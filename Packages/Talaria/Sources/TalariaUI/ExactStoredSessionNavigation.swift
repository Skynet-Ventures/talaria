import Foundation
import TalariaKit

/// Immutable authority for an out-of-process route into one durable Hermes
/// transcript.  Keeping the raw profile separate from its roster presentation
/// is what prevents a cold push from opening a same-named bot on another host.
public struct ExactStoredSessionRoute: Hashable, Sendable {
    public var gatewayID: String
    public var profile: String
    public var storedSessionID: String

    public init?(gatewayID: String, profile: String, storedSessionID: String) {
        let trim = CharacterSet.whitespacesAndNewlines
        guard !gatewayID.isEmpty, gatewayID == gatewayID.trimmingCharacters(in: trim),
              !profile.isEmpty, profile == profile.trimmingCharacters(in: trim),
              !storedSessionID.isEmpty,
              storedSessionID == storedSessionID.trimmingCharacters(in: trim),
              !gatewayID.contains(GatewayBotRoute.separator),
              GatewayBotRoute(qualifiedID: profile) == nil else { return nil }
        self.gatewayID = gatewayID
        self.profile = profile
        self.storedSessionID = storedSessionID
    }

    public var botRoute: GatewayBotRoute {
        GatewayBotRoute(gatewayID: gatewayID, profile: profile)
    }

    /// Active rows use their raw profile; every retained foreign row stays
    /// source-qualified. This is presentation only — `botRoute` remains the
    /// authority supplied to every RPC.
    public func rosterID(activeGatewayID: String?) -> String {
        gatewayID == activeGatewayID ? profile : botRoute.qualifiedID
    }
}

/// The URL contract is package-owned so the same strict parser used by the app
/// is executable in the Swift package test suite.
public enum TalariaDeepLink: Equatable {
    case approvals
    case connections
    case bot(id: String)
    case storedSession(ExactStoredSessionRoute)

    /// Parse syntax only. Saved-gateway and fresh-profile authority are checked
    /// by `AppModel.openExactStoredSession`; doing that here would discard a
    /// valid cold-launch intent before launch restore has rebuilt live state.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "talaria" else { return nil }
        guard url.user == nil, url.password == nil, url.port == nil,
              url.fragment == nil else { return nil }
        switch url.host?.lowercased() {
        case "approvals":
            self = .approvals
        case "connections":
            self = .connections
        case "bot":
            let components = url.pathComponents.filter { $0 != "/" }
            guard components.count == 1, let id = components.first, !id.isEmpty else {
                return nil
            }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let sessionItems = query.filter { $0.name == "session_id" }
            let gatewayItems = query.filter { $0.name == "gateway_id" }
            guard query.allSatisfy({ $0.name == "session_id" || $0.name == "gateway_id" }),
                  sessionItems.count <= 1, gatewayItems.count <= 1,
                  sessionItems.allSatisfy({ !($0.value ?? "").isEmpty }),
                  gatewayItems.allSatisfy({ !($0.value ?? "").isEmpty }) else {
                return nil
            }
            guard let storedSessionID = sessionItems.first?.value else {
                guard gatewayItems.isEmpty else { return nil }
                self = .bot(id: id)
                return
            }

            let route: ExactStoredSessionRoute?
            if let qualified = GatewayBotRoute(qualifiedID: id) {
                guard gatewayItems.isEmpty else { return nil }
                route = ExactStoredSessionRoute(
                    gatewayID: qualified.gatewayID,
                    profile: qualified.profile,
                    storedSessionID: storedSessionID)
            } else {
                guard let gatewayID = gatewayItems.first?.value else { return nil }
                route = ExactStoredSessionRoute(
                    gatewayID: gatewayID, profile: id,
                    storedSessionID: storedSessionID)
            }
            guard let route else { return nil }
            self = .storedSession(route)
        default:
            return nil
        }
    }
}

enum ExactStoredSessionRouteAuthorityError: LocalizedError, Equatable {
    case unknownGateway(String)
    case missingCredential(String)
    case invalidProfileInventory
    case missingProfile(ExactStoredSessionRoute)

    var errorDescription: String? {
        switch self {
        case .unknownGateway:
            return "That response came from a gateway that is no longer saved. Nothing was opened."
        case .missingCredential(let name):
            return "Sign in to \(name) before opening this response. Nothing was opened."
        case .invalidProfileInventory:
            return "The gateway returned an ambiguous profile list. Nothing was opened."
        case .missingProfile(let route):
            return "The \(route.profile) profile was renamed or deleted on this gateway. Nothing was opened."
        }
    }
}

enum ExactStoredSessionRouteAuthority {
    /// Hermes can fall back to its launch profile for an unknown explicit
    /// profile. Require an exact, fresh, unambiguous inventory before and after
    /// session.resume so that fallback can never become a shadow chat.
    static func requireCurrent(_ route: ExactStoredSessionRoute,
                               profileNames: [String]) throws {
        var exact = Set<String>()
        var folded = Set<String>()
        for raw in profileNames {
            guard !raw.isEmpty,
                  raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
                  exact.insert(raw).inserted,
                  folded.insert(raw.lowercased()).inserted else {
                throw ExactStoredSessionRouteAuthorityError.invalidProfileInventory
            }
        }
        guard exact.contains(route.profile) else {
            throw ExactStoredSessionRouteAuthorityError.missingProfile(route)
        }
    }
}

enum ExactStoredSessionResumeAckAuthorityError: Error, Equatable {
    case durableSessionMismatch
    case profileMismatch
}

enum ExactStoredSessionResumeAckAuthority {
    /// Validate the session.resume ACK itself, not only surrounding inventory.
    /// This closes delete/recreate ABA where unknown-profile fallback returns a
    /// same-key transcript owned by another profile before the requested name
    /// reappears in the post-resume profile list.
    static func requireExact(
        route: GatewayBotRoute,
        requestedStoredSessionID: String,
        returnedStoredSessionID: String,
        returnedProfile: String
    ) throws {
        guard returnedStoredSessionID == requestedStoredSessionID else {
            throw ExactStoredSessionResumeAckAuthorityError.durableSessionMismatch
        }
        guard !returnedProfile.isEmpty,
              returnedProfile == returnedProfile.trimmingCharacters(
                in: .whitespacesAndNewlines),
              returnedProfile == route.profile else {
            throw ExactStoredSessionResumeAckAuthorityError.profileMismatch
        }
    }
}

public enum ExactStoredSessionRouteOrigin: Sendable, Equatable {
    case deepLink
    case notification
}

struct ExactStoredSessionRouteRequest: Sendable, Equatable {
    var route: ExactStoredSessionRoute
    var origin: ExactStoredSessionRouteOrigin
    /// True only when the request arrived before a live world existed. A route
    /// submitted against an already-live model starts immediately.
    var waitsForLaunchRestore: Bool
}

enum ExactStoredSessionRouteAttempt: Equatable {
    case opened
    /// Retain the exact request until restore/reconnect/foreground authority
    /// changes and nudges the queue again.
    case deferred
    /// Permanent local authority failure. The request is cleared and surfaced.
    case rejected(String)
}

enum ExactStoredSessionRouteRetryPolicy {
    /// GatewayTransport uses -5 for an ordinary RPC timeout. Transport loss,
    /// timeout, cancellation, and URL loading failures retain the route; auth
    /// and fresh source/profile authority failures remain definitive.
    static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError || error is URLError { return true }
        guard let gateway = error as? GatewayError else { return false }
        return [-1, -2, -3, -5, -6, -7].contains(gateway.code)
    }
}

enum ExactStoredSessionRouteSubmission: Equatable {
    case started
    case duplicate
    case alreadyVisible
}

/// Latest-intent queue for out-of-process exact-session navigation.
///
/// Supersession is explicit: an identical URL/push pair coalesces; a different
/// route cancels the older operation and becomes the sole pending intent. A
/// deferred attempt remains pending across reconnect. Once opened, the queue
/// forgets it; a repeat tap is a no-op only while that exact route is visible.
@MainActor
final class ExactStoredSessionRouteQueue {
    typealias Execute = @MainActor (ExactStoredSessionRouteRequest) async
        -> ExactStoredSessionRouteAttempt
    typealias Reject = @MainActor (ExactStoredSessionRoute, String) -> Void

    private(set) var pending: ExactStoredSessionRouteRequest?
    private(set) var running: ExactStoredSessionRouteRequest?
    private(set) var completedOpenCount = 0
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var retryWhenSettled = false
    private var execute: Execute?
    private var reject: Reject?

    @discardableResult
    func submit(_ request: ExactStoredSessionRouteRequest, alreadyVisible: Bool,
                execute: @escaping Execute, reject: @escaping Reject)
        -> ExactStoredSessionRouteSubmission {
        if pending?.route == request.route || running?.route == request.route {
            return .duplicate
        }
        if alreadyVisible { return .alreadyVisible }

        // A newer, different tap is the user's latest navigation intent. The
        // generation fence makes a late completion from the cancelled task
        // incapable of clearing or publishing over the successor.
        generation &+= 1
        task?.cancel()
        task = nil
        retryWhenSettled = false
        pending = request
        running = nil
        self.execute = execute
        self.reject = reject
        startPendingAttempt()
        return .started
    }

    /// Re-run a retained request after launch restore, reconnect, network
    /// recovery, or foreground activation. If an attempt is still unwinding,
    /// remember the signal and run once immediately after it defers.
    func nudge() {
        guard pending != nil else { return }
        guard task == nil else {
            retryWhenSettled = true
            return
        }
        startPendingAttempt()
    }

    func awaitCurrentAttempt() async {
        while let current = task { await current.value }
    }

    private func startPendingAttempt() {
        guard task == nil, let request = pending, let execute else { return }
        let capturedGeneration = generation
        running = request
        let launched = Task { @MainActor [weak self] in
            let outcome = await execute(request)
            guard let self, self.generation == capturedGeneration else { return }
            self.task = nil
            self.running = nil
            switch outcome {
            case .opened:
                self.pending = nil
                self.execute = nil
                self.reject = nil
                self.retryWhenSettled = false
                self.completedOpenCount += 1
            case .rejected(let message):
                self.pending = nil
                self.execute = nil
                let reject = self.reject
                self.reject = nil
                self.retryWhenSettled = false
                reject?(request.route, message)
            case .deferred:
                if self.retryWhenSettled {
                    self.retryWhenSettled = false
                    self.startPendingAttempt()
                }
            }
        }
        task = launched
    }
}

extension AppModel {
    /// Close the exact-session source authority before a user-initiated
    /// gateway teardown crosses its first await.  Pool identity alone cannot
    /// express that intent: the teardown deliberately waits on an in-flight
    /// lease, while the saved row and pooled client remain visible until that
    /// lease is released.
    func beginExactStoredSessionSourceTeardown(gatewayID: String) {
        exactStoredSessionSourceInvalidations.insert(gatewayID)
        exactStoredSessionSourceTeardownCounts[gatewayID, default: 0] += 1
    }

    /// End one teardown scope.  Keep a failed/partial teardown fenced while a
    /// durable row with a credential still exists; a later credentialed
    /// reconnect can explicitly clear that transient invalidation.
    func finishExactStoredSessionSourceTeardown(gatewayID: String) {
        let remaining = exactStoredSessionSourceTeardownCounts[gatewayID, default: 1] - 1
        if remaining > 0 {
            exactStoredSessionSourceTeardownCounts[gatewayID] = remaining
            return
        }
        exactStoredSessionSourceTeardownCounts.removeValue(forKey: gatewayID)
        clearExactStoredSessionSourceInvalidationIfUnavailable(gatewayID: gatewayID)
    }

    /// A source that no longer has a durable row or credential is already
    /// rejected by the route/credential fence. Removing the transient mark in
    /// that state permits a later re-add/sign-in to establish fresh authority.
    func clearExactStoredSessionSourceInvalidationIfUnavailable(gatewayID: String) {
        guard exactStoredSessionSourceTeardownCounts[gatewayID] == nil else { return }
        let registry = ConnectionRegistry.shared
        guard let saved = registry.saved.first(where: { $0.id == gatewayID }) else {
            exactStoredSessionSourceInvalidations.remove(gatewayID)
            return
        }
        guard registry.credential(for: saved) == nil else { return }
        exactStoredSessionSourceInvalidations.remove(gatewayID)
    }

    /// A successfully credentialed reconnect may recover a source whose
    /// previous teardown could not prove durable removal. Never clear while a
    /// user teardown is still in flight.
    func clearExactStoredSessionSourceInvalidationIfCredentialed(gatewayID: String) {
        guard exactStoredSessionSourceTeardownCounts[gatewayID] == nil,
              let saved = ConnectionRegistry.shared.saved.first(where: {
                  $0.id == gatewayID
              }),
              ConnectionRegistry.shared.credential(for: saved) != nil else { return }
        exactStoredSessionSourceInvalidations.remove(gatewayID)
    }

    func exactStoredSessionSourceIsInvalidated(gatewayID: String) -> Bool {
        exactStoredSessionSourceInvalidations.contains(gatewayID)
    }

    /// Shared entry point for response-push taps and exact-session URLs. It
    /// never calls `openChat`; only the source-captured session.resume path may
    /// publish navigation after both authority checks pass.
    public func openExactStoredSession(_ route: ExactStoredSessionRoute,
                                       origin: ExactStoredSessionRouteOrigin) {
        let request = ExactStoredSessionRouteRequest(
            route: route, origin: origin,
            waitsForLaunchRestore: mode != .live || activeGatewayID == nil)
        exactStoredSessionRouteQueue.submit(
            request,
            alreadyVisible: isExactStoredSessionVisible(route),
            execute: { [weak self] request in
                guard let self else {
                    return .rejected("The app closed before the response could open.")
                }
                return await self.attemptExactStoredSessionNavigation(request)
            },
            reject: { [weak self] route, message in
                self?.surfaceExactStoredSessionFailure(route, message: message)
            })
    }

    /// Lifecycle signal, deliberately idempotent.
    func retryExactStoredSessionNavigation() {
        exactStoredSessionRouteQueue.nudge()
    }

    func completeLaunchWorldRestore() {
        launchWorldRestoreCompleted = true
        retryExactStoredSessionNavigation()
    }

    private func isExactStoredSessionVisible(_ route: ExactStoredSessionRoute) -> Bool {
        let botID = route.rosterID(activeGatewayID: activeGatewayID)
        return openBotID == botID
            && stateRoute(for: botID) == route.botRoute
            && chats[botID]?.storedSessionID == route.storedSessionID
    }

    private func attemptExactStoredSessionNavigation(
        _ request: ExactStoredSessionRouteRequest
    ) async -> ExactStoredSessionRouteAttempt {
        if request.waitsForLaunchRestore, !launchWorldRestoreCompleted {
            return .deferred
        }
        let registry = ConnectionRegistry.shared
        guard let saved = registry.saved.first(where: { $0.id == request.route.gatewayID }),
              saved.baseURL != nil else {
            return .rejected(ExactStoredSessionRouteAuthorityError
                .unknownGateway(request.route.gatewayID).localizedDescription)
        }
        guard let credential = registry.credential(for: saved) else {
            return .rejected(ExactStoredSessionRouteAuthorityError
                .missingCredential(saved.name).localizedDescription)
        }

        do {
            let sourceReady: Bool
            if let exactStoredSessionSourceReadinessOverride {
                sourceReady = try await exactStoredSessionSourceReadinessOverride(request.route)
            } else {
                sourceReady = try await prepareExactStoredSessionSource(
                    request.route, saved: saved, credential: credential)
            }
            guard sourceReady else { return .deferred }
            if let exactStoredSessionOpenOverride {
                try await exactStoredSessionOpenOverride(request.route)
            } else {
                try await openAuthoritativeExactStoredSession(request.route)
            }
            return .opened
        } catch let error as ExactStoredSessionRouteAuthorityError {
            return .rejected(error.localizedDescription)
        } catch where ExactStoredSessionRouteRetryPolicy.isTransient(error) {
            return .deferred
        } catch {
            return .rejected(error.localizedDescription)
        }
    }

    /// Launch restore may exhaust its one-shot saved-gateway pass while the
    /// device is offline, leaving the model in its `.demo` placeholder with no
    /// reconnect supervisor capable of dialing. A retained exact route owns
    /// enough authority to retry only its stamped saved source when lifecycle
    /// signals nudge the queue; it never falls back to another gateway.
    private func prepareExactStoredSessionSource(
        _ route: ExactStoredSessionRoute,
        saved: SavedGateway,
        credential: GatewayCredential
    ) async throws -> Bool {
        if mode == .live, client != nil, activeGatewayID != nil { return true }
        guard launchWorldRestoreCompleted else { return false }
        guard let baseURL = saved.baseURL,
              ConnectionRegistry.shared.saved.contains(where: {
                $0.id == route.gatewayID && $0.urlString == saved.urlString
              }) else {
            throw ExactStoredSessionRouteAuthorityError.unknownGateway(route.gatewayID)
        }

        try Task.checkCancellation()
        try await runManagedCloudBootEpisode(
            sourceURL: baseURL, gatewayID: route.gatewayID
        ) {
            try await self.connectGateway(baseURL: baseURL, credential: credential)
        }
        try Task.checkCancellation()

        guard let current = ConnectionRegistry.shared.saved.first(where: {
            $0.id == route.gatewayID && $0.urlString == saved.urlString
        }) else {
            throw ExactStoredSessionRouteAuthorityError.unknownGateway(route.gatewayID)
        }
        guard ConnectionRegistry.shared.credential(for: current) != nil else {
            throw ExactStoredSessionRouteAuthorityError.missingCredential(current.name)
        }
        // connectGateway was given the exact saved URL. Prove that URL became
        // the live primary before any profile/session RPC can publish state.
        guard mode == .live, client != nil, activeGatewayID == route.gatewayID else {
            throw CancellationError()
        }
        return true
    }

    /// Awaited transactional entry point for an already source-qualified
    /// in-app child, shared with message-level branch creation.
    func openAuthoritativeExactStoredSession(
        _ route: ExactStoredSessionRoute,
        validateImmediatelyBeforeBinding:
            (@MainActor () async throws -> Void)? = nil
    ) async throws {
        let registry = ConnectionRegistry.shared
        let pool = registry.clientPool
        let snapshot: GatewayClientPool.ConnectionSnapshot
        let poolLease: GatewayClientPool.ConnectionLease
        let trafficLease: GatewayClient.TrafficLease

        // Match the pool -> lifecycle acquisition order used by Projects. If a
        // profile mutation owns the source, release the pool and wait without
        // ever issuing profiles.list/session.resume under stale authority.
        while true {
            try Task.checkCancellation()
            guard let saved = registry.saved.first(where: { $0.id == route.gatewayID }),
                  let baseURL = saved.baseURL else {
                throw ExactStoredSessionRouteAuthorityError.unknownGateway(route.gatewayID)
            }
            guard let credential = registry.credential(for: saved) else {
                throw ExactStoredSessionRouteAuthorityError.missingCredential(saved.name)
            }
            let candidate = try await pool.connectWithGeneration(
                gatewayID: route.gatewayID, baseURL: baseURL, credential: credential)
            guard let candidatePoolLease = await pool.acquireLease(
                candidate, for: route.gatewayID) else {
                throw CancellationError()
            }
            if let candidateTrafficLease = ProfileLifecycleTrafficAdmission.acquire(route.gatewayID) {
                snapshot = candidate
                poolLease = candidatePoolLease
                trafficLease = candidateTrafficLease
                break
            }
            await pool.release(candidatePoolLease)
            try await Task.sleep(for: .milliseconds(100))
        }

        clearExactStoredSessionSourceInvalidationIfCredentialed(gatewayID: route.gatewayID)
        if let hook = SessionsRuntime.shared.exactOpenAfterPoolLeaseForTesting {
            await hook(route.gatewayID)
        }

        do {
            let wasPrimary = route.gatewayID == activeGatewayID
            try await requireExactStoredSessionSourceCurrent(
                route, snapshot: snapshot, wasPrimary: wasPrimary)
            let profiles = try await exactOpenProfiles(
                client: snapshot.client, route: route)
            try ExactStoredSessionRouteAuthority.requireCurrent(
                route, profileNames: profiles.map(\.name))
            try await requireExactStoredSessionSourceCurrent(
                route, snapshot: snapshot, wasPrimary: wasPrimary)

            let botID = route.rosterID(activeGatewayID: wasPrimary ? route.gatewayID : nil)
            guard stateRoute(for: botID) == route.botRoute else {
                throw CancellationError()
            }
            let resumeForTesting: (@MainActor () async throws -> LiveSession)?
            if let override = SessionsRuntime.shared.exactOpenResumeForTesting {
                resumeForTesting = { try await override(snapshot.client, route) }
            } else {
                resumeForTesting = nil
            }
            let opened = try await openStoredSessionAwaiting(
                route.storedSessionID,
                botID: botID,
                route: route.botRoute,
                client: snapshot.client,
                validateBeforeBinding: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.requireExactStoredSessionSourceCurrent(
                        route, snapshot: snapshot, wasPrimary: wasPrimary)
                    let current = try await self.exactOpenProfiles(
                        client: snapshot.client, route: route)
                    try ExactStoredSessionRouteAuthority.requireCurrent(
                        route, profileNames: current.map(\.name))
                    try await self.requireExactStoredSessionSourceCurrent(
                        route, snapshot: snapshot, wasPrimary: wasPrimary)
                },
                validateImmediatelyBeforeBinding: validateImmediatelyBeforeBinding,
                resumeForTesting: resumeForTesting,
                sourceSnapshot: snapshot)
            guard opened,
                  openBotID == botID,
                  stateRoute(for: botID) == route.botRoute,
                  chats[botID]?.storedSessionID == route.storedSessionID else {
                throw CancellationError()
            }
            await trafficLease.release()
            await pool.release(poolLease)
        } catch {
            await trafficLease.release()
            await pool.release(poolLease)
            throw error
        }
    }

    private func exactOpenProfiles(
        client: GatewayClient, route: ExactStoredSessionRoute
    ) async throws -> [HermesProfile] {
        if let override = SessionsRuntime.shared.exactOpenProfilesForTesting {
            return try await override(client, route)
        }
        return try await client.listProfiles(includeSessions: false)
    }

    private func requireExactStoredSessionSourceCurrent(
        _ route: ExactStoredSessionRoute,
        snapshot: GatewayClientPool.ConnectionSnapshot,
        wasPrimary: Bool
    ) async throws {
        guard ConnectionRegistry.shared.saved.contains(where: { $0.id == route.gatewayID }) else {
            throw ExactStoredSessionRouteAuthorityError.unknownGateway(route.gatewayID)
        }
        guard await ConnectionRegistry.shared.clientPool.isCurrent(
            snapshot, for: route.gatewayID) else { throw CancellationError() }
        if wasPrimary {
            guard activeGatewayID == route.gatewayID,
                  client.map(ObjectIdentifier.init) == ObjectIdentifier(snapshot.client) else {
                throw CancellationError()
            }
        } else if activeGatewayID == route.gatewayID {
            // A gateway switch changes the roster identity from qualified to
            // bare. Retry from the new world instead of publishing the old key.
            throw CancellationError()
        }
        guard ProfileLifecycleTrafficAdmission.allows(route.gatewayID) else {
            throw CancellationError()
        }
    }

    private func surfaceExactStoredSessionFailure(_ route: ExactStoredSessionRoute,
                                                  message: String) {
        toast(kind: .failure,
              title: theme.copy.toastOpenSessionFailed(theme.themeID),
              message: message,
              botID: route.rosterID(activeGatewayID: activeGatewayID))
    }
}
