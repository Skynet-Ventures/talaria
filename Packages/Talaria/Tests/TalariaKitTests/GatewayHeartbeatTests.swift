#if canImport(XCTest)
import XCTest
@testable import TalariaKit

final class GatewayHeartbeatTests: XCTestCase {
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
}
#endif
