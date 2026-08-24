import SwiftUI
import TalariaKit
import TalariaTheme

/// Phone-first counterpart to Hermes Desktop Settings → Messaging/Channels.
/// Pairing remains in Connections: this screen owns platform configuration and
/// health only, so approving who may DM a bot is never confused with storing a
/// platform credential.
public struct MessagingPlatformSettingsSection: View {
    private let model: AppModel
    @State private var lifecycle: MessagingPlatformLifecycleCoordinator
    @State private var selectedGatewayID: String?
    @State private var selectedProfile: String?
    @State private var selection: PlatformSelection?

    public init(model: AppModel) {
        self.model = model
        _lifecycle = State(initialValue: model.makeMessagingPlatformLifecycle())
    }

    private var theme: ThemePack { model.theme.pack }

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if gatewayChoices.count > 1 { gatewayPicker }
            if !profileChoices.isEmpty { profilePicker }
            platformList
            if let notice = lifecycle.notice {
                Text(notice)
                    .font(theme.mono(10.5))
                    .foregroundStyle(lifecycle.noticeIsWarning ? theme.warn : theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(notice))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: scopeKey) {
            lifecycle.select(gatewayID: targetGatewayID, profile: targetProfile)
            await lifecycle.refresh()
        }
        .onDisappear { lifecycle.tearDown() }
        .sheet(item: $selection) { selected in
            MessagingPlatformDetailSheet(model: model, lifecycle: lifecycle,
                                         platformID: selected.id)
                .presentationDragIndicator(.visible)
        }
    }

    private struct PlatformSelection: Identifiable { let id: String }

    private var gatewayChoices: [SavedGateway] {
        model.mode == .live ? ConnectionRegistry.shared.saved : []
    }

    private var targetGatewayID: String? {
        GatewaySettingsTargetFence.resolve(selected: selectedGatewayID,
                                           available: Set(gatewayChoices.map(\.id)),
                                           active: model.activeGatewayID,
                                           runtime: LiveRuntime.shared.gatewayID)
    }

    private var profileChoices: [(id: String, title: String)] {
        let gatewayID = targetGatewayID
        let rows: [(id: String, title: String)] = model.unionRosterBots.compactMap { bot -> (id: String, title: String)? in
            guard let route = model.profileRoute(for: bot.id),
                  route.gatewayID == gatewayID,
                  MessagingPlatformIdentityAdmission.profile(route.profile) == route.profile else {
                return nil
            }
            return (id: route.profile, title: bot.displayTitle)
        }
        var seen = Set<String>()
        return rows.filter { row in
            seen.insert(row.id).inserted
        }
    }

    private var targetProfile: String? {
        let ids = Set(profileChoices.map(\.id))
        if let selectedProfile, ids.contains(selectedProfile) { return selectedProfile }
        return profileChoices.first?.id
    }

    private var scopeKey: String {
        "\(targetGatewayID ?? "offline")\u{1f}\(targetProfile ?? "no-profile")"
    }

    private var gatewayPicker: some View {
        SettingsSection(theme: theme, title: "MESSAGING GATEWAY",
                        footnote: "Channels belong to one physical gateway. This picker never switches your active chat.") {
            SettingsGroup(theme: theme) {
                Picker("Gateway", selection: Binding(
                    get: { targetGatewayID },
                    set: { selectedGatewayID = $0; selectedProfile = nil })) {
                    ForEach(gatewayChoices) { gateway in
                        Text(gateway.name + (gateway.id == model.activeGatewayID ? " · active" : ""))
                            .tag(Optional(gateway.id))
                    }
                }
                .pickerStyle(.menu)
                .tint(theme.accent)
                .padding(10)
                .frame(minHeight: 44)
            }
        }
    }

    private var profilePicker: some View {
        SettingsSection(
            theme: theme, title: "MESSAGING PROFILE",
            footnote: "Direct-channel credentials and enablement are isolated to this exact Hermes profile. Relay routing is deployment-managed and process-wide."
        ) {
            SettingsGroup(theme: theme) {
                Picker("Profile", selection: Binding(
                    get: { targetProfile }, set: { selectedProfile = $0 })) {
                    ForEach(profileChoices, id: \.id) { row in
                        Text(row.title).tag(Optional(row.id))
                    }
                }
                .pickerStyle(.menu)
                .tint(theme.accent)
                .padding(10)
                .frame(minHeight: 44)
            }
        }
    }

    private var platformList: some View {
        SettingsSection(
            theme: theme, title: "MESSAGING PLATFORMS",
            footnote: "Pairing stays in Connections. Saving, enabling and checking are separate actions; Talaria never restarts a gateway automatically."
        ) {
            SettingsGroup(theme: theme) {
                if lifecycle.platforms.isEmpty {
                    SettingsRow(
                        theme: theme,
                        title: lifecycle.isLoading ? "Reading platforms…" : "No platforms available",
                        subtitle: emptySubtitle, isLast: true)
                } else {
                    ForEach(Array(lifecycle.platforms.enumerated()), id: \.element.id) { index, platform in
                        if platform.isDeploymentManaged {
                            SettingsRow(
                                theme: theme, title: platform.name,
                                subtitle: "Enrollment and routing belong to the gateway host or "
                                    + "orchestrator, not this profile.",
                                value: "Deployment managed", valueTone: theme.faint,
                                isLast: index == lifecycle.platforms.count - 1)
                            .frame(minHeight: 44)
                            .accessibilityHint(Text(
                                "Read only. Manage relay on the gateway deployment."
                            ))
                        } else {
                            SettingsRow(
                                theme: theme, title: platform.name,
                                subtitle: rowSubtitle(platform), value: rowValue(platform),
                                valueTone: rowTone(platform), showsChevron: true,
                                isLast: index == lifecycle.platforms.count - 1,
                                action: { selection = PlatformSelection(id: platform.id) })
                            .frame(minHeight: 44)
                            .accessibilityHint(Text("Opens channel configuration for \(platform.name)"))
                        }
                    }
                }
            }
            if targetProfile != nil {
                SettingsGroup(theme: theme) {
                    SettingsActionRow(
                        theme: theme, title: "Refresh platforms",
                        subtitle: "Read the selected profile again without changing the active chat.",
                        isBusy: lifecycle.isLoading, isLast: true
                    ) {
                        Task { await lifecycle.refresh() }
                    }
                }
            }
        }
    }

    private var emptySubtitle: String? {
        if model.mode != .live { return "Connect a gateway to manage its channels." }
        if targetProfile == nil { return "No exact profile is available on this gateway." }
        if lifecycle.unsupported { return "Update Hermes to expose the platform lifecycle API." }
        return lifecycle.isLoading ? nil : "Pull to retry after the gateway is reachable."
    }

    private func rowValue(_ platform: MessagingPlatform) -> String {
        if !platform.isEnabled { return "Off" }
        switch platform.state {
        case "connected": return "Connected"
        case "pending_restart": return "Restart needed"
        default: return platform.isConfigured ? "Configured" : "Setup needed"
        }
    }

    private func rowSubtitle(_ platform: MessagingPlatform) -> String? {
        if !platform.errorMessage.isEmpty { return platform.errorMessage }
        return platform.description.isEmpty ? nil : platform.description
    }

    private func rowTone(_ platform: MessagingPlatform) -> Color {
        if platform.state == "connected" { return theme.ok }
        if platform.isEnabled && !platform.isConfigured { return theme.warn }
        return theme.faint
    }
}

private struct MessagingPlatformDetailSheet: View {
    let model: AppModel
    let lifecycle: MessagingPlatformLifecycleCoordinator
    let platformID: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drafts: [String: String] = [:]
    @State private var clearCandidate: MessagingPlatformEnvironmentField?

    private var theme: ThemePack { model.theme.pack }
    private var platform: MessagingPlatform? {
        lifecycle.platforms.first(where: { $0.id == platformID })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let platform {
                        statusSection(platform)
                        credentialsSection(platform)
                        actionsSection(platform)
                        if platform.state == "pending_restart" { restartFollowUp(platform) }
                        if let notice = lifecycle.notice {
                            Text(notice)
                                .font(theme.mono(10.5))
                                .foregroundStyle(lifecycle.noticeIsWarning ? theme.warn : theme.sub)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("This platform is no longer present in the gateway snapshot.")
                            .foregroundStyle(theme.warn)
                    }
                }
                .padding(18)
            }
            .background(theme.bg)
            .navigationTitle(platform?.name ?? "Messaging platform")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(theme.accent)
                }
            }
        }
        .tint(theme.accent)
        .confirmationDialog(
            "Clear this credential?", isPresented: Binding(
                get: { clearCandidate != nil },
                set: { if !$0 { clearCandidate = nil } }),
            titleVisibility: .visible
        ) {
            if let field = clearCandidate {
                Button("Clear \(field.label)", role: .destructive) {
                    clearCandidate = nil
                    Task { _ = await lifecycle.clearCredential(platformID: platformID, key: field.key) }
                }
            }
            Button("Cancel", role: .cancel) { clearCandidate = nil }
        } message: {
            Text("The value is removed from this profile only. Other profiles and gateways are unchanged.")
        }
    }

    private func statusSection(_ platform: MessagingPlatform) -> some View {
        SettingsSection(theme: theme, title: "STATUS") {
            SettingsGroup(theme: theme) {
                SettingsRow(theme: theme, title: "Enabled",
                            value: platform.isEnabled ? "Yes" : "No")
                SettingsRow(theme: theme, title: "Credentials",
                            value: platform.isConfigured ? "Configured" : "Incomplete")
                SettingsRow(theme: theme, title: "Connection",
                            value: platform.state.replacingOccurrences(of: "_", with: " ").capitalized,
                            valueTone: platform.state == "connected" ? theme.ok : theme.faint,
                            isLast: true)
            }
            if !platform.errorMessage.isEmpty {
                Text(platform.errorMessage).font(theme.mono(10.5)).foregroundStyle(theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func credentialsSection(_ platform: MessagingPlatform) -> some View {
        SettingsSection(
            theme: theme, title: "CREDENTIALS",
            footnote: "Saved values are write-only and shown only as Configured. New entries stay in this sheet until sent, then are discarded."
        ) {
            if platform.environment.isEmpty {
                SettingsGroup(theme: theme) {
                    SettingsRow(theme: theme, title: "No credential fields declared",
                                subtitle: "This adapter is configured outside its platform card.", isLast: true)
                }
            } else {
                SettingsGroup(theme: theme) {
                    ForEach(Array(platform.environment.enumerated()), id: \.element.id) { index, field in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(field.label).font(SettingsType.rowTitle(theme)).foregroundStyle(theme.ink)
                                    Text(field.isConfigured ? "Configured" : (field.isRequired ? "Required" : "Optional"))
                                        .font(SettingsType.rowSubtitle(theme))
                                        .foregroundStyle(field.isConfigured ? theme.ok : theme.faint)
                                }
                                Spacer(minLength: 8)
                                if field.isConfigured {
                                    Button("Clear") { clearCandidate = field }
                                        .font(theme.mono(11)).foregroundStyle(theme.danger)
                                        .frame(minWidth: 44, minHeight: 44)
                                        .accessibilityLabel(Text("Clear \(field.label) credential"))
                                }
                            }
                            SecureField(field.isConfigured ? "Enter replacement" : "Enter value",
                                        text: draftBinding(field.key))
                                .textFieldStyle(.roundedBorder)
                                .frame(minHeight: 44)
                                .accessibilityLabel(Text("New \(field.label) credential"))
                            if !field.description.isEmpty {
                                Text(field.description).font(theme.mono(9.5)).foregroundStyle(theme.sub)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .modifier(SettingsRowChrome(
                            theme: theme, isLast: index == platform.environment.count - 1))
                    }
                }
                SettingsGroup(theme: theme) {
                    SettingsActionRow(
                        theme: theme, title: "Save credentials",
                        subtitle: "Writes only non-empty new values; blanks preserve saved credentials.",
                        isBusy: lifecycle.busyAction == "save:\(platform.id)", isLast: true
                    ) {
                        let submitted = drafts
                        Task {
                            if await lifecycle.saveCredentials(platformID: platform.id, values: submitted) {
                                drafts.removeAll()
                            }
                        }
                    }
                }
            }
        }
    }

    private func actionsSection(_ platform: MessagingPlatform) -> some View {
        SettingsSection(theme: theme, title: "LIFECYCLE") {
            SettingsGroup(theme: theme) {
                SettingsActionRow(
                    theme: theme,
                    title: platform.isEnabled ? "Disable platform" : "Enable platform",
                    subtitle: "Hermes confirms the resulting state; the row never changes optimistically.",
                    isDestructive: platform.isEnabled,
                    isBusy: lifecycle.busyAction == "enabled:\(platform.id)"
                ) {
                    Task { _ = await lifecycle.setEnabled(!platform.isEnabled, platformID: platform.id) }
                }
                SettingsActionRow(
                    theme: theme, title: "Check connection",
                    subtitle: "Reads the gateway's current configured, running and adapter state.",
                    isBusy: lifecycle.busyAction == "check:\(platform.id)", isLast: true
                ) {
                    Task { _ = await lifecycle.checkConnection(platformID: platform.id) }
                }
            }
            if let url = platform.documentationURL {
                SettingsGroup(theme: theme) {
                    SettingsLinkRow(theme: theme, title: "Platform documentation",
                                    subtitle: url.host, url: url, isLast: true)
                }
            }
        }
    }

    private func restartFollowUp(_ platform: MessagingPlatform) -> some View {
        SettingsSection(theme: theme, title: "RESTART REQUIRED") {
            SettingsGroup(theme: theme) {
                SettingsRow(
                    theme: theme, title: "Use Gateway Operations",
                    subtitle: "Hermes reports this adapter is pending restart. Talaria never restarts automatically; review active work, then use the existing fenced restart control in Gateway Operations.",
                    isLast: true)
            }
        }
        .transition(reduceMotion ? .identity : .opacity)
        .accessibilityElement(children: .combine)
    }

    private func draftBinding(_ key: String) -> Binding<String> {
        Binding(get: { drafts[key, default: ""] }, set: { drafts[key] = $0 })
    }
}
