import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class SupervisedReconnectParityTests: XCTestCase {
    @MainActor
    private struct Fixture {
        let model: AppModel
        let registry: ConnectionRegistry
        let gateway: SavedGateway
        let baseURL: URL
        let credential: GatewayCredential
        let client: GatewayClient
    }

    @MainActor
    private func fixture(
        host: String = "reconnect.example",
        credential: GatewayCredential = .sessionToken("reconnect-test-token")
    ) throws -> Fixture {
        let registry = ConnectionRegistry.shared
        let base = try XCTUnwrap(URL(string: "https://\(UUID().uuidString).\(host)"))
        let gateway = try XCTUnwrap(registry.upsert(
            urlString: base.absoluteString, name: "Reconnect test"))
        registry.setCredentialForTesting(credential, for: gateway)
        let client = GatewayClient(baseURL: base, credential: credential)
        let model = AppModel()
        model.mode = .live
        model.client = client
        model.isOffline = true

        let runtime = LiveRuntime.shared
        runtime.reconnectTask?.cancel()
        runtime.reconnectTask = nil
        runtime.monitorTask?.cancel()
        runtime.monitorTask = nil
        runtime.baseURL = base
        runtime.gatewayID = gateway.id
        runtime.generation &+= 1

        let supervisor = ConnectionSupervisor.shared
        supervisor.resetTestingSeams()
        supervisor.diagnostics.removeValue(forKey: gateway.id)
        return Fixture(model: model, registry: registry, gateway: gateway,
                       baseURL: base, credential: credential, client: client)
    }

    @MainActor
    private func cleanup(_ fixture: Fixture) {
        let runtime = LiveRuntime.shared
        runtime.reconnectTask?.cancel()
        runtime.reconnectTask = nil
        runtime.monitorTask?.cancel()
        runtime.monitorTask = nil
        runtime.baseURL = nil
        runtime.gatewayID = nil
        runtime.generation &+= 1
        fixture.model.client = nil
        fixture.registry.setCredentialForTesting(nil, for: fixture.gateway)
        fixture.registry.remove(id: fixture.gateway.id)
        ConnectionSupervisor.shared.diagnostics.removeValue(forKey: fixture.gateway.id)
        ConnectionSupervisor.shared.resetTestingSeams()
        ConnectionSupervisor.shared.healthProbe = { gateway in
            await GatewayDiagnostics.probe(gateway)
        }
        ManagedCloudBootRuntime.shared.resetForTesting()
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<1_000 where !predicate() { await Task.yield() }
        XCTAssertTrue(predicate())
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
    func testUnlimitedFullJitterAndFortyFiveSecondExactSourceEscalation() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let supervisor = ConnectionSupervisor.shared
        var time: TimeInterval = 0
        var sleeps: [TimeInterval] = []
        var dials = 0
        supervisor.now = { time }
        supervisor.randomUnit = { 0.5 }
        supervisor.sleep = { delay in
            sleeps.append(delay)
            time = sleeps.count == 1 ? 46 : time + delay
            if sleeps.count == 9 { throw CancellationError() }
        }
        supervisor.dial = { _ in
            dials += 1
            throw URLError(.cannotConnectToHost)
        }

        fixture.model.scheduleSupervisedReconnect()
        let task = LiveRuntime.shared.reconnectTask
        await task?.value

        XCTAssertEqual(dials, 8, "the supervised policy has no attempt ceiling")
        XCTAssertEqual(sleeps, [0.15, 0.3, 0.6, 1.2, 2.4, 4.8, 7.5, 7.5, 7.5])
        XCTAssertEqual(fixture.model.postBootReconnectRecovery?.gatewayID,
                       fixture.gateway.id)
        XCTAssertEqual(fixture.model.postBootReconnectRecovery?.host,
                       fixture.baseURL.host?.lowercased())
        XCTAssertGreaterThanOrEqual(
            fixture.model.postBootReconnectRecovery?.elapsed ?? 0, 45)
        XCTAssertNil(LiveRuntime.shared.reconnectTask)
    }

    @MainActor
    func testManualReconnectResetsEpisodeAndCleanOpenClearsRecovery() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let supervisor = ConnectionSupervisor.shared
        var time: TimeInterval = 100
        supervisor.now = { time }
        let source = try XCTUnwrap(fixture.model.currentReconnectSourceForTesting)
        supervisor.episodeSource = source
        supervisor.episodeStartedAt = 0
        supervisor.episodeAttempt = 99
        supervisor.postBootRecovery = PostBootReconnectRecovery(
            gatewayID: fixture.gateway.id, baseURL: fixture.baseURL, elapsed: 100)
        var continuation: CheckedContinuation<Void, Never>?
        supervisor.dial = { _ in
            await withCheckedContinuation { continuation = $0 }
        }

        fixture.model.reconnectNow()
        XCTAssertEqual(supervisor.episodeAttempt, 0)
        XCTAssertNil(supervisor.postBootRecovery)
        await waitUntil { continuation != nil }
        time = 101
        continuation?.resume()
        await LiveRuntime.shared.reconnectTask?.value

        XCTAssertFalse(fixture.model.isOffline)
        XCTAssertNil(supervisor.episodeSource)
        XCTAssertNil(fixture.model.postBootReconnectRecovery)
    }

    @MainActor
    func testInboundTrafficFromExactCurrentClientClearsStaleOfflinePublication() throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }

        XCTAssertTrue(fixture.model.isOffline)
        fixture.model.noteCurrentPrimaryInboundActivity(from: fixture.client)

        XCTAssertFalse(fixture.model.isOffline)
        XCTAssertEqual(fixture.registry.health[fixture.gateway.id]?.state, .connected)
    }

    @MainActor
    func testInboundTrafficFromReplacedClientCannotClearPrimaryOfflinePublication() throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let replaced = GatewayClient(
            baseURL: fixture.baseURL, credential: fixture.credential)

        fixture.model.noteCurrentPrimaryInboundActivity(from: replaced)

        XCTAssertTrue(fixture.model.isOffline)
    }

    @MainActor
    func testForegroundHalfOpenPingFailureEntersReconnectBeforeHTTPProbe() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let supervisor = ConnectionSupervisor.shared
        await fixture.client.setForegroundReadinessForTesting(true)
        await fixture.client.setRPCExecutorForTesting { method, _, timeout in
            guard method == "gateway.ping" else {
                return .object(["profiles": .array([]), "jobs": .array([])])
            }
            XCTAssertEqual(method, "gateway.ping")
            XCTAssertEqual(timeout, 3)
            throw GatewayError(code: -5, message: "request timed out: gateway.ping")
        }
        supervisor.healthProbe = { _ in
            XCTFail("saved-gateway HTTP probes must not delay failed foreground ping recovery")
            return (.offline, GatewayDiagnostics())
        }
        var dial: CheckedContinuation<Void, Never>?
        supervisor.dial = { _ in
            await withCheckedContinuation { dial = $0 }
        }

        fixture.model.applicationDidBecomeActive()
        await waitUntil { dial != nil }

        XCTAssertTrue(fixture.model.isReconnecting)
        dial?.resume()
        await LiveRuntime.shared.reconnectTask?.value
    }

    @MainActor
    func testForegroundAlreadyDisconnectedEntersExactSourceReconnectImmediately() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let supervisor = ConnectionSupervisor.shared
        await fixture.client.setForegroundReadinessForTesting(false)
        await fixture.client.setRPCExecutorForTesting { method, _, _ in
            if method == "gateway.ping" {
                XCTFail("disconnected foreground link must not attempt ping")
            }
            return .object(["profiles": .array([]), "jobs": .array([])])
        }
        supervisor.healthProbe = { _ in
            XCTFail("HTTP probe must not precede reconnect for a disconnected current socket")
            return (.offline, GatewayDiagnostics())
        }
        var dial: CheckedContinuation<Void, Never>?
        supervisor.dial = { client in
            XCTAssertTrue(client === fixture.client)
            await withCheckedContinuation { dial = $0 }
        }
        fixture.model.applicationDidBecomeActive()
        await waitUntil { dial != nil }

        XCTAssertTrue(fixture.model.isReconnecting)
        dial?.resume()
        await LiveRuntime.shared.reconnectTask?.value
    }

    @MainActor
    func testForegroundTrafficFenceNeverReconnectsAroundLifecycleAuthority() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let supervisor = ConnectionSupervisor.shared
        await fixture.client.setForegroundReadinessForTesting(true)
        await fixture.client.setTrafficAdmission { nil }
        await fixture.client.setRPCExecutorForTesting { _, _, _ in
            XCTFail("traffic-fenced wake must not reach the socket")
            return .object(["ok": .bool(true)])
        }
        var dialCount = 0
        supervisor.dial = { _ in dialCount += 1 }

        fixture.model.applicationDidBecomeActive()
        // Let the foreground task cross the actor boundary and settle.
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(dialCount, 0)
        XCTAssertNil(LiveRuntime.shared.reconnectTask)
        XCTAssertFalse(fixture.model.isReconnecting)
    }

    @MainActor
    func testEverySuspendedDialAuthorityChangeIsStaleWithoutPublication() async throws {
        enum Mutation: CaseIterable { case base, gateway, client, generation, credential }

        for mutation in Mutation.allCases {
            let fixture = try fixture()
            let supervisor = ConnectionSupervisor.shared
            var continuation: CheckedContinuation<Void, Never>?
            supervisor.dial = { _ in
                await withCheckedContinuation { continuation = $0 }
            }
            let source = try XCTUnwrap(fixture.model.currentReconnectSourceForTesting)
            let task = Task { @MainActor in
                await fixture.model.attemptReconnectOutcome(expected: source)
            }
            await waitUntil { continuation != nil }

            switch mutation {
            case .base:
                LiveRuntime.shared.baseURL = URL(string: "https://new.example")!
            case .gateway:
                LiveRuntime.shared.gatewayID = "replacement-gateway"
            case .client:
                fixture.model.client = GatewayClient(
                    baseURL: fixture.baseURL, credential: fixture.credential)
            case .generation:
                LiveRuntime.shared.generation &+= 1
            case .credential:
                fixture.registry.setCredentialForTesting(
                    .sessionToken("replacement-token"), for: fixture.gateway)
            }
            continuation?.resume()
            let outcome = await task.value

            XCTAssertEqual(outcome, .stale, "mutation: \(mutation)")
            XCTAssertNil(supervisor.reauthGateway, "mutation: \(mutation)")
            XCTAssertNil(supervisor.diagnostics[fixture.gateway.id],
                         "mutation: \(mutation)")
            XCTAssertNil(fixture.registry.health[fixture.gateway.id],
                         "mutation: \(mutation)")
            cleanup(fixture)
        }
    }

    @MainActor
    func testSessionExpiryPublishesReauthOnlyForExactSource() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        ConnectionSupervisor.shared.dial = { _ in
            fixture.registry.setCredentialForTesting(nil, for: fixture.gateway)
            throw AuthError.sessionExpired
        }

        let outcome = await fixture.model.attemptReconnectOutcome()

        XCTAssertEqual(outcome, .reauth)
        XCTAssertEqual(ConnectionSupervisor.shared.reauthGateway, fixture.baseURL)
        XCTAssertEqual(
            ConnectionSupervisor.shared.diagnostics[fixture.gateway.id]?.lastError,
            "session expired")
    }

    @MainActor
    func testLateOldLoopCannotClearSuccessorTask() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let supervisor = ConnectionSupervisor.shared
        var oldSleep: CheckedContinuation<Void, Never>?
        supervisor.sleep = { _ in
            await withCheckedContinuation { oldSleep = $0 }
        }
        fixture.model.scheduleSupervisedReconnect()
        let oldTask = LiveRuntime.shared.reconnectTask
        await waitUntil { oldSleep != nil }

        let successorToken = UUID()
        var successorGate: CheckedContinuation<Void, Never>?
        let successor = Task { @MainActor in
            await withCheckedContinuation { successorGate = $0 }
        }
        supervisor.reconnectTaskToken = successorToken
        LiveRuntime.shared.reconnectTask = successor
        oldSleep?.resume()
        await oldTask?.value

        XCTAssertEqual(supervisor.reconnectTaskToken, successorToken)
        XCTAssertNotNil(LiveRuntime.shared.reconnectTask)
        successorGate?.resume()
        await successor.value
    }

    @MainActor
    func testExactSuccessfulDialAdoptsOnlyCapturedSource() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let originalGeneration = LiveRuntime.shared.generation
        ConnectionSupervisor.shared.dial = { _ in }

        let outcome = await fixture.model.attemptReconnectOutcome()

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(LiveRuntime.shared.generation, originalGeneration + 1)
        XCTAssertEqual(LiveRuntime.shared.gatewayID, fixture.gateway.id)
        XCTAssertTrue(fixture.model.client === fixture.client)
        XCTAssertFalse(fixture.model.isOffline)
        XCTAssertEqual(fixture.registry.health[fixture.gateway.id]?.state, .connected)
    }

    @MainActor
    func testOAuthRotationOwnedByCapturedClientRemainsExactAndAdopts() async throws {
        let original = GatewayCredential.oauth(TokenSet(
            accessToken: "old-access", refreshToken: "old-refresh",
            expiresAt: 1, provider: "nous", userID: "user-1"))
        let refreshed = GatewayCredential.oauth(TokenSet(
            accessToken: "new-access", refreshToken: "new-refresh",
            expiresAt: Date().timeIntervalSince1970 + 3_600,
            provider: "nous", userID: "user-1"))
        let fixture = try fixture(credential: original)
        defer { cleanup(fixture) }
        ConnectionSupervisor.shared.dial = { client in
            await client.replaceCredentialForTesting(refreshed)
            fixture.registry.setCredentialForTesting(refreshed, for: fixture.gateway)
        }

        let outcome = await fixture.model.attemptReconnectOutcome()

        XCTAssertEqual(outcome, .success)
        XCTAssertFalse(fixture.model.isOffline)
        XCTAssertEqual(LiveRuntime.shared.gatewayID, fixture.gateway.id)
    }

    @MainActor
    func testSwitchGatewayUsesBoundedManagedBootAndKeepsTerminalOutage() async throws {
        let fixture = try fixture(host: "agents.nousresearch.com")
        defer { cleanup(fixture) }
        // Make the target a switch rather than the currently active source.
        LiveRuntime.shared.baseURL = URL(string: "https://departing.example")!
        LiveRuntime.shared.gatewayID = "departing"
        fixture.model.client = GatewayClient(
            baseURL: URL(string: "https://departing.example")!,
            credential: .sessionToken("departing"))
        let boot = ManagedCloudBootRuntime.shared
        boot.resetForTesting()
        boot.randomUnit = { 0 }
        boot.sleep = { _ in }
        var calls = 0
        ConnectionSupervisor.shared.switchConnect = { _, _, _ in
            calls += 1
            throw GatewayHTTPError(statusCode: 503, detail: "still starting")
        }

        await fixture.model.switchGateway(to: fixture.gateway)

        XCTAssertEqual(calls, 6)
        XCTAssertEqual(fixture.model.managedCloudBootOutage?.gatewayID,
                       fixture.gateway.id)
        XCTAssertEqual(fixture.model.managedCloudBootOutage?.statusCode, 503)
        XCTAssertTrue(fixture.model.isOffline)
    }

    @MainActor
    func testSupersededSwitchCannotPublishBOfflineOverNewerCConnection() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let registry = fixture.registry
        let credential = fixture.credential
        let targetBURL = URL(string: "https://switch-b-\(UUID().uuidString).example")!
        let targetCURL = URL(string: "https://switch-c-\(UUID().uuidString).example")!
        let targetB = try XCTUnwrap(registry.upsert(
            urlString: targetBURL.absoluteString, credential: credential))
        let targetC = try XCTUnwrap(registry.upsert(
            urlString: targetCURL.absoluteString, credential: credential))
        defer {
            registry.setCredentialForTesting(nil, for: targetB)
            registry.setCredentialForTesting(nil, for: targetC)
            registry.remove(id: targetB.id)
            registry.remove(id: targetC.id)
        }

        let boot = ManagedCloudBootRuntime.shared
        boot.resetForTesting()
        let operations = connectionOperations()
        let supervisor = ConnectionSupervisor.shared
        var switchStarted = false
        var switchContinuation: CheckedContinuation<Void, Never>?
        supervisor.switchConnect = { _, _, _ in
            switchStarted = true
            await withCheckedContinuation { switchContinuation = $0 }
        }

        // Start A → B and suspend it in its managed boot operation.
        let staleSwitch = Task { @MainActor in
            await fixture.model.switchGateway(to: targetB)
        }
        await waitUntil { switchStarted && switchContinuation != nil }

        // A newer user-owned C connect begins its own managed boot episode.
        // That deliberately supersedes B, then adopts C as the primary link.
        var winningClient: GatewayClient?
        try await fixture.model.runManagedCloudBootEpisode(
            sourceURL: targetCURL, gatewayID: targetC.id
        ) {
            try await fixture.model.connectGateway(
                baseURL: targetCURL, credential: credential,
                connectionOperation: { client in winningClient = client },
                adoptionOperations: operations)
        }
        switchContinuation?.resume()
        await staleSwitch.value

        XCTAssertEqual(LiveRuntime.shared.baseURL, targetCURL)
        XCTAssertEqual(fixture.model.client.map(ObjectIdentifier.init),
                       winningClient.map(ObjectIdentifier.init))
        XCTAssertFalse(fixture.model.isOffline)
        XCTAssertEqual(registry.health[targetC.id]?.state, .connected)
        XCTAssertNil(registry.health[targetB.id],
                     "the superseded B attempt must not mark its row offline")
        XCTAssertNil(supervisor.diagnostics[targetB.id],
                     "the superseded B attempt must not publish a diagnostic")
        XCTAssertNil(fixture.model.managedCloudBootOutage)

        await fixture.model.disconnectGateway()
    }

    @MainActor
    func testRecoveryProjectionStripsHostileURLComponents() {
        let url = URL(string:
            "https://user:secret@Gateway.Example:8443/private?q=token#fragment")!
        let recovery = PostBootReconnectRecovery(
            gatewayID: "safe-id", baseURL: url, elapsed: 45)

        XCTAssertEqual(recovery.gatewayID, "safe-id")
        XCTAssertEqual(recovery.host, "gateway.example")
        XCTAssertEqual(recovery.sourceOrigin, "https://gateway.example:8443")
        XCTAssertFalse(String(describing: recovery).contains("secret"))
        XCTAssertFalse(String(describing: recovery).contains("private"))
        XCTAssertFalse(String(describing: recovery).contains("token"))
    }
}
