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
#if DEBUG
import UIKit
#endif

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
    /// True when a finished session is stranded on disk after a failed upload.
    @State private var hasPendingUpload = false
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
            }
            .task { await resumePendingOnce() }
        }
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
            Button {
                Task { await startCapture() }
            } label: {
                Label(failure == nil ? "Start capture" : "Try again", systemImage: "camera.fill")
                    .font(.headline)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(Color.cyan, in: Capsule())
                    .foregroundStyle(.black)
            }
            if hasPendingUpload {
                Button {
                    Task { await retryPendingUpload() }
                } label: {
                    Label("Retry upload", systemImage: "arrow.up.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.cyan)
                }
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
    }

    // MARK: - Uploading

    private func upload(_ result: CaptureResult) async {
        uploadedFrames = 0
        defer { uploadedFrames = nil }
        let uploader = CaptureUploader(api: api)
        do {
            _ = try await uploader.upload(result: result) { done in
                Task { @MainActor in uploadedFrames = done }
            }
            hasPendingUpload = false
            engine.reset()
            toast = Toast(message: "Scan uploaded — watch it build in Library.", style: .success)
            try? await Task.sleep(for: .milliseconds(700))
            switchToLibrary()
        } catch {
            hasPendingUpload = true
            engine.reset()
            toast = Toast(message: "Upload failed — your scan is saved. Retry from here or relaunch. (\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))", style: .error)
        }
    }

    /// Manual retry of a stranded session (wired to CaptureUploader.resumePending).
    private func retryPendingUpload() async {
        uploadedFrames = 0
        defer { uploadedFrames = nil }
        let uploaded = await CaptureUploader(api: api).resumePending { done in
            Task { @MainActor in uploadedFrames = done }
        }
        if uploaded.isEmpty {
            toast = Toast(message: "Upload failed again — check your connection and retry.", style: .error)
        } else {
            hasPendingUpload = false
            toast = Toast(message: "Scan uploaded — watch it build in Library.", style: .success)
            try? await Task.sleep(for: .milliseconds(700))
            switchToLibrary()
        }
    }

    /// Retry any capture sessions stranded on disk by a crash or failed upload.
    private func resumePendingOnce() async {
        guard !didResumePending else { return }
        didResumePending = true
        let uploaded = await CaptureUploader(api: api).resumePending()
        if !uploaded.isEmpty {
            toast = Toast(message: "Resumed \(uploaded.count) pending scan upload\(uploaded.count == 1 ? "" : "s").", style: .success)
        }
    }

    // MARK: - Permission gate

    private func startCapture() async {
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
