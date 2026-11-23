//
//  RoomScanBundle.swift
//  VirtSpace
//
//  The Echo-3 capture bundle (spec §5.3 item 2), built on device after Finish:
//
//    images/Image_000001.jpg …           sensor-landscape JPEGs, EXIF from ARKit
//    cameras/per_frame_intrinsics.json   {frame_count, width_px, height_px, fx_px[], fy_px[], cx_px[], cy_px[]}
//    cameras/camera_trajectory.json      [N][4][4] row-major OpenCV camera_from_world
//
//  No cameras/orientation.json: SpAItial's prototype writes none and stores
//  frames unrotated in sensor landscape, where the capture guide says it is
//  only for portrait frames stored upright. Conventions follow
//  github.com/spaitial-ai/spaitial-capture-prototype (MIT No Attribution),
//  docs/bundle-format.md and docs/coordinate-conventions.md.
//
//  The ZIP is store-only, written streaming to a file one entry at a time
//  (one image in memory at once), no ZIP64: the whole archive stays under
//  4 GiB and 65535 entries, which the frame cap guarantees.
//

import Foundation
import simd
import zlib

nonisolated enum RoomScanBundle {
    /// `bundle_bytes` ceiling (4 GiB − 1, spec §5.3 item 3); also the last
    /// offset a non-ZIP64 archive can address.
    static let maxBytes = 0xFFFF_FFFF
    /// Echo-3's frame ceiling; the create response may lower it.
    static let maxFrames = 5000
    /// Echo-3 rejects entries over 64 MiB.
    static let maxEntryBytes = 64 << 20

    enum BuildError: LocalizedError {
        case invalidFrames(String)
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .invalidFrames: "This scan's photos couldn't be packed. Scan again."
            case .tooLarge: "This scan is too big to upload. Scan a smaller area."
            }
        }
    }

    static func imageName(_ index: Int) -> String { String(format: "Image_%06d.jpg", index) }

    /// Write the bundle for `frames` to `url` (via a temp file, renamed when
    /// complete) and return its size in bytes.
    @discardableResult
    static func build(frames: [RoomScanFrame], imageURL: (Int) -> URL, to url: URL, date: Date = Date()) throws -> Int {
        guard let first = frames.first, frames.count <= maxFrames else {
            throw BuildError.invalidFrames("\(frames.count) frames")
        }
        for (offset, frame) in frames.enumerated() {
            guard frame.index == offset + 1, frame.width == first.width, frame.height == first.height else {
                throw BuildError.invalidFrames("frame \(frame.index) breaks the sequence or size")
            }
        }
        let temp = url.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: temp)
        var zip = try StoredZipWriter(url: temp, date: date)
        do {
            try zip.add("cameras/per_frame_intrinsics.json", intrinsicsJSON(frames))
            try zip.add("cameras/camera_trajectory.json", trajectoryJSON(frames))
            for frame in frames {
                try autoreleasepool {
                    try zip.add("images/" + imageName(frame.index), Data(contentsOf: imageURL(frame.index)))
                }
            }
            let size = try zip.finish()
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temp, to: url)
            return size
        } catch {
            zip.close()
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    // MARK: Cameras JSON

    private struct Intrinsics: Encodable {
        let frameCount: Int
        let widthPx: Int
        let heightPx: Int
        let fxPx: [Double]
        let fyPx: [Double]
        let cxPx: [Double]
        let cyPx: [Double]

        enum CodingKeys: String, CodingKey {
            case frameCount = "frame_count", widthPx = "width_px", heightPx = "height_px"
            case fxPx = "fx_px", fyPx = "fy_px", cxPx = "cx_px", cyPx = "cy_px"
        }
    }

    static func intrinsicsJSON(_ frames: [RoomScanFrame]) throws -> Data {
        try JSONEncoder().encode(Intrinsics(
            frameCount: frames.count,
            widthPx: frames.first?.width ?? 0,
            heightPx: frames.first?.height ?? 0,
            fxPx: frames.map { Double($0.fx) },
            fyPx: frames.map { Double($0.fy) },
            cxPx: frames.map { Double($0.cx) },
            cyPx: frames.map { Double($0.cy) }))
    }

    static func trajectoryJSON(_ frames: [RoomScanFrame]) throws -> Data {
        let matrices = frames.map { rowMajor(opencvCameraFromWorld(arkitTransform($0.transform))) }
        return try JSONSerialization.data(withJSONObject: matrices)
    }

    // MARK: Geometry

    static func arkitTransform(_ columnMajor: [Float]) -> simd_float4x4 {
        simd_float4x4((0..<4).map { c in SIMD4(columnMajor[4 * c], columnMajor[4 * c + 1], columnMajor[4 * c + 2], columnMajor[4 * c + 3]) })
    }

    /// `diag(1, -1, -1, 1) · inverse(world_from_camera)`: invert the ARKit
    /// pose to camera_from_world, then flip camera Y and Z (ARKit +Y up, -Z
    /// forward → OpenCV +Y down, +Z forward). The flip is on the LEFT: it acts
    /// on camera coordinates. Rigid inverse (Rᵀ, -Rᵀt) in double, so the
    /// bottom row is exactly 0 0 0 1 (a general inverse leaves 1 ± 1e-16).
    static func opencvCameraFromWorld(_ arkitWorldFromCamera: simd_float4x4) -> simd_double4x4 {
        let m = arkitWorldFromCamera
        func xyz(_ c: SIMD4<Float>) -> SIMD3<Double> { SIMD3(Double(c.x), Double(c.y), Double(c.z)) }
        let r = simd_double3x3(xyz(m.columns.0), xyz(m.columns.1), xyz(m.columns.2)).transpose
        let t = -(r * xyz(m.columns.3))
        let cameraFromWorld = simd_double4x4(
            SIMD4(r.columns.0, 0), SIMD4(r.columns.1, 0), SIMD4(r.columns.2, 0), SIMD4(t, 1))
        return simd_double4x4(diagonal: SIMD4(1, -1, -1, 1)) * cameraFromWorld
    }

    /// `[row][column]`: simd is column-major, the JSON row-major.
    static func rowMajor(_ m: simd_double4x4) -> [[Double]] {
        (0..<4).map { row in (0..<4).map { column in m[column][row] } }
    }
}

// MARK: - Store-only ZIP

/// Minimal PKZIP writer: stored (method 0) entries, local headers carry the
/// CRC and sizes up front (no data descriptors), central directory + EOCD at
/// the end. Refuses anything that would need ZIP64.
nonisolated struct StoredZipWriter {
    private let handle: FileHandle
    private let dosTime: UInt16
    private let dosDate: UInt16
    private var offset = 0
    private var central = Data()
    private var entries = 0

    init(url: URL, date: Date) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        dosTime = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        dosDate = UInt16(max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
    }

    mutating func add(_ name: String, _ data: Data) throws {
        let nameBytes = Data(name.utf8)
        guard data.count <= RoomScanBundle.maxEntryBytes else { throw RoomScanBundle.BuildError.tooLarge }
        // Room for this entry, its central record and the 22-byte EOCD.
        guard entries < 0xFFFF,
              offset + 30 + nameBytes.count + data.count + central.count + 46 + nameBytes.count + 22 <= RoomScanBundle.maxBytes
        else { throw RoomScanBundle.BuildError.tooLarge }
        let crc = data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }

        var local = Data()
        local.le32(0x0403_4B50)
        local.le16(10)             // version needed: 1.0 (stored)
        local.le16(0x0800)         // flags: UTF-8 names
        local.le16(0)              // method: stored
        local.le16(dosTime)
        local.le16(dosDate)
        local.le32(crc)
        local.le32(UInt32(data.count))
        local.le32(UInt32(data.count))
        local.le16(UInt16(nameBytes.count))
        local.le16(0)              // extra length
        local.append(nameBytes)
        try handle.write(contentsOf: local)
        try handle.write(contentsOf: data)

        central.le32(0x0201_4B50)
        central.le16(20)           // made by: MS-DOS, 2.0
        central.le16(10)
        central.le16(0x0800)
        central.le16(0)
        central.le16(dosTime)
        central.le16(dosDate)
        central.le32(crc)
        central.le32(UInt32(data.count))
        central.le32(UInt32(data.count))
        central.le16(UInt16(nameBytes.count))
        central.le16(0)            // extra
        central.le16(0)            // comment
        central.le16(0)            // disk number
        central.le16(0)            // internal attributes
        central.le32(0)            // external attributes
        central.le32(UInt32(offset))
        central.append(nameBytes)

        offset += local.count + data.count
        entries += 1
    }

    /// Central directory + EOCD; returns the archive size.
    mutating func finish() throws -> Int {
        var end = central
        end.le32(0x0605_4B50)
        end.le16(0)                // this disk
        end.le16(0)                // central directory disk
        end.le16(UInt16(entries))
        end.le16(UInt16(entries))
        end.le32(UInt32(central.count))
        end.le32(UInt32(offset))
        end.le16(0)                // comment
        try handle.write(contentsOf: end)
        try handle.synchronize()
        close()
        return offset + end.count
    }

    func close() { try? handle.close() }
}

private extension Data {
    nonisolated mutating func le16(_ value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    nonisolated mutating func le32(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}
