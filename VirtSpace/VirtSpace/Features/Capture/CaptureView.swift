//
//  CaptureView.swift
//  VirtSpace
//
//  Stage B2: the polished guided-capture experience (spec §6.1). Start →
//  camera permission → live camera feed (ARSCNView on device, animated
//  stand-in in the simulator) under CaptureHUDView's world-locked dots,
//  snapping reticle, filling-sphere progress and coaching banners → on
//  finish, a full-screen upload overlay, then route to Library.
//
//  Layout only: CaptureScreenModel owns the state machine, uploads, quota
//  and idle timer; CaptureStartView draws the idle / failed screen.
//

import SwiftUI

struct CaptureView: View {
    @State private var model: CaptureScreenModel
    private var hud: CaptureHUDState { model.hud }

    /// `switchToLibrary` is set by the app shell so finished scans can route
    /// to the Library tab.
    init(api: APIClient, switchToLibrary: @escaping () -> Void = {}) {
        _model = State(initialValue: CaptureScreenModel(api: api, switchToLibrary: switchToLibrary))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                backdrop
                content
                if hud.isThermallyPaused {
                    thermalPauseOverlay
                }
                if let uploadedFrames = model.uploadedFrames {
                    UploadOverlayView(uploaded: uploadedFrames, total: hud.targets.count)
                }
            }
            .animation(.easeOut(duration: 0.25), value: model.uploadedFrames == nil)
            .animation(.easeOut(duration: 0.25), value: hud.isThermallyPaused)
            .navigationBarHidden(true)
            .toast($model.toast)
            .onChange(of: hud.state) { _, newState in
                model.engineStateChanged(to: newState)
            }
            .onDisappear { model.screenDisappeared() }
            .task { await model.resumePendingOnce() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch hud.state {
        case .idle:
            CaptureStartView(model: model, failure: nil)
        case .failed(let message):
            CaptureStartView(model: model, failure: message)
        case .starting:
            VStack(spacing: 14) {
                ProgressView().tint(.cyan)
                Text("Starting camera…")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }
        case .ready, .capturing, .advancing, .finished:
            // ONE structural identity for the camera layer across all four
            // live states. Splitting `.finished` into its own branch used to
            // give the camera layer a different position in the view tree, so
            // the `.advancing → .finished` transition made SwiftUI tear down
            // the ARSCNView and build a fresh one — against an ARSession the
            // engine is pausing at that very moment (crash, see
            // CameraPreviewView) — and threw away the painted quads with the
            // old coordinator. The HUD is still hidden in `.finished`; the
            // upload overlay (top-level ZStack) covers that state.
            ZStack {
                cameraLayer
                if !hud.state.isFinished {
                    CaptureHUDView(
                        hud: hud,
                        onCancel: { model.engine.cancel() },
                        onContinueInLowLight: { model.engine.continueInLowLight() },
                        onRestart: { model.engine.restart() }
                    )
                }
            }
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
            paintedShots: hud.paintedShots,
            cameraTransform: hud.cameraTransform,
            intrinsics: hud.cameraIntrinsics,
            imageResolution: hud.imageResolution
        )
        #else
        if let session = hud.previewSession {
            CameraPreviewView(
                session: session,
                paintedShots: hud.paintedShots,
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
        ThermalGovernor.previewFrameRate(for: hud.thermalState)
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
                    model.engine.resumeFromThermal()
                } label: {
                    Label("Resume capture", systemImage: "play.fill")
                        .font(.headline)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                        .background(Color.orange, in: Capsule())
                        .foregroundStyle(.black)
                }
                Button("Abandon scan", role: .destructive) {
                    model.engine.cancel()
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
}

#Preview {
    CaptureView(api: APIClient())
        .environment(APIClient())
        .preferredColorScheme(.dark)
}
