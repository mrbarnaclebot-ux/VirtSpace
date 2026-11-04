//
//  WorldStore.swift
//  VirtSpace
//
//  The app-scoped source of truth for the user's spaces (ui-spec 11 WP1):
//  the Library list, a by-id detail cache, pagination, and ONE poll loop that
//  runs only while some world is active and the scene is active. Screens read
//  it from the environment and never keep their own copies, so a world
//  created on Scan or deleted on Detail shows up everywhere at once.
//
//    @Environment(WorldStore.self) private var store
//    await store.refresh()                       // first page (pull to refresh)
//    await store.loadMore()                      // last card appeared
//    try await store.fetch(id: id)               // Detail; 404 removes it
//    store.insert(world) / store.remove(id:) / store.replace(from: world)
//

import Foundation
import Observation

@Observable
final class WorldStore {
    /// Library order, newest first.
    private(set) var worlds: [World] = [] { didSet { updatePolling() } }
    /// Detail responses (world + presigned assets) by world id.
    private(set) var details: [String: WorldEnvelope] = [:] { didSet { updatePolling() } }
    private(set) var hasMore = false
    /// A list load has succeeded at least once (empty vs. not loaded yet).
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    /// The most recent failure of a load, fetch or poll; nil after a success.
    private(set) var lastError: Error?
    /// Loads/polls that failed in a row. The offline banner shows at 2.
    private(set) var consecutiveFailures = 0

    /// True while the poll loop is scheduled.
    var isPolling: Bool { pollTask != nil }

    static let pollInterval: Duration = .seconds(3)

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private var nextOffset: Int?
    @ObservationIgnored private var sceneActive = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(api: APIClient) {
        self.api = api
    }

    /// The freshest copy of a world: the detail cache, else the list.
    func world(id: String) -> World? {
        details[id]?.world ?? worlds.first { $0.id == id }
    }

    // MARK: Loading

    /// Reload the first page, replacing the list.
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await api.listWorlds()
            worlds = page.worlds
            apply(page)
            hasLoaded = true
            recordSuccess()
        } catch {
            recordFailure(error)
        }
    }

    /// Append the next page, if any.
    func loadMore() async {
        guard hasMore, let offset = nextOffset, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await api.listWorlds(offset: offset)
            let known = Set(worlds.map(\.id))
            worlds += page.worlds.filter { !known.contains($0.id) }
            apply(page)
            recordSuccess()
        } catch {
            recordFailure(error)
        }
    }

    /// Fetch one world's detail and fold it into the list. A 404 removes the
    /// world from the store before rethrowing `.notFound`.
    @discardableResult
    func fetch(id: String) async throws -> WorldEnvelope {
        do {
            let envelope = try await load(id: id)
            recordSuccess()
            return envelope
        } catch let error as APIError where error.isWorldGone {
            throw error
        } catch {
            recordFailure(error)
            throw error
        }
    }

    // MARK: Local mutations

    /// A world the app just created or learned of; goes to the top.
    func insert(_ world: World) {
        worlds.removeAll { $0.id == world.id }
        worlds.insert(world, at: 0)
    }

    /// Call only after the server confirmed the delete (or answered 404).
    func remove(id: String) {
        worlds.removeAll { $0.id == id }
        details[id] = nil
    }

    /// Fold in a newer copy, e.g. the `world` from a `:retry` / `:enhance`
    /// answer. Keeps the assets already known when the copy carries none.
    func replace(from world: World) {
        if let index = worlds.firstIndex(where: { $0.id == world.id }) {
            var updated = world
            updated.assets = world.assets ?? worlds[index].assets
            worlds[index] = updated
        }
        if let envelope = details[world.id] {
            details[world.id] = WorldEnvelope(world: world, assets: envelope.assets)
        }
    }

    // MARK: Polling

    /// Wire to `scenePhase == .active`. Polling never runs in the background.
    func setSceneActive(_ active: Bool) {
        sceneActive = active
        updatePolling()
    }

    /// The poll decision: some world is active, and so is the scene.
    static func shouldPoll(_ statuses: [WorldStatus], sceneActive: Bool) -> Bool {
        sceneActive && statuses.contains { $0.isActive }
    }

    private var allIDs: Set<String> { Set(worlds.map(\.id)).union(details.keys) }

    private var activeIDs: [String] {
        allIDs.filter { world(id: $0)?.status.isActive == true }
    }

    private func updatePolling() {
        let statuses = allIDs.compactMap { world(id: $0)?.status }
        guard Self.shouldPoll(statuses, sceneActive: sceneActive) else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, let self else { return }
                await self.pollActive()
            }
        }
    }

    /// One tick: refetch each active world. Counts as one success or failure.
    private func pollActive() async {
        var failure: Error?
        for id in activeIDs {
            do {
                _ = try await load(id: id)
            } catch let error as APIError where error.isWorldGone {
                continue
            } catch {
                failure = error
            }
        }
        if let failure { recordFailure(failure) } else { recordSuccess() }
    }

    // MARK: Plumbing

    private func load(id: String) async throws -> WorldEnvelope {
        do {
            let envelope = try await api.getWorld(id: id)
            var listCopy = envelope.world
            listCopy.assets = envelope.assets
            replace(from: listCopy)
            details[id] = envelope
            return envelope
        } catch let error as APIError where error.isWorldGone {
            remove(id: id)
            throw error
        }
    }

    private func apply(_ page: WorldsListResponse) {
        hasMore = page.hasMore ?? false
        nextOffset = page.nextOffset
    }

    private func recordSuccess() {
        lastError = nil
        consecutiveFailures = 0
    }

    private func recordFailure(_ error: Error) {
        guard !Task.isCancelled else { return }
        lastError = error
        consecutiveFailures += 1
    }
}
