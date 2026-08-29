import Foundation
import TalariaKit

public enum ProfileLifecycleOutcome: Sendable, Equatable {
    case renamed(canonicalName: String, displayName: String?)
    case deleted
    case refused(String)
}

enum ProfileLifecyclePostcondition: Equatable {
    case committed
    case notCommitted
    case indeterminate

    static func rename(names: Set<String>, source: String, destination: String) -> Self {
        if !names.contains(source), names.contains(destination) { return .committed }
        if names.contains(source) { return .notCommitted }
        return .indeterminate
    }

    static func delete(names: Set<String>, source: String) -> Self {
        names.contains(source) ? .notCommitted : .committed
    }

    static func displayRename(inventory: [String: ProfileInventoryEntry],
                              source: String, requested: String) -> Self {
        guard let entry = inventory[source], let displayName = entry.displayName else {
            return .indeterminate
        }
        return displayName == requested ? .committed : .notCommitted
    }
}

@MainActor
private final class ProfileLifecycleRuntime {
    static let shared = ProfileLifecycleRuntime()
    var gatewaysInFlight: Set<String> = []
    /// An indeterminate filesystem mutation must not be followed by another
    /// lifecycle mutation on the same host until a fresh process/operator
    /// recovery establishes authority.
    var heldGateways: Set<String> = []
    var routeGenerations: [GatewayBotRoute: UInt64] = [:]
    var blockedRoutes: Set<GatewayBotRoute> = []
    var ordinaryTrafficCounts: [String: Int] = [:]
    private struct TrafficWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }
    private var trafficWaiters: [String: [TrafficWaiter]] = [:]
    /// The active-primary profile is parked under a qualified key before its
    /// gateway-wide retirement disconnect. Keep only that exact stop intent
    /// outside ChatRuntime so disconnectGateway's source scrub cannot erase it
    /// before a committed rename re-keys it (or a refusal restores it).
    var pendingStopParking: [GatewayBotRoute: ProfileLifecyclePendingStopParking] = [:]
    /// Lifecycle fence marker for canonical work. The registry itself is
    /// server-owned; only route-owned in-flight operations are retired.
    var pendingCanonicalPinParking: [GatewayBotRoute: ProfileLifecyclePendingCanonicalPinParking] = [:]

    func beginLifecycle(gatewayID: String) -> Bool {
        guard !heldGateways.contains(gatewayID),
              !gatewaysInFlight.contains(gatewayID),
              ordinaryTrafficCounts[gatewayID, default: 0] == 0 else { return false }
        gatewaysInFlight.insert(gatewayID)
        return true
    }

    /// A gateway removal must block *new* ordinary traffic immediately, but
    /// can safely wait for an already-issued exact-source operation to finish.
    /// This differs from a profile mutation, which refuses to start while
    /// traffic is live because it has a remote route transition to protect.
    func beginGatewayTeardown(gatewayID: String) -> Bool {
        guard !heldGateways.contains(gatewayID),
              !gatewaysInFlight.contains(gatewayID) else { return false }
        gatewaysInFlight.insert(gatewayID)
        return true
    }

    func awaitGatewayTrafficQuiescence(gatewayID: String) async {
        guard ordinaryTrafficCounts[gatewayID, default: 0] > 0 else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || ordinaryTrafficCounts[gatewayID, default: 0] == 0 {
                    continuation.resume()
                } else {
                    trafficWaiters[gatewayID, default: []].append(
                        TrafficWaiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in
                ProfileLifecycleRuntime.shared.cancelTrafficWaiter(
                    gatewayID: gatewayID, waiterID: waiterID)
            }
        }
    }

    private func cancelTrafficWaiter(gatewayID: String, waiterID: UUID) {
        guard var waiters = trafficWaiters[gatewayID],
              let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = waiters.remove(at: index)
        trafficWaiters[gatewayID] = waiters.isEmpty ? nil : waiters
        waiter.continuation.resume()
    }

    private func resumeTrafficWaitersIfQuiescent(gatewayID: String) {
        guard ordinaryTrafficCounts[gatewayID, default: 0] == 0,
              let waiters = trafficWaiters.removeValue(forKey: gatewayID) else { return }
        for waiter in waiters { waiter.continuation.resume() }
    }

    func acquireOrdinaryTraffic(gatewayID: String) -> GatewayClient.TrafficLease? {
        guard !heldGateways.contains(gatewayID),
              !gatewaysInFlight.contains(gatewayID) else { return nil }
        return makeOrdinaryTrafficLease(gatewayID: gatewayID)
    }

    func finishAuthoritativeReconciliation(gatewayID: String) -> GatewayClient.TrafficLease {
        // MainActor makes this an atomic exclusive-to-shared handoff: there is
        // no point where a successor lifecycle can enter before recovery owns
        // an ordinary lease.
        gatewaysInFlight.remove(gatewayID)
        return makeOrdinaryTrafficLease(gatewayID: gatewayID)
    }

    private func makeOrdinaryTrafficLease(gatewayID: String) -> GatewayClient.TrafficLease {
        ordinaryTrafficCounts[gatewayID, default: 0] += 1
        return GatewayClient.TrafficLease { @Sendable in
            await MainActor.run {
                let runtime = ProfileLifecycleRuntime.shared
                let remaining = runtime.ordinaryTrafficCounts[gatewayID, default: 1] - 1
                if remaining > 0 {
                    runtime.ordinaryTrafficCounts[gatewayID] = remaining
                } else {
                    runtime.ordinaryTrafficCounts.removeValue(forKey: gatewayID)
                    runtime.resumeTrafficWaitersIfQuiescent(gatewayID: gatewayID)
                }
            }
        }
    }

    func block(_ route: GatewayBotRoute) {
        routeGenerations[route, default: 0] &+= 1
        blockedRoutes.insert(route)
    }

    func restore(_ route: GatewayBotRoute) {
        routeGenerations[route, default: 0] &+= 1
        blockedRoutes.remove(route)
    }

    func activate(_ route: GatewayBotRoute) {
        routeGenerations[route, default: 0] &+= 1
        blockedRoutes.remove(route)
    }
}

@MainActor
enum ProfileLifecycleTrafficAdmission {
    static func beginLifecycle(_ gatewayID: String) -> Bool {
        ProfileLifecycleRuntime.shared.beginLifecycle(gatewayID: gatewayID)
    }

    static func beginGatewayTeardown(_ gatewayID: String) -> Bool {
        ProfileLifecycleRuntime.shared.beginGatewayTeardown(gatewayID: gatewayID)
    }

    static func awaitGatewayTrafficQuiescence(_ gatewayID: String) async {
        await ProfileLifecycleRuntime.shared.awaitGatewayTrafficQuiescence(gatewayID: gatewayID)
    }

    static func endGatewayTeardown(_ gatewayID: String) {
        ProfileLifecycleRuntime.shared.gatewaysInFlight.remove(gatewayID)
    }

    static func endLifecycle(_ gatewayID: String) {
        ProfileLifecycleRuntime.shared.gatewaysInFlight.remove(gatewayID)
    }

    /// Called only after Hermes' postcondition and all local route/queue state
    /// agree. Owner reconnect and roster refresh are ordinary traffic, so they
    /// must happen after this boundary rather than receiving a privileged
    /// bypass through the exclusive filesystem window.
    static func finishAuthoritativeReconciliation(
        _ gatewayID: String
    ) -> GatewayClient.TrafficLease {
        ProfileLifecycleRuntime.shared.finishAuthoritativeReconciliation(gatewayID: gatewayID)
    }

    static func allows(_ gatewayID: String) -> Bool {
        let runtime = ProfileLifecycleRuntime.shared
        return !runtime.gatewaysInFlight.contains(gatewayID)
            && !runtime.heldGateways.contains(gatewayID)
    }

    static func acquire(_ gatewayID: String) -> GatewayClient.TrafficLease? {
        ProfileLifecycleRuntime.shared.acquireOrdinaryTraffic(gatewayID: gatewayID)
    }

    /// Static GatewayREST surfaces carry a base URL rather than a saved source
    /// id. Resolve that exact registered source, then acquire the same ordinary
    /// lease as GatewayClient. Unknown pre-registration URLs have no lifecycle
    /// target yet and therefore need no lease.
    static func acquire(baseURL: URL) throws -> GatewayClient.TrafficLease? {
        guard let gatewayID = ConnectionRegistry.shared.gateway(forURL: baseURL)?.id else {
            return nil
        }
        guard let lease = acquire(gatewayID) else {
            throw GatewayError(
                code: GatewayClient.trafficFenced,
                message: "Gateway traffic is paused while a profile change is being resolved.")
        }
        return lease
    }
}

@MainActor
final class ProfileLifecycleExclusiveLease {
    private let gatewayID: String
    private var isHeld = true

    init(gatewayID: String) { self.gatewayID = gatewayID }

    func finishAuthoritativeReconciliation() -> GatewayClient.TrafficLease {
        precondition(isHeld, "Profile lifecycle exclusive lease already released")
        isHeld = false
        return ProfileLifecycleTrafficAdmission.finishAuthoritativeReconciliation(gatewayID)
    }

    func releaseIfHeld() {
        guard isHeld else { return }
        isHeld = false
        ProfileLifecycleTrafficAdmission.endLifecycle(gatewayID)
    }
}

struct ProfileLifecycleGenerationToken: Equatable, Sendable {
    var route: GatewayBotRoute
    var generation: UInt64
}

struct ProfileLifecycleRetirement: Equatable {
    var wasActive: Bool
    var connectionGeneration: Int?
}

enum ProfileLifecycleRecoveryPolicy {
    static func mayRestorePrimary(
        retirement: ProfileLifecycleRetirement,
        currentGeneration: Int,
        currentGatewayID: String?,
        hasClient: Bool,
        switchInProgress: Bool
    ) -> Bool {
        retirement.wasActive
            && retirement.connectionGeneration == currentGeneration
            && currentGatewayID == nil
            && !hasClient
            && !switchInProgress
    }
}

@MainActor
enum ProfileLifecycleSwitchClaim {
    static func acquire() -> Bool {
        let supervisor = ConnectionSupervisor.shared
        guard !supervisor.isReconnecting else { return false }
        supervisor.isReconnecting = true
        return true
    }

    static func release() {
        ConnectionSupervisor.shared.isReconnecting = false
    }
}

private struct ProfileLifecyclePreservedState {
    var portrait: Data?
    var unread: Int
}

private struct ProfileLifecyclePendingStopParking: Equatable {
    var originalBotID: String
    var parkedBotID: String
    var pending: PendingStopRequest
}

private struct ProfileLifecyclePendingCanonicalPinParking: Equatable {
    var sourceIDs: Set<String>
}

/// Exact pre-accept projection captured before lifecycle teardown scrubs
/// streaming/tool state. It is restored only for a request proven not to have
/// crossed its wire acceptance boundary.
private struct ProfileLifecycleMutationRollback {
    var chatID: ObjectIdentifier
    var messages: [ChatMessage]
    var isRunning: Bool
    var isTyping: Bool
}

extension AppModel {
    /// Focused race-test seam: model a lifecycle mutation winning across an
    /// RPC await without invoking a real profile filesystem operation.
    func invalidateProfileLifecycleRouteForTesting(_ route: GatewayBotRoute) {
        ProfileLifecycleRuntime.shared.block(route)
    }

    func clearProfileLifecycleRouteForTesting(_ route: GatewayBotRoute) {
        ProfileLifecycleRuntime.shared.blockedRoutes.remove(route)
        ProfileLifecycleRuntime.shared.routeGenerations.removeValue(forKey: route)
    }

    /// Capture one route generation before an async profile-owned operation.
    /// Lifecycle mutation blocks the route and bumps this generation before it
    /// can retire the socket; completions must re-check before publishing.
    internal func profileLifecycleGenerationToken(for botID: String)
        -> ProfileLifecycleGenerationToken? {
        guard let route = stateRoute(for: botID) else { return nil }
        let runtime = ProfileLifecycleRuntime.shared
        guard !runtime.blockedRoutes.contains(route) else { return nil }
        return ProfileLifecycleGenerationToken(
            route: route, generation: runtime.routeGenerations[route, default: 0])
    }

    internal func profileLifecycleAccepts(_ token: ProfileLifecycleGenerationToken) -> Bool {
        let runtime = ProfileLifecycleRuntime.shared
        return !runtime.blockedRoutes.contains(token.route)
            && runtime.routeGenerations[token.route, default: 0] == token.generation
    }

    /// A route token alone cannot reject a stale primary client after a
    /// reconnect. Canonical attach and roster cosmetics also retain the
    /// client identity and primary generation across their awaits.
    internal func profileLifecycleAcceptsGatewaySnapshot(
        route: GatewayBotRoute, client: GatewayClient, generation: Int
    ) -> Bool {
        let tokenID = route.gatewayID == LiveRuntime.shared.gatewayID
            ? route.profile : route.qualifiedID
        guard let token = profileLifecycleGenerationToken(for: tokenID),
              token.route == route,
              profileLifecycleAccepts(token) else { return false }
        guard route.gatewayID == LiveRuntime.shared.gatewayID else { return true }
        return LiveRuntime.shared.generation == generation
            && self.client.map(ObjectIdentifier.init) == ObjectIdentifier(client)
    }

    /// Gateway-wide admission check for runtimes such as voice whose stream
    /// can outlive one profile route. Both an active mutation and an unresolved
    /// postcondition must stop new traffic until lifecycle authority returns.
    internal func profileLifecycleAllowsGatewayTraffic(_ gatewayID: String) -> Bool {
        ProfileLifecycleTrafficAdmission.allows(gatewayID)
    }

    /// A successful explicit create/recreate makes a formerly deleted identity
    /// authoritative again. Never infer this from a possibly stale roster.
    internal func activateProfileLifecycleRoute(gatewayID: String, profile: String) async throws {
        let route = GatewayBotRoute(gatewayID: gatewayID, profile: profile)
        try await activateRoomProfileRoute(route)
        A2ARuntime.shared.activateProfileRoute(route)
        ProfileLifecycleRuntime.shared.activate(route)
    }

    public func profileLifecycleTarget(rosterID: String) -> ProfileLifecycleTarget? {
        guard let route = profileRoute(for: rosterID),
              unionRosterBots.contains(where: { $0.id == rosterID }) else { return nil }
        return ProfileLifecycleTarget(rosterID: rosterID, route: route)
    }

    /// Rename the exact source-qualified profile captured by the UI. Route
    /// ownership is checked again immediately before the REST mutation; a
    /// stale sheet cannot act on the same bare name after a gateway switch.
    public func renameProfile(_ target: ProfileLifecycleTarget, to newName: String) async
        -> ProfileLifecycleOutcome {
        guard mode == .live else { return .refused("Connect to a gateway first.") }
        guard profileLifecycleTarget(rosterID: target.rosterID) == target else {
            return .refused("That profile or gateway changed. Reopen the profile manager.")
        }
        guard let (baseURL, credential) = gatewayRESTContext(gatewayID: target.route.gatewayID)
        else { return .refused("Sign in to that gateway to rename this profile.") }
        guard !ProfileLifecycleRuntime.shared.heldGateways.contains(target.route.gatewayID) else {
            return .refused("That gateway has an unresolved profile change. Verify its profiles outside Talaria, then restart the app before trying again.")
        }
        guard !ConnectionSupervisor.shared.isReconnecting else {
            return .refused("A gateway connection change is already in progress. Try again when it finishes.")
        }
        let cleanName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return .refused("Enter a profile name.") }
        if target.route.profile != "default" {
            guard ProfileNamePolicy.validatesNamedProfile(cleanName) else {
                return .refused("Use a non-reserved profile name: lowercase letters, digits, hyphens, or underscores; start with a letter or digit.")
            }
            guard cleanName != target.route.profile else { return .refused("The profile name is unchanged.") }
        }
        guard ProfileLifecycleTrafficAdmission.beginLifecycle(target.route.gatewayID)
        else { return .refused("That gateway is busy with another request or profile change. Try again when it finishes.") }
        AdvancedTerminalCoordinator.shared.stopAndForget(gatewayID: target.route.gatewayID)
        let exclusive = ProfileLifecycleExclusiveLease(gatewayID: target.route.gatewayID)
        defer { exclusive.releaseIfHeld() }

        let changesDirectory = target.route.profile != "default"
        // Room drive/metadata work must be fenced before the first suspend;
        // otherwise a completion can make the destination writable while the
        // profile REST mutation is still unresolved.
        let roomLifecycleToken: RoomProfileLifecycleToken?
        if changesDirectory {
            do {
                roomLifecycleToken = try await persistRoomProfileLifecycleFence(source: target.route)
            } catch {
                return .refused("Room state could not be durably fenced before the profile rename.")
            }
        } else { roomLifecycleToken = nil }
        // A default-profile rename still changes the source-qualified profile
        // identity used by the queue reconciliation below, even though it does
        // not have a room-directory mutation. Park before every remote rename
        // so no local-ready row can race its route transition.
        guard parkDurableComposerQueueForLifecycle(route: target.route) else {
            return .refused("Queued prompts could not be durably parked before the profile rename.")
        }
        let preserved = captureProfileLifecycleState(target)
        if changesDirectory {
            parkProfileLifecycleCanonicalState(target)
            parkProfileLifecycleState(target)
            // Keep the exact deferred stop parked until a committed rename
            // can re-key it; a refused rename restores the original route.
            abortProfileRuntime(target, preservePendingStop: true,
                                preserveQueuedState: true)
        } else {
            // A default rename changes presentation metadata only, but late
            // profile-owned completions still must not publish across an
            // uncertain mutation response.
            ProfileLifecycleRuntime.shared.block(target.route)
            A2ARuntime.shared.retireProfileRoute(
                target.route, sourceBotIDs: profileLifecycleSourceIDs(target),
                preserveForRename: true)
        }
        if changesDirectory {
            // disconnectGateway clears the departing primary's A2A scope;
            // this route was already retired/paused above and must survive
            // until the rename postcondition can migrate it.
            A2ARuntime.shared.preserveRouteAcrossGatewayReset(target.route)
        }
        let retirement = changesDirectory
            ? await retireProfileLifecycleClient(target.route.gatewayID, baseURL: baseURL,
                                                  credential: credential)
            : ProfileLifecycleRetirement(wasActive: false, connectionGeneration: nil)
        if changesDirectory {
            // The active-primary retirement scrubbed all gateway stops. Put
            // only this target back under its parked qualified key before the
            // REST result is reconciled; siblings remain retired.
            restoreProfileLifecyclePendingStop(target, parked: true)
        }

        let result: ProfileRenameResult
        do {
            result = try await GatewayREST.renameProfile(baseURL: baseURL,
                                                         credential: credential,
                                                         profile: target.route.profile,
                                                         newName: cleanName)
        } catch let error as GatewayError {
            guard changesDirectory else {
                return await resolveAmbiguousDefaultDisplayRename(
                    target, requested: cleanName, originalError: error.message,
                    baseURL: baseURL, credential: credential, exclusive: exclusive)
            }
            return await resolveAmbiguousRename(
                target, requested: cleanName, originalError: error.message,
                baseURL: baseURL, credential: credential, retirement: retirement,
                preserved: preserved, exclusive: exclusive,
                roomLifecycleToken: roomLifecycleToken)
        } catch {
            guard changesDirectory else {
                return await resolveAmbiguousDefaultDisplayRename(
                    target, requested: cleanName, originalError: error.localizedDescription,
                    baseURL: baseURL, credential: credential, exclusive: exclusive)
            }
            return await resolveAmbiguousRename(
                target, requested: cleanName, originalError: error.localizedDescription,
                baseURL: baseURL, credential: credential, retirement: retirement,
                preserved: preserved, exclusive: exclusive,
                roomLifecycleToken: roomLifecycleToken)
        }

        let canonical = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty else {
            if changesDirectory {
                return await resolveAmbiguousRename(
                    target, requested: cleanName,
                    originalError: "Hermes returned an empty profile name.",
                    baseURL: baseURL, credential: credential, retirement: retirement,
                    preserved: preserved, exclusive: exclusive,
                    roomLifecycleToken: roomLifecycleToken)
            }
            return await resolveAmbiguousDefaultDisplayRename(
                target, requested: cleanName,
                originalError: "Hermes returned an empty profile name.",
                baseURL: baseURL, credential: credential, exclusive: exclusive)
        }
        // `default` is presentation-only and must keep the same canonical route.
        if !changesDirectory {
            guard canonical == target.route.profile, result.displayName == cleanName else {
                return await resolveAmbiguousDefaultDisplayRename(
                    target, requested: cleanName,
                    originalError: "Hermes returned an inconsistent default-profile rename result.",
                    baseURL: baseURL, credential: credential, exclusive: exclusive)
            }
            guard resumeDurableComposerQueueForLifecycle(route: target.route) else {
                ProfileLifecycleRuntime.shared.heldGateways.insert(target.route.gatewayID)
                return .refused("The default profile changed, but queued prompts remain parked because local storage could not resume them.")
            }
            A2ARuntime.shared.restoreProfileRoute(
                target.route, sourceBotIDs: profileLifecycleSourceIDs(target))
            ProfileLifecycleRuntime.shared.restore(target.route)
            // Hermes and local route state now agree. End the exclusive
            // filesystem fence before the owner refresh acquires an ordinary
            // transport lease; uncertain outcomes never reach this boundary.
            let recoveryLease = exclusive.finishAuthoritativeReconciliation()
            await refreshProfileRoster(gatewayID: target.route.gatewayID)
            await recoveryLease.release()
            rearmDeferredRoomProfileWork()
            return .renamed(canonicalName: canonical, displayName: result.displayName)
        }
        guard canonical != target.route.profile,
              ProfileNamePolicy.validatesNamedProfile(canonical) else {
            return await resolveAmbiguousRename(
                target, requested: cleanName,
                originalError: "Hermes did not return a valid changed canonical profile name.",
                baseURL: baseURL, credential: credential, retirement: retirement,
                preserved: preserved, exclusive: exclusive,
                roomLifecycleToken: roomLifecycleToken)
        }
        let destinationRoute = GatewayBotRoute(
            gatewayID: target.route.gatewayID, profile: canonical)
        guard await commitRoomProfileLifecycleIfNeeded(
            roomLifecycleToken, destination: destinationRoute, source: target.route) else {
            holdIndeterminateLifecycle(target)
            return .refused("The profile was renamed remotely, but its room state could not be migrated. The gateway remains fenced until it is verified.")
        }
        guard reconcileProfileRoute(target, canonicalNewName: canonical,
                                    scope: baseURL, preserved: preserved,
                                    restorePrimaryIfUnclaimed:
                                        mayRestoreRetiredPrimary(retirement)) else {
            holdIndeterminateLifecycle(target)
            return .refused("The profile was renamed remotely, but queued prompts remain parked until their durable route is reconciled.")
        }
        let recoveryLease = exclusive.finishAuthoritativeReconciliation()
        await releaseProfileLifecycleFence(gatewayID: target.route.gatewayID,
                                            retirement: retirement, baseURL: baseURL,
                                            credential: credential)
        if !retirement.wasActive {
            await refreshProfileRoster(gatewayID: target.route.gatewayID)
        }
        await recoveryLease.release()
        rearmDeferredRoomProfileWork()
        return .renamed(canonicalName: canonical, displayName: result.displayName)
    }

    /// Delete only after the caller has presented destructive confirmation.
    /// This method deliberately has no name-only overload: every call site
    /// must carry the gateway route captured by that confirmation.
    public func deleteProfile(_ target: ProfileLifecycleTarget,
                              confirmed: Bool) async -> ProfileLifecycleOutcome {
        guard confirmed else { return .refused("Deletion was not confirmed.") }
        guard mode == .live else { return .refused("Connect to a gateway first.") }
        guard target.route.profile != "default" else {
            return .refused("Hermes does not allow deleting the default profile.")
        }
        guard profileLifecycleTarget(rosterID: target.rosterID) == target else {
            return .refused("That profile or gateway changed. Reopen the profile manager.")
        }
        guard let (baseURL, credential) = gatewayRESTContext(gatewayID: target.route.gatewayID)
        else { return .refused("Sign in to that gateway to delete this profile.") }
        guard !ProfileLifecycleRuntime.shared.heldGateways.contains(target.route.gatewayID) else {
            return .refused("That gateway has an unresolved profile change. Verify its profiles outside Talaria, then restart the app before trying again.")
        }
        guard !ConnectionSupervisor.shared.isReconnecting else {
            return .refused("A gateway connection change is already in progress. Try again when it finishes.")
        }
        guard ProfileLifecycleTrafficAdmission.beginLifecycle(target.route.gatewayID)
        else { return .refused("That gateway is busy with another request or profile change. Try again when it finishes.") }
        AdvancedTerminalCoordinator.shared.stopAndForget(gatewayID: target.route.gatewayID)
        let exclusive = ProfileLifecycleExclusiveLease(gatewayID: target.route.gatewayID)
        defer { exclusive.releaseIfHeld() }

        // Deletion is a tombstone in RoomRuntime. It is prepared before any
        // disconnect/REST await and is only reopened on a definitive refusal.
        let roomLifecycleToken: RoomProfileLifecycleToken
        do {
            roomLifecycleToken = try await persistRoomProfileLifecycleFence(
                source: target.route, deleting: true)
        } catch {
            return .refused("Room state could not be durably fenced before profile deletion.")
        }
        guard parkDurableComposerQueueForLifecycle(route: target.route) else {
            return .refused("Queued prompts could not be durably parked before profile deletion.")
        }
        let preserved = captureProfileLifecycleState(target)
        parkProfileLifecycleCanonicalState(target)
        parkProfileLifecycleState(target)
        // Deletion has no destination. Retire source-qualified deferred stops
        // before the backend is torn down so they cannot reach a replacement
        // profile if the id is later reused.
        abortProfileRuntime(target)
        let retirement = await retireProfileLifecycleClient(target.route.gatewayID,
                                                             baseURL: baseURL,
                                                             credential: credential)

        do {
            try await GatewayREST.deleteProfile(baseURL: baseURL, credential: credential,
                                                profile: target.route.profile)
        } catch let error as GatewayError {
            return await resolveAmbiguousDelete(
                target, originalError: error.message, baseURL: baseURL,
                credential: credential, retirement: retirement,
                preserved: preserved, exclusive: exclusive,
                roomLifecycleToken: roomLifecycleToken)
        } catch {
            return await resolveAmbiguousDelete(
                target, originalError: error.localizedDescription, baseURL: baseURL,
                credential: credential, retirement: retirement,
                preserved: preserved, exclusive: exclusive,
                roomLifecycleToken: roomLifecycleToken)
        }

        guard reconcileProfileRoute(target, canonicalNewName: nil,
                                    scope: baseURL, preserved: preserved,
                                    restorePrimaryIfUnclaimed:
                                        mayRestoreRetiredPrimary(retirement)) else {
            holdIndeterminateLifecycle(target)
            return .refused("The profile was deleted remotely, but queued prompts remain parked until their durable cleanup is reconciled.")
        }
        do {
            try await commitRoomProfileRemoval(roomLifecycleToken)
        } catch {
            await failClosedRoomProfileRoute(target.route)
            holdIndeterminateLifecycle(target)
            return .refused("The profile was deleted remotely, but its room tombstone could not be committed. The gateway remains fenced until it is verified.")
        }
        let recoveryLease = exclusive.finishAuthoritativeReconciliation()
        await releaseProfileLifecycleFence(gatewayID: target.route.gatewayID,
                                            retirement: retirement, baseURL: baseURL,
                                            credential: credential)
        if !retirement.wasActive {
            await refreshProfileRoster(gatewayID: target.route.gatewayID)
        }
        await recoveryLease.release()
        rearmDeferredRoomProfileWork()
        return .deleted
    }

    /// RoomStore migration is part of the authoritative rename boundary. If
    /// it cannot commit after Hermes has accepted the rename, tombstone the
    /// source route instead of reopening it or publishing a partially moved
    /// destination. The caller keeps the profile lifecycle fenced so a later
    /// verification can reconcile both stores together.
    private func commitRoomProfileLifecycleIfNeeded(
        _ token: RoomProfileLifecycleToken?, destination: GatewayBotRoute,
        source: GatewayBotRoute
    ) async -> Bool {
        guard let token else { return true }
        do {
            try await commitRoomProfileRename(token, destination: destination)
            return true
        } catch {
            _ = prepareRoomProfileLifecycle(source: source, deleting: true)
            await failClosedRoomProfileRoute(source)
            return false
        }
    }

    private func resolveAmbiguousRename(
        _ target: ProfileLifecycleTarget, requested: String, originalError: String,
        baseURL: URL, credential: GatewayCredential,
        retirement: ProfileLifecycleRetirement,
        preserved: ProfileLifecyclePreservedState,
        exclusive: ProfileLifecycleExclusiveLease,
        roomLifecycleToken: RoomProfileLifecycleToken?
    ) async -> ProfileLifecycleOutcome {
        let names = try? await GatewayREST.profileNames(baseURL: baseURL, credential: credential)
        let verdict = names.map {
            ProfileLifecyclePostcondition.rename(names: $0, source: target.route.profile,
                                                 destination: requested)
        } ?? .indeterminate
        switch verdict {
        case .committed:
            let destinationRoute = GatewayBotRoute(
                gatewayID: target.route.gatewayID, profile: requested)
            guard await commitRoomProfileLifecycleIfNeeded(
                roomLifecycleToken, destination: destinationRoute, source: target.route) else {
                holdIndeterminateLifecycle(target)
                return .refused("The profile was renamed remotely, but its room state could not be migrated. The gateway remains fenced until it is verified.")
            }
            guard reconcileProfileRoute(target, canonicalNewName: requested, scope: baseURL,
                                        preserved: preserved,
                                        restorePrimaryIfUnclaimed:
                                            mayRestoreRetiredPrimary(retirement)) else {
                holdIndeterminateLifecycle(target)
                return .refused("The profile was renamed remotely, but queued prompts remain parked until their durable route is reconciled.")
            }
            let recoveryLease = exclusive.finishAuthoritativeReconciliation()
            await releaseProfileLifecycleFence(gatewayID: target.route.gatewayID,
                                                retirement: retirement, baseURL: baseURL,
                                                credential: credential)
            if !retirement.wasActive {
                await refreshProfileRoster(gatewayID: target.route.gatewayID)
            }
            await recoveryLease.release()
            rearmDeferredRoomProfileWork()
            return .renamed(canonicalName: requested, displayName: nil)
        case .notCommitted:
            if let roomLifecycleToken {
                await abortRoomProfileLifecycle(roomLifecycleToken)
            }
            guard resumeDurableComposerQueueForLifecycle(route: target.route) else {
                ProfileLifecycleRuntime.shared.heldGateways.insert(target.route.gatewayID)
                return .refused("The profile rename was not committed, but queued prompts remain parked because local storage could not resume them.")
            }
            let restorePrimary = mayRestoreRetiredPrimary(retirement)
            restoreParkedProfileLifecycleCanonicalStateIfNeeded(
                target, preferPrimary: restorePrimary)
            restoreParkedProfileLifecycleStateIfNeeded(target, wasActive: restorePrimary)
            A2ARuntime.shared.restoreProfileRoute(
                target.route, sourceBotIDs: profileLifecycleSourceIDs(target))
            ProfileLifecycleRuntime.shared.restore(target.route)
            let recoveryLease = exclusive.finishAuthoritativeReconciliation()
            await releaseProfileLifecycleFence(gatewayID: target.route.gatewayID,
                                                retirement: retirement, baseURL: baseURL,
                                                credential: credential)
            await recoveryLease.release()
            rearmDeferredRoomProfileWork()
            return .refused(originalError)
        case .indeterminate:
            ProfileLifecycleRuntime.shared.pendingCanonicalPinParking[target.route] = nil
            holdIndeterminateLifecycle(target)
            return .refused("\(originalError) The profile result is uncertain, so this gateway remains fenced and queued work for that profile was quarantined.")
        }
    }

    private func resolveAmbiguousDefaultDisplayRename(
        _ target: ProfileLifecycleTarget, requested: String, originalError: String,
        baseURL: URL, credential: GatewayCredential,
        exclusive: ProfileLifecycleExclusiveLease
    ) async -> ProfileLifecycleOutcome {
        let inventory = try? await GatewayREST.profileInventory(
            baseURL: baseURL, credential: credential)
        let verdict = inventory.map {
            ProfileLifecyclePostcondition.displayRename(
                inventory: $0, source: target.route.profile, requested: requested)
        } ?? .indeterminate
        switch verdict {
        case .committed:
            guard resumeDurableComposerQueueForLifecycle(route: target.route) else {
                ProfileLifecycleRuntime.shared.heldGateways.insert(target.route.gatewayID)
                return .refused("The default profile changed, but queued prompts remain parked because local storage could not resume them.")
            }
            A2ARuntime.shared.restoreProfileRoute(
                target.route, sourceBotIDs: profileLifecycleSourceIDs(target))
            ProfileLifecycleRuntime.shared.restore(target.route)
            let recoveryLease = exclusive.finishAuthoritativeReconciliation()
            await refreshProfileRoster(gatewayID: target.route.gatewayID)
            await recoveryLease.release()
            rearmDeferredRoomProfileWork()
            return .renamed(canonicalName: target.route.profile, displayName: requested)
        case .notCommitted:
            guard resumeDurableComposerQueueForLifecycle(route: target.route) else {
                ProfileLifecycleRuntime.shared.heldGateways.insert(target.route.gatewayID)
                return .refused("The default profile rename was not committed, but queued prompts remain parked because local storage could not resume them.")
            }
            A2ARuntime.shared.restoreProfileRoute(
                target.route, sourceBotIDs: profileLifecycleSourceIDs(target))
            ProfileLifecycleRuntime.shared.restore(target.route)
            let recoveryLease = exclusive.finishAuthoritativeReconciliation()
            await recoveryLease.release()
            rearmDeferredRoomProfileWork()
            return .refused(originalError)
        case .indeterminate:
            ProfileLifecycleRuntime.shared.heldGateways.insert(target.route.gatewayID)
            return .refused("\(originalError) The default profile's display name is uncertain, so profile-owned work on this route remains fenced until the gateway is verified and Talaria restarts.")
        }
    }

    private func resolveAmbiguousDelete(
        _ target: ProfileLifecycleTarget, originalError: String,
        baseURL: URL, credential: GatewayCredential,
        retirement: ProfileLifecycleRetirement,
        preserved: ProfileLifecyclePreservedState,
        exclusive: ProfileLifecycleExclusiveLease,
        roomLifecycleToken: RoomProfileLifecycleToken
    ) async -> ProfileLifecycleOutcome {
        let names = try? await GatewayREST.profileNames(baseURL: baseURL, credential: credential)
        let verdict = names.map {
            ProfileLifecyclePostcondition.delete(names: $0, source: target.route.profile)
        } ?? .indeterminate
        switch verdict {
        case .committed:
            do {
                try await commitRoomProfileRemoval(roomLifecycleToken)
            } catch {
                await failClosedRoomProfileRoute(target.route)
                holdIndeterminateLifecycle(target)
                return .refused("The profile was deleted remotely, but its room tombstone could not be committed. The gateway remains fenced until it is verified.")
            }
            guard reconcileProfileRoute(target, canonicalNewName: nil, scope: baseURL,
                                        preserved: preserved,
                                        restorePrimaryIfUnclaimed:
                                            mayRestoreRetiredPrimary(retirement)) else {
                holdIndeterminateLifecycle(target)
                return .refused("The profile was deleted remotely, but queued prompts remain parked until their durable cleanup is reconciled.")
            }
            let recoveryLease = exclusive.finishAuthoritativeReconciliation()
            await releaseProfileLifecycleFence(gatewayID: target.route.gatewayID,
                                                retirement: retirement, baseURL: baseURL,
                                                credential: credential)
            if !retirement.wasActive {
                await refreshProfileRoster(gatewayID: target.route.gatewayID)
            }
            await recoveryLease.release()
            rearmDeferredRoomProfileWork()
            return .deleted
        case .notCommitted:
            await abortRoomProfileLifecycle(roomLifecycleToken)
            guard resumeDurableComposerQueueForLifecycle(route: target.route) else {
                ProfileLifecycleRuntime.shared.heldGateways.insert(target.route.gatewayID)
                return .refused("The profile deletion was not committed, but queued prompts remain parked because local storage could not resume them.")
            }
            let restorePrimary = mayRestoreRetiredPrimary(retirement)
            restoreParkedProfileLifecycleCanonicalStateIfNeeded(
                target, preferPrimary: restorePrimary)
            restoreParkedProfileLifecycleStateIfNeeded(target, wasActive: restorePrimary)
            A2ARuntime.shared.restoreProfileRoute(
                target.route, sourceBotIDs: profileLifecycleSourceIDs(target))
            ProfileLifecycleRuntime.shared.restore(target.route)
            let recoveryLease = exclusive.finishAuthoritativeReconciliation()
            await releaseProfileLifecycleFence(gatewayID: target.route.gatewayID,
                                                retirement: retirement, baseURL: baseURL,
                                                credential: credential)
            await recoveryLease.release()
            rearmDeferredRoomProfileWork()
            return .refused(originalError)
        case .indeterminate:
            ProfileLifecycleRuntime.shared.pendingCanonicalPinParking[target.route] = nil
            holdIndeterminateLifecycle(target)
            return .refused("\(originalError) The profile result is uncertain, so this gateway remains fenced and queued work for that profile was quarantined.")
        }
    }

    private func holdIndeterminateLifecycle(_ target: ProfileLifecycleTarget) {
        ProfileLifecycleRuntime.shared.heldGateways.insert(target.route.gatewayID)
        let sources: Set = [target.route.qualifiedID]
        ProfileLifecycleQueue.reconcile(&composeQueue, sources: sources, destination: nil)
        reconcileComposeQueueIDs(sources: sources, destination: nil)
        if target.route.gatewayID == LiveRuntime.shared.gatewayID || client == nil {
            isOffline = true
        }
    }

    private func captureProfileLifecycleState(_ target: ProfileLifecycleTarget)
        -> ProfileLifecyclePreservedState {
        let route = target.route
        let routed = MultiGatewayRuntime.shared.routedUnread[route] ?? 0
        let visible = unionRosterBots.first(where: { $0.id == target.rosterID })?.unread ?? 0
        return ProfileLifecyclePreservedState(
            portrait: ProfileAssetStore.shared.portrait(for: route.qualifiedID),
            unread: max(routed, visible))
    }

    /// Canonical-chat metadata is keyed by the roster id rather than carrying
    /// a route alongside the value. Resolve only the exact source ids that
    /// belong to this lifecycle operation; in particular, a secondary
    /// profile must never borrow the primary gateway's bare `profile` key.
    private func profileLifecycleSourceIDs(_ target: ProfileLifecycleTarget) -> Set<String> {
        var ids: Set<String> = [target.route.qualifiedID]
        if target.rosterID == target.route.profile,
           LiveRuntime.shared.gatewayID == target.route.gatewayID {
            ids.insert(target.route.profile)
        }
        return ids
    }

    /// Remove canonical route bookkeeping before the profile directory is
    /// touched. The server registry is not portable client state; an in-flight
    /// kickoff is route-owned because Hermes tears down its old
    /// session/backend as part of the rename and must therefore be retired.
    internal func parkProfileLifecycleCanonicalState(_ target: ProfileLifecycleTarget) {
        let runtime = CanonicalChatRuntime.shared
        let sourceIDs = profileLifecycleSourceIDs(target)
        for source in sourceIDs {
            LiveRuntime.shared.canonicalSessionByBot.removeValue(forKey: source)
            runtime.opens.removeValue(forKey: source)?.cancel()
            let retired: Bool
            if let lease = runtime.kickoffLeases[source]
                ?? runtime.ambiguousKickoffs[source],
               let chat = chats[source],
               let storedID = chat.storedSessionID {
                retired = runtime.retireKickoff(
                    botID: source, route: target.route,
                    storedID: storedID,
                    chatID: ObjectIdentifier(chat), operationID: lease.id)
            } else {
                retired = false
            }
            guard retired else { continue }
        }
        ProfileLifecycleRuntime.shared.pendingCanonicalPinParking[target.route] =
            ProfileLifecyclePendingCanonicalPinParking(sourceIDs: sourceIDs)
    }

    /// Release the canonical lifecycle fence before normal reconciliation.
    private func restoreParkedProfileLifecycleCanonicalState(
        _ target: ProfileLifecycleTarget, destinationID: String?
    ) {
        _ = destinationID
        ProfileLifecycleRuntime.shared.pendingCanonicalPinParking
            .removeValue(forKey: target.route)
    }

    /// A refused mutation releases only the captured route's canonical fence.
    internal func restoreParkedProfileLifecycleCanonicalStateIfNeeded(
        _ target: ProfileLifecycleTarget, preferPrimary: Bool
    ) {
        _ = preferPrimary
        ProfileLifecycleRuntime.shared.pendingCanonicalPinParking
            .removeValue(forKey: target.route)
    }

    /// Before the first suspension, move a primary profile's portable state
    /// off its collision-prone bare key. The user may switch gateways while
    /// disconnect or REST is awaiting; from this point onward the mutation
    /// owns only the source-qualified key captured by `target`.
    internal func parkProfileLifecycleState(_ target: ProfileLifecycleTarget) {
        guard LiveRuntime.shared.gatewayID == target.route.gatewayID,
              GatewayBotRoute(qualifiedID: target.rosterID) == nil else { return }
        let source = target.route.profile
        let destination = target.route.qualifiedID
        guard source != destination else { return }

        if let summary = LiveRuntime.shared.canonicalSessionByBot.removeValue(forKey: source) {
            LiveRuntime.shared.canonicalSessionByBot[destination] = summary
        }

        // `disconnectGateway` intentionally clears every pending stop for the
        // departing gateway. Capture only this exact primary ChatState before
        // that scrub; sibling profile intents are never carried into the
        // renamed destination.
        if let chat = chats[source] {
            parkProfileLifecyclePendingStop(target, source: source,
                                             destination: destination, chat: chat)
        }

        rekeyProfileLifecyclePortableState(target, from: source, to: destination)
    }

    /// A failed mutation may reconnect the same gateway as primary. Move the
    /// parked state back only when no different gateway claimed the primary
    /// role during the await; otherwise its qualified identity remains the
    /// sole safe owner.
    internal func restoreParkedProfileLifecycleStateIfNeeded(
        _ target: ProfileLifecycleTarget, wasActive: Bool
    ) {
        let current = LiveRuntime.shared.gatewayID
        guard current == target.route.gatewayID || (current == nil && wasActive) else { return }
        rekeyProfileLifecyclePortableState(target, from: target.route.qualifiedID,
                                           to: target.route.profile)
        migrateRetainedProfileMutationFences(
            fromBotIDs: [target.route.qualifiedID], fromRoute: target.route,
            toBotID: target.route.profile, toRoute: target.route)
    }

    /// Restore the target stop after a primary retirement disconnect. The
    /// caller chooses the parked qualified key for a still-unresolved/committed
    /// route, or the original bare key when a refused mutation is returned to
    /// the same primary owner.
    internal func restoreProfileLifecyclePendingStop(
        _ target: ProfileLifecycleTarget, parked: Bool
    ) {
        guard let parking = ProfileLifecycleRuntime.shared.pendingStopParking
            .removeValue(forKey: target.route) else { return }
        let botID = parked ? parking.parkedBotID : parking.originalBotID
        var pending = parking.pending
        pending.botID = botID
        if let existing = ChatRuntime.shared.pendingStopRequests[botID],
           existing != pending {
            // A replacement owns this key already. Keep it untouched and
            // retire the parked intent rather than cross-delivering a stop.
            return
        }
        ChatRuntime.shared.pendingStopRequests[botID] = pending
    }

    private func parkProfileLifecyclePendingStop(
        _ target: ProfileLifecycleTarget, source: String, destination: String,
        chat: ChatState
    ) {
        let runtime = ProfileLifecycleRuntime.shared
        guard runtime.pendingStopParking[target.route] == nil else { return }
        let sourceIDs = Set([source, destination])
        let chatID = ObjectIdentifier(chat)
        let candidates = ChatRuntime.shared.pendingStopRequests.filter { key, pending in
            sourceIDs.contains(key)
                && pending.route == target.route
                && pending.chatID == chatID
                && ChatRuntime.sameDurable(pending.storedID, chat.storedSessionID)
        }
        if ChatRuntime.shared.pendingStopRequests[destination] != nil,
           !candidates.contains(where: { $0.key == destination }) {
            let stale = ChatRuntime.shared.pendingStopRequests.compactMap { key, pending in
                sourceIDs.contains(key) && pending.route == target.route ? key : nil
            }
            for key in stale { ChatRuntime.shared.pendingStopRequests[key] = nil }
            return
        }
        guard candidates.count == 1, let (originalBotID, pending) = candidates.first else {
            // Any source-route entry that cannot prove this exact ChatState or
            // durable row is stale; fail closed before the disconnect scrub.
            let stale = ChatRuntime.shared.pendingStopRequests.compactMap { key, pending in
                sourceIDs.contains(key) && pending.route == target.route ? key : nil
            }
            for key in stale { ChatRuntime.shared.pendingStopRequests[key] = nil }
            return
        }
        runtime.pendingStopParking[target.route] = ProfileLifecyclePendingStopParking(
            originalBotID: originalBotID, parkedBotID: destination, pending: pending)
    }

    private func rekeyProfileLifecyclePortableState(
        _ target: ProfileLifecycleTarget, from source: String, to destination: String
    ) {
        guard source != destination else { return }

        // Primary profile state is parked under its qualified route before
        // the gateway disconnect. Move every durable queue mirror with that
        // alias first; a later profile rename can then migrate the qualified
        // owner to its committed destination. Unknown durable bindings are
        // retired rather than allowed to follow a reused profile name.
        let queueRuntime = ChatRuntime.shared
        var queueCandidates: [(sessionID: String, storedID: String?)] = []
        for binding in queueRuntime.queuedBindings.values where
            binding.botID == source && binding.route == target.route {
            queueCandidates.append((binding.sessionID, binding.storedID))
        }
        for session in queueRuntime.queuedLifecycles.keys where
            session.botID == source && session.route == target.route {
            queueCandidates.append((session.sessionID, session.storedID))
        }
        for session in queueRuntime.pendingQueuedSubmissions.keys where
            session.botID == source && session.route == target.route {
            queueCandidates.append((session.sessionID, session.storedID))
        }
        var migratedQueueKeys = Set<String>()
        for candidate in queueCandidates {
            let key = candidate.sessionID + "\u{0}" + (candidate.storedID ?? "")
            guard migratedQueueKeys.insert(key).inserted else { continue }
            guard let storedID = candidate.storedID, !storedID.isEmpty,
                  !candidate.sessionID.isEmpty else {
                // An absent durable key cannot prove ownership of a queue
                // row across a profile directory mutation. Leave it parked
                // under the old route for quarantine/recovery; deleting it
                // here would turn missing identity into a false success.
                continue
            }
            _ = migrateQueuedState(
                fromBotID: source, toBotID: destination, route: target.route,
                oldSessionID: candidate.sessionID, newSessionID: candidate.sessionID,
                storedID: storedID)
        }

        if let chat = chats[source] {
            _ = ChatRuntime.shared.rekeyStopMutation(
                fromBotID: source, toBotID: destination, route: target.route,
                chatID: ObjectIdentifier(chat), storedID: chat.storedSessionID)
            _ = ChatRuntime.shared.movePendingStopBindingKey(
                fromBotID: source, toBotID: destination, route: target.route,
                chatID: ObjectIdentifier(chat), storedID: chat.storedSessionID)
        }

        ProfileLifecycleCache.moveFirst(&chats, from: [source], to: destination)
        ProfileLifecycleCache.moveFirst(&memory, from: [source], to: destination)
        ProfileLifecycleCache.moveFirst(&sessions, from: [source], to: destination)
        ProfileLifecycleQueue.reconcile(&composeQueue, sources: [source],
                                        destination: destination)
        reconcileComposeQueueIDs(sources: [source], destination: destination)
        if openBotID == source { openBotID = destination }
        for day in activity.indices {
            for item in activity[day].items.indices where activity[day].items[item].botID == source {
                activity[day].items[item].botID = destination
            }
        }
        for index in agentInbox.indices {
            if agentInbox[index].fromBotID == source { agentInbox[index].fromBotID = destination }
            if agentInbox[index].toBotID == source { agentInbox[index].toBotID = destination }
        }
        for index in artifacts.indices where artifacts[index].botID == source {
            artifacts[index].botID = destination
        }
        for index in routines.indices where routines[index].botID == source {
            routines[index].botID = destination
        }
        for index in approvals.indices where approvals[index].botID == source {
            approvals[index].botID = destination
        }

        let runtime = LiveRuntime.shared
        runtime.sessionToBot = runtime.sessionToBot.mapValues {
            $0 == source ? destination : $0
        }
        runtime.routedSessionToBot = runtime.routedSessionToBot.mapValues {
            $0 == source ? destination : $0
        }
        if runtime.workingBotIDs.remove(source) != nil {
            runtime.workingBotIDs.insert(destination)
        }
        ProfileLifecycleCache.moveFirst(&runtime.lastSessionByBot,
                                        from: [source], to: destination)
        // Queue mirrors keep the old runtime SID until the destination bind
        // supplies its replacement. The sid is not a valid wire destination
        // after a profile rename; it is only a migration token that prevents
        // the queued rows from becoming orphaned when ChatState is rebound.
        if let parked = runtime.reconnectParkedSessionIDs.removeValue(forKey: source) {
            if let existing = runtime.reconnectParkedSessionIDs[destination],
               existing != parked {
                // A destination owner already has a different parked SID.
                // Leave the source queue quarantined rather than letting this
                // rename inherit B's runtime address.
            } else {
                runtime.reconnectParkedSessionIDs[destination] = parked
            }
        }
        ProfileLifecycleCache.moveFirst(&runtime.attachTasks,
                                        from: [source], to: destination)
        reconcileCanonicalAndSessionCaches(sourceIDs: [source],
                                           destinationID: destination)
        reconcileFeedCaches(target: target.route, sourceIDs: [source],
                            destinationID: destination,
                            canonicalNewName: target.route.profile)
        let visibleUnread = bots.first(where: { $0.id == source })?.unread ?? 0
        if visibleUnread > 0 {
            MultiGatewayRuntime.shared.routedUnread[target.route] = max(
                MultiGatewayRuntime.shared.routedUnread[target.route] ?? 0,
                visibleUnread)
        }
    }

    /// Fence the exact gateway client before Hermes moves/deletes the profile
    /// directory. A pooled secondary has no automatic reconnect; a primary is
    /// deliberately disconnected, which cancels its supervisor before REST.
    private func retireProfileLifecycleClient(_ gatewayID: String, baseURL: URL,
                                              credential: GatewayCredential) async
        -> ProfileLifecycleRetirement {
        // There is no actor suspension between the public preflight check and
        // this claim. Hold the same mutex used by switchGateway across the
        // disconnect await, otherwise B can install itself while A's ordinary
        // disconnect is suspended and then be cleared by A's cleanup.
        precondition(ProfileLifecycleSwitchClaim.acquire(),
                     "profile lifecycle retirement lost its switch claim")
        defer { ProfileLifecycleSwitchClaim.release() }
        let wasActive = gatewayID == LiveRuntime.shared.gatewayID && client != nil
        if wasActive {
            await disconnectGateway()
        }
        let retirementGeneration = wasActive ? LiveRuntime.shared.generation : nil
        // Leave an intentionally disconnected sentinel in the pool. Every
        // routed lookup receives it and fails closed instead of opening a new
        // socket while the old profile directory is between names.
        let sentinel = GatewayClient(baseURL: baseURL, credential: credential)
        // Replace only the transport subscription. A2A route-owned delivery
        // and watcher state is preserved for the postcondition migration.
        await removeRoutedEventSubscription(gatewayID: gatewayID)
        await ConnectionRegistry.shared.clientPool.adopt(sentinel, for: gatewayID)
        return ProfileLifecycleRetirement(
            wasActive: wasActive, connectionGeneration: retirementGeneration)
    }

    /// Rehome a formerly active gateway onto its surviving/default backend.
    /// A failed reconnect intentionally leaves it disconnected; no old-profile
    /// socket remains able to recreate the directory just mutated.
    private func releaseProfileLifecycleFence(gatewayID: String,
                                              retirement: ProfileLifecycleRetirement,
                                              baseURL: URL,
                                              credential: GatewayCredential) async {
        let runtime = LiveRuntime.shared
        let supervisor = ConnectionSupervisor.shared
        guard mayRestoreRetiredPrimary(retirement) else {
            // Remove the disconnected sentinel. The owner-roster refresh is
            // the only operation allowed to redial after a successful change;
            // failures remain disconnected until ordinary demand retries.
            await ConnectionRegistry.shared.clientPool.disconnect(gatewayID: gatewayID)
            return
        }

        // Claim the same switch mutex used by Connections before dialing.
        // This claim is synchronous with the ownership/generation checks, so
        // a user-selected gateway cannot interleave with recovery.
        supervisor.isReconnecting = true
        defer { supervisor.isReconnecting = false }
        let attemptedGeneration = runtime.generation + 1
        do {
            try await connectGateway(baseURL: baseURL, credential: credential)
        } catch {
            // `connectGateway` may have installed its attempted client before
            // throwing. Clear only that exact unclaimed attempt; never a later
            // user-selected gateway.
            if runtime.generation == attemptedGeneration,
               runtime.baseURL?.absoluteString == baseURL.absoluteString,
               (runtime.gatewayID == nil || runtime.gatewayID == gatewayID) {
                // The supervisor mutex still excludes a user switch here, so
                // the ordinary teardown can scrub a partially registered A
                // (including failures after roster refresh began).
                await disconnectGateway()
                isOffline = true
            }
        }
    }

    /// Re-evaluate ownership at the exact reconciliation/recovery point. The
    /// pre-REST fact that A used to be primary is insufficient because a B
    /// switch temporarily has no gateway id while its client is connecting.
    private func mayRestoreRetiredPrimary(
        _ retirement: ProfileLifecycleRetirement
    ) -> Bool {
        let runtime = LiveRuntime.shared
        return ProfileLifecycleRecoveryPolicy.mayRestorePrimary(
            retirement: retirement,
            currentGeneration: runtime.generation,
            currentGatewayID: runtime.gatewayID,
            hasClient: client != nil,
            switchInProgress: ConnectionSupervisor.shared.isReconnecting)
    }

    // MARK: - State reconciliation

    /// Cancel every volatile producer that could publish old-profile state
    /// after the lifecycle fence is raised. The route generation is blocked
    /// before disconnect awaits, so a late socket or task completion cannot
    /// republish the parked state while the owning socket is being retired.
    internal func abortProfileRuntime(_ target: ProfileLifecycleTarget,
                                      preservePendingStop: Bool = false,
                                      preserveQueuedState: Bool = false) {
        ProfileLifecycleRuntime.shared.block(target.route)
        // The transcript worker owns the identity-bearing ChatRuntime lane.
        // Retire the exact route synchronously, before any disconnect/REST
        // await can make a replacement profile directory writable. The local
        // helper below additionally clears presentation and legacy aliases.
        let routeStateIDs = profileLifecycleSourceIDs(target)
        // Capture each mutation before route teardown. A request that has not
        // crossed the wire acceptance boundary is rolled back exactly; one
        // that has crossed it becomes a no-replay fence and remains parked for
        // the postcondition/reconnect path. Clearing the dictionaries first
        // would permit a lifecycle rename/delete to replay an accepted edit
        // or steer against a replacement profile.
        let mutationRollbacks = preserveOrRollbackProfileLifecycleMutations(
            sourceIDs: routeStateIDs)
        retireProfileLifecycleMutationState(
            target, preservePendingStop: preservePendingStop,
            preserveQueuedState: preserveQueuedState)
        if !preservePendingStop {
            ChatRuntime.shared.clearPendingStops(forRoute: target.route)
            ProfileLifecycleRuntime.shared.pendingStopParking[target.route] = nil
        }
        var sourceIDs: Set = [target.route.qualifiedID]
        // This synchronous ownership check is safe: unlike the former caller
        // snapshot, it is never carried across an await. It also keeps this
        // cleanup helper correct when invoked directly before parking.
        if LiveRuntime.shared.gatewayID == target.route.gatewayID,
           GatewayBotRoute(qualifiedID: target.rosterID) == nil {
            sourceIDs.insert(target.route.profile)
        }

        let chatRuntime = ChatRuntime.shared
        for botID in sourceIDs {
            chatRuntime.submitWatchdogs.removeValue(forKey: botID)?.cancel()
            chatRuntime.demoTurns.removeValue(forKey: botID)?.cancel()
            chatRuntime.turnFloor.removeValue(forKey: botID)
            guard let chat = chats[botID] else { continue }
            chat.sessionID = nil
            chat.isRunning = false
            chat.isTyping = false
            for index in chat.messages.indices {
                chat.messages[index].isStreaming = false
                for tool in chat.messages[index].toolCalls.indices
                where chat.messages[index].toolCalls[tool].state == .running {
                    chat.messages[index].toolCalls[tool].state = .failed
                }
            }
        }
        // The scrub above is correct for ordinary stale turns, but a
        // pre-accept transcript/steer was restored to an exact snapshot and
        // must remain byte-for-byte visible after lifecycle teardown.
        for rollback in mutationRollbacks {
            guard let chat = chats.values.first(where: {
                ObjectIdentifier($0) == rollback.chatID
            }) else { continue }
            chat.messages = rollback.messages
            chat.isRunning = rollback.isRunning
            chat.isTyping = rollback.isTyping
        }

        let attachments = AttachmentRuntime.shared
        for botID in sourceIDs {
            guard let chat = chats[botID] else { continue }
            for attachment in chat.attachments { attachments.forget(attachment.id) }
            chat.attachments.removeAll()
        }
        if attachments.chooserBotID.map(sourceIDs.contains) == true { attachments.chooserBotID = nil }
        if attachments.photoBotID.map(sourceIDs.contains) == true { attachments.photoBotID = nil }
        if attachments.fileBotID.map(sourceIDs.contains) == true { attachments.fileBotID = nil }

        let liveness = LivenessRuntime.shared
        for botID in sourceIDs {
            liveness.settledSince.removeValue(forKey: botID)
            liveness.unverifiableSince.removeValue(forKey: botID)
        }

        let live = LiveRuntime.shared
        var affectedSessions = Set(live.sessionToBot.compactMap { sid, botID in
            sourceIDs.contains(botID)
                ? GatewaySessionRoute(gatewayID: target.route.gatewayID, sessionID: sid) : nil
        })
        affectedSessions.formUnion(live.routedSessionToBot.compactMap { route, botID in
            sourceIDs.contains(botID) ? route : nil
        })
        // These live identity maps can outlive a secondary client sentinel;
        // retire them before the profile REST call so a late event/attach
        // cannot repopulate the source route while its directory is changing.
        live.sessionToBot = live.sessionToBot.filter { !sourceIDs.contains($0.value) }
        live.routedSessionToBot = live.routedSessionToBot.filter { !sourceIDs.contains($0.value) }
        live.workingBotIDs.subtract(sourceIDs)
        live.lastSessionByBot = live.lastSessionByBot.filter {
            !sourceIDs.contains($0.key)
        }
        if !preserveQueuedState {
            live.reconnectParkedSessionIDs = live.reconnectParkedSessionIDs.filter {
                !sourceIDs.contains($0.key)
            }
        }
        let attachTasks = live.attachTasks.filter { sourceIDs.contains($0.key) }
        for task in attachTasks.values { task.cancel() }
        for key in attachTasks.keys { live.attachTasks.removeValue(forKey: key) }
        let staleTargets = live.approvalTargets.compactMap { key, value in
            sourceIDs.contains(value.bot.qualifiedID) || value.bot == target.route ? key : nil
        }
        for key in staleTargets { live.approvalTargets.removeValue(forKey: key) }
        let approvalIDs = Set(approvals.compactMap { sourceIDs.contains($0.botID) ? $0.id : nil })
        let bridges = ApprovalBridges.shared
        bridges.prompts.removeAll { prompt in
            prompt.gatewayID == target.route.gatewayID
                && (prompt.botID.map(sourceIDs.contains) == true
                    || affectedSessions.contains(GatewaySessionRoute(
                        gatewayID: prompt.gatewayID, sessionID: prompt.sessionID)))
        }
        for id in approvalIDs {
            bridges.details.removeValue(forKey: id)
            bridges.decided.removeValue(forKey: id)
        }
        let approvalPrefix = GatewayApprovalRoute.qualifiedPrefix(
            gatewayID: target.route.gatewayID)
        let affectedSessionIDs = Set(affectedSessions.map(\.sessionID))
        let recoveredApprovalIDs = bridges.details.compactMap { id, detail in
            id.hasPrefix(approvalPrefix) && affectedSessionIDs.contains(detail.request.sessionID)
                ? id : nil
        }
        for id in recoveredApprovalIDs {
            bridges.details.removeValue(forKey: id)
            bridges.decided.removeValue(forKey: id)
        }
        bridges.sweptSessions.subtract(affectedSessions)
        bridges.sweepFailures = bridges.sweepFailures.filter { !affectedSessions.contains($0.key) }
        bridges.resetSweepScope(gatewayID: target.route.gatewayID)

        // A2A owns both recipient and sender route identity. Preserve accepted
        // handoffs while a rename is unresolved so the commit hook can migrate
        // them; delete retires them. The runtime also bumps its exact route
        // generation, fencing late canonical/watch completions independently
        // of sibling profiles on this gateway.
        A2ARuntime.shared.retireProfileRoute(
            target.route, sourceBotIDs: profileLifecycleSourceIDs(target),
            preserveForRename: preservePendingStop && preserveQueuedState)
    }

    /// Retire every ChatRuntime mutation whose authority is the captured
    /// source route. These dictionaries are intentionally not cleared by a
    /// gateway-wide disconnect: sibling profiles may share that transport.
    /// Profile lifecycle is the narrow operation that knows the exact route,
    /// and it performs this synchronous scrub before Hermes can make a
    /// replacement directory writable.
    private func preserveOrRollbackProfileLifecycleMutations(
        sourceIDs: Set<String>
    ) -> [ProfileLifecycleMutationRollback] {
        let runtime = ChatRuntime.shared
        var rollbacks: [ProfileLifecycleMutationRollback] = []

        // Transcript leases carry the complete pre-optimistic projection.
        // The UUID-only map remains for admission compatibility, but the
        // lease is the only safe way to decide whether a request crossed its
        // acceptance boundary.
        let transcriptLeases = runtime.transcriptLeases.filter {
            sourceIDs.contains($0.key)
        }
        for (botID, lease) in transcriptLeases {
            guard runtime.transcriptActions[botID] == lease.id else {
                runtime.transcriptLeases[botID] = nil
                continue
            }
            if lease.submitStarted {
                fenceTranscriptActionIfDurableTargetStillOwned(lease)
            } else {
                _ = restoreTranscriptActionOptimisticIfOwned(lease)
                if let chat = chats.values.first(where: {
                    ObjectIdentifier($0) == lease.chatID
                }) {
                    rollbacks.append(ProfileLifecycleMutationRollback(
                        chatID: lease.chatID, messages: chat.messages,
                        isRunning: chat.isRunning, isTyping: chat.isTyping))
                }
            }
            runtime.transcriptActions[botID] = nil
            runtime.transcriptActionGenerations[botID] = nil
            runtime.transcriptLeases[botID] = nil
        }

        // A steer's `requestStarted` flips immediately before the first wire
        // verb. Before that point removing its optimistic row is definitive;
        // afterwards the old route must retain a fence even if lifecycle
        // teardown cancels the worker.
        let steerLeases = runtime.steerActions.filter {
            sourceIDs.contains($0.key)
        }
        for (botID, lease) in steerLeases {
            guard runtime.steerActions[botID]?.id == lease.id else { continue }
            if lease.requestStarted {
                fenceSteerMutationIfOwned(lease)
            } else {
                _ = restoreSteerMutationOptimisticIfOwned(lease)
                if let chat = chats.values.first(where: {
                    ObjectIdentifier($0) == lease.chatID
                }) {
                    rollbacks.append(ProfileLifecycleMutationRollback(
                        chatID: lease.chatID, messages: chat.messages,
                        isRunning: chat.isRunning, isTyping: chat.isTyping))
                }
            }
            runtime.steerActions[botID] = nil
        }

        // Existing fences are already accepted-unknown operations. Keep them
        // attached to the captured source key; reconcileProfileRoute rekeys
        // them only after Hermes' rename postcondition commits.
        return rollbacks
    }

    private func retireProfileLifecycleMutationState(
        _ target: ProfileLifecycleTarget, preservePendingStop: Bool,
        preserveQueuedState: Bool
    ) {
        let runtime = ChatRuntime.shared
        let sourceIDs = profileLifecycleSourceIDs(target)
        let route = target.route

        runtime.transcriptActions = runtime.transcriptActions.filter {
            !sourceIDs.contains($0.key)
        }
        runtime.transcriptActionGenerations = runtime.transcriptActionGenerations.filter {
            !sourceIDs.contains($0.key)
        }
        runtime.transcriptLeases = runtime.transcriptLeases.filter {
            !sourceIDs.contains($0.key)
        }
        // transcriptFences/steerFences are intentionally retained: they are
        // accepted-unknown mutations captured above (or before this
        // lifecycle) and must not be replayed into a replacement binding.

        runtime.steerActions = runtime.steerActions.filter {
            !sourceIDs.contains($0.key) && $0.value.route != route
        }
        if !(preservePendingStop && preserveQueuedState) {
            runtime.stopActions = runtime.stopActions.filter {
                !sourceIDs.contains($0.key) && $0.value.route != route
            }
            runtime.stopFences = runtime.stopFences.filter {
                !sourceIDs.contains($0.key)
                    && ($0.value.unaddressable || $0.value.route != route)
            }
        }

        let tasks = runtime.reconciliationTasks.filter { sourceIDs.contains($0.key) }
        for task in tasks.values { task.cancel() }
        for key in tasks.keys {
            runtime.reconciliationTasks.removeValue(forKey: key)
            runtime.reconciliationTokens.removeValue(forKey: key)
        }
        // A canceled task can already have consumed its task entry while its
        // token remains as the stale completion fence; retire that token by
        // route as well rather than relying on the task dictionary's shape.
        runtime.reconciliationTokens = runtime.reconciliationTokens.filter {
            !sourceIDs.contains($0.key)
        }
        runtime.reconcilingBots.subtract(sourceIDs)
        runtime.deferredReconciliationBots.subtract(sourceIDs)
        if !preservePendingStop { runtime.clearPendingStops(forRoute: route) }

        // Queue mirrors have an AppModel-owned presentation half. A rename
        // parks them until its committed route migration; a delete (or an
        // explicitly unpreservable binding) removes the exact visible rows
        // and identity-bearing side tables together.
        if !preserveQueuedState {
            for source in sourceIDs {
                var storedIDs = Set<String?>()
                for binding in runtime.queuedBindings.values where
                    binding.botID == source && binding.route == route {
                    storedIDs.insert(binding.storedID)
                }
                for session in runtime.queuedLifecycles.keys where
                    session.botID == source && session.route == route {
                    storedIDs.insert(session.storedID)
                }
                for session in runtime.pendingQueuedSubmissions.keys where
                    session.botID == source && session.route == route {
                    storedIDs.insert(session.storedID)
                }
                for storedID in storedIDs where storedID?.isEmpty == false {
                    _ = retireQueuedState(botID: source, route: route, storedID: storedID)
                }
            }
        }

        // Kickoff state has no valid destination after Hermes tears down the
        // source directory. Pins are parked separately before this helper is
        // reached; only the in-flight operation itself is retired here.
        let canonical = CanonicalChatRuntime.shared
        for source in sourceIDs {
            canonical.opens.removeValue(forKey: source)?.cancel()
            let retired: Bool
            if let lease = canonical.kickoffLeases[source]
                ?? canonical.ambiguousKickoffs[source],
               let chat = chats[source],
               let storedID = chat.storedSessionID {
                retired = canonical.retireKickoff(
                    botID: source, route: target.route,
                    storedID: storedID,
                    chatID: ObjectIdentifier(chat), operationID: lease.id)
            } else {
                retired = false
            }
            guard retired else { continue }
        }
    }

    /// Re-key portable user state on rename and scrub it on delete. Runtime
    /// session/approval bindings are never transferred: Hermes tears down the
    /// old-name backend before changing its directory, so those wire ids are
    /// invalid after either operation and must fail closed.
    private func reconcileProfileRoute(_ target: ProfileLifecycleTarget,
                                       canonicalNewName: String?, scope: URL,
                                       preserved: ProfileLifecyclePreservedState,
                                       restorePrimaryIfUnclaimed: Bool) -> Bool {
        let destinationRoute = canonicalNewName.map {
            GatewayBotRoute(gatewayID: target.route.gatewayID, profile: $0)
        }
        do {
            try commitDurableComposerQueueLifecycle(
                from: target.route, to: destinationRoute)
        } catch {
            // Hermes has already changed the source, but no local row may be
            // replayed into its replacement. Leave the parked source envelope
            // intact and let the caller keep the lifecycle authority fenced.
            return false
        }
        let currentPrimaryGatewayID = LiveRuntime.shared.gatewayID
        let plan = ProfileLifecycleStatePlan(target: target,
                                             canonicalNewName: canonicalNewName,
                                             currentPrimaryGatewayID: currentPrimaryGatewayID,
                                             restorePrimaryIfUnclaimed: restorePrimaryIfUnclaimed)
        let sourceIDs = Set(plan.sourceIDs)
        // A primary ChatState is parked under its qualified key before the
        // gateway retirement, but accepted-unknown fences may still have
        // been captured under the original bare owner. Retain that exact
        // source key for fence migration/scrubbing; a secondary route must
        // never borrow another gateway's bare profile name.
        var retainedSourceIDs = sourceIDs
        if target.rosterID == target.route.profile {
            retainedSourceIDs.insert(target.route.profile)
        }
        if let destinationID = plan.destinationID, let canonicalNewName {
            let destinationRoute = GatewayBotRoute(
                gatewayID: target.route.gatewayID, profile: canonicalNewName)
            A2ARuntime.shared.migrateProfileRoute(
                from: target.route, to: destinationRoute,
                sourceBotIDs: sourceIDs, destinationBotID: destinationID)
        } else {
            A2ARuntime.shared.retireProfileRoute(
                target.route, sourceBotIDs: sourceIDs)
        }
        let sourceChat = plan.sourceIDs.first.flatMap { chats[$0] }
        if let destinationID = plan.destinationID,
           let canonicalNewName,
           let sourceChat,
           let storedID = sourceChat.storedSessionID,
           !storedID.isEmpty,
           let oldSessionID = sourceChat.sessionID
                ?? LiveRuntime.shared.reconnectParkedSessionIDs[plan.sourceIDs[0]],
           !oldSessionID.isEmpty {
            // This is deliberately before any cache can publish the new
            // profile key. ChatRuntime migrates only an exact ChatState/
            // durable-row owner; a collision retires the source state.
            let destinationRoute = GatewayBotRoute(
                gatewayID: target.route.gatewayID, profile: canonicalNewName)
            // ChatRuntime owns the identity-bearing queue mirrors, while the
            // visible prompt rows live on AppModel. Capture their exact ids
            // before the route migration so the presentation half follows
            // the same owner and cannot remain under the retired bot key.
            var queuedStoredIDs = Set<String?>()
            for binding in ChatRuntime.shared.queuedBindings.values where
                binding.botID == plan.sourceIDs[0] && binding.route == target.route {
                queuedStoredIDs.insert(binding.storedID)
            }
            for session in ChatRuntime.shared.queuedLifecycles.keys where
                session.botID == plan.sourceIDs[0] && session.route == target.route {
                queuedStoredIDs.insert(session.storedID)
            }
            for session in ChatRuntime.shared.pendingQueuedSubmissions.keys where
                session.botID == plan.sourceIDs[0] && session.route == target.route {
                queuedStoredIDs.insert(session.storedID)
            }
            for staleStoredID in queuedStoredIDs where staleStoredID != storedID {
                _ = retireQueuedState(botID: plan.sourceIDs[0], route: target.route,
                                      storedID: staleStoredID)
            }
            // A queued row from the same durable transcript but a different
            // runtime SID cannot be proven to belong to the next bind. Keep
            // only the exact old SID as the migration token; the rest is
            // quarantined instead of being replayed into a renamed profile.
            let staleSessionIDs = Set(ChatRuntime.shared.queuedBindings.values.compactMap {
                binding -> String? in
                binding.botID == plan.sourceIDs[0]
                    && binding.route == target.route
                    && binding.storedID == storedID
                    && binding.sessionID != oldSessionID ? binding.sessionID : nil
            })
            if !staleSessionIDs.isEmpty {
                _ = retireQueuedState(botID: plan.sourceIDs[0], route: target.route,
                                      storedID: storedID)
                // `retireQueuedState` above intentionally retires the full
                // exact durable owner. There is no safe way to retain a
                // subset when one destination FIFO is shared by stale SIDs.
            }
            let migratingPromptIDs = Set(ChatRuntime.shared.queuedBindings.compactMap {
                id, binding in
                binding.botID == plan.sourceIDs[0]
                    && binding.route == target.route
                    && binding.storedID == storedID ? id : nil
            })
            ChatRuntime.shared.migrateProfileRouteState(
                from: target.route, to: destinationRoute,
                sourceBotID: plan.sourceIDs[0], destinationBotID: destinationID,
                storedID: storedID, chatID: ObjectIdentifier(sourceChat),
                sessionID: oldSessionID)
            migrateComposeQueueRoute(
                from: plan.sourceIDs[0], to: destinationID,
                fromRoute: target.route, toRoute: destinationRoute,
                storedID: storedID, sessionID: oldSessionID,
                chatID: ObjectIdentifier(sourceChat))
            // Preserve this old SID as a local migration token. Hermes has
            // already retired the runtime address, so it must never be sent;
            // bindSession consumes it when the renamed durable session gets
            // its next runtime SID.
            if let existing = LiveRuntime.shared.reconnectParkedSessionIDs[destinationID],
               existing != oldSessionID {
                // A replacement already owns this destination's parked SID;
                // keep the renamed queue rows quarantined until an explicit
                // destination bind can disambiguate them.
            } else {
                LiveRuntime.shared.reconnectParkedSessionIDs[destinationID] = oldSessionID
            }
            for index in promptQueue.indices where migratingPromptIDs.contains(promptQueue[index].id) {
                promptQueue[index].botID = destinationID
            }
        } else if plan.destinationID == nil {
            // A delete has no destination; repeat the exact-route retirement
            // at the authoritative reconciliation boundary to catch any
            // state that was queued before the REST response returned.
            ChatRuntime.shared.retireProfileRouteState(
                route: target.route, botIDs: retainedSourceIDs)
        }
        // Release only the parked canonical fence under the source key that
        // still belongs to this route. The destination remains untouched until
        // this point, after Hermes has authoritatively committed the rename or
        // deletion.
        restoreParkedProfileLifecycleCanonicalState(
            target, destinationID: plan.destinationID)
        let presentationDestinationRoute = plan.destinationID.flatMap { _ in
            canonicalNewName.map {
                GatewayBotRoute(gatewayID: target.route.gatewayID, profile: $0)
            }
        }
        if let destinationID = plan.destinationID, let presentationDestinationRoute {
            rekeyComposeQueueRoute(from: plan.sourceIDs[0], to: destinationID,
                                   fromRoute: target.route, toRoute: presentationDestinationRoute)
            migrateRetainedProfileMutationFences(
                fromBotIDs: retainedSourceIDs, fromRoute: target.route,
                toBotID: destinationID, toRoute: presentationDestinationRoute,
                chatID: sourceChat.map { ObjectIdentifier($0) },
                storedID: sourceChat?.storedSessionID)
        } else {
            ChatRuntime.shared.transcriptFences = ChatRuntime.shared.transcriptFences
                .filter { !retainedSourceIDs.contains($0.key) }
            ChatRuntime.shared.steerFences = ChatRuntime.shared.steerFences
                .filter { !retainedSourceIDs.contains($0.key) }
            ChatRuntime.shared.offlineComposeFences =
                ChatRuntime.shared.offlineComposeFences.filter { _, fence in
                    !retainedSourceIDs.contains(fence.botID)
                        && fence.route != target.route
                }
        }
        let sources = Set(plan.sourceIDs)
        // A profile rename changes the source-qualified route but keeps the
        // same durable session and ChatState when that ownership is provable.
        // Re-key only that exact deferred interrupt; the old runtime sid is
        // invalid after Hermes retires the old profile backend. Deletion has
        // no destination and therefore retires only this source route (other
        // profiles on the same secondary gateway keep their intents).
        if let destination = plan.destinationID,
           let sourceChat {
            let sourceBotIDs = Set(plan.sourceIDs + [target.route.profile])
            let destinationRoute = GatewayBotRoute(
                gatewayID: target.route.gatewayID,
                profile: canonicalNewName ?? target.route.profile)
            _ = ChatRuntime.shared.rekeyPendingStop(
                fromBotIDs: sourceBotIDs, fromRoute: target.route,
                toBotID: destination, toRoute: destinationRoute,
                chatID: ObjectIdentifier(sourceChat),
                storedID: sourceChat.storedSessionID)
        } else {
            ChatRuntime.shared.clearPendingStops(forRoute: target.route)
        }
        if let destination = plan.destinationID {
            ProfileLifecycleRuntime.shared.activate(
                GatewayBotRoute(gatewayID: target.route.gatewayID,
                                profile: canonicalNewName ?? target.route.profile))
            // Hermes tears down the old-name backend during rename. Preserve
            // the transcript/durable key, never its now-invalid runtime sid.
            for source in sources {
                guard let chat = chats[source] else { continue }
                chat.sessionID = nil
                chat.isRunning = false
                chat.isTyping = false
                for index in chat.messages.indices {
                    chat.messages[index].isStreaming = false
                    for tool in chat.messages[index].toolCalls.indices
                    where chat.messages[index].toolCalls[tool].state == .running {
                        chat.messages[index].toolCalls[tool].state = .failed
                    }
                }
            }
            ProfileLifecycleCache.moveFirst(&chats, from: plan.sourceIDs, to: destination)
            ProfileLifecycleCache.moveFirst(&memory, from: plan.sourceIDs, to: destination)
            ProfileLifecycleCache.moveFirst(&sessions, from: plan.sourceIDs, to: destination)
            ProfileLifecycleQueue.reconcile(&composeQueue, sources: sources,
                                            destination: destination)
            reconcileComposeQueueIDs(sources: sources, destination: destination)
            if let openBotID, sources.contains(openBotID) { self.openBotID = destination }
            for day in activity.indices {
                for item in activity[day].items.indices where sources.contains(activity[day].items[item].botID) {
                    activity[day].items[item].botID = destination
                }
            }
            for index in agentInbox.indices {
                if sources.contains(agentInbox[index].fromBotID) { agentInbox[index].fromBotID = destination }
                if sources.contains(agentInbox[index].toBotID) { agentInbox[index].toBotID = destination }
            }
            for index in artifacts.indices where sources.contains(artifacts[index].botID) {
                artifacts[index].botID = destination
            }
            for index in routines.indices where sources.contains(routines[index].botID) {
                routines[index].botID = destination
            }
        } else {
            for source in sources {
                chats.removeValue(forKey: source)
                memory.removeValue(forKey: source)
                sessions.removeValue(forKey: source)
            }
            ProfileLifecycleQueue.reconcile(&composeQueue, sources: sources,
                                            destination: nil)
            reconcileComposeQueueIDs(sources: sources, destination: nil)
            if let openBotID, sources.contains(openBotID) { self.openBotID = nil }
            for day in activity.indices {
                activity[day].items.removeAll { sources.contains($0.botID) }
            }
            agentInbox.removeAll {
                sources.contains($0.fromBotID) || sources.contains($0.toBotID)
            }
            artifacts.removeAll { sources.contains($0.botID) }
            routines.removeAll { sources.contains($0.botID) }
        }

        // Other pending operations and runtime session ids cannot survive
        // Hermes' backend teardown. The one exception is the exact deferred
        // stop re-keyed above; its sid is parked until the new route binds.
        approvals.removeAll { sources.contains($0.botID) }
        let runtime = LiveRuntime.shared
        runtime.sessionToBot = runtime.sessionToBot.filter { !sources.contains($0.value) }
        runtime.routedSessionToBot = runtime.routedSessionToBot.filter { !sources.contains($0.value) }
        runtime.workingBotIDs.subtract(sources)
        runtime.lastSessionByBot = runtime.lastSessionByBot.filter { !sources.contains($0.key) }
        let tasks = runtime.attachTasks.filter { sources.contains($0.key) }
        for task in tasks.values { task.cancel() }
        for key in tasks.keys { runtime.attachTasks.removeValue(forKey: key) }
        let staleApprovals = runtime.approvalTargets.compactMap { key, value in
            value.bot == target.route ? key : nil
        }
        for key in staleApprovals { runtime.approvalTargets.removeValue(forKey: key) }

        var canonicalSources = sources
        if plan.destinationIsPrimary { canonicalSources.insert(target.route.profile) }
        reconcileCanonicalAndSessionCaches(sourceIDs: canonicalSources,
                                           destinationID: plan.destinationID)
        reconcileFeedCaches(target: target.route, sourceIDs: sources,
                            destinationID: plan.destinationID,
                            canonicalNewName: canonicalNewName)
        reconcileUnreadAndPortrait(target: target.route, newProfile: canonicalNewName,
                                   scope: scope, preserved: preserved,
                                   destinationIsPrimary: plan.destinationIsPrimary)
        scrubProfileEditorCaches(route: target.route, newProfile: canonicalNewName)
        return true
    }

    /// Move accepted-unknown mutation fences only after a rename is
    /// authoritative. Their durable key remains the same, while the old
    /// runtime SID is parked and migrated by the destination's next bind.
    /// A destination collision leaves the source fence quarantined rather than
    /// attaching an accepted mutation to an unrelated ChatState.
    private func migrateRetainedProfileMutationFences(
        fromBotIDs: Set<String>, fromRoute: GatewayBotRoute,
        toBotID: String, toRoute: GatewayBotRoute,
        chatID: ObjectIdentifier? = nil, storedID: String? = nil
    ) {
        let runtime = ChatRuntime.shared
        let hasExactProof = chatID != nil && storedID?.isEmpty == false
        let proofMatches: (ObjectIdentifier?, String?) -> Bool = { candidateChatID, candidateStoredID in
            guard hasExactProof, let chatID, let storedID else { return !hasExactProof }
            return candidateChatID == chatID && ChatRuntime.sameDurable(storedID, candidateStoredID)
        }
        if runtime.transcriptFences[toBotID] == nil,
           let source = runtime.transcriptFences.first(where: { key, fence in
               fromBotIDs.contains(key)
                   && fence.gatewayID == fromRoute.gatewayID
                   && fence.profile == fromRoute.profile
                   && proofMatches(fence.chatID, fence.storedID)
           }) {
            var moved = source.value
            moved.gatewayID = toRoute.gatewayID
            moved.profile = toRoute.profile
            runtime.transcriptFences[toBotID] = moved
            runtime.transcriptFences[source.key] = nil
        }
        if runtime.steerFences[toBotID] == nil,
           let source = runtime.steerFences.first(where: { key, fence in
               fromBotIDs.contains(key) && fence.route == fromRoute
                   && proofMatches(fence.chatID, fence.storedID)
           }) {
            var moved = source.value
            moved.botID = toBotID
            moved.route = toRoute
            runtime.steerFences[toBotID] = moved
            runtime.steerFences[source.key] = nil
        }
        if runtime.stopActions[toBotID] == nil,
           let source = runtime.stopActions.first(where: { key, action in
               fromBotIDs.contains(key) && action.route == fromRoute
                   && proofMatches(action.chatID, action.storedID)
           }) {
            var moved = source.value
            moved.botID = toBotID
            moved.route = toRoute
            runtime.stopActions[toBotID] = moved
            runtime.stopActions[source.key] = nil
        }
        if runtime.stopFences[toBotID] == nil,
           let source = runtime.stopFences.first(where: { key, fence in
               fromBotIDs.contains(key) && !fence.unaddressable
                   && fence.route == fromRoute
                   && proofMatches(fence.chatID, fence.storedID)
           }) {
            var moved = source.value
            moved.botID = toBotID
            moved.route = toRoute
            runtime.stopFences[toBotID] = moved
            runtime.stopFences[source.key] = nil
        }
        let retainedComposeFences = runtime.offlineComposeFences
        for (itemID, fence) in retainedComposeFences {
            guard fromBotIDs.contains(fence.botID), fence.route == fromRoute,
                  proofMatches(fence.chatID, fence.storedID) else { continue }
            var moved = fence
            moved.botID = toBotID
            moved.route = toRoute
            runtime.offlineComposeFences[itemID] = moved
        }
    }

    private func reconcileUnreadAndPortrait(target: GatewayBotRoute, newProfile: String?,
                                            scope: URL,
                                            preserved: ProfileLifecyclePreservedState,
                                            destinationIsPrimary: Bool) {
        MultiGatewayRuntime.shared.routedUnread.removeValue(forKey: target)
        let oldAssetID = target.qualifiedID
        if let newProfile {
            let destination = GatewayBotRoute(gatewayID: target.gatewayID, profile: newProfile)
            MultiGatewayRuntime.shared.routedUnread.removeValue(forKey: destination)
            if preserved.unread > 0 {
                MultiGatewayRuntime.shared.routedUnread[destination] = preserved.unread
            }
            if destinationIsPrimary,
               let index = bots.firstIndex(where: { $0.id == newProfile }) {
                bots[index].unread = preserved.unread
            }
            if let portrait = preserved.portrait {
                ProfileAssetStore.shared.set(portrait, for: destination.qualifiedID)
            } else {
                ProfileAssetStore.shared.markAbsent(destination.qualifiedID)
                let rosterID = destinationIsPrimary
                    ? newProfile : destination.qualifiedID
                Task { @MainActor [weak self] in
                    await self?.refreshAvatar(botID: rosterID, force: true)
                }
            }
        }
        ProfileAssetStore.shared.markAbsent(oldAssetID)
        UnreadWatermarkStore.shared.reconcileProfileLifecycle(
            profile: target.profile, newProfile: newProfile, scope: scope)
    }

    private func reconcileCanonicalAndSessionCaches(sourceIDs: Set<String>,
                                                     destinationID: String?) {
        let canonical = CanonicalChatRuntime.shared
        var sourceSummary: CanonicalSessionIdentity?
        for source in sourceIDs {
            if let summary = LiveRuntime.shared.canonicalSessionByBot.removeValue(forKey: source),
               sourceSummary == nil { sourceSummary = summary }
            canonical.opens.removeValue(forKey: source)?.cancel()
        }
        if let destinationID {
            LiveRuntime.shared.canonicalSessionByBot.removeValue(forKey: destinationID)
            if let sourceSummary {
                LiveRuntime.shared.canonicalSessionByBot[destinationID] = sourceSummary
            }
        }

        let sessions = SessionsRuntime.shared
        func remap(_ input: [String: String]) -> [String: String] {
            var output = input.filter { key, _ in
                guard let destinationID,
                      let boundary = key.firstIndex(of: "\u{0}") else { return true }
                return String(key[..<boundary]) != destinationID
            }
            for (key, value) in input {
                guard let boundary = key.firstIndex(of: "\u{0}") else { continue }
                let botID = String(key[..<boundary])
                guard sourceIDs.contains(botID) else { continue }
                output.removeValue(forKey: key)
                if let destinationID {
                    let suffix = String(key[boundary...])
                    let destinationKey = destinationID + suffix
                    output[destinationKey] = value
                }
            }
            return output
        }
        sessions.titles = remap(sessions.titles)
        sessions.previews = remap(sessions.previews)
        if let destinationID { sessions.loadErrors.removeValue(forKey: destinationID) }
        for source in sourceIDs {
            if let error = sessions.loadErrors.removeValue(forKey: source),
               let destinationID {
                sessions.loadErrors[destinationID] = error
            }
        }
    }

    private func reconcileFeedCaches(target: GatewayBotRoute, sourceIDs: Set<String>,
                                     destinationID: String?, canonicalNewName: String?) {
        let feeds = FeedsRuntime.shared
        if !feeds.journalLoaded {
            feeds.journalLoaded = true
            feeds.journal = Self.loadJournal()
        }
        if let destinationID {
            feeds.knownPreviews.removeValue(forKey: destinationID)
            for index in feeds.journal.indices where sourceIDs.contains(feeds.journal[index].botID) {
                feeds.journal[index].botID = destinationID
            }
            for source in sourceIDs {
                if let preview = feeds.knownPreviews.removeValue(forKey: source),
                   !destinationID.isEmpty {
                    feeds.knownPreviews[destinationID] = preview
                }
            }
        } else {
            feeds.journal.removeAll { sourceIDs.contains($0.botID) }
            for source in sourceIDs { feeds.knownPreviews.removeValue(forKey: source) }
        }
        feeds.knownApprovals = feeds.knownApprovals.filter {
            !sourceIDs.contains($0.value.botID)
        }
        Self.saveJournal(feeds.journal)
        publishActivity()

        func reconciled(_ ref: SessionRef) -> SessionRef? {
            // A bare `default` can belong to another gateway. SessionRef's
            // captured source outranks the collision-prone roster spelling.
            guard ref.gatewayID == target.gatewayID,
                  sourceIDs.contains(ref.botID) else { return ref }
            guard let destinationID else { return nil }
            return SessionRef(gatewayID: target.gatewayID,
                              botID: destinationID, storedID: ref.storedID)
        }
        feeds.artifactSessions = feeds.artifactSessions.compactMapValues(reconciled)
        feeds.inboxSessions = feeds.inboxSessions.compactMapValues(reconciled)

        let matchingRoutines = feeds.routineTargets.compactMap { key, value in
            value.bot == target ? key : nil
        }
        for key in matchingRoutines {
            guard let canonicalNewName else {
                feeds.cronJobs.removeValue(forKey: key)
                feeds.cronScope.removeValue(forKey: key)
                feeds.routineTargets.removeValue(forKey: key)
                clearCronRoutineCaches(key)
                // Quarantine keys carry the full routine fence (gateway,
                // profile, source generation, and profile generation). A raw
                // job-id removal leaves the exact marker behind, so a
                // delete/recreate can inherit a stale quarantine lease.
                clearCronRoutineQuarantine(key)
                continue
            }
            guard var route = feeds.routineTargets[key] else { continue }
            route.bot.profile = canonicalNewName
            if route.profile == target.profile { route.profile = canonicalNewName }
            feeds.routineTargets[key] = route
            if let scoped = feeds.cronScope[key] ?? nil, scoped == target.profile {
                feeds.cronScope[key] = canonicalNewName
            }
        }
    }

    /// Profile-specific editor caches retain credentials, capabilities, or
    /// generated state addressed to the old directory. Drop precisely this
    /// route; the next sheet load reconstructs it from the refreshed roster.
    private func scrubProfileEditorCaches(route: GatewayBotRoute, newProfile: String?) {
        var keys = [route.qualifiedID]
        if let newProfile {
            keys.append(GatewayBotRoute(gatewayID: route.gatewayID,
                                        profile: newProfile).qualifiedID)
        }
        for qualified in keys {
            if let state = ModelPickerRuntime.shared.states.removeValue(forKey: qualified) {
                state.resetForDetach()
            }
            if let state = CapabilityRuntime.shared.states.removeValue(forKey: qualified) {
                state.resetForDetach()
            }
            if let state = PetRuntime.shared.states.removeValue(forKey: qualified) {
                state.resetForDetach()
            }
            PetRuntime.shared.loads.removeValue(forKey: qualified)?.cancel()
            PetRuntime.shared.loadIDs.removeValue(forKey: qualified)
        }
    }
}
