import Foundation

/// Pure, non-persisting projection of exact assistant `MEDIA:` directives.
/// Callers must invoke this only for assistant-authored text.
public enum AssistantMediaProjection {
    public static let maximumInputScalars = 128_000
    public static let maximumInputUTF8Bytes = 384_000
    public static let maximumScanWork = 320_000
    public static let maximumDirectives = 32
    public static let maximumValueScalars = 2_048
    public static let maximumValueUTF8Bytes = 6_144

    public enum Kind: String, Sendable, Equatable, Codable {
        case image, audio, video, file
    }

    public struct Reference: Sendable, Equatable {
        public let rawValue: String
        public let ordinal: Int
        public let kind: Kind
        public let displayName: String
        public let fingerprint: String
        /// Half-open offsets in the original assistant string's UTF-8 view.
        public let sourceUTF8Range: Range<Int>

        init(rawValue: String, ordinal: Int, sourceUTF8Range: Range<Int>) {
            self.rawValue = rawValue
            self.ordinal = ordinal
            self.kind = AssistantMediaProjection.classify(rawValue)
            self.displayName = AssistantMediaProjection.displayName(rawValue)
            self.fingerprint = AssistantMediaProjection.fingerprint(
                rawValue: rawValue, ordinal: ordinal)
            self.sourceUTF8Range = sourceUTF8Range
        }
    }

    public enum Run: Sendable, Equatable {
        case text(String)
        case media(Reference)
    }

    public struct Projection: Sendable, Equatable {
        public let runs: [Run]
        /// True when a hard input/work/count/value bound or unsafe scalar made
        /// the only safe projection an empty, fail-closed result.
        public let isClipped: Bool
        /// True only for a plausible streaming tail that is deliberately left
        /// byte-for-byte in `.text` until a closing quote or delimiter arrives.
        public let hasPendingDirective: Bool

        public var references: [Reference] {
            runs.compactMap { run in
                guard case .media(let reference) = run else { return nil }
                return reference
            }
        }

        public var text: String {
            runs.reduce(into: "") { result, run in
                if case .text(let value) = run { result += value }
            }
        }
    }

    public static func project(_ assistantText: String,
                               isStreaming: Bool = false) -> Projection {
        guard assistantText.utf8.prefix(maximumInputUTF8Bytes + 1).count
                <= maximumInputUTF8Bytes,
              assistantText.unicodeScalars.prefix(maximumInputScalars + 1).count
                <= maximumInputScalars else {
            return Projection(runs: [], isClipped: true, hasPendingDirective: false)
        }
        var parser = Parser(source: assistantText, isStreaming: isStreaming)
        return parser.parse()
    }

    public static func copyText(in message: ChatMessage) -> String {
        guard message.author == .bot else { return message.text }
        let visible = GeneratedImageEchoPolicy.suppress(in: message)
        let projection = project(visible, isStreaming: message.isStreaming)
        return projection.isClipped ? "" : projection.text
    }

    public static func classify(_ rawValue: String) -> Kind {
        guard rawValue.utf8.prefix(maximumValueUTF8Bytes + 1).count
                <= maximumValueUTF8Bytes,
              rawValue.unicodeScalars.prefix(maximumValueScalars + 1).count
                <= maximumValueScalars else { return .file }
        var end = rawValue.endIndex
        if let query = rawValue.firstIndex(of: "?") { end = min(end, query) }
        if let fragment = rawValue.firstIndex(of: "#") { end = min(end, fragment) }
        let clean = rawValue[..<end]
        guard let dot = clean.lastIndex(of: ".") else { return .file }
        let ext = clean[clean.index(after: dot)...].lowercased()
        switch ext {
        case "bmp", "gif", "jpeg", "jpg", "png", "svg", "webp": return .image
        case "flac", "m4a", "mp3", "ogg", "opus", "wav": return .audio
        case "avi", "mkv", "mov", "mp4", "webm": return .video
        default: return .file
        }
    }

    private static func displayName(_ rawValue: String) -> String {
        var end = rawValue.endIndex
        if let query = rawValue.firstIndex(of: "?") { end = min(end, query) }
        if let fragment = rawValue.firstIndex(of: "#") { end = min(end, fragment) }
        let clean = rawValue[..<end]
        let component = clean.split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last.map(String.init) ?? String(clean)
        let decoded = component.removingPercentEncoding
        let candidate = decoded.flatMap { value in
            value.isEmpty || value.unicodeScalars.contains(where: unsafeDisplayScalar)
                ? nil : value
        } ?? (component.isEmpty ? "media" : component)
        let scalars = candidate.unicodeScalars
        let prefix = String(scalars.prefix(100))
        return scalars.count > 100 ? prefix + "…" : prefix
    }

    private static func unsafeDisplayScalar(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 0x20 || (0x7f...0x9f).contains(scalar.value)
            || scalar.value == 0x061c || (0x200e...0x200f).contains(scalar.value)
            || (0x202a...0x202e).contains(scalar.value)
            || (0x2066...0x2069).contains(scalar.value)
    }

    private static func fingerprint(rawValue: String, ordinal: Int) -> String {
        // Stable FNV-1a identity hint, not an authority or cryptographic hash.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in "\(ordinal)\u{1f}\(rawValue)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private struct Parser {
        let source: String
        let isStreaming: Bool
        var work = 0
        var runs: [Run] = []
        var directiveCount = 0
        var pending = false
        var lastTextStart: String.Index
        var clipped = false

        init(source: String, isStreaming: Bool) {
            self.source = source
            self.isStreaming = isStreaming
            self.lastTextStart = source.startIndex
        }

        mutating func parse() -> Projection {
            let scalars = source.unicodeScalars
            var lineStart = scalars.startIndex
            var lineStartUTF8 = 0
            var fenceMarker: UnicodeScalar?

            while lineStart < scalars.endIndex {
                var lineEnd = lineStart
                var lineUTF8 = 0
                while lineEnd < scalars.endIndex,
                      !Self.isLineBreak(scalars[lineEnd]) {
                    guard inspect(1) else { return failed() }
                    let scalar = scalars[lineEnd]
                    guard !Self.isUnsafe(scalar) else { return failed() }
                    lineUTF8 += scalar.utf8.count
                    lineEnd = scalars.index(after: lineEnd)
                }

                let first = firstNonHorizontalWhitespace(from: lineStart, to: lineEnd)
                let marker = first.flatMap { index -> UnicodeScalar? in
                    if hasPrefix("```", at: index, before: lineEnd) { return "`" }
                    if hasPrefix("~~~", at: index, before: lineEnd) { return "~" }
                    return nil
                }
                if let active = fenceMarker {
                    if marker == active { fenceMarker = nil }
                } else if let marker {
                    fenceMarker = marker
                } else if !isProtectedLine(first: first, lineEnd: lineEnd) {
                    parseLine(from: lineStart, to: lineEnd, lineStartUTF8: lineStartUTF8)
                    if clipped { return failed() }
                }

                lineStartUTF8 += lineUTF8
                if lineEnd < scalars.endIndex {
                    let firstBreak = scalars[lineEnd]
                    guard inspect(1) else { return failed() }
                    lineStartUTF8 += firstBreak.utf8.count
                    lineEnd = scalars.index(after: lineEnd)
                    if firstBreak == "\r", lineEnd < scalars.endIndex,
                       scalars[lineEnd] == "\n" {
                        guard inspect(1) else { return failed() }
                        lineStartUTF8 += scalars[lineEnd].utf8.count
                        lineEnd = scalars.index(after: lineEnd)
                    }
                }
                lineStart = lineEnd
            }

            appendText(until: source.endIndex)
            return Projection(runs: runs, isClipped: false,
                              hasPendingDirective: pending)
        }

        mutating func parseLine(from start: String.Index, to end: String.Index,
                                lineStartUTF8: Int) {
            let scalars = source.unicodeScalars
            var cursor = start
            var localUTF8 = 0
            var jsonDepth = 0
            while cursor < end {
                guard inspect(1) else { clipped = true; return }
                if scalars[cursor] == "{" || scalars[cursor] == "[" {
                    jsonDepth += 1
                    localUTF8 += scalars[cursor].utf8.count
                    cursor = scalars.index(after: cursor)
                    continue
                }
                if scalars[cursor] == "}" || scalars[cursor] == "]" {
                    jsonDepth = max(0, jsonDepth - 1)
                    localUTF8 += scalars[cursor].utf8.count
                    cursor = scalars.index(after: cursor)
                    continue
                }
                if scalars[cursor] == "\"", jsonDepth > 0 {
                    var probe = scalars.index(after: cursor)
                    var skippedUTF8 = scalars[cursor].utf8.count
                    var escaped = false
                    while probe < end {
                        guard inspect(1) else { clipped = true; return }
                        let scalar = scalars[probe]
                        skippedUTF8 += scalar.utf8.count
                        probe = scalars.index(after: probe)
                        if escaped {
                            escaped = false
                        } else if scalar == "\\" {
                            escaped = true
                        } else if scalar == "\"" {
                            break
                        }
                    }
                    cursor = probe
                    localUTF8 += skippedUTF8
                    continue
                }
                if scalars[cursor] == "`" {
                    var openingCount = 0
                    var probe = cursor
                    var skippedUTF8 = 0
                    while probe < end, scalars[probe] == "`" {
                        if openingCount > 0, !inspect(1) { clipped = true; return }
                        openingCount += 1
                        skippedUTF8 += scalars[probe].utf8.count
                        probe = scalars.index(after: probe)
                    }
                    var foundClosing = false
                    while probe < end {
                        guard inspect(1) else { clipped = true; return }
                        if scalars[probe] != "`" {
                            skippedUTF8 += scalars[probe].utf8.count
                            probe = scalars.index(after: probe)
                            continue
                        }
                        var closingCount = 0
                        while probe < end, scalars[probe] == "`" {
                            if closingCount > 0, !inspect(1) { clipped = true; return }
                            closingCount += 1
                            skippedUTF8 += scalars[probe].utf8.count
                            probe = scalars.index(after: probe)
                        }
                        if closingCount >= openingCount {
                            foundClosing = true
                            break
                        }
                    }
                    cursor = foundClosing ? probe : end
                    localUTF8 += skippedUTF8
                    continue
                }

                guard hasDirectiveBoundary(before: cursor, lineStart: start),
                      hasPrefix("MEDIA:", at: cursor, before: end) else {
                    localUTF8 += scalars[cursor].utf8.count
                    cursor = scalars.index(after: cursor)
                    continue
                }
                let directiveStart = cursor
                let directiveStartUTF8 = lineStartUTF8 + localUTF8
                var valueStart = cursor
                for _ in 0..<6 {
                    localUTF8 += scalars[valueStart].utf8.count
                    valueStart = scalars.index(after: valueStart)
                }
                while valueStart < end,
                      Self.isHorizontalWhitespace(scalars[valueStart]) {
                    guard inspect(1) else { clipped = true; return }
                    localUTF8 += scalars[valueStart].utf8.count
                    valueStart = scalars.index(after: valueStart)
                }
                guard valueStart < end else {
                    if isStreaming && end == scalars.endIndex { pending = true }
                    cursor = end
                    continue
                }

                let quote = scalars[valueStart]
                let isQuoted = quote == "\"" || quote == "'" || quote == "`"
                var rawStart = valueStart
                var valueEnd = valueStart
                var directiveEnd = valueStart
                if isQuoted {
                    localUTF8 += quote.utf8.count
                    valueEnd = scalars.index(after: valueStart)
                    rawStart = valueEnd
                    directiveEnd = valueEnd
                    while directiveEnd < end, scalars[directiveEnd] != quote {
                        guard inspect(1) else { clipped = true; return }
                        localUTF8 += scalars[directiveEnd].utf8.count
                        directiveEnd = scalars.index(after: directiveEnd)
                    }
                    guard directiveEnd < end else {
                        if isStreaming && end == scalars.endIndex { pending = true }
                        cursor = end
                        continue
                    }
                    let closing = directiveEnd
                    directiveEnd = scalars.index(after: closing)
                    localUTF8 += scalars[closing].utf8.count
                    valueEnd = closing
                } else {
                    valueEnd = valueStart
                    while valueEnd < end,
                          !Self.isHorizontalWhitespace(scalars[valueEnd]) {
                        guard inspect(1) else { clipped = true; return }
                        localUTF8 += scalars[valueEnd].utf8.count
                        valueEnd = scalars.index(after: valueEnd)
                    }
                    directiveEnd = valueEnd
                    if valueEnd == end, end == scalars.endIndex, isStreaming {
                        pending = true
                        cursor = end
                        continue
                    }
                }

                let raw = String(scalars[rawStart..<valueEnd])
                guard admitValue(raw) else { clipped = true; return }
                guard directiveCount < AssistantMediaProjection.maximumDirectives else {
                    clipped = true
                    return
                }
                appendText(until: directiveStart)
                let directiveEndUTF8 = lineStartUTF8 + localUTF8
                runs.append(.media(Reference(
                    rawValue: raw, ordinal: directiveCount,
                    sourceUTF8Range: directiveStartUTF8..<directiveEndUTF8)))
                directiveCount += 1
                lastTextStart = directiveEnd
                cursor = directiveEnd
            }
        }

        mutating func appendText(until end: String.Index) {
            guard lastTextStart < end else { return }
            runs.append(.text(String(source[lastTextStart..<end])))
            lastTextStart = end
        }

        mutating func inspect(_ amount: Int) -> Bool {
            work += amount
            return work <= AssistantMediaProjection.maximumScanWork
        }

        mutating func firstNonHorizontalWhitespace(from start: String.Index,
                                                   to end: String.Index) -> String.Index? {
            let scalars = source.unicodeScalars
            var cursor = start
            while cursor < end, Self.isHorizontalWhitespace(scalars[cursor]) {
                guard inspect(1) else { clipped = true; return nil }
                cursor = scalars.index(after: cursor)
            }
            return cursor < end ? cursor : nil
        }

        mutating func isProtectedLine(first: String.Index?,
                                      lineEnd: String.Index) -> Bool {
            guard let first else { return false }
            let scalars = source.unicodeScalars
            if scalars[first] == ">" || scalars[first] == "{" {
                return true
            }
            if scalars[first] == "[" {
                var next = scalars.index(after: first)
                while next < lineEnd, Self.isHorizontalWhitespace(scalars[next]) {
                    next = scalars.index(after: next)
                }
                guard next < lineEnd else { return false }
                let marker = scalars[next]
                return marker == "[" || marker == "{" || marker == "\""
                    || marker == "]" || marker == "-"
                    || (48...57).contains(marker.value)
            }
            guard scalars[first] == "\"" else { return false }
            var cursor = scalars.index(after: first)
            while cursor < lineEnd {
                guard inspect(1) else { clipped = true; return true }
                if scalars[cursor] == "\"" {
                    let after = scalars.index(after: cursor)
                    var colon = after
                    while colon < lineEnd,
                          Self.isHorizontalWhitespace(scalars[colon]) {
                        colon = scalars.index(after: colon)
                    }
                    return colon < lineEnd && scalars[colon] == ":"
                }
                cursor = scalars.index(after: cursor)
            }
            return false
        }

        mutating func hasPrefix(_ literal: StaticString, at start: String.Index,
                                before end: String.Index) -> Bool {
            let scalars = source.unicodeScalars
            var cursor = start
            for expected in String(describing: literal).unicodeScalars {
                guard inspect(1), cursor < end, scalars[cursor] == expected else { return false }
                cursor = scalars.index(after: cursor)
            }
            return true
        }

        func hasDirectiveBoundary(before index: String.Index,
                                  lineStart: String.Index) -> Bool {
            guard index != lineStart else { return true }
            let scalars = source.unicodeScalars
            let previous = scalars[scalars.index(before: index)]
            return !(previous.isASCII
                && ((65...90).contains(previous.value)
                    || (97...122).contains(previous.value)
                    || (48...57).contains(previous.value)
                    || previous == "_"))
        }

        func admitValue(_ value: String) -> Bool {
            guard !value.isEmpty,
                  value.utf8.prefix(AssistantMediaProjection.maximumValueUTF8Bytes + 1).count
                    <= AssistantMediaProjection.maximumValueUTF8Bytes,
                  value.unicodeScalars.prefix(
                    AssistantMediaProjection.maximumValueScalars + 1).count
                    <= AssistantMediaProjection.maximumValueScalars else { return false }
            return !value.unicodeScalars.contains(where: Self.isUnsafe)
        }

        func failed() -> Projection {
            Projection(runs: [], isClipped: true, hasPendingDirective: false)
        }

        static func isUnsafe(_ scalar: UnicodeScalar) -> Bool {
            (scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r")
                || (0x7F...0x9F).contains(scalar.value)
                || scalar.value == 0x061C || (0x200E...0x200F).contains(scalar.value)
                || (0x202A...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value)
        }

        static func isHorizontalWhitespace(_ scalar: UnicodeScalar) -> Bool {
            scalar.properties.isWhitespace && !isLineBreak(scalar)
        }

        static func isLineBreak(_ scalar: UnicodeScalar) -> Bool {
            scalar == "\n" || scalar == "\r"
                || scalar.value == 0x2028 || scalar.value == 0x2029
        }
    }
}
