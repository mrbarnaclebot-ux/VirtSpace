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

/// Settings entry points owned by onboarding (WP3). PLACEHOLDERS until merge:
/// the orchestrator points these at WP3's views and store.
enum SettingsOnboardingLinks {
    /// WIRE AT MERGE: onboarding pages 2-4 ("How to scan").
    static func howToScan() -> SettingsPlaceholderPage {
        SettingsPlaceholderPage(title: "How to scan")
    }

    /// WIRE AT MERGE: onboarding page 5, read-only once accepted.
    static func termsOfUse() -> SettingsPlaceholderPage {
        SettingsPlaceholderPage(title: "Terms of use")
    }

    /// WIRE AT MERGE: reset consent so onboarding shows again. Until then it
    /// clears the ui-spec 5 keys, read on the next launch.
    static func replayOnboarding() {
        UserDefaults.standard.removeObject(forKey: "onboarding.termsVersion")
        UserDefaults.standard.removeObject(forKey: "onboarding.termsAcceptedAt")
    }

    /// WIRE AT MERGE: WP4's first-scan coaching flag (ui-spec 5.7), plus the
    /// Explorer's own one-time coach.
    static func resetFirstScanCoaching() {
        UserDefaults.standard.removeObject(forKey: "onboarding.firstScanCoached")
        UserDefaults.standard.removeObject(forKey: ExplorerView.coachKey)
    }
}
