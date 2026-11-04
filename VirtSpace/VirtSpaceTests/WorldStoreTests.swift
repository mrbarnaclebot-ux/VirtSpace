//
//  WorldStoreTests.swift
//  VirtSpaceTests
//
//  The store's poll decisions and local mutations, and the router. No
//  network: every store test leaves the poll loop stopped before its first
//  3 s tick.
//

import Foundation
import Testing
@testable import VirtSpace

@Suite("WorldStore")
struct WorldStoreTests {
    @Test("shouldPoll needs an active world and an active scene")
    func pollDecision() {
        #expect(WorldStore.shouldPoll([.stitching], sceneActive: true))
        #expect(!WorldStore.shouldPoll([.stitching], sceneActive: false))
        #expect(!WorldStore.shouldPoll([.draftReady, .complete, .failed("failed_stitch")], sceneActive: true))
        #expect(!WorldStore.shouldPoll([], sceneActive: true))
    }

    @Test("The poll loop stops when nothing is active and when the scene goes inactive")
    func pollLoopLifecycle() {
        let store = WorldStore(api: APIClient())
        store.insert(Fixtures.world(id: "a", status: "stitching"))
        #expect(!store.isPolling) // scene not active yet
        store.setSceneActive(true)
        #expect(store.isPolling)
        store.setSceneActive(false)
        #expect(!store.isPolling)
        store.setSceneActive(true)
        #expect(store.isPolling)
        store.replace(from: Fixtures.world(id: "a", status: "draft_ready"))
        #expect(!store.isPolling)
        store.insert(Fixtures.world(id: "b", status: "generating_hq"))
        #expect(store.isPolling)
        store.remove(id: "b")
        #expect(!store.isPolling)
    }

    @Test("insert puts a world on top once; replace keeps known assets")
    func mutations() throws {
        let store = WorldStore(api: APIClient())
        var a = Fixtures.world(id: "a", status: "draft_ready")
        a.assets = try JSONDecoder().decode(WorldAssets.self, from: Data(#"{"thumbnail_url":"https://t"}"#.utf8))
        store.insert(a)
        store.insert(Fixtures.world(id: "b", status: "draft_ready"))
        store.insert(a)
        #expect(store.worlds.map(\.id) == ["a", "b"])

        // A :retry answer carries no assets.
        store.replace(from: Fixtures.world(id: "a", status: "complete"))
        #expect(store.world(id: "a")?.status == .complete)
        #expect(store.world(id: "a")?.assets?.thumbnailURL == "https://t")

        store.remove(id: "a")
        #expect(store.world(id: "a") == nil)
        #expect(store.worlds.map(\.id) == ["b"])
    }
}

@Suite("AppRouter")
struct AppRouterTests {
    @Test("open(worldId:) selects Library and pushes the space")
    func open() {
        let router = AppRouter()
        router.libraryPath = ["old"]
        router.open(worldId: "w1")
        #expect(router.selectedTab == .library)
        #expect(router.libraryPath == ["w1"])
    }
}
