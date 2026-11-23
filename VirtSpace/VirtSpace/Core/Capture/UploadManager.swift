//
//  UploadManager.swift
//  VirtSpace
//
//  App-scoped owner of upload/resume flows. Root cause (confirmed on device):
//  upload/resume ran inside view-lifecycle tasks, so navigating tabs cancelled
//  the flow — the background-session frame PUTs kept completing (their
//  continuations aren't cancellation-aware, frames kept getting flagged), but
//  the flow died at the first cancellation-aware call: frames:done threw
//  CancellationError before any request was sent, stranding the world in
//  `uploading` with 28/28 frames on R2.
//
//  Every flow here runs in an unstructured Task owned by this singleton —
//  detached from any view. Views merely kick a flow and (optionally) await the
//  returned handle for UI; cancelling THAT await never cancels the flow.
//
//  Mutual exclusion is PER SESSION (`SessionClaims`), not global. Flows used to
//  queue behind one global chain, so a single wedged frame PUT blocked every
//  later flow — including the user's "Retry upload" button, which just sat in
//  the queue behind the stuck upload (spec §10 R12). Now a flow claims each
//  session it touches and skips any session another flow already owns: two
//  flows still never double-upload the same session, but a stuck session can
//  no longer block a different one, or a retry.
//
//  Consent (spec-doc R32, ui-spec 5): every kick that sends data refuses to
//  start without current terms consent. The onboarding cover already blocks
//  the Scan tab; this guard is the backstop for launch and resume kicks.
//

import Foundation
import OSLog

@MainActor
final class UploadManager {
    static let shared = UploadManager()

    private let hasConsent: @MainActor () -> Bool

    /// The app uses `shared`; tests build their own with a fake consent check.
    init(hasConsent: @escaping @MainActor () -> Bool = { OnboardingStore.hasCurrentConsent() }) {
        self.hasConsent = hasConsent
    }

    /// Copy for an upload refused by the consent guard.
    static let consentMissingMessage = "Agree to the terms of use to upload your scan."

    /// True (and logged) when `flow` must not run: no current consent.
    private func consentMissing(_ flow: String) -> Bool {
        guard !hasConsent() else { return false }
        AppLog.upload.notice("UploadManager: \(flow, privacy: .public) refused, terms not accepted")
        return true
    }

    // MARK: - Kicks (safe to call from any view; never cancelled by views)

    /// Upload a finished capture session. Returns the app-scoped task handle;
    /// awaiting its value is UI-only and does not tie the flow to the caller.
    @discardableResult
    func kickUpload(
        result: CaptureResult,
        api: APIClient,
        progress: @escaping (Int) -> Void = { _ in }
    ) -> Task<Result<World, Error>, Never> {
        if consentMissing("upload") {
            return Task { .failure(APIError.localState(Self.consentMissingMessage)) }
        }
        return enqueue {
            AppLog.upload.log("UploadManager: upload flow started for session \(result.sessionID.uuidString, privacy: .public)")
            do {
                let world = try await CaptureUploader(api: api).upload(result: result, progress: progress)
                AppLog.upload.log("UploadManager: upload flow finished for world \(world.id, privacy: .public)")
                return .success(world)
            } catch is CancellationError {
                // Must never happen now that flows are app-scoped — log LOUDLY.
                AppLog.upload.fault("UploadManager: upload flow CANCELLED mid-run — app-scoped task was cancelled, investigate!")
                return .failure(CancellationError())
            } catch {
                AppLog.upload.error("UploadManager: upload flow failed: \(error.localizedDescription, privacy: .public)")
                return .failure(error)
            }
        }
    }

    /// Upload a room scan the engine just finished (spec §5.3). `stage`
    /// drives the overlay. `.success(nil)`: the server already had it.
    @discardableResult
    func kickRoomScanUpload(
        sessionID: UUID,
        api: APIClient,
        stage: @escaping (RoomScanUploader.Stage) -> Void
    ) -> Task<Result<World?, Error>, Never> {
        if consentMissing("room scan upload") {
            return Task { .failure(APIError.localState(Self.consentMissingMessage)) }
        }
        return enqueue {
            do {
                return .success(try await RoomScanUploader(api: api).uploadFinished(sessionID: sessionID, stage: stage))
            } catch {
                AppLog.upload.error("UploadManager: room scan upload failed: \(error.localizedDescription, privacy: .public)")
                return .failure(error)
            }
        }
    }

    /// Retry the sessions left on disk (stranded-completion first, then full
    /// resume). `userInitiated` marks the user's explicit Retry: it clears the
    /// attempt counter, ignores backoff and un-parks the session.
    @discardableResult
    func kickResume(
        api: APIClient,
        userInitiated: Bool = false,
        progress: @escaping (Int) -> Void = { _ in }
    ) -> Task<ResumeOutcome, Never> {
        if consentMissing("resume") {
            return Task { .deferred(reason: "the terms of use are not accepted yet") }
        }
        return enqueue {
            AppLog.upload.log("UploadManager: resume flow started (userInitiated: \(userInitiated))")
            let uploader = CaptureUploader(api: api)
            // Cheap idempotent recovery for the exact stranded state first.
            let stranded = await uploader.completeStrandedSessions(userInitiated: userInitiated)
            var outcome = await uploader.resumePending(userInitiated: userInitiated, progress: progress)
            AppLog.upload.log("UploadManager: resume flow finished (\(stranded) stranded completed, outcome: \(String(describing: outcome), privacy: .public))")
            // A stranded session finished by frames:done IS a success even when
            // the sweep itself had nothing left to upload.
            if stranded > 0, case .nothingToResume = outcome { outcome = .succeeded([]) }
            let rooms = await RoomScanUploader(api: api).resumePending(userInitiated: userInitiated)
            return outcome.merged(with: rooms)
        }
    }

    /// Throw away the pending capture sessions at the user's request (the
    /// "Discard" half of the parked-upload choice).
    @discardableResult
    func kickDiscardPending(api: APIClient) -> Task<Int, Never> {
        enqueue {
            let rooms = await RoomScanUploader(api: api).discardPending()
            return await CaptureUploader(api: api).discardPending() + rooms
        }
    }

    /// What's waiting on disk, for the capture screen's affordances.
    func pendingSummary(api: APIClient) async -> PendingUploadSummary {
        let spot = await CaptureUploader(api: api).pendingSummary()
        let rooms = await RoomScanUploader(api: api).pendingSummary()
        return PendingUploadSummary(pendingCount: spot.pendingCount + rooms.pendingCount,
                                    parkedCount: spot.parkedCount + rooms.parkedCount)
    }

    /// Completion kick (launch + every scenePhase → .active): any pending
    /// session with createdWorldId set AND all frames flagged uploaded goes
    /// straight to frames:done — recovery for flows that died between the last
    /// frame PUT and frames:done.
    @discardableResult
    func kickStrandedRecovery(api: APIClient) -> Task<Int, Never> {
        if consentMissing("stranded recovery") { return Task { 0 } }
        return enqueue {
            // Room scans: the automatic sweep (backoff and parking apply)
            // finishes a stranded bundle or resumes its PUT.
            _ = await RoomScanUploader(api: api).resumePending(userInitiated: false)
            return await CaptureUploader(api: api).completeStrandedSessions()
        }
    }

    // MARK: - Flow ownership

    /// Run `op` in an unstructured, manager-owned task. The returned handle is
    /// for observation only — cancelling an await on it never cancels the flow.
    ///
    /// Flows are deliberately NOT chained behind one another: correctness comes
    /// from the per-session claims taken inside `CaptureUploader`, and a global
    /// chain would just recreate the R12 wedge (one stuck session blocking the
    /// retry button).
    /// `op` is explicitly @MainActor because that is what it already was:
    /// these closures are written inside this @MainActor type, and an
    /// unstructured `Task` formed here inherits that isolation. The flows below
    /// therefore run their bookkeeping ON the main actor and suspend at each
    /// `await`: network transfers run inside URLSession, and every manifest
    /// read/write hops to the uploader's `PendingSessionStore` actor (R15), so
    /// none of that I/O touches the main thread. Spelling it out stops the next
    /// reader assuming otherwise — and stops anyone silently moving it.
    private func enqueue<T>(_ op: @escaping @MainActor () async -> T) -> Task<T, Never> {
        Task { await op() }
    }
}

extension ResumeOutcome {
    /// Two sweeps (spot and room scans) as one answer: any success wins,
    /// then any failure, then any deferral.
    func merged(with other: ResumeOutcome) -> ResumeOutcome {
        switch (self, other) {
        case let (.succeeded(a), .succeeded(b)): .succeeded(a + b)
        case (.succeeded, _), (.failed, .deferred), (.failed, .nothingToResume),
             (.deferred, .nothingToResume), (_, .nothingToResume):
            self
        default:
            other
        }
    }
}
