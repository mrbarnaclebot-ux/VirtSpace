//
//  CoachingLayer.swift
//  VirtSpace
//
//  Top-center coaching banners (spec §6.1: parallax coaching + graceful
//  degraded-tracking handling). One banner at a time, priority-ordered:
//    tracking > thermal > drift hard-warn > first-scan tip > drift soft-warn
//    > exposure notice.
//  Sticky banners (tracking, thermal, hard drift, the first-scan tip) stay
//  while the condition holds; soft banners auto-dismiss and cool down; the
//  exposure notice shows once. Hard drift plays a warning haptic once per
//  episode (ui-spec 2.5).
//

import SwiftUI

struct CoachingBanner: Equatable, Identifiable {
    enum Kind: Equatable {
        case tracking
        case thermal
        case driftHard
        case driftSoft
        case exposure
        /// A first-scan coaching tip (FirstScanCoach times it out).
        case coach
    }

    let kind: Kind
    let text: String
    let systemImage: String
    let tint: Color
    let isSticky: Bool

    var id: Kind { kind }
}

struct CoachingLayer: View {
    let hud: CaptureHUDState
    /// Banner text of the current first-scan tip, if any.
    var coachTip: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var banner: CoachingBanner?
    @State private var softDriftCooldownUntil = Date.distantPast
    @State private var exposureNoticeConsumed = false

    /// Cheap Equatable snapshot of everything the priority logic reads, so
    /// `.onChange` fires only on meaningful transitions (not per frame).
    private struct Conditions: Equatable {
        let trackingWarning: String?
        /// True at `.serious` thermal state (deliverable 2e). `.critical` is
        /// handled by the full-screen pause UI, not a banner.
        let thermalWarming: Bool
        let driftTier: Int // 0 none, 1 soft, 2 hard
        let wantsExposureNotice: Bool
        let coachTip: String?
    }

    private var conditions: Conditions {
        Conditions(
            trackingWarning: hud.warning,
            thermalWarming: ThermalGovernor.showsWarmingBanner(for: hud.thermalState),
            driftTier: hud.driftMeters > AlignmentMath.driftHardWarnMeters ? 2
                : (hud.driftMeters > AlignmentMath.driftWarnMeters ? 1 : 0),
            wantsExposureNotice: hud.capturedCount > 0 && !hud.exposureLocked,
            coachTip: coachTip
        )
    }

    var body: some View {
        ZStack {
            if let banner {
                HStack(spacing: 9) {
                    Image(systemName: banner.systemImage)
                        .foregroundStyle(banner.tint)
                    Text(banner.text)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal, 24)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .task(id: banner.id) {
                    guard !banner.isSticky else { return }
                    try? await Task.sleep(for: .seconds(3.2))
                    if self.banner?.id == banner.id {
                        if banner.kind == .driftSoft {
                            softDriftCooldownUntil = Date().addingTimeInterval(8)
                        }
                        self.banner = nil
                    }
                }
            }
        }
        .animation(Theme.Motion.standard, value: banner)
        .sensoryFeedback(.warning, trigger: banner?.kind) { old, new in
            new == .driftHard && old != .driftHard
        }
        .onChange(of: conditions, initial: true) { _, new in
            reevaluate(new)
        }
    }

    private func reevaluate(_ c: Conditions) {
        // Priority ladder. Sticky banners drop out the moment their
        // condition clears.
        if let sticky = Self.stickyBanner(for: c) {
            banner = sticky
            return
        }
        if c.driftTier == 1 {
            if banner?.kind == .driftSoft { return } // already up, let it time out
            if Date() >= softDriftCooldownUntil {
                banner = CoachingBanner(
                    kind: .driftSoft,
                    text: "Keep the phone over the same spot",
                    systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
                    tint: Theme.accent,
                    isSticky: false
                )
            } else if banner?.isSticky == true {
                banner = nil
            }
            return
        }
        if c.wantsExposureNotice, !exposureNoticeConsumed {
            exposureNoticeConsumed = true
            banner = CoachingBanner(
                kind: .exposure,
                text: "Lighting may change between photos. Avoid switching lights on or off.",
                systemImage: "sun.max.trianglebadge.exclamationmark",
                tint: .yellow,
                isSticky: false
            )
            return
        }
        // No condition: clear sticky banners; transient ones finish their
        // own timeout.
        if banner?.isSticky == true {
            banner = nil
        }
    }

    /// The top four rungs: banners that stay up while their condition holds.
    private static func stickyBanner(for c: Conditions) -> CoachingBanner? {
        let rung: (CoachingBanner.Kind, String, String, Color)
        if let warning = c.trackingWarning {
            rung = (.tracking, warning, "eye.trianglebadge.exclamationmark", .yellow)
        } else if c.thermalWarming {
            rung = (.thermal, "Your phone is getting warm. That's normal.", "thermometer.medium", .orange)
        } else if c.driftTier == 2 {
            rung = (.driftHard, "You've moved. Step back to where you started.", "figure.walk.motion", .orange)
        } else if let tip = c.coachTip {
            rung = (.coach, tip, "hand.point.up.left", Theme.accent)
        } else {
            return nil
        }
        return CoachingBanner(kind: rung.0, text: rung.1, systemImage: rung.2, tint: rung.3, isSticky: true)
    }
}
