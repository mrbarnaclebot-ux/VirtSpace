//
//  SessionClaims.swift
//  VirtSpace
//
//  Per-capture-session mutual exclusion for upload flows (spec §10 R12).
//
//  Upload flows used to be serialized by ONE global chain in UploadManager, so
//  a single wedged session (a frame PUT that never completed) blocked every
//  other flow behind it — including the user's "Retry upload" button, which
//  simply queued forever behind the stuck task.
//
//  Serialization actually only needs to be per session: two flows must never
//  work the same session concurrently (they'd double-upload frames or mint two
//  worlds), but flows touching *different* sessions are independent. A flow
//  claims the session it is about to work; a flow that can't claim one skips
//  it and moves on, so a stuck session can never block the rest.
//

import Foundation

actor SessionClaims {
    static let shared = SessionClaims()

    private var claimed: Set<UUID> = []

    /// Take exclusive ownership of `id`. Returns false when another in-flight
    /// flow already owns it — the caller must then skip that session.
    func claim(_ id: UUID) -> Bool {
        claimed.insert(id).inserted
    }

    /// Give the session back. Idempotent.
    func release(_ id: UUID) {
        claimed.remove(id)
    }

    /// True while some flow owns `id` (diagnostics / UI messaging).
    func isClaimed(_ id: UUID) -> Bool {
        claimed.contains(id)
    }
}
