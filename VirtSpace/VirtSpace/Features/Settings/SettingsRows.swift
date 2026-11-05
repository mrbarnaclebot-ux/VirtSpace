//
//  SettingsRows.swift
//  VirtSpace
//
//  Pure Settings logic (ui-spec 8): which sections show, and how download
//  sizes read.
//

import Foundation

struct SettingsRows: Equatable {
    /// User id, fixture photo, debug logs, onboarding resets. DEBUG builds only.
    let showsDeveloper: Bool
    /// Delete account. Hidden under dev auth (R24): there every install
    /// shares ONE library, so deleting "your" account wipes everyone's.
    let showsDeleteAccount: Bool

    init(isDebugBuild: Bool, isDevAuth: Bool) {
        showsDeveloper = isDebugBuild
        showsDeleteAccount = !isDevAuth
    }

    static var current: SettingsRows {
        #if DEBUG
        SettingsRows(isDebugBuild: true, isDevAuth: isDevAuth)
        #else
        SettingsRows(isDebugBuild: false, isDevAuth: isDevAuth)
        #endif
    }

    /// The client has no runtime auth mode: every request carries the
    /// compiled-in `Secrets.devAuthToken` (APIClient.request). So "dev auth"
    /// is exactly "that token is set". Real sign-in will replace this.
    static var isDevAuth: Bool { !Secrets.devAuthToken.isEmpty }

    /// "None" for an empty cache, else a Files-style size ("48 MB").
    static func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "None" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Settings reset for one-time coaching. Onboarding's pages and its replay
/// come straight from WP3 (`HowToScanView`, `TermsView`, `TermsOfUseView`,
/// `OnboardingStore.replay()`).
enum SettingsOnboardingLinks {
    /// WP4's first-scan coaching flag (ui-spec 5.7), plus the Explorer's own
    /// one-time coach.
    static func resetFirstScanCoaching() {
        UserDefaults.standard.removeObject(forKey: FirstScanCoach.defaultsKey)
        UserDefaults.standard.removeObject(forKey: ExplorerView.coachKey)
    }
}
