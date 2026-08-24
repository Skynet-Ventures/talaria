#if canImport(XCTest)
import XCTest
@testable import TalariaKit

final class TurnElapsedTimingTests: XCTestCase {
    func testGatewayEpochAdmissionIsFinitePositiveAndClockBounded() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertEqual(TurnElapsedTimingPolicy.admittedStartDate(
            epochSeconds: 1_999_900, now: now),
            Date(timeIntervalSince1970: 1_999_900))
        XCTAssertNotNil(TurnElapsedTimingPolicy.admittedStartDate(
            epochSeconds: 2_000_299, now: now))
        XCTAssertNil(TurnElapsedTimingPolicy.admittedStartDate(
            epochSeconds: 2_000_301, now: now))
        XCTAssertNil(TurnElapsedTimingPolicy.admittedStartDate(
            epochSeconds: Double.nan, now: now))
        XCTAssertNil(TurnElapsedTimingPolicy.admittedStartDate(
            epochSeconds: 0, now: now))
        XCTAssertNil(TurnElapsedTimingPolicy.admittedStartDate(
            epochSeconds: now.timeIntervalSince1970
                - Double(TurnElapsedTimingPolicy.maximumDurationSeconds) - 1,
            now: now))
    }

    func testLiveAndSettledDurationsFollowDesktopBucketing() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(TurnElapsedTimingPolicy.liveSeconds(
            startedAt: start, now: Date(timeIntervalSince1970: 1_059.9)), 59)
        XCTAssertEqual(TurnElapsedTimingPolicy.settledSeconds(
            startedAt: start, completedAt: Date(timeIntervalSince1970: 1_000.1)), 1)
        XCTAssertEqual(TurnElapsedTimingPolicy.settledSeconds(
            startedAt: start, completedAt: Date(timeIntervalSince1970: 1_061.6)), 62)
        XCTAssertEqual(TurnElapsedTimingPolicy.formatted(seconds: 59), "59s")
        XCTAssertEqual(TurnElapsedTimingPolicy.formatted(seconds: 60), "1:00")
        XCTAssertEqual(TurnElapsedTimingPolicy.formatted(seconds: 3_661), "61:01")
    }

    func testSessionInfoAndResumeRetainOnlyAdmittedWireEpoch() {
        let info = SessionInfo(.object([
            "running": .bool(true),
            "turn_started_at": .number(1_700_000_123.5),
        ]))
        XCTAssertEqual(info.turnStartedAtEpochSeconds, 1_700_000_123.5)

        let live = LiveSession(.object([
            "session_id": .string("runtime"),
            "stored_session_id": .string("stored"),
            "running": .bool(true),
            "turn_started_at": .number(1_700_000_123.5),
        ]))
        XCTAssertEqual(live.turnStartedAtEpochSeconds, 1_700_000_123.5)

        let malformed = LiveSession(.object([
            "session_id": .string("runtime"),
            "running": .bool(true),
            "turn_started_at": .string("yesterday"),
        ]))
        XCTAssertNil(malformed.turnStartedAtEpochSeconds)
    }

    func testOlderChatMessageJSONDoesNotInventDuration() throws {
        let original = ChatMessage(author: .bot, text: "historical")
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "turnDurationSeconds")
        let old = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ChatMessage.self, from: old)
        XCTAssertNil(decoded.turnDurationSeconds)
    }
}
#endif
