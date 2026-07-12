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
//  Flows are serialized so a kick and a resume can't double-upload a session.
//

import Foundation
import OSLog

@MainActor
final class UploadManager {
    static let shared = UploadManager()

    /// Tail of the serialized flow chain — each new flow awaits the previous
    /// one so two flows never touch the same session concurrently.
    private var chain: Task<Void, Never>?

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

    // MARK: - Serialization

    /// Run `op` in an unstructured, manager-owned task ordered after every
    /// previously enqueued flow. The returned handle is for observation only.
    private func enqueue<T>(_ op: @escaping () async -> T) -> Task<T, Never> {
        let previous = chain
        let task = Task {
            await previous?.value
            return await op()
        }
        chain = Task { _ = await task.value }
        return task
    }
}
