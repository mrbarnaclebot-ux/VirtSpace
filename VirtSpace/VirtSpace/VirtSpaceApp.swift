//
//  VirtSpaceApp.swift
//  VirtSpace
//
//  Created by Uzman Fassy on 2026-07-11.
//

import SwiftUI

@main
struct VirtSpaceApp: App {
    @State private var apiClient = APIClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(apiClient)
        }
    }
}
