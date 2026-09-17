//
//  CaptureView.swift
//  VirtSpace
//
//  Stage B2: the polished guided-capture experience (spec §6.1). Start →
//  camera permission → live camera feed (ARSCNView on device, animated
//  stand-in in the simulator) under CaptureHUDView's world-locked dots,
//  snapping reticle, filling-sphere progress and coaching banners → on
//  finish, a full-screen upload overlay driven by CaptureUploader, then
//  route to Library.
//
//  Keeps the DEBUG-only "Run test scan" harness from Stage A.
//

import AVFoundation
import SwiftUI
import UIKit

struct CaptureView: View {
    @Environment(APIClient.self) private var api

    /// Set by the app shell so finished scans can route to the Library tab.
    var switchToLibrary: () -> Void = {}

    @State private var engine = CaptureEngine()
    @State private var toast: Toast?
    @State private var isRunningTestScan = false
    /// Non-nil while an upload is in flight (frames done so far) — drives the
    /// full-screen upload overlay.
    @State private var uploadedFrames: Int?
    @State private var didResumePending = false
    /// Finished sessions stranded on disk after a failed upload, and how many
    /// have exhausted their automatic retries (parked, spec §10 R4) and so need
    /// an explicit Retry / Discard from the user.
    @State private var pendingUpload = PendingUploadSummary()
    @State private var showDiscardConfirmation = false
    /// Scans left in today's window, from GET /v1/me/quota. nil = unknown (not
    /// yet fetched, or the check failed — in which case we fail open and let
    /// capture proceed). 0 = daily limit reached; capture is blocked up front.
    @State private var scansRemaining: Int?
    /// When today's quota window frees up (only meaningful once exhausted).
    @State private var quotaResetsAt: Date?
    #if DEBUG
    /// Drives the DEBUG-only bundled-fixture explorer (no backend needed).
    @State private var showFixtureExplorer = false
    #endif

    var body: some View {
        NavigationStack {
            ZStack {
                backdrop
                content
                if engine.isThermallyPaused {
                    thermalPauseOverlay
                }
                if let uploadedFrames {
                    UploadOverlayView(uploaded: uploadedFrames, total: engine.targets.count)
                }
            }
            .animation(.easeOut(duration: 0.25), value: uploadedFrames == nil)
            .animation(.easeOut(duration: 0.25), value: engine.isThermallyPaused)
            .navigationBarHidden(true)
            .toast($toast)
            #if DEBUG
            .fullScreenCover(isPresented: $showFixtureExplorer) {
                if let url = ViewerSchemeHandler.bundledURL("fixture.spz") {
                    ExplorerView(source: .file(url), title: "Fixture World")
                } else {
                    missingFixtureView
                }
            }
            #endif
            .onChange(of: engine.state) { _, newState in
                if case .finished(let result) = newState {
                    Task { await upload(result) }
                }
                updateScreenAwake()
            }
            .onChange(of: uploadedFrames) { _, _ in updateScreenAwake() }
            .onDisappear {
                // Belt-and-braces: always hand the screen back when we leave.
                UIApplication.shared.isIdleTimerDisabled = false
            }
            .task {
                // Orphan-world prevention: abandoning a scan whose session
                // already minted a backend world (confirm-abandon in the HUD,
                // thermal-overlay abandon — both land in engine.cancel())
                // best-effort deletes that world server-side before the local
                // purge. The worker's 24 h uploading reaper is the backstop
                // when this can't land (e.g. abandoned while offline).
                engine.onSessionDiscarded = { worldId in
                    Task { try? await api.deleteWorld(id: worldId) }
                }
                await resumePendingOnce()
            }
        }
    }

    /// Keep the screen awake for the full capture + upload arc (belt-and-braces
    /// with the background session, which handles the app being suspended). The
    /// idle timer is restored the moment we return to idle / the overlay clears.
    private var shouldKeepScreenAwake: Bool {
        if uploadedFrames != nil { return true }
        switch engine.state {
        case .idle, .failed: return false
        default: return true // starting / ready / capturing / advancing / finished
        }
    }

    private func updateScreenAwake() {
        UIApplication.shared.isIdleTimerDisabled = shouldKeepScreenAwake
    }

    @ViewBuilder
    private var content: some View {
        switch engine.state {
        case .idle:
            startScreen(failure: nil)
        case .failed(let message):
            startScreen(failure: message)
        case .starting:
            VStack(spacing: 14) {
                ProgressView().tint(.cyan)
                Text("Starting camera…")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }
        case .ready, .capturing, .advancing:
            ZStack {
                cameraLayer
                CaptureHUDView(engine: engine, onCancel: { engine.cancel() })
            }
        case .finished:
            // The upload overlay (top-level ZStack) covers this state.
            cameraLayer
        }
    }

    /// Live camera feed behind the HUD. On device: the engine's ARSession
    /// rendered by a bare ARSCNView (see CameraPreviewView for the rationale),
    /// with painted-sphere quads for captured shots. Simulator: stylized
    /// animated placeholder with the same paint quads via a Canvas overlay.
    @ViewBuilder
    private var cameraLayer: some View {
        #if targetEnvironment(simulator)
        SimulatedCameraBackdrop(
            paintedShots: engine.paintedShots,
            cameraTransform: engine.cameraTransform,
            intrinsics: engine.cameraIntrinsics,
            imageResolution: engine.imageResolution
        )
        #else
        if let session = engine.previewSession {
            CameraPreviewView(
                session: session,
                paintedShots: engine.paintedShots,
                preferredFPS: previewFPS
            )
            .ignoresSafeArea()
        } else {
            Color.black.ignoresSafeArea()
        }
        #endif
    }

    /// Viewfinder frame rate: 30 fps normally, dropped to 24 under thermal
    /// pressure to shed load and heat (Stage B3 deliverable 2d/2e).
    private var previewFPS: Int {
        CaptureEngine.previewFrameRate(for: engine.thermalState)
    }

    // MARK: - Idle / failed

    private func startScreen(failure: String?) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "viewfinder")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.cyan)
            VStack(spacing: 8) {
                Text("Guided 360° Capture")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("Stand on one spot and pivot in place. Follow the targets — VirtSpace turns your surroundings into a walkable 3D world.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }
            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }
            if isQuotaExhausted {
                quotaLimitNotice
            }
            Button {
                Task { await startCapture() }
            } label: {
                Label(failure == nil ? "Start capture" : "Try again", systemImage: "camera.fill")
                    .font(.headline)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(isQuotaExhausted ? Color.gray.opacity(0.4) : Color.cyan, in: Capsule())
                    .foregroundStyle(.black)
            }
            .disabled(isQuotaExhausted)
            // Subtle heads-up as the day's allowance runs low (not when it's 0 —
            // the full-width notice covers that case).
            if !isQuotaExhausted, let left = scansRemaining, left < 5 {
                Text("\(left) scan\(left == 1 ? "" : "s") left today")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
            }
            if pendingUpload.hasPending {
                pendingUploadControls
            }
            Spacer()
            #if DEBUG
            VStack(spacing: 12) {
                testScanButton
                fixtureExplorerButton
            }
            .padding(.bottom, 24)
            #endif
        }
        // Refresh the allowance each time the start screen appears so the
        // remaining-scans hint / limit notice is current before a capture.
        .task {
            refreshPendingUpload()
            await refreshQuota()
        }
    }

    /// Pending-upload affordances. A session that has burned its automatic
    /// retry budget is PARKED: nothing retries it in the background any more
    /// (each retry can mint a billable world — spec §10 R4), so the choice is
    /// handed to the user explicitly.
    @ViewBuilder
    private var pendingUploadControls: some View {
        VStack(spacing: 10) {
            if pendingUpload.hasParked {
                Text("Upload paused after \(CaptureStore.Manifest.maxAutomaticAttempts) failed attempts. Your scan is still saved on this device.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }
            Button {
                Task { await retryPendingUpload() }
            } label: {
                Label("Retry upload", systemImage: "arrow.up.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.cyan)
            }
            if pendingUpload.hasParked {
                Button("Discard scan", role: .destructive) {
                    showDiscardConfirmation = true
                }
                .font(.subheadline.weight(.semibold))
                .tint(.red)
            }
        }
        .confirmationDialog(
            "Discard this scan?",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard scan", role: .destructive) {
                Task { await discardPendingUpload() }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("The captured frames are deleted from this device and can't be recovered.")
        }
    }

    /// True once we know the daily scan limit is spent (0 remaining). nil/unknown
    /// (quota not fetched or the check failed) is NOT exhausted — we fail open.
    private var isQuotaExhausted: Bool { scansRemaining == 0 }

    /// Full-width, friendly heads-up shown when the day's scans are used up.
    private var quotaLimitNotice: some View {
        VStack(spacing: 6) {
            Text("Daily scan limit reached\(quotaResetLabel)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Text("Your captures are precious; so are the credits 🙂")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 24)
    }

    /// " — resets in about 5 hours" when a reset time is known; empty otherwise.
    private var quotaResetLabel: String {
        guard let resetsAt = quotaResetsAt else { return "" }
        let relative = resetsAt.formatted(.relative(presentation: .named))
        return " — resets \(relative)"
    }

    // MARK: - Uploading

    private func upload(_ result: CaptureResult) async {
        uploadedFrames = 0
        defer { uploadedFrames = nil }
        // App-scoped flow (UploadManager owns the task): navigating tabs or
        // dismissing this view can no longer cancel the upload — awaiting the
        // handle below is UI-only, the flow survives this view.
        let handle = UploadManager.shared.kickUpload(result: result, api: api) { done in
            Task { @MainActor in uploadedFrames = done }
        }
        switch await handle.value {
        case .success:
            engine.reset()
            refreshPendingUpload()
            toast = Toast(message: "Scan uploaded — watch it build in Library.", style: .success)
            try? await Task.sleep(for: .milliseconds(700))
            switchToLibrary()
        case .failure(let error):
            engine.reset()
            refreshPendingUpload()
            toast = Toast(message: "Upload failed — your scan is saved. Retry from here or relaunch. (\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))", style: .error)
        }
    }

    /// Manual retry of a stranded session (app-scoped via UploadManager). A
    /// user-initiated retry clears the attempt counter, so a parked session
    /// gets a full fresh automatic budget again.
    private func retryPendingUpload() async {
        uploadedFrames = 0
        defer { uploadedFrames = nil }
        let handle = UploadManager.shared.kickResume(api: api, userInitiated: true) { done in
            Task { @MainActor in uploadedFrames = done }
        }
        let outcome = await handle.value
        refreshPendingUpload()
        switch outcome {
        case .succeeded:
            toast = Toast(message: "Scan uploaded — watch it build in Library.", style: .success)
            try? await Task.sleep(for: .milliseconds(700))
            switchToLibrary()
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
    private func discardPendingUpload() async {
        let discarded = await UploadManager.shared.kickDiscardPending(api: api).value
        refreshPendingUpload()
        if discarded > 0 {
            toast = Toast(message: "Scan discarded.", style: .success)
        }
    }

    /// Retry any capture sessions stranded on disk by a crash or failed upload.
    /// The flow itself is app-scoped (UploadManager); this await is UI-only.
    private func resumePendingOnce() async {
        // A hosted test run launches this app; resuming would upload for real.
        guard !TestEnvironment.isRunningUnderXCTest else { return }
        guard !didResumePending else { return }
        didResumePending = true
        let outcome = await UploadManager.shared.kickResume(api: api).value
        refreshPendingUpload()
        if case .succeeded(let worlds) = outcome, !worlds.isEmpty {
            toast = Toast(message: "Resumed \(worlds.count) pending scan upload\(worlds.count == 1 ? "" : "s").", style: .success)
        }
    }

    /// Re-read what's waiting on disk (pending / parked) for the affordances
    /// on the start screen.
    private func refreshPendingUpload() {
        pendingUpload = UploadManager.shared.pendingSummary(api: api)
    }

    // MARK: - Quota

    /// Pull the current daily-scan allowance. On failure we deliberately clear
    /// to "unknown" (nil) rather than blocking: capture is offline-safe (frames
    /// persist to disk and upload retries), so a flaky quota check must never
    /// stop someone from capturing — see startCapture()'s fail-open branch.
    private func refreshQuota() async {
        // No backend calls from a hosted test run (TestEnvironment).
        guard !TestEnvironment.isRunningUnderXCTest else { return }
        do {
            let q = try await api.quota()
            scansRemaining = q.scansRemaining
            quotaResetsAt = q.quotaResetsAt
        } catch {
            scansRemaining = nil
            quotaResetsAt = nil
        }
    }

    // MARK: - Permission gate

    private func startCapture() async {
        // Check quota BEFORE starting the engine — the whole point of this
        // screen's guard. A real device test had a user shoot a full 28-shot
        // session only to be rejected with 429 at POST /v1/worlds; enforcing up
        // front means they learn the limit before spending the effort.
        await refreshQuota()
        if scansRemaining == 0 {
            // Exhausted — the full-width notice is already shown; do not start.
            return
        }
        // scansRemaining == nil means the quota check itself failed. Fail open:
        // capture works offline (saved locally, upload retries later), so we let
        // capture proceed rather than block on a transient network error.

        #if targetEnvironment(simulator)
        // Simulated source — no camera involved.
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

    // MARK: - Thermal pause

    /// Full-screen cool-down UI shown when the device hits `.critical` and the
    /// engine has paused the session (Stage B3 deliverable 2e). Capture resumes
    /// only when the user taps — giving the phone a chance to cool.
    private var thermalPauseOverlay: some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "thermometer.high")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.orange)
                Text("Paused to cool down")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Text("Your iPhone got too warm, so capture paused to protect it. Give it a moment, then resume — your progress is saved.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button {
                    engine.resumeFromThermal()
                } label: {
                    Label("Resume capture", systemImage: "play.fill")
                        .font(.headline)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                        .background(Color.orange, in: Capsule())
                        .foregroundStyle(.black)
                }
                Button("Abandon scan", role: .destructive) {
                    engine.cancel()
                }
                .font(.subheadline.weight(.semibold))
                .tint(.red)
            }
        }
        .transition(.opacity)
    }

    // MARK: - Visuals

    private var backdrop: some View {
        ZStack {
            Color.black
            RadialGradient(
                colors: [Color.indigo.opacity(0.35), .clear],
                center: .init(x: 0.5, y: 0.38),
                startRadius: 20,
                endRadius: 340
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - DEBUG test-scan harness

    #if DEBUG
    private var testScanButton: some View {
        Button {
            Task { await runTestScan() }
        } label: {
            HStack(spacing: 8) {
                if isRunningTestScan {
                    ProgressView().controlSize(.small).tint(.black)
                    Text("Running test scan…")
                } else {
                    Image(systemName: "ladybug")
                    Text("Run test scan")
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(Color.cyan, in: Capsule())
            .foregroundStyle(.black)
        }
        .disabled(isRunningTestScan)
    }

    /// DEBUG: open the bundled bedroom fixture straight in the 3D explorer —
    /// exercises Spark/WKWebView with zero backend dependency (Stage C).
    private var fixtureExplorerButton: some View {
        Button {
            showFixtureExplorer = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "cube.transparent")
                Text("Explore fixture world")
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .foregroundStyle(.cyan)
            .overlay(Capsule().stroke(.cyan.opacity(0.6), lineWidth: 1.5))
        }
    }

    private var missingFixtureView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "questionmark.folder")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.orange)
                Text("fixture.spz isn't bundled in this build.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                Button("Close") { showFixtureExplorer = false }
                    .tint(.cyan)
            }
        }
    }

    /// On-device E2E harness: exercises createWorld → presigned frame upload →
    /// framesDone against the real backend, then routes to Library.
    private func runTestScan() async {
        isRunningTestScan = true
        defer { isRunningTestScan = false }
        do {
            let frame = Self.makeGradientJPEG()
            let (world, uploads) = try await api.createWorld(title: "Test Scan", frameCount: 1)
            guard let slot = uploads.first else {
                throw APIError.server(0, "Backend returned no upload slots")
            }
            try await FrameUploader().upload(frame, to: slot)
            try await api.framesDone(worldId: world.id)
            toast = Toast(message: "Test scan started — watch it in Library.", style: .success)
            try? await Task.sleep(for: .milliseconds(700))
            switchToLibrary()
        } catch {
            toast = Toast(error)
        }
    }

    /// 1024x512 horizontal-gradient JPEG rendered in-memory.
    private static func makeGradientJPEG() -> Data {
        let size = CGSize(width: 1024, height: 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            let colors = [UIColor.systemIndigo.cgColor, UIColor.systemCyan.cgColor, UIColor.systemTeal.cgColor]
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors as CFArray,
                locations: [0, 0.5, 1]
            )!
            ctx.cgContext.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: size.width, y: 0),
                options: []
            )
        }
        return image.jpegData(compressionQuality: 0.85) ?? Data()
    }
    #endif
}

#Preview {
    CaptureView()
        .environment(APIClient())
        .preferredColorScheme(.dark)
}
