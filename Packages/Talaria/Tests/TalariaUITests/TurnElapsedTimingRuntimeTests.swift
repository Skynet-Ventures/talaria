#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI

@MainActor
final class TurnElapsedTimingRuntimeTests: XCTestCase {
    func testTranscriptActivityUsesFastCadenceOnlyForDraftingReveal() {
        let start = Date(timeIntervalSince1970: 1_000)
        var activity = TurnTranscriptActivity()
        activity.begin(at: start, replacingExisting: true)
        XCTAssertEqual(TurnTranscriptActivityRefreshPolicy.interval(for: activity), 1)

        activity.namePhase(.providerWait, label: "Waiting on provider", startedAt: start)
        XCTAssertEqual(TurnTranscriptActivityRefreshPolicy.interval(for: activity), 1)

        activity.namePhase(.compacting, label: "Summarizing thread", startedAt: start)
        XCTAssertEqual(TurnTranscriptActivityRefreshPolicy.interval(for: activity), 1)

        activity.namePhase(.draftingTool, label: "Preparing browser", startedAt: start)
        XCTAssertEqual(TurnTranscriptActivityRefreshPolicy.interval(for: activity),
                       TurnTranscriptActivityPolicy.draftingRevealDelay)

        activity.recordVisibleProgress(at: start.addingTimeInterval(1))
        XCTAssertEqual(TurnTranscriptActivityRefreshPolicy.interval(for: activity), 1)
    }

    func testSettlementAnnotatesOnlyNewestAssistantOwnedByCurrentTurn() {
        let model = AppModel()
        let chat = model.chat(for: "worker")
        let historical = ChatMessage(author: .bot, text: "old")
        let user = ChatMessage(author: .user, text: "new prompt")
        let interim = ChatMessage(author: .bot, text: "interim")
        let final = ChatMessage(author: .bot, text: "final")
        chat.messages = [historical, user, interim, final]
        ChatRuntime.shared.turnFloor["worker"] = 1
        chat.beginTurnTiming(
            at: Date(timeIntervalSince1970: 1_000), replacingExisting: true)

        XCTAssertEqual(model.settleTurnTiming(
            in: chat, botID: "worker",
            completedAt: Date(timeIntervalSince1970: 1_061.6)), 62)
        XCTAssertNil(chat.turnStartedAt)
        XCTAssertNil(chat.messages[0].turnDurationSeconds)
        XCTAssertNil(chat.messages[2].turnDurationSeconds)
        XCTAssertEqual(chat.messages[3].turnDurationSeconds, 62)
        ChatRuntime.shared.turnFloor["worker"] = nil
    }

    func testTerminalWithoutObservedStartCannotInventHistoricalDuration() {
        let model = AppModel()
        let chat = model.chat(for: "worker")
        chat.messages = [ChatMessage(author: .bot, text: "loaded history")]
        ChatRuntime.shared.turnFloor["worker"] = 0

        XCTAssertNil(model.settleTurnTiming(
            in: chat, botID: "worker", completedAt: Date()))
        XCTAssertNil(chat.messages[0].turnDurationSeconds)
        ChatRuntime.shared.turnFloor["worker"] = nil
    }

    func testResumeUsesGatewayTimeAndLegacyReconnectDoesNotReuseLocalClock() {
        let model = AppModel()
        let chat = model.chat(for: "worker")
        let now = Date(timeIntervalSince1970: 2_000_000)
        let live = LiveSession(.object([
            "session_id": .string("runtime-new"),
            "stored_session_id": .string("stored"),
            "running": .bool(true),
            "turn_started_at": .number(1_999_900),
        ]))

        model.adoptTurnTiming(
            from: live, in: chat, priorRuntimeSessionID: "runtime-old",
            priorLocalStart: Date(timeIntervalSince1970: 1_999_950), now: now)
        XCTAssertEqual(chat.turnStartedAt, Date(timeIntervalSince1970: 1_999_900))

        let legacy = LiveSession(.object([
            "session_id": .string("runtime-next"),
            "stored_session_id": .string("stored"),
            "running": .bool(true),
        ]))
        model.adoptTurnTiming(
            from: legacy, in: chat, priorRuntimeSessionID: "runtime-new",
            priorLocalStart: Date(timeIntervalSince1970: 1_999_950), now: now)
        XCTAssertNil(chat.turnStartedAt,
                     "legacy reconnect has no authority to reconstruct elapsed history")

        let local = Date(timeIntervalSince1970: 1_999_990)
        model.adoptTurnTiming(
            from: legacy, in: chat, priorRuntimeSessionID: nil,
            priorLocalStart: local, now: now)
        XCTAssertEqual(chat.turnStartedAt, local,
                       "first-submit bind preserves the locally observed origin")
        XCTAssertTrue(chat.turnTranscriptActivity.isActive)
    }

    func testRetainedOutputSeedsFreshQuietBoundaryWithoutHistoricalGuess() {
        let model = AppModel()
        let chat = model.chat(for: "worker")
        let now = Date(timeIntervalSince1970: 2_000)
        let live = LiveSession(.object([
            "session_id": .string("runtime"),
            "running": .bool(true),
            "inflight": .object([
                "assistant": .string("already streamed"),
                "streaming": .bool(true),
            ]),
        ]))

        model.adoptTurnTiming(from: live, in: chat,
                              priorRuntimeSessionID: "old",
                              priorLocalStart: nil, now: now)

        XCTAssertNil(chat.turnStartedAt)
        XCTAssertTrue(chat.turnTranscriptActivity.hasVisibleProgress)
        XCTAssertEqual(chat.turnTranscriptActivity.lastVisibleProgressAt, now)
        XCTAssertNil(TurnTranscriptActivityPolicy.presentation(
            activity: chat.turnTranscriptActivity, turnStartedAt: nil,
            now: now, isTurnRunning: true, isAwaitingInput: false,
            toolNarratesWait: false))
    }

    func testExactSourceEventsOwnAndTerminallyClearActivity() {
        let model = AppModel()
        model.mode = .live
        let runtime = LiveRuntime.shared
        let sessionID = "activity-\(UUID().uuidString)"
        let botID = "remote::activity"
        let route = GatewaySessionRoute(gatewayID: "remote", sessionID: sessionID)
        let oldGateway = runtime.gatewayID
        defer {
            runtime.gatewayID = oldGateway
            runtime.routedSessionToBot[route] = nil
            ChatRuntime.shared.turnFloor[botID] = nil
            model.chats[botID] = nil
        }
        runtime.gatewayID = "primary"
        runtime.routedSessionToBot[route] = botID
        let chat = model.chat(for: botID)
        chat.sessionID = sessionID

        model.handle(event: GatewayEvent(type: "message.start", sessionID: sessionID,
                                         payload: nil), sourceGatewayID: "remote")
        XCTAssertTrue(chat.turnTranscriptActivity.isActive)

        model.handle(event: GatewayEvent(type: "message.delta", sessionID: sessionID,
                                         payload: ["text": "hello"]),
                     sourceGatewayID: "primary")
        XCTAssertFalse(chat.turnTranscriptActivity.hasVisibleProgress,
                       "a colliding source cannot mutate the qualified turn")

        model.handle(event: GatewayEvent(type: "message.delta", sessionID: sessionID,
                                         payload: ["text": "hello"]),
                     sourceGatewayID: "remote")
        XCTAssertTrue(chat.turnTranscriptActivity.hasVisibleProgress)

        model.handle(event: GatewayEvent(type: "message.complete", sessionID: sessionID,
                                         payload: ["status": "complete", "text": "hello"]),
                     sourceGatewayID: "remote")
        XCTAssertFalse(chat.turnTranscriptActivity.isActive)
    }

    func testSessionInfoPreservesLocalOriginAndStartsAtLiveObservationWhenMissing() {
        let model = AppModel()
        let chat = model.chat(for: "worker")
        let local = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 2_000)
        chat.turnStartedAt = local
        model.observeTurnTiming(from: SessionInfo(.object([
            "running": .bool(true),
            "turn_started_at": .number(1_500),
        ])), in: chat, now: now)
        XCTAssertEqual(chat.turnStartedAt, local)

        chat.clearTurnTiming()
        model.observeTurnTiming(from: SessionInfo(.object([
            "running": .bool(true),
        ])), in: chat, now: now)
        XCTAssertEqual(chat.turnStartedAt, now)
    }

    func testEstablishedSessionReplacementClearsLiveActivity() {
        let model = AppModel()
        let chat = model.chat(for: "worker")
        chat.sessionID = "old-runtime"
        chat.storedSessionID = "old-stored"
        chat.beginTurnTiming(at: Date(timeIntervalSince1970: 1_000),
                             replacingExisting: true)

        chat.sessionID = "new-runtime"
        XCTAssertNil(chat.turnStartedAt)
        XCTAssertFalse(chat.turnTranscriptActivity.isActive)

        chat.beginTurnTiming(at: Date(timeIntervalSince1970: 2_000),
                             replacingExisting: true)
        chat.storedSessionID = "new-stored"
        XCTAssertNil(chat.turnStartedAt)
        XCTAssertFalse(chat.turnTranscriptActivity.isActive)
    }
}
#endif
