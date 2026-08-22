#if canImport(XCTest)
import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class TranscriptRuntimeRemediationTests: XCTestCase {
    func testTranscriptPlansRequireDurableRowAddress() {
        let local = ChatMessage(author: .user, text: "retry")
        XCTAssertNil(TranscriptActing.planRestore([local], from: local.id))
        XCTAssertNil(TranscriptActing.planEdit([local], from: local.id, text: "edited"))

        let durable = ChatMessage(author: .user, text: "retry", rowID: 42)
        let assistant = ChatMessage(author: .bot, text: "answer", rowID: 43)
        XCTAssertEqual(TranscriptActing.planRestore([durable, assistant], from: durable.id)?
            .truncate.rowID, 42)
        XCTAssertEqual(TranscriptActing.planReload([durable, assistant], from: assistant.id)?
            .truncate.rowID, 42)
    }

    func testPromptQueueMirrorRequiresExactQueuedReceipt() {
        XCTAssertTrue(PromptSubmitReceipt.isAuthoritativelyQueued(
            .object(["status": .string("queued")])
        ))
        XCTAssertFalse(PromptSubmitReceipt.isAuthoritativelyQueued(
            .object(["status": .string("streaming")])
        ))
        XCTAssertFalse(PromptSubmitReceipt.isAuthoritativelyQueued(
            .object(["ok": .bool(false), "status": .string("queued")])
        ))
        XCTAssertThrowsError(try PromptSubmitReceipt.requireAccepted(
            .object(["status": .string("unknown")]), operation: "test"))
    }

    @MainActor
    func testQueuedSteerWireAcceptanceDiscardsTicketWhileRedirectAndFallbackMirrorNextTurn() {
        let model = AppModel()
        let botID = "steer-queue-disposition-\(UUID().uuidString)"
        let sessionID = "runtime"
        let previousGatewayID = LiveRuntime.shared.gatewayID
        let chat = model.chat(for: botID)
        chat.sessionID = sessionID
        chat.storedSessionID = "stored"
        chat.isRunning = true
        chat.isTyping = true
        let optimisticSteer = ChatMessage(author: .user, text: "current-turn steer")
        chat.messages = [optimisticSteer]
        LiveRuntime.shared.gatewayID = "queue-disposition-gateway"
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        defer {
            model.promptQueue = []
            ChatRuntime.shared.queuedBindings = [:]
            ChatRuntime.shared.queuedLifecycles = [:]
            ChatRuntime.shared.pendingQueuedSubmissions = [:]
            LiveRuntime.shared.gatewayID = previousGatewayID
        }

        let steerTicket = model.beginQueuedSubmission(botID: botID, sessionID: sessionID)
        XCTAssertEqual(model.settleSteerReceipt(
            steerTicket, text: optimisticSteer.text,
            stage: .steer, status: "queued"), .acceptedCurrentTurn)

        XCTAssertTrue(model.queuedPrompts(for: botID).isEmpty,
                      "session.steer queued means accepted into the current turn")
        XCTAssertTrue(ChatRuntime.shared.pendingQueuedSubmissions.isEmpty)
        XCTAssertEqual(chat.messages.map(\.id), [optimisticSteer.id],
                       "settlement must preserve the optimistic current-turn row")
        XCTAssertTrue(chat.isRunning)
        XCTAssertTrue(chat.isTyping)

        let redirectTicket = model.beginQueuedSubmission(botID: botID, sessionID: sessionID)
        XCTAssertEqual(model.settleSteerReceipt(
            redirectTicket, text: "redirect queued next turn",
            stage: .redirect, status: "queued"), .mirrorNextTurn)
        XCTAssertEqual(model.queuedPrompts(for: botID).map(\.text),
                       ["redirect queued next turn"],
                       "session.redirect queued remains genuine next-turn work")

        let fallbackTicket = model.beginQueuedSubmission(botID: botID, sessionID: sessionID)
        XCTAssertEqual(model.settleSteerReceipt(
            fallbackTicket, text: "explicit queued fallback",
            stage: .queuedSubmit, status: "queued"), .mirrorNextTurn)
        XCTAssertEqual(model.queuedPrompts(for: botID).map(\.text),
                       ["redirect queued next turn", "explicit queued fallback"])
        XCTAssertTrue(ChatRuntime.shared.pendingQueuedSubmissions.isEmpty)
    }

    @MainActor
    func testQueuedMirrorKeepsDuplicateTextByIdentityAndDrainsExactLifecycle() {
        let model = AppModel()
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        model.enqueuePrompt("same", botID: "bot", sessionID: "session-a")
        model.enqueuePrompt("same", botID: "bot", sessionID: "session-a")
        model.enqueuePrompt("same", botID: "bot", sessionID: "session-b")
        XCTAssertEqual(model.promptQueue.count, 3)

        model.markQueuedPromptsEligible(botID: "bot", sessionID: "session-a")
        model.drainStartedQueuedPrompt(botID: "bot", sessionID: "session-b")
        XCTAssertEqual(model.promptQueue.count, 3, "a foreign session start cannot drain")
        model.drainStartedQueuedPrompt(botID: "bot", sessionID: "session-a")
        XCTAssertEqual(model.promptQueue.count, 2, "one start consumes one FIFO entry")

        let dismissed = model.promptQueue[0].id
        model.dismissQueuedPrompt(id: dismissed)
        XCTAssertFalse(model.promptQueue.contains(where: { $0.id == dismissed }))
        XCTAssertNil(ChatRuntime.shared.queuedBindings[dismissed])
        XCTAssertEqual(model.promptQueue.count, 1, "dismiss is local and identity-specific")
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
    }

    @MainActor
    func testQueuedAckAfterCompletionIsEligibleAndAckAfterNextStartDoesNotLagFIFO() {
        let model = AppModel()
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        let firstSubmission = model.beginQueuedSubmission(botID: "bot", sessionID: "session")

        model.noteQueuedPromptCompletion(botID: "bot", sessionID: "session")
        model.acceptQueuedSubmission(firstSubmission, text: "after completion")
        let first = try? XCTUnwrap(model.promptQueue.first?.id)
        XCTAssertEqual(first.flatMap { ChatRuntime.shared.queuedBindings[$0] }?
            .eligibleAfterCurrentTurn, true)

        model.noteQueuedPromptStart(botID: "bot", sessionID: "session")
        model.drainStartedQueuedPrompt(botID: "bot", sessionID: "session")
        XCTAssertTrue(model.promptQueue.isEmpty)

        let next = model.beginQueuedSubmission(botID: "bot", sessionID: "session")
        model.noteQueuedPromptCompletion(botID: "bot", sessionID: "session")
        model.noteQueuedPromptStart(botID: "bot", sessionID: "session")
        model.drainStartedQueuedPrompt(botID: "bot", sessionID: "session")
        model.acceptQueuedSubmission(next, text: "already executing")
        XCTAssertTrue(model.promptQueue.isEmpty,
                      "an ack arriving after completion+start must not recreate an executing item")
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
    }

    @MainActor
    func testExistingQ0StartDoesNotSuppressDelayedQ1Acknowledgement() {
        let model = AppModel()
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        model.enqueuePrompt("Q0", botID: "bot", sessionID: "session")
        model.markQueuedPromptsEligible(botID: "bot", sessionID: "session")
        let delayedQ1 = model.beginQueuedSubmission(botID: "bot", sessionID: "session")

        model.noteQueuedPromptStart(botID: "bot", sessionID: "session")
        model.drainStartedQueuedPrompt(botID: "bot", sessionID: "session")
        model.acceptQueuedSubmission(delayedQ1, text: "Q1")

        XCTAssertEqual(model.promptQueue.map(\.text), ["Q1"])
        XCTAssertEqual(ChatRuntime.shared.pendingQueuedSubmissions.values.flatMap { $0 }.count, 0)
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
    }

    @MainActor
    func testConcurrentQueuedAcknowledgementsPreserveSubmissionOrderAndIdentity() {
        let model = AppModel()
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        let q1 = model.beginQueuedSubmission(botID: "bot", sessionID: "session")
        let q2 = model.beginQueuedSubmission(botID: "bot", sessionID: "session")
        model.noteQueuedPromptCompletion(botID: "bot", sessionID: "session")

        model.acceptQueuedSubmission(q2, text: "Q2")
        model.noteQueuedPromptStart(botID: "bot", sessionID: "session")
        model.drainStartedQueuedPrompt(botID: "bot", sessionID: "session")
        XCTAssertEqual(model.promptQueue.map(\.text), ["Q2"],
                       "the earlier still-pending Q1 owns the first start")
        model.acceptQueuedSubmission(q1, text: "Q1")
        XCTAssertEqual(model.promptQueue.map(\.text), ["Q2"],
                       "Q1 already started before its acknowledgement")
        model.noteQueuedPromptStart(botID: "bot", sessionID: "session")
        model.drainStartedQueuedPrompt(botID: "bot", sessionID: "session")
        XCTAssertTrue(model.promptQueue.isEmpty)
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
    }

    @MainActor
    func testNonqueuedDelayedSubmissionReassignsConsumedStartToNextAcceptedPrompt() {
        let model = AppModel()
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        let delayedQ1 = model.beginQueuedSubmission(botID: "bot", sessionID: "session")
        let q2 = model.beginQueuedSubmission(botID: "bot", sessionID: "session")
        model.noteQueuedPromptCompletion(botID: "bot", sessionID: "session")
        model.acceptQueuedSubmission(q2, text: "Q2")

        model.noteQueuedPromptStart(botID: "bot", sessionID: "session")
        model.drainStartedQueuedPrompt(botID: "bot", sessionID: "session")
        XCTAssertEqual(model.promptQueue.map(\.text), ["Q2"])

        model.discardQueuedSubmission(delayedQ1)
        XCTAssertTrue(model.promptQueue.isEmpty,
                      "Q1's provisional start must transfer to accepted Q2")
        XCTAssertTrue(ChatRuntime.shared.pendingQueuedSubmissions.isEmpty)
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
    }

    @MainActor
    func testConsumedStartTransferCannotCrossReusedRuntimeIntoDifferentStoredSession() {
        let model = AppModel()
        let botID = "worker"
        let sid = "reused-runtime"
        let chat = model.chat(for: botID)
        chat.sessionID = sid
        chat.storedSessionID = "stored-a"
        LiveRuntime.shared.gatewayID = "gateway"
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        let delayedA = model.beginQueuedSubmission(botID: botID, sessionID: sid)

        chat.storedSessionID = "stored-b"
        let acceptedB = model.beginQueuedSubmission(botID: botID, sessionID: sid)
        model.noteQueuedPromptCompletion(botID: botID, sessionID: sid)
        model.acceptQueuedSubmission(acceptedB, text: "B")

        chat.storedSessionID = "stored-a"
        model.noteQueuedPromptStart(botID: botID, sessionID: sid)
        model.drainStartedQueuedPrompt(botID: botID, sessionID: sid)
        model.discardQueuedSubmission(delayedA)

        XCTAssertEqual(model.promptQueue.map(\.text), ["B"])
        let remaining = try? XCTUnwrap(model.promptQueue.first?.id)
        XCTAssertEqual(remaining.flatMap { ChatRuntime.shared.queuedBindings[$0]?.storedID },
                       "stored-b")
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        LiveRuntime.shared.gatewayID = nil
    }

    @MainActor
    func testCanonicalKickoffRollbackKeepsNamedSessionBoundForRetry() {
        let model = AppModel()
        let botID = "bot"
        let chat = ChatState()
        let row = ChatMessage(author: .user, text: "kickoff")
        chat.messages = [row]
        chat.sessionID = "runtime-a"
        chat.storedSessionID = "stored-a"
        chat.isRunning = true
        model.chats[botID] = chat

        let lease = CanonicalKickoffLease(
            id: UUID(), botID: botID, sessionID: "runtime-a", storedID: "stored-a",
            rowID: row.id, chatID: ObjectIdentifier(chat))
        CanonicalChatRuntime.shared.kickoffs[botID] = lease.id
        model.rollbackCanonicalKickoffIfOwned(lease)
        XCTAssertEqual(chat.sessionID, "runtime-a")
        XCTAssertEqual(chat.storedSessionID, "stored-a")
        XCTAssertFalse(chat.isRunning)
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertNil(CanonicalChatRuntime.shared.kickoffs[botID])
    }

    @MainActor
    func testCanonicalKickoffClaimBeforeAdoptionCanBeCancelledWithoutLeakingOwner() {
        let model = AppModel()
        let botID = "pre-adopt"
        let chat = model.chat(for: botID)
        let lease = CanonicalKickoffLease(
            id: UUID(), botID: botID, sessionID: "runtime", storedID: "stored",
            rowID: nil, chatID: ObjectIdentifier(chat), submitStarted: false)
        CanonicalChatRuntime.shared.kickoffs[botID] = lease.id

        XCTAssertTrue(model.rollbackCanonicalKickoffIfOwned(lease))
        XCTAssertNil(CanonicalChatRuntime.shared.kickoffs[botID])
        XCTAssertNil(chat.sessionID)
        XCTAssertTrue(chat.messages.isEmpty)
    }

    @MainActor
    func testKickoffRetirementRequiresExactOperationIdentityAndDurableOwner() {
        let botID = "retire-kickoff"
        let route = GatewayBotRoute(gatewayID: "gateway", profile: botID)
        let chat = ChatState()
        chat.storedSessionID = "stored-a"
        let owner = CanonicalKickoffLease(
            id: UUID(), botID: botID, sessionID: "runtime-a", storedID: "stored-a",
            rowID: nil, chatID: ObjectIdentifier(chat), route: route)
        let foreign = UUID()
        CanonicalChatRuntime.shared.kickoffs[botID] = owner.id
        CanonicalChatRuntime.shared.kickoffLeases[botID] = owner
        defer {
            CanonicalChatRuntime.shared.kickoffs[botID] = nil
            CanonicalChatRuntime.shared.kickoffLeases[botID] = nil
            CanonicalChatRuntime.shared.ambiguousKickoffs[botID] = nil
        }

        XCTAssertFalse(CanonicalChatRuntime.shared.retireKickoff(
            botID: botID, route: route, storedID: "stored-a",
            chatID: ObjectIdentifier(chat), operationID: foreign))
        XCTAssertEqual(CanonicalChatRuntime.shared.kickoffs[botID], owner.id)
        XCTAssertFalse(CanonicalChatRuntime.shared.retireKickoff(
            botID: botID, route: route, storedID: nil,
            chatID: ObjectIdentifier(chat), operationID: owner.id))
        XCTAssertTrue(CanonicalChatRuntime.shared.retireKickoff(
            botID: botID, route: route, storedID: "stored-a",
            chatID: ObjectIdentifier(chat), operationID: owner.id))
        XCTAssertNil(CanonicalChatRuntime.shared.kickoffs[botID])
    }

    @MainActor
    func testRenamedQueueParksOldSIDUntilDestinationBindMigratesIt() {
        let model = AppModel()
        let gatewayID = "queue-rename"
        let oldRoute = GatewayBotRoute(gatewayID: gatewayID, profile: "worker")
        let destinationRoute = GatewayBotRoute(gatewayID: gatewayID, profile: "renamed")
        let source = ChatState()
        source.sessionID = "runtime-old"
        source.storedSessionID = "stored"
        model.chats[oldRoute.qualifiedID] = source
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings.removeAll()
        ChatRuntime.shared.queuedLifecycles.removeAll()
        ChatRuntime.shared.pendingQueuedSubmissions.removeAll()
        LiveRuntime.shared.gatewayID = gatewayID
        let rowID = UUID()
        model.promptQueue = [(id: rowID, botID: oldRoute.qualifiedID, text: "queued")]
        ChatRuntime.shared.queuedBindings[rowID] = QueuedPromptBinding(
            botID: oldRoute.qualifiedID, sessionID: "runtime-old", storedID: "stored",
            route: oldRoute, eligibleAfterCurrentTurn: true, order: 1)
        defer {
            model.chats.removeAll()
            model.promptQueue.removeAll()
            ChatRuntime.shared.queuedBindings.removeAll()
            ChatRuntime.shared.queuedLifecycles.removeAll()
            ChatRuntime.shared.pendingQueuedSubmissions.removeAll()
            LiveRuntime.shared.reconnectParkedSessionIDs[destinationRoute.qualifiedID] = nil
            LiveRuntime.shared.sessionToBot.removeAll()
            LiveRuntime.shared.routedSessionToBot.removeAll()
            LiveRuntime.shared.gatewayID = nil
        }

        ChatRuntime.shared.migrateProfileRouteState(
            from: oldRoute, to: destinationRoute,
            sourceBotID: oldRoute.qualifiedID,
            destinationBotID: destinationRoute.qualifiedID,
            storedID: "stored", chatID: ObjectIdentifier(source),
            sessionID: "runtime-old")
        model.promptQueue[0].botID = destinationRoute.qualifiedID
        model.chats.removeValue(forKey: oldRoute.qualifiedID)
        model.chats[destinationRoute.qualifiedID] = source
        source.sessionID = nil
        LiveRuntime.shared.reconnectParkedSessionIDs[destinationRoute.qualifiedID] = "runtime-old"

        model.adopt(LiveSession(.object([
            "session_id": .string("runtime-new"),
            "stored_session_id": .string("stored"),
        ])), storedID: "stored", botID: destinationRoute.qualifiedID,
        sourceGatewayID: gatewayID)

        XCTAssertEqual(ChatRuntime.shared.queuedBindings[rowID]?.sessionID, "runtime-new")
        XCTAssertEqual(ChatRuntime.shared.queuedBindings[rowID]?.route, destinationRoute)
        XCTAssertEqual(model.promptQueue.first?.botID, destinationRoute.qualifiedID)
        XCTAssertNil(LiveRuntime.shared.reconnectParkedSessionIDs[destinationRoute.qualifiedID])
    }

    @MainActor
    func testLifecycleRenameKeepsParkedPrimarySIDAndStopFence() {
        let model = AppModel()
        let gatewayID = "lifecycle-stop-(UUID().uuidString)"
        let route = GatewayBotRoute(gatewayID: gatewayID, profile: "worker")
        let chat = ChatState()
        chat.storedSessionID = "stored"
        chat.sessionID = "runtime-old"
        model.chats["worker"] = chat
        LiveRuntime.shared.gatewayID = gatewayID
        LiveRuntime.shared.reconnectParkedSessionIDs[route.qualifiedID] = "runtime-old"
        let stop = StopTurnFence(operationID: UUID(), botID: "worker", route: route,
                                 sessionID: "runtime-old", storedID: "stored",
                                 chatID: ObjectIdentifier(chat))
        ChatRuntime.shared.stopFences["worker"] = stop
        defer {
            ChatRuntime.shared.stopFences.removeAll()
            model.chats.removeAll()
            LiveRuntime.shared.reconnectParkedSessionIDs.removeAll()
            LiveRuntime.shared.gatewayID = nil
        }

        model.parkProfileLifecycleState(
            ProfileLifecycleTarget(rosterID: "worker", route: route))
        model.abortProfileRuntime(
            ProfileLifecycleTarget(rosterID: "worker", route: route),
            preservePendingStop: true, preserveQueuedState: true)

        XCTAssertEqual(LiveRuntime.shared.reconnectParkedSessionIDs[route.qualifiedID],
                       "runtime-old")
        XCTAssertEqual(ChatRuntime.shared.stopFences[route.qualifiedID]?.storedID,
                       "stored")
    }

    @MainActor
    func testDeliberatePrimaryResetRetiresAmbiguousKickoff() {
        let botID = "worker-reset-(UUID().uuidString)"
        let chat = ChatState()
        chat.storedSessionID = "stored"
        let lease = CanonicalKickoffLease(
            id: UUID(), botID: botID, sessionID: "runtime", storedID: "stored",
            rowID: nil, chatID: ObjectIdentifier(chat))
        let runtime = CanonicalChatRuntime.shared
        runtime.kickoffs[botID] = lease.id
        runtime.kickoffLeases[botID] = lease
        runtime.ambiguousKickoffs[botID] = lease
        defer {
            runtime.kickoffs[botID] = nil
            runtime.kickoffLeases[botID] = nil
            runtime.ambiguousKickoffs[botID] = nil
        }

        runtime.resetPrimaryScope()
        XCTAssertNil(runtime.ambiguousKickoffs[botID])
        runtime.resetPrimaryScope(retainAmbiguousForReconnect: true, retainLocalPins: true)
        XCTAssertNil(runtime.ambiguousKickoffs[botID])
    }

    @MainActor
    func testLifecycleAbortRestoresPreAcceptTranscriptProjection() {
        let model = AppModel()
        let route = GatewayBotRoute(gatewayID: "abort", profile: "worker")
        LiveRuntime.shared.gatewayID = route.gatewayID
        let chat = model.chat(for: route.profile)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let baseline = ChatMessage(author: .user, text: "before", rowID: 1)
        let optimistic = ChatMessage(author: .user, text: "replacement")
        chat.messages = [baseline, optimistic]
        let lease = TranscriptActionLease(
            id: UUID(), botID: route.profile, sessionID: "runtime", storedID: "stored",
            gatewayID: route.gatewayID, profile: route.profile,
            generation: LiveRuntime.shared.generation, chatID: ObjectIdentifier(chat),
            optimisticID: optimistic.id, baseline: [baseline])
        ChatRuntime.shared.transcriptActions[route.profile] = lease.id
        ChatRuntime.shared.transcriptActionGenerations[route.profile] = lease.generation
        ChatRuntime.shared.transcriptLeases[route.profile] = lease
        defer {
            ChatRuntime.shared.transcriptActions.removeAll()
            ChatRuntime.shared.transcriptActionGenerations.removeAll()
            ChatRuntime.shared.transcriptLeases.removeAll()
            ChatRuntime.shared.transcriptFences.removeAll()
            model.chats.removeAll()
            LiveRuntime.shared.gatewayID = nil
        }

        model.abortProfileRuntime(ProfileLifecycleTarget(rosterID: route.profile, route: route))

        XCTAssertEqual(chat.messages, [baseline])
        XCTAssertNil(ChatRuntime.shared.transcriptFences[route.profile])
        XCTAssertNil(ChatRuntime.shared.transcriptActions[route.profile])
    }

    @MainActor
    func testLifecycleAbortRetainsAcceptedTranscriptAmbiguityAsFence() {
        let model = AppModel()
        let route = GatewayBotRoute(gatewayID: "abort-ambiguous", profile: "worker")
        LiveRuntime.shared.gatewayID = route.gatewayID
        let chat = model.chat(for: route.profile)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let baseline = ChatMessage(author: .user, text: "before", rowID: 1)
        let optimistic = ChatMessage(author: .user, text: "replacement")
        chat.messages = [baseline, optimistic]
        let lease = TranscriptActionLease(
            id: UUID(), botID: route.profile, sessionID: "runtime", storedID: "stored",
            gatewayID: route.gatewayID, profile: route.profile,
            generation: LiveRuntime.shared.generation, chatID: ObjectIdentifier(chat),
            optimisticID: optimistic.id, baseline: [baseline], submitStarted: true)
        ChatRuntime.shared.transcriptActions[route.profile] = lease.id
        ChatRuntime.shared.transcriptActionGenerations[route.profile] = lease.generation
        ChatRuntime.shared.transcriptLeases[route.profile] = lease
        defer {
            ChatRuntime.shared.transcriptActions.removeAll()
            ChatRuntime.shared.transcriptActionGenerations.removeAll()
            ChatRuntime.shared.transcriptLeases.removeAll()
            ChatRuntime.shared.transcriptFences.removeAll()
            model.chats.removeAll()
            LiveRuntime.shared.gatewayID = nil
        }

        model.abortProfileRuntime(ProfileLifecycleTarget(rosterID: route.profile, route: route))

        XCTAssertEqual(ChatRuntime.shared.transcriptFences[route.profile]?.operationID, lease.id)
        XCTAssertEqual(chat.messages, [baseline, optimistic],
                       "accepted-unknown work must not roll back its optimistic evidence")
        XCTAssertNil(ChatRuntime.shared.transcriptActions[route.profile])
    }

    @MainActor
    func testLifecycleAbortRestoresPreAcceptSteerProjection() {
        let model = AppModel()
        let route = GatewayBotRoute(gatewayID: "abort-steer", profile: "worker")
        LiveRuntime.shared.gatewayID = route.gatewayID
        let chat = model.chat(for: route.profile)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        chat.isRunning = true
        let baseline = ChatMessage(author: .bot, text: "thinking", isStreaming: true)
        let optimistic = ChatMessage(author: .user, text: "correction")
        chat.messages = [baseline, optimistic]
        let lease = SteerMutationLease(
            id: UUID(), botID: route.profile, route: route, sessionID: "runtime",
            storedID: "stored", chatID: ObjectIdentifier(chat), optimisticID: optimistic.id,
            text: "correction", baselineMessages: [baseline], baselineIsRunning: true)
        ChatRuntime.shared.steerActions[route.profile] = lease
        defer {
            ChatRuntime.shared.steerActions.removeAll()
            ChatRuntime.shared.steerFences.removeAll()
            model.chats.removeAll()
            LiveRuntime.shared.gatewayID = nil
        }

        model.abortProfileRuntime(ProfileLifecycleTarget(rosterID: route.profile, route: route))

        XCTAssertEqual(chat.messages, [baseline])
        XCTAssertNil(ChatRuntime.shared.steerActions[route.profile])
        XCTAssertNil(ChatRuntime.shared.steerFences[route.profile])
    }

    @MainActor
    func testLifecycleAbortRetainsAcceptedSteerAmbiguityAsFence() {
        let model = AppModel()
        let route = GatewayBotRoute(gatewayID: "abort-steer-ambiguous", profile: "worker")
        LiveRuntime.shared.gatewayID = route.gatewayID
        let chat = model.chat(for: route.profile)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        chat.isRunning = true
        let baseline = ChatMessage(author: .bot, text: "thinking", isStreaming: true)
        let optimistic = ChatMessage(author: .user, text: "correction")
        chat.messages = [baseline, optimistic]
        let lease = SteerMutationLease(
            id: UUID(), botID: route.profile, route: route, sessionID: "runtime",
            storedID: "stored", chatID: ObjectIdentifier(chat), optimisticID: optimistic.id,
            text: "correction", requestStarted: true,
            baselineMessages: [baseline], baselineIsRunning: true)
        ChatRuntime.shared.steerActions[route.profile] = lease
        defer {
            ChatRuntime.shared.steerActions.removeAll()
            ChatRuntime.shared.steerFences.removeAll()
            model.chats.removeAll()
            LiveRuntime.shared.gatewayID = nil
        }

        model.abortProfileRuntime(ProfileLifecycleTarget(rosterID: route.profile, route: route))

        XCTAssertEqual(ChatRuntime.shared.steerFences[route.profile]?.operationID, lease.id)
        var stoppedBaseline = baseline
        stoppedBaseline.isStreaming = false
        XCTAssertEqual(chat.messages, [stoppedBaseline, optimistic])
        XCTAssertNil(ChatRuntime.shared.steerActions[route.profile])
    }

    @MainActor
    func testLiveSendRetainsOptimisticRowWhenMutationFenceOwnsBinding() async {
        let model = AppModel()
        model.mode = .live
        let botID = "send-fenced::worker"
        let chat = model.chat(for: botID)
        let row = ChatMessage(author: .user, text: "must survive")
        chat.messages = [row]
        ChatRuntime.shared.transcriptFences[botID] = TranscriptActionFence(
            operationID: UUID(), sessionID: "runtime", storedID: "stored",
            gatewayID: "send-fenced", profile: "worker", generation: 0,
            chatID: ObjectIdentifier(chat))
        defer {
            ChatRuntime.shared.transcriptFences.removeAll()
            model.chats.removeAll()
        }

        let result = await model.liveSendAwaiting(
            text: row.text, botID: botID, chat: chat, optimisticID: row.id)

        XCTAssertEqual(result, .retained)
        XCTAssertEqual(chat.messages, [row])
    }

    @MainActor
    func testOfflineFlushKeepsRowsWhenChatOwnerIsAbsent() async {
        let model = AppModel()
        model.mode = .live
        model.composeQueue = [(botID: "missing-chat", text: "keep me")]

        await model.flushComposeQueue()

        XCTAssertEqual(model.composeQueue.map(\.botID), ["missing-chat"])
        XCTAssertEqual(model.composeQueue.map(\.text), ["keep me"])
    }

    @MainActor
    func testCanonicalTapReconcilesKickoffAcceptanceByExactOwner() async {
        let model = AppModel()
        let botID = "bot"
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let lease = CanonicalKickoffLease(
            id: UUID(), botID: botID, sessionID: "runtime", storedID: "stored",
            rowID: nil, chatID: ObjectIdentifier(chat), submitStarted: true)
        CanonicalChatRuntime.shared.kickoffs[botID] = lease.id
        CanonicalChatRuntime.shared.ambiguousKickoffs[botID] = lease
        XCTAssertEqual(model.ambiguousCanonicalKickoffOwning(botID: botID, chat: chat), lease)

        var didResume = false
        var didHydrate = false
        let authoritativeKickoff = ChatMessage(
            author: .user, text: AppModel.canonicalKickoffPrompt, rowID: 1)
        let authoritative = ChatMessage(author: .bot, text: "authoritative intro", rowID: 2)
        await model.reconcileAmbiguousCanonicalKickoff(
            lease, sourceGatewayID: "gateway",
            resume: {
                didResume = true
                return LiveSession(.object([
                    "session_id": .string("runtime"),
                    "stored_session_id": .string("stored"),
                ]))
            },
            hydrate: { _ in
                didHydrate = true
                chat.messages = [authoritativeKickoff, authoritative]
            },
            accepts: { true })

        XCTAssertTrue(didResume)
        XCTAssertTrue(didHydrate)
        XCTAssertEqual(chat.messages, [authoritativeKickoff, authoritative])
        XCTAssertNil(CanonicalChatRuntime.shared.kickoffs[botID])
        XCTAssertNil(CanonicalChatRuntime.shared.ambiguousKickoffs[botID])
    }

    @MainActor
    func testAmbiguousKickoffKeepsFenceAfterEmptyHydration() async {
        let model = AppModel()
        let botID = "bot-empty-hydration"
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let historical = ChatMessage(
            author: .user, text: AppModel.canonicalKickoffPrompt, rowID: 42)
        chat.messages = [historical]
        let lease = CanonicalKickoffLease(
            id: UUID(), botID: botID, sessionID: "runtime", storedID: "stored",
            rowID: nil, chatID: ObjectIdentifier(chat), submitStarted: true,
            baselineDurableRowIDs: [42], baselineDurableRowCount: 1)
        CanonicalChatRuntime.shared.kickoffs[botID] = lease.id
        CanonicalChatRuntime.shared.ambiguousKickoffs[botID] = lease

        await model.reconcileAmbiguousCanonicalKickoff(
            lease, sourceGatewayID: "gateway",
            resume: {
                LiveSession(.object([
                    "session_id": .string("runtime"),
                    "stored_session_id": .string("stored"),
                ]))
            },
            hydrate: { _ in chat.messages = [] },
            accepts: { true })

        XCTAssertEqual(CanonicalChatRuntime.shared.kickoffs[botID], lease.id)
        XCTAssertEqual(CanonicalChatRuntime.shared.ambiguousKickoffs[botID], lease)
        CanonicalChatRuntime.shared.kickoffs[botID] = nil
        CanonicalChatRuntime.shared.ambiguousKickoffs[botID] = nil
    }

    @MainActor
    func testAmbiguousKickoffRequiresCompleteBaselineIDsAndOperationSpecificInflight() async {
        let model = AppModel()
        let botID = "canonical-adversarial-evidence"
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let prompt = AppModel.canonicalKickoffPrompt
        let historical = ChatMessage(author: .user, text: prompt, rowID: 42)
        chat.messages = [historical]
        let lease = CanonicalKickoffLease(
            id: UUID(), botID: botID, sessionID: "runtime", storedID: "stored",
            rowID: nil, chatID: ObjectIdentifier(chat), submitStarted: true,
            baselineDurableRowIDs: [42, 43], baselineDurableRowCount: 2,
            baselineDurableUserTexts: [prompt])
        CanonicalChatRuntime.shared.kickoffs[botID] = lease.id
        CanonicalChatRuntime.shared.ambiguousKickoffs[botID] = lease

        let staleReplacement = LiveSession(.object([
            "session_id": .string("runtime"),
            "stored_session_id": .string("stored"),
            "messages": [[
                "role": .string("user"), "text": .string(prompt),
                "row_id": .number(91),
            ], [
                "role": .string("assistant"), "text": .string("other"),
                "row_id": .number(92),
            ]],
        ]))
        await model.reconcileAmbiguousCanonicalKickoff(
            lease, sourceGatewayID: "gateway",
            resume: { staleReplacement },
            hydrate: { live in
                chat.messages = AppModel.chatMessages(fromTranscript: .array(live.messages))
            },
            accepts: { true })
        XCTAssertEqual(CanonicalChatRuntime.shared.ambiguousKickoffs[botID], lease)

        let duplicateInflight = LiveSession(.object([
            "session_id": .string("runtime"),
            "stored_session_id": .string("stored"),
            "inflight": ["user": .string(prompt)],
            "messages": [[
                "role": .string("user"), "text": .string(prompt),
                "row_id": .number(42),
            ], [
                "role": .string("assistant"), "text": .string("other"),
                "row_id": .number(43),
            ]],
        ]))
        await model.reconcileAmbiguousCanonicalKickoff(
            lease, sourceGatewayID: "gateway",
            resume: { duplicateInflight },
            hydrate: { live in
                chat.messages = AppModel.chatMessages(fromTranscript: .array(live.messages))
            },
            accepts: { true })
        XCTAssertEqual(CanonicalChatRuntime.shared.ambiguousKickoffs[botID], lease,
                       "a preexisting same-text inflight body cannot settle kickoff")

        let accepted = LiveSession(.object([
            "session_id": .string("runtime"),
            "stored_session_id": .string("stored"),
            "messages": [[
                "role": .string("user"), "text": .string("old"),
                "row_id": .number(42),
            ], [
                "role": .string("assistant"), "text": .string("old answer"),
                "row_id": .number(43),
            ], [
                "role": .string("user"), "text": .string(prompt),
                "row_id": .number(91),
            ]],
        ]))
        await model.reconcileAmbiguousCanonicalKickoff(
            lease, sourceGatewayID: "gateway",
            resume: { accepted },
            hydrate: { live in
                chat.messages = AppModel.chatMessages(fromTranscript: .array(live.messages))
            },
            accepts: { true })
        XCTAssertNil(CanonicalChatRuntime.shared.kickoffs[botID])
        XCTAssertNil(CanonicalChatRuntime.shared.ambiguousKickoffs[botID])
    }

    @MainActor
    func testAmbiguousKickoffRejectsMismatchedDurableResumeIdentity() async {
        let model = AppModel()
        let botID = "bot-mismatch"
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime-old"
        chat.storedSessionID = "stored-owned"
        let lease = CanonicalKickoffLease(
            id: UUID(), botID: botID, sessionID: "runtime-old", storedID: "stored-owned",
            rowID: nil, chatID: ObjectIdentifier(chat), submitStarted: true)
        CanonicalChatRuntime.shared.kickoffs[botID] = lease.id
        CanonicalChatRuntime.shared.ambiguousKickoffs[botID] = lease
        var didHydrate = false

        await model.reconcileAmbiguousCanonicalKickoff(
            lease, sourceGatewayID: "gateway",
            resume: {
                LiveSession(.object([
                    "session_id": .string("runtime-rotated"),
                    "stored_session_id": .string("stored-foreign"),
                ]))
            },
            hydrate: { _ in didHydrate = true },
            accepts: { true })

        XCTAssertFalse(didHydrate)
        XCTAssertEqual(chat.sessionID, "runtime-old")
        XCTAssertEqual(chat.storedSessionID, "stored-owned")
        XCTAssertEqual(CanonicalChatRuntime.shared.kickoffs[botID], lease.id)
        XCTAssertEqual(CanonicalChatRuntime.shared.ambiguousKickoffs[botID], lease)
        CanonicalChatRuntime.shared.kickoffs[botID] = nil
        CanonicalChatRuntime.shared.ambiguousKickoffs[botID] = nil
    }

    @MainActor
    func testReconnectGenerationDoesNotPruneAmbiguousTranscriptFence() {
        let botID = "fenced"
        let fence = TranscriptActionFence(
            operationID: UUID(), sessionID: "runtime", storedID: "stored",
            gatewayID: "gateway", profile: "profile", generation: 10)
        ChatRuntime.shared.transcriptFences[botID] = fence
        ChatRuntime.shared.pruneTranscriptState(botID: botID, generation: 11)
        XCTAssertEqual(ChatRuntime.shared.transcriptFences[botID], fence)
        XCTAssertFalse(fence.acceptsAuthoritativeHydration(
            gatewayID: "other", profile: "profile", storedID: "stored",
            generation: 11, currentGeneration: 11))
        XCTAssertFalse(fence.acceptsAuthoritativeHydration(
            gatewayID: "gateway", profile: "profile", storedID: "stored",
            generation: 10, currentGeneration: 11))
        XCTAssertTrue(fence.acceptsAuthoritativeHydration(
            gatewayID: "gateway", profile: "profile", storedID: "stored",
            generation: 11, currentGeneration: 11))
        ChatRuntime.shared.transcriptFences[botID] = nil
    }

    @MainActor
    func testLateSubmitResultAfterGenerationChangeFencesSameDurableTarget() {
        let model = AppModel()
        let botID = "gateway::worker"
        let chat = model.chat(for: botID)
        chat.sessionID = "new-runtime"
        chat.storedSessionID = "stored"
        let lease = TranscriptActionLease(
            id: UUID(), botID: botID, sessionID: "old-runtime", storedID: "stored",
            gatewayID: "gateway", profile: "worker", generation: 10,
            chatID: ObjectIdentifier(chat), optimisticID: UUID(), baseline: [])

        model.fenceTranscriptActionIfDurableTargetStillOwned(lease)

        XCTAssertEqual(ChatRuntime.shared.transcriptFences[botID]?.operationID, lease.id)
        XCTAssertEqual(ChatRuntime.shared.transcriptFences[botID]?.storedID, "stored")
        ChatRuntime.shared.transcriptFences[botID] = nil
    }

    @MainActor
    func testAdoptRetiresDifferentStoredFenceAndUnroutesOldRuntimeSID() {
        let model = AppModel()
        let botID = "worker"
        let chat = model.chat(for: botID)
        chat.sessionID = "old-runtime"
        chat.storedSessionID = "old-stored"
        LiveRuntime.shared.gatewayID = "gateway"
        LiveRuntime.shared.sessionToBot["old-runtime"] = botID
        ChatRuntime.shared.transcriptFences[botID] = TranscriptActionFence(
            operationID: UUID(), sessionID: "old-runtime", storedID: "old-stored",
            gatewayID: "gateway", profile: botID,
            generation: LiveRuntime.shared.generation)
        let live = LiveSession(.object([
            "session_id": .string("new-runtime"),
            "stored_session_id": .string("new-stored"),
        ]))

        model.adopt(live, storedID: "new-stored", botID: botID,
                    sourceGatewayID: "gateway")

        XCTAssertNil(LiveRuntime.shared.sessionToBot["old-runtime"])
        XCTAssertEqual(LiveRuntime.shared.sessionToBot["new-runtime"], botID)
        XCTAssertNil(ChatRuntime.shared.transcriptFences[botID])
        LiveRuntime.shared.sessionToBot["new-runtime"] = nil
        LiveRuntime.shared.gatewayID = nil
    }

    @MainActor
    func testStopQueueCleanupPredicateIsExactInterruptedSession() {
        let model = AppModel()
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        model.enqueuePrompt("old", botID: "bot", sessionID: "session-old")
        model.enqueuePrompt("current", botID: "bot", sessionID: "session-current")
        model.removeQueuedPrompts(botID: "bot", sessionID: "session-current")
        XCTAssertEqual(model.promptQueue.map(\.text), ["old"])
        XCTAssertEqual(ChatRuntime.shared.queuedBindings[model.promptQueue[0].id]?.sessionID,
                       "session-old")
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
    }

    @MainActor
    func testStopApprovalCleanupRequiresExactProfileBotAndDurableSession() {
        let model = AppModel()
        let gateway = "gateway"
        let sid = "colliding-runtime"
        let botA = "gateway::alpha"
        let botB = "gateway::beta"
        let routeA = GatewayBotRoute(gatewayID: gateway, profile: "alpha")
        let routeB = GatewayBotRoute(gatewayID: gateway, profile: "beta")
        let chat = model.chat(for: botA)
        chat.sessionID = "replacement"
        chat.storedSessionID = "stored-replacement"
        let lease = StopTurnLease(
            botID: botA, route: routeA, sessionID: sid,
            storedID: "stored-a", chatID: ObjectIdentifier(chat))
        let targets: [(String, ApprovalResponseTarget)] = [
            ("exact", ApprovalResponseTarget(
                bot: routeA, session: GatewaySessionRoute(gatewayID: gateway, sessionID: sid),
                requestID: "exact", storedID: "stored-a", botID: botA)),
            ("other-profile", ApprovalResponseTarget(
                bot: routeB, session: GatewaySessionRoute(gatewayID: gateway, sessionID: sid),
                requestID: "other-profile", storedID: "stored-a", botID: botB)),
            ("other-stored", ApprovalResponseTarget(
                bot: routeA, session: GatewaySessionRoute(gatewayID: gateway, sessionID: sid),
                requestID: "other-stored", storedID: "stored-b", botID: botA)),
        ]
        for (id, target) in targets { LiveRuntime.shared.approvalTargets[id] = target }
        model.approvals = targets.map { id, target in
            Approval(id: id, botID: target.bot == routeA ? botA : botB, kind: .command,
                     title: id, target: "", subject: "", body: "", why: "", age: "now")
        }
        ApprovalBridges.shared.prompts = [
            BlockingPrompt(kind: .clarify, gatewayID: gateway, requestID: "exact",
                           sessionID: sid, botID: botA, question: "A",
                           profile: "alpha", storedID: "stored-a"),
            BlockingPrompt(kind: .clarify, gatewayID: gateway, requestID: "other-profile",
                           sessionID: sid, botID: botB, question: "B",
                           profile: "beta", storedID: "stored-a"),
            BlockingPrompt(kind: .clarify, gatewayID: gateway, requestID: "other-stored",
                           sessionID: sid, botID: botA, question: "C",
                           profile: "alpha", storedID: "stored-b"),
        ]

        model.applyStopCompletion(lease, note: "Stopped")

        XCTAssertNil(LiveRuntime.shared.approvalTargets["exact"])
        XCTAssertNotNil(LiveRuntime.shared.approvalTargets["other-profile"])
        XCTAssertNotNil(LiveRuntime.shared.approvalTargets["other-stored"])
        XCTAssertEqual(Set(model.approvals.map(\.id)), ["other-profile", "other-stored"])
        XCTAssertEqual(Set(ApprovalBridges.shared.prompts.map(\.requestID)),
                       ["other-profile", "other-stored"])
        for (id, _) in targets { LiveRuntime.shared.approvalTargets[id] = nil }
        model.approvals = []
        ApprovalBridges.shared.prompts = []
    }

    @MainActor
    func testStopCleanupDoesNotCrossGatewayWithCollidingRuntimeSessionID() {
        let model = AppModel()
        let botID = "worker"
        let chat = model.chat(for: botID)
        chat.sessionID = "same-runtime"
        chat.storedSessionID = "stored-a"
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        LiveRuntime.shared.gatewayID = "gateway-a"
        model.enqueuePrompt("A", botID: botID, sessionID: "same-runtime")
        let lateA = model.beginQueuedSubmission(botID: botID, sessionID: "same-runtime")
        let routeA = GatewayBotRoute(gatewayID: "gateway-a", profile: botID)
        let routeB = GatewayBotRoute(gatewayID: "gateway-b", profile: botID)
        let lease = StopTurnLease(
            botID: botID, route: routeA, sessionID: "same-runtime",
            storedID: "stored-a", chatID: ObjectIdentifier(chat))

        LiveRuntime.shared.gatewayID = "gateway-b"
        chat.storedSessionID = "stored-b"
        model.enqueuePrompt("B", botID: botID, sessionID: "same-runtime")
        LiveRuntime.shared.approvalTargets["approval-a"] = ApprovalResponseTarget(
            bot: routeA,
            session: GatewaySessionRoute(gatewayID: "gateway-a", sessionID: "same-runtime"),
            requestID: "a", storedID: "stored-a", botID: botID)
        LiveRuntime.shared.approvalTargets["approval-b"] = ApprovalResponseTarget(
            bot: routeB,
            session: GatewaySessionRoute(gatewayID: "gateway-b", sessionID: "same-runtime"),
            requestID: "b", storedID: "stored-b", botID: botID)
        model.approvals = [
            Approval(id: "approval-a", botID: botID, kind: .command, title: "A", target: "",
                     subject: "", body: "", why: "", age: "now"),
            Approval(id: "approval-b", botID: botID, kind: .command, title: "B", target: "",
                     subject: "", body: "", why: "", age: "now"),
        ]
        model.applyStopCompletion(lease, note: "Stopped A")
        model.acceptQueuedSubmission(lateA, text: "late A")

        XCTAssertEqual(model.promptQueue.map(\.text), ["B"])
        let remaining = try? XCTUnwrap(model.promptQueue.first?.id)
        XCTAssertEqual(remaining.flatMap { ChatRuntime.shared.queuedBindings[$0]?.route?.gatewayID },
                       "gateway-b")
        XCTAssertNil(LiveRuntime.shared.approvalTargets["approval-a"])
        XCTAssertNotNil(LiveRuntime.shared.approvalTargets["approval-b"])
        XCTAssertEqual(model.approvals.map(\.id), ["approval-b"])
        XCTAssertEqual(chat.messages.filter { $0.text == "Stopped A" }.count, 0)
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        LiveRuntime.shared.approvalTargets["approval-b"] = nil
        model.approvals = []
        LiveRuntime.shared.gatewayID = nil
    }

    @MainActor
    func testDelayedStopCompletionCannotMutateReplacementSession() async {
        let model = AppModel()
        let botID = "gateway::worker"
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime-a"
        chat.storedSessionID = "stored-a"
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        model.enqueuePrompt("queued for A", botID: botID, sessionID: "runtime-a")
        let lateA = model.beginQueuedSubmission(botID: botID, sessionID: "runtime-a")
        model.enqueuePrompt("queued for B", botID: botID, sessionID: "runtime-b")
        let route = GatewayBotRoute(gatewayID: "gateway", profile: "worker")
        let approvalA = "gateway::approval-a"
        let approvalB = "gateway::approval-b"
        LiveRuntime.shared.approvalTargets[approvalA] = ApprovalResponseTarget(
            bot: route,
            session: GatewaySessionRoute(gatewayID: "gateway", sessionID: "runtime-a"),
            requestID: "approval-a", storedID: "stored-a", botID: botID)
        LiveRuntime.shared.approvalTargets[approvalB] = ApprovalResponseTarget(
            bot: route,
            session: GatewaySessionRoute(gatewayID: "gateway", sessionID: "runtime-b"),
            requestID: "approval-b", storedID: "stored-b", botID: botID)
        model.approvals = [
            Approval(id: approvalA, botID: botID, kind: .command, title: "A", target: "",
                     subject: "", body: "", why: "", age: "now"),
            Approval(id: approvalB, botID: botID, kind: .command, title: "B", target: "",
                     subject: "", body: "", why: "", age: "now"),
        ]
        ApprovalBridges.shared.prompts = [
            BlockingPrompt(kind: .clarify, gatewayID: "gateway", requestID: "ticket-a",
                           sessionID: "runtime-a", botID: botID, question: "A?",
                           profile: "worker", storedID: "stored-a"),
            BlockingPrompt(kind: .clarify, gatewayID: "gateway", requestID: "ticket-b",
                           sessionID: "runtime-b", botID: botID, question: "B?",
                           profile: "worker", storedID: "stored-b"),
        ]
        let lease = StopTurnLease(
            botID: botID, route: route,
            sessionID: "runtime-a", storedID: "stored-a",
            chatID: ObjectIdentifier(chat))
        let gate = TranscriptStopBarrier()
        let delayed = Task { @MainActor in
            _ = await gate.load()
        model.applyStopCompletion(lease, note: "Stopped A")
        }
        await gate.waitUntilEntered()
        chat.sessionID = "runtime-b"
        chat.storedSessionID = "stored-b"
        chat.messages = [ChatMessage(author: .bot, text: "B owns this transcript")]
        await gate.release()
        await delayed.value

        XCTAssertEqual(chat.messages.map(\.text), ["B owns this transcript"])
        XCTAssertFalse(model.stopCompletionIsOwned(lease))
        XCTAssertEqual(model.promptQueue.map(\.text), ["queued for B"],
                      "a proven stop cleans captured A even after the UI binds B")
        model.acceptQueuedSubmission(lateA, text: "late A acknowledgement")
        XCTAssertEqual(model.promptQueue.map(\.text), ["queued for B"],
                       "cleared pending A cannot be recreated by its late ack")
        XCTAssertNil(LiveRuntime.shared.approvalTargets[approvalA])
        XCTAssertNotNil(LiveRuntime.shared.approvalTargets[approvalB])
        XCTAssertEqual(model.approvals.map(\.id), [approvalB])
        XCTAssertEqual(ApprovalBridges.shared.prompts.map(\.requestID), ["ticket-b"])
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        LiveRuntime.shared.approvalTargets[approvalB] = nil
        model.approvals = []
        ApprovalBridges.shared.prompts = []
    }

    func testPromptMutationFailureSeparatesRefusalFromAmbiguousTransport() {
        XCTAssertFalse(PromptMutationFailure.isAmbiguous(
            GatewayError(code: 409, message: "refused")))
        XCTAssertTrue(PromptMutationFailure.isAmbiguous(
            GatewayError(code: -5, message: "timeout")))
        XCTAssertTrue(PromptMutationFailure.isAmbiguous(URLError(.networkConnectionLost)))
        XCTAssertTrue(PromptMutationFailure.isAmbiguous(
            AckValidationError(operation: "prompt")))
    }

    func testReconciliationCarriesOnlyPostBaselineDeltasNeverWholeSnapshot() {
        let oldUser = ChatMessage(author: .user, text: "old", rowID: 1)
        let oldBot = ChatMessage(author: .bot, text: "old answer", rowID: 2)
        let optimistic = ChatMessage(author: .user, text: "edited")
        var changedBot = oldBot
        changedBot.text = "old answer plus a newer delta"
        let freshTool = ChatMessage(author: .bot, text: "", isStreaming: true)

        let newer = TranscriptActionReconciliation.newerRows(
            current: [oldUser, changedBot, optimistic, freshTool],
            baseline: [oldUser, oldBot], optimisticID: optimistic.id)

        XCTAssertEqual(newer.map(\.id), [changedBot.id, freshTool.id])
        XCTAssertFalse(newer.contains(where: { $0.id == oldUser.id }))
        XCTAssertFalse(newer.contains(where: { $0.id == optimistic.id }))
    }

    @MainActor
    func testLostSteerResponseAndFailedReconcileKeepExactFence() async {
        let model = AppModel()
        let botID = "steer-fenced"
        let route = GatewayBotRoute(gatewayID: "gateway", profile: "worker")
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let fence = SteerMutationFence(
            operationID: UUID(), botID: botID, route: route,
            sessionID: "runtime", storedID: "stored", chatID: ObjectIdentifier(chat),
            optimisticID: UUID(), text: "adjust", stage: .steer)
        ChatRuntime.shared.steerFences[botID] = fence

        await model.reconcileSteerMutation(
            fence,
            resume: { throw GatewayError(code: -7, message: "lost response") },
            hydrate: { _ in XCTFail("failed resume must not hydrate") },
            accepts: { true })

        XCTAssertEqual(ChatRuntime.shared.steerFences[botID], fence)
        XCTAssertTrue(model.mutationIsFenced(botID: botID))
        ChatRuntime.shared.steerFences[botID] = nil
    }

    @MainActor
    func testSteerFenceClearsOnlyWhenResumeNamesExactCorrection() async {
        let model = AppModel()
        let botID = "steer-exact"
        let route = GatewayBotRoute(gatewayID: "gateway", profile: "worker")
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let historicalDuplicate = ChatMessage(author: .user, text: "adjust", rowID: 42)
        chat.messages = [historicalDuplicate]
        let fence = SteerMutationFence(
            operationID: UUID(), botID: botID, route: route,
            sessionID: "runtime", storedID: "stored", chatID: ObjectIdentifier(chat),
            optimisticID: UUID(), text: "adjust", stage: .redirect,
            baselineDurableRowIDs: [42], baselineDurableRowCount: 1)
        ChatRuntime.shared.steerFences[botID] = fence

        let unrelated = LiveSession(.object([
            "session_id": .string("runtime"),
            "stored_session_id": .string("stored"),
            "messages": [[
                "role": .string("user"), "text": .string("adjust"),
                "row_id": .number(42),
            ]],
        ]))
        await model.reconcileSteerMutation(
            fence,
            resume: { unrelated },
            hydrate: { _ in chat.messages = [historicalDuplicate] },
            accepts: { true })
        XCTAssertEqual(ChatRuntime.shared.steerFences[botID], fence,
                       "a historical duplicate must not settle a lost steer")

        let exact = LiveSession(.object([
            "session_id": .string("runtime"),
            "stored_session_id": .string("stored"),
            "messages": [[
                "role": .string("user"), "text": .string("adjust"),
                "row_id": .number(42),
            ], [
                "role": .string("user"), "text": .string("adjust"),
                "row_id": .number(91),
            ]],
        ]))
        await model.reconcileSteerMutation(
            fence,
            resume: { exact },
            hydrate: { live in
                chat.messages = AppModel.chatMessages(fromTranscript: .array(live.messages))
            },
            accepts: { true })
        XCTAssertNil(ChatRuntime.shared.steerFences[botID])
    }

    @MainActor
    func testSteerReconcileRequiresCompleteBaselineDurableIDSubset() async {
        let model = AppModel()
        let botID = "steer-baseline-subset"
        let route = GatewayBotRoute(gatewayID: "gateway", profile: "worker")
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let fence = SteerMutationFence(
            operationID: UUID(), botID: botID, route: route,
            sessionID: "runtime", storedID: "stored", chatID: ObjectIdentifier(chat),
            optimisticID: UUID(), text: "adjust", stage: .steer,
            baselineDurableRowIDs: [42, 43], baselineDurableRowCount: 2,
            baselineDurableUserTexts: ["adjust"])
        ChatRuntime.shared.steerFences[botID] = fence

        let sameCountReplacement = LiveSession(.object([
            "session_id": .string("runtime"),
            "stored_session_id": .string("stored"),
            "messages": [[
                "role": .string("user"), "text": .string("adjust"),
                "row_id": .number(91),
            ], [
                "role": .string("assistant"), "text": .string("other"),
                "row_id": .number(92),
            ]],
        ]))
        await model.reconcileSteerMutation(
            fence,
            resume: { sameCountReplacement },
            hydrate: { live in
                chat.messages = AppModel.chatMessages(fromTranscript: .array(live.messages))
            },
            accepts: { true })
        XCTAssertEqual(ChatRuntime.shared.steerFences[botID], fence,
                       "equal counts with replaced baseline ids are not evidence")

        let complete = LiveSession(.object([
            "session_id": .string("runtime"),
            "stored_session_id": .string("stored"),
            "messages": [[
                "role": .string("user"), "text": .string("old"),
                "row_id": .number(42),
            ], [
                "role": .string("assistant"), "text": .string("old answer"),
                "row_id": .number(43),
            ], [
                "role": .string("user"), "text": .string("adjust"),
                "row_id": .number(91),
            ]],
        ]))
        await model.reconcileSteerMutation(
            fence,
            resume: { complete },
            hydrate: { live in
                chat.messages = AppModel.chatMessages(fromTranscript: .array(live.messages))
            },
            accepts: { true })
        XCTAssertNil(ChatRuntime.shared.steerFences[botID])
    }

    @MainActor
    func testSteerInflightDuplicateTextIsNotOperationSpecificEvidence() async {
        let model = AppModel()
        let botID = "steer-inflight-duplicate"
        let route = GatewayBotRoute(gatewayID: "gateway", profile: "worker")
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let historical = ChatMessage(author: .user, text: "adjust", rowID: 42)
        chat.messages = [historical]
        let fence = SteerMutationFence(
            operationID: UUID(), botID: botID, route: route,
            sessionID: "runtime", storedID: "stored", chatID: ObjectIdentifier(chat),
            optimisticID: UUID(), text: "adjust", stage: .redirect,
            baselineDurableRowIDs: [42], baselineDurableRowCount: 1,
            baselineDurableUserTexts: ["adjust"])
        ChatRuntime.shared.steerFences[botID] = fence

        let live = LiveSession(.object([
            "session_id": .string("runtime"),
            "stored_session_id": .string("stored"),
            "inflight": ["user": .string("adjust")],
            "messages": [[
                "role": .string("user"), "text": .string("adjust"),
                "row_id": .number(42),
            ]],
        ]))
        await model.reconcileSteerMutation(
            fence,
            resume: { live },
            hydrate: { _ in chat.messages = [historical] },
            accepts: { true })

        XCTAssertEqual(ChatRuntime.shared.steerFences[botID], fence,
                       "an old duplicate body in inflight cannot settle a lost steer")
        ChatRuntime.shared.steerFences[botID] = nil
    }

    @MainActor
    func testSameDurableRuntimeSIDRotationMigratesMutationAndKickoffLeases() {
        let model = AppModel()
        let botID = "worker"
        let route = GatewayBotRoute(gatewayID: "gateway", profile: botID)
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime-old"
        chat.storedSessionID = "stored"
        LiveRuntime.shared.gatewayID = "gateway"
        let previousGeneration = LiveRuntime.shared.generation
        LiveRuntime.shared.generation = 17

        let steerID = UUID()
        ChatRuntime.shared.steerActions[botID] = SteerMutationLease(
            id: steerID, botID: botID, route: route, sessionID: "runtime-old",
            storedID: "stored", chatID: ObjectIdentifier(chat),
            optimisticID: UUID(), text: "adjust")
        ChatRuntime.shared.steerFences[botID] = SteerMutationFence(
            operationID: steerID, botID: botID, route: route, sessionID: "runtime-old",
            storedID: "stored", chatID: ObjectIdentifier(chat), optimisticID: UUID(),
            text: "adjust", stage: .steer)
        let stopID = UUID()
        ChatRuntime.shared.stopActions[botID] = StopTurnLease(
            botID: botID, route: route, sessionID: "runtime-old", storedID: "stored",
            chatID: ObjectIdentifier(chat), id: stopID, generation: 3)
        ChatRuntime.shared.stopFences[botID] = StopTurnFence(
            operationID: stopID, botID: botID, route: route, sessionID: "runtime-old",
            storedID: "stored", chatID: ObjectIdentifier(chat), generation: 3)
        let kickoff = CanonicalKickoffLease(
            id: UUID(), botID: botID, sessionID: "runtime-old", storedID: "stored",
            rowID: nil, chatID: ObjectIdentifier(chat), submitStarted: true)
        CanonicalChatRuntime.shared.kickoffs[botID] = kickoff.id
        CanonicalChatRuntime.shared.ambiguousKickoffs[botID] = kickoff

        model.adopt(LiveSession(.object([
            "session_id": .string("runtime-new"),
            "stored_session_id": .string("stored"),
        ])), storedID: "stored", botID: botID, sourceGatewayID: "gateway")

        XCTAssertEqual(ChatRuntime.shared.steerActions[botID]?.sessionID, "runtime-new")
        XCTAssertEqual(ChatRuntime.shared.steerFences[botID]?.sessionID, "runtime-new")
        XCTAssertEqual(ChatRuntime.shared.stopActions[botID]?.sessionID, "runtime-new")
        XCTAssertEqual(ChatRuntime.shared.stopFences[botID]?.sessionID, "runtime-new")
        XCTAssertEqual(ChatRuntime.shared.stopFences[botID]?.generation,
                       LiveRuntime.shared.generation)
        XCTAssertEqual(CanonicalChatRuntime.shared.ambiguousKickoffs[botID]?.sessionID,
                       "runtime-new")

        ChatRuntime.shared.steerActions[botID] = nil
        ChatRuntime.shared.steerFences[botID] = nil
        ChatRuntime.shared.stopActions[botID] = nil
        ChatRuntime.shared.stopFences[botID] = nil
        CanonicalChatRuntime.shared.kickoffs[botID] = nil
        CanonicalChatRuntime.shared.ambiguousKickoffs[botID] = nil
        LiveRuntime.shared.sessionToBot["runtime-new"] = nil
        LiveRuntime.shared.gatewayID = nil
        LiveRuntime.shared.generation = previousGeneration
    }

    @MainActor
    func testReconnectParkedSIDMigratesLeasesWhenVisibleSessionIsNil() {
        let model = AppModel()
        let botID = "parked-binding"
        let route = GatewayBotRoute(gatewayID: "gateway", profile: botID)
        let chat = model.chat(for: botID)
        chat.sessionID = nil
        chat.storedSessionID = "stored"
        LiveRuntime.shared.gatewayID = "gateway"
        LiveRuntime.shared.reconnectParkedSessionIDs[botID] = "runtime-old"

        let steerID = UUID()
        ChatRuntime.shared.steerActions[botID] = SteerMutationLease(
            id: steerID, botID: botID, route: route, sessionID: "runtime-old",
            storedID: "stored", chatID: ObjectIdentifier(chat), optimisticID: UUID(),
            text: "adjust")
        ChatRuntime.shared.steerFences[botID] = SteerMutationFence(
            operationID: steerID, botID: botID, route: route, sessionID: "runtime-old",
            storedID: "stored", chatID: ObjectIdentifier(chat), optimisticID: UUID(),
            text: "adjust", stage: .steer)
        let stopID = UUID()
        ChatRuntime.shared.stopActions[botID] = StopTurnLease(
            botID: botID, route: route, sessionID: "runtime-old", storedID: "stored",
            chatID: ObjectIdentifier(chat), id: stopID)
        ChatRuntime.shared.stopFences[botID] = StopTurnFence(
            operationID: stopID, botID: botID, route: route, sessionID: "runtime-old",
            storedID: "stored", chatID: ObjectIdentifier(chat))
        let kickoff = CanonicalKickoffLease(
            id: UUID(), botID: botID, sessionID: "runtime-old", storedID: "stored",
            rowID: nil, chatID: ObjectIdentifier(chat), submitStarted: true)
        CanonicalChatRuntime.shared.kickoffs[botID] = kickoff.id
        CanonicalChatRuntime.shared.ambiguousKickoffs[botID] = kickoff

        model.adopt(LiveSession(.object([
            "session_id": .string("runtime-new"),
            "stored_session_id": .string("stored"),
        ])), storedID: "stored", botID: botID, sourceGatewayID: "gateway")

        XCTAssertEqual(ChatRuntime.shared.steerActions[botID]?.sessionID, "runtime-new")
        XCTAssertEqual(ChatRuntime.shared.steerFences[botID]?.sessionID, "runtime-new")
        XCTAssertEqual(ChatRuntime.shared.stopActions[botID]?.sessionID, "runtime-new")
        XCTAssertEqual(ChatRuntime.shared.stopFences[botID]?.sessionID, "runtime-new")
        XCTAssertEqual(CanonicalChatRuntime.shared.ambiguousKickoffs[botID]?.sessionID,
                       "runtime-new")
        XCTAssertNil(LiveRuntime.shared.reconnectParkedSessionIDs[botID])

        ChatRuntime.shared.steerActions[botID] = nil
        ChatRuntime.shared.steerFences[botID] = nil
        ChatRuntime.shared.stopActions[botID] = nil
        ChatRuntime.shared.stopFences[botID] = nil
        CanonicalChatRuntime.shared.kickoffs[botID] = nil
        CanonicalChatRuntime.shared.ambiguousKickoffs[botID] = nil
        LiveRuntime.shared.reconnectParkedSessionIDs[botID] = nil
        LiveRuntime.shared.sessionToBot["runtime-new"] = nil
        LiveRuntime.shared.gatewayID = nil
    }

    @MainActor
    func testLegacyBindSessionUsesParkedSIDMigrationPath() {
        let model = AppModel()
        let botID = "legacy-bind"
        let route = GatewayBotRoute(gatewayID: "gateway", profile: botID)
        let chat = model.chat(for: botID)
        chat.sessionID = nil
        chat.storedSessionID = "stored"
        LiveRuntime.shared.gatewayID = "gateway"
        LiveRuntime.shared.reconnectParkedSessionIDs[botID] = "runtime-old"
        let operationID = UUID()
        ChatRuntime.shared.steerFences[botID] = SteerMutationFence(
            operationID: operationID, botID: botID, route: route, sessionID: "runtime-old",
            storedID: "stored", chatID: ObjectIdentifier(chat), optimisticID: UUID(),
            text: "adjust", stage: .redirect)

        model.bindSession(LiveSession(.object([
            "session_id": .string("runtime-new"),
            "stored_session_id": .string("stored"),
        ])), botID: botID, sourceGatewayID: "gateway")

        XCTAssertEqual(chat.sessionID, "runtime-new")
        XCTAssertEqual(ChatRuntime.shared.steerFences[botID]?.sessionID, "runtime-new")
        XCTAssertEqual(LiveRuntime.shared.sessionToBot["runtime-new"], botID)
        XCTAssertNil(LiveRuntime.shared.reconnectParkedSessionIDs[botID])

        ChatRuntime.shared.steerFences[botID] = nil
        LiveRuntime.shared.sessionToBot["runtime-new"] = nil
        LiveRuntime.shared.gatewayID = nil
    }

    @MainActor
    func testDeadRuntimeParksOldSIDBeforeNilAndAdoptMigratesSteerFence() {
        let model = AppModel()
        let botID = "dead-runtime-park"
        let route = GatewayBotRoute(gatewayID: "gateway", profile: botID)
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime-old"
        chat.storedSessionID = "stored"
        LiveRuntime.shared.gatewayID = "gateway"
        LiveRuntime.shared.sessionToBot["runtime-old"] = botID
        let operationID = UUID()
        ChatRuntime.shared.steerFences[botID] = SteerMutationFence(
            operationID: operationID, botID: botID, route: route,
            sessionID: "runtime-old", storedID: "stored", chatID: ObjectIdentifier(chat),
            optimisticID: UUID(), text: "adjust", stage: .steer)

        model.unbindDeadRuntime(sid: "runtime-old", botID: botID)

        XCTAssertNil(chat.sessionID)
        XCTAssertEqual(LiveRuntime.shared.reconnectParkedSessionIDs[botID], "runtime-old")
        model.adopt(LiveSession(.object([
            "session_id": .string("runtime-new"),
            "stored_session_id": .string("stored"),
        ])), storedID: "stored", botID: botID, sourceGatewayID: "gateway")
        XCTAssertEqual(ChatRuntime.shared.steerFences[botID]?.sessionID, "runtime-new")

        ChatRuntime.shared.steerFences[botID] = nil
        LiveRuntime.shared.sessionToBot["runtime-new"] = nil
        LiveRuntime.shared.reconnectParkedSessionIDs[botID] = nil
        LiveRuntime.shared.gatewayID = nil
    }

    @MainActor
    func testAttachmentSessionNotFoundParkingHookMigratesStopFence() {
        let model = AppModel()
        let botID = "attachment-session-recovery"
        let route = GatewayBotRoute(gatewayID: "gateway", profile: botID)
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime-old"
        chat.storedSessionID = "stored"
        LiveRuntime.shared.gatewayID = "gateway"
        let operationID = UUID()
        ChatRuntime.shared.stopFences[botID] = StopTurnFence(
            operationID: operationID, botID: botID, route: route,
            sessionID: "runtime-old", storedID: "stored", chatID: ObjectIdentifier(chat))

        // This is the exact parking operation used by stageOnGateway's
        // sessionNotFound recovery before it clears ChatState.sessionID.
        model.parkRuntimeSessionBeforeClearing(botID: botID)
        chat.sessionID = nil
        model.adopt(LiveSession(.object([
            "session_id": .string("runtime-new"),
            "stored_session_id": .string("stored"),
        ])), storedID: "stored", botID: botID, sourceGatewayID: "gateway")

        XCTAssertEqual(ChatRuntime.shared.stopFences[botID]?.sessionID, "runtime-new")
        ChatRuntime.shared.stopFences[botID] = nil
        LiveRuntime.shared.sessionToBot["runtime-new"] = nil
        LiveRuntime.shared.reconnectParkedSessionIDs[botID] = nil
        LiveRuntime.shared.gatewayID = nil
    }

    @MainActor
    func testStopTapDuringSteerReconciliationQueuesAndDrainsAfterOwner() {
        let model = AppModel()
        model.mode = .live
        let botID = "stop-after-steer"
        let route = GatewayBotRoute(gatewayID: "gateway", profile: botID)
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        chat.isRunning = true
        let steerID = UUID()
        ChatRuntime.shared.steerFences[botID] = SteerMutationFence(
            operationID: steerID, botID: botID, route: route, sessionID: "runtime",
            storedID: "stored", chatID: ObjectIdentifier(chat), optimisticID: UUID(),
            text: "adjust", stage: .redirect)
        ChatRuntime.shared.reconcilingBots.insert(botID)

        model.stopTurn(botID: botID)

        XCTAssertNotNil(ChatRuntime.shared.pendingStopRequests[botID])
        XCTAssertNil(ChatRuntime.shared.stopFences[botID],
                     "the stop must not issue a second mutation during steer reconciliation")

        ChatRuntime.shared.reconcilingBots.remove(botID)
        ChatRuntime.shared.steerFences[botID] = nil
        model.drainPendingMutationWork(botID: botID)

        XCTAssertNil(ChatRuntime.shared.pendingStopRequests[botID])
        XCTAssertTrue(ChatRuntime.shared.stopFences[botID]?.unaddressable == true,
                      "the deferred stop intent must be drained once steer releases")
        XCTAssertTrue(chat.isRunning)

        ChatRuntime.shared.stopFences[botID] = nil
        ChatRuntime.shared.clearPendingStop(botID: botID)
        LiveRuntime.shared.reconnectParkedSessionIDs[botID] = nil
        LiveRuntime.shared.gatewayID = nil
    }

    @MainActor
    func testPendingStopMigratesRuntimeSIDOnlyForSameDurableRoute() {
        let model = AppModel()
        model.mode = .live
        let botID = "pending-stop-migrate-\(UUID().uuidString)"
        let route = GatewayBotRoute(gatewayID: "gateway-a", profile: botID)
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime-a"
        chat.storedSessionID = "stored-a"
        chat.isRunning = true
        LiveRuntime.shared.gatewayID = "gateway-a"
        let steerID = UUID()
        ChatRuntime.shared.steerFences[botID] = SteerMutationFence(
            operationID: steerID, botID: botID, route: route, sessionID: "runtime-a",
            storedID: "stored-a", chatID: ObjectIdentifier(chat), optimisticID: UUID(),
            text: "adjust", stage: .redirect)
        ChatRuntime.shared.reconcilingBots.insert(botID)

        model.stopTurn(botID: botID)
        let oldGeneration = LiveRuntime.shared.generation
        XCTAssertEqual(ChatRuntime.shared.pendingStopRequests[botID]?.sessionID, "runtime-a")

        model.adopt(LiveSession(.object([
            "session_id": .string("runtime-b"),
            "stored_session_id": .string("stored-a"),
            "running": .bool(true),
        ])), storedID: "stored-a", botID: botID, sourceGatewayID: "gateway-a")

        XCTAssertEqual(ChatRuntime.shared.pendingStopRequests[botID]?.sessionID, "runtime-b")
        XCTAssertEqual(ChatRuntime.shared.pendingStopRequests[botID]?.storedID, "stored-a")
        XCTAssertEqual(ChatRuntime.shared.pendingStopRequests[botID]?.route, route)
        XCTAssertEqual(ChatRuntime.shared.pendingStopRequests[botID]?.generation, oldGeneration)

        ChatRuntime.shared.clearPendingStop(botID: botID)
        ChatRuntime.shared.steerFences[botID] = nil
        ChatRuntime.shared.reconcilingBots.remove(botID)
        LiveRuntime.shared.sessionToBot["runtime-b"] = nil
        LiveRuntime.shared.reconnectParkedSessionIDs[botID] = nil
        LiveRuntime.shared.gatewayID = nil
    }

    @MainActor
    func testPendingStopDoesNotFollowExplicitOpenToReplacementSession() {
        let model = AppModel()
        model.mode = .live
        let botID = "pending-stop-open-\(UUID().uuidString)"
        let route = GatewayBotRoute(gatewayID: "gateway-a", profile: botID)
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime-a"
        chat.storedSessionID = "stored-a"
        chat.isRunning = true
        LiveRuntime.shared.gatewayID = "gateway-a"
        ChatRuntime.shared.steerFences[botID] = SteerMutationFence(
            operationID: UUID(), botID: botID, route: route, sessionID: "runtime-a",
            storedID: "stored-a", chatID: ObjectIdentifier(chat), optimisticID: UUID(),
            text: "adjust", stage: .redirect)
        ChatRuntime.shared.reconcilingBots.insert(botID)
        model.stopTurn(botID: botID)
        XCTAssertNotNil(ChatRuntime.shared.pendingStopRequests[botID])

        model.openStoredSession("stored-b", botID: botID)
        XCTAssertNil(ChatRuntime.shared.pendingStopRequests[botID],
                     "explicit open must retire A's deferred interrupt")

        SessionsRuntime.shared.openGenerations[botID, default: 0] &+= 1
        LiveRuntime.shared.generation &+= 1
        ChatRuntime.shared.steerFences[botID] = nil
        ChatRuntime.shared.reconcilingBots.remove(botID)
        LiveRuntime.shared.gatewayID = nil
    }

    @MainActor
    func testPendingStopSurvivesReopenOfSameDurableSession() {
        let model = AppModel()
        model.mode = .live
        let botID = "pending-stop-reopen-" + UUID().uuidString
        let route = GatewayBotRoute(gatewayID: "gateway-reopen", profile: botID)
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime-a"
        chat.storedSessionID = "stored-a"
        chat.isRunning = true
        LiveRuntime.shared.gatewayID = route.gatewayID
        ChatRuntime.shared.steerFences[botID] = SteerMutationFence(
            operationID: UUID(), botID: botID, route: route, sessionID: "runtime-a",
            storedID: "stored-a", chatID: ObjectIdentifier(chat), optimisticID: UUID(),
            text: "adjust", stage: .redirect)
        ChatRuntime.shared.reconcilingBots.insert(botID)
        model.stopTurn(botID: botID)
        XCTAssertNotNil(ChatRuntime.shared.pendingStopRequests[botID])

        // The sessions sheet reopens A while resume temporarily clears the
        // runtime sid. The exact durable/chat binding still owns the intent.
        model.openStoredSession("stored-a", botID: botID)
        XCTAssertNotNil(ChatRuntime.shared.pendingStopRequests[botID],
                        "same durable reopen must retain the deferred stop")

        SessionsRuntime.shared.openGenerations[botID, default: 0] &+= 1
        LiveRuntime.shared.generation &+= 1
        ChatRuntime.shared.pendingStopRequests[botID] = nil
        ChatRuntime.shared.steerFences[botID] = nil
        ChatRuntime.shared.reconcilingBots.remove(botID)
        LiveRuntime.shared.gatewayID = nil
    }

    @MainActor
    func testSourceQualifiedPendingStopRekeysOnlyWithExactDurableChatOwnership() {
        let model = AppModel()
        let oldBotID = "gateway-profile::old"
        let newBotID = "gateway-profile::new"
        let oldRoute = GatewayBotRoute(gatewayID: "gateway-profile", profile: "old")
        let newRoute = GatewayBotRoute(gatewayID: "gateway-profile", profile: "new")
        let chat = model.chat(for: oldBotID)
        chat.storedSessionID = "stored-a"
        ChatRuntime.shared.pendingStopRequests[oldBotID] = PendingStopRequest(
            botID: oldBotID, route: oldRoute, storedID: "stored-a", sessionID: "runtime-a",
            chatID: ObjectIdentifier(chat), generation: LiveRuntime.shared.generation)

        XCTAssertTrue(ChatRuntime.shared.rekeyPendingStop(
            fromBotIDs: [oldBotID], fromRoute: oldRoute,
            toBotID: newBotID, toRoute: newRoute,
            chatID: ObjectIdentifier(chat), storedID: "stored-a"))
        XCTAssertNil(ChatRuntime.shared.pendingStopRequests[oldBotID])
        XCTAssertEqual(ChatRuntime.shared.pendingStopRequests[newBotID]?.route, newRoute)
        XCTAssertEqual(ChatRuntime.shared.pendingStopRequests[newBotID]?.storedID, "stored-a")
        XCTAssertNil(ChatRuntime.shared.pendingStopRequests[newBotID]?.sessionID,
                     "a renamed profile must await a new authoritative runtime sid")

        // A mismatched ChatState/durable row cancels the old route instead of
        // guessing that the destination owns the user's interrupt.
        ChatRuntime.shared.pendingStopRequests[newBotID] = nil
        ChatRuntime.shared.pendingStopRequests[oldBotID] = PendingStopRequest(
            botID: oldBotID, route: oldRoute, storedID: "stored-old", sessionID: "runtime-old",
            chatID: ObjectIdentifier(chat), generation: LiveRuntime.shared.generation)
        XCTAssertFalse(ChatRuntime.shared.rekeyPendingStop(
            fromBotIDs: [oldBotID], fromRoute: oldRoute,
            toBotID: newBotID, toRoute: newRoute,
            chatID: ObjectIdentifier(chat), storedID: "stored-new"))
        XCTAssertNil(ChatRuntime.shared.pendingStopRequests[oldBotID])
        XCTAssertNil(ChatRuntime.shared.pendingStopRequests[newBotID])
    }

    @MainActor
    func testDeletingOneSecondaryProfileClearsOnlyItsSourceQualifiedPendingStop() {
        let model = AppModel()
        let oldRoute = GatewayBotRoute(gatewayID: "gateway-delete", profile: "old")
        let siblingRoute = GatewayBotRoute(gatewayID: "gateway-delete", profile: "sibling")
        let oldBotID = oldRoute.qualifiedID
        let siblingBotID = siblingRoute.qualifiedID
        let oldChat = model.chat(for: oldBotID)
        let siblingChat = model.chat(for: siblingBotID)
        ChatRuntime.shared.pendingStopRequests[oldBotID] = PendingStopRequest(
            botID: oldBotID, route: oldRoute, storedID: "stored-old", sessionID: "runtime-old",
            chatID: ObjectIdentifier(oldChat), generation: LiveRuntime.shared.generation)
        ChatRuntime.shared.pendingStopRequests[siblingBotID] = PendingStopRequest(
            botID: siblingBotID, route: siblingRoute, storedID: "stored-sibling",
            sessionID: "runtime-sibling", chatID: ObjectIdentifier(siblingChat),
            generation: LiveRuntime.shared.generation)

        ChatRuntime.shared.clearPendingStops(forRoute: oldRoute)

        XCTAssertNil(ChatRuntime.shared.pendingStopRequests[oldBotID])
        XCTAssertNotNil(ChatRuntime.shared.pendingStopRequests[siblingBotID],
                        "deleting one secondary profile must not clear its sibling")
        ChatRuntime.shared.pendingStopRequests[siblingBotID] = nil
    }

    @MainActor
    func testPendingStopDoesNotFollowDeletedSessionIntoReplacement() async {
        let model = AppModel()
        model.mode = .live
        let botID = "pending-stop-delete-\(UUID().uuidString)"
        let route = GatewayBotRoute(gatewayID: "gateway-a", profile: botID)
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime-a"
        chat.storedSessionID = "stored-a"
        chat.isRunning = true
        LiveRuntime.shared.gatewayID = "gateway-a"
        ChatRuntime.shared.steerFences[botID] = SteerMutationFence(
            operationID: UUID(), botID: botID, route: route, sessionID: "runtime-a",
            storedID: "stored-a", chatID: ObjectIdentifier(chat), optimisticID: UUID(),
            text: "adjust", stage: .redirect)
        ChatRuntime.shared.reconcilingBots.insert(botID)
        model.stopTurn(botID: botID)
        XCTAssertNotNil(ChatRuntime.shared.pendingStopRequests[botID])

        model.mode = .demo
        _ = await model.deleteStoredSession("stored-a", botID: botID)
        XCTAssertNil(ChatRuntime.shared.pendingStopRequests[botID],
                     "deleting A must clear its deferred interrupt")

        chat.sessionID = "runtime-b"
        chat.storedSessionID = "stored-b"
        chat.isRunning = true
        ChatRuntime.shared.steerFences[botID] = nil
        ChatRuntime.shared.reconcilingBots.remove(botID)
        model.mode = .live
        model.drainPendingMutationWork(botID: botID)
        XCTAssertTrue(chat.isRunning)
        XCTAssertNil(ChatRuntime.shared.stopActions[botID])
        XCTAssertNil(ChatRuntime.shared.stopFences[botID])
        LiveRuntime.shared.gatewayID = nil
    }

    @MainActor
    func testPendingStopCannotDrainAfterGatewaySwitchToB() {
        let model = AppModel()
        model.mode = .live
        let botID = "pending-stop-switch-\(UUID().uuidString)"
        let routeA = GatewayBotRoute(gatewayID: "gateway-a", profile: botID)
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime-a"
        chat.storedSessionID = "stored-a"
        chat.isRunning = true
        LiveRuntime.shared.gatewayID = "gateway-a"
        ChatRuntime.shared.steerFences[botID] = SteerMutationFence(
            operationID: UUID(), botID: botID, route: routeA, sessionID: "runtime-a",
            storedID: "stored-a", chatID: ObjectIdentifier(chat), optimisticID: UUID(),
            text: "adjust", stage: .redirect)
        ChatRuntime.shared.reconcilingBots.insert(botID)
        model.stopTurn(botID: botID)
        XCTAssertEqual(ChatRuntime.shared.pendingStopRequests[botID]?.route, routeA)

        // Model the switch's new source reusing the same profile id and ChatState.
        ChatRuntime.shared.steerFences[botID] = nil
        ChatRuntime.shared.reconcilingBots.remove(botID)
        LiveRuntime.shared.gatewayID = "gateway-b"
        chat.sessionID = "runtime-b"
        chat.storedSessionID = "stored-b"
        chat.isRunning = true
        model.drainPendingMutationWork(botID: botID)

        XCTAssertNil(ChatRuntime.shared.pendingStopRequests[botID])
        XCTAssertNil(ChatRuntime.shared.stopActions[botID])
        XCTAssertNil(ChatRuntime.shared.stopFences[botID])
        XCTAssertTrue(chat.isRunning, "B must not inherit A's stop intent")
        LiveRuntime.shared.gatewayID = nil
    }

    @MainActor
    func testAmbiguousInterruptReadFailureRetainsRunningAndFence() async {
        let model = AppModel()
        let botID = "stop-fenced"
        let route = GatewayBotRoute(gatewayID: "gateway", profile: "worker")
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        chat.isRunning = true
        let fence = StopTurnFence(
            operationID: UUID(), botID: botID, route: route,
            sessionID: "runtime", storedID: "stored", chatID: ObjectIdentifier(chat))
        ChatRuntime.shared.stopFences[botID] = fence

        await model.reconcileStopTurn(
            fence, note: "Stopped",
            resume: { throw GatewayError(code: -7, message: "resume failed") },
            accepts: { true })

        XCTAssertTrue(chat.isRunning)
        XCTAssertEqual(ChatRuntime.shared.stopFences[botID], fence)
        XCTAssertTrue(model.mutationIsFenced(botID: botID))
        ChatRuntime.shared.stopFences[botID] = nil
    }

    @MainActor
    func testInterruptReconcileRunningProjectionRetainsFenceUntilIdle() async {
        let model = AppModel()
        let botID = "stop-running"
        let route = GatewayBotRoute(gatewayID: "gateway", profile: "worker")
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        chat.isRunning = true
        let fence = StopTurnFence(
            operationID: UUID(), botID: botID, route: route,
            sessionID: "runtime", storedID: "stored", chatID: ObjectIdentifier(chat))
        ChatRuntime.shared.stopFences[botID] = fence

        await model.reconcileStopTurn(
            fence, note: "Stopped",
            resume: {
                LiveSession(.object([
                    "session_id": .string("runtime"),
                    "stored_session_id": .string("stored"),
                    "running": .bool(true),
                ]))
            },
            accepts: { true })

        XCTAssertEqual(ChatRuntime.shared.stopFences[botID], fence)
        XCTAssertTrue(chat.isRunning)
        ChatRuntime.shared.stopFences[botID] = nil
    }

    @MainActor
    func testInterruptFalseRunningWithInflightDoesNotSettleStop() async {
        let model = AppModel()
        let botID = "stop-inflight"
        let route = GatewayBotRoute(gatewayID: "gateway", profile: "worker")
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        chat.isRunning = true
        let fence = StopTurnFence(
            operationID: UUID(), botID: botID, route: route,
            sessionID: "runtime", storedID: "stored", chatID: ObjectIdentifier(chat))
        ChatRuntime.shared.stopFences[botID] = fence

        await model.reconcileStopTurn(
            fence, note: "Stopped",
            resume: {
                LiveSession(.object([
                    "session_id": .string("runtime"),
                    "stored_session_id": .string("stored"),
                    "running": .bool(false),
                    "inflight": ["user": .string("still running")],
                ]))
            },
            accepts: { true })

        XCTAssertEqual(ChatRuntime.shared.stopFences[botID], fence)
        XCTAssertTrue(chat.isRunning)
        XCTAssertTrue(model.mutationIsFenced(botID: botID))
        ChatRuntime.shared.stopFences[botID] = nil
    }

    @MainActor
    func testInterruptFalseRunningWithNullInflightSettlesStopAndUIIdle() async {
        let model = AppModel()
        let botID = "stop-null-inflight"
        let route = GatewayBotRoute(gatewayID: "gateway", profile: "worker")
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        chat.isRunning = true
        let fence = StopTurnFence(
            operationID: UUID(), botID: botID, route: route,
            sessionID: "runtime", storedID: "stored", chatID: ObjectIdentifier(chat))
        ChatRuntime.shared.stopFences[botID] = fence

        await model.reconcileStopTurn(
            fence, note: "Stopped",
            resume: {
                LiveSession(.object([
                    "session_id": .string("runtime"),
                    "stored_session_id": .string("stored"),
                    "running": .bool(false),
                    "inflight": .null,
                ]))
            },
            accepts: { true })

        XCTAssertNil(ChatRuntime.shared.stopFences[botID])
        XCTAssertFalse(chat.isRunning)
        XCTAssertFalse(chat.isTyping)
        XCTAssertFalse(model.mutationIsFenced(botID: botID))
    }

    @MainActor
    func testCanonicalBirthSuppressesInvisibleKickoffBehindFirstUserPrompt() {
        let model = AppModel()
        let chat = model.chat(for: "birth")
        chat.messages = [ChatMessage(author: .user, text: "first prompt")]

        XCTAssertFalse(model.canonicalKickoffShouldSubmit(chat: chat))
        XCTAssertTrue(model.canonicalKickoffShouldSubmit(chat: ChatState()))
    }

    func testSteerAndRedirectReceiptsRejectRawFalseBeforeStatus() {
        XCTAssertThrowsError(try SessionMutationReceipt.requireStatus(
            .object(["ok": .bool(false), "status": .string("queued")]),
            operation: "session.steer", accepted: ["queued", "rejected"])) { error in
            XCTAssertEqual((error as? GatewayError)?.code, 409)
        }
        XCTAssertThrowsError(try SessionMutationReceipt.requireStatus(
            .object(["ok": .bool(false), "status": .string("redirected")]),
            operation: "session.redirect", accepted: ["redirected", "queued", "rejected"])) { error in
            XCTAssertEqual((error as? GatewayError)?.code, 409)
        }
        XCTAssertEqual(try? SessionMutationReceipt.requireStatus(
            .object(["ok": .bool(true), "status": .string("queued")]),
            operation: "session.steer", accepted: ["queued", "rejected"]), "queued")
    }

    @MainActor
    func testUnaddressableLiveStopFencesUntilAuthoritativeReattach() {
        let model = AppModel()
        model.mode = .live
        let botID = "unaddressable-stop"
        let chat = model.chat(for: botID)
        chat.storedSessionID = "stored"
        chat.isRunning = true
        LiveRuntime.shared.gatewayID = nil
        model.stopTurn(botID: botID)

        XCTAssertTrue(chat.isRunning)
        XCTAssertTrue(ChatRuntime.shared.stopFences[botID]?.unaddressable == true)
        XCTAssertTrue(model.mutationIsFenced(botID: botID))
        let countBeforeBlockedSend = chat.messages.count
        model.sendOrSteer(text: "must wait", to: botID)
        XCTAssertEqual(chat.messages.count, countBeforeBlockedSend,
                       "an unaddressable stop must block a new submit")

        model.adopt(LiveSession(.object([
            "session_id": .string("runtime-reattached"),
            "stored_session_id": .string("stored"),
            "running": .bool(false),
        ])), storedID: "stored", botID: botID, sourceGatewayID: "gateway")
        XCTAssertNil(ChatRuntime.shared.stopFences[botID])
        XCTAssertFalse(chat.isRunning)
        XCTAssertEqual(chat.sessionID, "runtime-reattached")
        LiveRuntime.shared.routedSessionToBot.removeValue(
            forKey: GatewaySessionRoute(gatewayID: "gateway", sessionID: "runtime-reattached"))
    }

    func testDefinitePromptRefusalIsNotAmbiguousEvenWhenReadbackWouldFail() {
        let refusal = GatewayError(code: 409, message: "refused")
        XCTAssertFalse(PromptMutationFailure.isAmbiguous(refusal))
        XCTAssertThrowsError(try PromptSubmitReceipt.requireAccepted(
            .object(["ok": .bool(false), "status": .string("rejected")]),
            operation: "Transcript action")) { error in
            XCTAssertFalse(PromptMutationFailure.isAmbiguous(error))
        }
    }

    @MainActor
    func testQueuedStateMigratesEveryMirrorAcrossExactRuntimeSIDRotation() {
        let model = AppModel()
        model.mode = .live
        let botID = "queued-rotation-\(UUID().uuidString)"
        let route = GatewayBotRoute(gatewayID: "queue-gateway", profile: botID)
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime-old"
        chat.storedSessionID = "stored"
        LiveRuntime.shared.gatewayID = route.gatewayID
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        ChatRuntime.shared.nextQueuedSubmissionOrder = 0

        model.enqueuePrompt("queued", botID: botID, sessionID: "runtime-old")
        let pending = model.beginQueuedSubmission(botID: botID, sessionID: "runtime-old")
        model.noteQueuedPromptStart(botID: botID, sessionID: "runtime-old")
        model.noteQueuedPromptCompletion(botID: botID, sessionID: "runtime-old")

        XCTAssertTrue(model.migrateQueuedState(
            fromBotID: botID, toBotID: botID, route: route,
            oldSessionID: "runtime-old", newSessionID: "runtime-new",
            storedID: "stored"))
        chat.sessionID = "runtime-new"

        XCTAssertEqual(model.queuedPrompts(for: botID).map(\.text), ["queued"])
        let queuedID = try? XCTUnwrap(model.promptQueue.first?.id)
        XCTAssertEqual(queuedID.flatMap { ChatRuntime.shared.queuedBindings[$0]?.sessionID },
                       "runtime-new")
        let lifecycle = model.queuedPromptLifecycle(botID: botID, sessionID: "runtime-new")
        XCTAssertEqual(lifecycle.starts, 1)
        XCTAssertEqual(lifecycle.completions, 1)
        let destination = QueuedPromptSession(
            botID: botID, sessionID: "runtime-new", storedID: "stored", route: route)
        XCTAssertEqual(ChatRuntime.shared.pendingQueuedSubmissions[destination]?.map(\.id),
                       [pending.id])
        XCTAssertEqual(ChatRuntime.shared.pendingQueuedSubmissions[destination]?.first?.session,
                       destination)

        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        LiveRuntime.shared.gatewayID = nil
    }

    @MainActor
    func testQueuedRetirementIsExactRouteAndStoredIdentity() {
        let model = AppModel()
        let botID = "queued-retire-\(UUID().uuidString)"
        let route = GatewayBotRoute(gatewayID: "queue-retire-gateway", profile: botID)
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored-a"
        LiveRuntime.shared.gatewayID = route.gatewayID
        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        model.enqueuePrompt("A", botID: botID, sessionID: "runtime")

        chat.storedSessionID = "stored-b"
        XCTAssertTrue(model.retireQueuedState(botID: botID, route: route, storedID: "stored-a"))
        XCTAssertTrue(model.promptQueue.isEmpty)
        XCTAssertTrue(ChatRuntime.shared.queuedBindings.isEmpty)

        model.promptQueue = []
        ChatRuntime.shared.queuedBindings = [:]
        ChatRuntime.shared.queuedLifecycles = [:]
        ChatRuntime.shared.pendingQueuedSubmissions = [:]
        LiveRuntime.shared.gatewayID = nil
    }

    func testTranscriptActionProofRequiresExactTruncateEffectAndNewBody() {
        let oldUser = ChatMessage(author: .user, text: "old", rowID: 1)
        let oldBot = ChatMessage(author: .bot, text: "old answer", rowID: 2)
        let target = ChatMessage(author: .user, text: "retry", rowID: 3)
        let targetBot = ChatMessage(author: .bot, text: "old retry answer", rowID: 4)
        let baseline = [oldUser, oldBot, target, targetBot]
        let plan = try! XCTUnwrap(TranscriptActing.planRestore(baseline, from: target.id))
        let proof = try! XCTUnwrap(TranscriptActionEffectProof.capture(
            plan: plan, baseline: baseline))

        XCTAssertFalse(proof.proves(baseline), "the old target is not proof of a rewrite")
        XCTAssertTrue(proof.proves([
            ChatMessage(author: .user, text: "old", rowID: 11),
            ChatMessage(author: .bot, text: "old answer", rowID: 12),
            ChatMessage(author: .user, text: "retry", rowID: 13),
        ]))
        XCTAssertFalse(proof.proves([
            ChatMessage(author: .user, text: "old", rowID: 11),
            ChatMessage(author: .bot, text: "old answer", rowID: 12),
            ChatMessage(author: .user, text: "retry", rowID: 13),
            ChatMessage(author: .bot, text: "old retry answer", rowID: 4),
        ]), "a surviving post-target row means the truncate effect is unproven")
    }

    @MainActor
    func testKickoffRouteMismatchRetiresOldBirthInsteadOfMigratingIt() {
        let model = AppModel()
        let botID = "kickoff-gateway-b::worker"
        let routeA = GatewayBotRoute(gatewayID: "kickoff-gateway-a", profile: "worker")
        let routeB = GatewayBotRoute(gatewayID: "kickoff-gateway-b", profile: "worker")
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime-old"
        chat.storedSessionID = "stored"
        let lease = CanonicalKickoffLease(
            id: UUID(), botID: botID, sessionID: "runtime-old", storedID: "stored",
            rowID: nil, chatID: ObjectIdentifier(chat), submitStarted: true,
            route: routeA)
        CanonicalChatRuntime.shared.kickoffs[botID] = lease.id
        CanonicalChatRuntime.shared.kickoffLeases[botID] = lease
        CanonicalChatRuntime.shared.ambiguousKickoffs[botID] = lease
        LiveRuntime.shared.gatewayID = routeB.gatewayID

        model.adopt(LiveSession(.object([
            "session_id": .string("runtime-new"),
            "stored_session_id": .string("stored"),
        ])), storedID: "stored", botID: botID, sourceGatewayID: routeB.gatewayID)

        XCTAssertNil(CanonicalChatRuntime.shared.kickoffs[botID])
        XCTAssertNil(CanonicalChatRuntime.shared.kickoffLeases[botID])
        XCTAssertNil(CanonicalChatRuntime.shared.ambiguousKickoffs[botID])
        LiveRuntime.shared.routedSessionToBot.removeValue(
            forKey: GatewaySessionRoute(gatewayID: routeB.gatewayID, sessionID: "runtime-new"))
        LiveRuntime.shared.gatewayID = nil
    }

    @MainActor
    func testKickoffCompatibilityReconcileRejectsForeignGatewaySource() async {
        let model = AppModel()
        let botID = "kickoff-source::worker"
        let route = GatewayBotRoute(gatewayID: "source-a", profile: "worker")
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let lease = CanonicalKickoffLease(
            id: UUID(), botID: botID, sessionID: "runtime", storedID: "stored",
            rowID: nil, chatID: ObjectIdentifier(chat), submitStarted: true,
            route: route)
        CanonicalChatRuntime.shared.kickoffs[botID] = lease.id
        CanonicalChatRuntime.shared.ambiguousKickoffs[botID] = lease
        var resumed = false

        await model.reconcileAmbiguousCanonicalKickoff(
            lease, sourceGatewayID: "source-b",
            resume: { resumed = true; return LiveSession(.object([:])) },
            hydrate: { _ in XCTFail("foreign source must not hydrate") },
            accepts: { true })

        XCTAssertFalse(resumed)
        XCTAssertEqual(CanonicalChatRuntime.shared.ambiguousKickoffs[botID], lease)
        CanonicalChatRuntime.shared.kickoffs[botID] = nil
        CanonicalChatRuntime.shared.ambiguousKickoffs[botID] = nil
    }

    @MainActor
    func testFenceArrivalWithdrawsOnlyTheWaitingSendBubble() {
        let model = AppModel()
        let botID = "waiting-send"
        let chat = model.chat(for: botID)
        let optimistic = ChatMessage(author: .user, text: "must wait")
        chat.messages = [optimistic]
        ChatRuntime.shared.transcriptFences[botID] = TranscriptActionFence(
            operationID: UUID(), sessionID: "runtime", storedID: "stored",
            gatewayID: "gateway", profile: botID, generation: LiveRuntime.shared.generation)

        model.removeOptimisticMessage(optimistic.id, from: chat, botID: botID)
        XCTAssertTrue(chat.messages.isEmpty)
        ChatRuntime.shared.transcriptFences[botID] = nil
    }
}

private actor TranscriptStopBarrier {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func load() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
#endif
