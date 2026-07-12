//
//  CaptureSource.swift
//  VirtSpace
//
//  Thin seam between CaptureEngine and the camera. On device the real
//  implementation is ARKitCaptureSource; in the simulator (no camera, no
//  ARKit tracking) SimulatedCaptureSource drives a fake pose that slowly
//  sweeps toward the current target so the whole capture flow is walkable.
//  Deliberately minimal — the ARKit path is the product; the sim path only
//  needs to exercise the engine's state machine.
//

import Foundation
import simd
#if targetEnvironment(simulator)
import UIKit
import QuartzCore
#endif

/// One tracked camera pose, delivered per frame on the engine's queue.
struct CapturePose {
    var timestamp: TimeInterval
    var transform: simd_float4x4
    var intrinsics: simd_float3x3
    /// Non-nil while tracking is degraded ("Slow down", "Too dark…").
    var trackingWarning: String?
}

/// One captured still: encoded JPEG plus the pose metadata the server
/// stitcher needs (spec §5: pose-assisted reprojection).
struct CapturedStill {
    var jpegData: Data
    var timestamp: TimeInterval
    var transform: simd_float4x4
    var intrinsics: simd_float3x3
}

enum CaptureSourceError: LocalizedError {
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

protocol CaptureSource: AnyObject {
    /// Per-frame pose stream. Called on the queue the source was created with.
    var onPose: ((CapturePose) -> Void)? { get set }
    /// Fatal session errors (camera unavailable, ARKit failure).
    var onError: ((String) -> Void)? { get set }

    func start()
    func stop()

    /// Take one still. Completion may arrive on any queue.
    func captureStill(_ completion: @escaping (Result<CapturedStill, Error>) -> Void)

    /// Lock AE/AWB/AF at their current values (called after the first shot —
    /// spec §9: exposure/WB seams). Returns whether the lock actually took.
    @discardableResult
    func lockCameraSettings() -> Bool
}

#if targetEnvironment(simulator)

// MARK: - SimulatedCaptureSource

/// Timer-driven fake camera for the simulator: holds a yaw/pitch attitude that
/// slews toward `desiredDirection` (the engine points this at the current
/// target), pausing when it arrives so steadiness + dwell fire naturally.
/// Stills are solid-color JPEGs.
final class SimulatedCaptureSource: CaptureSource {
    var onPose: ((CapturePose) -> Void)?
    var onError: ((String) -> Void)?
    /// Engine-provided: world direction the fake camera should drift toward.
    var desiredDirection: (() -> simd_float3?)?

    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?

    // Fake attitude, radians. Rotation convention matches transform(yaw:pitch:).
    private var yaw: Float = 0.35 // start slightly off-target so target 1 needs a turn
    private var pitch: Float = -0.1
    private var lastTick: TimeInterval?
    private var shotCount = 0

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

        let pose = CapturePose(
            timestamp: now,
            transform: Self.transform(yaw: yaw, pitch: pitch),
            intrinsics: Self.fakeIntrinsics,
            trackingWarning: nil
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

    func captureStill(_ completion: @escaping (Result<CapturedStill, Error>) -> Void) {
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
            transform: Self.transform(yaw: yaw, pitch: pitch),
            intrinsics: Self.fakeIntrinsics
        )))
    }

    func lockCameraSettings() -> Bool { true }

    // MARK: Fake camera math

    /// Camera-to-world transform for a yaw (about +Y) then pitch (about
    /// camera X) attitude, positioned at eye height. Forward (-Z rotated) is
    /// (-cos p · sin y, sin p, -cos p · cos y).
    private static func transform(yaw: Float, pitch: Float) -> simd_float4x4 {
        let qYaw = simd_quatf(angle: yaw, axis: simd_float3(0, 1, 0))
        let qPitch = simd_quatf(angle: pitch, axis: simd_float3(1, 0, 0))
        let rotation = simd_float3x3(qYaw * qPitch)
        var m = matrix_identity_float4x4
        m.columns.0 = simd_float4(rotation.columns.0, 0)
        m.columns.1 = simd_float4(rotation.columns.1, 0)
        m.columns.2 = simd_float4(rotation.columns.2, 0)
        m.columns.3 = simd_float4(0, 1.5, 0, 1)
        return m
    }

    private static let fakeIntrinsics = simd_float3x3(
        simd_float3(1500, 0, 0),
        simd_float3(0, 1500, 0),
        simd_float3(720, 540, 1)
    )
}

#endif
