//
//  FirstScanCoach.swift
//  VirtSpace
//
//  First-scan coaching (ui-spec 5.7): which one-time tip the scan HUD shows,
//  decided from the shot count and drift alone. Active on every scan until
//  one finishes; finishing sets `defaultsKey` and coaching never shows again
//  (Settings > Developer can clear the key to replay it).
//

import Foundation

struct FirstScanCoach: Equatable {
    enum Tip: Equatable {
        /// Before shot 0: a glass card with "Got it".
        case intro
        /// After shot 1, for `tipDuration`.
        case nextDot
        /// The first drift past the soft gate, for `tipDuration`, plus one
        /// pulse on the pivot indicator.
        case drift
        /// The last shot landed.
        case finished

        /// Banner copy for the tips shown in the coaching layer; nil for the
        /// intro card and the finale, which have their own surfaces.
        var bannerText: String? {
            switch self {
            case .nextDot: "Nice. Now turn to the next dot."
            case .drift: "Keep the phone over the same spot. The dot below shows where it is."
            case .intro, .finished: nil
            }
        }
    }

    /// UserDefaults flag: true once a coached scan has finished.
    static let defaultsKey = "onboarding.firstScanCoached"
    static let tipDuration: Duration = .seconds(3)
    static let introText = "Point at the blue dot and hold still. The photo takes itself."
    static let finishedText = "That's everything."

    private(set) var isActive = false
    private(set) var tip: Tip?
    private var didShowDrift = false

    /// A scan starts. `firstScan` is true while the flag is unset.
    mutating func begin(firstScan: Bool) {
        self = FirstScanCoach()
        isActive = firstScan
        tip = firstScan ? .intro : nil
    }

    /// The user tapped "Got it", or a timed tip ran out.
    mutating func dismiss(_ tip: Tip) {
        if self.tip == tip { self.tip = nil }
    }

    mutating func shotsChanged(captured: Int, total: Int) {
        guard isActive else { return }
        if total > 0, captured >= total {
            tip = .finished
        } else if captured == 1 {
            tip = .nextDot
        } else if captured > 1, tip == .intro {
            tip = nil
        }
    }

    /// `pastSoftGate`: drift is beyond the soft warning distance.
    mutating func driftChanged(pastSoftGate: Bool) {
        guard isActive, pastSoftGate, !didShowDrift, tip != .finished else { return }
        didShowDrift = true
        tip = .drift
    }
}
