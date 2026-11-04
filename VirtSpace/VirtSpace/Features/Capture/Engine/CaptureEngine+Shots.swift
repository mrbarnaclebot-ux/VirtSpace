//
//  CaptureEngine+Shots.swift
//  VirtSpace
//
//  Fire a still on a completed dwell and fold its outcome back into the
//  walk-around (advance, retry the target, or finish). Engine queue only.
//

import Foundation
import OSLog

nonisolated extension CaptureEngine {
    // MARK: - Engine queue: shots

    func takeStill() {
        guard let source, let session else { return }
        isTakingStill = true
        let index = currentIndex
        publish { $0.state = .capturing(targetIndex: index) }

        shots.take(index: index, from: source, into: session, totalTargets: targets.count) { [weak self] outcome in
            self?.handleShot(outcome, session: session)
        }
    }

    /// Engine queue: fold one shot's outcome back into the walk-around.
    private func handleShot(_ outcome: ShotOutcome, session: CaptureStore.Session) {
        switch outcome {
        case .saveFailed(_, let message):
            fail(message)

        case .failed(let index, let message):
            // One missed shot shouldn't kill a 28-shot walk-around: surface it
            // and let the dwell re-fire on the same target.
            isTakingStill = false
            dwell.reset()
            transientWarning = (message, (previousTimestamp ?? 0) + 3.0)
            publish {
                $0.warning = message
                $0.state = .ready(targetIndex: index)
            }

        case .saved(let index, let transform):
            shotPositions.append(AlignmentMath.position(of: transform))

            currentIndex += 1
            dwell.reset()
            pivotGate.reset()
            let next = currentIndex

            if next >= targets.count {
                running = false
                source?.stop()
                source = nil
                AppLog.capture.log("Capture complete: \(self.targets.count) frames, session \(session.id.uuidString, privacy: .public)")
                let result = CaptureResult(
                    sessionID: session.id,
                    directory: session.directory,
                    frameCount: targets.count
                )
                publish {
                    $0.capturedFlags[index] = true
                    $0.state = .finished(result)
                }
                ShotPipeline.celebrationHaptic()
            } else {
                publish {
                    $0.capturedFlags[index] = true
                    $0.state = .advancing
                }
                // Brief beat on .advancing so the UI can acknowledge the shot,
                // then open the next target. Dwell stays gated until then.
                queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self, self.running else { return }
                    self.isTakingStill = false
                    self.publish { $0.state = .ready(targetIndex: next) }
                }
            }
        }
    }
}
