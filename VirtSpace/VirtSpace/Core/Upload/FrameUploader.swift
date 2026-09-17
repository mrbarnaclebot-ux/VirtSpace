//
//  FrameUploader.swift
//  VirtSpace
//
//  PUTs frame data directly to presigned R2 URLs (spec §7.1: frames never
//  proxy through the API) over a BACKGROUND URLSession so uploads keep running
//  when the app leaves the foreground — plain URLSession suspends with the
//  process (a real-device 28-frame upload died at frame 4 on screen lock).
//
//  Frames upload FROM FILE (the bytes already live in the CaptureStore session
//  dir), which background sessions require. Completion is delegate-based and
//  bridged to async/await via `BackgroundUploadCoordinator`. Per-frame retry
//  (2 attempts) is preserved.
//

import Foundation
import OSLog

/// Owns the single app-lifetime background `URLSession` and bridges its
/// delegate callbacks to async/await. Must be a singleton: a background session
/// is keyed by its identifier and a second instance with the same id traps.
final class BackgroundUploadCoordinator: NSObject, URLSessionDataDelegate {
    static let shared = BackgroundUploadCoordinator()

    /// Stable across launches so the OS can hand back tasks that finished while
    /// the app was suspended/terminated.
    static let sessionIdentifier = "com.virtspace.frame-upload"

    /// Stored by the App/scene `handleEventsForBackgroundURLSession` hook and
    /// invoked from `urlSessionDidFinishEvents` once all background events have
    /// been delivered, so UIKit can snapshot and re-suspend the app.
    private var backgroundEventsCompletion: (() -> Void)?

    /// Hard ceiling on a single frame PUT, connectivity waiting included.
    /// `waitsForConnectivity` with no resource timeout means a task can sit
    /// forever, and its continuation with it — one stuck frame wedged the whole
    /// upload flow (spec §10 R12). 10 minutes is far beyond a legitimate
    /// multi-megabyte JPEG PUT on any usable connection, so hitting it means
    /// the transfer is dead: fail, let the session stay on disk, and retry.
    static let resourceTimeout: TimeInterval = 600

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // Relaunch the app in the background to finish/deliver events even after
        // it's been suspended or terminated.
        config.sessionSendsLaunchEvents = true
        // Uploads are user-initiated; don't let the system defer them.
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        // Bounded wait: without this the pair above can block indefinitely.
        config.timeoutIntervalForResource = Self.resourceTimeout
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<HTTPURLResponse, Error>] = [:]

    private override init() { super.init() }

    /// Instantiate the background session (idempotent). Called at launch so the
    /// session reconnects to any tasks that completed out-of-process.
    func activate() { _ = session }

    /// Record the UIKit completion handler for a background-events relaunch.
    func setBackgroundEventsCompletion(_ handler: @escaping () -> Void) {
        lock.lock()
        backgroundEventsCompletion = handler
        lock.unlock()
        activate()
    }

    /// Start a background upload task from a file and await its completion.
    func upload(fileURL: URL, request: URLRequest) async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HTTPURLResponse, Error>) in
            let task = session.uploadTask(with: request, fromFile: fileURL)
            lock.lock()
            continuations[task.taskIdentifier] = cont
            lock.unlock()
            task.taskDescription = request.url?.lastPathComponent
            task.resume()
        }
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Every completion path — success, failure, resource timeout, explicit
        // cancel — funnels through `finish`, which removes the continuation
        // under the lock. A continuation is therefore resumed exactly once:
        // whoever wins removeValue owns it, everyone else sees nil.
        if let error {
            finish(task.taskIdentifier, with: .failure(APIError.network(error)))
            return
        }
        guard let http = task.response as? HTTPURLResponse else {
            finish(task.taskIdentifier, with: .failure(APIError.invalidResponse))
            return
        }
        finish(task.taskIdentifier, with: .success(http))
    }

    /// The session became unusable (invalidated / unrecoverable error). Fail
    /// every outstanding continuation rather than leaving awaiting flows hung
    /// forever — the whole point of R12.
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock()
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        let failure = error.map { APIError.network($0) } ?? APIError.invalidResponse
        for (_, cont) in pending { cont.resume(throwing: failure) }
    }

    /// Resume the continuation for `taskIdentifier` exactly once, or do nothing
    /// if it was already resumed / belongs to a prior process (the app was
    /// terminated mid-upload and relaunched — those bytes already reached R2
    /// and the resume flow re-PUTs anything not marked uploaded).
    private func finish(_ taskIdentifier: Int, with result: Result<HTTPURLResponse, Error>) {
        lock.lock()
        let cont = continuations.removeValue(forKey: taskIdentifier)
        lock.unlock()
        guard let cont else { return }
        cont.resume(with: result)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let completion = backgroundEventsCompletion
        backgroundEventsCompletion = nil
        lock.unlock()
        if let completion {
            DispatchQueue.main.async { completion() }
        }
    }
}

/// The one thing `CaptureUploader` needs from the frame-upload layer. A
/// protocol so the uploader's state machine can be unit-tested with a fake
/// that never touches the network (spec §10 R13).
protocol FrameUploading {
    func upload(fileURL: URL, to slot: FrameUpload) async throws
}

struct FrameUploader: FrameUploading {
    var maxAttempts: Int = 2
    var coordinator: BackgroundUploadCoordinator = .shared

    /// Upload a frame that already lives on disk (the CaptureStore session file)
    /// straight from that file — the background session's required mode.
    func upload(fileURL: URL, to slot: FrameUpload) async throws {
        try await put(fileURL: fileURL, to: slot, ownsFile: false)
    }

    /// Upload in-memory bytes: staged to a temp file first (background uploads
    /// must be file-backed), removed once the task completes. Used by the DEBUG
    /// test-scan harness which synthesizes a frame in memory.
    func upload(_ data: Data, to slot: FrameUpload) async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-upload-\(UUID().uuidString).bin")
        try data.write(to: tmp, options: .atomic)
        try await put(fileURL: tmp, to: slot, ownsFile: true)
    }

    private func put(fileURL: URL, to slot: FrameUpload, ownsFile: Bool) async throws {
        guard let url = URL(string: slot.url) else {
            throw APIError.invalidResponse
        }
        // Safe to remove only after every attempt has completed (we await each).
        defer { if ownsFile { try? FileManager.default.removeItem(at: fileURL) } }

        var request = URLRequest(url: url)
        request.httpMethod = slot.httpMethod
        // Attach exactly the headers the API returned (e.g. Content-Type,
        // x-goog-content-length-range for GCS-style signed URLs).
        for (key, value) in slot.headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }

        var lastError: Error = APIError.invalidResponse
        for attempt in 1...max(1, maxAttempts) {
            do {
                let http = try await coordinator.upload(fileURL: fileURL, request: request)
                guard (200..<300).contains(http.statusCode) else {
                    throw APIError.server(http.statusCode, "Frame \(slot.index) upload failed")
                }
                return
            } catch {
                lastError = (error as? APIError) ?? APIError.network(error)
                if attempt < maxAttempts {
                    // Brief backoff before the retry.
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
        }
        throw lastError
    }
}
