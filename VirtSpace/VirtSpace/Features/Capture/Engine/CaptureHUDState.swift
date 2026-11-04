//
//  CaptureHUDState.swift
//  VirtSpace
//
//  The observable surface of a guided capture (spec §10 R14): everything the
//  capture UI renders, and nothing else. Split out of CaptureEngine so the
//  boundary between "state machine running on a private queue" and "state
//  SwiftUI observes on the main actor" is a type boundary rather than a naming
//  convention (`published` vs `@ObservationIgnored`) inside one class.
//
//  Isolation: `@MainActor`, always. CaptureEngine is the sole writer and only
//  ever writes through its `publish` hop; the views are read-only consumers.
//  The properties are therefore plain `var` — the engine needs write access
//  from another file — but treat them as private(set) to everything but the
//  engine.
//

import ARKit
import CoreGraphics
import Foundation
import Observation
import UIKit
import simd

// MARK: - PaintedShot

/// A per-shot "paint the sphere" event (Stage B3 deliverable 1): the captured
/// camera pose plus a small thumbnail of what was shot, so the capture layer
/// can hang a textured quad on the virtual sphere in that direction. Emitted
/// once per successful shot; the thumbnail is generated off the main actor.
struct PaintedShot: Identifiable {
    let index: Int
    /// The CAPTURED camera-to-world transform (ARKit portrait convention).
    let transform: simd_float4x4
    /// Intrinsics of the captured frame — used to size the quad to the FOV.
    let intrinsics: simd_float3x3
    /// Downscaled (~512 px) copy of the captured JPEG.
    let thumbnail: UIImage

    var id: Int { index }

    /// Image width the intrinsics refer to, approximated from the principal
    /// point (cx ≈ width/2). Avoids threading the sensor resolution through.
    var approxImageWidth: Float { 2 * intrinsics.columns.2.x }
    var approxImageHeight: Float { 2 * intrinsics.columns.2.y }
}

extension PaintedShot: Equatable {
    // Index is unique per capture; identity is enough (UIImage isn't Equatable).
    static func == (lhs: PaintedShot, rhs: PaintedShot) -> Bool { lhs.index == rhs.index }
}

// MARK: - CaptureHUDState

@MainActor
@Observable
final class CaptureHUDState {
    /// Constructing the state touches no main-actor state — only the defaults
    /// below — so the engine can own one from its own (nonisolated) init.
    nonisolated init() {}

    // MARK: - Session

    var state: CaptureEngineState = .idle

    /// The capture pattern. Immutable for the object's lifetime, so the engine
    /// reads it straight from its own queue without a hop.
    nonisolated let targets: [CaptureTarget] = TargetLayout.targets()

    /// Per-target captured flag, indexed like `targets`.
    var capturedFlags: [Bool] = Array(repeating: false, count: TargetLayout.targetCount)

    // MARK: - Aim

    /// Degrees between the camera forward and the current target.
    var angularDistanceDegrees: Double = 180
    /// Signed aim hints, degrees: yaw > 0 → turn right; pitch > 0 → look up.
    var yawDeltaDegrees: Double = 0
    var pitchDeltaDegrees: Double = 0
    var isSteady = false
    /// Meters of translation from the first shot's position (parallax coaching).
    var driftMeters: Float = 0
    /// Whether AE/AWB locked before shot 0 (the HUD pill + coaching notice).
    var exposureLocked = false
    /// Tracking warning to surface, or nil.
    var warning: String?

    // MARK: - HUD geometry (Stage B2)

    /// Latest camera-to-world transform (ARKit portrait camera convention).
    var cameraTransform: simd_float4x4 = matrix_identity_float4x4
    /// Latest camera intrinsics + the sensor resolution they refer to.
    var cameraIntrinsics: simd_float3x3 = matrix_identity_float3x3
    var imageResolution: CGSize = .zero
    /// World-space direction per target (empty until the heading basis locks).
    var targetDirections: [simd_float3] = []
    /// Dwell completion [0, 1] for the reticle's ring fill.
    var dwellProgress: Double = 0
    /// The live ARSession for the camera preview (device only, nil in sim).
    var previewSession: ARSession?

    // MARK: - Paint-the-sphere state (Stage B3)

    /// Accumulated painted shots, one per successful capture. The camera layer
    /// (device SceneKit / simulator Canvas) observes this and hangs a textured
    /// quad on the virtual sphere for each new entry.
    var paintedShots: [PaintedShot] = []

    // MARK: - Thermal state (Stage B3)

    /// Latest `ProcessInfo.thermalState`, mirrored onto the main actor so the
    /// HUD can coach ("warming up") and the preview can drop its frame rate.
    var thermalState: ProcessInfo.ThermalState = .nominal
    /// True when the session is paused because the device hit `.critical`.
    /// Cleared by `CaptureEngine.resumeFromThermal()`.
    var isThermallyPaused = false

    // MARK: - Derived

    var capturedCount: Int { capturedFlags.lazy.filter { $0 }.count }

    var currentTarget: CaptureTarget? {
        switch state {
        case .ready(let i), .capturing(let i):
            return targets.indices.contains(i) ? targets[i] : nil
        default:
            return nil
        }
    }

    var isAligned: Bool { AlignmentMath.isAligned(angularDistanceDegrees: angularDistanceDegrees) }

    /// Parallax coaching text (spec §9), or nil while the user stays put.
    var driftWarning: String? {
        if driftMeters > AlignmentMath.driftHardWarnMeters {
            return "You've moved \(String(format: "%.1f", driftMeters)) m — go back to your spot"
        }
        if driftMeters > AlignmentMath.driftWarnMeters {
            return "Stay on your spot — pivot, don't walk"
        }
        return nil
    }

    // MARK: - Reset

    /// Clear everything session-scoped and enter `state`. Called by the engine
    /// when a capture starts, is cancelled, or is reset for another scan.
    func applyReset(state: CaptureEngineState) {
        self.state = state
        capturedFlags = Array(repeating: false, count: targets.count)
        angularDistanceDegrees = 180
        yawDeltaDegrees = 0
        pitchDeltaDegrees = 0
        isSteady = false
        driftMeters = 0
        exposureLocked = false
        warning = nil
        cameraTransform = matrix_identity_float4x4
        cameraIntrinsics = matrix_identity_float3x3
        imageResolution = .zero
        targetDirections = []
        dwellProgress = 0
        previewSession = nil
        paintedShots = []
        isThermallyPaused = false
        // thermalState is left as-is: it reflects the hardware, not the session.
    }
}
