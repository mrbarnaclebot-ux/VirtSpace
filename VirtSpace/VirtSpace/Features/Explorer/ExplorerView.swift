//
//  ExplorerView.swift
//  VirtSpace
//
//  Explore in 3D (ui-spec 4.7): a full-screen WKWebView running the bundled
//  Spark viewer (ExplorerWebView), with native chrome on top. The cover owns
//  the whole loading arc: one screen, two labelled steps (download, then
//  open; ExplorerLoadPhase). Also an error state with one recovery button, a
//  glass close button plus the space title, and a one-time coach anchored
//  above the in-page joystick. Always dark; status bar hidden and the idle
//  timer off while presented.
//

import OSLog
import SwiftUI

struct ExplorerView: View {
    /// Where the space's file comes from. `.file` is already local (bundled
    /// fixture or pre-downloaded); `.remote` downloads through SplatCache as
    /// step 1 of the loading screen.
    enum SplatSource: Equatable {
        case file(URL)
        case remote(worldId: String, version: Int, tier: String, url: URL)
    }

    let source: SplatSource
    let title: String

    @Environment(\.dismiss) private var dismiss

    @State private var phase = ExplorerLoadPhase.start
    @State private var splatFileURL: URL?
    @State private var reloadToken = 0
    @State private var showCoach: Bool
    @State private var stickFrame: CGRect?

    static let coachKey = "explorer.coachSeen.v1"

    init(source: SplatSource, title: String = "") {
        self.source = source
        self.title = title
        _showCoach = State(initialValue: !UserDefaults.standard.bool(forKey: Self.coachKey))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let splatFileURL {
                ExplorerWebView(splatURL: splatFileURL, onMessage: handle)
                    .id(reloadToken)
                    .ignoresSafeArea()
            }
            if phase.isLoading {
                ExplorerLoadingView(phase: phase)
                    .transition(.opacity)
            }
            if case .failed(let failure) = phase {
                ViewerErrorView(title: failure.title, message: failure.message,
                                buttonTitle: failure.buttonTitle, action: reload)
                    .transition(.opacity)
            }
            if showCoach && phase == .ready {
                ExplorerCoach(stickFrame: stickFrame)
                    .transition(.opacity)
            }
            topBar
        }
        .animation(Theme.Motion.standard, value: phase)
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task(id: reloadToken) { await prepare() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var topBar: some View {
        HStack(spacing: Theme.Space.s) {
            ViewerIconButton(systemName: "xmark", label: "Close") { dismiss() }
            if !title.isEmpty {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .padding(.horizontal, Theme.Space.m)
                    .frame(minHeight: Theme.minTarget)
                    .glassEffect(.regular, in: .capsule)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.top, Theme.Space.s)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Load

    private func prepare() async {
        switch source {
        case .file(let url):
            splatFileURL = url
            phase = phase.applying(.downloaded)
        case .remote(let worldId, let version, let tier, let url):
            do {
                splatFileURL = try await SplatCache.shared.ensure(
                    worldId: worldId, version: version, tier: tier, remoteURL: url,
                    bytes: { received, expected in
                        Task { @MainActor in report(.downloadProgress(received, expected)) }
                    }
                )
                report(.downloaded)
            } catch {
                guard !Task.isCancelled else { return }
                AppLog.viewer.error("Explorer download failed: \(error.localizedDescription, privacy: .public)")
                report(.failed(ViewerErrorCopy.message(for: error)))
            }
        }
    }

    private func report(_ event: ExplorerEvent) {
        phase = phase.applying(event)
    }

    private func handle(_ message: ExplorerWebView.Message) {
        switch message {
        case .phase(let event): report(event)
        case .interaction: dismissCoach()
        case .stickFrame(let frame): stickFrame = frame
        }
    }

    /// Error-state button: a fresh web view and, if needed, a fresh download.
    private func reload() {
        phase = .start
        splatFileURL = nil
        reloadToken += 1
    }

    private func dismissCoach() {
        guard showCoach else { return }
        withAnimation(Theme.Motion.exit) { showCoach = false }
        UserDefaults.standard.set(true, forKey: Self.coachKey)
    }
}

// MARK: - Loading

/// "Opening your space" with the two steps. The current step shows its own
/// bar (determinate when measured) and the other step a done or waiting mark.
private struct ExplorerLoadingView: View {
    let phase: ExplorerLoadPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(ExplorerLoadPhase.title)
                .font(.title2.bold())
            stepRow(1, label: phase.downloadLabel)
            stepRow(2, label: ExplorerLoadPhase.openingLabel)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: 360)
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.001)) // stays above the transparent web view
    }

    private func stepRow(_ step: Int, label: String) -> some View {
        let current = phase.step ?? 0
        let state: StepState = step < current ? .done : (step == current ? .active : .waiting)
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                marker(state)
                    .frame(width: 24)
                Text(label)
                    .font(.body)
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .foregroundStyle(state == .waiting ? Theme.textSecondary : Theme.textPrimary)
            }
            if state == .active, let fraction = phase.fraction {
                ProgressView(value: fraction)
                    .tint(Theme.accent)
                    .animation(Theme.Motion.standard, value: fraction)
                    .padding(.leading, 24 + Theme.Space.s)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(state.spoken)
    }

    @ViewBuilder
    private func marker(_ state: StepState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case .active:
            ViewerSpinner()
        case .waiting:
            Image(systemName: "circle").foregroundStyle(Theme.textTertiary)
        }
    }

    private enum StepState {
        case done, active, waiting

        var spoken: String {
            switch self {
            case .done: "Done"
            case .active: "In progress"
            case .waiting: "Not started"
            }
        }
    }
}

// MARK: - Coach

/// One-time "how to move" capsule, 24 pt above the joystick (its frame comes
/// from the page). Touches pass through; the first drag in the page hides it.
private struct ExplorerCoach: View {
    let stickFrame: CGRect?

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                capsule
                Color.clear.frame(height: max(0, geo.size.height - stickTop(in: geo.size) + Theme.Space.l))
            }
            .frame(maxWidth: .infinity)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Fallback before the page reports: the stick's CSS position (120 pt,
    /// 28 pt above the bottom safe area), roughly.
    private func stickTop(in size: CGSize) -> CGFloat {
        stickFrame?.minY ?? size.height - 182
    }

    private var capsule: some View {
        ViewThatFits {
            HStack(spacing: Theme.Space.l) { items }
            VStack(alignment: .leading, spacing: Theme.Space.xs) { items }
        }
        .padding(.vertical, Theme.Space.s)
        .padding(.horizontal, Theme.Space.l)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, Theme.Space.m)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    @ViewBuilder
    private var items: some View {
        Label("Drag to look around", systemImage: "hand.draw")
        Label("Use the stick to walk", systemImage: "dpad")
    }
}
