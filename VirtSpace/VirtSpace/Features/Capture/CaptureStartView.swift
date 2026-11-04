//
//  CaptureStartView.swift
//  VirtSpace
//
//  The capture screen's idle / failed state: intro copy, the quota gate, the
//  Start button, and the pending-upload affordances. Layout only — every
//  decision lives in CaptureScreenModel.
//

import SwiftUI

struct CaptureStartView: View {
    let model: CaptureScreenModel
    /// The last capture's failure message, if it failed.
    let failure: String?

    @State private var showDiscardConfirmation = false

    var body: some View {
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
            if model.isQuotaExhausted {
                quotaLimitNotice
            }
            startButton
            if let hint = model.lowQuotaHint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
            }
            if model.pendingUpload.hasPending {
                pendingUploadControls
            }
            Spacer()
            #if DEBUG
            CaptureDebugToolsView(model: model)
            #endif
        }
        .task { await model.startScreenAppeared() }
    }

    private var startButton: some View {
        Button {
            Task { await model.startCapture() }
        } label: {
            Label(failure == nil ? "Start capture" : "Try again", systemImage: "camera.fill")
                .font(.headline)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(model.isQuotaExhausted ? Color.gray.opacity(0.4) : Color.cyan, in: Capsule())
                .foregroundStyle(.black)
        }
        .disabled(model.isQuotaExhausted)
    }

    /// Pending-upload affordances. A session that has burned its automatic
    /// retry budget is PARKED: nothing retries it in the background any more
    /// (each retry can mint a billable world — spec §10 R4), so the choice is
    /// handed to the user explicitly.
    private var pendingUploadControls: some View {
        VStack(spacing: 10) {
            if model.pendingUpload.hasParked {
                Text("Upload paused after \(CaptureStore.Manifest.maxAutomaticAttempts) failed attempts. Your scan is still saved on this device.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }
            Button {
                Task { await model.retryPendingUpload() }
            } label: {
                Label("Retry upload", systemImage: "arrow.up.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.cyan)
            }
            if model.pendingUpload.hasParked {
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
                Task { await model.discardPendingUpload() }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("The captured frames are deleted from this device and can't be recovered.")
        }
    }

    /// Full-width, friendly heads-up shown when the day's scans are used up.
    private var quotaLimitNotice: some View {
        VStack(spacing: 6) {
            Text("Daily scan limit reached\(model.quotaResetLabel)")
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
}
