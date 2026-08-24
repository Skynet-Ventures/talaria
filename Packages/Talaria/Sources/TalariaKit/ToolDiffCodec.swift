import Foundation

/// A bounded, read-only unified diff retained from an explicit Hermes field.
/// Only file-edit tools are eligible; arbitrary stdout is never promoted into
/// a patch and this model has no filesystem mutation surface.
public struct ToolFileDiff: Codable, Sendable, Equatable {
    public enum SourceField: String, Codable, Sendable {
        case inlineDiff = "inline_diff"
        case diff
    }

    public enum State: String, Codable, Sendable {
        case available
        case malformed
    }

    public var sourceField: SourceField
    public var state: State
    public var path: String?
    public var unifiedDiff: String?
    public var addedLines: Int
    public var removedLines: Int
    public var isTruncated: Bool
    public var diagnostic: String?

    public init(sourceField: SourceField, state: State, path: String? = nil,
                unifiedDiff: String? = nil, addedLines: Int = 0,
                removedLines: Int = 0, isTruncated: Bool = false,
                diagnostic: String? = nil) {
        self.sourceField = sourceField
        self.state = state
        self.path = path
        self.unifiedDiff = unifiedDiff
        self.addedLines = addedLines
        self.removedLines = removedLines
        self.isTruncated = isTruncated
        self.diagnostic = diagnostic
    }
}

public enum ToolDiffCodec {
    public static let maximumCharacters = 20_000
    public static let maximumLines = 400
    public static let maximumPathCharacters = 1_024
    private static let maximumContainerScalars = maximumCharacters + 8_192
    private static let fileEditNames: Set<String> = ["edit_file", "patch", "write_file"]

    public static func isFileEditTool(_ name: String) -> Bool {
        fileEditNames.contains(name)
    }

    /// Extract only the explicit diff contract of a known file-edit tool.
    /// Top-level live `inline_diff` wins over the retained result wrapper.
    public static func extract(toolName: String, arguments: JSONValue?,
                               result: JSONValue?, inlineDiff: JSONValue? = nil) -> ToolFileDiff? {
        guard isFileEditTool(toolName) else { return nil }
        return candidate(arguments: arguments, result: result, inlineDiff: inlineDiff)
    }

    /// Bound and sanitize explicit wire material before its tool name is
    /// necessarily known. This is inert evidence: callers must still establish
    /// an exact case-sensitive file-edit name before promoting it to `fileDiff`.
    public static func candidate(arguments: JSONValue?, result: JSONValue?,
                                 inlineDiff: JSONValue? = nil) -> ToolFileDiff? {
        let hasTopLevelDiff = inlineDiff != nil && inlineDiff != .null
        let resultObject = hasTopLevelDiff ? nil : object(from: result)
        let candidate: (ToolFileDiff.SourceField, JSONValue)?
        if let inlineDiff, inlineDiff != .null {
            candidate = (.inlineDiff, inlineDiff)
        } else if let value = resultObject?["inline_diff"], value != .null {
            candidate = (.inlineDiff, value)
        } else if let value = resultObject?["diff"], value != .null {
            candidate = (.diff, value)
        } else {
            candidate = nil
        }
        guard let (field, value) = candidate else { return nil }

        let path = firstPath(in: object(from: arguments), keys: ["path", "file", "filepath"])
            ?? firstPath(in: resultObject, keys: ["path", "file", "filepath", "resolved_path"])
        guard let source = value.stringValue else {
            return ToolFileDiff(
                sourceField: field, state: .malformed, path: path,
                diagnostic: "Hermes retained \(field.rawValue), but it was not a text unified diff.")
        }

        // Bound before replacement, normalization, splitting, or statistics.
        let admitted = scalarPrefix(source, maximum: maximumCharacters)
        let normalized = sanitizeTerminalText(admitted.text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let chromePattern = "(?i)^[\\t ]*┊[\\t ]*review diff[\\t ]*(?:\\n|$)"
        let chromeRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let clean = (try? NSRegularExpression(pattern: chromePattern))?
            .stringByReplacingMatches(in: normalized, range: chromeRange,
                                      withTemplate: "") ?? normalized
        guard !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolFileDiff(
                sourceField: field, state: .malformed, path: path,
                diagnostic: "Hermes retained \(field.rawValue), but it contained no displayable diff text.")
        }

        let marker = "… [diff truncated]"
        let markerScalars = marker.unicodeScalars.count
        var retainedSource = clean
        if admitted.truncated,
           retainedSource.unicodeScalars.count + markerScalars + 1 > maximumCharacters {
            retainedSource = scalarPrefix(
                retainedSource, maximum: maximumCharacters - markerScalars - 1).text
        }
        var lines = retainedSource.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let lineTruncated = lines.count > maximumLines
        let truncated = admitted.truncated || lineTruncated
        if truncated {
            lines = Array(lines.prefix(maximumLines - 1))
            while lines.joined(separator: "\n").unicodeScalars.count + markerScalars + 1
                    > maximumCharacters, !lines.isEmpty {
                lines.removeLast()
            }
        }
        var added = 0
        var removed = 0
        for line in lines {
            if line.hasPrefix("+") && !line.hasPrefix("+++") { added += 1 }
            if line.hasPrefix("-") && !line.hasPrefix("---") { removed += 1 }
        }
        if truncated { lines.append(marker) }
        return ToolFileDiff(
            sourceField: field, state: .available, path: path,
            unifiedDiff: lines.joined(separator: "\n"),
            addedLines: added, removedLines: removed, isTruncated: truncated,
            diagnostic: truncated
                ? "Diff preview exceeded the mobile display budget (at most \(maximumLines) lines and \(maximumCharacters) Unicode scalars)."
                : nil)
    }

    public static func path(from arguments: ToolPayload?) -> String? {
        firstPath(in: arguments?.json?.objectValue, keys: ["path", "file", "filepath"])
    }

    private static func object(from value: JSONValue?) -> [String: JSONValue]? {
        if let object = value?.objectValue { return object }
        guard let text = value?.stringValue else { return nil }
        let admitted = scalarPrefix(text, maximum: maximumContainerScalars)
        guard !admitted.truncated, let data = admitted.text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return decoded.objectValue
    }

    private static func firstPath(in object: [String: JSONValue]?,
                                  keys: [String]) -> String? {
        for key in keys {
            if let value = object?[key]?.stringValue, let safe = sanitizedPath(value) {
                return safe
            }
        }
        return nil
    }

    private static func sanitizedPath(_ path: String) -> String? {
        let admitted = scalarPrefix(path, maximum: maximumPathCharacters)
        let safe = sanitizeTerminalText(admitted.text)
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .trimmingCharacters(in: .whitespaces)
        return safe.isEmpty ? nil : safe
    }

    private static func scalarPrefix(_ text: String,
                                     maximum: Int) -> (text: String, truncated: Bool) {
        var iterator = text.unicodeScalars.makeIterator()
        var output = String.UnicodeScalarView()
        var count = 0
        while count < maximum, let scalar = iterator.next() {
            output.append(scalar)
            count += 1
        }
        return (String(output), iterator.next() != nil)
    }

    /// Strip terminal presentation controls and bidi overrides while retaining
    /// literal tab/newline/printable diff content.
    private static func sanitizeTerminalText(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0

        func isBidi(_ value: UInt32) -> Bool {
            value == 0x061C || value == 0x200E || value == 0x200F
                || (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value)
        }
        func consumeStringControl(from start: Int) -> Int {
            var cursor = start
            while cursor < scalars.count {
                let value = scalars[cursor].value
                if value == 0x9C || value == 0x07 { return cursor + 1 }
                if value == 0x1B, cursor + 1 < scalars.count,
                   scalars[cursor + 1].value == 0x5C { return cursor + 2 }
                cursor += 1
            }
            return scalars.count
        }
        func consumeCSI(from start: Int) -> Int {
            var cursor = start
            while cursor < scalars.count {
                if (0x40...0x7E).contains(scalars[cursor].value) { return cursor + 1 }
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

        while index < scalars.count {
            let scalar = scalars[index]
            let value = scalar.value
            if value == 0x1B {
                guard index + 1 < scalars.count else { break }
                let next = scalars[index + 1].value
                if next == 0x5B { index = consumeCSI(from: index + 2); continue }
                if [0x5D, 0x50, 0x58, 0x5E, 0x5F].contains(next) {
                    index = consumeStringControl(from: index + 2); continue
                }
                index = consumeEscape(from: index + 1)
                continue
            }
            if value == 0x9B { index = consumeCSI(from: index + 1); continue }
            if [0x90, 0x98, 0x9D, 0x9E, 0x9F].contains(value) {
                index = consumeStringControl(from: index + 1); continue
            }
            if isBidi(value)
                || (value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D)
                || (0x7F...0x9F).contains(value) {
                index += 1
                continue
            }
            output.append(scalar)
            index += 1
        }
        return String(output)
    }
}
