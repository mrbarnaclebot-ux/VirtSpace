//
//  ContentView.swift
//  VirtSpace
//
//  App shell (ui-spec 3): Library, Scan tab bar (v1 locked scope, spec §1).
//  Follows the system appearance; the Scan tab stays dark. The last-used tab
//  is restored per scene; a first launch lands on Scan after onboarding.
//  Onboarding covers everything until the current terms are accepted.
//

import SwiftUI

struct ContentView: View {
    @Environment(APIClient.self) private var api
    @Environment(ToastCenter.self) private var toasts
    @Environment(AppRouter.self) private var router
    @Environment(OnboardingStore.self) private var onboarding

    /// Last-used tab. nil until the first tab change in this scene.
    @SceneStorage("shell.selectedTab") private var storedTab: AppRouter.Tab?
    /// The tabs render only after the stored tab is applied, so the wrong tab
    /// never appears for a frame.
    @State private var tabRestored = false

    var body: some View {
        Group {
            if tabRestored {
                tabs
            } else {
                Theme.bg.ignoresSafeArea().onAppear(perform: restoreTab)
            }
        }
        .fullScreenCover(isPresented: .constant(!onboarding.hasCurrentConsent)) {
            OnboardingView(store: onboarding)
        }
    }

    private var tabs: some View {
        @Bindable var router = router
        return TabView(selection: $router.selectedTab) {
            LibraryView()
                .tabItem { Label("Library", systemImage: "square.grid.2x2") }
                .tag(AppRouter.Tab.library)

            CaptureView(api: api, toasts: toasts, switchToLibrary: { router.selectedTab = .library })
                .environment(\.colorScheme, .dark)
                .toolbarColorScheme(.dark, for: .tabBar)
                .tabItem { Label("Scan", systemImage: "viewfinder") }
                .tag(AppRouter.Tab.scan)
        }
        .tint(Theme.accent)
        .onChange(of: router.selectedTab) { _, tab in storedTab = tab }
    }

    private func restoreTab() {
        router.selectedTab = storedTab ?? (onboarding.gate == .full ? .scan : .library)
        tabRestored = true
    }
}

#Preview {
    let api = APIClient()
    ContentView()
        .environment(api)
        .environment(ToastCenter())
        .environment(WorldStore(api: api))
        .environment(AppRouter())
        .environment(OnboardingStore())
}
