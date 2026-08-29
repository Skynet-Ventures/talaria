import Foundation

// MARK: - Bounded session-lineage projection

/// One visible row in the session tree. The projection deliberately keeps a
/// copy of the source-compatible `SessionSummary` rather than retaining a
/// reference to mutable UI state; callers can render it directly or use the
/// ids to look up richer preview/runtime data.
public struct SessionLineageEntry: Identifiable, Equatable, Sendable {
    public var summary: SessionSummary
    /// The admitted parent row's current visible id. A raw parent id is never
    /// exposed here when it only matched an alias (for example a compressed
    /// lineage root).
    public var parentID: String?
    /// Current visible ids of children, in deterministic sibling order.
    public var childrenIDs: [String]
    /// Root = 0. Rows that exceed the bounded depth are admitted as top-level
    /// orphans rather than recursively traversed further.
    public var logicalLevel: Int
    /// True when the row carried parent evidence but no safe admitted parent
    /// could be attached (missing parent, cycle break, or depth bound).
    public var isOrphan: Bool
    /// Top-level root's current visible id. This is useful for pinned groups.
    public var rootID: String
    /// Input ordinal, retained solely as a deterministic final tie-breaker.
    public var ordinal: Int
    /// Optional TUI-style stem for callers that want a compact branch cue.
    /// Roots have no stem; children receive `├─ ` or `└─ `.
    public var branchStem: String?

    public var id: String { summary.id }
    public var row: SessionSummary { summary }
    public var session: SessionSummary { summary }
    public var parentId: String? { parentID }
    public var rootId: String { rootID }
    public var level: Int { logicalLevel }
    public var orphan: Bool { isOrphan }
    public var isRoot: Bool { parentID == nil }
    public var hasChildren: Bool { !childrenIDs.isEmpty }

    init(summary: SessionSummary, parentID: String?, childrenIDs: [String],
         logicalLevel: Int, isOrphan: Bool, rootID: String, ordinal: Int,
         branchStem: String?) {
        self.summary = summary
        self.parentID = parentID
        self.childrenIDs = childrenIDs
        self.logicalLevel = logicalLevel
        self.isOrphan = isOrphan
        self.rootID = rootID
        self.ordinal = ordinal
        self.branchStem = branchStem
    }
}

public typealias SessionHierarchyEntry = SessionLineageEntry

public extension SessionSummary {
    /// Lossless metadata bridge used by callers that keep the wire model until
    /// the presentation boundary. `when` remains caller-owned because its
    /// localization/time-zone policy belongs to the UI layer.
    init(row: StoredSession, when: String = "") {
        self.init(id: row.id, title: row.title, when: when,
                  messageCount: row.messageCount, preview: row.preview,
                  startedAt: row.startedAt, lastActive: row.lastActive,
                  lineageRootID: row.lineageRootID,
                  parentSessionID: row.parentSessionID,
                  branchParentRootID: row.branchParentRootID)
    }
}

/// Pure, bounded hierarchy/search policy for `SessionsSheet` and other
/// session surfaces. It intentionally has no UI/framework dependencies.
public struct SessionLineageProjection: Equatable, Sendable {
    public static let maximumRows = 200
    public static let maximumEdges = 200
    /// A malformed peer can provide a cycle or a very deep chain. Keeping the
    /// cap below the row cap makes the worst-case walk explicit and cheap.
    public static let maximumDepth = 64

    public var entries: [SessionLineageEntry]

    public init(_ summaries: [SessionSummary], maxRows: Int = maximumRows,
                maxDepth: Int = maximumDepth) {
        let rowCap = min(max(maxRows, 0), Self.maximumRows)
        let depthCap = min(max(maxDepth, 0), Self.maximumDepth)

        struct Node {
            var summary: SessionSummary
            var ordinal: Int
            var candidates: [String]
            var parent: Int?
            var logicalLevel: Int
            var orphan: Bool
        }

        var nodes: [Node] = []
        nodes.reserveCapacity(min(summaries.count, rowCap))
        var admittedIDs = Set<String>()
        admittedIDs.reserveCapacity(min(summaries.count, rowCap))

        // Admit at most one row per visible id. This prevents duplicate-row
        // bombs from multiplying edges or making ForEach identity ambiguous,
        // while preserving the server's first-row order.
        for (ordinal, raw) in summaries.prefix(rowCap).enumerated() {
            let id = raw.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, admittedIDs.insert(id).inserted else { continue }
            var summary = raw
            if summary.id != id { summary.id = id }
            let normalized = summary.branchParentRootID
                .flatMap(Self.normalizedIdentifier)
            let exact = summary.parentSessionID.flatMap(Self.normalizedIdentifier)
            var candidates: [String] = []
            if let normalized { candidates.append(normalized) }
            if let exact, exact != normalized { candidates.append(exact) }
            nodes.append(Node(summary: summary, ordinal: ordinal, candidates: candidates,
                              parent: nil, logicalLevel: 0, orphan: false))
        }

        // Exact ids win over aliases. The first row wins an alias collision;
        // later duplicate roots remain visible but cannot steal a parent's
        // edge from the server's earlier row.
        var byID: [String: Int] = [:]
        var byRoot: [String: Int] = [:]
        byID.reserveCapacity(nodes.count)
        byRoot.reserveCapacity(nodes.count)
        for index in nodes.indices {
            byID[nodes[index].summary.id] = byID[nodes[index].summary.id] ?? index
            let root = Self.normalizedIdentifier(nodes[index].summary.lineageRootID)
                ?? nodes[index].summary.id
            byRoot[root] = byRoot[root] ?? index
        }

        enum VisitState { case unseen, visiting, resolved }
        var state = Array(repeating: VisitState.unseen, count: nodes.count)

        // Resolving a parent recursively lets a child listed before its parent
        // attach correctly. A back-edge breaks the edge at the later-resolved
        // node, leaving a safe top-level orphan and guaranteeing an acyclic
        // output graph.
        func resolve(_ index: Int) {
            switch state[index] {
            case .resolved: return
            case .visiting:
                return
            case .unseen: break
            }
            state[index] = .visiting
            let nodeCandidates = nodes[index].candidates
            var parentIndex: Int?
            for candidate in nodeCandidates {
                if let exact = byID[candidate] {
                    parentIndex = exact
                    break
                }
                if let aliased = byRoot[candidate] {
                    parentIndex = aliased
                    break
                }
            }

            guard let parentIndex, parentIndex != index else {
                nodes[index].orphan = !nodeCandidates.isEmpty
                nodes[index].logicalLevel = 0
                state[index] = .resolved
                return
            }

            if state[parentIndex] == .visiting {
                // This edge closes a cycle. Keep the row itself and expose it
                // at the top level; its candidate remains represented by the
                // orphan flag for diagnostics/UI copy.
                nodes[index].orphan = true
                nodes[index].logicalLevel = 0
                state[index] = .resolved
                return
            }

            resolve(parentIndex)
            let proposedLevel = nodes[parentIndex].logicalLevel + 1
            guard proposedLevel <= depthCap else {
                nodes[index].orphan = true
                nodes[index].logicalLevel = 0
                state[index] = .resolved
                return
            }

            nodes[index].parent = parentIndex
            nodes[index].logicalLevel = proposedLevel
            nodes[index].orphan = false
            state[index] = .resolved
        }

        for index in nodes.indices { resolve(index) }

        var childrenByParent = Array(repeating: [Int](), count: nodes.count)
        var edgeCount = 0
        for index in nodes.indices {
            guard let parent = nodes[index].parent,
                  edgeCount < Self.maximumEdges else {
                if nodes[index].parent != nil {
                    nodes[index].parent = nil
                    nodes[index].logicalLevel = 0
                    nodes[index].orphan = true
                }
                continue
            }
            childrenByParent[parent].append(index)
            edgeCount += 1
        }

        func activity(_ node: Node) -> Double {
            // Hermes' row recency is last-active first, with started-at as
            // the compatibility fallback when activity is absent. Do not let
            // a newer creation stamp override explicit activity evidence.
            node.summary.lastActive ?? node.summary.startedAt ?? 0
        }
        func isBefore(_ left: Int, _ right: Int) -> Bool {
            let leftActivity = activity(nodes[left])
            let rightActivity = activity(nodes[right])
            if leftActivity != rightActivity { return leftActivity > rightActivity }
            let leftStarted = nodes[left].summary.startedAt ?? 0
            let rightStarted = nodes[right].summary.startedAt ?? 0
            if leftStarted != rightStarted { return leftStarted > rightStarted }
            if nodes[left].ordinal != nodes[right].ordinal {
                return nodes[left].ordinal < nodes[right].ordinal
            }
            return nodes[left].summary.id < nodes[right].summary.id
        }
        for index in nodes.indices {
            childrenByParent[index].sort(by: isBefore)
        }
        var childOffsets: [Int: Int] = [:]
        childOffsets.reserveCapacity(edgeCount)
        for siblings in childrenByParent {
            for (offset, child) in siblings.enumerated() {
                childOffsets[child] = offset
            }
        }

        var orderedIndices: [Int] = []
        orderedIndices.reserveCapacity(nodes.count)
        var seen = Set<Int>()

        func emit(_ index: Int, rootID: String, stem: String?, depth: Int) {
            guard seen.insert(index).inserted else { return }
            orderedIndices.append(index)
            // The graph is already depth-bounded and cycle-free. The guard is
            // retained as a second line of defence if this code is changed.
            guard depth <= depthCap else { return }
            for (offset, child) in childrenByParent[index].enumerated() {
                let childStem = offset == childrenByParent[index].count - 1 ? "└─ " : "├─ "
                emit(child, rootID: rootID, stem: childStem, depth: depth + 1)
            }
        }

        for index in nodes.indices where nodes[index].parent == nil {
            emit(index, rootID: nodes[index].summary.id, stem: nil, depth: 0)
        }
        // Every admitted row is emitted exactly once even if a future change
        // introduces an impossible disconnected/cyclic edge.
        for index in nodes.indices where !seen.contains(index) {
            emit(index, rootID: nodes[index].summary.id, stem: nil, depth: 0)
        }

        var entryByIndex: [Int: SessionLineageEntry] = [:]
        entryByIndex.reserveCapacity(orderedIndices.count)
        for index in orderedIndices {
            let node = nodes[index]
            let childIDs = childrenByParent[index].map { nodes[$0].summary.id }
            let rootID: String
            if let parent = node.parent, let parentEntry = entryByIndex[parent] {
                rootID = parentEntry.rootID
            } else {
                rootID = node.summary.id
            }
            let stem: String?
            if let parent = node.parent {
                let siblings = childrenByParent[parent]
                let offset = childOffsets[index] ?? 0
                stem = offset == siblings.count - 1 ? "└─ " : "├─ "
            } else {
                stem = nil
            }
            entryByIndex[index] = SessionLineageEntry(
                summary: node.summary,
                parentID: node.parent.map { nodes[$0].summary.id },
                childrenIDs: childIDs,
                logicalLevel: node.parent == nil ? 0 : node.logicalLevel,
                isOrphan: node.orphan,
                rootID: rootID,
                ordinal: node.ordinal,
                branchStem: stem)
        }
        entries = orderedIndices.compactMap { entryByIndex[$0] }
    }

    public init(_ rows: [StoredSession], when: String = "",
                maxRows: Int = maximumRows, maxDepth: Int = maximumDepth) {
        self.init(rows.map { SessionSummary(row: $0, when: when) },
                  maxRows: maxRows, maxDepth: maxDepth)
    }

    /// Convenience factory for call sites that prefer a verb over an
    /// initializer.
    public static func project(_ summaries: [SessionSummary], maxRows: Int = maximumRows,
                               maxDepth: Int = maximumDepth) -> SessionLineageProjection {
        SessionLineageProjection(summaries, maxRows: maxRows, maxDepth: maxDepth)
    }

    public static func project(_ rows: [StoredSession], when: String = "",
                               maxRows: Int = maximumRows,
                               maxDepth: Int = maximumDepth) -> SessionLineageProjection {
        SessionLineageProjection(rows, when: when, maxRows: maxRows, maxDepth: maxDepth)
    }

    public var rows: [SessionLineageEntry] { entries }
    public var flattened: [SessionLineageEntry] { entries }
    public var roots: [SessionLineageEntry] { entries.filter(\.isRoot) }

    /// Return the ancestor chain for a row, ordered root → immediate parent.
    public func searchAncestors(for id: String) -> [SessionLineageEntry] {
        guard let target = entries.first(where: { $0.id == id }) else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var result: [SessionLineageEntry] = []
        var cursor = target.parentID
        var seen = Set<String>()
        while let parentID = cursor, seen.insert(parentID).inserted,
              let parent = byID[parentID] {
            result.append(parent)
            cursor = parent.parentID
        }
        return result.reversed()
    }

    public func ancestorIDs(for id: String) -> [String] {
        searchAncestors(for: id).map(\.id)
    }

    /// Search narrows rows but retains every admitted ancestor needed to
    /// explain a matching branch. The projection's server-root and sibling
    /// order are never re-ranked by the query.
    public func search(_ query: String) -> [SessionLineageEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return entries }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var included = Set<String>()
        for entry in entries where Self.matches(entry.summary, needle: needle) {
            included.insert(entry.id)
            var cursor = entry.parentID
            var depth = 0
            while let parentID = cursor, depth < Self.maximumDepth,
                  included.insert(parentID).inserted,
                  let parent = byID[parentID] {
                cursor = parent.parentID
                depth += 1
            }
        }
        return entries.filter { included.contains($0.id) }
    }

    public func matching(_ query: String) -> [SessionLineageEntry] { search(query) }

    /// A pinned id may be the current row id or a stale compression root id.
    /// The selected group contains the root and every admitted descendant.
    public func pinnedRootGroup(for pinnedID: String) -> [SessionLineageEntry] {
        let needle = Self.normalizedIdentifier(pinnedID)
        guard let needle,
              let selected = entries.first(where: {
                  $0.id == needle || $0.summary.lineageRootID == needle
              }) else { return [] }
        return entries.filter { $0.rootID == selected.rootID }
    }

    public func pinnedRootGroup(_ pinnedID: String) -> [SessionLineageEntry] {
        pinnedRootGroup(for: pinnedID)
    }

    /// Resolve multiple pins into root groups, preserving the projection's
    /// server root order and emitting each admitted row at most once.
    public func pinnedRootGroups(_ pinnedIDs: [String]) -> [[SessionLineageEntry]] {
        let requested = Set(pinnedIDs.compactMap(Self.normalizedIdentifier))
        guard !requested.isEmpty else { return [] }
        let roots = Set(entries.compactMap { entry -> String? in
            guard requested.contains(entry.id)
                    || (entry.summary.lineageRootID.map(requested.contains) ?? false)
            else { return nil }
            return entry.rootID
        })
        // Bucket once so a page containing many roots remains O(n), rather
        // than filtering the complete entry list once per selected root.
        var grouped: [String: [SessionLineageEntry]] = [:]
        grouped.reserveCapacity(roots.count)
        for entry in entries where roots.contains(entry.rootID) {
            grouped[entry.rootID, default: []].append(entry)
        }
        return self.roots.compactMap { grouped[$0.rootID] }
    }

    private static func normalizedIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func matches(_ summary: SessionSummary, needle: String) -> Bool {
        let values = [summary.id, summary.title, summary.when, summary.preview ?? "",
                      summary.lineageRootID ?? "", summary.parentSessionID ?? "",
                      summary.branchParentRootID ?? ""]
        return values.contains { $0.lowercased().contains(needle) }
    }
}

public typealias SessionHierarchy = SessionLineageProjection

/// Namespace-style facade for callers that do not need to retain a
/// projection value. All operations are pure and use the same bounds/order.
public enum SessionLineagePolicy {
    public static func project(_ summaries: [SessionSummary], maxRows: Int = 200,
                               maxDepth: Int = 64) -> SessionLineageProjection {
        SessionLineageProjection(summaries, maxRows: maxRows, maxDepth: maxDepth)
    }

    public static func flatten(_ summaries: [SessionSummary], maxRows: Int = 200,
                               maxDepth: Int = 64) -> [SessionLineageEntry] {
        project(summaries, maxRows: maxRows, maxDepth: maxDepth).entries
    }

    public static func search(_ query: String, in summaries: [SessionSummary],
                              maxRows: Int = 200, maxDepth: Int = 64)
        -> [SessionLineageEntry] {
        project(summaries, maxRows: maxRows, maxDepth: maxDepth).search(query)
    }

    public static func searchAncestors(for id: String, in summaries: [SessionSummary],
                                       maxRows: Int = 200, maxDepth: Int = 64)
        -> [SessionLineageEntry] {
        project(summaries, maxRows: maxRows, maxDepth: maxDepth).searchAncestors(for: id)
    }

    public static func pinnedRootGroup(for pinnedID: String,
                                       in summaries: [SessionSummary],
                                       maxRows: Int = 200, maxDepth: Int = 64)
        -> [SessionLineageEntry] {
        project(summaries, maxRows: maxRows, maxDepth: maxDepth)
            .pinnedRootGroup(for: pinnedID)
    }

    public static func pinnedRootGroups(_ pinnedIDs: [String],
                                        in summaries: [SessionSummary],
                                        maxRows: Int = 200, maxDepth: Int = 64)
        -> [[SessionLineageEntry]] {
        project(summaries, maxRows: maxRows, maxDepth: maxDepth)
            .pinnedRootGroups(pinnedIDs)
    }
}
