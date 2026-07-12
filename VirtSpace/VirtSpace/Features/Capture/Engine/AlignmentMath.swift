//
//  AlignmentMath.swift
//  VirtSpace
//
//  Pure math for the guided-capture loop (spec §6.1, §9): camera↔target
//  angular distance, steadiness from frame-to-frame rotation rate (ARKit
//  exposes no gyro directly — we derive angular velocity from consecutive
//  camera transforms), a dwell state machine (aligned + steady for 300 ms →
//  auto-fire), and translation drift for parallax coaching.
//

import Foundation
import simd

enum AlignmentMath {
    /// Camera counts as "on target" within this cone half-angle.
    static let alignmentThresholdDegrees: Double = 6
    /// Camera counts as "steady" below this rotation rate (rad/s) — shots
    /// taken while turning would blur and break the stitch.
    static let steadinessThresholdRadPerSec: Double = 0.12
    /// Aligned + steady must hold continuously this long before auto-fire.
    static let dwellSeconds: TimeInterval = 0.30
    /// Parallax coaching (spec §9): soft warning past this many meters of
    /// translation from the first shot's position…
    static let driftWarnMeters: Float = 0.25
    /// …hard warning past this. The user is walking, not pivoting.
    static let driftHardWarnMeters: Float = 0.5

    // MARK: - Transform helpers

    /// Camera forward = -Z column of the camera transform (ARKit convention).
    static func forward(of transform: simd_float4x4) -> simd_float3 {
        let z = transform.columns.2
        return simd_normalize(simd_float3(-z.x, -z.y, -z.z))
    }

    /// Camera position = translation column of the transform.
    static func position(of transform: simd_float4x4) -> simd_float3 {
        let t = transform.columns.3
        return simd_float3(t.x, t.y, t.z)
    }

    // MARK: - Alignment

    /// Angular distance between two directions, in degrees [0, 180].
    static func angularDistanceDegrees(_ a: simd_float3, _ b: simd_float3) -> Double {
        let d = simd_dot(simd_normalize(a), simd_normalize(b))
        let clamped = max(-1, min(1, Double(d)))
        return acos(clamped) * 180 / .pi
    }

    static func isAligned(angularDistanceDegrees distance: Double) -> Bool {
        distance <= alignmentThresholdDegrees
    }

    /// Signed aim corrections from the camera forward to a target, in degrees.
    /// `yaw` positive = turn right; `pitch` positive = look up. Near-vertical
    /// targets have no meaningful yaw (returns 0).
    static func signedDeltas(cameraForward f: simd_float3, targetDirection t: simd_float3) -> (yaw: Double, pitch: Double) {
        let up = simd_float3(0, 1, 0)
        let fn = simd_normalize(f)
        let tn = simd_normalize(t)

        let pitch = (asin(max(-1, min(1, Double(tn.y)))) - asin(max(-1, min(1, Double(fn.y))))) * 180 / .pi

        // Horizontal projections; degenerate when either vector is near-vertical.
        let fh = simd_float3(fn.x, 0, fn.z)
        let th = simd_float3(tn.x, 0, tn.z)
        guard simd_length(fh) > 0.05, simd_length(th) > 0.05 else {
            return (0, pitch)
        }
        let fhn = simd_normalize(fh)
        let thn = simd_normalize(th)
        // atan2 of the signed area gives left-positive; negate for right-positive.
        let leftPositive = atan2(Double(simd_dot(simd_cross(fhn, thn), up)), Double(simd_dot(fhn, thn)))
        return (-leftPositive * 180 / .pi, pitch)
    }

    // MARK: - Steadiness

    /// Angular velocity (rad/s) implied by two consecutive camera transforms.
    /// Rotation-only: extracts the 3x3 rotation of each transform and measures
    /// the relative rotation angle over the elapsed time.
    static func rotationRate(from previous: simd_float4x4, to current: simd_float4x4, dt: TimeInterval) -> Double {
        guard dt > 0 else { return 0 }
        let qPrev = simd_quatf(rotationMatrix(of: previous))
        let qCurr = simd_quatf(rotationMatrix(of: current))
        let relative = qPrev.inverse * qCurr
        // simd_quatf.angle ∈ [0, 2π]; fold to the short way around.
        var angle = Double(relative.angle)
        if angle > .pi { angle = 2 * .pi - angle }
        return angle / dt
    }

    static func isSteady(rotationRate rate: Double) -> Bool {
        rate <= steadinessThresholdRadPerSec
    }

    private static func rotationMatrix(of transform: simd_float4x4) -> simd_float3x3 {
        // Normalize columns so residual scale never corrupts the quaternion.
        let c0 = simd_normalize(simd_float3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z))
        let c1 = simd_normalize(simd_float3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z))
        let c2 = simd_normalize(simd_float3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
        return simd_float3x3(c0, c1, c2)
    }

    // MARK: - Parallax drift

    /// Meters of translation from the pivot origin (position at first shot).
    /// Warn > `driftWarnMeters`, hard-warn > `driftHardWarnMeters` (spec §9:
    /// parallax is the #1 stitch killer).
    static func translationDrift(from origin: simd_float3, current: simd_float3) -> Float {
        simd_length(current - origin)
    }
}

// MARK: - DwellTracker

/// Fires once when aligned + steady have held continuously for
/// `AlignmentMath.dwellSeconds`. Any lapse resets the clock.
struct DwellTracker {
    private var satisfiedSince: TimeInterval?

    /// Feed one frame; returns true exactly once per completed dwell.
    mutating func update(aligned: Bool, steady: Bool, at timestamp: TimeInterval) -> Bool {
        guard aligned, steady else {
            satisfiedSince = nil
            return false
        }
        guard let since = satisfiedSince else {
            satisfiedSince = timestamp
            return false
        }
        if timestamp - since >= AlignmentMath.dwellSeconds {
            satisfiedSince = nil // re-arm for the next target
            return true
        }
        return false
    }

    mutating func reset() {
        satisfiedSince = nil
    }

    /// Fraction of the dwell completed, [0, 1] — drives the HUD's ring fill.
    func progress(at timestamp: TimeInterval) -> Double {
        guard let since = satisfiedSince else { return 0 }
        return min(1, max(0, (timestamp - since) / AlignmentMath.dwellSeconds))
    }
}
