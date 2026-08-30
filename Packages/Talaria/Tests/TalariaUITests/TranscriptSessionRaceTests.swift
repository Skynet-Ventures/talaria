#if canImport(XCTest)
import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class TranscriptSessionRaceTests: XCTestCase {
    func testOwnerBackfillReceiptRequiresExactProfileAndNonnegativeCount() throws {
        let receipt = try SessionOwnerBackfillReceipt(
            ["ok": true, "stamped": 3, "profile": "research"],
            expectedProfile: "research")
        XCTAssertEqual(receipt.stamped, 3)
        XCTAssertEqual(receipt.profile, "research")

        for malformed: JSONValue in [
            ["ok": false, "stamped": 3, "profile": "research"],
            ["ok": true, "stamped": -1, "profile": "research"],
            ["ok": true, "stamped": 3, "profile": "default"],
            ["ok": true, "profile": "research"],
        ] {
            XCTAssertThrowsError(try SessionOwnerBackfillReceipt(
                malformed, expectedProfile: "research"))
        }
    }

    func testOwnerBackfillUsesExactAuthenticatedProfileRoute() async throws {
        let baseURL = try XCTUnwrap(URL(string: "https://owner-backfill.example/base/"))
        let client = GatewayClient(
            baseURL: baseURL, credential: .sessionToken("owner-token"),
            restExecutor: { request, limit in
                XCTAssertNil(limit)
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.path, "/base/api/sessions/owner-backfill")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"),
                               "owner-token")
                let body = try XCTUnwrap(request.httpBody)
                let json = try JSONDecoder().decode(JSONValue.self, from: body)
                XCTAssertEqual(json["profile"]?.stringValue, "research")
                let responseBody = try JSONEncoder().encode(JSONValue.object([
                    "ok": true, "stamped": 4, "profile": "research",
                ]))
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]))
                return (responseBody, response)
            })

        let receipt = try await client.backfillLegacySessionOwners(profile: "research")

        XCTAssertEqual(receipt.stamped, 4)
        XCTAssertEqual(receipt.profile, "research")
    }
    @MainActor
    func testRetainedFailureProjectsCorrectionsAtScalarOffsetsAndOwnsTailAssistant() throws {
        let live = LiveSession(try json([
            "session_id": "runtime",
            "stored_session_id": "stored",
            "inflight": [
                "user": "original",
                "assistant": "abcdef",
                "corrections": ["first correction", "second correction"],
                "correction_offsets": [2, 4],
                "streaming": false,
                "status": "error",
                "error": "stream dropped",
                "recoverable": true,
                "error_surface": [
                    "layer": "streaming", "code": "stream_drop", "retryable": true,
                ],
            ],
        ]))
        let retained = try XCTUnwrap(live.retainedInflight)
        let failure = try XCTUnwrap(TurnFailureLifecycle.failure(from: retained))

        let rows = AppModel.retainedInflightProjection(retained, failure: failure)

        XCTAssertEqual(rows.map(\.author), [.user, .bot, .user, .bot, .user, .bot])
        XCTAssertEqual(rows.map(\.text), [
            "original", "ab", "first correction", "cd", "second correction", "ef",
        ])
        XCTAssertNil(rows[1].failure)
        XCTAssertEqual(rows.last?.failure?.message, "stream dropped")
        XCTAssertEqual(rows.last?.failure?.errorSurface?.layer, .streaming)
    }

    @MainActor
    func testMalformedCorrectionOffsetsUseBoundedLegacyPlacement() throws {
        let live = LiveSession(try json([
            "session_id": "runtime",
            "stored_session_id": "stored",
            "inflight": [
                "user": "original",
                "assistant": "whole partial",
                "corrections": ["redirect"],
                "correction_offsets": ["not-an-integer"],
                "status": "error",
                "error": "failed",
            ],
        ]))
        let retained = try XCTUnwrap(live.retainedInflight)
        XCTAssertTrue(retained.correctionsMalformed)
        let failure = try XCTUnwrap(TurnFailureLifecycle.failure(from: retained))

        let rows = AppModel.retainedInflightProjection(retained, failure: failure)

        XCTAssertEqual(rows.map(\.text), ["original", "whole partial", "redirect"])
        XCTAssertEqual(rows[1].failure?.message, "failed")
    }

    @MainActor
    func testRepeatedRetainedFailureUpsertsOneAssistantRow() throws {
        let model = AppModel()
        let botID = "worker"
        let chat = model.chat(for: botID)
        chat.storedSessionID = "stored"
        let live = LiveSession(try json([
            "session_id": "runtime",
            "stored_session_id": "stored",
            "messages": [["role": "user", "text": "repeat", "row_id": 41]],
            "inflight": [
                "user": "repeat", "assistant": "half", "streaming": false,
                "status": "error", "error": "provider failed", "recoverable": true,
                "error_surface": [
                    "layer": "provider", "code": "unknown", "retryable": true,
                ],
            ],
        ]))

        model.replayInflight(live, botID: botID)
        let firstIDs = chat.messages.map(\.id)
        model.replayInflight(live, botID: botID)

        XCTAssertEqual(chat.messages.map(\.id), firstIDs)
        XCTAssertEqual(chat.messages.filter { $0.author == .bot }.count, 1)
        XCTAssertEqual(chat.messages.last?.failure?.message, "provider failed")
    }

    @MainActor
    func testNewRetainedTurnNeverReusesEarlierFailureAboveItsUser() throws {
        let model = AppModel()
        let botID = "worker"
        let chat = model.chat(for: botID)
        chat.storedSessionID = "stored"
        let earlierFailure = ChatMessage(
            author: .bot, text: "",
            failure: TurnFailure(message: "old failure", recoverable: true))
        let newUser = ChatMessage(author: .user, text: "new prompt")
        chat.messages = [
            ChatMessage(author: .user, text: "old prompt"),
            earlierFailure,
            newUser,
        ]
        let live = LiveSession(try json([
            "session_id": "runtime",
            "stored_session_id": "stored",
            "inflight": [
                "user": "new prompt", "assistant": "", "streaming": true,
            ],
        ]))

        model.replayInflight(live, botID: botID)

        XCTAssertEqual(chat.messages.count, 4)
        XCTAssertEqual(chat.messages[1].id, earlierFailure.id)
        XCTAssertEqual(chat.messages[1].failure?.message, "old failure")
        XCTAssertEqual(chat.messages[2].id, newUser.id)
        XCTAssertEqual(chat.messages[3].author, .bot)
        XCTAssertTrue(chat.messages[3].isStreaming)
        XCTAssertNil(chat.messages[3].failure)
    }

    @MainActor
    func testErrorOnlyTerminalFrameCreatesCardOnlyOnExactSourceChat() throws {
        let model = AppModel()
        model.mode = .live
        let sid = "same-runtime"
        let primaryBot = "worker"
        let remoteBot = "remote::worker"
        LiveRuntime.shared.gatewayID = "primary"
        LiveRuntime.shared.sessionToBot[sid] = primaryBot
        LiveRuntime.shared.routedSessionToBot[
            GatewaySessionRoute(gatewayID: "remote", sessionID: sid)
        ] = remoteBot
        defer {
            LiveRuntime.shared.gatewayID = nil
            LiveRuntime.shared.sessionToBot[sid] = nil
            LiveRuntime.shared.routedSessionToBot[
                GatewaySessionRoute(gatewayID: "remote", sessionID: sid)
            ] = nil
            ChatRuntime.shared.turnFloor[remoteBot] = nil
            ChatRuntime.shared.failedRetryRows[remoteBot] = nil
        }
        let remote = model.chat(for: remoteBot)
        remote.sessionID = sid
        remote.storedSessionID = "stored"
        let historical = ChatMessage(author: .bot, text: "historical answer", rowID: 8)
        remote.messages = [
            ChatMessage(author: .user, text: "old prompt", rowID: 7),
            historical,
            ChatMessage(author: .user, text: "run", rowID: 9),
        ]
        model.handle(event: GatewayEvent(
            type: "message.start", sessionID: sid, payload: [:]),
            sourceGatewayID: "remote")
        let event = GatewayEvent(type: "message.complete", sessionID: sid, payload: [
            "status": "error",
            "text": "Error: invalid model",
            "error": "invalid model",
            "partial": false,
            "recoverable": true,
            "error_surface": [
                "layer": "provider", "code": "model_not_found", "retryable": true,
            ],
        ])

        model.handle(event: event, sourceGatewayID: "remote")

        XCTAssertTrue(model.chat(for: primaryBot).messages.isEmpty)
        XCTAssertEqual(remote.messages.count, 4)
        XCTAssertNil(remote.messages[1].failure,
                     "the new turn must not reuse a historical assistant row")
        XCTAssertEqual(remote.messages.last?.author, .bot)
        XCTAssertEqual(remote.messages.last?.text, "")
        XCTAssertEqual(remote.messages.last?.failure?.message, "invalid model")
        XCTAssertEqual(remote.messages.last?.failure?.errorSurface?.retryable, true)
        XCTAssertFalse(remote.messages.contains(where: { $0.author == .system }))
        let failed = try XCTUnwrap(remote.messages.last)
        XCTAssertTrue(model.canRetryFailedTurn(failed, in: remoteBot))
        let retry = model.prepareFailedTurnRetry(failed, in: remoteBot)
        XCTAssertEqual(retry?.text, "run",
                       "the failure card must own the new turn's prompt")
        XCTAssertEqual(retry?.assistantID, failed.id)
    }

    @MainActor
    func testErrorOnlyCompletionWithoutStartDoesNotStampHistoricalAssistant() {
        let model = AppModel()
        model.mode = .live
        let sid = "error-without-start"
        let botID = "remote::worker"
        let route = GatewaySessionRoute(gatewayID: "remote", sessionID: sid)
        LiveRuntime.shared.routedSessionToBot[route] = botID
        defer {
            LiveRuntime.shared.routedSessionToBot[route] = nil
            ChatRuntime.shared.turnFloor[botID] = nil
        }
        let chat = model.chat(for: botID)
        chat.sessionID = sid
        chat.storedSessionID = "stored"
        let historical = ChatMessage(author: .bot, text: "old answer")
        chat.messages = [
            ChatMessage(author: .user, text: "old prompt"),
            historical,
            ChatMessage(author: .user, text: "new prompt"),
        ]

        model.handle(event: GatewayEvent(
            type: "message.complete", sessionID: sid,
            payload: ["status": "error", "error": "new failure",
                      "recoverable": true]),
            sourceGatewayID: "remote")

        XCTAssertEqual(chat.messages.count, 4)
        XCTAssertEqual(chat.messages[1].id, historical.id)
        XCTAssertNil(chat.messages[1].failure)
        XCTAssertEqual(chat.messages.last?.failure?.message, "new failure")
    }

    @MainActor
    func testAuxiliaryRouterRejectsStaleSessionStartForReboundChat() {
        let model = AppModel()
        model.mode = .live
        let botID = "remote::worker"
        let staleSID = "stale-runtime"
        let currentSID = "current-runtime"
        let staleRoute = GatewaySessionRoute(gatewayID: "remote", sessionID: staleSID)
        LiveRuntime.shared.routedSessionToBot[staleRoute] = botID
        defer {
            LiveRuntime.shared.routedSessionToBot[staleRoute] = nil
            ChatRuntime.shared.turnFloor[botID] = nil
        }
        let chat = model.chat(for: botID)
        chat.sessionID = currentSID
        chat.isRunning = false

        model.routeToolEvent(
            GatewayEvent(type: "message.start", sessionID: staleSID, payload: [:]),
            sourceGatewayID: "remote")

        XCTAssertFalse(chat.isRunning)
        XCTAssertNil(ChatRuntime.shared.turnFloor[botID])
    }

    @MainActor
    func testPartialTerminalFrameKeepsPartialOnFailedAssistant() {
        let model = AppModel()
        model.mode = .live
        let sid = "partial-runtime"
        let botID = "remote::worker"
        LiveRuntime.shared.routedSessionToBot[
            GatewaySessionRoute(gatewayID: "remote", sessionID: sid)
        ] = botID
        defer {
            LiveRuntime.shared.routedSessionToBot[
                GatewaySessionRoute(gatewayID: "remote", sessionID: sid)
            ] = nil
        }
        let chat = model.chat(for: botID)
        chat.sessionID = sid
        chat.messages = [
            ChatMessage(author: .user, text: "run", rowID: 9),
            ChatMessage(author: .bot, text: "half", isStreaming: true),
        ]
        ChatRuntime.shared.turnFloor[botID] = 1

        model.handle(event: GatewayEvent(
            type: "message.complete", sessionID: sid,
            payload: [
                "status": "error", "text": "half an answer", "partial": true,
                "error": "stream reset", "recoverable": true,
            ]), sourceGatewayID: "remote")

        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(chat.messages.last?.text, "half an answer")
        XCTAssertEqual(chat.messages.last?.failure?.message, "stream reset")
        XCTAssertFalse(chat.messages.last?.isStreaming ?? true)
    }

    @MainActor
    func testProtectedRetainedFailureSurvivesRebindingHydration() async throws {
        let user = ChatMessage(author: .user, text: "failed prompt", rowID: 7)
        let failed = ChatMessage(
            author: .bot, text: "partial",
            failure: TurnFailure(message: "network lost", recoverable: true))
        let chat = ChatState(messages: [user, failed])
        ChatRuntime.shared.retainedFailureRows[ObjectIdentifier(chat)] = [user.id, failed.id]
        defer { ChatRuntime.shared.retainedFailureRows[ObjectIdentifier(chat)] = nil }

        try await AppModel.hydrateTranscript(
            chat: chat,
            resumeMessages: [["role": "user", "text": "older", "row_id": 1]],
            clearWhenEmpty: true,
            fallback: { nil },
            accepts: { true })

        XCTAssertEqual(chat.messages.map(\.text), ["older", "failed prompt", "partial"])
        XCTAssertEqual(chat.messages.last?.failure?.message, "network lost")
    }

    @MainActor
    func testDismissFailureDropsEmptyPlaceholderAndFencesReplay() throws {
        let model = AppModel()
        model.mode = .live
        let botID = "primary::worker"
        let chat = model.chat(for: botID)
        chat.storedSessionID = "stored"
        let failed = ChatMessage(
            author: .bot, text: "",
            failure: TurnFailure(message: "billing wall", recoverable: true))
        chat.messages = [ChatMessage(author: .user, text: "hello", rowID: 1), failed]

        model.dismissFailedTurn(failed, in: botID)

        XCTAssertEqual(chat.messages.count, 1)
        XCTAssertEqual(ChatRuntime.shared.dismissedFailures[ObjectIdentifier(chat)]?.message,
                       "billing wall")

        let live = LiveSession(try json([
            "session_id": "runtime", "stored_session_id": "stored",
            "inflight": [
                "user": "hello", "assistant": "", "status": "error",
                "error": "billing wall", "recoverable": true,
            ],
        ]))
        model.replayInflight(live, botID: botID)
        XCTAssertEqual(chat.messages.count, 1)
        XCTAssertNil(chat.messages.last?.failure)
    }

    @MainActor
    func testFailedRetryPolicyUsesSurfaceAndExactCurrentBinding() {
        let model = AppModel()
        model.mode = .live
        let botID = "primary::worker"
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let user = ChatMessage(author: .user, text: "retry me", rowID: 8)
        let retryable = ChatMessage(
            author: .bot, text: "partial",
            failure: TurnFailure(
                message: "rate limited", recoverable: true,
                errorSurface: TurnErrorSurface(
                    layer: .provider, code: "rate_limit", retryable: true)))
        chat.messages = [user, retryable]

        XCTAssertTrue(model.canRetryFailedTurn(retryable, in: botID))
        let before = chat.messages.map(\.id)
        let request = model.prepareFailedTurnRetry(retryable, in: botID)
        XCTAssertEqual(request?.text, "retry me")
        XCTAssertTrue(request?.truncate.isEmpty == true)
        XCTAssertEqual(request?.route,
                       GatewayBotRoute(gatewayID: "primary", profile: "worker"))
        XCTAssertEqual(request?.storedID, "stored")
        XCTAssertEqual(chat.messages.map(\.id), before,
                       "failed Retry must reuse the original user/assistant rows")
        XCTAssertFalse(chat.isRunning,
                       "REST preflight must not expose Stop for the old session")
        XCTAssertTrue(model.hasUnresolvedFailedTurnRetry(in: botID))
        let token = request?.token
        chat.isRunning = false // watchdog-equivalent UI recovery without settlement
        XCTAssertFalse(model.canRetryFailedTurn(retryable, in: botID))
        XCTAssertNil(model.prepareFailedTurnRetry(retryable, in: botID))
        XCTAssertEqual(ChatRuntime.shared.failedRetryRows[botID]?.token, token,
                       "watchdog recovery must not mint or replace an unresolved retry token")
        ChatRuntime.shared.failedRetryRows[botID] = nil
        chat.hasUnresolvedRetry = false
        chat.messages[1].failure?.errorSurface?.retryable = false
        XCTAssertFalse(model.canRetryFailedTurn(chat.messages[1], in: botID))
        chat.messages[1].failure?.errorSurface = nil
        chat.sessionID = nil
        XCTAssertFalse(model.canRetryFailedTurn(chat.messages[1], in: botID))
    }

    @MainActor
    func testRetryCompletionWithoutStartReusesAssistantAndAddsNoUser() throws {
        let model = AppModel()
        model.mode = .live
        let botID = "primary::worker"
        let sid = "runtime"
        let route = GatewaySessionRoute(gatewayID: "primary", sessionID: sid)
        LiveRuntime.shared.routedSessionToBot[route] = botID
        defer { LiveRuntime.shared.routedSessionToBot[route] = nil }
        let chat = model.chat(for: botID)
        chat.sessionID = sid
        chat.storedSessionID = "stored"
        let user = ChatMessage(author: .user, text: "retry me", rowID: 8)
        let failed = ChatMessage(
            author: .bot, text: "old partial",
            failure: TurnFailure(message: "failed", recoverable: true))
        chat.messages = [user, failed]
        let originalIDs = chat.messages.map(\.id)
        let request = try XCTUnwrap(model.prepareFailedTurnRetry(failed, in: botID))
        XCTAssertTrue(model.applyFailedRetryAuthoritativeBaseline(
            request, in: botID, rows: [user]))
        XCTAssertTrue(model.admitFailedTurnRetrySubmission(request, in: botID))

        model.handle(event: GatewayEvent(
            type: "message.complete", sessionID: sid,
            payload: ["status": "complete", "text": "fresh answer"]),
            sourceGatewayID: "primary")

        XCTAssertEqual(chat.messages.map(\.id), originalIDs)
        XCTAssertEqual(chat.messages.map(\.text), ["retry me", "fresh answer"])
        XCTAssertNil(chat.messages.last?.failure)
        XCTAssertNil(ChatRuntime.shared.failedRetryRows[botID])
    }

    @MainActor
    func testPreparedRetryCancelledByUnrelatedStartNeverOwnsAssistantOrSubmission() throws {
        let model = AppModel()
        model.mode = .live
        let botID = "remote::worker"
        let sid = "unrelated-start"
        let route = GatewaySessionRoute(gatewayID: "remote", sessionID: sid)
        LiveRuntime.shared.routedSessionToBot[route] = botID
        defer {
            LiveRuntime.shared.routedSessionToBot[route] = nil
            ChatRuntime.shared.failedRetryRows[botID] = nil
            ChatRuntime.shared.turnFloor[botID] = nil
        }
        let chat = model.chat(for: botID)
        chat.sessionID = sid
        chat.storedSessionID = "stored"
        let failed = ChatMessage(
            author: .bot, text: "partial",
            failure: TurnFailure(message: "failed", recoverable: true))
        let originalUser = ChatMessage(author: .user, text: "retry me", rowID: 10)
        chat.messages = [originalUser, failed]
        let request = try XCTUnwrap(model.prepareFailedTurnRetry(failed, in: botID))

        model.handle(event: GatewayEvent(
            type: "message.start", sessionID: sid, payload: [:]),
            sourceGatewayID: "remote")

        XCTAssertNil(ChatRuntime.shared.failedRetryRows[botID])
        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(chat.messages.last?.failure?.message, "failed")
        XCTAssertFalse(chat.messages.last?.isStreaming ?? true)
        XCTAssertFalse(model.admitFailedTurnRetrySubmission(request, in: botID),
                       "a cancelled prepared token cannot reach submit or steer")
    }

    @MainActor
    func testFenceBetweenRetryPrepareAndSendKeepsCardAndClearsBusyState() async throws {
        let model = AppModel()
        model.mode = .live
        let botID = "fenced::worker"
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let failed = ChatMessage(
            author: .bot, text: "partial",
            failure: TurnFailure(message: "failed", recoverable: true))
        chat.messages = [ChatMessage(author: .user, text: "retry me"), failed]
        let request = try XCTUnwrap(model.prepareFailedTurnRetry(failed, in: botID))
        ChatRuntime.shared.transcriptFences[botID] = TranscriptActionFence(
            operationID: UUID(), sessionID: "runtime", storedID: "stored",
            gatewayID: "fenced", profile: "worker", generation: 0,
            chatID: ObjectIdentifier(chat))
        defer {
            ChatRuntime.shared.transcriptFences[botID] = nil
            ChatRuntime.shared.failedRetryRows[botID] = nil
        }
        var admissionCalls = 0

        let result = await model.liveSendAwaiting(
            text: request.text, botID: botID, chat: chat,
            preSubmitAdmission: {
                admissionCalls += 1
                return model.admitFailedTurnRetrySubmission(request, in: botID)
            })
        model.settleFailedTurnRetry(request, result: result, in: botID, chat: chat)

        XCTAssertEqual(result, .retained)
        XCTAssertEqual(admissionCalls, 0,
                       "the fence must abort before the submit/steer boundary")
        XCTAssertNil(ChatRuntime.shared.failedRetryRows[botID])
        XCTAssertFalse(chat.isRunning)
        XCTAssertEqual(chat.messages.last?.failure?.message, "failed")
        XCTAssertTrue(model.composeQueue.isEmpty)
    }

    @MainActor
    func testProvenAmbiguousRetryAtomicallyRetiresExactQueueAndLease() throws {
        let model = AppModel()
        model.mode = .live
        let botID = "proof::worker"
        let route = GatewayBotRoute(gatewayID: "proof", profile: "worker")
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let failed = ChatMessage(
            author: .bot, text: "old partial",
            failure: TurnFailure(message: "failed", recoverable: true))
        let originalUser = ChatMessage(author: .user, text: "retry me", rowID: 10)
        chat.messages = [originalUser, failed]
        let request = try XCTUnwrap(model.prepareFailedTurnRetry(failed, in: botID))
        XCTAssertTrue(model.admitFailedTurnRetrySubmission(request, in: botID))
        model.appendComposeQueue(
            botID: botID, text: request.text, id: request.token,
            route: route, storedID: "stored", sessionID: "runtime",
            chatID: ObjectIdentifier(chat))
        let unrelatedID = UUID()
        model.appendComposeQueue(botID: "other::worker", text: "keep", id: unrelatedID)
        let fence = OfflineComposeFence(
            itemID: request.token, botID: botID, text: request.text,
            route: route, sessionID: "runtime", storedID: "stored",
            chatID: ObjectIdentifier(chat), baselineDurableUserRowIDs: [10],
            baselineDurableUserRowIDWatermark: 10)
        ChatRuntime.shared.offlineComposeFences[request.token] = fence
        defer {
            ChatRuntime.shared.offlineComposeFences.removeAll()
            ChatRuntime.shared.failedRetryRows.removeAll()
        }

        XCTAssertFalse(AppModel.provesOfflineComposeDelivery(fence, rows: [originalUser]),
                       "the original failed turn is not retry-delivery proof")
        let olderDuplicate = ChatMessage(author: .user, text: "retry me", rowID: 5)
        XCTAssertFalse(AppModel.provesOfflineComposeDelivery(
            fence, rows: [olderDuplicate]),
            "set nonmembership below the watermark is still old evidence")
        XCTAssertNotNil(ChatRuntime.shared.offlineComposeFences[request.token])
        let delivered = ChatMessage(author: .user, text: "retry me", rowID: 11)
        XCTAssertTrue(AppModel.provesOfflineComposeDelivery(
            fence, rows: [originalUser, delivered]))
        model.retireProvenOfflineCompose(fence, running: false)

        XCTAssertNil(ChatRuntime.shared.offlineComposeFences[request.token])
        XCTAssertNil(ChatRuntime.shared.failedRetryRows[botID])
        XCTAssertNil(model.composeQueueBindings[request.token])
        XCTAssertFalse(model.composeQueueIDs.contains(request.token))
        XCTAssertEqual(model.composeQueueIDs, [unrelatedID])
        XCTAssertEqual(model.composeQueue.map(\.text), ["keep"])
        XCTAssertFalse(chat.isRunning)
        XCTAssertEqual(chat.messages.map(\.author), [.user])

        var nilBaseline = fence
        nilBaseline.baselineDurableUserRowIDWatermark = nil
        XCTAssertFalse(AppModel.provesOfflineComposeDelivery(
            nilBaseline, rows: [ChatMessage(author: .user, text: "retry me", rowID: 12)]),
            "an undurable pre-submit baseline cannot be auto-proven by hydration")
    }

    @MainActor
    func testRetryBackedComposeRetirementPreservesEverySurfaceWhenAssistantMissing() throws {
        let model = AppModel()
        model.mode = .live
        let botID = "transaction::worker"
        let route = GatewayBotRoute(gatewayID: "transaction", profile: "worker")
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let failed = ChatMessage(
            author: .bot, text: "partial",
            failure: TurnFailure(message: "failed", recoverable: true))
        chat.messages = [ChatMessage(author: .user, text: "retry", rowID: 10), failed]
        let request = try XCTUnwrap(model.prepareFailedTurnRetry(failed, in: botID))
        XCTAssertTrue(model.applyFailedRetryAuthoritativeBaseline(
            request, in: botID, rows: chat.messages))
        XCTAssertTrue(model.admitFailedTurnRetrySubmission(request, in: botID))
        model.appendComposeQueue(
            botID: botID, text: request.text, id: request.token,
            route: route, storedID: "stored", sessionID: "runtime",
            chatID: ObjectIdentifier(chat))
        let fence = OfflineComposeFence(
            itemID: request.token, botID: botID, text: request.text,
            route: route, sessionID: "runtime", storedID: "stored",
            chatID: ObjectIdentifier(chat),
            baselineDurableUserRowIDWatermark: 10)
        ChatRuntime.shared.offlineComposeFences[request.token] = fence
        chat.messages.removeAll(where: { $0.id == failed.id })
        defer {
            ChatRuntime.shared.offlineComposeFences[request.token] = nil
            ChatRuntime.shared.failedRetryRows[botID] = nil
        }

        model.retireProvenOfflineCompose(fence, running: false)

        XCTAssertEqual(ChatRuntime.shared.offlineComposeFences[request.token], fence)
        XCTAssertEqual(ChatRuntime.shared.failedRetryRows[botID]?.token, request.token)
        XCTAssertTrue(chat.hasUnresolvedRetry)
        XCTAssertTrue(model.composeQueueIDs.contains(request.token))
        XCTAssertNotNil(model.composeQueueBindings[request.token])
    }

    @MainActor
    func testDismissCannotMutatePreparedOrSubmittingRetryOwnedFailure() throws {
        let model = AppModel()
        model.mode = .live
        let botID = "remote::dismiss-owned"
        let sid = "runtime"
        let sessionRoute = GatewaySessionRoute(gatewayID: "remote", sessionID: sid)
        LiveRuntime.shared.routedSessionToBot[sessionRoute] = botID
        defer {
            LiveRuntime.shared.routedSessionToBot[sessionRoute] = nil
            ChatRuntime.shared.failedRetryRows[botID] = nil
        }
        let chat = model.chat(for: botID)
        chat.sessionID = sid
        chat.storedSessionID = "stored"
        let failed = ChatMessage(
            author: .bot, text: "partial",
            failure: TurnFailure(message: "failed", recoverable: true))
        chat.messages = [ChatMessage(author: .user, text: "retry", rowID: 10), failed]
        let request = try XCTUnwrap(model.prepareFailedTurnRetry(failed, in: botID))

        XCTAssertFalse(model.canDismissFailedTurn(failed, in: botID))
        model.dismissFailedTurn(failed, in: botID)
        XCTAssertEqual(chat.messages.last?.failure?.message, "failed")
        XCTAssertTrue(model.applyFailedRetryAuthoritativeBaseline(
            request, in: botID, rows: chat.messages))
        XCTAssertTrue(model.admitFailedTurnRetrySubmission(request, in: botID))
        model.dismissFailedTurn(failed, in: botID)
        XCTAssertEqual(chat.messages.last?.failure?.message, "failed")

        model.handle(event: GatewayEvent(
            type: "message.start", sessionID: sid, payload: [:]),
            sourceGatewayID: "remote")
        model.handle(event: GatewayEvent(
            type: "message.complete", sessionID: sid,
            payload: ["status": "complete", "text": "finished"]),
            sourceGatewayID: "remote")
        XCTAssertNil(ChatRuntime.shared.failedRetryRows[botID])
        XCTAssertFalse(chat.hasUnresolvedRetry)
        XCTAssertEqual(chat.messages.last?.text, "finished")
        XCTAssertNil(chat.messages.last?.failure)
    }

    @MainActor
    func testUnchangedOldResumeDoesNotConsumeSubmittingRetryBeforeLaterStart() throws {
        let model = AppModel()
        model.mode = .live
        let botID = "remote::worker"
        let sid = "retry-old-resume"
        let sessionRoute = GatewaySessionRoute(gatewayID: "remote", sessionID: sid)
        let staleRoute = GatewaySessionRoute(gatewayID: "remote", sessionID: "stale-sid")
        let foreignRoute = GatewaySessionRoute(gatewayID: "foreign", sessionID: sid)
        LiveRuntime.shared.routedSessionToBot[sessionRoute] = botID
        LiveRuntime.shared.routedSessionToBot[staleRoute] = botID
        LiveRuntime.shared.routedSessionToBot[foreignRoute] = botID
        defer {
            LiveRuntime.shared.routedSessionToBot[sessionRoute] = nil
            LiveRuntime.shared.routedSessionToBot[staleRoute] = nil
            LiveRuntime.shared.routedSessionToBot[foreignRoute] = nil
            ChatRuntime.shared.failedRetryRows[botID] = nil
            ChatRuntime.shared.turnFloor[botID] = nil
        }
        let chat = model.chat(for: botID)
        chat.sessionID = sid
        chat.storedSessionID = "stored"
        let failed = ChatMessage(
            author: .bot, text: "old partial",
            failure: TurnFailure(message: "same failure", recoverable: true))
        chat.messages = [ChatMessage(author: .user, text: "retry me"), failed]
        let request = try XCTUnwrap(model.prepareFailedTurnRetry(failed, in: botID))
        XCTAssertTrue(model.admitFailedTurnRetrySubmission(request, in: botID))
        let old = LiveSession(try json([
            "session_id": sid, "stored_session_id": "stored",
            "inflight": [
                "user": "retry me", "assistant": "old partial",
                "status": "error", "error": "same failure",
                "recoverable": true, "streaming": false,
            ],
        ]))

        model.replayInflight(old, botID: botID)

        XCTAssertEqual(ChatRuntime.shared.failedRetryRows[botID]?.token, request.token)
        XCTAssertEqual(ChatRuntime.shared.failedRetryRows[botID]?.phase, .submitting)
        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(chat.messages.last?.failure?.message, "same failure")

        model.handle(event: GatewayEvent(
            type: "message.start", sessionID: sid, payload: [:]),
            sourceGatewayID: "foreign")
        model.handle(event: GatewayEvent(
            type: "message.start", sessionID: "stale-sid", payload: [:]),
            sourceGatewayID: "remote")
        model.handle(event: GatewayEvent(
            type: "message.complete", sessionID: sid,
            payload: [
                "status": "error", "text": "old partial", "partial": true,
                "error": "same failure", "recoverable": true,
            ]), sourceGatewayID: "remote")

        XCTAssertEqual(ChatRuntime.shared.failedRetryRows[botID]?.phase, .submitting)
        XCTAssertEqual(chat.messages.last?.failure?.message, "same failure")

        model.handle(event: GatewayEvent(
            type: "message.start", sessionID: sid, payload: [:]),
            sourceGatewayID: "remote")

        XCTAssertEqual(ChatRuntime.shared.failedRetryRows[botID]?.token, request.token)
        XCTAssertEqual(ChatRuntime.shared.failedRetryRows[botID]?.phase, .started)
        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(chat.messages.last?.id, failed.id)
        XCTAssertNil(chat.messages.last?.failure)
        XCTAssertEqual(chat.messages.last?.text, "")
        XCTAssertTrue(chat.messages.last?.isStreaming ?? false)

        model.replayInflight(old, botID: botID)
        XCTAssertEqual(ChatRuntime.shared.failedRetryRows[botID]?.phase, .started)
        XCTAssertEqual(chat.messages.last?.id, failed.id)
        XCTAssertNil(chat.messages.last?.failure)

        model.handle(event: GatewayEvent(
            type: "message.complete", sessionID: sid,
            payload: ["status": "complete", "text": "fresh answer"]),
            sourceGatewayID: "remote")
        XCTAssertNil(ChatRuntime.shared.failedRetryRows[botID])
        XCTAssertEqual(chat.messages.last?.text, "fresh answer")
        XCTAssertNil(chat.messages.last?.failure)
    }

    @MainActor
    func testAcceptedRetryWithoutEventsReconcilesOnlyFromPostWatermarkProof() throws {
        let model = AppModel()
        model.mode = .live
        let botID = "proofless::worker"
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let user = ChatMessage(author: .user, text: "retry me", rowID: 10)
        let failed = ChatMessage(
            author: .bot, text: "old partial",
            failure: TurnFailure(message: "failed", recoverable: true))
        chat.messages = [user, failed]
        let request = try XCTUnwrap(model.prepareFailedTurnRetry(failed, in: botID))
        XCTAssertTrue(model.applyFailedRetryAuthoritativeBaseline(
            request, in: botID, rows: [user]))
        XCTAssertTrue(model.admitFailedTurnRetrySubmission(request, in: botID))
        let lease = try XCTUnwrap(ChatRuntime.shared.failedRetryRows[botID])
        defer { ChatRuntime.shared.failedRetryRows[botID] = nil }

        chat.isRunning = false // watchdog-equivalent after accepted RPC, no events
        XCTAssertTrue(model.retainedMutationNeedsReconciliation(botID: botID))
        XCTAssertFalse(model.canRetryFailedTurn(failed, in: botID))
        XCTAssertFalse(model.reconcileFailedRetryLeaseFromAuthority(
            lease, botID: botID,
            rows: [user, ChatMessage(author: .user, text: "retry me", rowID: 5)],
            running: false))
        XCTAssertEqual(ChatRuntime.shared.failedRetryRows[botID]?.token, request.token)
        XCTAssertEqual(chat.messages.last?.failure?.message, "failed")

        let deliveredUser = ChatMessage(author: .user, text: "retry me", rowID: 11)
        let deliveredAnswer = ChatMessage(author: .bot, text: "durable answer", rowID: 12)
        XCTAssertTrue(model.reconcileFailedRetryLeaseFromAuthority(
            lease, botID: botID,
            rows: [user, deliveredUser, deliveredAnswer],
            running: false))
        XCTAssertNil(ChatRuntime.shared.failedRetryRows[botID])
        XCTAssertEqual(chat.messages.map(\.author), [.user, .user, .bot])
        XCTAssertEqual(chat.messages.last?.text, "durable answer")
        XCTAssertEqual(chat.messages.last?.rowID, 12)
    }

    @MainActor
    func testAuthoritativeKnownEmptyBaselineCanProveFirstDurableRetryRow() throws {
        let model = AppModel()
        model.mode = .live
        let botID = "empty::worker"
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let failed = ChatMessage(
            author: .bot, text: "old",
            failure: TurnFailure(message: "failed", recoverable: true))
        chat.messages = [ChatMessage(author: .user, text: "retry"), failed]
        let request = try XCTUnwrap(model.prepareFailedTurnRetry(failed, in: botID))
        defer { ChatRuntime.shared.failedRetryRows[botID] = nil }

        XCTAssertFalse(AppModel.provesFailedRetryDelivery(
            try XCTUnwrap(ChatRuntime.shared.failedRetryRows[botID]),
            rows: [ChatMessage(author: .user, text: "retry", rowID: 1)]))
        XCTAssertTrue(model.applyFailedRetryAuthoritativeBaseline(
            request, in: botID, rows: []))
        XCTAssertTrue(model.admitFailedTurnRetrySubmission(request, in: botID))
        XCTAssertTrue(AppModel.provesFailedRetryDelivery(
            try XCTUnwrap(ChatRuntime.shared.failedRetryRows[botID]),
            rows: [ChatMessage(author: .user, text: "retry", rowID: 1)]))
        let fence = OfflineComposeFence(
            itemID: request.token, botID: botID, text: request.text,
            route: request.route, sessionID: "runtime", storedID: "stored",
            chatID: ObjectIdentifier(chat), baselineAuthorityKnown: true)
        XCTAssertTrue(AppModel.provesOfflineComposeDelivery(
            fence, rows: [ChatMessage(author: .user, text: "retry", rowID: 1)]))
    }

    @MainActor
    func testAuthoritativeRetryProofProjectsFreshRetainedFailure() throws {
        let model = AppModel()
        model.mode = .live
        let botID = "retained::worker"
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let user = ChatMessage(author: .user, text: "retry", rowID: 10)
        let failed = ChatMessage(
            author: .bot, text: "old partial",
            failure: TurnFailure(message: "old failure", recoverable: true))
        chat.messages = [user, failed]
        let request = try XCTUnwrap(model.prepareFailedTurnRetry(failed, in: botID))
        XCTAssertTrue(model.applyFailedRetryAuthoritativeBaseline(
            request, in: botID, rows: [user]))
        XCTAssertTrue(model.admitFailedTurnRetrySubmission(request, in: botID))
        let lease = try XCTUnwrap(ChatRuntime.shared.failedRetryRows[botID])
        let live = LiveSession(try json([
            "session_id": "runtime", "stored_session_id": "stored",
            "inflight": [
                "user": "retry", "assistant": "new partial", "streaming": false,
                "status": "error", "error": "new failure", "recoverable": true,
            ],
        ]))
        defer { ChatRuntime.shared.failedRetryRows[botID] = nil }

        XCTAssertTrue(model.reconcileFailedRetryLeaseFromAuthority(
            lease, botID: botID,
            rows: [user, ChatMessage(author: .user, text: "retry", rowID: 11)],
            running: false, retainedInflight: live.retainedInflight))
        XCTAssertNil(ChatRuntime.shared.failedRetryRows[botID])
        XCTAssertEqual(chat.messages.last?.id, failed.id)
        XCTAssertEqual(chat.messages.last?.text, "new partial")
        XCTAssertEqual(chat.messages.last?.failure?.message, "new failure")
    }

    @MainActor
    func testAuthoritativeRetryProofProjectsHealthyRetainedStreamingPrefix() throws {
        let model = AppModel()
        model.mode = .live
        let botID = "healthy::worker"
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let user = ChatMessage(author: .user, text: "retry", rowID: 10)
        let failed = ChatMessage(
            author: .bot, text: "old partial",
            failure: TurnFailure(message: "old failure", recoverable: true))
        chat.messages = [user, failed]
        let request = try XCTUnwrap(model.prepareFailedTurnRetry(failed, in: botID))
        XCTAssertFalse(chat.isRunning)
        XCTAssertTrue(model.applyFailedRetryAuthoritativeBaseline(
            request, in: botID, rows: [user]))
        XCTAssertTrue(model.admitFailedTurnRetrySubmission(request, in: botID))
        XCTAssertTrue(chat.isRunning)
        let lease = try XCTUnwrap(ChatRuntime.shared.failedRetryRows[botID])
        let live = LiveSession(try json([
            "session_id": "runtime", "stored_session_id": "stored",
            "inflight": [
                "user": "retry", "assistant": "healthy prefix", "streaming": true,
                "status": "complete",
            ],
        ]))
        defer { ChatRuntime.shared.failedRetryRows[botID] = nil }

        XCTAssertTrue(model.reconcileFailedRetryLeaseFromAuthority(
            lease, botID: botID,
            rows: [user, ChatMessage(author: .user, text: "retry", rowID: 11)],
            running: true, retainedInflight: live.retainedInflight))
        XCTAssertEqual(chat.messages.last?.id, failed.id)
        XCTAssertEqual(chat.messages.last?.text, "healthy prefix")
        XCTAssertNil(chat.messages.last?.failure)
        XCTAssertTrue(chat.messages.last?.isStreaming ?? false)
    }

    @MainActor
    func testStartedRetryLaggingResumeSettlesWithoutGhostOrLeaseLoss() throws {
        let model = AppModel()
        model.mode = .live
        let botID = "remote::started"
        let sid = "runtime"
        let sessionRoute = GatewaySessionRoute(gatewayID: "remote", sessionID: sid)
        LiveRuntime.shared.routedSessionToBot[sessionRoute] = botID
        defer {
            LiveRuntime.shared.routedSessionToBot[sessionRoute] = nil
            ChatRuntime.shared.failedRetryRows[botID] = nil
        }
        let chat = model.chat(for: botID)
        chat.sessionID = sid
        chat.storedSessionID = "stored"
        let user = ChatMessage(author: .user, text: "retry", rowID: 10)
        let failed = ChatMessage(
            author: .bot, text: "old partial",
            failure: TurnFailure(message: "old failure", recoverable: true))
        chat.messages = [user, failed]
        let request = try XCTUnwrap(model.prepareFailedTurnRetry(failed, in: botID))
        XCTAssertTrue(model.applyFailedRetryAuthoritativeBaseline(
            request, in: botID, rows: [user]))
        XCTAssertTrue(model.admitFailedTurnRetrySubmission(request, in: botID))
        model.handle(event: GatewayEvent(
            type: "message.start", sessionID: sid, payload: [:]),
            sourceGatewayID: "remote")
        let startedLease = try XCTUnwrap(ChatRuntime.shared.failedRetryRows[botID])
        XCTAssertEqual(startedLease.phase, .started)
        let lagging = LiveSession(try json([
            "session_id": sid, "stored_session_id": "stored",
            "inflight": [
                "user": "retry", "assistant": "old partial", "streaming": false,
                "status": "error", "error": "old failure", "recoverable": true,
            ],
        ]))
        let delivered = ChatMessage(author: .user, text: "retry", rowID: 11)

        XCTAssertTrue(model.reconcileFailedRetryLeaseFromAuthority(
            startedLease, botID: botID, rows: [user, delivered], running: false,
            retainedInflight: lagging.retainedInflight))
        XCTAssertNil(ChatRuntime.shared.failedRetryRows[botID])
        XCTAssertFalse(chat.hasUnresolvedRetry)
        XCTAssertEqual(chat.messages.map(\.author), [.user, .user])
        XCTAssertFalse(chat.messages.contains(where: { $0.id == failed.id }))
    }

    @MainActor
    func testObservableRetryOwnershipTracksPrepareAdmissionAndRetirement() throws {
        let model = AppModel()
        model.mode = .live
        let botID = "observable::worker"
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let failed = ChatMessage(
            author: .bot, text: "partial",
            failure: TurnFailure(message: "failed", recoverable: true))
        chat.messages = [ChatMessage(author: .user, text: "retry", rowID: 1), failed]

        let request = try XCTUnwrap(model.prepareFailedTurnRetry(failed, in: botID))
        XCTAssertTrue(chat.hasUnresolvedRetry)
        XCTAssertTrue(model.hasUnresolvedFailedTurnRetry(in: botID))
        XCTAssertFalse(chat.isRunning)
        XCTAssertTrue(model.applyFailedRetryAuthoritativeBaseline(
            request, in: botID, rows: chat.messages))
        XCTAssertTrue(model.admitFailedTurnRetrySubmission(request, in: botID))
        XCTAssertTrue(chat.hasUnresolvedRetry)
        XCTAssertTrue(chat.isRunning)

        model.settleFailedTurnRetry(
            request, result: .failed, in: botID, chat: chat)
        XCTAssertFalse(chat.hasUnresolvedRetry)
        XCTAssertFalse(model.hasUnresolvedFailedTurnRetry(in: botID))
        XCTAssertFalse(chat.isRunning)
    }

    @MainActor
    func testUnresolvedRetryLeaseFencesOrdinaryComposerAfterWatchdog() throws {
        let model = AppModel()
        model.mode = .live
        let botID = "fenced::worker"
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let failed = ChatMessage(
            author: .bot, text: "old",
            failure: TurnFailure(message: "failed", recoverable: true))
        chat.messages = [ChatMessage(author: .user, text: "retry", rowID: 1), failed]
        let request = try XCTUnwrap(model.prepareFailedTurnRetry(failed, in: botID))
        XCTAssertTrue(model.applyFailedRetryAuthoritativeBaseline(
            request, in: botID, rows: chat.messages))
        XCTAssertTrue(model.admitFailedTurnRetrySubmission(request, in: botID))
        defer { ChatRuntime.shared.failedRetryRows[botID] = nil }
        chat.isRunning = false
        let before = chat.messages
        let queueCount = model.composeQueue.count

        model.sendOrSteer(text: "ordinary composer send", to: botID)

        XCTAssertEqual(chat.messages, before)
        XCTAssertEqual(model.composeQueue.count, queueCount)
        XCTAssertEqual(ChatRuntime.shared.failedRetryRows[botID]?.token, request.token)
    }

    @MainActor
    func testStaleMappedLifecycleEventsCannotMutateCurrentChat() {
        let model = AppModel()
        model.mode = .live
        let botID = "remote::worker"
        let currentSID = "current"
        let staleSID = "stale"
        let staleRoute = GatewaySessionRoute(gatewayID: "remote", sessionID: staleSID)
        LiveRuntime.shared.routedSessionToBot[staleRoute] = botID
        defer { LiveRuntime.shared.routedSessionToBot[staleRoute] = nil }
        let chat = model.chat(for: botID)
        chat.sessionID = currentSID
        chat.storedSessionID = "stored"
        chat.messages = [ChatMessage(author: .bot, text: "current", isStreaming: true)]
        chat.isTyping = true
        let before = chat.messages

        for event in [
            GatewayEvent(type: "message.start", sessionID: staleSID, payload: [:]),
            GatewayEvent(type: "message.delta", sessionID: staleSID,
                         payload: ["text": " stale"]),
            GatewayEvent(type: "thinking.delta", sessionID: staleSID,
                         payload: ["text": "secret"]),
            GatewayEvent(type: "message.interim", sessionID: staleSID,
                         payload: ["text": "interim"]),
            GatewayEvent(type: "message.complete", sessionID: staleSID,
                         payload: ["status": "complete", "text": "wrong"]),
        ] {
            model.handle(event: event, sourceGatewayID: "remote")
        }
        XCTAssertEqual(chat.messages, before)
        XCTAssertTrue(chat.isTyping)
    }

    @MainActor
    func testExactMappedLifecycleEventCanPopulateUnboundBackgroundChat() {
        let model = AppModel()
        model.mode = .live
        let botID = "remote::background"
        let sid = "background-runtime"
        let route = GatewaySessionRoute(gatewayID: "remote", sessionID: sid)
        LiveRuntime.shared.routedSessionToBot[route] = botID
        defer { LiveRuntime.shared.routedSessionToBot[route] = nil }
        let chat = model.chat(for: botID)
        XCTAssertNil(chat.sessionID)

        model.handle(event: GatewayEvent(
            type: "message.delta", sessionID: sid,
            payload: ["text": "background answer"]),
            sourceGatewayID: "remote")

        XCTAssertEqual(chat.messages.last?.text, "background answer")
        XCTAssertTrue(chat.messages.last?.isStreaming ?? false)
    }

    @MainActor
    func testExactReconnectMigratesRetrySIDAndRejectsStaleOldSessionEvent() throws {
        let model = AppModel()
        model.mode = .live
        let botID = "remote::worker"
        let route = GatewayBotRoute(gatewayID: "remote", profile: "worker")
        let oldSID = "old-runtime"
        let newSID = "new-runtime"
        let oldRoute = GatewaySessionRoute(gatewayID: "remote", sessionID: oldSID)
        let newRoute = GatewaySessionRoute(gatewayID: "remote", sessionID: newSID)
        LiveRuntime.shared.routedSessionToBot[oldRoute] = botID
        LiveRuntime.shared.routedSessionToBot[newRoute] = botID
        defer {
            LiveRuntime.shared.routedSessionToBot[oldRoute] = nil
            LiveRuntime.shared.routedSessionToBot[newRoute] = nil
            ChatRuntime.shared.failedRetryRows[botID] = nil
            ChatRuntime.shared.turnFloor[botID] = nil
        }
        let chat = model.chat(for: botID)
        chat.sessionID = oldSID
        chat.storedSessionID = "stored"
        let failed = ChatMessage(
            author: .bot, text: "old partial",
            failure: TurnFailure(message: "failed", recoverable: true))
        chat.messages = [ChatMessage(author: .user, text: "retry", rowID: 10), failed]
        let request = try XCTUnwrap(model.prepareFailedTurnRetry(failed, in: botID))
        XCTAssertTrue(model.admitFailedTurnRetrySubmission(request, in: botID))

        chat.sessionID = newSID
        ChatRuntime.shared.migrateMutationState(
            botID: botID, route: route, sessionID: newSID, storedID: "stored",
            generation: 1, chatID: ObjectIdentifier(chat), oldSessionID: oldSID)
        XCTAssertEqual(ChatRuntime.shared.failedRetryRows[botID]?.sessionID, newSID)

        model.handle(event: GatewayEvent(
            type: "message.start", sessionID: oldSID, payload: [:]),
            sourceGatewayID: "remote")
        XCTAssertEqual(ChatRuntime.shared.failedRetryRows[botID]?.phase, .submitting)
        XCTAssertEqual(chat.messages.last?.failure?.message, "failed")

        model.handle(event: GatewayEvent(
            type: "message.start", sessionID: newSID, payload: [:]),
            sourceGatewayID: "remote")
        XCTAssertEqual(ChatRuntime.shared.failedRetryRows[botID]?.phase, .started)
        XCTAssertEqual(chat.messages.last?.id, failed.id)
        XCTAssertNil(chat.messages.last?.failure)
    }

    @MainActor
    func testDismissFailureRetainsPartialAssistantContent() {
        let model = AppModel()
        model.mode = .live
        let botID = "primary::worker"
        let chat = model.chat(for: botID)
        chat.storedSessionID = "stored"
        let failed = ChatMessage(
            author: .bot, text: "useful partial",
            failure: TurnFailure(message: "stream reset", recoverable: true))
        chat.messages = [ChatMessage(author: .user, text: "hello", rowID: 1), failed]

        model.dismissFailedTurn(failed, in: botID)

        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(chat.messages.last?.text, "useful partial")
        XCTAssertNil(chat.messages.last?.failure)
    }

    func testFailureMessageAdmissionBoundsScalarsAndRemovesSpoofingControls() {
        let hostile = "start\u{202E}\u{0000}\nkept"
            + String(repeating: "a\u{0301}", count: 10_000)
        let admitted = TurnFailureLifecycle.admittedMessage(hostile)

        XCTAssertLessThanOrEqual(admitted.unicodeScalars.count,
                                 TurnFailureLifecycle.maximumMessageScalars)
        XCTAssertTrue(admitted.contains("turn detail clipped"))
        XCTAssertFalse(admitted.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0 })
    }

    func testFailureMessageAdmissionDoesNotLetStrippedControlsHideSafeTail() {
        let controls = String(repeating: "\u{001B}",
                              count: TurnFailureLifecycle.maximumMessageScalars * 2)
        let admitted = TurnFailureLifecycle.admittedMessage(controls + "safe tail")

        XCTAssertEqual(admitted, "safe tail")
    }

    func testMalformedStatusWithStructuredSurfaceStillCreatesFailure() {
        let payload = MessageCompletePayload([
            "status": "future-status",
            "text": "provider fallback",
            "error_surface": [
                "layer": "provider", "code": "future_error", "retryable": false,
            ],
        ])

        let failure = TurnFailureLifecycle.failure(from: payload)

        XCTAssertEqual(failure?.message, "provider fallback")
        XCTAssertEqual(failure?.errorSurface?.code, "future_error")
        XCTAssertEqual(failure?.errorSurface?.retryable, false)
    }

    func testUnknownAndNonstringStatusUseTextAsLiveResumeFailureFallback() throws {
        for status: JSONValue in ["future-status", 7] {
            let live = MessageCompletePayload([
                "status": status, "text": "bounded fallback",
            ])
            let liveFailure = try XCTUnwrap(TurnFailureLifecycle.failure(from: live))

            let resumed = LiveSession([
                "session_id": "runtime", "stored_session_id": "stored",
                "inflight": [
                    "status": status,
                    "assistant": "bounded fallback", "streaming": false,
                ],
            ])
            let retained = try XCTUnwrap(resumed.retainedInflight)
            let resumedFailure = try XCTUnwrap(TurnFailureLifecycle.failure(from: retained))

            XCTAssertEqual(live.status, .malformed)
            XCTAssertEqual(retained.status, .malformed)
            XCTAssertEqual(liveFailure.message, "bounded fallback")
            XCTAssertEqual(resumedFailure.message, liveFailure.message)
        }
    }

    @MainActor
    func testHugeLiveThenResumeFailureUsesCanonicalIdentityAndDoesNotDuplicate() throws {
        let model = AppModel()
        model.mode = .live
        let botID = "remote::worker"
        let sid = "huge-dedupe-runtime"
        let route = GatewaySessionRoute(gatewayID: "remote", sessionID: sid)
        LiveRuntime.shared.routedSessionToBot[route] = botID
        defer {
            LiveRuntime.shared.routedSessionToBot[route] = nil
            ChatRuntime.shared.turnFloor[botID] = nil
            ChatRuntime.shared.retainedFailureRows[ObjectIdentifier(model.chat(for: botID))] = nil
        }
        let chat = model.chat(for: botID)
        chat.sessionID = sid
        chat.storedSessionID = "stored"
        chat.messages = [ChatMessage(author: .user, text: "run", rowID: 1)]
        let huge = String(repeating: "x", count: 40_000)

        model.handle(event: GatewayEvent(
            type: "message.start", sessionID: sid, payload: [:]),
            sourceGatewayID: "remote")
        model.handle(event: GatewayEvent(
            type: "message.complete", sessionID: sid,
            payload: ["status": "error", "error": .string(huge),
                      "recoverable": true]),
            sourceGatewayID: "remote")
        let liveFailureID = try XCTUnwrap(chat.messages.last?.id)
        let liveMessage = try XCTUnwrap(chat.messages.last?.failure?.message)

        let resumed = LiveSession(try json([
            "session_id": sid, "stored_session_id": "stored",
            "inflight": [
                "user": "run", "assistant": "", "status": "error",
                "error": huge, "recoverable": true, "streaming": false,
            ],
        ]))
        model.replayInflight(resumed, botID: botID)

        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertEqual(chat.messages.last?.id, liveFailureID)
        XCTAssertEqual(chat.messages.last?.failure?.message, liveMessage)
        XCTAssertTrue(liveMessage.hasSuffix("… [turn detail clipped]"))
    }

    @MainActor
    func testHugeDismissedLiveFailureDoesNotResurrectOnResume() throws {
        let model = AppModel()
        model.mode = .live
        let botID = "remote::worker"
        let sid = "huge-dismiss-runtime"
        let route = GatewaySessionRoute(gatewayID: "remote", sessionID: sid)
        LiveRuntime.shared.routedSessionToBot[route] = botID
        defer {
            LiveRuntime.shared.routedSessionToBot[route] = nil
            ChatRuntime.shared.turnFloor[botID] = nil
            ChatRuntime.shared.dismissedFailures[ObjectIdentifier(model.chat(for: botID))] = nil
        }
        let chat = model.chat(for: botID)
        chat.sessionID = sid
        chat.storedSessionID = "stored"
        chat.messages = [ChatMessage(author: .user, text: "run", rowID: 1)]
        let huge = String(repeating: "z", count: 40_000)

        model.handle(event: GatewayEvent(
            type: "message.start", sessionID: sid, payload: [:]),
            sourceGatewayID: "remote")
        model.handle(event: GatewayEvent(
            type: "message.complete", sessionID: sid,
            payload: ["status": "error", "error": .string(huge),
                      "recoverable": true]),
            sourceGatewayID: "remote")
        let failed = try XCTUnwrap(chat.messages.last)
        model.dismissFailedTurn(failed, in: botID)
        XCTAssertEqual(chat.messages.count, 1)

        let resumed = LiveSession(try json([
            "session_id": sid, "stored_session_id": "stored",
            "inflight": [
                "user": "run", "assistant": "", "status": "error",
                "error": huge, "recoverable": true, "streaming": false,
            ],
        ]))
        model.replayInflight(resumed, botID: botID)

        XCTAssertEqual(chat.messages.count, 1)
        XCTAssertNil(chat.messages.last?.failure)
    }

    func testFailureEvidenceOnlyBecomesMoreSpecificAndNonretryable() {
        let existing = TurnFailure(
            message: "failed", recoverable: false,
            errorSurface: TurnErrorSurface(
                layer: .provider, code: "unknown", retryable: true))
        let specific = TurnFailure(
            message: "different wording", recoverable: true,
            errorSurface: TurnErrorSurface(
                layer: .provider, code: "rate_limit", retryable: false,
                provider: "openrouter", model: "model"))

        let merged = TurnFailureLifecycle.merge(existing, specific)
        XCTAssertEqual(merged?.message, "failed")
        XCTAssertEqual(merged?.recoverable, true)
        XCTAssertEqual(merged?.errorSurface?.code, "rate_limit")
        XCTAssertEqual(merged?.errorSurface?.retryable, false)
        XCTAssertEqual(merged?.errorSurface?.provider, "openrouter")

        let conflicting = TurnFailure(
            message: "conflict", recoverable: true,
            errorSurface: TurnErrorSurface(
                layer: .auth, code: "auth", retryable: false))
        XCTAssertEqual(TurnFailureLifecycle.merge(merged, conflicting)?.errorSurface,
                       merged?.errorSurface)
    }

    @MainActor
    func testEmptyResumeAndFailedRESTPreserveSendBehindSharedAttach() async throws {
        let model = AppModel()
        model.mode = .live
        model.isOffline = true
        let botID = "race-gateway::worker"
        let chat = model.chat(for: botID)
        let barrier = TranscriptFallbackBarrier()

        let attach = Task<String, Error> { @MainActor in
            try await AppModel.hydrateTranscript(
                chat: chat,
                resumeMessages: [],
                clearWhenEmpty: true,
                fallback: { await barrier.load() },
                accepts: { true })
            return "runtime-session"
        }
        LiveRuntime.shared.attachTasks[botID] = attach
        defer {
            attach.cancel()
            if LiveRuntime.shared.attachTasks[botID] == attach {
                LiveRuntime.shared.attachTasks[botID] = nil
            }
            ChatRuntime.shared.submitWatchdogs[botID]?.cancel()
            ChatRuntime.shared.submitWatchdogs[botID] = nil
        }

        await barrier.waitUntilEntered()
        model.sendOrSteer(text: "keep this optimistic send", to: botID)

        XCTAssertEqual(chat.messages.map(\.text), ["keep this optimistic send"])
        XCTAssertTrue(LiveRuntime.shared.attachTasks[botID] == attach)

        // nil models the REST fallback failing after an empty resume ack.
        await barrier.release(nil)
        _ = try await attach.value
        await Task.yield()

        XCTAssertTrue(chat.messages.contains(where: {
            $0.author == .user && $0.text == "keep this optimistic send"
        }))
    }

    @MainActor
    func testTypingOnlyTurnSteersInsteadOfSubmittingNewPrompt() async {
        let model = AppModel()
        model.mode = .live
        model.isOffline = true
        let botID = "typing-gateway::worker"
        let chat = model.chat(for: botID)
        chat.sessionID = "deadbeef"
        chat.isRunning = false
        chat.isTyping = true

        model.sendOrSteer(text: "adjust the running answer", to: botID)

        XCTAssertFalse(chat.isRunning, "submit path must not run while isTyping promises steer")
        XCTAssertTrue(chat.isTyping)
        XCTAssertEqual(chat.messages.last?.author, .user)
        XCTAssertEqual(chat.messages.last?.text, "adjust the running answer")
        await Task.yield()
    }

    @MainActor
    func testPrimaryOfflineTypingTurnUsesNormalEchoAndComposeQueue() {
        let model = AppModel()
        model.mode = .live
        model.isOffline = true
        let botID = "worker"
        let chat = model.chat(for: botID)
        chat.sessionID = "deadbeef"
        chat.isTyping = true

        model.sendOrSteer(text: "send after reconnect", to: botID)

        XCTAssertEqual(chat.messages.map(\.text), ["send after reconnect"])
        XCTAssertEqual(model.composeQueue.count, 1)
        XCTAssertEqual(model.composeQueue.first?.botID, botID)
        XCTAssertEqual(model.composeQueue.first?.text, "send after reconnect")
        XCTAssertFalse(chat.isRunning)
    }

    @MainActor
    func testDelayedHydrationMergesLiveAssistantDeltaOverStaleREST() async throws {
        let chat = ChatState(messages: [
            ChatMessage(author: .bot, text: "Hel", isStreaming: true),
        ])
        let barrier = TranscriptFallbackBarrier()
        let hydration = Task<Void, Error> { @MainActor in
            try await AppModel.hydrateTranscript(
                chat: chat,
                resumeMessages: [],
                clearWhenEmpty: false,
                fallback: { await barrier.load() },
                accepts: { true })
        }

        await barrier.waitUntilEntered()
        chat.messages[0].text += "lo"
        let stale: JSONValue = ["messages": [
            ["role": "user", "text": "Earlier question", "row_id": 10],
            ["role": "assistant", "text": "Hel", "row_id": 11],
        ]]
        await barrier.release(stale)
        try await hydration.value

        XCTAssertEqual(chat.messages.map(\.text), ["Earlier question", "Hello"])
        XCTAssertTrue(chat.messages[1].isStreaming)
        XCTAssertEqual(chat.messages[1].rowID, 11)
    }

    @MainActor
    func testHydrateTranscriptEmptyResumeAndEmptyRESTKeepLocalRows() async throws {
        let chat = ChatState(messages: [
            ChatMessage(author: .user, text: "keep"),
            ChatMessage(author: .bot, text: "me"),
        ])

        try await AppModel.hydrateTranscript(
            chat: chat,
            resumeMessages: [],
            clearWhenEmpty: true,
            fallback: { ["messages": []] },
            accepts: { true })

        XCTAssertEqual(chat.messages.map(\.text), ["keep", "me"])
    }

    func testEmptyGatewayPageDoesNotClobberPopulatedLocalTranscript() {
        let current = [
            ChatMessage(author: .user, text: "still on the phone"),
            ChatMessage(author: .bot, text: "gateway still has this"),
        ]

        let cleared = TranscriptHydrationMerge.merge(
            history: [], baseline: current, current: current, clearWhenEmpty: true)
        let raced = TranscriptHydrationMerge.merge(
            history: [], baseline: current, current: current, clearWhenEmpty: false)

        XCTAssertEqual(cleared.map(\.text), current.map(\.text))
        XCTAssertEqual(raced.map(\.text), current.map(\.text))
    }

    func testEmptyGatewayPageMayClearSystemOnlyChatWhenRebinding() {
        let systemOnly = [ChatMessage(author: .system, text: "signed out")]

        let merged = TranscriptHydrationMerge.merge(
            history: [], baseline: systemOnly, current: systemOnly, clearWhenEmpty: true)

        XCTAssertTrue(merged.isEmpty)
    }

    func testHydrationNeverCollapsesAssistantAcrossANewerUserTurn() {
        let history = [ChatMessage(author: .bot, text: "Hel", rowID: 4)]
        let current = [
            ChatMessage(author: .user, text: "A different turn"),
            ChatMessage(author: .bot, text: "Hello from the new turn", isStreaming: true),
        ]

        let merged = TranscriptHydrationMerge.merge(
            history: history, baseline: [], current: current, clearWhenEmpty: false)

        XCTAssertEqual(merged.map(\.text),
                       ["Hel", "A different turn", "Hello from the new turn"])
    }

    func testPostBaselineRepeatedUserTextDoesNotCollapseIntoStaleHistory() {
        let stale = ChatMessage(author: .user, text: "retry", rowID: 5)
        let optimistic = ChatMessage(author: .user, text: "retry")

        let merged = TranscriptHydrationMerge.merge(
            history: [stale], baseline: [], current: [optimistic],
            clearWhenEmpty: true)

        XCTAssertEqual(merged.map(\.text), ["retry", "retry"])
        XCTAssertEqual(merged.map(\.id), [stale.id, optimistic.id])
    }

    func testStaleSameSessionPagePreservesLatestCompletedTurn() {
        let oldUser = ChatMessage(author: .user, text: "old question", rowID: 1)
        let oldBot = ChatMessage(author: .bot, text: "old answer", rowID: 2)
        let latestUser = ChatMessage(author: .user, text: "latest question", rowID: 3)
        let latestBot = ChatMessage(author: .bot, text: "latest answer", rowID: 4)
        let current = [oldUser, oldBot, latestUser, latestBot]

        let merged = TranscriptHydrationMerge.merge(
            history: [oldUser, oldBot], baseline: current, current: current,
            clearWhenEmpty: false)

        XCTAssertEqual(merged.map(\.text), current.map(\.text))
    }

    @MainActor
    func testSupersededSelectionGenerationRejectsDelayedHydrationWrite() async throws {
        let botID = "selection-\(UUID().uuidString)"
        let runtime = SessionsRuntime.shared
        let first = runtime.beginOpen(botID: botID)
        let chat = ChatState()
        let barrier = TranscriptFallbackBarrier()
        let hydration = Task<Void, Error> { @MainActor in
            try await AppModel.hydrateTranscript(
                chat: chat,
                resumeMessages: [],
                clearWhenEmpty: true,
                fallback: { await barrier.load() },
                accepts: { runtime.acceptsOpen(botID: botID, generation: first) })
        }

        await barrier.waitUntilEntered()
        _ = runtime.beginOpen(botID: botID)
        chat.messages = [ChatMessage(author: .bot, text: "new selection wins")]
        await barrier.release(["messages": [
            ["role": "assistant", "text": "stale selection"],
        ]])

        do {
            try await hydration.value
            XCTFail("superseded hydration unexpectedly committed")
        } catch is CancellationError {
            // Expected: the new selection owns the transcript.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(chat.messages.map(\.text), ["new selection wins"])
    }

    @MainActor
    func testCancelledAttachQueuesIntentWhenOptimisticRowStillOwnsBinding() async {
        let model = AppModel()
        model.mode = .live
        let botID = "cancelled-worker"
        let chat = model.chat(for: botID)
        chat.storedSessionID = "stored"
        let barrier = TranscriptFallbackBarrier()
        let attach = Task<String, Error> { @MainActor in
            _ = await barrier.load()
            try Task.checkCancellation()
            return "runtime"
        }
        LiveRuntime.shared.attachTasks[botID] = attach
        defer {
            attach.cancel()
            if LiveRuntime.shared.attachTasks[botID] == attach {
                LiveRuntime.shared.attachTasks[botID] = nil
            }
        }

        await barrier.waitUntilEntered()
        model.sendOrSteer(text: "survive reconnect", to: botID)
        attach.cancel()
        await barrier.release(nil)
        _ = try? await attach.value
        for _ in 0..<20 {
            if model.composeQueue.contains(where: {
                $0.botID == botID && $0.text == "survive reconnect"
            }) { break }
            await Task.yield()
        }

        XCTAssertTrue(chat.messages.contains(where: {
            $0.author == .user && $0.text == "survive reconnect"
        }))
        XCTAssertTrue(model.composeQueue.contains(where: {
            $0.botID == botID && $0.text == "survive reconnect"
        }))
    }

    @MainActor
    func testCancelledTypingAttachQueuesCorrectionInsteadOfSubmittingOrDropping() async {
        let model = AppModel()
        model.mode = .live
        let botID = "cancelled-typing-worker"
        let chat = model.chat(for: botID)
        chat.storedSessionID = "stored"
        chat.isTyping = true
        let barrier = TranscriptFallbackBarrier()
        let attach = Task<String, Error> { @MainActor in
            _ = await barrier.load()
            try Task.checkCancellation()
            return "runtime"
        }
        LiveRuntime.shared.attachTasks[botID] = attach
        defer {
            attach.cancel()
            if LiveRuntime.shared.attachTasks[botID] == attach {
                LiveRuntime.shared.attachTasks[botID] = nil
            }
        }

        await barrier.waitUntilEntered()
        model.sendOrSteer(text: "preserve this correction", to: botID)
        attach.cancel()
        await barrier.release(nil)
        _ = try? await attach.value
        for _ in 0..<20 {
            if model.composeQueue.contains(where: {
                $0.botID == botID && $0.text == "preserve this correction"
            }) { break }
            await Task.yield()
        }

        XCTAssertFalse(chat.isRunning)
        XCTAssertTrue(chat.messages.contains(where: {
            $0.author == .user && $0.text == "preserve this correction"
        }))
        XCTAssertTrue(model.composeQueue.contains(where: {
            $0.botID == botID && $0.text == "preserve this correction"
        }))
    }

    @MainActor
    func testCancelledAttachDoesNotQueueAfterExplicitTranscriptSupersession() async {
        let model = AppModel()
        model.mode = .live
        let botID = "superseded-worker"
        let chat = model.chat(for: botID)
        chat.storedSessionID = "stored-a"
        let barrier = TranscriptFallbackBarrier()
        let attach = Task<String, Error> { @MainActor in
            _ = await barrier.load()
            try Task.checkCancellation()
            return "runtime"
        }
        LiveRuntime.shared.attachTasks[botID] = attach
        defer {
            attach.cancel()
            if LiveRuntime.shared.attachTasks[botID] == attach {
                LiveRuntime.shared.attachTasks[botID] = nil
            }
        }

        await barrier.waitUntilEntered()
        model.sendOrSteer(text: "belongs to a", to: botID)
        chat.messages = []
        chat.storedSessionID = "stored-b"
        attach.cancel()
        await barrier.release(nil)
        _ = try? await attach.value
        for _ in 0..<5 { await Task.yield() }

        XCTAssertFalse(model.composeQueue.contains(where: {
            $0.botID == botID && $0.text == "belongs to a"
        }))
    }

    @MainActor
    func testHiddenSessionFailuresStaySilentButUnexpectedErrorsReachDiagnostics() {
        let supervisor = ConnectionSupervisor.shared
        let unsupported = "hidden-unsupported-\(UUID().uuidString)"
        let vanished = "hidden-vanished-\(UUID().uuidString)"
        let http404 = "hidden-http404-\(UUID().uuidString)"
        let failed = "hidden-failed-\(UUID().uuidString)"
        let nonGateway404 = "hidden-nongateway-\(UUID().uuidString)"
        defer {
            for id in [unsupported, vanished, http404, failed, nonGateway404] {
                supervisor.diagnostics[id] = nil
            }
        }

        OwnedSessionHidingFailure.record(
            GatewayError(code: -32_601, message: "method not found"),
            gatewayID: unsupported)
        OwnedSessionHidingFailure.record(
            GatewayError(code: GatewayError.storedSessionGone, message: "row vanished"),
            gatewayID: vanished)
        XCTAssertNil(supervisor.diagnostics[unsupported])
        XCTAssertNil(supervisor.diagnostics[vanished])

        OwnedSessionHidingFailure.record(
            GatewayError(code: 404, message: "ordinary HTTP failure"),
            gatewayID: http404)
        XCTAssertNotNil(supervisor.diagnostics[http404]?.lastError)

        OwnedSessionHidingFailure.record(
            GatewayError(code: -3, message: "transport unavailable"),
            gatewayID: failed)
        XCTAssertNotNil(supervisor.diagnostics[failed]?.lastError)

        // Only a GatewayError carrying the two contract codes is benign.
        OwnedSessionHidingFailure.record(
            NSError(domain: "test", code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "ordinary failure"]),
            gatewayID: nonGateway404)
        XCTAssertNotNil(supervisor.diagnostics[nonGateway404]?.lastError)
    }

    private func json(_ object: Any) throws -> JSONValue {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

private actor TranscriptFallbackBarrier {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<JSONValue?, Never>?

    func load() async -> JSONValue? {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        return await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release(_ value: JSONValue?) {
        releaseContinuation?.resume(returning: value)
        releaseContinuation = nil
    }
}
#endif
