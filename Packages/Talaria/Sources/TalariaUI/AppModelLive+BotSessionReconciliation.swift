import Foundation
import TalariaKit

struct BotSessionReconciliationRow: Sendable, Equatable {
    var id: String
    var title: String
    var startedAt: Double?

    init(id: String, title: String, startedAt: Double?) {
        self.id = id; self.title = title; self.startedAt = startedAt
    }

    init(_ session: StoredSession) {
        self.init(id: session.id, title: session.title, startedAt: session.startedAt)
    }
}

struct BotSessionReconciliationInventory: Sendable, Equatable {
    var rows: [BotSessionReconciliationRow]
    var originalRowCount: Int
    var total: Int?
    var hasMore: Bool

    init(rows: [BotSessionReconciliationRow], originalRowCount: Int? = nil,
         total: Int?, hasMore: Bool) {
        self.originalRowCount = originalRowCount ?? rows.count
        self.rows = Array(rows.prefix(BotSessionReconciliationPolicy.maximumRows))
        self.total = total; self.hasMore = hasMore
    }

    init(_ page: SessionListPage) {
        self.init(rows: page.sessions.map(BotSessionReconciliationRow.init),
                  originalRowCount: page.originalRowCount,
                  total: page.total, hasMore: page.hasMore)
    }
}

struct BotSessionReconciliationClaim: Sendable, Equatable, Hashable {
    var sourceKey: String
    var profile: String
    var mustHideOwnedSessionIDs: Set<String>
    var protectedSessionIDs: Set<String>

    init(sourceKey: String, profile: String,
         mustHideOwnedSessionIDs: Set<String> = [],
         protectedSessionIDs: Set<String>) {
        self.sourceKey = sourceKey; self.profile = profile
        self.mustHideOwnedSessionIDs = mustHideOwnedSessionIDs
        self.protectedSessionIDs = protectedSessionIDs
    }
}

enum BotSessionReconciliationIssue: Sendable, Equatable {
    case unavailable(sourceKey: String)
    case stale(sourceKey: String)
    case incompleteInventory(sourceKey: String)
    case duplicateSource(sourceKey: String)
    case sessionCollision(sessionID: String, sourceKeys: [String])

    var message: String {
        switch self {
        case .unavailable: "Bot session reconciliation skipped an unavailable source."
        case .stale: "Bot session reconciliation discarded stale source authority."
        case .incompleteInventory: "Bot session reconciliation retained a partial or saturated inventory."
        case .duplicateSource: "Bot session reconciliation retained an ambiguous duplicate profile route."
        case .sessionCollision: "Bot session reconciliation retained a cross-profile session-id collision."
        }
    }
}

enum BotSessionReconciliationError: Error {
    case stale
}

enum BotSessionReconciliationPolicy {
    static let maximumRows = 200
    static let minimumAge: TimeInterval = 5 * 60

    enum InventoryDecision: Equatable {
        case candidates([String])
        case incomplete
    }

    static func candidateIDs(
        in inventory: BotSessionReconciliationInventory,
        mustHideOwned: Set<String>, protected: Set<String>, now: TimeInterval
    ) -> InventoryDecision {
        guard now.isFinite, now > 0,
              inventory.hasMore == false,
              let total = inventory.total,
              inventory.originalRowCount == inventory.rows.count,
              total == inventory.originalRowCount,
              total < maximumRows,
              inventory.originalRowCount < maximumRows else { return .incomplete }

        let normalizedIDs = inventory.rows.map {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard Set(normalizedIDs).count == normalizedIDs.count else { return .incomplete }

        var candidates: [String] = []
        for row in inventory.rows {
            let id = row.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            if mustHideOwned.contains(id) {
                candidates.append(id)
                continue
            }
            guard !protected.contains(id), isPlumbingTitle(row.title),
                  let startedAt = row.startedAt,
                  startedAt.isFinite, startedAt > 0, startedAt <= now,
                  now - startedAt >= minimumAge else { continue }
            candidates.append(id)
        }
        return .candidates(candidates)
    }

    static func isPlumbingTitle(_ raw: String) -> Bool {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return title == "Bot Chat" || title == "Agent Inbox" || title.hasPrefix("Group: ")
    }
}

@MainActor
struct BotSessionReconciliationOperations {
    var list: (BotSessionReconciliationClaim) async throws
        -> BotSessionReconciliationInventory
    var isCurrent: (BotSessionReconciliationClaim) async -> Bool
    var hide: (BotSessionReconciliationClaim, String) async throws -> Void
    var report: (BotSessionReconciliationIssue) -> Void
    var reportInventoryFailure: (Error, BotSessionReconciliationClaim) -> Void
    var reportMutationFailure: (Error, BotSessionReconciliationClaim, String) -> Void
}

struct BotSessionReconciliationOutcome: Sendable, Equatable {
    var hiddenSessionIDs: [String] = []
    var issues: [BotSessionReconciliationIssue] = []
}

@MainActor
enum BotSessionReconciler {
    static func run(
        claims: [BotSessionReconciliationClaim], now: TimeInterval,
        operations: BotSessionReconciliationOperations
    ) async -> BotSessionReconciliationOutcome {
        var outcome = BotSessionReconciliationOutcome()
        var plans: [(claim: BotSessionReconciliationClaim, ids: [String])] = []
        var seenSources = Set<String>()

        for claim in claims {
            guard seenSources.insert(claim.sourceKey).inserted else {
                record(.duplicateSource(sourceKey: claim.sourceKey), into: &outcome,
                       using: operations)
                continue
            }
            do {
                let inventory = try await operations.list(claim)
                guard await operations.isCurrent(claim) else {
                    record(.stale(sourceKey: claim.sourceKey), into: &outcome,
                           using: operations)
                    continue
                }
                switch BotSessionReconciliationPolicy.candidateIDs(
                    in: inventory, mustHideOwned: claim.mustHideOwnedSessionIDs,
                    protected: claim.protectedSessionIDs, now: now) {
                case .incomplete:
                    record(.incompleteInventory(sourceKey: claim.sourceKey), into: &outcome,
                           using: operations)
                case .candidates(let ids):
                    plans.append((claim, ids))
                }
            } catch {
                operations.reportInventoryFailure(error, claim)
            }
        }

        var owners: [String: Set<String>] = [:]
        for plan in plans {
            for id in plan.ids { owners[id, default: []].insert(plan.claim.sourceKey) }
        }
        let collisions = Set(owners.compactMap { id, sources in sources.count > 1 ? id : nil })
        for id in collisions.sorted() {
            record(.sessionCollision(sessionID: id,
                                     sourceKeys: owners[id, default: []].sorted()),
                   into: &outcome, using: operations)
        }

        for plan in plans {
            for id in plan.ids where !collisions.contains(id) {
                guard await operations.isCurrent(plan.claim) else {
                    record(.stale(sourceKey: plan.claim.sourceKey), into: &outcome,
                           using: operations)
                    break
                }
                do {
                    try await operations.hide(plan.claim, id)
                    guard await operations.isCurrent(plan.claim) else {
                        record(.stale(sourceKey: plan.claim.sourceKey), into: &outcome,
                               using: operations)
                        break
                    }
                    outcome.hiddenSessionIDs.append(id)
                } catch BotSessionReconciliationError.stale {
                    record(.stale(sourceKey: plan.claim.sourceKey), into: &outcome,
                           using: operations)
                    break
                } catch {
                    operations.reportMutationFailure(error, plan.claim, id)
                }
            }
        }
        return outcome
    }

    private static func record(
        _ issue: BotSessionReconciliationIssue,
        into outcome: inout BotSessionReconciliationOutcome,
        using operations: BotSessionReconciliationOperations
    ) {
        outcome.issues.append(issue)
        operations.report(issue)
    }
}

@MainActor
private final class BotSessionReconciliationRuntime {
    static let shared = BotSessionReconciliationRuntime()
    var isRunning = false
}

@MainActor
private struct BotSessionSourceAuthority {
    var claim: BotSessionReconciliationClaim
    var rosterID: String
    var route: GatewayBotRoute
    var connection: GatewayClientPool.ConnectionSnapshot
    var lifecycle: ProfileLifecycleGenerationToken
    var primaryGeneration: Int?
    var primaryClientIdentity: ObjectIdentifier?
}

extension AppModel {
    /// Repair visible exact-owned canonical/room plumbing and reconcile only
    /// proven-old unowned plumbing. Current scratch/recent chats are protected.
    /// A partial/saturated/ambiguous inventory or authority race is
    /// non-destructive.
    func reconcileStaleBotSessions(now: TimeInterval = Date().timeIntervalSince1970) async {
        guard mode == .live else { return }
        let runtime = BotSessionReconciliationRuntime.shared
        guard !runtime.isRunning else { return }
        runtime.isRunning = true
        defer { runtime.isRunning = false }

        let authorities = await botSessionSourceAuthorities()
        let byKey = Dictionary(uniqueKeysWithValues: authorities.map { ($0.claim.sourceKey, $0) })
        let operations = BotSessionReconciliationOperations(
            list: { claim in
                guard let authority = byKey[claim.sourceKey] else {
                    throw BotSessionReconciliationError.stale
                }
                let page = try await authority.connection.client.listSessionPage(
                    limit: BotSessionReconciliationPolicy.maximumRows,
                    profile: authority.route.profile, includeHidden: false)
                return BotSessionReconciliationInventory(page)
            },
            isCurrent: { claim in
                guard let authority = byKey[claim.sourceKey] else { return false }
                return await self.botSessionSourceAuthorityIsCurrent(authority)
            },
            hide: { claim, sessionID in
                guard let authority = byKey[claim.sourceKey],
                      await self.botSessionSourceAuthorityIsCurrent(authority),
                      let lease = await ConnectionRegistry.shared.clientPool.acquireLease(
                        authority.connection, for: authority.route.gatewayID) else {
                    throw BotSessionReconciliationError.stale
                }
                guard await self.botSessionSourceAuthorityIsCurrent(authority) else {
                    await ConnectionRegistry.shared.clientPool.release(lease)
                    throw BotSessionReconciliationError.stale
                }
                do {
                    _ = try await authority.connection.client.setSessionHidden(
                        sessionID, hidden: true, profile: authority.route.profile)
                } catch {
                    await ConnectionRegistry.shared.clientPool.release(lease)
                    throw error
                }
                guard await self.botSessionSourceAuthorityIsCurrent(authority) else {
                    await ConnectionRegistry.shared.clientPool.release(lease)
                    throw BotSessionReconciliationError.stale
                }
                await ConnectionRegistry.shared.clientPool.release(lease)
                guard await self.botSessionSourceAuthorityIsCurrent(authority) else {
                    throw BotSessionReconciliationError.stale
                }
            },
            report: { issue in
                for gatewayID in issue.gatewayIDs(from: byKey) {
                    ConnectionSupervisor.shared.note(
                        error: GatewayError(code: -8, message: issue.message),
                        forGatewayID: gatewayID)
                }
            },
            reportInventoryFailure: { error, claim in
                guard let authority = byKey[claim.sourceKey] else { return }
                OwnedSessionHidingFailure.record(error, gatewayID: authority.route.gatewayID)
            },
            reportMutationFailure: { error, claim, _ in
                guard let authority = byKey[claim.sourceKey] else { return }
                OwnedSessionHidingFailure.record(error, gatewayID: authority.route.gatewayID)
            }
        )
        _ = await BotSessionReconciler.run(
            claims: authorities.map(\.claim), now: now, operations: operations)
    }

    private func botSessionSourceAuthorities() async -> [BotSessionSourceAuthority] {
        let retained = await ConnectionRegistry.shared.clientPool.retainedConnectionSnapshots()
        let connections = Dictionary(uniqueKeysWithValues: retained.map {
            ($0.gatewayID, $0.connection)
        })
        var byRoute: [GatewayBotRoute: [Bot]] = [:]
        for bot in unionRosterBots {
            guard let route = stateRoute(for: bot.id), route.profile == bot.profileName else { continue }
            byRoute[route, default: []].append(bot)
        }

        var result: [BotSessionSourceAuthority] = []
        for route in byRoute.keys.sorted(by: { $0.qualifiedID < $1.qualifiedID }) {
            guard let rows = byRoute[route], rows.count == 1, let bot = rows.first else {
                botSessionReconciliationReport(.duplicateSource(sourceKey: route.qualifiedID),
                                               gatewayID: route.gatewayID)
                continue
            }
            guard let connection = connections[route.gatewayID],
                  let lifecycle = profileLifecycleGenerationToken(for: bot.id),
                  lifecycle.route == route,
                  gatewayBaseURL(for: route) == connection.baseURL else {
                botSessionReconciliationReport(.unavailable(sourceKey: route.qualifiedID),
                                               gatewayID: route.gatewayID)
                continue
            }
            let primary = route.gatewayID == LiveRuntime.shared.gatewayID
            let primaryClientIdentity: ObjectIdentifier?
            if primary {
                guard let client,
                      ObjectIdentifier(client) == ObjectIdentifier(connection.client) else {
                    botSessionReconciliationReport(.stale(sourceKey: route.qualifiedID),
                                                   gatewayID: route.gatewayID)
                    continue
                }
                primaryClientIdentity = ObjectIdentifier(client)
            } else {
                primaryClientIdentity = nil
            }
            let authority = BotSessionSourceAuthority(
                claim: BotSessionReconciliationClaim(
                    sourceKey: route.qualifiedID, profile: route.profile,
                    mustHideOwnedSessionIDs: ownedBotSessionIDs(for: route),
                    protectedSessionIDs: protectedBotSessionIDs(for: route)),
                rosterID: bot.id, route: route, connection: connection,
                lifecycle: lifecycle,
                primaryGeneration: primary ? LiveRuntime.shared.generation : nil,
                primaryClientIdentity: primaryClientIdentity)
            guard await botSessionSourceAuthorityIsCurrent(authority) else {
                botSessionReconciliationReport(.stale(sourceKey: route.qualifiedID),
                                               gatewayID: route.gatewayID)
                continue
            }
            result.append(authority)
        }
        return result
    }

    private func protectedBotSessionIDs(for route: GatewayBotRoute) -> Set<String> {
        var ids = Set<String>()
        // Roster freshness is weaker than canonical identity but still proves
        // current ownership: a just-observed durable tail must not be treated
        // as an orphan merely because the user has not opened it on this phone.
        for (botID, sessionID) in LiveRuntime.shared.lastSessionByBot
            where stateRoute(for: botID) == route && !sessionID.isEmpty {
            ids.insert(sessionID)
        }
        for (botID, chat) in chats where stateRoute(for: botID) == route {
            if let stored = chat.storedSessionID, !stored.isEmpty { ids.insert(stored) }
        }
        return ids
    }

    /// Exact Bot Mode ownership retains Desktop's original behavior: legacy
    /// canonical and room rows that were born visible are repaired to hidden
    /// even while they are current. This is separate from orphan protection.
    private func ownedBotSessionIDs(for route: GatewayBotRoute) -> Set<String> {
        var ids = Set<String>()
        for (botID, summary) in LiveRuntime.shared.canonicalSessionByBot
            where stateRoute(for: botID) == route {
            if !summary.id.isEmpty { ids.insert(summary.id) }
            if let resolved = summary.resolvedID, !resolved.isEmpty { ids.insert(resolved) }
        }
        for room in rooms {
            for (memberKey, sessionID) in room.memberSessions
                where GatewayBotRoute(qualifiedID: memberKey) == route && !sessionID.isEmpty {
                ids.insert(sessionID)
            }
        }
        return ids
    }

    private func botSessionSourceAuthorityIsCurrent(
        _ authority: BotSessionSourceAuthority
    ) async -> Bool {
        guard botSessionSourceLocalAuthorityIsCurrent(authority),
              await ConnectionRegistry.shared.clientPool.isCurrent(
                authority.connection, for: authority.route.gatewayID),
              botSessionSourceLocalAuthorityIsCurrent(authority) else { return false }
        return true
    }

    /// Main-actor half of the source fence, deliberately repeated after the
    /// pool actor hop. A profile switch can run while `isCurrent` awaits the
    /// pool, so pre-await agreement alone is not publication authority.
    private func botSessionSourceLocalAuthorityIsCurrent(
        _ authority: BotSessionSourceAuthority
    ) -> Bool {
        guard mode == .live,
              unionRosterBots.filter({ stateRoute(for: $0.id) == authority.route }).count == 1,
              stateRoute(for: authority.rosterID) == authority.route,
              profileLifecycleAccepts(authority.lifecycle),
              gatewayBaseURL(for: authority.route) == authority.connection.baseURL else {
            return false
        }
        if let generation = authority.primaryGeneration {
            return LiveRuntime.shared.generation == generation
                && client.map(ObjectIdentifier.init) == authority.primaryClientIdentity
        }
        return true
    }

    private func botSessionReconciliationReport(
        _ issue: BotSessionReconciliationIssue, gatewayID: String
    ) {
        ConnectionSupervisor.shared.note(
            error: GatewayError(code: -8, message: issue.message), forGatewayID: gatewayID)
    }
}

private extension BotSessionReconciliationIssue {
    func gatewayIDs(from authorities: [String: BotSessionSourceAuthority]) -> Set<String> {
        switch self {
        case .unavailable(let key), .stale(let key),
             .incompleteInventory(let key), .duplicateSource(let key):
            return Set(authorities[key].map { [$0.route.gatewayID] } ?? [])
        case .sessionCollision(_, let sourceKeys):
            return Set(sourceKeys.compactMap { authorities[$0]?.route.gatewayID })
        }
    }
}
