//
//  CaptureStore.swift
//  VirtSpace
//
//  Crash-proof on-disk capture sessions (spec §6.1: every frame + pose is
//  written the moment it's taken; a killed app resumes the upload on next
//  launch). Layout: Application Support/captures/<uuid>/frame_<i>.jpg, an
//  optional depth_<i>.png (LiDAR, spec §5.2) per frame, plus poses.json (rewritten atomically after every shot). Sessions survive until
//  `purge(id:)` after a successful upload.
//

import Foundation
import simd

/// Confined to whichever single executor its owner uses — the engine queue for
/// a live capture, a `PendingSessionStore` actor for upload flows and the
/// Library. `manifests` is the only mutable state and is never shared between
/// owners: each owns its own instance. The blocking disk I/O is the whole point
/// (see `saveFrame`), so this is deliberately NOT an actor and deliberately NOT
/// main-actor isolated; main-actor code reaches it through
/// `PendingSessionStore`, never directly (spec §10 R15).
nonisolated final class CaptureStore: @unchecked Sendable {
    // MARK: - Types

    /// Per-frame pose metadata for the server stitcher (spec §5:
    /// pose-assisted reprojection). Matrices are column-major float arrays.
    struct FramePose: Codable {
        let index: Int
        let timestamp: TimeInterval
        /// Camera-to-world transform, 16 floats, column-major.
        let transform: [Float]
        /// Camera intrinsics, 9 floats, column-major (matches the JPEG pixels).
        let intrinsics: [Float]
        /// Whether AE/AWB were locked when this frame was taken.
        let exposureLocked: Bool
        /// Capture v2 (spec §5.2), optional so older manifests still decode:
        /// the exposure this frame was taken at, for gain compensation.
        let iso: Float?
        /// Seconds.
        let exposureDuration: Double?
        /// Median depth (metres) of ARKit raw feature points in view.
        let featureDepthMedian: Float?
        /// Size of depth_<index>.png, set iff that file was written to disk.
        /// On the wire it is sent only once the file is UPLOADED.
        var depth: FrameDepthSize?

        init(
            index: Int,
            timestamp: TimeInterval,
            transform: simd_float4x4,
            intrinsics: simd_float3x3,
            exposureLocked: Bool,
            iso: Float? = nil,
            exposureDuration: Double? = nil,
            featureDepthMedian: Float? = nil,
            depth: FrameDepthSize? = nil
        ) {
            self.index = index
            self.timestamp = timestamp
            self.transform = (0..<4).flatMap { column -> [Float] in
                let c = transform[column]
                return [c.x, c.y, c.z, c.w]
            }
            self.intrinsics = (0..<3).flatMap { column -> [Float] in
                let c = intrinsics[column]
                return [c.x, c.y, c.z]
            }
            self.exposureLocked = exposureLocked
            self.iso = iso
            self.exposureDuration = exposureDuration
            self.featureDepthMedian = featureDepthMedian
            self.depth = depth
        }

        /// The frames:done wire shape. Nil fields are omitted, never sent as
        /// JSON null (the backend 400s a null). `depth` rides along only when
        /// the depth file actually reached R2.
        func wire(depthUploaded: Bool) -> VirtSpace.FramePose {
            VirtSpace.FramePose(
                index: index,
                timestamp: timestamp,
                transform: transform,
                intrinsics: intrinsics,
                exposureLocked: exposureLocked,
                iso: iso,
                exposureDuration: exposureDuration,
                featureDepthMedian: featureDepthMedian,
                depth: depthUploaded ? depth : nil
            )
        }
    }

    /// poses.json contents.
    struct Manifest: Codable {
        let sessionID: UUID
        let expectedFrameCount: Int
        let createdAt: Date
        var frames: [FramePose]
        /// The backend world id minted by `createWorld` for this session. Set
        /// once the world exists so a resumed upload REUSES it (re-presigning via
        /// uploads:refresh) instead of creating a duplicate, orphaned world.
        var createdWorldId: String?
        /// Frame indices confirmed uploaded to R2. A resume skips these and only
        /// re-PUTs the rest. Written after each confirmed upload → crash-safe.
        var uploadedFrameIndices: [Int]
        /// Frame indices whose depth_<i>.png is confirmed uploaded. Only these
        /// poses carry `depth` on frames:done (spec §5.2).
        var uploadedDepthIndices: [Int]
        /// Idempotency-Key for this session's `POST /v1/worlds`, persisted
        /// BEFORE the request goes out. A kill between request and response
        /// therefore can't double-create: the retry replays the same key and
        /// the backend returns the same world. Regenerated (and re-persisted,
        /// still before the request) only when we deliberately mint a
        /// REPLACEMENT world because the old one was deleted server-side.
        var worldRequestId: UUID?
        /// Automatic upload attempts that failed for a real reason. Drives the
        /// backoff schedule and, at `maxAutomaticAttempts`, parks the session.
        /// Reset to 0 by a user-initiated retry.
        var attemptCount: Int
        /// When the last attempt ran (successful or not) — the backoff clock.
        var lastAttemptAt: Date?

        /// Failed attempts after which automatic retrying stops entirely: no
        /// more uploads, and crucially no more automatic fresh-world minting
        /// (each mint is billable — the R4 finding). The session then waits for
        /// an explicit user "Retry upload" or "Discard".
        static let maxAutomaticAttempts = 5

        /// How long to wait after the nth failed attempt before trying again:
        /// 1 min, 5 min, 30 min, 2 h, 6 h. (Parking at 5 attempts means the
        /// last entry only applies if that budget is ever raised.)
        static let backoffDelays: [TimeInterval] = [60, 300, 1_800, 7_200, 21_600]

        var isComplete: Bool { frames.count >= expectedFrameCount }

        func isUploaded(_ index: Int) -> Bool { uploadedFrameIndices.contains(index) }

        /// True once automatic retrying has given up on this session.
        var isParked: Bool { attemptCount >= Self.maxAutomaticAttempts }

        /// Earliest time an automatic retry may run again; nil when no attempt
        /// has been made yet (retry immediately). An attempt that didn't count
        /// toward parking (quota/offline, `attemptCount` still 0) still waits
        /// out the first tier, so a foreground kick can't hammer the backend.
        var nextAutomaticAttemptAt: Date? {
            guard let lastAttemptAt else { return nil }
            let index = min(max(attemptCount - 1, 0), Self.backoffDelays.count - 1)
            return lastAttemptAt.addingTimeInterval(Self.backoffDelays[index])
        }

        /// Whether an automatic sweep may work this session right now.
        func isReadyForAutomaticRetry(now: Date = Date()) -> Bool {
            guard !isParked else { return false }
            guard let next = nextAutomaticAttemptAt else { return true }
            return now >= next
        }

        init(
            sessionID: UUID,
            expectedFrameCount: Int,
            createdAt: Date,
            frames: [FramePose],
            createdWorldId: String? = nil,
            uploadedFrameIndices: [Int] = [],
            uploadedDepthIndices: [Int] = [],
            worldRequestId: UUID? = nil,
            attemptCount: Int = 0,
            lastAttemptAt: Date? = nil
        ) {
            self.sessionID = sessionID
            self.expectedFrameCount = expectedFrameCount
            self.createdAt = createdAt
            self.frames = frames
            self.createdWorldId = createdWorldId
            self.uploadedFrameIndices = uploadedFrameIndices
            self.uploadedDepthIndices = uploadedDepthIndices
            self.worldRequestId = worldRequestId
            self.attemptCount = attemptCount
            self.lastAttemptAt = lastAttemptAt
        }

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case expectedFrameCount = "expected_frame_count"
            case createdAt = "created_at"
            case frames
            case createdWorldId = "created_world_id"
            case uploadedFrameIndices = "uploaded_frame_indices"
            case uploadedDepthIndices = "uploaded_depth_indices"
            case worldRequestId = "world_request_id"
            case attemptCount = "attempt_count"
            case lastAttemptAt = "last_attempt_at"
        }

        // Custom decode so manifests written before the resume/attempt fields
        // existed (older sessions on disk) still load — the new fields default
        // cleanly: no world request id yet, zero attempts, never attempted.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = try c.decode(UUID.self, forKey: .sessionID)
            expectedFrameCount = try c.decode(Int.self, forKey: .expectedFrameCount)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            frames = try c.decode([FramePose].self, forKey: .frames)
            createdWorldId = try c.decodeIfPresent(String.self, forKey: .createdWorldId)
            uploadedFrameIndices = try c.decodeIfPresent([Int].self, forKey: .uploadedFrameIndices) ?? []
            uploadedDepthIndices = try c.decodeIfPresent([Int].self, forKey: .uploadedDepthIndices) ?? []
            worldRequestId = try c.decodeIfPresent(UUID.self, forKey: .worldRequestId)
            attemptCount = try c.decodeIfPresent(Int.self, forKey: .attemptCount) ?? 0
            lastAttemptAt = try c.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        }
    }

    /// Handle for a live capture session.
    struct Session {
        let id: UUID
        let directory: URL
    }

    /// A persisted session found on disk (possibly from a previous launch).
    struct PendingSession {
        let id: UUID
        let directory: URL
        let manifest: Manifest
    }

    // MARK: - State

    private let fileManager: FileManager
    private let baseDirectory: URL
    /// In-memory manifests for sessions created this launch (avoids
    /// read-modify-write of poses.json on every shot). Callers use the store
    /// from a single queue (the engine queue).
    private var manifests: [UUID: Manifest] = [:]
    /// Off-main queue for teardown I/O (session purge). Directory removal is
    /// slow, blocking I/O; on-device logs flagged `removeItemAtURL` running on
    /// the MAIN THREAD (hang-risk / excessive-I/O Faults). Keeping it here
    /// guarantees the delete never blocks the UI, regardless of caller.
    private let ioQueue = DispatchQueue(label: "com.virtspace.capture-store.io", qos: .utility)

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    /// `baseDirectory` overrides where sessions live; tests point it at a temp
    /// directory so they never touch the real captures folder.
    init(fileManager: FileManager = .default, baseDirectory: URL? = nil) {
        self.fileManager = fileManager
        if let baseDirectory {
            self.baseDirectory = baseDirectory
            return
        }
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.baseDirectory = support.appendingPathComponent("captures", isDirectory: true)
    }

    // MARK: - Session lifecycle

    func createSession(expectedFrameCount: Int) throws -> Session {
        let id = UUID()
        let directory = directoryURL(for: id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = Manifest(
            sessionID: id,
            expectedFrameCount: expectedFrameCount,
            createdAt: Date(),
            frames: []
        )
        manifests[id] = manifest
        try writeManifest(manifest, to: directory)
        return Session(id: id, directory: directory)
    }

    /// Persist one shot: frame_<i>.jpg and (when present) depth_<i>.png written
    /// atomically, then poses.json rewritten atomically. After this returns,
    /// the shot survives a crash. A depth file that can't be written never
    /// fails the shot: the pose just records no depth.
    ///
    /// Threading: intentionally synchronous — the write MUST complete before we
    /// return so the shot is crash-safe (spec §6.1). It is only ever called
    /// from the engine's background serial queue (never the main actor), so the
    /// blocking disk I/O stays off the UI thread. Do not call from MainActor.
    func saveFrame(_ jpegData: Data, depthPNG: Data? = nil, pose: FramePose, in session: Session) throws {
        try jpegData.write(to: frameURL(index: pose.index, in: session.directory), options: .atomic)
        var pose = pose
        if let depthPNG, pose.depth != nil {
            do {
                try depthPNG.write(to: depthURL(index: pose.index, in: session.directory), options: .atomic)
            } catch {
                pose.depth = nil
            }
        } else {
            pose.depth = nil
        }
        var manifest = manifests[session.id] ?? (try? readManifest(in: session.directory))
            ?? Manifest(sessionID: session.id, expectedFrameCount: pose.index + 1, createdAt: Date(), frames: [])
        manifest.frames.removeAll { $0.index == pose.index }
        manifest.frames.append(pose)
        manifest.frames.sort { $0.index < $1.index }
        manifests[session.id] = manifest
        try writeManifest(manifest, to: session.directory)
    }

    // MARK: - Resume state (world id + per-frame uploaded flags)

    /// Persist the backend world id for a session so a later resume reuses it
    /// (spec §6.1 crash-safe resume; never orphan a world). Idempotent.
    func setCreatedWorldId(_ worldId: String, forSession id: UUID, in directory: URL) throws {
        try mutateManifest(id: id, in: directory) { $0.createdWorldId = worldId }
    }

    /// Reset a session's server-side world binding so a resume starts completely
    /// fresh: clears the minted `createdWorldId` AND every per-frame uploaded
    /// flag, persisted atomically via the same manifest write path. Used only
    /// when the backend reports the created world is gone (404 / world_not_found)
    /// — the frames + poses (the real capture data) are left untouched on disk so
    /// they can be re-uploaded to a brand-new world.
    func resetWorldState(forSession id: UUID, in directory: URL) throws {
        try mutateManifest(id: id, in: directory) { m in
            m.createdWorldId = nil
            m.uploadedFrameIndices = []
            m.uploadedDepthIndices = []
        }
    }

    /// The Idempotency-Key to send with this session's `POST /v1/worlds`,
    /// PERSISTED BEFORE the caller makes that request (spec §10 R4).
    ///
    /// - `renew: false` — the key for this session's world. Reuses the stored
    ///   one if there is one; otherwise adopts the session's own UUID, so the
    ///   very first mint keys on the session id. Every retry of the same
    ///   logical request replays the same key, and the backend returns the same
    ///   world instead of minting (and billing) a second one.
    /// - `renew: true` — a brand-new key, for the one case where a NEW world is
    ///   genuinely wanted: the previous world was deleted server-side. Written
    ///   to disk before the request returns, so a kill in that window still
    ///   can't double-create — the retry replays the new key.
    ///
    /// Throws when the key can't be persisted (e.g. disk full). The caller must
    /// then NOT send the request: an unpersisted renewed key would be replaced
    /// by yet another one on the next attempt, and each could bill a world.
    @discardableResult
    func worldRequestId(forSession id: UUID, in directory: URL, renew: Bool = false) throws -> UUID {
        var assigned = id
        try mutateManifest(id: id, in: directory) { m in
            if renew || m.worldRequestId == nil {
                m.worldRequestId = renew ? UUID() : m.sessionID
            }
            assigned = m.worldRequestId ?? id
        }
        return assigned
    }

    /// Record that an upload attempt for this session just finished failing.
    /// `countsTowardParking` is false for failures that say nothing about the
    /// session's health — no connectivity, or a quota/credit refusal (429):
    /// those must never push a perfectly good capture toward being parked, but
    /// they do update the clock so the next automatic try still backs off.
    func recordFailedAttempt(
        forSession id: UUID,
        in directory: URL,
        countsTowardParking: Bool,
        at date: Date = Date()
    ) throws {
        try mutateManifest(id: id, in: directory) { m in
            if countsTowardParking { m.attemptCount += 1 }
            m.lastAttemptAt = date
        }
    }

    /// Clear the attempt counter — a user-initiated retry starts the automatic
    /// budget over (and un-parks the session).
    func resetUploadAttempts(forSession id: UUID, in directory: URL) throws {
        try mutateManifest(id: id, in: directory) { m in
            m.attemptCount = 0
            m.lastAttemptAt = nil
        }
    }

    /// Mark one frame confirmed-uploaded (crash-safe). Called after each frame's
    /// PUT succeeds so a resume re-PUTs only what's missing.
    func markFrameUploaded(index: Int, forSession id: UUID, in directory: URL) throws {
        try mutateManifest(id: id, in: directory) { m in
            guard !m.uploadedFrameIndices.contains(index) else { return }
            m.uploadedFrameIndices.append(index)
            m.uploadedFrameIndices.sort()
        }
    }

    /// Mark one frame's depth file confirmed-uploaded (crash-safe).
    func markDepthUploaded(index: Int, forSession id: UUID, in directory: URL) throws {
        try mutateManifest(id: id, in: directory) { m in
            guard !m.uploadedDepthIndices.contains(index) else { return }
            m.uploadedDepthIndices.append(index)
            m.uploadedDepthIndices.sort()
        }
    }

    /// Exact on-disk sizes of the session's depth files, for the create /
    /// refresh `depth_frames` declaration; nil when no frame has depth (the
    /// request then omits depth entirely). Derived from disk, so every retry
    /// under one idempotency key sends the same body. Missing or oversized
    /// files are left out: that frame just isn't uploaded with depth.
    func depthDeclarations(for frames: [FramePose], in directory: URL) -> [DepthFrameDeclaration]? {
        let declared = frames.compactMap { frame -> DepthFrameDeclaration? in
            guard frame.depth != nil,
                  let size = (try? fileManager.attributesOfItem(atPath: depthURL(index: frame.index, in: directory).path))?[.size] as? Int,
                  size > 0, size <= FrameDepth.maxPNGBytes
            else { return nil }
            return DepthFrameDeclaration(index: frame.index, bytes: size)
        }
        return declared.isEmpty ? nil : declared
    }

    /// Read-modify-write poses.json atomically. Reads the on-disk manifest first
    /// (resume sessions from a previous launch aren't in the in-memory cache),
    /// falling back to the cache. Not reentrant-safe on its own: concurrent
    /// callers must be serialized by the owner (`PendingSessionStore` does).
    /// Throws when there is no manifest to update or the write fails, so a
    /// caller never proceeds as if unpersisted state were on disk.
    private func mutateManifest(id: UUID, in directory: URL, _ body: (inout Manifest) -> Void) throws {
        guard var manifest = (try? readManifest(in: directory)) ?? manifests[id] else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: manifestURL(in: directory).path])
        }
        body(&manifest)
        try writeManifest(manifest, to: directory)
        manifests[id] = manifest
    }

    // MARK: - Reading back

    /// The backend world id a session has minted, if any (nil for sessions
    /// that never reached createWorld). Reads the on-disk manifest for
    /// sessions from a previous launch, falling back to the in-memory cache.
    func createdWorldId(forSession id: UUID, in directory: URL) -> String? {
        if let manifest = manifests[id] { return manifest.createdWorldId }
        return (try? readManifest(in: directory))?.createdWorldId
    }

    /// Client-truth upload progress for the world a pending (not yet purged)
    /// session minted: (frames confirmed uploaded, total expected), or nil when
    /// no pending session references `worldId`. The Library consults this on
    /// each refresh tick to render "Uploading i/N" — the server only knows the
    /// world is `uploading`, the manifest knows how far along it actually is.
    func pendingSessionProgress(worldId: String) -> (uploaded: Int, total: Int)? {
        guard
            let session = loadPending().first(where: { $0.manifest.createdWorldId == worldId })
        else { return nil }
        let manifest = session.manifest
        return (manifest.uploadedFrameIndices.count, manifest.expectedFrameCount)
    }

    /// All persisted sessions, complete or not (crash-recovery entry point).
    func loadPending() -> [PendingSession] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { url in
            guard
                let id = UUID(uuidString: url.lastPathComponent),
                let manifest = try? readManifest(in: url)
            else { return nil }
            return PendingSession(id: id, directory: url, manifest: manifest)
        }
        .sorted { $0.manifest.createdAt < $1.manifest.createdAt }
    }

    func loadFrameData(index: Int, in directory: URL) throws -> Data {
        try Data(contentsOf: frameURL(index: index, in: directory))
    }

    /// Remove a session after a successful upload (or user cancel). The
    /// in-memory manifest is dropped synchronously (cheap, preserves ordering
    /// on the caller's queue) but the actual directory removal — the slow,
    /// blocking part — is punted to `ioQueue` so it never runs on the main
    /// thread (see `ioQueue` docs: this was a flagged on-device Fault).
    func purge(id: UUID) {
        manifests[id] = nil
        let url = directoryURL(for: id)
        // Tombstone first (synchronous, single unlink): removing poses.json
        // makes the session invisible to loadPending() IMMEDIATELY, so a
        // resume/stranded-recovery flow racing the async directory removal can
        // never see a purged session and re-send frames:done for it. The slow
        // recursive removal stays off-thread below.
        try? fileManager.removeItem(at: manifestURL(in: url))
        // FileManager is documented thread-safe for file operations when no
        // delegate is set (none is here); the SDK simply doesn't mark it Sendable.
        nonisolated(unsafe) let fm = fileManager
        ioQueue.async { try? fm.removeItem(at: url) }
    }

    // MARK: - Paths & JSON

    func directoryURL(for id: UUID) -> URL {
        baseDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func frameURL(index: Int, in directory: URL) -> URL {
        directory.appendingPathComponent("frame_\(index).jpg")
    }

    func depthURL(index: Int, in directory: URL) -> URL {
        directory.appendingPathComponent("depth_\(index).png")
    }

    private func manifestURL(in directory: URL) -> URL {
        directory.appendingPathComponent("poses.json")
    }

    private func writeManifest(_ manifest: Manifest, to directory: URL) throws {
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL(in: directory), options: .atomic)
    }

    private func readManifest(in directory: URL) throws -> Manifest {
        let data = try Data(contentsOf: manifestURL(in: directory))
        return try decoder.decode(Manifest.self, from: data)
    }
}
