import Foundation
import TalariaKit

/// Failed-turn evidence can arrive twice: first on the live terminal frame,
/// then again in `session.resume.inflight` when the socket died around that
/// frame. Keep the evidence on one assistant row and only make it more
/// specific. A contradictory later descriptor is not authority to relabel a
/// failure the user already saw.
enum TurnFailureLifecycle {
    static let maximumMessageScalars = 8_192
    /// Shared with retained-inflight admission so the same oversized failure
    /// has one stable identity across live completion, resume, and Dismiss.
    private static let clippedMarker = "\n… [turn detail clipped]"

    /// Bound work before whitespace trimming or UI storage. Preserve ordinary
    /// multiline diagnostics, but remove terminal/bidi controls that can spoof
    /// card labels or copied details.
    static func admittedMessage(_ value: String?) -> String {
        guard let value else { return "" }
        let markerCount = clippedMarker.unicodeScalars.count
        let contentLimit = maximumMessageScalars - markerCount
        let rawWorkMaximum = maximumMessageScalars * 4
        let raw = value.unicodeScalars.prefix(rawWorkMaximum + 1)
        let rawWasClipped = raw.count > rawWorkMaximum
        var output = String.UnicodeScalarView()
        output.reserveCapacity(maximumMessageScalars + 1)
        var visibleCount = 0
        for scalar in raw.prefix(rawWorkMaximum) {
            if scalar.value == 0x09 || scalar.value == 0x0A {
                output.append(scalar)
                visibleCount += 1
            } else if !isUnsafeControl(scalar.value) {
                output.append(scalar)
                visibleCount += 1
            }
            if visibleCount > maximumMessageScalars { break }
        }
        guard rawWasClipped || visibleCount > maximumMessageScalars else {
            return String(output).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var clipped = String.UnicodeScalarView(output.prefix(contentLimit))
        clipped.append(contentsOf: clippedMarker.unicodeScalars)
        return String(clipped).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isUnsafeControl(_ value: UInt32) -> Bool {
        if value <= 0x1F || (0x7F...0x9F).contains(value) { return true }
        switch value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        default:
            return false
        }
    }

    static func failure(from payload: MessageCompletePayload) -> TurnFailure? {
        let raw = admittedMessage(payload.error)
        let isFailure = payload.status == .error || payload.status == .malformed
        guard isFailure else { return nil }
        let fallback = admittedMessage(payload.text)
        return TurnFailure(
            message: raw.isEmpty ? (fallback.isEmpty ? "Hermes reported an error" : fallback) : raw,
            recoverable: payload.recoverable,
            errorSurface: payload.errorSurface)
    }

    static func failure(from retained: RetainedInflightTurn) -> TurnFailure? {
        let raw = admittedMessage(retained.error)
        let isFailure = retained.status == .error
            || retained.status == .malformed
            || !raw.isEmpty
        guard isFailure else { return nil }
        let fallback = admittedMessage(retained.assistant)
        return TurnFailure(
            message: raw.isEmpty ? (fallback.isEmpty ? "Hermes reported an error" : fallback) : raw,
            recoverable: retained.recoverable ?? false,
            errorSurface: retained.errorSurface)
    }

    static func merge(_ existing: TurnFailure?, _ incoming: TurnFailure?) -> TurnFailure? {
        guard let incoming else { return existing }
        guard let existing else { return incoming }
        return TurnFailure(
            message: existing.message.isEmpty ? incoming.message : existing.message,
            recoverable: existing.recoverable || incoming.recoverable,
            errorSurface: merge(existing.errorSurface, incoming.errorSurface))
    }

    private static func merge(_ existing: TurnErrorSurface?,
                              _ incoming: TurnErrorSurface?) -> TurnErrorSurface? {
        guard let incoming else { return existing }
        guard let existing else { return incoming }
        guard existing.layer == incoming.layer else { return existing }
        let code: String
        if existing.code == "unknown", incoming.code != "unknown" {
            code = incoming.code
        } else if incoming.code == "unknown" || existing.code == incoming.code {
            code = existing.code
        } else {
            return existing
        }
        return TurnErrorSurface(
            layer: existing.layer,
            code: code,
            retryable: existing.retryable && incoming.retryable,
            provider: existing.provider ?? incoming.provider,
            model: existing.model ?? incoming.model)
    }

    static func compatible(existing: ChatMessage, partial: String,
                           failure: TurnFailure?) -> Bool {
        guard existing.author == .bot else { return false }
        let textMatches = existing.text == partial || existing.text.isEmpty || partial.isEmpty
            || existing.text.hasPrefix(partial) || partial.hasPrefix(existing.text)
        guard textMatches else { return false }
        guard let old = existing.failure, let failure else {
            return existing.isStreaming || existing.failure == nil || failure == nil
        }
        return old.message == failure.message
    }
}

// Live-gateway side of AppModel: connect, route events into observable state,
// and back the shared actions with real RPCs. Demo mode never touches this.
//
// Protocol contract: .research/ws-protocol.md / auth-flows.md. Key behaviors:
// - profiles.list is the roster; cosmetics ride ui_meta — desktop Bot Mode's
//   own ui_meta["hermes-bots"] block first, Talaria's ui_meta["talaria"]
//   mirror second, a hash of the profile name only when there is neither
//   (TalariaKit/BotCosmetics.swift).
// - Turn events (message.*/tool.*/session.usage) route by runtime session id.
// - approval.request blocks the agent until approval.respond.
// - On socket loss the server parks live sessions for ~20 s; we reconnect with
//   exponential backoff and session.resume open chats to reattach in-flight
//   state, then flush the offline compose queue.

// MARK: - Live runtime (side table)

/// Book-keeping for the live link. `AppModel`'s stored properties live in
/// AppModel.swift (another owner); extensions cannot add storage, so the
/// runtime rides in a MainActor singleton — Talaria drives one gateway link
/// per process.
@MainActor
final class LiveRuntime {
    static let shared = LiveRuntime()

    /// Runtime session id (8-hex sid) → bot/profile id.
    var sessionToBot: [String: String] = [:]
    /// Secondary sessions require a gateway-qualified key because two Hermes
    /// processes can issue the same short runtime id.
    var routedSessionToBot: [GatewaySessionRoute: String] = [:]
    /// Bots with a turn in flight (drives BotStatus.working).
    var workingBotIDs: Set<String> = []
    /// Opaque approval UI id → independently verified wire destination.
    /// The key is gateway-qualified because two retained Hermes processes may
    /// issue the same request_id at the same time.
    var approvalTargets: [String: ApprovalResponseTarget] = [:]
    /// bot id → durable stored-session key from the roster's freshest
    /// conversation projection (canonical or raw last session, never worker).
    var lastSessionByBot: [String: String] = [:]
    /// Latest gateway-authoritative `(profile, "Bot Chat")` registry summary.
    /// This is a read-only roster projection, never a client pointer: opens
    /// still exact-list the title registry on every tap.
    var canonicalSessionByBot: [String: CanonicalSessionIdentity] = [:]
    /// The gateway's default profile — owner of un-namespaced cron jobs and
    /// approvals we cannot attribute.
    var defaultBotID: String?
    /// In-flight create/resume per bot so a tap + a send never double-create.
    var attachTasks: [String: Task<String, Error>] = [:]
    /// Runtime sid captured immediately before a reconnect parks the primary
    /// chats. The visible ChatState may be cleared while the transport is
    /// replaced, but mutation leases still need this old sid as their binding
    /// proof when the durable session adopts its new sid.
    var reconnectParkedSessionIDs: [String: String] = [:]
    /// Normalized base URL of the connected gateway (mirror of the client's,
    /// readable without hopping onto its actor).
    var baseURL: URL?
    /// Saved-connection id of the primary client. Secondary clients use the
    /// same id key in `GatewayClientPool`.
    var gatewayID: String?

    /// Bumped on every (re)connect + teardown; stale monitors check it.
    var generation = 0
    /// Exact primary transition currently permitted to publish after a
    /// connection/adoption suspension. Generation alone cannot distinguish
    /// two overlapping attempts that share a normalized endpoint.
    var connectionAttemptToken: UUID?
    var eventPump: Task<Void, Never>?
    var monitorTask: Task<Void, Never>?
    var reconnectTask: Task<Void, Never>?

    func resetSessionState() {
        sessionToBot.removeAll()
        for task in ChatRuntime.shared.reconciliationTasks.values { task.cancel() }
        ChatRuntime.shared.reconciliationTasks.removeAll()
        ChatRuntime.shared.reconciliationTokens.removeAll()
        ChatRuntime.shared.reconcilingBots.removeAll()
        ChatRuntime.shared.deferredReconciliationBots.removeAll()
        // Primary reconnects must not erase sessions that are still attached
        // through retained secondary clients.
        workingBotIDs = Set(workingBotIDs.filter { GatewayBotRoute(qualifiedID: $0) != nil })
        if let gatewayID {
            approvalTargets = approvalTargets.filter { $0.value.bot.gatewayID != gatewayID }
        } else {
            approvalTargets.removeAll()
        }
        let primaryTasks = attachTasks.filter { GatewayBotRoute(qualifiedID: $0.key) == nil }
        for task in primaryTasks.values { task.cancel() }
        for key in primaryTasks.keys { attachTasks.removeValue(forKey: key) }
        canonicalSessionByBot = canonicalSessionByBot.filter {
            GatewayBotRoute(qualifiedID: $0.key) != nil
        }
    }

    func resetRoutedState(gatewayID: String) {
        routedSessionToBot = routedSessionToBot.filter { $0.key.gatewayID != gatewayID }
        approvalTargets = approvalTargets.filter { $0.value.bot.gatewayID != gatewayID }
        ChatRuntime.shared.clearPendingStops(forGatewayID: gatewayID)
        let prefix = gatewayID + GatewayBotRoute.separator
        workingBotIDs = Set(workingBotIDs.filter { !$0.hasPrefix(prefix) })
        let tasks = attachTasks.filter { $0.key.hasPrefix(prefix) }
        for task in tasks.values { task.cancel() }
        for key in tasks.keys { attachTasks.removeValue(forKey: key) }
        canonicalSessionByBot = canonicalSessionByBot.filter { !$0.key.hasPrefix(prefix) }
    }
}

/// MainActor proof carried through the complete primary dial/adoption
/// transaction. Every field must still match before post-await publication.
struct PrimaryConnectionAttemptAuthority {
    let generation: Int
    let baseURL: URL
    let client: GatewayClient
    let token: UUID
}

/// Focused suspension seams for the post-dial adoption transaction. Production
/// installs the real operations; tests can suspend an exact boundary without
/// opening a socket or changing unrelated lifecycle code.
struct ConnectedGatewayAdoptionOperations {
    var adopt: (GatewayClient, String) async throws -> GatewayClientPool.ConnectionSnapshot
    var refreshRoster: () async throws -> Void
    var refreshRoutines: () async -> Void
    var hideOwnedSessions: () async -> Void
    var flushComposeQueue: () async -> Void
    var reseedRoomProjection: (String) async -> Void
}

struct CanonicalSessionIdentity: Equatable, Sendable {
    var id: String
    var resolvedID: String?

    init(id: String, resolvedID: String? = nil) {
        self.id = id
        self.resolvedID = resolvedID
    }

    init(_ summary: HermesProfile.ProfileSessionRef) {
        self.init(id: summary.id, resolvedID: summary.resolvedID)
    }
}

/// The independently verified destination for an approval response. Keeping
/// both identities together prevents a card attributed to one gateway from
/// borrowing a colliding runtime session id owned by another.
struct ApprovalResponseTarget: Equatable {
    var bot: GatewayBotRoute
    var session: GatewaySessionRoute
    var requestID: String
    var storedID: String? = nil
    var botID: String? = nil
}

extension LiveSession {
    /// Hermes may encode an absent partial-turn block as JSON `null`. Treat
    /// that shape exactly like a missing block at every lifecycle boundary;
    /// a non-nil `.null` must not keep an idle stop fenced or the UI running.
    var hasInflightTurn: Bool {
        guard let inflight else { return false }
        return inflight != .null
    }
}

extension AppModel {

    // MARK: - Connection

    /// Connect to a gateway from a user-entered URL string. Normalizes like
    /// desktop's connection-config, then connects.
    public func connectGateway(urlString: String, credential: GatewayCredential) async throws {
        guard let base = GatewayURL.normalize(urlString) else {
            throw AuthError.protocolError("not a gateway URL")
        }
        try await connectGateway(baseURL: base, credential: credential)
    }

    /// Connect to a gateway and become live. Credential comes from the
    /// onboarding auth flow (AuthController) or the Keychain. Registers the
    /// gateway in the ConnectionRegistry and starts the disconnect monitor.
    public func connectGateway(baseURL: URL, credential: GatewayCredential) async throws {
        let registry = ConnectionRegistry.shared
        try await connectGateway(
            baseURL: baseURL,
            credential: credential,
            connectionOperation: { try await $0.connect() },
            adoptionOperations: ConnectedGatewayAdoptionOperations(
                adopt: { client, gatewayID in
                    try await registry.clientPool.adoptWithGeneration(client, for: gatewayID)
                },
                refreshRoster: { try await self.refreshRoster() },
                refreshRoutines: { await self.refreshRoutinesLive(force: true) },
                hideOwnedSessions: { await self.hideOwnedBotSessions() },
                flushComposeQueue: { await self.flushComposeQueue() },
                reseedRoomProjection: { gatewayID in
                    await self.pullAndReseedRoomProjection(gatewayID: gatewayID)
                }
            )
        )
    }

    /// Deterministic focused seam preserving the production transition order.
    func connectGateway(
        baseURL: URL,
        credential: GatewayCredential,
        connectionOperation: (GatewayClient) async throws -> Void,
        adoptionOperations: ConnectedGatewayAdoptionOperations
    ) async throws {
        invalidateManagedCloudBootEpisodeUnlessOwnedByCurrentTask(sourceURL: baseURL)
        let runtime = LiveRuntime.shared

        // Tear down any previous link.
        // A user-initiated gateway switch must not carry parked runtime ids
        // from the departed source. Supervised reconnect sets this flag before
        // calling here, so its explicit old-sid migration survives the reset.
        if !ConnectionSupervisor.shared.isReconnecting {
            runtime.reconnectParkedSessionIDs.removeAll()
        }
        let departingGatewayID = runtime.gatewayID
        let departingPrimaryBots = Set(chats.keys.filter {
            stateRoute(for: $0)?.gatewayID == departingGatewayID
                || (GatewayBotRoute(qualifiedID: $0)?.gatewayID == departingGatewayID)
        })
        if !ConnectionSupervisor.shared.isReconnecting, let departingGatewayID {
            ChatRuntime.shared.clearPendingStops(forGatewayID: departingGatewayID)
            ChatRuntime.shared.retirePrimaryMutationState(
                gatewayID: departingGatewayID, botIDs: departingPrimaryBots)
            reconcileComposeQueueIDs(sources: departingPrimaryBots, destination: nil)
        }
        runtime.generation += 1
        let transitionGeneration = runtime.generation
        let transitionToken = UUID()
        runtime.connectionAttemptToken = transitionToken
        defer {
            if runtime.generation == transitionGeneration,
               runtime.connectionAttemptToken == transitionToken {
                runtime.connectionAttemptToken = nil
            }
        }
        runtime.reconnectTask?.cancel(); runtime.reconnectTask = nil
        runtime.monitorTask?.cancel(); runtime.monitorTask = nil
        runtime.eventPump?.cancel(); runtime.eventPump = nil
        if let gatewayID = runtime.gatewayID { dropApprovalScope(gatewayID: gatewayID) }
        runtime.resetSessionState()
        for botID in departingPrimaryBots {
            if let idx = bots.firstIndex(where: { $0.id == botID }) {
                bots[idx].task = nil
                bots[idx].status = .idle
            }
            chats[botID]?.isTyping = false
            chats[botID]?.isRunning = false
            LiveActivityController.shared.endAllOperationalWork(botID: botID)
        }
        // Canonical summaries are source-scoped and were dropped above. The
        // next roster/open resolves the exact title registry again.
        CanonicalChatRuntime.shared.resetPrimaryScope(
            retainAmbiguousForReconnect: ConnectionSupervisor.shared.isReconnecting,
            retainLocalPins: ConnectionSupervisor.shared.isReconnecting)
        // Switching gateways reaches here WITHOUT going through
        // disconnectGateway (switchGateway calls connectGateway directly), so
        // the per-gateway caches have to be dropped on both paths. Done before
        // the old socket closes, so the pairing watch can still surrender its
        // handler to the client that owns it.
        dropPerGatewayCaches()
        let registry = ConnectionRegistry.shared
        if let oldGatewayID = runtime.gatewayID {
            await registry.clientPool.disconnect(gatewayID: oldGatewayID)
            try requireCurrentConnectionTransition(
                generation: transitionGeneration, token: transitionToken)
        } else if let old = client {
            await old.disconnect()
            try requireCurrentConnectionTransition(
                generation: transitionGeneration, token: transitionToken)
        }
        try requireCurrentConnectionTransition(
            generation: transitionGeneration, token: transitionToken)
        runtime.gatewayID = nil

        let client = GatewayClient(baseURL: baseURL, credential: credential)
        self.client = client
        runtime.baseURL = baseURL
        let authority = PrimaryConnectionAttemptAuthority(
            generation: transitionGeneration, baseURL: baseURL,
            client: client, token: transitionToken)
        // Events fan out of the client on its own actor; funnel them through
        // one AsyncStream so MainActor delivery preserves wire order (deltas
        // arrive in ~30 fps bursts and must append in order).
        let (stream, continuation) = AsyncStream.makeStream(of: GatewayEvent.self)
        _ = await client.addEventHandler { continuation.yield($0) }
        guard isCurrentConnectionAttempt(authority), !Task.isCancelled else {
            continuation.finish()
            await disconnectCapturedClientIfUnowned(authority)
            throw CancellationError()
        }
        runtime.eventPump = Task { @MainActor [weak self] in
            for await event in stream { self?.handle(event: event) }
        }

        do {
            try await connectionOperation(client)
        } catch {
            guard isCurrentConnectionAttempt(authority), !Task.isCancelled else {
                continuation.finish()
                await disconnectCapturedClientIfUnowned(authority)
                throw CancellationError()
            }
            throw error
        }
        guard isCurrentConnectionAttempt(authority), !Task.isCancelled else {
            continuation.finish()
            await disconnectCapturedClientIfUnowned(authority)
            throw CancellationError()
        }
        // Entering the real world: the canned demo content must not survive
        // next to live data.
        if demoDataLoaded { flushDemoWorld() }
        mode = .live
        isOffline = false

        do {
            try await finishConnectedGatewayAdoption(
                client, baseURL: baseURL, credential: credential,
                authority: authority, operations: adoptionOperations)
        } catch is CancellationError {
            continuation.finish()
            await disconnectCapturedClientIfUnowned(authority)
            throw CancellationError()
        }
    }

    /// Publish an authenticated post-dial client, then perform ancillary world
    /// refreshes. Exact-route recovery is signalled at the publication boundary:
    /// a later profiles.list timeout must not strand a retained notification or
    /// URL until some unrelated lifecycle event happens to nudge it again.
    ///
    /// `rosterRefresh` is the real refresh in production and a focused failure
    /// injection in the ordering regression; source readiness itself is never
    /// overridden by that test.
    func finishConnectedGatewayAdoption(
        _ client: GatewayClient,
        baseURL: URL,
        credential: GatewayCredential,
        rosterRefresh: @escaping () async throws -> Void
    ) async throws {
        let runtime = LiveRuntime.shared
        let authority = PrimaryConnectionAttemptAuthority(
            generation: runtime.generation, baseURL: baseURL,
            client: client, token: UUID())
        runtime.connectionAttemptToken = authority.token
        defer {
            if runtime.generation == authority.generation,
               runtime.connectionAttemptToken == authority.token {
                runtime.connectionAttemptToken = nil
            }
        }
        let registry = ConnectionRegistry.shared
        try await finishConnectedGatewayAdoption(
            client, baseURL: baseURL, credential: credential,
            authority: authority,
            operations: ConnectedGatewayAdoptionOperations(
                adopt: { client, gatewayID in
                    try await registry.clientPool.adoptWithGeneration(client, for: gatewayID)
                },
                refreshRoster: rosterRefresh,
                refreshRoutines: { await self.refreshRoutinesLive(force: true) },
                hideOwnedSessions: { await self.hideOwnedBotSessions() },
                flushComposeQueue: { await self.flushComposeQueue() },
                reseedRoomProjection: { gatewayID in
                    await self.pullAndReseedRoomProjection(gatewayID: gatewayID)
                }
            )
        )
    }

    private func finishConnectedGatewayAdoption(
        _ client: GatewayClient,
        baseURL: URL,
        credential: GatewayCredential,
        authority: PrimaryConnectionAttemptAuthority,
        operations: ConnectedGatewayAdoptionOperations
    ) async throws {
        let runtime = LiveRuntime.shared
        let registry = ConnectionRegistry.shared
        try requireCurrentConnectionAttempt(authority)
        guard let savedGateway = registry.upsert(urlString: baseURL.absoluteString,
                                                 credential: credential) else {
            if isCurrentConnectionAttempt(authority) {
                await client.disconnect()
                if isCurrentConnectionAttempt(authority) {
                    self.client = nil
                    runtime.baseURL = nil
                    runtime.connectionAttemptToken = nil
                }
            }
            throw AuthError.protocolError("connected gateway could not be registered")
        }
        try requireCurrentConnectionAttempt(authority)
        let poolSnapshot: GatewayClientPool.ConnectionSnapshot
        do {
            poolSnapshot = try await operations.adopt(client, savedGateway.id)
        } catch {
            guard isCurrentConnectionAttempt(authority) else { throw CancellationError() }
            throw error
        }
        guard isCurrentConnectionAttempt(authority) else {
            _ = await registry.clientPool.disconnectIfCurrent(
                poolSnapshot, for: savedGateway.id)
            throw CancellationError()
        }
        runtime.gatewayID = savedGateway.id

        // Source, credential and pooled-client authority are all installed now.
        // Signal before profiles.list or any other ancillary refresh can fail.
        retryExactStoredSessionNavigation()
        registry.noteState(.connected, forURL: baseURL)

        #if os(iOS)
        // Hand the APNs token to this gateway's push relay (if installed).
        PushCoordinator.shared.registerWithRelayIfConnected()
        #endif

        try await performConnectionAttempt(
            authority, poolSnapshot: poolSnapshot, gatewayID: savedGateway.id,
            operation: operations.refreshRoster)
        try requireCurrentConnectionAttempt(authority)
        await operations.refreshRoutines()
        try await requireCurrentConnectionAttempt(
            authority, poolSnapshot: poolSnapshot, gatewayID: savedGateway.id)
        connections = registry.rows
        try requireCurrentConnectionAttempt(authority)
        await operations.hideOwnedSessions()
        try await requireCurrentConnectionAttempt(
            authority, poolSnapshot: poolSnapshot, gatewayID: savedGateway.id)
        await operations.flushComposeQueue()
        try await requireCurrentConnectionAttempt(
            authority, poolSnapshot: poolSnapshot, gatewayID: savedGateway.id)
        await operations.reseedRoomProjection(savedGateway.id)
        try await requireCurrentConnectionAttempt(
            authority, poolSnapshot: poolSnapshot, gatewayID: savedGateway.id)
        // Arm socket-loss recovery only after the initial adoption transaction
        // can no longer resume and CAS-remove this same pooled client.
        startSupervisedMonitor(for: client, generation: authority.generation)
    }

    private func isCurrentConnectionAttempt(_ authority: PrimaryConnectionAttemptAuthority) -> Bool {
        let runtime = LiveRuntime.shared
        return runtime.generation == authority.generation
            && runtime.baseURL == authority.baseURL
            && runtime.connectionAttemptToken == authority.token
            && client.map(ObjectIdentifier.init) == ObjectIdentifier(authority.client)
    }

    private func requireCurrentConnectionTransition(generation: Int, token: UUID) throws {
        let runtime = LiveRuntime.shared
        guard !Task.isCancelled, runtime.generation == generation,
              runtime.connectionAttemptToken == token else {
            throw CancellationError()
        }
    }

    private func disconnectCapturedClientIfUnowned(
        _ authority: PrimaryConnectionAttemptAuthority
    ) async {
        guard client.map(ObjectIdentifier.init) != ObjectIdentifier(authority.client) else {
            return
        }
        await authority.client.disconnect()
    }

    private func requireCurrentConnectionAttempt(
        _ authority: PrimaryConnectionAttemptAuthority
    ) throws {
        guard !Task.isCancelled, isCurrentConnectionAttempt(authority) else {
            throw CancellationError()
        }
    }

    private func requireCurrentConnectionAttempt(
        _ authority: PrimaryConnectionAttemptAuthority,
        poolSnapshot: GatewayClientPool.ConnectionSnapshot,
        gatewayID: String
    ) async throws {
        guard !Task.isCancelled, isCurrentConnectionAttempt(authority) else {
            _ = await ConnectionRegistry.shared.clientPool.disconnectIfCurrent(
                poolSnapshot, for: gatewayID)
            throw CancellationError()
        }
    }

    private func performConnectionAttempt(
        _ authority: PrimaryConnectionAttemptAuthority,
        poolSnapshot: GatewayClientPool.ConnectionSnapshot,
        gatewayID: String,
        operation: () async throws -> Void
    ) async throws {
        try requireCurrentConnectionAttempt(authority)
        do {
            try await operation()
        } catch {
            guard !Task.isCancelled, isCurrentConnectionAttempt(authority) else {
                _ = await ConnectionRegistry.shared.clientPool.disconnectIfCurrent(
                    poolSnapshot, for: gatewayID)
                throw CancellationError()
            }
            throw error
        }
        try await requireCurrentConnectionAttempt(
            authority, poolSnapshot: poolSnapshot, gatewayID: gatewayID)
    }

    /// Deliberate disconnect (Settings → Connections). No reconnect follows.
    public func disconnectGateway() async {
        let runtime = LiveRuntime.shared
        let departingGatewayID = runtime.gatewayID
        invalidateManagedCloudBootEpisode(gatewayID: departingGatewayID)
        let departingPrimaryBots = Set(chats.keys.filter {
            stateRoute(for: $0)?.gatewayID == departingGatewayID
                || (GatewayBotRoute(qualifiedID: $0)?.gatewayID == departingGatewayID)
        })
        runtime.generation += 1
        runtime.connectionAttemptToken = nil
        runtime.reconnectTask?.cancel(); runtime.reconnectTask = nil
        runtime.monitorTask?.cancel(); runtime.monitorTask = nil
        runtime.eventPump?.cancel(); runtime.eventPump = nil
        if let departingGatewayID { cancelRoomProjectionSync(gatewayID: departingGatewayID) }
        if let gatewayID = departingGatewayID { dropApprovalScope(gatewayID: gatewayID) }
        if let departingGatewayID,
           !ConnectionSupervisor.shared.isReconnecting {
            ChatRuntime.shared.clearPendingStops(forGatewayID: departingGatewayID)
            ChatRuntime.shared.retirePrimaryMutationState(
                gatewayID: departingGatewayID, botIDs: departingPrimaryBots)
        }
        runtime.resetSessionState()
        for botID in departingPrimaryBots {
            if let idx = bots.firstIndex(where: { $0.id == botID }) {
                bots[idx].task = nil
                bots[idx].status = .idle
            }
            chats[botID]?.isTyping = false
            chats[botID]?.isRunning = false
            LiveActivityController.shared.endAllOperationalWork(botID: botID)
        }
        // Teardown while both the captured source id and its client still
        // exist. Clearing either first makes A2A mistake a deliberate primary
        // disconnect for an unknown-source reset and cancel retained remotes.
        dropPerGatewayCaches(gatewayID: departingGatewayID)
        if let gatewayID = departingGatewayID {
            await ConnectionRegistry.shared.clientPool.disconnect(gatewayID: gatewayID)
        } else if let client {
            await client.disconnect()
        }
        if let base = runtime.baseURL {
            ConnectionRegistry.shared.noteState(.offline, forURL: base)
        }
        runtime.baseURL = nil
        runtime.gatewayID = nil
        if !ConnectionSupervisor.shared.isReconnecting {
            runtime.reconnectParkedSessionIDs.removeAll()
        }
        client = nil
        isOffline = false
        // Each area's router owns state belonging to *that* gateway. Without
        // this they survive the disconnect: cached session titles from a store
        // that is gone, and — the visible one — a parked clarify/sudo/secret
        // prompt left modal over an empty world with no socket to answer on.
        // The attach* calls all early-return once `client` is nil, so this is
        // the only chance to tear them down.
        detachApprovalBridges()
        detachSessionEventRouter()
        detachVoiceRouter()
        // The liveness watches are not event subscriptions but they have the
        // same lifetime: a reaper polling `session.active_list`, a foreground
        // observer and an NWPathMonitor all outlive this call otherwise, and
        // every conclusion they draw is scoped to the gateway that just left.
        stopLivenessSupervision()
        // Cancel source-owned canonical birth work; canonical identity itself
        // is re-read from the next gateway's exact title registry.
        CanonicalChatRuntime.shared.resetPrimaryScope(
            retainAmbiguousForReconnect: ConnectionSupervisor.shared.isReconnecting,
            retainLocalPins: ConnectionSupervisor.shared.isReconnecting)
        // ~11 MB of decoded spritesheets and a per-profile pet cache belong to
        // the gateway that served them, not to the next one.
        detachPetEventRouter()
        // Same rule for the About panel's facts: `desktop_contract`, the health
        // probe and the runtime model all describe THIS gateway. Left standing,
        // the next gateway's About page would report the departed one's
        // contract version — which is precisely the number a client uses to
        // decide which RPC shapes it may send.
        detachSettingsDiagnostics()
        connections = ConnectionRegistry.shared.rows
    }

    /// Everything Phase 3 caches per gateway, dropped in one place because two
    /// paths end a link: `disconnectGateway()` (sign out, Connections →
    /// disconnect) and `connectGateway()` (a switch, which never disconnects
    /// first). A cache that only one of them clears is a cache that survives
    /// half the time — which is worse than one that never clears, because the
    /// bug only reproduces on one route.
    private func dropPerGatewayCaches() {
        dropPerGatewayCaches(gatewayID: LiveRuntime.shared.gatewayID)
    }

    private func dropPerGatewayCaches(gatewayID: String?) {
        // Command Center is source-qualified state, but it outlives the sheet
        // and therefore cannot rely on view disappearance to notice a real
        // socket teardown. Invalidate Operator reads even when the selected
        // source is a retained secondary; late status replies must not paint
        // over a new connection generation.
        OperatorSettingsRuntime.shared.invalidateConnectionScope()
        if let gatewayID {
            dropWorkspaceScope(gatewayID: gatewayID)
        } else if let workspaceGatewayID = WorkspaceRuntime.shared.gatewayID {
            // A partially-installed/launch-time client can have no primary id
            // while WorkspaceRuntime still owns a source. Clear that exact
            // scope rather than leaving its controls and backup ShareLink live.
            dropWorkspaceScope(gatewayID: workspaceGatewayID)
        }
        if let gatewayID {
            // Skills/MCP/plugin state carries profile names that are only
            // meaningful inside this gateway. Keep foreign-source states, but
            // never let the departing primary survive a role switch.
            dropCapabilityScope(gatewayID: gatewayID)
            dropModelScope(gatewayID: gatewayID)
            dropApprovalPolicyScope(gatewayID: gatewayID)
        }
        // Cron detail: the `cron.changed` subscription, per-job records, run
        // histories, and the "this gateway has no cron REST router" verdict —
        // the last of which decides whether editing and history exist at all.
        detachCronDetailRouter()
        // Artifacts are source-qualified. Drop only this gateway's cards,
        // refs and cached bodies; remotes stay exactly as inbox remotes do.
        if let gatewayID {
            dropArtifactScope(gatewayID: gatewayID)
        }
        // Agent-to-agent: surrender the departing primary's subscription,
        // source-qualified refs and captured-client watches. Secondary watches
        // remain retained; the explicit gateway id prevents a cleared runtime
        // from being mistaken for permission to reset every source.
        detachA2ARouter(departingGatewayID: gatewayID)
        // A toast is the app answering a mutation aimed at THIS gateway. Left
        // standing across a switch, "Duplicating inbox…" hangs over a roster
        // that never had an `inbox`, and its ledger row would settle into the
        // next gateway's journal when the answer finally arrives.
        clearToasts()
    }

    /// Probe every saved gateway and sync the Connections rows.
    public func refreshConnections() async {
        await ConnectionRegistry.shared.probeAll()
        if mode == .live { connections = ConnectionRegistry.shared.rows }
    }

    // MARK: - Roster (profiles.list → bots)

    /// Ask the gateway for the roster and fold the answer in.
    public func refreshRoster() async throws {
        guard let client else { return }
        let capturedClient = client
        let capturedGeneration = LiveRuntime.shared.generation
        let capturedGatewayID = LiveRuntime.shared.gatewayID
        let profiles = try await capturedClient.listProfiles()
        guard LiveRuntime.shared.generation == capturedGeneration,
              LiveRuntime.shared.gatewayID == capturedGatewayID,
              self.client.map(ObjectIdentifier.init) == ObjectIdentifier(capturedClient)
        else { return }
        applyRosterAnswer(profiles)
    }

    /// THE roster builder. Every path holding a `profiles.list` answer — the
    /// connect-time refresh, the 10 s signals poll, a create/duplicate/delete,
    /// a `sessions.changed` event — folds it in here, and nothing else writes a
    /// row's cosmetics, its ranking signal or its timestamp.
    ///
    /// It is one function because it used to be two, and the split WAS the bug.
    /// This map owned cosmetics and ignored `has_avatar`; `RosterSignals.ingest`
    /// owned recency, liveness and `has_avatar` and ignored cosmetics. A cold
    /// launch ran only the first (the poll's opening tick bails until the socket
    /// lands), the poll's second tick then ran only the second, and the roster
    /// visibly changed identity between them: avatars swapped to the gateway's
    /// stored rasters, timestamps flipped absolute → relative, the rows
    /// reordered and an Active Now rail appeared, all on one tick about eight
    /// seconds in. One answer in, one roster out, one instant.
    func applyRosterAnswer(_ profiles: [HermesProfile]) {
        let runtime = LiveRuntime.shared
        runtime.defaultBotID = profiles.first(where: \.isDefault)?.name ?? profiles.first?.name

        // Scoped to this gateway BEFORE the fold, with no await in between.
        // `rescope` clears every table when the gateway changes, and the roster
        // screen arms its poll with a rescope of its own — so an answer folded
        // in while the scope was still unset would be wiped moments later by
        // that arming call, leaving the rows with no recency, no liveness and
        // no `has_avatar` until the next poll landed. Which is the same flip
        // this whole path exists to prevent, one layer down.
        RosterSignals.shared.rescope(to: runtime.baseURL)
        // Ranking, the 90 s liveness window and `has_avatar`, taken from the
        // SAME answer the map below reads — not from a second call landing
        // seconds later.
        RosterSignals.shared.ingest(profiles)
        let rosterNames = Set(profiles.map(\.name))
        runtime.canonicalSessionByBot = runtime.canonicalSessionByBot.filter {
            GatewayBotRoute(qualifiedID: $0.key) != nil || rosterNames.contains($0.key)
        }
        // …and the unread diff off the stamps that ingest just restated. It runs
        // HERE, synchronously between the fold and the rows, rather than from an
        // observer on `lastActive`: an observer's MainActor hop lands the badge
        // write either side of `bots` being rebuilt purely by run-loop ordering,
        // which is a race that has to be insured against instead of avoided.
        let moved = unreadMoves(scope: runtime.baseURL)
        // A bot with a cosmetics write in flight keeps the look the user just
        // picked: this answer was composed before that write, and reading it as
        // authority would flip the row back under their thumb.
        let writing = RosterSignals.shared.writing

        bots = profiles.map { profile in
            // Preview identity and activity identity are deliberately distinct
            // upstream. The resolved canonical session is what a row click
            // opens and therefore what its text previews; recency/unread use
            // whichever of canonical and visible last_session is fresher.
            // worker_session participates in neither durable identity.
            let previewSession = profile.previewSession
            let activitySession = profile.freshestConversationSession
            switch profile.canonicalSession {
            case .resolved(let canonical):
                runtime.canonicalSessionByBot[profile.name] = CanonicalSessionIdentity(canonical)
            case .gone:
                runtime.canonicalSessionByBot[profile.name] = nil
            case .notRequested, .invalid:
                // Omitted compatibility answers and malformed current answers
                // are both inconclusive. Preserve the last authoritative
                // durable/resolved identity so a transient roster downgrade
                // cannot disable the forever-chat guard or adopt recency.
                break
            }
            if let id = activitySession?.id, !id.isEmpty {
                runtime.lastSessionByBot[profile.name] = id
            } else {
                runtime.lastSessionByBot[profile.name] = nil
            }
            let existing = bots.first { $0.id == profile.name }
            // Desktop Bot Mode's own metadata block wins over Talaria's, so a
            // bot titled/recolored on desktop reads identically here. The
            // precedence — desktop's block, then Talaria's mirror, then a hash
            // of the name as a last resort — lives in one place for the whole
            // app (TalariaKit/BotCosmetics.swift).
            let deskMeta = BotModeMeta(uiMeta: profile.uiMeta)
            // `stripPreviewMarkdown` (plugin.js:2991-3007): without it a bot
            // that answers with a bulleted list puts literal asterisks in the
            // roster. Folded in here because the 10 s poll used to do it in a
            // second pass of its own, and a row's text and its face must land
            // on the same tick.
            let fresh = (previewSession?.preview).map(Self.flattenPreview) ?? ""
            let hasAuthoritativePreferredPreview: Bool
            if case .resolved = profile.canonicalSession {
                hasAuthoritativePreferredPreview = true
            } else {
                hasAuthoritativePreferredPreview = false
            }
            let rowPreview = fresh.isEmpty
                ? (hasAuthoritativePreferredPreview
                    ? "Ready when you are."
                    : (existing?.preview ?? "Ready when you are."))
                : fresh
            let routedUnread = takeRoutedUnreadForPrimary(profile: profile.name)
            var bot = Bot(
                id: profile.name,
                job: profile.description ?? "",
                shape: BotCosmetics.shape(for: profile),
                hue: BotCosmetics.hue(for: profile),
                status: .idle,
                task: existing?.task,
                minutesElapsed: existing?.minutesElapsed ?? 0,
                preview: rowPreview,
                previewTime: Self.shortTime(activitySession?.lastActive),
                unread: max(existing?.unread ?? 0, routedUnread),
                mentionsYou: existing?.mentionsYou ?? false,
                description: profile.description,
                pinnedModel: profile.model,
                title: deskMeta?.title,
                rawDisplayName: profile.displayName)
            // A look whose write is still in flight keeps the value the user
            // just picked — this answer was composed before it.
            if let existing, writing.contains(profile.name) {
                bot.shape = existing.shape
                bot.hue = existing.hue
                bot.title = existing.title
            }
            if approvals.contains(where: { $0.botID == bot.id }) { bot.status = .approval }
            if runtime.workingBotIDs.contains(bot.id) { bot.status = .working }
            return bot
        }

        applyUnreadWatermark(moved)
        // `has_avatar` drives the FETCH and only the fetch — never which face a
        // row draws. Desktop reads the same flag the same way, walking the whole
        // roster fire-and-forget (`pullServerAvatars`, plugin.js:397-409), which
        // is also what keeps a shape-only roster at zero `profiles.get_asset`
        // calls instead of one per row.
        for profile in profiles where profile.hasAvatar
            && !ProfileAssetStore.shared.isResolved(profile.name) {
            Task { await self.refreshAvatar(botID: profile.name) }
        }

        if let base = runtime.baseURL {
            ConnectionRegistry.shared.noteBotCount(bots.count, forURL: base)
            connections = ConnectionRegistry.shared.rows
        }
    }

    /// Deterministic across launches (String.hashValue is seeded per-process).
    /// The roster's own use of it lives in `BotCosmetics`; this stays as the
    /// spelling the feed dedupe keys and the row-sway offsets already use.
    static func stableHash(_ s: String) -> Int { BotCosmetics.stableHash(s) }

    static func shortTime(_ unix: Double?) -> String {
        guard let unix, unix > 0 else { return "" }
        let date = Date(timeIntervalSince1970: unix)
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE"
        return f.string(from: date)
    }

    // MARK: - Opening a chat (canonical forever-chat + hydration)

    /// Navigate into a bot's chat. THE entry point: every route into a bot —
    /// roster row, deep link, notification tap, search result, activity row,
    /// banner — goes through here, because this is what resumes the bot's
    /// conversation instead of leaving the chat empty and letting the first
    /// send fork a brand-new session.
    ///
    /// Live mode lands in the bot's canonical forever-chat, resolved in
    /// AppModelLive+CanonicalChat.swift (plugin.js:2802-2896). Never "the most
    /// recent session": a cron delivery or a CLI run would otherwise hijack
    /// what a tap opens.
    public func openChat(botID: String) {
        // Some routes in carry a @handle rather than a profile id — an A2A
        // attribution prefix names the sender `@hermes`, and a deep link or
        // push payload can quote whatever the desktop displayed. Every
        // gateway call below wants the profile id, so resolve once, here, at
        // the single entry point (Components/BotIdentity.swift).
        let botID = resolvedBotID(botID)
        openBotID = botID
        selectedTab = .home
        clearUnread(for: botID)
        // The durable mark has to move with the badge, or the next roster poll
        // finds activity this app already counted from the event stream and
        // raises the dot again on a chat the user is reading
        // (AppModelLive+Unread.swift).
        noteChatOpened(botID)
        guard mode == .live,
              !isOffline || GatewayBotRoute(qualifiedID: botID) != nil else { return }
        Task { @MainActor in await self.enterCanonicalChat(botID: botID) }
    }

    /// Create-or-resume the bot's session and bind it to the chat. Coalesces
    /// concurrent callers (openChat racing a send) onto one attach.
    ///
    /// The resolution itself lives in `attachCanonicalSession`: an explicit
    /// binding wins, otherwise the canonical chat. That is what keeps a send
    /// typed before the chat finished opening out of a fresh forked session.
    func ensureSession(botID: String, hydrate: Bool) async throws -> String {
        let runtime = LiveRuntime.shared
        if let sid = chat(for: botID).sessionID { return sid }
        if let pending = runtime.attachTasks[botID] { return try await pending.value }
        guard let route = gatewayRoute(for: botID) else { throw GatewayRouteError.noRoute }

        let task = Task<String, Error> { @MainActor in
            let client = try await self.routedClient(for: route)
            await self.attachRoutedEventsIfNeeded(client: client, gatewayID: route.gatewayID)
            return try await self.attachCanonicalSession(botID: botID, route: route,
                                                         client: client, hydrate: hydrate)
        }
        runtime.attachTasks[botID] = task
        // Clear only OUR entry. `openStoredSession` cancels the in-flight
        // attach and drops the slot, so by the time this frame resumes the
        // slot may already hold a newer task; blanking it unconditionally
        // un-coalesces that one, and two concurrent resolutions of the same
        // bot can mint two canonical chats — the fork this phase exists to
        // prevent. Task is Equatable, so identity is exact.
        defer { if runtime.attachTasks[botID] == task { runtime.attachTasks[botID] = nil } }
        return try await task.value
    }

    func bindSession(_ live: LiveSession, botID: String, sourceGatewayID: String? = nil) {
        let chat = chat(for: botID)
        let runtime = LiveRuntime.shared
        // Some legacy resume callers clear the visible sid before they reach
        // this helper. Keep the parked sid as an explicit old binding so the
        // same durable operation leases migrate instead of being silently
        // orphaned by the nil gap.
        let oldSessionID = chat.sessionID ?? runtime.reconnectParkedSessionIDs[botID]
        let oldStoredID = chat.storedSessionID
        let oldRoute = gatewayRoute(for: botID) ?? stateRoute(for: botID)
        let newStoredID = live.storedSessionID.isEmpty ? nil : live.storedSessionID
        let durableID = newStoredID ?? chat.storedSessionID
        let gatewayID = sourceGatewayID ?? gatewayRoute(for: botID)?.gatewayID
            ?? runtime.gatewayID
        let bindingRoute = gatewayID.map { gatewayID in
            gatewayRoute(for: botID).flatMap { existing in
                existing.gatewayID == gatewayID ? existing : nil
            } ?? GatewayBotRoute(
                gatewayID: gatewayID,
                profile: GatewayBotRoute(qualifiedID: botID)?.profile ?? botID)
        }
        let routeChanged = oldRoute != nil && bindingRoute != nil && oldRoute != bindingRoute
        let bindingChanged = (oldSessionID != nil && oldSessionID != live.sessionID)
            || (newStoredID != nil && chat.storedSessionID != newStoredID)
            || routeChanged
        if routeChanged, let oldRoute, let bindingRoute, let oldStoredID,
           oldStoredID == durableID {
            ChatRuntime.shared.migrateProfileRouteState(
                from: oldRoute, to: bindingRoute,
                sourceBotID: botID, destinationBotID: botID,
                storedID: oldStoredID, chatID: ObjectIdentifier(chat),
                sessionID: oldSessionID)
        }
        if let bindingRoute {
            ChatRuntime.shared.migratePendingStop(
                botID: botID, route: bindingRoute, sessionID: live.sessionID,
                storedID: durableID, generation: runtime.generation,
                chatID: ObjectIdentifier(chat))
            if bindingChanged, let oldSessionID, let oldRoute {
                if let oldStoredID, oldStoredID == durableID, oldRoute == bindingRoute {
                    _ = migrateQueuedState(
                        fromBotID: botID, toBotID: botID, route: bindingRoute,
                        oldSessionID: oldSessionID, newSessionID: live.sessionID,
                        storedID: oldStoredID)
                    migrateComposeQueueSession(
                        botID: botID, route: bindingRoute,
                        oldSessionID: oldSessionID, newSessionID: live.sessionID,
                        storedID: oldStoredID, chatID: ObjectIdentifier(chat))
                } else {
                    _ = retireQueuedState(botID: botID, route: oldRoute,
                                          storedID: oldStoredID)
                }
            }
        }
        if bindingChanged, let gatewayID, let route = bindingRoute {
            ChatRuntime.shared.migrateMutationState(
                botID: botID, route: route, sessionID: live.sessionID,
                storedID: durableID, generation: runtime.generation,
                chatID: ObjectIdentifier(chat), oldSessionID: oldSessionID)
            chat.hasUnresolvedRetry = ChatRuntime.shared.failedRetryRows[botID] != nil
            if let kickoffStored = durableID ?? oldStoredID,
               CanonicalChatRuntime.shared.migrateKickoff(
                   botID: botID, route: route, sessionID: live.sessionID,
                   storedID: kickoffStored, chatID: ObjectIdentifier(chat)) == false {
                // A legacy bind can cross a same-gateway profile switch too;
                // gateway id alone is not ownership. Retire only the exact
                // old route/durable/chat lease and never carry it to the new
                // profile directory.
                let priorRoute = CanonicalChatRuntime.shared.ambiguousKickoffs[botID]?.route
                    ?? CanonicalChatRuntime.shared.kickoffLeases[botID]?.route
                    ?? route
                if let priorLease = CanonicalChatRuntime.shared.kickoffLeases[botID]
                    ?? CanonicalChatRuntime.shared.ambiguousKickoffs[botID],
                   let oldStoredID {
                    _ = CanonicalChatRuntime.shared.retireKickoff(
                        botID: botID, route: priorRoute,
                        storedID: oldStoredID,
                        chatID: ObjectIdentifier(chat), operationID: priorLease.id)
                }
            }
            if ChatRuntime.shared.transcriptActions[botID] != nil {
                if newStoredID != nil, chat.storedSessionID != newStoredID {
                    ChatRuntime.shared.transcriptActions[botID] = nil
                    ChatRuntime.shared.transcriptActionGenerations[botID] = nil
                } else if ChatRuntime.shared.transcriptFences[botID] == nil {
                    ChatRuntime.shared.transcriptActionGenerations[botID] = runtime.generation
                }
            }
            if let old = oldSessionID, old != live.sessionID {
                if runtime.sessionToBot[old] == botID {
                    runtime.sessionToBot.removeValue(forKey: old)
                }
                let routed = GatewaySessionRoute(gatewayID: gatewayID, sessionID: old)
                if runtime.routedSessionToBot[routed] == botID {
                    runtime.routedSessionToBot.removeValue(forKey: routed)
                }
            }
        }

        chat.sessionID = live.sessionID
        if let newStoredID { chat.storedSessionID = newStoredID }
        if gatewayID == runtime.gatewayID {
            runtime.sessionToBot[live.sessionID] = botID
        } else if let gatewayID {
            runtime.routedSessionToBot[GatewaySessionRoute(gatewayID: gatewayID,
                                                           sessionID: live.sessionID)] = botID
        }
        runtime.reconnectParkedSessionIDs[botID] = nil
        if live.running {
            setWorking(botID, true)
            chat.isTyping = true
        }
        // The legacy bind path is also an authoritative adoption boundary.
        // Give any retained no-replay lease one read-only retry opportunity;
        // the scheduler coalesces with adopt's call when both paths meet.
        scheduleRetainedMutationReconciliation(botID: botID)
        drainPendingMutationWork(botID: botID)
    }

    /// Preserve the currently visible runtime binding before a recovery path
    /// deliberately clears it. Adoption then has an explicit old SID to
    /// migrate unresolved mutation/kickoff state through the nil window.
    func parkRuntimeSessionBeforeClearing(botID: String) {
        guard let sessionID = chats[botID]?.sessionID, !sessionID.isEmpty else { return }
        LiveRuntime.shared.reconnectParkedSessionIDs[botID] = sessionID
    }

    /// Map transcript rows to chat messages. Two shapes reach here and both
    /// have to work, because the REST route is the hydration fallback:
    ///
    /// - the WS display projection (server.py:_history_to_messages) —
    ///   `{role, text, timestamp?, row_id?, reasoning?, display_kind?}`, tool
    ///   rows carrying `{role:"tool", name, args}`;
    /// - raw `messages` rows from GET /api/sessions/{id}/messages
    ///   (hermes_state.py:get_messages returns `SELECT *`) — the same fields
    ///   under their column names: `content` for the body, `id` for the row.
    ///
    /// Hidden scaffolding is dropped. Tool rows are reconstructed into typed,
    /// ordered calls. Only exact wire ids pair calls/results; names and text
    /// are presentation data and never identity.
    static func chatMessages(fromTranscript payload: JSONValue,
                             toolsMayBeRunning: Bool = false) -> [ChatMessage] {
        var rows = payload["messages"]?.arrayValue ?? payload.arrayValue ?? []
        // Durable ids outrank wall-clock timestamps, which can move backward.
        if rows.count > 1,
           let first = transcriptRowID(rows[0]), let last = transcriptRowID(rows[rows.count - 1]),
           first > last {
            rows.reverse()
        } else if rows.count > 1, transcriptRowID(rows[0]) == nil,
                  transcriptRowID(rows[rows.count - 1]) == nil,
                  let first = rows.first?["timestamp"]?.doubleValue,
                  let last = rows.last?["timestamp"]?.doubleValue, first > last {
            rows.reverse()
        }
        // Normalize direction before clipping. `latest` REST pages may arrive
        // newest-first; clipping first would discard the newest row rather
        // than the oldest one and make a 201-row page regress by one turn.
        if rows.count > StoredTranscriptHydrationPayloadPolicy.maximumRows {
            rows = Array(rows.suffix(StoredTranscriptHydrationPayloadPolicy.maximumRows))
        }
        let ambiguousToolIDs = Self.ambiguousTranscriptToolIDs(rows)

        var messages: [ChatMessage] = []
        var pending: [ToolCall] = []
        var pendingTime: String?
        var pendingRowID: Int?
        var possibleRunningPresentationIDs: Set<String> = []

        func appendPending() {
            guard !pending.isEmpty else { return }
            messages.append(ChatMessage(author: .bot, time: pendingTime, text: "",
                                        toolCalls: pending, rowID: pendingRowID))
            pending.removeAll(); pendingTime = nil; pendingRowID = nil
        }

        func retain(_ calls: [ToolCall], time: String?, rowID: Int?) {
            guard !calls.isEmpty else { return }
            pending.append(contentsOf: calls)
            if pendingTime == nil { pendingTime = time }
            if pendingRowID == nil { pendingRowID = rowID }
        }

        func apply(_ result: ToolCall) -> Bool {
            guard let wireID = result.gatewayToolID else { return false }
            // Repeated exact ids are not an identity proof. Pairing one of
            // several calls/results would silently attach output to the wrong
            // execution, so every member of the collision remains visible but
            // unpaired.
            guard !ambiguousToolIDs.contains(wireID) else { return false }
            if let hit = pending.lastIndex(where: {
                $0.gatewayToolID == wireID
                    && ($0.result == nil || $0.result?.kind == .unavailable)
            }) {
                mergeStoredResult(result, into: &pending[hit])
                possibleRunningPresentationIDs.remove(pending[hit].id)
                return true
            }
            for index in messages.indices.reversed() {
                guard let hit = messages[index].toolCalls.lastIndex(where: {
                    $0.gatewayToolID == wireID
                        && ($0.result == nil || $0.result?.kind == .unavailable)
                }) else { continue }
                mergeStoredResult(result, into: &messages[index].toolCalls[hit])
                possibleRunningPresentationIDs.remove(messages[index].toolCalls[hit].id)
                return true
            }
            return false
        }

        for (index, row) in rows.enumerated() {
            guard row["display_kind"]?.stringValue != "hidden" else { continue }
            let role = row["role"]?.stringValue
            let text = transcriptText(row)
            // Gateway bookkeeping (model switches, personality notices) is
            // persisted as role=user "[System: …]" so strict providers accept
            // it mid-history. The WS projection filters it
            // (server.py:_is_display_hidden_marker); raw DB rows do not, so it
            // has to be filtered here too or it renders as a user bubble.
            guard !(role == "user" && text.hasPrefix("[System:")) else { continue }
            let time = row["timestamp"]?.doubleValue.map { shortTime($0) }
            let reasoning = row["reasoning"]?.stringValue
                ?? row["reasoning_content"]?.stringValue
            // Durable row identity (_history_to_messages stamps `row_id` from
            // _rows_to_conversation; the DB column it comes from is `id`).
            // Without it only the newest assistant row is addressable by
            // `message.react`, which names rows by id.
            let rowID = transcriptRowID(row)
            switch role {
            case "tool":
                let result = storedToolResult(
                    row, index: index, rowID: rowID, ambiguousWireIDs: ambiguousToolIDs)
                if !apply(result) { retain([result], time: time, rowID: rowID) }

            case "assistant":
                let calls = storedToolCalls(
                    row, rowID: rowID, ambiguousWireIDs: ambiguousToolIDs)
                let visible = !text.isEmpty || !(reasoning ?? "").isEmpty
                if !calls.isEmpty {
                    possibleRunningPresentationIDs = Set(calls.compactMap { call in
                        guard call.provenance == .stored, call.gatewayToolID != nil else {
                            return nil
                        }
                        return call.id
                    })
                } else if visible {
                    possibleRunningPresentationIDs = []
                }
                if !visible {
                    guard !calls.isEmpty else { continue }
                    appendPending()
                    retain(calls, time: time, rowID: rowID)
                    continue
                }
                let allCalls = pending + calls
                pending.removeAll(); pendingTime = nil; pendingRowID = nil
                messages.append(ChatMessage(author: .bot, time: time, text: text,
                                            reasoning: reasoning, toolCalls: allCalls,
                                            rowID: rowID))

            case "user":
                appendPending(); possibleRunningPresentationIDs = []
                guard !text.isEmpty else { continue }
                messages.append(ChatMessage(author: .user, time: time, text: text,
                                            rowID: rowID))

            case "system":
                appendPending(); possibleRunningPresentationIDs = []
                guard !text.isEmpty else { continue }
                messages.append(ChatMessage(author: .system, time: time, text: text))

            default: continue
            }
        }
        appendPending()

        // A running session can only lend liveness to its single unmatched
        // tail invocation. Older unmatched calls are historical and must not
        // come back as permanent spinners after hydration.
        if toolsMayBeRunning, !possibleRunningPresentationIDs.isEmpty {
            for messageIndex in messages.indices {
                for callIndex in messages[messageIndex].toolCalls.indices
                where possibleRunningPresentationIDs.contains(
                    messages[messageIndex].toolCalls[callIndex].id)
                    && messages[messageIndex].toolCalls[callIndex].provenance == .stored {
                    messages[messageIndex].toolCalls[callIndex].state = .running
                    messages[messageIndex].toolCalls[callIndex].result = nil
                    messages[messageIndex].toolCalls[callIndex].resultText = nil
                    messages[messageIndex].toolCalls[callIndex].diagnostic = nil
                }
            }
        }
        return messages
    }

    static func transcriptNeedsRawToolSupplement(_ payload: JSONValue) -> Bool {
        let rows = payload["messages"]?.arrayValue ?? payload.arrayValue ?? []
        return rows.contains {
            $0["role"]?.stringValue == "tool" || $0["tool_calls"] != nil
        }
    }

    /// Enrich a display projection with the exact bounded raw page without
    /// treating repeated text/tool names as identity. Raw durable ids define
    /// the only replaceable range; ambiguous id-less projection edges remain.
    static func mergeRawToolSupplement(display: [ChatMessage],
                                       raw: [ChatMessage]) -> [ChatMessage] {
        guard !display.isEmpty else { return raw }
        guard raw.contains(where: { !$0.toolCalls.isEmpty }) else { return display }
        let ids = raw.compactMap(\.rowID).sorted()
        guard let lower = ids.first, let upper = ids.last else {
            if raw.allSatisfy(isToolOnlyTranscriptMessage)
                && display.allSatisfy(isToolOnlyTranscriptMessage) { return raw }
            return display + raw
        }

        let replaceableAnonymous = Set(display.indices.filter { index in
            guard display[index].rowID == nil,
                  isToolOnlyTranscriptMessage(display[index]),
                  let prior = display[..<index].last(where: { $0.rowID != nil })?.rowID,
                  let next = display.indices.lazy.filter({ $0 > index })
                    .compactMap({ display[$0].rowID }).first else { return false }
            return (lower...upper).contains(prior) && (lower...upper).contains(next)
        })
        let insertion = replaceableAnonymous.min()
            ?? display.firstIndex(where: { $0.rowID.map { $0 >= lower } == true })
            ?? display.endIndex
        var merged: [ChatMessage] = []
        var inserted = false
        for (index, message) in display.enumerated() {
            if !inserted, index == insertion {
                merged.append(contentsOf: raw); inserted = true
            }
            if let id = message.rowID, (lower...upper).contains(id) { continue }
            if replaceableAnonymous.contains(index) { continue }
            merged.append(message)
        }
        if !inserted { merged.append(contentsOf: raw) }
        return merged
    }

    private static func isToolOnlyTranscriptMessage(_ message: ChatMessage) -> Bool {
        message.author == .bot && message.text.isEmpty && !message.toolCalls.isEmpty
    }

    private static func transcriptRowID(_ row: JSONValue) -> Int? {
        row["row_id"]?.intValue ?? row["id"]?.intValue
    }

    private static func transcriptWireID(_ value: JSONValue?) -> String? {
        let raw = value?.stringValue ?? value?.intValue.map(String.init)
        return ToolPayloadCodec.admittedIdentity(
            raw, maximum: ToolPayloadCodec.maximumToolIdentityCharacters)
    }

    /// Exact execution ids are only useful when each side is unique. A
    /// duplicate call or duplicate result is retained as an explicit
    /// diagnostic, but it can never be paired by choosing first/last order.
    private static func ambiguousTranscriptToolIDs(_ rows: [JSONValue]) -> Set<String> {
        var callCounts: [String: Int] = [:]
        var resultCounts: [String: Int] = [:]
        for row in rows where row["display_kind"]?.stringValue != "hidden" {
            switch row["role"]?.stringValue {
            case "assistant":
                for call in row["tool_calls"]?.arrayValue ?? [] {
                    if let wireID = transcriptWireID(call["id"] ?? call["tool_call_id"]) {
                        callCounts[wireID, default: 0] += 1
                    }
                }
            case "tool":
                if let wireID = transcriptWireID(row["tool_call_id"] ?? row["tool_id"]) {
                    resultCounts[wireID, default: 0] += 1
                }
            default:
                continue
            }
        }
        let duplicateCalls = callCounts.compactMap { key, count in count > 1 ? key : nil }
        let duplicateResults = resultCounts.compactMap { key, count in count > 1 ? key : nil }
        return Set(duplicateCalls).union(duplicateResults)
    }

    private static func storedToolCalls(
        _ row: JSONValue, rowID: Int?, ambiguousWireIDs: Set<String> = []
    ) -> [ToolCall] {
        guard let encoded = row["tool_calls"], encoded != .null else { return [] }
        guard let calls = encoded.arrayValue else {
            return [ToolCall(
                id: "stored-malformed-call:\(rowID.map(String.init) ?? "unknown")",
                name: "Tool", context: "", state: .done,
                result: ToolPayloadCodec.unavailable(
                    "Hermes retained a malformed tool-call record."),
                provenance: .malformed,
                diagnostic: "The saved tool-call record could not be decoded; no result was inferred.")]
        }
        return calls.prefix(128).enumerated().map { offset, call in
            let function = call["function"]
            let wireID = transcriptWireID(call["id"] ?? call["tool_call_id"])
            let rawName = call["name"]?.stringValue ?? call["tool_name"]?.stringValue
                ?? function?["name"]?.stringValue ?? call["input"]?["name"]?.stringValue
            let name = ToolPayloadCodec.admittedIdentity(
                rawName, maximum: ToolPayloadCodec.maximumToolNameCharacters) ?? "Tool"
            let arguments = ToolPayloadCodec.arguments(
                from: function?["arguments"] ?? call["arguments"] ?? call["args"]
                    ?? call["input"])
            let context = call["context"]?.stringValue.map {
                ToolPayloadCodec.boundedText($0, maximum: 80)
            } ?? ToolPayloadCodec.preview(arguments, maximum: 80) ?? ""
            let missingIdentity = wireID == nil
            let ambiguousIdentity = wireID.map { ambiguousWireIDs.contains($0) } == true
            return ToolCall(
                id: "stored-call:\(rowID.map(String.init) ?? "unknown"):\(offset)",
                name: name, context: context, state: .done, gatewayToolID: wireID,
                arguments: arguments,
                result: ToolPayloadCodec.unavailable(
                    "Hermes retained this tool call without a matching result row."),
                provenance: missingIdentity || ambiguousIdentity ? .malformed : .stored,
                diagnostic: missingIdentity
                    ? "The saved call has no stable tool-call id; Talaria will not guess its result."
                    : (ambiguousIdentity
                        ? "The saved transcript reused this tool id; Talaria left the call unpaired."
                        : "The saved turn contains no matching retained tool result."))
        }
    }

    private static func storedToolResult(
        _ row: JSONValue, index: Int, rowID: Int?, ambiguousWireIDs: Set<String> = []
    ) -> ToolCall {
        // Database row `id` is not an execution id.
        let wireID = transcriptWireID(row["tool_call_id"] ?? row["tool_id"])
        let name = ToolPayloadCodec.admittedIdentity(
            row["tool_name"]?.stringValue ?? row["name"]?.stringValue,
            maximum: ToolPayloadCodec.maximumToolNameCharacters) ?? "Tool"
        let arguments = ToolPayloadCodec.directArguments(
            from: row["args"] ?? row["arguments"] ?? row["input"])
        let context = row["context"]?.stringValue.map {
            ToolPayloadCodec.boundedText($0, maximum: 80)
        } ?? ToolPayloadCodec.preview(arguments, maximum: 80) ?? ""
        let raw = row["content"] ?? row["result"]
        let hasRaw = raw != nil && raw != .null
        let result = ToolPayloadCodec.result(from: raw)
            ?? ToolPayloadCodec.unavailable(hasRaw
                ? "Hermes saved an empty tool result."
                : "This display projection omitted the retained tool output.")
        let ambiguousIdentity = wireID.map { ambiguousWireIDs.contains($0) } == true
        return ToolCall(
            id: "stored-result:\(rowID.map(String.init) ?? "unknown"):\(index)",
            name: name, context: context,
            state: ToolPayloadCodec.resultHasExplicitError(result) ? .failed : .done,
            summary: context.isEmpty ? ToolPayloadCodec.preview(result) : context,
            resultText: result.displayText, gatewayToolID: wireID,
            arguments: arguments, result: result,
            fileDiff: ToolDiffCodec.extract(toolName: name,
                arguments: row["args"] ?? row["arguments"] ?? row["input"],
                result: raw),
            deferredFileDiff: ToolDiffCodec.isFileEditTool(name) ? nil
                : ToolDiffCodec.candidate(
                    arguments: row["args"] ?? row["arguments"] ?? row["input"],
                    result: raw),
            provenance: hasRaw
                ? (wireID == nil ? .unmatchedResult : (ambiguousIdentity ? .malformed : .stored))
                : .projection,
            diagnostic: wireID == nil
                ? "Hermes retained this result without a stable tool-call id; it was not paired by name."
                : (ambiguousIdentity
                    ? "The saved transcript reused this tool id; Talaria left the result unpaired."
                    : (hasRaw ? nil : "Raw retained output is unavailable in this projection.")))
    }

    private static func mergeStoredResult(_ result: ToolCall, into call: inout ToolCall) {
        call.state = result.state
        call.context = call.context.isEmpty ? result.context : call.context
        call.arguments = call.arguments ?? result.arguments
        call.result = result.result
        if ToolDiffCodec.isFileEditTool(call.name),
           var diff = result.fileDiff ?? result.deferredFileDiff {
            if diff.path == nil { diff.path = ToolDiffCodec.path(from: call.arguments) }
            call.fileDiff = diff
        }
        call.deferredFileDiff = nil
        call.summary = result.summary ?? call.summary
        call.resultText = result.resultText ?? call.resultText
        call.diagnostic = result.provenance == .projection ? call.diagnostic : result.diagnostic
    }

    /// The body of a transcript row. `text` is the projection's field name and
    /// `content` the column's; a multimodal `content` is a parts array
    /// (`[{type:"text", text:…}, {type:"image_url", …}]`), whose text parts are
    /// the only renderable half.
    private static func transcriptText(_ row: JSONValue) -> String {
        if let text = row["text"]?.stringValue { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let content = row["content"] else { return "" }
        if let text = content.stringValue { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let parts = content.arrayValue else { return "" }
        return parts.compactMap { $0["text"]?.stringValue }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replay a reconnect/resume inflight snapshot into the exact bound chat.
    /// Failed turns are retained by Hermes precisely because their terminal
    /// frame and canonical DB row may both be absent. Keep failure metadata on
    /// the assistant row, structurally upsert a repeated live/resume copy, and
    /// preserve mid-turn correction ordering when the gateway supplied a
    /// trustworthy offset vector.
    func replayInflight(_ live: LiveSession, botID: String,
                        replacingTranscript: Bool = false) {
        guard let retained = live.retainedInflight else { return }
        let chat = chat(for: botID)
        let retainedFailure = TurnFailureLifecycle.failure(from: retained)
        let dismissal = retainedFailure.flatMap { failure -> DismissedTurnFailure? in
            guard let route = gatewayRoute(for: botID),
                  let storedID = chat.storedSessionID, !storedID.isEmpty else { return nil }
            return DismissedTurnFailure(route: route, storedID: storedID,
                                        message: failure.message)
        }
        let dismissed = dismissal.map {
            ChatRuntime.shared.dismissedFailures[ObjectIdentifier(chat)] == $0
        } ?? false
        let failure = dismissed ? nil : retainedFailure
        let partial = retainedFailure == nil
            ? (retained.assistant ?? "")
            : TurnFailureLifecycle.admittedMessage(retained.assistant)

        if dismissed, !replacingTranscript,
           let user = retained.user?.trimmingCharacters(in: .whitespacesAndNewlines),
           !user.isEmpty,
           chat.messages.last(where: { $0.author == .user })?.text == user {
            // The empty failed placeholder may have been deliberately removed.
            // Replaying the same retained snapshot must not resurrect either
            // its card or a duplicate user bubble before the next turn starts.
            return
        }

        // A retry may have been accepted just as the socket disappeared,
        // before message.start could clear the old failed row. The retained
        // projection is authoritative evidence of that fresh turn: reuse the
        // leased assistant identity and replace, rather than monotonically
        // merging the previous turn's failure into the retry.
        if !replacingTranscript,
           let retryLease = ChatRuntime.shared.failedRetryRows[botID],
           retryLease.phase == .started || retryLease.phase == .submitting,
           retryLease.route == gatewayRoute(for: botID),
           retryLease.sessionID == live.sessionID,
           chat.sessionID == live.sessionID,
           retryLease.storedID == chat.storedSessionID,
           retryLease.chatID == ObjectIdentifier(chat),
           (retained.streaming
               || partial != retryLease.baselineText
               || retainedFailure != retryLease.baselineFailure),
           let index = chat.messages.firstIndex(where: {
               $0.id == retryLease.assistantID
           }) {
            chat.messages[index].text = partial
            chat.messages[index].isStreaming = retained.streaming && failure == nil
            chat.messages[index].failure = failure
            ChatRuntime.shared.failedRetryRows[botID] = nil
            chat.hasUnresolvedRetry = false
            if retainedFailure != nil {
                let start = chat.messages[...index].lastIndex(where: { $0.author == .user })
                    ?? index
                ChatRuntime.shared.retainedFailureRows[ObjectIdentifier(chat)] =
                    Set(chat.messages[start...index].map(\.id))
            }
            chat.isTyping = false
            return
        }

        // An unchanged retained snapshot is the failed attempt captured as
        // the retry baseline, not evidence from the new submission. Keep the
        // lease and card until fresh streaming/content/failure or authority.
        if !replacingTranscript,
           let retryLease = ChatRuntime.shared.failedRetryRows[botID],
           retryLease.phase != .prepared,
           retryLease.route == gatewayRoute(for: botID),
           retryLease.sessionID == live.sessionID,
           chat.sessionID == live.sessionID,
           retryLease.storedID == chat.storedSessionID,
           retryLease.chatID == ObjectIdentifier(chat) {
            return
        }

        // A live terminal frame may already own the exact assistant bubble.
        // Anchor the search after the latest matching retained user. An empty
        // new-turn assistant must never reuse a failed/streaming row belonging
        // to an earlier prompt above that user.
        let retainedUser = retained.user?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let retainedUserIndex = retainedUser.isEmpty ? nil
            : chat.messages.indices.reversed().first(where: {
                chat.messages[$0].author == .user
                    && chat.messages[$0].text == retainedUser
            })
        let latestUserIndex = chat.messages.indices.reversed().first(where: {
            chat.messages[$0].author == .user
        })
        let currentTurnLowerBound = retainedUser.isEmpty
            ? (latestUserIndex.map { $0 + 1 } ?? 0)
            : retainedUserIndex.map { $0 + 1 }
        if !replacingTranscript,
           let lowerBound = currentTurnLowerBound,
           let index = chat.messages.indices.reversed().first(where: {
               guard $0 >= lowerBound,
                     chat.messages[$0].author == .bot else { return false }
               let row = chat.messages[$0]
               return TurnFailureLifecycle.compatible(
                   existing: row, partial: partial, failure: retainedFailure)
                   && (row.failure != nil || row.isStreaming || dismissed)
           }) {
            let old = chat.messages[index].text
            if old.isEmpty || partial.hasPrefix(old) {
                chat.messages[index].text = partial
            }
            chat.messages[index].isStreaming = retained.streaming && failure == nil
            chat.messages[index].failure = TurnFailureLifecycle.merge(
                chat.messages[index].failure, failure)
            if retainedFailure != nil {
                let start = min(ChatRuntime.shared.turnFloor[botID] ?? index, index)
                ChatRuntime.shared.retainedFailureRows[ObjectIdentifier(chat)] =
                    Set(chat.messages[start...index].map(\.id))
            }
            chat.isTyping = false
            return
        }

        let persisted = Self.chatMessages(fromTranscript: .array(live.messages))
            .filter { $0.author == .user }
        let rows = Self.retainedInflightProjection(
            retained, failure: failure, persistedUsers: persisted)

        var retainedIDs: Set<UUID> = []
        for (offset, row) in rows.enumerated() {
            // The retained projection begins with its owning user. If that
            // exact user is already the latest matching turn in the visible
            // transcript, keep the existing row and append only the new
            // assistant/correction tail beneath it.
            if offset == 0, row.author == .user,
               let retainedUserIndex,
               row.text == retainedUser {
                if let rowID = row.rowID,
                   chat.messages[retainedUserIndex].rowID == nil {
                    chat.messages[retainedUserIndex].rowID = rowID
                }
                if retainedFailure != nil {
                    retainedIDs.insert(chat.messages[retainedUserIndex].id)
                }
                continue
            }
            if row.author == .user, let rowID = row.rowID,
               let existing = chat.messages.first(where: {
                   $0.author == .user && $0.rowID == rowID
               }) {
                if retainedFailure != nil { retainedIDs.insert(existing.id) }
                continue
            }
            chat.messages.append(row)
            if retainedFailure != nil { retainedIDs.insert(row.id) }
        }
        if retainedFailure != nil {
            ChatRuntime.shared.retainedFailureRows[ObjectIdentifier(chat)] = retainedIDs
        }
        if rows.contains(where: { $0.author == .bot }) { chat.isTyping = false }
    }

    /// Pure projection seam for retained-turn ordering regressions. Python's
    /// correction offsets count Unicode code points; Swift Unicode scalars are
    /// the corresponding bounded indexing unit (never `Character`, whose one
    /// grapheme may contain unbounded combining marks).
    static func retainedInflightProjection(
        _ retained: RetainedInflightTurn,
        failure: TurnFailure?,
        persistedUsers: [ChatMessage] = []
    ) -> [ChatMessage] {
        let user = retained.user?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let corrections = retained.corrections
        let expectedUserTexts = ([user] + corrections).filter { !$0.isEmpty }
        let persistedTail = Array(persistedUsers.suffix(expectedUserTexts.count))
        let persistedMatches = persistedTail.map(\.text) == expectedUserTexts
        var persistedIndex = 0

        func userRow(_ text: String) -> ChatMessage? {
            guard !text.isEmpty else { return nil }
            defer { persistedIndex += 1 }
            if persistedMatches, persistedIndex < persistedTail.count {
                return persistedTail[persistedIndex]
            }
            return ChatMessage(author: .user, time: AppModel.clock(), text: text)
        }

        var rows: [ChatMessage] = []
        if let row = userRow(user) { rows.append(row) }
        let hasFailureEvidence = TurnFailureLifecycle.failure(from: retained) != nil
        let assistant = hasFailureEvidence || !retained.corrections.isEmpty
            ? TurnFailureLifecycle.admittedMessage(retained.assistant)
            : (retained.assistant ?? "")
        let scalars = Array(assistant.unicodeScalars)
        let offsets = retained.correctionOffsets
        let offsetsUsable = !retained.correctionsMalformed
            && !corrections.isEmpty
            && offsets?.count == corrections.count

        if offsetsUsable, let offsets {
            var cursor = 0
            for (correction, rawOffset) in zip(corrections, offsets) {
                let boundary = min(max(rawOffset, cursor), scalars.count)
                if boundary > cursor {
                    let segment = String(String.UnicodeScalarView(scalars[cursor..<boundary]))
                    rows.append(ChatMessage(author: .bot, time: AppModel.clock(), text: segment))
                }
                if let row = userRow(correction) { rows.append(row) }
                cursor = boundary
            }
            let tail = String(String.UnicodeScalarView(scalars[cursor...]))
            if !tail.isEmpty || retained.streaming || failure != nil {
                rows.append(ChatMessage(
                    author: .bot, time: AppModel.clock(), text: tail,
                    isStreaming: retained.streaming && failure == nil,
                    failure: failure))
            }
        } else {
            if !assistant.isEmpty || retained.streaming || failure != nil {
                rows.append(ChatMessage(
                    author: .bot, time: AppModel.clock(), text: assistant,
                    isStreaming: retained.streaming && failure == nil,
                    failure: failure))
            }
            for correction in corrections {
                if let row = userRow(correction) { rows.append(row) }
            }
        }
        return rows
    }

    /// Replay the blocking prompts `session.resume` carries. Both park a real
    /// agent thread, and neither is re-emitted as an event after a reconnect:
    /// the approval sweep would find the approval a round trip later, but a
    /// clarify has no `*.pending` RPC at all, so this block is its only
    /// recovery channel. Routed through the approvals surface so a replayed
    /// approval arrives with its real choice set rather than once/deny.
    func replayPendingPrompts(_ live: LiveSession, sourceGatewayID: String? = nil) {
        if let pending = live.pendingApproval {
            ingestPendingApproval(pending, sourceGatewayID: sourceGatewayID)
        }
        if let clarify = live.pendingClarify, clarify != .null {
            ingestPendingClarify(clarify, sessionID: live.sessionID,
                                 sourceGatewayID: sourceGatewayID)
        }
    }

    // MARK: - Event routing

    func botID(forSession sessionID: String, sourceGatewayID: String? = nil) -> String? {
        let runtime = LiveRuntime.shared
        let gatewayID = sourceGatewayID ?? runtime.gatewayID
        if gatewayID == runtime.gatewayID { return runtime.sessionToBot[sessionID] }
        guard let gatewayID else { return nil }
        return runtime.routedSessionToBot[GatewaySessionRoute(gatewayID: gatewayID,
                                                              sessionID: sessionID)]
    }

    public func handle(event: GatewayEvent) {
        handle(event: event, sourceGatewayID: LiveRuntime.shared.gatewayID)
    }

    func handle(event: GatewayEvent, sourceGatewayID: String?) {
        let botID = botID(forSession: event.sessionID, sourceGatewayID: sourceGatewayID)
        switch TypedGatewayEvent(event) {
        case .messageStart:
            if let botID, currentChatOwnsMessageEvent(
                botID: botID, sessionID: event.sessionID,
                sourceGatewayID: sourceGatewayID) {
                let chat = chat(for: botID)
                chat.isTyping = true
                ChatRuntime.shared.retainedFailureRows[ObjectIdentifier(chat)] = nil
                ChatRuntime.shared.dismissedFailures[ObjectIdentifier(chat)] = nil
                if var retryLease = ChatRuntime.shared.failedRetryRows[botID],
                   retryLease.phase == .submitting,
                   retryLeaseMatchesEvent(
                       retryLease, botID: botID, sessionID: event.sessionID,
                       sourceGatewayID: sourceGatewayID),
                   let index = chat.messages.firstIndex(where: {
                       $0.id == retryLease.assistantID
                   }) {
                    retryLease.phase = .started
                    ChatRuntime.shared.failedRetryRows[botID] = retryLease
                    chat.messages[index].text = ""
                    chat.messages[index].reasoning = nil
                    chat.messages[index].toolCalls = []
                    chat.messages[index].card = nil
                    chat.messages[index].failure = nil
                    chat.messages[index].isStreaming = true
                    ChatRuntime.shared.turnFloor[botID] = index
                } else {
                    if ChatRuntime.shared.failedRetryRows[botID]?.phase == .prepared {
                        ChatRuntime.shared.failedRetryRows[botID] = nil
                        chat.hasUnresolvedRetry = false
                    }
                    // This ordered pump sees message.start before the auxiliary
                    // tool router. Establish the new turn's ownership here so
                    // an immediately-following error-only completion cannot
                    // attach its failure card to historical assistant output.
                    ChatRuntime.shared.turnFloor[botID] =
                        chat.messages.indices.last(where: {
                            chat.messages[$0].author == .bot
                                && chat.messages[$0].isStreaming
                        }) ?? chat.messages.count
                }
                setWorking(botID, true)
            }

        case .messageDelta(let text):
            guard let botID, !text.isEmpty,
                  currentChatOwnsMessageEvent(botID: botID, sessionID: event.sessionID,
                                              sourceGatewayID: sourceGatewayID) else { return }
            let chat = chat(for: botID)
            chat.isTyping = false
            if let last = chat.messages.last, last.isStreaming {
                chat.messages[chat.messages.count - 1].text += text
            } else {
                chat.messages.append(ChatMessage(author: .bot, time: AppModel.clock(),
                                                 text: text, isStreaming: true))
            }

        case .thinkingDelta(let text), .reasoningDelta(let text):
            // Reasoning usually precedes the first visible token — open the
            // streaming bubble early so the "Thought" block has a home.
            guard let botID, !text.isEmpty,
                  currentChatOwnsMessageEvent(botID: botID, sessionID: event.sessionID,
                                              sourceGatewayID: sourceGatewayID) else { return }
            let chat = chat(for: botID)
            chat.isTyping = false
            if let last = chat.messages.last, last.isStreaming {
                chat.messages[chat.messages.count - 1].reasoning =
                    (last.reasoning ?? "") + text
            } else {
                chat.messages.append(ChatMessage(author: .bot, time: AppModel.clock(),
                                                 text: "", isStreaming: true, reasoning: text))
            }

        case .messageInterim(let text, let alreadyStreamed):
            // Complete assistant segment between tool calls: finalize the
            // streaming bubble, or append when it never streamed.
            guard let botID, !text.isEmpty,
                  currentChatOwnsMessageEvent(botID: botID, sessionID: event.sessionID,
                                              sourceGatewayID: sourceGatewayID) else { return }
            let chat = chat(for: botID)
            if let last = chat.messages.last, last.isStreaming {
                chat.messages[chat.messages.count - 1].text = text
                chat.messages[chat.messages.count - 1].isStreaming = false
            } else if !alreadyStreamed {
                chat.messages.append(ChatMessage(author: .bot, time: AppModel.clock(), text: text))
            }
            chat.isTyping = true   // the turn continues (tools next)

        case .messageComplete(let payload):
            guard let botID,
                  currentChatOwnsMessageEvent(botID: botID, sessionID: event.sessionID,
                                              sourceGatewayID: sourceGatewayID) else { return }
            let chat = chat(for: botID)
            chat.isTyping = false
            let retainedFailure = TurnFailureLifecycle.failure(from: payload)
            let dismissal = retainedFailure.flatMap { failure -> DismissedTurnFailure? in
                guard let route = gatewayRoute(for: botID),
                      let storedID = chat.storedSessionID, !storedID.isEmpty else { return nil }
                return DismissedTurnFailure(route: route, storedID: storedID,
                                            message: failure.message)
            }
            let failure = dismissal.map {
                ChatRuntime.shared.dismissedFailures[ObjectIdentifier(chat)] == $0
            } == true ? nil : retainedFailure
            if let retryLease = ChatRuntime.shared.failedRetryRows[botID],
               retryLease.phase == .submitting,
               retryLeaseMatchesEvent(
                   retryLease, botID: botID, sessionID: event.sessionID,
                   sourceGatewayID: sourceGatewayID),
               retainedFailure == retryLease.baselineFailure,
               (!payload.partial
                   || TurnFailureLifecycle.admittedMessage(payload.text)
                       == retryLease.baselineText) {
                // A delayed copy of the failed turn's old terminal frame is
                // not evidence about the accepted retry. Preserve its lease,
                // card, and no-replay reconciliation obligation unchanged.
                chat.usage = payload.usage
                return
            }
            // On non-partial failures Hermes' `text` is the rendered error
            // fallback, not assistant output. The card owns that string.
            let visibleText: String
            if retainedFailure != nil {
                visibleText = payload.partial
                    ? TurnFailureLifecycle.admittedMessage(payload.text) : ""
            } else {
                visibleText = payload.text
            }
            let retryIndex: Int?
            if let retryLease = ChatRuntime.shared.failedRetryRows[botID],
               retryLeaseMatchesEvent(
                   retryLease, botID: botID, sessionID: event.sessionID,
                   sourceGatewayID: sourceGatewayID),
               retryLease.phase == .started
                   || (retryLease.phase == .submitting
                       && (retainedFailure != retryLease.baselineFailure
                           || (payload.partial
                               && TurnFailureLifecycle.admittedMessage(payload.text)
                                   != retryLease.baselineText))) {
                retryIndex = chat.messages.firstIndex(where: {
                    $0.id == retryLease.assistantID
                })
            } else {
                retryIndex = nil
            }
            if let retryIndex {
                chat.messages[retryIndex].text = visibleText
                chat.messages[retryIndex].isStreaming = false
                chat.messages[retryIndex].failure = failure
                if let reasoning = payload.reasoning, !reasoning.isEmpty {
                    chat.messages[retryIndex].reasoning = reasoning
                }
                ChatRuntime.shared.failedRetryRows[botID] = nil
                chat.hasUnresolvedRetry = false
            } else if let last = chat.messages.last, last.isStreaming {
                if !visibleText.isEmpty {
                    chat.messages[chat.messages.count - 1].text = visibleText
                }
                chat.messages[chat.messages.count - 1].isStreaming = false
                if let reasoning = payload.reasoning, !reasoning.isEmpty,
                   chat.messages[chat.messages.count - 1].reasoning == nil {
                    chat.messages[chat.messages.count - 1].reasoning = reasoning
                }
            } else if !visibleText.isEmpty, chat.messages.last?.text != visibleText {
                chat.messages.append(ChatMessage(author: .bot, time: AppModel.clock(),
                                                 text: visibleText, failure: failure))
            }
            if retainedFailure != nil {
                let inferredFloor = chat.messages.indices.reversed().first(where: {
                    chat.messages[$0].author == .user
                }).map { $0 + 1 } ?? chat.messages.count
                let floor = min(ChatRuntime.shared.turnFloor[botID] ?? inferredFloor,
                                chat.messages.count)
                let failureIndex = retryIndex ?? chat.messages.indices.reversed().first(where: {
                    $0 >= floor && chat.messages[$0].author == .bot
                })
                if let index = failureIndex {
                    chat.messages[index].isStreaming = false
                    chat.messages[index].failure = TurnFailureLifecycle.merge(
                        chat.messages[index].failure, failure)
                } else if let failure {
                    chat.messages.append(ChatMessage(
                        author: .bot, time: AppModel.clock(), text: visibleText,
                        failure: failure))
                }
                if !chat.messages.isEmpty {
                    let end = chat.messages.index(before: chat.messages.endIndex)
                    let start = retryIndex.flatMap { index in
                        chat.messages[...index].lastIndex(where: { $0.author == .user })
                    } ?? min(floor, end)
                    ChatRuntime.shared.retainedFailureRows[ObjectIdentifier(chat)] =
                        Set(chat.messages[start...end].map(\.id))
                }
            }
            chat.usage = payload.usage
            pruneApprovals(sessionID: event.sessionID, sourceGatewayID: sourceGatewayID)
            setWorking(botID, false)
            LiveActivityController.shared.endAllOperationalWork(botID: botID)
            requestComposeQueueFlush()
            if let idx = bots.firstIndex(where: { $0.id == botID }) {
                if !visibleText.isEmpty {
                    bots[idx].preview = Self.previewLine(visibleText)
                    bots[idx].previewTime = AppModel.clock()
                }
            }
            recordUnread(for: botID)

        case .sessionUsage(let usage):
            if let botID { chat(for: botID).usage = usage }

        case .sessionInfo(let info):
            guard let botID else { return }
            let chat = chat(for: botID)
            chat.yolo = info.yolo
            if chat.storedSessionID == nil, !info.storedSessionID.isEmpty {
                chat.storedSessionID = info.storedSessionID
            }

        case .toolGenerating(let name):
            if let botID, let idx = bots.firstIndex(where: { $0.id == botID }) {
                bots[idx].task = name
            }

        case .toolStart(let tool):
            if let botID, let idx = bots.firstIndex(where: { $0.id == botID }) {
                bots[idx].task = tool.context.isEmpty ? tool.name : "\(tool.name) · \(tool.context)"
            }

        case .statusUpdate(_, let text):
            if let botID, !text.isEmpty,
               LiveRuntime.shared.workingBotIDs.contains(botID),
               let idx = bots.firstIndex(where: { $0.id == botID }) {
                bots[idx].task = text
            }

        case .approvalRequest(let request):
            ingest(request, sourceGatewayID: sourceGatewayID, owner: botID)

        case .errorEvent(let message):
            if let botID, !message.isEmpty {
                chat(for: botID).messages.append(ChatMessage(author: .system, text: message))
                setWorking(botID, false)
                LiveActivityController.shared.endAllOperationalWork(botID: botID)
                requestComposeQueueFlush()
            }

        case .changed(let what):
            Task { @MainActor in
                if sourceGatewayID == LiveRuntime.shared.gatewayID {
                    if what == "sessions.changed" { try? await self.refreshRoster() }
                    if what == "cron.changed" { await self.refreshRoutinesLive(force: true) }
                } else if let sourceGatewayID, what == "sessions.changed" {
                    await ConnectionRegistry.shared.refreshSecondaryRoster(
                        gatewayID: sourceGatewayID)
                    self.applySecondaryUnreadAnswers(gatewayID: sourceGatewayID)
                } else if sourceGatewayID != nil, what == "cron.changed" {
                    CronDetailRuntime.shared.changeTick &+= 1
                    await self.refreshRoutinesLive(force: true)
                }
            }

        case .notificationShow(let payload):
            showAgentNotice(payload)

        case .notificationClear(let key):
            clearAgentNotice(key)

        case .backgroundComplete(let taskID, let text):
            reportBackgroundCompletion(taskID: taskID, text: text, botID: botID)

        case .other(let raw) where raw.type == "session.reclaimed":
            // Backend reclaimed a parked runtime session (idle TTL / orphan
            // reap): drop the cached sid so the next open/send re-resumes
            // from the durable key.
            let sid = raw.payload?["session_id"]?.stringValue ?? ""
            guard !sid.isEmpty else { return }
            if let owner = self.botID(forSession: sid, sourceGatewayID: sourceGatewayID) {
                let chat = chat(for: owner)
                if chat.sessionID == sid || chat.storedSessionID == sid {
                    if chat.sessionID == sid {
                        LiveRuntime.shared.reconnectParkedSessionIDs[owner] = sid
                    }
                    chat.sessionID = nil
                    chat.isTyping = false
                }
                if sourceGatewayID == LiveRuntime.shared.gatewayID {
                    LiveRuntime.shared.sessionToBot.removeValue(forKey: sid)
                } else if let sourceGatewayID {
                    LiveRuntime.shared.routedSessionToBot.removeValue(
                        forKey: GatewaySessionRoute(gatewayID: sourceGatewayID, sessionID: sid))
                }
                setWorking(owner, false)
                LiveActivityController.shared.endAllOperationalWork(botID: owner)
            }

        default:
            break
        }
    }

    private func retryLeaseMatchesEvent(_ lease: FailedTurnRetryLease,
                                        botID: String, sessionID: String,
                                        sourceGatewayID: String?) -> Bool {
        guard let sourceGatewayID,
              sourceGatewayID == lease.route.gatewayID,
              gatewayRoute(for: botID) == lease.route,
              lease.sessionID == sessionID,
              let chat = chats[botID], ObjectIdentifier(chat) == lease.chatID,
              chat.sessionID == sessionID,
              chat.storedSessionID == lease.storedID else { return false }
        return true
    }

    func currentChatOwnsMessageEvent(botID: String, sessionID: String,
                                     sourceGatewayID: String?) -> Bool {
        guard let sourceGatewayID,
              (stateRoute(for: botID) ?? gatewayRoute(for: botID))?.gatewayID
                == sourceGatewayID,
              let chat = chats[botID] else { return false }
        if let currentSessionID = chat.sessionID {
            return currentSessionID == sessionID
        }
        // Exact routedSessionToBot ownership is sufficient for a background
        // ChatState that has never been foreground-bound. A reconnect park is
        // different: it remembers the only SID allowed during the temporary
        // nil window, so a stale mapped SID cannot mutate the rebound chat.
        if let parkedSessionID = LiveRuntime.shared.reconnectParkedSessionIDs[botID] {
            return parkedSessionID == sessionID
        }
        return true
    }

    // MARK: - Approvals

    @discardableResult
    func ingest(_ request: ApprovalRequest, sourceGatewayID: String? = nil,
                owner explicitOwner: String? = nil) -> String? {
        guard !request.requestID.isEmpty else { return nil }
        let runtime = LiveRuntime.shared
        guard let gatewayID = sourceGatewayID ?? runtime.gatewayID else { return nil }
        let approvalID = GatewayApprovalRoute(gatewayID: gatewayID,
                                               requestID: request.requestID).qualifiedID
        if ApprovalOutcomes.shared.choice(for: approvalID) != nil { return nil }
        let scopedOwner = explicitOwner ?? botID(forSession: request.sessionID,
                                                  sourceGatewayID: sourceGatewayID)
        let isRemote = sourceGatewayID != nil && sourceGatewayID != runtime.gatewayID
        // A secondary event pump covers its whole gateway. An approval for a
        // session we have not attached therefore has no trustworthy profile
        // owner. Never invent one from the primary roster: that would render
        // an answerable card whose response could be sent to another machine.
        guard !isRemote || scopedOwner != nil else { return nil }
        let owner = scopedOwner ?? runtime.defaultBotID ?? bots.first?.id ?? "default"
        let botRoute = GatewayBotRoute(qualifiedID: owner)
            ?? GatewayBotRoute(gatewayID: gatewayID, profile: owner)
        runtime.approvalTargets[approvalID] = ApprovalResponseTarget(
            bot: botRoute,
            session: GatewaySessionRoute(gatewayID: gatewayID, sessionID: request.sessionID),
            requestID: request.requestID,
            storedID: chats[owner].flatMap {
                $0.sessionID == request.sessionID ? $0.storedSessionID : nil
            }, botID: owner)
        if approvals.contains(where: { $0.id == approvalID }) { return approvalID }
        approvals.append(Approval(
            id: approvalID,
            botID: owner,
            kind: Self.approvalKind(for: request),
            title: request.description.isEmpty ? request.command : request.description,
            target: request.patternKey ?? runtime.baseURL?.host() ?? "",
            subject: request.command,
            body: request.command,
            why: request.description,
            age: "now"))
        if let idx = bots.firstIndex(where: { $0.id == owner }) {
            bots[idx].status = .approval
        }
        return approvalID
    }

    /// A finished turn can hold no approvals — drop the stale ones (they were
    /// answered elsewhere, timed out, or denied by an interrupt).
    private func pruneApprovals(sessionID: String, sourceGatewayID: String? = nil) {
        let runtime = LiveRuntime.shared
        guard let gatewayID = sourceGatewayID ?? runtime.gatewayID else { return }
        let session = GatewaySessionRoute(gatewayID: gatewayID, sessionID: sessionID)
        let stale = runtime.approvalTargets.filter { $0.value.session == session }.map(\.key)
        guard !stale.isEmpty else { return }
        for id in stale { runtime.approvalTargets.removeValue(forKey: id) }
        for id in stale { ApprovalBridges.shared.details.removeValue(forKey: id) }
        let owners = Set(approvals.filter { stale.contains($0.id) }.map(\.botID))
        approvals.removeAll { stale.contains($0.id) }
        for owner in owners { recomputeStatus(for: owner) }
    }

    static func approvalKind(for request: ApprovalRequest) -> ApprovalKind {
        let text = (request.command + " " + request.description).lowercased()
        if text.contains("mail") || text.contains("smtp") { return .email }
        if text.contains("post") || text.contains("publish") || text.contains("tweet") { return .post }
        if request.patternKey != nil || !request.command.isEmpty { return .command }
        return .other
    }

    /// Resolve the response route without crossing gateway identity domains.
    /// A routed request must agree with its card's qualified bot. A primary
    /// request may use its recorded session (or the primary chat's session for
    /// legacy events), but remote cards never receive that fallback.
    func approvalResponseTarget(for approval: Approval,
                                botRoute: GatewayBotRoute?) -> ApprovalResponseTarget? {
        guard let botRoute else { return nil }
        let runtime = LiveRuntime.shared
        if let target = runtime.approvalTargets[approval.id] {
            guard target.bot == botRoute, target.session.gatewayID == botRoute.gatewayID else {
                return nil
            }
            return target
        }
        // Demo/legacy primary cards have no live target. A live card must never
        // synthesize a destination from a chat after source qualification.
        return nil
    }

    /// Match a gateway wire request id without confusing it for the app's
    /// source-qualified approval id. A bot hint disambiguates the normal push
    /// payload; without one, collisions fail closed instead of picking first.
    func approval(matchingWireRequestID requestID: String, botID: String?) -> Approval? {
        let candidates = approvals.filter { approval in
            guard let target = LiveRuntime.shared.approvalTargets[approval.id] else {
                return approval.id == requestID // demo/solo compatibility
            }
            guard target.requestID == requestID else { return false }
            return botID == nil || approval.botID == botID
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    // MARK: - Live actions (called from AppModel's mode dispatch)

    enum LiveSendResult: Equatable, Sendable {
        case accepted
        /// The exact ChatState/route/fence changed while an await was
        /// suspended. The optimistic row remains visible and the caller must
        /// retain its queue item; it is not safe to retry automatically.
        case retained
        case failed
    }

    /// c1e25 accepts a busy prompt in place as either a steer or redirect.
    /// Those statuses are as authoritative as streaming/queued and must never
    /// enter the offline replay path.
    enum LivePromptSubmitReceipt {
        static func requireAccepted(_ value: JSONValue, operation: String) throws {
            if value["ok"]?.boolValue == false
                || ["error", "rejected", "refused"].contains(
                    value["status"]?.stringValue ?? "") {
                throw GatewayError(code: 409,
                                   message: "Hermes refused \(operation.lowercased()).")
            }
            guard let status = value["status"]?.stringValue,
                  ["streaming", "queued", "steered", "redirected"].contains(status) else {
                throw AckValidationError(
                    operation: operation,
                    detail: "Hermes did not return an accepted prompt status.")
            }
        }
    }

    /// Fire-and-forget entry point used by normal compose paths. The actual
    /// work is awaitable so offline flush can remove one queue row only after
    /// that exact operation has settled.
    func liveSend(text: String, botID: String, chat: ChatState,
                  optimisticID: UUID? = nil) {
        Task { @MainActor in
            _ = await liveSendAwaiting(text: text, botID: botID, chat: chat,
                                       optimisticID: optimisticID)
        }
    }

    /// Submit one prompt while preserving the exact mutation/chat/route
    /// binding captured at the operation boundary. Every await is followed by
    /// the same ownership check; a lifecycle rename, reconnect, fence, or
    /// ChatState replacement therefore leaves the optimistic row/queue item
    /// intact instead of silently dropping it or submitting into B.
    @discardableResult
    func liveSendAwaiting(text: String, botID: String, chat: ChatState,
                          optimisticID: UUID? = nil,
                          composeItemID: UUID? = nil,
                          preSubmitAdmission: (() -> Bool)? = nil) async -> LiveSendResult {
        guard mode == .live,
              let route = stateRoute(for: botID) ?? gatewayRoute(for: botID),
              !mutationIsFenced(botID: botID) else {
            return .retained
        }
        let chatID = ObjectIdentifier(chat)
        let localBaselineDurableUserRowIDs = Set(chat.messages.compactMap { row in
            row.author == .user ? row.rowID : nil
        })
        let localBaselineUndurableMatchingUserCount = chat.messages.filter {
            $0.author == .user && $0.rowID == nil && $0.text == text
        }.count
        let retryBaseline = composeItemID.flatMap { itemID -> FailedTurnRetryLease? in
            guard let lease = ChatRuntime.shared.failedRetryRows[botID],
                  lease.token == itemID, lease.authoritativeBaselineKnown,
                  lease.chatID == ObjectIdentifier(chat) else { return nil }
            return lease
        }
        let baselineDurableUserRowIDs = retryBaseline == nil
            ? localBaselineDurableUserRowIDs : []
        let baselineDurableUserRowIDWatermark = retryBaseline?
            .baselineDurableUserRowIDWatermark ?? localBaselineDurableUserRowIDs.max()
        let baselineUndurableMatchingUserCount = retryBaseline?
            .baselineUndurableMatchingUserCount ?? localBaselineUndurableMatchingUserCount
        let baselineAuthorityKnown = retryBaseline?.authoritativeBaselineKnown ?? false
        let capturedStoredID = chat.storedSessionID
        let capturedGeneration = LiveRuntime.shared.generation
        guard let lifecycleToken = profileLifecycleGenerationToken(for: botID) else {
            return .retained
        }
        let operationComposeID = composeItemID ?? UUID()
        var preSubmitAdmitted = false
        func retainComposeItem() -> LiveSendResult {
            // A failed-turn retry that never crossed its exact pre-submit gate
            // remains represented by the existing card. Do not also enqueue
            // it for an unowned later replay.
            if preSubmitAdmission != nil, !preSubmitAdmitted { return .retained }
            normalizeComposeQueueIDs()
            guard !composeQueueIDs.contains(operationComposeID) else { return .retained }
            appendComposeQueue(botID: botID, text: text, id: operationComposeID,
                               route: route, storedID: expectedStoredID,
                               sessionID: expectedSessionID, chatID: chatID)
            return .retained
        }
        var expectedStoredID = capturedStoredID
        var expectedSessionID: String?

        func owns(_ sessionID: String? = nil) -> Bool {
            guard mode == .live,
                  let current = chats[botID], ObjectIdentifier(current) == chatID,
                  !mutationIsFenced(botID: botID),
                  bindingRouteMatches(route, botID: botID),
                  current.storedSessionID == expectedStoredID,
                  LiveRuntime.shared.generation >= capturedGeneration,
                  profileLifecycleAccepts(lifecycleToken) else { return false }
            if let expectedSessionID, current.sessionID != expectedSessionID {
                return false
            }
            if let sessionID {
                guard bindingSessionID(for: botID) == sessionID,
                      current.sessionID == sessionID else { return false }
            }
            if let optimisticID {
                guard current.messages.contains(where: { $0.id == optimisticID }) else {
                    return false
                }
            }
            return true
        }

        var submitStarted = false
        do {
            let sid = try await ensureSession(botID: botID, hydrate: false)
            guard let boundStoredID = chats[botID]?.storedSessionID,
                  !boundStoredID.isEmpty else { return retainComposeItem() }
            expectedStoredID = boundStoredID
            expectedSessionID = sid
            guard owns(sid) else { return retainComposeItem() }
            let client = try await routedClient(for: route)
            guard owns(sid) else { return retainComposeItem() }
            guard preSubmitAdmission?() != false else { return .retained }
            preSubmitAdmitted = true
            submitStarted = true
            let receipt = try await client.submitPrompt(sessionID: sid, text: text)
            // Validate the wire receipt before consulting mutable UI ownership.
            // If Hermes authoritatively steered/redirected a busy turn and the
            // view changed in the same instant, replaying this text would run it
            // twice against a later turn.
            try LivePromptSubmitReceipt.requireAccepted(receipt, operation: "Prompt")
            guard owns(sid) else {
                // The gateway accepted while the local binding changed. Leave
                // the optimistic row to transcript reconciliation, but never
                // enqueue an accepted message for replay.
                ChatRuntime.shared.offlineComposeFences[operationComposeID] = nil
                return .accepted
            }
            ChatRuntime.shared.offlineComposeFences[operationComposeID] = nil
            return .accepted
        } catch let error as GatewayError where error.code == -3 || error.code == -7 {
            if submitStarted, let storedID = expectedStoredID {
                ChatRuntime.shared.offlineComposeFences[operationComposeID] =
                    OfflineComposeFence(itemID: operationComposeID, botID: botID, text: text,
                                       route: route, sessionID: expectedSessionID ?? "",
                                       storedID: storedID, chatID: chatID,
                                       baselineDurableUserRowIDs: baselineDurableUserRowIDs,
                                       baselineDurableUserRowIDWatermark:
                                           baselineDurableUserRowIDWatermark,
                                       baselineUndurableMatchingUserCount:
                                           baselineUndurableMatchingUserCount,
                                       baselineAuthorityKnown: baselineAuthorityKnown)
                return retainComposeItem()
            }
            guard owns() else { return retainComposeItem() }
            if GatewayBotRoute(qualifiedID: botID) == nil {
                // Primary link died mid-send — the bubble stays, the text
                // queues, and the supervised reconnect retries it. The queue
                // row is added only while the original binding still owns it.
                isOffline = true
                appendComposeQueue(botID: botID, text: text, id: operationComposeID,
                                   route: route, storedID: expectedStoredID,
                                   sessionID: expectedSessionID, chatID: chatID)
            } else {
                // A secondary failure must not mark the primary gateway
                // offline or silently enqueue work behind its reconnect.
                guard owns() else { return .retained }
                chat.messages.append(ChatMessage(author: .system, text: error.message))
            }
            return .failed
        } catch {
            if submitStarted, PromptMutationFailure.isAmbiguous(error),
               let storedID = expectedStoredID {
                ChatRuntime.shared.offlineComposeFences[operationComposeID] =
                    OfflineComposeFence(itemID: operationComposeID, botID: botID, text: text,
                                       route: route, sessionID: expectedSessionID ?? "",
                                       storedID: storedID, chatID: chatID,
                                       baselineDurableUserRowIDs: baselineDurableUserRowIDs,
                                       baselineDurableUserRowIDWatermark:
                                           baselineDurableUserRowIDWatermark,
                                       baselineUndurableMatchingUserCount:
                                           baselineUndurableMatchingUserCount,
                                       baselineAuthorityKnown: baselineAuthorityKnown)
                return retainComposeItem()
            }
            guard owns() else { return retainComposeItem() }
            let detail = (error as? GatewayError)?.message ?? error.localizedDescription
            chat.messages.append(ChatMessage(author: .system, text: detail))
            return .failed
        }
    }

    func liveResolveApproval(_ approval: Approval, approve: Bool) {
        Task { @MainActor in
            guard let target = approvalResponseTarget(
                for: approval, botRoute: gatewayRoute(for: approval.botID)),
                  let client = try? await routedClient(for: target.bot) else {
                restoreFailedApproval(approval)
                return
            }
            let runtime = LiveRuntime.shared
            do {
                try await client.respondToApproval(sessionID: target.session.sessionID,
                                                   choice: approve ? .once : .deny,
                                                   requestID: target.requestID)
                runtime.approvalTargets.removeValue(forKey: approval.id)
            } catch {
                // The request-to-session binding remains available for an
                // explicit retry/recovery path; never retarget after failure.
                restoreFailedApproval(approval)
            }
            recomputeStatus(for: approval.botID)
        }
    }

    func liveToggleRoutine(_ routine: Routine) {
        Task { @MainActor in
            guard let target = FeedsRuntime.shared.routineTargets[routine.id],
                  let client = try? await routedClient(gatewayID: target.route.gatewayID)
            else { return }
            try? await client.cronSetPaused(jobID: target.route.jobID,
                                            paused: !routine.isOn,
                                            profile: target.profile)
        }
    }

    // MARK: - Routines (Hermes cron)

    /// Legacy flat list used only by the canned demo world. Live refreshes must
    /// use `refreshRoutinesLive`, which folds source-qualified targets and
    /// refuses to infer ownership from a default or a title tag.
    public func refreshRoutines() async throws {
        guard CronRoutineRefreshAuthorityPolicy.allowsLegacyRefresh(mode: mode) else {
            return
        }
        guard let client else { return }
        let jobs = try await client.cronList()
        let fallback = LiveRuntime.shared.defaultBotID ?? bots.first?.id ?? "default"
        routines = jobs.map { job in
            var botID = fallback
            var name = job.name
            if job.name.hasPrefix("[bot:"), let close = job.name.firstIndex(of: "]") {
                botID = String(job.name.dropFirst(5).prefix(while: { $0 != "]" }))
                name = String(job.name[job.name.index(after: close)...])
                    .trimmingCharacters(in: .whitespaces)
            }
            return Routine(id: job.id, botID: botID, name: name, schedule: job.schedule,
                           next: Self.relativeNext(job.nextRun),
                           last: Self.shortTime(job.lastRun),
                           isOn: job.enabled)
        }
    }

    /// "in 22h 18m" — matches the design's next-run column.
    static func relativeNext(_ unix: Double?) -> String {
        guard let unix else { return "" }
        let delta = Int(unix - Date().timeIntervalSince1970)
        guard delta > 0 else { return "" }
        let d = delta / 86_400, h = (delta % 86_400) / 3600, m = (delta % 3600) / 60
        if d > 0 { return "in \(d)d \(h)h" }
        if h > 0 { return "in \(h)h \(m)m" }
        return "in \(max(m, 1))m"
    }

    // MARK: - Working state

    private func setWorking(_ botID: String, _ working: Bool) {
        let runtime = LiveRuntime.shared
        if working {
            runtime.workingBotIDs.insert(botID)
        } else {
            runtime.workingBotIDs.remove(botID)
        }
        if !working, let idx = bots.firstIndex(where: { $0.id == botID }) {
            bots[idx].task = nil
        }
        recomputeStatus(for: botID)
    }

    private func recomputeStatus(for botID: String) {
        guard let idx = bots.firstIndex(where: { $0.id == botID }) else { return }
        if approvals.contains(where: { $0.botID == botID }) {
            bots[idx].status = .approval
        } else if LiveRuntime.shared.workingBotIDs.contains(botID) {
            bots[idx].status = .working
        } else {
            bots[idx].status = .idle
        }
    }

    static func previewLine(_ text: String) -> String {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? text
        return firstLine.count > 120 ? String(firstLine.prefix(119)) + "…" : firstLine
    }

    // MARK: - Model / reasoning / YOLO controls (chat model strip)

    /// Switch the session model (live: config.set model, may defer mid-turn)
    /// and remember it as the bot's pin.
    public func setModel(botID: String, to modelID: String) {
        if let idx = bots.firstIndex(where: { $0.id == botID }) {
            bots[idx].pinnedModel = modelID
        }
        guard mode == .live else { return }
        Task { @MainActor in
            let sid = try? await ensureSession(botID: botID, hydrate: false)
            guard let sid, let route = gatewayRoute(for: botID),
                  let client = try? await routedClient(for: route) else { return }
            try? await client.setSessionModel(sessionID: sid, model: modelID)
        }
    }

    /// Session reasoning effort ("none"/"low"/"medium"/"high").
    public func setReasoningEffort(botID: String, to effort: String) {
        chat(for: botID).reasoningEffort = effort
        guard mode == .live else { return }
        Task { @MainActor in
            let sid = try? await ensureSession(botID: botID, hydrate: false)
            guard let sid, let route = gatewayRoute(for: botID),
                  let client = try? await routedClient(for: route) else { return }
            try? await client.setReasoningEffort(sessionID: sid, value: effort)
        }
    }

    /// Per-session YOLO toggle, wired through to the gateway when live.
    public func setYolo(botID: String, enabled: Bool) {
        chat(for: botID).yolo = enabled
        guard mode == .live else { return }
        Task { @MainActor in
            let sid = try? await ensureSession(botID: botID, hydrate: false)
            guard let sid, let route = gatewayRoute(for: botID),
                  let client = try? await routedClient(for: route) else { return }
            try? await client.setYolo(sessionID: sid, enabled: enabled)
        }
    }

    // The flat `availableModels()` that used to live here is superseded by the
    // typed catalog in AppModelLive+Models.swift, which keeps the same
    // signature for the profile editor's fallback path.

    // MARK: - Offline queue

    /// Coalesced trigger for reconnect, completion, foreground, and the
    /// explicit Queue control. A trigger while a pass owns the FIFO lanes asks
    /// for one follow-up pass rather than starting a duplicate submit.
    func requestComposeQueueFlush() {
        guard mode == .live else { return }
        guard !composeFlushActive else {
            composeFlushRequested = true
            return
        }
        Task { @MainActor [weak self] in
            await self?.flushComposeQueue()
        }
    }

    /// Drain only source-qualified durable rows. The compatibility tuples are
    /// merely a projection and are never their own submit authority.
    public func flushComposeQueue() async {
        guard mode == .live else { return }
        guard !composeFlushActive else {
            composeFlushRequested = true
            return
        }
        composeFlushActive = true
        defer {
            composeFlushActive = false
            if composeFlushRequested {
                composeFlushRequested = false
                Task { @MainActor [weak self] in
                    await self?.flushComposeQueue()
                }
            }
        }

        reloadDurableComposerQueueProjection()
        let readyKeys = durableComposerQueueEntries.compactMap { entry -> DurableComposerQueueKey? in
            entry.state == .localReady ? entry.key : nil
        }
        var seen = Set<DurableComposerQueueKey>()
        let keys = readyKeys.filter { seen.insert($0).inserted }
        await withTaskGroup(of: Void.self) { group in
            for key in keys {
                group.addTask { @MainActor [weak self] in
                    guard let self else { return }
                    _ = try? await DurableComposerQueueDrainLimiter.shared.withLane(for: key) {
                        await self.drainDurableComposerQueueKey(key)
                    }
                }
            }
            await group.waitForAll()
        }
        reloadDurableComposerQueueProjection()
        await drainLegacyComposeQueueUnderFlushOwnership()
    }

    /// Respect FIFO within one exact source session. Gateway-owned accepted
    /// rows have already crossed that ordering boundary, but parked,
    /// submitting, uncertain, exhausted, and edit-reserved rows stop the lane
    /// rather than allowing later local text to leapfrog them.
    private func drainDurableComposerQueueKey(_ key: DurableComposerQueueKey) async {
        while mode == .live {
            let rows = durableComposerQueueStore.entries(for: key)
            let reserved = Set(durableComposerQueueEditReservations.keys)
            guard let entry = DurableComposerQueuePolicy.nextFIFOEntry(
                rows, reservedIDs: reserved) else { return }
            // An editor reservation deliberately makes this exact FIFO head
            // non-drainable; it must not be skipped.
            guard claimDurableComposerEntry(id: entry.id) else { return }
            let result = await drainDurableComposerQueueEntry(entry)
            switch result {
            case .accepted:
                continue
            case .retained:
                return
            case .failed:
                do {
                    _ = try durableComposerQueueStore.recordAutomaticFailure(
                        id: entry.id, error: "Automatic queue delivery failed.")
                    reloadDurableComposerQueueProjection()
                } catch {
                    // A failure to persist the retry accounting is itself a
                    // retained result. Never loop and submit again against a
                    // store whose outcome is unknown.
                }
                // One definitive pre-wire refusal spends one automatic
                // attempt and yields the lane. Retrying four times in one
                // flush would turn a temporary 409 into immediate
                // retry-exhaustion and defeat reconnect/foreground pacing.
                return
            }
        }
    }

    /// A definitive pre-wire failure consumes the small automatic retry budget.
    /// Once `.submitting` is durably written, every ambiguous response becomes
    /// `.uncertain`; no later drain may replay it.
    private func drainDurableComposerQueueEntry(_ entry: DurableComposerQueueEntry)
        async -> LiveSendResult {
        guard durableComposerQueueStore.entry(id: entry.id)?.state == .localReady,
              durableComposerQueueClaims.contains(entry.id) else { return .retained }
        defer { releaseDurableComposerEntryClaim(entry.id) }
        if entry.key.gatewayID == LiveRuntime.shared.gatewayID, isOffline {
            return .retained
        }
        guard profileLifecycleAllowsGatewayTraffic(entry.key.gatewayID) else { return .retained }
        let lifecycleToken = profileLifecycleGenerationToken(
            for: entry.key.gatewayID == LiveRuntime.shared.gatewayID
                ? entry.key.profile : entry.key.route.qualifiedID)
        guard let lifecycleToken else { return .retained }
        let connectionGeneration = LiveRuntime.shared.generation
        let routedGeneration = MultiGatewayRuntime.shared.routedEventGenerations[
            entry.key.gatewayID] ?? 0

        let client: GatewayClient
        do {
            client = try await routedClient(for: entry.key.route)
        } catch {
            // A missing source client is not a prompt rejection. Keep the
            // exact FIFO head until that source reconnects instead of spending
            // its automatic retry budget while a secondary is asleep.
            return .retained
        }

        // Hold both the pool slot and ordinary profile-traffic admission from
        // the authoritative resume through the receipt. Generation checks are
        // defense in depth; the leases close the final TOCTOU gap with source
        // replacement, managed-cloud reconnect, or profile lifecycle work.
        let pooledSnapshot = await ConnectionRegistry.shared.clientPool
            .retainedConnectionSnapshots()
            .first(where: { $0.gatewayID == entry.key.gatewayID })?.connection
        if let pooledSnapshot {
            guard ObjectIdentifier(pooledSnapshot.client) == ObjectIdentifier(client) else {
                return .retained
            }
            do {
                let result = try await ConnectionRegistry.shared.clientPool
                    .withCommandConnectionAndTrafficLease(
                        pooledSnapshot, for: entry.key.gatewayID
                    ) { @MainActor [weak self] in
                        guard let self else { return LiveSendResult.retained }
                        return await self.drainDurableComposerQueueEntryUsingLeasedClient(
                            entry, client: client, lifecycleToken: lifecycleToken,
                            connectionGeneration: connectionGeneration,
                            routedGeneration: routedGeneration,
                            pooledSnapshot: pooledSnapshot)
                    }
                return result ?? .retained
            } catch {
                return .retained
            }
        }

        // Production clients are pooled. Keep this primary-only fallback for
        // an already-bound client that predates pool adoption (and focused
        // test harnesses); it still owns an ordinary traffic lease throughout
        // the source-qualified operation.
        guard entry.key.gatewayID == LiveRuntime.shared.gatewayID else { return .retained }
        do {
            guard let trafficLease = try await client.acquireTrafficLease() else {
                return .retained
            }
            let result = await drainDurableComposerQueueEntryUsingLeasedClient(
                entry, client: client, lifecycleToken: lifecycleToken,
                connectionGeneration: connectionGeneration,
                routedGeneration: routedGeneration, pooledSnapshot: nil)
            await trafficLease.release()
            return result
        } catch {
            return .retained
        }
    }

    /// Resume and submit while the caller holds source leases. A local row is
    /// made `.submitting` before its first wire boundary; every outcome after
    /// that boundary is accepted or fail-closed uncertain, never replayed.
    private func drainDurableComposerQueueEntryUsingLeasedClient(
        _ entry: DurableComposerQueueEntry, client: GatewayClient,
        lifecycleToken: ProfileLifecycleGenerationToken,
        connectionGeneration: Int, routedGeneration: UInt64,
        pooledSnapshot: GatewayClientPool.ConnectionSnapshot?
    ) async -> LiveSendResult {
        let live: LiveSession
        do {
            live = try await client.resumeSession(
                entry.key.storedSessionID, profile: entry.key.profile,
                deferHistory: true)
        } catch {
            // The authoritative read did not settle. It does not authorize a
            // retry into another source or consume a local automatic attempt.
            return .retained
        }
        guard await durableDrainAuthorityMatches(
            entry.key, client: client, lifecycleToken: lifecycleToken,
            connectionGeneration: connectionGeneration,
            routedGeneration: routedGeneration, pooledSnapshot: pooledSnapshot) else {
            return .retained
        }
        // A Queue row is keyed by the stored session, not by the runtime id
        // returned by resume. An omitted stored id is not proof that the
        // gateway resumed the requested session; accepting it would allow a
        // fallback/default session to receive this prompt. Require a
        // non-empty exact match before any prompt-submit wire boundary.
        guard !live.storedSessionID.isEmpty,
              live.storedSessionID == entry.key.storedSessionID,
              !live.sessionID.isEmpty else {
            markDurableQueueEntryUncertain(entry.id,
                "The gateway returned a different durable session; this prompt will not replay automatically.")
            return .retained
        }
        // This authoritative stored-session result, not a stale visible
        // ChatState, decides when an explicit Queue row may cross the wire.
        guard DurableComposerQueuePolicy.shouldAutoDrain(
            state: entry.state,
            isTurnRunning: live.running || live.hasInflightTurn
                || live.pendingApproval != nil || live.pendingClarify != nil) else {
            return .retained
        }
        do {
            try durableComposerQueueStore.markSubmitting(id: entry.id)
            reloadDurableComposerQueueProjection()
        } catch {
            return .retained
        }
        guard await durableDrainAuthorityMatches(
            entry.key, client: client, lifecycleToken: lifecycleToken,
            connectionGeneration: connectionGeneration,
            routedGeneration: routedGeneration, pooledSnapshot: pooledSnapshot) else {
            markDurableQueueEntryUncertain(entry.id,
                "The source changed while this prompt was being prepared; it will not replay automatically.")
            return .retained
        }
        registerDurableComposerWireSubmission(
            id: entry.id, key: entry.key, runtimeSessionID: live.sessionID)
        do {
            let receipt = try await client.submitPrompt(
                sessionID: live.sessionID, text: entry.text, queued: true)
            try LivePromptSubmitReceipt.requireAccepted(receipt, operation: "Queued prompt")
            let startedBeforeReceipt = finishDurableComposerWireSubmission(id: entry.id)
            if startedBeforeReceipt {
                try durableComposerQueueStore.removeSubmittingForExecution(id: entry.id)
                reloadDurableComposerQueueProjection()
                return .accepted
            }
            guard await durableDrainAuthorityMatches(
                entry.key, client: client, lifecycleToken: lifecycleToken,
                connectionGeneration: connectionGeneration,
                routedGeneration: routedGeneration, pooledSnapshot: pooledSnapshot) else {
                markDurableQueueEntryUncertain(entry.id,
                    "The source changed while the gateway receipt was in flight; it will not replay automatically.")
                return .retained
            }
            try durableComposerQueueStore.markAcceptedGatewayOwned(id: entry.id)
            reloadDurableComposerQueueProjection()
            if let botID = visibleBotID(for: entry.key),
               let chat = chats[botID], chat.storedSessionID == entry.key.storedSessionID {
                acceptLocalQueueEntry(id: entry.id, text: entry.text, botID: botID, chat: chat)
            }
            return .accepted
        } catch let error as GatewayError where error.code == 409 {
            if finishDurableComposerWireSubmission(id: entry.id) {
                do {
                    try durableComposerQueueStore.removeSubmittingForExecution(id: entry.id)
                    reloadDurableComposerQueueProjection()
                    return .accepted
                } catch {
                    markDurableQueueEntryUncertain(entry.id,
                        "The gateway started this prompt, but local execution proof could not be saved.")
                    return .retained
                }
            }
            do {
                try durableComposerQueueStore.markLocalReady(id: entry.id, error: error.message)
                reloadDurableComposerQueueProjection()
                return .failed
            } catch {
                return .retained
            }
        } catch {
            if finishDurableComposerWireSubmission(id: entry.id) {
                do {
                    try durableComposerQueueStore.removeSubmittingForExecution(id: entry.id)
                    reloadDurableComposerQueueProjection()
                    return .accepted
                } catch {
                    markDurableQueueEntryUncertain(entry.id,
                        "The gateway started this prompt, but local execution proof could not be saved.")
                    return .retained
                }
            }
            markDurableQueueEntryUncertain(entry.id,
                "The gateway may have accepted this prompt; it will not replay automatically.")
            return .retained
        }
    }

    private func durableDrainAuthorityMatches(
        _ key: DurableComposerQueueKey, client: GatewayClient,
        lifecycleToken: ProfileLifecycleGenerationToken,
        connectionGeneration: Int, routedGeneration: UInt64,
        pooledSnapshot: GatewayClientPool.ConnectionSnapshot?
    ) async -> Bool {
        guard lifecycleToken.route == key.route,
              profileLifecycleAccepts(lifecycleToken),
              profileLifecycleAllowsGatewayTraffic(key.gatewayID) else {
            return false
        }
        if key.gatewayID == LiveRuntime.shared.gatewayID {
            return LiveRuntime.shared.generation == connectionGeneration
                && self.client.map(ObjectIdentifier.init) == ObjectIdentifier(client)
        }
        guard MultiGatewayRuntime.shared.routedEventGenerations[key.gatewayID]
                == routedGeneration,
              let pooledSnapshot else { return false }
        let current = await ConnectionRegistry.shared.clientPool
            .retainedConnectionSnapshots()
            .first(where: { $0.gatewayID == key.gatewayID })?.connection
        return current?.generation == pooledSnapshot.generation
            && current.map({ ObjectIdentifier($0.client) }) == ObjectIdentifier(client)
    }

    private func markDurableQueueEntryUncertain(_ id: UUID, _ message: String) {
        try? durableComposerQueueStore.markUncertain(id: id, error: message)
        reloadDurableComposerQueueProjection()
    }

    private func visibleBotID(for key: DurableComposerQueueKey) -> String? {
        chats.first { botID, chat in
            (stateRoute(for: botID) ?? gatewayRoute(for: botID)) == key.route
                && chat.storedSessionID == key.storedSessionID
        }?.key
    }

    /// Legacy optimistic rows are retained only for older callers that have
    /// not yet supplied a source-qualified durable key. New compose paths use
    /// `flushComposeQueue()` below and never call this fallback.
    private func drainLegacyComposeQueueUnderFlushOwnership() async {
        guard !composeQueue.isEmpty, mode == .live, !isOffline else { return }
        normalizeComposeQueueIDs()
        // Process one exact tuple at a time. Removing the whole array before
        // the first await used to lose every row when a route/fence changed or
        // the socket failed; a successful send now removes only the tuple that
        // is still at that index with the same identity.
        while let index = composeQueueIDs.firstIndex(where: {
            durableComposerQueueStore.entry(id: $0) == nil
        }) {
            guard mode == .live, !isOffline else { return }
            let item = composeQueue[index]
            let itemID = composeQueueIDs[index]
            if ChatRuntime.shared.offlineComposeFences[itemID] != nil {
                return
            }
            guard let chat = chats[item.botID] else {
                // An absent ChatState cannot prove the optimistic owner. Keep
                // the row quarantined for the next authoritative bind.
                return
            }
            if let binding = composeQueueBindings[itemID] {
                let currentRoute = stateRoute(for: item.botID) ?? gatewayRoute(for: item.botID)
                guard binding.botID == item.botID,
                      (binding.route.map { bindingRouteMatches($0, botID: item.botID) }
                       ?? (currentRoute != nil)),
                      binding.storedID == chat.storedSessionID,
                      binding.sessionID == nil || binding.sessionID == chat.sessionID,
                      binding.chatID == nil || binding.chatID == ObjectIdentifier(chat) else {
                    return
                }
            } else {
                // Rows created by legacy callers have no proof of ownership.
                // Do not submit them into a newly replaced ChatState.
                guard chat.messages.contains(where: { $0.author == .user && $0.text == item.text }) else {
                    return
                }
            }
            let result = await liveSendAwaiting(
                text: item.text, botID: item.botID, chat: chat,
                composeItemID: itemID)
            guard composeQueue.indices.contains(index),
                  composeQueueIDs.indices.contains(index),
                  composeQueueIDs[index] == itemID,
                  composeQueue[index].botID == item.botID,
                  composeQueue[index].text == item.text else {
                // Lifecycle/reconnect may have re-keyed or replaced the
                // queue while the RPC was suspended. Never remove a row we
                // did not submit under the exact captured binding.
                if result == .accepted { continue }
                return
            }
            switch result {
            case .accepted:
                composeQueue.remove(at: index)
                composeQueueIDs.remove(at: index)
                composeQueueBindings[itemID] = nil
            case .retained, .failed:
                return
            }
        }
    }

    /// An authoritative durable user row proves this exact ambiguous prompt
    /// was delivered. Retire every local replay surface atomically so neither
    /// reconnect nor queue flush can submit it a second time.
    func retireProvenOfflineCompose(_ fence: OfflineComposeFence, running: Bool,
                                    retainedInflight: RetainedInflightTurn? = nil,
                                    authoritativeRows: [ChatMessage]? = nil) {
        guard ChatRuntime.shared.offlineComposeFences[fence.itemID] == fence else { return }
        if let retryLease = ChatRuntime.shared.failedRetryRows[fence.botID],
           retryLease.token == fence.itemID {
            guard retryLease.phase != .prepared,
                  retryLease.route == fence.route,
                  retryLease.storedID == fence.storedID,
                  retryLease.chatID == fence.chatID,
                  settleProvenFailedRetryLease(
                      retryLease, botID: fence.botID, running: running,
                      retainedInflight: retainedInflight,
                      authoritativeRows: authoritativeRows) else {
                // Retry-backed compose state is one transaction. If the
                // leased assistant cannot be settled, preserve every replay
                // and ownership surface for a later authoritative attempt.
                return
            }
        }
        // A legacy ambiguous tuple may already have been imported into the
        // durable store as `.uncertain`. The authoritative proof above is the
        // one safe time to clear that exact no-replay record; if persistence
        // fails, retain every in-memory fence rather than reopening replay.
        if durableComposerQueueStore.entry(id: fence.itemID)?.state == .uncertain {
            do {
                try durableComposerQueueStore.removeUncertain(id: fence.itemID)
                reloadDurableComposerQueueProjection()
            } catch {
                return
            }
        }
        normalizeComposeQueueIDs()
        if let index = composeQueueIDs.indices.first(where: { index in
            composeQueueIDs[index] == fence.itemID
                && composeQueue.indices.contains(index)
                && composeQueue[index].botID == fence.botID
                && composeQueue[index].text == fence.text
        }) {
            composeQueue.remove(at: index)
            composeQueueIDs.remove(at: index)
        }
        composeQueueBindings[fence.itemID] = nil
        ChatRuntime.shared.offlineComposeFences[fence.itemID] = nil
    }

    @discardableResult
    func reconcileFailedRetryLeaseFromAuthority(
        _ lease: FailedTurnRetryLease, botID: String,
        rows: [ChatMessage], running: Bool,
        retainedInflight: RetainedInflightTurn? = nil
    ) -> Bool {
        guard let current = ChatRuntime.shared.failedRetryRows[botID],
              current.token == lease.token, current.phase != .prepared,
              current.route == lease.route, current.storedID == lease.storedID,
              current.chatID == lease.chatID,
              gatewayRoute(for: botID) == lease.route,
              chats[botID].map({ ObjectIdentifier($0) == lease.chatID }) == true,
              chats[botID]?.sessionID == current.sessionID,
              chats[botID]?.storedSessionID == lease.storedID,
              Self.provesFailedRetryDelivery(lease, rows: rows) else { return false }
        return settleProvenFailedRetryLease(
            current, botID: botID, running: running,
            retainedInflight: retainedInflight, authoritativeRows: rows)
    }

    @discardableResult
    private func settleProvenFailedRetryLease(_ lease: FailedTurnRetryLease,
                                              botID: String, running: Bool,
                                              retainedInflight: RetainedInflightTurn?,
                                              authoritativeRows: [ChatMessage]?) -> Bool {
        guard let currentLease = ChatRuntime.shared.failedRetryRows[botID],
              currentLease.token == lease.token, currentLease == lease,
              let chat = chats[botID], ObjectIdentifier(chat) == lease.chatID,
              let index = chat.messages.firstIndex(where: { row in
                  guard row.id == lease.assistantID else { return false }
                  switch lease.phase {
                  case .prepared:
                      return false
                  case .submitting:
                      return row.text == lease.baselineText
                          && row.failure == lease.baselineFailure
                  case .started:
                      return row.failure == nil && row.isStreaming
                  }
              }) else { return false }
        let baseline = chat.messages
        let retainedFailure = retainedInflight.flatMap(TurnFailureLifecycle.failure(from:))
        let retainedText = retainedInflight.map {
            TurnFailureLifecycle.admittedMessage($0.assistant)
        } ?? ""
        let retainedIsFresh = retainedInflight.map {
            $0.streaming || retainedText != lease.baselineText
                || retainedFailure != lease.baselineFailure
        } ?? false
        if let retainedInflight, retainedIsFresh {
            chat.messages[index].text = retainedText
            chat.messages[index].reasoning = nil
            chat.messages[index].toolCalls = []
            chat.messages[index].card = nil
            chat.messages[index].failure = retainedFailure
            chat.messages[index].isStreaming = retainedInflight.streaming
        } else {
            chat.messages.remove(at: index)
        }
        let authoritativeCandidates = retainedIsFresh
            ? chat.messages.filter({ $0.id == lease.assistantID }) : []
        let chatID = ObjectIdentifier(chat)
        if ChatRuntime.shared.retainedFailureRows[chatID]?.contains(lease.assistantID) == true {
            // The set protects the entire old failed turn (user + assistant).
            // Authority now contains that turn, so carrying any member as a
            // live candidate would append a duplicate after the durable page.
            ChatRuntime.shared.retainedFailureRows[chatID] = nil
        }
        if retainedFailure != nil {
            ChatRuntime.shared.retainedFailureRows[chatID, default: []]
                .insert(lease.assistantID)
        }
        if let authoritativeRows, !authoritativeRows.isEmpty {
            let protected = ChatRuntime.shared.retainedFailureRows[chatID] ?? []
            chat.messages = TranscriptHydrationMerge.merge(
                history: authoritativeRows, baseline: baseline,
                current: authoritativeCandidates, clearWhenEmpty: true,
                protectedIDs: protected)
        }
        // Clear ownership only after the exact phase-owned row was found and
        // its retained/durable projection completed successfully.
        ChatRuntime.shared.failedRetryRows[botID] = nil
        chat.hasUnresolvedRetry = false
        ChatRuntime.shared.submitWatchdogs[botID]?.cancel()
        ChatRuntime.shared.submitWatchdogs[botID] = nil
        chat.isRunning = running
        return true
    }

    static func provesOfflineComposeDelivery(_ fence: OfflineComposeFence,
                                             rows: [ChatMessage]) -> Bool {
        guard fence.baselineDurableUserRowIDWatermark != nil
                || fence.baselineAuthorityKnown else { return false }
        let watermark = fence.baselineDurableUserRowIDWatermark
        let postBaseline = Set(rows.compactMap { row -> Int? in
            guard row.author == .user, row.text == fence.text,
                  let rowID = row.rowID,
                  watermark.map({ rowID > $0 }) ?? true else { return nil }
            return rowID
        })
        return postBaseline.count > fence.baselineUndurableMatchingUserCount
    }

    static func provesFailedRetryDelivery(_ lease: FailedTurnRetryLease,
                                          rows: [ChatMessage]) -> Bool {
        guard lease.authoritativeBaselineKnown else { return false }
        let watermark = lease.baselineDurableUserRowIDWatermark
        let postBaseline = Set(rows.compactMap { row -> Int? in
            guard row.author == .user, row.text == lease.promptText,
                  let rowID = row.rowID,
                  watermark.map({ rowID > $0 }) ?? true else { return nil }
            return rowID
        })
        return postBaseline.count > lease.baselineUndurableMatchingUserCount
    }
}
