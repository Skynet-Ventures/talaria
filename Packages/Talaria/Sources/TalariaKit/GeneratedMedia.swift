import Foundation

/// Bounded, portable evidence from an exact Hermes `image_generate` result.
/// The source remains inert until the UI binds it to the producing chat.
public struct ToolGeneratedImage: Codable, Sendable, Equatable {
    public enum Aspect: String, Codable, Sendable {
        case landscape, square, portrait

        public var ratio: Double {
            switch self {
            case .landscape: 16.0 / 9.0
            case .square: 1
            case .portrait: 9.0 / 16.0
            }
        }
    }

    public enum SourceKind: String, Codable, Sendable {
        case gatewayPath, remoteURL
    }

    public var source: String
    public var sourceKind: SourceKind
    public var aspect: Aspect
    /// Exact documented result fields used only after this output has exact,
    /// successful tool authority. `agent_visible_image` is echo-only.
    public var echoSources: [String]

    public init?(source: String, sourceKind: SourceKind, aspect: Aspect,
                 echoSources: [String] = []) {
        guard let admitted = ToolGeneratedImageCodec.admittedSource(source),
              admitted.kind == sourceKind else {
            return nil
        }
        self.source = admitted.value
        self.sourceKind = sourceKind
        self.aspect = aspect
        self.echoSources = ToolGeneratedImageCodec.admittedEchoSources(echoSources)
    }

    private enum CodingKeys: String, CodingKey {
        case source, sourceKind, aspect, echoSources
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawSource = try values.decode(String.self, forKey: .source)
        let rawKind = try values.decode(SourceKind.self, forKey: .sourceKind)
        guard let admitted = ToolGeneratedImageCodec.admittedSource(rawSource),
              admitted.kind == rawKind else {
            throw DecodingError.dataCorruptedError(
                forKey: .source, in: values,
                debugDescription: "Generated image source is not safely admitted.")
        }
        source = admitted.value
        sourceKind = rawKind
        aspect = try values.decodeIfPresent(Aspect.self, forKey: .aspect) ?? .landscape
        echoSources = ToolGeneratedImageCodec.admittedEchoSources(
            try values.decodeIfPresent([String].self, forKey: .echoSources) ?? [])
    }

    public static func merging(newer: ToolGeneratedImage?,
                               preserving older: ToolGeneratedImage?) -> ToolGeneratedImage? {
        newer ?? older
    }
}

public enum ToolGeneratedImageCodec {
    public static let exactToolName = "image_generate"
    public static let maximumPathOrURLScalars = 2_048
    public static let maximumSerializedResultBytes = 80_000
    public static let maximumGatewayMediaResponseBytes = 16_781_312
    public static let maximumInlineDecodedBytes = 12 * 1_024 * 1_024
    public static let maximumEchoSources = 3

    public struct AdmittedSource: Sendable, Equatable {
        public var value: String
        public var kind: ToolGeneratedImage.SourceKind
    }

    public static func isGeneratedImageTool(_ name: String) -> Bool {
        name == exactToolName
    }

    /// Candidate parsing is name-free so a nameless completion can remain a
    /// bounded Codable placeholder until an exact-id start supplies authority.
    public static func candidate(arguments: ToolPayload?, result: JSONValue?)
        -> ToolGeneratedImage? {
        guard let record = record(from: result), record["success"]?.boolValue == true else {
            return nil
        }
        let display = [record["host_image"]?.stringValue, record["image"]?.stringValue]
            .compactMap { admittedSource($0) }.first
        guard let display else { return nil }
        let echoes = admittedEchoSources([
            record["host_image"]?.stringValue,
            record["image"]?.stringValue,
            record["agent_visible_image"]?.stringValue,
        ].compactMap { $0 })
        return ToolGeneratedImage(
            source: display.value, sourceKind: display.kind,
            aspect: aspectHint(from: arguments), echoSources: echoes)
    }

    public static func admit(toolName: String, arguments: ToolPayload?,
                             result: JSONValue?) -> ToolGeneratedImage? {
        guard isGeneratedImageTool(toolName) else { return nil }
        return candidate(arguments: arguments, result: result)
    }

    public static func admittedSource(_ raw: String?) -> AdmittedSource? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !containsUnsafeScalar(value) else { return nil }
        let lower = value.lowercased()

        guard !lower.hasPrefix("data:") else { return nil }

        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard value.unicodeScalars.prefix(maximumPathOrURLScalars + 1).count
                    <= maximumPathOrURLScalars,
                  !value.contains("\\"),
                  let decoded = value.removingPercentEncoding,
                  !containsUnsafeScalar(decoded),
                  let parts = URLComponents(string: value),
                  let scheme = parts.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = parts.host, !host.isEmpty,
                  parts.user == nil, parts.password == nil,
                  RemoteGeneratedImagePolicy.hostIsPublic(host) else { return nil }
            return AdmittedSource(value: value, kind: .remoteURL)
        }

        guard value.unicodeScalars.prefix(maximumPathOrURLScalars + 1).count
                <= maximumPathOrURLScalars,
              !value.contains("%") else { return nil }
        var path = value
        if lower.hasPrefix("file://") {
            guard let url = URL(string: value), url.scheme?.lowercased() == "file",
                  url.host == nil || url.host?.isEmpty == true || url.host == "localhost"
            else { return nil }
            path = url.path(percentEncoded: false)
        } else if value.contains(":") {
            // A drive letter is the only colon-bearing non-URL path form.
            guard value.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
            else { return nil }
        }
        let normalized: String
        if path.hasPrefix("~/") {
            normalized = path
        } else {
            guard let parsed = WorkspaceRemotePath.normalized(path),
                  WorkspaceRemotePath.isAbsolute(parsed),
                  !WorkspaceRemotePath.isFilesystemRoot(parsed) else { return nil }
            normalized = parsed
        }
        let ext = URL(fileURLWithPath: normalized).pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "bmp"]
            .contains(ext) else { return nil }
        return AdmittedSource(value: normalized, kind: .gatewayPath)
    }

    public static func admittedEchoSources(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in values {
            guard result.count < maximumEchoSources else { break }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !containsUnsafeScalar(value),
                  value.unicodeScalars.prefix(maximumPathOrURLScalars + 1).count
                    <= maximumPathOrURLScalars,
                  seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }

    public static func inlineDataDecodedUpperBound(_ value: String) -> Int? {
        guard let comma = value.firstIndex(of: ",") else { return nil }
        let metadata = value[value.startIndex..<comma].lowercased()
        let allowed = ["data:image/png;base64", "data:image/jpeg;base64",
                       "data:image/webp;base64", "data:image/gif;base64",
                       "data:image/heic;base64", "data:image/heif;base64",
                       "data:image/bmp;base64"]
        guard allowed.contains(String(metadata)) else { return nil }
        let encoded = value[value.index(after: comma)...]
        let maximumEncoded = ((maximumInlineDecodedBytes + 2) / 3) * 4
        guard encoded.utf8.count <= maximumEncoded,
              encoded.unicodeScalars.allSatisfy({ scalar in
                  (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
                    || (48...57).contains(scalar.value) || scalar == "+"
                    || scalar == "/" || scalar == "="
              }) else { return nil }
        let padding = encoded.suffix(2).reduce(0) { $1 == "=" ? $0 + 1 : $0 }
        guard padding <= 2 else { return nil }
        let upper = ((encoded.utf8.count + 3) / 4) * 3 - padding
        return upper <= maximumInlineDecodedBytes ? upper : nil
    }

    public static func aspectHint(from arguments: ToolPayload?) -> ToolGeneratedImage.Aspect {
        var object = arguments?.json?.objectValue
        if object == nil, let text = arguments?.text,
           text.utf8.count <= ToolPayloadCodec.maximumArgumentCharacters,
           let data = text.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) {
            object = decoded.objectValue
        }
        let raw = object?["aspect_ratio"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ToolGeneratedImage.Aspect(rawValue: raw ?? "") ?? .landscape
    }

    public static func applyingAspectHint(_ image: ToolGeneratedImage?,
                                          arguments: ToolPayload?) -> ToolGeneratedImage? {
        guard let image else { return nil }
        return ToolGeneratedImage(source: image.source, sourceKind: image.sourceKind,
                                  aspect: aspectHint(from: arguments),
                                  echoSources: image.echoSources)
    }

    private static func record(from result: JSONValue?) -> [String: JSONValue]? {
        guard let result, result != .null else { return nil }
        if let object = result.objectValue { return object }
        guard let text = result.stringValue,
              text.utf8.count <= maximumSerializedResultBytes,
              let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        return decoded.objectValue
    }

    private static func containsUnsafeScalar(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
                || scalar.value == 0x061C || (0x200E...0x200F).contains(scalar.value)
                || (0x202A...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value)
        }
    }
}

public enum RemoteGeneratedImagePolicy {
    /// Reject names and literal addresses that are inherently local/private.
    /// The explicit loader additionally rejects redirects.
    public static func hostIsPublic(_ raw: String) -> Bool {
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty, host != "localhost", !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local") else { return false }
        if host == "::" || host == "::1" || host == "0:0:0:0:0:0:0:1"
            || (host.contains(":") && (host.hasPrefix("fe80:")
                || host.hasPrefix("fc") || host.hasPrefix("fd")
                || host.hasPrefix("ff"))) { return false }
        if host.hasPrefix("::ffff:"),
           ipv4IsPrivate(String(host.dropFirst("::ffff:".count))) { return false }
        if host.allSatisfy(\.isNumber) { return false }
        return !ipv4IsPrivate(host)
    }

    private static func ipv4IsPrivate(_ host: String) -> Bool {
        let pieces = host.split(separator: ".")
        let octets = pieces.compactMap { UInt8($0) }
        if pieces.count == 4, octets.count == 4 {
            let a = octets[0], b = octets[1], c = octets[2]
            if a == 0 || a == 10 || a == 127 || (a == 169 && b == 254)
                || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
                || (a == 100 && (64...127).contains(b))
                || (a == 192 && (b == 0 || b == 2))
                || (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100)))
                || (a == 203 && b == 0 && c == 113)
                || a >= 224 { return true }
        }
        return false
    }
}

public enum GeneratedImageEchoPolicy {
    public static let maximumTranscriptScalars = 128_000

    public static func hasSuccessfulAuthority(_ call: ToolCall) -> Bool {
        call.name == ToolGeneratedImageCodec.exactToolName
            && call.state == .done && call.generatedImage != nil
            && call.gatewayToolID?.isEmpty == false
            && (call.provenance == .live || call.provenance == .stored)
    }

    public static func suppress(in text: String, calls: [ToolCall]) -> String {
        guard !text.isEmpty,
              text.unicodeScalars.prefix(maximumTranscriptScalars + 1).count
                <= maximumTranscriptScalars else { return text }
        let sources = ToolGeneratedImageCodec.admittedEchoSources(calls.flatMap { call in
            hasSuccessfulAuthority(call) ? (call.generatedImage?.echoSources ?? []) : []
        })
        guard !sources.isEmpty else { return text }

        var next = text
        for source in sources {
            let escaped = NSRegularExpression.escapedPattern(for: source)
            var mediaAllowed = CharacterSet.alphanumerics
            mediaAllowed.insert(charactersIn: "-_.~")
            let encoded = source.addingPercentEncoding(
                withAllowedCharacters: mediaAllowed) ?? source
            let mediaTargets = [source, encoded].map(NSRegularExpression.escapedPattern)
                .joined(separator: "|")
            for pattern in [
                #"!\[[^\]\n]{0,240}\]\(\s*<?"# + escaped
                    + #">?(?:\s+\"[^\"\n]{0,240}\")?\s*\)"#,
                #"\[[^\]\n]{0,240}\]\(\s*#media:(?:"# + mediaTargets + #")\s*\)"#,
            ] {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(next.startIndex..<next.endIndex, in: next)
                next = regex.stringByReplacingMatches(in: next, range: range, withTemplate: "")
            }
            let pattern = #"(^|[\s(\[{])<?"# + escaped
                + #">?(?=$|[\s)\]},]|[.!?](?=$|\s))"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(next.startIndex..<next.endIndex, in: next)
            next = regex.stringByReplacingMatches(in: next, range: range, withTemplate: "$1")
        }
        return next
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public extension GatewayClient {
    func generatedMediaDataURL(path: String) async throws -> String {
        let payload = try await restJSONBoundedNoRedirect(
            path: "api/media",
            query: [URLQueryItem(name: "path", value: path)],
            maximumResponseBytes: ToolGeneratedImageCodec.maximumGatewayMediaResponseBytes)
        guard let value = payload["data_url"]?.stringValue,
              ToolGeneratedImageCodec.inlineDataDecodedUpperBound(value) != nil else {
            throw GatewayError(code: 404, message: "Gateway returned no bounded image media.")
        }
        return value
    }
}

public enum GeneratedRemoteImageLoader {
    public static func load(_ url: URL) async throws -> Data {
        guard let host = url.host(), RemoteGeneratedImagePolicy.hostIsPublic(host),
              url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https"
        else { throw GatewayError(code: 403, message: "Private image hosts are not allowed.") }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = "GET"
        let (data, response) = try await GatewayBoundedRESTLoader.load(
            request, limit: ToolGeneratedImageCodec.maximumInlineDecodedBytes,
            rejectsRedirects: true)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              http.mimeType?.lowercased().hasPrefix("image/") == true else {
            throw GatewayError(code: 415, message: "Remote response was not an image.")
        }
        return data
    }
}
