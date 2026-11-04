//
//  CaptureDebugToolsView.swift
//  VirtSpace
//
//  DEBUG-only capture-screen tooling, kept from Stage A: a one-frame test scan
//  that exercises createWorld → presigned frame upload → frames:done against
//  the configured backend, and the bundled-fixture explorer (no backend).
//  Compiled out of Release entirely.
//

#if DEBUG
import SwiftUI
import UIKit

struct CaptureDebugToolsView: View {
    @Environment(APIClient.self) private var api
    let model: CaptureScreenModel

    @State private var isRunningTestScan = false
    @State private var showFixtureExplorer = false

    var body: some View {
        VStack(spacing: 12) {
            testScanButton
            fixtureExplorerButton
        }
        .padding(.bottom, 24)
        .fullScreenCover(isPresented: $showFixtureExplorer) {
            if let url = ViewerSchemeHandler.bundledURL("fixture.spz") {
                ExplorerView(source: .file(url), title: "Fixture World")
            } else {
                missingFixtureView
            }
        }
    }

    private var testScanButton: some View {
        Button {
            Task { await runTestScan() }
        } label: {
            HStack(spacing: 8) {
                if isRunningTestScan {
                    ProgressView().controlSize(.small).tint(.black)
                    Text("Running test scan…")
                } else {
                    Image(systemName: "ladybug")
                    Text("Run test scan")
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(Color.cyan, in: Capsule())
            .foregroundStyle(.black)
        }
        .disabled(isRunningTestScan)
    }

    /// Opens the bundled bedroom fixture straight in the 3D explorer —
    /// exercises Spark/WKWebView with zero backend dependency (Stage C).
    private var fixtureExplorerButton: some View {
        Button {
            showFixtureExplorer = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "cube.transparent")
                Text("Explore fixture world")
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .foregroundStyle(.cyan)
            .overlay(Capsule().stroke(.cyan.opacity(0.6), lineWidth: 1.5))
        }
    }

    private var missingFixtureView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "questionmark.folder")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.orange)
                Text("fixture.spz isn't bundled in this build.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                Button("Close") { showFixtureExplorer = false }
                    .tint(.cyan)
            }
        }
    }

    private func runTestScan() async {
        isRunningTestScan = true
        defer { isRunningTestScan = false }
        do {
            let frame = Self.makeGradientJPEG()
            // Keyed like a real capture, so a replayed request can't mint a
            // second billable world.
            let (world, uploads, _) = try await api.createWorld(title: "Test Scan", frameCount: 1, idempotencyKey: UUID())
            guard let slot = uploads.first else {
                throw APIError.localState("Backend returned no upload slots")
            }
            try await FrameUploader().upload(frame, to: slot)
            try await api.framesDone(worldId: world.id)
            await model.announceUploadedAndSwitch("Test scan started — watch it in Library.")
        } catch {
            model.toasts.show(error)
        }
    }

    /// 1024x512 horizontal-gradient JPEG rendered in-memory.
    private static func makeGradientJPEG() -> Data {
        let size = CGSize(width: 1024, height: 512)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            let colors = [UIColor.systemIndigo.cgColor, UIColor.systemCyan.cgColor, UIColor.systemTeal.cgColor]
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors as CFArray,
                locations: [0, 0.5, 1]
            )!
            ctx.cgContext.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: size.width, y: 0),
                options: []
            )
        }
        return image.jpegData(compressionQuality: 0.85) ?? Data()
    }
}
#endif
