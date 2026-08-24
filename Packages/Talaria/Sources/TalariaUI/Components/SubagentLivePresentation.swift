import SwiftUI
import TalariaKit
import TalariaTheme

/// Mobile presentation bounds are intentionally tighter than the live
/// reducer's evidence bounds. The sheet stays useful on a phone while always
/// disclosing when retained evidence is not currently visible.
public enum SubagentLivePresentationPolicy {
    public static let maximumPresentedNodes = 64
    public static let maximumPresentedFiles = 6
    public static let maximumPresentedTailEntries = 4
    public static let minimumInteractiveDimension: CGFloat = 44

    public struct Summary: Sendable, Equatable {
        public let source: SubagentSourceFence
        public let nodes: [SubagentNodeSummary]
        public let totalCount: Int
        public let activeCount: Int
        public let failedCount: Int
        public let hiddenNodeCount: Int
        public let droppedNodeCount: Int
        public let isTruncated: Bool

        public init(source: SubagentSourceFence, nodes: [SubagentNodeSummary],
                    totalCount: Int, activeCount: Int, failedCount: Int,
                    hiddenNodeCount: Int, droppedNodeCount: Int,
                    isTruncated: Bool) {
            self.source = source
            self.nodes = nodes
            self.totalCount = totalCount
            self.activeCount = activeCount
            self.failedCount = failedCount
            self.hiddenNodeCount = hiddenNodeCount
            self.droppedNodeCount = droppedNodeCount
            self.isTruncated = isTruncated
        }
    }

    public struct FileEvidence: Sendable, Equatable, Identifiable {
        public enum Access: String, Sendable { case read, written }

        public let access: Access
        public let path: String
        public var id: String { "\(access.rawValue):\(path)" }

        public init(access: Access, path: String) {
            self.access = access
            self.path = path
        }
    }

    public static func make(snapshot: SubagentLiveSnapshot) -> Summary? {
        guard let source = snapshot.source, !snapshot.nodes.isEmpty else { return nil }
        let visible = Array(snapshot.nodes.prefix(maximumPresentedNodes))
        let hidden = max(0, snapshot.nodes.count - visible.count)
        return Summary(
            source: source,
            nodes: visible,
            totalCount: snapshot.nodes.count,
            activeCount: snapshot.nodes.filter { !$0.status.isTerminal }.count,
            failedCount: snapshot.nodes.filter { isFailed($0.status) }.count,
            hiddenNodeCount: hidden,
            droppedNodeCount: snapshot.droppedNodeCount,
            isTruncated: snapshot.isTruncated || hidden > 0
        )
    }

    public static func isFailed(_ status: SubagentStatus) -> Bool {
        switch status {
        case .failed, .error, .timeout, .interrupted, .cancelled, .stopped:
            return true
        case .queued, .running, .completed:
            return false
        }
    }

    public static func files(for node: SubagentNodeSummary) -> [FileEvidence] {
        let all = node.filesRead.map { FileEvidence(access: .read, path: $0) }
            + node.filesWritten.map { FileEvidence(access: .written, path: $0) }
        return Array(all.prefix(maximumPresentedFiles))
    }

    public static func hiddenFileCount(for node: SubagentNodeSummary) -> Int {
        max(0, node.filesRead.count + node.filesWritten.count - maximumPresentedFiles)
    }

    public static func outputTail(for node: SubagentNodeSummary)
        -> [SubagentOutputTailEntry] {
        Array(node.outputTail.suffix(maximumPresentedTailEntries))
    }

    public static func hiddenTailCount(for node: SubagentNodeSummary) -> Int {
        max(0, node.outputTail.count - maximumPresentedTailEntries)
    }

    /// A child-session label is not navigation authority. It becomes a target
    /// only while the exact node/source is still the current bot's gateway and
    /// runtime session, and that profile's source-qualified session list has
    /// independently proved the durable key.
    public static func provenChildStoredSessionID(
        node: SubagentNodeSummary,
        source: SubagentSourceFence,
        currentGatewayID: String?,
        currentRuntimeSessionID: String?,
        availableStoredSessionIDs: Set<String>
    ) -> String? {
        guard node.key.source == source,
              currentGatewayID == source.gatewayID,
              currentRuntimeSessionID == source.parentRuntimeSessionID,
              let child = node.childSession,
              child.gatewayID == node.key.gatewayID,
              child.parentRuntimeSessionID == node.key.parentRuntimeSessionID,
              child.subagentID == node.key.subagentID,
              availableStoredSessionIDs.contains(child.childSessionID)
        else { return nil }
        return child.childSessionID
    }
}

struct SubagentLiveStatusSurface: View {
    let presentation: SubagentLivePresentationPolicy.Summary
    let theme: ThemePack
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: presentation.activeCount > 0
                      ? "point.3.connected.trianglepath.dotted"
                      : "checkmark.circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(presentation.failedCount > 0 ? theme.warn : theme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Agents")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.ink)
                    Text(compactSummary)
                        .font(.caption)
                        .foregroundStyle(theme.sub)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.faint)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: SubagentLivePresentationPolicy.minimumInteractiveDimension)
            .background(theme.panel)
            .overlay(alignment: .top) {
                Rectangle().fill(theme.line).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilitySummary))
        .accessibilityHint(Text("Shows live delegated agent details"))
        .accessibilityIdentifier("subagent-live-status")
    }

    private var compactSummary: String {
        var parts = ["\(presentation.totalCount) total"]
        if presentation.activeCount > 0 { parts.append("\(presentation.activeCount) active") }
        if presentation.failedCount > 0 { parts.append("\(presentation.failedCount) failed") }
        if presentation.isTruncated { parts.append("limited view") }
        return parts.joined(separator: " · ")
    }

    private var accessibilitySummary: String {
        "Agents, \(presentation.totalCount) total, \(presentation.activeCount) active, "
            + "\(presentation.failedCount) failed"
    }
}

struct SubagentLiveSheet: View {
    let presentation: SubagentLivePresentationPolicy.Summary
    let theme: ThemePack
    let canOpenChild: (SubagentNodeSummary) -> Bool
    let openChild: (SubagentNodeSummary) -> Void
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    summary
                    if presentation.isTruncated { truncationNotice }
                    ForEach(presentation.nodes) { node in
                        SubagentLiveNodeCard(
                            node: node,
                            theme: theme,
                            canOpenChild: canOpenChild(node),
                            openChild: { openChild(node) }
                        )
                    }
                }
                .padding(16)
            }
            .background(theme.bg)
            .navigationTitle("Delegated agents")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss)
                        .frame(minWidth: SubagentLivePresentationPolicy.minimumInteractiveDimension,
                               minHeight: SubagentLivePresentationPolicy.minimumInteractiveDimension)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var summary: some View {
        HStack(spacing: 16) {
            metric(presentation.totalCount, "total", theme.ink)
            metric(presentation.activeCount, "active", theme.accent)
            metric(presentation.failedCount, "failed", theme.danger)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func metric(_ value: Int, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted())
                .font(.title3.weight(.bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.sub)
        }
    }

    private var truncationNotice: some View {
        let omitted = presentation.hiddenNodeCount + presentation.droppedNodeCount
        return Label {
            Text(omitted > 0
                 ? "Limited live view — \(omitted) agent entr\(omitted == 1 ? "y" : "ies") omitted."
                 : "Some agent details were shortened to safe display limits.")
                .font(.caption)
        } icon: {
            Image(systemName: "ellipsis.circle")
        }
        .foregroundStyle(theme.warn)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.warn.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("subagent-live-truncation")
    }
}

private struct SubagentLiveNodeCard: View {
    let node: SubagentNodeSummary
    let theme: ThemePack
    let canOpenChild: Bool
    let openChild: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let goal = node.goal, !goal.isEmpty {
                Text(goal)
                    .font(.body.weight(.medium))
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let activity = node.latestActivity { activityRow(activity) }
            metadata
            if let summary = node.summary, !summary.isEmpty {
                detailSection("Result", text: summary)
            }
            fileEvidence
            outputEvidence
            childSessionEvidence
            if node.isClipped {
                Label("Some details were shortened or conflicted with earlier evidence.",
                      systemImage: "ellipsis.circle")
                    .font(.caption)
                    .foregroundStyle(theme.warn)
            }
        }
        .padding(13)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: theme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: theme.cardRadius)
                .stroke(theme.line, lineWidth: 1)
        }
        .padding(.leading, CGFloat(min(node.hierarchyDepth, 4)) * 10)
        .accessibilityIdentifier("subagent-node-\(node.key.subagentID)")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
            Text(node.goal?.isEmpty == false ? "Agent" : "Subagent")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.ink)
            if node.isOrphaned {
                Text("unattached")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.warn)
            }
            Spacer(minLength: 4)
            Text(node.status.rawValue.capitalized)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func activityRow(_ activity: SubagentLatestActivity) -> some View {
        let label = activity.toolName ?? activity.text ?? activity.toolPreview
            ?? activity.kind.rawValue.capitalized
        Label {
            Text(label)
                .font(activity.kind == .tool ? .caption.monospaced() : .caption)
                .foregroundStyle(theme.sub)
                .lineLimit(3)
        } icon: {
            Image(systemName: activity.kind == .tool ? "wrench.and.screwdriver" : "ellipsis.message")
                .foregroundStyle(theme.accent)
        }
        .accessibilityLabel(Text("Latest activity, \(label)"))
    }

    private var metadata: some View {
        let values = metadataValues
        return Group {
            if !values.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { metadataContent(values) }
                    VStack(alignment: .leading, spacing: 5) { metadataContent(values) }
                }
            }
        }
    }

    @ViewBuilder
    private func metadataContent(_ values: [String]) -> some View {
        ForEach(values, id: \.self) { value in
            Text(value)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(theme.sub)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(theme.inset, in: Capsule())
        }
    }

    private var metadataValues: [String] {
        var values: [String] = []
        if let model = node.model, !model.isEmpty { values.append(model) }
        if let index = node.taskIndex, let count = node.taskCount, count > 0 {
            values.append("task \(min(index + 1, count))/\(count)")
        }
        if let tools = node.toolCount, tools > 0 { values.append("\(tools) tools") }
        if let duration = node.cost.durationSeconds { values.append(formatDuration(duration)) }
        let tokens = node.tokenUsage.inputTokens + node.tokenUsage.outputTokens
            + node.tokenUsage.reasoningTokens
        if tokens > 0 { values.append("\(tokens.formatted(.number.notation(.compactName))) tokens") }
        if node.tokenUsage.apiCalls > 0 { values.append("\(node.tokenUsage.apiCalls) calls") }
        if let cost = node.cost.costUSD { values.append(cost.formatted(.currency(code: "USD"))) }
        return values
    }

    @ViewBuilder
    private var fileEvidence: some View {
        let files = SubagentLivePresentationPolicy.files(for: node)
        let hidden = SubagentLivePresentationPolicy.hiddenFileCount(for: node)
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Files")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.sub)
                ForEach(files) { file in
                    Label(file.path, systemImage: file.access == .written
                          ? "pencil.line" : "doc.text.magnifyingglass")
                        .font(.caption.monospaced())
                        .foregroundStyle(theme.ink)
                        .lineLimit(2)
                }
                if hidden > 0 {
                    Text("\(hidden) more file entr\(hidden == 1 ? "y" : "ies") not shown")
                        .font(.caption2)
                        .foregroundStyle(theme.faint)
                }
            }
        }
    }

    @ViewBuilder
    private var outputEvidence: some View {
        let tail = SubagentLivePresentationPolicy.outputTail(for: node)
        let hidden = SubagentLivePresentationPolicy.hiddenTailCount(for: node)
        if !tail.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Output tail")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.sub)
                if hidden > 0 {
                    Text("Showing the latest \(tail.count) of \(node.outputTail.count) entries")
                        .font(.caption2)
                        .foregroundStyle(theme.faint)
                }
                ForEach(Array(tail.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.tool)
                            .font(.caption.monospaced().weight(.semibold))
                        if let preview = entry.preview, !preview.isEmpty {
                            Text(preview)
                                .font(.caption.monospaced())
                                .lineLimit(4)
                        }
                    }
                    .foregroundStyle(entry.isError ? theme.danger : theme.ink)
                }
            }
        }
    }

    @ViewBuilder
    private var childSessionEvidence: some View {
        if let child = node.childSession {
            if canOpenChild {
                Button(action: openChild) {
                    Label("Open agent session", systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: SubagentLivePresentationPolicy.minimumInteractiveDimension)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
                .accessibilityHint(Text("Opens the proven stored session for this agent"))
            } else {
                Label {
                    Text("Session \(child.childSessionID) is not proven in this bot's current session list.")
                        .font(.caption)
                        .foregroundStyle(theme.faint)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "link.badge.plus")
                        .foregroundStyle(theme.faint)
                }
                .accessibilityLabel(Text("Agent session is not currently available to open"))
            }
        }
    }

    private func detailSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.sub)
            Text(text)
                .font(.caption)
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusSymbol: String {
        switch node.status {
        case .queued, .running: "circle.dotted"
        case .completed: "checkmark.circle.fill"
        case .failed, .error, .timeout, .interrupted, .cancelled, .stopped:
            "exclamationmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch node.status {
        case .queued, .running: theme.accent
        case .completed: theme.ok
        case .failed, .error, .timeout, .interrupted, .cancelled, .stopped: theme.danger
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(seconds.formatted(.number.precision(.fractionLength(1))))s" }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds.rounded()) % 60
        return "\(minutes)m \(remainder)s"
    }
}
