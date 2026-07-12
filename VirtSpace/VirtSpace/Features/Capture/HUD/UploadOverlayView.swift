//
//  UploadOverlayView.swift
//  VirtSpace
//
//  Full-screen handoff shown the moment a capture finishes: a progress ring
//  driven by CaptureUploader's per-frame callback ("Uploading your space…
//  i/16"), after which CaptureView routes to the Library.
//

import SwiftUI

struct UploadOverlayView: View {
    let uploaded: Int
    let total: Int

    private var fraction: Double {
        total > 0 ? Double(uploaded) / Double(total) : 0
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()

            VStack(spacing: 26) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(
                            AngularGradient(
                                colors: [.cyan, .teal, .cyan],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: fraction)
                    Text("\(uploaded)/\(total)")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .animation(.default, value: uploaded)
                }
                .frame(width: 118, height: 118)

                VStack(spacing: 6) {
                    Text("Uploading your space…")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Keep VirtSpace open — this only takes a moment.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .transition(.opacity)
    }
}

#Preview {
    UploadOverlayView(uploaded: 6, total: 16)
        .preferredColorScheme(.dark)
}
