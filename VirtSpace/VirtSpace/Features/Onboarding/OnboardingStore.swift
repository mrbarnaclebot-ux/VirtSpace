//
//  OnboardingStore.swift
//  VirtSpace
//
//  Versioned terms consent (ui-spec 5, spec-doc R32). Onboarding shows while
//  the stored terms version is below `currentTermsVersion`:
//    - nothing stored (fresh install): the full flow, welcome to terms;
//    - an older version stored (terms changed): the terms page only;
//    - current version stored: never.
//  Bump `currentTermsVersion` whenever the terms text changes in substance.
//
//  `UploadManager` reads `hasCurrentConsent(defaults:)` directly, so the
//  upload guard does not depend on any view being alive.
//

import Foundation
import Observation

@Observable
final class OnboardingStore {
    /// Bump when the terms change; every user then agrees again.
    static let currentTermsVersion = 1

    enum Key {
        static let termsVersion = "onboarding.termsVersion"
        static let termsAcceptedAt = "onboarding.termsAcceptedAt"
    }

    enum Gate: Equatable {
        /// Consent is current: no onboarding.
        case none
        /// Never agreed: welcome, how to scan, then terms.
        case full
        /// Agreed to an older version: the terms page only.
        case termsOnly
    }

    @ObservationIgnored private let defaults: UserDefaults
    let currentVersion: Int
    private(set) var acceptedVersion: Int
    private(set) var acceptedAt: Date?

    init(defaults: UserDefaults = .standard, currentVersion: Int = OnboardingStore.currentTermsVersion) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        acceptedVersion = defaults.integer(forKey: Key.termsVersion)
        acceptedAt = defaults.object(forKey: Key.termsAcceptedAt) as? Date
    }

    var hasCurrentConsent: Bool { acceptedVersion >= currentVersion }

    var gate: Gate {
        if hasCurrentConsent { return .none }
        return acceptedVersion == 0 ? .full : .termsOnly
    }

    /// "Agree and continue": record the version and date.
    func accept(at date: Date = .now) {
        defaults.set(currentVersion, forKey: Key.termsVersion)
        defaults.set(date, forKey: Key.termsAcceptedAt)
        acceptedVersion = currentVersion
        acceptedAt = date
    }

    /// Settings "Replay onboarding" (Developer section): forget consent so the
    /// full flow shows again. Uploads stay blocked until the user agrees again.
    func replay() {
        defaults.removeObject(forKey: Key.termsVersion)
        defaults.removeObject(forKey: Key.termsAcceptedAt)
        acceptedVersion = 0
        acceptedAt = nil
    }

    /// The upload guard's check, readable without a store instance.
    static func hasCurrentConsent(
        defaults: UserDefaults = .standard,
        currentVersion: Int = OnboardingStore.currentTermsVersion
    ) -> Bool {
        defaults.integer(forKey: Key.termsVersion) >= currentVersion
    }
}
