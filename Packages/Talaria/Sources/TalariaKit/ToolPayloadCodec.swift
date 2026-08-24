import Foundation

/// Finite normalization shared by retained transcript hydration and live tool
/// events. Caps apply before JSON decode/render work reaches the UI model.
public enum ToolPayloadCodec {
    public static let maximumArgumentCharacters = 4_096
    public static let maximumResultCharacters = 20_000
    public static let maximumDiagnosticCharacters = 280
    public static let maximumToolIdentityCharacters = 256
    public static let maximumToolNameCharacters = 160
    private static let maximumDecodeBytes = 80_000

    public static func arguments(from value: JSONValue?) -> ToolPayload? {
        guard let value, value != .null else { return nil }
        if let text = value.stringValue {
            guard text.unicodeScalars.prefix(maximumDecodeBytes + 1).count <= maximumDecodeBytes,
                  text.unicodeScalars.contains(where: {
                    !CharacterSet.whitespacesAndNewlines.contains($0)
                  }),
                  let decoded = decodeJSON(text) else {
                let label = "Saved tool arguments were not valid bounded JSON: "
                let raw = bounded(
                    text, maximum: max(0, maximumDiagnosticCharacters - label.count))
                let admitted = bounded(label + raw.text,
                                       maximum: maximumDiagnosticCharacters)
                return ToolPayload(
                    kind: .malformed,
                    text: admitted.text,
                    isTruncated: admitted.truncated)
            }
            return json(decoded, maximum: maximumArgumentCharacters)
        }
        return json(value, maximum: maximumArgumentCharacters)
    }

    public static func directArguments(from value: JSONValue?) -> ToolPayload? {
        guard let value, value != .null else { return nil }
        if let text = value.stringValue {
            guard !text.isEmpty else { return nil }
            let admitted = bounded(text, maximum: maximumArgumentCharacters)
            return ToolPayload(kind: .text, text: admitted.text,
                               isTruncated: admitted.truncated)
        }
        return json(value, maximum: maximumArgumentCharacters)
    }

    public static func result(from value: JSONValue?) -> ToolPayload? {
        guard let value, value != .null else { return nil }
        if let text = value.stringValue {
            guard !text.isEmpty else { return nil }
            if text.unicodeScalars.prefix(maximumDecodeBytes + 1).count <= maximumDecodeBytes,
               let decoded = decodeJSON(text) {
                return json(decoded, maximum: maximumResultCharacters)
            }
            let admitted = bounded(text, maximum: maximumResultCharacters)
            return ToolPayload(kind: .text, text: admitted.text,
                               isTruncated: admitted.truncated)
        }
        return json(value, maximum: maximumResultCharacters)
    }

    public static func unavailable(_ explanation: String) -> ToolPayload {
        let admitted = bounded(explanation, maximum: maximumDiagnosticCharacters)
        return ToolPayload(kind: .unavailable, text: admitted.text,
                           isTruncated: admitted.truncated)
    }

    public static func preview(_ payload: ToolPayload?, maximum: Int = 120) -> String? {
        guard let text = payload?.displayText else { return nil }
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return bounded(line, maximum: maximum).text
    }

    public static func boundedText(_ text: String, maximum: Int) -> String {
        bounded(text, maximum: maximum).text
    }

    public static func resultHasExplicitError(_ payload: ToolPayload?) -> Bool {
        guard let object = payload?.json?.objectValue else { return false }
        return object["is_error"]?.boolValue == true || valueIsExplicitError(object["error"])
    }

    public static func valueIsExplicitError(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .null: return false
        case .bool(let flag): return flag
        case .number(let number): return number != 0
        case .string(let text):
            let bounded = text.unicodeScalars.prefix(maximumDiagnosticCharacters + 1)
            return bounded.contains {
                !CharacterSet.whitespacesAndNewlines.contains($0)
            }
        case .array(let values): return !values.isEmpty
        case .object(let object): return !object.isEmpty
        }
    }

    /// Identity fields are rejected rather than clipped: a prefix names a
    /// different execution and would make exact pairing unsafe.
    public static func admittedIdentity(_ text: String?, maximum: Int) -> String? {
        guard let text else { return nil }
        let scalars = text.unicodeScalars.prefix(maximum + 1)
        guard scalars.count <= maximum else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.unicodeScalars.contains(where: {
            $0.value < 0x20
                || (0x7F...0x9F).contains($0.value)
                || $0.value == 0x061C
                || (0x200E...0x200F).contains($0.value)
                || (0x202A...0x202E).contains($0.value)
                || (0x2066...0x2069).contains($0.value)
        }) else { return nil }
        return trimmed
    }

    private static func json(_ value: JSONValue, maximum: Int) -> ToolPayload {
        var remainingNodes = 10_000
        guard structurallyAdmissible(value, depth: 0, remainingNodes: &remainingNodes) else {
            return ToolPayload(kind: .malformed,
                               text: "The retained JSON payload exceeded Talaria's safety budget.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), data.count <= maximumDecodeBytes,
              let rendered = String(data: data, encoding: .utf8) else {
            return ToolPayload(kind: .malformed,
                               text: "Talaria could not safely render this retained JSON payload.")
        }
        let admitted = bounded(rendered, maximum: maximum)
        return ToolPayload(kind: .json, json: admitted.truncated ? nil : value,
                           text: admitted.text, isTruncated: admitted.truncated)
    }

    private static func decodeJSON(_ text: String) -> JSONValue? {
        guard text.unicodeScalars.prefix(maximumDecodeBytes + 1).count <= maximumDecodeBytes,
              let data = text.data(using: .utf8), data.count <= maximumDecodeBytes else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Stops after a fixed node/depth/string prefix budget, before encoder
    /// traversal. This bounds hostile in-memory WS payload work as well as the
    /// wire-byte ceiling bounding REST decode.
    private static func structurallyAdmissible(
        _ value: JSONValue, depth: Int, remainingNodes: inout Int
    ) -> Bool {
        guard depth <= 32, remainingNodes > 0 else { return false }
        remainingNodes -= 1
        switch value {
        case .null, .bool, .number:
            return true
        case .string(let text):
            return text.unicodeScalars.prefix(maximumDecodeBytes + 1).count
                <= maximumDecodeBytes
        case .array(let values):
            guard values.count <= remainingNodes else { return false }
            for child in values where !structurallyAdmissible(
                child, depth: depth + 1, remainingNodes: &remainingNodes) { return false }
            return true
        case .object(let object):
            guard object.count <= remainingNodes else { return false }
            for (key, child) in object {
                guard key.unicodeScalars.prefix(1_025).count <= 1_024,
                      structurallyAdmissible(
                        child, depth: depth + 1, remainingNodes: &remainingNodes)
                else { return false }
            }
            return true
        }
    }

    /// Unicode-scalar bounded presentation admission. Work never depends on
    /// grapheme segmentation (so combining-mark bombs stay finite), ordinary
    /// tabs/newlines survive, and controls capable of spoofing copied or
    /// painted diagnostics are removed before the scalar cap is applied.
    private static func bounded(_ text: String, maximum: Int) -> (text: String, truncated: Bool) {
        guard maximum > 0 else {
            return ("", !text.unicodeScalars.isEmpty)
        }
        let marker = "\n… [truncated]"
        let markerScalars = marker.unicodeScalars
        let rawWorkMaximum = max(maximum + 1, maximum * 4)
        let raw = text.unicodeScalars.prefix(rawWorkMaximum + 1)
        let rawClipped = raw.count > rawWorkMaximum
        var safe = String.UnicodeScalarView()
        safe.reserveCapacity(maximum + 1)
        var safeCount = 0
        var removedUnsafe = false
        for scalar in raw.prefix(rawWorkMaximum) {
            if isUnsafePresentationControl(scalar.value) {
                removedUnsafe = true
                continue
            }
            safe.append(scalar)
            safeCount += 1
            if safeCount > maximum { break }
        }
        let contentClipped = safeCount > maximum
        guard rawClipped || contentClipped else {
            return (String(safe), removedUnsafe)
        }
        let contentMaximum = max(0, maximum - min(maximum, markerScalars.count))
        var clipped = String.UnicodeScalarView(safe.prefix(contentMaximum))
        clipped.append(contentsOf: markerScalars.prefix(maximum - contentMaximum))
        return (String(clipped), true)
    }

    private static func isUnsafePresentationControl(_ value: UInt32) -> Bool {
        if value == 0x09 || value == 0x0A { return false }
        if value <= 0x1F || (0x7F...0x9F).contains(value) { return true }
        return value == 0x061C
            || (0x200E...0x200F).contains(value)
            || (0x202A...0x202E).contains(value)
            || (0x2066...0x2069).contains(value)
    }
}
