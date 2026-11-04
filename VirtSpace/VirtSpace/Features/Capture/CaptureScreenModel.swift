//
//  CaptureScreenModel.swift
//  VirtSpace
//
//  Everything the capture screen decides, none of what it draws: reacting to
//  engine state, kicking app-scoped upload flows, the daily-quota gate, the
//  pending/parked-upload affordances, and keeping the screen awake for the
//  capture + upload arc. `CaptureView` and its subviews only lay this out.
//

import AVFoundation
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class CaptureScreenModel {
    /// Actions (start / cancel / reset / thermal resume). Views render `hud`.
    let engine: CaptureEngine
    var hud: CaptureHUDState { engine.hud }

    var toast: Toast?
    /// Non-nil while an upload is in flight (frames done so far) — drives the
    /// full-screen upload overlay.
    private(set) var uploadedFrames: Int? {
        didSet { updateScreenAwake() }
    }
    /// Finished sessions stranded on disk after a failed upload, and how many
    /// have exhausted their automatic retries (parked, spec §10 R4) and so need
    /// an explicit Retry / Discard from the user.
    private(set) var pendingUpload = PendingUploadSummary()
    /// Scans left in today's window, from GET /v1/me/quota. nil = unknown (not
    /// yet fetched, or the check failed — in which case we fail open and let
    /// capture proceed). 0 = daily limit reached; capture is blocked up front.
    private(set) var scansRemaining: Int?
    /// When today's quota window frees up (only meaningful once exhausted).
    private(set) var quotaResetsAt: Date?

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored let switchToLibrary: () -> Void
    @ObservationIgnored private var didResumePending = false

    init(api: APIClient, switchToLibrary: @escaping () -> Void = {}) {
        self.api = api
        self.switchToLibrary = switchToLibrary
        // Orphan-world prevention: abandoning a scan whose session already
        // minted a backend world (confirm-abandon in the HUD, thermal-overlay
        // abandon — both land in engine.cancel()) best-effort deletes that
        // world server-side before the local purge. The worker's 24 h
        // uploading reaper is the backstop when this can't land (offline).
        engine = CaptureEngine(onSessionDiscarded: { worldId in
            Task { @MainActor in try? await api.deleteWorld(id: worldId) }
        })
    }

    // MARK: - Engine state

    func engineStateChanged(to state: CaptureEngineState) {
        if case .finished(let result) = state {
            Task { await upload(result) }
        }
        updateScreenAwake()
    }

    /// Keep the screen awake for the full capture + upload arc (belt-and-braces
    /// with the background session, which handles the app being suspended).
    static func keepsScreenAwake(state: CaptureEngineState, isUploading: Bool) -> Bool {
        if isUploading { return true }
        switch state {
        case .idle, .failed: return false
        default: return true // starting / ready / capturing / advancing / finished
        }
    }

    private func updateScreenAwake() {
        UIApplication.shared.isIdleTimerDisabled =
            Self.keepsScreenAwake(state: hud.state, isUploading: uploadedFrames != nil)
    }

    /// Belt-and-braces: always hand the screen back when the view goes away.
    func screenDisappeared() {
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Quota

    /// True once we know the daily scan limit is spent (0 remaining). nil/unknown
    /// (quota not fetched or the check failed) is NOT exhausted — we fail open.
    var isQuotaExhausted: Bool { scansRemaining == 0 }

    /// Subtle heads-up as the day's allowance runs low; nil when unknown or
    /// exhausted (the full-width notice covers that case).
    var lowQuotaHint: String? {
        guard !isQuotaExhausted, let left = scansRemaining, left < 5 else { return nil }
        return "\(left) scan\(left == 1 ? "" : "s") left today"
    }

    /// " — resets in about 5 hours" when a reset time is known; empty otherwise.
    var quotaResetLabel: String {
        guard let resetsAt = quotaResetsAt else { return "" }
        return " — resets \(resetsAt.formatted(.relative(presentation: .named)))"
    }

    /// nil (a failed check) deliberately clears to "unknown" rather than
    /// blocking: capture is offline-safe (frames persist, upload retries), so
    /// a flaky quota check must never stop someone from capturing.
    func applyQuota(_ quota: QuotaStatus?) {
        scansRemaining = quota?.scansRemaining
        quotaResetsAt = quota?.quotaResetsAt
    }

    private func refreshQuota() async {
        // No backend calls from a hosted test run (TestEnvironment).
        guard !TestEnvironment.isRunningUnderXCTest else { return }
        applyQuota(try? await api.quota())
    }

    /// Refresh the allowance and pending uploads each time the start screen
    /// appears, so its hints are current before a capture.
    func startScreenAppeared() async {
        await refreshPendingUpload()
        await refreshQuota()
    }

    // MARK: - Starting a capture

    func startCapture() async {
        // Check quota BEFORE starting the engine. A real device test had a user
        // shoot a full 28-shot session only to be rejected with 429 at
        // POST /v1/worlds; enforcing up front means they learn the limit first.
        await refreshQuota()
        guard !isQuotaExhausted else { return }

        #if targetEnvironment(simulator)
        engine.start()
        #else
        // Never crash on a missing usage string: the OS kills the app on
        // camera access without NSCameraUsageDescription in the Info.plist.
        guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil else {
            toast = Toast(message: "Camera permission text is missing from the build — capture is disabled.", style: .error)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            engine.start()
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .video) {
                engine.start()
            } else {
                toast = Toast(message: "Camera access is needed to capture your space.", style: .error)
            }
        default:
            toast = Toast(message: "Camera access is denied. Enable it in Settings → VirtSpace.", style: .error)
        }
        #endif
    }

    // MARK: - Uploading

    private func upload(_ result: CaptureResult) async {
        uploadedFrames = 0
        defer { uploadedFrames = nil }
        // App-scoped flow (UploadManager owns the task): navigating tabs or
        // dismissing the view can no longer cancel the upload — awaiting the
        // handle below is UI-only, the flow survives the screen.
        let handle = UploadManager.shared.kickUpload(result: result, api: api) { [weak self] done in
            Task { @MainActor in self?.uploadedFrames = done }
        }
        let outcome = await handle.value
        engine.reset()
        await refreshPendingUpload()
        switch outcome {
        case .success:
            await announceUploadedAndSwitch()
        case .failure(let error):
            toast = Toast(message: "Upload failed — your scan is saved. Retry from here or relaunch. (\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))", style: .error)
        }
    }

    /// Manual retry of a stranded session (app-scoped via UploadManager). A
    /// user-initiated retry clears the attempt counter, so a parked session
    /// gets a full fresh automatic budget again.
    func retryPendingUpload() async {
        uploadedFrames = 0
        defer { uploadedFrames = nil }
        let handle = UploadManager.shared.kickResume(api: api, userInitiated: true) { [weak self] done in
            Task { @MainActor in self?.uploadedFrames = done }
        }
        let outcome = await handle.value
        await refreshPendingUpload()
        switch outcome {
        case .succeeded:
            await announceUploadedAndSwitch()
        case .nothingToResume:
            toast = Toast(message: "Nothing left to upload.", style: .success)
        case .failed(let reason):
            // Report what ACTUALLY went wrong — resumePending used to swallow
            // every error, so this always read "check your connection".
            toast = Toast(message: "Upload failed again — \(reason)", style: .error)
        case .deferred(let reason):
            toast = Toast(message: "Upload not retried — \(reason).", style: .error)
        }
    }

    /// Give up on the parked session(s) at the user's request.
    func discardPendingUpload() async {
        let discarded = await UploadManager.shared.kickDiscardPending(api: api).value
        await refreshPendingUpload()
        if discarded > 0 {
            toast = Toast(message: "Scan discarded.", style: .success)
        }
    }

    /// Retry any capture sessions stranded on disk by a crash or failed upload,
    /// once per screen. The flow itself is app-scoped; this await is UI-only.
    func resumePendingOnce() async {
        // A hosted test run launches this app; resuming would upload for real.
        guard !TestEnvironment.isRunningUnderXCTest, !didResumePending else { return }
        didResumePending = true
        let outcome = await UploadManager.shared.kickResume(api: api).value
        await refreshPendingUpload()
        if case .succeeded(let worlds) = outcome, !worlds.isEmpty {
            toast = Toast(message: "Resumed \(worlds.count) pending scan upload\(worlds.count == 1 ? "" : "s").", style: .success)
        }
    }

    /// Shared tail of a successful upload: confirm, let the toast land, then
    /// route to the Library where the world builds.
    func announceUploadedAndSwitch(_ message: String = "Scan uploaded — watch it build in Library.") async {
        toast = Toast(message: message, style: .success)
        try? await Task.sleep(for: .milliseconds(700))
        switchToLibrary()
    }

    private func refreshPendingUpload() async {
        pendingUpload = await UploadManager.shared.pendingSummary(api: api)
    }
}
