import Foundation
import TalariaKit

private enum RoomComposerDraftClearError: LocalizedError {
    case storage

    var errorDescription: String? {
        "Message sent, but its saved draft could not be cleared. The text was preserved."
    }
}

@MainActor
extension RoomRuntime {
    @discardableResult
    func bumpComposerDraftGeneration(_ roomID: RoomID) -> UInt64 {
        let next = (composerDraftGenerations[roomID] ?? 0) &+ 1
        composerDraftGenerations[roomID] = next
        return next
    }

    func retireComposerDraft(_ roomID: RoomID) {
        _ = bumpComposerDraftGeneration(roomID)
        composerDraftTasks[roomID]?.cancel()
        composerDraftTasks[roomID] = nil
        composerDraftGenerations[roomID] = nil
        composerDrafts[roomID] = nil
        composerDraftErrors[roomID] = nil
    }

    func retainComposerDrafts(for roomIDs: Set<RoomID>) {
        let known = Set(composerDrafts.keys)
            .union(composerDraftErrors.keys)
            .union(composerDraftTasks.keys)
            .union(composerDraftGenerations.keys)
        for roomID in known where !roomIDs.contains(roomID) {
            retireComposerDraft(roomID)
        }
    }
}

@MainActor
extension AppModel {
    func roomComposerDraft(_ roomID: RoomID) -> String {
        RoomRuntime.shared.composerDrafts[roomID] ?? ""
    }

    func roomComposerDraftError(_ roomID: RoomID) -> String? {
        RoomRuntime.shared.composerDraftErrors[roomID]
    }

    /// Load is generation-fenced so a slow disk read can never replace text
    /// typed after the room appeared. RoomID, not name/source/member, is the
    /// complete authority key.
    func loadRoomComposerDraft(_ roomID: RoomID) async {
        let runtime = RoomRuntime.shared
        guard runtime.rooms.contains(where: { $0.id == roomID }) else {
            runtime.retireComposerDraft(roomID)
            return
        }
        let generation = runtime.composerDraftGenerations[roomID] ?? 0
        await runtime.composerDraftTasks[roomID]?.value
        guard runtime.composerDraftGenerations[roomID] ?? 0 == generation else { return }
        do {
            let value = try await RoomMutationGate.shared.withLock(roomID.description) {
                try await runtime.store.composerDraft(roomID: roomID)
            }
            guard runtime.composerDraftGenerations[roomID] ?? 0 == generation,
                  runtime.rooms.contains(where: { $0.id == roomID }) else { return }
            runtime.composerDrafts[roomID] = value
            runtime.composerDraftErrors[roomID] = nil
        } catch {
            guard runtime.composerDraftGenerations[roomID] ?? 0 == generation,
                  runtime.rooms.contains(where: { $0.id == roomID }) else { return }
            runtime.composerDraftErrors[roomID] = "Draft could not be restored from protected storage."
        }
    }

    /// Update presentation immediately, then serialize the bounded protected
    /// write behind earlier edits and the room mutation/privacy gate. Only the
    /// newest generation writes; stale queued snapshots are skipped.
    func updateRoomComposerDraft(_ proposed: String, roomID: RoomID) {
        let runtime = RoomRuntime.shared
        guard runtime.rooms.contains(where: { $0.id == roomID }) else {
            runtime.retireComposerDraft(roomID)
            return
        }
        let text = RoomComposerDraftPolicy.bounded(proposed)
        runtime.composerDrafts[roomID] = text
        runtime.composerDraftErrors[roomID] = nil
        let generation = runtime.bumpComposerDraftGeneration(roomID)
        let previous = runtime.composerDraftTasks[roomID]
        let task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled,
                  runtime.composerDraftGenerations[roomID] == generation else { return }
            do {
                _ = try await RoomMutationGate.shared.withLock(roomID.description) {
                    try await runtime.store.setComposerDraft(text, roomID: roomID)
                }
                guard runtime.composerDraftGenerations[roomID] == generation else { return }
                runtime.composerDraftErrors[roomID] = nil
            } catch {
                guard runtime.composerDraftGenerations[roomID] == generation else { return }
                runtime.composerDraftErrors[roomID] =
                    "Draft is still on screen but could not be saved to protected storage."
            }
            if runtime.composerDraftGenerations[roomID] == generation {
                runtime.composerDraftTasks[roomID] = nil
            }
        }
        runtime.composerDraftTasks[roomID] = task
    }

    func flushRoomComposerDraft(_ roomID: RoomID) async {
        await RoomRuntime.shared.composerDraftTasks[roomID]?.value
    }

    /// A send is not presented as complete until its exact draft deletion is
    /// durable. If newer text won while an await was suspended, that text and
    /// its queued write remain untouched.
    func clearRoomComposerDraftAfterSend(_ roomID: RoomID,
                                         submitted: String) async throws {
        let runtime = RoomRuntime.shared
        let expected = RoomComposerDraftPolicy.bounded(submitted)
        await runtime.composerDraftTasks[roomID]?.value
        guard runtime.rooms.contains(where: { $0.id == roomID }),
              runtime.composerDrafts[roomID] == expected else { return }
        let generation = runtime.bumpComposerDraftGeneration(roomID)
        do {
            _ = try await RoomMutationGate.shared.withLock(roomID.description) {
                try await runtime.store.setComposerDraft("", roomID: roomID)
            }
        } catch {
            guard runtime.composerDraftGenerations[roomID] == generation else { return }
            runtime.composerDraftErrors[roomID] =
                "Message sent, but its saved draft could not be cleared."
            throw RoomComposerDraftClearError.storage
        }
        guard runtime.composerDraftGenerations[roomID] == generation,
              runtime.composerDrafts[roomID] == expected else { return }
        runtime.composerDrafts[roomID] = ""
        runtime.composerDraftErrors[roomID] = nil
    }
}
