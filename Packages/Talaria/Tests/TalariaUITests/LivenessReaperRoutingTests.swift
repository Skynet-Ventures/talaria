#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI

@MainActor
final class LivenessReaperRoutingTests: XCTestCase {
    private struct Fixture {
        var model: AppModel
        var primary: SavedGateway
        var primaryClient: GatewayClient
        var remote: SavedGateway
        var remoteClient: GatewayClient
        var primaryBotID: String
        var remoteBotID: String
        var remoteRoute: GatewayBotRoute
    }

    private func liveRow(id: String, key: String, status: String,
                         preview: String = "") -> LiveSessionRow {
        LiveSessionRow(.object([
            "id": .string(id),
            "session_key": .string(key),
            "status": .string(status),
            "last_active": .number(1_777_000_000),
            "preview": .string(preview),
        ]))
    }

    private func approval(id: String, botID: String) -> Approval {
        Approval(id: id, botID: botID, kind: .command, title: "Run",
                 target: "shell", subject: "echo ok", body: "echo ok",
                 why: "test", age: "now")
    }

    private func target(gatewayID: String, profile: String, sessionID: String,
                        requestID: String) -> ApprovalResponseTarget {
        ApprovalResponseTarget(
            bot: GatewayBotRoute(gatewayID: gatewayID, profile: profile),
            session: GatewaySessionRoute(gatewayID: gatewayID, sessionID: sessionID),
            requestID: requestID)
    }

    private func withDualGatewayFixture(
        _ body: @MainActor (Fixture) async throws -> Void
    ) async throws {
        let registry = ConnectionRegistry.shared
        let live = LiveRuntime.shared
        let liveness = LivenessRuntime.shared
        let oldGatewayID = live.gatewayID
        let oldBaseURL = live.baseURL
        let oldGeneration = live.generation
        let oldWorking = live.workingBotIDs
        let oldSessionToBot = live.sessionToBot
        let oldRouted = live.routedSessionToBot
        let oldApprovals = live.approvalTargets
        let nonce = UUID().uuidString
        let primaryURL = try XCTUnwrap(URL(
            string: "https://liveness-primary-\(nonce).example"))
        let remoteURL = try XCTUnwrap(URL(
            string: "https://liveness-remote-\(nonce).example"))
        let primary = try XCTUnwrap(registry.upsert(
            urlString: primaryURL.absoluteString, name: "Liveness primary",
            credential: .sessionToken("liveness-primary-\(nonce)")))
        let remote = try XCTUnwrap(registry.upsert(
            urlString: remoteURL.absoluteString, name: "Liveness remote",
            credential: .sessionToken("liveness-remote-\(nonce)")))
        let primaryClient = GatewayClient(
            baseURL: primaryURL, credential: .sessionToken("liveness-primary-\(nonce)"))
        let remoteClient = GatewayClient(
            baseURL: remoteURL, credential: .sessionToken("liveness-remote-\(nonce)"))
        await registry.clientPool.adopt(primaryClient, for: primary.id)
        await registry.clientPool.adopt(remoteClient, for: remote.id)

        let primaryBotID = "default"
        let remoteRoute = GatewayBotRoute(gatewayID: remote.id, profile: "researcher")
        let remoteBotID = remoteRoute.qualifiedID
        let model = AppModel()
        model.mode = .live
        model.client = primaryClient
        model.bots = [
            Bot(id: primaryBotID, job: "", shape: .circle, hue: .violet),
            Bot(id: remoteBotID, job: "", shape: .circle, hue: .amber, status: .working),
        ]
        live.gatewayID = primary.id
        live.baseURL = primaryURL
        live.generation &+= 1
        live.workingBotIDs = [remoteBotID]
        liveness.supported = true
        liveness.supportedGeneration = live.generation
        liveness.settledSince.removeAll()
        liveness.unverifiableSince.removeAll()
        liveness.reseedPending = false

        let fixture = Fixture(
            model: model, primary: primary, primaryClient: primaryClient,
            remote: remote, remoteClient: remoteClient,
            primaryBotID: primaryBotID, remoteBotID: remoteBotID,
            remoteRoute: remoteRoute)
        var caught: Error?
        do { try await body(fixture) } catch { caught = error }

        liveness.activeSessionsForTesting = nil
        liveness.sessionHistoryForTesting = nil
        liveness.settledSince.removeAll()
        liveness.unverifiableSince.removeAll()
        liveness.reseedPending = false
        liveness.supported = true
        model.client = nil
        model.clearProfileLifecycleRouteForTesting(
            GatewayBotRoute(gatewayID: primary.id, profile: primaryBotID))
        model.clearProfileLifecycleRouteForTesting(remoteRoute)
        live.workingBotIDs = oldWorking
        live.sessionToBot = oldSessionToBot
        live.routedSessionToBot = oldRouted
        live.approvalTargets = oldApprovals
        live.reconnectParkedSessionIDs[remoteBotID] = nil
        live.reconnectParkedSessionIDs[primaryBotID] = nil
        live.canonicalSessionByBot[remoteBotID] = nil
        await registry.clientPool.disconnect(gatewayID: remote.id)
        await registry.clientPool.disconnect(gatewayID: primary.id)
        registry.remove(id: remote.id)
        registry.remove(id: primary.id)
        live.gatewayID = oldGatewayID
        live.baseURL = oldBaseURL
        live.generation = oldGeneration
        if let caught { throw caught }
    }

    func testUniqueRemoteSIDAbsentFromPrimarySnapshotStaysBound() async throws {
        try await withDualGatewayFixture { fixture in
            let remoteSID = "remote-only-\(UUID().uuidString.prefix(8))"
            let remoteChat = fixture.model.chat(for: fixture.remoteBotID)
            remoteChat.sessionID = remoteSID
            remoteChat.storedSessionID = "remote-stored"
            remoteChat.isRunning = true
            let primaryChat = fixture.model.chat(for: fixture.primaryBotID)
            primaryChat.sessionID = "primary-live"
            primaryChat.storedSessionID = "primary-stored"
            LiveRuntime.shared.routedSessionToBot[GatewaySessionRoute(
                gatewayID: fixture.remote.id, sessionID: remoteSID)] = fixture.remoteBotID
            LiveRuntime.shared.sessionToBot["primary-live"] = fixture.primaryBotID

            var asked: [String] = []
            LivenessRuntime.shared.activeSessionsForTesting = { client, gatewayID in
                asked.append(gatewayID)
                if gatewayID == fixture.primary.id {
                    XCTAssertEqual(ObjectIdentifier(client),
                                   ObjectIdentifier(fixture.primaryClient))
                    return [self.liveRow(id: "primary-live", key: "primary-stored",
                                         status: "idle")]
                }
                if gatewayID == fixture.remote.id {
                    XCTAssertEqual(ObjectIdentifier(client),
                                   ObjectIdentifier(fixture.remoteClient))
                    return [self.liveRow(id: remoteSID, key: "remote-stored",
                                         status: "working")]
                }
                XCTFail("unexpected gateway \(gatewayID)")
                return []
            }
            LivenessRuntime.shared.sessionHistoryForTesting = { _, gatewayID, _ in
                XCTFail("unique remote SID must not hydrate from \(gatewayID)")
                return .object(["messages": .array([])])
            }

            await fixture.model.reconcileLiveness(trigger: .reaper)

            XCTAssertTrue(asked.contains(fixture.remote.id),
                          "the owning gateway must be asked, not leftover primary")
            XCTAssertEqual(remoteChat.sessionID, remoteSID)
            XCTAssertEqual(LiveRuntime.shared.routedSessionToBot[GatewaySessionRoute(
                gatewayID: fixture.remote.id, sessionID: remoteSID)], fixture.remoteBotID)
            XCTAssertTrue(LiveRuntime.shared.workingBotIDs.contains(fixture.remoteBotID))
            XCTAssertTrue(remoteChat.isRunning)
        }
    }

    func testCollidingSIDDoesNotClearRemoteWorkingOrGraftPrimaryTranscript() async throws {
        try await withDualGatewayFixture { fixture in
            let collidingSID = "deadbeef"
            let remoteMessages = [
                ChatMessage(author: .user, text: "remote hello", rowID: 1),
                ChatMessage(author: .bot, text: "remote reply", rowID: 2),
            ]
            let remoteChat = fixture.model.chat(for: fixture.remoteBotID)
            remoteChat.sessionID = collidingSID
            remoteChat.storedSessionID = "remote-stored"
            remoteChat.messages = remoteMessages
            remoteChat.isRunning = true
            let primaryChat = fixture.model.chat(for: fixture.primaryBotID)
            primaryChat.sessionID = collidingSID
            primaryChat.storedSessionID = "primary-stored"
            primaryChat.messages = [
                ChatMessage(author: .user, text: "primary hello", rowID: 10),
                ChatMessage(author: .bot, text: "primary reply", rowID: 11),
            ]
            LiveRuntime.shared.sessionToBot[collidingSID] = fixture.primaryBotID
            LiveRuntime.shared.routedSessionToBot[GatewaySessionRoute(
                gatewayID: fixture.remote.id, sessionID: collidingSID)] = fixture.remoteBotID
            fixture.model.openBotID = fixture.remoteBotID

            var asked: [String] = []
            var historyGateways: [String] = []
            LivenessRuntime.shared.activeSessionsForTesting = { client, gatewayID in
                asked.append(gatewayID)
                if gatewayID == fixture.primary.id {
                    XCTAssertEqual(ObjectIdentifier(client),
                                   ObjectIdentifier(fixture.primaryClient))
                    return [self.liveRow(id: collidingSID, key: "primary-stored",
                                         status: "idle",
                                         preview: "primary reply grafted")]
                }
                if gatewayID == fixture.remote.id {
                    XCTAssertEqual(ObjectIdentifier(client),
                                   ObjectIdentifier(fixture.remoteClient))
                    return [self.liveRow(id: collidingSID, key: "remote-stored",
                                         status: "working",
                                         preview: "remote reply")]
                }
                XCTFail("unexpected gateway \(gatewayID)")
                return []
            }
            LivenessRuntime.shared.sessionHistoryForTesting = { _, gatewayID, sid in
                historyGateways.append(gatewayID)
                XCTAssertEqual(sid, collidingSID)
                return .object(["messages": .array([
                    .object(["role": .string("user"), "text": .string("primary hello"),
                             "row_id": .number(10)]),
                    .object(["role": .string("assistant"),
                             "text": .string("primary reply grafted"),
                             "row_id": .number(11)]),
                    .object(["role": .string("user"), "text": .string("more primary"),
                             "row_id": .number(12)]),
                    .object(["role": .string("assistant"),
                             "text": .string("grafted from primary"),
                             "row_id": .number(13)]),
                ])])
            }

            await fixture.model.reconcileLiveness(trigger: .foreground)

            XCTAssertTrue(asked.contains(fixture.remote.id))
            XCTAssertTrue(asked.contains(fixture.primary.id))
            XCTAssertTrue(historyGateways.isEmpty,
                          "a busy remote must not read history from either snapshot")
            XCTAssertEqual(remoteChat.sessionID, collidingSID)
            XCTAssertEqual(LiveRuntime.shared.routedSessionToBot[GatewaySessionRoute(
                gatewayID: fixture.remote.id, sessionID: collidingSID)], fixture.remoteBotID)
            XCTAssertTrue(LiveRuntime.shared.workingBotIDs.contains(fixture.remoteBotID))
            XCTAssertTrue(remoteChat.isRunning)
            XCTAssertEqual(remoteChat.messages.map(\.text), remoteMessages.map(\.text))
            XCTAssertEqual(LiveRuntime.shared.sessionToBot[collidingSID],
                           fixture.primaryBotID)
        }
    }

    func testCanonicalBotModeIdentityKeepsSidlessWorkingTurnVerifiable() async throws {
        try await withDualGatewayFixture { fixture in
            let remoteChat = fixture.model.chat(for: fixture.remoteBotID)
            remoteChat.sessionID = nil
            remoteChat.storedSessionID = nil
            remoteChat.isRunning = true
            LiveRuntime.shared.canonicalSessionByBot[fixture.remoteBotID] =
                CanonicalSessionIdentity(id: "canonical-stored")
            LivenessRuntime.shared.unverifiableSince[fixture.remoteBotID] =
                ContinuousClock.now - .seconds(60)
            LivenessRuntime.shared.activeSessionsForTesting = { _, gatewayID in
                gatewayID == fixture.remote.id
                    ? [self.liveRow(id: "fresh-runtime", key: "canonical-stored",
                                    status: "working")]
                    : []
            }

            await fixture.model.reconcileLiveness(trigger: .reaper)

            XCTAssertTrue(LiveRuntime.shared.workingBotIDs.contains(fixture.remoteBotID))
            XCTAssertTrue(remoteChat.isRunning)
            XCTAssertNil(LivenessRuntime.shared.unverifiableSince[fixture.remoteBotID])
        }
    }

    func testUnbindDeadRemoteDoesNotClearCollidingPrimaryBindings() {
        let model = AppModel()
        let sid = "deadbeef"
        let primaryBot = "default"
        let remoteRoute = GatewayBotRoute(gatewayID: "homelab", profile: "researcher")
        let remoteBot = remoteRoute.qualifiedID
        let previousGatewayID = LiveRuntime.shared.gatewayID
        let previousSession = LiveRuntime.shared.sessionToBot[sid]
        let previousRouted = LiveRuntime.shared.routedSessionToBot[
            GatewaySessionRoute(gatewayID: "homelab", sessionID: sid)]
        let previousPrimaryApproval = LiveRuntime.shared.approvalTargets["primary-card"]
        let previousRemoteApproval = LiveRuntime.shared.approvalTargets["remote-card"]
        LiveRuntime.shared.gatewayID = "primary"
        LiveRuntime.shared.sessionToBot[sid] = primaryBot
        LiveRuntime.shared.routedSessionToBot[GatewaySessionRoute(
            gatewayID: "homelab", sessionID: sid)] = remoteBot
        LiveRuntime.shared.approvalTargets["primary-card"] = target(
            gatewayID: "primary", profile: primaryBot, sessionID: sid,
            requestID: "primary-wire")
        LiveRuntime.shared.approvalTargets["remote-card"] = target(
            gatewayID: "homelab", profile: "researcher", sessionID: sid,
            requestID: "remote-wire")
        model.approvals = [
            approval(id: "primary-card", botID: primaryBot),
            approval(id: "remote-card", botID: remoteBot),
        ]
        model.chat(for: primaryBot).sessionID = sid
        model.chat(for: remoteBot).sessionID = sid

        model.unbindDeadRuntime(sid: sid, botID: remoteBot, sourceGatewayID: "homelab")

        XCTAssertEqual(LiveRuntime.shared.sessionToBot[sid], primaryBot)
        XCTAssertNil(LiveRuntime.shared.routedSessionToBot[GatewaySessionRoute(
            gatewayID: "homelab", sessionID: sid)])
        XCTAssertEqual(model.chat(for: primaryBot).sessionID, sid)
        XCTAssertNil(model.chat(for: remoteBot).sessionID)
        XCTAssertEqual(model.approvals.map(\.id), ["primary-card"])
        XCTAssertEqual(LiveRuntime.shared.approvalTargets["primary-card"]?.requestID,
                       "primary-wire")
        XCTAssertNil(LiveRuntime.shared.approvalTargets["remote-card"])

        LiveRuntime.shared.sessionToBot[sid] = previousSession
        if let previousRouted {
            LiveRuntime.shared.routedSessionToBot[GatewaySessionRoute(
                gatewayID: "homelab", sessionID: sid)] = previousRouted
        } else {
            LiveRuntime.shared.routedSessionToBot.removeValue(forKey: GatewaySessionRoute(
                gatewayID: "homelab", sessionID: sid))
        }
        LiveRuntime.shared.approvalTargets["primary-card"] = previousPrimaryApproval
        LiveRuntime.shared.approvalTargets["remote-card"] = previousRemoteApproval
        LiveRuntime.shared.reconnectParkedSessionIDs[remoteBot] = nil
        LiveRuntime.shared.gatewayID = previousGatewayID
    }
}
#endif
