//
//  TargetLayoutTests.swift
//  VirtSpaceTests
//
//  The capture pattern's invariants (spec §10 R13). These were `assert`s in
//  `CaptureEngine.debugValidation`, run once at first engine start in DEBUG
//  builds — which meant they only ever ran if someone started a capture, and
//  never in CI. They live here now.
//

import Foundation
import Testing
import simd
@testable import VirtSpace

@Suite("TargetLayout")
struct TargetLayoutTests {
    @Test("Rebalanced pattern is 12 horizon + 6 up + 8 down + 2 poles")
    func patternShape() {
        let targets = TargetLayout.targets()
        #expect(targets.count == 28)
        #expect(TargetLayout.targetCount == 28)
        #expect(targets.filter { $0.pitchDegrees == 0 }.count == 12)
        #expect(targets.filter { $0.pitchDegrees == 45 }.count == 6)
        #expect(targets.filter { $0.pitchDegrees == -45 }.count == 8)
        #expect(targets.filter { $0.pitchDegrees == 90 }.count == 1)
        #expect(targets.filter { $0.pitchDegrees == -90 }.count == 1)
        // Every ring position appears exactly once.
        #expect(Set(targets.map(\.label)).count == 28)
    }

    @Test("Targets are unit vectors; target 0 is the horizon straight ahead; poles last")
    func directions() {
        let targets = TargetLayout.targets()
        #expect(targets.allSatisfy { abs(simd_length($0.direction) - 1) < 1e-4 })
        #expect(targets.map(\.index) == Array(0..<28))
        #expect(simd_length(targets[0].direction - simd_float3(0, 0, -1)) < 1e-4)
        #expect(simd_length(targets[26].direction - simd_float3(0, 1, 0)) < 1e-4)
        #expect(simd_length(targets[27].direction - simd_float3(0, -1, 0)) < 1e-4)
    }

    @Test("Column order: one sweep, yaw never goes backwards before the poles")
    func columnOrder() {
        let sweep = TargetLayout.targets().prefix(TargetLayout.sweepEndIndex + 1)
        let yaws = sweep.map(\.yawDegrees)
        #expect(yaws == yaws.sorted())
        // The first column is horizon, then up, then down (nearest pitch first,
        // ties go up); a two-target column follows from the previous pitch.
        #expect(sweep.prefix(3).map(\.pitchDegrees) == [0, 45, -45])
        let at60 = sweep.filter { $0.yawDegrees == 60 }.map(\.pitchDegrees)
        #expect(at60 == [0, 45]) // coming from the down ring at 45°: horizon first
    }

    @Test("Ring neighbours are 360 / ring size apart")
    func ringSpacing() {
        let targets = TargetLayout.targets()
        func spacing(_ prefix: String) -> Double {
            let a = targets.first { $0.label == "\(prefix) 1" }!
            let b = targets.first { $0.label == "\(prefix) 2" }!
            return b.yawDegrees - a.yawDegrees
        }
        #expect(spacing("Horizon") == 30)
        #expect(spacing("Up") == 60)
        #expect(spacing("Down") == 45)
    }

    @Test("Celebrations are derived: the sweep's last shot, never the final one")
    func celebrations() {
        let targets = TargetLayout.targets()
        #expect(TargetLayout.sweepEndIndex == 25)
        #expect(TargetLayout.celebrationIndices == [25])
        #expect(targets[TargetLayout.sweepEndIndex + 1].label == "Sky")
        #expect(!TargetLayout.celebrationIndices.contains(TargetLayout.targetCount - 1))
    }
}
