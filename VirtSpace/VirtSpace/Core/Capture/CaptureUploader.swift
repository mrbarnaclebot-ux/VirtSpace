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
        let (world, slots) = try await api.createWorld(title: title, frameCount: frameCount)

        progress(0)
        var done = 0
        for slot in slots.sorted(by: { $0.index < $1.index }) {
            let data = try store.loadFrameData(index: slot.index, in: session.directory)
            try await frameUploader.upload(data, to: slot)
            done += 1
            progress(done)
        }

        try await api.framesDone(worldId: world.id)
        store.purge(id: session.id)
        return world
    }
}
