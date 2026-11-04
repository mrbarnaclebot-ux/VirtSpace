//
//  ARKitCameraControl.swift
//  VirtSpace
//
//  AE/AWB control on ARKit's own capture device (spec §10 R34/R38), split out
//  of ARKitCaptureSource. ARKit owns the camera, so the only handle is
//  `configurableCaptureDeviceForPrimaryCamera`.
//
//  The locked values are remembered so they can be re-applied: an ARKit
//  interruption or a thermal pause/resume reconfigures the capture device,
//  which can silently drop it back to continuous AE mid-capture.
//
//  Focus is never touched: continuous AF stays on (see CaptureSource).
//

import ARKit
import AVFoundation

/// Confined to the owning ARKitCaptureSource's engine queue. `device` is
/// immutable, and AVCaptureDevice's exposure readings are safe to read from
/// the encode queue.
nonisolated final class ARKitCameraControl {
    let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera

    private struct Locked {
        let duration: CMTime
        let iso: Float
        let gains: AVCaptureDevice.WhiteBalanceGains?
    }

    private var locked: Locked?

    func reset() {
        locked = nil
    }

    func sample() -> ExposureSample? {
        guard let device else { return nil }
        let format = device.activeFormat
        return ExposureSample(
            iso: device.iso,
            duration: device.exposureDuration.seconds,
            minISO: format.minISO,
            maxISO: format.maxISO,
            minDuration: format.minExposureDuration.seconds,
            maxDuration: format.maxExposureDuration.seconds
        )
    }

    /// Returns whether the lock took; `onApplied` fires (any queue) once the
    /// frames actually carry the new exposure, which the dwell gate waits on.
    func lock(iso: Float, duration: Double, onApplied: @escaping @Sendable () -> Void) -> Bool {
        guard let device else { return false }
        let gains = device.isWhiteBalanceModeSupported(.locked) ? device.deviceWhiteBalanceGains : nil
        locked = Locked(
            duration: CMTime(seconds: duration, preferredTimescale: 1_000_000_000),
            iso: iso,
            gains: gains
        )
        return apply(onApplied: onApplied)
    }

    /// Put the stored lock back after an interruption or thermal resume. No-op
    /// before the first lock.
    func reapply() {
        guard locked != nil else { return }
        _ = apply {}
    }

    // Benign device-log noise: locking AE/AWB triggers the
    // `FigCaptureSourceRemote err=-17281` / CoreMedia `-12710` bursts also seen
    // at capture time. The lock takes effect regardless.
    private func apply(onApplied: @escaping @Sendable () -> Void) -> Bool {
        guard let device, let locked else { return false }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if let gains = locked.gains {
                device.setWhiteBalanceModeLocked(with: Self.clamped(gains, max: device.maxWhiteBalanceGain), completionHandler: nil)
            }
            if device.isExposureModeSupported(.custom) {
                device.setExposureModeCustom(duration: locked.duration, iso: locked.iso) { _ in onApplied() }
                return true
            }
            if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
                onApplied()
                return true
            }
            return false
        } catch {
            return false
        }
    }

    /// Out-of-range gains raise an Objective-C exception, so clamp even the
    /// device's own reading.
    private static func clamped(_ gains: AVCaptureDevice.WhiteBalanceGains, max: Float) -> AVCaptureDevice.WhiteBalanceGains {
        func clamp(_ value: Float) -> Float { Swift.min(Swift.max(value, 1), max) }
        return AVCaptureDevice.WhiteBalanceGains(redGain: clamp(gains.redGain), greenGain: clamp(gains.greenGain), blueGain: clamp(gains.blueGain))
    }
}
