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
        // Never under XCTest: a hosted test run launches this app, and a test
        // must not reclaim (or start) real upload traffic — see TestEnvironment.
        guard !TestEnvironment.isRunningUnderXCTest else { return true }
        // Reconnect to the background session at launch so tasks that completed
        // out-of-process (app was suspended/killed mid-upload) are reclaimed.
        BackgroundUploadCoordinator.shared.activate()
        BackgroundUploadCoordinator.bundles.activate()
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
        let coordinator = [BackgroundUploadCoordinator.shared, .bundles].first { $0.sessionIdentifier == identifier }
        guard let coordinator else {
            completionHandler()
            return
        }
        coordinator.setBackgroundEventsCompletion(completionHandler)
    }
}

@main
struct VirtSpaceApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var apiClient: APIClient
    @State private var toasts = ToastCenter()
    @State private var worldStore: WorldStore
    @State private var router = AppRouter()
    @State private var onboarding = OnboardingStore()

    init() {
        let api = APIClient()
        _apiClient = State(initialValue: api)
        _worldStore = State(initialValue: WorldStore(api: api))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(apiClient)
                .environment(toasts)
                .environment(worldStore)
                .environment(router)
                .environment(onboarding)
                .onAppear { ToastWindow.install(toasts) }
                // Uploads are refused until the current terms are accepted
                // (UploadManager's consent guard). When the terms version was
                // bumped with a scan still waiting on disk, agreeing restarts
                // it right away instead of at the next launch.
                .onChange(of: onboarding.hasCurrentConsent) { _, hasConsent in
                    if hasConsent, !TestEnvironment.isRunningUnderXCTest {
                        UploadManager.shared.kickResume(api: apiClient)
                    }
                }
        }
        // Completion kick (launch + every return to foreground): finish any
        // pending session whose manifest shows createdWorldId + all frames
        // flagged uploaded by going straight to frames:done — recovery for
        // flows that died between the last frame PUT and frames:done. The
        // flow is app-scoped (UploadManager), never tied to a view.
        // Skipped entirely under XCTest: the hosted test bundle launches this
        // app, and this kick mints/completes REAL worlds (TestEnvironment).
        .onChange(of: scenePhase, initial: true) { _, phase in
            worldStore.setSceneActive(phase == .active)
            if phase == .active, !TestEnvironment.isRunningUnderXCTest {
                UploadManager.shared.kickStrandedRecovery(api: apiClient)
            }
        }
    }
}
