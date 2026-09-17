//
//  ThermalGovernor.swift
//  VirtSpace
//
//  Thermal mitigation for the guided capture (Stage B3 deliverable 2e),
//  extracted from CaptureEngine (spec §10 R14).
//
//  Two halves:
//   • A pure decision mapping (frame rate, coaching banner, pause) — static,
//     side-effect free, and DEBUG/unit-assertable, because the simulator can
//     never raise a real `ProcessInfo.thermalState`.
//   • A live observer that watches `thermalStateDidChangeNotification` and, at
//     `.critical`, suspends the camera feed so the device can cool. We pause
//     (not reset) the source, so the world frame and the engine's heading basis
//     survive and `resumeFromPause()` picks up exactly where we left off.
//
//  Threading: the notification lands on an arbitrary queue and immediately hops
//  to the engine queue. `isPaused` and every hook below are therefore confined
//  to that queue — the governor never touches the main actor itself; it hands
//  changes to the engine, which owns publishing.
//

import Foundation
import OSLog

/// Confined to the engine queue: every mutable member (`isPaused`, `observer`
/// and the hooks) is read and written only there — the notification callback
/// hops onto it before touching anything, and the engine wires the hooks in
/// `init` before the object is shared.
nonisolated final class ThermalGovernor: @unchecked Sendable {
    // MARK: - Decision mapping (pure)

    /// Viewfinder frame rate for a thermal state: 24 fps at serious/critical to
    /// shed load + heat, else 30.
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

    static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Engine-queue state

    /// True when we've paused the session because the device hit `.critical`.
    /// Cleared by `resumeFromPause()` or `reset()`. Engine queue only.
    private(set) var isPaused = false

    private let queue: DispatchQueue
    private var observer: NSObjectProtocol?

    // MARK: - Hooks (set once by the engine; all called on `queue`)

    /// Whether a capture is actually live — we only pause a running session.
    var isCapturing: () -> Bool = { false }
    /// Suspend the camera feed WITHOUT tearing down tracking.
    var pauseFeed: () -> Void = {}
    /// Resume after `pauseFeed()`, preserving the established world frame.
    var resumeFeed: () -> Void = {}
    /// A thermal state change landed: (new state, whether we're now paused).
    var onThermalChange: (ProcessInfo.ThermalState, Bool) -> Void = { _, _ in }
    /// The user resumed from a thermal pause.
    var onResume: () -> Void = {}

    // MARK: - Lifecycle

    init(queue: DispatchQueue) {
        self.queue = queue
        // React to thermal pressure even before capture starts.
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleStateChange()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// The hardware's current state — read when capture starts so the HUD
    /// reflects reality on entry rather than waiting for the first change.
    var currentState: ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }

    // MARK: - Engine queue

    /// Clear the session-pause flag for a fresh capture. The thermal state
    /// itself is hardware, not session state, and is deliberately untouched.
    func reset() {
        isPaused = false
    }

    /// Called on the notification queue when `ProcessInfo.thermalState`
    /// changes. Hops to the engine queue to mutate session state safely.
    private func handleStateChange() {
        let state = ProcessInfo.processInfo.thermalState
        queue.async { [weak self] in self?.apply(state) }
    }

    /// Apply a thermal state on the engine queue.
    func apply(_ state: ProcessInfo.ThermalState) {
        AppLog.engine.log("Thermal state: \(Self.name(state), privacy: .public)")
        // At .critical, pause the live session to let the device cool. Below
        // .critical we leave resuming to the user.
        if Self.pausesSession(for: state), isCapturing(), !isPaused {
            isPaused = true
            pauseFeed()
            AppLog.engine.error("Thermal critical — session paused")
        }
        onThermalChange(state, isPaused)
    }

    /// User-driven resume from a thermal-critical pause (see the resume UI).
    func resumeFromPause() {
        guard isPaused else { return }
        isPaused = false
        resumeFeed()
        AppLog.engine.log("Thermal resume requested by user")
        onResume()
    }
}
