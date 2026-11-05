//
//  StatusPill.swift
//  VirtSpace
//
//  The status pill (ui-spec 7.4): word + symbol + color, never color alone,
//  plus the small waiting indicators the Library and Detail share. Every
//  repeating animation stops under Reduce Motion (ui-spec 2.4).
//

import SwiftUI

struct StatusPill: View {
    let presentation: StatusPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tint = presentation.tone.color
        HStack(spacing: Theme.Space.xxs) {
            if presentation.isInProgress {
                PulsingDot(color: tint)
            }
            Image(systemName: presentation.symbol)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            Text(presentation.pill)
                .contentTransition(.interpolate)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, Theme.Space.xs)
        .padding(.vertical, Theme.Space.xxs)
        .background(tint.opacity(0.14), in: Capsule())
        .animation(Theme.Motion.quick, value: presentation)
        .fixedSize()
    }
}

/// The pill plus its secondary note ("High quality", "Quality upgrade
/// failed"). Wraps to a column at large text sizes.
struct StatusBadge: View {
    let presentation: StatusPresentation

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.xs) { content }
            VStack(alignment: .trailing, spacing: Theme.Space.xxs) { content }
        }
    }

    @ViewBuilder private var content: some View {
        StatusPill(presentation: presentation)
        if let note = presentation.note {
            Text(note)
                .font(.caption)
                .foregroundStyle(presentation.noteTone == .neutral ? Theme.textSecondary : presentation.noteTone.color)
        }
    }
}

/// The in-progress dot: pulses while work runs, static under Reduce Motion.
struct PulsingDot: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .pulsing(!reduceMotion)
            .accessibilityHidden(true)
    }
}

/// Indeterminate bar for estimated work (ui-spec 7.3 rule 2). Under Reduce
/// Motion it is not drawn at all: the step text and pill already say it is
/// working, and a static segment would read as a real percentage.
struct IndeterminateBar: View {
    var tint: Color = Theme.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !reduceMotion {
            Capsule()
                .fill(Theme.surfaceInset)
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(tint)
                            .frame(width: geo.size.width * 0.3)
                            .phaseAnimator([false, true]) { bar, end in
                                bar.offset(x: end ? geo.size.width * 0.7 : 0)
                            } animation: { _ in .easeInOut(duration: 1.1) }
                    }
                }
                .clipShape(Capsule())
                .accessibilityHidden(true)
        }
    }
}

/// Determinate bar for measured work (upload count, stitch). Keyed by its
/// step at the call site so a new step starts a new bar, never runs one
/// backwards (ui-spec 7.3 rule 3).
struct MeasuredBar: View {
    let fraction: Double
    var tint: Color = Theme.accent

    var body: some View {
        ProgressView(value: min(max(fraction, 0), 1))
            .tint(tint)
            .animation(Theme.Motion.standard, value: fraction)
            .accessibilityHidden(true)
    }
}

extension View {
    /// A slow opacity pulse (the one allowed looping indicator while real
    /// waiting happens). Pass false under Reduce Motion.
    @ViewBuilder func pulsing(_ active: Bool) -> some View {
        if active {
            phaseAnimator([1.0, 0.35]) { view, opacity in
                view.opacity(opacity)
            } animation: { _ in .easeInOut(duration: 0.9) }
        } else {
            self
        }
    }
}
