//
//  CaptureEngine.swift
//  VirtSpace
//
//  The guided-capture state machine (Stage B1 — spec §5, §6.1, §9):
//  idle → starting → ready(targetIndex) → capturing → advancing → …
//  → finished(CaptureResult) | failed(String).
//
//  Owns the CaptureSource (ARKit on device, simulated in the simulator).
//  World alignment is `.gravity` — NOT gravityAndHeading; the heading basis
//  is derived from the first tracked frame's camera yaw so target 0 is
//  "straight ahead of wherever the user started looking".
//
//  Threading: pose callbacks and all internal mutation happen on a private
//  serial queue; the @Observable properties SwiftUI reads are only ever
//  mutated on the main queue via `publish`.
//

import ARKit
import Foundation
import ImageIO
import Observation
import OSLog
import simd
import UIKit

// MARK: - State

enum CaptureEngineState: Equatable {
    case idle
    case starting
    case ready(targetIndex: Int)
    case capturing(targetIndex: Int)
    case advancing
    case finished(CaptureResult)
    case failed(String)
}

/// A completed full-sphere capture (28 frames), persisted on disk and ready to upload.
struct CaptureResult: Equatable {
    let sessionID: UUID
    let directory: URL
    let frameCount: Int
}

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

// MARK: - Engine

@Observable
final class CaptureEngine {
    // MARK: Published state (mutated on the main queue only)

    private(set) var state: CaptureEngineState = .idle
    private(set) var targets: [CaptureTarget] = TargetLayout.targets()
    /// Per-target captured flag, indexed like `targets`.
    private(set) var capturedFlags: [Bool] = Array(repeating: false, count: TargetLayout.targets().count)
    /// Degrees between the camera forward and the current target.
    private(set) var angularDistanceDegrees: Double = 180
    /// Signed aim hints, degrees: yaw > 0 → turn right; pitch > 0 → look up.
    private(set) var yawDeltaDegrees: Double = 0
    private(set) var pitchDeltaDegrees: Double = 0
    private(set) var isSteady = false
    /// Meters of translation from the first shot's position (parallax coaching).
    private(set) var driftMeters: Float = 0
    /// Whether AE/AWB/AF locked successfully after the first shot.
    private(set) var exposureLocked = false
    /// Tracking/thermal warning to surface, or nil.
    private(set) var warning: String?

    // MARK: HUD state (Stage B2)

    /// Latest camera-to-world transform (ARKit portrait camera convention).
    private(set) var cameraTransform: simd_float4x4 = matrix_identity_float4x4
    /// Latest camera intrinsics + the sensor resolution they refer to.
    private(set) var cameraIntrinsics: simd_float3x3 = matrix_identity_float3x3
    private(set) var imageResolution: CGSize = .zero
    /// World-space direction per target (empty until the heading basis locks).
    private(set) var targetDirections: [simd_float3] = []
    /// Dwell completion [0, 1] for the reticle's ring fill.
    private(set) var dwellProgress: Double = 0
    /// The live ARSession for the camera preview (device only, nil in sim).
    private(set) var previewSession: ARSession?

    // MARK: Paint-the-sphere state (Stage B3)

    /// Accumulated painted shots, one per successful capture. The camera-layer
    /// (device SceneKit / simulator Canvas) observes this and hangs a textured
    /// quad on the virtual sphere for each new entry.
    private(set) var paintedShots: [PaintedShot] = []

    // MARK: Thermal state (Stage B3)

    /// Latest `ProcessInfo.thermalState`, mirrored onto the main actor so the
    /// HUD can coach ("warming up") and the preview can drop its frame rate.
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    /// True when we've paused the session because the device hit `.critical`.
    /// Cleared by `resumeFromThermal()`.
    private(set) var isThermallyPaused = false

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

    // MARK: Engine-queue state (never touched from the main queue)

    @ObservationIgnored private let queue = DispatchQueue(label: "com.virtspace.capture-engine")
    @ObservationIgnored private var source: CaptureSource?
    @ObservationIgnored private let store: CaptureStore
    @ObservationIgnored private var session: CaptureStore.Session?

    /// Target directions rotated into ARKit world space (set once the heading
    /// basis is established from the first tracked frame).
    @ObservationIgnored private var worldTargets: [simd_float3] = []
    @ObservationIgnored private var currentIndex = 0
    @ObservationIgnored private var running = false
    /// True from dwell-fire until the next target is ready — gates the dwell
    /// machine while a still is in flight.
    @ObservationIgnored private var isTakingStill = false
    @ObservationIgnored private var previousTransform: simd_float4x4?
    @ObservationIgnored private var previousTimestamp: TimeInterval?
    @ObservationIgnored private var smoothedRate: Double = 0
    @ObservationIgnored private var dwell = DwellTracker()
    @ObservationIgnored private var firstShotPosition: simd_float3?
    @ObservationIgnored private var exposureLockedInternal = false
    /// Transient (non-pose) warnings stay visible this long (engine queue).
    @ObservationIgnored private var transientWarning: (text: String, until: TimeInterval)?

    /// Background queue for downscaling paint thumbnails — never the main actor.
    @ObservationIgnored private let thumbnailQueue = DispatchQueue(label: "com.virtspace.capture-thumbnails", qos: .utility)

    /// Whether the session is paused for thermal reasons (engine-queue mirror).
    @ObservationIgnored private var thermalPausedInternal = false
    @ObservationIgnored private var thermalObserver: NSObjectProtocol?

    // Publish throttle (Stage B3 deliverable 2b): ARFrames arrive at 60 Hz;
    // coalesce the HUD-state publish to ~30 Hz and only on meaningful change so
    // we don't force a whole-HUD SwiftUI re-render every frame.
    @ObservationIgnored private var lastPublishTime: TimeInterval = 0
    @ObservationIgnored private var lastPublishedAngle: Double = .infinity
    @ObservationIgnored private var lastPublishedSteady = false
    @ObservationIgnored private var lastPublishedTargetIndex = -1
    @ObservationIgnored private var lastPublishedDwell: Double = 0
    @ObservationIgnored private var lastPublishedWarning: String?

    init(store: CaptureStore = CaptureStore()) {
        self.store = store
        // React to thermal pressure even before capture starts.
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleThermalStateChange()
        }
    }

    deinit {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
    }

    // MARK: - Lifecycle

    /// Begin a capture. Caller is responsible for camera permission on device.
    /// Callable from `.idle` or `.failed` (retry).
    func start() {
        switch state {
        case .idle, .failed: break
        default: return
        }
        #if DEBUG
        _ = Self.debugValidation // asserts TargetLayout/AlignmentMath invariants
        #endif
        state = .starting
        queue.async { [weak self] in
            guard let self else { return }
            self.resetOnQueue()
            self.publish { $0.applyReset(state: .starting) }
            self.startOnQueue()
        }
    }

    /// Abort mid-capture: stops the camera and discards the partial session.
    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.source?.stop()
            self.source = nil
            if let session = self.session {
                self.store.purge(id: session.id)
            }
            self.resetOnQueue()
            self.publish { $0.applyReset(state: .idle) }
        }
    }

    /// Return to idle after `.finished` or `.failed` (e.g. once the upload is
    /// handed off) so another scan can start.
    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.resetOnQueue()
            self.publish { $0.applyReset(state: .idle) }
        }
    }

    // MARK: - Engine queue: setup

    private func startOnQueue() {
        do {
            session = try store.createSession(expectedFrameCount: targets.count)
        } catch {
            fail("Couldn't create a capture folder: \(error.localizedDescription)")
            return
        }

        #if targetEnvironment(simulator)
        let simulated = SimulatedCaptureSource(queue: queue)
        simulated.desiredDirection = { [weak self] in
            guard let self, self.running, self.worldTargets.indices.contains(self.currentIndex) else { return nil }
            return self.worldTargets[self.currentIndex]
        }
        source = simulated
        #else
        source = ARKitCaptureSource(queue: queue)
        #endif

        source?.onPose = { [weak self] pose in self?.handlePose(pose) }
        source?.onError = { [weak self] message in self?.fail(message) }

        running = true
        currentIndex = 0
        source?.start()
        AppLog.engine.log("Capture started: session \(self.session?.id.uuidString ?? "?", privacy: .public)")

        // Seed the published thermal state so the HUD reflects reality on entry.
        let thermal = ProcessInfo.processInfo.thermalState
        publish { $0.thermalState = thermal }

        // Hand the live session to the HUD's camera preview (device only).
        if let arSource = source as? ARKitCaptureSource {
            let arSession = arSource.arSession
            publish { $0.previewSession = arSession }
        }
    }

    private func resetOnQueue() {
        running = false
        source = nil
        session = nil
        worldTargets = []
        currentIndex = 0
        isTakingStill = false
        previousTransform = nil
        previousTimestamp = nil
        smoothedRate = 0
        dwell.reset()
        firstShotPosition = nil
        exposureLockedInternal = false
        transientWarning = nil
        thermalPausedInternal = false
        lastPublishTime = 0
        lastPublishedAngle = .infinity
        lastPublishedSteady = false
        lastPublishedTargetIndex = -1
        lastPublishedDwell = 0
        lastPublishedWarning = nil
    }

    private func fail(_ message: String) {
        running = false
        source?.stop()
        source = nil
        AppLog.engine.error("Capture failed: \(message, privacy: .public)")
        publish { $0.state = .failed(message) }
    }

    // MARK: - Thermal mitigation (Stage B3 deliverable 2e)

    /// Called on the notification queue when `ProcessInfo.thermalState` changes.
    /// Hops to the engine queue to mutate session state safely.
    private func handleThermalStateChange() {
        let state = ProcessInfo.processInfo.thermalState
        queue.async { [weak self] in self?.applyThermalState(state) }
    }

    private func applyThermalState(_ state: ProcessInfo.ThermalState) {
        AppLog.engine.log("Thermal state: \(Self.thermalName(state), privacy: .public)")
        // At .critical, pause the live session to let the device cool. We keep
        // the world/heading basis (source.pause(), not a reset) so resume picks
        // up where we left off. Below .critical we leave resume to the user.
        if state == .critical, running, !thermalPausedInternal {
            thermalPausedInternal = true
            source?.pause()
            AppLog.engine.error("Thermal critical — session paused")
        }
        let paused = thermalPausedInternal
        publish {
            $0.thermalState = state
            $0.isThermallyPaused = paused
        }
    }

    /// User-driven resume from a thermal-critical pause (see resume UI).
    func resumeFromThermal() {
        queue.async { [weak self] in
            guard let self, self.thermalPausedInternal else { return }
            self.thermalPausedInternal = false
            self.source?.resume()
            AppLog.engine.log("Thermal resume requested by user")
            self.publish { $0.isThermallyPaused = false }
        }
    }

    // MARK: Thermal decision mapping (pure — DEBUG-assertable)

    /// Viewfinder frame rate for a thermal state: 24 fps at serious/critical to
    /// shed load + heat, else 30. Extracted as a pure function so it can be
    /// asserted in DEBUG (the simulator can never raise the real thermalState).
    static func previewFrameRate(for state: ProcessInfo.ThermalState) -> Int {
        switch state {
        case .serious, .critical: return 24
        default: return 30
        }
    }

    /// Whether the "warming up" coaching banner shows (serious only; critical is
    /// the full-screen pause UI, not a banner).
    static func showsWarmingBanner(for state: ProcessInfo.ThermalState) -> Bool {
        state == .serious
    }

    /// Whether we pause the session for cool-down (critical only).
    static func pausesSession(for state: ProcessInfo.ThermalState) -> Bool {
        state == .critical
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Engine queue: per-frame

    private func handlePose(_ pose: CapturePose) {
        guard running else { return }

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

        guard worldTargets.indices.contains(currentIndex) else { return }
        let target = worldTargets[currentIndex]
        let distance = AlignmentMath.angularDistanceDegrees(forward, target)
        let deltas = AlignmentMath.signedDeltas(cameraForward: forward, targetDirection: target)
        let steady = AlignmentMath.isSteady(rotationRate: smoothedRate)
        let drift = firstShotPosition.map { AlignmentMath.translationDrift(from: $0, current: position) } ?? 0

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
            if dwell.update(aligned: aligned, steady: steady && pose.trackingWarning == nil, at: pose.timestamp) {
                progress = 1
            } else {
                progress = dwell.progress(at: pose.timestamp)
            }
        }

        // Coalesce the HUD publish to ~30 Hz and only when something the HUD
        // actually renders has moved: while the camera is turning (so all dots
        // track), when the angle/steadiness/target/dwell/warning changes, or on
        // the firing frame. A held-still, unchanged frame publishes nothing —
        // no wasteful whole-HUD SwiftUI re-render (Stage B3 deliverable 2b).
        let now = pose.timestamp
        let due = (now - lastPublishTime) >= (1.0 / 30.0)
        let moving = smoothedRate > 0.02 // rad/s (~1.1°/s)
        let angleMoved = abs(distance - lastPublishedAngle) > 0.3
        let steadyFlip = steady != lastPublishedSteady
        let targetChanged = currentIndex != lastPublishedTargetIndex
        let dwellMoved = abs(progress - lastPublishedDwell) > 0.01
        let warningChanged = warningText != lastPublishedWarning
        let meaningful = moving || angleMoved || steadyFlip || targetChanged
            || dwellMoved || warningChanged || progress >= 1

        if due && meaningful {
            lastPublishTime = now
            lastPublishedAngle = distance
            lastPublishedSteady = steady
            lastPublishedTargetIndex = currentIndex
            lastPublishedDwell = progress
            lastPublishedWarning = warningText

            let transform = pose.transform
            let intrinsics = pose.intrinsics
            let resolution = pose.imageResolution
            publish {
                $0.angularDistanceDegrees = distance
                $0.yawDeltaDegrees = deltas.yaw
                $0.pitchDeltaDegrees = deltas.pitch
                $0.isSteady = steady
                $0.driftMeters = drift
                $0.warning = warningText
                $0.cameraTransform = transform
                $0.cameraIntrinsics = intrinsics
                $0.imageResolution = resolution
                $0.dwellProgress = progress
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

    // MARK: - Engine queue: shots

    private func takeStill() {
        guard let source, let session else { return }
        isTakingStill = true
        let index = currentIndex
        publish { $0.state = .capturing(targetIndex: index) }

        source.captureStill { [weak self] result in
            guard let self else { return }
            self.queue.async { self.handleStill(result, index: index, session: session) }
        }
    }

    private func handleStill(_ result: Result<CapturedStill, Error>, index: Int, session: CaptureStore.Session) {
        guard running else { return }

        switch result {
        case .failure(let error):
            // One missed shot shouldn't kill a 28-shot walk-around: surface it
            // and let the dwell re-fire on the same target.
            isTakingStill = false
            dwell.reset()
            let text = "Shot failed — hold on the target again (\(error.localizedDescription))"
            transientWarning = (text, (previousTimestamp ?? 0) + 3.0)
            publish {
                $0.warning = text
                $0.state = .ready(targetIndex: index)
            }

        case .success(let still):
            let pose = CaptureStore.FramePose(
                index: index,
                timestamp: still.timestamp,
                transform: still.transform,
                intrinsics: still.intrinsics,
                exposureLocked: exposureLockedInternal
            )
            do {
                try store.saveFrame(still.jpegData, pose: pose, in: session)
            } catch {
                fail("Couldn't save frame \(index + 1): \(error.localizedDescription)")
                return
            }
            AppLog.capture.log("Shot \(index + 1)/\(self.targets.count) saved")

            // Paint the sphere (Stage B3 deliverable 1): downscale the JPEG to a
            // ~512 px thumbnail off the main actor, then publish a PaintedShot
            // carrying the CAPTURED transform + intrinsics for the camera layer
            // to hang a quad in that direction.
            let jpeg = still.jpegData
            let paintTransform = still.transform
            let paintIntrinsics = still.intrinsics
            thumbnailQueue.async { [weak self] in
                guard let self, let thumb = Self.makePaintThumbnail(from: jpeg, maxDimension: 512) else { return }
                let shot = PaintedShot(index: index, transform: paintTransform, intrinsics: paintIntrinsics, thumbnail: thumb)
                self.publish { engine in
                    if !engine.paintedShots.contains(where: { $0.index == index }) {
                        engine.paintedShots.append(shot)
                    }
                }
            }

            // First shot: pin the pivot origin and lock AE/AWB/AF so the
            // remaining 15 frames match (spec §9: exposure/WB seams).
            if index == 0 {
                firstShotPosition = AlignmentMath.position(of: still.transform)
                exposureLockedInternal = source?.lockCameraSettings() ?? false
                let locked = exposureLockedInternal
                publish { $0.exposureLocked = locked }
            }

            Task { @MainActor in
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            // Ring-completion celebrations: horizon ring (index 7), upper
            // ring (11), down pair (13). The final shot's success haptic
            // fires below with `.finished`.
            if index == 7 || index == 11 || index == 13 {
                Task { @MainActor in
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }

            currentIndex += 1
            dwell.reset()
            let next = currentIndex

            if next >= targets.count {
                running = false
                source?.stop()
                source = nil
                AppLog.capture.log("Capture complete: \(self.targets.count) frames, session \(session.id.uuidString, privacy: .public)")
                let result = CaptureResult(
                    sessionID: session.id,
                    directory: session.directory,
                    frameCount: targets.count
                )
                publish {
                    $0.capturedFlags[index] = true
                    $0.state = .finished(result)
                }
                Task { @MainActor in
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } else {
                publish {
                    $0.capturedFlags[index] = true
                    $0.state = .advancing
                }
                // Brief beat on .advancing so the UI can acknowledge the shot,
                // then open the next target. Dwell stays gated until then.
                queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self, self.running else { return }
                    self.isTakingStill = false
                    self.publish { $0.state = .ready(targetIndex: next) }
                }
            }
        }
    }

    // MARK: - Paint thumbnails

    /// Downscale JPEG data to a thumbnail no larger than `maxDimension` on its
    /// long edge, using ImageIO so we never fully decode the full-res image.
    /// Runs on `thumbnailQueue` (utility QoS) — never the main actor.
    private static func makePaintThumbnail(from data: Data, maxDimension: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: - Publishing

    /// Apply a mutation to the observable surface on the main queue.
    private func publish(_ mutation: @escaping (CaptureEngine) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            mutation(self)
        }
    }

    private func applyReset(state: CaptureEngineState) {
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

// MARK: - DEBUG validation

#if DEBUG
extension CaptureEngine {
    /// Compile-and-runtime sanity checks on the pure math, run once at first
    /// engine start in debug builds (Stage B1 verification requirement).
    static let debugValidation: Void = {
        // Phase 0.5 densified pattern: 12 horizon (30°) + 8 up (45°) +
        // 6 down (60°) + zenith + nadir = 28.
        let targets = TargetLayout.targets()
        assert(targets.count == 28, "expected 28 targets")
        assert(targets.filter { $0.pitchDegrees == 0 }.count == 12, "expected 12 horizon targets")
        assert(targets.filter { $0.pitchDegrees == 45 }.count == 8, "expected 8 up-ring targets")
        assert(targets.filter { $0.pitchDegrees == -45 }.count == 6, "expected 6 down-ring targets")
        assert(targets.filter { $0.pitchDegrees == 90 }.count == 1, "expected 1 zenith")
        assert(targets.filter { $0.pitchDegrees == -90 }.count == 1, "expected 1 nadir")
        assert(targets.allSatisfy { abs(simd_length($0.direction) - 1) < 1e-4 }, "directions must be unit vectors")
        assert(targets.map(\.index) == Array(0..<28), "indices must be capture-ordered")

        // Horizon neighbors sit 30° apart; forward is (0,0,-1); poles are ±Y.
        let d01 = AlignmentMath.angularDistanceDegrees(targets[0].direction, targets[1].direction)
        assert(abs(d01 - 30) < 0.01, "horizon spacing should be 30°, got \(d01)")
        assert(simd_length(targets[0].direction - simd_float3(0, 0, -1)) < 1e-4, "target 0 must be straight ahead")
        assert(simd_length(targets[26].direction - simd_float3(0, 1, 0)) < 1e-4, "zenith must be +Y")
        assert(simd_length(targets[27].direction - simd_float3(0, -1, 0)) < 1e-4, "nadir must be -Y")

        // Forward of the identity transform is -Z; drift math is euclidean.
        assert(simd_length(AlignmentMath.forward(of: matrix_identity_float4x4) - simd_float3(0, 0, -1)) < 1e-5)
        let drift = AlignmentMath.translationDrift(from: simd_float3(0, 0, 0), current: simd_float3(0.3, 0, 0.4))
        assert(abs(drift - 0.5) < 1e-5, "drift should be 0.5 m, got \(drift)")

        // Signed deltas: a target to the right yields positive yaw.
        let deltas = AlignmentMath.signedDeltas(
            cameraForward: simd_float3(0, 0, -1),
            targetDirection: simd_float3(1, 0, 0)
        )
        assert(abs(deltas.yaw - 90) < 0.01, "right target should be yaw +90, got \(deltas.yaw)")

        // Dwell: fires only after 300 ms of continuous aligned+steady, and
        // reports fractional progress for the HUD ring.
        var dwell = DwellTracker()
        assert(!dwell.update(aligned: true, steady: true, at: 0))
        assert(!dwell.update(aligned: true, steady: true, at: 0.15))
        let progress = dwell.progress(at: 0.15)
        assert(abs(progress - 0.5) < 0.01, "dwell progress at 150 ms should be 0.5, got \(progress)")
        assert(dwell.update(aligned: true, steady: true, at: 0.31), "dwell should fire at 310 ms")
        assert(!dwell.update(aligned: false, steady: true, at: 0.4), "dwell must re-arm after firing")

        // HUD projection (Stage B2): identity camera, portrait mapping.
        let fakeIntrinsics = simd_float3x3(
            simd_float3(1500, 0, 0), simd_float3(0, 1500, 0), simd_float3(720, 540, 1)
        )
        let viewSize = CGSize(width: 400, height: 800)
        let resolution = CGSize(width: 1440, height: 1080)
        let ahead = TargetProjection.project(
            worldDirection: simd_float3(0, 0, -1), cameraTransform: matrix_identity_float4x4,
            intrinsics: fakeIntrinsics, imageResolution: resolution, viewSize: viewSize
        )
        assert(ahead.isInFront && ahead.isOnScreen, "straight-ahead target must be on screen")
        assert(abs(ahead.point.x - 200) < 0.5 && abs(ahead.point.y - 400) < 0.5,
               "straight-ahead target must project to screen center, got \(ahead.point)")
        // Camera +Y is screen-right in portrait → a +Y-ish direction lands right of center.
        let rightish = TargetProjection.project(
            worldDirection: simd_normalize(simd_float3(0, 0.25, -1)), cameraTransform: matrix_identity_float4x4,
            intrinsics: fakeIntrinsics, imageResolution: resolution, viewSize: viewSize
        )
        assert(rightish.point.x > 200 && abs(rightish.point.y - 400) < 0.5,
               "camera+Y direction must land screen-right, got \(rightish.point)")
        let behind = TargetProjection.project(
            worldDirection: simd_float3(0, 0, 1), cameraTransform: matrix_identity_float4x4,
            intrinsics: fakeIntrinsics, imageResolution: resolution, viewSize: viewSize
        )
        assert(!behind.isInFront && !behind.isOnScreen, "behind-camera target must be off screen")

        // Thermal decision mapping (Stage B3 deliverable 2e): the simulator can
        // never raise the real thermalState, so assert the pure mapping instead.
        assert(CaptureEngine.previewFrameRate(for: .nominal) == 30, "nominal → 30 fps")
        assert(CaptureEngine.previewFrameRate(for: .fair) == 30, "fair → 30 fps")
        assert(CaptureEngine.previewFrameRate(for: .serious) == 24, "serious → 24 fps")
        assert(CaptureEngine.previewFrameRate(for: .critical) == 24, "critical → 24 fps")
        assert(!CaptureEngine.showsWarmingBanner(for: .nominal), "nominal shows no warming banner")
        assert(!CaptureEngine.showsWarmingBanner(for: .fair), "fair shows no warming banner")
        assert(CaptureEngine.showsWarmingBanner(for: .serious), "serious shows warming banner")
        assert(!CaptureEngine.showsWarmingBanner(for: .critical), "critical uses pause UI, not banner")
        assert(!CaptureEngine.pausesSession(for: .serious), "serious does not pause")
        assert(CaptureEngine.pausesSession(for: .critical), "critical pauses the session")

        // Paint-the-sphere quad sizing (deliverable 1): at radius 2.5 m with the
        // fake intrinsics (fx=1500, cx=720 → imageWidth≈1440), the quad width
        // should subtend the FOV: width = radius · (2·cx) / fx.
        let paint = PaintedShot(
            index: 0, transform: matrix_identity_float4x4,
            intrinsics: fakeIntrinsics, thumbnail: UIImage()
        )
        let expectedWidth = Float(2.5) * paint.approxImageWidth / fakeIntrinsics.columns.0.x
        assert(abs(expectedWidth - 2.5 * 1440 / 1500) < 1e-3, "quad width must match FOV at radius")
    }()
}
#endif
