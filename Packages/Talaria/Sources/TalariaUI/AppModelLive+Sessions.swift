import Foundation
import TalariaKit
import TalariaTheme

@MainActor
private final class LegacySessionOwnerBackfillCoordinator {
    static let shared = LegacySessionOwnerBackfillCoordinator()

    private var attemptedScopes: Set<String> = []

    func begin(gatewayID: String, profile: String) -> Bool {
        let key = Self.key(gatewayID: gatewayID, profile: profile)
        return attemptedScopes.insert(key).inserted
    }

    func rearm(gatewayID: String, profile: String) {
        attemptedScopes.remove(Self.key(gatewayID: gatewayID, profile: profile))
    }

    private static func key(gatewayID: String, profile: String) -> String {
        gatewayID + "\u{1f}" + profile
    }
}

// The live sessions area: the bot's stored-session list, the context
// breakdown, opening a stored session in chat, the row actions (rename,
// delete), the turn controls (branch, compress, export) and cross-session
// search.
//
// Two ids matter throughout and must never be mixed up (ws-protocol.md §5,
// §7.3): the RUNTIME sid (8 hex, routes events, addresses live-session RPCs)
// and the DURABLE key (`stored_session_id` / `session_key`, addresses the DB
// row and survives reconnects). Session lists, resume, delete and the
// session.title EVENT all speak the durable key; branch/compress/save and the
// session.title RPC all speak the runtime sid.

/// Side table for the sessions area. `AppModel`'s stored properties live in
/// AppModel.swift (another owner) and extensions cannot add storage, so the
/// per-session extras Talaria's shared models don't carry ride here.
@MainActor
final class SessionsRuntime {
    static let shared = SessionsRuntime()

    /// Durable key → freshest title. The session.title event can land before
    /// (or after) any list fetch, so it is kept as an overlay and re-applied
    /// on every refresh instead of being lost between them.
    var titles: [String: String] = [:]
    /// Durable key → preview line. `SessionSummary` has no preview field and
    /// is shared with other screens, so the sheet reads previews from here.
    var previews: [String: String] = [:]
    /// bot id → why the last list fetch failed (nil once one succeeds).
    var loadErrors: [String: String] = [:]

    /// Bot id → explicit stored-session selection generation. Cancelling a
    /// task is not enough to fence a WebSocket/REST reply that was already on
    /// the wire, so every completion also proves it still owns the selection.
    var openGenerations: [String: UInt64] = [:]

    /// The extra event handler behind `attachSessionEventRouter()`, and the
    /// client it is registered on. A reconnect re-dials the transport but
    /// keeps the same `GatewayClient` (and its handler table); only a new
    /// gateway link needs re-arming, which is what this identity check buys.
    var handlerID: UUID?
    weak var attachedClient: GatewayClient?
    var routerTask: Task<Void, Never>?
    /// Debounce for the `sessions.changed` broadcast.
    var refreshTask: Task<Void, Never>?
    /// Focused transaction seam: force the synchronous visible-adoption
    /// boundary to fail after a staged routed swap, without touching ordinary
    /// manual/session paths.
    var beginFailureForTesting: Error?
    /// Runs after the final pool identity await and before the synchronous
    /// source/lifecycle fence. Tests use this to model a profile mutation
    /// winning during that actor hop.
    var sourceFenceAfterPoolCheckForTesting: (@MainActor () async -> Void)?
    /// Holds an exact-open pool lease in deterministic teardown tests. The
    /// production path has no pause here; the seam makes sign-out/remove race
    /// ordering explicit without opening a real gateway socket.
    var exactOpenAfterPoolLeaseForTesting: (@MainActor (String) async -> Void)?
    /// Lower-wire seams that keep exact-open transaction and authority logic
    /// intact in focused races without requiring a live Hermes transport.
    var exactOpenProfilesForTesting:
        (@MainActor (GatewayClient, ExactStoredSessionRoute) async throws -> [HermesProfile])?
    var exactOpenResumeForTesting:
        (@MainActor (GatewayClient, ExactStoredSessionRoute) async throws -> LiveSession)?
    /// Lower network-boundary seam for exact-source list recovery tests. The
    /// production authority checks and publication path remain intact.
    var listSessionsForTesting:
        (@MainActor (GatewayClient, String) async throws -> [StoredSession])?

    static func key(botID: String, sessionID: String) -> String {
        botID + "\u{0}" + sessionID
    }

    func beginOpen(botID: String) -> UInt64 {
        openGenerations[botID, default: 0] &+= 1
        return openGenerations[botID, default: 0]
    }

    func acceptsOpen(botID: String, generation: UInt64) -> Bool {
        openGenerations[botID] == generation
    }

    private static func botID(from key: String) -> String {
        String(key.prefix { $0 != "\u{0}" })
    }

    func resetPrimaryScope() {
        titles = titles.filter { GatewayBotRoute(qualifiedID: Self.botID(from: $0.key)) != nil }
        previews = previews.filter { GatewayBotRoute(qualifiedID: Self.botID(from: $0.key)) != nil }
        loadErrors = loadErrors.filter { GatewayBotRoute(qualifiedID: $0.key) != nil }
        refreshTask?.cancel()
        refreshTask = nil
    }

    func resetRoutedScope(gatewayID: String) {
        let prefix = gatewayID + GatewayBotRoute.separator
        titles = titles.filter { !Self.botID(from: $0.key).hasPrefix(prefix) }
        previews = previews.filter { !Self.botID(from: $0.key).hasPrefix(prefix) }
        loadErrors = loadErrors.filter { !$0.key.hasPrefix(prefix) }
    }
}

private struct StoredSessionOpenSource {
    var route: GatewayBotRoute
    var client: GatewayClient
    /// A fully authority-checked resume projection. Exact notification/deep-
    /// link opens obtain this before visible navigation or transcript state is
    /// changed.
    var resumed: LiveSession
}

private struct ExactStoredSessionSourceFence {
    var route: GatewayBotRoute
    var botID: String
    var client: GatewayClient
    var lifecycle: ProfileLifecycleGenerationToken
    var connectionGeneration: Int
    var savedURLString: String?
    var snapshot: GatewayClientPool.ConnectionSnapshot?
}

private struct StoredSessionOpenAttempt {
    var task: Task<String, Error>
    var botID: String
    var chat: ChatState
    var lifecycle: ProfileLifecycleGenerationToken
    var openGeneration: UInt64
    var connectionGeneration: Int
}

/// Immutable authority for publishing a session-list reconciliation from one
/// captured source. Foreign sources cannot use `AppModel.client` identity —
/// that is the primary — so their captured pool generation is load-bearing.
struct ExactSessionListRefreshAuthority {
    var route: GatewayBotRoute
    var client: GatewayClient
    var snapshot: GatewayClientPool.ConnectionSnapshot
    var lifecycle: ProfileLifecycleGenerationToken
    var connectionGeneration: Int
    var savedURLString: String
    var wasPrimary: Bool
    var chatID: ObjectIdentifier
    var sessionID: String
    var storedSessionID: String
}

private struct ExactSessionControlLease {
    var claim: SessionControlMutationClaim
    var lifecycle: ProfileLifecycleGenerationToken
    var chatID: ObjectIdentifier
    var connectionGeneration: Int
}

/// The result of a session action, ready to render as one themed line plus an
/// optional detail line.
public struct SessionActionOutcome: Sendable, Equatable {
    public var ok: Bool
    public var headline: String
    public var detail: String?

    public init(ok: Bool, headline: String, detail: String? = nil) {
        self.ok = ok; self.headline = headline; self.detail = detail
    }
}

extension AppModel {

    // MARK: - Listing

    /// Load this bot's stored sessions (session.list {limit:200, profile,
    /// include_hidden}) into `ChatState.storedSessions`. Demo mode serves the
    /// canned index so the sheet is never empty in the App Review walkthrough.
    ///
    /// `include_hidden` because this is the per-bot browser — the one surface
    /// that OWNS hidden sessions, which is exactly the case upstream carves
    /// the flag out for (methods_session.py:180-186; desktop's Bots pane does
    /// the same). Bot Mode sessions, the canonical forever-chat among them,
    /// are always hidden; without the flag a bot's own chat is missing from
    /// its own session list.
    public func refreshSessions(botID: String) async {
        let runtime = SessionsRuntime.shared
        guard mode == .live else {
            chat(for: botID).storedSessions = sessions[botID] ?? sessions["default"] ?? []
            runtime.loadErrors[botID] = nil
            return
        }
        guard let lifecycle = profileLifecycleGenerationToken(for: botID),
              let route = gatewayRoute(for: botID),
              let client = try? await routedClient(for: route) else {
            if profileLifecycleGenerationToken(for: botID) != nil {
                runtime.loadErrors[botID] = theme.copy.sessUnreachable(theme.themeID)
            }
            return
        }
        let generation = LiveRuntime.shared.generation
        let chatID = ObjectIdentifier(chat(for: botID))
        guard profileLifecycleAccepts(lifecycle) else { return }
        do {
            let rows = try await client.listSessions(limit: 200, profile: route.profile,
                                                     includeHidden: true)
            guard profileLifecycleAccepts(lifecycle),
                  LiveRuntime.shared.generation == generation,
                  gatewayRoute(for: botID) == route,
                  self.client.map(ObjectIdentifier.init) == ObjectIdentifier(client),
                  chats[botID].map({ ObjectIdentifier($0) == chatID }) == true else { return }
            publishSessionRows(rows, botID: botID)
            scheduleLegacySessionOwnerBackfill(client: client, route: route)
        } catch {
            guard profileLifecycleAccepts(lifecycle) else { return }
            runtime.loadErrors[botID] = Self.sessionFailure(error, theme: theme)
        }
    }

    /// Reconcile the session list through the exact source already used by a
    /// mutation. This is the recovery path after an ambiguous branch receipt
    /// or a created child that could not be opened. It never re-resolves the
    /// client through the active primary and therefore works for foreign bots.
    @discardableResult
    func refreshSessionsFromExactSource(
        botID: String, authority: ExactSessionListRefreshAuthority
    ) async -> Bool {
        let runtime = SessionsRuntime.shared
        guard await exactSessionListRefreshIsCurrent(
            botID: botID, authority: authority) else { return false }
        do {
            let rows: [StoredSession]
            if let override = runtime.listSessionsForTesting {
                rows = try await override(authority.client, authority.route.profile)
            } else {
                rows = try await authority.client.listSessions(
                    limit: 200, profile: authority.route.profile, includeHidden: true)
            }
            guard await exactSessionListRefreshIsCurrent(
                botID: botID, authority: authority) else { return false }
            publishSessionRows(rows, botID: botID)
            scheduleLegacySessionOwnerBackfill(
                client: authority.client, route: authority.route)
            return true
        } catch {
            guard await exactSessionListRefreshIsCurrent(
                botID: botID, authority: authority) else { return false }
            runtime.loadErrors[botID] = Self.sessionFailure(error, theme: theme)
            return false
        }
    }

    private func exactSessionListRefreshIsCurrent(
        botID: String, authority: ExactSessionListRefreshAuthority
    ) async -> Bool {
        guard await ConnectionRegistry.shared.clientPool.isCurrent(
            authority.snapshot, for: authority.route.gatewayID) else { return false }
        let nowPrimary = authority.route.gatewayID == activeGatewayID
        let expectedBotID = nowPrimary
            ? authority.route.profile : authority.route.qualifiedID
        guard mode == .live,
              nowPrimary == authority.wasPrimary,
              botID == expectedBotID,
              gatewayRoute(for: botID) == authority.route,
              stateRoute(for: botID) == authority.route,
              profileLifecycleAccepts(authority.lifecycle),
              !exactStoredSessionSourceIsInvalidated(
                gatewayID: authority.route.gatewayID),
              let saved = ConnectionRegistry.shared.saved.first(where: {
                  $0.id == authority.route.gatewayID
                    && $0.urlString == authority.savedURLString
              }), ConnectionRegistry.shared.credential(for: saved) != nil,
              let chat = chats[botID],
              ObjectIdentifier(chat) == authority.chatID,
              chat.sessionID == authority.sessionID,
              chat.storedSessionID == authority.storedSessionID else { return false }
        if nowPrimary {
            guard LiveRuntime.shared.generation == authority.connectionGeneration,
                  client.map(ObjectIdentifier.init)
                    == ObjectIdentifier(authority.client) else { return false }
        }
        return true
    }

    private func publishSessionRows(_ rows: [StoredSession], botID: String) {
        let runtime = SessionsRuntime.shared
        var summaries: [SessionSummary] = []
        summaries.reserveCapacity(rows.count)
        for row in rows where !row.id.isEmpty {
            let preview = (row.preview ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let key = SessionsRuntime.key(botID: botID, sessionID: row.id)
            runtime.previews[key] = preview.isEmpty ? nil : preview
            // The event overlay wins: an auto-title that landed since the
            // list was built is newer than the row we just fetched.
            let title = runtime.titles[key]
                ?? (row.title.isEmpty
                    ? GatewayClient.fallbackTitle(id: row.id, preview: preview)
                    : row.title)
            summaries.append(SessionSummary(
                id: row.id, title: title, when: SessionClock.stamp(row.startedAt),
                messageCount: row.messageCount))
        }
        chat(for: botID).storedSessions = summaries
        // The bot sheet's "Recent sessions" group reads `sessions[botID]`
        // (the demo-shaped index) — keep both in step so it goes live too.
        sessions[botID] = summaries
        runtime.loadErrors[botID] = nil
    }

    /// Enumeration proves the exact serving gateway/profile. Under a real
    /// registry topology, ask that backend once to stamp only its own legacy
    /// NULL-owner rows. The migration never blocks or fails the list that
    /// discovered it; 404 is permanent version skew, while transient failures
    /// re-arm the scope for a later refresh.
    private func scheduleLegacySessionOwnerBackfill(
        client: GatewayClient, route: GatewayBotRoute
    ) {
        let registry = ConnectionRegistry.shared
        guard registry.saved.count > 1,
              registry.saved.contains(where: { $0.id == route.gatewayID }),
              LegacySessionOwnerBackfillCoordinator.shared.begin(
                gatewayID: route.gatewayID, profile: route.profile) else { return }
        Task { @MainActor in
            do {
                _ = try await client.backfillLegacySessionOwners(profile: route.profile)
            } catch let error as GatewayError where error.code == 404 {
                // An older Hermes does not expose the migration. Keep this
                // scope attempted for the process lifetime; repeated probes
                // cannot make the endpoint appear.
            } catch {
                LegacySessionOwnerBackfillCoordinator.shared.rearm(
                    gatewayID: route.gatewayID, profile: route.profile)
            }
        }
    }

    /// Why the last `refreshSessions` failed, in the current theme's voice.
    public func sessionsLoadError(for botID: String) -> String? {
        SessionsRuntime.shared.loadErrors[botID]
    }

    /// The stored session's first transcript line, when session.list carried
    /// one. Session rows show it under the title.
    public func sessionPreview(_ sessionID: String, botID: String) -> String? {
        SessionsRuntime.shared.previews[SessionsRuntime.key(botID: botID, sessionID: sessionID)]
    }

    // MARK: - Context breakdown

    /// session.context_breakdown → `ChatState.contextSegments`. Deliberately
    /// does NOT mint a session: opening a bot sheet to look at it must not
    /// create a conversation, so a bot with no live session simply reports
    /// nothing to measure.
    public func refreshContext(botID: String) async {
        guard mode == .live else {
            chat(for: botID).contextSegments = contextMeter
            return
        }
        guard let lifecycle = profileLifecycleGenerationToken(for: botID),
              let route = gatewayRoute(for: botID),
              let client = try? await routedClient(for: route),
              let sid = chats[botID]?.sessionID else {
            chat(for: botID).contextSegments = []
            return
        }
        guard profileLifecycleAccepts(lifecycle) else { return }
        let generation = LiveRuntime.shared.generation
        let chatID = ObjectIdentifier(chat(for: botID))
        guard let segments = try? await client.contextBreakdown(sid) else { return }
        guard profileLifecycleAccepts(lifecycle),
              LiveRuntime.shared.generation == generation,
              gatewayRoute(for: botID) == route,
              self.client.map(ObjectIdentifier.init) == ObjectIdentifier(client),
              chats[botID].map({ ObjectIdentifier($0) == chatID }) == true,
              chats[botID]?.sessionID == sid else { return }
        chat(for: botID).contextSegments = segments
        // The bot sheet's meter reads the global `contextMeter`; it only ever
        // shows the bot whose sheet is open, so mirroring is correct.
        contextMeter = segments
    }

    // MARK: - Opening a stored session

    /// Rebind this bot's chat onto a stored session (session.resume by
    /// durable key) and hydrate its transcript. Mirrors `openChat` but for a
    /// session the user picked instead of the profile's most recent one.
    public func openStoredSession(_ id: String, botID: String) {
        guard let attempt = try? beginStoredSessionOpen(
            id, botID: botID, exactSource: nil
        ) else { return }
        Task { @MainActor in
            _ = try? await finishStoredSessionOpen(attempt, presentsFailure: true)
        }
    }

    /// Await one explicit durable-session selection on an already captured
    /// route/client. Workspace Projects uses this while its pool and profile
    /// lifecycle leases are still held, so no later task may re-resolve the
    /// destination through mutable active-gateway state.
    @discardableResult
    func openStoredSessionAwaiting(
        _ id: String, botID: String, route: GatewayBotRoute,
        client: GatewayClient,
        validateBeforeBinding: @escaping @MainActor () async throws -> Void,
        validateImmediatelyBeforeBinding:
            (@MainActor () async throws -> Void)? = nil,
        resumeForTesting: (@MainActor () async throws -> LiveSession)? = nil,
        catchUpResumeForTesting:
            (@MainActor () async throws -> (LiveSession, UInt64))? = nil,
        sourceSnapshot: GatewayClientPool.ConnectionSnapshot? = nil
    ) async throws -> Bool {
        guard !id.isEmpty else {
            throw GatewayError(code: 400, message: "A stored session identity is required.")
        }
        guard let lifecycle = profileLifecycleGenerationToken(for: botID),
              lifecycle.route == route else {
            throw CancellationError()
        }
        let sourceFence = ExactStoredSessionSourceFence(
            route: route, botID: botID, client: client, lifecycle: lifecycle,
            connectionGeneration: LiveRuntime.shared.generation,
            savedURLString: ConnectionRegistry.shared.saved.first {
                $0.id == route.gatewayID
            }?.urlString,
            snapshot: sourceSnapshot)
        // Exact out-of-process navigation is transactional at the visible-state
        // boundary. Resume and validate both durable/profile identity and the
        // caller's fresh source authority before `beginStoredSessionOpen`
        // clears the current chat, unread mark, or navigation selection.
        let isPrimaryRoute = route.gatewayID == activeGatewayID
        let prepared = await prepareExactRoutedEvents(
            client: client, gatewayID: route.gatewayID)
        let resumed: (session: LiveSession, inboundSequence: UInt64)
        do {
            if !isPrimaryRoute {
                // A new/replacement secondary must stage before this ONE
                // authoritative sequenced resume. Every event from the first
                // response request onward is therefore buffered for the later
                // snapshot-boundary replay.
                guard prepared != nil else {
                    // A foreign exact route never falls back to the legacy
                    // unsequenced resume: without staged intake there is no
                    // safe handoff authority.
                    throw CancellationError()
                }
                if let catchUpResumeForTesting {
                    resumed = try await catchUpResumeForTesting()
                } else if let resumeForTesting {
                    resumed = (try await resumeForTesting(), 0)
                } else {
                    let result = try await client.resumeSessionSequenced(
                        id, profile: route.profile, deferHistory: false)
                    resumed = (result.session, result.inboundSequence)
                }
            } else if let resumeForTesting {
                resumed = (try await resumeForTesting(), 0)
            } else {
                resumed = (try await client.resumeSession(
                    id, profile: route.profile, deferHistory: false), 0)
            }
            let live = resumed.session
            func requireExactResume(_ resumed: LiveSession) throws {
                guard !resumed.sessionID.isEmpty else {
                    throw GatewayError(code: -8, message: "session.resume returned no id")
                }
                guard !resumed.storedSessionID.isEmpty else {
                    throw AckValidationError(
                        operation: "Resume session",
                        detail: "Hermes returned no durable session identity.")
                }
                do {
                    try ExactStoredSessionResumeAckAuthority.requireExact(
                        route: route,
                        requestedStoredSessionID: id,
                        returnedStoredSessionID: resumed.storedSessionID,
                        returnedProfile: resumed.info.profileName)
                } catch ExactStoredSessionResumeAckAuthorityError.durableSessionMismatch {
                    throw AckValidationError(
                        operation: "Resume session",
                        detail: "Hermes returned a different durable session identity.")
                } catch {
                    throw AckValidationError(
                        operation: "Resume session",
                        detail: "Hermes returned a different profile identity.")
                }
            }
            try Task.checkCancellation()
            try requireExactResume(live)
            try await validateBeforeBinding()
            try Task.checkCancellation()
            try await requireExactStoredSessionSourceCurrent(sourceFence)
            // The final cancellation/source fence is immediately followed by
            // the synchronous swap and visible begin. There is intentionally
            // no await between those operations, so a superseding route or
            // source teardown cannot publish this attempt after it has lost
            // authority.
            try Task.checkCancellation()
        } catch {
            // Staging installs a handler before the first resume. Any failure
            // before the synchronous commit must close that intake, including
            // cancellation or source removal while the resume/authority await
            // is suspended; otherwise a dead invisible handler leaks forever.
            if let prepared { await prepared.discard() }
            throw error
        }
        let live = resumed.session
        let authoritative = live
        let snapshotSequence = resumed.inboundSequence
        let transaction: ExactRoutedEventsTransaction?
        if let prepared {
            do {
                transaction = try commitExactRoutedEvents(
                    prepared, snapshotSequence: snapshotSequence,
                    snapshotSessionID: authoritative.sessionID,
                    snapshotEvidence: authoritative.snapshotEvidence)
            } catch {
                await prepared.discard()
                throw error
            }
        } else {
            // Primary and already-subscribed secondary sources already have a
            // continuous pump, so no staged publication is necessary.
            await attachRoutedEventsIfNeeded(client: client, gatewayID: route.gatewayID)
            try Task.checkCancellation()
            try await requireExactStoredSessionSourceCurrent(sourceFence)
            transaction = nil
        }

        let attempt: StoredSessionOpenAttempt
        do {
            // Some callers own additional state outside the destination
            // source itself. Run that authority check after every open
            // preflight await and immediately before the synchronous visible
            // commit; there must be no actor hop between this return and
            // beginStoredSessionOpen.
            if let validateImmediatelyBeforeBinding {
                try await validateImmediatelyBeforeBinding()
            }
            try Task.checkCancellation()
            attempt = try beginStoredSessionOpen(
                id, botID: botID,
                exactSource: StoredSessionOpenSource(
                    route: route, client: client, resumed: authoritative
                )
            )
        } catch {
            if let transaction {
                transaction.rollback()
                await transaction.cleanupSupersededPrevious()
                await transaction.prepared.discardAfterRollback()
            }
            throw error
        }
        // Cancelling the outer navigation task must also cancel the unstructured
        // resume/hydration task created by beginStoredSessionOpen. Without this
        // propagation, a superseded cold route could still bind after its newer
        // successor had become the sole queued intent.
        return try await withTaskCancellationHandler {
            do {
                let opened = try await finishStoredSessionOpen(
                    attempt, presentsFailure: false)
                if let transaction {
                    if await transaction.finalize(model: self) {
                        transaction.prepared.activate()
                    }
                }
                return opened
            } catch {
                if let transaction {
                    if await transaction.finalize(model: self) {
                        transaction.prepared.activate()
                    }
                }
                throw error
            }
        } onCancel: {
            attempt.task.cancel()
        }
    }

    private func requireExactStoredSessionSourceCurrent(
        _ fence: ExactStoredSessionSourceFence
    ) async throws {
        try Task.checkCancellation()
        if let snapshot = fence.snapshot {
            guard await ConnectionRegistry.shared.clientPool.isCurrent(
                snapshot, for: fence.route.gatewayID) else {
                throw CancellationError()
            }
        } else if let current = await ConnectionRegistry.shared.clientPool.client(
            for: fence.route.gatewayID) {
            guard ObjectIdentifier(current) == ObjectIdentifier(fence.client) else {
                throw CancellationError()
            }
        }
        if let hook = SessionsRuntime.shared.sourceFenceAfterPoolCheckForTesting {
            await hook()
        }
        // Everything below is synchronous on MainActor. This is deliberately
        // the last authority read before commit/begin: source removal or a
        // profile lifecycle mutation that wins the pool actor hop is rejected
        // here rather than publishing from the pre-await snapshot.
        try Task.checkCancellation()
        guard !exactStoredSessionSourceIsInvalidated(gatewayID: fence.route.gatewayID) else {
            throw CancellationError()
        }
        guard mode == .live,
              stateRoute(for: fence.botID) == fence.route,
              profileLifecycleAccepts(fence.lifecycle) else {
            throw CancellationError()
        }
        if let expectedURL = fence.savedURLString {
            guard let saved = ConnectionRegistry.shared.saved.first(where: {
                $0.id == fence.route.gatewayID && $0.urlString == expectedURL
            }), ConnectionRegistry.shared.credential(for: saved) != nil else {
                throw CancellationError()
            }
        }
        if fence.route.gatewayID == activeGatewayID {
            guard LiveRuntime.shared.generation == fence.connectionGeneration,
                  self.client.map(ObjectIdentifier.init)
                    == ObjectIdentifier(fence.client) else {
                throw CancellationError()
            }
        } else {
            guard fence.route.gatewayID != activeGatewayID else {
                throw CancellationError()
            }
        }
    }

    private func beginStoredSessionOpen(
        _ id: String, botID: String, exactSource: StoredSessionOpenSource?
    ) throws -> StoredSessionOpenAttempt {
        guard !id.isEmpty else {
            throw GatewayError(code: 400, message: "A stored session identity is required.")
        }
        let lifecycle = mode == .live ? profileLifecycleGenerationToken(for: botID) : nil
        if let exactSource {
            guard mode == .live, let lifecycle,
                  lifecycle.route == exactSource.route,
                  stateRoute(for: botID) == exactSource.route else {
                throw CancellationError()
            }
            if let forced = SessionsRuntime.shared.beginFailureForTesting {
                throw forced
            }
        } else if mode == .live, lifecycle == nil {
            throw CancellationError()
        }
        openBotID = botID
        selectedTab = .home
        clearUnread(for: botID)
        // Same rule as `openChat`: this is a route into the bot's chat, so the
        // durable mark moves with the badge it just cleared.
        noteChatOpened(botID)

        let chat = chat(for: botID)
        let runtime = LiveRuntime.shared
        guard mode == .live, let lifecycle else { throw CancellationError() }

        let sessionsRuntime = SessionsRuntime.shared
        let openGeneration = sessionsRuntime.beginOpen(botID: botID)
        let connectionGeneration = runtime.generation

        // An explicit session selection replaces the binding at this tap,
        // except when it is reopening the exact durable row that owns a
        // deferred stop. Keep that intent through the temporary nil sid; the
        // subsequent resume/bind proves the same ChatState and durable route.
        // A different durable row (or known route) retires the old intent so
        // it cannot drain into a reused profile id.
        let reopenRoute = exactSource?.route ?? stateRoute(for: botID) ?? gatewayRoute(for: botID)
        let preservesPendingStop = ChatRuntime.shared.pendingStopMatchesReopen(
            botID: botID, storedID: id, chatID: ObjectIdentifier(chat), route: reopenRoute)
        if !preservesPendingStop {
            ChatRuntime.shared.clearPendingStop(botID: botID)
        }

        let oldStoredID = chat.storedSessionID
        if oldStoredID == id, let oldSessionID = chat.sessionID, !oldSessionID.isEmpty {
            // Keep the exact old runtime sid while the same durable session is
            // explicitly reopened; adopt/bind consumes it to migrate queued
            // mirrors and accepted mutation state to the replacement sid.
            runtime.reconnectParkedSessionIDs[botID] = oldSessionID
        } else if oldStoredID != id {
            // A different explicit durable row is a replacement binding. Do
            // not let an edit/rewind fence for A survive the stored-id swap.
            ChatRuntime.shared.transcriptActions[botID] = nil
            ChatRuntime.shared.transcriptActionGenerations[botID] = nil
            ChatRuntime.shared.transcriptLeases[botID] = nil
            ChatRuntime.shared.transcriptFences[botID] = nil
            if let oldStoredID, !oldStoredID.isEmpty, let reopenRoute {
                _ = ChatRuntime.shared.retireQueuedState(
                    botID: botID, route: reopenRoute, storedID: oldStoredID)
                retireComposeQueue(botID: botID, storedID: oldStoredID,
                                   chatID: ObjectIdentifier(chat))
                ChatRuntime.shared.offlineComposeFences =
                    ChatRuntime.shared.offlineComposeFences.filter { _, fence in
                        !(fence.botID == botID && fence.route == reopenRoute
                          && fence.storedID == oldStoredID
                          && fence.chatID == ObjectIdentifier(chat))
                    }
            }
            runtime.reconnectParkedSessionIDs[botID] = nil
        }

        // Unbind first: a send racing this must not land in the session we
        // are leaving, and an in-flight attach for the old session is stale.
        // This open installs its own replacement in the SAME attach slot
        // below. A send before session.resume returns therefore awaits this
        // exact selection instead of starting canonical resolution in parallel.
        runtime.attachTasks[botID]?.cancel()
        runtime.attachTasks[botID] = nil
        if let old = chat.sessionID, let route = reopenRoute {
            if route.gatewayID == runtime.gatewayID {
                runtime.sessionToBot.removeValue(forKey: old)
            } else {
                runtime.routedSessionToBot.removeValue(forKey: GatewaySessionRoute(
                    gatewayID: route.gatewayID, sessionID: old))
            }
        }
        chat.sessionID = nil
        chat.storedSessionID = id
        chat.isRunning = false
        chat.isTyping = false
        chat.usage = nil
        chat.contextSegments = []
        chat.messages = []
        ChatRuntime.shared.submitWatchdogs[botID]?.cancel()
        ChatRuntime.shared.submitWatchdogs[botID] = nil
        ChatRuntime.shared.turnFloor[botID] = nil
        runtime.workingBotIDs.remove(botID)
        if let idx = bots.firstIndex(where: { $0.id == botID }) {
            bots[idx].task = nil
            bots[idx].status = approvals.contains(where: { $0.botID == botID })
                ? .approval : .idle
        }
        // The durable key is also what a reconnect resumes from.
        runtime.lastSessionByBot[botID] = id

        let task = Task<String, Error> { @MainActor in
            let requireCurrentOpen: @MainActor () throws -> Void = {
                try Task.checkCancellation()
                guard SessionsRuntime.shared.acceptsOpen(
                    botID: botID, generation: openGeneration),
                    LiveRuntime.shared.generation == connectionGeneration,
                    self.profileLifecycleAccepts(lifecycle) else {
                    throw CancellationError()
                }
                if let exactSource {
                    guard lifecycle.route == exactSource.route,
                          self.stateRoute(for: botID) == exactSource.route,
                          exactSource.route.gatewayID != LiveRuntime.shared.gatewayID
                            || self.client.map(ObjectIdentifier.init)
                                == ObjectIdentifier(exactSource.client) else {
                        throw CancellationError()
                    }
                }
            }

            try requireCurrentOpen()
            let route: GatewayBotRoute
            let client: GatewayClient
            let live: LiveSession
            if let exactSource {
                route = exactSource.route
                client = exactSource.client
                live = exactSource.resumed
            } else {
                guard let resolvedRoute = self.gatewayRoute(for: botID) else {
                    throw GatewayRouteError.noRoute
                }
                route = resolvedRoute
                client = try await self.routedClient(for: resolvedRoute)
                try requireCurrentOpen()
                await self.attachRoutedEventsIfNeeded(client: client,
                                                      gatewayID: route.gatewayID)
                try requireCurrentOpen()
                // Full projection in the ack (deferHistory returns a bounded
                // stub) — one round trip, authoritative rows, same tradeoff
                // ensureSession makes.
                live = try await client.resumeSession(id, profile: route.profile,
                                                      deferHistory: false)
            }
            try requireCurrentOpen()
            guard !live.sessionID.isEmpty else {
                throw GatewayError(code: -8, message: "session.resume returned no id")
            }
            let stored: String
            if exactSource != nil {
                guard !live.storedSessionID.isEmpty else {
                    throw AckValidationError(
                        operation: "Resume session",
                        detail: "Hermes returned no durable session identity.")
                }
                stored = live.storedSessionID
            } else {
                stored = live.storedSessionID.isEmpty ? id : live.storedSessionID
            }
            chat.storedSessionID = stored
            // Clear state from the session we left, then derive the selected
            // session's turn state before yielding to REST hydration. Events
            // that arrive after bindSession are newer and may refine it.
            chat.isRunning = live.running
            chat.isTyping = false
            self.bindSession(live, botID: botID, sourceGatewayID: route.gatewayID)
            runtime.lastSessionByBot[botID] = stored
            self.replayInflight(live, botID: botID)

            try await Self.hydrateTranscript(
                chat: chat,
                resumeMessages: live.messages,
                clearWhenEmpty: true,
                fallback: {
                    try? await client.latestSessionMessages(storedID: stored,
                                                            profile: route.profile)
                },
                accepts: {
                    SessionsRuntime.shared.acceptsOpen(
                        botID: botID, generation: openGeneration)
                        && LiveRuntime.shared.generation == connectionGeneration
                        && self.profileLifecycleAccepts(lifecycle)
                })
            try requireCurrentOpen()

            // Same replay every other resume path uses: the approval keeps
            // its real choice set, and a parked clarify is recovered too.
            self.replayPendingPrompts(live, sourceGatewayID: route.gatewayID)
            // Context is ancillary to the binding. Do not keep the shared
            // attach task occupied behind this extra RPC: sends may proceed as
            // soon as resume + transcript hydration are coherent. The exact
            // sid and both generations still fence the detached completion.
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self,
                      SessionsRuntime.shared.acceptsOpen(
                        botID: botID, generation: openGeneration),
                      LiveRuntime.shared.generation == connectionGeneration,
                      self.profileLifecycleAccepts(lifecycle),
                      chat.sessionID == live.sessionID,
                      let segments = try? await client.contextBreakdown(live.sessionID),
                      SessionsRuntime.shared.acceptsOpen(
                        botID: botID, generation: openGeneration),
                      LiveRuntime.shared.generation == connectionGeneration,
                      self.profileLifecycleAccepts(lifecycle),
                      chat.sessionID == live.sessionID else { return }
                chat.contextSegments = segments
                self.contextMeter = segments
            }
            return live.sessionID
        }
        runtime.attachTasks[botID] = task
        return StoredSessionOpenAttempt(
            task: task, botID: botID, chat: chat,
            lifecycle: lifecycle, openGeneration: openGeneration,
            connectionGeneration: connectionGeneration
        )
    }

    @discardableResult
    private func finishStoredSessionOpen(
        _ attempt: StoredSessionOpenAttempt, presentsFailure: Bool
    ) async throws -> Bool {
        defer {
            if LiveRuntime.shared.attachTasks[attempt.botID] == attempt.task {
                LiveRuntime.shared.attachTasks[attempt.botID] = nil
            }
        }
        do {
            let sessionID = try await attempt.task.value
            guard SessionsRuntime.shared.acceptsOpen(
                botID: attempt.botID, generation: attempt.openGeneration),
                LiveRuntime.shared.generation == attempt.connectionGeneration,
                profileLifecycleAccepts(attempt.lifecycle),
                attempt.chat.sessionID == sessionID else {
                throw CancellationError()
            }
            return true
        } catch is CancellationError {
            // A newer selection/reconnect owns the visible result.
            throw CancellationError()
        } catch {
            guard SessionsRuntime.shared.acceptsOpen(
                botID: attempt.botID, generation: attempt.openGeneration),
                LiveRuntime.shared.generation == attempt.connectionGeneration,
                profileLifecycleAccepts(attempt.lifecycle) else {
                throw CancellationError()
            }
            let runtime = LiveRuntime.shared
            attempt.chat.isRunning = false
            attempt.chat.isTyping = false
            runtime.workingBotIDs.remove(attempt.botID)
            if let idx = bots.firstIndex(where: { $0.id == attempt.botID }) {
                bots[idx].task = nil
                bots[idx].status = approvals.contains(where: { $0.botID == attempt.botID })
                    ? .approval : .idle
            }
            if presentsFailure {
                attempt.chat.messages.append(ChatMessage(
                    author: .system, text: Self.sessionFailure(error, theme: theme)))
                // …and out loud (plugin.js:6782 `notifyError(err, 'Could not
                // open session')`). The system row above is the durable record,
                // but this tap came from a sheet that has just dismissed onto an
                // empty chat, and a blank screen with an explanation somewhere
                // below the fold reads as the app having done nothing at all.
                toast(kind: .failure,
                      title: theme.copy.toastOpenSessionFailed(theme.themeID),
                      message: Self.reason(error), botID: attempt.botID)
            }
            throw error
        }
    }

    // MARK: - Row actions

    /// Delete a stored session. Returns nil on success, else a themed reason.
    /// The gateway answers **4023** for a session it still holds live — that
    /// is a real state the user has to resolve, not a bug.
    public func deleteStoredSession(_ id: String, botID: String) async -> String? {
        guard mode == .live else {
            dropSessionRow(id, botID: botID)
            return nil
        }
        guard let route = gatewayRoute(for: botID),
              let client = try? await routedClient(for: route) else {
            return theme.copy.sessUnreachable(theme.themeID)
        }
        let generation = LiveRuntime.shared.generation
        do {
            try await client.deleteSession(id, profile: route.profile)
        } catch let error as GatewayError where error.code == 4023 {
            return theme.copy.sessDeleteLive(theme.themeID)
        } catch let error as GatewayError where error.code == 4007 {
            // Already gone — the desktop treats an absent row as success and
            // so must we, or the row resurrects on the next refresh.
            guard LiveRuntime.shared.generation == generation,
                  gatewayRoute(for: botID) == route else { return nil }
            dropSessionRow(id, botID: botID)
            return nil
        } catch {
            return Self.sessionFailure(error, theme: theme)
        }
        guard LiveRuntime.shared.generation == generation,
              gatewayRoute(for: botID) == route else { return nil }
        dropSessionRow(id, botID: botID)
        return nil
    }

    /// Rename a session. A live session goes over session.title (which
    /// re-emits session.info so every strip resyncs); a stored one goes over
    /// PATCH /api/sessions/{id}, the only path that resolves durable keys.
    /// Returns nil on success, else a themed reason.
    public func renameStoredSession(_ id: String, botID: String, to title: String) async -> String? {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return theme.copy.sessRenameEmpty(theme.themeID) }
        guard mode == .live else {
            applyTitle(clean, to: id, botID: botID)
            return nil
        }
        guard let route = gatewayRoute(for: botID),
              let client = try? await routedClient(for: route) else {
            return theme.copy.sessUnreachable(theme.themeID)
        }
        let chat = chats[botID]
        let generation = LiveRuntime.shared.generation
        do {
            if let sid = chat?.sessionID, chat?.storedSessionID == id {
                try await client.setSessionTitle(sessionID: sid, title: clean)
            } else {
                try await client.renameStoredSession(id, title: clean, profile: route.profile)
            }
        } catch {
            return Self.sessionFailure(error, theme: theme)
        }
        guard LiveRuntime.shared.generation == generation,
              gatewayRoute(for: botID) == route else { return nil }
        applyTitle(clean, to: id, botID: botID)
        return nil
    }

    // MARK: - Turn controls (branch / compress / export)

    /// Fork the bot's current session. The fork is persisted with the
    /// parent's lineage and appears in the list; it is deliberately NOT
    /// opened, so the conversation the user is reading never changes under
    /// them.
    public func branchSession(botID: String) async -> SessionActionOutcome {
        guard let lease = await beginSessionControlMutation(
            botID: botID, kind: .wholeSessionBranch) else { return needsLiveSession }
        defer {
            SessionMutationCoordinator.shared.release(lease.claim)
            drainPendingMutationWork(botID: botID)
        }
        if let hook = SessionMutationCoordinator.shared.afterClaimForTesting {
            await hook(lease.claim)
        }
        guard sessionControlAuthorityIsCurrent(lease) else { return needsLiveSession }
        let route = lease.claim.target.route
        guard let client = try? await routedClient(for: route),
              sessionControlAuthorityIsCurrent(lease) else { return needsLiveSession }
        do {
            let branch: SessionBranch
            if let override = SessionMutationCoordinator.shared.wholeBranchForTesting {
                branch = try await override(client, lease.claim.target.runtimeSessionID)
            } else {
                branch = try await client.branchSession(
                    lease.claim.target.runtimeSessionID)
            }
            guard sessionControlAuthorityIsCurrent(lease) else { return needsLiveSession }
            await refreshSessions(botID: botID)
            return SessionActionOutcome(
                ok: true,
                headline: theme.copy.sessBranched(theme.themeID),
                detail: branch.title.isEmpty ? nil : branch.title)
        } catch {
            return SessionActionOutcome(ok: false,
                                        headline: Self.sessionFailure(error, theme: theme))
        }
    }

    /// Manual compaction, with the gateway's own before/after summary. The
    /// compacted transcript replaces the local one, matching desktop.
    public func compressSession(botID: String) async -> SessionActionOutcome {
        guard let lease = await beginSessionControlMutation(
            botID: botID, kind: .compression) else { return needsLiveSession }
        defer {
            SessionMutationCoordinator.shared.release(lease.claim)
            drainPendingMutationWork(botID: botID)
        }
        if let hook = SessionMutationCoordinator.shared.afterClaimForTesting {
            await hook(lease.claim)
        }
        guard sessionControlAuthorityIsCurrent(lease) else { return needsLiveSession }
        let route = lease.claim.target.route
        guard let client = try? await routedClient(for: route),
              sessionControlAuthorityIsCurrent(lease) else { return needsLiveSession }
        do {
            let result: SessionCompression
            if let override = SessionMutationCoordinator.shared.compressionForTesting {
                result = try await override(client, lease.claim.target.runtimeSessionID)
            } else {
                result = try await client.compressSession(
                    lease.claim.target.runtimeSessionID)
            }
            guard sessionControlAuthorityIsCurrent(lease) else { return needsLiveSession }
            if !result.messages.isEmpty {
                let rebuilt = Self.chatMessages(fromTranscript: .array(result.messages))
                if !rebuilt.isEmpty { chat(for: botID).messages = rebuilt }
            }
            await refreshContext(botID: botID)
            var detail = result.tokenLine
            if let note = result.note, !note.isEmpty {
                detail = detail.isEmpty ? note : detail + "\n" + note
            }
            return SessionActionOutcome(ok: result.outcome != .aborted,
                                        headline: result.headline,
                                        detail: detail.isEmpty ? nil : detail)
        } catch {
            return SessionActionOutcome(ok: false,
                                        headline: Self.sessionFailure(error, theme: theme))
        }
    }

    /// session.save — a JSON snapshot written on the GATEWAY host, not the
    /// phone. The path is the whole result, so it is what we show.
    public func exportSession(botID: String) async -> SessionActionOutcome {
        guard let sid = await liveSessionID(botID: botID) else { return needsLiveSession }
        guard let route = gatewayRoute(for: botID),
              let client = try? await routedClient(for: route) else { return needsLiveSession }
        let generation = LiveRuntime.shared.generation
        do {
            let path = try await client.saveSession(sid)
            guard LiveRuntime.shared.generation == generation,
                  gatewayRoute(for: botID) == route,
                  chats[botID]?.sessionID == sid else { return needsLiveSession }
            return SessionActionOutcome(ok: true,
                                        headline: theme.copy.sessExported(theme.themeID),
                                        detail: path.isEmpty ? nil : path)
        } catch {
            return SessionActionOutcome(ok: false,
                                        headline: Self.sessionFailure(error, theme: theme))
        }
    }

    /// branch/compress/save all resolve runtime sids, so they need a session
    /// this process holds live. These are explicit user actions, so minting
    /// one when the chat was never opened is the right call.
    private func liveSessionID(botID: String) async -> String? {
        guard mode == .live, gatewayRoute(for: botID) != nil else { return nil }
        if let sid = chats[botID]?.sessionID { return sid }
        return try? await ensureSession(botID: botID, hydrate: false)
    }

    private var needsLiveSession: SessionActionOutcome {
        SessionActionOutcome(ok: false, headline: theme.copy.sessNoLiveSession(theme.themeID))
    }

    private func beginSessionControlMutation(
        botID: String, kind: SessionControlMutationKind
    ) async -> ExactSessionControlLease? {
        guard let sessionID = await liveSessionID(botID: botID),
              let route = gatewayRoute(for: botID),
              stateRoute(for: botID) == route,
              let lifecycle = profileLifecycleGenerationToken(for: botID),
              lifecycle.route == route,
              profileLifecycleAccepts(lifecycle),
              let chat = chats[botID],
              chat.sessionID == sessionID,
              let storedSessionID = chat.storedSessionID,
              let target = ExactSessionMutationTarget(
                route: route, runtimeSessionID: sessionID,
                storedSessionID: storedSessionID),
              !chat.isRunning, !chat.isTyping,
              !LiveRuntime.shared.workingBotIDs.contains(botID),
              sessionMutationAdmissionIsAvailable(botID: botID, target: target),
              let claim = SessionMutationCoordinator.shared.acquire(
                target, botID: botID, kind: kind) else { return nil }
        return ExactSessionControlLease(
            claim: claim, lifecycle: lifecycle,
            chatID: ObjectIdentifier(chat),
            connectionGeneration: LiveRuntime.shared.generation)
    }

    private func sessionControlAuthorityIsCurrent(
        _ lease: ExactSessionControlLease
    ) -> Bool {
        let claim = lease.claim
        guard SessionMutationCoordinator.shared.owns(claim),
              mode == .live,
              LiveRuntime.shared.generation == lease.connectionGeneration,
              gatewayRoute(for: claim.botID) == claim.target.route,
              stateRoute(for: claim.botID) == claim.target.route,
              profileLifecycleAccepts(lease.lifecycle),
              let chat = chats[claim.botID],
              ObjectIdentifier(chat) == lease.chatID,
              chat.sessionID == claim.target.runtimeSessionID,
              chat.storedSessionID == claim.target.storedSessionID,
              !chat.isRunning, !chat.isTyping,
              !LiveRuntime.shared.workingBotIDs.contains(claim.botID),
              !turnMutationIsActive(botID: claim.botID, target: claim.target) else {
            return false
        }
        return true
    }

    // MARK: - Cross-session search

    /// Full-text search over every bot's sessions. Each profile owns its own
    /// state.db (web_server.py:_open_session_db_for_profile), so this is a
    /// fan-out — one GET /api/sessions/search per roster entry, merged newest
    /// first. Consumed by the search palette.
    public func searchSessions(_ query: String) async -> [SessionSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        guard mode == .live else { return demoSearch(trimmed) }
        var targets: [(botID: String, profile: String, client: GatewayClient)] = []
        for bot in unionRosterBots {
            guard let route = gatewayRoute(for: bot.id),
                  let client = try? await routedClient(for: route) else { continue }
            targets.append((bot.id, route.profile, client))
        }
        guard !targets.isEmpty else { return [] }
        var merged: [SessionSearchHit] = []
        await withTaskGroup(of: [SessionSearchHit].self) { group in
            for target in targets {
                group.addTask {
                    ((try? await target.client.searchSessions(query: trimmed,
                                                              profile: target.profile, limit: 8))
                        ?? []).map { hit in
                            var tagged = hit
                            tagged.botID = target.botID
                            return tagged
                        }
                }
            }
            for await batch in group { merged.append(contentsOf: batch) }
        }
        var seen = Set<String>()
        return merged
            .filter { seen.insert(SessionsRuntime.key(botID: $0.botID, sessionID: $0.id)).inserted }
            .sorted { $0.lastActive > $1.lastActive }
    }

    /// The same search scoped to one bot — the sessions sheet's filter falls
    /// through to it so a phrase from inside a conversation finds it.
    public func searchSessions(_ query: String, botID: String) async -> [SessionSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        guard mode == .live else {
            return demoSearch(trimmed).filter { $0.botID == botID }
        }
        guard let route = gatewayRoute(for: botID),
              let client = try? await routedClient(for: route),
              let hits = try? await client.searchSessions(query: trimmed,
                                                           profile: route.profile, limit: 20)
        else { return [] }
        return hits.map { hit in
            var tagged = hit
            tagged.botID = botID
            return tagged
        }
    }

    /// Demo mode has no gateway index; the canned session titles are the
    /// whole world, so filter those.
    private func demoSearch(_ query: String) -> [SessionSearchHit] {
        let needle = query.lowercased()
        return sessions
            .filter { $0.key != "default" }
            .sorted { $0.key < $1.key }
            .flatMap { botID, list in
                list.filter { $0.title.lowercased().contains(needle) }
                    .map { SessionSearchHit(sessionID: $0.id, botID: botID, title: $0.title,
                                            snippet: "", when: $0.when, lastActive: 0) }
            }
    }

    // MARK: - session.title event + router

    /// The auto-title lands as a `session.title` event whose payload
    /// `session_id` is the DURABLE key (the envelope's is the runtime sid —
    /// ws-protocol.md §5.3). Patches every list showing that row and keeps an
    /// overlay so a later refresh cannot regress to the untitled row.
    public func applySessionTitle(_ event: GatewayEvent, sourceGatewayID: String? = nil) {
        guard event.type == "session.title" else { return }
        let stored = event.payload?["session_id"]?.stringValue ?? ""
        let title = (event.payload?["title"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stored.isEmpty, !title.isEmpty else { return }
        let owner = botID(forSession: event.sessionID, sourceGatewayID: sourceGatewayID)
            ?? chats.first(where: { botID, chat in
                guard chat.storedSessionID == stored else { return false }
                guard let sourceGatewayID else { return true }
                return gatewayRoute(for: botID)?.gatewayID == sourceGatewayID
            })?.key
        guard let owner else { return }
        SessionsRuntime.shared.titles[SessionsRuntime.key(botID: owner, sessionID: stored)] = title

        var patched = false
        if let chat = chats[owner],
           let idx = chat.storedSessions.firstIndex(where: { $0.id == stored }) {
            chat.storedSessions[idx].title = title
            if var list = sessions[owner], let row = list.firstIndex(where: { $0.id == stored }) {
                list[row].title = title
                sessions[owner] = list
            }
            patched = true
        }
        guard !patched else { return }
        // A first-turn auto-title arrives before any list holds that row. Pull
        // the owning bot's list so the freshly named session shows up.
        Task { @MainActor in await self.refreshSessions(botID: owner) }
    }

    /// Register the sessions-area event handler on the live client. The main
    /// pump in AppModelLive drops `session.title`, so this adds a second
    /// handler rather than contending for that switch. Idempotent; call after
    /// `connectGateway`.
    public func attachSessionEventRouter() {
        guard mode == .live, let client else { return }
        let runtime = SessionsRuntime.shared
        if runtime.routerTask != nil, runtime.attachedClient === client { return }
        detachSessionEventRouter()
        runtime.attachedClient = client
        // One AsyncStream so MainActor delivery preserves wire order, same
        // shape as the main event pump.
        let (stream, continuation) = AsyncStream.makeStream(of: GatewayEvent.self)
        runtime.routerTask = Task { @MainActor [weak self] in
            for await event in stream { self?.routeSessionEvent(event) }
        }
        Task {
            let id = await client.addEventHandler { continuation.yield($0) }
            await MainActor.run { SessionsRuntime.shared.handlerID = id }
        }
    }

    /// Drop the sessions-area handler (gateway swap / sign-out). The cached
    /// titles and previews go with it — they belong to that gateway's store.
    public func detachSessionEventRouter() {
        let runtime = SessionsRuntime.shared
        runtime.routerTask?.cancel()
        runtime.routerTask = nil
        runtime.resetPrimaryScope()
        if let id = runtime.handlerID, let target = runtime.attachedClient {
            Task { await target.removeEventHandler(id) }
        }
        runtime.handlerID = nil
        runtime.attachedClient = nil
    }

    func routeSessionEvent(_ event: GatewayEvent, sourceGatewayID: String? = nil) {
        switch event.type {
        case "session.title":
            applySessionTitle(event, sourceGatewayID: sourceGatewayID)
        case "sessions.changed":
            // Global broadcast, already floored at 2 s server-side. Only the
            // open bot's list is on screen, so refresh that one — and debounce
            // it, because a busy turn can trip the broadcast repeatedly.
            guard let botID = openBotID else { return }
            if let sourceGatewayID, gatewayRoute(for: botID)?.gatewayID != sourceGatewayID {
                return
            }
            let runtime = SessionsRuntime.shared
            runtime.refreshTask?.cancel()
            runtime.refreshTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await self?.refreshSessions(botID: botID)
            }
        default:
            break
        }
    }

    // MARK: - Local list maintenance

    private func dropSessionRow(_ id: String, botID: String) {
        let runtime = SessionsRuntime.shared
        let key = SessionsRuntime.key(botID: botID, sessionID: id)
        // A deleted durable row can never receive the deferred interrupt that
        // was captured for it. Clear before mutating ChatState so a later
        // replacement session cannot inherit the intent.
        ChatRuntime.shared.clearPendingStopIfStored(id, botID: botID)
        if chats[botID]?.storedSessionID == id {
            ChatRuntime.shared.clearPendingStop(botID: botID)
        }
        runtime.titles[key] = nil
        runtime.previews[key] = nil
        if let chat = chats[botID] {
            chat.storedSessions.removeAll { $0.id == id }
            // The deleted row was this chat's binding: forget it so the next
            // open creates a fresh session instead of resuming a dead key.
            if chat.storedSessionID == id {
                chat.storedSessionID = nil
                if let sid = chat.sessionID, let route = gatewayRoute(for: botID) {
                    if route.gatewayID == LiveRuntime.shared.gatewayID {
                        LiveRuntime.shared.sessionToBot.removeValue(forKey: sid)
                    } else {
                        LiveRuntime.shared.routedSessionToBot.removeValue(
                            forKey: GatewaySessionRoute(gatewayID: route.gatewayID,
                                                        sessionID: sid))
                    }
                }
                chat.sessionID = nil
                chat.messages = []
                chat.isTyping = false
            }
        }
        sessions[botID]?.removeAll { $0.id == id }
        if LiveRuntime.shared.lastSessionByBot[botID] == id {
            LiveRuntime.shared.lastSessionByBot[botID] = nil
        }
    }

    private func applyTitle(_ title: String, to id: String, botID: String) {
        SessionsRuntime.shared.titles[SessionsRuntime.key(botID: botID, sessionID: id)] = title
        if let chat = chats[botID], let idx = chat.storedSessions.firstIndex(where: { $0.id == id }) {
            chat.storedSessions[idx].title = title
        }
        if var list = sessions[botID], let idx = list.firstIndex(where: { $0.id == id }) {
            list[idx].title = title
            sessions[botID] = list
        }
    }

    /// One themed line for any failure the sessions area can hit. Transport
    /// codes read as a dropped link; everything else keeps the gateway's own
    /// message, which is written for humans.
    static func sessionFailure(_ error: Error, theme: ThemeManager) -> String {
        guard let gateway = error as? GatewayError else {
            return theme.copy.sessFailed(theme.themeID)
        }
        if gateway.code <= -1, gateway.code >= -9 {
            return theme.copy.sessUnreachable(theme.themeID)
        }
        return gateway.message.isEmpty ? theme.copy.sessFailed(theme.themeID) : gateway.message
    }
}
