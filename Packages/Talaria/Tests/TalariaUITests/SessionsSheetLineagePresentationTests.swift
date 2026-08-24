#if canImport(XCTest)
import XCTest
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
        let known: Set<String> = ["root", "child"]
        XCTAssertFalse(SessionsSheetLineagePresentationPolicy.isFullTextOnly(
            sessionID: "child", knownSessionIDs: known))
        XCTAssertTrue(SessionsSheetLineagePresentationPolicy.isFullTextOnly(
            sessionID: "off-page", knownSessionIDs: known))
    }
}
#endif
