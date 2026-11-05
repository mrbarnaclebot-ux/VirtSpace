//
//  ProgressSphereView.swift
//  VirtSpace
//
//  The "filling sphere" progress hero (spec §6.1: progress as a filling
//  sphere, not just "1 of 28"). A stylized 2D azimuthal projection of the
//  capture pattern drawn with Canvas: an outer band for the horizon ring, a
//  middle band for the upper ring, an inner band for the down ring and a
//  center core split into Sky (top half) and Ground (bottom half). Facets are
//  derived from TargetLayout (capture order is a column sweep, so a target's
//  index says nothing about its ring); they light up as their target is
//  captured, and the current target's facet carries a brighter rim.
//

import SwiftUI

struct ProgressSphereView: View {
    /// Captured flag per target, in TargetLayout capture order.
    let capturedFlags: [Bool]
    /// Index of the target being aimed at (highlighted facet), if any.
    let currentIndex: Int?

    private var capturedCount: Int { capturedFlags.lazy.filter { $0 }.count }

    var body: some View {
        HStack(spacing: 10) {
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .frame(width: 58, height: 58)

            Text("\(capturedCount) of \(capturedFlags.count)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .contentTransition(.numericText())
                .animation(Theme.Motion.quick, value: capturedCount)
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

    /// One facet per TargetLayout target, placed by its pitch band and yaw.
    private static let facets: [Facet] = TargetLayout.targets().map { target in
        let gap = 4.0 // degrees between facets
        switch target.pitchDegrees {
        case 90:
            return Facet(index: target.index, innerRadius: 0, outerRadius: 0.18,
                         startDegrees: -90 + gap, endDegrees: 90 - gap)
        case -90:
            return Facet(index: target.index, innerRadius: 0, outerRadius: 0.18,
                         startDegrees: 90 + gap, endDegrees: 270 - gap)
        default:
            let (inner, outer): (CGFloat, CGFloat) = switch target.pitchDegrees {
            case 0: (0.76, 1.0)
            case let p where p > 0: (0.5, 0.7)
            default: (0.26, 0.44)
            }
            let width = 360 / Double(TargetLayout.ringCount(atPitch: target.pitchDegrees) ?? 1)
            return Facet(index: target.index, innerRadius: inner, outerRadius: outer,
                         startDegrees: target.yawDegrees - width / 2 + gap / 2,
                         endDegrees: target.yawDegrees + width / 2 - gap / 2)
        }
    }

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
