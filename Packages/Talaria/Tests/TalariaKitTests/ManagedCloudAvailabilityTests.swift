import XCTest
@testable import TalariaKit

final class ManagedCloudAvailabilityTests: XCTestCase {
    func testStrictManagedAgentHostClassification() throws {
        let accepted = [
            "https://ares-3009.agents.nousresearch.com",
            "http://test.agents.nousresearch.com/api/health",
            "https://DEEP.Region.Agents.NousResearch.Com:443/path",
        ]
        for source in accepted {
            XCTAssertTrue(ManagedCloudAvailabilityPolicy.isManagedAgentURL(
                try XCTUnwrap(URL(string: source))), source)
        }

        let rejected = [
            "https://agents.nousresearch.com",
            "https://nousresearch.com",
            "https://agents.nousresearch.com.evil.example",
            "https://fooagents.nousresearch.com",
            "https://foo.agents.nousresearch.com.evil.example",
            "https://user@foo.agents.nousresearch.com",
            "https://user:pass@foo.agents.nousresearch.com",
            "https://127.0.0.1",
            "https://[::1]",
            "https://-bad.agents.nousresearch.com",
            "https://bad-.agents.nousresearch.com",
            "https://bad..agents.nousresearch.com",
            "https://bad_name.agents.nousresearch.com",
            "https://foo.agents.nousresearch.com.",
            "https://foo.agents.nousresearch.com%2eevil.example",
            "not-a-url",
        ]
        for source in rejected {
            XCTAssertFalse(ManagedCloudAvailabilityPolicy.isManagedAgentURL(
                try XCTUnwrap(URL(string: source))), source)
        }
    }

    func testPreWebSocketServerDownClassificationIsExact() throws {
        let managed = try XCTUnwrap(URL(string: "https://one.agents.nousresearch.com"))
        for status in [502, 503, 504] {
            XCTAssertEqual(
                ManagedCloudAvailabilityPolicy.preWebSocketServerDown(
                    url: managed, statusCode: status),
                ManagedCloudServerDown(host: "one.agents.nousresearch.com", statusCode: status)
            )
            XCTAssertTrue(ManagedCloudAvailabilityPolicy.isServerDownStatus(status))
        }
        for status in [-1, 0, 200, 401, 403, 404, 429, 500, 501, 505, 599] {
            XCTAssertNil(ManagedCloudAvailabilityPolicy.preWebSocketServerDown(
                url: managed, statusCode: status))
            XCTAssertFalse(ManagedCloudAvailabilityPolicy.isServerDownStatus(status))
        }

        let unmanaged = try XCTUnwrap(URL(string: "https://gateway.example.com"))
        XCTAssertNil(ManagedCloudAvailabilityPolicy.preWebSocketServerDown(
            url: unmanaged, statusCode: 503))
    }

    func testFiveRetryBudgetAndExactExponentialCeilings() {
        XCTAssertEqual(ManagedCloudAvailabilityPolicy.maximumAutomaticRetries, 5)
        let expected: [TimeInterval] = [2, 4, 8, 15, 15]
        for (attempt, ceiling) in expected.enumerated() {
            let retry = ManagedCloudAvailabilityPolicy.bootRetry(
                attempt: attempt, randomUnit: 0.5)
            XCTAssertEqual(retry?.attempt, attempt)
            XCTAssertEqual(retry?.ceiling, ceiling)
            XCTAssertEqual(retry?.delay, ceiling / 2)
        }
        XCTAssertNil(ManagedCloudAvailabilityPolicy.bootRetry(attempt: -1, randomUnit: 0.5))
        XCTAssertNil(ManagedCloudAvailabilityPolicy.bootRetry(attempt: 5, randomUnit: 0.5))
        XCTAssertNil(ManagedCloudAvailabilityPolicy.bootRetry(attempt: Int.max, randomUnit: 0.5))
    }

    func testFullJitterBoundariesAndInvalidRandomInputsStayFinite() throws {
        for attempt in 0..<ManagedCloudAvailabilityPolicy.maximumAutomaticRetries {
            let zero = try XCTUnwrap(ManagedCloudAvailabilityPolicy.bootRetry(
                attempt: attempt, randomUnit: 0))
            XCTAssertEqual(zero.delay, 0)

            let half = try XCTUnwrap(ManagedCloudAvailabilityPolicy.bootRetry(
                attempt: attempt, randomUnit: 0.5))
            XCTAssertEqual(half.delay, half.ceiling * 0.5)

            let nearOne = try XCTUnwrap(ManagedCloudAvailabilityPolicy.bootRetry(
                attempt: attempt, randomUnit: 1.nextDown))
            XCTAssertGreaterThanOrEqual(nearOne.delay, 0)
            XCTAssertLessThan(nearOne.delay, nearOne.ceiling)

            for invalid in [-Double.infinity, -1, Double.nan] {
                let retry = try XCTUnwrap(ManagedCloudAvailabilityPolicy.bootRetry(
                    attempt: attempt, randomUnit: invalid))
                XCTAssertEqual(retry.delay, 0)
                XCTAssertTrue(retry.delay.isFinite)
            }
            for oversized in [1, 2, Double.infinity] {
                let retry = try XCTUnwrap(ManagedCloudAvailabilityPolicy.bootRetry(
                    attempt: attempt, randomUnit: oversized))
                XCTAssertGreaterThanOrEqual(retry.delay, 0)
                XCTAssertLessThan(retry.delay, retry.ceiling)
                XCTAssertTrue(retry.delay.isFinite)
            }
        }
    }
}
