//
//  RoomScanTests.swift
//  VirtSpaceTests
//
//  Room scan (spec §5.3): the store-only ZIP read back with a minimal
//  central-directory reader, the ARKit → OpenCV trajectory conversion, and
//  the keyframe gate. No network, temp directories only.
//

import Foundation
import Testing
import simd
import zlib
@testable import VirtSpace

@Suite("Room scan")
struct RoomScanTests {
    // MARK: - Bundle

    @Test("The bundle is a valid store-only ZIP with the contract's entries")
    func bundleRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("roomscan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoomScanStore(baseDirectory: root)
        let id = UUID()
        try store.createSession(id: id)
        let images = (1...3).map { Data("jpeg-\($0)-".utf8) + Data(repeating: UInt8($0), count: 100 * $0) }
        for (offset, image) in images.enumerated() {
            var pose = matrix_identity_float4x4
            pose.columns.3 = SIMD4(Float(offset) * 0.1, 1.4, 0, 1)
            let flat = (0..<4).flatMap { [pose[$0].x, pose[$0].y, pose[$0].z, pose[$0].w] }
            try store.appendFrame(image, RoomScanFrame(index: offset + 1, transform: flat, fx: 1450, fy: 1451,
                                                        cx: 960, cy: 720, width: 1920, height: 1440), to: id)
        }
        // A torn record (kill mid-append) is ignored.
        let handle = try FileHandle(forWritingTo: store.directory(for: id).appendingPathComponent("frames.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"index\":4,\"tra".utf8))
        try handle.close()

        let frames = store.committedFrames(for: id)
        #expect(frames.count == 3)
        let url = store.bundleURL(for: id)
        let size = try RoomScanBundle.build(frames: frames, imageURL: { store.imageURL(for: id, index: $0) }, to: url)
        let zip = try Data(contentsOf: url)
        #expect(zip.count == size)

        let entries = try readZip(zip)
        #expect(entries.map(\.name) == [
            "cameras/per_frame_intrinsics.json", "cameras/camera_trajectory.json",
            "images/Image_000001.jpg", "images/Image_000002.jpg", "images/Image_000003.jpg",
        ])
        #expect(entries.allSatisfy { $0.method == 0 })
        for (index, image) in images.enumerated() {
            #expect(entries[index + 2].data == image)
        }

        let intrinsics = try #require(JSONSerialization.jsonObject(with: entries[0].data) as? [String: Any])
        #expect(intrinsics["frame_count"] as? Int == 3)
        #expect(intrinsics["width_px"] as? Int == 1920)
        #expect(intrinsics["height_px"] as? Int == 1440)
        #expect(intrinsics["fx_px"] as? [Double] == [1450, 1450, 1450])
        #expect(intrinsics["fy_px"] as? [Double] == [1451, 1451, 1451])
        #expect(intrinsics["cx_px"] as? [Double] == [960, 960, 960])
        #expect(intrinsics["cy_px"] as? [Double] == [720, 720, 720])

        let trajectory = try #require(JSONSerialization.jsonObject(with: entries[1].data) as? [[[Double]]])
        #expect(trajectory.count == 3)
        #expect(trajectory.allSatisfy { $0.count == 4 && $0.allSatisfy { $0.count == 4 } && $0[3] == [0, 0, 0, 1] })
        // Identity rotation at (0.2, 1.4, 0): camera_from_world translation
        // is -t, then Y and Z flipped.
        #expect(abs(trajectory[2][0][3] - -0.2) < 1e-6)
        #expect(abs(trajectory[2][1][3] - 1.4) < 1e-6)
        #expect(abs(trajectory[2][2][3] - 0) < 1e-6)
    }

    private struct Entry { let name: String; let method: UInt16; let data: Data }

    /// EOCD → central directory → each local header, CRC checked with zlib.
    private func readZip(_ zip: Data) throws -> [Entry] {
        let bytes = [UInt8](zip)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        let eocd = bytes.count - 22
        try #require(u32(eocd) == 0x0605_4B50)
        let count = u16(eocd + 10)
        let cdSize = u32(eocd + 12)
        var cursor = u32(eocd + 16)
        try #require(cursor + cdSize == eocd)
        var entries: [Entry] = []
        for _ in 0..<count {
            try #require(u32(cursor) == 0x0201_4B50)
            let method = UInt16(u16(cursor + 10))
            let crc = u32(cursor + 16)
            let compressed = u32(cursor + 20)
            let size = u32(cursor + 24)
            let nameLength = u16(cursor + 28)
            let extra = u16(cursor + 30), comment = u16(cursor + 32)
            let local = u32(cursor + 42)
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            cursor += 46 + nameLength + extra + comment

            try #require(u32(local) == 0x0403_4B50)
            #expect(u16(local + 8) == Int(method))
            #expect(u32(local + 14) == crc && u32(local + 18) == compressed && u32(local + 22) == size)
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            let data = Data(bytes[start..<(start + size)])
            #expect(compressed == size)
            let actual = data.withUnsafeBytes { Int(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
            #expect(actual == crc, "CRC of \(name)")
            entries.append(Entry(name: name, method: method, data: data))
        }
        return entries
    }

    // MARK: - Trajectory

    @Test("ARKit pose → OpenCV camera_from_world: identity flips, a known point reprojects")
    func opencvConversion() {
        #expect(RoomScanBundle.opencvCameraFromWorld(matrix_identity_float4x4) == simd_double4x4(diagonal: SIMD4(1, -1, -1, 1)))

        // Camera at (1, 1.5, 2), yawed 90° left: ARKit -Z (forward) is world -X.
        let yaw = Float.pi / 2
        var pose = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
        pose.columns.3 = SIMD4(1, 1.5, 2, 1)
        let m = RoomScanBundle.opencvCameraFromWorld(pose)
        let (fx, fy, cx, cy) = (1450.0, 1450.0, 960.0, 720.0)
        func project(_ world: SIMD3<Double>) -> SIMD2<Double> {
            let p = m * SIMD4(world, 1)
            return SIMD2(fx * p.x / p.z + cx, fy * p.y / p.z + cy)
        }
        // 2 m straight ahead lands on the principal point.
        let ahead = project(SIMD3(1 - 2, 1.5, 2))
        #expect(abs(ahead.x - cx) < 1e-3 && abs(ahead.y - cy) < 1e-3)
        // 0.5 m right (world -Z after the yaw) and 0.5 m up of that point:
        // OpenCV +X right, +Y down → (cx + fx/4, cy - fy/4).
        let offset = project(SIMD3(1 - 2, 2.0, 2 - 0.5))
        #expect(abs(offset.x - (cx + fx / 4)) < 1e-3)
        #expect(abs(offset.y - (cy - fy / 4)) < 1e-3)

        let rows = RoomScanBundle.rowMajor(m)
        #expect(rows[0][3] == m.columns.3.x && rows[3] == [0, 0, 0, 1])
    }

    // MARK: - Keyframe gate

    /// A landscape-held camera at `x` metres, yawed `degrees`.
    private func pose(x: Float = 0, degrees: Float = 0) -> simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: degrees * .pi / 180, axis: SIMD3(0, 1, 0)))
        m.columns.3 = SIMD4(x, 1.4, 0, 1)
        return m
    }

    @Test("Keyframe gate: settle, cadence, heartbeat, tracking, cap, backpressure")
    func gateCadence() {
        var gate = RoomScanKeyframeGate(maxFrames: 3)
        func eval(_ m: simd_float4x4, _ t: TimeInterval, normal: Bool = true, canAccept: Bool = true) -> RoomScanKeyframeGate.Decision {
            gate.evaluate(transform: m, timestamp: t, trackingNormal: normal, exposure: 1.0 / 120, fx: 1450, canAccept: canAccept)
        }
        #expect(eval(pose(), 0) == .skip(.settling))
        #expect(eval(pose(), 0.6) == .accept)                              // first keyframe
        #expect(eval(pose(x: 0.08), 0.65) == .skip(.notMoved))             // 7 cm but < 0.12 s
        #expect(eval(pose(x: 0.08), 0.75, canAccept: false) == .skip(.busy))
        #expect(eval(pose(x: 0.08), 0.76) == .accept)                      // ≥0.12 s and ≥7 cm
        #expect(eval(pose(x: 0.09), 1.0) == .skip(.notMoved))              // 1 cm but < 0.35 s
        #expect(eval(pose(x: 0.09), 1.0, normal: false) == .skip(.tracking))
        #expect(eval(pose(x: 0.09), 1.3) == .skip(.settling))              // 0.5 s after recovery
        #expect(eval(pose(x: 0.095, degrees: 2), 1.6) == .accept)          // heartbeat: ≥0.35 s and ≥1.5°
        #expect(eval(pose(x: 0.5), 2.0) == .skip(.limit))
        #expect(gate.accepted == 3)
    }

    @Test("Keyframe gate: fast rotation is blur, a turned phone is the wrong hold")
    func gateBlurAndHold() {
        var gate = RoomScanKeyframeGate(maxFrames: 100)
        func eval(_ m: simd_float4x4, _ t: TimeInterval, exposure: Double = 1.0 / 30) -> RoomScanKeyframeGate.Decision {
            gate.evaluate(transform: m, timestamp: t, trackingNormal: true, exposure: exposure, fx: 1450)
        }
        #expect(eval(pose(), 0) == .skip(.settling))
        #expect(eval(pose(), 0.6) == .accept)
        // 60° in 0.15 s ≈ 7 rad/s · 1450 px · 1/30 s ≈ 340 px of blur.
        #expect(eval(pose(degrees: 60), 0.75) == .skip(.blur))
        // Slow again: 1° over 0.4 s.
        #expect(eval(pose(degrees: 60), 1.1) == .accept)
        // Rolled 90° about the view axis (after a pause, so no blur):
        // landscape → portrait.
        let rolled = pose(degrees: 60) * simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1)))
        #expect(eval(rolled, 2.0) == .skip(.holdChanged))
    }
}
