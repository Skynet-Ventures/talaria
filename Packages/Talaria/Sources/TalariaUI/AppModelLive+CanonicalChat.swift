import Foundation
import TalariaKit

// ── The canonical forever-chat ───────────────────────────────────────────────
//
// "Each bot has exactly one chat, forever." Current Hermes identifies it by
// the exact `(profile, title: "Bot Chat")` registry row. Stored-session ids in
// ui_meta were the old identity and are deliberately ignored: every lost-chat
// incident upstream traced back to a dangling or stolen pointer.
//
// Ported from apps/desktop/src/plugins/hermes-bots/plugin.js:
//   findExistingCanonicalChat 4092-4110 exact hidden title lookup
//   createCanonicalChat       4113-4202 recheck, hidden birth, eager title
//   openBotCanonicalChat      4210-4221 exact lookup on every bot-row open
//
// Gateway contract cited inline from tui_gateway/methods_session.py,
// tui_gateway/methods_profiles.py and hermes_cli/web_routers/sessions.py.

// MARK: - Runtime (side table)

/// Canonical-chat bookkeeping. `AppModel`'s stored properties live in
/// AppModel.swift (another owner) and extensions cannot add storage, so this
/// rides in a MainActor singleton like `LiveRuntime` does.
@MainActor
final class CanonicalChatRuntime {
    static let shared = CanonicalChatRuntime()

    /// One resolution per bot at a time — a double tap must not mint two
    /// canonical chats (plugin.js:2742, `canonicalCreations`).
    var opens: [String: Task<Void, Never>] = [:]

    /// The exact birth operation currently allowed to settle a newly-created
    /// chat. A canceled/late kickoff must never mutate a replacement binding.
    var kickoffs: [String: UUID] = [:]
    /// Full lease metadata for the active kickoff. `kickoffs` remains as the
    /// small compatibility/ownership index, while this table lets a reconnect
    /// migrate the runtime sid without ever changing the source route.
    var kickoffLeases: [String: CanonicalKickoffLease] = [:]
    var ambiguousKickoffs: [String: CanonicalKickoffLease] = [:]

    /// Clear primary-source in-flight work while retaining routed operations
    /// owned by still-connected secondary clients. There is no canonical id
    /// cache to clear; the next open consults the title registry again.
    func resetPrimaryScope(retainAmbiguousForReconnect: Bool = false,
                           retainLocalPins _: Bool = false) {
        let primaryOpens = opens.filter { GatewayBotRoute(qualifiedID: $0.key) == nil }
        for task in primaryOpens.values { task.cancel() }
        for key in primaryOpens.keys { opens.removeValue(forKey: key) }
        let primaryLeases = kickoffLeases.filter {
            GatewayBotRoute(qualifiedID: $0.key) == nil
        }
        for key in primaryLeases.keys where ambiguousKickoffs[key] == nil {
            kickoffLeases.removeValue(forKey: key)
        }
        let primaryKickoffs = kickoffs.keys.filter { GatewayBotRoute(qualifiedID: $0) == nil }
        for key in primaryKickoffs where ambiguousKickoffs[key] == nil {
            kickoffs.removeValue(forKey: key)
        }
        if !retainAmbiguousForReconnect {
            let ambiguousPrimary = ambiguousKickoffs.keys.filter {
                GatewayBotRoute(qualifiedID: $0) == nil
            }
            for key in ambiguousPrimary {
                ambiguousKickoffs.removeValue(forKey: key)
                kickoffs.removeValue(forKey: key)
                kickoffLeases.removeValue(forKey: key)
            }
        }
    }

    func resetRoutedScope(gatewayID: String) {
        let prefix = gatewayID + GatewayBotRoute.separator
        let tasks = opens.filter { $0.key.hasPrefix(prefix) }
        for task in tasks.values { task.cancel() }
        for key in tasks.keys { opens.removeValue(forKey: key) }
        let leases = kickoffLeases.filter { $0.key.hasPrefix(prefix) }
        for key in leases.keys where ambiguousKickoffs[key] == nil {
            kickoffLeases.removeValue(forKey: key)
        }
        let routedKickoffs = kickoffs.keys.filter { $0.hasPrefix(prefix) }
        for key in routedKickoffs where ambiguousKickoffs[key] == nil {
            kickoffs.removeValue(forKey: key)
        }
    }

    /// Migrate a kickoff across a runtime-sid rotation only when every stable
    /// identity agrees. The route is immutable: a same-named profile on a new
    /// source is a replacement chat, never a continuation of this birth.
    @discardableResult
    func migrateKickoff(botID: String, route: GatewayBotRoute,
                        sessionID: String, storedID: String,
                        chatID: ObjectIdentifier) -> Bool {
        var migrated = false
        if var lease = kickoffLeases[botID], kickoffs[botID] == lease.id,
           lease.chatID == chatID, lease.storedID == storedID,
           lease.route.map({ $0 == route }) ?? true {
            lease.sessionID = sessionID
            kickoffLeases[botID] = lease
            migrated = true
        }
        if var lease = ambiguousKickoffs[botID], kickoffs[botID] == lease.id,
           lease.chatID == chatID, lease.storedID == storedID,
           lease.route.map({ $0 == route }) ?? true {
            lease.sessionID = sessionID
            ambiguousKickoffs[botID] = lease
            migrated = true
        }
        return migrated
    }

    /// Retire a kickoff only for the exact source/durable/chat binding. This is
    /// the fail-closed counterpart used by profile lifecycle recovery.
    @discardableResult
    func retireKickoff(botID: String, route: GatewayBotRoute,
                       storedID: String?, chatID: ObjectIdentifier?,
                       operationID: UUID? = nil) -> Bool {
        let active = kickoffLeases[botID]
        let ambiguous = ambiguousKickoffs[botID]
        let owns: (CanonicalKickoffLease?) -> Bool = { lease in
            guard let lease else { return false }
            // Missing identity is not an ownership proof. In particular, a
            // lifecycle caller that has already lost its ChatState or durable
            // key must not retire a replacement birth merely because the bot
            // id was reused. Empty is a valid stored id for an ephemeral
            // create, but it must be supplied explicitly and match exactly.
            guard let storedID, let chatID,
                  lease.storedID == storedID,
                  lease.chatID == chatID,
                  lease.route.map({ $0 == route }) ?? true,
                  self.kickoffs[botID] == lease.id else { return false }
            return operationID.map { $0 == lease.id } ?? false
        }
        let owned: CanonicalKickoffLease?
        if let active, owns(active) {
            owned = active
        } else if let ambiguous, owns(ambiguous) {
            owned = ambiguous
        } else {
            owned = nil
        }
        guard let owned else { return false }
        if self.kickoffLeases[botID]?.id == owned.id { self.kickoffLeases[botID] = nil }
        if self.ambiguousKickoffs[botID]?.id == owned.id { self.ambiguousKickoffs[botID] = nil }
        if self.kickoffs[botID] == owned.id { self.kickoffs[botID] = nil }
        return true
    }
}

struct CanonicalKickoffLease: Equatable {
    var id: UUID
    var botID: String
    var sessionID: String
    var storedID: String
    var rowID: UUID?
    var chatID: ObjectIdentifier
    var submitStarted = false
    /// The source profile is immutable for the lifetime of this birth. A
    /// default keeps older focused tests/source callers source-compatible;
    /// production always supplies it at claim time.
    var route: GatewayBotRoute? = nil
    /// Durable transcript identity/count sampled before the optimistic kickoff
    /// row. An old duplicate prompt is not proof that this birth was accepted.
    var baselineDurableRowIDs: Set<Int> = []
    var baselineDurableRowCount: Int = 0
    /// User bodies that predate this birth, including optimistic rows. A
    /// resume in-flight body with the same text is historical evidence, not
    /// proof of this kickoff.
    var baselineDurableUserTexts: Set<String> = []
}

extension GatewayError {
    /// `session.resume` answers **4007** for a durable key with no DB row
    /// (methods_session.py:367) — the definitive "this conversation is gone".
    /// Distinct from 4001 (`sessionNotFound`), which upstream uses for "no
    /// live session" on the runtime-sid RPCs (methods_tools.py:607).
    static let storedSessionGone = 4007
}

// MARK: - Resolution

/// What one resume attempt settled on.
private enum CanonicalAttach {
    case attached(sessionID: String, storedID: String)
    /// The gateway is certain the row does not exist (4007).
    case missing
    /// Anything else — transport, backend restart, an older gateway.
    case failed(Error)
}

/// One literal owns the Bot Mode title across the nonisolated evidence check
/// and AppModel's actor-isolated open path.
private let canonicalBotChatTitle = "Bot Chat"

enum CanonicalTitleOwnership {
    static func isAuthoritative(_ receipt: SessionTitleReceipt,
                                expected: String = canonicalBotChatTitle) -> Bool {
        !receipt.pending && receipt.title == expected
    }
}

enum CanonicalScratchReleaseDecision: Equatable {
    case preserve
    case authoritativeBirthReady
}

/// Evidence carried by a roster summary is intentionally narrower than
/// "whatever session happened most recently." A compression tip can have a
/// different leaf title, so `rootTitle` is authoritative when present; only a
/// legacy summary without it may use the leaf title. The id remains the
/// durable registry root — `session.resume` follows it to a resolved tip.
enum CanonicalBotChatEvidence {
    static func durableID(in session: HermesProfile.ProfileSessionRef?) -> String? {
        guard let session, !session.id.isEmpty, session.isCanonicalBotChat else { return nil }
        return session.id
    }
}

/// A transcript REST read is safe to retry only when URLSession reports the
/// typed timeout condition. In particular, a generic gateway failure, a
/// cancelled task, or a missing stored row must not be "helped" by falling
/// back through canonical resolution again: that can turn a read retry into a
/// second chat birth.
struct CanonicalHydrationTimeout: Error {
    let storedID: String
    /// Preserve the URLSession error byte-for-byte (code and userInfo). The
    /// wrapper is retry control flow only and must never escape to callers.
    let original: URLError

    static func wraps(_ error: Error, storedID: String) -> CanonicalHydrationTimeout? {
        guard let url = error as? URLError, url.code == .timedOut,
              !storedID.isEmpty else { return nil }
        return CanonicalHydrationTimeout(storedID: storedID, original: url)
    }
}

/// Reconcile an authoritative stored page with UI rows that became newer
/// while hydration was suspended. Stored projections mint fresh UUIDs, so
/// identity alone cannot find overlap; durable row ids and a short semantic
/// tail do. The live candidate wins presentation state (streaming, reasoning,
/// tools) without throwing away a row id learned from storage.
enum TranscriptHydrationMerge {
    static func merge(history: [ChatMessage], baseline: [ChatMessage],
                      current: [ChatMessage], clearWhenEmpty: Bool,
                      protectedIDs: Set<UUID> = []) -> [ChatMessage] {
        guard !history.isEmpty else {
            // Clearing is safe only when nothing changed during the fallback.
            // A user send, assistant delta, or error that landed while REST
            // was suspended is newer than an empty/failed response.
            if clearWhenEmpty, current == baseline,
               current.allSatisfy({ $0.author == .system }) {
                return []
            }
            return current
        }

        let baselineByID = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id, $0) })
        let baselineUsers = trailingUserIDs(in: baseline)
        let currentUsers = trailingUserIDs(in: current)
        let baselineLiveTurn = liveTurnIDs(in: baseline)
        let sameSessionTail = clearWhenEmpty ? Set<UUID>() : latestTurnIDs(in: current)
        let candidates = current.filter { message in
            let changed = baselineByID[message.id].map { $0 != message } ?? true
            let live = message.isStreaming
                || message.toolCalls.contains(where: { $0.state == .running })
            return changed || live || baselineUsers.contains(message.id)
                || currentUsers.contains(message.id) || baselineLiveTurn.contains(message.id)
                || sameSessionTail.contains(message.id) || protectedIDs.contains(message.id)
        }

        var merged = history
        let overlap = tailOverlap(history: history, candidates: candidates,
                                  baselineByID: baselineByID)
        let historyStart = history.count - overlap
        for offset in 0..<overlap {
            merged[historyStart + offset] = overlay(
                candidates[offset], on: merged[historyStart + offset])
        }
        merged.append(contentsOf: candidates.dropFirst(overlap))
        return merged
    }

    private static func trailingUserIDs(in messages: [ChatMessage]) -> Set<UUID> {
        Set(messages.reversed().prefix { $0.author == .user }.map(\.id))
    }

    /// A resume inflight snapshot is a turn, not two unrelated rows. Preserve
    /// its user echo together with the streaming assistant row so a stale REST
    /// page cannot keep the delta while dropping the prompt it answers.
    private static func liveTurnIDs(in messages: [ChatMessage]) -> Set<UUID> {
        guard let live = messages.lastIndex(where: {
            $0.isStreaming || $0.toolCalls.contains(where: { $0.state == .running })
        }) else { return [] }
        var ids: Set<UUID> = [messages[live].id]
        var index = live
        while index > messages.startIndex {
            let previous = messages.index(before: index)
            guard messages[previous].author == .user else { break }
            ids.insert(messages[previous].id)
            index = previous
        }
        return ids
    }

    /// When hydrating the same durable binding, its latest completed turn is
    /// also newer than a fallback page that ends early. Rebinding callers set
    /// `clearWhenEmpty`, so rows from the session being left are never carried
    /// into the selected conversation by this rule.
    private static func latestTurnIDs(in messages: [ChatMessage]) -> Set<UUID> {
        guard !messages.isEmpty else { return [] }
        let start = messages.lastIndex(where: { $0.author == .user })
            ?? messages.index(before: messages.endIndex)
        return Set(messages[start...].map(\.id))
    }

    /// Stored history can have persisted none, some, or all of the candidate
    /// live tail. Only an ordered suffix/prefix overlap is safe: semantic
    /// prefix matching across a newly appended user row would collapse two
    /// distinct assistant turns.
    private static func tailOverlap(history: [ChatMessage], candidates: [ChatMessage],
                                    baselineByID: [UUID: ChatMessage]) -> Int {
        let limit = min(history.count, candidates.count)
        for count in stride(from: limit, through: 1, by: -1) {
            let start = history.count - count
            let matches = (0..<count).allSatisfy { offset in
                compatible(history[start + offset], candidates[offset],
                           existedAtBaseline: baselineByID[candidates[offset].id] != nil)
            }
            if matches { return count }
        }
        return 0
    }

    private static func compatible(_ stored: ChatMessage, _ live: ChatMessage,
                                   existedAtBaseline: Bool) -> Bool {
        guard stored.author == live.author else { return false }
        // A post-baseline user row is optimistic by definition. Identical
        // text in stored history may be an older repeated prompt ("retry" is
        // common), so only a row already present at the baseline may overlap.
        if live.author == .user, !existedAtBaseline { return false }
        if let rowID = live.rowID, stored.rowID == rowID { return true }
        if stored.text == live.text { return true }
        return existedAtBaseline && live.author == .bot
            && !stored.text.isEmpty && !live.text.isEmpty
            && (stored.text.hasPrefix(live.text) || live.text.hasPrefix(stored.text))
    }

    private static func overlay(_ live: ChatMessage, on stored: ChatMessage) -> ChatMessage {
        var row = live
        if stored.text.count > live.text.count, stored.text.hasPrefix(live.text) {
            row.text = stored.text
        }
        row.time = live.time ?? stored.time
        row.card = live.card ?? stored.card
        row.reasoning = live.reasoning ?? stored.reasoning
        if live.toolCalls.isEmpty { row.toolCalls = stored.toolCalls }
        row.rowID = live.rowID ?? stored.rowID
        row.failure = TurnFailureLifecycle.merge(stored.failure, live.failure)
        return row
    }
}

/// Hiding owned sessions is deliberately silent like desktop, but silence
/// must not erase operational evidence. Only the two wire answers that mean
/// "this capability/row is absent" are benign; transport, auth, routing, and
/// every other backend failure belong in gateway diagnostics for retry sweeps.
enum OwnedSessionHidingFailure {
    static func isBenign(_ error: Error) -> Bool {
        guard let gateway = error as? GatewayError else { return false }
        return gateway.code == -32_601 || gateway.code == GatewayError.storedSessionGone
    }

    @MainActor
    static func record(_ error: Error, gatewayID: String) {
        guard !isBenign(error) else { return }
        ConnectionSupervisor.shared.note(error: error, forGatewayID: gatewayID)
    }
}

extension AppModel {

    /// Desktop titles every canonical chat "Bot Chat" (plugin.js:2757). The
    /// title is load-bearing, not decoration: `session.resume` falls back to an
    /// exact title lookup when the id misses (methods_session.py:349-352 →
    /// hermes_state.py:8468), so this is how a phone finds a forever chat
    /// minted on the laptop — and why it can
    /// never mint a second one alongside it.
    static var canonicalChatTitle: String { canonicalBotChatTitle }
    static var canonicalKickoffPrompt: String { BotModeStrings.canonicalKickoffPrompt }

    // MARK: The primary tap

    /// Land in the bot's forever chat, whatever the chat was last bound to.
    /// An artifact/inbox/sessions-sheet jump leaves a scratch session behind;
    /// desktop's roster row still opens the title registry, so the
    /// primary tap re-resolves rather than resuming whatever is bound.
    func enterCanonicalChat(botID: String) async {
        guard mode == .live,
              !isOffline || GatewayBotRoute(qualifiedID: botID) != nil else { return }
        let runtime = CanonicalChatRuntime.shared

        // Coalesce: a double tap, or a tap racing a deep link, must resolve
        // once (plugin.js:2742).
        if let inflight = runtime.opens[botID] {
            await inflight.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            // A send that beat the tap owns an attach. Let it settle before
            // touching the binding, so the rebind below cannot be undone by a
            // task that is already resolving.
            if let pending = LiveRuntime.shared.attachTasks[botID] { _ = try? await pending.value }

            let chat = self.chat(for: botID)
            if let lease = self.ambiguousCanonicalKickoffOwning(botID: botID, chat: chat) {
                // `ensureSession` intentionally trusts an existing runtime SID,
                // but an ambiguous kickoff needs stronger evidence: resume the
                // exact durable target and hydrate it. Never submit kickoff a
                // second time while acceptance is unresolved.
                do {
                    guard let route = self.gatewayRoute(for: botID) else {
                        throw GatewayRouteError.noRoute
                    }
                    let client = try await self.routedClient(for: route)
                    await self.reconcileAmbiguousCanonicalKickoff(
                        lease, route: route, client: client)
                    if CanonicalChatRuntime.shared.ambiguousKickoffs[botID] == nil {
                        await self.refreshContext(botID: botID)
                    }
                } catch {
                    self.reportCanonicalFailure(error, botID: botID)
                }
                return
            }
            if self.retainedMutationNeedsReconciliation(botID: botID) {
                self.scheduleRetainedMutationReconciliation(botID: botID)
                return
            }
            do {
                guard let route = self.gatewayRoute(for: botID) else {
                    throw GatewayRouteError.noRoute
                }
                let client = try await self.routedClient(for: route)
                _ = try await self.attachCanonicalSession(
                    botID: botID, route: route, client: client,
                    hydrate: true, honorsExplicitBinding: false)
                // Context meter is ancillary. Do not hold first paint or a
                // coalesced second tap behind session.context_breakdown.
                Task { @MainActor [weak self] in
                    await self?.refreshContext(botID: botID)
                }
            } catch is CancellationError {
                // Superseded by another attach; that one owns the outcome.
            } catch {
                self.reportCanonicalFailure(error, botID: botID)
            }
        }
        runtime.opens[botID] = task
        // Released in a defer, and only if the slot is still ours: a tap that
        // arrived between this task finishing and the slot being cleared would
        // otherwise await an already-finished resolution and return having
        // done nothing, leaving that tap on whatever chat was bound.
        defer { if runtime.opens[botID] == task { runtime.opens[botID] = nil } }
        await task.value
    }

    func ambiguousCanonicalKickoffOwning(botID: String,
                                         chat: ChatState) -> CanonicalKickoffLease? {
        guard let lease = CanonicalChatRuntime.shared.ambiguousKickoffs[botID],
              CanonicalChatRuntime.shared.kickoffs[botID] == lease.id,
              ObjectIdentifier(chat) == lease.chatID,
              chat.sessionID == lease.sessionID,
              lease.storedID.isEmpty || chat.storedSessionID == lease.storedID else { return nil }
        return lease
    }

    /// Resolve and attach the session a send/open should land in, in desktop's
    /// order: an explicit scratch binding when appropriate, then the exact
    /// canonical registry row, then a rechecked birth. Returns the runtime sid.
    ///
    /// `ensureSession` funnels every create/resume through here, so a message
    /// typed before the chat finished opening lands in the forever chat rather
    /// than forking a fresh session — the failure this phase exists to fix.
    func attachCanonicalSession(botID: String, route: GatewayBotRoute,
                                client: GatewayClient, hydrate: Bool,
                                honorsExplicitBinding: Bool = true) async throws -> String {
        try Task.checkCancellation()
        let chat = chat(for: botID)
        let profile = route.profile
        guard let lifecycleToken = profileLifecycleGenerationToken(for: botID),
              profileLifecycleAccepts(lifecycleToken) else {
            throw CancellationError()
        }
        let gatewayGeneration = LiveRuntime.shared.generation
        func acceptsSnapshot() -> Bool {
            profileLifecycleAcceptsGatewaySnapshot(
                route: route, client: client, generation: gatewayGeneration)
        }

        // An explicit binding wins: the user named this conversation (sessions
        // sheet, artifact jump, inbox jump), or a reconnect is re-attaching it.
        if honorsExplicitBinding, let bound = chat.storedSessionID, !bound.isEmpty {
            switch await attach(bound, botID: botID, route: route,
                                hydrate: hydrate, client: client,
                                lifecycleToken: lifecycleToken,
                                gatewayGeneration: gatewayGeneration) {
            case .attached(let sid, _): return sid
            case .missing: break            // vanished under us — re-resolve
            case .failed(let error): throw error
            }
        }

        // Current Hermes' registry is the sole canonical authority. A failed
        // lookup is not an empty lookup: propagate it so an outage can never
        // mint a sibling forever-chat.
        if let row = try await client.canonicalBotChat(profile: profile) {
            guard acceptsSnapshot() else { throw CancellationError() }
            LiveRuntime.shared.canonicalSessionByBot[botID] = CanonicalSessionIdentity(
                id: row.id, resolvedID: row.resolvedID)
            switch await attach(row.resumeID, botID: botID, route: route,
                                hydrate: hydrate, client: client,
                                lifecycleToken: lifecycleToken,
                                gatewayGeneration: gatewayGeneration,
                                durableID: row.id) {
            case .attached(let sid, _): return sid
            case .missing:
                // The exact row disappeared between lookup and resume. Recheck
                // before birth; only a successful empty answer authorizes it.
                LiveRuntime.shared.canonicalSessionByBot[botID] = nil
                break
            case .failed(let error): throw error
            }
        }

        if let row = try await client.canonicalBotChat(profile: profile) {
            guard acceptsSnapshot() else { throw CancellationError() }
            LiveRuntime.shared.canonicalSessionByBot[botID] = CanonicalSessionIdentity(
                id: row.id, resolvedID: row.resolvedID)
            switch await attach(row.resumeID, botID: botID, route: route,
                                hydrate: hydrate, client: client,
                                lifecycleToken: lifecycleToken,
                                gatewayGeneration: gatewayGeneration,
                                durableID: row.id) {
            case .attached(let sid, _): return sid
            case .missing: throw GatewayError(code: GatewayError.storedSessionGone,
                                              message: "Canonical session changed during open")
            case .failed(let error): throw error
            }
        }
        LiveRuntime.shared.canonicalSessionByBot[botID] = nil

        // Birth. A brand-new bot: mint the chat under the canonical title,
        // then submit the
        //     same kickoff desktop uses (plugin.js:2343-2390). The gateway
        //     prunes zero-message sessions, so the forever-chat is born with
        //     the bot introducing itself — a local roster-preview bubble is
        //     not a first turn.
        //
        //     Born hidden, like every Bot Mode session (plugin.js:2758-2763,
        //     BOT-MODE-PARITY §canonical-chat): hidden means *owned*, not
        //     secret. Without it a phone-born forever chat drops a "Bot Chat"
        //     row into every shared list — desktop recents, the resume picker
        //     — that a desktop-born one never appears in.
        let live = try await client.createSession(profile: profile,
                                                  title: Self.canonicalChatTitle,
                                                  hidden: true)
        guard acceptsSnapshot() else {
            throw CancellationError()
        }
        guard !live.sessionID.isEmpty else {
            throw GatewayError(code: -8, message: "session.create returned no id")
        }
        // Current Hermes accepts eager title at create and still exposes the
        // explicit title RPC. Keep the second write for gateways that defer or
        // ignore the create title; method-not-found alone is compatibility.
        do {
            let receipt = try await client.titleSession(
                runtimeID: live.sessionID, title: Self.canonicalChatTitle)
            if !CanonicalTitleOwnership.isAuthoritative(receipt) {
                // A pending/mismatched title is not ownership. UNIQUE title
                // materialization may have selected another row; re-read the
                // registry and adopt only its winner, never submit kickoff to
                // this unproven create.
                guard let winner = try await client.canonicalBotChat(profile: profile) else {
                    throw GatewayError(
                        code: GatewayClient.exactTitleLookupIndeterminate,
                        message: "Canonical Bot Chat title is not authoritative yet")
                }
                guard acceptsSnapshot() else { throw CancellationError() }
                LiveRuntime.shared.canonicalSessionByBot[botID] = CanonicalSessionIdentity(
                    id: winner.id, resolvedID: winner.resolvedID)
                switch await attach(
                    winner.resumeID, botID: botID, route: route,
                    hydrate: hydrate, client: client,
                    lifecycleToken: lifecycleToken,
                    gatewayGeneration: gatewayGeneration,
                    durableID: winner.id) {
                case .attached(let sid, _): return sid
                case .missing:
                    throw GatewayError(
                        code: GatewayClient.exactTitleLookupIndeterminate,
                        message: "Canonical Bot Chat changed during title recovery")
                case .failed(let error): throw error
                }
            }
        } catch let error as GatewayError where error.code == -32_601 {
            // Older gateway: create(title:) is the compatibility path.
        }
        // The row is now authoritative (or an older gateway accepted the eager
        // create title). Only here may a roster-row open leave its explicit
        // scratch binding; every earlier lookup/create/title failure preserves
        // transcript, queue, and visible ownership for retry.
        if !honorsExplicitBinding {
            applyCanonicalScratchRelease(
                botID: botID, decision: .authoritativeBirthReady)
        }
        let stored = live.storedSessionID
        if !stored.isEmpty {
            LiveRuntime.shared.canonicalSessionByBot[botID] = CanonicalSessionIdentity(id: stored)
        }
        var lease = claimCanonicalKickoff(sessionID: live.sessionID, storedID: stored,
                                          botID: botID, route: route)
        do {
            try Task.checkCancellation()
            guard acceptsSnapshot() else {
                throw CancellationError()
            }
            adopt(live, storedID: stored.isEmpty ? nil : stored, botID: botID,
                  sourceGatewayID: route.gatewayID)
            if let migrated = CanonicalChatRuntime.shared.kickoffLeases[botID],
               migrated.id == lease.id {
                // `adopt` may have rotated the runtime sid while this birth
                // was being created. Keep the route immutable, but submit to
                // the newly-authoritative runtime address.
                lease = migrated
            }
            try Task.checkCancellation()
            let shouldSubmitKickoff = beginCanonicalKickoff(&lease)
            if shouldSubmitKickoff {
                lease.submitStarted = true
                try await submitCanonicalKickoff(lease: lease, client: client)
            }
            finishCanonicalKickoff(lease)
        } catch let kickoffError {
            if lease.submitStarted && PromptMutationFailure.isAmbiguous(kickoffError) {
                CanonicalChatRuntime.shared.ambiguousKickoffs[botID] = lease
                await reconcileAmbiguousCanonicalKickoff(
                    lease, route: route, client: client)
            } else { _ = rollbackCanonicalKickoffIfOwned(lease) }
            throw kickoffError
        }
        return live.sessionID
    }

    /// Desktop's first turn for a brand-new forever-chat. Bind first, then
    /// submit, so the intro reply is visible without reopening.
    private func claimCanonicalKickoff(sessionID: String, storedID: String,
                                       botID: String, route: GatewayBotRoute) -> CanonicalKickoffLease {
        let chat = chat(for: botID)
        let baselineDurableRowIDs = Set(chat.messages.compactMap(\.rowID))
        let baselineDurableUserTexts: Set<String> = Set(chat.messages.compactMap { message -> String? in
            guard message.author == .user else { return nil }
            return message.text
        })
        let lease = CanonicalKickoffLease(id: UUID(), botID: botID, sessionID: sessionID,
                                          storedID: storedID, rowID: nil,
                                          chatID: ObjectIdentifier(chat), route: route,
                                          baselineDurableRowIDs: baselineDurableRowIDs,
                                          baselineDurableRowCount: baselineDurableRowIDs.count,
                                          baselineDurableUserTexts: baselineDurableUserTexts)
        CanonicalChatRuntime.shared.kickoffs[botID] = lease.id
        CanonicalChatRuntime.shared.kickoffLeases[botID] = lease
        return lease
    }

    @discardableResult
    private func beginCanonicalKickoff(_ lease: inout CanonicalKickoffLease) -> Bool {
        let chat = chat(for: lease.botID)
        let text = Self.canonicalKickoffPrompt
        // A first user prompt may have been echoed while canonical birth was
        // creating/resuming the session. In that case the visible transcript
        // already starts with the user's turn: submitting an invisible
        // kickoff first would reorder the gateway history relative to the UI.
        guard canonicalKickoffShouldSubmit(chat: chat) else { return false }
        let row = ChatMessage(author: .user, time: AppModel.clock(), text: text)
        chat.messages.append(row)
        lease.rowID = row.id
        if CanonicalChatRuntime.shared.kickoffLeases[lease.botID]?.id == lease.id {
            CanonicalChatRuntime.shared.kickoffLeases[lease.botID] = lease
        }
        chat.isRunning = true
        if CanonicalChatRuntime.shared.kickoffs[lease.botID] == lease.id {
            CanonicalChatRuntime.shared.ambiguousKickoffs[lease.botID] = nil
        }
        return true
    }

    /// Birth may only submit the desktop intro when no visible first prompt
    /// exists. Kept as a small policy seam so the first-send race can be tested
    /// without constructing a WebSocket client.
    func canonicalKickoffShouldSubmit(chat: ChatState) -> Bool {
        chat.messages.isEmpty
    }

    private func submitCanonicalKickoff(lease: CanonicalKickoffLease,
                                        client: GatewayClient) async throws {
        let result = try await client.submitPrompt(sessionID: lease.sessionID,
                                                   text: Self.canonicalKickoffPrompt)
        try PromptSubmitReceipt.requireAccepted(result, operation: "Canonical kickoff")
    }

    private func finishCanonicalKickoff(_ lease: CanonicalKickoffLease) {
        let runtime = CanonicalChatRuntime.shared
        if runtime.kickoffs[lease.botID] == lease.id { runtime.kickoffs[lease.botID] = nil }
        if runtime.ambiguousKickoffs[lease.botID]?.id == lease.id {
            runtime.ambiguousKickoffs[lease.botID] = nil
        }
        if runtime.kickoffLeases[lease.botID]?.id == lease.id {
            runtime.kickoffLeases[lease.botID] = nil
        }
    }

    /// Roll back only the birth state this exact operation still owns. This is
    /// intentionally identity-heavy: every await above permits a replacement
    /// attach, transcript, or session to become authoritative.
    @discardableResult
    func rollbackCanonicalKickoffIfOwned(_ lease: CanonicalKickoffLease) -> Bool {
        let runtime = CanonicalChatRuntime.shared
        guard runtime.kickoffs[lease.botID] == lease.id,
              let chat = chats[lease.botID], ObjectIdentifier(chat) == lease.chatID,
              lease.rowID == nil || chat.messages.contains(where: { $0.id == lease.rowID }) else { return false }
        let ownsBinding = chat.sessionID == lease.sessionID
            && (lease.storedID.isEmpty || chat.storedSessionID == lease.storedID)
        guard ownsBinding || chat.sessionID == nil else { return false }
        if let rowID = lease.rowID {
            chat.messages.removeAll { $0.id == rowID }
        }
        if ownsBinding {
            chat.isRunning = false
            chat.isTyping = false
        }
        if ownsBinding, let route = gatewayRoute(for: lease.botID) {
            if route.gatewayID == LiveRuntime.shared.gatewayID {
                LiveRuntime.shared.sessionToBot.removeValue(forKey: lease.sessionID)
            } else {
                LiveRuntime.shared.routedSessionToBot.removeValue(forKey: GatewaySessionRoute(
                    gatewayID: route.gatewayID, sessionID: lease.sessionID))
            }
        }
        // A definite kickoff failure removes only its optimistic row/running
        // state. The named hidden session remains bound and discoverable, so
        // the next tap reopens it instead of minting another chat.
        runtime.kickoffs[lease.botID] = nil
        runtime.kickoffLeases[lease.botID] = nil
        runtime.ambiguousKickoffs[lease.botID] = nil
        return true
    }

    func reconcileAmbiguousCanonicalKickoff(
        _ lease: CanonicalKickoffLease, route: GatewayBotRoute, client: GatewayClient
    ) async {
        guard lease.route.map({ $0 == route }) ?? true else { return }
        guard !ChatRuntime.shared.reconcilingBots.contains(lease.botID) else {
            ChatRuntime.shared.deferredReconciliationBots.insert(lease.botID)
            return
        }
        ChatRuntime.shared.reconcilingBots.insert(lease.botID)
        defer {
            ChatRuntime.shared.reconcilingBots.remove(lease.botID)
            drainPendingMutationWork(botID: lease.botID)
        }
        let target = lease.storedID.isEmpty ? lease.sessionID : lease.storedID
        let generation = LiveRuntime.shared.generation
        await reconcileAmbiguousCanonicalKickoff(
            lease, sourceGatewayID: route.gatewayID,
            resume: {
                try await client.resumeSession(target, profile: route.profile,
                                               deferHistory: false)
            },
            hydrate: { live in
                try await self.hydrateCanonical(
                    live, botID: lease.botID, profile: route.profile,
                    client: client, clearWhenEmpty: false)
            },
            accepts: {
                LiveRuntime.shared.generation >= generation
                    && self.gatewayRoute(for: lease.botID) == route
            })
    }

    /// Ownership-fenced reconciliation core. Factoring the two authoritative
    /// operations makes the tap ordering testable without a mock WebSocket;
    /// production supplies `session.resume` and transcript hydration above.
    func reconcileAmbiguousCanonicalKickoff(
        _ lease: CanonicalKickoffLease, sourceGatewayID: String,
        resume: @MainActor () async throws -> LiveSession,
        hydrate: @MainActor (LiveSession) async throws -> Void,
        accepts: @MainActor () -> Bool
    ) async {
        if let leaseRoute = lease.route, leaseRoute.gatewayID != sourceGatewayID {
            // The compatibility overload carries only a gateway id; it still
            // must reject a caller that tries to reconcile a lease from a
            // different source.
            return
        }
        let sourceRoute = lease.route ?? GatewayBotRoute(
            gatewayID: sourceGatewayID,
            profile: GatewayBotRoute(qualifiedID: lease.botID)?.profile ?? lease.botID)
        await reconcileAmbiguousCanonicalKickoff(
            lease, sourceRoute: sourceRoute, resume: resume,
            hydrate: hydrate, accepts: accepts)
    }

    /// Test/recovery seam with the complete immutable source identity. The
    /// older gateway-id-only overload remains for callers built before
    /// source-qualified routes existed, but production should use this shape.
    func reconcileAmbiguousCanonicalKickoff(
        _ lease: CanonicalKickoffLease, sourceRoute: GatewayBotRoute,
        resume: @MainActor () async throws -> LiveSession,
        hydrate: @MainActor (LiveSession) async throws -> Void,
        accepts: @MainActor () -> Bool
    ) async {
        guard lease.route.map({ $0 == sourceRoute }) ?? true else { return }
        guard CanonicalChatRuntime.shared.kickoffs[lease.botID] == lease.id else { return }
        do {
            let live = try await resume()
            let sameDurableSession = !lease.storedID.isEmpty
                && live.storedSessionID == lease.storedID
            guard CanonicalChatRuntime.shared.kickoffs[lease.botID] == lease.id,
                  accepts(),
                  lease.route.map({ $0 == sourceRoute }) ?? true,
                  (live.sessionID == lease.sessionID || sameDurableSession),
                  live.storedSessionID == lease.storedID,
                  let chat = chats[lease.botID], ObjectIdentifier(chat) == lease.chatID,
                  lease.storedID.isEmpty || chat.storedSessionID == lease.storedID else { return }
            adopt(live, storedID: live.storedSessionID.isEmpty ? lease.storedID : live.storedSessionID,
                  botID: lease.botID, sourceGatewayID: sourceRoute.gatewayID)
            replayInflight(live, botID: lease.botID)
            try await hydrate(live)
            guard CanonicalChatRuntime.shared.kickoffs[lease.botID] == lease.id,
                  accepts(), canonicalKickoffHasEvidence(lease, live: live) else { return }
            finishCanonicalKickoff(lease)
        } catch {
            // Keep the lease and visible state: acceptance is unresolved, so a
            // blind rollback or retry could duplicate the first turn.
        }
    }

    /// An ambiguous kickoff settles only when this exact birth is visible in
    /// durable storage (a new row id on a non-shrinking page) or the resume
    /// snapshot carries the exact in-flight user marker. Empty or stale
    /// hydration is not evidence.
    private func canonicalKickoffHasEvidence(
        _ lease: CanonicalKickoffLease, live: LiveSession
    ) -> Bool {
        let text = Self.canonicalKickoffPrompt
        let durableUserTexts: Set<String> = Set(chats[lease.botID]?.messages.compactMap { message -> String? in
            guard message.author == .user, message.rowID != nil else { return nil }
            return message.text
        } ?? [])
        if live.inflight?["user"]?.stringValue == text,
           !lease.baselineDurableUserTexts.union(durableUserTexts).contains(text) {
            return true
        }
        let remote = SteerMutationReconciliation.hasPostOperationDurableRow(
            AppModel.chatMessages(fromTranscript: .array(live.messages)), text: text,
            baselineDurableRowIDs: lease.baselineDurableRowIDs,
            baselineDurableRowCount: lease.baselineDurableRowCount)
        if remote { return true }
        guard let chat = chats[lease.botID], ObjectIdentifier(chat) == lease.chatID else {
            return false
        }
        return SteerMutationReconciliation.hasPostOperationDurableRow(
            chat.messages, text: text,
            baselineDurableRowIDs: lease.baselineDurableRowIDs,
            baselineDurableRowCount: lease.baselineDurableRowCount)
    }

    /// Resume `target` — a durable key or the canonical title — and bind the
    /// bot's chat to whatever it resolved to.
    private func attach(_ target: String, botID: String, route: GatewayBotRoute, hydrate: Bool,
                        client: GatewayClient,
                        lifecycleToken: ProfileLifecycleGenerationToken,
                        gatewayGeneration: Int,
                        durableID: String? = nil) async -> CanonicalAttach {
        let chat = chat(for: botID)
        let rebinding = !Self.sameOpenChatBinding(
            chat.storedSessionID, target: target, durableID: durableID)
        do {
            try Task.checkCancellation()
            // Bind with a deferred resume so first paint is not the full
            // forever-chat projection. The newest REST page is the open-chat
            // history window; a flaky REST read keeps the stub/cache instead
            // of failing the open. Mutation-proof paths still request a
            // full projection.
            let restTarget = attachRestTarget(target, durableID: durableID)
            let pageTask: Task<JSONValue?, Error>? = hydrate && restTarget != nil
                ? Task {
                    try await client.latestSessionMessages(
                        storedID: restTarget ?? target, profile: route.profile)
                }
                : nil
            defer { pageTask?.cancel() }
            let live = try await client.resumeSession(
                target, profile: route.profile,
                deferHistory: OpenChatHistoryPolicy.resumeDefersHistory)
            try Task.checkCancellation()
            guard profileLifecycleAcceptsGatewaySnapshot(
                route: route, client: client, generation: gatewayGeneration) else {
                throw CancellationError()
            }
            guard !live.sessionID.isEmpty else {
                return .failed(GatewayError(code: -8, message: "session.resume returned no id"))
            }
            // `target` may have been the TITLE; the ack carries the real key.
            let stored = durableID ?? (live.storedSessionID.isEmpty ? target : live.storedSessionID)
            adopt(live, storedID: stored, botID: botID,
                  sourceGatewayID: route.gatewayID)
            // Seed the resume snapshot before REST yields. Any message.delta
            // that lands during fallback then extends this exact live row and
            // hydration's merge preserves the newer value.
            replayInflight(live, botID: botID, replacingTranscript: rebinding)
            if hydrate {
                try await hydrateOpenChat(
                    live, botID: botID, profile: route.profile,
                    client: client, storedID: stored, clearWhenEmpty: rebinding,
                    prefetchedPage: {
                        guard let pageTask else { return nil }
                        return try await pageTask.value
                    })
                guard profileLifecycleAcceptsGatewaySnapshot(
                    route: route, client: client, generation: gatewayGeneration) else {
                    throw CancellationError()
                }
            }
            replayPendingPrompts(live, sourceGatewayID: route.gatewayID)
            return .attached(sessionID: live.sessionID, storedID: stored)
        } catch let error as GatewayError where error.code == GatewayError.storedSessionGone {
            forget(target, botID: botID)
            return .missing
        } catch {
            return .failed(error)
        }
    }

    // MARK: Binding

    /// Bind the chat to a resolved session. Message history is left alone —
    /// the hydration step owns it, so a message typed before the chat finished
    /// opening keeps its optimistic bubble.
    func adopt(_ live: LiveSession, storedID: String?, botID: String,
               sourceGatewayID: String) {
        let chat = chat(for: botID)
        let runtime = LiveRuntime.shared
        // Reconnect deliberately clears the visible runtime sid before the
        // socket is replaced. Use the explicit parked sid as the old binding
        // in that window; otherwise `oldSessionID == nil` skips migration and
        // leaves unresolved mutation/kickoff leases attached to a dead sid.
        let oldSessionID = chat.sessionID ?? runtime.reconnectParkedSessionIDs[botID]
        let oldStoredID = chat.storedSessionID
        let oldRoute = gatewayRoute(for: botID) ?? stateRoute(for: botID)
        if let old = oldSessionID, old != live.sessionID {
            if runtime.sessionToBot[old] == botID {
                runtime.sessionToBot.removeValue(forKey: old)
            }
            let routed = GatewaySessionRoute(gatewayID: sourceGatewayID, sessionID: old)
            if runtime.routedSessionToBot[routed] == botID {
                runtime.routedSessionToBot.removeValue(forKey: routed)
            }
        }
        if let fence = ChatRuntime.shared.transcriptFences[botID],
           let storedID, !storedID.isEmpty, storedID != fence.storedID {
            ChatRuntime.shared.transcriptFences[botID] = nil
        }
        let newStoredID = storedID.flatMap { $0.isEmpty ? nil : $0 }
        let durableID = newStoredID ?? chat.storedSessionID
        let bindingChanged = oldSessionID != nil && oldSessionID != live.sessionID
            || (newStoredID != nil && chat.storedSessionID != newStoredID)
        let bindingRoute = gatewayRoute(for: botID)
                ?? GatewayBotRoute(
                    gatewayID: sourceGatewayID,
                    profile: GatewayBotRoute(qualifiedID: botID)?.profile ?? botID)
        let replacedFailureScope = (newStoredID != nil && newStoredID != oldStoredID)
            || (oldRoute != nil && oldRoute != bindingRoute)
        if replacedFailureScope {
            let chatID = ObjectIdentifier(chat)
            ChatRuntime.shared.retainedFailureRows[chatID] = nil
            ChatRuntime.shared.dismissedFailures[chatID] = nil
            ChatRuntime.shared.failedRetryRows[botID] = nil
            chat.hasUnresolvedRetry = false
        }
        ChatRuntime.shared.migratePendingStop(
            botID: botID, route: bindingRoute, sessionID: live.sessionID,
            storedID: durableID, generation: runtime.generation,
            chatID: ObjectIdentifier(chat))
        if bindingChanged {
            let route = bindingRoute
            if let oldSessionID, let oldRoute {
                if let oldStoredID, oldStoredID == durableID, oldRoute == route {
                    _ = migrateQueuedState(
                        fromBotID: botID, toBotID: botID, route: route,
                        oldSessionID: oldSessionID, newSessionID: live.sessionID,
                        storedID: oldStoredID)
                } else {
                    // A changed durable key or source is a replacement chat;
                    // never let A's visible queue or pending ack drain into B.
                    _ = retireQueuedState(botID: botID, route: oldRoute,
                                          storedID: oldStoredID)
                }
            }
            ChatRuntime.shared.migrateMutationState(
                botID: botID, route: route, sessionID: live.sessionID,
                storedID: durableID, generation: runtime.generation,
                chatID: ObjectIdentifier(chat), oldSessionID: oldSessionID)
            chat.hasUnresolvedRetry = ChatRuntime.shared.failedRetryRows[botID] != nil
            if let fence = ChatRuntime.shared.stopFences[botID], fence.unaddressable,
               fence.storedID != durableID {
                // A reattach to a different durable conversation is an
                // authoritative replacement, not the chat that the local
                // stop fence was protecting.
                ChatRuntime.shared.stopFences[botID] = nil
            }
            if let kickoffStored = durableID ?? oldStoredID,
               CanonicalChatRuntime.shared.migrateKickoff(
                   botID: botID, route: route, sessionID: live.sessionID,
                   storedID: kickoffStored, chatID: ObjectIdentifier(chat)) == false {
                // The old birth belongs to another route/durable row (or a
                // replacement ChatState). Retire only that exact owner; do not
                // let a late kickoff receipt clean up this adopted session.
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
                    // A replacement durable binding cannot inherit an
                    // in-flight destructive action from the session being
                    // left. The late task still fails its ownership check.
                    ChatRuntime.shared.transcriptActions[botID] = nil
                    ChatRuntime.shared.transcriptActionGenerations[botID] = nil
                } else if ChatRuntime.shared.transcriptFences[botID] == nil {
                    // No fence carries the lease's session metadata while the
                    // destructive RPC is still awaiting its receipt; move its
                    // generation with this same durable binding.
                    ChatRuntime.shared.transcriptActionGenerations[botID] = runtime.generation
                }
            }
        }
        if let storedID, !storedID.isEmpty {
            chat.storedSessionID = storedID
            // What a reconnect resumes from.
            runtime.lastSessionByBot[botID] = storedID
        }
        chat.isTyping = false
        bindSession(live, botID: botID, sourceGatewayID: sourceGatewayID)
        // A stop tapped while no route/sid was available never crossed a wire
        // acceptance boundary. It still fenced the composer, because the
        // running state was unknown; this exact adopt is the authoritative
        // reattach that releases that local-only fence. Preserve truthful
        // running state, but do not carry a sentinel lock into the new sid.
        if let fence = ChatRuntime.shared.stopFences[botID], fence.unaddressable,
           ObjectIdentifier(chat) == fence.chatID,
           (ChatRuntime.sameDurable(fence.storedID, chat.storedSessionID)
                || (fence.storedID == nil && chat.storedSessionID == nil)) {
            ChatRuntime.shared.stopFences[botID] = nil
            chat.isRunning = live.running || live.hasInflightTurn
            chat.isTyping = chat.isRunning
        }
        runtime.reconnectParkedSessionIDs[botID] = nil
        // Reconnect/adoption is also a retry boundary for an unresolved
        // mutation or canonical birth. The scheduler performs authoritative
        // resume/hydration only; it never replays the original verb.
        scheduleRetainedMutationReconciliation(botID: botID)
    }

    /// Drop the current binding so the next attach re-resolves from scratch.
    /// Callers wait out any in-flight attach first — an attach that lands
    /// after this would re-bind the session being left.
    private func unbindChat(botID: String) {
        let chat = chat(for: botID)
        let runtime = LiveRuntime.shared
        retireComposeQueue(botID: botID, storedID: chat.storedSessionID,
                           chatID: ObjectIdentifier(chat))
        if let sid = chat.sessionID, let route = gatewayRoute(for: botID) {
            if route.gatewayID == runtime.gatewayID {
                runtime.sessionToBot.removeValue(forKey: sid)
            } else {
                runtime.routedSessionToBot.removeValue(forKey: GatewaySessionRoute(
                    gatewayID: route.gatewayID, sessionID: sid))
            }
        }
        // The user explicitly left this session. Any steer/interrupt fence
        // belongs to the old binding and must not poison the replacement chat;
        // late tasks still fail their exact chat/session ownership checks.
        ChatRuntime.shared.steerActions[botID] = nil
        ChatRuntime.shared.steerFences[botID] = nil
        ChatRuntime.shared.stopActions[botID] = nil
        ChatRuntime.shared.stopFences[botID] = nil
        ChatRuntime.shared.clearPendingStop(botID: botID)
        ChatRuntime.shared.deferredReconciliationBots.remove(botID)
        chat.sessionID = nil
        chat.storedSessionID = nil
        chat.isTyping = false
        chat.usage = nil
        chat.contextSegments = []
        chat.messages = []
        chat.resetTranscriptWindow()
    }

    /// A roster tap may discard a scratch binding only after two successful
    /// empty registry reads and authoritative title ownership. Keeping this as
    /// a stateful seam makes lookup-error preservation regression-testable:
    /// errors and indeterminate answers select `.preserve` and touch nothing.
    func applyCanonicalScratchRelease(
        botID: String, decision: CanonicalScratchReleaseDecision
    ) {
        guard decision == .authoritativeBirthReady else { return }
        unbindChat(botID: botID)
    }

    /// A durable key the gateway just declared gone (4007) must not be handed
    /// back by any of the fallbacks below it.
    private func forget(_ storedID: String, botID: String) {
        ChatRuntime.shared.clearPendingStopIfStored(storedID, botID: botID)
        if LiveRuntime.shared.lastSessionByBot[botID] == storedID {
            LiveRuntime.shared.lastSessionByBot[botID] = nil
        }
        if LiveRuntime.shared.canonicalSessionByBot[botID]?.id == storedID {
            LiveRuntime.shared.canonicalSessionByBot[botID] = nil
        }
        let chat = chat(for: botID)
        if chat.storedSessionID == storedID { chat.storedSessionID = nil }
    }

    /// Durable and resolved identities from the latest authoritative roster
    /// projection. This is a read-only summary, never an open pointer.
    func canonicalSessionIDs(botID: String) -> Set<String> {
        guard let summary = LiveRuntime.shared.canonicalSessionByBot[botID] else { return [] }
        return Set([summary.id, summary.resolvedID].compactMap {
            guard let value = $0, !value.isEmpty else { return nil }
            return value
        })
    }

    func isCurrentCanonicalSession(botID: String, sessionID: String?) -> Bool {
        guard let sessionID, !sessionID.isEmpty else { return false }
        return canonicalSessionIDs(botID: botID).contains(sessionID)
    }

    // MARK: Hydration

    /// Durable key we can address REST with before `session.resume` returns.
    /// A title-only target has to wait for the ack; using "Bot Chat" as a
    /// path segment would 404.
    static func attachRestTarget(_ target: String, durableID: String?) -> String? {
        if let durableID {
            let trimmed = durableID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == canonicalChatTitle { return nil }
        return trimmed
    }

    /// Root id, resume tip, and the bound stored key are the same conversation.
    static func sameOpenChatBinding(_ stored: String?, target: String,
                                    durableID: String?) -> Bool {
        guard let stored, !stored.isEmpty else { return false }
        if stored == target { return true }
        if let durableID, stored == durableID { return true }
        return false
    }

    /// Open-chat hydration: paint the deferred stub immediately, then merge
    /// the newest REST page. A REST failure must not fail the bind.
    private func hydrateOpenChat(_ live: LiveSession, botID: String, profile: String,
                                 client: GatewayClient, storedID: String,
                                 clearWhenEmpty: Bool,
                                 prefetchedPage: (@MainActor () async throws -> JSONValue?)? = nil
    ) async throws {
        let chat = chat(for: botID)
        let chatID = ObjectIdentifier(chat)
        let hydrationGeneration = LiveRuntime.shared.generation
        let sourceGatewayID = gatewayRoute(for: botID)?.gatewayID
        let durableTarget = storedID.trimmingCharacters(in: .whitespacesAndNewlines)
        var attempt = 0
        while true {
            do {
                try await Self.hydrateOpenChatTranscript(
                    chat: chat,
                    resumeMessages: live.messages,
                    historyDeferred: OpenChatHistoryPolicy.resumeDefersHistory,
                    clearWhenEmpty: clearWhenEmpty,
                    latestPage: {
                        if let prefetchedPage, attempt == 0 {
                            do {
                                if let page = try await prefetchedPage() { return page }
                            } catch {
                                if let timeout = CanonicalHydrationTimeout.wraps(
                                    error, storedID: durableTarget) {
                                    throw timeout
                                }
                            }
                        }
                        guard !durableTarget.isEmpty else { return nil }
                        do {
                            return try await client.latestSessionMessages(
                                storedID: durableTarget, profile: profile)
                        } catch {
                            if let timeout = CanonicalHydrationTimeout.wraps(
                                error, storedID: durableTarget) {
                                throw timeout
                            }
                            throw error
                        }
                    },
                    accepts: {
                        guard LiveRuntime.shared.generation == hydrationGeneration,
                              let owner = chats[botID], ObjectIdentifier(owner) == chatID,
                              owner.sessionID == live.sessionID,
                              owner.storedSessionID == storedID,
                              let route = gatewayRoute(for: botID) else { return false }
                        return route.gatewayID == sourceGatewayID && route.profile == profile
                    })
                break
            } catch let timeout as CanonicalHydrationTimeout {
                if attempt == 0 && timeout.storedID == durableTarget {
                    attempt += 1
                    continue
                }
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Bind already succeeded. Keep stub/cache rather than
                // reporting the chat as unopenable.
                break
            }
        }
        if let lease = CanonicalChatRuntime.shared.ambiguousKickoffs[botID],
           CanonicalChatRuntime.shared.kickoffs[botID] == lease.id,
           lease.sessionID == live.sessionID,
           lease.storedID.isEmpty || chat.storedSessionID == lease.storedID,
           canonicalKickoffHasEvidence(lease, live: live) {
            finishCanonicalKickoff(lease)
        }
        if let fence = ChatRuntime.shared.transcriptFences[botID],
           let sourceGatewayID,
           let storedID = chat.storedSessionID,
           fence.acceptsAuthoritativeHydration(
               gatewayID: sourceGatewayID, profile: profile, storedID: storedID,
               generation: hydrationGeneration,
               currentGeneration: LiveRuntime.shared.generation),
           (fence.chatID == nil || fence.chatID == ObjectIdentifier(chat)),
           let proof = fence.effectProof,
           proof.proves(chat.messages) || proof.proves(live) {
            ChatRuntime.shared.transcriptFences[botID] = nil
        }
        let hydratedRows = chat.messages
        for (_, fence) in ChatRuntime.shared.offlineComposeFences {
            guard fence.botID == botID, fence.route.gatewayID == sourceGatewayID,
                  fence.route.profile == profile,
                  fence.storedID == (chat.storedSessionID ?? ""),
                  fence.chatID == ObjectIdentifier(chat),
                  Self.provesOfflineComposeDelivery(fence, rows: hydratedRows) else { continue }
            retireProvenOfflineCompose(
                fence, running: live.running,
                retainedInflight: live.retainedInflight,
                authoritativeRows: hydratedRows)
        }
    }

    /// Replace the transcript with the stored conversation. The resume ack's
    /// projection is primary (it is the shape every surface reads,
    /// server.py:_history_to_messages); REST is the fallback for a resume that
    /// omitted messages.
    private func hydrateCanonical(_ live: LiveSession, botID: String, profile: String,
                                  client: GatewayClient,
                                  clearWhenEmpty: Bool) async throws {
        let chat = chat(for: botID)
        let chatID = ObjectIdentifier(chat)
        let hydrationGeneration = LiveRuntime.shared.generation
        let sourceGatewayID = gatewayRoute(for: botID)?.gatewayID
        let storedID = live.storedSessionID.isEmpty ? chat.storedSessionID : live.storedSessionID
        // A resume projection is the primary history source.  When it is
        // empty, the REST page is a read-only fallback for this exact durable
        // key.  Its one permitted retry is deliberately kept inside hydration:
        // it must never re-enter canonical resolution, where a timeout could
        // otherwise choose a different title/recency candidate or mint a chat.
        try await Self.hydrateCanonicalTranscript(
            chat: chat,
            resumeMessages: live.messages,
            clearWhenEmpty: clearWhenEmpty,
            storedID: storedID,
            fallback: { durableTarget in
                guard !durableTarget.isEmpty else { return nil }
                return try await client.latestSessionMessages(
                    storedID: durableTarget, profile: profile)
            },
            accepts: {
                guard LiveRuntime.shared.generation == hydrationGeneration,
                      let owner = chats[botID], ObjectIdentifier(owner) == chatID,
                      owner.sessionID == live.sessionID,
                      owner.storedSessionID == storedID,
                      let route = gatewayRoute(for: botID) else { return false }
                return route.gatewayID == sourceGatewayID && route.profile == profile
            })
        if let lease = CanonicalChatRuntime.shared.ambiguousKickoffs[botID],
           CanonicalChatRuntime.shared.kickoffs[botID] == lease.id,
           lease.sessionID == live.sessionID,
           lease.storedID.isEmpty || chat.storedSessionID == lease.storedID,
           canonicalKickoffHasEvidence(lease, live: live) {
            finishCanonicalKickoff(lease)
        }
        if let fence = ChatRuntime.shared.transcriptFences[botID],
           let sourceGatewayID,
           let storedID = chat.storedSessionID,
           fence.acceptsAuthoritativeHydration(
               gatewayID: sourceGatewayID, profile: profile, storedID: storedID,
               generation: hydrationGeneration,
               currentGeneration: LiveRuntime.shared.generation),
           (fence.chatID == nil || fence.chatID == ObjectIdentifier(chat)),
           let proof = fence.effectProof,
           proof.proves(chat.messages) || proof.proves(live) {
            ChatRuntime.shared.transcriptFences[botID] = nil
        }
        let hydratedRows = chat.messages
        for (_, fence) in ChatRuntime.shared.offlineComposeFences {
            guard fence.botID == botID, fence.route.gatewayID == sourceGatewayID,
                  fence.route.profile == profile,
                  fence.storedID == (chat.storedSessionID ?? ""),
                  fence.chatID == ObjectIdentifier(chat),
                  Self.provesOfflineComposeDelivery(fence, rows: hydratedRows) else { continue }
            retireProvenOfflineCompose(
                fence, running: live.running,
                retainedInflight: live.retainedInflight,
                authoritativeRows: hydratedRows)
        }
    }

    /// Shared by canonical and explicit stored-session opens, and deliberately
    /// testable with a suspended fallback. `baseline` is sampled immediately
    /// before the only suspension; the merge can therefore distinguish stale
    /// stored rows from user/assistant state that arrived afterward.
    static func hydrateTranscript(
        chat: ChatState,
        resumeMessages: [JSONValue],
        clearWhenEmpty: Bool,
        fallback: @MainActor () async throws -> JSONValue?,
        accepts: @MainActor () -> Bool
    ) async throws {
        let baseline = chat.messages
        var history = Self.chatMessages(fromTranscript: .array(resumeMessages))
        if history.isEmpty, let payload = try await fallback() {
            history = Self.chatMessages(fromTranscript: payload)
        }
        try Task.checkCancellation()
        guard accepts() else { throw CancellationError() }
        let chatID = ObjectIdentifier(chat)
        let protectedIDs = ChatRuntime.shared.retainedFailureRows[chatID] ?? []
        chat.messages = TranscriptHydrationMerge.merge(
            history: history, baseline: baseline, current: chat.messages,
            clearWhenEmpty: clearWhenEmpty, protectedIDs: protectedIDs)
        if !protectedIDs.isEmpty {
            let visible = Set(chat.messages.map(\.id))
            ChatRuntime.shared.retainedFailureRows[chatID] =
                protectedIDs.intersection(visible)
        }
    }

    /// Open-chat hydration. The deferred resume stub is painted before the
    /// REST page suspends, so first paint is not the full history. A larger
    /// resume projection (old gateway ignored `defer_history`) is kept.
    static func hydrateOpenChatTranscript(
        chat: ChatState,
        resumeMessages: [JSONValue],
        historyDeferred: Bool,
        clearWhenEmpty: Bool,
        firstPageLimit: Int = OpenChatHistoryPolicy.firstPageLimit,
        latestPage: @MainActor () async throws -> JSONValue?,
        accepts: @MainActor () -> Bool
    ) async throws {
        let stub = Self.chatMessages(fromTranscript: .array(resumeMessages))
        if !stub.isEmpty {
            try Task.checkCancellation()
            guard accepts() else { throw CancellationError() }
            applyHydratedHistory(
                stub, to: chat, baseline: chat.messages,
                clearWhenEmpty: false)
        }

        guard OpenChatHistoryPolicy.needsLatestPage(
            historyDeferred: historyDeferred, resumeMessageCount: stub.count)
        else {
            chat.resetTranscriptWindow()
            return
        }

        let baseline = chat.messages
        let payload = try await latestPage()
        try Task.checkCancellation()
        guard accepts() else { throw CancellationError() }
        guard let payload else {
            if stub.isEmpty {
                applyHydratedHistory(
                    [], to: chat, baseline: baseline,
                    clearWhenEmpty: clearWhenEmpty)
            }
            return
        }

        let page = Self.chatMessages(fromTranscript: payload)
        let source = OpenChatHistoryPolicy.authoritativeSource(
            resumeCount: stub.count, pageCount: page.count)
        if source == .resumeProjection {
            chat.resetTranscriptWindow()
            return
        }
        applyHydratedHistory(
            page, to: chat, baseline: baseline,
            clearWhenEmpty: clearWhenEmpty)
        chat.transcriptHasOlder = OpenChatHistoryPolicy.hasOlderMessages(
            pageCount: page.count, limit: firstPageLimit, source: source)
        chat.transcriptOlderOffset = page.count
        chat.isLoadingOlderTranscript = false
    }

    private static func applyHydratedHistory(_ history: [ChatMessage],
                                             to chat: ChatState,
                                             baseline: [ChatMessage],
                                             clearWhenEmpty: Bool) {
        let chatID = ObjectIdentifier(chat)
        let protectedIDs = ChatRuntime.shared.retainedFailureRows[chatID] ?? []
        chat.messages = TranscriptHydrationMerge.merge(
            history: history, baseline: baseline, current: chat.messages,
            clearWhenEmpty: clearWhenEmpty, protectedIDs: protectedIDs)
        if !protectedIDs.isEmpty {
            let visible = Set(chat.messages.map(\.id))
            ChatRuntime.shared.retainedFailureRows[chatID] =
                protectedIDs.intersection(visible)
        }
    }

    /// Canonical hydration's narrowly-scoped retry policy.  The fallback
    /// receives the durable key rather than a live session or title so a retry
    /// is structurally unable to select a newer arbitrary session.  One
    /// URLSession timeout gets one repeat read; every other failure remains the
    /// original failure.
    static func hydrateCanonicalTranscript(
        chat: ChatState,
        resumeMessages: [JSONValue],
        clearWhenEmpty: Bool,
        storedID: String?,
        fallback: @MainActor (String) async throws -> JSONValue?,
        accepts: @MainActor () -> Bool
    ) async throws {
        let durableTarget = storedID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var attempt = 0
        while true {
            do {
                try await hydrateTranscript(
                    chat: chat,
                    resumeMessages: resumeMessages,
                    clearWhenEmpty: clearWhenEmpty,
                    fallback: {
                        guard !durableTarget.isEmpty else { return nil }
                        do {
                            return try await fallback(durableTarget)
                        } catch {
                            if let timeout = CanonicalHydrationTimeout.wraps(
                                error, storedID: durableTarget) {
                                throw timeout
                            }
                            throw error
                        }
                    },
                    accepts: accepts)
                return
            } catch let timeout as CanonicalHydrationTimeout {
                if attempt == 0 && timeout.storedID == durableTarget {
                    // There is no backoff or route re-resolution here. The
                    // retry has exactly the same durable database target and
                    // can happen at most once for this hydration operation.
                    attempt += 1
                    continue
                }
                // A persistent timeout is still the transport's original
                // typed failure, not this internal retry sentinel.
                throw timeout.original
            }
        }
    }

    // MARK: Failure

    /// One themed line in the transcript, in the voice every session failure
    /// uses. Never a fork: a failed open is transient and the pin stays
    /// (plugin.js:2864-2871).
    ///
    /// Since Phase D it also says so out loud — `notifyError(error, "Could not
    /// open <name>'s chat — try again")` (plugin.js:2878). The transcript line
    /// alone was not enough: the tap has already switched tabs and put an empty
    /// chat on screen, so the one surface carrying the explanation is the one
    /// the user is least likely to be looking at, and "try again" is the whole
    /// instruction — the pin is innocent and a second tap usually works.
    ///
    /// Both halves are guarded by the same repeat check. A retry loop against a
    /// dead link would otherwise stack an identical card three times over.
    private func reportCanonicalFailure(_ error: Error, botID: String) {
        let text = Self.sessionFailure(error, theme: theme)
        let chat = chat(for: botID)
        guard chat.messages.last?.text != text else { return }
        chat.messages.append(ChatMessage(author: .system, text: text))
        toast(kind: .failure,
              title: theme.copy.toastOpenChatFailed(botName(botID, theme.themeID), theme.themeID),
              message: Self.reason(error), botID: botID)
    }
}

// MARK: - REST hydration

extension GatewayClient {

    /// The newest page of a stored transcript, in desktop's exact shape
    /// (hermes.ts:786-800 `getLatestSessionMessages`).
    ///
    /// Three query params the core wrapper omits, each load-bearing
    /// (hermes_cli/web_routers/sessions.py:601-640):
    /// - `profile` — the route opens THAT profile's state.db, so without it a
    ///   non-default bot's transcript 404s;
    /// - `order=latest` — the endpoint pages from the OLDEST message whenever a
    ///   `limit` is sent, which opens a long forever-chat at its beginning;
    /// - `include_compacted` — rows preserved by in-place compaction are
    ///   durable display history; without them the transcript silently ends at
    ///   the compaction boundary (hermes_state.py:10155-10161).
    func latestSessionMessages(storedID: String, profile: String?,
                               limit: Int = OpenChatHistoryPolicy.firstPageLimit,
                               offset: Int = 0) async throws -> JSONValue {
        try await restJSON(
            path: "api/sessions/\(storedID)/messages",
            query: OpenChatHistoryPolicy.latestMessagesQuery(
                profile: profile, limit: limit, offset: offset))
    }
}


extension AppModel {
    /// Reconcile every Bot Mode-owned stored session onto `hidden:true`
    /// (plugin.js:setHideBotChats). Canonical pins plus room member sessions
    /// stay out of shared recents; the per-bot Sessions sheet still lists them
    /// via `include_hidden`. Older gateways reject `session.set_hidden`; that
    /// is unsupported, not a toast.
    func hideOwnedBotSessions() async {
        guard mode == .live else { return }
        var grouped: [String: Set<String>] = [:]
        func add(_ gatewayID: String?, _ sessionID: String) {
            let sid = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let gatewayID, !gatewayID.isEmpty, !sid.isEmpty else { return }
            grouped[gatewayID, default: []].insert(sid)
        }
        let fallback = LiveRuntime.shared.gatewayID
        for (botID, summary) in LiveRuntime.shared.canonicalSessionByBot {
            add(gatewayRoute(for: botID)?.gatewayID ?? fallback, summary.id)
        }
        for room in rooms {
            for (memberID, sessionID) in room.memberSessions {
                add(gatewayRoute(for: memberID)?.gatewayID ?? fallback, sessionID)
            }
        }
        for (gatewayID, ids) in grouped {
            do {
                let client = try await routedClient(gatewayID: gatewayID)
                for sid in ids {
                    do { _ = try await client.setSessionHidden(sid, hidden: true) }
                    catch { OwnedSessionHidingFailure.record(error, gatewayID: gatewayID) }
                }
            } catch {
                OwnedSessionHidingFailure.record(error, gatewayID: gatewayID)
            }
        }
    }

    /// Prepend the next older REST page. Honest about remaining history:
    /// a short page ends the window.
    public func loadOlderTranscript(botID: String) async {
        let botID = resolvedBotID(botID)
        guard mode == .live else { return }
        let chat = chat(for: botID)
        guard chat.transcriptHasOlder, !chat.isLoadingOlderTranscript,
              let stored = chat.storedSessionID, !stored.isEmpty,
              let route = gatewayRoute(for: botID) else { return }
        chat.isLoadingOlderTranscript = true
        let offset = chat.transcriptOlderOffset
        let storedID = stored
        let chatID = ObjectIdentifier(chat)
        defer {
            if chats[botID].map({ ObjectIdentifier($0) == chatID }) == true {
                chat.isLoadingOlderTranscript = false
            }
        }
        do {
            let client = try await routedClient(for: route)
            let payload = try await client.latestSessionMessages(
                storedID: storedID, profile: route.profile, offset: offset)
            guard chats[botID].map({ ObjectIdentifier($0) == chatID }) == true,
                  chat.storedSessionID == storedID else { return }
            let older = Self.chatMessages(fromTranscript: payload)
            chat.messages = OpenChatHistoryPolicy.prepend(
                existing: chat.messages, older: older)
            if older.count < OpenChatHistoryPolicy.firstPageLimit {
                chat.transcriptHasOlder = false
            } else {
                chat.transcriptOlderOffset = offset + older.count
            }
        } catch {
            // Keep the visible window; the user can retry.
        }
    }

    /// Desktop's "New chat with this agent": a scratch session on this
    /// profile, explicitly NOT the forever-chat (plugin.js:3503). The
    /// `/new` guard's copy points here.
    public func openScratchChat(botID: String) async {
        let botID = resolvedBotID(botID)
        guard mode == .live else { return }
        do {
            guard let route = gatewayRoute(for: botID) else { throw GatewayRouteError.noRoute }
            let client = try await routedClient(for: route)
            let live = try await client.createSession(profile: route.profile, hidden: false)
            let stored = live.storedSessionID.isEmpty ? live.sessionID : live.storedSessionID
            guard !stored.isEmpty else {
                throw GatewayError(code: -8, message: "session.create returned no id")
            }
            openStoredSession(stored, botID: botID)
        } catch {
            toast(kind: .failure,
                  title: theme.copy.toastScratchFailed(theme.themeID),
                  message: (error as? GatewayError)?.message ?? error.localizedDescription,
                  botID: botID)
        }
    }

}
