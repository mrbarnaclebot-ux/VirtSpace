//
//  SpaceActions.swift
//  VirtSpace
//
//  The server-confirmed actions on one space, shared by the Library context
//  menu and Detail: Try again (`:retry`), Improve quality (`:enhance`) and
//  Delete. Nothing is optimistic: the store changes only after the server
//  answers (ui-spec 4.6, 7.4, 7.5).
//
//    let actions = SpaceActions(api: api, store: store, toasts: toasts, router: router)
//    let outcome = await actions.run(.retry, on: world)
//    let deleted = await actions.delete(id: world.id)
//

import SwiftUI

struct SpaceActions {
    enum Kind { case retry, enhance }

    let api: APIClient
    let store: WorldStore
    let toasts: ToastCenter
    let router: AppRouter

    /// POST the action, then apply the answer to the store, toasts and
    /// navigation. `.scanQuota` is left to the caller (Detail shows it on the
    /// card, the Library toasts it).
    @discardableResult
    func run(_ kind: Kind, on world: World) async -> SpaceOutcome {
        let result: Result<WorldJobResponse, Error>
        do {
            switch kind {
            case .retry: result = .success(try await api.retry(worldId: world.id))
            case .enhance: result = .success(try await api.enhance(worldId: world.id))
            }
        } catch {
            result = .failure(error)
        }
        let outcome = SpaceOutcome(result)
        await apply(outcome, kind: kind, worldId: world.id, previous: world.status)
        return outcome
    }

    /// DELETE, then (only after a 2xx) drop the space everywhere, pop to the
    /// Library and confirm. A 404 means it is already gone: same cleanup.
    /// Returns false when the space is still there.
    @discardableResult
    func delete(id: String) async -> Bool {
        do {
            try await api.deleteWorld(id: id)
            dropEverywhere(id)
            toasts.show("Space deleted.", style: .success)
            return true
        } catch let error as APIError where error.isWorldGone {
            dropEverywhere(id)
            toasts.show(error)
            return true
        } catch {
            toasts.show(error)
            return false
        }
    }

    private func apply(_ outcome: SpaceOutcome, kind: Kind, worldId: String, previous: WorldStatus) async {
        switch outcome {
        case .accepted(let world):
            store.replace(from: world)
        case .movedOn:
            let fresh = try? await store.fetch(id: worldId)
            if fresh?.world.status == previous {
                toasts.show(kind == .retry
                            ? "This space can't be retried right now."
                            : APIError.notRetryable(status: nil).userCopy,
                            style: .error)
            }
        case .gone:
            dropEverywhere(worldId)
            toasts.show(APIError.notFound)
        case .failed(let message):
            toasts.show(message, style: .error)
        case .scanQuota:
            break
        }
    }

    private func dropEverywhere(_ id: String) {
        store.remove(id: id)
        router.libraryPath.removeAll { $0 == id }
    }
}

extension View {
    /// The delete confirmation (copy deck: Detail delete dialog). Shown while
    /// `world` is non-nil; the DELETE runs only on "Delete".
    func deleteSpaceDialog(for world: Binding<World?>, actions: SpaceActions) -> some View {
        confirmationDialog(
            "Delete this space?",
            isPresented: Binding(get: { world.wrappedValue != nil }, set: { if !$0 { world.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: world.wrappedValue
        ) { target in
            Button("Delete", role: .destructive) {
                Task { await actions.delete(id: target.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It will be removed from your library and our servers. This can't be undone.")
        }
    }
}
