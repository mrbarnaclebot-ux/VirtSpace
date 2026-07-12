//
//  CaptureStore.swift
//  VirtSpace
//
//  Crash-proof on-disk capture sessions (spec §6.1: every frame + pose is
//  written the moment it's taken; a killed app resumes the upload on next
//  launch). Layout: Application Support/captures/<uuid>/frame_<i>.jpg plus
//  poses.json (rewritten atomically after every shot). Sessions survive until
//  `purge(id:)` after a successful upload.
//

import Foundation
import simd

final class CaptureStore {
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
        /// Whether AE/AWB/AF were locked when this frame was taken.
        let exposureLocked: Bool

        init(index: Int, timestamp: TimeInterval, transform: simd_float4x4, intrinsics: simd_float3x3, exposureLocked: Bool) {
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

        var isComplete: Bool { frames.count >= expectedFrameCount }

        func isUploaded(_ index: Int) -> Bool { uploadedFrameIndices.contains(index) }

        init(
            sessionID: UUID,
            expectedFrameCount: Int,
            createdAt: Date,
            frames: [FramePose],
            createdWorldId: String? = nil,
            uploadedFrameIndices: [Int] = []
        ) {
            self.sessionID = sessionID
            self.expectedFrameCount = expectedFrameCount
            self.createdAt = createdAt
            self.frames = frames
            self.createdWorldId = createdWorldId
            self.uploadedFrameIndices = uploadedFrameIndices
        }

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case expectedFrameCount = "expected_frame_count"
            case createdAt = "created_at"
            case frames
            case createdWorldId = "created_world_id"
            case uploadedFrameIndices = "uploaded_frame_indices"
        }

        // Custom decode so manifests written before the resume fields existed
        // (older sessions on disk) still load — the new fields default cleanly.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = try c.decode(UUID.self, forKey: .sessionID)
            expectedFrameCount = try c.decode(Int.self, forKey: .expectedFrameCount)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            frames = try c.decode([FramePose].self, forKey: .frames)
            createdWorldId = try c.decodeIfPresent(String.self, forKey: .createdWorldId)
            uploadedFrameIndices = try c.decodeIfPresent([Int].self, forKey: .uploadedFrameIndices) ?? []
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

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
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

    /// Persist one shot: frame_<i>.jpg written atomically, then poses.json
    /// rewritten atomically. After this returns, the shot survives a crash.
    ///
    /// Threading: intentionally synchronous — the write MUST complete before we
    /// return so the shot is crash-safe (spec §6.1). It is only ever called
    /// from the engine's background serial queue (never the main actor), so the
    /// blocking disk I/O stays off the UI thread. Do not call from MainActor.
    func saveFrame(_ jpegData: Data, pose: FramePose, in session: Session) throws {
        try jpegData.write(to: frameURL(index: pose.index, in: session.directory), options: .atomic)
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
    func setCreatedWorldId(_ worldId: String, forSession id: UUID, in directory: URL) {
        mutateManifest(id: id, in: directory) { $0.createdWorldId = worldId }
    }

    /// Mark one frame confirmed-uploaded (crash-safe). Called after each frame's
    /// PUT succeeds so a resume re-PUTs only what's missing.
    func markFrameUploaded(index: Int, forSession id: UUID, in directory: URL) {
        mutateManifest(id: id, in: directory) { m in
            guard !m.uploadedFrameIndices.contains(index) else { return }
            m.uploadedFrameIndices.append(index)
            m.uploadedFrameIndices.sort()
        }
    }

    /// Read-modify-write poses.json atomically. Reads the on-disk manifest first
    /// (resume sessions from a previous launch aren't in the in-memory cache),
    /// falling back to the cache. Runs off the main actor from the upload flow.
    private func mutateManifest(id: UUID, in directory: URL, _ body: (inout Manifest) -> Void) {
        guard var manifest = (try? readManifest(in: directory)) ?? manifests[id] else { return }
        body(&manifest)
        manifests[id] = manifest
        try? writeManifest(manifest, to: directory)
    }

    // MARK: - Reading back

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
        let fm = fileManager
        ioQueue.async { try? fm.removeItem(at: url) }
    }

    // MARK: - Paths & JSON

    func directoryURL(for id: UUID) -> URL {
        baseDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func frameURL(index: Int, in directory: URL) -> URL {
        directory.appendingPathComponent("frame_\(index).jpg")
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
