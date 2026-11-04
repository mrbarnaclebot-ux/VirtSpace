//
//  PendingSessionStoreTests.swift
//  VirtSpaceTests
//
//  Upload-side manifest I/O must stay off the main thread and must never lose
//  an update when two writes to one session race (spec §10 R15).
//

import Foundation
import Synchronization
import Testing
@testable import VirtSpace

/// Records whether directory listings ran on the main thread.
nonisolated final class ThreadRecordingFileManager: FileManager, @unchecked Sendable {
    private let listedOnMain = Mutex<[Bool]>([])

    var listings: [Bool] { listedOnMain.withLock { $0 } }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        let onMain = Thread.isMainThread
        listedOnMain.withLock { $0.append(onMain) }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}

@Suite("PendingSessionStore")
struct PendingSessionStoreTests {
    @Test("Concurrent manifest updates to one session all land")
    func concurrentUpdatesAreSerialized() async throws {
        let fixture = StoreFixture()
        let session = try fixture.makeCompleteSession(frameCount: 1)
        let sessions = PendingSessionStore(store: fixture.store)
        let writers = 40

        await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<writers {
                group.addTask {
                    try await sessions.markFrameUploaded(index: index, forSession: session.id, in: session.directory)
                }
                group.addTask {
                    try await sessions.recordFailedAttempt(
                        forSession: session.id,
                        in: session.directory,
                        countsTowardParking: true,
                        at: Date()
                    )
                }
            }
        }

        let manifest = fixture.manifest(session.id)
        #expect(manifest?.uploadedFrameIndices == Array(0..<writers))
        #expect(manifest?.attemptCount == writers)
    }

    @Test("Manifest I/O awaited from the main actor runs off the main thread")
    @MainActor
    func ioIsNotMainActorIsolated() async throws {
        let fixture = StoreFixture()
        try fixture.makeCompleteSession(frameCount: 1)
        let recorder = ThreadRecordingFileManager()
        let sessions = PendingSessionStore(store: CaptureStore(fileManager: recorder, baseDirectory: fixture.root))

        MainActor.assertIsolated()
        let pending = await sessions.loadPending()

        #expect(pending.count == 1)
        #expect(recorder.listings == [false])
    }
}
