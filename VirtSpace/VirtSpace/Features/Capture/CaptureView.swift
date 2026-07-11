//
//  CaptureView.swift
//  VirtSpace
//
//  Stage A placeholder for the guided 360° capture (lands in Stage B).
//  Includes a DEBUG-only "Run test scan" harness that exercises the REAL
//  pipeline: generate a gradient JPEG in-memory → createWorld → presigned
//  upload via FrameUploader → framesDone → route to Library to watch it run.
//

import SwiftUI
#if DEBUG
import UIKit
#endif

struct CaptureView: View {
    @Environment(APIClient.self) private var api

    /// Set by the app shell so the harness can route to the Library tab.
    var switchToLibrary: () -> Void = {}

    @State private var toast: Toast?
    @State private var isRunningTestScan = false

    var body: some View {
        NavigationStack {
            ZStack {
                backdrop
                VStack(spacing: 18) {
                    Spacer()
                    captureSphere
                    VStack(spacing: 8) {
                        Text("Guided 360° Capture")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                        Text("Coming in Stage B — stand on one spot, follow the targets, and VirtSpace turns your surroundings into a walkable 3D world.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.65))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)
                    }
                    Spacer()
                    #if DEBUG
                    testScanButton
                        .padding(.bottom, 24)
                    #endif
                }
            }
            .navigationBarHidden(true)
            .toast($toast)
        }
    }

    // MARK: - Visuals

    private var backdrop: some View {
        ZStack {
            Color.black
            RadialGradient(
                colors: [Color.indigo.opacity(0.35), .clear],
                center: .init(x: 0.5, y: 0.38),
                startRadius: 20,
                endRadius: 340
            )
        }
        .ignoresSafeArea()
    }

    private var captureSphere: some View {
        ZStack {
            // Concentric rings suggesting the capture sphere.
            ForEach(0..<3, id: \.self) { ring in
                Circle()
                    .strokeBorder(
                        Color.white.opacity(0.10 + Double(2 - ring) * 0.06),
                        style: StrokeStyle(lineWidth: 1, dash: ring == 1 ? [4, 6] : [])
                    )
                    .frame(width: 150 + CGFloat(ring) * 44, height: 150 + CGFloat(ring) * 44)
            }
            // Target dots on the outer ring.
            ForEach(0..<8, id: \.self) { i in
                let angle = Double(i) / 8 * 2 * .pi
                Circle()
                    .fill(i == 2 ? Color.cyan : Color.white.opacity(0.25))
                    .frame(width: i == 2 ? 10 : 7, height: i == 2 ? 10 : 7)
                    .offset(x: cos(angle) * 119, y: sin(angle) * 119)
            }
            Image(systemName: "viewfinder")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(.cyan)
        }
        .frame(height: 260)
    }

    // MARK: - DEBUG test-scan harness

    #if DEBUG
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

    /// On-device E2E harness: exercises createWorld → presigned frame upload →
    /// framesDone against the real backend, then routes to Library.
    private func runTestScan() async {
        isRunningTestScan = true
        defer { isRunningTestScan = false }
        do {
            let frame = Self.makeGradientJPEG()
            let (world, uploads) = try await api.createWorld(title: "Test Scan", frameCount: 1)
            guard let slot = uploads.first else {
                throw APIError.server(0, "Backend returned no upload slots")
            }
            try await FrameUploader().upload(frame, to: slot)
            try await api.framesDone(worldId: world.id)
            toast = Toast(message: "Test scan started — watch it in Library.", style: .success)
            try? await Task.sleep(for: .milliseconds(700))
            switchToLibrary()
        } catch {
            toast = Toast(error)
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
    #endif
}

#Preview {
    CaptureView()
        .environment(APIClient())
        .preferredColorScheme(.dark)
}
