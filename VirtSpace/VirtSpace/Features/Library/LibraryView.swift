//
//  LibraryView.swift
//  VirtSpace
//
//  The user's spaces (ui-spec 4.5). Reads everything from the app-scoped
//  WorldStore (one list, one poll loop), so a space created on Scan or
//  deleted on Detail shows up here without a pull to refresh. The stack is
//  bound to `router.libraryPath` so other screens can open a space.
//
//  States: placeholder cards on first load; "No spaces yet" only after a
//  successful empty load; "Can't load your library" when a load failed with
//  nothing cached; cards plus an offline banner after 2 failed polls.
//

import SwiftUI

struct LibraryView: View {
    @Environment(APIClient.self) private var api
    @Environment(WorldStore.self) private var store
    @Environment(ToastCenter.self) private var toasts
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var uploads: [String: UploadProgress] = [:]
    @State private var pendingDelete: World?
    @State private var improveTarget: World?
    @State private var acceptedCount = 0
    @State private var showSettings = false
    @State private var showDebugLog = false
    @State private var titleTapCount = 0
    @State private var firstTitleTapAt = Date.distantPast

    private var actions: SpaceActions {
        SpaceActions(api: api, store: store, toasts: toasts, router: router)
    }

    private var listState: LibraryListState {
        LibraryListState(isEmpty: store.worlds.isEmpty, hasLoaded: store.hasLoaded, lastError: store.lastError)
    }

    private var uploadingIDs: [String] {
        store.worlds.filter { $0.status == .uploading }.map(\.id)
    }

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.libraryPath) {
            content
                .navigationTitle("Library")
                .navigationBarTitleDisplayMode(.large)
                .background(Theme.bg)
                .toolbar { toolbar }
                .navigationDestination(for: String.self) { WorldDetailView(worldId: $0) }
        }
        .task {
            // No backend calls from a hosted test run (TestEnvironment).
            guard !TestEnvironment.isRunningUnderXCTest, !store.hasLoaded else { return }
            await store.refresh()
        }
        .readingUploadProgress(for: uploadingIDs, into: $uploads)
        .sensoryFeedback(.impact(weight: .light), trigger: acceptedCount)
        .deleteSpaceDialog(for: $pendingDelete, actions: actions)
        .sheet(item: $improveTarget) { world in
            ImproveQualitySheet { await retry(world) }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showDebugLog) { DebugLogView() }
    }

    // MARK: - States

    private var content: some View {
        let state = listState
        return ScrollView {
            Group {
                switch state {
                case .loading: placeholders
                case .empty: emptyState
                case .failed(let cause): errorState(cause)
                case .content: cards
                }
            }
            .transition(.opacity)
        }
        .refreshable { await store.refresh() }
        .animation(Theme.Motion.standard, value: state)
    }

    private var placeholders: some View {
        VStack(spacing: Theme.Space.m) {
            PlaceholderCard()
            PlaceholderCard()
        }
        .padding(.horizontal, Theme.Space.m)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No spaces yet", systemImage: "cube.transparent")
        } description: {
            Text("Scan a room and it will show up here.")
        } actions: {
            Button("Scan a room") { router.selectedTab = .scan }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .containerRelativeFrame(.vertical)
    }

    private func errorState(_ cause: String) -> some View {
        ContentUnavailableView {
            Label("Can't load your library", systemImage: "wifi.exclamationmark")
        } description: {
            Text(cause)
        } actions: {
            Button { Task { await store.refresh() } } label: {
                BusyLabel(title: "Try again", busyTitle: "Try again", isBusy: store.isLoading)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(store.isLoading)
        }
        .containerRelativeFrame(.vertical)
    }

    private var cards: some View {
        LazyVStack(spacing: Theme.Space.m) {
            if LibraryListState.showsOfflineBanner(listState, consecutiveFailures: store.consecutiveFailures) {
                OfflineBanner()
                    .transition(.opacity)
            }
            ForEach(store.worlds) { world in
                NavigationLink(value: world.id) {
                    SpaceCard(world: world, upload: uploads[world.id], pollsFailing: store.consecutiveFailures > 0)
                }
                .buttonStyle(.plain)
                .contextMenu { menu(for: world) }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
            }
            if store.hasMore {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: Theme.minTarget)
                    .onAppear { Task { await store.loadMore() } }
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.bottom, Theme.Space.m)
        .animation(Theme.Motion.standard, value: store.worlds.map(\.id))
        .animation(Theme.Motion.standard, value: store.consecutiveFailures >= 2)
    }

    // MARK: - Context menu

    @ViewBuilder private func menu(for world: World) -> some View {
        if let cost = world.status.presentation().retry {
            Button {
                if cost == .needsConfirmation {
                    improveTarget = world
                } else {
                    Task { await retry(world) }
                }
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
                if cost == .usesScan { Text("Uses 1 of today's scans") }
            }
        }
        Button(role: .destructive) { pendingDelete = world } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func retry(_ world: World) async {
        switch await actions.run(.retry, on: world) {
        case .accepted: acceptedCount += 1
        case .scanQuota(let resetAt): toasts.show(APIError.scanQuota(resetAt: resetAt))
        default: break
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // The 5-tap debug gesture lives on the title; it keeps its header trait.
        ToolbarItem(placement: .largeTitle) {
            Text("Library")
                .font(.largeTitle.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .onTapGesture { registerTitleTap() }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            #if DEBUG
            Button("Debug logs", systemImage: "ladybug") { showDebugLog = true }
            #endif
            Button("Settings", systemImage: "gearshape") { showSettings = true }
        }
    }

    /// Five taps on the title within 2 s opens the debug log viewer. This is
    /// the release/TestFlight-safe entry point (no #if DEBUG).
    private func registerTitleTap() {
        let now = Date()
        if now.timeIntervalSince(firstTitleTapAt) > 2 {
            titleTapCount = 0
            firstTitleTapAt = now
        }
        titleTapCount += 1
        if titleTapCount >= 5 {
            titleTapCount = 0
            showDebugLog = true
        }
    }
}

/// "Offline. Showing your last update." (ui-spec 4.5): an ongoing condition,
/// so an inline banner, not a toast.
struct OfflineBanner: View {
    var body: some View {
        Label {
            Text("Offline. Showing your last update.").foregroundStyle(Theme.textPrimary)
        } icon: {
            Image(systemName: "wifi.slash").foregroundStyle(Theme.warning)
        }
        .font(.subheadline)
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    let api = APIClient()
    LibraryView()
        .environment(api)
        .environment(WorldStore(api: api))
        .environment(ToastCenter())
        .environment(AppRouter())
}
