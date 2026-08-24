import SwiftUI
import TalariaKit
import TalariaTheme

// Settings → Models & providers.
//
// Desktop splits this across two pages (Settings → Model and Settings →
// Providers, apps/desktop/src/app/settings/model-settings.tsx and
// providers-settings.tsx). On a phone they are one thing, because the only
// reason you open either from a phone is that something broke: the default
// model is wrong, or a key expired and every bot is dead. PARITY.md:563 calls
// the inline "paste key → working again" path "the single fastest path from
// 'provider dead' to 'working' on desktop"; that is the spine of this section.
//
// Two rules the code follows and the copy states out loud:
//
// 1. GATEWAY SCOPE. Everything here writes the gateway's `config.yaml`
//    default, not one chat's override — that is what "default model" has to
//    mean, and it is why the writes live in GatewayClient+Providers.swift
//    rather than reusing the session-scoped calls in GatewayClient+Models.swift.
//    A live conversation keeps whatever its own picker chose; this only
//    decides where the NEXT one starts.
// 2. THE KEY LEAVES, IT DOES NOT LAND. `model.save_key` hands the key to the
//    gateway, which writes it into `~/.hermes/.env` on THAT machine
//    (tui_gateway/methods_complete.py:492 → save_provider_env_credential).
//    Talaria never puts an inference key in the Keychain or UserDefaults — the
//    Keychain here holds gateway credentials only — and the UI says so above
//    the field rather than leaving the user to assume.
//
// The catalog is not re-parsed here: `model.options` is decoded once, in
// GatewayClient+Models.swift, and the family collapsing / labels / visible
// shortlist come from `ModelLabels` and `ModelVisibilityStore`, so a model
// reads identically in Settings and in the chat picker.
//
// Auxiliary/vision and MoA editing remain a separate mobile slice, but they are
// not wire-blocked: current Hermes exposes profile-scoped /api/model/auxiliary,
// /api/model/set and /api/model/moa. GatewayClient+Models.swift owns the bounded
// transport foundation. This screen must say "not editable here yet", never the
// obsolete and materially false "no gateway API" claim. Custom endpoints are
// already managed in Providers.

struct GatewaySettingsTargetFence {
    static func resolve(selected: String?, available: Set<String>,
                        active: String?, runtime: String?) -> String? {
        let validSelection = selected.flatMap { available.contains($0) ? $0 : nil }
        return validSelection ?? active ?? runtime
    }

    static func accepts(stateGatewayID: String?, targetGatewayID: String?,
                        generation: Int, currentGeneration: Int) -> Bool {
        stateGatewayID == targetGatewayID && generation == currentGeneration
    }
}

public struct ModelSettingsSection: View {
    private let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    @State private var selectedGatewayID: String?
    @State private var stateGatewayID: String?
    @State private var loadGeneration = 0

    // Catalog + gateway defaults
    @State private var catalog: ModelCatalog = .empty
    @State private var effort: String = ModelLabels.defaultEffort
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var loadError: String?

    // Feedback from the last write
    @State private var notice: String?
    @State private var noticeIsWarning = false
    @State private var pendingConfirm: PendingModelConfirmation?

    // Model list
    @State private var isPicking = false
    @State private var query = ""
    @State private var busyModel: String?

    // Providers
    @State private var keyTarget: String?
    @State private var keyDraft = ""
    @State private var busyProvider: String?
    @State private var disconnectTarget: ModelProviderRow?

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if gatewayChoices.count > 1 {
                gatewaySection
            }
            modelSection
            effortSection
            providerSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: targetGatewayID) {
            prepareForGateway(targetGatewayID)
            await load(gatewayID: targetGatewayID)
        }
        .confirmationDialog(disconnectTarget?.name ?? "",
                            isPresented: Binding(get: { disconnectTarget != nil },
                                                 set: { if !$0 { disconnectTarget = nil } }),
                            titleVisibility: .visible) {
            if let target = disconnectTarget {
                Button(copy.settingsDisconnectConfirm(theme.id), role: .destructive) {
                    Task { await disconnect(target) }
                }
                Button(copy.cancel, role: .cancel) { disconnectTarget = nil }
            }
        } message: {
            Text(copy.settingsDisconnectNote(theme.id))
        }
    }

    private var gatewayChoices: [SavedGateway] {
        model.mode == .live ? ConnectionRegistry.shared.saved : []
    }

    private var targetGatewayID: String? {
        GatewaySettingsTargetFence.resolve(selected: selectedGatewayID,
                                         available: Set(gatewayChoices.map(\.id)),
                                         active: model.activeGatewayID,
                                         runtime: LiveRuntime.shared.gatewayID)
    }

    private var gatewaySection: some View {
        SettingsSection(theme: theme,
                        title: copy.settingsModelGateway(theme.id),
                        footnote: copy.settingsModelGatewayNote(theme.id)) {
            SettingsGroup(theme: theme) {
                Picker(copy.settingsModelGateway(theme.id), selection: Binding(
                    get: { targetGatewayID },
                    set: { selectedGatewayID = $0 })) {
                    ForEach(gatewayChoices) { gateway in
                        Text(gateway.name + (gateway.id == model.activeGatewayID
                                             ? copy.settingsModelGatewayActive(theme.id) : ""))
                            .tag(Optional(gateway.id))
                    }
                }
                .pickerStyle(.menu)
                .tint(theme.accent)
                .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            }
        }
    }

    // MARK: - Default model

    private var currentProviderRow: ModelProviderRow? { catalog.row(owning: catalog.provider) }

    private var currentSubtitle: String {
        guard !catalog.model.isEmpty else { return copy.settingsGatewayDefaultsLabel(theme.id) }
        let provider = currentProviderRow?.name ?? catalog.provider
        return provider.isEmpty ? catalog.model : "\(provider) · \(catalog.model)"
    }

    private var modelSection: some View {
        SettingsSection(theme: theme, title: copy.settingsModelSection(theme.id),
                        footnote: copy.settingsDefaultModelNote(theme.id)) {
            SettingsGroup(theme: theme) {
                SettingsRow(theme: theme,
                            title: catalog.model.isEmpty
                                ? copy.settingsNoDefaultModel(theme.id)
                                : ModelLabels.displayName(catalog.model),
                            subtitle: currentSubtitle,
                            value: isLoading && !hasLoaded ? copy.settingsLoading(theme.id) : nil,
                            showsChevron: true,
                            isLast: true) {
                    withAnimation(.easeInOut(duration: 0.18)) { isPicking.toggle() }
                }
            }

            if let loadError {
                noticeLine(loadError, warning: true)
            }
            if let pendingConfirm {
                confirmBanner(pendingConfirm)
            }
            if let notice {
                noticeLine(notice, warning: noticeIsWarning)
            }
            if isPicking {
                modelPicker

                // Desktop's "Refresh Models" (model-catalog-menu.tsx footer).
                // It busts the gateway's 1 h per-provider model cache and
                // re-probes saved custom endpoints, so it stays an explicit
                // action — a normal open has to be snappy.
                if model.mode == .live {
                    SettingsGroup(theme: theme) {
                        SettingsActionRow(theme: theme,
                                          title: copy.settingsRefreshModels(theme.id),
                                          subtitle: copy.settingsRefreshModelsSub(theme.id),
                                          isBusy: isLoading, isLast: true) {
                            Task { await load(refresh: true) }
                        }
                    }
                }
            }
        }
    }

    private func noticeLine(_ text: String, warning: Bool) -> some View {
        Text(text)
            .font(theme.mono(10.5))
            .foregroundStyle(warning ? theme.warn : theme.sub)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }

    // MARK: - Model picker

    private struct PickerGroup: Identifiable {
        var id: String { provider.slug }
        var provider: ModelProviderRow
        var families: [ModelFamily]
    }

    /// Collapsed, this shows the same curated shortlist the chat picker opens
    /// on, so the two surfaces agree. Typing spans every model of every
    /// provider, because the reason you came to Settings may well be a model
    /// the shortlist hides.
    private var pickerGroups: [PickerGroup] {
        let q = ModelLabels.normalize(query)
        let providers = catalog.modelProviders
        let visible = ModelVisibilityStore.shared.visibleKeys(providers: providers)

        var out: [PickerGroup] = []
        for provider in providers {
            let kept = ModelLabels.collapseFamilies(provider.models).filter { family in
                guard !q.isEmpty else {
                    return visible.contains(ModelVisibilityStore.key(provider: provider.slug,
                                                                     model: family.id))
                        || family.id == catalog.model
                }
                let haystack = [ModelLabels.searchText(family.id), family.fastID ?? "",
                                provider.name, provider.slug,
                                ModelLabels.displayName(family.id)]
                    .joined(separator: " ").lowercased()
                return haystack.contains(q)
            }
            if !kept.isEmpty { out.append(PickerGroup(provider: provider, families: kept)) }
        }
        // Groups get a stable alphabetical order; the models INSIDE a group
        // keep the backend's curated order, exactly as the chat picker does.
        return out.sorted {
            $0.provider.name.localizedCaseInsensitiveCompare($1.provider.name) == .orderedAscending
        }
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("", text: $query,
                      prompt: Text(copy.modelsSearchPlaceholder(theme.id))
                        .foregroundStyle(theme.faint))
                .textFieldStyle(.plain)
                .font(theme.body(13))
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .padding(.horizontal, 13)
                .frame(height: 40)
                .background(theme.panel, in: inputShape)
                .overlay(inputShape.strokeBorder(
                    theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))

            if pickerGroups.isEmpty {
                Text(hasLoaded ? copy.settingsNoModels(theme.id) : copy.modelsLoading(theme.id))
                    .font(theme.body(12))
                    .foregroundStyle(theme.faint)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 2)
            }

            ForEach(pickerGroups) { group in
                Text("\(group.provider.name) · \(group.provider.totalModels)")
                    .font(theme.mono(9, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(theme.faint)
                    .padding(.top, 6)
                    .padding(.horizontal, 2)

                SettingsGroup(theme: theme) {
                    ForEach(Array(group.families.enumerated()), id: \.element.id) { index, family in
                        modelRow(family, in: group.provider,
                                 isLast: index == group.families.count - 1)
                    }
                }
            }
        }
    }

    private var inputShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.inputRadius, style: .continuous)
    }

    private func modelRow(_ family: ModelFamily, in provider: ModelProviderRow,
                          isLast: Bool) -> some View {
        let isCurrent = provider.owns(provider: catalog.provider)
            && (catalog.model == family.id || catalog.model == family.fastID)
        let parts = ModelLabels.displayParts(family.id)
        // A model the account may not select is shown, disabled, rather than
        // hidden — "why can't I pick Opus" is a question the row answers.
        let locked = provider.unavailableModels.contains(family.id)
        let price = provider.pricing[family.id]
        let busy = busyModel == family.id

        return Button {
            guard !locked else { return }
            Task { await selectDefault(family.id, provider: provider.slug) }
        } label: {
            HStack(spacing: 8) {
                Text(parts.name)
                    .font(SettingsType.rowTitle(theme))
                    .foregroundStyle(locked ? theme.faint : theme.ink)
                    .lineLimit(1)
                if !parts.tag.isEmpty {
                    Text(parts.tag)
                        .font(theme.mono(9, weight: .semibold))
                        .foregroundStyle(theme.faint)
                }
                Spacer(minLength: 6)
                if let price, !price.isEmpty {
                    Text(price.compact)
                        .font(theme.mono(9))
                        .foregroundStyle(price.free ? theme.ok : theme.faint)
                        .monospacedDigit()
                }
                if locked {
                    Text(copy.modelsProBadge(theme.id))
                        .font(theme.mono(8.5, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(theme.faint)
                }
                if busy {
                    ProgressView().controlSize(.small).tint(theme.accent)
                } else if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked || busyModel != nil)
        .opacity(locked ? 0.45 : 1)
        .modifier(SettingsRowChrome(theme: theme, isLast: isLast))
    }

    // MARK: - Reasoning effort

    /// The level a new chat inherits. `none` is thinking off — not a point on
    /// the scale — which is the same split the chat picker draws.
    private var effortSection: some View {
        SettingsSection(theme: theme, title: copy.settingsEffortSection(theme.id),
                        footnote: copy.settingsEffortNote(theme.id)) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 7)],
                      alignment: .leading, spacing: 7) {
                effortChip("none")
                ForEach(ModelLabels.reasoningEfforts, id: \.self) { effortChip($0) }
            }
        }
    }

    private func effortChip(_ value: String) -> some View {
        let on = value == "none" ? !ModelLabels.isThinkingEnabled(effort)
                                 : (ModelLabels.isThinkingEnabled(effort)
                                    && ModelLabels.resolveEffort(effort) == value)
        let shape = RoundedRectangle(cornerRadius: theme.chipIsCapsule ? 999 : theme.buttonRadius)
        return Button {
            Task { await selectEffort(value) }
        } label: {
            Text(ModelLabels.effortLabel(value))
                .font(theme.mono(10.5, weight: .semibold))
                .foregroundStyle(on ? theme.accentFg : theme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(on ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.inset), in: shape)
                .overlay { if !on { shape.strokeBorder(theme.line, lineWidth: 1) } }
        }
        .buttonStyle(.plain)
        .disabled(model.mode != .live)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    // MARK: - Providers

    /// Connected first, then the rest — desktop's own grouping
    /// (app/settings/providers-settings.tsx:126-292). With
    /// `include_unconfigured` the tail can be thirty rows of providers nobody
    /// has ever touched, and burying the two that are live inside them is the
    /// difference between a settings page and a directory.
    private var connectedProviders: [ModelProviderRow] {
        catalog.modelProviders.filter(\.authenticated)
    }

    private var otherProviders: [ModelProviderRow] {
        catalog.modelProviders.filter { !$0.authenticated }
    }

    private var providerSection: some View {
        SettingsSection(theme: theme, title: copy.settingsProvidersSection(theme.id),
                        footnote: copy.settingsAuxNote(theme.id)) {
            if catalog.modelProviders.isEmpty {
                Text(hasLoaded ? copy.settingsNoProviders(theme.id) : copy.modelsLoading(theme.id))
                    .font(theme.body(12))
                    .foregroundStyle(theme.faint)
                    .padding(.horizontal, 2)
            }
            if !connectedProviders.isEmpty {
                providerGroup(connectedProviders)
            }
            if !otherProviders.isEmpty {
                if !connectedProviders.isEmpty {
                    Text(copy.settingsOtherProviders(theme.id))
                        .font(theme.mono(9, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(theme.faint)
                        .padding(.top, 6)
                        .padding(.horizontal, 2)
                }
                providerGroup(otherProviders)
            }
        }
    }

    private func providerGroup(_ providers: [ModelProviderRow]) -> some View {
        SettingsGroup(theme: theme) {
            ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                providerRow(provider, isLast: index == providers.count - 1)
            }
        }
    }

    private func providerRow(_ provider: ModelProviderRow, isLast: Bool) -> some View {
        // `auth_type` decides which door a provider even has: only "api_key"
        // rows accept a pasted key — `model.save_key` answers 4003 for OAuth
        // providers (methods_complete.py:507-513). OAuth is managed by the
        // typed, profile-scoped Provider accounts section below, so this row
        // points there instead of offering a field the gateway would refuse.
        let acceptsKey = provider.authType == "api_key"
        let isEditing = keyTarget == provider.slug
        let busy = busyProvider == provider.slug

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.name)
                            .font(SettingsType.rowTitle(theme))
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                        if provider.isCurrent {
                            Text(copy.settingsProviderInUse(theme.id))
                                .font(theme.mono(8, weight: .bold))
                                .tracking(1)
                                .foregroundStyle(theme.accent)
                        }
                    }
                    Text(providerDetail(provider))
                        .font(SettingsType.rowValue(theme))
                        .foregroundStyle(theme.faint)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if busy {
                    ProgressView().controlSize(.small).tint(theme.accent)
                } else {
                    stateTag(for: provider)
                }
            }

            // A row-level caution from the backend (a re-auth hint, the MoA
            // explainer) is the provider's own words — never paraphrased.
            if !provider.warning.isEmpty {
                Text(provider.warning)
                    .font(theme.mono(9.5))
                    .foregroundStyle(theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isEditing {
                keyEditor(provider)
            } else {
                providerActions(provider, acceptsKey: acceptsKey, busy: busy)
            }
        }
        .modifier(SettingsRowChrome(theme: theme, isLast: isLast))
    }

    private func providerActions(_ provider: ModelProviderRow,
                                 acceptsKey: Bool, busy: Bool) -> some View {
        HStack(spacing: 8) {
            if acceptsKey {
                smallButton(provider.authenticated ? copy.settingsReplaceKey(theme.id)
                                                   : copy.settingsConnect(theme.id),
                            tone: theme.accent, disabled: busy || model.mode != .live) {
                    keyDraft = ""
                    keyTarget = provider.slug
                }
            }
            if provider.authenticated {
                smallButton(copy.settingsDisconnect(theme.id), tone: theme.danger,
                            disabled: busy || model.mode != .live) {
                    disconnectTarget = provider
                }
            }
            if !acceptsKey && !provider.authenticated {
                Text(copy.settingsOAuthProvider(theme.id))
                    .font(SettingsType.rowSubtitle(theme))
                    .foregroundStyle(theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func smallButton(_ title: String, tone: Color, disabled: Bool,
                             action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.buttonRadius)
        return Button(action: action) {
            Text(title)
                .font(theme.mono(10.5, weight: .bold))
                .foregroundStyle(tone)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(theme.inset, in: shape)
                .overlay(shape.strokeBorder(tone.opacity(0.4), lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    private func providerDetail(_ provider: ModelProviderRow) -> String {
        var parts: [String] = [provider.slug]
        if provider.totalModels > 0 { parts.append("\(provider.totalModels) models") }
        if !provider.keyEnv.isEmpty { parts.append(provider.keyEnv) }
        return parts.joined(separator: " · ")
    }

    private func stateTag(for provider: ModelProviderRow) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(provider.authenticated ? theme.ok : theme.faint)
                .frame(width: 6, height: 6)
            Text(provider.authenticated ? copy.settingsConnected(theme.id)
                                        : copy.settingsNotConnected(theme.id))
                .font(theme.mono(9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(provider.authenticated ? theme.ok : theme.faint)
        }
    }

    /// The paste-a-key field. The sentence above it is the point of the whole
    /// control: the key travels to the gateway and is written into that host's
    /// `~/.hermes/.env`, and never touches this device's storage.
    private func keyEditor(_ provider: ModelProviderRow) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(copy.settingsKeyDestination(theme.id, env: provider.keyEnv))
                .font(SettingsType.rowSubtitle(theme))
                .foregroundStyle(theme.sub)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("", text: $keyDraft,
                        prompt: Text(copy.settingsKeyPlaceholder(theme.id))
                            .foregroundStyle(theme.faint))
                .textFieldStyle(.plain)
                .font(theme.mono(12))
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .padding(.horizontal, 13)
                .frame(height: 40)
                .background(theme.panel, in: inputShape)
                .overlay(inputShape.strokeBorder(
                    theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))

            HStack(spacing: 8) {
                Button {
                    Task { await saveKey(for: provider) }
                } label: {
                    Text(copy.settingsSaveKey(theme.id))
                        .font(theme.mono(10.5, weight: .bold))
                        .foregroundStyle(theme.accentFg)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(theme.accent,
                                    in: RoundedRectangle(cornerRadius: theme.buttonRadius))
                }
                .buttonStyle(.plain)
                .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || busyProvider != nil)

                smallButton(copy.cancel, tone: theme.ink, disabled: busyProvider != nil) {
                    keyTarget = nil
                    keyDraft = ""
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Expensive-model confirmation

    /// `confirm_required` means NOTHING was applied — the same switch has to be
    /// re-sent with the guard cleared (tui_gateway/server.py:4866).
    private func confirmBanner(_ pending: PendingModelConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(copy.modelsConfirmTitle(theme.id))
                .font(theme.mono(9.5, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(theme.warn)
            Text(pending.message.isEmpty
                 ? copy.modelsConfirmFallback(theme.id, model: pending.model)
                 : pending.message)
                .font(theme.body(12.5))
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    Task { await selectDefault(pending.model, provider: pending.provider,
                                               confirmExpensive: true) }
                } label: {
                    Text(copy.modelsConfirmGo(theme.id))
                        .font(theme.mono(10.5, weight: .bold))
                        .foregroundStyle(theme.accentFg)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(theme.accent,
                                    in: RoundedRectangle(cornerRadius: theme.buttonRadius))
                }
                .buttonStyle(.plain)
                smallButton(copy.cancel, tone: theme.ink, disabled: false) {
                    pendingConfirm = nil
                }
                Spacer(minLength: 0)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.warn.opacity(0.09),
                    in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
            .strokeBorder(theme.warn.opacity(0.45), lineWidth: 1))
    }

    // MARK: - Actions

    private func prepareForGateway(_ gatewayID: String?) {
        guard stateGatewayID != gatewayID else { return }
        loadGeneration &+= 1
        stateGatewayID = gatewayID
        catalog = .empty
        effort = ModelLabels.defaultEffort
        isLoading = false
        hasLoaded = false
        loadError = nil
        notice = nil
        pendingConfirm = nil
        isPicking = false
        query = ""
        busyModel = nil
        keyTarget = nil
        keyDraft = ""
        busyProvider = nil
        disconnectTarget = nil
    }

    private func gatewayClient(for gatewayID: String?) async throws -> GatewayClient {
        if let gatewayID { return try await model.routedClient(gatewayID: gatewayID) }
        if let client = model.client { return client }
        throw AppModel.GatewayRouteError.noRoute
    }

    private func isCurrent(_ gatewayID: String?, generation: Int) -> Bool {
        targetGatewayID == gatewayID && GatewaySettingsTargetFence.accepts(
            stateGatewayID: stateGatewayID, targetGatewayID: gatewayID,
            generation: generation, currentGeneration: loadGeneration)
    }

    private func load(refresh: Bool = false, gatewayID: String? = nil) async {
        let gatewayID = gatewayID ?? targetGatewayID
        guard stateGatewayID == gatewayID, !isLoading else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if isCurrent(gatewayID, generation: generation) {
                isLoading = false
                hasLoaded = true
            }
        }

        guard model.mode == .live else {
            catalog = AppModel.demoCatalog(pinned: nil)
            effort = ModelLabels.defaultEffort
            loadError = nil
            return
        }

        do {
            let client = try await gatewayClient(for: gatewayID)
            let loaded = try await client.defaultModelCatalog(refresh: refresh)
            guard isCurrent(gatewayID, generation: generation) else { return }
            catalog = loaded
            loadError = nil
            // A gateway too old for `config.get key:"reasoning"` leaves the
            // scale on its built-in default rather than blanking the row.
            if let value = try? await client.defaultReasoningEffort(), !value.isEmpty,
               isCurrent(gatewayID, generation: generation) {
                effort = value
            }
        } catch let error as GatewayError {
            guard isCurrent(gatewayID, generation: generation) else { return }
            // A failed refresh must not blank a catalog we already have.
            if !catalog.hasSelectableModels { catalog = .empty }
            loadError = error.message
        } catch {
            guard isCurrent(gatewayID, generation: generation) else { return }
            if !catalog.hasSelectableModels { catalog = .empty }
            loadError = error.localizedDescription
        }
    }

    private func selectDefault(_ modelID: String, provider: String? = nil,
                               confirmExpensive: Bool = false) async {
        guard stateGatewayID == targetGatewayID else { return }
        let gatewayID = stateGatewayID
        let generation = loadGeneration
        notice = nil
        pendingConfirm = nil
        busyModel = modelID
        defer {
            if isCurrent(gatewayID, generation: generation) { busyModel = nil }
        }

        guard model.mode == .live else {
            catalog.model = modelID
            note(copy.settingsDemoWrite(theme.id), warning: false)
            return
        }

        do {
            let client = try await gatewayClient(for: gatewayID)
            let outcome = try await client.applyDefaultModel(modelID, provider: provider,
                                                             confirmExpensive: confirmExpensive)
            guard isCurrent(gatewayID, generation: generation) else { return }
            if outcome.confirmRequired {
                let message = outcome.confirmMessage.isEmpty ? outcome.warning
                                                             : outcome.confirmMessage
                pendingConfirm = PendingModelConfirmation(provider: catalog.provider,
                                                          model: modelID, message: message)
                return
            }
            let resolved = outcome.value.isEmpty ? modelID : outcome.value
            // Move the checkmark now, then reconcile. A switch can cross
            // providers, and `switch_model` decides which one actually serves
            // the id — guessing it locally would label the model under the
            // wrong house, so the gateway is asked rather than second-guessed.
            catalog.model = resolved
            isPicking = false
            query = ""
            busyModel = nil
            await load(gatewayID: gatewayID)
            guard targetGatewayID == gatewayID else { return }

            // `scope` is the gateway's own word for where the write landed;
            // anything but "global" means the saved default did NOT change, and
            // saying so beats a checkmark that lies. A `warning` can ride along
            // either way, so both go into one line rather than the second
            // silently replacing the first.
            let saved = outcome.scope == "global"
            var lines = [saved
                ? copy.settingsModelSaved(theme.id, model: ModelLabels.displayName(resolved))
                : copy.settingsModelNotGlobal(theme.id, scope: outcome.scope)]
            if !outcome.warning.isEmpty { lines.append(outcome.warning) }
            note(lines.joined(separator: "\n"), warning: !saved || !outcome.warning.isEmpty)
        } catch let error as GatewayError {
            guard isCurrent(gatewayID, generation: generation) else { return }
            note(error.message, warning: true)
        } catch {
            guard isCurrent(gatewayID, generation: generation) else { return }
            note(error.localizedDescription, warning: true)
        }
    }

    private func selectEffort(_ value: String) async {
        guard model.mode == .live else { return }
        guard stateGatewayID == targetGatewayID else { return }
        let gatewayID = stateGatewayID
        let generation = loadGeneration
        let previous = effort
        effort = value
        do {
            let client = try await gatewayClient(for: gatewayID)
            let resolved = try await client.applyDefaultReasoningEffort(value)
            guard isCurrent(gatewayID, generation: generation) else { return }
            effort = resolved
        } catch let error as GatewayError {
            guard isCurrent(gatewayID, generation: generation) else { return }
            effort = previous
            note(error.message, warning: true)
        } catch {
            guard isCurrent(gatewayID, generation: generation) else { return }
            effort = previous
            note(error.localizedDescription, warning: true)
        }
    }

    private func saveKey(for provider: ModelProviderRow) async {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard model.mode == .live else {
            keyDraft = ""
            keyTarget = nil
            note(copy.settingsDemoWrite(theme.id), warning: false)
            return
        }
        guard stateGatewayID == targetGatewayID else { return }
        let gatewayID = stateGatewayID
        let generation = loadGeneration
        // A provider secret leaves view state before the first suspension. A
        // gateway switch, timeout, or cancellation cannot strand it in memory.
        keyDraft = ""
        keyTarget = nil
        busyProvider = provider.slug
        notice = nil
        defer {
            if isCurrent(gatewayID, generation: generation) { busyProvider = nil }
        }

        do {
            let client = try await gatewayClient(for: gatewayID)
            // The row `model.save_key` hands back is built with narrower flags
            // than the picker's (no pricing / capabilities / featured), so it is
            // used as proof the key took, not as a replacement row — splicing it
            // in would quietly strip this provider's price tags and capability
            // gating. A plain re-read costs one cached call and comes back whole.
            _ = try await client.saveModelProviderKey(slug: provider.slug, apiKey: key)
            // The draft is cleared on every exit path, success or not: a live
            // API key has no business sitting in view state.
            guard isCurrent(gatewayID, generation: generation) else { return }
            busyProvider = nil
            await load(gatewayID: gatewayID)
            guard targetGatewayID == gatewayID else { return }
            note(copy.settingsKeySaved(theme.id, provider: provider.name), warning: false)
        } catch let error as GatewayError {
            guard isCurrent(gatewayID, generation: generation) else { return }
            // 4006 managed install, 4003 wrong auth type, 4002 unknown
            // provider — upstream writes those as sentences meant for the
            // user, so passing them through beats paraphrasing them wrong.
            note(error.message, warning: true)
        } catch {
            guard isCurrent(gatewayID, generation: generation) else { return }
            note(error.localizedDescription, warning: true)
        }
    }

    private func disconnect(_ provider: ModelProviderRow) async {
        disconnectTarget = nil
        guard model.mode == .live else { return }
        guard stateGatewayID == targetGatewayID else { return }
        let gatewayID = stateGatewayID
        let generation = loadGeneration
        busyProvider = provider.slug
        notice = nil
        defer {
            if isCurrent(gatewayID, generation: generation) { busyProvider = nil }
        }
        do {
            let client = try await gatewayClient(for: gatewayID)
            let name = try await client.disconnectModelProvider(slug: provider.slug)
            guard isCurrent(gatewayID, generation: generation) else { return }
            // A plain read, not `refresh`: only the per-provider MODEL LIST is
            // cached, and it is the credential state that just changed — a
            // refresh would re-probe every saved custom endpoint for nothing.
            busyProvider = nil
            await load(gatewayID: gatewayID)
            guard targetGatewayID == gatewayID else { return }
            note(copy.settingsDisconnected(theme.id, provider: name), warning: false)
        } catch let error as GatewayError {
            guard isCurrent(gatewayID, generation: generation) else { return }
            note(error.message, warning: true)
        } catch {
            guard isCurrent(gatewayID, generation: generation) else { return }
            note(error.localizedDescription, warning: true)
        }
    }

    private func note(_ text: String, warning: Bool) {
        notice = text.isEmpty ? nil : text
        noticeIsWarning = warning
    }
}

// MARK: - Themed copy

/// Voice for the models & providers section. Anything the GATEWAY said (a
/// provider warning, an RPC error, a confirm message) passes through verbatim —
/// only Talaria's own sentences are themed.
public extension CopyPack {

    func settingsModelGateway(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Gateway"
        case .control: "MODEL SOURCE"
        case .ink: "THE HOUSE WHOSE HANDS THESE ARE"
        }
    }

    func settingsModelGatewayNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Default models and provider credentials belong to one gateway. Choose the machine you mean to change."
        case .control: "MODEL DEFAULTS + PROVIDER KEYS ARE GATEWAY-LOCAL. SELECT AN EXPLICIT TARGET."
        case .ink: "Each house keeps its own hands and secret names; choose the house before changing either."
        }
    }

    func settingsModelGatewayActive(_ t: ThemeID) -> String {
        switch t {
        case .soft: " · active"
        case .control: " [ACTIVE]"
        case .ink: " · present"
        }
    }

    func settingsModelSection(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Default model"
        case .control: "DEFAULT MODEL"
        case .ink: "the standing hand"
        }
    }

    func settingsProvidersSection(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Providers"
        case .control: "PROVIDERS"
        case .ink: "the houses"
        }
    }

    func settingsEffortSection(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Default thinking"
        case .control: "DEFAULT REASONING"
        case .ink: "depth of thought"
        }
    }

    func settingsDefaultModelNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Where a new chat starts. A conversation you’ve already switched keeps its own model."
        case .control: "APPLIES TO NEW SESSIONS. EXISTING SESSION OVERRIDES ARE UNTOUCHED."
        case .ink: "Whichever hand takes up work not yet begun. Work already under way keeps the hand it has."
        }
    }

    func settingsEffortNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Saved on the gateway as the starting level for new chats. Off means no thinking at all."
        case .control: "WRITES agent.reasoning_effort. OFF = THINKING DISABLED, NOT A LEVEL."
        case .ink: "Set down in the gateway’s own book. Off is silence, not a lesser degree."
        }
    }

    func settingsGatewayDefaultsLabel(_ t: ThemeID) -> String {
        switch t {
        case .soft: "gateway default"
        case .control: "GATEWAY DEFAULT"
        case .ink: "the house standard"
        }
    }

    func settingsNoDefaultModel(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No default set"
        case .control: "NO DEFAULT MODEL"
        case .ink: "no hand stands ready"
        }
    }

    func settingsLoading(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Loading…"
        case .control: "READING…"
        case .ink: "reading…"
        }
    }

    func settingsRefreshModels(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Refresh models"
        case .control: "REFRESH MODELS"
        case .ink: "call the roll again"
        }
    }

    func settingsRefreshModelsSub(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Re-fetches every provider’s catalogue instead of using the gateway’s hourly cache."
        case .control: "model.options refresh=true — BUSTS THE 1h CACHE, RE-PROBES CUSTOM ENDPOINTS."
        case .ink: "Ask each house afresh who it has, rather than trusting the hour-old list."
        }
    }

    func settingsNoModels(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No models match."
        case .control: "NO MATCHES."
        case .ink: "No hand answers to that name."
        }
    }

    func settingsNoProviders(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This gateway has no inference providers configured."
        case .control: "NO PROVIDERS CONFIGURED ON THIS GATEWAY."
        case .ink: "This gateway keeps no houses."
        }
    }

    func settingsConnected(_ t: ThemeID) -> String {
        switch t {
        case .soft: "CONNECTED"
        case .control: "AUTH OK"
        case .ink: "SWORN"
        }
    }

    func settingsNotConnected(_ t: ThemeID) -> String {
        switch t {
        case .soft: "NO KEY"
        case .control: "NO CREDENTIAL"
        case .ink: "UNSWORN"
        }
    }

    func settingsOtherProviders(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Not connected"
        case .control: "AVAILABLE — NO CREDENTIAL"
        case .ink: "unsworn houses"
        }
    }

    func settingsProviderInUse(_ t: ThemeID) -> String {
        switch t {
        case .soft: "IN USE"
        case .control: "CURRENT"
        case .ink: "SERVING"
        }
    }

    func settingsConnect(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Add key"
        case .control: "ADD KEY"
        case .ink: "swear it in"
        }
    }

    func settingsReplaceKey(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Replace key"
        case .control: "REPLACE KEY"
        case .ink: "renew the oath"
        }
    }

    func settingsSaveKey(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Save to gateway"
        case .control: "SAVE TO GATEWAY"
        case .ink: "entrust it"
        }
    }

    func settingsKeyPlaceholder(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Paste the provider’s API key"
        case .control: "PASTE API KEY"
        case .ink: "the secret word…"
        }
    }

    /// The one sentence this control exists to make unambiguous.
    func settingsKeyDestination(_ t: ThemeID, env: String) -> String {
        let slot = env.isEmpty ? "its env file" : env
        switch t {
        case .soft:
            return "This key is sent to your gateway and saved there as \(slot). It is never stored on this phone."
        case .control:
            return "KEY → GATEWAY HOST → ~/.hermes/.env (\(slot)). NOT WRITTEN TO DEVICE STORAGE."
        case .ink:
            return "The word travels to the gateway and is kept in its own house as \(slot). This device keeps no copy."
        }
    }

    func settingsDisconnect(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Disconnect"
        case .control: "DISCONNECT"
        case .ink: "release"
        }
    }

    func settingsDisconnectConfirm(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Disconnect provider"
        case .control: "CLEAR CREDENTIALS"
        case .ink: "release the house"
        }
    }

    func settingsDisconnectNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Clears this provider’s key and any OAuth grant on the gateway. Bots using it stop working until you reconnect."
        case .control: "CLEARS ENV KEY + OAUTH GRANT ON THE GATEWAY HOST. SESSIONS ON THIS PROVIDER WILL FAIL."
        case .ink: "The gateway forgets both key and grant. Whatever leaned on this house falls until it is sworn again."
        }
    }

    func settingsOAuthProvider(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Signs in with OAuth — use Provider accounts below to connect this profile."
        case .control: "OAUTH PROVIDER — CONNECT IN PROVIDER ACCOUNTS BELOW."
        case .ink: "This house is entered by ceremony. Use Provider accounts below to swear it to this profile."
        }
    }

    func settingsKeySaved(_ t: ThemeID, provider: String) -> String {
        switch t {
        case .soft: "Saved. \(provider) is connected."
        case .control: "KEY STORED — \(provider.uppercased()) AUTHENTICATED."
        case .ink: "\(provider) is sworn in."
        }
    }

    func settingsDisconnected(_ t: ThemeID, provider: String) -> String {
        switch t {
        case .soft: "\(provider) disconnected."
        case .control: "\(provider.uppercased()) CREDENTIALS CLEARED."
        case .ink: "\(provider) is released."
        }
    }

    func settingsModelSaved(_ t: ThemeID, model: String) -> String {
        switch t {
        case .soft: "\(model) is the new default."
        case .control: "DEFAULT → \(model.uppercased())."
        case .ink: "\(model) stands ready."
        }
    }

    /// The gateway accepted the switch but wrote it somewhere narrower than
    /// config.yaml — a settings control must not claim otherwise.
    func settingsModelNotGlobal(_ t: ThemeID, scope: String) -> String {
        switch t {
        case .soft: "The gateway applied this to \(scope) scope, not to its saved default."
        case .control: "SCOPE=\(scope.uppercased()) — CONFIG DEFAULT UNCHANGED."
        case .ink: "The gateway took it only for \(scope). Its standing order is unchanged."
        }
    }

    func settingsDemoWrite(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Demo data — nothing was sent to a gateway."
        case .control: "DEMO MODE — NO RPC ISSUED."
        case .ink: "A rehearsal. No word left this device."
        }
    }

    func settingsAuxNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Auxiliary and vision slots and MoA presets are not editable on this screen yet. Custom endpoints are available under Providers."
        case .control: "AUX/VISION + MoA EDITOR: NOT YET IN THIS BUILD. CUSTOM ENDPOINTS: PROVIDERS."
        case .ink: "The lesser hands and councils await their mobile ledger. Private endpoints are kept under Providers."
        }
    }
}
