#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI

private actor RoomDriveProbe {
    private var active = 0
    private(set) var maximumActive = 0
    private(set) var starts: [RoomID] = []

    func begin(_ id: RoomID) {
        active += 1
        maximumActive = max(maximumActive, active)
        starts.append(id)
    }

    func end() { active -= 1 }
}

private actor RoomSubmitProbe {
    private(set) var calls = 0
    private(set) var sawWorking = false
    func record(working: Bool) { calls += 1; sawWorking = sawWorking || working }
}

private actor RoomMetadataProbe {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func execute(_ mutation: RoomMetadataMutation) async throws {
        _ = mutation
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { release = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resume() { release?.resume(); release = nil }
}

private actor RoomNameCommitProbe {
    private var firstStarted = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    /// Suspend only the first mutation which reaches the post-collision,
    /// pre-commit boundary. Without namespace serialization, its competitor
    /// can then pass the same collision check and commit a duplicate name.
    func pauseFirstCommit() async {
        guard !firstStarted else { return }
        firstStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilFirstStarted() async {
        if firstStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resumeFirst() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private enum RoomNameMetadataFailure: Error { case offline }

@MainActor
final class RoomRoutingTests: XCTestCase {
    private func waitUntilSettled(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    override func tearDown() {
        let runtime = RoomRuntime.shared
        for task in runtime.driveTasks.values { task.cancel() }
        for task in runtime.postSettleHarvestTasks.values { task.cancel() }
        runtime.driveTasks.removeAll()
        runtime.driveTokens.removeAll()
        runtime.postSettleHarvestTasks.removeAll()
        runtime.postSettleHarvestTokens.removeAll()
        runtime.driveOperation = nil
        runtime.loadOperation = nil
        runtime.submitOperation = nil
        runtime.metadataMutationOperation = nil
        runtime.sessionReadOperation = nil
        runtime.pendingPromptResponseOperation = nil
        runtime.roomNameCommitBarrier = nil
        runtime.pendingPrompts.removeAll()
        runtime.answeredPromptQuestions.removeAll()
        runtime.profileRouteGenerations.removeAll()
        runtime.retiredProfileRoutes.removeAll()
        runtime.store = RoomStore.shared
        runtime.pollInterval = .seconds(2)
        runtime.baseTurnTimeout = 180
        runtime.hardTurnTimeout = 20 * 60
        runtime.postSettleHarvestInterval = .seconds(5)
        runtime.postSettleHarvestLimit = 60
        runtime.rooms = []
        runtime.openRoomID = nil
        super.tearDown()
    }

    func testRoomDrivesWaitForActualPriorCompletion() async {
        let runtime = RoomRuntime.shared
        let model = AppModel()
        let roomID = RoomID()
        let probe = RoomDriveProbe()
        runtime.driveOperation = { _, id in
            await probe.begin(id)
            try? await Task.sleep(for: .milliseconds(60))
            await probe.end()
        }

        model.scheduleRoomDrive(roomID: roomID)
        model.scheduleRoomDrive(roomID: roomID)
        await runtime.driveTasks[roomID]?.value

        let maximum = await probe.maximumActive
        let starts = await probe.starts
        XCTAssertEqual(maximum, 1, "A 250 ms timer hand-off would allow overlapping owners")
        XCTAssertEqual(starts, [roomID, roomID])
    }

    func testRoomMutationGateDropsCancelledWaiterWithoutWedgingNext() async {
        let gate = RoomMutationGate()
        var releaseOwner: CheckedContinuation<Void, Never>?
        let owner = Task { @MainActor in
            try? await gate.withLock("room") {
                await withCheckedContinuation { releaseOwner = $0 }
            }
        }
        while releaseOwner == nil { await Task.yield() }

        var cancelledRan = false
        let cancelled = Task { @MainActor in
            try? await gate.withLock("room") { cancelledRan = true }
        }
        await Task.yield()
        var finalRan = false
        let final = Task { @MainActor in
            try? await gate.withLock("room") { finalRan = true }
        }
        await Task.yield()
        cancelled.cancel()
        await cancelled.value
        XCTAssertFalse(cancelledRan)
        XCTAssertFalse(finalRan)

        releaseOwner?.resume()
        await owner.value
        await final.value
        XCTAssertTrue(finalRan)
    }

    func testRoomMutationCancellationAfterGrantReleasesKey() async {
        let gate = RoomMutationGate()
        var releaseOwner: CheckedContinuation<Void, Never>?
        let owner = Task { @MainActor in
            try? await gate.withLock("room") {
                await withCheckedContinuation { releaseOwner = $0 }
            }
        }
        while releaseOwner == nil { await Task.yield() }
        var cancelledRan = false
        let cancelled = Task { @MainActor in
            try? await gate.withLock("room") { cancelledRan = true }
        }
        while gate.queuedWaiterCount(for: "room") == 0 { await Task.yield() }

        releaseOwner?.resume()
        cancelled.cancel()
        await owner.value
        await cancelled.value
        XCTAssertFalse(cancelledRan)

        var finalRan = false
        try? await gate.withLock("room") { finalRan = true }
        XCTAssertTrue(finalRan)
    }

    func testRoomQuiescenceDrainsOwnerAndBlocksNewMutationUntilDeletionEnds() async {
        let gate = RoomMutationGate()
        var releaseOwner: CheckedContinuation<Void, Never>?
        let owner = Task { @MainActor in
            try? await gate.withLock("room-a") {
                await withCheckedContinuation { releaseOwner = $0 }
            }
        }
        while releaseOwner == nil { await Task.yield() }

        var quiescenceEntered = false
        var releaseQuiescence: CheckedContinuation<Void, Never>?
        let deletion = Task { @MainActor in
            await gate.withQuiescence {
                quiescenceEntered = true
                await withCheckedContinuation { releaseQuiescence = $0 }
            }
        }
        await Task.yield()
        var laterMutationRan = false
        let later = Task { @MainActor in
            try? await gate.withLock("room-b") { laterMutationRan = true }
        }
        await Task.yield()
        XCTAssertFalse(quiescenceEntered)
        XCTAssertFalse(laterMutationRan)

        releaseOwner?.resume()
        await owner.value
        while releaseQuiescence == nil { await Task.yield() }
        XCTAssertTrue(quiescenceEntered)
        XCTAssertFalse(laterMutationRan)

        releaseQuiescence?.resume()
        await deletion.value
        await later.value
        XCTAssertTrue(laterMutationRan)
    }

    func testRoomCreateUsesAlreadyAdmittedFlushSoDeleteQuiescenceCannotDeadlock() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-create-delete-quiescence-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        let barrier = RoomNameCommitProbe()
        runtime.roomNameCommitBarrier = { await barrier.pauseFirstCommit() }
        var metadataCalls = 0
        runtime.metadataMutationOperation = { _ in metadataCalls += 1 }
        let members = [
            RoomMember(route: GatewayBotRoute(gatewayID: "alpha", profile: "one")),
            RoomMember(route: GatewayBotRoute(gatewayID: "alpha", profile: "two")),
        ]
        let model = AppModel()
        var createFinished = false
        var deleteFinished = false
        let create = Task { @MainActor () throws -> RoomID in
            defer { createFinished = true }
            return try await model.createRoom(name: "Fleet", members: members)
        }
        await barrier.waitUntilFirstStarted()
        let deletion = Task { @MainActor in
            defer { deleteFinished = true }
            try await model.deleteAllRoomData()
        }
        let quiescenceStarted = await waitUntilSettled {
            RoomMutationGate.shared.quiescenceIsPending
        }
        guard quiescenceStarted else {
            await barrier.resumeFirst()
            create.cancel()
            deletion.cancel()
            _ = try? await create.value
            _ = try? await deletion.value
            XCTFail("delete-all did not enter room-mutation quiescence")
            return
        }

        await barrier.resumeFirst()
        let completed = await waitUntilSettled { createFinished && deleteFinished }
        if !completed {
            create.cancel()
            deletion.cancel()
            XCTFail("room creation and delete-all quiescence deadlocked at metadata flush admission")
        }
        _ = try? await create.value
        _ = try? await deletion.value

        XCTAssertTrue(completed)
        XCTAssertEqual(metadataCalls, members.count,
                       "the already-admitted FIFO flush must settle before deletion")
        let storedRooms = try await store.loadAll()
        let storedOutbox = try await store.metadataOutbox()
        XCTAssertTrue(storedRooms.isEmpty)
        XCTAssertTrue(storedOutbox.isEmpty)
        XCTAssertTrue(runtime.rooms.isEmpty)
    }

    func testPublicMetadataFlushHoldsAdmissionUntilItsSourceMutationSettles() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-flush-delete-quiescence-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let route = GatewayBotRoute(gatewayID: "alpha", profile: "one")
        let sibling = GatewayBotRoute(gatewayID: "alpha", profile: "two")
        let room = RoomRecord(name: "Fleet", members: [
            RoomMember(route: route), RoomMember(route: sibling),
        ])
        try await store.upsert(room, metadataMutations: [
            RoomMetadataMutation(route: route, kind: .add, newName: room.name),
        ])
        let runtime = RoomRuntime.shared
        runtime.store = store
        runtime.rooms = [room]
        let probe = RoomMetadataProbe()
        runtime.metadataMutationOperation = { mutation in
            try await probe.execute(mutation)
        }
        let model = AppModel()
        var flushFinished = false
        var deleteFinished = false
        let flush = Task { @MainActor in
            defer { flushFinished = true }
            await model.flushRoomMetadataOutbox()
        }
        await probe.waitUntilStarted()
        let deletion = Task { @MainActor in
            defer { deleteFinished = true }
            try await model.deleteAllRoomData()
        }
        let quiescenceStarted = await waitUntilSettled {
            RoomMutationGate.shared.quiescenceIsPending
        }
        guard quiescenceStarted else {
            await probe.resume()
            flush.cancel()
            deletion.cancel()
            await flush.value
            _ = try? await deletion.value
            XCTFail("delete-all did not wait on public metadata-flush admission")
            return
        }
        XCTAssertFalse(deleteFinished,
                       "delete-all must wait for an admitted public metadata flush")

        await probe.resume()
        let completed = await waitUntilSettled { flushFinished && deleteFinished }
        if !completed {
            flush.cancel()
            deletion.cancel()
            XCTFail("public metadata flush did not release admission to delete-all")
        }
        await flush.value
        _ = try? await deletion.value

        XCTAssertTrue(completed)
        let storedRooms = try await store.loadAll()
        let storedOutbox = try await store.metadataOutbox()
        XCTAssertTrue(storedRooms.isEmpty)
        XCTAssertTrue(storedOutbox.isEmpty)
        XCTAssertTrue(runtime.rooms.isEmpty)
    }

    func testRoomLoadCannotRepublishSnapshotAcrossLocalDataDeletion() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-load-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        runtime.isLoaded = false
        let room = RoomRecord(name: "Snapshot", members: [
            RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "one")),
            RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "two")),
        ])
        try await store.upsert(room)
        var releaseLoad: CheckedContinuation<Void, Never>?
        runtime.loadOperation = {
            await withCheckedContinuation { releaseLoad = $0 }
            return [room]
        }
        let model = AppModel()
        let load = Task { @MainActor in await model.loadRooms() }
        while releaseLoad == nil { await Task.yield() }
        let deletion = Task { @MainActor in try await model.deleteAllRoomData() }
        await Task.yield()

        releaseLoad?.resume()
        await load.value
        try await deletion.value
        XCTAssertTrue(runtime.rooms.isEmpty)
        XCTAssertFalse(runtime.isLoaded)
        let erased = try await store.loadAll()
        XCTAssertEqual(erased, [])
    }

    func testRoomDeletionFailsClosedBeforeEmptyCommitAndPreservesRuntime() async throws {
        enum Injected: Error { case stop }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-delete-precommit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base, deleteFailure: { phase in
            if case .beforeEmptyCommit = phase { throw Injected.stop }
        })
        let members = [
            RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "one")),
            RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "two")),
        ]
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: members[0].route, epoch: 1,
                                  promptText: "accepted already", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", state: .accepted)
        let room = RoomRecord(name: "Private", members: members, threads: [thread],
                              attempts: [attempt], drives: [
                                RoomDriveState(threadID: thread.id, epoch: 1)
                              ], epoch: 1)
        try await store.upsert(room)
        RoomRuntime.shared.store = store
        RoomRuntime.shared.rooms = [room]
        RoomRuntime.shared.driveTasks[room.id] = Task {}
        RoomRuntime.shared.driveTokens[room.id] = UUID()
        var resumedOwners = 0
        var submissions = 0
        RoomRuntime.shared.driveOperation = { _, _ in resumedOwners += 1 }
        RoomRuntime.shared.submitOperation = { _, _, _ in
            submissions += 1
            return RoomPromptSubmission(acceptance: .uncertain("must not run"),
                                        runtimeID: "runtime", storedID: "stored", baseline: 0)
        }
        defer {
            RoomRuntime.shared.driveOperation = nil
            RoomRuntime.shared.submitOperation = nil
            RoomRuntime.shared.driveTasks.removeAll()
            RoomRuntime.shared.driveTokens.removeAll()
        }
        let model = AppModel()
        do { try await model.deleteAllRoomData(); XCTFail("reported false erasure") }
        catch { XCTAssertEqual(error as? RoomStoreError, .deleteCommitFailed) }
        for _ in 0..<1_000 where resumedOwners == 0 { await Task.yield() }
        XCTAssertEqual(resumedOwners, 1)
        XCTAssertEqual(submissions, 0)
        XCTAssertEqual(RoomRuntime.shared.rooms.map(\.id), [room.id])
        let preserved = try await RoomStore(baseDirectory: base).loadAll()
        XCTAssertEqual(preserved.map(\.id), [room.id])
    }

    func testRoomDeletionSurfacesCleanupFailureAfterAuthoritativeEmptyCommit() async throws {
        enum Injected: Error { case stop }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-delete-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base, deleteFailure: { phase in
            if case .afterEmptyCommit = phase { throw Injected.stop }
        })
        let room = RoomRecord(name: "Private", members: [
            RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "one")),
            RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "two")),
        ])
        try await store.upsert(room)
        RoomRuntime.shared.store = store
        RoomRuntime.shared.rooms = [room]
        do { try await AppModel().deleteAllRoomData(); XCTFail("hid residual cleanup") }
        catch { XCTAssertEqual(error as? RoomStoreError, .deleteCleanupFailed) }
        XCTAssertTrue(RoomRuntime.shared.rooms.isEmpty)
        let erased = try await RoomStore(baseDirectory: base).loadAll()
        XCTAssertEqual(erased, [])
    }

    func testExactAttemptAnchorAndPromptHashReconcileAcceptance() {
        let attempt = makeAttempt(prompt: "Exact room delta")
        let snapshot = RoomMemberSessionSnapshot(
            runtimeID: "deadbeef", storedID: "stored", messages: [
                message(role: "user", text: attempt.promptAnchor + "\n" + attempt.promptText
                        + "\n\nAttached files staged in your session workspace:\na → @file:a"),
            ], running: false)

        XCTAssertTrue(snapshot.containsAttempt(attempt))

        let forged = RoomAttempt(threadID: attempt.threadID, member: attempt.member,
                                 epoch: attempt.epoch, promptText: "Different delta",
                                 storedSessionID: "stored", runtimeSessionID: "deadbeef")
        let sameMarkerWrongBody = RoomMemberSessionSnapshot(
            runtimeID: "deadbeef", storedID: "stored", messages: [
                message(role: "user", text: forged.promptAnchor + "\nnot the persisted prompt"),
            ], running: false)
        XCTAssertFalse(sameMarkerWrongBody.containsAttempt(forged))
    }

    func testRoomSessionProjectionTreatsNullInflightAsIdle() {
        let live = LiveSession(.object([
            "session_id": .string("runtime"),
            "stored_session_id": .string("stored"),
            "running": .bool(false),
            "inflight": .null,
        ]))

        XCTAssertFalse(RoomMemberSessionSnapshot(liveSession: live).running)
    }

    func testRoomSessionProjectionTreatsNonNullInflightAsActive() {
        let live = LiveSession(.object([
            "session_id": .string("runtime"),
            "stored_session_id": .string("stored"),
            "running": .bool(false),
            "inflight": .object(["text": .string("partial")]),
        ]))

        XCTAssertTrue(RoomMemberSessionSnapshot(liveSession: live).running)
    }

    func testRoomSessionResolverNeverCreatesAfterTransientResumeFailure() async {
        var resumes: [String] = []
        var creates = 0
        do {
            _ = try await RoomSessionResolver.resolve(
                storedID: "durable", immutableTitle: "Group: room-id",
                legacyTitle: "Group: Team",
                resume: { target -> String in
                    resumes.append(target)
                    throw GatewayError(code: -3, message: "offline")
                },
                create: { creates += 1; return "created" })
            XCTFail("Transient durable resume must propagate")
        } catch {}
        XCTAssertEqual(resumes, ["durable"])
        XCTAssertEqual(creates, 0)

        resumes = []; creates = 0
        do {
            _ = try await RoomSessionResolver.resolve(
                storedID: "gone", immutableTitle: "Group: room-id",
                legacyTitle: "Group: Team",
                resume: { target -> String in
                    resumes.append(target)
                    if target == "gone" {
                        throw GatewayError(code: GatewayError.storedSessionGone, message: "gone")
                    }
                    throw GatewayError(code: -3, message: "offline")
                },
                create: { creates += 1; return "created" })
            XCTFail("Transient title resume must propagate")
        } catch {}
        XCTAssertEqual(resumes, ["gone", "Group: room-id"])
        XCTAssertEqual(creates, 0)

        resumes = []; creates = 0
        do {
            _ = try await RoomSessionResolver.resolve(
                storedID: "gone", immutableTitle: "Group: room-id",
                legacyTitle: "Group: Team",
                resume: { target -> String in
                    resumes.append(target)
                    if target != "Group: Team" {
                        throw GatewayError(code: GatewayError.storedSessionGone, message: "gone")
                    }
                    throw GatewayError(code: -3, message: "offline")
                },
                create: { creates += 1; return "created" })
            XCTFail("Transient legacy-title resume must propagate")
        } catch {}
        XCTAssertEqual(resumes, ["gone", "Group: room-id", "Group: Team"])
        XCTAssertEqual(creates, 0)
    }

    func testRoomSessionResolverCreatesOnlyAfterEveryAllowedTargetIsDefinitelyMissing() async throws {
        var resumes: [String] = []
        var creates = 0
        let result = try await RoomSessionResolver.resolve(
            storedID: "gone", immutableTitle: "Group: room-id",
            legacyTitle: "Group: Team",
            resume: { target -> String in
                resumes.append(target)
                throw GatewayError(code: GatewayError.storedSessionGone, message: "gone")
            },
            create: { creates += 1; return "created" })
        XCTAssertEqual(result, "created")
        XCTAssertEqual(resumes, ["gone", "Group: room-id", "Group: Team"])
        XCTAssertEqual(creates, 1)
    }

    func testLegacyRoomRenameKeepsItsCapturedNameFallbackAfterImmutableLookup() async throws {
        let id = RoomID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        var room = RoomRecord(
            id: id, name: "Original", members: [],
            sessionTitleIdentityVersion: RoomRecord.legacyNameSessionTitleVersion,
            legacySessionTitleName: "Original")
        room.name = "Renamed"

        var resumes: [String] = []
        let result = try await RoomSessionResolver.resolve(
            storedID: "gone",
            immutableTitle: "Group: \(room.id.description)",
            legacyTitle: room.sessionTitleIdentityVersion
                == RoomRecord.legacyNameSessionTitleVersion
                ? room.legacySessionTitleName.map { "Group: \($0)" } : nil,
            resume: { target -> String in
                resumes.append(target)
                if target == "Group: Original" { return "legacy-session" }
                throw GatewayError(code: GatewayError.storedSessionGone, message: "gone")
            },
            create: { "created" })

        XCTAssertEqual(result, "legacy-session")
        XCTAssertEqual(resumes, ["gone", "Group: \(id.description)", "Group: Original"])
        XCTAssertFalse(resumes.contains("Group: Renamed"))
    }

    func testSameNameRecreateCannotResumeDisbandedRoomsNameTitledSession() async throws {
        let oldID = RoomID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        let recreatedID = RoomID(rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!)
        let recreated = RoomRecord(id: recreatedID, name: "Team", members: [])
        XCTAssertEqual(recreated.sessionTitleIdentityVersion,
                       RoomRecord.immutableIDSessionTitleVersion)
        XCTAssertNil(recreated.legacySessionTitleName)

        var resumes: [String] = []
        var createdTitle: String?
        let immutableTitle = "Group: \(recreated.id.description)"
        let result = try await RoomSessionResolver.resolve(
            storedID: nil, immutableTitle: immutableTitle,
            resume: { target -> String in
                resumes.append(target)
                if target == "Group: Team" { return "old-name-session" }
                throw GatewayError(code: GatewayError.storedSessionGone, message: "gone")
            },
            create: {
                createdTitle = immutableTitle
                return "new-session"
            })

        XCTAssertEqual(result, "new-session")
        XCTAssertEqual(resumes, [immutableTitle])
        XCTAssertEqual(createdTitle, immutableTitle)
        XCTAssertNotEqual("Group: \(oldID.description)", immutableTitle)
        XCTAssertFalse(resumes.contains("Group: Team"))
    }

    func testReplyMustFollowExactAnchorBeforeAnyLaterUserTurn() {
        let attempt = makeAttempt(prompt: "Room turn")
        let unrelated = RoomMemberSessionSnapshot(
            runtimeID: "deadbeef", storedID: "stored", messages: [
                message(role: "user", text: attempt.promptAnchor + "\n" + attempt.promptText),
                message(role: "user", text: "unrelated later turn"),
                message(role: "assistant", text: "not the room reply"),
            ], running: false)
        XCTAssertNil(unrelated.assistantReply(for: attempt))

        let causal = RoomMemberSessionSnapshot(
            runtimeID: "deadbeef", storedID: "stored", messages: [
                message(role: "user", text: attempt.promptAnchor + "\n" + attempt.promptText),
                message(role: "assistant", text: "room answer"),
                message(role: "user", text: "later"),
                message(role: "assistant", text: "later answer"),
            ], running: false)
        XCTAssertEqual(causal.assistantReply(for: attempt), "room answer")
    }

    func testRoomNavigationIdentitySurvivesRename() {
        let id = RoomID()
        let routeA = GatewayBotRoute(gatewayID: "mini", profile: "default")
        let routeB = GatewayBotRoute(gatewayID: "lab", profile: "default")
        var room = RoomRecord(id: id, name: "Old name", members: [
            RoomMember(route: routeA), RoomMember(route: routeB, handle: "hermes-lab"),
        ])
        room.name = "New name"
        XCTAssertEqual(room.id, id)
        XCTAssertNotEqual(room.members[0].route, room.members[1].route)
    }

    func testConcurrentUserSendsAppendBothWithoutClobberingEpoch() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        runtime.driveOperation = { _, _ in }
        let model = AppModel()
        let room = RoomRecord(name: "Team", members: [
            RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "one")),
            RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "two")),
        ])
        try await store.upsert(room)
        runtime.replace(room)

        async let first = model.sendRoomMessage(roomID: room.id, text: "first")
        async let second = model.sendRoomMessage(roomID: room.id, text: "second")
        _ = try await (first, second)
        await runtime.driveTasks[room.id]?.value

        let loaded = try await store.room(id: room.id)
        let persisted = try XCTUnwrap(loaded)
        XCTAssertEqual(Set(persisted.entries.map(\.text)), ["first", "second"])
        XCTAssertEqual(persisted.entries.count, 2)
        XCTAssertEqual(persisted.threads.count, 2)
        XCTAssertEqual(persisted.epoch, 2)
        try await store.deleteAll()
    }

    func testSupersededAcceptedTurnDoesNotHoldNewDriveUntilTimeout() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-supersede-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        runtime.pollInterval = .seconds(10)
        let model = AppModel()
        let a = RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "one"))
        let b = RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "two"))
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: a.route, epoch: 1,
                                  promptText: "old turn", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", state: .accepted)
        let room = RoomRecord(name: "Team", members: [a, b], threads: [thread],
                              attempts: [attempt], epoch: 2)
        try await store.upsert(room)

        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await model.waitForRoomReply(roomID: room.id, attemptID: attempt.id)
        }
        XCTAssertLessThan(elapsed, .milliseconds(100))
        try await store.deleteAll()
    }

    func testRoomNamesAreCappedAndCreationSuffixesCollisions() throws {
        XCTAssertEqual(try RoomNamePolicy.unique("Ops", existing: ["ops", "Ops 2"]), "Ops 3")
        XCTAssertEqual(try RoomNamePolicy.normalized(String(repeating: "x", count: 80)).count, 64)
        XCTAssertThrowsError(try RoomNamePolicy.normalized("  "))
    }

    func testBusyAttemptSubmitsOnceAfterIdleAndWorkingNeverResubmits() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-waiting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        runtime.pollInterval = .milliseconds(1)
        let model = AppModel()
        let a = RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "one"))
        let b = RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "two"))
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: a.route, epoch: 1,
                                  promptText: "persisted delta", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", state: .waiting)
        let room = RoomRecord(name: "Team", members: [a, b], threads: [thread],
                              attempts: [attempt], epoch: 1)
        try await store.upsert(room)
        let probe = RoomSubmitProbe()
        let root = base.appendingPathComponent("Rooms", isDirectory: true)
        let index = root.appendingPathComponent("rooms-v1.json")
        let backup = root.appendingPathComponent("rooms-v1.backup")
        let sentinel = base.appendingPathComponent("sentinel")
        try Data("do-not-overwrite".utf8).write(to: sentinel)
        runtime.submitOperation = { claimed, session, _ in
            let loaded = try? await store.room(id: room.id)
            let working = loaded?.attempts.first(where: { $0.id == claimed.id })?.state == .working
            await probe.record(working: working)
            // Force only the post-network result save to fail closed. The
            // pre-network `.working` CAS is already durable in `backup`.
            try? FileManager.default.moveItem(at: index, to: backup)
            try? FileManager.default.createSymbolicLink(at: index,
                                                        withDestinationURL: sentinel)
            return RoomPromptSubmission(acceptance: .accepted,
                                        runtimeID: session.runtimeID,
                                        storedID: session.storedID,
                                        baseline: session.messageCount)
        }
        let snapshot = RoomMemberSessionSnapshot(runtimeID: "runtime", storedID: "stored",
                                                 messages: [], running: false)
        let client = GatewayClient(baseURL: URL(string: "https://example.invalid")!,
                                   credential: .sessionToken("test"))

        async let first: Void = model.submitWaitingRoomAttempt(
            roomID: room.id, attempt: attempt, session: snapshot, client: client)
        async let second: Void = model.submitWaitingRoomAttempt(
            roomID: room.id, attempt: attempt, session: snapshot, client: client)
        _ = await (first, second)

        let firstCalls = await probe.calls
        let sawWorking = await probe.sawWorking
        XCTAssertEqual(firstCalls, 1)
        XCTAssertTrue(sawWorking)
        try? FileManager.default.removeItem(at: index)
        try FileManager.default.moveItem(at: backup, to: index)
        let relaunched = RoomStore(baseDirectory: base)
        let relaunchedRoom = try await relaunched.room(id: room.id)
        let durable = try XCTUnwrap(relaunchedRoom)
        XCTAssertEqual(durable.attempts.first?.state, .working)
        // Relaunch sees `.working`; the waiting CAS cannot cross the network
        // boundary again even though the accepted-result save was lost.
        await model.submitWaitingRoomAttempt(roomID: room.id, attempt: attempt,
                                             session: snapshot, client: client)
        let finalCalls = await probe.calls
        XCTAssertEqual(finalCalls, 1)
        try await store.deleteAll()
    }

    func testFrozenPrimaryRoutesAndOfflineMembersSurviveSettingsSave() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-frozen-routes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        RoomRuntime.shared.store = store
        let model = AppModel()
        let frozen = [
            RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "default"),
                       handle: "hermes-mini", sourceLabel: "Mini"),
            RoomMember(route: GatewayBotRoute(gatewayID: "lab", profile: "default"),
                       handle: "hermes-lab", sourceLabel: "Lab"),
        ]
        let id = try await model.createRoom(name: "Fleet", members: frozen)
        // Neither route is in the current union roster; settings accepts the
        // frozen descriptors instead of rebuilding from whatever is online.
        try await model.updateRoomSettings(id, name: "Fleet renamed", members: frozen)
        let loaded = try await store.room(id: id)
        let persisted = try XCTUnwrap(loaded)
        XCTAssertEqual(persisted.members.map(\.route), frozen.map(\.route))
        XCTAssertEqual(persisted.name, "Fleet renamed")
        try await store.deleteAll()
    }

    func testConcurrentRoomRenamesSerializeNameCheckThroughStoreAndOutboxCommit() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-name-rename-race-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        runtime.metadataMutationOperation = { _ in throw RoomNameMetadataFailure.offline }
        let alphaMembers = [
            RoomMember(route: GatewayBotRoute(gatewayID: "alpha", profile: "one")),
            RoomMember(route: GatewayBotRoute(gatewayID: "alpha", profile: "two")),
        ]
        let betaMembers = [
            RoomMember(route: GatewayBotRoute(gatewayID: "beta", profile: "one")),
            RoomMember(route: GatewayBotRoute(gatewayID: "beta", profile: "two")),
        ]
        let alpha = RoomRecord(name: "Alpha", members: alphaMembers)
        let beta = RoomRecord(name: "Beta", members: betaMembers)
        try await store.upsert(alpha)
        try await store.upsert(beta)
        runtime.rooms = [alpha, beta]

        let probe = RoomNameCommitProbe()
        runtime.roomNameCommitBarrier = { await probe.pauseFirstCommit() }
        let model = AppModel()
        let winner = Task { @MainActor in
            try await model.renameRoom(alpha.id, name: "Shared")
        }
        await probe.waitUntilFirstStarted()
        let loser = Task { @MainActor in
            try await model.renameRoom(beta.id, name: "Shared")
        }
        while RoomMutationGate.shared.queuedWaiterCount(
            for: RoomMutationGate.roomNameNamespaceKey) == 0 {
            await Task.yield()
        }
        await probe.resumeFirst()

        try await winner.value
        do {
            try await loser.value
            XCTFail("the second rename must observe the committed namespace winner")
        } catch {
            XCTAssertEqual(error as? RoomNameError, .taken)
        }

        let rooms = try await store.loadAll()
        XCTAssertEqual(rooms.count, 2)
        XCTAssertEqual(Set(rooms.map(\.name)), Set(["Shared", "Beta"]))
        XCTAssertEqual(rooms.filter { $0.name == "Shared" }.count, 1)
        let outbox = try await store.metadataOutbox()
        XCTAssertEqual(outbox.count, alphaMembers.count)
        XCTAssertEqual(Set(outbox.map(\.route)), Set(alphaMembers.map(\.route)))
        XCTAssertTrue(outbox.allSatisfy {
            $0.kind == .rename && $0.oldName == "Alpha" && $0.newName == "Shared"
        })
        try await store.deleteAll()
    }

    func testConcurrentCreateAndRenameSerializeNameCheckThroughStoreAndOutboxCommit() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-name-create-race-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        runtime.metadataMutationOperation = { _ in throw RoomNameMetadataFailure.offline }
        let existingMembers = [
            RoomMember(route: GatewayBotRoute(gatewayID: "existing", profile: "one")),
            RoomMember(route: GatewayBotRoute(gatewayID: "existing", profile: "two")),
        ]
        let createdMembers = [
            RoomMember(route: GatewayBotRoute(gatewayID: "created", profile: "one")),
            RoomMember(route: GatewayBotRoute(gatewayID: "created", profile: "two")),
        ]
        let existing = RoomRecord(name: "Existing", members: existingMembers)
        try await store.upsert(existing)
        runtime.rooms = [existing]

        let probe = RoomNameCommitProbe()
        runtime.roomNameCommitBarrier = { await probe.pauseFirstCommit() }
        let model = AppModel()
        let winner = Task { @MainActor in
            try await model.createRoom(name: "Shared", members: createdMembers)
        }
        await probe.waitUntilFirstStarted()
        let loser = Task { @MainActor in
            try await model.renameRoom(existing.id, name: "Shared")
        }
        while RoomMutationGate.shared.queuedWaiterCount(
            for: RoomMutationGate.roomNameNamespaceKey) == 0 {
            await Task.yield()
        }
        await probe.resumeFirst()

        _ = try await winner.value
        do {
            try await loser.value
            XCTFail("the rename must observe the concurrently committed created name")
        } catch {
            XCTAssertEqual(error as? RoomNameError, .taken)
        }

        let rooms = try await store.loadAll()
        XCTAssertEqual(rooms.count, 2)
        XCTAssertEqual(Set(rooms.map(\.name)), Set(["Existing", "Shared"]))
        XCTAssertEqual(rooms.filter { $0.name == "Shared" }.count, 1)
        let outbox = try await store.metadataOutbox()
        XCTAssertEqual(outbox.count, createdMembers.count)
        XCTAssertEqual(Set(outbox.map(\.route)), Set(createdMembers.map(\.route)))
        XCTAssertTrue(outbox.allSatisfy {
            $0.kind == .add && $0.oldName == nil && $0.newName == "Shared"
        })
        try await store.deleteAll()
    }

    func testOfflineCreateAndDisbandKeepSourceQualifiedMetadataOutbox() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-metadata-outbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        RoomRuntime.shared.store = store
        let model = AppModel()
        let members = [
            RoomMember(route: GatewayBotRoute(gatewayID: "offline-a", profile: "default")),
            RoomMember(route: GatewayBotRoute(gatewayID: "offline-b", profile: "default")),
        ]
        let id = try await model.createRoom(name: "Fleet", members: members)
        let afterCreate = try await store.metadataOutbox()
        XCTAssertEqual(afterCreate.count, 2)
        XCTAssertEqual(Set(afterCreate.map(\.route)), Set(members.map(\.route)))
        XCTAssertTrue(afterCreate.allSatisfy { $0.kind == .add && $0.newName == "Fleet" })
        model.updateRoomComposerDraft("unfinished fleet note", roomID: id)
        await model.flushRoomComposerDraft(id)
        let storedDraft = try await store.composerDraft(roomID: id)
        XCTAssertEqual(storedDraft, "unfinished fleet note")

        try await model.disbandRoom(id)
        XCTAssertEqual(model.roomComposerDraft(id), "")
        let fresh = RoomStore(baseDirectory: base)
        let afterDisband = try await fresh.metadataOutbox()
        XCTAssertEqual(afterDisband.count, 4)
        XCTAssertEqual(afterDisband.suffix(2).map(\.kind), [.remove, .remove])
        XCTAssertTrue(afterDisband.suffix(2).allSatisfy { $0.oldName == "Fleet" })
        do {
            _ = try await fresh.composerDraft(roomID: id)
            XCTFail("disband must purge the immutable room draft")
        } catch {
            XCTAssertEqual(error as? RoomStoreError, .roomNotFound(id))
        }
        try await fresh.deleteAll()
    }

    func testLoadAppliesCachedProjectionTombstoneBeforeGatewayReconnect() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-cached-tombstone-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let room = RoomRecord(name: "Disbanded", members: [
            RoomMember(route: GatewayBotRoute(gatewayID: "offline", profile: "default")),
            RoomMember(route: GatewayBotRoute(gatewayID: "offline", profile: "reviewer"))
        ])
        try await store.upsert(room)
        let projectionKey = RoomProjectionEnvelope.idKey(room.id.description)
        _ = try await store.mergeRoomProjection(
            RoomProjectionEnvelope(),
            intent: RoomProjectionMergeIntent(
                deletedRooms: [projectionKey], writeRevision: 1)
        )

        let runtime = RoomRuntime.shared
        runtime.store = RoomStore(baseDirectory: base)
        runtime.rooms = [room]
        runtime.isLoaded = false

        await AppModel().loadRooms()

        XCTAssertTrue(runtime.rooms.isEmpty)
        let reloadedRoom = try await runtime.store.room(id: room.id)
        let reloadedProjection = try await runtime.store.roomProjection()
        XCTAssertNil(reloadedRoom)
        XCTAssertEqual(reloadedProjection.deleted[projectionKey], 1)
    }

    func testLegacyProjectionRenameAtomicallyPromotesIdentityBeforeSync() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-legacy-promotion-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let legacyKey = RoomProjectionEnvelope.legacyNameKey("Legacy")
        let hydrated = try await store.reconcileRoomProjection(
            RoomProjectionEnvelope(rooms: [
                legacyKey: RoomProjectionRoom(
                    name: "Legacy",
                    log: [RoomProjectionEntry(
                        id: "message-1",
                        from: RoomProjectionAuthor(kind: .user, name: "You"),
                        text: "hello", at: 1, thread: "thread-1")],
                    revision: 7,
                    members: [
                        RoomProjectionMember(name: "one", connectionID: "mini",
                                             sourceScoped: true),
                        RoomProjectionMember(name: "two", connectionID: "mini",
                                             sourceScoped: true),
                    ])
            ]),
            allowedGatewayIDs: ["mini"])
        let room = try XCTUnwrap(hydrated.rooms.first)
        let runtime = RoomRuntime.shared
        runtime.store = store
        runtime.rooms = hydrated.rooms

        try await AppModel().renameRoom(room.id, name: "Renamed")

        let fresh = RoomStore(baseDirectory: base)
        let reloadedValue = try await fresh.room(id: room.id)
        let reloaded = try XCTUnwrap(reloadedValue)
        let projection = try await fresh.roomProjection()
        let promotedKey = RoomProjectionEnvelope.idKey(room.id.description)
        XCTAssertEqual(reloaded.rawProjectionRoomKey, promotedKey)
        XCTAssertEqual(reloaded.rawProjectionRevision, 8)
        XCTAssertEqual(projection.rooms[promotedKey]?.name, "Renamed")
        XCTAssertEqual(projection.deleted[legacyKey], 8)
        XCTAssertNil(projection.rooms[legacyKey])
    }

    func testIDProjectionSettingsAtomicallyRemoveMemberAndAvatarBeforeSync() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-id-settings-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let key = "id:desktop-room"
        let original = RoomProjectionEnvelope(rooms: [
            key: RoomProjectionRoom(
                name: "Shared",
                roomID: "desktop-room",
                log: [RoomProjectionEntry(
                    id: "message-1",
                    from: RoomProjectionAuthor(kind: .user, name: "You"),
                    text: "hello", at: 1, thread: "thread-1")],
                revision: 7,
                members: ["one", "two", "three"].map {
                    RoomProjectionMember(name: $0, connectionID: "mini",
                                         sourceScoped: true)
                },
                image: "data:image/png;base64,aGVsbG8="),
        ])
        let hydrated = try await store.reconcileRoomProjection(
            original, allowedGatewayIDs: ["mini"])
        let room = try XCTUnwrap(hydrated.rooms.first)
        let runtime = RoomRuntime.shared
        runtime.store = store
        runtime.rooms = hydrated.rooms
        runtime.avatarData = hydrated.projectedImages

        try await AppModel().updateRoomSettings(
            room.id, name: "Renamed", members: Array(room.members.prefix(2)),
            removeAvatar: true)

        let fresh = RoomStore(baseDirectory: base)
        let reloadedValue = try await fresh.room(id: room.id)
        let reloaded = try XCTUnwrap(reloadedValue)
        let projection = try await fresh.roomProjection()
        XCTAssertEqual(reloaded.name, "Renamed")
        XCTAssertEqual(reloaded.members.map(\.route.profile), ["one", "two"])
        XCTAssertEqual(reloaded.rawProjectionRevision, 8)
        XCTAssertEqual(projection.rooms[key]?.revision, 8)
        XCTAssertEqual(projection.rooms[key]?.members.map(\.name), ["one", "two"])
        XCTAssertEqual(projection.rooms[key]?.image, "")
        XCTAssertNil(runtime.avatarData[room.id])

        let restarted = try await fresh.reconcileRoomProjection(
            original, allowedGatewayIDs: ["mini"])
        XCTAssertEqual(restarted.rooms.first?.name, "Renamed")
        XCTAssertEqual(restarted.rooms.first?.members.map(\.route.profile), ["one", "two"])
        XCTAssertEqual(restarted.roomProjection.rooms[key]?.image, "")
        XCTAssertTrue(restarted.projectedImages.isEmpty)
    }

    func testFrozenProjectionSettingsPreserveUnknownSeatsAndNeverQueueMetadata() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-frozen-settings-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let key = "id:desktop-frozen-room"
        let hydrated = try await store.reconcileRoomProjection(
            RoomProjectionEnvelope(rooms: [
                key: RoomProjectionRoom(
                    name: "Desktop room", roomID: "desktop-frozen-room",
                    log: [RoomProjectionEntry(
                        id: "message-1",
                        from: RoomProjectionAuthor(kind: .user, name: "You"),
                        text: "hello", at: 1, thread: "thread-1")],
                    revision: 3,
                    members: ["home", "mini", "lab"].map {
                        RoomProjectionMember(
                            name: "default", handle: $0,
                            connectionID: "desktop-\($0)",
                            connectionLabel: $0.capitalized,
                            sourceScoped: true)
                    })
            ]))
        let room = try XCTUnwrap(hydrated.rooms.first)
        XCTAssertTrue(room.members.allSatisfy(\.isFrozenProjection))
        let runtime = RoomRuntime.shared
        runtime.store = store
        runtime.rooms = hydrated.rooms

        var attemptedMembers = Array(room.members.prefix(2))
        attemptedMembers[0] = RoomMember(
            route: attemptedMembers[0].route, title: "Spoofed local seat")
        try await AppModel().updateRoomSettings(
            room.id, name: "Renamed on phone", members: attemptedMembers)

        let outbox = try await store.metadataOutbox()
        XCTAssertTrue(outbox.isEmpty)
        let updatedValue = try await store.room(id: room.id)
        let updated = try XCTUnwrap(updatedValue)
        let projection = try await store.roomProjection()
        XCTAssertEqual(updated.name, "Renamed on phone")
        XCTAssertEqual(updated.members.count, 3)
        XCTAssertTrue(updated.members.allSatisfy(\.isFrozenProjection))
        XCTAssertFalse(updated.members.contains { $0.title == "Spoofed local seat" })
        XCTAssertEqual(Set(updated.members.map(\.route.gatewayID)),
                       ["desktop-home", "desktop-mini", "desktop-lab"])
        XCTAssertEqual(projection.rooms[key]?.revision, 4)
        XCTAssertEqual(projection.rooms[key]?.members.map(\.connectionID),
                       ["desktop-home", "desktop-mini", "desktop-lab"])
    }

    func testLateMetadataCompletionCannotRemoveRenamedDestinationMutation() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-late-metadata-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = GatewayBotRoute(gatewayID: "offline", profile: "old")
        let destination = GatewayBotRoute(gatewayID: "offline", profile: "new")
        let sibling = GatewayBotRoute(gatewayID: "other", profile: "old")
        let room = RoomRecord(name: "Fleet", members: [
            RoomMember(route: source), RoomMember(route: sibling)
        ])
        let mutation = RoomMetadataMutation(route: source, kind: .rename,
                                            oldName: "Fleet", newName: "Fleet 2")
        let store = RoomStore(baseDirectory: base)
        try await store.upsert(room, metadataMutations: [mutation])
        let runtime = RoomRuntime.shared
        runtime.store = store
        runtime.rooms = [room]
        let probe = RoomMetadataProbe()
        runtime.metadataMutationOperation = { mutation in
            try await probe.execute(mutation)
        }
        let model = AppModel()
        let flush = Task { @MainActor in await model.flushRoomMetadataOutbox() }
        await probe.waitUntilStarted()

        let token = model.prepareRoomProfileLifecycle(source: source)
        try await model.commitRoomProfileRename(token, destination: destination)
        await probe.resume()
        await flush.value

        let outbox = try await store.metadataOutbox()
        XCTAssertEqual(outbox.count, 1)
        XCTAssertEqual(outbox.first?.route, destination)
        XCTAssertEqual(outbox.first?.newName, "Fleet 2")
        let migrated = try await store.room(id: room.id)
        XCTAssertEqual(migrated?.members.map(\.route), [destination, sibling])
    }

    func testSupersededWaitingAttemptCancelsWithoutSubmitting() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-stale-wait-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        let model = AppModel()
        let a = RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "one"))
        let b = RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "two"))
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: a.route, epoch: 1,
                                  promptText: "stale", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", state: .waiting)
        let room = RoomRecord(name: "Team", members: [a, b], threads: [thread],
                              attempts: [attempt], epoch: 2)
        try await store.upsert(room)
        let probe = RoomSubmitProbe()
        runtime.submitOperation = { _, session, _ in
            await probe.record(working: true)
            return RoomPromptSubmission(acceptance: .accepted,
                                        runtimeID: session.runtimeID,
                                        storedID: session.storedID, baseline: 0)
        }
        let snapshot = RoomMemberSessionSnapshot(runtimeID: "runtime", storedID: "stored",
                                                 messages: [], running: false)
        let client = GatewayClient(baseURL: URL(string: "https://example.invalid")!,
                                   credential: .sessionToken("test"))
        await model.submitWaitingRoomAttempt(roomID: room.id, attempt: attempt,
                                             session: snapshot, client: client)
        let loaded = try await store.room(id: room.id)
        XCTAssertEqual(loaded?.attempts.first?.state, .cancelled)
        XCTAssertNotNil(loaded?.attempts.first?.finishedAt)
        let calls = await probe.calls
        XCTAssertEqual(calls, 0)
        try await store.deleteAll()
    }

    func testDeliveryResolutionNeverClearsGenuineUserAttention() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-abandon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        RoomRuntime.shared.store = store
        let a = RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "one"))
        let b = RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "two"))
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: a.route, epoch: 1,
                                  promptText: "maybe sent", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", state: .uncertain)
        let room = RoomRecord(name: "Team", members: [a, b], threads: [thread],
                              attempts: [attempt], epoch: 1, needsUser: true)
        try await store.upsert(room)

        await AppModel().abandonRoomAttempt(roomID: room.id, attemptID: attempt.id)
        let loaded = try await store.room(id: room.id)
        XCTAssertEqual(loaded?.attempts.first?.state, .cancelled)
        XCTAssertNotNil(loaded?.attempts.first?.finishedAt)
        XCTAssertTrue(loaded?.needsUser ?? false)
        XCTAssertFalse(RoomDeliveryPolicy.hasUnresolvedDelivery(try XCTUnwrap(loaded)))

        // Reconciliation/terminal completion is the other delivery-resolution
        // path. It likewise leaves transcript attention under @user ownership.
        let accepted = RoomAttempt(threadID: thread.id, member: a.route, epoch: 1,
                                   promptText: "accepted", storedSessionID: "stored-2",
                                   runtimeSessionID: "runtime-2", state: .accepted)
        var withAccepted = try XCTUnwrap(loaded)
        withAccepted.attempts.append(accepted)
        try await store.upsert(withAccepted)
        await AppModel().finishRoomAttempt(
            roomID: room.id, attemptID: accepted.id, member: a,
            reply: "resolved without a new mention", delivered: true)
        let reconciledValue = try await store.room(id: room.id)
        let reconciled = try XCTUnwrap(reconciledValue)
        XCTAssertTrue(reconciled.needsUser)
        XCTAssertFalse(RoomDeliveryPolicy.hasUnresolvedDelivery(reconciled))
    }

    func testPendingPromptRegistryRetainsSameRequestAndClearsOnlyOnSuccessfulNoPendingResume() {
        let runtime = RoomRuntime.shared
        let route = GatewayBotRoute(gatewayID: "remote", profile: "planner")
        let roomID = RoomID()
        let attempt = RoomAttempt(threadID: RoomThreadID(), member: route, epoch: 4,
                                  promptText: "turn", storedSessionID: "stored",
                                  runtimeSessionID: "old", state: .accepted)
        let key = RoomPendingPromptKey(roomID: roomID, route: route)
        let first = RoomMemberSessionSnapshot(
            runtimeID: "runtime-1", storedID: "stored", messages: [], running: false,
            pendingClarify: ["request_id": "clarify-1", "question": "Pick a plan"])
        runtime.synchronizePendingPrompt(roomID: roomID, attempt: attempt, snapshot: first)
        let firstPrompt = try! XCTUnwrap(runtime.pendingPrompts[key])
        runtime.answeredPromptQuestions[key] = .init(prompt: firstPrompt,
                                                      answeredQuestionIDs: ["q1"])

        // Same request after reconnect updates the current runtime SID but
        // preserves live card state/progress.
        let sameRequest = RoomMemberSessionSnapshot(
            runtimeID: "runtime-2", storedID: "stored", messages: [], running: false,
            pendingClarify: ["request_id": "clarify-1", "question": "Pick a plan"])
        runtime.synchronizePendingPrompt(roomID: roomID, attempt: attempt, snapshot: sameRequest)
        XCTAssertEqual(runtime.pendingPrompts[key]?.runtimeSessionID, "runtime-2")
        XCTAssertEqual(runtime.answeredPromptQuestions[key]?.answeredQuestionIDs, ["q1"])

        // A new Hermes request on the same room/source replaces the card and
        // cannot inherit the old draft/progress.
        let replacement = RoomMemberSessionSnapshot(
            runtimeID: "runtime-3", storedID: "stored", messages: [], running: false,
            pendingClarify: ["request_id": "clarify-2", "question": "Pick a target"])
        runtime.synchronizePendingPrompt(roomID: roomID, attempt: attempt, snapshot: replacement)
        XCTAssertEqual(runtime.pendingPrompts[key]?.requestID, "clarify-2")
        XCTAssertEqual(runtime.answeredPromptQuestions[key]?.answeredQuestionIDs, [])
        XCTAssertEqual(runtime.answeredPromptQuestions[key]?.lockedAnswersByQuestionID, [:])

        runtime.synchronizePendingPrompt(
            roomID: roomID, attempt: attempt,
            snapshot: .init(runtimeID: "runtime-3", storedID: "stored", messages: [], running: false))
        XCTAssertNil(runtime.pendingPrompts[key])
    }

    func testApprovalRequiresPositiveResolutionBeforeCardRemovalOrTranscriptEcho() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-prompt-approval-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        let route = GatewayBotRoute(gatewayID: "remote", profile: "ops")
        let peer = RoomMember(route: GatewayBotRoute(gatewayID: "home", profile: "peer"))
        let member = RoomMember(route: route)
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: route, epoch: 1,
                                  promptText: "turn", storedSessionID: "stored",
                                  runtimeSessionID: "durable-old", state: .accepted)
        let room = RoomRecord(name: "Approvals", members: [member, peer], threads: [thread],
                              attempts: [attempt], epoch: 1)
        try await store.upsert(room); runtime.rooms = [room]
        let snapshot = RoomMemberSessionSnapshot(
            runtimeID: "runtime-current", storedID: "stored", messages: [], running: false,
            pendingApproval: ApprovalRequest([
                "request_id": "approval-1", "description": "Run tool", "command": "deploy",
                "choices": ["once", "deny"],
            ], sessionID: "wrong-old-runtime"))
        runtime.synchronizePendingPrompt(roomID: room.id, attempt: attempt, snapshot: snapshot)
        let prompt = try XCTUnwrap(runtime.pendingPrompts[RoomPendingPromptKey(roomID: room.id, route: route)])
        var sent: [RoomPendingPromptResponse] = []
        runtime.pendingPromptResponseOperation = { response in
            sent.append(response)
            return ["resolved": 0]
        }

        do {
            try await AppModel().respondToRoomPendingPrompt(prompt, answers: [.approval(.once)])
            XCTFail("zero resolved approvals must not remove the card")
        } catch {
            XCTAssertEqual(error as? RoomPendingPromptRuntimeError, .unresolvedApproval)
        }
        XCTAssertEqual(sent.first?.route, route)
        XCTAssertEqual(sent.first?.params["session_id"]?.stringValue, "runtime-current")
        XCTAssertEqual(sent.first?.params["request_id"]?.stringValue, "approval-1")
        XCTAssertNotNil(runtime.pendingPrompts[prompt.key])
        let approvalRoom = try await store.room(id: room.id)
        XCTAssertTrue(approvalRoom?.entries.isEmpty ?? false)

        runtime.pendingPromptResponseOperation = { response in
            sent.append(response)
            return ["resolved": 1]
        }
        try await AppModel().respondToRoomPendingPrompt(prompt, answers: [.approval(.once)])
        XCTAssertNil(runtime.pendingPrompts[prompt.key])
    }

    func testSameRequestIDReplacementCannotInheritOrBeRemovedByOldResponse() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-prompt-replacement-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        let route = GatewayBotRoute(gatewayID: "remote", profile: "ops")
        let member = RoomMember(route: route)
        let peer = RoomMember(route: GatewayBotRoute(gatewayID: "home", profile: "peer"))
        let firstThread = RoomThread()
        let firstAttempt = RoomAttempt(
            threadID: firstThread.id, member: route, epoch: 1,
            promptText: "first", storedSessionID: "stored",
            runtimeSessionID: "runtime-1", state: .accepted)
        let room = RoomRecord(name: "Replacement", members: [member, peer],
                              threads: [firstThread], attempts: [firstAttempt], epoch: 1)
        try await store.upsert(room)
        runtime.rooms = [room]
        let requestID = "reused-request"
        runtime.synchronizePendingPrompt(roomID: room.id, attempt: firstAttempt, snapshot: .init(
            runtimeID: "runtime-1", storedID: "stored", messages: [], running: false,
            pendingApproval: ApprovalRequest([
                "request_id": .string(requestID), "description": "First",
                "choices": ["once", "deny"],
            ], sessionID: "runtime-1")))
        let key = RoomPendingPromptKey(roomID: room.id, route: route)
        let firstPrompt = try XCTUnwrap(runtime.pendingPrompts[key])

        var responseStarted = false
        var releaseResponse: CheckedContinuation<Void, Never>?
        runtime.pendingPromptResponseOperation = { _ in
            responseStarted = true
            await withCheckedContinuation { releaseResponse = $0 }
            return ["resolved": 1]
        }
        let response = Task { @MainActor in
            do {
                try await AppModel().respondToRoomPendingPrompt(
                    firstPrompt, answers: [.approval(.once)])
                return nil as RoomPendingPromptRuntimeError?
            } catch {
                return error as? RoomPendingPromptRuntimeError
            }
        }
        while !responseStarted { await Task.yield() }

        let replacementThread = RoomThreadID()
        let replacementAttempt = RoomAttempt(
            threadID: replacementThread, member: route, epoch: 2,
            promptText: "replacement", storedSessionID: "stored",
            runtimeSessionID: "runtime-2", state: .accepted)
        runtime.synchronizePendingPrompt(roomID: room.id, attempt: replacementAttempt,
                                         snapshot: .init(
            runtimeID: "runtime-2", storedID: "stored", messages: [], running: false,
            pendingApproval: ApprovalRequest([
                "request_id": .string(requestID), "description": "Replacement",
                "choices": ["once", "deny"],
            ], sessionID: "runtime-2")))
        releaseResponse?.resume()

        let responseError = await response.value
        XCTAssertEqual(responseError, .stale)
        let retained = try XCTUnwrap(runtime.pendingPrompts[key])
        XCTAssertEqual(retained.attemptID, replacementAttempt.id)
        XCTAssertEqual(retained.threadID, replacementThread)
        XCTAssertEqual(retained.epoch, 2)
        XCTAssertEqual(runtime.answeredPromptQuestions[key]?.attemptID, replacementAttempt.id)
        XCTAssertTrue(runtime.answeredPromptQuestions[key]?.answeredQuestionIDs.isEmpty ?? false)
    }

    func testSameProducerReusedRequestWithDifferentPayloadResetsProgressAndSurvivesOldResponse() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-prompt-fingerprint-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        let route = GatewayBotRoute(gatewayID: "remote", profile: "planner")
        let member = RoomMember(route: route)
        let peer = RoomMember(route: GatewayBotRoute(gatewayID: "home", profile: "peer"))
        let thread = RoomThread()
        let attempt = RoomAttempt(
            threadID: thread.id, member: route, epoch: 7,
            promptText: "turn", storedSessionID: "stored",
            runtimeSessionID: "runtime-1", state: .accepted)
        let room = RoomRecord(name: "Fingerprint", members: [member, peer],
                              threads: [thread], attempts: [attempt], epoch: 7)
        try await store.upsert(room)
        runtime.rooms = [room]
        let requestID = "reused-request"
        runtime.synchronizePendingPrompt(roomID: room.id, attempt: attempt, snapshot: .init(
            runtimeID: "runtime-1", storedID: "stored", messages: [], running: false,
            pendingClarify: .object([
                "request_id": .string(requestID),
                "questions": .array([.object([
                    "id": .string("q1"), "question": .string("First target"),
                    "choices": .array([.string("one"), .string("two")]),
                ])]),
            ])))
        let key = RoomPendingPromptKey(roomID: room.id, route: route)
        let firstPrompt = try XCTUnwrap(runtime.pendingPrompts[key])
        runtime.answeredPromptQuestions[key] = .init(
            prompt: firstPrompt, answeredQuestionIDs: ["old-confirmed"])

        var responseStarted = false
        var releaseResponse: CheckedContinuation<Void, Never>?
        runtime.pendingPromptResponseOperation = { _ in
            responseStarted = true
            await withCheckedContinuation { releaseResponse = $0 }
            return [:]
        }
        let response = Task { @MainActor in
            do {
                try await AppModel().respondToRoomPendingPrompt(
                    firstPrompt, answers: [.text("one", questionID: "q1")])
                return nil as RoomPendingPromptRuntimeError?
            } catch {
                return error as? RoomPendingPromptRuntimeError
            }
        }
        while !responseStarted { await Task.yield() }

        // Every durable producer field and the request id stay identical;
        // only the blocking prompt payload changes.
        runtime.synchronizePendingPrompt(roomID: room.id, attempt: attempt, snapshot: .init(
            runtimeID: "runtime-2", storedID: "stored", messages: [], running: false,
            pendingClarify: .object([
                "request_id": .string(requestID),
                "questions": .array([.object([
                    "id": .string("q2"), "question": .string("Replacement target"),
                    "choices": .array([.string("alpha"), .string("beta")]),
                    "multi_select": .bool(true),
                ])]),
            ])))
        let replacement = try XCTUnwrap(runtime.pendingPrompts[key])
        XCTAssertNotEqual(replacement.stableFingerprint, firstPrompt.stableFingerprint)
        XCTAssertEqual(replacement.attemptID, firstPrompt.attemptID)
        XCTAssertEqual(replacement.threadID, firstPrompt.threadID)
        XCTAssertEqual(replacement.epoch, firstPrompt.epoch)
        XCTAssertEqual(replacement.requestID, firstPrompt.requestID)
        XCTAssertTrue(runtime.answeredPromptQuestions[key]?.answeredQuestionIDs.isEmpty ?? false,
                      "replacement payload must not inherit the old prompt's progress")

        releaseResponse?.resume()
        let responseError = await response.value
        XCTAssertEqual(responseError, .stale)
        let retained = try XCTUnwrap(runtime.pendingPrompts[key])
        XCTAssertEqual(retained.stableFingerprint, replacement.stableFingerprint)
        XCTAssertEqual(retained.questions.first?.questionID, "q2")
        XCTAssertTrue(runtime.answeredPromptQuestions[key]?.answeredQuestionIDs.isEmpty ?? false,
                      "the old response must not mutate replacement progress")
    }

    func testStablePromptFingerprintNormalizesApprovalIdentity() {
        let key = RoomPendingPromptKey(
            roomID: RoomID(),
            route: GatewayBotRoute(gatewayID: "home", profile: "ops"))
        let attemptID = RoomAttemptID()
        let threadID = RoomThreadID()
        let original = RoomPendingPrompt(
            key: key, attemptID: attemptID, threadID: threadID, epoch: 1,
            runtimeSessionID: "runtime-a", requestID: "approval",
            kind: .approval, question: "  Deploy now?  ",
            command: "  git push  ", approvalChoices: [.once, .deny])
        let normalizedReplay = RoomPendingPrompt(
            key: key, attemptID: attemptID, threadID: threadID, epoch: 1,
            runtimeSessionID: "runtime-b", requestID: "approval",
            kind: .approval, question: "Deploy now?",
            command: "git push", approvalChoices: [.once, .deny])
        let changedCommand = RoomPendingPrompt(
            key: key, attemptID: attemptID, threadID: threadID, epoch: 1,
            runtimeSessionID: "runtime-b", requestID: "approval",
            kind: .approval, question: "Deploy now?",
            command: "git push --force", approvalChoices: [.once, .deny])
        let changedChoices = RoomPendingPrompt(
            key: key, attemptID: attemptID, threadID: threadID, epoch: 1,
            runtimeSessionID: "runtime-b", requestID: "approval",
            kind: .approval, question: "Deploy now?",
            command: "git push", approvalChoices: [.always, .deny])

        XCTAssertEqual(original.stableFingerprint, normalizedReplay.stableFingerprint)
        XCTAssertNotEqual(original.stableFingerprint, changedCommand.stableFingerprint)
        XCTAssertNotEqual(original.stableFingerprint, changedChoices.stableFingerprint)
    }

    func testBatchClarifySendsSequentiallyAndRetainsCardAfterMidBatchError() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-prompt-batch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        let route = GatewayBotRoute(gatewayID: "lab", profile: "planner")
        let peer = RoomMember(route: GatewayBotRoute(gatewayID: "home", profile: "peer"))
        let member = RoomMember(route: route)
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: route, epoch: 1,
                                  promptText: "turn", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", state: .accepted)
        let room = RoomRecord(name: "Batch", members: [member, peer], threads: [thread],
                              attempts: [attempt], epoch: 1)
        try await store.upsert(room); runtime.rooms = [room]
        runtime.synchronizePendingPrompt(roomID: room.id, attempt: attempt, snapshot: .init(
            runtimeID: "runtime", storedID: "stored", messages: [], running: false,
            pendingClarify: [
                "request_id": "batch-1",
                "questions": [
                    ["id": "q1", "question": "First"],
                    ["id": "q2", "question": "Second"],
                ],
            ]))
        let key = RoomPendingPromptKey(roomID: room.id, route: route)
        let prompt = try XCTUnwrap(runtime.pendingPrompts[key])
        let answers: [RoomPendingPromptAnswer] = [
            .text("one", questionID: "q1"), .text("two", questionID: "q2"),
        ]
        var sent: [RoomPendingPromptResponse] = []
        runtime.pendingPromptResponseOperation = { response in
            sent.append(response)
            if response.params["question_id"]?.stringValue == "q2" {
                throw GatewayError(code: -3, message: "temporary")
            }
            return [:]
        }
        do {
            try await AppModel().respondToRoomPendingPrompt(prompt, answers: answers)
            XCTFail("batch failure must keep the card")
        } catch {}
        XCTAssertEqual(sent.map { $0.params["question_id"]?.stringValue }, ["q1", "q2"])
        XCTAssertNotNil(runtime.pendingPrompts[key])
        XCTAssertEqual(runtime.answeredPromptQuestions[key]?.answeredQuestionIDs, ["q1"])
        XCTAssertEqual(runtime.pendingPrompts[key]?.lockedAnswersByQuestionID, ["q1": "one"])

        runtime.pendingPromptResponseOperation = { response in
            sent.append(response)
            return [:]
        }
        let refreshed = try XCTUnwrap(runtime.pendingPrompts[key])
        try await AppModel().respondToRoomPendingPrompt(
            refreshed, answers: [.text("two", questionID: "q2")])
        XCTAssertEqual(sent.map { $0.params["question_id"]?.stringValue }, ["q1", "q2", "q2"])
        XCTAssertNil(runtime.pendingPrompts[key])
    }

    func testReplayedBatchLocksSurviveRelaunchMergeMonotonicallyAndDropMalformedAnswers() {
        let runtime = RoomRuntime.shared
        let route = GatewayBotRoute(gatewayID: "remote", profile: "planner")
        let roomID = RoomID()
        let attempt = RoomAttempt(threadID: RoomThreadID(), member: route, epoch: 1,
                                  promptText: "turn", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", state: .accepted)
        let key = RoomPendingPromptKey(roomID: roomID, route: route)
        let first = RoomMemberSessionSnapshot(
            runtimeID: "runtime", storedID: "stored", messages: [], running: false,
            pendingClarify: [
                "request_id": "locked-batch",
                "questions": [["id": "q1", "question": "First"],
                              ["id": "q2", "question": "Second"]],
                "answers": ["q1": "accepted first", "unknown": "ignore"],
            ])
        runtime.synchronizePendingPrompt(roomID: roomID, attempt: attempt, snapshot: first)
        XCTAssertEqual(runtime.pendingPrompts[key]?.lockedAnswersByQuestionID,
                       ["q1": "accepted first"])
        XCTAssertEqual(runtime.answeredPromptQuestions[key]?.answeredQuestionIDs, ["q1"])

        // Runtime-only state disappears on relaunch; the next successful
        // resume must rebuild the lock before a card can offer a response.
        runtime.pendingPrompts.removeAll(); runtime.answeredPromptQuestions.removeAll()
        runtime.synchronizePendingPrompt(roomID: roomID, attempt: attempt, snapshot: first)
        XCTAssertTrue(runtime.pendingPrompts[key]?.isQuestionLocked(
            runtime.pendingPrompts[key]!.questions[0]) ?? false)

        // A same-request replay that only contains a newer lock cannot unlock
        // q1 by omission. Both accepted answers remain read-only.
        let second = RoomMemberSessionSnapshot(
            runtimeID: "runtime-2", storedID: "stored", messages: [], running: false,
            pendingClarify: [
                "request_id": "locked-batch",
                "questions": [["id": "q1", "question": "First"],
                              ["id": "q2", "question": "Second"]],
                "answers": ["q2": "accepted second"],
            ])
        runtime.synchronizePendingPrompt(roomID: roomID, attempt: attempt, snapshot: second)
        XCTAssertEqual(runtime.pendingPrompts[key]?.lockedAnswersByQuestionID,
                       ["q1": "accepted first", "q2": "accepted second"])

        let malformed = RoomMemberSessionSnapshot(
            runtimeID: "runtime-3", storedID: "stored", messages: [], running: false,
            pendingClarify: [
                "request_id": "malformed-locks",
                "questions": [["id": "q1", "question": "First"],
                              ["id": "q2", "question": "Second"]],
                "answers": ["unknown": "ignore", "q1": ["not", "a", "string"]],
            ])
        runtime.synchronizePendingPrompt(roomID: roomID, attempt: attempt, snapshot: malformed)
        XCTAssertEqual(runtime.pendingPrompts[key]?.lockedAnswersByQuestionID, [:])
        XCTAssertEqual(runtime.answeredPromptQuestions[key]?.answeredQuestionIDs, [])
    }

    func testReplayLockedBatchOnlySendsRemainingQuestion() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-prompt-replay-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        let route = GatewayBotRoute(gatewayID: "remote", profile: "planner")
        let member = RoomMember(route: route)
        let peer = RoomMember(route: GatewayBotRoute(gatewayID: "home", profile: "peer"))
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: route, epoch: 1,
                                  promptText: "turn", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", state: .accepted)
        let room = RoomRecord(name: "Replay lock", members: [member, peer], threads: [thread],
                              attempts: [attempt], epoch: 1)
        try await store.upsert(room); runtime.rooms = [room]
        runtime.synchronizePendingPrompt(roomID: room.id, attempt: attempt, snapshot: .init(
            runtimeID: "runtime", storedID: "stored", messages: [], running: false,
            pendingClarify: [
                "request_id": "replay-lock",
                "questions": [["id": "q1", "question": "Accepted"],
                              ["id": "q2", "question": "Remaining"]],
                "answers": ["q1": "already accepted"],
            ]))
        let key = RoomPendingPromptKey(roomID: room.id, route: route)
        let prompt = try XCTUnwrap(runtime.pendingPrompts[key])
        var sent: [RoomPendingPromptResponse] = []
        runtime.pendingPromptResponseOperation = { response in
            sent.append(response)
            return [:]
        }

        do {
            try await AppModel().respondToRoomPendingPrompt(prompt, answers: [
                .text("overwrite", questionID: "q1"), .text("new", questionID: "q2"),
            ])
            XCTFail("locked q1 must not be accepted as a resend candidate")
        } catch let error as RoomPendingPromptRuntimeError {
            XCTAssertEqual(error, .malformedAnswer)
        }
        XCTAssertTrue(sent.isEmpty)

        try await AppModel().respondToRoomPendingPrompt(
            prompt, answers: [.text("new", questionID: "q2")])
        XCTAssertEqual(sent.map { $0.params["question_id"]?.stringValue }, ["q2"])
        XCTAssertNil(runtime.pendingPrompts[key])
    }

    func testBlockedNonRunningPromptTimesOutWithoutPassingAndHarvestCanRemirrorIt() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-prompt-timeout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        runtime.pollInterval = .milliseconds(1)
        runtime.baseTurnTimeout = 0.008
        runtime.hardTurnTimeout = 0.025
        let route = GatewayBotRoute(gatewayID: "remote", profile: "research")
        let member = RoomMember(route: route)
        let peer = RoomMember(route: GatewayBotRoute(gatewayID: "home", profile: "peer"))
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: route, epoch: 1,
                                  promptText: "turn", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", state: .accepted)
        let room = RoomRecord(name: "Blocked", members: [member, peer], threads: [thread],
                              attempts: [attempt], epoch: 1)
        try await store.upsert(room); runtime.rooms = [room]
        let blocked = RoomMemberSessionSnapshot(
            runtimeID: "runtime", storedID: "stored", messages: [], running: false,
            pendingClarify: ["request_id": "clarify-blocked", "question": "Continue?"])
        runtime.sessionReadOperation = { _ in blocked }

        await AppModel().waitForRoomReply(roomID: room.id, attemptID: attempt.id)
        let loadedTimedOut = try await store.room(id: room.id)
        let timedOut = try XCTUnwrap(loadedTimedOut)
        XCTAssertEqual(timedOut.attempts.first?.state, .timedOut)
        XCTAssertNil(timedOut.attempts.first?.finishedAt)
        XCTAssertTrue(timedOut.entries.isEmpty, "blocked non-running work must never pass/finish")
        XCTAssertTrue(runtime.pendingPrompts.isEmpty, "hard cap clears only transient card state")

        await AppModel().harvestRoomAttempts(roomID: room.id, epoch: timedOut.epoch)
        XCTAssertEqual(runtime.pendingPrompts.values.first?.attemptID, attempt.id,
                       "a later successful harvest can re-mirror the durable stranded turn")
    }

    func testWorkingAndUncertainPromptsRequireExactAttemptMarker() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-prompt-ownership-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        let a = RoomMember(route: GatewayBotRoute(gatewayID: "home", profile: "working"))
        let b = RoomMember(route: GatewayBotRoute(gatewayID: "lab", profile: "uncertain"))
        let thread = RoomThread()
        let working = RoomAttempt(threadID: thread.id, member: a.route, epoch: 1,
                                  promptText: "working turn", storedSessionID: "stored-a",
                                  runtimeSessionID: "runtime-a", state: .working)
        let uncertain = RoomAttempt(threadID: thread.id, member: b.route, epoch: 1,
                                    promptText: "uncertain turn", storedSessionID: "stored-b",
                                    runtimeSessionID: "runtime-b", state: .uncertain)
        let room = RoomRecord(name: "Ownership", members: [a, b], threads: [thread],
                              attempts: [working, uncertain], epoch: 1)
        try await store.upsert(room)
        runtime.rooms = [room]
        var includeMarkers = false
        runtime.sessionReadOperation = { attempt in
            let messages: [JSONValue] = includeMarkers ? [
                .object(["role": .string("user"),
                         "content": .string(attempt.promptAnchor + "\n" + attempt.promptText)]),
            ] : []
            return RoomMemberSessionSnapshot(
                runtimeID: attempt.runtimeSessionID, storedID: attempt.storedSessionID,
                messages: messages, running: false,
                pendingClarify: ["request_id": .string("clarify-\(attempt.member.profile)"),
                                 "question": .string("Continue?")])
        }

        await AppModel().harvestRoomAttempts(roomID: room.id, epoch: room.epoch)
        XCTAssertTrue(runtime.pendingPrompts.isEmpty,
                      "an unrelated hidden-session prompt cannot borrow a pending attempt")

        includeMarkers = true
        await AppModel().harvestRoomAttempts(roomID: room.id, epoch: room.epoch)
        XCTAssertEqual(Set(runtime.pendingPrompts.values.map(\.attemptID)),
                       Set([working.id, uncertain.id]))
    }

    func testPostSettleHarvestDeliversLateReplyAndStopsWhenResolved() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-post-settle-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        runtime.postSettleHarvestInterval = .milliseconds(1)
        runtime.postSettleHarvestLimit = 8
        let a = RoomMember(route: GatewayBotRoute(gatewayID: "home", profile: "late"))
        let b = RoomMember(route: GatewayBotRoute(gatewayID: "lab", profile: "peer"))
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: a.route, epoch: 1,
                                  promptText: "late turn", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", state: .accepted)
        let room = RoomRecord(name: "Late", members: [a, b], threads: [thread],
                              attempts: [attempt],
                              drives: [RoomDriveState(threadID: thread.id, epoch: 1)],
                              epoch: 1)
        try await store.upsert(room)
        runtime.rooms = [room]
        runtime.sessionReadOperation = { attempt in
            RoomMemberSessionSnapshot(
                runtimeID: attempt.runtimeSessionID, storedID: attempt.storedSessionID,
                messages: [
                    .object(["role": .string("user"),
                             "content": .string(attempt.promptAnchor + "\n" + attempt.promptText)]),
                    .object(["role": .string("assistant"),
                             "content": .string("late reply")]),
                ], running: false)
        }

        let model = AppModel()
        await model.settleRoomDrive(roomID: room.id, epoch: 1, threadID: thread.id)
        await runtime.postSettleHarvestTasks[room.id]?.value
        let resolvedValue = try await store.room(id: room.id)
        let resolved = try XCTUnwrap(resolvedValue)
        XCTAssertEqual(resolved.attempts.first?.state, .delivered)
        XCTAssertEqual(resolved.entries.last?.text, "late reply")
        XCTAssertNil(runtime.postSettleHarvestTasks[room.id])
    }

    func testPostSettleHarvestIsBoundedAndNewDriveCancelsIt() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-post-settle-bound-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        runtime.postSettleHarvestInterval = .milliseconds(1)
        runtime.postSettleHarvestLimit = 2
        let a = RoomMember(route: GatewayBotRoute(gatewayID: "home", profile: "running"))
        let b = RoomMember(route: GatewayBotRoute(gatewayID: "lab", profile: "peer"))
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: a.route, epoch: 1,
                                  promptText: "still running", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", state: .accepted)
        let room = RoomRecord(name: "Bounded", members: [a, b], threads: [thread],
                              attempts: [attempt], epoch: 1)
        try await store.upsert(room)
        runtime.rooms = [room]
        var reads = 0
        runtime.sessionReadOperation = { attempt in
            reads += 1
            return RoomMemberSessionSnapshot(
                runtimeID: attempt.runtimeSessionID, storedID: attempt.storedSessionID,
                messages: [.object(["role": .string("user"),
                    "content": .string(attempt.promptAnchor + "\n" + attempt.promptText)])],
                running: true)
        }
        let model = AppModel()
        model.schedulePostSettleRoomHarvest(roomID: room.id, epoch: 1)
        await runtime.postSettleHarvestTasks[room.id]?.value
        XCTAssertEqual(reads, 2)
        XCTAssertNil(runtime.postSettleHarvestTasks[room.id])

        runtime.postSettleHarvestInterval = .seconds(30)
        model.schedulePostSettleRoomHarvest(roomID: room.id, epoch: 1)
        let cancelled = runtime.postSettleHarvestTasks[room.id]
        model.scheduleRoomDrive(roomID: room.id)
        await cancelled?.value
        XCTAssertNil(runtime.postSettleHarvestTasks[room.id])
        await runtime.driveTasks[room.id]?.value
    }

    func testNewSendRevokesSuspendedLateHarvestBeforeItCanPublishIntoNextEpoch() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-harvest-send-race-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        runtime.postSettleHarvestInterval = .milliseconds(1)
        runtime.postSettleHarvestLimit = 8
        let member = RoomMember(route: GatewayBotRoute(gatewayID: "home", profile: "late"))
        let peer = RoomMember(route: GatewayBotRoute(gatewayID: "lab", profile: "peer"))
        let thread = RoomThread()
        let attempt = RoomAttempt(
            threadID: thread.id, member: member.route, epoch: 1,
            promptText: "old turn", storedSessionID: "stored",
            runtimeSessionID: "runtime", state: .accepted)
        let room = RoomRecord(name: "Race", members: [member, peer], threads: [thread],
                              attempts: [attempt], epoch: 1)
        try await store.upsert(room)
        runtime.rooms = [room]

        var readStarted = false
        var releaseRead: CheckedContinuation<Void, Never>?
        runtime.sessionReadOperation = { attempt in
            readStarted = true
            await withCheckedContinuation { releaseRead = $0 }
            return RoomMemberSessionSnapshot(
                runtimeID: attempt.runtimeSessionID, storedID: attempt.storedSessionID,
                messages: [
                    .object(["role": .string("user"),
                             "content": .string(attempt.promptAnchor + "\n" + attempt.promptText)]),
                    .object(["role": .string("assistant"),
                             "content": .string("late old reply")]),
                ], running: false)
        }
        // Keep the newly scheduled E+1 drive inert; this test isolates whether
        // the already-suspended E harvest can publish after send admission.
        runtime.driveOperation = { _, _ in }
        let model = AppModel()
        model.schedulePostSettleRoomHarvest(roomID: room.id, epoch: 1)
        let oldHarvest = runtime.postSettleHarvestTasks[room.id]
        while !readStarted { await Task.yield() }

        _ = try await model.sendRoomMessage(roomID: room.id, text: "new epoch message",
                                            threadID: thread.id)
        releaseRead?.resume()
        await oldHarvest?.value
        await runtime.driveTasks[room.id]?.value

        let loadedValue = try await store.room(id: room.id)
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(loaded.epoch, 2)
        XCTAssertEqual(loaded.entries.map(\.text), ["new epoch message"])
        XCTAssertEqual(loaded.attempts.first?.state, .accepted)
        XCTAssertNil(loaded.attempts.first?.finishedAt)
        XCTAssertNil(runtime.postSettleHarvestTasks[room.id])
    }

    func testPromptRouteRenameRetainsStableAttemptThenDisbandClearsIt() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-prompt-rename-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        let source = GatewayBotRoute(gatewayID: "remote", profile: "old")
        let destination = GatewayBotRoute(gatewayID: "remote", profile: "new")
        let member = RoomMember(route: source)
        let peer = RoomMember(route: GatewayBotRoute(gatewayID: "home", profile: "peer"))
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: source, epoch: 1,
                                  promptText: "turn", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", state: .accepted)
        let room = RoomRecord(name: "Rename", members: [member, peer], threads: [thread],
                              attempts: [attempt], epoch: 1)
        try await store.upsert(room); runtime.rooms = [room]
        runtime.synchronizePendingPrompt(roomID: room.id, attempt: attempt, snapshot: .init(
            runtimeID: "runtime", storedID: "stored", messages: [], running: false,
            pendingClarify: ["request_id": "rename-request", "question": "Continue?"]))
        let token = AppModel().prepareRoomProfileLifecycle(source: source)
        try await AppModel().commitRoomProfileRename(token, destination: destination)
        let migrated = runtime.pendingPrompts[RoomPendingPromptKey(roomID: room.id, route: destination)]
        XCTAssertEqual(migrated?.attemptID, attempt.id)
        XCTAssertEqual(migrated?.requestID, "rename-request")

        runtime.postSettleHarvestInterval = .seconds(30)
        AppModel().schedulePostSettleRoomHarvest(roomID: room.id, epoch: 1)
        try await AppModel().disbandRoom(room.id)
        XCTAssertTrue(runtime.pendingPrompts.isEmpty)
        XCTAssertNil(runtime.postSettleHarvestTasks[room.id])
    }

    func testRemovingMemberWithLivePromptFailsClosed() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-prompt-member-removal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let runtime = RoomRuntime.shared
        runtime.store = store
        let a = RoomMember(route: GatewayBotRoute(gatewayID: "home", profile: "a"))
        let b = RoomMember(route: GatewayBotRoute(gatewayID: "remote", profile: "b"))
        let c = RoomMember(route: GatewayBotRoute(gatewayID: "remote", profile: "c"))
        let room = RoomRecord(name: "Members", members: [a, b, c])
        try await store.upsert(room); runtime.rooms = [room]
        let prompt = RoomPendingPrompt(
            key: .init(roomID: room.id, route: b.route), attemptID: RoomAttemptID(),
            threadID: RoomThreadID(), epoch: room.epoch, runtimeSessionID: "runtime",
            requestID: "live", kind: .clarify, question: "Keep me?")
        runtime.pendingPrompts[prompt.key] = prompt

        do {
            try await AppModel().updateRoomSettings(room.id, name: room.name, members: [a, c])
            XCTFail("a live prompt must block member removal")
        } catch {
            XCTAssertEqual(error as? RoomSettingsError, .memberBusy)
        }
    }

    private func makeAttempt(prompt: String) -> RoomAttempt {
        RoomAttempt(threadID: RoomThreadID(),
                    member: GatewayBotRoute(gatewayID: "mini", profile: "research"),
                    epoch: 3, promptText: prompt,
                    storedSessionID: "stored", runtimeSessionID: "deadbeef")
    }

    private func message(role: String, text: String) -> JSONValue {
        .object(["role": .string(role), "content": .string(text)])
    }
}
#endif
