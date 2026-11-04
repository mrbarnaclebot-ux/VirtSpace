//
//  ExplorerLoadPhaseTests.swift
//  VirtSpaceTests
//
//  The Explorer's two-step loading arc: labels, bars that never run
//  backwards, and the process-death path.
//

import Foundation
import Testing
@testable import VirtSpace

@Suite("Explorer loading phase")
struct ExplorerLoadPhaseTests {
    @Test("download step reads bytes as whole MB")
    func downloadLabel() {
        let phase = ExplorerLoadPhase.start.applying(.downloadProgress(12_400_000, 40_000_000))
        #expect(phase.step == 1)
        #expect(phase.downloadLabel == "Downloading · 12 of 40 MB")
        #expect(phase.fraction == 0.31)
    }

    @Test("unknown size is indeterminate with a plain label")
    func unknownSize() {
        let phase = ExplorerLoadPhase.start.applying(.downloadProgress(5_000_000, -1))
        #expect(phase.downloadLabel == "Downloading")
        #expect(phase.fraction == nil)
    }

    @Test("small totals never read 0 MB")
    func smallFile() {
        #expect(ExplorerLoadPhase.megabytes(300_000, roundUp: true) == 1)
        #expect(ExplorerLoadPhase.megabytes(300_000, roundUp: false) == 0)
    }

    @Test("bars never move backwards")
    func monotonic() {
        let downloading = ExplorerLoadPhase.downloading(received: 20, expected: 40)
        #expect(downloading.applying(.downloadProgress(10, 40)) == .downloading(received: 20, expected: 40))
        #expect(ExplorerLoadPhase.opening(0.6).applying(.renderProgress(0.4)) == .opening(0.6))
    }

    @Test("download done starts step 2 with a fresh, indeterminate bar")
    func openingStep() {
        let phase = ExplorerLoadPhase.downloading(received: 40, expected: 40).applying(.downloaded)
        #expect(phase == .opening(0))
        #expect(phase.step == 2)
        #expect(phase.fraction == nil)
        #expect(phase.applying(.renderProgress(0.5)).fraction == 0.5)
    }

    @Test("render progress is ignored while still downloading")
    func renderBeforeDownload() {
        #expect(ExplorerLoadPhase.start.applying(.renderProgress(0.5)) == .start)
        #expect(ExplorerLoadPhase.start.applying(.loaded) == .start)
    }

    @Test("loaded finishes; nothing revives a failure")
    func terminalStates() {
        #expect(ExplorerLoadPhase.opening(0.9).applying(.loaded) == .ready)
        let failed = ExplorerLoadPhase.opening(0.2).applying(.failed("x"))
        #expect(failed == .failed(.load("x")))
        #expect(failed.applying(.loaded) == failed)
        #expect(failed.applying(.reloading) == failed)
        #expect(!failed.isLoading)
    }

    @Test("first process death reloads, second offers Reload")
    func processDeath() {
        let reloading = ExplorerLoadPhase.ready.applying(.reloading)
        #expect(reloading == .opening(0))
        #expect(reloading.isLoading)
        let closed = reloading.applying(.closedUnexpectedly)
        guard case .failed(let failure) = closed else {
            Issue.record("expected a failure")
            return
        }
        #expect(failure.title == "This space closed unexpectedly.")
        #expect(failure.message == nil)
        #expect(failure.buttonTitle == "Reload")
    }

    @Test("load failure copy")
    func loadFailureCopy() {
        let failure = ExplorerLoadPhase.Failure.load("You're offline. Check your connection and try again.")
        #expect(failure.title == "Couldn't open this space")
        #expect(failure.buttonTitle == "Try again")
    }

    @Test("download errors map to user copy, never raw text")
    func errorMap() {
        let offline = URLError(.notConnectedToInternet)
        #expect(ViewerErrorCopy.message(for: offline) == "You're offline. Check your connection and try again.")
        #expect(ViewerErrorCopy.message(for: SplatCacheError.badStatus(403)) == ViewerErrorCopy.generic)
    }
}

@Suite("Settings rows")
struct SettingsRowsTests {
    @Test("dev auth hides Delete account in every build")
    func devAuthHidesAccount() {
        #expect(!SettingsRows(isDebugBuild: false, isDevAuth: true).showsDeleteAccount)
        #expect(!SettingsRows(isDebugBuild: true, isDevAuth: true).showsDeleteAccount)
        #expect(SettingsRows(isDebugBuild: false, isDevAuth: false).showsDeleteAccount)
    }

    @Test("the user id lives in Developer, which Release never shows")
    func developerSection() {
        #expect(!SettingsRows(isDebugBuild: false, isDevAuth: true).showsDeveloper)
        #expect(SettingsRows(isDebugBuild: true, isDevAuth: true).showsDeveloper)
    }

    @Test("this build talks dev auth, so Account is hidden")
    func currentBuild() {
        #expect(SettingsRows.isDevAuth)
        #expect(!SettingsRows.current.showsDeleteAccount)
    }

    @Test("cache sizes: None when empty, Files-style otherwise")
    func sizeFormatting() {
        #expect(SettingsRows.formatBytes(0) == "None")
        #expect(SettingsRows.formatBytes(-1) == "None")
        #expect(SettingsRows.formatBytes(48_000_000) == ByteCountFormatter.string(fromByteCount: 48_000_000, countStyle: .file))
        #expect(SettingsRows.formatBytes(48_000_000).contains("48"))
    }
}
