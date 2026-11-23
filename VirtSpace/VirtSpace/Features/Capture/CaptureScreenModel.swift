//
//  CaptureScreenModel.swift
//  VirtSpace
//
//  Everything the scan screen decides, none of what it draws: reacting to
//  engine state, first-scan coaching, kicking app-scoped upload flows, and
//  keeping the screen awake for the capture + upload arc. The start screen's
//  gates (quota, camera access, banners) live in CaptureScreenModel+Start.
//  `CaptureView` and its subviews only lay this out.
//

import AVFoundation
import Foundation
import Observation
import UIKit

/// Spot scan (stand still, follow the dots → Marble) or room scan (walk
/// the room → Echo-3 reconstruction, spec §5.3).
enum ScanMode: String, Hashable {
    case spot, room
}

@MainActor
@Observable
final class CaptureScreenModel {
    /// Actions (start / cancel / reset / thermal resume). Views render `hud`.
    let engine: CaptureEngine
    var hud: CaptureHUDState { engine.hud }
    /// The room-scan capture; its HUD drives the screen while it is live.
    let roomEngine = RoomScanEngine()
    var roomHUD: RoomScanHUD { roomEngine.hud }
    var scanMode = ScanMode.spot
    /// Non-nil while a room scan uploads: the overlay's line.
    private(set) var roomUploadStage: RoomScanUploader.Stage? {
        didSet { updateScreenAwake() }
    }

    /// Non-nil while an upload is in flight (frames done so far): drives the
    /// full-screen upload overlay.
    private(set) var uploadedFrames: Int? {
        didSet { updateScreenAwake() }
    }
    /// Finished sessions stranded on disk after a failed upload, and how many
    /// have exhausted their automatic retries (parked, spec §10 R4) and so need
    /// an explicit Try again / Delete from the user.
    private(set) var pendingUpload = PendingUploadSummary()
    /// Banner copy after an upload or a manual retry failed, with the cause.
    /// Cleared when an upload succeeds or the scan is deleted.
    var uploadFailureMessage: String?
    /// Scans left in today's window, from GET /v1/me/quota. nil = unknown (not
    /// yet fetched, or the check failed, in which case we fail open and let
    /// capture proceed). 0 = daily limit reached; capture is blocked up front.
    var scansRemaining: Int?
    /// When today's quota window frees up (only meaningful once exhausted).
    var quotaResetsAt: Date?
    /// Camera permission as last read (simulator: always authorized).
    var cameraAccess = CameraAccess.current
    /// The just-in-time camera explanation sheet (ui-spec 5.6).
    var showsCameraPriming = false
    /// First-scan coaching for the scan in progress (ui-spec 5.7).
    private(set) var coach = FirstScanCoach()
    /// Bumped when the server confirmed an upload: the view's success haptic.
    private(set) var uploadSuccessCount = 0

    @ObservationIgnored let api: APIClient
    @ObservationIgnored let toasts: ToastCenter
    @ObservationIgnored let defaults: UserDefaults
    /// App-scoped store and router, injected by CaptureView from the
    /// environment (the model is built before the environment exists).
    @ObservationIgnored var worldStore: WorldStore?
    @ObservationIgnored var router: AppRouter?
    @ObservationIgnored private var didResumePending = false
    @ObservationIgnored private var tipTask: Task<Void, Never>?

    init(api: APIClient, toasts: ToastCenter, defaults: UserDefaults = .standard) {
        self.api = api
        self.toasts = toasts
        self.defaults = defaults
        // Orphan-world prevention: abandoning a scan whose session already
        // minted a backend world (confirm-abandon in the HUD, thermal-overlay
        // abandon: both land in engine.cancel()) best-effort deletes that
        // world server-side before the local purge. The worker's 24 h
        // uploading reaper is the backstop when this can't land (offline).
        engine = CaptureEngine(onSessionDiscarded: { worldId in
            Task { @MainActor in try? await api.deleteWorld(id: worldId) }
        })
    }

    // MARK: - Engine state

    func engineStateChanged(to state: CaptureEngineState) {
        if case .finished(let result) = state {
            if coach.isActive { defaults.set(true, forKey: FirstScanCoach.defaultsKey) }
            Task { await upload(result) }
        }
        updateScreenAwake()
    }

    /// Start the engine with coaching set up for this scan.
    func startEngine() {
        if scanMode == .room {
            Task { await roomEngine.start(maxFrames: RoomScanUploader.maxFrames) }
            return
        }
        coach.begin(firstScan: !defaults.bool(forKey: FirstScanCoach.defaultsKey))
        engine.start()
    }

    // MARK: - Room scan

    #if DEBUG && targetEnvironment(simulator)
    /// Simulator-only autopilot (no tap automation under Xcode 27):
    /// `VIRTSPACE_DEBUG_ROOM_SCAN_SECONDS=N` starts one room scan at launch
    /// and taps Finish after N seconds. Pair with `VIRTSPACE_API_BASE_URL`.
    static let debugRoomScanSeconds = ProcessInfo.processInfo.environment["VIRTSPACE_DEBUG_ROOM_SCAN_SECONDS"].flatMap(Double.init)
    private static var debugRoomScanStarted = false

    func debugAutoRoomScan() async {
        guard let seconds = Self.debugRoomScanSeconds, !Self.debugRoomScanStarted else { return }
        Self.debugRoomScanStarted = true
        scanMode = .room
        startEngine()
        try? await Task.sleep(for: .seconds(seconds))
        roomEngine.finish()
    }
    #endif

    func roomStateChanged(to state: RoomScanHUD.State) {
        switch state {
        case .finished(let id):
            Task { await uploadRoomScan(id) }
        case .failed(let message):
            toasts.show(message, style: .error)
            roomEngine.reset()
        default:
            break
        }
        updateScreenAwake()
    }

    private func uploadRoomScan(_ id: UUID) async {
        roomUploadStage = .preparing
        defer { roomUploadStage = nil }
        let handle = UploadManager.shared.kickRoomScanUpload(sessionID: id, api: api) { [weak self] stage in
            self?.roomUploadStage = stage
        }
        let outcome = await handle.value
        roomEngine.reset()
        await refreshPendingUpload()
        switch outcome {
        case .success(let world?):
            routeToNewSpace(world)
        case .success(nil):
            uploadFailureMessage = nil
            router?.selectedTab = .library
            await worldStore?.refresh()
        case .failure(let error):
            uploadFailureMessage = "Upload didn't finish. Your scan is saved on this phone. " + Self.cause(of: error)
        }
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
            Self.keepsScreenAwake(state: hud.state, isUploading: uploadedFrames != nil || roomUploadStage != nil)
            || roomHUD.isLive
    }

    /// Belt-and-braces: always hand the screen back when the view goes away.
    func screenDisappeared() {
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - First-scan coaching

    func capturedCountChanged(to count: Int) {
        let before = coach.tip
        coach.shotsChanged(captured: count, total: hud.targets.count)
        expireTipLater(ifChangedFrom: before)
    }

    func driftChanged(pastSoftGate: Bool) {
        let before = coach.tip
        coach.driftChanged(pastSoftGate: pastSoftGate)
        expireTipLater(ifChangedFrom: before)
    }

    func dismissCoachTip(_ tip: FirstScanCoach.Tip) {
        coach.dismiss(tip)
    }

    /// Timed tips (the banners) clear themselves after `tipDuration`.
    private func expireTipLater(ifChangedFrom before: FirstScanCoach.Tip?) {
        guard let tip = coach.tip, tip != before, tip.bannerText != nil else { return }
        tipTask?.cancel()
        tipTask = Task { [weak self] in
            try? await Task.sleep(for: FirstScanCoach.tipDuration)
            guard !Task.isCancelled else { return }
            self?.coach.dismiss(tip)
        }
    }

    // MARK: - Uploading

    private func upload(_ result: CaptureResult) async {
        uploadedFrames = 0
        defer {
            uploadedFrames = nil
            coach.dismiss(.finished)
        }
        // App-scoped flow (UploadManager owns the task): navigating tabs or
        // dismissing the view can no longer cancel the upload; awaiting the
        // handle below is UI-only, the flow survives the screen.
        let handle = UploadManager.shared.kickUpload(result: result, api: api) { [weak self] done in
            Task { @MainActor in self?.uploadedFrames = done }
        }
        let outcome = await handle.value
        engine.reset()
        await refreshPendingUpload()
        switch outcome {
        case .success(let world):
            routeToNewSpace(world)
        case .failure(let error):
            uploadFailureMessage = "Upload didn't finish. Your scan is saved on this phone. " + Self.cause(of: error)
        }
    }

    /// Manual retry of a stranded session (app-scoped via UploadManager). A
    /// user-initiated retry clears the attempt counter, so a parked session
    /// gets a full fresh automatic budget again. "Nothing to do" and
    /// "already uploading" get no toast: the banner shows the state.
    func retryPendingUpload() async {
        uploadedFrames = 0
        defer { uploadedFrames = nil }
        let handle = UploadManager.shared.kickResume(api: api, userInitiated: true) { [weak self] done in
            Task { @MainActor in self?.uploadedFrames = done }
        }
        let outcome = await handle.value
        await refreshPendingUpload()
        switch outcome {
        case .succeeded(let worlds):
            worlds.dropFirst().forEach { worldStore?.insert($0) }
            if let first = worlds.first {
                routeToNewSpace(first)
            } else {
                // A stranded session finished by frames:done: no world copy.
                uploadFailureMessage = nil
                uploadSuccessCount += 1
                router?.selectedTab = .library
                await worldStore?.refresh()
            }
        case .failed(let reason):
            uploadFailureMessage = "Still couldn't upload. \(reason)"
        case .nothingToResume, .deferred:
            break
        }
    }

    /// Give up on the parked session(s) at the user's request.
    func discardPendingUpload() async {
        let discarded = await UploadManager.shared.kickDiscardPending(api: api).value
        await refreshPendingUpload()
        if discarded > 0 {
            uploadFailureMessage = nil
            toasts.show("Scan deleted.", style: .success)
        }
    }

    /// Retry any capture sessions stranded on disk by a crash or failed upload,
    /// once per screen. The flow itself is app-scoped; this await is UI-only.
    /// No toast: the new card simply appears in the Library.
    func resumePendingOnce() async {
        // A hosted test run launches this app; resuming would upload for real.
        guard !TestEnvironment.isRunningUnderXCTest, !didResumePending else { return }
        didResumePending = true
        let outcome = await UploadManager.shared.kickResume(api: api).value
        await refreshPendingUpload()
        if case .succeeded(let worlds) = outcome {
            worlds.forEach { worldStore?.insert($0) }
        }
    }

    /// The server confirmed an upload: show the space in the Library and open
    /// its Detail, where it builds (ui-spec 3). No toast: Detail says it.
    func routeToNewSpace(_ world: World) {
        uploadFailureMessage = nil
        uploadSuccessCount += 1
        worldStore?.insert(world)
        router?.open(worldId: world.id)
    }

    func refreshPendingUpload() async {
        pendingUpload = await UploadManager.shared.pendingSummary(api: api)
    }

    /// User copy for why an upload failed (ui-spec 6 Errors). Never raw text:
    /// anything that isn't a typed APIError or a URL error gets the generic line.
    static func cause(of error: Error) -> String {
        let apiError: APIError
        if let typed = error as? APIError {
            apiError = typed
        } else if (error as NSError).domain == NSURLErrorDomain {
            apiError = .network(error)
        } else {
            apiError = .invalidResponse
        }
        return apiError.userMessage(includeDeveloperHints: false)
    }
}
