#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class SessionsSheetLineagePresentationTests: XCTestCase {
    func testActionsAndIndentRemainMobileBounded() {
        XCTAssertGreaterThanOrEqual(
            SessionsSheetLineagePresentationPolicy.minimumActionSize, 44)
        XCTAssertEqual(
            SessionsSheetLineagePresentationPolicy.visualIndentLevel(-8), 0)
        XCTAssertEqual(
            SessionsSheetLineagePresentationPolicy.visualIndentLevel(1), 1)
        XCTAssertEqual(
            SessionsSheetLineagePresentationPolicy.visualIndentLevel(200), 2)
    }

    func testVoiceOverAnnouncesLogicalRatherThanVisualLevel() {
        let label = SessionsSheetLineagePresentationPolicy.voiceOverLabel(
            title: "Research branch", logicalLevel: 17,
            branchCount: 2, orphan: false, current: true)

        XCTAssertTrue(label.contains("branch level 17"))
        XCTAssertTrue(label.contains("2 branches"))
        XCTAssertTrue(label.contains("current session"))
    }

    func testOrphanIsQuietlyIdentifiedAsBranch() {
        XCTAssertEqual(
            SessionsSheetLineagePresentationPolicy.voiceOverLabel(
                title: "Still visible", logicalLevel: 0,
                branchCount: 0, orphan: true, current: false),
            "Still visible, branch")
    }

    func testFullTextOnlyRowsNeverDuplicateLoadedHierarchy() {
        let projection = SessionLineageProjection([
            SessionSummary(
                id: "visible-tip", title: "Tip", when: "now", messageCount: 1,
                lineageRootID: "durable-root"),
            SessionSummary(
                id: "child", title: "Child", when: "now", messageCount: 1,
                parentSessionID: "durable-root",
                branchParentRootID: "durable-root"),
        ])
        let known = SessionsSheetLineagePresentationPolicy.knownSessionIdentities(
            projection.entries)
        XCTAssertFalse(SessionsSheetLineagePresentationPolicy.isFullTextOnly(
            sessionID: "durable-root", knownSessionIDs: known),
            "a loaded compressed tip owns its root alias")
        XCTAssertFalse(SessionsSheetLineagePresentationPolicy.isFullTextOnly(
            sessionID: "child", knownSessionIDs: known))
        XCTAssertTrue(SessionsSheetLineagePresentationPolicy.isFullTextOnly(
            sessionID: "off-page", knownSessionIDs: known))
    }

    func testAuthoritativePagingNoticeFailsClosedForOldGateway() {
        XCTAssertNil(SessionsSheetLineagePresentationPolicy.remainderNotice(
            loadedCount: 200, total: nil, hasMore: false))
        XCTAssertEqual(
            SessionsSheetLineagePresentationPolicy.remainderNotice(
                loadedCount: 200, total: 250, hasMore: true),
            "Showing 200 of 250 sessions. More remain on this gateway.")
        XCTAssertNotNil(SessionsSheetLineagePresentationPolicy.remainderNotice(
            loadedCount: 200, total: nil, hasMore: true))
        XCTAssertNotNil(SessionsSheetLineagePresentationPolicy.remainderNotice(
            loadedCount: 200, total: 250, hasMore: false),
            "a truthful total alone proves the page is incomplete")
    }
}
#endif
