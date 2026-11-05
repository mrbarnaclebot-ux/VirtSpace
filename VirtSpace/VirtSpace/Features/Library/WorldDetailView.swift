//
//  WorldDetailView.swift
//  VirtSpace
//
//  Space detail (ui-spec 4.6). Reads the space from the WorldStore (its one
//  poll loop keeps an active space current) and shows, by status: the build
//  step list, the status card with Try again, or the actions (Explore in 3D,
//  View 360° photo, Improve quality). Nothing is optimistic; delete, retry
//  and improve change the screen only after the server answers.
//

import SwiftUI

struct WorldDetailView: View {
    let worldId: String

    @Environment(APIClient.self) private var api
    @Environment(WorldStore.self) private var store
    @Environment(ToastCenter.self) private var toasts
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    @State private var uploads: [String: UploadProgress] = [:]
    @State private var loadError: String?
    @State private var isGone = false
    @State private var isRetrying = false
    @State private var quotaNote: String?
    @State private var improve: ImproveMode?
    @State private var pendingDelete: World?
    @State private var explorer: ExplorerPresentation?
    @State private var pano: PanoPresentation?
    @State private var readyMoment = false
    @State private var readyCount = 0
    @State private var acceptedCount = 0
    @State private var captionExpanded = false
    @AppStorage("detail.exploreTipSeen") private var exploreTipSeen = false
    @AppStorage(WorldAssets.maximumDetailKey) private var maximumDetail = false

    enum ImproveMode: Identifiable {
        case enhance, retry
        var id: Self { self }
    }

    struct ExplorerPresentation: Identifiable {
        let id = UUID()
        let source: ExplorerView.SplatSource
        let title: String
    }

    struct PanoPresentation: Identifiable {
        let id = UUID()
        let source: PanoPreviewView.Source
        let title: String
    }

    private var world: World? { store.world(id: worldId) }
    private var assets: WorldAssets? { store.details[worldId]?.assets ?? world?.assets }
    private var actions: SpaceActions { SpaceActions(api: api, store: store, toasts: toasts, router: router) }
    private var pollsFailing: Bool { store.consecutiveFailures > 0 }

    var body: some View {
        screen
            .navigationTitle(world.map(SpaceTitle.title) ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .background(Theme.bg)
            .toolbar { moreMenu }
            .task { await load() }
            .onChange(of: world?.status) { old, new in noteReadyMoment(from: old, to: new) }
            .onChange(of: world == nil) { _, isNil in if isNil { isGone = true } }
            .readingUploadProgress(for: watchesUpload ? [worldId] : [], into: $uploads)
            .sensoryFeedback(.success, trigger: readyCount)
            .sensoryFeedback(.impact(weight: .light), trigger: acceptedCount)
            .deleteSpaceDialog(for: $pendingDelete, actions: actions)
            .sheet(item: $improve) { mode in
                ImproveQualitySheet { await run(mode == .enhance ? .enhance : .retry) }
            }
            .fullScreenCover(item: $explorer) { ExplorerView(source: $0.source, title: $0.title) }
            .fullScreenCover(item: $pano) { PanoPreviewView(source: $0.source, title: $0.title) }
    }

    @ViewBuilder private var screen: some View {
        if let world {
            ScrollView { loaded(world) }
                .refreshable { await load() }
        } else if isGone {
            ContentUnavailableView("This space was deleted.", systemImage: "trash")
        } else if let loadError {
            ContentUnavailableView {
                Label("Can't load this space", systemImage: "wifi.exclamationmark")
            } description: {
                Text(loadError)
            } actions: {
                Button("Try again") { Task { await load() } }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        } else {
            ScrollView { placeholder }
        }
    }

    // MARK: - Layout

    private func loaded(_ world: World) -> some View {
        let p = world.status.presentation(hasLocalUpload: uploads[worldId] != nil)
        let isBuilding = world.status.isActive && p.step != nil
        return VStack(alignment: .leading, spacing: Theme.Space.l) {
            if loadError != nil || store.consecutiveFailures >= 2 {
                OfflineBanner()
            }
            SpaceThumbnail(url: assets?.thumbnailAsURL, isBuilding: isBuilding, revealBlur: readyMoment)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            DetailHeader(world: world, presentation: p, captionExpanded: $captionExpanded)
            if isBuilding {
                StepList(world: world, upload: uploads[worldId], pollsFailing: pollsFailing)
            } else {
                statusCard(world, p)
                actionButtons(world)
                    .transition(.opacity)
            }
        }
        .padding(Theme.Space.m)
        .animation(Theme.Motion.standard, value: world.status)
    }

    @ViewBuilder private func statusCard(_ world: World, _ p: StatusPresentation) -> some View {
        if p.detail != nil {
            StatusCard(
                presentation: p,
                isRetrying: isRetrying,
                isSlow: world.status.isSlow(heartbeatAt: world.heartbeatAt, pollsFailing: pollsFailing),
                quotaNote: quotaNote,
                onRetry: p.retry.map { cost in { retryTapped(cost) } },
                onGoToScan: world.status == .failed("failed_upload") && uploads[worldId] != nil
                    ? { router.selectedTab = .scan } : nil
            )
        }
    }

    @ViewBuilder private func actionButtons(_ world: World) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let splat = WorldAssets.explorerSplat(assets: assets, maximumDetail: maximumDetail), let url = URL(string: splat.url) {
                Button {
                    exploreTipSeen = true
                    explorer = ExplorerPresentation(
                        source: .remote(worldId: world.id, version: world.assetVersion ?? 1, tier: splat.tier, url: url),
                        title: SpaceTitle.title(for: world))
                } label: {
                    Label("Explore in 3D", systemImage: "move.3d").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                if !exploreTipSeen {
                    Text("Drag to look around. Use the stick to walk.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if let url = assets?.panoAsURL {
                Button {
                    pano = PanoPresentation(
                        source: .remote(worldId: world.id, version: world.assetVersion ?? 1, url: url),
                        title: SpaceTitle.title(for: world))
                } label: {
                    Label("View 360° photo", systemImage: "pano").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            if world.canEnhance {
                ImproveCard { improve = .enhance }
                    .padding(.top, Theme.Space.s)
            }
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            SpaceThumbnail(url: nil)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Nov 5, 3:12 PM").font(.title2.bold())
                Text("Living room · 2 minutes ago").font(.subheadline)
            }
            .redacted(reason: .placeholder)
        }
        .padding(Theme.Space.m)
        .accessibilityHidden(true)
    }

    @ToolbarContentBuilder private var moreMenu: some ToolbarContent {
        if let world {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") {
                    Button("Delete space", systemImage: "trash", role: .destructive) { pendingDelete = world }
                }
            }
        }
    }

    // MARK: - Data and actions

    /// Upload count (step 1), or whether a failed upload is still on this phone.
    private var watchesUpload: Bool {
        world?.status == .uploading || world?.status == .failed("failed_upload")
    }

    private func load() async {
        // No backend calls from a hosted test run (TestEnvironment).
        guard !TestEnvironment.isRunningUnderXCTest else { return }
        do {
            try await store.fetch(id: worldId)
            loadError = nil
        } catch let error as APIError where error.isWorldGone {
            isGone = true
        } catch {
            loadError = error.userCopy
        }
    }

    private func retryTapped(_ cost: RetryCost) {
        if cost == .needsConfirmation {
            improve = .retry
        } else {
            Task { await run(.retry) }
        }
    }

    private func run(_ kind: SpaceActions.Kind) async {
        guard let world, !isRetrying else { return }
        isRetrying = true
        defer { isRetrying = false }
        switch await actions.run(kind, on: world) {
        case .accepted:
            quotaNote = nil
            acceptedCount += 1
        case .scanQuota(let resetAt):
            quotaNote = APIError.scanQuota(resetAt: resetAt).userCopy
        default:
            break
        }
    }

    /// The space-ready moment (ui-spec 9.7): seen live, app active.
    private func noteReadyMoment(from old: WorldStatus?, to new: WorldStatus?) {
        guard let old, old.isActive, new == .draftReady, scenePhase == .active else { return }
        readyMoment = true
        readyCount += 1
    }
}
