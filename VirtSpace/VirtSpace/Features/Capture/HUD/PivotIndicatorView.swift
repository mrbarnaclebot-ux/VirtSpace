//
//  PivotIndicatorView.swift
//  VirtSpace
//
//  Small top-down pivot indicator (R37): the dashed ring is the soft-gate
//  distance around the centroid of the shots so far, the dot is the phone,
//  forward is up. Green inside the ring, orange outside. Coaching text alone
//  ("turn around the phone") is hard to act on; seeing the dot drift out and
//  steering it back is not.
//

import simd
import SwiftUI

struct PivotIndicatorView: View {
    /// Camera offset from the shot centroid, metres (x right, y forward).
    let offset: SIMD2<Float>

    /// The view's radius spans twice the gate distance.
    private static let spanMeters = 2 * AlignmentMath.pivotGateMeters

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width, size.height) / 2 - 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let gateRadius = radius * CGFloat(AlignmentMath.pivotGateMeters / Self.spanMeters)
            let gate = Path(ellipseIn: CGRect(x: center.x - gateRadius, y: center.y - gateRadius,
                                              width: 2 * gateRadius, height: 2 * gateRadius))
            context.stroke(gate, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))

            let inside = simd_length(offset) <= AlignmentMath.pivotGateMeters
            // Clamp to the rim so a big drift still shows its direction.
            var scaled = offset / Self.spanMeters
            if simd_length(scaled) > 1 { scaled = simd_normalize(scaled) }
            let dot = CGPoint(x: center.x + CGFloat(scaled.x) * radius,
                              y: center.y - CGFloat(scaled.y) * radius)
            context.fill(Path(ellipseIn: CGRect(x: dot.x - 3.5, y: dot.y - 3.5, width: 7, height: 7)),
                         with: .color(inside ? .green : .orange))
        }
        .frame(width: 34, height: 34)
        .accessibilityLabel(simd_length(offset) <= AlignmentMath.pivotGateMeters
                            ? "Phone is on the pivot" : "Phone has moved off the pivot")
    }
}
