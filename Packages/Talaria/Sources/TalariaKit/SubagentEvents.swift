import Foundation

/// Explicit limits for the parent-session `subagent.*` event family.  Hermes
/// emits these as advisory live progress, not as a durable session snapshot,
/// so Talaria admits a small, display-safe subset before it reaches any UI
/// state.
public enum SubagentEventLimits {
    public static let maximumIdentityScalars = 256
    public static let maximumTextScalars = 4_096
    public static let maximumModelScalars = 256
    public static let maximumToolNameScalars = 160
    public static let maximumToolsetScalars = 160
    public static let maximumFilePathScalars = 1_024
    public static let maximumTailPreviewScalars = 600
    public static let maximumTailEntries = 8
    public static let maximumFilesPerKind = 40
    public static let maximumToolsets = 32
    public static let maximumReportedDepth = 64
    public static let maximumCounter = 1_000_000_000_000
    public static let maximumTaskCount = 1_000_000
    public static let maximumDurationSeconds = 31_536_000.0
    public static let maximumCostUSD = 1_000_000_000.0
}

/// The recognized current Hermes subagent event suffixes.  Unknown suffixes
/// deliberately remain raw `GatewayEvent`s: inventing a lifecycle transition
/// from a future event would be less safe than waiting for an explicit model.
public enum SubagentEventKind: String, Sendable, Equatable, CaseIterable {
    case start
    case thinking
    case tool
    case progress
    case complete
    case text

    init?(gatewayEventType: String) {
        guard gatewayEventType.hasPrefix("subagent.") else { return nil }
        self.init(rawValue: String(gatewayEventType.dropFirst("subagent.".count)))
    }
}

/// Hermes' terminal subagent outcomes. `canceled` is accepted at the wire
/// boundary as the backend's alternate spelling and normalized to the
/// canonical `cancelled` case. A raw status outside this finite list is
/// malformed rather than a new visual state.
public enum SubagentStatus: String, Sendable, Equatable, CaseIterable {
    case queued
    case running
    case completed
    case failed
    case error
    case timeout
    case interrupted
    case cancelled
    case stopped

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .error, .timeout, .interrupted, .cancelled, .stopped:
            return true
        case .queued, .running:
            return false
        }
    }
}

/// Keep an absent status distinct from a malformed one. A `subagent.complete`
/// frame with no status has a safe completed endpoint-default; an explicit
/// malformed or still-active completion status is handled as terminal failure
/// by the reducer rather than leaving the branch spinning.
public enum SubagentStatusAdmission: Sendable, Equatable {
    case absent
    case malformed
    case value(SubagentStatus)
}

/// A bounded child result line carried by `output_tail` on completion.
public struct SubagentOutputTailEntry: Sendable, Equatable, Hashable {
    public let tool: String
    public let preview: String?
    public let isError: Bool

    public init(tool: String, preview: String?, isError: Bool) {
        self.tool = tool
        self.preview = preview
        self.isError = isError
    }
}

/// Sparse token counters from a subagent event.  Hermes currently includes
/// these on completion, but the sparse shape keeps a future partial event from
/// overwriting a previously admitted scalar with a synthetic zero.
public struct SubagentTokenUsageUpdate: Sendable, Equatable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let reasoningTokens: Int?
    public let apiCalls: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil,
                reasoningTokens: Int? = nil, apiCalls: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.apiCalls = apiCalls
    }

    public var isEmpty: Bool {
        inputTokens == nil && outputTokens == nil && reasoningTokens == nil && apiCalls == nil
    }
}

/// Sparse duration/cost values.  `cost_usd` is accepted when present because
/// the delegate producer supplies it, although an older gateway relay may not
/// yet forward that optional scalar.
public struct SubagentCostUpdate: Sendable, Equatable {
    public let durationSeconds: Double?
    public let costUSD: Double?

    public init(durationSeconds: Double? = nil, costUSD: Double? = nil) {
        self.durationSeconds = durationSeconds
        self.costUSD = costUSD
    }

    public var isEmpty: Bool { durationSeconds == nil && costUSD == nil }
}

/// A fully admitted `subagent.*` frame.  Its parent runtime session comes from
/// the WebSocket envelope, never a payload label.  The gateway source is added
/// by the UI routing fence before this payload enters the live store.
public struct SubagentGatewayEvent: Sendable, Equatable {
    public let kind: SubagentEventKind
    public let parentRuntimeSessionID: String
    public let subagentID: String
    /// Optional nested-parent identity.  Goals, models, and tool labels are
    /// presentation only and are never used as a hierarchy key.
    public let parentSubagentID: String?
    /// Hermes' durable child session reference, not a parent runtime sid.
    public let childSessionID: String?
    public let reportedDepth: Int?
    public let taskCount: Int?
    public let taskIndex: Int?
    public let goal: String?
    public let model: String?
    public let toolCount: Int?
    public let toolsets: [String]?
    public let text: String?
    public let toolName: String?
    public let toolPreview: String?
    public let status: SubagentStatusAdmission
    public let summary: String?
    public let tokenUsage: SubagentTokenUsageUpdate
    public let cost: SubagentCostUpdate
    public let filesRead: [String]?
    public let filesWritten: [String]?
    public let outputTail: [SubagentOutputTailEntry]?
    /// At least one admitted non-identity field was clipped to a local bound.
    public let isClipped: Bool

    init(kind: SubagentEventKind, parentRuntimeSessionID: String, subagentID: String,
         parentSubagentID: String?, childSessionID: String?, reportedDepth: Int?,
         taskCount: Int?, taskIndex: Int?, goal: String?, model: String?,
         toolCount: Int?, toolsets: [String]?, text: String?, toolName: String?,
         toolPreview: String?, status: SubagentStatusAdmission, summary: String?,
         tokenUsage: SubagentTokenUsageUpdate, cost: SubagentCostUpdate,
         filesRead: [String]?, filesWritten: [String]?,
         outputTail: [SubagentOutputTailEntry]?, isClipped: Bool) {
        self.kind = kind
        self.parentRuntimeSessionID = parentRuntimeSessionID
        self.subagentID = subagentID
        self.parentSubagentID = parentSubagentID
        self.childSessionID = childSessionID
        self.reportedDepth = reportedDepth
        self.taskCount = taskCount
        self.taskIndex = taskIndex
        self.goal = goal
        self.model = model
        self.toolCount = toolCount
        self.toolsets = toolsets
        self.text = text
        self.toolName = toolName
        self.toolPreview = toolPreview
        self.status = status
        self.summary = summary
        self.tokenUsage = tokenUsage
        self.cost = cost
        self.filesRead = filesRead
        self.filesWritten = filesWritten
        self.outputTail = outputTail
        self.isClipped = isClipped
    }
}

/// Bounded, fail-closed admission for current Hermes `subagent.*` payloads.
/// This intentionally does not produce a placeholder for malformed identity:
/// a placeholder would become an attacker-controlled key in the live tree.
enum SubagentEventCodec {
    private struct BoundedText {
        let value: String
        let isClipped: Bool
    }

    static func decode(_ event: GatewayEvent) -> SubagentGatewayEvent? {
        guard let kind = SubagentEventKind(gatewayEventType: event.type),
              let parentRuntimeSessionID = identity(event.sessionID),
              let object = event.payload?.objectValue,
              let subagentID = identity(object["subagent_id"])
        else { return nil }

        var clipped = false

        func text(_ key: String, maximum: Int = SubagentEventLimits.maximumTextScalars)
            -> String? {
            guard let admitted = boundedText(object[key], maximum: maximum) else { return nil }
            clipped = clipped || admitted.isClipped
            return admitted.value
        }

        func strings(_ key: String, maximumCount: Int, maximumText: Int) -> [String]? {
            guard let admitted = boundedStrings(
                object[key], maximumCount: maximumCount, maximumText: maximumText
            ) else { return nil }
            clipped = clipped || admitted.isClipped
            return admitted.values
        }

        let tail: [SubagentOutputTailEntry]?
        if let admitted = boundedTail(object["output_tail"]) {
            clipped = clipped || admitted.isClipped
            tail = admitted.values
        } else {
            tail = nil
        }

        return SubagentGatewayEvent(
            kind: kind,
            parentRuntimeSessionID: parentRuntimeSessionID,
            subagentID: subagentID,
            parentSubagentID: identity(object["parent_id"]),
            childSessionID: identity(object["child_session_id"]),
            reportedDepth: boundedInteger(object["depth"],
                                          maximum: SubagentEventLimits.maximumReportedDepth),
            taskCount: boundedInteger(object["task_count"],
                                      maximum: SubagentEventLimits.maximumTaskCount),
            taskIndex: boundedInteger(object["task_index"],
                                      maximum: SubagentEventLimits.maximumTaskCount),
            goal: text("goal"),
            model: text("model", maximum: SubagentEventLimits.maximumModelScalars),
            toolCount: boundedInteger(object["tool_count"],
                                      maximum: SubagentEventLimits.maximumCounter),
            toolsets: strings("toolsets", maximumCount: SubagentEventLimits.maximumToolsets,
                              maximumText: SubagentEventLimits.maximumToolsetScalars),
            text: text("text"),
            toolName: text("tool_name", maximum: SubagentEventLimits.maximumToolNameScalars),
            toolPreview: text("tool_preview"),
            status: status(object["status"], for: kind),
            summary: text("summary"),
            tokenUsage: SubagentTokenUsageUpdate(
                inputTokens: boundedInteger(object["input_tokens"],
                                             maximum: SubagentEventLimits.maximumCounter),
                outputTokens: boundedInteger(object["output_tokens"],
                                              maximum: SubagentEventLimits.maximumCounter),
                reasoningTokens: boundedInteger(object["reasoning_tokens"],
                                                 maximum: SubagentEventLimits.maximumCounter),
                apiCalls: boundedInteger(object["api_calls"],
                                         maximum: SubagentEventLimits.maximumCounter)
            ),
            cost: SubagentCostUpdate(
                durationSeconds: boundedFinite(object["duration_seconds"],
                                               maximum: SubagentEventLimits.maximumDurationSeconds),
                costUSD: boundedFinite(object["cost_usd"],
                                       maximum: SubagentEventLimits.maximumCostUSD)
            ),
            filesRead: strings("files_read", maximumCount: SubagentEventLimits.maximumFilesPerKind,
                               maximumText: SubagentEventLimits.maximumFilePathScalars),
            filesWritten: strings("files_written", maximumCount: SubagentEventLimits.maximumFilesPerKind,
                                  maximumText: SubagentEventLimits.maximumFilePathScalars),
            outputTail: tail,
            isClipped: clipped
        )
    }

    /// Routing fences and model keys use strict, un-clipped references.  A
    /// prefix is a different runtime/source identity, so truncation is never
    /// a safe fallback here.
    static func identity(_ value: JSONValue?) -> String? {
        guard let value = value?.stringValue else { return nil }
        return identity(value)
    }

    static func identity(_ value: String) -> String? {
        let raw = value.unicodeScalars.prefix(SubagentEventLimits.maximumIdentityScalars + 1)
        guard raw.count <= SubagentEventLimits.maximumIdentityScalars else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              trimmed == value,
              !value.unicodeScalars.contains(where: { unsafeIdentityScalar($0.value) })
        else { return nil }
        return value
    }

    private static func boundedInteger(_ value: JSONValue?, maximum: Int) -> Int? {
        guard let number = value?.doubleValue,
              number.isFinite,
              number >= 0,
              number.rounded(.towardZero) == number,
              number <= Double(maximum)
        else { return nil }
        return Int(number)
    }

    private static func boundedFinite(_ value: JSONValue?, maximum: Double) -> Double? {
        guard let number = value?.doubleValue,
              number.isFinite,
              number >= 0,
              number <= maximum
        else { return nil }
        return number
    }

    private static func status(_ value: JSONValue?, for kind: SubagentEventKind)
        -> SubagentStatusAdmission {
        guard let value else { return .absent }
        guard let text = identity(value) else { return .malformed }
        let normalized = text.lowercased() == "canceled" ? "cancelled" : text.lowercased()
        guard let status = SubagentStatus(rawValue: normalized),
              (kind == .complete || !status.isTerminal),
              (kind != .complete || status.isTerminal)
        else { return .malformed }
        return .value(status)
    }

    private static func boundedText(_ value: JSONValue?, maximum: Int) -> BoundedText? {
        guard let value = value?.stringValue, maximum > 0 else { return nil }
        let marker = "\n… [subagent text clipped]"
        let raw = value.unicodeScalars.prefix(maximum + 1)
        let wasClipped = raw.count > maximum
        var safe = String.UnicodeScalarView()
        safe.reserveCapacity(min(maximum, raw.count))
        for scalar in raw.prefix(maximum) {
            guard !unsafeControl(scalar.value) else { return nil }
            safe.append(scalar)
        }
        let visible = String(safe).trimmingCharacters(in: .whitespacesAndNewlines)
        guard visible.unicodeScalars.contains(where: {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }) else { return nil }
        guard wasClipped else { return BoundedText(value: visible, isClipped: false) }

        let markerScalars = marker.unicodeScalars
        let contentLimit = max(0, maximum - min(maximum, markerScalars.count))
        var clipped = String.UnicodeScalarView(safe.prefix(contentLimit))
        clipped.append(contentsOf: markerScalars.prefix(maximum - contentLimit))
        return BoundedText(value: String(clipped), isClipped: true)
    }

    private static func boundedStrings(_ value: JSONValue?, maximumCount: Int,
                                       maximumText: Int)
        -> (values: [String], isClipped: Bool)? {
        guard let values = value?.arrayValue, maximumCount > 0 else { return nil }
        let prefix = values.prefix(maximumCount + 1)
        var clipped = prefix.count > maximumCount
        var result: [String] = []
        var seen = Set<String>()
        result.reserveCapacity(min(maximumCount, values.count))
        for item in prefix.prefix(maximumCount) {
            guard let admitted = boundedText(item, maximum: maximumText) else { continue }
            clipped = clipped || admitted.isClipped
            if seen.insert(admitted.value).inserted { result.append(admitted.value) }
        }
        return result.isEmpty ? nil : (result, clipped)
    }

    private static func boundedTail(_ value: JSONValue?)
        -> (values: [SubagentOutputTailEntry], isClipped: Bool)? {
        guard let values = value?.arrayValue else { return nil }
        let prefix = values.prefix(SubagentEventLimits.maximumTailEntries + 1)
        var clipped = prefix.count > SubagentEventLimits.maximumTailEntries
        var result: [SubagentOutputTailEntry] = []
        result.reserveCapacity(min(SubagentEventLimits.maximumTailEntries, values.count))
        for value in prefix.prefix(SubagentEventLimits.maximumTailEntries) {
            guard let object = value.objectValue,
                  let tool = boundedText(object["tool"],
                                         maximum: SubagentEventLimits.maximumToolNameScalars)
            else { continue }
            let preview = boundedText(object["preview"],
                                      maximum: SubagentEventLimits.maximumTailPreviewScalars)
            if let rawError = object["is_error"], rawError.boolValue == nil { continue }
            clipped = clipped || tool.isClipped || (preview?.isClipped ?? false)
            result.append(SubagentOutputTailEntry(
                tool: tool.value, preview: preview?.value,
                isError: object["is_error"]?.boolValue ?? false
            ))
        }
        return result.isEmpty ? nil : (result, clipped)
    }

    private static func unsafeControl(_ value: UInt32) -> Bool {
        if value == 0x09 || value == 0x0A { return false }
        if value <= 0x1F || (0x7F...0x9F).contains(value) { return true }
        switch value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        default:
            return false
        }
    }

    private static func unsafeIdentityScalar(_ value: UInt32) -> Bool {
        if value <= 0x1F || (0x7F...0x9F).contains(value) { return true }
        switch value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        default:
            return false
        }
    }
}
