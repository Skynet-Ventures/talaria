#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI

@MainActor
final class MessageBranchingFlowTests: XCTestCase {
    private struct Fixture {
        var model: AppModel
        var gatewayID: String
        var profile: String
        var botID: String
        var route: GatewayBotRoute
        var client: GatewayClient
        var baseURL: URL
        var chat: ChatState
        var target: ChatMessage
        var primaryClient: GatewayClient?
    }

    private var authoritativeHistory: JSONValue {
        .object(["messages": .array([
            .object(["role": .string("system"), "text": .string("system"),
                     "row_id": .number(9)]),
            .object(["role": .string("user"), "text": .string("first"),
                     "row_id": .number(10)]),
            .object(["role": .string("tool"), "text": .string("tool result"),
                     "row_id": .number(11)]),
            .object(["role": .string("assistant"), "text": .string("same answer"),
                     "row_id": .number(12)]),
            .object(["role": .string("user"), "text": .string("hidden marker"),
                     "display_kind": .string("hidden"), "row_id": .number(13)]),
            .object(["role": .string("assistant"), "text": .string("  "),
                     "row_id": .number(14)]),
            .object(["role": .string("user"), "text": .string("second"),
                     "row_id": .number(17)]),
            .object(["role": .string("assistant"), "text": .string("same answer"),
                     "row_id": .number(18)]),
        ])])
    }

    private func branch(parent: String = "parent-stored", count: Int = 2,
                        runtime: String = "child-runtime",
                        stored: String = "child-stored") -> SessionBranch {
        SessionBranch(.object([
            "session_id": .string(runtime),
            "stored_session_id": .string(stored),
            "title": .string("Parent (branch)"),
            "parent": .string(parent),
            "message_count": .number(Double(count)),
            "messages": .array([]),
        ]))
    }

    private var listedSessions: [StoredSession] {
        [
            StoredSession(.object([
                "id": .string("parent-stored"),
                "title": .string("Parent"),
                "message_count": .number(4),
            ])),
            StoredSession(.object([
                "id": .string("child-stored"),
                "title": .string("Parent (branch)"),
                "message_count": .number(2),
            ])),
        ]
    }

    private func clearMutationState(botID: String) {
        let chat = ChatRuntime.shared
        chat.transcriptActions[botID] = nil
        chat.transcriptActionGenerations[botID] = nil
        chat.transcriptLeases[botID] = nil
        chat.transcriptFences[botID] = nil
        chat.steerActions[botID] = nil
        chat.steerFences[botID] = nil
        chat.stopActions[botID] = nil
        chat.stopFences[botID] = nil
        chat.pendingStopRequests[botID] = nil
        let canonical = CanonicalChatRuntime.shared
        canonical.kickoffs[botID] = nil
        canonical.kickoffLeases[botID] = nil
        canonical.ambiguousKickoffs[botID] = nil
    }

    private func resetBranchRuntime() {
        let runtime = MessageBranchRuntime.shared
        for task in runtime.tasks.values { task.cancel() }
        runtime.actionIDs = [:]
        runtime.tasks = [:]
        runtime.historyForTesting = nil
        runtime.mutationForTesting = nil
        runtime.openForTesting = nil
        runtime.afterHistoryForTesting = nil
        let sessions = SessionsRuntime.shared
        sessions.listSessionsForTesting = nil
        sessions.exactOpenProfilesForTesting = nil
        sessions.exactOpenResumeForTesting = nil
        ChatRuntime.shared.interruptForTesting = nil
        SessionMutationCoordinator.shared.resetForTesting()
    }

    private func withPrimaryFixture(
        _ body: @MainActor (Fixture) async throws -> Void
    ) async throws {
        resetBranchRuntime()
        let registry = ConnectionRegistry.shared
        let live = LiveRuntime.shared
        let oldGatewayID = live.gatewayID
        let oldBaseURL = live.baseURL
        let oldGeneration = live.generation
        let gatewayURL = try XCTUnwrap(URL(
            string: "https://message-branch-\(UUID().uuidString).example"))
        let saved = try XCTUnwrap(registry.upsert(
            urlString: gatewayURL.absoluteString, name: "Message branch",
            credential: .sessionToken("message-branch-token")))
        let profile = "researcher"
        let route = GatewayBotRoute(gatewayID: saved.id, profile: profile)
        let client = GatewayClient(
            baseURL: gatewayURL, credential: .sessionToken("message-branch-token"))
        await registry.clientPool.adopt(client, for: saved.id)

        let target = ChatMessage(author: .bot, text: "same answer", rowID: 12)
        let chat = ChatState(messages: [
            ChatMessage(author: .user, text: "first", rowID: 10),
            target,
            ChatMessage(author: .user, text: "second", rowID: 17),
            ChatMessage(author: .bot, text: "same answer", rowID: 18),
        ])
        chat.sessionID = "parent-runtime"
        chat.storedSessionID = "parent-stored"
        let model = AppModel()
        model.mode = .live
        model.client = client
        model.bots = [Bot(id: profile, job: "", shape: .circle, hue: .violet)]
        model.chats[profile] = chat
        live.gatewayID = saved.id
        live.baseURL = gatewayURL
        live.generation &+= 1
        live.workingBotIDs.remove(profile)

        let fixture = Fixture(
            model: model, gatewayID: saved.id, profile: profile,
            botID: profile, route: route, client: client, baseURL: gatewayURL,
            chat: chat, target: target, primaryClient: nil)
        var caught: Error?
        do { try await body(fixture) } catch { caught = error }

        MessageBranchRuntime.shared.tasks[profile]?.cancel()
        await model.awaitMessageBranchForTesting(botID: profile)
        resetBranchRuntime()
        model.client = nil
        model.clearProfileLifecycleRouteForTesting(route)
        clearMutationState(botID: profile)
        live.workingBotIDs.remove(profile)
        await registry.clientPool.disconnect(gatewayID: saved.id)
        registry.remove(id: saved.id)
        live.gatewayID = oldGatewayID
        live.baseURL = oldBaseURL
        live.generation = oldGeneration
        if let caught { throw caught }
    }

    private func withForeignFixture(
        _ body: @MainActor (Fixture) async throws -> Void
    ) async throws {
        resetBranchRuntime()
        let registry = ConnectionRegistry.shared
        let live = LiveRuntime.shared
        let oldGatewayID = live.gatewayID
        let oldBaseURL = live.baseURL
        let oldGeneration = live.generation
        let primaryURL = try XCTUnwrap(URL(
            string: "https://message-branch-primary-\(UUID().uuidString).example"))
        let remoteURL = try XCTUnwrap(URL(
            string: "https://message-branch-remote-\(UUID().uuidString).example"))
        let primary = try XCTUnwrap(registry.upsert(
            urlString: primaryURL.absoluteString, name: "Primary",
            credential: .sessionToken("primary-token")))
        let remote = try XCTUnwrap(registry.upsert(
            urlString: remoteURL.absoluteString, name: "Remote",
            credential: .sessionToken("remote-token")))
        let primaryClient = GatewayClient(
            baseURL: primaryURL, credential: .sessionToken("primary-token"))
        let remoteClient = GatewayClient(
            baseURL: remoteURL, credential: .sessionToken("remote-token"))
        await registry.clientPool.adopt(primaryClient, for: primary.id)
        await registry.clientPool.adopt(remoteClient, for: remote.id)

        let profile = "same-name"
        let route = GatewayBotRoute(gatewayID: remote.id, profile: profile)
        let botID = route.qualifiedID
        let target = ChatMessage(author: .bot, text: "same answer", rowID: 12)
        let chat = ChatState(messages: [
            ChatMessage(author: .user, text: "first", rowID: 10), target,
            ChatMessage(author: .user, text: "second", rowID: 17),
            ChatMessage(author: .bot, text: "same answer", rowID: 18),
        ])
        chat.sessionID = "parent-runtime"
        chat.storedSessionID = "parent-stored"
        let model = AppModel()
        model.mode = .live
        model.client = primaryClient
        model.bots = [
            Bot(id: profile, job: "", shape: .circle, hue: .violet),
            Bot(id: botID, job: "", shape: .circle, hue: .amber),
        ]
        model.chats[botID] = chat
        live.gatewayID = primary.id
        live.baseURL = primaryURL
        live.generation &+= 1
        live.workingBotIDs.remove(botID)

        let fixture = Fixture(
            model: model, gatewayID: remote.id, profile: profile,
            botID: botID, route: route, client: remoteClient, baseURL: remoteURL,
            chat: chat, target: target, primaryClient: primaryClient)
        var caught: Error?
        do { try await body(fixture) } catch { caught = error }

        MessageBranchRuntime.shared.tasks[botID]?.cancel()
        await model.awaitMessageBranchForTesting(botID: botID)
        resetBranchRuntime()
        model.client = nil
        model.clearProfileLifecycleRouteForTesting(route)
        clearMutationState(botID: botID)
        live.workingBotIDs.remove(botID)
        await registry.clientPool.disconnect(gatewayID: remote.id)
        await registry.clientPool.disconnect(gatewayID: primary.id)
        registry.remove(id: remote.id)
        registry.remove(id: primary.id)
        live.gatewayID = oldGatewayID
        live.baseURL = oldBaseURL
        live.generation = oldGeneration
        if let caught { throw caught }
    }

    func testEligiblePolicyRejectsNewestStreamingAndUndurableAssistants() {
        let historical = ChatMessage(author: .bot, text: "old", rowID: 2)
        let newest = ChatMessage(author: .bot, text: "new", rowID: 4)
        XCTAssertTrue(MessageBranching.isEligible(historical, in: [historical, newest]))
        XCTAssertFalse(MessageBranching.isEligible(newest, in: [historical, newest]))
        var streaming = historical
        streaming.isStreaming = true
        XCTAssertFalse(MessageBranching.isEligible(streaming, in: [streaming, newest]))
        let local = ChatMessage(author: .bot, text: "local")
        XCTAssertFalse(MessageBranching.isEligible(local, in: [local, newest]))
    }

    func testDoubleTapMutatesOnceWithAuthoritativeFilteredRowIDCount() async throws {
        try await withPrimaryFixture { fixture in
            XCTAssertTrue(fixture.model.canBranchFromMessage(
                fixture.target, in: fixture.botID),
                "fixture must satisfy message-branch admission")
            var histories = 0
            var mutations = 0
            var refreshes = 0
            var opened: [ExactStoredSessionRoute] = []
            let runtime = MessageBranchRuntime.shared
            runtime.historyForTesting = { client, sessionID in
                XCTAssertTrue(client === fixture.client)
                XCTAssertEqual(sessionID, "parent-runtime")
                histories += 1
                return self.authoritativeHistory
            }
            runtime.mutationForTesting = { client, sessionID, count in
                XCTAssertTrue(client === fixture.client)
                XCTAssertEqual(sessionID, "parent-runtime")
                XCTAssertEqual(count, 2,
                    "system/tool/hidden/empty rows must not enter Hermes' count")
                mutations += 1
                return self.branch(count: count)
            }
            SessionsRuntime.shared.listSessionsForTesting = { client, profile in
                XCTAssertTrue(client === fixture.client)
                XCTAssertEqual(profile, fixture.profile)
                refreshes += 1
                return self.listedSessions
            }
            runtime.openForTesting = { opened.append($0) }

            fixture.model.branchFromMessage(fixture.target, in: fixture.botID)
            fixture.model.branchFromMessage(fixture.target, in: fixture.botID)
            await fixture.model.awaitMessageBranchForTesting(botID: fixture.botID)

            XCTAssertEqual(histories, 1)
            XCTAssertEqual(mutations, 1)
            XCTAssertEqual(refreshes, 1)
            XCTAssertEqual(opened, [ExactStoredSessionRoute(
                gatewayID: fixture.gatewayID, profile: fixture.profile,
                storedSessionID: "child-stored")!])
        }
    }

    private func assertStaleCompletionRejected(
        mutateAfterHistory: @escaping @MainActor (Fixture) -> Void
    ) async throws {
        try await withPrimaryFixture { fixture in
            var mutations = 0
            let runtime = MessageBranchRuntime.shared
            runtime.historyForTesting = { _, _ in self.authoritativeHistory }
            runtime.afterHistoryForTesting = { mutateAfterHistory(fixture) }
            runtime.mutationForTesting = { _, _, count in
                mutations += 1
                return self.branch(count: count)
            }
            runtime.openForTesting = { _ in }

            fixture.model.branchFromMessage(fixture.target, in: fixture.botID)
            await fixture.model.awaitMessageBranchForTesting(botID: fixture.botID)
            XCTAssertEqual(mutations, 0)
        }
    }

    func testStaleRuntimeSessionAfterHistoryIsRejectedBeforeMutation() async throws {
        try await assertStaleCompletionRejected { fixture in
            fixture.chat.sessionID = "replacement-runtime"
        }
    }

    func testStaleSourceClientAfterHistoryIsRejectedBeforeMutation() async throws {
        try await assertStaleCompletionRejected { fixture in
            fixture.model.client = GatewayClient(
                baseURL: fixture.baseURL,
                credential: .sessionToken("replacement-token"))
        }
    }

    func testStaleProfileLifecycleAfterHistoryIsRejectedBeforeMutation() async throws {
        try await assertStaleCompletionRejected { fixture in
            fixture.model.invalidateProfileLifecycleRouteForTesting(fixture.route)
        }
    }

    func testTurnBecomingBusyAfterHistoryIsRejectedBeforeMutation() async throws {
        try await assertStaleCompletionRejected { fixture in
            fixture.chat.isRunning = true
        }
    }

    func testMalformedWrongParentAndWrongCountAcknowledgementsFailClosed() {
        XCTAssertThrowsError(try SessionBranchAckAuthority.requireExact(
            branch(runtime: "", stored: "child"),
            parentRuntimeSessionID: "parent-runtime",
            parentStoredSessionID: "parent-stored", requestedCount: 2))
        XCTAssertThrowsError(try SessionBranchAckAuthority.requireExact(
            branch(parent: "other-parent"),
            parentRuntimeSessionID: "parent-runtime",
            parentStoredSessionID: "parent-stored", requestedCount: 2))
        XCTAssertThrowsError(try SessionBranchAckAuthority.requireExact(
            branch(count: 3),
            parentRuntimeSessionID: "parent-runtime",
            parentStoredSessionID: "parent-stored", requestedCount: 2))
        XCTAssertThrowsError(try SessionBranchAckAuthority.requireExact(
            branch(runtime: "parent-runtime"),
            parentRuntimeSessionID: "parent-runtime",
            parentStoredSessionID: "parent-stored", requestedCount: 2))
        XCTAssertThrowsError(try SessionBranchAckAuthority.requireExact(
            branch(stored: "parent-stored"),
            parentRuntimeSessionID: "parent-runtime",
            parentStoredSessionID: "parent-stored", requestedCount: 2))
        var fractional = branch(count: 2)
        fractional.messageCount = SessionBranch(.object([
            "message_count": .number(2.5),
        ])).messageCount
        XCTAssertThrowsError(try SessionBranchAckAuthority.requireExact(
            fractional, parentRuntimeSessionID: "parent-runtime",
            parentStoredSessionID: "parent-stored", requestedCount: 2))
    }

    func testAmbiguousTimeoutNeverRetriesMutation() async throws {
        try await withPrimaryFixture { fixture in
            var mutations = 0
            var refreshes = 0
            var opens = 0
            let runtime = MessageBranchRuntime.shared
            runtime.historyForTesting = { _, _ in self.authoritativeHistory }
            runtime.mutationForTesting = { _, _, _ in
                mutations += 1
                throw GatewayError(code: -5, message: "request timed out: session.branch")
            }
            SessionsRuntime.shared.listSessionsForTesting = { client, profile in
                XCTAssertTrue(client === fixture.client)
                XCTAssertEqual(profile, fixture.profile)
                refreshes += 1
                return self.listedSessions
            }
            runtime.openForTesting = { _ in opens += 1 }

            fixture.model.branchFromMessage(fixture.target, in: fixture.botID)
            await fixture.model.awaitMessageBranchForTesting(botID: fixture.botID)
            for _ in 0..<20 { await Task.yield() }

            XCTAssertEqual(mutations, 1)
            XCTAssertEqual(refreshes, 1,
                           "read-only list refresh is reconciliation, not a mutation retry")
            XCTAssertEqual(opens, 0)
        }
    }

    func testBranchSuccessOpenFailurePreservesParentAndExposesChildInRefreshedList() async throws {
        try await withPrimaryFixture { fixture in
            let baseline = fixture.chat.messages
            var mutations = 0
            let runtime = MessageBranchRuntime.shared
            runtime.historyForTesting = { _, _ in self.authoritativeHistory }
            runtime.mutationForTesting = { _, _, count in
                mutations += 1
                return self.branch(count: count)
            }
            SessionsRuntime.shared.listSessionsForTesting = { client, profile in
                XCTAssertTrue(client === fixture.client)
                XCTAssertEqual(profile, fixture.profile)
                return self.listedSessions
            }
            runtime.openForTesting = { _ in
                throw GatewayError(code: -5, message: "resume timed out")
            }

            fixture.model.branchFromMessage(fixture.target, in: fixture.botID)
            await fixture.model.awaitMessageBranchForTesting(botID: fixture.botID)

            XCTAssertEqual(mutations, 1)
            XCTAssertEqual(fixture.chat.sessionID, "parent-runtime")
            XCTAssertEqual(fixture.chat.storedSessionID, "parent-stored")
            XCTAssertEqual(fixture.chat.messages, baseline)
            XCTAssertTrue(fixture.chat.storedSessions.contains(where: {
                $0.id == "child-stored"
            }))
        }
    }

    func testParentTurnAndStopDuringProductionChildOpenAbortAndDrainExactInterrupt() async throws {
        try await withPrimaryFixture { fixture in
            let baseline = fixture.chat.messages
            let priorOpenBotID = fixture.model.openBotID
            let priorOpenGeneration = SessionsRuntime.shared.openGenerations[fixture.botID]
            let priorLastSession = LiveRuntime.shared.lastSessionByBot[fixture.botID]
            var profiles = 0
            var resumes = 0
            var interrupts = 0
            var preflightStarted = false
            var releasePreflight: CheckedContinuation<Void, Never>?
            let runtime = MessageBranchRuntime.shared
            XCTAssertNil(runtime.openForTesting,
                         "this race must exercise the production open transaction")
            runtime.historyForTesting = { client, sessionID in
                XCTAssertTrue(client === fixture.client)
                XCTAssertEqual(sessionID, "parent-runtime")
                return self.authoritativeHistory
            }
            runtime.mutationForTesting = { client, sessionID, count in
                XCTAssertTrue(client === fixture.client)
                XCTAssertEqual(sessionID, "parent-runtime")
                return self.branch(count: count)
            }
            SessionsRuntime.shared.listSessionsForTesting = { client, profile in
                XCTAssertTrue(client === fixture.client)
                XCTAssertEqual(profile, fixture.profile)
                return self.listedSessions
            }
            SessionsRuntime.shared.exactOpenProfilesForTesting = { client, route in
                XCTAssertTrue(client === fixture.client)
                XCTAssertEqual(route.gatewayID, fixture.gatewayID)
                XCTAssertEqual(route.profile, fixture.profile)
                profiles += 1
                return [HermesProfile(.object(["name": .string(fixture.profile)]))]
            }
            SessionsRuntime.shared.exactOpenResumeForTesting = { client, route in
                XCTAssertTrue(client === fixture.client)
                XCTAssertEqual(route.storedSessionID, "child-stored")
                resumes += 1
                preflightStarted = true
                await withCheckedContinuation { releasePreflight = $0 }
                return LiveSession(.object([
                    "session_id": .string("child-runtime"),
                    "stored_session_id": .string("child-stored"),
                    "messages": .array([
                        .object(["role": .string("assistant"),
                                 "text": .string("child transcript")]),
                    ]),
                    "info": .object(["profile_name": .string(fixture.profile)]),
                ]))
            }
            ChatRuntime.shared.interruptForTesting = { client, sessionID in
                XCTAssertTrue(client === fixture.client)
                XCTAssertEqual(sessionID, "parent-runtime")
                let target = try XCTUnwrap(fixture.model.exactSessionMutationTarget(
                    botID: fixture.botID))
                XCTAssertTrue(SessionMutationCoordinator.shared.isAvailable(target),
                              "the parent claim must release before Stop drains")
                XCTAssertNil(MessageBranchRuntime.shared.actionIDs[fixture.botID])
                interrupts += 1
            }
            defer { releasePreflight?.resume() }

            fixture.model.branchFromMessage(fixture.target, in: fixture.botID)
            for _ in 0..<200 where !preflightStarted { await Task.yield() }
            XCTAssertTrue(preflightStarted,
                          "the production child-open transaction must reach resume preflight")

            // A gateway event can start the parent while child resume is on
            // the wire. Stop must remain an exact-parent intent behind the
            // message-branch claim instead of being inherited by the child.
            fixture.chat.isRunning = true
            fixture.chat.isTyping = true
            fixture.model.stopTurn(botID: fixture.botID)
            let pending = try XCTUnwrap(
                ChatRuntime.shared.pendingStopRequests[fixture.botID])
            XCTAssertEqual(pending.route, fixture.route)
            XCTAssertEqual(pending.sessionID, "parent-runtime")
            XCTAssertEqual(pending.storedID, "parent-stored")
            XCTAssertEqual(interrupts, 0)

            releasePreflight?.resume()
            releasePreflight = nil
            await fixture.model.awaitMessageBranchForTesting(botID: fixture.botID)
            for _ in 0..<200 where interrupts < 1
                || ChatRuntime.shared.stopActions[fixture.botID] != nil {
                await Task.yield()
            }

            XCTAssertEqual(profiles, 2)
            XCTAssertEqual(resumes, 1)
            XCTAssertEqual(interrupts, 1)
            XCTAssertEqual(fixture.chat.sessionID, "parent-runtime")
            XCTAssertEqual(fixture.chat.storedSessionID, "parent-stored")
            XCTAssertEqual(Array(fixture.chat.messages.prefix(baseline.count)), baseline)
            XCTAssertFalse(fixture.chat.messages.contains { $0.text == "child transcript" })
            XCTAssertEqual(SessionsRuntime.shared.openGenerations[fixture.botID],
                           priorOpenGeneration,
                           "beginStoredSessionOpen must never commit the child")
            XCTAssertEqual(fixture.model.openBotID, priorOpenBotID)
            XCTAssertEqual(LiveRuntime.shared.lastSessionByBot[fixture.botID],
                           priorLastSession)
            XCTAssertNil(ChatRuntime.shared.pendingStopRequests[fixture.botID])
            XCTAssertNil(ChatRuntime.shared.stopActions[fixture.botID])
        }
    }

    func testSeededSteerMakesMessageBranchIneligible() async throws {
        try await withPrimaryFixture { fixture in
            XCTAssertTrue(fixture.model.canBranchFromMessage(
                fixture.target, in: fixture.botID))
            ChatRuntime.shared.steerActions[fixture.botID] = SteerMutationLease(
                id: UUID(), botID: fixture.botID, route: fixture.route,
                sessionID: "parent-runtime", storedID: "parent-stored",
                chatID: ObjectIdentifier(fixture.chat), optimisticID: UUID(),
                text: "correction")
            XCTAssertFalse(fixture.model.canBranchFromMessage(
                fixture.target, in: fixture.botID))
        }
    }

    func testSeededStopMakesMessageBranchIneligible() async throws {
        try await withPrimaryFixture { fixture in
            XCTAssertTrue(fixture.model.canBranchFromMessage(
                fixture.target, in: fixture.botID))
            ChatRuntime.shared.stopActions[fixture.botID] = StopTurnLease(
                botID: fixture.botID, route: fixture.route,
                sessionID: "parent-runtime", storedID: "parent-stored",
                chatID: ObjectIdentifier(fixture.chat))
            XCTAssertFalse(fixture.model.canBranchFromMessage(
                fixture.target, in: fixture.botID))
        }
    }

    func testAmbiguousKickoffMakesMessageBranchIneligible() async throws {
        try await withPrimaryFixture { fixture in
            let lease = CanonicalKickoffLease(
                id: UUID(), botID: fixture.botID,
                sessionID: "parent-runtime", storedID: "parent-stored",
                rowID: nil, chatID: ObjectIdentifier(fixture.chat),
                submitStarted: true, route: fixture.route)
            CanonicalChatRuntime.shared.kickoffs[fixture.botID] = lease.id
            CanonicalChatRuntime.shared.ambiguousKickoffs[fixture.botID] = lease
            XCTAssertFalse(fixture.model.canBranchFromMessage(
                fixture.target, in: fixture.botID))
        }
    }

    func testMessageBranchClaimRejectsConcurrentSessionControls() async throws {
        try await withPrimaryFixture { fixture in
            var reachedHistoryFence = false
            var releaseHistory: CheckedContinuation<Void, Never>?
            var messageMutations = 0
            var wholeMutations = 0
            var compressions = 0
            let runtime = MessageBranchRuntime.shared
            runtime.historyForTesting = { _, _ in self.authoritativeHistory }
            runtime.afterHistoryForTesting = {
                reachedHistoryFence = true
                await withCheckedContinuation { releaseHistory = $0 }
            }
            runtime.mutationForTesting = { _, _, count in
                messageMutations += 1
                return self.branch(count: count)
            }
            runtime.openForTesting = { _ in }
            SessionsRuntime.shared.listSessionsForTesting = { _, _ in self.listedSessions }
            SessionMutationCoordinator.shared.wholeBranchForTesting = { _, _ in
                wholeMutations += 1
                return self.branch()
            }
            SessionMutationCoordinator.shared.compressionForTesting = { _, _ in
                compressions += 1
                return SessionCompression(.object(["status": .string("compressed")]))
            }

            fixture.model.branchFromMessage(fixture.target, in: fixture.botID)
            while !reachedHistoryFence { await Task.yield() }
            let outcome = await fixture.model.branchSession(botID: fixture.botID)
            XCTAssertFalse(outcome.ok)
            XCTAssertEqual(wholeMutations, 0)
            let compression = await fixture.model.compressSession(botID: fixture.botID)
            XCTAssertFalse(compression.ok)
            XCTAssertEqual(compressions, 0)
            releaseHistory?.resume()
            await fixture.model.awaitMessageBranchForTesting(botID: fixture.botID)
            XCTAssertEqual(messageMutations, 1)
        }
    }

    func testWholeSessionBranchClaimRejectsConcurrentMessageBranch() async throws {
        try await withPrimaryFixture { fixture in
            var reachedClaimFence = false
            var releaseClaim: CheckedContinuation<Void, Never>?
            var messageMutations = 0
            var wholeMutations = 0
            MessageBranchRuntime.shared.historyForTesting = { _, _ in
                self.authoritativeHistory
            }
            MessageBranchRuntime.shared.mutationForTesting = { _, _, count in
                messageMutations += 1
                return self.branch(count: count)
            }
            SessionMutationCoordinator.shared.afterClaimForTesting = { claim in
                guard claim.kind == .wholeSessionBranch else { return }
                reachedClaimFence = true
                await withCheckedContinuation { releaseClaim = $0 }
            }
            SessionMutationCoordinator.shared.wholeBranchForTesting = { _, _ in
                wholeMutations += 1
                throw GatewayError(code: 500, message: "focused whole-branch failure")
            }

            let wholeTask = Task { @MainActor in
                await fixture.model.branchSession(botID: fixture.botID)
            }
            while !reachedClaimFence { await Task.yield() }
            XCTAssertFalse(fixture.model.canBranchFromMessage(
                fixture.target, in: fixture.botID))
            fixture.model.branchFromMessage(fixture.target, in: fixture.botID)
            XCTAssertNil(MessageBranchRuntime.shared.actionIDs[fixture.botID])
            XCTAssertEqual(messageMutations, 0)
            releaseClaim?.resume()
            let outcome = await wholeTask.value
            XCTAssertFalse(outcome.ok)
            XCTAssertEqual(wholeMutations, 1)
            let target = try XCTUnwrap(fixture.model.exactSessionMutationTarget(
                botID: fixture.botID))
            XCTAssertTrue(SessionMutationCoordinator.shared.isAvailable(target),
                          "a failed whole-session branch must release its claim")
        }
    }

    func testWholeSessionBranchPublishesLineageOnlyFromAuthoritativeRefresh() async throws {
        try await withPrimaryFixture { fixture in
            var listCalls = 0
            SessionMutationCoordinator.shared.wholeBranchForTesting = { _, sessionID in
                XCTAssertEqual(sessionID, "parent-runtime")
                // The acknowledgement deliberately carries no lineage fields.
                return self.branch(count: 2)
            }
            SessionsRuntime.shared.listSessionsForTesting = { client, profile in
                XCTAssertTrue(client === fixture.client)
                XCTAssertEqual(profile, fixture.profile)
                listCalls += 1
                return [
                    StoredSession(.object([
                        "id": .string("parent-stored"),
                        "title": .string("Parent"),
                        "message_count": .number(4),
                    ])),
                    StoredSession(.object([
                        "id": .string("child-stored"),
                        "title": .string("Authoritative child"),
                        "message_count": .number(2),
                        "parent_session_id": .string("parent-stored"),
                        "branch_parent_root_id": .string("parent-stored"),
                    ])),
                ]
            }

            let outcome = await fixture.model.branchSession(botID: fixture.botID)

            XCTAssertTrue(outcome.ok)
            XCTAssertEqual(listCalls, 1)
            let child = try XCTUnwrap(fixture.chat.storedSessions.first(where: {
                $0.id == "child-stored"
            }))
            XCTAssertEqual(child.title, "Authoritative child")
            XCTAssertEqual(child.parentSessionID, "parent-stored")
            XCTAssertEqual(child.branchParentRootID, "parent-stored")
        }
    }

    func testWholeSessionBranchRejectsMismatchedAckBeforeListRefresh() async throws {
        try await withPrimaryFixture { fixture in
            var listCalls = 0
            SessionMutationCoordinator.shared.wholeBranchForTesting = { _, _ in
                self.branch(parent: "wrong-parent", count: 2)
            }
            SessionsRuntime.shared.listSessionsForTesting = { _, _ in
                listCalls += 1
                return self.listedSessions
            }

            let outcome = await fixture.model.branchSession(botID: fixture.botID)

            XCTAssertFalse(outcome.ok)
            XCTAssertEqual(listCalls, 0)
            XCTAssertTrue(fixture.chat.storedSessions.isEmpty)
        }
    }

    func testWholeSessionBranchProfileSupersessionCannotPublishRefresh() async throws {
        try await withPrimaryFixture { fixture in
            var listCalls = 0
            SessionMutationCoordinator.shared.wholeBranchForTesting = { _, _ in
                fixture.model.invalidateProfileLifecycleRouteForTesting(fixture.route)
                return self.branch(count: 2)
            }
            SessionsRuntime.shared.listSessionsForTesting = { _, _ in
                listCalls += 1
                return self.listedSessions
            }

            let outcome = await fixture.model.branchSession(botID: fixture.botID)

            XCTAssertFalse(outcome.ok)
            XCTAssertEqual(listCalls, 0)
            XCTAssertTrue(fixture.chat.storedSessions.isEmpty)
        }
    }

    func testCompressionFailureReleasesClaimAndRestoresMessageBranchAdmission() async throws {
        try await withPrimaryFixture { fixture in
            var compressions = 0
            SessionMutationCoordinator.shared.compressionForTesting = { _, sessionID in
                XCTAssertEqual(sessionID, "parent-runtime")
                compressions += 1
                throw GatewayError(code: 500, message: "focused compression failure")
            }

            let outcome = await fixture.model.compressSession(botID: fixture.botID)

            XCTAssertFalse(outcome.ok)
            XCTAssertEqual(compressions, 1)
            XCTAssertTrue(fixture.model.canBranchFromMessage(
                fixture.target, in: fixture.botID))
            let target = try XCTUnwrap(fixture.model.exactSessionMutationTarget(
                botID: fixture.botID))
            XCTAssertTrue(SessionMutationCoordinator.shared.isAvailable(target))
        }
    }

    func testSourceProfileCollisionUsesOnlyCapturedRemoteClient() async throws {
        try await withForeignFixture { fixture in
            var mutationClient: GatewayClient?
            var refreshClient: GatewayClient?
            let runtime = MessageBranchRuntime.shared
            runtime.historyForTesting = { client, _ in
                XCTAssertTrue(client === fixture.client)
                return self.authoritativeHistory
            }
            runtime.mutationForTesting = { client, _, count in
                mutationClient = client
                return self.branch(count: count)
            }
            SessionsRuntime.shared.listSessionsForTesting = { client, profile in
                refreshClient = client
                XCTAssertEqual(profile, fixture.profile)
                return self.listedSessions
            }
            runtime.openForTesting = { child in
                XCTAssertEqual(child.gatewayID, fixture.gatewayID)
                XCTAssertEqual(child.profile, fixture.profile)
            }
            fixture.model.branchFromMessage(fixture.target, in: fixture.botID)
            await fixture.model.awaitMessageBranchForTesting(botID: fixture.botID)

            XCTAssertTrue(mutationClient === fixture.client)
            XCTAssertTrue(refreshClient === fixture.client)
            XCTAssertFalse(mutationClient === fixture.primaryClient)
            XCTAssertTrue(fixture.chat.storedSessions.contains {
                $0.id == "child-stored"
            })
        }
    }

    func testForeignAmbiguousTimeoutRefreshesExactSourceWithoutRetry() async throws {
        try await withForeignFixture { fixture in
            var mutations = 0
            var refreshes = 0
            var opens = 0
            let runtime = MessageBranchRuntime.shared
            runtime.historyForTesting = { client, _ in
                XCTAssertTrue(client === fixture.client)
                return self.authoritativeHistory
            }
            runtime.mutationForTesting = { client, _, _ in
                XCTAssertTrue(client === fixture.client)
                mutations += 1
                throw GatewayError(code: -5, message: "request timed out: session.branch")
            }
            SessionsRuntime.shared.listSessionsForTesting = { client, profile in
                XCTAssertTrue(client === fixture.client)
                XCTAssertFalse(client === fixture.primaryClient)
                XCTAssertEqual(profile, fixture.profile)
                refreshes += 1
                return self.listedSessions
            }
            runtime.openForTesting = { _ in opens += 1 }

            fixture.model.branchFromMessage(fixture.target, in: fixture.botID)
            await fixture.model.awaitMessageBranchForTesting(botID: fixture.botID)

            XCTAssertEqual(mutations, 1)
            XCTAssertEqual(refreshes, 1)
            XCTAssertEqual(opens, 0)
            XCTAssertTrue(fixture.chat.storedSessions.contains {
                $0.id == "child-stored"
            })
        }
    }

    func testForeignOpenFailurePreservesParentAndPublishesExactSourceChild() async throws {
        try await withForeignFixture { fixture in
            let baseline = fixture.chat.messages
            var refreshes = 0
            let runtime = MessageBranchRuntime.shared
            runtime.historyForTesting = { client, _ in
                XCTAssertTrue(client === fixture.client)
                return self.authoritativeHistory
            }
            runtime.mutationForTesting = { client, _, count in
                XCTAssertTrue(client === fixture.client)
                return self.branch(count: count)
            }
            SessionsRuntime.shared.listSessionsForTesting = { client, profile in
                XCTAssertTrue(client === fixture.client)
                XCTAssertFalse(client === fixture.primaryClient)
                XCTAssertEqual(profile, fixture.profile)
                refreshes += 1
                return self.listedSessions
            }
            runtime.openForTesting = { _ in
                throw GatewayError(code: -5, message: "resume timed out")
            }

            fixture.model.branchFromMessage(fixture.target, in: fixture.botID)
            await fixture.model.awaitMessageBranchForTesting(botID: fixture.botID)

            XCTAssertEqual(refreshes, 1)
            XCTAssertEqual(fixture.chat.sessionID, "parent-runtime")
            XCTAssertEqual(fixture.chat.storedSessionID, "parent-stored")
            XCTAssertEqual(fixture.chat.messages, baseline)
            XCTAssertTrue(fixture.chat.storedSessions.contains {
                $0.id == "child-stored"
            })
        }
    }
}
#endif
