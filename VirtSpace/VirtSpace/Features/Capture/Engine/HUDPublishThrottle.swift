//
//  HUDPublishThrottle.swift
//  VirtSpace
//
//  The HUD publish coalescer (Stage B3 deliverable 2b), extracted from
//  CaptureEngine so the policy is testable on its own (spec §10 R14).
//
//  ARFrames arrive at 60 Hz. Republishing the observable HUD surface on every
//  one of them forces a whole-HUD SwiftUI re-render 60 times a second for no
//  visible benefit, so this gate coalesces publishes to ~30 Hz AND drops any
//  frame where nothing the HUD actually renders has moved.
//
//  Pure value type, no I/O, no clock of its own — the caller supplies the
//  frame timestamp. Lives on (and is only ever mutated from) the engine queue.
//

import Foundation

nonisolated struct HUDPublishThrottle {
    // MARK: Policy constants

    /// Publish cadence ceiling: at most one publish per this interval.
    static let minimumInterval: TimeInterval = 1.0 / 30.0
    /// Camera rotation above this (rad/s ≈ 1.1°/s) counts as "the user is
    /// turning", which moves every world-locked dot — always worth a publish.
    static let movingRateRadPerSec: Double = 0.02
    /// Angle-to-target must move at least this much (degrees) to count.
    static let angleEpsilonDegrees: Double = 0.3
    /// Dwell ring fill must move at least this much [0, 1] to count.
    static let dwellEpsilon: Double = 0.01

    // MARK: Sample

    /// Everything the coalescing predicate looks at for one pose frame.
    struct Sample: Equatable {
        /// Frame timestamp (the pose clock, not wall time).
        var timestamp: TimeInterval
        var angleDegrees: Double
        var isSteady: Bool
        var targetIndex: Int
        var dwellProgress: Double
        var warning: String?
        /// Smoothed camera rotation rate for this frame, rad/s.
        var rotationRate: Double
    }

    // MARK: State (engine queue)

    private var lastPublishTime: TimeInterval = 0
    private var lastAngleDegrees: Double = .infinity
    private var lastSteady = false
    private var lastTargetIndex = -1
    private var lastDwellProgress: Double = 0
    private var lastWarning: String?

    // MARK: Decision

    /// Whether this frame should be published. Returning true COMMITS the
    /// sample as the new baseline, so each frame must be offered exactly once.
    mutating func shouldPublish(_ sample: Sample) -> Bool {
        let due = (sample.timestamp - lastPublishTime) >= Self.minimumInterval
        guard due, Self.isMeaningful(sample, since: self) else { return false }

        lastPublishTime = sample.timestamp
        lastAngleDegrees = sample.angleDegrees
        lastSteady = sample.isSteady
        lastTargetIndex = sample.targetIndex
        lastDwellProgress = sample.dwellProgress
        lastWarning = sample.warning
        return true
    }

    /// Back to the just-initialised state — a new capture starts clean.
    mutating func reset() {
        self = HUDPublishThrottle()
    }

    /// Has anything the HUD renders actually changed since the last publish?
    /// A firing frame (`dwellProgress >= 1`) always counts: the shot flash and
    /// the capturing state must never be coalesced away.
    private static func isMeaningful(_ s: Sample, since throttle: HUDPublishThrottle) -> Bool {
        let moving = s.rotationRate > movingRateRadPerSec
        let angleMoved = abs(s.angleDegrees - throttle.lastAngleDegrees) > angleEpsilonDegrees
        let steadyFlipped = s.isSteady != throttle.lastSteady
        let targetChanged = s.targetIndex != throttle.lastTargetIndex
        let dwellMoved = abs(s.dwellProgress - throttle.lastDwellProgress) > dwellEpsilon
        let warningChanged = s.warning != throttle.lastWarning
        return moving || angleMoved || steadyFlipped || targetChanged
            || dwellMoved || warningChanged || s.dwellProgress >= 1
    }
}
