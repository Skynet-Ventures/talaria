#if canImport(XCTest)
import XCTest
@testable import TalariaKit

final class GatewayForegroundLivenessTests: XCTestCase {
    private func client() -> GatewayClient {
        GatewayClient(
            baseURL: URL(string: "https://foreground-liveness.example")!,
            credential: .sessionToken("foreground-liveness-test"))
    }

    func testHealthyPingRequiresExactBoundedReply() async {
        let client = client()
        await client.setForegroundReadinessForTesting(true)
        await client.setRPCExecutorForTesting { method, params, timeout in
            XCTAssertEqual(method, "gateway.ping")
            XCTAssertEqual(params, .object([:]))
            XCTAssertEqual(timeout, ForegroundSocketPolicy.pingTimeout)
            return .object(["ok": .bool(true)])
        }

        let outcome = await client.validateForegroundLiveness()
        XCTAssertEqual(outcome, .healthy)
    }

    func testHalfOpenFailureAndMalformedReplyRequireReconnect() async {
        let client = client()
        await client.setForegroundReadinessForTesting(true)
        await client.setRPCExecutorForTesting { _, _, _ in
            throw GatewayError(code: -5, message: "request timed out: gateway.ping")
        }
        var outcome = await client.validateForegroundLiveness()
        XCTAssertEqual(outcome, .reconnectRequired)

        await client.setRPCExecutorForTesting { _, _, _ in
            .object(["ok": .string("true")])
        }
        outcome = await client.validateForegroundLiveness()
        XCTAssertEqual(outcome, .reconnectRequired)
    }

    func testAlreadyDisconnectedNeverAttemptsPing() async {
        let client = client()
        await client.setForegroundReadinessForTesting(false)
        await client.setRPCExecutorForTesting { _, _, _ in
            XCTFail("a disconnected link must fail before RPC")
            return .object(["ok": .bool(true)])
        }

        let outcome = await client.validateForegroundLiveness()
        XCTAssertEqual(outcome, .reconnectRequired)
    }

    func testOlderGatewayMethodNotFoundIsHealthy() async {
        let client = client()
        await client.setForegroundReadinessForTesting(true)
        await client.setRPCExecutorForTesting { _, _, _ in
            throw GatewayError(code: ForegroundSocketPolicy.methodNotFound,
                               message: "Method not found")
        }

        let outcome = await client.validateForegroundLiveness()
        XCTAssertEqual(outcome, .healthy)
    }

    func testTrafficFenceDoesNotBecomeReconnectFailure() async {
        let client = client()
        await client.setForegroundReadinessForTesting(true)
        await client.setTrafficAdmission { nil }
        await client.setRPCExecutorForTesting { _, _, _ in
            XCTFail("traffic-fenced wake must not reach the transport")
            return .object(["ok": .bool(true)])
        }

        let outcome = await client.validateForegroundLiveness()
        XCTAssertEqual(outcome, .trafficFenced)
    }
}
#endif
