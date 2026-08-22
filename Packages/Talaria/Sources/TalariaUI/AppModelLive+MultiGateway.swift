import Foundation
import Observation
import TalariaKit

// Phase 4 — one roster across every configured Connection.
//
// Desktop's Bot Mode roster is a union, not a list: `useRoster` merges the
// active gateway's rich `profiles.list` with `host.agents()` across every
// registered Connection (plugin.js:2265-2360). Same-source rows are annotated
// in place; rows from other sources are appended as thin `remoteSource` rows
// carrying a device label, and the duplicate-name rule mints `@name-device`
// handles once across all sources (electron/connection-registry.ts:330-372).
//
// `GatewayClientPool` keeps authenticated secondary connections alive and
// coalesces dials. Chat, events, sessions, approvals, and unread state retain
// their source route instead of switching the primary AppModel world.

/// Book-keeping for the union roster. `AppModel`'s stored properties live in
/// AppModel.swift (another owner); extensions cannot add storage, so the
/// in-flight switch rides a MainActor singleton — observable, because roster
/// rows read it from a view body to go inert while a switch is under way.
@MainActor
@Observable
final class MultiGatewayRuntime {
    static let shared = MultiGatewayRuntime()

    /// Gateway id of a switch in flight — a second tap while the world is
    /// being torn down and rebuilt would race `switchGateway` against itself.
    var switchingGatewayID: String?

    struct RoutedEvents {
        var client: GatewayClient
        var handlerID: UUID
        var pump: Task<Void, Never>
        /// Kept so rollback can return the exact target events that were
        /// temporarily parked by a same-client handoff.
        var continuation: AsyncStream<GatewayEvent>.Continuation?
        var gate: RoutedEventGate?
        var generation: UInt64

        @MainActor
        init(client: GatewayClient, handlerID: UUID, pump: Task<Void, Never>,
             continuation: AsyncStream<GatewayEvent>.Continuation? = nil,
             gate: RoutedEventGate? = nil, generation: UInt64 = 0) {
            self.client = client
            self.handlerID = handlerID
            self.pump = pump
            self.continuation = continuation
            self.gate = gate ?? RoutedEventGate(client: client, generation: generation)
            self.generation = generation
        }
    }

    var routedEvents: [String: RoutedEvents] = [:]
    var routedEventGenerations: [String: UInt64] = [:]
    /// Focused preparation seam: tests use this to publish a newer routed
    /// subscription while the staged handler is being installed. The source
    /// identity check must preserve that newer owner when the older prepare
    /// attempt subsequently fails closed.
    var prepareAfterHandlerInstallationForTesting:
        (@MainActor (_ gatewayID: String, _ client: GatewayClient,
                     _ handlerID: UUID) async -> Void)?
    /// Unread counts for bots whose gateway is not currently primary.
    /// Primary rows keep the existing `Bot.unread` storage for compatibility;
    /// gateway switches move counts between the two representations.
    var routedUnread: [GatewayBotRoute: Int] = [:]
}

/// Main-actor delivery authority for one routed pump generation. A client can
/// briefly have two handlers during an exact-session handoff, so the handler
/// identity alone is not enough to decide which queued frame owns a route.
/// The gate provides a small sequence ledger and a target-session quarantine:
/// the old same-client pump keeps global/unrelated events, while target events
/// are handed to the staged pump. A different or retired client cannot inject
/// frames after the atomic swap.
@MainActor
final class RoutedEventGate {
    let clientIdentity: ObjectIdentifier
    let generation: UInt64

    private enum State {
        case active
        case staging
        case handingOff(targetSessionID: String)
        case retired
    }

    private var state: State = .active
    /// Frames already assigned to the old pump. The same-client handoff has
    /// two fan-out handlers, so the staged handler must be able to recognize
    /// these frames without consuming them a second time.
    private var oldSequences: Set<UInt64> = []
    private var oldUnsequenced: [GatewayEvent] = []
    /// Frames whose ownership moved to the staged pump. Keeping this separate
    /// from `delivered` matters when the old handler observes a frame before
    /// the staged handler: the latter still has to deliver it once.
    private var targetSequences: Set<UInt64> = []
    private var targetUnsequenced: [GatewayEvent] = []
    private var deliveredSequences: Set<UInt64> = []
    private var deliveredUnsequenced: [GatewayEvent] = []
    private var stagedEvents: [GatewayEvent] = []
    private var deferredTargetEvents: [GatewayEvent] = []
    private var replayOldSequences: Set<UInt64> = []
    private var replayOldEvents: [GatewayEvent] = []
    /// A prior gate is allowed to hand its client over after it is retired;
    /// the replacement pump then owns all subsequent frames. A replacement
    /// gate itself never allows delivery after retirement.
    private var allowsStagedAfterRetire = false

    init(client: GatewayClient, generation: UInt64) {
        clientIdentity = ObjectIdentifier(client)
        self.generation = generation
    }

    func beginHandoff(targetSessionID: String) {
        guard case .active = state else { return }
        state = .handingOff(targetSessionID: targetSessionID)
    }

    /// Freeze session-specific ownership before the staged handler starts its
    /// resume. Global broadcasts remain with the old pump; session frames are
    /// held until the authoritative runtime session id is known.
    func beginStaging() {
        guard case .active = state else { return }
        state = .staging
    }

    /// Resolve the pre-resume hold at the atomic swap. Target frames stay in
    /// the staged stream; unrelated session frames are returned to the old
    /// stream so they retain their old source ownership.
    func finishStaging(targetSessionID: String) -> [GatewayEvent] {
        guard case .staging = state else { return [] }
        state = .handingOff(targetSessionID: targetSessionID)
        let held = stagedEvents
        stagedEvents.removeAll(keepingCapacity: false)
        var unrelated: [GatewayEvent] = []
        for event in held {
            if event.sessionID == targetSessionID {
                markTarget(event, deferForRollback: true)
            } else {
                _ = markOld(event)
                unrelated.append(event)
            }
        }
        return unrelated
    }

    func retire() {
        state = .retired
        allowsStagedAfterRetire = false
    }

    /// Retire the old same-client gate after visible adoption. Its handler is
    /// still being removed asynchronously, but the replacement must own every
    /// frame that arrives during that removal window.
    func retireForStagedReplacement() {
        state = .retired
        allowsStagedAfterRetire = true
    }

    var isOpen: Bool {
        if case .retired = state { return false }
        return true
    }

    /// Claim a frame for the pump that currently owns this gate. During a
    /// same-client handoff, only the exact target session is parked; unrelated
    /// sessions and global broadcasts remain with the old pump.
    func claimForPump(_ event: GatewayEvent) -> Bool {
        guard isOpen else { return false }
        if case .staging = state, !event.sessionID.isEmpty {
            guard !stagedEvents.contains(where: { sameEvent($0, event) }) else {
                return false
            }
            stagedEvents.append(event)
            return false
        }
        if case .handingOff(let targetSessionID) = state,
           event.sessionID == targetSessionID {
            markTarget(event, deferForRollback: true)
            return false
        }
        if consumeOldReplay(event) { return true }
        return markOld(event)
    }

    /// Claim a frame for the staged pump. A target frame parked by the old
    /// pump becomes staged-owned; frames already claimed by the old generation
    /// (including global/unrelated frames) stay there and are not duplicated.
    func claimForStaged(_ event: GatewayEvent) -> Bool {
        switch state {
        case .active:
            return markDelivered(event)
        case .staging:
            return false
        case .handingOff(let targetSessionID):
            guard event.sessionID == targetSessionID else { return false }
            markTarget(event, deferForRollback: false)
            return markDelivered(event)
        case .retired:
            guard allowsStagedAfterRetire else { return false }
            // The prepared handler saw the same frames as the old handler
            // before that handler was retired.  Keep those old-owned frames
            // out of the replacement pump, while still admitting frames that
            // first arrive after retirement (and target frames that were
            // parked for the staged handoff).
            if event.inboundSequence != 0 {
                guard !oldSequences.contains(event.inboundSequence) else {
                    return false
                }
            } else {
                guard !oldUnsequenced.contains(where: { sameEvent($0, event) }) else {
                    return false
                }
            }
            return markDelivered(event)
        }
    }

    /// Restore the old generation after a failed visible adoption and return
    /// only the target frames it parked. The caller yields these synchronously
    /// back into the old stream before the transaction is considered settled.
    func restoreForRollback() -> [GatewayEvent] {
        state = .active
        allowsStagedAfterRetire = false
        let replay = uniqueEvents(stagedEvents + deferredTargetEvents)
        for event in replay {
            removeTarget(event)
            removeDelivered(event)
        }
        stagedEvents.removeAll(keepingCapacity: false)
        deferredTargetEvents.removeAll(keepingCapacity: false)
        targetSequences.removeAll(keepingCapacity: false)
        targetUnsequenced.removeAll(keepingCapacity: false)
        deliveredSequences.removeAll(keepingCapacity: false)
        deliveredUnsequenced.removeAll(keepingCapacity: false)
        return replay
    }

    /// Mark frames that were consumed by the old pump while staging as
    /// explicitly replayable to that same pump. This is used only for held
    /// unrelated events; target events remain staged-owned.
    func prepareOldReplay(_ events: [GatewayEvent]) {
        for event in events {
            if event.inboundSequence != 0 {
                replayOldSequences.insert(event.inboundSequence)
            } else if !replayOldEvents.contains(where: { sameEvent($0, event) }) {
                replayOldEvents.append(event)
            }
        }
    }

    private func markTarget(_ event: GatewayEvent, deferForRollback: Bool) {
        if event.inboundSequence != 0 {
            guard targetSequences.insert(event.inboundSequence).inserted else {
                if deferForRollback,
                   !deferredTargetEvents.contains(where: { sameEvent($0, event) }) {
                    deferredTargetEvents.append(event)
                }
                return
            }
        }
        else if targetUnsequenced.contains(where: { sameEvent($0, event) }) {
            if deferForRollback,
               !deferredTargetEvents.contains(where: { sameEvent($0, event) }) {
                deferredTargetEvents.append(event)
            }
            return
        }
        if event.inboundSequence == 0 { targetUnsequenced.append(event) }
        if deferForRollback,
           !deferredTargetEvents.contains(where: { sameEvent($0, event) }) {
            deferredTargetEvents.append(event)
        }
    }

    private func markOld(_ event: GatewayEvent) -> Bool {
        if event.inboundSequence != 0 {
            return oldSequences.insert(event.inboundSequence).inserted
        }
        guard !oldUnsequenced.contains(where: { sameEvent($0, event) }) else {
            return false
        }
        oldUnsequenced.append(event)
        return true
    }

    private func markDelivered(_ event: GatewayEvent) -> Bool {
        if event.inboundSequence != 0 {
            return deliveredSequences.insert(event.inboundSequence).inserted
        }
        guard !deliveredUnsequenced.contains(where: { sameEvent($0, event) }) else {
            return false
        }
        deliveredUnsequenced.append(event)
        return true
    }

    private func consumeOldReplay(_ event: GatewayEvent) -> Bool {
        if event.inboundSequence != 0 {
            return replayOldSequences.remove(event.inboundSequence) != nil
        }
        guard let index = replayOldEvents.firstIndex(where: { sameEvent($0, event) })
        else { return false }
        replayOldEvents.remove(at: index)
        return true
    }

    private func removeTarget(_ event: GatewayEvent) {
        if event.inboundSequence != 0 {
            targetSequences.remove(event.inboundSequence)
        } else {
            targetUnsequenced.removeAll { sameEvent($0, event) }
        }
    }

    private func removeDelivered(_ event: GatewayEvent) {
        if event.inboundSequence != 0 {
            deliveredSequences.remove(event.inboundSequence)
        } else {
            deliveredUnsequenced.removeAll { sameEvent($0, event) }
        }
    }

    private func uniqueEvents(_ events: [GatewayEvent]) -> [GatewayEvent] {
        var result: [GatewayEvent] = []
        for event in events where !result.contains(where: { sameEvent($0, event) }) {
            result.append(event)
        }
        return result
    }

    private func sameEvent(_ lhs: GatewayEvent, _ rhs: GatewayEvent) -> Bool {
        lhs.type == rhs.type && lhs.sessionID == rhs.sessionID
            && lhs.payload == rhs.payload
            && lhs.inboundSequence == rhs.inboundSequence
    }
}

/// The old routed subscription remains live while a staged exact-session open
/// crosses its synchronous visible-adoption boundary. Keeping this token on
/// the MainActor makes a same-client swap reversible; a different-client
/// failure instead retires both generations without reconstructing stale
/// approval or runtime state.
@MainActor
final class ExactRoutedEventsTransaction {
    let gatewayID: String
    let replacement: MultiGatewayRuntime.RoutedEvents
    let prepared: PreparedExactRoutedEvents
    private let previous: MultiGatewayRuntime.RoutedEvents?
    private let previousGeneration: UInt64
    private let previousApprovalSweepEpoch: Int?
    private var settled = false
    private var finalizing = false

    init(gatewayID: String,
         replacement: MultiGatewayRuntime.RoutedEvents,
         previous: MultiGatewayRuntime.RoutedEvents?,
         previousGeneration: UInt64,
         previousApprovalSweepEpoch: Int?,
         prepared: PreparedExactRoutedEvents) {
        self.gatewayID = gatewayID
        self.replacement = replacement
        self.previous = previous
        self.previousGeneration = previousGeneration
        self.previousApprovalSweepEpoch = previousApprovalSweepEpoch
        self.prepared = prepared
    }

    /// Undo only the synchronous swap.  No await occurs here, so a caller can
    /// decide visible adoption and restore the old source as one MainActor
    /// transaction.
    func rollback() {
        guard !settled, !finalizing else { return }
        let runtime = MultiGatewayRuntime.shared
        guard let current = runtime.routedEvents[gatewayID],
              current.handlerID == replacement.handlerID,
              ObjectIdentifier(current.client) == ObjectIdentifier(replacement.client) else {
            // A source teardown/replacement already won.  Do not resurrect an
            // older subscription over that newer authority.
            settled = true
            replacement.gate?.retire()
            prepared.forgetStagedPrior()
            prepared.abandonCommitted()
            return
        }
        replacement.gate?.retire()
        replacement.pump.cancel()

        // A same-client handoff is reversible: the old gate parked target
        // frames and can replay them into the old pump without changing the
        // source identity. A different client is not reversible. Its prior
        // handler was retired at commit because that client is no longer the
        // pool owner; restoring it here would reopen a stale source and let a
        // queued frame from the old connection mutate the new world.
        let canRestorePrevious = previous.map {
            ObjectIdentifier($0.client) == ObjectIdentifier(replacement.client)
        } == true
        if canRestorePrevious, let previous {
            let replay = previous.gate?.restoreForRollback() ?? []
            for event in replay { previous.continuation?.yield(event) }
            runtime.routedEvents[gatewayID] = previous
            runtime.routedEventGenerations[gatewayID] = previousGeneration
            if let previousApprovalSweepEpoch {
                ApprovalBridges.shared.sweepEpochs[gatewayID] = previousApprovalSweepEpoch
            } else {
                ApprovalBridges.shared.sweepEpochs[gatewayID] = nil
            }
        } else {
            // Keep the source unpublished until a fresh attach wins. The
            // generation bump is deliberate: a late completion or stale
            // cleanup from either client must not be able to claim this slot.
            runtime.routedEvents[gatewayID] = nil
            let currentGeneration = runtime.routedEventGenerations[gatewayID,
                                                                   default: replacement.generation]
            runtime.routedEventGenerations[gatewayID] = currentGeneration &+ 1
            // Do not restore the prior sweep epoch. Approval.pending work
            // issued against the retired client belongs to that source and
            // must be fenced until a new subscription starts its own sweep.
            ApprovalBridges.shared.resetSweepScope(gatewayID: gatewayID)
        }
        prepared.abandonCommitted()
        settled = true
    }

    /// If a source teardown/replacement won before rollback could restore the
    /// old runtime slot, retire and remove that stale prior handler as well.
    /// The normal rollback path is a no-op here because the restored prior
    /// subscription is again the current runtime owner.
    func cleanupSupersededPrevious() async {
        let runtime = MultiGatewayRuntime.shared
        guard let previous, !ownsRuntime(previous, runtime: runtime) else { return }
        previous.gate?.retire()
        previous.continuation?.finish()
        previous.pump.cancel()
        await previous.client.removeEventHandler(previous.handlerID)
    }

    /// Remove the old handler only after visible adoption has succeeded.  The
    /// replacement remains installed throughout; broad routed-state teardown
    /// would erase the newly bound session and approvals, so finalization only
    /// retires the old subscription and starts a fresh approval sweep epoch.
    @discardableResult
    func finalize(model: AppModel) async -> Bool {
        guard !settled, !finalizing else { return false }
        let runtime = MultiGatewayRuntime.shared
        guard ownsCurrentRuntime(runtime) else {
            replacement.gate?.retire()
            prepared.abandonCommitted()
            if let previous, !ownsRuntime(previous, runtime: runtime) {
                previous.gate?.retire()
                previous.continuation?.finish()
                previous.pump.cancel()
                await previous.client.removeEventHandler(previous.handlerID)
            }
            settled = true
            return false
        }
        finalizing = true
        if let previous,
           previous.handlerID != replacement.handlerID
            || ObjectIdentifier(previous.client) != ObjectIdentifier(replacement.client) {
            // Retire the authority synchronously before cancellation/removal;
            // a queued old-client frame must fail its exact generation gate
            // even if the actor hop below has not completed yet.
            previous.gate?.retireForStagedReplacement()
            previous.continuation?.finish()
            previous.pump.cancel()
            await previous.client.removeEventHandler(previous.handlerID)
        }
        guard ownsCurrentRuntime(runtime) else {
            replacement.gate?.retire()
            prepared.abandonCommitted()
            settled = true
            return false
        }
        ApprovalBridges.shared.resetSweepScope(gatewayID: gatewayID)
        Task { @MainActor [weak model] in await model?.replayPendingApprovals() }
        settled = true
        return true
    }

    private func ownsCurrentRuntime(_ runtime: MultiGatewayRuntime) -> Bool {
        ownsRuntime(replacement, runtime: runtime)
    }

    private func ownsRuntime(_ candidate: MultiGatewayRuntime.RoutedEvents,
                             runtime: MultiGatewayRuntime) -> Bool {
        guard let current = runtime.routedEvents[gatewayID] else { return false }
        return current.handlerID == candidate.handlerID
            && ObjectIdentifier(current.client) == ObjectIdentifier(candidate.client)
    }
}

/// A secondary-source event intake that is invisible until exact session
/// authority succeeds. The handler starts buffering immediately; publication
/// installs its gated pump only after the authoritative snapshot is ready.
@MainActor
final class PreparedExactRoutedEvents {
    let client: GatewayClient
    let gatewayID: String
    let handlerID: UUID
    let stream: AsyncStream<GatewayEvent>
    let continuation: AsyncStream<GatewayEvent>.Continuation
    private var committed = false
    private var activation: AsyncStream<Void>.Continuation?
    /// The exact routed owner that was present when preparation started. A
    /// same-client owner can be restored if resume/authority fails before the
    /// visible commit; a different-client owner is already stale once the
    /// pool has published the replacement and must be retired permanently.
    private var stagedPrior: MultiGatewayRuntime.RoutedEvents?
    private var stagedPriorCanRestore = false
    private var discarded = false

    init(client: GatewayClient, gatewayID: String, handlerID: UUID,
         stream: AsyncStream<GatewayEvent>,
         continuation: AsyncStream<GatewayEvent>.Continuation) {
        self.client = client
        self.gatewayID = gatewayID
        self.handlerID = handlerID
        self.stream = stream
        self.continuation = continuation
    }

    func markCommitted(_ activation: AsyncStream<Void>.Continuation) {
        committed = true
        self.activation = activation
    }

    func rememberStagedPrior(_ prior: MultiGatewayRuntime.RoutedEvents,
                             canRestore: Bool) {
        stagedPrior = prior
        stagedPriorCanRestore = canRestore
    }

    /// Resume/authority failure happens before a transaction exists. Restore
    /// only an exact same-client owner synchronously before removing the
    /// invisible handler. A newer publication winning during the await must
    /// never be overwritten by this stale attempt.
    @discardableResult
    func restoreStagedPrior() -> MultiGatewayRuntime.RoutedEvents? {
        guard stagedPriorCanRestore, let prior = stagedPrior else { return nil }
        defer {
            stagedPrior = nil
            stagedPriorCanRestore = false
        }
        let runtime = MultiGatewayRuntime.shared
        guard ownsRuntime(prior, runtime: runtime) else {
            prior.gate?.retire()
            prior.continuation?.finish()
            prior.pump.cancel()
            return prior
        }
        let replay = prior.gate?.restoreForRollback() ?? []
        for event in replay { prior.continuation?.yield(event) }
        return nil
    }

    func forgetStagedPrior() {
        stagedPrior = nil
        stagedPriorCanRestore = false
    }

    /// Mark a published intake as abandoned during a synchronous transaction
    /// rollback.  The pump is cancelled by the transaction; closing both
    /// streams prevents a later activation from reviving it.
    func abandonCommitted() {
        committed = false
        activation?.finish()
        activation = nil
        continuation.finish()
    }

    func activate() {
        activation?.yield(())
        activation?.finish()
        activation = nil
    }

    func finish() { continuation.finish() }

    func discard() async {
        guard !committed, !discarded else { return }
        discarded = true
        let prior = stagedPrior
        let canRestore = stagedPriorCanRestore
        var stalePrior: MultiGatewayRuntime.RoutedEvents?
        if canRestore {
            stalePrior = restoreStagedPrior()
        } else if let prior {
            // The pool has already selected a different client. Retire every
            // old delivery path synchronously, then remove only the captured
            // handler. If a newer runtime publication won during resume, its
            // slot and approval scope remain untouched.
            prior.gate?.retire()
            prior.continuation?.finish()
            prior.pump.cancel()
            let runtime = MultiGatewayRuntime.shared
            if ownsRuntime(prior, runtime: runtime) {
                runtime.routedEvents[gatewayID] = nil
                runtime.routedEventGenerations[gatewayID,
                                               default: prior.generation] &+= 1
                ApprovalBridges.shared.resetSweepScope(gatewayID: gatewayID)
            }
            forgetStagedPrior()
            await prior.client.removeEventHandler(prior.handlerID)
        }
        if let stalePrior {
            await stalePrior.client.removeEventHandler(stalePrior.handlerID)
        }
        continuation.finish()
        await client.removeEventHandler(handlerID)
    }

    func discardAfterRollback() async {
        guard !discarded else { return }
        discarded = true
        forgetStagedPrior()
        abandonCommitted()
        await client.removeEventHandler(handlerID)
    }

    private func ownsRuntime(_ candidate: MultiGatewayRuntime.RoutedEvents,
                             runtime: MultiGatewayRuntime) -> Bool {
        guard let current = runtime.routedEvents[gatewayID] else { return false }
        return current.handlerID == candidate.handlerID
            && ObjectIdentifier(current.client) == ObjectIdentifier(candidate.client)
    }

    func yieldForTesting(_ event: GatewayEvent) { continuation.yield(event) }
}

public extension AppModel {

    private func consumeRoutedEvent(_ event: GatewayEvent, gatewayID: String,
                                    client: GatewayClient,
                                    gate: RoutedEventGate? = nil) async {
        guard gate?.isOpen ?? true else { return }
        handle(event: event, sourceGatewayID: gatewayID)
        guard gate?.isOpen ?? true else { return }
        await handleMCPSetupWireEvent(event, sourceGatewayID: gatewayID,
                                      sourceClient: client)
        guard gate?.isOpen ?? true else { return }
        handleBridgeEvent(event, sourceGatewayID: gatewayID)
        routeToolEvent(event, sourceGatewayID: gatewayID)
        routeSessionEvent(event, sourceGatewayID: gatewayID)
        routePetEvent(event, sourceGatewayID: gatewayID)
        routeA2AChange(event, sourceGatewayID: gatewayID)
    }

    /// Install a handler on a not-yet-published secondary client. Existing
    /// routed state remains untouched until `commitExactRoutedEvents`.
    internal func prepareExactRoutedEvents(client: GatewayClient,
                                           gatewayID: String) async
        -> PreparedExactRoutedEvents? {
        guard gatewayID != activeGatewayID else { return nil }
        let existing = MultiGatewayRuntime.shared.routedEvents[gatewayID]
        let sameClient = existing.map {
            ObjectIdentifier($0.client) == ObjectIdentifier(client)
        } == true
        if sameClient {
            existing?.gate?.beginStaging()
        } else {
            // The pool has already selected this client as the source's
            // current identity. Keep the old handler attached only until the
            // pre-commit resume settles, but reject its stale frames while the
            // exact resume is in flight; a failure retires it permanently.
            existing?.gate?.retire()
        }
        let (stream, continuation) = AsyncStream.makeStream(of: GatewayEvent.self)
        let handlerID = await client.addEventHandler { continuation.yield($0) }
        if let hook = MultiGatewayRuntime.shared.prepareAfterHandlerInstallationForTesting {
            await hook(gatewayID, client, handlerID)
        }
        let current = await ConnectionRegistry.shared.clientPool.client(for: gatewayID)
        // A missing pool entry is tolerated for deterministic/test clients;
        // the caller's captured source fence remains authoritative in live
        // navigation. If a slot exists, however, identity must be exact.
        guard current == nil
            || current.map(ObjectIdentifier.init) == ObjectIdentifier(client) else {
            if let existing {
                // The pool has moved on while this attempt was suspended. Both
                // the requested client and the captured routed owner are stale
                // relative to that slot, so rollback must not resurrect the
                // old source. Retire it before removing its handler; a queued
                // frame must fail closed even while actor cleanup is pending.
                existing.gate?.retire()
                existing.continuation?.finish()
                existing.pump.cancel()

                // Do not clear a newer publication that won while the handler
                // was being installed. This check and the removal are both
                // synchronous on MainActor, so no newer owner can interleave.
                let ownsCapturedRuntime = MultiGatewayRuntime.shared
                    .routedEvents[gatewayID]
                    .map {
                        $0.handlerID == existing.handlerID
                            && ObjectIdentifier($0.client)
                                == ObjectIdentifier(existing.client)
                    } == true
                if ownsCapturedRuntime {
                    MultiGatewayRuntime.shared.routedEvents[gatewayID] = nil
                    MultiGatewayRuntime.shared.routedEventGenerations[gatewayID,
                                                                        default: 0] &+= 1
                    ApprovalBridges.shared.resetSweepScope(gatewayID: gatewayID)
                }
                await existing.client.removeEventHandler(existing.handlerID)
            }
            await client.removeEventHandler(handlerID)
            continuation.finish()
            return nil
        }
        let prepared = PreparedExactRoutedEvents(
            client: client, gatewayID: gatewayID, handlerID: handlerID,
            stream: stream, continuation: continuation)
        if let existing {
            prepared.rememberStagedPrior(
                existing,
                canRestore: ObjectIdentifier(existing.client)
                    == ObjectIdentifier(client))
        }
        return prepared
    }

    /// Synchronously swap a prepared intake into the routed runtime without
    /// starting delivery.  The old subscription is intentionally left attached
    /// until the caller's visible begin succeeds; the returned transaction can
    /// restore it synchronously or finalize it after hydration.
    internal func commitExactRoutedEvents(_ prepared: PreparedExactRoutedEvents,
                                          snapshotSequence: UInt64,
                                          snapshotSessionID: String,
                                          snapshotEvidence: ResumeSnapshotEvidence? = nil) throws
        -> ExactRoutedEventsTransaction {
        let gatewayID = prepared.gatewayID
        guard gatewayID != activeGatewayID else { throw CancellationError() }
        let runtime = MultiGatewayRuntime.shared
        let previous = runtime.routedEvents[gatewayID]
        let previousGeneration = runtime.routedEventGenerations[gatewayID, default: 0]
        let previousApprovalSweepEpoch = ApprovalBridges.shared.sweepEpochs[gatewayID]
        let generation = previousGeneration &+ 1
        let (activationStream, activation) = AsyncStream.makeStream(of: Void.self)
        let priorGate: RoutedEventGate?
        if let previous {
            if ObjectIdentifier(previous.client) == ObjectIdentifier(prepared.client) {
                let unrelated = previous.gate?.finishStaging(
                    targetSessionID: snapshotSessionID) ?? []
                previous.gate?.prepareOldReplay(unrelated)
                for event in unrelated { previous.continuation?.yield(event) }
                priorGate = previous.gate
            } else {
                // A different client/generation can never be allowed to race
                // the staged source after this synchronous swap.
                previous.gate?.retire()
                priorGate = nil
            }
        } else {
            priorGate = nil
        }
        let replacementGate = RoutedEventGate(
            client: prepared.client, generation: generation)
        let pump = Task { @MainActor [weak self] in
            for await _ in activationStream { break }
            guard let self else { return }
            for await event in prepared.stream {
                if let priorGate, !priorGate.claimForStaged(event) {
                    continue
                }
                guard replacementGate.claimForStaged(event) else { continue }
                // The sequence is only a boundary. Suppress a target event
                // below it only when durable/state evidence proves that the
                // exact event is already present in the resume projection.
                if event.sessionID == snapshotSessionID,
                   event.inboundSequence != 0,
                   event.inboundSequence <= snapshotSequence,
                   snapshotEvidence?.represents(event) == true {
                    continue
                }
                await self.consumeRoutedEvent(
                    event, gatewayID: gatewayID, client: prepared.client,
                    gate: replacementGate)
            }
        }
        let replacement = MultiGatewayRuntime.RoutedEvents(
            client: prepared.client, handlerID: prepared.handlerID, pump: pump,
            continuation: prepared.continuation, gate: replacementGate,
            generation: generation)
        runtime.routedEventGenerations[gatewayID] = generation
        runtime.routedEvents[gatewayID] = replacement
        prepared.markCommitted(activation)
        let transaction = ExactRoutedEventsTransaction(
            gatewayID: gatewayID, replacement: replacement, previous: previous,
            previousGeneration: previousGeneration,
            previousApprovalSweepEpoch: previousApprovalSweepEpoch,
            prepared: prepared)
        // The transaction now owns the exact `previous` cleanup/rollback
        // decision. Do not leave either prior record on the prepared intake to
        // be considered by a later pre-commit discard.
        prepared.forgetStagedPrior()
        return transaction
    }

    enum GatewayRouteError: LocalizedError {
        case noRoute
        case unknownGateway(String)
        case missingCredential(String)

        public var errorDescription: String? {
            switch self {
            case .noRoute: return "The bot has no gateway route."
            case .unknownGateway(let id): return "Gateway \(id) is no longer registered."
            case .missingCredential(let name): return "Sign in to \(name) to continue."
            }
        }
    }

    // MARK: - The active source

    /// Saved-gateway id of the live link, or nil when nothing is connected.
    /// Nil is meaningful: with no live gateway every saved one is a foreign
    /// source, so the honest empty roster still shows what it last knew.
    var activeGatewayID: String? {
        guard client != nil, let base = LiveRuntime.shared.baseURL else { return nil }
        return ConnectionRegistry.shared.gateway(forURL: base)?.id
    }

    /// Display label of the live gateway, for the "you are here" annotation.
    var activeConnectionLabel: String? {
        guard let base = LiveRuntime.shared.baseURL else { return nil }
        return ConnectionRegistry.shared.gateway(forURL: base)?.name
    }

    /// Resolve a roster identity without guessing which machine owns a bare
    /// profile name.
    func gatewayRoute(for rosterID: String) -> GatewayBotRoute? {
        GatewayBotRoute.resolve(rosterID: rosterID, activeGatewayID: activeGatewayID)
    }

    /// Resolve state ownership without requiring a connected client. Unlike
    /// `gatewayRoute`, this is valid during reconnect and gateway switching,
    /// when UI state still needs a collision-safe key.
    func stateRoute(for rosterID: String) -> GatewayBotRoute? {
        if let qualified = GatewayBotRoute(qualifiedID: rosterID) { return qualified }
        guard let gatewayID = LiveRuntime.shared.gatewayID, !rosterID.isEmpty else { return nil }
        return GatewayBotRoute(gatewayID: gatewayID, profile: rosterID)
    }

    func gatewayBaseURL(for route: GatewayBotRoute) -> URL? {
        if route.gatewayID == LiveRuntime.shared.gatewayID { return LiveRuntime.shared.baseURL }
        return ConnectionRegistry.shared.saved.first(where: { $0.id == route.gatewayID })?.baseURL
    }

    /// Obtain the client that owns a source-qualified bot. The primary client
    /// is reused directly; secondary clients are connected and retained by the
    /// registry pool without changing the app's active gateway.
    func routedClient(for route: GatewayBotRoute) async throws -> GatewayClient {
        try await routedClient(gatewayID: route.gatewayID)
    }

    /// Resolve a connection when the protocol request has no profile field
    /// (sudo/secret responses are keyed only by request_id).
    func routedClient(gatewayID: String) async throws -> GatewayClient {
        guard profileLifecycleAllowsGatewayTraffic(gatewayID) else {
            throw GatewayError(code: GatewayClient.trafficFenced,
                               message: "Gateway traffic is paused while a profile change is being resolved.")
        }
        if gatewayID == activeGatewayID, let client {
            // Pool adoption installs this on normal primary connections. Set
            // it again defensively for restored/test clients that predate the
            // pool entry, then re-check after the actor hop.
            await client.setTrafficAdmission {
                await ProfileLifecycleTrafficAdmission.acquire(gatewayID)
            }
            guard profileLifecycleAllowsGatewayTraffic(gatewayID) else {
                throw GatewayError(code: GatewayClient.trafficFenced,
                                   message: "Gateway traffic is paused while a profile change is being resolved.")
            }
            return client
        }
        let registry = ConnectionRegistry.shared
        guard let gateway = registry.saved.first(where: { $0.id == gatewayID }),
              let baseURL = gateway.baseURL else {
            throw GatewayRouteError.unknownGateway(gatewayID)
        }
        guard let credential = registry.credential(for: gateway) else {
            throw GatewayRouteError.missingCredential(gateway.name)
        }
        let routed = try await registry.clientPool.connect(gatewayID: gateway.id,
                                                           baseURL: baseURL,
                                                           credential: credential)
        guard profileLifecycleAllowsGatewayTraffic(gatewayID) else {
            throw GatewayError(code: GatewayClient.trafficFenced,
                               message: "Gateway traffic is paused while a profile change is being resolved.")
        }
        return routed
    }

    /// Subscribe once to a secondary gateway and retain source information on
    /// every event. An AsyncStream pump preserves the order in which the
    /// GatewayClient fan-out delivered deltas.
    func attachRoutedEventsIfNeeded(client: GatewayClient, gatewayID: String,
                                    preserveStateOnReplacement: Bool = false) async {
        guard gatewayID != activeGatewayID else { return }
        let runtime = MultiGatewayRuntime.shared
        if let existing = runtime.routedEvents[gatewayID],
           ObjectIdentifier(existing.client) == ObjectIdentifier(client) { return }
        if preserveStateOnReplacement, runtime.routedEvents[gatewayID] != nil {
            // Some feature lanes deliberately preserve transcript/model state
            // while swapping a secondary socket. Command prefills and parked
            // MCP request IDs are process-generation authority, never durable
            // presentation state, so they must still be purged.
            dropCommandsScope(gatewayID: gatewayID)
        }
        if preserveStateOnReplacement || runtime.routedEvents[gatewayID] == nil {
            await removeRoutedEventSubscription(gatewayID: gatewayID)
        } else {
            await detachRoutedEvents(gatewayID: gatewayID)
        }
        runtime.routedEventGenerations[gatewayID, default: 0] &+= 1
        let generation = runtime.routedEventGenerations[gatewayID, default: 0]

        let (stream, continuation) = AsyncStream.makeStream(of: GatewayEvent.self)
        let handlerID = await client.addEventHandler { continuation.yield($0) }
        let currentClient = await ConnectionRegistry.shared.clientPool.client(for: gatewayID)
        guard runtime.routedEventGenerations[gatewayID] == generation,
              runtime.routedEvents[gatewayID] == nil,
              currentClient.map(ObjectIdentifier.init) == ObjectIdentifier(client) else {
            await client.removeEventHandler(handlerID)
            continuation.finish()
            return
        }
        let gate = RoutedEventGate(client: client, generation: generation)
        let pump = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                guard gate.claimForPump(event) else { continue }
                await self.consumeRoutedEvent(
                    event, gatewayID: gatewayID, client: client, gate: gate)
            }
        }
        runtime.routedEvents[gatewayID] = MultiGatewayRuntime.RoutedEvents(
            client: client, handlerID: handlerID, pump: pump,
            continuation: continuation, gate: gate, generation: generation)
        ApprovalBridges.shared.resetSweepScope(gatewayID: gatewayID)
        Task { @MainActor [weak self] in await self?.replayPendingApprovals() }
    }

    func detachRoutedEvents(gatewayID: String) async {
        await detachRoutedEvents(gatewayID: gatewayID, expected: nil)
    }

    /// Detach a retained source only when the caller still owns the exact pool
    /// slot it started against. Roster failures can arrive after `adopt` has
    /// installed a replacement, and tearing down by gateway id alone would
    /// clear the replacement's Workspace/Operator state.
    func detachRoutedEvents(
        gatewayID: String, expected: GatewayClientPool.ConnectionSnapshot?
    ) async {
        if let expected {
            guard gatewayID != LiveRuntime.shared.gatewayID,
                  gatewayID != activeGatewayID,
                  await ConnectionRegistry.shared.clientPool.isCurrent(
                      expected, for: gatewayID) else { return }
        }
        // A retained secondary can own the Command Center source even while
        // the primary socket stays up. Tear down that exact workspace scope
        // and invalidate selected Operator reads before the pool client is
        // released, so a late status response cannot restore old controls.
        OperatorSettingsRuntime.shared.invalidateConnectionScope()
        dropCommandsScope(gatewayID: gatewayID)
        dropWorkspaceScope(gatewayID: gatewayID)
        await removeRoutedEventSubscription(gatewayID: gatewayID)
        dropApprovalScope(gatewayID: gatewayID)
        dropRoutineScope(gatewayID: gatewayID)
        dropCapabilityScope(gatewayID: gatewayID)
        dropModelScope(gatewayID: gatewayID)
        dropApprovalPolicyScope(gatewayID: gatewayID)
        dropA2AScope(gatewayID: gatewayID)
        dropArtifactScope(gatewayID: gatewayID)
        ProfileAssetStore.shared.drop(gatewayID: gatewayID)
        dropPetScope(gatewayID: gatewayID)
        LiveRuntime.shared.resetRoutedState(gatewayID: gatewayID)
        CanonicalChatRuntime.shared.resetRoutedScope(gatewayID: gatewayID)
        SessionsRuntime.shared.resetRoutedScope(gatewayID: gatewayID)
    }

    func removeRoutedEventSubscription(gatewayID: String) async {
        MultiGatewayRuntime.shared.routedEventGenerations[gatewayID, default: 0] &+= 1
        if let subscription = MultiGatewayRuntime.shared.routedEvents.removeValue(
            forKey: gatewayID) {
            subscription.gate?.retire()
            subscription.continuation?.finish()
            subscription.pump.cancel()
            await subscription.client.removeEventHandler(subscription.handlerID)
        }
    }

    // MARK: - The union roster

    /// Roster rows that live on a gateway other than the live one.
    ///
    /// Empty in demo mode: the canned world is not a gateway, and mixing real
    /// machines into it would make the demo lie about what is connected.
    var foreignRosterEntries: [ForeignRosterEntry] {
        guard !demoDataLoaded else { return [] }
        return ConnectionRegistry.shared.foreignRoster(activeProfiles: bots.map(\.id),
                                                       activeGatewayID: activeGatewayID)
    }

    /// The foreign half of `filterBots` (plugin.js:2963-2981).
    ///
    /// Desktop keeps thin remote rows in the SAME roster array it filters
    /// (plugin.js:2345-2357, 7668), so one query narrows both halves of the
    /// list at once — and the fourth match field exists precisely for this
    /// half: typing "homelab" lists every bot living on the Homelab
    /// connection (plugin.js:2974-2976). Talaria draws the two halves as two
    /// blocks, so the filter has to be applied twice; the rules are the same
    /// ones, out of `RosterSearch`.
    ///
    /// Order is untouched, as everywhere else search runs: the entries come
    /// back in `foreignRoster`'s gateway-then-recency order.
    ///
    /// Filtered through `rosterBot(for:)` — the row this half actually paints
    /// — and not through fields re-derived from the entry. Upstream's
    /// `filterBots` reads every one of its four fields off the same helpers
    /// that render the row (`displayName` at 2971, `botHandle` at 2973), thin
    /// remote rows included, so search and paint cannot drift apart. Doing the
    /// derivation twice here did drift: `rosterBot` resolves a bare-name entry
    /// through `Bot.handle`, so a foreign `default` PAINTS `@hermes` while the
    /// entry's own `handle` field still says "default" — and typing the handle
    /// printed on the row dropped it from the list.
    func foreignRosterEntries(matching needle: String) -> [ForeignRosterEntry] {
        guard !needle.isEmpty else { return foreignRosterEntries }
        return foreignRosterEntries.filter { rosterBot(for: $0).matchesRosterSearch(needle) }
    }

    /// Saved gateways that contributed nothing and why — a footnote the user
    /// can act on (sign in, or wake the machine), never a bare error.
    var foreignRosterProblems: [SecondaryRosterProblem] {
        guard !demoDataLoaded else { return [] }
        return ConnectionRegistry.shared.secondaryRosterProblems(activeGatewayID: activeGatewayID)
    }

    /// True when there is a second source worth drawing a divider for.
    var rosterSpansGateways: Bool {
        !foreignRosterEntries.isEmpty || !foreignRosterProblems.isEmpty
    }

    /// A foreign entry as a `Bot`, so it renders through the same avatar and
    /// identity path as every other row — desktop's thin `remoteSource` row
    /// (plugin.js:2348-2356), which it pushes into the SAME array as the live
    /// ones.
    ///
    /// The id is the source-qualified `botRosterKey` (plugin.js:2669), which
    /// cannot collide with a live profile id — that is the point. The bare
    /// name and the device label travel in `remoteSource` rather than being
    /// derived from that id, because nothing can be: `Bot.displayTitle` would
    /// de-slug "homelab::default" into "Homelab::default", and the resolver
    /// would register a form no @token can spell.
    func rosterBot(for entry: ForeignRosterEntry) -> Bot {
        // A bare-name entry keeps the plain rules (default → Hermes/@hermes);
        // a disambiguated one already carries its `name-device` form, which
        // desktop's botHandle() prefers verbatim (plugin.js:2406-2412).
        let plain = Bot.unlisted(id: entry.profile)
        let handle = entry.handle == entry.profile ? plain.handle : entry.handle
        return Bot(id: entry.id,
                   job: entry.job,
                   shape: entry.shape ?? BotCosmetics.derivedShape(forName: entry.profile),
                   hue: entry.hue ?? BotCosmetics.derivedHue(forName: entry.profile),
                   status: .idle,
                   preview: entry.preview,
                   previewTime: Self.shortTime(entry.lastActive),
                   unread: MultiGatewayRuntime.shared.routedUnread[
                    GatewayBotRoute(gatewayID: entry.gatewayID, profile: entry.profile)
                   ] ?? 0,
                   description: entry.job,
                   // The far gateway's `ui_meta` title, or nothing — never a
                   // stand-in derived here. `Bot.displayTitle` applies the
                   // rules itself, and a synthesised "Hermes" in this slot
                   // claimed a user-set title the profile does not have,
                   // which is what shadowed the remote-default rule
                   // (plugin.js:2941-2943) and left both machines' primary
                   // agents reading `Hermes` on one screen.
                   title: entry.title,
                   handleOverride: handle,
                   remoteSource: BotSource(profile: entry.profile,
                                           gatewayID: entry.gatewayID,
                                           connectionLabel: entry.connectionLabel),
                   rawDisplayName: entry.rawDisplayName)
    }

    // MARK: - The @name-device rule, applied to BOTH sides

    /// The live gateway's own rows, with the duplicate-name rule applied.
    ///
    /// This is desktop's annotate-in-place path (plugin.js:2331-2338), whose
    /// comment is the whole justification: "the @name-device handle only
    /// differs from the bare name when the profile exists on several sources".
    /// Upstream applies `agentHandle` to EVERY colliding identity, the active
    /// connection's included (connection-registry.ts:362-370), so a phone
    /// bound to "MacBook" that also has a saved "Homelab" carrying `default`
    /// shows `@default-macbook` here and `@default-homelab` there — not a bare
    /// `@hermes` on the near side, which is what Talaria drew before: the
    /// counting already included the live profiles, but only foreign rows were
    /// ever stamped with the result.
    ///
    /// Nothing is annotated when there is no duplicate, so the common
    /// single-gateway phone keeps `@hermes` and this is a cheap no-op.
    ///
    /// WITHOUT A LABEL THERE IS NO SUFFIX TO MINT. The label is taken from the
    /// saved gateway `activeGatewayID` names — deliberately that one, and not
    /// `activeConnectionLabel`, so the gateway whose label goes into the
    /// suffix is EXACTLY the gateway `foreignRoster` leaves out of the foreign
    /// half. Anything looser lets the live gateway appear on both sides during
    /// a connect or a switch, and mint the same handle twice — which the
    /// resolver would then poison, making a bot unaddressable from its own
    /// roster row.
    ///
    /// So there is no suffix until the socket is bound to a saved Connection.
    /// Slugging an absent label would mint `default-connection` (`labelSlug`'s
    /// fallback), a handle naming a machine that does not exist. The live row
    /// keeps its bare handle instead, and if a saved gateway claims the same
    /// name the resolver poisons the bare form between them: the row stays
    /// reachable only through a form nothing else claims (`@hermes`, for the
    /// primary profile) and not at all for any other name. That is the safe
    /// side of the coin the whole rule is built on — refuse rather than guess
    /// (plugin.js:2457-2466) — because the alternative is delivering to
    /// whichever machine happens to be live.
    var liveRosterBots: [Bot] {
        guard !demoDataLoaded, let liveID = activeGatewayID,
              let label = ConnectionRegistry.shared.saved.first(where: { $0.id == liveID })?.name
        else { return bots }
        let duplicated = ConnectionRegistry.shared
            .duplicatedProfileNames(activeProfiles: bots.map(\.id), activeGatewayID: liveID)
        guard !duplicated.isEmpty else { return bots }
        return bots.map { bot in
            let name = AgentHandle.profileName(bot.id)
            guard duplicated.contains(name) else { return bot }
            var annotated = bot
            annotated.handleOverride = AgentHandle.mint(profile: name,
                                                       connectionLabel: label,
                                                       duplicated: true)
            return annotated
        }
    }

    /// One roster across every configured Connection — `mergeMultiSourceRoster`'s
    /// output (plugin.js:2270-2398): annotated live rows first, then the thin
    /// foreign ones, in one array.
    ///
    /// The mention surfaces read THIS, not `bots`. Both halves have to meet in
    /// one array before the duplicate-name rule can do anything at all: the
    /// resolver's form map is where two `default` rows collide and poison the
    /// bare name (2457-2466), and the completion provider is where the
    /// `@name-device` form is offered in the first place. Reading `bots` alone
    /// left the minted handle rendering on the roster and addressable by
    /// nobody.
    ///
    /// The roster surface draws the two halves as sections with a source
    /// divider, while actions still route through this one identity domain.
    var unionRosterBots: [Bot] {
        liveRosterBots + foreignRosterEntries.map { rosterBot(for: $0) }
    }

    // MARK: - Refresh

    /// Top up every secondary gateway's roster. Cheap when nothing is due:
    /// the registry rate-limits per gateway and skips hosts the status probe
    /// just found asleep.
    func refreshUnionRoster() async {
        // The canned world shows no foreign rows, so dialling real machines
        // for an answer nothing renders is pure radio — and a demo that
        // silently reaches a homelab is not a demo.
        guard !demoDataLoaded else { return }
        let excluded: Set<String> = client != nil
            ? Set([LiveRuntime.shared.baseURL?.absoluteString].compactMap { $0 })
            : []
        await ConnectionRegistry.shared.enumerateSecondaryRosters(excluding: excluded)
        applySecondaryUnreadAnswers()
        await flushRoomMetadataOutbox()
    }

    /// One periodic enumeration pass may reconnect the pending route's foreign
    /// source without any foreground/NWPath transition. Coalesce the whole pass
    /// into one queue signal, and ignore successes from unrelated gateways.
    func exactStoredSessionSecondarySourcesDidRefresh(_ gatewayIDs: Set<String>) {
        guard let pending = exactStoredSessionRouteQueue.pending,
              gatewayIDs.contains(pending.route.gatewayID) else { return }
        retryExactStoredSessionNavigation()
    }

    /// Keep the union roster warm while the roster screen is on-stage. Driven
    /// by a SwiftUI `.task`, so it dies with the view rather than dialling
    /// other people's machines in the background forever.
    func superviseUnionRoster(every seconds: TimeInterval = 45) async {
        // The roster is the first screen the app paints, in a race with the
        // launch reconnect: at that instant nothing is live, so every saved
        // gateway — including the one about to become live — looks like a
        // secondary worth a probe socket. Letting the reconnect land first is
        // the same debounce `kickSecondaryEnumeration` takes, for the same
        // reason (`enumerate` re-checks at dial time for the slower case).
        try? await Task.sleep(for: .seconds(2))
        while !Task.isCancelled {
            await refreshUnionRoster()
            try? await Task.sleep(for: .seconds(seconds))
        }
    }

    // MARK: - Opening a bot on another gateway

    /// A switch is being performed — rows stay tappable but inert.
    var isSwitchingGateway: Bool {
        MultiGatewayRuntime.shared.switchingGatewayID != nil
    }

    /// Tapping a foreign row opens its source-qualified canonical chat while
    /// the primary app gateway stays in place. The connection and transcript
    /// attach happen asynchronously through the same openChat door as local
    /// bots, so failures render in that bot's chat instead of erasing the
    /// current world.
    func openForeignBot(_ entry: ForeignRosterEntry) async {
        hydrateForeignCanonicalPin(entry)
        if let pin = entry.canonicalChatID,
           let owner = try? await routedClient(gatewayID: entry.gatewayID) {
            // Prime only the client that enumerated/owns this profile. Sending
            // a qualified id or a foreign profile name to the primary is a
            // fork-by-collision bug, not a harmless cache miss.
            await owner.notePreferredSessions([entry.profile: pin])
        }
        openChat(botID: entry.id)
    }

    /// Bring the authenticated secondary roster's canonical identity into the
    /// source-qualified runtime before `openChat` starts resolution. A local
    /// pin still waiting for its server echo remains newer authority.
    func hydrateForeignCanonicalPin(_ entry: ForeignRosterEntry) {
        guard let pin = entry.canonicalChatID, !pin.isEmpty else { return }
        let runtime = CanonicalChatRuntime.shared
        guard !runtime.dirtyPins.contains(entry.id) else { return }
        runtime.pins[entry.id] = pin
        runtime.grandfatherCandidates[entry.id] = nil
    }

    /// Become a saved gateway, from a roster row rather than the Connections
    /// screen. Wraps `switchGateway` with the in-flight flag so a second tap
    /// during the teardown-and-redial cannot start a competing switch — the
    /// roster is a fast, thumb-sized surface and double taps are the norm.
    ///
    /// A gateway with no Keychain credential raises the re-auth banner from
    /// inside `switchGateway`; that IS the outcome, so there is nothing to
    /// report here.
    func becomeGateway(_ gateway: SavedGateway) async {
        let runtime = MultiGatewayRuntime.shared
        guard runtime.switchingGatewayID == nil else { return }
        runtime.switchingGatewayID = gateway.id
        defer { runtime.switchingGatewayID = nil }
        await switchGateway(to: gateway)
    }

    // Cosmetics for a profile we have only a name for live in
    // `BotCosmetics.derivedShape(forName:)` / `derivedHue(forName:)`, the same
    // last-resort the live roster uses — so a bot's face does not change the
    // instant the switch completes and the real row replaces the foreign one.
    // This file used to carry its own byte-identical copy of that hash.
}

// MARK: - Searching a foreign row
//
// There is no `ForeignRosterEntry.matchesRosterSearch`, and deliberately so.
// A thin remote row's side of `filterBots` (plugin.js:2970-2980) runs on the
// row, through the same identity helpers that painted it — see
// `foreignRosterEntries(matching:)`, which turns each entry into the `Bot` the
// list draws and calls `Bot.matchesRosterSearch`. That keeps the four match
// fields (display name, profile name, @handle, device label) pinned by
// `talaria-verify` in ONE place, on the type both halves of the union share.
//
// The id is the one thing neither side matches: it is `gatewayID::profile`
// (plugin.js:2669), and a needle that happened to fall inside a gateway id
// would silently match rows nothing on screen says it should. `profileName`
// is the field that carries the name a user can see and type.
