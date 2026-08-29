import Foundation
import Observation
import SwiftUI
import TalariaKit
import TalariaTheme

// ── Agent-to-agent: @mention identity and a live Agent Inbox ──────────────
//
// Bot Mode's current a2a contract has one client-owned job: resolve @handles
// against the cached union roster and tell the active agent which identities
// the user meant. Delivery belongs exclusively to Hermes' Bot-Chat-only
// `message_agent` tool; Talaria never forwards the user's draft to recipients.
// The inbox remains a read-only projection of attributed traffic. Ported from
// apps/desktop/src/plugins/hermes-bots/plugin.js:
//
//   botHandle                    2406        the @handle namespace
//   isActiveRosterBot            2414        "a bot never @s itself"
//   resolveRosterMentions        2434-2493   prose scan, form map, ambiguity
//   mention autocomplete         7996-8046   prefix-on-handle, cap 8
//   mention middleware           identification-only roster annotation
//
// Gateway shapes cited inline from tui_gateway/.

// MARK: - Policy

/// The tuned constants. Upstream's are ported verbatim except where a phone
/// radio makes a loopback cadence wrong; those carry their reason.
enum A2APolicy {
    /// plugin.js:2499 `REMOTE_DM_TIMEOUT_MS` — 3 minutes, verbatim. A teammate
    /// that has not answered in three minutes is not an error, it is busy.
    static let replyDeadline: Double = 180

    /// plugin.js:2500 `REMOTE_DM_POLL_MS` is 2 s over a loopback socket. Each
    /// poll here is a radio round trip, so the interval is doubled; the cheap
    /// probe below (`session.list`, a pure DB read) makes the extra latency
    /// invisible in practice — the expensive transcript read happens once,
    /// after the counter has already moved.
    static let replyPoll: Double = 4

    /// `sessions.changed` is the cross-process signal — a CLI handoff, a cron
    /// run or another machine writing state.db all move it (server.py:3678,
    /// `_sessions_sig`) — and the gateway already floors it to one broadcast
    /// per 2 s (server.py:3760). Debounce past that floor so the burst a
    /// single streaming turn produces collapses into one sweep.
    static let changeDebounce: Double = 2.5

    /// Safety net for traffic no event reaches us for: the change watcher
    /// stats the ACTIVE profile's home only (`_watcher_home`, server.py:3626),
    /// so a message written into another profile's state.db can be silent.
    static let idleSweep: Double = 90

    /// Outbound handoffs remembered for their delivery note. Older ones lose
    /// the note and become ordinary inbox rows.
    static let deliveryLimit = 60

    /// A sweep is N profiles × up to 2 transcripts; these caps are what keep
    /// it affordable on a phone.
    static let scanProfiles = 10
    static let scanSessionsPerProfile = 2
    static let scanMessages = 60
    static let feedLimit = 80
}

// MARK: - Runtime (side table)

/// What one outbound handoff is doing.
public struct A2ADelivery: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// Submitted; the reply watch is running.
        case waiting
        /// The recipient answered and the reply is in the feed.
        case replied
        /// The deadline passed with no reply. Not an error — it is in their
        /// chat, and the next sweep will find it.
        case quiet
        case failed(String)
    }

    public var to: String
    /// Exact gateway/profile that accepted this attempt. Nil only for legacy
    /// in-memory entries constructed by older tests/callers.
    public var route: GatewayBotRoute?
    /// The sender is part of the delivery's ownership too. A recipient route
    /// alone cannot tell a profile rename whether this watch belongs to the
    /// profile being renamed or to a sibling that merely shares its gateway.
    public var senderRoute: GatewayBotRoute?
    /// The roster spelling used by the sender at submit time. This is kept
    /// separately from `senderRoute` because primary rows are bare while
    /// retained secondary rows are source-qualified.
    public var senderRosterID: String?
    /// Submit-time fence metadata for an accepted prompt whose publication
    /// raced lifecycle. It is portable evidence, not permission to rearm.
    public var submitScopeGeneration: Int?
    public var submitTargetGeneration: UInt64?
    public var submitSenderGeneration: UInt64?
    public var submitClientID: ObjectIdentifier?
    public var requiresExplicitRearm: Bool
    /// One identity per submit attempt. Equal recipient/body pairs must not
    /// replace each other's watcher or delivery outcome.
    public var attemptID: UUID
    /// Stable body fingerprint used to reconnect transcript rows to the most
    /// recent matching attempt without making it the attempt identity.
    public var bodyHash: Int?
    /// The gateway parked this behind a turn that was already running. Kept
    /// after the reply lands, because it explains a slow answer.
    public var queuedBehindRun: Bool
    public var state: State
    public var at: Date

    public init(to: String, route: GatewayBotRoute? = nil,
                senderRoute: GatewayBotRoute? = nil, senderRosterID: String? = nil,
                submitScopeGeneration: Int? = nil,
                submitTargetGeneration: UInt64? = nil,
                submitSenderGeneration: UInt64? = nil,
                submitClientID: ObjectIdentifier? = nil,
                requiresExplicitRearm: Bool = false,
                attemptID: UUID = UUID(),
                bodyHash: Int? = nil, queuedBehindRun: Bool,
                state: State, at: Date) {
        self.to = to; self.route = route
        self.senderRoute = senderRoute; self.senderRosterID = senderRosterID
        self.submitScopeGeneration = submitScopeGeneration
        self.submitTargetGeneration = submitTargetGeneration
        self.submitSenderGeneration = submitSenderGeneration
        self.submitClientID = submitClientID
        self.requiresExplicitRearm = requiresExplicitRearm
        self.attemptID = attemptID
        self.bodyHash = bodyHash; self.queuedBehindRun = queuedBehindRun
        self.state = state; self.at = at
    }
}

/// A bot identity after roster resolution and before any wire work. Both the
/// UI identity and the exact gateway route travel together; no dispatch API
/// accepts a bare profile id.
struct A2AEndpoint: Sendable, Equatable {
    var rosterID: String
    var route: GatewayBotRoute
    var displayTitle: String
    var handle: String
    /// Sender-attribution form. Upstream derives this from the bare profile,
    /// not the source-annotated roster row (plugin.js:8298).
    var attributionHandle: String
    var connectionLabel: String?
}

/// Read-only compatibility parser for attribution markers written by older
/// Talaria builds. Current code never constructs or submits these messages;
/// retaining the parser lets the inbox project durable historical rows.
enum A2AWire {
    /// The attempt marker is deliberately anchored to the attribution line.
    /// A title/body can contain marker-looking text, but it cannot become the
    /// wire identity unless it is the terminal marker before the body colon.
    private static let attemptPrefixPattern =
        #"^Message from .*?\[Talaria handoff attempt ([0-9a-fA-F-]{36})\]:"#

    private static func unescapeMarkerValue(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    static func senderRoute(in attributed: String) -> GatewayBotRoute? {
        guard let attempt = attributed.range(
            of: attemptPrefixPattern, options: .regularExpression) else { return nil }
        guard let markerStart = attributed[..<attempt.upperBound].lastIndex(of: "[") else {
            return nil
        }
        let prefixText = String(attributed[..<markerStart])
        let sourcePattern = #"\[Talaria handoff source ([^\]]+)\]"#
        var range: Range<String.Index>?
        var searchStart = prefixText.startIndex
        while let candidate = prefixText.range(of: sourcePattern,
                                                options: .regularExpression,
                                                range: searchStart..<prefixText.endIndex) {
            range = candidate
            searchStart = candidate.upperBound
        }
        guard let range else { return nil }
        let marker = String(attributed[range])
        let prefix = "[Talaria handoff source "
        guard marker.hasPrefix(prefix), marker.hasSuffix("]") else { return nil }
        let qualified = unescapeMarkerValue(
            String(marker.dropFirst(prefix.count).dropLast()))
        return GatewayBotRoute(qualifiedID: qualified)
    }

    static func attemptID(in attributed: String) -> UUID? {
        guard let range = attributed.range(
            of: attemptPrefixPattern,
            options: .regularExpression) else { return nil }
        let marker = String(attributed[range])
        guard let markerStart = marker.lastIndex(of: "[") else { return nil }
        let attemptMarker = String(marker[markerStart...])
        guard let idRange = attemptMarker.range(
            of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#,
            options: .regularExpression) else { return nil }
        return UUID(uuidString: String(attemptMarker[idRange]))
    }

    /// Deterministic companion id for the assistant row belonging to an
    /// attempt. Distinct from its user row while surviving transcript rebuilds.
    static func replyID(for attemptID: UUID) -> UUID {
        var bytes = attemptID.uuid
        bytes.15 ^= 0x80
        return UUID(uuid: bytes)
    }
}

/// The two source-qualified identities a reply watch must retain. Keeping
/// this in the runtime, rather than only in a task closure, lets a committed
/// profile rename update the sender/recipient before the same watch relays its
/// answer. A deleted route simply removes the registration.
@MainActor
struct A2AWatcherRegistration: Equatable {
    var target: A2AEndpoint
    var sender: A2AEndpoint
    var targetGeneration: UInt64
    var senderGeneration: UInt64
    var paused = false
}

@MainActor
struct A2AOptimisticOwner: Equatable {
    var target: GatewayBotRoute
    var targetRosterID: String
    var sender: GatewayBotRoute
    var senderRosterID: String
}

enum A2AInboxMerge {
    static func source(of message: A2AMessage, ref: SessionRef?,
                       optimisticRows: [UUID: String],
                       primaryGatewayID: String?) -> String? {
        if let source = optimisticRows[message.id] { return source }
        if let source = ref?.gatewayID, !source.isEmpty { return source }
        if let route = GatewayBotRoute(qualifiedID: message.toBotID) { return route.gatewayID }
        if let route = GatewayBotRoute(qualifiedID: message.fromBotID) { return route.gatewayID }
        return primaryGatewayID
    }

    static func merge(existing: [A2AMessage], existingRefs: [UUID: SessionRef],
                      server: [(A2AMessage, Date, SessionRef)],
                      successfulGateways: Set<String>, optimisticRows: [UUID: String],
                      primaryGatewayID: String?, limit: Int)
        -> (messages: [A2AMessage], refs: [UUID: SessionRef], settled: Set<UUID>) {
        let serverOrdered = server.sorted { $0.1 > $1.1 }
        let serverIDs = Set(serverOrdered.map { $0.0.id })
        let preserved = existing.filter { message in
            guard let gatewayID = source(of: message, ref: existingRefs[message.id],
                                         optimisticRows: optimisticRows,
                                         primaryGatewayID: primaryGatewayID) else { return true }
            if !successfulGateways.contains(gatewayID) { return true }
            return optimisticRows[message.id] != nil && !serverIDs.contains(message.id)
        }
        var seen: Set<UUID> = []
        let messages = Array((preserved + serverOrdered.map(\.0))
            .filter { seen.insert($0.id).inserted }.prefix(limit))
        var refs = existingRefs.filter { id, _ in
            preserved.contains(where: { $0.id == id })
        }
        for entry in serverOrdered { refs[entry.0.id] = entry.2 }
        let visibleIDs = Set(messages.map(\.id))
        refs = refs.filter { visibleIDs.contains($0.key) }
        return (messages, refs, serverIDs)
    }
}

/// Book-keeping the a2a surfaces need. `AppModel`'s stored properties live in
/// AppModel.swift (another owner) and extensions cannot add storage, so this
/// rides in a MainActor singleton like `FeedsRuntime` and `LiveRuntime` do.
@MainActor
@Observable
final class A2ARuntime {
    static let shared = A2ARuntime()

    /// Handoffs this app sent, keyed by source-qualified recipient + body hash
    /// + attempt UUID. A rebuilt transcript row has a fresh UUID, so lookup can
    /// fall back to its qualified recipient/body while live optimistic rows
    /// retain exact attempt identity.
    var deliveries: [String: A2ADelivery] = [:]

    @ObservationIgnored var watchers: [String: Task<Void, Never>] = [:]
    /// Bumped every time a watch is (re)started for a key. A cancelled watch
    /// finishes asynchronously, so it must not tidy up after the watch that
    /// replaced it.
    @ObservationIgnored var watcherGeneration: [String: Int] = [:]
    /// Gateway owning each live watcher, including the interval between submit
    /// and delivery-table publication. Enables exact-source detach.
    @ObservationIgnored var watcherScopes: [String: String] = [:]
    /// Invalidates a task even when cancellation races an RPC already in flight.
    @ObservationIgnored var scopeGenerations: [String: Int] = [:]
    /// Profile-route generations are narrower than `scopeGenerations`: a
    /// secondary gateway can retain several profiles, and renaming/deleting
    /// one must not invalidate a sibling's retained legacy delivery cleanup.
    @ObservationIgnored var routeGenerations: [GatewayBotRoute: UInt64] = [:]
    /// Reply-watch ownership is mutable across a committed rename. The task
    /// reads this registration after each network await, so its captured
    /// sender/recipient cannot relay into a retired bare or qualified id.
    @ObservationIgnored var watcherRegistrations: [String: A2AWatcherRegistration] = [:]
    /// Optimistic rows that a sweep must retain until the exact anchored rows
    /// appear in the owning gateway's transcript.
    @ObservationIgnored var optimisticRows: [UUID: String] = [:]
    @ObservationIgnored var optimisticOwners: [UUID: A2AOptimisticOwner] = [:]
    @ObservationIgnored var pendingRearms: Set<String> = []
    /// A rename fences a watch while Hermes moves the profile directory. The
    /// task remains retained so the commit hook can migrate it in place; a
    /// delete removes it instead. This set is intentionally route-qualified.
    @ObservationIgnored var pausedRoutes: Set<GatewayBotRoute> = []
    /// Profile lifecycle parks this exact route before a primary disconnect;
    /// reset(gatewayID:) must not mistake that deliberate teardown for a
    /// request to erase its portable handoff/watch state.
    @ObservationIgnored var routesPreservedAcrossGatewayReset: Set<GatewayBotRoute> = []
    /// Restore hooks can run while the lifecycle exclusive lease still fences
    /// ordinary traffic. Keep the rearm pending instead of unpausing a route
    /// that cannot yet reacquire its client.
    @ObservationIgnored var deferredRestores: [GatewayBotRoute: Set<String>] = [:]
    @ObservationIgnored var deferredRestoreTasks: [GatewayBotRoute: Task<Void, Never>] = [:]
    @ObservationIgnored var eventToken: UUID?
    /// addEpochEventHandler is asynchronous; a late token from a departing client
    /// must not replace the subscription installed for its successor.
    @ObservationIgnored var eventClient: ObjectIdentifier?
    @ObservationIgnored var eventGeneration: UInt64 = 0
    /// Which gateway the state above belongs to; a swap owns none of it.
    @ObservationIgnored var routedClient: ObjectIdentifier?
    @ObservationIgnored var inboxGatewayID: String?
    @ObservationIgnored var attachTask: Task<Void, Never>?
    @ObservationIgnored var sweepDebounce: Task<Void, Never>?
    @ObservationIgnored var idlePoll: Task<Void, Never>?
    /// Screens currently showing the inbox. Events keep arriving when it is
    /// zero; sweeping for a screen nobody is looking at is just radio.
    @ObservationIgnored var viewers = 0
    /// Invalidates an inbox sweep still awaiting a profile during reset.
    @ObservationIgnored var inboxSweepGeneration: UInt64 = 0

    func routeGeneration(for route: GatewayBotRoute) -> UInt64 {
        routeGenerations[route, default: 0]
    }

    func accepts(route: GatewayBotRoute, generation: UInt64) -> Bool {
        routeGenerations[route, default: 0] == generation
            && !pausedRoutes.contains(route)
    }

    /// Invalidate one exact profile route without disturbing siblings on the
    /// same gateway. The caller may preserve accepted delivery state for a
    /// rename; it is then paused until `migrateProfileRoute` or
    /// `restoreProfileRoute` supplies a new owner.
    func retireProfileRoute(_ route: GatewayBotRoute,
                            sourceBotIDs: Set<String>,
                            preserveForRename: Bool = false) {
        routeGenerations[route, default: 0] &+= 1
        pausedRoutes.insert(route)
        deferredRestoreTasks.removeValue(forKey: route)?.cancel()
        deferredRestores.removeValue(forKey: route)

        var keys = Set(deliveries.compactMap { key, delivery in
            let ownsRecipient = delivery.route == route
                || delivery.to == route.qualifiedID
                || sourceBotIDs.contains(delivery.to)
            let ownsSender = delivery.senderRoute == route
                || delivery.senderRosterID.map(sourceBotIDs.contains) == true
            return ownsRecipient || ownsSender ? key : nil
        }).union(watcherRegistrations.compactMap { key, registration in
            let ownsRecipient = registration.target.route == route
                || sourceBotIDs.contains(registration.target.rosterID)
            let ownsSender = registration.sender.route == route
                || sourceBotIDs.contains(registration.sender.rosterID)
            return ownsRecipient || ownsSender ? key : nil
        })
        // Older callers may have installed a primary watch before sender
        // ownership was recorded. A bare primary cannot prove which profile
        // owns such a closure, so retire those legacy watches rather than let
        // them relay into a replacement profile. New watches always carry a
        // registration and are migrated above.
        let barePrimary = sourceBotIDs.contains(route.profile)
        let legacyWatchers = barePrimary
            ? Set(watchers.keys.filter { watcherRegistrations[$0] == nil }) : []
        let legacyDeliveries = barePrimary
            ? Set(deliveries.compactMap { key, delivery in
                delivery.senderRoute == nil && delivery.route != route ? key : nil
            }) : []
        let retireLegacy: (String) -> Void = { key in
            self.watchers.removeValue(forKey: key)?.cancel()
            self.watcherGeneration.removeValue(forKey: key)
            self.watcherScopes.removeValue(forKey: key)
            self.watcherRegistrations.removeValue(forKey: key)
            if let delivery = self.deliveries.removeValue(forKey: key) {
                self.optimisticRows.removeValue(forKey: delivery.attemptID)
                self.optimisticOwners.removeValue(forKey: delivery.attemptID)
            }
        }

        if preserveForRename {
            for key in keys {
                watcherRegistrations[key]?.paused = true
                if watcherRegistrations[key] == nil { retireLegacy(key) }
            }
            for key in legacyWatchers.union(legacyDeliveries) { retireLegacy(key) }
            // Keep accepted delivery records and optimistic rows. They are
            // portable state and are migrated after Hermes confirms the name.
            return
        }
        keys.formUnion(legacyWatchers)
        keys.formUnion(legacyDeliveries)

        for key in keys {
            watchers.removeValue(forKey: key)?.cancel()
            watcherGeneration.removeValue(forKey: key)
            watcherScopes.removeValue(forKey: key)
            watcherRegistrations.removeValue(forKey: key)
            if let delivery = deliveries.removeValue(forKey: key) {
                optimisticRows.removeValue(forKey: delivery.attemptID)
                optimisticOwners.removeValue(forKey: delivery.attemptID)
            }
        }
        let optimistic = optimisticOwners.compactMap { id, owner in
            let ownsRecipient = owner.target == route
                || sourceBotIDs.contains(owner.targetRosterID)
            let ownsSender = owner.sender == route
                || sourceBotIDs.contains(owner.senderRosterID)
            return ownsRecipient || ownsSender ? id : nil
        }
        for id in optimistic {
            optimisticOwners.removeValue(forKey: id)
            optimisticRows.removeValue(forKey: id)
        }
    }

    /// A successful explicit profile create/recreate re-authorizes a route
    /// that a prior delete permanently retired. Bump once more so no task
    /// captured before the new directory existed can publish into it.
    func activateProfileRoute(_ route: GatewayBotRoute) {
        deferredRestoreTasks.removeValue(forKey: route)?.cancel()
        deferredRestores.removeValue(forKey: route)
        routeGenerations[route, default: 0] &+= 1
        pausedRoutes.remove(route)
    }

    /// Restore a refused rename. Canonical opens were intentionally retired;
    /// only accepted deliveries/watchers are unpaused and allowed to continue
    /// against the original source route.
    func restoreProfileRoute(_ route: GatewayBotRoute, sourceBotIDs: Set<String>) {
        guard ProfileLifecycleTrafficAdmission.allows(route.gatewayID) else {
            deferredRestores[route, default: []].formUnion(sourceBotIDs)
            if deferredRestoreTasks[route] == nil {
                deferredRestoreTasks[route] = Task { @MainActor [weak self] in
                    while !Task.isCancelled,
                          !ProfileLifecycleTrafficAdmission.allows(route.gatewayID) {
                        try? await Task.sleep(for: .milliseconds(25))
                    }
                    guard let self, !Task.isCancelled,
                          ProfileLifecycleTrafficAdmission.allows(route.gatewayID) else { return }
                    let ids = self.deferredRestores.removeValue(forKey: route) ?? []
                    self.deferredRestoreTasks[route] = nil
                    self.restoreProfileRoute(route, sourceBotIDs: ids)
                }
            }
            return
        }
        deferredRestores.removeValue(forKey: route)
        deferredRestoreTasks.removeValue(forKey: route)
        routeGenerations[route, default: 0] &+= 1
        pausedRoutes.remove(route)
        for key in watcherRegistrations.keys {
            guard var registration = watcherRegistrations[key] else { continue }
            let owns = registration.target.route == route
                || registration.sender.route == route
                || sourceBotIDs.contains(registration.target.rosterID)
                || sourceBotIDs.contains(registration.sender.rosterID)
            guard owns else { continue }
            if registration.target.route == route {
                registration.targetGeneration = routeGeneration(for: route)
            }
            if registration.sender.route == route {
                registration.senderGeneration = routeGeneration(for: route)
            }
            registration.paused = false
            watcherRegistrations[key] = registration
            pendingRearms.remove(key)
        }

        for key in deliveries.keys {
            guard var delivery = deliveries[key],
                  delivery.route == route || delivery.senderRoute == route else { continue }
            delivery.requiresExplicitRearm = false
            deliveries[key] = delivery
            pendingRearms.remove(key)
        }
    }

    /// Re-key accepted delivery/watch state after a committed profile rename.
    /// The old route remains fenced forever; all mutable watcher ownership is
    /// moved to the destination before ordinary traffic is released.
    func migrateProfileRoute(from source: GatewayBotRoute,
                             to destination: GatewayBotRoute,
                             sourceBotIDs: Set<String>,
                             destinationBotID: String) {
        guard source != destination else {
            restoreProfileRoute(source, sourceBotIDs: sourceBotIDs)
            return
        }
        routeGenerations[source, default: 0] &+= 1
        routeGenerations[destination, default: 0] &+= 1
        // Keep the old route permanently fenced. Only the destination may
        // accept a late completion after a committed rename.
        pausedRoutes.insert(source)
        pausedRoutes.remove(destination)

        for key in deliveries.keys {
            guard var delivery = deliveries[key] else { continue }
            var changed = false
            if delivery.route == source {
                delivery.route = destination
                delivery.to = destinationBotID
                changed = true
            }
            if delivery.senderRoute == source {
                delivery.senderRoute = destination
                delivery.senderRosterID = destinationBotID
                changed = true
            }
            if changed { deliveries[key] = delivery }
            if changed {
                delivery.requiresExplicitRearm = false
                deliveries[key] = delivery
                pendingRearms.remove(key)
            }
        }

        for key in watcherRegistrations.keys {
            guard var registration = watcherRegistrations[key] else { continue }
            var changed = false
            if registration.target.route == source {
                registration.target.route = destination
                registration.target.rosterID = destinationBotID
                registration.targetGeneration = routeGeneration(for: destination)
                changed = true
            }
            if registration.sender.route == source {
                registration.sender.route = destination
                registration.sender.rosterID = destinationBotID
                registration.senderGeneration = routeGeneration(for: destination)
                changed = true
            }
            if changed {
                registration.paused = false
                watcherRegistrations[key] = registration
                pendingRearms.remove(key)
            }
        }

        for id in optimisticOwners.keys {
            guard var owner = optimisticOwners[id] else { continue }
            if owner.target == source {
                owner.target = destination
                owner.targetRosterID = destinationBotID
            }
            if owner.sender == source {
                owner.sender = destination
                owner.senderRosterID = destinationBotID
            }
            optimisticOwners[id] = owner
        }
    }

    func preserveRouteAcrossGatewayReset(_ route: GatewayBotRoute) {
        routesPreservedAcrossGatewayReset.insert(route)
    }

    func reset() {
        let gateways = Set(watcherScopes.values)
            .union(deliveries.values.compactMap { $0.route?.gatewayID })
        for gatewayID in gateways { scopeGenerations[gatewayID, default: 0] += 1 }
        let routes = Set(routeGenerations.keys)
            .union(deliveries.values.compactMap { $0.route })
            .union(deliveries.values.compactMap { $0.senderRoute })
            .union(watcherRegistrations.values.flatMap { [$0.target.route, $0.sender.route] })
        for route in routes { routeGenerations[route, default: 0] &+= 1 }
        inboxSweepGeneration &+= 1
        deliveries.removeAll()
        for task in watchers.values { task.cancel() }
        watchers.removeAll()
        watcherGeneration.removeAll()
        watcherScopes.removeAll()
        watcherRegistrations.removeAll()
        pendingRearms.removeAll()
        optimisticRows.removeAll()
        optimisticOwners.removeAll()
        pausedRoutes.removeAll()
        routesPreservedAcrossGatewayReset.removeAll()
        for task in deferredRestoreTasks.values { task.cancel() }
        deferredRestoreTasks.removeAll()
        deferredRestores.removeAll()
        sweepDebounce?.cancel(); sweepDebounce = nil
        idlePoll?.cancel(); idlePoll = nil
        eventToken = nil
        eventClient = nil
        eventGeneration &+= 1
        inboxGatewayID = nil
    }

    /// Surrender only one retained gateway. Other gateway reply watches keep
    /// their captured client/session and continue independently.
    func reset(gatewayID: String) {
        scopeGenerations[gatewayID, default: 0] += 1
        for route in Array(deferredRestoreTasks.keys) where route.gatewayID == gatewayID {
            deferredRestoreTasks.removeValue(forKey: route)?.cancel()
            deferredRestores.removeValue(forKey: route)
        }
        if inboxGatewayID == gatewayID {
            eventGeneration &+= 1
            eventToken = nil
            eventClient = nil
        }
        let preservedRoutes = routesPreservedAcrossGatewayReset.filter {
            $0.gatewayID == gatewayID
        }
        let routes = Set(routeGenerations.keys.filter {
            $0.gatewayID == gatewayID && !preservedRoutes.contains($0)
        })
            .union(deliveries.values.compactMap { $0.route }.filter { $0.gatewayID == gatewayID })
            .union(deliveries.values.compactMap { $0.senderRoute }.filter { $0.gatewayID == gatewayID })
            .union(watcherRegistrations.values.flatMap { [$0.target.route, $0.sender.route] }
                .filter { $0.gatewayID == gatewayID })
        for route in routes { routeGenerations[route, default: 0] &+= 1 }
        inboxSweepGeneration &+= 1
        let keys: Set<String> = Set(deliveries.compactMap { key, delivery in
            let preserved = delivery.route.map { preservedRoutes.contains($0) } == true
                || delivery.senderRoute.map { preservedRoutes.contains($0) } == true
            if preserved { return nil }
            return delivery.route?.gatewayID == gatewayID
                || delivery.senderRoute?.gatewayID == gatewayID
                || GatewayBotRoute(qualifiedID: delivery.to)?.gatewayID == gatewayID ? key : nil
        }).union(watcherScopes.compactMap { key, value in
            guard value == gatewayID else { return nil }
            guard let registration = watcherRegistrations[key] else { return key }
            return preservedRoutes.contains(registration.target.route)
                || preservedRoutes.contains(registration.sender.route) ? nil : key
        })
            .union(watcherRegistrations.compactMap { key, registration in
                if preservedRoutes.contains(registration.target.route)
                    || preservedRoutes.contains(registration.sender.route) { return nil }
                return registration.target.route.gatewayID == gatewayID
                    || registration.sender.route.gatewayID == gatewayID ? key : nil
            })
        for key in keys {
            watchers.removeValue(forKey: key)?.cancel()
            watcherGeneration.removeValue(forKey: key)
            watcherScopes.removeValue(forKey: key)
            watcherRegistrations.removeValue(forKey: key)
            pendingRearms.remove(key)
            if let delivery = deliveries.removeValue(forKey: key) {
                optimisticRows.removeValue(forKey: delivery.attemptID)
                optimisticOwners.removeValue(forKey: delivery.attemptID)
            }
        }
        let preservedAttempts = Set(deliveries.values.compactMap { delivery in
            delivery.route.map { preservedRoutes.contains($0) } == true
                || delivery.senderRoute.map { preservedRoutes.contains($0) } == true
                ? delivery.attemptID : nil
        })
        optimisticRows = optimisticRows.filter {
            $0.value != gatewayID || preservedAttempts.contains($0.key)
        }
        optimisticOwners = optimisticOwners.filter {
            ( $0.value.target.gatewayID != gatewayID
                && $0.value.sender.gatewayID != gatewayID )
                || preservedAttempts.contains($0.key)
        }
        pausedRoutes = Set(pausedRoutes.filter {
            $0.gatewayID != gatewayID || preservedRoutes.contains($0)
        })
        routesPreservedAcrossGatewayReset.subtract(preservedRoutes)
    }

    /// Keep the note table bounded; oldest deliveries lose their note first.
    func prune() {
        guard deliveries.count > A2APolicy.deliveryLimit else { return }
        let doomed = deliveries.sorted { $0.value.at < $1.value.at }
            .prefix(deliveries.count - A2APolicy.deliveryLimit)
        for (key, _) in doomed {
            if let delivery = deliveries[key] {
                optimisticRows.removeValue(forKey: delivery.attemptID)
                optimisticOwners.removeValue(forKey: delivery.attemptID)
            }
            deliveries.removeValue(forKey: key)
            watchers.removeValue(forKey: key)?.cancel()
            watcherGeneration.removeValue(forKey: key)
            watcherScopes.removeValue(forKey: key)
            watcherRegistrations.removeValue(forKey: key)
        }
    }
}

// MARK: - Mention grammar (plugin.js:2434-2497)

// `BotMention`, `MentionResolution`, `MentionResolver`, `MentionSuggestion`
// and `MentionMiddleware` live in TalariaKit/BotMention.swift — they are pure,
// three surfaces share them, and `talaria-verify` links TalariaKit alone, so
// that is the only place their rules can be pinned by ProtocolChecks. What
// stays here is the cached union roster plus bounded read-only compatibility
// state for projecting and retiring rows accepted by older Talaria builds.

// MARK: - Resolving mentions against the roster

public extension AppModel {

    /// Resolve @handles in a draft against the union roster
    /// (`MentionResolver`, plugin.js:2434-2497). The roster is the only thing
    /// this side supplies; every rule is the shared one.
    ///
    /// `unionRosterBots`, not `bots`: upstream resolves against the whole
    /// merged roster (8252-8256 reads the cached `profiles`, which
    /// `mergeMultiSourceRoster` has already unioned), and that is what makes
    /// the duplicate-name rule fire. Two `default` rows from two gateways
    /// poison the bare form between them, so `@default` refuses and only
    /// `@default-macbook` / `@default-homelab` resolve.
    func resolveMentions(in text: String, speaking speaker: String?) -> MentionResolution {
        MentionResolver.resolve(text, roster: unionRosterBots, speaking: speaker)
    }

    /// The @-autocomplete provider (plugin.js:8006-8043). Every rule is the
    /// shared one; the roster and the device it lives on are what this side
    /// supplies.
    ///
    /// Same union roster as the resolver, for the same reason plus one more:
    /// a `@name-device` handle that cannot be completed cannot be discovered,
    /// and it is not a form anyone guesses. The meta line is what keeps the
    /// two apart on screen — `Bot · Hermes · MacBook` above
    /// `Bot · Homelab · Homelab`, the far row naming itself by the machine it
    /// lives on in both slots (`displayName` rule 1, plugin.js:2941-2943).
    ///
    /// The label passed here is the live gateway's, because those rows all
    /// came off it — desktop stamps `connectionLabel` onto each row it merges
    /// from a source and reads it back out for the meta line (plugin.js:2337,
    /// 8034); foreign rows carry their own and override it. It is nil until
    /// the socket is bound to a saved Connection, and the meta line then reads
    /// `Bot · <name>` with no tail, which is the no-label shape upstream
    /// renders too.
    func mentionSuggestions(for query: String, speaking speaker: String?) -> [MentionSuggestion] {
        unionRosterBots.mentionSuggestions(for: query, speaking: speaker,
                                           connectionLabel: activeConnectionLabel)
    }

    /// The delivery note for an inbox row, when this app is the one that sent
    /// it. Transcript rows do not carry Talaria's attempt UUID, so choose the
    /// newest matching source-qualified recipient/body attempt after a rebuild.
    func delivery(for message: A2AMessage) -> A2ADelivery? {
        let hash = Self.stableHash(message.text)
        if let exact = A2ARuntime.shared.deliveries.values.first(where: {
            $0.attemptID == message.id
        }) { return exact }
        return A2ARuntime.shared.deliveries.values
            .filter { delivery in
                delivery.to == message.toBotID && (delivery.bodyHash ?? hash) == hash
            }
            .max(by: { $0.at < $1.at })
    }

    /// Legacy deterministic spelling retained for lifecycle tests and entries
    /// created before attempt-qualified delivery keys. New dispatch uses the
    /// route + UUID overload below.
    static func deliveryKey(to: String, body: String) -> String {
        "\(to.lowercased())|\(stableHash(body))"
    }

    /// Exact source + body fingerprint + attempt UUID. Profile, body and even
    /// runtime/stored session ids are allowed to collide across gateways and
    /// repeat submissions; none can replace another attempt's state.
    static func deliveryKey(route: GatewayBotRoute, body: String, attemptID: UUID) -> String {
        "\(route.gatewayID.count):\(route.gatewayID)|\(route.profile.count):\(route.profile)"
            + "|\(stableHash(body))|\(attemptID.uuidString.lowercased())"
    }

    /// Turn one union-roster row into a dispatch endpoint. Foreign rows already
    /// carry their source; local rows are scoped to the current primary.
    internal func a2aEndpoint(for bot: Bot) -> A2AEndpoint? {
        let route: GatewayBotRoute
        if let source = bot.remoteSource {
            route = GatewayBotRoute(gatewayID: source.gatewayID, profile: source.profile)
        } else {
            guard let activeGatewayID else { return nil }
            route = GatewayBotRoute(gatewayID: activeGatewayID, profile: bot.profileName)
        }
        return A2AEndpoint(rosterID: bot.id, route: route,
                           displayTitle: bot.displayTitle, handle: bot.handle,
                           attributionHandle: Bot.unlisted(id: route.profile).handle,
                           connectionLabel: bot.remoteSource?.connectionLabel
                               ?? (route.gatewayID == activeGatewayID ? activeConnectionLabel : nil))
    }

    internal func a2aEndpoint(forRosterID rosterID: String) -> A2AEndpoint? {
        if let bot = unionRosterBots.first(where: { $0.id == rosterID }) {
            return a2aEndpoint(for: bot)
        }
        guard let route = gatewayRoute(for: rosterID) else { return nil }
        let bot = identity(rosterID)
        let label = ConnectionRegistry.shared.saved.first(where: { $0.id == route.gatewayID })?.name
        return A2AEndpoint(rosterID: rosterID, route: route,
                           displayTitle: bot.displayTitle, handle: bot.handle,
                           attributionHandle: Bot.unlisted(id: route.profile).handle,
                           connectionLabel: label)
    }
}

// MARK: - Liveness

public extension AppModel {

    /// The inbox is on screen: sweep now, follow the gateway's change signal,
    /// and keep a slow poll behind it.
    ///
    /// Desktop gets this for free from a 5 s roster poll it runs anyway
    /// (plugin.js:2218). Talaria's inbox is a transcript scan across profiles
    /// — far too expensive to run on a timer — so it is event-first: the
    /// gateway's `sessions.changed` fires on any state.db write, INCLUDING the
    /// ones other processes make (a CLI handoff, a cron run, the laptop), and
    /// the idle poll only covers what the watcher cannot see.
    func beginInboxLive() {
        A2ARuntime.shared.viewers += 1
        armInboxAttach()
    }

    /// Surrender everything this surface registered on the departing gateway.
    ///
    /// Every piece of a2a state names one gateway: its `sessions.changed`
    /// subscription, source-qualified delivery notes, and reply watches holding
    /// that source's client/session. Teardown cancels only the captured primary;
    /// retained secondary watches continue on their own clients. Called from
    /// `dropPerGatewayCaches`, the hook both ways out of a primary link use.
    func detachA2ARouter(departingGatewayID capturedGatewayID: String? = nil) {
        let runtime = A2ARuntime.shared
        let departing = client.map(ObjectIdentifier.init)
        let departingGatewayID = capturedGatewayID ?? activeGatewayID
            ?? LiveRuntime.shared.gatewayID
        // While the departing client is still around to surrender it to.
        if let token = runtime.eventToken, let client {
            Task { await client.removeEventHandler(token) }
        }
        runtime.attachTask?.cancel(); runtime.attachTask = nil
        if let departingGatewayID {
            dropA2AScope(gatewayID: departingGatewayID, wasPrimary: true)
        } else {
            runtime.reset()
        }
        runtime.routedClient = nil
        runtime.inboxGatewayID = nil
        FeedsRuntime.shared.lastInboxScan = nil
        // The inbox may be the screen the user is looking at while the switch
        // happens; it re-attaches itself to the incoming gateway rather than
        // sitting empty until they navigate away and back.
        armInboxAttach(avoiding: departing)
    }

    /// Drop one retained gateway's handoff attempts without disturbing any
    /// other source. `detachRoutedEvents(gatewayID:)` calls this when a pooled
    /// secondary is retired; the primary detach path above uses the same hook.
    func dropA2AScope(gatewayID: String, wasPrimary: Bool = false) {
        let a2a = A2ARuntime.shared
        let inboxRefs = FeedsRuntime.shared.inboxSessions
        // A primary profile rename marks its exact route portable before the
        // disconnect path reaches this gateway-wide scrub. Keep those rows
        // visible; reset(gatewayID:) will preserve the matching deliveries
        // and watchers for postcondition migration.
        let preservedRoutes = a2a.routesPreservedAcrossGatewayReset.filter {
            $0.gatewayID == gatewayID
        }
        let preservedOptimisticIDs = Set(a2a.deliveries.values.compactMap { delivery in
            delivery.route.map { preservedRoutes.contains($0) } == true
                || delivery.senderRoute.map { preservedRoutes.contains($0) } == true
                ? delivery.attemptID : nil
        })
        let ownedInboxIDs = Set(inboxRefs.compactMap {
            id, ref in ref.gatewayID == gatewayID ? id : nil
        }).subtracting(preservedOptimisticIDs)
        // Optimistic rows can be visible before the next transcript sweep and
        // therefore have no SessionRef yet. Use the exact delivery/source
        // owner first, including replies from a remote target into a departing
        // bare primary sender.
        let ownedOptimisticIDs = Set(a2a.optimisticRows.compactMap {
            id, sourceGateway in sourceGateway == gatewayID ? id : nil
        }).union(a2a.optimisticOwners.compactMap { id, owner in
            owner.sender.gatewayID == gatewayID || owner.target.gatewayID == gatewayID
                ? id : nil
        }).union(a2a.deliveries.values.compactMap { delivery in
            delivery.senderRoute?.gatewayID == gatewayID || delivery.route?.gatewayID == gatewayID
                ? delivery.attemptID : nil
        }).subtracting(preservedOptimisticIDs)
        A2ARuntime.shared.reset(gatewayID: gatewayID)
        let prefix = gatewayID + GatewayBotRoute.separator
        agentInbox.removeAll { message in
            !preservedOptimisticIDs.contains(message.id)
                && (ownedInboxIDs.contains(message.id) || ownedOptimisticIDs.contains(message.id)
                    || message.fromBotID.hasPrefix(prefix) || message.toBotID.hasPrefix(prefix)
                    || (wasPrimary
                        && GatewayBotRoute(qualifiedID: message.fromBotID) == nil
                        && GatewayBotRoute(qualifiedID: message.toBotID) == nil
                        && (inboxRefs[message.id].map { $0.gatewayID == gatewayID } ?? true)))
        }
        FeedsRuntime.shared.inboxSessions = FeedsRuntime.shared.inboxSessions.filter { _, ref in
            ref.gatewayID != gatewayID
        }
        FeedsRuntime.shared.lastInboxScan = nil
    }

    /// The inbox left the screen. Reply watches deliberately outlive it — a
    /// handoff sent from here is still owed an answer, and the answer lands in
    /// the activity ledger whichever tab the user is on.
    func endInboxLive() {
        let runtime = A2ARuntime.shared
        runtime.viewers = max(0, runtime.viewers - 1)
        guard runtime.viewers == 0 else { return }
        runtime.attachTask?.cancel(); runtime.attachTask = nil
        runtime.sweepDebounce?.cancel(); runtime.sweepDebounce = nil
        runtime.idlePoll?.cancel(); runtime.idlePoll = nil
    }

    /// Rebuild the feed, coalescing a burst of change events into one scan.
    func sweepInbox(after delay: Double) {
        let runtime = A2ARuntime.shared
        runtime.sweepDebounce?.cancel()
        runtime.sweepDebounce = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            await self.refreshInboxLive()
            if !Task.isCancelled { A2ARuntime.shared.sweepDebounce = nil }
        }
    }

    /// Primary and retained-secondary session signals share one federated
    /// sweep. The source is carried by the caller even though the merge itself
    /// refreshes every eligible source.
    func routeA2AChange(_ event: GatewayEvent, sourceGatewayID: String?) {
        guard mode == .live, A2ARuntime.shared.viewers > 0 else { return }
        guard case .changed(let what) = TypedGatewayEvent(event),
              what == "sessions.changed" else { return }
        _ = sourceGatewayID
        sweepInbox(after: A2APolicy.changeDebounce)
    }

    /// One sweep: every profile's own a2a conversation, split back into
    /// attributed rows.
    ///
    /// The session a profile receives handoffs in is its CANONICAL chat — the
    /// `-c "Bot Chat"` the CLI recipe names (plugin.js:8307) and the one
    /// `ensureRemoteCanonicalChat` resolves (2506). So the pin is read first
    /// and the title match is the fallback, in that order: a bot whose forever
    /// chat was grandfathered from an older conversation has a pin but no
    /// session called "Bot Chat", and scanning by title alone would show none
    /// of its traffic — including handoffs sent from this phone, which land
    /// wherever the pin points.
    func refreshInboxLive() async {
        guard mode == .live else { return }
        let endpoints = unionRosterBots.compactMap(a2aEndpoint(for:))
        guard !endpoints.isEmpty else { return }
        let runtime = FeedsRuntime.shared
        guard !runtime.inboxScanning else { return }
        runtime.inboxScanning = true
        defer { runtime.inboxScanning = false; runtime.lastInboxScan = Date() }

        var collected: [(A2AMessage, Date, SessionRef)] = []
        let a2aRuntime = A2ARuntime.shared
        let sweepGeneration = a2aRuntime.inboxSweepGeneration
        var routeGenerations: [GatewayBotRoute: UInt64] = [:]
        var scanned = 0
        var completedProfiles: [String: Int] = [:]
        var failedGateways: Set<String> = []
        let selected = Array(endpoints.prefix(A2APolicy.scanProfiles))
        let totalProfiles = Dictionary(grouping: endpoints, by: { $0.route.gatewayID })
            .mapValues(\.count)
        let selectedProfiles = Dictionary(grouping: selected, by: { $0.route.gatewayID })
            .mapValues(\.count)
        for (gatewayID, count) in totalProfiles
        where selectedProfiles[gatewayID, default: 0] < count {
            // A capped partial source cannot authoritatively replace rows from
            // profiles this sweep did not inspect.
            failedGateways.insert(gatewayID)
        }

        for endpoint in selected {
            guard !Task.isCancelled else { return }
            let route = endpoint.route
            let routeGeneration = A2ARuntime.shared.routeGeneration(for: route)
            routeGenerations[route] = routeGeneration
            guard a2aRuntime.inboxSweepGeneration == sweepGeneration,
                  a2aRuntime.accepts(route: route, generation: routeGeneration) else { continue }
            guard let sourceClient = try? await routedClient(for: route),
                  let (base, credential) = gatewayRESTContext(gatewayID: route.gatewayID) else {
                failedGateways.insert(route.gatewayID)
                continue
            }
            await attachRoutedEventsIfNeeded(client: sourceClient,
                                             gatewayID: route.gatewayID,
                                             preserveStateOnReplacement: true)
            guard a2aRuntime.inboxSweepGeneration == sweepGeneration,
                  a2aRuntime.accepts(route: route, generation: routeGeneration) else { continue }
            var targets: [String] = []

            // Read-only inbox discovery consults the exact title registry. It
            // never reads or writes a cached session pointer; `id` remains the
            // durable transcript identity while `resolvedID` is only the live
            // resume address used by interactive navigation.
            do {
                let canonical = try await sourceClient.canonicalBotChat(profile: route.profile)
                guard a2aRuntime.inboxSweepGeneration == sweepGeneration,
                      a2aRuntime.accepts(route: route, generation: routeGeneration) else { continue }
                if let id = canonical?.id, !id.isEmpty { targets.append(id) }
            } catch {
                failedGateways.insert(route.gatewayID)
                continue
            }

            // Legacy "Agent Inbox" sessions have no canonical pin/title.
            do {
                let sessions = try await sourceClient.listSessions(
                    limit: 200, profile: route.profile, includeHidden: true)
                guard a2aRuntime.inboxSweepGeneration == sweepGeneration,
                      a2aRuntime.accepts(route: route, generation: routeGeneration) else { continue }
                for session in sessions where session.title.lowercased().contains("agent inbox") {
                    guard targets.count < A2APolicy.scanSessionsPerProfile else { break }
                    if !targets.contains(session.id) { targets.append(session.id) }
                }
            } catch {
                failedGateways.insert(route.gatewayID)
                continue
            }

            var profileComplete = true
            for stored in targets.prefix(A2APolicy.scanSessionsPerProfile) {
                guard !Task.isCancelled else { return }
                do {
                    let rows = try await GatewayREST.sessionMessages(
                        baseURL: base, credential: credential, storedID: stored,
                        profile: route.profile, limit: A2APolicy.scanMessages)
                    guard a2aRuntime.inboxSweepGeneration == sweepGeneration,
                          a2aRuntime.accepts(route: route, generation: routeGeneration) else {
                        profileComplete = false
                        continue
                    }
                    scanned += 1
                    let ref = SessionRef(gatewayID: route.gatewayID,
                                         botID: endpoint.rosterID, storedID: stored)
                    for (message, at) in AppModel.inboxMessages(
                        in: rows, owner: endpoint.rosterID,
                        sourceGatewayID: route.gatewayID) {
                        collected.append((message, at, ref))
                    }
                } catch {
                    profileComplete = false
                    failedGateways.insert(route.gatewayID)
                }
            }
            if profileComplete { completedProfiles[route.gatewayID, default: 0] += 1 }
        }

        guard a2aRuntime.inboxSweepGeneration == sweepGeneration else { return }
        collected = collected.filter { _, _, ref in
            let profile = GatewayBotRoute(qualifiedID: ref.botID)?.profile ?? ref.botID
            let route = GatewayBotRoute(gatewayID: ref.gatewayID, profile: profile)
            guard let generation = routeGenerations[route] else { return false }
            return a2aRuntime.accepts(route: route, generation: generation)
        }

        let successfulGateways = Set(totalProfiles.compactMap { gatewayID, count in
            !failedGateways.contains(gatewayID)
                && completedProfiles[gatewayID, default: 0] == count ? gatewayID : nil
        })
        let merged = A2AInboxMerge.merge(
            existing: agentInbox, existingRefs: runtime.inboxSessions,
            server: collected, successfulGateways: successfulGateways,
            optimisticRows: A2ARuntime.shared.optimisticRows,
            primaryGatewayID: LiveRuntime.shared.gatewayID, limit: A2APolicy.feedLimit)
        for id in merged.settled { A2ARuntime.shared.optimisticRows[id] = nil }
        runtime.inboxSessions = merged.refs
        agentInbox = merged.messages
        runtime.inboxNote = theme.copy.inboxSourceNote(theme.themeID, sessions: scanned)
    }
}

private extension AppModel {

    /// Wait briefly for a live socket, then bind the feed to it.
    ///
    /// `client` is published before the socket is up, and the tab can be opened
    /// mid-connect (or the gateway swapped underneath a tab already open) — so
    /// this waits rather than leaving an empty feed until the user navigates
    /// away and back. No-op when nobody is watching.
    /// `avoiding` is the client this call is walking away from. A switch tears
    /// the a2a state down BEFORE `AppModel.client` is replaced, so without it
    /// the very first check would re-attach to the socket that is closing and
    /// then never notice the one that replaced it.
    func armInboxAttach(avoiding stale: ObjectIdentifier? = nil) {
        let runtime = A2ARuntime.shared
        guard runtime.viewers > 0, mode == .live else { return }
        runtime.attachTask?.cancel()
        runtime.attachTask = Task { @MainActor [weak self] in
            for attempt in 0..<10 {
                guard !Task.isCancelled, let self,
                      A2ARuntime.shared.viewers > 0 else { return }
                if let client = self.client, ObjectIdentifier(client) != stale {
                    self.attachInboxLive(to: client)
                    return
                }
                if attempt < 9 { try? await Task.sleep(for: .seconds(1)) }
            }
        }
    }

    /// Bind the live feed to a connected gateway.
    func attachInboxLive(to client: GatewayClient) {
        let runtime = A2ARuntime.shared
        let identity = ObjectIdentifier(client)
        if runtime.routedClient != identity {
            // Replace only the inbox subscription's source. Reply watches for
            // retained secondary gateways carry their own client and survive.
            if let previous = runtime.inboxGatewayID,
               previous != activeGatewayID {
                runtime.reset(gatewayID: previous)
            }
            runtime.routedClient = identity
            runtime.inboxGatewayID = activeGatewayID
            runtime.eventGeneration &+= 1
            runtime.eventClient = identity
            runtime.eventToken = nil
            subscribeToA2AChanges(client, generation: runtime.eventGeneration,
                                   gatewayID: activeGatewayID)
        }
        sweepInbox(after: 0)
        startIdleInboxPoll()
    }

    func subscribeToA2AChanges(_ client: GatewayClient, generation: UInt64,
                                gatewayID sourceGatewayID: String?) {
        let identity = ObjectIdentifier(client)
        Task { @MainActor in
            let token = await client.addEpochEventHandler { event, transportEpoch in
                Task { @MainActor [weak self] in
                    guard await client.isCurrentReadyTransport(epoch: transportEpoch) else {
                        return
                    }
                    let runtime = A2ARuntime.shared
                    guard runtime.eventGeneration == generation,
                          runtime.eventClient == identity,
                          runtime.routedClient == identity,
                          runtime.inboxGatewayID == sourceGatewayID else { return }
                    self?.routeA2AChange(event, sourceGatewayID: sourceGatewayID)
                }
            }
            let runtime = A2ARuntime.shared
            guard runtime.eventGeneration == generation,
                  runtime.eventClient == identity,
                  runtime.routedClient == identity,
                  runtime.inboxGatewayID == sourceGatewayID else {
                await client.removeEventHandler(token)
                return
            }
            runtime.eventToken = token
        }
    }

    func startIdleInboxPoll() {
        let runtime = A2ARuntime.shared
        guard runtime.idlePoll == nil else { return }
        runtime.idlePoll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(A2APolicy.idleSweep))
                guard !Task.isCancelled, let self,
                      A2ARuntime.shared.viewers > 0, !self.isOffline else { continue }
                await self.refreshInboxLive()
            }
        }
    }
}

// MARK: - The composer middleware (plugin.js:8206-8321)

public extension AppModel {

    /// Route the @handles in a chat draft, and return the text the submit
    /// should actually carry.
    ///
    /// This is desktop's `mention-middleware` composer registration
    /// (plugin.js:8206-8321) at Talaria's matching point in the pipeline:
    /// `sendOrSteer` → here → `composedPrompt` → `send`. Upstream's handler
    /// also carries the `/new` → `/compact` reroute (8218-8241), which shares
    /// the handler and nothing else; Talaria's slash path never reaches this
    /// function, because `ChatView.send()` hands a leading "/" to `runSlash`
    /// first.
    ///
    /// Three things happen, in upstream's order:
    ///
    ///  1. the fast gate, on the RAW draft (8244) — an ordinary message does
    ///     no work at all;
    ///  2. resolution against the live roster (8252-8256 → 2434), which strips
    ///     code FIRST, so an @handle inside a fence or `backticks` is literal
    ///     text and never a handoff;
    ///  3. identification, and then the note. The note is appended; the
    ///     handles are never rewritten or stripped out of the message.
    ///
    /// An ambiguous handle is refused rather than guessed, and the refusal is
    /// said out loud — see `refuse`.
    ///
    /// This is pure cached-roster work and performs no RPC. It remains safe
    /// while offline: a queued draft carries the same identity annotation when
    /// it is eventually submitted, including the honest no-`message_agent`
    /// clause for ordinary sessions.
    func routeMentions(in text: String, from botID: String) -> String {
        guard BotMention.mentions(text) else { return text }
        let routed = MentionMiddleware.route(text, roster: unionRosterBots, speaking: botID)
        let identified = !routed.recipients.isEmpty
        for collision in routed.refused {
            refuse(collision, in: botID, identified: identified)
        }
        return routed.text
    }
}

private extension AppModel {

    /// An ambiguous handle, said out loud in the chat it was typed in.
    ///
    /// Upstream refuses silently and totally: the form map holds `null`, the
    /// token is skipped, and there is no notify anywhere in 2434-2497 or
    /// 8206-8321 for it. Silence is affordable on desktop, where the roster
    /// sits beside the composer and the two duplicate rows are visible. On a
    /// phone the roster is a screen away, so the refusal costs one system
    /// line naming the bots that collided — the same divergence, for the same
    /// reason, as `MentionResolution.ambiguous` existing at all.
    ///
    /// The message itself still sends. Refusing the mention is not refusing
    /// the turn (plugin.js:8285-8287 returns the draft untouched) — which is
    /// also why the line is appended one hop later: the middleware runs BEFORE
    /// `send()` has put the user's own bubble in the transcript, and a
    /// refusal that appears above the message it is about reads as an answer
    /// to the previous turn.
    ///
    /// `identified` picks the SUBJECT, not whether to speak. A draft can carry
    /// an ambiguous handle and a good one at once — `MentionMiddleware.route`
    /// returns `refused` beside a non-empty `recipients` by design (2457-2466
    /// poisons one form; the rest of the draft resolves normally) — and in
    /// that case the whole-message wording ("No agent was identified") is
    /// false: the appended note names another identity. The scoped wording
    /// says which handle stayed ambiguous and leaves the rest alone.
    func refuse(_ collision: MentionCollision, in botID: String, identified: Bool) {
        let copy = theme.copy
        let line = identified
            ? copy.mentionRefusedOne(theme.themeID, token: collision.token,
                                     options: collision.labels)
            : copy.mentionRefused(theme.themeID, token: collision.token,
                                  options: collision.labels)
        Task { @MainActor in
            chat(for: botID).messages.append(
                ChatMessage(author: .system, time: Self.clock(), text: line))
        }
    }

}

// MARK: - Copy

extension CopyPack {

    /// Activity row when a relayed reply lands.
    func feedHandoffReply(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Reply from"
        case .control: "REPLY RX FROM"
        case .ink: "An answer from"
        }
    }

    /// Composer field prompt — it doubles as the documentation for the
    /// routing grammar, the way desktop's room composer does (plugin.js:7390).
    func mentionPlaceholder(_ t: ThemeID) -> String {
        switch t {
        case .soft: "What should they do? @handle to address a bot"
        case .control: "PAYLOAD — @HANDLE TO ADDRESS"
        case .ink: "what shall they do? name a familiar with @"
        }
    }

    func mentionRecipients(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Goes to"
        case .control: "ROUTE"
        case .ink: "carried unto"
        }
    }

    func mentionRosterLabel(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Tap to address"
        case .control: "ROSTER"
        case .ink: "the familiars"
        }
    }

    func mentionNoRecipients(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Name a bot with @ to send this."
        case .control: "NO ROUTE — @HANDLE REQUIRED."
        case .ink: "Name a familiar with @, and it shall be carried."
        }
    }

    /// Ambiguity refuses rather than guesses (plugin.js:2455).
    func mentionAmbiguous(_ t: ThemeID, token: String) -> String {
        switch t {
        case .soft: "@\(token) fits more than one bot — use its @name-device handle."
        case .control: "@\(token) AMBIGUOUS — USE @NAME-DEVICE."
        case .ink: "@\(token) answers for more than one — call it by @name-device."
        }
    }

    /// The same refusal, said in a bot chat rather than under a composer, and
    /// naming the bots that collided — the composer strip can show two rows,
    /// a transcript has to say it in a sentence. Falls back to the composer
    /// wording if the collision arrived without its cause.
    ///
    /// The subject is the WHOLE message ("no agent was identified"), so this is
    /// the line for a draft where nothing resolved at all. When something did,
    /// use `mentionRefusedOne`.
    func mentionRefused(_ t: ThemeID, token: String, options: [String]) -> String {
        guard !options.isEmpty else { return mentionAmbiguous(t, token: token) }
        let list = options.joined(separator: " or ")
        return switch t {
        case .soft: "No agent was identified — @\(token) fits \(list). Name the one you mean."
        case .control: "NO AGENT IDENTIFIED — @\(token) FITS \(list.uppercased()). NAME ONE."
        case .ink: "@\(token) answers for \(list) alike, so no agent was named. Name the one you mean."
        }
    }

    /// One ambiguous handle in a draft that identified somebody else.
    ///
    /// Scoped to the token because the appended note lists the identities that
    /// did resolve. No wording implies that a message was sent.
    func mentionRefusedOne(_ t: ThemeID, token: String, options: [String]) -> String {
        guard !options.isEmpty else { return mentionAmbiguous(t, token: token) }
        let list = options.joined(separator: " or ")
        return switch t {
        case .soft: "@\(token) was not identified — it fits \(list). Name the one you mean."
        case .control: "@\(token) NOT IDENTIFIED — FITS \(list.uppercased()). NAME ONE."
        case .ink: "@\(token) answers for \(list) alike, so that identity was left unnamed. "
            + "Name the one you mean."
        }
    }

    func mentionUnknown(_ t: ThemeID, token: String) -> String {
        switch t {
        case .soft: "No bot answers to @\(token)."
        case .control: "@\(token) — NO SUCH HANDLE."
        case .ink: "None answers to @\(token)."
        }
    }

    /// Addressed, but on another gateway. Desktop delivers this one over
    /// Connections (plugin.js:8312-8317); a phone holds one socket, so it says
    /// where the bot is instead — naming the device the way upstream's own
    /// remote note does (8313, `@handle (label)`).
    func mentionElsewhere(_ t: ThemeID, handle: String, label: String) -> String {
        let where_ = label.trimmingCharacters(in: .whitespaces)
        guard !where_.isEmpty else {
            return switch t {
            case .soft: "@\(handle) is on another gateway — switch to it to send this."
            case .control: "@\(handle) — OTHER GATEWAY. SWITCH TO SEND."
            case .ink: "@\(handle) keeps another house; go there to be heard."
            }
        }
        return switch t {
        case .soft: "@\(handle) lives on \(where_) — switch to that gateway to send this."
        case .control: "@\(handle) — ON \(where_.uppercased()). SWITCH GATEWAY TO SEND."
        case .ink: "@\(handle) keeps house on \(where_); go there to be heard."
        }
    }

    /// The honest limit, said once in the composer.
    func a2aLimitNote(_ t: ThemeID) -> String {
        switch t {
        case .soft:
            "Delivery is one message per run. A bot mid-run finishes first and reads yours next — nothing interrupts it."
        case .control:
            "PER-RUN DELIVERY. A BUSY BOT FINISHES ITS TURN, THEN READS. NO INTERRUPT."
        case .ink:
            "A word waits its turn. A familiar at work finishes, then hears you; nothing cuts across it."
        }
    }

    func a2aQueuedNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Queued behind a run — it goes next"
        case .control: "QUEUED — RUNS NEXT"
        case .ink: "waits behind work already begun"
        }
    }

    func a2aWaitingNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Delivered — waiting for a reply"
        case .control: "DELIVERED — AWAITING REPLY"
        case .ink: "carried — the answer is awaited"
        }
    }

    func a2aRepliedNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Replied"
        case .control: "REPLIED"
        case .ink: "answered"
        }
    }

    func a2aQuietNote(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No reply yet — it is in their chat"
        case .control: "NO REPLY YET — SEE ITS BOT CHAT"
        case .ink: "no answer yet; the word is kept in its chat"
        }
    }

    func a2aFailedNote(_ t: ThemeID, reason: String) -> String {
        switch t {
        case .soft: "Could not reach it — \(reason)"
        case .control: "UNREACHABLE — \(reason.uppercased())"
        case .ink: "the word did not arrive — \(reason)"
        }
    }
}
