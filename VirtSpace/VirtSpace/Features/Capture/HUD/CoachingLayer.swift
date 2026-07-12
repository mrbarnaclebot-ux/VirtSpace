//
//  CoachingLayer.swift
//  VirtSpace
//
//  Top-center coaching banners (spec §6.1: parallax coaching + graceful
//  degraded-tracking handling). One banner at a time, priority-ordered:
//    tracking degraded > drift hard-warn > drift soft-warn > exposure notice.
//  Sticky banners (tracking, hard drift) stay while the condition holds;
//  soft banners auto-dismiss and cool down; the exposure notice shows once.
//

import SwiftUI

struct CoachingBanner: Equatable, Identifiable {
    enum Kind: Equatable {
        case tracking
        case thermal
        case driftHard
        case driftSoft
        case exposure
    }

    let kind: Kind
    let text: String
    let systemImage: String
    let tint: Color
    let isSticky: Bool

    var id: Kind { kind }
}

struct CoachingLayer: View {
    let engine: CaptureEngine

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
    }

    private var conditions: Conditions {
        Conditions(
            trackingWarning: engine.warning,
            thermalWarming: CaptureEngine.showsWarmingBanner(for: engine.thermalState),
            driftTier: engine.driftMeters > AlignmentMath.driftHardWarnMeters ? 2
                : (engine.driftMeters > AlignmentMath.driftWarnMeters ? 1 : 0),
            wantsExposureNotice: engine.capturedCount > 0 && !engine.exposureLocked
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
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(banner.tint.opacity(0.45), lineWidth: 1))
                .padding(.horizontal, 24)
                .transition(.move(edge: .top).combined(with: .opacity))
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
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: banner)
        .onChange(of: conditions, initial: true) { _, new in
            reevaluate(new)
        }
    }

    private func reevaluate(_ c: Conditions) {
        // Priority ladder. Sticky banners drop out the moment their
        // condition clears.
        if let warning = c.trackingWarning {
            banner = CoachingBanner(
                kind: .tracking,
                text: warning,
                systemImage: "eye.trianglebadge.exclamationmark",
                tint: .yellow,
                isSticky: true
            )
            return
        }
        if c.thermalWarming {
            banner = CoachingBanner(
                kind: .thermal,
                text: "Phone is warming up — normal during capture",
                systemImage: "thermometer.medium",
                tint: .orange,
                isSticky: true
            )
            return
        }
        if c.driftTier == 2 {
            banner = CoachingBanner(
                kind: .driftHard,
                text: "Stay on your spot — step back to where you started",
                systemImage: "figure.walk.motion",
                tint: .orange,
                isSticky: true
            )
            return
        }
        if c.driftTier == 1 {
            if banner?.kind == .driftSoft { return } // already up, let it time out
            if Date() >= softDriftCooldownUntil {
                banner = CoachingBanner(
                    kind: .driftSoft,
                    text: "Try to pivot in place",
                    systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
                    tint: .cyan,
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
                text: "Couldn't lock exposure — lighting may vary between shots",
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
}
