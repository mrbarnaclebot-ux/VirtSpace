//
//  PanoSphereView.swift
//  VirtSpace
//
//  The 360° photo renderer: an inside-out SceneKit sphere (radius 10)
//  textured with the equirect image, the camera pinned at its centre. Drag
//  looks around (yaw/pitch, pitch clamped to 85 degrees); pinch zooms the
//  field of view 40 to 90 degrees. UIKit recognizers drive the camera for
//  60 fps look-around without a SwiftUI gesture round-trip.
//

import SceneKit
import SwiftUI

// MARK: - PanoSphereView (SceneKit)

/// Inside-out SCNSphere textured with the equirect pano, viewed from its centre.
/// UIKit pan/pinch recognizers drive the camera for 60 fps look-around without a
/// SwiftUI gesture round-trip.
struct PanoSphereView: UIViewRepresentable {
    let image: UIImage
    /// Called once, when the first drag starts (the hint fades out).
    var onFirstDrag: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(onFirstDrag: onFirstDrag) }

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = .black
        scnView.scene = context.coordinator.makeScene(image: image)
        scnView.pointOfView = context.coordinator.cameraNode
        scnView.isUserInteractionEnabled = true
        // We drive the camera ourselves; SceneKit's built-in orbit control would
        // move the camera off-centre.
        scnView.allowsCameraControl = false

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        scnView.addGestureRecognizer(pan)
        scnView.addGestureRecognizer(pinch)
        return scnView
    }

    func updateUIView(_ scnView: SCNView, context: Context) {
        context.coordinator.updateImage(image)
    }

    final class Coordinator: NSObject {
        let cameraNode = SCNNode()
        private var material: SCNMaterial?
        private var onFirstDrag: (() -> Void)?

        init(onFirstDrag: @escaping () -> Void) {
            self.onFirstDrag = onFirstDrag
        }

        /// Opening yaw: facing the capture's first shot. Shot 0 is the user's
        /// starting look direction, ARKit world -Z (the session starts with the
        /// camera looking down -Z), which the stitcher puts at lon ±180, the
        /// equirect's left/right edge (reproject.py: +Z at lon 0, image centre).
        /// With the `scale(-1,1,1)` + `.repeat` UV correction below, camera yaw
        /// 0 (SceneKit looks down -Z) shows texture u = 0, that same edge, and
        /// yaw -θ shows u = θ/360 (checked with an offscreen SceneKit render of
        /// a sector-coded texture). So 0 already faces shot 0 for pose-path
        /// panos; only pose-less fallback panos (nominal angles, shot 0 at lon
        /// 0) open behind it, and those would want `.pi`.
        static let initialYaw: Float = 0

        // Camera orientation, radians. yaw about +Y, pitch about +X.
        private var yaw: Float = initialYaw
        private var pitch: Float = 0
        private var panStartYaw: Float = 0
        private var panStartPitch: Float = 0

        private let minFOV: CGFloat = 40
        private let maxFOV: CGFloat = 90
        private var pinchStartFOV: CGFloat = 70

        func makeScene(image: UIImage) -> SCNScene {
            let scene = SCNScene()

            let sphere = SCNSphere(radius: 10)
            sphere.segmentCount = 96 // smooth enough for a full-res equirect
            let material = SCNMaterial()
            material.diffuse.contents = image
            material.isDoubleSided = false
            // Render the inside: cull the outward-facing (front) triangles so we
            // see the texture from the centre. wrapS .repeat + a horizontal flip
            // corrects the mirroring that inside-out viewing introduces.
            material.cullMode = .front
            material.diffuse.wrapS = .repeat
            material.diffuse.wrapT = .clamp
            material.diffuse.contentsTransform = SCNMatrix4MakeScale(-1, 1, 1)
            sphere.firstMaterial = material
            self.material = material

            let sphereNode = SCNNode(geometry: sphere)
            scene.rootNode.addChildNode(sphereNode)

            let camera = SCNCamera()
            camera.fieldOfView = 70
            camera.zNear = 0.1
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(0, 0, 0)
            applyOrientation()
            scene.rootNode.addChildNode(cameraNode)

            return scene
        }

        func updateImage(_ image: UIImage) {
            material?.diffuse.contents = image
        }

        private func applyOrientation() {
            // Yaw then pitch. eulerAngles applies in Z, Y, X order — with roll 0
            // this yields the expected look direction.
            cameraNode.eulerAngles = SCNVector3(pitch, yaw, 0)
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            if gesture.state == .began {
                panStartYaw = yaw
                panStartPitch = pitch
                onFirstDrag?()
                onFirstDrag = nil
            }
            let translation = gesture.translation(in: view)
            // Sensitivity scales with FOV so a zoomed-in view pans proportionally
            // slower. ~180° of look sweep across the view width at 70° FOV.
            let fov = CGFloat(cameraNode.camera?.fieldOfView ?? 70)
            let scale = Float(fov / 70) * (.pi / Float(max(view.bounds.width, 1)))
            yaw = panStartYaw - Float(translation.x) * scale
            pitch = panStartPitch - Float(translation.y) * scale
            // Clamp pitch to ±85° so the user can't roll past the poles.
            let limit = Float(85 * Double.pi / 180)
            pitch = max(-limit, min(limit, pitch))
            applyOrientation()
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let camera = cameraNode.camera else { return }
            if gesture.state == .began {
                pinchStartFOV = CGFloat(camera.fieldOfView)
            }
            // Pinch out (scale > 1) zooms in → smaller FOV.
            var fov = pinchStartFOV / gesture.scale
            fov = max(minFOV, min(maxFOV, fov))
            camera.fieldOfView = Double(fov)
        }
    }
}
