//
//  Models.swift
//  VirtSpace
//
//  Core domain models mirroring the backend contract (spec §7).
//  JSON is snake_case; decoding uses explicit CodingKeys throughout for an
//  unambiguous, consistent mapping (chosen over .convertFromSnakeCase because
//  fields like `spz_500k_url` camel-case awkwardly).
//

import Foundation

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

    // MARK: Pipeline state

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
}

// MARK: - World

/// World metadata as serialized by the backend. Presigned asset URLs are NOT
/// part of this object — they arrive in a separate top-level `assets` object
/// (see `WorldAssets`); list items carry a thumbnail-only `assets`.
struct World: Identifiable, Decodable, Hashable {
    let id: String
    var title: String
    var status: WorldStatus

    var caption: String?
    var placeName: String?
    var lat: Double?
    var lng: Double?
    var isPublic: Bool?
    var phase: String?
    /// Within-status completion 0–100, or nil between phases / on old backends.
    var progress: Int?
    /// Server heartbeat (worlds.updated_at) — the last time the pipeline
    /// touched this row. Drives the "working / taking longer" staleness UI.
    var heartbeatAt: Date?
    var assetVersion: Int?
    var provider: String?
    var creditsSpent: Int?
    var createdAt: Date?

    /// Present on `GET /v1/worlds` list items (thumbnail-only assets object).
    var assets: WorldAssets?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case status
        case caption
        case placeName = "place_name"
        case lat
        case lng
        case isPublic = "is_public"
        case phase
        case progress
        case heartbeatAt = "heartbeat_at"
        case assetVersion = "asset_version"
        case provider
        case creditsSpent = "credits_spent"
        case createdAt = "created_at"
        case assets
    }

    var canEnhance: Bool { status == .draftReady }
}

// MARK: - WorldAssets

/// Presigned asset URLs (our R2, never provider CDN). Returned as a top-level
/// `assets` object on world detail; list items only populate `thumbnail_url`.
struct WorldAssets: Decodable, Hashable {
    var panoURL: String?
    var thumbnailURL: String?
    var spz100kURL: String?
    var spz500kURL: String?
    var spzFullURL: String?
    var colliderGLBURL: String?

    enum CodingKeys: String, CodingKey {
        case panoURL = "pano_url"
        case thumbnailURL = "thumbnail_url"
        case spz100kURL = "spz_100k_url"
        case spz500kURL = "spz_500k_url"
        case spzFullURL = "spz_full_url"
        case colliderGLBURL = "collider_glb_url"
    }

    /// The splat the 3D explorer loads, plus its tier tag (the cache key part
    /// that keeps a cached 500k file from ever being served as full_res).
    /// full_res is about 4x the splats of 500k (sharp lettering up close) and
    /// needs the headroom: 7 GiB admits every 8 GB iPhone (they report ~7.5 GiB)
    /// and up, and keeps 6 GB and smaller devices on 500k.
    static func explorerSplat(
        assets: WorldAssets?,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> (url: String, tier: String)? {
        if physicalMemory >= 7 * 1024 * 1024 * 1024,
           let full = assets?.spzFullURL, !full.isEmpty {
            return (full, "full")
        }
        guard let k500 = assets?.spz500kURL, !k500.isEmpty else { return nil }
        return (k500, "500k")
    }

    /// Thumbnail as a URL, when the signed URL is present.
    var thumbnailAsURL: URL? {
        guard let thumbnailURL, !thumbnailURL.isEmpty else { return nil }
        return URL(string: thumbnailURL)
    }

    /// Stitched equirectangular panorama as a URL, when the signed URL is present.
    var panoAsURL: URL? {
        guard let panoURL, !panoURL.isEmpty else { return nil }
        return URL(string: panoURL)
    }
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
    /// Depth opt-in (spec §5.2 item 3). nil (absent) keeps the request — and
    /// the response — byte-identical to the pre-depth contract.
    var depth: Bool?
    var depthFrames: [DepthFrameDeclaration]?

    enum CodingKeys: String, CodingKey {
        case title, lat, lng, depth
        case frameCount = "frame_count"
        case depthFrames = "depth_frames"
    }
}

/// One depth file's exact size, so its presigned PUT carries a signed
/// Content-Length (the R7 pattern). The backend 400s anything over 1 MiB.
nonisolated struct DepthFrameDeclaration: Codable, Hashable, Sendable {
    let index: Int
    let bytes: Int
}

/// `POST /v1/worlds/:id/uploads:refresh` body when depth is wanted.
struct RefreshUploadsRequest: Encodable {
    let depth: Bool
    let depthFrames: [DepthFrameDeclaration]

    enum CodingKeys: String, CodingKey {
        case depth
        case depthFrames = "depth_frames"
    }
}

struct CreateWorldResponse: Decodable {
    let world: World
    let uploads: [FrameUpload]
    /// Same shape as `uploads` (keys `depth_<i>.png`); present only when the
    /// request asked for depth.
    let depthUploads: [FrameUpload]?

    enum CodingKeys: String, CodingKey {
        case world, uploads
        case depthUploads = "depth_uploads"
    }
}

/// `POST /v1/worlds/:id/uploads:refresh` → the same `uploads` array shape as
/// create, re-issued so an interrupted upload can resume onto the identical R2
/// keys with fresh (unexpired) presigned URLs. `world` rides along unused.
struct RefreshUploadsResponse: Decodable {
    let world: World?
    let uploads: [FrameUpload]
    let depthUploads: [FrameUpload]?

    enum CodingKeys: String, CodingKey {
        case world, uploads
        case depthUploads = "depth_uploads"
    }
}

// MARK: - Frame poses (capture → backend)

/// One per-frame pose, mirroring a `poses.json` entry (see CaptureStore).
/// Sent up in the `frames:done` body so the server stitcher can do
/// pose-assisted reprojection (spec §5, §7 `captures.poses_json`). Field names
/// match poses.json exactly — the backend contract keys off these.
struct FramePose: Codable, Hashable {
    let index: Int
    let timestamp: TimeInterval
    /// Camera-to-world transform, 16 floats, column-major.
    let transform: [Float]
    /// Camera intrinsics, 9 floats, column-major (matches the JPEG pixels).
    let intrinsics: [Float]
    /// Whether AE/AWB were locked when this frame was taken.
    let exposureLocked: Bool
    /// Capture v2 (spec §5.2). Synthesized Codable encodes optionals with
    /// encodeIfPresent, so a nil field is absent from the JSON, never null —
    /// a null 400s the whole frames:done.
    var iso: Float?
    /// Seconds.
    var exposureDuration: Double?
    /// Metres; median depth of ARKit raw feature points in view.
    var featureDepthMedian: Float?
    /// Present iff this frame's depth_<index>.png was uploaded — the worker
    /// reads depth only for poses carrying it.
    var depth: FrameDepthSize?
}

/// Pixel size of a frame's depth map (spec §5.2 `depth`). Nonisolated: built
/// on the camera's encode queue.
nonisolated struct FrameDepthSize: Codable, Hashable, Sendable {
    let width: Int
    let height: Int
}

/// `POST /v1/worlds/:id/frames:done` body. `poses` is optional on the wire —
/// the backend tolerates it being absent (older clients / test harness).
struct FramesDoneRequest: Encodable {
    let poses: [FramePose]?
}

/// `GET /v1/worlds` → `{ worlds: [...], has_more, next_offset }`.
struct WorldsListResponse: Decodable {
    let worlds: [World]
    let hasMore: Bool?
    /// Offset of the next page; nil on the last page.
    let nextOffset: Int?

    enum CodingKeys: String, CodingKey {
        case worlds
        case hasMore = "has_more"
        case nextOffset = "next_offset"
    }
}

/// `GET /v1/worlds/:id` → `{ world: {metadata}, assets: {...} }`.
struct WorldEnvelope: Decodable {
    let world: World
    let assets: WorldAssets?
}

// MARK: - Quota

/// `GET /v1/me/quota` → the user's daily-scan allowance. Checked BEFORE a
/// capture starts so a full session is never shot only to be rejected with a
/// 429 at `POST /v1/worlds`. `quotaResetsAt` is nil when no window is active
/// (the user has their full allowance).
struct QuotaStatus: Decodable, Hashable {
    let scansRemaining: Int
    let quotaResetsAt: Date?
    let dailyQuota: Int

    enum CodingKeys: String, CodingKey {
        case scansRemaining = "scans_remaining"
        case quotaResetsAt = "quota_resets_at"
        case dailyQuota = "daily_quota"
    }

    var isExhausted: Bool { scansRemaining <= 0 }
}

/// `{ world: {metadata}, job_id }`: the answer of `frames:done`, `:enhance`
/// and `:retry`. `world` carries no assets; `jobId` nil = nothing new was
/// enqueued (a replay or a concurrent request already did).
struct WorldJobResponse: Decodable {
    let world: World
    let jobId: String?

    enum CodingKeys: String, CodingKey {
        case world
        case jobId = "job_id"
    }
}
