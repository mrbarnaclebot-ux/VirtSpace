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

    init(baseURL: String = Secrets.apiBaseURL, session: URLSession = .shared) {
        // Trim any trailing slash so path joins are clean.
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.session = session

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(APIClient.decodeDate)
        self.decoder = decoder

        self.encoder = JSONEncoder()
    }

    // MARK: - Endpoints (spec §7.1)

    func createWorld(title: String, frameCount: Int, lat: Double? = nil, lng: Double? = nil) async throws -> (World, [FrameUpload]) {
        let body = try encoder.encode(CreateWorldRequest(title: title, frameCount: frameCount, lat: lat, lng: lng))
        let data = try await send(request("POST", "v1/worlds", body: body))
        let resp: CreateWorldResponse = try decode(data)
        return (resp.world, resp.uploads)
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

    /// `GET /v1/worlds` → `{ worlds: [...], has_more }`; each list item carries
    /// a thumbnail-only `assets` object.
    func listWorlds() async throws -> [World] {
        let data = try await send(request("GET", "v1/worlds"))
        let resp: WorldsListResponse = try decode(data)
        return resp.worlds
    }

    func enhance(worldId: String) async throws {
        _ = try await send(request("POST", "v1/worlds/\(worldId):enhance"))
    }

    func deleteWorld(id: String) async throws {
        _ = try await send(request("DELETE", "v1/worlds/\(id)"))
    }

    // MARK: - Request plumbing

    private func request(_ method: String, _ path: String, body: Data? = nil) -> URLRequest? {
        // Build by string so path colons (":enhance", "frames:done") stay literal.
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
        case 401, 403:
            AppLog.api.error("Unauthorized (\(http.statusCode)): \(tag, privacy: .public)")
            throw APIError.unauthorized
        case 402, 429:
            AppLog.api.error("Quota (\(http.statusCode)): \(tag, privacy: .public)")
            throw APIError.quota
        default:
            let message = APIClient.errorMessage(from: data)
            AppLog.api.error("Server error \(http.statusCode): \(tag, privacy: .public) — \(message ?? "no body", privacy: .public)")
            throw APIError.server(http.statusCode, message)
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

    private static func errorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["error", "message", "detail"] {
                if let value = object[key] as? String { return value }
            }
        }
        return String(data: data, encoding: .utf8)
    }

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
    private nonisolated static func decodeDate(_ decoder: Decoder) throws -> Date {
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
