#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI

@MainActor
final class TurnElapsedTimingRuntimeTests: XCTestCase {
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
}
#endif
