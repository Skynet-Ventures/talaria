import Foundation
import TalariaKit

public struct TranscriptFindAddress: Sendable, Equatable, Hashable {
    public var rowID: Int?
    public var author: MessageAuthor
    public var revisionID: UUID
    public var segment: Int

    public init(rowID: Int?, author: MessageAuthor, revisionID: UUID, segment: Int) {
        self.rowID = rowID
        self.author = author
        self.revisionID = revisionID
        self.segment = segment
    }

    public func identifies(_ message: ChatMessage) -> Bool {
        guard message.author == author else { return false }
        if let rowID { return message.rowID == rowID }
        return message.id == revisionID
    }
}

public struct TranscriptFindIndex: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var address: TranscriptFindAddress
        public var segments: [String]

        public init(address: TranscriptFindAddress, segments: [String]) {
            self.address = address
            self.segments = segments
        }

        public init(rowID: Int?, author: MessageAuthor, revisionID: UUID,
                    segments: [String]) {
            self.init(address: .init(rowID: rowID, author: author,
                                     revisionID: revisionID, segment: 0),
                      segments: segments)
        }
    }

    public var entries: [Entry]
    public var isTruncated: Bool

    public init(entries: [Entry] = [], isTruncated: Bool = false) {
        self.entries = entries
        self.isTruncated = isTruncated
    }
}

public struct TranscriptFindMatchGroup: Sendable, Equatable {
    public var address: TranscriptFindAddress
    public var count: Int
}

public struct TranscriptFindResult: Sendable, Equatable {
    public var query: String
    public var groups: [TranscriptFindMatchGroup]
    public var total: Int
    public var isTruncated: Bool

    public init(query: String = "", groups: [TranscriptFindMatchGroup] = [],
                total: Int = 0, isTruncated: Bool = false) {
        self.query = query
        self.groups = groups
        self.total = total
        self.isTruncated = isTruncated
    }
}

public struct TranscriptFindSelection: Sendable, Equatable {
    public var address: TranscriptFindAddress
    public var occurrenceInSegment: Int
    public var query: String
}

public struct TranscriptFindSourceIdentity: Sendable, Equatable, Hashable {
    public var botID: String
    public var storedSessionID: String
    public var liveSessionID: String
    public var gatewayID: String
    public var profile: String

    public init(botID: String, storedSessionID: String, liveSessionID: String,
                gatewayID: String = "", profile: String = "") {
        self.botID = botID
        self.storedSessionID = storedSessionID
        self.liveSessionID = liveSessionID
        self.gatewayID = gatewayID
        self.profile = profile
    }
}

public struct TranscriptFindResolvedStatus: Sendable, Equatable {
    public var visual: String
    public var accessibility: String
}

public enum TranscriptFindStatusPolicy {
    public static func resolved(result: TranscriptFindResult,
                                ordinal: Int) -> TranscriptFindResolvedStatus {
        if result.total == 0 {
            return result.isTruncated
                ? .init(visual: "No matches in indexed text+",
                        accessibility: "No matches in indexed text; transcript clipped")
                : .init(visual: "No matches", accessibility: "No matches")
        }
        let current = min(max(ordinal, 0), result.total - 1) + 1
        return result.isTruncated
            ? .init(visual: "\(current) of \(result.total)+",
                    accessibility: "Match \(current) of at least \(result.total)")
            : .init(visual: "\(current) of \(result.total)",
                    accessibility: "Match \(current) of \(result.total)")
    }
}

public enum TranscriptFindPolicy {
    public static let maximumIndexedCharacters = 1_000_000
    public static let maximumFieldCharacters = 64_000
    public static let maximumSourceCharactersPerMessage = 128_000
    public static let maximumSourceBytesPerMessage = 512_000
    public static let maximumSourceLinesPerMessage = 2_048
    public static let maximumSegmentsPerMessage = 512
    public static let maximumIndexedSegments = 4_096
    public static let maximumIndexedMessages = 1_000
    public static let maximumTraversedMessages = 1_000
    public static let maximumSearchedEntries = 1_000
    public static let maximumMatchGroups = 2_048
    public static let maximumMatches = 10_000
    public static let maximumQueryCharacters = 256
    public static let maximumQueryBytes = 1_024
    public static let minimumInteractiveDimension: CGFloat = 44
    public static let debounceMilliseconds: UInt64 = 180
    public static let indexDebounceMilliseconds: UInt64 = 120

    public static func allowsAutomaticFollow(hasSelection: Bool) -> Bool { !hasSelection }
    public static func allowsInitialAnchor(isFindOwningScroll: Bool) -> Bool {
        !isFindOwningScroll
    }
    public static func usesAnimatedNavigation(reducedMotion: Bool) -> Bool { !reducedMotion }
    public static func allowsHiddenDetailExpansion() -> Bool { false }
    public static func allowsJumpToLatest(isFindOwningScroll: Bool) -> Bool {
        !isFindOwningScroll
    }
    public static func nextSelectionScrollRevision(_ current: UInt64) -> UInt64 {
        current &+ 1
    }

    public static func isIndexReady(indexMessageGeneration: Int,
                                    currentMessageGeneration: Int,
                                    indexSource: TranscriptFindSourceIdentity,
                                    currentSource: TranscriptFindSourceIdentity) -> Bool {
        indexMessageGeneration == currentMessageGeneration && indexSource == currentSource
    }

    public static func isCurrent(
        _ result: TranscriptFindResult, query: String,
        resultIndexRevision: Int, currentIndexRevision: Int,
        resultMessageGeneration: Int, currentMessageGeneration: Int,
        resultSource: TranscriptFindSourceIdentity,
        currentSource: TranscriptFindSourceIdentity
    ) -> Bool {
        result.query == boundedQuery(query)
            && resultIndexRevision == currentIndexRevision
            && resultMessageGeneration == currentMessageGeneration
            && resultSource == currentSource
    }

    /// Builds a device-local index from the exact primary text bubbles. System
    /// rows, reasoning, cards, tool calls, and other detail surfaces are never
    /// read, so find cannot reveal or expand normally hidden content.
    public static func makeIndex(messages: [ChatMessage]) throws -> TranscriptFindIndex {
        var remainingCharacters = maximumIndexedCharacters
        var remainingSegments = maximumIndexedSegments
        var indexedMessages = 0
        var truncated = messages.count > maximumTraversedMessages
        var entries: [TranscriptFindIndex.Entry] = []
        entries.reserveCapacity(min(
            messages.count, maximumTraversedMessages, maximumIndexedMessages))

        // Search the newest bounded window, in ordinary transcript order.
        // Raw traversal is capped before author/empty filtering so excluded
        // rows cannot manufacture unbounded foreground indexing work.
        let window = messages.suffix(maximumTraversedMessages)
        for (offset, message) in window.enumerated() {
            if offset.isMultiple(of: 16) { try Task.checkCancellation() }
            guard message.author == .user || message.author == .bot else { continue }
            let visibleText = message.author == .bot
                ? GeneratedImageEchoPolicy.suppress(in: message)
                : message.text
            guard !visibleText.isEmpty else { continue }
            guard indexedMessages < maximumIndexedMessages,
                  remainingCharacters > 0, remainingSegments > 0 else {
                truncated = true
                break
            }
            indexedMessages += 1
            guard sourceIsAdmissible(visibleText) else {
                truncated = true
                continue
            }

            let projected = MarkdownParser.searchSegments(
                visibleText, isCancelled: { Task.isCancelled })
            try Task.checkCancellation()
            let allowance = min(maximumSegmentsPerMessage, remainingSegments)
            let admittedSegments = projected.prefix(allowance)
            if admittedSegments.count < projected.count { truncated = true }
            var segments: [String] = []
            segments.reserveCapacity(admittedSegments.count)
            for source in admittedSegments {
                guard remainingCharacters > 0 else {
                    truncated = true
                    break
                }
                let allowed = min(maximumFieldCharacters, remainingCharacters)
                let retained = scalarPrefix(source, maximum: allowed)
                segments.append(retained.text)
                remainingSegments -= 1
                remainingCharacters -= retained.text.unicodeScalars.count
                truncated = truncated || retained.truncated
            }
            if segments.contains(where: { !$0.isEmpty }) {
                entries.append(.init(
                    address: .init(rowID: message.rowID, author: message.author,
                                   revisionID: message.id, segment: 0),
                    segments: segments))
            }
        }
        return .init(entries: entries, isTruncated: truncated)
    }

    public static func admittedQueryInput(_ query: String) -> String {
        let bytes = query.utf8
        var byteEnd = bytes.index(bytes.startIndex, offsetBy: maximumQueryBytes,
                                  limitedBy: bytes.endIndex) ?? bytes.endIndex
        while String.Index(byteEnd, within: query) == nil, byteEnd > bytes.startIndex {
            byteEnd = bytes.index(before: byteEnd)
        }
        guard let stringEnd = String.Index(byteEnd, within: query) else { return "" }
        let byteBounded = query[..<stringEnd]
        var safe = String.UnicodeScalarView()
        safe.reserveCapacity(min(byteBounded.unicodeScalars.count, maximumQueryCharacters))
        for scalar in byteBounded.unicodeScalars {
            if safe.count >= maximumQueryCharacters { break }
            guard scalar.value >= 0x20, scalar.value != 0x7F,
                  !(0x80...0x9F).contains(scalar.value),
                  !(0x202A...0x202E).contains(scalar.value),
                  !(0x2066...0x2069).contains(scalar.value) else { continue }
            safe.append(scalar)
        }
        return String(safe)
    }

    public static func boundedQuery(_ query: String) -> String {
        admittedQueryInput(query).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func search(_ rawQuery: String, in index: TranscriptFindIndex) throws
        -> TranscriptFindResult {
        let query = boundedQuery(rawQuery)
        guard !query.isEmpty else { return TranscriptFindResult() }
        var groups: [TranscriptFindMatchGroup] = []
        var total = 0
        var inspected = 0
        var truncated = index.isTruncated
        if index.entries.count > maximumSearchedEntries { truncated = true }
        outer: for entry in index.entries.prefix(maximumSearchedEntries) {
            for (segment, text) in entry.segments.enumerated() {
                guard inspected < maximumIndexedSegments else {
                    truncated = true
                    break outer
                }
                inspected += 1
                if inspected.isMultiple(of: 16) { try Task.checkCancellation() }
                let capacity = maximumMatches - total
                guard capacity > 0, groups.count < maximumMatchGroups else {
                    truncated = true
                    break outer
                }
                let admittedText = scalarPrefix(text, maximum: maximumFieldCharacters)
                truncated = truncated || admittedText.truncated
                let match = try occurrenceCount(
                    of: query, in: admittedText.text, limit: capacity)
                guard match.count > 0 else { continue }
                total += match.count
                var address = entry.address
                address.segment = segment
                groups.append(.init(address: address, count: match.count))
                if match.truncated || total >= maximumMatches {
                    truncated = true
                    break outer
                }
            }
        }
        return .init(query: query, groups: groups, total: total, isTruncated: truncated)
    }

    public static func movedOrdinal(current: Int, delta: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        return ((current + delta) % total + total) % total
    }

    public static func selection(in result: TranscriptFindResult,
                                 ordinal: Int) -> TranscriptFindSelection? {
        guard ordinal >= 0, ordinal < result.total else { return nil }
        var offset = ordinal
        for group in result.groups {
            if offset < group.count {
                return .init(address: group.address, occurrenceInSegment: offset,
                             query: result.query)
            }
            offset -= group.count
        }
        return nil
    }

    public static func ordinal(of selection: TranscriptFindSelection,
                               in result: TranscriptFindResult) -> Int? {
        var offset = 0
        for group in result.groups {
            let sameMessage = selection.address.rowID.map {
                group.address.rowID == $0 && group.address.author == selection.address.author
            } ?? (group.address.revisionID == selection.address.revisionID
                  && group.address.author == selection.address.author)
            if sameMessage, group.address.segment == selection.address.segment,
               selection.occurrenceInSegment < group.count {
                return offset + selection.occurrenceInSegment
            }
            offset += group.count
        }
        return nil
    }

    static func range(of query: String, occurrence target: Int,
                      in text: String) -> Range<String.Index>? {
        guard !query.isEmpty, target >= 0 else { return nil }
        var occurrence = 0
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let range = text.range(
                of: query, options: [.caseInsensitive],
                range: cursor..<text.endIndex, locale: Locale(identifier: "en_US_POSIX")) {
            if occurrence == target { return range }
            occurrence += 1
            cursor = range.upperBound
        }
        return nil
    }

    private static func occurrenceCount(of query: String, in text: String, limit: Int) throws
        -> (count: Int, truncated: Bool) {
        var count = 0
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let range = text.range(
                of: query, options: [.caseInsensitive],
                range: cursor..<text.endIndex, locale: Locale(identifier: "en_US_POSIX")) {
            if count >= limit { return (count, true) }
            count += 1
            if count.isMultiple(of: 256) { try Task.checkCancellation() }
            cursor = range.upperBound
        }
        return (count, false)
    }

    private static func sourceIsAdmissible(_ source: String) -> Bool {
        let bytes = source.utf8
        if bytes.index(bytes.startIndex, offsetBy: maximumSourceBytesPerMessage + 1,
                       limitedBy: bytes.endIndex) != nil { return false }
        if source.unicodeScalars.index(
            source.unicodeScalars.startIndex,
            offsetBy: maximumSourceCharactersPerMessage + 1,
            limitedBy: source.unicodeScalars.endIndex) != nil { return false }
        var lines = 1
        for scalar in source.unicodeScalars {
            if scalar.value == 0x0A || scalar.value == 0x0D
                || scalar.value == 0x2028 || scalar.value == 0x2029 {
                lines += 1
                if lines > maximumSourceLinesPerMessage { return false }
            }
        }
        return true
    }

    private static func scalarPrefix(_ text: String, maximum: Int)
        -> (text: String, truncated: Bool) {
        var iterator = text.unicodeScalars.makeIterator()
        var output = String.UnicodeScalarView()
        var count = 0
        while count < maximum, let scalar = iterator.next() {
            output.append(scalar)
            count += 1
        }
        return (String(output), iterator.next() != nil)
    }
}
