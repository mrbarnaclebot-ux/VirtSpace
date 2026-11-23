//
//  UploadOverlayView.swift
//  VirtSpace
//
//  Full-screen handoff shown the moment a scan finishes (ui-spec 4.4): a ring
//  counting photos uploaded ("12 of 28"), then "Finishing up…" with an
//  indeterminate indicator once every photo is up (depth maps and the
//  frames:done call still run after the last photo). On success the model
//  routes to the new space's Detail; on failure the start screen shows a banner.
//

import SwiftUI

struct UploadOverlayView: View {
    let uploaded: Int
    let total: Int
    /// First-scan finale ("That's everything."), shown above the ring.
    var lead: String?
    /// A room scan has no photo count: its stage line under a spinner.
    var message: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Phase: Equatable {
        case uploading(done: Int, total: Int)
        case finishing

        static func of(uploaded: Int, total: Int) -> Phase {
            total > 0 && uploaded >= total ? .finishing : .uploading(done: uploaded, total: total)
        }

        var title: String {
            switch self {
            case .uploading: "Uploading photos"
            case .finishing: "Finishing up…"
            }
        }

        /// "12 of 28" while counting; nil once finishing.
        var counter: String? {
            guard case .uploading(let done, let total) = self else { return nil }
            return "\(done) of \(total)"
        }
    }

    /// Honest until background uploads land (R25).
    static let subtitle = "Keep VirtSpace open until this finishes."

    private var phase: Phase { .of(uploaded: uploaded, total: total) }
    private var fraction: Double { total > 0 ? min(1, Double(uploaded) / Double(total)) : 0 }

    var body: some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()
            VStack(spacing: Theme.Space.l) {
                if let lead {
                    Text(lead)
                        .font(.title3.bold())
                        .foregroundStyle(Theme.success)
                }
                ring
                VStack(spacing: Theme.Space.xs) {
                    Text(message ?? phase.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .contentTransition(.opacity)
                    Text(Self.subtitle)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, Theme.Space.xl)
            .accessibilityElement(children: .combine)
            .animation(Theme.Motion.standard, value: phase)
        }
        .transition(.opacity)
        .onChange(of: phase == .finishing) { _, finishing in
            if finishing { AccessibilityNotification.Announcement(Phase.finishing.title).post() }
        }
    }

    @ViewBuilder
    private var ring: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 6)
            if message == nil, let counter = phase.counter {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(Theme.Motion.standard, value: fraction)
                Text(counter)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .animation(Theme.Motion.quick, value: uploaded)
            } else if reduceMotion {
                // No repeating animation under Reduce Motion: a static mark.
                Image(systemName: "ellipsis")
                    .font(.title2.bold())
                    .foregroundStyle(Theme.accent)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.accent)
            }
        }
        .frame(width: 118, height: 118)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

#Preview {
    UploadOverlayView(uploaded: 12, total: 28)
        .preferredColorScheme(.dark)
}
