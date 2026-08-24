import Foundation

// Server→client events on /api/ws. Envelope (tui_gateway/server.py:_event_frame):
//   {"jsonrpc":"2.0","method":"event","params":{"type":"<event>","session_id":"<sid>","payload":{...}}}
// session_id is the runtime UI sid (8 hex chars); "" marks a global broadcast.

public struct GatewayEvent: Sendable {
    public var type: String
    /// Runtime session id; empty string for global broadcasts.
    public var sessionID: String
    public var payload: JSONValue?
    /// Monotonic frame position assigned by the transport. Zero is reserved
    /// for synthetic/test events that predate sequencing.
    public var inboundSequence: UInt64

    public init(type: String, sessionID: String, payload: JSONValue?,
                inboundSequence: UInt64 = 0) {
        self.type = type; self.sessionID = sessionID; self.payload = payload
        self.inboundSequence = inboundSequence
    }

    public var isGlobal: Bool { sessionID.isEmpty }
}

/// Typed views over the events Talaria renders. Anything unlisted still flows
/// through as `.other` so screens can opt in without protocol churn.
public enum TypedGatewayEvent: Sendable {
    case gatewayReady(skin: JSONValue?, changeEvents: Bool)
    case messageStart
    case messageDelta(text: String)
    case messageInterim(text: String, alreadyStreamed: Bool)
    case thinkingDelta(text: String)
    case reasoningDelta(text: String)
    case messageComplete(MessageCompletePayload)
    case sessionUsage(Usage)
    case sessionInfo(SessionInfo)
    case sessionTitle(storedSessionID: String, title: String)
    case toolGenerating(name: String)
    case toolStart(ToolStartPayload)
    case toolComplete(ToolCompletePayload)
    case statusUpdate(kind: String, text: String)
    case approvalRequest(ApprovalRequest)
    case clarifyRequest(ClarifyRequest)
    case notificationShow(NotificationPayload)
    case notificationClear(key: String)
    case backgroundComplete(taskID: String, text: String)
    case voiceTranscript(text: String?, stopPhrase: Bool)
    case voiceStatus(state: String)
    case errorEvent(message: String)
    /// Global broadcasts: sessions.changed, cron.changed, platforms.changed…
    case changed(what: String)
    case other(GatewayEvent)

    public init(_ event: GatewayEvent) {
        let p = event.payload
        switch event.type {
        case "gateway.ready":
            self = .gatewayReady(skin: p?["skin"], changeEvents: p?["change_events"]?.boolValue ?? false)
        case "message.start":
            self = .messageStart
        case "message.delta":
            self = .messageDelta(text: p?["text"]?.stringValue ?? "")
        case "message.interim":
            self = .messageInterim(text: p?["text"]?.stringValue ?? "",
                                   alreadyStreamed: p?["already_streamed"]?.boolValue ?? false)
        case "thinking.delta":
            self = .thinkingDelta(text: p?["text"]?.stringValue ?? "")
        case "reasoning.delta":
            self = .reasoningDelta(text: p?["text"]?.stringValue ?? "")
        case "message.complete":
            self = .messageComplete(MessageCompletePayload(p))
        case "session.usage":
            self = .sessionUsage(Usage(p?["usage"]))
        case "session.info":
            self = .sessionInfo(SessionInfo(p))
        case "session.title":
            self = .sessionTitle(storedSessionID: p?["session_id"]?.stringValue ?? "",
                                 title: p?["title"]?.stringValue ?? "")
        case "tool.generating":
            self = .toolGenerating(name: ToolPayloadCodec.admittedIdentity(
                p?["name"]?.stringValue,
                maximum: ToolPayloadCodec.maximumToolNameCharacters) ?? "")
        case "tool.start":
            self = .toolStart(ToolStartPayload(p))
        case "tool.complete":
            self = .toolComplete(ToolCompletePayload(p))
        case "status.update":
            self = .statusUpdate(kind: p?["kind"]?.stringValue ?? "",
                                 text: p?["text"]?.stringValue ?? "")
        case "approval.request":
            self = .approvalRequest(ApprovalRequest(p, sessionID: event.sessionID))
        case "clarify.request":
            self = .clarifyRequest(ClarifyRequest(p, sessionID: event.sessionID))
        case "notification.show":
            self = .notificationShow(NotificationPayload(p))
        case "notification.clear":
            self = .notificationClear(key: p?["key"]?.stringValue ?? "")
        case "background.complete":
            self = .backgroundComplete(taskID: p?["task_id"]?.stringValue ?? "",
                                       text: p?["text"]?.stringValue ?? "")
        case "voice.transcript":
            self = .voiceTranscript(text: p?["text"]?.stringValue,
                                    stopPhrase: p?["stop_phrase"]?.boolValue ?? false)
        case "voice.status":
            self = .voiceStatus(state: p?["state"]?.stringValue ?? "")
        case "error":
            self = .errorEvent(message: p?["message"]?.stringValue ?? "")
        case "sessions.changed", "cron.changed", "pet.changed", "platforms.changed",
             "pairing.changed", "skin.changed":
            self = .changed(what: event.type)
        default:
            self = .other(event)
        }
    }
}

// MARK: - Event payloads

public struct Usage: Sendable, Equatable {
    public var model: String?
    public var input: Int
    public var output: Int
    public var total: Int
    public var contextUsed: Int?
    public var contextMax: Int?
    public var contextPercent: Int?
    public var activeSubagents: Int?

    public init(_ v: JSONValue?) {
        model = v?["model"]?.stringValue
        input = v?["input"]?.intValue ?? 0
        output = v?["output"]?.intValue ?? 0
        total = v?["total"]?.intValue ?? 0
        contextUsed = v?["context_used"]?.intValue
        contextMax = v?["context_max"]?.intValue
        contextPercent = v?["context_percent"]?.intValue
        activeSubagents = v?["active_subagents"]?.intValue
    }
}

/// Stable structured failure descriptor emitted by current Hermes. The
/// descriptor is advisory, but a present malformed value is kept distinct
/// from an older gateway that omitted it.
public struct TurnErrorSurface: Codable, Sendable, Equatable {
    public enum Layer: String, Codable, Sendable, CaseIterable {
        case provider, endpoint, streaming, auth, billing, gateway, runtime, disk
    }

    public static let maximumCodeScalars = 128
    public static let maximumIdentityScalars = 256

    public var layer: Layer
    public var code: String
    public var retryable: Bool
    public var provider: String?
    public var model: String?

    public init(layer: Layer, code: String, retryable: Bool,
                provider: String? = nil, model: String? = nil) {
        self.layer = layer
        self.code = code
        self.retryable = retryable
        self.provider = provider
        self.model = model
    }

    public init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        guard case .value(let surface) = TurnErrorSurfaceCodec.admit(raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Malformed or unsafe turn error surface"))
        }
        self = surface
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(layer, forKey: .layer)
        try container.encode(code, forKey: .code)
        try container.encode(retryable, forKey: .retryable)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encodeIfPresent(model, forKey: .model)
    }

    private enum CodingKeys: String, CodingKey {
        case layer, code, retryable, provider, model
    }
}

public enum TurnErrorSurfaceAdmission: Sendable, Equatable {
    case absent
    case malformed
    case value(TurnErrorSurface)

    public var surface: TurnErrorSurface? {
        if case .value(let surface) = self { return surface }
        return nil
    }

    public var isMalformed: Bool {
        if case .malformed = self { return true }
        return false
    }
}

enum TurnErrorSurfaceCodec {
    static func admit(_ value: JSONValue?) -> TurnErrorSurfaceAdmission {
        guard let value, value != .null else { return .absent }
        guard let object = value.objectValue,
              let layerText = object["layer"]?.stringValue,
              let layer = TurnErrorSurface.Layer(rawValue: layerText) else { return .malformed }

        let code: String
        if let rawCode = object["code"] {
            if let codeText = rawCode.stringValue {
                guard isWithinSafeBound(codeText, maximum: TurnErrorSurface.maximumCodeScalars)
                else { return .malformed }
                code = hasVisibleScalar(codeText) ? codeText : "unknown"
            } else {
                // Desktop treats a non-string code like an omitted one.
                code = "unknown"
            }
        } else {
            code = "unknown"
        }
        // Current producers send an exact Bool. Compatibility matches pinned
        // Desktop: only literal false disables retry; absent/foreign values
        // remain retryable rather than hiding an otherwise valid layer.
        let retryable = object["retryable"]?.boolValue != false

        return .value(TurnErrorSurface(layer: layer, code: code, retryable: retryable,
                                       provider: optionalField(object, key: "provider"),
                                       model: optionalField(object, key: "model")))
    }

    private static func optionalField(_ object: [String: JSONValue], key: String)
        -> String? {
        guard let raw = object[key] else { return nil }
        guard let string = raw.stringValue,
              isWithinSafeBound(string, maximum: TurnErrorSurface.maximumIdentityScalars),
              hasVisibleScalar(string) else { return nil }
        return string
    }

    /// Work is bounded before whitespace/control inspection. Reject rather
    /// than truncate: code/provider/model are diagnostic identity, and a
    /// clipped value would name a different failure.
    private static func isWithinSafeBound(_ value: String, maximum: Int) -> Bool {
        let bounded = value.unicodeScalars.prefix(maximum + 1)
        guard bounded.count <= maximum else { return false }
        for scalar in bounded {
            if isUnsafeControl(scalar.value) { return false }
        }
        return true
    }

    private static func hasVisibleScalar(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    private static func isUnsafeControl(_ value: UInt32) -> Bool {
        if value <= 0x1F || (0x7F...0x9F).contains(value) { return true }
        switch value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        default:
            return false
        }
    }
}

public struct MessageCompletePayload: Sendable {
    public enum Status: String, Sendable { case complete, interrupted, error, malformed }
    public var text: String
    public var status: Status
    public var usage: Usage
    public var reasoning: String?
    public var warning: String?
    public var error: String?
    public var recoverable: Bool
    public var partial: Bool
    public var errorSurfaceAdmission: TurnErrorSurfaceAdmission

    public var errorSurface: TurnErrorSurface? { errorSurfaceAdmission.surface }

    public init(_ v: JSONValue?) {
        text = v?["text"]?.stringValue ?? ""
        if let rawStatus = v?["status"] {
            status = rawStatus.stringValue.flatMap(Status.init(rawValue:)) ?? .malformed
        } else {
            // Older gateways omitted status on successful terminal frames.
            status = .complete
        }
        usage = Usage(v?["usage"])
        reasoning = v?["reasoning"]?.stringValue
        warning = v?["warning"]?.stringValue
        error = v?["error"]?.stringValue
        recoverable = v?["recoverable"]?.boolValue ?? false
        partial = v?["partial"]?.boolValue ?? false
        errorSurfaceAdmission = TurnErrorSurfaceCodec.admit(v?["error_surface"])
    }
}

/// Typed view of `session.resume.live.inflight`. Healthy running snapshots
/// omit status/error; retained failed snapshots carry the same descriptor as
/// the terminal `message.complete` frame.
public enum RetainedInflightTurnAdmission: Sendable, Equatable {
    case absent
    case malformed
    case value(RetainedInflightTurn)

    public var turn: RetainedInflightTurn? {
        if case .value(let turn) = self { return turn }
        return nil
    }

    static func admit(_ value: JSONValue?) -> RetainedInflightTurnAdmission {
        guard let value, value != .null else { return .absent }
        guard let turn = RetainedInflightTurn(value) else { return .malformed }
        return .value(turn)
    }
}

public struct RetainedInflightTurn: Sendable, Equatable {
    public static let maximumCorrections = 32
    public static let maximumCorrectionScalars = 4_096
    public static let maximumUserScalars = 65_536
    public static let maximumAssistantScalars = 65_536
    public static let maximumErrorScalars = 8_192
    /// Must match the live terminal admission marker: failure message identity
    /// is used for resume dedupe and the user's local Dismiss fence.
    private static let primaryClippedMarker = "\n… [turn detail clipped]"
    private static let correctionClippedMarker = "\n… [correction clipped]"
    private static let correctionRemovedMarker = "[correction content removed]"

    public var user: String?
    public var assistant: String?
    public var corrections: [String]
    public var correctionOffsets: [Int]?
    /// True when correction text/count exceeded admission or the offsets were
    /// present but not an exact nonnegative integer vector. The UI may use its
    /// safe legacy placement, but must not trust/reparse the raw array.
    public var correctionsMalformed: Bool
    public var streaming: Bool
    public var error: String?
    public var status: MessageCompletePayload.Status?
    public var recoverable: Bool?
    public var errorSurfaceAdmission: TurnErrorSurfaceAdmission

    public var errorSurface: TurnErrorSurface? { errorSurfaceAdmission.surface }

    init?(_ value: JSONValue?) {
        guard let object = value?.objectValue else { return nil }
        user = Self.admitPrimary(object["user"], maximum: Self.maximumUserScalars)
        assistant = Self.admitPrimary(object["assistant"], maximum: Self.maximumAssistantScalars)
        let correctionAdmission = Self.admitCorrections(object["corrections"])
        corrections = correctionAdmission.values
        let offsetAdmission = Self.admitOffsets(object["correction_offsets"],
                                                expectedCount: corrections.count)
        correctionOffsets = offsetAdmission.values
        correctionsMalformed = correctionAdmission.malformed || offsetAdmission.malformed
        streaming = object["streaming"]?.boolValue ?? false
        error = Self.admitPrimary(object["error"], maximum: Self.maximumErrorScalars)
        if let rawStatus = object["status"] {
            status = rawStatus.stringValue.flatMap(MessageCompletePayload.Status.init(rawValue:))
                ?? .malformed
        } else {
            status = nil
        }
        recoverable = object["recoverable"]?.boolValue
        errorSurfaceAdmission = TurnErrorSurfaceCodec.admit(object["error_surface"])
    }

    /// Keep retained turn bodies finite before projection performs trimming,
    /// splitting, or scalar indexing. A separate raw-work cap lets dense
    /// controls consume finite work without hiding all following safe text.
    /// The returned value, including its marker, never exceeds `maximum`.
    private static func admitPrimary(_ value: JSONValue?, maximum: Int) -> String? {
        guard let string = value?.stringValue else { return nil }
        let markerScalars = primaryClippedMarker.unicodeScalars
        let markerCount = markerScalars.count
        let rawWorkMaximum = maximum * 4
        let raw = string.unicodeScalars.prefix(rawWorkMaximum + 1)
        let rawWasClipped = raw.count > rawWorkMaximum
        var safe = String.UnicodeScalarView()
        safe.reserveCapacity(maximum + 1)
        var safeCount = 0
        for scalar in raw.prefix(rawWorkMaximum) {
            if scalar.value == 0x09 || scalar.value == 0x0A {
                safe.append(scalar)
                safeCount += 1
            } else if !isUnsafePrimaryControl(scalar.value) {
                safe.append(scalar)
                safeCount += 1
            }
            if safeCount > maximum { break }
        }
        guard rawWasClipped || safeCount > maximum else { return String(safe) }
        let contentCount = max(0, maximum - markerCount)
        var clipped = String.UnicodeScalarView(safe.prefix(contentCount))
        clipped.append(contentsOf: markerScalars.prefix(maximum - clipped.count))
        return String(clipped)
    }

    private static func isUnsafePrimaryControl(_ value: UInt32) -> Bool {
        if value <= 0x1F || (0x7F...0x9F).contains(value) { return true }
        switch value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        default:
            return false
        }
    }

    private static func admitCorrections(_ value: JSONValue?)
        -> (values: [String], malformed: Bool) {
        guard let value else { return ([], false) }
        guard let array = value.arrayValue else { return ([], true) }
        var values: [String] = []
        var malformed = array.count > maximumCorrections
        let retainedCount = array.count > maximumCorrections
            ? maximumCorrections - 1 : array.count
        for candidate in array.prefix(retainedCount) {
            guard let string = candidate.stringValue else { malformed = true; continue }
            let admission = admitCorrection(string)
            values.append(admission.value)
            malformed = malformed || admission.clipped
        }
        if array.count > maximumCorrections {
            let omitted = array.count - retainedCount
            values.append("[\(omitted) additional corrections omitted]")
        }
        return (values, malformed)
    }

    /// Keep every accepted string correction in its original array position.
    /// A clipped correction is still visible and forces conservative legacy
    /// placement because its original scalar offsets no longer address the
    /// bounded presentation text.
    private static func admitCorrection(_ string: String)
        -> (value: String, clipped: Bool) {
        let markerScalars = correctionClippedMarker.unicodeScalars
        let markerCount = markerScalars.count
        let rawWorkMaximum = maximumCorrectionScalars * 4
        let raw = string.unicodeScalars.prefix(rawWorkMaximum + 1)
        let rawWasClipped = raw.count > rawWorkMaximum
        var safe = String.UnicodeScalarView()
        safe.reserveCapacity(maximumCorrectionScalars + 1)
        var safeCount = 0
        for scalar in raw.prefix(rawWorkMaximum) {
            if scalar.value == 0x09 || scalar.value == 0x0A {
                safe.append(scalar)
                safeCount += 1
            } else if !isUnsafePrimaryControl(scalar.value) {
                safe.append(scalar)
                safeCount += 1
            }
            if safeCount > maximumCorrectionScalars { break }
        }
        guard rawWasClipped || safeCount > maximumCorrectionScalars else {
            if safeCount == 0, !string.unicodeScalars.isEmpty {
                return (correctionRemovedMarker, true)
            }
            return (String(safe), false)
        }
        let contentCount = max(0, maximumCorrectionScalars - markerCount)
        var clipped = String.UnicodeScalarView(safe.prefix(contentCount))
        clipped.append(contentsOf: markerScalars.prefix(
            maximumCorrectionScalars - clipped.count))
        return (String(clipped), true)
    }

    private static func admitOffsets(_ value: JSONValue?, expectedCount: Int)
        -> (values: [Int]?, malformed: Bool) {
        guard let value else { return (nil, false) }
        guard let array = value.arrayValue,
              array.count == expectedCount,
              array.count <= maximumCorrections else { return (nil, true) }
        var values: [Int] = []
        values.reserveCapacity(array.count)
        for candidate in array {
            guard let number = candidate.doubleValue, number.isFinite,
                  number >= 0, number.rounded(.towardZero) == number,
                  number <= Double(Int.max) else { return (nil, true) }
            values.append(Int(number))
        }
        return (values, false)
    }
}

public struct SessionInfo: Sendable, Equatable {
    public var model: String
    public var provider: String?
    public var yolo: Bool
    public var approvalMode: String
    public var cwd: String
    public var running: Bool
    public var title: String
    public var storedSessionID: String
    public var desktopContract: Int
    public var profileName: String
    public var usage: Usage
    public var raw: JSONValue?

    public init(_ v: JSONValue?) {
        model = v?["model"]?.stringValue ?? ""
        provider = v?["provider"]?.stringValue
        yolo = v?["yolo"]?.boolValue ?? false
        approvalMode = v?["approval_mode"]?.stringValue ?? "manual"
        cwd = v?["cwd"]?.stringValue ?? ""
        running = v?["running"]?.boolValue ?? false
        title = v?["title"]?.stringValue ?? ""
        storedSessionID = v?["stored_session_id"]?.stringValue ?? ""
        desktopContract = v?["desktop_contract"]?.intValue ?? 0
        profileName = v?["profile_name"]?.stringValue ?? "default"
        usage = Usage(v?["usage"])
        raw = v
    }
}

public struct ToolStartPayload: Sendable {
    public var toolID: String
    public var name: String
    /// ≤80-char argument preview.
    public var context: String
    public var arguments: ToolPayload?

    public init(_ v: JSONValue?) {
        toolID = ToolPayloadCodec.admittedIdentity(v?["tool_id"]?.stringValue
            ?? v?["tool_call_id"]?.stringValue
            ?? v?["id"]?.stringValue,
            maximum: ToolPayloadCodec.maximumToolIdentityCharacters) ?? ""
        name = ToolPayloadCodec.admittedIdentity(
            v?["name"]?.stringValue,
            maximum: ToolPayloadCodec.maximumToolNameCharacters) ?? ""
        let supplied = v?["context"]?.stringValue
        let preview = v?["preview"]?.stringValue
        context = ToolPayloadCodec.boundedText(
            (supplied?.isEmpty == false ? supplied : preview) ?? "", maximum: 80)
        arguments = ToolPayloadCodec.directArguments(
            from: v?["args"] ?? v?["arguments"] ?? v?["input"])
    }
}

public struct ToolCompletePayload: Sendable {
    public var toolID: String
    public var name: String
    public var durationSeconds: Double?
    public var summary: String?
    public var resultText: String?
    public var arguments: ToolPayload?
    public var result: ToolPayload?
    public var fileDiff: ToolFileDiff?
    public var structuredOutput: ToolStructuredOutput?
    public var deferredStructuredOutput: ToolStructuredOutput?
    public var deferredFileDiff: ToolFileDiff?

    public init(_ v: JSONValue?) {
        toolID = ToolPayloadCodec.admittedIdentity(v?["tool_id"]?.stringValue
            ?? v?["tool_call_id"]?.stringValue
            ?? v?["id"]?.stringValue,
            maximum: ToolPayloadCodec.maximumToolIdentityCharacters) ?? ""
        name = ToolPayloadCodec.admittedIdentity(
            v?["name"]?.stringValue,
            maximum: ToolPayloadCodec.maximumToolNameCharacters) ?? ""
        durationSeconds = v?["duration_s"]?.doubleValue
        let supplied = v?["summary"]?.stringValue
        let preview = v?["preview"]?.stringValue
        summary = (supplied?.isEmpty == false ? supplied : preview).map {
            ToolPayloadCodec.boundedText(
                $0, maximum: ToolPayloadCodec.maximumDiagnosticCharacters)
        }
        arguments = ToolPayloadCodec.directArguments(
            from: v?["args"] ?? v?["arguments"] ?? v?["input"])
        let rawResult = v?["result"] ?? v?["result_text"]
        let outputAdmission = ToolOutputCodec.admit(toolName: name, result: rawResult)
        result = outputAdmission.genericResult
        resultText = result?.displayText
        let candidate = ToolDiffCodec.candidate(
            arguments: v?["args"] ?? v?["arguments"] ?? v?["input"],
            result: v?["result"] ?? v?["result_text"],
            inlineDiff: v?["inline_diff"])
        fileDiff = ToolDiffCodec.isFileEditTool(name) ? candidate : nil
        structuredOutput = outputAdmission.output
        deferredStructuredOutput = name.isEmpty
            ? ToolOutputCodec.candidate(result: rawResult) : nil
        deferredFileDiff = fileDiff == nil ? candidate : nil
    }
}

/// A live approval request. The agent thread is blocked on this until the
/// client answers `approval.respond` (or the ~300 s timeout denies it).
public struct ApprovalRequest: Sendable, Identifiable, Equatable {
    public var id: String { requestID }
    public var sessionID: String
    public var requestID: String
    /// Redacted command / action text.
    public var command: String
    public var description: String
    public var patternKey: String?
    public var allowPermanent: Bool
    public var allowSession: Bool
    /// e.g. ["once","session","always","deny"]
    public var choices: [String]

    public init(_ v: JSONValue?, sessionID: String) {
        self.sessionID = sessionID
        requestID = v?["request_id"]?.stringValue ?? ""
        command = v?["command"]?.stringValue ?? ""
        description = v?["description"]?.stringValue ?? ""
        patternKey = v?["pattern_key"]?.stringValue
        allowPermanent = v?["allow_permanent"]?.boolValue ?? false
        allowSession = v?["allow_session"]?.boolValue ?? false
        choices = v?["choices"]?.arrayValue?.compactMap(\.stringValue) ?? ["once", "deny"]
    }
}

public enum ApprovalChoice: String, Sendable {
    case once, session, always, deny
}

public struct ClarifyRequest: Sendable, Equatable {
    public var sessionID: String
    public var requestID: String
    public var question: String
    public var choices: [String]
    public var multiSelect: Bool

    public init(_ v: JSONValue?, sessionID: String) {
        self.sessionID = sessionID
        requestID = v?["request_id"]?.stringValue ?? ""
        question = v?["question"]?.stringValue ?? ""
        choices = v?["choices"]?.arrayValue?.compactMap(\.stringValue) ?? []
        multiSelect = v?["multi_select"]?.boolValue ?? false
    }
}

/// The small, explicit part of a `session.resume` projection that can prove
/// an already-buffered event is represented by that projection. Hermes' cold
/// resume also carries inflight/tool/status/notification state, but those
/// shapes are not durable message rows and therefore must never be inferred
/// from a transport sequence alone.
public struct ResumeMessageEvidence: Sendable, Equatable {
    public let rowID: String?
    public let role: String
    public let text: String

    public init(_ value: JSONValue) {
        rowID = Self.identity(value["row_id"] ?? value["id"])
        role = value["role"]?.stringValue ?? ""
        text = value["text"]?.stringValue
            ?? value["content"]?.stringValue
            ?? ""
    }

    private static func identity(_ value: JSONValue?) -> String? {
        if let string = value?.stringValue, !string.isEmpty { return string }
        if let number = value?.intValue { return String(number) }
        return nil
    }
}

/// Evidence carried by the authoritative `session.resume` response. This is
/// deliberately conservative: only events with an exact row/state match are
/// suppressible. Tool/status/notification/voice events are not represented
/// here and are always replayed even when their frame is older than resume.
public struct ResumeSnapshotEvidence: Sendable, Equatable {
    public let messages: [ResumeMessageEvidence]
    public let info: SessionInfo
    public let pendingApproval: ApprovalRequest?
    public let pendingClarify: JSONValue?

    public init(session: LiveSession) {
        messages = session.messages.map(ResumeMessageEvidence.init)
        info = session.info
        pendingApproval = session.pendingApproval
        pendingClarify = session.pendingClarify
    }

    /// A sequence position is only a replay-boundary hint; it is not evidence
    /// that an arbitrary event was included in the snapshot.
    public func represents(_ event: GatewayEvent) -> Bool {
        switch event.type {
        case "message.complete":
            let payload = event.payload
            let status = payload?["status"]?.stringValue ?? "complete"
            guard status == "complete" else { return false }
            let text = payload?["text"]?.stringValue
                ?? payload?["content"]?.stringValue
                ?? ""
            let rowID = payload?["row_id"]?.stringValue
                ?? payload?["id"]?.stringValue
                ?? payload?["row_id"]?.intValue.map(String.init)
                ?? payload?["id"]?.intValue.map(String.init)
            let matches = messages.filter { message in
                guard message.role == "assistant", message.text == text else {
                    return false
                }
                if let rowID { return message.rowID == rowID }
                return true
            }
            // Duplicate assistant text is not enough evidence without the
            // durable row id; retaining it is safer than dropping a message.
            return matches.count == 1

        case "session.info":
            return SessionInfo(event.payload) == info

        case "session.title":
            guard let stored = event.payload?["session_id"]?.stringValue,
                  stored == info.storedSessionID else { return false }
            return event.payload?["title"]?.stringValue == info.title

        case "session.usage":
            let usageValue = event.payload?["usage"] ?? event.payload
            return Usage(usageValue) == info.usage

        case "approval.request":
            guard let pendingApproval else { return false }
            return ApprovalRequest(event.payload, sessionID: event.sessionID)
                == pendingApproval

        case "clarify.request":
            return pendingClarify == event.payload

        default:
            // message.delta, tool.*, status.update, notifications, voice,
            // and every other event have no exact durable representation in
            // this snapshot and must not be filtered by sequence.
            return false
        }
    }
}

public struct NotificationPayload: Sendable {
    public var text: String
    public var level: String
    public var kind: String
    public var ttlMilliseconds: Int?
    public var key: String?
    public var id: String?

    public init(_ v: JSONValue?) {
        text = v?["text"]?.stringValue ?? ""
        level = v?["level"]?.stringValue ?? "info"
        kind = v?["kind"]?.stringValue ?? ""
        ttlMilliseconds = v?["ttl_ms"]?.intValue
        key = v?["key"]?.stringValue
        id = v?["id"]?.stringValue
    }
}
