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

import Foundation
import OSLog

@MainActor
final class UploadManager {
    static let shared = UploadManager()

    private init() {}

    // MARK: - Kicks (safe to call from any view; never cancelled by views)

    /// Upload a finished capture session. Returns the app-scoped task handle;
    /// awaiting its value is UI-only and does not tie the flow to the caller.
    @discardableResult
    func kickUpload(
        result: CaptureResult,
        api: APIClient,
        progress: @escaping (Int) -> Void = { _ in }
    ) -> Task<Result<World, Error>, Never> {
        enqueue {
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

    /// Retry every session left on disk (stranded-completion first, then full
    /// resume). Returns the worlds whose pipelines were (re)started.
    @discardableResult
    func kickResume(
        api: APIClient,
        progress: @escaping (Int) -> Void = { _ in }
    ) -> Task<[World], Never> {
        enqueue {
            AppLog.upload.log("UploadManager: resume flow started")
            let uploader = CaptureUploader(api: api)
            // Cheap idempotent recovery for the exact stranded state first.
            _ = await uploader.completeStrandedSessions()
            let worlds = await uploader.resumePending(progress: progress)
            AppLog.upload.log("UploadManager: resume flow finished (\(worlds.count) uploaded)")
            return worlds
        }
    }

    /// Completion kick (launch + every scenePhase → .active): any pending
    /// session with createdWorldId set AND all frames flagged uploaded goes
    /// straight to frames:done — recovery for flows that died between the last
    /// frame PUT and frames:done.
    @discardableResult
    func kickStrandedRecovery(api: APIClient) -> Task<Int, Never> {
        enqueue {
            await CaptureUploader(api: api).completeStrandedSessions()
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
    private func enqueue<T>(_ op: @escaping () async -> T) -> Task<T, Never> {
        Task { await op() }
    }
}
