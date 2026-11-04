//
//  CaptureStoreTests.swift
//  VirtSpaceTests
//
//  poses.json is the crash-safety contract (spec §6.1): if it can't be read
//  back, a killed app loses a capture, and if a manifest written by an older
//  build can't be decoded, every session already on a user's device becomes
//  invisible. Both directions are covered here (spec §10 R13).
//

import Foundation
import Testing
import simd
@testable import VirtSpace

@Suite("CaptureStore manifest")
struct CaptureStoreManifestTests {
    private func makePose(index: Int) -> CaptureStore.FramePose {
        CaptureStore.FramePose(
            index: index,
            timestamp: Double(index) * 0.5,
            transform: matrix_identity_float4x4,
            intrinsics: matrix_identity_float3x3,
            exposureLocked: true
        )
    }

    @Test("Round-trips every field, new ones included")
    func roundTrip() throws {
        let id = UUID()
        let requestId = UUID()
        let attemptedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = CaptureStore.Manifest(
            sessionID: id,
            expectedFrameCount: 28,
            createdAt: Date(timeIntervalSince1970: 1_699_000_000),
            frames: [makePose(index: 0), makePose(index: 1)],
            createdWorldId: "world-42",
            uploadedFrameIndices: [0, 1],
            worldRequestId: requestId,
            attemptCount: 3,
            lastAttemptAt: attemptedAt
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(CaptureStore.Manifest.self, from: data)

        #expect(decoded.sessionID == id)
        #expect(decoded.expectedFrameCount == 28)
        #expect(decoded.frames.count == 2)
        #expect(decoded.frames[1].index == 1)
        #expect(decoded.createdWorldId == "world-42")
        #expect(decoded.uploadedFrameIndices == [0, 1])
        #expect(decoded.worldRequestId == requestId)
        #expect(decoded.attemptCount == 3)
        #expect(decoded.lastAttemptAt == attemptedAt)
    }

    @Test("Legacy manifest without the new fields still decodes")
    func legacyDecode() throws {
        // Exactly what a build before the resume/attempt fields wrote.
        let legacy = """
        {
          "session_id": "6C3C0A5A-6B7E-4F7B-9E8A-1E0F1A2B3C4D",
          "expected_frame_count": 28,
          "created_at": 0,
          "frames": []
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(CaptureStore.Manifest.self, from: legacy)

        #expect(decoded.expectedFrameCount == 28)
        #expect(decoded.createdWorldId == nil)
        #expect(decoded.uploadedFrameIndices.isEmpty)
        // The R4 additions must default cleanly — an old session is not parked
        // and has no spent idempotency key.
        #expect(decoded.worldRequestId == nil)
        #expect(decoded.attemptCount == 0)
        #expect(decoded.lastAttemptAt == nil)
        #expect(!decoded.isParked)
        #expect(decoded.isReadyForAutomaticRetry(now: Date()))
    }

    @Test("Backoff schedule: 1 m, 5 m, 30 m, 2 h, 6 h, then parked")
    func backoffAndParking() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var manifest = CaptureStore.Manifest(
            sessionID: UUID(),
            expectedFrameCount: 1,
            createdAt: start,
            frames: []
        )

        // No attempt yet ⇒ retry immediately.
        #expect(manifest.isReadyForAutomaticRetry(now: start))

        // Wait after the nth failed attempt.
        let expected: [TimeInterval] = [60, 300, 1_800, 7_200, 21_600]
        for (index, delay) in expected.enumerated() where index + 1 < CaptureStore.Manifest.maxAutomaticAttempts {
            manifest.attemptCount = index + 1
            manifest.lastAttemptAt = start
            #expect(!manifest.isReadyForAutomaticRetry(now: start.addingTimeInterval(delay - 1)))
            #expect(manifest.isReadyForAutomaticRetry(now: start.addingTimeInterval(delay)))
        }

        // An uncounted failure (quota/offline) still waits out the first tier.
        manifest.attemptCount = 0
        manifest.lastAttemptAt = start
        #expect(!manifest.isReadyForAutomaticRetry(now: start.addingTimeInterval(59)))
        #expect(manifest.isReadyForAutomaticRetry(now: start.addingTimeInterval(60)))

        manifest.attemptCount = CaptureStore.Manifest.maxAutomaticAttempts
        #expect(manifest.isParked)
        // Parked means parked: no amount of waiting re-enables automatic retry.
        #expect(!manifest.isReadyForAutomaticRetry(now: start.addingTimeInterval(86_400)))
    }
}

@Suite("CaptureStore on disk")
struct CaptureStoreDiskTests {
    @Test("Saved frames and resume state survive a re-read")
    func persistsResumeState() throws {
        let fixture = StoreFixture()
        let session = try fixture.makeCompleteSession(frameCount: 2)

        #expect(fixture.manifest(session.id)?.isComplete == true)

        try fixture.store.setCreatedWorldId("world-9", forSession: session.id, in: session.directory)
        try fixture.store.markFrameUploaded(index: 0, forSession: session.id, in: session.directory)

        let reread = CaptureStore(baseDirectory: fixture.root)
        let manifest = reread.loadPending().first { $0.id == session.id }?.manifest
        #expect(manifest?.createdWorldId == "world-9")
        #expect(manifest?.uploadedFrameIndices == [0])
    }

    @Test("The first world request id is the session id; renewing changes it")
    func worldRequestIds() throws {
        let fixture = StoreFixture()
        let session = try fixture.makeCompleteSession(frameCount: 1)

        let first = try fixture.store.worldRequestId(forSession: session.id, in: session.directory)
        #expect(first == session.id)
        // Stable across retries of the same logical request.
        #expect(try fixture.store.worldRequestId(forSession: session.id, in: session.directory) == first)
        // Persisted, not just remembered.
        #expect(fixture.manifest(session.id)?.worldRequestId == first)

        let renewed = try fixture.store.worldRequestId(forSession: session.id, in: session.directory, renew: true)
        #expect(renewed != first)
        #expect(fixture.manifest(session.id)?.worldRequestId == renewed)
    }

    @Test("Attempt bookkeeping increments, exempts, and resets")
    func attemptBookkeeping() throws {
        let fixture = StoreFixture()
        let session = try fixture.makeCompleteSession(frameCount: 1)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try fixture.store.recordFailedAttempt(forSession: session.id, in: session.directory, countsTowardParking: true, at: now)
        #expect(fixture.manifest(session.id)?.attemptCount == 1)
        #expect(fixture.manifest(session.id)?.lastAttemptAt == now)

        // Quota / offline: clock moves, counter doesn't.
        try fixture.store.recordFailedAttempt(forSession: session.id, in: session.directory, countsTowardParking: false, at: now.addingTimeInterval(60))
        #expect(fixture.manifest(session.id)?.attemptCount == 1)
        #expect(fixture.manifest(session.id)?.lastAttemptAt == now.addingTimeInterval(60))

        try fixture.store.resetUploadAttempts(forSession: session.id, in: session.directory)
        #expect(fixture.manifest(session.id)?.attemptCount == 0)
        #expect(fixture.manifest(session.id)?.lastAttemptAt == nil)
    }

    @Test("Purging a session hides it immediately")
    func purge() throws {
        let fixture = StoreFixture()
        let session = try fixture.makeCompleteSession(frameCount: 1)
        fixture.store.purge(id: session.id)
        #expect(fixture.pending(session.id) == nil)
    }
}
