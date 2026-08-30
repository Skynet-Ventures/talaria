import SwiftUI
import TalariaKit
import TalariaTheme

#if os(iOS)
import SafariServices
#endif

// Capabilities — the phone-shaped subset of desktop's /skills surface
// (PARITY.md §10). One pushed screen, four sections:
//
//   Skills    — the profile's skills with live enable toggles (write path is
//               profiles.configure disabled_skills) plus the shared catalog,
//               and skills.reload as a rescan.
//   MCP       — configured servers with a real connect probe, the bundled
//               catalog, add / remove / API key / OAuth.
//   Toolsets  — per-profile toolset pin. This is the knob that makes a small
//               on-device-model profile viable: fewer toolsets, fewer tool
//               definitions in the system prompt.
//   Plugins   — gateway-side plugins (contract v6, key-addressed toggles);
//               this is also how you verify the talaria-push relay is live.
//
// A gateway that doesn't implement a section's RPC hides it (see
// AppModelLive+Capabilities). Every destructive action confirms first.

@MainActor
public struct CapabilitiesView: View {
    private let model: AppModel
    /// Profile (bot id) whose capabilities are shown; nil = launch profile.
    private let profile: String?
    private let onBack: (() -> Void)?

    @State private var state: CapabilityState
    @State private var query = ""
    @State private var expandedToolset: String?
    @State private var showsCatalog = false
    @State private var showsAddServer = false
    @State private var inspecting: MCPServer?
    @State private var pendingPluginDisable: GatewayPlugin?

    @Environment(\.dismiss) private var dismiss

    public init(model: AppModel, profileID: String? = nil, onBack: (() -> Void)? = nil) {
        self.model = model
        let resolved = profileID ?? model.defaultCapabilityProfile
        self.profile = resolved
        self.onBack = onBack
        _state = State(initialValue: model.capabilities(for: resolved))
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var themeID: ThemeID { model.theme.themeID }

    /// Per-profile writes (skill toggles, toolset pin) need a profile name.
    /// The launch-profile view is a read-only inventory.
    private var canWrite: Bool { profile?.isEmpty == false }

    private var listGap: CGFloat {
        switch theme.rowStyle {
        case .ledger: 0
        case .terminal: 7
        case .card: 8
        }
    }

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchField
            ScrollView {
                VStack(alignment: .leading, spacing: listGap) {
                    if let notice = state.notice {
                        noticeCard(notice)
                            .padding(.bottom, 8)
                    }
                    if state.hasLoaded, state.supported.isEmpty {
                        emptyCard(copy.capUnavailable(themeID))
                    } else if state.hasLoaded, state.isEmpty {
                        emptyCard(copy.capEmpty(themeID))
                    }

                    skillsSection
                    mcpSection
                    toolsetsSection
                    pluginsSection

                    if !state.supported.isEmpty {
                        GatewayFootnote(theme: theme, text: copy.capFootnote(themeID))
                            .padding(.top, 12)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
        .sheet(item: $inspecting) { server in
            MCPServerSheet(model: model, profile: profile, server: server)
        }
        .sheet(isPresented: $showsAddServer) {
            MCPAddServerSheet(model: model, profile: profile)
        }
        .confirmationDialog(
            copy.capDisableTitle(themeID, pendingPluginDisable?.name ?? ""),
            isPresented: Binding(get: { pendingPluginDisable != nil },
                                 set: { if !$0 { pendingPluginDisable = nil } }),
            titleVisibility: .visible
        ) {
            Button(copy.capDisable(themeID), role: .destructive) {
                if let plugin = pendingPluginDisable {
                    Task { await model.setPlugin(plugin, enabled: false, profile: profile) }
                }
            }
            Button(copy.cancel, role: .cancel) {}
        } message: {
            Text(copy.capDisableBody(themeID))
        }
        .task {
            guard !state.hasLoaded else { return }
            await model.loadCapabilities(profile: profile)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                if let onBack { onBack() } else { dismiss() }
            } label: {
                Text(verbatim: "‹")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(themeID == .ink ? theme.ink : theme.accent)
                    .frame(width: 31, height: 31)
                    .background(themeID == .ink ? Color.clear : theme.panel)
                    .clipShape(iconButtonShape)
                    .overlay(iconButtonShape.strokeBorder(
                        themeID == .ink ? theme.lineStrong : theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                if theme.showsKicker {
                    Text(copy.capKicker(themeID))
                        .font(theme.mono(9.5, weight: .semibold))
                        .tracking(2)
                        .foregroundStyle(themeID == .ink ? theme.sub : theme.accent)
                        .lineLimit(1)
                }
                Text(titleText)
                    .font(titleFont)
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if state.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.accent)
            } else {
                HeaderIconButton(theme: theme, size: 31,
                                 action: { Task { await model.loadCapabilities(profile: profile) } }) {
                    Text(verbatim: "⟳")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(themeID == .ink ? theme.ink : theme.accent)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    /// "Capabilities · @researcher" — the bot the toggles actually write to.
    private var titleText: String {
        guard let profile, !profile.isEmpty else { return copy.capTitle(themeID) }
        return copy.capTitle(themeID) + " · " + model.botName(profile, themeID)
    }

    private var iconButtonShape: RoundedRectangle {
        let radius: CGFloat = theme.iconCornerFraction >= 0.5 ? 15.5 : 31 * theme.iconCornerFraction
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    private var titleFont: Font {
        switch themeID {
        case .soft: theme.display(20)
        case .control: theme.display(18)
        case .ink: theme.display(22, weight: .bold).smallCaps()
        }
    }

    private var searchField: some View {
        TextField(copy.capSearch(themeID), text: $query)
            .gatewayFieldTraits()
            .modifier(GatewayFlowInputChrome(theme: theme))
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
    }

    // MARK: - Skills

    private var filteredSkills: [SkillEntry] {
        state.skills.filter { matches($0.name) || matches($0.category) }
    }

    @ViewBuilder private var skillsSection: some View {
        let rows = filteredSkills
        if state.supports(.skills), !rows.isEmpty {
            sectionLabel(copy.skillsSec) {
                if state.supports(.skills), model.mode == .live {
                    SmallActionButton(theme: theme, title: copy.capRescan(themeID),
                                      isBusy: state.isBusy("skills:reload")) {
                        Task { await model.rescanSkills(profile: profile) }
                    }
                }
            }
            ForEach(rows) { skill in
                CapabilityRow(theme: theme,
                              title: skill.name,
                              subtitle: skillSubtitle(skill),
                              tag: skill.scope == .shared ? copy.capSharedTag(themeID) : nil,
                              tagColor: theme.faint) {
                    if skill.scope == .profile {
                        CapToggle(isOn: skill.enabled, theme: theme,
                                  isBusy: state.isBusy("skill:\(skill.name)")) {
                            Task { await model.setSkill(skill, enabled: !skill.enabled,
                                                        profile: profile) }
                        }
                    }
                }
            }
            GatewayFootnote(theme: theme, text: copy.capSkillsNote(themeID))
                .padding(.top, 6)
                .padding(.bottom, 8)
        }
    }

    private func skillSubtitle(_ skill: SkillEntry) -> String {
        if !skill.category.isEmpty { return skill.category }
        return skill.enabled ? copy.capOn(themeID) : copy.capOff(themeID)
    }

    // MARK: - MCP

    private var filteredServers: [MCPServer] {
        state.mcpServers.filter { matches($0.name) || matches($0.endpoint) }
    }

    private var filteredCatalog: [MCPCatalogEntry] {
        state.mcpCatalog.filter { matches($0.name) || matches($0.detail) }
    }

    @ViewBuilder private var mcpSection: some View {
        let servers = filteredServers
        let catalog = filteredCatalog
        if state.supports(.mcp), !servers.isEmpty || !catalog.isEmpty {
            sectionLabel(copy.capMCPSec(themeID)) {
                Text(verbatim: "\(state.mcpServers.count)")
                    .font(theme.mono(10, weight: .semibold))
                    .foregroundStyle(theme.faint)
            }
            .padding(.top, 12)

            ForEach(servers) { server in
                Button {
                    inspecting = server
                } label: {
                    CapabilityRow(theme: theme,
                                  title: server.name,
                                  subtitle: server.endpoint,
                                  tag: serverTag(server),
                                  tagColor: serverTagColor(server)) {
                        if state.isBusy("mcp:\(server.name)") {
                            ProgressView().controlSize(.small).tint(theme.accent)
                        } else {
                            Text(verbatim: "›")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(theme.faint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            addServerRow

            if !catalog.isEmpty {
                DisclosureRow(theme: theme, title: copy.capCatalogSec(themeID),
                              isOpen: showsCatalog || !query.isEmpty) {
                    withAnimation(.easeOut(duration: 0.2)) { showsCatalog.toggle() }
                }
                if showsCatalog || !query.isEmpty {
                    ForEach(catalog) { entry in
                        CapabilityRow(theme: theme,
                                      title: entry.name,
                                      subtitle: catalogSubtitle(entry),
                                      tag: nil, tagColor: theme.faint) {
                            if entry.installed {
                                Text(copy.capInstalled(themeID))
                                    .font(theme.mono(9.5, weight: .semibold))
                                    .foregroundStyle(theme.ok)
                            } else {
                                SmallActionButton(theme: theme, title: copy.capInstall(themeID),
                                                  isBusy: state.isBusy("catalog:\(entry.name)")) {
                                    Task { await model.installCatalogServer(entry, profile: profile) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func catalogSubtitle(_ entry: MCPCatalogEntry) -> String {
        guard !entry.requires.isEmpty else { return entry.detail }
        let needs = copy.capRequires(themeID) + " " + entry.requires.joined(separator: ", ")
        return entry.detail.isEmpty ? needs : entry.detail + " · " + needs
    }

    private func serverTag(_ server: MCPServer) -> String? {
        if server.needsOAuth { return copy.capNeedsAuth(themeID) }
        if let probe = state.probes[server.name] {
            return probe.ok ? copy.capToolCount(themeID, probe.tools.count)
                            : copy.capProbeFailed(themeID)
        }
        return server.transport.uppercased()
    }

    private func serverTagColor(_ server: MCPServer) -> Color {
        if server.needsOAuth { return theme.warn }
        if let probe = state.probes[server.name] { return probe.ok ? theme.ok : theme.danger }
        return theme.faint
    }

    private var addServerRow: some View {
        Button {
            showsAddServer = true
        } label: {
            Text(copy.capAddServer(themeID))
                .font(addFont)
                .foregroundStyle(themeID == .ink ? theme.ink.opacity(0.5) : theme.faint)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(11)
                .overlay(
                    RoundedRectangle(cornerRadius: themeID == .ink ? 0 : theme.cardRadius,
                                     style: .continuous)
                        .strokeBorder(dashColor,
                                      style: StrokeStyle(lineWidth: themeID == .soft ? 1.5 : 1,
                                                         dash: [5, 4]))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }

    private var addFont: Font {
        switch themeID {
        case .soft: theme.body(13, weight: .bold)
        case .control: theme.mono(10.5, weight: .semibold)
        case .ink: theme.body(14.5, weight: .semibold).smallCaps()
        }
    }

    private var dashColor: Color {
        switch themeID {
        case .soft: theme.ink.opacity(0.15)
        case .control: theme.accent.opacity(0.25)
        case .ink: theme.ink.opacity(0.4)
        }
    }

    // MARK: - Toolsets

    private var filteredToolsets: [ToolsetEntry] {
        state.toolsets.filter { matches($0.name) || matches($0.label) || matches($0.detail) }
    }

    @ViewBuilder private var toolsetsSection: some View {
        let rows = filteredToolsets
        if state.supports(.toolsets), !rows.isEmpty {
            sectionLabel(copy.capToolsetsSec(themeID)) {
                Text(state.toolsetsPinned ? copy.capPinned(themeID) : copy.capUnpinned(themeID))
                    .font(theme.mono(9.5, weight: .semibold))
                    .foregroundStyle(theme.faint)
            }
            .padding(.top, 12)

            ForEach(rows) { toolset in
                VStack(alignment: .leading, spacing: 0) {
                    CapabilityRow(theme: theme,
                                  title: toolset.label.isEmpty ? toolset.name : toolset.label,
                                  subtitle: toolsetSubtitle(toolset),
                                  tag: nil, tagColor: theme.faint) {
                        if canWrite {
                            CapToggle(isOn: toolset.enabled, theme: theme,
                                      isBusy: state.isBusy("toolset:\(toolset.name)")) {
                                Task { await model.setToolset(toolset, enabled: !toolset.enabled,
                                                              profile: profile) }
                            }
                        } else {
                            // The launch-profile view has no profile to write a
                            // pin to, so it reports rather than pretends.
                            Text(toolset.enabled ? copy.capOn(themeID) : copy.capOff(themeID))
                                .font(theme.mono(9.5, weight: .semibold))
                                .textCase(.uppercase)
                                .foregroundStyle(toolset.enabled ? theme.ok : theme.faint)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !toolset.tools.isEmpty else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            expandedToolset = expandedToolset == toolset.name ? nil : toolset.name
                        }
                    }
                    if expandedToolset == toolset.name, !toolset.tools.isEmpty {
                        ToolNameGrid(theme: theme, names: toolset.tools)
                    }
                }
            }
            GatewayFootnote(theme: theme, text: copy.capToolsetsNote(themeID))
                .padding(.top, 6)
        }
    }

    private func toolsetSubtitle(_ toolset: ToolsetEntry) -> String {
        let count = copy.capToolCount(themeID, toolset.toolCount)
        return toolset.detail.isEmpty ? count : toolset.detail + " · " + count
    }

    // MARK: - Plugins

    private var filteredPlugins: [GatewayPlugin] {
        state.plugins.filter { matches($0.name) || matches($0.key) || matches($0.detail) }
    }

    @ViewBuilder private var pluginsSection: some View {
        let rows = filteredPlugins
        if state.supports(.plugins), !rows.isEmpty {
            sectionLabel(copy.capPluginsSec(themeID)) {
                Text(verbatim: "\(rows.filter(\.enabled).count)/\(rows.count)")
                    .font(theme.mono(10, weight: .semibold))
                    .foregroundStyle(theme.faint)
            }
            .padding(.top, 12)

            ForEach(rows) { plugin in
                CapabilityRow(theme: theme,
                              title: plugin.name,
                              subtitle: pluginSubtitle(plugin),
                              tag: plugin.portable ? copy.capPortable(themeID) : nil,
                              tagColor: theme.faint) {
                    CapToggle(isOn: plugin.enabled, theme: theme,
                              isBusy: state.isBusy("plugin:\(plugin.id)")) {
                        if plugin.enabled {
                            // Turning a plugin off can silence the push relay
                            // or drop a provider backend — always confirm.
                            pendingPluginDisable = plugin
                        } else {
                            Task { await model.setPlugin(plugin, enabled: true, profile: profile) }
                        }
                    }
                }
            }
        }
    }

    private func pluginSubtitle(_ plugin: GatewayPlugin) -> String {
        var parts: [String] = []
        if !plugin.source.isEmpty { parts.append(plugin.source) }
        if !plugin.version.isEmpty { parts.append("v" + plugin.version) }
        if !plugin.detail.isEmpty { parts.append(plugin.detail) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Shared chrome

    private func sectionLabel<Trailing: View>(
        _ text: String, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            GatewaySectionLabel(theme: theme, text: text)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 2)
        .padding(.bottom, theme.rowStyle == .ledger ? 6 : 2)
    }

    private func noticeCard(_ text: String) -> some View {
        Text(text)
            .font(themeID == .control ? theme.mono(10.5) : theme.body(12.5))
            .foregroundStyle(theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: theme.cardRadius)
                .stroke(theme.danger.opacity(0.45), lineWidth: 1))
    }

    private func emptyCard(_ text: String) -> some View {
        Text(text)
            .font(themeID == .control ? theme.mono(11) : theme.body(13))
            .italic(themeID == .ink)
            .foregroundStyle(theme.sub)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
    }

    private func matches(_ candidate: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return candidate.localizedCaseInsensitiveContains(trimmed)
    }
}

// MARK: - Row

/// Title + subtitle + optional tag, with a trailing control. Row chrome
/// follows rowStyle: floating card in soft, terminal panel in control, ruled
/// ledger line in ink. (File-scoped copy; each screen keeps its own.)
private struct CapabilityRow<Trailing: View>: View {
    let theme: ThemePack
    let title: String
    let subtitle: String
    let tag: String?
    let tagColor: Color
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(titleFont)
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    if let tag, !tag.isEmpty {
                        Text(tag)
                            .font(theme.mono(8.5, weight: .semibold))
                            .tracking(1)
                            .textCase(.uppercase)
                            .foregroundStyle(tagColor)
                            .lineLimit(1)
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(subtitleFont)
                        .foregroundStyle(theme.id == .control ? theme.faint : theme.sub)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing()
        }
        .modifier(CapRowChrome(theme: theme))
    }

    private var titleFont: Font {
        switch theme.id {
        case .soft: theme.body(14.5, weight: .bold)
        case .control: theme.body(13.5, weight: .bold)
        case .ink: theme.body(16.5, weight: .bold)
        }
    }

    private var subtitleFont: Font {
        switch theme.id {
        case .soft: theme.body(11.5)
        case .control: theme.mono(9.5)
        case .ink: theme.body(12.5)
        }
    }
}

private struct CapRowChrome: ViewModifier {
    let theme: ThemePack

    func body(content: Content) -> some View {
        switch theme.rowStyle {
        case .card:
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                    .strokeBorder(theme.ink.opacity(0.05), lineWidth: 1))
                .shadow(color: theme.ink.opacity(0.04), radius: 3, y: 1)
        case .terminal:
            content
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                    .strokeBorder(theme.line, lineWidth: 1))
        case .ledger:
            content
                .padding(.horizontal, 2)
                .padding(.vertical, 13)
                .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
        }
    }
}

/// Expanded tool names under a toolset row — a wrapped run of mono chips.
private struct ToolNameGrid: View {
    let theme: ThemePack
    let names: [String]

    var body: some View {
        ChipFlowLayout {
            ForEach(names, id: \.self) { name in
                Text(name)
                    .font(theme.mono(9.5))
                    .foregroundStyle(theme.sub)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(theme.inset,
                                in: RoundedRectangle(cornerRadius: theme.id == .ink ? 0 : 5))
            }
        }
        .padding(.horizontal, theme.rowStyle == .ledger ? 2 : 14)
        .padding(.bottom, 10)
    }
}

/// Wrapping run of chips. SwiftUI ships no flow container, and a fixed grid
/// would misalign tool names of wildly different lengths.
private struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Controls

/// The design's 46×27 switch, with a spinner while a write is in flight.
/// File-scoped copy, matching Connections/Routines so every screen agrees.
private struct CapToggle: View {
    let isOn: Bool
    let theme: ThemePack
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                trackShape
                    .fill(trackFill)
                    .overlay(trackShape.strokeBorder(trackBorder, lineWidth: 1))
                knobShape
                    .fill(knobFill)
                    .frame(width: 21, height: 21)
                    .shadow(color: theme.id == .soft ? Color.black.opacity(0.2) : .clear,
                            radius: 1.5, y: 1)
                    .offset(x: isOn ? 21 : 2.5)
            }
            .frame(width: 46, height: 27)
            .opacity(isBusy ? 0.45 : 1)
            .animation(.easeInOut(duration: 0.2), value: isOn)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private var trackShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .control ? 6 : 14, style: .continuous)
    }

    private var knobShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .control ? 4 : 10.5, style: .continuous)
    }

    private var trackFill: Color {
        switch theme.id {
        case .soft: isOn ? theme.ok : theme.ink.opacity(0.12)
        case .control: isOn ? theme.accent.opacity(0.35) : theme.ink.opacity(0.08)
        case .ink: isOn ? theme.ok.opacity(0.25) : .clear
        }
    }

    private var trackBorder: Color {
        switch theme.id {
        case .soft: .clear
        case .control, .ink: theme.lineStrong
        }
    }

    private var knobFill: Color {
        switch theme.id {
        case .soft: theme.panel
        case .control: theme.ink
        case .ink: isOn ? theme.ink : theme.ink.opacity(0.35)
        }
    }
}

/// Compact trailing action (Rescan / Install / Probe).
private struct SmallActionButton: View {
    let theme: ThemePack
    let title: String
    var isBusy: Bool = false
    var isDestructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView().controlSize(.small).tint(tint)
                } else {
                    Text(title)
                        .font(font)
                        .tracking(theme.id == .soft ? 0 : 1)
                        .foregroundStyle(tint)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(theme.id == .soft ? tint.opacity(0.08) : Color.clear)
            .clipShape(shape)
            .overlay(shape.strokeBorder(tint.opacity(theme.id == .soft ? 0 : 0.5), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .ink ? 0 : theme.buttonRadius,
                         style: .continuous)
    }

    private var tint: Color {
        isDestructive ? theme.danger : (theme.id == .ink ? theme.ink : theme.accent)
    }

    private var font: Font {
        switch theme.id {
        case .soft: theme.body(11.5, weight: .bold)
        case .control: theme.mono(9.5, weight: .bold)
        case .ink: theme.body(12.5, weight: .semibold).smallCaps()
        }
    }
}

/// Section sub-header that opens/closes an inline group (the MCP catalog).
private struct DisclosureRow: View {
    let theme: ThemePack
    let title: String
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                GatewaySectionLabel(theme: theme, text: title)
                Text(verbatim: isOpen ? "▾" : "▸")
                    .font(theme.mono(9))
                    .foregroundStyle(theme.faint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - MCP server sheet

/// One server: how it connects, what a probe found, and the four actions —
/// probe, OAuth sign-in, store an API key, remove.
@MainActor
private struct MCPServerSheet: View {
    let model: AppModel
    let profile: String?
    /// Snapshot from the row that was tapped; `server` below re-resolves it so
    /// a write (API key, OAuth) refreshes what the sheet shows.
    let initial: MCPServer

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var apiKey = ""
    @State private var showsKeyField = false
    @State private var showsToolFilter = false
    @State private var confirmingRemoval = false
    @State private var oauthTarget: BrowserTarget?
    @State private var oauthNote: String?

    init(model: AppModel, profile: String?, server: MCPServer) {
        self.model = model
        self.profile = profile
        self.initial = server
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var themeID: ThemeID { model.theme.themeID }
    private var state: CapabilityState { model.capabilities(for: profile) }
    private var server: MCPServer {
        state.mcpServers.first { $0.name == initial.name } ?? initial
    }
    private var probe: MCPProbeResult? { state.probes[server.name] }
    private var isBusy: Bool { state.isBusy("mcp:\(server.name)") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    detailRows

                    HStack(spacing: 8) {
                        SmallActionButton(theme: theme, title: copy.capTest(themeID),
                                          isBusy: isBusy) {
                            Task { await model.testMCPServer(server, profile: profile) }
                        }
                        if server.toolFilter.isEditable {
                            SmallActionButton(theme: theme, title: copy.capEditTools(themeID),
                                              isBusy: isBusy) {
                                showsToolFilter = true
                            }
                        }
                        if server.auth == "oauth" || probe?.oauthNeeded == true {
                            SmallActionButton(theme: theme, title: copy.capConnect(themeID),
                                              isBusy: isBusy) { startOAuth() }
                        }
                        if server.transport == "http" || !server.envKeys.isEmpty {
                            SmallActionButton(theme: theme, title: copy.capSetKey(themeID)) {
                                withAnimation(.easeOut(duration: 0.2)) { showsKeyField.toggle() }
                            }
                        }
                        Spacer(minLength: 0)
                    }

                    if showsKeyField { keyField }
                    if let oauthNote {
                        GatewayFootnote(theme: theme, text: oauthNote)
                    }
                    if let probe { probeResult(probe) }

                    GatewayFootnote(theme: theme, text: copy.capOAuthNote(themeID))
                        .padding(.top, 4)

                    SmallActionButton(theme: theme, title: copy.capRemove(themeID),
                                      isDestructive: true) {
                        confirmingRemoval = true
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
        .sheet(item: $oauthTarget) { target in
            OAuthBrowser(url: target.url, theme: theme, title: copy.capConnect(themeID)) {
                oauthTarget = nil
            }
        }
        .sheet(isPresented: $showsToolFilter) {
            MCPToolFilterSheet(model: model, profile: profile, server: server)
        }
        // Confirmed here rather than on the list so the dialog never has to
        // present through a dismissing sheet.
        .confirmationDialog(copy.capRemoveTitle(themeID, server.name),
                            isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button(copy.capRemove(themeID), role: .destructive) {
                let target = server
                Task {
                    await model.removeMCPServer(target, profile: profile)
                    dismiss()
                }
            }
            Button(copy.cancel, role: .cancel) {}
        } message: {
            Text(copy.capRemoveBody(themeID))
        }
    }

    private var sheetHeader: some View {
        HStack(alignment: .center) {
            Button { dismiss() } label: {
                Text(copy.cancel)
                    .font(themeID == .control ? theme.mono(11, weight: .semibold)
                                              : theme.body(14, weight: .semibold))
                    .foregroundStyle(themeID == .ink ? theme.ink.opacity(0.55)
                                     : (themeID == .control ? theme.sub : theme.accent))
            }
            .buttonStyle(.plain)
            Spacer()
            Text(server.name)
                .font(themeID == .ink ? theme.display(20, weight: .bold).smallCaps()
                                      : theme.body(16, weight: .heavy))
                .foregroundStyle(theme.ink)
            Spacer()
            Text(copy.cancel)
                .font(themeID == .control ? theme.mono(11, weight: .semibold)
                                          : theme.body(14, weight: .semibold))
                .hidden()
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var detailRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailLine(copy.capTransport(themeID), server.transport)
            detailLine(copy.capEndpoint(themeID), server.endpoint)
            if let auth = server.auth {
                detailLine(copy.capAuth(themeID), auth)
            }
            if !server.envKeys.isEmpty {
                detailLine(copy.capEnvKeys(themeID), server.envKeys.joined(separator: ", "))
            }
            toolFilterDetail
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GatewayCardChrome(theme: theme))
    }

    @ViewBuilder private var toolFilterDetail: some View {
        switch server.toolFilter.mode {
        case .all:
            detailLine(copy.capToolFilter(themeID), copy.capAllTools(themeID))
        case .include:
            detailLine(copy.capToolFilter(themeID), copy.capIncludeMode(themeID))
            detailLine(copy.capFilterPatterns(themeID),
                       server.toolFilter.patterns.isEmpty
                        ? copy.capEmptyWhitelist(themeID)
                        : server.toolFilter.patterns.joined(separator: ", "))
        case .exclude:
            detailLine(copy.capToolFilter(themeID), copy.capExcludeMode(themeID))
            detailLine(copy.capFilterPatterns(themeID),
                       server.toolFilter.patterns.isEmpty
                        ? copy.capNoExcludedTools(themeID)
                        : server.toolFilter.patterns.joined(separator: ", "))
        case .unavailable:
            detailLine(copy.capToolFilter(themeID), copy.capFilterUnavailable(themeID))
        }
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(theme.mono(9, weight: .semibold))
                .tracking(1)
                .textCase(.uppercase)
                .foregroundStyle(theme.faint)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(themeID == .control ? theme.mono(11) : theme.body(12.5))
                .foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The secret is typed here and posted straight to the gateway's .env —
    /// it is never persisted on the phone.
    private var keyField: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField(copy.capKeyPlaceholder(themeID), text: $apiKey)
                .modifier(GatewayFlowInputChrome(theme: theme))
            HStack(spacing: 8) {
                SmallActionButton(theme: theme, title: copy.capSave(themeID), isBusy: isBusy) {
                    let value = apiKey
                    apiKey = ""
                    Task {
                        if await model.setMCPAPIKey(server, value: value,
                                                    envVar: server.envKeys.first,
                                                    profile: profile) {
                            withAnimation(.easeOut(duration: 0.2)) { showsKeyField = false }
                        }
                    }
                }
                .disabled(apiKey.isEmpty)
                Spacer(minLength: 0)
            }
            GatewayFootnote(theme: theme, text: copy.capKeyNote(themeID))
        }
    }

    private func probeResult(_ probe: MCPProbeResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(probe.ok ? theme.ok : theme.danger)
                    .frame(width: 7, height: 7)
                Text(probe.ok ? copy.capToolCount(themeID, probe.tools.count)
                              : copy.capProbeFailed(themeID))
                    .font(themeID == .control ? theme.mono(10.5, weight: .bold)
                                              : theme.body(12.5, weight: .bold))
                    .foregroundStyle(theme.ink)
            }
            if let error = probe.error, !error.isEmpty {
                Text(error)
                    .font(themeID == .control ? theme.mono(9.5) : theme.body(11.5))
                    .foregroundStyle(theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(probe.tools) { tool in
                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.name)
                        .font(theme.mono(10.5, weight: .semibold))
                        .foregroundStyle(theme.ink)
                    if !tool.detail.isEmpty {
                        Text(tool.detail)
                            .font(themeID == .control ? theme.mono(9) : theme.body(11))
                            .foregroundStyle(theme.sub)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GatewayCardChrome(theme: theme))
    }

    /// Start the gateway-side flow, open the authorization page, and poll
    /// until it lands. The redirect is caught by the gateway's own loopback
    /// listener, so nothing here has to receive it.
    private func startOAuth() {
        oauthNote = nil
        Task {
            guard let flow = await model.beginMCPOAuth(server, profile: profile) else { return }
            if let url = flow.authURL {
                present(url)
            } else {
                oauthNote = copy.capOAuthNoURL(themeID)
                return
            }
            let status = await model.awaitMCPOAuth(server, flow: flow, profile: profile)
            oauthTarget = nil
            if status.isApproved {
                oauthNote = copy.capOAuthDone(themeID)
            } else if status.isPending {
                oauthNote = copy.capOAuthTimeout(themeID)
            } else {
                oauthNote = status.errorMessage ?? copy.capOAuthFailed(themeID)
            }
        }
    }

    /// In-app browser for https flows (the AuthWebSheet pattern, without
    /// duplicating that file's PKCE interception — this flow's redirect is
    /// the gateway's business). Anything else hands off to the system.
    private func present(_ url: URL) {
        #if os(iOS)
        if let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            oauthTarget = BrowserTarget(url: url)
            return
        }
        #endif
        openURL(url)
    }
}

// MARK: - MCP tool filter sheet

/// Presentation draft for the filter editor. Keeping this separate from the
/// probe result makes the UI contract testable: switching nothing on an
/// exclude-mode server must preserve that mode and its patterns verbatim.
struct MCPToolFilterEditorDraft: Sendable, Equatable {
    var mode: MCPToolFilterMode
    var patterns: [String]

    init(filter: MCPToolFilter) {
        mode = filter.isEditable ? filter.mode : .all
        patterns = filter.patterns
    }

    var filter: MCPToolFilter {
        MCPToolFilter(mode: mode, patterns: mode == .all ? [] : patterns)
    }
}

/// Mode-aware editor for a server's `tools` block. This intentionally edits
/// configured patterns rather than deriving an include list from a probe: an
/// exclude-mode catalog entry must keep applying to tools the remote server
/// adds tomorrow.
@MainActor
private struct MCPToolFilterSheet: View {
    let model: AppModel
    let profile: String?
    let initial: MCPServer

    @Environment(\.dismiss) private var dismiss
    @State private var draft: MCPToolFilterEditorDraft

    init(model: AppModel, profile: String?, server: MCPServer) {
        self.model = model
        self.profile = profile
        self.initial = server
        _draft = State(initialValue: MCPToolFilterEditorDraft(filter: server.toolFilter))
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var themeID: ThemeID { model.theme.themeID }
    private var state: CapabilityState { model.capabilities(for: profile) }
    private var server: MCPServer {
        state.mcpServers.first { $0.id == initial.id } ?? initial
    }
    private var isBusy: Bool { state.isBusy("mcp:\(server.name)") }
    private var filter: MCPToolFilter { draft.filter }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    Text(copy.capToolFilterBody(themeID))
                        .font(themeID == .control ? theme.mono(9.5) : theme.body(12))
                        .foregroundStyle(theme.sub)
                        .fixedSize(horizontal: false, vertical: true)

                    Picker(copy.capToolFilter(themeID), selection: $draft.mode) {
                        Text(copy.capAllTools(themeID)).tag(MCPToolFilterMode.all)
                        Text(copy.capIncludeMode(themeID)).tag(MCPToolFilterMode.include)
                        Text(copy.capExcludeMode(themeID)).tag(MCPToolFilterMode.exclude)
                    }
                    .pickerStyle(.segmented)

                    if draft.mode != .all {
                        patternRows
                        SmallActionButton(theme: theme, title: copy.capAddFilterPattern(themeID)) {
                            draft.patterns.append("")
                        }
                        GatewayFootnote(theme: theme,
                                        text: draft.mode == .exclude
                                            ? copy.capExcludeModeNote(themeID)
                                            : copy.capIncludeModeNote(themeID))
                    } else {
                        GatewayFootnote(theme: theme, text: copy.capAllToolsNote(themeID))
                    }

                    if let notice = state.notice {
                        Text(notice)
                            .font(themeID == .control ? theme.mono(10) : theme.body(12))
                            .foregroundStyle(theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    GatewayFlowButton(theme: theme, label: copy.capSaveFilter(themeID),
                                      role: .primary) { save() }
                        .opacity(isBusy ? 0.55 : 1)
                        .disabled(isBusy)
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
    }

    private var header: some View {
        HStack(alignment: .center) {
            Button { dismiss() } label: {
                Text(copy.cancel)
                    .font(themeID == .control ? theme.mono(11, weight: .semibold)
                                                  : theme.body(14, weight: .semibold))
                    .foregroundStyle(themeID == .ink ? theme.ink.opacity(0.55)
                                     : (themeID == .control ? theme.sub : theme.accent))
            }
            .buttonStyle(.plain)
            Spacer()
            Text(copy.capToolFilterTitle(themeID, server.name))
                .font(themeID == .ink ? theme.display(20, weight: .bold).smallCaps()
                                      : theme.body(16, weight: .heavy))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            Spacer()
            Text(copy.cancel)
                .font(themeID == .control ? theme.mono(11, weight: .semibold)
                                              : theme.body(14, weight: .semibold))
                .hidden()
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var patternRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(draft.patterns.indices), id: \.self) { index in
                HStack(spacing: 8) {
                    TextField(copy.capFilterPattern(themeID), text: binding(for: index))
                        .gatewayFieldTraits()
                        .modifier(GatewayFlowInputChrome(theme: theme))
                    Button {
                        draft.patterns.remove(at: index)
                    } label: {
                        Text(verbatim: "−")
                            .font(theme.mono(14, weight: .bold))
                            .foregroundStyle(theme.danger)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(copy.capRemove(themeID))
                }
            }
        }
    }

    private func binding(for index: Int) -> Binding<String> {
        Binding(
            get: { draft.patterns.indices.contains(index) ? draft.patterns[index] : "" },
            set: { value in
                guard draft.patterns.indices.contains(index) else { return }
                draft.patterns[index] = value
            })
    }

    private func save() {
        let requested = filter
        Task {
            if await model.setMCPToolFilter(server, filter: requested, profile: profile) {
                dismiss()
            }
        }
    }
}

/// Identifiable wrapper so an optional URL can drive `.sheet(item:)`.
private struct BrowserTarget: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// SFSafariViewController on iOS; a plain hand-off elsewhere.
private struct OAuthBrowser: View {
    let url: URL
    let theme: ThemePack
    let title: String
    let onDone: () -> Void

    var body: some View {
        #if os(iOS)
        SafariView(url: url)
            .ignoresSafeArea()
        #else
        VStack(spacing: 14) {
            Text(title)
                .font(theme.body(16, weight: .bold))
                .foregroundStyle(theme.ink)
            Link(url.absoluteString, destination: url)
                .font(theme.mono(11))
                .tint(theme.accent)
            Button("Done", action: onDone)
                .tint(theme.accent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
        #endif
    }
}

#if os(iOS)
private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
#endif

// MARK: - Add-server sheet

/// Minimal add form: a name plus either an http(s) URL or a stdio command.
/// The gateway rejects anything else (4063), and the raw mcp.json editor
/// desktop offers is deliberately not on the phone.
@MainActor
private struct MCPAddServerSheet: View {
    let model: AppModel
    let profile: String?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var transport: Transport = .http
    @State private var endpoint = ""
    @State private var args = ""

    private enum Transport: String, CaseIterable { case http, stdio }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var themeID: ThemeID { model.theme.themeID }
    private var state: CapabilityState { model.capabilities(for: profile) }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !endpoint.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    TextField(copy.capServerName(themeID), text: $name)
                        .gatewayFieldTraits()
                        .modifier(GatewayFlowInputChrome(theme: theme))

                    HStack(spacing: 7) {
                        ForEach(Transport.allCases, id: \.self) { option in
                            GatewayModeChip(theme: theme, label: option.rawValue.uppercased(),
                                            isOn: transport == option) {
                                withAnimation(.easeInOut(duration: 0.2)) { transport = option }
                            }
                        }
                    }

                    TextField(transport == .http ? copy.capServerURL(themeID)
                                                 : copy.capServerCommand(themeID),
                              text: $endpoint)
                        .gatewayFieldTraits()
                        .modifier(GatewayFlowInputChrome(theme: theme))

                    if transport == .stdio {
                        TextField(copy.capServerArgs(themeID), text: $args)
                            .gatewayFieldTraits()
                            .modifier(GatewayFlowInputChrome(theme: theme))
                    }

                    if let notice = state.notice {
                        Text(notice)
                            .font(themeID == .control ? theme.mono(10) : theme.body(12))
                            .foregroundStyle(theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    GatewayFootnote(theme: theme, text: copy.capAddNote(themeID))

                    GatewayFlowButton(theme: theme, label: copy.capAddOK(themeID),
                                      role: .primary) { save() }
                        .opacity(canSave ? 1 : 0.45)
                        .disabled(!canSave || state.isBusy("mcp:add"))
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
        // A notice left over from elsewhere would read as this form's error.
        .onAppear { state.notice = nil }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Button { dismiss() } label: {
                Text(copy.cancel)
                    .font(themeID == .control ? theme.mono(11, weight: .semibold)
                                              : theme.body(14, weight: .semibold))
                    .foregroundStyle(themeID == .ink ? theme.ink.opacity(0.55)
                                     : (themeID == .control ? theme.sub : theme.accent))
            }
            .buttonStyle(.plain)
            Spacer()
            Text(copy.capAddTitle(themeID))
                .font(themeID == .ink ? theme.display(20, weight: .bold).smallCaps()
                                      : theme.body(16, weight: .heavy))
                .foregroundStyle(theme.ink)
            Spacer()
            Text(copy.cancel)
                .font(themeID == .control ? theme.mono(11, weight: .semibold)
                                          : theme.body(14, weight: .semibold))
                .hidden()
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private func save() {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let argv = args.split(separator: " ").map(String.init)
        Task {
            let ok = await model.addMCPServer(
                name: name,
                url: transport == .http ? trimmed : nil,
                command: transport == .stdio ? trimmed : nil,
                args: transport == .stdio ? argv : [],
                profile: profile)
            if ok { dismiss() }
        }
    }
}

// MARK: - Copy

/// Per-theme voice for the Capabilities surface. Anything CopyPack already
/// says (skills section label, Cancel, …) is reused rather than restated.
public extension CopyPack {

    func capKicker(_ t: ThemeID) -> String {
        switch t {
        case .soft: "WHAT IT CAN DO"
        case .control: "CAPABILITY MATRIX"
        case .ink: "GIFTS, WAYS & INSTRUMENTS"
        }
    }

    func capTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Capabilities"
        case .control: "Capabilities"
        case .ink: "The Gifts"
        }
    }

    func capSearch(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Search skills, servers, tools…"
        case .control: "FILTER CAPABILITIES…"
        case .ink: "seek a gift…"
        }
    }

    func capMCPSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "MCP servers"
        case .control: "MCP SERVERS"
        case .ink: "OUTER WAYS (MCP)"
        }
    }

    func capCatalogSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Bundled catalog"
        case .control: "BUNDLED CATALOG"
        case .ink: "THE WAYS ON OFFER"
        }
    }

    func capToolsetsSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Toolsets"
        case .control: "TOOLSETS"
        case .ink: "INSTRUMENTS (TOOLSETS)"
        }
    }

    func capPluginsSec(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Gateway plugins"
        case .control: "GATEWAY PLUGINS"
        case .ink: "THE GATEWAY'S APPENDAGES"
        }
    }

    func capRescan(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Rescan"
        case .control: "RESCAN"
        case .ink: "read again"
        }
    }

    func capTest(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Test"
        case .control: "PROBE"
        case .ink: "sound it"
        }
    }

    func capConnect(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Sign in"
        case .control: "AUTHENTICATE"
        case .ink: "seek leave"
        }
    }

    func capSetKey(_ t: ThemeID) -> String {
        switch t {
        case .soft: "API key"
        case .control: "SET KEY"
        case .ink: "entrust a key"
        }
    }

    func capSave(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Save"
        case .control: "STORE"
        case .ink: "inscribe"
        }
    }

    func capRemove(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Remove"
        case .control: "REMOVE"
        case .ink: "strike it out"
        }
    }

    func capDisable(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Turn off"
        case .control: "DISABLE"
        case .ink: "withhold it"
        }
    }

    func capInstall(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Install"
        case .control: "INSTALL"
        case .ink: "take it up"
        }
    }

    func capInstalled(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Installed"
        case .control: "INSTALLED"
        case .ink: "held"
        }
    }

    func capAddServer(_ t: ThemeID) -> String {
        switch t {
        case .soft: "+ Add MCP server — URL or command"
        case .control: "+ ADD MCP SERVER — URL / COMMAND"
        case .ink: "+ open an outer way — url or command"
        }
    }

    func capAddTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Add MCP server"
        case .control: "ADD MCP SERVER"
        case .ink: "An Outer Way"
        }
    }

    func capAddOK(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Add server"
        case .control: "ADD"
        case .ink: "open the way"
        }
    }

    func capAddNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Saved to this bot's config.yaml on the gateway. Test it afterwards to see the tools it offers."
        case .control: "WRITTEN TO THE PROFILE'S CONFIG.YAML. PROBE AFTER SAVING TO ENUMERATE TOOLS."
        case .ink: "Inscribed in this familiar's config.yaml. Sound the way afterwards to learn what it offers."
        }
    }

    func capServerName(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Name — e.g. linear"
        case .control: "NAME — e.g. linear"
        case .ink: "its name — e.g. linear"
        }
    }

    func capServerURL(_ t: ThemeID) -> String {
        switch t {
        case .soft: "https://mcp.example.com/sse"
        case .control: "https://mcp.example.com/sse"
        case .ink: "https://mcp.example.com/sse"
        }
    }

    func capServerCommand(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Command — e.g. npx"
        case .control: "COMMAND — e.g. npx"
        case .ink: "the command — e.g. npx"
        }
    }

    func capServerArgs(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Arguments, space separated"
        case .control: "ARGV — SPACE SEPARATED"
        case .ink: "its arguments, parted by spaces"
        }
    }

    func capKeyPlaceholder(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Paste the API key"
        case .control: "PASTE CREDENTIAL"
        case .ink: "the key itself"
        }
    }

    func capKeyNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Stored in this bot's .env on the gateway — the phone keeps no copy."
        case .control: "WRITTEN TO THE PROFILE'S .ENV ON THE GATEWAY. NO LOCAL COPY."
        case .ink: "Kept in this familiar's .env upon the gateway; the glass keeps nothing."
        }
    }

    func capTransport(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Transport"
        case .control: "TRANSPORT"
        case .ink: "manner"
        }
    }

    func capEndpoint(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Endpoint"
        case .control: "ENDPOINT"
        case .ink: "whither"
        }
    }

    func capAuth(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Auth"
        case .control: "AUTH"
        case .ink: "leave"
        }
    }

    func capEnvKeys(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Env keys"
        case .control: "ENV KEYS"
        case .ink: "keys"
        }
    }

    func capAllowList(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Tools"
        case .control: "TOOL PIN"
        case .ink: "instruments"
        }
    }

    func capToolFilter(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Tool filter"
        case .control: "TOOL FILTER"
        case .ink: "instrument rule"
        }
    }

    func capFilterPatterns(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Patterns"
        case .control: "PATTERNS"
        case .ink: "marks"
        }
    }

    func capAllTools(_ t: ThemeID) -> String {
        switch t {
        case .soft: "All tools"
        case .control: "ALL TOOLS"
        case .ink: "all instruments"
        }
    }

    func capIncludeMode(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Include only"
        case .control: "INCLUDE"
        case .ink: "only these"
        }
    }

    func capExcludeMode(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Exclude"
        case .control: "EXCLUDE"
        case .ink: "withhold these"
        }
    }

    func capEmptyWhitelist(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No tools allowed"
        case .control: "EMPTY WHITELIST"
        case .ink: "none are permitted"
        }
    }

    func capNoExcludedTools(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No excluded tools"
        case .control: "NO EXCLUSIONS"
        case .ink: "none withheld"
        }
    }

    func capFilterUnavailable(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Unsupported filter format — left unchanged"
        case .control: "UNSUPPORTED FILTER — PRESERVED"
        case .ink: "an unknown rule, left unaltered"
        }
    }

    func capEditTools(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Tools"
        case .control: "FILTER"
        case .ink: "shape tools"
        }
    }

    func capToolFilterTitle(_ t: ThemeID, _ name: String) -> String {
        switch t {
        case .soft: "Tools · \(name)"
        case .control: "TOOLS · \(name.uppercased())"
        case .ink: "The instruments of \(name)"
        }
    }

    func capToolFilterBody(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Keep an include whitelist or an exclude denylist. Patterns are saved exactly as written."
        case .control: "PRESERVE INCLUDE / EXCLUDE MODE. PATTERNS ARE WRITTEN VERBATIM."
        case .ink: "Keep a chosen list, or a list withheld. The marks are inscribed exactly as given."
        }
    }

    func capFilterPattern(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Tool name or glob, e.g. *_secret_*"
        case .control: "TOOL NAME OR GLOB"
        case .ink: "a name or star-mark"
        }
    }

    func capAddFilterPattern(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Add pattern"
        case .control: "ADD PATTERN"
        case .ink: "add a mark"
        }
    }

    func capSaveFilter(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Save tool filter"
        case .control: "SAVE FILTER"
        case .ink: "inscribe the rule"
        }
    }

    func capExcludeModeNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Exclude mode stays dynamic: tools the server adds later remain enabled unless a pattern matches them."
        case .control: "EXCLUDE MODE STAYS DYNAMIC. NEW SERVER TOOLS ARE NOT FROZEN INTO AN INCLUDE LIST."
        case .ink: "What the way makes tomorrow remains available, unless one of these marks catches it."
        }
    }

    func capIncludeModeNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "An empty include list is intentional: it allows no tools until you add a pattern."
        case .control: "EMPTY INCLUDE = EXPLICIT EMPTY WHITELIST."
        case .ink: "An empty choosing is still a choice: no instruments are permitted."
        }
    }

    func capAllToolsNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This removes only the include/exclude keys. Other server configuration stays unchanged."
        case .control: "ONLY INCLUDE / EXCLUDE KEYS ARE REMOVED. ALL OTHER SERVER CONFIG REMAINS."
        case .ink: "Only the rule is lifted; the rest of the way remains as it was."
        }
    }

    func capRequires(_ t: ThemeID) -> String {
        switch t {
        case .soft: "needs"
        case .control: "REQUIRES"
        case .ink: "wants"
        }
    }

    func capNeedsAuth(_ t: ThemeID) -> String {
        switch t {
        case .soft: "needs sign-in"
        case .control: "NO TOKEN"
        case .ink: "unsealed"
        }
    }

    func capProbeFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Didn't connect"
        case .control: "PROBE FAILED"
        case .ink: "it would not answer"
        }
    }

    func capToolCount(_ t: ThemeID, _ count: Int) -> String {
        switch t {
        case .soft: count == 1 ? "1 tool" : "\(count) tools"
        case .control: "\(count) TOOLS"
        case .ink: count == 1 ? "one instrument" : "\(count) instruments"
        }
    }

    func capSharedTag(_ t: ThemeID) -> String {
        switch t {
        case .soft: "shared"
        case .control: "SHARED"
        case .ink: "held in common"
        }
    }

    func capPortable(_ t: ThemeID) -> String {
        switch t {
        case .soft: "package"
        case .control: "PKG v1"
        case .ink: "a bundle"
        }
    }

    func capOn(_ t: ThemeID) -> String {
        switch t {
        case .soft: "on"
        case .control: "ENABLED"
        case .ink: "granted"
        }
    }

    func capOff(_ t: ThemeID) -> String {
        switch t {
        case .soft: "off"
        case .control: "DISABLED"
        case .ink: "withheld"
        }
    }

    func capPinned(_ t: ThemeID) -> String {
        switch t {
        case .soft: "pinned"
        case .control: "PINNED"
        case .ink: "fixed"
        }
    }

    func capUnpinned(_ t: ThemeID) -> String {
        switch t {
        case .soft: "gateway default"
        case .control: "DEFAULT"
        case .ink: "as the gateway wills"
        }
    }

    func capSkillsNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Toggles change this bot's own skills. Shared skills come from the gateway and apply to every bot."
        case .control: "TOGGLES WRITE THE PROFILE'S DISABLED-SKILL LIST. SHARED ROWS ARE GATEWAY-WIDE, READ-ONLY HERE."
        case .ink: "What you strike through is withheld from this familiar alone. Gifts held in common are the gateway's, and not yours to alter here."
        }
    }

    func capToolsetsNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Fewer toolsets means a shorter tool list in the prompt — the difference between a small model coping and not. Tap a row to see its tools."
        case .control: "FEWER TOOLSETS = SHORTER TOOL BLOCK IN THE SYSTEM PROMPT. SMALL MODELS DEPEND ON IT. TAP A ROW FOR ITS TOOLS."
        case .ink: "The fewer instruments it carries, the lighter its mind. Touch a row to see what each holds."
        }
    }

    func capOAuthNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The gateway catches the redirect, not this phone — finish the sign-in and it completes there."
        case .control: "REDIRECT IS CAUGHT BY THE GATEWAY'S LOOPBACK LISTENER, NOT THE HANDSET."
        case .ink: "The way itself receives the reply; finish, and it is caught there."
        }
    }

    func capOAuthDone(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Signed in — tokens are on the gateway."
        case .control: "AUTHENTICATED — TOKENS STORED GATEWAY-SIDE."
        case .ink: "Leave was granted; the token rests with the gateway."
        }
    }

    func capOAuthTimeout(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Still waiting — finish the sign-in, then test the server again."
        case .control: "FLOW STILL PENDING — COMPLETE SIGN-IN, THEN RE-PROBE."
        case .ink: "It waits yet. Finish, then sound the way again."
        }
    }

    func capOAuthFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Sign-in didn't complete."
        case .control: "AUTH FLOW FAILED."
        case .ink: "Leave was not granted."
        }
    }

    func capOAuthNoURL(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The gateway didn't return a sign-in link."
        case .control: "NO AUTH URL RETURNED."
        case .ink: "No door was named."
        }
    }

    func capRemoveTitle(_ t: ThemeID, _ name: String) -> String {
        switch t {
        case .soft: "Remove \(name)?"
        case .control: "REMOVE \(name.uppercased())?"
        case .ink: "Strike \(name) from the record?"
        }
    }

    func capRemoveBody(_ t: ThemeID) -> String {
        switch t {
        case .soft: "It's deleted from this bot's config on the gateway. Stored credentials stay in .env."
        case .control: "DELETED FROM THE PROFILE'S CONFIG.YAML. .ENV CREDENTIALS PERSIST."
        case .ink: "It is struck from this familiar's config. What keys were entrusted remain."
        }
    }

    func capDisableTitle(_ t: ThemeID, _ name: String) -> String {
        switch t {
        case .soft: "Turn off \(name)?"
        case .control: "DISABLE \(name.uppercased())?"
        case .ink: "Withhold \(name)?"
        }
    }

    func capDisableBody(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Gateway plugins affect every bot. Turning off the push relay stops notifications reaching this phone."
        case .control: "PLUGINS ARE GATEWAY-WIDE. DISABLING THE PUSH RELAY ENDS NOTIFICATION DELIVERY."
        case .ink: "These serve the whole house. Withhold the herald, and no tidings reach you."
        }
    }

    func capNoticeLead(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The gateway refused that"
        case .control: "GATEWAY REFUSED"
        case .ink: "The way answered ill"
        }
    }

    func capEmpty(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Nothing configured yet — install an MCP server from the catalog, or add skills on the gateway."
        case .control: "NO CAPABILITIES REPORTED FOR THIS PROFILE."
        case .ink: "No gifts are recorded against this familiar."
        }
    }

    func capUnavailable(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This gateway doesn't expose capability management. Update Hermes on the gateway to manage skills, MCP servers and toolsets from here."
        case .control: "GATEWAY EXPOSES NO CAPABILITY RPCS. UPDATE HERMES SERVE-SIDE."
        case .ink: "This way keeps no register of gifts. A newer Hermes upon the gateway would."
        }
    }

    func capFootnote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Skills and toolsets are per-bot. MCP servers are written to this bot's config; plugins are gateway-wide."
        case .control: "SKILLS + TOOLSETS ARE PER-PROFILE · MCP IS PER-PROFILE CONFIG · PLUGINS ARE GATEWAY-WIDE."
        case .ink: "Gifts and instruments belong to the familiar; the appendages belong to the house."
        }
    }
}
