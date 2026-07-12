//
//  APIError.swift
//  VirtSpace
//
//  Typed network errors surfaced to the UI. Every network action maps failures
//  into one of these cases so nothing is silently swallowed.
//

import Foundation

enum APIError: Error, LocalizedError {
    case unauthorized
    case quota
    case server(Int, String?)
    case decoding(Error)
    case network(Error)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Not authorized. Check the dev-auth token in Secrets."
        case .quota:
            return "Daily scan quota or credit budget reached. Try again later."
        case .server(let code, let message):
            if let message, !message.isEmpty {
                return "Server error (\(code)): \(message)"
            }
            return "Server error (\(code)). Please try again."
        case .decoding:
            return "Couldn't read the server's response."
        case .network(let underlying):
            return underlying.localizedDescription
        case .invalidResponse:
            return "Unexpected response from the server."
        }
    }

    /// True when the backend reports the referenced world no longer exists:
    /// an HTTP 404 whose body carries the `world_not_found` code (or a bare 404
    /// on a world-scoped endpoint, which is unreachable either way). Deliberately
    /// narrow — transient network drops (`.network`) and 5xx server faults
    /// (`.server(500, …)`) are NOT world-gone, so callers only reset a stranded
    /// session and start fresh when the world is genuinely gone server-side,
    /// never on a retryable blip.
    var isWorldGone: Bool {
        guard case let .server(status, message) = self, status == 404 else { return false }
        guard let message, !message.isEmpty else { return true }
        return message.localizedCaseInsensitiveContains("world_not_found")
    }
}
