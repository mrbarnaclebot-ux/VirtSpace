//
//  OnboardingView.swift
//  VirtSpace
//
//  First-launch flow (ui-spec 5, pages 1 to 5): Welcome, How to scan
//  (3 pages, skippable), then Terms + consent (required). Presented by
//  ContentView as a full-screen cover while consent is not current. When only
//  the terms version changed, it opens straight on the terms page.
//
//  `HowToScanView` is also the Settings "How to scan" page (WP5):
//    NavigationLink("How to scan") { HowToScanView() }
//

import SwiftUI

struct OnboardingView: View {
    let store: OnboardingStore

    private enum Step { case welcome, howTo, terms }
    @State private var step: Step

    init(store: OnboardingStore) {
        self.store = store
        _step = State(initialValue: store.gate == .termsOnly ? .terms : .welcome)
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            // Opacity only, so it is already the Reduce Motion form.
            content.transition(.opacity)
        }
        .animation(Theme.Motion.standard, value: step)
        .tint(Theme.accent)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            WelcomePage(onContinue: { step = .howTo }, onSkip: { step = .terms })
        case .howTo:
            HowToScanView(onFinish: { step = .terms }, onSkip: { step = .terms })
        case .terms:
            TermsView(onAgree: { store.accept() })
        }
    }
}

// MARK: - Page 1: Welcome

private struct WelcomePage: View {
    let onContinue: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SkipBar(action: onSkip)
            OnboardingPage(step: .welcome)
            OnboardingButton(title: "Continue", action: onContinue)
                .padding(Theme.Space.m)
        }
    }
}

// MARK: - Pages 2 to 4: How to scan

/// The three how-to pages in a paged `TabView`. Onboarding passes both
/// closures. Settings passes neither: there is no Skip, and the last button
/// reads "Done" and dismisses (pops) the page.
struct HowToScanView: View {
    var onFinish: (() -> Void)?
    var onSkip: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0

    private let steps = OnboardingStep.howTo
    private var isLast: Bool { page == steps.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            if let onSkip { SkipBar(action: onSkip) }
            TabView(selection: $page) {
                ForEach(steps.indices, id: \.self) { index in
                    OnboardingPage(step: steps[index], isCurrent: page == index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            OnboardingButton(title: isLast && onFinish == nil ? "Done" : "Next", action: advance)
                .padding(Theme.Space.m)
        }
        .background(Theme.bg)
    }

    private func advance() {
        guard isLast else {
            withAnimation(reduceMotion ? nil : Theme.Motion.standard) { page += 1 }
            return
        }
        if let onFinish { onFinish() } else { dismiss() }
    }
}

// MARK: - Page content

struct OnboardingStep {
    let symbol: String
    let title: String
    let message: String
    /// Welcome draws its symbol on once; the how-to symbols bounce once.
    var drawsOn = false

    static let welcome = OnboardingStep(
        symbol: "cube.transparent",
        title: "Turn any room into a 3D space",
        message: "Scan a room with your iPhone, then walk through it in 3D.",
        drawsOn: true
    )

    static let howTo = [
        OnboardingStep(
            symbol: "figure.stand",
            title: "Stand in the middle of the room",
            message: "You'll stay on this spot for the whole scan, about 2 minutes."
        ),
        OnboardingStep(
            symbol: "arrow.trianglehead.2.clockwise.rotate.90",
            title: "Turn the phone, not your feet",
            message: "Hold your phone at chest height and turn in place, keeping the phone over the same spot. Follow the dots."
        ),
        OnboardingStep(
            symbol: "lightbulb.max",
            title: "Turn on the lights",
            message: "Bright, even light gives the sharpest result. Keep people and pets out of the room."
        ),
    ]
}

/// One scrollable page: symbol, title, message. Scrolls at large text sizes.
private struct OnboardingPage: View {
    let step: OnboardingStep
    var isCurrent = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                OnboardingSymbol(step: step, isCurrent: isCurrent)
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(step.title)
                        .font(.title2.bold())
                        .foregroundStyle(Theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(step.message)
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.m)
            // Clears the page indicator that floats over the bottom edge.
            .padding(.bottom, Theme.Space.xxl)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// The page symbol plus its one animation on appear. Static under Reduce Motion.
private struct OnboardingSymbol: View {
    let step: OnboardingStep
    let isCurrent: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var scaledSize: CGFloat = 64
    @State private var drawn = false
    @State private var bounces = 0

    private var size: CGFloat { min(scaledSize, 120) }

    var body: some View {
        ZStack(alignment: .leading) {
            if drawn || !step.drawsOn {
                Image(systemName: step.symbol)
                    .font(.system(size: size))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.bounce, value: bounces)
                    .transition(.symbolEffect(.drawOn))
            }
        }
        .frame(height: size * 1.25, alignment: .leading)
        .accessibilityHidden(true)
        .task(id: isCurrent) { play() }
    }

    private func play() {
        guard isCurrent else { return }
        if step.drawsOn {
            withAnimation(reduceMotion ? nil : Theme.Motion.standard) { drawn = true }
        } else if !reduceMotion {
            bounces += 1
        }
    }
}

// MARK: - Shared controls

/// Top-trailing "Skip": jumps to the terms page.
private struct SkipBar: View {
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("Skip", action: action)
                .font(.body)
                .frame(minWidth: Theme.minTarget, minHeight: Theme.minTarget)
        }
        .padding(.horizontal, Theme.Space.m)
    }
}

/// Full-width accent capsule, at least 50 pt high (ui-spec 4.2 primary button).
struct OnboardingButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.onAccent)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Theme.accent, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    OnboardingView(store: OnboardingStore(defaults: UserDefaults(suiteName: "preview")!))
}
