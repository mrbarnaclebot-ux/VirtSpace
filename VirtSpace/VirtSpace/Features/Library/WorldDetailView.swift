//
//  WorldDetailView.swift
//  VirtSpace
//
//  World detail: big thumbnail, honest status timeline (spec §6.2 phases),
//  caption, created date, Enhance (draft_ready → optimistic flip to
//  generating_hq), Delete with confirmation, and a disabled 3D-viewer
//  placeholder ("Explorer coming in Stage C"). Polls while a job is active.
//

import SwiftUI

struct WorldDetailView: View {
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss

    let worldId: String
    @State var world: World?
    /// Presigned asset URLs — arrive in the detail response's top-level
    /// `assets` object; seeded from the list item's thumbnail-only assets.
    @State var assets: WorldAssets?

    @State private var toast: Toast?
    @State private var showDeleteConfirm = false
    @State private var isWorking = false
    @State private var pollTask: Task<Void, Never>?

    // 3D explorer (Stage C): tapping downloads the 500k SPZ via SplatCache
    // (inline button progress) then presents the immersive explorer.
    @State private var isPreparingExplorer = false
    @State private var explorerProgress: Double = 0
    @State private var explorer: ExplorerPresentation?

    // 2D 360° pano preview (spec §6.4) — presented full-screen when the world
    // has a stitched equirect pano (assets.pano_url).
    @State private var pano: PanoPresentation?

    /// Identifiable wrapper so the pano viewer can drive `fullScreenCover(item:)`.
    struct PanoPresentation: Identifiable {
        let id = UUID()
        let source: PanoPreviewView.Source
        let title: String
    }

    /// Identifiable wrapper so the explorer can drive `fullScreenCover(item:)`.
    struct ExplorerPresentation: Identifiable {
        let id = UUID()
        let source: ExplorerView.SplatSource
        let title: String
    }

    init(worldId: String, initialWorld: World? = nil) {
        self.worldId = worldId
        _world = State(initialValue: initialWorld)
        _assets = State(initialValue: initialWorld?.assets)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroThumbnail
                if let world {
                    header(world)
                    StatusTimeline(status: world.status)
                    if let caption = world.caption, !caption.isEmpty {
                        captionSection(caption)
                    }
                    actions(world)
                } else {
                    ProgressView("Loading world…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(16)
        }
        .navigationTitle(world?.title ?? "World")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemBackground))
        .toast($toast)
        .fullScreenCover(item: $explorer) { presentation in
            ExplorerView(source: presentation.source, title: presentation.title)
        }
        .fullScreenCover(item: $pano) { presentation in
            PanoPreviewView(source: presentation.source, title: presentation.title)
        }
        .task {
            await refresh(showErrors: world == nil)
            startPollingIfNeeded()
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
        .confirmationDialog(
            "Delete this world?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete World", role: .destructive) {
                Task { await deleteWorld() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the world and its assets.")
        }
    }

    // MARK: - Sections

    private var heroThumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(.secondarySystemBackground), Color(.tertiarySystemBackground)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            if let url = assets?.thumbnailAsURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        heroPlaceholder
                    default:
                        ProgressView()
                    }
                }
            } else {
                heroPlaceholder
            }
        }
        .frame(height: 230)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var heroPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 40, weight: .light))
            Text(world?.status.isActive == true ? "Preview appears when ready" : "No preview yet")
                .font(.caption)
        }
        .foregroundStyle(.tertiary)
    }

    private func header(_ world: World) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(world.title)
                    .font(.title2.weight(.bold))
                Spacer()
                StatusChip(status: world.status)
            }
            HStack(spacing: 6) {
                if let place = world.placeName, !place.isEmpty {
                    Text(place)
                    Text("·")
                }
                if let created = world.createdAt {
                    Text(created.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text("Just now")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if case .failed(let raw) = world.status {
                Label(raw.replacingOccurrences(of: "_", with: " "), systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private func captionSection(_ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Caption")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(caption)
                .font(.body)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func actions(_ world: World) -> some View {
        VStack(spacing: 12) {
            // 3D explorer (Stage C) — enabled once the 500k SPZ tier is
            // available (phone default per spec §3.1). Downloads via SplatCache
            // with inline progress, then presents the immersive explorer.
            Button {
                Task { await openExplorer(world) }
            } label: {
                Group {
                    if isPreparingExplorer {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(.white)
                            Text(explorerProgress > 0
                                 ? "Preparing… \(Int(explorerProgress * 100))%"
                                 : "Preparing…")
                        }
                    } else {
                        Label("Explore in 3D", systemImage: "move.3d")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canExplore(world) || isPreparingExplorer)

            // 2D 360° pano preview — enabled once the stitched equirect pano
            // (assets.pano_url) is available.
            Button {
                openPano(world)
            } label: {
                Label("View 360° Photo", systemImage: "pano")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .tint(.cyan)
            .disabled(!canViewPano)

            // Enhance — enabled only at draft_ready.
            Button {
                Task { await enhance() }
            } label: {
                Label("Enhance to HQ", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .tint(.purple)
            .disabled(!world.canEnhance || isWorking)

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete World", systemImage: "trash")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .disabled(isWorking)
        }
        .padding(.top, 4)
    }

    // MARK: - Pano preview

    /// The 360° photo is available once the stitched equirect pano URL is present.
    private var canViewPano: Bool { assets?.panoAsURL != nil }

    private func openPano(_ world: World) {
        guard let url = assets?.panoAsURL else {
            toast = Toast(message: "This world has no 360° photo yet.", style: .error)
            return
        }
        pano = PanoPresentation(
            source: .remote(worldId: world.id, version: world.assetVersion ?? 1, url: url),
            title: world.title
        )
    }

    // MARK: - Explorer

    /// Explore is available once the 500k SPZ tier URL is present.
    private func canExplore(_ world: World) -> Bool {
        guard let s = assets?.spz500kURL else { return false }
        return !s.isEmpty
    }

    private func openExplorer(_ world: World) async {
        guard let urlStr = assets?.spz500kURL, let remoteURL = URL(string: urlStr) else {
            toast = Toast(message: "This world has no 3D asset yet.", style: .error)
            return
        }
        isPreparingExplorer = true
        explorerProgress = 0
        defer { isPreparingExplorer = false }
        do {
            let local = try await SplatCache.shared.ensure(
                worldId: world.id,
                version: world.assetVersion ?? 1,
                remoteURL: remoteURL
            ) { p in
                Task { @MainActor in explorerProgress = p }
            }
            explorer = ExplorerPresentation(source: .file(local), title: world.title)
        } catch {
            toast = Toast(error)
        }
    }

    // MARK: - Data / actions

    private func refresh(showErrors: Bool) async {
        do {
            let envelope = try await api.getWorld(id: worldId)
            world = envelope.world
            assets = envelope.assets
        } catch {
            if showErrors, !Task.isCancelled {
                toast = Toast(error)
            }
        }
    }

    private func startPollingIfNeeded() {
        pollTask?.cancel()
        pollTask = nil
        guard world?.status.isActive == true else { return }
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
                await refresh(showErrors: false)
                if world?.status.isActive != true { return }
            }
        }
    }

    private func enhance() async {
        guard let current = world, current.canEnhance else { return }
        isWorking = true
        defer { isWorking = false }
        // Optimistic status flip; revert on failure.
        let previous = current.status
        world?.status = .generatingHq
        do {
            try await api.enhance(worldId: worldId)
            toast = Toast(message: "Enhancing to HQ — this takes a few minutes.", style: .success)
            startPollingIfNeeded()
        } catch {
            world?.status = previous
            toast = Toast(error)
        }
    }

    private func deleteWorld() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await api.deleteWorld(id: worldId)
            dismiss()
        } catch {
            toast = Toast(error)
        }
    }
}

// MARK: - StatusTimeline

/// The honest §6.2 phase timeline: Uploading → Stitching → Reconstructing →
/// Draft ready → Enhancing → Complete. Rendered against the current status.
struct StatusTimeline: View {
    let status: WorldStatus

    private struct Phase: Identifiable {
        let id: Int
        let label: String
        let icon: String
    }

    private static let phases: [Phase] = [
        Phase(id: 0, label: "Uploading", icon: "arrow.up.circle"),
        Phase(id: 1, label: "Stitching", icon: "square.stack.3d.up"),
        Phase(id: 2, label: "Reconstructing", icon: "sparkles"),
        Phase(id: 3, label: "Draft ready", icon: "checkmark.seal"),
        Phase(id: 4, label: "Enhancing", icon: "wand.and.stars"),
        Phase(id: 5, label: "Complete", icon: "checkmark.seal.fill"),
    ]

    /// Index of the phase the status maps to; nil for capturing (pre-timeline).
    private var currentIndex: Int? {
        switch status {
        case .capturing: return nil
        case .uploading: return 0
        case .stitching: return 1
        case .generatingDraft: return 2
        case .draftReady: return 3
        case .generatingHq: return 4
        case .complete: return 5
        case .failed(let raw):
            // Map failed_<phase> onto the phase that failed.
            if raw.contains("upload") { return 0 }
            if raw.contains("stitch") { return 1 }
            if raw.contains("draft") { return 2 }
            if raw.contains("hq") || raw.contains("enhance") { return 4 }
            return 2
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.phases) { phase in
                HStack(spacing: 12) {
                    marker(for: phase)
                    Text(phase.label)
                        .font(.subheadline.weight(phase.id == currentIndex ? .semibold : .regular))
                        .foregroundStyle(color(for: phase))
                    Spacer()
                    if phase.id == currentIndex {
                        if status.isFailed {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else if status.isActive {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .padding(.vertical, 7)
                if phase.id < Self.phases.count - 1 {
                    Rectangle()
                        .fill(connectorColor(after: phase))
                        .frame(width: 2, height: 12)
                        .padding(.leading, 11)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func marker(for phase: Phase) -> some View {
        ZStack {
            Circle()
                .fill(fillColor(for: phase))
                .frame(width: 24, height: 24)
            Image(systemName: phase.id == currentIndex && status.isFailed ? "xmark" : phase.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(markerIconColor(for: phase))
        }
    }

    private func isDone(_ phase: Phase) -> Bool {
        guard let currentIndex else { return false }
        if status.isFailed { return phase.id < currentIndex }
        // A non-active current phase (draft_ready, complete) is itself done.
        return phase.id < currentIndex || (phase.id == currentIndex && !status.isActive)
    }

    private func fillColor(for phase: Phase) -> Color {
        if phase.id == currentIndex {
            return status.isFailed ? .red : status.tint
        }
        return isDone(phase) ? Color.green.opacity(0.85) : Color(.tertiarySystemFill)
    }

    private func markerIconColor(for phase: Phase) -> Color {
        (phase.id == currentIndex || isDone(phase)) ? .white : .secondary
    }

    private func color(for phase: Phase) -> Color {
        if phase.id == currentIndex { return status.isFailed ? .red : .primary }
        return isDone(phase) ? .primary : .secondary
    }

    private func connectorColor(after phase: Phase) -> Color {
        isDone(phase) ? Color.green.opacity(0.5) : Color(.tertiarySystemFill)
    }
}

#Preview {
    NavigationStack {
        WorldDetailView(worldId: "preview")
    }
    .environment(APIClient())
    .preferredColorScheme(.dark)
}
