//
//  APIErrorTests.swift
//  VirtSpaceTests
//
//  `isWorldGone` decides whether the app throws away a world binding and mints
//  a NEW (billable) one, so being wrong here costs real money — a transient
//  5xx must never look like "the world is gone". The parking classifiers decide
//  whether a failure counts against a capture's retry budget (spec §10 R4/R13).
//

import Foundation
import Testing
@testable import VirtSpace

@Suite("APIError classification")
struct APIErrorTests {
    @Test("404 world_not_found is world-gone")
    func worldGone() {
        #expect(APIError.server(404, "world_not_found").isWorldGone)
        #expect(APIError.server(404, "WORLD_NOT_FOUND").isWorldGone)
        #expect(APIError.server(404, #"{"error":"world_not_found"}"#).isWorldGone)
        // A bare 404 on a world-scoped endpoint is unreachable either way.
        #expect(APIError.server(404, nil).isWorldGone)
        #expect(APIError.server(404, "").isWorldGone)
    }

    @Test("Retryable failures are never world-gone")
    func notWorldGone() {
        #expect(!APIError.server(500, "boom").isWorldGone)
        #expect(!APIError.server(503, "world_not_found in a 503 body").isWorldGone)
        #expect(!APIError.server(404, "capture_not_found").isWorldGone)
        #expect(!APIError.quota.isWorldGone)
        #expect(!APIError.unauthorized.isWorldGone)
        #expect(!APIError.invalidResponse.isWorldGone)
        #expect(!Fixtures.offline.isWorldGone)
    }

    @Test("409 is an idempotency conflict")
    func idempotencyConflict() {
        #expect(APIError.server(409, "world_deleted").isIdempotencyConflict)
        #expect(!APIError.server(404, "world_not_found").isIdempotencyConflict)
        #expect(!APIError.quota.isIdempotencyConflict)
    }

    @Test("Quota and connectivity failures don't count toward parking")
    func parkingClassification() {
        #expect(!APIError.quota.countsTowardParking)
        #expect(!Fixtures.offline.countsTowardParking)
        #expect(!APIError.network(URLError(.timedOut)).countsTowardParking)
        #expect(!APIError.network(URLError(.networkConnectionLost)).countsTowardParking)

        #expect(APIError.server(500, "boom").countsTowardParking)
        #expect(APIError.server(404, "world_not_found").countsTowardParking)
        #expect(APIError.unauthorized.countsTowardParking)
        #expect(APIError.invalidResponse.countsTowardParking)
        // A non-URL error we can't prove is transient counts.
        #expect(APIError.network(URLError(.badURL)).countsTowardParking)
    }
}
