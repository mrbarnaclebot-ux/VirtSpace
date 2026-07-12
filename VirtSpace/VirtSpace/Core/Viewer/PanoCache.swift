//
//  PanoCache.swift
//  VirtSpace
//
//  Download-and-cache manager for stitched equirectangular panoramas (the
//  2D 360° preview, spec §6.4). Mirrors SplatCache: files live under
//  Application Support/panos/{worldId}_v{version}.jpg, keyed by world id +
//  asset_version so a new asset version re-downloads. A missing file is
//  streamed from its presigned R2 URL and atomically moved into place. Total
//  cache is held under a modest budget (panos are small) by LRU eviction.
//

import Foundation
import OSLog

actor PanoCache {
    static let shared = PanoCache()

    /// Eviction trigger: keep the panos directory under 250 MB.
    private let budgetBytes: Int64 = 250_000_000

    private let fm = FileManager.default
    private let log = Logger(subsystem: "dev.virtspace.app", category: "PanoCache")

    // MARK: - Paths

    private var directory: URL {
        get throws {
            let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let dir = base.appendingPathComponent("panos", isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir
        }
    }

    private func fileURL(worldId: String, version: Int) throws -> URL {
        let safe = worldId.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        return try directory.appendingPathComponent("\(safe)_v\(version).jpg")
    }

    // MARK: - API

    /// Return the local pano image file, downloading + caching it if absent.
    /// `progress` is called 0…1 on an arbitrary executor; marshal to the main
    /// actor in the UI.
    func ensure(
        worldId: String,
        version: Int,
        remoteURL: URL,
        progress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws -> URL {
        let dest = try fileURL(worldId: worldId, version: version)
        if fm.fileExists(atPath: dest.path) {
            touch(dest)
            return dest
        }

        let (bytes, response) = try await URLSession.shared.bytes(from: remoteURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PanoCacheError.badStatus(http.statusCode)
        }
        let expected = response.expectedContentLength // -1 if unknown

        let tmp = try directory.appendingPathComponent("\(UUID().uuidString).partial")
        fm.createFile(atPath: tmp.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: tmp) else {
            throw PanoCacheError.writeFailed
        }

        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(256 * 1024)
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 256 * 1024 {
                    try handle.write(contentsOf: buffer)
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if expected > 0 { progress(min(1, Double(received) / Double(expected))) }
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(at: tmp)
            throw error
        }

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

    /// Total bytes currently held in the panos cache directory.
    func totalBytes() -> Int64 {
        guard let dir = try? directory,
              let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Delete every cached pano. Returns the number of bytes freed.
    @discardableResult
    func clear() -> Int64 {
        let before = totalBytes()
        guard let dir = try? directory,
              let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return 0 }
        for url in items { try? fm.removeItem(at: url) }
        log.info("Cleared pano cache (\(before) bytes)")
        return before
    }

    // MARK: - LRU eviction

    private func touch(_ url: URL) {
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func evictIfNeeded(keeping keep: URL) {
        guard let dir = try? directory else { return }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }

        let files = items.filter { $0.pathExtension == "jpg" }
        var total: Int64 = files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        guard total > budgetBytes else { return }

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
                log.info("Evicted cached pano \(url.lastPathComponent, privacy: .public)")
            }
        }
    }
}

enum PanoCacheError: LocalizedError {
    case badStatus(Int)
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "Download failed (HTTP \(code))."
        case .writeFailed: return "Couldn't write the panorama to disk."
        }
    }
}
