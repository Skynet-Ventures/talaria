import Foundation

/// The identity of a local response-alternative shelf.
///
/// This is deliberately stricter than a profile id.  A shelf belongs to one
/// ChatState, one source user row, and one exact runtime/durable session.  It
/// is never encoded or sent to Hermes.
public struct AssistantResponseAlternativesBinding: Sendable, Equatable, Hashable {
    public var chatID: UUID
    public var sourceUserID: UUID
    public var storedSessionID: String
    public var runtimeSessionID: String
    public var gatewayID: String
    public var profile: String

    public init(chatID: UUID, sourceUserID: UUID, storedSessionID: String,
                runtimeSessionID: String, gatewayID: String, profile: String) {
        self.chatID = chatID
        self.sourceUserID = sourceUserID
        self.storedSessionID = storedSessionID
        self.runtimeSessionID = runtimeSessionID
        self.gatewayID = gatewayID
        self.profile = profile
    }
}

/// One complete assistant response run retained as a local snapshot.
/// `messages` contains assistant rows in their original order, including
/// reasoning, tools, cards, failures, and specialist evidence.
public struct AssistantResponseAlternativeRun: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var messages: [ChatMessage]
    /// Measured retained budgets after admission. These are hard upper
    /// bounds, not estimates copied from the source payload.
    public var visibleScalars: Int
    public var workItems: Int
    public var bytes: Int
    public var isClipped: Bool
    public var clippedMessages: Int
    public var clippedVisibleScalars: Int
    public var clippedWorkItems: Int
    public var clippedBytes: Int

    public init(id: UUID = UUID(), messages: [ChatMessage], visibleScalars: Int = 0,
                workItems: Int = 0, bytes: Int = 0, isClipped: Bool = false,
                clippedMessages: Int = 0, clippedVisibleScalars: Int = 0,
                clippedWorkItems: Int = 0, clippedBytes: Int = 0) {
        self.id = id
        self.messages = messages
        self.visibleScalars = visibleScalars
        self.workItems = workItems
        self.bytes = bytes
        self.isClipped = isClipped
        self.clippedMessages = clippedMessages
        self.clippedVisibleScalars = clippedVisibleScalars
        self.clippedWorkItems = clippedWorkItems
        self.clippedBytes = clippedBytes
    }
}

/// A source user row's ordered archived response runs.  The current
/// canonical response is intentionally not copied here: it is the implicit
/// newest response at position `alternatives.count`.
public struct AssistantResponseAlternativeGroup: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var binding: AssistantResponseAlternativesBinding
    /// Oldest to newest archived runs.  The current live run is the implicit
    /// final entry and is supplied by the current ChatState transcript.
    public var alternatives: [AssistantResponseAlternativeRun]
    public var isClipped: Bool

    public init(id: UUID = UUID(), binding: AssistantResponseAlternativesBinding,
                alternatives: [AssistantResponseAlternativeRun] = [],
                isClipped: Bool = false) {
        self.id = id
        self.binding = binding
        self.alternatives = alternatives
        self.isClipped = isClipped
    }
}

/// Presentation-only placement for one group's compact response navigator.
/// The control belongs after the final displayed bot row in that source
/// turn, never before the prompt or in a transcript-wide header.
public struct AssistantResponseAlternativeControlPlacement: Identifiable,
    Sendable, Equatable {
    public var id: UUID { groupID }
    public var groupID: UUID
    public var sourceUserID: UUID
    public var botMessageID: UUID

    public init(groupID: UUID, sourceUserID: UUID, botMessageID: UUID) {
        self.groupID = groupID
        self.sourceUserID = sourceUserID
        self.botMessageID = botMessageID
    }
}

/// Non-persistent, current-ChatState response-alternative state.
public struct AssistantResponseAlternatives: Sendable, Equatable {
    public var groups: [AssistantResponseAlternativeGroup]
    public var selectedGroupID: UUID?
    /// `nil` means the implicit newest/current response.  A value indexes an
    /// archived run.  Navigation therefore has an explicit terminal newest
    /// state and never wraps.
    public var selectedAlternativeIndex: Int?
    public var isClipped: Bool

    public init(groups: [AssistantResponseAlternativeGroup] = [],
                selectedGroupID: UUID? = nil, selectedAlternativeIndex: Int? = nil,
                isClipped: Bool = false) {
        self.groups = groups
        self.selectedGroupID = selectedGroupID
        self.selectedAlternativeIndex = selectedAlternativeIndex
        self.isClipped = isClipped
    }

    public var selectedGroup: AssistantResponseAlternativeGroup? {
        guard let selectedGroupID else { return nil }
        return groups.first { $0.id == selectedGroupID }
    }

    public var isShowingArchived: Bool {
        guard let selectedGroup, let selectedAlternativeIndex else { return false }
        return selectedAlternativeIndex >= 0
            && selectedAlternativeIndex < selectedGroup.alternatives.count
    }
}

/// Pure bounded policy for local response alternatives.
public enum AssistantResponseAlternativesPolicy {
    public static let maximumGroups = 8
    public static let maximumAlternativesPerGroup = 8
    public static let maximumMessagesPerRun = 256
    public static let maximumVisibleScalarsPerRun = 200_000
    public static let maximumWorkItemsPerRun = 16_384
    public static let maximumBytesPerRun = 1_000_000
    public static let maximumTextScalarsPerMessage = 32_768
    public static let maximumToolScalars = 8_192
    public static let clippedMarker = "\n… [response snapshot clipped]"

    /// Add one previously-current response to the exact source group. The
    /// operation is atomic at group/alternative boundaries: an exhausted
    /// group is marked clipped and left intact rather than evicting half of a
    /// response shelf. Group and run ids are stable once admitted.
    public static func record(
        _ messages: [ChatMessage], binding: AssistantResponseAlternativesBinding,
        state: AssistantResponseAlternatives = AssistantResponseAlternatives(),
        runID: UUID = UUID(), groupID: UUID? = nil
    ) -> AssistantResponseAlternatives {
        let assistantRun = messages.filter { $0.author == .bot }
        guard !assistantRun.isEmpty else { return state }
        let admitted = boundedRun(assistantRun, id: runID)
        var next = state
        guard let existingIndex = next.groups.firstIndex(where: {
            $0.binding == binding
        }) else {
            guard next.groups.count < maximumGroups else {
                next.isClipped = true
                return next
            }
            var group = AssistantResponseAlternativeGroup(
                id: groupID ?? UUID(), binding: binding)
            group.alternatives = [admitted]
            group.isClipped = admitted.isClipped
            next.groups.append(group)
            next.selectedGroupID = group.id
            next.selectedAlternativeIndex = nil
            next.isClipped = next.isClipped || admitted.isClipped
            return next
        }

        guard next.groups[existingIndex].alternatives.count < maximumAlternativesPerGroup else {
            next.groups[existingIndex].isClipped = true
            next.isClipped = true
            next.selectedGroupID = next.groups[existingIndex].id
            next.selectedAlternativeIndex = nil
            return next
        }
        next.groups[existingIndex].alternatives.append(admitted)
        next.groups[existingIndex].isClipped =
            next.groups[existingIndex].isClipped || admitted.isClipped
        next.selectedGroupID = next.groups[existingIndex].id
        next.selectedAlternativeIndex = nil
        next.isClipped = next.isClipped || admitted.isClipped
        return next
    }

    /// Return the exact group for a binding, if one exists.
    public static func group(
        for binding: AssistantResponseAlternativesBinding,
        in state: AssistantResponseAlternatives
    ) -> AssistantResponseAlternativeGroup? {
        state.groups.first { $0.binding == binding }
    }

    /// Rebind one source row after a destructive regenerate replaces its
    /// optimistic user identity. Every other binding dimension must match;
    /// a text/profile match is never enough. The existing group id and all
    /// archived runs remain untouched.
    public static func rebindSourceUserID(
        from oldSourceUserID: UUID, to newSourceUserID: UUID,
        matching binding: AssistantResponseAlternativesBinding,
        in state: AssistantResponseAlternatives
    ) -> AssistantResponseAlternatives {
        let candidates = state.groups.indices.filter { index in
            let groupBinding = state.groups[index].binding
            return groupBinding.sourceUserID == oldSourceUserID
                && groupBinding.chatID == binding.chatID
                && groupBinding.storedSessionID == binding.storedSessionID
                && groupBinding.runtimeSessionID == binding.runtimeSessionID
                && groupBinding.gatewayID == binding.gatewayID
                && groupBinding.profile == binding.profile
        }
        guard candidates.count == 1, let index = candidates.first else {
            return state
        }
        if oldSourceUserID != newSourceUserID,
           state.groups.contains(where: {
               $0.id != state.groups[index].id
                   && $0.binding.sourceUserID == newSourceUserID
           }) {
            // Never merge two exact source identities into one visible turn.
            // A duplicate optimistic id is an ambiguous receipt, not a
            // reason to let one shelf overwrite another.
            return state
        }
        var next = state
        next.groups[index].binding.sourceUserID = newSourceUserID
        return next
    }

    /// Remove groups whose source turns were dropped by an accepted
    /// destructive action. The source being regenerated is intentionally
    /// excluded by the caller so its shelf can migrate and append atomically.
    public static func pruning(
        sourceUserIDs: Set<UUID>, in state: AssistantResponseAlternatives
    ) -> AssistantResponseAlternatives {
        guard !sourceUserIDs.isEmpty else { return state }
        var next = state
        next.groups.removeAll { sourceUserIDs.contains($0.binding.sourceUserID) }
        if let selected = next.selectedGroupID,
           !next.groups.contains(where: { $0.id == selected }) {
            next.selectedGroupID = nil
            next.selectedAlternativeIndex = nil
        }
        return next
    }

    /// Select an archived run, or `nil` for the current/newest run. Invalid
    /// indexes fail closed and leave the prior state unchanged.
    public static func select(
        groupID: UUID, archivedIndex: Int?,
        in state: AssistantResponseAlternatives
    ) -> AssistantResponseAlternatives {
        guard let group = state.groups.first(where: { $0.id == groupID }) else {
            return state
        }
        if let archivedIndex,
           !(0..<group.alternatives.count).contains(archivedIndex) {
            return state
        }
        var next = state
        next.selectedGroupID = group.id
        next.selectedAlternativeIndex = archivedIndex
        return next
    }

    /// Move one step toward an older response. At newest, this selects the
    /// newest archived run; at the oldest archived run it stops.
    public static func previous(
        in state: AssistantResponseAlternatives
    ) -> AssistantResponseAlternatives {
        guard let group = state.selectedGroup, !group.alternatives.isEmpty else {
            return state
        }
        let nextIndex = state.selectedAlternativeIndex.map { $0 - 1 }
            ?? (group.alternatives.count - 1)
        guard nextIndex >= 0 else { return state }
        return select(groupID: group.id, archivedIndex: nextIndex, in: state)
    }

    /// Move one step toward the current/newest response. At newest it stops;
    /// moving from the newest archived run selects the current sentinel.
    public static func next(
        in state: AssistantResponseAlternatives
    ) -> AssistantResponseAlternatives {
        guard let group = state.selectedGroup, !group.alternatives.isEmpty else {
            return state
        }
        guard let current = state.selectedAlternativeIndex else { return state }
        if current + 1 < group.alternatives.count {
            return select(groupID: group.id, archivedIndex: current + 1, in: state)
        }
        return select(groupID: group.id, archivedIndex: nil, in: state)
    }

    /// Restore the implicit current/newest selection before a normal send.
    public static func resetSelection(
        in state: AssistantResponseAlternatives
    ) -> AssistantResponseAlternatives {
        var next = state
        next.selectedGroupID = nil
        next.selectedAlternativeIndex = nil
        return next
    }

    /// Localized-view data source. The current transcript remains canonical;
    /// only the selected bot segment is replaced by an archived value copy.
    public static func displayedMessages(
        current: [ChatMessage], state: AssistantResponseAlternatives,
        binding: AssistantResponseAlternativesBinding?
    ) -> [ChatMessage] {
        guard let group = state.selectedGroup,
              let archivedIndex = state.selectedAlternativeIndex,
              group.binding == binding,
              group.alternatives.indices.contains(archivedIndex),
              let sourceIndex = current.firstIndex(where: {
                  $0.id == group.binding.sourceUserID && $0.author == .user
              }) else { return current }
        let sourceEnd = current[(sourceIndex + 1)..<current.endIndex]
            .firstIndex(where: { $0.author == .user }) ?? current.endIndex
        let oldAssistantMessages = group.alternatives[archivedIndex].messages
        var displayed = Array(current[..<(sourceIndex + 1)])
        displayed.append(contentsOf: oldAssistantMessages)
        displayed.append(contentsOf: current[sourceEnd...])
        return displayed
    }

    /// Locate each valid group's navigator after the final displayed bot row
    /// in that source turn.  The selected archived group is projected first,
    /// so a run containing several assistant/tool-only rows still anchors to
    /// its last displayed bot row.  At most one placement is emitted per
    /// retained group; this policy never creates a global transcript header.
    public static func controlPlacements(
        current: [ChatMessage], state: AssistantResponseAlternatives,
        binding: AssistantResponseAlternativesBinding?
    ) -> [AssistantResponseAlternativeControlPlacement] {
        let projectionBinding = state.selectedGroup?.binding ?? binding
        let displayed = displayedMessages(current: current, state: state,
                                          binding: projectionBinding)
        return state.groups.compactMap { group in
            guard let sourceIndex = displayed.firstIndex(where: {
                $0.author == .user && $0.id == group.binding.sourceUserID
            }) else { return nil }
            let sourceEnd = displayed[(sourceIndex + 1)..<displayed.endIndex]
                .firstIndex(where: { $0.author == .user }) ?? displayed.endIndex
            guard let bot = displayed[(sourceIndex + 1)..<sourceEnd]
                .last(where: { $0.author == .bot }) else { return nil }
            return AssistantResponseAlternativeControlPlacement(
                groupID: group.id, sourceUserID: group.binding.sourceUserID,
                botMessageID: bot.id)
        }
    }

    /// Position text uses the newest/current sentinel as the final response.
    public static func responsePosition(
        in state: AssistantResponseAlternatives
    ) -> (current: Int, total: Int)? {
        guard let group = state.selectedGroup else { return nil }
        return responsePosition(group: group,
                                archivedIndex: state.selectedAlternativeIndex)
    }

    public static func responsePosition(
        groupID: UUID, in state: AssistantResponseAlternatives
    ) -> (current: Int, total: Int)? {
        guard let group = state.groups.first(where: { $0.id == groupID }) else {
            return nil
        }
        let archivedIndex = state.selectedGroupID == groupID
            ? state.selectedAlternativeIndex : nil
        return responsePosition(group: group, archivedIndex: archivedIndex)
    }

    private static func responsePosition(
        group: AssistantResponseAlternativeGroup, archivedIndex: Int?
    ) -> (current: Int, total: Int) {
        let current = (archivedIndex ?? group.alternatives.count) + 1
        return (current, group.alternatives.count + 1)
    }

    public static func isArchived(
        _ message: ChatMessage, in state: AssistantResponseAlternatives
    ) -> Bool {
        guard state.isShowingArchived,
              let group = state.selectedGroup,
              let index = state.selectedAlternativeIndex else { return false }
        return group.alternatives[index].messages.contains { $0.id == message.id }
    }

    /// Admission is deliberately value-preserving for the evidence-bearing
    /// model fields while bounding every large visible text field and tool
    /// collection before storage in the local shelf.
    public static func boundedRun(
        _ source: [ChatMessage], id: UUID = UUID()
    ) -> AssistantResponseAlternativeRun {
        let messageLimit = min(maximumMessagesPerRun, maximumWorkItemsPerRun)
        var clipped = source.count > messageLimit
        let clippedMessages = max(0, source.count - messageLimit)
        var clippedVisibleScalars = 0
        var clippedWorkItems = 0
        var admitted = source.prefix(messageLimit).map {
            boundedMessage($0, clipped: &clipped)
        }
        clippedWorkItems = source.prefix(messageLimit).reduce(0) {
            $0 + max(0, $1.toolCalls.count - 128)
        }

        // Reserve one work item for every admitted message before admitting
        // any tool call. This keeps the message projection stable while
        // guaranteeing that message + tool work can never cross the hard
        // cap at the boundary.
        var remainingToolWork = max(0, maximumWorkItemsPerRun - admitted.count)
        for index in admitted.indices {
            let allowedCalls = min(admitted[index].toolCalls.count, remainingToolWork)
            if allowedCalls < admitted[index].toolCalls.count {
                clippedWorkItems += admitted[index].toolCalls.count - allowedCalls
                clipped = true
                admitted[index].toolCalls = Array(
                    admitted[index].toolCalls.prefix(allowedCalls))
            }
            remainingToolWork -= admitted[index].toolCalls.count
        }

        // Consume the scalar budget in display order, including argument and
        // result text. This pass is bounded-prefix work even for hostile
        // multi-byte strings and leaves a truthful clipped marker.
        let preClipScalars = retainedScalarCount(admitted)
        if preClipScalars > maximumVisibleScalarsPerRun {
            clippedVisibleScalars = preClipScalars - maximumVisibleScalarsPerRun
            clipped = true
            // JSON and specialist evidence are complete-value fields.  They
            // cannot be prefix-clipped safely, so discard them atomically
            // before consuming the scalar prefix of ordinary text fields.
            for index in admitted.indices {
                dropOptionalEvidence(&admitted[index])
            }
        }
        var remainingScalars = maximumVisibleScalarsPerRun
        for index in admitted.indices {
            let before = remainingScalars
            clipVisibleScalars(&admitted[index], remaining: &remainingScalars,
                               clipped: &clipped)
            if before == remainingScalars, retainedScalarCount(admitted[index]) > 0 {
                clipped = true
            }
        }
        // UTF-8 bytes are a separate hard budget. Specialist evidence is
        // already admitted by its own codecs; when this shelf saturates, drop
        // only those optional evidence containers and compact visible strings
        // by a bounded UTF-8 prefix.
        var bytes = retainedByteCount(admitted)
        var clippedBytes = 0
        if bytes > maximumBytesPerRun {
            clipped = true
            clippedBytes = bytes - maximumBytesPerRun
            for index in admitted.indices {
                for callIndex in admitted[index].toolCalls.indices {
                    dropOptionalEvidence(&admitted[index].toolCalls[callIndex])
                }
            }
            var remainingBytes = maximumBytesPerRun
            for index in admitted.indices {
                clipVisibleBytes(&admitted[index], remaining: &remainingBytes,
                                 clipped: &clipped)
            }
            bytes = retainedByteCount(admitted)
            clippedBytes = max(clippedBytes, max(0, bytes - maximumBytesPerRun))
        }

        let visibleScalars = retainedScalarCount(admitted)
        let workItems = admitted.reduce(0) { $0 + 1 + $1.toolCalls.count }
        bytes = retainedByteCount(admitted)
        return AssistantResponseAlternativeRun(
            id: id, messages: admitted, visibleScalars: visibleScalars,
            workItems: workItems, bytes: bytes, isClipped: clipped,
            clippedMessages: clippedMessages,
            clippedVisibleScalars: clippedVisibleScalars,
            clippedWorkItems: clippedWorkItems,
            clippedBytes: clippedBytes)
    }

    private static func boundedMessage(_ source: ChatMessage,
                                       clipped: inout Bool) -> ChatMessage {
        var message = source
        let text = boundedText(message.text, maximum: maximumTextScalarsPerMessage)
        message.text = text.text
        clipped = clipped || text.truncated
        if let time = message.time {
            let bounded = boundedText(time, maximum: maximumToolScalars)
            message.time = bounded.text
            clipped = clipped || bounded.truncated
        }
        if let reasoning = message.reasoning {
            let bounded = boundedText(reasoning, maximum: maximumTextScalarsPerMessage)
            message.reasoning = bounded.text
            clipped = clipped || bounded.truncated
        }
        if var failure = message.failure {
            let bounded = boundedText(failure.message, maximum: maximumToolScalars)
            failure.message = bounded.text
            message.failure = failure
            clipped = clipped || bounded.truncated
        }
        message.card = boundedCard(message.card, clipped: &clipped)
        message.toolCalls = message.toolCalls.prefix(128).map { call in
            boundedToolCall(call, clipped: &clipped)
        }
        if source.toolCalls.count > message.toolCalls.count { clipped = true }
        return message
    }

    private static func boundedToolCall(_ source: ToolCall,
                                        clipped: inout Bool) -> ToolCall {
        var call = source
        func bound(_ value: String, maximum: Int) -> String {
            let result = boundedText(value, maximum: maximum)
            clipped = clipped || result.truncated
            return result.text
        }
        call.id = bound(call.id, maximum: 256)
        call.gatewayToolID = call.gatewayToolID.map { bound($0, maximum: 256) }
        call.name = bound(call.name, maximum: 160)
        call.context = bound(call.context, maximum: maximumToolScalars)
        call.summary = call.summary.map { bound($0, maximum: maximumToolScalars) }
        call.resultText = call.resultText.map { bound($0, maximum: maximumToolScalars) }
        call.diagnostic = call.diagnostic.map { bound($0, maximum: maximumToolScalars) }
        call.webSearchQuery = call.webSearchQuery.map { bound($0, maximum: maximumToolScalars) }
        call.arguments = boundedPayload(call.arguments, clipped: &clipped)
        call.result = boundedPayload(call.result, clipped: &clipped)
        return call
    }

    private static func boundedPayload(_ source: ToolPayload?, clipped: inout Bool)
        -> ToolPayload? {
        guard var payload = source else { return nil }
        if let text = payload.text {
            let bounded = boundedText(text, maximum: maximumToolScalars)
            payload.text = bounded.text
            payload.isTruncated = payload.isTruncated || bounded.truncated
            clipped = clipped || bounded.truncated
            // A clipped textual projection is not a safe complete JSON value.
            if bounded.truncated { payload.json = nil }
        }
        if let json = payload.json, !jsonFitsBudget(json) {
            payload.json = nil
            payload.isTruncated = true
            clipped = true
        }
        return payload
    }

    private static func jsonFitsBudget(_ value: JSONValue) -> Bool {
        var remaining = maximumToolScalars
        func visit(_ value: JSONValue, depth: Int) -> Bool {
            guard depth <= 32, remaining > 0 else { return false }
            switch value {
            case .null, .bool, .number:
                remaining -= 1
                return true
            case .string(let string):
                let count = string.unicodeScalars.prefix(remaining + 1).count
                guard count <= remaining else { return false }
                remaining -= count
                return true
            case .array(let values):
                for item in values where !visit(item, depth: depth + 1) { return false }
            case .object(let values):
                for (key, item) in values {
                    let keyCount = key.unicodeScalars.prefix(remaining + 1).count
                    guard keyCount <= remaining else { return false }
                    remaining -= keyCount
                    guard visit(item, depth: depth + 1) else { return false }
                }
            }
            return true
        }
        return visit(value, depth: 0)
    }

    private static func boundedCard(_ source: MessageCard?, clipped: inout Bool)
        -> MessageCard? {
        guard let source else { return nil }
        switch source {
        case .approvalRef(let ref):
            let bounded = boundedText(ref, maximum: maximumToolScalars)
            clipped = clipped || bounded.truncated
            return .approvalRef(bounded.text)
        case .papers(let papers):
            let bounded = papers.prefix(64).map { paper -> MessageCard.Paper in
                let title = boundedText(paper.title, maximum: maximumToolScalars)
                let meta = boundedText(paper.meta, maximum: maximumToolScalars)
                let summary = boundedText(paper.summary, maximum: maximumToolScalars)
                clipped = clipped || title.truncated || meta.truncated || summary.truncated
                return .init(title: title.text, meta: meta.text, summary: summary.text)
            }
            clipped = clipped || papers.count > bounded.count
            return .papers(Array(bounded))
        }
    }

    private static func consumeScalars(_ source: String, maximum: Int,
                                       remaining: inout Int)
        -> (text: String, truncated: Bool) {
        let allowed = min(maximum, max(0, remaining))
        let bounded = boundedText(source, maximum: allowed)
        remaining -= bounded.text.unicodeScalars.count
        return bounded
    }

    private static func clipVisibleScalars(_ message: inout ChatMessage,
                                           remaining: inout Int,
                                           clipped: inout Bool) {
        func take(_ value: String, maximum: Int) -> String {
            let result = consumeScalars(value, maximum: maximum, remaining: &remaining)
            clipped = clipped || result.truncated
            return result.text
        }
        message.text = take(message.text, maximum: maximumTextScalarsPerMessage)
        message.time = message.time.map { take($0, maximum: maximumToolScalars) }
        if let reasoning = message.reasoning {
            message.reasoning = take(reasoning, maximum: maximumTextScalarsPerMessage)
        }
        if var failure = message.failure {
            failure.message = take(failure.message, maximum: maximumToolScalars)
            message.failure = failure
        }
        if let card = message.card {
            switch card {
            case .approvalRef(let ref):
                message.card = .approvalRef(take(ref, maximum: maximumToolScalars))
            case .papers(let papers):
                message.card = .papers(papers.map { paper in
                    .init(title: take(paper.title, maximum: maximumToolScalars),
                          meta: take(paper.meta, maximum: maximumToolScalars),
                          summary: take(paper.summary, maximum: maximumToolScalars))
                })
            }
        }
        for index in message.toolCalls.indices {
            var call = message.toolCalls[index]
            call.id = take(call.id, maximum: 256)
            call.gatewayToolID = call.gatewayToolID.map { take($0, maximum: 256) }
            call.name = take(call.name, maximum: 160)
            call.context = take(call.context, maximum: maximumToolScalars)
            call.summary = call.summary.map { take($0, maximum: maximumToolScalars) }
            call.resultText = call.resultText.map { take($0, maximum: maximumToolScalars) }
            call.diagnostic = call.diagnostic.map { take($0, maximum: maximumToolScalars) }
            call.webSearchQuery = call.webSearchQuery.map {
                take($0, maximum: maximumToolScalars)
            }
            call.arguments = clipPayloadScalars(call.arguments, remaining: &remaining,
                                                clipped: &clipped)
            call.result = clipPayloadScalars(call.result, remaining: &remaining,
                                              clipped: &clipped)
            message.toolCalls[index] = call
        }
    }

    private static func clipPayloadScalars(_ source: ToolPayload?, remaining: inout Int,
                                           clipped: inout Bool) -> ToolPayload? {
        guard var payload = source else { return nil }
        if let text = payload.text {
            let bounded = consumeScalars(text, maximum: maximumToolScalars,
                                          remaining: &remaining)
            payload.text = bounded.text
            payload.isTruncated = payload.isTruncated || bounded.truncated
            clipped = clipped || bounded.truncated
            if bounded.truncated { payload.json = nil }
        }
        if let json = payload.json {
            let count = jsonScalarCount(json)
            if count <= remaining {
                remaining -= count
            } else {
                payload.json = nil
                payload.isTruncated = true
                clipped = true
            }
        }
        return payload
    }

    private static func consumeBytes(_ source: String, maximum: Int,
                                     remaining: inout Int)
        -> (text: String, truncated: Bool) {
        let allowed = min(maximum, max(0, remaining))
        let bounded = boundedUTF8Text(source, maximumBytes: allowed)
        remaining -= bounded.text.utf8.count
        return bounded
    }

    private static func clipVisibleBytes(_ message: inout ChatMessage,
                                         remaining: inout Int,
                                         clipped: inout Bool) {
        func take(_ value: String, maximum: Int = maximumBytesPerRun) -> String {
            let result = consumeBytes(value, maximum: maximum, remaining: &remaining)
            clipped = clipped || result.truncated
            return result.text
        }
        message.text = take(message.text)
        message.time = message.time.map { take($0, maximum: maximumToolScalars) }
        if let reasoning = message.reasoning { message.reasoning = take(reasoning) }
        if var failure = message.failure {
            failure.message = take(failure.message)
            message.failure = failure
        }
        if let card = message.card {
            switch card {
            case .approvalRef(let ref): message.card = .approvalRef(take(ref))
            case .papers(let papers):
                message.card = .papers(papers.map {
                    .init(title: take($0.title), meta: take($0.meta), summary: take($0.summary))
                })
            }
        }
        for index in message.toolCalls.indices {
            var call = message.toolCalls[index]
            call.id = take(call.id, maximum: 256)
            call.gatewayToolID = call.gatewayToolID.map { take($0, maximum: 256) }
            call.name = take(call.name, maximum: 160)
            call.context = take(call.context, maximum: maximumToolScalars)
            call.summary = call.summary.map { take($0, maximum: maximumToolScalars) }
            call.resultText = call.resultText.map { take($0, maximum: maximumToolScalars) }
            call.diagnostic = call.diagnostic.map { take($0, maximum: maximumToolScalars) }
            call.arguments?.json = nil
            call.result?.json = nil
            call.arguments = clipPayloadBytes(call.arguments, remaining: &remaining,
                                               clipped: &clipped)
            call.result = clipPayloadBytes(call.result, remaining: &remaining,
                                            clipped: &clipped)
            message.toolCalls[index] = call
        }
    }

    private static func clipPayloadBytes(_ source: ToolPayload?, remaining: inout Int,
                                         clipped: inout Bool) -> ToolPayload? {
        guard var payload = source else { return nil }
        if let text = payload.text {
            let bounded = consumeBytes(text, maximum: maximumToolScalars * 4,
                                       remaining: &remaining)
            payload.text = bounded.text
            payload.isTruncated = payload.isTruncated || bounded.truncated
            clipped = clipped || bounded.truncated
        }
        payload.json = nil
        return payload
    }

    private static func boundedText(_ source: String, maximum: Int)
        -> (text: String, truncated: Bool) {
        guard maximum >= 0 else { return ("", !source.isEmpty) }
        let scalars = source.unicodeScalars.prefix(maximum + 1)
        guard scalars.count > maximum else { return (source, false) }
        let marker = clippedMarker.unicodeScalars
        var retained = String.UnicodeScalarView()
        retained.append(contentsOf: scalars.prefix(maximum))
        if maximum <= marker.count { return (String(retained), true) }
        retained = String.UnicodeScalarView()
        retained.append(contentsOf: scalars.prefix(maximum - marker.count))
        return (String(retained) + clippedMarker, true)
    }

    private static func boundedUTF8Text(_ source: String, maximumBytes: Int)
        -> (text: String, truncated: Bool) {
        guard maximumBytes >= 0 else { return ("", !source.isEmpty) }
        var retained = String.UnicodeScalarView()
        var used = 0
        var truncated = false
        for scalar in source.unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            guard used + scalarBytes <= maximumBytes else {
                truncated = true
                break
            }
            retained.append(scalar)
            used += scalarBytes
        }
        if !truncated { return (source, false) }
        return (String(retained), true)
    }

    /// Complete-value specialist fields and structural JSON cannot be
    /// prefix-clipped without changing their meaning.  They remain present
    /// while the aggregate budget allows them, then are removed atomically.
    private static func dropOptionalEvidence(_ message: inout ChatMessage) {
        for index in message.toolCalls.indices {
            dropOptionalEvidence(&message.toolCalls[index])
        }
    }

    private static func dropOptionalEvidence(_ call: inout ToolCall) {
        if call.arguments?.json != nil {
            call.arguments?.json = nil
            call.arguments?.isTruncated = true
        }
        if call.result?.json != nil {
            call.result?.json = nil
            call.result?.isTruncated = true
        }
        call.fileDiff = nil
        call.structuredOutput = nil
        call.deferredStructuredOutput = nil
        call.deferredFileDiff = nil
        call.webSearchOutput = nil
        call.deferredWebSearchOutput = nil
        call.generatedImage = nil
        call.deferredGeneratedImage = nil
    }

    private static func jsonScalarCount(_ value: JSONValue, depth: Int = 0) -> Int {
        guard depth <= 32 else { return 0 }
        switch value {
        case .null, .bool, .number: return 0
        case .string(let value): return value.unicodeScalars.count
        case .array(let values):
            return values.reduce(0) { $0 + jsonScalarCount($1, depth: depth + 1) }
        case .object(let values):
            return values.reduce(0) {
                $0 + $1.key.unicodeScalars.count
                    + jsonScalarCount($1.value, depth: depth + 1)
            }
        }
    }

    private static func jsonByteCount(_ value: JSONValue) -> Int {
        (try? JSONEncoder().encode(value).count) ?? jsonScalarCount(value)
    }

    private static func optionalScalarCount(_ value: String?) -> Int {
        value?.unicodeScalars.count ?? 0
    }

    private static func optionalByteCount(_ value: String?) -> Int {
        value?.utf8.count ?? 0
    }

    private static func scalarCount(_ stream: ToolOutputStream?) -> Int {
        guard let stream else { return 0 }
        return stream.segments.reduce(0) { $0 + $1.text.unicodeScalars.count }
            + optionalScalarCount(stream.diagnostic)
    }

    private static func byteCount(_ stream: ToolOutputStream?) -> Int {
        guard let stream else { return 0 }
        return stream.segments.reduce(0) { $0 + $1.text.utf8.count }
            + optionalByteCount(stream.diagnostic)
    }

    private static func scalarCount(_ value: ToolFileDiff?) -> Int {
        guard let value else { return 0 }
        return optionalScalarCount(value.path)
            + optionalScalarCount(value.unifiedDiff)
            + optionalScalarCount(value.diagnostic)
    }

    private static func byteCount(_ value: ToolFileDiff?) -> Int {
        guard let value else { return 0 }
        return optionalByteCount(value.path)
            + optionalByteCount(value.unifiedDiff)
            + optionalByteCount(value.diagnostic)
    }

    private static func scalarCount(_ value: ToolStructuredOutput?) -> Int {
        guard let value else { return 0 }
        return scalarCount(value.stdout) + scalarCount(value.stderr)
            + optionalScalarCount(value.residualText)
            + optionalScalarCount(value.diagnostic)
    }

    private static func byteCount(_ value: ToolStructuredOutput?) -> Int {
        guard let value else { return 0 }
        return byteCount(value.stdout) + byteCount(value.stderr)
            + optionalByteCount(value.residualText)
            + optionalByteCount(value.diagnostic)
    }

    private static func scalarCount(_ value: ToolWebSearchOutput?) -> Int {
        guard let value else { return 0 }
        return optionalScalarCount(value.query)
            + value.hits.reduce(0) {
                $0 + $1.title.unicodeScalars.count
                    + optionalScalarCount($1.url)
                    + optionalScalarCount($1.snippet)
            }
            + optionalScalarCount(value.diagnostic)
    }

    private static func byteCount(_ value: ToolWebSearchOutput?) -> Int {
        guard let value else { return 0 }
        return optionalByteCount(value.query)
            + value.hits.reduce(0) {
                $0 + $1.title.utf8.count
                    + optionalByteCount($1.url)
                    + optionalByteCount($1.snippet)
            }
            + optionalByteCount(value.diagnostic)
    }

    private static func scalarCount(_ value: ToolGeneratedImage?) -> Int {
        guard let value else { return 0 }
        return value.source.unicodeScalars.count
            + value.echoSources.reduce(0) { $0 + $1.unicodeScalars.count }
    }

    private static func byteCount(_ value: ToolGeneratedImage?) -> Int {
        guard let value else { return 0 }
        return value.source.utf8.count
            + value.echoSources.reduce(0) { $0 + $1.utf8.count }
    }

    private static func retainedScalarCount(_ payload: ToolPayload?) -> Int {
        guard let payload else { return 0 }
        return optionalScalarCount(payload.text)
            + (payload.json.map { jsonScalarCount($0) } ?? 0)
    }

    private static func retainedByteCount(_ payload: ToolPayload?) -> Int {
        guard let payload else { return 0 }
        return optionalByteCount(payload.text)
            + (payload.json.map { jsonByteCount($0) } ?? 0)
    }

    private static func retainedScalarCount(_ call: ToolCall) -> Int {
        optionalScalarCount(call.id)
            + optionalScalarCount(call.gatewayToolID)
            + call.name.unicodeScalars.count
            + call.context.unicodeScalars.count
            + optionalScalarCount(call.summary)
            + optionalScalarCount(call.resultText)
            + optionalScalarCount(call.diagnostic)
            + optionalScalarCount(call.webSearchQuery)
            + retainedScalarCount(call.arguments)
            + retainedScalarCount(call.result)
            + scalarCount(call.fileDiff)
            + scalarCount(call.structuredOutput)
            + scalarCount(call.deferredStructuredOutput)
            + scalarCount(call.deferredFileDiff)
            + scalarCount(call.webSearchOutput)
            + scalarCount(call.deferredWebSearchOutput)
            + scalarCount(call.generatedImage)
            + scalarCount(call.deferredGeneratedImage)
    }

    private static func retainedByteCount(_ call: ToolCall) -> Int {
        optionalByteCount(call.id)
            + optionalByteCount(call.gatewayToolID)
            + call.name.utf8.count
            + call.context.utf8.count
            + optionalByteCount(call.summary)
            + optionalByteCount(call.resultText)
            + optionalByteCount(call.diagnostic)
            + optionalByteCount(call.webSearchQuery)
            + retainedByteCount(call.arguments)
            + retainedByteCount(call.result)
            + byteCount(call.fileDiff)
            + byteCount(call.structuredOutput)
            + byteCount(call.deferredStructuredOutput)
            + byteCount(call.deferredFileDiff)
            + byteCount(call.webSearchOutput)
            + byteCount(call.deferredWebSearchOutput)
            + byteCount(call.generatedImage)
            + byteCount(call.deferredGeneratedImage)
    }

    private static func retainedScalarCount(_ message: ChatMessage) -> Int {
        optionalScalarCount(message.time)
            + message.text.unicodeScalars.count
            + optionalScalarCount(message.reasoning)
            + optionalScalarCount(message.failure?.message)
            + (message.card.map { card in
                switch card {
                case .approvalRef(let value): return value.unicodeScalars.count
                case .papers(let papers):
                    return papers.reduce(0) {
                        $0 + $1.title.unicodeScalars.count
                            + $1.meta.unicodeScalars.count
                            + $1.summary.unicodeScalars.count
                    }
                }
            } ?? 0)
            + message.toolCalls.reduce(0) { $0 + retainedScalarCount($1) }
    }

    private static func retainedByteCount(_ message: ChatMessage) -> Int {
        optionalByteCount(message.time)
            + message.text.utf8.count
            + optionalByteCount(message.reasoning)
            + optionalByteCount(message.failure?.message)
            + (message.card.map { card in
                switch card {
                case .approvalRef(let value): return value.utf8.count
                case .papers(let papers):
                    return papers.reduce(0) {
                        $0 + $1.title.utf8.count
                            + $1.meta.utf8.count
                            + $1.summary.utf8.count
                    }
                }
            } ?? 0)
            + message.toolCalls.reduce(0) { $0 + retainedByteCount($1) }
    }

    private static func retainedScalarCount(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + retainedScalarCount($1) }
    }

    private static func retainedByteCount(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + retainedByteCount($1) }
    }
}

/// Source compatibility for callers that prefer an explicit state name.
public typealias AssistantResponseAlternativesState = AssistantResponseAlternatives
public typealias AssistantResponseAlternative = AssistantResponseAlternativeRun
