//
//  CaptureEngine+Pose.swift
//  VirtSpace
//
//  Per-frame work on the engine queue: heading basis from the first tracked
//  frame, steadiness, alignment, dwell, and the throttled HUD publish.
//

import Foundation
import simd

nonisolated extension CaptureEngine {
    // MARK: - Engine queue: per-frame

    func handlePose(_ pose: CapturePose) {
        guard running else { return }

        // Meter during the tracking preroll: ARKit's continuous AE is already
        // following the user's look-around, before any target exists.
        if exposurePhase == .metering, let sample = source?.exposureSample() {
            meter.add(sample)
        }

        // Establish the heading basis from the first *well-tracked* frame:
        // yaw of the camera forward becomes "straight ahead" for the layout.
        if worldTargets.isEmpty {
            guard pose.trackingWarning == nil else {
                publish { $0.warning = pose.trackingWarning }
                return
            }
            let basis = Self.headingBasis(fromCameraForward: AlignmentMath.forward(of: pose.transform))
            worldTargets = targets.map { simd_normalize(basis * $0.direction) }
            let directions = worldTargets
            publish {
                $0.targetDirections = directions
                $0.state = .ready(targetIndex: 0)
            }
        }

        let forward = AlignmentMath.forward(of: pose.transform)
        let position = AlignmentMath.position(of: pose.transform)

        // Steadiness from consecutive transforms (ARKit exposes no gyro
        // directly); light low-pass so single noisy frames don't flicker it.
        if let prev = previousTransform, let prevTime = previousTimestamp {
            let rate = AlignmentMath.rotationRate(from: prev, to: pose.transform, dt: pose.timestamp - prevTime)
            smoothedRate = 0.7 * smoothedRate + 0.3 * rate
        }
        previousTransform = pose.transform
        previousTimestamp = pose.timestamp

        trackRelocalization(pose)

        meterOrLockExposure()

        guard worldTargets.indices.contains(currentIndex) else { return }
        let target = worldTargets[currentIndex]
        let distance = AlignmentMath.angularDistanceDegrees(forward, target)
        let deltas = AlignmentMath.signedDeltas(cameraForward: forward, targetDirection: target)
        let steady = AlignmentMath.isSteady(rotationRate: smoothedRate, exposureDuration: pose.exposureDuration)
        let drift = AlignmentMath.driftFromCentroid(of: shotPositions, current: position)
        let pivotOffset = AlignmentMath.centroid(shotPositions).map {
            AlignmentMath.pivotOffset(from: $0, current: position, cameraForward: forward)
        } ?? .zero

        // Thermal coaching now flows through the dedicated `thermalState`
        // publish + CoachingLayer banner (event-driven via NotificationCenter),
        // so we no longer poll ProcessInfo per frame here.
        var warningText = pose.trackingWarning
        // Transient warnings (e.g. a failed shot) hold for a few seconds
        // instead of being wiped by the very next pose frame.
        if warningText == nil, let transient = transientWarning {
            if pose.timestamp < transient.until {
                warningText = transient.text
            } else {
                transientWarning = nil
            }
        }

        // Auto-fire: aligned + steady, continuously, with trustworthy tracking.
        var progress: Double = 0
        let aligned = AlignmentMath.isAligned(angularDistanceDegrees: distance)
        if !isTakingStill {
            var canFire = steady && pose.trackingWarning == nil && exposurePhase == .locked
            canFire = pivotGate.allows(drift: drift, onTarget: aligned && canFire, at: pose.timestamp) && canFire
            if dwell.update(aligned: aligned, steady: canFire, at: pose.timestamp) {
                progress = 1
            } else {
                progress = dwell.progress(at: pose.timestamp)
            }
        }

        // Coalesce the HUD publish to ~30 Hz and only when something the HUD
        // actually renders has moved (Stage B3 deliverable 2b) — the policy
        // itself lives in HUDPublishThrottle so it can be unit-tested.
        let sample = HUDPublishThrottle.Sample(
            timestamp: pose.timestamp,
            angleDegrees: distance,
            isSteady: steady,
            targetIndex: currentIndex,
            dwellProgress: progress,
            warning: warningText,
            rotationRate: smoothedRate
        )

        if throttle.shouldPublish(sample) {
            // Bind the two locals that are `var` above to immutable copies:
            // the publish closure runs later, on the main queue, and must
            // capture this frame's values rather than the variables.
            let publishedWarning = warningText
            let publishedProgress = progress
            let transform = pose.transform
            let intrinsics = pose.intrinsics
            let resolution = pose.imageResolution
            publish {
                $0.angularDistanceDegrees = distance
                $0.yawDeltaDegrees = deltas.yaw
                $0.pitchDeltaDegrees = deltas.pitch
                $0.isSteady = steady
                $0.driftMeters = drift
                $0.pivotOffset = pivotOffset
                $0.warning = publishedWarning
                $0.cameraTransform = transform
                $0.cameraIntrinsics = intrinsics
                $0.imageResolution = resolution
                $0.dwellProgress = publishedProgress
            }
        }

        if progress >= 1 {
            takeStill()
        }
    }

    /// Rotation mapping the heading frame (-Z forward) into world space, from
    /// the camera forward's horizontal projection. Falls back to world -Z if
    /// the user starts pointing straight up/down.
    private static func headingBasis(fromCameraForward forward: simd_float3) -> simd_float3x3 {
        var horizontal = simd_float3(forward.x, 0, forward.z)
        if simd_length(horizontal) < 0.05 {
            horizontal = simd_float3(0, 0, -1)
        }
        let f = simd_normalize(horizontal)
        let up = simd_float3(0, 1, 0)
        let right = simd_normalize(simd_cross(f, up))
        // Columns: heading-frame X (right), Y (up), Z (backward = -forward).
        return simd_float3x3(right, up, -f)
    }
}
