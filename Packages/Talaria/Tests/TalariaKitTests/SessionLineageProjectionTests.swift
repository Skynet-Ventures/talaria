#if canImport(XCTest)
import XCTest
@testable import TalariaKit

final class SessionLineageProjectionTests: XCTestCase {
    private func row(_ id: String, title: String? = nil, root: String? = nil,
                     parent: String? = nil, normalizedParent: String? = nil,
                     started: Double? = nil, active: Double? = nil,
                     preview: String? = nil) -> SessionSummary {
        SessionSummary(id: id, title: title ?? id, when: "now", messageCount: 1,
                       preview: preview, startedAt: started, lastActive: active,
                       lineageRootID: root, parentSessionID: parent,
                       branchParentRootID: normalizedParent)
    }

    func testWireOptionalLineageFieldsFailClosedWithoutDroppingRow() throws {
        let value: JSONValue = .object([
            "sessions": .array([.object([
                "id": .string("valid"),
                "_lineage_root_id": .number(7),
                "parent_session_id": .bool(true),
                "branch_parent_root_id": .array([]),
                "last_active": .string("not-a-number"),
            ])]),
            "total": .string("not-a-number"),
            "has_more": .number(1),
        ])
        let page = try GatewayClient.decodeStoredSessionPage(value, limit: 200, title: nil)
        XCTAssertEqual(page.sessions.count, 1)
        XCTAssertEqual(page.sessions[0].id, "valid")
        XCTAssertNil(page.sessions[0].lineageRootID)
        XCTAssertNil(page.sessions[0].parentSessionID)
        XCTAssertNil(page.sessions[0].branchParentRootID)
        XCTAssertNil(page.sessions[0].lastActive)
        XCTAssertNil(page.total)
        XCTAssertFalse(page.hasMore)
    }

    func testWireRowsAndMetadataAreCappedAtTwoHundred() throws {
        let raw = (0..<250).map { index -> JSONValue in
            .object(["id": .string("s-\(index)"),
                     "last_active": .number(Double(index))])
        }
        let page = try GatewayClient.decodeStoredSessionPage(
            .object(["sessions": .array(raw), "total": .number(250),
                     "has_more": .bool(true)]),
            limit: 500, title: nil)
        XCTAssertEqual(page.sessions.count, 200)
        XCTAssertEqual(page.sessions.last?.id, "s-199")
        XCTAssertEqual(page.total, 250)
        XCTAssertTrue(page.hasMore)
    }

    func testSessionSummaryCodableKeepsOldSnapshotsCompatible() throws {
        let old = Data(#"{"id":"legacy","title":"Legacy","when":"today","messageCount":3}"#.utf8)
        let decoded = try JSONDecoder().decode(SessionSummary.self, from: old)
        XCTAssertEqual(decoded.id, "legacy")
        XCTAssertNil(decoded.lineageRootID)
        XCTAssertNil(decoded.parentSessionID)
        XCTAssertNil(decoded.branchParentRootID)

        let enriched = row("tip", root: "root", parent: "parent",
                           normalizedParent: "parent-root", started: 4, active: 9)
        XCTAssertEqual(
            try JSONDecoder().decode(
                SessionSummary.self, from: JSONEncoder().encode(enriched)),
            enriched)
    }

    func testCompressedParentAliasAndNormalizedParentSurviveRecompression() {
        let projection = SessionLineageProjection([
            row("tip-2", root: "root", active: 30),
            row("child", parent: "root", active: 10),
            row("grandchild", parent: "child", normalizedParent: "child", active: 5),
        ])
        XCTAssertEqual(projection.entries.map(\.id), ["tip-2", "child", "grandchild"])
        XCTAssertEqual(projection.entries.map(\.parentID), [nil, "tip-2", "child"])
        XCTAssertEqual(projection.entries.map(\.logicalLevel), [0, 1, 2])
        XCTAssertFalse(projection.entries[1].isOrphan)
    }

    func testCompressedBranchRetainsConversationParentAndOwnChildren() {
        let projection = SessionLineageProjection([
            row("conversation-root"),
            row("branch-tip", root: "branch-root", parent: "conversation-root",
                normalizedParent: "conversation-root"),
            row("branch-child", parent: "branch-root",
                normalizedParent: "branch-root"),
        ])

        XCTAssertEqual(projection.entries.map(\.id), [
            "conversation-root", "branch-tip", "branch-child",
        ])
        XCTAssertEqual(projection.entries.map(\.parentID), [
            nil, "conversation-root", "branch-tip",
        ])
        XCTAssertEqual(projection.entries.map(\.rootID), [
            "conversation-root", "conversation-root", "conversation-root",
        ])
    }

    func testNormalizedParentWinsOverStaleExactIdAndSelfParentFailsClosed() {
        let projection = SessionLineageProjection([
            row("root-a"),
            row("root-b"),
            row("child", parent: "root-a", normalizedParent: "root-b"),
            row("self", parent: "self"),
        ])
        XCTAssertEqual(projection.entries.first(where: { $0.id == "child" })?.parentID,
                       "root-b")
        XCTAssertTrue(projection.entries.first(where: { $0.id == "self" })?.isOrphan == true)
    }

    func testMissingOffPageParentIsTopLevelOrphan() {
        let projection = SessionLineageProjection([
            row("child", parent: "deleted-parent"),
            row("other"),
        ])
        XCTAssertEqual(projection.entries.map(\.id), ["child", "other"])
        XCTAssertEqual(projection.entries[0].parentID, nil)
        XCTAssertTrue(projection.entries[0].isOrphan)
        XCTAssertEqual(projection.roots.map(\.id), ["child", "other"])
    }

    func testDuplicateCycleAndDepthBombsRemainBoundedAndUnique() {
        var rows = [
            row("a", parent: "b"),
            row("b", parent: "a"),
            row("a", title: "duplicate"),
        ]
        for index in 0..<80 {
            rows.append(row("deep-\(index)", parent: index == 0 ? nil : "deep-\(index - 1)"))
        }
        let projection = SessionLineageProjection(rows, maxDepth: 8)
        XCTAssertEqual(projection.entries.count, rows.count - 1)
        XCTAssertEqual(Set(projection.entries.map(\.id)).count, projection.entries.count)
        XCTAssertLessThanOrEqual(projection.entries.count, 200)
        XCTAssertTrue(projection.entries.contains {
            $0.isOrphan && ($0.id == "a" || $0.id == "b")
        })
        XCTAssertTrue(projection.entries.contains { $0.isOrphan && $0.id == "deep-9" })
    }

    func testChildrenUseActivityThenStartedThenOrdinalAndID() {
        let projection = SessionLineageProjection([
            row("root"),
            row("z", parent: "root", started: 5, active: 100),
            row("a", parent: "root", started: 8, active: 100),
            row("same-second-late", parent: "root", started: 2, active: 100),
            row("fallback", parent: "root", started: 200),
            row("explicit-activity", parent: "root", started: 1000, active: 99),
        ])
        XCTAssertEqual(projection.entries.map(\.id), [
            "root", "fallback", "a", "z", "same-second-late", "explicit-activity",
        ])
        XCTAssertEqual(projection.entries[1].branchStem, "├─ ")
        XCTAssertEqual(projection.entries[5].branchStem, "└─ ")
    }

    func testSearchKeepsMatchingAncestorsAndPinnedRootGroupIncludesDescendants() {
        let summaries = [
            row("root", title: "Root"),
            row("branch", title: "Branch", parent: "root"),
            row("tip", title: "needle result", root: "tip-root", parent: "branch"),
            row("other", title: "Other"),
        ]
        let projection = SessionLineageProjection(summaries)
        XCTAssertEqual(projection.search("needle").map(\.id), ["root", "branch", "tip"])
        XCTAssertEqual(projection.searchAncestors(for: "tip").map(\.id), ["root", "branch"])
        XCTAssertEqual(projection.pinnedRootGroup(for: "branch").map(\.id), [
            "root", "branch", "tip",
        ])
    }
}
#endif
