import SwiftUI
import TalariaKit
import TalariaTheme

/// Mobile administration for Hermes' external-memory provider surface.
///
/// The provider inventory and dependency setup belong to a gateway host. The
/// declared field values belong to the captured profile (or gateway default).
/// Those two scopes are shown separately and every async read/write carries a
/// generation fence, so changing either picker cannot repaint or mutate the
/// previous machine/profile.
public struct MemoryProviderSettingsSection: View {
    private let model: AppModel

    public init(model: AppModel) { self.model = model }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    @State private var selectedGatewayID: String?
    @State private var selectedProfile: String?
    @State private var selectedProvider = ""
    @State private var stateScopeKey: String?
    @State private var generation = 0
    @State private var configGeneration = 0
    @State private var inventory = MemoryProviderInventory(.null)
    @State private var providerNames: [String] = []
    @State private var profileProviderNames: Set<String> = []
    @State private var scopedActive = ""
    @State private var checkpointRequirement = CompressionCheckpointRequirement(rawValue: nil)
    @State private var providerConfig: MemoryProviderDeclaredConfig?
    @State private var drafts: [String: String] = [:]
    @State private var isLoadingScope = false
    @State private var isLoadingConfig = false
    @State private var busyAction: String?
    @State private var notice: String?
    @State private var noticeIsWarning = false
    @State private var setupTarget: PendingSetup?
    @State private var oauthProbed = false
    @State private var oauthSupported = false
    @State private var oauthStatus: MemoryProviderOAuthStatus?
    @State private var oauthDetail = ""
    @State private var oauthPollTask: Task<Void, Never>?
    @State private var oauthGeneration = 0

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if gatewayChoices.count > 1 { gatewayPicker }
            if !profileChoices.isEmpty { profilePicker }
            providerSection
            if model.mode == .live { checkpointSection }
            if let notice {
                Text(notice)
                    .font(theme.mono(10.5))
                    .foregroundStyle(noticeIsWarning ? theme.warn : theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: scopeKey) { await loadScope(scopeKey) }
        .task(id: providerLoadKey) { await loadSelectedProvider(providerLoadKey) }
        .onDisappear { stopOAuthPolling(showNotice: false) }
        .confirmationDialog(copy.settingsMemoryProviderSetupTitle(theme.id),
                            isPresented: Binding(get: { setupTarget != nil },
                                                 set: { if !$0 { setupTarget = nil } }),
                            titleVisibility: .visible) {
            Button(copy.settingsMemoryProviderInstall(theme.id)) {
                guard let target = setupTarget else { return }
                Task { await runSetup(target) }
            }
            Button(copy.cancel, role: .cancel) { setupTarget = nil }
        } message: {
            Text(copy.settingsMemoryProviderSetupWarning(theme.id,
                                                         provider: setupTarget?.provider ?? ""))
        }
    }

    // MARK: Scope

    private var gatewayChoices: [SavedGateway] {
        model.mode == .live ? ConnectionRegistry.shared.saved : []
    }

    private var targetGatewayID: String? {
        GatewaySettingsTargetFence.resolve(selected: selectedGatewayID,
                                           available: Set(gatewayChoices.map(\.id)),
                                           active: model.activeGatewayID,
                                           runtime: LiveRuntime.shared.gatewayID)
    }

    private var profileChoices: [Bot] {
        let target = targetGatewayID
        return model.unionRosterBots.filter { bot in
            if let route = model.profileRoute(for: bot.id) { return route.gatewayID == target }
            return target == model.activeGatewayID
        }
    }

    private var targetProfile: String? {
        let available = Set(profileChoices.map { model.profileRoute(for: $0.id)?.profile ?? $0.id })
        return selectedProfile.flatMap { available.contains($0) ? $0 : nil }
    }

    private var scopeKey: String {
        "\(targetGatewayID ?? "demo")\u{1f}\(targetProfile ?? "__gateway__")"
    }

    private var providerLoadKey: String { "\(scopeKey)\u{1f}\(selectedProvider)" }

    private var gatewayPicker: some View {
        SettingsSection(theme: theme, title: copy.settingsMemoryProviderGateway(theme.id),
                        footnote: copy.settingsMemoryProviderGatewayNote(theme.id)) {
            SettingsGroup(theme: theme) {
                Picker(copy.settingsMemoryProviderGateway(theme.id), selection: Binding(
                    get: { targetGatewayID },
                    set: { selectedGatewayID = $0; selectedProfile = nil })) {
                    ForEach(gatewayChoices) { gateway in
                        Text(gateway.name + (gateway.id == model.activeGatewayID
                                             ? copy.settingsModelGatewayActive(theme.id) : ""))
                            .tag(Optional(gateway.id))
                    }
                }
                .pickerStyle(.menu).tint(theme.accent).padding(10)
            }
        }
    }

    private var profilePicker: some View {
        SettingsSection(theme: theme, title: copy.settingsMemoryProviderScope(theme.id),
                        footnote: copy.settingsMemoryProviderScopeNote(theme.id)) {
            SettingsGroup(theme: theme) {
                Picker(copy.settingsMemoryProviderScope(theme.id), selection: $selectedProfile) {
                    Text(copy.settingsOperatorGatewayDefault(theme.id)).tag(String?.none)
                    ForEach(profileChoices) { bot in
                        Text(bot.displayTitle)
                            .tag(Optional(model.profileRoute(for: bot.id)?.profile ?? bot.id))
                    }
                }
                .pickerStyle(.menu).tint(theme.accent).padding(10)
            }
        }
    }

    // MARK: Provider UI

    private var selectedInventoryRow: MemoryProviderInventoryRow? {
        inventory.providers.first { $0.name == selectedProvider }
    }

    private var providerSection: some View {
        SettingsSection(theme: theme, title: copy.settingsMemoryProviders(theme.id),
                        footnote: copy.settingsMemoryProvidersNote(theme.id,
                                                                  profile: targetProfile)) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsGroup(theme: theme) {
                    Picker(copy.settingsMemoryProviders(theme.id), selection: $selectedProvider) {
                        Text(copy.settingsMemoryBuiltin(theme.id)).tag("")
                        ForEach(providerNames, id: \.self) { provider in
                            Text(provider).tag(provider)
                        }
                    }
                    .pickerStyle(.menu).tint(theme.accent).padding(10)

                    SettingsRow(theme: theme,
                                title: copy.settingsMemoryProviderActive(theme.id),
                                subtitle: targetProfile == nil
                                    ? copy.settingsMemoryProviderGatewayActiveNote(theme.id)
                                    : copy.settingsMemoryProviderProfileActiveNote(theme.id),
                                value: scopedActive.isEmpty
                                    ? copy.settingsMemoryBuiltinShort(theme.id) : scopedActive,
                                valueTone: theme.accent,
                                isLast: selectedProvider.isEmpty)

                    if !selectedProvider.isEmpty {
                        SettingsRow(theme: theme,
                                    title: copy.settingsMemoryProviderGatewayStatus(theme.id,
                                                                                   provider: selectedProvider),
                                    subtitle: selectedInventoryRow?.description,
                                    value: providerStatusLabel,
                                    valueTone: providerStatusColor,
                                    isLast: !canSetup && providerConfig?.fields.isEmpty != false)
                    }
                }

                if canSetup {
                    SettingsGroup(theme: theme) {
                        SettingsActionRow(theme: theme,
                                          title: copy.settingsMemoryProviderSetup(theme.id),
                                          subtitle: setupSummary,
                                          isBusy: busyAction == "setup",
                                          isLast: true) {
                            setupTarget = PendingSetup(gatewayID: targetGatewayID,
                                                       profile: targetProfile,
                                                       provider: selectedProvider,
                                                       scopeKey: scopeKey,
                                                       generation: generation)
                        }
                    }
                }

                if oauthProbed && oauthSupported && !selectedProvider.isEmpty {
                    oauthSection
                }

                if isLoadingScope || isLoadingConfig {
                    ProgressView().tint(theme.accent).frame(maxWidth: .infinity)
                } else if let config = providerConfig, !config.fields.isEmpty {
                    SettingsGroup(theme: theme) {
                        ForEach(Array(config.fields.enumerated()), id: \.element.id) { index, field in
                            providerField(field, isLast: index == config.fields.count - 1)
                        }
                    }
                    if let docs = MemoryProviderDocumentationPolicy.externalURL(
                        config.documentationURL) {
                        Link(copy.settingsMemoryProviderDocumentation(theme.id), destination: docs)
                            .font(SettingsType.rowSubtitle(theme)).foregroundStyle(theme.accent)
                            .padding(.horizontal, 2)
                    }
                } else if !selectedProvider.isEmpty && !canSetup {
                    Text(copy.settingsMemoryProviderNoFields(theme.id))
                        .font(SettingsType.rowSubtitle(theme)).foregroundStyle(theme.faint)
                        .padding(.horizontal, 2)
                }

                SettingsGroup(theme: theme) {
                    if !selectedProvider.isEmpty, providerConfig?.fields.isEmpty == false {
                        SettingsActionRow(theme: theme,
                                          title: copy.settingsMemoryProviderSave(theme.id),
                                          subtitle: copy.settingsMemoryProviderSecretNote(theme.id),
                                          isBusy: busyAction == "save",
                                          isLast: false) {
                            Task { await saveConfig() }
                        }
                    }
                    SettingsActionRow(theme: theme,
                                      title: selectedProvider.isEmpty
                                        ? copy.settingsMemoryUseBuiltin(theme.id)
                                        : copy.settingsMemoryUseProvider(theme.id, provider: selectedProvider),
                                      subtitle: copy.settingsMemoryProviderActivationNote(theme.id,
                                                                                         profile: targetProfile),
                                      isBusy: busyAction == "activate",
                                      isLast: true) {
                        Task { await activateSelection() }
                    }
                    .disabled(selectedProvider == scopedActive || !selectionCanActivate)
                }
            }
        }
        .opacity(model.mode == .live ? 1 : 0.55)
        // OAuth's Stop-waiting control must remain tappable while its polling
        // task owns `busyAction`; every mutation still guards busyAction.
        .disabled(model.mode != .live || (busyAction != nil && busyAction != "oauth"))
    }

    @ViewBuilder
    private func providerField(_ field: MemoryProviderField, isLast: Bool) -> some View {
        switch field.kind {
        case .boolean:
            SettingsToggleRow(theme: theme, title: field.label,
                              subtitle: field.description,
                              isOn: (drafts[field.key] ?? field.value).lowercased() == "true",
                              isLast: isLast) {
                let current = (drafts[field.key] ?? field.value).lowercased() == "true"
                drafts[field.key] = current ? "false" : "true"
            }
        case .select:
            VStack(alignment: .leading, spacing: 5) {
                Text(field.label).font(SettingsType.rowTitle(theme)).foregroundStyle(theme.ink)
                Picker(field.label, selection: draftBinding(field)) {
                    ForEach(field.options) { option in Text(option.label).tag(option.value) }
                }
                .pickerStyle(.menu).tint(theme.accent)
                if !field.description.isEmpty {
                    Text(field.description).font(SettingsType.rowSubtitle(theme))
                        .foregroundStyle(theme.sub)
                }
            }
            .modifier(SettingsRowChrome(theme: theme, isLast: isLast))
        case .secret:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(field.label).font(SettingsType.rowTitle(theme)).foregroundStyle(theme.ink)
                    Spacer()
                    if field.isSet {
                        Text(copy.settingsMemorySecretSet(theme.id))
                            .font(theme.mono(9)).foregroundStyle(theme.ok)
                    }
                }
                SecureField(field.isSet ? copy.settingsMemorySecretKeep(theme.id) : field.placeholder,
                            text: draftBinding(field))
                    .textFieldStyle(.roundedBorder).textContentType(.password)
                if !field.description.isEmpty {
                    Text(field.description).font(SettingsType.rowSubtitle(theme))
                        .foregroundStyle(theme.sub)
                }
            }
            .modifier(SettingsRowChrome(theme: theme, isLast: isLast))
        case .number, .text:
            VStack(alignment: .leading, spacing: 6) {
                Text(field.label).font(SettingsType.rowTitle(theme)).foregroundStyle(theme.ink)
                TextField(field.placeholder, text: draftBinding(field))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                if !field.description.isEmpty {
                    Text(field.description).font(SettingsType.rowSubtitle(theme))
                        .foregroundStyle(theme.sub)
                }
            }
            .modifier(SettingsRowChrome(theme: theme, isLast: isLast))
        }
    }

    private func draftBinding(_ field: MemoryProviderField) -> Binding<String> {
        Binding(get: { drafts[field.key] ?? field.value },
                set: { drafts[field.key] = $0 })
    }

    private var canSetup: Bool { selectedInventoryRow?.setup.hasWork == true }

    private var setupSummary: String {
        let setup = selectedInventoryRow?.setup
        return ((setup?.pipDependencies ?? []) + (setup?.externalDependencies ?? []))
            .joined(separator: ", ")
    }

    private var selectionCanActivate: Bool {
        guard !selectedProvider.isEmpty else { return true }
        if let selectedInventoryRow { return selectedInventoryRow.status == "ready" }
        return profileProviderNames.contains(selectedProvider)
    }

    private var providerStatusLabel: String {
        selectedInventoryRow?.status.replacingOccurrences(of: "_", with: " ")
            ?? (profileProviderNames.contains(selectedProvider)
                ? copy.settingsMemoryProviderProfileAvailable(theme.id)
                : copy.settingsMemoryProviderNotFound(theme.id))
    }

    private var providerStatusColor: Color {
        switch selectedInventoryRow?.status {
        case "ready": theme.ok
        case "needs_config": theme.warn
        case nil where profileProviderNames.contains(selectedProvider): theme.accent
        default: theme.danger
        }
    }

    // MARK: Durable checkpoint gate

    private var checkpointGateState: CompressionCheckpointGateState {
        CompressionCheckpointGateState.resolve(requirement: checkpointRequirement,
                                                activeProvider: scopedActive,
                                                inventory: inventory,
                                                readinessIsAuthoritative: targetProfile == nil)
    }

    private var checkpointSection: some View {
        let state = checkpointGateState
        return SettingsSection(theme: theme, title: copy.settingsMemoryCheckpoint(theme.id),
                               footnote: copy.settingsMemoryCheckpointNote(theme.id)) {
            SettingsGroup(theme: theme) {
                switch state {
                case .controllable(let enabled, let provider, let apiVersion):
                    SettingsToggleRow(theme: theme,
                                      title: copy.settingsMemoryCheckpointToggle(theme.id),
                                      subtitle: copy.settingsMemoryCheckpointToggleNote(
                                        theme.id, provider: provider, apiVersion: apiVersion),
                                      isOn: enabled, isLast: true) {
                        Task { await setCheckpointRequirement(!enabled) }
                    }
                case .blocked(let blocker):
                    SettingsRow(theme: theme,
                                title: copy.settingsMemoryCheckpointToggle(theme.id),
                                subtitle: checkpointBlockerDetail(blocker, blocked: true),
                                value: copy.settingsMemoryCheckpointBlocked(theme.id),
                                valueTone: theme.warn, isLast: true)
                case .unavailable(let blocker):
                    SettingsRow(theme: theme,
                                title: copy.settingsMemoryCheckpointToggle(theme.id),
                                subtitle: checkpointBlockerDetail(blocker, blocked: false),
                                value: copy.settingsMemoryCheckpointUnavailable(theme.id),
                                valueTone: theme.faint, isLast: true)
                }
            }
            .disabled(isLoadingScope || busyAction != nil)
            .opacity(isLoadingScope ? 0.55 : 1)
        }
    }

    private func checkpointBlockerDetail(_ blocker: CompressionCheckpointGateState.Blocker,
                                         blocked: Bool) -> String {
        let prefix = blocked ? copy.settingsMemoryCheckpointRecoverablePrefix(theme.id) : ""
        let reason: String
        switch blocker {
        case .checkpointValueNotReported:
            reason = copy.settingsMemoryCheckpointValueNotReported(theme.id)
        case .checkpointValueUnrecognized:
            reason = copy.settingsMemoryCheckpointValueUnrecognized(theme.id)
        case .noActiveExternalProvider:
            reason = copy.settingsMemoryCheckpointNoActiveProvider(theme.id)
        case .activeProviderNotReported(let provider):
            reason = copy.settingsMemoryCheckpointProviderNotReported(theme.id, provider: provider)
        case .activeProviderNotReady(let provider):
            reason = copy.settingsMemoryCheckpointProviderNotReady(theme.id, provider: provider)
        case .checkpointAPINotAdvertised(let provider):
            reason = copy.settingsMemoryCheckpointAPINotAdvertised(theme.id, provider: provider)
        case .checkpointAPIVersionTooOld(let provider, let version):
            reason = copy.settingsMemoryCheckpointAPIVersionTooOld(theme.id, provider: provider,
                                                                      version: version)
        case .scopedProviderReadinessUnavailable(let provider):
            reason = copy.settingsMemoryCheckpointScopedReadinessUnavailable(
                theme.id, provider: provider)
        }
        return prefix + reason
    }

    private var oauthSection: some View {
        SettingsGroup(theme: theme) {
            SettingsRow(theme: theme,
                        title: copy.settingsMemoryOAuth(theme.id),
                        subtitle: oauthSubtitle,
                        value: oauthStatus?.connected == true
                            ? copy.settingsMemoryOAuthConnected(theme.id,
                                                                method: oauthStatus?.authentication)
                            : nil,
                        valueTone: oauthStatus?.connected == true ? theme.ok : theme.faint,
                        isLast: false)
            if oauthStatus?.state == .pending {
                SettingsActionRow(theme: theme,
                                  title: copy.settingsMemoryOAuthStopWaiting(theme.id),
                                  subtitle: copy.settingsMemoryOAuthStopNote(theme.id),
                                  isLast: true) {
                    stopOAuthPolling(showNotice: true)
                }
            } else {
                SettingsActionRow(theme: theme,
                                  title: oauthStatus?.connected == true
                                    ? copy.settingsMemoryOAuthReconnect(theme.id)
                                    : copy.settingsMemoryOAuthConnect(theme.id),
                                  subtitle: copy.settingsMemoryOAuthBrowserNote(theme.id),
                                  isBusy: busyAction == "oauth",
                                  isLast: true) {
                    startOAuth()
                }
            }
        }
    }

    private var oauthSubtitle: String {
        if !oauthDetail.isEmpty { return oauthDetail }
        switch oauthStatus?.state {
        case .pending: return copy.settingsMemoryOAuthPending(theme.id)
        case .error: return oauthStatus?.detail ?? copy.settingsMemoryOAuthFailed(theme.id)
        default: return copy.settingsMemoryOAuthNote(theme.id)
        }
    }

    // MARK: Async state machine

    private func targetClient(gatewayID: String?) async throws -> GatewayClient {
        if let gatewayID { return try await model.routedClient(gatewayID: gatewayID) }
        if let client = model.client { return client }
        throw AppModel.GatewayRouteError.noRoute
    }

    private func isCurrent(_ key: String, _ captured: Int) -> Bool {
        stateScopeKey == key && scopeKey == key && generation == captured
    }

    private func resetForScope(_ key: String) {
        oauthPollTask?.cancel()
        oauthPollTask = nil
        oauthGeneration &+= 1
        generation &+= 1
        configGeneration &+= 1
        stateScopeKey = key
        inventory = MemoryProviderInventory(.null)
        providerNames = []
        profileProviderNames = []
        scopedActive = ""
        checkpointRequirement = CompressionCheckpointRequirement(rawValue: nil)
        selectedProvider = ""
        providerConfig = nil
        drafts = [:]
        notice = nil
        busyAction = nil
        isLoadingScope = false
        isLoadingConfig = false
        oauthProbed = false
        oauthSupported = false
        oauthStatus = nil
        oauthDetail = ""
    }

    private func loadScope(_ key: String) async {
        guard scopeKey == key else { return }
        resetForScope(key)
        let captured = generation
        let gatewayID = targetGatewayID
        let profile = targetProfile
        guard model.mode == .live else { return }
        isLoadingScope = true
        defer { if isCurrent(key, captured) { isLoadingScope = false } }
        do {
            let client = try await targetClient(gatewayID: gatewayID)
            guard isCurrent(key, captured) else { return }
            async let inventoryRequest = client.memoryProviderInventory()
            async let configurationRequest = client.memoryProviderScopeConfiguration(profile: profile)
            let (loadedInventory, configuration) = try await (inventoryRequest, configurationRequest)
            guard isCurrent(key, captured) else { return }
            let profileCatalog = (try? await client.memoryProviderCatalog(profile: profile)) ?? []
            guard isCurrent(key, captured) else { return }
            let active = configuration.activeProvider
            inventory = loadedInventory
            profileProviderNames = Set(profileCatalog.filter { !$0.isEmpty })
            providerNames = MemoryProviderCatalog.merge(profileSchema: profileCatalog,
                                                        gatewayInventory: loadedInventory.providers,
                                                        active: active)
            scopedActive = active
            checkpointRequirement = configuration.checkpointRequirement
            selectedProvider = active
            if !active.isEmpty && !profileProviderNames.contains(active)
                && !loadedInventory.providers.contains(where: { $0.name == active }) {
                setNotice(copy.settingsMemoryProviderMissing(theme.id, provider: active), warning: true)
            }
        } catch {
            guard isCurrent(key, captured) else { return }
            setNotice(error.localizedDescription, warning: true)
        }
    }

    private func setCheckpointRequirement(_ enabled: Bool) async {
        guard busyAction == nil, checkpointGateState.toggleIsVisible else { return }
        let key = scopeKey
        let captured = generation
        let gatewayID = targetGatewayID
        let profile = targetProfile
        let activeProvider = scopedActive
        busyAction = "checkpoint"
        setNotice(nil, warning: false)
        defer { if isCurrent(key, captured) { busyAction = nil } }
        do {
            let client = try await targetClient(gatewayID: gatewayID)
            guard isCurrent(key, captured), scopedActive == activeProvider,
                  checkpointGateState.toggleIsVisible else { return }
            try await client.setCompressionCheckpointRequired(enabled, profile: profile)
            guard isCurrent(key, captured), scopedActive == activeProvider else { return }
            checkpointRequirement = CompressionCheckpointRequirement(rawValue: .bool(enabled))
            setNotice(copy.settingsMemoryCheckpointSaved(theme.id, enabled: enabled), warning: false)
        } catch {
            guard isCurrent(key, captured), scopedActive == activeProvider else { return }
            // This is a configuration mutation failure. Keep the live gateway
            // session intact and leave the pre-write raw value in place so the
            // operator can remedy the provider/configuration and retry.
            setNotice(error.localizedDescription, warning: true)
        }
    }

    private func loadSelectedProvider(_ key: String) async {
        oauthPollTask?.cancel()
        oauthPollTask = nil
        oauthGeneration &+= 1
        if busyAction == "oauth" { busyAction = nil }
        configGeneration &+= 1
        let capturedConfig = configGeneration
        let captured = generation
        let scope = scopeKey
        let gatewayID = targetGatewayID
        let profile = targetProfile
        let provider = selectedProvider
        providerConfig = nil
        drafts = [:]
        oauthProbed = false
        oauthSupported = false
        oauthStatus = nil
        oauthDetail = ""
        guard stateScopeKey == scope, model.mode == .live, !provider.isEmpty else { return }
        isLoadingConfig = true
        defer {
            if isCurrent(scope, captured), configGeneration == capturedConfig {
                isLoadingConfig = false
            }
        }
        do {
            let client = try await targetClient(gatewayID: gatewayID)
            guard isCurrent(scope, captured), providerLoadKey == key,
                  configGeneration == capturedConfig else { return }
            let loaded = try await client.memoryProviderConfig(provider, profile: profile)
            guard isCurrent(scope, captured), providerLoadKey == key,
                  configGeneration == capturedConfig else { return }
            providerConfig = loaded
            drafts = Dictionary(uniqueKeysWithValues: loaded.fields.map { ($0.key, $0.value) })
            await probeOAuth(client: client, provider: provider, profile: profile,
                             scope: scope, generation: captured,
                             configGeneration: capturedConfig, providerKey: key)
        } catch {
            guard isCurrent(scope, captured), providerLoadKey == key,
                  configGeneration == capturedConfig else { return }
            setNotice(error.localizedDescription, warning: true)
        }
    }

    private func probeOAuth(client: GatewayClient, provider: String, profile: String?,
                            scope: String, generation captured: Int,
                            configGeneration capturedConfig: Int, providerKey: String) async {
        do {
            let status = try await client.memoryProviderOAuthStatus(provider, profile: profile)
            guard isCurrent(scope, captured), configGeneration == capturedConfig,
                  providerLoadKey == providerKey else { return }
            oauthSupported = true
            oauthStatus = status
            oauthProbed = true
        } catch let error as GatewayError where error.code == 404 {
            guard isCurrent(scope, captured), configGeneration == capturedConfig,
                  providerLoadKey == providerKey else { return }
            oauthSupported = false
            oauthStatus = nil
            oauthProbed = true
        } catch {
            guard isCurrent(scope, captured), configGeneration == capturedConfig,
                  providerLoadKey == providerKey else { return }
            // A transport/auth failure is not evidence that the provider lacks
            // OAuth. Keep capability unknown and surface a retryable error.
            oauthProbed = false
            oauthDetail = error.localizedDescription
            setNotice(copy.settingsMemoryOAuthProbeFailed(theme.id), warning: true)
        }
    }

    private func startOAuth() {
        guard busyAction == nil, oauthSupported, !selectedProvider.isEmpty else { return }
        oauthPollTask?.cancel()
        oauthGeneration &+= 1
        let flowGeneration = oauthGeneration
        let key = scopeKey
        let captured = generation
        let capturedConfig = configGeneration
        let gatewayID = targetGatewayID
        let profile = targetProfile
        let provider = selectedProvider
        busyAction = "oauth"
        oauthDetail = ""
        oauthPollTask = Task {
            await runOAuth(provider: provider, gatewayID: gatewayID, profile: profile,
                           scope: key, generation: captured,
                           configGeneration: capturedConfig,
                           oauthGeneration: flowGeneration)
        }
    }

    private func runOAuth(provider: String, gatewayID: String?, profile: String?,
                          scope: String, generation captured: Int,
                          configGeneration capturedConfig: Int,
                          oauthGeneration flowGeneration: Int) async {
        defer {
            if isCurrent(scope, captured), oauthGeneration == flowGeneration {
                busyAction = nil
                oauthPollTask = nil
            }
        }
        do {
            let client = try await targetClient(gatewayID: gatewayID)
            guard oauthIsCurrent(provider: provider, scope: scope, generation: captured,
                                 configGeneration: capturedConfig,
                                 oauthGeneration: flowGeneration) else { return }
            let before = try await client.memoryProviderOAuthStatus(provider, profile: profile)
            guard oauthIsCurrent(provider: provider, scope: scope, generation: captured,
                                 configGeneration: capturedConfig,
                                 oauthGeneration: flowGeneration) else { return }
            guard before.state != .pending else {
                oauthStatus = before
                oauthDetail = copy.settingsMemoryOAuthAlreadyPending(theme.id)
                return
            }
            let started = try await client.startMemoryProviderOAuth(provider, profile: profile)
            guard oauthIsCurrent(provider: provider, scope: scope, generation: captured,
                                 configGeneration: capturedConfig,
                                 oauthGeneration: flowGeneration) else { return }
            oauthStatus = started
            oauthDetail = started.detail

            let deadline = Date().addingTimeInterval(120)
            while !Task.isCancelled {
                let initialDecision = MemoryProviderOAuthPollDecision.decide(
                    status: oauthStatus ?? started, timedOut: Date() >= deadline)
                if await finishOAuthIfTerminal(initialDecision, client: client, provider: provider,
                                               profile: profile, scope: scope,
                                               generation: captured,
                                               configGeneration: capturedConfig,
                                               oauthGeneration: flowGeneration) { return }

                try await Task.sleep(for: .milliseconds(1_500))
                guard oauthIsCurrent(provider: provider, scope: scope, generation: captured,
                                     configGeneration: capturedConfig,
                                     oauthGeneration: flowGeneration) else { return }
                do {
                    let next = try await client.memoryProviderOAuthStatus(provider, profile: profile)
                    guard oauthIsCurrent(provider: provider, scope: scope, generation: captured,
                                         configGeneration: capturedConfig,
                                         oauthGeneration: flowGeneration) else { return }
                    oauthStatus = next
                    oauthDetail = next.detail
                } catch {
                    // Poll transport failures are transient. Keep polling until
                    // the bounded deadline, matching Desktop's behavior.
                    if Date() >= deadline {
                        oauthDetail = copy.settingsMemoryOAuthTimedOut(theme.id)
                        if var status = oauthStatus { status.state = .error; oauthStatus = status }
                        return
                    }
                }
            }
        } catch is CancellationError {
            // The upstream memory flow has no cancellation route. Talaria can
            // stop waiting, but must not claim it revoked browser consent.
        } catch {
            guard oauthIsCurrent(provider: provider, scope: scope, generation: captured,
                                 configGeneration: capturedConfig,
                                 oauthGeneration: flowGeneration) else { return }
            oauthDetail = error.localizedDescription
            oauthStatus = MemoryProviderOAuthStatus([
                "state": "error", "detail": .string(error.localizedDescription),
                "connected": false, "auth": nil,
            ])
        }
    }

    private func finishOAuthIfTerminal(_ decision: MemoryProviderOAuthPollDecision,
                                       client: GatewayClient, provider: String, profile: String?,
                                       scope: String, generation captured: Int,
                                       configGeneration capturedConfig: Int,
                                       oauthGeneration flowGeneration: Int) async -> Bool {
        switch decision {
        case .keepWaiting:
            return false
        case .failed(let detail):
            oauthDetail = detail
            if var status = oauthStatus { status.state = .error; oauthStatus = status }
            return true
        case .connected:
            oauthDetail = copy.settingsMemoryOAuthComplete(theme.id)
            if let loaded = try? await client.memoryProviderConfig(provider, profile: profile),
               oauthIsCurrent(provider: provider, scope: scope, generation: captured,
                              configGeneration: capturedConfig,
                              oauthGeneration: flowGeneration) {
                providerConfig = loaded
                drafts = Dictionary(uniqueKeysWithValues: loaded.fields.map { ($0.key, $0.value) })
            }
            return true
        }
    }

    private func oauthIsCurrent(provider: String, scope: String, generation captured: Int,
                                configGeneration capturedConfig: Int,
                                oauthGeneration flowGeneration: Int) -> Bool {
        isCurrent(scope, captured) && configGeneration == capturedConfig
            && oauthGeneration == flowGeneration && selectedProvider == provider
    }

    private func stopOAuthPolling(showNotice: Bool) {
        oauthGeneration &+= 1
        oauthPollTask?.cancel()
        oauthPollTask = nil
        if var status = oauthStatus, status.state == .pending {
            status.state = .idle
            oauthStatus = status
        }
        busyAction = nil
        oauthDetail = showNotice ? copy.settingsMemoryOAuthStopped(theme.id) : ""
    }

    private func saveConfig() async {
        guard busyAction == nil, let config = providerConfig else { return }
        guard selectedProvider == config.name else { return }
        let key = scopeKey
        let captured = generation
        let capturedConfig = configGeneration
        let gatewayID = targetGatewayID
        let profile = targetProfile
        let capturedDrafts = drafts
        let activeBeforeSave = scopedActive
        busyAction = "save"
        setNotice(nil, warning: false)
        defer { if isCurrent(key, captured) { busyAction = nil } }
        do {
            let client = try await targetClient(gatewayID: gatewayID)
            guard isCurrent(key, captured), configGeneration == capturedConfig,
                  selectedProvider == config.name else { return }
            try await client.saveMemoryProviderConfig(config, drafts: capturedDrafts, profile: profile)
            guard isCurrent(key, captured), configGeneration == capturedConfig,
                  selectedProvider == config.name else { return }
            if let refreshedInventory = try? await client.memoryProviderInventory() {
                guard isCurrent(key, captured), configGeneration == capturedConfig,
                      selectedProvider == config.name else { return }
                inventory = refreshedInventory
            }
            // Hermes' declared-config PUT saves fields only. Activation remains
            // an explicit, separate action so the UI continues to reflect the
            // runtime selection returned by /api/config.
            scopedActive = MemoryProviderSaveSemantics.activeSelection(
                afterDeclaredSave: activeBeforeSave)
            drafts = drafts.merging(config.fields.filter { $0.kind == .secret }
                .map { ($0.key, "") }, uniquingKeysWith: { _, new in new })
            setNotice(copy.settingsMemoryProviderSaved(theme.id, provider: config.label), warning: false)
        } catch {
            guard isCurrent(key, captured), configGeneration == capturedConfig else { return }
            setNotice(error.localizedDescription, warning: true)
        }
    }

    private func activateSelection() async {
        guard busyAction == nil else { return }
        let key = scopeKey
        let captured = generation
        let gatewayID = targetGatewayID
        let profile = targetProfile
        let provider = selectedProvider
        busyAction = "activate"
        setNotice(nil, warning: false)
        defer { if isCurrent(key, captured) { busyAction = nil } }
        do {
            let client = try await targetClient(gatewayID: gatewayID)
            guard isCurrent(key, captured), selectedProvider == provider else { return }
            try await client.selectMemoryProvider(provider, profile: profile)
            guard isCurrent(key, captured), selectedProvider == provider else { return }
            scopedActive = provider
            setNotice(copy.settingsMemoryProviderActivated(theme.id,
                                                            provider: provider.isEmpty
                                                                ? copy.settingsMemoryBuiltinShort(theme.id)
                                                                : provider), warning: false)
        } catch {
            guard isCurrent(key, captured), selectedProvider == provider else { return }
            setNotice(error.localizedDescription, warning: true)
        }
    }

    private func runSetup(_ target: PendingSetup) async {
        setupTarget = nil
        guard busyAction == nil, isCurrent(target.scopeKey, target.generation),
              target.gatewayID == targetGatewayID, target.provider == selectedProvider else { return }
        busyAction = "setup"
        setNotice(nil, warning: false)
        defer { if isCurrent(target.scopeKey, target.generation) { busyAction = nil } }
        do {
            let client = try await targetClient(gatewayID: target.gatewayID)
            guard isCurrent(target.scopeKey, target.generation),
                  target.provider == selectedProvider else { return }
            try await client.setupMemoryProvider(target.provider)
            guard isCurrent(target.scopeKey, target.generation),
                  target.provider == selectedProvider else { return }
            if let refreshed = try? await client.memoryProviderInventory() {
                guard isCurrent(target.scopeKey, target.generation),
                      target.provider == selectedProvider else { return }
                inventory = refreshed
            }
            if let loaded = try? await client.memoryProviderConfig(target.provider,
                                                                  profile: target.profile) {
                guard isCurrent(target.scopeKey, target.generation),
                      target.provider == selectedProvider else { return }
                providerConfig = loaded
                drafts = Dictionary(uniqueKeysWithValues: loaded.fields.map { ($0.key, $0.value) })
            }
            setNotice(copy.settingsMemoryProviderSetupDone(theme.id, provider: target.provider),
                      warning: false)
        } catch {
            guard isCurrent(target.scopeKey, target.generation),
                  target.provider == selectedProvider else { return }
            setNotice(error.localizedDescription, warning: true)
        }
    }

    private func setNotice(_ text: String?, warning: Bool) {
        notice = text.flatMap { $0.isEmpty ? nil : $0 }
        noticeIsWarning = warning
    }
}

private struct PendingSetup {
    var gatewayID: String?
    var profile: String?
    var provider: String
    var scopeKey: String
    var generation: Int
}

public extension CopyPack {
    func settingsMemoryProviderGateway(_ t: ThemeID) -> String { t == .control ? "MEMORY HOST" : "Memory gateway" }
    func settingsMemoryProviderGatewayNote(_ t: ThemeID) -> String { t == .control ? "DISCOVERY + INSTALLS BELONG TO ONE GATEWAY HOST." : "Providers and their dependencies are installed separately on each gateway." }
    func settingsMemoryProviderScope(_ t: ThemeID) -> String { t == .control ? "CONFIG SCOPE" : "Provider settings for" }
    func settingsMemoryProviderScopeNote(_ t: ThemeID) -> String { t == .control ? "CREDENTIALS + DECLARED FIELDS RESOLVE INSIDE THIS PROFILE." : "Credentials and provider fields are isolated to the selected profile or gateway default." }
    func settingsMemoryProviders(_ t: ThemeID) -> String { t == .control ? "MEMORY PROVIDER" : "External memory provider" }
    func settingsMemoryProvidersNote(_ t: ThemeID, profile: String?) -> String { profile == nil ? (t == .control ? "GATEWAY DEFAULT. BUILT-IN MEMORY ALWAYS REMAINS AVAILABLE." : "Changes the gateway default. Built-in MEMORY.md and USER.md remain available.") : (t == .control ? "PROFILE OVERRIDE. SETUP STILL RUNS ON THE GATEWAY HOST." : "Configuration and selection apply to this profile; dependency setup still runs on its gateway host.") }
    func settingsMemoryBuiltin(_ t: ThemeID) -> String { t == .control ? "BUILT-IN (MEMORY.md + USER.md)" : "Built-in memory (MEMORY.md + USER.md)" }
    func settingsMemoryBuiltinShort(_ t: ThemeID) -> String { t == .control ? "BUILT-IN" : "Built-in" }
    func settingsMemoryProviderActive(_ t: ThemeID) -> String { t == .control ? "ACTIVE" : "Currently active" }
    func settingsMemoryProviderGatewayStatus(_ t: ThemeID, provider: String) -> String { t == .control ? "\(provider.uppercased()) · GATEWAY STATUS" : "\(provider) on this gateway" }
    func settingsMemoryProviderProfileAvailable(_ t: ThemeID) -> String { t == .control ? "PROFILE AVAILABLE" : "profile available" }
    func settingsMemoryProviderNotFound(_ t: ThemeID) -> String { t == .control ? "NOT DISCOVERED" : "not discovered" }
    func settingsMemoryProviderGatewayActiveNote(_ t: ThemeID) -> String { t == .control ? "GATEWAY DEFAULT" : "Default for new and unoverridden profiles" }
    func settingsMemoryProviderProfileActiveNote(_ t: ThemeID) -> String { t == .control ? "CAPTURED PROFILE" : "For the selected profile" }
    func settingsMemoryProviderSetup(_ t: ThemeID) -> String { t == .control ? "INSTALL PROVIDER REQUIREMENTS" : "Install provider requirements" }
    func settingsMemoryProviderSetupTitle(_ t: ThemeID) -> String { t == .control ? "RUN GATEWAY SETUP?" : "Install on gateway?" }
    func settingsMemoryProviderSetupWarning(_ t: ThemeID, provider: String) -> String { t == .control ? "\(provider.uppercased()) MAY RUN DECLARED PACKAGE INSTALL COMMANDS ON THE SELECTED GATEWAY." : "Hermes may run \(provider)'s declared package-install commands on the selected gateway. This affects every profile on that host." }
    func settingsMemoryProviderInstall(_ t: ThemeID) -> String { t == .control ? "INSTALL ON GATEWAY" : "Install on gateway" }
    func settingsMemoryProviderNoFields(_ t: ThemeID) -> String { t == .control ? "NO DECLARED MOBILE CONFIG FIELDS" : "This provider does not declare configuration fields." }
    func settingsMemoryProviderDocumentation(_ t: ThemeID) -> String { t == .control ? "OPEN PROVIDER DOCUMENTATION ↗" : "Open provider documentation ↗" }
    func settingsMemoryProviderSave(_ t: ThemeID) -> String {
        MemoryProviderCopySemantics.saveAction(control: t == .control)
    }
    func settingsMemoryProviderSecretNote(_ t: ThemeID) -> String { t == .control ? "BLANK SECRETS KEEP THEIR STORED VALUE." : "Leave a saved secret blank to keep it unchanged." }
    func settingsMemoryUseBuiltin(_ t: ThemeID) -> String { t == .control ? "USE BUILT-IN MEMORY" : "Switch to built-in memory" }
    func settingsMemoryUseProvider(_ t: ThemeID, provider: String) -> String { t == .control ? "USE \(provider.uppercased())" : "Use \(provider)" }
    func settingsMemoryProviderActivationNote(_ t: ThemeID, profile: String?) -> String { profile == nil ? (t == .control ? "SET GATEWAY DEFAULT" : "Apply to the gateway default") : (t == .control ? "SET PROFILE OVERRIDE" : "Apply only to the selected profile") }
    func settingsMemorySecretSet(_ t: ThemeID) -> String { t == .control ? "SET" : "Saved" }
    func settingsMemorySecretKeep(_ t: ThemeID) -> String { t == .control ? "BLANK KEEPS CURRENT" : "Leave blank to keep current" }
    func settingsMemoryProviderMissing(_ t: ThemeID, provider: String) -> String { t == .control ? "ACTIVE PROVIDER \(provider.uppercased()) IS NOT INSTALLED." : "The active provider \(provider) is not installed on this gateway." }
    func settingsMemoryProviderSaved(_ t: ThemeID, provider: String) -> String {
        MemoryProviderCopySemantics.savedNotice(control: t == .control, provider: provider)
    }
    func settingsMemoryProviderActivated(_ t: ThemeID, provider: String) -> String { t == .control ? "ACTIVE: \(provider.uppercased())" : "Now using \(provider)." }
    func settingsMemoryCheckpoint(_ t: ThemeID) -> String {
        t == .control ? "DURABLE CHECKPOINT" : "Durable checkpoint"
    }
    func settingsMemoryCheckpointNote(_ t: ThemeID) -> String {
        t == .control
            ? "FAIL-CLOSED PRE-COMPRESSION PROTECTION. V2 PROVIDER PROOF REQUIRED."
            : "Fail-closed protection before lossy compression. Talaria only exposes the control after this gateway proves the active provider supports checkpoint API v2."
    }
    func settingsMemoryCheckpointToggle(_ t: ThemeID) -> String {
        t == .control ? "REQUIRE PRE-COMPRESS CHECKPOINT" : "Require durable checkpoint"
    }
    func settingsMemoryCheckpointToggleNote(_ t: ThemeID, provider: String, apiVersion: Int) -> String {
        t == .control
            ? "\(provider.uppercased()) ADVERTISES CHECKPOINT API V\(apiVersion). NATIVE + MICRO COMPACTION ARE SUPPRESSED; CODEX APP-SERVER MODE IS REJECTED."
            : "\(provider) advertises checkpoint API v\(apiVersion). Hermes suppresses native and micro-compaction while this is on, and rejects Codex app-server mode."
    }
    func settingsMemoryCheckpointBlocked(_ t: ThemeID) -> String {
        t == .control ? "BLOCKED" : "Blocked"
    }
    func settingsMemoryCheckpointUnavailable(_ t: ThemeID) -> String {
        t == .control ? "NOT AVAILABLE" : "Unavailable"
    }
    func settingsMemoryCheckpointRecoverablePrefix(_ t: ThemeID) -> String {
        t == .control
            ? "TRANSCRIPT PRESERVED. FIX THE GATEWAY CONFIGURATION, THEN RETRY COMPACTION. "
            : "The transcript is preserved. Fix the gateway configuration, then retry compression. "
    }
    func settingsMemoryCheckpointValueNotReported(_ t: ThemeID) -> String {
        t == .control
            ? "THIS GATEWAY DOES NOT REPORT compression.checkpoint_required; TALARIA LEAVES IT UNCHANGED."
            : "This gateway does not report compression.checkpoint_required, so Talaria leaves it unchanged."
    }
    func settingsMemoryCheckpointValueUnrecognized(_ t: ThemeID) -> String {
        t == .control
            ? "THE GATEWAY REPORTED A NON-BOOLEAN checkpoint_required VALUE; TALARIA LEAVES THE RAW VALUE UNCHANGED."
            : "The gateway reported a non-boolean checkpoint_required value, so Talaria leaves the raw value unchanged."
    }
    func settingsMemoryCheckpointNoActiveProvider(_ t: ThemeID) -> String {
        t == .control
            ? "SELECT A READY EXTERNAL MEMORY PROVIDER THAT ADVERTISES CHECKPOINT API V2."
            : "Select and configure a ready external memory provider that advertises checkpoint API v2."
    }
    func settingsMemoryCheckpointProviderNotReported(_ t: ThemeID, provider: String) -> String {
        t == .control
            ? "ACTIVE PROVIDER \(provider.uppercased()) IS NOT IN THE AUTHORITATIVE GATEWAY INVENTORY."
            : "The active provider \(provider) is not in the gateway inventory."
    }
    func settingsMemoryCheckpointProviderNotReady(_ t: ThemeID, provider: String) -> String {
        t == .control
            ? "FINISH CONFIGURING \(provider.uppercased()) ON THIS GATEWAY, THEN REFRESH."
            : "Finish configuring \(provider) on this gateway, then refresh this screen."
    }
    func settingsMemoryCheckpointAPINotAdvertised(_ t: ThemeID, provider: String) -> String {
        t == .control
            ? "\(provider.uppercased()) DOES NOT ADVERTISE CHECKPOINT API V2. UPDATE OR CONFIGURE THE PROVIDER; TALARIA WILL NOT INFER CAPABILITY."
            : "\(provider) does not advertise checkpoint API v2. Update or configure the provider; Talaria will not infer capability."
    }
    func settingsMemoryCheckpointAPIVersionTooOld(_ t: ThemeID, provider: String, version: Int) -> String {
        t == .control
            ? "\(provider.uppercased()) REPORTS CHECKPOINT API V\(version); V2 OR LATER IS REQUIRED."
            : "\(provider) reports checkpoint API v\(version); API v2 or later is required."
    }
    func settingsMemoryCheckpointScopedReadinessUnavailable(_ t: ThemeID,
                                                             provider: String) -> String {
        let name = provider.isEmpty ? "the selected provider" : provider
        return t == .control
            ? "PROFILE-SCOPED READINESS FOR \(name.uppercased()) IS NOT EXPOSED BY THIS GATEWAY. TALARIA LEAVES THE CHECKPOINT SETTING UNCHANGED."
            : "This gateway does not expose profile-scoped readiness for \(name), so Talaria leaves the checkpoint setting unchanged."
    }
    func settingsMemoryCheckpointSaved(_ t: ThemeID, enabled: Bool) -> String {
        if t == .control {
            return enabled ? "DURABLE CHECKPOINT REQUIRED" : "DURABLE CHECKPOINT NOT REQUIRED"
        }
        return enabled ? "Durable checkpoint required before compression."
            : "Durable checkpoint requirement disabled."
    }
    func settingsMemoryProviderSetupDone(_ t: ThemeID, provider: String) -> String { t == .control ? "SETUP COMPLETE: \(provider.uppercased())" : "Installed \(provider)'s gateway requirements." }
    func settingsMemoryOAuth(_ t: ThemeID) -> String { t == .control ? "PROVIDER CONNECTION" : "Provider account" }
    func settingsMemoryOAuthNote(_ t: ThemeID) -> String { t == .control ? "PROFILE-SCOPED OAUTH CREDENTIAL" : "Connect this provider for the selected profile." }
    func settingsMemoryOAuthConnect(_ t: ThemeID) -> String { t == .control ? "CONNECT WITH OAUTH" : "Connect with OAuth" }
    func settingsMemoryOAuthReconnect(_ t: ThemeID) -> String { t == .control ? "RECONNECT WITH OAUTH" : "Reconnect with OAuth" }
    func settingsMemoryOAuthConnected(_ t: ThemeID, method: String?) -> String { (method ?? "oauth").uppercased() + (t == .control ? " SET" : " connected") }
    func settingsMemoryOAuthPending(_ t: ThemeID) -> String { t == .control ? "WAITING FOR BROWSER CONSENT…" : "Waiting for browser consent…" }
    func settingsMemoryOAuthBrowserNote(_ t: ThemeID) -> String { t == .control ? "CONSENT OPENS ON THE GATEWAY HOST." : "Hermes opens the consent browser on the selected gateway host." }
    func settingsMemoryOAuthStopWaiting(_ t: ThemeID) -> String { t == .control ? "STOP WAITING" : "Stop waiting" }
    func settingsMemoryOAuthStopNote(_ t: ThemeID) -> String { t == .control ? "STOPS MOBILE POLLING; DOES NOT REVOKE OPEN BROWSER CONSENT." : "Stops polling on this phone; it cannot revoke consent already open on the gateway." }
    func settingsMemoryOAuthStopped(_ t: ThemeID) -> String { t == .control ? "POLLING STOPPED. BROWSER FLOW MAY STILL FINISH." : "Stopped waiting. The gateway browser flow may still finish." }
    func settingsMemoryOAuthComplete(_ t: ThemeID) -> String { t == .control ? "OAUTH CONNECTION COMPLETE" : "OAuth connection complete." }
    func settingsMemoryOAuthFailed(_ t: ThemeID) -> String { t == .control ? "CONNECTION FAILED" : "Connection failed." }
    func settingsMemoryOAuthTimedOut(_ t: ThemeID) -> String { t == .control ? "PHONE POLLING TIMED OUT; GATEWAY FLOW MAY STILL FINISH." : "Phone polling timed out; the gateway browser flow may still finish." }
    func settingsMemoryOAuthAlreadyPending(_ t: ThemeID) -> String { t == .control ? "ANOTHER GATEWAY BROWSER FLOW IS ALREADY PENDING." : "A gateway browser flow is already pending; Talaria did not attach it to this profile." }
    func settingsMemoryOAuthProbeFailed(_ t: ThemeID) -> String { t == .control ? "COULD NOT CHECK PROVIDER OAUTH CAPABILITY." : "Could not check this provider's OAuth capability." }
}
