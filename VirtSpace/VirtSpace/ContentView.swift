//
//  ContentView.swift
//  VirtSpace
//
//  App shell: Capture · Library tab bar (v1 locked scope, spec §1).
//  Dark-mode-first, content-forward.
//

import SwiftUI

struct ContentView: View {
    @Environment(APIClient.self) private var api
    @Environment(ToastCenter.self) private var toasts
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            CaptureView(api: api, toasts: toasts, switchToLibrary: { router.selectedTab = .library })
                .tabItem {
                    Label("Capture", systemImage: "viewfinder")
                }
                .tag(AppRouter.Tab.scan)

            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "square.grid.2x2")
                }
                .tag(AppRouter.Tab.library)
        }
        .tint(.cyan)
        .preferredColorScheme(.dark)
    }
}

#Preview {
    let api = APIClient()
    ContentView()
        .environment(api)
        .environment(ToastCenter())
        .environment(WorldStore(api: api))
        .environment(AppRouter())
}
