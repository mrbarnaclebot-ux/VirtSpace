//
//  CaptureView.swift
//  VirtSpace
//
//  The Scan tab (spec §6.1, ui-spec 4.2-4.4): start screen, then the live
//  camera feed (ARSCNView on device, animated stand-in in the simulator)
//  under CaptureHUDView, then a full-screen upload overlay, then the new
//  space's Detail via AppRouter. Always dark.
//
//  Layout only: CaptureScreenModel owns the state machine, uploads, quota,
//  coaching and idle timer; CaptureStartView draws the idle / failed screen.
//

import SwiftUI

struct CaptureView: View {
    @State private var model: CaptureScreenModel
    @Environment(AppRouter.self) private var router
    @Environment(WorldStore.self) private var worldStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var hud: CaptureHUDState { model.hud }

    /// A finished upload routes through AppRouter to the new space's Detail.
    init(api: APIClient, toasts: ToastCenter) {
        _model = State(initialValue: CaptureScreenModel(api: api, toasts: toasts))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                content
                if hud.isThermallyPaused {
                    thermalPauseOverlay
                }
                if let uploadedFrames = model.uploadedFrames {
                    UploadOverlayView(
                        uploaded: uploadedFrames,
                        total: hud.targets.count,
                        lead: model.coach.tip == .finished ? FirstScanCoach.finishedText : nil
                    )
                }
            }
            .animation(Theme.Motion.standard, value: model.uploadedFrames == nil)
            .animation(Theme.Motion.standard, value: hud.isThermallyPaused)
            .navigationBarHidden(true)
            .onChange(of: hud.state) { _, newState in
                model.engineStateChanged(to: newState)
            }
            .onChange(of: hud.capturedCount) { _, count in
                model.capturedCountChanged(to: count)
            }
            .onChange(of: hud.driftMeters > AlignmentMath.driftWarnMeters) { _, past in
                model.driftChanged(pastSoftGate: past)
            }
            .sensoryFeedback(.success, trigger: model.uploadSuccessCount)
            .onDisappear { model.screenDisappeared() }
            .task {
                model.worldStore = worldStore
                model.router = router
                await model.resumePendingOnce()
            }
        }
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .tabBar)
    }

    @ViewBuilder
    private var content: some View {
        switch hud.state {
        case .idle, .failed:
            CaptureStartView(model: model)
        case .starting:
            VStack(spacing: 14) {
                if !reduceMotion {
                    ProgressView().tint(Theme.accent)
                }
                Text("Starting camera…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
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
                        coach: model.coach,
                        onCancel: { model.engine.cancel() },
                        onContinueInLowLight: { model.engine.continueInLowLight() },
                        onRestart: { model.engine.restart() },
                        onDismissCoachTip: { model.dismissCoachTip($0) }
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
    /// only when the user taps, giving the phone a chance to cool.
    private var thermalPauseOverlay: some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "thermometer.high")
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
                Text("Paused to cool down")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Text("Your iPhone got too warm. Give it a minute. Your photos so far are saved.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button {
                    model.engine.resumeFromThermal()
                } label: {
                    Text("Continue scan")
                        .font(.headline)
                        .padding(.horizontal, 28)
                        .frame(minHeight: 50)
                        .background(Theme.warning, in: Capsule())
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                Button("Stop and delete", role: .destructive) {
                    model.engine.cancel()
                }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: Theme.minTarget)
                .tint(Theme.danger)
            }
        }
        .transition(.opacity)
    }
}

#Preview {
    let api = APIClient()
    CaptureView(api: api, toasts: ToastCenter())
        .environment(api)
        .environment(AppRouter())
        .environment(WorldStore(api: api))
}
