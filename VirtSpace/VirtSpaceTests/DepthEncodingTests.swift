//
//  DepthEncodingTests.swift
//  VirtSpaceTests
//
//  The depth file contract (spec §5.2 item 2): 16-bit grayscale PNG,
//  millimetres, 0 = invalid (non-finite, non-positive or low confidence),
//  written crash-safely next to its frame.
//

import CoreVideo
import Foundation
import ImageIO
import Testing
import simd
@testable import VirtSpace

@Suite("Depth encoding")
struct DepthEncodingTests {
    private func makeBuffer<T>(_ format: OSType, width: Int, height: Int, values: [T]) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, format, nil, &buffer)
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(pixelBuffer))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            let row = (base + y * bytesPerRow).assumingMemoryBound(to: T.self)
            for x in 0..<width { row[x] = values[y * width + x] }
        }
        return pixelBuffer
    }

    /// Decode a 16-bit gray PNG to its raw samples, honouring its byte order.
    private func decode(_ png: Data) throws -> (width: Int, height: Int, bits: Int, values: [UInt16]) {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let data = try #require(image.dataProvider?.data) as Data
        let little = image.bitmapInfo.contains(.byteOrder16Little)
        var values: [UInt16] = []
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = y * image.bytesPerRow + x * 2
                let a = UInt16(data[offset]), b = UInt16(data[offset + 1])
                values.append(little ? a | b << 8 : a << 8 | b)
            }
        }
        return (image.width, image.height, image.bitsPerComponent, values)
    }

    @Test("Synthetic depth buffer round-trips as millimetres with invalid pixels zeroed")
    func roundTrip() throws {
        let width = 4, height = 3
        let metres: [Float] = [1.234, 2, .nan, -1, 0, 70, 0.5, 3, 1, 1.5, 0.25, 4]
        // ARConfidenceLevel: 0 low, 1 medium, 2 high. Pixel 6 is low.
        let confidence: [UInt8] = [2, 1, 2, 2, 2, 2, 0, 2, 2, 2, 2, 2]
        let depthMap = try makeBuffer(kCVPixelFormatType_DepthFloat32, width: width, height: height, values: metres)
        let confidenceMap = try makeBuffer(kCVPixelFormatType_OneComponent8, width: width, height: height, values: confidence)

        let encoded = try #require(FrameDepth.encode(depthMap: depthMap, confidenceMap: confidenceMap))
        #expect(encoded.size == FrameDepthSize(width: 4, height: 3))
        #expect(encoded.png.count <= FrameDepth.maxPNGBytes)

        let decoded = try decode(encoded.png)
        #expect(decoded.width == 4 && decoded.height == 3 && decoded.bits == 16)
        // NaN, negative and zero → 0; 70 m clamps to UInt16.max; low confidence → 0.
        #expect(decoded.values == [1234, 2000, 0, 0, 0, 65535, 0, 3000, 1000, 1500, 250, 4000])
    }

    @Test("Wrong pixel formats and mismatched sizes are refused")
    func refusesBadInput() throws {
        let notDepth = try makeBuffer(kCVPixelFormatType_OneComponent8, width: 2, height: 2, values: [UInt8](repeating: 1, count: 4))
        #expect(FrameDepth.encode(depthMap: notDepth, confidenceMap: nil) == nil)
        #expect(FrameDepth.png(millimetres: [1, 2, 3], width: 2, height: 2) == nil)
    }

    @Test("A frame's depth file is written beside it; no data means no depth on the pose")
    func storeWritesDepth() throws {
        let fixture = StoreFixture()
        let session = try fixture.store.createSession(expectedFrameCount: 2)
        func pose(_ index: Int) -> CaptureStore.FramePose {
            CaptureStore.FramePose(
                index: index, timestamp: 0, transform: matrix_identity_float4x4,
                intrinsics: matrix_identity_float3x3, exposureLocked: true,
                depth: FrameDepthSize(width: 2, height: 1)
            )
        }
        let png = try #require(FrameDepth.png(millimetres: [500, 0], width: 2, height: 1))
        try fixture.store.saveFrame(Data([0xFF, 0xD8]), depthPNG: png, pose: pose(0), in: session)
        try fixture.store.saveFrame(Data([0xFF, 0xD8]), depthPNG: nil, pose: pose(1), in: session)

        let frames = try #require(fixture.manifest(session.id)?.frames)
        #expect(frames[0].depth == FrameDepthSize(width: 2, height: 1))
        #expect(frames[1].depth == nil)
        let written = try Data(contentsOf: fixture.store.depthURL(index: 0, in: session.directory))
        #expect(written == png)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.depthURL(index: 1, in: session.directory).path))
    }
}
