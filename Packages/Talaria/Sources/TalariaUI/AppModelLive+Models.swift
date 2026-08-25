import Foundation
import SwiftUI
import TalariaKit

// Live logic behind the model picker: the provider-grouped catalog, the model
// switch and its three non-obvious answers, the reasoning/fast controls, and
// the two stored preferences the desktop picker also keeps (which models are
// visible, and each model's remembered effort/fast).
//
// Three rules shape everything here:
//
// 1. `config.set key:"model"` does not simply succeed. Mid-turn it answers
//    `deferred: true` — the pick is stashed and applies at the NEXT turn start
//    (tui_gateway/server.py:11754) — and the expensive-model guard can answer
//    `confirm_required: true`, in which case NOTHING was applied and the same
//    call must be re-sent with `confirm_expensive_model: true`
//    (server.py:4868). A `warning` can ride along either way. All three are
//    data, and every one of them is surfaced.
// 2. Provider order comes from the backend and is never re-sorted inside a
//    group; only the groups themselves get a stable alphabetical order, so
//    switching models cannot reshuffle the list under the user's thumb.
// 3. `config.set` with no matching session falls back to gateway-global
//    config. It does not address a bot profile. A Bot Mode selection therefore
//    sends a session-scoped switch and then a provider-qualified
//    `profiles.configure` write for that bot.
// 4. A source-qualified bot owns its catalog and every session mutation. A
//    remote picker never reads from or writes through the primary gateway.

// MARK: - Per-model presets

/// A model's remembered reasoning/fast settings, re-applied whenever that model
/// is selected. Port of store/model-presets.ts — unset dimensions fall back to
/// the Hermes defaults (medium effort, no fast).
public struct ModelPreset: Codable, Sendable, Equatable {
    public var effort: String?
    public var fast: Bool?

    public init(effort: String? = nil, fast: Bool? = nil) {
        self.effort = effort; self.fast = fast
    }

    public var isEmpty: Bool { effort == nil && fast == nil }
}

/// Global, cross-session model presets keyed `provider::model`. One preference
/// for the whole app: picking a model anywhere restores the same settings.
@MainActor
@Observable
public final class ModelPresetStore {
    public static let shared = ModelPresetStore()

    private static let storageKey = "talaria.model-presets"

    public private(set) var presets: [String: ModelPreset] = [:]

    init() {
        guard let raw = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: ModelPreset].self, from: raw)
        else { return }
        presets = decoded
    }

    public static func key(provider: String, model: String) -> String { "\(provider)::\(model)" }

    public func preset(provider: String, model: String) -> ModelPreset {
        presets[Self.key(provider: provider, model: model)] ?? ModelPreset()
    }

    /// Forget every per-model preset. Used by Settings → "delete local data",
    /// which is about to remove the backing key: without dropping the in-memory
    /// copy too, the next `merge` would write the whole lot straight back.
    public func reset() {
        presets = [:]
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    /// Merge a partial preset for one model and persist.
    public func merge(provider: String, model: String, effort: String? = nil, fast: Bool? = nil) {
        let key = Self.key(provider: provider, model: model)
        var next = presets[key] ?? ModelPreset()
        if let effort { next.effort = effort }
        if let fast { next.fast = fast }
        presets[key] = next
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

// MARK: - Model visibility ("Edit Models")

/// Which models the picker shows before search. Port of
/// store/model-visibility.ts, including the hide-all sentinel: `nil` means the
/// user never customized (curated defaults apply), an empty key set for a
/// provider means they explicitly emptied it, and those two must not be
/// confused or the defaults silently come back.
@MainActor
@Observable
public final class ModelVisibilityStore {
    public static let shared = ModelVisibilityStore()

    private static let storageKey = "talaria.visible-models"

    /// Models shown per provider before the user customizes. Backend `models`
    /// are already relevance-ordered.
    public static let defaultVisiblePerProvider = 50

    /// Explicit set of visible `provider::model` keys, or nil when untouched.
    public private(set) var stored: Set<String>?

    init() {
        guard let raw = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String].self, from: raw)
        else { return }
        stored = Set(decoded)
    }

    public static func key(provider: String, model: String) -> String { "\(provider)::\(model)" }

    /// Sentinel recording "the user hid every model of this provider".
    static func sentinel(provider: String) -> String { key(provider: provider, model: "") }

    static func isSentinel(_ key: String) -> Bool { key.hasSuffix("::") }

    private func persist(_ keys: Set<String>) {
        stored = keys
        if let data = try? JSONEncoder().encode(Array(keys)) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// A provider's curated default keys: its `featured_models` shortlist when
    /// the backend ships one (aggregators serving dozens of models across many
    /// labs), else the top-N collapsed families.
    private func expandDefaults(_ provider: ModelProviderRow, into target: inout Set<String>) {
        let families = ModelLabels.collapseFamilies(provider.models)
        let featured = provider.featuredModels
        let defaults = featured.isEmpty
            ? Array(families.prefix(Self.defaultVisiblePerProvider))
            : families.filter { featured.contains($0.id) }
        for family in defaults {
            target.insert(Self.key(provider: provider.slug, model: family.id))
        }
    }

    /// The canonical working set: stored keys plus curated defaults for any
    /// provider the user never touched. Sentinels are PRESERVED — this is what
    /// the toggle handlers mutate and persist.
    func resolvedKeys(providers: [ModelProviderRow]) -> Set<String> {
        guard let stored else {
            var keys = Set<String>()
            for provider in providers { expandDefaults(provider, into: &keys) }
            return keys
        }
        if stored.isEmpty { return [] }

        var next = stored
        for provider in providers {
            let prefix = "\(provider.slug)::"
            let hasReal = stored.contains { $0.hasPrefix(prefix) && !Self.isSentinel($0) }
            let hasSentinel = stored.contains(Self.sentinel(provider: provider.slug))
            if hasReal || hasSentinel { continue }
            expandDefaults(provider, into: &next)
        }
        return next
    }

    /// What to actually render: the working set with sentinels stripped.
    public func visibleKeys(providers: [ModelProviderRow]) -> Set<String> {
        resolvedKeys(providers: providers).filter { !Self.isSentinel($0) }
    }

    public func isVisible(providers: [ModelProviderRow], provider: String, model: String) -> Bool {
        visibleKeys(providers: providers).contains(Self.key(provider: provider, model: model))
    }

    /// Flip one model row. Emptying a provider records its hide-all sentinel;
    /// re-enabling clears THAT provider's sentinel only, and restores exactly
    /// the one model — not the curated defaults.
    public func toggle(_ providers: [ModelProviderRow], provider: String, model: String) {
        var next = resolvedKeys(providers: providers)
        let key = Self.key(provider: provider, model: model)
        let sentinel = Self.sentinel(provider: provider)

        if next.contains(key) {
            next.remove(key)
            let prefix = "\(provider)::"
            let remaining = next.contains { $0.hasPrefix(prefix) && !Self.isSentinel($0) }
            if !remaining { next.insert(sentinel) }
        } else {
            next.remove(sentinel)
            next.insert(key)
        }
        persist(next)
    }

    /// Flip a provider's master switch: every collapsed family on, or all off
    /// with the sentinel recorded so the defaults are not re-expanded.
    public func setProvider(_ providers: [ModelProviderRow], provider: String, visible: Bool) {
        var next = resolvedKeys(providers: providers)
        let sentinel = Self.sentinel(provider: provider)
        let prefix = "\(provider)::"
        let families = ModelLabels.collapseFamilies(
            providers.first { $0.slug == provider }?.models ?? [])

        for key in next where key.hasPrefix(prefix) { next.remove(key) }

        if visible {
            for family in families { next.insert(Self.key(provider: provider, model: family.id)) }
            // A provider with no models can't be "all on" — leave it empty
            // rather than stranding a sentinel that reads as an explicit hide.
            if families.isEmpty { next.remove(sentinel) }
        } else {
            next.insert(sentinel)
        }
        persist(next)
    }

    /// Forget the customization entirely — back to the curated defaults.
    public func reset() {
        stored = nil
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }
}

// MARK: - Picker state

/// The expensive-model guard fired: nothing was applied, and the same switch
/// must be re-sent with `confirm_expensive_model: true` to go through.
public struct PendingModelConfirmation: Sendable, Equatable, Identifiable {
    public var id: String { "\(provider)::\(model)" }
    public var provider: String
    public var model: String
    public var message: String
}

/// What a model switch actually did.
public enum ModelSelectionResult: Sendable, Equatable {
    /// Applied now. `warning` may still carry a non-fatal caution.
    case applied(warning: String)
    /// Stashed mid-turn — it applies when the running turn settles.
    case deferred(model: String)
    /// Blocked by the expensive-model guard; nothing changed.
    case needsConfirmation(message: String)
    case failed(String)
}

/// Observable state for one bot's model picker. `AppModel`'s stored properties
/// live in a file this feature doesn't own and extensions cannot add storage,
/// so the per-bot stores hang off a MainActor side table (the LiveRuntime
/// pattern).
@MainActor
@Observable
public final class ModelPickerState {
    @ObservationIgnored var target: GatewayBotRoute?
    public var catalog: ModelCatalog = .empty
    public var isLoading = false
    /// An explicit "Refresh Models" is in flight (drives the spinner).
    public var isRefreshing = false
    /// True once a load has completed, so the empty state isn't shown first.
    public var hasLoaded = false
    /// The catalog could not be read at all. Distinct from "loaded, but this
    /// gateway has no configured providers".
    public var loadError: String?
    /// One-line note about the last action (deferred switch, warning, failure).
    public var notice: String?
    public var noticeIsWarning = false
    public var pendingConfirmation: PendingModelConfirmation?
    /// The session's `speed=fast` pin. ChatState has no home for it and this
    /// file cannot add one, so the picker owns it.
    public var fastMode = false
    /// A switch/effort write is in flight for this row key.
    public var busyRow: String?

    public func note(_ text: String, warning: Bool = false) {
        notice = text.isEmpty ? nil : text
        noticeIsWarning = warning
    }

    public func clearNotice() {
        notice = nil
        noticeIsWarning = false
    }

    func resetForDetach() {
        catalog = .empty
        isLoading = false
        isRefreshing = false
        hasLoaded = false
        loadError = nil
        notice = nil
        noticeIsWarning = false
        pendingConfirmation = nil
        fastMode = false
        busyRow = nil
    }
}

@MainActor
final class ModelPickerRuntime {
    static let shared = ModelPickerRuntime()
    var states: [String: ModelPickerState] = [:]

    func drop(gatewayID: String) {
        let keys = states.compactMap { key, state in
            state.target?.gatewayID == gatewayID ? key : nil
        }
        for key in keys {
            states[key]?.resetForDetach()
            states.removeValue(forKey: key)
        }
    }
}

// MARK: - Model API

extension AppModel {

    /// The picker store for a bot, created on first use.
    public func modelPicker(for botID: String) -> ModelPickerState {
        let runtime = ModelPickerRuntime.shared
        let target = stateRoute(for: botID)
        let key = target?.qualifiedID ?? "model-demo:\(botID)"
        if let existing = runtime.states[key] { return existing }
        let fresh = ModelPickerState()
        fresh.target = target
        runtime.states[key] = fresh
        return fresh
    }

    internal func dropModelScope(gatewayID: String) {
        ModelPickerRuntime.shared.drop(gatewayID: gatewayID)
    }

    private func modelContext(botID: String, state: ModelPickerState) async throws
        -> (route: GatewayBotRoute, client: GatewayClient)? {
        guard let route = state.target,
              stateRoute(for: botID) == route,
              ModelPickerRuntime.shared.states[route.qualifiedID] === state else {
            throw GatewayRouteError.noRoute
        }
        let client = try await routedClient(for: route)
        await attachRoutedEventsIfNeeded(client: client, gatewayID: route.gatewayID,
                                         preserveStateOnReplacement: true)
        guard stateRoute(for: botID) == route,
              ModelPickerRuntime.shared.states[route.qualifiedID] === state else { return nil }
        return (route, client)
    }

    private func modelStateIsCurrent(_ state: ModelPickerState, botID: String,
                                     route: GatewayBotRoute) -> Bool {
        stateRoute(for: botID) == route
            && ModelPickerRuntime.shared.states[route.qualifiedID] === state
    }

    /// Load (or refresh) the provider-grouped catalog for a bot's picker.
    /// `refresh` busts the backend's per-provider model cache and re-probes
    /// saved custom endpoints — the explicit "Refresh Models" action only.
    public func loadModelCatalog(botID: String, refresh: Bool = false) async {
        let state = modelPicker(for: botID)
        // One read at a time either way: two in flight would race on the
        // catalog and the second's completion would clear the first's flag.
        guard !state.isLoading, !state.isRefreshing else { return }

        let initialTarget = state.target
        if refresh { state.isRefreshing = true } else { state.isLoading = true }
        defer {
            if initialTarget == nil
                || initialTarget.map({ modelStateIsCurrent(state, botID: botID, route: $0) }) == true {
                state.isLoading = false
                state.isRefreshing = false
                state.hasLoaded = true
            }
        }

        guard mode == .live else {
            state.catalog = Self.demoCatalog(pinned: bot(botID)?.pinnedModel)
            state.loadError = nil
            return
        }

        do {
            guard let context = try await modelContext(botID: botID, state: state) else { return }
            // The picker must open without forcing a session build: with no live
            // session the owning gateway answers from disk config, which is the
            // right catalog for a chat that hasn't started yet.
            let sessionID = chats[botID]?.sessionID
            let catalog = try await context.client.modelCatalog(sessionID: sessionID,
                                                                refresh: refresh)
            guard modelStateIsCurrent(state, botID: botID, route: context.route) else { return }
            state.catalog = catalog
            state.loadError = nil
            // Keep the flat list the rest of the app reads in step.
            let ids = catalog.modelProviders.flatMap(\.models)
            if !ids.isEmpty, context.route.gatewayID == activeGatewayID { models = ids }
        } catch let error as GatewayError {
            guard state.target.map({ modelStateIsCurrent(state, botID: botID, route: $0) }) == true
            else { return }
            // A refresh failure must not blank a catalog we already have.
            if !state.catalog.hasSelectableModels { state.catalog = .empty }
            state.loadError = error.message
        } catch {
            guard state.target.map({ modelStateIsCurrent(state, botID: botID, route: $0) }) == true
            else { return }
            if !state.catalog.hasSelectableModels { state.catalog = .empty }
            state.loadError = error.localizedDescription
        }
    }

    /// Commit one collapsed family row. Mirrors the desktop `selectFamily`:
    /// a variant-fast model (no `speed` param, fast is a separate `…-fast` id)
    /// honors the remembered preset by selecting that sibling, then the model's
    /// preset is re-applied to the session.
    @discardableResult
    public func selectModelFamily(botID: String, provider: ModelProviderRow,
                                  family: ModelFamily) async -> ModelSelectionResult {
        let caps = provider.capabilities(for: family.id)
        let preset = ModelPresetStore.shared.preset(provider: provider.slug, model: family.id)
        let variantFast = !caps.fast && family.fastID != nil
        let target = (variantFast && preset.fast == true) ? (family.fastID ?? family.id) : family.id

        let result = await selectModel(botID: botID, provider: provider.slug, model: target)

        // Only a switch that actually landed (now, or stashed for the next
        // turn) gets the preset pushed onto the session. A blocked or failed
        // switch left the old model running — writing its successor's effort
        // over that would change the model the user still has.
        switch result {
        case .applied, .deferred:
            await applyPreset(botID: botID, provider: provider.slug, model: family.id,
                              effort: caps.reasoning ? (preset.effort ?? ModelLabels.defaultEffort) : nil,
                              fast: caps.fast ? (preset.fast ?? false) : nil)
        case .needsConfirmation, .failed:
            break
        }
        return result
    }

    /// Switch the session's model. Handles the gateway's three answers:
    /// `confirm_required` parks a confirmation (nothing applied), `deferred`
    /// reports that the pick lands when the running turn settles, and a plain
    /// `warning` is surfaced next to an applied switch.
    @discardableResult
    public func selectModel(botID: String, provider: String, model: String,
                            confirmExpensive: Bool = false) async -> ModelSelectionResult {
        let state = modelPicker(for: botID)
        state.clearNotice()
        state.busyRow = "\(provider)::\(model)"
        defer { state.busyRow = nil }

        guard mode == .live else {
            pinModel(botID: botID, provider: provider, model: model)
            state.pendingConfirmation = nil
            return .applied(warning: "")
        }

        let context: (route: GatewayBotRoute, client: GatewayClient)
        do {
            guard let resolved = try await modelContext(botID: botID, state: state) else {
                return .failed("the bot changed gateways while the model picker was open")
            }
            context = resolved
        } catch {
            let detail = (error as? GatewayError)?.message ?? error.localizedDescription
            state.note(detail, warning: true)
            return .failed(detail)
        }

        guard let sessionID = try? await ensureSession(botID: botID, hydrate: false) else {
            let detail = "no session — the gateway is unreachable"
            state.note(detail, warning: true)
            return .failed(detail)
        }
        guard modelStateIsCurrent(state, botID: botID, route: context.route) else {
            return .failed("the bot changed gateways while the model picker was open")
        }

        do {
            // The provider travels with the id: a bare name resolves inside
            // whatever aggregator is current, which is how a self-hosted model
            // ends up being looked for on a subscription endpoint.
            // This RPC changes the live forever-chat only.  `--global` is the
            // gateway process' config scope; it is not a profile-addressed
            // write and therefore cannot stand in for profiles.configure.
            // Keeping this session-scoped also avoids one bot changing the
            // default inherited by its siblings.
            let outcome = try await context.client.applySessionModel(
                sessionID: sessionID, model: model, provider: provider,
                persistAsDefault: false,
                confirmExpensive: confirmExpensive)
            guard modelStateIsCurrent(state, botID: botID, route: context.route) else {
                return .failed("the bot changed gateways while the model picker was open")
            }

            if outcome.confirmRequired {
                // NOTHING was applied. Park the message; the caller re-sends
                // through `confirmPendingModel` to go through.
                let message = outcome.confirmMessage.isEmpty ? outcome.warning : outcome.confirmMessage
                state.pendingConfirmation = PendingModelConfirmation(
                    provider: provider, model: model, message: message)
                return .needsConfirmation(message: message)
            }

            let resolved = outcome.value.isEmpty ? model : outcome.value
            state.pendingConfirmation = nil

            // Bot Mode has one durable profile behind every forever-chat.
            // Persist that profile with the explicit provider+model pair;
            // config.set above cannot address a profile and Hermes silently
            // drops model-only profile writes.  MoA is intentionally a
            // session preset rather than a profile model.
            var persistenceWarning = ""
            if provider.lowercased() != "moa" {
                let edit = ProfileEdit(model: resolved, provider: provider)
                do {
                    let applied = try await context.client.applyProfileEdit(
                        name: context.route.profile, edit)
                    guard edit.wasFullyApplied(applied) else {
                        throw GatewayError(code: 4065,
                                           message: "the gateway did not save the profile model")
                    }
                    guard modelStateIsCurrent(state, botID: botID, route: context.route) else {
                        return .failed("the bot changed gateways while the model picker was open")
                    }
                    await refreshProfileRoster(gatewayID: context.route.gatewayID)
                } catch {
                    persistenceWarning = "The live chat changed, but the bot profile default was not saved."
                }
            }

            pinModel(botID: botID, provider: provider, model: resolved,
                     persistedProfile: persistenceWarning.isEmpty && provider.lowercased() != "moa")

            if outcome.deferred {
                if !persistenceWarning.isEmpty {
                    state.note(persistenceWarning, warning: true)
                }
                return .deferred(model: resolved)
            }
            let warning = [outcome.warning, persistenceWarning]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return .applied(warning: warning)
        } catch let error as GatewayError {
            guard modelStateIsCurrent(state, botID: botID, route: context.route) else {
                return .failed("the bot changed gateways while the model picker was open")
            }
            state.note(error.message, warning: true)
            return .failed(error.message)
        } catch {
            guard modelStateIsCurrent(state, botID: botID, route: context.route) else {
                return .failed("the bot changed gateways while the model picker was open")
            }
            state.note(error.localizedDescription, warning: true)
            return .failed(error.localizedDescription)
        }
    }

    /// Re-send the parked switch with the expensive-model guard cleared.
    @discardableResult
    public func confirmPendingModel(botID: String) async -> ModelSelectionResult {
        let state = modelPicker(for: botID)
        guard let pending = state.pendingConfirmation else { return .failed("nothing to confirm") }
        state.pendingConfirmation = nil
        return await selectModel(botID: botID, provider: pending.provider,
                                 model: pending.model, confirmExpensive: true)
    }

    public func cancelPendingModel(botID: String) {
        modelPicker(for: botID).pendingConfirmation = nil
    }

    /// Session reasoning effort. "" inherits the profile default; "none" is
    /// thinking off (not a level on the scale).
    ///
    /// - Returns: nil when it took (including the local-only demo path), else
    ///   the gateway's own sentence. The value used to be swallowed here and
    ///   posted to the picker's note line alone, which is invisible the moment
    ///   the sheet closes — `setReasoningEffortWithFeedback` needs it to say so
    ///   anywhere durable.
    @discardableResult
    public func applyReasoningEffort(botID: String, effort: String,
                                     provider: String = "", model: String = "") async -> String? {
        let state = modelPicker(for: botID)
        let chat = chat(for: botID)
        let previous = chat.reasoningEffort
        chat.reasoningEffort = effort
        if !provider.isEmpty, !model.isEmpty {
            ModelPresetStore.shared.merge(provider: provider, model: model, effort: effort)
        }

        guard mode == .live else { return nil }
        do {
            guard let context = try await modelContext(botID: botID, state: state),
                  let sessionID = try? await ensureSession(botID: botID, hydrate: false),
                  modelStateIsCurrent(state, botID: botID, route: context.route) else {
                throw GatewayRouteError.noRoute
            }
            _ = try await context.client.applyReasoningEffort(sessionID: sessionID, value: effort)
            guard modelStateIsCurrent(state, botID: botID, route: context.route) else {
                return "the bot changed gateways while the model picker was open"
            }
            return nil
        } catch {
            chat.reasoningEffort = previous
            let reason = (error as? GatewayError)?.message ?? error.localizedDescription
            if state.target.map({ modelStateIsCurrent(state, botID: botID, route: $0) }) == true {
                state.note(reason, warning: true)
            }
            return reason
        }
    }

    /// The `speed=fast` service-tier pin, for models whose capabilities row
    /// says the backend accepts the parameter.
    public func applyFastMode(botID: String, enabled: Bool,
                              provider: String = "", model: String = "") async {
        let state = modelPicker(for: botID)
        let previous = state.fastMode
        state.fastMode = enabled
        if !provider.isEmpty, !model.isEmpty {
            ModelPresetStore.shared.merge(provider: provider, model: model, fast: enabled)
        }

        guard mode == .live else { return }
        do {
            guard let context = try await modelContext(botID: botID, state: state),
                  let sessionID = try? await ensureSession(botID: botID, hydrate: false),
                  modelStateIsCurrent(state, botID: botID, route: context.route) else {
                throw GatewayRouteError.noRoute
            }
            let applied = try await context.client.applyFastMode(sessionID: sessionID,
                                                                  enabled: enabled)
            guard modelStateIsCurrent(state, botID: botID, route: context.route) else { return }
            state.fastMode = applied
        } catch {
            guard state.target.map({ modelStateIsCurrent(state, botID: botID, route: $0) }) == true
            else { return }
            state.fastMode = previous
            state.note((error as? GatewayError)?.message ?? error.localizedDescription,
                       warning: true)
        }
    }

    /// Model ids offered by the gateway, flattened. Supersedes the old flat
    /// `availableModels()` that used to live in AppModelLive.swift: the typed
    /// catalog is the source now, and this stays only as the narrow accessor
    /// the profile editor's fallback path wants. `DemoData.models` is the
    /// documented "no real catalog" sentinel — `modelChoices()` tests for it.
    public func availableModels() async -> [String] {
        guard mode == .live, let client else { return DemoData.models }
        guard let catalog = try? await client.modelCatalog(
            sessionID: chats.values.first(where: { $0.sessionID != nil })?.sessionID)
        else { return DemoData.models }

        var ids: [String] = []
        var seen = Set<String>()
        func add(_ id: String) {
            guard !id.isEmpty, seen.insert(id).inserted else { return }
            ids.append(id)
        }
        // The active model first so a picker opens on the current pin.
        add(catalog.model)
        for provider in catalog.modelProviders {
            for id in provider.models { add(id) }
        }
        return ids.isEmpty ? DemoData.models : ids
    }

    // MARK: - Internals

    /// Push a model's remembered settings onto the session after a switch.
    /// Batched here (not treated as user edits) so one selection is one write
    /// per dimension, and `nil` means "this model doesn't offer it".
    private func applyPreset(botID: String, provider: String, model: String,
                             effort: String?, fast: Bool?) async {
        if let effort {
            ModelPresetStore.shared.merge(provider: provider, model: model, effort: effort)
            await applyReasoningEffort(botID: botID, effort: effort)
        }
        if let fast {
            ModelPresetStore.shared.merge(provider: provider, model: model, fast: fast)
            await applyFastMode(botID: botID, enabled: fast)
        }
    }

    /// Record the selection locally: the bot's pin and the picker's own idea of
    /// the current pair, so the checkmark moves before the next catalog read.
    private func pinModel(botID: String, provider: String, model: String,
                          persistedProfile: Bool = true) {
        if persistedProfile, let idx = bots.firstIndex(where: { $0.id == botID }) {
            bots[idx].pinnedModel = model
        }
        let state = modelPicker(for: botID)
        state.catalog.model = model
        state.catalog.provider = provider
        // A `…-fast` variant IS fast mode, expressed as a separate model id.
        if ModelLabels.baseID(model).lowercased().hasSuffix("-fast") { state.fastMode = true }
    }

    /// The demo world's catalog: one honest provider row so the picker's
    /// grouping, search and labels all render without a gateway.
    static func demoCatalog(pinned: String?) -> ModelCatalog {
        let row = ModelProviderRow(
            slug: "demo",
            name: "Demo Gateway",
            isCurrent: true,
            models: DemoData.models,
            source: "demo",
            authenticated: true,
            capabilities: Dictionary(uniqueKeysWithValues: DemoData.models.map {
                ($0, ModelOptionCapabilities(fast: false, reasoning: true))
            }))
        return ModelCatalog(providers: [row],
                            model: pinned ?? DemoData.models.first ?? "",
                            provider: "demo")
    }
}
