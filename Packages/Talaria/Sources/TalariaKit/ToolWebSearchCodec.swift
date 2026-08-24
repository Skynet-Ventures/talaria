import Foundation

public struct ToolWebSearchHit: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var title: String
    public var url: String?
    public var snippet: String?

    public var destinationHost: String? {
        url.flatMap(ToolWebSearchCodec.destinationHost)
    }

    public init(id: Int, title: String, url: String? = nil, snippet: String? = nil) {
        self.id = id
        self.title = ToolWebSearchCodec.safeText(
            title, maximum: ToolWebSearchCodec.maximumTitleScalars).text ?? ""
        self.url = ToolWebSearchCodec.admittedURL(url)
        self.snippet = ToolWebSearchCodec.safeText(
            snippet, maximum: ToolWebSearchCodec.maximumSnippetScalars).text
    }

    private enum CodingKeys: String, CodingKey { case id, title, url, snippet }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: (try? values.decodeIfPresent(Int.self, forKey: .id)) ?? 0,
            title: (try? values.decodeIfPresent(String.self, forKey: .title)) ?? "",
            url: try? values.decodeIfPresent(String.self, forKey: .url),
            snippet: try? values.decodeIfPresent(String.self, forKey: .snippet))
    }
}

public struct ToolWebSearchOutput: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case available, malformed }

    public var state: State
    public var query: String?
    public var hits: [ToolWebSearchHit]
    public var isTruncated: Bool
    public var diagnostic: String?

    public init(state: State, query: String? = nil, hits: [ToolWebSearchHit] = [],
                isTruncated: Bool = false, diagnostic: String? = nil) {
        let queryAdmission = ToolWebSearchCodec.safeText(
            query, maximum: ToolWebSearchCodec.maximumQueryScalars)
        let diagnosticAdmission = ToolWebSearchCodec.safeText(
            diagnostic, maximum: ToolWebSearchCodec.maximumDiagnosticScalars)
        var normalized: [ToolWebSearchHit] = []
        var changed = hits.count > ToolWebSearchCodec.maximumHits
            || queryAdmission.truncated || diagnosticAdmission.truncated
        for source in hits.prefix(ToolWebSearchCodec.maximumHits) {
            let hit = ToolWebSearchHit(
                id: normalized.count, title: source.title,
                url: source.url, snippet: source.snippet)
            if hit.title.isEmpty, hit.url == nil { changed = true; continue }
            changed = changed || hit.title != source.title || hit.url != source.url
                || hit.snippet != source.snippet
            normalized.append(hit)
        }
        self.state = state
        self.query = queryAdmission.text
        self.hits = normalized
        self.isTruncated = isTruncated || changed
        self.diagnostic = diagnosticAdmission.text
    }

    private struct SnapshotHit: Decodable {
        var title: String
        var url: String?
        var snippet: String?
    }

    private enum CodingKeys: String, CodingKey {
        case state, query, hits, isTruncated, diagnostic
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        var hits: [ToolWebSearchHit] = []
        var changed = false
        var inspected = 0
        if var rows = try? values.nestedUnkeyedContainer(forKey: .hits) {
            while !rows.isAtEnd, inspected < ToolWebSearchCodec.maximumCandidateItems {
                inspected += 1
                if let row = try? rows.decode(SnapshotHit.self) {
                    let hit = ToolWebSearchHit(
                        id: hits.count, title: row.title,
                        url: row.url, snippet: row.snippet)
                    if hit.title.isEmpty, hit.url == nil { changed = true; continue }
                    if hits.count < ToolWebSearchCodec.maximumHits { hits.append(hit) }
                    else { changed = true }
                } else {
                    changed = true
                    _ = try? rows.decode(JSONValue.self)
                }
            }
            if !rows.isAtEnd { changed = true }
        }
        self.init(
            state: (try? values.decodeIfPresent(State.self, forKey: .state)) ?? .malformed,
            query: try? values.decodeIfPresent(String.self, forKey: .query),
            hits: hits,
            isTruncated: ((try? values.decodeIfPresent(Bool.self, forKey: .isTruncated))
                          ?? false) || changed,
            diagnostic: try? values.decodeIfPresent(String.self, forKey: .diagnostic))
        if inspected > 0, self.hits.isEmpty {
            state = .malformed
            diagnostic = diagnostic
                ?? "Saved web-search results contained no safe title or URL."
        }
    }

    public static func merging(newer: ToolWebSearchOutput?,
                               preserving older: ToolWebSearchOutput?) -> ToolWebSearchOutput? {
        guard let newer else { return older }
        guard let older else { return newer }
        return ToolWebSearchOutput(
            state: newer.state,
            query: newer.query ?? older.query,
            hits: newer.hits,
            isTruncated: newer.isTruncated,
            diagnostic: newer.diagnostic)
    }
}

public struct ToolWebSearchAdmission: Sendable, Equatable {
    public var output: ToolWebSearchOutput?
    public var hasExplicitError: Bool

    public init(output: ToolWebSearchOutput?, hasExplicitError: Bool) {
        self.output = output
        self.hasExplicitError = hasExplicitError
    }
}

/// Exact, bounded admission for Hermes' case-sensitive `web_search` result.
/// It never follows a URL and never derives hits from prose.
public enum ToolWebSearchCodec {
    public static let maximumHits = 6
    public static let maximumCandidateItems = 64
    public static let maximumTitleScalars = 256
    public static let maximumSnippetScalars = 600
    public static let maximumQueryScalars = 300
    public static let maximumDiagnosticScalars = 280
    public static let maximumURLScalars = 2_048
    public static let maximumRawFieldScalars = 10_000
    public static let maximumContainerScalars = 80_000
    public static let maximumTraversalNodes = 256
    public static let maximumTraversalDepth = 6

    private static let resultKeys = [
        "web", "results", "search_results", "sources", "web_sources",
        "items", "organic_results", "organic", "matches", "documents",
    ]
    private static let wrapperKeys = ["data", "result", "output", "response", "payload"]

    public static func isWebSearchTool(_ name: String) -> Bool { name == "web_search" }

    public static func admit(toolName: String, arguments: JSONValue?,
                             result: JSONValue?) -> ToolWebSearchAdmission {
        guard isWebSearchTool(toolName) else {
            return ToolWebSearchAdmission(output: nil, hasExplicitError: false)
        }
        return candidateAdmission(arguments: arguments, result: result)
    }

    /// Bounded search-shaped material and its search-specific error signal.
    /// Both remain inert until exact-ID pairing establishes `web_search`.
    public static func candidateAdmission(arguments: JSONValue?,
                                          result: JSONValue?) -> ToolWebSearchAdmission {
        let output = candidate(arguments: arguments, result: result)
        var errorBudget = TraversalBudget()
        return ToolWebSearchAdmission(
            output: output,
            hasExplicitError: explicitError(
                in: decodedContainer(result), depth: 0, budget: &errorBudget))
    }

    /// Bounded inert material used when an exact completion/result omits its
    /// name. Promotion still requires an exact-ID `web_search` start/call.
    public static func candidate(arguments: JSONValue?,
                                 result: JSONValue?) -> ToolWebSearchOutput? {
        guard let container = decodedContainer(result) else { return nil }
        var budget = TraversalBudget()
        let found = findItems(in: container, depth: 0, budget: &budget)
        guard found.found else { return nil }

        var hits: [ToolWebSearchHit] = []
        var malformed = found.malformed ? 1 : 0
        var truncated = found.truncated || budget.exhausted
        for item in found.items.prefix(maximumCandidateItems) {
            guard budget.consume(), let row = decodedObject(item) else {
                malformed += 1
                if budget.exhausted { truncated = true; break }
                continue
            }
            let title = safeText(
                firstString(in: row, keys: ["title", "name"]),
                maximum: maximumTitleScalars)
            let snippet = safeText(
                firstString(in: row, keys: ["snippet", "description", "body", "content"]),
                maximum: maximumSnippetScalars)
            let rawURL = firstString(in: row, keys: ["url", "href", "link"])
            let url = admittedURL(rawURL)
            if hasNonString(in: row, keys: ["title", "name", "url", "href", "link",
                                                   "snippet", "description", "body", "content"])
                || (rawURL != nil && url == nil) {
                malformed += 1
            }
            truncated = truncated || title.truncated || snippet.truncated
            let cleanTitle = title.text ?? ""
            guard !cleanTitle.isEmpty || url != nil else { malformed += 1; continue }
            if hits.count == maximumHits { truncated = true; break }
            hits.append(ToolWebSearchHit(
                id: hits.count, title: cleanTitle, url: url, snippet: snippet.text))
        }
        if found.items.count > maximumCandidateItems { truncated = true }
        let state: ToolWebSearchOutput.State = hits.isEmpty && malformed > 0
            ? .malformed : .available
        let diagnostic: String?
        if state == .malformed {
            diagnostic = "Hermes retained web-search results, but none had a safe title or URL."
        } else if truncated {
            diagnostic = "Additional web-search results exceeded the mobile display budget."
        } else if malformed > 0 {
            diagnostic = "Some web-search entries were omitted because their fields were malformed or unsafe."
        } else {
            diagnostic = nil
        }
        return ToolWebSearchOutput(
            state: state, query: query(from: arguments), hits: hits,
            isTruncated: truncated, diagnostic: diagnostic)
    }

    public static func query(from arguments: ToolPayload?) -> String? {
        query(from: arguments?.json)
    }

    public static func query(from arguments: JSONValue?) -> String? {
        guard let object = decodedObject(arguments) else { return nil }
        return safeText(
            firstString(in: object, keys: ["search_term", "query"]),
            maximum: maximumQueryScalars).text
    }

    public static func admittedURL(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let bounded = scalarPrefix(raw, maximum: maximumURLScalars)
        guard !bounded.truncated, !raw.contains("\\"),
              !raw.unicodeScalars.contains(where: { unsafeURLScalar($0.value) }),
              let decoded = raw.removingPercentEncoding,
              !decoded.contains("\\"),
              !decoded.unicodeScalars.contains(where: { unsafeURLScalar($0.value) }),
              var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil, components.password == nil,
              let host = components.host, !host.isEmpty else { return nil }
        components.scheme = scheme
        guard let url = components.url, url.host?.isEmpty == false else { return nil }
        return url.absoluteString
    }

    public static func destinationHost(_ admittedURL: String) -> String? {
        guard let safe = self.admittedURL(admittedURL),
              let host = URLComponents(string: safe)?.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }

    static func safeText(_ raw: String?, maximum: Int,
                         trimsEdges: Bool = true) -> (text: String?, truncated: Bool) {
        guard let raw else { return (nil, false) }
        let sanitized = sanitize(raw)
        let bounded = scalarPrefix(sanitized.text, maximum: maximum)
        let text = trimsEdges
            ? bounded.text.trimmingCharacters(in: .whitespacesAndNewlines)
            : bounded.text
        return (text.isEmpty ? nil : text,
                sanitized.truncated || bounded.truncated)
    }

    private struct TraversalBudget {
        var nodes = 0
        var exhausted = false
        mutating func consume() -> Bool {
            guard nodes < maximumTraversalNodes else { exhausted = true; return false }
            nodes += 1
            return true
        }
    }

    private struct FoundItems {
        var found: Bool
        var items: [JSONValue]
        var truncated: Bool
        var malformed: Bool
    }

    private static func findItems(in value: JSONValue, depth: Int,
                                  budget: inout TraversalBudget) -> FoundItems {
        guard depth <= maximumTraversalDepth, budget.consume() else {
            return FoundItems(found: false, items: [], truncated: true, malformed: true)
        }
        if let array = value.arrayValue {
            return FoundItems(
                found: true, items: Array(array.prefix(maximumCandidateItems + 1)),
                truncated: array.count > maximumCandidateItems, malformed: false)
        }
        guard let object = value.objectValue else {
            return FoundItems(found: false, items: [], truncated: false, malformed: false)
        }
        var malformed = false
        var truncated = false
        for key in resultKeys {
            guard budget.consume() else { break }
            guard let child = object[key], child != .null else { continue }
            if let array = child.arrayValue {
                return FoundItems(
                    found: true, items: Array(array.prefix(maximumCandidateItems + 1)),
                    truncated: truncated || array.count > maximumCandidateItems,
                    malformed: malformed)
            }
            if child.objectValue != nil || child.stringValue != nil {
                let nested = findItems(in: child, depth: depth + 1, budget: &budget)
                if nested.found {
                    return FoundItems(
                        found: true, items: nested.items,
                        truncated: truncated || nested.truncated,
                        malformed: malformed || nested.malformed)
                }
                malformed = malformed || nested.malformed
                truncated = truncated || nested.truncated
            } else {
                malformed = true
            }
        }
        for key in wrapperKeys {
            guard budget.consume() else { break }
            guard let child = object[key], child != .null else { continue }
            let nested = findItems(in: child, depth: depth + 1, budget: &budget)
            if nested.found { return nested }
            // The first non-null wrapper is authoritative; do not scan later
            // siblings looking for a more convenient shape.
            return FoundItems(
                found: nested.malformed, items: [],
                truncated: nested.truncated, malformed: true)
        }
        return FoundItems(
            found: malformed, items: [],
            truncated: truncated || budget.exhausted, malformed: malformed)
    }

    private static func decodedContainer(_ value: JSONValue?) -> JSONValue? {
        guard let value, value != .null else { return nil }
        guard let text = value.stringValue else { return value }
        let bounded = scalarPrefix(text, maximum: maximumContainerScalars)
        guard !bounded.truncated, let data = bounded.text.data(using: .utf8),
              data.count <= maximumContainerScalars else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func decodedObject(_ value: JSONValue?) -> [String: JSONValue]? {
        guard let value else { return nil }
        if let object = value.objectValue { return object }
        guard let text = value.stringValue else { return nil }
        let bounded = scalarPrefix(text, maximum: maximumRawFieldScalars)
        guard !bounded.truncated, let data = bounded.text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return decoded.objectValue
    }

    private static func firstString(in object: [String: JSONValue],
                                    keys: [String]) -> String? {
        for key in keys {
            if let value = object[key]?.stringValue { return value }
        }
        return nil
    }

    private static func hasNonString(in object: [String: JSONValue],
                                     keys: [String]) -> Bool {
        keys.contains { key in
            guard let value = object[key], value != .null else { return false }
            return value.stringValue == nil
        }
    }

    private static func explicitError(in value: JSONValue?, depth: Int,
                                      budget: inout TraversalBudget) -> Bool {
        guard depth <= maximumTraversalDepth, budget.consume(),
              let value, value != .null else { return false }
        if let array = value.arrayValue {
            for child in array.prefix(maximumCandidateItems) {
                if explicitError(in: child, depth: depth + 1, budget: &budget) {
                    return true
                }
            }
            return false
        }
        guard let object = value.objectValue else { return false }
        for key in ["error", "errors", "failure", "exception"] {
            if ToolPayloadCodec.valueIsExplicitError(object[key]) { return true }
        }
        if object["is_error"]?.boolValue == true
            || object["success"]?.boolValue == false
            || object["ok"]?.boolValue == false { return true }
        for key in wrapperKeys {
            if explicitError(in: object[key], depth: depth + 1, budget: &budget) {
                return true
            }
        }
        return false
    }

    private static func unsafeURLScalar(_ value: UInt32) -> Bool {
        value <= 0x20 || (0x7F...0x9F).contains(value) || isBidi(value)
    }

    private static func sanitize(_ source: String) -> (text: String, truncated: Bool) {
        let admitted = scalarPrefix(source, maximum: maximumRawFieldScalars)
        let scalars = Array(admitted.text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        func stringControl(_ start: Int, bell: Bool) -> Int {
            var cursor = start
            while cursor < scalars.count {
                let value = scalars[cursor].value
                if value == 0x9C || (bell && value == 0x07) { return cursor + 1 }
                if value == 0x1B, cursor + 1 < scalars.count,
                   scalars[cursor + 1].value == 0x5C { return cursor + 2 }
                cursor += 1
            }
            return scalars.count
        }
        func csi(_ start: Int) -> Int {
            var cursor = start
            while cursor < scalars.count {
                if (0x40...0x7E).contains(scalars[cursor].value) { return cursor + 1 }
                cursor += 1
            }
            return scalars.count
        }
        func escape(_ start: Int) -> Int {
            var cursor = start
            while cursor < scalars.count, (0x20...0x2F).contains(scalars[cursor].value) {
                cursor += 1
            }
            return cursor < scalars.count ? cursor + 1 : scalars.count
        }
        while index < scalars.count {
            let value = scalars[index].value
            if value == 0x1B {
                guard index + 1 < scalars.count else { break }
                let next = scalars[index + 1].value
                if next == 0x5B { index = csi(index + 2); continue }
                if [0x5D, 0x50, 0x58, 0x5E, 0x5F].contains(next) {
                    index = stringControl(index + 2, bell: next == 0x5D); continue
                }
                index = escape(index + 1); continue
            }
            if value == 0x9B { index = csi(index + 1); continue }
            if [0x90, 0x98, 0x9D, 0x9E, 0x9F].contains(value) {
                index = stringControl(index + 1, bell: value == 0x9D); continue
            }
            if isBidi(value) || (value < 0x20 && value != 0x09 && value != 0x0A)
                || (0x7F...0x9F).contains(value) {
                index += 1; continue
            }
            output.append(scalars[index])
            index += 1
        }
        return (String(output), admitted.truncated)
    }

    private static func scalarPrefix(_ text: String,
                                     maximum: Int) -> (text: String, truncated: Bool) {
        guard maximum > 0 else { return ("", !text.isEmpty) }
        var iterator = text.unicodeScalars.makeIterator()
        var output = String.UnicodeScalarView()
        var count = 0
        while count < maximum, let scalar = iterator.next() {
            output.append(scalar); count += 1
        }
        return (String(output), iterator.next() != nil)
    }

    private static func isBidi(_ value: UInt32) -> Bool {
        value == 0x061C || value == 0x200E || value == 0x200F
            || (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value)
    }
}
