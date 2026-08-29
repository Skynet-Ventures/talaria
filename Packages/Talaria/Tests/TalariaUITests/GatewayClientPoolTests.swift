#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI

private actor ConnectorCounter {
    var calls = 0
    var failNext = false

    func record() throws {
        calls += 1
        if failNext {
            failNext = false
            throw URLError(.cannotConnectToHost)
        }
    }

    func setFailNext() { failNext = true }
}

private actor LifecycleAdmissionInstallGate {
    private let blockingCall: Int
    private var calls = 0
    private var blockingCallArrived = false
    private var releaseBlockingCall: CheckedContinuation<Void, Never>?

    init(blockingCall: Int = 2) {
        self.blockingCall = blockingCall
    }

    func install() async {
        calls += 1
        guard calls == blockingCall else { return }
        blockingCallArrived = true
        await withCheckedContinuation { releaseBlockingCall = $0 }
    }

    func blockedCallArrived() -> Bool { blockingCallArrived }
    func secondArrived() -> Bool { calls >= 2 }

    func release() {
        releaseBlockingCall?.resume()
        releaseBlockingCall = nil
    }
}

private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<1_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

final class GatewayClientPoolTests: XCTestCase {
    private let url = URL(string: "https://gateway.example")!
    private let credential = GatewayCredential.sessionToken("test-token")

    func testConnectedSecondaryPublishesEpochAuthorityBeforePoolReturnsIt() async throws {
        let connected = GatewayClient(baseURL: url, credential: credential)
        let pool = GatewayClientPool { _, _ in
            await connected.setForegroundReadinessForTesting(true)
            return connected
        }

        let snapshot = try await pool.connectWithGeneration(
            gatewayID: "secondary", baseURL: url, credential: credential)
        let epoch = await snapshot.client.eventAuthorityEpochForTesting()
        let ready = await snapshot.client.isCurrentReadyTransport(epoch: epoch)

        XCTAssertTrue(ready)
        await pool.disconnectAll()
    }

    func testConcurrentLookupsReuseOneClient() async throws {
        let counter = ConnectorCounter()
        let pool = GatewayClientPool { baseURL, credential in
            try await counter.record()
            return GatewayClient(baseURL: baseURL, credential: credential)
        }

        async let first = pool.connect(gatewayID: "one", baseURL: url, credential: credential)
        async let second = pool.connect(gatewayID: "one", baseURL: url, credential: credential)
        let (a, b) = try await (first, second)
        let calls = await counter.calls
        let connected = await pool.connectedGatewayIDs()

        XCTAssertEqual(ObjectIdentifier(a), ObjectIdentifier(b))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(connected, ["one"])
        await pool.disconnectAll()
    }

    func testFailedConnectionIsEvictedAndCanRetry() async throws {
        let counter = ConnectorCounter()
        await counter.setFailNext()
        let pool = GatewayClientPool { baseURL, credential in
            try await counter.record()
            return GatewayClient(baseURL: baseURL, credential: credential)
        }

        do {
            _ = try await pool.connect(gatewayID: "one", baseURL: url, credential: credential)
            XCTFail("first connection should fail")
        } catch {
            let failedClient = await pool.client(for: "one")
            XCTAssertNil(failedClient)
        }

        _ = try await pool.connect(gatewayID: "one", baseURL: url, credential: credential)
        let calls = await counter.calls
        let connectedClient = await pool.client(for: "one")
        XCTAssertEqual(calls, 2)
        XCTAssertNotNil(connectedClient)
        await pool.disconnectAll()
    }

    func testDifferentGatewaysNeverShareAClient() async throws {
        let pool = GatewayClientPool { baseURL, credential in
            GatewayClient(baseURL: baseURL, credential: credential)
        }
        let a = try await pool.connect(gatewayID: "one", baseURL: url, credential: credential)
        let b = try await pool.connect(gatewayID: "two", baseURL: url, credential: credential)
        let connected = await pool.connectedGatewayIDs()

        XCTAssertNotEqual(ObjectIdentifier(a), ObjectIdentifier(b))
        XCTAssertEqual(connected, ["one", "two"])
        await pool.disconnectAll()
    }

    func testCapturedDisconnectCannotRetireReplacementClient() async throws {
        let pool = GatewayClientPool { baseURL, credential in
            GatewayClient(baseURL: baseURL, credential: credential)
        }
        let old = GatewayClient(baseURL: url, credential: .sessionToken("old"))
        let replacement = GatewayClient(baseURL: url, credential: .sessionToken("new"))
        await pool.adopt(old, for: "one")
        let captured = try await pool.connectWithGeneration(
            gatewayID: "one", baseURL: url, credential: .sessionToken("old"))
        await pool.adopt(replacement, for: "one")

        let disconnected = await pool.disconnectIfCurrent(captured, for: "one")
        let current = await pool.client(for: "one")
        XCTAssertFalse(disconnected)
        XCTAssertEqual(ObjectIdentifier(current!), ObjectIdentifier(replacement))
        await pool.disconnect(gatewayID: "one")
    }

    func testAdoptAdmissionAwaitCannotOverwriteASecondOperationLease() async throws {
        let installGate = LifecycleAdmissionInstallGate()
        let old = GatewayClient(baseURL: url, credential: .sessionToken("old"))
        let replacement = GatewayClient(baseURL: url, credential: .sessionToken("new"))
        let pool = GatewayClientPool(
            connector: { _, _ in old },
            lifecycleAdmissionInstaller: { _, _ in await installGate.install() }
        )
        await pool.adopt(old, for: "one")
        let captured = try await pool.connectWithGeneration(
            gatewayID: "one", baseURL: url, credential: credential)

        let adoption = Task { await pool.adopt(replacement, for: "one") }
        let installerReached = await eventually { await installGate.secondArrived() }
        XCTAssertTrue(installerReached)

        // This is the exact actor-reentrancy window that used to sit after
        // adopt's lease check. The operation must own the old slot before the
        // replacement installer is allowed to return.
        let acquired = await pool.acquireLease(captured, for: "one")
        let operationLease = try XCTUnwrap(acquired)
        await installGate.release()
        let adoptionQueued = await eventually {
            await pool.queuedLeaseWaiterCount(for: "one") == 1
        }
        XCTAssertTrue(adoptionQueued)
        let oldStillCurrent = await pool.isCurrent(captured, for: "one")
        XCTAssertTrue(oldStillCurrent,
                      "adopt must re-enter behind the operation lease")

        await pool.release(operationLease)
        await adoption.value
        let current = await pool.client(for: "one")
        XCTAssertEqual(current.map(ObjectIdentifier.init), ObjectIdentifier(replacement))
        await pool.disconnectAll()
    }

    func testCoalescedConnectWaitsForAdmissionAndPublishedSlotBeforeReturning() async throws {
        let installGate = LifecycleAdmissionInstallGate(blockingCall: 1)
        let connected = GatewayClient(baseURL: url, credential: .sessionToken("connected"))
        let pool = GatewayClientPool(
            connector: { _, _ in connected },
            lifecycleAdmissionInstaller: { _, _ in await installGate.install() }
        )

        let first = Task {
            try await pool.connectWithGeneration(
                gatewayID: "one", baseURL: url, credential: credential)
        }
        let installerReached = await eventually { await installGate.blockedCallArrived() }
        XCTAssertTrue(installerReached, "the connector must already be finished")

        let second = Task {
            try await pool.connectWithGeneration(
                gatewayID: "one", baseURL: url, credential: credential)
        }
        let bothWaitingForPublication = await eventually {
            await pool.connectingPublicationWaiterCount(for: "one") == 2
        }
        XCTAssertTrue(bothWaitingForPublication)
        let unpublished = await pool.client(for: "one")
        XCTAssertNil(unpublished,
                     "the connected client must not escape while admission is still installing")

        await installGate.release()
        let firstSnapshot = try await first.value
        let secondSnapshot = try await second.value
        XCTAssertEqual(firstSnapshot.generation, secondSnapshot.generation)
        XCTAssertEqual(ObjectIdentifier(firstSnapshot.client),
                       ObjectIdentifier(secondSnapshot.client))
        let published = await pool.client(for: "one")
        XCTAssertEqual(published.map(ObjectIdentifier.init), ObjectIdentifier(connected))

        let acquired = await pool.acquireLease(secondSnapshot, for: "one")
        let lease = try XCTUnwrap(acquired)
        await pool.release(lease)
        await pool.disconnectAll()
    }

    func testCancelledCoalescedConnectCannotEscapeSharedPublishedClient() async throws {
        let installGate = LifecycleAdmissionInstallGate(blockingCall: 1)
        let connected = GatewayClient(baseURL: url, credential: .sessionToken("connected"))
        let pool = GatewayClientPool(
            connector: { _, _ in connected },
            lifecycleAdmissionInstaller: { _, _ in await installGate.install() }
        )
        let owner = Task {
            try await pool.connectWithGeneration(
                gatewayID: "one", baseURL: url, credential: credential)
        }
        let installerReached = await eventually { await installGate.blockedCallArrived() }
        XCTAssertTrue(installerReached)
        let cancelled = Task {
            try await pool.connectWithGeneration(
                gatewayID: "one", baseURL: url, credential: credential)
        }
        let bothWaiting = await eventually {
            await pool.connectingPublicationWaiterCount(for: "one") == 2
        }
        XCTAssertTrue(bothWaiting)
        cancelled.cancel()
        await installGate.release()

        let ownerSnapshot = try await owner.value
        do {
            _ = try await cancelled.value
            XCTFail("a cancelled coalesced waiter must not receive the published client")
        } catch is CancellationError {}
        let current = await pool.client(for: "one")
        XCTAssertEqual(current.map(ObjectIdentifier.init),
                       ObjectIdentifier(ownerSnapshot.client))
        await pool.disconnectAll()
    }

    func testReplacementDuringConnectAdmissionRejectsEveryCoalescedGenerationWaiter()
        async throws {
        let installGate = LifecycleAdmissionInstallGate(blockingCall: 1)
        let connecting = GatewayClient(baseURL: url, credential: .sessionToken("connecting"))
        let replacement = GatewayClient(baseURL: url, credential: .sessionToken("replacement"))
        let pool = GatewayClientPool(
            connector: { _, _ in connecting },
            lifecycleAdmissionInstaller: { _, _ in await installGate.install() }
        )
        let first = Task {
            try await pool.connectWithGeneration(
                gatewayID: "one", baseURL: url, credential: credential)
        }
        let installerReached = await eventually { await installGate.blockedCallArrived() }
        XCTAssertTrue(installerReached)
        let second = Task {
            try await pool.connectWithGeneration(
                gatewayID: "one", baseURL: url, credential: credential)
        }
        let bothWaiting = await eventually {
            await pool.connectingPublicationWaiterCount(for: "one") == 2
        }
        XCTAssertTrue(bothWaiting)

        let adoption = Task { await pool.adopt(replacement, for: "one") }
        let replacementPublished = await eventually {
            await pool.client(for: "one").map(ObjectIdentifier.init)
                == ObjectIdentifier(replacement)
        }
        XCTAssertTrue(replacementPublished)
        await installGate.release()
        await adoption.value
        for waiter in [first, second] {
            do {
                _ = try await waiter.value
                XCTFail("a replaced connecting generation must not escape")
            } catch is CancellationError {}
        }
        let current = await pool.client(for: "one")
        XCTAssertEqual(current.map(ObjectIdentifier.init), ObjectIdentifier(replacement))
        await pool.disconnectAll()
    }

    func testMixedOperationAdoptAndDisconnectWaitersUseFIFOBarrierHandoff() async throws {
        let old = GatewayClient(baseURL: url, credential: .sessionToken("old"))
        let replacement = GatewayClient(baseURL: url, credential: .sessionToken("new"))
        let pool = GatewayClientPool { _, _ in old }
        await pool.adopt(old, for: "one")
        let captured = try await pool.connectWithGeneration(
            gatewayID: "one", baseURL: url, credential: credential)
        let acquiredFirstLease = await pool.acquireLease(captured, for: "one")
        let firstLease = try XCTUnwrap(acquiredFirstLease)

        let secondOperation = Task { await pool.acquireLease(captured, for: "one") }
        let secondOperationQueued = await eventually {
            await pool.queuedLeaseWaiterCount(for: "one") == 1
        }
        XCTAssertTrue(secondOperationQueued)
        let adoption = Task { await pool.adopt(replacement, for: "one") }
        let adoptionQueued = await eventually {
            await pool.queuedLeaseWaiterCount(for: "one") == 2
        }
        XCTAssertTrue(adoptionQueued)
        let disconnect = Task { await pool.disconnect(gatewayID: "one") }
        let disconnectQueued = await eventually {
            await pool.queuedLeaseWaiterCount(for: "one") == 3
        }
        XCTAssertTrue(disconnectQueued)

        await pool.release(firstLease)
        let acquiredSecondLease = await secondOperation.value
        let secondLease = try XCTUnwrap(acquiredSecondLease)
        let oldStillCurrent = await pool.isCurrent(captured, for: "one")
        XCTAssertTrue(oldStillCurrent,
                      "the next operation owns G1 before replacement waiters run")
        let remainingWaiters = await pool.queuedLeaseWaiterCount(for: "one")
        XCTAssertEqual(remainingWaiters, 2)

        await pool.release(secondLease)
        await adoption.value
        await disconnect.value
        let finalClient = await pool.client(for: "one")
        XCTAssertNil(finalClient,
                     "adopt then disconnect must consume their FIFO turns")
    }

    func testCancelledBarrierWaiterCannotWedgeTheNextOperation() async throws {
        let old = GatewayClient(baseURL: url, credential: .sessionToken("old"))
        let cancelledReplacement = GatewayClient(
            baseURL: url, credential: .sessionToken("cancelled"))
        let pool = GatewayClientPool { _, _ in old }
        await pool.adopt(old, for: "one")
        let captured = try await pool.connectWithGeneration(
            gatewayID: "one", baseURL: url, credential: credential)
        let acquiredOwner = await pool.acquireLease(captured, for: "one")
        let owner = try XCTUnwrap(acquiredOwner)

        let cancelledAdoption = Task {
            await pool.adopt(cancelledReplacement, for: "one")
        }
        let cancelledAdoptionQueued = await eventually {
            await pool.queuedLeaseWaiterCount(for: "one") == 1
        }
        XCTAssertTrue(cancelledAdoptionQueued)
        let nextOperation = Task { await pool.acquireLease(captured, for: "one") }
        let nextOperationQueued = await eventually {
            await pool.queuedLeaseWaiterCount(for: "one") == 2
        }
        XCTAssertTrue(nextOperationQueued)

        cancelledAdoption.cancel()
        await cancelledAdoption.value
        let cancelledWaiterRemoved = await eventually {
            await pool.queuedLeaseWaiterCount(for: "one") == 1
        }
        XCTAssertTrue(cancelledWaiterRemoved)
        await pool.release(owner)
        let acquiredSuccessor = await nextOperation.value
        let successor = try XCTUnwrap(acquiredSuccessor)
        let oldStillCurrent = await pool.isCurrent(captured, for: "one")
        XCTAssertTrue(oldStillCurrent)
        await pool.release(successor)
        await pool.disconnectAll()
    }
}
#endif
