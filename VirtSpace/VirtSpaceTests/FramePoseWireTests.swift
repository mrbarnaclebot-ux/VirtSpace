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

    private func storePose(
        iso: Float? = nil,
        exposureDuration: Double? = nil,
        featureDepthMedian: Float? = nil,
        depth: FrameDepthSize? = nil
    ) -> CaptureStore.FramePose {
        CaptureStore.FramePose(
            index: 3,
            timestamp: 1.5,
            transform: matrix_identity_float4x4,
            intrinsics: matrix_identity_float3x3,
            exposureLocked: true,
            iso: iso,
            exposureDuration: exposureDuration,
            featureDepthMedian: featureDepthMedian,
            depth: depth
        )
    }

    @Test("Capture v2 fields use the spec's camelCase names")
    func fieldNames() throws {
        let pose = storePose(iso: 400, exposureDuration: 1.0 / 60, featureDepthMedian: 2.5,
                             depth: FrameDepthSize(width: 256, height: 192))
        let object = try json(pose.wire(depthUploaded: true))
        #expect(object["index"] as? Int == 3)
        #expect(object["exposureLocked"] as? Bool == true)
        #expect((object["iso"] as? Double).map { abs($0 - 400) < 1e-3 } == true)
        #expect((object["exposureDuration"] as? Double).map { abs($0 - 1.0 / 60) < 1e-9 } == true)
        #expect((object["transform"] as? [Double])?.count == 16)
        #expect((object["intrinsics"] as? [Double])?.count == 9)
        #expect((object["featureDepthMedian"] as? Double) == 2.5)
        let depth = try #require(object["depth"] as? [String: Any])
        #expect(depth["width"] as? Int == 256)
        #expect(depth["height"] as? Int == 192)
    }

    @Test("depth is sent only once its file was uploaded")
    func depthOnlyWhenUploaded() throws {
        let pose = storePose(depth: FrameDepthSize(width: 256, height: 192))
        #expect(try json(pose.wire(depthUploaded: false))["depth"] == nil)
        #expect(try json(pose.wire(depthUploaded: true))["depth"] != nil)
    }

    @Test("Create and refresh requests use the backend's snake_case depth fields")
    func depthRequestKeys() throws {
        var create = CreateWorldRequest(title: "t", frameCount: 28, lat: nil, lng: nil)
        let plain = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(create)) as? [String: Any])
        // No depth asked for: byte-compatible with the pre-depth contract.
        #expect(plain["depth"] == nil && plain["depth_frames"] == nil && plain["lat"] == nil)
        create.depth = true
        create.depthFrames = [DepthFrameDeclaration(index: 0, bytes: 1234)]
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(create)) as? [String: Any])
        #expect(object["depth"] as? Bool == true)
        #expect(object["frame_count"] as? Int == 28)
        let declared = try #require(object["depth_frames"] as? [[String: Any]])
        #expect(declared.first?["index"] as? Int == 0 && declared.first?["bytes"] as? Int == 1234)

        let refresh = RefreshUploadsRequest(depth: true, depthFrames: [DepthFrameDeclaration(index: 2, bytes: 9)])
        let refreshObject = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(refresh)) as? [String: Any])
        #expect(refreshObject["depth"] as? Bool == true)
        #expect((refreshObject["depth_frames"] as? [[String: Any]])?.count == 1)
    }

    @Test("depth_uploads decodes beside uploads, and is optional")
    func depthUploadsDecode() throws {
        let json = """
        {"world": {"id": "w", "title": "t", "status": "uploading"},
         "uploads": [{"index": 0, "key": "captures/c/frame_0.jpg", "url": "https://x.invalid/0"}],
         "depth_uploads": [{"index": 0, "key": "captures/c/depth_0.png", "url": "https://x.invalid/d0",
                            "method": "PUT", "headers": {"content-type": "image/png"}}]}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(CreateWorldResponse.self, from: json)
        #expect(response.depthUploads?.first?.key == "captures/c/depth_0.png")
        let legacy = try JSONDecoder().decode(RefreshUploadsResponse.self, from: """
        {"uploads": []}
        """.data(using: .utf8)!)
        #expect(legacy.depthUploads == nil)
    }

    @Test("Absent optionals are omitted, never encoded as null")
    func nilFieldsAreAbsent() throws {
        let data = try JSONEncoder().encode(storePose().wire(depthUploaded: true))
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
        #expect(pose.depth == nil)
    }
}
