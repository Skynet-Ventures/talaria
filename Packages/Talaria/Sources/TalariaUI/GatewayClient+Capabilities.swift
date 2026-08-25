import Foundation
import TalariaKit

// The Capabilities RPC surface: skills, MCP servers, toolsets and gateway
// plugins. Shapes verified against the upstream checkout, not guessed:
//
//   tui_gateway/methods_tools.py — skills.manage 1815, skills.reload 2353,
//     mcp.catalog 1899, mcp.servers.list 1971 / add 2001 / set_api_key 2074 /
//     test 2154 / remove 2233 / oauth.start 2259 / oauth.poll 2320,
//     tools.list 1479, toolsets.list 1622, plugins.manage 2378
//   tui_gateway/mcp_rpc_helpers.py:45 — summarize_server (the MCP row shape)
//   tui_gateway/methods_profiles.py — profiles.describe 489, configure 660
//
// skills.manage / mcp.* / plugins.manage all take an optional `profile` that
// scopes HERMES_HOME server-side, so the phone can manage any bot's
// capabilities without switching the gateway's launch profile. toolsets.list
// and tools.list do NOT — they read the launch profile / a live session — so
// the *per-profile* toolset state comes from profiles.describe instead and
// tools.list is used only for the profile-independent tool names.

// MARK: - Wire models

/// Where a skill was found. The wire carries no bundled/user/plugin tag, so
/// this is the honest distinction we can actually make: skills enumerated by
/// profiles.describe live in `<profile>/skills`; everything else came from the
/// shared catalog skills.manage returns.
public enum SkillScope: String, Sendable {
    case profile, shared
}

public struct SkillEntry: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public var name: String
    /// SKILL.md `category:` frontmatter — skills.manage groups by it. Empty
    /// when the shared catalog didn't list this skill (it filters disabled
    /// ones out, so a disabled profile skill has no category to borrow).
    public var category: String
    public var scope: SkillScope
    public var enabled: Bool

    init(name: String, category: String, scope: SkillScope, enabled: Bool) {
        self.name = name; self.category = category
        self.scope = scope; self.enabled = enabled
    }
}

/// The configured filter for one MCP server's discovered tools.
///
/// Hermes treats an `include` key as a whitelist even when it is explicitly
/// empty. An `exclude` key is a denylist, so it deliberately stays dynamic as
/// the server grows its surface. Keeping those states distinct is important:
/// deriving an include list from a probe would freeze an exclude-mode catalog
/// entry to whatever tools happened to be visible at that moment.
public enum MCPToolFilterMode: String, Sendable, Equatable {
    /// No include/exclude key: Hermes registers the whole server surface.
    case all
    /// `tools.include`, including the meaningful explicit empty whitelist.
    case include
    /// `tools.exclude`, whose entries may be exact names or glob patterns.
    case exclude
    /// A malformed or future wire shape which the mobile editor must not
    /// rewrite, so a newer gateway's values survive untouched.
    case unavailable
}

public struct MCPToolFilter: Sendable, Equatable {
    public var mode: MCPToolFilterMode
    /// Exact configured strings. In exclude mode these can be glob patterns;
    /// their spelling and order are intentionally not normalized.
    public var patterns: [String]

    public init(mode: MCPToolFilterMode = .all, patterns: [String] = []) {
        self.mode = mode
        self.patterns = patterns
    }

    /// Decode the raw `tools` object emitted by `mcp.servers.list`.
    ///
    /// Do not compact-map arrays here: discarding a future/non-string value
    /// would make a later save destructive. A malformed filter is exposed as
    /// unavailable and remains read-only until a gateway that understands it
    /// can edit it.
    public init(_ value: JSONValue?) {
        guard let value else {
            self.init()
            return
        }
        if case .null = value {
            self.init()
            return
        }
        // Early gateway summaries exposed a bare string array as an allow
        // list. Keep reading that legacy shape; an explicit edit upgrades it
        // to the current `tools.include` object without changing its meaning.
        if let legacyInclude = Self.stringArray(value) {
            self.init(mode: .include, patterns: legacyInclude)
            return
        }
        guard let tools = value.objectValue else {
            self.init(mode: .unavailable)
            return
        }
        let include = tools["include"].flatMap(Self.filterPatterns)
        let exclude = tools["exclude"].flatMap(Self.filterPatterns)
        // A conflicting filter key may be ignored by current Hermes (include
        // wins), but an invalid one can be meaningful to a newer gateway.
        // Refuse to rewrite either shape rather than dropping it on save.
        if (tools["include"] != nil && include == nil)
            || (tools["exclude"] != nil && exclude == nil) {
            self.init(mode: .unavailable)
            return
        }
        if let include {
            self.init(mode: .include, patterns: include)
            return
        }
        if let exclude {
            self.init(mode: .exclude, patterns: exclude)
            return
        }
        self.init()
    }

    public var isEditable: Bool { mode != .unavailable }
    public var isExplicit: Bool { mode == .include || mode == .exclude }

    /// Apply this user-authored filter to a fresh raw `tools` object while
    /// retaining every unrelated (including future) tools key. The caller
    /// supplies the just-read config value rather than a summary row, because
    /// the whole-map Hermes REST write must never discard unknown server data.
    public func applying(to current: JSONValue?) throws -> JSONValue? {
        guard isEditable else {
            throw GatewayError(code: -8,
                               message: "This gateway's tool filter has an unsupported shape.")
        }
        guard MCPToolFilter(current).isEditable else {
            throw GatewayError(code: -8,
                               message: "The server's tool filter changed to an unsupported shape.")
        }

        var tools: [String: JSONValue]
        switch current {
        case nil, .some(.null):
            tools = [:]
        case .some(.object(let value)):
            tools = value
        case .some(.array):
            // Legacy bare allow-list; `MCPToolFilter(current)` above proved
            // every item is a string, so this explicit user edit can safely
            // migrate it to the current object shape.
            tools = [:]
        default:
            throw GatewayError(code: -8,
                               message: "The server's tool filter is not an object.")
        }

        switch mode {
        case .all:
            tools.removeValue(forKey: "include")
            tools.removeValue(forKey: "exclude")
        case .include:
            // Keep [] — it is an explicit empty whitelist, not no filter.
            tools["include"] = Self.encodedPatterns(
                patterns, preserving: tools["include"])
            tools.removeValue(forKey: "exclude")
        case .exclude:
            // Keep glob patterns verbatim and never infer an include list from
            // a transient tools/list probe.
            tools["exclude"] = Self.encodedPatterns(
                patterns, preserving: tools["exclude"])
            tools.removeValue(forKey: "include")
        case .unavailable:
            throw GatewayError(code: -8,
                               message: "This gateway's tool filter has an unsupported shape.")
        }
        return tools.isEmpty ? nil : .object(tools)
    }

    private static func stringArray(_ value: JSONValue) -> [String]? {
        guard let values = value.arrayValue else { return nil }
        var names: [String] = []
        names.reserveCapacity(values.count)
        for value in values {
            guard let name = value.stringValue else { return nil }
            names.append(name)
        }
        return names
    }

    /// Hermes also accepts a legacy single-string include/exclude value. Keep
    /// it readable and, when it remains one pattern, preserve that wire shape
    /// across an unrelated edit for older hand-written configurations.
    private static func filterPatterns(_ value: JSONValue) -> [String]? {
        value.stringValue.map { [$0] } ?? stringArray(value)
    }

    private static func encodedPatterns(_ patterns: [String],
                                        preserving current: JSONValue?) -> JSONValue {
        if patterns.count == 1, current?.stringValue != nil {
            return .string(patterns[0])
        }
        return .array(patterns.map(JSONValue.string))
    }
}

/// One row of `mcp.servers.list` (mcp_rpc_helpers.summarize_server). `env`
/// carries key names only — the gateway never ships secret values.
public struct MCPServer: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public var name: String
    /// "http" | "stdio" | "unknown"
    public var transport: String
    public var url: String?
    public var command: String?
    public var args: [String]
    public var envKeys: [String]
    /// "oauth" | "header" | nil
    public var auth: String?
    /// Only meaningful for `auth == "oauth"`; nil otherwise.
    public var oauthTokensPresent: Bool?
    public var enabled: Bool
    /// Lossless include/exclude filter state from config.yaml. `include: []`
    /// is intentionally distinct from `.all`.
    public var toolFilter: MCPToolFilter

    /// Compatibility projection for existing callers. Exclude-mode filters
    /// are deliberately not represented as an allow-list.
    public var toolAllowList: [String]? {
        toolFilter.mode == .include ? toolFilter.patterns : nil
    }

    init(_ v: JSONValue) {
        name = v["name"]?.stringValue ?? ""
        transport = v["transport"]?.stringValue ?? "unknown"
        url = v["url"]?.stringValue
        command = v["command"]?.stringValue
        args = v["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
        envKeys = v["env"]?.arrayValue?.compactMap(\.stringValue) ?? []
        auth = v["auth"]?.stringValue
        oauthTokensPresent = v["oauth_tokens_present"]?.boolValue
        enabled = v["enabled"]?.boolValue ?? true
        toolFilter = MCPToolFilter(v["tools"])
    }

    init(name: String, transport: String, url: String? = nil, command: String? = nil,
         args: [String] = [], envKeys: [String] = [], auth: String? = nil,
         oauthTokensPresent: Bool? = nil, enabled: Bool = true,
         toolFilter: MCPToolFilter? = nil, toolAllowList: [String]? = nil) {
        self.name = name; self.transport = transport; self.url = url
        self.command = command; self.args = args; self.envKeys = envKeys
        self.auth = auth; self.oauthTokensPresent = oauthTokensPresent
        self.enabled = enabled
        self.toolFilter = toolFilter
            ?? toolAllowList.map { MCPToolFilter(mode: .include, patterns: $0) }
            ?? MCPToolFilter()
    }

    /// The one-line "how does this connect" summary for a row.
    public var endpoint: String {
        if let url, !url.isEmpty { return url }
        if let command, !command.isEmpty {
            return ([command] + args).joined(separator: " ")
        }
        return transport
    }

    /// An OAuth server with no token on disk cannot serve tools yet.
    public var needsOAuth: Bool {
        auth == "oauth" && oauthTokensPresent != true
    }
}

/// One bundled-catalog entry (`mcp.catalog`), with this profile's install and
/// enable state already resolved server-side.
public struct MCPCatalogEntry: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public var name: String
    public var detail: String
    public var installed: Bool
    public var enabled: Bool
    /// Env keys that must be set before the server will work.
    public var requires: [String]
    public var transport: String

    init(_ v: JSONValue) {
        name = v["name"]?.stringValue ?? ""
        detail = v["description"]?.stringValue ?? ""
        installed = v["installed"]?.boolValue ?? false
        enabled = v["enabled"]?.boolValue ?? false
        requires = v["requires"]?.arrayValue?.compactMap(\.stringValue) ?? []
        transport = v["transport"]?.stringValue ?? "stdio"
    }

    init(name: String, detail: String, installed: Bool, enabled: Bool,
         requires: [String] = [], transport: String = "stdio") {
        self.name = name; self.detail = detail; self.installed = installed
        self.enabled = enabled; self.requires = requires; self.transport = transport
    }
}

public struct MCPToolInfo: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public var name: String
    public var detail: String
}

/// Result of `mcp.servers.test` — a real connect + tools/list probe. The
/// handler answers `ok:false` in the result (not an RPC error) for a failed
/// connect, so a probe failure is data, not a thrown error.
public struct MCPProbeResult: Sendable, Equatable {
    public var ok: Bool
    public var error: String?
    public var tools: [MCPToolInfo]
    public var prompts: Int
    public var resources: Int
    public var oauthNeeded: Bool

    init(_ v: JSONValue) {
        ok = v["ok"]?.boolValue ?? false
        error = v["error"]?.stringValue
        tools = v["tools"]?.arrayValue?.compactMap { row in
            guard let name = row["name"]?.stringValue else { return nil }
            return MCPToolInfo(name: name, detail: row["description"]?.stringValue ?? "")
        } ?? []
        prompts = v["prompts"]?.intValue ?? 0
        resources = v["resources"]?.intValue ?? 0
        oauthNeeded = v["oauth_needed"]?.boolValue ?? false
    }

    init(ok: Bool, error: String? = nil, tools: [MCPToolInfo] = [],
         prompts: Int = 0, resources: Int = 0, oauthNeeded: Bool = false) {
        self.ok = ok; self.error = error; self.tools = tools
        self.prompts = prompts; self.resources = resources; self.oauthNeeded = oauthNeeded
    }
}

public struct MCPOAuthFlow: Sendable, Equatable {
    public var sessionID: String
    public var authURL: URL?
    public var flow: String
}

public struct MCPOAuthStatus: Sendable, Equatable {
    /// "pending" | "approved" | "error"
    public var status: String
    public var errorMessage: String?
    public var authURL: URL?

    public var isApproved: Bool { status == "approved" }
    public var isPending: Bool { status == "pending" }
}

public struct ToolsetEntry: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public var name: String
    /// profiles.describe adds a human label; toolsets.list has only the key.
    public var label: String
    public var detail: String
    public var toolCount: Int
    public var enabled: Bool
    /// Tool names from tools.list, merged in lazily for the expanded row.
    public var tools: [String]

    init(_ v: JSONValue) {
        name = v["name"]?.stringValue ?? ""
        label = v["label"]?.stringValue ?? v["name"]?.stringValue ?? ""
        detail = v["description"]?.stringValue ?? ""
        toolCount = v["tool_count"]?.intValue ?? 0
        enabled = v["enabled"]?.boolValue ?? true
        tools = v["tools"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    init(name: String, label: String, detail: String, toolCount: Int,
         enabled: Bool, tools: [String] = []) {
        self.name = name; self.label = label; self.detail = detail
        self.toolCount = toolCount; self.enabled = enabled; self.tools = tools
    }
}

/// A gateway-side plugin row (`plugins.manage` action:"list", contract v6).
/// Addressed by `key` — names collide across category dirs (two `fal`
/// backends), so every toggle sends the key.
public struct GatewayPlugin: Identifiable, Sendable, Equatable {
    public var id: String { key.isEmpty ? name : key }
    public var name: String
    public var key: String
    public var version: String
    public var detail: String
    /// "bundled" | "user" | …
    public var source: String
    /// "enabled" | "not enabled" | …
    public var status: String
    /// Agent-Plugins v1 package (plugin.json — the portable skills/MCP format).
    public var portable: Bool

    public var enabled: Bool { status == "enabled" }
    public var isBundled: Bool { source == "bundled" }

    init(_ v: JSONValue) {
        name = v["name"]?.stringValue ?? ""
        key = v["key"]?.stringValue ?? ""
        version = v["version"]?.stringValue ?? ""
        detail = v["description"]?.stringValue ?? ""
        source = v["source"]?.stringValue ?? ""
        status = v["status"]?.stringValue ?? ""
        portable = v["portable"]?.boolValue ?? false
    }

    init(name: String, key: String, version: String, detail: String,
         source: String, status: String, portable: Bool = false) {
        self.name = name; self.key = key; self.version = version
        self.detail = detail; self.source = source; self.status = status
        self.portable = portable
    }
}

/// The per-profile half of the capabilities picture (profiles.describe). This
/// is the authoritative source for skill and toolset *enablement*: it walks
/// the profile's own skills dir and resolves the `tools.enabled_toolsets` pin,
/// where skills.manage/toolsets.list report the launch profile's runtime view.
public struct ProfileCapabilities: Sendable {
    /// name + enable state of one skill in `<profile>/skills`.
    public struct SkillFlag: Identifiable, Sendable, Equatable {
        public var id: String { name }
        public var name: String
        public var enabled: Bool
    }

    public var skills: [SkillFlag]
    public var toolsets: [ToolsetEntry]
    public var toolsetsPinned: Bool

    init(_ v: JSONValue) {
        skills = v["skills"]?.arrayValue?.compactMap { row in
            guard let name = row["name"]?.stringValue else { return nil }
            return SkillFlag(name: name, enabled: row["enabled"]?.boolValue ?? true)
        } ?? []
        toolsets = v["toolsets"]?.arrayValue?.map(ToolsetEntry.init) ?? []
        toolsetsPinned = v["toolsets_pinned"]?.boolValue ?? false
    }
}

// MARK: - RPCs

extension GatewayClient {

    /// JSON-RPC "unknown method" — the gateway is older than the RPC we asked
    /// for (server.py:2070). Callers hide the whole section rather than
    /// showing an error the user cannot act on.
    public static let methodNotFound = -32601

    // MARK: Skills

    /// The shared skill catalog grouped by SKILL.md category. Note the
    /// upstream handler filters *disabled* skills out and caches the walk
    /// per-process, so this is a display/annotation source only — the
    /// per-profile enable state comes from `profileCapabilities`.
    public func skillCatalog(profile: String?) async throws -> [String: [String]] {
        var params: [String: JSONValue] = ["action": "list"]
        if let profile, !profile.isEmpty { params["profile"] = .string(profile) }
        let result = try await rpc("skills.manage", .object(params))
        var out: [String: [String]] = [:]
        for (category, names) in result["skills"]?.objectValue ?? [:] {
            out[category] = names.arrayValue?.compactMap(\.stringValue) ?? []
        }
        return out
    }

    /// Rescan the skills tree. Returns the human-readable summary the handler
    /// renders ("Added skills: …", "N skill(s) available").
    @discardableResult
    public func reloadSkills() async throws -> String {
        let result = try await rpc("skills.reload", .object([:]), timeout: 120)
        return result["output"]?.stringValue ?? ""
    }

    // MARK: Profile snapshot

    public func profileCapabilities(_ name: String) async throws -> ProfileCapabilities {
        ProfileCapabilities(try await describeProfile(name))
    }

    /// Pin this profile's toolsets. An empty list clears the pin, which is how
    /// "everything enabled" is expressed — sending every name instead would
    /// freeze the profile against toolsets added later.
    public func setProfileToolsets(name: String, enabled: [String]) async throws {
        try await rpc("profiles.configure",
                      ["name": .string(name),
                       "enabled_toolsets": .array(enabled.map(JSONValue.string))])
    }

    // MARK: Toolsets / tools

    /// The toolset universe with the launch profile's (or a session's)
    /// enablement. Used as the fallback when profiles.describe is unavailable.
    public func toolsetsList(sessionID: String? = nil) async throws -> [ToolsetEntry] {
        var params: [String: JSONValue] = [:]
        if let sessionID { params["session_id"] = .string(sessionID) }
        let result = try await rpc("toolsets.list", .object(params))
        return result["toolsets"]?.arrayValue?.map(ToolsetEntry.init) ?? []
    }

    /// Same rows as `toolsetsList` plus each toolset's resolved tool names.
    public func toolsList(sessionID: String? = nil) async throws -> [ToolsetEntry] {
        var params: [String: JSONValue] = [:]
        if let sessionID { params["session_id"] = .string(sessionID) }
        let result = try await rpc("tools.list", .object(params))
        return result["toolsets"]?.arrayValue?.map(ToolsetEntry.init) ?? []
    }

    // MARK: MCP

    public func mcpServers(profile: String?) async throws -> [MCPServer] {
        let result = try await rpc("mcp.servers.list", mcpParams(profile: profile))
        return result["servers"]?.arrayValue?.map(MCPServer.init) ?? []
    }

    public func mcpCatalog(profile: String?) async throws -> [MCPCatalogEntry] {
        let result = try await rpc("mcp.catalog", mcpParams(profile: profile))
        return result["servers"]?.arrayValue?.map(MCPCatalogEntry.init) ?? []
    }

    /// Install a live catalog entry into this profile's config.yaml.
    ///
    /// Do not route catalog rows through `mcp.servers.add(preset:)`: that RPC
    /// only knows its small static preset map. The catalog REST installer owns
    /// `tools.default_excluded`, glob patterns, prior include/exclude state,
    /// and the failed-probe fallback, so it is the only path that can preserve
    /// the server-driven catalog's filter semantics.
    public func mcpAddFromCatalog(profile: String?, name: String) async throws {
        do {
            let result = try await restJSON(
                path: "api/mcp/catalog/install",
                method: "POST",
                query: mcpRESTQuery(profile: profile),
                body: .object([
                    "name": .string(name),
                    "enable": .bool(true),
                ]),
                timeout: 120)
            guard result["ok"]?.boolValue == true else {
                throw GatewayError(code: -8,
                                   message: "The gateway did not confirm the catalog install.")
            }
        } catch let error as GatewayError where error.code == 404 {
            // Older Hermes gateways predate the REST catalog installer but
            // retain the historic WebSocket preset path. Keep that narrow
            // compatibility fallback; current dynamic entries never take it.
            var params = mcpParams(profile: profile).objectValue ?? [:]
            params["name"] = .string(name)
            params["preset"] = .string(name)
            try await rpc("mcp.servers.add", .object(params), timeout: 120)
        }
    }

    /// Add a hand-configured server. Exactly one of `url` (http/sse) or
    /// `command` (stdio) must be present — the handler rejects neither.
    public func mcpAddServer(profile: String?, name: String, url: String?,
                             command: String?, args: [String]) async throws {
        var config: [String: JSONValue] = [:]
        if let url, !url.isEmpty { config["url"] = .string(url) }
        if let command, !command.isEmpty {
            config["command"] = .string(command)
            if !args.isEmpty { config["args"] = .array(args.map(JSONValue.string)) }
        }
        var params = mcpParams(profile: profile).objectValue ?? [:]
        params["name"] = .string(name)
        params["config"] = .object(config)
        try await rpc("mcp.servers.add", .object(params), timeout: 120)
    }

    public func mcpRemoveServer(profile: String?, name: String) async throws {
        var params = mcpParams(profile: profile).objectValue ?? [:]
        params["name"] = .string(name)
        try await rpc("mcp.servers.remove", .object(params))
    }

    /// Store a credential for a server. The secret goes to the profile's .env;
    /// only an interpolation template lands in config.yaml.
    public func mcpSetAPIKey(profile: String?, name: String, value: String,
                             envVar: String?) async throws {
        var params = mcpParams(profile: profile).objectValue ?? [:]
        params["name"] = .string(name)
        params["value"] = .string(value)
        if let envVar, !envVar.isEmpty { params["env_var"] = .string(envVar) }
        try await rpc("mcp.servers.set_api_key", .object(params))
    }

    /// Connect + tools/list probe. Pooled server-side: a cold stdio `npx`
    /// spawn blocks for many seconds, so this gets a long ceiling.
    public func mcpTestServer(profile: String?, name: String) async throws -> MCPProbeResult {
        var params = mcpParams(profile: profile).objectValue ?? [:]
        params["name"] = .string(name)
        return MCPProbeResult(try await rpc("mcp.servers.test", .object(params), timeout: 120))
    }

    /// Replace one server's include/exclude filter without losing the rest of
    /// the raw MCP configuration. Hermes exposes this edit as a whole-map REST
    /// replacement, so first read the full `mcp_servers` map (not the lossy
    /// list summary), update only `tools`, then send that fresh map back.
    ///
    /// This intentionally does not use `tools.configure`: that RPC appends to
    /// `tools.exclude` even for an include-mode server and therefore cannot
    /// preserve an explicit `tools.include: []` whitelist.
    public func setMCPToolFilter(profile: String?, name: String,
                                 filter: MCPToolFilter) async throws {
        guard filter.isEditable else {
            throw GatewayError(code: -8,
                               message: "This gateway's tool filter cannot be edited safely.")
        }
        let query = mcpRESTQuery(profile: profile)
        let config = try await restJSON(path: "api/config", query: query, timeout: 120)
        guard let rawServers = config["mcp_servers"]?.objectValue else {
            throw GatewayError(code: -8,
                               message: "The gateway did not return an MCP server configuration.")
        }
        guard let rawServer = rawServers[name]?.objectValue else {
            throw GatewayError(code: -8,
                               message: "MCP server '\(name)' no longer exists in this profile.")
        }

        // Refuse to overwrite a concurrently introduced future/malformed
        // filter. The user can refresh against a gateway that understands it;
        // silently coercing it would violate the lossless contract.
        guard MCPToolFilter(rawServer["tools"]).isEditable else {
            throw GatewayError(code: -8,
                               message: "The gateway returned an unsupported tool filter shape.")
        }

        var servers = rawServers
        var server = rawServer
        if let tools = try filter.applying(to: rawServer["tools"]) {
            server["tools"] = tools
        } else {
            server.removeValue(forKey: "tools")
        }
        servers[name] = .object(server)

        let result = try await restJSON(
            path: "api/mcp/servers",
            method: "PUT",
            query: query,
            body: .object(["servers": .object(servers)]),
            timeout: 120)
        guard result["ok"]?.boolValue == true else {
            throw GatewayError(code: -8,
                               message: "The gateway did not confirm the MCP filter update.")
        }
    }

    /// Begin the session-backed OAuth flow. The gateway drives the same
    /// machinery `hermes mcp login` uses and captures the redirect on its own
    /// loopback listener — the client only opens `auth_url` and polls.
    public func mcpOAuthStart(profile: String?, name: String) async throws -> MCPOAuthFlow {
        var params = mcpParams(profile: profile).objectValue ?? [:]
        params["name"] = .string(name)
        let result = try await rpc("mcp.servers.oauth.start", .object(params), timeout: 120)
        return MCPOAuthFlow(sessionID: result["session_id"]?.stringValue ?? "",
                            authURL: result["auth_url"]?.stringValue.flatMap(URL.init(string:)),
                            flow: result["flow"]?.stringValue ?? "pkce")
    }

    public func mcpOAuthPoll(profile: String?, name: String,
                             sessionID: String) async throws -> MCPOAuthStatus {
        var params = mcpParams(profile: profile).objectValue ?? [:]
        params["name"] = .string(name)
        params["session_id"] = .string(sessionID)
        let result = try await rpc("mcp.servers.oauth.poll", .object(params))
        return MCPOAuthStatus(status: result["status"]?.stringValue ?? "pending",
                              errorMessage: result["error_message"]?.stringValue,
                              authURL: result["auth_url"]?.stringValue.flatMap(URL.init(string:)))
    }

    // MARK: Plugins

    public func pluginsList(profile: String?) async throws -> [GatewayPlugin] {
        var params = mcpParams(profile: profile).objectValue ?? [:]
        params["action"] = "list"
        let result = try await rpc("plugins.manage", .object(params), timeout: 120)
        return result["plugins"]?.arrayValue?.map(GatewayPlugin.init) ?? []
    }

    /// Toggle by canonical registry key (contract v6). Returns the refreshed
    /// row so the caller doesn't have to re-list the whole set.
    @discardableResult
    public func pluginToggle(profile: String?, key: String,
                             enable: Bool) async throws -> GatewayPlugin? {
        var params = mcpParams(profile: profile).objectValue ?? [:]
        params["action"] = "toggle"
        params["key"] = .string(key)
        params["enable"] = .bool(enable)
        let result = try await rpc("plugins.manage", .object(params), timeout: 120)
        return result["plugin"].map(GatewayPlugin.init)
    }

    // MARK: -

    private func mcpParams(profile: String?) -> JSONValue {
        guard let profile, !profile.isEmpty else { return .object([:]) }
        return .object(["profile": .string(profile)])
    }

    private func mcpRESTQuery(profile: String?) -> [URLQueryItem] {
        guard let profile, !profile.isEmpty else { return [] }
        return [URLQueryItem(name: "profile", value: profile)]
    }
}
