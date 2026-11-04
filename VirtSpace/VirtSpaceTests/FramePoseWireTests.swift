//
//  FramePoseWireTests.swift
//  VirtSpaceTests
//
//  The frames:done pose contract (spec §5.2 item 1). The backend validates the
//  capture v2 fields by name and type and 400s the whole request on a JSON
//  null, so both the camelCase names and the omission of absent fields matter.
//

import Foundation
import Testing
import simd
@testable import VirtSpace

@Suite("FramePose wire shape")
struct FramePoseWireTests {
    private func json(_ pose: FramePose) throws -> [String: Any] {
        let data = try JSONEncoder().encode(pose)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func storePose(iso: Float? = nil, exposureDuration: Double? = nil) -> CaptureStore.FramePose {
        CaptureStore.FramePose(
            index: 3,
            timestamp: 1.5,
            transform: matrix_identity_float4x4,
            intrinsics: matrix_identity_float3x3,
            exposureLocked: true,
            iso: iso,
            exposureDuration: exposureDuration
        )
    }

    @Test("Capture v2 fields use the spec's camelCase names")
    func fieldNames() throws {
        let object = try json(storePose(iso: 400, exposureDuration: 1.0 / 60).wire)
        #expect(object["index"] as? Int == 3)
        #expect(object["exposureLocked"] as? Bool == true)
        #expect((object["iso"] as? Double).map { abs($0 - 400) < 1e-3 } == true)
        #expect((object["exposureDuration"] as? Double).map { abs($0 - 1.0 / 60) < 1e-9 } == true)
        #expect((object["transform"] as? [Double])?.count == 16)
        #expect((object["intrinsics"] as? [Double])?.count == 9)
    }

    @Test("Absent optionals are omitted, never encoded as null")
    func nilFieldsAreAbsent() throws {
        let data = try JSONEncoder().encode(storePose().wire)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["iso", "exposureDuration", "featureDepthMedian", "depth"] {
            #expect(object[key] == nil, "\(key) must be omitted")
        }
        #expect(!String(decoding: data, as: UTF8.self).contains("null"))
    }

    @Test("A manifest pose written before capture v2 still decodes")
    func legacyManifestPose() throws {
        let legacy = """
        {"index":0,"timestamp":1,"transform":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],
         "intrinsics":[1,0,0,0,1,0,0,0,1],"exposureLocked":false}
        """.data(using: .utf8)!
        let pose = try JSONDecoder().decode(CaptureStore.FramePose.self, from: legacy)
        #expect(pose.iso == nil)
        #expect(pose.exposureDuration == nil)
    }
}
