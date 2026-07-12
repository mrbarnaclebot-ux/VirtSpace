//
//  TargetProjection.swift
//  VirtSpace
//
//  Pure math projecting world-space target directions into HUD screen space
//  (spec §6.1: world-locked dots). Assumes a portrait interface and the ARKit
//  camera convention: camera +X = image-right = screen-DOWN in portrait,
//  camera +Y = image-up = screen-RIGHT in portrait, -Z = forward
//  (right-handed). SimulatedCaptureSource emits the same convention, so this
//  math is shared between device and simulator.
//

import CoreGraphics
import Foundation
import simd

/// Where a target direction lands on screen.
struct ProjectedTarget {
    /// Screen point (only meaningful when `isInFront`).
    let point: CGPoint
    /// True when the direction is in the camera's forward hemisphere.
    let isInFront: Bool
    /// True when `point` falls within the view (with a small margin).
    let isOnScreen: Bool
    /// Unit 2D direction from screen center along the shortest rotation path
    /// toward the target — valid even when the target is behind the camera.
    /// Drives the edge-of-screen chevron.
    let screenDirection: CGVector
}

enum TargetProjection {
    /// Margin inside the view bounds within which a dot counts as on-screen.
    static let onScreenMargin: CGFloat = 26

    static func project(
        worldDirection: simd_float3,
        cameraTransform: simd_float4x4,
        intrinsics: simd_float3x3,
        imageResolution: CGSize,
        viewSize: CGSize
    ) -> ProjectedTarget {
        // World → camera space. The rotation block of a camera-to-world
        // transform is orthonormal, so its inverse is the transpose;
        // simd_mul(vector, matrix) applies exactly that (vᵀM = Mᵀv).
        let rotation = rotationBlock(of: cameraTransform)
        let v = simd_normalize(simd_mul(worldDirection, rotation))

        // Portrait screen components (see header): right = +Y, down = +X.
        let sRight = CGFloat(v.y)
        let sDown = CGFloat(v.x)
        let zc = CGFloat(-v.z) // positive in front of the camera

        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let planarLength = max(1e-6, (sRight * sRight + sDown * sDown).squareRoot())
        let direction = CGVector(dx: sRight / planarLength, dy: sDown / planarLength)

        guard zc > 0.001 else {
            // Behind the camera: no projectable point, but `direction` still
            // points the shortest way to turn.
            return ProjectedTarget(point: center, isInFront: false, isOnScreen: false, screenDirection: direction)
        }

        let focal = focalLength(intrinsics: intrinsics, imageResolution: imageResolution, viewSize: viewSize)
        let point = CGPoint(
            x: center.x + focal * sRight / zc,
            y: center.y + focal * sDown / zc
        )
        let onScreen = CGRect(origin: .zero, size: viewSize)
            .insetBy(dx: onScreenMargin, dy: onScreenMargin)
            .contains(point)
        return ProjectedTarget(point: point, isInFront: true, isOnScreen: onScreen, screenDirection: direction)
    }

    /// On-screen focal length in points: the sensor image (landscape) is
    /// rotated 90° and aspect-filled into the portrait view, so the pixel
    /// focal length scales by the same fill factor.
    static func focalLength(intrinsics: simd_float3x3, imageResolution: CGSize, viewSize: CGSize) -> CGFloat {
        let fx = CGFloat(intrinsics.columns.0.x)
        guard fx > 1, imageResolution.width > 1, imageResolution.height > 1,
              viewSize.width > 1, viewSize.height > 1 else {
            // Fallback ≈ 58° vertical FOV.
            return viewSize.height * 0.9
        }
        let rotatedWidth = imageResolution.height // after 90° rotation
        let rotatedHeight = imageResolution.width
        let scale = max(viewSize.width / rotatedWidth, viewSize.height / rotatedHeight)
        return fx * scale
    }

    /// Anchor point + pointing angle for the edge-of-screen chevron of an
    /// off-screen target: the ray from screen center along `direction`,
    /// clipped to the view rect inset by `padding`.
    static func edgeAnchor(direction: CGVector, viewSize: CGSize, padding: CGFloat) -> (point: CGPoint, angle: Double) {
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let halfW = max(1, viewSize.width / 2 - padding)
        let halfH = max(1, viewSize.height / 2 - padding)

        var t = CGFloat.greatestFiniteMagnitude
        if abs(direction.dx) > 1e-6 { t = min(t, halfW / abs(direction.dx)) }
        if abs(direction.dy) > 1e-6 { t = min(t, halfH / abs(direction.dy)) }
        if t == .greatestFiniteMagnitude { t = 0 }

        let point = CGPoint(x: center.x + direction.dx * t, y: center.y + direction.dy * t)
        return (point, atan2(Double(direction.dy), Double(direction.dx)))
    }

    private static func rotationBlock(of transform: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            simd_float3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            simd_float3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            simd_float3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )
    }
}
