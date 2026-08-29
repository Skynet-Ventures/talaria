import Foundation
import TalariaKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Liveness: keeping "what is actually running" honest on a device that stops
// running.
//
// A phone suspends; a desktop does not. Every turn event Talaria depends on —
// message.complete above all — is delivered over a socket that dies the moment
// iOS parks the process, and the gateway does not replay them
// (ws-protocol.md §3: liveness is socket-level, sessions are parked for
// ~20 s and then reaped). The consequence is not a missing feature but WRONG
// STATE: a bot whose turn finished while the app was backgrounded stays pinned
// to `.working` forever, spinner and all, because the only thing that ever
// clears it is an event that will never arrive (PARITY.md:1123 — "the
// highest-severity liveness gap").
//
// The fix is one authoritative question asked at the right moments:
// `session.active_list` (methods_session.py:992 → server.py:_session_live_item,
// 8577) returns the gateway's IN-MEMORY session registry — every session with a
// live agent, with its true status. It resumes nothing, focuses nothing and
// mutates nothing, so it is safe to ask on every foreground.
//
// It is authoritative about ABSENCE too, and that is the half that matters
// here: the gateway drops a session out of `_sessions` when its turn completes
// and its transport goes away, so a runtime that is simply missing from the
// snapshot has ended. Desktop reaps on exactly that signal
// (apps/desktop/src/app/contrib/hooks/use-background-sync.ts:178
// `rehydrateLiveSessionStatuses`); this is its phone twin, plus the two things
// a phone needs that a desktop does not — a foreground re-seed and a
// network-restore nudge.
//
// Everything here is idempotent, bounded, and inert in demo mode.

// MARK: - The snapshot

/// One row of `session.active_list` (server.py:8592-8602).
struct LiveSessionRow: Sendable {

    /// What the gateway believes this session is doing right now
    /// (server.py:_session_live_status, 8545).
    enum Turn {
        /// `working` (a turn is running) or `waiting` (parked on an approval /
        /// clarify — still a turn in progress from the roster's point of view).
        case busy
        /// `starting`: the agent is still being built. Indeterminate — it is
        /// neither proof of a turn nor proof there is none, so it settles
        /// nothing in either direction.
        case building
        /// `idle`: alive, nothing running.
        case idle
    }

    /// Runtime sid — routes events, addresses live-session RPCs.
    var sessionID: String
    /// Durable key — what `session.resume` and every session list speak.
    var sessionKey: String
    var turn: Turn
    /// Unix seconds of the session's last activity, gateway-side.
    var lastActive: Double
    /// The session's last message, whitespace-flattened and capped at 160
    /// chars (server.py:_message_preview, 8558). On an idle session this is
    /// exactly the tail of the transcript, which makes it a free signature for
    /// "did this conversation move while we were away?". On a busy one it is
    /// the in-flight or queued text instead (server.py:8585-8590), so it only
    /// carries that meaning for `.idle` rows.
    var preview: String

    init(_ v: JSONValue) {
        sessionID = v["id"]?.stringValue ?? ""
        sessionKey = v["session_key"]?.stringValue ?? ""
        lastActive = v["last_active"]?.doubleValue ?? 0
        preview = v["preview"]?.stringValue ?? ""
        switch v["status"]?.stringValue {
        case "working", "waiting": turn = .busy
        case "starting": turn = .building
        default: turn = .idle
        }
    }
}

extension GatewayClient {

    /// `session.active_list` — the gateway's in-memory session registry
    /// (methods_session.py:992). Not a DB browser: it reports only sessions
    /// with a live agent that a client could attach to, and it filters
    /// `_finalized` rows so a session mid-teardown never counts as live
    /// (methods_session.py:1007-1026).
    ///
    /// The 20 s ceiling is deliberate. Upstream polls this snapshot every 1.5 s
    /// from the TUI, so it is small and fast; the default 120 s would let a
    /// silently-dead socket (a Wi-Fi handoff the transport has not noticed yet)
    /// hold the reconcile open for two minutes.
    func activeSessions() async throws -> [LiveSessionRow] {
        let result = try await rpc("session.active_list", .object([:]), timeout: 20)
        // A gateway that answers without a `sessions` key is not describing an
        // empty registry, it is not answering this question at all — and every
        // conclusion below reads absence as authority. Refuse to guess.
        guard let rows = result["sessions"]?.arrayValue else {
            throw GatewayError(code: GatewayClient.methodNotFound,
                               message: "session.active_list unsupported")
        }
        return rows.map(LiveSessionRow.init)
    }

    /// `session.history` (methods_session.py:2587) → `{count, messages}` in the
    /// standard display projection. Addressed by RUNTIME sid (`_sess_nowait`,
    /// so it does not block on an agent build), which means it only answers for
    /// a session still in `_sessions`; a session that has ended is reachable
    /// only over the REST transcript route by durable key.
    ///
    /// Preferred where it applies for two reasons: it reads the WHOLE lineage
    /// (`include_ancestors=True`) rather than a paged tail, and it stamps
    /// `row_id` on every row (`include_row_ids=True`, added for exactly this
    /// class of client-side reconciliation) — which is what lets the graft
    /// below anchor on durable identity instead of matching text.
    func sessionHistory(_ sessionID: String) async throws -> JSONValue {
        try await rpc("session.history", ["session_id": .string(sessionID)], timeout: 60)
    }
}

// MARK: - Runtime (side table)

/// What triggered a reconcile. Only one distinction is load-bearing: after a
/// foreground the user has demonstrably not just submitted anything, so a
/// "this session is idle" verdict can be trusted on the spot.
enum LivenessTrigger {
    case foreground
    case reaper
    case networkRestored
}

/// `AppModel`'s stored properties live in AppModel.swift (another owner) and
/// extensions cannot add storage, so liveness bookkeeping rides a MainActor
/// singleton, like `LiveRuntime` and `CanonicalChatRuntime` do.
@MainActor
final class LivenessRuntime {
    static let shared = LivenessRuntime()

    /// Reaper cadence, and only while something is actually spinning — a phone
    /// must not poll for nothing. 20 s is the gateway's own orphan-reap grace
    /// (`_WS_ORPHAN_REAP_GRACE_S`, server.py:164-180): before it elapses a
    /// dropped session is still parked and attachable, so a snapshot taken
    /// sooner could read a recoverable session as gone. After it, absence is
    /// final. Matching the two means the reaper never races the park window.
    static let reaperTick: Duration = .seconds(20)

    /// How long a live-but-idle session may disagree with a locally-working bot
    /// before the snapshot wins, outside a foreground re-seed. Covers the one
    /// window where the gateway honestly reports idle while the client is
    /// right: between `prompt.submit` being accepted and the turn flipping
    /// `running` (sub-second in practice). Desktop refuses to clear in exactly
    /// this window too (use-background-sync.ts:206-211).
    static let settleGrace: Duration = .seconds(5)

    /// A bot marked working with NO addressable session — no runtime sid, no
    /// durable key — cannot be checked against the snapshot at all. 45 s
    /// matches the submit watchdog in AppModelLive+Chat.swift: a turn that has
    /// produced nothing addressable for that long is wedged, not working.
    static let unverifiableGrace: Duration = .seconds(45)

    /// Lifecycle observer + monitors installed once per process.
    var armed = false
    /// Cleared for a gateway that answers -32601. Everything here reads
    /// absence as authority; without the snapshot there is nothing honest to
    /// say, so the whole surface stands down rather than guessing.
    var supported = true
    /// Link generation the verdict above was reached on. A re-dial re-probes:
    /// one -32601 is cheap, and a gateway upgraded and restarted underneath us
    /// would otherwise stay written off for the rest of the process.
    var supportedGeneration = -1
    /// Base URL the bookkeeping below belongs to. Session ids are per-gateway.
    var scope: String?

    var reconcileTask: Task<Void, Never>?
    var reaperTask: Task<Void, Never>?
    var lifecycleObserver: NSObjectProtocol?

    /// bot id → first snapshot that reported its turn finished while we still
    /// showed it working. A second agreeing snapshot settles it.
    var settledSince: [String: ContinuousClock.Instant] = [:]
    /// bot id → since when it has been working with nothing to verify against.
    var unverifiableSince: [String: ContinuousClock.Instant] = [:]
    /// A trigger arrived while the link was down. The reaper picks it up once
    /// the link is back, so a foreground-while-offline still gets its re-seed.
    var reseedPending = false

    /// Package-test seam: `session.active_list` for one owning gateway, using
    /// the captured client the reaper resolved. Production still asks that
    /// client on the wire.
    var activeSessionsForTesting:
        (@MainActor (GatewayClient, String) async throws -> [LiveSessionRow])?
    /// Package-test seam: `session.history` on the same captured client.
    var sessionHistoryForTesting:
        (@MainActor (GatewayClient, String, String) async throws -> JSONValue)?

    /// Point the bookkeeping at the live gateway, dropping anything learned
    /// about a different one — its session ids resolve to nothing here (or,
    /// worse, to something else).
    func rescope(to base: URL?) {
        let next = base?.absoluteString
        guard next != scope else { return }
        scope = next
        supported = true
        settledSince.removeAll()
        unverifiableSince.removeAll()
        // A re-seed owed to the gateway we just left is not owed by the one we
        // arrived at; carrying it would spend the next tick's request
        // reconciling a world that no longer exists.
        reseedPending = false
    }
}

// MARK: - Arming

extension AppModel {

    /// Install the liveness watches. Idempotent: call it whenever the live
    /// client changes (TalariaRootView does, off `clientToken`) and the second
    /// call only re-scopes the bookkeeping to the new gateway.
    ///
    /// Requires a client. Without one there is no snapshot to ask for and no
    /// socket for a network nudge to save, so demo mode — and the window after
    /// `disconnectGateway()` tore these same watches down — arm nothing rather
    /// than running a timer and an NWPathMonitor that can only ever no-op.
    ///
    /// Deliberately NOT gated on `mode == .live`: `connectGateway` assigns the
    /// client before it awaits the dial and only flips `mode` afterwards, so a
    /// render that lands inside that await would see a client with the old
    /// mode and arm nothing — and `clientToken` does not change a second time
    /// to correct it. Every path this arms re-checks `mode` when it fires.
    public func startLivenessSupervision() {
        guard client != nil else { return }
        let liveness = LivenessRuntime.shared
        liveness.rescope(to: LiveRuntime.shared.baseURL)
        startLivenessReaper()

        // The nudge itself is `reconnectNow()`, which already guards against a
        // concurrent dial and parks in the same slot as the backoff ladder.
        NetworkMonitor.shared.start { [weak self] in
            self?.networkPathBecameUsable()
        }

        guard !liveness.armed else { return }
        liveness.armed = true

        // Own foreground detection rather than depending on a scene-phase hook
        // in a view: the re-seed has to run when the process wakes, whatever is
        // on screen, and this way it survives any view being rebuilt.
        #if canImport(UIKit)
        let activation = UIApplication.didBecomeActiveNotification
        #elseif canImport(AppKit)
        let activation = NSApplication.didBecomeActiveNotification
        #endif
        #if canImport(UIKit) || canImport(AppKit)
        liveness.lifecycleObserver = NotificationCenter.default.addObserver(
            forName: activation, object: nil, queue: .main
        ) { [weak self] _ in
            // Reseed alone cannot restore a socket that died while parked.
            // Route the reliable UIKit edge through the same coalesced
            // validate-then-reconnect path scenePhase uses.
            Task { @MainActor in self?.applicationDidBecomeActive() }
        }
        #endif
    }

    /// Tear every liveness watch down. Called from `disconnectGateway()`: with
    /// no gateway there is nothing to reconcile against, and a reaper still
    /// ticking against `LiveRuntime.workingBotIDs` would be asking a client
    /// that no longer exists. `startLivenessSupervision()` re-arms the whole
    /// set on the next connect, so this is a pause and not a one-way door.
    public func stopLivenessSupervision() {
        let liveness = LivenessRuntime.shared
        liveness.reaperTask?.cancel(); liveness.reaperTask = nil
        liveness.reconcileTask?.cancel(); liveness.reconcileTask = nil
        if let observer = liveness.lifecycleObserver {
            NotificationCenter.default.removeObserver(observer)
            liveness.lifecycleObserver = nil
        }
        liveness.armed = false
        NetworkMonitor.shared.stop()
        // Session ids, settle timers and the -32601 verdict all belong to the
        // gateway that just went away.
        liveness.rescope(to: nil)
    }

    /// Re-seed from the gateway after the process comes back to the front.
    /// Safe to call repeatedly: concurrent callers coalesce onto one snapshot.
    public func foregroundReseed() {
        startLivenessSupervision()
        retryExactStoredSessionNavigation()
        guard mode == .live else { return }
        Task { @MainActor in await self.reconcileLiveness(trigger: .foreground) }
    }

    /// The OS reports a usable route again (dead zone left, Wi-Fi↔cellular
    /// handoff). Skip the backoff sleep instead of waiting it out
    /// (PARITY.md:1120).
    private func networkPathBecameUsable() {
        retryExactStoredSessionNavigation()
        guard mode == .live, LiveRuntime.shared.baseURL != nil else { return }
        Task { @MainActor in
            // A handoff kills the socket without the transport noticing
            // immediately. `.ready` is not enough — prove the current
            // transport with the same bounded ping the foreground path uses.
            if !self.isOffline, let client = self.client {
                switch await client.validateForegroundLiveness() {
                case .healthy:
                    await self.reconcileLiveness(trigger: .networkRestored)
                    return
                case .trafficFenced:
                    return
                case .reconnectRequired:
                    break
                }
            }
            self.reconnectNow()
        }
    }

    /// The reaper's clock. It only asks the gateway anything while a bot is
    /// showing as working (or a re-seed is owed from an offline foreground) —
    /// an idle roster costs zero requests.
    private func startLivenessReaper() {
        let liveness = LivenessRuntime.shared
        guard liveness.reaperTask == nil else { return }
        liveness.reaperTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: LivenessRuntime.reaperTick)
                guard !Task.isCancelled, let self else { return }
                guard self.mode == .live, self.client != nil, !self.isOffline else { continue }
                guard LivenessRuntime.shared.reseedPending
                        || !LiveRuntime.shared.workingBotIDs.isEmpty else { continue }
                await self.reconcileLiveness(trigger: .reaper)
            }
        }
    }
}

// MARK: - Reconcile

extension AppModel {

    /// One authoritative pass over `session.active_list`. Coalesced: a
    /// foreground racing a reaper tick asks once and both await the answer.
    func reconcileLiveness(trigger: LivenessTrigger) async {
        let liveness = LivenessRuntime.shared
        if let inflight = liveness.reconcileTask {
            await inflight.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runLivenessReconcile(trigger: trigger)
        }
        liveness.reconcileTask = task
        // Clear only OUR slot: a later reconcile may already own it by the time
        // this frame resumes, and blanking it unconditionally would
        // un-coalesce that one.
        defer { if liveness.reconcileTask == task { liveness.reconcileTask = nil } }
        await task.value
    }

    private func runLivenessReconcile(trigger: LivenessTrigger) async {
        let liveness = LivenessRuntime.shared
        guard mode == .live, client != nil else { return }
        guard !isOffline else {
            // Nothing to ask and nothing to conclude. The reaper carries the
            // debt until the link is back.
            liveness.reseedPending = true
            return
        }
        liveness.rescope(to: LiveRuntime.shared.baseURL)

        // Conclusions drawn from this snapshot are only valid for the link that
        // answered it; a re-dial in the middle mints new sids and re-resumes.
        let generation = LiveRuntime.shared.generation
        if liveness.supportedGeneration != generation {
            liveness.supportedGeneration = generation
            liveness.supported = true
        }
        // Sampled BEFORE any source's round trip. Everything below reads a
        // snapshot as authoritative about absence, and it only *is*
        // authoritative about the turns that already existed when it was
        // taken: a `prompt.submit` accepted while this request was in flight
        // is legitimately missing from it, and both immediate-clear paths
        // would then reap a turn that is genuinely running. A bot that
        // started working during the round trip is therefore held to the
        // same two-observation settle grace as any other ambiguous verdict.
        let believedBeforeAsking = LiveRuntime.shared.workingBotIDs

        // Every bot with a chat, plus any the runtime still believes is
        // working. `chats[botID]` is read directly rather than through
        // `chat(for:)`, which would mint a ChatState for every idle bot.
        // Group by the gateway that owns the row: a remote
        // `gateway::profile` sid is invisible to the primary snapshot, and
        // short sids collide across Hermes processes.
        let candidates = Set(chats.keys).union(LiveRuntime.shared.workingBotIDs)
        var byGateway: [String: Set<String>] = [:]
        var unrouted: [String] = []
        for botID in candidates {
            if let gatewayID = livenessOwnerGatewayID(for: botID) {
                byGateway[gatewayID, default: []].insert(botID)
            } else {
                unrouted.append(botID)
            }
        }

        let now = ContinuousClock.now
        var changed = false
        var reattach: [String] = []
        var refresh: [(botID: String, runtimeSID: String?, client: GatewayClient)] = []
        var hadTransientFailure = false
        let primaryGatewayID = LiveRuntime.shared.gatewayID

        for botID in unrouted {
            if settleUnverifiableWorking(botID: botID, now: now) { changed = true }
        }

        for (gatewayID, botIDs) in byGateway {
            if gatewayID == primaryGatewayID, !liveness.supported { continue }

            // Same reasoning one level down, for the bindings rather than the
            // turns, and only for this source: a runtime sid minted by an
            // `ensureSession` that ran while THIS request was in flight is
            // necessarily missing from an answer that predates it. SIDs from
            // another gateway are not this snapshot's to judge.
            let boundBeforeAsking = Set(botIDs.compactMap { botID in
                chats[botID]?.sessionID.flatMap { $0.isEmpty ? nil : $0 }
            })

            let capturedClient: GatewayClient
            do {
                capturedClient = try await routedClient(gatewayID: gatewayID)
            } catch {
                // Unknown, fenced, or still connecting. Leave every belief
                // for this source as it is — another gateway's snapshot is
                // not a substitute.
                hadTransientFailure = true
                continue
            }
            guard LiveRuntime.shared.generation == generation, mode == .live, !isOffline else { return }

            let rows: [LiveSessionRow]
            do {
                rows = try await livenessSnapshot(from: capturedClient, gatewayID: gatewayID)
            } catch let error as GatewayError where error.code == GatewayClient.methodNotFound {
                if gatewayID == primaryGatewayID {
                    liveness.supported = false
                }
                continue
            } catch {
                // Transient (socket dying, gateway busy). Leave every belief
                // for this source as it is — a failed question is not
                // evidence of anything.
                hadTransientFailure = true
                continue
            }
            guard LiveRuntime.shared.generation == generation, mode == .live, !isOffline else { return }

            applyLivenessSnapshot(
                rows, bots: botIDs, trigger: trigger,
                believedBeforeAsking: believedBeforeAsking,
                boundBeforeAsking: boundBeforeAsking,
                client: capturedClient, sourceGatewayID: gatewayID, now: now,
                changed: &changed, reattach: &reattach, refresh: &refresh)
        }

        // A pass that asked every reachable source (or learned the method is
        // gone) has paid the offline-foreground debt. A transient hole on
        // any source leaves the debt so the reaper retries.
        if !hadTransientFailure { liveness.reseedPending = false }

        // Re-attaching hydrates from the resume ack, so a session that advanced
        // while we were away comes back with its transcript whole rather than
        // resuming mid-gap.
        for botID in reattach {
            guard LiveRuntime.shared.generation == generation else { return }
            _ = try? await ensureSession(botID: botID, hydrate: true)
            changed = true
        }

        // Turns that ENDED while we were away never delivered their last
        // tokens; pull the tail so the user does not see the conversation stop
        // mid-thought. The client is the one that answered this bot's
        // snapshot — never a leftover primary.
        for item in refresh {
            guard LiveRuntime.shared.generation == generation else { return }
            await rehydrateTranscript(botID: item.botID, runtimeSID: item.runtimeSID,
                                     client: item.client)
        }

        if changed { try? await refreshRoster() }
    }

    /// The gateway whose `session.active_list` is allowed to judge this bot.
    private func livenessOwnerGatewayID(for botID: String) -> String? {
        stateRoute(for: botID)?.gatewayID ?? gatewayRoute(for: botID)?.gatewayID
    }

    private func livenessSnapshot(from client: GatewayClient,
                                 gatewayID: String) async throws -> [LiveSessionRow] {
        if let override = LivenessRuntime.shared.activeSessionsForTesting {
            return try await override(client, gatewayID)
        }
        return try await client.activeSessions()
    }

    /// Working with no sid and no durable key — the snapshot cannot address
    /// this turn. Same bounded wait the per-source walk uses.
    @discardableResult
    private func settleUnverifiableWorking(botID: String, now: ContinuousClock.Instant) -> Bool {
        let liveness = LivenessRuntime.shared
        guard LiveRuntime.shared.workingBotIDs.contains(botID) else {
            liveness.unverifiableSince[botID] = nil
            return false
        }
        let chat = chats[botID]
        let sid = chat?.sessionID.flatMap { $0.isEmpty ? nil : $0 }
        let key = chat?.storedSessionID.flatMap { $0.isEmpty ? nil : $0 }
            ?? LiveRuntime.shared.canonicalSessionByBot[botID]?.id
        guard sid == nil, key == nil else { return false }
        let since = liveness.unverifiableSince[botID] ?? now
        liveness.unverifiableSince[botID] = since
        guard now - since >= LivenessRuntime.unverifiableGrace else { return false }
        clearWorkingState(botID: botID)
        liveness.unverifiableSince[botID] = nil
        return true
    }

    private func applyLivenessSnapshot(
        _ rows: [LiveSessionRow],
        bots botIDs: Set<String>,
        trigger: LivenessTrigger,
        believedBeforeAsking: Set<String>,
        boundBeforeAsking: Set<String>,
        client: GatewayClient,
        sourceGatewayID: String,
        now: ContinuousClock.Instant,
        changed: inout Bool,
        reattach: inout [String],
        refresh: inout [(botID: String, runtimeSID: String?, client: GatewayClient)]
    ) {
        let liveness = LivenessRuntime.shared
        var byKey: [String: LiveSessionRow] = [:]
        var bySID: [String: LiveSessionRow] = [:]
        for row in rows {
            if !row.sessionKey.isEmpty { byKey[row.sessionKey] = row }
            if !row.sessionID.isEmpty { bySID[row.sessionID] = row }
        }

        for botID in botIDs {
            let chat = chats[botID]
            let sid = chat?.sessionID.flatMap { $0.isEmpty ? nil : $0 }
            let key = chat?.storedSessionID.flatMap { $0.isEmpty ? nil : $0 }
                ?? LiveRuntime.shared.canonicalSessionByBot[botID]?.id
            let believedWorking = LiveRuntime.shared.workingBotIDs.contains(botID)
            // Was this turn already running when the snapshot was taken? Only
            // then can the snapshot be trusted to describe it.
            let predatesSnapshot = believedBeforeAsking.contains(botID)
            // The sid the snapshot is entitled to have an opinion about.
            let judgedSID = sid.flatMap { boundBeforeAsking.contains($0) ? $0 : nil }

            // Nothing addressable to check against. The only defensible move is
            // a bounded wait — clearing on a timer alone is the guess this
            // whole file exists to avoid.
            guard sid != nil || key != nil else {
                if settleUnverifiableWorking(botID: botID, now: now) { changed = true }
                continue
            }
            liveness.unverifiableSince[botID] = nil

            // The sid is the precise identity; the durable key finds the same
            // session after a resume minted a new sid. Both are judged only
            // inside this source's registry.
            let row = sid.flatMap { bySID[$0] } ?? key.flatMap { byKey[$0] }
            // The chat on screen is the only place a gap is visible, and once
            // it is open nothing re-hydrates it — `openChat` already ran. So it
            // is the one chat worth a speculative read after a suspension.
            let watching = trigger == .foreground && botID == openBotID

            switch row?.turn {
            case .busy:
                liveness.settledSince[botID] = nil
                if !believedWorking {
                    // A turn that started while the phone was asleep. The
                    // roster said idle and it was wrong.
                    markWorkingState(botID: botID)
                    changed = true
                }
                // Our sid died with the socket and the durable key found the
                // turn still running under a runtime we are not bound to. A
                // binding that does not name the live runtime receives none of
                // its events, so re-attach — and clear the dead sid first, or
                // `ensureSession` would hand the stale one straight back.
                if let judgedSID, bySID[judgedSID] == nil {
                    unbindDeadRuntime(sid: judgedSID, botID: botID,
                                      sourceGatewayID: sourceGatewayID)
                    reattach.append(botID)
                } else if sid == nil {
                    reattach.append(botID)
                }

            case .building:
                // Agent still being constructed — settles nothing either way.
                liveness.settledSince[botID] = nil

            case .idle:
                // Alive and demonstrably not running.
                if believedWorking {
                    let since = liveness.settledSince[botID] ?? now
                    liveness.settledSince[botID] = since
                    // After a foreground the user cannot have just submitted,
                    // so the verdict needs no second opinion; on a reaper tick
                    // it does, because a submit accepted moments ago legitimately
                    // still reads idle. The `predatesSnapshot` half is the same
                    // rule applied to the round trip itself — a turn that began
                    // while we were asking is not described by the answer.
                    if (trigger == .foreground && predatesSnapshot)
                        || now - since >= LivenessRuntime.settleGrace {
                        clearWorkingState(botID: botID)
                        liveness.settledSince[botID] = nil
                        noteTurnEndedAway(botID: botID, row: row)
                        refresh.append((botID, row?.sessionID, client))
                        changed = true
                    }
                } else {
                    liveness.settledSince[botID] = nil
                    // Nothing was ever marked working — the whole turn (a cron
                    // delivery, a CLI run, a turn that began and ended while
                    // suspended) happened off-socket. The preview is the
                    // gateway's own tail of this transcript, so a mismatch is
                    // proof the chat on screen has fallen behind.
                    if watching, let row, transcriptFellBehind(chats[botID], row: row) {
                        refresh.append((botID, row.sessionID, client))
                    }
                }
                // A sid the registry does not list is dead even when the
                // session lives on under another one.
                if let judgedSID, bySID[judgedSID] == nil {
                    unbindDeadRuntime(sid: judgedSID, botID: botID,
                                      sourceGatewayID: sourceGatewayID)
                }

            case nil:
                // Absent from the registry: the gateway tore this session down
                // when its turn completed and the transport went away
                // (ws-protocol.md §3).
                if let judgedSID {
                    unbindDeadRuntime(sid: judgedSID, botID: botID,
                                      sourceGatewayID: sourceGatewayID)
                }
                if believedWorking {
                    // A turn that already existed when we asked and is not in
                    // the answer has ended — no later event can put it back.
                    // One that began DURING the round trip is merely younger
                    // than the snapshot, so it earns the ordinary
                    // two-observation grace instead of being reaped on the
                    // strength of an answer that could not have mentioned it.
                    let since = liveness.settledSince[botID] ?? now
                    liveness.settledSince[botID] = since
                    guard predatesSnapshot
                            || now - since >= LivenessRuntime.settleGrace else { continue }
                    clearWorkingState(botID: botID)
                    liveness.settledSince[botID] = nil
                    noteTurnEndedAway(botID: botID, row: nil)
                    refresh.append((botID, nil, client))
                    changed = true
                } else if watching {
                    // No row means no preview to compare against, and the
                    // teardown itself says the socket outlived this session.
                    // One read by durable key is the cheapest way to be sure
                    // the open chat is not missing its last exchange.
                    refresh.append((botID, nil, client))
                }
            }
        }
    }
}

// MARK: - State transitions

extension AppModel {

    /// Mirror of AppModelLive's private `setWorking(_:false)` + `recomputeStatus`,
    /// plus the parts a lost `message.complete` also owed us: the composer's
    /// stop control, the typing indicator and any tool chip still spinning.
    private func clearWorkingState(botID: String) {
        let runtime = LiveRuntime.shared
        runtime.workingBotIDs.remove(botID)
        if let idx = bots.firstIndex(where: { $0.id == botID }) {
            bots[idx].task = nil
            // Approvals outrank idle — a bot can be blocked on one without a
            // turn running.
            bots[idx].status = approvals.contains { $0.botID == botID } ? .approval : .idle
        }
        guard let chat = chats[botID] else { return }
        chat.isTyping = false
        chat.isRunning = false
        // A turn that ended off-socket left its `tool.complete` undelivered; a
        // chip left spinning inside a finished turn is the same phantom one
        // scale down. `interrupted: true` marks them failed rather than done:
        // nothing ever confirmed success.
        finishRunningTools(in: chat, interrupted: true)
    }

    /// The snapshot says a turn is running that the roster shows idle. Mirrors
    /// what `bindSession` does for a resume ack that comes back `running`.
    private func markWorkingState(botID: String) {
        LiveRuntime.shared.workingBotIDs.insert(botID)
        if let idx = bots.firstIndex(where: { $0.id == botID }), bots[idx].status != .approval {
            bots[idx].status = .working
        }
        guard let chat = chats[botID] else { return }
        chat.isRunning = true
        // The typing indicator stands in for tokens that have not arrived yet;
        // a bubble already streaming is the better signal and owns the slot.
        if chat.messages.last?.isStreaming != true { chat.isTyping = true }
    }

    /// A runtime sid the registry no longer lists. Drop every binding that
    /// names it so the next open or send re-resumes from the durable key —
    /// the same treatment the `session.reclaimed` event gets
    /// (AppModelLive.swift), and for the same reason. The owning gateway is
    /// required: short sids collide across retained Hermes processes, so a
    /// remote death must not clear `sessionToBot` or orphan a primary card.
    func unbindDeadRuntime(sid: String, botID: String, sourceGatewayID: String? = nil) {
        let runtime = LiveRuntime.shared
        let gatewayID = sourceGatewayID
            ?? stateRoute(for: botID)?.gatewayID
            ?? runtime.gatewayID
        if let gatewayID, gatewayID == runtime.gatewayID {
            if runtime.sessionToBot[sid] == botID {
                runtime.sessionToBot.removeValue(forKey: sid)
            }
        } else if let gatewayID {
            let routed = GatewaySessionRoute(gatewayID: gatewayID, sessionID: sid)
            if runtime.routedSessionToBot[routed] == botID {
                runtime.routedSessionToBot.removeValue(forKey: routed)
            }
        }
        if chats[botID]?.sessionID == sid {
            // The durable resume that follows must know which runtime binding
            // the unresolved mutation belonged to, even while ChatState is
            // intentionally nilled during the reattach window.
            parkRuntimeSessionBeforeClearing(botID: botID)
            chats[botID]?.sessionID = nil
        }
        // Approval cards bound to a dead runtime cannot be answered: the
        // request id resolves to no session, so both buttons would fail
        // silently. Leaving an unanswerable card up is worse than none.
        guard let gatewayID else { return }
        let dead = GatewaySessionRoute(gatewayID: gatewayID, sessionID: sid)
        let orphaned = runtime.approvalTargets.filter { $0.value.session == dead }.map(\.key)
        guard !orphaned.isEmpty else { return }
        for id in orphaned { runtime.approvalTargets.removeValue(forKey: id) }
        for id in orphaned { ApprovalBridges.shared.details.removeValue(forKey: id) }
        approvals.removeAll { orphaned.contains($0.id) }
    }

    /// The busy→idle edge that a lost `message.complete` never fired. Desktop
    /// uses the same edge to raise the "your turn" unread dot
    /// (use-background-sync.ts:247-268) — on a phone that edge is the whole
    /// point, because the app was not on screen when the answer landed.
    private func noteTurnEndedAway(botID: String, row: LiveSessionRow?) {
        guard let idx = bots.firstIndex(where: { $0.id == botID }) else { return }
        if let row, !row.preview.isEmpty {
            bots[idx].preview = Self.previewLine(row.preview)
            bots[idx].previewTime = Self.shortTime(row.lastActive)
        }
        recordUnread(for: botID)
    }
}

// MARK: - Stale-chat refresh

extension AppModel {

    /// Re-read a transcript that advanced while the app was away, and graft the
    /// new tail onto what is already on screen.
    ///
    /// Only chats that already show something are refreshed: an untouched chat
    /// has no visible gap to close and hydrates on its first open
    /// (AppModelLive+CanonicalChat.swift), so fetching it here would be a round
    /// trip nobody sees.
    private func rehydrateTranscript(botID: String, runtimeSID: String?,
                                    client: GatewayClient) async {
        guard mode == .live, !isOffline else { return }
        guard let chat = chats[botID], !chat.messages.isEmpty else { return }
        let profile = GatewayBotRoute(qualifiedID: botID)?.profile ?? botID

        var payload: JSONValue?
        // A session still in the registry answers over WS with row ids and the
        // full ancestor lineage; one that has ended is only reachable through
        // the REST tail page, addressed by its durable key. Both go to the
        // captured client that owns this bot — never a leftover primary.
        if let runtimeSID, !runtimeSID.isEmpty {
            if let override = LivenessRuntime.shared.sessionHistoryForTesting {
                payload = try? await override(client, livenessOwnerGatewayID(for: botID) ?? "",
                                              runtimeSID)
            } else {
                payload = try? await client.sessionHistory(runtimeSID)
            }
        }
        if payload == nil, let stored = chat.storedSessionID, !stored.isEmpty {
            payload = try? await client.latestSessionMessages(storedID: stored, profile: profile)
        }
        guard let payload else { return }

        let fetched = Self.chatMessages(fromTranscript: payload)
        guard !fetched.isEmpty else { return }
        graft(fetched, into: chat)
    }

    /// Merge a freshly-read transcript into a chat without losing either half.
    ///
    /// Neither side is wholly authoritative. The fetched page is the newest
    /// tail only (REST pages `order=latest`, limit 200), so replacing outright
    /// would truncate a long chat the user has scrolled back through; the
    /// in-memory transcript is missing everything that landed while the socket
    /// was down, and its last bubble may be a half-streamed one the persisted
    /// row supersedes. So: anchor the fetched page on the newest settled
    /// message we already hold and append only what comes after it.
    private func graft(_ fetched: [ChatMessage], into chat: ChatState) {
        // Trailing rows the store cannot be expected to carry, peeled off so
        // the anchor below lands on a real transcript row: user bubbles typed
        // while this read was in flight (`prompt.submit` has not persisted
        // them) and Talaria's own system lines, which are never persisted.
        var settled = chat.messages
        var pending: [ChatMessage] = []
        while let last = settled.last, last.author != .bot {
            pending.insert(last, at: 0)
            settled.removeLast()
        }
        // A partial streamed bubble is exactly what the persisted row replaces.
        if settled.last?.isStreaming == true { settled.removeLast() }

        // A user bubble the store DOES already hold would otherwise double up;
        // a system line can never be in the fetched page, so it always rides.
        let carried = pending.filter { row in
            row.author == .system
                || !fetched.suffix(8).contains { Self.sameTranscriptRow($0, row) }
        }

        guard let anchor = settled.last else {
            chat.messages = fetched + carried
            return
        }
        if let index = fetched.lastIndex(where: { Self.sameTranscriptRow($0, anchor) }) {
            chat.messages = settled + fetched[fetched.index(after: index)...] + carried
        } else if fetched.count > settled.count {
            // No overlap and the server holds more: the local view has drifted
            // far enough (a compression, a branch, a long absence) that the
            // fetched page is simply the better transcript.
            chat.messages = fetched + carried
        }
        // Otherwise the page describes older ground than what is on screen —
        // grafting it would rewind the chat, so leave the transcript alone.
    }

    /// Row identity across two projections of the same transcript. `row_id`
    /// (WS) and `id` (REST) are the durable key when both sides carry one;
    /// anything built from a live stream has none, so author + text is the
    /// fallback.
    private static func sameTranscriptRow(_ a: ChatMessage, _ b: ChatMessage) -> Bool {
        if let left = a.rowID, let right = b.rowID { return left == right }
        return a.author == b.author && a.text == b.text
    }

    /// Does the gateway's tail of this conversation differ from ours?
    ///
    /// An idle row's `preview` IS the last message of the session, built by
    /// `_message_preview` (server.py:8558) — flatten the whitespace, cut at
    /// 160. Reproducing that locally and comparing is a whole-transcript
    /// signature for the price of a field we already have. Only ever used to
    /// decide whether a read is worth making: a false positive costs one
    /// request and grafts nothing.
    private func transcriptFellBehind(_ chat: ChatState?, row: LiveSessionRow) -> Bool {
        guard let chat, !chat.messages.isEmpty, !row.preview.isEmpty else { return false }
        // System lines are Talaria's own voice and were never in the history
        // the preview was built from.
        guard let tail = chat.messages.last(where: { $0.author != .system && !$0.text.isEmpty })
        else { return true }
        return Self.previewSignature(tail.text) != row.preview
    }

    /// `" ".join(text.split())[:160]` in Swift.
    private static func previewSignature(_ text: String) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(160))
    }
}
