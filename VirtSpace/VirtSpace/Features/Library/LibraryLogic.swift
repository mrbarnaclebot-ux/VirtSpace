//
//  LibraryLogic.swift
//  VirtSpace
//
//  The pure decisions behind the Library and Detail screens (ui-spec 4.5,
//  4.6, 7.4), kept out of the views so they are unit-tested: which list
//  state to show, how a space is titled and read aloud, and what a
//  `:retry` / `:enhance` answer means for the screen.
//

import Foundation

/// What the Library shows (ui-spec 4.5 States). A failed load never reads as
/// an empty library.
enum LibraryListState: Equatable {
    /// First load still running: placeholder cards.
    case loading
    /// The load succeeded with zero spaces.
    case empty
    /// Nothing cached and the last load failed. `cause` is user copy.
    case failed(cause: String)
    /// Cards. The offline banner is decided separately (`showsOfflineBanner`).
    case content

    init(isEmpty: Bool, hasLoaded: Bool, lastError: Error?) {
        if !isEmpty {
            self = .content
        } else if let lastError {
            self = .failed(cause: lastError.userCopy)
        } else {
            self = hasLoaded ? .empty : .loading
        }
    }

    /// "Offline. Showing your last update." after 2 failed loads/polls in a
    /// row, only while cards are on screen. Cleared by the store's next
    /// success.
    static func showsOfflineBanner(_ state: LibraryListState, consecutiveFailures: Int) -> Bool {
        state == .content && consecutiveFailures >= 2
    }
}

/// How a space is named on screen (copy deck: "Nov 5, 3:12 PM").
enum SpaceTitle {
    /// The capture date, else the server title without the uploader's
    /// "Scan " prefix (CaptureUploader names worlds "Scan <date>").
    // ponytail: no year, per the copy deck; add `.year()` for dates outside
    // the current year once libraries span years.
    static func title(for world: World) -> String {
        if let created = world.createdAt {
            return created.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        let prefix = "Scan "
        return world.title.hasPrefix(prefix) ? String(world.title.dropFirst(prefix.count)) : world.title
    }

    /// VoiceOver label for a Library card: "Space from Nov 5 at 3:12 PM, Ready".
    static func accessibilityLabel(for world: World, presentation: StatusPresentation) -> String {
        let when: String
        if let created = world.createdAt {
            let day = created.formatted(.dateTime.month(.abbreviated).day())
            when = "\(day) at \(created.formatted(.dateTime.hour().minute()))"
        } else {
            when = title(for: world)
        }
        let status = [presentation.pill, presentation.note].compactMap { $0 }.joined(separator: ", ")
        return "Space from \(when), \(status)"
    }

    /// First line of the caption: the card subtitle once a space is ready.
    static func captionLine(_ caption: String?) -> String? {
        let line = caption?.split(whereSeparator: \.isNewline).first.map(String.init)
        return line?.isEmpty == false ? line : nil
    }
}

/// Client-truth upload count from the capture session still on this phone
/// (the server only knows the world is `uploading`).
struct UploadProgress: Equatable {
    let uploaded: Int
    let total: Int

    var fraction: Double { Double(uploaded) / Double(max(total, 1)) }
    var line: String { "Uploading photos · \(uploaded) of \(total)" }
}

/// Which progress indicator a space gets (ui-spec 7.3).
enum ProgressKind: Equatable {
    case none
    /// Measured work only: upload count, stitch.
    case measured(Double)
    /// Estimated work (`generating_*`, an upload from another phone).
    case indeterminate

    /// `generating_*` is always indeterminate, whatever `progress` says.
    /// Stitching shows nothing until its first measured value.
    init(world: World, upload: UploadProgress?) {
        switch world.status {
        case .uploading:
            self = upload.map { .measured($0.fraction) } ?? .indeterminate
        case .stitching:
            self = world.status.measuredFraction(serverProgress: world.progress).map { .measured($0) } ?? .none
        case .reconstructing:
            self = world.status.measuredFraction(serverProgress: world.progress).map { .measured($0) } ?? .indeterminate
        case let status where status.isActive:
            self = .indeterminate
        default:
            self = .none
        }
    }
}

/// The Library card's line under the title: the card's one-line form
/// while building or failed, the caption once ready.
enum CardLine {
    static func text(for world: World, presentation p: StatusPresentation, upload: UploadProgress?) -> String? {
        if world.status == .uploading { return upload?.line ?? p.detail }
        if world.status.isActive { return p.stepLine ?? p.detail }
        if p.tone == .danger || p.tone == .neutral { return p.detail }
        return SpaceTitle.captionLine(world.caption)
    }
}

/// What a `:retry` or `:enhance` answer means (ui-spec 7.4 Retry UI, 7.5).
enum SpaceOutcome: Equatable {
    /// 200, with or without a `job_id` (nil = already running): fold the
    /// returned world into the store. The status change is the confirmation.
    case accepted(World)
    /// 409: the space moved on. Refetch; toast only if nothing changed.
    case movedOn
    /// 429 scan quota (draft retry): a note on the card, button disabled.
    case scanQuota(resetAt: Date?)
    /// 404: toast, remove from the store, pop to the Library.
    case gone
    /// Anything else, with its user copy for a toast (offline, rate limit,
    /// credit budget, server faults).
    case failed(message: String)

    init(_ result: Result<WorldJobResponse, Error>) {
        switch result {
        case .success(let response):
            self = .accepted(response.world)
        case .failure(let error):
            switch error as? APIError {
            case .notRetryable: self = .movedOn
            case .scanQuota(let resetAt): self = .scanQuota(resetAt: resetAt)
            case .notFound: self = .gone
            default: self = .failed(message: error.userCopy)
            }
        }
    }
}

extension Error {
    /// The user copy for any error (APIError copy, else the system text).
    var userCopy: String {
        (self as? LocalizedError)?.errorDescription ?? localizedDescription
    }
}
