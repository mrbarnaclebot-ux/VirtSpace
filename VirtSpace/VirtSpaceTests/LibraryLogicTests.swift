//
//  LibraryLogicTests.swift
//  VirtSpaceTests
//
//  ui-spec 4.5 / 7.3 / 7.4 pure decisions: list state (a failed load never
//  reads as empty), titles and VoiceOver labels, which progress a status
//  gets (never a percentage for generation), and retry answer handling.
//

import Foundation
import Testing
@testable import VirtSpace

@Suite("Library logic")
struct LibraryLogicTests {
    private struct Boom: Error {}

    @Test("List state: content beats errors, a failed empty load is an error, not empty")
    func listState() {
        #expect(LibraryListState(isEmpty: false, hasLoaded: true, lastError: Boom()) == .content)
        #expect(LibraryListState(isEmpty: true, hasLoaded: false, lastError: nil) == .loading)
        #expect(LibraryListState(isEmpty: true, hasLoaded: true, lastError: nil) == .empty)
        let offline = LibraryListState(isEmpty: true, hasLoaded: false, lastError: Fixtures.offline)
        #expect(offline == .failed(cause: "You're offline. Check your connection and try again."))
        // A refresh that fails after an empty success is still an error.
        if case .failed = LibraryListState(isEmpty: true, hasLoaded: true, lastError: Boom()) {} else {
            Issue.record("expected .failed")
        }
    }

    @Test("Offline banner only with cards on screen and 2+ failures")
    func offlineBanner() {
        #expect(!LibraryListState.showsOfflineBanner(.content, consecutiveFailures: 1))
        #expect(LibraryListState.showsOfflineBanner(.content, consecutiveFailures: 2))
        #expect(!LibraryListState.showsOfflineBanner(.failed(cause: "x"), consecutiveFailures: 3))
    }

    @Test("Title: the date, else the server title without the Scan prefix")
    func title() {
        var world = Fixtures.world(id: "a", status: "draft_ready")
        world.title = "Scan Nov 5, 2026 at 3:12 PM"
        #expect(SpaceTitle.title(for: world) == "Nov 5, 2026 at 3:12 PM")
        let date = Date(timeIntervalSince1970: 1_762_355_520)
        world.createdAt = date
        #expect(SpaceTitle.title(for: world) == date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
        #expect(!SpaceTitle.title(for: world).contains("Scan"))
    }

    @Test("Card VoiceOver label carries the status words, including the note")
    func accessibilityLabel() {
        let world = Fixtures.world(id: "a", status: "failed_generating_hq")
        let label = SpaceTitle.accessibilityLabel(for: world, presentation: world.status.presentation())
        #expect(label.hasPrefix("Space from "))
        #expect(label.hasSuffix(", Ready, Quality upgrade failed"))
    }

    @Test("Generation never gets a percentage; stitch and upload are measured",
          arguments: ["generating_draft", "generating_hq"])
    func noPercentForGeneration(raw: String) {
        var world = Fixtures.world(id: "a", status: raw)
        world.progress = 37
        #expect(ProgressKind(world: world, upload: nil) == .indeterminate)
    }

    @Test("Stitch bar appears at its first value; uploads use the local count")
    func measuredProgress() {
        var stitch = Fixtures.world(id: "a", status: "stitching")
        #expect(ProgressKind(world: stitch, upload: nil) == .none)
        stitch.progress = 40
        #expect(ProgressKind(world: stitch, upload: nil) == .measured(0.4))
        let uploading = Fixtures.world(id: "b", status: "uploading")
        #expect(ProgressKind(world: uploading, upload: UploadProgress(uploaded: 7, total: 28)) == .measured(0.25))
        #expect(ProgressKind(world: uploading, upload: nil) == .indeterminate)
        #expect(ProgressKind(world: Fixtures.world(id: "c", status: "draft_ready"), upload: nil) == .none)
    }

    @Test("Card line: upload count, step, failure copy, then caption")
    func cardLine() {
        func line(_ raw: String, caption: String? = nil, upload: UploadProgress? = nil) -> String? {
            var world = Fixtures.world(id: "a", status: raw)
            world.caption = caption
            return CardLine.text(for: world, presentation: world.status.presentation(hasLocalUpload: upload != nil), upload: upload)
        }
        #expect(line("uploading", upload: UploadProgress(uploaded: 12, total: 28)) == "Uploading photos · 12 of 28")
        #expect(line("uploading") == "Waiting for the upload from your phone.")
        #expect(line("stitching") == "Step 2 of 3 · Combining photos")
        #expect(line("failed_stitch")?.hasPrefix("Couldn't combine your photos.") == true)
        #expect(line("draft_ready", caption: "A bright room\nwith a sofa") == "A bright room")
        #expect(line("failed_generating_hq", caption: "Kitchen") == "Kitchen")
    }

    @Test("Retry/enhance answers map to outcomes (7.4)")
    func outcomes() throws {
        let world = Fixtures.world(id: "a", status: "stitching")
        for jobId in ["job-1", nil] {
            let response = WorldJobResponse(world: world, jobId: jobId)
            #expect(SpaceOutcome(.success(response)) == .accepted(world))
        }
        #expect(SpaceOutcome(.failure(APIError.notRetryable(status: "stitching"))) == .movedOn)
        #expect(SpaceOutcome(.failure(APIError.scanQuota(resetAt: nil))) == .scanQuota(resetAt: nil))
        #expect(SpaceOutcome(.failure(APIError.notFound)) == .gone)
        #expect(SpaceOutcome(.failure(APIError.rateLimited))
                == .failed(message: "Too many tries. Wait a moment and try again."))
        #expect(SpaceOutcome(.failure(Fixtures.offline))
                == .failed(message: "You're offline. Check your connection and try again."))
    }
}
