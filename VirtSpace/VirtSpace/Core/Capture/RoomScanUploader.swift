//
//  RoomScanUploader.swift
//  VirtSpace
//
//  A finished room scan to the backend (spec §5.3 item 3): build bundle.zip →
//  `POST /v1/worlds` (capture_type room_scan, Idempotency-Key = session id,
//  persisted first) → one background PUT of the ZIP → frames:done → purge.
//  Every step's result is persisted, so a resume after a kill picks up where
//  it stopped: a minted world is re-signed with uploads:refresh, never minted
//  again; an uploaded bundle goes straight to frames:done.
//
//  Same retry policy as CaptureUploader (spec §10 R4): automatic sweeps back
//  off and park after 5 real failures; quota and offline failures don't count;
//  a 403 on the PUT is an expired presign, re-signed once (R25).
//
//  Disk work (manifests, the ZIP build) runs off the main actor in `io`.
//

import Foundation
import OSLog

/// The backend calls a room-scan upload needs. `APIClient` is the production
/// conformer; tests can fake it.
protocol RoomScanUploadAPI {
    func createRoomScan(frameCount: Int, bundleBytes: Int, title: String, idempotencyKey: UUID) async throws -> (world: World, upload: FrameUpload, maxFrames: Int?)
    func refreshBundleUpload(worldId: String) async throws -> FrameUpload
    func framesDone(worldId: String, poses: [FramePose]?) async throws
    func deleteWorld(id: String) async throws
}

extension APIClient: RoomScanUploadAPI {}

final class RoomScanUploader {
    /// What the upload overlay says.
    enum Stage: Equatable {
        case preparing
        case uploading(bytes: Int)
        case finishing

        var message: String {
            switch self {
            case .preparing: "Preparing your scan…"
            case .uploading(let bytes): "Uploading scan · \(bytes.formatted(.byteCount(style: .file)))"
            case .finishing: "Finishing up…"
            }
        }
    }

    /// UserDefaults key for the last `max_frames` the server announced: the
    /// next scan's cap (5000 until a create has answered).
    static let maxFramesKey = "roomScan.maxFrames"

    static var maxFrames: Int {
        let stored = UserDefaults.standard.integer(forKey: maxFramesKey)
        return stored > 0 ? min(stored, RoomScanBundle.maxFrames) : RoomScanBundle.maxFrames
    }

    private let api: RoomScanUploadAPI
    private let store: RoomScanStore
    private let frameUploader: FrameUploading
    private let now: () -> Date

    init(
        api: RoomScanUploadAPI,
        store: RoomScanStore = RoomScanStore(),
        frameUploader: FrameUploading = FrameUploader(maxAttempts: 1, coordinator: .bundles),
        now: @escaping () -> Date = Date.init
    ) {
        self.api = api
        self.store = store
        self.frameUploader = frameUploader
        self.now = now
    }

    // MARK: Flows

    /// Upload the scan the engine just finished. The engine's claim on the
    /// session is handed over and released here. nil = the server already
    /// had the world (nothing new to show).
    func uploadFinished(sessionID id: UUID, stage: @escaping (Stage) -> Void) async throws -> World? {
        do {
            let world = try await attempt(id, stage: stage)
            await SessionClaims.shared.release(id)
            return world
        } catch {
            await SessionClaims.shared.release(id)
            throw error
        }
    }

    /// Retry every room scan left on disk (launch, foreground, Try again).
    /// An interrupted scan (killed mid-walk) is sealed as parked: it uploads
    /// only when the user asks, never behind their back.
    func resumePending(userInitiated: Bool, stage: @escaping (Stage) -> Void = { _ in }) async -> ResumeOutcome {
        var worlds: [World] = []
        var completed = 0
        var failure: String?
        var deferrals: [String] = []
        for manifest in await read({ [store] in store.pending() }) {
            let id = manifest.sessionID
            guard await SessionClaims.shared.claim(id) else {
                deferrals.append("already uploading")
                continue
            }
            switch await resume(manifest, userInitiated: userInitiated, stage: stage) {
            case .uploaded(let world):
                completed += 1
                if let world { worlds.append(world) }
            case .failed(let reason): failure = reason
            case .deferred(let reason): deferrals.append(reason)
            case .skipped: break
            }
            await SessionClaims.shared.release(id)
        }
        if completed > 0 { return .succeeded(worlds) }
        if let failure { return .failed(reason: failure) }
        if let deferral = deferrals.first { return .deferred(reason: deferral) }
        return .nothingToResume
    }

    private enum SessionOutcome {
        case uploaded(World?), failed(String), deferred(String), skipped
    }

    /// One claimed session of a resume sweep.
    private func resume(_ manifest: RoomScanManifest, userInitiated: Bool, stage: @escaping (Stage) -> Void) async -> SessionOutcome {
        let id = manifest.sessionID
        if !manifest.isFinished {
            // Unfinished and unclaimed: the scan that wrote it is gone.
            let count = (try? await io { [store] in try store.finish(id) }) ?? 0
            if count == 0 {
                await read { [store] in store.purge(id) }
                return .skipped
            }
            try? await io { [store] in try store.update(id) { $0.attemptCount = CaptureStore.Manifest.maxAutomaticAttempts } }
            AppLog.upload.log("Room scan \(id.uuidString, privacy: .public) was interrupted at \(count) frames — parked for the user")
            if !userInitiated { return .deferred("interrupted scan waiting for the user") }
        }
        if userInitiated {
            try? await io { [store] in try store.update(id) { $0.attemptCount = 0; $0.lastAttemptAt = nil } }
        } else if !manifest.isReadyForAutomaticRetry(now: now()) {
            return .deferred(manifest.isParked ? "paused after failed attempts" : "waiting before the next automatic retry")
        }
        do {
            return .uploaded(try await attempt(id, stage: stage))
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Room scans waiting on disk. An unfinished, unclaimed one is an
    /// interrupted scan and counts as parked.
    func pendingSummary() async -> PendingUploadSummary {
        var summary = PendingUploadSummary()
        for manifest in await read({ [store] in store.pending() }) {
            if !manifest.isFinished, await SessionClaims.shared.isClaimed(manifest.sessionID) { continue }
            summary.pendingCount += 1
            if manifest.isParked || !manifest.isFinished { summary.parkedCount += 1 }
        }
        return summary
    }

    /// Delete every room scan not being worked on, and best-effort its world.
    func discardPending() async -> Int {
        var discarded = 0
        for manifest in await read({ [store] in store.pending() }) {
            let id = manifest.sessionID
            guard await SessionClaims.shared.claim(id) else { continue }
            if let worldId = manifest.worldId { try? await api.deleteWorld(id: worldId) }
            await read { [store] in store.purge(id) }
            await SessionClaims.shared.release(id)
            discarded += 1
        }
        return discarded
    }

    // MARK: One attempt

    private func attempt(_ id: UUID, stage: @escaping (Stage) -> Void) async throws -> World? {
        do {
            return try await run(id, stage: stage)
        } catch {
            if !(error is CancellationError) {
                let counts = error.countsTowardUploadParking
                let at = now()
                try? await io { [store] in
                    try store.update(id) {
                        if counts { $0.attemptCount += 1 }
                        $0.lastAttemptAt = at
                    }
                }
                AppLog.upload.error("Room scan \(id.uuidString, privacy: .public) upload failed (counts: \(counts)): \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
    }

    private func run(_ id: UUID, stage: @escaping (Stage) -> Void) async throws -> World? {
        guard var manifest = await read({ [store] in store.manifest(id) }) else {
            throw APIError.localState("This scan is no longer on this phone.")
        }
        // 1. The bundle. Built once; its size is the create's bundle_bytes,
        // so every retry under one idempotency key sends the same body.
        let bundleURL = store.bundleURL(for: id)
        if manifest.bundleBytes == nil || !FileManager.default.fileExists(atPath: bundleURL.path) {
            stage(.preparing)
            let (bytes, count) = try await io { [store] in
                let frames = store.committedFrames(for: id)
                let bytes = try RoomScanBundle.build(
                    frames: frames,
                    imageURL: { store.imageURL(for: id, index: $0) },
                    to: bundleURL)
                try store.update(id) {
                    $0.bundleBytes = bytes
                    $0.frameCount = frames.count
                }
                // The ZIP is the scan from here on; don't hold it twice.
                store.removeImages(id)
                return (bytes, frames.count)
            }
            manifest.bundleBytes = bytes
            manifest.frameCount = count
            AppLog.upload.log("Room scan \(id.uuidString, privacy: .public): bundle built, \(count) frames, \(bytes) bytes")
        }
        let bytes = manifest.bundleBytes ?? 0
        stage(.uploading(bytes: bytes))

        // 2. The world, and a fresh presign for the PUT.
        var world: World?
        var slot: FrameUpload?
        if let worldId = manifest.worldId, !manifest.bundleUploaded {
            do {
                slot = try await api.refreshBundleUpload(worldId: worldId)
            } catch let error as APIError where error.isWorldGone {
                // Deleted server-side: a deliberate replacement, new key.
                AppLog.upload.fault("Room scan world \(worldId, privacy: .public) is gone — minting a replacement")
                try await io { [store] in try store.update(id) { $0.worldId = nil; $0.bundleUploaded = false } }
                manifest.worldId = nil
                (world, slot) = try await mint(id, manifest: manifest, renewKey: true)
            }
        } else if manifest.worldId == nil {
            (world, slot) = try await mint(id, manifest: manifest, renewKey: false)
        }
        guard let worldId = world?.id ?? manifest.worldId else { throw APIError.invalidResponse }

        // 3. One PUT of the whole ZIP (background session, long timeout).
        if var current = slot {
            do {
                try await frameUploader.upload(fileURL: bundleURL, to: current)
            } catch let error as APIError where error.isExpiredPresign {
                current = try await api.refreshBundleUpload(worldId: worldId)
                try await frameUploader.upload(fileURL: bundleURL, to: current)
            }
            try await io { [store] in try store.update(id) { $0.bundleUploaded = true } }
            AppLog.upload.log("Room scan bundle uploaded for world \(worldId, privacy: .public)")
        }

        // 4. frames:done (empty body): the server checks the object's size
        // and flips uploading → reconstructing.
        stage(.finishing)
        do {
            try await api.framesDone(worldId: worldId, poses: nil)
        } catch let error as APIError where error.isWorldGone {
            try? await io { [store] in try store.update(id) { $0.worldId = nil; $0.bundleUploaded = false } }
            throw error
        }
        AppLog.upload.log("frames:done ok for room scan world \(worldId, privacy: .public)")
        await read { [store] in store.purge(id) }
        return world
    }

    /// `POST /v1/worlds`, key persisted first, world id persisted before any
    /// byte is PUT (spec §10 R4). A 409 for a spent key renews it once.
    private func mint(_ id: UUID, manifest: RoomScanManifest, renewKey: Bool) async throws -> (World, FrameUpload) {
        let title = "Room \(manifest.createdAt.formatted(date: .abbreviated, time: .shortened))"
        func create(renew: Bool) async throws -> (world: World, upload: FrameUpload, maxFrames: Int?) {
            let key = try await io { [store] in
                var key = id
                try store.update(id) {
                    if renew || $0.worldRequestId == nil { $0.worldRequestId = renew ? UUID() : $0.sessionID }
                    key = $0.worldRequestId ?? id
                }
                return key
            }
            return try await api.createRoomScan(frameCount: manifest.frameCount, bundleBytes: manifest.bundleBytes ?? 0, title: title, idempotencyKey: key)
        }
        let created: (world: World, upload: FrameUpload, maxFrames: Int?)
        do {
            created = try await create(renew: renewKey)
        } catch let error as APIError where error.isIdempotencyConflict {
            created = try await create(renew: true)
        }
        let worldId = created.world.id
        try await io { [store] in try store.update(id) { $0.worldId = worldId } }
        if let maxFrames = created.maxFrames, maxFrames > 0 {
            UserDefaults.standard.set(maxFrames, forKey: Self.maxFramesKey)
        }
        AppLog.upload.log("Room scan world created: \(worldId, privacy: .public), \(manifest.frameCount) frames")
        return (created.world, created.upload)
    }

    /// Run blocking disk work off the main actor.
    private func io<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .utility, operation: work).value
    }

    private func read<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .utility, operation: work).value
    }
}
