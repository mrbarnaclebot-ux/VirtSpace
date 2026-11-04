//
//  APIError.swift
//  VirtSpace
//
//  Typed network errors surfaced to the UI. `APIClient.send` branches on the
//  backend's `error` code (spec-doc §7.1 error codes), never on the HTTP
//  status alone. `errorDescription` is user copy (ui-spec §6 Errors): never a
//  raw code, status string or system message. Show it with
//  `ToastCenter.show(error)`; branch on the cases for anything else.
//

import Foundation

enum APIError: Error, LocalizedError {
    /// 401 / 403 from our API.
    case unauthorized
    /// 429 `scan_quota_exceeded`: the user's daily scans are spent.
    case scanQuota(resetAt: Date?)
    /// 429 `credit_budget_exceeded`: the deployment-wide generation budget for
    /// today is spent (`:enhance`, generation `:retry`).
    case creditBudget(resetAt: Date?)
    /// 429 `rate_limited` (or any other 402/429): too many requests, briefly.
    case rateLimited
    /// 404 `world_not_found` (or a 404 with no body): the space is gone.
    case notFound
    /// 409 `not_retryable` / `not_enhanceable`: the world is not in a status
    /// the action accepts. `status` is the world's current raw status.
    case notRetryable(status: String?)
    /// Any other HTTP failure. `code` is the body's `error` code (or raw text).
    case server(Int, String?)
    /// A local condition, not a server answer. The string is user copy.
    case localState(String)
    case decoding(Error)
    /// URL-level failure. `isConnectivityFailure` says whether it is offline.
    case network(Error)
    case invalidResponse

    var errorDescription: String? {
        #if DEBUG
        userMessage(includeDeveloperHints: true)
        #else
        userMessage(includeDeveloperHints: false)
        #endif
    }

    /// The copy for this error (ui-spec §6 Errors). Developer hints are for
    /// DEBUG builds only.
    func userMessage(includeDeveloperHints: Bool) -> String {
        switch self {
        case .unauthorized:
            let base = "Something went wrong signing in."
            return includeDeveloperHints ? base + " (DEBUG: check the dev-auth token in Secrets.)" : base
        case .scanQuota(let resetAt):
            return "You've used today's scans." + Self.moreAt(resetAt)
        case .creditBudget(let resetAt):
            return "Today's limit for building spaces is used up." + Self.moreAt(resetAt)
        case .rateLimited:
            return "Too many tries. Wait a moment and try again."
        case .notFound:
            return "This space was deleted."
        case .notRetryable:
            return "This space has already moved on."
        case .server(let status, _) where status >= 500:
            return "Something went wrong on our side. Try again in a minute."
        case .localState(let message):
            return message
        case .network where isConnectivityFailure:
            return "You're offline. Check your connection and try again."
        case .server, .decoding, .network, .invalidResponse:
            return "Something went wrong. Try again."
        }
    }

    private static func moreAt(_ date: Date?) -> String {
        guard let date else { return "" }
        return " More at \(date.formatted(date: .omitted, time: .shortened))."
    }

    /// True when the backend reports the referenced world no longer exists.
    /// Deliberately narrow: transient network drops and 5xx faults are NOT
    /// world-gone, so callers only reset a stranded session when the world is
    /// genuinely gone server-side, never on a retryable blip.
    var isWorldGone: Bool {
        if case .notFound = self { return true }
        return false
    }

    /// True when `POST /v1/worlds` refuses a replayed `Idempotency-Key`
    /// because the world it originally created has since been deleted (409
    /// `idempotency_key_world_deleted`). The key is spent; the caller must
    /// persist a NEW key and retry with it (spec §10 R4).
    var isIdempotencyConflict: Bool {
        guard case let .server(status, code) = self else { return false }
        return status == 409 && code == "idempotency_key_world_deleted"
    }

    /// True for a 403 from a presigned PUT. The URLs live 900 s, so on a slow
    /// run this is an expired signature: re-presign (`uploads:refresh`) and
    /// retry, never count it as a failed attempt (spec §10 R25). A 403 that
    /// survives a fresh presign is a real failure and counts as usual.
    var isExpiredPresign: Bool {
        guard case let .server(status, _) = self else { return false }
        return status == 403
    }

    /// A refusal that says "not right now": scan quota, credit budget, rate
    /// limit. The capture is fine; the world just can't be made yet.
    var isLimit: Bool {
        switch self {
        case .scanQuota, .creditBudget, .rateLimited: true
        default: false
        }
    }

    /// True when the failure is "the network isn't there right now": offline,
    /// timed out, connection dropped. These say nothing about whether the
    /// capture or the backend is healthy, so they must never count toward
    /// parking a session (spec §10 R4).
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

    /// Whether a failed upload attempt should count toward parking the
    /// session. Limits and connectivity failures don't.
    var countsTowardParking: Bool {
        !isLimit && !isConnectivityFailure
    }
}

extension APIError {
    /// Map a non-2xx HTTP answer to a case by its `error` code (spec-doc §7.1).
    /// `data` is the raw response body; non-JSON bodies are tolerated.
    static func from(status: Int, data: Data) -> APIError {
        let body = ErrorBody.decode(data)
        switch (status, body.error) {
        case (401, _), (403, _): return .unauthorized
        case (429, "scan_quota_exceeded"): return .scanQuota(resetAt: body.retryAt)
        case (429, "credit_budget_exceeded"): return .creditBudget(resetAt: body.retryAt)
        case (402, _), (429, _): return .rateLimited
        case (404, "world_not_found"): return .notFound
        case (404, nil) where body.text == nil: return .notFound
        case (409, "not_retryable"), (409, "not_enhanceable"): return .notRetryable(status: body.status)
        default: return .server(status, body.error ?? body.text)
        }
    }

    /// `{error, message?, retry_at?, status?}`. Unknown fields are ignored.
    private struct ErrorBody: Decodable {
        var error: String?
        var retryAt: Date?
        var status: String?
        var text: String?

        enum CodingKeys: String, CodingKey {
            case error, status
            case retryAt = "retry_at"
        }

        static func decode(_ data: Data) -> ErrorBody {
            guard !data.isEmpty else { return ErrorBody() }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom(APIClient.decodeDate)
            if let body = try? decoder.decode(ErrorBody.self, from: data) { return body }
            return ErrorBody(text: String(data: data, encoding: .utf8))
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
