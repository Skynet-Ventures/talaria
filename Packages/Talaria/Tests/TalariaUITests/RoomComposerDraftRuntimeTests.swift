import XCTest
import TalariaKit
@testable import TalariaUI

private actor RoomDraftTestLatch {
    private var continuation: CheckedContinuation<Void, Never>?
    private var arrived = false

    func wait() async {
        arrived = true
        await withCheckedContinuation { continuation = $0 }
    }

    func hasArrived() -> Bool { arrived }
    func open() { continuation?.resume(); continuation = nil }
}

@MainActor
final class RoomComposerDraftRuntimeTests: XCTestCase {
    private var base: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "talaria-room-draft-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        resetRuntime(store: RoomStore(baseDirectory: base))
    }

    override func tearDown() async throws {
        resetRuntime(store: RoomStore.shared)
        try? FileManager.default.removeItem(at: base)
    }

    func testRuntimeKeepsRoomSwitchesIsolatedAndPersistsLatestBoundedValues() async throws {
        let store = RoomRuntime.shared.store
        let first = RoomRecord(name: "First", members: members())
        let second = RoomRecord(name: "Second", members: members())
        try await store.upsert(first)
        try await store.upsert(second)
        RoomRuntime.shared.rooms = [first, second]
        let model = AppModel()

        model.updateRoomComposerDraft("stale first draft", roomID: first.id)
        model.updateRoomComposerDraft("first draft", roomID: first.id)
        model.updateRoomComposerDraft("second draft", roomID: second.id)
        await model.flushRoomComposerDraft(first.id)
        await model.flushRoomComposerDraft(second.id)

        XCTAssertEqual(model.roomComposerDraft(first.id), "first draft")
        XCTAssertEqual(model.roomComposerDraft(second.id), "second draft")
        XCTAssertNil(model.roomComposerDraftError(first.id))
        let relaunched = RoomStore(baseDirectory: base)
        let firstRestored = try await relaunched.composerDraft(roomID: first.id)
        let secondRestored = try await relaunched.composerDraft(roomID: second.id)
        XCTAssertEqual(firstRestored, "first draft")
        XCTAssertEqual(secondRestored, "second draft")

        try await model.clearRoomComposerDraftAfterSend(first.id, submitted: "first draft")
        XCTAssertEqual(model.roomComposerDraft(first.id), "")
        XCTAssertEqual(model.roomComposerDraft(second.id), "second draft")
        let afterSend = RoomStore(baseDirectory: base)
        let cleared = try await afterSend.composerDraft(roomID: first.id)
        let untouched = try await afterSend.composerDraft(roomID: second.id)
        XCTAssertEqual(cleared, "")
        XCTAssertEqual(untouched, "second draft")

        try await model.clearRoomComposerDraftAfterSend(second.id, submitted: "older text")
        XCTAssertEqual(model.roomComposerDraft(second.id), "second draft")
    }

    func testRuntimeReloadRestoresOnlyTheExactImmutableRoom() async throws {
        let store = RoomRuntime.shared.store
        let first = RoomRecord(name: "Shared name", members: members())
        let second = RoomRecord(name: "Shared name", members: members())
        try await store.upsert(first)
        try await store.upsert(second)
        try await store.setComposerDraft("first only", roomID: first.id)
        RoomRuntime.shared.rooms = [first, second]
        RoomRuntime.shared.composerDrafts = [:]
        let model = AppModel()

        await model.loadRoomComposerDraft(second.id)
        await model.loadRoomComposerDraft(first.id)

        XCTAssertEqual(model.roomComposerDraft(second.id), "")
        XCTAssertEqual(model.roomComposerDraft(first.id), "first only")
    }

    func testSlowRestoreCannotReplaceTypingThatWonDuringTheRead() async throws {
        let runtime = RoomRuntime.shared
        let store = runtime.store
        let room = RoomRecord(name: "Race", members: members())
        try await store.upsert(room)
        try await store.setComposerDraft("old disk value", roomID: room.id)
        runtime.rooms = [room]
        let model = AppModel()
        let latch = RoomDraftTestLatch()
        let holder = Task { @MainActor in
            try await RoomMutationGate.shared.withLock(room.id.description) {
                await latch.wait()
            }
        }
        while !(await latch.hasArrived()) { await Task.yield() }

        let restore = Task { @MainActor in await model.loadRoomComposerDraft(room.id) }
        while RoomMutationGate.shared.queuedWaiterCount(for: room.id.description) == 0 {
            await Task.yield()
        }
        model.updateRoomComposerDraft("new typing", roomID: room.id)
        await latch.open()
        try await holder.value
        await restore.value
        await model.flushRoomComposerDraft(room.id)

        XCTAssertEqual(model.roomComposerDraft(room.id), "new typing")
        let persisted = try await store.composerDraft(roomID: room.id)
        XCTAssertEqual(persisted, "new typing")
    }

    func testRuntimeProjectionRetentionPurgesOnlyDeletedRoomIdentity() {
        let kept = RoomID()
        let deleted = RoomID()
        let runtime = RoomRuntime.shared
        runtime.composerDrafts = [kept: "keep", deleted: "purge"]
        runtime.composerDraftErrors = [deleted: "stale warning"]
        runtime.composerDraftGenerations = [kept: 1, deleted: 2]

        runtime.retainComposerDrafts(for: [kept])

        XCTAssertEqual(runtime.composerDrafts, [kept: "keep"])
        XCTAssertNil(runtime.composerDraftErrors[deleted])
        XCTAssertEqual(runtime.composerDraftGenerations[kept], 1)
        XCTAssertNil(runtime.composerDraftGenerations[deleted])
    }

    func testRetiredRoomRejectsAZeroGenerationRestoreCompletion() async throws {
        let runtime = RoomRuntime.shared
        let room = RoomRecord(name: "Retired", members: members())
        try await runtime.store.upsert(room)
        try await runtime.store.setComposerDraft("must stay retired", roomID: room.id)
        runtime.rooms = [room]
        let latch = RoomDraftTestLatch()
        let holder = Task { @MainActor in
            try await RoomMutationGate.shared.withLock(room.id.description) {
                await latch.wait()
            }
        }
        while !(await latch.hasArrived()) { await Task.yield() }

        let restore = Task { @MainActor in
            await AppModel().loadRoomComposerDraft(room.id)
        }
        while RoomMutationGate.shared.queuedWaiterCount(for: room.id.description) == 0 {
            await Task.yield()
        }
        runtime.rooms = []
        runtime.retireComposerDraft(room.id)
        await latch.open()
        try await holder.value
        await restore.value

        XCTAssertNil(runtime.composerDrafts[room.id])
        XCTAssertNil(runtime.composerDraftErrors[room.id])
    }

    private func resetRuntime(store: RoomStore) {
        let runtime = RoomRuntime.shared
        for task in runtime.composerDraftTasks.values { task.cancel() }
        runtime.store = store
        runtime.rooms = []
        runtime.composerDrafts = [:]
        runtime.composerDraftErrors = [:]
        runtime.composerDraftTasks = [:]
        runtime.composerDraftGenerations = [:]
    }

    private func members() -> [RoomMember] {
        [
            RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "default")),
            RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "reviewer")),
        ]
    }
}
