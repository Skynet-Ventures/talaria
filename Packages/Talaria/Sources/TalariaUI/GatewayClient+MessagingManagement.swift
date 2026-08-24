import Foundation
import TalariaKit

// Typed mobile projection of current Hermes' messaging-platform lifecycle.
//
// Source authority (NousResearch/hermes-agent @ 77d6c78c):
//   hermes_cli/web_server.py:8677-9034, 9929-10124
//   hermes_cli/web_models.py:68-73
//   tui_gateway/server.py:3704-3760
//
// Credentials are write-only. `redacted_value` is intentionally not retained
// by any Talaria model: the only durable fact the phone needs is `is_set`.

enum MessagingPlatformIdentityAdmission {
    static let maximumPlatformBytes = 128
    static let maximumEnvironmentKeyBytes = 128
    // Hermes profiles.validate_profile_name: [a-z0-9][a-z0-9_-]{0,63},
    // with `default` as the built-in root alias.
    static let maximumProfileBytes = 64

    static func platform(_ raw: String?) -> String? {
        admit(raw, maximumBytes: maximumPlatformBytes) { byte in
            (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
                || byte == 45 || byte == 95
        }
    }

    static func environmentKey(_ raw: String?) -> String? {
        admit(raw, maximumBytes: maximumEnvironmentKeyBytes) { byte in
            (byte >= 65 && byte <= 90) || (byte >= 48 && byte <= 57) || byte == 95
        }
    }

    static func profile(_ raw: String?) -> String? {
        guard let admitted = admit(raw, maximumBytes: maximumProfileBytes, allowed: { byte in
            (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
                || byte == 45 || byte == 95
        }), let first = admitted.utf8.first,
              (first >= 97 && first <= 122) || (first >= 48 && first <= 57) else { return nil }
        return admitted
    }

    private static func admit(
        _ raw: String?, maximumBytes: Int, allowed: (UInt8) -> Bool
    ) -> String? {
        guard let raw, !raw.isEmpty,
              raw == raw.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let bytes = Array(raw.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumBytes, bytes.allSatisfy(allowed) else {
            return nil
        }
        return raw
    }
}

private enum MessagingPlatformDisplayAdmission {
    static func text(_ raw: String?, maximumScalars: Int = 2_048) -> String {
        guard let raw else { return "" }
        let forbidden = CharacterSet.controlCharacters
            .union(CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"))
        let clean = raw.unicodeScalars.filter { !forbidden.contains($0) }
        return String(String.UnicodeScalarView(clean.prefix(maximumScalars)))
    }

    static func webURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"), url.host != nil else { return nil }
        return url
    }
}

struct MessagingPlatformEnvironmentField: Identifiable, Equatable, Sendable {
    var id: String { key }
    let key: String
    let label: String
    let description: String
    let help: String
    let documentationURL: URL?
    let isSecret: Bool
    let isAdvanced: Bool
    let isRequired: Bool
    let isConfigured: Bool

    fileprivate init?(_ value: JSONValue) {
        guard let key = MessagingPlatformIdentityAdmission.environmentKey(
            value["key"]?.stringValue) else { return nil }
        self.key = key
        label = MessagingPlatformDisplayAdmission.text(value["prompt"]?.stringValue).nonEmpty ?? key
        description = MessagingPlatformDisplayAdmission.text(value["description"]?.stringValue)
        help = MessagingPlatformDisplayAdmission.text(value["help"]?.stringValue)
        documentationURL = MessagingPlatformDisplayAdmission.webURL(value["url"]?.stringValue)
        isSecret = value["is_password"]?.boolValue ?? true
        isAdvanced = value["advanced"]?.boolValue ?? false
        isRequired = value["required"]?.boolValue ?? false
        isConfigured = value["is_set"]?.boolValue ?? false
        // Deliberately ignore `redacted_value`. Even a masked credential is
        // unnecessary secret-derived material and must not enter app state.
    }
}

struct MessagingPlatform: Identifiable, Equatable, Sendable {
    static let maximumEnvironmentFields = 128
    let id: String
    let name: String
    let description: String
    let documentationURL: URL?
    let isEnabled: Bool
    let isConfigured: Bool
    let gatewayIsRunning: Bool
    let state: String
    let errorCode: String
    let errorMessage: String
    let environment: [MessagingPlatformEnvironmentField]

    fileprivate init?(_ value: JSONValue) {
        guard let id = MessagingPlatformIdentityAdmission.platform(value["id"]?.stringValue) else {
            return nil
        }
        let rawEnvironment = value["env_vars"]?.arrayValue ?? []
        // A 1 MiB response can still contain thousands of tiny rows. Never
        // allocate an unbounded editor or mint authority from a prefix whose
        // unseen tail could contain a duplicate key.
        guard rawEnvironment.count <= Self.maximumEnvironmentFields else { return nil }
        let decoded = rawEnvironment.compactMap(MessagingPlatformEnvironmentField.init)
        let grouped = Dictionary(grouping: decoded, by: \.key)
        // Duplicate keys make a clear/save target ambiguous. Fail the whole
        // row closed rather than silently selecting one declaration.
        guard grouped.values.allSatisfy({ $0.count == 1 }) else { return nil }
        self.id = id
        name = MessagingPlatformDisplayAdmission.text(value["name"]?.stringValue).nonEmpty ?? id
        description = MessagingPlatformDisplayAdmission.text(value["description"]?.stringValue)
        documentationURL = MessagingPlatformDisplayAdmission.webURL(value["docs_url"]?.stringValue)
        isEnabled = value["enabled"]?.boolValue ?? false
        isConfigured = value["configured"]?.boolValue ?? false
        gatewayIsRunning = value["gateway_running"]?.boolValue ?? false
        state = MessagingPlatformDisplayAdmission.text(value["state"]?.stringValue, maximumScalars: 128)
        errorCode = MessagingPlatformDisplayAdmission.text(value["error_code"]?.stringValue, maximumScalars: 128)
        errorMessage = MessagingPlatformDisplayAdmission.text(value["error_message"]?.stringValue)
        environment = decoded
    }

    var authority: MessagingPlatformMutationAuthority {
        MessagingPlatformMutationAuthority(platformID: id,
                                           environmentKeys: Set(environment.map(\.key)))
    }

    /// Hermes exposes relay in the platform catalog, but relay enrollment and
    /// routing are deployment lifecycle concerns rather than profile-local
    /// messaging-platform controls. Keep the row visible without minting
    /// profile-scoped mutation authority for it.
    var isDeploymentManaged: Bool {
        MessagingPlatformManagementScope.isDeploymentManaged(id)
    }
}

enum MessagingPlatformManagementScope {
    private static let deploymentManagedPlatformIDs: Set<String> = ["relay"]

    static func isDeploymentManaged(_ platformID: String) -> Bool {
        deploymentManagedPlatformIDs.contains(platformID)
    }
}

struct MessagingPlatformCatalog: Equatable, Sendable {
    static let maximumPlatforms = 128

    let platforms: [MessagingPlatform]
    let gatewayStartCommand: String
    /// True when rows were rejected as unsafe/ambiguous. Safe admitted rows
    /// remain usable, but Settings surfaces the omission rather than implying
    /// the server snapshot was complete.
    let omittedRowCount: Int
    /// An over-cap platform array is rejected wholesale: truncating it could
    /// miss a duplicate id beyond the retained prefix and mint false mutation
    /// authority for that id.
    let rejectedOversizedPlatformList: Bool

    var hasOmissions: Bool { omittedRowCount > 0 || rejectedOversizedPlatformList }

    init(_ value: JSONValue) {
        let raw = value["platforms"]?.arrayValue ?? []
        guard raw.count <= Self.maximumPlatforms else {
            platforms = []
            omittedRowCount = raw.count
            rejectedOversizedPlatformList = true
            gatewayStartCommand = MessagingPlatformDisplayAdmission.text(
                value["gateway_start_command"]?.stringValue, maximumScalars: 512)
            return
        }
        // Count every syntactically safe raw identity before decoding the
        // remainder of the row. Otherwise one valid row plus an oversized or
        // malformed row with the same id could incorrectly leave the valid
        // row authorized for mutation.
        let rawIdentityCounts = Dictionary(grouping: raw.compactMap {
            MessagingPlatformIdentityAdmission.platform($0["id"]?.stringValue)
        }, by: { $0 })
        let decoded = raw.compactMap(MessagingPlatform.init)
        platforms = decoded.filter { rawIdentityCounts[$0.id]?.count == 1 }
        omittedRowCount = raw.count - platforms.count
        rejectedOversizedPlatformList = false
        // This is display-only operator guidance, never executed by Talaria.
        gatewayStartCommand = MessagingPlatformDisplayAdmission.text(
            value["gateway_start_command"]?.stringValue, maximumScalars: 512)
    }
}

struct MessagingPlatformMutationAuthority: Equatable, Sendable {
    let platformID: String
    let environmentKeys: Set<String>
}

enum MessagingPlatformMutationValidation {
    static func admits(_ mutation: MessagingPlatformMutation,
                       authority: MessagingPlatformMutationAuthority) -> Bool {
        let submitted = mutation.submittedKeys
        let cleared = Set(mutation.clearEnvironment)
        return MessagingPlatformIdentityAdmission.platform(authority.platformID)
                == authority.platformID
            && !MessagingPlatformManagementScope.isDeploymentManaged(authority.platformID)
            && submitted.isSubset(of: authority.environmentKeys)
            && cleared.isSubset(of: authority.environmentKeys)
            && submitted.isDisjoint(with: cleared)
            && submitted.allSatisfy {
                MessagingPlatformIdentityAdmission.environmentKey($0) == $0
            }
            && cleared.allSatisfy {
                MessagingPlatformIdentityAdmission.environmentKey($0) == $0
            }
    }
}

struct MessagingPlatformMutation: Sendable, CustomDebugStringConvertible {
    let enabled: Bool?
    private let environment: [String: String]
    let clearEnvironment: [String]

    init(enabled: Bool? = nil, environment: [String: String] = [:],
         clearEnvironment: [String] = []) {
        self.enabled = enabled
        self.environment = environment
        self.clearEnvironment = clearEnvironment
    }

    var submittedKeys: Set<String> { Set(environment.keys) }
    var submittedSecrets: [String] { Array(environment.values) }

    func wireBody(profile: String) -> JSONValue {
        var object: [String: JSONValue] = [
            "profile": .string(profile),
            "env": .object(environment.mapValues(JSONValue.string)),
            "clear_env": .array(clearEnvironment.map(JSONValue.string)),
        ]
        if let enabled { object["enabled"] = .bool(enabled) }
        return .object(object)
    }

    var debugDescription: String {
        "MessagingPlatformMutation(enabled: \(String(describing: enabled)), "
            + "environmentKeys: \(submittedKeys.sorted()), clearEnvironment: \(clearEnvironment.sorted()))"
    }
}

struct MessagingPlatformTestResult: Equatable, Sendable {
    let ok: Bool
    let state: String
    let message: String

    init(_ value: JSONValue) {
        ok = value["ok"]?.boolValue ?? false
        state = MessagingPlatformDisplayAdmission.text(value["state"]?.stringValue,
                                                       maximumScalars: 128)
        message = MessagingPlatformDisplayAdmission.text(value["message"]?.stringValue)
    }
}

enum MessagingPlatformSecretRedaction {
    static func serverMessage(_ raw: String, submittedSecrets: [String]) -> String {
        var result = MessagingPlatformDisplayAdmission.text(raw)
        for secret in submittedSecrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "[credential redacted]")
        }
        return result
    }
}

extension GatewayClient {
    private static func messagingProfile(_ profile: String) throws -> String {
        guard let admitted = MessagingPlatformIdentityAdmission.profile(profile) else {
            throw GatewayError(code: 400, message: "Choose an exact Hermes profile.")
        }
        return admitted
    }

    func messagingPlatforms(profile: String) async throws -> MessagingPlatformCatalog {
        let profile = try Self.messagingProfile(profile)
        let payload = try await restJSONBounded(
            path: "api/messaging/platforms",
            query: [URLQueryItem(name: "profile", value: profile)], timeout: 30,
            maximumResponseBytes: 1_048_576)
        return MessagingPlatformCatalog(payload)
    }

    func updateMessagingPlatform(
        authority: MessagingPlatformMutationAuthority,
        mutation: MessagingPlatformMutation,
        profile: String
    ) async throws {
        let profile = try Self.messagingProfile(profile)
        guard let platformID = MessagingPlatformIdentityAdmission.platform(authority.platformID),
              platformID == authority.platformID else {
            throw GatewayError(code: 400, message: "The platform identity is unsafe.")
        }
        guard !MessagingPlatformManagementScope.isDeploymentManaged(platformID) else {
            throw GatewayError(
                code: 409,
                message: "Relay enrollment and routing are managed by the gateway deployment."
            )
        }
        guard MessagingPlatformMutationValidation.admits(mutation, authority: authority) else {
            throw GatewayError(code: 400,
                               message: "Only credentials declared by this platform can be changed.")
        }
        _ = try await restJSONBounded(
            path: "api/messaging/platforms/\(platformID)", method: "PUT",
            query: [URLQueryItem(name: "profile", value: profile)],
            body: mutation.wireBody(profile: profile), timeout: 30,
            maximumResponseBytes: 65_536)
    }

    func testMessagingPlatform(
        authority: MessagingPlatformMutationAuthority, profile: String
    ) async throws -> MessagingPlatformTestResult {
        let profile = try Self.messagingProfile(profile)
        guard let platformID = MessagingPlatformIdentityAdmission.platform(authority.platformID),
              platformID == authority.platformID else {
            throw GatewayError(code: 400, message: "The platform identity is unsafe.")
        }
        guard !MessagingPlatformManagementScope.isDeploymentManaged(platformID) else {
            throw GatewayError(
                code: 409,
                message: "Relay connection checks are managed by the gateway deployment."
            )
        }
        return MessagingPlatformTestResult(try await restJSONBounded(
            path: "api/messaging/platforms/\(platformID)/test", method: "POST",
            query: [URLQueryItem(name: "profile", value: profile)], timeout: 30,
            maximumResponseBytes: 65_536))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
