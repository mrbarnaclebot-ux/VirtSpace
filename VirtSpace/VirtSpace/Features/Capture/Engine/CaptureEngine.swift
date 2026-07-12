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

import Foundation
import Observation
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

/// A completed 16-frame capture, persisted on disk and ready to upload.
struct CaptureResult: Equatable {
    let sessionID: UUID
    let directory: URL
    let frameCount: Int
}

// MARK: - Engine

@Observable
final class CaptureEngine {
    // MARK: Published state (mutated on the main queue only)

    private(set) var state: CaptureEngineState = .idle
    private(set) var targets: [CaptureTarget] = TargetLayout.targets()
    /// Per-target captured flag, indexed like `targets`.
    private(set) var capturedFlags: [Bool] = Array(repeating: false, count: 16)
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

    init(store: CaptureStore = CaptureStore()) {
        self.store = store
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
    }

    private func fail(_ message: String) {
        running = false
        source?.stop()
        source = nil
        publish { $0.state = .failed(message) }
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
            publish { $0.state = .ready(targetIndex: 0) }
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

        var warningText = pose.trackingWarning
        let thermal = ProcessInfo.processInfo.thermalState
        if warningText == nil, thermal == .serious || thermal == .critical {
            warningText = "iPhone is getting hot — capture may slow down"
        }

        publish {
            $0.angularDistanceDegrees = distance
            $0.yawDeltaDegrees = deltas.yaw
            $0.pitchDeltaDegrees = deltas.pitch
            $0.isSteady = steady
            $0.driftMeters = drift
            $0.warning = warningText
        }

        // Auto-fire: aligned + steady, continuously, with trustworthy tracking.
        guard !isTakingStill else { return }
        let aligned = AlignmentMath.isAligned(angularDistanceDegrees: distance)
        if dwell.update(aligned: aligned, steady: steady && pose.trackingWarning == nil, at: pose.timestamp) {
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
            // One missed shot shouldn't kill a 16-shot walk-around: surface it
            // and let the dwell re-fire on the same target.
            isTakingStill = false
            dwell.reset()
            publish {
                $0.warning = "Shot failed — hold on the target again (\(error.localizedDescription))"
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

            currentIndex += 1
            dwell.reset()
            let next = currentIndex

            if next >= targets.count {
                running = false
                source?.stop()
                source = nil
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
    }
}

// MARK: - DEBUG validation

#if DEBUG
extension CaptureEngine {
    /// Compile-and-runtime sanity checks on the pure math, run once at first
    /// engine start in debug builds (Stage B1 verification requirement).
    static let debugValidation: Void = {
        let targets = TargetLayout.targets()
        assert(targets.count == 16, "expected 16 targets")
        assert(targets.filter { $0.pitchDegrees == 0 }.count == 8, "expected 8 horizon targets")
        assert(targets.filter { $0.pitchDegrees == 45 }.count == 4, "expected 4 up-ring targets")
        assert(targets.filter { $0.pitchDegrees == -45 }.count == 2, "expected 2 down targets")
        assert(targets.filter { $0.pitchDegrees == 90 }.count == 1, "expected 1 zenith")
        assert(targets.filter { $0.pitchDegrees == -90 }.count == 1, "expected 1 nadir")
        assert(targets.allSatisfy { abs(simd_length($0.direction) - 1) < 1e-4 }, "directions must be unit vectors")
        assert(targets.map(\.index) == Array(0..<16), "indices must be capture-ordered")

        // Horizon neighbors sit 45° apart; forward is (0,0,-1); zenith is +Y.
        let d01 = AlignmentMath.angularDistanceDegrees(targets[0].direction, targets[1].direction)
        assert(abs(d01 - 45) < 0.01, "horizon spacing should be 45°, got \(d01)")
        assert(simd_length(targets[0].direction - simd_float3(0, 0, -1)) < 1e-4, "target 0 must be straight ahead")
        assert(simd_length(targets[14].direction - simd_float3(0, 1, 0)) < 1e-4, "zenith must be +Y")
        assert(simd_length(targets[15].direction - simd_float3(0, -1, 0)) < 1e-4, "nadir must be -Y")

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

        // Dwell: fires only after 300 ms of continuous aligned+steady.
        var dwell = DwellTracker()
        assert(!dwell.update(aligned: true, steady: true, at: 0))
        assert(!dwell.update(aligned: true, steady: true, at: 0.2))
        assert(dwell.update(aligned: true, steady: true, at: 0.31), "dwell should fire at 310 ms")
        assert(!dwell.update(aligned: false, steady: true, at: 0.4), "dwell must re-arm after firing")
    }()
}
#endif
