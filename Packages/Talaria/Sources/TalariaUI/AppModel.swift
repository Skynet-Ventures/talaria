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
    /// Ephemeral identity for this exact in-memory chat. It is intentionally
    /// not persisted or sent over the wire; response alternatives are scoped
    /// to this object rather than a reused profile id.
    public let chatIdentity: UUID
    public var messages: [ChatMessage]
    public var isTyping: Bool = false
    /// Runtime session id (live mode).
    public var sessionID: String? {
        didSet {
            if oldValue != sessionID {
                clearAssistantResponseAlternatives()
                // nil -> concrete is the normal first-submit bind and keeps
                // its locally observed origin. Any established binding moving
                // elsewhere must wait for new live/resume timing evidence.
                if oldValue != nil { turnStartedAt = nil }
            }
        }
    }
    /// Durable session key for resume-after-reconnect.
    public var storedSessionID: String? {
        didSet {
            if oldValue != storedSessionID {
                clearAssistantResponseAlternatives()
                if oldValue != nil { turnStartedAt = nil }
            }
        }
    }
    public var usage: Usage?
    public var yolo: Bool = false
    /// Session reasoning effort ("" = gateway default).
    public var reasoningEffort: String = ""
    /// A turn is in flight — the composer's send button becomes stop.
    public var isRunning: Bool = false
    /// Current-process live timing evidence. It is never hydrated from a
    /// historical transcript row; a current Hermes resume may seed it from
    /// `turn_started_at` after bounded clock validation.
    public var turnStartedAt: Date?
    /// A failed-turn retry owns this chat's composer, including while its
    /// authoritative preflight is suspended before any turn is running.
    public var hasUnresolvedRetry: Bool = false
    /// Files staged on the composer, consumed by the next submit.
    public var attachments: [PendingAttachment] = []
    /// Stored sessions for this bot (session.list), for the sessions sheet.
    public var storedSessions: [SessionSummary] = []
    /// Live context-window breakdown (session.context_breakdown).
    public var contextSegments: [ContextSegment] = []

    /// Current-ChatState only. This shelf never participates in Codable
    /// transcript storage or session-tree/branch persistence.
    public var assistantResponseAlternatives = AssistantResponseAlternatives()
    public var assistantResponseBinding: AssistantResponseAlternativesBinding?

    public init(messages: [ChatMessage] = [], chatIdentity: UUID = UUID()) {
        self.chatIdentity = chatIdentity
        self.messages = messages
    }

    public func clearAssistantResponseAlternatives() {
        assistantResponseAlternatives = AssistantResponseAlternatives()
        assistantResponseBinding = nil
        ChatRuntime.shared.clearAssistantResponseAlternativeStages(
            chatID: ObjectIdentifier(self))
    }

    public var isShowingArchivedResponseAlternative: Bool {
        assistantResponseAlternatives.isShowingArchived
    }

    public var assistantResponseGroups: [AssistantResponseAlternativeGroup] {
        assistantResponseAlternatives.groups
    }

    public func displayedMessages() -> [ChatMessage] {
        AssistantResponseAlternativesPolicy.displayedMessages(
            current: messages, state: assistantResponseAlternatives,
            // `assistantResponseBinding` is the latest live source used for
            // lifecycle/hydration fencing.  Display selection is instead
            // group-addressable: an older surviving source turn may be
            // selected while a newer group remains in the same shelf.
            binding: assistantResponseAlternatives.selectedGroup?.binding)
    }

    public func selectPreviousAssistantResponse() {
        assistantResponseAlternatives = AssistantResponseAlternativesPolicy.previous(
            in: assistantResponseAlternatives)
    }

    @discardableResult
    public func selectAssistantResponseGroup(
        _ groupID: UUID, archivedIndex: Int? = nil
    ) -> Bool {
        let next = AssistantResponseAlternativesPolicy.select(
            groupID: groupID, archivedIndex: archivedIndex,
            in: assistantResponseAlternatives)
        guard next != assistantResponseAlternatives else { return false }
        assistantResponseAlternatives = next
        return true
    }

    public func selectNextAssistantResponse() {
        assistantResponseAlternatives = AssistantResponseAlternativesPolicy.next(
            in: assistantResponseAlternatives)
    }

    public func resetAssistantResponseSelection() {
        assistantResponseAlternatives = AssistantResponseAlternativesPolicy.resetSelection(
            in: assistantResponseAlternatives)
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
    var composeFlushRequested = false
    /// Compare-and-swap claims for dispatch. They remain in memory so Stop can
    /// synchronously park the durable row while pre-wire work is suspended.
    var durableComposerQueueClaims: Set<UUID> = []
    /// A text editor reserves exactly one source-qualified row. A reservation
    /// is intentionally distinct from a dispatch claim: it blocks FIFO drain
    /// at that row without treating the row as in-flight work.
    struct DurableComposerQueueEditReservation: Equatable {
        var botID: String
        var key: DurableComposerQueueKey
    }
    var durableComposerQueueEditReservations: [UUID: DurableComposerQueueEditReservation] = [:]
    struct DurableComposerQueueWireSubmission: Equatable {
        var id: UUID
        var key: DurableComposerQueueKey
        var runtimeSessionID: String
    }
    /// Exact pre-receipt wire attempts. message.start may precede the RPC
    /// acknowledgement, including for a chat that is not currently visible.
    var durableComposerQueueWireSubmissions: [UUID: DurableComposerQueueWireSubmission] = [:]
    var durableComposerQueueStartsBeforeReceipt: Set<UUID> = []
    /// Live prompts the gateway parked behind the current turn (`queued: true`).
    public var promptQueue: [(id: UUID, botID: String, text: String)] = []
    /// The durable authority for local queue rows and accepted gateway mirrors.
    public let durableComposerQueueStore: DurableComposerQueueStore
    public internal(set) var durableComposerQueueEntries: [DurableComposerQueueEntry] = []
    /// Accepted gateway work can be hidden from the current panel but remains
    /// persisted until authoritative execution/transcript proof removes it.
    var hiddenAcceptedQueueIDs: Set<UUID> = []

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

    public init(queueStore: DurableComposerQueueStore? = nil) {
        if let queueStore {
            durableComposerQueueStore = queueStore
        } else if NSClassFromString("XCTestCase") != nil {
            // Keep unrelated UI tests independent from a developer device's
            // Application Support envelope. Durable-queue tests inject their
            // own URL and therefore still exercise real persistence.
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("talaria-test-queue-\(UUID().uuidString).json")
            durableComposerQueueStore = DurableComposerQueueStore(fileURL: url)
        } else {
            durableComposerQueueStore = DurableComposerQueueStore.shared
        }
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
        reloadDurableComposerQueueProjection()
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
        composeFlushRequested = false
        durableComposerQueueClaims = []
        durableComposerQueueEditReservations = [:]
        promptQueue = []
        // Source-qualified entries deliberately survive a demo/live world
        // transition. Only their visible compatibility projection resets.
        durableComposerQueueEntries = durableComposerQueueStore.allEntries()
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
        // Compatibility callers (normal Send/Steer/offline recovery) retain
        // their existing optimistic, in-memory lifecycle. Only the explicit
        // Queue control may create replayable durable authority.
        composeQueue.append((botID: botID, text: text))
        composeQueueIDs.append(id)
        if route != nil || storedID != nil || sessionID != nil || chatID != nil {
            composeQueueBindings[id] = ComposeQueueBinding(botID: botID, route: route,
                storedID: storedID, sessionID: sessionID, chatID: chatID)
        }
    }

    /// Rebuild the legacy tuples as a projection of the durable authority.
    /// Source-qualified rows are never rebound by bare profile name.
    func reloadDurableComposerQueueProjection() {
        normalizeComposeQueueIDs()
        let persisted = durableComposerQueueStore.allEntries()
        let previousDurableIDs = Set(durableComposerQueueEntries.map(\.id))
        let persistedIDs = Set(persisted.map(\.id))
        // Attachment-bearing recovery rows and ordinary steer mirrors remain
        // intentionally in-memory: Hermes cannot prove their replayable
        // attachment/session ownership. A durable projection refresh must
        // merge around them, never erase them as collateral damage.
        let legacyCompose = zip(composeQueue, composeQueueIDs).filter {
            !previousDurableIDs.contains($0.1) && !persistedIDs.contains($0.1)
        }
        let legacyComposeIDs = Set(legacyCompose.map(\.1))
        let legacyComposeBindings = composeQueueBindings.filter {
            legacyComposeIDs.contains($0.key)
        }
        let legacyPrompt = promptQueue.filter {
            !previousDurableIDs.contains($0.id) && !persistedIDs.contains($0.id)
        }
        for id in previousDurableIDs.subtracting(persistedIDs) {
            ChatRuntime.shared.queuedBindings[id] = nil
        }
        durableComposerQueueEntries = persisted
        let local = persisted.filter { $0.state != .acceptedGatewayOwned }
        composeQueue = legacyCompose.map(\.0)
            + local.map { (botID: durableBotID(for: $0.key), text: $0.text) }
        composeQueueIDs = legacyCompose.map(\.1) + local.map(\.id)
        composeQueueBindings = legacyComposeBindings
        for (id, binding) in local.map({ entry in
            (entry.id, ComposeQueueBinding(
                botID: durableBotID(for: entry.key), route: entry.key.route,
                storedID: entry.key.storedSessionID, sessionID: nil, chatID: nil))
        }) {
            composeQueueBindings[id] = binding
        }
        let accepted = persisted.filter {
            $0.state == .acceptedGatewayOwned && !hiddenAcceptedQueueIDs.contains($0.id)
        }
        promptQueue = legacyPrompt
            + accepted.map { (id: $0.id, botID: durableBotID(for: $0.key), text: $0.text) }
        // Retain identity-bearing execution bindings across a projection
        // rebuild. An accepted row is gateway-owned, but an exact subsequent
        // start event still needs this source/session proof to retire only its
        // matching local mirror; never match by text.
        for entry in accepted {
            let botID = durableBotID(for: entry.key)
            ChatRuntime.shared.queuedBindings[entry.id] = QueuedPromptBinding(
                botID: botID, sessionID: chats[botID]?.sessionID ?? "",
                storedID: entry.key.storedSessionID, route: entry.key.route,
                eligibleAfterCurrentTurn: true, order: entry.order)
        }
    }

    private func durableBotID(for key: DurableComposerQueueKey) -> String {
        if LiveRuntime.shared.gatewayID == key.gatewayID { return key.profile }
        return key.route.qualifiedID
    }

    /// The exact current source/session fence for a local queue row.
    func durableQueueKey(botID: String, chat: ChatState? = nil) -> DurableComposerQueueKey? {
        let route = stateRoute(for: botID) ?? gatewayRoute(for: botID)
            ?? GatewayBotRoute(qualifiedID: botID)
        let storedID = (chat ?? chats[botID])?.storedSessionID
        guard let route, let storedID, !storedID.isEmpty else { return nil }
        return DurableComposerQueueKey(route: route, storedSessionID: storedID)
    }

    /// Persist before showing any queued presentation. This is intentionally
    /// text-only and never creates a transcript bubble.
    @discardableResult
    func enqueueDurableLocalPrompt(_ text: String, botID: String,
                                   chat: ChatState, attachments: Int = 0) -> UUID? {
        guard let key = durableQueueKey(botID: botID, chat: chat) else {
            chat.messages.append(ChatMessage(author: .system,
                text: "This prompt cannot be queued until the exact durable session is available."))
            return nil
        }
        do {
            let entry = try durableComposerQueueStore.enqueue(
                key: key, text: text, attachments: attachments)
            reloadDurableComposerQueueProjection()
            if composeFlushActive { composeFlushRequested = true }
            return entry.id
        } catch {
            chat.messages.append(ChatMessage(author: .system, text: error.localizedDescription))
            return nil
        }
    }

    /// Dispatch claims and edit reservations both block a FIFO head. A row
    /// being edited must not be skipped or sent with stale text.
    @discardableResult
    func claimDurableComposerEntry(id: UUID) -> Bool {
        guard let entry = durableComposerQueueStore.entry(id: id),
              entry.state.isAutomaticallyReplayable,
              durableComposerQueueEditReservations[id] == nil,
              durableComposerQueueClaims.insert(id).inserted else { return false }
        return true
    }

    func releaseDurableComposerEntryClaim(_ id: UUID) {
        durableComposerQueueClaims.remove(id)
    }

    func registerDurableComposerWireSubmission(
        id: UUID, key: DurableComposerQueueKey, runtimeSessionID: String
    ) {
        durableComposerQueueWireSubmissions[id] = DurableComposerQueueWireSubmission(
            id: id, key: key, runtimeSessionID: runtimeSessionID)
        durableComposerQueueStartsBeforeReceipt.remove(id)
    }

    /// Runs before visible-chat event admission. A queued prompt may execute
    /// while its chat is closed, and message.start can race ahead of the RPC
    /// receipt; source + runtime sid + FIFO order identify the exact attempt.
    func noteDurableComposerQueueStart(
        runtimeSessionID: String, sourceGatewayID: String?
    ) {
        guard let sourceGatewayID else { return }
        let candidate = durableComposerQueueWireSubmissions.values
            .filter {
                $0.runtimeSessionID == runtimeSessionID
                    && $0.key.gatewayID == sourceGatewayID
            }
            .min {
                (durableComposerQueueStore.entry(id: $0.id)?.order ?? UInt64.max)
                    < (durableComposerQueueStore.entry(id: $1.id)?.order ?? UInt64.max)
            }
        if let candidate { durableComposerQueueStartsBeforeReceipt.insert(candidate.id) }
    }

    /// Release the pre-receipt token and report whether message.start already
    /// proved gateway execution for this exact durable identity.
    func finishDurableComposerWireSubmission(id: UUID) -> Bool {
        durableComposerQueueWireSubmissions[id] = nil
        return durableComposerQueueStartsBeforeReceipt.remove(id) != nil
    }

    /// Begin an edit only for the exact source/session currently displayed.
    /// Returning the entry gives the view a snapshot but the reservation, not
    /// that snapshot, is the authority for a later save.
    @discardableResult
    public func beginEditingDurableQueuedPrompt(id: UUID, botID: String)
        -> DurableComposerQueueEntry? {
        guard let key = durableQueueKey(botID: botID),
              let entry = durableComposerQueueStore.entry(id: id),
              entry.key == key, entry.state.isLocallyEditable,
              !durableComposerQueueClaims.contains(id),
              durableComposerQueueEditReservations[id] == nil else { return nil }
        durableComposerQueueEditReservations[id] = DurableComposerQueueEditReservation(
            botID: botID, key: key)
        return entry
    }

    /// Save only the reservation's exact source/session. Any lifecycle or
    /// session replacement invalidates the edit rather than rewriting another
    /// row. Reservations release on both success and failure.
    @discardableResult
    public func saveEditingDurableQueuedPrompt(id: UUID, botID: String,
                                               text: String) -> Bool {
        guard let reservation = durableComposerQueueEditReservations[id] else { return false }
        defer { durableComposerQueueEditReservations[id] = nil }
        guard reservation.botID == botID,
              durableQueueKey(botID: botID) == reservation.key,
              durableComposerQueueStore.entry(id: id)?.key == reservation.key else { return false }
        do {
            _ = try durableComposerQueueStore.replaceLocalText(id: id, text: text)
            reloadDurableComposerQueueProjection()
            if composeFlushActive { composeFlushRequested = true }
            return true
        } catch {
            chat(for: botID).messages.append(ChatMessage(author: .system,
                text: "That queued prompt was not changed: \(error.localizedDescription)"))
            reloadDurableComposerQueueProjection()
            return false
        }
    }

    /// Cancel is intentionally fence-aware: a reused UUID from another queue
    /// key cannot release an unrelated reservation.
    public func cancelEditingDurableQueuedPrompt(id: UUID, botID: String) {
        guard let reservation = durableComposerQueueEditReservations[id],
              reservation.botID == botID else { return }
        durableComposerQueueEditReservations[id] = nil
    }

    /// Profile/gateway lifecycle calls this before its first remote mutation.
    /// If the write fails, the lifecycle must not proceed with replayable rows
    /// still committed under an about-to-change source route.
    @discardableResult
    func parkDurableComposerQueueForLifecycle(route: GatewayBotRoute) -> Bool {
        do {
            try durableComposerQueueStore.park(route: route)
            reloadDurableComposerQueueProjection()
            return true
        } catch {
            durableComposerQueueEntries = durableComposerQueueStore.allEntries()
            return false
        }
    }

    /// A definitively refused lifecycle operation leaves its original route
    /// authoritative. Re-open only rows that were parked by that exact route;
    /// a persistence failure keeps them parked and lets the caller retain its
    /// lifecycle fence rather than silently turning local work replayable.
    @discardableResult
    func resumeDurableComposerQueueForLifecycle(route: GatewayBotRoute) -> Bool {
        do {
            try durableComposerQueueStore.resume(route: route)
            reloadDurableComposerQueueProjection()
            return true
        } catch {
            durableComposerQueueEntries = durableComposerQueueStore.allEntries()
            return false
        }
    }

    /// Commit the source-qualified half only after Hermes has authoritatively
    /// accepted the lifecycle operation. Rename preserves FIFO/order; delete
    /// removes the exact source rows. A failed write leaves parked source rows
    /// in place rather than replaying them under a guessed destination.
    func commitDurableComposerQueueLifecycle(
        from source: GatewayBotRoute, to destination: GatewayBotRoute? = nil
    ) throws {
        if let destination {
            try durableComposerQueueStore.migrateRouteAndResume(
                from: source, to: destination)
        } else {
            try durableComposerQueueStore.remove(route: source)
        }
        reloadDurableComposerQueueProjection()
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

    @discardableResult
    public func send(text: String, to botID: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let chat = chat(for: botID)
        chat.resetAssistantResponseSelection()
        if isOffline && GatewayBotRoute(qualifiedID: botID) == nil {
            // Normal Send keeps the existing optimistic recovery semantics.
            // Only the explicit Queue affordance is bubble-free; an ordinary
            // offline send may still lack a stored-session key and must remain
            // visible/recoverable through the current failure lifecycle.
            let optimistic = ChatMessage(author: .user, time: Self.clock(), text: text)
            chat.messages.append(optimistic)
            appendComposeQueue(botID: botID, text: text,
                               route: stateRoute(for: botID) ?? gatewayRoute(for: botID),
                               storedID: chat.storedSessionID, sessionID: chat.sessionID,
                               chatID: ObjectIdentifier(chat))
            return true
        }
        let optimistic = ChatMessage(author: .user, time: Self.clock(), text: text)
        chat.messages.append(optimistic)
        switch mode {
        case .demo: demoReply(botID: botID, chat: chat)
        case .live:
            liveSendSerialized(text: text, botID: botID, chat: chat,
                               optimisticID: optimistic.id)
        }
        return true
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
