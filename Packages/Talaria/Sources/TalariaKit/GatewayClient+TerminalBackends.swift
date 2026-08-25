import Foundation

// Server-driven terminal environment management.
//
// Hermes owns the terminal-provider registry: built-ins, installed plug-ins,
// availability probes, and admission all happen on the gateway host. Talaria
// deliberately receives that catalog as opaque, authenticated data instead of
// maintaining a mobile enum or trying to load host plug-ins itself.

public enum TerminalBackendStatus: String, Sendable, Equatable {
    case ready
    case needsSetup = "needs_setup"
    case unavailable

    /// A backend that needs credentials or host setup is still a valid desired
    /// selection. An unavailable backend is visible for diagnosis but cannot
    /// be selected from the phone.
    public var isSelectable: Bool {
        switch self {
        case .ready, .needsSetup: true
        case .unavailable: false
        }
    }
}

/// One gateway-admitted row from `GET /api/tools/terminal/backends`.
public struct TerminalBackend: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public var name: String
    public var label: String
    public var description: String
    public var active: Bool
    public var status: TerminalBackendStatus
    public var detail: String

    public init(name: String, label: String, description: String,
                active: Bool, status: TerminalBackendStatus, detail: String = "") {
        self.name = name
        self.label = label
        self.description = description
        self.active = active
        self.status = status
        self.detail = detail
    }

    init?(_ value: JSONValue) {
        guard let name = Self.canonicalName(value["name"]?.stringValue),
              let active = value["active"]?.boolValue,
              let rawStatus = value["status"]?.stringValue,
              let status = TerminalBackendStatus(rawValue: rawStatus) else {
            return nil
        }
        let label = Self.displayText(value["label"]?.stringValue)
        self.init(
            name: name,
            label: label.isEmpty ? name : label,
            description: Self.displayText(value["description"]?.stringValue),
            active: active,
            status: status,
            detail: Self.displayText(value["detail"]?.stringValue)
        )
    }

    /// Preserve future plug-in names without accepting whitespace/control
    /// values that could not be shown or compared safely in a picker.
    static func canonicalName(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty,
              normalized == value,
              !normalized.unicodeScalars.contains(where: {
                  $0.properties.isWhitespace || CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return normalized
    }

    private static func displayText(_ value: String?) -> String {
        guard let value else { return "" }
        return value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0.value == 0x0A
        }.map(String.init).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A single coherent terminal-backend read. The catalog is invalid if its
/// active marker is ambiguous or inconsistent; callers must fail closed rather
/// than invent a static fallback such as `local`.
public struct TerminalBackendCatalog: Sendable, Equatable {
    public var active: String
    public var backends: [TerminalBackend]

    public init(active: String, backends: [TerminalBackend]) {
        self.active = active
        self.backends = backends
    }

    public init?(_ value: JSONValue) {
        guard let active = TerminalBackend.canonicalName(value["active"]?.stringValue),
              let values = value["backends"]?.arrayValue,
              !values.isEmpty else {
            return nil
        }
        let backends = values.compactMap(TerminalBackend.init)
        guard backends.count == values.count,
              Set(backends.map(\.name)).count == backends.count,
              backends.contains(where: { $0.name == active }),
              backends.allSatisfy({ $0.active == ($0.name == active) }) else {
            return nil
        }
        self.init(active: active, backends: backends)
    }

    /// Return only a row that the gateway's exact catalog admitted for mobile
    /// selection. `needs_setup` is intentionally admitted; `unavailable` is
    /// a diagnostic state, not an action target.
    public func admittedBackend(named name: String) -> TerminalBackend? {
        guard let canonical = TerminalBackend.canonicalName(name) else { return nil }
        guard let backend = backends.first(where: { $0.name == canonical }),
              backend.status.isSelectable else {
            return nil
        }
        return backend
    }
}

/// Exact acknowledgement of a terminal backend write. A 2xx response with a
/// malformed or different backend is not evidence that the requested change
/// committed, so callers can refresh rather than optimistically repainting.
public struct TerminalBackendSelectionReceipt: Sendable, Equatable {
    public var backend: String

    init?(_ value: JSONValue, expectedBackend: String) {
        guard value["ok"]?.boolValue == true,
              let backend = TerminalBackend.canonicalName(value["backend"]?.stringValue),
              backend == expectedBackend else {
            return nil
        }
        self.backend = backend
    }
}

extension GatewayClient {
    /// Read the server's current, profile-scoped terminal catalog. This is the
    /// only discovery source used by Talaria; no device-side plug-in registry
    /// is consulted.
    public func terminalBackendCatalog(profile: String? = nil) async throws
        -> TerminalBackendCatalog {
        let value = try await restJSON(
            path: "api/tools/terminal/backends",
            query: Self.terminalBackendProfileQuery(profile),
            timeout: 30
        )
        guard let catalog = TerminalBackendCatalog(value) else {
            throw GatewayError(code: -8,
                               message: "Terminal backend catalog was malformed or ambiguous.")
        }
        return catalog
    }

    /// Persist one dynamically admitted terminal backend. Admission to a
    /// particular catalog snapshot is enforced by the caller; Hermes remains
    /// the final authority and validates the name against its live registry.
    @discardableResult
    public func selectTerminalBackend(_ backend: String, profile: String? = nil) async throws
        -> TerminalBackendSelectionReceipt {
        guard let canonical = TerminalBackend.canonicalName(backend) else {
            throw GatewayError(code: -9, message: "Invalid terminal backend name.")
        }
        var body: [String: JSONValue] = ["backend": .string(canonical)]
        if let profile = Self.terminalBackendProfile(profile) {
            body["profile"] = .string(profile)
        }
        let response = try await restJSON(
            path: "api/tools/terminal/backend",
            method: "PUT",
            body: .object(body),
            timeout: 30
        )
        guard let receipt = TerminalBackendSelectionReceipt(
            response, expectedBackend: canonical
        ) else {
            throw GatewayError(
                code: -8,
                message: "Terminal backend selection was not acknowledged by the gateway."
            )
        }
        return receipt
    }

    public static func terminalBackendProfileQuery(_ profile: String?) -> [URLQueryItem] {
        guard let profile = terminalBackendProfile(profile) else { return [] }
        return [URLQueryItem(name: "profile", value: profile)]
    }

    public static func terminalBackendProfile(_ profile: String?) -> String? {
        let value = profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}
