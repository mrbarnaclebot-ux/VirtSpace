//
//  AppLog.swift
//  VirtSpace
//
//  Persistent on-device logging (Stage B3 deliverable 3). Wraps os.Logger so
//  the whole app logs to a single subsystem with a handful of stable
//  categories. Entries written through here land in the unified log and are
//  readable back — even once the device is unplugged from Xcode — via
//  OSLogStore (see DebugLogView).
//
//  Privacy rules baked in here so call sites can't get them wrong:
//    • NEVER log auth tokens, bearer headers, or dev-user ids.
//    • URLs are always passed through `redact(_:)`, which strips the query
//      string (presigned R2 URLs carry signatures there) before logging.
//  Everything logged is treated as `.public` on purpose: these are our own
//  diagnostics and we want them legible in the in-app viewer. Do not log user
//  content or secrets through this path.
//

import Foundation
import OSLog

/// Logged from every queue in the app — the engine queue, the thumbnail queue,
/// URLSession delegate queues and the main actor. `Logger` is thread-safe.
nonisolated enum AppLog {
    /// One subsystem for the whole app; categories fan out by area.
    static let subsystem = "com.uzmanshafifassy.VirtSpace"

    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let upload = Logger(subsystem: subsystem, category: "upload")
    static let api = Logger(subsystem: subsystem, category: "api")
    static let engine = Logger(subsystem: subsystem, category: "engine")
    static let viewer = Logger(subsystem: subsystem, category: "viewer")

    /// Strip everything from `?` onward so presigned-URL signatures and query
    /// tokens never reach the log. Returns just scheme://host/path.
    static func redact(_ urlString: String?) -> String {
        guard let urlString, !urlString.isEmpty else { return "<none>" }
        if let components = URLComponents(string: urlString),
           let host = components.host {
            let scheme = components.scheme.map { "\($0)://" } ?? ""
            return "\(scheme)\(host)\(components.path)"
        }
        // Fallback: hard-cut at the first `?`.
        if let q = urlString.firstIndex(of: "?") {
            return String(urlString[..<q])
        }
        return urlString
    }

    static func redact(_ url: URL?) -> String {
        redact(url?.absoluteString)
    }
}
