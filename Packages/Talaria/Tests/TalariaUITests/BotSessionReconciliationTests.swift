#if canImport(XCTest)
import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class BotSessionReconciliationTests: XCTestCase {
    private let now: TimeInterval = 2_000_000_000

    func testPolicyAdmitsOnlyExactOldPlumbingWithValidSecondTimestamps() {
        let rows = [
            row("old-bot", "Bot Chat", now - 300),
            row("old-inbox", " Agent Inbox\n", now - 301),
            row("old-group", "Group: Room", now - 9_000),
            row("young", "Bot Chat", now - 299),
            row("missing", "Bot Chat", nil),
            row("zero", "Bot Chat", 0),
            row("nan", "Bot Chat", .nan),
            row("infinite", "Bot Chat", .infinity),
            row("future", "Bot Chat", now + 1),
            row("milliseconds", "Bot Chat", now * 1_000),
            row("guessed", "Bot Chat notes", now - 9_000),
            row("group-guessed", "My Group: Room", now - 9_000),
            row("user", "Ordinary chat", now - 9_000),
        ]

        XCTAssertEqual(candidates(rows), ["old-bot", "old-inbox", "old-group"])
    }

    func testPolicyProtectsCanonicalLiveCurrentRoomAndRenamedRoomSessions() {
        let rows = [
            row("canonical-root", "Bot Chat", now - 9_000),
            row("canonical-tip", "Bot Chat", now - 9_000),
            row("live-chat", "Agent Inbox", now - 9_000),
            row("renamed-room-member", "Group: Old name", now - 9_000),
            row("deleted-room-orphan", "Group: Deleted room", now - 9_000),
        ]
        let protected: Set<String> = [
            "canonical-root", "canonical-tip", "live-chat", "renamed-room-member",
        ]

        XCTAssertEqual(candidates(rows, protected: protected), ["deleted-room-orphan"])
    }

    func testLegacyVisibleOwnedCanonicalAndRoomHideWhileRecentScratchStaysVisible() {
        let rows = [
            row("canonical-root", "Renamed canonical", now - 1),
            row("canonical-tip", "Bot Chat", nil),
            row("current-room", "Group: Current room", now + 100),
            row("current-scratch", "Bot Chat", now - 9_000),
            row("roster-last", "Agent Inbox", now - 9_000),
        ]
        XCTAssertEqual(
            candidates(
                rows,
                mustHideOwned: ["canonical-root", "canonical-tip", "current-room"],
                protected: ["current-scratch", "roster-last"]),
            ["canonical-root", "canonical-tip", "current-room"])
    }

    func testPolicyRejectsPartialLegacyAndSaturatedInventories() {
        let old = row("old", "Bot Chat", now - 9_000)
        XCTAssertEqual(decision([old], total: nil), .incomplete)
        XCTAssertEqual(decision([old], total: 2), .incomplete)
        XCTAssertEqual(decision([old], total: 1, hasMore: true), .incomplete)

        let saturated = (0..<BotSessionReconciliationPolicy.maximumRows).map {
            row("old-\($0)", "Bot Chat", now - 9_000)
        }
        XCTAssertEqual(decision(saturated, total: saturated.count), .incomplete)
    }

    func testOverCapRowsRemainIncompleteWhenWireLiesAboutTotal() throws {
        let rawRows: [JSONValue] = (0...BotSessionReconciliationPolicy.maximumRows).map {
            ["id": .string("old-\($0)"), "title": .string("Bot Chat"),
             "started_at": .number(now - 9_000)]
        }
        let page = try GatewayClient.decodeStoredSessionPage(
            ["sessions": .array(rawRows),
             "total": .number(Double(BotSessionReconciliationPolicy.maximumRows)),
             "has_more": .bool(false)],
            limit: BotSessionReconciliationPolicy.maximumRows, title: nil)
        let inventory = BotSessionReconciliationInventory(page)

        XCTAssertEqual(inventory.rows.count, BotSessionReconciliationPolicy.maximumRows)
        XCTAssertEqual(inventory.originalRowCount,
                       BotSessionReconciliationPolicy.maximumRows + 1)
        XCTAssertEqual(
            BotSessionReconciliationPolicy.candidateIDs(
                in: inventory, mustHideOwned: [], protected: [], now: now),
            .incomplete)
    }

    func testDuplicateIDWithinOneSourceMakesWholeInventoryIncomplete() {
        let duplicate = [
            row("same", "Bot Chat", now - 9_000),
            row("same", "Agent Inbox", now - 9_000),
            row("other", "Group: Room", now - 9_000),
        ]
        XCTAssertEqual(decision(duplicate, total: duplicate.count), .incomplete)
    }

    func testHideMutationCarriesExactProfileOnWire() {
        XCTAssertEqual(
            GatewayClient.sessionHiddenParams(
                sessionID: "same-id", hidden: true, profile: "exact-profile"),
            ["session_id": .string("same-id"), "hidden": .bool(true),
             "profile": .string("exact-profile")])
    }

    @MainActor
    func testExactSourceProfileAndIdempotentSecondSweep() async {
        let claim = claim(
            "gateway-a|profile-a", profile: "profile-a", mustHideOwned: ["owned"])
        var visible = [row("owned", "Renamed canonical", nil)]
        var requestedProfiles: [String] = []
        var hidden: [String] = []
        let operations = operations(
            list: { requested in
                requestedProfiles.append(requested.profile)
                return self.inventory(visible)
            },
            hide: { _, id in
                hidden.append(id)
                visible.removeAll { $0.id == id }
            })

        let first = await BotSessionReconciler.run(
            claims: [claim], now: now, operations: operations)
        let second = await BotSessionReconciler.run(
            claims: [claim], now: now, operations: operations)

        XCTAssertEqual(first.hiddenSessionIDs, ["owned"])
        XCTAssertEqual(second.hiddenSessionIDs, [])
        XCTAssertEqual(hidden, ["owned"])
        XCTAssertEqual(requestedProfiles, ["profile-a", "profile-a"])
    }

    @MainActor
    func testCrossProfileSessionIDCollisionIsRetainedAndDisclosed() async {
        let first = claim("gateway-a|same", profile: "same")
        let second = claim("gateway-b|same", profile: "same")
        var hidden: [String] = []
        var issues: [BotSessionReconciliationIssue] = []
        let result = await BotSessionReconciler.run(
            claims: [first, second], now: now,
            operations: operations(
                list: { _ in self.inventory([
                    self.row("collision", "Bot Chat", self.now - 9_000),
                ]) },
                hide: { _, id in hidden.append(id) },
                report: { issues.append($0) }))

        XCTAssertTrue(hidden.isEmpty)
        XCTAssertEqual(result.hiddenSessionIDs, [])
        XCTAssertEqual(issues, [
            .sessionCollision(sessionID: "collision",
                              sourceKeys: ["gateway-a|same", "gateway-b|same"]),
        ])
    }

    @MainActor
    func testSourceSwitchAfterInventoryIsNonDestructive() async {
        let source = claim("gateway-a|profile", profile: "profile")
        var currentChecks = 0
        var hidden: [String] = []
        var issues: [BotSessionReconciliationIssue] = []
        let result = await BotSessionReconciler.run(
            claims: [source], now: now,
            operations: operations(
                list: { _ in self.inventory([
                    self.row("orphan", "Bot Chat", self.now - 9_000),
                ]) },
                isCurrent: { _ in
                    currentChecks += 1
                    return false
                },
                hide: { _, id in hidden.append(id) },
                report: { issues.append($0) }))

        XCTAssertEqual(currentChecks, 1)
        XCTAssertTrue(hidden.isEmpty)
        XCTAssertEqual(result.hiddenSessionIDs, [])
        XCTAssertEqual(issues, [.stale(sourceKey: source.sourceKey)])
    }

    @MainActor
    func testAuthorityMutationBetweenCandidatesStopsThePlan() async {
        let source = claim("gateway-a|profile", profile: "profile")
        var currentChecks = 0
        var hidden: [String] = []
        var issues: [BotSessionReconciliationIssue] = []
        let result = await BotSessionReconciler.run(
            claims: [source], now: now,
            operations: operations(
                list: { _ in self.inventory([
                    self.row("first", "Bot Chat", self.now - 9_000),
                    self.row("second", "Agent Inbox", self.now - 9_000),
                ]) },
                isCurrent: { _ in
                    currentChecks += 1
                    return currentChecks < 3
                },
                hide: { _, id in hidden.append(id) },
                report: { issues.append($0) }))

        XCTAssertEqual(hidden, ["first"])
        XCTAssertEqual(result.hiddenSessionIDs, [])
        XCTAssertEqual(issues, [.stale(sourceKey: source.sourceKey)])
    }

    @MainActor
    func testMutationFailureIsDisclosedAndDoesNotHideByInference() async {
        struct Failure: Error {}
        let source = claim("gateway-a|profile", profile: "profile")
        var attempts: [String] = []
        var failures: [String] = []
        let result = await BotSessionReconciler.run(
            claims: [source], now: now,
            operations: operations(
                list: { _ in self.inventory([
                    self.row("fails", "Bot Chat", self.now - 9_000),
                    self.row("succeeds", "Agent Inbox", self.now - 9_000),
                ]) },
                hide: { _, id in
                    attempts.append(id)
                    if id == "fails" { throw Failure() }
                },
                reportMutationFailure: { _, _, id in failures.append(id) }))

        XCTAssertEqual(attempts, ["fails", "succeeds"])
        XCTAssertEqual(failures, ["fails"])
        XCTAssertEqual(result.hiddenSessionIDs, ["succeeds"])
    }

    @MainActor
    func testInventoryFailureAndDuplicateSourceAreNonDestructiveAndDisclosed() async {
        struct Failure: Error {}
        let source = claim("gateway-a|profile", profile: "profile")
        var inventoryFailures = 0
        var hidden: [String] = []
        var issues: [BotSessionReconciliationIssue] = []
        let result = await BotSessionReconciler.run(
            claims: [source, source], now: now,
            operations: operations(
                list: { _ in throw Failure() },
                hide: { _, id in hidden.append(id) },
                report: { issues.append($0) },
                reportInventoryFailure: { _, _ in inventoryFailures += 1 }))

        XCTAssertEqual(inventoryFailures, 1)
        XCTAssertTrue(hidden.isEmpty)
        XCTAssertEqual(result.hiddenSessionIDs, [])
        XCTAssertEqual(issues, [.duplicateSource(sourceKey: source.sourceKey)])
    }

    private func row(_ id: String, _ title: String, _ startedAt: Double?)
        -> BotSessionReconciliationRow {
        BotSessionReconciliationRow(id: id, title: title, startedAt: startedAt)
    }

    private func inventory(_ rows: [BotSessionReconciliationRow])
        -> BotSessionReconciliationInventory {
        BotSessionReconciliationInventory(rows: rows, total: rows.count, hasMore: false)
    }

    private func decision(
        _ rows: [BotSessionReconciliationRow], total: Int?, hasMore: Bool = false,
        mustHideOwned: Set<String> = [], protected: Set<String> = []
    ) -> BotSessionReconciliationPolicy.InventoryDecision {
        BotSessionReconciliationPolicy.candidateIDs(
            in: BotSessionReconciliationInventory(rows: rows, total: total, hasMore: hasMore),
            mustHideOwned: mustHideOwned, protected: protected, now: now)
    }

    private func candidates(
        _ rows: [BotSessionReconciliationRow], mustHideOwned: Set<String> = [],
        protected: Set<String> = []
    ) -> [String] {
        guard case .candidates(let ids) = decision(
            rows, total: rows.count, mustHideOwned: mustHideOwned,
            protected: protected) else { return [] }
        return ids
    }

    private func claim(_ sourceKey: String, profile: String,
                       mustHideOwned: Set<String> = [])
        -> BotSessionReconciliationClaim {
        BotSessionReconciliationClaim(
            sourceKey: sourceKey, profile: profile,
            mustHideOwnedSessionIDs: mustHideOwned, protectedSessionIDs: [])
    }

    @MainActor
    private func operations(
        list: @escaping (BotSessionReconciliationClaim) async throws
            -> BotSessionReconciliationInventory,
        isCurrent: @escaping (BotSessionReconciliationClaim) async -> Bool = { _ in true },
        hide: @escaping (BotSessionReconciliationClaim, String) async throws -> Void,
        report: @escaping (BotSessionReconciliationIssue) -> Void = { _ in },
        reportInventoryFailure: @escaping (Error, BotSessionReconciliationClaim) -> Void = { _, _ in },
        reportMutationFailure: @escaping (Error, BotSessionReconciliationClaim, String) -> Void = { _, _, _ in }
    ) -> BotSessionReconciliationOperations {
        BotSessionReconciliationOperations(
            list: list, isCurrent: isCurrent, hide: hide, report: report,
            reportInventoryFailure: reportInventoryFailure,
            reportMutationFailure: reportMutationFailure)
    }
}
#endif
