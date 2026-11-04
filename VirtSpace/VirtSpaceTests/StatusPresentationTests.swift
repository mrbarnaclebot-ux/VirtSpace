//
//  StatusPresentationTests.swift
//  VirtSpaceTests
//
//  ui-spec 7.3 / 7.4: every status reads as plain copy (never a raw status
//  string), generation progress is never determinate, and a failed quality
//  upgrade still reads as a usable space.
//

import Foundation
import Testing
@testable import VirtSpace

@Suite("Status presentation")
struct StatusPresentationTests {
    nonisolated static let raws = [
        "capturing", "uploading", "stitching", "generating_draft", "draft_ready",
        "generating_hq", "complete", "failed_upload", "failed_stitch",
        "failed_generating_draft", "failed_generating_hq", "some_future_status",
    ]

    @Test("Every status has pill copy and never shows its raw string", arguments: raws)
    func pillCopy(raw: String) {
        let status = WorldStatus(rawString: raw)
        for local in [false, true] {
            let p = status.presentation(hasLocalUpload: local)
            #expect(!p.pill.isEmpty)
            #expect(!p.symbol.isEmpty)
            for text in [p.pill, p.note, p.detail, p.stepLine].compactMap({ $0 }) {
                #expect(!text.contains(raw), "\(raw) leaks into \"\(text)\"")
                #expect(!text.contains("_"))
            }
        }
    }

    @Test("Generation progress is never measured")
    func generationIsIndeterminate() {
        for status in [WorldStatus.generatingDraft, .generatingHq] {
            #expect(!status.presentation().isProgressMeasured)
            #expect(status.measuredFraction(serverProgress: 37) == nil)
        }
        #expect(WorldStatus.stitching.presentation().isProgressMeasured)
        #expect(WorldStatus.stitching.measuredFraction(serverProgress: 37) == 0.37)
        #expect(WorldStatus.stitching.measuredFraction(serverProgress: 140) == 1)
        #expect(WorldStatus.stitching.measuredFraction(serverProgress: nil) == nil)
        // Upload is measured only from the local manifest.
        #expect(WorldStatus.uploading.presentation(hasLocalUpload: true).isProgressMeasured)
        #expect(!WorldStatus.uploading.presentation(hasLocalUpload: false).isProgressMeasured)
    }

    @Test("Build steps advance 1, 2, 3")
    func steps() {
        #expect(WorldStatus.uploading.presentation().stepLine == "Step 1 of 3 · Uploading photos")
        #expect(WorldStatus.stitching.presentation().step == 2)
        #expect(WorldStatus.generatingDraft.presentation().stepLine == "Step 3 of 3 · Building your space")
        #expect(WorldStatus.draftReady.presentation().step == nil)
    }

    @Test("Failure severity and retry cost per 7.4")
    func failures() {
        let hq = WorldStatus(rawString: "failed_generating_hq").presentation()
        #expect(hq.pill == "Ready")
        #expect(hq.tone == .success)
        #expect(hq.note == "Quality upgrade failed")
        #expect(hq.noteTone == .warning)
        #expect(hq.retry == .needsConfirmation)

        let draft = WorldStatus(rawString: "failed_generating_draft").presentation()
        #expect(draft.pill == "Needs attention")
        #expect(draft.tone == .danger)
        #expect(draft.retry == .usesScan)

        #expect(WorldStatus(rawString: "failed_stitch").presentation().retry == .free)
        #expect(WorldStatus(rawString: "failed_upload").presentation().retry == nil)
        #expect(WorldStatus(rawString: "some_future_status").presentation().pill == "Updating")
        #expect(WorldStatus.complete.presentation().note == "High quality")
    }

    @Test("Slowness: 90 s stitching, 120 s generating, never while offline")
    func slowness() {
        let now = Date()
        let ago: (TimeInterval) -> Date = { now.addingTimeInterval(-$0) }
        #expect(WorldStatus.stitching.isSlow(heartbeatAt: ago(91), now: now, pollsFailing: false))
        #expect(!WorldStatus.stitching.isSlow(heartbeatAt: ago(89), now: now, pollsFailing: false))
        #expect(!WorldStatus.generatingDraft.isSlow(heartbeatAt: ago(110), now: now, pollsFailing: false))
        #expect(WorldStatus.generatingHq.isSlow(heartbeatAt: ago(121), now: now, pollsFailing: false))
        #expect(!WorldStatus.generatingHq.isSlow(heartbeatAt: ago(999), now: now, pollsFailing: true))
        #expect(!WorldStatus.uploading.isSlow(heartbeatAt: ago(999), now: now, pollsFailing: false))
        #expect(!WorldStatus.stitching.isSlow(heartbeatAt: nil, now: now, pollsFailing: false))
    }
}
