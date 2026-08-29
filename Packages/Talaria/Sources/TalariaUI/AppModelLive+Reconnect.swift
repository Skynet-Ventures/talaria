import Foundation
import Observation
import SwiftUI
import TalariaKit
import TalariaTheme

/// UIKit's application-active callback is the reliable wake edge on iOS.
/// SwiftUI's `scenePhase` remains useful, but production devices have shown it
/// can miss a lock-screen return while the mounted root view survives. The
/// app target posts this notification from `UIApplicationDelegate` and the
/// root funnels both lifecycle sources through the same coalesced validation.
public extension Notification.Name {
    static let talariaApplicationDidBecomeActive = Notification.Name(
        "bot.talaria.applicationDidBecomeActive")
}

// Connection supervision for every post-boot socket-loss path.
//
// Event-pump completion is the disconnect signal. The single supervised loop
// applies the host-agnostic full-jitter policy, re-auth handling, exact-source
// fences, session reattachment, and recovery escalation. It also handles:
//
//   1. Re-auth. GatewayClient.connect() throws AuthError.sessionExpired when
//      the refresh token is rejected, and deletes the Keychain credential on
//      the way out (GatewayClient.swift:167-170). The backoff loop then just
//      stops, leaving the app silently offline forever (PARITY §1, roadmap
//      #10). A missing credential for the connected base URL is therefore an
//      exact, side-effect-free signal that reconnect gave up on auth — the
//      supervisor polls for it and raises ReauthBanner.
//   2. Foreground recovery. iOS suspends the process; a socket that died in the
//      background is often still `.ready` until the first write. A scenePhase
//      hook can also miss lock-screen return. applicationDidBecomeActive()
//      therefore takes the UIKit wake as well, proves the exact socket with a
//      bounded `gateway.ping`, and enters supervised reconnect immediately
//      instead of trusting transport state or waiting out backoff.
//   3. Manual control — "Reconnect now" on the banner, and switching the live
//      gateway from Connections.
//
// The supervised retry parks in LiveRuntime.reconnectTask and re-dials the same
// GatewayClient, preserving event fan-out and the server's ~20 s park window.

// MARK: - Supervisor state (side table)

/// A post-boot reconnect episode that has remained offline long enough for the
/// recovery UI to offer stronger help. This is exact saved-source state, not a
/// managed-cloud availability diagnosis.
public struct PostBootReconnectRecovery: Sendable, Equatable {
    public let gatewayID: String
    public let sourceOrigin: String
    public let host: String
    public let elapsed: TimeInterval

    init(gatewayID: String, baseURL: URL, elapsed: TimeInterval) {
        self.gatewayID = gatewayID
        let host = baseURL.host?.lowercased() ?? ""
        self.host = host
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        components?.host = host.isEmpty ? nil : host
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        let projected = components?.url?.absoluteString ?? host
        self.sourceOrigin = projected.hasSuffix("/")
            ? String(projected.dropLast()) : projected
        self.elapsed = elapsed
    }
}

/// AppModel's stored properties live in AppModel.swift (another owner) and
/// extensions cannot add storage, so supervision state rides an observable
/// MainActor singleton — the same shape LiveRuntime uses, but observable
/// because the banner and the Connections rows read it from view bodies.
@MainActor
@Observable
final class ConnectionSupervisor {
    typealias Sleep = @MainActor (TimeInterval) async throws -> Void
    typealias RandomUnit = @MainActor () -> Double
    typealias Now = @MainActor () -> TimeInterval
    typealias Dial = @MainActor (GatewayClient) async throws -> Void
    typealias SwitchConnect = @MainActor (AppModel, URL, GatewayCredential) async throws -> Void

    struct EpisodeSource: Equatable {
        let generation: Int
        let gatewayID: String
        let baseURL: URL
        let clientID: ObjectIdentifier
    }

    static let shared = ConnectionSupervisor()

    /// Gateway whose sign-in must be repeated; nil when auth is healthy.
    var reauthGateway: URL?
    /// A supervised dial is in flight (banner spinner, disabled row actions).
    var isReconnecting = false
    /// Last status-probe result per saved-gateway id.
    var diagnostics: [String: GatewayDiagnostics] = [:]
    /// Exact source whose unlimited reconnect episode crossed the recovery
    /// escalation threshold. This intentionally does not reuse managed-cloud
    /// outage state: post-boot reconnect is host agnostic.
    var postBootRecovery: PostBootReconnectRecovery?
    /// Probe seam for deterministic lifecycle tests. Production always uses
    /// the real unauthenticated status endpoint; tests replace this briefly
    /// while exercising AppModel.refreshConnectionHealth end to end.
    @ObservationIgnored var healthProbe:
        @Sendable (SavedGateway) async -> (ConnectionState, GatewayDiagnostics) =
            { gateway in await GatewayDiagnostics.probe(gateway) }

    @ObservationIgnored let keychain = KeychainStore()
    /// App-lifetime watch loop; nil until the first start request.
    @ObservationIgnored var watchTask: Task<Void, Never>?
    @ObservationIgnored var reconnectTaskToken: UUID?
    /// Single-flight foreground socket validation. UIKit and SwiftUI publish
    /// the same wake a few milliseconds apart; they must share one ping.
    @ObservationIgnored var foregroundValidationTask: Task<Void, Never>?
    @ObservationIgnored var foregroundValidationToken: UUID?
    @ObservationIgnored var episodeSource: EpisodeSource?
    @ObservationIgnored var episodeStartedAt: TimeInterval?
    @ObservationIgnored var episodeAttempt = 0
    @ObservationIgnored var sleep: Sleep = ConnectionSupervisor.productionSleep
    @ObservationIgnored var randomUnit: RandomUnit = { Double.random(in: 0..<1) }
    @ObservationIgnored var now: Now = { ProcessInfo.processInfo.systemUptime }
    @ObservationIgnored var dial: Dial = { client in try await client.connect() }
    @ObservationIgnored var switchConnect: SwitchConnect?

    private static let productionSleep: Sleep = { delay in
        guard delay > 0 else {
            await Task.yield()
            try Task.checkCancellation()
            return
        }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    func resetEpisode(for reason: PostBootReconnectResetReason,
                      source: EpisodeSource? = nil) {
        let reset = PostBootReconnectPolicy.resetEpisode(for: reason)
        episodeSource = source
        episodeStartedAt = source == nil ? nil : now()
        episodeAttempt = reset.attempt
        postBootRecovery = nil
    }

    func resetTestingSeams() {
        sleep = Self.productionSleep
        randomUnit = { Double.random(in: 0..<1) }
        now = { ProcessInfo.processInfo.systemUptime }
        dial = { client in try await client.connect() }
        switchConnect = nil
        reconnectTaskToken = nil
        foregroundValidationTask?.cancel()
        foregroundValidationTask = nil
        foregroundValidationToken = nil
        resetEpisode(for: .cleanOpen)
        isReconnecting = false
        reauthGateway = nil
    }

    func note(error: Error, forGatewayID id: String?) {
        guard let id else { return }
        var entry = diagnostics[id] ?? GatewayDiagnostics()
        entry.lastError = GatewayDiagnostics.shortMessage(for: error)
        entry.checkedAt = Date()
        diagnostics[id] = entry
    }
}

/// What the Connections health row shows for one saved gateway: the public
/// `GET /api/status` answer plus the measured round trip and the last failure.
public struct GatewayDiagnostics: Sendable, Equatable {

    /// How the gateway gates access (auth_required + auth_flows).
    public enum AuthMode: String, Sendable {
        /// Loopback / trusted bind — a pasted session token is enough.
        case open
        /// Gated and advertising native_pkce: the in-app broker flow works.
        case oauth
        /// Gated without native_pkce — Talaria cannot broker a sign-in.
        case gated
        case unknown
    }

    public var version: String?
    public var authMode: AuthMode
    public var pingMS: Int?
    public var lastError: String?
    public var checkedAt: Date?

    public init(version: String? = nil, authMode: AuthMode = .unknown,
                pingMS: Int? = nil, lastError: String? = nil, checkedAt: Date? = nil) {
        self.version = version
        self.authMode = authMode
        self.pingMS = pingMS
        self.lastError = lastError
        self.checkedAt = checkedAt
    }

    /// One health probe: `GET /api/status` (public, unauthenticated —
    /// ws-protocol.md §18) with a measured round trip. A timeout reads as a
    /// sleeping host, anything else as offline — same split the registry
    /// probe uses, so the two agree on the state word.
    static func probe(_ gateway: SavedGateway) async -> (ConnectionState, GatewayDiagnostics) {
        guard let base = gateway.baseURL else {
            return (.offline, GatewayDiagnostics(lastError: "malformed gateway URL",
                                                 checkedAt: Date()))
        }
        var request = URLRequest(url: base.appending(path: "api/status"))
        // Fail fast: a sleeping LAN box must not hold the row for 60 s.
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let clock = ContinuousClock()
        let start = clock.now
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let code = (response as? HTTPURLResponse)?.statusCode else {
                throw URLError(.badServerResponse)
            }
            guard code == 200 else {
                return (.offline, GatewayDiagnostics(lastError: "status \(code)",
                                                     checkedAt: Date()))
            }
            let elapsed = start.duration(to: clock.now)
            let ms = max(1, Int((elapsed / .milliseconds(1)).rounded()))
            let status = GatewayStatus(try JSONDecoder().decode(JSONValue.self, from: data))
            return (.connected, GatewayDiagnostics(version: status.version,
                                                   authMode: authMode(for: status),
                                                   pingMS: ms,
                                                   lastError: nil,
                                                   checkedAt: Date()))
        } catch {
            let timedOut = (error as? URLError)?.code == .timedOut
            return (timedOut ? .asleep : .offline,
                    GatewayDiagnostics(lastError: shortMessage(for: error), checkedAt: Date()))
        }
    }

    static func authMode(for status: GatewayStatus) -> AuthMode {
        guard status.authRequired else { return .open }
        return status.supportsNativePKCE ? .oauth : .gated
    }

    /// System-localized, one line — these are diagnostics, not app voice.
    static func shortMessage(for error: Error) -> String {
        if let urlError = error as? URLError { return urlError.localizedDescription }
        if let gateway = error as? GatewayError { return gateway.message }
        switch error {
        case AuthError.sessionExpired: return "session expired"
        case AuthError.providerUnreachable: return "sign-in provider unreachable"
        case AuthError.unauthorized(let detail): return detail
        case AuthError.protocolError(let detail): return detail
        default: return (error as NSError).localizedDescription
        }
    }
}

enum SupervisedReconnectOutcome: Equatable {
    case success
    case retryable
    case reauth
    case stale
}

private struct SupervisedReconnectAuthority {
    let generation: Int
    let baseURL: URL
    let gatewayID: String
    let client: GatewayClient
    let credential: GatewayCredential

    var episodeSource: ConnectionSupervisor.EpisodeSource {
        ConnectionSupervisor.EpisodeSource(
            generation: generation, gatewayID: gatewayID, baseURL: baseURL,
            clientID: ObjectIdentifier(client))
    }
}

// MARK: - AppModel surface

extension AppModel {

    /// The gateway that needs a fresh sign-in, or nil. Observable: reading it
    /// from a view body subscribes to changes.
    public var needsReauth: URL? { ConnectionSupervisor.shared.reauthGateway }

    /// A supervised (manual / foreground) reconnect is dialing right now.
    public var isReconnecting: Bool { ConnectionSupervisor.shared.isReconnecting }

    /// Exact saved source whose host-agnostic post-boot reconnect episode has
    /// crossed the recovery escalation threshold.
    public var postBootReconnectRecovery: PostBootReconnectRecovery? {
        ConnectionSupervisor.shared.postBootRecovery
    }

    /// Last health probe for a saved gateway row.
    public func diagnostics(forGatewayID id: String) -> GatewayDiagnostics? {
        ConnectionSupervisor.shared.diagnostics[id]
    }

    /// True when this saved row is the gateway the live socket is bound to.
    public func isActiveGateway(_ gateway: SavedGateway) -> Bool {
        guard mode == .live, client != nil,
              let live = LiveRuntime.shared.baseURL, let base = gateway.baseURL else { return false }
        return live.absoluteString == base.absoluteString
    }

    // MARK: Supervision loop

    /// Start the app-lifetime link watch. Idempotent — ReauthBanner asks for it
    /// on appear and the scene-phase hook asks again, so supervision survives a
    /// banner that is torn down and rebuilt. Cheap: the Keychain is only read in
    /// the one state that can mean "reconnect gave up" — offline, nobody
    /// retrying.
    public func startLinkSupervision() {
        let supervisor = ConnectionSupervisor.shared
        guard supervisor.watchTask == nil else { return }
        supervisor.watchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self else { return }
                self.evaluateLinkHealth()
            }
        }
    }

    private func evaluateLinkHealth() {
        let supervisor = ConnectionSupervisor.shared
        let runtime = LiveRuntime.shared
        guard mode == .live, client != nil, let base = runtime.baseURL else { return }

        if !isOffline {
            supervisor.resetEpisode(for: .cleanOpen)
            // Only the live gateway's own banner is cleared here: a re-auth
            // raised for some other saved row (tapped while signed out) has to
            // survive a healthy current link.
            if supervisor.reauthGateway?.absoluteString == base.absoluteString {
                supervisor.reauthGateway = nil
            }
            return
        }
        // Somebody is already working on it.
        guard runtime.reconnectTask == nil, !supervisor.isReconnecting else { return }

        if supervisor.keychain.load(for: base) == nil {
            // GatewayClient has already dropped the expired Keychain
            // credential — the one state where the user must act.
            supervisor.reauthGateway = base
        } else if supervisor.reauthGateway == nil {
            // Offline, credential intact, no retry loop alive: the automatic
            // path either never started or ended on a non-auth failure. Take
            // it over rather than sit dark.
            scheduleSupervisedReconnect()
        }
    }

    // MARK: Foreground / manual entry points

    /// Scene-phase / UIKit wake hook. Validates the exact current socket
    /// before waiting on any saved-gateway HTTP diagnostics, then either
    /// enters supervised reconnect immediately or refreshes a healthy source.
    public func applicationDidBecomeActive() {
        startLinkSupervision()
        let supervisor = ConnectionSupervisor.shared
        // UIKit and SwiftUI normally publish the same foreground edge a few
        // milliseconds apart. Do not cancel a liveness RPC already crossing
        // the half-open transport: cancellation can retire its waiter while a
        // replacement request is still queued behind that same dead socket.
        // The check is bounded to three seconds, so one exact-source
        // single-flight is both faster and safer than cancel-and-restart.
        guard supervisor.foregroundValidationTask == nil else { return }
        let token = UUID()
        supervisor.foregroundValidationToken = token
        supervisor.foregroundValidationTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else {
                self?.clearForegroundValidation(ifOwned: token)
                return
            }
            let refreshSource: (client: GatewayClient, source: ConnectionSupervisor.EpisodeSource)?
            if mode == .live, let client,
               let capturedSource = currentReconnectAuthority()?.episodeSource {
                let liveness = await client.validateForegroundLiveness()
                guard !Task.isCancelled,
                      currentReconnectAuthority()?.episodeSource == capturedSource else {
                    self.clearForegroundValidation(ifOwned: token)
                    return
                }
                switch liveness {
                case .reconnectRequired:
                    // Release the single-flight before dialling so a later
                    // lock/unlock is not discarded while reconnect runs.
                    self.clearForegroundValidation(ifOwned: token)
                    reconnectNow()
                    return
                case .trafficFenced:
                    // Profile-lifecycle authority intentionally rejected local
                    // traffic. Do not mistake that for a dead socket.
                    self.clearForegroundValidation(ifOwned: token)
                    return
                case .healthy:
                    refreshSource = (client, capturedSource)
                }
            } else {
                refreshSource = nil
            }
            // End the lease after the exact socket verdict so a distinct later
            // wake can ping again while HTTP/roster/room refresh is still
            // running on this one.
            self.clearForegroundValidation(ifOwned: token)

            if let refreshSource {
                // Only ask the socket for liveness/session snapshots after the
                // explicit ping proved it survived suspension.
                foregroundReseed()
                await refreshConnectionHealth()
                guard mode == .live, self.client === refreshSource.client,
                      currentReconnectAuthority()?.episodeSource == refreshSource.source else {
                    return
                }
                guard await refreshSource.client.isConnected else {
                    reconnectNow()
                    return
                }
                if isOffline {
                    // The socket outlived the flag (a send failed, then the link
                    // recovered): the transport is the authority.
                    isOffline = false
                    if let base = LiveRuntime.shared.baseURL {
                        ConnectionRegistry.shared.noteState(.connected, forURL: base)
                        connections = ConnectionRegistry.shared.rows
                    }
                    await flushComposeQueue()
                }
                try? await refreshRoster()
                if let gatewayID = LiveRuntime.shared.gatewayID {
                    await pullAndReseedRoomProjection(gatewayID: gatewayID)
                }
            } else {
                await refreshConnectionHealth()
            }
        }
    }

    private func clearForegroundValidation(ifOwned token: UUID) {
        let supervisor = ConnectionSupervisor.shared
        guard supervisor.foregroundValidationToken == token else { return }
        supervisor.foregroundValidationTask = nil
        supervisor.foregroundValidationToken = nil
    }

    /// "Reconnect now" — abandons any backoff sleep and dials at once.
    public func reconnectNow() {
        let supervisor = ConnectionSupervisor.shared
        guard !supervisor.isReconnecting else { return }
        let source = currentReconnectAuthority()?.episodeSource
        let runtime = LiveRuntime.shared
        runtime.reconnectTask?.cancel()
        runtime.reconnectTask = nil
        supervisor.reconnectTaskToken = nil
        supervisor.resetEpisode(for: .manualWake, source: source)

        let token = UUID()
        supervisor.reconnectTaskToken = token
        runtime.reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.attemptReconnectOutcome(expected: source)
            guard supervisor.reconnectTaskToken == token else { return }
            supervisor.reconnectTaskToken = nil
            runtime.reconnectTask = nil
            if outcome == .retryable, let source {
                self.scheduleSupervisedReconnect(continuing: source)
            }
        }
    }

    /// Re-probe every saved gateway: state + ping into the registry (so the
    /// rows and the roster's net chip stay honest) and version / auth mode /
    /// last error into the diagnostics table the Connections rows render.
    public func refreshConnectionHealth() async {
        let registry = ConnectionRegistry.shared
        let saved = registry.saved
        guard !saved.isEmpty else { return }
        let healthProbe = ConnectionSupervisor.shared.healthProbe

        let results = await withTaskGroup(
            of: (SavedGateway, ConnectionState, GatewayDiagnostics).self
        ) { group -> [(SavedGateway, ConnectionState, GatewayDiagnostics)] in
            for gateway in saved {
                group.addTask { @Sendable in
                    let (state, diagnostics) = await healthProbe(gateway)
                    return (gateway, state, diagnostics)
                }
            }
            var rows: [(SavedGateway, ConnectionState, GatewayDiagnostics)] = []
            for await row in group { rows.append(row) }
            return rows
        }

        let supervisor = ConnectionSupervisor.shared
        for (gateway, state, fresh) in results {
            var merged = fresh
            // A failed probe knows nothing about the gateway itself; keep the
            // last good facts so the row does not blank out while a host naps.
            if merged.version == nil { merged.version = supervisor.diagnostics[gateway.id]?.version }
            if merged.authMode == .unknown,
               let previous = supervisor.diagnostics[gateway.id]?.authMode {
                merged.authMode = previous
            }
            supervisor.diagnostics[gateway.id] = merged
            if let base = gateway.baseURL {
                // The live socket is the better authority for its own row.
                if isActiveGateway(gateway), !isOffline {
                    registry.noteState(.connected, pingMS: merged.pingMS, forURL: base)
                } else {
                    // A REST probe is diagnostic for a saved secondary. It
                    // must not claim the live-source beacon merely because
                    // that gateway answered successfully.
                    let authRequired: Bool
                    switch merged.authMode {
                    case .open:
                        authRequired = false
                    case .oauth, .gated:
                        authRequired = true
                    case .unknown:
                        authRequired = registry.health[gateway.id]?.authRequired ?? false
                    }
                    registry.noteProbeHealth(
                        ConnectionRegistry.Health(state: state,
                                                 pingMS: merged.pingMS,
                                                 version: merged.version,
                                                 authRequired: authRequired),
                        forURL: base)
                }
            }
        }
        if mode == .live { connections = registry.rows }
    }

    // MARK: Reconnect mechanics

    /// One supervised dial. Re-dials the EXISTING client — GatewayClient.connect
    /// refreshes the OAuth tokens, mints a fresh single-use WS ticket and hangs
    /// a new transport off the same event fan-out, so the pump AppModelLive
    /// wired at connect time keeps delivering. Deliberately not connectGateway:
    /// that tears the link down and cancels whatever sits in
    /// LiveRuntime.reconnectTask — which, called from the backoff loop, would be
    /// the loop cancelling itself mid-dial.
    @discardableResult
    func attemptReconnect() async -> Bool {
        await attemptReconnectOutcome() == .success
    }

    private func currentReconnectAuthority() -> SupervisedReconnectAuthority? {
        let runtime = LiveRuntime.shared
        let registry = ConnectionRegistry.shared
        guard mode == .live, let base = runtime.baseURL,
              let gatewayID = runtime.gatewayID, let client,
              let saved = registry.gateway(forURL: base), saved.id == gatewayID,
              let credential = registry.credential(for: saved) else { return nil }
        return SupervisedReconnectAuthority(
            generation: runtime.generation, baseURL: base, gatewayID: gatewayID,
            client: client, credential: credential)
    }

    /// Focused package-test projection of the same exact source identity the
    /// scheduler captures; contains no credential prose beyond Equatable state.
    var currentReconnectSourceForTesting: ConnectionSupervisor.EpisodeSource? {
        currentReconnectAuthority()?.episodeSource
    }

    private func reconnectAuthorityIsCurrent(
        _ authority: SupervisedReconnectAuthority
    ) async -> Bool {
        let registry = ConnectionRegistry.shared
        guard reconnectSourceIdentityIsCurrent(authority),
              let saved = registry.gateway(forURL: authority.baseURL),
              let credential = registry.credential(for: saved),
              await authority.client.ownsCredential(credential),
              reconnectSourceIdentityIsCurrent(authority),
              registry.credential(for: saved) == credential else { return false }
        return true
    }

    private func reconnectSourceIdentityIsCurrent(
        _ authority: SupervisedReconnectAuthority
    ) -> Bool {
        let runtime = LiveRuntime.shared
        let registry = ConnectionRegistry.shared
        guard mode == .live, runtime.generation == authority.generation,
              runtime.baseURL?.absoluteString == authority.baseURL.absoluteString,
              runtime.gatewayID == authority.gatewayID,
              client === authority.client,
              let saved = registry.gateway(forURL: authority.baseURL),
              saved.id == authority.gatewayID else { return false }
        return true
    }

    private func reconnectSessionExpiryIsCurrent(
        _ authority: SupervisedReconnectAuthority
    ) -> Bool {
        guard reconnectSourceIdentityIsCurrent(authority),
              let saved = ConnectionRegistry.shared.gateway(forURL: authority.baseURL) else {
            return false
        }
        // GatewayClient deletes the exact expired credential before throwing.
        // A different replacement credential means another authority won and
        // this old error must not raise re-auth over it.
        let current = ConnectionRegistry.shared.credential(for: saved)
        return current == nil || current == authority.credential
    }

    private func adoptedReconnectAuthorityIsCurrent(
        _ authority: SupervisedReconnectAuthority, generation: Int
    ) async -> Bool {
        let runtime = LiveRuntime.shared
        let registry = ConnectionRegistry.shared
        guard mode == .live, runtime.generation == generation,
              runtime.baseURL?.absoluteString == authority.baseURL.absoluteString,
              runtime.gatewayID == authority.gatewayID,
              client === authority.client,
              let saved = registry.gateway(forURL: authority.baseURL),
              saved.id == authority.gatewayID,
              let credential = registry.credential(for: saved),
              await authority.client.ownsCredential(credential),
              mode == .live, runtime.generation == generation,
              runtime.baseURL?.absoluteString == authority.baseURL.absoluteString,
              runtime.gatewayID == authority.gatewayID,
              client === authority.client,
              registry.credential(for: saved) == credential else { return false }
        return true
    }

    func attemptReconnectOutcome(
        expected source: ConnectionSupervisor.EpisodeSource? = nil
    ) async -> SupervisedReconnectOutcome {
        let runtime = LiveRuntime.shared
        let supervisor = ConnectionSupervisor.shared
        guard !supervisor.isReconnecting else { return .stale }
        guard let authority = currentReconnectAuthority() else {
            // Missing credential is re-auth only when the remaining source
            // coordinates still describe the exact live row.
            if mode == .live, let base = runtime.baseURL,
               let gatewayID = runtime.gatewayID,
               let saved = ConnectionRegistry.shared.gateway(forURL: base),
               saved.id == gatewayID,
               ConnectionRegistry.shared.credential(for: saved) == nil {
                supervisor.reauthGateway = base
                return .reauth
            }
            return .stale
        }
        if let source, source != authority.episodeSource { return .stale }
        guard await reconnectAuthorityIsCurrent(authority) else { return .stale }

        // Fence Operator status before the first await below. This generation
        // remains in force on every exact-source failure path.
        OperatorSettingsRuntime.shared.beginReconnectAttempt()

        supervisor.isReconnecting = true
        defer { supervisor.isReconnecting = false }

        // Every cached runtime sid dies with the old socket; drop them before
        // dialing so nothing can submit into a session that no longer exists.
        let primaryChats = chats.filter { GatewayBotRoute(qualifiedID: $0.key) == nil }
        let parked = primaryChats.filter { $0.value.storedSessionID != nil }.map(\.key)
        for (botID, chat) in primaryChats {
            if let sessionID = chat.sessionID, !sessionID.isEmpty {
                runtime.reconnectParkedSessionIDs[botID] = sessionID
            }
            chat.sessionID = nil
            chat.isTyping = false
        }

        let registry = ConnectionRegistry.shared
        do {
            try await supervisor.dial(authority.client)
        } catch AuthError.sessionExpired {
            guard reconnectSessionExpiryIsCurrent(authority) else { return .stale }
            supervisor.reauthGateway = authority.baseURL
            supervisor.note(error: AuthError.sessionExpired,
                            forGatewayID: authority.gatewayID)
            isOffline = true
            return .reauth
        } catch {
            guard await reconnectAuthorityIsCurrent(authority) else { return .stale }
            isOffline = true
            registry.noteState(.offline, forURL: authority.baseURL)
            supervisor.note(error: error, forGatewayID: authority.gatewayID)
            connections = registry.rows
            return .retryable
        }

        guard await reconnectAuthorityIsCurrent(authority) else { return .stale }
        supervisor.reauthGateway = nil
        let adopted = await adoptReconnectedLink(authority: authority, parked: parked)
        return adopted ? .success : .stale
    }

    /// Post-dial housekeeping, mirroring AppModelLive's own reattach (that one
    /// is file-private, so the sequence is repeated rather than called): retire
    /// the old generation, re-arm the disconnect watch, re-resume every parked
    /// chat, then resync the surfaces the outage may have staled.
    private func adoptReconnectedLink(
        authority: SupervisedReconnectAuthority, parked: [String]
    ) async -> Bool {
        guard await reconnectAuthorityIsCurrent(authority) else { return false }
        let runtime = LiveRuntime.shared
        runtime.generation += 1
        let adoptedGeneration = runtime.generation
        OperatorSettingsRuntime.shared.completeReconnectAttempt()
        runtime.resetSessionState()
        // Pending approvals replay through session.resume below; keeping the
        // old cards would let the user answer request ids that no longer exist.
        approvals.removeAll { GatewayBotRoute(qualifiedID: $0.botID) == nil }
        isOffline = false
        ConnectionRegistry.shared.noteState(.connected, forURL: authority.baseURL)

        startSupervisedMonitor(for: authority.client, generation: adoptedGeneration)

        // ensureSession does the whole reattach: resume by durable key, bind the
        // new sid, replay the inflight snapshot and any pending approval. The
        // transcript is already in memory, so history is never re-hydrated.
        for botID in parked {
            guard await adoptedReconnectAuthorityIsCurrent(
                authority, generation: adoptedGeneration) else { return false }
            _ = try? await ensureSession(botID: botID, hydrate: false)
            guard await adoptedReconnectAuthorityIsCurrent(
                authority, generation: adoptedGeneration) else { return false }
        }

        try? await refreshRoster()
        guard await adoptedReconnectAuthorityIsCurrent(
            authority, generation: adoptedGeneration) else { return false }
        await refreshRoutinesLive(force: true)
        guard await adoptedReconnectAuthorityIsCurrent(
            authority, generation: adoptedGeneration) else { return false }
        await hideOwnedBotSessions()
        guard await adoptedReconnectAuthorityIsCurrent(
            authority, generation: adoptedGeneration) else { return false }
        connections = ConnectionRegistry.shared.rows
        await flushComposeQueue()
        guard await adoptedReconnectAuthorityIsCurrent(
            authority, generation: adoptedGeneration) else { return false }
        exactStoredSessionSourceDidReconnect()
        if let gatewayID = runtime.gatewayID {
            await pullAndReseedRoomProjection(gatewayID: gatewayID)
            guard await adoptedReconnectAuthorityIsCurrent(
                authority, generation: adoptedGeneration) else { return false }
        }
        ConnectionSupervisor.shared.resetEpisode(for: .cleanOpen)
        return true
    }

    /// Supervised reconnect finishes after the foreground/network callbacks
    /// that initiated it. Signal the retained exact-route queue only once the
    /// replacement link, roster, and parked sessions have been adopted.
    func exactStoredSessionSourceDidReconnect() {
        retryExactStoredSessionNavigation()
    }

    /// The client's event pump finishes exactly when the socket dies; awaiting
    /// it is the disconnect signal (ws-protocol §3 — liveness is socket-level).
    func startSupervisedMonitor(for client: GatewayClient, generation: Int) {
        let runtime = LiveRuntime.shared
        runtime.monitorTask?.cancel()
        runtime.monitorTask = Task { @MainActor [weak self] in
            guard let pump = await client.eventsTask else { return }
            await pump.value
            guard !Task.isCancelled, let self,
                  LiveRuntime.shared.generation == generation else { return }
            guard self.mode == .live, self.client != nil else { return }
            self.isOffline = true
            if let base = LiveRuntime.shared.baseURL {
                ConnectionRegistry.shared.noteState(.offline, forURL: base)
                self.connections = ConnectionRegistry.shared.rows
            }
            self.scheduleSupervisedReconnect()
        }
    }

    /// Host-agnostic unlimited full-jitter post-boot retry. Parks in
    /// LiveRuntime.reconnectTask; exact task tokens prevent a late old loop
    /// from clearing or rescheduling a successor.
    func scheduleSupervisedReconnect(
        continuing expectedSource: ConnectionSupervisor.EpisodeSource? = nil
    ) {
        let runtime = LiveRuntime.shared
        let supervisor = ConnectionSupervisor.shared
        guard runtime.reconnectTask == nil, !supervisor.isReconnecting,
              let currentSource = currentReconnectAuthority()?.episodeSource else { return }
        if let expectedSource, expectedSource != currentSource { return }
        if supervisor.episodeSource != currentSource {
            supervisor.resetEpisode(for: .manualWake, source: currentSource)
        }
        let token = UUID()
        supervisor.reconnectTaskToken = token
        runtime.reconnectTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, supervisor.reconnectTaskToken == token,
                      supervisor.episodeSource == currentSource else { return }
                let delay = PostBootReconnectPolicy.delay(
                    attempt: supervisor.episodeAttempt,
                    randomUnit: supervisor.randomUnit())
                do {
                    try await supervisor.sleep(delay.delay)
                } catch {
                    self.clearSupervisedReconnectTask(ifOwned: token)
                    return
                }
                guard !Task.isCancelled, supervisor.reconnectTaskToken == token,
                      supervisor.episodeSource == currentSource,
                      self.currentReconnectAuthority()?.episodeSource == currentSource else {
                    self.clearSupervisedReconnectTask(ifOwned: token)
                    return
                }
                self.publishRecoveryEscalationIfNeeded(source: currentSource)
                let outcome = await self.attemptReconnectOutcome(expected: currentSource)
                guard supervisor.reconnectTaskToken == token else { return }
                switch outcome {
                case .success:
                    self.clearSupervisedReconnectTask(ifOwned: token)
                    return
                case .reauth, .stale:
                    self.clearSupervisedReconnectTask(ifOwned: token)
                    return
                case .retryable:
                    supervisor.episodeAttempt &+= 1
                    self.publishRecoveryEscalationIfNeeded(source: currentSource)
                }
            }
            self?.clearSupervisedReconnectTask(ifOwned: token)
        }
    }

    private func publishRecoveryEscalationIfNeeded(
        source: ConnectionSupervisor.EpisodeSource
    ) {
        let supervisor = ConnectionSupervisor.shared
        guard supervisor.episodeSource == source,
              let startedAt = supervisor.episodeStartedAt else { return }
        let elapsed = max(0, supervisor.now() - startedAt)
        guard PostBootReconnectPolicy.shouldEscalateRecovery(elapsed: elapsed) else { return }
        supervisor.postBootRecovery = PostBootReconnectRecovery(
            gatewayID: source.gatewayID, baseURL: source.baseURL, elapsed: elapsed)
    }

    private func clearSupervisedReconnectTask(ifOwned token: UUID) {
        let supervisor = ConnectionSupervisor.shared
        guard supervisor.reconnectTaskToken == token else { return }
        supervisor.reconnectTaskToken = nil
        LiveRuntime.shared.reconnectTask = nil
    }

    // MARK: Re-auth completion

    /// Adopt a credential minted by the re-auth sheet and get back on the wire.
    public func completeReauth(baseURL: URL, credential: GatewayCredential) async {
        let registry = ConnectionRegistry.shared
        registry.upsert(urlString: baseURL.absoluteString, credential: credential)
        ConnectionSupervisor.shared.reauthGateway = nil

        let runtime = LiveRuntime.shared
        runtime.reconnectTask?.cancel()
        runtime.reconnectTask = nil
        ConnectionSupervisor.shared.reconnectTaskToken = nil

        if runtime.baseURL?.absoluteString == baseURL.absoluteString, client != nil {
            let outcome = await attemptReconnectOutcome()
            if outcome == .retryable {
                scheduleSupervisedReconnect()
            }
        } else if let saved = registry.gateway(forURL: baseURL) {
            await switchGateway(to: saved)
        }
        connections = registry.rows
    }

    /// Dismiss the banner without signing in (the gateway stays offline).
    public func dismissReauth() {
        ConnectionSupervisor.shared.reauthGateway = nil
    }

    // MARK: Multi-gateway (Connections row actions)

    /// Make `gateway` the live one. The previous gateway's world — roster,
    /// chats, approvals, routines — is flushed first: bot ids and session keys
    /// are per-gateway, so carrying them across would bind chats to sessions
    /// that do not exist on the new host.
    public func switchGateway(to gateway: SavedGateway) async {
        guard let base = gateway.baseURL else { return }
        let registry = ConnectionRegistry.shared
        guard let credential = registry.credential(for: gateway) else {
            // Saved metadata with no Keychain credential: signed out here, or
            // restored on a new device. Sign-in is the only way forward.
            ConnectionSupervisor.shared.reauthGateway = base
            return
        }
        // Already the live gateway: a "switch" to it is a reconnect, never a
        // teardown — flushing here would throw away chats for no reason.
        if isActiveGateway(gateway) {
            if isOffline { reconnectNow() }
            return
        }

        let supervisor = ConnectionSupervisor.shared
        guard !supervisor.isReconnecting else { return }
        supervisor.isReconnecting = true
        defer { supervisor.isReconnecting = false }

        let runtime = LiveRuntime.shared
        runtime.reconnectTask?.cancel()
        runtime.reconnectTask = nil
        supervisor.reconnectTaskToken = nil
        supervisor.resetEpisode(for: .manualWake)
        flushWorldForGatewaySwitch()

        do {
            try await runManagedCloudBootEpisode(
                sourceURL: base, gatewayID: gateway.id
            ) {
                if let switchConnect = supervisor.switchConnect {
                    try await switchConnect(self, base, credential)
                } else {
                    try await self.connectGateway(baseURL: base, credential: credential)
                }
            }
            supervisor.reauthGateway = nil
            supervisor.diagnostics[gateway.id]?.lastError = nil
        } catch is ManagedCloudBootSupersededError {
            // A newer primary transition superseded this switch while its
            // connect/boot work was suspended. That newer owner exclusively
            // decides the global offline flag and row health.
        } catch AuthError.sessionExpired {
            supervisor.reauthGateway = base
            supervisor.note(error: AuthError.sessionExpired, forGatewayID: gateway.id)
        } catch {
            isOffline = true
            registry.noteState(.offline, forURL: base)
            supervisor.note(error: error, forGatewayID: gateway.id)
        }
        connections = registry.rows
    }

    /// Rename a saved gateway (metadata only; the credential is keyed by URL).
    public func renameGateway(_ gateway: SavedGateway, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ConnectionRegistry.shared.rename(id: gateway.id, to: trimmed)
        connections = ConnectionRegistry.shared.rows
    }

    /// Forget the credential but keep the row: the gateway stays listed and
    /// probeable, and the next tap runs sign-in again.
    public func signOutGateway(_ gateway: SavedGateway) async {
        invalidateManagedCloudBootEpisode(gatewayID: gateway.id)
        ArtifactStore.shared.purge(gatewayID: gateway.id)
        AdvancedTerminalCoordinator.shared.stopAndForget(gatewayID: gateway.id)
        beginExactStoredSessionSourceTeardown(gatewayID: gateway.id)
        defer { finishExactStoredSessionSourceTeardown(gatewayID: gateway.id) }
        cancelRoomProjectionSync(gatewayID: gateway.id)
        guard let base = gateway.baseURL else {
            dropArtifactScope(gatewayID: gateway.id)
            return
        }
        if isActiveGateway(gateway) {
            await disconnectGateway()
            flushWorldForGatewaySwitch()
        } else {
            await detachRoutedEvents(gatewayID: gateway.id)
            await ConnectionRegistry.shared.clientPool.disconnect(gatewayID: gateway.id)
            // The first detach closes the old owner before the pool barrier.
            // This second pass closes anything that was already committed by
            // an exact open while that barrier was held.
            await detachRoutedEvents(gatewayID: gateway.id)
        }
        // Close the suspension window above: a new request that began after
        // the eager purge can no longer publish once the retained slot is gone.
        ArtifactStore.shared.purge(gatewayID: gateway.id)
        ConnectionSupervisor.shared.keychain.delete(for: base)
        // Detach/disconnect already dropped this source's scope. Repeat after
        // the Keychain delete so a late cache publish cannot outlive the
        // credential, and so a primary path that skipped detach still purges.
        dropArtifactScope(gatewayID: gateway.id)
        if ConnectionSupervisor.shared.reauthGateway?.absoluteString == base.absoluteString {
            ConnectionSupervisor.shared.reauthGateway = nil
        }
        connections = ConnectionRegistry.shared.rows
    }

    /// Remove the gateway entirely — registry row and Keychain credential.
    public func removeGateway(_ gateway: SavedGateway) async {
        invalidateManagedCloudBootEpisode(gatewayID: gateway.id)
        ArtifactStore.shared.purge(gatewayID: gateway.id)
        AdvancedTerminalCoordinator.shared.stopAndForget(gatewayID: gateway.id)
        beginExactStoredSessionSourceTeardown(gatewayID: gateway.id)
        defer { finishExactStoredSessionSourceTeardown(gatewayID: gateway.id) }
        cancelRoomProjectionSync(gatewayID: gateway.id)
        if isActiveGateway(gateway) {
            await disconnectGateway()
            flushWorldForGatewaySwitch()
        } else {
            await detachRoutedEvents(gatewayID: gateway.id)
            await ConnectionRegistry.shared.clientPool.disconnect(gatewayID: gateway.id)
            // A pool lease can keep an exact open alive across the first
            // detach. Scrub again after disconnect so no committed handler or
            // source-qualified runtime survives removal.
            await detachRoutedEvents(gatewayID: gateway.id)
        }
        ArtifactStore.shared.purge(gatewayID: gateway.id)
        dropArtifactScope(gatewayID: gateway.id)
        let supervisor = ConnectionSupervisor.shared
        if let base = gateway.baseURL,
           supervisor.reauthGateway?.absoluteString == base.absoluteString {
            supervisor.reauthGateway = nil
        }
        supervisor.diagnostics.removeValue(forKey: gateway.id)
        // ConnectionRegistry.remove deletes the Keychain credential with the row.
        ConnectionRegistry.shared.remove(id: gateway.id)
        connections = ConnectionRegistry.shared.rows
        // Reject a retained exact-session route now that its source is no
        // longer trusted, instead of leaving it parked until another launch.
        retryExactStoredSessionNavigation()
    }

    /// Drop the outgoing gateway's world. flushDemoWorld() is the single place
    /// that knows every primary surface to clear. Source-qualified remote chat
    /// and artifact state is restored afterward because those clients remain
    /// connected.
    private func flushWorldForGatewaySwitch() {
        if let departingGatewayID = LiveRuntime.shared.gatewayID {
            ChatRuntime.shared.clearPendingStops(forGatewayID: departingGatewayID)
            let primaryBots = Set(chats.keys.filter {
                stateRoute(for: $0)?.gatewayID == departingGatewayID
                    || (GatewayBotRoute(qualifiedID: $0)?.gatewayID == departingGatewayID)
            })
            ChatRuntime.shared.retirePrimaryMutationState(
                gatewayID: departingGatewayID, botIDs: primaryBots)
        }
        preservePrimaryUnreadForGatewaySwitch()
        let remoteChats = chats.filter { GatewayBotRoute(qualifiedID: $0.key) != nil }
        let remoteApprovals = approvals.filter { GatewayBotRoute(qualifiedID: $0.botID) != nil }
        let departingArtifactGatewayID = LiveRuntime.shared.gatewayID
        let remoteArtifacts = artifacts.filter { artifact in
            guard let ref = FeedsRuntime.shared.artifactSessions[artifact.id] else {
                return false
            }
            return departingArtifactGatewayID.map { ref.gatewayID != $0 } ?? true
        }
        normalizeComposeQueueIDs()
        let retainedQueue = zip(composeQueue, composeQueueIDs).filter {
            GatewayBotRoute(qualifiedID: $0.0.botID) != nil
        }
        let remoteQueue = retainedQueue.map { $0.0 }
        let remoteQueueIDs = retainedQueue.map { $0.1 }
        let remoteQueueIDSet = Set(remoteQueueIDs)
        let remoteQueueBindings = composeQueueBindings.filter { remoteQueueIDSet.contains($0.key) }
        let remoteOpenBot = openBotID.flatMap {
            GatewayBotRoute(qualifiedID: $0) == nil ? nil : $0
        }
        flushDemoWorld()
        chats = remoteChats
        approvals = remoteApprovals
        artifacts = remoteArtifacts
        composeQueue = remoteQueue
        composeQueueIDs = remoteQueueIDs
        composeQueueBindings = remoteQueueBindings
        ChatRuntime.shared.offlineComposeFences =
            ChatRuntime.shared.offlineComposeFences.filter { _, fence in
                GatewayBotRoute(qualifiedID: fence.botID) != nil
            }
        openBotID = remoteOpenBot
        let runtime = LiveRuntime.shared
        runtime.lastSessionByBot = runtime.lastSessionByBot.filter {
            GatewayBotRoute(qualifiedID: $0.key) != nil
        }
        runtime.defaultBotID = nil
        isOffline = false
    }
}

// MARK: - Banner

/// The persistent link banner: "sign in again" when reconnect stopped on an
/// expired session, otherwise the offline notice with a manual retry. Renders
/// nothing (zero height) when the link is healthy, and owns the supervision
/// loop for the life of the app — mount it once, at the top of the screen graph.
public struct ReauthBanner: View {
    private let model: AppModel

    /// Captured when the button is tapped so the sheet keeps its gateway even
    /// if the banner's own state clears underneath it.
    @State private var signInTarget: SignInTarget?

    public init(model: AppModel) {
        self.model = model
    }

    private struct SignInTarget: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    public var body: some View {
        VStack(spacing: 8) {
            if let gateway = model.needsReauth {
                card(tone: theme.danger) {
                    reauthContent(gateway)
                }
            } else if model.mode == .live, model.isOffline {
                card(tone: theme.warn) {
                    offlineContent
                }
            }
        }
        .padding(.horizontal, 16)
        .onAppear { model.startLinkSupervision() }
        .sheet(item: $signInTarget) { target in
            ReauthSheet(model: model, baseURL: target.url)
        }
    }

    // MARK: Content

    private func reauthContent(_ gateway: URL) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            headline(copy.reauthTitle(theme.id), tone: theme.danger)
            Text(copy.reauthBody(theme.id, host: gateway.host() ?? gateway.absoluteString))
                .font(bodyFont)
                .italic(theme.id == .ink)
                .foregroundStyle(theme.sub)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                LinkBannerButton(theme: theme, label: copy.reauthCTA(theme.id), role: .primary) {
                    signInTarget = SignInTarget(url: gateway)
                }
                LinkBannerButton(theme: theme, label: copy.later, role: .secondary) {
                    model.dismissReauth()
                }
            }
        }
    }

    /// Deliberately short: the roster already prints the full `copy.offline`
    /// sentence, and this card follows the user onto every other screen. What
    /// it adds is the manual retry.
    private var offlineContent: some View {
        HStack(spacing: 10) {
            headline(copy.linkDownTitle(theme.id), tone: theme.warn)
            Spacer(minLength: 8)
            LinkBannerButton(theme: theme,
                             label: model.isReconnecting ? copy.reconnecting(theme.id)
                                                         : copy.reconnectCTA(theme.id),
                             role: .primary) {
                model.reconnectNow()
            }
            .disabled(model.isReconnecting)
            .opacity(model.isReconnecting ? 0.6 : 1)
        }
    }

    private func headline(_ text: String, tone: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(tone)
                .frame(width: 7, height: 7)
                .shadow(color: theme.glowRadius > 0 ? tone : .clear, radius: theme.glowRadius / 2)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(text)
                .font(titleFont)
                .tracking(theme.id == .control ? 0.5 : 0)
                .foregroundStyle(tone)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card<Content: View>(tone: Color,
                                     @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(theme.id == .ink ? 12 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bannerBackground(tone))
            .overlay(bannerShape.strokeBorder(tone.opacity(theme.id == .soft ? 0.35 : 0.5),
                                              lineWidth: 1))
            .clipShape(bannerShape)
            .shadow(color: theme.id == .soft ? theme.ink.opacity(0.08) : .clear, radius: 8, y: 3)
    }

    private func bannerBackground(_ tone: Color) -> some View {
        ZStack {
            theme.panel
            tone.opacity(theme.id == .control ? 0.07 : 0.05)
        }
    }

    private var bannerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .ink ? 0 : theme.cardRadius, style: .continuous)
    }

    private var titleFont: Font {
        switch theme.id {
        case .soft: theme.body(13.5, weight: .bold)
        case .control: theme.mono(11, weight: .bold)
        case .ink: theme.body(15, weight: .bold).smallCaps()
        }
    }

    private var bodyFont: Font {
        switch theme.id {
        case .soft: theme.body(12.5)
        case .control: theme.mono(10)
        case .ink: theme.body(13.5)
        }
    }
}

/// Compact themed button for the banner (the flow buttons are full-width).
struct LinkBannerButton: View {
    enum Role { case primary, secondary }

    var theme: ThemePack
    var label: String
    var role: Role
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            text
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(background)
                .clipShape(shape)
                .overlay(shape.strokeBorder(border, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.buttonRadius, style: .continuous)
    }

    @ViewBuilder private var text: some View {
        switch theme.id {
        case .soft:
            Text(label).font(theme.body(12.5, weight: .bold)).foregroundStyle(foreground)
        case .control:
            Text(label).font(theme.mono(10, weight: .bold)).tracking(1).foregroundStyle(foreground)
        case .ink:
            Text(label).font(theme.body(13.5, weight: .bold).smallCaps()).tracking(1)
                .foregroundStyle(foreground)
        }
    }

    private var foreground: Color {
        switch role {
        case .primary: theme.id == .ink ? theme.bg : theme.accentFg
        case .secondary: theme.id == .ink ? theme.ink.opacity(0.7) : theme.sub
        }
    }

    private var background: Color {
        switch role {
        case .primary: theme.id == .ink ? theme.ink : theme.accent
        case .secondary: theme.id == .soft ? theme.ink.opacity(0.05) : .clear
        }
    }

    private var border: Color {
        role == .secondary ? theme.lineStrong : .clear
    }
}

// MARK: - Re-auth sheet

/// Re-runs sign-in against one known gateway. The stored-credential
/// short-circuit is disabled: we are here precisely because the stored one was
/// rejected, and a token that still answers /api/auth/me would otherwise send
/// the user straight back into the same failing reconnect.
private struct ReauthSheet: View {
    let model: AppModel
    let baseURL: URL

    @Environment(\.dismiss) private var dismiss
    @State private var auth = AuthController()

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    Text(baseURL.host() ?? baseURL.absoluteString)
                        .font(theme.id == .soft ? theme.body(13, weight: .semibold) : theme.mono(11))
                        .foregroundStyle(theme.sub)

                    GatewayAuthPhasePanel(auth: auth, theme: theme, copy: copy,
                                          onRetry: { probe() },
                                          onDemoSelect: nil)
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
        .task { probe() }
        .onChange(of: auth.phase) { _, phase in
            if phase == .done { finish() }
        }
        .onDisappear { auth.cancelSignIn() }
    }

    private var header: some View {
        HStack {
            Button {
                auth.cancelSignIn()
                dismiss()
            } label: {
                Text(copy.cancel)
                    .font(theme.id == .control ? theme.mono(11, weight: .semibold)
                                               : theme.body(14, weight: .semibold))
                    .foregroundStyle(theme.id == .ink ? theme.ink.opacity(0.55) : theme.accent)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(copy.reauthTitle(theme.id))
                .font(theme.id == .ink ? theme.display(20, weight: .bold).smallCaps()
                                       : theme.body(16, weight: .heavy))
                .foregroundStyle(theme.ink)

            Spacer()

            Text(copy.cancel)
                .font(theme.id == .control ? theme.mono(11, weight: .semibold)
                                           : theme.body(14, weight: .semibold))
                .hidden()
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private func probe() {
        Task { await auth.probe(baseURL.absoluteString, allowStoredCredential: false) }
    }

    private func finish() {
        guard let base = auth.baseURL, let credential = auth.credential else { return }
        Task { @MainActor in
            await model.completeReauth(baseURL: base, credential: credential)
        }
        dismiss()
    }
}

// MARK: - Copy (link supervision)

extension CopyPack {

    func reauthTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Sign in again"
        case .control: "AUTH EXPIRED"
        case .ink: "the seal has lapsed"
        }
    }

    func reauthBody(_ t: ThemeID, host: String) -> String {
        switch t {
        case .soft: "\(host) ended your session, so reconnecting stopped. Sign in to bring the link back."
        case .control: "\(host.uppercased()) REJECTED THE REFRESH TOKEN. RELINK REQUIRES A NEW SIGN-IN."
        case .ink: "The way to \(host) no longer knows your hand. Set your seal upon it again."
        }
    }

    func reauthCTA(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Sign in"
        case .control: "REAUTH"
        case .ink: "seal anew"
        }
    }

    /// Short link-down headline for the floating banner (the roster prints the
    /// full `offline` sentence in place).
    func linkDownTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Gateway unreachable"
        case .control: "LINK DOWN"
        case .ink: "the way is severed"
        }
    }

    func reconnectCTA(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Reconnect now"
        case .control: "RELINK NOW"
        case .ink: "mend the way"
        }
    }

    func reconnecting(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Reconnecting…"
        case .control: "RELINKING…"
        case .ink: "mending…"
        }
    }
}
