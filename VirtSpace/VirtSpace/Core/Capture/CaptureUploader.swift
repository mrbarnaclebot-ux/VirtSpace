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
    static let expectedFrameCount = 16

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
                store.purge(id: session.id)
            }
        }
        return uploaded
    }

    // MARK: - Internals

    private func upload(session: CaptureStore.PendingSession, progress: @escaping (Int) -> Void) async throws -> World {
        let frameCount = session.manifest.frames.count
        let title = "Scan \(Date().formatted(date: .abbreviated, time: .shortened))"
        AppLog.upload.log("Upload start: session \(session.id.uuidString, privacy: .public), \(frameCount) frames")

        let (world, slots) = try await api.createWorld(title: title, frameCount: frameCount)
        AppLog.upload.log("World created: \(world.id, privacy: .public), \(slots.count) upload slots")

        progress(0)
        var done = 0
        for slot in slots.sorted(by: { $0.index < $1.index }) {
            // loadFrameData reads off the main actor: this method runs in a
            // non-isolated async context (cooperative pool), never on MainActor.
            let data = try store.loadFrameData(index: slot.index, in: session.directory)
            do {
                try await frameUploader.upload(data, to: slot)
            } catch {
                AppLog.upload.error("Frame \(slot.index) upload failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
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
        try await api.framesDone(worldId: world.id, poses: poses)
        AppLog.upload.log("frames:done ok for \(world.id, privacy: .public) with \(poses.count) poses")
        store.purge(id: session.id)
        return world
    }
}
