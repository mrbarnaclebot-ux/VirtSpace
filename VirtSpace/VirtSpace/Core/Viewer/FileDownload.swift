//
//  FileDownload.swift
//  VirtSpace
//
//  One shared file download for the asset caches (SplatCache, PanoCache).
//
//  Both caches used to stream `for try await byte in URLSession.bytes` —
//  literally one byte per loop iteration, appended to a Data buffer, for files
//  measured in megabytes (spec §10 R12). That burns CPU proportional to file
//  size for no benefit and gives the system no chance to schedule the transfer
//  efficiently. A URLSessionDownloadTask does the transfer out of process, with
//  delegate-driven progress and a finished file on disk.
//
//  The system's downloaded file is deleted the moment `didFinishDownloadingTo`
//  returns, so it is moved to the caller's destination INSIDE that callback.
//  Callers pass a scratch path in the cache directory and do their own atomic
//  move/replace into the final cache file afterwards.
//

import Foundation

enum FileDownloadError: LocalizedError {
    case badStatus(Int)
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "Download failed (HTTP \(code))."
        case .writeFailed: return "Couldn't write the downloaded file to disk."
        }
    }
}

enum FileDownload {
    /// Download `remoteURL` into `destination` (overwritten if present),
    /// reporting 0…1 progress on an arbitrary executor. Progress is only
    /// reported when the server sends a content length; otherwise it stays at
    /// 0 until the download completes, matching the previous behaviour.
    static func download(
        from remoteURL: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let delegate = DownloadDelegate(destination: destination, progress: progress)
        try await delegate.run(remoteURL: remoteURL)
    }
}

/// Per-download delegate. One session per download, invalidated on completion
/// (a URLSession strongly retains its delegate until then).
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
        super.init()
    }

    func run(remoteURL: URL) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        // Bounded like the frame uploads (R12): never wait forever.
        config.timeoutIntervalForResource = 600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session

        let task = session.downloadTask(with: remoteURL)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                continuation = cont
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Resume the continuation exactly once and tear the session down; whoever
    /// wins the swap under the lock owns it, every later caller is a no-op.
    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        cont?.resume(with: result)
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            finish(.failure(FileDownloadError.badStatus(http.statusCode)))
            return
        }
        // Must happen before this callback returns — the system removes
        // `location` immediately afterwards.
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: location)
            } else {
                try fm.moveItem(at: location, to: destination)
            }
        } catch {
            finish(.failure(FileDownloadError.writeFailed))
            return
        }
        finish(.success(()))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success already resumed the continuation in didFinishDownloadingTo;
        // `finish` makes this a no-op in that case.
        if let error {
            finish(.failure(error))
        } else {
            finish(.success(()))
        }
    }
}
