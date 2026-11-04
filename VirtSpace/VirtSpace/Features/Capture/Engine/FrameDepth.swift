//
//  FrameDepth.swift
//  VirtSpace
//
//  Pure per-frame depth helpers for the stitcher (spec §5.2): the LiDAR depth
//  map as a 16-bit grayscale PNG in millimetres, and the median depth of
//  ARKit's raw feature points in view (the non-LiDAR fallback).
//
//  Orientation: the PNG is written in the depth map's native orientation,
//  untransformed. ARKit aligns `sceneDepth.depthMap` with `capturedImage`
//  (same landscape sensor orientation, same field of view, 4:3), and the
//  uploaded JPEG is `capturedImage` encoded untransformed too — no rotation,
//  no crop, only an aspect-preserving downscale for 48 MP formats. So the
//  depth map already matches the JPEG, and the stitcher scales the frame
//  intrinsics by depth.width / jpegWidth and depth.height / jpegHeight.
//

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import simd

/// One frame's encoded depth map.
nonisolated struct EncodedDepth: Sendable {
    let png: Data
    let size: FrameDepthSize
}

nonisolated enum FrameDepth {
    /// The backend refuses depth files above 1 MiB (spec §5.2); a 256x192
    /// map is ~100 KB raw, so hitting this means something is wrong.
    static let maxPNGBytes = 1_048_576
    /// `ARConfidenceLevel.low.rawValue`: those pixels are written as 0 (invalid).
    static let lowConfidence: UInt8 = 0

    /// ARKit `sceneDepth` (Float32 metres + UInt8 confidence) → PNG. nil when
    /// the buffer isn't the expected format or the PNG can't be produced.
    static func encode(depthMap: CVPixelBuffer, confidenceMap: CVPixelBuffer?) -> EncodedDepth? {
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else { return nil }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let metres = read(depthMap, as: Float.self, width: width, height: height)
        var confidence: [UInt8]?
        if let confidenceMap,
           CVPixelBufferGetPixelFormatType(confidenceMap) == kCVPixelFormatType_OneComponent8,
           CVPixelBufferGetWidth(confidenceMap) == width,
           CVPixelBufferGetHeight(confidenceMap) == height {
            confidence = read(confidenceMap, as: UInt8.self, width: width, height: height)
        }
        let mm = millimetres(depthMetres: metres, confidence: confidence)
        guard let png = png(millimetres: mm, width: width, height: height) else { return nil }
        return EncodedDepth(png: png, size: FrameDepthSize(width: width, height: height))
    }

    /// Metres → millimetres; 0 marks invalid (non-finite, non-positive, or
    /// low confidence). Clamped to the UInt16 range (~65 m).
    static func millimetres(depthMetres: [Float], confidence: [UInt8]?) -> [UInt16] {
        depthMetres.indices.map { i in
            if let confidence, i < confidence.count, confidence[i] == lowConfidence { return 0 }
            let metres = depthMetres[i]
            guard metres.isFinite, metres > 0 else { return 0 }
            return UInt16(min((metres * 1000).rounded(), Float(UInt16.max)))
        }
    }

    /// 16-bit grayscale PNG of `millimetres` (row-major, top row first).
    static func png(millimetres: [UInt16], width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, millimetres.count == width * height else { return nil }
        let pixels = millimetres.withUnsafeBufferPointer { Data(buffer: $0) }
        guard
            let provider = CGDataProvider(data: pixels as CFData),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 16,
                bitsPerPixel: 16,
                bytesPerRow: width * 2,
                space: CGColorSpaceCreateDeviceGray(),
                // Host order is little-endian on every Apple platform.
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= maxPNGBytes else { return nil }
        return output as Data
    }

    private static func read<T>(_ buffer: CVPixelBuffer, as _: T.Type, width: Int, height: Int) -> [T] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var values: [T] = []
        values.reserveCapacity(width * height)
        for y in 0..<height {
            let row = (base + y * bytesPerRow).assumingMemoryBound(to: T.self)
            for x in 0..<width { values.append(row[x]) }
        }
        return values
    }

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
