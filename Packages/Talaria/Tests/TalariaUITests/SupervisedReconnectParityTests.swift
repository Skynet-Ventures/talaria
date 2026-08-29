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
    func testFailedReconnectLeavesPopulatedTranscriptAndRuntimeSid() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let botID = "worker"
        let chat = fixture.model.chat(for: botID)
        chat.sessionID = "live-sid"
        chat.storedSessionID = "durable-bot-chat"
        chat.messages = [
            ChatMessage(author: .user, text: "still on screen"),
            ChatMessage(author: .bot, text: "gateway still has this"),
        ]
        ConnectionSupervisor.shared.dial = { _ in
            throw URLError(.cannotConnectToHost)
        }

        let outcome = await fixture.model.attemptReconnectOutcome()

        XCTAssertEqual(outcome, .retryable)
        XCTAssertEqual(chat.sessionID, "live-sid")
        XCTAssertEqual(chat.storedSessionID, "durable-bot-chat")
        XCTAssertEqual(chat.messages.map(\.text),
                       ["still on screen", "gateway still has this"])
        XCTAssertTrue(fixture.model.isOffline)
    }

    @MainActor
    func testBackgroundWakeHardRedialsWithoutPinging() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let supervisor = ConnectionSupervisor.shared
        fixture.model.isOffline = false
        ConnectionRegistry.shared.noteState(.connected, forURL: fixture.baseURL)
        // Half-open sockets still report ready. The failed device build
        // trusted that and wrote gateway.ping; this wake must redial anyway.
        await fixture.client.setForegroundReadinessForTesting(true)
        await fixture.client.setRPCExecutorForTesting { method, _, _ in
            XCTAssertNotEqual(method, "gateway.ping",
                              "background wake must not write onto the parked socket")
            return .object(["profiles": .array([]), "sessions": .array([]), "jobs": .array([])])
        }

        var dialCount = 0
        supervisor.dial = { _ in
            dialCount += 1
        }

        fixture.model.applicationWillResignActive()
        XCTAssertTrue(supervisor.suspendedForBackground)
        fixture.model.applicationDidBecomeActive()
        fixture.model.applicationDidBecomeActive()
        await waitUntil { dialCount > 0 }
        await LiveRuntime.shared.reconnectTask?.value

        XCTAssertGreaterThanOrEqual(dialCount, 1)
        XCTAssertFalse(fixture.model.isOffline)
        XCTAssertFalse(supervisor.suspendedForBackground)
    }

    @MainActor
    func testForegroundAlreadyDisconnectedEntersExactSourceReconnectImmediately() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let supervisor = ConnectionSupervisor.shared
        await fixture.client.setForegroundReadinessForTesting(false)
        await fixture.client.setRPCExecutorForTesting { _, _, _ in
            XCTFail("a closed socket must not be pinged")
            return .object(["ok": .bool(true)])
        }

        var dialCount = 0
        supervisor.dial = { _ in
            dialCount += 1
            throw URLError(.cannotConnectToHost)
        }

        fixture.model.applicationDidBecomeActive()
        await waitUntil { dialCount > 0 }
        XCTAssertEqual(dialCount, 1)
        XCTAssertTrue(fixture.model.isOffline)
    }

    @MainActor
    func testForegroundWhileConnectedDoesNotRedial() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        fixture.model.isOffline = false
        ConnectionRegistry.shared.noteState(.connected, forURL: fixture.baseURL)
        await fixture.client.setForegroundReadinessForTesting(true)
        await fixture.client.setRPCExecutorForTesting { _, _, _ in
            return .object(["profiles": .array([]), "sessions": .array([])])
        }

        var dialCount = 0
        ConnectionSupervisor.shared.dial = { _ in
            dialCount += 1
        }

        fixture.model.applicationDidBecomeActive()
        await waitUntil {
            ConnectionSupervisor.shared.foregroundValidationTask == nil
        }
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(dialCount, 0)
        XCTAssertFalse(fixture.model.isOffline)
        XCTAssertEqual(ConnectionRegistry.shared.health[fixture.gateway.id]?.state, .connected)
    }

    @MainActor
    func testAlreadyActiveWhileOfflineAlwaysRedials() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let supervisor = ConnectionSupervisor.shared
        // Device 5497344: HTTP healthy, transport offline, wake said
        // already-active and skipped hard-redial.
        fixture.model.isOffline = true
        supervisor.suspendedForBackground = false
        await fixture.client.setForegroundReadinessForTesting(true)
        await fixture.client.setRPCExecutorForTesting { method, _, _ in
            XCTAssertNotEqual(method, "gateway.ping",
                              "already-active offline must redial, not ping")
            return .object(["ok": .bool(true)])
        }

        var dialCount = 0
        supervisor.dial = { _ in
            dialCount += 1
            throw URLError(.cannotConnectToHost)
        }

        fixture.model.applicationDidBecomeActive()
        await waitUntil { dialCount > 0 }
        await LiveRuntime.shared.reconnectTask?.value

        XCTAssertGreaterThanOrEqual(dialCount, 1)
        XCTAssertTrue(fixture.model.reconnectTraceForTesting.contains("didBecomeActive"))
        XCTAssertTrue(
            fixture.model.reconnectTraceForTesting.contains("redial.scheduled"),
            fixture.model.reconnectTraceForTesting.joined(separator: ","))
        XCTAssertTrue(fixture.model.isOffline)
    }

    @MainActor
    func testAlreadyActiveOfflineSupersedesStaleForegroundLease() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let supervisor = ConnectionSupervisor.shared
        fixture.model.isOffline = true
        supervisor.suspendedForBackground = false
        var hung: CheckedContinuation<Void, Never>?
        supervisor.foregroundValidationTask = Task { @MainActor in
            await withCheckedContinuation { hung = $0 }
        }
        supervisor.foregroundValidationToken = UUID()

        var dialCount = 0
        supervisor.dial = { _ in
            dialCount += 1
            throw URLError(.cannotConnectToHost)
        }

        fixture.model.applicationDidBecomeActive()
        await waitUntil { dialCount > 0 }
        hung?.resume()
        await LiveRuntime.shared.reconnectTask?.value

        XCTAssertGreaterThanOrEqual(dialCount, 1)
        XCTAssertTrue(
            fixture.model.lastReconnectStep.contains("already-active")
                || fixture.model.reconnectTraceForTesting.contains("redial.scheduled"),
            fixture.model.lastReconnectStep)
    }

    @MainActor
    func testWakeSupersedesHungDialAndKeepsTranscript() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        let supervisor = ConnectionSupervisor.shared
        let botID = "worker"
        let chat = fixture.model.chat(for: botID)
        chat.sessionID = "hung-sid"
        chat.storedSessionID = "durable-bot-chat"
        chat.messages = [
            ChatMessage(author: .user, text: "do not blank"),
            ChatMessage(author: .bot, text: "still here"),
        ]

        var hung: CheckedContinuation<Void, Never>?
        supervisor.dial = { _ in
            await withCheckedContinuation { hung = $0 }
        }
        fixture.model.reconnectNow()
        await waitUntil { hung != nil && supervisor.isReconnecting }
        let hungGeneration = supervisor.reconnectGeneration

        var wakeDials = 0
        supervisor.dial = { _ in
            wakeDials += 1
        }
        fixture.model.applicationWillResignActive()
        XCTAssertNotEqual(supervisor.reconnectGeneration, hungGeneration)
        fixture.model.applicationDidBecomeActive()
        await waitUntil { wakeDials > 0 }
        await LiveRuntime.shared.reconnectTask?.value

        hung?.resume()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertGreaterThanOrEqual(wakeDials, 1)
        XCTAssertEqual(chat.messages.map(\.text), ["do not blank", "still here"])
        XCTAssertFalse(fixture.model.isOffline)
    }

    @MainActor
    func testBackgroundWakeTraceNamesEachClientStep() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        ConnectionSupervisor.shared.dial = { _ in
            throw URLError(.cannotConnectToHost)
        }

        fixture.model.applicationWillResignActive()
        fixture.model.applicationDidBecomeActive()
        await waitUntil {
            fixture.model.reconnectTraceForTesting.contains("connect.failed")
        }
        await LiveRuntime.shared.reconnectTask?.value

        let steps = fixture.model.reconnectTraceForTesting
        XCTAssertTrue(steps.contains("resign"))
        XCTAssertTrue(steps.contains("didBecomeActive"))
        XCTAssertTrue(steps.contains("redial.scheduled"))
        XCTAssertTrue(steps.contains("connect.started"))
        XCTAssertTrue(steps.contains("connect.failed"))
        XCTAssertTrue(fixture.model.lastReconnectStep.contains("connect.failed"))
    }

    @MainActor
    func testRedialBannerNamesTheTryWhileConnectIsInFlight() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        var hung: CheckedContinuation<Void, Error>?
        ConnectionSupervisor.shared.dial = { _ in
            try await withCheckedThrowingContinuation { hung = $0 }
        }

        fixture.model.reconnectNow()
        await waitUntil { hung != nil && ConnectionSupervisor.shared.isReconnecting }
        XCTAssertEqual(fixture.model.reconnectTryNumber, 1)
        XCTAssertTrue(fixture.model.lastReconnectStep.contains("try 1"),
                      fixture.model.lastReconnectStep)

        hung?.resume(throwing: URLError(.cannotConnectToHost))
        for _ in 0..<20 { await Task.yield() }
    }

    @MainActor
    func testResignWithoutWakeBannerSaysDidBecomeActiveNeverArrived() throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }

        fixture.model.applicationWillResignActive()
        XCTAssertTrue(
            fixture.model.lastReconnectStep.contains("never got didBecomeActive"),
            fixture.model.lastReconnectStep)
        XCTAssertTrue(fixture.model.reconnectTraceForTesting.contains("resign"))
        XCTAssertFalse(fixture.model.reconnectTraceForTesting.contains("didBecomeActive"))
    }

    @MainActor
    func testSuccessfulReconnectTraceReachesAdopted() async throws {
        let fixture = try fixture()
        defer { cleanup(fixture) }
        ConnectionSupervisor.shared.dial = { _ in }

        let outcome = await fixture.model.attemptReconnectOutcome()

        XCTAssertEqual(outcome, .success)
        let steps = fixture.model.reconnectTraceForTesting
        XCTAssertTrue(steps.contains("connect.started"))
        XCTAssertTrue(steps.contains("gateway.ready"))
        XCTAssertTrue(steps.contains("adopted"))
        XCTAssertEqual(fixture.model.lastReconnectStep, "adopted")
    }

    @MainActor
    func testOpenChatResumeDefersHistoryOnTheWire() {
        XCTAssertTrue(OpenChatHistoryPolicy.resumeDefersHistory)
        let params = GatewayClient.resumeSessionParams(
            "durable-bot-chat", profile: "main",
            deferHistory: OpenChatHistoryPolicy.resumeDefersHistory)
        XCTAssertEqual(params["defer_history"]?.boolValue, true)
        XCTAssertNil(GatewayClient.resumeSessionParams(
            "durable-bot-chat", deferHistory: false)["defer_history"])
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
