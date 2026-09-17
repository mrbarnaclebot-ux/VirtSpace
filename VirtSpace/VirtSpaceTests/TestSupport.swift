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

    static func slots(count: Int) -> [FrameUpload] {
        (0..<count).map {
            FrameUpload(
                index: $0,
                key: "frames/\($0).jpg",
                url: "https://example.invalid/upload/\($0)",
                method: "PUT",
                headers: ["Content-Type": "image/jpeg"]
            )
        }
    }

    /// An APIError.network wrapping a genuine "device is offline" URLError.
    static var offline: APIError {
        .network(URLError(.notConnectedToInternet))
    }

    static var worldGone: APIError {
        .server(404, "world_not_found")
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

    /// Per-call behaviour. Defaults are "everything works".
    var onCreateWorld: ((UUID?) throws -> (World, [FrameUpload]))?
    var onRefreshUploads: ((String) throws -> (World, [FrameUpload]))?
    var onFramesDone: ((String) throws -> Void)?

    var createCount: Int { createKeys.count }

    func createWorld(
        title: String,
        frameCount: Int,
        idempotencyKey: UUID?,
        lat: Double?,
        lng: Double?
    ) async throws -> (World, [FrameUpload]) {
        createKeys.append(idempotencyKey)
        if let onCreateWorld { return try onCreateWorld(idempotencyKey) }
        return (Fixtures.world(), Fixtures.slots(count: frameCount))
    }

    func refreshUploads(worldId: String) async throws -> (World, [FrameUpload]) {
        refreshedWorldIds.append(worldId)
        if let onRefreshUploads { return try onRefreshUploads(worldId) }
        return (Fixtures.world(id: worldId), Fixtures.slots(count: 2))
    }

    func framesDone(worldId: String, poses: [FramePose]?) async throws {
        framesDoneWorldIds.append(worldId)
        try onFramesDone?(worldId)
    }

    func deleteWorld(id: String) async throws {
        deletedWorldIds.append(id)
    }
}

/// Frame uploads that never leave the process.
final class FakeFrameUploader: FrameUploading, @unchecked Sendable {
    private(set) var uploadedIndices: [Int] = []
    var error: Error?

    func upload(fileURL: URL, to slot: FrameUpload) async throws {
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
