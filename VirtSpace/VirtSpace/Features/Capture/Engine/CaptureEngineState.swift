//
//  CaptureEngineState.swift
//  VirtSpace
//
//  The engine's published state machine and its result (see CaptureEngine).
//

import Foundation

// MARK: - State

enum CaptureEngineState: Equatable {
    case idle
    case starting
    case ready(targetIndex: Int)
    case capturing(targetIndex: Int)
    case advancing
    case finished(CaptureResult)
    case failed(String)

    /// Payload-free `.finished` test, for view code that has to branch on the
    /// state without binding the result (`if case` doesn't compose inside a
    /// ViewBuilder condition).
    var isFinished: Bool {
        if case .finished = self { return true }
        return false
    }
}

/// A completed full-sphere capture (28 frames), persisted on disk and ready to upload.
struct CaptureResult: Equatable {
    let sessionID: UUID
    let directory: URL
    let frameCount: Int
}
