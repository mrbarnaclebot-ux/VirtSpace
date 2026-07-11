//
//  FrameUploader.swift
//  VirtSpace
//
//  PUTs frame data directly to presigned R2 URLs (spec §7.1: frames never
//  proxy through the API). Uses exactly the method + headers the API returned
//  for each upload slot, with per-frame retry (2 attempts).
//

import Foundation

struct FrameUploader {
    var session: URLSession = .shared
    var maxAttempts: Int = 2

    /// Upload a single frame's bytes to its presigned slot.
    func upload(_ data: Data, to slot: FrameUpload) async throws {
        guard let url = URL(string: slot.url) else {
            throw APIError.invalidResponse
        }
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
                let (_, response) = try await session.upload(for: request, from: data)
                guard let http = response as? HTTPURLResponse else {
                    throw APIError.invalidResponse
                }
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

    /// Upload multiple frames sequentially (index-ordered). `frames[i]` maps to
    /// the slot with matching `index` when present, else positionally.
    func uploadAll(_ frames: [Data], to slots: [FrameUpload]) async throws {
        let ordered = slots.sorted { $0.index < $1.index }
        for (position, slot) in ordered.enumerated() {
            let frameIndex = frames.indices.contains(slot.index) ? slot.index : position
            guard frames.indices.contains(frameIndex) else {
                throw APIError.server(0, "No frame data for upload slot \(slot.index)")
            }
            try await upload(frames[frameIndex], to: slot)
        }
    }
}
