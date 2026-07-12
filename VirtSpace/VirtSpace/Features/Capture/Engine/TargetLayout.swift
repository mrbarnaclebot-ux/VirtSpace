//
//  TargetLayout.swift
//  VirtSpace
//
//  Pure, testable layout of the 16 guided-capture targets (spec §5, §6.1).
//  Directions are unit vectors in a "heading frame": +Y up (gravity),
//  -Z forward along the user's initial heading, +X to the user's right.
//  CaptureEngine rotates these into ARKit world space using the yaw of the
//  first tracked camera frame, so target 0 is always "straight ahead of
//  wherever the user started looking".
//
//  Overlap rationale (spec §6.1 / §9 — "16 shots marginal for full sphere"):
//  the iPhone main camera in 4:3 covers ~69° horizontally. 8 horizon shots at
//  45° yaw spacing leave ~24° of shared view between neighbors — ≈35% of the
//  FOV, clearing the ≥30% overlap the server stitcher needs for seam blending.
//  The upper ring at pitch +45° uses 90° yaw spacing: at that latitude the
//  great-circle distance between neighbors shrinks to ~60°, and each upper
//  shot also overlaps two-to-three horizon shots vertically (vertical FOV
//  ~53°, ring separation 45°). The sparse lower pair (floor is usually
//  featureless and close), plus explicit zenith/nadir shots, complete true
//  full-sphere coverage instead of leaving polar holes.
//

import Foundation
import simd

/// One aim-point in the guided capture sphere.
struct CaptureTarget: Identifiable, Hashable {
    /// Capture order: 0…7 horizon ring, 8…11 up ring, 12…13 down pair,
    /// 14 zenith, 15 nadir.
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

enum TargetLayout {
    /// The 16-frame capture pattern, in capture order: 8 horizon shots
    /// (every 45°), 4 at pitch +45° (every 90°), 2 at pitch −45°
    /// (yaw 0°/180°), zenith, nadir.
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

        // Horizon ring — 8 shots, every 45° of yaw.
        for i in 0..<8 {
            add(pitch: 0, yaw: Double(i) * 45, label: "Horizon \(i + 1)")
        }
        // Upper ring — 4 shots at +45°, every 90° of yaw.
        for i in 0..<4 {
            add(pitch: 45, yaw: Double(i) * 90, label: "Up \(i + 1)")
        }
        // Lower pair — 2 shots at −45°, front and back.
        add(pitch: -45, yaw: 0, label: "Down 1")
        add(pitch: -45, yaw: 180, label: "Down 2")
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
