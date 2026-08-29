import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

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
        guard let admittedEchoes = ToolGeneratedImageCodec.admittedEchoSources(echoSources)
        else { return nil }
        self.echoSources = admittedEchoes
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
        if values.contains(.echoSources) {
            var encoded = try values.nestedUnkeyedContainer(forKey: .echoSources)
            if let count = encoded.count, count > ToolGeneratedImageCodec.maximumEchoSources {
                throw DecodingError.dataCorruptedError(
                    forKey: .echoSources, in: values,
                    debugDescription: "Too many generated-image echo sources.")
            }
            var decoded: [String] = []
            decoded.reserveCapacity(min(encoded.count ?? 0,
                                        ToolGeneratedImageCodec.maximumEchoSources))
            while !encoded.isAtEnd {
                guard decoded.count < ToolGeneratedImageCodec.maximumEchoSources else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .echoSources, in: values,
                        debugDescription: "Too many generated-image echo sources.")
                }
                decoded.append(try encoded.decode(String.self))
            }
            guard let admitted = ToolGeneratedImageCodec.admittedEchoSources(decoded) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .echoSources, in: values,
                    debugDescription: "Generated-image echo source exceeded its bound.")
            }
            echoSources = admitted
        } else {
            echoSources = []
        }
    }

    public static func merging(newer: ToolGeneratedImage?,
                               preserving older: ToolGeneratedImage?) -> ToolGeneratedImage? {
        newer ?? older
    }
}

public enum ToolGeneratedImageCodec {
    public static let exactToolName = "image_generate"
    public static let maximumPathOrURLScalars = 2_048
    public static let maximumPathOrURLBytes = 8_192
    public static let maximumSerializedResultBytes = ToolPayloadCodec.maximumResultCharacters
    public static let maximumResultObjectFields = 32
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
        let echoes = [
            record["host_image"]?.stringValue,
            record["image"]?.stringValue,
            record["agent_visible_image"]?.stringValue,
        ].compactMap { $0 }.compactMap(admittedEchoSource)
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
        guard raw.utf8.count <= maximumPathOrURLBytes,
              raw.unicodeScalars.prefix(maximumPathOrURLScalars + 1).count
                <= maximumPathOrURLScalars else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !containsUnsafeScalar(value) else { return nil }
        let lower = value.lowercased()

        guard !lower.hasPrefix("data:") else { return nil }

        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard !value.contains("\\"),
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

        guard !value.contains("%") else { return nil }
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
        guard ["png", "jpg", "jpeg", "webp", "gif", "bmp"]
            .contains(ext) else { return nil }
        return AdmittedSource(value: normalized, kind: .gatewayPath)
    }

    public static func admittedEchoSource(_ raw: String) -> String? {
        guard raw.utf8.count <= maximumPathOrURLBytes,
              raw.unicodeScalars.prefix(maximumPathOrURLScalars + 1).count
                <= maximumPathOrURLScalars else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !containsUnsafeScalar(value) else { return nil }
        return value
    }

    public static func admittedEchoSources(_ values: [String]) -> [String]? {
        guard values.count <= maximumEchoSources else { return nil }
        var seen = Set<String>()
        var result: [String] = []
        for raw in values {
            guard let value = admittedEchoSource(raw) else { return nil }
            guard seen.insert(value).inserted else { continue }
            result.append(value)
        }
        return result
    }

    public static func inlineDataDecodedUpperBound(_ value: String) -> Int? {
        let maximumEncoded = ((maximumInlineDecodedBytes + 2) / 3) * 4
        guard value.utf8.count <= maximumEncoded + 40,
              value.unicodeScalars.prefix(maximumEncoded + 41).count
                <= maximumEncoded + 40,
              let comma = value.firstIndex(of: ","),
              let utf8Comma = comma.samePosition(in: value.utf8),
              value.utf8.distance(from: value.utf8.startIndex,
                                  to: utf8Comma) <= 32
        else { return nil }
        let metadata = value[value.startIndex..<comma].lowercased()
        let allowed = ["data:image/png;base64", "data:image/jpeg;base64",
                       "data:image/webp;base64", "data:image/gif;base64",
                       "data:image/bmp;base64"]
        guard allowed.contains(String(metadata)) else { return nil }
        let encoded = value[value.index(after: comma)...]
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
        if let object = result.objectValue {
            return object.count <= maximumResultObjectFields ? object : nil
        }
        guard let text = result.stringValue,
              text.utf8.count <= maximumSerializedResultBytes,
              let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        guard let object = decoded.objectValue,
              object.count <= maximumResultObjectFields else { return nil }
        return object
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
    public static let maximumResolvedAddresses = 64
    public static let maximumBlockingResolvers = 2
    public static let resolverDeadlineSeconds: TimeInterval = 2

    public enum ResolvedAddress: Sendable, Equatable {
        case ipv4(UInt8, UInt8, UInt8, UInt8)
        case ipv6([UInt8])
    }

    typealias Resolver = @Sendable (String) async -> [ResolvedAddress]?
    public typealias BlockingResolver = @Sendable (String) -> [ResolvedAddress]?
    public typealias WorkerDispatcher = @Sendable (@escaping @Sendable () -> Void) -> Void
    public typealias DeadlineCancellation = @Sendable () -> Void
    public typealias DeadlineScheduler = @Sendable (
        @escaping @Sendable () -> Void
    ) -> DeadlineCancellation

    public final class ResolutionGate: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var active = 0

        public init(limit: Int = maximumBlockingResolvers) {
            self.limit = max(1, limit)
        }

        fileprivate func acquire() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard active < limit else { return false }
            active += 1
            return true
        }

        fileprivate func release() {
            lock.lock()
            active = max(0, active - 1)
            lock.unlock()
        }

        var activeCountForTesting: Int {
            lock.lock()
            defer { lock.unlock() }
            return active
        }
    }

    private final class ResolutionAttempt: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[ResolvedAddress]?, Never>?
        private var finished = false
        private var result: [ResolvedAddress]?
        private var cancelDeadline: DeadlineCancellation?

        func install(_ continuation: CheckedContinuation<[ResolvedAddress]?, Never>) {
            lock.lock()
            if finished {
                let result = result
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func claim(_ gate: ResolutionGate) -> Bool {
            lock.lock()
            guard !finished else { lock.unlock(); return false }
            let admitted = gate.acquire()
            lock.unlock()
            return admitted
        }

        func setDeadlineCancellation(_ cancellation: @escaping DeadlineCancellation) {
            lock.lock()
            if finished {
                lock.unlock()
                cancellation()
            } else {
                cancelDeadline = cancellation
                lock.unlock()
            }
        }

        func finish(_ result: [ResolvedAddress]?) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            self.result = result
            let continuation = continuation
            let cancellation = cancelDeadline
            self.continuation = nil
            cancelDeadline = nil
            lock.unlock()
            cancellation?()
            continuation?.resume(returning: result)
        }
    }

    private static let systemResolutionGate = ResolutionGate()

    public static func hostIsPublic(_ raw: String) -> Bool {
        guard raw.utf8.count <= 253 else { return false }
        var host = raw.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host != "localhost", !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"), !host.contains("%") else { return false }
        if let literal = parsedLiteral(host) {
            if case .ipv4(let a, let b, let c, let d) = literal,
               host != "\(a).\(b).\(c).\(d)" { return false }
            return addressIsPublic(literal)
        }

        // inet_pton intentionally rejects legacy IPv4 spellings. Fail closed
        // for strings made only from the numeric-address alphabet so octal,
        // hexadecimal, shortened, and overflow forms are never sent to DNS.
        let numericAlphabet = CharacterSet(charactersIn: "0123456789abcdefx.:")
        if host.unicodeScalars.allSatisfy({ numericAlphabet.contains($0) }) {
            return false
        }
        return true
    }

    public static func resolvedHostIsPublic(_ raw: String) async -> Bool {
        await resolvedHostIsPublic(raw, resolver: { host in
            await systemResolve(host)
        })
    }

    static func resolvedHostIsPublic(_ raw: String, resolver: Resolver) async -> Bool {
        guard hostIsPublic(raw) else { return false }
        var host = raw.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst(); host.removeLast()
        }
        if host.hasSuffix(".") { host.removeLast() }
        if let literal = parsedLiteral(host) { return addressIsPublic(literal) }
        let addresses = await resolver(host)
        guard let addresses, !addresses.isEmpty,
              addresses.count <= maximumResolvedAddresses else { return false }
        return addresses.allSatisfy(addressIsPublic)
    }

    public static func addressIsPublic(_ address: ResolvedAddress) -> Bool {
        switch address {
        case .ipv4(let a, let b, let c, _):
            return !(a == 0 || a == 10 || a == 127 || (a == 169 && b == 254)
                || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
                || (a == 100 && (64...127).contains(b))
                || (a == 192 && (b == 0 || b == 2))
                || (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100)))
                || (a == 203 && b == 0 && c == 113) || a >= 224)
        case .ipv6(let bytes):
            guard bytes.count == 16 else { return false }
            if bytes.allSatisfy({ $0 == 0 }) { return false }
            if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 { return false }
            if bytes[0] == 0xff || (bytes[0] & 0xfe) == 0xfc
                || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)
                || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0xc0) { return false }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff,
               bytes[11] == 0xff {
                return addressIsPublic(.ipv4(bytes[12], bytes[13], bytes[14], bytes[15]))
            }
            if bytes.prefix(12).allSatisfy({ $0 == 0 }) {
                return addressIsPublic(.ipv4(bytes[12], bytes[13], bytes[14], bytes[15]))
            }
            return true
        }
    }

    public static func systemResolve(_ host: String) async -> [ResolvedAddress]? {
        await boundedResolve(host: host, gate: systemResolutionGate)
    }

    static func boundedResolve(
        host: String,
        gate: ResolutionGate,
        blockingResolver: BlockingResolver? = nil,
        workerDispatcher: WorkerDispatcher? = nil,
        deadlineScheduler: DeadlineScheduler? = nil
    ) async -> [ResolvedAddress]? {
        let attempt = ResolutionAttempt()
        let resolver = blockingResolver ?? rawSystemResolve
        let dispatchWorker: WorkerDispatcher = workerDispatcher ?? { work in
            DispatchQueue.global(qos: .utility).async(execute: work)
        }
        let scheduleDeadline: DeadlineScheduler = deadlineScheduler ?? { finish in
            let work = DispatchWorkItem(block: finish)
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + resolverDeadlineSeconds, execute: work)
            return { work.cancel() }
        }
        let resolved = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                attempt.install(continuation)
                guard !Task.isCancelled, attempt.claim(gate) else {
                    attempt.finish(nil)
                    return
                }
                attempt.setDeadlineCancellation(scheduleDeadline {
                    attempt.finish(nil)
                })
                dispatchWorker {
                    let result = resolver(host)
                    gate.release()
                    attempt.finish(result)
                }
            }
        } onCancel: {
            attempt.finish(nil)
        }
        return Task.isCancelled ? nil : resolved
    }

    private static func rawSystemResolve(_ host: String) -> [ResolvedAddress]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &head) == 0, let head else { return nil }
        defer { freeaddrinfo(head) }
        var result: [ResolvedAddress] = []
        var inspected = 0
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let info = cursor?.pointee {
            inspected += 1
            guard inspected <= maximumResolvedAddresses else { return nil }
            if info.ai_family == AF_INET,
               let socket = info.ai_addr?.withMemoryRebound(
                to: sockaddr_in.self, capacity: 1, { $0.pointee }) {
                var raw = socket.sin_addr
                withUnsafeBytes(of: &raw) { bytes in
                    result.append(.ipv4(bytes[0], bytes[1], bytes[2], bytes[3]))
                }
            } else if info.ai_family == AF_INET6,
                      let socket = info.ai_addr?.withMemoryRebound(
                        to: sockaddr_in6.self, capacity: 1, { $0.pointee }) {
                var raw = socket.sin6_addr
                let bytes = withUnsafeBytes(of: &raw) { Array($0.prefix(16)) }
                result.append(.ipv6(bytes))
            }
            cursor = info.ai_next
        }
        return result
    }

    private static func parsedLiteral(_ host: String) -> ResolvedAddress? {
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return withUnsafeBytes(of: &ipv4) { .ipv4($0[0], $0[1], $0[2], $0[3]) }
        }
        var ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            return withUnsafeBytes(of: &ipv6) { .ipv6(Array($0.prefix(16))) }
        }
        return nil
    }
}

public enum GeneratedImageEchoPolicy {
    public static let maximumTranscriptScalars = 128_000
    public static let maximumTranscriptBytes = 512_000
    public static let maximumCalls = 128
    public static let maximumSuppressedSources = 24

    public static func hasSuccessfulAuthority(_ call: ToolCall) -> Bool {
        guard call.name == ToolGeneratedImageCodec.exactToolName,
              call.state == .done, let image = call.generatedImage,
              call.gatewayToolID?.isEmpty == false,
              call.provenance == .live || call.provenance == .stored,
              ToolGeneratedImage(source: image.source, sourceKind: image.sourceKind,
                                 aspect: image.aspect,
                                 echoSources: image.echoSources) == image else { return false }
        return true
    }

    public static func suppress(in text: String, calls: [ToolCall]) -> String {
        guard !text.isEmpty else { return text }
        // Retained transcript hydration itself caps a row at 128 calls. A
        // hand-built/corrupt snapshot outside that envelope cannot safely
        // decide which image echoes are authoritative, so expose no prose.
        guard calls.count <= maximumCalls else { return "" }
        var sources: [String] = []
        var seen = Set<String>()
        for call in calls where hasSuccessfulAuthority(call) {
            guard let echoes = call.generatedImage?.echoSources else { continue }
            for source in echoes {
                guard sources.count < maximumSuppressedSources else { return "" }
                guard let admitted = ToolGeneratedImageCodec.admittedEchoSource(source)
                else { return "" }
                if seen.insert(admitted).inserted { sources.append(admitted) }
            }
        }
        guard !sources.isEmpty else { return text }
        // Byte/scalar ceilings are checked before regex construction or a
        // whole-string transform. With successful image authority, oversized
        // prose fails closed rather than leaking an unscanned echo.
        guard text.utf8.count <= maximumTranscriptBytes,
              text.unicodeScalars.prefix(maximumTranscriptScalars + 1).count
                <= maximumTranscriptScalars else { return "" }

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
    }

    public static func suppress(in message: ChatMessage) -> String {
        guard message.author == .bot else { return message.text }
        return suppress(in: message.text, calls: message.toolCalls)
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
        try await load(url, resolver: { host in
            await RemoteGeneratedImagePolicy.systemResolve(host)
        })
    }

    static func load(_ url: URL,
                     resolver: RemoteGeneratedImagePolicy.Resolver) async throws -> Data {
        guard let host = url.host(), RemoteGeneratedImagePolicy.hostIsPublic(host),
              url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https"
        else { throw GatewayError(code: 403, message: "Private image hosts are not allowed.") }
        guard await RemoteGeneratedImagePolicy.resolvedHostIsPublic(host, resolver: resolver)
        else { throw GatewayError(code: 403, message: "Image host resolved to a private address.") }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = "GET"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        let (data, response) = try await GatewayBoundedRESTLoader.load(
            request, limit: ToolGeneratedImageCodec.maximumInlineDecodedBytes,
            configuration: configuration, rejectsRedirects: true)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              http.mimeType?.lowercased().hasPrefix("image/") == true else {
            throw GatewayError(code: 415, message: "Remote response was not an image.")
        }
        return data
    }
}
