#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI

@MainActor
final class SubagentLivePresentationTests: XCTestCase {
    private func source(_ gateway: String = "gateway", _ runtime: String = "parent")
        -> SubagentSourceFence {
        SubagentSourceFence(gatewayID: gateway, parentRuntimeSessionID: runtime)!
    }

    private func node(
        _ id: String,
        source: SubagentSourceFence,
        status: SubagentStatus = .running,
        childSessionID: String? = nil,
        filesRead: [String] = [],
        filesWritten: [String] = [],
        outputTail: [SubagentOutputTailEntry] = []
    ) -> SubagentNodeSummary {
        let key = SubagentNodeKey(
            gatewayID: source.gatewayID,
            parentRuntimeSessionID: source.parentRuntimeSessionID,
            subagentID: id)!
        let child = childSessionID.flatMap {
            SubagentChildSessionReference(key: key, childSessionID: $0)
        }
        return SubagentNodeSummary(
            key: key, childSession: child, status: status,
            filesRead: filesRead, filesWritten: filesWritten,
            outputTail: outputTail)
    }

    func testPresentationIsSourceScopedBoundedAndReportsOmittedRows() throws {
        let fence = source()
        let nodes = (0..<70).map { index in
            node("agent-\(index)", source: fence,
                 status: index < 3 ? .running : (index < 8 ? .failed : .completed))
        }
        let projection = try XCTUnwrap(SubagentLivePresentationPolicy.make(
            snapshot: SubagentLiveSnapshot(
                source: fence, nodes: nodes,
                isTruncated: true, droppedNodeCount: 2)))

        XCTAssertEqual(projection.source, fence)
        XCTAssertEqual(projection.totalCount, 70)
        XCTAssertEqual(projection.nodes.count,
                       SubagentLivePresentationPolicy.maximumPresentedNodes)
        XCTAssertEqual(projection.activeCount, 3)
        XCTAssertEqual(projection.failedCount, 5)
        XCTAssertEqual(projection.hiddenNodeCount, 6)
        XCTAssertEqual(projection.droppedNodeCount, 2)
        XCTAssertTrue(projection.isTruncated)
        XCTAssertNil(SubagentLivePresentationPolicy.make(
            snapshot: SubagentLiveSnapshot(source: fence)))
    }

    func testFilesAndOutputTailUsePhoneBoundsWithExactOmissionCounts() {
        let fence = source()
        let reads = (0..<5).map { "Read/\($0).swift" }
        let writes = (0..<5).map { "Write/\($0).swift" }
        let tail = (0..<7).map {
            SubagentOutputTailEntry(tool: "tool-\($0)", preview: "preview-\($0)",
                                    isError: $0 == 6)
        }
        let value = node("bounded", source: fence, filesRead: reads,
                         filesWritten: writes, outputTail: tail)

        let files = SubagentLivePresentationPolicy.files(for: value)
        XCTAssertEqual(files.count, 6)
        XCTAssertEqual(files.map(\.access), [.read, .read, .read, .read, .read, .written])
        XCTAssertEqual(SubagentLivePresentationPolicy.hiddenFileCount(for: value), 4)
        XCTAssertEqual(SubagentLivePresentationPolicy.outputTail(for: value).map(\.tool),
                       ["tool-3", "tool-4", "tool-5", "tool-6"])
        XCTAssertEqual(SubagentLivePresentationPolicy.hiddenTailCount(for: value), 3)
    }

    func testChildNavigationRequiresExactCurrentSourceAndListedDurableKey() {
        let fence = source("home", "runtime-a")
        let value = node("worker", source: fence, childSessionID: "child-stored")

        XCTAssertEqual(SubagentLivePresentationPolicy.provenChildStoredSessionID(
            node: value, source: fence,
            currentGatewayID: "home", currentRuntimeSessionID: "runtime-a",
            availableStoredSessionIDs: ["child-stored"]), "child-stored")

        for (gateway, runtime, listed) in [
            ("foreign", "runtime-a", Set(["child-stored"])),
            ("home", "replacement", Set(["child-stored"])),
            ("home", "runtime-a", Set<String>()),
        ] {
            XCTAssertNil(SubagentLivePresentationPolicy.provenChildStoredSessionID(
                node: value, source: fence,
                currentGatewayID: gateway, currentRuntimeSessionID: runtime,
                availableStoredSessionIDs: listed))
        }

        let foreignSource = source("foreign", "runtime-a")
        XCTAssertNil(SubagentLivePresentationPolicy.provenChildStoredSessionID(
            node: value, source: foreignSource,
            currentGatewayID: "foreign", currentRuntimeSessionID: "runtime-a",
            availableStoredSessionIDs: ["child-stored"]))
    }

    func testAcceptedEventsAndExactTeardownAdvanceObservableRevision() throws {
        let store = SubagentLiveStore()
        let fence = source()
        store.activate(fence)
        XCTAssertEqual(store.presentationRevision, 0)

        let raw = GatewayEvent(
            type: "subagent.start", sessionID: fence.parentRuntimeSessionID,
            payload: .object(["subagent_id": .string("worker")]),
            inboundSequence: 1)
        guard case .subagent(let decoded) = TypedGatewayEvent(raw) else {
            return XCTFail("fixture must decode")
        }
        XCTAssertTrue(store.reduce(decoded, source: fence, inboundSequence: 1))
        XCTAssertEqual(store.presentationRevision, 1)

        XCTAssertFalse(store.reduce(decoded, source: fence, inboundSequence: 1))
        XCTAssertEqual(store.presentationRevision, 1,
                       "stale evidence must not invalidate the visible snapshot")

        store.tearDown(fence)
        XCTAssertEqual(store.presentationRevision, 2)
        XCTAssertTrue(store.snapshot(for: fence).nodes.isEmpty)
    }

    func testAppModelNavigationProofRechecksCurrentRouteRuntimeLedgerAndSessionList() throws {
        let gatewayID = "presentation-\(UUID().uuidString)"
        let runtimeID = "runtime-\(UUID().uuidString)"
        let fence = source(gatewayID, runtimeID)
        let live = LiveRuntime.shared
        let previousGatewayID = live.gatewayID
        defer {
            live.gatewayID = previousGatewayID
            SubagentLiveRuntime.shared.store.tearDown(fence)
        }
        live.gatewayID = gatewayID

        let model = AppModel()
        model.mode = .live
        let chat = model.chat(for: "worker")
        chat.sessionID = runtimeID
        chat.storedSessions = [SessionSummary(
            id: "child-stored", title: "Child", when: "now", messageCount: 1)]

        let raw = GatewayEvent(
            type: "subagent.start", sessionID: runtimeID,
            payload: .object([
                "subagent_id": .string("child"),
                "child_session_id": .string("child-stored"),
            ]), inboundSequence: 1)
        guard case .subagent(let decoded) = TypedGatewayEvent(raw) else {
            return XCTFail("fixture must decode")
        }
        let store = SubagentLiveRuntime.shared.store
        store.activate(fence)
        XCTAssertTrue(store.reduce(decoded, source: fence, inboundSequence: 1))
        let current = try XCTUnwrap(store.snapshot(for: fence).nodes.first)

        XCTAssertEqual(model.provenSubagentChildStoredSessionID(
            for: current, botID: "worker", source: fence), "child-stored")

        chat.sessionID = "replacement-runtime"
        XCTAssertNil(model.provenSubagentChildStoredSessionID(
            for: current, botID: "worker", source: fence))
        chat.sessionID = runtimeID
        chat.storedSessions = []
        XCTAssertNil(model.provenSubagentChildStoredSessionID(
            for: current, botID: "worker", source: fence))
        chat.storedSessions = [SessionSummary(
            id: "child-stored", title: "Child", when: "now", messageCount: 1)]
        store.tearDown(fence)
        XCTAssertNil(model.provenSubagentChildStoredSessionID(
            for: current, botID: "worker", source: fence),
            "a stale sheet row cannot navigate after exact source teardown")
    }
}
#endif
