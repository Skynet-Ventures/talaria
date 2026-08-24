import Foundation

public struct ToolStructuredOutput: Codable, Sendable, Equatable {
    public var stdout: ToolOutputStream?
    public var stderr: ToolOutputStream?
    /// Non-stream result metadata (exit_code, pid, etc.) retained separately
    /// so a large stdout cannot make it silently disappear with ToolPayload.json.
    public var residualText: String?
    public var residualIsTruncated: Bool
    public var diagnostic: String?

    public init(stdout: ToolOutputStream? = nil, stderr: ToolOutputStream? = nil,
                residualText: String? = nil, residualIsTruncated: Bool = false,
                diagnostic: String? = nil) {
        self.stdout = stdout
        self.stderr = stderr
        self.residualText = residualText
        self.residualIsTruncated = residualIsTruncated
        self.diagnostic = diagnostic
    }

    /// Repeated exact completions may be sparse. New fields supersede their
    /// matching old field, while omitted channels/metadata remain durable.
    public static func merging(newer: ToolStructuredOutput?,
                               preserving older: ToolStructuredOutput?) -> ToolStructuredOutput? {
        guard let newer else { return older }
        guard let older else { return newer }
        let replacesResidual = newer.residualText != nil || newer.residualIsTruncated
        return ToolStructuredOutput(
            stdout: newer.stdout ?? older.stdout,
            stderr: newer.stderr ?? older.stderr,
            residualText: replacesResidual ? newer.residualText : older.residualText,
            residualIsTruncated: replacesResidual
                ? newer.residualIsTruncated : older.residualIsTruncated,
            diagnostic: replacesResidual
                ? newer.diagnostic : (newer.diagnostic ?? older.diagnostic))
    }
}

public struct ToolOutputStream: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case available, malformed }

    public var state: State
    public var segments: [ToolANSISegment]
    public var isTruncated: Bool
    public var diagnostic: String?

    public init(state: State, segments: [ToolANSISegment] = [],
                isTruncated: Bool = false, diagnostic: String? = nil) {
        self.state = state
        self.segments = segments
        self.isTruncated = isTruncated
        self.diagnostic = diagnostic
    }

    public var plainText: String { segments.map(\.text).joined() }
    /// Clipboard contract: only the already-sanitized bounded visible stream,
    /// never the original escape-bearing gateway string.
    public var copyText: String { plainText }
}

public struct ToolANSISegment: Codable, Sendable, Equatable, Identifiable {
    public enum Foreground: String, Codable, Sendable, CaseIterable {
        case black, red, green, yellow, blue, magenta, cyan, white
        case brightBlack, brightRed, brightGreen, brightYellow
        case brightBlue, brightMagenta, brightCyan, brightWhite
    }

    public var id: Int
    public var text: String
    public var foreground: Foreground?
    public var bold: Bool

    public init(id: Int, text: String, foreground: Foreground? = nil, bold: Bool = false) {
        self.id = id
        self.text = text
        self.foreground = foreground
        self.bold = bold
    }
}

/// One bounded specialist pass supplies both the rich stream presentation and
/// the generic metadata/failure model. Callers must not independently encode
/// the original terminal result after this admission succeeds.
public struct ToolOutputAdmission: Sendable, Equatable {
    public var output: ToolStructuredOutput?
    public var genericResult: ToolPayload?
    public var hasExplicitError: Bool
}

/// Exact structured-output admission for Hermes terminal and execute_code
/// results. It never promotes arbitrary prose into stdout/stderr.
public enum ToolOutputCodec {
    struct MetadataSelection {
        var entries: [(key: String, value: JSONValue)]
        var inspectedKeyCount: Int
        var wasTruncated: Bool
    }

    public static let maximumStreamScalars = 10_000
    public static let maximumSegments = 256
    public static let maximumResidualScalars = 4_096
    public static let maximumMetadataKeysInspected = 64
    public static let maximumMetadataKeysAdmitted = 64
    /// Parser work is independently capped before scalar materialization.
    /// This leaves room to retain safe visible text after dense terminal
    /// controls without allowing an arbitrarily large escape-bearing input.
    public static let maximumRawWorkScalars = 100_000
    // Two admitted 10k streams can each be JSON-escaped at six scalars per
    // control code, plus wrapper/metadata. Keep that valid worst case inside
    // the decode cap without admitting the multi-megabyte REST envelope.
    private static let maximumContainerScalars = 256_000
    private static let truncationMarker = "\n… [output truncated]"

    public static func isStructuredTool(_ name: String) -> Bool {
        name == "terminal" || name == "execute_code"
    }

    public static func admit(toolName: String, result: JSONValue?) -> ToolOutputAdmission {
        guard isStructuredTool(toolName) else {
            let generic = ToolPayloadCodec.result(from: result)
            return ToolOutputAdmission(
                output: nil, genericResult: generic,
                hasExplicitError: ToolPayloadCodec.resultHasExplicitError(generic))
        }
        guard let container = container(from: result) else {
            let generic: ToolPayload?
            if let text = result?.stringValue, !text.isEmpty {
                let marker = "\n… [truncated]"
                let body = scalarPrefix(
                    text, maximum: ToolPayloadCodec.maximumResultCharacters - marker.unicodeScalars.count)
                generic = ToolPayload(
                    kind: .text,
                    text: body.text + (body.truncated ? marker : ""),
                    isTruncated: body.truncated)
            } else {
                generic = ToolPayloadCodec.result(from: result)
            }
            return ToolOutputAdmission(
                output: nil, genericResult: generic,
                hasExplicitError: ToolPayloadCodec.resultHasExplicitError(generic))
        }
        switch container {
        case .object(let object):
            return admission(from: object)
        case .generic(let value):
            let generic = boundedGenericPayload(from: value)
            return ToolOutputAdmission(
                output: nil, genericResult: generic,
                hasExplicitError: ToolPayloadCodec.resultHasExplicitError(generic))
        }
    }

    public static func extract(toolName: String, result: JSONValue?) -> ToolStructuredOutput? {
        admit(toolName: toolName, result: result).output
    }

    /// Bound explicit stream evidence before a completion's tool name is
    /// available. The returned value is inert: callers must retain it only as
    /// a deferred candidate and promote it after an exact-ID, exact-case
    /// terminal/execute_code start establishes authority.
    public static func candidate(result: JSONValue?) -> ToolStructuredOutput? {
        guard case .object(let object)? = container(from: result) else { return nil }
        return admission(from: object).output
    }

    private static func admission(from object: [String: JSONValue]) -> ToolOutputAdmission {
        let stdout = stream(field: "stdout", in: object)
        let stderr = stream(field: "stderr", in: object)
        let residual = residual(from: object)
        let hasStreams = stdout != nil || stderr != nil
        let output = hasStreams ? ToolStructuredOutput(
                stdout: stdout, stderr: stderr,
                residualText: residual.text,
                residualIsTruncated: residual.truncated,
                diagnostic: residual.diagnostic) : nil
        let generic: ToolPayload?
        if let text = residual.text {
            generic = residual.truncated
                ? ToolPayload(kind: .json, text: text, isTruncated: true)
                : ToolPayloadCodec.result(from: .string(text))
        } else {
            generic = nil
        }
        return ToolOutputAdmission(
            output: output, genericResult: generic,
            hasExplicitError: object["is_error"]?.boolValue == true
                || ToolPayloadCodec.valueIsExplicitError(object["error"]))
    }

    private static func residual(from source: [String: JSONValue])
        -> (text: String?, truncated: Bool, diagnostic: String?) {
        var budget = maximumResidualScalars
        var nodes = 0
        let bounded = boundedMetadataObject(
            source, budget: &budget, nodes: &nodes, depth: 0)
        guard !bounded.value.isEmpty else { return (nil, false, nil) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(JSONValue.object(bounded.value)),
              let text = String(data: data, encoding: .utf8) else {
            return (nil, false, "Talaria could not render the remaining structured result metadata.")
        }
        let marker = "\n… [metadata truncated]"
        let admitted = scalarPrefix(text, maximum: maximumResidualScalars)
        let truncated = bounded.truncated || admitted.truncated
        guard truncated else { return (admitted.text, false, nil) }
        let markerCount = marker.unicodeScalars.count
        let body = scalarPrefix(text, maximum: maximumResidualScalars - markerCount).text
        return (body + marker, true,
                "Additional structured result metadata exceeded the mobile display budget.")
    }

    /// Select a bounded residual root directly from the source dictionary.
    /// This deliberately avoids Dictionary COW/removal and exits the ordinary
    /// source loop after a hard inspection budget; JSONEncoder therefore sees
    /// only a small admitted dictionary to sort and escape.
    private static func boundedMetadataObject(
        _ source: [String: JSONValue], budget: inout Int,
        nodes: inout Int, depth: Int
    ) -> (value: [String: JSONValue], truncated: Bool) {
        let selection = selectMetadata(from: source)
        var result: [String: JSONValue] = [:]
        var truncated = selection.wasTruncated
        for (rawKey, item) in selection.entries {
            let sanitizedKey = parseANSI(rawKey, field: "metadata key")
            let admittedKey = scalarPrefix(
                sanitizedKey.plainText, maximum: min(128, max(1, budget)))
            let safeKey = admittedKey.text
            truncated = truncated || sanitizedKey.isTruncated || admittedKey.truncated
            guard !safeKey.isEmpty, result[safeKey] == nil else {
                truncated = true
                continue
            }
            budget -= min(budget, safeKey.unicodeScalars.count)
            let child = boundedJSON(item, budget: &budget, nodes: &nodes, depth: depth + 1)
            result[safeKey] = child.value
            truncated = truncated || child.truncated
            if budget <= 0 || nodes >= 256 { truncated = true; break }
        }
        return (result, truncated)
    }

    /// The exact selection step used by residual rendering. Internal so tests
    /// can prove its attacker-controlled dictionary iteration is capped,
    /// independently of the final rendered output size.
    static func selectMetadata(from source: [String: JSONValue]) -> MetadataSelection {
        let priority = ["exit_code", "exitCode", "pid", "command", "cwd", "error", "is_error"]
        let prioritySet = Set(priority)
        var admitted: [(String, JSONValue)] = []
        admitted.reserveCapacity(maximumMetadataKeysAdmitted)
        for key in priority {
            if let value = source[key] { admitted.append((key, value)) }
        }

        var inspected = 0
        var iterator = source.makeIterator()
        while inspected < maximumMetadataKeysInspected,
              let (key, value) = iterator.next() {
            inspected += 1
            if key == "stdout" || key == "stderr" || prioritySet.contains(key) { continue }
            if admitted.count >= maximumMetadataKeysAdmitted { break }
            admitted.append((key, value))
        }
        var truncated = source.count > admitted.count
            + (source["stdout"] == nil ? 0 : 1)
            + (source["stderr"] == nil ? 0 : 1)
        if inspected >= maximumMetadataKeysInspected,
           source.count > inspected { truncated = true }
        return MetadataSelection(
            entries: admitted, inspectedKeyCount: inspected,
            wasTruncated: truncated)
    }

    /// Exact terminal tools may return an already-decoded array/scalar. Bound
    /// the tree before JSONEncoder sees it; clipping only the rendered string
    /// would still make a huge direct array an unbounded serialization path.
    private static func boundedGenericPayload(from source: JSONValue) -> ToolPayload {
        var budget = maximumResidualScalars
        var nodes = 0
        let bounded = boundedJSON(source, budget: &budget, nodes: &nodes, depth: 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(bounded.value),
              let rendered = String(data: data, encoding: .utf8) else {
            return ToolPayload(
                kind: .malformed,
                text: "Talaria could not render this bounded terminal JSON result.")
        }
        let marker = "\n… [truncated]"
        let markerCount = marker.unicodeScalars.count
        let admitted = scalarPrefix(
            rendered, maximum: ToolPayloadCodec.maximumResultCharacters - markerCount)
        let truncated = bounded.truncated || admitted.truncated
        let text = admitted.text + (truncated ? marker : "")
        let retainedJSON: JSONValue? = truncated
            ? Optional<JSONValue>.none : bounded.value
        return ToolPayload(
            kind: .json,
            json: retainedJSON,
            text: text,
            isTruncated: truncated)
    }

    /// Create a bounded JSON tree before JSONEncoder sees it. This prevents a
    /// huge metadata string/object from doing unbounded escaping/sorting work
    /// merely because stdout was admitted through the specialist path.
    private static func boundedJSON(_ value: JSONValue, budget: inout Int,
                                    nodes: inout Int, depth: Int)
        -> (value: JSONValue, truncated: Bool) {
        guard budget > 0, nodes < 256, depth <= 8 else {
            return (.string("…"), true)
        }
        nodes += 1
        switch value {
        case .null, .bool, .number:
            budget -= 1
            return (value, false)
        case .string(let text):
            let sanitized = parseANSI(text, field: "metadata")
            let admitted = scalarPrefix(
                sanitized.plainText, maximum: min(budget, 1_024))
            budget -= admitted.text.unicodeScalars.count
            return (.string(admitted.text), sanitized.isTruncated || admitted.truncated)
        case .array(let array):
            var result: [JSONValue] = []
            var truncated = array.count > 64
            for item in array.prefix(64) {
                let child = boundedJSON(item, budget: &budget, nodes: &nodes, depth: depth + 1)
                result.append(child.value)
                truncated = truncated || child.truncated
                if budget <= 0 || nodes >= 256 { truncated = true; break }
            }
            return (.array(result), truncated)
        case .object(let object):
            var result: [String: JSONValue] = [:]
            var truncated = object.count > maximumMetadataKeysAdmitted
            let priority = ["exit_code", "exitCode", "pid", "command", "cwd", "error", "is_error"]
            let prioritySet = Set(priority)
            // Inspect the small operational allowlist first, then at most 64
            // dictionary entries. The source dictionary has already lost wire
            // order; sorting every attacker-controlled key would defeat the
            // bounded renderer before admission even began.
            let priorityKeys = priority.filter { object[$0] != nil }
            var admittedKeys = priorityKeys
            var inspected = 0
            var iterator = object.keys.makeIterator()
            while inspected < maximumMetadataKeysInspected,
                  let rawKey = iterator.next() {
                inspected += 1
                if prioritySet.contains(rawKey) { continue }
                if admittedKeys.count >= maximumMetadataKeysAdmitted {
                    truncated = true
                    break
                }
                admittedKeys.append(rawKey)
            }
            if inspected >= maximumMetadataKeysInspected,
               object.count > inspected { truncated = true }
            for rawKey in admittedKeys {
                guard let item = object[rawKey] else { continue }
                let sanitizedKey = parseANSI(rawKey, field: "metadata key")
                let admittedKey = scalarPrefix(
                    sanitizedKey.plainText,
                    maximum: min(128, max(1, budget)))
                let safeKey = admittedKey.text
                truncated = truncated || sanitizedKey.isTruncated || admittedKey.truncated
                guard !safeKey.isEmpty, result[safeKey] == nil else {
                    truncated = true
                    continue
                }
                budget -= min(budget, safeKey.unicodeScalars.count)
                let child = boundedJSON(item, budget: &budget, nodes: &nodes, depth: depth + 1)
                result[safeKey] = child.value
                truncated = truncated || child.truncated
                if budget <= 0 || nodes >= 256 { truncated = true; break }
            }
            return (.object(result), truncated)
        }
    }

    private static func stream(field: String,
                               in object: [String: JSONValue]) -> ToolOutputStream? {
        guard let value = object[field], value != .null else { return nil }
        guard let text = value.stringValue else {
            return ToolOutputStream(
                state: .malformed,
                diagnostic: "Hermes retained \(field), but it was not text.")
        }
        guard !text.isEmpty else { return nil }
        return parseANSI(text, field: field)
    }

    private enum Container {
        case object([String: JSONValue])
        case generic(JSONValue)
    }

    private static func container(from value: JSONValue?) -> Container? {
        if let object = value?.objectValue { return .object(object) }
        if let value, value != .null, value.stringValue == nil { return .generic(value) }
        guard let text = value?.stringValue else { return nil }
        let admitted = scalarPrefix(text, maximum: maximumContainerScalars)
        guard !admitted.truncated else { return nil }
        guard let data = admitted.text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        if let object = decoded.objectValue { return .object(object) }
        return .generic(decoded)
    }

    private static func parseANSI(_ source: String, field: String) -> ToolOutputStream {
        let markerCount = truncationMarker.unicodeScalars.count
        let admitted = scalarPrefix(source, maximum: maximumRawWorkScalars)
        let scalars = Array(admitted.text.unicodeScalars)
        var segments: [ToolANSISegment] = []
        var index = 0
        var visibleScalars = 0
        var foreground: ToolANSISegment.Foreground?
        var bold = false
        var truncated = admitted.truncated

        func append(_ scalar: UnicodeScalar) -> Bool {
            guard visibleScalars < maximumStreamScalars - markerCount else { return false }
            if let last = segments.indices.last,
               segments[last].foreground == foreground,
               segments[last].bold == bold {
                segments[last].text.unicodeScalars.append(scalar)
                visibleScalars += 1
                return true
            }
            guard segments.count < maximumSegments - 1 else { return false }
            segments.append(ToolANSISegment(
                id: segments.count, text: String(scalar),
                foreground: foreground, bold: bold))
            visibleScalars += 1
            return true
        }

        func consumeStringControl(from start: Int, bellTerminates: Bool) -> Int {
            var cursor = start
            while cursor < scalars.count {
                let value = scalars[cursor].value
                if value == 0x9C || (bellTerminates && value == 0x07) { return cursor + 1 }
                if value == 0x1B, cursor + 1 < scalars.count,
                   scalars[cursor + 1].value == 0x5C { return cursor + 2 }
                cursor += 1
            }
            return scalars.count
        }

        func consumeEscape(from start: Int) -> Int {
            var cursor = start
            while cursor < scalars.count, (0x20...0x2F).contains(scalars[cursor].value) {
                cursor += 1
            }
            if cursor < scalars.count, (0x30...0x7E).contains(scalars[cursor].value) {
                return cursor + 1
            }
            return scalars.count
        }

        func csi(from start: Int) -> (
            end: Int, final: UInt32?, parameters: String, hasIntermediate: Bool
        ) {
            var cursor = start
            var parameterScalars = String.UnicodeScalarView()
            var hasIntermediate = false
            while cursor < scalars.count {
                let value = scalars[cursor].value
                if (0x40...0x7E).contains(value) {
                    return (cursor + 1, value, String(parameterScalars), hasIntermediate)
                }
                if (0x30...0x3F).contains(value) { parameterScalars.append(scalars[cursor]) }
                if (0x20...0x2F).contains(value) { hasIntermediate = true }
                cursor += 1
            }
            return (scalars.count, nil, String(parameterScalars), hasIntermediate)
        }

        func applySGR(_ parameters: String) {
            guard parameters.unicodeScalars.allSatisfy({
                (0x30...0x39).contains($0.value) || $0.value == 0x3B
            }) else { return }
            let codes = parameters.split(separator: ";", omittingEmptySubsequences: false)
                .compactMap { $0.isEmpty ? 0 : Int($0) }
            var cursor = 0
            while cursor < codes.count {
                let code = codes[cursor]
                switch code {
                case 0: bold = false; foreground = nil
                case 1: bold = true
                case 22: bold = false
                case 39: foreground = nil
                case 30...37: foreground = normalForeground(code)
                case 90...97: foreground = brightForeground(code)
                case 38:
                    if cursor + 1 < codes.count, codes[cursor + 1] == 5 {
                        cursor = min(codes.count, cursor + 3) - 1
                    } else if cursor + 1 < codes.count, codes[cursor + 1] == 2 {
                        cursor = min(codes.count, cursor + 5) - 1
                    }
                default: break
                }
                cursor += 1
            }
        }

        while index < scalars.count {
            let scalar = scalars[index]
            let value = scalar.value
            if value == 0x1B {
                guard index + 1 < scalars.count else { break }
                let next = scalars[index + 1].value
                if next == 0x5B {
                    let sequence = csi(from: index + 2)
                    if sequence.final == 0x6D, !sequence.hasIntermediate {
                        applySGR(sequence.parameters)
                    }
                    index = sequence.end
                    continue
                }
                if [0x5D, 0x50, 0x58, 0x5E, 0x5F].contains(next) {
                    index = consumeStringControl(
                        from: index + 2, bellTerminates: next == 0x5D)
                } else {
                    index = consumeEscape(from: index + 1)
                }
                continue
            }
            if value == 0x9B {
                let sequence = csi(from: index + 1)
                if sequence.final == 0x6D, !sequence.hasIntermediate {
                    applySGR(sequence.parameters)
                }
                index = sequence.end
                continue
            }
            if [0x90, 0x98, 0x9D, 0x9E, 0x9F].contains(value) {
                index = consumeStringControl(
                    from: index + 1, bellTerminates: value == 0x9D)
                continue
            }
            if isBidi(value) || (value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D)
                || (0x7F...0x9F).contains(value) {
                index += 1
                continue
            }
            if value == 0x0D {
                guard append("\n") else { truncated = true; break }
                if index + 1 < scalars.count, scalars[index + 1].value == 0x0A { index += 1 }
            } else if !append(scalar) {
                truncated = true
                break
            }
            index += 1
        }

        if truncated {
            foreground = nil
            bold = false
            if let last = segments.indices.last,
               segments[last].foreground == nil, !segments[last].bold {
                segments[last].text += truncationMarker
            } else if segments.count < maximumSegments {
                segments.append(ToolANSISegment(id: segments.count, text: truncationMarker))
            }
        }

        if visibleScalars == 0, !truncated {
            return ToolOutputStream(
                state: .malformed,
                diagnostic: "Hermes retained \(field), but it contained no displayable text.")
        }
        return ToolOutputStream(
            state: .available, segments: segments,
            isTruncated: truncated,
            diagnostic: truncated
                ? "\(field) exceeded the mobile display budget."
                : nil)
    }

    private static func scalarPrefix(_ text: String, maximum: Int) -> (text: String, truncated: Bool) {
        var iterator = text.unicodeScalars.makeIterator()
        var output = String.UnicodeScalarView()
        var count = 0
        while count < maximum, let scalar = iterator.next() {
            output.append(scalar)
            count += 1
        }
        return (String(output), iterator.next() != nil)
    }

    private static func isBidi(_ value: UInt32) -> Bool {
        value == 0x061C || value == 0x200E || value == 0x200F
            || (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value)
    }

    private static func normalForeground(_ code: Int) -> ToolANSISegment.Foreground? {
        let values: [ToolANSISegment.Foreground] = [
            .black, .red, .green, .yellow, .blue, .magenta, .cyan, .white,
        ]
        return values.indices.contains(code - 30) ? values[code - 30] : nil
    }

    private static func brightForeground(_ code: Int) -> ToolANSISegment.Foreground? {
        let values: [ToolANSISegment.Foreground] = [
            .brightBlack, .brightRed, .brightGreen, .brightYellow,
            .brightBlue, .brightMagenta, .brightCyan, .brightWhite,
        ]
        return values.indices.contains(code - 90) ? values[code - 90] : nil
    }
}
