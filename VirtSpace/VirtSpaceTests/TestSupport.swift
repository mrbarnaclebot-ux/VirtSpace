//
//  TestSupport.swift
//  VirtSpaceTests
//
//  Fixtures and fakes shared by the suites.
//
//  HARD RULE: nothing here may touch the network or the app's real capture
//  directory. Stores are rooted in a per-test temp directory and every backend
//  call goes through `FakeUploadAPI` — the uploader talks to `CaptureUploadAPI`
//  precisely so these tests never need a server (spec §10 R13).
//

import Foundation
import simd
@testable import VirtSpace

// MARK: - Store fixtures

/// A CaptureStore rooted in a fresh temp directory, plus the sessions written
/// into it. Deleted by the OS with the temp dir; `cleanUp()` is available for
/// tidiness.
final class StoreFixture {
    let root: URL
    let store: CaptureStore

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("virtspace-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = CaptureStore(baseDirectory: root)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Write a complete capture session (frames + manifest) to disk.
    @discardableResult
    func makeCompleteSession(frameCount: Int = 2) throws -> CaptureStore.PendingSession {
        let session = try store.createSession(expectedFrameCount: frameCount)
        for index in 0..<frameCount {
            let pose = CaptureStore.FramePose(
                index: index,
                timestamp: Double(index),
                transform: matrix_identity_float4x4,
                intrinsics: matrix_identity_float3x3,
                exposureLocked: true
            )
            try store.saveFrame(Data([0xFF, 0xD8, 0xFF]), pose: pose, in: session)
        }
        return pending(session.id)!
    }

    /// Re-read a session from disk (manifests change under the uploader).
    func pending(_ id: UUID) -> CaptureStore.PendingSession? {
        store.loadPending().first { $0.id == id }
    }

    func manifest(_ id: UUID) -> CaptureStore.Manifest? {
        pending(id)?.manifest
    }
}

// MARK: - Model builders

enum Fixtures {
    /// Worlds are Decodable-only in production; build them the same way the
    /// app does, from JSON.
    static func world(id: String = "world-1", status: String = "uploading") -> World {
        let json = """
        {"id": "\(id)", "title": "Test Scan", "status": "\(status)"}
        """.data(using: .utf8)!
        // A failure here means the World contract changed — fail loudly.
        return try! JSONDecoder().decode(World.self, from: json)
    }

    /// `batch` tags the URLs, so a refreshed presign is distinguishable.
    static func slots(count: Int, batch: String = "upload") -> [FrameUpload] {
        (0..<count).map {
            FrameUpload(
                index: $0,
                key: "frames/\($0).jpg",
                url: "https://example.invalid/\(batch)/\($0)",
                method: "PUT",
                headers: ["Content-Type": "image/jpeg"]
            )
        }
    }

    static func depthSlots(count: Int) -> [FrameUpload] {
        (0..<count).map {
            FrameUpload(
                index: $0,
                key: "captures/c/depth_\($0).png",
                url: "https://example.invalid/depth/\($0)",
                method: "PUT",
                headers: ["Content-Type": "image/png"]
            )
        }
    }

    /// An APIError.network wrapping a genuine "device is offline" URLError.
    static var offline: APIError {
        .network(URLError(.notConnectedToInternet))
    }

    static var worldGone: APIError {
        .notFound
    }
}

// MARK: - Fakes

/// In-memory stand-in for the backend. Records every call and lets each test
/// script the outcomes it needs.
final class FakeUploadAPI: CaptureUploadAPI, @unchecked Sendable {
    /// Idempotency keys seen by `createWorld`, in order.
    private(set) var createKeys: [UUID?] = []
    private(set) var refreshedWorldIds: [String] = []
    private(set) var framesDoneWorldIds: [String] = []
    private(set) var deletedWorldIds: [String] = []
    /// The `depthFrames` declaration each create / refresh call sent.
    private(set) var createDepthFrames: [[DepthFrameDeclaration]?] = []
    private(set) var refreshDepthFrames: [[DepthFrameDeclaration]?] = []
    /// Poses sent with the last frames:done.
    private(set) var lastPoses: [FramePose]?
    /// Depth slots handed back whenever a call asked for depth.
    var depthSlotCount = 0

    /// Per-call behaviour. Defaults are "everything works".
    var onCreateWorld: ((UUID?) throws -> (World, [FrameUpload]))?
    var onRefreshUploads: ((String) throws -> (World, [FrameUpload]))?
    var onFramesDone: ((String) throws -> Void)?

    var createCount: Int { createKeys.count }

    func createWorld(
        title: String,
        frameCount: Int,
        depthFrames: [DepthFrameDeclaration]?,
        idempotencyKey: UUID?,
        lat: Double?,
        lng: Double?
    ) async throws -> (World, [FrameUpload], [FrameUpload]) {
        createKeys.append(idempotencyKey)
        createDepthFrames.append(depthFrames)
        let depth = depthFrames == nil ? [] : Fixtures.depthSlots(count: depthSlotCount)
        if let onCreateWorld {
            let (world, slots) = try onCreateWorld(idempotencyKey)
            return (world, slots, depth)
        }
        return (Fixtures.world(), Fixtures.slots(count: frameCount), depth)
    }

    func refreshUploads(worldId: String, depthFrames: [DepthFrameDeclaration]?) async throws -> (World, [FrameUpload], [FrameUpload]) {
        refreshedWorldIds.append(worldId)
        refreshDepthFrames.append(depthFrames)
        let depth = depthFrames == nil ? [] : Fixtures.depthSlots(count: depthSlotCount)
        if let onRefreshUploads {
            let (world, slots) = try onRefreshUploads(worldId)
            return (world, slots, depth)
        }
        return (Fixtures.world(id: worldId), Fixtures.slots(count: 2), depth)
    }

    func framesDone(worldId: String, poses: [FramePose]?) async throws {
        framesDoneWorldIds.append(worldId)
        lastPoses = poses
        try onFramesDone?(worldId)
    }

    func deleteWorld(id: String) async throws {
        deletedWorldIds.append(id)
    }
}

/// Frame uploads that never leave the process.
final class FakeFrameUploader: FrameUploading, @unchecked Sendable {
    /// Frame (JPEG) slot indices uploaded, in order.
    private(set) var uploadedIndices: [Int] = []
    /// Depth slot indices uploaded, in order.
    private(set) var uploadedDepthIndices: [Int] = []
    var error: Error?
    /// Depth slot indices whose PUT fails.
    var failingDepthIndices: Set<Int> = []
    /// Per-slot scripted outcome, checked before everything else.
    var onUpload: ((FrameUpload) throws -> Void)?
    /// Each PUT stays in flight until this many are (bounded, so a serial
    /// uploader finishes instead of hanging); `maxInFlight` records the peak.
    var holdUntilInFlight = 0
    private var inFlight = 0
    private(set) var maxInFlight = 0

    func upload(fileURL: URL, to slot: FrameUpload) async throws {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        for _ in 0..<1_000 where inFlight < holdUntilInFlight { await Task.yield() }
        try onUpload?(slot)
        if slot.key.contains("depth_") {
            if failingDepthIndices.contains(slot.index) { throw APIError.server(500, "depth put failed") }
            uploadedDepthIndices.append(slot.index)
            return
        }
        if let error { throw error }
        uploadedIndices.append(slot.index)
    }
}

/// A clock the tests move by hand, so backoff windows are exercised without
/// sleeping.
final class TestClock: @unchecked Sendable {
    private(set) var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = start
    }

    func advance(by interval: TimeInterval) {
        current = current.addingTimeInterval(interval)
    }

    var now: () -> Date { { self.current } }
}
