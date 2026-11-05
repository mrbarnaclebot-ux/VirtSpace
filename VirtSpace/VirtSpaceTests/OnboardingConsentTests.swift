//
//  OnboardingConsentTests.swift
//  VirtSpaceTests
//
//  ui-spec 5 / spec-doc R32: versioned terms consent and the upload guard.
//  Every store uses a throwaway UserDefaults suite, never `.standard`. The
//  guard tests only exercise the refusal path, so nothing reaches the network
//  or the capture directory.
//

import Foundation
import Testing
@testable import VirtSpace

@MainActor
@Suite("Onboarding consent")
struct OnboardingConsentTests {
    private let defaults: UserDefaults

    init() {
        let suite = "virtspace-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("A fresh install shows the full onboarding and has no consent")
    func freshInstall() {
        let store = OnboardingStore(defaults: defaults, currentVersion: 1)
        #expect(store.gate == .full)
        #expect(!store.hasCurrentConsent)
        #expect(!OnboardingStore.hasCurrentConsent(defaults: defaults, currentVersion: 1))
    }

    @Test("Agreeing records the version and date, and a relaunch sees no onboarding")
    func returningUser() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        OnboardingStore(defaults: defaults, currentVersion: 1).accept(at: date)

        let relaunched = OnboardingStore(defaults: defaults, currentVersion: 1)
        #expect(relaunched.gate == .none)
        #expect(relaunched.acceptedVersion == 1)
        #expect(relaunched.acceptedAt == date)
        #expect(OnboardingStore.hasCurrentConsent(defaults: defaults, currentVersion: 1))
    }

    @Test("Bumping the terms version shows only the terms page")
    func bumpedVersion() {
        OnboardingStore(defaults: defaults, currentVersion: 1).accept()

        let bumped = OnboardingStore(defaults: defaults, currentVersion: 2)
        #expect(bumped.gate == .termsOnly)
        #expect(!OnboardingStore.hasCurrentConsent(defaults: defaults, currentVersion: 2))

        bumped.accept()
        #expect(bumped.gate == .none)
        #expect(OnboardingStore(defaults: defaults, currentVersion: 2).gate == .none)
    }

    @Test("Replay forgets consent and shows the full flow again")
    func replay() {
        let store = OnboardingStore(defaults: defaults, currentVersion: 1)
        store.accept()
        store.replay()
        #expect(store.gate == .full)
        #expect(store.acceptedAt == nil)
        #expect(OnboardingStore(defaults: defaults, currentVersion: 1).gate == .full)
    }

    // MARK: - UploadManager consent guard

    private func blockedManager() -> UploadManager {
        let defaults = defaults
        return UploadManager(hasConsent: { OnboardingStore.hasCurrentConsent(defaults: defaults, currentVersion: 1) })
    }

    @Test("No upload starts without current consent")
    func uploadRefused() async {
        let result = CaptureResult(
            sessionID: UUID(),
            directory: FileManager.default.temporaryDirectory,
            frameCount: 28
        )
        var progressCalls = 0
        let outcome = await blockedManager()
            .kickUpload(result: result, api: APIClient()) { _ in progressCalls += 1 }
            .value

        guard case .failure(let error) = outcome, case .localState(let message) = error as? APIError else {
            Issue.record("expected the consent refusal, got \(outcome)")
            return
        }
        #expect(message == UploadManager.consentMissingMessage)
        #expect(progressCalls == 0)
    }

    @Test("Resume and stranded recovery do nothing without current consent")
    func resumeRefused() async {
        let manager = blockedManager()
        let resume = await manager.kickResume(api: APIClient(), userInitiated: true).value
        guard case .deferred = resume else {
            Issue.record("expected a deferred resume, got \(resume)")
            return
        }
        #expect(await manager.kickStrandedRecovery(api: APIClient()).value == 0)
    }

    @Test("A stale consent (older terms version) also blocks uploads")
    func staleConsentBlocks() async {
        OnboardingStore(defaults: defaults, currentVersion: 1).accept()
        let defaults = defaults
        let manager = UploadManager(hasConsent: { OnboardingStore.hasCurrentConsent(defaults: defaults, currentVersion: 2) })
        #expect(await manager.kickStrandedRecovery(api: APIClient()).value == 0)
        let resume = await manager.kickResume(api: APIClient()).value
        #expect(resume == .deferred(reason: "the terms of use are not accepted yet"))
    }
}
