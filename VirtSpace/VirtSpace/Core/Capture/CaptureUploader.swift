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

import Foundation
import OSLog

final class CaptureUploader {
    /// Expected full-sphere frame count — derived from the capture pattern
    /// (Phase 0.5 densified layout = 28) so nothing hardcodes the old 16.
    static let expectedFrameCount = TargetLayout.targets().count

    private let api: APIClient
    private let store: CaptureStore
    private let frameUploader: FrameUploader

    init(api: APIClient, store: CaptureStore = CaptureStore(), frameUploader: FrameUploader = FrameUploader()) {
        self.api = api
        self.store = store
        self.frameUploader = frameUploader
    }

    // MARK: - Upload

    /// Upload one finished capture session. `progress` receives the number of
    /// frames uploaded so far (0…frameCount). On success the local session is
    /// purged; on failure it stays on disk for `resumePending()`.
    @discardableResult
    func upload(result: CaptureResult, progress: @escaping (Int) -> Void = { _ in }) async throws -> World {
        let pending = store.loadPending()
        guard let session = pending.first(where: { $0.id == result.sessionID }) else {
            throw APIError.server(0, "Capture session not found on disk")
        }
        return try await upload(session: session, progress: progress)
    }

    /// Retry every complete session left on disk (called at launch / on the
    /// capture screen appearing). Returns the worlds started; failures stay
    /// on disk for next time. Incomplete sessions older than a day are dead
    /// (the capture UI can't resume mid-scan yet) and get cleaned up.
    @discardableResult
    func resumePending(progress: @escaping (Int) -> Void = { _ in }) async -> [World] {
        var uploaded: [World] = []
        for session in store.loadPending() {
            if session.manifest.isComplete {
                if let world = try? await upload(session: session, progress: progress) {
                    uploaded.append(world)
                }
            } else if Date().timeIntervalSince(session.manifest.createdAt) > 86_400 {
                // Permanently discarding the session — if it already minted a
                // backend world, best-effort delete it so it doesn't linger as
                // an orphan in `uploading` (the server-side 24 h reaper is the
                // backstop if this delete never lands).
                if let worldId = session.manifest.createdWorldId {
                    try? await api.deleteWorld(id: worldId)
                }
                store.purge(id: session.id)
            }
        }
        return uploaded
    }

    // MARK: - Stranded-session completion

    /// Cheap, idempotent recovery for the exact stranded state a cancelled
    /// view-lifecycle flow used to leave behind: createdWorldId set AND every
    /// frame flagged uploaded, but frames:done never sent (the world sits in
    /// `uploading` forever server-side). Goes straight to frames:done (with
    /// poses) and purges the session on success. Kicked by UploadManager at
    /// launch and on every scenePhase → .active. Returns sessions completed.
    @discardableResult
    func completeStrandedSessions() async -> Int {
        var completed = 0
        for session in store.loadPending() {
            let manifest = session.manifest
            guard
                let worldId = manifest.createdWorldId,
                manifest.isComplete,
                manifest.frames.count > 0,
                manifest.uploadedFrameIndices.count >= manifest.frames.count
            else { continue }
            AppLog.upload.log("Stranded session \(session.id.uuidString, privacy: .public): \(manifest.uploadedFrameIndices.count)/\(manifest.frames.count) frames already uploaded, world \(worldId, privacy: .public) — going straight to frames:done")
            do {
                let poses = manifest.frames.map {
                    FramePose(
                        index: $0.index,
                        timestamp: $0.timestamp,
                        transform: $0.transform,
                        intrinsics: $0.intrinsics,
                        exposureLocked: $0.exposureLocked
                    )
                }
                AppLog.upload.log("uploads complete, calling frames:done for \(worldId, privacy: .public)")
                try await api.framesDone(worldId: worldId, poses: poses)
                AppLog.upload.log("frames:done ok for \(worldId, privacy: .public) with \(poses.count) poses (stranded recovery)")
                store.purge(id: session.id)
                completed += 1
            } catch is CancellationError {
                AppLog.upload.fault("frames:done for stranded world \(worldId, privacy: .public) hit CancellationError — this flow must be app-scoped (UploadManager), investigate!")
            } catch let error as APIError where error.isWorldGone {
                // The stranded world was deleted server-side (404 world_not_found):
                // frames:done can never land. Clear the dead world id + uploaded
                // flags (frames stay on disk), then start a fresh upload in this
                // same run so the user's 28 frames aren't stranded forever.
                AppLog.upload.fault("resume: world \(worldId, privacy: .public) gone server-side — starting fresh")
                store.resetWorldState(forSession: session.id, in: session.directory)
                if let fresh = store.loadPending().first(where: { $0.id == session.id }),
                   (try? await upload(session: fresh, progress: { _ in })) != nil {
                    completed += 1
                }
            } catch {
                AppLog.upload.error("Stranded-session frames:done failed for \(worldId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return completed
    }

    // MARK: - Internals

    /// Mint a brand-new backend world for this session and persist its id BEFORE
    /// any frame uploads (crash-safe: a kill mid-upload resumes onto this world
    /// instead of orphaning it). Quota edge: if `createWorld` is refused for
    /// quota (429), the session is intentionally left pending on disk — NOT
    /// discarded — so it retries once the user's allowance frees up.
    private func createFreshWorld(session: CaptureStore.PendingSession, frameCount: Int) async throws -> (World, [FrameUpload]) {
        let title = "Scan \(Date().formatted(date: .abbreviated, time: .shortened))"
        AppLog.upload.log("Upload start: session \(session.id.uuidString, privacy: .public), \(frameCount) frames")
        do {
            let (world, slots) = try await api.createWorld(title: title, frameCount: frameCount)
            // Persist the world id BEFORE uploading any frame so a crash/kill
            // mid-upload resumes onto this same world instead of orphaning it.
            store.setCreatedWorldId(world.id, forSession: session.id, in: session.directory)
            AppLog.upload.log("World created: \(world.id, privacy: .public), \(slots.count) upload slots")
            return (world, slots)
        } catch APIError.quota {
            AppLog.upload.log("createWorld refused for quota (429) — keeping session \(session.id.uuidString, privacy: .public) pending, will retry when allowance frees up")
            throw APIError.quota
        }
    }

    private func upload(session: CaptureStore.PendingSession, progress: @escaping (Int) -> Void) async throws -> World {
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
                AppLog.upload.fault("resume: world \(existingWorldId, privacy: .public) gone server-side — starting fresh")
                store.resetWorldState(forSession: session.id, in: session.directory)
                manifest.createdWorldId = nil
                manifest.uploadedFrameIndices = []
                (world, slots) = try await createFreshWorld(session: session, frameCount: frameCount)
            }
        } else {
            (world, slots) = try await createFreshWorld(session: session, frameCount: frameCount)
        }

        // Count frames already confirmed uploaded (resume) toward progress.
        var done = manifest.uploadedFrameIndices.count
        AppLog.upload.log("resume: \(done)/\(frameCount) already uploaded")
        progress(done)
        for slot in slots.sorted(by: { $0.index < $1.index }) {
            // Skip frames a previous (possibly killed) run already confirmed.
            if manifest.isUploaded(slot.index) { continue }
            // Upload straight from the on-disk session file via the background
            // session. This runs in a non-isolated async context, never MainActor.
            let fileURL = store.frameURL(index: slot.index, in: session.directory)
            do {
                try await frameUploader.upload(fileURL: fileURL, to: slot)
            } catch {
                AppLog.upload.error("Frame \(slot.index) upload failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
            // Mark uploaded immediately (crash-safe) so a later resume skips it.
            store.markFrameUploaded(index: slot.index, forSession: session.id, in: session.directory)
            done += 1
            progress(done)
        }

        // Include the captured poses so the backend gets pose-assisted stitching
        // data (spec §5). The field is optional on the contract.
        let poses = session.manifest.frames.map {
            FramePose(
                index: $0.index,
                timestamp: $0.timestamp,
                transform: $0.transform,
                intrinsics: $0.intrinsics,
                exposureLocked: $0.exposureLocked
            )
        }
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
        store.purge(id: session.id)
        return world
    }
}
