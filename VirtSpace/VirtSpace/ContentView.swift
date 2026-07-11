//
//  ContentView.swift
//  VirtSpace
//
//  App shell: Capture · Library tab bar (v1 locked scope, spec §1).
//  Dark-mode-first, content-forward.
//

import SwiftUI

struct ContentView: View {
    private enum Tab: Hashable {
        case capture
        case library
    }

    @State private var selectedTab: Tab = .capture

    var body: some View {
        TabView(selection: $selectedTab) {
            CaptureView(switchToLibrary: { selectedTab = .library })
                .tabItem {
                    Label("Capture", systemImage: "viewfinder")
                }
                .tag(Tab.capture)

            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "square.grid.2x2")
                }
                .tag(Tab.library)
        }
        .tint(.cyan)
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
        .environment(APIClient())
}
