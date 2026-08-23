import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class LaunchRestoreSelectionTests: XCTestCase {
    private actor LaunchGate {
        private var entered = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }

        func hasEntered() -> Bool { entered }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    private struct Fixture {
        let model: AppModel
        let registry: ConnectionRegistry
        let first: SavedGateway
        let second: SavedGateway
        let previousDemoChoice: Any?
    }

    @MainActor
    private func fixture(firstCredential: Bool = true,
                         secondCredential: Bool = true) throws -> Fixture {
        let registry = ConnectionRegistry.shared
        let nonce = UUID().uuidString
        let first = try XCTUnwrap(registry.upsert(
            urlString: "https://launch-first-\(nonce).example", name: "First"))
        let second = try XCTUnwrap(registry.upsert(
            urlString: "https://launch-second-\(nonce).example", name: "Second"))
        if firstCredential {
            registry.setCredentialForTesting(.sessionToken("first-token"), for: first)
        }
        if secondCredential {
            registry.setCredentialForTesting(.sessionToken("second-token"), for: second)
        }

        let model = AppModel()
        model.showOnboarding = false
        model.launchSavedGatewaysOverrideForTesting = [first, second]
        let previousDemoChoice = UserDefaults.standard.object(forKey: AppModel.demoChoiceKey)
        UserDefaults.standard.removeObject(forKey: AppModel.demoChoiceKey)
        return Fixture(model: model, registry: registry, first: first, second: second,
                       previousDemoChoice: previousDemoChoice)
    }

    @MainActor
    private func tearDownFixture(_ fixture: Fixture) {
        fixture.model.launchConnectOverrideForTesting = nil
        fixture.model.launchSavedGatewaysOverrideForTesting = nil
        fixture.registry.setCredentialForTesting(nil, for: fixture.first)
        fixture.registry.setCredentialForTesting(nil, for: fixture.second)
        fixture.registry.remove(id: fixture.first.id)
        fixture.registry.remove(id: fixture.second.id)
        if let previous = fixture.previousDemoChoice {
            UserDefaults.standard.set(previous, forKey: AppModel.demoChoiceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppModel.demoChoiceKey)
        }
    }

    private func eventually(_ predicate: @escaping () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await predicate() { return true }
            await Task.yield()
        }
        return await predicate()
    }

    @MainActor
    private func connectionOperations() -> ConnectedGatewayAdoptionOperations {
        let pool = ConnectionRegistry.shared.clientPool
        return ConnectedGatewayAdoptionOperations(
            adopt: { client, gatewayID in
                try await pool.adoptWithGeneration(client, for: gatewayID)
            },
            refreshRoster: {},
            refreshRoutines: {},
            hideOwnedSessions: {},
            flushComposeQueue: {},
            reseedRoomProjection: { _ in }
        )
    }

    @MainActor
    func testFirstEligibleSuccessMakesExactlyOneAttemptAndIsIdempotent() async throws {
        let fixture = try fixture()
        defer { tearDownFixture(fixture) }
        var attemptedURLs: [URL] = []
        fixture.model.launchConnectOverrideForTesting = { base, _ in
            attemptedURLs.append(base)
            fixture.model.mode = .live
        }

        fixture.model.showOnboarding = true
        await fixture.model.restoreWorldAtLaunch()
        XCTAssertFalse(fixture.model.launchWorldRestoreStarted)
        XCTAssertFalse(fixture.model.launchWorldRestoreCompleted)
        XCTAssertTrue(attemptedURLs.isEmpty)

        fixture.model.showOnboarding = false
        await fixture.model.restoreWorldAtLaunch()
        await fixture.model.restoreWorldAtLaunch()

        XCTAssertEqual(attemptedURLs, [try XCTUnwrap(fixture.first.baseURL)])
        XCTAssertEqual(fixture.model.mode, .live)
        XCTAssertTrue(fixture.model.launchWorldRestoreStarted)
        XCTAssertTrue(fixture.model.launchWorldRestoreCompleted)
    }

    @MainActor
    func testFirstEligibleFailureStopsWithoutSecondOrDemoAndMarksExactOffline() async throws {
        let fixture = try fixture()
        defer { tearDownFixture(fixture) }
        UserDefaults.standard.set(true, forKey: AppModel.demoChoiceKey)
        var attemptedURLs: [URL] = []
        fixture.model.launchConnectOverrideForTesting = { base, _ in
            attemptedURLs.append(base)
            throw URLError(.cannotConnectToHost)
        }

        await fixture.model.restoreWorldAtLaunch()

        XCTAssertEqual(attemptedURLs, [try XCTUnwrap(fixture.first.baseURL)])
        XCTAssertEqual(fixture.registry.health[fixture.first.id]?.state, .offline)
        XCTAssertNil(fixture.registry.health[fixture.second.id],
                     "an unattempted source must not receive failure state")
        XCTAssertTrue(fixture.model.connections.contains(where: {
            $0.id == fixture.first.id && $0.state == .offline
        }))
        XCTAssertFalse(fixture.model.demoDataLoaded)
        XCTAssertTrue(fixture.model.bots.isEmpty)
        XCTAssertEqual(fixture.model.mode, .demo,
                       "honest empty/offline launch state is not canned demo data")
    }

    @MainActor
    func testMissingCredentialIsSkippedDuringSelectionButFailureIsNotFailover() async throws {
        let fixture = try fixture(firstCredential: false, secondCredential: true)
        defer { tearDownFixture(fixture) }
        var attemptedURLs: [URL] = []
        fixture.model.launchConnectOverrideForTesting = { base, credential in
            attemptedURLs.append(base)
            XCTAssertEqual(credential, .sessionToken("second-token"))
            fixture.model.mode = .live
        }

        await fixture.model.restoreWorldAtLaunch()

        XCTAssertEqual(attemptedURLs, [try XCTUnwrap(fixture.second.baseURL)])
        XCTAssertNil(fixture.registry.health[fixture.first.id])
    }

    @MainActor
    func testNoEligibleSavedCredentialKeepsExistingExplicitDemoFallback() async throws {
        let fixture = try fixture(firstCredential: false, secondCredential: false)
        defer { tearDownFixture(fixture) }
        UserDefaults.standard.set(true, forKey: AppModel.demoChoiceKey)
        var attempts = 0
        fixture.model.launchConnectOverrideForTesting = { _, _ in attempts += 1 }

        await fixture.model.restoreWorldAtLaunch()

        XCTAssertEqual(attempts, 0)
        XCTAssertTrue(fixture.model.demoDataLoaded)
        XCTAssertFalse(fixture.model.bots.isEmpty)
        XCTAssertTrue(fixture.model.launchWorldRestoreCompleted)
    }

    @MainActor
    func testConcurrentLaunchCallsShareTheInFlightGuard() async throws {
        let fixture = try fixture()
        defer { tearDownFixture(fixture) }
        let gate = LaunchGate()
        var attempts = 0
        fixture.model.launchConnectOverrideForTesting = { _, _ in
            attempts += 1
            await gate.wait()
            fixture.model.mode = .live
        }

        let first = Task { @MainActor in await fixture.model.restoreWorldAtLaunch() }
        let entered = await eventually { await gate.hasEntered() }
        XCTAssertTrue(entered)
        let second = Task { @MainActor in await fixture.model.restoreWorldAtLaunch() }
        await second.value
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(fixture.model.launchWorldRestoreCompleted,
                       "the second call must not complete the first call's launch gate")

        await gate.release()
        await first.value
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(fixture.model.launchWorldRestoreCompleted)
    }

    @MainActor
    func testSupersededLaunchRestoreCannotMarkSelectedSourceOffline() async throws {
        let fixture = try fixture()
        defer { tearDownFixture(fixture) }
        let firstURL = try XCTUnwrap(fixture.first.baseURL)
        let secondURL = try XCTUnwrap(fixture.second.baseURL)
        let operations = connectionOperations()
        let gate = LaunchGate()
        fixture.model.launchConnectOverrideForTesting = { base, credential in
            XCTAssertEqual(base, firstURL)
            try await fixture.model.connectGateway(
                baseURL: base, credential: credential,
                connectionOperation: { _ in await gate.wait() },
                adoptionOperations: operations)
        }

        let restore = Task { @MainActor in await fixture.model.restoreWorldAtLaunch() }
        let entered = await eventually { await gate.hasEntered() }
        XCTAssertTrue(entered)

        // A user connection wins while launch's selected source is suspended.
        var winningClient: GatewayClient?
        try await fixture.model.connectGateway(
            baseURL: secondURL, credential: .sessionToken("second-token"),
            connectionOperation: { client in winningClient = client },
            adoptionOperations: operations)
        await gate.release()
        await restore.value

        XCTAssertEqual(LiveRuntime.shared.baseURL, secondURL)
        XCTAssertEqual(fixture.model.client.map(ObjectIdentifier.init),
                       winningClient.map(ObjectIdentifier.init))
        XCTAssertFalse(fixture.model.isOffline)
        XCTAssertEqual(fixture.registry.health[fixture.second.id]?.state, .connected)
        XCTAssertNil(fixture.registry.health[fixture.first.id],
                     "a cancelled launch attempt must not mark its saved row offline")
        XCTAssertNil(fixture.model.managedCloudBootOutage)

        await fixture.model.disconnectGateway()
    }
}
