//
//  AppRouter.swift
//  VirtSpace
//
//  App-level navigation state (ui-spec 3): which tab is selected and the
//  Library stack's path. Replaces ad-hoc "switch to Library" closures.
//
//    @Environment(AppRouter.self) private var router
//    router.open(worldId: world.id)   // e.g. after an upload succeeds
//    NavigationStack(path: $router.libraryPath) { ... }
//        .navigationDestination(for: String.self) { worldId in ... }
//

import Observation

@Observable
final class AppRouter {
    enum Tab: String, Hashable {
        case library
        case scan
    }

    var selectedTab: Tab = .scan
    /// Library NavigationStack path: world ids, pushed as `String` values.
    var libraryPath: [String] = []

    /// Show one space's Detail on top of the Library root.
    func open(worldId: String) {
        selectedTab = .library
        libraryPath = [worldId]
    }
}
