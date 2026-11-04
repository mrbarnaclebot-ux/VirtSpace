//
//  ShotPipeline.swift
//  VirtSpace
//
//  Everything that happens between "the dwell fired" and "the engine can move
//  to the next target" (spec §10 R14), extracted from CaptureEngine: take the
//  still, persist it crash-safely, kick off the paint thumbnail, and fire the
//  haptics. The exposure lock happens before shot 0, in the engine.
//
//  The pipeline owns no state-machine state — no target index, no dwell, no
//  running flag. It does the I/O and reports a `ShotOutcome` back to the engine
//  on the engine queue; the engine decides what that means for the walk-around.
//
//  Threading: `take` is called on the engine queue. The source's completion may
//  arrive on any queue, so it hops back to the engine queue before anything
//  else, and the outcome is always delivered there. Thumbnail downscaling runs
//  on its own utility queue and is never on the main actor.
//

import Foundation
import ImageIO
import OSLog
import UIKit
import simd

/// What one shot did. Delivered on the engine queue.
nonisolated enum ShotOutcome: Sendable {
    /// Captured and written to disk. `transform` is the CAPTURED camera pose —
    /// the engine pins the pivot origin from the first shot's.
    case saved(index: Int, transform: simd_float4x4)
    /// Recoverable: the camera didn't produce a frame. One missed shot mustn't
    /// kill a 28-shot walk-around — the engine re-arms the same target.
    case failed(index: Int, message: String)
    /// Unrecoverable: the frame couldn't be written to disk, so the session can
    /// no longer be completed. The engine fails the capture.
    case saveFailed(index: Int, message: String)
}

/// Confined to the engine queue, except `onPaintedShot`, which is called on
/// `thumbnailQueue` (and is only ever written during the engine's `init`,
/// before this object is shared with any other thread).
nonisolated final class ShotPipeline: @unchecked Sendable {
    /// Long edge of the paint-the-sphere thumbnail, in pixels.
    static let thumbnailMaxDimension: CGFloat = 512

    private let store: CaptureStore
    private let queue: DispatchQueue
    /// Background queue for downscaling paint thumbnails — never the main actor.
    private let thumbnailQueue = DispatchQueue(label: "com.virtspace.capture-thumbnails", qos: .utility)

    /// Whether AE/AWB locked before shot 0. Set by the engine (engine queue);
    /// stamped into every frame's persisted pose.
    var exposureLocked = false

    // MARK: - Hooks (set once by the engine)

    /// Whether the capture is still live. Checked on the engine queue the
    /// instant the still comes back, before anything is written to disk.
    var isCapturing: () -> Bool = { true }
    /// A finished paint thumbnail. **Called on `thumbnailQueue`**, not the
    /// engine queue — the engine hops to the main actor from here.
    var onPaintedShot: (PaintedShot) -> Void = { _ in }

    init(store: CaptureStore, queue: DispatchQueue) {
        self.store = store
        self.queue = queue
    }

    /// Clear per-capture state for a fresh session.
    func reset() {
        exposureLocked = false
    }

    // MARK: - One shot

    /// Take, persist and post-process frame `index`. `completion` is always
    /// delivered on the engine queue; it is not called at all if the capture
    /// stopped while the still was in flight.
    func take(
        index: Int,
        from source: CaptureSource,
        into session: CaptureStore.Session,
        totalTargets: Int,
        completion: @escaping @Sendable (ShotOutcome) -> Void
    ) {
        source.captureStill { [weak self] result in
            guard let self else { return }
            // The source may complete on any queue; everything below is engine
            // queue only.
            self.queue.async {
                guard self.isCapturing() else { return }
                completion(
                    self.finish(result, index: index, session: session, totalTargets: totalTargets)
                )
            }
        }
    }

    /// Engine queue: persist the still and run its side effects.
    private func finish(
        _ result: Result<CapturedStill, Error>,
        index: Int,
        session: CaptureStore.Session,
        totalTargets: Int
    ) -> ShotOutcome {
        let still: CapturedStill
        switch result {
        case .failure(let error):
            return .failed(
                index: index,
                message: "Shot failed — hold on the target again (\(error.localizedDescription))"
            )
        case .success(let value):
            still = value
        }

        let pose = CaptureStore.FramePose(
            index: index,
            timestamp: still.timestamp,
            transform: still.transform,
            intrinsics: still.intrinsics,
            exposureLocked: exposureLocked,
            iso: still.iso,
            exposureDuration: still.exposureDuration,
            featureDepthMedian: still.featureDepthMedian
        )
        do {
            try store.saveFrame(still.jpegData, pose: pose, in: session)
        } catch {
            return .saveFailed(
                index: index,
                message: "Couldn't save frame \(index + 1): \(error.localizedDescription)"
            )
        }
        AppLog.capture.log("Shot \(index + 1)/\(totalTargets) saved")

        paint(still, index: index)

        Self.shotHaptic()
        // Sweep-complete celebration, derived from TargetLayout (R12: these
        // were once dead literals from an older pattern). The final shot's
        // success haptic is the engine's, with `.finished`.
        if TargetLayout.celebrationIndices.contains(index) {
            Self.celebrationHaptic()
        }

        return .saved(index: index, transform: still.transform)
    }

    /// Paint the sphere (Stage B3 deliverable 1): downscale the JPEG to a
    /// ~512 px thumbnail off the main actor, then hand back a PaintedShot
    /// carrying the CAPTURED transform + intrinsics so the camera layer can
    /// hang a textured quad in that direction.
    private func paint(_ still: CapturedStill, index: Int) {
        let jpeg = still.jpegData
        let transform = still.transform
        let intrinsics = still.intrinsics
        thumbnailQueue.async { [weak self] in
            guard
                let self,
                let thumbnail = Self.makeThumbnail(from: jpeg, maxDimension: Self.thumbnailMaxDimension)
            else { return }
            self.onPaintedShot(
                PaintedShot(index: index, transform: transform, intrinsics: intrinsics, thumbnail: thumbnail)
            )
        }
    }

    // MARK: - Paint thumbnails

    /// Downscale JPEG data to a thumbnail no larger than `maxDimension` on its
    /// long edge, using ImageIO so we never fully decode the full-res image.
    /// Runs on `thumbnailQueue` (utility QoS) — never the main actor.
    static func makeThumbnail(from data: Data, maxDimension: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: - Haptics (feedback generators are main-actor only)

    /// One shot landed.
    static func shotHaptic() {
        Task { @MainActor in
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    /// A ring finished, or the whole sphere did.
    static func celebrationHaptic() {
        Task { @MainActor in
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}
