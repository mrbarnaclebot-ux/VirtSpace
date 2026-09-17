//
//  HUDPublishThrottleTests.swift
//  VirtSpaceTests
//
//  The HUD publish coalescer's policy (spec §10 R14): ~30 Hz ceiling plus a
//  "did anything the HUD renders actually move?" gate. Previously buried in
//  CaptureEngine.handlePose, where it could only be exercised by running a
//  real capture.
//
//  Note: `shouldPublish` is mutating, and #expect's macro expansion can't call
//  a mutating member, so every decision is bound to a local first.
//

import Foundation
import Testing
@testable import VirtSpace

@Suite("HUD publish throttle")
struct HUDPublishThrottleTests {
    /// A frame that differs from the throttle's initial baseline only in the
    /// ways each test asks for — everything else matches what a fresh throttle
    /// has already "published" (not steady, dwell 0, no warning).
    private func sample(
        at timestamp: TimeInterval,
        angle: Double = 42,
        steady: Bool = false,
        targetIndex: Int = 0,
        dwell: Double = 0,
        warning: String? = nil,
        rotationRate: Double = 0
    ) -> HUDPublishThrottle.Sample {
        HUDPublishThrottle.Sample(
            timestamp: timestamp,
            angleDegrees: angle,
            isSteady: steady,
            targetIndex: targetIndex,
            dwellProgress: dwell,
            warning: warning,
            rotationRate: rotationRate
        )
    }

    @Test("The first frame publishes, then the 30 Hz ceiling holds")
    func cadenceCeiling() {
        var throttle = HUDPublishThrottle()
        // Baseline angle is .infinity and target index -1, so frame one is
        // always meaningful.
        let first = throttle.shouldPublish(sample(at: 1100))
        #expect(first)
        // 10 ms later: meaningful (big angle move) but not yet due.
        let tooSoon = throttle.shouldPublish(sample(at: 1100.01, angle: 90))
        #expect(!tooSoon)
        // Past 1/30 s: publishes.
        let due = throttle.shouldPublish(sample(at: 1100.034, angle: 90))
        #expect(due)
    }

    @Test("A due but unchanged frame publishes nothing")
    func unchangedFrameIsDropped() {
        var throttle = HUDPublishThrottle()
        let first = throttle.shouldPublish(sample(at: 1000, angle: 20))
        #expect(first)
        // Same everything, a full second later: due, but nothing moved.
        let held = throttle.shouldPublish(sample(at: 1001, angle: 20))
        #expect(!held)
        let stillHeld = throttle.shouldPublish(sample(at: 1002, angle: 20))
        #expect(!stillHeld)
    }

    @Test("Camera rotation alone is meaningful — every dot is moving")
    func rotationIsMeaningful() {
        var throttle = HUDPublishThrottle()
        let first = throttle.shouldPublish(sample(at: 1000, angle: 20))
        #expect(first)
        // Identical HUD values, but the camera is turning: the world-locked
        // dots have all moved even though the angle-to-target has not.
        let turning = throttle.shouldPublish(
            sample(at: 1001, angle: 20, rotationRate: HUDPublishThrottle.movingRateRadPerSec + 0.001)
        )
        #expect(turning)
        // Exactly at the threshold is not "moving" — the test pins the
        // strictly-greater comparison.
        let atThreshold = throttle.shouldPublish(
            sample(at: 1002, angle: 20, rotationRate: HUDPublishThrottle.movingRateRadPerSec)
        )
        #expect(!atThreshold)
    }

    @Test("Angle and dwell changes need to clear their epsilons")
    func epsilons() {
        var throttle = HUDPublishThrottle()
        let first = throttle.shouldPublish(sample(at: 1000, angle: 20, dwell: 0.5))
        #expect(first)
        // Sub-epsilon nudges in both: dropped.
        let nudge = throttle.shouldPublish(sample(at: 1001, angle: 20.2, dwell: 0.505))
        #expect(!nudge)
        // Angle clears its epsilon.
        let angleMoved = throttle.shouldPublish(sample(at: 1002, angle: 20.6, dwell: 0.505))
        #expect(angleMoved)
        // Dwell clears its epsilon.
        let dwellMoved = throttle.shouldPublish(sample(at: 1003, angle: 20.6, dwell: 0.6))
        #expect(dwellMoved)
    }

    @Test("Steadiness, target and warning flips are each meaningful")
    func discreteFlips() {
        var throttle = HUDPublishThrottle()
        let first = throttle.shouldPublish(sample(at: 1000, angle: 20))
        #expect(first)
        let steadyFlip = throttle.shouldPublish(sample(at: 1001, angle: 20, steady: true))
        #expect(steadyFlip)
        let targetFlip = throttle.shouldPublish(sample(at: 1002, angle: 20, steady: true, targetIndex: 1))
        #expect(targetFlip)
        let warningRaised = throttle.shouldPublish(
            sample(at: 1003, angle: 20, steady: true, targetIndex: 1, warning: "Slow down")
        )
        #expect(warningRaised)
        // …and clearing the warning again is just as meaningful.
        let warningCleared = throttle.shouldPublish(sample(at: 1004, angle: 20, steady: true, targetIndex: 1))
        #expect(warningCleared)
        let settled = throttle.shouldPublish(sample(at: 1005, angle: 20, steady: true, targetIndex: 1))
        #expect(!settled)
    }

    @Test("A firing frame is never coalesced away, even when nothing moved")
    func firingFrameAlwaysPublishes() {
        var throttle = HUDPublishThrottle()
        let firing = throttle.shouldPublish(sample(at: 1000, angle: 3, dwell: 1))
        #expect(firing)
        // Still dwell == 1 and nothing else changed: the >= 1 escape hatch keeps
        // publishing, so the firing frame can't be dropped on the floor.
        let stillFiring = throttle.shouldPublish(sample(at: 1001, angle: 3, dwell: 1))
        #expect(stillFiring)
        // But the cadence ceiling still applies to it.
        let tooSoon = throttle.shouldPublish(sample(at: 1001.001, angle: 3, dwell: 1))
        #expect(!tooSoon)
    }

    @Test("Reset restores the fresh-capture baseline")
    func resetClearsBaseline() {
        var throttle = HUDPublishThrottle()
        let first = throttle.shouldPublish(sample(at: 1500, angle: 20, steady: true, targetIndex: 7))
        #expect(first)
        let settled = throttle.shouldPublish(sample(at: 1501, angle: 20, steady: true, targetIndex: 7))
        #expect(!settled)

        throttle.reset()
        // The clock baseline is cleared too, so the next frame publishes even
        // though its timestamp is EARLIER than the last published one — which
        // is exactly what a restarted capture on a fresh pose clock looks like.
        let afterReset = throttle.shouldPublish(sample(at: 1000.001, angle: 20, steady: true, targetIndex: 7))
        #expect(afterReset)
    }
}
