//
//  RoomScanStore.swift
//  VirtSpace
//
//  Crash-safe on-disk room scans (spec §5.3). Separate from CaptureStore: a
//  walk is up to 5000 keyframes, and CaptureStore rewrites poses.json on every
//  shot, which would be quadratic I/O here. Layout under
//  Application Support/room_scans/<uuid>/:
//
//    images/Image_000001.jpg …  one per committed keyframe, written atomically
//    frames.jsonl               one RoomScanFrame per line, appended after its image
//    scan.json                  RoomScanManifest, rewritten at state changes only
//    bundle.zip                 built after Finish (RoomScanBundle)
//
//  Stateless: every call goes to disk, so any queue may use it. Two flows are
//  kept off one session by SessionClaims (the engine holds the claim while
//  scanning, upload flows after).
//

import Foundation

/// One committed keyframe. Index parity: `images/Image_<index>.jpg`,
/// trajectory entry `index - 1` and intrinsics entry `index - 1`.
nonisolated struct RoomScanFrame: Codable, Equatable, Sendable {
    /// 1-based, contiguous. Assigned by the writer once the JPEG encoded.
    var index: Int
    /// ARKit world_from_camera (`ARFrame.camera.transform`), column-major.
    let transform: [Float]
    /// Pinhole intrinsics for the encoded JPEG pixels.
    let fx: Float
    let fy: Float
    let cx: Float
    let cy: Float
    let width: Int
    let height: Int
}

nonisolated struct RoomScanManifest: Codable, Sendable {
    let sessionID: UUID
    let createdAt: Date
    /// The user tapped Finish (or an interrupted scan was recovered).
    var isFinished = false
    var frameCount = 0
    /// Size of bundle.zip once built: the create's `bundle_bytes`.
    var bundleBytes: Int?
    var worldId: String?
    /// Idempotency-Key for `POST /v1/worlds`, persisted before the request
    /// (spec §10 R4). The session id on the first mint.
    var worldRequestId: UUID?
    var bundleUploaded = false
    var attemptCount = 0
    var lastAttemptAt: Date?

    init(sessionID: UUID, createdAt: Date) {
        self.sessionID = sessionID
        self.createdAt = createdAt
    }

    /// Same budget and backoff as a spot scan (CaptureStore.Manifest).
    var isParked: Bool { attemptCount >= CaptureStore.Manifest.maxAutomaticAttempts }

    func isReadyForAutomaticRetry(now: Date) -> Bool {
        guard !isParked else { return false }
        guard let lastAttemptAt else { return true }
        let delays = CaptureStore.Manifest.backoffDelays
        return now >= lastAttemptAt.addingTimeInterval(delays[min(max(attemptCount - 1, 0), delays.count - 1)])
    }
}

nonisolated final class RoomScanStore: Sendable {
    let baseDirectory: URL

    init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.baseDirectory = support.appendingPathComponent("room_scans", isDirectory: true)
        }
    }

    // MARK: Paths

    func directory(for id: UUID) -> URL { baseDirectory.appendingPathComponent(id.uuidString, isDirectory: true) }
    func imageURL(for id: UUID, index: Int) -> URL {
        directory(for: id).appendingPathComponent("images/" + RoomScanBundle.imageName(index))
    }
    func bundleURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("bundle.zip") }
    private func framesURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("frames.jsonl") }
    private func manifestURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("scan.json") }

    // MARK: Capture

    func createSession(id: UUID, at date: Date = Date()) throws {
        try FileManager.default.createDirectory(
            at: directory(for: id).appendingPathComponent("images", isDirectory: true),
            withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: framesURL(for: id).path, contents: nil)
        try write(RoomScanManifest(sessionID: id, createdAt: date))
    }

    /// Image first (atomic), then its record line. A kill between the two
    /// leaves an image without a record, which `committedFrames` ignores.
    func appendFrame(_ jpeg: Data, _ frame: RoomScanFrame, to id: UUID) throws {
        try jpeg.write(to: imageURL(for: id, index: frame.index), options: .atomic)
        let handle = try FileHandle(forWritingTo: framesURL(for: id))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONEncoder().encode(frame) + Data([0x0A]))
    }

    /// The contiguous 1…n prefix whose record parsed and whose image exists.
    /// A torn last line (kill mid-append) is dropped.
    func committedFrames(for id: UUID) -> [RoomScanFrame] {
        guard let data = try? Data(contentsOf: framesURL(for: id)) else { return [] }
        let decoder = JSONDecoder()
        var frames: [RoomScanFrame] = []
        for line in data.split(separator: 0x0A) {
            guard let frame = try? decoder.decode(RoomScanFrame.self, from: Data(line)),
                  frame.index == frames.count + 1,
                  FileManager.default.fileExists(atPath: imageURL(for: id, index: frame.index).path)
            else { break }
            frames.append(frame)
        }
        return frames
    }

    /// Seal the scan at its committed frames. Returns the frame count.
    @discardableResult
    func finish(_ id: UUID) throws -> Int {
        let count = committedFrames(for: id).count
        try update(id) {
            $0.isFinished = true
            $0.frameCount = count
        }
        return count
    }

    // MARK: Manifest

    func manifest(_ id: UUID) -> RoomScanManifest? {
        guard let data = try? Data(contentsOf: manifestURL(for: id)) else { return nil }
        return try? JSONDecoder().decode(RoomScanManifest.self, from: data)
    }

    func update(_ id: UUID, _ body: (inout RoomScanManifest) -> Void) throws {
        guard var manifest = manifest(id) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: manifestURL(for: id).path])
        }
        body(&manifest)
        try write(manifest)
    }

    private func write(_ manifest: RoomScanManifest) throws {
        try JSONEncoder().encode(manifest).write(to: manifestURL(for: manifest.sessionID), options: .atomic)
    }

    /// Every session on disk, oldest first.
    func pending() -> [RoomScanManifest] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)) ?? []
        return entries
            .compactMap { UUID(uuidString: $0.lastPathComponent).flatMap(manifest) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Once bundle.zip holds them, the loose JPEGs only cost disk.
    func removeImages(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id).appendingPathComponent("images", isDirectory: true))
    }

    /// Manifest first (the session vanishes from `pending()` at once), then
    /// the directory.
    func purge(_ id: UUID) {
        try? FileManager.default.removeItem(at: manifestURL(for: id))
        try? FileManager.default.removeItem(at: directory(for: id))
    }
}
