//
//  UploadProgressReader.swift
//  VirtSpace
//
//  Reads "12 of 28" from the pending capture-session manifests for worlds
//  the server still reports as `uploading`. Read-only: it never starts,
//  resumes or changes an upload.
//

import SwiftUI

enum UploadProgressReader {
    private static let sessions = PendingSessionStore()

    /// Progress for each id whose capture session is on this phone.
    static func read(_ worldIds: [String]) async -> [String: UploadProgress] {
        var result: [String: UploadProgress] = [:]
        for id in worldIds {
            if let (uploaded, total) = await sessions.pendingSessionProgress(worldId: id) {
                result[id] = UploadProgress(uploaded: uploaded, total: total)
            }
        }
        return result
    }
}

extension View {
    /// Keeps `progress` current for `worldIds` (re-read every second while
    /// any are given; stops when the list empties or the view goes away).
    func readingUploadProgress(for worldIds: [String], into progress: Binding<[String: UploadProgress]>) -> some View {
        task(id: worldIds) {
            guard !worldIds.isEmpty else {
                progress.wrappedValue = [:]
                return
            }
            while !Task.isCancelled {
                progress.wrappedValue = await UploadProgressReader.read(worldIds)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
