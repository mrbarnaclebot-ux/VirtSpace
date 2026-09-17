//
//  ViewerSchemeHandler.swift
//  VirtSpace
//
//  WKURLSchemeHandler for the `virtspace-viewer://` scheme (spec §3.1).
//  `fetch()`/ES-module imports are blocked on file:// inside WKWebView, so the
//  Spark viewer page, its pinned three.js + Spark modules, and the world's SPZ
//  are all served through this handler instead.
//
//  Routing (host + last path component):
//    virtspace-viewer://app/viewer.html      → bundled viewer page   (text/html)
//    virtspace-viewer://app/three.module.js  → bundled module        (text/javascript)
//    virtspace-viewer://app/three.core.js    →   "  (three dep)
//    virtspace-viewer://app/spark.module.js  →   "
//    virtspace-viewer://app/Pass.js          →   "  (spark dep)
//    virtspace-viewer://assets/world.spz     → the splat file it's initialised with
//  Everything else is denied (404).
//
//  Requests are served synchronously on WebKit's calling (main) thread, so a
//  task can't be stopped mid-flight — no cross-thread WKURLSchemeTask races.
//

import Foundation
import WebKit

final class ViewerSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "virtspace-viewer"

    /// The world's SPZ on disk (cache file or bundled fixture). Served at
    /// `virtspace-viewer://assets/world.spz`.
    private let splatURL: URL

    /// Bundled code/page resources allowed under host `app`, by filename → MIME.
    private static let bundled: [String: String] = [
        "viewer.html": "text/html; charset=utf-8",
        "three.module.js": "text/javascript; charset=utf-8",
        "three.core.js": "text/javascript; charset=utf-8",
        "spark.module.js": "text/javascript; charset=utf-8",
        "Pass.js": "text/javascript; charset=utf-8",
    ]

    /// Memory-mapped SPZ bytes, kept across range requests. Spark issues many
    /// Range reads while loading a world and each one used to re-read the WHOLE
    /// file with `Data(contentsOf:)` — tens of megabytes copied per request
    /// (spec §10 R12). Mapped once, the OS pages in only the requested slice.
    private var cachedSplat: Data?
    /// Identity of the file `cachedSplat` was mapped from; when the file on
    /// disk changes (a re-download replaced it), the map is dropped and retaken.
    private var cachedSplatSignature: FileSignature?

    /// Cheap on-disk identity: size + modification date.
    private struct FileSignature: Equatable {
        let size: Int
        let modified: Date?
    }

    init(splatURL: URL) {
        self.splatURL = splatURL
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            fail(task, status: 400)
            return
        }
        let host = url.host ?? ""
        let name = url.lastPathComponent

        switch host {
        case "assets":
            // Only the single splat slot is exposed.
            guard name == "world.spz" else { fail(task, status: 404); return }
            serveSplat(task, url: url)
        case "app":
            guard let mime = Self.bundled[name], let fileURL = Self.bundledURL(name) else {
                fail(task, status: 404)
                return
            }
            guard let data = try? Data(contentsOf: fileURL) else { fail(task, status: 404); return }
            respond(task, url: url, data: data, mime: mime)
        default:
            fail(task, status: 404)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // Handled synchronously in start(); nothing in flight to cancel.
    }

    // MARK: - Serving

    /// SPZ bytes. Supports a single trivial `bytes=start-end` Range (206);
    /// otherwise a full 200 response.
    private func serveSplat(_ task: WKURLSchemeTask, url: URL) {
        guard let data = splatData() else { fail(task, status: 404); return }
        let mime = "application/octet-stream"

        if let range = task.request.value(forHTTPHeaderField: "Range"),
           let parsed = Self.parseRange(range, total: data.count) {
            let slice = data.subdata(in: parsed)
            let headers = [
                "Content-Type": mime,
                "Content-Length": "\(slice.count)",
                "Content-Range": "bytes \(parsed.lowerBound)-\(parsed.upperBound - 1)/\(data.count)",
                "Accept-Ranges": "bytes",
                "Access-Control-Allow-Origin": "*",
            ]
            let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!
            task.didReceive(response)
            task.didReceive(slice)
            task.didFinish()
            return
        }
        respond(task, url: url, data: data, mime: mime, extraHeaders: ["Accept-Ranges": "bytes"])
    }

    /// The SPZ bytes, memory-mapped once and reused for every range request.
    /// Re-maps when the file on disk changed. No locking needed: WebKit calls
    /// the handler on its own (main) thread and every request is served
    /// synchronously — see the file header.
    private func splatData() -> Data? {
        let signature = currentSplatSignature()
        if let cachedSplat, cachedSplatSignature == signature {
            return cachedSplat
        }
        guard let data = try? Data(contentsOf: splatURL, options: .mappedIfSafe) else {
            cachedSplat = nil
            cachedSplatSignature = nil
            return nil
        }
        cachedSplat = data
        cachedSplatSignature = signature
        return data
    }

    private func currentSplatSignature() -> FileSignature? {
        guard let values = try? splatURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        return FileSignature(size: size, modified: values.contentModificationDate)
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, mime: String, extraHeaders: [String: String] = [:]) {
        var headers = [
            "Content-Type": mime,
            "Content-Length": "\(data.count)",
            "Access-Control-Allow-Origin": "*",
        ]
        headers.merge(extraHeaders) { _, new in new }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: WKURLSchemeTask, status: Int) {
        if let url = task.request.url,
           let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) {
            task.didReceive(response)
        }
        task.didFinish()
    }

    // MARK: - Helpers

    /// Resolve a bundled SparkViewer resource. The filesystem-synchronized
    /// project flattens resources into the bundle root, but fall back to the
    /// SparkViewer subdirectory in case a future change nests them.
    static func bundledURL(_ filename: String) -> URL? {
        let ns = filename as NSString
        let name = ns.deletingPathExtension
        let ext = ns.pathExtension
        return Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "SparkViewer")
    }

    /// Parse `bytes=start-end` (single range) into a half-open Range<Int>.
    static func parseRange(_ header: String, total: Int) -> Range<Int>? {
        guard total > 0, header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return nil }
        let startStr = spec[spec.startIndex..<dash]
        let endStr = spec[spec.index(after: dash)...]
        let start = Int(startStr) ?? 0
        let end = endStr.isEmpty ? total - 1 : (Int(endStr) ?? total - 1)
        guard start >= 0, start <= end, start < total else { return nil }
        let upper = min(end, total - 1) + 1
        return start..<upper
    }
}
