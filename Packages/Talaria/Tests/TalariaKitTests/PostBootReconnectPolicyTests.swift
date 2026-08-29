import XCTest
@testable import TalariaKit

final class PostBootReconnectPolicyTests: XCTestCase {
    func testExactExponentialCeilingsAndIndefiniteAttempts() {
        let expected: [TimeInterval] = [0.3, 0.6, 1.2, 2.4, 4.8, 9.6, 15, 15]
        for (attempt, ceiling) in expected.enumerated() {
            let decision = PostBootReconnectPolicy.delay(attempt: attempt, randomUnit: 0.5)
            XCTAssertEqual(decision.attempt, attempt)
            XCTAssertEqual(decision.ceiling, ceiling, accuracy: 0.000_001)
            XCTAssertEqual(decision.delay, ceiling / 2, accuracy: 0.000_001)
        }

        let huge = PostBootReconnectPolicy.delay(attempt: Int.max, randomUnit: 0.5)
        XCTAssertEqual(huge.attempt, Int.max)
        XCTAssertEqual(huge.ceiling, 15)
        XCTAssertEqual(huge.delay, 7.5)

        let negative = PostBootReconnectPolicy.delay(attempt: Int.min, randomUnit: 0.5)
        XCTAssertEqual(negative.attempt, 0)
        XCTAssertEqual(negative.ceiling, 0.3)
        XCTAssertEqual(negative.delay, 0.15)
    }

    func testFullJitterBoundsAndInvalidUnitsNeverProduceNaN() {
        for attempt in [0, 1, 5, 6, 100, Int.max] {
            let zero = PostBootReconnectPolicy.delay(attempt: attempt, randomUnit: 0)
            XCTAssertEqual(zero.delay, 0)

            let half = PostBootReconnectPolicy.delay(attempt: attempt, randomUnit: 0.5)
            XCTAssertEqual(half.delay, half.ceiling / 2)

            let nearOne = PostBootReconnectPolicy.delay(
                attempt: attempt, randomUnit: 1.nextDown)
            XCTAssertGreaterThanOrEqual(nearOne.delay, 0)
            XCTAssertLessThan(nearOne.delay, nearOne.ceiling)

            for invalid in [-Double.infinity, -1, Double.nan] {
                let decision = PostBootReconnectPolicy.delay(
                    attempt: attempt, randomUnit: invalid)
                XCTAssertEqual(decision.delay, 0)
                XCTAssertTrue(decision.delay.isFinite)
            }
            for oversized in [1, 2, Double.infinity] {
                let decision = PostBootReconnectPolicy.delay(
                    attempt: attempt, randomUnit: oversized)
                XCTAssertGreaterThanOrEqual(decision.delay, 0)
                XCTAssertLessThan(decision.delay, decision.ceiling)
                XCTAssertTrue(decision.delay.isFinite)
            }
        }
    }

    func testRecoveryEscalationUsesExactElapsedTimeBoundary() {
        for elapsed in [-Double.infinity, -1, -0.0, 0, 44.999_999, Double.nan] {
            XCTAssertFalse(PostBootReconnectPolicy.shouldEscalateRecovery(elapsed: elapsed))
        }
        for elapsed in [45, 45.000_001, 10_000, Double.infinity] {
            XCTAssertTrue(PostBootReconnectPolicy.shouldEscalateRecovery(elapsed: elapsed))
        }
    }

    func testCleanOpenAndManualWakeResetTheWholeEpisode() {
        let reset = PostBootReconnectEpisode(attempt: 0, elapsed: 0)
        XCTAssertEqual(PostBootReconnectPolicy.resetEpisode(for: .cleanOpen), reset)
        XCTAssertEqual(PostBootReconnectPolicy.resetEpisode(for: .manualWake), reset)
    }

    func testRedialReadyTimeoutIsShorterThanTheConnectBound() {
        XCTAssertEqual(PostBootReconnectPolicy.redialReadyTimeout, 5)
        XCTAssertLessThan(PostBootReconnectPolicy.redialReadyTimeout, 15)
    }

    func testGatewayClientStoresRepairedHermesOrigin() async {
        let client = GatewayClient(
            baseURL: URL(string: "http://100.87.108.5")!,
            credential: .sessionToken("x"))
        let origin = await client.baseURL
        XCTAssertEqual(origin.absoluteString, "http://100.87.108.5:9119")
    }
}
