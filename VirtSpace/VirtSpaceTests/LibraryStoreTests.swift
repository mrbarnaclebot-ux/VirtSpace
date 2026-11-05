//
//  LibraryStoreTests.swift
//  VirtSpaceTests
//
//  WP2 acceptance "against the mock backend", run as WorldStore +
//  SpaceActions over a scripted StubBackend: error vs empty first load,
//  pagination past 20, the offline banner, and every :retry / delete answer
//  from ui-spec 7.4.
//

import Foundation
import Testing
@testable import VirtSpace

@Suite("Library against a stub backend")
struct LibraryStoreTests {
    private let backend = StubBackend()
    private let toasts = ToastCenter(isVoiceOverRunning: { false })
    private let router = AppRouter()

    private func makeStore() -> WorldStore { WorldStore(api: backend.makeAPI()) }

    private func state(_ store: WorldStore) -> LibraryListState {
        LibraryListState(isEmpty: store.worlds.isEmpty, hasLoaded: store.hasLoaded, lastError: store.lastError)
    }

    private func actions(_ store: WorldStore) -> SpaceActions {
        SpaceActions(api: backend.makeAPI(), store: store, toasts: toasts, router: router)
    }

    // MARK: List states and pagination

    @Test("A failed first load shows the error state, then an empty load shows empty")
    func errorThenEmpty() async {
        backend.on("GET /v1/worlds?offset=0", 0)
        backend.on("GET /v1/worlds?offset=0", 200, StubBackend.page([]))
        let store = makeStore()
        await store.refresh()
        #expect(state(store) == .failed(cause: "You're offline. Check your connection and try again."))
        await store.refresh()
        #expect(state(store) == .empty)
    }

    @Test("More than 20 spaces paginate without duplicates")
    func pagination() async {
        let first = (0..<20).map { StubBackend.world("w\($0)", "draft_ready") }
        // The second page overlaps by one (a space created in between).
        let second = (19..<25).map { StubBackend.world("w\($0)", "draft_ready") }
        backend.on("GET /v1/worlds?offset=0", 200, StubBackend.page(first, hasMore: true, nextOffset: 20))
        backend.on("GET /v1/worlds?offset=20", 200, StubBackend.page(second))
        let store = makeStore()
        await store.refresh()
        #expect(store.worlds.count == 20)
        #expect(store.hasMore)
        await store.loadMore()
        #expect(store.worlds.map(\.id) == (0..<25).map { "w\($0)" })
        #expect(!store.hasMore)
        await store.loadMore() // last page: no request
        #expect(backend.calls.filter { $0.hasPrefix("GET /v1/worlds?") }.count == 2)
    }

    @Test("Offline banner after 2 failed loads, never 'taking longer' meanwhile, gone on success")
    func offlineBanner() async throws {
        let page = StubBackend.page([StubBackend.world("a", "stitching")])
        backend.on("GET /v1/worlds?offset=0", 200, page)
        backend.on("GET /v1/worlds?offset=0", 0)
        backend.on("GET /v1/worlds?offset=0", 0)
        backend.on("GET /v1/worlds?offset=0", 200, page)
        let store = makeStore()
        await store.refresh()
        await store.refresh()
        #expect(!LibraryListState.showsOfflineBanner(state(store), consecutiveFailures: store.consecutiveFailures))
        await store.refresh()
        #expect(LibraryListState.showsOfflineBanner(state(store), consecutiveFailures: store.consecutiveFailures))
        let world = try #require(store.worlds.first)
        let stale = Date.now.addingTimeInterval(-600)
        #expect(!world.status.isSlow(heartbeatAt: stale, pollsFailing: store.consecutiveFailures > 0))
        await store.refresh()
        #expect(!LibraryListState.showsOfflineBanner(state(store), consecutiveFailures: store.consecutiveFailures))
    }

    // MARK: Retry answers (7.4)

    @Test("200 with or without job_id replaces the world; no toast", arguments: ["job-1", nil] as [String?])
    func retryAccepted(jobId: String?) async {
        backend.on("POST /v1/worlds/a:retry", 200, StubBackend.job("a", "stitching", jobId: jobId))
        let store = makeStore()
        store.insert(Fixtures.world(id: "a", status: "failed_stitch"))
        let outcome = await actions(store).run(.retry, on: store.worlds[0])
        #expect(outcome == .accepted(Fixtures.world(id: "a", status: "stitching").withTitle("Scan Nov 5")))
        #expect(store.world(id: "a")?.status == .stitching)
        #expect(toasts.current == nil)
    }

    @Test("409 refetches; toast only when the status did not change")
    func retryNotRetryable() async {
        backend.on("POST /v1/worlds/a:retry", 409, StubBackend.error("not_retryable"))
        backend.on("GET /v1/worlds/a", 200, StubBackend.envelope("a", "failed_stitch"))
        backend.on("POST /v1/worlds/b:retry", 409, StubBackend.error("not_retryable"))
        backend.on("GET /v1/worlds/b", 200, StubBackend.envelope("b", "stitching"))
        let store = makeStore()
        store.insert(Fixtures.world(id: "b", status: "failed_stitch"))
        store.insert(Fixtures.world(id: "a", status: "failed_stitch"))

        #expect(await actions(store).run(.retry, on: store.world(id: "b")!) == .movedOn)
        #expect(store.world(id: "b")?.status == .stitching)
        #expect(toasts.current == nil)

        #expect(await actions(store).run(.retry, on: store.world(id: "a")!) == .movedOn)
        #expect(toasts.current?.message == "This space can't be retried right now.")
    }

    @Test("429 scan quota is left to the card; rate limit toasts")
    func retryLimits() async {
        backend.on("POST /v1/worlds/a:retry", 429, StubBackend.error("scan_quota_exceeded"))
        backend.on("POST /v1/worlds/b:retry", 429, StubBackend.error("rate_limited"))
        let store = makeStore()
        store.insert(Fixtures.world(id: "a", status: "failed_generating_draft"))
        store.insert(Fixtures.world(id: "b", status: "failed_generating_draft"))
        #expect(await actions(store).run(.retry, on: store.world(id: "a")!) == .scanQuota(resetAt: nil))
        #expect(toasts.current == nil)
        _ = await actions(store).run(.retry, on: store.world(id: "b")!)
        #expect(toasts.current?.message == "Too many tries. Wait a moment and try again.")
        #expect(store.world(id: "b")?.status == .failed("failed_generating_draft"))
    }

    @Test("404 removes the space, pops to the Library and toasts")
    func retryGone() async {
        backend.on("POST /v1/worlds/a:retry", 404, StubBackend.error("world_not_found"))
        let store = makeStore()
        store.insert(Fixtures.world(id: "a", status: "failed_stitch"))
        router.open(worldId: "a")
        #expect(await actions(store).run(.retry, on: store.worlds[0]) == .gone)
        #expect(store.world(id: "a") == nil)
        #expect(router.libraryPath.isEmpty)
        #expect(toasts.current?.message == "This space was deleted.")
    }

    @Test("Offline retry toasts the offline copy and changes nothing")
    func retryOffline() async {
        backend.on("POST /v1/worlds/a:retry", 0)
        let store = makeStore()
        store.insert(Fixtures.world(id: "a", status: "failed_stitch"))
        _ = await actions(store).run(.retry, on: store.worlds[0])
        #expect(toasts.current?.message == "You're offline. Check your connection and try again.")
        #expect(store.world(id: "a")?.status == .failed("failed_stitch"))
    }

    @Test("Enhance 200 applies the returned status (not optimistic)")
    func enhanceAccepted() async {
        backend.on("POST /v1/worlds/a:enhance", 200, StubBackend.job("a", "generating_hq", jobId: "j"))
        let store = makeStore()
        store.insert(Fixtures.world(id: "a", status: "draft_ready"))
        _ = await actions(store).run(.enhance, on: store.worlds[0])
        #expect(store.world(id: "a")?.status == .generatingHq)
    }

    // MARK: Delete

    @Test("Delete: gone from the list only after the 2xx, with a toast")
    func deleteSucceeds() async {
        backend.on("DELETE /v1/worlds/a", 204, "")
        let store = makeStore()
        store.insert(Fixtures.world(id: "a", status: "draft_ready"))
        router.open(worldId: "a")
        #expect(await actions(store).delete(id: "a"))
        #expect(store.worlds.isEmpty)
        #expect(router.libraryPath.isEmpty)
        #expect(toasts.current?.message == "Space deleted.")
    }

    @Test("Delete failure keeps the space and the screen")
    func deleteFails() async {
        backend.on("DELETE /v1/worlds/a", 500, StubBackend.error("internal_error"))
        let store = makeStore()
        store.insert(Fixtures.world(id: "a", status: "draft_ready"))
        router.open(worldId: "a")
        #expect(!(await actions(store).delete(id: "a")))
        #expect(store.worlds.map(\.id) == ["a"])
        #expect(router.libraryPath == ["a"])
        #expect(toasts.current?.message == "Something went wrong on our side. Try again in a minute.")
    }
}

private extension World {
    func withTitle(_ title: String) -> World {
        var copy = self
        copy.title = title
        return copy
    }
}
