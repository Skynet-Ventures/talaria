import Foundation
import TalariaKit

// Typed projection of Hermes' dedicated memory-provider administration API.
//
// Pinned Hermes authority (b5455fdd):
//   GET  /api/memory                                           web_server.py:13926
//   GET  /api/memory/providers/{name}/config?surface=declared web_server.py:6706
//   PUT  /api/memory/providers/{name}/config?surface=declared web_server.py:6751
//   POST /api/memory/providers/{name}/setup                    web_server.py:6729
//   PUT  /api/memory/provider                                  web_server.py:13953
//   POST /api/memory/providers/{name}/oauth/start              memory_oauth.py:57
//   GET  /api/memory/providers/{name}/oauth/status             memory_oauth.py:73
//
// Discovery, dependency setup, and the default selection are gateway-owned.
// Declared config is profile-aware: Hermes evaluates it inside `_profile_scope`
// so a profile's provider credentials/config never leak into another profile.
//
// Checkpoint-v2 authority (Hermes 1bbb6e5):
//   agent/memory_provider.py                  — API v2 is an opt-in provider attribute
//   agent/conversation_compression.py         — false/missing proof blocks before rewrite
//   hermes_cli/web_server.py:/api/config      — existing raw config read/write route
//   hermes_cli/web_server.py:/api/memory      — existing authoritative provider inventory
// The audited source adds no checkpoint-specific RPC or capability endpoint.
// Consequently this client accepts only an explicit capability field carried
// by the existing inventory response and otherwise leaves the control guarded
// off; it never guesses a provider's version or calls an invented method.

struct MemoryProviderSetup: Equatable, Sendable {
    var pipDependencies: [String]
    var externalDependencies: [String]
    var requiredEnvironment: [String]
    var dependenciesInstalled: Bool

    init(_ value: JSONValue?) {
        pipDependencies = value?["pip_dependencies"]?.arrayValue?.compactMap(\.stringValue) ?? []
        externalDependencies = value?["external_dependencies"]?.arrayValue?.compactMap {
            $0["name"]?.stringValue
        } ?? []
        requiredEnvironment = value?["required_env"]?.arrayValue?.compactMap(\.stringValue) ?? []
        dependenciesInstalled = value?["dependencies_installed"]?.boolValue ?? true
    }

    var hasWork: Bool {
        !dependenciesInstalled && (!pipDependencies.isEmpty || !externalDependencies.isEmpty)
    }
}

struct MemoryProviderInventoryRow: Identifiable, Equatable, Sendable {
    var id: String { name }
    var name: String
    var description: String
    var available: Bool
    var configured: Bool
    var status: String
    var setup: MemoryProviderSetup
    /// The provider's explicit `pre_compress_checkpoint_api_version` claim,
    /// when the authoritative inventory carries one. A missing or malformed
    /// value is deliberately not treated as the historical v1 default: that
    /// default is a provider implementation detail, not proof that this
    /// gateway can safely arm the fail-closed v2 gate.
    var checkpointAPIVersionRaw: JSONValue?
    var checkpointAPIVersion: Int?

    init?(_ value: JSONValue) {
        guard let name = value["name"]?.stringValue, !name.isEmpty else { return nil }
        self.name = name
        description = value["description"]?.stringValue ?? ""
        available = value["available"]?.boolValue ?? false
        configured = value["configured"]?.boolValue ?? false
        status = value["status"]?.stringValue ?? "unavailable"
        setup = MemoryProviderSetup(value["setup"])
        checkpointAPIVersionRaw = value["pre_compress_checkpoint_api_version"]
        checkpointAPIVersion = Self.exactInteger(checkpointAPIVersionRaw)
    }

    var isReady: Bool { available && configured && status == "ready" }

    /// Hermes' checkpoint manager accepts providers advertising v2 or a later
    /// compatible version (`provider_version >= required_version`).
    var advertisesCheckpointAPIV2: Bool { (checkpointAPIVersion ?? 0) >= 2 }

    private static func exactInteger(_ raw: JSONValue?) -> Int? {
        guard let number = raw?.doubleValue, number.isFinite,
              number.rounded(.towardZero) == number else { return nil }
        return Int(exactly: number)
    }
}

struct MemoryProviderInventory: Equatable, Sendable {
    var activeGatewayDefault: String
    var providers: [MemoryProviderInventoryRow]
    var memoryBytes: Int
    var userBytes: Int

    init(_ value: JSONValue) {
        activeGatewayDefault = value["active"]?.stringValue ?? ""
        providers = value["providers"]?.arrayValue?.compactMap(MemoryProviderInventoryRow.init) ?? []
        memoryBytes = value["builtin_files"]?["memory"]?.intValue ?? 0
        userBytes = value["builtin_files"]?["user"]?.intValue ?? 0
    }
}

/// Lossless projection of the raw `compression.checkpoint_required` config
/// leaf. Hermes' agent initializer is permissive about config truthiness, but
/// a mobile management control must never silently reinterpret or overwrite a
/// non-boolean value. It can offer a switch only for an explicit boolean.
struct CompressionCheckpointRequirement: Equatable, Sendable {
    enum RawState: Equatable, Sendable {
        case absent
        case boolean(Bool)
        case unrecognized(JSONValue)
    }

    var rawValue: JSONValue?

    init(config: JSONValue) {
        rawValue = config["compression"]?["checkpoint_required"]
    }

    init(rawValue: JSONValue?) {
        self.rawValue = rawValue
    }

    var rawState: RawState {
        guard let rawValue else { return .absent }
        if let bool = rawValue.boolValue { return .boolean(bool) }
        return .unrecognized(rawValue)
    }

    var enabled: Bool? { rawValue?.boolValue }
}

/// The single profile-scoped config read used by the memory settings page.
/// Keeping both values in this envelope prevents a provider selection and the
/// checkpoint switch from being read from different config snapshots.
struct MemoryProviderScopeConfiguration: Equatable, Sendable {
    var activeProvider: String
    var checkpointRequirement: CompressionCheckpointRequirement

    init(_ config: JSONValue) {
        activeProvider = config["memory"]?["provider"]?.stringValue ?? ""
        checkpointRequirement = CompressionCheckpointRequirement(config: config)
    }
}

/// The client-visible state of Hermes' fail-closed pre-compress gate. A
/// `blocked` value is a configuration/remediation state, not a transport
/// failure: Hermes preserves the transcript and the user can fix the provider
/// then retry compaction without reconnecting the gateway.
enum CompressionCheckpointGateState: Equatable, Sendable {
    enum Blocker: Error, Equatable, Sendable {
        case checkpointValueNotReported
        case checkpointValueUnrecognized(JSONValue)
        case noActiveExternalProvider
        case activeProviderNotReported(String)
        case activeProviderNotReady(String)
        case checkpointAPINotAdvertised(String)
        case checkpointAPIVersionTooOld(provider: String, version: Int)
    }

    case controllable(enabled: Bool, provider: String, apiVersion: Int)
    case unavailable(Blocker)
    case blocked(Blocker)

    static func resolve(requirement: CompressionCheckpointRequirement,
                        activeProvider: String,
                        inventory: MemoryProviderInventory) -> Self {
        let prerequisite = providerPrerequisite(activeProvider: activeProvider, inventory: inventory)
        switch requirement.rawState {
        case .absent:
            return .unavailable(.checkpointValueNotReported)
        case .unrecognized(let raw):
            return .unavailable(.checkpointValueUnrecognized(raw))
        case .boolean(let enabled):
            switch prerequisite {
            case .success(let row):
                // `advertisesCheckpointAPIV2` above already proves this is a
                // literal API v2-or-newer declaration, never an inferred v1.
                return .controllable(enabled: enabled, provider: row.name,
                                     apiVersion: row.checkpointAPIVersion ?? 2)
            case .failure(let blocker):
                return enabled ? .blocked(blocker) : .unavailable(blocker)
            }
        }
    }

    var toggleIsVisible: Bool {
        if case .controllable = self { return true }
        return false
    }

    var isRecoverableConfigurationState: Bool {
        if case .blocked = self { return true }
        return false
    }

    var enabled: Bool? {
        if case .controllable(let enabled, _, _) = self { return enabled }
        return nil
    }

    var blocker: Blocker? {
        switch self {
        case .controllable: nil
        case .unavailable(let blocker), .blocked(let blocker): blocker
        }
    }

    private static func providerPrerequisite(activeProvider: String,
                                             inventory: MemoryProviderInventory)
        -> Result<MemoryProviderInventoryRow, Blocker> {
        guard !activeProvider.isEmpty else { return .failure(.noActiveExternalProvider) }
        guard let row = inventory.providers.first(where: { $0.name == activeProvider }) else {
            return .failure(.activeProviderNotReported(activeProvider))
        }
        guard row.isReady else { return .failure(.activeProviderNotReady(activeProvider)) }
        guard let version = row.checkpointAPIVersion else {
            return .failure(.checkpointAPINotAdvertised(activeProvider))
        }
        guard version >= 2 else {
            return .failure(.checkpointAPIVersionTooOld(provider: activeProvider, version: version))
        }
        return .success(row)
    }
}

/// Hermes uses this stable fail-closed outcome marker when it preserves the
/// uncompressed transcript because a durable checkpoint cannot be confirmed.
/// It is an application-level configuration outcome, never evidence that the
/// WebSocket or gateway session disconnected.
enum CompressionCheckpointFailurePolicy {
    static let blockedPrerequisiteMarker = "BLOCKED_MISSING_PREREQUISITE"

    static func isBlockedPrerequisite(_ value: String?) -> Bool {
        value?.uppercased().contains(blockedPrerequisiteMarker) ?? false
    }

    static func isBlockedPrerequisite(_ error: Error) -> Bool {
        guard let gateway = error as? GatewayError else { return false }
        return isBlockedPrerequisite(gateway.message)
    }
}

enum MemoryProviderCatalog {
    static func merge(profileSchema: [String], gatewayInventory: [MemoryProviderInventoryRow],
                      active: String) -> [String] {
        var seen = Set<String>()
        return (profileSchema + gatewayInventory.map(\.name) + [active]).filter { name in
            !name.isEmpty && seen.insert(name).inserted
        }
    }
}

enum MemoryProviderSaveSemantics {
    /// Hermes' declared-config PUT does not select a provider.
    static func activeSelection(afterDeclaredSave current: String) -> String { current }
}

enum MemoryProviderDocumentationPolicy {
    static func externalURL(_ raw: String) -> URL? {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: clean),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

enum MemoryProviderCopySemantics {
    static func saveAction(control: Bool) -> String {
        control ? "SAVE PROVIDER CONFIG" : "Save provider configuration"
    }

    static func savedNotice(control: Bool, provider: String) -> String {
        control ? "CONFIG SAVED: \(provider.uppercased())"
            : "Saved \(provider) configuration. Activate it separately to use it."
    }
}

struct MemoryProviderFieldOption: Identifiable, Equatable, Sendable {
    var id: String { value }
    var value: String
    var label: String
    var description: String

    init?(_ value: JSONValue) {
        guard let raw = value["value"]?.stringValue else { return nil }
        self.value = raw
        label = value["label"]?.stringValue ?? raw
        description = value["description"]?.stringValue ?? ""
    }
}

struct MemoryProviderField: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case text, secret, select, boolean, number

        init(upstream: String) {
            switch upstream {
            case "secret": self = .secret
            case "select": self = .select
            case "bool", "boolean": self = .boolean
            case "number", "integer": self = .number
            default: self = .text
            }
        }
    }

    var id: String { key }
    var key: String
    var label: String
    var kind: Kind
    var description: String
    var placeholder: String
    var isSet: Bool
    var value: String
    var options: [MemoryProviderFieldOption]

    init?(_ raw: JSONValue) {
        guard let key = raw["key"]?.stringValue, !key.isEmpty else { return nil }
        self.key = key
        label = raw["label"]?.stringValue ?? key
        kind = Kind(upstream: raw["kind"]?.stringValue ?? "text")
        description = raw["description"]?.stringValue ?? ""
        placeholder = raw["placeholder"]?.stringValue ?? ""
        isSet = raw["is_set"]?.boolValue ?? false
        value = raw["value"]?.stringValue
            ?? raw["value"]?.boolValue.map { $0 ? "true" : "false" }
            ?? raw["value"]?.doubleValue.map { String($0) }
            ?? ""
        options = raw["options"]?.arrayValue?.compactMap(MemoryProviderFieldOption.init) ?? []
    }
}

struct MemoryProviderDeclaredConfig: Equatable, Sendable {
    var name: String
    var label: String
    var documentationURL: String
    var fields: [MemoryProviderField]

    init(_ value: JSONValue) {
        name = value["name"]?.stringValue ?? ""
        label = value["label"]?.stringValue ?? name
        documentationURL = value["docs_url"]?.stringValue ?? ""
        fields = value["fields"]?.arrayValue?.compactMap(MemoryProviderField.init) ?? []
    }

    /// Hermes secrets are write-only. An empty secret means "keep the value
    /// already stored", so it must be omitted rather than submitted as a
    /// blank. Non-secret blanks remain meaningful (they clear an override).
    func submission(from drafts: [String: String]) -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for field in fields {
            let draft = drafts[field.key] ?? field.value
            if field.kind == .secret && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            values[field.key] = .string(draft)
        }
        return values
    }
}

enum MemoryProviderOAuthState: String, Equatable, Sendable {
    case idle, pending, connected, error
}

struct MemoryProviderOAuthStatus: Equatable, Sendable {
    var state: MemoryProviderOAuthState
    var detail: String
    var connected: Bool
    /// `oauth`, `apikey`, or nil when no credential is stored.
    var authentication: String?

    init(_ value: JSONValue) {
        state = MemoryProviderOAuthState(rawValue: value["state"]?.stringValue ?? "") ?? .error
        detail = value["detail"]?.stringValue ?? ""
        connected = value["connected"]?.boolValue ?? false
        authentication = value["auth"]?.stringValue
    }
}

enum MemoryProviderOAuthPollDecision: Equatable {
    case keepWaiting
    case connected
    case failed(String)

    static func decide(status: MemoryProviderOAuthStatus, timedOut: Bool) -> Self {
        if status.state == .error {
            return .failed(status.detail.isEmpty ? "Connection failed." : status.detail)
        }
        // The flow state is process-global upstream, while credential detection
        // is evaluated inside the requested profile. Require BOTH on a terminal
        // connection so another profile's completed flow cannot be mistaken for
        // a credential in this one. During reconnect, pending+connected merely
        // describes the old credential and must keep waiting.
        if status.state == .connected {
            return status.connected
                ? .connected
                : .failed("Authorization did not connect the selected profile.")
        }
        if status.state == .idle && status.connected { return .connected }
        if timedOut {
            return .failed("Phone polling timed out; the gateway browser flow may still finish.")
        }
        return .keepWaiting
    }
}

extension GatewayClient {
    func memoryProviderInventory() async throws -> MemoryProviderInventory {
        MemoryProviderInventory(try await restJSON(path: "api/memory", timeout: 30))
    }

    /// Existing profile-scoped config route, projected without coercing the
    /// raw checkpoint flag. Hermes 1bbb6e5's checkpoint-v2 change adds no
    /// dedicated client RPC, so this is intentionally the ordinary
    /// `/api/config` read rather than a guessed capability method.
    func memoryProviderScopeConfiguration(profile: String?) async throws
        -> MemoryProviderScopeConfiguration {
        MemoryProviderScopeConfiguration(
            try await restJSON(path: "api/config", query: Self.memoryProfileQuery(profile),
                               timeout: 30))
    }

    func memoryProviderSelection(profile: String?) async throws -> String {
        let configuration = try await memoryProviderScopeConfiguration(profile: profile)
        return configuration.activeProvider
    }

    /// Persist only the supported boolean leaf through Hermes' existing
    /// deep-merge `PUT /api/config` route. Callers are responsible for the
    /// API-v2 provider proof; this method deliberately has no fallback RPC.
    func setCompressionCheckpointRequired(_ enabled: Bool, profile: String?) async throws {
        try await setGatewayConfigValue(path: ["compression", "checkpoint_required"],
                                        value: .bool(enabled), profile: profile)
    }

    /// Profile-scoped discovery options from Hermes' dynamic config schema.
    /// Unlike `/api/memory`, this request runs inside the selected profile and
    /// therefore includes providers installed in that profile's plugin home,
    /// plus its configured current value even when discovery is temporarily
    /// unavailable.
    func memoryProviderCatalog(profile: String?) async throws -> [String] {
        let schema = try await restJSON(path: "api/config/schema",
                                        query: Self.memoryProfileQuery(profile), timeout: 30)
        return schema["fields"]?["memory.provider"]?["options"]?.arrayValue?
            .compactMap(\.stringValue) ?? []
    }

    func memoryProviderConfig(_ provider: String, profile: String?) async throws
        -> MemoryProviderDeclaredConfig {
        let name = try Self.memoryProviderPathName(provider)
        var query = [URLQueryItem(name: "surface", value: "declared")]
        query.append(contentsOf: Self.memoryProfileQuery(profile))
        return MemoryProviderDeclaredConfig(
            try await restJSON(path: "api/memory/providers/\(name)/config",
                               query: query, timeout: 30))
    }

    func saveMemoryProviderConfig(_ config: MemoryProviderDeclaredConfig,
                                  drafts: [String: String], profile: String?) async throws {
        let name = try Self.memoryProviderPathName(config.name)
        var query = [URLQueryItem(name: "surface", value: "declared")]
        query.append(contentsOf: Self.memoryProfileQuery(profile))
        let body: JSONValue = .object(["values": .object(config.submission(from: drafts))])
        try await restJSON(path: "api/memory/providers/\(name)/config", method: "PUT",
                           query: query, body: body, timeout: 60)
    }

    /// Runs provider-declared dependency setup on the gateway host. This is
    /// intentionally NOT profile-scoped: dependencies belong to the gateway's
    /// Python/runtime installation, not to any bot profile.
    func setupMemoryProvider(_ provider: String) async throws {
        let name = try Self.memoryProviderPathName(provider)
        try await restJSON(path: "api/memory/providers/\(name)/setup", method: "POST",
                           body: ["values": .object([:])], timeout: 600)
    }

    /// Capability probe and current credential state. A 404 is intentional:
    /// providers without an `oauth_flow` module do not support this surface.
    func memoryProviderOAuthStatus(_ provider: String, profile: String?) async throws
        -> MemoryProviderOAuthStatus {
        let name = try Self.memoryProviderPathName(provider)
        return MemoryProviderOAuthStatus(
            try await restJSON(path: "api/memory/providers/\(name)/oauth/status",
                               query: Self.memoryProfileQuery(profile), timeout: 30))
    }

    /// Starts the provider's background loopback flow. The gateway opens the
    /// consent browser on its host; Talaria polls the profile-scoped status.
    func startMemoryProviderOAuth(_ provider: String, profile: String?) async throws
        -> MemoryProviderOAuthStatus {
        let name = try Self.memoryProviderPathName(provider)
        return MemoryProviderOAuthStatus(
            try await restJSON(path: "api/memory/providers/\(name)/oauth/start",
                               method: "POST", query: Self.memoryProfileQuery(profile),
                               body: .object([:]), timeout: 30))
    }

    /// Select a provider for a captured scope. Hermes' dedicated selection
    /// route owns the gateway default. A profile override uses the ordinary
    /// profile-scoped config route because `/api/memory/provider` deliberately
    /// has no profile parameter.
    func selectMemoryProvider(_ provider: String, profile: String?) async throws {
        if let profile, !profile.isEmpty {
            try await setGatewayConfigValue(path: ["memory", "provider"],
                                            value: .string(provider), profile: profile)
        } else {
            try await restJSON(path: "api/memory/provider", method: "PUT",
                               body: ["provider": .string(provider)], timeout: 30)
        }
    }

    private static func memoryProfileQuery(_ profile: String?) -> [URLQueryItem] {
        guard let profile, !profile.isEmpty else { return [] }
        return [URLQueryItem(name: "profile", value: profile)]
    }

    private static func memoryProviderPathName(_ name: String) throws -> String {
        let allowed = name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"#,
                                 options: .regularExpression) != nil
        guard allowed else { throw GatewayError(code: -9, message: "invalid memory provider") }
        return name
    }
}
