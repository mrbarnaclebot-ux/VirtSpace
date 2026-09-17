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
//  Session attachment is DEFERRED (crash fix, iOS 27): the ARSession is handed
//  to the ARSCNView on a main-actor hop, never from inside SwiftUI's make /
//  update pass. See CameraPreviewHost below for the full why.
//

import simd
import SwiftUI

#if !targetEnvironment(simulator)
import ARKit
import SceneKit
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let session: ARSession
    /// Shots captured so far — each becomes one quad on the sphere.
    var paintedShots: [PaintedShot] = []
    /// Viewfinder frame rate (30 normally, 24 under thermal pressure).
    var preferredFPS: Int = 30

    /// Virtual sphere radius the quads sit on, meters.
    private let radius: Float = 2.5

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> CameraPreviewHost {
        let host = CameraPreviewHost(frame: .zero)
        let view = host.sceneView
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = false
        view.antialiasingMode = .none
        view.isUserInteractionEnabled = false
        // Cap the render loop: a viewfinder, not a game (deliverable 2d). The
        // live feed still updates every session frame, just rate-limited.
        view.preferredFramesPerSecond = preferredFPS
        // Deliberately NOT `view.session = session` here — that assignment is
        // what crashed on iOS 27 when made from inside SwiftUI's update pass
        // (see CameraPreviewHost). The host applies it on a later hop.
        host.attach(session)
        return host
    }

    func updateUIView(_ host: CameraPreviewHost, context: Context) {
        // A session swap (new scan) takes the same deferred, guarded route:
        // assigning it inline here would re-enter ARKit's lock exactly as
        // makeUIView's assignment did.
        host.attach(session)

        let view = host.sceneView
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

    /// Teardown. We only drop the queued attach so a hop that outlives the
    /// representable can't touch a stale session; we deliberately do NOT hand
    /// the ARSCNView a different session to "detach" it, because re-assigning
    /// `session` is precisely the call that re-enters ARKit's lock, and
    /// dismantle runs inside SwiftUI's update pass. The engine's
    /// ARKitCaptureSource owns the session lifecycle and has already stopped it
    /// by the time this view goes away — this view never runs or pauses it.
    static func dismantleUIView(_ host: CameraPreviewHost, coordinator: Coordinator) {
        host.cancelPendingAttach()
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

/// Wrapper that owns the ARSCNView and gives it the ARSession from OUTSIDE
/// SwiftUI's make/update pass.
///
/// WHY (crash fix — EXC_BREAKPOINT, "Trying to recursively lock an
/// os_unfair_lock", main thread, iOS 27): `-[ARSession setViewLayer:]` takes
/// the session's unfair lock and, while still holding it, synchronously
/// delivers the current preview rotation angle to the view. ARSCNView responds
/// by publishing an orientation swap, which runs a UIKit layout pass inline,
/// which re-enters SwiftUI's graph update. When the original assignment came
/// from `makeUIView`, SwiftUI has no view for this representable yet, so the
/// re-entrant update calls `makeUIView` a SECOND time — a second
/// `setSession:` on the same ARSession, whose `setViewLayer:` then tries to
/// take the lock the outer call is still holding, and libplatform aborts.
///
/// Hopping the assignment onto the main actor means `makeUIView` has long
/// returned before ARKit re-enters, so the worst case is a redundant
/// `updateUIView` (a no-op — the session is already pending/attached) instead
/// of a recursive `makeUIView`. `isAttaching` is a second fuse for the case
/// where the inline layout pass drains the main queue re-entrantly.
///
/// Like the ARSCNView it wraps, this view never runs or pauses the session:
/// the engine's ARKitCaptureSource stays the sole owner of that lifecycle.
final class CameraPreviewHost: UIView {
    let sceneView = ARSCNView(frame: .zero)

    /// The session we've been asked to show. Cleared on dismantle so a hop
    /// that outlives the representable can't attach to a stale session.
    private var pendingSession: ARSession?
    /// True while `setSession:` is on the stack — re-entrancy fuse.
    private var isAttaching = false
    /// At most one hop in flight at a time.
    private var isAttachScheduled = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        sceneView.frame = bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(sceneView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CameraPreviewHost is code-only")
    }

    /// Ask for `session` to be shown. Safe to call from inside a SwiftUI
    /// update and idempotent: the assignment itself happens on a later hop.
    func attach(_ session: ARSession) {
        guard pendingSession !== session else { return }
        pendingSession = session
        scheduleAttach()
    }

    /// Drop the queued attach (representable torn down).
    func cancelPendingAttach() {
        pendingSession = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // The hop can fire before SwiftUI has put us on screen; try again now
        // that it has — still deferred, never inline, because this callback is
        // itself delivered from inside SwiftUI's update.
        if window != nil { scheduleAttach() }
    }

    private func scheduleAttach() {
        guard !isAttachScheduled, pendingSession != nil else { return }
        isAttachScheduled = true
        // A main-actor hop, NOT a synchronous call: this has to land after
        // SwiftUI's current graph update has unwound.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isAttachScheduled = false
            self.attachIfNeeded()
        }
    }

    /// Attaches at most once per session identity, and only while we're really
    /// on screen — a view already torn down (or pointed at a newer session)
    /// never touches the old one.
    private func attachIfNeeded() {
        guard !isAttaching, window != nil else { return }
        guard let session = pendingSession, sceneView.session !== session else { return }
        isAttaching = true
        defer { isAttaching = false }
        sceneView.session = session
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
