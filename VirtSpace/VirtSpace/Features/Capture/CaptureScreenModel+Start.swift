//
//  CaptureScreenModel+Start.swift
//  VirtSpace
//
//  The scan start screen's gates (ui-spec 4.2, 5.6): daily quota, camera
//  permission with just-in-time priming, the Start button's label, and the
//  banner slot. The pure rules (`StartButtonState.make`, `StartBanner.list`)
//  are static so they can be tested without a camera or a backend.
//

import AVFoundation
import Foundation

/// Camera permission, reduced to what the start screen distinguishes.
enum CameraAccess: Equatable {
    case notDetermined, authorized, denied, restricted

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        default: self = .denied
        }
    }

    /// The live status. The simulator has no camera prompt to show.
    static var current: CameraAccess {
        #if targetEnvironment(simulator)
        .authorized
        #else
        CameraAccess(AVCaptureDevice.authorizationStatus(for: .video))
        #endif
    }
}

/// The primary button's label and whether it can be tapped.
struct StartButtonState: Equatable {
    let title: String
    let isEnabled: Bool

    static func make(quotaExhausted: Bool, camera: CameraAccess, lastScanFailed: Bool) -> StartButtonState {
        if quotaExhausted { return StartButtonState(title: "Scan unavailable today", isEnabled: false) }
        let title = lastScanFailed ? "Scan again" : "Start scan"
        // Denied / restricted: the banner explains and offers Open Settings.
        let cameraUsable = camera == .authorized || camera == .notDetermined
        return StartButtonState(title: title, isEnabled: cameraUsable)
    }
}

/// One ongoing condition shown in the start screen's banner slot (ui-spec 7.2:
/// banners for conditions, toasts for one-off outcomes).
enum StartBanner: Equatable, Identifiable {
    case cameraDenied
    case cameraRestricted
    /// Full copy, cause included. Actions: Try again.
    case uploadFailed(String)
    /// Actions: Try again, Delete scan.
    case parked
    /// Retrying automatically. Action: Upload now.
    case waiting(count: Int)
    case quotaReached(resetAt: Date?)
    /// The last scan stopped with an engine error.
    case scanFailed

    var id: String {
        switch self {
        case .cameraDenied: "camera"
        case .cameraRestricted: "camera-restricted"
        case .uploadFailed: "upload-failed"
        case .parked: "parked"
        case .waiting: "waiting"
        case .quotaReached: "quota"
        case .scanFailed: "scan-failed"
        }
    }

    var message: String {
        switch self {
        case .cameraDenied:
            "VirtSpace needs camera access to scan."
        case .cameraRestricted:
            "Camera access is restricted on this iPhone."
        case .uploadFailed(let message):
            message
        case .parked:
            "This scan couldn't upload. It's saved on this phone."
        case .waiting(let count):
            "\(count) scan\(count == 1 ? "" : "s") waiting to upload. It will retry when you're online."
        case .quotaReached(let resetAt):
            APIError.scanQuota(resetAt: resetAt).userMessage(includeDeveloperHints: false)
        case .scanFailed:
            "Something went wrong starting the scan. Try again."
        }
    }

    var tone: Tone {
        switch self {
        case .cameraDenied, .cameraRestricted, .uploadFailed, .parked, .scanFailed: .warning
        case .waiting, .quotaReached: .neutral
        }
    }

    var systemImage: String {
        switch self {
        case .cameraDenied, .cameraRestricted: "camera.fill"
        case .uploadFailed, .parked: "exclamationmark.icloud"
        case .waiting: "icloud.and.arrow.up"
        case .quotaReached: "clock"
        case .scanFailed: "exclamationmark.triangle"
        }
    }

    /// Ordered, most actionable first. A failed upload's banner needs the
    /// session to still be pending (otherwise there is nothing to retry);
    /// parked beats it, and both replace the plain "waiting" line.
    static func list(
        camera: CameraAccess,
        quotaExhausted: Bool,
        quotaResetsAt: Date?,
        uploadFailure: String?,
        pending: PendingUploadSummary,
        scanFailed: Bool
    ) -> [StartBanner] {
        var banners: [StartBanner] = []
        if camera == .denied { banners.append(.cameraDenied) }
        if camera == .restricted { banners.append(.cameraRestricted) }
        if pending.hasParked {
            banners.append(.parked)
        } else if let uploadFailure, pending.hasPending {
            banners.append(.uploadFailed(uploadFailure))
        } else if pending.hasPending {
            banners.append(.waiting(count: pending.pendingCount))
        }
        if quotaExhausted { banners.append(.quotaReached(resetAt: quotaResetsAt)) }
        if scanFailed { banners.append(.scanFailed) }
        return banners
    }
}

extension CaptureScreenModel {
    // MARK: - Derived start-screen state

    var lastScanFailed: Bool {
        if case .failed = hud.state { return true }
        return false
    }

    var startButton: StartButtonState {
        StartButtonState.make(quotaExhausted: isQuotaExhausted, camera: cameraAccess, lastScanFailed: lastScanFailed)
    }

    var banners: [StartBanner] {
        StartBanner.list(
            camera: cameraAccess,
            quotaExhausted: isQuotaExhausted,
            quotaResetsAt: quotaResetsAt,
            uploadFailure: uploadFailureMessage,
            pending: pendingUpload,
            scanFailed: lastScanFailed
        )
    }

    // MARK: - Quota

    /// True once we know the daily scan limit is spent (0 remaining). nil/unknown
    /// (quota not fetched or the check failed) is NOT exhausted: we fail open.
    var isQuotaExhausted: Bool { scansRemaining == 0 }

    /// Subtle heads-up as the day's allowance runs low; nil when unknown or
    /// exhausted (the banner covers that case).
    var lowQuotaHint: String? {
        guard !isQuotaExhausted, let left = scansRemaining, left < 5 else { return nil }
        return "\(left) scan\(left == 1 ? "" : "s") left today"
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

    /// Refresh the allowance, camera status and pending uploads each time the
    /// start screen appears, so its banners are current before a capture.
    func startScreenAppeared() async {
        cameraAccess = .current
        await refreshPendingUpload()
        await refreshQuota()
    }

    /// Back from the Settings app: camera access may have changed.
    func refreshCameraAccess() {
        cameraAccess = .current
    }

    // MARK: - Starting a scan

    func startCapture() async {
        // Check quota BEFORE starting the engine. A real device test had a user
        // shoot a full 28-shot session only to be rejected with 429 at
        // POST /v1/worlds; enforcing up front means they learn the limit first.
        await refreshQuota()
        guard !isQuotaExhausted else { return }

        #if targetEnvironment(simulator)
        startEngine()
        #else
        // Never crash on a missing usage string: the OS kills the app on
        // camera access without NSCameraUsageDescription in the Info.plist.
        guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil else {
            #if DEBUG
            toasts.show("Camera permission text is missing from the build — capture is disabled.", style: .error)
            #else
            toasts.show("Something went wrong starting the scan. Try again.", style: .error)
            #endif
            return
        }
        cameraAccess = .current
        switch cameraAccess {
        case .authorized: startEngine()
        case .notDetermined: showsCameraPriming = true
        case .denied, .restricted: break // the banner offers Open Settings
        }
        #endif
    }

    /// "Continue" on the priming sheet: now ask the system.
    func continueFromCameraPriming() async {
        showsCameraPriming = false
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        cameraAccess = granted ? .authorized : .denied
        if granted { startEngine() }
    }
}
