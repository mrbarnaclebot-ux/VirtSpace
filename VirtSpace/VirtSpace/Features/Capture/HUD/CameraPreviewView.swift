//
//  CameraPreviewView.swift
//  VirtSpace
//
//  The layer behind the HUD. On device: the live ARKit camera feed.
//
//  Implementation choice (Stage B2 deliverable 7): a minimal ARSCNView with
//  an empty scene. It is the least code that renders an externally-owned
//  ARSession's camera feed, it never runs or pauses the session (the
//  engine's ARKitCaptureSource stays the sole owner of the session
//  lifecycle), and it does not claim `ARSession.delegate` — SceneKit
//  observes frames through its own internal channel, so the engine's pose
//  stream is unaffected. An MTKView blitting `capturedImage` would avoid the
//  SceneKit dependency but costs ~10x the code for the same pixels.
//
//  In the simulator there is no camera: a stylized, slowly-breathing
//  gradient stands in so the HUD remains legible and demoable.
//

import SwiftUI

#if !targetEnvironment(simulator)
import ARKit
import SceneKit

struct CameraPreviewView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = false
        view.antialiasingMode = .none
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        if view.session !== session {
            view.session = session
        }
    }
}
#endif

/// Simulator stand-in for the camera feed: dark, ambient, subtly animated so
/// the world-locked HUD reads against something alive.
struct SimulatedCameraBackdrop: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Color.black
                RadialGradient(
                    colors: [Color.indigo.opacity(0.42), .clear],
                    center: UnitPoint(x: 0.5 + 0.09 * cos(t * 0.31), y: 0.42 + 0.07 * sin(t * 0.23)),
                    startRadius: 30,
                    endRadius: 430
                )
                RadialGradient(
                    colors: [Color.cyan.opacity(0.14), .clear],
                    center: UnitPoint(x: 0.42 + 0.11 * sin(t * 0.17), y: 0.62 + 0.08 * cos(t * 0.27)),
                    startRadius: 10,
                    endRadius: 330
                )
            }
        }
        .ignoresSafeArea()
    }
}
