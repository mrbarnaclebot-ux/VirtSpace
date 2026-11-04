//
//  CaptureMathTests.swift
//  VirtSpaceTests
//
//  The rest of `CaptureEngine.debugValidation`, moved into real tests
//  (spec §10 R13): alignment math, the dwell tracker, HUD projection and
//  paint-quad sizing. The thermal mapping now lives in ThermalGovernorTests.
//

import CoreGraphics
import Foundation
import Testing
import UIKit
import simd
@testable import VirtSpace

@Suite("Alignment math")
struct AlignmentMathTests {
    @Test("Identity transform looks down -Z and drift is euclidean")
    func forwardAndDrift() {
        let forward = AlignmentMath.forward(of: matrix_identity_float4x4)
        #expect(simd_length(forward - simd_float3(0, 0, -1)) < 1e-5)

        let drift = AlignmentMath.translationDrift(from: .zero, current: simd_float3(0.3, 0, 0.4))
        #expect(abs(drift - 0.5) < 1e-5)
    }

    @Test("A target to the right yields positive yaw")
    func signedDeltas() {
        let deltas = AlignmentMath.signedDeltas(
            cameraForward: simd_float3(0, 0, -1),
            targetDirection: simd_float3(1, 0, 0)
        )
        #expect(abs(deltas.yaw - 90) < 0.01)
    }
}

@Suite("Dwell tracker")
struct DwellTrackerTests {
    @Test("Fires only after 300 ms aligned + steady, then re-arms")
    func dwellLifecycle() {
        var dwell = DwellTracker()
        #expect(dwell.update(aligned: true, steady: true, at: 0) == false)
        #expect(dwell.update(aligned: true, steady: true, at: 0.15) == false)
        #expect(abs(dwell.progress(at: 0.15) - 0.5) < 0.01)
        #expect(dwell.update(aligned: true, steady: true, at: 0.31) == true)
        // Re-armed: the next frame can't immediately fire again.
        #expect(dwell.update(aligned: false, steady: true, at: 0.4) == false)
    }
}

@Suite("HUD projection")
struct TargetProjectionTests {
    private let intrinsics = simd_float3x3(
        simd_float3(1500, 0, 0), simd_float3(0, 1500, 0), simd_float3(720, 540, 1)
    )
    private let viewSize = CGSize(width: 400, height: 800)
    private let resolution = CGSize(width: 1440, height: 1080)

    @Test("Straight ahead projects to screen centre")
    func straightAhead() {
        let ahead = TargetProjection.project(
            worldDirection: simd_float3(0, 0, -1),
            cameraTransform: matrix_identity_float4x4,
            intrinsics: intrinsics,
            imageResolution: resolution,
            viewSize: viewSize
        )
        #expect(ahead.isInFront)
        #expect(ahead.isOnScreen)
        #expect(abs(ahead.point.x - 200) < 0.5)
        #expect(abs(ahead.point.y - 400) < 0.5)
    }

    @Test("Camera +Y lands screen-right in portrait")
    func cameraYIsScreenRight() {
        let rightish = TargetProjection.project(
            worldDirection: simd_normalize(simd_float3(0, 0.25, -1)),
            cameraTransform: matrix_identity_float4x4,
            intrinsics: intrinsics,
            imageResolution: resolution,
            viewSize: viewSize
        )
        #expect(rightish.point.x > 200)
        #expect(abs(rightish.point.y - 400) < 0.5)
    }

    @Test("A direction behind the camera is off screen")
    func behindCamera() {
        let behind = TargetProjection.project(
            worldDirection: simd_float3(0, 0, 1),
            cameraTransform: matrix_identity_float4x4,
            intrinsics: intrinsics,
            imageResolution: resolution,
            viewSize: viewSize
        )
        #expect(!behind.isInFront)
        #expect(!behind.isOnScreen)
    }

    @Test("Paint quad width subtends the camera FOV at its radius")
    func paintQuadWidth() {
        let paint = PaintedShot(
            index: 0,
            transform: matrix_identity_float4x4,
            intrinsics: intrinsics,
            thumbnail: UIImage()
        )
        let width = Float(2.5) * paint.approxImageWidth / intrinsics.columns.0.x
        #expect(abs(width - 2.5 * 1440 / 1500) < 1e-3)
    }
}


@Suite("Exposure meter")
struct ExposureMeterTests {
    private func sample(iso: Float, duration: Double = 1.0 / 60) -> ExposureSample {
        ExposureSample(iso: iso, duration: duration, minISO: 32, maxISO: 3_000,
                       minDuration: 1.0 / 10_000, maxDuration: 1.0 / 3)
    }

    @Test("Locks to the window's median exposure at the current shutter")
    func lockTargetIsMedian() throws {
        var meter = ExposureMeter()
        // A bright window glimpsed once must not drag the lock down.
        for iso: Float in [400, 420, 50, 410, 400] { meter.add(sample(iso: iso)) }
        let target = try #require(meter.lockTarget)
        #expect(abs(target.duration - 1.0 / 60) < 1e-9)
        #expect(abs(target.iso - 400) < 0.5)
    }

    @Test("ISO is clamped to the format and an empty meter has no target")
    func clampsAndEmpty() throws {
        var meter = ExposureMeter()
        #expect(meter.lockTarget == nil)
        meter.add(sample(iso: 3_000, duration: 1.0 / 60))
        meter.add(sample(iso: 3_000, duration: 1.0 / 60))
        // Latest shutter is shorter than the window's: the needed ISO exceeds max.
        meter.add(sample(iso: 3_000, duration: 1.0 / 240))
        let target = try #require(meter.lockTarget)
        #expect(target.iso == 3_000)
    }

    @Test("The window keeps only the most recent samples")
    func rollingWindow() {
        var meter = ExposureMeter()
        for _ in 0..<(ExposureMeter.windowSize + 10) { meter.add(sample(iso: 100)) }
        #expect(meter.samples.count == ExposureMeter.windowSize)
    }
}

@Suite("Low light and steadiness scaling")
struct LowLightTests {
    private func sample(iso: Float, duration: Double = 1.0 / 60) -> ExposureSample {
        ExposureSample(iso: iso, duration: duration, minISO: 32, maxISO: 3_000,
                       minDuration: 1.0 / 10_000, maxDuration: 1.0 / 3)
    }

    @Test("ISO near the format ceiling reads as too dark; a bright room does not")
    func tooDark() {
        var dark = ExposureMeter()
        for _ in 0..<5 { dark.add(sample(iso: 2_800)) }
        #expect(dark.isTooDark)

        var bright = ExposureMeter()
        for _ in 0..<5 { bright.add(sample(iso: 200)) }
        #expect(!bright.isTooDark)
        #expect(!ExposureMeter().isTooDark)
    }

    @Test("Longer exposures need a proportionally steadier hold, with a floor")
    func steadinessScales() {
        let base = AlignmentMath.steadinessThresholdRadPerSec
        #expect(AlignmentMath.steadinessThreshold(exposureDuration: 1.0 / 120) == base)
        #expect(AlignmentMath.steadinessThreshold(exposureDuration: 1.0 / 60) == base)
        #expect(abs(AlignmentMath.steadinessThreshold(exposureDuration: 1.0 / 30) - base / 2) < 1e-9)
        #expect(AlignmentMath.steadinessThreshold(exposureDuration: 1) == AlignmentMath.minSteadinessThresholdRadPerSec)
        // 0.08 rad/s is steady at 1/60 s but not at 1/30 s.
        #expect(AlignmentMath.isSteady(rotationRate: 0.08, exposureDuration: 1.0 / 60))
        #expect(!AlignmentMath.isSteady(rotationRate: 0.08, exposureDuration: 1.0 / 30))
    }
}

@Suite("Pivot drift")
struct PivotDriftTests {
    @Test("Drift is measured from the shot centroid, not shot 0")
    func centroidDrift() throws {
        // An orbit: the phone swings on a 0.4 m arm around the body.
        let shots: [simd_float3] = [
            simd_float3(0, 1.5, -0.4), simd_float3(0.4, 1.5, 0),
            simd_float3(0, 1.5, 0.4), simd_float3(-0.4, 1.5, 0)
        ]
        let centroid = try #require(AlignmentMath.centroid(shots))
        #expect(simd_length(centroid - simd_float3(0, 1.5, 0)) < 1e-5)
        // Back near shot 0: 0 m from shot 0 but 0.4 m from the pivot.
        let drift = AlignmentMath.driftFromCentroid(of: shots, current: simd_float3(0, 1.5, -0.4))
        #expect(abs(drift - 0.4) < 1e-5)
        #expect(AlignmentMath.driftFromCentroid(of: [], current: simd_float3(5, 5, 5)) == 0)
        #expect(AlignmentMath.centroid([]) == nil)
    }

    @Test("Pivot offset is in the camera's heading frame")
    func offsetFrame() {
        // Looking down -Z; camera 0.1 m to the world's +X = to the camera's right.
        let right = AlignmentMath.pivotOffset(from: .zero, current: simd_float3(0.1, 0, 0), cameraForward: simd_float3(0, 0, -1))
        #expect(abs(right.x - 0.1) < 1e-5 && abs(right.y) < 1e-5)
        // Turned to face +X, the same offset is straight ahead.
        let ahead = AlignmentMath.pivotOffset(from: .zero, current: simd_float3(0.1, 0, 0), cameraForward: simd_float3(1, 0, 0))
        #expect(abs(ahead.x) < 1e-5 && abs(ahead.y - 0.1) < 1e-5)
    }

    @Test("The soft gate withholds the dwell, then lets it through after the grace")
    func softGate() {
        var gate = PivotGate()
        // `#expect` can't call a mutating method, so step the gate out here.
        func step(_ drift: Float, _ onTarget: Bool, _ t: TimeInterval) -> Bool {
            gate.allows(drift: drift, onTarget: onTarget, at: t)
        }
        let far = AlignmentMath.pivotGateMeters + 0.05
        let grace = AlignmentMath.pivotGateGraceSeconds
        let results = [
            step(0.05, true, 0),          // on the pivot: allowed
            step(far, true, 1),           // off it: withheld…
            step(far, true, 1 + grace - 0.1),
            step(far, true, 1 + grace),   // …until the grace runs out
            step(far, false, 10),         // looking away restarts the clock
            step(far, true, 10.5)
        ]
        #expect(results == [true, false, false, true, true, false])
    }
}

@Suite("Feature depth")
struct FeatureDepthTests {
    private let intrinsics = simd_float3x3(
        simd_float3(1000, 0, 0), simd_float3(0, 1000, 0), simd_float3(960, 720, 1)
    )
    private let size = CGSize(width: 1920, height: 1440)

    @Test("Median of the points in view; points behind or outside are ignored")
    func median() throws {
        let points: [simd_float3] = [
            simd_float3(0, 0, -1), simd_float3(0.1, 0.1, -2), simd_float3(0, 0, -3),
            simd_float3(0, 0, 2),     // behind the camera
            simd_float3(50, 0, -1)    // far outside the image
        ]
        let depth = try #require(FrameDepth.featureDepthMedian(
            points: points, cameraTransform: matrix_identity_float4x4, intrinsics: intrinsics, imageSize: size
        ))
        #expect(abs(depth - 2) < 1e-5)
        #expect(FrameDepth.featureDepthMedian(
            points: [], cameraTransform: matrix_identity_float4x4, intrinsics: intrinsics, imageSize: size
        ) == nil)
    }
}
