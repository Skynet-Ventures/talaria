import XCTest
@testable import TalariaKit

final class RoomComposerDraftTests: XCTestCase {
    func testScalarAndUTF8BoundsAreIndependentAndCanonical() {
        let scalarHeavy = String(repeating: "a", count: RoomComposerDraftPolicy.maximumScalars + 8)
        XCTAssertEqual(RoomComposerDraftPolicy.bounded(scalarHeavy).unicodeScalars.count,
                       RoomComposerDraftPolicy.maximumScalars)

        let byteHeavy = String(repeating: "🛰️", count: RoomComposerDraftPolicy.maximumScalars)
        let bounded = RoomComposerDraftPolicy.bounded(byteHeavy)
        XCTAssertLessThanOrEqual(bounded.unicodeScalars.count,
                                 RoomComposerDraftPolicy.maximumScalars)
        XCTAssertLessThanOrEqual(bounded.utf8.count,
                                 RoomComposerDraftPolicy.maximumUTF8Bytes)
        XCTAssertTrue(String(decoding: bounded.utf8, as: UTF8.self) == bounded)
    }

    func testCollectionBoundsRejectDuplicatesCountAndAggregateStorage() {
        let id = RoomID()
        XCTAssertFalse(RoomComposerDraftPolicy.admits([
            RoomComposerDraft(roomID: id, text: "one"),
            RoomComposerDraft(roomID: id, text: "two"),
        ]))
        let tooMany = (0...RoomComposerDraftPolicy.maximumDraftCount).map { _ in
            RoomComposerDraft(roomID: RoomID(), text: "x")
        }
        XCTAssertFalse(RoomComposerDraftPolicy.admits(tooMany))
        let chunk = String(repeating: "x", count: RoomComposerDraftPolicy.maximumUTF8Bytes)
        let aggregate = (0..<65).map { _ in RoomComposerDraft(roomID: RoomID(), text: chunk) }
        XCTAssertGreaterThan(aggregate.reduce(0, { $0 + $1.text.utf8.count }),
                             RoomComposerDraftPolicy.maximumStoredUTF8Bytes)
        XCTAssertFalse(RoomComposerDraftPolicy.admits(aggregate))
    }

    func testSendCompletionClearsOnlyExactSuccessfulSnapshot() {
        XCTAssertEqual(RoomComposerDraftCompletionPolicy.result(
            current: "send me", submitted: "send me", sendSucceeded: true), "")
        XCTAssertEqual(RoomComposerDraftCompletionPolicy.result(
            current: "send me", submitted: "send me", sendSucceeded: false), "send me")
        XCTAssertEqual(RoomComposerDraftCompletionPolicy.result(
            current: "newer typing", submitted: "send me", sendSucceeded: true), "newer typing")
    }
}
