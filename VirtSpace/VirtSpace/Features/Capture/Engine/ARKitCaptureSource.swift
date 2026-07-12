//
//  ARKitCaptureSource.swift
//  VirtSpace
//
//  The real, on-device CaptureSource: an ARSession running
//  ARWorldTrackingConfiguration with `.gravity` alignment (NOT
//  gravityAndHeading — the engine derives its own heading from the first
//  frame so targets are relative to where the user starts looking, and the
//  magnetometer can't yank the world frame mid-capture).
//
//  Stills use ARKit-native `captureHighResolutionFrame` (spec §3.1 corrected
//  row: a parallel AVCaptureSession is impossible — ARKit owns the camera).
//  If the device offers no high-res-capable video format we fall back to the
//  live feed's `capturedImage`. After the first shot the engine calls
//  `lockCameraSettings()`, which locks AE/AWB/AF on ARKit's own capture
//  device via `configurableCaptureDeviceForPrimaryCamera` (spec §9:
//  exposure/WB seams are the biggest stitch killer we control).
//

import ARKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import simd

final class ARKitCaptureSource: NSObject, CaptureSource, ARSessionDelegate {
    var onPose: ((CapturePose) -> Void)?
    var onError: ((String) -> Void)?

    /// Exposed so the HUD's camera preview (ARSCNView) can render this
    /// session's feed. The engine remains the sole owner: only this class
    /// runs/pauses the session, and the delegate stays here.
    var arSession: ARSession { session }

    /// JPEG pixel cap (~12 MP): native 4032×3024 high-res frames pass
    /// untouched; anything larger (48 MP-class formats) is Lanczos-downscaled
    /// so uploads stay in the size range the backend/stitcher expects.
    private static let maxPixels = 12_600_000
    private static let jpegQuality = 0.9

    private let session = ARSession()
    private let ciContext = CIContext()
    private var supportsHighResCapture = false
    private var isRunning = false

    init(queue: DispatchQueue) {
        super.init()
        session.delegateQueue = queue
        session.delegate = self
    }

    // MARK: - CaptureSource

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            onError?("This device doesn't support world tracking.")
            return
        }
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.isLightEstimationEnabled = false
        // Opt into a video format that supports 12 MP+ mid-session stills.
        if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            configuration.videoFormat = format
            supportsHighResCapture = true
        } else {
            supportsHighResCapture = false
        }
        isRunning = true
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        isRunning = false
        session.pause()
    }

    func captureStill(_ completion: @escaping (Result<CapturedStill, Error>) -> Void) {
        guard isRunning else {
            completion(.failure(CaptureSourceError.notRunning))
            return
        }
        if supportsHighResCapture {
            session.captureHighResolutionFrame { [weak self] frame, _ in
                guard let self else { return }
                if let frame {
                    completion(self.encode(frame))
                } else {
                    // High-res capture can transiently fail (e.g. one already
                    // in flight) — degrade to the live feed rather than lose
                    // the shot.
                    completion(self.captureCurrentFrame())
                }
            }
        } else {
            completion(captureCurrentFrame())
        }
    }

    func lockCameraSettings() -> Bool {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else {
            return false
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            var lockedExposure = false
            if device.isExposureModeSupported(.custom) {
                // Freeze AE at its *current* values.
                let format = device.activeFormat
                let duration = clamp(device.exposureDuration,
                                     min: format.minExposureDuration,
                                     max: format.maxExposureDuration)
                let iso = max(format.minISO, min(format.maxISO, device.iso))
                device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
                lockedExposure = true
            } else if device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
                lockedExposure = true
            }
            if device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            }
            if device.isFocusModeSupported(.locked) {
                device.focusMode = .locked
            }
            return lockedExposure
        } catch {
            return false
        }
    }

    private func clamp(_ value: CMTime, min minTime: CMTime, max maxTime: CMTime) -> CMTime {
        if CMTimeCompare(value, minTime) < 0 { return minTime }
        if CMTimeCompare(value, maxTime) > 0 { return maxTime }
        return value
    }

    // MARK: - Frame encoding

    private func captureCurrentFrame() -> Result<CapturedStill, Error> {
        guard let frame = session.currentFrame else {
            return .failure(CaptureSourceError.noFrame)
        }
        return encode(frame)
    }

    /// CVPixelBuffer → JPEG (quality 0.9), capped at ~12 MP. Intrinsics are
    /// scaled alongside any downscale so poses.json stays consistent with the
    /// uploaded pixels. Pixels are uploaded in ARKit's native (landscape)
    /// orientation; the server stitcher orients via the pose transform.
    private func encode(_ frame: ARFrame) -> Result<CapturedStill, Error> {
        var image = CIImage(cvPixelBuffer: frame.capturedImage)
        var intrinsics = frame.camera.intrinsics

        let pixels = Int(image.extent.width * image.extent.height)
        if pixels > Self.maxPixels {
            let scale = (Double(Self.maxPixels) / Double(pixels)).squareRoot()
            let filter = CIFilter.lanczosScaleTransform()
            filter.inputImage = image
            filter.scale = Float(scale)
            filter.aspectRatio = 1
            guard let scaled = filter.outputImage else {
                return .failure(CaptureSourceError.encodingFailed)
            }
            image = scaled
            // fx, fy, cx, cy all scale linearly with the pixel dimensions.
            let s = Float(scale)
            intrinsics.columns.0.x *= s // fx
            intrinsics.columns.1.y *= s // fy
            intrinsics.columns.2.x *= s // cx
            intrinsics.columns.2.y *= s // cy
        }

        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let data = ciContext.jpegRepresentation(
                of: image,
                colorSpace: colorSpace,
                options: [
                    CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): Self.jpegQuality
                ]
            )
        else {
            return .failure(CaptureSourceError.encodingFailed)
        }

        return .success(CapturedStill(
            jpegData: data,
            timestamp: frame.timestamp,
            transform: frame.camera.transform,
            intrinsics: intrinsics
        ))
    }

    // MARK: - ARSessionDelegate (called on `delegateQueue`)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        onPose?(CapturePose(
            timestamp: frame.timestamp,
            transform: frame.camera.transform,
            intrinsics: frame.camera.intrinsics,
            imageResolution: frame.camera.imageResolution,
            trackingWarning: Self.warning(for: frame.camera.trackingState)
        ))
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        isRunning = false
        onError?(error.localizedDescription)
    }

    func sessionWasInterrupted(_ session: ARSession) {
        // No-op: interruptions surface via trackingState once frames resume.
    }

    private static func warning(for state: ARCamera.TrackingState) -> String? {
        switch state {
        case .normal:
            return nil
        case .notAvailable:
            return "Tracking unavailable"
        case .limited(.initializing):
            return "Getting ready…"
        case .limited(.excessiveMotion):
            return "Slow down"
        case .limited(.insufficientFeatures):
            return "Too dark or too plain — try more light"
        case .limited(.relocalizing):
            return "Re-finding your space…"
        case .limited:
            return "Tracking limited"
        }
    }
}
