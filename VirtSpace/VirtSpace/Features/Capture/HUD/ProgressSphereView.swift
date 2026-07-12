//
//  ProgressSphereView.swift
//  VirtSpace
//
//  The "filling sphere" progress hero (spec §6.1: progress as a filling
//  sphere, not just "1 of 28"). A stylized 2D azimuthal projection of the
//  Phase 0.5 densified 28-target pattern drawn with Canvas: an outer band of
//  12 facets (horizon ring, 30°), a middle band of 8 (upper ring, 45°), an
//  inner band of 6 (down ring, 60°) and a center core split into Sky (top
//  half) and Ground (bottom half). Facets light up as their target is
//  captured; the current target's facet carries a brighter rim.
//

import SwiftUI

struct ProgressSphereView: View {
    /// Captured flag per target, in TargetLayout capture order.
    let capturedFlags: [Bool]
    /// Index of the target being aimed at (highlighted facet), if any.
    let currentIndex: Int?

    var body: some View {
        HStack(spacing: 10) {
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .frame(width: 58, height: 58)

            Text("\(capturedFlags.lazy.filter { $0 }.count)/\(capturedFlags.count)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    // MARK: - Drawing

    private struct Facet {
        let index: Int
        let innerRadius: CGFloat  // normalized 0…1
        let outerRadius: CGFloat
        let startDegrees: Double  // 0° = up, clockwise
        let endDegrees: Double
    }

    /// The 28 facets, indexed like TargetLayout: 0…11 horizon, 12…19 up,
    /// 20…25 down, 26 sky, 27 ground.
    private static let facets: [Facet] = {
        var facets: [Facet] = []
        let gap = 4.0 // degrees between facets
        // Horizon ring — 12 facets every 30°, outer band.
        for i in 0..<12 {
            let start = Double(i) * 30 - 15
            facets.append(Facet(index: i, innerRadius: 0.76, outerRadius: 1.0,
                                startDegrees: start + gap / 2, endDegrees: start + 30 - gap / 2))
        }
        // Upper ring — 8 facets every 45°, middle band.
        for i in 0..<8 {
            let start = Double(i) * 45 - 22.5
            facets.append(Facet(index: 12 + i, innerRadius: 0.5, outerRadius: 0.7,
                                startDegrees: start + gap / 2, endDegrees: start + 45 - gap / 2))
        }
        // Lower ring — 6 facets every 60°, inner band.
        for i in 0..<6 {
            let start = Double(i) * 60 - 30
            facets.append(Facet(index: 20 + i, innerRadius: 0.26, outerRadius: 0.44,
                                startDegrees: start + gap / 2, endDegrees: start + 60 - gap / 2))
        }
        // Sky = top half of the core, Ground = bottom half.
        facets.append(Facet(index: 26, innerRadius: 0, outerRadius: 0.18,
                            startDegrees: -90 + gap, endDegrees: 90 - gap))
        facets.append(Facet(index: 27, innerRadius: 0, outerRadius: 0.18,
                            startDegrees: 90 + gap, endDegrees: 270 - gap))
        return facets
    }()

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - 1

        for facet in Self.facets {
            let captured = capturedFlags.indices.contains(facet.index) && capturedFlags[facet.index]
            let isCurrent = facet.index == currentIndex
            let path = facetPath(facet, center: center, radius: radius)

            if captured {
                context.fill(path, with: .color(Color.cyan.opacity(0.9)))
            } else {
                context.fill(path, with: .color(Color.white.opacity(isCurrent ? 0.16 : 0.05)))
                context.stroke(
                    path,
                    with: .color(isCurrent ? Color.cyan.opacity(0.9) : Color.white.opacity(0.22)),
                    lineWidth: isCurrent ? 1.4 : 0.7
                )
            }
        }
    }

    /// Annular wedge (or center wedge) path. Angles measured with 0° at
    /// 12 o'clock, clockwise.
    private func facetPath(_ facet: Facet, center: CGPoint, radius: CGFloat) -> Path {
        let start = Angle(degrees: facet.startDegrees - 90)
        let end = Angle(degrees: facet.endDegrees - 90)
        var path = Path()
        if facet.innerRadius <= 0.001 {
            path.move(to: center)
            path.addArc(center: center, radius: radius * facet.outerRadius,
                        startAngle: start, endAngle: end, clockwise: false)
            path.closeSubpath()
        } else {
            path.addArc(center: center, radius: radius * facet.outerRadius,
                        startAngle: start, endAngle: end, clockwise: false)
            path.addArc(center: center, radius: radius * facet.innerRadius,
                        startAngle: end, endAngle: start, clockwise: true)
            path.closeSubpath()
        }
        return path
    }
}

#Preview {
    ZStack {
        Color.black
        ProgressSphereView(
            capturedFlags: (0..<28).map { $0 < 15 },
            currentIndex: 15
        )
    }
}
