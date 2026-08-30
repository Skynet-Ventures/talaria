import Foundation
import TalariaKit

// The model-catalog RPC surface, typed. Shapes verified against the upstream
// checkout, not guessed:
//
//   tui_gateway/methods_complete.py — model.options 469, model.save_key 492,
//     model.disconnect 572
//   hermes_cli/inventory.py — build_model_options_payload 284 →
//     build_models_payload 114 (the {providers, model, provider} shape, plus
//     picker_hints / pricing / capabilities / featured enrichment) and
//     _moa_provider_row 855 (the virtual `moa` presets row)
//   tui_gateway/server.py — config.set 11732: key "model" answers
//     {key, value, warning, confirm_required, confirm_message, scope} and adds
//     `deferred: true` when a turn is streaming (11783); the expensive-model
//     guard at _apply_model_switch 4868 is cleared by re-sending the same call
//     with confirm_expensive_model: true.
//
// `ModelLabels` is a straight port of the desktop picker's label derivation
// (apps/desktop/src/lib/model-status-label.ts, reasoning-effort.ts,
// model-search-text.ts, store/model-visibility.ts collapseModelFamilies). It is
// pure string work with no platform types so both the sheet and the chat strip
// can render the same "Opus 4.8 · Fast Med" the desktop shows.

// MARK: - Wire models

/// Per-model option support (`capabilities` map, inventory.py
/// `_apply_capabilities`). Gates the fast/reasoning controls to what the
/// backend will actually accept for this model.
public struct ModelOptionCapabilities: Sendable, Hashable {
    public var fast: Bool
    public var reasoning: Bool

    public init(fast: Bool = false, reasoning: Bool = true) {
        self.fast = fast; self.reasoning = reasoning
    }

    init(_ v: JSONValue) {
        fast = v["fast"]?.boolValue ?? false
        reasoning = v["reasoning"]?.boolValue ?? true
    }
}

/// Formatted $/Mtok price tag for one model (present only when the gateway
/// enriched the row with pricing).
public struct ModelPriceTag: Sendable, Hashable {
    public var input: String
    public var output: String
    public var cache: String?
    public var free: Bool
    /// Rounded percent off list, when the provider reported a sale.
    public var discountPercent: Int?
    public var wasInput: String?
    public var wasOutput: String?

    init(_ v: JSONValue) {
        input = v["input"]?.stringValue ?? ""
        output = v["output"]?.stringValue ?? ""
        cache = v["cache"]?.stringValue
        free = v["free"]?.boolValue ?? false
        discountPercent = v["discount_percent"]?.intValue
        wasInput = v["was_input"]?.stringValue
        wasOutput = v["was_output"]?.stringValue
    }

    public init(input: String, output: String, free: Bool = false) {
        self.input = input; self.output = output; self.free = free
    }

    /// Nothing worth rendering — mirrors the desktop `ModelPrice` early return.
    public var isEmpty: Bool { !free && input.isEmpty && output.isEmpty }

    /// "$3.00 / $15.00" — the compact in/out pair the desktop row shows.
    public var compact: String {
        free ? "FREE" : "\(input.isEmpty ? "?" : input) / \(output.isEmpty ? "?" : output)"
    }
}

/// One provider row of `model.options`.
public struct ModelProviderRow: Sendable, Identifiable, Hashable {
    public var id: String { slug }
    public var slug: String
    public var name: String
    public var isCurrent: Bool
    /// Curated, backend-ordered model ids. Never re-sort these.
    public var models: [String]
    /// The provider's full catalog size (may exceed `models` after dedup).
    public var totalModels: Int
    /// "built-in" | "canonical" | "user-config" | "virtual" | …
    public var source: String
    /// Row-level caution the picker renders above the models (MoA explains
    /// itself this way; a re-auth hint arrives the same route).
    public var warning: String
    /// One flagship per lab — what an aggregator row shows before the user
    /// customizes. Empty for single-lab providers (fall back to top-N).
    public var featuredModels: [String]
    public var authenticated: Bool
    /// "api_key" | "oauth_*" | "virtual" | …
    public var authType: String
    /// Env var an `api_key` provider's key is pasted into (model.save_key).
    public var keyEnv: String
    public var isUserDefined: Bool
    /// Every accepted identity for a user-defined endpoint. A session reports
    /// the canonical `custom:<key>` form while the row's slug is the bare
    /// config key, so "is this the current provider?" must check membership.
    public var aliases: [String]
    /// Nous only: true = free tier, false = pro, nil = not applicable.
    public var freeTier: Bool?
    /// Models the current account may not select (shown disabled).
    public var unavailableModels: Set<String>
    public var pricing: [String: ModelPriceTag]
    public var capabilities: [String: ModelOptionCapabilities]

    public init(slug: String, name: String, isCurrent: Bool = false, models: [String] = [],
                totalModels: Int? = nil, source: String = "", warning: String = "",
                featuredModels: [String] = [], authenticated: Bool = true,
                authType: String = "", keyEnv: String = "", isUserDefined: Bool = false,
                aliases: [String] = [], freeTier: Bool? = nil,
                unavailableModels: Set<String> = [],
                pricing: [String: ModelPriceTag] = [:],
                capabilities: [String: ModelOptionCapabilities] = [:]) {
        self.slug = slug; self.name = name; self.isCurrent = isCurrent
        self.models = models; self.totalModels = totalModels ?? models.count
        self.source = source; self.warning = warning; self.featuredModels = featuredModels
        self.authenticated = authenticated; self.authType = authType; self.keyEnv = keyEnv
        self.isUserDefined = isUserDefined; self.aliases = aliases; self.freeTier = freeTier
        self.unavailableModels = unavailableModels
        self.pricing = pricing; self.capabilities = capabilities
    }

    init(_ v: JSONValue) {
        slug = v["slug"]?.stringValue ?? ""
        name = v["name"]?.stringValue ?? v["slug"]?.stringValue ?? ""
        isCurrent = v["is_current"]?.boolValue ?? false
        // Rows carry bare id strings; tolerate the {id}/{model} object shape
        // some aggregators have shipped rather than dropping the whole row.
        models = (v["models"]?.arrayValue ?? []).compactMap {
            $0.stringValue ?? ($0["id"] ?? $0["model"])?.stringValue
        }
        totalModels = v["total_models"]?.intValue ?? models.count
        source = v["source"]?.stringValue ?? ""
        warning = v["warning"]?.stringValue ?? ""
        featuredModels = v["featured_models"]?.arrayValue?.compactMap(\.stringValue) ?? []
        authenticated = v["authenticated"]?.boolValue ?? true
        authType = v["auth_type"]?.stringValue ?? ""
        keyEnv = v["key_env"]?.stringValue ?? ""
        isUserDefined = v["is_user_defined"]?.boolValue ?? false
        aliases = v["aliases"]?.arrayValue?.compactMap(\.stringValue) ?? []
        freeTier = v["free_tier"]?.boolValue
        unavailableModels = Set(v["unavailable_models"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        pricing = (v["pricing"]?.objectValue ?? [:]).mapValues(ModelPriceTag.init)
        capabilities = (v["capabilities"]?.objectValue ?? [:]).mapValues(ModelOptionCapabilities.init)
    }

    /// The virtual MoA row — presets, not worker models. Rendered in its own
    /// section so a preset never appears twice.
    public var isMoA: Bool { slug.lowercased() == "moa" }

    /// Whether this row owns `provider`, checking aliases (a custom endpoint
    /// reports `custom:<key>` while its row slug is the bare config key).
    public func owns(provider: String) -> Bool {
        !provider.isEmpty && (slug == provider || aliases.contains(provider))
    }

    public func capabilities(for model: String) -> ModelOptionCapabilities {
        capabilities[model] ?? ModelOptionCapabilities(fast: false, reasoning: true)
    }
}

/// The whole `model.options` answer.
public struct ModelCatalog: Sendable {
    public var providers: [ModelProviderRow]
    /// The gateway's current model / provider for the scope we asked about.
    public var model: String
    public var provider: String

    public static let empty = ModelCatalog(providers: [], model: "", provider: "")

    public init(providers: [ModelProviderRow], model: String, provider: String) {
        self.providers = providers; self.model = model; self.provider = provider
    }

    init(_ v: JSONValue) {
        providers = v["providers"]?.arrayValue?.map(ModelProviderRow.init) ?? []
        model = v["model"]?.stringValue ?? ""
        provider = v["provider"]?.stringValue ?? ""
    }

    /// True when no provider offers a single selectable model — the state the
    /// picker must report honestly instead of rendering an empty list.
    public var hasSelectableModels: Bool {
        providers.contains { !$0.models.isEmpty }
    }

    /// Everything but the virtual MoA row.
    public var modelProviders: [ModelProviderRow] { providers.filter { !$0.isMoA } }

    /// The MoA preset names, or empty when this gateway configures none.
    public var moaPresets: [String] { providers.first(where: \.isMoA)?.models ?? [] }

    public func row(owning provider: String) -> ModelProviderRow? {
        providers.first { $0.owns(provider: provider) }
    }

    /// Which model/provider pair the picker should mark current. Port of
    /// `currentPickerSelection` — a complete local pair wins over the catalog's
    /// own report, and fields are never mixed across the two sources.
    public func currentSelection(localModel: String,
                                 localProvider: String) -> (model: String, provider: String) {
        if !localModel.isEmpty, !localProvider.isEmpty { return (localModel, localProvider) }
        if !model.isEmpty, !provider.isEmpty { return (model, provider) }
        return (localModel.isEmpty ? model : localModel,
                localProvider.isEmpty ? provider : localProvider)
    }
}

/// What `config.set key:"model"` answered.
public struct ModelSwitchOutcome: Sendable, Equatable {
    /// The resolved model id the gateway accepted (or stashed).
    public var value: String
    public var warning: String
    /// The expensive-model / selection guard fired: nothing was applied.
    /// Re-send with `confirmExpensive: true` to go through.
    public var confirmRequired: Bool
    public var confirmMessage: String
    /// "session" | "global"
    public var scope: String
    /// Stashed mid-turn — applies at the next turn start, not now.
    public var deferred: Bool

    init(_ v: JSONValue) {
        value = v["value"]?.stringValue ?? ""
        warning = v["warning"]?.stringValue ?? ""
        confirmRequired = v["confirm_required"]?.boolValue ?? false
        confirmMessage = v["confirm_message"]?.stringValue ?? ""
        scope = v["scope"]?.stringValue ?? "session"
        deferred = v["deferred"]?.boolValue ?? false
    }

    public init(value: String, warning: String = "", confirmRequired: Bool = false,
                confirmMessage: String = "", scope: String = "session", deferred: Bool = false) {
        self.value = value; self.warning = warning
        self.confirmRequired = confirmRequired; self.confirmMessage = confirmMessage
        self.scope = scope; self.deferred = deferred
    }
}

// MARK: - Model families

/// A model and its optional `…-fast` sibling collapsed into one row — port of
/// `collapseModelFamilies`. One row, one selection, one toggle.
public struct ModelFamily: Sendable, Hashable, Identifiable {
    public var id: String
    public var fastID: String?

    public init(id: String, fastID: String? = nil) {
        self.id = id; self.fastID = fastID
    }
}

/// How "fast" is reached for a model — two different mechanisms, exactly as
/// `resolveFastControl` splits them.
public enum ModelFastControl: Sendable, Equatable {
    /// Not offered here.
    case none
    /// The `speed=fast` request parameter (config.set key:"fast").
    case param(on: Bool)
    /// A separate `…-fast` sibling model id, selected via the model field.
    case variant(baseID: String, fastID: String, on: Bool)

    public var isOffered: Bool {
        if case .none = self { return false }
        return true
    }

    public var isOn: Bool {
        switch self {
        case .none: return false
        case .param(let on): return on
        case .variant(_, _, let on): return on
        }
    }
}

// MARK: - Label derivation

/// Display names, status labels and search text for model ids. Straight port of
/// the desktop helpers so a model reads identically on both surfaces.
public enum ModelLabels {

    /// Hermes' reasoning levels in ascending order (backend
    /// VALID_REASONING_EFFORTS). `none` is not a level — it is thinking off,
    /// owned by the Thinking toggle rather than the scale.
    public static let reasoningEfforts = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    /// The built-in level when neither the surface nor the profile specifies.
    public static let defaultEffort = "medium"

    /// Compact labels for tight chrome (picker rows, the chat strip).
    private static let shortLabels: [String: String] = [
        "none": "Off", "minimal": "Min", "low": "Low", "medium": "Med",
        "high": "High", "xhigh": "XHigh", "max": "Max", "ultra": "Ultra",
    ]

    /// Extra search tokens; never changes a wire id. Kept in sync with
    /// model-search-text.ts / hermes_cli/model_search.py.
    private static let searchAliases: [String: [String]] = ["k3": ["kimi-k3", "kimi"]]

    /// Trailing id variants rendered as a grayed tag beside the name, so
    /// `…-4.8` and `…-4.8-fast` don't collapse to the same display name.
    private static let variantTags: [(suffix: String, label: String)] = [
        ("-fast", "Fast"), ("-thinking", "Thinking"),
        ("-preview", "Preview"), ("-latest", "Latest"),
    ]

    /// `value.trim().toLowerCase()` — the desktop's search-key normalization.
    public static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func effortLabel(_ effort: String) -> String {
        let key = normalize(effort)
        guard !key.isEmpty else { return "" }
        return shortLabels[key] ?? effort
    }

    public static func isReasoningEffort(_ value: String) -> Bool {
        reasoningEfforts.contains(normalize(value))
    }

    /// Thinking is on unless a level explicitly says otherwise; empty means
    /// "inherit", so it resolves through `fallback` first.
    public static func isThinkingEnabled(_ effort: String, fallback: String = defaultEffort) -> Bool {
        normalize(effort.isEmpty ? fallback : effort) != "none"
    }

    /// The level a scale control should show. Empty inherits `fallback`;
    /// `none` selects nothing; anything unrecognized clamps to the default.
    public static func resolveEffort(_ effort: String, fallback: String = defaultEffort) -> String {
        let value = normalize(effort.isEmpty ? fallback : effort)
        if value == "none" { return "" }
        return isReasoningEffort(value) ? value : defaultEffort
    }

    /// Strip a provider prefix (`vendor/model`) for display.
    public static func baseID(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    /// Split a model id into a clean display name plus an optional variant tag.
    public static func displayParts(_ model: String) -> (name: String, tag: String) {
        var base = baseID(model)
        var tag = ""
        for entry in variantTags where base.lowercased().hasSuffix(entry.suffix) {
            tag = entry.label
            base = String(base.dropLast(entry.suffix.count))
            break
        }
        // Drop a trailing date-pin (`…-20251101`) — snapshot noise, not a name.
        base = datePinnedBase(base) ?? base
        let pretty = prettify(base)
        if !pretty.isEmpty { return (pretty, tag) }
        let fallback = model.trimmingCharacters(in: .whitespaces)
        return (fallback.isEmpty ? "No model" : fallback, tag)
    }

    /// Friendly one-line model name for menus and the chat strip.
    public static func displayName(_ model: String) -> String {
        displayParts(model).name
    }

    /// Haystack for substring model search; never changes the wire id.
    public static func searchText(_ model: String) -> String {
        let id = model.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return model }
        guard let aliases = searchAliases[id.lowercased()], !aliases.isEmpty else { return id }
        return id + " " + aliases.joined(separator: " ")
    }

    /// The trailing muted label on a picker row: "Fast Med", "Med", "High".
    /// Fast is shown only when the model actually offers it and it is on;
    /// the effort is always surfaced when the model supports reasoning, so the
    /// live level is visible at a glance rather than only when non-default.
    public static func rowStatusLabel(fastOn: Bool, reasoningSupported: Bool,
                                      effort: String, defaultEffort: String = defaultEffort) -> String {
        var parts: [String] = []
        if fastOn { parts.append("Fast") }
        if reasoningSupported {
            let label = effortLabel(effort.isEmpty ? defaultEffort : effort)
            if !label.isEmpty { parts.append(label) }
        }
        return parts.joined(separator: " ")
    }

    /// Chat-strip trigger label — model name plus the live session state.
    /// `defaultEffort` is the profile's configured level, used when the surface
    /// has no explicit effort so the label never advertises a level the agent
    /// won't use.
    public static func statusLabel(model: String, reasoningEffort: String = "",
                                   defaultEffort: String = defaultEffort,
                                   fastMode: Bool = false) -> String {
        let name = displayName(model)
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else { return name }
        // Fast shows for the speed=fast param OR a `…-fast` model id.
        let fast = fastMode || baseID(model).lowercased().hasSuffix("-fast")
        let meta = rowStatusLabel(fastOn: fast, reasoningSupported: true,
                                  effort: reasoningEffort, defaultEffort: defaultEffort)
        return meta.isEmpty ? name : "\(name) · \(meta)"
    }

    /// Collapse a provider's curated list so a base model and its `…-fast`
    /// variant become one family. Order follows the base model's position; a
    /// date-pinned snapshot superseded by its rolling alias is dropped.
    public static func collapseFamilies(_ models: [String]) -> [ModelFamily] {
        let present = Set(models)
        var families: [ModelFamily] = []
        var consumed = Set<String>()

        for model in models {
            if consumed.contains(model) { continue }
            if model.lowercased().hasSuffix("-fast"),
               present.contains(String(model.dropLast(5))) {
                continue    // represented by its base entry
            }
            if let rolling = datePinnedBase(model), present.contains(rolling) {
                continue    // a dupe of the rolling alias
            }
            let fastID = model + "-fast"
            let hasFast = present.contains(fastID)
            families.append(ModelFamily(id: model, fastID: hasFast ? fastID : nil))
            consumed.insert(model)
            if hasFast { consumed.insert(fastID) }
        }
        return families
    }

    /// Resolve the fast mechanism for a model: prefer the `speed=fast`
    /// parameter when the backend supports it, else a `…-fast` sibling.
    public static func fastControl(model: String, providerModels: [String],
                                   paramSupported: Bool, fastMode: Bool) -> ModelFastControl {
        if paramSupported { return .param(on: fastMode) }

        if model.lowercased().hasSuffix("-fast") {
            let base = String(model.dropLast(5))
            // Only a toggle when there is a base to switch back to; otherwise
            // it's a standalone fast model with no off state.
            return providerModels.contains(base)
                ? .variant(baseID: base, fastID: model, on: true)
                : .none
        }

        let fastID = model + "-fast"
        if providerModels.contains(fastID) {
            return .variant(baseID: model, fastID: fastID, on: false)
        }

        // Not natively offered — but if the session still carries the speed
        // param, expose the toggle so it can be turned off rather than stranded.
        return fastMode ? .param(on: true) : .none
    }

    // MARK: Internals

    /// The id with a trailing `-` + 8 digits removed, or nil when unpinned.
    private static func datePinnedBase(_ model: String) -> String? {
        guard model.count >= 9 else { return nil }
        let tail = model.suffix(9)
        guard tail.first == "-",
              tail.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return String(model.dropLast(9))
    }

    private static func prettify(_ base: String) -> String {
        let lower = base.lowercased()
        if lower.hasPrefix("claude-") {
            return titleCase(String(base.dropFirst(7)).replacingOccurrences(of: "-", with: " "))
        }
        if lower.hasPrefix("gpt-") {
            return "GPT-" + String(base.dropFirst(4))
        }
        if lower.hasPrefix("gemini-") {
            return "Gemini " + String(base.dropFirst(7)).replacingOccurrences(of: "-", with: " ")
        }
        return titleCase(base.replacingOccurrences(of: "-", with: " "))
    }

    /// Uppercase the first character of every word run (JS `\b\w` semantics,
    /// where a word char is [A-Za-z0-9_]).
    private static func titleCase(_ text: String) -> String {
        var out = ""
        var atWordStart = true
        for ch in text {
            let isWord = ch.isLetter || ch.isNumber || ch == "_"
            if isWord, atWordStart {
                out += String(ch).uppercased()
            } else {
                out.append(ch)
            }
            atWordStart = !isWord
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - RPCs

extension GatewayClient {

    /// `model.options` — the provider-grouped catalog. `explicitOnly` keeps
    /// ambient/auto-seeded credentials out of a chat picker (the desktop chat
    /// surfaces all pass it); `refresh` busts the backend's 1 h per-provider
    /// model cache and re-probes saved custom endpoints, so it belongs to an
    /// explicit "Refresh Models" action only — a normal open must stay snappy.
    func modelCatalog(sessionID: String? = nil, refresh: Bool = false,
                      explicitOnly: Bool = true) async throws -> ModelCatalog {
        var params: [String: JSONValue] = [:]
        if let sessionID, !sessionID.isEmpty { params["session_id"] = .string(sessionID) }
        if refresh { params["refresh"] = .bool(true) }
        if explicitOnly { params["explicit_only"] = .bool(true) }
        // A refresh re-probes every saved custom endpoint; an offline local
        // server can sit on the socket well past the default ceiling.
        return ModelCatalog(try await rpc("model.options", .object(params),
                                          timeout: refresh ? 180 : 60))
    }

    /// `model.save_key` — store an API key for an `auth_type: "api_key"`
    /// provider and get its refreshed row back. Rejects managed installs and
    /// OAuth providers server-side (those need `hermes model`).
    func saveModelProviderKey(slug: String, apiKey: String,
                              sessionID: String? = nil) async throws -> ModelProviderRow? {
        var params: [String: JSONValue] = ["slug": .string(slug), "api_key": .string(apiKey)]
        if let sessionID, !sessionID.isEmpty { params["session_id"] = .string(sessionID) }
        let result = try await rpc("model.save_key", .object(params), timeout: 120)
        return result["provider"].map(ModelProviderRow.init)
    }

    /// `model.disconnect` — clear a provider's credentials (env key, OAuth
    /// grant and every mirror). Returns the provider's display name.
    @discardableResult
    func disconnectModelProvider(slug: String) async throws -> String {
        let result = try await rpc("model.disconnect", ["slug": .string(slug)])
        return result["name"]?.stringValue ?? slug
    }

    /// `config.set key:"model"`. Three answers matter and all three are data,
    /// not errors: `deferred` (stashed mid-turn, applies at the next turn
    /// start), `confirm_required` (the expensive-model guard fired and NOTHING
    /// was applied — re-send with `confirmExpensive: true`), and a plain
    /// `warning` riding alongside a successful switch.
    ///
    /// Pass the provider whenever the picker knows it: a bare name resolves
    /// within the *current* aggregator first (model_switch.py:713-716), so
    /// switching to a self-hosted model while a subscription provider is
    /// active otherwise resolves against the wrong endpoint.
    ///
    /// `persistAsDefault` addresses the gateway process' config scope. A
    /// profile default is a different operation (`profiles.configure` with
    /// both provider and model), so Bot Mode callers keep this session-scoped
    /// and perform that profile-addressed write separately. MoA presets are
    /// always session-only.
    func applySessionModel(sessionID: String?, model: String, provider: String? = nil,
                           persistAsDefault: Bool = false,
                           confirmExpensive: Bool = false) async throws -> ModelSwitchOutcome {
        let slug = (provider ?? "").trimmingCharacters(in: .whitespaces)
        let value = Self.modelSwitchValue(model: model, provider: slug,
                                          persistAsDefault: persistAsDefault)
        var params: [String: JSONValue] = ["key": "model", "value": .string(value)]
        if let sessionID, !sessionID.isEmpty { params["session_id"] = .string(sessionID) }
        if confirmExpensive { params["confirm_expensive_model"] = .bool(true) }
        return ModelSwitchOutcome(try await rpc("config.set", .object(params), timeout: 180))
    }

    static func modelSwitchValue(model: String, provider: String,
                                 persistAsDefault: Bool) -> String {
        var parts = [model]
        if !provider.isEmpty { parts.append("--provider \(provider)") }
        parts.append(persistAsDefault ? "--global" : "--session")
        return parts.joined(separator: " ")
    }

    /// `config.set key:"reasoning"`. Returns the level the gateway settled on.
    @discardableResult
    func applyReasoningEffort(sessionID: String, value: String) async throws -> String {
        let result = try await rpc("config.set", ["session_id": .string(sessionID),
                                                  "key": "reasoning", "value": .string(value)])
        return result["value"]?.stringValue ?? value
    }

    /// `config.set key:"fast"` — the `speed=fast` service-tier pin. The handler
    /// speaks "fast"/"normal" and echoes the resulting state.
    @discardableResult
    func applyFastMode(sessionID: String, enabled: Bool) async throws -> Bool {
        let result = try await rpc("config.set", ["session_id": .string(sessionID),
                                                  "key": "fast",
                                                  "value": .string(enabled ? "fast" : "normal")])
        return (result["value"]?.stringValue ?? "") == "fast"
    }
}
