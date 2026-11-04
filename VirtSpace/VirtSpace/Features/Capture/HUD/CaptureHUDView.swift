//
//  CaptureHUDView.swift
//  VirtSpace
//
//  The Stage B2 capture HUD (spec §6.1): world-locked target dots projected
//  from the engine's live camera transform, a snapping reticle with a dwell
//  ring, edge chevrons for off-screen targets, the filling-sphere progress
//  hero, coaching banners and session chrome. Renders on top of the camera
//  layer; owns no capture logic — everything is driven by the engine's
//  published CaptureHUDState.
//

import simd
import SwiftUI

struct CaptureHUDView: View {
    let hud: CaptureHUDState
    var onCancel: () -> Void = {}
    var onContinueInLowLight: () -> Void = {}
    var onRestart: () -> Void = {}

    @State private var showAbandonDialog = false
    @State private var flashOpacity: Double = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                vignette
                targetDotsLayer(viewSize: geo.size)
                reticle
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                Color.white
                    .opacity(flashOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            CoachingLayer(hud: hud)
                .padding(.top, 64)
        }
        .overlay(alignment: .topLeading) { closeButton.padding(.leading, 20) }
        .overlay(alignment: .topTrailing) { exposurePill.padding(.trailing, 20) }
        .overlay(alignment: .bottom) { bottomBar.padding(.bottom, 14) }
        .overlay {
            if hud.isOfferingRestart {
                restartCard.transition(.opacity)
            } else if hud.isTooDark {
                lowLightCard.transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: hud.isTooDark)
        .animation(.easeOut(duration: 0.25), value: hud.isOfferingRestart)
        .onChange(of: hud.capturedCount) { old, new in
            guard new > old else { return }
            fireShotFlash()
        }
        .confirmationDialog(
            "Abandon this scan?",
            isPresented: $showAbandonDialog,
            titleVisibility: .visible
        ) {
            Button("Abandon scan", role: .destructive) { onCancel() }
            Button("Keep capturing", role: .cancel) {}
        } message: {
            Text("The \(hud.capturedCount) shots taken so far will be discarded.")
        }
    }

    // MARK: - World-locked target dots

    private func targetDotsLayer(viewSize: CGSize) -> some View {
        let transform = hud.cameraTransform
        let directions = hud.targetDirections
        let forward = AlignmentMath.forward(of: transform)
        let currentIndex = hud.currentTarget?.index

        return ZStack {
            ForEach(hud.targets) { target in
                if directions.indices.contains(target.index) {
                    let projected = TargetProjection.project(
                        worldDirection: directions[target.index],
                        cameraTransform: transform,
                        intrinsics: hud.cameraIntrinsics,
                        imageResolution: hud.imageResolution,
                        viewSize: viewSize
                    )
                    if projected.isOnScreen {
                        let captured = hud.capturedFlags.indices.contains(target.index)
                            && hud.capturedFlags[target.index]
                        let degreesOff = AlignmentMath.angularDistanceDegrees(forward, directions[target.index])
                        targetDot(
                            captured: captured,
                            isCurrent: target.index == currentIndex,
                            degreesOff: degreesOff
                        )
                        .position(projected.point)
                    }
                }
            }

            // Off-screen current target → edge chevron with degrees-to-go.
            if let currentIndex, directions.indices.contains(currentIndex) {
                let projected = TargetProjection.project(
                    worldDirection: directions[currentIndex],
                    cameraTransform: transform,
                    intrinsics: hud.cameraIntrinsics,
                    imageResolution: hud.imageResolution,
                    viewSize: viewSize
                )
                if !projected.isOnScreen {
                    let anchor = TargetProjection.edgeAnchor(
                        direction: projected.screenDirection,
                        viewSize: viewSize,
                        padding: 58
                    )
                    edgeChevron(angle: anchor.angle, degrees: hud.angularDistanceDegrees)
                        .position(anchor.point)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// A single world-locked dot: uncaptured dots glow brighter and larger as
    /// the camera closes in; captured ones collapse into a green check.
    @ViewBuilder
    private func targetDot(captured: Bool, isCurrent: Bool, degreesOff: Double) -> some View {
        if captured {
            // Dimmed once captured (Stage B3 deliverable 1): the painted
            // imagery now fills that direction, so the marker recedes to a
            // small, low-contrast tick and lets the panorama read clearly.
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.14))
                    .frame(width: 15, height: 15)
                Image(systemName: "checkmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.green.opacity(0.6))
            }
            .opacity(0.7)
        } else {
            // 0 (far) → 1 (dead-on) over a 60° falloff.
            let closeness = max(0, 1 - degreesOff / 60)
            let diameter = 16 + 26 * closeness
            let tint = isCurrent ? Color.cyan : Color.white
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16 + 0.38 * closeness))
                    .frame(width: diameter, height: diameter)
                    .blur(radius: 3 + 5 * closeness)
                Circle()
                    .strokeBorder(tint.opacity(isCurrent ? 0.95 : 0.4), lineWidth: isCurrent ? 2 : 1)
                    .frame(width: diameter, height: diameter)
                if isCurrent {
                    Circle()
                        .fill(tint)
                        .frame(width: 5, height: 5)
                }
            }
            .shadow(color: tint.opacity(0.5 * closeness), radius: 8)
        }
    }

    private func edgeChevron(angle: Double, degrees: Double) -> some View {
        VStack(spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.cyan)
                .rotationEffect(.radians(angle))
                .shadow(color: .cyan.opacity(0.6), radius: 6)
            Text("\(Int(degrees.rounded()))°")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    // MARK: - Reticle

    private var reticle: some View {
        let aligned = hud.isAligned
        let capturing: Bool = {
            if case .capturing = hud.state { return true }
            return false
        }()
        let tint: Color = aligned ? .green : .white

        return ZStack {
            // Base ring.
            Circle()
                .strokeBorder(tint.opacity(aligned ? 0.9 : 0.38), lineWidth: aligned ? 2.5 : 1.5)
                .frame(width: 82, height: 82)

            // Dwell fill: sweeps closed over the 300 ms hold.
            Circle()
                .trim(from: 0, to: hud.dwellProgress)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 82, height: 82)

            // Center mark.
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(tint.opacity(0.85))

            if capturing {
                Circle()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 74, height: 74)
            }
        }
        // Magnetic snap: the reticle tightens when the target locks in.
        .scaleEffect(aligned ? 0.88 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.6), value: aligned)
        .allowsHitTesting(false)
    }

    private func fireShotFlash() {
        withAnimation(.easeOut(duration: 0.06)) { flashOpacity = 0.55 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            withAnimation(.easeOut(duration: 0.3)) { flashOpacity = 0 }
        }
    }

    // MARK: - Chrome

    private var closeButton: some View {
        Button {
            showAbandonDialog = true
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("Cancel capture")
    }

    @ViewBuilder
    private var exposurePill: some View {
        if hud.exposureLocked {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("Exposure locked")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
            .animation(.spring(response: 0.35), value: hud.exposureLocked)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            if let target = hud.currentTarget {
                VStack(spacing: 3) {
                    Text(target.label)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .contentTransition(.opacity)
                    Text(statusLine)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(hud.isAligned ? .green : .white.opacity(0.55))
                        .monospacedDigit()
                }
                .animation(.easeOut(duration: 0.2), value: target.index)
            } else if case .advancing = hud.state {
                Text("Got it")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.green)
            }

            HStack(spacing: 12) {
                ProgressSphereView(
                    capturedFlags: hud.capturedFlags,
                    currentIndex: hud.currentTarget?.index
                )
                // The centroid exists only once a shot has landed.
                if hud.capturedCount > 0 {
                    PivotIndicatorView(offset: hud.pivotOffset)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .allowsHitTesting(false)
    }

    private var statusLine: String {
        if case .capturing = hud.state { return "Capturing…" }
        if hud.isAligned {
            return hud.isSteady ? "Hold still…" : "Steady…"
        }
        return "\(Int(hud.angularDistanceDegrees.rounded()))° away"
    }

    // MARK: - Low-light preflight

    /// Shown before shot 0 while AE is pinned near its ceiling (spec §6.1).
    /// Clears by itself once the room is bright enough.
    private var lowLightCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "lightbulb.max")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.yellow)
            Text("Too dark — turn on lights")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
            Text("Dim rooms scan noisy and blurry.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
            Button("Continue anyway", action: onContinueInLowLight)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.15), in: Capsule())
                .foregroundStyle(.white)
        }
        .multilineTextAlignment(.center)
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 40)
    }

    /// ARKit lost the room after an interruption and hasn't found it again.
    /// Withdrawn automatically if tracking recovers.
    private var restartCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "location.slash")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.orange)
            Text("Lost track of the room")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
            Text("Point at what you were scanning, or start over. Restarting discards the shots so far.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
            Button("Restart scan", action: onRestart)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.orange, in: Capsule())
                .foregroundStyle(.black)
        }
        .multilineTextAlignment(.center)
        .padding(22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 40)
    }

    // MARK: - Vignette

    /// Darkened edges so the raw camera feed reads as a viewfinder and HUD
    /// text stays legible (spec §6.5: dark, immersive, content-forward).
    private var vignette: some View {
        ZStack {
            RadialGradient(
                colors: [.clear, .clear, .black.opacity(0.42)],
                center: .center,
                startRadius: 120,
                endRadius: 520
            )
            LinearGradient(
                colors: [.black.opacity(0.5), .clear, .clear, .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

#Preview {
    ZStack {
        SimulatedCameraBackdrop()
        CaptureHUDView(hud: CaptureHUDState())
    }
    .preferredColorScheme(.dark)
}
