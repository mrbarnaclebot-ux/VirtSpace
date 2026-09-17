//
//  CaptureMathTests.swift
//  VirtSpaceTests
//
//  The rest of `CaptureEngine.debugValidation`, moved into real tests
//  (spec §10 R13): alignment math, the dwell tracker, HUD projection, the
//  thermal governor's pure mapping and paint-quad sizing.
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

@Suite("Thermal governor mapping")
struct ThermalMappingTests {
    @Test("Preview frame rate drops under thermal pressure")
    func frameRate() {
        #expect(CaptureEngine.previewFrameRate(for: .nominal) == 30)
        #expect(CaptureEngine.previewFrameRate(for: .fair) == 30)
        #expect(CaptureEngine.previewFrameRate(for: .serious) == 24)
        #expect(CaptureEngine.previewFrameRate(for: .critical) == 24)
    }

    @Test("Only `serious` shows the warming banner; `critical` pauses")
    func banners() {
        #expect(!CaptureEngine.showsWarmingBanner(for: .nominal))
        #expect(!CaptureEngine.showsWarmingBanner(for: .fair))
        #expect(CaptureEngine.showsWarmingBanner(for: .serious))
        #expect(!CaptureEngine.showsWarmingBanner(for: .critical))
        #expect(!CaptureEngine.pausesSession(for: .serious))
        #expect(CaptureEngine.pausesSession(for: .critical))
    }
}
