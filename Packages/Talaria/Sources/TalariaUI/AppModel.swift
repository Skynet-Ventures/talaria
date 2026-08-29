import SwiftUI
import TalariaKit
import TalariaTheme

// The app's observable state tree. Two modes:
// - demo: the onboarding "Explore with demo data" path — canned roster,
//   scripted replies, simulated pushes. Mirrors the design prototype and
//   gives App Review the full experience without a gateway.
// - live: bound to a GatewayClient; RPCs + events drive the same state.

public enum AppMode: Sendable, Equatable {
    case demo
    case live
}

/// Per-bot chat state.
@MainActor
@Observable
public final class ChatState {
    public var messages: [ChatMessage]
    public var isTyping: Bool = false
    /// Runtime session id (live mode).
    public var sessionID: String?
    /// Durable session key for resume-after-reconnect.
    public var storedSessionID: String?
    public var usage: Usage?
    public var yolo: Bool = false
    /// Session reasoning effort ("" = gateway default).
    public var reasoningEffort: String = ""
    /// A turn is in flight — the composer's send button becomes stop.
    public var isRunning: Bool = false
    /// A failed-turn retry owns this chat's composer, including while its
    /// authoritative preflight is suspended before any turn is running.
    public var hasUnresolvedRetry: Bool = false
    /// Files staged on the composer, consumed by the next submit.
    public var attachments: [PendingAttachment] = []
    /// Stored sessions for this bot (session.list), for the sessions sheet.
    public var storedSessions: [SessionSummary] = []
    /// Live context-window breakdown (session.context_breakdown).
    public var contextSegments: [ContextSegment] = []
    /// The visible transcript is the newest REST window, not the full store.
    /// `loadOlderTranscript` prepends the next page when this is true.
    public var transcriptHasOlder: Bool = false
    /// REST `offset` for the next older `order=latest` page.
    public var transcriptOlderOffset: Int = 0
    public var isLoadingOlderTranscript: Bool = false

    public init(messages: [ChatMessage] = []) {
        self.messages = messages
    }

    func resetTranscriptWindow() {
        transcriptHasOlder = false
        transcriptOlderOffset = 0
        isLoadingOlderTranscript = false
    }
}

@MainActor
@Observable
public final class AppModel {
    public var mode: AppMode = .demo
    public let theme = ThemeManager()

    // Roster + surfaces
    public var bots: [Bot] = []
    public var approvals: [Approval] = []
    public var activity: [ActivityDay] = []
    public var agentInbox: [A2AMessage] = []
    public var routines: [Routine] = []
    public var artifacts: [Artifact] = []
    public var connections: [GatewayConnection] = []
    public var notificationPrefs: [NotificationPref] = []
    public var chats: [String: ChatState] = [:]
    public var memory: [String: BotMemory] = [:]
    public var sessions: [String: [SessionSummary]] = [:]
    public var contextMeter: [ContextSegment] = []
    public var models: [String] = []
    public var skills: [String] = []

    // Navigation
    public var selectedTab: CopyPack.Tab = .home
    public var openBotID: String?
    public var showOnboarding: Bool
    public var isOffline: Bool = false
    /// Messages composed while unreachable; flushed on reconnect.
    public var composeQueue: [(botID: String, text: String)] = []
    /// Stable identity for each compose row. The tuple remains source
    /// compatible for existing views, while flush/rekey removes only the
    /// exact row that crossed its own await.
    var composeQueueIDs: [UUID] = []
    struct ComposeQueueBinding: Equatable {
        var botID: String
        var route: GatewayBotRoute?
        var storedID: String?
        var sessionID: String?
        var chatID: ObjectIdentifier?
    }
    var composeQueueBindings: [UUID: ComposeQueueBinding] = [:]
    var composeFlushActive = false
    /// Live prompts the gateway parked behind the current turn (`queued: true`).
    public var promptQueue: [(id: UUID, botID: String, text: String)] = []

    // Live mode
    public var client: GatewayClient?
    /// Out-of-process exact-session navigation is retained outside the visible
    /// chat tree until launch restore and source/profile authority are ready.
    let exactStoredSessionRouteQueue = ExactStoredSessionRouteQueue()
    /// User-initiated gateway teardown invalidates exact-session source
    /// authority synchronously, before the pool/client cleanup can suspend.
    /// The count lets overlapping sign-out/remove actions retain the fence
    /// until every teardown has crossed its durable row/credential boundary.
    var exactStoredSessionSourceInvalidations: Set<String> = []
    var exactStoredSessionSourceTeardownCounts: [String: Int] = [:]
    /// Focused integration-test seams around network/RPC boundaries. Queue,
    /// launch readiness, source/credential validation, and retry behavior stay
    /// on the production path.
    var exactStoredSessionSourceReadinessOverride:
        (@MainActor (ExactStoredSessionRoute) async throws -> Bool)?
    var exactStoredSessionOpenOverride:
        (@MainActor (ExactStoredSessionRoute) async throws -> Void)?
    /// One-shot launch restore guard. `launchWorldRestoreCompleted` cannot
    /// serve this role because it deliberately stays false across the awaited
    /// connection attempt so deferred exact-session routes remain parked.
    var launchWorldRestoreStarted = false
    var launchWorldRestoreCompleted = false
    /// Focused test seams for launch selection and the one network boundary.
    /// Nil in production. The saved-row override keeps package tests isolated
    /// from a developer device's real UserDefaults without changing the
    /// production credential lookup or ordering policy.
    var launchSavedGatewaysOverrideForTesting: [SavedGateway]?
    var launchConnectOverrideForTesting:
        (@MainActor (URL, GatewayCredential) async throws -> Void)?

    public init() {
        showOnboarding = !UserDefaults.standard.bool(forKey: "talaria-onboarded")
        ConnectionRegistry.shared.setSecondaryTeardown { [weak self] gatewayID, expected in
            await self?.detachRoutedEvents(gatewayID: gatewayID, expected: expected)
        }
        ConnectionRegistry.shared.setSecondaryRefresh { [weak self] gatewayIDs in
            self?.exactStoredSessionSecondarySourcesDidRefresh(gatewayIDs)
            Task { @MainActor [weak self] in
                guard let self else { return }
                for gatewayID in gatewayIDs.sorted() {
                    await self.pullAndReseedRoomProjection(gatewayID: gatewayID)
                }
            }
        }
    }

    // MARK: - Demo mode

    /// True while the canned demo world is loaded. Drives the exit affordance
    /// in Connections and the flush when a real gateway connects.
    public internal(set) var demoDataLoaded = false

    /// UserDefaults key remembering that demo was the user's explicit choice,
    /// so relaunches restore the same world.
    public static let demoChoiceKey = "talaria-demo-chosen"

    public func enterDemoMode() {
        mode = .demo
        demoDataLoaded = true
        UserDefaults.standard.set(true, forKey: Self.demoChoiceKey)
        bots = DemoData.bots
        approvals = DemoData.approvals
        activity = DemoData.activity
        agentInbox = DemoData.agentInbox
        routines = DemoData.routines
        artifacts = DemoData.artifacts
        connections = DemoData.connections
        notificationPrefs = DemoData.notificationPrefs
        memory = DemoData.memory
        sessions = DemoData.sessions
        contextMeter = DemoData.contextMeter
        models = DemoData.models
        skills = DemoData.skills
        chats = DemoData.chats.mapValues { ChatState(messages: $0) }
    }

    public func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "talaria-onboarded")
        showOnboarding = false
    }

    /// Leave the demo world for the honest empty state (notification prefs
    /// are real device settings and survive; saved gateways re-appear from
    /// the registry).
    public func exitDemoMode() {
        flushDemoWorld()
        connections = ConnectionRegistry.shared.rows
    }

    /// Re-run onboarding from the first step.
    public func resetOnboarding() {
        UserDefaults.standard.removeObject(forKey: "talaria-onboarded")
        showOnboarding = true
    }

    /// Launch restore, in order of intent: reconnect the first eligible saved
    /// gateway in the registry's existing deterministic order; else reload the
    /// demo world if that was the explicit choice; else stay honest and empty.
    public func restoreWorldAtLaunch() async {
        // An early call while onboarding or after another world already won is
        // not the launch attempt. Keep the one-shot guard available for the
        // later eligible lifecycle call.
        guard mode == .demo, bots.isEmpty, !showOnboarding else { return }
        guard !launchWorldRestoreStarted else { return }
        launchWorldRestoreStarted = true
        defer { completeLaunchWorldRestore() }
        let registry = ConnectionRegistry.shared
        let saved = launchSavedGatewaysOverrideForTesting ?? registry.saved
        let selected = saved.lazy.compactMap { gateway
            -> (gateway: SavedGateway, base: URL, credential: GatewayCredential)? in
            guard let base = gateway.baseURL,
                  let credential = registry.credential(for: gateway) else { return nil }
            return (gateway, base, credential)
        }.first

        if let selected {
            do {
                try await runManagedCloudBootEpisode(
                    sourceURL: selected.base, gatewayID: selected.gateway.id
                ) {
                    if let launchConnectOverrideForTesting = self.launchConnectOverrideForTesting {
                        try await launchConnectOverrideForTesting(
                            selected.base, selected.credential)
                    } else {
                        try await self.connectGateway(
                            baseURL: selected.base, credential: selected.credential)
                    }
                }
            } catch is ManagedCloudBootSupersededError {
                // Another primary connection won while this launch attempt
                // was suspended. Do not mark the selected saved row offline:
                // this stale attempt has no result to publish.
            } catch {
                // The selected saved source outranks demo. Keep its honest
                // offline row visible and stop; another saved gateway is not
                // an implicit failover target.
                registry.noteState(.offline, forURL: selected.base)
                connections = registry.rows
            }
            return
        }

        // Demo remains a fallback only when there is no credentialed saved
        // source to select at all.
        if UserDefaults.standard.bool(forKey: Self.demoChoiceKey) {
            enterDemoMode()
        } else {
            connections = registry.rows
        }
    }

    /// Drop every demo-populated surface. Called on exit and when a real
    /// gateway connection replaces the demo world.
    func flushDemoWorld() {
        demoDataLoaded = false
        UserDefaults.standard.removeObject(forKey: Self.demoChoiceKey)
        bots = []
        approvals = []
        activity = []
        agentInbox = []
        routines = []
        artifacts = []
        chats = [:]
        memory = [:]
        sessions = [:]
        contextMeter = []
        composeQueue = []
        composeQueueIDs = []
        composeQueueBindings = [:]
        promptQueue = []
        openBotID = nil
        selectedTab = .home
        // A toast is an answer about a world that no longer exists once this
        // returns — a demo pin confirming itself over a live roster, or over
        // the honest empty one (Components/ToastBus.swift).
        ToastBus.shared.clear()
    }

    // MARK: - Shared actions (mode-dispatched; live paths in AppModel+Live)

    public func chat(for botID: String) -> ChatState {
        if let existing = chats[botID] { return existing }
        let fresh = ChatState()
        chats[botID] = fresh
        return fresh
    }

    func normalizeComposeQueueIDs() {
        if composeQueueIDs.count > composeQueue.count {
            composeQueueIDs.removeLast(composeQueueIDs.count - composeQueue.count)
        }
        while composeQueueIDs.count < composeQueue.count {
            composeQueueIDs.append(UUID())
        }
        let valid = Set(composeQueueIDs)
        composeQueueBindings = composeQueueBindings.filter { valid.contains($0.key) }
    }

    func appendComposeQueue(botID: String, text: String, id: UUID = UUID(),
                            route: GatewayBotRoute? = nil, storedID: String? = nil,
                            sessionID: String? = nil, chatID: ObjectIdentifier? = nil) {
        normalizeComposeQueueIDs()
        guard !composeQueueIDs.contains(id) else { return }
        composeQueue.append((botID: botID, text: text))
        composeQueueIDs.append(id)
        if route != nil || storedID != nil || sessionID != nil || chatID != nil {
            composeQueueBindings[id] = ComposeQueueBinding(botID: botID, route: route,
                storedID: storedID, sessionID: sessionID, chatID: chatID)
        }
    }

    func reconcileComposeQueueIDs(sources: Set<String>, destination: String?) {
        normalizeComposeQueueIDs()
        guard destination == nil else { return }
        let retained = zip(composeQueue, composeQueueIDs).filter {
            !sources.contains($0.0.botID)
        }
        composeQueue = retained.map { $0.0 }
        composeQueueIDs = retained.map { $0.1 }
        let valid = Set(composeQueueIDs)
        composeQueueBindings = composeQueueBindings.filter { valid.contains($0.key) }
    }

    func migrateComposeQueueRoute(from sourceBotID: String, to destinationBotID: String,
                                  fromRoute: GatewayBotRoute, toRoute: GatewayBotRoute,
                                  storedID: String, sessionID: String,
                                  chatID: ObjectIdentifier) {
        normalizeComposeQueueIDs()
        for index in composeQueue.indices {
            let id = composeQueueIDs[index]
            guard composeQueue[index].botID == sourceBotID,
                  let binding = composeQueueBindings[id],
                  binding.botID == sourceBotID, binding.route == fromRoute,
                  binding.storedID == storedID, binding.sessionID == sessionID,
                  binding.chatID == chatID else { continue }
            composeQueue[index].botID = destinationBotID
            composeQueueBindings[id] = ComposeQueueBinding(
                botID: destinationBotID, route: toRoute, storedID: storedID,
                sessionID: sessionID, chatID: chatID)
        }
    }

    func migrateComposeQueueSession(botID: String, route: GatewayBotRoute,
                                    oldSessionID: String, newSessionID: String,
                                    storedID: String, chatID: ObjectIdentifier) {
        normalizeComposeQueueIDs()
        for id in composeQueueIDs {
            guard let binding = composeQueueBindings[id], binding.botID == botID,
                  binding.route == route, binding.sessionID == oldSessionID,
                  binding.storedID == storedID, binding.chatID == chatID else { continue }
            composeQueueBindings[id]?.sessionID = newSessionID
        }
    }

    func rekeyComposeQueueRoute(from sourceBotID: String, to destinationBotID: String,
                                fromRoute: GatewayBotRoute, toRoute: GatewayBotRoute) {
        normalizeComposeQueueIDs()
        for index in composeQueue.indices {
            let id = composeQueueIDs[index]
            guard composeQueue[index].botID == sourceBotID,
                  let binding = composeQueueBindings[id], binding.botID == sourceBotID,
                  binding.route == fromRoute else { continue }
            composeQueue[index].botID = destinationBotID
            composeQueueBindings[id]?.botID = destinationBotID
            composeQueueBindings[id]?.route = toRoute
        }
    }

    func retireComposeQueue(botID: String, storedID: String?, chatID: ObjectIdentifier?) {
        normalizeComposeQueueIDs()
        let retained = zip(composeQueue, composeQueueIDs).filter { item, id in
            guard item.botID == botID, let binding = composeQueueBindings[id] else { return true }
            let exactChat = chatID.map { binding.chatID == $0 } ?? false
            let exactStored = storedID.map { binding.storedID == $0 } ?? false
            return !(exactChat || exactStored)
        }
        composeQueue = retained.map { $0.0 }
        composeQueueIDs = retained.map { $0.1 }
        let valid = Set(composeQueueIDs)
        composeQueueBindings = composeQueueBindings.filter { valid.contains($0.key) }
    }

    public func bot(_ id: String) -> Bot? {
        bots.first { $0.id == id }
    }

    public func send(text: String, to botID: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let chat = chat(for: botID)
        let optimistic = ChatMessage(author: .user, time: Self.clock(), text: text)
        chat.messages.append(optimistic)

        if isOffline && GatewayBotRoute(qualifiedID: botID) == nil {
            appendComposeQueue(botID: botID, text: text,
                               route: stateRoute(for: botID) ?? gatewayRoute(for: botID),
                               storedID: chat.storedSessionID, sessionID: chat.sessionID,
                               chatID: ObjectIdentifier(chat))
            return
        }
        switch mode {
        case .demo: demoReply(botID: botID, chat: chat)
        case .live:
            liveSendSerialized(text: text, botID: botID, chat: chat,
                               optimisticID: optimistic.id)
        }
    }

    public func resolveApproval(_ approval: Approval, approve: Bool) {
        approvals.removeAll { $0.id == approval.id }
        if case .live = mode {
            liveResolveApproval(approval, approve: approve)
        } else {
            let chat = chat(for: approval.botID)
            chat.messages.append(ChatMessage(
                author: .system,
                text: approve ? "Approved · \(approval.title)" : "Denied · \(approval.title)"))
        }
    }

    public func toggleRoutine(_ routine: Routine) {
        guard let idx = routines.firstIndex(where: { $0.id == routine.id }) else { return }
        routines[idx].isOn.toggle()
        if case .live = mode { liveToggleRoutine(routines[idx]) }
    }

    public func pendingApprovalCount(for botID: String? = nil) -> Int {
        botID.map { id in approvals.filter { $0.botID == id }.count } ?? approvals.count
    }

    /// Working bots drive the Live Activity / Dynamic Island.
    public var workingBots: [Bot] {
        bots.filter { $0.status == .working }
    }

    // MARK: - Demo behaviors

    private func demoReply(botID: String, chat: ChatState) {
        chat.isTyping = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Double.random(in: 0.9...1.8)))
            chat.isTyping = false
            let reply = DemoData.cannedReplies[botID] ?? DemoData.cannedReplies["default"]!
            chat.messages.append(ChatMessage(author: .bot, time: Self.clock(), text: reply))
        }
    }

    static func clock() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }
}
