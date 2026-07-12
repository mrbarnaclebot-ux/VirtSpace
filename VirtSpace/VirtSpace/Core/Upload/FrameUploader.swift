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

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // Relaunch the app in the background to finish/deliver events even after
        // it's been suspended or terminated.
        config.sessionSendsLaunchEvents = true
        // Uploads are user-initiated; don't let the system defer them.
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
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
        lock.lock()
        let cont = continuations.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        // No continuation → this task finished in a PRIOR process (the app was
        // terminated mid-upload and relaunched). The bytes already reached R2;
        // the resume flow re-PUTs anything not marked uploaded, so we just drop it.
        guard let cont else { return }

        if let error {
            cont.resume(throwing: APIError.network(error))
            return
        }
        guard let http = task.response as? HTTPURLResponse else {
            cont.resume(throwing: APIError.invalidResponse)
            return
        }
        cont.resume(returning: http)
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

struct FrameUploader {
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
