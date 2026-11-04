//
//  SettingsView.swift
//  VirtSpace
//
//  Settings (ui-spec 8), a sheet from the Library toolbar gear: How to scan,
//  Storage (downloaded copies, with real sizes and Clear downloads), About
//  (Terms, Privacy, Acknowledgements, Version), Developer (DEBUG only) and
//  Account. Account is hidden under dev auth (SettingsRows), because there
//  every install shares one library.
//

import SwiftUI

struct SettingsView: View {
    @Environment(APIClient.self) private var api
    @Environment(WorldStore.self) private var store
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    /// Cache sizes; nil while measuring.
    @State private var spaceBytes: Int64?
    @State private var photoBytes: Int64?
    @State private var isClearing = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false

    private let rows = SettingsRows.current

    var body: some View {
        NavigationStack {
            Form {
                Section("How to scan") {
                    NavigationLink("How to scan") { SettingsOnboardingLinks.howToScan() }
                }
                storageSection
                aboutSection
                #if DEBUG
                if rows.showsDeveloper { SettingsDeveloperSection() }
                #endif
                if rows.showsDeleteAccount { accountSection }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await measure() }
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section {
            sizeRow("3D spaces", bytes: spaceBytes)
            sizeRow("360° photos", bytes: photoBytes)
            Button {
                Task { await clearDownloads() }
            } label: {
                HStack {
                    Text("Clear downloads")
                    Spacer()
                    if isClearing { ProgressView() }
                }
            }
            .disabled(isClearing || totalBytes == 0)
        } header: {
            Text("Storage")
        } footer: {
            Text("Downloaded copies of your spaces. Clearing them frees space; they download again when you open them.")
        }
    }

    private var totalBytes: Int64 { (spaceBytes ?? 0) + (photoBytes ?? 0) }

    private func sizeRow(_ title: String, bytes: Int64?) -> some View {
        LabeledContent(title) {
            Text(SettingsRows.formatBytes(bytes ?? 0))
                .monospacedDigit()
                .redacted(reason: bytes == nil ? .placeholder : [])
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            NavigationLink("Terms of use") { SettingsOnboardingLinks.termsOfUse() }
            NavigationLink("Privacy") { PrivacyPage() }
            NavigationLink {
                AcknowledgementsPage()
            } label: {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text("Acknowledgements")
                    Text("3D spaces are generated using World Labs.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            LabeledContent("Version", value: Self.versionString)
        }
    }

    // MARK: - Account (real auth only)

    private var accountSection: some View {
        Section("Account") {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                HStack {
                    Text("Delete account")
                    Spacer()
                    if isDeleting { ProgressView() }
                }
            }
            .disabled(isDeleting)
            .confirmationDialog("Delete your account?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete account", role: .destructive) { Task { await deleteAccount() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All your spaces and scans will be erased. This can't be undone.")
            }
        }
    }

    // MARK: - Actions

    private func measure() async {
        spaceBytes = await SplatCache.shared.totalBytes()
        photoBytes = await PanoCache.shared.totalBytes()
    }

    private func clearDownloads() async {
        isClearing = true
        defer { isClearing = false }
        await SplatCache.shared.clear()
        await PanoCache.shared.clear()
        await measure()
        toasts.show("Downloads cleared", style: .success)
    }

    /// After the server confirms: local copies and the shared store go, and
    /// consent resets so the app returns to onboarding (ui-spec 8).
    private func deleteAccount() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await api.deleteAccount()
            await SplatCache.shared.clear()
            await PanoCache.shared.clear()
            for world in store.worlds { store.remove(id: world.id) }
            SettingsOnboardingLinks.replayOnboarding()
            dismiss()
        } catch {
            toasts.show(error)
        }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

#Preview {
    let api = APIClient()
    SettingsView()
        .environment(api)
        .environment(WorldStore(api: api))
        .environment(ToastCenter())
}
