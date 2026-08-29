import XCTest
@testable import TalariaKit

final class ForegroundSocketPolicyTests: XCTestCase {
    func testDisconnectedTransportNeverLooksHealthy() {
        let outcome = ForegroundSocketPolicy.outcome(
            transportReady: false,
            result: .success(.object(["ok": .bool(true)])))
        XCTAssertEqual(outcome, .reconnectRequired)
    }

    func testExactOkReplyIsHealthyAndExtraFieldsStillCount() {
        XCTAssertEqual(
            ForegroundSocketPolicy.outcome(
                transportReady: true,
                result: .success(.object(["ok": .bool(true)]))),
            .healthy)
        XCTAssertEqual(
            ForegroundSocketPolicy.outcome(
                transportReady: true,
                result: .success(.object(["ok": .bool(true), "ts": .number(1)]))),
            .healthy)
    }

    func testMalformedOrMissingOkRequiresReconnect() {
        let replies: [JSONValue] = [
            .object([:]),
            .object(["ok": .string("true")]),
            .object(["ok": .bool(false)]),
            .bool(true),
        ]
        for reply in replies {
            XCTAssertEqual(
                ForegroundSocketPolicy.outcome(transportReady: true, result: .success(reply)),
                .reconnectRequired,
                "reply: \(reply)")
        }
    }

    func testTimeoutAndTransportErrorsRequireReconnect() {
        XCTAssertEqual(
            ForegroundSocketPolicy.outcome(
                transportReady: true,
                result: .failure(GatewayError(code: -5, message: "request timed out: gateway.ping"))),
            .reconnectRequired)
        XCTAssertEqual(
            ForegroundSocketPolicy.outcome(
                transportReady: true,
                result: .failure(URLError(.networkConnectionLost))),
            .reconnectRequired)
    }

    func testMethodNotFoundStillProvesTheSocketAndFenceIsNotADrop() {
        XCTAssertEqual(
            ForegroundSocketPolicy.outcome(
                transportReady: true,
                result: .failure(GatewayError(
                    code: ForegroundSocketPolicy.methodNotFound,
                    message: "Method not found"))),
            .healthy)
        XCTAssertEqual(
            ForegroundSocketPolicy.outcome(
                transportReady: true,
                result: .failure(GatewayError(
                    code: GatewayClient.trafficFenced,
                    message: "Gateway traffic is paused"))),
            .trafficFenced)
    }
}
