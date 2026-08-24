#if canImport(XCTest)
import XCTest
@testable import TalariaKit

final class GatewayHeartbeatTests: XCTestCase {
    private func client() -> GatewayClient {
        GatewayClient(
            baseURL: URL(string: "https://foreground-heartbeat.example")!,
            credential: .sessionToken("foreground-heartbeat-test"))
    }

    func testInvalidPolicyValuesDisableHeartbeat() {
        XCTAssertFalse(GatewayHeartbeatPolicy(interval: .nan, deadline: 45).isEnabled)
        XCTAssertFalse(GatewayHeartbeatPolicy(interval: 15, deadline: .infinity).isEnabled)
        XCTAssertFalse(GatewayHeartbeatPolicy(interval: -1, deadline: 45).isEnabled)
    }

    func testOldGatewayNeverStartsApplicationHeartbeat() {
        var state = GatewayHeartbeatState(policy: .current)
        state.activate(advertised: false, now: 100)
        XCTAssertEqual(state.tick(now: 1_000), .none)
    }

    func testAdvertisedHeartbeatSendsOnePingAndWaitsForExactAck() {
        var state = GatewayHeartbeatState(policy: .current)
        state.activate(advertised: true, now: 100)
        XCTAssertEqual(state.tick(now: 115), .send(id: "talaria-heartbeat-1"))
        XCTAssertEqual(state.tick(now: 130), .none)
        state.recordInbound(responseID: "ordinary-rpc", now: 131)
        XCTAssertEqual(state.tick(now: 132), .none,
                       "ordinary traffic proves liveness but cannot acknowledge the ping")
        state.recordInbound(responseID: "talaria-heartbeat-1", now: 133)
        XCTAssertEqual(state.tick(now: 148), .send(id: "talaria-heartbeat-2"))
    }

    func testSilentSocketInvalidatesAtDeadline() {
        var state = GatewayHeartbeatState(policy: .current)
        state.activate(advertised: true, now: 10)
        XCTAssertEqual(state.tick(now: 25), .send(id: "talaria-heartbeat-1"))
        XCTAssertEqual(state.tick(now: 54.999), .none)
        XCTAssertEqual(state.tick(now: 55), .invalidate)
    }

    func testAnyInboundTrafficMovesDeadlineWithoutInventingAcknowledgement() {
        var state = GatewayHeartbeatState(policy: .current)
        state.activate(advertised: true, now: 10)
        _ = state.tick(now: 25)
        state.recordInbound(responseID: nil, now: 50)
        XCTAssertEqual(state.tick(now: 70), .none)
        XCTAssertEqual(state.tick(now: 95), .invalidate)
    }

    func testGatewayReadyDecodesHeartbeatCapability() {
        let event = GatewayEvent(type: "gateway.ready", sessionID: "", payload: .object([
            "change_events": .bool(true),
            "heartbeat": .bool(true),
        ]))
        guard case .gatewayReady(_, let changeEvents, let heartbeat) = TypedGatewayEvent(event) else {
            return XCTFail("expected typed ready event")
        }
        XCTAssertTrue(changeEvents)
        XCTAssertTrue(heartbeat)
    }

    func testForegroundHealthyPingRequiresExactBoundedReply() async {
        let client = client()
        await client.setForegroundReadinessForTesting(true)
        await client.setRPCExecutorForTesting { method, params, timeout in
            XCTAssertEqual(method, "gateway.ping")
            XCTAssertEqual(params, .object([:]))
            XCTAssertEqual(timeout, 3)
            return .object(["ok": .bool(true)])
        }

        let outcome = await client.validateForegroundLiveness()
        XCTAssertEqual(outcome, .healthy)
    }

    func testForegroundHalfOpenFailureAndMalformedReplyRequireReconnect() async {
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

        await client.setRPCExecutorForTesting { _, _, _ in
            .object(["ok": .bool(true), "unexpected": .bool(true)])
        }
        outcome = await client.validateForegroundLiveness()
        XCTAssertEqual(outcome, .reconnectRequired)
    }

    func testForegroundAlreadyDisconnectedNeverAttemptsPing() async {
        let client = client()
        await client.setForegroundReadinessForTesting(false)
        await client.setRPCExecutorForTesting { _, _, _ in
            XCTFail("a disconnected link must fail before RPC")
            return .object(["ok": .bool(true)])
        }

        let outcome = await client.validateForegroundLiveness()
        XCTAssertEqual(outcome, .reconnectRequired)
    }

    func testForegroundTrafficFenceDoesNotBecomeReconnectFailure() async {
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
