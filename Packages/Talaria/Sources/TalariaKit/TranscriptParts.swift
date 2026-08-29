import Foundation

/// Bounded presentation-only counterpart of Hermes' additive transcript
/// `parts_version: 1` contract. Legacy `text` remains stored separately on
/// `ChatMessage` and is the fallback whenever this envelope is absent.
public struct TranscriptPartsEnvelope: Codable, Sendable, Equatable {
    public var version: Int
    public var parts: [TranscriptPart]
    public var clipped: Bool

    public init(version: Int = 1, parts: [TranscriptPart], clipped: Bool = false) {
        self.version = version
        self.parts = Array(parts.prefix(TranscriptPartsCodec.maximumParts))
        self.clipped = clipped || parts.count > TranscriptPartsCodec.maximumParts
    }

    public init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        guard let admitted = TranscriptPartsCodec.admitCanonical(raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Malformed ordered transcript parts"))
        }
        self = admitted
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(parts, forKey: .parts)
        try container.encode(clipped, forKey: .clipped)
    }

    private enum CodingKeys: String, CodingKey { case version, parts, clipped }
}

public struct TranscriptPart: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case text, reasoning, image, audio, file
        case toolCall = "tool-call"
        case toolResult = "tool-result"
        case unknown, clipped, malformed
    }

    public var kind: Kind
    /// Exact unrecognized wire kind for inert evidence; nil for known kinds.
    public var sourceKind: String?
    public var id: String?
    public var name: String?
    public var text: String?
    public var ref: String?
    public var mimeType: String?
    public var contentKind: String?
    public var evidence: String?
    public var reason: String?
    public var isClipped: Bool
    public var timestamp: Double?
    public var completedAt: Double?
    public var arguments: JSONValue?
    public var value: JSONValue?

    public init(kind: Kind, sourceKind: String? = nil, id: String? = nil,
                name: String? = nil, text: String? = nil, ref: String? = nil,
                mimeType: String? = nil, contentKind: String? = nil,
                evidence: String? = nil, reason: String? = nil,
                isClipped: Bool = false, timestamp: Double? = nil,
                completedAt: Double? = nil, arguments: JSONValue? = nil,
                value: JSONValue? = nil) {
        self.kind = kind; self.sourceKind = sourceKind; self.id = id; self.name = name
        self.text = text; self.ref = ref; self.mimeType = mimeType
        self.contentKind = contentKind; self.evidence = evidence; self.reason = reason
        self.isClipped = isClipped; self.timestamp = timestamp
        self.completedAt = completedAt; self.arguments = arguments; self.value = value
    }

    public init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        let envelope = JSONValue.object([
            "version": .number(1), "parts": .array([raw]),
        ])
        guard let admitted = TranscriptPartsCodec.admitCanonical(envelope),
              let first = admitted.parts.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Malformed ordered transcript part"))
        }
        self = first
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encodeIfPresent(sourceKind, forKey: .sourceType)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(ref, forKey: .ref)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(contentKind, forKey: .contentKind)
        try container.encodeIfPresent(evidence, forKey: .evidence)
        try container.encodeIfPresent(reason, forKey: .reason)
        if isClipped { try container.encode(true, forKey: .clipped) }
        try container.encodeIfPresent(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encodeIfPresent(arguments, forKey: .arguments)
        try container.encodeIfPresent(value, forKey: .value)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, id, name, text, ref, evidence, reason, clipped, timestamp, arguments, value
        case sourceType = "source_type"
        case mimeType = "mime_type"
        case contentKind = "content_kind"
        case completedAt = "completed_at"
    }
}

public enum TranscriptPartsMode: String, Codable, Sendable, Equatable {
    case append, replace, seal
}

public struct TranscriptPartsUpdate: Sendable, Equatable {
    public var envelope: TranscriptPartsEnvelope
    public var mode: TranscriptPartsMode

    public init(envelope: TranscriptPartsEnvelope,
                mode: TranscriptPartsMode = .replace) {
        self.envelope = envelope; self.mode = mode
    }
}

public enum TranscriptPartsCodec {
    public static let version = 1
    public static let maximumParts = 64
    public static let maximumNodes = 256
    public static let maximumDepth = 8
    public static let maximumScalars = 65_536
    public static let maximumBytes = 256 * 1_024
    public static let maximumStringScalars = 16_384
    public static let maximumReferenceScalars = 4_096
    public static let maximumIdentityScalars = 256
    /// Reserve ample space for bounded keys/container syntax so the complete
    /// encoded envelope remains below Hermes' 256 KiB ceiling.
    private static let maximumContentBytes = 128 * 1_024

    /// Decode additive wire fields. Missing fields mean an old gateway and do
    /// not synthesize an envelope. Present malformed fields retain the legacy
    /// body plus explicit inert malformed evidence.
    public static func update(
        from value: JSONValue?, partsKey: String = "parts",
        clippedKey: String = "parts_clipped", modeKey: String = "parts_mode",
        inheritedVersion: Int? = nil, legacyText: String? = nil,
        legacyReasoning: String? = nil, defaultMode: TranscriptPartsMode = .replace
    ) -> TranscriptPartsUpdate? {
        guard let object = value?.objectValue, object[partsKey] != nil else { return nil }
        let rawVersion = inheritedVersion ?? exactInteger(object["parts_version"])
        let rawMode = object[modeKey]?.stringValue
        let mode = rawMode.flatMap(TranscriptPartsMode.init(rawValue:)) ?? defaultMode
        if let rawMode, TranscriptPartsMode(rawValue: rawMode) == nil {
            return TranscriptPartsUpdate(
                envelope: malformedFallback(text: legacyText, reasoning: legacyReasoning),
                mode: defaultMode)
        }
        guard rawVersion == version, let rawParts = object[partsKey]?.arrayValue else {
            return TranscriptPartsUpdate(
                envelope: malformedFallback(text: legacyText, reasoning: legacyReasoning),
                mode: mode)
        }
        return TranscriptPartsUpdate(
            envelope: admit(rawParts, clipped: object[clippedKey]?.boolValue == true),
            mode: mode)
    }

    public static func apply(_ update: TranscriptPartsUpdate,
                             to current: TranscriptPartsEnvelope?)
        -> TranscriptPartsEnvelope {
        switch update.mode {
        case .replace:
            return update.envelope
        case .append:
            return admitCanonicalParts(
                coalescingStreamText((current?.parts ?? []) + update.envelope.parts),
                clipped: (current?.clipped ?? false) || update.envelope.clipped)
        case .seal:
            // `seal` describes an interim boundary already delivered by prior
            // append frames. If those frames are absent, retain the bounded
            // seal evidence rather than losing the segment.
            guard let current, !current.parts.isEmpty else { return update.envelope }
            return current
        }
    }

    public static func appendLocalStreamText(
        _ text: String, kind: TranscriptPart.Kind, id: String,
        to current: TranscriptPartsEnvelope?
    ) -> TranscriptPartsEnvelope? {
        guard !text.isEmpty, kind == .text || kind == .reasoning,
              !id.isEmpty else { return current }
        let update = TranscriptPartsUpdate(
            envelope: TranscriptPartsEnvelope(parts: [
                TranscriptPart(kind: kind, id: id, text: text),
            ]), mode: .append)
        return apply(update, to: current)
    }

    /// Reconstruct the additive contract's legacy assistant body without
    /// interpreting directives or references. The envelope has already passed
    /// the scalar/byte/part budgets, so this concatenation is bounded. Callers
    /// still run the result through the established whole-message echo/MEDIA
    /// projections before display, copy, voice, or find.
    public static func legacyText(in envelope: TranscriptPartsEnvelope) -> String {
        var result = ""
        for part in envelope.parts where part.kind == .text {
            if let text = part.text { result += text }
        }
        return result
    }

    /// Hermes emits one `assistant-stream` text part per delta. Compact only
    /// adjacent text-like frames with the same nonempty stable id before the
    /// 64-part admission cap; structural ordering remains untouched.
    private static func coalescingStreamText(_ parts: [TranscriptPart]) -> [TranscriptPart] {
        var result: [TranscriptPart] = []
        result.reserveCapacity(min(parts.count, maximumParts))
        for part in parts {
            if var last = result.last,
               (part.kind == .text || part.kind == .reasoning),
               part.kind == last.kind,
               let id = part.id, !id.isEmpty, last.id == id,
               part.sourceKind == nil, last.sourceKind == nil {
                last.text = (last.text ?? "") + (part.text ?? "")
                last.isClipped = last.isClipped || part.isClipped
                result[result.count - 1] = last
            } else {
                result.append(part)
            }
        }
        return result
    }

    public static func admitCanonical(_ value: JSONValue) -> TranscriptPartsEnvelope? {
        guard let object = value.objectValue,
              exactInteger(object["version"] ?? object["parts_version"]) == version,
              let parts = object["parts"]?.arrayValue else { return nil }
        return admit(parts, clipped: object["clipped"]?.boolValue == true
                     || object["parts_clipped"]?.boolValue == true)
    }

    private static func admitCanonicalParts(_ parts: [TranscriptPart], clipped: Bool)
        -> TranscriptPartsEnvelope {
        guard let raw = try? JSONValue.from(parts) else {
            return malformedFallback(text: nil, reasoning: nil)
        }
        return admit(raw.arrayValue ?? [], clipped: clipped)
    }

    private static func admit(_ rawParts: [JSONValue], clipped suppliedClipped: Bool)
        -> TranscriptPartsEnvelope {
        var budget = Budget()
        var admitted: [TranscriptPart] = []
        admitted.reserveCapacity(min(rawParts.count, maximumParts))
        var clipped = suppliedClipped || rawParts.count > maximumParts
        for raw in rawParts.prefix(maximumParts) {
            guard budget.takeNode() else { clipped = true; break }
            admitted.append(admitPart(raw, budget: &budget))
            clipped = clipped || budget.clipped
        }
        if clipped || budget.clipped {
            admitted.removeAll { $0.kind == .clipped }
            if admitted.count >= maximumParts { admitted.removeLast() }
            admitted.append(TranscriptPart(kind: .clipped, reason: "budget", isClipped: true))
        }
        return TranscriptPartsEnvelope(parts: admitted, clipped: clipped || budget.clipped)
    }

    private static func admitPart(_ raw: JSONValue, budget: inout Budget) -> TranscriptPart {
        guard let object = raw.objectValue else {
            budget.clipped = true
            return TranscriptPart(kind: .malformed,
                                  evidence: rawType(raw), isClipped: true)
        }
        let rawKind = boundedString(object["kind"]?.stringValue ?? "unknown",
                                    maximum: maximumIdentityScalars, budget: &budget)
        let known = TranscriptPart.Kind(rawValue: rawKind)
        let kind = known ?? .unknown
        let explicitSourceKind = identity(object["source_type"], budget: &budget)
        var part = TranscriptPart(
            kind: kind,
            sourceKind: kind == .unknown
                ? (explicitSourceKind ?? (known == nil ? rawKind : nil)) : nil,
            id: identity(object["id"], budget: &budget),
            name: identity(object["name"], budget: &budget),
            text: optionalString(object["text"], maximum: maximumStringScalars,
                                 budget: &budget),
            ref: inertReference(object["ref"], budget: &budget),
            mimeType: identity(object["mime_type"], budget: &budget),
            contentKind: identity(object["content_kind"], budget: &budget),
            evidence: optionalString(object["evidence"], maximum: maximumStringScalars,
                                     budget: &budget),
            reason: identity(object["reason"], budget: &budget),
            isClipped: object["clipped"]?.boolValue == true,
            timestamp: finiteTime(object["timestamp"]),
            completedAt: finiteTime(object["completed_at"]))
        if let arguments = object["arguments"] {
            part.arguments = boundedJSON(arguments, depth: 0, budget: &budget)
        }
        if let value = object["value"] {
            part.value = boundedJSON(value, depth: 0, budget: &budget)
        }
        if kind == .unknown || kind == .malformed { part.isClipped = true; budget.clipped = true }
        return part
    }

    private static func boundedJSON(_ raw: JSONValue, depth: Int,
                                    budget: inout Budget) -> JSONValue {
        guard depth <= maximumDepth else {
            budget.clipped = true
            return .object(["clipped": .bool(true), "reason": .string("depth")])
        }
        guard budget.takeNode() else {
            return .object(["clipped": .bool(true), "reason": .string("nodes")])
        }
        switch raw {
        case .null, .bool:
            budget.takeScalar(); return raw
        case .number(let number):
            guard number.isFinite, abs(number) <= 1_000_000_000_000 else {
                budget.clipped = true
                return .object(["clipped": .bool(true), "reason": .string("number")])
            }
            budget.takeScalar(); return raw
        case .string(let string):
            return .string(boundedString(string, maximum: maximumStringScalars,
                                         budget: &budget))
        case .array(let values):
            var output: [JSONValue] = []
            for value in values.prefix(maximumParts) where budget.nodes < maximumNodes {
                output.append(boundedJSON(value, depth: depth + 1, budget: &budget))
            }
            if values.count > output.count { budget.clipped = true }
            return .array(output)
        case .object(let object):
            var output: [String: JSONValue] = [:]
            var inspected = 0
            for (key, value) in object {
                guard inspected < maximumNodes, budget.nodes < maximumNodes else {
                    budget.clipped = true; break
                }
                inspected += 1
                let safeKey = boundedString(key, maximum: maximumIdentityScalars,
                                            budget: &budget)
                guard !safeKey.isEmpty else { budget.clipped = true; continue }
                output[safeKey] = boundedJSON(value, depth: depth + 1, budget: &budget)
            }
            return .object(output)
        }
    }

    private static func malformedFallback(text: String?, reasoning: String?)
        -> TranscriptPartsEnvelope {
        var budget = Budget()
        var parts: [TranscriptPart] = []
        if let reasoning, !reasoning.isEmpty {
            parts.append(TranscriptPart(kind: .reasoning,
                                        text: boundedString(
                                            reasoning, maximum: maximumStringScalars,
                                            budget: &budget)))
        }
        if let text, !text.isEmpty {
            parts.append(TranscriptPart(kind: .text,
                                        text: boundedString(
                                            text, maximum: maximumStringScalars,
                                            budget: &budget)))
        }
        parts.append(TranscriptPart(kind: .malformed,
                                    evidence: "ordered parts", isClipped: true))
        return TranscriptPartsEnvelope(parts: parts, clipped: true)
    }

    private static func identity(_ value: JSONValue?, budget: inout Budget) -> String? {
        guard let raw = value?.stringValue else { return nil }
        let safe = boundedString(raw, maximum: maximumIdentityScalars, budget: &budget)
        return safe.isEmpty ? nil : safe
    }

    private static func optionalString(_ value: JSONValue?, maximum: Int,
                                       budget: inout Budget) -> String? {
        guard let raw = value?.stringValue else { return nil }
        return boundedString(raw, maximum: maximum, budget: &budget)
    }

    private static func boundedString(_ raw: String, maximum: Int,
                                      budget: inout Budget) -> String {
        var output = String.UnicodeScalarView()
        output.reserveCapacity(min(maximum, 256))
        var count = 0
        for scalar in raw.unicodeScalars.prefix(maximum + 1) {
            guard count < maximum, budget.scalars < maximumScalars else {
                budget.clipped = true; break
            }
            if isUnsafeControl(scalar.value) && scalar.value != 0x09 && scalar.value != 0x0A {
                budget.clipped = true; continue
            }
            let bytes = String(scalar).utf8.count
            guard budget.bytes <= maximumContentBytes - bytes else {
                budget.clipped = true; break
            }
            output.append(scalar); count += 1
            budget.scalars += 1; budget.bytes += bytes
        }
        if raw.unicodeScalars.prefix(maximum + 1).count > maximum { budget.clipped = true }
        return String(output)
    }

    private static func inertReference(_ value: JSONValue?, budget: inout Budget) -> String? {
        guard let rawValue = value?.stringValue else { return nil }
        let raw = boundedString(rawValue, maximum: maximumReferenceScalars, budget: &budget)
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("data:") {
            budget.clipped = true
            return String(raw.prefix { $0 != "," })
        }
        if raw.hasPrefix("@image:") {
            let name = raw.dropFirst(7).replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/").last.map(String.init) ?? "attachment"
            if raw != "@image:\(name)" { budget.clipped = true }
            return "@image:\(name)"
        }
        if raw.hasPrefix("/") || raw.hasPrefix("file:")
            || raw.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil {
            budget.clipped = true; return "file:local"
        }
        if var components = URLComponents(string: raw),
           components.scheme == "http" || components.scheme == "https" {
            components.user = nil; components.password = nil
            if components.query != nil || components.fragment != nil { budget.clipped = true }
            components.query = nil; components.fragment = nil
            return components.string
        }
        return raw
    }

    private static func finiteTime(_ value: JSONValue?) -> Double? {
        guard let number = value?.doubleValue, number.isFinite,
              number >= 0, number <= 1_000_000_000_000 else { return nil }
        return number
    }

    private static func exactInteger(_ value: JSONValue?) -> Int? {
        guard let number = value?.doubleValue, number.isFinite,
              number.rounded(.towardZero) == number,
              number >= 0, number <= Double(Int.max) else { return nil }
        return Int(number)
    }

    private static func rawType(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "bool"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    private static func isUnsafeControl(_ value: UInt32) -> Bool {
        if value <= 0x1F || (0x7F...0x9F).contains(value) { return true }
        return value == 0x061C || value == 0x200E || value == 0x200F
            || (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value)
    }

    private struct Budget {
        var nodes = 0; var scalars = 0; var bytes = 0; var clipped = false
        mutating func takeNode() -> Bool {
            guard nodes < maximumNodes else { clipped = true; return false }
            nodes += 1; return true
        }
        mutating func takeScalar() {
            guard scalars < maximumScalars else { clipped = true; return }
            scalars += 1
        }
    }
}
