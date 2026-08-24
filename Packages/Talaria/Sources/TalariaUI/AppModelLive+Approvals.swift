import Foundation
import TalariaKit

// Live approvals and the blocking request/respond bridges (ws-protocol.md §8).
//
// Three things happen here that AppModelLive's core pump does not do:
//
// 1. Full choice set. `approval.request` carries a server-derived `choices`
//    array (once / session / always / deny); the card drives its buttons from
//    that instead of collapsing everything to approve/deny.
// 2. Reconnect replay. `session.resume` replays only the *oldest* pending
//    approval, and an `approval.request` raised while the socket was down is
//    never re-emitted — so every live session is swept with `approval.pending`
//    after a (re)connect and the results merged. Each merged card is
//    acknowledged with `approval.received`.
// 3. clarify / sudo / secret. These park a real tool thread for 120–300 s with
//    no UI at all today. They are answered through BlockingPromptOverlay.
//
// The bridges ride their own event handler on the client rather than
// AppModelLive's switch, because that file has another owner. Both handlers see
// the same stream; dedupe is by request_id on both sides.

// MARK: - Bridge state (side table)

/// One parked request/respond bridge. The agent thread is blocked on this
/// until the client answers or the bounded wait expires (`<kind>.expire`).
public struct BlockingPrompt: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// `clarify.request` — a question, optionally with choices. Timeout
        /// `agent.clarify_timeout` (300 s default; ≤0 waits forever).
        case clarify
        /// `sudo.request` — the terminal tool needs a sudo password. 120 s.
        case sudo
        /// `secret.request` — a skill needs a credential to store in env. 300 s.
        case secret
    }

    public var id: String {
        GatewayApprovalRoute(gatewayID: gatewayID, requestID: requestID).qualifiedID
    }
    public var kind: Kind
    /// Saved connection that owns this request. Prompt response RPCs do not
    /// carry a session id, so choosing the correct client is the trust boundary.
    public var gatewayID: String
    public var requestID: String
    /// Runtime sid the request arrived on.
    public var sessionID: String
    /// Bot whose turn is parked, when the sid is bound to one.
    public var botID: String?
    /// Exact profile and durable conversation captured while the request was
    /// bound. Runtime SIDs can collide across profiles and can later be reused.
    public var profile: String?
    public var storedID: String?
    /// clarify: the question. secret: the human-readable prompt. sudo: empty
    /// (the gateway sends no payload beyond request_id).
    public var question: String
    public var choices: [String]
    public var multiSelect: Bool
    /// secret: the env var the captured value is stored as.
    public var envVar: String?

    public init(kind: Kind, gatewayID: String, requestID: String,
                sessionID: String, botID: String?,
                question: String, choices: [String] = [], multiSelect: Bool = false,
                envVar: String? = nil, profile: String? = nil,
                storedID: String? = nil) {
        self.kind = kind; self.gatewayID = gatewayID
        self.requestID = requestID; self.sessionID = sessionID
        self.botID = botID; self.profile = profile; self.storedID = storedID
        self.question = question; self.choices = choices
        self.multiSelect = multiSelect; self.envVar = envVar
    }

    /// Secure entry — the answer is a credential and must never be echoed,
    /// logged, or written into the transcript.
    public var isSecret: Bool { kind == .sudo || kind == .secret }
}

/// Protocol-side book-keeping for the approval layer. `AppModel`'s stored
/// properties live in AppModel.swift (another owner) and extensions cannot add
/// storage, so — following LiveRuntime's precedent — this rides in a MainActor
/// singleton. Every request-bearing entry retains its gateway identity.
@MainActor
@Observable
public final class ApprovalBridges {
    public static let shared = ApprovalBridges()

    /// request_id → the gateway's choice set + smart-denied flag. The shared
    /// `Approval` model carries only what the card renders; this is the
    /// protocol half of the same request.
    public internal(set) var details: [String: ApprovalDetail] = [:]

    /// Parked prompts, oldest first. Only the first is presented; the rest
    /// queue behind it (the gateway can park several tools at once).
    public internal(set) var prompts: [BlockingPrompt] = []

    /// request_id → the choice the user actually picked, so a decided card can
    /// say "always" rather than just "approved". Survives the approval leaving
    /// `model.approvals`, like the ApprovalOutcomes ledger it complements.
    public internal(set) var decided: [String: ApprovalChoice] = [:]

    /// The client the bridge pump is bound to (weak: identity only).
    weak var attachedClient: GatewayClient?
    var attachedGatewayID: String?
    var handlerID: UUID?
    var pump: Task<Void, Never>?
    var sweepTask: Task<Void, Never>?
    /// Sessions whose approval.pending backlog has been merged since the last
    /// (re)connect, and how many times a sweep failed for one.
    var sweptSessions: Set<GatewaySessionRoute> = []
    var sweepFailures: [GatewaySessionRoute: Int] = [:]
    /// Per-gateway generation fencing an approval.pending RPC that completes
    /// after its client was detached or replaced.
    var sweepEpochs: [String: Int] = [:]
    /// `LiveRuntime.generation` the sweep bookkeeping belongs to. The runtime
    /// bumps it on every connect and reconnect, which makes it the connection
    /// epoch — see `syncApprovalEpoch()`.
    var sweptGeneration: Int?

    public init() {}

    /// A new socket means a new backlog: every session must be swept again.
    func resetSweepScope(gatewayID: String) {
        sweepEpochs[gatewayID, default: 0] &+= 1
        sweptSessions = sweptSessions.filter { $0.gatewayID != gatewayID }
        sweepFailures = sweepFailures.filter { $0.key.gatewayID != gatewayID }
    }

    func resetScope(gatewayID: String) {
        let prefix = GatewayApprovalRoute.qualifiedPrefix(gatewayID: gatewayID)
        details = details.filter { !$0.key.hasPrefix(prefix) }
        prompts.removeAll { $0.gatewayID == gatewayID }
        resetSweepScope(gatewayID: gatewayID)
    }

    func resetForNewPrimaryConnection(gatewayID: String?) {
        if let gatewayID { resetSweepScope(gatewayID: gatewayID) }
        sweepTask?.cancel()
        sweepTask = nil
    }
}

// MARK: - Outcome ledger (choice-aware)

extension ApprovalOutcomes {
    /// Choice-aware sibling of `resolve(_:approve:in:)`. Every approval control
    /// that offers more than approve/deny goes through here so the Approvals
    /// tab, the inline chat card and the push banner agree on the outcome.
    public func resolve(_ approval: Approval, choice: ApprovalChoice, in model: AppModel) {
        ApprovalBridges.shared.decided[approval.id] = choice
        record(approval, approved: choice != .deny)
        model.resolveApproval(approval, choice: choice)
    }

    /// The choice a decided approval was answered with, when it is known.
    /// Binary paths (notification action, push banner) record only approve/deny
    /// and resolve to `.once` / `.deny`, which is exactly what they sent.
    public func choice(for approvalID: String) -> ApprovalChoice? {
        if let choice = ApprovalBridges.shared.decided[approvalID] { return choice }
        guard let approved = outcomes[approvalID] else { return nil }
        return approved ? .once : .deny
    }

}

// MARK: - AppModel

extension AppModel {

    /// Remove every pending surface owned by one gateway before its client or
    /// routing tables disappear. Calling this after teardown loses the only
    /// evidence that tells colliding request ids apart.
    func dropApprovalScope(gatewayID: String) {
        let runtime = LiveRuntime.shared
        let stale = Set(runtime.approvalTargets.compactMap { key, target in
            target.bot.gatewayID == gatewayID ? key : nil
        })
        let owners = Set(approvals.filter { stale.contains($0.id) }.map(\.botID))
        approvals.removeAll { stale.contains($0.id) }
        runtime.approvalTargets = runtime.approvalTargets.filter {
            $0.value.bot.gatewayID != gatewayID
        }
        ApprovalBridges.shared.resetScope(gatewayID: gatewayID)
        for owner in owners { recomputeApprovalStatus(for: owner) }
    }

    // MARK: Bridge registration

    /// Register the approval / clarify / sudo / secret bridges on the live
    /// client and (re)arm the reconnect replay.
    ///
    /// Idempotent and cheap — an identity check plus an integer compare — so
    /// call it liberally: after every connect, on foreground, and whenever the
    /// link state changes. A reconnect that reuses the same `GatewayClient`
    /// keeps its handler (the client's table survives `connect()`); one that
    /// dials a fresh client re-registers here.
    public func attachApprovalBridges() {
        guard mode == .live, let client, let gatewayID = LiveRuntime.shared.gatewayID else { return }
        let bridges = ApprovalBridges.shared
        guard bridges.attachedClient !== client || bridges.attachedGatewayID != gatewayID else {
            syncApprovalEpoch()
            return
        }

        if let previous = bridges.attachedClient, let handlerID = bridges.handlerID {
            Task { await previous.removeEventHandler(handlerID) }
        }
        bridges.pump?.cancel()
        bridges.resetScope(gatewayID: gatewayID)
        bridges.resetForNewPrimaryConnection(gatewayID: gatewayID)
        bridges.attachedClient = client
        bridges.attachedGatewayID = gatewayID
        bridges.handlerID = nil

        // Same funnel AppModelLive uses for its main pump: events leave the
        // client actor through one AsyncStream so MainActor delivery preserves
        // wire order — an `.expire` must never land before its `.request`.
        let (stream, continuation) = AsyncStream.makeStream(
            of: GatewayEpochEventDelivery.self)
        bridges.pump = Task { @MainActor [weak self] in
            for await delivery in stream {
                guard bridges.attachedClient === client,
                      bridges.attachedGatewayID == gatewayID,
                      await client.isCurrentReadyTransport(
                        epoch: delivery.transportEpoch) else { continue }
                self?.handleBridgeEvent(delivery.event, sourceGatewayID: gatewayID)
            }
        }
        Task { @MainActor in
            let handlerID = await client.addEpochEventHandler { event, transportEpoch in
                continuation.yield(GatewayEpochEventDelivery(
                    event: event, transportEpoch: transportEpoch))
            }
            if bridges.attachedClient === client, bridges.attachedGatewayID == gatewayID {
                bridges.handlerID = handlerID
            } else {
                await client.removeEventHandler(handlerID)
            }
        }
        syncApprovalEpoch()
    }

    /// Tear the bridges down — deliberate disconnect, sign-out, or dropping
    /// back to demo mode. Parked prompts cannot be answered without a socket,
    /// so they are cleared rather than left dangling over an empty world.
    public func detachApprovalBridges() {
        let bridges = ApprovalBridges.shared
        let gatewayID = bridges.attachedGatewayID
        if let client = bridges.attachedClient, let handlerID = bridges.handlerID {
            Task { await client.removeEventHandler(handlerID) }
        }
        bridges.pump?.cancel(); bridges.pump = nil
        bridges.sweepTask?.cancel(); bridges.sweepTask = nil
        bridges.attachedClient = nil
        bridges.attachedGatewayID = nil
        bridges.handlerID = nil
        if let gatewayID { bridges.resetScope(gatewayID: gatewayID) }
        bridges.sweptGeneration = nil
    }

    // MARK: Event routing

    func handleBridgeEvent(_ event: GatewayEvent, sourceGatewayID: String? = nil) {
        // Cheap enough to do per event, and this is the earliest reliable place
        // to notice a reconnect: `gateway.ready` cannot be used because the
        // transport consumes that frame itself while waiting for the socket to
        // come up (GatewayTransport.connect), so it never reaches a handler.
        if sourceGatewayID == LiveRuntime.shared.gatewayID { syncApprovalEpoch() }

        guard let gatewayID = sourceGatewayID ?? LiveRuntime.shared.gatewayID else { return }

        switch event.type {
        case "approval.request":
            ingestApproval(ApprovalDetail(event.payload, sessionID: event.sessionID),
                           sourceGatewayID: gatewayID)

        case "clarify.request":
            let request = ClarifyRequest(event.payload, sessionID: event.sessionID)
            present(BlockingPrompt(kind: .clarify, gatewayID: gatewayID,
                                   requestID: request.requestID,
                                   sessionID: event.sessionID,
                                   botID: botID(forSession: event.sessionID,
                                                sourceGatewayID: gatewayID),
                                   question: request.question,
                                   choices: request.choices,
                                   multiSelect: request.multiSelect))

        case "sudo.request":
            present(BlockingPrompt(kind: .sudo,
                                   gatewayID: gatewayID,
                                   requestID: event.payload?["request_id"]?.stringValue ?? "",
                                   sessionID: event.sessionID,
                                   botID: botID(forSession: event.sessionID,
                                                sourceGatewayID: gatewayID),
                                   question: ""))

        case "secret.request":
            present(BlockingPrompt(kind: .secret,
                                   gatewayID: gatewayID,
                                   requestID: event.payload?["request_id"]?.stringValue ?? "",
                                   sessionID: event.sessionID,
                                   botID: botID(forSession: event.sessionID,
                                                sourceGatewayID: gatewayID),
                                   question: event.payload?["prompt"]?.stringValue ?? "",
                                   envVar: event.payload?["env_var"]?.stringValue))

        case "clarify.expire", "sudo.expire", "secret.expire":
            // The tool gave up and returned empty; a late respond would be
            // answered {"status":"expired"} and change nothing.
            if let requestID = event.payload?["request_id"]?.stringValue {
                dismissBlockingPrompt(requestID, sourceGatewayID: gatewayID)
            }

        case "session.reclaimed":
            // The runtime session is gone; anything parked on it died with it.
            let sid = event.payload?["session_id"]?.stringValue ?? ""
            guard !sid.isEmpty else { return }
            for prompt in ApprovalBridges.shared.prompts
                where prompt.gatewayID == gatewayID && prompt.sessionID == sid {
                dismissBlockingPrompt(prompt.requestID, sourceGatewayID: gatewayID)
            }

        default:
            break
        }

        // Backstop for the reconnect replay: the first event a resumed session
        // emits (usually session.info) is the signal that its runtime sid is
        // bound again — which is exactly when approval.pending can be asked.
        if !event.sessionID.isEmpty {
            sweepApprovalsIfNeeded(sessionID: event.sessionID, sourceGatewayID: gatewayID)
        }
    }

    /// Notice a new connection epoch and re-arm the replay. `LiveRuntime`
    /// bumps `generation` on every connect and reconnect, which makes it a
    /// reliable epoch counter that needs no event of its own.
    private func syncApprovalEpoch() {
        let bridges = ApprovalBridges.shared
        let generation = LiveRuntime.shared.generation
        guard bridges.sweptGeneration != generation else { return }
        bridges.sweptGeneration = generation
        bridges.resetForNewPrimaryConnection(gatewayID: LiveRuntime.shared.gatewayID)

        // The socket is up but the chats have not been re-resumed yet, and
        // approval.pending needs a bound runtime sid. Sweep twice: once after a
        // normal resume round trip, once late for a slow gateway. The
        // per-session guard makes the second pass free when the first worked.
        bridges.sweepTask = Task { @MainActor [weak self] in
            for delay in [1.5, 5.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self?.replayPendingApprovals()
            }
        }
    }

    // MARK: Reconnect replay

    /// Merge every live session's unresolved approval backlog. Approvals raised
    /// while the app was away are otherwise invisible: their `approval.request`
    /// fired into a dead socket and `session.resume` replays only the oldest.
    ///
    /// Safe to call any time — on foreground, from a pull-to-refresh, or after
    /// a manual reconnect. Sessions already swept on this connection are
    /// skipped unless `force` is set, and a gateway without `approval.pending`
    /// degrades to the event-driven path instead of erroring.
    public func replayPendingApprovals(force: Bool = false) async {
        guard mode == .live else { return }
        syncApprovalEpoch()
        if force {
            let bridges = ApprovalBridges.shared
            bridges.sweptSessions.removeAll()
            bridges.sweepFailures.removeAll()
        }
        let runtime = LiveRuntime.shared
        if let client, let gatewayID = runtime.gatewayID {
            for sessionID in Array(runtime.sessionToBot.keys) {
                await sweepApprovals(
                    GatewaySessionRoute(gatewayID: gatewayID, sessionID: sessionID),
                    client: client)
            }
        }
        for session in Array(runtime.routedSessionToBot.keys) {
            guard let client = MultiGatewayRuntime.shared.routedEvents[session.gatewayID]?.client
            else { continue }
            await sweepApprovals(session, client: client)
        }
    }

    private func sweepApprovalsIfNeeded(sessionID: String, sourceGatewayID: String) {
        let bridges = ApprovalBridges.shared
        let runtime = LiveRuntime.shared
        let route = GatewaySessionRoute(gatewayID: sourceGatewayID, sessionID: sessionID)
        let ownerExists = sourceGatewayID == runtime.gatewayID
            ? runtime.sessionToBot[sessionID] != nil
            : runtime.routedSessionToBot[route] != nil
        let owningClient = sourceGatewayID == runtime.gatewayID
            ? client
            : MultiGatewayRuntime.shared.routedEvents[sourceGatewayID]?.client
        guard mode == .live, ownerExists, let owningClient,
              // Claim the session synchronously: a streaming turn fires dozens
              // of events per second and every one of them reaches here.
              bridges.sweptSessions.insert(route).inserted else { return }
        let epoch = bridges.sweepEpochs[sourceGatewayID, default: 0]
        Task { @MainActor in
            await self.performSweep(route, client: owningClient, epoch: epoch)
        }
    }

    private func sweepApprovals(_ session: GatewaySessionRoute,
                                client: GatewayClient) async {
        guard ApprovalBridges.shared.sweptSessions.insert(session).inserted else { return }
        let epoch = ApprovalBridges.shared.sweepEpochs[session.gatewayID, default: 0]
        await performSweep(session, client: client, epoch: epoch)
    }

    private func performSweep(_ session: GatewaySessionRoute, client: GatewayClient,
                              epoch: Int) async {
        let bridges = ApprovalBridges.shared
        do {
            let details = try await client.pendingApprovalDetails(sessionID: session.sessionID)
            guard bridges.sweepEpochs[session.gatewayID, default: 0] == epoch else { return }
            for detail in details {
                ingestApproval(detail, sourceGatewayID: session.gatewayID)
            }
            bridges.sweepFailures.removeValue(forKey: session)
        } catch {
            guard bridges.sweepEpochs[session.gatewayID, default: 0] == epoch else { return }
            // A gateway that predates approval.pending, or a session that went
            // away mid-flight. Retry on the next event for this session, but
            // only twice — an unsupported method must not become an RPC storm.
            let failures = (bridges.sweepFailures[session] ?? 0) + 1
            bridges.sweepFailures[session] = failures
            if failures < 3 { bridges.sweptSessions.remove(session) }
        }
    }

    // MARK: Resume replay (session.resume `pending_*` blocks)

    /// Merge the approval `session.resume` replays in its `pending_approval`
    /// block. The reconnect sweep finds the same request a moment later, so
    /// this only makes the card appear a round trip sooner — with its real
    /// choice set instead of the once/deny fallback.
    public func ingestPendingApproval(_ request: ApprovalRequest,
                                      sourceGatewayID: String? = nil) {
        ingestApproval(ApprovalDetail(request: request, replayed: true),
                       sourceGatewayID: sourceGatewayID)
    }

    /// Present the clarify `session.resume` replays in its `pending_clarify`
    /// block. Unlike approvals there is no `clarify.pending` RPC — the resume
    /// payload is the only channel — so a question raised while the socket was
    /// down is recoverable *only* through this call.
    ///
    /// `payload` is the raw `pending_clarify` object
    /// (`{question, choices, multi_select?, request_id}`).
    public func ingestPendingClarify(_ payload: JSONValue, sessionID: String,
                                     sourceGatewayID: String? = nil) {
        guard let gatewayID = sourceGatewayID ?? LiveRuntime.shared.gatewayID else { return }
        let request = ClarifyRequest(payload, sessionID: sessionID)
        present(BlockingPrompt(kind: .clarify, gatewayID: gatewayID,
                               requestID: request.requestID,
                               sessionID: sessionID,
                               botID: botID(forSession: sessionID,
                                            sourceGatewayID: gatewayID),
                               question: request.question,
                               choices: request.choices,
                               multiSelect: request.multiSelect))
    }

    // MARK: Ingest

    /// Merge one approval into the shared surfaces: the Approvals tab, the
    /// bot's status dot, and an inline card in that bot's transcript.
    ///
    /// Field mapping mirrors AppModelLive's own ingest exactly, so a card
    /// recovered by the reconnect sweep is indistinguishable from one that
    /// arrived live — both paths dedupe on request_id, so they can and do run
    /// over the same request.
    func ingestApproval(_ detail: ApprovalDetail, sourceGatewayID: String? = nil) {
        let request = detail.request
        guard let gatewayID = sourceGatewayID ?? LiveRuntime.shared.gatewayID,
              let approvalID = ingest(request, sourceGatewayID: gatewayID) else { return }
        let bridges = ApprovalBridges.shared
        bridges.details[approvalID] = detail
        guard let approval = approvals.first(where: { $0.id == approvalID }) else { return }
        if detail.replayed, let index = approvals.firstIndex(where: { $0.id == approvalID }) {
            approvals[index].age = ""
        }
        appendApprovalCard(approvalID: approvalID, botID: approval.botID)
        acknowledgeApproval(detail, sourceGatewayID: gatewayID)
    }

    /// Desktop renders an approval as a tool card inside the thread, not only
    /// in a side list. The `.approvalRef` row is what InlineApprovalCard binds
    /// to; both surfaces then read the same `model.approvals` entry.
    private func appendApprovalCard(approvalID: String, botID: String) {
        let chat = chat(for: botID)
        let ref = MessageCard.approvalRef(approvalID)
        guard !chat.messages.contains(where: { $0.card == ref }) else { return }
        chat.messages.append(ChatMessage(author: .bot, time: AppModel.clock(),
                                         text: "", card: ref))
    }

    /// `approval.received` — tells the gateway a client has the card on screen
    /// so it can stop re-notifying. Fire-and-forget: an older gateway without
    /// the method just errors and the approval still answers normally.
    private func acknowledgeApproval(_ detail: ApprovalDetail, sourceGatewayID: String) {
        guard mode == .live, !detail.request.sessionID.isEmpty else { return }
        let sessionID = detail.request.sessionID
        let requestID = detail.request.requestID
        Task { @MainActor in
            guard let client = try? await routedClient(gatewayID: sourceGatewayID) else { return }
            _ = try? await client.acknowledgeApproval(sessionID: sessionID,
                                                      requestID: requestID)
        }
    }

    // MARK: Answering an approval

    /// The gateway's choice set for a pending approval. Falls back to
    /// once/deny — the reduced pair the server itself uses when it can offer no
    /// more — so demo cards and approvals ingested before the bridges attached
    /// still render something answerable.
    public func approvalChoices(for approvalID: String) -> [ApprovalChoice] {
        ApprovalBridges.shared.details[approvalID]?.choices ?? [.once, .deny]
    }

    /// Protocol detail behind a pending approval (smart-denied flag, pattern
    /// key, whether it was replayed). nil for demo cards.
    public func approvalDetail(_ approvalID: String) -> ApprovalDetail? {
        ApprovalBridges.shared.details[approvalID]
    }

    /// Answer an approval in the gateway's own vocabulary.
    /// `resolveApproval(_:approve:)` stays the binary shim the notification
    /// action and push banner use; this is the full once / session / always /
    /// deny set the cards drive.
    public func resolveApproval(_ approval: Approval, choice: ApprovalChoice) {
        approvals.removeAll { $0.id == approval.id }
        // The protocol detail is kept until the gateway confirms: a failed
        // respond puts the card back, and it must come back with the same
        // choice set rather than degraded to once/deny.
        ApprovalBridges.shared.decided[approval.id] = choice
        switch mode {
        case .live:
            liveAnswerApproval(approval, choice: choice)
        case .demo:
            // Same prefixes AppModel.resolveApproval writes, so the chat card's
            // outcome fallback keeps reading them. Demo bot statuses are canned
            // scenery and are deliberately left alone.
            chat(for: approval.botID).messages.append(ChatMessage(
                author: .system,
                text: (choice == .deny ? "Denied · " : "Approved · ") + approval.title))
        }
    }

    private func liveAnswerApproval(_ approval: Approval, choice: ApprovalChoice) {
        let runtime = LiveRuntime.shared
        recomputeApprovalStatus(for: approval.botID)
        guard let target = approvalResponseTarget(
            for: approval, botRoute: gatewayRoute(for: approval.botID)) else {
            restoreFailedApproval(approval)
            return
        }
        Task { @MainActor in
            do {
                let client = try await self.routedClient(for: target.bot)
                let resolved = try await client.answerApproval(
                    sessionID: target.session.sessionID, choice: choice,
                    requestID: target.requestID)
                runtime.approvalTargets.removeValue(forKey: approval.id)
                ApprovalBridges.shared.details.removeValue(forKey: approval.id)
                if resolved == 0 {
                    // Nothing was parked: the 300 s timeout already denied it,
                    // session.interrupt cleared it, or another client answered.
                    self.noteApproval(self.theme.copy.approvalGone(self.theme.themeID),
                                      for: approval.botID)
                }
            } catch {
                // The gateway never heard us, so the agent is still blocked —
                // put the card back rather than leave a parked run with no
                // affordance anywhere in the app.
                self.noteApproval(self.theme.copy.approvalSendFailed(self.theme.themeID),
                                  for: approval.botID)
                self.restoreFailedApproval(approval)
            }
        }
    }

    func restoreFailedApproval(_ approval: Approval) {
        ApprovalOutcomes.shared.reopen(approval.id)
        if !approvals.contains(where: { $0.id == approval.id }) {
            approvals.append(approval)
        }
        recomputeApprovalStatus(for: approval.botID)
    }

    private func noteApproval(_ text: String, for botID: String) {
        chat(for: botID).messages.append(ChatMessage(author: .system, text: text))
    }

    /// AppModelLive's `recomputeStatus` is private to that file; this mirrors it
    /// and additionally treats a parked clarify/sudo/secret prompt as blocked,
    /// which is exactly what the bot is while one is on screen.
    func recomputeApprovalStatus(for botID: String) {
        guard let idx = bots.firstIndex(where: { $0.id == botID }) else { return }
        if approvals.contains(where: { $0.botID == botID })
            || ApprovalBridges.shared.prompts.contains(where: { $0.botID == botID }) {
            bots[idx].status = .approval
        } else if LiveRuntime.shared.workingBotIDs.contains(botID) {
            bots[idx].status = .working
        } else {
            bots[idx].status = .idle
        }
    }

    // MARK: Blocking prompts

    private func present(_ incoming: BlockingPrompt) {
        var prompt = incoming
        if let botID = prompt.botID,
           let route = stateRoute(for: botID), route.gatewayID == prompt.gatewayID,
           let chat = chats[botID], chat.sessionID == prompt.sessionID {
            prompt.profile = route.profile
            prompt.storedID = chat.storedSessionID
        }
        let bridges = ApprovalBridges.shared
        guard !prompt.requestID.isEmpty,
              !bridges.prompts.contains(where: { $0.id == prompt.id }) else { return }
        bridges.prompts.append(prompt)
        if let botID = prompt.botID { recomputeApprovalStatus(for: botID) }
    }

    /// Drop a prompt without answering — `<kind>.expire` and session teardown
    /// both land here. The tool has already moved on.
    public func dismissBlockingPrompt(_ requestID: String,
                                      sourceGatewayID: String? = nil) {
        let bridges = ApprovalBridges.shared
        let matches = bridges.prompts.indices.filter { index in
            bridges.prompts[index].requestID == requestID
                && (sourceGatewayID == nil || bridges.prompts[index].gatewayID == sourceGatewayID)
        }
        // A bare request id is not enough to choose between gateways.
        guard matches.count == 1, let index = matches.first else { return }
        let botID = bridges.prompts.remove(at: index).botID
        if let botID { recomputeApprovalStatus(for: botID) }
    }

    /// Answer a clarify (free text or single choice), sudo, or secret prompt.
    ///
    /// An empty answer is the protocol's refusal and is a first-class outcome,
    /// not an error: sudo reports that no password is available, secret stores
    /// nothing and returns `skipped:true`, clarify hands the agent an empty
    /// string. Secrets are never echoed anywhere.
    public func answerBlockingPrompt(_ prompt: BlockingPrompt, answer: String) {
        sendPromptAnswer(prompt, answer: answer, selections: nil)
    }

    /// Answer a multi-select clarify. Selections are encoded as a JSON array,
    /// which is what the clarify tool decodes first.
    public func answerBlockingPrompt(_ prompt: BlockingPrompt, selections: [String]) {
        sendPromptAnswer(prompt, answer: "", selections: selections)
    }

    private func sendPromptAnswer(_ prompt: BlockingPrompt, answer: String,
                                  selections: [String]?) {
        dismissBlockingPrompt(prompt.requestID, sourceGatewayID: prompt.gatewayID)
        guard mode == .live else { return }
        let botID = prompt.botID
        Task { @MainActor in
            do {
                let client = try await self.routedClient(gatewayID: prompt.gatewayID)
                switch prompt.kind {
                case .clarify:
                    if let selections {
                        try await client.respondToClarify(sessionID: prompt.sessionID,
                                                          requestID: prompt.requestID,
                                                          selections: selections)
                    } else {
                        try await client.respondToClarify(sessionID: prompt.sessionID,
                                                          requestID: prompt.requestID,
                                                          answer: answer)
                    }
                case .sudo:
                    try await client.respondToSudo(requestID: prompt.requestID, password: answer)
                case .secret:
                    try await client.respondToSecret(requestID: prompt.requestID, value: answer)
                }
            } catch {
                // Never surface the value itself — only that the reply failed
                // and the tool is still waiting on its own timeout.
                guard let botID else { return }
                self.noteApproval(self.theme.copy.promptSendFailed(self.theme.themeID),
                                  for: botID)
            }
        }
    }
}
