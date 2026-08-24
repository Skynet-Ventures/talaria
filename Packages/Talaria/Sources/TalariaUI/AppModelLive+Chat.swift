import Foundation
import TalariaKit
import TalariaTheme

// The chat surface's live behaviors: the stop control, mid-turn steering,
// tool-call routing into the transcript, and message reactions.
//
// Event routing note: AppModel.handle(event:) (AppModelLive.swift, another
// owner) already pumps message/approval events. Rather than reach into it,
// this file registers a SECOND handler on the client — its own AsyncStream
// pump, so tool.start → tool.complete stay in wire order among themselves —
// and routes only what chat-core owns: ChatState.isRunning and the ToolCall
// list hanging off each assistant message. RootView calls
// `attachChatEventRouter()` after every connect; it is idempotent per client.

// MARK: - Chat runtime (side table)

/// Storage for chat-core's live state. `AppModel`'s stored properties live in
/// AppModel.swift (another owner) and extensions cannot add storage, so this
/// rides in a MainActor singleton like LiveRuntime does.
@MainActor
final class ChatRuntime {
    static let shared = ChatRuntime()

    /// The client the router is attached to — re-attaching to the same client
    /// would double every tool chip.
    weak var routedClient: GatewayClient?
    var routerHandler: UUID?
    var pump: Task<Void, Never>?

    /// Index of the first message of the current turn, per bot. Tool chips
    /// only ever attach at or after it, so a tool that starts before the first
    /// token can't land on the previous turn's bubble.
    var turnFloor: [String: Int] = [:]

    /// Exact local rows reconstructed from a retained failed turn. Canonical
    /// history may legitimately omit them, so hydration receives this
    /// identity set rather than trying to rediscover the turn from repeated
    /// prompt text. Keyed by ChatState identity to prevent same runtime ids on
    /// two gateways from sharing evidence.
    var retainedFailureRows: [ObjectIdentifier: Set<UUID>] = [:]
    var dismissedFailures: [ObjectIdentifier: DismissedTurnFailure] = [:]
    /// Retry keeps the failed row/card intact until the exact prepared token
    /// crosses the submit boundary. Only that submitting lease may reuse the
    /// assistant on message.start/complete/resume; an unrelated start cancels
    /// a merely prepared lease without touching its card.
    var failedRetryRows: [String: FailedTurnRetryLease] = [:]

    /// A submit that never produces message.start must not leave the composer
    /// stuck on Stop (RPC accepted, gateway wedged, socket died mid-flight).
    var submitWatchdogs: [String: Task<Void, Never>] = [:]

    /// Demo replies, cancellable so the demo stop button means something.
    var demoTurns: [String: Task<Void, Never>] = [:]

    /// message id → this device's emoji. ChatMessage has no reactions field
    /// and Models.swift belongs to another owner; the gateway remains the
    /// source of truth, this is the local echo.
    var reactions: [UUID: String] = [:]

    /// Exactly one destructive transcript operation may own a bot/session at a
    /// time. `transcriptFences` survives the request until an authoritative
    /// resume + hydration resolves an ambiguous acceptance.
    var transcriptActions: [String: UUID] = [:]
    var transcriptActionGenerations: [String: Int] = [:]
    /// The identity-bearing lease behind `transcriptActions`. The UUID map is
    /// retained for the existing admission checks, while this side table lets
    /// a profile lifecycle rollback the exact optimistic projection when the
    /// destructive RPC had not crossed acceptance, or retain a no-replay
    /// fence when it had.
    var transcriptLeases: [String: TranscriptActionLease] = [:]
    var transcriptFences: [String: TranscriptActionFence] = [:]
    /// A regenerate's old assistant run is staged here until the destructive
    /// submit has an accepted receipt or an exact later effect proof. It is
    /// never a navigable alternative while this lease is ambiguous.
    var assistantResponseAlternativeStages: [String: AssistantResponseAlternativeStage] = [:]

    /// Mid-turn mutations are no-replay operations too. A lost `steer` or
    /// `redirect` receipt must not fall through to the next verb: the gateway
    /// may already have accepted the first one. Keep the exact request here
    /// until a resume/transcript read proves what happened.
    var steerActions: [String: SteerMutationLease] = [:]
    var steerFences: [String: SteerMutationFence] = [:]

    /// An interrupt is a mutation too. While one is in flight the visible
    /// turn remains running; an uncertain answer leaves this fence in place so
    /// a new prompt cannot race the unknown stop.
    var stopActions: [String: StopTurnLease] = [:]
    var stopFences: [String: StopTurnFence] = [:]
    /// Lower-wire interrupt seam for focused admission/drain races.
    var interruptForTesting:
        (@MainActor (GatewayClient, String) async throws -> Void)?

    /// At most one authoritative retry may be in flight for a bot. Retained
    /// mutation/kickoff fences are deliberately not replayed; this coalescer
    /// only schedules read/resume reconciliation when a reconnect, adoption,
    /// or user tap gives us a fresh opportunity to prove the old operation.
    var reconciliationTasks: [String: Task<Void, Never>] = [:]
    var reconciliationTokens: [String: UUID] = [:]
    var reconcilingBots: Set<String> = []
    /// A stop tap that arrived while another mutation owned the bot. It is a
    /// user intent, not a second interrupt; drain it only after the owner has
    /// settled or retained fence reconciliation has had its read attempt. The
    /// value is the exact binding at the tap, not merely the profile name:
    /// reusing a bot id for a newly-opened session must never inherit A's stop.
    var pendingStopRequests: [String: PendingStopRequest] = [:]
    /// A steer/stop/kickoff fence created while a different authoritative
    /// read was active. Retry the read after that owner releases the bot.
    var deferredReconciliationBots: Set<String> = []

    /// Local mirrors of gateway-accepted queued prompts. The public tuple in
    /// AppModel remains presentation-only; this side table supplies exact
    /// session identity and lifecycle eligibility without text deduplication.
    var queuedBindings: [UUID: QueuedPromptBinding] = [:]
    var queuedLifecycles: [QueuedPromptSession: QueuedPromptLifecycle] = [:]
    var pendingQueuedSubmissions: [QueuedPromptSession: [PendingQueuedSubmission]] = [:]
    var nextQueuedSubmissionOrder: UInt64 = 0
    /// An offline row whose submit crossed the wire but lost its response or
    /// binding proof. It must remain queued for presentation, but never be
    /// replayed automatically until an authoritative bind clears this fence.
    var offlineComposeFences: [UUID: OfflineComposeFence] = [:]

    func pruneTranscriptState(botID: String, generation: Int) {
        if transcriptActionGenerations[botID].map({ $0 != generation }) == true {
            transcriptActions[botID] = nil
            transcriptActionGenerations[botID] = nil
        }
        // An ambiguous destructive submit survives a connection generation.
        // Only authoritative hydration of the same source/session, or an
        // explicit bind to a different durable session, may retire it.
    }

    func clearAssistantResponseAlternativeStage(botID: String,
                                                chatID: ObjectIdentifier? = nil) {
        guard let stage = assistantResponseAlternativeStages[botID] else { return }
        if let chatID, stage.chatID != chatID { return }
        assistantResponseAlternativeStages[botID] = nil
    }

    func clearAssistantResponseAlternativeStages(chatID: ObjectIdentifier) {
        assistantResponseAlternativeStages = assistantResponseAlternativeStages.filter {
            $0.value.chatID != chatID
        }
    }

    /// A reconnect may assign a new runtime sid to the same durable session.
    /// The operation boundary belongs to the durable binding, not the old
    /// sid, so unresolved leases/fences must move with it. A different route
    /// or an unproven durable key is a replacement session and retires the
    /// old state instead.
    func migrateMutationState(botID: String, route: GatewayBotRoute,
                              sessionID: String, storedID: String?,
                              generation: Int, chatID: ObjectIdentifier,
                              oldSessionID: String? = nil) {
        if var action = steerActions[botID] {
            if action.route == route, Self.sameDurable(action.storedID, storedID) {
                action.sessionID = sessionID
                action.generation = generation
                steerActions[botID] = action
            } else {
                steerActions[botID] = nil
            }
        }
        if var fence = steerFences[botID] {
            if fence.route == route, Self.sameDurable(fence.storedID, storedID) {
                fence.sessionID = sessionID
                fence.generation = generation
                steerFences[botID] = fence
            } else {
                steerFences[botID] = nil
            }
        }
        if var action = stopActions[botID] {
            if action.route == route, Self.sameDurable(action.storedID, storedID) {
                action.sessionID = sessionID
                action.generation = generation
                stopActions[botID] = action
            } else {
                stopActions[botID] = nil
            }
        }
        // An unaddressable stop is held by the reattach path below; it has no
        // old route/session to migrate and must not be mistaken for a stale
        // operation merely because its sentinel route differs.
        if var fence = stopFences[botID], !fence.unaddressable {
            if fence.route == route, Self.sameDurable(fence.storedID, storedID) {
                fence.sessionID = sessionID
                fence.generation = generation
                stopFences[botID] = fence
            } else {
                stopFences[botID] = nil
            }
        }
        if var fence = transcriptFences[botID] {
            if fence.gatewayID == route.gatewayID, fence.profile == route.profile,
               fence.storedID == (storedID ?? ""), !fence.storedID.isEmpty,
               (fence.chatID == nil || fence.chatID == chatID) {
                fence.sessionID = sessionID
                fence.generation = generation
                transcriptFences[botID] = fence
            } else {
                transcriptFences[botID] = nil
            }
        }
        if var retry = failedRetryRows[botID] {
            if let oldSessionID, retry.sessionID == oldSessionID,
               retry.route == route, retry.chatID == chatID,
               Self.sameDurable(retry.storedID, storedID) {
                retry.sessionID = sessionID
                failedRetryRows[botID] = retry
            } else {
                failedRetryRows[botID] = nil
            }
        }
        migratePendingStop(botID: botID, route: route, sessionID: sessionID,
                           storedID: storedID, generation: generation, chatID: chatID)
    }

    /// Move a deferred stop across a runtime-sid rotation only when the route,
    /// durable session, and exact ChatState are unchanged. A changed durable
    /// binding is a new conversation, even when the profile id is reused.
    func migratePendingStop(botID: String, route: GatewayBotRoute,
                            sessionID: String, storedID: String?,
                            generation: Int, chatID: ObjectIdentifier) {
        guard var pending = pendingStopRequests[botID] else { return }
        guard pending.chatID == chatID,
              pending.route == route,
              Self.sameDurable(pending.storedID, storedID) else {
            pendingStopRequests[botID] = nil
            return
        }
        pending.sessionID = sessionID
        pending.generation = generation
        pendingStopRequests[botID] = pending
    }

    /// Move queued-prompt state across a runtime-sid rotation. A Hermes sid is
    /// ephemeral; the queued mirror belongs to the exact source route and
    /// durable session instead. Re-keying by bot id alone would let a reused
    /// profile inherit another conversation's FIFO and lifecycle counters.
    ///
    /// The returned ids are the visible `AppModel.promptQueue` rows whose
    /// binding moved. `ChatRuntime` cannot own that presentation array (it is
    /// stored on `AppModel`), so the caller updates only those exact rows.
    @discardableResult
    func migrateQueuedState(fromBotID: String, toBotID: String,
                            route: GatewayBotRoute,
                            oldSessionID: String, newSessionID: String,
                            storedID: String) -> Set<UUID> {
        guard !oldSessionID.isEmpty, !newSessionID.isEmpty,
              !storedID.isEmpty else { return [] }
        let source = QueuedPromptSession(botID: fromBotID, sessionID: oldSessionID,
                                         storedID: storedID, route: route)
        let destination = QueuedPromptSession(botID: toBotID, sessionID: newSessionID,
                                              storedID: storedID, route: route)

        let candidates = queuedBindings.filter { _, binding in
            binding.botID == fromBotID && binding.sessionID == oldSessionID
            && binding.storedID == storedID && binding.route == route
        }
        var movedIDs = Set<UUID>()
        for (id, binding) in candidates {
            var moved = binding
            moved.botID = toBotID
            moved.sessionID = newSessionID
            queuedBindings[id] = moved
            movedIDs.insert(id)
        }

        if let lifecycle = queuedLifecycles.removeValue(forKey: source) {
            var merged = queuedLifecycles[destination] ?? .init()
            // Starts/completions are event counts split by the old/new runtime
            // sid during a reconnect. Both portions are real and additive.
            merged.starts += lifecycle.starts
            merged.completions += lifecycle.completions
            queuedLifecycles[destination] = merged
        }

        if let pending = pendingQueuedSubmissions.removeValue(forKey: source) {
            var moved = pending.map { item -> PendingQueuedSubmission in
                var item = item
                item.session = destination
                return item
            }
            moved.sort { $0.order < $1.order }
            var merged = pendingQueuedSubmissions[destination] ?? []
            merged.append(contentsOf: moved)
            merged.sort { $0.order < $1.order }
            pendingQueuedSubmissions[destination] = merged
        }
        return movedIDs
    }

    /// Retire queued state for one exact source/durable binding. This is used
    /// when a profile/session is replaced or deleted; a route-wide scrub would
    /// erase a sibling profile's queued work, while a bot-id scrub can cross a
    /// reused primary profile.
    @discardableResult
    func retireQueuedState(botID: String, route: GatewayBotRoute,
                           storedID: String?) -> Set<UUID> {
        let matchingIDs = queuedBindings.compactMap { id, binding -> UUID? in
            guard binding.botID == botID, binding.route == route,
                  binding.storedID == storedID else { return nil }
            return id
        }
        for id in matchingIDs { queuedBindings[id] = nil }
        queuedLifecycles = queuedLifecycles.filter { key, _ in
            !(key.botID == botID && key.route == route && key.storedID == storedID)
        }
        pendingQueuedSubmissions = pendingQueuedSubmissions.filter { key, _ in
            !(key.botID == botID && key.route == route && key.storedID == storedID)
        }
        return Set(matchingIDs)
    }

    /// Retire all mutation/reconciliation state owned by one exact profile
    /// route. Profile lifecycle calls this before Hermes tears down the source
    /// directory; sibling profiles on the same gateway remain untouched.
    func retireProfileRouteState(route: GatewayBotRoute, botIDs: Set<String>) {
        transcriptActions = transcriptActions.filter { !botIDs.contains($0.key) }
        transcriptActionGenerations = transcriptActionGenerations.filter {
            !botIDs.contains($0.key)
        }
        transcriptFences = transcriptFences.filter { key, fence in
            !botIDs.contains(key)
                && (fence.gatewayID != route.gatewayID || fence.profile != route.profile)
        }
        assistantResponseAlternativeStages = assistantResponseAlternativeStages.filter {
            !botIDs.contains($0.key)
                && ($0.value.binding.gatewayID != route.gatewayID
                    || $0.value.binding.profile != route.profile)
        }
        steerActions = steerActions.filter {
            !botIDs.contains($0.key) && $0.value.route != route
        }
        steerFences = steerFences.filter {
            !botIDs.contains($0.key) && $0.value.route != route
        }
        stopActions = stopActions.filter {
            !botIDs.contains($0.key) && $0.value.route != route
        }
        stopFences = stopFences.filter { key, fence in
            !botIDs.contains(key) && (fence.unaddressable || fence.route != route)
        }
        let tasks = reconciliationTasks.filter { botIDs.contains($0.key) }
        for task in tasks.values { task.cancel() }
        for key in tasks.keys {
            reconciliationTasks.removeValue(forKey: key)
            reconciliationTokens.removeValue(forKey: key)
        }
        reconcilingBots.subtract(botIDs)
        deferredReconciliationBots.subtract(botIDs)
        // Pending stops are the one portable, pre-acceptance intent. The
        // profile lifecycle caller decides whether to park it for a rename or
        // retire it for delete, after this exact-route mutation scrub.
    }

    /// Direct gateway teardown has no captured profile target. Retire only
    /// source-qualified mutation state owned by the departing primary; routed
    /// secondary profiles on the same gateway remain live.
    func retirePrimaryMutationState(gatewayID: String, botIDs: Set<String>) {
        func ownsPrimary(_ key: String, route: GatewayBotRoute? = nil) -> Bool {
            botIDs.contains(key)
                || route.map { $0.gatewayID == gatewayID && botIDs.contains($0.profile) } == true
        }
        transcriptActions = transcriptActions.filter { !ownsPrimary($0.key) }
        transcriptActionGenerations = transcriptActionGenerations.filter { !ownsPrimary($0.key) }
        transcriptLeases = transcriptLeases.filter {
            !ownsPrimary($0.key, route: GatewayBotRoute(
                gatewayID: $0.value.gatewayID, profile: $0.value.profile))
        }
        transcriptFences = transcriptFences.filter {
            !ownsPrimary($0.key, route: GatewayBotRoute(
                gatewayID: $0.value.gatewayID, profile: $0.value.profile))
        }
        assistantResponseAlternativeStages = assistantResponseAlternativeStages.filter {
            !ownsPrimary($0.key, route: GatewayBotRoute(
                gatewayID: $0.value.binding.gatewayID,
                profile: $0.value.binding.profile))
        }
        steerActions = steerActions.filter { !ownsPrimary($0.key, route: $0.value.route) }
        steerFences = steerFences.filter { !ownsPrimary($0.key, route: $0.value.route) }
        stopActions = stopActions.filter { !ownsPrimary($0.key, route: $0.value.route) }
        stopFences = stopFences.filter { !ownsPrimary($0.key, route: $0.value.route) }
        offlineComposeFences = offlineComposeFences.filter {
            !ownsPrimary($0.value.botID, route: $0.value.route)
        }
        let tasks = reconciliationTasks.filter { botIDs.contains($0.key) }
        for task in tasks.values { task.cancel() }
        for key in tasks.keys {
            reconciliationTasks.removeValue(forKey: key)
            reconciliationTokens.removeValue(forKey: key)
        }
        reconcilingBots.subtract(botIDs)
        deferredReconciliationBots.subtract(botIDs)
    }

    /// Re-key only portable queue/interrupt state after an exact profile-route
    /// rename. Runtime transcript mutations are deliberately retired: Hermes
    /// replaces the old profile backend, so their old runtime sid is not a
    /// valid destination. The pending stop has no wire acceptance yet and is
    /// therefore safe to move with its durable/chat proof.
    func migrateProfileRouteState(from sourceRoute: GatewayBotRoute,
                                  to destinationRoute: GatewayBotRoute,
                                  sourceBotID: String, destinationBotID: String,
                                  storedID: String, chatID: ObjectIdentifier,
                                  sessionID: String? = nil) {
        guard !storedID.isEmpty, sourceRoute != destinationRoute else { return }

        _ = rekeyPendingStop(
            fromBotIDs: [sourceBotID], fromRoute: sourceRoute,
            toBotID: destinationBotID, toRoute: destinationRoute,
            chatID: chatID, storedID: storedID)

        let bindings = queuedBindings.filter { _, binding in
            binding.botID == sourceBotID && binding.route == sourceRoute
                && binding.storedID == storedID
                && (sessionID == nil || binding.sessionID == sessionID)
        }
        for (id, binding) in bindings {
            var moved = binding
            moved.botID = destinationBotID
            moved.route = destinationRoute
            queuedBindings[id] = moved
        }

        let lifecycleKeys = queuedLifecycles.keys.filter {
            $0.botID == sourceBotID && $0.route == sourceRoute && $0.storedID == storedID
                && (sessionID == nil || $0.sessionID == sessionID)
        }
        for key in lifecycleKeys {
            guard let lifecycle = queuedLifecycles.removeValue(forKey: key) else { continue }
            let destination = QueuedPromptSession(
                botID: destinationBotID, sessionID: key.sessionID,
                storedID: storedID, route: destinationRoute)
            var merged = queuedLifecycles[destination] ?? .init()
            merged.starts += lifecycle.starts
            merged.completions += lifecycle.completions
            queuedLifecycles[destination] = merged
        }

        let pendingKeys = pendingQueuedSubmissions.keys.filter {
            $0.botID == sourceBotID && $0.route == sourceRoute && $0.storedID == storedID
                && (sessionID == nil || $0.sessionID == sessionID)
        }
        for key in pendingKeys {
            guard let pending = pendingQueuedSubmissions.removeValue(forKey: key) else { continue }
            let destination = QueuedPromptSession(
                botID: destinationBotID, sessionID: key.sessionID,
                storedID: storedID, route: destinationRoute)
            let moved = pending.map { item -> PendingQueuedSubmission in
                var item = item
                item.session = destination
                return item
            }
            var merged = pendingQueuedSubmissions[destination] ?? []
            merged.append(contentsOf: moved)
            merged.sort { $0.order < $1.order }
            pendingQueuedSubmissions[destination] = merged
        }

        // Any reconciliation task/fence for this source was intentionally
        // retired above. The route-specific queue state is now waiting for the
        // destination's next authoritative bind to rotate its runtime sid.
    }

    func clearPendingStop(botID: String) {
        pendingStopRequests[botID] = nil
    }

    func clearPendingStopIfStored(_ storedID: String, botID: String) {
        guard pendingStopRequests[botID]?.storedID == storedID else { return }
        pendingStopRequests[botID] = nil
    }

    func clearPendingStops(forGatewayID gatewayID: String) {
        pendingStopRequests = pendingStopRequests.filter {
            $0.value.route.gatewayID != gatewayID
        }
    }

    /// Remove deferred interrupts for one source-qualified profile. A
    /// secondary profile can share a gateway with other profiles, so a
    /// gateway-wide scrub would incorrectly retire their user intent too.
    func clearPendingStops(forRoute route: GatewayBotRoute) {
        pendingStopRequests = pendingStopRequests.filter {
            $0.value.route != route
        }
    }

    /// Move a deferred stop with its ChatState when lifecycle parking changes
    /// a primary bot from its bare key to a source-qualified key (or back).
    /// The route, durable row, and exact reference identity must all agree;
    /// a destination collision cancels the old entry fail-closed.
    @discardableResult
    func movePendingStopBindingKey(fromBotID: String, toBotID: String,
                                   route: GatewayBotRoute,
                                   chatID: ObjectIdentifier,
                                   storedID: String?) -> Bool {
        guard fromBotID != toBotID else { return true }
        guard let pending = pendingStopRequests[fromBotID],
              pending.route == route,
              pending.chatID == chatID,
              Self.sameDurable(pending.storedID, storedID),
              pendingStopRequests[toBotID] == nil else {
            pendingStopRequests[fromBotID] = nil
            return false
        }
        var moved = pending
        moved.botID = toBotID
        pendingStopRequests[fromBotID] = nil
        pendingStopRequests[toBotID] = moved
        return true
    }

    /// Park an in-flight stop under the qualified primary key before a
    /// gateway retirement. The route, durable id, and exact ChatState are
    /// required; ambiguous/mismatched state remains quarantined.
    func rekeyStopMutation(fromBotID: String, toBotID: String,
                           route: GatewayBotRoute, chatID: ObjectIdentifier,
                           storedID: String?) -> Bool {
        guard fromBotID != toBotID else { return true }
        guard let durable = storedID, !durable.isEmpty else { return false }
        guard stopActions[toBotID] == nil, stopFences[toBotID] == nil else { return false }
        var moved = false
        if var action = stopActions[fromBotID], action.route == route,
           action.chatID == chatID, Self.sameDurable(action.storedID, durable) {
            action.botID = toBotID
            stopActions[toBotID] = action
            stopActions[fromBotID] = nil
            moved = true
        }
        if var fence = stopFences[fromBotID], !fence.unaddressable,
           fence.route == route, fence.chatID == chatID,
           Self.sameDurable(fence.storedID, durable) {
            fence.botID = toBotID
            stopFences[toBotID] = fence
            stopFences[fromBotID] = nil
            moved = true
        }
        return moved
    }

    /// Re-key a deferred interrupt across a confirmed source-profile rename.
    /// The runtime sid is deliberately dropped: Hermes retires the old
    /// profile backend during the rename, and only a later authoritative
    /// bind/adopt may supply the new sid. Preserve the intent only when one
    /// exact old entry proves the same durable row and ChatState owns it;
    /// otherwise cancel the old entry fail-closed instead of guessing which
    /// destination chat should receive the stop.
    @discardableResult
    func rekeyPendingStop(fromBotIDs: Set<String>, fromRoute: GatewayBotRoute,
                          toBotID: String, toRoute: GatewayBotRoute,
                          chatID: ObjectIdentifier, storedID: String?) -> Bool {
        let sourceKeys = pendingStopRequests
            .filter { key, pending in
                fromBotIDs.contains(key) && pending.route == fromRoute
            }
            .map(\.key)
        guard let durable = storedID, !durable.isEmpty,
              fromRoute.gatewayID == toRoute.gatewayID,
              fromRoute != toRoute else {
            for key in sourceKeys { pendingStopRequests[key] = nil }
            return false
        }

        let candidates = sourceKeys.filter { key in
            guard let pending = pendingStopRequests[key] else { return false }
            return pending.chatID == chatID && Self.sameDurable(pending.storedID, durable)
        }
        guard candidates.count == 1, let sourceKey = candidates.first,
              pendingStopRequests[toBotID] == nil,
              var pending = pendingStopRequests[sourceKey] else {
            // A duplicate, collision, or mismatched durable/chat identity is
            // not evidence that the old intent belongs to the new route.
            // Retire every old-route candidate; never leave an orphaned stop
            // that could later drain into a reused profile id.
            for key in sourceKeys { pendingStopRequests[key] = nil }
            return false
        }

        pending.botID = toBotID
        pending.route = toRoute
        pending.sessionID = nil
        pending.generation = LiveRuntime.shared.generation
        pendingStopRequests[sourceKey] = nil
        pendingStopRequests[toBotID] = pending
        return true
    }

    /// Keep an exact deferred stop when the sessions sheet reopens the same
    /// durable row. A route that is temporarily unavailable during reconnect
    /// is left for bind/adopt to prove; a known replacement route retires it.
    func pendingStopMatchesReopen(botID: String, storedID: String,
                                  chatID: ObjectIdentifier,
                                  route: GatewayBotRoute?) -> Bool {
        guard let pending = pendingStopRequests[botID],
              pending.chatID == chatID,
              Self.sameDurable(pending.storedID, storedID) else { return false }
        return route.map { pending.route == $0 } ?? true
    }

    static func sameDurable(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, !lhs.isEmpty, let rhs, !rhs.isEmpty else { return false }
        return lhs == rhs
    }

    /// tool.generating placeholders carry no tool_id — this prefix marks them
    /// so tool.start can promote rather than duplicate them.
    static let generatingPrefix = "generating:"
}

struct DismissedTurnFailure: Equatable {
    var route: GatewayBotRoute
    var storedID: String
    var message: String
}

struct FailedTurnRetryRequest: Equatable {
    var token: UUID
    var text: String
    var assistantID: UUID
    var route: GatewayBotRoute
    var storedID: String
    var chatID: ObjectIdentifier
    /// Explicitly empty: failed Retry is a fresh submit, never regenerate.
    var truncate = TranscriptActing.TruncateAddress()
}

struct FailedTurnRetryLease: Equatable {
    enum Phase: Equatable { case prepared, submitting, started }
    var token: UUID
    var assistantID: UUID
    var route: GatewayBotRoute
    var sessionID: String
    var storedID: String
    var chatID: ObjectIdentifier
    var phase: Phase
    var baselineText: String
    var baselineFailure: TurnFailure
    var promptText: String
    var baselineDurableUserRowIDWatermark: Int?
    var baselineUndurableMatchingUserCount: Int
    /// True only after an exact authoritative history read. `nil` watermark
    /// then means a proven empty durable baseline, rather than unknown.
    var authoritativeBaselineKnown = false
}

struct TranscriptActionFence: Equatable {
    var operationID: UUID
    var sessionID: String
    var storedID: String
    var gatewayID: String
    var profile: String
    var generation: Int
    /// A read settles the fence only after it proves the requested destructive
    /// effect. Keep the proof on the fence so a late result can reconcile it
    /// after a reconnect without reissuing the verb.
    var effectProof: TranscriptActionEffectProof? = nil
    /// Older callers may not have supplied this identity; production fences
    /// always do, so a reused ChatState cannot inherit an old destructive read.
    var chatID: ObjectIdentifier? = nil

    func acceptsAuthoritativeHydration(gatewayID: String, profile: String,
                                       storedID: String, generation: Int,
                                       currentGeneration: Int) -> Bool {
        self.gatewayID == gatewayID && self.profile == profile
            && self.storedID == storedID
            && generation == currentGeneration && generation >= self.generation
    }
}

struct TranscriptActionRowSignature: Equatable {
    var author: MessageAuthor
    var text: String
}

/// Evidence captured before an edit/rewind/regenerate submit. Repeated prompt
/// text is common, so text alone cannot establish that this operation landed.
/// A proving projection must preserve the pre-truncate prefix, remove the
/// exact target/tail durable rows, and expose the new body with a fresh row id
/// (or the exact live inflight marker).
struct TranscriptActionEffectProof: Equatable {
    var truncateRowID: Int
    var submittedText: String
    var baselineDurableRowIDs: Set<Int>
    var baselinePrefix: [TranscriptActionRowSignature]
    var baselineTailRowIDs: Set<Int>
    var baselineUserTexts: Set<String>

    static func capture(plan: TranscriptActing.Plan,
                        baseline: [ChatMessage]) -> Self? {
        guard let truncateRowID = plan.truncate.rowID,
              plan.dropsFromIndex >= 0,
              plan.dropsFromIndex < baseline.count else { return nil }
        let prefix = Array(baseline.prefix(plan.dropsFromIndex))
            .filter { $0.author == .user || $0.author == .bot }
            .map { TranscriptActionRowSignature(author: $0.author, text: $0.text) }
        let tail = Array(baseline.dropFirst(plan.dropsFromIndex))
        let tailIDs = Set(tail.compactMap(\.rowID))
        guard tailIDs.contains(truncateRowID) else { return nil }
        return Self(
            truncateRowID: truncateRowID,
            submittedText: plan.text,
            baselineDurableRowIDs: Set(baseline.compactMap(\.rowID)),
            baselinePrefix: prefix,
            baselineTailRowIDs: tailIDs,
            baselineUserTexts: Set(baseline.compactMap {
                $0.author == .user ? $0.text : nil
            }))
    }

    /// Proof from a complete authoritative transcript projection.
    func proves(_ messages: [ChatMessage]) -> Bool {
        let visible = messages.filter { $0.author == .user || $0.author == .bot }
        let durableIDs = Set(visible.compactMap(\.rowID))
        guard !durableIDs.contains(truncateRowID),
              baselineTailRowIDs.isDisjoint(with: durableIDs),
              visible.count >= baselinePrefix.count else { return false }
        let prefix = visible.prefix(baselinePrefix.count).map {
            TranscriptActionRowSignature(author: $0.author, text: $0.text)
        }
        guard prefix == baselinePrefix else { return false }
        return visible.dropFirst(baselinePrefix.count).contains { row in
            row.author == .user && row.text == submittedText
                && row.rowID.map { !baselineDurableRowIDs.contains($0) } == true
        }
    }

    /// A live inflight marker is operation-specific only after the exact
    /// truncate target/tail have disappeared from that same resume projection.
    @MainActor
    func proves(_ live: LiveSession) -> Bool {
        guard live.inflight?["user"]?.stringValue == submittedText else { return false }
        let messages = AppModel.chatMessages(fromTranscript: .array(live.messages))
        let visible = messages.filter { $0.author == .user || $0.author == .bot }
        let durableIDs = Set(visible.compactMap(\.rowID))
        guard !durableIDs.contains(truncateRowID),
              baselineTailRowIDs.isDisjoint(with: durableIDs),
              visible.count >= baselinePrefix.count else { return false }
        let prefix = visible.prefix(baselinePrefix.count).map {
            TranscriptActionRowSignature(author: $0.author, text: $0.text)
        }
        return prefix == baselinePrefix
    }
}

struct TranscriptActionLease {
    var id: UUID
    var botID: String
    var sessionID: String
    var storedID: String
    var gatewayID: String
    var profile: String
    var generation: Int
    var chatID: ObjectIdentifier
    var optimisticID: UUID
    var baseline: [ChatMessage]
    /// The no-replay fence is justified only after the destructive RPC has
    /// crossed its acceptance boundary. A route/client failure before this
    /// point is a definite non-attempt, even if its transport error is noisy.
    var submitStarted = false
    var effectProof: TranscriptActionEffectProof? = nil
}

struct AssistantResponseAlternativeStage: Equatable {
    var operationID: UUID
    var botID: String
    var chatID: ObjectIdentifier
    var binding: AssistantResponseAlternativesBinding
    var previousSourceUserID: UUID
    var invalidatedSourceUserIDs: Set<UUID>
    var previousAssistantRun: [ChatMessage]
    var committed = false
}

struct QueuedPromptBinding: Equatable {
    var botID: String
    var sessionID: String
    var storedID: String?
    var route: GatewayBotRoute?
    var eligibleAfterCurrentTurn: Bool
    var order: UInt64
}

struct QueuedPromptSession: Hashable {
    var botID: String
    var sessionID: String
    var storedID: String?
    var route: GatewayBotRoute?
}

struct QueuedPromptLifecycle: Equatable {
    var starts = 0
    var completions = 0
}

struct PendingQueuedSubmission: Equatable {
    var id: UUID
    var session: QueuedPromptSession
    var lifecycle: QueuedPromptLifecycle
    var order: UInt64
    var startedBeforeAcknowledgement = false
}

struct OfflineComposeFence: Equatable {
    var itemID: UUID
    var botID: String
    var text: String
    var route: GatewayBotRoute
    var sessionID: String
    var storedID: String
    var chatID: ObjectIdentifier
    /// Durable user rows carrying the same body before this submit began.
    /// Reconciliation requires a new row id; text alone is never delivery
    /// proof for a retry or repeated slash-generated prompt.
    var baselineDurableUserRowIDs: Set<Int> = []
    /// Strict monotonic proof boundary. A different older row id is still old.
    var baselineDurableUserRowIDWatermark: Int? = nil
    var baselineUndurableMatchingUserCount: Int = 0
    /// Allows a nil watermark only when an exact authoritative read proved
    /// that no durable user row existed before submission.
    var baselineAuthorityKnown = false
}

struct StopTurnLease {
    var botID: String
    var route: GatewayBotRoute
    var sessionID: String
    var storedID: String?
    var chatID: ObjectIdentifier
    /// Identity for the exact interrupt attempt. Defaults preserve the small
    /// memberwise initializer used by older tests/callers.
    var id: UUID = UUID()
    var requestStarted = false
    var generation: Int = -1
}

enum SteerMutationStage: String, Equatable {
    case steer
    case redirect
    case queuedSubmit
}

enum SteerReceiptDisposition: Equatable {
    case acceptedCurrentTurn
    case mirrorNextTurn
    case advanceCascade

    static func resolve(stage: SteerMutationStage, status: String) -> Self? {
        switch (stage, status) {
        case (.steer, "queued"), (.redirect, "redirected"):
            return .acceptedCurrentTurn
        case (.redirect, "queued"), (.queuedSubmit, "queued"):
            return .mirrorNextTurn
        case (.steer, "rejected"), (.redirect, "rejected"):
            return .advanceCascade
        default:
            return nil
        }
    }
}

struct SteerMutationLease: Equatable {
    var id: UUID
    var botID: String
    var route: GatewayBotRoute
    var sessionID: String
    var storedID: String?
    var chatID: ObjectIdentifier
    var optimisticID: UUID
    var text: String
    var stage: SteerMutationStage = .steer
    var requestStarted = false
    var generation: Int = -1
    /// Durable rows that existed before this operation's optimistic bubble.
    /// Text is not identity: a repeated prompt must not satisfy reconciliation
    /// merely because an older row has the same body.
    var baselineDurableRowIDs: Set<Int> = []
    var baselineDurableRowCount: Int = 0
    /// User bodies that existed at the operation boundary (including an
    /// optimistic row that has not acquired a durable id). An in-flight
    /// snapshot is operation-specific only when it does not merely repeat
    /// one of these prior turns.
    var baselineDurableUserTexts: Set<String> = []
    /// Exact pre-optimistic projection. Lifecycle abort uses the row-id
    /// snapshot rather than text matching, so a repeated prompt or a live
    /// delta cannot be mistaken for this steer's bubble.
    var baselineMessages: [ChatMessage] = []
    var baselineIsRunning: Bool = false
    var baselineIsTyping: Bool = false
}

/// The request is held after an ambiguous response. The optimistic row is
/// intentionally identified separately: it is not evidence that the gateway
/// accepted the mutation.
struct SteerMutationFence: Equatable {
    var operationID: UUID
    var botID: String
    var route: GatewayBotRoute
    var sessionID: String
    var storedID: String?
    var chatID: ObjectIdentifier
    var optimisticID: UUID
    var text: String
    var stage: SteerMutationStage
    var generation: Int = -1
    /// Snapshot of durable transcript identity/count before the mutation.
    /// Reconciliation may clear this fence only with a post-operation row (or
    /// an exact in-flight marker), never a historical duplicate.
    var baselineDurableRowIDs: Set<Int> = []
    var baselineDurableRowCount: Int = 0
    /// See `SteerMutationLease.baselineDurableUserTexts`.
    var baselineDurableUserTexts: Set<String> = []
    /// Exact pre-optimistic projection. Lifecycle abort uses the row-id
    /// snapshot rather than text matching, so a repeated prompt or a live
    /// delta cannot be mistaken for this steer's bubble.
    var baselineMessages: [ChatMessage] = []
}

struct StopTurnFence: Equatable {
    var operationID: UUID
    var botID: String
    var route: GatewayBotRoute
    var sessionID: String
    var storedID: String?
    var chatID: ObjectIdentifier
    var generation: Int = -1
    /// No wire request could be addressed at the time of the stop tap. This
    /// local fence blocks new sends until `adopt` receives an authoritative
    /// live session for the same durable chat.
    var unaddressable: Bool = false
}

/// A stop tap waiting behind another mutation. Every field participates in
/// ownership: a later ChatState or durable session using the same bot id must
/// not inherit the earlier user's interrupt intent.
struct PendingStopRequest: Equatable {
    var botID: String
    var route: GatewayBotRoute
    var storedID: String?
    var sessionID: String?
    var chatID: ObjectIdentifier
    var generation: Int
}

enum PromptSubmitReceipt {
    static func requireAccepted(_ value: JSONValue, operation: String) throws {
        if value["ok"]?.boolValue == false
            || ["error", "rejected", "refused"].contains(value["status"]?.stringValue ?? "") {
            throw GatewayError(code: 409, message: "Hermes refused \(operation.lowercased()).")
        }
        guard let status = value["status"]?.stringValue,
              ["streaming", "queued"].contains(status) else {
            throw AckValidationError(operation: operation,
                                     detail: "Hermes did not return an accepted prompt status.")
        }
    }

    static func isAuthoritativelyQueued(_ value: JSONValue) -> Bool {
        value["status"]?.stringValue == "queued" && value["ok"]?.boolValue != false
    }

    /// A queued fallback is only mirrorable when Hermes explicitly says
    /// `queued`. A refusal is definitive; every other shape (including a
    /// streaming answer from a queued request) is an uncertain acceptance
    /// boundary and must not be followed by another mutation.
    static func requireQueued(_ value: JSONValue, operation: String) throws {
        if value["ok"]?.boolValue == false
            || ["error", "rejected", "refused"].contains(value["status"]?.stringValue ?? "") {
            throw GatewayError(code: 409, message: "Hermes refused \(operation.lowercased()).")
        }
        guard value["status"]?.stringValue == "queued" else {
            throw AckValidationError(operation: operation,
                                     detail: "Hermes did not return an authoritative queued status.")
        }
    }
}

enum PromptMutationFailure {
    static func isAmbiguous(_ error: Error) -> Bool {
        if error is AckValidationError || error is DecodingError { return true }
        if error is CancellationError { return true }
        if let gateway = error as? GatewayError { return [-5, -6, -7].contains(gateway.code) }
        if let url = error as? URLError {
            return url.code == .timedOut || url.code == .networkConnectionLost
        }
        return false
    }
}

enum SteerMutationReconciliation {
    /// A resume projection is authoritative evidence only when it names the
    /// exact correction. `running == true` alone is insufficient: the turn
    /// could have been running before the correction arrived.
    @MainActor
    static func hasRemoteEvidence(
        _ live: LiveSession, text: String,
        baselineDurableRowIDs: Set<Int>, baselineDurableRowCount: Int,
        baselineDurableUserTexts: Set<String> = []
    ) -> Bool {
        // `inflight.user` is a body, not an operation id. It is useful only
        // when the same durable body was not already present at the boundary;
        // otherwise a lost response could settle against an older turn.
        if live.inflight?["user"]?.stringValue == text,
           !baselineDurableUserTexts.contains(text) { return true }
        return hasPostOperationDurableRow(
            AppModel.chatMessages(fromTranscript: .array(live.messages)), text: text,
            baselineDurableRowIDs: baselineDurableRowIDs,
            baselineDurableRowCount: baselineDurableRowCount)
    }

    /// A durable row proves acceptance only when it was not present in the
    /// pre-operation snapshot and the authoritative page did not shrink the
    /// durable row set. The count guard rejects empty/stale pages while the
    /// identity guard rejects an older persisted row with the same text.
    static func hasPostOperationDurableRow(
        _ messages: [ChatMessage], text: String,
        baselineDurableRowIDs: Set<Int>, baselineDurableRowCount: Int
    ) -> Bool {
        let durableRowIDs = Set(messages.compactMap(\.rowID))
        // A page with the same count can still be a stale/replaced page. The
        // complete pre-operation identity set must survive the authoritative
        // read before any new row can prove this operation landed.
        guard baselineDurableRowIDs.isSubset(of: durableRowIDs),
              durableRowIDs.count >= baselineDurableRowCount else { return false }
        return messages.contains { message in
            message.author == .user && message.text == text
                && message.rowID.map { !baselineDurableRowIDs.contains($0) } == true
        }
    }
}

enum TranscriptActionReconciliation {
    static func newerRows(current: [ChatMessage], baseline: [ChatMessage],
                          optimisticID: UUID) -> [ChatMessage] {
        let baselineByID = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id, $0) })
        return current.filter { row in
            guard row.id != optimisticID else { return false }
            return baselineByID[row.id].map { $0 != row } ?? true
        }
    }
}

extension AppModel {

    /// `AppModel.send` already owns the optimistic user echo. Await a birth or
    /// explicit attach that has published a runtime sid before handing the
    /// prompt to the ordinary submit path; otherwise a kickoff can overtake
    /// this visible first row on the wire.
    func liveSendSerialized(text: String, botID: String, chat: ChatState,
                            optimisticID: UUID? = nil) {
        let capturedChatID = ObjectIdentifier(chat)
        let capturedRoute = stateRoute(for: botID) ?? gatewayRoute(for: botID)
        let capturedStoredID = chat.storedSessionID
        let capturedGeneration = LiveRuntime.shared.generation
        let capturedLifecycle = profileLifecycleGenerationToken(for: botID)
        Task { @MainActor in
            if let pending = LiveRuntime.shared.attachTasks[botID] {
                _ = try? await pending.value
            }
            guard mode == .live,
                  let route = capturedRoute,
                  let current = chats[botID], ObjectIdentifier(current) == capturedChatID,
                  (capturedStoredID == nil || current.storedSessionID == capturedStoredID),
                  LiveRuntime.shared.generation >= capturedGeneration,
                  capturedLifecycle.map(profileLifecycleAccepts) ?? false,
                  bindingRouteMatches(route, botID: botID),
                  !mutationIsFenced(botID: botID) else {
                // The row belongs to the captured operation even when its
                // route was replaced while attach was suspended. Keep it for
                // the replacement/reconnect path; deleting here loses user
                // input that was never proven to reach Hermes.
                scheduleRetainedMutationReconciliation(botID: botID)
                return
            }
            if let optimisticID {
                liveSend(text: text, botID: botID, chat: chat,
                         optimisticID: optimisticID)
            } else {
                liveSend(text: text, botID: botID, chat: chat)
            }
        }
    }

    /// Send a row created by an attach-serialized path. The base live sender
    /// predates mutation fences and has no row identity; this narrow overload
    /// lets the waiting path withdraw its own bubble if a fence appears in the
    /// handoff window.
    func liveSend(text: String, botID: String, chat: ChatState,
                  optimisticID: UUID) {
        guard !mutationIsFenced(botID: botID) else {
            scheduleRetainedMutationReconciliation(botID: botID)
            return
        }
        Task { @MainActor [weak self] in
            _ = await self?.liveSendAwaiting(text: text, botID: botID, chat: chat,
                                             optimisticID: optimisticID)
        }
    }

    /// Remove only a row this task created, and only while the same ChatState
    /// still owns the bot. A fence can appear while an attach is suspended;
    /// leaving that row visible would falsely claim the gateway received it.
    func removeOptimisticMessage(_ id: UUID?, from chat: ChatState,
                                 botID: String) {
        guard let id, chats[botID].map({ ObjectIdentifier($0) == ObjectIdentifier(chat) }) == true
        else { return }
        chat.messages.removeAll { $0.id == id }
    }

    // MARK: - Router attachment

    /// Register chat-core's event handler on the current client. Safe to call
    /// repeatedly; a no-op in demo mode and when already attached to this
    /// client. Call it after every `connectGateway` — a reconnect keeps the
    /// same client (and therefore this handler), but a new gateway link builds
    /// a fresh client that has no handlers yet.
    public func attachChatEventRouter() {
        let runtime = ChatRuntime.shared
        guard mode == .live, let client else { return }
        guard runtime.routedClient !== client else { return }

        let previous = runtime.routerHandler
        let previousClient = runtime.routedClient
        runtime.routedClient = client
        runtime.pump?.cancel()

        let (stream, continuation) = AsyncStream.makeStream(of: GatewayEvent.self)
        runtime.pump = Task { @MainActor [weak self] in
            for await event in stream {
                self?.routeToolEvent(event)
            }
        }
        Task {
            if let previous, let previousClient {
                await previousClient.removeEventHandler(previous)
            }
            let id = await client.addEventHandler { continuation.yield($0) }
            await MainActor.run { ChatRuntime.shared.routerHandler = id }
        }
    }

    // MARK: - Event routing (turn state + tool chips)

    /// Route one gateway event into chat-core state. Public so the router (and
    /// anything replaying events) can hand events in from outside this file.
    public func routeToolEvent(_ event: GatewayEvent, sourceGatewayID: String? = nil) {
        let typed = TypedGatewayEvent(event)
        if case .messageStart = typed {
            noteDurableComposerQueueStart(
                runtimeSessionID: event.sessionID,
                sourceGatewayID: sourceGatewayID ?? LiveRuntime.shared.gatewayID)
        }
        guard mode == .live,
              let botID = botID(forSession: event.sessionID,
                                sourceGatewayID: sourceGatewayID),
              currentChatOwnsMessageEvent(
                botID: botID, sessionID: event.sessionID,
                sourceGatewayID: sourceGatewayID ?? LiveRuntime.shared.gatewayID)
        else { return }
        let chat = chat(for: botID)
        ChatRuntime.shared.pruneTranscriptState(
            botID: botID, generation: LiveRuntime.shared.generation)

        switch typed {
        case .messageStart:
            noteQueuedPromptStart(botID: botID, sessionID: event.sessionID)
            drainStartedQueuedPrompt(botID: botID, sessionID: event.sessionID)
            clearWatchdog(botID)
            chat.beginTurnTiming(
                at: Date(), replacingExisting: !(chat.isRunning || chat.isTyping))
            chat.isRunning = true
            ChatRuntime.shared.turnFloor[botID] = chat.messages.indices.last(where: {
                chat.messages[$0].author == .bot && chat.messages[$0].isStreaming
            }) ?? chat.messages.count

        case .messageComplete(let payload):
            noteQueuedPromptCompletion(botID: botID, sessionID: event.sessionID)
            markQueuedPromptsEligible(botID: botID, sessionID: event.sessionID)
            clearWatchdog(botID)
            chat.isRunning = false
            finishRunningTools(in: chat, interrupted: payload.status != .complete)
            LiveActivityController.shared.endAllOperationalWork(botID: botID)
            requestComposeQueueFlush()

        case .errorEvent:
            noteQueuedPromptCompletion(botID: botID, sessionID: event.sessionID)
            markQueuedPromptsEligible(botID: botID, sessionID: event.sessionID)
            clearWatchdog(botID)
            chat.isRunning = false
            finishRunningTools(in: chat, interrupted: true)
            LiveActivityController.shared.endAllOperationalWork(botID: botID)
            requestComposeQueueFlush()

        case .sessionInfo(let info):
            // Authoritative after a resume: the turn may have kept running
            // while the socket was down. A session.info that lands between the
            // submit and message.start must not pull the stop control out from
            // under a turn that is visibly streaming.
            if info.running {
                observeTurnTiming(from: info, in: chat)
                chat.isRunning = true
            } else if chat.messages.last?.isStreaming != true {
                observeTurnTiming(from: info, in: chat)
                chat.isRunning = false
            }

        case .toolGenerating(let name):
            guard !name.isEmpty else { return }
            let index = toolAnchor(in: chat, botID: botID)
            guard !chat.messages[index].toolCalls.contains(where: {
                $0.name == name && $0.state == .running
            }) else { return }
            chat.messages[index].toolCalls.append(
                ToolCall(id: ChatRuntime.generatingPrefix + name + "-\(UUID().uuidString.prefix(6))",
                         name: name, context: ""))

        case .toolStart(let tool):
            guard !tool.name.isEmpty || !tool.toolID.isEmpty else { return }
            startTool(tool, in: chat, botID: botID)
            LiveActivityController.shared.beginOperationalWork(
                botID: botID,
                operationID: tool.toolID.isEmpty ? "tool:\(tool.name)" : tool.toolID)

        case .toolComplete(let tool):
            completeTool(tool, payload: event.payload, in: chat, botID: botID)
            LiveActivityController.shared.endOperationalWork(
                botID: botID,
                operationID: tool.toolID.isEmpty ? "tool:\(tool.name)" : tool.toolID)

        default:
            break
        }
    }

    /// The message a tool chip belongs under: the assistant bubble of the
    /// running turn, or a fresh one when tools fire before the first token.
    private func toolAnchor(in chat: ChatState, botID: String) -> Int {
        let floor = ChatRuntime.shared.turnFloor[botID] ?? chat.messages.count
        if let last = chat.messages.indices.last, chat.messages[last].author == .bot,
           chat.messages[last].isStreaming || last >= floor {
            return last
        }
        chat.messages.append(ChatMessage(author: .bot, time: AppModel.clock(),
                                         text: "", isStreaming: true))
        return chat.messages.count - 1
    }

    private func startTool(_ tool: ToolStartPayload, in chat: ChatState, botID: String) {
        let index = toolAnchor(in: chat, botID: botID)
        let id = tool.toolID.isEmpty ? UUID().uuidString : tool.toolID
        var calls = chat.messages[index].toolCalls
        var admitsStartMetadata = false

        if let existing = calls.firstIndex(where: {
            $0.id == id || (!tool.toolID.isEmpty && $0.gatewayToolID == tool.toolID)
        }) {
            let completionBeforeStart = calls[existing].provenance == .unmatchedResult
                && calls[existing].state != .running
                && (calls[existing].deferredFileDiff != nil
                    || calls[existing].fileDiff != nil
                    || calls[existing].structuredOutput != nil
                    || calls[existing].deferredStructuredOutput != nil
                    || calls[existing].webSearchOutput != nil
                    || calls[existing].deferredWebSearchOutput != nil
                    || calls[existing].deferredWebSearchHasExplicitError
                    || calls[existing].generatedImage != nil
                    || calls[existing].deferredGeneratedImage != nil
                    || calls[existing].result != nil)
            if completionBeforeStart {
                admitsStartMetadata = true
                // Exact completion-before-start ownership beats its one
                // presentation placeholder. A settled ordinary A must never
                // consume a same-name generating placeholder belonging to B.
                if let pending = calls.firstIndex(where: {
                    $0.id.hasPrefix(ChatRuntime.generatingPrefix)
                        && $0.name == tool.name && $0.state == .running
                }), pending != existing {
                    if calls[existing].context.isEmpty {
                        calls[existing].context = calls[pending].context
                    }
                    calls[existing].arguments = calls[existing].arguments
                        ?? calls[pending].arguments
                    calls.remove(at: pending)
                }
            } else if calls[existing].state == .running {
                admitsStartMetadata = true
            }
            // Reacquire after possible placeholder removal; indices may shift.
            if admitsStartMetadata, let exact = calls.firstIndex(where: {
                $0.id == id || (!tool.toolID.isEmpty && $0.gatewayToolID == tool.toolID)
            }) {
                if !tool.name.isEmpty { calls[exact].name = tool.name }
                if !tool.context.isEmpty || calls[exact].context.isEmpty {
                    calls[exact].context = tool.context
                }
                calls[exact].gatewayToolID = tool.toolID.isEmpty ? nil : tool.toolID
                calls[exact].arguments = tool.arguments ?? calls[exact].arguments
                calls[exact].webSearchQuery = tool.webSearchQuery
                    ?? calls[exact].webSearchQuery
                calls[exact].provenance = .live
            }
        } else if let pending = calls.firstIndex(where: {
            $0.id.hasPrefix(ChatRuntime.generatingPrefix) && $0.name == tool.name && $0.state == .running
        }) {
            admitsStartMetadata = true
            // Promote the tool.generating placeholder rather than add a twin.
            calls[pending].id = id
            calls[pending].gatewayToolID = tool.toolID.isEmpty ? nil : tool.toolID
            if !tool.name.isEmpty { calls[pending].name = tool.name }
            calls[pending].context = tool.context
            calls[pending].arguments = tool.arguments
            calls[pending].webSearchQuery = tool.webSearchQuery
        } else {
            admitsStartMetadata = true
            calls.append(ToolCall(
                id: id, name: tool.name, context: tool.context,
                gatewayToolID: tool.toolID.isEmpty ? nil : tool.toolID,
                arguments: tool.arguments,
                webSearchQuery: tool.webSearchQuery))
        }
        // A completion can arrive before its start frame. Enrich only the
        // exact invocation's missing path; never replace its retained diff.
        if admitsStartMetadata, let exact = calls.firstIndex(where: {
            $0.id == id || (!tool.toolID.isEmpty && $0.gatewayToolID == tool.toolID)
        }) {
            let establishedName = tool.name.isEmpty ? calls[exact].name : tool.name
            if ToolDiffCodec.isFileEditTool(establishedName) {
                if calls[exact].fileDiff == nil {
                    calls[exact].fileDiff = calls[exact].deferredFileDiff
                }
                calls[exact].deferredFileDiff = nil
                if calls[exact].fileDiff?.path == nil,
                   let path = ToolDiffCodec.path(
                    from: tool.arguments ?? calls[exact].arguments) {
                    calls[exact].fileDiff?.path = path
                }
            } else if !establishedName.isEmpty, establishedName != "Tool" {
                calls[exact].deferredFileDiff = nil
            }
            if ToolOutputCodec.isStructuredTool(establishedName) {
                calls[exact].structuredOutput = ToolStructuredOutput.merging(
                    newer: calls[exact].deferredStructuredOutput,
                    preserving: calls[exact].structuredOutput)
                calls[exact].deferredStructuredOutput = nil
            } else if !establishedName.isEmpty, establishedName != "Tool" {
                calls[exact].deferredStructuredOutput = nil
            }
            if ToolWebSearchCodec.isWebSearchTool(establishedName) {
                calls[exact].webSearchOutput = ToolWebSearchOutput.merging(
                    newer: calls[exact].deferredWebSearchOutput,
                    preserving: calls[exact].webSearchOutput)
                calls[exact].deferredWebSearchOutput = nil
                if calls[exact].deferredWebSearchHasExplicitError {
                    calls[exact].state = .failed
                }
                calls[exact].deferredWebSearchHasExplicitError = false
                if calls[exact].webSearchOutput?.query == nil {
                    let query = calls[exact].webSearchQuery
                        ?? ToolWebSearchCodec.query(from: calls[exact].arguments)
                    calls[exact].webSearchOutput?.query = query
                }
            } else if !establishedName.isEmpty, establishedName != "Tool" {
                calls[exact].deferredWebSearchOutput = nil
                calls[exact].deferredWebSearchHasExplicitError = false
            }
            if ToolGeneratedImageCodec.isGeneratedImageTool(establishedName) {
                calls[exact].generatedImage = ToolGeneratedImage.merging(
                    newer: calls[exact].deferredGeneratedImage,
                    preserving: calls[exact].generatedImage)
                calls[exact].generatedImage = ToolGeneratedImageCodec.applyingAspectHint(
                    calls[exact].generatedImage, arguments: calls[exact].arguments)
                calls[exact].deferredGeneratedImage = nil
            } else if !establishedName.isEmpty, establishedName != "Tool" {
                calls[exact].generatedImage = nil
                calls[exact].deferredGeneratedImage = nil
            }
        }
        chat.messages[index].toolCalls = calls
    }

    private func completeTool(_ tool: ToolCompletePayload, payload: JSONValue?,
                              in chat: ChatState, botID: String) {
        // Newest first, and only within reach of the running turn: a stale
        // chip further up the transcript must not be retro-completed by a
        // same-named tool running now.
        for index in chat.messages.indices.suffix(12).reversed() {
            guard !chat.messages[index].toolCalls.isEmpty else { continue }
            var calls = chat.messages[index].toolCalls
            let hit = calls.firstIndex {
                !tool.toolID.isEmpty && ($0.gatewayToolID == tool.toolID || $0.id == tool.toolID)
            }
            guard let hit else { continue }

            if (calls[hit].name.isEmpty || calls[hit].name == "Tool"),
               !tool.name.isEmpty {
                calls[hit].name = tool.name
            }
            let establishedName = (calls[hit].name.isEmpty || calls[hit].name == "Tool")
                ? tool.name : calls[hit].name
            let rawResult = payload?["result"] ?? payload?["result_text"]
            let outputAdmission = ToolOutputCodec.admit(
                toolName: establishedName, result: rawResult)
            let searchAdmission = ToolWebSearchCodec.admit(
                toolName: establishedName,
                arguments: payload?["args"] ?? payload?["arguments"] ?? payload?["input"],
                result: rawResult)
            let generatedAdmission = ToolGeneratedImageCodec.admit(
                toolName: establishedName,
                arguments: tool.arguments ?? calls[hit].arguments,
                result: rawResult)
            let completionOutput = outputAdmission.output ?? tool.structuredOutput
            let completionResult = completionOutput == nil
                ? tool.result : (outputAdmission.genericResult ?? tool.result)
            let completionFailed = Self.toolFailed(
                payload: payload, summary: tool.summary, resultText: tool.resultText)
                || searchAdmission.hasExplicitError
            let preservesFailedEvidence = calls[hit].state == .failed && !completionFailed
            calls[hit].state = completionFailed ? .failed
                : (preservesFailedEvidence ? .failed : .done)
            if !preservesFailedEvidence, let summary = tool.summary {
                calls[hit].summary = summary
            }
            // result_text only rides along in verbose mode; `result` is always
            // there, so fall back to a readable rendering of it.
            if !preservesFailedEvidence, let result = completionResult {
                calls[hit].result = result
                calls[hit].resultText = result.displayText
                    ?? Self.describeResult(payload?["result"])
            }
            calls[hit].durationSeconds = tool.durationSeconds ?? calls[hit].durationSeconds
            calls[hit].arguments = calls[hit].arguments ?? tool.arguments
            calls[hit].structuredOutput = preservesFailedEvidence
                ? ToolStructuredOutput.merging(
                    newer: calls[hit].structuredOutput, preserving: completionOutput)
                : ToolStructuredOutput.merging(
                    newer: completionOutput, preserving: calls[hit].structuredOutput)
            let completionSearch = searchAdmission.output ?? tool.webSearchOutput
            calls[hit].webSearchOutput = preservesFailedEvidence
                ? ToolWebSearchOutput.merging(
                    newer: calls[hit].webSearchOutput, preserving: completionSearch)
                : ToolWebSearchOutput.merging(
                    newer: completionSearch, preserving: calls[hit].webSearchOutput)
            let deferredSearch = tool.deferredWebSearchOutput
            if ToolWebSearchCodec.isWebSearchTool(establishedName) {
                calls[hit].webSearchOutput = preservesFailedEvidence
                    ? ToolWebSearchOutput.merging(
                        newer: calls[hit].webSearchOutput, preserving: deferredSearch)
                    : ToolWebSearchOutput.merging(
                        newer: deferredSearch, preserving: calls[hit].webSearchOutput)
                calls[hit].deferredWebSearchOutput = nil
                if tool.deferredWebSearchHasExplicitError {
                    calls[hit].state = .failed
                }
                calls[hit].deferredWebSearchHasExplicitError = false
                if calls[hit].webSearchOutput?.query == nil {
                    let query = calls[hit].webSearchQuery
                        ?? ToolWebSearchCodec.query(from: tool.arguments ?? calls[hit].arguments)
                    calls[hit].webSearchOutput?.query = query
                }
            } else if establishedName.isEmpty || establishedName == "Tool" {
                calls[hit].deferredWebSearchOutput = ToolWebSearchOutput.merging(
                    newer: deferredSearch, preserving: calls[hit].deferredWebSearchOutput)
                calls[hit].deferredWebSearchHasExplicitError =
                    calls[hit].deferredWebSearchHasExplicitError
                    || tool.deferredWebSearchHasExplicitError
            } else {
                calls[hit].deferredWebSearchOutput = nil
                calls[hit].deferredWebSearchHasExplicitError = false
            }
            let deferredOutput = tool.deferredStructuredOutput
            if ToolOutputCodec.isStructuredTool(establishedName) {
                calls[hit].structuredOutput = preservesFailedEvidence
                    ? ToolStructuredOutput.merging(
                        newer: calls[hit].structuredOutput, preserving: deferredOutput)
                    : ToolStructuredOutput.merging(
                        newer: deferredOutput, preserving: calls[hit].structuredOutput)
                calls[hit].deferredStructuredOutput = nil
            } else if establishedName.isEmpty || establishedName == "Tool" {
                calls[hit].deferredStructuredOutput = ToolStructuredOutput.merging(
                    newer: deferredOutput, preserving: calls[hit].deferredStructuredOutput)
            } else {
                calls[hit].deferredStructuredOutput = nil
            }
            let completionGenerated = generatedAdmission ?? tool.generatedImage
            if ToolGeneratedImageCodec.isGeneratedImageTool(establishedName) {
                let evidence = completionGenerated ?? tool.deferredGeneratedImage
                calls[hit].generatedImage = preservesFailedEvidence
                    ? ToolGeneratedImage.merging(
                        newer: calls[hit].generatedImage, preserving: evidence)
                    : ToolGeneratedImage.merging(
                        newer: evidence, preserving: calls[hit].generatedImage)
                calls[hit].deferredGeneratedImage = nil
            } else if establishedName.isEmpty || establishedName == "Tool" {
                calls[hit].deferredGeneratedImage = ToolGeneratedImage.merging(
                    newer: tool.deferredGeneratedImage,
                    preserving: calls[hit].deferredGeneratedImage)
            } else {
                calls[hit].generatedImage = nil
                calls[hit].deferredGeneratedImage = nil
            }
            if !preservesFailedEvidence {
                let establishedName = ToolDiffCodec.isFileEditTool(calls[hit].name)
                    ? calls[hit].name : tool.name
                if ToolDiffCodec.isFileEditTool(establishedName),
                   var diff = tool.fileDiff ?? tool.deferredFileDiff {
                    if diff.path == nil {
                        diff.path = ToolDiffCodec.path(from: calls[hit].arguments)
                    }
                    calls[hit].fileDiff = diff
                    calls[hit].deferredFileDiff = nil
                } else if let candidate = tool.fileDiff ?? tool.deferredFileDiff {
                    calls[hit].deferredFileDiff = candidate
                }
            }
            if !preservesFailedEvidence, calls[hit].context.isEmpty,
               let summary = tool.summary {
                calls[hit].context = summary
            }
            chat.messages[index].toolCalls = calls
            return
        }
        let result = tool.result ?? ToolPayloadCodec.unavailable(
            "Hermes completed this tool without retaining inspectable output.")
        let index = toolAnchor(in: chat, botID: botID)
        chat.messages[index].toolCalls.append(ToolCall(
            id: "live-result:\(UUID().uuidString)",
            name: tool.name.isEmpty ? "Tool" : tool.name,
            context: "",
            state: Self.toolFailed(payload: payload, summary: tool.summary,
                                   resultText: tool.resultText)
                || tool.webSearchHasExplicitError ? .failed : .done,
            summary: tool.summary, resultText: result.displayText,
            durationSeconds: tool.durationSeconds,
            gatewayToolID: tool.toolID.isEmpty ? nil : tool.toolID,
            arguments: tool.arguments, result: result,
            fileDiff: tool.fileDiff,
            structuredOutput: tool.structuredOutput,
            deferredStructuredOutput: tool.deferredStructuredOutput,
            deferredFileDiff: tool.fileDiff == nil ? tool.deferredFileDiff : nil,
            webSearchOutput: tool.webSearchOutput,
            deferredWebSearchOutput: tool.webSearchOutput == nil
                ? tool.deferredWebSearchOutput : nil,
            deferredWebSearchHasExplicitError: tool.webSearchOutput == nil
                && tool.deferredWebSearchHasExplicitError,
            webSearchQuery: tool.webSearchOutput?.query,
            // An unmatched completion remains inert until an exact-id start
            // proves the invocation, regardless of a repeated result name.
            generatedImage: nil,
            deferredGeneratedImage: tool.generatedImage
                ?? tool.deferredGeneratedImage,
            provenance: .unmatchedResult,
            diagnostic: "No exact live tool-call id matched this completion; Talaria did not pair it by name."))
    }

    /// A finished turn can hold no running tools — a stop or an error leaves
    /// chips spinning forever otherwise.
    /// Settle every tool chip still spinning in the recent tail. Internal
    /// rather than private because the liveness reaper owes the same debt when
    /// a turn ends off-socket (AppModelLive+Liveness.swift): one rule for what
    /// a chip left running means, in one place.
    func finishRunningTools(in chat: ChatState, interrupted: Bool) {
        for index in chat.messages.indices.suffix(12) {
            guard !chat.messages[index].toolCalls.isEmpty else { continue }
            for call in chat.messages[index].toolCalls.indices
            where chat.messages[index].toolCalls[call].state == .running {
                chat.messages[index].toolCalls[call].state = interrupted ? .failed : .done
            }
        }
    }

    /// Only protocol-level evidence marks a tool failed. Human prose is not a
    /// status bit (a successful grep result can legitimately begin "error").
    static func toolFailed(payload: JSONValue?, summary: String?, resultText: String?) -> Bool {
        if payload?["is_error"]?.boolValue == true
            || ToolPayloadCodec.valueIsExplicitError(payload?["error"]) { return true }
        return ToolPayloadCodec.resultHasExplicitError(
            ToolPayloadCodec.result(from: payload?["result"]))
    }

    /// Render a tool result for the expanded chip: strings verbatim, structured
    /// results as pretty JSON, both capped so one runaway result can't be
    /// carried around in memory forever.
    static func describeResult(_ value: JSONValue?) -> String? {
        guard let value, value != .null else { return nil }
        if let text = value.stringValue {
            // This path is fed directly by live gateway payloads rather than
            // the retained-payload codec. Apply the same scalar/control
            // admission before prefixing so bidi/C0 controls cannot spoof a
            // copied or painted result, and avoid grapheme-bounded work on
            // combining-mark bombs.
            return text.isEmpty ? nil : ToolPayloadCodec.boundedText(
                text, maximum: ToolPayloadCodec.maximumResultCharacters)
        }
        return ToolPayloadCodec.result(from: value)?.displayText
    }

    // MARK: - Sending: submit, or steer while a turn runs

    /// Explicit Queue is deliberately separate from the normal composer
    /// action. Ordinary mid-turn Send continues to steer first; Queue stores
    /// only text for the next authoritative idle turn and never creates an
    /// optimistic transcript bubble.
    @discardableResult
    public func queuePrompt(text: String, to botID: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode == .live, !trimmed.isEmpty else { return false }
        let chat = chat(for: botID)
        guard chat.attachments.isEmpty else {
            chat.messages.append(ChatMessage(author: .system,
                text: DurableComposerQueueStoreError.attachmentRefused.description))
            return false
        }
        guard enqueueDurableLocalPrompt(trimmed, botID: botID, chat: chat) != nil else {
            return false
        }
        requestComposeQueueFlush()
        return true
    }

    public func resumeQueuedPrompts(botID: String) {
        guard let key = durableQueueKey(botID: botID) else { return }
        do {
            try durableComposerQueueStore.resume(key: key)
            reloadDurableComposerQueueProjection()
            requestComposeQueueFlush()
        } catch {
            chat(for: botID).messages.append(ChatMessage(author: .system,
                text: "Queued prompts stayed paused because local storage failed: \(error.localizedDescription)"))
        }
    }

    public func durableQueuedPrompts(for botID: String) -> [DurableComposerQueueEntry] {
        guard let key = durableQueueKey(botID: botID) else { return [] }
        return durableComposerQueueStore.entries(for: key).filter {
            !($0.state == .acceptedGatewayOwned && hiddenAcceptedQueueIDs.contains($0.id))
        }
    }

    public func removeDurableQueuedPrompt(id: UUID) {
        guard let entry = durableComposerQueueStore.entry(id: id) else { return }
        do {
            if entry.state == .uncertain {
                try durableComposerQueueStore.removeUncertain(id: id)
            } else if entry.state == .acceptedGatewayOwned {
                // Gateway-owned work cannot be cancelled or altered locally.
                hiddenAcceptedQueueIDs.insert(id)
            } else {
                try durableComposerQueueStore.remove(id: id)
            }
            durableComposerQueueEditReservations[id] = nil
            durableComposerQueueClaims.remove(id)
            promptQueue.removeAll { $0.id == id }
            ChatRuntime.shared.queuedBindings[id] = nil
            reloadDurableComposerQueueProjection()
        } catch {
            if let botID = chats.first(where: { botID, chat in
                (stateRoute(for: botID) ?? gatewayRoute(for: botID)) == entry.key.route
                    && chat.storedSessionID == entry.key.storedSessionID
            })?.key {
                chats[botID]?.messages.append(ChatMessage(author: .system,
                    text: "That queued prompt was retained: \(error.localizedDescription)"))
            }
        }
    }

    /// Local queue work becomes a gateway-owned mirror only after an
    /// authoritative receipt. The first transcript echo stays event-driven.
    func acceptLocalQueueEntry(id: UUID, text: String, botID: String,
                               chat: ChatState) {
        guard let entry = durableComposerQueueStore.entry(id: id),
              entry.state == .acceptedGatewayOwned else { return }
        hiddenAcceptedQueueIDs.remove(id)
        if !promptQueue.contains(where: { $0.id == id }) {
            promptQueue.append((id: id, botID: botID, text: text))
        }
        ChatRuntime.shared.queuedBindings[id] = QueuedPromptBinding(
            botID: botID, sessionID: chat.sessionID ?? "",
            storedID: entry.key.storedSessionID, route: entry.key.route,
            eligibleAfterCurrentTurn: true, order: entry.order)
        reloadDurableComposerQueueProjection()
    }

    /// The matching queued-start event is exact execution proof for this
    /// gateway-owned mirror. Generic queue CRUD never uses this path.
    func retireAcceptedDurableProjection(id: UUID) {
        guard durableComposerQueueStore.entry(id: id)?.state == .acceptedGatewayOwned else { return }
        do {
            _ = try durableComposerQueueStore.removeAcceptedForExecution(id: id)
            hiddenAcceptedQueueIDs.remove(id)
            promptQueue.removeAll { $0.id == id }
            ChatRuntime.shared.queuedBindings[id] = nil
            reloadDurableComposerQueueProjection()
        } catch {
            // Preserve the truthful mirror for a later authoritative event.
        }
    }

    /// The composer's send. A turn already in flight takes the desktop path —
    /// `session.steer` injects the text into the running turn instead of
    /// `prompt.submit`, which would interrupt it.
    public func sendOrSteer(text: String, to botID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let chat = chat(for: botID)
        // Staged attachments are a turn on their own — composedPrompt supplies
        // the words for an image sent without any.
        guard !trimmed.isEmpty || !chat.attachments.isEmpty else { return }

        // A failed-turn retry owns the composer until its delivery is proved
        // or rejected. The retry itself bypasses this surface and submits via
        // liveSendAwaiting after its tokenized pre-submit admission gate.
        guard ChatRuntime.shared.failedRetryRows[botID] == nil else {
            scheduleRetainedMutationReconciliation(botID: botID)
            return
        }
        // A normal composer send always returns the transcript to the
        // authoritative newest response before it can append/steer.
        chat.resetAssistantResponseSelection()

        switch mode {
        case .demo:
            guard !trimmed.isEmpty else { return }
            chat.messages.append(ChatMessage(author: .user, time: AppModel.clock(), text: trimmed))
            startDemoTurn(botID: botID, chat: chat)
        case .live:
            // An unresolved mutation owns this exact session. Do not append a
            // new optimistic row or issue a second wire verb while the first
            // operation is being reconciled.
            guard !mutationIsFenced(botID: botID) else {
                scheduleRetainedMutationReconciliation(botID: botID)
                return
            }
            let routeAvailable = !isOffline || GatewayBotRoute(qualifiedID: botID) != nil
            let turnInFlight = chat.isRunning || chat.isTyping
            if turnInFlight, routeAvailable {
                // `isTyping` is part of the same UI turn state as isRunning:
                // message.start and resume ordering can raise it first. Never
                // contradict the visible steer affordance by submitting a new
                // prompt in that window. Attachments alone also cannot steer.
                guard !trimmed.isEmpty else { return }
                // Deliberately mention-free. Desktop has no steer path at all
                // — its middleware only ever sees a fresh submit — so there is
                // no upstream answer for "@ops" typed into a turn already
                // running, and the conservative reading wins: steering is a
                // correction aimed at THIS bot mid-thought, and firing a
                // handoff out of one would send a half-sentence to a stranger.
                // The handle rides along as literal text, as it does today.
                if let sessionID = chat.sessionID,
                   LiveRuntime.shared.attachTasks[botID] == nil {
                    steer(text: trimmed, botID: botID, sessionID: sessionID, chat: chat)
                } else {
                    steerAfterAttach(text: trimmed, botID: botID, chat: chat)
                }
            } else {
                // The composer middleware runs FIRST, on the raw draft, which
                // is where desktop registers it (plugin.js:8214 reads
                // `draft.text`). Order is not incidental: the attachment
                // rewrite below prepends "@file:<path>" refs, and a mention
                // scan downstream of it would read those as an @file handle.
                // Bot Mode's canonical chat is one conversation forever.
                // Desktop's composer middleware intercepts a bare `/new` or
                // `/reset` aimed at that pinned chat and runs `/compact`
                // instead (plugin.js:8215-8241). Scratch sessions keep the
                // commands unchanged, and an unresolved pin is deliberately
                // not guessed at.
                let canonical = isCurrentCanonicalSession(
                    botID: botID, sessionID: chat.storedSessionID)
                let guarded: String
                switch ForeverChatGuard.resolve(trimmed, isCanonicalChat: canonical) {
                case .run(let text):
                    guarded = text
                case .rewritten(let replacement):
                    guarded = replacement
                    toast(kind: .info,
                          title: theme.copy.toastNeverResetsTitle(theme.themeID),
                          message: theme.copy.toastNeverResetsBody(theme.themeID),
                          botID: botID)
                }
                let routed = routeMentions(in: guarded, from: botID)
                // Staged attachments only reach the agent if their "@file:"
                // refs ride the prompt (images ride the session) — the
                // attachments surface owns that rewrite.
                let prompt = composedPrompt(routed, botID: botID)
                // send() appends the user bubble and submits (or queues while
                // offline) — going around it would duplicate the bubble.
                if LiveRuntime.shared.attachTasks[botID] != nil {
                    // A sessions-sheet selection owns the shared attach slot.
                    // Echo now, await that exact attach, then re-evaluate the
                    // resumed turn: an idle session receives a submit; a turn
                    // that resumed running receives a steer. Starting another
                    // ensureSession here used to race canonical resolution.
                    sendAfterAttach(text: prompt, botID: botID, chat: chat,
                                    routeAvailable: routeAvailable)
                } else {
                    ChatRuntime.shared.turnFloor[botID] = chat.messages.count + 1
                    if routeAvailable {
                        chat.beginTurnTiming(at: Date(), replacingExisting: true)
                    }
                    chat.isRunning = routeAvailable
                    send(text: prompt, to: botID)
                    if routeAvailable { startWatchdog(botID) }
                }
                clearAttachments(botID: botID)
            }
        }
    }

    /// A stop, transcript action, or ambiguous mid-turn mutation is an
    /// operation boundary, not a UI hint. The composer must stay inert until
    /// that exact operation is accepted, rejected, or reconciled.
    func mutationIsFenced(botID: String) -> Bool {
        let runtime = ChatRuntime.shared
        return MessageBranchRuntime.shared.actionIDs[botID] != nil
            || sessionControlMutationIsActive(botID: botID)
            || runtime.transcriptFences[botID] != nil
            || runtime.transcriptActions[botID] != nil
            || runtime.steerFences[botID] != nil
            || runtime.steerActions[botID] != nil
            || runtime.stopFences[botID] != nil
            || runtime.stopActions[botID] != nil
            || CanonicalChatRuntime.shared.ambiguousKickoffs[botID] != nil
    }

    /// During supervised reconnect the visible chat sid is intentionally nil
    /// for a short window. Ownership checks must consult the explicit parked
    /// sid too, or an old task that receives an ambiguous response in that
    /// window could release without creating the fence that adoption needs to
    /// migrate.
    func bindingSessionID(for botID: String) -> String? {
        chats[botID]?.sessionID ?? LiveRuntime.shared.reconnectParkedSessionIDs[botID]
    }

    func bindingRouteMatches(_ route: GatewayBotRoute, botID: String) -> Bool {
        if gatewayRoute(for: botID) == route { return true }
        // During lifecycle teardown the primary client may already be nil,
        // while the exact bare ChatState and gateway id still prove the
        // captured route. A state route is safe here because callers also
        // require the exact ChatState/durable binding; do not require a
        // parked SID, which is precisely what abort is about to preserve.
        return stateRoute(for: botID) == route
    }

    /// A retained ambiguous mutation is a read-only recovery obligation, not
    /// a permanent lock. Re-enter it after a reconnect/adoption or a blocked
    /// user tap. The task is coalesced per bot so one tap cannot start several
    /// resumes, and it never sends steer/redirect/submit/interrupt again.
    func retainedMutationNeedsReconciliation(botID: String) -> Bool {
        let runtime = ChatRuntime.shared
        return runtime.steerFences[botID] != nil
            || runtime.stopFences[botID] != nil
            || runtime.transcriptFences[botID] != nil
            || runtime.transcriptLeases[botID] != nil
            || runtime.offlineComposeFences.values.contains(where: { $0.botID == botID })
            || runtime.failedRetryRows[botID].map({ $0.phase != .prepared }) == true
            || CanonicalChatRuntime.shared.ambiguousKickoffs[botID] != nil
    }

    /// Check the exact binding captured when a deferred stop was tapped. A
    /// route/durable/chat mismatch retires the intent; a temporary runtime-sid
    /// or generation gap remains parked for bindSession/adopt to migrate.
    private func pendingStopStillOwnsBinding(_ pending: PendingStopRequest) -> Bool {
        guard let chat = chats[pending.botID],
              ObjectIdentifier(chat) == pending.chatID,
              chat.storedSessionID == pending.storedID else { return false }
        if let route = pendingStopRoute(botID: pending.botID), route != pending.route {
            return false
        }
        let currentSession = bindingSessionID(for: pending.botID)
        guard currentSession == pending.sessionID else { return false }
        return LiveRuntime.shared.generation == pending.generation
    }

    /// Drain work deferred behind a different mutation. A pending stop is
    /// issued only once every other operation/fence is gone; a deferred
    /// authoritative read is retried before the pending stop is considered.
    func drainPendingMutationWork(botID: String) {
        let runtime = ChatRuntime.shared
        guard !runtime.reconcilingBots.contains(botID),
              runtime.reconciliationTasks[botID] == nil else { return }

        if runtime.deferredReconciliationBots.contains(botID) {
            if retainedMutationNeedsReconciliation(botID: botID) {
                // Do not spin a read loop while the source is unavailable;
                // reconnect/adoption/tap will provide the next boundary.
                guard mode == .live, gatewayRoute(for: botID) != nil else { return }
                runtime.deferredReconciliationBots.remove(botID)
                if scheduleRetainedMutationReconciliation(botID: botID) { return }
            } else {
                runtime.deferredReconciliationBots.remove(botID)
            }
        }

        guard let pending = runtime.pendingStopRequests[botID] else { return }
        guard pendingStopStillOwnsBinding(pending) else {
            // If the exact ChatState/durable route is gone, this is A's intent
            // and must not be drained into a replacement B. A temporary
            // generation/sid gap is retained for bindSession to migrate; the
            // binding check above intentionally treats only exact ownership
            // as drainable.
            if chats[botID].map({ ObjectIdentifier($0) == pending.chatID }) == false
                || chats[botID]?.storedSessionID != pending.storedID
                || pendingStopRoute(botID: botID).map({ $0 != pending.route }) == true {
                runtime.pendingStopRequests[botID] = nil
            }
            return
        }
        guard
              runtime.steerActions[botID] == nil,
              runtime.steerFences[botID] == nil,
              runtime.stopActions[botID] == nil,
              runtime.stopFences[botID] == nil,
              runtime.transcriptActions[botID] == nil,
              runtime.transcriptFences[botID] == nil,
              !sessionControlMutationIsActive(botID: botID),
              CanonicalChatRuntime.shared.ambiguousKickoffs[botID] == nil else { return }
        runtime.pendingStopRequests[botID] = nil
        stopTurn(botID: botID)
    }

    @discardableResult
    func scheduleRetainedMutationReconciliation(botID: String) -> Bool {
        guard mode == .live,
              retainedMutationNeedsReconciliation(botID: botID),
              let route = gatewayRoute(for: botID) else { return false }
        let runtime = ChatRuntime.shared
        guard runtime.reconciliationTasks[botID] == nil,
              !runtime.reconcilingBots.contains(botID) else { return false }
        let token = UUID()
        runtime.reconciliationTokens[botID] = token
        let task = Task { @MainActor [weak self] in
            defer {
                if ChatRuntime.shared.reconciliationTokens[botID] == token {
                    ChatRuntime.shared.reconciliationTokens[botID] = nil
                    ChatRuntime.shared.reconciliationTasks[botID] = nil
                }
                self?.drainPendingMutationWork(botID: botID)
            }
            guard let self, !Task.isCancelled,
                  let client = try? await self.routedClient(for: route) else { return }

            if let fence = ChatRuntime.shared.steerFences[botID] {
                await self.reconcileSteerMutationViaGateway(fence, client: client)
            }
            guard !Task.isCancelled else { return }
            if let fence = ChatRuntime.shared.stopFences[botID] {
                await self.reconcileStopTurnViaGateway(
                    fence, note: self.theme.copy.stopNote(self.theme.themeID), client: client)
            }
            guard !Task.isCancelled else { return }
            if let lease = ChatRuntime.shared.transcriptLeases[botID] {
                await self.reconcileTranscriptAction(
                    lease, ambiguous: lease.submitStarted)
            }
            guard !Task.isCancelled else { return }
            if let composeFence = ChatRuntime.shared.offlineComposeFences.values.first(where: {
                $0.botID == botID && $0.route == route
            }) {
                do {
                    let live = try await client.resumeSession(
                        composeFence.storedID, profile: route.profile, deferHistory: false)
                    let payload = try await client.latestSessionMessages(
                        storedID: composeFence.storedID, profile: route.profile)
                    let rows = Self.chatMessages(fromTranscript: payload)
                    let proof = Self.provesOfflineComposeDelivery(composeFence, rows: rows)
                    guard live.storedSessionID.isEmpty || live.storedSessionID == composeFence.storedID,
                          chats[botID].map({ ObjectIdentifier($0) == composeFence.chatID }) == true,
                          chats[botID]?.storedSessionID == composeFence.storedID,
                          proof else { return }
                    self.retireProvenOfflineCompose(
                        composeFence, running: live.running,
                        retainedInflight: live.retainedInflight,
                        authoritativeRows: rows)
                } catch {
                    // An authoritative read failure is not proof of rejection.
                }
            }
            guard !Task.isCancelled else { return }
            if let retryLease = ChatRuntime.shared.failedRetryRows[botID],
               retryLease.phase != .prepared,
               ChatRuntime.shared.offlineComposeFences[retryLease.token] == nil {
                await self.reconcileFailedRetryLease(
                    retryLease, botID: botID, client: client)
            }
            guard !Task.isCancelled else { return }
            if let lease = CanonicalChatRuntime.shared.ambiguousKickoffs[botID] {
                await self.reconcileAmbiguousCanonicalKickoff(
                    lease, route: route, client: client)
            }
        }
        runtime.reconciliationTasks[botID] = task
        return true
    }

    private func reconcileFailedRetryLease(_ lease: FailedTurnRetryLease,
                                           botID: String,
                                           client: GatewayClient) async {
        guard ChatRuntime.shared.failedRetryRows[botID]?.token == lease.token,
              gatewayRoute(for: botID) == lease.route,
              let chat = chats[botID], ObjectIdentifier(chat) == lease.chatID,
              chat.sessionID == lease.sessionID,
              chat.storedSessionID == lease.storedID else { return }
        do {
            let live = try await client.resumeSession(
                lease.storedID, profile: lease.route.profile, deferHistory: false)
            let payload = try await client.latestSessionMessages(
                storedID: lease.storedID, profile: lease.route.profile)
            let rows = Self.chatMessages(fromTranscript: payload)
            guard live.storedSessionID.isEmpty || live.storedSessionID == lease.storedID,
                  ChatRuntime.shared.failedRetryRows[botID]?.token == lease.token,
                  chats[botID].map({ ObjectIdentifier($0) == lease.chatID }) == true,
                  chats[botID]?.sessionID == ChatRuntime.shared.failedRetryRows[botID]?.sessionID,
                  chats[botID]?.storedSessionID == lease.storedID else { return }
            _ = reconcileFailedRetryLeaseFromAuthority(
                lease, botID: botID, rows: rows, running: live.running,
                retainedInflight: live.retainedInflight)
        } catch {
            // No authoritative proof: preserve the no-replay lease and card.
        }
    }

    private func steer(text: String, botID: String, sessionID: String, chat: ChatState) {
        chat.messages.append(ChatMessage(author: .user, time: AppModel.clock(), text: text))
        deliverSteer(text: text, botID: botID, sessionID: sessionID,
                     optimisticID: chat.messages.last?.id)
    }

    private func deliverSteer(text: String, botID: String, sessionID: String,
                              optimisticID: UUID? = nil) {
        let owner = chat(for: botID)
        func retainSteer() {
            appendComposeQueue(botID: botID, text: text,
                               route: gatewayRoute(for: botID) ?? stateRoute(for: botID),
                               storedID: owner.storedSessionID, sessionID: sessionID,
                               chatID: ObjectIdentifier(owner))
        }
        guard !mutationIsFenced(botID: botID) else {
            retainSteer()
            scheduleRetainedMutationReconciliation(botID: botID)
            return
        }
        guard let route = gatewayRoute(for: botID) else {
            retainSteer()
            return
        }
        let submission = beginQueuedSubmission(botID: botID, sessionID: sessionID)
        let chat = chat(for: botID)
        let baselineMessages = optimisticID.map { optimisticID in
            chat.messages.filter { $0.id != optimisticID }
        } ?? chat.messages
        let baselineIsRunning = chat.isRunning
        let baselineIsTyping = chat.isTyping
        let baselineDurableRowIDs = Set(baselineMessages.compactMap(\.rowID))
        let baselineDurableUserTexts: Set<String> = Set(baselineMessages.compactMap { message -> String? in
            // A pre-operation optimistic row has no durable id yet, but its
            // body can still be the old in-flight turn. Keep all prior user
            // bodies here; the durable-id proof remains separately strict.
            guard message.author == .user else { return nil }
            return message.text
        })
        let lease = SteerMutationLease(
            id: UUID(), botID: botID, route: route, sessionID: sessionID,
            storedID: chat.storedSessionID, chatID: ObjectIdentifier(chat),
            optimisticID: optimisticID ?? chat.messages.last?.id ?? UUID(), text: text,
            generation: LiveRuntime.shared.generation,
            baselineDurableRowIDs: baselineDurableRowIDs,
            baselineDurableRowCount: baselineDurableRowIDs.count,
            baselineDurableUserTexts: baselineDurableUserTexts,
            baselineMessages: baselineMessages,
            baselineIsRunning: baselineIsRunning,
            baselineIsTyping: baselineIsTyping)
        ChatRuntime.shared.steerActions[botID] = lease
        Task { @MainActor in
            var lease = lease
            guard let client = try? await routedClient(for: route) else {
                discardQueuedSubmission(submission)
                releaseSteerMutation(lease)
                return
            }
            guard ChatRuntime.shared.steerActions[botID]?.id == lease.id,
                  let currentChat = chats[botID],
                  ObjectIdentifier(currentChat) == lease.chatID,
                  bindingRouteMatches(lease.route, botID: botID),
                  currentChat.storedSessionID == lease.storedID,
                  bindingSessionID(for: botID) == lease.sessionID,
                  ChatRuntime.shared.steerFences[botID] == nil,
                  ChatRuntime.shared.transcriptActions[botID] == nil,
                  ChatRuntime.shared.transcriptFences[botID] == nil,
                  ChatRuntime.shared.stopActions[botID] == nil,
                  ChatRuntime.shared.stopFences[botID] == nil,
                  CanonicalChatRuntime.shared.ambiguousKickoffs[botID] == nil
            else {
                discardQueuedSubmission(submission)
                // The lifecycle/reconnect may have replaced or retired this
                // exact lease while routedClient was suspended. Do not leave
                // the UUID-only action blocking the replacement forever.
                finishSteerMutation(lease)
                return
            }
            do {
                lease.stage = .steer
                lease.requestStarted = true
                updateSteerMutation(lease)
                let wireSessionID = ChatRuntime.shared.steerActions[botID]?.id == lease.id
                    ? ChatRuntime.shared.steerActions[botID]?.sessionID ?? sessionID
                    : sessionID
                let steered = try await client.steerTurn(sessionID: wireSessionID, text: text)
                guard let steerDisposition = settleSteerReceipt(
                    submission, text: text, stage: lease.stage, status: steered) else {
                    throw AckValidationError(
                        operation: "session.steer",
                        detail: "Hermes did not return an authoritative steer status.")
                }
                switch steerDisposition {
                case .acceptedCurrentTurn, .mirrorNextTurn:
                    finishSteerMutation(lease)
                    return
                case .advanceCascade:
                    // A wire-level rejection is definitive. It is the only
                    // answer that permits trying the next operation.
                    break
                }

                // Too late to steer: re-aim the turn, and failing that queue
                // the text behind it rather than interrupting what is running.
                lease.stage = .redirect
                lease.requestStarted = true
                updateSteerMutation(lease)
                let redirectSessionID = ChatRuntime.shared.steerActions[botID]?.id == lease.id
                    ? ChatRuntime.shared.steerActions[botID]?.sessionID ?? sessionID
                    : sessionID
                let redirected = try await client.redirectTurn(
                    sessionID: redirectSessionID, text: text)
                guard let redirectDisposition = settleSteerReceipt(
                    submission, text: text, stage: lease.stage, status: redirected) else {
                    throw AckValidationError(
                        operation: "session.redirect",
                        detail: "Hermes did not return an authoritative redirect status.")
                }
                switch redirectDisposition {
                case .acceptedCurrentTurn, .mirrorNextTurn:
                    finishSteerMutation(lease)
                    return
                case .advanceCascade:
                    // A definitive redirect rejection permits the queued
                    // submit fallback below; no ambiguous answer was seen.
                    break
                }

                lease.stage = .queuedSubmit
                lease.requestStarted = true
                updateSteerMutation(lease)
                let queuedSessionID = ChatRuntime.shared.steerActions[botID]?.id == lease.id
                    ? ChatRuntime.shared.steerActions[botID]?.sessionID ?? sessionID
                    : sessionID
                let receipt = try await client.submitPrompt(
                    sessionID: queuedSessionID, text: text, queued: true)
                try PromptSubmitReceipt.requireQueued(receipt,
                                                      operation: "Queued steer")
                guard let queuedStatus = receipt["status"]?.stringValue,
                      settleSteerReceipt(
                        submission, text: text, stage: lease.stage,
                        status: queuedStatus) == .mirrorNextTurn else {
                    throw AckValidationError(
                        operation: "Queued steer",
                        detail: "Hermes did not return an authoritative queued status.")
                }
                finishSteerMutation(lease)
            } catch {
                discardQueuedSubmission(submission)
                await handleSteerFailure(lease, error: error, client: client)
            }
        }
    }

    private func updateSteerMutation(_ lease: SteerMutationLease) {
        guard let active = ChatRuntime.shared.steerActions[lease.botID],
              active.id == lease.id else { return }
        var updated = lease
        // Keep the current durable binding if adopt migrated it while this
        // task was suspended at a client/transport await.
        updated.route = active.route
        updated.sessionID = active.sessionID
        updated.storedID = active.storedID
        updated.chatID = active.chatID
        updated.generation = active.generation
        ChatRuntime.shared.steerActions[lease.botID] = updated
    }

    private func releaseSteerMutation(_ lease: SteerMutationLease) {
        if ChatRuntime.shared.steerActions[lease.botID]?.id == lease.id {
            ChatRuntime.shared.steerActions[lease.botID] = nil
        }
        drainPendingMutationWork(botID: lease.botID)
    }

    /// Roll back only the optimistic projection owned by this exact steer.
    /// Rows/deltas that arrived while the transport was suspended survive the
    /// merge; a replacement ChatState or durable session is never touched.
    @discardableResult
    func restoreSteerMutationOptimisticIfOwned(_ lease: SteerMutationLease) -> Bool {
        guard let chat = chats[lease.botID].flatMap({
            ObjectIdentifier($0) == lease.chatID ? $0 : nil
        }) ?? chats.values.first(where: { ObjectIdentifier($0) == lease.chatID }),
              chat.messages.contains(where: { $0.id == lease.optimisticID }) else {
            return false
        }
        let newer = TranscriptActionReconciliation.newerRows(
            current: chat.messages, baseline: lease.baselineMessages,
            optimisticID: lease.optimisticID)
        chat.messages = TranscriptHydrationMerge.merge(
            history: lease.baselineMessages, baseline: [], current: newer,
            clearWhenEmpty: true)
        chat.isRunning = lease.baselineIsRunning
        chat.isTyping = lease.baselineIsTyping
        return true
    }

    private func finishSteerMutation(_ lease: SteerMutationLease) {
        releaseSteerMutation(lease)
        if ChatRuntime.shared.steerFences[lease.botID]?.operationID == lease.id {
            ChatRuntime.shared.steerFences[lease.botID] = nil
        }
        drainPendingMutationWork(botID: lease.botID)
    }

    func fenceSteerMutationIfOwned(_ lease: SteerMutationLease) {
        let runtime = ChatRuntime.shared
        guard let active = runtime.steerActions[lease.botID], active.id == lease.id,
              let chat = chats[lease.botID].flatMap({
                  ObjectIdentifier($0) == active.chatID ? $0 : nil
              }) ?? chats.values.first(where: { ObjectIdentifier($0) == active.chatID }),
              (chat.sessionID ?? LiveRuntime.shared.reconnectParkedSessionIDs[lease.botID]
                  ?? chats.values.first(where: { ObjectIdentifier($0) == active.chatID })?.sessionID)
                  == active.sessionID,
              chat.storedSessionID == active.storedID,
              bindingRouteMatches(active.route, botID: lease.botID) else { return }
        runtime.steerFences[lease.botID] = SteerMutationFence(
            operationID: active.id, botID: active.botID, route: active.route,
            sessionID: active.sessionID, storedID: active.storedID,
            chatID: active.chatID, optimisticID: active.optimisticID,
            text: active.text, stage: active.stage, generation: active.generation,
            baselineDurableRowIDs: active.baselineDurableRowIDs,
            baselineDurableRowCount: active.baselineDurableRowCount,
            baselineDurableUserTexts: active.baselineDurableUserTexts)
    }

    private func handleSteerFailure(_ lease: SteerMutationLease, error: Error,
                                    client: GatewayClient) async {
        let ambiguous = lease.requestStarted && PromptMutationFailure.isAmbiguous(error)
        guard ChatRuntime.shared.steerActions[lease.botID]?.id == lease.id else {
            if ambiguous { fenceSteerMutationIfOwned(lease) }
            return
        }
        guard ambiguous else {
            releaseSteerMutation(lease)
            if let chat = chats[lease.botID], ObjectIdentifier(chat) == lease.chatID {
                let detail = (error as? GatewayError)?.message ?? error.localizedDescription
                chat.messages.append(ChatMessage(author: .system, text: detail))
            }
            return
        }

        fenceSteerMutationIfOwned(lease)
        releaseSteerMutation(lease)
        guard let fence = ChatRuntime.shared.steerFences[lease.botID],
              fence.operationID == lease.id else { return }
        await reconcileSteerMutationViaGateway(fence, client: client)
    }

    /// Production wiring for both the first ambiguous response and every
    /// later reconnect/adoption/tap retry. The closures only resume and read;
    /// no mutation verb is attempted from reconciliation.
    private func reconcileSteerMutationViaGateway(
        _ fence: SteerMutationFence, client: GatewayClient
    ) async {
        guard !ChatRuntime.shared.reconcilingBots.contains(fence.botID) else {
            ChatRuntime.shared.deferredReconciliationBots.insert(fence.botID)
            return
        }
        ChatRuntime.shared.reconcilingBots.insert(fence.botID)
        defer {
            ChatRuntime.shared.reconcilingBots.remove(fence.botID)
            drainPendingMutationWork(botID: fence.botID)
        }
        let generation = LiveRuntime.shared.generation
        await reconcileSteerMutation(
            fence,
            resume: {
                let target = fence.storedID ?? fence.sessionID
                return try await client.resumeSession(target, profile: fence.route.profile,
                                                      deferHistory: false)
            },
            hydrate: { [weak self] live in
                guard let self else { return }
                let chat = self.chat(for: fence.botID)
                let baseline = chat.messages
                self.adopt(live, storedID: live.storedSessionID.isEmpty
                           ? fence.storedID : live.storedSessionID,
                           botID: fence.botID, sourceGatewayID: fence.route.gatewayID)
                self.replayInflight(live, botID: fence.botID)
                var history = AppModel.chatMessages(fromTranscript: .array(live.messages))
                if history.isEmpty, let stored = fence.storedID, !stored.isEmpty {
                    let payload = try await client.latestSessionMessages(
                        storedID: stored, profile: fence.route.profile)
                    history = AppModel.chatMessages(fromTranscript: payload)
                }
                guard LiveRuntime.shared.generation >= generation,
                      self.bindingRouteMatches(fence.route, botID: fence.botID) else {
                    throw CancellationError()
                }
                chat.messages = TranscriptHydrationMerge.merge(
                    history: history, baseline: baseline,
                    current: chat.messages, clearWhenEmpty: false)
            },
            accepts: { [weak self] in
                guard let self,
                      LiveRuntime.shared.generation >= generation,
                      self.bindingRouteMatches(fence.route, botID: fence.botID),
                      let chat = self.chats[fence.botID],
                      ObjectIdentifier(chat) == fence.chatID,
                      (fence.storedID == nil || chat.storedSessionID == fence.storedID)
                else { return false }
                return true
            })
    }

    /// Read-only reconciliation for an ambiguous steer/redirect/queued-submit
    /// response. No subsequent mutation is attempted from this path.
    func reconcileSteerMutation(
        _ fence: SteerMutationFence,
        resume: @MainActor () async throws -> LiveSession,
        hydrate: @MainActor (LiveSession) async throws -> Void,
        accepts: @MainActor () -> Bool
    ) async {
        let runtime = ChatRuntime.shared
        guard runtime.steerFences[fence.botID]?.operationID == fence.operationID else { return }
        do {
            let live = try await resume()
            let sameDurableSession: Bool
            if let storedID = fence.storedID, !storedID.isEmpty {
                sameDurableSession = live.storedSessionID == storedID
            } else {
                sameDurableSession = false
            }
            guard runtime.steerFences[fence.botID]?.operationID == fence.operationID,
                  (live.sessionID == fence.sessionID || sameDurableSession),
                  (fence.storedID == nil || live.storedSessionID == fence.storedID),
                  (fence.generation < 0 || LiveRuntime.shared.generation >= fence.generation),
                  accepts() else { return }
            try await hydrate(live)
            guard let activeFence = runtime.steerFences[fence.botID],
                  activeFence.operationID == fence.operationID, accepts() else { return }
            let durableUserTexts: Set<String> = Set(chats[activeFence.botID]?.messages.compactMap { message -> String? in
                guard message.author == .user, message.rowID != nil,
                      message.id != activeFence.optimisticID else { return nil }
                return message.text
            } ?? [])
            let remote = SteerMutationReconciliation.hasRemoteEvidence(
                live, text: activeFence.text,
                baselineDurableRowIDs: activeFence.baselineDurableRowIDs,
                baselineDurableRowCount: activeFence.baselineDurableRowCount,
                baselineDurableUserTexts: activeFence.baselineDurableUserTexts.union(durableUserTexts))
            let hydrated = chats[activeFence.botID].map {
                SteerMutationReconciliation.hasPostOperationDurableRow(
                    $0.messages, text: activeFence.text,
                    baselineDurableRowIDs: activeFence.baselineDurableRowIDs,
                    baselineDurableRowCount: activeFence.baselineDurableRowCount)
            } == true
            // A successful read with neither the in-flight marker nor a
            // durable row is not a reconciliation. Keep the fence: clearing
            // it would permit a duplicate correction whose first answer was
            // merely lost.
            guard remote || hydrated else { return }
            if runtime.steerFences[fence.botID]?.operationID == fence.operationID {
                runtime.steerFences[fence.botID] = nil
            }
            if runtime.steerActions[fence.botID]?.id == fence.operationID {
                runtime.steerActions[fence.botID] = nil
            }
        } catch {
            // Uncertainty remains explicit. The fence survives until a later
            // authoritative resume proves the exact text's fate.
        }
    }

    /// message.start/resume can raise the UI's steer state one MainActor turn
    /// before the runtime sid is published. Keep the user's correction,
    /// coalesce onto (or start) the one attach, then deliver it through the
    /// same steer/redirect/queued cascade; never downgrade it to a new
    /// unqueued prompt.
    private func steerAfterAttach(text: String, botID: String, chat: ChatState) {
        let optimistic = ChatMessage(author: .user, time: AppModel.clock(), text: text)
        chat.messages.append(optimistic)
        let capturedRoute = stateRoute(for: botID) ?? gatewayRoute(for: botID)
        let capturedStoredID = chat.storedSessionID
        let capturedSessionID = chat.sessionID
        Task { @MainActor in
            do {
                let sessionID = try await ensureSession(botID: botID, hydrate: false)
                guard exactAttachIntentOwner(botID: botID, chat: chat,
                                             route: capturedRoute,
                                             storedID: capturedStoredID,
                                             sessionID: capturedSessionID,
                                             resolvedSessionID: sessionID),
                      !mutationIsFenced(botID: botID) else {
                    retainAttachIntent(text: text, botID: botID, chat: chat,
                                       optimisticID: optimistic.id)
                    scheduleRetainedMutationReconciliation(botID: botID)
                    return
                }
                deliverSteer(text: text, botID: botID, sessionID: sessionID,
                             optimisticID: optimistic.id)
            } catch is CancellationError {
                recoverCancelledAttachIntent(
                    text: text, botID: botID, chat: chat,
                    optimisticID: optimistic.id, steering: true,
                    routeAvailable: true)
            } catch {
                let detail = (error as? GatewayError)?.message ?? error.localizedDescription
                guard chats[botID].map({ ObjectIdentifier($0) == ObjectIdentifier(chat) }) == true else {
                    retainAttachIntent(text: text, botID: botID, chat: chat,
                                       optimisticID: optimistic.id)
                    return
                }
                chat.messages.append(ChatMessage(author: .system, text: detail))
            }
        }
    }

    /// Preserve a compose action issued while an explicit stored-session
    /// resume owns `LiveRuntime.attachTasks`. The user bubble is optimistic,
    /// but the wire verb is chosen only after the resume tells us whether a
    /// turn survived the switch.
    private func sendAfterAttach(text: String, botID: String, chat: ChatState,
                                 routeAvailable: Bool) {
        let optimistic = ChatMessage(author: .user, time: AppModel.clock(), text: text)
        chat.messages.append(optimistic)
        let capturedRoute = stateRoute(for: botID) ?? gatewayRoute(for: botID)
        let capturedStoredID = chat.storedSessionID
        let capturedSessionID = chat.sessionID
        Task { @MainActor in
            do {
                let sessionID = try await ensureSession(botID: botID, hydrate: false)
                guard exactAttachIntentOwner(botID: botID, chat: chat,
                                             route: capturedRoute,
                                             storedID: capturedStoredID,
                                             sessionID: capturedSessionID,
                                             resolvedSessionID: sessionID),
                      !mutationIsFenced(botID: botID) else {
                    retainAttachIntent(text: text, botID: botID, chat: chat,
                                       optimisticID: optimistic.id)
                    scheduleRetainedMutationReconciliation(botID: botID)
                    return
                }
                if chat.isRunning || chat.isTyping {
                    deliverSteer(text: text, botID: botID, sessionID: sessionID,
                                 optimisticID: optimistic.id)
                } else {
                    ChatRuntime.shared.turnFloor[botID] = chat.messages.count
                    if routeAvailable {
                        chat.beginTurnTiming(at: Date(), replacingExisting: true)
                    }
                    chat.isRunning = routeAvailable
                    liveSend(text: text, botID: botID, chat: chat,
                             optimisticID: optimistic.id)
                    if routeAvailable { startWatchdog(botID) }
                }
            } catch let error as GatewayError where error.code == -3 || error.code == -7 {
                chat.isRunning = false
                if GatewayBotRoute(qualifiedID: botID) == nil {
                    isOffline = true
                    appendComposeQueue(botID: botID, text: text,
                                       route: capturedRoute, storedID: capturedStoredID,
                                       sessionID: capturedSessionID, chatID: ObjectIdentifier(chat))
                } else {
                    guard chats[botID].map({ ObjectIdentifier($0) == ObjectIdentifier(chat) }) == true else {
                        retainAttachIntent(text: text, botID: botID, chat: chat,
                                           optimisticID: optimistic.id)
                        return
                    }
                    chat.messages.append(ChatMessage(author: .system, text: error.message))
                }
            } catch is CancellationError {
                recoverCancelledAttachIntent(
                    text: text, botID: botID, chat: chat,
                    optimisticID: optimistic.id, steering: false,
                    routeAvailable: routeAvailable)
            } catch {
                chat.isRunning = false
                let detail = (error as? GatewayError)?.message ?? error.localizedDescription
                guard chats[botID].map({ ObjectIdentifier($0) == ObjectIdentifier(chat) }) == true else {
                    retainAttachIntent(text: text, botID: botID, chat: chat,
                                       optimisticID: optimistic.id)
                    return
                }
                chat.messages.append(ChatMessage(author: .system, text: detail))
            }
        }
    }

    private func exactAttachIntentOwner(
        botID: String, chat: ChatState, route: GatewayBotRoute?, storedID: String?,
        sessionID: String?, resolvedSessionID: String
    ) -> Bool {
        guard let route,
              let current = chats[botID], ObjectIdentifier(current) == ObjectIdentifier(chat),
              bindingRouteMatches(route, botID: botID),
              current.sessionID == resolvedSessionID,
              current.storedSessionID != nil else { return false }
        if let storedID, current.storedSessionID != storedID { return false }
        if let sessionID, sessionID != resolvedSessionID { return false }
        return true
    }

    private func retainAttachIntent(text: String, botID: String, chat: ChatState,
                                    optimisticID: UUID) {
        if let owner = chats[botID], ObjectIdentifier(owner) == ObjectIdentifier(chat),
           chat.messages.contains(where: { $0.id == optimisticID }) {
            return
        }
        appendComposeQueue(botID: botID, text: text,
                           route: gatewayRoute(for: botID) ?? stateRoute(for: botID),
                           storedID: chat.storedSessionID, sessionID: chat.sessionID,
                           chatID: ObjectIdentifier(chat))
    }

    /// Cancellation has two meanings. An explicit selection clears the old
    /// optimistic row (and often replaces the ChatState), so it owns the
    /// outcome and this intent disappears with that transcript. A reconnect
    /// or generation reset leaves the exact row in the exact chat; recover it
    /// against an already rebound sid when possible, otherwise retain it in
    /// the visible compose queue for the reconnect flush.
    private func recoverCancelledAttachIntent(
        text: String, botID: String, chat: ChatState, optimisticID: UUID,
        steering: Bool, routeAvailable: Bool
    ) {
        guard let owner = chats[botID], owner === chat,
              chat.messages.contains(where: { $0.id == optimisticID }) else { return }

        guard !mutationIsFenced(botID: botID) else {
            retainAttachIntent(text: text, botID: botID, chat: chat,
                               optimisticID: optimisticID)
            scheduleRetainedMutationReconciliation(botID: botID)
            return
        }

        if let sessionID = chat.sessionID,
           let route = gatewayRoute(for: botID),
           self.botID(forSession: sessionID, sourceGatewayID: route.gatewayID) == botID {
            if steering || chat.isRunning || chat.isTyping {
                deliverSteer(text: text, botID: botID, sessionID: sessionID,
                             optimisticID: optimisticID)
            } else {
                ChatRuntime.shared.turnFloor[botID] = chat.messages.count
                chat.isRunning = routeAvailable
                liveSend(text: text, botID: botID, chat: chat,
                         optimisticID: optimisticID)
                if routeAvailable { startWatchdog(botID) }
            }
            return
        }

        chat.isRunning = false
        appendComposeQueue(botID: botID, text: text,
                           route: gatewayRoute(for: botID) ?? stateRoute(for: botID),
                           storedID: chat.storedSessionID, sessionID: chat.sessionID,
                           chatID: ObjectIdentifier(chat))
    }

    /// Demo mode's scripted reply, owned here so the stop button can cancel it
    /// (AppModel's own demo reply is fire-and-forget).
    private func startDemoTurn(botID: String, chat: ChatState) {
        let runtime = ChatRuntime.shared
        runtime.demoTurns[botID]?.cancel()
        runtime.turnFloor[botID] = chat.messages.count
        chat.isTyping = true
        chat.isRunning = true
        chat.beginTurnTiming(at: Date(), replacingExisting: true)
        runtime.demoTurns[botID] = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Double.random(in: 0.9...1.8)))
            guard !Task.isCancelled else { return }
            chat.isTyping = false
            chat.isRunning = false
            let reply = DemoData.cannedReplies[botID]
                ?? DemoData.cannedReplies["default"]
                ?? "On it. I’ll report back here when it’s done."
            chat.messages.append(ChatMessage(author: .bot, time: AppModel.clock(), text: reply))
            self.settleTurnTiming(in: chat, botID: botID)
            ChatRuntime.shared.demoTurns[botID] = nil
        }
    }

    /// A submit whose turn never starts (accepted RPC, wedged gateway, socket
    /// lost) would otherwise strand the composer on Stop.
    private func startWatchdog(_ botID: String) {
        let runtime = ChatRuntime.shared
        runtime.submitWatchdogs[botID]?.cancel()
        runtime.submitWatchdogs[botID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self else { return }
            let chat = self.chat(for: botID)
            if chat.messages.last?.isStreaming != true {
                chat.isRunning = false
                chat.clearTurnTiming()
            }
            ChatRuntime.shared.submitWatchdogs[botID] = nil
            if ChatRuntime.shared.failedRetryRows[botID]?.phase == .submitting {
                self.scheduleRetainedMutationReconciliation(botID: botID)
            }
        }
    }

    private func clearWatchdog(_ botID: String) {
        ChatRuntime.shared.submitWatchdogs[botID]?.cancel()
        ChatRuntime.shared.submitWatchdogs[botID] = nil
    }


    // MARK: - Transcript acting (edit / rewind / regenerate)

    /// Desktop's restore checkpoint: drop this user turn and everything after
    /// it, then run the same text again.
    public func rewind(to message: ChatMessage, in botID: String) {
        applyTranscriptPlan(TranscriptActing.planRestore(chat(for: botID).messages, from: message.id),
                            botID: botID)
    }

    /// Desktop's regenerate: resubmit the nearest previous user prompt.
    public func regenerate(from message: ChatMessage, in botID: String) {
        applyTranscriptPlan(TranscriptActing.planReload(chat(for: botID).messages, from: message.id),
                            botID: botID)
    }

    /// Desktop's edit: drop the original user turn and resubmit the new text.
    public func editMessage(_ message: ChatMessage, in botID: String, to text: String) {
        applyTranscriptPlan(TranscriptActing.planEdit(chat(for: botID).messages, from: message.id, text: text),
                            botID: botID)
    }

    public func canActOnTranscript(_ message: ChatMessage, in botID: String) -> Bool {
        guard mode == .live else { return false }
        let chat = chat(for: botID)
        ChatRuntime.shared.pruneTranscriptState(
            botID: botID, generation: LiveRuntime.shared.generation)
        guard chat.sessionID != nil, chat.storedSessionID?.isEmpty == false,
              !chat.isRunning, !chat.isTyping,
              MessageBranchRuntime.shared.actionIDs[botID] == nil,
              !sessionControlMutationIsActive(botID: botID),
              ChatRuntime.shared.transcriptActions[botID] == nil,
              ChatRuntime.shared.transcriptFences[botID] == nil else { return false }
        if message.author == .user {
            return TranscriptActing.planRestore(chat.messages, from: message.id) != nil
        }
        if message.author == .bot, !message.isStreaming {
            return TranscriptActing.planReload(chat.messages, from: message.id) != nil
        }
        return false
    }

    /// Presentation-only ownership query. The composer must preserve its draft
    /// while this exact retry owns the next same-session lifecycle event.
    public func hasUnresolvedFailedTurnRetry(in botID: String) -> Bool {
        chat(for: botID).hasUnresolvedRetry
    }

    /// A failed-turn retry is a fresh prompt, never a destructive regenerate.
    /// Hermes has already terminated the failed turn; sending the same body
    /// without truncate matches Desktop and avoids treating a possibly
    /// unpersisted retained user row as a safe truncation address.
    public func canRetryFailedTurn(_ message: ChatMessage, in botID: String) -> Bool {
        guard mode == .live, let failure = message.failure,
              failure.errorSurface?.retryable != false,
              ChatRuntime.shared.failedRetryRows[botID] == nil else { return false }
        let chat = chat(for: botID)
        guard let index = chat.messages.firstIndex(where: { $0.id == message.id }),
              chat.messages[index].author == .bot,
              chat.messages[...index].last(where: {
                  $0.author == .user
                      && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) != nil,
              chat.sessionID?.isEmpty == false,
              chat.storedSessionID?.isEmpty == false,
              gatewayRoute(for: botID) != nil,
              !chat.isRunning, !chat.isTyping,
              LiveRuntime.shared.attachTasks[botID] == nil,
              !mutationIsFenced(botID: botID) else { return false }
        return true
    }

    public func retryFailedTurn(_ message: ChatMessage, in botID: String) {
        guard let request = prepareFailedTurnRetry(message, in: botID) else { return }
        let chat = chat(for: botID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let lease = ChatRuntime.shared.failedRetryRows[botID],
                  lease.token == request.token else { return }
            guard lease.phase == .prepared,
                  self.gatewayRoute(for: botID) == request.route,
                  chat.storedSessionID == request.storedID,
                  self.chats[botID].map(ObjectIdentifier.init) == request.chatID else {
                if lease.phase == .prepared {
                    self.cancelFailedTurnRetry(request, in: botID, chat: chat)
                }
                return
            }
            // A local transcript cannot distinguish a genuinely empty durable
            // baseline from an optimistic/nil-id row. Establish the retry's
            // exact authoritative watermark before any submit; a failed read
            // leaves the original card retryable and sends nothing.
            do {
                let client = try await self.routedClient(for: request.route)
                let payload = try await client.latestSessionMessages(
                    storedID: request.storedID, profile: request.route.profile)
                guard self.applyFailedRetryAuthoritativeBaseline(
                    request, in: botID, payload: payload) else {
                    self.cancelFailedTurnRetry(request, in: botID, chat: chat)
                    return
                }
            } catch {
                self.cancelFailedTurnRetry(request, in: botID, chat: chat)
                return
            }
            let result = await self.liveSendAwaiting(
                text: request.text, botID: botID, chat: chat,
                composeItemID: request.token,
                preSubmitAdmission: {
                    self.admitFailedTurnRetrySubmission(request, in: botID)
                })
            self.settleFailedTurnRetry(request, result: result, in: botID, chat: chat)
        }
    }

    /// Synchronous admission/projection seam. Tests use it to prove Retry
    /// neither appends a second user bubble nor acquires a truncate address;
    /// the public action performs only the subsequent exact-route submit.
    func prepareFailedTurnRetry(_ message: ChatMessage,
                                in botID: String) -> FailedTurnRetryRequest? {
        guard canRetryFailedTurn(message, in: botID) else { return nil }
        let chat = chat(for: botID)
        guard let failure = message.failure,
              let index = chat.messages.firstIndex(where: { $0.id == message.id }),
              let route = gatewayRoute(for: botID),
              let storedID = chat.storedSessionID, !storedID.isEmpty,
              let user = chat.messages[...index].last(where: {
                  $0.author == .user
                      && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else { return nil }
        let token = UUID()
        let watermark = chat.messages.compactMap { row in
            row.author == .user ? row.rowID : nil
        }.max()
        let undurableMatchingCount = chat.messages.filter {
            $0.author == .user && $0.rowID == nil && $0.text == user.text
        }.count
        let request = FailedTurnRetryRequest(
            token: token, text: user.text, assistantID: message.id, route: route,
            storedID: storedID, chatID: ObjectIdentifier(chat))
        ChatRuntime.shared.failedRetryRows[botID] = FailedTurnRetryLease(
            token: token, assistantID: message.id, route: route,
            sessionID: chat.sessionID ?? "", storedID: storedID,
            chatID: ObjectIdentifier(chat), phase: .prepared,
            baselineText: message.text, baselineFailure: failure,
            promptText: user.text, baselineDurableUserRowIDWatermark: watermark,
            baselineUndurableMatchingUserCount: undurableMatchingCount)
        chat.hasUnresolvedRetry = true
        ChatRuntime.shared.dismissedFailures[ObjectIdentifier(chat)] = nil
        return request
    }

    /// Synchronous last-moment gate invoked immediately before submitPrompt.
    /// MainActor serialization makes prepared -> submitting atomic with every
    /// event/lifecycle cancellation that can retire this exact token.
    func admitFailedTurnRetrySubmission(_ request: FailedTurnRetryRequest,
                                        in botID: String) -> Bool {
        guard var lease = ChatRuntime.shared.failedRetryRows[botID],
              lease.token == request.token, lease.phase == .prepared,
              lease.assistantID == request.assistantID,
              lease.route == request.route, lease.storedID == request.storedID,
              lease.chatID == request.chatID else { return false }
        lease.phase = .submitting
        ChatRuntime.shared.failedRetryRows[botID] = lease
        if let chat = chats[botID], ObjectIdentifier(chat) == request.chatID {
            chat.beginTurnTiming(at: Date(), replacingExisting: true)
            chat.isRunning = true
        }
        startWatchdog(botID)
        return true
    }

    @discardableResult
    func applyFailedRetryAuthoritativeBaseline(
        _ request: FailedTurnRetryRequest, in botID: String,
        payload: JSONValue
    ) -> Bool {
        guard let rawRows = payload["messages"]?.arrayValue ?? payload.arrayValue,
              rawRows.allSatisfy({ $0.objectValue != nil }) else { return false }
        let rows = Self.chatMessages(fromTranscript: payload)
        guard applyFailedRetryAuthoritativeBaseline(
            request, in: botID, rows: rows) else { return false }
        guard var lease = ChatRuntime.shared.failedRetryRows[botID],
              lease.token == request.token, lease.phase == .prepared else { return false }
        // Include every durable user row in the strict proof boundary, even a
        // hidden/system-marker row that is intentionally absent from display.
        lease.baselineDurableUserRowIDWatermark = rawRows.compactMap { row in
            guard row["role"]?.stringValue == "user" else { return nil }
            return row["row_id"]?.intValue ?? row["id"]?.intValue
        }.max()
        ChatRuntime.shared.failedRetryRows[botID] = lease
        return true
    }

    @discardableResult
    func applyFailedRetryAuthoritativeBaseline(
        _ request: FailedTurnRetryRequest, in botID: String,
        rows: [ChatMessage]
    ) -> Bool {
        guard var lease = ChatRuntime.shared.failedRetryRows[botID],
              lease.token == request.token, lease.phase == .prepared,
              lease.route == request.route, lease.storedID == request.storedID,
              lease.chatID == request.chatID,
              gatewayRoute(for: botID) == request.route,
              let chat = chats[botID], ObjectIdentifier(chat) == request.chatID,
              chat.sessionID == lease.sessionID,
              chat.storedSessionID == request.storedID else { return false }
        lease.baselineDurableUserRowIDWatermark = rows.compactMap { row in
            row.author == .user ? row.rowID : nil
        }.max()
        lease.baselineUndurableMatchingUserCount = rows.filter {
            $0.author == .user && $0.rowID == nil && $0.text == request.text
        }.count
        lease.authoritativeBaselineKnown = true
        ChatRuntime.shared.failedRetryRows[botID] = lease
        return true
    }

    func settleFailedTurnRetry(_ request: FailedTurnRetryRequest,
                               result: LiveSendResult, in botID: String,
                               chat: ChatState) {
        guard let lease = ChatRuntime.shared.failedRetryRows[botID],
              lease.token == request.token else { return }
        let clears: Bool
        switch result {
        case .failed: clears = true
        case .retained: clears = lease.phase == .prepared
        case .accepted: clears = false
        }
        guard clears else { return }
        ChatRuntime.shared.failedRetryRows[botID] = nil
        chat.hasUnresolvedRetry = false
        chat.isRunning = false
        chat.clearTurnTiming()
        clearWatchdog(botID)
    }

    private func cancelFailedTurnRetry(_ request: FailedTurnRetryRequest,
                                       in botID: String, chat: ChatState) {
        guard ChatRuntime.shared.failedRetryRows[botID]?.token == request.token else { return }
        ChatRuntime.shared.failedRetryRows[botID] = nil
        chat.hasUnresolvedRetry = false
        chat.isRunning = false
        chat.clearTurnTiming()
        clearWatchdog(botID)
    }

    public func canDismissFailedTurn(_ message: ChatMessage, in botID: String) -> Bool {
        let chat = chat(for: botID)
        guard chat.messages.contains(where: {
            $0.id == message.id && $0.failure != nil
        }) else { return false }
        return ChatRuntime.shared.failedRetryRows[botID]?.assistantID != message.id
    }

    public func dismissFailedTurn(_ message: ChatMessage, in botID: String) {
        guard canDismissFailedTurn(message, in: botID) else { return }
        let chat = chat(for: botID)
        guard let index = chat.messages.firstIndex(where: {
            $0.id == message.id && $0.failure != nil
        }) else { return }
        guard let failure = chat.messages[index].failure else { return }
        if let route = gatewayRoute(for: botID),
           let storedID = chat.storedSessionID, !storedID.isEmpty {
            ChatRuntime.shared.dismissedFailures[ObjectIdentifier(chat)] =
                DismissedTurnFailure(route: route, storedID: storedID,
                                     message: failure.message)
        }
        chat.messages[index].failure = nil
        if chat.messages[index].text.isEmpty,
           chat.messages[index].reasoning?.isEmpty != false,
           chat.messages[index].toolCalls.isEmpty,
           chat.messages[index].card == nil {
            let removed = chat.messages.remove(at: index)
            ChatRuntime.shared.retainedFailureRows[ObjectIdentifier(chat)]?
                .remove(removed.id)
        }
    }

    private func applyTranscriptPlan(_ plan: TranscriptActing.Plan?, botID: String) {
        guard let plan, !plan.truncate.isEmpty else { return }
        let chat = chat(for: botID)
        let runtime = ChatRuntime.shared
        runtime.pruneTranscriptState(botID: botID, generation: LiveRuntime.shared.generation)
        guard let sid = chat.sessionID, let storedID = chat.storedSessionID,
              let actionRoute = gatewayRoute(for: botID),
              !storedID.isEmpty, !chat.isRunning, !chat.isTyping,
              !sessionControlMutationIsActive(botID: botID),
              runtime.transcriptActions[botID] == nil,
              runtime.transcriptFences[botID] == nil else { return }
        let baseline = chat.messages
        let effectProof = TranscriptActionEffectProof.capture(plan: plan, baseline: baseline)
        guard effectProof != nil else { return }
        let operationID = UUID()
        chat.messages = TranscriptActing.applyOptimistic(baseline, plan: plan)
        let optimistic = ChatMessage(author: .user, time: AppModel.clock(), text: plan.text)
        chat.messages.append(optimistic)
        if plan.kind == .regenerate,
           let previousSourceUserID = plan.sourceUserID,
           !plan.previousAssistantRun.isEmpty {
            // The destructive submit replaces the old durable source row with
            // this new local identity. The plan still captures the old source
            // identity; the shelf binds to the exact current row so selected
            // snapshots can be projected in place after the mutation.
            let binding = AssistantResponseAlternativesBinding(
                chatID: chat.chatIdentity,
                sourceUserID: optimistic.id,
                storedSessionID: storedID,
                runtimeSessionID: sid,
                gatewayID: actionRoute.gatewayID,
                profile: actionRoute.profile)
            runtime.assistantResponseAlternativeStages[botID] =
                AssistantResponseAlternativeStage(
                    operationID: operationID, botID: botID,
                    chatID: ObjectIdentifier(chat), binding: binding,
                    previousSourceUserID: previousSourceUserID,
                    invalidatedSourceUserIDs: Set(
                        baseline.dropFirst(plan.sourceIndex + 1)
                            .filter { $0.author == .user }.map(\.id)),
                    previousAssistantRun: plan.previousAssistantRun)
        }
        chat.beginTurnTiming(at: Date(), replacingExisting: true)
        chat.isRunning = true
        let lease = TranscriptActionLease(
            id: operationID, botID: botID, sessionID: sid, storedID: storedID,
            gatewayID: actionRoute.gatewayID, profile: actionRoute.profile,
            generation: LiveRuntime.shared.generation, chatID: ObjectIdentifier(chat),
            optimisticID: optimistic.id, baseline: baseline,
            effectProof: effectProof)
        runtime.transcriptActions[botID] = lease.id
        runtime.transcriptActionGenerations[botID] = lease.generation
        runtime.transcriptLeases[botID] = lease
        Task { @MainActor in
            let route = GatewayBotRoute(gatewayID: lease.gatewayID, profile: lease.profile)
            var submitStarted = false
            do {
                let client = try await routedClient(for: route)
                guard ownsTranscriptAction(lease) else { return }
                // From this line onward a lost answer may represent an
                // accepted destructive mutation. Before it, no mutation was
                // sent and no durable fence is justified.
                submitStarted = true
                if runtime.transcriptLeases[botID]?.id == lease.id {
                    var acceptedLease = lease
                    acceptedLease.submitStarted = true
                    runtime.transcriptLeases[botID] = acceptedLease
                }
                let result = try await client.submitPrompt(sessionID: sid, text: plan.text,
                                                           truncate: plan.truncate)
                try PromptSubmitReceipt.requireAccepted(result, operation: "Transcript action")
                guard ownsTranscriptAction(lease) else {
                    fenceTranscriptActionIfDurableTargetStillOwned(lease)
                    releaseTranscriptAction(lease)
                    return
                }
                let survivors = TranscriptActing.survivorRowIDs(from: result)
                if !survivors.isEmpty {
                    chat.messages = TranscriptActing.rebindSurvivorRowIDs(chat.messages,
                                                                          survivorRowIDs: survivors)
                }
                commitAssistantResponseAlternativeIfProven(lease)
                releaseTranscriptAction(lease)
                startWatchdog(botID)
            } catch {
                let ambiguous = submitStarted && PromptMutationFailure.isAmbiguous(error)
                guard ownsTranscriptAction(lease) else {
                    if ambiguous { fenceTranscriptActionIfDurableTargetStillOwned(lease) }
                    if !ambiguous { clearAssistantResponseAlternativeIfOwned(lease) }
                    releaseTranscriptAction(lease)
                    return
                }
                if ambiguous {
                    runtime.transcriptFences[botID] = TranscriptActionFence(
                        operationID: lease.id, sessionID: sid, storedID: storedID,
                        gatewayID: route.gatewayID, profile: route.profile,
                        generation: lease.generation, effectProof: lease.effectProof,
                        chatID: lease.chatID)
                }
                await reconcileTranscriptAction(lease, ambiguous: ambiguous)
                let detail = (error as? GatewayError)?.message ?? error.localizedDescription
                toast(kind: .failure,
                      title: theme.copy.toastTranscriptActFailed(theme.themeID),
                      message: detail,
                      botID: botID)
            }
        }
    }

    private func ownsTranscriptAction(_ lease: TranscriptActionLease) -> Bool {
        guard ChatRuntime.shared.transcriptActions[lease.botID] == lease.id,
              let chat = chats[lease.botID].flatMap({
                  ObjectIdentifier($0) == lease.chatID ? $0 : nil
              }) ?? chats.values.first(where: { ObjectIdentifier($0) == lease.chatID })
        else { return false }
        let route = GatewayBotRoute(gatewayID: lease.gatewayID, profile: lease.profile)
        guard bindingRouteMatches(route, botID: lease.botID) else { return false }
        let sameDurableBinding = chat.storedSessionID == lease.storedID
        let generationOwned = LiveRuntime.shared.generation == lease.generation
            || (sameDurableBinding
                && ChatRuntime.shared.transcriptActionGenerations[lease.botID]
                    == LiveRuntime.shared.generation)
        return generationOwned && (chat.sessionID == lease.sessionID || sameDurableBinding)
    }

    func fenceTranscriptActionIfDurableTargetStillOwned(_ lease: TranscriptActionLease) {
        guard let chat = chats[lease.botID].flatMap({
            ObjectIdentifier($0) == lease.chatID ? $0 : nil
        }) ?? chats.values.first(where: { ObjectIdentifier($0) == lease.chatID }),
              chat.storedSessionID == lease.storedID,
              let route = gatewayRoute(for: lease.botID) ?? stateRoute(for: lease.botID),
              route.gatewayID == lease.gatewayID, route.profile == lease.profile else { return }
        ChatRuntime.shared.transcriptFences[lease.botID] = TranscriptActionFence(
            operationID: lease.id, sessionID: chat.sessionID ?? lease.sessionID, storedID: lease.storedID,
            gatewayID: lease.gatewayID, profile: lease.profile,
            generation: LiveRuntime.shared.generation, effectProof: lease.effectProof,
            chatID: lease.chatID)
    }

    private func releaseTranscriptAction(_ lease: TranscriptActionLease) {
        if ChatRuntime.shared.transcriptActions[lease.botID] == lease.id {
            ChatRuntime.shared.transcriptActions[lease.botID] = nil
            ChatRuntime.shared.transcriptActionGenerations[lease.botID] = nil
        }
        if ChatRuntime.shared.transcriptLeases[lease.botID]?.id == lease.id {
            ChatRuntime.shared.transcriptLeases[lease.botID] = nil
        }
    }

    /// Restore an edit/rewind/regenerate projection when the request never
    /// crossed the acceptance boundary. This is intentionally exact-owner
    /// only; a lifecycle replacement must not resurrect rows in a new chat.
    @discardableResult
    func restoreTranscriptActionOptimisticIfOwned(_ lease: TranscriptActionLease) -> Bool {
        guard ownsTranscriptBinding(lease),
              let chat = chats[lease.botID].flatMap({
                  ObjectIdentifier($0) == lease.chatID ? $0 : nil
              }) ?? chats.values.first(where: { ObjectIdentifier($0) == lease.chatID }) else {
            return false
        }
        let newer = TranscriptActionReconciliation.newerRows(
            current: chat.messages, baseline: lease.baseline,
            optimisticID: lease.optimisticID)
        chat.messages = TranscriptHydrationMerge.merge(
            history: lease.baseline, baseline: [], current: newer,
            clearWhenEmpty: true)
        chat.isRunning = false
        chat.isTyping = false
        clearAssistantResponseAlternativeIfOwned(lease)
        return true
    }

    /// Re-read the exact durable session after any failed destructive submit.
    /// Never restore the captured snapshot: message/tool deltas may have landed
    /// since it was taken, and a superseding session owns its own transcript.
    private func reconcileTranscriptAction(_ lease: TranscriptActionLease,
                                           ambiguous: Bool) async {
        guard ownsTranscriptAction(lease) else {
            releaseTranscriptAction(lease)
            return
        }
        guard let route = gatewayRoute(for: lease.botID),
              route.gatewayID == lease.gatewayID,
              route.profile == lease.profile,
              let client = try? await routedClient(for: route) else {
            if !ambiguous { restoreDefiniteTranscriptFailure(lease) }
            releaseTranscriptAction(lease)
            return
        }
        do {
            let live = try await client.resumeSession(lease.storedID, profile: route.profile,
                                                      deferHistory: false)
            let payload = try await client.latestSessionMessages(
                storedID: lease.storedID, profile: route.profile)
            let resumeHistory = Self.chatMessages(fromTranscript: .array(live.messages))
            let authoritative = Self.chatMessages(fromTranscript: payload)
            guard ownsTranscriptAction(lease), let chat = chats[lease.botID] else {
                releaseTranscriptAction(lease)
                return
            }
            var newer = TranscriptActionReconciliation.newerRows(
                current: chat.messages, baseline: lease.baseline,
                optimisticID: lease.optimisticID)
            adopt(live, storedID: lease.storedID, botID: lease.botID,
                  sourceGatewayID: route.gatewayID)
            replayInflight(live, botID: lease.botID)
            let replayed = TranscriptActionReconciliation.newerRows(
                current: chat.messages, baseline: lease.baseline,
                optimisticID: lease.optimisticID)
            for row in replayed where !newer.contains(where: { $0.id == row.id }) {
                newer.append(row)
            }
            chat.messages = TranscriptHydrationMerge.merge(
                history: authoritative, baseline: [], current: newer, clearWhenEmpty: true)
            chat.isRunning = live.running
            chat.isTyping = live.running
            let proof = ChatRuntime.shared.transcriptFences[lease.botID]?.effectProof
                ?? lease.effectProof
            let effectProven = proof.map {
                $0.proves(resumeHistory) || $0.proves(authoritative)
                    || $0.proves(chat.messages)
                    || $0.proves(live)
            } == true
            if effectProven {
                commitAssistantResponseAlternativeIfProven(lease)
            }
            releaseTranscriptAction(lease)
            // A successful resume/read is not proof that the destructive
            // submit landed. Keep the no-replay fence when the exact target
            // was not removed and the replacement body was not observed.
            guard effectProven else { return }
            if let fence = ChatRuntime.shared.transcriptFences[lease.botID],
               fence.operationID == lease.id,
               fence.acceptsAuthoritativeHydration(
                   gatewayID: route.gatewayID, profile: route.profile,
                   storedID: lease.storedID, generation: lease.generation,
                   currentGeneration: LiveRuntime.shared.generation) {
                ChatRuntime.shared.transcriptFences[lease.botID] = nil
            }
        } catch {
            releaseTranscriptAction(lease)
            // A definite refusal is proof that the destructive operation did
            // not cross its acceptance boundary. Even if the read-back also
            // fails, restore only the optimistic projection and release the
            // action; fencing this path would strand edit/rewind forever.
            if !ambiguous {
                restoreDefiniteTranscriptFailure(lease)
            }
        }
    }

    private func restoreDefiniteTranscriptFailure(_ lease: TranscriptActionLease) {
        guard ownsTranscriptBinding(lease), let chat = chats[lease.botID] else { return }
        let newer = TranscriptActionReconciliation.newerRows(
            current: chat.messages, baseline: lease.baseline,
            optimisticID: lease.optimisticID)
        chat.messages = TranscriptHydrationMerge.merge(
            history: lease.baseline, baseline: [], current: newer,
            clearWhenEmpty: true)
        chat.isRunning = false
        chat.isTyping = false
        clearAssistantResponseAlternativeIfOwned(lease)
    }

    /// Publish the staged old run exactly once. An accepted submit receipt is
    /// sufficient; an ambiguous receipt reaches this method only after the
    /// existing exact transcript effect proof has settled.
    @discardableResult
    func commitAssistantResponseAlternativeIfProven(
        _ lease: TranscriptActionLease
    ) -> Bool {
        let runtime = ChatRuntime.shared
        guard let stage = runtime.assistantResponseAlternativeStages[lease.botID],
              stage.operationID == lease.id, !stage.committed,
              let chat = chats[lease.botID], ObjectIdentifier(chat) == stage.chatID,
              chat.chatIdentity == stage.binding.chatID,
              chat.storedSessionID == stage.binding.storedSessionID,
              chat.sessionID == stage.binding.runtimeSessionID,
              let route = gatewayRoute(for: lease.botID),
              route.gatewayID == stage.binding.gatewayID,
              route.profile == stage.binding.profile else { return false }
        var shelf = AssistantResponseAlternativesPolicy.pruning(
            sourceUserIDs: stage.invalidatedSourceUserIDs,
            in: chat.assistantResponseAlternatives)
        shelf = AssistantResponseAlternativesPolicy.rebindSourceUserID(
            from: stage.previousSourceUserID,
            to: stage.binding.sourceUserID,
            matching: stage.binding,
            in: shelf)
        chat.assistantResponseBinding = stage.binding
        chat.assistantResponseAlternatives = AssistantResponseAlternativesPolicy.record(
            stage.previousAssistantRun, binding: stage.binding,
            state: shelf)
        // The stage is one-shot evidence. Once the run is admitted, removing
        // it prevents a later definite refusal/cleanup callback from wiping
        // committed shelves and makes repeated commit attempts fail closed.
        runtime.assistantResponseAlternativeStages[lease.botID] = nil
        return true
    }

    func clearAssistantResponseAlternativeIfOwned(_ lease: TranscriptActionLease) {
        let runtime = ChatRuntime.shared
        guard let stage = runtime.assistantResponseAlternativeStages[lease.botID],
              stage.operationID == lease.id else { return }
        // A definite refusal owns only this uncommitted stage. Previously
        // committed groups are independent local history and must survive.
        runtime.assistantResponseAlternativeStages[lease.botID] = nil
    }

    private func ownsTranscriptBinding(_ lease: TranscriptActionLease) -> Bool {
        guard let chat = chats[lease.botID].flatMap({
            ObjectIdentifier($0) == lease.chatID ? $0 : nil
        }) ?? chats.values.first(where: { ObjectIdentifier($0) == lease.chatID }) else { return false }
        let route = GatewayBotRoute(gatewayID: lease.gatewayID, profile: lease.profile)
        guard bindingRouteMatches(route, botID: lease.botID) else { return false }
        let sameDurableBinding = chat.storedSessionID == lease.storedID
        return (LiveRuntime.shared.generation == lease.generation || sameDurableBinding)
            && (chat.sessionID == lease.sessionID || sameDurableBinding)
    }


    func queuedPromptLifecycle(botID: String, sessionID: String) -> QueuedPromptLifecycle {
        ChatRuntime.shared.queuedLifecycles[queuedPromptSession(
            botID: botID, sessionID: sessionID)] ?? .init()
    }

    func noteQueuedPromptStart(botID: String, sessionID: String) {
        let key = queuedPromptSession(botID: botID, sessionID: sessionID)
        ChatRuntime.shared.queuedLifecycles[key, default: .init()].starts += 1
    }

    func noteQueuedPromptCompletion(botID: String, sessionID: String) {
        let key = queuedPromptSession(botID: botID, sessionID: sessionID)
        ChatRuntime.shared.queuedLifecycles[key, default: .init()].completions += 1
    }

    func beginQueuedSubmission(botID: String, sessionID: String) -> PendingQueuedSubmission {
        let runtime = ChatRuntime.shared
        runtime.nextQueuedSubmissionOrder &+= 1
        let session = queuedPromptSession(botID: botID, sessionID: sessionID)
        let submission = PendingQueuedSubmission(
            id: UUID(), session: session,
            lifecycle: queuedPromptLifecycle(botID: botID, sessionID: sessionID),
            order: runtime.nextQueuedSubmissionOrder)
        runtime.pendingQueuedSubmissions[session, default: []].append(submission)
        return submission
    }

    func discardQueuedSubmission(_ submission: PendingQueuedSubmission) {
        removeQueuedSubmission(submission, reassignConsumedStart: true)
    }

    private func removeQueuedSubmission(_ submission: PendingQueuedSubmission,
                                        reassignConsumedStart: Bool) {
        let runtime = ChatRuntime.shared
        guard let pending = runtime.pendingQueuedSubmissions[submission.session]?
            .first(where: { $0.id == submission.id }) else { return }
        runtime.pendingQueuedSubmissions[submission.session]?.removeAll { $0.id == submission.id }
        if runtime.pendingQueuedSubmissions[submission.session]?.isEmpty == true {
            runtime.pendingQueuedSubmissions[submission.session] = nil
        }
        guard reassignConsumedStart, pending.startedBeforeAcknowledgement else { return }

        // The start happened, even if the request that provisionally owned it
        // later answers non-queued. Hand that exact FIFO token to the next
        // submission instead of losing it and leaving a ghost mirror behind.
        let nextPending = runtime.pendingQueuedSubmissions[submission.session]?
            .enumerated()
            .filter { !$0.element.startedBeforeAcknowledgement && $0.element.order > pending.order }
            .min(by: { $0.element.order < $1.element.order })
        let nextAccepted = promptQueue.compactMap { item -> (UUID, UInt64)? in
            guard let binding = runtime.queuedBindings[item.id],
                  binding.botID == submission.session.botID,
                  binding.sessionID == submission.session.sessionID,
                  binding.storedID == submission.session.storedID,
                  binding.route == submission.session.route,
                  binding.eligibleAfterCurrentTurn,
                  binding.order > pending.order else { return nil }
            return (item.id, binding.order)
        }.min(by: { $0.1 < $1.1 })

        if let accepted = nextAccepted,
           accepted.1 < (nextPending?.element.order ?? UInt64.max) {
            promptQueue.removeAll { $0.id == accepted.0 }
            runtime.queuedBindings[accepted.0] = nil
        } else if let nextPending {
            var rows = runtime.pendingQueuedSubmissions[submission.session] ?? []
            guard rows.indices.contains(nextPending.offset) else { return }
            rows[nextPending.offset].startedBeforeAcknowledgement = true
            runtime.pendingQueuedSubmissions[submission.session] = rows
        }
    }

    func acceptQueuedSubmission(_ submission: PendingQueuedSubmission, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let runtime = ChatRuntime.shared
        guard !trimmed.isEmpty,
              let pending = runtime.pendingQueuedSubmissions[submission.session]?
                .first(where: { $0.id == submission.id }) else { return }
        removeQueuedSubmission(submission, reassignConsumedStart: false)
        guard !pending.startedBeforeAcknowledgement else { return }
        let now = runtime.queuedLifecycles[submission.session] ?? .init()
        let id = UUID()
        let insert = promptQueue.firstIndex { item in
            (runtime.queuedBindings[item.id]?.order ?? UInt64.max) > pending.order
        } ?? promptQueue.endIndex
        promptQueue.insert((id: id, botID: submission.session.botID, text: trimmed), at: insert)
        runtime.queuedBindings[id] = QueuedPromptBinding(
            botID: submission.session.botID, sessionID: submission.session.sessionID,
            storedID: submission.session.storedID, route: submission.session.route,
            eligibleAfterCurrentTurn: now.completions > pending.lifecycle.completions,
            order: pending.order)
    }

    /// Settle the actual wire receipt at the shared cascade boundary. Hermes
    /// overloads `queued`: `session.steer` has injected into the running turn,
    /// while redirect and explicit queued-submit acknowledgements describe
    /// genuine next-turn work.
    @discardableResult
    func settleSteerReceipt(_ submission: PendingQueuedSubmission, text: String,
                            stage: SteerMutationStage,
                            status: String) -> SteerReceiptDisposition? {
        guard let disposition = SteerReceiptDisposition.resolve(
            stage: stage, status: status) else { return nil }
        switch disposition {
        case .acceptedCurrentTurn:
            discardQueuedSubmission(submission)
        case .mirrorNextTurn:
            acceptQueuedSubmission(submission, text: text)
        case .advanceCascade:
            break
        }
        return disposition
    }

    func enqueuePrompt(_ text: String, botID: String, sessionID: String) {
        let submission = beginQueuedSubmission(botID: botID, sessionID: sessionID)
        acceptQueuedSubmission(submission, text: text)
    }

    public func dismissQueuedPrompt(id: UUID) {
        promptQueue.removeAll { $0.id == id }
        ChatRuntime.shared.queuedBindings[id] = nil
    }

    public func queuedPrompts(for botID: String) -> [(id: UUID, botID: String, text: String)] {
        guard let sessionID = chats[botID]?.sessionID else { return [] }
        let session = queuedPromptSession(botID: botID, sessionID: sessionID)
        return promptQueue.filter {
            guard let binding = ChatRuntime.shared.queuedBindings[$0.id] else { return false }
            return binding.botID == session.botID
                && binding.sessionID == session.sessionID
                && binding.storedID == session.storedID
                && binding.route == session.route
        }
    }

    func markQueuedPromptsEligible(botID: String, sessionID: String) {
        let runtime = ChatRuntime.shared
        let session = queuedPromptSession(botID: botID, sessionID: sessionID)
        for id in promptQueue.lazy.filter({ $0.botID == botID }).map(\.id) {
            guard var binding = runtime.queuedBindings[id],
                  binding.sessionID == session.sessionID,
                  binding.storedID == session.storedID,
                  binding.route == session.route else { continue }
            binding.eligibleAfterCurrentTurn = true
            runtime.queuedBindings[id] = binding
        }
    }

    func drainStartedQueuedPrompt(botID: String, sessionID: String) {
        let runtime = ChatRuntime.shared
        let key = queuedPromptSession(botID: botID, sessionID: sessionID)
        let item = promptQueue.first(where: {
            guard $0.botID == botID, let binding = runtime.queuedBindings[$0.id] else { return false }
            return binding.sessionID == key.sessionID
                && binding.storedID == key.storedID
                && binding.route == key.route
                && binding.eligibleAfterCurrentTurn
        })
        let pending = runtime.pendingQueuedSubmissions[key]?.first
        let itemOrder = item.flatMap { runtime.queuedBindings[$0.id]?.order }
        // Gateway execution is submission-FIFO, not acknowledgement-FIFO. An
        // earlier request whose ack is delayed owns this start ahead of a later
        // request that happened to acknowledge first.
        if let item, let itemOrder, itemOrder < (pending?.order ?? UInt64.max) {
            promptQueue.removeAll { $0.id == item.id }
            runtime.queuedBindings[item.id] = nil
            retireAcceptedDurableProjection(id: item.id)
            return
        }
        guard var pendingRows = runtime.pendingQueuedSubmissions[key], !pendingRows.isEmpty else { return }
        pendingRows[0].startedBeforeAcknowledgement = true
        runtime.pendingQueuedSubmissions[key] = pendingRows
    }

    func removeQueuedPrompts(botID: String, sessionID: String) {
        let session = queuedPromptSession(botID: botID, sessionID: sessionID)
        removeQueuedPrompts(session)
    }

    private func queuedPromptSession(botID: String, sessionID: String) -> QueuedPromptSession {
        QueuedPromptSession(botID: botID, sessionID: sessionID,
                            storedID: chats[botID]?.storedSessionID,
                            route: stateRoute(for: botID))
    }

    func removeQueuedPrompts(_ session: QueuedPromptSession) {
        let runtime = ChatRuntime.shared
        let removed = promptQueue.filter {
            guard let binding = runtime.queuedBindings[$0.id] else { return false }
            return binding.botID == session.botID
                && binding.sessionID == session.sessionID
                && binding.storedID == session.storedID
                && binding.route == session.route
        }.map(\.id)
        promptQueue.removeAll { removed.contains($0.id) }
        for id in removed { runtime.queuedBindings[id] = nil }
        runtime.pendingQueuedSubmissions[session] = nil
    }

    /// AppModel's presentation queue is intentionally a tuple for the chat
    /// view, while ChatRuntime owns the identity-bearing mirrors. Keep the two
    /// stores in lockstep when a reconnect rotates only the runtime sid.
    @discardableResult
    func migrateQueuedState(fromBotID: String, toBotID: String,
                            route: GatewayBotRoute,
                            oldSessionID: String, newSessionID: String,
                            storedID: String) -> Bool {
        let ids = ChatRuntime.shared.migrateQueuedState(
            fromBotID: fromBotID, toBotID: toBotID, route: route,
            oldSessionID: oldSessionID, newSessionID: newSessionID,
            storedID: storedID)
        guard !ids.isEmpty else { return false }
        for index in promptQueue.indices where ids.contains(promptQueue[index].id) {
            promptQueue[index].botID = toBotID
        }
        return true
    }

    /// Remove only queue state proven to belong to one route and durable
    /// session, and remove its visible rows by identity rather than text.
    @discardableResult
    func retireQueuedState(botID: String, route: GatewayBotRoute,
                           storedID: String?) -> Bool {
        let ids = ChatRuntime.shared.retireQueuedState(
            botID: botID, route: route, storedID: storedID)
        guard !ids.isEmpty else { return false }
        promptQueue.removeAll { ids.contains($0.id) }
        return true
    }

    // MARK: - Stop (session.interrupt)

    /// Stop is itself a mutation. If steer/redirect or another authoritative
    /// read currently owns the bot, retain the user's stop intent and drain it
    /// only after that owner settles; sending interrupt concurrently would
    /// create two unresolved fences with no safe ordering.
    func deferStopUntilMutationSettles(botID: String, wasRunning: Bool) -> Bool {
        guard mode == .live else { return false }
        let runtime = ChatRuntime.shared
        if runtime.stopActions[botID] != nil || runtime.stopFences[botID] != nil {
            scheduleRetainedMutationReconciliation(botID: botID)
            return true
        }
        let blocked = runtime.steerActions[botID] != nil
            || runtime.steerFences[botID] != nil
            || runtime.transcriptActions[botID] != nil
            || runtime.transcriptFences[botID] != nil
            || sessionControlMutationIsActive(botID: botID)
            || runtime.reconcilingBots.contains(botID)
            || runtime.reconciliationTasks[botID] != nil
            || CanonicalChatRuntime.shared.ambiguousKickoffs[botID] != nil
        guard blocked else { return false }
        if wasRunning,
           let pending = pendingStopRequest(botID: botID) {
            runtime.pendingStopRequests[botID] = pending
        }
        scheduleRetainedMutationReconciliation(botID: botID)
        return true
    }

    /// Resolve the binding route. Prefer the mutation owner because a reconnect
    /// can temporarily make the visible route nil.
    private func pendingStopRoute(botID: String) -> GatewayBotRoute? {
        let runtime = ChatRuntime.shared
        return runtime.steerActions[botID]?.route
            ?? runtime.steerFences[botID]?.route
            ?? runtime.stopActions[botID]?.route
            ?? runtime.stopFences[botID]?.route
            ?? runtime.transcriptFences[botID].map {
                GatewayBotRoute(gatewayID: $0.gatewayID, profile: $0.profile)
            }
            ?? gatewayRoute(for: botID)
            ?? stateRoute(for: botID)
    }

    /// Capture the owner route/session at the tap. Prefer the mutation owner
    /// because a reconnect can temporarily make the visible route nil.
    private func pendingStopRequest(botID: String) -> PendingStopRequest? {
        let runtime = ChatRuntime.shared
        let chat = chat(for: botID)
        guard let route = pendingStopRoute(botID: botID) else { return nil }
        let sessionID = bindingSessionID(for: botID)
            ?? runtime.steerActions[botID]?.sessionID
            ?? runtime.steerFences[botID]?.sessionID
            ?? runtime.stopActions[botID]?.sessionID
            ?? runtime.stopFences[botID]?.sessionID
            ?? runtime.transcriptFences[botID]?.sessionID
        return PendingStopRequest(
            botID: botID, route: route, storedID: chat.storedSessionID,
            sessionID: sessionID, chatID: ObjectIdentifier(chat),
            generation: LiveRuntime.shared.generation)
    }

    /// Halt the running turn. The gateway also cancels queued prompts, releases
    /// blocking clarify/sudo/secret prompts and denies every pending approval
    /// for the session (ws-protocol §6.2) — so the local approval cards for
    /// this bot go with it.
    public func stopTurn(botID: String) {
        let chat = chat(for: botID)
        let wasRunning = chat.isRunning || chat.isTyping
        // Stop means local follow-ups must be parked before an interrupt can
        // race a next-turn drain. Gateway-owned/uncertain rows remain intact.
        if let key = durableQueueKey(botID: botID, chat: chat) {
            do {
                try durableComposerQueueStore.park(key: key)
                reloadDurableComposerQueueProjection()
            } catch {
                chat.messages.append(ChatMessage(author: .system,
                    text: "Queued prompts were not parked because local storage failed: \(error.localizedDescription)"))
                return
            }
        }
        ChatRuntime.shared.demoTurns[botID]?.cancel()
        ChatRuntime.shared.demoTurns[botID] = nil

        // A retained uncertain stop is retried through authoritative resume,
        // never by issuing a second interrupt. A stop tapped during another
        // mutation is retained and drained after that mutation's outcome.
        if deferStopUntilMutationSettles(botID: botID, wasRunning: wasRunning) {
            return
        }

        guard wasRunning else { return }
        let note = theme.copy.stopNote(theme.themeID)

        // Demo work is wholly local, so cancellation is an authoritative stop.
        // Live work stays visibly running until session.interrupt is accepted.
        guard mode == .live else {
            chat.isRunning = false
            chat.isTyping = false
            chat.clearTurnTiming()
            clearWatchdog(botID)
            finishRunningTools(in: chat, interrupted: true)
            chat.messages.append(ChatMessage(author: .system, text: note))
            return
        }

        guard ChatRuntime.shared.stopActions[botID] == nil,
              ChatRuntime.shared.stopFences[botID] == nil else {
            scheduleRetainedMutationReconciliation(botID: botID)
            return
        }

        guard let sessionID = chat.sessionID,
              let route = gatewayRoute(for: botID) else {
            // There is no addressable interrupt. Keep a local fence anyway:
            // claiming idle here would permit a new submit against unknown
            // work after a reconnect. `adopt` retires this sentinel only
            // after an authoritative reattach names the same durable chat.
            let sentinelRoute = GatewayBotRoute(
                gatewayID: "__unaddressable__", profile: botID)
            ChatRuntime.shared.stopFences[botID] = StopTurnFence(
                operationID: UUID(), botID: botID, route: sentinelRoute,
                sessionID: "", storedID: chat.storedSessionID,
                chatID: ObjectIdentifier(chat),
                generation: LiveRuntime.shared.generation,
                unaddressable: true)
            chat.isRunning = true
            chat.isTyping = true
            chat.messages.append(ChatMessage(
                author: .system,
                text: "Unable to stop this turn while the gateway is unavailable."))
            return
        }
        let lease = StopTurnLease(
            botID: botID, route: route, sessionID: sessionID,
            storedID: chat.storedSessionID, chatID: ObjectIdentifier(chat),
            generation: LiveRuntime.shared.generation)
        ChatRuntime.shared.stopActions[botID] = lease
        Task { @MainActor in
            var attempt = lease
            do {
                let client = try await routedClient(for: attempt.route)
                guard let active = ChatRuntime.shared.stopActions[botID],
                      active.id == attempt.id else { return }
                attempt.route = active.route
                attempt.sessionID = active.sessionID
                attempt.storedID = active.storedID
                attempt.chatID = active.chatID
                attempt.generation = active.generation
                attempt.requestStarted = true
                ChatRuntime.shared.stopActions[botID] = attempt
                if let override = ChatRuntime.shared.interruptForTesting {
                    try await override(client, attempt.sessionID)
                } else {
                    try await client.interruptSession(attempt.sessionID)
                }
                applyStopCompletion(attempt, note: note)
            } catch {
                let ambiguous = attempt.requestStarted && PromptMutationFailure.isAmbiguous(error)
                if ambiguous {
                    fenceStopTurnIfOwned(attempt)
                    releaseStopTurn(attempt)
                    guard let fence = ChatRuntime.shared.stopFences[botID],
                          fence.operationID == attempt.id,
                          let reconcileClient = try? await self.routedClient(for: fence.route)
                    else { return }
                    await reconcileStopTurnViaGateway(
                        fence, note: note, client: reconcileClient)
                } else {
                    releaseStopTurn(attempt)
                    guard self.stopCompletionIsOwned(attempt) else { return }
                    // A definitive interrupt failure is not evidence that the
                    // turn ended. Restore the running affordance before
                    // releasing the operation so a new call cannot take the
                    // submit path against still-live work.
                    chat.isRunning = true
                    chat.isTyping = true
                    let detail = (error as? GatewayError)?.message ?? error.localizedDescription
                    // The interrupt did not have an ambiguous acceptance
                    // boundary. The turn is still running and may be retried.
                    chat.messages.append(ChatMessage(author: .system, text: detail))
                }
            }
        }
    }

    private func releaseStopTurn(_ lease: StopTurnLease) {
        if ChatRuntime.shared.stopActions[lease.botID]?.id == lease.id {
            ChatRuntime.shared.stopActions[lease.botID] = nil
        }
    }

    private func fenceStopTurnIfOwned(_ lease: StopTurnLease) {
        guard let active = ChatRuntime.shared.stopActions[lease.botID], active.id == lease.id,
              stopCompletionIsOwned(active) else { return }
        ChatRuntime.shared.stopFences[lease.botID] = StopTurnFence(
            operationID: active.id, botID: active.botID, route: active.route,
            sessionID: active.sessionID, storedID: active.storedID,
            chatID: active.chatID, generation: active.generation)
    }

    private func reconcileStopTurnViaGateway(
        _ fence: StopTurnFence, note: String, client: GatewayClient
    ) async {
        guard !ChatRuntime.shared.reconcilingBots.contains(fence.botID) else {
            ChatRuntime.shared.deferredReconciliationBots.insert(fence.botID)
            return
        }
        ChatRuntime.shared.reconcilingBots.insert(fence.botID)
        defer {
            ChatRuntime.shared.reconcilingBots.remove(fence.botID)
            drainPendingMutationWork(botID: fence.botID)
        }
        await reconcileStopTurn(
            fence, note: note,
            resume: {
                let target = fence.storedID ?? fence.sessionID
                return try await client.resumeSession(
                    target, profile: fence.route.profile, deferHistory: false)
            },
            accepts: {
                self.stopFenceStillAddresses(fence)
            })
    }

    private func stopFenceStillAddresses(_ fence: StopTurnFence) -> Bool {
        guard !fence.unaddressable,
              let current = ChatRuntime.shared.stopFences[fence.botID],
              current.operationID == fence.operationID,
              let chat = chats[fence.botID], ObjectIdentifier(chat) == current.chatID,
              bindingSessionID(for: fence.botID) == current.sessionID,
              (current.storedID == nil || chat.storedSessionID == current.storedID),
              (current.generation < 0 || LiveRuntime.shared.generation >= current.generation),
              bindingRouteMatches(current.route, botID: fence.botID) else { return false }
        return true
    }

    /// Reconcile an interrupt whose response was lost. Only a resumed idle
    /// session with no in-flight turn proves the stop; every other projection
    /// keeps the fence and truthful running state until a later read.
    func reconcileStopTurn(
        _ fence: StopTurnFence,
        note: String,
        resume: @MainActor () async throws -> LiveSession,
        accepts: @MainActor () -> Bool
    ) async {
        guard ChatRuntime.shared.stopFences[fence.botID]?.operationID == fence.operationID else { return }
        do {
            let live = try await resume()
            let sameDurableSession: Bool
            if let storedID = fence.storedID, !storedID.isEmpty {
                sameDurableSession = live.storedSessionID == storedID
            } else {
                sameDurableSession = false
            }
            guard ChatRuntime.shared.stopFences[fence.botID]?.operationID == fence.operationID,
                  (live.sessionID == fence.sessionID || sameDurableSession),
                  (fence.storedID == nil || live.storedSessionID == fence.storedID),
                  (fence.generation < 0 || LiveRuntime.shared.generation >= fence.generation),
                  accepts() else { return }
            // A running projection, or a partial in-flight turn despite
            // `running: false`, is not an idle proof. Keep the fence and the
            // visible running state until both signals agree on idle; only
            // `!running && inflight == nil` may settle the interrupt.
            guard !live.running, !live.hasInflightTurn else {
                if let chat = chats[fence.botID], ObjectIdentifier(chat) == fence.chatID {
                    chat.isRunning = true
                    chat.isTyping = true
                }
                return
            }
            guard let activeFence = ChatRuntime.shared.stopFences[fence.botID],
                  activeFence.operationID == fence.operationID else { return }
            let lease = StopTurnLease(
                botID: fence.botID, route: activeFence.route,
                sessionID: live.sessionID,
                storedID: live.storedSessionID.isEmpty ? activeFence.storedID : live.storedSessionID,
                chatID: activeFence.chatID, id: activeFence.operationID,
                requestStarted: true, generation: activeFence.generation)
            let ownedBeforeCleanup = stopCompletionIsOwned(lease)
            applyStopCompletion(lease, note: note)
            // The authoritative resume/acceptance closure is allowed to be
            // the only live binding proof during the short reconnect window
            // where `gatewayRoute` is not published yet. The exact fence/chat
            // identity still protects against a replacement session; once the
            // projection is !running with no real inflight turn, settle the UI
            // even if the generic receipt cleanup could not resolve a route.
            if !ownedBeforeCleanup,
               let chat = chats[fence.botID], ObjectIdentifier(chat) == fence.chatID,
               (chat.sessionID == live.sessionID || sameDurableSession),
               (fence.storedID == nil || chat.storedSessionID == fence.storedID) {
                clearWatchdog(fence.botID)
                chat.isRunning = false
                chat.isTyping = false
                finishRunningTools(in: chat, interrupted: true)
                chat.messages.append(ChatMessage(author: .system, text: note))
            }
        } catch {
            // Keep the stop fence and truthful running state until a later
            // authoritative read settles the exact session.
        }
    }

    func stopCompletionIsOwned(_ lease: StopTurnLease) -> Bool {
        let active = ChatRuntime.shared.stopActions[lease.botID].flatMap {
            $0.id == lease.id ? $0 : nil
        }
        let target = active ?? lease
        guard let chat = chats[target.botID], ObjectIdentifier(chat) == target.chatID,
              bindingSessionID(for: target.botID) == target.sessionID,
              chat.storedSessionID == target.storedID,
              (target.generation < 0 || LiveRuntime.shared.generation == target.generation),
              bindingRouteMatches(target.route, botID: target.botID) else { return false }
        return true
    }

    func applyStopCompletion(_ lease: StopTurnLease, note: String) {
        // A reconnect may have migrated the side-table action to a fresh
        // runtime sid before this old task received its receipt. Cleanup the
        // durable operation's current address, while still matching by id so
        // a replacement operation cannot be touched by the late response.
        let cleanupLease = ChatRuntime.shared.stopActions[lease.botID].flatMap {
            $0.id == lease.id ? $0 : nil
        } ?? lease
        let owned = stopCompletionIsOwned(cleanupLease)
        let session = GatewaySessionRoute(gatewayID: cleanupLease.route.gatewayID,
                                          sessionID: cleanupLease.sessionID)
        let stale = LiveRuntime.shared.approvalTargets.compactMap { key, target in
            target.session == session && target.bot == cleanupLease.route
                && target.botID == cleanupLease.botID
                && target.storedID == cleanupLease.storedID ? key : nil
        }
        for id in stale { LiveRuntime.shared.approvalTargets[id] = nil }
        for id in stale { ApprovalBridges.shared.details[id] = nil }
        approvals.removeAll { stale.contains($0.id) }
        ApprovalBridges.shared.prompts.removeAll {
            $0.gatewayID == session.gatewayID
            && $0.profile == cleanupLease.route.profile
                && $0.botID == cleanupLease.botID
                && $0.storedID == cleanupLease.storedID
                && $0.sessionID == session.sessionID
        }
        removeQueuedPrompts(QueuedPromptSession(
            botID: cleanupLease.botID, sessionID: cleanupLease.sessionID,
            storedID: cleanupLease.storedID, route: cleanupLease.route))
        recomputeApprovalStatus(for: cleanupLease.botID)
        // The interrupt receipt proves A was stopped even when the visible
        // chat rebound to B while the RPC was in flight. Cleanup above follows
        // the captured gateway/session; only the transcript note follows the
        // still-visible ChatState binding.
        releaseStopTurn(cleanupLease)
        if ChatRuntime.shared.stopFences[cleanupLease.botID]?.operationID == cleanupLease.id {
            ChatRuntime.shared.stopFences[cleanupLease.botID] = nil
        }
        guard owned, let chat = chats[cleanupLease.botID] else { return }
        clearWatchdog(cleanupLease.botID)
        chat.isRunning = false
        chat.isTyping = false
        chat.clearTurnTiming()
        finishRunningTools(in: chat, interrupted: true)
        chat.messages.append(ChatMessage(author: .system, text: note))
    }

    // MARK: - Reactions (message.react)

    /// This device's reaction on a message, for the badge under the bubble.
    public func reaction(for message: ChatMessage) -> String? {
        ChatRuntime.shared.reactions[message.id]
    }

    /// Reactions key on the durable `row_id`. A live bubble has none until it
    /// round-trips a resume, so the newest assistant row can still be named by
    /// role — anything older than that simply can't be addressed yet.
    public func canReact(to message: ChatMessage, in botID: String) -> Bool {
        guard message.author == .bot, !message.isStreaming else { return false }
        guard mode == .live else { return true }
        guard chat(for: botID).sessionID != nil else { return false }
        return message.rowID != nil || isNewestBotMessage(message, in: botID)
    }

    /// Toggle an emoji on a message (same emoji again retracts it, matching the
    /// gateway's Tapback semantics).
    public func react(to message: ChatMessage, in botID: String, emoji: String) {
        let runtime = ChatRuntime.shared
        let retracting = runtime.reactions[message.id] == emoji
        runtime.reactions[message.id] = retracting ? nil : emoji

        guard mode == .live, let sessionID = chat(for: botID).sessionID else { return }
        let rowID = message.rowID
        guard rowID != nil || isNewestBotMessage(message, in: botID) else { return }
        let role: String? = rowID == nil ? "assistant" : nil
        let payload: String? = retracting ? nil : emoji
        Task { @MainActor in
            guard let route = gatewayRoute(for: botID),
                  let client = try? await routedClient(for: route) else { return }
            _ = try? await client.reactToMessage(sessionID: sessionID, rowID: rowID,
                                                 newestRole: role, emoji: payload)
        }
    }

    private func isNewestBotMessage(_ message: ChatMessage, in botID: String) -> Bool {
        chat(for: botID).messages.last(where: { $0.author == .bot })?.id == message.id
    }
}
