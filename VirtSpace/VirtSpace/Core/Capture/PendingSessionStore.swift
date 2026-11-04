//
//  PendingSessionStore.swift
//  VirtSpace
//
//  Off-main access to capture-session manifests for the upload flows and the
//  Library (spec §10 R15).
//
//  Upload flows are main-actor code (they live in `UploadManager` and handle
//  main-actor API and model types), so calling `CaptureStore` from them made
//  every poses.json read and write synchronous disk I/O on the main thread.
//  This actor owns a `CaptureStore` and runs that I/O on its own executor.
//  Because every call is serialized through the actor, two concurrent updates
//  to one session's manifest can never interleave their read-modify-write and
//  lose one; a caller that awaits a write knows it is on disk before it goes
//  on (the idempotency key before `createWorld`, a frame's uploaded flag before
//  the next PUT). Keeping two flows off the same session is still the job of
//  `SessionClaims`.
//
//  The capture engine keeps using `CaptureStore` directly and synchronously on
//  its own serial queue: a shot must be on disk before the engine moves on.
//

import Foundation

actor PendingSessionStore {
    typealias PendingSession = CaptureStore.PendingSession

    private let store: CaptureStore

    init(store: CaptureStore = CaptureStore()) {
        self.store = store
    }

    func loadPending() -> [PendingSession] {
        store.loadPending()
    }

    /// Fresh copy of one session from disk (manifests change under a flow).
    func pending(_ id: UUID) -> PendingSession? {
        store.loadPending().first { $0.id == id }
    }

    func pendingSessionProgress(worldId: String) -> (uploaded: Int, total: Int)? {
        store.pendingSessionProgress(worldId: worldId)
    }

    func setCreatedWorldId(_ worldId: String, forSession id: UUID, in directory: URL) throws {
        try store.setCreatedWorldId(worldId, forSession: id, in: directory)
    }

    func resetWorldState(forSession id: UUID, in directory: URL) throws {
        try store.resetWorldState(forSession: id, in: directory)
    }

    func worldRequestId(forSession id: UUID, in directory: URL, renew: Bool) throws -> UUID {
        try store.worldRequestId(forSession: id, in: directory, renew: renew)
    }

    func recordFailedAttempt(forSession id: UUID, in directory: URL, countsTowardParking: Bool, at date: Date) throws {
        try store.recordFailedAttempt(forSession: id, in: directory, countsTowardParking: countsTowardParking, at: date)
    }

    func resetUploadAttempts(forSession id: UUID, in directory: URL) throws {
        try store.resetUploadAttempts(forSession: id, in: directory)
    }

    func markFrameUploaded(index: Int, forSession id: UUID, in directory: URL) throws {
        try store.markFrameUploaded(index: index, forSession: id, in: directory)
    }

    func markDepthUploaded(index: Int, forSession id: UUID, in directory: URL) throws {
        try store.markDepthUploaded(index: index, forSession: id, in: directory)
    }

    /// File-size reads, so off the main actor like the manifest I/O.
    func depthDeclarations(for session: PendingSession) -> [DepthFrameDeclaration]? {
        store.depthDeclarations(for: session.manifest.frames, in: session.directory)
    }

    func purge(id: UUID) {
        store.purge(id: id)
    }

    /// Pure path arithmetic, no I/O — callable without a hop.
    nonisolated func frameURL(index: Int, in directory: URL) -> URL {
        store.frameURL(index: index, in: directory)
    }

    nonisolated func depthURL(index: Int, in directory: URL) -> URL {
        store.depthURL(index: index, in: directory)
    }
}
