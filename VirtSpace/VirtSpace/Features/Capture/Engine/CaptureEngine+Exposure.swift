//
//  CaptureEngine+Exposure.swift
//  VirtSpace
//
//  Exposure lock lifecycle (spec §10 R34/R38): AE is metered while tracking
//  initialises and locked once target 0 is up, with the low-light preflight
//  holding the lock while AE is pinned near its ceiling. Engine queue only.
//

import Foundation
import OSLog

nonisolated extension CaptureEngine {
    /// A lock whose "applied" callback never comes must not wedge the dwell.
    static let exposureApplyTimeout: TimeInterval = 0.5

    /// The user chose to scan despite the low-light warning.
    func continueInLowLight() {
        queue.async { [weak self] in self?.lowLightAcknowledged = true }
    }

    // MARK: - Engine queue: exposure lock

    /// Per pose while metering: hold the lock in low light (unless the user
    /// chose to continue), otherwise lock.
    func meterOrLockExposure() {
        guard exposurePhase == .metering else { return }
        if meter.isTooDark, !lowLightAcknowledged {
            if !isShowingLowLight {
                isShowingLowLight = true
                AppLog.engine.log("Low light before shot 0: holding the exposure lock")
                publish { $0.isTooDark = true }
            }
        } else {
            if isShowingLowLight {
                isShowingLowLight = false
                publish { $0.isTooDark = false }
            }
            lockExposure()
        }
    }

    /// Lock AE/AWB to the preroll's median exposure. Called once target 0 is
    /// up; the dwell is gated until `finishExposureLock`.
    private func lockExposure() {
        guard let source, let target = meter.lockTarget else {
            finishExposureLock(false)
            return
        }
        exposurePhase = .locking
        let sessionID = session?.id
        let applied: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard self.running, self.session?.id == sessionID, self.exposurePhase == .locking else { return }
                self.finishExposureLock(true)
            }
        }
        guard source.lockExposure(iso: target.iso, duration: target.duration, onApplied: applied) else {
            finishExposureLock(false)
            return
        }
        queue.asyncAfter(deadline: .now() + Self.exposureApplyTimeout, execute: applied)
    }

    private func finishExposureLock(_ locked: Bool) {
        exposurePhase = .locked
        shots.exposureLocked = locked
        AppLog.engine.log("Exposure lock before shot 0: \(locked ? "locked" : "unavailable", privacy: .public)")
        publish { $0.exposureLocked = locked }
    }
}
