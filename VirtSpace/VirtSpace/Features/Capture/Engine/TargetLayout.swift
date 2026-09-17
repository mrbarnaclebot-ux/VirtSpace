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
//  overlap the server stitcher needs, and the 2-frame down ring left a muddy,
//  under-sampled band near the floor. The densified pattern fixes both:
//    • Horizon ring — 12 shots every 30°. At ~50° HFOV a 30° step keeps ~20°
//      (≈40% of the FOV) shared between neighbors, clearing the ≥30% gate.
//    • Upper ring (+45°) — 8 shots every 45°. Latitude shrinks the great-circle
//      spacing between neighbors, and each shot also overlaps 2–3 horizon shots
//      vertically (vertical FOV ~64° portrait, ring separation 45°).
//    • Lower ring (−45°) — 6 shots every 60°. Denser than the old 2-shot pair
//      so the floor band is properly sampled instead of muddy.
//    • Explicit zenith + nadir close the poles for true full-sphere coverage.
//  Total: 12 + 8 + 6 + 2 = 28 targets. The backend accepts any frame_count
//  (poses schema caps at 64), so no server change is needed.
//

import Foundation
import simd

/// One aim-point in the guided capture sphere.
struct CaptureTarget: Identifiable, Hashable {
    /// Capture order: 0…11 horizon ring, 12…19 up ring, 20…25 down ring,
    /// 26 zenith, 27 nadir.
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

    /// Target counts per group, in capture order: horizon ring, upper ring,
    /// lower ring, poles. EVERYTHING else in the layout — the targets, the
    /// total, the ring boundaries the HUD/haptics celebrate — derives from
    /// this. The 16→28 densification left the ring-completion haptics firing
    /// at the dead literals 7/11/13 (mid-ring in the new pattern) precisely
    /// because those indices were hardcoded elsewhere; deriving them here
    /// means the next pattern change can't silently desync (spec §10 R12).
    static let groupSizes: [Int] = [12, 8, 6, 2]

    static var horizonCount: Int { groupSizes[0] }
    static var upperCount: Int { groupSizes[1] }
    static var lowerCount: Int { groupSizes[2] }
    static var poleCount: Int { groupSizes[3] }

    /// Total targets in the pattern (28 today).
    static var targetCount: Int { groupSizes.reduce(0, +) }

    /// Index of the LAST target of each group — the running sums of
    /// `groupSizes`, minus one: [11, 19, 25, 27] for the 28-target pattern.
    static var ringBoundaryIndices: [Int] {
        var running = 0
        return groupSizes.map { size in
            running += size
            return running - 1
        }
    }

    /// Ring boundaries that earn a "ring complete" celebration haptic: every
    /// boundary except the final target, whose completion is announced by the
    /// end-of-capture success haptic the engine fires with `.finished`.
    static var ringCompletionIndices: Set<Int> {
        Set(ringBoundaryIndices.dropLast())
    }

    // MARK: - Targets

    /// The 28-frame capture pattern, in capture order: 12 horizon shots
    /// (every 30°), 8 at pitch +45° (every 45°), 6 at pitch −45° (every 60°),
    /// zenith, nadir. Ring yaw steps are 360° / ring size, so the ring sizes
    /// above fully determine the pattern.
    static func targets() -> [CaptureTarget] {
        var result: [CaptureTarget] = []
        var index = 0

        func add(pitch: Double, yaw: Double, label: String) {
            result.append(CaptureTarget(
                index: index,
                direction: direction(pitchDegrees: pitch, yawDegrees: yaw),
                pitchDegrees: pitch,
                yawDegrees: yaw,
                label: label
            ))
            index += 1
        }

        func addRing(pitch: Double, count: Int, labelPrefix: String) {
            let step = 360 / Double(count)
            for i in 0..<count {
                add(pitch: pitch, yaw: Double(i) * step, label: "\(labelPrefix) \(i + 1)")
            }
        }

        // Horizon ring — 12 shots, every 30° of yaw.
        addRing(pitch: 0, count: horizonCount, labelPrefix: "Horizon")
        // Upper ring — 8 shots at +45°, every 45° of yaw.
        addRing(pitch: 45, count: upperCount, labelPrefix: "Up")
        // Lower ring — 6 shots at −45°, every 60° of yaw.
        addRing(pitch: -45, count: lowerCount, labelPrefix: "Down")
        // Poles.
        add(pitch: 90, yaw: 0, label: "Sky")
        add(pitch: -90, yaw: 0, label: "Ground")

        return result
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
