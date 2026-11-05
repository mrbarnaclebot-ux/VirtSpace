//
//  CaptureHUDView.swift
//  VirtSpace
//
//  The capture HUD (spec §6.1, ui-spec 4.3): world-locked target dots, a
//  snapping reticle with a dwell ring and a drawn-on check per shot, one
//  instruction line ("Turn right", "Hold still"), the filling-sphere progress
//  capsule, coaching banners, first-scan tips and session chrome. Renders on
//  top of the camera layer; owns no capture logic: everything is driven by
//  the engine's CaptureHUDState and the model's FirstScanCoach.
//
//  Feedback: a selection haptic once per target on lock-on, a soft 120 ms
//  flash per shot (none under Reduce Motion; the engine plays the shot
//  haptic), and VoiceOver announcements of each photo and of the direction
//  for each new target (at most once per 2 s).
//

import simd
import SwiftUI

struct CaptureHUDView: View {
    let hud: CaptureHUDState
    var coach = FirstScanCoach()
    var onCancel: () -> Void = {}
    var onContinueInLowLight: () -> Void = {}
    var onRestart: () -> Void = {}
    var onDismissCoachTip: (FirstScanCoach.Tip) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var showAbandonDialog = false
    @State private var flashOpacity: Double = 0
    /// Last target that played the lock-on haptic (once per target).
    @State private var lockedTarget: Int?
    @State private var lockTick = 0
    @State private var pivotPulseTick = 0
    @State private var directionThrottle = AnnouncementThrottle()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                vignette
                TargetDotsLayer(hud: hud, viewSize: geo.size)
                reticle
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                Color.white
                    .opacity(flashOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            CoachingLayer(hud: hud, coachTip: coach.tip?.bannerText)
                .padding(.top, 64)
        }
        .overlay(alignment: .topLeading) { closeButton.padding(.leading, 20) }
        .overlay(alignment: .bottom) { bottomStack.padding(.bottom, 14) }
        .overlay { centerCard }
        .animation(Theme.Motion.standard, value: hud.isTooDark)
        .animation(Theme.Motion.standard, value: hud.isOfferingRestart)
        .animation(Theme.Motion.standard, value: coach.tip)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .sensoryFeedback(.selection, trigger: lockTick)
        .onChange(of: hud.isAligned) { wasAligned, isAligned in
            lockOn(wasAligned: wasAligned, isAligned: isAligned)
        }
        .onChange(of: hud.capturedCount) { old, new in
            shotCountChanged(from: old, to: new)
        }
        .onChange(of: coach.tip) { _, tip in
            if tip == .drift, !reduceMotion { pivotPulseTick += 1 }
        }
        .task(id: hud.currentTarget?.index) { await announceDirection() }
    }

    @ViewBuilder
    private var centerCard: some View {
        if hud.isOfferingRestart {
            HUDCard.lostPlace(action: onRestart).transition(.opacity)
        } else if hud.isTooDark {
            HUDCard.lowLight(action: onContinueInLowLight).transition(.opacity)
        }
    }

    // MARK: - Reticle

    private var isCapturing: Bool {
        if case .capturing = hud.state { return true }
        return false
    }

    private var reticle: some View {
        let aligned = hud.isAligned
        let shotLanded = hud.state == .advancing
        let tint: Color = aligned || shotLanded ? Theme.success : .white

        return ZStack {
            Circle()
                .strokeBorder(tint.opacity(aligned ? 0.9 : 0.38), lineWidth: aligned ? 2.5 : 1.5)
                .frame(width: 82, height: 82)
            // Dwell fill: sweeps closed over the hold.
            Circle()
                .trim(from: 0, to: hud.dwellProgress)
                .stroke(Theme.success, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 82, height: 82)
            if isCapturing || shotLanded {
                Circle()
                    .fill(Theme.success.opacity(0.3))
                    .frame(width: 74, height: 74)
            }
            if shotLanded {
                Image(systemName: "checkmark")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.symbolEffect(.drawOn)))
            } else {
                Image(systemName: "plus")
                    .font(.body)
                    .foregroundStyle(tint.opacity(0.85))
            }
        }
        // Magnetic snap: the reticle tightens when the target locks in.
        .scaleEffect(aligned && !reduceMotion ? 0.88 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.6), value: aligned)
        .animation(Theme.Motion.emphasis, value: shotLanded)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Feedback

    private func lockOn(wasAligned: Bool, isAligned: Bool) {
        guard !wasAligned, isAligned, let index = hud.currentTarget?.index, index != lockedTarget else { return }
        lockedTarget = index
        lockTick += 1
    }

    private func shotCountChanged(from old: Int, to new: Int) {
        if new == 0 { lockedTarget = nil } // restarted
        guard new > old else { return }
        fireShotFlash()
        announce("Photo \(new) of \(hud.targets.count)", queued: false)
    }

    /// Soft 0.2 flash for 120 ms; nothing under Reduce Motion.
    private func fireShotFlash() {
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.04)) { flashOpacity = 0.2 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(Theme.Motion.exit) { flashOpacity = 0 }
        }
    }

    /// Speak the direction for a new target once the pose has caught up
    /// with it. Queued so it follows the "Photo n of 28" announcement.
    private func announceDirection() async {
        guard voiceOverEnabled, hud.currentTarget != nil else { return }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled, let title = instruction?.title, directionThrottle.allow() else { return }
        announce(title, queued: true)
    }

    private func announce(_ text: String, queued: Bool) {
        var message = AttributedString(text)
        message.accessibilitySpeechAnnouncementPriority = queued ? .low : .default
        AccessibilityNotification.Announcement(message).post()
    }

    // MARK: - Chrome

    private var closeButton: some View {
        Button {
            showAbandonDialog = true
        } label: {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: Theme.minTarget, height: Theme.minTarget)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop scan")
        .confirmationDialog("Stop scanning?", isPresented: $showAbandonDialog, titleVisibility: .visible) {
            Button("Stop and delete", role: .destructive) { onCancel() }
            Button("Keep scanning", role: .cancel) {}
        } message: {
            Text("The \(hud.capturedCount) photos taken so far will be deleted.")
        }
    }

    private var instruction: ScanInstruction? {
        guard let target = hud.currentTarget else { return nil }
        return ScanInstruction.make(
            targetPitch: target.pitchDegrees,
            yawDelta: hud.yawDeltaDegrees,
            pitchDelta: hud.pitchDeltaDegrees,
            degreesAway: hud.angularDistanceDegrees,
            isAligned: hud.isAligned,
            isCapturing: isCapturing,
            firstScan: coach.isActive
        )
    }

    private var bottomStack: some View {
        VStack(spacing: Theme.Space.s) {
            if coach.tip == .intro {
                HUDCard.firstScanIntro { onDismissCoachTip(.intro) }
                    .transition(.opacity)
            }
            instructionLine
            progressCapsule
        }
    }

    /// Fixed height, so the capsule doesn't jump while the line is empty.
    private var instructionLine: some View {
        VStack(spacing: 2) {
            Text(instruction?.title ?? " ")
                .font(.headline.bold())
                .foregroundStyle(hud.isAligned ? Theme.success : .white)
                .contentTransition(.opacity)
            Text(instruction?.detail ?? " ")
                .font(.footnote.weight(.medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
        }
        .shadow(color: .black.opacity(0.6), radius: 4)
        .animation(Theme.Motion.quick, value: instruction?.title)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private var progressCapsule: some View {
        HStack(spacing: 12) {
            ProgressSphereView(capturedFlags: hud.capturedFlags, currentIndex: hud.currentTarget?.index)
            // The centroid exists only once a shot has landed.
            if hud.capturedCount > 0 {
                PivotIndicatorView(offset: hud.pivotOffset)
                    .keyframeAnimator(initialValue: 1.0, trigger: pivotPulseTick) { content, scale in
                        content.scaleEffect(scale)
                    } keyframes: { _ in
                        SpringKeyframe(1.5, duration: 0.25)
                        SpringKeyframe(1.0, duration: 0.35)
                    }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
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
