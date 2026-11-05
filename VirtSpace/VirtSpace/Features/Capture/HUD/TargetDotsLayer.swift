//
//  TargetDotsLayer.swift
//  VirtSpace
//
//  The world-locked target dots projected from the engine's live camera
//  transform, plus the edge chevron (with degrees to go) when the current
//  target is off screen. Split out of CaptureHUDView; drawing only.
//

import simd
import SwiftUI

struct TargetDotsLayer: View {
    let hud: CaptureHUDState
    let viewSize: CGSize

    var body: some View {
        let transform = hud.cameraTransform
        let directions = hud.targetDirections
        let forward = AlignmentMath.forward(of: transform)
        let currentIndex = hud.currentTarget?.index

        ZStack {
            ForEach(hud.targets) { target in
                if directions.indices.contains(target.index) {
                    let projected = project(directions[target.index])
                    if projected.isOnScreen {
                        let captured = hud.capturedFlags.indices.contains(target.index)
                            && hud.capturedFlags[target.index]
                        let degreesOff = AlignmentMath.angularDistanceDegrees(forward, directions[target.index])
                        targetDot(captured: captured, isCurrent: target.index == currentIndex, degreesOff: degreesOff)
                            .position(projected.point)
                    }
                }
            }

            // Off-screen current target: edge chevron with degrees to go.
            if let currentIndex, directions.indices.contains(currentIndex) {
                let projected = project(directions[currentIndex])
                if !projected.isOnScreen {
                    let anchor = TargetProjection.edgeAnchor(
                        direction: projected.screenDirection,
                        viewSize: viewSize,
                        padding: 58
                    )
                    edgeChevron(angle: anchor.angle, degrees: hud.angularDistanceDegrees)
                        .position(anchor.point)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func project(_ direction: simd_float3) -> ProjectedTarget {
        TargetProjection.project(
            worldDirection: direction,
            cameraTransform: hud.cameraTransform,
            intrinsics: hud.cameraIntrinsics,
            imageResolution: hud.imageResolution,
            viewSize: viewSize
        )
    }

    /// A single world-locked dot: uncaptured dots glow brighter and larger as
    /// the camera closes in; captured ones collapse into a small check.
    @ViewBuilder
    private func targetDot(captured: Bool, isCurrent: Bool, degreesOff: Double) -> some View {
        if captured {
            // Dimmed once captured (Stage B3 deliverable 1): the painted
            // imagery now fills that direction, so the marker recedes to a
            // small, low-contrast tick and lets the panorama read clearly.
            ZStack {
                Circle()
                    .fill(Theme.success.opacity(0.14))
                    .frame(width: 18, height: 18)
                Image(systemName: "checkmark")
                    .font(.caption2.bold())
                    .foregroundStyle(Theme.success.opacity(0.6))
            }
            .opacity(0.7)
        } else {
            // 0 (far) to 1 (dead-on) over a 60 degree falloff.
            let closeness = max(0, 1 - degreesOff / 60)
            let diameter = 16 + 26 * closeness
            let tint = isCurrent ? Theme.accent : Color.white
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16 + 0.38 * closeness))
                    .frame(width: diameter, height: diameter)
                    .blur(radius: 3 + 5 * closeness)
                Circle()
                    .strokeBorder(tint.opacity(isCurrent ? 0.95 : 0.4), lineWidth: isCurrent ? 2 : 1)
                    .frame(width: diameter, height: diameter)
                if isCurrent {
                    Circle()
                        .fill(tint)
                        .frame(width: 5, height: 5)
                }
            }
            .shadow(color: tint.opacity(0.5 * closeness), radius: 8)
        }
    }

    private func edgeChevron(angle: Double, degrees: Double) -> some View {
        VStack(spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.title2.bold())
                .foregroundStyle(Theme.accent)
                .rotationEffect(.radians(angle))
                .shadow(color: Theme.accent.opacity(0.6), radius: 6)
            Text("\(Int(degrees.rounded()))°")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .glassEffect(.regular, in: .capsule)
        }
    }
}
