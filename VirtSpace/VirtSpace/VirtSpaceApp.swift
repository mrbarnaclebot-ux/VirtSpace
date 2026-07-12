//
//  VirtSpaceApp.swift
//  VirtSpace
//
//  Created by Uzman Fassy on 2026-07-11.
//

import SwiftUI
import UIKit

/// UIKit app delegate — needed purely to receive the background-URLSession
/// relaunch event. When the system finishes frame uploads while the app is
/// suspended/terminated, it relaunches us here so the upload session can deliver
/// its completion events (spec §7.1: uploads must survive backgrounding).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Reconnect to the background session at launch so tasks that completed
        // out-of-process (app was suspended/killed mid-upload) are reclaimed.
        BackgroundUploadCoordinator.shared.activate()
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // Hand the stored completion handler to the coordinator; it fires once
        // urlSessionDidFinishEvents reports all background events delivered, so
        // UIKit can snapshot and re-suspend the app.
        guard identifier == BackgroundUploadCoordinator.sessionIdentifier else {
            completionHandler()
            return
        }
        BackgroundUploadCoordinator.shared.setBackgroundEventsCompletion(completionHandler)
    }
}

@main
struct VirtSpaceApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var apiClient = APIClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(apiClient)
        }
    }
}
