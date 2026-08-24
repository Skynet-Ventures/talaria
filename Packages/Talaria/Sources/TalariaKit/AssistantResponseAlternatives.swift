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
    public var isClipped: Bool
    public var clippedMessages: Int
    public var clippedVisibleScalars: Int
    public var clippedWorkItems: Int
    public var clippedBytes: Int

    public init(id: UUID = UUID(), messages: [ChatMessage], isClipped: Bool = false,
                clippedMessages: Int = 0, clippedVisibleScalars: Int = 0,
                clippedWorkItems: Int = 0, clippedBytes: Int = 0) {
        self.id = id
        self.messages = messages
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

    /// Position text uses the newest/current sentinel as the final response.
    public static func responsePosition(
        in state: AssistantResponseAlternatives
    ) -> (current: Int, total: Int)? {
        guard let group = state.selectedGroup else { return nil }
        let current = (state.selectedAlternativeIndex ?? group.alternatives.count) + 1
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
        var clipped = source.count > maximumMessagesPerRun
        var clippedMessages = max(0, source.count - maximumMessagesPerRun)
        var visibleScalars = 0
        var workItems = 0
        var bytes = 0
        var clippedVisibleScalars = 0
        var clippedWorkItems = 0
        var admitted: [ChatMessage] = []
        admitted.reserveCapacity(min(source.count, maximumMessagesPerRun))

        for sourceMessage in source.prefix(maximumMessagesPerRun) {
            var message = sourceMessage
            var messageClipped = false
            let text = boundedText(message.text, maximum: maximumTextScalarsPerMessage)
            message.text = text.text
            messageClipped = messageClipped || text.truncated
            if let reasoning = message.reasoning {
                let bounded = boundedText(reasoning, maximum: maximumTextScalarsPerMessage)
                message.reasoning = bounded.text
                messageClipped = messageClipped || bounded.truncated
            }
            var calls: [ToolCall] = []
            calls.reserveCapacity(min(message.toolCalls.count, 128))
            for call in message.toolCalls.prefix(128) {
                var boundedCall = call
                let context = boundedText(call.context, maximum: maximumToolScalars)
                boundedCall.context = context.text
                let summary = call.summary.map {
                    boundedText($0, maximum: maximumToolScalars)
                }
                boundedCall.summary = summary?.text
                let result = call.resultText.map {
                    boundedText($0, maximum: maximumToolScalars)
                }
                boundedCall.resultText = result?.text
                let diagnostic = call.diagnostic.map {
                    boundedText($0, maximum: maximumToolScalars)
                }
                boundedCall.diagnostic = diagnostic?.text
                messageClipped = messageClipped || context.truncated
                    || summary?.truncated == true || result?.truncated == true
                    || diagnostic?.truncated == true
                calls.append(boundedCall)
            }
            if message.toolCalls.count > calls.count {
                clipped = true
                clippedWorkItems += message.toolCalls.count - calls.count
            }
            message.toolCalls = calls
            let messageScalars = visibleScalarCount(message)
            let messageBytes = visibleByteCount(message)
            visibleScalars += messageScalars
            bytes += messageBytes
            workItems += 1 + calls.count
            if messageClipped { clipped = true }
            admitted.append(message)
        }

        if visibleScalars > maximumVisibleScalarsPerRun {
            clipped = true
            clippedVisibleScalars = visibleScalars - maximumVisibleScalarsPerRun
            let allowance = maximumVisibleScalarsPerRun
            var used = 0
            for index in admitted.indices {
                let message = admitted[index]
                let available = max(0, allowance - used)
                let bounded = boundedText(message.text, maximum: available)
                admitted[index].text = bounded.text
                used += bounded.text.unicodeScalars.count
                if bounded.truncated { admitted[index].reasoning = nil }
                if used >= allowance {
                    for rest in admitted.indices where rest > index {
                        admitted[rest].text = ""
                        admitted[rest].reasoning = nil
                        admitted[rest].toolCalls = []
                    }
                    break
                }
            }
            visibleScalars = allowance
        }
        if workItems > maximumWorkItemsPerRun {
            clipped = true
            clippedWorkItems += workItems - maximumWorkItemsPerRun
        }
        if bytes > maximumBytesPerRun {
            clipped = true
        }
        if clippedMessages == 0, source.count > admitted.count {
            clippedMessages = source.count - admitted.count
        }
        return AssistantResponseAlternativeRun(
            id: id, messages: admitted, isClipped: clipped,
            clippedMessages: clippedMessages,
            clippedVisibleScalars: clippedVisibleScalars,
            clippedWorkItems: clippedWorkItems,
            clippedBytes: max(0, bytes - maximumBytesPerRun))
    }

    private static func boundedText(_ source: String, maximum: Int)
        -> (text: String, truncated: Bool) {
        guard maximum >= 0 else { return ("", !source.isEmpty) }
        let scalars = Array(source.unicodeScalars)
        guard scalars.count > maximum else { return (source, false) }
        let marker = clippedMarker.unicodeScalars
        var retained = String.UnicodeScalarView()
        retained.append(contentsOf: scalars.prefix(maximum))
        if maximum <= marker.count { return (String(retained), true) }
        retained = String.UnicodeScalarView()
        retained.append(contentsOf: scalars.prefix(maximum - marker.count))
        return (String(retained) + clippedMarker, true)
    }

    private static func visibleScalarCount(_ message: ChatMessage) -> Int {
        var count = message.text.unicodeScalars.count
        count += message.reasoning?.unicodeScalars.count ?? 0
        count += message.failure?.message.unicodeScalars.count ?? 0
        for call in message.toolCalls {
            count += call.context.unicodeScalars.count
            count += call.summary?.unicodeScalars.count ?? 0
            count += call.resultText?.unicodeScalars.count ?? 0
            count += call.diagnostic?.unicodeScalars.count ?? 0
            count += call.arguments?.displayText?.unicodeScalars.count ?? 0
            count += call.result?.displayText?.unicodeScalars.count ?? 0
        }
        return count
    }

    private static func visibleByteCount(_ message: ChatMessage) -> Int {
        var count = message.text.utf8.count
        count += message.reasoning?.utf8.count ?? 0
        count += message.failure?.message.utf8.count ?? 0
        for call in message.toolCalls {
            count += call.context.utf8.count
            count += call.summary?.utf8.count ?? 0
            count += call.resultText?.utf8.count ?? 0
            count += call.diagnostic?.utf8.count ?? 0
            count += call.arguments?.displayText?.utf8.count ?? 0
            count += call.result?.displayText?.utf8.count ?? 0
        }
        return count
    }
}

/// Source compatibility for callers that prefer an explicit state name.
public typealias AssistantResponseAlternativesState = AssistantResponseAlternatives
public typealias AssistantResponseAlternative = AssistantResponseAlternativeRun
