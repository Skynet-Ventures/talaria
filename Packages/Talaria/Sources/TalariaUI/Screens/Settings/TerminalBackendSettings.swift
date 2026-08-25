import SwiftUI
import TalariaKit
import TalariaTheme

/// The exact host/profile source whose terminal configuration is being shown.
/// A raw profile name is not enough: two retained gateways may both have a
/// `research` profile, and terminal changes must never cross that boundary.
struct TerminalBackendSource: Equatable, Sendable {
    var gatewayID: String
    var profile: String

    var key: String {
        "\(gatewayID.utf8.count):\(gatewayID)\u{1f}\(profile.utf8.count):\(profile)"
    }
}

/// Pure admission rule for an action made from a catalog response. Keeping it
/// separate from the view makes the source/profile/generation fence auditable:
/// a delayed read or write can never make a currently selected control target
/// a different gateway/profile or a row from an older catalog.
enum TerminalBackendSelectionPolicy {
    static func matchesSnapshot(snapshotSource: TerminalBackendSource?,
                                snapshotGeneration: Int?,
                                currentSource: TerminalBackendSource?,
                                currentGeneration: Int) -> Bool {
        guard let snapshotSource, let snapshotGeneration else { return false }
        return snapshotSource == currentSource && snapshotGeneration == currentGeneration
    }

    static func admits(backendName: String, catalog: TerminalBackendCatalog?,
                       snapshotSource: TerminalBackendSource?, snapshotGeneration: Int?,
                       currentSource: TerminalBackendSource?, currentGeneration: Int) -> Bool {
        guard let catalog,
              matchesSnapshot(
                  snapshotSource: snapshotSource,
                  snapshotGeneration: snapshotGeneration,
                  currentSource: currentSource,
                  currentGeneration: currentGeneration
              ) else {
            return false
        }
        return catalog.admittedBackend(named: backendName) != nil
    }
}

private struct TerminalBackendSnapshot {
    var id = UUID()
    var source: TerminalBackendSource
    var generation: Int
    /// Retaining the exact client lets the view reject a response from a
    /// replaced gateway connection even if its user-facing id stayed stable.
    var client: GatewayClient
    var catalog: TerminalBackendCatalog
}

/// Phone-safe terminal environment settings. Hermes performs host plug-in
/// discovery and readiness probes; Talaria only renders its authenticated,
/// profile-scoped response and sends a selected row back to that same source.
public struct TerminalBackendSettingsSection: View {
    private let model: AppModel

    public init(model: AppModel) { self.model = model }

    private var theme: ThemePack { model.theme.pack }

    @State private var selectedGatewayID: String?
    @State private var selectedProfile: String?
    @State private var stateSource: TerminalBackendSource?
    @State private var generation = 0
    @State private var snapshot: TerminalBackendSnapshot?
    @State private var configuredSharedContainerKey = ""
    @State private var sharedContainerKeyDraft = ""
    @State private var isLoading = false
    @State private var busyAction: String?
    @State private var notice: String?
    @State private var noticeIsWarning = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if gatewayChoices.count > 1 { gatewayPicker }
            profilePicker
            backendSection
            sharedDockerIdentitySection
            if let notice {
                Text(notice)
                    .font(theme.mono(10.5))
                    .foregroundStyle(noticeIsWarning ? theme.warn : theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: scopeKey) { await load(source: targetSource) }
    }

    // MARK: Source scope

    private var gatewayChoices: [SavedGateway] {
        model.mode == .live ? ConnectionRegistry.shared.saved : []
    }

    private var targetGatewayID: String? {
        GatewaySettingsTargetFence.resolve(
            selected: selectedGatewayID,
            available: Set(gatewayChoices.map(\.id)),
            active: model.activeGatewayID,
            runtime: LiveRuntime.shared.gatewayID
        )
    }

    private var profileChoices: [Bot] {
        let target = targetGatewayID
        return model.unionRosterBots.filter { bot in
            if let route = model.profileRoute(for: bot.id) {
                return route.gatewayID == target
            }
            return target == model.activeGatewayID
        }
    }

    private func profileName(for bot: Bot) -> String {
        model.profileRoute(for: bot.id)?.profile ?? bot.id
    }

    private var targetProfile: String? {
        let available = profileChoices.map(profileName).filter { !$0.isEmpty }
        if let selectedProfile, available.contains(selectedProfile) { return selectedProfile }
        return available.first
    }

    private var targetSource: TerminalBackendSource? {
        guard let gatewayID = targetGatewayID,
              let profile = targetProfile,
              !gatewayID.isEmpty,
              !profile.isEmpty else {
            return nil
        }
        return TerminalBackendSource(gatewayID: gatewayID, profile: profile)
    }

    private var scopeKey: String {
        guard let source = targetSource else { return "terminal:no-source" }
        return "terminal:\(source.key)\u{1f}\(model.mode == .live ? "live" : "demo")"
    }

    private var gatewayPicker: some View {
        SettingsSection(
            theme: theme,
            title: theme.id == .control ? "TERMINAL HOST" : "Terminal gateway",
            footnote: "The selected gateway performs all terminal discovery and readiness checks."
        ) {
            SettingsGroup(theme: theme) {
                Picker("Terminal gateway", selection: Binding(
                    get: { targetGatewayID },
                    set: { selectedGatewayID = $0; selectedProfile = nil }
                )) {
                    ForEach(gatewayChoices) { gateway in
                        Text(gateway.name + (gateway.id == model.activeGatewayID ? " · active" : ""))
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
        SettingsSection(
            theme: theme,
            title: theme.id == .control ? "PROFILE SCOPE" : "Terminal profile",
            footnote: "Both the backend and Docker container identity apply only to this Hermes profile."
        ) {
            SettingsGroup(theme: theme) {
                if profileChoices.isEmpty {
                    SettingsRow(
                        theme: theme,
                        title: model.mode == .live ? "No profile is available" : "Connect a gateway to manage terminal settings",
                        subtitle: model.mode == .live
                            ? "Refresh the selected gateway's profile roster, then try again."
                            : "Terminal backends are configured on a live Hermes gateway.",
                        isLast: true
                    )
                } else {
                    Picker("Terminal profile", selection: Binding(
                        get: { targetProfile },
                        set: { selectedProfile = $0 }
                    )) {
                        ForEach(profileChoices) { bot in
                            Text(bot.displayTitle).tag(Optional(profileName(for: bot)))
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(theme.accent)
                    .padding(10)
                }
            }
        }
    }

    // MARK: Backend catalog

    private var backendSection: some View {
        SettingsSection(
            theme: theme,
            title: theme.id == .control ? "TERMINAL BACKEND" : "Terminal environment",
            footnote: "Rows come from the selected gateway's current terminal registry. Talaria does not load host plug-ins or keep a built-in backend list."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                SettingsGroup(theme: theme) {
                    if isLoading {
                        SettingsRow(theme: theme, title: "Reading terminal backends…", isLast: true)
                    } else if let snapshot, isSnapshotCurrent(snapshot) {
                        ForEach(Array(snapshot.catalog.backends.enumerated()), id: \.element.id) {
                            index, backend in
                            backendRow(
                                backend,
                                snapshot: snapshot,
                                isLast: index == snapshot.catalog.backends.count - 1
                            )
                        }
                    } else {
                        SettingsRow(
                            theme: theme,
                            title: targetSource == nil ? "Choose a terminal profile" : "Terminal backends are unavailable",
                            subtitle: targetSource == nil
                                ? "A profile-specific source is required before Talaria can read or change a backend."
                                : "Refresh to read this gateway's current terminal catalog.",
                            isLast: true
                        )
                    }
                }

                SettingsGroup(theme: theme) {
                    SettingsActionRow(
                        theme: theme,
                        title: "Refresh terminal backends",
                        subtitle: "Re-reads readiness and current backend from the selected gateway.",
                        isBusy: isLoading,
                        isLast: true
                    ) {
                        Task { await load(source: targetSource) }
                    }
                    .disabled(targetSource == nil || busyAction != nil || model.mode != .live)
                }
            }
        }
        .opacity(model.mode == .live ? 1 : 0.55)
    }

    private func backendRow(_ backend: TerminalBackend,
                            snapshot: TerminalBackendSnapshot,
                            isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(backend.label)
                        .font(SettingsType.rowTitle(theme))
                        .foregroundStyle(theme.ink)
                    if !backend.description.isEmpty {
                        Text(backend.description)
                            .font(SettingsType.rowSubtitle(theme))
                            .foregroundStyle(theme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Text(backend.active ? "ACTIVE · \(statusLabel(backend.status))"
                                    : statusLabel(backend.status))
                    .font(theme.mono(9.5))
                    .foregroundStyle(backend.active ? theme.accent : statusColor(backend.status))
                    .multilineTextAlignment(.trailing)
            }

            if !backend.detail.isEmpty {
                Text(backend.detail)
                    .font(theme.mono(9.5))
                    .foregroundStyle(backend.status == .unavailable ? theme.warn : theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !backend.active, backend.status.isSelectable {
                Button(backend.status == .needsSetup ? "Select anyway" : "Use this backend") {
                    Task { await selectBackend(named: backend.name) }
                }
                .buttonStyle(.bordered)
                .tint(theme.accent)
                .disabled(busyAction != nil || !isSnapshotCurrent(snapshot))
            }
        }
        .modifier(SettingsRowChrome(theme: theme, isLast: isLast))
        .opacity(backend.status == .unavailable ? 0.72 : 1)
    }

    private func statusLabel(_ status: TerminalBackendStatus) -> String {
        switch status {
        case .ready: "READY"
        case .needsSetup: "NEEDS SETUP"
        case .unavailable: "UNAVAILABLE"
        }
    }

    private func statusColor(_ status: TerminalBackendStatus) -> Color {
        switch status {
        case .ready: theme.ok
        case .needsSetup: theme.warn
        case .unavailable: theme.danger
        }
    }

    // MARK: Shared Docker identity

    private var requestedSharedContainerKey: String { sharedContainerKeyDraft }

    private var sharedContainerKeyIsValid: Bool {
        let value = requestedSharedContainerKey
        if value.isEmpty { return true }
        return value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.unicodeScalars.count <= 256
            && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    private var canSaveSharedContainerKey: Bool {
        guard let snapshot, isSnapshotCurrent(snapshot), busyAction == nil else { return false }
        return sharedContainerKeyIsValid
            && requestedSharedContainerKey != configuredSharedContainerKey
    }

    private var sharedDockerIdentitySection: some View {
        SettingsSection(
            theme: theme,
            title: theme.id == .control ? "SHARED DOCKER IDENTITY" : "Shared Docker identity",
            footnote: "This setting is written through Hermes' guarded profile-scoped config API. Other terminal configuration is not replaced."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                SettingsGroup(theme: theme) {
                    SettingsRow(
                        theme: theme,
                        title: "Current container identity",
                        subtitle: configuredSharedContainerKey.isEmpty
                            ? "Profile-isolated (the default)"
                            : "Shared with profiles that use this exact key",
                        value: configuredSharedContainerKey.isEmpty ? "ISOLATED" : "SHARED",
                        valueTone: configuredSharedContainerKey.isEmpty ? theme.ok : theme.warn,
                        isLast: false
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Shared container key (optional)")
                            .font(SettingsType.rowTitle(theme))
                            .foregroundStyle(theme.ink)
                        TextField("Leave blank for profile isolation", text: $sharedContainerKeyDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(theme.mono(11))
                            .autocorrectionDisabled()
                        Text("The same non-empty key is the only way profiles intentionally share a persistent Docker identity.")
                            .font(SettingsType.rowSubtitle(theme))
                            .foregroundStyle(theme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .modifier(SettingsRowChrome(theme: theme, isLast: true))
                }

                if !requestedSharedContainerKey.isEmpty {
                    Text("Trust warning: every profile on this gateway that uses this exact key can reuse one persistent Docker container, workspace, and cache. Use it only for profiles you trust to share execution identity.")
                        .font(theme.mono(10))
                        .foregroundStyle(theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .background(theme.warn.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                SettingsGroup(theme: theme) {
                    SettingsActionRow(
                        theme: theme,
                        title: requestedSharedContainerKey.isEmpty
                            ? "Restore profile isolation"
                            : "Save shared Docker identity",
                        subtitle: requestedSharedContainerKey.isEmpty
                            ? "Clears the shared key for future Docker containers. Existing containers are not deleted or relabeled."
                            : "Saves this key only for the selected profile.",
                        isBusy: busyAction == "shared-container-key",
                        isLast: true
                    ) {
                        Task { await saveSharedContainerKey() }
                    }
                    .disabled(!canSaveSharedContainerKey || model.mode != .live)
                }
            }
        }
        .opacity(model.mode == .live ? 1 : 0.55)
    }

    // MARK: Read/write fencing

    private func targetClient(for source: TerminalBackendSource) async throws -> GatewayClient {
        try await model.routedClient(gatewayID: source.gatewayID)
    }

    private func isCurrent(_ source: TerminalBackendSource, generation captured: Int) -> Bool {
        stateSource == source && targetSource == source && generation == captured
    }

    private func isSnapshotCurrent(_ snapshot: TerminalBackendSnapshot) -> Bool {
        stateSource == snapshot.source && TerminalBackendSelectionPolicy.matchesSnapshot(
            snapshotSource: snapshot.source,
            snapshotGeneration: snapshot.generation,
            currentSource: targetSource,
            currentGeneration: generation
        )
    }

    private func reset(source: TerminalBackendSource?) {
        generation &+= 1
        stateSource = source
        snapshot = nil
        configuredSharedContainerKey = ""
        sharedContainerKeyDraft = ""
        isLoading = false
        busyAction = nil
        notice = nil
        noticeIsWarning = false
    }

    private func load(source: TerminalBackendSource?, completionNotice: String? = nil) async {
        reset(source: source)
        guard let source else { return }
        let capturedGeneration = generation
        guard model.mode == .live else { return }

        isLoading = true
        defer {
            if isCurrent(source, generation: capturedGeneration) {
                isLoading = false
            }
        }

        do {
            let client = try await targetClient(for: source)
            guard isCurrent(source, generation: capturedGeneration) else { return }
            async let catalogRequest = client.terminalBackendCatalog(profile: source.profile)
            async let keyRequest = client.terminalDockerSharedContainerKey(profile: source.profile)
            let (catalog, key) = try await (catalogRequest, keyRequest)
            guard isCurrent(source, generation: capturedGeneration) else { return }

            // `routedClient` may have refreshed or replaced a connection while
            // the two reads were in flight. Never publish a catalog from an
            // old source client into a current-looking gateway/profile view.
            let currentClient = try await targetClient(for: source)
            guard currentClient === client,
                  isCurrent(source, generation: capturedGeneration) else {
                return
            }

            snapshot = TerminalBackendSnapshot(
                source: source,
                generation: capturedGeneration,
                client: client,
                catalog: catalog
            )
            // The raw key participates in Hermes' collision-resistant digest;
            // trimming it would silently select a different container.
            configuredSharedContainerKey = key
            sharedContainerKeyDraft = configuredSharedContainerKey
            setNotice(completionNotice, warning: false)
        } catch {
            guard isCurrent(source, generation: capturedGeneration) else { return }
            setNotice((error as? GatewayError)?.message ?? error.localizedDescription, warning: true)
        }
    }

    private func admittedSnapshot(named backendName: String)
        -> (snapshot: TerminalBackendSnapshot, backend: TerminalBackend)? {
        guard let snapshot,
              TerminalBackendSelectionPolicy.admits(
                  backendName: backendName,
                  catalog: snapshot.catalog,
                  snapshotSource: snapshot.source,
                  snapshotGeneration: snapshot.generation,
                  currentSource: targetSource,
                  currentGeneration: generation
              ),
              let backend = snapshot.catalog.admittedBackend(named: backendName) else {
            return nil
        }
        return (snapshot, backend)
    }

    private func operationIsCurrent(_ snapshot: TerminalBackendSnapshot,
                                    backendName: String? = nil) -> Bool {
        guard isSnapshotCurrent(snapshot), self.snapshot?.id == snapshot.id else { return false }
        guard let backendName else { return true }
        return TerminalBackendSelectionPolicy.admits(
            backendName: backendName,
            catalog: snapshot.catalog,
            snapshotSource: snapshot.source,
            snapshotGeneration: snapshot.generation,
            currentSource: targetSource,
            currentGeneration: generation
        )
    }

    private func selectBackend(named backendName: String) async {
        guard busyAction == nil,
              let captured = admittedSnapshot(named: backendName) else {
            if targetSource != nil {
                setNotice("Refresh terminal backends before selecting one.", warning: true)
            }
            return
        }
        let snapshot = captured.snapshot
        let backend = captured.backend
        busyAction = "backend:\(backend.name)"
        defer {
            if operationIsCurrent(snapshot, backendName: backend.name) {
                busyAction = nil
            }
        }

        do {
            let client = try await targetClient(for: snapshot.source)
            guard operationIsCurrent(snapshot, backendName: backend.name) else { return }
            guard client === snapshot.client else {
                await load(
                    source: snapshot.source,
                    completionNotice: "Gateway connection changed; terminal backends were refreshed."
                )
                return
            }
            _ = try await client.selectTerminalBackend(backend.name, profile: snapshot.source.profile)
            guard operationIsCurrent(snapshot, backendName: backend.name) else { return }
            await load(
                source: snapshot.source,
                completionNotice: backend.status == .needsSetup
                    ? "Selected \(backend.label). The gateway still reports setup is needed."
                    : "Selected \(backend.label)."
            )
        } catch {
            guard operationIsCurrent(snapshot, backendName: backend.name) else { return }
            setNotice((error as? GatewayError)?.message ?? error.localizedDescription, warning: true)
        }
    }

    private func saveSharedContainerKey() async {
        guard busyAction == nil,
              let snapshot,
              operationIsCurrent(snapshot),
              sharedContainerKeyIsValid,
              requestedSharedContainerKey != configuredSharedContainerKey else {
            return
        }
        let key = requestedSharedContainerKey
        busyAction = "shared-container-key"
        defer {
            if operationIsCurrent(snapshot) { busyAction = nil }
        }

        do {
            let client = try await targetClient(for: snapshot.source)
            guard operationIsCurrent(snapshot) else { return }
            guard client === snapshot.client else {
                await load(
                    source: snapshot.source,
                    completionNotice: "Gateway connection changed; terminal settings were refreshed."
                )
                return
            }
            try await client.setTerminalDockerSharedContainerKey(key, profile: snapshot.source.profile)
            guard operationIsCurrent(snapshot) else { return }
            configuredSharedContainerKey = key
            sharedContainerKeyDraft = key
            setNotice(
                key.isEmpty
                    ? "Profile isolation will apply to future Docker containers."
                    : "Saved a shared Docker identity for \(snapshot.source.profile).",
                warning: false
            )
        } catch {
            guard operationIsCurrent(snapshot) else { return }
            setNotice((error as? GatewayError)?.message ?? error.localizedDescription, warning: true)
        }
    }

    private func setNotice(_ text: String?, warning: Bool) {
        notice = text.flatMap { $0.isEmpty ? nil : $0 }
        noticeIsWarning = warning
    }
}
