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

        var isComplete: Bool { frames.count >= expectedFrameCount }

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case expectedFrameCount = "expected_frame_count"
            case createdAt = "created_at"
            case frames
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

    /// Remove a session after a successful upload (or user cancel).
    func purge(id: UUID) {
        manifests[id] = nil
        try? fileManager.removeItem(at: directoryURL(for: id))
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
