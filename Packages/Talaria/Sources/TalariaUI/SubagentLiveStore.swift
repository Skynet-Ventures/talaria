import Foundation
import TalariaKit

/// Hard local ceilings for foreground-only subagent progress.  The relay is a
/// live advisory stream, so this store never evicts an admitted branch merely
/// to make room for a later unknown one.
public enum SubagentLiveStoreLimits {
    public static let maximumNodes = 128
    public static let maximumHierarchyDepth = 8
    public static let maximumDroppedNodeCount = 1_000_000
}

/// Main-actor reducer for the source-fenced `subagent.*` live stream.
///
/// There is intentionally no persistence or reconnect restoration here. The
/// current Hermes relay does not expose an authoritative subagent snapshot or
/// list endpoint, so carrying this advisory state to a replacement runtime
/// session would fabricate recovery evidence. Callers activate a source when
/// its exact parent runtime session is bound and tear down that same source
/// when it is released.
@MainActor
public final class SubagentLiveStore {
    private struct Node {
        let key: SubagentNodeKey
        let firstSeenOrder: UInt64
        var lastUpdatedOrder: UInt64
        var lastInboundSequence: UInt64
        var parentSubagentID: String?
        var childSession: SubagentChildSessionReference?
        var status: SubagentStatus
        var goal: String?
        var model: String?
        var taskCount: Int?
        var taskIndex: Int?
        var reportedDepth: Int?
        var toolCount: Int?
        var toolsets: [String]
        var latestActivity: SubagentLatestActivity?
        var summary: String?
        var tokenUsage: SubagentTokenUsage
        var cost: SubagentCostMetrics
        var filesRead: [String]
        var filesWritten: [String]
        var outputTail: [SubagentOutputTailEntry]
        var isClipped: Bool

        init(key: SubagentNodeKey, order: UInt64, sequence: UInt64,
             status: SubagentStatus) {
            self.key = key
            firstSeenOrder = order
            lastUpdatedOrder = order
            lastInboundSequence = sequence
            parentSubagentID = nil
            childSession = nil
            self.status = status
            goal = nil
            model = nil
            taskCount = nil
            taskIndex = nil
            reportedDepth = nil
            toolCount = nil
            toolsets = []
            latestActivity = nil
            summary = nil
            tokenUsage = .init()
            cost = .init()
            filesRead = []
            filesWritten = []
            outputTail = []
            isClipped = false
        }
    }

    private struct Projection {
        let parent: SubagentNodeKey?
        let depth: Int
        let isOrphaned: Bool
    }

    private var activeSources = Set<SubagentSourceFence>()
    private var nodes: [SubagentNodeKey: Node] = [:]
    private var droppedNodeCountBySource: [SubagentSourceFence: Int] = [:]
    private var order: UInt64 = 0

    public init() {}

    /// Open the exact parent-session fence. Re-activating the same foreground
    /// session preserves its already-admitted evidence; a new runtime id must
    /// use a distinct fence and cannot inherit this one.
    public func activate(_ source: SubagentSourceFence) {
        activeSources.insert(source)
    }

    public func isActive(_ source: SubagentSourceFence) -> Bool {
        activeSources.contains(source)
    }

    /// Remove only this exact source's live evidence and fence. A sibling
    /// session on the same gateway, or the same short sid on another gateway,
    /// remains untouched.
    public func tearDown(_ source: SubagentSourceFence) {
        activeSources.remove(source)
        nodes = nodes.filter { $0.key.source != source }
        droppedNodeCountBySource.removeValue(forKey: source)
    }

    /// Apply a previously decoded event only while its exact parent source is
    /// active. `inboundSequence` is the transport order; zero remains reserved
    /// for synthetic tests and is never allowed to overwrite sequenced live
    /// evidence.
    @discardableResult
    public func reduce(_ event: SubagentGatewayEvent, source: SubagentSourceFence,
                       inboundSequence: UInt64 = 0) -> Bool {
        guard activeSources.contains(source),
              event.parentRuntimeSessionID == source.parentRuntimeSessionID,
              let key = SubagentNodeKey(gatewayID: source.gatewayID,
                                        parentRuntimeSessionID: source.parentRuntimeSessionID,
                                        subagentID: event.subagentID)
        else { return false }

        if var node = nodes[key] {
            guard accepts(inboundSequence: inboundSequence,
                          after: node.lastInboundSequence) else { return false }
            let eventOrder = nextOrder()
            merge(event, into: &node, order: eventOrder, inboundSequence: inboundSequence)
            nodes[key] = node
            return true
        }

        guard nodes.count < SubagentLiveStoreLimits.maximumNodes else {
            droppedNodeCountBySource[source] = min(
                SubagentLiveStoreLimits.maximumDroppedNodeCount,
                (droppedNodeCountBySource[source] ?? 0) + 1
            )
            return false
        }

        let eventOrder = nextOrder()
        var node = Node(key: key, order: eventOrder, sequence: inboundSequence,
                        status: initialStatus(for: event))
        merge(event, into: &node, order: eventOrder, inboundSequence: inboundSequence)
        nodes[key] = node
        return true
    }

    /// Return a value snapshot for all currently retained sources, or one
    /// exact source. The returned structs share no mutable store state.
    public func snapshot(for source: SubagentSourceFence? = nil) -> SubagentLiveSnapshot {
        let scoped = nodes.values.filter { source == nil || $0.key.source == source }
        let projected = project(scoped)
        let dropped: Int
        if let source {
            dropped = droppedNodeCountBySource[source] ?? 0
        } else {
            dropped = droppedNodeCountBySource.values.reduce(0) { partial, value in
                min(SubagentLiveStoreLimits.maximumDroppedNodeCount, partial + value)
            }
        }
        return SubagentLiveSnapshot(source: source, nodes: projected,
                                    isTruncated: dropped > 0 || projected.contains(where: { $0.isClipped }),
                                    droppedNodeCount: dropped)
    }

    /// Return one exact branch projection. A bare subagent id cannot query the
    /// store because it could collide across parent sessions or gateways.
    public func summary(for key: SubagentNodeKey) -> SubagentNodeSummary? {
        snapshot(for: key.source).nodes.first { $0.key == key }
    }

    private func nextOrder() -> UInt64 {
        if order < UInt64.max { order += 1 }
        return order
    }

    private func accepts(inboundSequence: UInt64, after prior: UInt64) -> Bool {
        if prior == 0 { return true }
        guard inboundSequence > 0 else { return false }
        return inboundSequence > prior
    }

    private func initialStatus(for event: SubagentGatewayEvent) -> SubagentStatus {
        if event.kind == .complete {
            switch event.status {
            case .absent:
                return .completed
            case .value(let status) where status.isTerminal:
                return status
            case .value, .malformed:
                // A complete frame is terminal by contract. An explicit
                // unknown or still-active status must fail closed instead of
                // leaving a branch running after its terminal relay frame.
                return .failed
            }
        }
        if case .value(let status) = event.status { return status }
        return .running
    }

    private func merge(_ event: SubagentGatewayEvent, into node: inout Node,
                       order: UInt64, inboundSequence: UInt64) {
        node.lastUpdatedOrder = order
        if inboundSequence > 0 { node.lastInboundSequence = inboundSequence }
        node.isClipped = node.isClipped || event.isClipped

        if let parent = event.parentSubagentID, parent != node.key.subagentID {
            if node.parentSubagentID == nil {
                node.parentSubagentID = parent
            } else if node.parentSubagentID != parent {
                // Parent identity is immutable after first admission. A later
                // conflicting label is not authority to rewire the tree.
                node.isClipped = true
            }
        } else if event.parentSubagentID == node.key.subagentID {
            node.isClipped = true
        }

        if let childID = event.childSessionID,
           let child = SubagentChildSessionReference(key: node.key, childSessionID: childID) {
            if node.childSession == nil {
                node.childSession = child
            } else if node.childSession != child {
                // A child session key is a navigation target; never replace a
                // previously admitted exact reference with a conflicting one.
                node.isClipped = true
            }
        }

        preserveFirst(event.goal, in: &node.goal, clipped: &node.isClipped)
        preserveFirst(event.model, in: &node.model, clipped: &node.isClipped)
        preserveFirst(event.taskCount, in: &node.taskCount, clipped: &node.isClipped)
        preserveFirst(event.taskIndex, in: &node.taskIndex, clipped: &node.isClipped)
        preserveFirst(event.reportedDepth, in: &node.reportedDepth, clipped: &node.isClipped)
        if let toolCount = event.toolCount {
            node.toolCount = max(node.toolCount ?? 0, toolCount)
        }
        if let toolsets = event.toolsets {
            node.toolsets = boundedUnion(node.toolsets, toolsets,
                                         maximum: SubagentEventLimits.maximumToolsets,
                                         clipped: &node.isClipped)
        }

        let postTerminalProgress = node.status.isTerminal && event.kind != .complete
        if !postTerminalProgress,
           event.text != nil || event.toolName != nil || event.toolPreview != nil
                || event.kind == .start || event.kind == .complete {
            node.latestActivity = SubagentLatestActivity(
                kind: event.kind, text: event.text, toolName: event.toolName,
                toolPreview: event.toolPreview
            )
        }
        if !postTerminalProgress, let summary = event.summary {
            node.summary = summary
        } else if event.kind == .complete, let summary = event.summary {
            // A later sequenced terminal replay may fill in a summary but can
            // never change the terminal outcome itself.
            node.summary = summary
        }

        mergeStatus(event, into: &node)
        merge(event.tokenUsage, into: &node.tokenUsage)
        merge(event.cost, into: &node.cost)
        if let filesRead = event.filesRead {
            node.filesRead = boundedUnion(node.filesRead, filesRead,
                                          maximum: SubagentEventLimits.maximumFilesPerKind,
                                          clipped: &node.isClipped)
        }
        if let filesWritten = event.filesWritten {
            node.filesWritten = boundedUnion(node.filesWritten, filesWritten,
                                             maximum: SubagentEventLimits.maximumFilesPerKind,
                                             clipped: &node.isClipped)
        }
        if let tail = event.outputTail {
            // `output_tail` is an ordered terminal rollup. A valid newer
            // payload replaces only this field; an absent/malformed tail never
            // clears the prior one.
            node.outputTail = Array(tail.prefix(SubagentEventLimits.maximumTailEntries))
        }
    }

    private func mergeStatus(_ event: SubagentGatewayEvent, into node: inout Node) {
        guard !node.status.isTerminal else { return }
        switch event.status {
        case .value(let status) where event.kind != .complete || status.isTerminal:
            node.status = status
        case .absent where event.kind == .start:
            node.status = .running
        case .absent where event.kind == .complete:
            node.status = .completed
        case .malformed where event.kind == .complete,
             .value where event.kind == .complete:
            // The decoder normally rejects active statuses on a complete
            // frame, but retain the same fail-closed behavior if a future
            // caller constructs one directly.
            node.status = .failed
        case .absent, .malformed, .value:
            break
        }
    }

    private func preserveFirst<T: Equatable>(_ incoming: T?, in existing: inout T?,
                                             clipped: inout Bool) {
        guard let incoming else { return }
        if existing == nil {
            existing = incoming
        } else if existing != incoming {
            clipped = true
        }
    }

    private func merge(_ update: SubagentTokenUsageUpdate, into usage: inout SubagentTokenUsage) {
        usage = SubagentTokenUsage(
            inputTokens: max(usage.inputTokens, update.inputTokens ?? 0),
            outputTokens: max(usage.outputTokens, update.outputTokens ?? 0),
            reasoningTokens: max(usage.reasoningTokens, update.reasoningTokens ?? 0),
            apiCalls: max(usage.apiCalls, update.apiCalls ?? 0)
        )
    }

    private func merge(_ update: SubagentCostUpdate, into cost: inout SubagentCostMetrics) {
        cost = SubagentCostMetrics(
            durationSeconds: maxOptional(cost.durationSeconds, update.durationSeconds),
            costUSD: maxOptional(cost.costUSD, update.costUSD)
        )
    }

    private func maxOptional(_ existing: Double?, _ incoming: Double?) -> Double? {
        switch (existing, incoming) {
        case let (existing?, incoming?): return max(existing, incoming)
        case let (existing?, nil): return existing
        case let (nil, incoming?): return incoming
        case (nil, nil): return nil
        }
    }

    private func boundedUnion<T: Hashable>(_ existing: [T], _ incoming: [T], maximum: Int,
                                           clipped: inout Bool) -> [T] {
        guard maximum > 0 else {
            clipped = clipped || !existing.isEmpty || !incoming.isEmpty
            return []
        }
        var result: [T] = []
        var seen = Set<T>()
        result.reserveCapacity(min(maximum, existing.count + incoming.count))
        for value in existing + incoming where seen.insert(value).inserted {
            guard result.count < maximum else {
                clipped = true
                continue
            }
            result.append(value)
        }
        return result
    }

    private func project(_ scopedNodes: [Node]) -> [SubagentNodeSummary] {
        guard !scopedNodes.isEmpty else { return [] }
        let byKey = Dictionary(uniqueKeysWithValues: scopedNodes.map { ($0.key, $0) })
        let orderedKeys = scopedNodes.map(\.key).sorted { lhs, rhs in
            nodePrecedes(byKey[lhs]!, byKey[rhs]!)
        }

        // A parent graph has one outgoing edge per child. Break precisely one
        // deterministic edge in every cycle before resolving depth, so a
        // hostile A↔B or longer loop cannot recurse or duplicate nodes.
        var brokenEdges = Set<SubagentNodeKey>()
        for start in orderedKeys {
            var positions: [SubagentNodeKey: Int] = [:]
            var cursor = start
            while !brokenEdges.contains(cursor),
                  let node = byKey[cursor], let parentID = node.parentSubagentID,
                  let parent = SubagentNodeKey(gatewayID: cursor.gatewayID,
                                                parentRuntimeSessionID: cursor.parentRuntimeSessionID,
                                                subagentID: parentID),
                  byKey[parent] != nil {
                if positions[parent] != nil {
                    brokenEdges.insert(cursor)
                    break
                }
                positions[cursor] = positions.count
                cursor = parent
            }
        }

        var projections: [SubagentNodeKey: Projection] = [:]
        func resolve(_ key: SubagentNodeKey) -> Projection {
            if let cached = projections[key] { return cached }
            guard let node = byKey[key], let parentID = node.parentSubagentID else {
                let result = Projection(parent: nil, depth: 0, isOrphaned: false)
                projections[key] = result
                return result
            }
            guard !brokenEdges.contains(key),
                  let parent = SubagentNodeKey(gatewayID: key.gatewayID,
                                                parentRuntimeSessionID: key.parentRuntimeSessionID,
                                                subagentID: parentID),
                  byKey[parent] != nil
            else {
                let result = Projection(parent: nil, depth: 0, isOrphaned: true)
                projections[key] = result
                return result
            }
            let parentProjection = resolve(parent)
            guard parentProjection.depth < SubagentLiveStoreLimits.maximumHierarchyDepth else {
                let result = Projection(parent: nil, depth: 0, isOrphaned: true)
                projections[key] = result
                return result
            }
            let result = Projection(parent: parent, depth: parentProjection.depth + 1,
                                    isOrphaned: false)
            projections[key] = result
            return result
        }
        for key in orderedKeys { _ = resolve(key) }

        var children: [SubagentNodeKey: [SubagentNodeKey]] = [:]
        var roots: [SubagentNodeKey] = []
        for key in orderedKeys {
            if let parent = projections[key]?.parent {
                children[parent, default: []].append(key)
            } else {
                roots.append(key)
            }
        }
        roots.sort { nodePrecedes(byKey[$0]!, byKey[$1]!) }
        for key in Array(children.keys) {
            children[key]?.sort { nodePrecedes(byKey[$0]!, byKey[$1]!) }
        }

        var result: [SubagentNodeSummary] = []
        result.reserveCapacity(scopedNodes.count)
        func emit(_ key: SubagentNodeKey) {
            guard let node = byKey[key], let projection = projections[key] else { return }
            result.append(SubagentNodeSummary(
                key: node.key, parentKey: projection.parent,
                hierarchyDepth: projection.depth, isOrphaned: projection.isOrphaned,
                childSession: node.childSession, status: node.status, goal: node.goal,
                model: node.model, taskCount: node.taskCount, taskIndex: node.taskIndex,
                reportedDepth: node.reportedDepth, toolCount: node.toolCount,
                toolsets: node.toolsets, latestActivity: node.latestActivity,
                summary: node.summary, tokenUsage: node.tokenUsage, cost: node.cost,
                filesRead: node.filesRead, filesWritten: node.filesWritten,
                outputTail: node.outputTail, firstSeenOrder: node.firstSeenOrder,
                lastUpdatedOrder: node.lastUpdatedOrder, isClipped: node.isClipped
            ))
            for child in children[key] ?? [] { emit(child) }
        }
        for root in roots { emit(root) }
        return result
    }

    private func nodePrecedes(_ lhs: Node, _ rhs: Node) -> Bool {
        if lhs.firstSeenOrder != rhs.firstSeenOrder {
            return lhs.firstSeenOrder < rhs.firstSeenOrder
        }
        if lhs.key.gatewayID != rhs.key.gatewayID { return lhs.key.gatewayID < rhs.key.gatewayID }
        if lhs.key.parentRuntimeSessionID != rhs.key.parentRuntimeSessionID {
            return lhs.key.parentRuntimeSessionID < rhs.key.parentRuntimeSessionID
        }
        return lhs.key.subagentID < rhs.key.subagentID
    }
}
