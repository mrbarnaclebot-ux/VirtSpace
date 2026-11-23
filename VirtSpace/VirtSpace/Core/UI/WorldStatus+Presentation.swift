//
//  WorldStatus+Presentation.swift
//  VirtSpace
//
//  How a world's status reads on screen (ui-spec 7.3, 7.4): pill copy,
//  symbol, tone, the 3-step build list, card text, and whether a progress
//  value is real. Views never show `rawString`; they use this.
//
//    let p = world.status.presentation(hasLocalUpload: sessionOnPhone)
//    Label(p.pill, systemImage: p.symbol).foregroundStyle(p.tone.color)
//    if let f = world.status.measuredFraction(serverProgress: world.progress) { ProgressView(value: f) }
//

import Foundation

/// Everything a pill, Library card or Detail status card needs for one status.
struct StatusPresentation: Equatable {
    /// Short pill label: "Building", "Ready", "Needs attention".
    let pill: String
    let symbol: String
    let tone: Tone
    /// Secondary label next to the pill ("High quality", "Quality upgrade
    /// failed") and its tone.
    var note: String?
    var noteTone: Tone = .neutral
    /// 1...3 while the space is being built (see `StatusPresentation.steps`).
    var step: Int?
    /// Detail card body; nil = no card for this status.
    var detail: String?
    /// True only for measured work (upload manifest, stitch). Generation
    /// progress from the server is elapsed-time pseudo-progress
    /// (backend/src/worker.ts), so it is never shown as determinate.
    var isProgressMeasured = false
    /// Non-nil when a `:retry` is offered, with what it costs.
    var retry: RetryCost?
    /// The build steps this space goes through, and how long they take.
    var steps = Self.spotSteps
    var buildEstimate = "Usually 1 to 2 minutes. You can leave this screen."

    /// The build step list, in order (ui-spec 4.6).
    static let spotSteps = ["Uploading photos", "Combining photos", "Building your space"]
    /// A room scan has no combine step (spec §5.3).
    static let roomSteps = ["Uploading photos", "Building your space"]

    /// "Step 2 of 3 · Combining photos", or nil outside the build.
    var stepLine: String? {
        guard let step, steps.indices.contains(step - 1) else { return nil }
        return "Step \(step) of \(steps.count) · \(steps[step - 1])"
    }

    /// True while work is running: shows the in-progress dot.
    var isInProgress: Bool { tone == .progress }
}

/// What a `:retry` costs the user (ui-spec 7.4 "Cost honesty").
enum RetryCost: Equatable {
    /// `failed_stitch`: free.
    case free
    /// `failed_generating_draft`: uses one of today's scans. Caption the
    /// button "Uses 1 of today's scans".
    case usesScan
    /// `failed_generating_hq`: can bill a full quality upgrade again. Confirm
    /// with the Improve quality sheet first.
    case needsConfirmation
}

extension WorldStatus {
    /// `hasLocalUpload`: the capture session for this world is still on this
    /// phone (only changes the `uploading` copy). `roomScan`: a walked room
    /// (spec §5.3), two steps and a long build.
    func presentation(hasLocalUpload: Bool = false, roomScan: Bool = false) -> StatusPresentation {
        var p = basePresentation(hasLocalUpload: hasLocalUpload)
        if roomScan, p.step != nil {
            p.steps = StatusPresentation.roomSteps
            p.buildEstimate = "Usually 30 minutes to 2 hours. You can leave the app."
        }
        return p
    }

    private func basePresentation(hasLocalUpload: Bool) -> StatusPresentation {
        switch self {
        case .capturing:
            return StatusPresentation(pill: "Scanning", symbol: "viewfinder", tone: .progress)
        case .uploading:
            return hasLocalUpload
                ? StatusPresentation(pill: "Uploading", symbol: "arrow.up", tone: .progress, step: 1, isProgressMeasured: true)
                : StatusPresentation(pill: "Uploading", symbol: "arrow.up", tone: .progress, step: 1,
                                     detail: "Waiting for the upload from your phone.")
        case .stitching:
            return StatusPresentation(pill: "Building", symbol: "cube.transparent", tone: .progress, step: 2,
                                      isProgressMeasured: true)
        case .generatingDraft:
            return StatusPresentation(pill: "Building", symbol: "cube.transparent", tone: .progress, step: 3,
                                      detail: "Usually under a minute.")
        case .reconstructing:
            return StatusPresentation(pill: "Building", symbol: "cube.transparent", tone: .progress, step: 2,
                                      detail: "Usually 30 minutes to 2 hours.", isProgressMeasured: true)
        case .draftReady:
            return Self.ready
        case .generatingHq:
            return StatusPresentation(pill: "Improving", symbol: "sparkles", tone: .progress,
                                      detail: "Improving quality… usually 5 to 10 minutes. You can keep exploring.")
        case .complete:
            var ready = Self.ready
            ready.note = "High quality"
            return ready
        case .failed(let raw):
            return Self.failure(raw)
        }
    }

    private static let ready = StatusPresentation(pill: "Ready", symbol: "checkmark.circle.fill", tone: .success)

    /// `failed(_)` also carries any status this build doesn't know.
    private static func failure(_ raw: String) -> StatusPresentation {
        let attention = (pill: "Needs attention", symbol: "exclamationmark.triangle.fill")
        switch raw {
        case "failed_upload":
            return StatusPresentation(pill: "Didn't upload", symbol: attention.symbol, tone: .danger,
                                      detail: "The upload didn't finish. If the scan is still on this phone, you can upload it again from Scan. Otherwise, delete it and scan again.")
        case "failed_stitch":
            return StatusPresentation(pill: attention.pill, symbol: attention.symbol, tone: .danger,
                                      detail: "Couldn't combine your photos. Try again. If it fails again, scan the room again, keeping the phone over one spot.",
                                      retry: .free)
        case "failed_generating_draft":
            return StatusPresentation(pill: attention.pill, symbol: attention.symbol, tone: .danger,
                                      detail: "Couldn't build your space. This is usually temporary. Try again.",
                                      retry: .usesScan)
        case "failed_reconstructing":
            return StatusPresentation(pill: attention.pill, symbol: attention.symbol, tone: .danger,
                                      detail: "Couldn't build your space. This is usually temporary. Try again.",
                                      retry: .usesScan)
        case "failed_generating_hq":
            var ready = Self.ready
            ready.note = "Quality upgrade failed"
            ready.noteTone = .warning
            ready.detail = "Couldn't improve quality. Your space is still here."
            ready.retry = .needsConfirmation
            return ready
        default:
            return StatusPresentation(pill: "Updating", symbol: "arrow.triangle.2.circlepath", tone: .neutral,
                                      detail: "We're updating this space. Pull to refresh.")
        }
    }

    /// The server's `progress` (0-100) as a 0...1 fraction, for stitching and
    /// for a room scan's build (provider progress when it reports one, else
    /// pseudo-progress over the 30 min–2 h quote: a bar beats a spinner for
    /// hours, spec §5.3 item 4). nil for everything else, including the
    /// elapsed-time pseudo-progress of `generating_*`. Upload progress comes
    /// from the local manifest, not from here.
    func measuredFraction(serverProgress: Int?) -> Double? {
        guard self == .stitching || self == .reconstructing, let serverProgress else { return nil }
        return Double(min(max(serverProgress, 0), 100)) / 100
    }

    /// "Taking longer than usual" (ui-spec 7.3 rule 4): the server heartbeat
    /// is older than 90 s while stitching or 120 s while generating. Pass
    /// `pollsFailing` when the client's own polls fail: then the phone is
    /// offline and the server must not be blamed, so this is false.
    func isSlow(heartbeatAt: Date?, now: Date = .now, pollsFailing: Bool) -> Bool {
        guard !pollsFailing, let heartbeatAt else { return false }
        let limit: TimeInterval
        switch self {
        case .stitching: limit = 90
        case .generatingDraft, .generatingHq: limit = 120
        default: return false
        }
        return now.timeIntervalSince(heartbeatAt) > limit
    }
}
