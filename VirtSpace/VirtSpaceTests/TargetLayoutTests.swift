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
    @Test("Densified pattern is 12 horizon + 8 up + 6 down + 2 poles")
    func patternShape() {
        let targets = TargetLayout.targets()
        #expect(targets.count == 28)
        #expect(TargetLayout.targetCount == 28)
        #expect(targets.filter { $0.pitchDegrees == 0 }.count == 12)
        #expect(targets.filter { $0.pitchDegrees == 45 }.count == 8)
        #expect(targets.filter { $0.pitchDegrees == -45 }.count == 6)
        #expect(targets.filter { $0.pitchDegrees == 90 }.count == 1)
        #expect(targets.filter { $0.pitchDegrees == -90 }.count == 1)
    }

    @Test("Targets are unit vectors in capture order")
    func directions() {
        let targets = TargetLayout.targets()
        #expect(targets.allSatisfy { abs(simd_length($0.direction) - 1) < 1e-4 })
        #expect(targets.map(\.index) == Array(0..<28))
        #expect(simd_length(targets[0].direction - simd_float3(0, 0, -1)) < 1e-4)
        #expect(simd_length(targets[26].direction - simd_float3(0, 1, 0)) < 1e-4)
        #expect(simd_length(targets[27].direction - simd_float3(0, -1, 0)) < 1e-4)
    }

    @Test("Horizon neighbours sit 30° apart")
    func horizonSpacing() {
        let targets = TargetLayout.targets()
        let spacing = AlignmentMath.angularDistanceDegrees(targets[0].direction, targets[1].direction)
        #expect(abs(spacing - 30) < 0.01)
    }

    @Test("Ring boundaries are derived from the ring sizes, not literals")
    func ringBoundaries() {
        // Running sums of [12, 8, 6, 2], minus one.
        #expect(TargetLayout.ringBoundaryIndices == [11, 19, 25, 27])
        // The final target is excluded: its completion is the end-of-capture
        // success haptic, not a ring celebration.
        #expect(TargetLayout.ringCompletionIndices == [11, 19, 25])
        // The dead 16-target layout's indices must NOT fire any more — this is
        // the exact R12 bug: 7/11/13 survived the 16→28 densification.
        #expect(!TargetLayout.ringCompletionIndices.contains(7))
        #expect(!TargetLayout.ringCompletionIndices.contains(13))
    }

    @Test("Each ring boundary really is the last target of its ring")
    func boundariesMatchRings() {
        let targets = TargetLayout.targets()
        for boundary in TargetLayout.ringBoundaryIndices {
            let next = boundary + 1
            guard next < targets.count else { continue }
            // The target after a boundary starts a different ring (pitch changes).
            #expect(targets[boundary].pitchDegrees != targets[next].pitchDegrees)
        }
    }
}
