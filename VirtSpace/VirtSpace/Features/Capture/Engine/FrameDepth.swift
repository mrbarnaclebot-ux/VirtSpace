//
//  FrameDepth.swift
//  VirtSpace
//
//  Pure per-frame depth helpers for the stitcher (spec §5.2): the median
//  depth of ARKit's raw feature points in view, the non-LiDAR fallback for
//  translation-aware reprojection.
//

import CoreGraphics
import Foundation
import simd

nonisolated enum FrameDepth {
    /// Median camera-space depth (metres) of the world points that project
    /// inside the image, or nil when none do. `intrinsics` and `imageSize`
    /// must describe the same image (ARKit's landscape sensor frame).
    static func featureDepthMedian(
        points: [simd_float3],
        cameraTransform: simd_float4x4,
        intrinsics: simd_float3x3,
        imageSize: CGSize
    ) -> Float? {
        let worldToCamera = cameraTransform.inverse
        let width = Float(imageSize.width)
        let height = Float(imageSize.height)
        var depths: [Float] = []
        depths.reserveCapacity(points.count)
        for point in points {
            // ARKit camera space: +x right, +y up, the camera looks down -z.
            let c = worldToCamera * simd_float4(point, 1)
            let depth = -c.z
            guard depth > 0.05 else { continue }
            let u = intrinsics[0][0] * c.x / depth + intrinsics[2][0]
            let v = intrinsics[2][1] - intrinsics[1][1] * c.y / depth
            guard u >= 0, u < width, v >= 0, v < height else { continue }
            depths.append(depth)
        }
        guard !depths.isEmpty else { return nil }
        depths.sort()
        let mid = depths.count / 2
        return depths.count % 2 == 0 ? (depths[mid - 1] + depths[mid]) / 2 : depths[mid]
    }
}
