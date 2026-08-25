import SwiftUI
import TalariaKit
import TalariaTheme

enum SettingsDestination: String, CaseIterable, Hashable, Identifiable {
    case connections
    case appearance
    case intelligence
    case agents
    case operations
    case workspace
    case localData
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connections: "Connections & Notifications"
        case .appearance: "Appearance & Conversation"
        case .intelligence: "Models, Voice & Memory"
        case .agents: "Agents & Profiles"
        case .operations: "Gateway Operations"
        case .workspace: "Command Center"
        case .localData: "On-device & Privacy"
        case .about: "About & Diagnostics"
        }
    }

    var subtitle: String {
        switch self {
        case .connections: "Gateways, APNs and notification routing"
        case .appearance: "Theme, text, motion and transcript detail"
        case .intelligence: "Inference providers, OAuth, voice and memory"
        case .agents: "Rename, delete and manage Hermes profiles"
        case .operations: "Restart, update, usage, runtime and logs"
        case .workspace: "Projects, files, review, commands and system"
        case .localData: "Solo mode, storage, exports and deletion"
        case .about: "Versions, health, links and desktop-only boundaries"
        }
    }

    var symbol: String {
        switch self {
        case .connections: "network"
        case .appearance: "paintpalette.fill"
        case .intelligence: "cpu.fill"
        case .agents: "person.2.fill"
        case .operations: "slider.horizontal.3"
        case .workspace: "square.grid.2x2"
        case .localData: "lock.iphone"
        case .about: "info.circle.fill"
        }
    }

    var keywords: String {
        switch self {
        case .connections: "gateway cloud tailscale push apns approval mention notification"
        case .appearance: "theme color font text size motion reduce tools reasoning transcript avatar"
        case .intelligence: "model provider oauth endpoint api key voice speech memory stt tts"
        case .agents: "bot profile rename delete lifecycle terminal backend docker sandbox"
        case .operations: "operator config logs debug level"
        case .workspace: "command center projects files git review commands system workspace directory preview pty terminal"
        case .localData: "solo offline storage cache privacy export delete reset"
        case .about: "version gateway health diagnostics source docs desktop"
        }
    }

    var presentsCommandCenter: Bool { self == .workspace }
}

// Settings — roadmap Phase 2.
//
// Raw YAML and environment editing do not belong on a phone. Dedicated,
// authenticated Hermes management APIs do: this surface exposes their typed
// mobile controls and leaves only host filesystem/process knobs to desktop.
//
// Sections, in the roadmap's order:
//   Gateways      — the connection registry, merged from Connections.
//   Appearance    — the three packs, text size, motion.
//   Notifications ┐
//   Models        ├ owned by Screens/Settings/, embedded directly below.
//   Voice         ┘
//   Privacy & data— measured local storage, and the verbs that undo it.
//   About         — versions, gateway contract, copyable diagnostics, links.
//
// Reached from the roster header and from Connections. Neither of those owns
// the screen graph, so both go through `AppModel.requestSettings()`, whose
// notification lands on `View.talariaSettings(model:)` at the bottom of this
// file — the same shape `requestCapabilities` already uses.

public struct SettingsView: View {
    private let model: AppModel
    private let onBack: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    public init(model: AppModel, onBack: (() -> Void)? = nil) {
        self.model = model
        self.onBack = onBack
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(filteredDestinations) { destination in
                        if destination.presentsCommandCenter {
                            Button {
                                model.requestCommandCenter()
                            } label: {
                                HStack(spacing: 10) {
                                    SettingsIndexRow(destination: destination, theme: theme)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(theme.faint)
                                        .accessibilityHidden(true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!WorkspaceCommandCenterRequest.allows(mode: model.mode))
                            .accessibilityHint(Text(
                                WorkspaceCommandCenterRequest.allows(mode: model.mode)
                                    ? "Opens the source-qualified workspace controls"
                                    : "Connect a live gateway to enable Command Center"
                            ))
                            .listRowBackground(theme.panel)
                        } else {
                            NavigationLink(value: destination) {
                                SettingsIndexRow(destination: destination, theme: theme)
                            }
                            .listRowBackground(theme.panel)
                        }
                    }
                } footer: {
                    Text("Settings are grouped by task. Nothing was removed; each row opens a focused surface.")
                        .foregroundStyle(theme.sub)
                }
            }
            .modifier(SettingsIndexListStyle())
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            .navigationTitle(copy.settingsTitle(theme.id))
            .searchable(text: $search, prompt: "Search settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    HeaderIconButton(theme: theme, size: 32, showsChrome: false, action: close) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(theme.id == .ink ? theme.ink : theme.accent)
                    }
                    .accessibilityLabel(Text(copy.settingsBack(theme.id)))
                }
            }
            .navigationDestination(for: SettingsDestination.self) { destination in
                SettingsDetailPage(model: model, destination: destination,
                                   onAddGateway: addGateway)
            }
        }
        .tint(theme.id == .ink ? theme.ink : theme.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
        // The picker in Appearance is live because the screen it lives on
        // adopts its own setting.
        .talariaTextSize(model)
        .task {
            // `desktop_contract` only ever rides a session.info payload, so the
            // watcher has to be listening before About can report it.
            model.attachSettingsDiagnostics()
            await model.refreshGatewayStatus()
        }
    }

    private var filteredDestinations: [SettingsDestination] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return SettingsDestination.allCases }
        return SettingsDestination.allCases.filter {
            ("\($0.title) \($0.subtitle) \($0.keywords)").lowercased().contains(query)
        }
    }

    private func close() {
        if let onBack { onBack() } else { dismiss() }
    }

    /// Connections owns the probe → PKCE sign-in flow and Hermes Cloud
    /// discovery; duplicating either here would be two sign-in paths to keep in
    /// step. Leave, then ask for that screen.
    private func addGateway() {
        if let onBack { onBack() } else { dismiss() }
        NotificationCenter.default.post(name: .talariaOpenConnections, object: nil)
    }
}

private struct SettingsIndexRow: View {
    let destination: SettingsDestination
    let theme: ThemePack

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: destination.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.accentFg)
                .frame(width: 32, height: 32)
                .background(theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.ink)
                Text(destination.subtitle)
                    .font(.caption)
                    .foregroundStyle(theme.sub)
                    .lineLimit(2)
            }
            .padding(.vertical, 3)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsDetailPage: View {
    let model: AppModel
    let destination: SettingsDestination
    let onAddGateway: () -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var reducedMotion: Bool {
        model.settings.prefersReducedMotion(system: systemReduceMotion)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch destination {
                case .connections:
                    GatewaySettingsSection(model: model, onAddGateway: onAddGateway)
                    NotificationSettingsSection(model: model)
                case .appearance:
                    AppearanceSettingsSection(model: model)
                case .intelligence:
                    ModelSettingsSection(model: model)
                    InferenceProviderSettingsSection(model: model)
                    VoiceSettingsSection(model: model)
                    MemoryProviderSettingsSection(model: model)
                case .agents:
                    ProfileLifecycleSettingsSection(model: model)
                    TerminalBackendSettingsSection(model: model)
                case .operations:
                    OperatorSettingsSection(model: model)
                case .workspace:
                    // The index renders this destination as a modal action, not
                    // a NavigationLink. Keep the switch exhaustive without
                    // mounting the legacy Files/Git page as a second entry.
                    EmptyView()
                case .localData:
                    SoloSettingsSection(model: model)
                    PrivacySettingsSection(model: model)
                case .about:
                    AboutSettingsSection(model: model)
                    DesktopPointerSection(theme: theme, copy: copy)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .settingsEntrance(delay: 0, reduced: reducedMotion)
        }
        .background(theme.bg)
        .navigationTitle(destination.title)
        .modifier(SettingsInlineNavigationTitle())
    }
}

private struct SettingsIndexListStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.listStyle(.insetGrouped)
        #else
        content.listStyle(.inset)
        #endif
    }
}

private struct SettingsInlineNavigationTitle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.navigationBarTitleDisplayMode(.inline)
        #else
        content
        #endif
    }
}

// MARK: - About & diagnostics

/// Versions, the gateway's contract, and one copyable block for a bug report.
/// Every row is either a fact the app knows or an honest dash — nothing here is
/// inferred, and a gateway that has not answered yet says so.
struct AboutSettingsSection: View {
    let model: AppModel

    @State private var didCopy = false

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    private static let repoURL = URL(string: "https://github.com/Skynet-Ventures/talaria")!
    private static let docsURL = URL(string: "https://github.com/Skynet-Ventures/talaria/tree/main/docs")!
    private static let upstreamURL = URL(string: "https://github.com/NousResearch/hermes-agent")!

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(theme: theme, title: copy.settingsAboutSec(theme.id), footnote: nil) {
                SettingsGroup(theme: theme) {
                    SettingsRow(theme: theme, title: copy.settingsAppVersion(theme.id),
                                value: AppModel.appVersionString)
                    SettingsRow(theme: theme, title: copy.settingsPlatform(theme.id),
                                value: AppModel.platformString,
                                isLast: gatewayRows.isEmpty)
                    ForEach(Array(gatewayRows.enumerated()), id: \.offset) { index, row in
                        SettingsRow(theme: theme, title: row.title,
                                    value: row.value, valueTone: row.tone,
                                    isLast: index == gatewayRows.count - 1)
                    }
                }
            }

            SettingsSection(theme: theme, title: copy.settingsDiagnosticsSec(theme.id),
                            footnote: copy.settingsDiagnosticsNote(theme.id)) {
                SettingsGroup(theme: theme) {
                    SettingsActionRow(theme: theme,
                                      title: didCopy ? copy.settingsCopied(theme.id)
                                                     : copy.settingsCopyDiagnostics(theme.id),
                                      isLast: true) {
                        copyToPasteboard(model.diagnosticsSummary())
                        didCopy = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            didCopy = false
                        }
                    }
                }
            }

            SettingsSection(theme: theme, title: copy.settingsLinksSec(theme.id), footnote: nil) {
                SettingsGroup(theme: theme) {
                    SettingsLinkRow(theme: theme, title: copy.settingsRepo(theme.id),
                                    subtitle: Self.repoURL.host(), url: Self.repoURL)
                    SettingsLinkRow(theme: theme, title: copy.settingsDocs(theme.id),
                                    subtitle: copy.settingsDocsNote(theme.id), url: Self.docsURL)
                    SettingsLinkRow(theme: theme, title: copy.settingsUpstream(theme.id),
                                    subtitle: copy.settingsUpstreamNote(theme.id),
                                    url: Self.upstreamURL, isLast: true)
                }
            }
        }
    }

    private struct AboutRow {
        var title: String
        var value: String
        var tone: Color?
    }

    /// Gateway facts, only for a gateway that exists. `desktop_contract` is
    /// reported as "—" until a session.info has carried one, because guessing a
    /// contract version is how a client ends up speaking the wrong protocol.
    private var gatewayRows: [AboutRow] {
        guard let gateway = model.liveGateway else { return [] }
        var rows: [AboutRow] = [
            AboutRow(title: copy.settingsGateway(theme.id),
                     value: ConnectionRegistry.address(for: gateway), tone: nil),
            AboutRow(title: copy.settingsLink(theme.id),
                     value: model.isOffline ? copy.linkDownTitle(theme.id)
                                            : copy.connActive(theme.id),
                     tone: model.isOffline ? theme.danger : theme.ok),
        ]
        if let diagnostics = model.liveGatewayDiagnostics {
            if let version = diagnostics.version, !version.isEmpty {
                rows.append(AboutRow(title: copy.settingsGatewayVersion(theme.id),
                                     value: "v\(version)", tone: nil))
            }
            rows.append(AboutRow(title: copy.settingsAuthMode(theme.id),
                                 value: copy.authModeLabel(diagnostics.authMode, theme.id),
                                 tone: nil))
            if let ping = diagnostics.pingMS {
                rows.append(AboutRow(title: copy.settingsPing(theme.id),
                                     value: "\(ping)ms", tone: nil))
            }
        }
        rows.append(AboutRow(title: copy.settingsContract(theme.id),
                             value: model.gatewayDesktopContract.map { "v\($0)" } ?? "—",
                             tone: nil))
        if let status = model.gatewayStatus {
            rows.append(AboutRow(title: copy.settingsHealth(theme.id),
                                 value: status.overall,
                                 tone: status.overall == "ok" ? theme.ok : theme.warn))
            rows.append(AboutRow(title: copy.settingsActiveAgents(theme.id),
                                 value: "\(status.activeAgents)", tone: nil))
        }
        return rows
    }
}

// MARK: - Managed on desktop

/// The honest end of the screen. These exist on desktop and are deliberately
/// not on the phone; naming them is better than letting somebody hunt.
struct DesktopPointerSection: View {
    let theme: ThemePack
    let copy: CopyPack

    var body: some View {
        SettingsSection(theme: theme,
                        title: copy.settingsDesktopSec(theme.id),
                        footnote: copy.settingsAskABot(theme.id)) {
            SettingsGroup(theme: theme) {
                let items = copy.settingsDesktopItems(theme.id)
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    SettingsRow(theme: theme, title: item.0, subtitle: item.1,
                                isLast: index == items.count - 1)
                }
            }
        }
    }
}

// MARK: - Presentation

/// Hosts the Settings screen for whoever owns the screen graph. Mount once,
/// next to the other overlays:
///
///     TalariaRootView(model: model)      // or the root ZStack inside it
///         .talariaSettings(model: model)
///
/// It listens for `AppModel.requestSettings()`, so the roster header and
/// Connections only have to call that — neither needs a binding threaded
/// through it, and neither has to know Settings exists.
public struct TalariaSettingsPresenter: ViewModifier {
    private let model: AppModel

    @State private var isPresented = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    public init(model: AppModel) { self.model = model }

    private var pushAnimation: Animation {
        model.settings.prefersReducedMotion(system: systemReduceMotion)
            ? .easeOut(duration: 0.15) : .easeOut(duration: 0.32)
    }

    public func body(content: Content) -> some View {
        content
            .overlay {
                if isPresented {
                    ZStack {
                        model.theme.pack.bg.ignoresSafeArea()
                        SettingsView(model: model) {
                            withAnimation(pushAnimation) { isPresented = false }
                        }
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(14)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .talariaOpenSettings)) { _ in
                guard !isPresented else { return }
                withAnimation(pushAnimation) { isPresented = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .talariaOpenConnections)) { _ in
                // Settings hands the add-gateway flow to Connections; it must
                // not stay stacked on top of the screen it just asked for.
                guard isPresented else { return }
                withAnimation(pushAnimation) { isPresented = false }
            }
            .onChange(of: model.showOnboarding) { _, showing in
                // "Delete local data" ends in onboarding, and onboarding is the
                // topmost surface in the app. An overlay mounted above the
                // screen graph would otherwise hide it.
                if showing, isPresented { isPresented = false }
            }
    }
}

public extension View {
    /// Mount the Settings screen on this view tree.
    func talariaSettings(model: AppModel) -> some View {
        modifier(TalariaSettingsPresenter(model: model))
    }
}

// MARK: - Copy

extension CopyPack {

    func settingsKicker(_ t: ThemeID) -> String {
        switch t {
        case .soft: "TALARIA // DEVICE"
        case .control: "DEVICE CONTROL"
        case .ink: "OF THIS DEVICE"
        }
    }

    func settingsTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Settings"
        case .control: "Settings"
        case .ink: "The Settings"
        }
    }

    /// VoiceOver label for the back chevron. Not `cancel` — leaving Settings
    /// abandons nothing, every control here has already taken effect.
    func settingsBack(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Back"
        case .control: "BACK"
        case .ink: "return"
        }
    }

    // MARK: About

    func settingsAboutSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "About"
        case .control: "BUILD & LINK"
        case .ink: "OF THIS COPY"
        }
    }

    func settingsAppVersion(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Talaria"
        case .control: "TALARIA BUILD"
        case .ink: "this copy"
        }
    }

    func settingsPlatform(_ t: ThemeID) -> String {
        switch t {
        case .soft: "System"
        case .control: "HOST OS"
        case .ink: "the machine"
        }
    }

    func settingsGateway(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Gateway"
        case .control: "UPLINK"
        case .ink: "the way"
        }
    }

    func settingsGatewayVersion(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Gateway version"
        case .control: "GATEWAY BUILD"
        case .ink: "its making"
        }
    }

    func settingsAuthMode(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Sign-in"
        case .control: "AUTH MODE"
        case .ink: "the seal"
        }
    }

    func settingsPing(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Round trip"
        case .control: "RTT"
        case .ink: "the distance"
        }
    }

    func settingsLink(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Link"
        case .control: "LINK STATE"
        case .ink: "the way's state"
        }
    }

    /// The backend contract this gateway speaks (`desktop_contract`), which is
    /// what tells a client which RPC shapes it may use.
    func settingsContract(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Backend contract"
        case .control: "DESKTOP CONTRACT"
        case .ink: "the covenant"
        }
    }

    func settingsHealth(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Gateway health"
        case .control: "OVERALL"
        case .ink: "its humour"
        }
    }

    func settingsActiveAgents(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Active agents"
        case .control: "ACTIVE AGENTS"
        case .ink: "familiars afoot"
        }
    }

    // MARK: Diagnostics

    func settingsDiagnosticsSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Diagnostics"
        case .control: "DIAGNOSTICS"
        case .ink: "THE ACCOUNT"
        }
    }

    func settingsDiagnosticsNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Versions, link state and the gateway's contract as plain text — paste it into a bug report. No tokens, no message contents."
        case .control: "PLAIN-TEXT SNAPSHOT: BUILD, LINK, CONTRACT. NO CREDENTIALS, NO MESSAGE CONTENT."
        case .ink: "A plain account of build, way and covenant, fit to be copied into a report. No seals and no words of the familiars."
        }
    }

    func settingsCopyDiagnostics(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Copy diagnostics"
        case .control: "COPY SNAPSHOT"
        case .ink: "copy the account"
        }
    }

    func settingsCopied(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Copied ✓"
        case .control: "COPIED ✓"
        case .ink: "copied ✓"
        }
    }

    // MARK: Links

    func settingsLinksSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Links"
        case .control: "REFERENCES"
        case .ink: "WHERE TO READ FURTHER"
        }
    }

    func settingsRepo(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Source code"
        case .control: "SOURCE"
        case .ink: "the source"
        }
    }

    func settingsDocs(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Documentation"
        case .control: "DOCS"
        case .ink: "the papers"
        }
    }

    func settingsDocsNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Roadmap, parity audits and protocol notes"
        case .control: "ROADMAP · PARITY · PROTOCOL"
        case .ink: "roadmap, parity and the protocol"
        }
    }

    func settingsUpstream(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Hermes Agent"
        case .control: "HERMES AGENT"
        case .ink: "Hermes itself"
        }
    }

    func settingsUpstreamNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The gateway and agent runtime this app talks to"
        case .control: "GATEWAY + AGENT RUNTIME"
        case .ink: "the runtime this app attends"
        }
    }

    // MARK: Managed on desktop

    func settingsDesktopSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Managed on desktop"
        case .control: "NOT ON DEVICE"
        case .ink: "KEPT ELSEWHERE"
        }
    }

    /// Named rather than hidden: these are real desktop settings that are
    /// deliberately absent here, and a person hunting for them deserves to be
    /// told where they went.
    func settingsDesktopItems(_ t: ThemeID) -> [(String, String)] {
        switch t {
        case .soft:
            return [("Environment variables", "hermes config env — on the machine running the gateway"),
                    ("Raw config.yaml", "Provider keys and host paths stay on the gateway host"),
                    ("Local terminal", "iOS cannot run a local shell. Command Center provides an authenticated terminal on supported gateway hosts."),
                    ("Electron windows and overlays", "Desktop chrome such as window placement has no mobile analogue")]
        case .control:
            return [("ENV VARS", "HERMES CONFIG ENV — GATEWAY HOST ONLY"),
                    ("RAW CONFIG.YAML", "HOST KEYS AND PATHS STAY ON THE GATEWAY"),
                    ("LOCAL TERMINAL", "NO LOCAL SHELL. COMMAND CENTER CONNECTS TO A SUPPORTED GATEWAY PTY."),
                    ("ELECTRON WINDOWS", "NO MOBILE ANALOGUE")]
        case .ink:
            return [("the environment", "set where the gateway itself runs"),
                    ("the raw config", "keys and paths remain with the house"),
                    ("the local terminal", "a pocket runs no shell; Command Center can attend a supported gateway PTY"),
                    ("the windows", "desktop chrome has no counterpart here")]
        }
    }

    func settingsAskABot(_ t: ThemeID) -> String {
        switch t {
        case .soft: "A phone is a poor YAML editor — but you can just ask a bot. “Set my default model to Hermes 4 405B” does the same job from the chat you are already in."
        case .control: "NO RAW CONFIG EDITING ON DEVICE BY DESIGN. ASK AN AGENT INSTEAD: \"SET DEFAULT MODEL TO HERMES-4-405B\"."
        case .ink: "A phone makes a poor scriptorium. Ask a familiar instead — “set my default model to Hermes 4” is asked and done from the chat you already keep."
        }
    }
}
