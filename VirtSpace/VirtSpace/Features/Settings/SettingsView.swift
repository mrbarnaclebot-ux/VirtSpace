//
//  SettingsView.swift
//  VirtSpace
//
//  App settings, reachable from the gear on the Library toolbar (spec §13).
//  Shows app version/build, the dev user id (display only), on-device storage
//  usage for the splat + pano caches with a "Clear cache" action, a World Labs
//  attribution row (spec §13), a link-less privacy blurb, and Delete account
//  (red, double-confirmation) → DELETE /v1/account, which clears local caches
//  and drops the app into a signed-out placeholder state.
//

import SwiftUI

struct SettingsView: View {
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var splatBytes: Int64 = 0
    @State private var panoBytes: Int64 = 0
    @State private var isMeasuring = true
    @State private var isClearing = false

    @State private var showDeleteConfirm1 = false
    @State private var showDeleteConfirm2 = false
    @State private var isDeleting = false
    /// Set after a successful account deletion. In dev-auth there is no real
    /// session to sign out of, so we swap to a fresh-install-like placeholder.
    @State private var accountDeleted = false

    @Environment(ToastCenter.self) private var toasts

    #if DEBUG
    @State private var fixturePano: PanoFixture?
    struct PanoFixture: Identifiable { let id = UUID(); let url: URL }
    #endif

    private var totalBytes: Int64 { splatBytes + panoBytes }

    var body: some View {
        NavigationStack {
            Group {
                if accountDeleted {
                    signedOutPlaceholder
                } else {
                    settingsForm
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await measure() }
        #if DEBUG
        .fullScreenCover(item: $fixturePano) { fixture in
            PanoPreviewView(source: .file(fixture.url), title: "Fixture Pano")
        }
        #endif
    }

    // MARK: - Form

    private var settingsForm: some View {
        Form {
            aboutSection
            storageSection
            attributionSection
            privacySection
            #if DEBUG
            debugSection
            #endif
            accountSection
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Self.versionString)
            LabeledContent("User") {
                Text(Secrets.devUserId)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var storageSection: some View {
        Section {
            LabeledContent("3D worlds") {
                Text(isMeasuring ? "—" : Self.formatBytes(splatBytes))
                    .foregroundStyle(.secondary)
            }
            LabeledContent("360° photos") {
                Text(isMeasuring ? "—" : Self.formatBytes(panoBytes))
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                Task { await clearCaches() }
            } label: {
                HStack {
                    Text("Clear cache")
                    Spacer()
                    if isClearing { ProgressView().controlSize(.small) }
                }
            }
            .disabled(isClearing || isMeasuring || totalBytes == 0)
        } header: {
            Text("Storage")
        } footer: {
            Text("Cached downloads only. Your worlds stay safe in the cloud and re-download on demand. Currently using \(isMeasuring ? "…" : Self.formatBytes(totalBytes)).")
        }
    }

    private var attributionSection: some View {
        Section {
            Label("3D worlds generated using World Labs", systemImage: "sparkles")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } header: {
            Text("Attribution")
        }
    }

    private var privacySection: some View {
        Section {
            Text("""
            VirtSpace captures photos of your surroundings to build 3D worlds. \
            Your photos are uploaded to our servers and to World Labs, which \
            generates the 3D reconstruction. Location is optional and only used \
            to tag a scan with where it was captured. Worlds are private by \
            default. Raw capture frames are deleted after processing. A full \
            privacy policy will be linked here before public release.
            """)
            .font(.footnote)
            .foregroundStyle(.secondary)
        } header: {
            Text("Privacy")
        }
    }

    #if DEBUG
    private var debugSection: some View {
        Section {
            Button {
                openFixturePano()
            } label: {
                Label("Preview fixture pano", systemImage: "pano")
            }
        } header: {
            Text("Debug")
        } footer: {
            Text("Renders a synthetic equirect image in PanoPreviewView — exercises the 360° viewer with no backend and no bundled asset.")
        }
    }
    #endif

    private var accountSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirm1 = true
            } label: {
                HStack {
                    Text("Delete account")
                    Spacer()
                    if isDeleting { ProgressView().controlSize(.small) }
                }
            }
            .disabled(isDeleting)
        } header: {
            Text("Account")
        } footer: {
            Text("Permanently deletes your account, all your worlds, and their assets from our servers. This cannot be undone.")
        }
        // Double confirmation: the destructive dialog only opens the final,
        // even-more-explicit confirmation.
        .confirmationDialog(
            "Delete your account?",
            isPresented: $showDeleteConfirm1,
            titleVisibility: .visible
        ) {
            Button("Continue", role: .destructive) { showDeleteConfirm2 = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes your account and every world you've created. You can't undo this.")
        }
        .confirmationDialog(
            "This is permanent",
            isPresented: $showDeleteConfirm2,
            titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) { Task { await deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All your worlds and data will be erased and cannot be recovered. Delete your account?")
        }
    }

    // MARK: - Signed-out placeholder

    private var signedOutPlaceholder: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("Account deleted")
                .font(.title2.weight(.bold))
            Text("Your account and all your worlds have been removed. Close VirtSpace — the next launch starts fresh.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func measure() async {
        isMeasuring = true
        splatBytes = await SplatCache.shared.totalBytes()
        panoBytes = await PanoCache.shared.totalBytes()
        isMeasuring = false
    }

    private func clearCaches() async {
        isClearing = true
        defer { isClearing = false }
        await SplatCache.shared.clear()
        await PanoCache.shared.clear()
        await measure()
        toasts.show("Cache cleared.", style: .success)
    }

    private func deleteAccount() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await api.deleteAccount()
            // Wipe on-device caches so nothing survives the deletion. Dev-auth
            // has no session to invalidate; real Sign in with Apple (later stage)
            // would clear the token and route back to a sign-in screen here.
            await SplatCache.shared.clear()
            await PanoCache.shared.clear()
            accountDeleted = true
        } catch {
            toasts.show(error)
        }
    }

    #if DEBUG
    private func openFixturePano() {
        guard let url = Self.makeFixturePano() else {
            toasts.show("Couldn't render the fixture pano.", style: .error)
            return
        }
        fixturePano = PanoFixture(url: url)
    }

    /// A synthetic 2:1 equirectangular test image (color bands + a lat/long grid
    /// so orientation is obvious), written to a temp file. Zero bundle bloat.
    private static func makeFixturePano() -> URL? {
        let size = CGSize(width: 2048, height: 1024)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            // Vertical sky→ground gradient.
            let colors = [UIColor.systemIndigo.cgColor, UIColor.systemTeal.cgColor, UIColor.brown.cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.5, 1])!
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            // Longitude/latitude grid every 30°.
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.35).cgColor)
            cg.setLineWidth(2)
            for lon in stride(from: 0.0, through: 360.0, by: 30.0) {
                let x = size.width * lon / 360
                cg.move(to: CGPoint(x: x, y: 0)); cg.addLine(to: CGPoint(x: x, y: size.height))
            }
            for lat in stride(from: 0.0, through: 180.0, by: 30.0) {
                let y = size.height * lat / 180
                cg.move(to: CGPoint(x: 0, y: y)); cg.addLine(to: CGPoint(x: size.width, y: y))
            }
            cg.strokePath()
            // A bright marker at yaw 0 so look-direction is unmistakable.
            UIColor.systemYellow.setFill()
            cg.fillEllipse(in: CGRect(x: size.width / 2 - 40, y: size.height / 2 - 40, width: 80, height: 80))
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-pano.jpg")
        do { try data.write(to: url); return url } catch { return nil }
    }
    #endif

    // MARK: - Helpers

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes == 0 { return "Empty" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#Preview {
    SettingsView()
        .environment(APIClient())
        .environment(ToastCenter())
        .preferredColorScheme(.dark)
}
