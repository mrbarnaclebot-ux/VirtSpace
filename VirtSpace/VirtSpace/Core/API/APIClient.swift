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
        // Primary contract: { "world": {...}, "uploads": [...] }.
        if let resp = try? decoder.decode(CreateWorldResponse.self, from: data) {
            return (resp.world, resp.uploads)
        }
        // Fallback: world fields at top level alongside `uploads`.
        do {
            let world = try decoder.decode(World.self, from: data)
            let uploads = (try? decoder.decode(UploadsEnvelope.self, from: data))?.uploads ?? []
            return (world, uploads)
        } catch {
            throw APIError.decoding(error)
        }
    }

    func framesDone(worldId: String) async throws {
        _ = try await send(request("POST", "v1/worlds/\(worldId)/frames:done"))
    }

    func getWorld(id: String) async throws -> World {
        let data = try await send(request("GET", "v1/worlds/\(id)"))
        return try decodeWorld(from: data)
    }

    func listWorlds() async throws -> [World] {
        let data = try await send(request("GET", "v1/worlds"))
        if let envelope = try? decoder.decode(WorldsEnvelope.self, from: data) {
            return envelope.worlds
        }
        do {
            return try decoder.decode([World].self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
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
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.network(error)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw APIError.unauthorized
        case 402, 429:
            throw APIError.quota
        default:
            throw APIError.server(http.statusCode, APIClient.errorMessage(from: data))
        }
    }

    private func decodeWorld(from data: Data) throws -> World {
        if let world = try? decoder.decode(World.self, from: data) { return world }
        if let envelope = try? decoder.decode(WorldEnvelope.self, from: data) { return envelope.world }
        do {
            return try decoder.decode(World.self, from: data)
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

    private static let isoWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Lenient date decoding: ISO8601 (with/without fractional seconds) or epoch.
    private static func decodeDate(_ decoder: Decoder) throws -> Date {
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

/// Small envelope used only for the createWorld fallback path.
private struct UploadsEnvelope: Decodable {
    let uploads: [FrameUpload]
}
