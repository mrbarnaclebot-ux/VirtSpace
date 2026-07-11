//
//  Models.swift
//  VirtSpace
//
//  Core domain models mirroring the backend contract (spec §7).
//  JSON is snake_case; decoding uses explicit CodingKeys throughout for an
//  unambiguous, consistent mapping (chosen over .convertFromSnakeCase because
//  fields like `spz_500k_url` camel-case awkwardly).
//

import SwiftUI

// MARK: - WorldStatus

/// The §7 world state machine. `failed(String)` is a catch-all with a custom
/// Codable init so unknown or `failed_<phase>` statuses never crash decoding.
enum WorldStatus: Hashable, Codable {
    case capturing
    case uploading
    case stitching
    case generatingDraft
    case draftReady
    case generatingHq
    case complete
    case failed(String)

    init(rawString raw: String) {
        switch raw {
        case "capturing": self = .capturing
        case "uploading": self = .uploading
        case "stitching": self = .stitching
        case "generating_draft": self = .generatingDraft
        case "draft_ready": self = .draftReady
        case "generating_hq": self = .generatingHq
        case "complete": self = .complete
        default: self = .failed(raw) // handles failed_* and any unknown value
        }
    }

    var rawString: String {
        switch self {
        case .capturing: return "capturing"
        case .uploading: return "uploading"
        case .stitching: return "stitching"
        case .generatingDraft: return "generating_draft"
        case .draftReady: return "draft_ready"
        case .generatingHq: return "generating_hq"
        case .complete: return "complete"
        case .failed(let raw): return raw
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = WorldStatus(rawString: raw)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawString)
    }

    // MARK: Presentation

    /// True while a background job is running and the library should keep polling.
    var isActive: Bool {
        switch self {
        case .uploading, .stitching, .generatingDraft, .generatingHq: return true
        default: return false
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .capturing: return "Capturing"
        case .uploading: return "Uploading"
        case .stitching: return "Stitching"
        case .generatingDraft: return "Reconstructing"
        case .draftReady: return "Draft ready"
        case .generatingHq: return "Enhancing"
        case .complete: return "Complete"
        case .failed: return "Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .capturing: return "camera"
        case .uploading: return "arrow.up.circle"
        case .stitching: return "square.stack.3d.up"
        case .generatingDraft: return "sparkles"
        case .draftReady: return "checkmark.seal"
        case .generatingHq: return "wand.and.stars"
        case .complete: return "checkmark.seal.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .capturing: return .gray
        case .uploading: return .blue
        case .stitching: return .teal
        case .generatingDraft: return .indigo
        case .draftReady: return .green
        case .generatingHq: return .purple
        case .complete: return .green
        case .failed: return .red
        }
    }
}

// MARK: - World

struct World: Identifiable, Decodable, Hashable {
    let id: String
    var title: String
    var status: WorldStatus

    var ownerId: String?
    var caption: String?
    var placeName: String?
    var lat: Double?
    var lng: Double?
    var isPublic: Bool?
    var createdAt: Date?

    // Asset columns — always point at our R2, never the provider CDN.
    var panoURL: String?
    var thumbnailURL: String?
    var spz100kURL: String?
    var spz500kURL: String?
    var spzFullURL: String?
    var colliderGLBURL: String?
    var assetVersion: Int?

    // Provider columns (draft-first: two provider worlds per VirtSpace world).
    var provider: String?
    var draftWorldId: String?
    var hqWorldId: String?
    var draftModel: String?
    var hqModel: String?
    var creditsSpent: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case status
        case ownerId = "owner_id"
        case caption
        case placeName = "place_name"
        case lat
        case lng
        case isPublic = "is_public"
        case createdAt = "created_at"
        case panoURL = "pano_url"
        case thumbnailURL = "thumbnail_url"
        case spz100kURL = "spz_100k_url"
        case spz500kURL = "spz_500k_url"
        case spzFullURL = "spz_full_url"
        case colliderGLBURL = "collider_glb_url"
        case assetVersion = "asset_version"
        case provider
        case draftWorldId = "draft_world_id"
        case hqWorldId = "hq_world_id"
        case draftModel = "draft_model"
        case hqModel = "hq_model"
        case creditsSpent = "credits_spent"
    }

    /// Best available thumbnail as a URL, when the signed URL is present.
    var thumbnailAsURL: URL? {
        guard let thumbnailURL, !thumbnailURL.isEmpty else { return nil }
        return URL(string: thumbnailURL)
    }

    var canEnhance: Bool { status == .draftReady }
}

// MARK: - FrameUpload

/// A presigned upload slot returned by `POST /v1/worlds`. The client PUTs frame
/// bytes to `url` with exactly `headers`, using `method` (defaults to PUT).
struct FrameUpload: Decodable, Hashable {
    let index: Int
    let key: String
    let url: String
    let method: String?
    let headers: [String: String]?

    var httpMethod: String { method ?? "PUT" }
}

// MARK: - Capture

/// A capture session's frame set (spec §7 `captures`). Minimal for Stage A;
/// full pose payloads land with the capture pipeline in a later stage.
struct Capture: Identifiable, Decodable, Hashable {
    let id: String
    var worldId: String?
    var frameCount: Int?
    var r2FramesPrefix: String?

    enum CodingKeys: String, CodingKey {
        case id
        case worldId = "world_id"
        case frameCount = "frame_count"
        case r2FramesPrefix = "r2_frames_prefix"
    }
}

// MARK: - Request / response envelopes

struct CreateWorldRequest: Encodable {
    let title: String
    let frameCount: Int
    let lat: Double?
    let lng: Double?

    enum CodingKeys: String, CodingKey {
        case title, lat, lng
        case frameCount = "frame_count"
    }
}

struct CreateWorldResponse: Decodable {
    let world: World
    let uploads: [FrameUpload]
}

struct WorldsEnvelope: Decodable {
    let worlds: [World]
}

struct WorldEnvelope: Decodable {
    let world: World
}
