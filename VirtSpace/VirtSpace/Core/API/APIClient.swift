//
//  APIClient.swift
//  VirtSpace
//
//  Thin async/await client over URLSession for the v1 backend (spec §7.1).
//  Attaches dev-auth headers from Secrets. Injected into the SwiftUI
//  environment as an @Observable service.
//

import Foundation
import Observation
import OSLog

@Observable
final class APIClient {
    let baseURL: String
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    /// Host of the owner's production backend (Railway). Named so the DEBUG
    /// simulator guard below can recognise it without re-deriving it from a
    /// string literal at the call site.
    static let productionHost = "api-production-dbd38.up.railway.app"

    /// Fallback used whenever a DEBUG run must not be allowed near production
    /// (simulator guard, XCTest host). Points at a local backend/mock.
    static let localBaseURL = "http://localhost:8080"

    /// Resolve the backend base URL. In DEBUG a `VIRTSPACE_API_BASE_URL` launch
    /// env var (e.g. a local mock backend) overrides the compiled-in default so
    /// upload/resume flows can be exercised end-to-end off production. Never
    /// consulted in release builds.
    static var defaultBaseURL: String {
        #if DEBUG
        // Hosted unit tests launch the real app process. Pin them to localhost
        // so nothing a test does can reach a deployed backend, and so the
        // production guard below can never fatalError the test host.
        if TestEnvironment.isRunningUnderXCTest { return localBaseURL }
        if let override = ProcessInfo.processInfo.environment["VIRTSPACE_API_BASE_URL"],
           !override.isEmpty {
            return guardAgainstProduction(override)
        }
        return guardAgainstProduction(Secrets.apiBaseURL)
        #else
        return Secrets.apiBaseURL
        #endif
    }

    #if DEBUG
    /// Production-data guard (spec §10 R5). A DEBUG **simulator** run that
    /// resolves to the production host is an accident in nearly every case —
    /// agent/QA sim runs have previously written real frames into the owner's
    /// production library and burned the daily scan quota, because launch-time
    /// resume/recovery kicks create real state before anyone touches the UI.
    /// Such a run dies immediately with an explanation; set
    /// `VIRTSPACE_ALLOW_PROD=1` in the scheme's environment for a deliberate
    /// production check from the simulator.
    ///
    /// On a physical device this is a no-op: the owner routinely runs DEBUG
    /// builds against production with free provisioning, and that must keep
    /// working unchanged.
    private static func guardAgainstProduction(_ urlString: String) -> String {
        #if targetEnvironment(simulator)
        let host = URLComponents(string: urlString)?.host ?? ""
        if host == productionHost,
           ProcessInfo.processInfo.environment["VIRTSPACE_ALLOW_PROD"] != "1" {
            fatalError("""
            Refusing to run a DEBUG simulator build against PRODUCTION (\(host)).

            Simulator runs create real data: launch-time upload resume/recovery \
            mints worlds, uploads frames and spends the daily scan quota before \
            you touch the UI.

            Fix one of these:
              • point the run at a local backend/mock: set VIRTSPACE_API_BASE_URL \
            (e.g. http://localhost:8080) in the scheme's Run → Arguments → \
            Environment Variables, or
              • if you really mean production, set VIRTSPACE_ALLOW_PROD=1 there too.

            Physical-device DEBUG builds are unaffected by this guard.
            """)
        }
        #endif
        return urlString
    }
    #endif

    init(baseURL: String = APIClient.defaultBaseURL, session: URLSession = .shared) {
        // Trim any trailing slash so path joins are clean.
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.session = session

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(APIClient.decodeDate)
        self.decoder = decoder

        self.encoder = JSONEncoder()
    }

    // MARK: - Endpoints (spec §7.1)

    /// Mint a world for a capture session.
    ///
    /// `idempotencyKey` is sent as the `Idempotency-Key` header: replaying a
    /// request with the same key returns the SAME world (same response shape)
    /// and charges quota/credits once, so a kill or retry between request and
    /// response can never mint a second billable world (spec §10 R4). The
    /// backend answers 409 when the world previously created for that key has
    /// since been deleted — see `APIError.isIdempotencyConflict`; the caller
    /// then persists a fresh key and retries.
    ///
    /// `depthFrames` non-nil opts into LiDAR depth (spec §5.2): the response
    /// then carries `depth_uploads` (returned third). An idempotent replay
    /// only returns them if it sends the same depth fields, so callers must
    /// build the identical body on every retry.
    func createWorld(
        title: String,
        frameCount: Int,
        depthFrames: [DepthFrameDeclaration]? = nil,
        idempotencyKey: UUID? = nil,
        lat: Double? = nil,
        lng: Double? = nil
    ) async throws -> (World, [FrameUpload], [FrameUpload]) {
        var payload = CreateWorldRequest(title: title, frameCount: frameCount, lat: lat, lng: lng)
        if let depthFrames {
            payload.depth = true
            payload.depthFrames = depthFrames
        }
        let body = try encoder.encode(payload)
        var req = request("POST", "v1/worlds", body: body)
        if let idempotencyKey {
            req?.setValue(idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key")
        }
        let data = try await send(req)
        let resp: CreateWorldResponse = try decode(data)
        return (resp.world, resp.uploads, resp.depthUploads ?? [])
    }

    /// Re-issue presigned frame PUT URLs for an in-progress capture (resume
    /// path). Same keys/TTL/content-type as `createWorld`; the world is NOT
    /// recreated. Called by `CaptureUploader` when resuming a session that
    /// already has a `createdWorldId`, so a dropped/expired URL never orphans a
    /// world by forcing a fresh `createWorld`.
    /// `depthFrames` non-nil also re-presigns the depth slots (same shape).
    func refreshUploads(
        worldId: String,
        depthFrames: [DepthFrameDeclaration]? = nil
    ) async throws -> (World, [FrameUpload], [FrameUpload]) {
        let body = try depthFrames.map { try encoder.encode(RefreshUploadsRequest(depth: true, depthFrames: $0)) }
        let data = try await send(request("POST", "v1/worlds/\(worldId)/uploads:refresh", body: body))
        let resp: RefreshUploadsResponse = try decode(data)
        let depthUploads = resp.depthUploads ?? []
        if let world = resp.world {
            return (world, resp.uploads, depthUploads)
        }
        // Backend always echoes `world`; if a lenient/older shape omits it, fall
        // back to a detail fetch so callers still get a valid World.
        let world = try await getWorld(id: worldId).world
        return (world, resp.uploads, depthUploads)
    }

    /// Mint a room-scan world (spec §5.3): one presigned PUT for the bundle
    /// plus the server's frame ceiling. Same Idempotency-Key, quota and rate
    /// limit as a spot-scan create.
    func createRoomScan(
        frameCount: Int,
        bundleBytes: Int,
        title: String,
        idempotencyKey: UUID
    ) async throws -> (world: World, upload: FrameUpload, maxFrames: Int?) {
        let body = try encoder.encode(CreateRoomScanRequest(frameCount: frameCount, bundleBytes: bundleBytes, title: title))
        var req = request("POST", "v1/worlds", body: body)
        req?.setValue(idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key")
        let resp: CreateRoomScanResponse = try decode(try await send(req))
        return (resp.world, resp.bundleUpload.slot, resp.maxFrames)
    }

    /// Re-sign a room scan's bundle PUT (expired presign, resume).
    func refreshBundleUpload(worldId: String) async throws -> FrameUpload {
        let resp: RefreshBundleResponse = try decode(try await send(request("POST", "v1/worlds/\(worldId)/uploads:refresh")))
        return resp.bundleUpload.slot
    }

    /// Signal all frames uploaded. `poses` (when present) is included in the
    /// body so the backend can persist per-frame ARKit attitude for
    /// pose-assisted stitching; the field is optional on the contract.
    func framesDone(worldId: String, poses: [FramePose]? = nil) async throws {
        var body: Data?
        if let poses, !poses.isEmpty {
            body = try encoder.encode(FramesDoneRequest(poses: poses))
        }
        // Response is { world: {metadata}, job_id } — not needed by callers.
        _ = try await send(request("POST", "v1/worlds/\(worldId)/frames:done", body: body))
    }

    /// `GET /v1/worlds/:id` → `{ world: {metadata}, assets: {...} }`. Presigned
    /// asset URLs live only in the top-level `assets` object, never on `world`.
    func getWorld(id: String) async throws -> WorldEnvelope {
        let data = try await send(request("GET", "v1/worlds/\(id)"))
        return try decode(data)
    }

    /// `GET /v1/worlds?offset=&limit=` → one page, newest first, with
    /// `has_more` / `next_offset`. Each item carries a thumbnail-only `assets`
    /// object. `limit` nil = the server default (20, max 100).
    func listWorlds(offset: Int = 0, limit: Int? = nil) async throws -> WorldsListResponse {
        var query = "offset=\(offset)"
        if let limit { query += "&limit=\(limit)" }
        let data = try await send(request("GET", "v1/worlds?\(query)"))
        return try decode(data)
    }

    /// `GET /v1/me/quota` → the user's daily-scan allowance. Called before a
    /// capture starts so quota is enforced up front, not after a full session.
    func quota() async throws -> QuotaStatus {
        let data = try await send(request("GET", "v1/me/quota"))
        return try decode(data)
    }

    /// `POST /v1/worlds/{id}:enhance` → `{world, job_id}`. 409
    /// `.notRetryable`, 429 `.creditBudget` / `.rateLimited`.
    @discardableResult
    func enhance(worldId: String) async throws -> WorldJobResponse {
        try decode(try await send(request("POST", "v1/worlds/\(worldId):enhance")))
    }

    /// `POST /v1/worlds/{id}:retry` re-runs the phase a `failed_*` world
    /// failed in. 200 `{world, job_id}`; `job_id == nil` means a retry is
    /// already running (double tap, replay): success all the same. Errors:
    /// `.notRetryable`, `.notFound`, `.scanQuota` (draft retry),
    /// `.creditBudget`, `.rateLimited`. Not idempotent-keyed: never call it
    /// in a loop; it is an explicit user action that can bill again.
    func retry(worldId: String) async throws -> WorldJobResponse {
        try decode(try await send(request("POST", "v1/worlds/\(worldId):retry")))
    }

    func deleteWorld(id: String) async throws {
        _ = try await send(request("DELETE", "v1/worlds/\(id)"))
    }

    /// `DELETE /v1/account` (Apple account-deletion requirement, spec §13):
    /// cascades Neon rows, R2 assets, APNs tokens and provider-side worlds. The
    /// caller is responsible for clearing local caches afterwards.
    func deleteAccount() async throws {
        _ = try await send(request("DELETE", "v1/account"))
    }

    // MARK: - Request plumbing

    private func request(_ method: String, _ path: String, body: Data? = nil) -> URLRequest? {
        // Build by string so path colons (":enhance", ":retry", "frames:done") stay literal.
        guard let url = URL(string: baseURL + "/" + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(Secrets.devAuthToken)", forHTTPHeaderField: "Authorization")
        req.setValue(Secrets.devUserId, forHTTPHeaderField: "x-dev-user")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func send(_ request: URLRequest?) async throws -> Data {
        guard let request else { throw APIError.invalidResponse }
        // Redacted for logs: method + path only, never the Authorization header.
        let tag = "\(request.httpMethod ?? "?") \(AppLog.redact(request.url))"
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            AppLog.api.error("Network failure: \(tag, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            throw APIError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            AppLog.api.error("Non-HTTP response: \(tag, privacy: .public)")
            throw APIError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            return data
        default:
            let error = APIError.from(status: http.statusCode, data: data)
            AppLog.api.error("HTTP \(http.statusCode): \(tag, privacy: .public) — \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    // MARK: - Helpers

    // ISO8601DateFormatter is thread-safe; nonisolated(unsafe) is sound here.
    private nonisolated(unsafe) static let isoWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private nonisolated(unsafe) static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Lenient date decoding: ISO8601 (with/without fractional seconds) or epoch.
    nonisolated static func decodeDate(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            if let date = isoWithFractional.date(from: string) { return date }
            if let date = isoPlain.date(from: string) { return date }
            if let seconds = Double(string) { return Date(timeIntervalSince1970: seconds) }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date: \(string)")
        }
        if let seconds = try? container.decode(Double.self) {
            return Date(timeIntervalSince1970: seconds)
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date value")
    }
}
