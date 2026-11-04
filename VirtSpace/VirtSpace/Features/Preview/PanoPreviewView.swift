//
//  PanoPreviewView.swift
//  VirtSpace
//
//  360° photo (ui-spec 4.8): the space's stitched equirectangular photo on an
//  inside-out sphere (PanoSphereView). Always dark. Glass 44 pt Close and
//  Save to Photos buttons, a loading state, an error state with Try again,
//  and a hint that fades out after the first drag. Saving asks for add-only
//  Photos access; a denial offers Settings in an alert.
//
//  `.remote` downloads and caches through PanoCache (world id + asset
//  version); `.file` loads a local image (the DEBUG fixture in Settings).
//

import OSLog
import Photos
import SwiftUI

struct PanoPreviewView: View {
    enum Source: Equatable {
        case file(URL)
        case remote(worldId: String, version: Int, url: URL)
    }

    let source: Source
    var title: String = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(ToastCenter.self) private var toasts

    private enum Phase: Equatable {
        case loading(Double)   // download fraction, 0 = unknown
        case ready
        case failed(String)    // user copy
    }

    @State private var phase: Phase = .loading(0)
    @State private var image: UIImage?
    @State private var reloadToken = 0
    @State private var isSaving = false
    @State private var showHint = true
    @State private var showPhotosDenied = false

    static let damagedCopy = "This photo is damaged. Try again to download it fresh."

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                PanoSphereView(image: image, onFirstDrag: hideHint)
                    .ignoresSafeArea()
                    .accessibilityLabel("360° photo")
            }
            if case .loading(let fraction) = phase {
                loadingView(fraction)
                    .transition(.opacity)
            }
            if case .failed(let message) = phase {
                ViewerErrorView(title: "Couldn't open this photo", message: message,
                                buttonTitle: "Try again", action: retry)
                    .transition(.opacity)
            }
            chrome
        }
        .animation(Theme.Motion.standard, value: phase)
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task(id: reloadToken) { await load() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .alert("Allow VirtSpace to add photos in Settings.", isPresented: $showPhotosDenied) {
            Button("Open Settings") { openSettings() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Load

    private func load() async {
        switch source {
        case .file(let url):
            show(UIImage(contentsOfFile: url.path))
        case .remote(let worldId, let version, let url):
            do {
                let local = try await PanoCache.shared.ensure(worldId: worldId, version: version, remoteURL: url) { p in
                    Task { @MainActor in
                        if case .loading(let old) = phase, p > old { phase = .loading(p) }
                    }
                }
                let decoded = UIImage(contentsOfFile: local.path)
                if decoded == nil { await PanoCache.shared.remove(worldId: worldId, version: version) }
                show(decoded)
            } catch {
                guard !Task.isCancelled else { return }
                AppLog.viewer.error("360 photo download failed: \(error.localizedDescription, privacy: .public)")
                phase = .failed(ViewerErrorCopy.message(for: error))
            }
        }
    }

    private func show(_ decoded: UIImage?) {
        guard let decoded else {
            phase = .failed(Self.damagedCopy)
            return
        }
        image = decoded
        phase = .ready
    }

    private func retry() {
        image = nil
        phase = .loading(0)
        reloadToken += 1
    }

    private func hideHint() {
        guard showHint else { return }
        withAnimation(Theme.Motion.exit) { showHint = false }
    }

    // MARK: - Save to Photos

    private func saveToPhotos() async {
        guard let image, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            showPhotosDenied = true
            return
        }
        do {
            try await Self.addToPhotos(image)
            toasts.show("Saved to Photos", style: .success)
        } catch {
            AppLog.viewer.error("Save to Photos failed: \(error.localizedDescription, privacy: .public)")
            toasts.show("Couldn't save to Photos.", style: .error)
        }
    }

    /// Nonisolated: Photos runs the change block on its own queue.
    nonisolated private static func addToPhotos(_ image: UIImage) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    // MARK: - Chrome

    private func loadingView(_ fraction: Double) -> some View {
        VStack(spacing: Theme.Space.m) {
            if fraction > 0 {
                ProgressView(value: fraction)
                    .tint(Theme.accent)
                    .frame(maxWidth: 240)
                    .animation(Theme.Motion.standard, value: fraction)
            } else {
                ViewerSpinner()
            }
            Text("Loading 360° photo")
                .font(.headline)
        }
        .accessibilityElement(children: .combine)
    }

    private var chrome: some View {
        VStack {
            HStack {
                ViewerIconButton(systemName: "xmark", label: "Close") { dismiss() }
                Spacer()
                if phase == .ready {
                    ViewerIconButton(systemName: "square.and.arrow.down", label: "Save to Photos", busy: isSaving) {
                        Task { await saveToPhotos() }
                    }
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.s)
            Spacer()
            if phase == .ready && showHint {
                Label("Drag to look around. Pinch to zoom.", systemImage: "hand.draw")
                    .font(.footnote.weight(.medium))
                    .padding(.vertical, Theme.Space.s)
                    .padding(.horizontal, Theme.Space.m)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, Theme.Space.xl)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
    }
}
