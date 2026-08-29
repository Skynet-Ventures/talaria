import Foundation

/// The bounded, visible-prose boundary for per-message speech.
///
/// Callers must pass `AssistantMediaProjection.copyText(in:)`, never a raw
/// transcript envelope. That projection already excludes assistant MEDIA
/// directives and generated-image echoes; this policy then removes syntax
/// that is useful on screen but unsafe or hostile when spoken.
public enum ReadAloudPolicy {
    public static let maximumInputUTF8Bytes = 96_000
    public static let maximumInputScalars = 48_000
    public static let maximumOutputUTF8Bytes = 48_000
    public static let maximumOutputScalars = 24_000

    /// Read Aloud is an explicit action on settled assistant prose only.
    public static func preparedText(for message: ChatMessage) -> String? {
        guard message.author == .bot, !message.isStreaming, message.failure == nil else {
            return nil
        }
        let visible = AssistantMediaProjection.copyText(in: message)
        return sanitize(visible)
    }

    /// Removes code, raw destinations, table contents, Markdown decoration,
    /// emoji, controls and bidi formatting while preserving ordinary prose.
    /// Returns nil on any hard bound or unsafe result.
    public static func sanitize(_ source: String) -> String? {
        guard bounded(source, bytes: maximumInputUTF8Bytes,
                      scalars: maximumInputScalars) else { return nil }

        let safeScalars = source.unicodeScalars.filter { !isUnsafe($0) }
        var text = String(String.UnicodeScalarView(safeScalars))
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        text = removeFencedCode(from: text)
        text = removeMarkdownTables(from: text)
        text = replaceMarkdownLinks(in: text)
        text = replaceRawURLs(in: text)
        text = removeEmoji(from: text)
        text = text.replacingOccurrences(
            of: #"`([^`\n]+)`"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"(?m)^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"(?m)^\s{0,3}(?:[-+*]|\d{1,4}[.)])\s+"#,
            with: "", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"[*_~>#]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"(?m)([.!?][\"'’”)}\]]*)[ \t]*\n{2,}[ \t]*"#,
            with: "$1 ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"[ \t]*\n{2,}[ \t]*"#, with: ". ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"[ \t]*\n[ \t]*"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty,
              bounded(text, bytes: maximumOutputUTF8Bytes,
                      scalars: maximumOutputScalars),
              !text.unicodeScalars.contains(where: isUnsafe) else { return nil }
        return text
    }

    /// Stable identity hint carried by the playback lease. Runtime admission
    /// also compares the exact prepared text, so this non-cryptographic digest
    /// is never the only collision boundary.
    public static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private static func bounded(_ value: String, bytes: Int, scalars: Int) -> Bool {
        value.utf8.prefix(bytes + 1).count <= bytes
            && value.unicodeScalars.prefix(scalars + 1).count <= scalars
    }

    private static func isUnsafe(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 0x20 && scalar != "\n" && scalar != "\t"
            || (0x7f...0x9f).contains(scalar.value)
            || scalar.value == 0x061c
            || (0x200e...0x200f).contains(scalar.value)
            || (0x202a...0x202e).contains(scalar.value)
            || (0x2066...0x2069).contains(scalar.value)
    }

    private static func removeFencedCode(from source: String) -> String {
        source.replacingOccurrences(
            of: #"(?s)(?:```|~~~).*?(?:(?:```|~~~)|\z)"#,
            with: " Code block omitted. ", options: .regularExpression)
    }

    private static func replaceMarkdownLinks(in source: String) -> String {
        source.replacingOccurrences(
            of: #"!?\[([^\]\n]{1,512})\]\([^\n)]{1,4096}\)"#,
            with: "$1", options: .regularExpression)
    }

    private static func replaceRawURLs(in source: String) -> String {
        source.replacingOccurrences(
            of: #"(?i)\bhttps?://[^\s<>()\[\]{}]+"#,
            with: " link ", options: .regularExpression)
    }

    private static func removeEmoji(from source: String) -> String {
        let scalars = source.unicodeScalars.filter { scalar in
            let value = scalar.value
            return !((0x1f000...0x1faff).contains(value)
                || (0x2600...0x27bf).contains(value)
                || value == 0xfe0f || value == 0x200d
                || (0xe0020...0xe007f).contains(value))
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private struct TableRow {
        let quoteDepth: Int
        let cells: [String]
    }

    private static func removeMarkdownTables(from source: String) -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard lines.count > 1 else { return source }
        var omitted = Set<Int>()
        var index = 1
        while index < lines.count {
            guard let header = parseTableRow(lines[index - 1]),
                  let divider = parseTableRow(lines[index]),
                  header.quoteDepth == divider.quoteDepth,
                  header.cells.count == divider.cells.count,
                  divider.cells.allSatisfy({ cell in
                      cell.range(of: #"^:?-{3,}:?$"#,
                                 options: .regularExpression) != nil
                  }) else {
                index += 1
                continue
            }
            omitted.insert(index - 1)
            omitted.insert(index)
            var body = index + 1
            while body < lines.count,
                  let row = parseTableRow(lines[body]),
                  row.quoteDepth == divider.quoteDepth {
                omitted.insert(body)
                body += 1
            }
            index = body
        }
        return lines.enumerated().compactMap { omitted.contains($0.offset) ? nil : $0.element }
            .joined(separator: "\n")
    }

    private static func parseTableRow(_ input: String) -> TableRow? {
        var row = input[...]
        var depth = 0
        while true {
            let spaces = row.prefix(while: { $0 == " " }).count
            guard spaces <= 3, !row.prefix(spaces).contains("\t") else { return nil }
            row = row.dropFirst(spaces)
            guard row.first == ">" else { break }
            depth += 1
            row = row.dropFirst()
            if row.first == " " { row = row.dropFirst() }
        }
        let clean = String(row).trimmingCharacters(in: .whitespaces)
        let pipeIndexes = clean.indices.filter { index in
            guard clean[index] == "|" else { return false }
            var cursor = index
            var backslashes = 0
            while cursor > clean.startIndex {
                cursor = clean.index(before: cursor)
                guard clean[cursor] == "\\" else { break }
                backslashes += 1
            }
            return backslashes.isMultiple(of: 2)
        }
        guard !pipeIndexes.isEmpty else { return nil }
        var body = clean
        let leading = body.first == "|"
        let trailing = body.last == "|"
        if leading { body.removeFirst() }
        if trailing, !body.isEmpty { body.removeLast() }
        var cells: [String] = []
        var start = body.startIndex
        for index in body.indices where body[index] == "|" {
            var cursor = index
            var backslashes = 0
            while cursor > body.startIndex {
                cursor = body.index(before: cursor)
                guard body[cursor] == "\\" else { break }
                backslashes += 1
            }
            guard backslashes.isMultiple(of: 2) else { continue }
            cells.append(String(body[start..<index]).trimmingCharacters(in: .whitespaces))
            start = body.index(after: index)
        }
        cells.append(String(body[start...]).trimmingCharacters(in: .whitespaces))
        guard cells.count >= 2 || (leading && trailing && cells.count == 1) else { return nil }
        return TableRow(quoteDepth: depth, cells: cells)
    }
}
