//
//  ScanInstruction.swift
//  VirtSpace
//
//  The HUD's one line of "what to do now" (ui-spec 4.3): a direction while
//  the phone is off target, "Hold still" once aligned, nothing while the
//  photo is being taken (the reticle's check says it). Replaces the target
//  labels ("Horizon 3"), which meant nothing to users.
//

import Foundation

struct ScanInstruction: Equatable {
    let title: String
    /// Degrees still to go, shown small under the title.
    let detail: String?

    /// - Parameters:
    ///   - targetPitch: the current target's elevation (+90 ceiling, -90 floor).
    ///   - yawDelta: degrees to turn, > 0 = right (CaptureHUDState).
    ///   - pitchDelta: degrees to tilt, > 0 = up.
    ///   - firstScan: first-scan coaching is on (longer floor wording, 5.7).
    static func make(
        targetPitch: Double,
        yawDelta: Double,
        pitchDelta: Double,
        degreesAway: Double,
        isAligned: Bool,
        isCapturing: Bool,
        firstScan: Bool
    ) -> ScanInstruction? {
        if isCapturing { return nil }
        if isAligned { return ScanInstruction(title: "Hold still", detail: nil) }
        let detail = "\(Int(degreesAway.rounded()))°"
        let title: String
        if targetPitch >= 90 {
            title = "Point at the ceiling"
        } else if targetPitch <= -90 {
            title = firstScan ? "Point at the floor by your feet" : "Point at the floor"
        } else if abs(yawDelta) >= abs(pitchDelta) {
            title = yawDelta > 0 ? "Turn right" : "Turn left"
        } else {
            title = pitchDelta > 0 ? "Tilt up" : "Tilt down"
        }
        return ScanInstruction(title: title, detail: detail)
    }
}

/// At most one spoken announcement per `interval` (VoiceOver, ui-spec 4.3).
struct AnnouncementThrottle {
    var interval: TimeInterval = 2
    private var lastAt: Date?

    /// True (and records `now`) when enough time has passed since the last
    /// allowed announcement.
    mutating func allow(at now: Date = .now) -> Bool {
        if let lastAt, now.timeIntervalSince(lastAt) < interval { return false }
        lastAt = now
        return true
    }
}
