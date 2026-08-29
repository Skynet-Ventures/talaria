#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI

@MainActor
private final class SuspendedRoomMemberInterrupt {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func run() async -> RoomMemberHoldInterruptState {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return .confirmed
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class RoomMemberHoldRuntimeTests: XCTestCase {
    private var base: URL!
    private var store: RoomStore!
    private let route = GatewayBotRoute(gatewayID: "mini", profile: "worker")
    private let peerRoute = GatewayBotRoute(gatewayID: "mini", profile: "peer")

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-hold-runtime-\(UUID())", isDirectory: true)
        store = RoomStore(baseDirectory: base)
        RoomRuntime.shared.store = store
        RoomRuntime.shared.rooms = []
    }

    override func tearDown() async throws {
        let runtime = RoomRuntime.shared
        for task in runtime.driveTasks.values { task.cancel() }
        runtime.driveTasks.removeAll(); runtime.driveTokens.removeAll()
        runtime.memberHoldInterruptOperation = nil
        runtime.driveOperation = nil
        runtime.rooms = []
        runtime.store = RoomStore.shared
        try? FileManager.default.removeItem(at: base)
    }

    func testHoldPersistsBeforeAmbiguousStopAndExplicitResumeIsExact() async throws {
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: route, epoch: 3,
                                  promptText: "exact", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", state: .accepted)
        let room = RoomRecord(name: "Sticky",
                              members: [RoomMember(route: route), RoomMember(route: peerRoute)],
                              threads: [thread], attempts: [attempt], epoch: 3)
        try await store.upsert(room); RoomRuntime.shared.rooms = [room]
        var calls = 0
        RoomRuntime.shared.memberHoldInterruptOperation = { _ in
            calls += 1
            let persisted = try? await self.store.room(id: room.id)
            XCTAssertEqual(persisted?.memberHolds.count, 1)
            return .ambiguous
        }
        let model = AppModel()
        let hold = try await model.holdRoomMember(roomID: room.id, member: route)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(hold.interruptState, .ambiguous)
        let afterHold = try await store.room(id: room.id)
        XCTAssertNil(afterHold?.attempts[0].finishedAt)

        let duplicate = try await model.holdRoomMember(roomID: room.id, member: route)
        XCTAssertEqual(duplicate.id, hold.id)
        XCTAssertEqual(calls, 1)
        RoomRuntime.shared.driveOperation = { _, _ in }
        try await model.resumeRoomMember(roomID: room.id, holdID: hold.id, member: route)
        let afterResume = try await store.room(id: room.id)
        XCTAssertEqual(afterResume?.memberHolds, [])
        await RoomRuntime.shared.driveTasks[room.id]?.value
    }

    func testHeldBoundaryAdvancesExactWatermarkOnceWithoutNetworkWork() async throws {
        let thread = RoomThread()
        let peer = RoomMember(route: peerRoute)
        let member = RoomMember(route: route)
        let entries = [
            RoomEntry(threadID: thread.id, speaker: .user, speakerName: "You", text: "one"),
            RoomEntry(threadID: thread.id, speaker: .member, memberRoute: peerRoute,
                      speakerName: "Peer", text: "two"),
        ]
        let hold = RoomMemberHold(member: route, driveEpoch: 2)
        let room = RoomRecord(name: "Skip", members: [member, peer], threads: [thread],
                              entries: entries, memberHolds: [hold], epoch: 2)
        try await store.upsert(room); RoomRuntime.shared.rooms = [room]
        let model = AppModel()
        await model.runRoomMemberBoundary(roomID: room.id, epoch: 2,
                                          threadID: thread.id, member: member)
        await model.runRoomMemberBoundary(roomID: room.id, epoch: 2,
                                          threadID: thread.id, member: member)
        let loaded = try await store.room(id: room.id)
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.watermarks[RoomEngine.watermarkKey(
            threadID: thread.id, member: route)], entries.count)
        XCTAssertEqual(saved.activity.filter { $0.kind == .held && $0.member == route }.count, 1)
        XCTAssertEqual(saved.memberHolds[0].lastNotedEpoch, 2)
    }

    func testDefiniteFailureKeepsAttemptWhileConfirmedStopCancelsOnlyExactAttempt() async throws {
        let thread = RoomThread()
        func makeRoom(_ name: String) -> RoomRecord {
            let attempt = RoomAttempt(threadID: thread.id, member: route, epoch: 7,
                                      promptText: name, storedSessionID: "stored-\(name)",
                                      runtimeSessionID: "runtime-\(name)", state: .accepted)
            return RoomRecord(name: name,
                              members: [RoomMember(route: route), RoomMember(route: peerRoute)],
                              threads: [thread], attempts: [attempt], epoch: 7)
        }
        let failedRoom = makeRoom("Failed")
        try await store.upsert(failedRoom); RoomRuntime.shared.rooms = [failedRoom]
        RoomRuntime.shared.memberHoldInterruptOperation = { _ in .failed }
        let failed = try await AppModel().holdRoomMember(
            roomID: failedRoom.id, member: route)
        let failedSaved = try await store.room(id: failedRoom.id)
        XCTAssertEqual(failed.interruptState, .failed)
        XCTAssertNil(failedSaved?.attempts[0].finishedAt)
        XCTAssertEqual(failedSaved?.memberHolds.map(\.id), [failed.id])

        let confirmedRoom = makeRoom("Confirmed")
        try await store.upsert(confirmedRoom); RoomRuntime.shared.replace(confirmedRoom)
        RoomRuntime.shared.memberHoldInterruptOperation = { _ in .confirmed }
        let confirmed = try await AppModel().holdRoomMember(
            roomID: confirmedRoom.id, member: route)
        let confirmedSaved = try await store.room(id: confirmedRoom.id)
        XCTAssertEqual(confirmed.interruptState, .confirmed)
        XCTAssertEqual(confirmedSaved?.attempts[0].state, .cancelled)
        XCTAssertNotNil(confirmedSaved?.attempts[0].finishedAt)
        XCTAssertEqual(confirmedSaved?.memberHolds.map(\.id), [confirmed.id])
    }

    func testSuspendedInterruptReleasesRoomGateAndCannotOverwriteRecreatedHold() async throws {
        let thread = RoomThread()
        let member = RoomMember(route: route)
        let peer = RoomMember(route: peerRoute)
        let attempt = RoomAttempt(threadID: thread.id, member: route, epoch: 5,
                                  promptText: "slow stop", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", state: .accepted)
        let room = RoomRecord(name: "Concurrent", members: [member, peer],
                              threads: [thread], entries: [
                                RoomEntry(threadID: thread.id, speaker: .user,
                                          speakerName: "You", text: "work")
                              ], attempts: [attempt], epoch: 5)
        try await store.upsert(room); RoomRuntime.shared.rooms = [room]
        RoomRuntime.shared.driveOperation = { _, _ in }
        let suspended = SuspendedRoomMemberInterrupt()
        RoomRuntime.shared.memberHoldInterruptOperation = { _ in await suspended.run() }
        let model = AppModel()
        let holdTask = Task {
            try await model.holdRoomMember(roomID: room.id, member: self.route)
        }
        await suspended.waitUntilStarted()
        let duringInterrupt = try await store.room(id: room.id)
        let oldHold = try XCTUnwrap(duringInterrupt?.memberHolds.first)
        XCTAssertEqual(oldHold.interruptState, .pending)

        // Held arbitration remains visible while the interrupt is suspended.
        await model.runRoomMemberBoundary(roomID: room.id, epoch: 5,
                                          threadID: thread.id, member: member)
        let afterSkip = try await store.room(id: room.id)
        XCTAssertEqual(afterSkip?.watermarks[RoomEngine.watermarkKey(
            threadID: thread.id, member: route)], 1)

        // A separate room-gated peer mutation must not wait for phase 2.
        let gateFinished = expectation(description: "room gate released during interrupt")
        let peerMutation = Task { @MainActor in
            try await RoomMutationGate.shared.withLock(room.id.description) {
                let updated = try await self.store.mutate(roomID: room.id) { current in
                    RoomEngine.recordActivity(RoomActivity(
                        epoch: current.epoch, kind: .working,
                        member: self.peerRoute, threadID: thread.id), in: &current)
                }
                RoomRuntime.shared.replace(updated)
            }
            gateFinished.fulfill()
        }
        await fulfillment(of: [gateFinished], timeout: 0.5)
        _ = try await peerMutation.value

        // Resume and a new exact hold both win while the old result is still
        // suspended. Its later confirmed settlement must not touch either.
        try await model.resumeRoomMember(
            roomID: room.id, holdID: oldHold.id, member: route)
        let replacement = RoomMemberHold(member: route, driveEpoch: 5,
                                         interruptState: .notNeeded)
        try await RoomMutationGate.shared.withLock(room.id.description) {
            let updated = try await store.mutate(roomID: room.id) {
                $0.memberHolds.append(replacement)
            }
            RoomRuntime.shared.replace(updated)
        }
        suspended.release()
        _ = try await holdTask.value

        let final = try await store.room(id: room.id)
        XCTAssertEqual(final?.memberHolds.map(\.id), [replacement.id])
        XCTAssertEqual(final?.memberHolds.first?.interruptState, .notNeeded)
        XCTAssertNil(final?.attempts.first?.finishedAt)
    }

    func testMemberRemovalPurgesHoldAndSameRouteReaddDoesNotInherit() async throws {
        let a = RoomMember(route: route)
        let b = RoomMember(route: peerRoute)
        let c = RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "third"))
        let room = RoomRecord(name: "Remove", members: [a, b, c],
                              memberHolds: [RoomMemberHold(member: route, driveEpoch: 0)])
        try await store.upsert(room); RoomRuntime.shared.rooms = [room]
        let model = AppModel()
        try await model.updateRoomSettings(room.id, name: room.name, members: [b, c])
        let removed = try await store.room(id: room.id)
        XCTAssertEqual(removed?.memberHolds, [])
        try await model.updateRoomSettings(room.id, name: room.name, members: [a, b, c])
        let readded = try await store.room(id: room.id)
        XCTAssertEqual(readded?.memberHolds, [])
    }

    func testRelaunchedPendingHoldBecomesAmbiguousAndSkipsUntilExplicitResume() async throws {
        let thread = RoomThread()
        let member = RoomMember(route: route)
        let peer = RoomMember(route: peerRoute)
        let attempt = RoomAttempt(threadID: thread.id, member: route, epoch: 4,
                                  promptText: "crashed interrupt",
                                  storedSessionID: "stored", runtimeSessionID: "runtime",
                                  state: .accepted)
        let pending = RoomMemberHold(member: route, driveEpoch: 4,
                                     threadID: thread.id, attemptID: attempt.id,
                                     storedSessionID: attempt.storedSessionID,
                                     runtimeSessionID: attempt.runtimeSessionID,
                                     interruptState: .pending)
        let room = RoomRecord(name: "Relaunch", members: [member, peer],
                              threads: [thread], entries: [
                                RoomEntry(threadID: thread.id, speaker: .user,
                                          speakerName: "You", text: "continue peers")
                              ], attempts: [attempt], memberHolds: [pending], epoch: 4)
        try await store.upsert(room)

        let relaunched = RoomStore(baseDirectory: base)
        let loaded = try await relaunched.loadAll()
        let restored = try XCTUnwrap(loaded.first)
        RoomRuntime.shared.store = relaunched
        RoomRuntime.shared.rooms = [restored]
        var interruptCalls = 0
        RoomRuntime.shared.memberHoldInterruptOperation = { _ in
            interruptCalls += 1
            return .confirmed
        }
        XCTAssertEqual(restored.memberHolds.first?.interruptState, .ambiguous)

        let model = AppModel()
        await model.runRoomMemberBoundary(roomID: room.id, epoch: 4,
                                          threadID: thread.id, member: member)
        let skipped = try await relaunched.room(id: room.id)
        XCTAssertEqual(skipped?.memberHolds.first?.id, pending.id)
        XCTAssertEqual(skipped?.watermarks[RoomEngine.watermarkKey(
            threadID: thread.id, member: route)], 1)
        XCTAssertEqual(interruptCalls, 0)

        RoomRuntime.shared.driveOperation = { _, _ in }
        try await model.resumeRoomMember(
            roomID: room.id, holdID: pending.id, member: route)
        let resumed = try await relaunched.room(id: room.id)
        XCTAssertEqual(resumed?.memberHolds, [])
        XCTAssertEqual(interruptCalls, 0)
    }
}
#endif
