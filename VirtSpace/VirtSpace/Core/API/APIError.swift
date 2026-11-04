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

    /// True when `POST /v1/worlds` refuses a replayed `Idempotency-Key` because
    /// the world it originally created has since been deleted (HTTP 409). The
    /// key is spent and can never produce a world again; the caller must
    /// persist a NEW key and retry with it (spec §10 R4).
    var isIdempotencyConflict: Bool {
        guard case let .server(status, _) = self, status == 409 else { return false }
        return true
    }

    /// True for a 403 from a presigned PUT. The URLs live 900 s, so on a slow
    /// run this is an expired signature: re-presign (`uploads:refresh`) and
    /// retry, never count it as a failed attempt (spec §10 R25). A 403 that
    /// survives a fresh presign is a real failure and counts as usual.
    var isExpiredPresign: Bool {
        guard case let .server(status, _) = self else { return false }
        return status == 403
    }

    /// True when the failure is "the network isn't there right now" — the
    /// device is offline, the request timed out, the connection dropped. These
    /// say nothing about whether the capture or the backend is healthy, so they
    /// must never count toward parking a session (spec §10 R4).
    var isConnectivityFailure: Bool {
        guard case let .network(underlying) = self else { return false }
        let error = underlying as NSError
        guard error.domain == NSURLErrorDomain else { return false }
        switch error.code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorTimedOut,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorInternationalRoamingOff,
             NSURLErrorDataNotAllowed,
             NSURLErrorCallIsActive,
             NSURLErrorSecureConnectionFailed:
            return true
        default:
            return false
        }
    }

    /// Whether a failed upload attempt should count toward parking the session.
    /// Quota refusals (402/429) and connectivity failures don't: the capture is
    /// fine, the world just can't be made *right now*.
    var countsTowardParking: Bool {
        switch self {
        case .quota: return false
        default: return !isConnectivityFailure
        }
    }
}

extension Error {
    /// Same question for an arbitrary error: anything that isn't a recognised
    /// APIError counts (we can't prove it's transient), except a bare URL-level
    /// connectivity error.
    var countsTowardUploadParking: Bool {
        if let apiError = self as? APIError { return apiError.countsTowardParking }
        return APIError.network(self).countsTowardParking
    }
}
