//
//  CameraPreviewView.swift
//  VirtSpace
//
//  The layer behind the HUD. On device: the live ARKit camera feed.
//
//  Implementation choice (Stage B2 deliverable 7): a minimal ARSCNView with
//  an (initially) empty scene. It is the least code that renders an
//  externally-owned ARSession's camera feed, it never runs or pauses the
//  session (the engine's ARKitCaptureSource stays the sole owner of the
//  session lifecycle), and it does not claim `ARSession.delegate` — SceneKit
//  observes frames through its own internal channel, so the engine's pose
//  stream is unaffected. An MTKView blitting `capturedImage` would avoid the
//  SceneKit dependency but costs ~10x the code for the same pixels.
//
//  Stage B3 deliverable 1 ("paint the sphere"): as shots land, we add textured
//  quads to that scene, one per PaintedShot, on a virtual sphere (radius
//  ~2.5 m) centered on the capture origin and oriented to the captured camera
//  transform — so the panorama visibly paints itself around the user while
//  uncaptured directions stay live camera feed. The preview runs at a modest
//  frame rate (it's a viewfinder, not a game) — 30 fps, dropping to 24 under
//  thermal pressure (deliverable 2d/2e).
//
//  In the simulator there is no camera: a stylized, slowly-breathing gradient
//  stands in, over which a Canvas paints a simplified equivalent of the same
//  quads using the shared projection math.
//

import simd
import SwiftUI

#if !targetEnvironment(simulator)
import ARKit
import SceneKit

struct CameraPreviewView: UIViewRepresentable {
    let session: ARSession
    /// Shots captured so far — each becomes one quad on the sphere.
    var paintedShots: [PaintedShot] = []
    /// Viewfinder frame rate (30 normally, 24 under thermal pressure).
    var preferredFPS: Int = 30

    /// Virtual sphere radius the quads sit on, meters.
    private let radius: Float = 2.5

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = false
        view.antialiasingMode = .none
        view.isUserInteractionEnabled = false
        // Cap the render loop: a viewfinder, not a game (deliverable 2d). The
        // live feed still updates every session frame, just rate-limited.
        view.preferredFramesPerSecond = preferredFPS
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        if view.session !== session {
            view.session = session
        }
        view.preferredFramesPerSecond = preferredFPS

        // Session reset (new scan) → clear painted quads.
        if paintedShots.isEmpty, !context.coordinator.addedIndices.isEmpty {
            view.scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }
            context.coordinator.addedIndices.removeAll()
            return
        }

        // Add a quad for each newly-arrived shot (idempotent via the Set).
        for shot in paintedShots where !context.coordinator.addedIndices.contains(shot.index) {
            context.coordinator.addedIndices.insert(shot.index)
            let node = Self.makeQuadNode(for: shot, radius: radius)
            view.scene.rootNode.addChildNode(node)
        }
    }

    /// Build a textured, unlit, single-sided quad sized to the camera FOV at
    /// `radius`, positioned that far along the captured camera's forward axis
    /// and oriented parallel to the image plane (front face toward the user).
    private static func makeQuadNode(for shot: PaintedShot, radius: Float) -> SCNNode {
        // Physical size subtending the camera FOV at `radius`:
        //   width  = radius · imageWidth  / fx
        //   height = radius · imageHeight / fy
        let fx = shot.intrinsics.columns.0.x
        let fy = shot.intrinsics.columns.1.y
        let width = fx > 1 ? radius * shot.approxImageWidth / fx : radius
        let height = fy > 1 ? radius * shot.approxImageHeight / fy : radius

        let plane = SCNPlane(width: CGFloat(max(0.01, width)), height: CGFloat(max(0.01, height)))
        let material = SCNMaterial()
        material.diffuse.contents = shot.thumbnail
        material.lightingModel = .constant // unlit
        material.isDoubleSided = false
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        material.writesToDepthBuffer = false
        plane.materials = [material]

        let node = SCNNode(geometry: plane)
        // Orient to the captured camera transform, then push the node `radius`
        // meters along camera-forward (-Z). Keeping the rotation means the
        // plane's +Z (its textured front, single-sided) faces back toward the
        // capture origin — i.e. toward the user.
        var t = shot.transform
        let forwardPoint = t * simd_float4(0, 0, -radius, 1)
        t.columns.3 = forwardPoint
        node.simdTransform = t

        // Slightly transparent with a soft fade-in.
        node.opacity = 0
        let fade = SCNAction.fadeOpacity(to: 0.9, duration: 0.45)
        fade.timingMode = .easeOut
        node.runAction(fade)
        return node
    }

    final class Coordinator {
        var addedIndices = Set<Int>()
    }
}
#endif

/// Simulator stand-in for the camera feed: dark, ambient, subtly animated so
/// the world-locked HUD reads against something alive — plus a cheap Canvas
/// "paint the sphere" overlay that projects each captured shot with the same
/// math the device SceneKit path uses (Stage B3 deliverable 1).
struct SimulatedCameraBackdrop: View {
    var paintedShots: [PaintedShot] = []
    var cameraTransform: simd_float4x4 = matrix_identity_float4x4
    var intrinsics: simd_float3x3 = matrix_identity_float3x3
    var imageResolution: CGSize = .zero

    var body: some View {
        ZStack {
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
            paintOverlay
        }
        .ignoresSafeArea()
    }

    /// Draws each painted shot as a quad centered on its projected direction,
    /// sized to the FOV — the simplified simulator equivalent of the device
    /// SceneKit quads. Cheap: axis-aligned image draws, no rotation.
    private var paintOverlay: some View {
        Canvas { context, size in
            guard !paintedShots.isEmpty else { return }
            let resolution = imageResolution == .zero ? size : imageResolution
            let focal = TargetProjection.focalLength(
                intrinsics: intrinsics, imageResolution: resolution, viewSize: size
            )
            // Painters' order: earliest shots first so newer overlaps older.
            for shot in paintedShots {
                let direction = AlignmentMath.forward(of: shot.transform)
                let projected = TargetProjection.project(
                    worldDirection: direction,
                    cameraTransform: cameraTransform,
                    intrinsics: intrinsics,
                    imageResolution: resolution,
                    viewSize: size
                )
                guard projected.isInFront else { continue }

                // On-screen size mirrors the device world-size (radius·2cx/fx)
                // reprojected: on screen that is focal·(2cx/fx) at the center.
                let fx = shot.intrinsics.columns.0.x
                let fy = shot.intrinsics.columns.1.y
                let w = fx > 1 ? 2 * focal * CGFloat(shot.intrinsics.columns.2.x / fx) : 200
                let h = fy > 1 ? 2 * focal * CGFloat(shot.intrinsics.columns.2.y / fy) : 200
                let rect = CGRect(
                    x: projected.point.x - w / 2,
                    y: projected.point.y - h / 2,
                    width: w, height: h
                )
                context.opacity = 0.9
                context.draw(context.resolve(Image(uiImage: shot.thumbnail)), in: rect)
            }
        }
        .allowsHitTesting(false)
    }
}
