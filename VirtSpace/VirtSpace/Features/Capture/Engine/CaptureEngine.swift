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
//  This is the coordinator, not the whole capture: the shot I/O lives in
//  ShotPipeline, thermal mitigation in ThermalGovernor, the HUD publish
//  coalescing in HUDPublishThrottle, and every property the UI renders in
//  CaptureHUDState.
//
//  Threading: pose callbacks and all internal mutation happen on a private
//  serial queue; the observable HUD state SwiftUI reads is only ever mutated
//  on the main queue via `publish`.
//

import ARKit
import Foundation
import OSLog
import simd

// MARK: - State

enum CaptureEngineState: Equatable {
    case idle
    case starting
    case ready(targetIndex: Int)
    case capturing(targetIndex: Int)
    case advancing
    case finished(CaptureResult)
    case failed(String)

    /// Payload-free `.finished` test, for view code that has to branch on the
    /// state without binding the result (`if case` doesn't compose inside a
    /// ViewBuilder condition).
    var isFinished: Bool {
        if case .finished = self { return true }
        return false
    }
}

/// A completed full-sphere capture (28 frames), persisted on disk and ready to upload.
struct CaptureResult: Equatable {
    let sessionID: UUID
    let directory: URL
    let frameCount: Int
}

// MARK: - Engine

/// Confined to `queue` (the engine queue): every mutable member below the
/// `hud` reference is read and written only there. `hud` is a @MainActor class
/// (itself Sendable) and is only ever touched through `publish`.
nonisolated final class CaptureEngine: @unchecked Sendable {
    /// Everything the capture UI renders. Main-actor-isolated and written ONLY
    /// through `publish`; the views observe it directly.
    let hud = CaptureHUDState()

    /// The capture pattern. Immutable, so both the engine queue and the main
    /// actor read the same array without coordination.
    private var targets: [CaptureTarget] { hud.targets }

    // MARK: Engine-queue state (never touched from the main queue)

    private let queue: DispatchQueue
    private var source: CaptureSource?
    private let store: CaptureStore
    private var session: CaptureStore.Session?

    /// Target directions rotated into ARKit world space (set once the heading
    /// basis is established from the first tracked frame).
    private var worldTargets: [simd_float3] = []
    private var currentIndex = 0
    private var running = false
    /// Fired (on the engine queue) with the backend world id when a session
    /// that already minted a world is permanently discarded (abandon flow).
    /// The owner (CaptureScreenModel) uses it for a best-effort server-side
    /// delete; the worker's 24 h uploading reaper is the backstop. Fixed at
    /// init so the engine queue never reads it while the main actor writes it.
    private let onSessionDiscarded: @Sendable (String) -> Void
    /// True from dwell-fire until the next target is ready — gates the dwell
    /// machine while a still is in flight.
    private var isTakingStill = false
    private var previousTransform: simd_float4x4?
    private var previousTimestamp: TimeInterval?
    private var smoothedRate: Double = 0
    private var dwell = DwellTracker()
    private var firstShotPosition: simd_float3?
    /// Transient (non-pose) warnings stay visible this long (engine queue).
    private var transientWarning: (text: String, until: TimeInterval)?

    /// Takes, persists and post-processes one still per fired dwell, and
    /// reports the outcome back here (see ShotPipeline).
    private let shots: ShotPipeline

    /// Thermal mitigation: owns the thermal observer, the cool-down pause and
    /// the pure state→policy mapping (see ThermalGovernor).
    private let thermal: ThermalGovernor

    /// Coalesces the HUD publish to ~30 Hz and to meaningful changes only
    /// (Stage B3 deliverable 2b) — see HUDPublishThrottle.
    private var throttle = HUDPublishThrottle()

    init(
        store: CaptureStore = CaptureStore(),
        onSessionDiscarded: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        let queue = DispatchQueue(label: "com.virtspace.capture-engine")
        self.queue = queue
        self.store = store
        self.onSessionDiscarded = onSessionDiscarded
        self.thermal = ThermalGovernor(queue: queue)
        self.shots = ShotPipeline(store: store, queue: queue)

        // Wire the shot pipeline to this engine's session. `onPaintedShot`
        // lands on the pipeline's thumbnail queue; the rest is engine queue.
        shots.isCapturing = { [weak self] in self?.running ?? false }
        shots.lockCameraSettings = { [weak self] in self?.source?.lockCameraSettings() ?? false }
        shots.onExposureLock = { [weak self] locked in
            self?.publish { $0.exposureLocked = locked }
        }
        shots.onPaintedShot = { [weak self] shot in
            self?.publish { hud in
                if !hud.paintedShots.contains(where: { $0.index == shot.index }) {
                    hud.paintedShots.append(shot)
                }
            }
        }

        // Wire the governor to this engine's session. Every hook below is
        // invoked on `queue`, where the engine's own state already lives.
        thermal.isCapturing = { [weak self] in self?.running ?? false }
        thermal.pauseFeed = { [weak self] in self?.source?.pause() }
        thermal.resumeFeed = { [weak self] in self?.source?.resume() }
        thermal.onThermalChange = { [weak self] state, paused in
            self?.publish {
                $0.thermalState = state
                $0.isThermallyPaused = paused
            }
        }
        thermal.onResume = { [weak self] in
            self?.publish { $0.isThermallyPaused = false }
        }
    }

    // MARK: - Lifecycle

    /// Begin a capture. Caller is responsible for camera permission on device.
    /// Callable from `.idle` or `.failed` (retry).
    ///
    /// Main actor because it reads and writes `hud.state` synchronously: the
    /// `.starting` transition has to be visible to the caller's next render,
    /// so it cannot wait for a hop.
    @MainActor
    func start() {
        switch hud.state {
        case .idle, .failed: break
        default: return
        }
        hud.state = .starting
        queue.async { [weak self] in
            guard let self else { return }
            self.resetOnQueue()
            self.publish { $0.applyReset(state: .starting) }
            self.startOnQueue()
        }
    }

    /// Abort mid-capture: stops the camera and discards the partial session.
    /// If the session already minted a backend world (createdWorldId in the
    /// manifest), `onSessionDiscarded` fires with that id BEFORE the local
    /// purge so the caller can best-effort delete the server-side world —
    /// otherwise it would sit orphaned in `uploading` (the worker's 24 h
    /// reaper is the backstop when the delete can't land, e.g. offline).
    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.source?.stop()
            self.source = nil
            if let session = self.session {
                if let worldId = self.store.createdWorldId(forSession: session.id, in: session.directory) {
                    self.onSessionDiscarded(worldId)
                }
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
        let thermalState = thermal.currentState
        publish { $0.thermalState = thermalState }

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
        shots.reset()
        transientWarning = nil
        thermal.reset()
        throttle.reset()
    }

    private func fail(_ message: String) {
        running = false
        source?.stop()
        source = nil
        AppLog.engine.error("Capture failed: \(message, privacy: .public)")
        publish { $0.state = .failed(message) }
    }

    // MARK: - Thermal mitigation (Stage B3 deliverable 2e)

    /// User-driven resume from a thermal-critical pause (see resume UI).
    func resumeFromThermal() {
        queue.async { [weak self] in self?.thermal.resumeFromPause() }
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

    // MARK: - Engine queue: shots

    private func takeStill() {
        guard let source, let session else { return }
        isTakingStill = true
        let index = currentIndex
        publish { $0.state = .capturing(targetIndex: index) }

        shots.take(index: index, from: source, into: session, totalTargets: targets.count) { [weak self] outcome in
            self?.handleShot(outcome, session: session)
        }
    }

    /// Engine queue: fold one shot's outcome back into the walk-around.
    private func handleShot(_ outcome: ShotOutcome, session: CaptureStore.Session) {
        switch outcome {
        case .saveFailed(_, let message):
            fail(message)

        case .failed(let index, let message):
            // One missed shot shouldn't kill a 28-shot walk-around: surface it
            // and let the dwell re-fire on the same target.
            isTakingStill = false
            dwell.reset()
            transientWarning = (message, (previousTimestamp ?? 0) + 3.0)
            publish {
                $0.warning = message
                $0.state = .ready(targetIndex: index)
            }

        case .saved(let index, let transform):
            // First shot pins the pivot origin for parallax coaching (the
            // exposure lock is the pipeline's half of the same rule).
            if index == 0 {
                firstShotPosition = AlignmentMath.position(of: transform)
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
                ShotPipeline.celebrationHaptic()
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

    // MARK: - Publishing

    /// Apply a mutation to the observable HUD state on the main queue. This is
    /// the ONE door between the engine queue and the main actor — nothing else
    /// in the engine touches `hud`.
    ///
    /// `DispatchQueue.main.async` rather than a `Task { @MainActor }` on
    /// purpose: publishes must stay strictly FIFO with respect to each other
    /// (a `.capturing` must never land after the `.ready` that follows it), and
    /// only the queue guarantees that. `assumeIsolated` is therefore a fact,
    /// not a wish — the block is already running on the main queue.
    private func publish(_ mutation: @escaping @MainActor (CaptureHUDState) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { mutation(self.hud) }
        }
    }
}
