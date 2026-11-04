//
//  CaptureUploaderTests.swift
//  VirtSpaceTests
//
//  The resume state machine (spec §10 R4/R13). This is the money path: before
//  these rules existed, a complete-but-failing session retried forever and
//  minted a fresh BILLABLE world on every world-gone retry.
//
//  Everything here runs against `FakeUploadAPI` and a temp-directory
//  CaptureStore — no network, no real capture directory.
//

import Foundation
import Testing
import simd
@testable import VirtSpace

@Suite("CaptureUploader resume state machine")
struct CaptureUploaderTests {
    private func makeUploader(
        _ fixture: StoreFixture,
        api: FakeUploadAPI,
        frames: FakeFrameUploader = FakeFrameUploader(),
        clock: TestClock = TestClock()
    ) -> CaptureUploader {
        CaptureUploader(api: api, store: fixture.store, frameUploader: frames, now: clock.now)
    }

    // MARK: - Idempotency

    @Test("The first world is minted under the session's own id, persisted first")
    func firstMintUsesSessionId() async throws {
        let fixture = StoreFixture()
        let session = try fixture.makeCompleteSession(frameCount: 2)
        let api = FakeUploadAPI()
        var keyWasPersistedBeforeRequest = false
        api.onCreateWorld = { key in
            // The key must already be on disk when the request goes out — that
            // is what makes a kill in this window safe.
            keyWasPersistedBeforeRequest = fixture.manifest(session.id)?.worldRequestId == key
            return (Fixtures.world(), Fixtures.slots(count: 2))
        }
        let uploader = makeUploader(fixture, api: api)

        let world = try await uploader.upload(
            result: CaptureResult(sessionID: session.id, directory: session.directory, frameCount: 2)
        )

        #expect(world.id == "world-1")
        #expect(api.createKeys == [session.id])
        #expect(keyWasPersistedBeforeRequest)
        #expect(api.framesDoneWorldIds == ["world-1"])
        // Success purges the session.
        #expect(fixture.pending(session.id) == nil)
    }

    @Test("A retry of a failed mint replays the same idempotency key")
    func keyIsStableAcrossRetries() async throws {
        let fixture = StoreFixture()
        let session = try fixture.makeCompleteSession(frameCount: 2)
        let api = FakeUploadAPI()
        var failNext = true
        api.onCreateWorld = { _ in
            if failNext {
                failNext = false
                throw APIError.server(500, "boom")
            }
            return (Fixtures.world(), Fixtures.slots(count: 2))
        }
        let uploader = makeUploader(fixture, api: api)

        await #expect(throws: (any Error).self) {
            try await uploader.upload(
                result: CaptureResult(sessionID: session.id, directory: session.directory, frameCount: 2)
            )
        }
        let outcome = await uploader.resumePending(userInitiated: true)

        #expect(api.createKeys == [session.id, session.id])
        if case .succeeded(let worlds) = outcome {
            #expect(worlds.count == 1)
        } else {
            Issue.record("expected success, got \(outcome)")
        }
    }

    @Test("A 409 on a spent key mints once more under a fresh key")
    func idempotencyConflictRenewsKey() async throws {
        let fixture = StoreFixture()
        let session = try fixture.makeCompleteSession(frameCount: 2)
        let api = FakeUploadAPI()
        var first = true
        api.onCreateWorld = { _ in
            if first {
                first = false
                throw APIError.server(409, "idempotency_key_world_deleted")
            }
            return (Fixtures.world(), Fixtures.slots(count: 2))
        }
        let uploader = makeUploader(fixture, api: api)

        _ = try await uploader.upload(
            result: CaptureResult(sessionID: session.id, directory: session.directory, frameCount: 2)
        )

        #expect(api.createKeys.count == 2)
        #expect(api.createKeys.first == session.id)
        #expect(api.createKeys.last != session.id)
    }

    @Test("A key that can't be persisted never reaches createWorld")
    func unpersistableKeyRefusesToMint() async throws {
        let fixture = StoreFixture()
        let session = try fixture.makeCompleteSession(frameCount: 2)
        // A read-only session directory makes every atomic poses.json write
        // fail, the same way a full disk would.
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: session.directory.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: session.directory.path) }
        let api = FakeUploadAPI()
        let uploader = makeUploader(fixture, api: api)

        await #expect(throws: (any Error).self) {
            try await uploader.upload(
                result: CaptureResult(sessionID: session.id, directory: session.directory, frameCount: 2)
            )
        }

        #expect(api.createCount == 0)
        #expect(fixture.manifest(session.id)?.worldRequestId == nil)
    }

    // MARK: - World gone

    @Test("A world deleted server-side is replaced under a NEW persisted key")
    func worldGoneMintsWithNewKey() async throws {
        let fixture = StoreFixture()
        let session = try fixture.makeCompleteSession(frameCount: 2)
        try fixture.store.setCreatedWorldId("dead-world", forSession: session.id, in: session.directory)
        try fixture.store.markFrameUploaded(index: 0, forSession: session.id, in: session.directory)

        let api = FakeUploadAPI()
        api.onRefreshUploads = { _ in throw Fixtures.worldGone }
        var persistedKeyAtRequest: UUID?
        api.onCreateWorld = { key in
            persistedKeyAtRequest = fixture.manifest(session.id)?.worldRequestId
            #expect(persistedKeyAtRequest == key)
            return (Fixtures.world(id: "fresh-world"), Fixtures.slots(count: 2))
        }
        let frames = FakeFrameUploader()
        let uploader = makeUploader(fixture, api: api, frames: frames)

        let outcome = await uploader.resumePending(userInitiated: true)

        #expect(api.refreshedWorldIds == ["dead-world"])
        #expect(api.createKeys.count == 1)
        // A deliberate replacement world ⇒ a brand-new key, not the session id.
        #expect(api.createKeys.first! != session.id)
        #expect(persistedKeyAtRequest != nil)
        // Every frame is re-uploaded to the fresh world, not just the missing one.
        #expect(frames.uploadedIndices.sorted() == [0, 1])
        #expect(api.framesDoneWorldIds == ["fresh-world"])
        if case .succeeded = outcome {} else { Issue.record("expected success, got \(outcome)") }
    }

    @Test("A quota refusal never leaves a replacement world behind")
    func quotaDuringWorldGoneMintsNothing() async throws {
        let fixture = StoreFixture()
        let session = try fixture.makeCompleteSession(frameCount: 2)
        try fixture.store.setCreatedWorldId("dead-world", forSession: session.id, in: session.directory)

        let api = FakeUploadAPI()
        api.onRefreshUploads = { _ in throw Fixtures.worldGone }
        api.onCreateWorld = { _ in throw APIError.scanQuota(resetAt: nil) }
        let uploader = makeUploader(fixture, api: api)

        let outcome = await uploader.resumePending(userInitiated: true)

        #expect(api.createKeys.count == 1)      // refused, nothing created
        #expect(api.framesDoneWorldIds.isEmpty)
        // The capture is still on disk, unparked, waiting for allowance.
        let manifest = fixture.manifest(session.id)
        #expect(manifest != nil)
        #expect(manifest?.createdWorldId == nil)
        #expect(manifest?.attemptCount == 0)
        #expect(manifest?.isParked == false)
        if case .failed = outcome {} else { Issue.record("expected failure, got \(outcome)") }
    }

    // MARK: - Backoff and parking

    @Test("An automatic sweep waits out the backoff window")
    func backoffIsRespected() async throws {
        let fixture = StoreFixture()
        let session = try fixture.makeCompleteSession(frameCount: 2)
        let api = FakeUploadAPI()
        api.onCreateWorld = { _ in throw APIError.server(500, "boom") }
        let clock = TestClock()
        let uploader = makeUploader(fixture, api: api, clock: clock)

        _ = await uploader.resumePending()
        #expect(api.createCount == 1)
        #expect(fixture.manifest(session.id)?.attemptCount == 1)

        // Immediately again: still inside the 1-minute window.
        let deferred = await uploader.resumePending()
        #expect(api.createCount == 1)
        if case .deferred = deferred {} else { Issue.record("expected deferral, got \(deferred)") }

        clock.advance(by: 60)
        _ = await uploader.resumePending()
        #expect(api.createCount == 2)
    }

    @Test("Five real failures park the session; no further automatic work")
    func parksAfterFiveAttempts() async throws {
        let fixture = StoreFixture()
        let session = try fixture.makeCompleteSession(frameCount: 2)
        let api = FakeUploadAPI()
        api.onCreateWorld = { _ in throw APIError.server(500, "boom") }
        let clock = TestClock()
        let uploader = makeUploader(fixture, api: api, clock: clock)

        for _ in 0..<CaptureStore.Manifest.maxAutomaticAttempts {
            _ = await uploader.resumePending()
            clock.advance(by: 86_400) // well past any backoff window
        }

        #expect(api.createCount == CaptureStore.Manifest.maxAutomaticAttempts)
        #expect(fixture.manifest(session.id)?.attemptCount == CaptureStore.Manifest.maxAutomaticAttempts)
        #expect(fixture.manifest(session.id)?.isParked == true)

        // Parked: no more automatic attempts, however long we wait. Crucially
        // that includes minting another billable world.
        clock.advance(by: 86_400)
        let outcome = await uploader.resumePending()
        #expect(api.createCount == CaptureStore.Manifest.maxAutomaticAttempts)
        if case .deferred = outcome {} else { Issue.record("expected deferral, got \(outcome)") }

        let summary = await uploader.pendingSummary()
        #expect(summary.pendingCount == 1)
        #expect(summary.parkedCount == 1)
    }

    @Test("Quota refusals never park a session")
    func quotaDoesNotPark() async throws {
        let fixture = StoreFixture()
        let session = try fixture.makeCompleteSession(frameCount: 2)
        let api = FakeUploadAPI()
        api.onCreateWorld = { _ in throw APIError.scanQuota(resetAt: nil) }
        let clock = TestClock()
        let uploader = makeUploader(fixture, api: api, clock: clock)

        for _ in 0..<8 {
            _ = await uploader.resumePending()
            clock.advance(by: 86_400)
        }

        #expect(api.createCount == 8)
        #expect(fixture.manifest(session.id)?.attemptCount == 0)
        #expect(fixture.manifest(session.id)?.isParked == false)
    }

    @Test("Being offline never parks a session")
    func offlineDoesNotPark() async throws {
        let fixture = StoreFixture()
        let session = try fixture.makeCompleteSession(frameCount: 2)
        let api = FakeUploadAPI()
        api.onCreateWorld = { _ in throw Fixtures.offline }
        let clock = TestClock()
        let uploader = makeUploader(fixture, api: api, clock: clock)

        for _ in 0..<8 {
            _ = await uploader.resumePending()
            clock.advance(by: 86_400)
        }

        #expect(fixture.manifest(session.id)?.attemptCount == 0)
        #expect(fixture.manifest(session.id)?.isParked == false)
    }

    @Test("A user-initiated retry un-parks and resets the counter")
    func userRetryResetsCounter() async throws {
        let fixture = StoreFixture()
        let session = try fixture.makeCompleteSession(frameCount: 2)
        let api = FakeUploadAPI()
        api.onCreateWorld = { _ in throw APIError.server(500, "boom") }
        let clock = TestClock()
        let uploader = makeUploader(fixture, api: api, clock: clock)

        for _ in 0..<CaptureStore.Manifest.maxAutomaticAttempts {
            _ = await uploader.resumePending()
            clock.advance(by: 86_400)
        }
        #expect(fixture.manifest(session.id)?.isParked == true)

        // The user says "try again": full fresh budget, no backoff wait.
        api.onCreateWorld = nil
        let outcome = await uploader.resumePending(userInitiated: true)

        if case .succeeded = outcome {} else { Issue.record("expected success, got \(outcome)") }
        #expect(fixture.pending(session.id) == nil) // purged on success
    }

    // MARK: - Outcomes

    @Test("An empty store reports nothing to resume")
    func nothingToResume() async {
        let fixture = StoreFixture()
        let uploader = makeUploader(fixture, api: FakeUploadAPI())
        let outcome = await uploader.resumePending()
        #expect(outcome == .nothingToResume)
    }

    @Test("A failure reports the real reason, not a swallowed generic one")
    func failureReasonIsReported() async throws {
        let fixture = StoreFixture()
        _ = try fixture.makeCompleteSession(frameCount: 2)
        let api = FakeUploadAPI()
        api.onCreateWorld = { _ in throw APIError.server(503, "stitcher unavailable") }
        let uploader = makeUploader(fixture, api: api)

        let outcome = await uploader.resumePending()

        if case .failed(let reason) = outcome {
            // The real error's user copy, not a generic "check your connection".
            #expect(reason == APIError.server(503, "stitcher unavailable").errorDescription)
        } else {
            Issue.record("expected a failure with a reason, got \(outcome)")
        }
    }

    // MARK: - Resume mechanics

    @Test("A resume re-PUTs only the frames that aren't confirmed")
    func resumeSkipsUploadedFrames() async throws {
        let fixture = StoreFixture()
        let session = try fixture.makeCompleteSession(frameCount: 2)
        try fixture.store.setCreatedWorldId("world-1", forSession: session.id, in: session.directory)
        try fixture.store.markFrameUploaded(index: 0, forSession: session.id, in: session.directory)

        let api = FakeUploadAPI()
        let frames = FakeFrameUploader()
        let uploader = makeUploader(fixture, api: api, frames: frames)

        _ = await uploader.resumePending(userInitiated: true)

        #expect(api.refreshedWorldIds == ["world-1"])
        #expect(api.createKeys.isEmpty)          // the world is reused, never re-minted
        #expect(frames.uploadedIndices == [1])
    }

    // MARK: - Background batch (R25)

    @Test("Every remaining PUT is on the background session at once")
    func allUploadsEnqueuedUpFront() async throws {
        let fixture = StoreFixture()
        let session = try fixture.makeCompleteSession(frameCount: 4)
        let frames = FakeFrameUploader()
        frames.holdUntilInFlight = 4
        let uploader = makeUploader(fixture, api: FakeUploadAPI(), frames: frames)

        _ = try await uploader.upload(
            result: CaptureResult(sessionID: session.id, directory: session.directory, frameCount: 4)
        )

        // Serial uploads never had more than one task in flight.
        #expect(frames.maxInFlight == 4)
        #expect(frames.uploadedIndices.sorted() == [0, 1, 2, 3])
    }

    @Test("An expired presign (403) re-presigns and retries without counting")
    func expiredPresignRefreshes() async throws {
        let fixture = StoreFixture()
        let session = try fixture.makeCompleteSession(frameCount: 2)
        let api = FakeUploadAPI()
        api.onRefreshUploads = { id in (Fixtures.world(id: id), Fixtures.slots(count: 2, batch: "fresh")) }
        let frames = FakeFrameUploader()
        // Frame 1's original URL expired; frame 0 made it in time.
        frames.onUpload = { slot in
            if slot.url.hasSuffix("upload/1") { throw APIError.server(403, "Request has expired") }
        }
        let uploader = makeUploader(fixture, api: api, frames: frames)

        let world = try await uploader.upload(
            result: CaptureResult(sessionID: session.id, directory: session.directory, frameCount: 2)
        )

        #expect(world.id == "world-1")
        #expect(api.refreshedWorldIds == ["world-1"])
        // Only the expired frame goes again.
        #expect(frames.uploadedIndices.sorted() == [0, 1])
        #expect(api.framesDoneWorldIds == ["world-1"])
        #expect(fixture.pending(session.id) == nil)
    }

    @Test("A 403 that survives a fresh presign is one counted failure")
    func persistent403Counts() async throws {
        let fixture = StoreFixture()
        let session = try fixture.makeCompleteSession(frameCount: 2)
        let api = FakeUploadAPI()
        let frames = FakeFrameUploader()
        frames.onUpload = { _ in throw APIError.server(403, "AccessDenied") }
        let uploader = makeUploader(fixture, api: api, frames: frames)

        await #expect(throws: (any Error).self) {
            try await uploader.upload(
                result: CaptureResult(sessionID: session.id, directory: session.directory, frameCount: 2)
            )
        }

        #expect(api.refreshedWorldIds == ["world-1"])
        #expect(api.framesDoneWorldIds.isEmpty)
        #expect(fixture.manifest(session.id)?.attemptCount == 1)
    }

    @Test("A stranded session goes straight to frames:done")
    func strandedRecovery() async throws {
        let fixture = StoreFixture()
        let session = try fixture.makeCompleteSession(frameCount: 2)
        try fixture.store.setCreatedWorldId("world-1", forSession: session.id, in: session.directory)
        try fixture.store.markFrameUploaded(index: 0, forSession: session.id, in: session.directory)
        try fixture.store.markFrameUploaded(index: 1, forSession: session.id, in: session.directory)

        let api = FakeUploadAPI()
        let uploader = makeUploader(fixture, api: api)

        let completed = await uploader.completeStrandedSessions()

        #expect(completed == 1)
        #expect(api.framesDoneWorldIds == ["world-1"])
        #expect(api.createKeys.isEmpty)
        #expect(api.refreshedWorldIds.isEmpty)
        #expect(fixture.pending(session.id) == nil)
    }

    @Test("Stranded recovery leaves a parked session alone")
    func strandedRecoverySkipsParked() async throws {
        let fixture = StoreFixture()
        let session = try fixture.makeCompleteSession(frameCount: 2)
        try fixture.store.setCreatedWorldId("world-1", forSession: session.id, in: session.directory)
        try fixture.store.markFrameUploaded(index: 0, forSession: session.id, in: session.directory)
        try fixture.store.markFrameUploaded(index: 1, forSession: session.id, in: session.directory)
        // Park it.
        for _ in 0..<CaptureStore.Manifest.maxAutomaticAttempts {
            try fixture.store.recordFailedAttempt(forSession: session.id, in: session.directory, countsTowardParking: true)
        }

        let api = FakeUploadAPI()
        // If it ran, the world-gone branch below would mint a billable world.
        api.onFramesDone = { _ in throw Fixtures.worldGone }
        let uploader = makeUploader(fixture, api: api)

        let completed = await uploader.completeStrandedSessions()

        #expect(completed == 0)
        #expect(api.framesDoneWorldIds.isEmpty)
        #expect(api.createKeys.isEmpty)
        #expect(fixture.pending(session.id) != nil)
    }

    @Test("Discarding removes the session and deletes its world")
    func discardPending() async throws {
        let fixture = StoreFixture()
        let session = try fixture.makeCompleteSession(frameCount: 2)
        try fixture.store.setCreatedWorldId("world-1", forSession: session.id, in: session.directory)
        let api = FakeUploadAPI()
        let uploader = makeUploader(fixture, api: api)

        let discarded = await uploader.discardPending()

        #expect(discarded == 1)
        #expect(api.deletedWorldIds == ["world-1"])
        #expect(fixture.pending(session.id) == nil)
        #expect(await uploader.pendingSummary().pendingCount == 0)
    }
}

@Suite("CaptureUploader depth uploads")
struct CaptureUploaderDepthTests {
    /// Two frames with depth on disk plus one whose depth file is missing.
    private func makeDepthSession(_ fixture: StoreFixture) throws -> CaptureStore.PendingSession {
        let session = try fixture.store.createSession(expectedFrameCount: 3)
        let png = try #require(FrameDepth.png(millimetres: [1000, 2000], width: 2, height: 1))
        for index in 0..<3 {
            let pose = CaptureStore.FramePose(
                index: index, timestamp: Double(index), transform: matrix_identity_float4x4,
                intrinsics: matrix_identity_float3x3, exposureLocked: true,
                iso: 200, exposureDuration: 1.0 / 60,
                depth: FrameDepthSize(width: 2, height: 1)
            )
            try fixture.store.saveFrame(Data([0xFF, 0xD8]), depthPNG: png, pose: pose, in: session)
        }
        // Lost after capture: frame 2 must still upload, just without depth.
        try FileManager.default.removeItem(at: fixture.store.depthURL(index: 2, in: session.directory))
        return try #require(fixture.pending(session.id))
    }

    @Test("Declares exact depth sizes, uploads them, and sends depth only for uploaded files")
    func depthUploadsAlongsideFrames() async throws {
        let fixture = StoreFixture()
        let session = try makeDepthSession(fixture)
        let api = FakeUploadAPI()
        api.depthSlotCount = 3
        let frames = FakeFrameUploader()
        frames.failingDepthIndices = [1]
        let uploader = CaptureUploader(api: api, store: fixture.store, frameUploader: frames, now: TestClock().now)

        _ = try await uploader.upload(
            result: CaptureResult(sessionID: session.id, directory: session.directory, frameCount: 3)
        )

        let size = try #require(
            try FileManager.default.attributesOfItem(atPath: fixture.store.depthURL(index: 0, in: session.directory).path)[.size] as? Int
        )
        #expect(api.createDepthFrames == [[DepthFrameDeclaration(index: 0, bytes: size), DepthFrameDeclaration(index: 1, bytes: size)]])
        // A failed depth PUT and a missing depth file never block the frames.
        #expect(frames.uploadedIndices.sorted() == [0, 1, 2])
        #expect(frames.uploadedDepthIndices == [0])
        let poses = try #require(api.lastPoses)
        #expect(poses.map { $0.depth != nil } == [true, false, false])
        #expect(poses.allSatisfy { $0.iso == 200 })
        #expect(fixture.pending(session.id) == nil)
    }

    @Test("A session without depth sends no depth fields at all")
    func noDepthNoField() async throws {
        let fixture = StoreFixture()
        let session = try fixture.makeCompleteSession(frameCount: 2)
        let api = FakeUploadAPI()
        let uploader = CaptureUploader(api: api, store: fixture.store, frameUploader: FakeFrameUploader(), now: TestClock().now)

        _ = try await uploader.upload(
            result: CaptureResult(sessionID: session.id, directory: session.directory, frameCount: 2)
        )

        #expect(api.createDepthFrames.count == 1)
        #expect(api.createDepthFrames.first! == nil)
        #expect(api.lastPoses?.allSatisfy { $0.depth == nil } == true)
    }
}
