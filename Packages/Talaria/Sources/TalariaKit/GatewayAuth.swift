import Foundation
import CryptoKit

// Authentication against a hermes gateway, at parity with Hermes Desktop:
//
// 1. Loopback / trusted setups — static session token:
//    REST header `X-Hermes-Session-Token`, WS query `?token=`.
// 2. Gated mode (any non-loopback bind) — the native PKCE broker flow
//    (RFC 8252): the gateway is the authorization server to the app and an
//    OAuth client to Nous Portal (or a self-hosted OIDC IdP / the basic
//    username-password provider). The app opens the system browser at
//    /auth/native/authorize with a loopback redirect, then redeems the
//    one-time code at /auth/native/token.
// 3. WebSocket access in gated mode — single-use 30 s tickets minted at
//    POST /api/auth/ws-ticket immediately before every (re)connect.
//
// See .research/auth-flows.md for the full upstream map (file:line refs).

// MARK: - Status probe

public struct GatewayStatus: Sendable {
    public var version: String?
    public var authRequired: Bool
    public var authProviders: [String]
    public var authFlows: [String]
    public var gatewayRunning: Bool
    public var activeAgents: Int
    public var activeSessions: Int
    public var overall: String
    public var raw: JSONValue?

    public init(_ v: JSONValue?) {
        version = v?["version"]?.stringValue
        authRequired = v?["auth_required"]?.boolValue ?? false
        authProviders = v?["auth_providers"]?.arrayValue?.compactMap(\.stringValue) ?? []
        authFlows = v?["auth_flows"]?.arrayValue?.compactMap(\.stringValue) ?? []
        gatewayRunning = v?["gateway_running"]?.boolValue ?? false
        activeAgents = v?["active_agents"]?.intValue ?? 0
        activeSessions = v?["active_sessions"]?.intValue ?? 0
        overall = v?["overall"]?.stringValue ?? "unknown"
        raw = v
    }

    public var supportsNativePKCE: Bool { authFlows.contains("native_pkce") }
}

public struct AuthProviderInfo: Sendable {
    public var name: String
    public var displayName: String
    public var supportsPassword: Bool
}

/// A gateway HTTP response that was neither successful nor an authentication
/// rejection. Keeping the numeric status structured lets higher layers apply
/// managed-cloud policy to exact 502/503/504 responses without parsing prose.
public struct GatewayHTTPError: Error, Sendable, Equatable {
    public let statusCode: Int
    /// Bounded, control-sanitized response detail. Request headers,
    /// credentials, and the unbounded response body are never retained.
    public let detail: String

    init(statusCode: Int, detail: String) {
        self.statusCode = statusCode
        self.detail = detail
    }
}

extension GatewayHTTPError: LocalizedError {
    public var errorDescription: String? {
        "Gateway returned HTTP \(statusCode): \(detail)"
    }
}

// MARK: - Token set

/// Result of the native token exchange; stored in the Keychain keyed by the
/// normalized gateway base URL (desktop stores the same shape via safeStorage).
public struct TokenSet: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    /// Unix seconds.
    public var expiresAt: TimeInterval
    public var provider: String
    public var userID: String?

    public init(accessToken: String, refreshToken: String, expiresAt: TimeInterval,
                provider: String, userID: String?) {
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.expiresAt = expiresAt; self.provider = provider; self.userID = userID
    }

    /// Desktop refreshes at expiresAt - 60 s.
    public var needsRefresh: Bool {
        Date().timeIntervalSince1970 >= expiresAt - 60
    }
}

/// Stored credential for one gateway connection.
public enum GatewayCredential: Codable, Sendable, Equatable {
    /// Loopback / pasted dashboard session token.
    case sessionToken(String)
    /// Native PKCE broker tokens (nous / self-hosted / basic providers).
    case oauth(TokenSet)
}

// MARK: - Base URL normalization

public enum GatewayURL {
    /// `hermes serve` default bind. A pasted tailnet/LAN IP without a port
    /// used to become `http://100.x.x.x` → TCP :80, so Mini's :9119 log never
    /// saw the phone while the journal still printed the host.
    public static let hermesDefaultPort = 9119

    /// Normalize a user-pasted base URL like desktop's connection-config.ts:
    /// prefix scheme-less input with http://, strip trailing slash, keep any
    /// reverse-proxy path prefix. Private / Tailscale / loopback IPs with no
    /// port get :9119.
    public static func normalize(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let host = url.host(), !host.isEmpty,
              url.scheme == "http" || url.scheme == "https" else { return nil }
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        if comps.port == nil, usesHermesDefaultPort(host: host) {
            comps.port = hermesDefaultPort
        }
        return comps.url
    }

    /// Scheme + host + port for banners and the activity journal.
    /// `URL.host()` alone hid a missing :9119 behind `100.87.108.5`.
    public static func originForDisplay(_ url: URL) -> String {
        let repaired = normalize(url.absoluteString) ?? url
        var comps = URLComponents()
        comps.scheme = repaired.scheme
        comps.host = repaired.host()
        comps.port = repaired.port
        return comps.string ?? repaired.absoluteString
    }

    /// RFC1918, CGNAT/Tailscale `100.64/10`, loopback, Tailscale ULA.
    public static func usesHermesDefaultPort(host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" { return true }
        if h.hasPrefix("fd7a:115c:a1e0") { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        let a = parts[0], b = parts[1]
        if a == 10 || a == 127 { return true }
        if a == 192 && b == 168 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 100 && (64...127).contains(b) { return true }
        return false
    }

    /// ws(s):// URL for /api/ws with the given query item.
    public static func webSocket(base: URL, query: URLQueryItem) -> URL? {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        comps?.scheme = base.scheme == "https" ? "wss" : "ws"
        comps?.path += "/api/ws"
        comps?.queryItems = [query]
        return comps?.url
    }
}

// MARK: - Auth API client

public struct GatewayAuthClient: Sendable {
    public var baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func status(timeout: TimeInterval = 15) async throws -> GatewayStatus {
        var req = URLRequest(url: baseURL.appending(path: "api/status"))
        req.timeoutInterval = timeout
        let (data, response) = try await session.data(for: req)
        try Self.admitHTTPResponse(response, data: data, endpoint: "status")
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw AuthError.protocolError("status response was not valid JSON")
        }
        guard value.objectValue != nil else {
            throw AuthError.protocolError("status response was not an object")
        }
        return GatewayStatus(value)
    }

    public func providers() async throws -> [AuthProviderInfo] {
        let (data, _) = try await session.data(from: baseURL.appending(path: "api/auth/providers"))
        let v = try JSONDecoder().decode(JSONValue.self, from: data)
        return v["providers"]?.arrayValue?.map {
            AuthProviderInfo(name: $0["name"]?.stringValue ?? "",
                             displayName: $0["display_name"]?.stringValue ?? "",
                             supportsPassword: $0["supports_password"]?.boolValue ?? false)
        } ?? []
    }

    /// Mint a single-use WS ticket (30 s TTL). Call immediately before every
    /// (re)connect; in gated mode legacy ?token= is rejected.
    /// Bounded at 8s: URLSession's default 60s request clock is a first-launch
    /// / redial stall that looks like a dead gateway.ready wait.
    public func mintWSTicket(credential: GatewayCredential) async throws -> String {
        var req = URLRequest(url: baseURL.appending(path: "api/auth/ws-ticket"))
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        apply(credential: credential, to: &req)
        let (data, response) = try await session.data(for: req)
        try Self.admitHTTPResponse(response, data: data, endpoint: "ws-ticket")
        let v: JSONValue
        do {
            v = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw AuthError.protocolError("ws-ticket response was not valid JSON")
        }
        guard v.objectValue != nil,
              let ticket = v["ticket"]?.stringValue,
              !ticket.isEmpty else {
            throw AuthError.protocolError("ws-ticket response missing ticket")
        }
        return ticket
    }

    /// Refresh native tokens. 401 session_expired ⇒ drop tokens and re-login;
    /// 503 (provider unreachable) ⇒ keep tokens and retry later.
    /// Same 8s HTTP bound as ws-ticket — this sits on the connect() path.
    public func refresh(_ tokens: TokenSet) async throws -> TokenSet {
        var req = URLRequest(url: baseURL.appending(path: "auth/native/refresh"))
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(JSONValue.object([
            "refresh_token": .string(tokens.refreshToken),
            "provider": .string(tokens.provider),
        ]))
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200:
            return try Self.parseTokenResponse(data)
        case 401:
            throw AuthError.sessionExpired
        case 503:
            throw AuthError.providerUnreachable
        default:
            throw AuthError.protocolError("refresh failed with status \(code)")
        }
    }

    public func me(credential: GatewayCredential) async throws -> JSONValue {
        var req = URLRequest(url: baseURL.appending(path: "api/auth/me"))
        apply(credential: credential, to: &req)
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Attach REST auth: bearer for oauth tokens, X-Hermes-Session-Token for
    /// loopback session tokens.
    public func apply(credential: GatewayCredential, to request: inout URLRequest) {
        switch credential {
        case .sessionToken(let token):
            request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
        case .oauth(let tokens):
            request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        }
    }

    /// WS URL for the given credential (ticket must be freshly minted for oauth).
    public func webSocketURL(credential: GatewayCredential, ticket: String?) throws -> URL {
        let query: URLQueryItem
        switch credential {
        case .sessionToken(let token):
            query = URLQueryItem(name: "token", value: token)
        case .oauth:
            guard let ticket else { throw AuthError.protocolError("gated mode requires a ws ticket") }
            query = URLQueryItem(name: "ticket", value: ticket)
        }
        guard let url = GatewayURL.webSocket(base: baseURL, query: query) else {
            throw AuthError.protocolError("could not build ws url")
        }
        return url
    }

    static func parseTokenResponse(_ data: Data) throws -> TokenSet {
        let v = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let at = v["access_token"]?.stringValue,
              let rt = v["refresh_token"]?.stringValue else {
            throw AuthError.protocolError("token response missing fields")
        }
        return TokenSet(accessToken: at, refreshToken: rt,
                        expiresAt: v["expires_at"]?.doubleValue ?? 0,
                        provider: v["provider"]?.stringValue ?? "nous",
                        userID: v["user_id"]?.stringValue)
    }

    private static func admitHTTPResponse(_ response: URLResponse, data: Data,
                                          endpoint: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.protocolError("\(endpoint) response was not HTTP")
        }
        guard http.statusCode == 200 else {
            let detail = safeHTTPDetail(data, statusCode: http.statusCode)
            if http.statusCode == 401 || http.statusCode == 403 {
                throw AuthError.unauthorized(detail)
            }
            throw GatewayHTTPError(statusCode: http.statusCode, detail: detail)
        }
    }

    /// Admit only a small response prefix, select the conventional gateway
    /// error field when it is JSON, strip terminal/bidi controls, redact common
    /// credential shapes, and cap the final presentation. The original body is
    /// never retained in an Error.
    static func safeHTTPDetail(_ data: Data, statusCode: Int) -> String {
        let maximumRawBytes = 8_192
        let maximumWorkScalars = 2_048
        let maximumVisibleScalars = 512
        // Never parse an arbitrary prefix as though it were a complete body.
        // Truncation can break JSON grammar and turn a secret-bearing field
        // into plaintext fallback. An oversized response therefore contributes
        // no body prose at all.
        if data.count > maximumRawBytes {
            return HTTPURLResponse.localizedString(forStatusCode: statusCode)
                + " … [oversized response detail omitted]"
        }
        let prefix = Data(data.prefix(maximumRawBytes))
        let candidate = responseDetailCandidate(prefix)
            ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)

        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(min(maximumVisibleScalars, candidate.unicodeScalars.count))
        var inspected = 0
        var clippedScalars = false
        for scalar in candidate.unicodeScalars {
            inspected += 1
            if inspected > maximumWorkScalars {
                clippedScalars = true
                break
            }
            let value = scalar.value
            if value == 0x09 || value == 0x0A || value == 0x0D
                || value == 0x85 || value == 0x2028 || value == 0x2029 {
                if scalars.last?.properties.isWhitespace != true { scalars.append(" ") }
            } else if value >= 0x20, !(0x7F...0x9F).contains(value),
                      !bidiControlValues.contains(value) {
                scalars.append(scalar)
            }
            if scalars.count == maximumVisibleScalars {
                clippedScalars = inspected < candidate.unicodeScalars.count
                break
            }
        }

        var safe = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        safe = redactCredentialShapes(safe)
        if safe.isEmpty {
            safe = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        }
        if clippedScalars {
            let marker = "… [response detail clipped]"
            let retained = max(0, maximumVisibleScalars - marker.unicodeScalars.count - 1)
            safe = String(safe.unicodeScalars.prefix(retained)) + " " + marker
        }
        return safe
    }

    private static func responseDetailCandidate(_ data: Data) -> String? {
        if let value = try? JSONDecoder().decode(JSONValue.self, from: data),
           let object = value.objectValue {
            for key in ["detail", "error", "message"] {
                if let text = object[key]?.stringValue { return text }
                if let nested = object[key]?.objectValue {
                    for nestedKey in ["message", "detail", "error"] {
                        if let text = nested[nestedKey]?.stringValue { return text }
                    }
                }
            }
            // A JSON error body with no conventional prose should not be
            // serialized wholesale: it may contain token/session fields.
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func redactCredentialShapes(_ source: String) -> String {
        var result = source
        let replacements: [(String, String)] = [
            (#"(?i)(bearer\s+)[^\s\"'<>]+"#, "$1[redacted]"),
            (#"(?i)((?:access|refresh|session|api)[_-]?token|authorization|x-hermes-session-token)\s*[:=]\s*[\"']?[^\s\"',<>}]+"#, "$1=[redacted]"),
            (#"\beyJ[A-Za-z0-9_-]{12,}(?:\.[A-Za-z0-9_-]+){1,2}\b"#, "[redacted-token]"),
        ]
        for (pattern, replacement) in replacements {
            result = result.replacingOccurrences(
                of: pattern, with: replacement,
                options: [.regularExpression], range: nil)
        }
        return result
    }

    private static let bidiControlValues: Set<UInt32> = [
        0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069,
    ]
}

public enum AuthError: Error, Sendable, Equatable {
    case unauthorized(String)
    /// Refresh token expired/invalid — drop tokens, start a new sign-in.
    case sessionExpired
    /// IdP unreachable — keep tokens, retry.
    case providerUnreachable
    case flowCancelled
    case stateMismatch
    case protocolError(String)
}

// MARK: - Native PKCE flow (RFC 8252)

/// The client half of the gateway's native broker flow. The app opens
/// `authorizeURL(...)` in the system browser (ASWebAuthenticationSession is
/// unsuitable — the redirect target is a loopback listener on the phone, so
/// use SFSafariViewController / openURL plus this listener).
public struct NativePKCEFlow: Sendable {
    public var codeVerifier: String
    public var codeChallenge: String
    public var state: String

    public init() {
        // Desktop: verifier = base64url(32 random bytes), state = base64url(24).
        codeVerifier = Self.base64url(Self.randomBytes(32))
        state = Self.base64url(Self.randomBytes(24))
        let digest = SHA256.hash(data: Data(codeVerifier.utf8))
        codeChallenge = Self.base64url(Data(digest))
    }

    /// The system-browser URL. `redirectPort` is the app's loopback listener;
    /// the host must be literally 127.0.0.1 (localhost is rejected upstream).
    public func authorizeURL(base: URL, redirectPort: UInt16, provider: String? = nil) -> URL? {
        var comps = URLComponents(url: base.appending(path: "auth/native/authorize"),
                                  resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1:\(redirectPort)/callback"),
            URLQueryItem(name: "state", value: state),
        ]
        if let provider { items.append(URLQueryItem(name: "provider", value: provider)) }
        comps?.queryItems = items
        return comps?.url
    }

    /// Redeem the one-time gateway code (120 s TTL, single-use). Verify the
    /// callback `state` equals ours BEFORE calling this.
    public func redeem(code: String, base: URL, session: URLSession = .shared) async throws -> TokenSet {
        var req = URLRequest(url: base.appending(path: "auth/native/token"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(JSONValue.object([
            "code": .string(code),
            "code_verifier": .string(codeVerifier),
        ]))
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.protocolError("Invalid or expired authorization code.")
        }
        return try GatewayAuthClient.parseTokenResponse(data)
    }

    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            for i in 0..<count {
                base.storeBytes(of: UInt8.random(in: 0...255), toByteOffset: i, as: UInt8.self)
            }
        }
        return data
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
