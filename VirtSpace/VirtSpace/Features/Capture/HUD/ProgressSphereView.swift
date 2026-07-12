//
//  ProgressSphereView.swift
//  VirtSpace
//
//  The "filling sphere" progress hero (spec §6.1: progress as a filling
//  sphere, not just "1 of 16"). A stylized 2D azimuthal projection of the
//  16-target pattern drawn with Canvas: an outer band of 8 facets (horizon
//  ring), a middle band of 4 (upper ring), an inner band of 2 (down pair)
//  and a center core split into Sky (top half) and Ground (bottom half).
//  Facets light up as their target is captured; the current target's facet
//  carries a brighter rim.
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

    /// The 16 facets, indexed like TargetLayout: 0…7 horizon, 8…11 up,
    /// 12…13 down, 14 sky, 15 ground.
    private static let facets: [Facet] = {
        var facets: [Facet] = []
        let gap = 5.0 // degrees between facets
        for i in 0..<8 {
            let start = Double(i) * 45 - 22.5
            facets.append(Facet(index: i, innerRadius: 0.76, outerRadius: 1.0,
                                startDegrees: start + gap / 2, endDegrees: start + 45 - gap / 2))
        }
        for i in 0..<4 {
            let start = Double(i) * 90 - 45
            facets.append(Facet(index: 8 + i, innerRadius: 0.5, outerRadius: 0.7,
                                startDegrees: start + gap / 2, endDegrees: start + 90 - gap / 2))
        }
        for i in 0..<2 {
            let start = Double(i) * 180 - 90
            facets.append(Facet(index: 12 + i, innerRadius: 0.26, outerRadius: 0.44,
                                startDegrees: start + gap / 2, endDegrees: start + 180 - gap / 2))
        }
        // Sky = top half of the core, Ground = bottom half.
        facets.append(Facet(index: 14, innerRadius: 0, outerRadius: 0.18,
                            startDegrees: -90 + gap, endDegrees: 90 - gap))
        facets.append(Facet(index: 15, innerRadius: 0, outerRadius: 0.18,
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
            capturedFlags: (0..<16).map { $0 < 9 },
            currentIndex: 9
        )
    }
}
