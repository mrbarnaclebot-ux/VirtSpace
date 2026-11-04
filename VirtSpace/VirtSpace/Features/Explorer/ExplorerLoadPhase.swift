//
//  ExplorerLoadPhase.swift
//  VirtSpace
//
//  The Explorer's one loading arc (ui-spec 4.7, 7.3): step 1 downloads the
//  file (measured in bytes), step 2 opens it in the viewer (Spark's own load
//  progress). Each step has its own label and bar, so no bar ever runs 0 to
//  100 twice unexplained, and a bar never moves backwards. Pure value logic:
//  the view feeds it events and renders what it says.
//

import Foundation

/// What happens to the Explorer while it loads.
enum ExplorerEvent: Equatable {
    /// Download bytes (written, expected). `expected <= 0`: unknown size.
    case downloadProgress(Int64, Int64)
    /// The file is on disk; the viewer starts opening it.
    case downloaded
    /// Spark load progress, 0...1.
    case renderProgress(Double)
    case loaded
    /// The download or the page failed. `message` is user copy.
    case failed(String)
    /// The web content process died and was reloaded once.
    case reloading
    /// The web content process died again: give up, offer Reload.
    case closedUnexpectedly
}

enum ExplorerLoadPhase: Equatable {
    enum Failure: Equatable {
        case load(String)
        case closedUnexpectedly
    }

    case downloading(received: Int64, expected: Int64)
    case opening(Double)
    case ready
    case failed(Failure)

    static let start = ExplorerLoadPhase.downloading(received: 0, expected: 0)

    func applying(_ event: ExplorerEvent) -> ExplorerLoadPhase {
        switch (self, event) {
        case (.failed, _):
            return self
        case (.downloading(let old, _), .downloadProgress(let received, let expected)):
            return .downloading(received: max(old, received), expected: expected)
        case (.downloading, .downloaded):
            return .opening(0)
        case (.opening(let old), .renderProgress(let p)):
            return .opening(max(old, min(1, p)))
        case (.opening, .loaded):
            return .ready
        case (_, .failed(let message)):
            return .failed(.load(message))
        case (_, .reloading):
            return .opening(0)
        case (_, .closedUnexpectedly):
            return .failed(.closedUnexpectedly)
        default:
            return self
        }
    }

    var isLoading: Bool {
        switch self {
        case .downloading, .opening: true
        case .ready, .failed: false
        }
    }

    /// 1 (download) or 2 (open) while loading.
    var step: Int? {
        switch self {
        case .downloading: 1
        case .opening: 2
        case .ready, .failed: nil
        }
    }

    /// The current step's bar value; nil means indeterminate.
    var fraction: Double? {
        switch self {
        case .downloading(let received, let expected) where expected > 0:
            return min(1, Double(received) / Double(expected))
        case .opening(let p) where p > 0:
            return p
        default:
            return nil
        }
    }

    /// Step 1's label: "Downloading · 12 of 40 MB" while the size is known.
    var downloadLabel: String {
        guard case .downloading(let received, let expected) = self, expected > 0 else { return "Downloading" }
        return "Downloading · \(Self.megabytes(received, roundUp: false)) of \(Self.megabytes(expected, roundUp: true)) MB"
    }

    static let openingLabel = "Almost ready"
    static let title = "Opening your space"

    /// Decimal MB, like Files. The total rounds up so a small file never reads
    /// "0 MB"; the count rounds down so it never reads done before it is.
    static func megabytes(_ bytes: Int64, roundUp: Bool) -> Int {
        let mb = Double(max(0, bytes)) / 1_000_000
        return roundUp ? max(1, Int(mb.rounded(.up))) : Int(mb.rounded(.down))
    }
}

extension ExplorerLoadPhase.Failure {
    var title: String {
        switch self {
        case .load: "Couldn't open this space"
        case .closedUnexpectedly: "This space closed unexpectedly."
        }
    }

    var message: String? {
        if case .load(let message) = self { return message }
        return nil
    }

    var buttonTitle: String {
        switch self {
        case .load: "Try again"
        case .closedUnexpectedly: "Reload"
        }
    }
}

enum ViewerErrorCopy {
    static let generic = "Something went wrong. Try again."

    /// User copy for a failed download (ui-spec 6 Errors): offline reads as
    /// offline, anything else is the generic line. Never raw error text.
    static func message(for error: Error) -> String {
        let apiError = (error as? APIError) ?? .network(error)
        return apiError.errorDescription ?? generic
    }
}
