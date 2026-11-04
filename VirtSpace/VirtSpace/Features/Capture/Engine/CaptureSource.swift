//
//  CaptureSource.swift
//  VirtSpace
//
//  Thin seam between CaptureEngine and the camera. On device the real
//  implementation is ARKitCaptureSource; in the simulator (no camera, no
//  ARKit tracking) SimulatedCaptureSource drives a fake pose that slowly
//  sweeps toward the current target so the whole capture flow is walkable.
//  Deliberately minimal — the ARKit path is the product; the sim path only
//  needs to exercise the engine's state machine (and, for B2, the HUD).
//

import CoreGraphics
import Foundation
import simd
#if targetEnvironment(simulator)
import UIKit
import QuartzCore
#endif

/// One tracked camera pose, delivered per frame on the engine's queue.
nonisolated struct CapturePose: Sendable {
    var timestamp: TimeInterval
    var transform: simd_float4x4
    var intrinsics: simd_float3x3
    /// Sensor image size in pixels (landscape, matching `intrinsics`) — the
    /// HUD needs it to derive an on-screen focal length for dot projection.
    var imageResolution: CGSize
    /// Non-nil while tracking is degraded ("Slow down", "Too dark…").
    var trackingWarning: String?
    /// This frame's shutter time, seconds: longer exposures blur at a lower
    /// rotation rate, so the steadiness gate scales with it.
    var exposureDuration: Double
}

/// One captured still: encoded JPEG plus the pose metadata the server
/// stitcher needs (spec §5: pose-assisted reprojection).
nonisolated struct CapturedStill: Sendable {
    var jpegData: Data
    var timestamp: TimeInterval
    var transform: simd_float4x4
    var intrinsics: simd_float3x3
    /// The exposure the still was taken at, for the stitcher's gain
    /// compensation (spec §5.2). nil when the camera didn't report it.
    var iso: Float?
    var exposureDuration: Double?
}

nonisolated enum CaptureSourceError: LocalizedError {
    case notRunning
    case noFrame
    case encodingFailed
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "The camera session isn't running."
        case .noFrame: return "No camera frame is available yet."
        case .encodingFailed: return "Couldn't encode the captured photo."
        case .unsupported(let what): return what
        }
    }
}

/// Implementations are confined to the engine queue they are created with.
nonisolated protocol CaptureSource: AnyObject, Sendable {
    /// Per-frame pose stream. Called on the queue the source was created with.
    var onPose: ((CapturePose) -> Void)? { get set }
    /// Fatal session errors (camera unavailable, ARKit failure).
    var onError: ((String) -> Void)? { get set }

    func start()
    func stop()

    /// Temporarily suspend the feed (thermal-critical cool-down) WITHOUT
    /// tearing down tracking, so `resume()` continues the same world/heading.
    func pause()
    /// Resume after `pause()`, preserving the established world frame.
    func resume()

    /// Take one still. Completion may arrive on any queue.
    func captureStill(_ completion: @escaping @Sendable (Result<CapturedStill, Error>) -> Void)

    /// The camera's current auto-exposure reading, for metering during the
    /// tracking preroll. nil when the camera isn't configurable.
    func exposureSample() -> ExposureSample?

    /// Lock AE at (iso, duration) and AWB at its current gains, before shot 0
    /// (spec §10 R34/R38: exposure/WB seams are the biggest stitch killer we
    /// control). Focus is deliberately left on continuous AF: per-frame
    /// intrinsics already record focus breathing, and a focus locked at
    /// target 0's distance blurs every farther wall. Returns whether the lock
    /// took; `onApplied` (any queue) fires once frames carry the new exposure.
    func lockExposure(iso: Float, duration: Double, onApplied: @escaping @Sendable () -> Void) -> Bool
}

#if targetEnvironment(simulator)

// MARK: - SimulatedCaptureSource

/// Timer-driven fake camera for the simulator: holds a yaw/pitch attitude that
/// slews toward `desiredDirection` (the engine points this at the current
/// target), pausing when it arrives so steadiness + dwell fire naturally.
/// Stills are solid-color JPEGs.
///
/// Transforms follow the ARKit *portrait* camera convention (camera +X =
/// screen-down, +Y = screen-right, -Z = forward, right-handed) so the HUD's
/// projection math is identical on device and simulator.
///
/// Confined to the engine queue: the timer fires on it, and `captureStill` and
/// the attitude state are only touched from there.
nonisolated final class SimulatedCaptureSource: CaptureSource, @unchecked Sendable {
    var onPose: ((CapturePose) -> Void)?
    var onError: ((String) -> Void)?
    /// Engine-provided: world direction the fake camera should drift toward.
    var desiredDirection: (() -> simd_float3?)?

    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?

    // Fake attitude, radians. yaw about +Y (math-positive = turning left in
    // this parameterization), pitch positive = looking up.
    private var yaw: Float = 0.35 // start slightly off-target so target 1 needs a turn
    private var pitch: Float = -0.1
    private var lastTick: TimeInterval?
    private var shotCount = 0

    /// SIM-ONLY scripted parallax: between shots 4 and 6 the fake user
    /// "wanders" ~0.42 m off the pivot spot, then steps back — exercises the
    /// drift-coaching banner in HUD walkthroughs. No device equivalent.
    private var driftOffset: Float = 0
    private let driftSlewRate: Float = 0.3 // m/s

    /// Slew rate, rad/s — fast enough to demo, slow enough to look like a turn.
    private let slewRate: Float = 1.0
    private let tickHz: Double = 30

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / tickHz)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lastTick = nil
    }

    func pause() { stop() }

    func resume() { start() }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = Float(min(0.2, now - (lastTick ?? now)))
        lastTick = now

        if let target = desiredDirection?() {
            // Convert desired direction to this convention's yaw/pitch.
            let targetPitch = asin(max(-1, min(1, target.y)))
            let horizontal = simd_length(simd_float2(target.x, target.z))
            let targetYaw = horizontal > 0.001 ? atan2(-target.x, -target.z) : yaw

            yaw += clampedStep(from: yaw, to: targetYaw, maxStep: slewRate * dt, wrap: true)
            pitch += clampedStep(from: pitch, to: targetPitch, maxStep: slewRate * dt, wrap: false)
        }

        // Scripted drift (sim-only, see declaration).
        let driftTarget: Float = (4..<6).contains(shotCount) ? 0.42 : 0
        driftOffset += clampedStep(from: driftOffset, to: driftTarget, maxStep: driftSlewRate * dt, wrap: false)

        let pose = CapturePose(
            timestamp: now,
            transform: currentTransform(),
            intrinsics: Self.fakeIntrinsics,
            imageResolution: Self.fakeResolution,
            trackingWarning: nil,
            exposureDuration: 1.0 / 60
        )
        onPose?(pose)
    }

    private func clampedStep(from: Float, to: Float, maxStep: Float, wrap: Bool) -> Float {
        var delta = to - from
        if wrap {
            // Shortest way around the circle.
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
        }
        return max(-maxStep, min(maxStep, delta))
    }

    func captureStill(_ completion: @escaping @Sendable (Result<CapturedStill, Error>) -> Void) {
        shotCount += 1
        let hue = CGFloat((shotCount * 61) % 360) / 360
        let color = UIColor(hue: hue, saturation: 0.55, brightness: 0.8, alpha: 1)
        let size = CGSize(width: 1440, height: 1080)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            completion(.failure(CaptureSourceError.encodingFailed))
            return
        }
        completion(.success(CapturedStill(
            jpegData: data,
            timestamp: CACurrentMediaTime(),
            transform: currentTransform(),
            intrinsics: Self.fakeIntrinsics,
            iso: 100,
            exposureDuration: 1.0 / 60
        )))
    }

    /// A bright, well-exposed room: the sim never trips the low-light warning.
    func exposureSample() -> ExposureSample? {
        ExposureSample(iso: 100, duration: 1.0 / 60, minISO: 32, maxISO: 2_000,
                       minDuration: 1.0 / 10_000, maxDuration: 1.0 / 3)
    }

    func lockExposure(iso: Float, duration: Double, onApplied: @escaping @Sendable () -> Void) -> Bool {
        onApplied()
        return true
    }

    // MARK: Fake camera math

    private func currentTransform() -> simd_float4x4 {
        Self.transform(yaw: yaw, pitch: pitch, position: simd_float3(driftOffset, 1.5, 0))
    }

    /// Camera-to-world transform in ARKit portrait convention for a camera
    /// that yaws about world +Y then pitches. Forward is
    /// (-cos p · sin y, sin p, -cos p · cos y); screen-right stays horizontal.
    /// Columns: camX = screen-down, camY = screen-right, camZ = -forward
    /// (right-handed: camX × camY = camZ).
    private static func transform(yaw: Float, pitch: Float, position: simd_float3) -> simd_float4x4 {
        let forward = simd_float3(-cos(pitch) * sin(yaw), sin(pitch), -cos(pitch) * cos(yaw))
        // Screen-right is horizontal and pitch-independent for a yaw-pitch rig.
        let right = simd_float3(cos(yaw), 0, -sin(yaw))
        let up = simd_normalize(simd_cross(right, forward)) // screen-up

        var m = matrix_identity_float4x4
        m.columns.0 = simd_float4(-up, 0)      // camera X = screen-down
        m.columns.1 = simd_float4(right, 0)    // camera Y = screen-right
        m.columns.2 = simd_float4(-forward, 0) // camera Z = backward
        m.columns.3 = simd_float4(position, 1)
        return m
    }

    private static let fakeIntrinsics = simd_float3x3(
        simd_float3(1500, 0, 0),
        simd_float3(0, 1500, 0),
        simd_float3(720, 540, 1)
    )

    private static let fakeResolution = CGSize(width: 1440, height: 1080)
}

#endif
