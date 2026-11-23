//
//  RoomScanKeyframeGate.swift
//  VirtSpace
//
//  Which ARFrames of a walk become keyframes (spec §5.3 item 1). Pure: pose,
//  timestamp, tracking, exposure and fx in, a decision out, so it runs on the
//  engine queue per frame and in unit tests alike. Thresholds and the blur
//  model follow SpAItial's prototype (ContinuousScanSampler,
//  CaptureFrameQualityGate, CaptureQualityMonitor, CameraGeometry; MIT No
//  Attribution).
//
//  Accept when ≥0.12 s since the last keyframe AND (≥7 cm or ≥10°), or
//  ≥0.35 s AND (≥1 cm or ≥1.5°). Skip when tracking isn't `.normal` (and for
//  0.5 s after it recovers, or after a pose jump ARKit didn't report: one
//  world frame per bundle), when predicted blur
//  `fx·ω·exposure + fx·(v_lateral / 2 m)·exposure` exceeds 64 px, when the
//  phone is clearly held the other way up from the first keyframe, or at the
//  frame cap.
//

import Foundation
import simd

nonisolated struct RoomScanKeyframeGate: Sendable {
    enum Skip: Equatable, Sendable {
        case tracking, settling, limit, blur, holdChanged, notMoved, busy
    }

    enum Decision: Equatable, Sendable {
        case accept
        case skip(Skip)
    }

    var maxFrames: Int
    private(set) var accepted = 0
    /// The last blur estimate, px (HUD "slow down", logs).
    private(set) var predictedBlurPx: Float = 0

    static let minInterval: TimeInterval = 0.12
    static let moveMeters: Float = 0.07
    static let moveDegrees: Float = 10
    static let heartbeatInterval: TimeInterval = 0.35
    static let heartbeatMeters: Float = 0.01
    static let heartbeatDegrees: Float = 1.5
    static let maxBlurPx: Float = 64
    static let nominalDepthMeters: Float = 2
    static let settleSeconds: TimeInterval = 0.5
    /// Faster than this between two ARFrames is a world shift, not motion.
    static let jumpMetersPerSecond: Float = 5
    static let jumpRadiansPerSecond: Float = 4 * .pi

    private struct Pose {
        let t: TimeInterval
        let position: SIMD3<Float>
        let rotation: simd_quatf
        var forward: SIMD3<Float> { rotation.act(SIMD3(0, 0, -1)) }
    }

    private enum Hold { case portrait, landscape }

    private var lastKeyframe: Pose?
    private var previous: Pose?
    /// Start of the ≥0.1 s window the blur speeds are measured over.
    private var blurReference: Pose?
    private var blurMeasuredAt: TimeInterval = -.infinity
    private var settledAt: TimeInterval?
    private var hold: Hold?

    init(maxFrames: Int) {
        self.maxFrames = maxFrames
    }

    /// `transform` is ARKit world_from_camera, `exposure` seconds, `fx` px.
    /// `canAccept` false (the writer is backed up) skips without consuming
    /// the cadence, so the next frame gets the slot.
    mutating func evaluate(
        transform: simd_float4x4,
        timestamp t: TimeInterval,
        trackingNormal: Bool,
        exposure: Double,
        fx: Float,
        canAccept: Bool = true
    ) -> Decision {
        let rotation = simd_quatf(simd_float3x3(
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)))
        let pose = Pose(t: t, position: SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z), rotation: rotation)

        if let previous, t > previous.t {
            let dt = Float(t - previous.t)
            if simd_distance(pose.position, previous.position) / dt > Self.jumpMetersPerSecond
                || Self.angle(previous.rotation, rotation) / dt > Self.jumpRadiansPerSecond {
                settledAt = t + Self.settleSeconds
            }
        }
        previous = pose
        updateBlur(pose, exposure: exposure, fx: fx)

        guard trackingNormal else {
            settledAt = t + Self.settleSeconds
            return .skip(.tracking)
        }
        if settledAt == nil { settledAt = t + Self.settleSeconds }
        if let settledAt, t < settledAt { return .skip(.settling) }
        guard accepted < maxFrames else { return .skip(.limit) }
        if t - blurMeasuredAt <= 0.3, predictedBlurPx > Self.maxBlurPx { return .skip(.blur) }
        if isClearHoldMismatch(transform) { return .skip(.holdChanged) }

        if let last = lastKeyframe {
            let dt = t - last.t
            let meters = simd_distance(pose.position, last.position)
            let degrees = Self.degrees(last.forward, pose.forward)
            let moved = dt >= Self.minInterval && (meters >= Self.moveMeters || degrees >= Self.moveDegrees)
            let heartbeat = dt >= Self.heartbeatInterval && (meters >= Self.heartbeatMeters || degrees >= Self.heartbeatDegrees)
            guard moved || heartbeat else { return .skip(.notMoved) }
        }
        guard canAccept else { return .skip(.busy) }
        lastKeyframe = pose
        accepted += 1
        return .accept
    }

    /// Speeds over a ≥0.1 s window (single-frame deltas are too noisy);
    /// gaps over 0.5 s restart the window.
    private mutating func updateBlur(_ pose: Pose, exposure: Double, fx: Float) {
        guard let reference = blurReference, pose.t - reference.t <= 0.5 else {
            blurReference = pose
            return
        }
        let dt = Float(pose.t - reference.t)
        guard dt >= 0.1 else { return }
        let omega = Self.angle(reference.rotation, pose.rotation) / dt
        let velocity = (pose.position - reference.position) / dt
        let forward = pose.forward
        let lateral = simd_length(velocity - simd_dot(velocity, forward) * forward)
        let exposure = Float(exposure)
        predictedBlurPx = fx * omega * exposure + fx * (lateral / Self.nominalDepthMeters) * exposure
        blurMeasuredAt = pose.t
        blurReference = pose
    }

    /// The first keyframe that isn't looking at the floor or ceiling fixes
    /// the hold; later frames clearly in the other hold are skipped. With
    /// OpenCV M = flip·inverse(T): |M[0][1]| is |camera X · world up| and
    /// |M[1][1]| is |camera Y · world up|.
    private mutating func isClearHoldMismatch(_ transform: simd_float4x4) -> Bool {
        let ux = abs(transform.columns.0.y)
        let uy = abs(transform.columns.1.y)
        guard (ux * ux + uy * uy).squareRoot() >= 0.5 else { return false }
        guard let hold else {
            hold = ux >= uy ? .portrait : .landscape
            return false
        }
        return hold == .portrait ? uy >= 2 * ux : ux >= 2 * uy
    }

    private static func angle(_ a: simd_quatf, _ b: simd_quatf) -> Float {
        2 * acos(min(1, abs(simd_dot(a.vector, b.vector))))
    }

    private static func degrees(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        acos(simd_clamp(simd_dot(simd_normalize(a), simd_normalize(b)), -1, 1)) * 180 / .pi
    }
}
