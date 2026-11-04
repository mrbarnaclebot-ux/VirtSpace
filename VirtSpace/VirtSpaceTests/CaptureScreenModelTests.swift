//
//  CaptureScreenModelTests.swift
//  VirtSpaceTests
//
//  The capture screen's decisions, without a view (spec §10 R19). Nothing here
//  starts the engine or kicks an upload flow: under XCTest the model's quota
//  and resume calls are inert (TestEnvironment), and every path exercised
//  below returns before touching the camera, the disk or the network.
//

import Foundation
import Testing
@testable import VirtSpace

@Suite("CaptureScreenModel")
struct CaptureScreenModelTests {
    private func quota(remaining: Int, resetsAt: Date? = nil) throws -> QuotaStatus {
        var json: [String: Any] = ["scans_remaining": remaining, "daily_quota": 5]
        if let resetsAt { json["quota_resets_at"] = resetsAt.timeIntervalSinceReferenceDate }
        return try JSONDecoder().decode(QuotaStatus.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test("Screen stays awake through capture and upload, not at rest")
    func screenAwakePolicy() {
        let result = CaptureResult(sessionID: UUID(), directory: URL(filePath: "/tmp"), frameCount: 28)
        let awake: [CaptureEngineState] = [
            .starting, .ready(targetIndex: 0), .capturing(targetIndex: 3), .advancing, .finished(result),
        ]
        for state in awake {
            #expect(CaptureScreenModel.keepsScreenAwake(state: state, isUploading: false), "\(state)")
        }
        #expect(!CaptureScreenModel.keepsScreenAwake(state: .idle, isUploading: false))
        #expect(!CaptureScreenModel.keepsScreenAwake(state: .failed("x"), isUploading: false))
        // The upload overlay outlives the engine's reset to idle.
        #expect(CaptureScreenModel.keepsScreenAwake(state: .idle, isUploading: true))
    }

    @Test("An exhausted quota blocks capture before the engine starts")
    func exhaustedQuotaBlocksStart() async throws {
        let model = CaptureScreenModel(api: APIClient())
        model.applyQuota(try quota(remaining: 0, resetsAt: Date().addingTimeInterval(3_600)))

        #expect(model.isQuotaExhausted)
        #expect(model.lowQuotaHint == nil)
        #expect(model.quotaResetLabel.hasPrefix(" — resets "))

        await model.startCapture()
        // `start()` flips to .starting synchronously, so this would catch it.
        #expect(model.hud.state == .idle)
    }

    @Test("A failed quota check fails open")
    func unknownQuotaFailsOpen() throws {
        let model = CaptureScreenModel(api: APIClient())
        model.applyQuota(try quota(remaining: 0))
        model.applyQuota(nil)

        #expect(model.scansRemaining == nil)
        #expect(!model.isQuotaExhausted)
        #expect(model.lowQuotaHint == nil)
        #expect(model.quotaResetLabel.isEmpty)
    }

    @Test("Low-allowance hint below five scans only")
    func lowQuotaHint() throws {
        let model = CaptureScreenModel(api: APIClient())
        model.applyQuota(try quota(remaining: 1))
        #expect(model.lowQuotaHint == "1 scan left today")
        model.applyQuota(try quota(remaining: 4))
        #expect(model.lowQuotaHint == "4 scans left today")
        model.applyQuota(try quota(remaining: 5))
        #expect(model.lowQuotaHint == nil)
    }
}
