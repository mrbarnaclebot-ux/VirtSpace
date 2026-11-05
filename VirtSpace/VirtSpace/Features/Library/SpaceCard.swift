//
//  SpaceCard.swift
//  VirtSpace
//
//  One Library card (ui-spec 4.5): a 16:9 thumbnail, the date title with the
//  status pill, and one line saying what is happening. Read by VoiceOver as
//  one element, "Space from Nov 5 at 3:12 PM, Ready".
//

import SwiftUI

struct SpaceCard: View {
    let world: World
    var upload: UploadProgress?
    /// The client's own polls are failing: never claim the server is slow.
    var pollsFailing = false

    private static let inset = Theme.Space.xs

    var body: some View {
        let p = world.status.presentation(hasLocalUpload: upload != nil)
        VStack(alignment: .leading, spacing: 0) {
            SpaceThumbnail(url: world.assets?.thumbnailAsURL, isBuilding: world.status.isActive)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card - Self.inset, style: .continuous))
                .padding([.horizontal, .top], Self.inset)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                titleRow(p)
                statusLines(p)
            }
            .padding(Theme.Space.m)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SpaceTitle.accessibilityLabel(for: world, presentation: p))
        .accessibilityValue(CardLine.text(for: world, presentation: p, upload: upload) ?? "")
        .accessibilityHint("Opens details")
    }

    private func titleRow(_ p: StatusPresentation) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                title
                Spacer(minLength: Theme.Space.xs)
                StatusBadge(presentation: p)
            }
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                title
                StatusBadge(presentation: p)
            }
        }
    }

    private var title: some View {
        Text(SpaceTitle.title(for: world))
            .font(.headline)
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(2)
    }

    @ViewBuilder private func statusLines(_ p: StatusPresentation) -> some View {
        if let line = CardLine.text(for: world, presentation: p, upload: upload) {
            Text(line)
                .font(.caption)
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
        }
        SpaceProgress(kind: ProgressKind(world: world, upload: upload))
            .id(world.status)
        if world.status.isSlow(heartbeatAt: world.heartbeatAt, pollsFailing: pollsFailing) {
            Text("Taking longer than usual")
                .font(.caption)
                .foregroundStyle(Theme.warning)
        }
    }
}

/// The right bar for a `ProgressKind`; fades in at its first value.
struct SpaceProgress: View {
    let kind: ProgressKind

    var body: some View {
        Group {
            switch kind {
            case .none: EmptyView()
            case .measured(let fraction): MeasuredBar(fraction: fraction)
            case .indeterminate: IndeterminateBar()
            }
        }
        .transition(.opacity)
    }
}

/// A 16:9 thumbnail on a flat placeholder (symbol only, no spinner). The
/// image crossfades in; `revealBlur` adds the space-ready blur (12 to 0 over
/// 0.6 s, ui-spec 9.7). Reduce Motion keeps only the crossfade.
struct SpaceThumbnail: View {
    let url: URL?
    var isBuilding = false
    var revealBlur = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var symbolSize: CGFloat = 28
    @State private var shown = false

    var body: some View {
        Rectangle()
            .fill(Theme.surfaceInset)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay { placeholder }
            .overlay { image }
            .clipped()
            .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: "cube.transparent")
            .font(.system(size: symbolSize))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Theme.textTertiary)
            .pulsing(isBuilding && !reduceMotion)
    }

    @ViewBuilder private var image: some View {
        if let url {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable()
                        .aspectRatio(contentMode: .fill)
                        .opacity(shown ? 1 : 0)
                        .blur(radius: shown || !revealBlur || reduceMotion ? 0 : 12)
                        .onAppear {
                            withAnimation(.smooth(duration: revealBlur ? 0.6 : 0.35)) { shown = true }
                        }
                }
            }
        }
    }
}

/// First-load placeholder card: redacted, no spinner (ui-spec 4.5).
struct PlaceholderCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Theme.surfaceInset)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card - Theme.Space.xs, style: .continuous))
                .padding([.horizontal, .top], Theme.Space.xs)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Nov 5, 3:12 PM").font(.headline)
                Text("A bright living room with a sofa").font(.caption)
            }
            .padding(Theme.Space.m)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}
