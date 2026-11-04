//
//  APIErrorTests.swift
//  VirtSpaceTests
//
//  `isWorldGone` decides whether the app throws away a world binding and mints
//  a NEW (billable) one, so being wrong here costs real money: a transient
//  5xx must never look like "the world is gone". The parking classifiers decide
//  whether a failure counts against a capture's retry budget (spec §10 R4/R13).
//  The copy tests pin ui-spec §6 Errors: no raw codes, no "Secrets" in Release.
//

import Foundation
import Testing
@testable import VirtSpace

@Suite("APIError classification")
struct APIErrorTests {
    private func map(_ status: Int, _ body: String = "") -> APIError {
        APIError.from(status: status, data: Data(body.utf8))
    }

    @Test("Each 429 code maps to its own case, with retry_at")
    func limitCodes() throws {
        let quota = map(429, #"{"error":"scan_quota_exceeded","message":"x","retry_at":"2026-11-05T16:00:00.000Z"}"#)
        guard case .scanQuota(let at) = quota else { Issue.record("got \(quota)"); return }
        #expect(at == Date(timeIntervalSince1970: 1_793_894_400))

        let budget = map(429, #"{"error":"credit_budget_exceeded","message":"x","retry_at":"2026-11-06T00:00:00Z"}"#)
        guard case .creditBudget(let budgetAt) = budget else { Issue.record("got \(budget)"); return }
        #expect(budgetAt != nil)

        // The rate limiter's body: retry_after is a human string, ignored.
        guard case .rateLimited = map(429, #"{"statusCode":429,"error":"rate_limited","retry_after":"1 minute"}"#) else {
            Issue.record("rate_limited"); return
        }
        guard case .rateLimited = map(429) else { Issue.record("bare 429"); return }
        guard case .rateLimited = map(402) else { Issue.record("402"); return }
    }

    @Test("rate_limited is not the scan quota, in case or copy")
    func rateLimitedIsNotQuota() {
        let error = map(429, #"{"error":"rate_limited"}"#)
        #expect(error.userMessage(includeDeveloperHints: false) == "Too many tries. Wait a moment and try again.")
        #expect(!error.userMessage(includeDeveloperHints: false).contains("scans"))
    }

    @Test("404, 409 and auth codes map to typed cases")
    func otherCodes() {
        guard case .notFound = map(404, #"{"error":"world_not_found"}"#) else { Issue.record("404"); return }
        guard case .notFound = map(404) else { Issue.record("empty 404"); return }
        guard case .notRetryable(let status) = map(409, #"{"error":"not_retryable","status":"complete"}"#) else {
            Issue.record("not_retryable"); return
        }
        #expect(status == "complete")
        guard case .notRetryable = map(409, #"{"error":"not_enhanceable","status":"stitching"}"#) else {
            Issue.record("not_enhanceable"); return
        }
        guard case .unauthorized = map(401, #"{"error":"unauthenticated"}"#) else { Issue.record("401"); return }
        guard case .unauthorized = map(403) else { Issue.record("403"); return }
        guard case .server(500, "internal_error") = map(500, #"{"error":"internal_error"}"#) else {
            Issue.record("500"); return
        }
    }

    @Test("404 world_not_found is world-gone")
    func worldGone() {
        #expect(map(404, #"{"error":"world_not_found"}"#).isWorldGone)
        #expect(map(404).isWorldGone)
        #expect(APIError.notFound.isWorldGone)
    }

    @Test("Retryable failures are never world-gone")
    func notWorldGone() {
        #expect(!map(500, #"{"error":"internal_error"}"#).isWorldGone)
        #expect(!map(503, #"{"error":"world_not_found"}"#).isWorldGone)
        #expect(!map(404, #"{"error":"capture_not_found"}"#).isWorldGone)
        // A proxy's HTML 404 is not proof the world is gone.
        #expect(!map(404, "<html>not found</html>").isWorldGone)
        #expect(!APIError.scanQuota(resetAt: nil).isWorldGone)
        #expect(!APIError.unauthorized.isWorldGone)
        #expect(!APIError.invalidResponse.isWorldGone)
        #expect(!Fixtures.offline.isWorldGone)
    }

    @Test("Only idempotency_key_world_deleted is an idempotency conflict")
    func idempotencyConflict() {
        #expect(map(409, #"{"error":"idempotency_key_world_deleted","world_id":"w"}"#).isIdempotencyConflict)
        #expect(!map(409, #"{"error":"not_retryable","status":"complete"}"#).isIdempotencyConflict)
        #expect(!map(409, #"{"error":"something_else"}"#).isIdempotencyConflict)
        #expect(!APIError.notFound.isIdempotencyConflict)
    }

    @Test("Limits and connectivity failures don't count toward parking")
    func parkingClassification() {
        #expect(!APIError.scanQuota(resetAt: nil).countsTowardParking)
        #expect(!APIError.creditBudget(resetAt: nil).countsTowardParking)
        #expect(!APIError.rateLimited.countsTowardParking)
        #expect(!Fixtures.offline.countsTowardParking)
        #expect(!APIError.network(URLError(.timedOut)).countsTowardParking)
        #expect(!APIError.network(URLError(.networkConnectionLost)).countsTowardParking)

        #expect(APIError.server(500, "boom").countsTowardParking)
        #expect(APIError.notFound.countsTowardParking)
        #expect(APIError.unauthorized.countsTowardParking)
        #expect(APIError.invalidResponse.countsTowardParking)
        #expect(APIError.localState("x").countsTowardParking)
        // A non-URL error we can't prove is transient counts.
        #expect(APIError.network(URLError(.badURL)).countsTowardParking)
    }

    @Test("User copy per case (ui-spec §6 Errors)")
    func copy() {
        let release: (APIError) -> String = { $0.userMessage(includeDeveloperHints: false) }
        #expect(release(.unauthorized) == "Something went wrong signing in.")
        #expect(!release(.unauthorized).contains("Secrets"))
        #expect(APIError.unauthorized.userMessage(includeDeveloperHints: true).contains("Secrets"))
        #expect(release(.scanQuota(resetAt: nil)) == "You've used today's scans.")
        #expect(release(.scanQuota(resetAt: .now)).hasPrefix("You've used today's scans. More at "))
        #expect(release(.notFound) == "This space was deleted.")
        #expect(release(.notRetryable(status: nil)) == "This space has already moved on.")
        #expect(release(.server(500, "internal_error")) == "Something went wrong on our side. Try again in a minute.")
        #expect(release(.server(400, "invalid_body")) == "Something went wrong. Try again.")
        #expect(release(Fixtures.offline) == "You're offline. Check your connection and try again.")
        #expect(release(.decoding(URLError(.cannotDecodeContentData))) == "Something went wrong. Try again.")
        #expect(release(.invalidResponse) == "Something went wrong. Try again.")
        #expect(release(.localState("This scan is already uploading.")) == "This scan is already uploading.")
    }
}
