//
//  CaptureUploader.swift
//  VirtSpace
//
//  Glue between a finished on-disk capture session and the backend:
//  createWorld → sequential presigned frame uploads (FrameUploader) →
//  frames:done → purge the local session. Frames upload as image/jpeg using
//  exactly the headers the API returned per slot. Resumable: a failed upload
//  keeps the session directory; `resumePending()` retries complete sessions
//  found on disk (crash/offline recovery, spec §6.1).
//
//  Retry policy (spec §10 R4 — this used to retry forever, minting a fresh
//  BILLABLE world per attempt for a session the backend kept rejecting):
//    • `POST /v1/worlds` carries an `Idempotency-Key` persisted BEFORE the
//      request, so a kill or retry in that window returns the same world.
//    • Automatic retries back off (1 m, 5 m, 30 m, 2 h, 6 h) and stop entirely
//      after 5 real failures: the session is PARKED — no more uploads and no
//      more automatic world minting — until the user explicitly retries or
//      discards it.
//    • Quota refusals and "there's no network" don't count toward that budget,
//      and a quota refusal never mints a replacement world.
//

import Foundation
import OSLog

/// What a resume sweep actually did. `resumePending` used to swallow every
/// failure with `try?` and return an array, so the UI could only ever say
/// "failed again" — including when nothing was pending, or when the session was
/// simply waiting out its backoff (spec §10 R4).
enum ResumeOutcome: Equatable {
    /// Nothing on disk needed uploading.
    case nothingToResume
    /// At least one session's pipeline was (re)started.
    case succeeded([World])
    /// Work was attempted and every candidate failed. `reason` is user-facing.
    case failed(reason: String)
    /// Candidates exist but weren't touched: parked awaiting an explicit user
    /// choice, waiting out a backoff, or already in flight on another task.
    case deferred(reason: String)
}

/// Snapshot of what's waiting on disk, for the capture screen's pending-upload
/// affordances.
struct PendingUploadSummary: Equatable {
    /// Complete sessions still waiting to reach the backend.
    var pendingCount: Int = 0
    /// How many of those have exhausted their automatic retry budget.
    var parkedCount: Int = 0

    var hasPending: Bool { pendingCount > 0 }
    var hasParked: Bool { parkedCount > 0 }
}

final class CaptureUploader {
    /// Expected full-sphere frame count — derived from the capture pattern
    /// (Phase 0.5 densified layout = 28) so nothing hardcodes the old 16.
    static let expectedFrameCount = TargetLayout.targetCount

    private let api: CaptureUploadAPI
    /// Every manifest read/write goes through here, off the main actor (R15).
    private let sessions: PendingSessionStore
    private let frameUploader: FrameUploading
    /// Injected for tests; production uses the wall clock.
    private let now: () -> Date

    init(
        api: CaptureUploadAPI,
        store: CaptureStore = CaptureStore(),
        frameUploader: FrameUploading = FrameUploader(),
        now: @escaping () -> Date = Date.init
    ) {
        self.api = api
        self.sessions = PendingSessionStore(store: store)
        self.frameUploader = frameUploader
        self.now = now
    }

    // MARK: - Upload

    /// Upload one finished capture session. `progress` receives the number of
    /// frames uploaded so far (0…frameCount). On success the local session is
    /// purged; on failure it stays on disk, with the failure recorded against
    /// the session's automatic-retry budget, for `resumePending()`.
    @discardableResult
    func upload(result: CaptureResult, progress: @escaping (Int) -> Void = { _ in }) async throws -> World {
        guard let session = await sessions.pending(result.sessionID) else {
            throw APIError.server(0, "Capture session not found on disk")
        }
        guard let world = try await withClaim(session.id, {
            try await attemptUpload(session: session, progress: progress)
        }) else {
            throw APIError.server(0, "This capture is already uploading")
        }
        return world
    }

    /// Retry the sessions left on disk (launch, capture screen appearing, or
    /// the user's Retry button when `userInitiated`).
    ///
    /// An automatic sweep skips sessions that are parked or still inside their
    /// backoff window. A user-initiated one clears the attempt counter first —
    /// an explicit retry always gets a full fresh budget — and ignores backoff.
    /// Incomplete sessions older than a day are dead (the capture UI can't
    /// resume mid-scan yet) and get cleaned up.
    @discardableResult
    func resumePending(
        userInitiated: Bool = false,
        progress: @escaping (Int) -> Void = { _ in }
    ) async -> ResumeOutcome {
        var uploaded: [World] = []
        var lastFailure: String?
        var deferrals: [String] = []
        var candidates = 0

        for session in await sessions.loadPending() {
            if session.manifest.isComplete {
                candidates += 1
                if userInitiated {
                    // Explicit retry ⇒ fresh budget, no backoff wait, un-parked.
                    // A reset that can't persist leaves the old budget in place;
                    // a still-parked session's mint is refused in createFreshWorld.
                    try? await sessions.resetUploadAttempts(forSession: session.id, in: session.directory)
                } else if session.manifest.isParked {
                    AppLog.upload.log("Session \(session.id.uuidString, privacy: .public) is parked after \(session.manifest.attemptCount) failed attempts — waiting for the user")
                    deferrals.append("paused after \(session.manifest.attemptCount) failed attempts")
                    continue
                } else if !session.manifest.isReadyForAutomaticRetry(now: now()) {
                    deferrals.append("waiting before the next automatic retry")
                    continue
                }
                // Re-read: the reset above changed the manifest on disk.
                let current = await sessions.pending(session.id) ?? session
                // Skip (never wait for) a session another flow already owns — one
                // wedged upload must not block the rest, or the retry button (R12).
                let claimed = await withClaim(current.id) { () -> Result<World, Error> in
                    do {
                        return .success(try await attemptUpload(session: current, progress: progress))
                    } catch {
                        return .failure(error)
                    }
                }
                switch claimed {
                case .none:
                    deferrals.append("already uploading")
                case .some(.success(let world)):
                    uploaded.append(world)
                case .some(.failure(let error)):
                    lastFailure = Self.message(for: error)
                }
            } else if now().timeIntervalSince(session.manifest.createdAt) > 86_400 {
                await withClaim(session.id) {
                    // Permanently discarding the session — if it already minted
                    // a backend world, best-effort delete it so it doesn't
                    // linger as an orphan in `uploading` (the server-side 24 h
                    // reaper is the backstop if this delete never lands).
                    if let worldId = session.manifest.createdWorldId {
                        try? await api.deleteWorld(id: worldId)
                    }
                    await sessions.purge(id: session.id)
                }
            }
        }

        if !uploaded.isEmpty { return .succeeded(uploaded) }
        if let lastFailure { return .failed(reason: lastFailure) }
        if let deferral = deferrals.first { return .deferred(reason: deferral) }
        return candidates == 0 ? .nothingToResume : .deferred(reason: "nothing to do")
    }

    /// What's waiting on disk right now (capture screen affordances).
    func pendingSummary() async -> PendingUploadSummary {
        var summary = PendingUploadSummary()
        for session in await sessions.loadPending() where session.manifest.isComplete {
            summary.pendingCount += 1
            if session.manifest.isParked { summary.parkedCount += 1 }
        }
        return summary
    }

    /// Throw away every complete pending session at the user's request, and
    /// best-effort delete any world they already minted so it doesn't sit
    /// orphaned in `uploading`. Returns the number discarded.
    @discardableResult
    func discardPending() async -> Int {
        var discarded = 0
        for session in await sessions.loadPending() where session.manifest.isComplete {
            await withClaim(session.id) {
                if let worldId = session.manifest.createdWorldId {
                    try? await api.deleteWorld(id: worldId)
                }
                await sessions.purge(id: session.id)
                discarded += 1
            }
        }
        AppLog.upload.log("Discarded \(discarded) pending capture session(s) at the user's request")
        return discarded
    }

    // MARK: - Per-session exclusion

    /// Run `body` while holding an exclusive claim on `id`, or skip it entirely
    /// (returning nil) when another in-flight flow already owns that session.
    /// This is the ONLY serialization upload flows need: two flows must never
    /// work the same session, but flows on different sessions are independent
    /// (spec §10 R12 — the old global chain let one stuck session block all).
    @discardableResult
    private func withClaim<T>(_ id: UUID, _ body: () async throws -> T) async rethrows -> T? {
        guard await SessionClaims.shared.claim(id) else {
            AppLog.upload.log("Session \(id.uuidString, privacy: .public) is already being worked by another flow — skipping")
            return nil
        }
        do {
            let value = try await body()
            await SessionClaims.shared.release(id)
            return value
        } catch {
            await SessionClaims.shared.release(id)
            throw error
        }
    }

    // MARK: - Stranded-session completion

    /// Cheap, idempotent recovery for the exact stranded state a cancelled
    /// view-lifecycle flow used to leave behind: createdWorldId set AND every
    /// frame flagged uploaded, but frames:done never sent (the world sits in
    /// `uploading` forever server-side). Goes straight to frames:done (with
    /// poses) and purges the session on success. Kicked by UploadManager at
    /// launch and on every scenePhase → .active. Returns sessions completed.
    ///
    /// Parked sessions are left alone unless the user asked for this: the
    /// world-gone branch below MINTS A NEW WORLD, which is billable.
    @discardableResult
    func completeStrandedSessions(userInitiated: Bool = false) async -> Int {
        var completed = 0
        for session in await sessions.loadPending() {
            let manifest = session.manifest
            guard
                let worldId = manifest.createdWorldId,
                manifest.isComplete,
                manifest.frames.count > 0,
                manifest.uploadedFrameIndices.count >= manifest.frames.count
            else { continue }
            if !userInitiated, manifest.isParked {
                AppLog.upload.log("Stranded session \(session.id.uuidString, privacy: .public) is parked — leaving it for the user")
                continue
            }
            // Another flow already owns this session — skip, never block (R12).
            await withClaim(session.id) {
                if await completeStranded(session: session, worldId: worldId) { completed += 1 }
            }
        }
        return completed
    }

    /// The stranded-recovery body for one already-claimed session. Returns true
    /// when the session was completed (or re-uploaded to a fresh world).
    private func completeStranded(session: CaptureStore.PendingSession, worldId: String) async -> Bool {
        let manifest = session.manifest
        AppLog.upload.log("Stranded session \(session.id.uuidString, privacy: .public): \(manifest.uploadedFrameIndices.count)/\(manifest.frames.count) frames already uploaded, world \(worldId, privacy: .public) — going straight to frames:done")
        do {
            let poses = manifest.frames.map(\.wire)
            AppLog.upload.log("uploads complete, calling frames:done for \(worldId, privacy: .public)")
            try await api.framesDone(worldId: worldId, poses: poses)
            AppLog.upload.log("frames:done ok for \(worldId, privacy: .public) with \(poses.count) poses (stranded recovery)")
            await sessions.purge(id: session.id)
            return true
        } catch is CancellationError {
            AppLog.upload.fault("frames:done for stranded world \(worldId, privacy: .public) hit CancellationError — this flow must be app-scoped (UploadManager), investigate!")
            return false
        } catch let error as APIError where error.isWorldGone {
            // The stranded world was deleted server-side (404 world_not_found):
            // frames:done can never land. Clear the dead world id + uploaded
            // flags (frames stay on disk), then start a fresh upload in this
            // same run so the user's 28 frames aren't stranded forever. The
            // replacement world is minted under a NEW idempotency key — see
            // createFreshWorld(renewKey:).
            AppLog.upload.fault("resume: world \(worldId, privacy: .public) gone server-side — starting fresh")
            do {
                try await sessions.resetWorldState(forSession: session.id, in: session.directory)
                guard let fresh = await sessions.pending(session.id) else { return false }
                _ = try await attemptUpload(session: fresh, progress: { _ in }, renewWorldKey: true)
                return true
            } catch {
                return false
            }
        } catch {
            AppLog.upload.error("Stranded-session frames:done failed for \(worldId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            await recordFailure(error, for: session)
            return false
        }
    }

    // MARK: - Internals

    /// One upload attempt for an already-claimed session, with the failure
    /// recorded against the session's automatic-retry budget.
    private func attemptUpload(
        session: CaptureStore.PendingSession,
        progress: @escaping (Int) -> Void,
        renewWorldKey: Bool = false
    ) async throws -> World {
        do {
            return try await upload(session: session, progress: progress, renewWorldKey: renewWorldKey)
        } catch {
            await recordFailure(error, for: session)
            throw error
        }
    }

    /// Record a failed attempt. Quota refusals (402/429) and "there's no
    /// network" don't count toward parking — the capture is fine, the world
    /// just can't be made right now — but they still move the backoff clock so
    /// a foreground kick can't hammer the backend.
    private func recordFailure(_ error: Error, for session: CaptureStore.PendingSession) async {
        if error is CancellationError { return }
        let counts = error.countsTowardUploadParking
        do {
            try await sessions.recordFailedAttempt(
                forSession: session.id,
                in: session.directory,
                countsTowardParking: counts,
                at: now()
            )
        } catch {
            AppLog.upload.error("Couldn't record the failed attempt for session \(session.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        if counts {
            let attempts = await sessions.pending(session.id)?.manifest.attemptCount ?? 0
            AppLog.upload.error("Upload attempt \(attempts)/\(CaptureStore.Manifest.maxAutomaticAttempts) failed for session \(session.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if attempts >= CaptureStore.Manifest.maxAutomaticAttempts {
                AppLog.upload.fault("Session \(session.id.uuidString, privacy: .public) PARKED after \(attempts) failed attempts — no further automatic retries or world minting until the user chooses")
            }
        } else {
            AppLog.upload.log("Upload attempt for session \(session.id.uuidString, privacy: .public) failed transiently (quota/offline) — not counted toward parking")
        }
    }

    /// Mint a backend world for this session and persist its id BEFORE any
    /// frame uploads (crash-safe: a kill mid-upload resumes onto this world
    /// instead of orphaning it).
    ///
    /// The request carries an `Idempotency-Key` that is written to the manifest
    /// BEFORE it is sent, so a kill between request and response can't
    /// double-create: the retry replays the key and the backend returns the
    /// same world. `renewKey` mints a brand-new key for the one case where a
    /// genuinely NEW world is wanted — the previous one was deleted
    /// server-side.
    ///
    /// Quota edge: if `createWorld` is refused for quota (429), the session is
    /// intentionally left pending on disk — NOT discarded, and NOT re-minted —
    /// so it retries once the user's allowance frees up.
    private func createFreshWorld(
        session: CaptureStore.PendingSession,
        frameCount: Int,
        renewKey: Bool
    ) async throws -> (World, [FrameUpload]) {
        // Defensive: a parked session must never mint a billable world behind
        // the user's back. Every automatic path already skips parked sessions.
        if let current = await sessions.pending(session.id), current.manifest.isParked {
            AppLog.upload.fault("Refusing to mint a world for PARKED session \(session.id.uuidString, privacy: .public)")
            throw APIError.server(0, "This upload is paused. Retry or discard it from the capture screen.")
        }
        let title = "Scan \(now().formatted(date: .abbreviated, time: .shortened))"
        AppLog.upload.log("Upload start: session \(session.id.uuidString, privacy: .public), \(frameCount) frames")
        do {
            return try await mintWorld(session: session, title: title, frameCount: frameCount, renewKey: renewKey)
        } catch let error as APIError where error.isIdempotencyConflict {
            // 409: the world this key created has since been deleted, so the
            // key is spent and can never produce a world again. Persist a
            // brand-new key (before the request, as always) and retry once.
            AppLog.upload.fault("createWorld 409 for session \(session.id.uuidString, privacy: .public) — idempotency key is spent, minting under a fresh key")
            return try await mintWorld(session: session, title: title, frameCount: frameCount, renewKey: true)
        } catch APIError.quota {
            AppLog.upload.log("createWorld refused for quota (429) — keeping session \(session.id.uuidString, privacy: .public) pending, will retry when allowance frees up (no replacement world minted)")
            throw APIError.quota
        }
    }

    private func mintWorld(
        session: CaptureStore.PendingSession,
        title: String,
        frameCount: Int,
        renewKey: Bool
    ) async throws -> (World, [FrameUpload]) {
        // Persisted FIRST — the whole point of the key. A key that can't be
        // persisted throws here, so the billable request is never sent.
        let key = try await sessions.worldRequestId(forSession: session.id, in: session.directory, renew: renewKey)
        let (world, slots) = try await api.createWorld(
            title: title,
            frameCount: frameCount,
            idempotencyKey: key,
            lat: nil,
            lng: nil
        )
        // Persist the world id BEFORE uploading any frame so a crash/kill
        // mid-upload resumes onto this same world instead of orphaning it.
        try await sessions.setCreatedWorldId(world.id, forSession: session.id, in: session.directory)
        AppLog.upload.log("World created: \(world.id, privacy: .public), \(slots.count) upload slots (idempotency key \(key.uuidString, privacy: .public))")
        return (world, slots)
    }

    private func upload(
        session: CaptureStore.PendingSession,
        progress: @escaping (Int) -> Void,
        renewWorldKey: Bool = false
    ) async throws -> World {
        // Mutable local copy: a world-gone reset below clears the resume fields
        // so the rest of this run re-uploads EVERY frame to the fresh world.
        var manifest = session.manifest
        let frameCount = manifest.frames.count

        // World reuse (spec §6.1): if this session already minted a world, RESUME
        // it — re-presign fresh URLs (the originals may have expired) rather than
        // creating a second, orphaned world for the same capture.
        let world: World
        let slots: [FrameUpload]
        if let existingWorldId = manifest.createdWorldId {
            do {
                AppLog.upload.log("Resuming upload for world \(existingWorldId, privacy: .public), \(manifest.uploadedFrameIndices.count)/\(frameCount) already uploaded")
                (world, slots) = try await api.refreshUploads(worldId: existingWorldId)
                AppLog.upload.log("Refreshed \(slots.count) upload slots")
            } catch let error as APIError where error.isWorldGone {
                // The created world was deleted server-side (404 world_not_found):
                // retrying uploads:refresh can NEVER succeed. Clear the dead world
                // id + every uploaded flag (frames stay on disk), then start fresh
                // in this same run so the user's captured frames aren't stranded.
                // A DELIBERATE replacement world ⇒ a brand-new idempotency key.
                AppLog.upload.fault("resume: world \(existingWorldId, privacy: .public) gone server-side — starting fresh")
                try await sessions.resetWorldState(forSession: session.id, in: session.directory)
                manifest.createdWorldId = nil
                manifest.uploadedFrameIndices = []
                (world, slots) = try await createFreshWorld(session: session, frameCount: frameCount, renewKey: true)
            }
        } else {
            (world, slots) = try await createFreshWorld(session: session, frameCount: frameCount, renewKey: renewWorldKey)
        }

        // Count frames already confirmed uploaded (resume) toward progress.
        var done = manifest.uploadedFrameIndices.count
        AppLog.upload.log("resume: \(done)/\(frameCount) already uploaded")
        progress(done)
        for slot in slots.sorted(by: { $0.index < $1.index }) {
            // Skip frames a previous (possibly killed) run already confirmed.
            if manifest.isUploaded(slot.index) { continue }
            // Upload straight from the on-disk session file via the background
            // session; the transfer itself runs in URLSession, off the main thread.
            let fileURL = sessions.frameURL(index: slot.index, in: session.directory)
            do {
                try await frameUploader.upload(fileURL: fileURL, to: slot)
            } catch {
                AppLog.upload.error("Frame \(slot.index) upload failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
            // Mark uploaded immediately (crash-safe) so a later resume skips it.
            try await sessions.markFrameUploaded(index: slot.index, forSession: session.id, in: session.directory)
            done += 1
            progress(done)
        }

        // Include the captured poses so the backend gets pose-assisted stitching
        // data (spec §5). The field is optional on the contract.
        let poses = session.manifest.frames.map(\.wire)
        AppLog.upload.log("uploads complete, calling frames:done for \(world.id, privacy: .public)")
        do {
            try await api.framesDone(worldId: world.id, poses: poses)
        } catch is CancellationError {
            // Loud, never swallowed: a cancellation HERE means the flow ran in
            // a cancellable (view-lifecycle) context — it must be app-scoped
            // via UploadManager. The stranded-recovery kick will finish the
            // world on next scene activation either way.
            AppLog.upload.fault("frames:done for \(world.id, privacy: .public) CANCELLED mid-flow — upload flows must run app-scoped (UploadManager)!")
            throw CancellationError()
        }
        AppLog.upload.log("frames:done ok for \(world.id, privacy: .public) with \(poses.count) poses")
        await sessions.purge(id: session.id)
        return world
    }

    /// User-facing text for a failed attempt.
    private static func message(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return error.localizedDescription
    }
}
