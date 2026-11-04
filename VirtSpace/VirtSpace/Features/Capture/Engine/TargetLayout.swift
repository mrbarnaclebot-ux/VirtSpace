//
//  TargetLayout.swift
//  VirtSpace
//
//  Pure, testable layout of the 28 guided-capture targets (spec §5, §6.1;
//  Phase 0.5 stitch-gate decision). Directions are unit vectors in a "heading
//  frame": +Y up (gravity), -Z forward along the user's initial heading, +X to
//  the user's right. CaptureEngine rotates these into ARKit world space using
//  the yaw of the first tracked camera frame, so target 0 is always "straight
//  ahead of wherever the user started looking".
//
//  Densified pattern — why 28, not 16 (Phase 0.5 stitch gate):
//  the earlier 16-target ring (45° yaw spacing) proved too sparse. In portrait
//  the iPhone main camera covers only ~50° horizontally, so a 45° step leaves
//  barely ~5° of shared view between horizon neighbors — well under the ≥30%
//  overlap the server stitcher needs.
//    • Horizon ring — 12 shots every 30° (~40% of the FOV shared).
//    • Upper ring (+45°) — 6 shots every 60°. Latitude shrinks the spacing
//      and each shot also overlaps 2–3 horizon shots vertically.
//    • Lower ring (−45°) — 8 shots every 45°. Rebalanced from 6 (R39): the
//      floor matters more than the ceiling for a walkable world, and 60°
//      steps left the down ring at only ~20% overlap.
//    • Explicit zenith + nadir close the poles for true full-sphere coverage.
//  Total: 12 + 6 + 8 + 2 = 28 targets.
//
//  Capture order is COLUMN order (R39): one sweep around, taking whichever
//  ring targets share a yaw step together (up / horizon / down), then the
//  poles. Ring-by-ring meant three full body rotations — three chances to
//  drift off the pivot. Column order over "any aligned target fires" because
//  it keeps the HUD at one current target, one chevron and one label; any-
//  order would need the HUD to choose and explain which of several targets
//  to aim for.
//

import Foundation
import simd

/// One aim-point in the guided capture sphere.
struct CaptureTarget: Identifiable, Hashable {
    /// Capture order (column sweep, then Sky, then Ground) — see TargetLayout.
    let index: Int
    /// Unit direction in the heading frame (-Z forward, +Y up, +X right).
    let direction: simd_float3
    /// Elevation above the horizon, degrees (+90 = zenith, -90 = nadir).
    let pitchDegrees: Double
    /// Rotation from the initial heading, degrees. Positive = to the right.
    let yawDegrees: Double
    /// Human-readable name ("Horizon 3", "Up 2", "Sky", "Ground").
    let label: String

    var id: Int { index }
}

/// Pure layout math with no isolation of its own: the engine queue, the
/// thumbnail queue and the main actor all read it.
nonisolated enum TargetLayout {
    // MARK: - Shape of the pattern (single source of truth)

    /// The three rings: pitch, target count (yaw step = 360 / count), label.
    /// EVERYTHING else — the targets, the total, the celebration haptics, the
    /// progress sphere's facets — derives from this (spec §10 R12: hardcoded
    /// indices elsewhere silently desynced on the last pattern change).
    static let rings: [(pitchDegrees: Double, count: Int, label: String)] = [
        (0, 12, "Horizon"),
        (45, 6, "Up"),
        (-45, 8, "Down")
    ]

    static func ringCount(atPitch pitch: Double) -> Int? {
        rings.first { $0.pitchDegrees == pitch }?.count
    }

    /// Sky + Ground.
    static let poleCount = 2

    /// Total targets in the pattern (28 today).
    static var targetCount: Int { rings.reduce(0) { $0 + $1.count } + poleCount }

    /// Index of the last ring target: the sweep around is complete.
    static var sweepEndIndex: Int { targetCount - poleCount - 1 }

    /// Shots that earn a celebration haptic: the end of the sweep. In column
    /// order all three rings finish within the sweep's last few shots, so
    /// per-ring celebrations would fire back to back. The final target's
    /// completion is the engine's end-of-capture success haptic.
    static var celebrationIndices: Set<Int> { [sweepEndIndex] }

    // MARK: - Targets

    /// The 28-frame pattern in capture order: ring targets sorted by yaw;
    /// within one yaw step, nearest pitch to the previous shot first (ties go
    /// up), so each column is one tilt; then Sky, then Ground.
    static func targets() -> [CaptureTarget] {
        typealias Spot = (pitch: Double, yaw: Double, label: String)
        var spots: [Spot] = []
        for ring in rings {
            let step = 360 / Double(ring.count)
            for i in 0..<ring.count {
                spots.append((ring.pitchDegrees, Double(i) * step, "\(ring.label) \(i + 1)"))
            }
        }

        var ordered: [Spot] = []
        var lastPitch = 0.0 // target 0 is the horizon straight ahead
        let columns = Dictionary(grouping: spots) { $0.yaw }.sorted { $0.key < $1.key }
        for (_, column) in columns {
            var remaining = column
            while !remaining.isEmpty {
                let pick = remaining.indices.min { a, b in
                    let da = abs(remaining[a].pitch - lastPitch), db = abs(remaining[b].pitch - lastPitch)
                    return da != db ? da < db : remaining[a].pitch > remaining[b].pitch
                }!
                lastPitch = remaining[pick].pitch
                ordered.append(remaining.remove(at: pick))
            }
        }
        ordered.append((90, 0, "Sky"))
        ordered.append((-90, 0, "Ground"))

        return ordered.enumerated().map { index, spot in
            CaptureTarget(
                index: index,
                direction: direction(pitchDegrees: spot.pitch, yawDegrees: spot.yaw),
                pitchDegrees: spot.pitch,
                yawDegrees: spot.yaw,
                label: spot.label
            )
        }
    }

    /// Unit vector for a pitch/yaw pair in the heading frame.
    /// pitch 0 / yaw 0 → (0, 0, -1) (straight ahead); yaw 90° → (1, 0, 0)
    /// (to the right); pitch +90° → (0, 1, 0) (straight up).
    static func direction(pitchDegrees pitch: Double, yawDegrees yaw: Double) -> simd_float3 {
        let p = pitch * .pi / 180
        let y = yaw * .pi / 180
        return simd_float3(
            Float(cos(p) * sin(y)),
            Float(sin(p)),
            Float(-cos(p) * cos(y))
        )
    }
}
