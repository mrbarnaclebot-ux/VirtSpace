//
//  RoomScanEngine.swift
//  VirtSpace
//
//  The room-scan capture (spec §5.3 item 1): an ARWorldTrackingConfiguration
//  (gravity, 1920×1440) whose frames pass RoomScanKeyframeGate; each keyframe
//  is `ARFrame.capturedImage` copied (never the ARFrame: ARKit drops frames
//  while they are held), JPEG-encoded on a serial write queue with
//  `ARFrame.exifData` embedded, and appended to RoomScanStore the moment it
//  is encoded. At most 3 writes are in flight; past that, frames are skipped.
//
//  The simulator has no ARKit: a timer walks a synthetic camera around a
//  circle and paints synthetic frames, through the same gate, encoder and
//  store, so the bundle and upload path run end to end.
//
//  Threading: frame handling and engine state live on `queue` (also the
//  ARSession delegate queue); disk writes on `writeQueue`; `hud` is only
//  touched on the main actor via `publish`.
//

import ARKit
import CoreImage
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers
import simd

/// What the room-scan UI renders. RoomScanEngine is the only writer.
@MainActor
@Observable
final class RoomScanHUD {
    enum State: Equatable {
        case idle, starting, scanning
        case finished(UUID)
        case failed(String)
    }

    var state: State = .idle
    var startedAt: Date?
    /// Keyframes on disk.
    var frameCount = 0
    /// One coaching line (tracking, "Slow down", limits); nil = all good.
    var hint: String?

    var isLive: Bool {
        switch state {
        case .starting, .scanning, .finished: true
        case .idle, .failed: false
        }
    }

    nonisolated init() {}
}

nonisolated final class RoomScanEngine: NSObject, ARSessionDelegate, @unchecked Sendable {
    let hud = RoomScanHUD()
    /// The camera preview renders this session (device only).
    let arSession = ARSession()

    static let maxWritesInFlight = 3
    /// Headroom under the 4 GiB bundle for the JSON and ZIP headers.
    static let byteBudget = RoomScanBundle.maxBytes - (64 << 20)
    static let jpegQuality = 0.85

    private let store: RoomScanStore
    private let queue = DispatchQueue(label: "com.virtspace.room-scan", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "com.virtspace.room-scan.write", qos: .userInitiated)
    private let ciContext = CIContext()

    // MARK: Engine-queue state

    private var sessionID: UUID?
    private var running = false
    private var gate = RoomScanKeyframeGate(maxFrames: RoomScanBundle.maxFrames)
    private var writesInFlight = 0
    private var committedFrames = 0
    private var committedBytes = 0
    private var writeFailed = false
    private var lastBlurSkip: TimeInterval = -.infinity
    private var lastHoldSkip: TimeInterval = -.infinity
    private var publishedHint: String?? = .none

    // MARK: Write-queue state

    private var nextIndex = 1

    init(store: RoomScanStore = RoomScanStore()) {
        self.store = store
        super.init()
        arSession.delegateQueue = queue
        arSession.delegate = self
    }

    // MARK: Controls (main actor)

    /// Claims a fresh session (so resume sweeps leave it alone while it is
    /// written) and starts the camera. `maxFrames` is the server's cap.
    @MainActor
    func start(maxFrames: Int) async {
        hud.state = .starting
        hud.frameCount = 0
        hud.hint = nil
        let id = UUID()
        _ = await SessionClaims.shared.claim(id)
        queue.async { self.begin(id, maxFrames: maxFrames) }
    }

    /// Stop the camera, wait for queued writes, seal the scan. The HUD goes
    /// to `.finished(id)`; the claim passes to the upload flow.
    @MainActor
    func finish() {
        queue.async {
            guard let id = self.stop() else { return }
            self.writeQueue.async {
                let count = (try? self.store.finish(id)) ?? 0
                AppLog.capture.log("Room scan \(id.uuidString, privacy: .public) finished with \(count) frames")
                if count > 0 {
                    self.publish { $0.state = .finished(id) }
                } else {
                    self.discard(id)
                    self.publish { $0.state = .failed("No photos were taken. Scan again.") }
                }
            }
        }
    }

    /// Stop and delete everything taken so far.
    @MainActor
    func cancel() {
        hud.state = .idle
        queue.async {
            guard let id = self.stop() else { return }
            self.writeQueue.async { self.discard(id) }
        }
    }

    /// Back to the start screen once the upload flow has taken over.
    @MainActor
    func reset() {
        hud.state = .idle
        hud.frameCount = 0
        hud.hint = nil
    }

    // MARK: Lifecycle (engine queue)

    private func begin(_ id: UUID, maxFrames: Int) {
        do {
            try store.createSession(id: id)
        } catch {
            Task { await SessionClaims.shared.release(id) }
            publish { $0.state = .failed("Something went wrong starting the scan. Try again.") }
            return
        }
        sessionID = id
        gate = RoomScanKeyframeGate(maxFrames: maxFrames)
        writesInFlight = 0
        committedFrames = 0
        committedBytes = 0
        writeFailed = false
        publishedHint = .none
        writeQueue.async { self.nextIndex = 1 }
        running = true
        #if targetEnvironment(simulator)
        startSimulatedWalk()
        #else
        guard ARWorldTrackingConfiguration.isSupported else {
            _ = stop()
            writeQueue.async { self.discard(id) }
            publish { $0.state = .failed("This iPhone can't track a room scan.") }
            return
        }
        arSession.run(Self.configuration(), options: [.resetTracking, .removeExistingAnchors])
        #endif
        AppLog.capture.log("Room scan \(id.uuidString, privacy: .public) started, cap \(maxFrames) frames")
        publish {
            $0.state = .scanning
            $0.startedAt = Date()
        }
    }

    /// Returns the session that was running.
    private func stop() -> UUID? {
        running = false
        #if targetEnvironment(simulator)
        simTimer?.cancel()
        simTimer = nil
        #else
        arSession.pause()
        #endif
        defer { sessionID = nil }
        return sessionID
    }

    /// Write queue: after every queued write, so nothing lands afterwards.
    private func discard(_ id: UUID) {
        store.purge(id)
        Task { await SessionClaims.shared.release(id) }
    }

    // MARK: Frames (engine queue)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let camera = frame.camera
        process(
            timestamp: frame.timestamp,
            transform: camera.transform,
            intrinsics: camera.intrinsics,
            resolution: camera.imageResolution,
            exposure: camera.exposureDuration,
            tracking: camera.trackingState,
            pixels: { Self.copy(frame.capturedImage) },
            exif: { frame.exifData })
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        AppLog.capture.error("Room scan ARSession failed: \(error.localizedDescription, privacy: .public)")
        publishHint("The camera stopped. Tap Finish to keep your scan.")
    }

    /// Relocalize into the same world after an interruption: one world frame
    /// per bundle. Frames are skipped until tracking is normal again.
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

    private func process(
        timestamp: TimeInterval,
        transform: simd_float4x4,
        intrinsics: simd_float3x3,
        resolution: CGSize,
        exposure: Double,
        tracking: ARCamera.TrackingState,
        pixels: () -> CVPixelBuffer?,
        exif: () -> [String: Any]
    ) {
        guard running, let id = sessionID else { return }
        let decision = gate.evaluate(
            transform: transform,
            timestamp: timestamp,
            trackingNormal: tracking == .normal,
            exposure: exposure,
            fx: intrinsics.columns.0.x,
            canAccept: writesInFlight < Self.maxWritesInFlight && committedBytes < Self.byteBudget && !writeFailed)
        switch decision {
        case .accept:
            if let buffer = pixels() {
                enqueue(buffer, transform: transform, intrinsics: intrinsics, resolution: resolution,
                        exif: Self.exif(exif(), capturedAt: Date()), session: id)
            }
        case .skip(.blur): lastBlurSkip = timestamp
        case .skip(.holdChanged): lastHoldSkip = timestamp
        case .skip: break
        }
        publishHint(hint(tracking: tracking, at: timestamp))
    }

    private func enqueue(_ buffer: CVPixelBuffer, transform: simd_float4x4, intrinsics: simd_float3x3,
                         resolution: CGSize, exif: [String: Any], session id: UUID) {
        // Intrinsics for the pixels actually encoded (1 at 1920×1440).
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let sx = Float(width) / Float(max(resolution.width, 1))
        let sy = Float(height) / Float(max(resolution.height, 1))
        let flat = (0..<4).flatMap { [transform[$0].x, transform[$0].y, transform[$0].z, transform[$0].w] }
        let pending = PendingFrame(buffer: buffer, exif: exif, frame: RoomScanFrame(
            index: 0, transform: flat,
            fx: intrinsics.columns.0.x * sx, fy: intrinsics.columns.1.y * sy,
            cx: intrinsics.columns.2.x * sx, cy: intrinsics.columns.2.y * sy,
            width: width, height: height))
        writesInFlight += 1
        writeQueue.async {
            let bytes = self.write(pending, session: id)
            self.queue.async {
                self.writesInFlight -= 1
                guard let bytes else {
                    self.writeFailed = true
                    return
                }
                self.committedFrames += 1
                self.committedBytes += bytes
                let count = self.committedFrames
                self.publish { $0.frameCount = count }
            }
        }
    }

    /// Write queue. Index assigned here, after a successful encode, so a
    /// failed frame never leaves a gap in Image_000001…
    private func write(_ pending: PendingFrame, session id: UUID) -> Int? {
        autoreleasepool {
            guard let jpeg = Self.jpeg(pending.buffer, exif: pending.exif, context: ciContext) else {
                AppLog.capture.error("Room scan frame \(self.nextIndex) didn't encode")
                return nil
            }
            var frame = pending.frame
            frame.index = nextIndex
            do {
                try store.appendFrame(jpeg, frame, to: id)
                nextIndex += 1
                return jpeg.count
            } catch {
                AppLog.capture.error("Room scan frame \(self.nextIndex) didn't save: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    // MARK: HUD

    private func hint(tracking: ARCamera.TrackingState, at t: TimeInterval) -> String? {
        if let warning = ARKitCaptureSource.warning(for: tracking) { return warning }
        if writeFailed { return "Your iPhone couldn't save more photos. Tap Finish." }
        if gate.accepted >= gate.maxFrames || committedBytes >= Self.byteBudget {
            return "That's as much as one scan can hold. Tap Finish."
        }
        if t - lastBlurSkip < 1 { return "Slow down" }
        if t - lastHoldSkip < 1 { return "Hold the phone the way you started" }
        return nil
    }

    private func publishHint(_ hint: String?) {
        guard publishedHint != .some(hint) else { return }
        publishedHint = .some(hint)
        publish { $0.hint = hint }
    }

    private func publish(_ mutation: @escaping @MainActor (RoomScanHUD) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { mutation(self.hud) }
        }
    }

    // MARK: Camera configuration

    /// Gravity-aligned, 1920×1440 on the wide camera (else the largest
    /// format with a long edge ≤ 1920), autofocus on, nothing else running.
    private static func configuration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = []
        configuration.environmentTexturing = .none
        configuration.isLightEstimationEnabled = false
        configuration.isAutoFocusEnabled = true
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        let wide = formats.filter { $0.captureDeviceType == .builtInWideAngleCamera }
        let pool = wide.isEmpty ? formats : wide
        let exact = pool.first { $0.imageResolution == CGSize(width: 1920, height: 1440) }
        let fallback = pool
            .filter { max($0.imageResolution.width, $0.imageResolution.height) <= 1920 }
            .max { $0.imageResolution.width * $0.imageResolution.height < $1.imageResolution.width * $1.imageResolution.height }
        if let format = exact ?? fallback { configuration.videoFormat = format }
        return configuration
    }

    // MARK: Encoding

    /// Sensor-landscape JPEG, never rotated, EXIF Orientation absent, the
    /// ARKit EXIF (DateTimeOriginal / SubSecTimeOriginal /
    /// OffsetTimeOriginal) embedded. Quality 0.85 as in SpAItial's prototype.
    static func jpeg(_ buffer: CVPixelBuffer, exif: [String: Any], context: CIContext) -> Data? {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
            kCGImagePropertyExifDictionary: exif,
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// `ARFrame.exifData` as is. Only a capture-time tag ARKit left out is
    /// filled from the wall clock (the simulator has no EXIF at all); ARKit's
    /// own values are never rewritten.
    static func exif(_ arkit: [String: Any], capturedAt date: Date) -> [String: Any] {
        var exif = arkit
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let offset = TimeZone.current.secondsFromGMT(for: date) / 60
        let fill: [CFString: String] = [
            kCGImagePropertyExifDateTimeOriginal: String(
                format: "%04d:%02d:%02d %02d:%02d:%02d",
                c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0),
            kCGImagePropertyExifSubsecTimeOriginal: String(format: "%03d", (c.nanosecond ?? 0) / 1_000_000),
            kCGImagePropertyExifOffsetTimeOriginal: String(
                format: "%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 60, abs(offset) % 60),
        ]
        for (key, value) in fill where exif[key as String] == nil {
            exif[key as String] = value
        }
        return exif
    }

    /// Deep copy, so the ARFrame's pool buffer goes back to ARKit at once.
    /// Adapted from SpAItial's prototype (ARCaptureCoordinator, MIT-0).
    static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        var copy: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source),
            CVPixelBufferGetPixelFormatType(source), attributes as CFDictionary, &copy) == kCVReturnSuccess,
            let copy
        else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        let planes = CVPixelBufferIsPlanar(source) ? CVPixelBufferGetPlaneCount(source) : 1
        for plane in 0..<planes {
            let planar = CVPixelBufferIsPlanar(source)
            guard let src = planar ? CVPixelBufferGetBaseAddressOfPlane(source, plane) : CVPixelBufferGetBaseAddress(source),
                  let dst = planar ? CVPixelBufferGetBaseAddressOfPlane(copy, plane) : CVPixelBufferGetBaseAddress(copy)
            else { return nil }
            let srcStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(source, plane) : CVPixelBufferGetBytesPerRow(source)
            let dstStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(copy, plane) : CVPixelBufferGetBytesPerRow(copy)
            let rows = planar ? CVPixelBufferGetHeightOfPlane(source, plane) : CVPixelBufferGetHeight(source)
            for row in 0..<rows {
                memcpy(dst + row * dstStride, src + row * srcStride, min(srcStride, dstStride))
            }
        }
        return copy
    }

    // MARK: Simulator walk

    #if targetEnvironment(simulator)
    private var simTimer: DispatchSourceTimer?
    private var simStart: TimeInterval = 0
    private var simFrame = 0

    private func startSimulatedWalk() {
        simStart = CACurrentMediaTime()
        simFrame = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30)
        timer.setEventHandler { [weak self] in self?.simTick() }
        timer.resume()
        simTimer = timer
    }

    /// A landscape-held camera walking a 1.2 m circle at 0.25 m/s, facing the
    /// walls, tilting gently up and down.
    private func simTick() {
        let now = CACurrentMediaTime()
        let t = Float(now - simStart)
        let angle = t * 0.25 / 1.2
        let outward = SIMD3<Float>(sin(angle), 0, -cos(angle))
        let pitch = 0.25 * sin(t * 0.6)
        let forward = simd_normalize(outward * cos(pitch) + SIMD3(0, sin(pitch), 0))
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        let back = -forward
        let up = simd_cross(back, right)
        let transform = simd_float4x4(SIMD4(right, 0), SIMD4(up, 0), SIMD4(back, 0), SIMD4(outward * 1.2 + SIMD3(0, 1.4, 0), 1))
        simFrame += 1
        let n = simFrame
        process(
            timestamp: now, transform: transform,
            intrinsics: simd_float3x3(SIMD3(1450, 0, 0), SIMD3(0, 1450, 0), SIMD3(960, 720, 1)),
            resolution: CGSize(width: 1920, height: 1440), exposure: 1.0 / 60, tracking: .normal,
            pixels: { Self.syntheticFrame(n) }, exif: { [:] })
    }

    /// 1920×1440 grey bands that shift per frame.
    private static func syntheticFrame(_ n: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, 1920, 1440, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess, let buffer
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<1440 {
            memset(base + row * stride, Int32(30 + (row / 24 + n * 9) % 200), stride)
        }
        return buffer
    }
    #endif
}

/// One accepted keyframe on its way to the write queue: the copied pixels,
/// its EXIF and its record (index 0 until written). Nothing else touches it
/// once enqueued.
nonisolated struct PendingFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let exif: [String: Any]
    let frame: RoomScanFrame
}
