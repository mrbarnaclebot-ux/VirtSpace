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
//  CaptureHUDState. The engine itself is split by responsibility across
//  CaptureEngine+Pose (per frame), +Exposure, +Relocalization and +Shots.
//
//  Threading: pose callbacks and all internal mutation happen on a private
//  serial queue; the observable HUD state SwiftUI reads is only ever mutated
//  on the main queue via `publish`.
//

import ARKit
import Foundation
import OSLog
import simd

/// Confined to `queue` (the engine queue): every mutable member below the
/// `hud` reference is read and written only there. `hud` is a @MainActor class
/// (itself Sendable) and is only ever touched through `publish`. Engine state
/// is internal rather than private only so the CaptureEngine+*.swift
/// extensions can reach it; nothing outside those files touches it.
nonisolated final class CaptureEngine: @unchecked Sendable {
    /// Everything the capture UI renders. Main-actor-isolated and written ONLY
    /// through `publish`; the views observe it directly.
    let hud = CaptureHUDState()

    /// The capture pattern. Immutable, so both the engine queue and the main
    /// actor read the same array without coordination.
    var targets: [CaptureTarget] { hud.targets }

    // MARK: Engine-queue state (never touched from the main queue)

    let queue: DispatchQueue
    var source: CaptureSource?
    private let store: CaptureStore
    var session: CaptureStore.Session?

    /// Target directions rotated into ARKit world space (set once the heading
    /// basis is established from the first tracked frame).
    var worldTargets: [simd_float3] = []
    var currentIndex = 0
    var running = false
    /// Fired (on the engine queue) with the backend world id when a session
    /// that already minted a world is permanently discarded (abandon flow).
    /// The owner (CaptureScreenModel) uses it for a best-effort server-side
    /// delete; the worker's 24 h uploading reaper is the backstop. Fixed at
    /// init so the engine queue never reads it while the main actor writes it.
    private let onSessionDiscarded: @Sendable (String) -> Void
    /// True from dwell-fire until the next target is ready — gates the dwell
    /// machine while a still is in flight.
    var isTakingStill = false
    var previousTransform: simd_float4x4?
    var previousTimestamp: TimeInterval?
    var smoothedRate: Double = 0
    var dwell = DwellTracker()
    /// Camera position of every captured shot: their centroid is the pivot
    /// the drift coaching and the soft gate measure from (R37).
    var shotPositions: [simd_float3] = []
    var pivotGate = PivotGate()
    /// When the current relocalization began; past the timeout the HUD offers
    /// "Restart scan" (R31/R39).
    var relocalizingSince: TimeInterval?
    var isOfferingRestart = false
    /// Transient (non-pose) warnings stay visible this long (engine queue).
    var transientWarning: (text: String, until: TimeInterval)?

    /// Exposure lock lifecycle (spec §10 R34/R38): AE is metered while
    /// tracking initialises and locked once target 0 is up, and the dwell
    /// stays gated until the lock has been applied — so shot 0 is captured,
    /// and stamped, locked like every other frame.
    enum ExposurePhase { case metering, locking, locked }
    var exposurePhase = ExposurePhase.metering
    var meter = ExposureMeter()
    /// Low-light preflight: the lock waits while AE is pinned near its ceiling
    /// (turning the lights on clears it) unless the user chose to continue.
    var isShowingLowLight = false
    var lowLightAcknowledged = false

    /// Takes, persists and post-processes one still per fired dwell, and
    /// reports the outcome back here (see ShotPipeline).
    let shots: ShotPipeline

    /// Thermal mitigation: owns the thermal observer, the cool-down pause and
    /// the pure state→policy mapping (see ThermalGovernor).
    private let thermal: ThermalGovernor

    /// Coalesces the HUD publish to ~30 Hz and to meaningful changes only
    /// (Stage B3 deliverable 2b) — see HUDPublishThrottle.
    var throttle = HUDPublishThrottle()

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
            self.discardOnQueue()
            self.publish { $0.applyReset(state: .idle) }
        }
    }

    func discardOnQueue() {
        running = false
        source?.stop()
        source = nil
        if let session {
            if let worldId = store.createdWorldId(forSession: session.id, in: session.directory) {
                onSessionDiscarded(worldId)
            }
            store.purge(id: session.id)
        }
        resetOnQueue()
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
        shotPositions = []
        pivotGate.reset()
        relocalizingSince = nil
        isOfferingRestart = false
        exposurePhase = .metering
        meter.reset()
        isShowingLowLight = false
        lowLightAcknowledged = false
        shots.reset()
        transientWarning = nil
        thermal.reset()
        throttle.reset()
    }

    func fail(_ message: String) {
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
    func publish(_ mutation: @escaping @MainActor (CaptureHUDState) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { mutation(self.hud) }
        }
    }
}
