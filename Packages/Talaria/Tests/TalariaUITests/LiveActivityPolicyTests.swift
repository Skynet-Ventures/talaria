import XCTest
@testable import TalariaUI

final class LiveActivityPolicyTests: XCTestCase {
    func testOrdinaryChatHasNoAdmissionWithoutOperation() {
        let state = LiveActivityWorkAdmission()
        XCTAssertTrue(state.trackedBotIDs.isEmpty)
        XCTAssertTrue(state.admittedBotIDs.isEmpty)
    }

    func testOperationMustSurviveExplicitAdmissionBoundary() {
        var state = LiveActivityWorkAdmission()
        XCTAssertTrue(state.begin(botID: "default", operationID: "tool-1"))
        XCTAssertFalse(state.begin(botID: "default", operationID: "tool-1"))
        XCTAssertTrue(state.admittedBotIDs.isEmpty)

        XCTAssertTrue(state.admit(botID: "default", operationID: "tool-1"))
        XCTAssertEqual(state.admittedBotIDs, ["default"])
    }

    func testShortOrFinishedOperationCannotBeAdmitted() {
        var state = LiveActivityWorkAdmission()
        XCTAssertTrue(state.begin(botID: "default", operationID: "tool-1"))
        state.end(botID: "default", operationID: "tool-1")

        XCTAssertFalse(state.admit(botID: "default", operationID: "tool-1"))
        XCTAssertTrue(state.trackedBotIDs.isEmpty)
        XCTAssertTrue(state.admittedBotIDs.isEmpty)
    }

    func testEndAllClearsParallelOperations() {
        var state = LiveActivityWorkAdmission()
        XCTAssertTrue(state.begin(botID: "default", operationID: "tool-1"))
        XCTAssertTrue(state.begin(botID: "default", operationID: "tool-2"))
        XCTAssertTrue(state.admit(botID: "default", operationID: "tool-1"))

        state.endAll(botID: "default")
        XCTAssertTrue(state.trackedBotIDs.isEmpty)
        XCTAssertTrue(state.admittedBotIDs.isEmpty)
    }
}
