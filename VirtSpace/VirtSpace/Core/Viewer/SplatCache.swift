//
//  SplatCache.swift
//  VirtSpace
//
//  Download-and-cache manager for world SPZ splats (spec §8: "aggressive
//  on-device caching keyed by world-id+version"). Files live under
//  Application Support/splats/{worldId}_v{version}.spz. A missing file is
//  streamed from its presigned R2 URL with progress, written to a temp file,
//  then atomically moved into place. Total cache is held under a 1 GB budget by
//  evicting least-recently-used files.
//

import Foundation
import OSLog

actor SplatCache {
    static let shared = SplatCache()

    /// Eviction trigger: keep the splats directory under 1 GB.
    private let budgetBytes: Int64 = 1_000_000_000

    private let fm = FileManager.default
    private let log = Logger(subsystem: "dev.virtspace.app", category: "SplatCache")

    // MARK: - Paths

    private var directory: URL {
        get throws {
            let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let dir = base.appendingPathComponent("splats", isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir
        }
    }

    private func fileURL(worldId: String, version: Int) throws -> URL {
        // Sanitize the id so it can't escape the directory.
        let safe = worldId.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        return try directory.appendingPathComponent("\(safe)_v\(version).spz")
    }

    // MARK: - API

    /// The cached file, if present. Touches it so LRU sees a fresh access.
    func cached(worldId: String, version: Int) -> URL? {
        guard let url = try? fileURL(worldId: worldId, version: version),
              fm.fileExists(atPath: url.path) else { return nil }
        touch(url)
        return url
    }

    /// Return the local SPZ, downloading + caching it if absent. `progress` is
    /// called with 0…1 on an arbitrary executor — marshal to the main actor in
    /// the UI. When the server sends no Content-Length, progress stays at 0
    /// until completion (then no explicit final call — callers treat return as
    /// done).
    func ensure(
        worldId: String,
        version: Int,
        remoteURL: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        let dest = try fileURL(worldId: worldId, version: version)
        if fm.fileExists(atPath: dest.path) {
            touch(dest)
            return dest
        }

        // Download to a scratch file in the same directory (same volume → the
        // move below is a rename). A download task transfers out of process
        // with delegate progress; this used to be a byte-at-a-time async
        // sequence over a multi-megabyte SPZ (spec §10 R12).
        let tmp = try directory.appendingPathComponent("\(UUID().uuidString).partial")
        do {
            try await FileDownload.download(from: remoteURL, to: tmp, progress: progress)
        } catch let error as FileDownloadError {
            try? fm.removeItem(at: tmp)
            switch error {
            case .badStatus(let code): throw SplatCacheError.badStatus(code)
            case .writeFailed: throw SplatCacheError.writeFailed
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }

        // Atomic move into place (replace if a racing writer beat us).
        do {
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: dest)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }

        progress(1)
        evictIfNeeded(keeping: dest)
        return dest
    }

    // MARK: - Maintenance (Settings)

    /// Total bytes currently held in the splats cache directory.
    func totalBytes() -> Int64 {
        guard let dir = try? directory,
              let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Delete every cached splat. Returns the number of bytes freed.
    @discardableResult
    func clear() -> Int64 {
        let before = totalBytes()
        guard let dir = try? directory,
              let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return 0 }
        for url in items { try? fm.removeItem(at: url) }
        log.info("Cleared splat cache (\(before) bytes)")
        return before
    }

    // MARK: - LRU eviction

    private func touch(_ url: URL) {
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Delete least-recently-used splats until the directory is under budget.
    /// `keep` is never evicted (it's the file we just produced).
    private func evictIfNeeded(keeping keep: URL) {
        guard let dir = try? directory else { return }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }

        let files = items.filter { $0.pathExtension == "spz" }
        var total: Int64 = files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        guard total > budgetBytes else { return }

        // Oldest access (modification date) first.
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        for url in sorted {
            if total <= budgetBytes { break }
            if url.standardizedFileURL == keep.standardizedFileURL { continue }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if (try? fm.removeItem(at: url)) != nil {
                total -= size
                log.info("Evicted cached splat \(url.lastPathComponent, privacy: .public)")
            }
        }
    }
}

enum SplatCacheError: LocalizedError {
    case badStatus(Int)
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "Download failed (HTTP \(code))."
        case .writeFailed: return "Couldn't write the world to disk."
        }
    }
}
