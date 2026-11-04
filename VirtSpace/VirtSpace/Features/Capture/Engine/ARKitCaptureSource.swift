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
//  live feed's `capturedImage`. Before shot 0 the engine locks AE/AWB to the
//  exposure metered during the tracking preroll (ARKitCameraControl); focus
//  stays on continuous AF.
//

import ARKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import simd

/// Confined to the engine queue, which is also the ARSession's `delegateQueue`
/// — so `didUpdate frame:` and the engine's own mutation are already serialized
/// against each other. The still encode hops to `encodeQueue` and touches only
/// immutable state (`ciContext`, the constants) from there.
nonisolated final class ARKitCaptureSource: NSObject, CaptureSource, ARSessionDelegate, @unchecked Sendable {
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
    private let camera = ARKitCameraControl()
    private let ciContext = CIContext()
    private var supportsHighResCapture = false
    private var isRunning = false
    /// Retained so a thermal `resume()` can re-run the SAME configuration
    /// without `.resetTracking` — preserving the world frame + heading basis.
    private var configuration: ARWorldTrackingConfiguration?
    /// Set when the capture device may have been reconfigured under us
    /// (interruption end, thermal resume): the next frame re-applies the
    /// stored AE/AWB lock, so the rest of the capture matches shot 0.
    private var needsLockReapply = false

    /// iOS 26.0's first `captureHighResolutionFrame` can return a wrong camera
    /// transform (Apple forum thread 801508, fixed in 26.1), and the
    /// deployment target is 26.0. On 26.0.x only, that first still takes its
    /// transform from the live frame instead.
    private static let firstHighResTransformIsUnreliable: Bool = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.majorVersion == 26 && version.minorVersion == 0
    }()
    private var hasRequestedHighRes = false

    /// Off-main queue for the heavy still encode (Lanczos downscale + JPEG).
    /// `captureHighResolutionFrame`'s completion is delivered on the main
    /// thread; encoding there would hang the UI and add heat (Stage B3
    /// deliverable 2c), so we hop here first.
    private let encodeQueue = DispatchQueue(label: "com.virtspace.arkit-encode", qos: .userInitiated)

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
        // Thermal trim (Stage B3 deliverable 2a): this is a pure pose+still
        // capture — turn OFF every ARKit subsystem we don't use so the device
        // does less work and runs cooler. Plane detection, scene
        // reconstruction (LiDAR mesh), frame semantics (segmentation/depth),
        // environment texturing and light estimation are all unnecessary here.
        configuration.planeDetection = []
        configuration.frameSemantics = []
        configuration.environmentTexturing = .none
        configuration.isLightEstimationEnabled = false
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = []
        }
        // Opt into a video format that supports 12 MP+ mid-session stills.
        if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            configuration.videoFormat = format
            supportsHighResCapture = true
        } else {
            supportsHighResCapture = false
        }
        self.configuration = configuration
        isRunning = true
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        isRunning = false
        session.pause()
    }

    func pause() {
        // Suspend the feed to cool down; keep `configuration` so resume()
        // continues the same world map (no reset → heading basis survives).
        isRunning = false
        session.pause()
    }

    func resume() {
        guard let configuration else { start(); return }
        isRunning = true
        needsLockReapply = true
        // No options → ARKit relocalizes into the existing world; the engine's
        // established heading basis and captured poses stay valid.
        session.run(configuration)
    }

    func captureStill(_ completion: @escaping @Sendable (Result<CapturedStill, Error>) -> Void) {
        guard isRunning else {
            completion(.failure(CaptureSourceError.notRunning))
            return
        }
        if supportsHighResCapture {
            let replaceTransform = Self.firstHighResTransformIsUnreliable && !hasRequestedHighRes
            hasRequestedHighRes = true
            // Benign device-log noise: at high-res still capture the camera
            // stack emits `FigCaptureSourceRemote ... err=-17281` and CoreMedia
            // `-12710` bursts. Captures succeed regardless — these are Apple's
            // internal chatter, not our failure. Don't chase them when debugging.
            session.captureHighResolutionFrame { [weak self] frame, _ in
                guard let self else { return }
                // The latest live frame, for what the high-res frame may not
                // carry (feature points; depth) — the user is holding still.
                let live = self.session.currentFrame
                // Encode off the main thread: this callback lands on main and
                // the Lanczos+JPEG work is expensive (deliverable 2c).
                self.encodeQueue.async {
                    if let frame {
                        var result = self.encode(frame, live: live)
                        if replaceTransform, let live {
                            result = result.map { still in
                                var still = still
                                still.transform = live.camera.transform
                                return still
                            }
                        }
                        completion(result)
                    } else {
                        // High-res capture can transiently fail (e.g. one
                        // already in flight) — degrade to the live feed rather
                        // than lose the shot.
                        completion(self.captureCurrentFrame())
                    }
                }
            }
        } else {
            encodeQueue.async { completion(self.captureCurrentFrame()) }
        }
    }

    func exposureSample() -> ExposureSample? {
        camera.sample()
    }

    func lockExposure(iso: Float, duration: Double, onApplied: @escaping @Sendable () -> Void) -> Bool {
        camera.lock(iso: iso, duration: duration, onApplied: onApplied)
    }

    // MARK: - Frame encoding

    private func captureCurrentFrame() -> Result<CapturedStill, Error> {
        guard let frame = session.currentFrame else {
            return .failure(CaptureSourceError.noFrame)
        }
        return encode(frame, live: nil)
    }

    /// CVPixelBuffer → JPEG (quality 0.9), capped at ~12 MP. Intrinsics are
    /// scaled alongside any downscale so poses.json stays consistent with the
    /// uploaded pixels. Pixels are uploaded in ARKit's native (landscape)
    /// orientation; the server stitcher orients via the pose transform.
    private func encode(_ frame: ARFrame, live: ARFrame?) -> Result<CapturedStill, Error> {
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
            intrinsics: intrinsics,
            // ISO isn't on ARFrame; AE is locked by now, so the device's
            // current ISO is the one this frame was exposed at.
            iso: camera.device?.iso,
            exposureDuration: frame.camera.exposureDuration,
            featureDepthMedian: Self.featureDepthMedian(frame.rawFeaturePoints != nil ? frame : live)
        ))
    }

    /// Projects with the camera of the frame the points came from.
    private static func featureDepthMedian(_ frame: ARFrame?) -> Float? {
        guard let frame, let points = frame.rawFeaturePoints?.points else { return nil }
        return FrameDepth.featureDepthMedian(
            points: points,
            cameraTransform: frame.camera.transform,
            intrinsics: frame.camera.intrinsics,
            imageSize: frame.camera.imageResolution
        )
    }

    // MARK: - ARSessionDelegate (called on `delegateQueue`)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if needsLockReapply {
            needsLockReapply = false
            camera.reapply()
        }
        onPose?(CapturePose(
            timestamp: frame.timestamp,
            transform: frame.camera.transform,
            intrinsics: frame.camera.intrinsics,
            imageResolution: frame.camera.imageResolution,
            trackingWarning: Self.warning(for: frame.camera.trackingState),
            exposureDuration: frame.camera.exposureDuration,
            isRelocalizing: frame.camera.trackingState == .limited(.relocalizing)
        ))
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        isRunning = false
        onError?(error.localizedDescription)
    }

    func sessionWasInterrupted(_ session: ARSession) {
        // No-op: interruptions surface via trackingState once frames resume.
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        needsLockReapply = true
    }

    /// Relocalize into the existing world after an interruption instead of
    /// resetting it: the heading basis and every captured pose stay valid
    /// (R31). The engine offers a restart if this doesn't succeed.
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        true
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
