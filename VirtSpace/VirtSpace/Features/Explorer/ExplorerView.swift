//
//  ExplorerView.swift
//  VirtSpace
//
//  Stage C: the full-screen immersive 3D world explorer (spec §6.4). A
//  WKWebView runs the bundled Spark viewer; native SwiftUI provides only the
//  chrome — a "Preparing your world…" loading ring (SplatCache download → the
//  in-page render progress bridge), an error state with Retry, a top-left close
//  X matching the capture chrome, and a first-run coach-mark overlay. Status
//  bar hidden and the idle timer disabled while presented.
//
//  Nav controls (joystick + drag-to-look) live inside the web page — a native→JS
//  bridge at 60 fps is too laggy (spec §3.1, §9).
//

import OSLog
import SwiftUI
import WebKit

struct ExplorerView: View {
    /// Where the world's SPZ comes from. `.file` is already local (bundled
    /// fixture or a pre-downloaded world); `.remote` is fetched via SplatCache
    /// with the loading ring.
    enum SplatSource: Equatable {
        case file(URL)
        case remote(worldId: String, version: Int, url: URL)
    }

    let source: SplatSource
    var title: String = "3D World"

    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case preparing(Double)   // SplatCache download (remote) — fraction or 0 if unknown
        case rendering(Double)   // WebView up, splats streaming — in-page bridge
        case ready
        case failed(String)
    }

    @State private var phase: Phase = .preparing(0)
    @State private var splatFileURL: URL?
    @State private var reloadToken = 0
    @State private var showCoach = false

    private static let coachKey = "explorer.coachSeen.v1"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let splatFileURL {
                ExplorerWebView(
                    splatURL: splatFileURL,
                    onProgress: { p in
                        if case .rendering = phase { phase = .rendering(p) }
                        else if !isReady { phase = .rendering(p) }
                    },
                    onLoaded: { phase = .ready },
                    onError: { message in phase = .failed(message) },
                    onInteraction: { dismissCoach() }
                )
                .id(reloadToken)
                .ignoresSafeArea()
            }

            if !isReady && !isFailed {
                loadingOverlay
            }
            if case .failed(let message) = phase {
                errorOverlay(message)
            }
            if showCoach && isReady {
                coachOverlay
            }

            closeButton
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task(id: reloadToken) { await prepare() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var isReady: Bool { phase == .ready }
    private var isFailed: Bool { if case .failed = phase { return true }; return false }

    // MARK: - Load

    private func prepare() async {
        switch source {
        case .file(let url):
            splatFileURL = url
            if case .preparing = phase { phase = .rendering(0) }
        case .remote(let worldId, let version, let url):
            do {
                let local = try await SplatCache.shared.ensure(
                    worldId: worldId, version: version, remoteURL: url
                ) { p in
                    Task { @MainActor in
                        if case .preparing = phase { phase = .preparing(p) }
                    }
                }
                splatFileURL = local
                phase = .rendering(0)
            } catch {
                phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func retry() {
        phase = .preparing(0)
        splatFileURL = nil
        reloadToken += 1
    }

    // MARK: - Coach marks

    private func dismissCoach() {
        guard showCoach else { return }
        showCoach = false
        UserDefaults.standard.set(true, forKey: Self.coachKey)
    }

    // MARK: - Overlays

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.001) // keep it above the (transparent) webview
            VStack(spacing: 20) {
                ProgressRing(progress: loadingFraction)
                    .frame(width: 66, height: 66)
                Text("Preparing your world…")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(loadingDetail)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .transition(.opacity)
    }

    private var loadingFraction: Double {
        switch phase {
        case .preparing(let p): return p
        case .rendering(let p): return p
        default: return 0
        }
    }

    private var loadingDetail: String {
        switch phase {
        case .preparing: return "Downloading"
        case .rendering: return "Rendering splats"
        default: return ""
        }
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.orange)
            Text("Couldn't open this world")
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

    private var coachOverlay: some View {
        // Non-blocking: touches pass through to the webview, which reports the
        // first interaction back over the bridge to dismiss this.
        VStack {
            Spacer()
            HStack(spacing: 24) {
                coachItem(icon: "hand.draw", text: "Drag to look around")
                coachItem(icon: "dpad", text: "Use the stick to walk")
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 22)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 170)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func coachItem(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.cyan)
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
        }
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.black.opacity(0.45), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
                }
                .padding(.leading, 16)
                .padding(.top, 12)
                Spacer()
            }
            Spacer()
        }
    }

    init(source: SplatSource, title: String = "3D World") {
        self.source = source
        self.title = title
        _showCoach = State(initialValue: !UserDefaults.standard.bool(forKey: Self.coachKey))
    }
}

// MARK: - ProgressRing

private struct ProgressRing: View {
    let progress: Double // 0…1; <=0 shows an indeterminate spinner

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
                IndeterminateArc()
            }
        }
    }
}

private struct IndeterminateArc: View {
    @State private var spinning = false
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.25)
            .stroke(Color.cyan, style: StrokeStyle(lineWidth: 5, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

// MARK: - ExplorerWebView (WKWebView bridge)

private struct ExplorerWebView: UIViewRepresentable {
    let splatURL: URL
    let onProgress: (Double) -> Void
    let onLoaded: () -> Void
    let onError: (String) -> Void
    let onInteraction: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress, onLoaded: onLoaded, onError: onError, onInteraction: onInteraction)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(ViewerSchemeHandler(splatURL: splatURL), forURLScheme: ViewerSchemeHandler.scheme)
        config.userContentController.add(context.coordinator, name: "viewer")
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.navigationDelegate = context.coordinator
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif

        var comps = URLComponents()
        comps.scheme = ViewerSchemeHandler.scheme
        comps.host = "app"
        comps.path = "/viewer.html"
        comps.queryItems = [URLQueryItem(name: "flip", value: "1")] // 180° X flip default (spec §3.1)
        webView.load(URLRequest(url: comps.url!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "viewer")
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onProgress: (Double) -> Void
        let onLoaded: () -> Void
        let onError: (String) -> Void
        let onInteraction: () -> Void

        init(onProgress: @escaping (Double) -> Void, onLoaded: @escaping () -> Void,
             onError: @escaping (String) -> Void, onInteraction: @escaping () -> Void) {
            self.onProgress = onProgress
            self.onLoaded = onLoaded
            self.onError = onError
            self.onInteraction = onInteraction
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "progress": onProgress((body["value"] as? Double) ?? 0)
            case "loaded": onLoaded()
            case "error": onError((body["message"] as? String) ?? "Unknown error")
            case "interaction": onInteraction()
            default: break
            }
        }

        /// Navigation allowlist (spec §10 R12). The viewer is a fully local
        /// page: the only navigations it can legitimately make are within the
        /// `virtspace-viewer` scheme (its page, its pinned modules, the SPZ).
        /// Anything else — an http(s) link, a data:/file: URL, a redirect out
        /// of a world's caption text — is a navigation we never intend, so it
        /// is cancelled rather than loaded into the explorer.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            let scheme = url?.scheme?.lowercased()
            // about:blank is WebKit's own initial/empty document, not a
            // navigation away from the viewer.
            if scheme == ViewerSchemeHandler.scheme || url?.absoluteString == "about:blank" {
                decisionHandler(.allow)
            } else {
                AppLog.viewer.log("Blocked viewer navigation to \(AppLog.redact(url), privacy: .public)")
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onError(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onError(error.localizedDescription)
        }
    }
}
