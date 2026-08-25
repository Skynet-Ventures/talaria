import SwiftUI
import TalariaKit
import TalariaTheme

/// Settings → Intelligence → Web cache & browser snapshots.
///
/// These are selected-profile settings, not phone-local preferences.  A cache
/// mutation carries the exact gateway source, profile, and generation that was
/// on screen when the user tapped it.  If a picker changes while the request is
/// in flight, its result is discarded rather than repainting or mutating the
/// newly selected source.
public struct WebCacheSettingsSection: View {
    private let model: AppModel

    public init(model: AppModel) { self.model = model }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    @State private var selectedGatewayID: String?
    @State private var selectedProfile: String?
    @State private var stateScopeKey: String?
    @State private var generation = 0
    @State private var configuration: WebCacheConfiguration?
    @State private var isLoading = false
    @State private var busyAction: String?
    @State private var notice: String?
    @State private var noticeIsWarning = false
    @State private var ttlDraft = ""
    @State private var snapshotThresholdDraft = ""
    @State private var exemptHostsDraft = ""

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if gatewayChoices.count > 1 { gatewayPicker }
            if !profileChoices.isEmpty { profilePicker }
            webCacheSection
            browserSnapshotSection
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
    }

    // MARK: Scope and source fencing

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
        WebCacheSettingsScope.key(gatewayID: targetGatewayID, profile: targetProfile)
    }

    private func capturedScope() -> WebCacheSettingsScope {
        WebCacheSettingsScope(gatewayID: targetGatewayID, profile: targetProfile,
                              generation: generation)
    }

    private func owns(_ captured: WebCacheSettingsScope) -> Bool {
        stateScopeKey == captured.key
            && WebCacheSettingsScopeFence.accepts(current: capturedScope(), captured: captured)
    }

    private var gatewayPicker: some View {
        SettingsSection(theme: theme, title: copy.settingsWebCacheGateway(theme.id),
                        footnote: copy.settingsWebCacheGatewayNote(theme.id)) {
            SettingsGroup(theme: theme) {
                Picker(copy.settingsWebCacheGateway(theme.id), selection: Binding(
                    get: { targetGatewayID },
                    set: { selectedGatewayID = $0; selectedProfile = nil })) {
                    ForEach(gatewayChoices) { gateway in
                        Text(gateway.name + (gateway.id == model.activeGatewayID
                                             ? copy.settingsModelGatewayActive(theme.id) : ""))
                            .tag(Optional(gateway.id))
                    }
                }
                .pickerStyle(.menu)
                .tint(theme.accent)
                .padding(10)
            }
        }
    }

    private var profilePicker: some View {
        SettingsSection(theme: theme, title: copy.settingsWebCacheScope(theme.id),
                        footnote: copy.settingsWebCacheScopeNote(theme.id)) {
            SettingsGroup(theme: theme) {
                Picker(copy.settingsWebCacheScope(theme.id), selection: $selectedProfile) {
                    Text(copy.settingsOperatorGatewayDefault(theme.id)).tag(String?.none)
                    ForEach(profileChoices) { bot in
                        Text(bot.displayTitle)
                            .tag(Optional(model.profileRoute(for: bot.id)?.profile ?? bot.id))
                    }
                }
                .pickerStyle(.menu)
                .tint(theme.accent)
                .padding(10)
            }
        }
    }

    // MARK: Web-result cache

    private var webCacheSection: some View {
        SettingsSection(theme: theme, title: copy.settingsWebCacheSection(theme.id),
                        footnote: copy.settingsWebCacheNote(theme.id)) {
            if let configuration {
                SettingsGroup(theme: theme) {
                    cacheEnabledRow(configuration, isLast: false)
                    ttlRow(configuration, isLast: true)
                }
                exemptHostsSection(configuration)
            } else {
                SettingsGroup(theme: theme) {
                    SettingsRow(theme: theme,
                                title: copy.settingsWebCacheUnavailable(theme.id),
                                subtitle: unavailableSubtitle,
                                value: isLoading ? copy.settingsLoading(theme.id) : nil,
                                valueTone: theme.faint, isLast: true)
                }
            }
        }
        .disabled(busyAction != nil)
        .opacity(busyAction == nil ? 1 : 0.62)
    }

    @ViewBuilder
    private func cacheEnabledRow(_ configuration: WebCacheConfiguration,
                                 isLast: Bool) -> some View {
        if let enabled = configuration.cacheEnabled.value {
            SettingsToggleRow(theme: theme,
                              title: copy.settingsWebCacheEnabled(theme.id),
                              subtitle: copy.settingsWebCacheEnabledNote(theme.id),
                              isOn: enabled, isLast: isLast) {
                Task { await setCacheEnabled(!enabled) }
            }
        } else {
            SettingsRow(theme: theme,
                        title: copy.settingsWebCacheEnabled(theme.id),
                        subtitle: copy.settingsWebCacheRawValueNote(theme.id,
                                                                     key: "web.cache_enabled"),
                        value: copy.settingsWebCachePreserved(theme.id),
                        valueTone: theme.warn, isLast: isLast)
        }
    }

    @ViewBuilder
    private func ttlRow(_ configuration: WebCacheConfiguration, isLast: Bool) -> some View {
        if let current = configuration.cacheTTLMinutes.value {
            settingTextRow(title: copy.settingsWebCacheTTL(theme.id),
                           subtitle: copy.settingsWebCacheTTLNote(theme.id),
                           text: $ttlDraft,
                           prompt: WebCacheTTLMinutesValue.editorText(current),
                           actionTitle: copy.settingsWebCacheSaveTTL(theme.id),
                           isBusy: busyAction == "ttl", isLast: isLast) {
                Task { await saveTTL() }
            }
        } else {
            SettingsRow(theme: theme,
                        title: copy.settingsWebCacheTTL(theme.id),
                        subtitle: copy.settingsWebCacheRawValueNote(theme.id,
                                                                     key: "web.cache_ttl_minutes"),
                        value: copy.settingsWebCachePreserved(theme.id),
                        valueTone: theme.warn, isLast: isLast)
        }
    }

    @ViewBuilder
    private func exemptHostsSection(_ configuration: WebCacheConfiguration) -> some View {
        SettingsSection(theme: theme, title: copy.settingsWebCacheExemptHosts(theme.id),
                        footnote: copy.settingsWebCacheExemptHostsNote(theme.id)) {
            if configuration.cacheExemptHosts.isManaged {
                SettingsGroup(theme: theme) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(copy.settingsWebCacheExemptHostsInput(theme.id))
                            .font(SettingsType.rowTitle(theme))
                            .foregroundStyle(theme.ink)
                        TextEditor(text: $exemptHostsDraft)
                            .font(theme.mono(11))
                            .foregroundStyle(theme.ink)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 92, maxHeight: 150)
                            .padding(8)
                            .background(theme.panel, in: inputShape)
                            .overlay(inputShape.strokeBorder(theme.line, lineWidth: 1))
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        Text(copy.settingsWebCacheExemptHostsPreserveNote(theme.id))
                            .font(SettingsType.rowSubtitle(theme))
                            .foregroundStyle(theme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                        if !exemptHostsDraft.isEmpty,
                           WebCacheHostPattern.editorValues(exemptHostsDraft) == nil {
                            Text(copy.settingsWebCacheExemptHostsInvalid(theme.id))
                                .font(SettingsType.rowSubtitle(theme))
                                .foregroundStyle(theme.warn)
                        }
                        settingsSaveButton(copy.settingsWebCacheSaveHosts(theme.id),
                                           isBusy: busyAction == "hosts") {
                            Task { await saveExemptHosts() }
                        }
                    }
                    .modifier(SettingsRowChrome(theme: theme, isLast: true))
                }
            } else {
                SettingsGroup(theme: theme) {
                    SettingsRow(theme: theme,
                                title: copy.settingsWebCacheExemptHosts(theme.id),
                                subtitle: copy.settingsWebCacheRawValueNote(
                                    theme.id, key: "web.cache_exempt_hosts"),
                                value: copy.settingsWebCachePreserved(theme.id),
                                valueTone: theme.warn, isLast: true)
                }
            }
        }
    }

    // MARK: Browser snapshots

    private var browserSnapshotSection: some View {
        SettingsSection(theme: theme, title: copy.settingsBrowserSnapshotSection(theme.id),
                        footnote: copy.settingsBrowserSnapshotFootnote(theme.id)) {
            if let configuration {
                SettingsGroup(theme: theme) {
                    snapshotThresholdRow(configuration, isLast: true)
                }
            } else {
                SettingsGroup(theme: theme) {
                    SettingsRow(theme: theme,
                                title: copy.settingsBrowserSnapshotThreshold(theme.id),
                                subtitle: unavailableSubtitle,
                                value: isLoading ? copy.settingsLoading(theme.id) : nil,
                                valueTone: theme.faint, isLast: true)
                }
            }
        }
        .disabled(busyAction != nil)
        .opacity(busyAction == nil ? 1 : 0.62)
    }

    @ViewBuilder
    private func snapshotThresholdRow(_ configuration: WebCacheConfiguration,
                                      isLast: Bool) -> some View {
        if let current = configuration.snapshotThreshold.value {
            settingTextRow(title: copy.settingsBrowserSnapshotThreshold(theme.id),
                           subtitle: copy.settingsBrowserSnapshotThresholdNote(theme.id),
                           text: $snapshotThresholdDraft,
                           prompt: String(current),
                           actionTitle: copy.settingsBrowserSnapshotSave(theme.id),
                           isBusy: busyAction == "snapshot", isLast: isLast) {
                Task { await saveSnapshotThreshold() }
            }
        } else {
            SettingsRow(theme: theme,
                        title: copy.settingsBrowserSnapshotThreshold(theme.id),
                        subtitle: copy.settingsWebCacheRawValueNote(
                            theme.id, key: "browser.snapshot_threshold"),
                        value: copy.settingsWebCachePreserved(theme.id),
                        valueTone: theme.warn, isLast: isLast)
        }
    }

    private var inputShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.inputRadius, style: .continuous)
    }

    private func settingTextRow(title: String, subtitle: String, text: Binding<String>,
                                prompt: String, actionTitle: String, isBusy: Bool,
                                isLast: Bool, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(SettingsType.rowTitle(theme)).foregroundStyle(theme.ink)
            Text(subtitle).font(SettingsType.rowSubtitle(theme)).foregroundStyle(theme.sub)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField(prompt, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(theme.mono(11))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                    #endif
                settingsSaveButton(actionTitle, isBusy: isBusy, action: action)
            }
        }
        .modifier(SettingsRowChrome(theme: theme, isLast: isLast))
    }

    private func settingsSaveButton(_ title: String, isBusy: Bool,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView().controlSize(.small).tint(theme.accentFg)
                } else {
                    Text(title).font(theme.mono(9.5, weight: .bold)).tracking(0.5)
                }
            }
            .foregroundStyle(theme.accentFg)
            .frame(minWidth: 64)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(theme.accent, in: RoundedRectangle(cornerRadius: theme.buttonRadius,
                                                            style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy ? 0.65 : 1)
    }

    // MARK: Read and writes

    private var unavailableSubtitle: String {
        if model.mode != .live { return copy.settingsWebCacheLiveOnly(theme.id) }
        return noticeIsWarning ? (notice ?? copy.settingsWebCacheLoadNote(theme.id))
            : copy.settingsWebCacheLoadNote(theme.id)
    }

    private func resetForScope(_ key: String) {
        generation &+= 1
        stateScopeKey = key
        configuration = nil
        isLoading = false
        busyAction = nil
        notice = nil
        noticeIsWarning = false
        ttlDraft = ""
        snapshotThresholdDraft = ""
        exemptHostsDraft = ""
    }

    private func loadScope(_ requestedKey: String) async {
        if stateScopeKey != requestedKey { resetForScope(requestedKey) }
        let scope = capturedScope()
        guard scope.key == requestedKey else { return }
        guard model.mode == .live else { return }

        isLoading = true
        defer { if owns(scope) { isLoading = false } }
        do {
            let client = try await targetClient(gatewayID: scope.gatewayID)
            guard owns(scope) else { return }
            let loaded = try await client.webCacheConfiguration(profile: scope.profile)
            guard owns(scope) else { return }
            configuration = loaded
            if let value = loaded.cacheTTLMinutes.value {
                ttlDraft = WebCacheTTLMinutesValue.editorText(value)
            }
            if let value = loaded.snapshotThreshold.value { snapshotThresholdDraft = String(value) }
            if let values = loaded.cacheExemptHosts.values {
                exemptHostsDraft = values.joined(separator: "\n")
            }
            notice = nil
            noticeIsWarning = false
        } catch {
            guard owns(scope) else { return }
            notice = error.localizedDescription
            noticeIsWarning = true
        }
    }

    private func setCacheEnabled(_ enabled: Bool) async {
        guard busyAction == nil, configuration?.cacheEnabled.isManaged == true else { return }
        let scope = capturedScope()
        busyAction = "enabled"
        notice = nil
        noticeIsWarning = false
        defer { if owns(scope) { busyAction = nil } }
        do {
            let client = try await targetClient(gatewayID: scope.gatewayID)
            guard owns(scope), configuration?.cacheEnabled.isManaged == true else { return }
            try await client.setWebCacheEnabled(enabled, profile: scope.profile)
            guard owns(scope) else { return }
            configuration?.apply(cacheEnabled: enabled)
            setNotice(copy.settingsWebCacheSavedEnabled(theme.id, enabled: enabled), warning: false)
        } catch {
            guard owns(scope) else { return }
            setNotice(error.localizedDescription, warning: true)
        }
    }

    private func saveTTL() async {
        guard busyAction == nil, configuration?.cacheTTLMinutes.isManaged == true else { return }
        guard let value = WebCacheTTLMinutesValue.parseEditorValue(ttlDraft) else {
            setNotice(copy.settingsWebCacheTTLInvalid(theme.id), warning: true)
            return
        }
        let scope = capturedScope()
        busyAction = "ttl"
        notice = nil
        noticeIsWarning = false
        defer { if owns(scope) { busyAction = nil } }
        do {
            let client = try await targetClient(gatewayID: scope.gatewayID)
            guard owns(scope), configuration?.cacheTTLMinutes.isManaged == true else { return }
            try await client.setWebCacheTTLMinutes(value, profile: scope.profile)
            guard owns(scope) else { return }
            configuration?.apply(cacheTTLMinutes: value)
            ttlDraft = WebCacheTTLMinutesValue.editorText(value)
            setNotice(copy.settingsWebCacheTTLSaved(theme.id), warning: false)
        } catch {
            guard owns(scope) else { return }
            setNotice(error.localizedDescription, warning: true)
        }
    }

    private func saveExemptHosts() async {
        guard busyAction == nil, configuration?.cacheExemptHosts.isManaged == true else { return }
        guard let values = WebCacheHostPattern.editorValues(exemptHostsDraft) else {
            setNotice(copy.settingsWebCacheExemptHostsInvalid(theme.id), warning: true)
            return
        }
        let scope = capturedScope()
        busyAction = "hosts"
        notice = nil
        noticeIsWarning = false
        defer { if owns(scope) { busyAction = nil } }
        do {
            let client = try await targetClient(gatewayID: scope.gatewayID)
            guard owns(scope), configuration?.cacheExemptHosts.isManaged == true else { return }
            try await client.setWebCacheExemptHosts(values, profile: scope.profile)
            guard owns(scope) else { return }
            configuration?.apply(cacheExemptHosts: values)
            // `values` came from the exact editor text with no normalization.
            exemptHostsDraft = values.joined(separator: "\n")
            setNotice(copy.settingsWebCacheHostsSaved(theme.id), warning: false)
        } catch {
            guard owns(scope) else { return }
            setNotice(error.localizedDescription, warning: true)
        }
    }

    private func saveSnapshotThreshold() async {
        guard busyAction == nil, configuration?.snapshotThreshold.isManaged == true else { return }
        guard let value = BrowserSnapshotThresholdValue.parseEditorValue(snapshotThresholdDraft) else {
            setNotice(copy.settingsBrowserSnapshotInvalid(theme.id), warning: true)
            return
        }
        let scope = capturedScope()
        busyAction = "snapshot"
        notice = nil
        noticeIsWarning = false
        defer { if owns(scope) { busyAction = nil } }
        do {
            let client = try await targetClient(gatewayID: scope.gatewayID)
            guard owns(scope), configuration?.snapshotThreshold.isManaged == true else { return }
            try await client.setBrowserSnapshotThreshold(value, profile: scope.profile)
            guard owns(scope) else { return }
            configuration?.apply(snapshotThreshold: value)
            snapshotThresholdDraft = String(value)
            setNotice(copy.settingsBrowserSnapshotSaved(theme.id), warning: false)
        } catch {
            guard owns(scope) else { return }
            setNotice(error.localizedDescription, warning: true)
        }
    }

    private func targetClient(gatewayID: String?) async throws -> GatewayClient {
        if let gatewayID { return try await model.routedClient(gatewayID: gatewayID) }
        if let client = model.client { return client }
        throw AppModel.GatewayRouteError.noRoute
    }

    private func setNotice(_ message: String?, warning: Bool) {
        notice = message
        noticeIsWarning = warning
    }
}

/// The operation fence deliberately compares source, profile, and generation.
/// A matching profile name on a different saved gateway is never interchangeable.
struct WebCacheSettingsScope: Equatable, Sendable {
    var gatewayID: String?
    var profile: String?
    var generation: Int

    var key: String { Self.key(gatewayID: gatewayID, profile: profile) }

    static func key(gatewayID: String?, profile: String?) -> String {
        "\(gatewayID ?? "__demo__")\u{1F}\(profile ?? "__gateway__")"
    }
}

enum WebCacheSettingsScopeFence {
    static func accepts(current: WebCacheSettingsScope, captured: WebCacheSettingsScope) -> Bool {
        current.gatewayID == captured.gatewayID
            && current.profile == captured.profile
            && current.generation == captured.generation
    }
}

public extension CopyPack {
    func settingsWebCacheGateway(_ t: ThemeID) -> String {
        t == .control ? "WEB CACHE GATEWAY" : "Web cache gateway"
    }
    func settingsWebCacheGatewayNote(_ t: ThemeID) -> String {
        t == .control ? "SELECT THE GATEWAY THAT OWNS THIS CONFIGURATION."
            : "Choose the gateway that owns this configuration."
    }
    func settingsWebCacheScope(_ t: ThemeID) -> String {
        t == .control ? "PROFILE SCOPE" : "Profile scope"
    }
    func settingsWebCacheScopeNote(_ t: ThemeID) -> String {
        t == .control ? "WRITES APPLY ONLY TO THE CAPTURED PROFILE OR GATEWAY DEFAULT."
            : "Writes apply only to the selected profile or the gateway default."
    }
    func settingsWebCacheSection(_ t: ThemeID) -> String {
        t == .control ? "WEB RESULT CACHE" : "Web result cache"
    }
    func settingsWebCacheNote(_ t: ThemeID) -> String {
        t == .control
            ? "CONTROLS SEARCH + EXTRACT CACHES. POLICY AND PROVIDER GATES STILL RUN ON EVERY CALL."
            : "Controls Hermes' web-search and web-extract result caches. Safety policy and provider gates still run on every call."
    }
    func settingsWebCacheUnavailable(_ t: ThemeID) -> String {
        t == .control ? "WEB CACHE CONFIGURATION" : "Web cache configuration"
    }
    func settingsWebCacheLiveOnly(_ t: ThemeID) -> String {
        t == .control ? "CONNECT A LIVE GATEWAY TO READ OR CHANGE ITS CONFIGURATION."
            : "Connect a live gateway to read or change its configuration."
    }
    func settingsWebCacheLoadNote(_ t: ThemeID) -> String {
        t == .control ? "THE SELECTED GATEWAY HAS NOT RETURNED /api/config YET."
            : "The selected gateway has not returned /api/config yet."
    }
    func settingsWebCacheEnabled(_ t: ThemeID) -> String {
        t == .control ? "CACHE WEB RESULTS" : "Cache web results"
    }
    func settingsWebCacheEnabledNote(_ t: ThemeID) -> String {
        t == .control ? "DISABLES BOTH SEARCH MEMO AND EXTRACT CACHE WHEN OFF."
            : "When off, Hermes bypasses both the search memo and extract cache."
    }
    func settingsWebCacheTTL(_ t: ThemeID) -> String {
        t == .control ? "FRESHNESS WINDOW (MINUTES)" : "Freshness window (minutes)"
    }
    func settingsWebCacheTTLNote(_ t: ThemeID) -> String {
        t == .control ? "FINITE NUMBER FROM 1 THROUGH 1440. HERMES CLAMPS THE RUNTIME VALUE TO THIS RANGE."
            : "Enter a finite number from 1 through 1,440. Hermes clamps its runtime value to this range."
    }
    func settingsWebCacheSaveTTL(_ t: ThemeID) -> String { t == .control ? "SAVE TTL" : "Save" }
    func settingsWebCacheTTLInvalid(_ t: ThemeID) -> String {
        t == .control ? "ENTER A FINITE NUMBER FROM 1 THROUGH 1440."
            : "Enter a finite number from 1 through 1,440."
    }
    func settingsWebCacheTTLSaved(_ t: ThemeID) -> String {
        t == .control ? "WEB CACHE TTL SAVED" : "Web cache freshness window saved."
    }
    func settingsWebCacheExemptHosts(_ t: ThemeID) -> String {
        t == .control ? "ALWAYS FETCH LIVE" : "Always fetch live"
    }
    func settingsWebCacheExemptHostsNote(_ t: ThemeID) -> String {
        t == .control
            ? "ONE HOST OR LEADING *. GLOB PER LINE. MATCHES EXACTLY OR BY LABEL-BOUNDARY SUFFIX."
            : "One host or leading *. glob per line. Hermes matches exact hosts and label-boundary suffixes."
    }
    func settingsWebCacheExemptHostsInput(_ t: ThemeID) -> String {
        t == .control ? "HOSTS / GLOBS" : "Hosts / globs"
    }
    func settingsWebCacheExemptHostsPreserveNote(_ t: ThemeID) -> String {
        t == .control
            ? "ENTRIES ARE SENT IN THE SAME ORDER, CASE, AND DUPLICITY. TALARIA NEVER TRIMS, LOWERS, SORTS, OR DEDUPES THEM."
            : "Entries keep their order, case, and duplicates. Talaria never trims, lowercases, sorts, or deduplicates them."
    }
    func settingsWebCacheExemptHostsInvalid(_ t: ThemeID) -> String {
        t == .control ? "USE ASCII HOST LABELS OR A LEADING *. GLOB; NO URL, PORT, PATH, WHITESPACE, OR EMPTY LINE."
            : "Use ASCII host labels or a leading *. glob; no URL, port, path, whitespace, or empty line."
    }
    func settingsWebCacheSaveHosts(_ t: ThemeID) -> String { t == .control ? "SAVE LIVE HOSTS" : "Save hosts" }
    func settingsWebCacheHostsSaved(_ t: ThemeID) -> String {
        t == .control ? "LIVE-FETCH HOST LIST SAVED" : "Always-live host list saved."
    }
    func settingsWebCacheRawValueNote(_ t: ThemeID, key: String) -> String {
        t == .control
            ? "THE GATEWAY RETURNED A NON-CANONICAL \(key) VALUE. TALARIA LEAVES THE RAW VALUE UNCHANGED."
            : "The gateway returned a non-canonical \(key) value, so Talaria leaves the raw value unchanged."
    }
    func settingsWebCachePreserved(_ t: ThemeID) -> String {
        t == .control ? "PRESERVED" : "Preserved"
    }
    func settingsWebCacheSavedEnabled(_ t: ThemeID, enabled: Bool) -> String {
        if t == .control { return enabled ? "WEB RESULT CACHE ENABLED" : "WEB RESULT CACHE DISABLED" }
        return enabled ? "Web result caching enabled." : "Web result caching disabled."
    }
    func settingsBrowserSnapshotSection(_ t: ThemeID) -> String {
        t == .control ? "BROWSER SNAPSHOTS" : "Browser snapshots"
    }
    func settingsBrowserSnapshotFootnote(_ t: ThemeID) -> String {
        t == .control
            ? "APPLIES TO EXPLICIT + POST-NAVIGATION SNAPSHOTS, INCLUDING CAMOFOX. CURRENT BROWSER CONFIG IS CACHED UNTIL SESSION CLEANUP/RESTART."
            : "Applies to explicit and post-navigation snapshots, including Camofox. Hermes caches browser configuration until the current browser session is cleaned up or restarted."
    }
    func settingsBrowserSnapshotThreshold(_ t: ThemeID) -> String {
        t == .control ? "INLINE SNAPSHOT CHARACTER BUDGET" : "Inline snapshot character budget"
    }
    func settingsBrowserSnapshotThresholdNote(_ t: ThemeID) -> String {
        t == .control ? "WHOLE NUMBER OF AT LEAST 1000. LARGER TREES TRUNCATE AT LINE BOUNDARIES AND SAVE A READ_FILE POINTER."
            : "Enter a whole number of at least 1,000. Larger trees truncate at line boundaries and include a read_file pointer."
    }
    func settingsBrowserSnapshotSave(_ t: ThemeID) -> String { t == .control ? "SAVE BUDGET" : "Save" }
    func settingsBrowserSnapshotInvalid(_ t: ThemeID) -> String {
        t == .control ? "ENTER A WHOLE NUMBER OF AT LEAST 1000."
            : "Enter a whole number of at least 1,000."
    }
    func settingsBrowserSnapshotSaved(_ t: ThemeID) -> String {
        t == .control ? "BROWSER SNAPSHOT BUDGET SAVED" : "Browser snapshot budget saved."
    }
}
