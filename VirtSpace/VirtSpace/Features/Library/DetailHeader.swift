//
//  DetailHeader.swift
//  VirtSpace
//
//  Detail's title block (ui-spec 4.6): date title with the status pill,
//  "Living room · 2 minutes ago" (ticks every minute), and the caption as
//  an expandable subtitle.
//

import SwiftUI

struct DetailHeader: View {
    let world: World
    let presentation: StatusPresentation
    @Binding var captionExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    title
                    Spacer(minLength: Theme.Space.xs)
                    StatusBadge(presentation: presentation)
                }
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    title
                    StatusBadge(presentation: presentation)
                }
            }
            meta
            caption
        }
    }

    private var title: some View {
        Text(SpaceTitle.title(for: world))
            .font(.title2.bold())
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var meta: some View {
        if let created = world.createdAt {
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                let parts = [world.placeName, created.formatted(.relative(presentation: .named))]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                Text(parts.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityLabel(parts.joined(separator: ", "))
            }
        }
    }

    @ViewBuilder private var caption: some View {
        if let caption = world.caption, !caption.isEmpty {
            Text(caption)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(captionExpanded ? nil : 3)
                .onTapGesture { withAnimation(Theme.Motion.standard) { captionExpanded.toggle() } }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(captionExpanded ? "Shows less" : "Shows the full caption")
        }
    }
}
