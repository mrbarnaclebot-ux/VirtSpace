//
//  LibraryView.swift
//  VirtSpace
//
//  The user's private gallery of scans (spec §6.3). Cards show title, status
//  chip, relative time, and thumbnail. Pull-to-refresh; while any world has an
//  active job the list polls every 3 s (Task-based, cancelled on disappear).
//

import SwiftUI

struct LibraryView: View {
    @Environment(APIClient.self) private var api

    @State private var worlds: [World] = []
    @State private var isLoading = false
    @State private var hasLoadedOnce = false
    @State private var toast: Toast?
    @State private var pollTask: Task<Void, Never>?

    // Debug log viewer entry (Stage B3 deliverable 3c).
    @State private var showDebugLog = false
    @State private var titleTapCount = 0
    @State private var firstTitleTapAt = Date.distantPast

    private var anyActive: Bool { worlds.contains { $0.status.isActive } }

    var body: some View {
        NavigationStack {
            Group {
                if worlds.isEmpty {
                    emptyState
                } else {
                    worldList
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(.systemBackground))
            .toast($toast)
            .toolbar {
                // A tappable title stands in for the nav title so the secret
                // gesture has a reliable hit target.
                ToolbarItem(placement: .principal) {
                    Text("Library")
                        .font(.headline)
                        .onTapGesture { registerTitleTap() }
                }
                // Wrench/ladybug shortcut — DEBUG builds only. TestFlight
                // (release) builds strip this, so the 5-tap-on-title gesture
                // below is the ALWAYS-available path to reach the log viewer.
                #if DEBUG
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showDebugLog = true
                    } label: {
                        Image(systemName: "ladybug")
                    }
                    .accessibilityLabel("Debug logs")
                }
                #endif
            }
            .sheet(isPresented: $showDebugLog) {
                DebugLogView()
            }
        }
        .task {
            if !hasLoadedOnce {
                await refresh(showErrors: true)
                hasLoadedOnce = true
            }
            startPollingIfNeeded()
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
        .onChange(of: anyActive) {
            startPollingIfNeeded()
        }
    }

    // MARK: - Subviews

    private var worldList: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(worlds) { world in
                    NavigationLink(value: world.id) {
                        WorldCard(world: world)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .refreshable { await refresh(showErrors: true) }
        .navigationDestination(for: String.self) { worldId in
            WorldDetailView(worldId: worldId, initialWorld: worlds.first { $0.id == worldId })
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 14) {
                Spacer(minLength: 120)
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)
                Text(hasLoadedOnce && !isLoading ? "No worlds yet" : "Loading…")
                    .font(.title3.weight(.semibold))
                Text("Capture a space and it will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .refreshable { await refresh(showErrors: true) }
    }

    // MARK: - Debug log gesture

    /// Five taps on the title within 2 s opens the debug log viewer. This is
    /// the release/TestFlight-safe entry point (no #if DEBUG), so the owner can
    /// pull logs from a build that has no debug toolbar button.
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

    // MARK: - Data

    private func refresh(showErrors: Bool) async {
        if isLoading { return }
        isLoading = true
        defer { isLoading = false }
        do {
            worlds = try await api.listWorlds()
        } catch {
            if showErrors, !Task.isCancelled {
                toast = Toast(error)
            }
        }
    }

    /// Polls listWorlds every 3 s while any world is in an active status.
    private func startPollingIfNeeded() {
        pollTask?.cancel()
        pollTask = nil
        guard anyActive else { return }
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
                await refresh(showErrors: false)
                if !anyActive { return }
            }
        }
    }
}

// MARK: - WorldCard

struct WorldCard: View {
    let world: World

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnail
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(world.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let place = world.placeName, !place.isEmpty {
                            Text(place)
                                .lineLimit(1)
                            Text("·")
                        }
                        Text(relativeTime)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                StatusChip(status: world.status)
            }
            .padding(12)
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var thumbnail: some View {
        ZStack {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color(.tertiarySystemBackground), Color(.secondarySystemBackground)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            // List items carry a thumbnail-only `assets` object from the API.
            if let url = world.assets?.thumbnailAsURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholderIcon
                    default:
                        ProgressView()
                    }
                }
            } else {
                placeholderIcon
            }
        }
        .frame(height: 150)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private var placeholderIcon: some View {
        Image(systemName: world.status.isActive ? "hourglass" : "cube.transparent")
            .font(.system(size: 30, weight: .light))
            .foregroundStyle(.tertiary)
    }

    private var relativeTime: String {
        guard let created = world.createdAt else { return "Just now" }
        return created.formatted(.relative(presentation: .named))
    }
}

// MARK: - StatusChip

struct StatusChip: View {
    let status: WorldStatus

    var body: some View {
        HStack(spacing: 5) {
            if status.isActive {
                ProgressView()
                    .controlSize(.mini)
                    .tint(status.tint)
            } else {
                Image(systemName: status.systemImage)
                    .font(.caption2)
            }
            Text(status.label)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(status.tint.opacity(0.14), in: Capsule())
    }
}

#Preview {
    LibraryView()
        .environment(APIClient())
        .preferredColorScheme(.dark)
}
