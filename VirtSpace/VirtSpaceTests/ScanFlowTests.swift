//
//  ScanFlowTests.swift
//  VirtSpaceTests
//
//  WP4 scan-flow decisions (ui-spec 4.2-4.4, 5.6, 5.7) as pure logic: the
//  first-scan coach, the Start button, the banner slot, the upload overlay's
//  phase text, and the HUD's direction line. Nothing here starts the engine,
//  touches the disk or the network.
//

import Foundation
import Testing
@testable import VirtSpace

@Suite("FirstScanCoach")
struct FirstScanCoachTests {
    @Test("First scan: intro, next-dot after shot 1, one drift tip, finale")
    func firstScanSequence() {
        var coach = FirstScanCoach()
        coach.begin(firstScan: true)
        #expect(coach.isActive)
        #expect(coach.tip == .intro)

        coach.shotsChanged(captured: 1, total: 28)
        #expect(coach.tip == .nextDot)
        #expect(coach.tip?.bannerText == "Nice. Now turn to the next dot.")
        coach.dismiss(.nextDot)
        #expect(coach.tip == nil)

        coach.driftChanged(pastSoftGate: true)
        #expect(coach.tip == .drift)
        coach.dismiss(.drift)
        coach.driftChanged(pastSoftGate: false)
        coach.driftChanged(pastSoftGate: true)
        #expect(coach.tip == nil, "the drift tip shows once per scan")

        coach.shotsChanged(captured: 28, total: 28)
        #expect(coach.tip == .finished)
    }

    @Test("Later scans get no coaching")
    func notFirstScan() {
        var coach = FirstScanCoach()
        coach.begin(firstScan: false)
        coach.shotsChanged(captured: 1, total: 28)
        coach.driftChanged(pastSoftGate: true)
        coach.shotsChanged(captured: 28, total: 28)
        #expect(!coach.isActive)
        #expect(coach.tip == nil)
    }

    @Test("Got it dismisses the intro; a later shot clears a lingering intro")
    func introDismissal() {
        var coach = FirstScanCoach()
        coach.begin(firstScan: true)
        coach.dismiss(.nextDot) // wrong tip: no effect
        #expect(coach.tip == .intro)
        coach.dismiss(.intro)
        #expect(coach.tip == nil)

        coach.begin(firstScan: true)
        coach.shotsChanged(captured: 2, total: 28)
        #expect(coach.tip == nil)
    }

    @Test("Begin resets the one-time drift tip")
    func beginResets() {
        var coach = FirstScanCoach()
        coach.begin(firstScan: true)
        coach.driftChanged(pastSoftGate: true)
        coach.begin(firstScan: true)
        coach.driftChanged(pastSoftGate: true)
        #expect(coach.tip == .drift)
    }
}

@Suite("Scan start screen")
struct ScanStartTests {
    @Test("Start button per quota, camera and last failure")
    func startButton() {
        #expect(StartButtonState.make(quotaExhausted: false, camera: .authorized, lastScanFailed: false)
            == StartButtonState(title: "Start scan", isEnabled: true))
        #expect(StartButtonState.make(quotaExhausted: false, camera: .notDetermined, lastScanFailed: false)
            == StartButtonState(title: "Start scan", isEnabled: true))
        #expect(StartButtonState.make(quotaExhausted: false, camera: .authorized, lastScanFailed: true)
            == StartButtonState(title: "Scan again", isEnabled: true))
        #expect(StartButtonState.make(quotaExhausted: true, camera: .authorized, lastScanFailed: true)
            == StartButtonState(title: "Scan unavailable today", isEnabled: false))
        #expect(!StartButtonState.make(quotaExhausted: false, camera: .denied, lastScanFailed: false).isEnabled)
        #expect(!StartButtonState.make(quotaExhausted: false, camera: .restricted, lastScanFailed: false).isEnabled)
    }

    private func banners(
        camera: CameraAccess = .authorized,
        quota: Bool = false,
        failure: String? = nil,
        pending: Int = 0,
        parked: Int = 0,
        scanFailed: Bool = false
    ) -> [StartBanner] {
        StartBanner.list(
            camera: camera,
            quotaExhausted: quota,
            quotaResetsAt: nil,
            uploadFailure: failure,
            pending: PendingUploadSummary(pendingCount: pending, parkedCount: parked),
            scanFailed: scanFailed
        )
    }

    @Test("Banner slot: nothing at rest, conditions in priority order")
    func bannerOrder() {
        #expect(banners().isEmpty)
        #expect(banners(camera: .denied) == [.cameraDenied])
        #expect(banners(camera: .denied).first?.message == "VirtSpace needs camera access to scan.")
        #expect(banners(camera: .restricted) == [.cameraRestricted])
        #expect(banners(quota: true) == [.quotaReached(resetAt: nil)])
        #expect(banners(quota: true).first?.message == "You've used today's scans.")
        #expect(banners(camera: .denied, quota: true, scanFailed: true)
            == [.cameraDenied, .quotaReached(resetAt: nil), .scanFailed])
    }

    @Test("Pending uploads: waiting, failed with cause, parked")
    func pendingBanners() {
        #expect(banners(pending: 1) == [.waiting(count: 1)])
        #expect(banners(pending: 1).first?.message == "1 scan waiting to upload. It will retry when you're online.")
        #expect(banners(failure: "Upload didn't finish.", pending: 1) == [.uploadFailed("Upload didn't finish.")])
        #expect(banners(failure: "Upload didn't finish.", pending: 1, parked: 1) == [.parked])
        #expect(banners(parked: 1).first?.message == "This scan couldn't upload. It's saved on this phone.")
        // A failure with nothing left on disk has nothing to retry.
        #expect(banners(failure: "Upload didn't finish.").isEmpty)
    }

    @Test("Upload failure causes are mapped, never raw")
    func uploadCause() {
        let offline = URLError(.notConnectedToInternet)
        #expect(CaptureScreenModel.cause(of: offline) == "You're offline. Check your connection and try again.")
        #expect(CaptureScreenModel.cause(of: APIError.rateLimited) == "Too many tries. Wait a moment and try again.")
        #expect(CaptureScreenModel.cause(of: CocoaError(.fileWriteOutOfSpace)) == "Something went wrong. Try again.")
        #expect(!CaptureScreenModel.cause(of: APIError.unauthorized).contains("Secrets"))
    }

    @Test("Failed engine state drives Scan again and the failure banner")
    func failedState() {
        let model = CaptureScreenModel(api: APIClient(), toasts: ToastCenter())
        #expect(model.startButton.title == "Start scan")
        #expect(!model.lastScanFailed)
    }
}

@Suite("Upload overlay")
struct UploadOverlayPhaseTests {
    @Test("Counts photos, then says Finishing up once every photo is up")
    func phases() {
        let counting = UploadOverlayView.Phase.of(uploaded: 12, total: 28)
        #expect(counting.title == "Uploading photos")
        #expect(counting.counter == "12 of 28")
        #expect(UploadOverlayView.Phase.of(uploaded: 0, total: 28).counter == "0 of 28")

        let finishing = UploadOverlayView.Phase.of(uploaded: 28, total: 28)
        #expect(finishing == .finishing)
        #expect(finishing.title == "Finishing up…")
        #expect(finishing.counter == nil)
        #expect(UploadOverlayView.subtitle == "Keep VirtSpace open until this finishes.")
        // No total yet: never claims to be finishing.
        #expect(UploadOverlayView.Phase.of(uploaded: 0, total: 0) != .finishing)
    }
}

@Suite("Scan instruction")
struct ScanInstructionTests {
    private func line(
        pitch: Double = 0, yaw: Double = 0, tilt: Double = 0, away: Double = 20,
        aligned: Bool = false, capturing: Bool = false, firstScan: Bool = false
    ) -> ScanInstruction? {
        ScanInstruction.make(
            targetPitch: pitch, yawDelta: yaw, pitchDelta: tilt, degreesAway: away,
            isAligned: aligned, isCapturing: capturing, firstScan: firstScan
        )
    }

    @Test("Direction from the larger delta, degrees in the caption")
    func directions() {
        #expect(line(yaw: 30, tilt: 5) == ScanInstruction(title: "Turn right", detail: "20°"))
        #expect(line(yaw: -30, tilt: 5)?.title == "Turn left")
        #expect(line(yaw: 5, tilt: 40)?.title == "Tilt up")
        #expect(line(yaw: 5, tilt: -40)?.title == "Tilt down")
        #expect(line(away: 12.4)?.detail == "12°")
    }

    @Test("Ceiling and floor targets, longer floor copy on the first scan")
    func poles() {
        #expect(line(pitch: 90, yaw: 50)?.title == "Point at the ceiling")
        #expect(line(pitch: -90, tilt: -50)?.title == "Point at the floor")
        #expect(line(pitch: -90, firstScan: true)?.title == "Point at the floor by your feet")
    }

    @Test("Hold still once aligned, nothing while the photo is taken, no target labels")
    func alignedAndCapturing() {
        #expect(line(aligned: true) == ScanInstruction(title: "Hold still", detail: nil))
        #expect(line(aligned: true, capturing: true) == nil)
        let titles = [line(yaw: 1), line(yaw: -1), line(tilt: 9), line(tilt: -9), line(pitch: 90), line(pitch: -90)]
            .compactMap { $0?.title }
        #expect(!titles.contains { $0.contains("Horizon") || $0.contains("Up ") || $0.contains("Down ") })
    }

    @Test("Announcements at most once per 2 s")
    func throttle() {
        var throttle = AnnouncementThrottle()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let first = throttle.allow(at: start)
        let tooSoon = throttle.allow(at: start.addingTimeInterval(1.9))
        let later = throttle.allow(at: start.addingTimeInterval(2.1))
        #expect(first)
        #expect(!tooSoon)
        #expect(later)
    }
}
