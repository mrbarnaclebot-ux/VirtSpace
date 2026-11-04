//
//  ExplorerWebView.swift
//  VirtSpace
//
//  The WKWebView that runs the bundled Spark viewer (viewer.html), plus its
//  message bridge. Nav controls (joystick + drag-to-look) live inside the page:
//  a native-to-JS bridge at 60 fps is too laggy (spec §3.1, §9).
//

import OSLog
import SwiftUI
import WebKit

struct ExplorerWebView: UIViewRepresentable {
    /// What the page reports back.
    enum Message {
        case phase(ExplorerEvent)
        case interaction
        /// The joystick's frame in the web view's coordinates (CSS px = pt).
        case stickFrame(CGRect)
    }

    let splatURL: URL
    let onMessage: (Message) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onMessage: onMessage) }

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
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = context.coordinator
        #if DEBUG
        webView.isInspectable = true
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
        let onMessage: (Message) -> Void

        /// Content-process deaths seen by this web view. Reload builds a new
        /// web view (and coordinator), so the count starts over there.
        private var processTerminations = 0

        init(onMessage: @escaping (Message) -> Void) {
            self.onMessage = onMessage
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "progress": onMessage(.phase(.renderProgress((body["value"] as? Double) ?? 0)))
            case "loaded": onMessage(.phase(.loaded))
            case "error": pageFailed(body["message"] as? String ?? "unknown")
            case "interaction": onMessage(.interaction)
            case "stick": stickFrame(body).map { onMessage(.stickFrame($0)) }
            default: break
            }
        }

        private func stickFrame(_ body: [String: Any]) -> CGRect? {
            guard let x = body["x"] as? Double, let y = body["y"] as? Double,
                  let w = body["width"] as? Double, let h = body["height"] as? Double else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }

        /// Page or navigation failures carry developer text (a JS exception,
        /// "WebGL2 is not available"). Log it; show the user the generic line.
        private func pageFailed(_ detail: String) {
            AppLog.viewer.error("Viewer failed: \(detail, privacy: .public)")
            onMessage(.phase(.failed(ViewerErrorCopy.generic)))
        }

        /// Navigation allowlist (spec §10 R12). The viewer is a fully local
        /// page: the only navigations it can legitimately make are within the
        /// `virtspace-viewer` scheme (its page, its pinned modules, the SPZ).
        /// Anything else is cancelled rather than loaded into the explorer.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            let scheme = url?.scheme?.lowercased()
            // about:blank is WebKit's own initial/empty document.
            if scheme == ViewerSchemeHandler.scheme || url?.absoluteString == "about:blank" {
                decisionHandler(.allow)
            } else {
                AppLog.viewer.log("Blocked viewer navigation to \(AppLog.redact(url), privacy: .public)")
                decisionHandler(.cancel)
            }
        }

        /// iOS kills the WebGL content process under memory pressure or in the
        /// background, leaving a permanently black viewer (spec §10 R31).
        /// Reload once (the loading screen comes back); a second death in the
        /// same view shows "This space closed unexpectedly." with Reload,
        /// which rebuilds everything.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            processTerminations += 1
            AppLog.viewer.error("Viewer web content process terminated (\(self.processTerminations))")
            if processTerminations == 1 {
                onMessage(.phase(.reloading))
                webView.reload()
            } else {
                onMessage(.phase(.closedUnexpectedly))
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            pageFailed(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            pageFailed(error.localizedDescription)
        }
    }
}
