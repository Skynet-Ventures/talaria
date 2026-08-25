import Combine
import SwiftUI
import TalariaKit
import TalariaTheme

// The screen graph, ported from the prototype's flat `state.screen` switch and
// extended with the surfaces the live gateway needs:
//
//   reauth/offline banner (displaces content, zero-height when healthy)
//   ── roster ⇄ chat (push) ── bot sheet / routines (push) / voice (z20)
//   ── activity / approvals / agent inbox / artifacts (tabs)
//   ── connections, capabilities (push z12), new-bot + sessions sheets
//   ── search palette (z48) · push banner (z40) · onboarding (z50)
//   blocking prompts + mcp setup (above everything) · control scanlines
//
// TalariaRootView(model:) is the app target's single mount point: it applies
// the theme background, hosts every overlay and sheet, registers the live
// event routers once per connection, runs the demo push cycle, and wires the
// push/live-activity controllers to the model.
//
// Cross-screen navigation that doesn't fit a callback goes through
// NotificationCenter — `.talariaOpenConnections`, `.talariaOpenCapabilities`
// (AppModel.requestCapabilities) and `.talariaOpenSessions` — so a screen this
// view doesn't own can ask for a push without a binding threaded through it.

/// Reports the on-stage push banner's height up to the root, so the toast stack
/// can offset under it. Zero when no banner is mounted, which is the default and
/// every live session.
private struct BannerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

public struct TalariaRootView: View {
    private let model: AppModel

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.talariaReducedMotion) private var environmentReducedMotion

    // Presentation state the model doesn't own (the model keeps routing state
    // other screens drive: selectedTab, openBotID, showOnboarding).
    @State private var showSearch = false
    @State private var showCreate = false
    @State private var showCreateMenu = false
    @State private var showCreateRoom = false
    @State private var showProfile = false
    @State private var showVoice = false
    @State private var showConnections = false
    @State private var routinesBotID: String?

    // Screens reached from the palette, the chat header and cross-screen
    // notifications rather than from a tab.
    @State private var capabilitiesRequest: CapabilitiesRequest?
    @State private var sessionsRequest: SessionsRequest?
    @State private var commandCenterRequest: CommandCenterRequest?
    @State private var pendingTerminalRequest: CommandCenterRequest?

    /// Capabilities opens on a profile, and `nil` means "the gateway's launch
    /// profile" — a real value — so presentation can't key off the profile
    /// alone.
    private struct CapabilitiesRequest: Identifiable, Equatable {
        let id = UUID()
        let profile: String?
    }

    /// Keyed by bot so a second request for the same bot is a no-op rather
    /// than a re-present.
    private struct SessionsRequest: Identifiable, Equatable {
        var id: String { botID }
        let botID: String
    }

    /// A fresh identity allows Command Center to be presented again after a
    /// dismissal even when the requested source is unchanged. The model
    /// resolves ordinary Settings requests to an available source before it
    /// posts; the optional keeps this receiver honest for direct notifications.
    private struct CommandCenterRequest: Identifiable, Equatable {
        let id = UUID()
        let gatewayID: String?
        let profile: String?
        let terminalResume: String?
    }

    // Demo push banner cycle.
    @State private var activeBanner: BannerPush?
    /// Height of the banner currently on stage, so the toast stack can sit
    /// under it instead of over it. Zero whenever there is no banner.
    @State private var bannerHeight: CGFloat = 0

    // Theme-swap flash (tSwapX/tSwapY).
    @State private var themeSwapDim = false

    public init(model: AppModel) {
        self.model = model
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    /// The tab bar lives only on the five tab screens.
    private var showsTabBar: Bool {
        model.openBotID == nil && model.openRoomID == nil
            && routinesBotID == nil && !showConnections
            && capabilitiesRequest == nil && !showVoice && !model.showOnboarding
    }

    /// The prototype suppresses banner pushes on voice / onboarding / search.
    /// They also require the demo world to actually be loaded — the empty
    /// real state gets no fake pushes.
    private var bannersAllowed: Bool {
        model.demoDataLoaded && !model.showOnboarding && !showSearch && !showVoice
    }

    /// Per-tab counts. Approvals shows blocked work; Bots carries the unread
    /// total so traffic is visible from the other four tabs (openChat clears
    /// a bot's count, so the badge drains as you read).
    private var tabBadges: [CopyPack.Tab: Int] {
        var badges: [CopyPack.Tab: Int] = [:]
        let pending = model.pendingApprovalCount()
        if pending > 0 { badges[.approvals] = pending }
        let unread = model.totalRosterUnread
        if unread > 0 { badges[.home] = unread }
        return badges
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            theme.bg
                .ignoresSafeArea()
                .animation(TalariaMotionTokens.opacityAnimation(.standard,
                                                          reducedMotion: reducedMotion),
                           value: theme.id)

            // The re-auth / offline banner is zero-height while the link is
            // healthy, so stacking it above the graph costs nothing and means
            // it displaces content instead of covering a header. It also owns
            // the connection-supervision loop, so it must be mounted once for
            // the life of the app.
            VStack(spacing: 0) {
                ReauthBanner(model: model)
                // Settings pushes over the screen graph but under the parked-
                // agent prompts below: a blocked tool thread outranks a
                // preferences screen.
                screenGraph
                    .talariaSettings(model: model)
                    // Approval policy stacks ABOVE Settings, because Settings is
                    // one of the two places that opens it — pushing it under
                    // would hide it behind the screen that asked for it.
                    .talariaApprovalPolicy(model: model)
                    // Solo (roadmap Phase 5) mounts the same way, in the order
                    // it is opened: the chat, then its settings, then the
                    // explainer that Solo settings pushes. Each renders nothing
                    // until its notification arrives, so mounting all three
                    // costs a modifier and buys every route in — the Settings
                    // section, the chat header, the explainer's own footer.
                    .talariaSolo(model: model)
                    .talariaSoloSettings(model: model)
                    .talariaSoloExplainer(model: model)
            }
            .opacity(themeSwapDim ? 0.3 : 1)
            .scaleEffect(reducedMotion ? 1 : (themeSwapDim ? 0.982 : 1))

            // The toast stack (Components/ToastBus.swift). Deliberately OUTSIDE
            // the VStack above: Settings, the approval-policy screen and Solo
            // all push over the screen graph from modifiers applied inside it,
            // so a toast mounted in `screenGraph` would be covered by the very
            // screen that fired it.
            //
            // No zIndex, on purpose. The two overlays below carry none either,
            // and in a ZStack an explicit zIndex sorts above every default-0
            // sibling regardless of declaration order — stamping one here would
            // lift toasts over the parked-agent prompts, which outrank
            // everything because a tool thread is blocked on the answer.
            // Declaration order puts this exactly where it belongs: over the
            // screen graph, under those prompts.
            //
            // The inset is the one collision the two surfaces genuinely have:
            // the demo push banner is on stage for 4.8 s and a demo mutation can
            // toast underneath it. Its own height, so they stack rather than
            // overlap; zero the rest of the time, which is every live session.
            ToastHost(model: model, topInset: activeBanner == nil ? 0 : bannerHeight + 8)

            // Parked-agent prompts (z55). Mounted unconditionally — each
            // renders nothing until its request arrives, and each outranks
            // every other surface, banner included, because a tool thread is
            // blocked on the answer.
            BlockingPromptOverlay(model: model)
            MCPSetupPrompt(model: model)

            if theme.id == .control {
                ScanlineOverlay()
            }
        }
        .onPreferenceChange(BannerHeightKey.self) { bannerHeight = $0 }
        .preferredColorScheme(theme.statusBarDark ? .dark : .light)
        .tint(theme.accent)
        // Appearance (Settings → Appearance) is app-wide, so it is adopted at
        // the one mount point every screen hangs off. Text size overrides
        // Dynamic Type for the whole tree; `talariaMotion` publishes the motion
        // preference already merged with the device's own setting, so a view
        // reads one bool and never has to know which switch asked for stillness.
        .talariaTextSize(model)
        .talariaMotion(model)
        .sheet(isPresented: $showProfile) {
            if let id = model.openBotID {
                BotSheetView(model: model, botID: id)
            }
        }
        .sheet(isPresented: $showCreate) {
            CreateBotView(model: model)
        }
        .sheet(isPresented: $showCreateRoom) {
            CreateRoomView(model: model) { roomID in
                withAnimation(pushAnimation) {
                    model.openBotID = nil
                    model.openRoomID = roomID
                }
            }
        }
        .confirmationDialog("Create", isPresented: $showCreateMenu,
                            titleVisibility: .visible) {
            Button("Agent") { showCreate = true }
            Button("Group Room") { showCreateRoom = true }
                .disabled(model.unionRosterBots.count < RoomEngine.minimumMembers)
            Button("Cancel", role: .cancel) {}
        } message: {
            if model.unionRosterBots.count < RoomEngine.minimumMembers {
                Text("Connect at least two agents before creating a room.")
            } else {
                Text("Create one agent or a room shared by agents across your gateways.")
            }
        }
        .sheet(item: $sessionsRequest, onDismiss: {
            guard let pending = pendingTerminalRequest else { return }
            pendingTerminalRequest = nil
            commandCenterRequest = pending
        }) { request in
            // onOpen fires after the sheet has already rebound the chat, so
            // this only has to clear the way to it.
            SessionsSheet(model: model, botID: request.botID,
                          onOpenTerminal: { gatewayID, profile, resume in
                pendingTerminalRequest = CommandCenterRequest(
                    gatewayID: gatewayID, profile: profile,
                    terminalResume: resume)
                sessionsRequest = nil
            }) { _ in
                sessionsRequest = nil
                revealChat()
            }
        }
        .sheet(item: $commandCenterRequest) { request in
            CommandCenterView(model: model, initialGatewayID: request.gatewayID,
                              initialProfile: request.profile,
                              initialTerminalResume: request.terminalResume)
                .presentationBackground(theme.bg)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: model.theme.themeID) { runThemeSwapAnimation() }
        .onChange(of: model.openBotID) {
            if model.openBotID == nil {
                // Leaving chat tears down everything stacked on it.
                routinesBotID = nil
                showVoice = false
                showProfile = false
            } else {
                model.openRoomID = nil
                // One rule for every route into a chat — palette, banner,
                // deep link, activity row: entering pops what covered it.
                revealChat()
            }
        }
        .onChange(of: model.openRoomID) {
            guard model.openRoomID != nil else { return }
            model.openBotID = nil
            routinesBotID = nil
            showVoice = false
            showProfile = false
            revealChat()
        }
        .onChange(of: clientToken) { attachEventRouters() }
        // `connectGateway` assigns the client, awaits the dial, and only then
        // sets `mode = .live` — so a render landing inside that await sees a
        // client while every router's `mode == .live` guard is still false, and
        // `clientToken` never changes again to give them a second chance.
        // Every attach is idempotent, so re-running them on the mode edge costs
        // nothing and closes that window.
        .onChange(of: model.mode) { attachEventRouters() }
        .onChange(of: scenePhase) {
            // Foregrounding is when a parked socket has to be re-established
            // and any approval resolved from a notification has to be caught up.
            if scenePhase == .active { model.applicationDidBecomeActive() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .talariaApplicationDidBecomeActive
        )) { _ in
            // UIApplicationDelegate is the authoritative iOS wake edge. The
            // model coalesces this with scenePhase so a normal foreground does
            // one exact-source liveness validation, while a scenePhase miss
            // after screen lock can no longer strand a dead socket.
            model.applicationDidBecomeActive()
        }
        .onAppear { wireUp() }
        .onReceive(NotificationCenter.default.publisher(for: .talariaOpenConnections)) { _ in
            // talaria://connections deep links and gateway pushes; this view
            // owns the Connections navigation push.
            guard !showConnections else { return }
            withAnimation(pushAnimation) { showConnections = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .talariaOpenCapabilities)) { note in
            withAnimation(pushAnimation) {
                capabilitiesRequest = CapabilitiesRequest(
                    profile: note.userInfo?["profile"] as? String)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .talariaOpenCommandCenter)) { note in
            guard commandCenterRequest == nil else { return }
            commandCenterRequest = CommandCenterRequest(
                gatewayID: note.userInfo?["gatewayID"] as? String,
                profile: note.userInfo?["profile"] as? String,
                terminalResume: note.userInfo?["terminalResume"] as? String)
        }
        .onReceive(NotificationCenter.default.publisher(for: .talariaOpenSessions)) { note in
            // object carries the bot id; fall back to whatever chat is open.
            if let botID = (note.object as? String) ?? model.openBotID {
                sessionsRequest = SessionsRequest(botID: botID)
            }
        }
        .task { await runDemoPushCycle() }
    }

    // MARK: - Screen graph

    private var screenGraph: some View {
        ZStack {
            tabContent

            // Chat, pushed over the roster (any tab can deep-link into it).
            if let botID = model.openBotID {
                ZStack {
                    theme.bg.ignoresSafeArea()
                    ChatView(model: model, botID: botID,
                             onOpenProfile: { showProfile = true },
                             onRoutines: { withAnimation(pushAnimation) { routinesBotID = botID } },
                             onVoice: { withAnimation(sheetAnimation) { showVoice = true } })
                }
                .modifier(ChatSwipeBack(onBack: closeOpenChat))
                .transition(pushTransition)
            }

            // Rooms are stable, device-local identities layered over exact
            // source-qualified Hermes sessions. They use the same push depth
            // as a bot chat, so opening either one replaces the other.
            if let roomID = model.openRoomID {
                ZStack {
                    theme.bg.ignoresSafeArea()
                    RoomView(model: model, roomID: roomID)
                }
                .transition(pushTransition)
            }

            // Routines, pushed from chat.
            if let botID = routinesBotID {
                ZStack {
                    theme.bg.ignoresSafeArea()
                    RoutinesView(model: model, botID: botID,
                                 onBack: { withAnimation(pushAnimation) { routinesBotID = nil } })
                }
                .transition(pushTransition)
            }

            // Connections, pushed from the net chip / activity / search.
            if showConnections {
                ZStack {
                    theme.bg.ignoresSafeArea()
                    ConnectionsView(model: model,
                                    onBack: { withAnimation(pushAnimation) { showConnections = false } })
                }
                .transition(pushTransition)
            }

            // Capabilities, pushed over whatever asked for it (palette,
            // Connections, bot sheet) — above chat so the bot sheet's row
            // lands on top of the chat it was opened from.
            if let request = capabilitiesRequest {
                ZStack {
                    theme.bg.ignoresSafeArea()
                    CapabilitiesView(model: model, profileID: request.profile,
                                     onBack: { closeCapabilities() })
                }
                .transition(pushTransition)
                .zIndex(12)
            }

            // Tab bar (z15).
            if showsTabBar {
                VStack(spacing: 0) {
                    Spacer()
                    TalariaTabBar(theme: theme, copy: copy,
                                  selected: model.selectedTab,
                                  badges: tabBadges) { tab in
                        withAnimation(TalariaMotionTokens.opacityAnimation(
                            .standard, reducedMotion: reducedMotion
                        )) {
                            model.selectedTab = tab
                        }
                    }
                }
                .transition(.opacity)
            }

            // Search palette (z48–49).
            if showSearch {
                SearchPalette(model: model, isPresented: $showSearch) { action in
                    route(action)
                }
                .transition(.opacity)
                .zIndex(48)
            }

            // Voice overlay (z20 — above chat, below banner).
            if showVoice, let botID = model.openBotID {
                VoiceView(model: model, botID: botID, isPresented: $showVoice)
                    .transition(TalariaMotionTokens.verticalOverlayTransition(
                        edge: .bottom, reducedMotion: reducedMotion))
                    .zIndex(20)
            }

            // Push banner (z40).
            if let banner = activeBanner {
                VStack {
                    bannerView(banner)
                        // Measured rather than guessed: the toast stack sits
                        // above this and offsets by exactly this much while a
                        // banner is on stage, and the card's height moves with
                        // Dynamic Type and with the approve/later row.
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: BannerHeightKey.self,
                                                       value: proxy.size.height)
                            }
                        )
                    Spacer()
                }
                .transition(TalariaMotionTokens.verticalOverlayTransition(
                    edge: .top, reducedMotion: reducedMotion))
                .zIndex(40)
            }

            // Onboarding cover (z50).
            if model.showOnboarding {
                OnboardingView(model: model)
                    .transition(.opacity)
                    .zIndex(50)
            }
        }
        .animation(pushAnimation, value: model.openBotID)
        .animation(TalariaMotionTokens.opacityAnimation(.deliberate,
                                                  reducedMotion: reducedMotion),
                   value: model.showOnboarding)
    }

    @ViewBuilder private var tabContent: some View {
        Group {
            switch model.selectedTab {
            case .home:
                RosterView(model: model,
                           onSearch: { showSearch = true },
                           onCreate: { showCreateMenu = true },
                           onConnections: { withAnimation(pushAnimation) { showConnections = true } })
            case .activity:
                ActivityView(model: model,
                             onOpenConnections: { withAnimation(pushAnimation) { showConnections = true } })
            case .approvals:
                ApprovalsView(model: model)
            case .a2a:
                AgentInboxView(model: model)
            case .artifacts:
                ArtifactsView(model: model)
            }
        }
        .id(model.selectedTab)
        .transition(.opacity)
    }

    // MARK: - Palette routing

    private func route(_ action: SearchPaletteAction) {
        switch action {
        case .newBot:
            showCreate = true
        case .addGateway:
            withAnimation(pushAnimation) { showConnections = true }
        case .tab(let tab):
            goToTab(tab)
        case .capabilities:
            openCapabilities()
        case .settings:
            // Same shape as capabilities: the request is a notification, so
            // the presenter mounted on the screen graph does the push.
            model.requestSettings()
        case .approvalPolicy:
            model.requestApprovalPolicy()
        case .sessions(let botID):
            openSessions(for: botID)
        case .openSession(let botID, let sessionID):
            openStoredSession(botID: botID, sessionID: sessionID)
        }
    }

    /// Capabilities (skills / toolsets / MCP) deliberately has no tab of its
    /// own — five is the prototype's tab budget. It is reached from the search
    /// palette, from Connections and from the bot sheet; all three go through
    /// `requestCapabilities`, whose notification lands back here.
    private func openCapabilities() {
        model.requestCapabilities(profile: model.openBotID ?? model.defaultCapabilityProfile)
    }

    private func closeCapabilities() {
        withAnimation(pushAnimation) { capabilitiesRequest = nil }
    }

    /// A tab is only reachable once everything pushed over it is gone.
    private func goToTab(_ tab: CopyPack.Tab) {
        withAnimation(pushAnimation) {
            model.openBotID = nil
            model.openRoomID = nil
            showConnections = false
            capabilitiesRequest = nil
            routinesBotID = nil
            model.selectedTab = tab
        }
    }

    private func openSessions(for botID: String) {
        sessionsRequest = SessionsRequest(botID: botID)
    }

    /// A cross-session search hit: rebind that bot's chat onto the picked
    /// session (openStoredSession also selects the bot and the home tab) and
    /// clear the way to it.
    private func openStoredSession(botID: String, sessionID: String) {
        model.openStoredSession(sessionID, botID: botID)
        revealChat()
    }

    /// Pop whatever is stacked over the chat so a freshly bound session is
    /// actually what the user sees.
    private func revealChat() {
        withAnimation(pushAnimation) {
            showConnections = false
            capabilitiesRequest = nil
            routinesBotID = nil
        }
    }

    // MARK: - Transitions

    private var pushTransition: AnyTransition {
        TalariaMotionTokens.pushTransition(reducedMotion: reducedMotion)
    }

    private func closeOpenChat() {
        withAnimation(pushAnimation) { model.openBotID = nil }
    }

    private var pushAnimation: Animation? {
        TalariaMotionTokens.opacityAnimation(.standard, reducedMotion: reducedMotion)
    }
    private var sheetAnimation: Animation? {
        TalariaMotionTokens.opacityAnimation(.deliberate, reducedMotion: reducedMotion)
    }

    /// Root publishes the merged value to descendants, but also computes it
    /// directly so transitions owned by the publisher itself obey the same
    /// setting during the render in which it changes.
    private var reducedMotion: Bool {
        environmentReducedMotion
            || model.settings.prefersReducedMotion(system: systemReduceMotion)
    }

    // MARK: - Theme swap (tSwapX / tSwapY)

    private func runThemeSwapAnimation() {
        var snap = Transaction()
        snap.disablesAnimations = true
        withTransaction(snap) { themeSwapDim = true }
        withAnimation(TalariaMotionTokens.opacityAnimation(.standard,
                                                      reducedMotion: reducedMotion)) {
            themeSwapDim = false
        }
    }

    // MARK: - Wiring

    private func wireUp() {
        // Restore the last world: saved gateway → live; explicit demo choice
        // → demo; otherwise the honest empty roster.
        Task { await model.restoreWorldAtLaunch() }
        PushCoordinator.shared.configure(model: model)
        LiveActivityController.shared.attach(to: model)
        // Covers a remount onto an already-connected client; the usual path is
        // the clientToken change below.
        attachEventRouters()
    }

    /// Identity of the live client, so the routers re-register when a
    /// connection is made, swapped or torn down. Each router is idempotent and
    /// no-ops without a client, so calling them all on every change is safe.
    private var clientToken: ObjectIdentifier? {
        model.client.map(ObjectIdentifier.init)
    }

    /// Every feature that needs its own gateway-event subscription registers
    /// here, once per connection. The main pump in AppModelLive ignores the
    /// events these own.
    private func attachEventRouters() {
        model.attachChatEventRouter()
        model.attachApprovalBridges()
        model.attachSessionEventRouter()
        model.attachActivityRouter()
        model.attachVoiceRouter()
        model.attachCommandsEventRouter()
        model.attachPetEventRouter()
        // Not an event subscription but the same lifecycle: the liveness
        // watches (foreground re-seed, network-restore nudge, phantom reaper)
        // are per-gateway bookkeeping, so they arm here and re-scope when the
        // client is swapped or torn down.
        model.startLivenessSupervision()
    }

    // MARK: - Demo push banners

    /// The prototype's `cycleBanner`: first banner 8s in, then one every ~14s,
    /// visible for 4.8s. Suppressed during onboarding, search and voice; the
    /// cycle only runs against demo data.
    private func runDemoPushCycle() async {
        try? await Task.sleep(for: .seconds(8))
        var index = 0
        while !Task.isCancelled {
            presentDemoBanner(BannerPush.demoCycle[index % BannerPush.demoCycle.count])
            index += 1
            try? await Task.sleep(for: .seconds(14))
            if Task.isCancelled { return }
        }
    }

    private func presentDemoBanner(_ push: BannerPush) {
        guard bannersAllowed else { return }
        withAnimation(TalariaMotionTokens.opacityAnimation(.deliberate,
                                                      reducedMotion: reducedMotion)) {
            activeBanner = push
        }
        let shownID = push.id
        Task {
            try? await Task.sleep(for: .seconds(4.8))
            if activeBanner?.id == shownID {
                withAnimation(TalariaMotionTokens.opacityAnimation(.quick,
                                                              reducedMotion: reducedMotion)) {
                    activeBanner = nil
                }
            }
        }
    }

    private func bannerView(_ banner: BannerPush) -> some View {
        let pendingApproval = banner.approvalID.flatMap { id in
            model.approvals.first { $0.id == id }
        }
        return PushBanner(
            theme: theme, copy: copy, push: banner,
            bot: banner.botID == "gateway" ? nil : model.bot(banner.botID),
            showsApprovalActions: banner.kind == .approval && pendingApproval != nil,
            onTap: { routeBanner(banner) },
            onApprove: {
                if let approval = pendingApproval {
                    ApprovalOutcomes.shared.resolve(approval, approve: true, in: model)
                }
                withAnimation(TalariaMotionTokens.opacityAnimation(.quick,
                                                              reducedMotion: reducedMotion)) {
                    activeBanner = nil
                }
            },
            onLater: {
                withAnimation(TalariaMotionTokens.opacityAnimation(.quick,
                                                              reducedMotion: reducedMotion)) {
                    activeBanner = nil
                }
            })
    }

    /// bannerGo — approval → Approvals, gateway → Connections, else that
    /// bot's chat.
    private func routeBanner(_ banner: BannerPush) {
        withAnimation(TalariaMotionTokens.opacityAnimation(.fast,
                                                      reducedMotion: reducedMotion)) {
            activeBanner = nil
        }
        switch banner.kind {
        case .approval:
            withAnimation(pushAnimation) {
                model.openBotID = nil
                model.openRoomID = nil
                showConnections = false
                model.selectedTab = .approvals
            }
        case .gateway:
            withAnimation(pushAnimation) { showConnections = true }
        default:
            withAnimation(pushAnimation) {
                showConnections = false
                // openChat, not a raw openBotID write — the banner has to land
                // in the bot's canonical chat with its history, like every
                // other route in.
                model.openChat(botID: banner.botID)
            }
        }
    }
}

// MARK: - Cross-screen navigation requests

public extension Notification.Name {
    /// Browse a bot's stored sessions. `object` is the bot id (String);
    /// nil falls back to the open chat. Posted by the chat header and the bot
    /// sheet so neither has to thread a callback through RootView.
    /// (Capabilities has the same shape — `.talariaOpenCapabilities`, declared
    /// with `AppModel.requestCapabilities(profile:)` in AppModelLive+Capabilities.)
    static let talariaOpenSessions = Notification.Name("bot.talaria.openSessions")
}

// MARK: - Scanline overlay (control)

/// The CRT scanline wash over everything in the control theme — 1pt lines on
/// a 3pt pitch at 1.6% white, hit-testing disabled (z60).
private struct ScanlineOverlay: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            while y < size.height {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                             with: .color(Color.white.opacity(0.016)))
                y += 3
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}


/// Left-edge interactive pop for the custom chat overlay. The drag lives on
/// a leading hit target so the transcript can still scroll; committing it
/// uses the same `openBotID = nil` path as the header back button.
private struct ChatSwipeBack: ViewModifier {
    var onBack: () -> Void
    @State private var offset: CGFloat = 0
    @Environment(\.talariaReducedMotion) private var reducedMotion

    func body(content: Content) -> some View {
        GeometryReader { geo in
            content
                .frame(width: geo.size.width, height: geo.size.height)
                .offset(x: offset)
                .overlay(alignment: .leading) {
                    Color.clear
                        .frame(width: ChatSwipeBackPolicy.edgeWidth)
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            DragGesture(minimumDistance: ChatSwipeBackPolicy.minimumDistance)
                                .onChanged { value in
                                    guard ChatSwipeBackPolicy.shouldBegin(startX: value.startLocation.x) else { return }
                                    offset = reducedMotion ? 0 : max(0, value.translation.width)
                                }
                                .onEnded { value in
                                    let commit = ChatSwipeBackPolicy.shouldBegin(startX: value.startLocation.x)
                                        && ChatSwipeBackPolicy.shouldCommit(
                                            translationX: value.translation.width,
                                            predictedX: value.predictedEndTranslation.width,
                                            containerWidth: geo.size.width)
                                    if commit {
                                        onBack()
                                        offset = 0
                                    } else {
                                        withAnimation(TalariaMotionTokens.spatialAnimation(
                                            .quick, reducedMotion: reducedMotion
                                        )) { offset = 0 }
                                    }
                                }
                        )
                }
        }
    }
}
