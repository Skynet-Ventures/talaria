import Foundation

/// A successful private diagnostics upload made by the current Hermes gateway.
/// The gateway has already collected and redacted the bundle; Talaria never
/// uploads files or logs of its own through this API.
public struct NousDiagnosticsShareReceipt: Sendable, Equatable {
    public let viewURL: URL?
    public let uploadID: String?
    public let expiresAt: String?

    public init(viewURL: URL?, uploadID: String?, expiresAt: String?) {
        self.viewURL = viewURL
        self.uploadID = uploadID
        self.expiresAt = expiresAt
    }
}

/// Structured application-level failures returned by `diagnostics.share_nous`.
/// JSON-RPC failures are deliberately not wrapped: in particular, an older
/// gateway's `GatewayError(code: -32601, ...)` remains distinguishable.
public enum NousDiagnosticsShareError: Error, Sendable, Equatable {
    case rejected(message: String)
    case malformedReceipt(reason: String)
}

extension NousDiagnosticsShareError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .rejected(let message): message
        case .malformedReceipt(let reason): "Malformed diagnostics response: \(reason)"
        }
    }
}

/// Exact current-Hermes wire contract and bounded admission policy.
public enum NousDiagnosticsSharingProtocol {
    public static let method = "diagnostics.share_nous"
    public static let timeout: TimeInterval = 120

    static let maximumContextScalars = 8_000
    static let maximumContextWorkScalars = 32_000
    static let maximumViewURLScalars = 2_048
    static let maximumUploadIDScalars = 256
    static let maximumExpiryScalars = 256
    static let maximumErrorScalars = 2_048
    static let maximumResponseWorkScalars = 8_192

    /// Build the complete mobile request. Current Hermes accepts more desktop
    /// parameters, but Talaria intentionally sends only optional error context.
    public static func requestParameters(errorContext: String?) -> JSONValue {
        var object: [String: JSONValue] = [:]
        if let errorContext,
           let admitted = sanitizePresentation(
               errorContext,
               maximumVisibleScalars: maximumContextScalars,
               maximumWorkScalars: maximumContextWorkScalars,
               clippedMarker: "\n… [diagnostic context clipped]"
           ), admitted.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) {
            object["error_context"] = .string(admitted)
        }
        return .object(object)
    }

    /// Strictly admit the structured gateway receipt. Unknown top-level fields
    /// are ignored for forward compatibility; known fields retain exact types.
    public static func decodeReceipt(_ value: JSONValue) throws -> NousDiagnosticsShareReceipt {
        guard let object = value.objectValue else {
            throw malformed("top level is not an object")
        }
        guard let ok = object["ok"]?.boolValue else {
            throw malformed("missing or non-boolean ok")
        }

        let rawError = try optionalString(object, key: "error")
        if !ok {
            guard let rawError,
                  let message = sanitizePresentation(
                    rawError,
                    maximumVisibleScalars: maximumErrorScalars,
                    maximumWorkScalars: maximumResponseWorkScalars,
                    clippedMarker: "\n… [diagnostics error clipped]"
                  ), message.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) else {
                throw malformed("failed receipt has no bounded error")
            }
            throw NousDiagnosticsShareError.rejected(message: message)
        }
        guard rawError == nil else {
            throw malformed("successful receipt includes an error")
        }

        let rawURL = try optionalString(object, key: "view_url")
        let viewURL: URL?
        if let rawURL {
            guard let admitted = admittedViewURL(rawURL) else {
                throw malformed("unsafe view_url")
            }
            viewURL = admitted
        } else {
            viewURL = nil
        }

        let uploadID = try admittedIdentity(object, key: "upload_id",
                                            maximumScalars: maximumUploadIDScalars)
        let expiresAt = try admittedIdentity(object, key: "expires_at",
                                             maximumScalars: maximumExpiryScalars)
        guard viewURL != nil || uploadID != nil else {
            throw malformed("successful receipt has no safe reference")
        }
        return NousDiagnosticsShareReceipt(
            viewURL: viewURL, uploadID: uploadID, expiresAt: expiresAt)
    }

    /// Current Hermes obtains `view_url` from its configurable NAS service,
    /// whose production default is portal.nousresearch.com. Talaria therefore
    /// admits the Nous-controlled DNS family, rather than arbitrary gateway-
    /// supplied HTTPS destinations. Signed paths and queries remain opaque.
    public static func admittedViewURL(_ source: String) -> URL? {
        let scalars = source.unicodeScalars
        var inspected = 0
        for scalar in scalars.prefix(maximumViewURLScalars + 1) {
            inspected += 1
            if inspected > maximumViewURLScalars || isUnsafeScalar(scalar)
                || scalar.properties.isWhitespace { return nil }
        }

        guard let components = URLComponents(string: source),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              let rawHost = components.host?.lowercased(),
              !rawHost.isEmpty,
              rawHost == "nousresearch.com" || rawHost.hasSuffix(".nousresearch.com"),
              rawHost.unicodeScalars.allSatisfy({
                  $0.isASCII && (CharacterSet.alphanumerics.contains($0)
                      || $0 == "." || $0 == "-")
              }),
              let url = components.url else { return nil }
        return url
    }

    private static func optionalString(_ object: [String: JSONValue], key: String) throws -> String? {
        guard let value = object[key] else { return nil }
        if case .null = value { return nil }
        guard let string = value.stringValue else { throw malformed("non-string \(key)") }
        return string
    }

    private static func admittedIdentity(_ object: [String: JSONValue], key: String,
                                         maximumScalars: Int) throws -> String? {
        guard let source = try optionalString(object, key: key) else { return nil }
        var count = 0
        for scalar in source.unicodeScalars.prefix(maximumScalars + 1) {
            count += 1
            if count > maximumScalars || isUnsafeScalar(scalar)
                || scalar.properties.isWhitespace { throw malformed("unsafe \(key)") }
        }
        guard !source.isEmpty else { throw malformed("empty \(key)") }
        return source
    }

    private static func malformed(_ reason: String) -> NousDiagnosticsShareError {
        .malformedReceipt(reason: reason)
    }

    private static func sanitizePresentation(_ source: String, maximumVisibleScalars: Int,
                                             maximumWorkScalars: Int,
                                             clippedMarker: String) -> String? {
        let admittedSource = Array(source.unicodeScalars.prefix(maximumWorkScalars + 1))
        let rawClipped = admittedSource.count > maximumWorkScalars
        let work = admittedSource.prefix(maximumWorkScalars)
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(min(maximumVisibleScalars, work.count))
        var visibleClipped = false

        for scalar in work where !isUnsafeScalar(scalar) {
            if output.count == maximumVisibleScalars {
                visibleClipped = true
                break
            }
            output.append(scalar)
        }
        guard !output.isEmpty else { return nil }

        if rawClipped || visibleClipped {
            let marker = Array(clippedMarker.unicodeScalars)
            let retained = max(0, maximumVisibleScalars - marker.count)
            if output.count > retained { output.removeLast(output.count - retained) }
            output.append(contentsOf: marker.prefix(maximumVisibleScalars - output.count))
        }
        return String(String.UnicodeScalarView(output))
    }

    private static func isUnsafeScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value == 0x09 || value == 0x0A { return false }
        if value < 0x20 || (0x7F...0x9F).contains(value) { return true }
        return bidiControlValues.contains(value)
    }

    private static let bidiControlValues: Set<UInt32> = [
        0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069,
    ]
}

public extension GatewayClient {
    /// Ask the connected Hermes gateway to create a private, server-redacted
    /// Nous diagnostics bundle. Cancellation is propagated to the RPC; callers
    /// own consent and stale-completion policy.
    func shareDiagnosticsToNous(errorContext: String? = nil) async throws
        -> NousDiagnosticsShareReceipt {
        let response = try await rpc(
            NousDiagnosticsSharingProtocol.method,
            NousDiagnosticsSharingProtocol.requestParameters(errorContext: errorContext),
            timeout: NousDiagnosticsSharingProtocol.timeout
        )
        return try NousDiagnosticsSharingProtocol.decodeReceipt(response)
    }
}
