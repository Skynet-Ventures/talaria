import Foundation

/// An exact parent-session source fence.  A short Hermes runtime sid is only
/// unique inside one gateway, so both values participate in every live
/// subagent lookup and teardown.
public struct SubagentSourceFence: Hashable, Sendable {
    public let gatewayID: String
    public let parentRuntimeSessionID: String

    public init?(gatewayID: String, parentRuntimeSessionID: String) {
        guard let gatewayID = SubagentEventCodec.identity(gatewayID),
              let parentRuntimeSessionID = SubagentEventCodec.identity(parentRuntimeSessionID)
        else { return nil }
        self.gatewayID = gatewayID
        self.parentRuntimeSessionID = parentRuntimeSessionID
    }
}

/// Stable identity for one delegated branch.  Names, goals, models, and task
/// indexes are deliberately absent: they are display data and may collide or
/// change while a run is live.
public struct SubagentNodeKey: Hashable, Sendable {
    public let gatewayID: String
    public let parentRuntimeSessionID: String
    public let subagentID: String

    public init?(gatewayID: String, parentRuntimeSessionID: String, subagentID: String) {
        guard let source = SubagentSourceFence(
            gatewayID: gatewayID, parentRuntimeSessionID: parentRuntimeSessionID
        ), let subagentID = SubagentEventCodec.identity(subagentID) else { return nil }
        self.gatewayID = source.gatewayID
        self.parentRuntimeSessionID = source.parentRuntimeSessionID
        self.subagentID = subagentID
    }

    public var source: SubagentSourceFence {
        // The initializer validates all stored scalars, so this cannot fail.
        SubagentSourceFence(gatewayID: gatewayID,
                            parentRuntimeSessionID: parentRuntimeSessionID)!
    }
}

/// A source-qualified reference to the delegated child's durable session.
/// It is intentionally not a `GatewaySessionRoute`: the parent wire field is
/// a child session key for a later `session.resume`, not the child's ephemeral
/// runtime sid.
public struct SubagentChildSessionReference: Hashable, Sendable {
    public let gatewayID: String
    public let parentRuntimeSessionID: String
    public let subagentID: String
    public let childSessionID: String

    public init?(key: SubagentNodeKey, childSessionID: String) {
        guard let childSessionID = SubagentEventCodec.identity(childSessionID) else { return nil }
        gatewayID = key.gatewayID
        parentRuntimeSessionID = key.parentRuntimeSessionID
        subagentID = key.subagentID
        self.childSessionID = childSessionID
    }
}

/// Monotone counters retained from the newest admitted completion evidence.
public struct SubagentTokenUsage: Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int
    public let apiCalls: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0,
                reasoningTokens: Int = 0, apiCalls: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.apiCalls = apiCalls
    }
}

/// Bounded scalar run-cost evidence.  A nil field means the gateway did not
/// relay that optional measurement; it does not mean a zero-cost run.
public struct SubagentCostMetrics: Sendable, Equatable {
    public let durationSeconds: Double?
    public let costUSD: Double?

    public init(durationSeconds: Double? = nil, costUSD: Double? = nil) {
        self.durationSeconds = durationSeconds
        self.costUSD = costUSD
    }
}

/// The latest non-terminal progress detail for a branch.  This remains inert
/// evidence until a future screen chooses how to present it.
public struct SubagentLatestActivity: Sendable, Equatable {
    public let kind: SubagentEventKind
    public let text: String?
    public let toolName: String?
    public let toolPreview: String?

    public init(kind: SubagentEventKind, text: String? = nil,
                toolName: String? = nil, toolPreview: String? = nil) {
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.toolPreview = toolPreview
    }
}

/// An immutable branch projection.  `parentKey` and `hierarchyDepth` are
/// derived only from exact IDs in the current bounded snapshot; a missing,
/// cyclic, or over-depth parent leaves the node as an orphan rather than
/// guessing from a goal or label.
public struct SubagentNodeSummary: Sendable, Equatable, Identifiable {
    public let key: SubagentNodeKey
    public var id: SubagentNodeKey { key }
    public let parentKey: SubagentNodeKey?
    public let hierarchyDepth: Int
    public let isOrphaned: Bool
    public let childSession: SubagentChildSessionReference?
    public let status: SubagentStatus
    public let goal: String?
    public let model: String?
    public let taskCount: Int?
    public let taskIndex: Int?
    /// Reported by Hermes for diagnostics only; it never drives attachment.
    public let reportedDepth: Int?
    public let toolCount: Int?
    public let toolsets: [String]
    public let latestActivity: SubagentLatestActivity?
    public let summary: String?
    public let tokenUsage: SubagentTokenUsage
    public let cost: SubagentCostMetrics
    public let filesRead: [String]
    public let filesWritten: [String]
    public let outputTail: [SubagentOutputTailEntry]
    public let firstSeenOrder: UInt64
    public let lastUpdatedOrder: UInt64
    public let isClipped: Bool

    public init(key: SubagentNodeKey, parentKey: SubagentNodeKey? = nil,
                hierarchyDepth: Int = 0, isOrphaned: Bool = false,
                childSession: SubagentChildSessionReference? = nil,
                status: SubagentStatus = .running, goal: String? = nil,
                model: String? = nil, taskCount: Int? = nil, taskIndex: Int? = nil,
                reportedDepth: Int? = nil, toolCount: Int? = nil,
                toolsets: [String] = [], latestActivity: SubagentLatestActivity? = nil,
                summary: String? = nil, tokenUsage: SubagentTokenUsage = .init(),
                cost: SubagentCostMetrics = .init(), filesRead: [String] = [],
                filesWritten: [String] = [], outputTail: [SubagentOutputTailEntry] = [],
                firstSeenOrder: UInt64 = 0, lastUpdatedOrder: UInt64 = 0,
                isClipped: Bool = false) {
        self.key = key
        self.parentKey = parentKey
        self.hierarchyDepth = hierarchyDepth
        self.isOrphaned = isOrphaned
        self.childSession = childSession
        self.status = status
        self.goal = goal
        self.model = model
        self.taskCount = taskCount
        self.taskIndex = taskIndex
        self.reportedDepth = reportedDepth
        self.toolCount = toolCount
        self.toolsets = toolsets
        self.latestActivity = latestActivity
        self.summary = summary
        self.tokenUsage = tokenUsage
        self.cost = cost
        self.filesRead = filesRead
        self.filesWritten = filesWritten
        self.outputTail = outputTail
        self.firstSeenOrder = firstSeenOrder
        self.lastUpdatedOrder = lastUpdatedOrder
        self.isClipped = isClipped
    }
}

/// A value-only, UI-independent view of the bounded live ledger.  This is not
/// a reconnect snapshot: Hermes has no `subagent.list`/snapshot contract for
/// this data, so a new runtime session starts a new foreground ledger.
public struct SubagentLiveSnapshot: Sendable, Equatable {
    /// `nil` represents the store-wide view; a value is one exact source.
    public let source: SubagentSourceFence?
    /// Stable depth-first hierarchy order.  Siblings retain first-admitted
    /// order, with exact keys only as a deterministic final tiebreaker.
    public let nodes: [SubagentNodeSummary]
    public let isTruncated: Bool
    public let droppedNodeCount: Int

    public init(source: SubagentSourceFence? = nil, nodes: [SubagentNodeSummary] = [],
                isTruncated: Bool = false, droppedNodeCount: Int = 0) {
        self.source = source
        self.nodes = nodes
        self.isTruncated = isTruncated
        self.droppedNodeCount = droppedNodeCount
    }
}
