//
//  PanoPreviewView.swift
//  VirtSpace
//
//  Full-screen 2D 360° panorama viewer for a world's stitched equirectangular
//  pano (spec §6.4; assets.pano_url now points at a real backend-produced
//  pano). A SceneKit sphere (radius 10) is rendered from the inside — front
//  faces culled / geometry inverted so we look out onto the texture — with the
//  camera pinned at the sphere's centre. Drag looks around (camera yaw/pitch,
//  pitch clamped ±85°); pinch zooms the field of view 40–90°. Dark chrome
//  matches ExplorerView: a close X, a loading ring, an error+retry state, plus
//  a "Save to Photos" action.
//
//  The remote image is fetched + disk-cached by PanoCache (keyed on world id +
//  asset_version). A `.file` source loads a local image directly — used for
//  the DEBUG fixture preview in Settings, and for any manual smoke test.
//

import Photos
import SceneKit
import SwiftUI

struct PanoPreviewView: View {
    /// Where the equirect pano comes from. `.file` is already local (a bundled
    /// or pre-downloaded image); `.remote` is fetched + cached via PanoCache
    /// with the loading ring.
    enum Source: Equatable {
        case file(URL)
        case remote(worldId: String, version: Int, url: URL)
    }

    let source: Source
    var title: String = "360° Photo"

    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case loading(Double)   // download fraction (0 = unknown/indeterminate)
        case ready
        case failed(String)
    }

    @State private var phase: Phase = .loading(0)
    @State private var image: UIImage?
    @State private var reloadToken = 0
    @State private var toast: Toast?
    @State private var isSaving = false
    // Retained for the duration of a Photos save (UIKit completion target).
    @State private var photoSaver: PhotoSaver?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                PanoSphereView(image: image)
                    .ignoresSafeArea()
            }

            if case .loading = phase { loadingOverlay }
            if case .failed(let message) = phase { errorOverlay(message) }

            chrome
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .toast($toast)
        .task(id: reloadToken) { await load() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var isReady: Bool { phase == .ready }

    // MARK: - Load

    private func load() async {
        switch source {
        case .file(let url):
            if let img = UIImage(contentsOfFile: url.path) {
                image = img
                phase = .ready
            } else {
                phase = .failed("Couldn't read this image.")
            }
        case .remote(let worldId, let version, let url):
            do {
                let local = try await PanoCache.shared.ensure(
                    worldId: worldId, version: version, remoteURL: url
                ) { p in
                    Task { @MainActor in
                        if case .loading = phase { phase = .loading(p) }
                    }
                }
                guard let img = UIImage(contentsOfFile: local.path) else {
                    phase = .failed("The downloaded panorama couldn't be decoded.")
                    return
                }
                image = img
                phase = .ready
            } catch {
                phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func retry() {
        image = nil
        phase = .loading(0)
        reloadToken += 1
    }

    // MARK: - Save to Photos

    private func saveToPhotos() {
        guard let image, !isSaving else { return }
        isSaving = true
        let saver = PhotoSaver { error in
            Task { @MainActor in
                isSaving = false
                photoSaver = nil
                if let error {
                    toast = Toast(message: "Couldn't save: \(error.localizedDescription)", style: .error)
                } else {
                    toast = Toast(message: "Saved to Photos.", style: .success)
                }
            }
        }
        photoSaver = saver
        saver.save(image)
    }

    // MARK: - Overlays / chrome

    private var loadingOverlay: some View {
        VStack(spacing: 20) {
            PanoProgressRing(progress: loadingFraction)
                .frame(width: 66, height: 66)
            Text("Loading 360° photo…")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Downloading")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
        }
        .transition(.opacity)
    }

    private var loadingFraction: Double {
        if case .loading(let p) = phase { return p }
        return 0
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.orange)
            Text("Couldn't open this photo")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                retry()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.headline)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
                    .background(Color.cyan, in: Capsule())
                    .foregroundStyle(.black)
            }
        }
        .padding(30)
        .transition(.opacity)
    }

    private var chrome: some View {
        VStack {
            HStack {
                circleButton("xmark") { dismiss() }
                    .padding(.leading, 16)
                Spacer()
                if isReady {
                    circleButton(isSaving ? nil : "square.and.arrow.down", busy: isSaving) {
                        saveToPhotos()
                    }
                    .padding(.trailing, 16)
                }
            }
            .padding(.top, 12)
            Spacer()
            if isReady {
                Label("Drag to look around · pinch to zoom", systemImage: "hand.draw")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.vertical, 10)
                    .padding(.horizontal, 18)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 34)
            }
        }
    }

    private func circleButton(_ systemName: String?, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView().controlSize(.small).tint(.white)
                } else if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 40, height: 40)
            .background(.black.opacity(0.45), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
        }
        .disabled(busy)
    }

    init(source: Source, title: String = "360° Photo") {
        self.source = source
        self.title = title
    }
}

// MARK: - PhotoSaver

/// Bridges `UIImageWriteToSavedPhotosAlbum`'s NSObject completion selector to a
/// Swift closure. The photo-library-add purpose string ships in build settings.
private final class PhotoSaver: NSObject {
    private let completion: (Error?) -> Void
    init(completion: @escaping (Error?) -> Void) { self.completion = completion }

    func save(_ image: UIImage) {
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(didFinish(_:error:contextInfo:)), nil)
    }

    @objc private func didFinish(_ image: UIImage, error: Error?, contextInfo: UnsafeRawPointer) {
        completion(error)
    }
}

// MARK: - PanoProgressRing

private struct PanoProgressRing: View {
    let progress: Double // 0…1; <=0 shows an indeterminate spinner

    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: 5)
            if progress > 0 {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, progress)))
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: progress)
            } else {
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
                    .onAppear { spinning = true }
            }
        }
    }
}

// MARK: - PanoSphereView (SceneKit)

/// Inside-out SCNSphere textured with the equirect pano, viewed from its centre.
/// UIKit pan/pinch recognizers drive the camera for 60 fps look-around without a
/// SwiftUI gesture round-trip.
private struct PanoSphereView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

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
