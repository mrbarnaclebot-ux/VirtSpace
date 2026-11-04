//
//  CaptureUploadAPI.swift
//  VirtSpace
//
//  The exact backend surface `CaptureUploader` uses — nothing more.
//
//  Narrowing it to a protocol keeps the uploader's resume state machine (world
//  reuse, idempotency keys, backoff, parking) testable without a network: the
//  unit tests drive it with an in-memory fake and a temp-directory
//  CaptureStore. `APIClient` is the only production conformer.
//

import Foundation

protocol CaptureUploadAPI {
    /// Returns the world, its frame upload slots and its depth upload slots
    /// (empty unless `depthFrames` was non-nil and the backend presigned them).
    func createWorld(
        title: String,
        frameCount: Int,
        depthFrames: [DepthFrameDeclaration]?,
        idempotencyKey: UUID?,
        lat: Double?,
        lng: Double?
    ) async throws -> (World, [FrameUpload], [FrameUpload])

    func refreshUploads(
        worldId: String,
        depthFrames: [DepthFrameDeclaration]?
    ) async throws -> (World, [FrameUpload], [FrameUpload])

    func framesDone(worldId: String, poses: [FramePose]?) async throws

    func deleteWorld(id: String) async throws
}

extension APIClient: CaptureUploadAPI {}
