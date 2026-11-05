//
//  HUDCards.swift
//  VirtSpace
//
//  The glass cards that float over the camera: low light before shot 0,
//  lost place after an interruption, and the first-scan intro (ui-spec 4.3,
//  5.7). Buttons are at least 44 pt tall.
//

import SwiftUI

/// One card: symbol, title, body, one action.
struct HUDCard: View {
    let symbol: String
    let symbolTint: Color
    let title: String?
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: symbol)
                .font(.title)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(symbolTint)
                .accessibilityHidden(true)
            if let title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(message)
                .font(title == nil ? .body : .footnote)
                .foregroundStyle(.white.opacity(title == nil ? 1 : 0.8))
                .fixedSize(horizontal: false, vertical: true)
            Button(action: action) {
                Text(actionTitle)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, Theme.Space.l)
                    .frame(minHeight: Theme.minTarget)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
        }
        .multilineTextAlignment(.center)
        .padding(22)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.card))
        .padding(.horizontal, 40)
    }
}

extension HUDCard {
    /// AE pinned near its ceiling before shot 0 (spec §6.1). Clears by
    /// itself once the room is bright enough.
    static func lowLight(action: @escaping () -> Void) -> HUDCard {
        HUDCard(
            symbol: "lightbulb.max",
            symbolTint: .yellow,
            title: "It's too dark",
            message: "Turn on more lights for a sharper result.",
            actionTitle: "Scan anyway",
            action: action
        )
    }

    /// ARKit lost the room after an interruption and hasn't found it again.
    /// Withdrawn automatically if tracking recovers.
    static func lostPlace(action: @escaping () -> Void) -> HUDCard {
        HUDCard(
            symbol: "location.slash",
            symbolTint: Theme.warning,
            title: "Lost your place",
            message: "Point at what you were scanning. Or start over (this clears the photos so far).",
            actionTitle: "Start over",
            action: action
        )
    }

    /// Before shot 0 of the first scan (ui-spec 5.7).
    static func firstScanIntro(action: @escaping () -> Void) -> HUDCard {
        HUDCard(
            symbol: "scope",
            symbolTint: Theme.accent,
            title: nil,
            message: FirstScanCoach.introText,
            actionTitle: "Got it",
            action: action
        )
    }
}
