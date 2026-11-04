//
//  Theme.swift
//  VirtSpace
//
//  Design tokens (docs/design/ui-spec.md section 2): semantic colors, spacing,
//  radii, motion. Static members only, no token framework. Read them as
//  `Theme.accent`, `Theme.Space.m`, `Theme.Radius.card`, `Theme.Motion.quick`.
//

import SwiftUI
import UIKit

enum Theme {
    // MARK: Color (2.1)

    /// Screens.
    static let bg = Color(uiColor: .systemBackground)
    /// Cards, sections.
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    /// Placeholders, progress tracks.
    static let surfaceInset = Color(uiColor: .tertiarySystemFill)
    static let textPrimary = Color(uiColor: .label)
    /// Meta, captions.
    static let textSecondary = Color(uiColor: .secondaryLabel)
    /// Dividers and icons only. Fails contrast for text.
    static let textTertiary = Color(uiColor: .tertiaryLabel)
    /// Primary actions, current target, links. 5.4:1 on white, 12:1 on black.
    static let accent = Color(light: 0x0071A4, dark: 0x64D2FF)
    /// Label on accent fills.
    static let onAccent = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : .white })
    static let success = Color(uiColor: .systemGreen)
    static let warning = Color(uiColor: .systemOrange)
    static let danger = Color(uiColor: .systemRed)
    /// Behind full-screen overlays on the camera.
    static let scrim = Color.black.opacity(0.6)

    // MARK: Spacing, radii, targets (2.3)

    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    enum Radius {
        /// Small surfaces, thumbnails inside cards.
        static let small: CGFloat = 12
        /// Cards, sections.
        static let card: CGFloat = 20
    }

    /// Minimum touch target edge, everywhere.
    static let minTarget: CGFloat = 44

    // MARK: Motion (2.4)

    /// Under Reduce Motion, swap move/scale/blur for an opacity crossfade at
    /// the call site; these curves stay the same.
    enum Motion {
        /// Pills, toggles, small state swaps.
        static let quick = Animation.snappy(duration: 0.2)
        /// Appear/disappear, overlays, progress values.
        static let standard = Animation.smooth(duration: 0.35)
        /// Shot confirmation, space-ready moment.
        static let emphasis = Animation.spring(duration: 0.45, bounce: 0.2)
        /// Dismissals.
        static let exit = Animation.easeOut(duration: 0.2)
    }
}

/// The three status meanings (2.1) plus neutral. Color is never the only
/// signal: pair it with a word and a symbol.
enum Tone: Equatable, Sendable {
    case progress, success, warning, danger, neutral

    var color: Color {
        switch self {
        case .progress: Theme.accent
        case .success: Theme.success
        case .warning: Theme.warning
        case .danger: Theme.danger
        case .neutral: Theme.textSecondary
        }
    }
}

private extension Color {
    /// A dynamic color from two 0xRRGGBB values.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
