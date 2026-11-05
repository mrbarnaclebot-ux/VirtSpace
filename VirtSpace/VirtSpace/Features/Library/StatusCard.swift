//
//  StatusCard.swift
//  VirtSpace
//
//  Detail's status surfaces (ui-spec 4.6, 7.4): the 3-step build list while
//  a space is being built, the status card (failed, improving, unknown) with
//  its Try again button, and the Improve quality card on a ready space.
//

import SwiftUI

// MARK: - Step list

/// Uploading photos / Combining photos / Building your space. Done steps get
/// a check, the current one an indicator and its bar, future ones are grey.
struct StepList: View {
    let world: World
    var upload: UploadProgress?
    var pollsFailing = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let p = world.status.presentation(hasLocalUpload: upload != nil)
        let current = p.step ?? 1
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(Array(StatusPresentation.steps.enumerated()), id: \.offset) { index, label in
                row(label, step: index + 1, current: current, p: p)
            }
            Text("Usually 1 to 2 minutes. You can leave this screen.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            if world.status.isSlow(heartbeatAt: world.heartbeatAt, pollsFailing: pollsFailing) {
                Text("Taking longer than usual")
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .animation(reduceMotion ? nil : Theme.Motion.standard, value: current)
    }

    private func row(_ label: String, step: Int, current: Int, p: StatusPresentation) -> some View {
        let state: StepState = step < current ? .done : (step == current ? .current : .future)
        return HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            StepMarker(state: state)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(label)
                    .font(.subheadline.weight(state == .current ? .semibold : .regular))
                    .foregroundStyle(state == .future ? Theme.textSecondary : Theme.textPrimary)
                if state == .current {
                    currentDetail(p)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(state.spoken)")
    }

    @ViewBuilder private func currentDetail(_ p: StatusPresentation) -> some View {
        if let text = upload.map({ "\($0.uploaded) of \($0.total)" }) ?? p.detail {
            Text(text)
                .font(.footnote)
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(Theme.textSecondary)
        }
        SpaceProgress(kind: ProgressKind(world: world, upload: upload))
            .id(world.status)
    }
}

enum StepState {
    case done, current, future

    var spoken: String {
        switch self {
        case .done: "done"
        case .current: "in progress"
        case .future: "not started"
        }
    }
}

/// Check (drawn on when a step finishes), indicator, or empty circle.
struct StepMarker: View {
    let state: StepState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
                    .transition(reduceMotion ? .identity : AnyTransition(.symbolEffect(.drawOn)))
            case .current:
                if reduceMotion {
                    Image(systemName: "circle.dotted").foregroundStyle(Theme.accent)
                } else {
                    ProgressView().controlSize(.small)
                }
            case .future:
                Image(systemName: "circle").foregroundStyle(Theme.textTertiary)
            }
        }
        .font(.body)
        .frame(width: 22)
        .accessibilityHidden(true)
    }
}

// MARK: - Status card

/// The card for a failed, improving or unknown status, with Try again when
/// the status offers a retry. Never optimistic: `isRetrying` comes from the
/// screen while the request runs.
struct StatusCard: View {
    let presentation: StatusPresentation
    var isRetrying = false
    /// Stale server heartbeat while improving (never while polls fail).
    var isSlow = false
    /// "You've used today's scans. More at 4:00 PM." after a 429.
    var quotaNote: String?
    var onRetry: (() -> Void)?
    /// `failed_upload` with the scan still on this phone.
    var onGoToScan: (() -> Void)?

    private var tone: Tone {
        presentation.tone == .success ? presentation.noteTone : presentation.tone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let detail = presentation.detail {
                Label {
                    Text(detail).foregroundStyle(Theme.textPrimary)
                } icon: {
                    Image(systemName: tone == .progress ? presentation.symbol : "exclamationmark.triangle.fill")
                        .foregroundStyle(tone.color)
                }
                .font(.subheadline)
            }
            if tone == .progress {
                IndeterminateBar()
            }
            if isSlow {
                Text("Taking longer than usual").font(.footnote).foregroundStyle(Theme.warning)
            }
            if let quotaNote {
                Text(quotaNote).font(.footnote).foregroundStyle(Theme.warning)
            }
            retryButton
            if let onGoToScan {
                Button("Go to Scan", action: onGoToScan)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    @ViewBuilder private var retryButton: some View {
        if let retry = presentation.retry, let onRetry {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Button(action: onRetry) {
                    BusyLabel(title: "Try again", busyTitle: "Trying again…", isBusy: isRetrying)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isRetrying || quotaNote != nil)
                if retry == .usesScan {
                    Text("Uses 1 of today's scans")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}

/// "Improve quality" on a ready space (ui-spec 4.6). Opens the sheet.
struct ImproveCard: View {
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Improve quality").font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Theme.Space.s) { text; Spacer(minLength: 0); button }
                VStack(alignment: .leading, spacing: Theme.Space.s) { text; button }
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private var text: some View {
        Text("Build a sharper version. Takes about 5 to 10 minutes.")
            .font(.subheadline)
            .foregroundStyle(Theme.textSecondary)
    }

    private var button: some View {
        Button("Start", action: onStart)
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityHint("Opens details about improving quality")
    }
}

/// A button label that crossfades to a spinner while the request runs.
struct BusyLabel: View {
    let title: String
    let busyTitle: String
    let isBusy: Bool

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            if isBusy {
                ProgressView().controlSize(.small)
            }
            Text(isBusy ? busyTitle : title)
        }
        .animation(Theme.Motion.standard, value: isBusy)
    }
}
