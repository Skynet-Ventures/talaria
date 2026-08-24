#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI

private actor ConnectionSuspensionGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
final class PrimaryConnectionAuthorityTests: XCTestCase {
    private let credential = GatewayCredential.sessionToken("connection-fence-token")

    private func url(_ label: String) -> URL {
        URL(string: "https://\(label)-\(UUID().uuidString).example")!
    }

    private func removeSavedRows(for urls: [URL]) {
        let registry = ConnectionRegistry.shared
        for url in urls {
            if let saved = registry.gateway(forURL: url) { registry.remove(id: saved.id) }
        }
    }

    private func operations(
        adopt: ((GatewayClient, String) async throws
            -> GatewayClientPool.ConnectionSnapshot)? = nil,
        roster: @escaping () async throws -> Void = {}
    ) -> ConnectedGatewayAdoptionOperations {
        let pool = ConnectionRegistry.shared.clientPool
        return ConnectedGatewayAdoptionOperations(
            adopt: adopt ?? { client, gatewayID in
                try await pool.adoptWithGeneration(client, for: gatewayID)
            },
            refreshRoster: roster,
            refreshRoutines: {},
            hideOwnedSessions: {},
            flushComposeQueue: {},
            reseedRoomProjection: { _ in }
        )
    }

    private func assertCancelled(_ task: Task<Void, Error>,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await task.value
            XCTFail("stale connection attempt must cancel", file: file, line: line)
        } catch is CancellationError {
            // Expected exact stale-attempt result.
        } catch {
            XCTFail("unexpected stale-attempt error: \(error)", file: file, line: line)
        }
    }

    private func waitUntil(_ predicate: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 where !predicate() { await Task.yield() }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    func testRetiredPrimaryTransportMessageStartCannotMutateMainOrChatPump() async throws {
        let model = AppModel()
        let baseURL = url("event-epoch")
        defer { removeSavedRows(for: [baseURL]) }
        var connectedClient: GatewayClient?

        try await model.connectGateway(
            baseURL: baseURL, credential: credential,
            connectionOperation: { client in
                connectedClient = client
                // The package seam models an installed, ready transport without
                // opening a real WebSocket in this consumer-boundary test.
                await client.setForegroundReadinessForTesting(true)
            },
            adoptionOperations: operations())
        let client = try XCTUnwrap(connectedClient)
        let botID = "epoch-worker"
        let sessionID = "epoch-runtime"
        model.bots = [Bot(id: botID, job: "", shape: .circle, hue: .violet)]
        let chat = model.chat(for: botID)
        chat.sessionID = sessionID
        LiveRuntime.shared.sessionToBot[sessionID] = botID

        let priorChatHandler = ChatRuntime.shared.routerHandler
        model.attachChatEventRouter()
        await waitUntil {
            ChatRuntime.shared.routedClient === client
                && ChatRuntime.shared.routerHandler != priorChatHandler
        }

        // Install a successor epoch while retaining an event that was received
        // by the prior transport. Readiness remains true, proving rejection is
        // caused by exact transport identity rather than an offline shortcut.
        let retiredEpoch = await client.advanceTransportEpochForTesting()
        await client.emitEventForTesting(GatewayEvent(
            type: "message.start", sessionID: sessionID, payload: [:]),
            eventAuthorityEpoch: retiredEpoch)
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(model.bots.first?.status, .idle)
        XCTAssertFalse(LiveRuntime.shared.workingBotIDs.contains(botID))
        XCTAssertFalse(chat.isTyping)
        XCTAssertFalse(chat.isRunning)

        // A delivery from the current ready transport still reaches both
        // independent consumers: AppModel's main pump owns roster working
        // state, while ChatRuntime owns the Stop/running state.
        let published = await client.publishCurrentTransportForEvents()
        XCTAssertTrue(published)
        let currentEpoch = await client.eventAuthorityEpochForTesting()
        await client.emitEventForTesting(GatewayEvent(
            type: "message.start", sessionID: sessionID, payload: [:]),
            eventAuthorityEpoch: currentEpoch)
        await waitUntil {
            model.bots.first?.status == .working
                && LiveRuntime.shared.workingBotIDs.contains(botID)
                && chat.isTyping
                && chat.isRunning
        }

        await model.disconnectGateway()
    }

    func testDisconnectDuringSuspendedConnectSuppressesEveryLatePublication() async throws {
        let model = AppModel()
        let baseURL = url("dial-disconnect")
        defer { removeSavedRows(for: [baseURL]) }
        let gate = ConnectionSuspensionGate()
        let task = Task { @MainActor in
            try await model.connectGateway(
                baseURL: baseURL, credential: credential,
                connectionOperation: { _ in await gate.suspend() },
                adoptionOperations: operations())
        }
        await gate.waitUntilEntered()

        await model.disconnectGateway()
        await gate.release()
        await assertCancelled(task)

        XCTAssertNil(model.client)
        XCTAssertNil(LiveRuntime.shared.baseURL)
        XCTAssertNil(LiveRuntime.shared.gatewayID)
        XCTAssertNil(LiveRuntime.shared.connectionAttemptToken)
        XCTAssertNotEqual(model.mode, .live)
    }

    func testOlderConnectCompletionCannotReplaceACompletedNewSource() async throws {
        let model = AppModel()
        let oldURL = url("dial-old")
        let newURL = url("dial-new")
        defer { removeSavedRows(for: [oldURL, newURL]) }
        let gate = ConnectionSuspensionGate()
        var replacementClient: GatewayClient?

        let oldTask = Task { @MainActor in
            try await model.connectGateway(
                baseURL: oldURL, credential: credential,
                connectionOperation: { _ in await gate.suspend() },
                adoptionOperations: operations())
        }
        await gate.waitUntilEntered()

        try await model.connectGateway(
            baseURL: newURL, credential: credential,
            connectionOperation: { client in
                replacementClient = client
                await client.setForegroundReadinessForTesting(true)
            },
            adoptionOperations: operations())
        let replacementID = try XCTUnwrap(LiveRuntime.shared.gatewayID)
        let replacement = try XCTUnwrap(replacementClient)

        await gate.release()
        await assertCancelled(oldTask)

        XCTAssertEqual(model.client.map(ObjectIdentifier.init), ObjectIdentifier(replacement))
        XCTAssertEqual(LiveRuntime.shared.baseURL, newURL)
        XCTAssertEqual(LiveRuntime.shared.gatewayID, replacementID)
        let pooledReplacement = await ConnectionRegistry.shared.clientPool.client(
            for: replacementID)
        XCTAssertEqual(pooledReplacement.map(ObjectIdentifier.init), ObjectIdentifier(replacement))
        await model.disconnectGateway()
    }

    func testStaleAdoptionIsCASRemovedAfterDisconnect() async throws {
        let model = AppModel()
        let baseURL = url("adoption-disconnect")
        defer { removeSavedRows(for: [baseURL]) }
        let gate = ConnectionSuspensionGate()
        var adoptedGatewayID: String?
        let pool = ConnectionRegistry.shared.clientPool
        let task = Task { @MainActor in
            try await model.connectGateway(
                baseURL: baseURL, credential: credential,
                connectionOperation: { client in
                    await client.setForegroundReadinessForTesting(true)
                },
                adoptionOperations: operations(adopt: { client, gatewayID in
                    let snapshot = try await pool.adoptWithGeneration(client, for: gatewayID)
                    adoptedGatewayID = gatewayID
                    await gate.suspend()
                    return snapshot
                }))
        }
        await gate.waitUntilEntered()
        let gatewayID = try XCTUnwrap(adoptedGatewayID)

        await model.disconnectGateway()
        await gate.release()
        await assertCancelled(task)

        let stalePooledClient = await pool.client(for: gatewayID)
        XCTAssertNil(stalePooledClient)
        XCTAssertNil(LiveRuntime.shared.gatewayID)
    }

    func testStaleRosterCompletionCannotFlushOrDisconnectReplacement() async throws {
        let model = AppModel()
        let oldURL = url("roster-old")
        let newURL = url("roster-new")
        defer { removeSavedRows(for: [oldURL, newURL]) }
        let gate = ConnectionSuspensionGate()
        var replacementClient: GatewayClient?
        var oldGatewayID: String?
        let oldTask = Task { @MainActor in
            try await model.connectGateway(
                baseURL: oldURL, credential: credential,
                connectionOperation: { client in
                    await client.setForegroundReadinessForTesting(true)
                },
                adoptionOperations: operations(roster: {
                    oldGatewayID = LiveRuntime.shared.gatewayID
                    await gate.suspend()
                }))
        }
        await gate.waitUntilEntered()

        try await model.connectGateway(
            baseURL: newURL, credential: credential,
            connectionOperation: { client in
                replacementClient = client
                await client.setForegroundReadinessForTesting(true)
            },
            adoptionOperations: operations())
        let replacementID = try XCTUnwrap(LiveRuntime.shared.gatewayID)
        let replacement = try XCTUnwrap(replacementClient)

        await gate.release()
        await assertCancelled(oldTask)

        XCTAssertNotEqual(oldGatewayID, replacementID)
        XCTAssertEqual(model.client.map(ObjectIdentifier.init), ObjectIdentifier(replacement))
        let pooledReplacement = await ConnectionRegistry.shared.clientPool.client(
            for: replacementID)
        XCTAssertEqual(pooledReplacement.map(ObjectIdentifier.init), ObjectIdentifier(replacement))
        await model.disconnectGateway()
    }

    func testSuspendedOldTeardownCannotBorrowNewAttemptGeneration() async throws {
        let model = AppModel()
        let oldURL = url("teardown-seed")
        let firstURL = url("teardown-first")
        let secondURL = url("teardown-second")
        defer { removeSavedRows(for: [oldURL, firstURL, secondURL]) }
        let registry = ConnectionRegistry.shared
        let saved = try XCTUnwrap(registry.upsert(
            urlString: oldURL.absoluteString, credential: credential))
        let oldClient = GatewayClient(baseURL: oldURL, credential: credential)
        let oldSnapshot = try await registry.clientPool.adoptWithGeneration(
            oldClient, for: saved.id)
        let acquiredLease = await registry.clientPool.acquireLease(oldSnapshot, for: saved.id)
        let lease = try XCTUnwrap(acquiredLease)
        model.client = oldClient
        LiveRuntime.shared.baseURL = oldURL
        LiveRuntime.shared.gatewayID = saved.id

        let first = Task { @MainActor in
            try await model.connectGateway(
                baseURL: firstURL, credential: credential,
                connectionOperation: { client in
                    await client.setForegroundReadinessForTesting(true)
                }, adoptionOperations: operations())
        }
        for _ in 0..<20 { await Task.yield() }
        var secondClient: GatewayClient?
        let second = Task { @MainActor in
            try await model.connectGateway(
                baseURL: secondURL, credential: credential,
                connectionOperation: { client in
                    secondClient = client
                    await client.setForegroundReadinessForTesting(true)
                },
                adoptionOperations: operations())
        }
        for _ in 0..<20 { await Task.yield() }
        await registry.clientPool.release(lease)

        await assertCancelled(first)
        try await second.value
        let winner = try XCTUnwrap(secondClient)
        let winnerID = try XCTUnwrap(LiveRuntime.shared.gatewayID)
        XCTAssertEqual(LiveRuntime.shared.baseURL, secondURL)
        XCTAssertEqual(model.client.map(ObjectIdentifier.init), ObjectIdentifier(winner))
        let pooledWinner = await registry.clientPool.client(for: winnerID)
        XCTAssertEqual(pooledWinner.map(ObjectIdentifier.init), ObjectIdentifier(winner))
        await model.disconnectGateway()
    }

    func testPoolCASCleanupCannotDisconnectLaterSameOrDifferentClientAdoption() async throws {
        let pool = GatewayClientPool()
        let gatewayID = "pool-cas-\(UUID().uuidString)"
        let first = GatewayClient(baseURL: url("pool-first"), credential: credential)
        let firstSnapshot = try await pool.adoptWithGeneration(first, for: gatewayID)
        let reusedSnapshot = try await pool.adoptWithGeneration(first, for: gatewayID)

        let removedFirst = await pool.disconnectIfCurrent(firstSnapshot, for: gatewayID)
        let reusedIsCurrent = await pool.isCurrent(reusedSnapshot, for: gatewayID)
        XCTAssertFalse(removedFirst)
        XCTAssertTrue(reusedIsCurrent)

        let replacement = GatewayClient(baseURL: url("pool-replacement"), credential: credential)
        let replacementSnapshot = try await pool.adoptWithGeneration(replacement, for: gatewayID)
        let removedReused = await pool.disconnectIfCurrent(reusedSnapshot, for: gatewayID)
        let replacementIsCurrent = await pool.isCurrent(replacementSnapshot, for: gatewayID)
        XCTAssertFalse(removedReused)
        XCTAssertTrue(replacementIsCurrent)
        await pool.disconnectAll()
    }

    func testDisconnectMonitorArmsOnlyAfterInitialAdoptionTransactionFinishes() async throws {
        let model = AppModel()
        let baseURL = url("monitor-order")
        defer { removeSavedRows(for: [baseURL]) }
        let gate = ConnectionSuspensionGate()
        LiveRuntime.shared.monitorTask?.cancel()
        LiveRuntime.shared.monitorTask = nil

        let task = Task { @MainActor in
            try await model.connectGateway(
                baseURL: baseURL, credential: credential,
                connectionOperation: { client in
                    await client.setForegroundReadinessForTesting(true)
                },
                adoptionOperations: operations(roster: { await gate.suspend() }))
        }
        await gate.waitUntilEntered()
        XCTAssertNil(LiveRuntime.shared.monitorTask)

        await gate.release()
        try await task.value
        XCTAssertNotNil(LiveRuntime.shared.monitorTask)
        await model.disconnectGateway()
    }
}
#endif
