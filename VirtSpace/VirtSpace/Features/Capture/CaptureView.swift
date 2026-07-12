//
//  CaptureView.swift
//  VirtSpace
//
//  Stage B1: functional-but-plain guided capture flow driven by
//  CaptureEngine (Stage B2 adds the polished HUD). Start → camera
//  permission → live readout (target label, angle, steady dot, n/16,
//  drift warning) with a crosshair + text direction hint → on finish the
//  session uploads via CaptureUploader and routes to Library.
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
    /// Non-nil while a finished capture is uploading (frames done so far).
    @State private var uploadedFrames: Int?
    @State private var didResumePending = false

    var body: some View {
        NavigationStack {
            ZStack {
                backdrop
                content
            }
            .navigationBarHidden(true)
            .toast($toast)
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
            liveCapture
        case .finished:
            uploadingScreen
        }
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
                Text("Stand on one spot and pivot in place. Follow the 16 targets — VirtSpace turns your surroundings into a walkable 3D world.")
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
            Spacer()
            #if DEBUG
            testScanButton
                .padding(.bottom, 24)
            #endif
        }
    }

    // MARK: - Live capture readout (plain; B2 replaces with the real HUD)

    private var liveCapture: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { engine.cancel() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text("\(engine.capturedCount)/\(engine.targets.count)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

            Spacer()

            // Crosshair that reflects alignment state.
            ZStack {
                Circle()
                    .strokeBorder(
                        engine.isAligned ? Color.green : Color.white.opacity(0.4),
                        lineWidth: engine.isAligned ? 3 : 1.5
                    )
                    .frame(width: 84, height: 84)
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(engine.isAligned ? .green : .white.opacity(0.7))
            }
            .padding(.bottom, 22)

            VStack(spacing: 10) {
                if let target = engine.currentTarget {
                    Text(target.label)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                }

                if case .capturing = engine.state {
                    Text("Capturing…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.cyan)
                } else if case .advancing = engine.state {
                    Text("Got it")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    Text(directionHint)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(engine.isAligned ? .green : .cyan)
                        .monospacedDigit()
                }

                HStack(spacing: 14) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(engine.isSteady ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(engine.isSteady ? "Steady" : "Hold still")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Text(String(format: "%.0f° off", engine.angularDistanceDegrees))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }

                if let driftWarning = engine.driftWarning {
                    Text(driftWarning)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                if let warning = engine.warning {
                    Text(warning)
                        .font(.footnote)
                        .foregroundStyle(.yellow)
                }
                if engine.capturedCount > 0 && !engine.exposureLocked {
                    Text("Exposure lock unavailable — seams may vary")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 30)

            Spacer()
        }
    }

    /// Plain-text aim hint ("→ turn right 34°"); the B2 HUD replaces this.
    private var directionHint: String {
        let yaw = engine.yawDeltaDegrees
        let pitch = engine.pitchDeltaDegrees
        if engine.isAligned { return "Hold still…" }
        // Lead with whichever correction is larger.
        if abs(yaw) >= abs(pitch), abs(yaw) > 4 {
            return yaw > 0
                ? "→ turn right \(Int(abs(yaw).rounded()))°"
                : "← turn left \(Int(abs(yaw).rounded()))°"
        }
        if abs(pitch) > 4 {
            return pitch > 0
                ? "↑ look up \(Int(abs(pitch).rounded()))°"
                : "↓ look down \(Int(abs(pitch).rounded()))°"
        }
        return "Almost there…"
    }

    // MARK: - Uploading

    private var uploadingScreen: some View {
        VStack(spacing: 16) {
            ProgressView(
                value: Double(uploadedFrames ?? 0),
                total: Double(engine.targets.count)
            )
            .tint(.cyan)
            .padding(.horizontal, 60)
            Text(uploadedFrames == nil
                 ? "Preparing upload…"
                 : "Uploading \(uploadedFrames ?? 0)/\(engine.targets.count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private func upload(_ result: CaptureResult) async {
        uploadedFrames = 0
        defer { uploadedFrames = nil }
        let uploader = CaptureUploader(api: api)
        do {
            _ = try await uploader.upload(result: result) { done in
                Task { @MainActor in uploadedFrames = done }
            }
            engine.reset()
            toast = Toast(message: "Scan uploaded — watch it build in Library.", style: .success)
            try? await Task.sleep(for: .milliseconds(700))
            switchToLibrary()
        } catch {
            engine.reset()
            toast = Toast(message: "Upload failed — your scan is saved and will retry. (\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))", style: .error)
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
