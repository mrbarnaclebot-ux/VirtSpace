//
//  CaptureEngine+Relocalization.swift
//  VirtSpace
//
//  Recovery after an ARKit interruption (R31/R39): while tracking
//  relocalizes, offer "Restart scan" past a timeout. Engine queue only,
//  except `restart()`, which hops onto it.
//

import Foundation
import OSLog

nonisolated extension CaptureEngine {
    static let relocalizationTimeout: TimeInterval = 10

    /// Discard the scan and start a fresh one — offered when ARKit can't
    /// relocalize after an interruption. Goes through `.idle` exactly like
    /// cancel-then-Start, so the camera layer's lifecycle is the one the
    /// cancel path already has (R16).
    func restart() {
        queue.async { [weak self] in
            guard let self else { return }
            self.discardOnQueue()
            self.publish { hud in
                hud.applyReset(state: .idle)
                self.start()
            }
        }
    }

    /// Offer "Restart scan" once relocalization has run past the timeout;
    /// withdraw it the moment tracking recovers.
    func trackRelocalization(_ pose: CapturePose) {
        guard pose.isRelocalizing else {
            relocalizingSince = nil
            if isOfferingRestart {
                isOfferingRestart = false
                publish { $0.isOfferingRestart = false }
            }
            return
        }
        let since = relocalizingSince ?? pose.timestamp
        relocalizingSince = since
        if !isOfferingRestart, pose.timestamp - since >= Self.relocalizationTimeout {
            isOfferingRestart = true
            AppLog.engine.error("Relocalization still failing after \(Self.relocalizationTimeout, privacy: .public) s, offering restart")
            publish { $0.isOfferingRestart = true }
        }
    }
}
