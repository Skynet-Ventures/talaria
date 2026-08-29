import Foundation

/// Mobile port of Hermes Desktop's rewind/edit/regenerate planners
/// (`apps/desktop/src/app/session/hooks/use-prompt-actions/rewind.ts`).
///
/// A truncating `prompt.submit` is the one primitive: the gateway drops the
/// targeted user turn and everything after it, then runs the submitted text as
/// a fresh turn. Ordinary sends MUST NOT carry leftover ordinals — the gateway
/// only truncates when `confirm_truncate` is present.
public enum TranscriptActing {
    public struct TruncateAddress: Equatable, Sendable {
        public var ordinal: Int?
        public var rowID: Int?
        public var confirmEmpty: Bool

        public init(ordinal: Int? = nil, rowID: Int? = nil, confirmEmpty: Bool = false) {
            self.ordinal = ordinal
            self.rowID = rowID
            self.confirmEmpty = confirmEmpty
        }

        public var isEmpty: Bool { ordinal == nil && rowID == nil }
    }

    public struct Plan: Equatable, Sendable {
        public enum Kind: String, Sendable, Equatable {
            case restore
            case regenerate
            case edit
        }

        public var sourceIndex: Int
        public var sourceText: String
        public var text: String
        public var truncate: TruncateAddress
        public var dropsFromIndex: Int
        /// Metadata used only by the local response-alternative lifecycle.
        /// `truncate` remains the exact existing wire address.
        public var kind: Kind
        public var sourceUserID: UUID?
        public var previousAssistantRun: [ChatMessage]

        public init(sourceIndex: Int, sourceText: String, text: String,
                    truncate: TruncateAddress, dropsFromIndex: Int,
                    kind: Kind = .restore, sourceUserID: UUID? = nil,
                    previousAssistantRun: [ChatMessage] = []) {
            self.sourceIndex = sourceIndex
            self.sourceText = sourceText
            self.text = text
            self.truncate = truncate
            self.dropsFromIndex = dropsFromIndex
            self.kind = kind
            self.sourceUserID = sourceUserID
            self.previousAssistantRun = previousAssistantRun
        }
    }

    /// Visible user turns that actually reached the gateway. Empty bubbles and
    /// local-only failed sends are not truncation addresses.
    public static func visibleUserIndices(_ messages: [ChatMessage]) -> [Int] {
        messages.indices.filter { index in
            let message = messages[index]
            guard message.author == .user else { return false }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty
        }
    }

    public static func visibleUserOrdinal(_ messages: [ChatMessage], before index: Int) -> Int {
        visibleUserIndices(messages).filter { $0 < index }.count
    }

    public static func truncateParams(_ address: TruncateAddress) -> [String: JSONValue] {
        guard !address.isEmpty else { return [:] }
        var params: [String: JSONValue] = ["confirm_truncate": .bool(true)]
        if let rowID = address.rowID {
            params["truncate_before_row_id"] = .number(Double(rowID))
        } else if let ordinal = address.ordinal {
            params["truncate_before_user_ordinal"] = .number(Double(ordinal))
        }
        if address.confirmEmpty || address.ordinal == 0 {
            params["confirm_empty_truncate"] = .bool(true)
        }
        return params
    }

    /// Regenerating an assistant bubble resubmits the nearest previous user
    /// prompt and drops that prompt plus everything after it.
    public static func planReload(_ messages: [ChatMessage], from messageID: UUID) -> Plan? {
        guard let parentIndex = messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        let userIndex = messages[0...parentIndex].lastIndex(where: { $0.author == .user })
        guard let userIndex else { return nil }
        let source = messages[userIndex]
        let sourceEnd = messages[(userIndex + 1)..<messages.endIndex]
            .firstIndex(where: { $0.author == .user }) ?? messages.endIndex
        let previousAssistantRun = Array(messages[(userIndex + 1)..<sourceEnd])
            .filter { $0.author == .bot }
        guard let restore = planRestore(messages, from: source.id) else { return nil }
        return Plan(sourceIndex: restore.sourceIndex,
                    sourceText: restore.sourceText,
                    text: restore.text,
                    truncate: restore.truncate,
                    dropsFromIndex: restore.dropsFromIndex,
                    kind: .regenerate,
                    sourceUserID: source.id,
                    previousAssistantRun: previousAssistantRun)
    }

    /// Restore/rewind a user turn: drop it and everything after, then run the
    /// same text again.
    public static func planRestore(_ messages: [ChatMessage], from messageID: UUID) -> Plan? {
        guard let sourceIndex = messages.firstIndex(where: { $0.id == messageID }),
              messages[sourceIndex].author == .user else { return nil }
        let sourceText = messages[sourceIndex].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { return nil }
        guard let truncate = address(for: messages, at: sourceIndex) else { return nil }
        return Plan(sourceIndex: sourceIndex,
                    sourceText: sourceText,
                    text: sourceText,
                    truncate: truncate,
                    dropsFromIndex: sourceIndex,
                    kind: .restore,
                    sourceUserID: messages[sourceIndex].id)
    }

    /// Edit a user turn: drop it and everything after, then submit the new text.
    public static func planEdit(_ messages: [ChatMessage], from messageID: UUID,
                                text: String) -> Plan? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sourceIndex = messages.firstIndex(where: { $0.id == messageID }),
              messages[sourceIndex].author == .user,
              !trimmed.isEmpty else { return nil }
        let sourceText = messages[sourceIndex].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sourceText != trimmed else { return nil }
        guard let truncate = address(for: messages, at: sourceIndex) else { return nil }
        return Plan(sourceIndex: sourceIndex,
                    sourceText: sourceText,
                    text: trimmed,
                    truncate: truncate,
                    dropsFromIndex: sourceIndex,
                    kind: .edit,
                    sourceUserID: messages[sourceIndex].id)
    }

    /// After a truncating submit, surviving visible user turns get new SQLite
    /// ids. Rebind them in visible-user order; anything past the survivor list
    /// (the resubmitted turn) drops its cached id so the next rewind cannot
    /// 4018 on a stale row.
    public static func rebindSurvivorRowIDs(_ messages: [ChatMessage],
                                            survivorRowIDs: [Int?]) -> [ChatMessage] {
        let indices = visibleUserIndices(messages)
        var next = messages
        for (ordinal, index) in indices.enumerated() {
            let rebound: Int? = ordinal < survivorRowIDs.count ? survivorRowIDs[ordinal] : nil
            next[index].rowID = rebound
        }
        return next
    }

    public static func survivorRowIDs(from value: JSONValue) -> [Int?] {
        (value["survivor_user_row_ids"]?.arrayValue ?? []).map { item in
            item.intValue
        }
    }

    public static func applyOptimistic(_ messages: [ChatMessage], plan: Plan) -> [ChatMessage] {
        Array(messages.prefix(plan.dropsFromIndex))
    }

    private static func address(for messages: [ChatMessage], at sourceIndex: Int) -> TruncateAddress? {
        let source = messages[sourceIndex]
        // A user bubble with no durable id never established a safe destructive
        // address. An ordinary prompt.submit here would look like rewind/edit
        // while leaving the old turn intact, so the action must be unavailable.
        guard source.rowID != nil else { return nil }
        let ordinal = visibleUserOrdinal(messages, before: sourceIndex)
        return TruncateAddress(ordinal: ordinal, rowID: source.rowID, confirmEmpty: ordinal == 0)
    }
}
