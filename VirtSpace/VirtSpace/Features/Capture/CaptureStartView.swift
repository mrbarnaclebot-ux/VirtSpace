//
//  CaptureStartView.swift
//  VirtSpace
//
//  The scan start screen (ui-spec 4.2): title, three short steps, the banner
//  slot (camera, quota, pending upload, last failure), and the Start button
//  pinned to the bottom. Layout only: every decision lives in
//  CaptureScreenModel(+Start).
//

import SwiftUI
import UIKit

struct CaptureStartView: View {
    @Bindable var model: CaptureScreenModel

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDiscardConfirmation = false

    private static let steps: [(symbol: String, text: String)] = [
        ("figure.stand", "Stand in the middle"),
        ("arrow.trianglehead.2.clockwise.rotate.90", "Turn the phone, not your feet"),
        ("lightbulb.max", "Turn on the lights"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                header
                stepList
                ForEach(model.banners) { banner in
                    bannerView(banner)
                }
                #if DEBUG
                CaptureDebugToolsView(model: model)
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.xl)
            .padding(.bottom, Theme.Space.m)
            .animation(Theme.Motion.standard, value: model.banners)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) { startBlock }
        .task { await model.startScreenAppeared() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshCameraAccess() }
        }
        .sheet(isPresented: $model.showsCameraPriming) {
            CameraPrimingView { Task { await model.continueFromCameraPriming() } }
        }
        .confirmationDialog("Delete this scan?", isPresented: $showDiscardConfirmation, titleVisibility: .visible) {
            Button("Delete scan", role: .destructive) {
                Task { await model.discardPendingUpload() }
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The photos will be removed from this phone. This can't be undone.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Scan a room")
                .font(.title2.bold())
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("Stand in the middle, then follow the dots around you.")
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                Label {
                    Text(step.text).font(.body)
                } icon: {
                    Image(systemName: step.symbol)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Theme.accent)
                }
                .accessibilityLabel("Step \(index + 1): \(step.text)")
            }
        }
    }

    // MARK: - Banners

    private func bannerView(_ banner: StartBanner) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Image(systemName: banner.systemImage)
                .foregroundStyle(banner.tone.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(banner.message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                bannerActions(banner)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .transition(.opacity)
    }

    @ViewBuilder
    private func bannerActions(_ banner: StartBanner) -> some View {
        switch banner {
        case .cameraDenied:
            bannerButton("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        case .uploadFailed:
            bannerButton("Try again") { Task { await model.retryPendingUpload() } }
        case .parked:
            HStack(spacing: Theme.Space.s) {
                bannerButton("Try again") { Task { await model.retryPendingUpload() } }
                Button("Delete scan", role: .destructive) { showDiscardConfirmation = true }
                    .frame(minHeight: Theme.minTarget)
                    .tint(Theme.danger)
            }
        case .waiting:
            bannerButton("Upload now") { Task { await model.retryPendingUpload() } }
        case .cameraRestricted, .quotaReached, .scanFailed:
            EmptyView()
        }
    }

    private func bannerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(Theme.accent)
            .frame(minHeight: Theme.minTarget)
    }

    // MARK: - Start

    private var startBlock: some View {
        let state = model.startButton
        return VStack(spacing: Theme.Space.xs) {
            Button {
                Task { await model.startCapture() }
            } label: {
                Text(state.title)
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(state.isEnabled ? Theme.onAccent : Theme.textSecondary)
                    .background(state.isEnabled ? Theme.accent : Theme.surfaceInset, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!state.isEnabled)
            .accessibilityHint(state.isEnabled ? "Opens the camera and starts a guided scan." : "")
            if let hint = model.lowQuotaHint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Color.black)
    }
}

/// Just-in-time camera explanation before the system prompt (ui-spec 5.6).
private struct CameraPrimingView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: "camera")
                .font(.largeTitle)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("Allow camera access")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("VirtSpace uses the camera to take the photos for your scan. Photos are only taken while you scan.")
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onContinue) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(Theme.onAccent)
                    .background(Theme.accent, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Space.l)
        .presentationDetents([.medium])
    }
}
