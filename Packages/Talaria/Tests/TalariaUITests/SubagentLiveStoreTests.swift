#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI

@MainActor
final class SubagentLiveStoreTests: XCTestCase {
    private func source(_ gatewayID: String, _ parentRuntimeSessionID: String)
        -> SubagentSourceFence {
        guard let source = SubagentSourceFence(
            gatewayID: gatewayID, parentRuntimeSessionID: parentRuntimeSessionID
        ) else { fatalError("test source must be valid") }
        return source
    }

    private func event(_ kind: String, parent: String, payload: [String: JSONValue],
                       sequence: UInt64 = 0) -> (SubagentGatewayEvent, UInt64) {
        let raw = GatewayEvent(type: "subagent.\(kind)", sessionID: parent,
                               payload: .object(payload), inboundSequence: sequence)
        guard case .subagent(let decoded) = TypedGatewayEvent(raw) else {
            fatalError("test subagent payload must decode")
        }
        return (decoded, raw.inboundSequence)
    }

    private func reduce(_ store: SubagentLiveStore, source: SubagentSourceFence,
                        kind: String, payload: [String: JSONValue], sequence: UInt64 = 0) {
        let decoded = event(kind, parent: source.parentRuntimeSessionID,
                            payload: payload, sequence: sequence)
        XCTAssertTrue(store.reduce(decoded.0, source: source, inboundSequence: decoded.1))
    }

    func testCollidingSubagentIDsRemainSeparatedByExactSourceAndParent() {
        let store = SubagentLiveStore()
        let first = source("gateway-a", "parent")
        let second = source("gateway-b", "parent")
        let third = source("gateway-a", "other-parent")
        [first, second, third].forEach { store.activate($0) }

        for (index, fence) in [first, second, third].enumerated() {
            reduce(store, source: fence, kind: "start", payload: [
                "subagent_id": .string("same-id"),
                "goal": .string("goal \(index)"),
            ], sequence: UInt64(index + 1))
        }

        let all = store.snapshot()
        XCTAssertEqual(all.nodes.count, 3)
        XCTAssertEqual(Set(all.nodes.map(\.key)).count, 3)
        XCTAssertEqual(store.snapshot(for: first).nodes.map(\.key.subagentID), ["same-id"])
        XCTAssertEqual(store.snapshot(for: second).nodes.first?.key.gatewayID, "gateway-b")
        XCTAssertEqual(store.snapshot(for: third).nodes.first?.key.parentRuntimeSessionID,
                       "other-parent")
    }

    func testChildBeforeParentAttachesByExactIDInStableTreeOrder() {
        let store = SubagentLiveStore()
        let fence = source("gateway", "parent-runtime")
        store.activate(fence)

        reduce(store, source: fence, kind: "start", payload: [
            "subagent_id": .string("child-first"),
            "parent_id": .string("root"),
            "goal": .string("This name must not control hierarchy"),
        ], sequence: 1)
        reduce(store, source: fence, kind: "start", payload: [
            "subagent_id": .string("second-child"),
            "parent_id": .string("root"),
        ], sequence: 2)
        reduce(store, source: fence, kind: "start", payload: [
            "subagent_id": .string("root"),
            "goal": .string("A completely different label"),
        ], sequence: 3)

        let nodes = store.snapshot(for: fence).nodes
        XCTAssertEqual(nodes.map(\.key.subagentID), ["root", "child-first", "second-child"])
        let root = try! XCTUnwrap(nodes.first)
        XCTAssertEqual(nodes[1].parentKey, root.key)
        XCTAssertEqual(nodes[2].parentKey, root.key)
        XCTAssertEqual(nodes[1].hierarchyDepth, 1)
        XCTAssertEqual(nodes[2].hierarchyDepth, 1)
        XCTAssertFalse(nodes[1].isOrphaned)
    }

    func testHostileFieldsAreBoundedWithoutCreatingUnboundedState() {
        let store = SubagentLiveStore()
        let fence = source("gateway", "bounded-parent")
        store.activate(fence)
        let files = (0..<(SubagentEventLimits.maximumFilesPerKind + 12)).map {
            JSONValue.string("Sources/\($0).swift")
        }
        let tail = (0..<(SubagentEventLimits.maximumTailEntries + 12)).map {
            JSONValue.object([
                "tool": .string("tool-\($0)"),
                "preview": .string(String(repeating: "p", count: 900)),
                "is_error": .bool(false),
            ])
        }
        reduce(store, source: fence, kind: "complete", payload: [
            "subagent_id": .string("bounded"),
            "goal": .string(String(repeating: "g", count: SubagentEventLimits.maximumTextScalars + 64)),
            "depth": .number(Double(SubagentEventLimits.maximumReportedDepth + 1)),
            "input_tokens": .number(Double(SubagentEventLimits.maximumCounter + 1)),
            "output_tokens": .number(42),
            "duration_seconds": .number(Double.infinity),
            "cost_usd": .number(SubagentEventLimits.maximumCostUSD + 1),
            "files_read": .array(files),
            "files_written": .array(files),
            "output_tail": .array(tail),
        ], sequence: 1)

        let node = try! XCTUnwrap(store.snapshot(for: fence).nodes.first)
        XCTAssertLessThanOrEqual(node.goal?.unicodeScalars.count ?? .max,
                                 SubagentEventLimits.maximumTextScalars)
        XCTAssertNil(node.reportedDepth)
        XCTAssertEqual(node.tokenUsage.inputTokens, 0)
        XCTAssertEqual(node.tokenUsage.outputTokens, 42)
        XCTAssertNil(node.cost.durationSeconds)
        XCTAssertNil(node.cost.costUSD)
        XCTAssertEqual(node.filesRead.count, SubagentEventLimits.maximumFilesPerKind)
        XCTAssertEqual(node.filesWritten.count, SubagentEventLimits.maximumFilesPerKind)
        XCTAssertEqual(node.outputTail.count, SubagentEventLimits.maximumTailEntries)
        XCTAssertTrue(node.isClipped)
    }

    func testNodeAndDerivedHierarchyDepthCapsKeepEarlierEvidenceStable() {
        let depthStore = SubagentLiveStore()
        let depthFence = source("gateway", "depth-parent")
        depthStore.activate(depthFence)
        for level in 0...(SubagentLiveStoreLimits.maximumHierarchyDepth + 1) {
            var payload: [String: JSONValue] = [
                "subagent_id": .string("level-\(level)"),
            ]
            if level > 0 { payload["parent_id"] = .string("level-\(level - 1)") }
            reduce(depthStore, source: depthFence, kind: "start", payload: payload,
                   sequence: UInt64(level + 1))
        }
        let deepest = try! XCTUnwrap(depthStore.snapshot(for: depthFence).nodes.first {
            $0.key.subagentID == "level-\(SubagentLiveStoreLimits.maximumHierarchyDepth + 1)"
        })
        XCTAssertTrue(deepest.isOrphaned)
        XCTAssertEqual(deepest.hierarchyDepth, 0)

        let countStore = SubagentLiveStore()
        let countFence = source("gateway", "count-parent")
        countStore.activate(countFence)
        for index in 0..<(SubagentLiveStoreLimits.maximumNodes + 5) {
            let decoded = event("start", parent: countFence.parentRuntimeSessionID, payload: [
                "subagent_id": .string("node-\(index)"),
            ], sequence: UInt64(index + 1))
            _ = countStore.reduce(decoded.0, source: countFence, inboundSequence: decoded.1)
        }
        let snapshot = countStore.snapshot(for: countFence)
        XCTAssertEqual(snapshot.nodes.count, SubagentLiveStoreLimits.maximumNodes)
        XCTAssertTrue(snapshot.isTruncated)
        XCTAssertEqual(snapshot.droppedNodeCount, 5)
        XCTAssertNotNil(snapshot.nodes.first { $0.key.subagentID == "node-0" })
    }

    func testCyclicParentClaimsBreakOneExactEdgeWithoutDuplicatingNodes() {
        let store = SubagentLiveStore()
        let fence = source("gateway", "cycle-parent")
        store.activate(fence)
        reduce(store, source: fence, kind: "start", payload: [
            "subagent_id": .string("a"),
            "parent_id": .string("b"),
        ], sequence: 1)
        reduce(store, source: fence, kind: "start", payload: [
            "subagent_id": .string("b"),
            "parent_id": .string("a"),
        ], sequence: 2)

        let nodes = store.snapshot(for: fence).nodes
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(Set(nodes.map(\.key)).count, 2)
        XCTAssertEqual(nodes.filter { $0.isOrphaned }.count, 1)
        XCTAssertEqual(nodes.filter { $0.parentKey != nil }.count, 1)
    }

    func testMalformedCompletionFailsClosedWithoutDeletingPriorEvidence() {
        let store = SubagentLiveStore()
        let fence = source("gateway", "malformed-parent")
        store.activate(fence)
        reduce(store, source: fence, kind: "start", payload: [
            "subagent_id": .string("safe"),
            "goal": .string("keep this goal"),
            "files_read": .array([.string("Sources/Kept.swift")]),
        ], sequence: 1)
        reduce(store, source: fence, kind: "complete", payload: [
            "subagent_id": .string("safe"),
            "goal": .string("replace\u{202E}me"),
            "files_read": .string("not-an-array"),
            "status": .string("future-terminal-state"),
        ], sequence: 2)

        let node = try! XCTUnwrap(store.snapshot(for: fence).nodes.first)
        XCTAssertEqual(node.goal, "keep this goal")
        XCTAssertEqual(node.filesRead, ["Sources/Kept.swift"])
        XCTAssertEqual(node.status, .failed)
    }

    func testCompleteWithExplicitActiveOrUnknownStatusFailsClosedToFailure() {
        let store = SubagentLiveStore()
        let fence = source("gateway", "complete-status-parent")
        store.activate(fence)

        for (index, status) in ["running", "queued", "future-status"].enumerated() {
            reduce(store, source: fence, kind: "complete", payload: [
                "subagent_id": .string("branch-\(index)"),
                "status": .string(status),
            ], sequence: UInt64(index + 1))
        }
        reduce(store, source: fence, kind: "complete", payload: [
            "subagent_id": .string("branch-absent"),
        ], sequence: 4)

        let nodes = store.snapshot(for: fence).nodes
        XCTAssertEqual(nodes.map(\.status), [.failed, .failed, .failed, .completed])
    }

    func testCompleteCanceledAndCancelledStatusesPreserveCanonicalCancelledOutcome() {
        let store = SubagentLiveStore()
        let fence = source("gateway", "canceled-status-parent")
        store.activate(fence)

        for (index, rawStatus) in ["cancelled", "canceled"].enumerated() {
            reduce(store, source: fence, kind: "complete", payload: [
                "subagent_id": .string("branch-\(index)"),
                "status": .string(rawStatus),
            ], sequence: UInt64(index + 1))
        }

        XCTAssertEqual(store.snapshot(for: fence).nodes.map(\.status), [.cancelled, .cancelled])
    }

    func testTerminalStatusIsStickyAndCountersCostsAndChildReferenceAreExact() {
        let store = SubagentLiveStore()
        let fence = source("gateway-exact", "parent-exact")
        store.activate(fence)
        reduce(store, source: fence, kind: "start", payload: [
            "subagent_id": .string("branch"),
            "child_session_id": .string("child-stored-key"),
        ], sequence: 1)
        reduce(store, source: fence, kind: "complete", payload: [
            "subagent_id": .string("branch"),
            "status": .string("timeout"),
            "summary": .string("Timed out after useful work"),
            "input_tokens": .number(10),
            "output_tokens": .number(20),
            "reasoning_tokens": .number(30),
            "api_calls": .number(4),
            "duration_seconds": .number(12.5),
            "cost_usd": .number(0.45),
        ], sequence: 2)
        reduce(store, source: fence, kind: "thinking", payload: [
            "subagent_id": .string("branch"),
            "text": .string("late progress must not resurrect the branch"),
        ], sequence: 3)

        let node = try! XCTUnwrap(store.snapshot(for: fence).nodes.first)
        XCTAssertEqual(node.status, .timeout)
        XCTAssertEqual(node.summary, "Timed out after useful work")
        XCTAssertEqual(node.latestActivity?.kind, .complete)
        XCTAssertEqual(node.tokenUsage, SubagentTokenUsage(
            inputTokens: 10, outputTokens: 20, reasoningTokens: 30, apiCalls: 4))
        XCTAssertEqual(node.cost.durationSeconds, 12.5)
        XCTAssertEqual(node.cost.costUSD, 0.45)
        let child = try! XCTUnwrap(node.childSession)
        XCTAssertEqual(child.gatewayID, "gateway-exact")
        XCTAssertEqual(child.parentRuntimeSessionID, "parent-exact")
        XCTAssertEqual(child.subagentID, "branch")
        XCTAssertEqual(child.childSessionID, "child-stored-key")

        let stale = event("complete", parent: fence.parentRuntimeSessionID, payload: [
            "subagent_id": .string("branch"),
            "status": .string("completed"),
        ], sequence: 2)
        XCTAssertFalse(store.reduce(stale.0, source: fence, inboundSequence: stale.1))
        XCTAssertEqual(store.summary(for: node.key)?.status, .timeout)
    }

    func testInactiveForeignEventsAreRejectedAndExactTeardownKeepsSiblingSource() {
        let store = SubagentLiveStore()
        let retained = source("gateway", "retained-parent")
        let sibling = source("gateway", "sibling-parent")
        let foreign = source("foreign-gateway", "retained-parent")
        store.activate(retained)
        store.activate(sibling)
        reduce(store, source: retained, kind: "start", payload: [
            "subagent_id": .string("same"),
        ], sequence: 1)
        reduce(store, source: sibling, kind: "start", payload: [
            "subagent_id": .string("same"),
        ], sequence: 1)

        let stale = event("start", parent: foreign.parentRuntimeSessionID, payload: [
            "subagent_id": .string("same"),
        ], sequence: 1)
        XCTAssertFalse(store.reduce(stale.0, source: foreign, inboundSequence: stale.1))
        XCTAssertEqual(store.snapshot().nodes.count, 2)

        store.tearDown(retained)
        XCTAssertFalse(store.isActive(retained))
        XCTAssertTrue(store.isActive(sibling))
        XCTAssertTrue(store.snapshot(for: retained).nodes.isEmpty)
        let surviving = try! XCTUnwrap(store.snapshot(for: sibling).nodes.first)
        XCTAssertEqual(surviving.key.gatewayID, "gateway")
        XCTAssertEqual(surviving.key.parentRuntimeSessionID, "sibling-parent")
        XCTAssertEqual(surviving.key.subagentID, "same")
    }

    func testAppModelRoutingRequiresItsExactActiveGatewayAndParentSessionFence() {
        let gatewayID = "gateway-\(UUID().uuidString)"
        let parentID = "parent-\(UUID().uuidString)"
        let fence = source(gatewayID, parentID)
        let runtime = LiveRuntime.shared
        let oldGatewayID = runtime.gatewayID
        let oldSessions = runtime.sessionToBot
        defer {
            SubagentLiveRuntime.shared.store.tearDown(fence)
            runtime.gatewayID = oldGatewayID
            runtime.sessionToBot = oldSessions
        }

        let model = AppModel()
        model.mode = .live
        model.chats["bot"] = ChatState()
        model.chats["bot"]?.sessionID = parentID
        runtime.gatewayID = gatewayID
        runtime.sessionToBot[parentID] = "bot"

        let frame = GatewayEvent(type: "subagent.start", sessionID: parentID,
                                 payload: .object(["subagent_id": .string("branch")]),
                                 inboundSequence: 1)
        model.handle(event: frame, sourceGatewayID: gatewayID)
        XCTAssertTrue(model.subagentLiveSnapshot(for: fence).nodes.isEmpty,
                      "a decoded frame cannot self-activate a source fence")

        SubagentLiveRuntime.shared.store.activate(fence)
        model.handle(event: frame, sourceGatewayID: "foreign-\(gatewayID)")
        XCTAssertTrue(model.subagentLiveSnapshot(for: fence).nodes.isEmpty,
                      "a foreign source cannot reuse the primary runtime sid")

        model.handle(event: frame, sourceGatewayID: gatewayID)
        XCTAssertEqual(model.subagentLiveSnapshot(for: fence).nodes.map(\.key.subagentID),
                       ["branch"])
    }
}
#endif
