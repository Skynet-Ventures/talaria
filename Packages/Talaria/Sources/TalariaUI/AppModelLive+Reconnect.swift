import Foundation
import Observation
#if canImport(os)
import os
#endif
import SwiftUI
import TalariaKit
import TalariaTheme

/// UIKit's resign/active callbacks are the reliable iOS lifecycle edges.
/// SwiftUI's `scenePhase` remains useful, but production devices have shown
/// it can miss a lock-screen return while the mounted root view survives.
/// The app target posts these from `UIApplicationDelegate` and the root
/// funnels both sources through the same coalesced handlers.
public extension Notification.Name {
    static let talariaApplicationDidBecomeActive = Notification.Name(
        "bot.talaria.applicationDidBecomeActive")
    static let talariaApplicationWillResignActive = Notification.Name(
        "bot.talaria.applicationWillResignActive")
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
//   2. Foreground recovery. Device evidence, in order:
//      f3ad5b6 — ping-first on a parked URLSession.shared socket wedged
//      the session; hung `isReconnecting` made `reconnectNow()` a no-op.
//      5923674 — hard-redial + ephemeral session still looked dead because
//      adopt waited on a full `session.resume` of every parked forever-chat
//      (hydrate: false still downloaded history). Same 20s stall as first
//      open.
//      12594f3 — defer_history + roster-off-reconnect-adopt + wake trace.
//      Device still saw ~20s first load and a dead redial. History stayed.
//      The waits that exist on that build: connect() owned the single-consumer
//      `events` stream for the 15s gateway.ready bound (so the event pump
//      never ran and the supervised monitor treated the socket as already
//      dead); launch adoption awaited profiles.list (~20s) before arming
//      the monitor; open-chat attach awaited the 30s REST latest page after
//      defer_history was already on the wire.
//      Device journal (2026-08-29): repeated `Gateway unreachable` /
//      `100.87.108.5`, last recovered 2026-08-28. Port repair to :9119
//      worked (Mini saw the phone; Connections shows :9119 · 570ms). Wake
//      still skipped redial with banner `didBecomeActive already-active`
//      while HTTP was healthy and the live socket stayed offline. Opening
//      the Hermes default chat still stalled: Mini `ws write slow >10s`
//      dumping a 584-msg / ~360k-token resume frame. Already-active must
//      redial when offline; canonical open must not await that fat frame.
//      8cea17a — already-active skip fixed (`redial.scheduled
//      after-background`), but dial never reached `connect.started`:
//      unbounded await on hung background invalidate + dual wake clearing
//      suspendedForBackground inside the Task. Cap invalidate, cancel it
//      on reconnectNow, capture the after-background edge synchronously.
//      a9e387c — dial path advanced; banner dead-ended on
//      `reconnect.stale authority`. Pre-dial fence required the live client
//      to already own the registry credential; OAuth/port-repair drift
//      failed ownsCredential and reconnectNow did not retry `.stale`.
//      Rebind registry → client on the same live row, then dial.
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
    /// Incremented by every user-visible wake/manual reconnect so a hung
    /// background dial cannot keep `isReconnecting` or publish after it
    /// is superseded.
    @ObservationIgnored var reconnectGeneration = 0
    /// True after the process left the foreground. The next active edge
    /// always hard-redials; it must not write to the parked socket.
    @ObservationIgnored var suspendedForBackground = false
    /// Resign closes the transport off the wake path. The next dial waits
    /// for this so connect() does not race the teardown.
    @ObservationIgnored var backgroundInvalidateTask: Task<Void, Never>?
    /// Client-side breadcrumbs for the next device fail: resign, wake,
    /// connect, ready, resume, adopt. Shown on the offline banner after a
    /// real failure — not during the wake-redial grace window.
    var reconnectTrace: [ReconnectTraceEvent] = []
    var lastReconnectStep = ""
    /// Uptime deadline while "Gateway unreachable" chrome stays hidden for
    /// an expected after-background redial. Observable so roster/banner
    /// update when grace begins or ends.
    var offlineChromeGraceUntil: TimeInterval?
    @ObservationIgnored var offlineChromeGraceTask: Task<Void, Never>?
    /// Single-flight foreground wake. UIKit and SwiftUI publish the same
    /// edge a few milliseconds apart.
    @ObservationIgnored var foregroundValidationTask: Task<Void, Never>?
    @ObservationIgnored var foregroundValidationToken: UUID?
    @ObservationIgnored var episodeSource: EpisodeSource?
    @ObservationIgnored var episodeStartedAt: TimeInterval?
    @ObservationIgnored var episodeAttempt = 0
    @ObservationIgnored var sleep: Sleep = ConnectionSupervisor.productionSleep
    @ObservationIgnored var randomUnit: RandomUnit = { Double.random(in: 0..<1) }
    @ObservationIgnored var now: Now = { ProcessInfo.processInfo.systemUptime }
    @ObservationIgnored var dial: Dial = { client in
        try await client.connect(
            readyTimeout: PostBootReconnectPolicy.redialReadyTimeout)
    }
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
        dial = { client in
            try await client.connect(
                readyTimeout: PostBootReconnectPolicy.redialReadyTimeout)
        }
        switchConnect = nil
        reconnectTaskToken = nil
        reconnectGeneration = 0
        suspendedForBackground = false
        backgroundInvalidateTask = nil
        reconnectTrace = []
        lastReconnectStep = ""
        endOfflineChromeGrace()
        foregroundValidationTask?.cancel()
        foregroundValidationTask = nil
        foregroundValidationToken = nil
        resetEpisode(for: .cleanOpen)
        isReconnecting = false
        reauthGateway = nil
    }

    /// True while the brief wake-redial grace window is still open.
    var isOfflineChromeGraceActive: Bool {
        guard let until = offlineChromeGraceUntil else { return false }
        return now() < until
    }

    /// Start/refresh the presentation grace that hides unreachable chrome
    /// during an expected foreground redial.
    func beginOfflineChromeGrace(
        seconds: TimeInterval = PostBootReconnectPolicy.offlineChromeGrace
    ) {
        let deadline = now() + max(0, seconds)
        offlineChromeGraceUntil = deadline
        offlineChromeGraceTask?.cancel()
        offlineChromeGraceTask = Task { @MainActor in
            let remaining = max(0, deadline - ConnectionSupervisor.shared.now())
            let ns = UInt64(remaining * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            let supervisor = ConnectionSupervisor.shared
            if supervisor.offlineChromeGraceUntil == deadline {
                supervisor.offlineChromeGraceUntil = nil
            }
        }
    }

    func endOfflineChromeGrace() {
        offlineChromeGraceTask?.cancel()
        offlineChromeGraceTask = nil
        offlineChromeGraceUntil = nil
    }

    func note(error: Error, forGatewayID id: String?) {
        guard let id else { return }
        var entry = diagnostics[id] ?? GatewayDiagnostics()
        entry.lastError = GatewayDiagnostics.shortMessage(for: error)
        entry.checkedAt = Date()
        diagnostics[id] = entry
    }

    func noteReconnect(_ step: String, _ detail: String = "") {
        let label = detail.isEmpty ? step : "\(step) \(detail)"
        lastReconnectStep = label
        reconnectTrace.append(ReconnectTraceEvent(step: step, detail: detail))
        if reconnectTrace.count > 32 {
            reconnectTrace.removeFirst(reconnectTrace.count - 32)
        }
        #if canImport(os)
        ReconnectTraceLog.logger.info("\(label, privacy: .public)")
        #endif
        switch step {
        case "redial.scheduled":
            beginOfflineChromeGrace()
        case "adopted":
            // Clear after isOffline is already false inside adopt.
            endOfflineChromeGrace()
        case "connect.failed", "resume.failed":
            // Real dial/resume failure — show unreachable chrome again.
            endOfflineChromeGrace()
        default:
            break
        }
    }

    /// Device-facing reason. A dead wake must say whether connect timed out,
    /// resume failed, or UIKit never delivered `didBecomeActive`. Prefer the
    /// newest actionable dial step so a stuck `redial.scheduled` is not
    /// hidden behind a later no-op breadcrumb.
    var bannerReason: String {
        guard let last = reconnectTrace.last else { return lastReconnectStep }
        switch last.step {
        case "connect.failed", "connect.started", "gateway.ready",
             "redial.scheduled", "invalidate.timeout", "reconnect.stale":
            return last.detail.isEmpty ? last.step : "\(last.step) \(last.detail)"
        case "resume.failed":
            return last.detail.isEmpty ? "resume.failed" : "resume.failed \(last.detail)"
        case "resign", "transport.dropped":
            return "never got didBecomeActive (\(last.step))"
        default:
            return lastReconnectStep
        }
    }
}

/// One breadcrumb on the reconnect path. Device verify of 5923674 had no
/// client-side reason; the next fail must say which step ran last.
struct ReconnectTraceEvent: Equatable, Sendable {
    var step: String
    var detail: String
}

#if canImport(os)
private enum ReconnectTraceLog {
    static let logger = Logger(subsystem: "bot.talaria", category: "reconnect")
}
#endif

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

    /// Last reconnect breadcrumb (resign / wake / connect / resume / adopt).
    /// Classified for the offline banner: `connect.failed`, `resume.failed`,
    /// or `never got didBecomeActive` when resign ran and the wake never did.
    public var lastReconnectStep: String { ConnectionSupervisor.shared.bannerReason }

    /// 1-based try shown on the banner while a redial episode is alive.
    public var reconnectTryNumber: Int {
        let supervisor = ConnectionSupervisor.shared
        if supervisor.isReconnecting { return supervisor.episodeAttempt + 1 }
        return max(supervisor.episodeAttempt, 0)
    }

    /// Supervised backoff loop is parked between tries.
    public var isSupervisedReconnectLooping: Bool {
        LiveRuntime.shared.reconnectTask != nil
    }

    /// Brief after-background redial window where unreachable chrome is noise.
    public var isWakeRedialGraceActive: Bool {
        ConnectionSupervisor.shared.isOfflineChromeGraceActive
    }

    /// Global "Gateway unreachable" banner + roster strip. Hidden during the
    /// healthy wake-redial grace; shown on real failure, recovery escalation,
    /// or when grace expires while still offline.
    public var showsOfflineUnreachableChrome: Bool {
        let supervisor = ConnectionSupervisor.shared
        // Touch observable grace field so views refresh when it clears.
        _ = supervisor.offlineChromeGraceUntil
        return PostBootReconnectPolicy.showsUnreachableChrome(
            isOffline: isOffline,
            graceActive: supervisor.isOfflineChromeGraceActive,
            needsReauth: supervisor.reauthGateway != nil,
            hasPostBootRecovery: supervisor.postBootRecovery != nil)
    }

    /// Package-test projection of the reconnect breadcrumb log.
    var reconnectTraceForTesting: [String] {
        ConnectionSupervisor.shared.reconnectTrace.map(\.step)
    }

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

        if supervisor.suspendedForBackground { return }

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

    /// UIKit / scene-phase resign. Drop the live socket without writing to it.
    /// A ping or RPC on a parked URLSessionWebSocket wedges the session and
    /// the next dial never returns — that is the device-verified failure of
    /// the ping-first wake path.
    public func applicationWillResignActive() {
        let supervisor = ConnectionSupervisor.shared
        guard mode == .live, client != nil else { return }
        supervisor.suspendedForBackground = true
        // Mark offline synchronously. Teardown is async and may be cancelled
        // by the wake dial; the banner and link watch must not believe the
        // parked socket is still live in that window.
        isOffline = true
        if let base = LiveRuntime.shared.baseURL {
            ConnectionRegistry.shared.noteState(.offline, forURL: base)
            connections = ConnectionRegistry.shared.rows
        }
        // A mid-background dial is what made the first wake a no-op
        // (`isReconnecting` stayed true, `reconnectNow` returned). Cancel it
        // and bump generation so a hung attempt cannot publish after we
        // drop the socket. Do not start a replacement dial here — iOS is
        // about to park the process.
        let runtime = LiveRuntime.shared
        runtime.reconnectTask?.cancel()
        runtime.reconnectTask = nil
        supervisor.reconnectTaskToken = nil
        supervisor.reconnectGeneration &+= 1
        supervisor.isReconnecting = false
        supervisor.foregroundValidationTask?.cancel()
        supervisor.foregroundValidationTask = nil
        supervisor.foregroundValidationToken = nil
        supervisor.noteReconnect("resign")
        // scenePhase + UIKit + didEnterBackground can fire resign thrice.
        // Cancel the prior teardown so we do not pile hung close() awaits.
        supervisor.backgroundInvalidateTask?.cancel()
        supervisor.backgroundInvalidateTask = Task { @MainActor [weak self] in
            await self?.invalidateLiveTransportForBackground()
            guard !Task.isCancelled else { return }
            ConnectionSupervisor.shared.noteReconnect("transport.dropped")
        }
    }

    /// Close the parked transport. Offline was already published on resign —
    /// this only retires the socket. Session bindings and transcripts stay
    /// put; a resign must not hydrate, rebind, or empty the open chat.
    func invalidateLiveTransportForBackground() async {
        guard mode == .live, let client else { return }
        await client.invalidateTransportForBackground()
        isOffline = true
        if let base = LiveRuntime.shared.baseURL {
            ConnectionRegistry.shared.noteState(.offline, forURL: base)
            connections = ConnectionRegistry.shared.rows
        }
    }

    /// Scene-phase / UIKit wake hook. After the process was parked, always
    /// hard-redial. Never probe the old socket, and never wait on HTTP
    /// diagnostics or roster refresh before the replacement link is adopted.
    ///
    /// Device (5497344): banner `didBecomeActive already-active` while the
    /// Connections HTTP probe was healthy (`:9119`, 570ms) and the live
    /// socket stayed offline. "Already-active" must not skip redial when
    /// unreachable — HTTP health is not a live WebSocket.
    ///
    /// Device (8cea17a): wake noted `redial.scheduled after-background` but
    /// never `connect.started`. Concurrent scenePhase + UIKit + liveness
    /// wakes cleared `suspendedForBackground` inside the first Task, then
    /// cancelled that Task before `reconnectNow()` while a later wake took
    /// the already-active path. Capture the after-background edge
    /// synchronously so every coalesced wake still hard-redials.
    public func applicationDidBecomeActive() {
        startLinkSupervision()
        let supervisor = ConnectionSupervisor.shared
        // Synchronous edge capture — before any Task hop — so dual wake
        // notifications cannot turn after-background into already-active.
        let wasBackgrounded = supervisor.suspendedForBackground
        if wasBackgrounded {
            supervisor.suspendedForBackground = false
        }
        let forceRedial = wasBackgrounded || isOffline
        // Presentation only: hide unreachable chrome before the first post-wake
        // frame paints. Dial ownership is unchanged.
        if forceRedial {
            supervisor.beginOfflineChromeGrace()
        }
        // A prior already-active refresh must not hold a lease that blocks
        // redial when we are offline or were backgrounded.
        if supervisor.foregroundValidationTask != nil {
            if forceRedial {
                supervisor.foregroundValidationTask?.cancel()
                supervisor.foregroundValidationTask = nil
                supervisor.foregroundValidationToken = nil
            } else {
                return
            }
        }
        let token = UUID()
        supervisor.foregroundValidationToken = token
        supervisor.foregroundValidationTask = Task { @MainActor [weak self] in
            defer { self?.clearForegroundValidation(ifOwned: token) }
            guard !Task.isCancelled, let self else { return }

            supervisor.noteReconnect(
                "didBecomeActive", wasBackgrounded ? "after-background" : "already-active")

            guard mode == .live, client != nil,
                  currentReconnectAuthority() != nil else {
                supervisor.noteReconnect("wake.skipped", "no-authority")
                await refreshConnectionHealth()
                return
            }

            if wasBackgrounded {
                // Resign already dropped the socket. Hard-redial; do not
                // write onto whatever transport is still installed.
                supervisor.noteReconnect("redial.scheduled", "after-background")
                reconnectNow()
                return
            }

            // Already-active + offline/unreachable: always redial. Clearing
            // isOffline here (pre-5497344) left the banner dark while HTTP
            // still painted LIVE · 570ms on Connections.
            if isOffline {
                supervisor.noteReconnect("redial.scheduled", "already-active-offline")
                reconnectNow()
                return
            }

            guard let client, await client.isConnected else {
                supervisor.noteReconnect("redial.scheduled", "already-active-not-ready")
                reconnectNow()
                return
            }
            foregroundReseed()
            await refreshConnectionHealth()
            try? await refreshRoster()
            if let gatewayID = LiveRuntime.shared.gatewayID {
                await pullAndReseedRoomProjection(gatewayID: gatewayID)
            }
        }
    }

    private func clearForegroundValidation(ifOwned token: UUID) {
        let supervisor = ConnectionSupervisor.shared
        guard supervisor.foregroundValidationToken == token else { return }
        supervisor.foregroundValidationTask = nil
        supervisor.foregroundValidationToken = nil
    }

    /// "Reconnect now" — abandons any backoff sleep or hung dial and starts
    /// a fresh attempt. A wake must be able to supersede a background dial
    /// that is still sitting in `isReconnecting`.
    public func reconnectNow() {
        let supervisor = ConnectionSupervisor.shared
        let source = currentReconnectAuthority()?.episodeSource
        let runtime = LiveRuntime.shared
        runtime.reconnectTask?.cancel()
        runtime.reconnectTask = nil
        supervisor.reconnectTaskToken = nil
        supervisor.reconnectGeneration &+= 1
        supervisor.isReconnecting = false
        // Device 8cea17a: banner stuck on `redial.scheduled after-background`
        // with no `connect.started`. The dial was awaiting a hung resign
        // teardown. Drop that wait — `connect()` retires any leftover
        // transport — so the replacement attempt can actually dial.
        supervisor.backgroundInvalidateTask?.cancel()
        supervisor.backgroundInvalidateTask = nil
        supervisor.resetEpisode(for: .manualWake, source: source)

        let generation = supervisor.reconnectGeneration
        let token = UUID()
        supervisor.reconnectTaskToken = token
        runtime.reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.attemptReconnectOutcome(
                expected: source, generation: generation)
            guard supervisor.reconnectTaskToken == token else { return }
            supervisor.reconnectTaskToken = nil
            runtime.reconnectTask = nil
            switch outcome {
            case .retryable:
                if let continuing = self.currentReconnectAuthority()?.episodeSource ?? source {
                    self.scheduleSupervisedReconnect(continuing: continuing)
                }
            case .stale:
                // Device a9e387c: wake dead-ended on `reconnect.stale
                // authority` with no further try. A foreground return that
                // still owns an offline live row must keep dialing.
                if self.isOffline,
                   let fresh = self.currentReconnectAuthority()?.episodeSource {
                    self.scheduleSupervisedReconnect(continuing: fresh)
                }
            case .success, .reauth:
                break
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
        await reconnectAuthorityFailureReason(authority) == nil
    }

    /// Why the pre-dial fence rejected this authority, for banner diagnosis.
    private func reconnectAuthorityFailureReason(
        _ authority: SupervisedReconnectAuthority
    ) async -> String? {
        guard reconnectSourceIdentityIsCurrent(authority) else {
            return reconnectSourceIdentityFailureReason(authority)
        }
        let registry = ConnectionRegistry.shared
        guard let saved = registry.gateway(forURL: authority.baseURL) else {
            return "authority saved-row"
        }
        guard let credential = registry.credential(for: saved) else {
            return "authority credential-missing"
        }
        guard await authority.client.ownsCredential(credential) else {
            return "authority credential"
        }
        guard reconnectSourceIdentityIsCurrent(authority) else {
            return reconnectSourceIdentityFailureReason(authority)
        }
        guard registry.credential(for: saved) == credential else {
            return "authority credential-race"
        }
        return nil
    }

    private func reconnectSourceIdentityIsCurrent(
        _ authority: SupervisedReconnectAuthority
    ) -> Bool {
        reconnectSourceIdentityFailureReason(authority) == nil
    }

    private func reconnectSourceIdentityFailureReason(
        _ authority: SupervisedReconnectAuthority
    ) -> String? {
        let runtime = LiveRuntime.shared
        let registry = ConnectionRegistry.shared
        guard mode == .live else { return "authority mode" }
        guard runtime.generation == authority.generation else {
            return "authority generation"
        }
        guard runtime.baseURL?.absoluteString == authority.baseURL.absoluteString else {
            return "authority base"
        }
        guard runtime.gatewayID == authority.gatewayID else {
            return "authority gateway"
        }
        guard client === authority.client else { return "authority client" }
        guard let saved = registry.gateway(forURL: authority.baseURL),
              saved.id == authority.gatewayID else {
            return "authority saved-row"
        }
        return nil
    }

    /// Same live gateway row as the wake/manual episode. Allow :9119 repair
    /// (baseURL string) and credential/client rebind on that row — those are
    /// how a foreground return recovers. A different gatewayID or live
    /// generation is a real source switch and must stay stale.
    private func reconnectSourceCompatible(
        _ expected: ConnectionSupervisor.EpisodeSource,
        with authority: SupervisedReconnectAuthority
    ) -> Bool {
        expected.gatewayID == authority.gatewayID
            && expected.generation == authority.generation
    }

    /// Registry/Keychain is source of truth after background. Port repair and
    /// OAuth refresh can desync the in-memory client; adopt before dial so
    /// the fence does not dead-end on `reconnect.stale authority`.
    private func rebindReconnectAuthorityIfNeeded(
        _ authority: SupervisedReconnectAuthority
    ) async -> SupervisedReconnectAuthority? {
        if await reconnectAuthorityIsCurrent(authority) { return authority }

        // Live row may already point at a replacement client for the same
        // gateway (wake vs pool). Prefer that over the captured pointer.
        if let live = currentReconnectAuthority(),
           live.gatewayID == authority.gatewayID,
           live.generation == authority.generation,
           await reconnectAuthorityIsCurrent(live) {
            if live.client !== authority.client {
                ConnectionSupervisor.shared.noteReconnect("client.rebound")
            }
            return live
        }

        guard reconnectSourceIdentityIsCurrent(authority) else { return nil }
        let registry = ConnectionRegistry.shared
        guard let saved = registry.gateway(forURL: authority.baseURL),
              let credential = registry.credential(for: saved) else { return nil }
        if await authority.client.ownsCredential(credential) {
            return await reconnectAuthorityIsCurrent(authority) ? authority : nil
        }
        await authority.client.adoptCredential(credential)
        ConnectionSupervisor.shared.noteReconnect("credential.rebound")
        let rebound = SupervisedReconnectAuthority(
            generation: authority.generation,
            baseURL: authority.baseURL,
            gatewayID: authority.gatewayID,
            client: authority.client,
            credential: credential)
        return await reconnectAuthorityIsCurrent(rebound) ? rebound : nil
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
        expected source: ConnectionSupervisor.EpisodeSource? = nil,
        generation claimedGeneration: Int? = nil
    ) async -> SupervisedReconnectOutcome {
        let runtime = LiveRuntime.shared
        let supervisor = ConnectionSupervisor.shared
        // Capture the caller's generation BEFORE any await. A wake that
        // increments `reconnectGeneration` while this attempt is already
        // past the first guard used to steal the new generation, set
        // `isReconnecting`, and make the replacement dial return `.stale`.
        let attemptGeneration = claimedGeneration ?? supervisor.reconnectGeneration
        func stale(_ reason: String) -> SupervisedReconnectOutcome {
            // Do not overwrite a newer wake's breadcrumb with a superseded
            // attempt's stale note — the banner must show the live dial.
            if supervisor.reconnectGeneration == attemptGeneration {
                supervisor.noteReconnect("reconnect.stale", reason)
            }
            return .stale
        }
        guard supervisor.reconnectGeneration == attemptGeneration else {
            return stale("generation")
        }
        // Another dial already holds the fence for this generation. Stay
        // silent — noting `reconnect.stale busy` would overwrite the live
        // attempt's `connect.started` on the banner.
        guard !supervisor.isReconnecting else { return .stale }
        supervisor.isReconnecting = true
        defer {
            if supervisor.reconnectGeneration == attemptGeneration {
                supervisor.isReconnecting = false
            }
        }

        let registry = ConnectionRegistry.shared
        // Repair :9119 before capturing authority so the wake episode source
        // and the live row agree on one baseURL. Doing this after the fence
        // made a repaired runtime look like a different authority.
        if let base = runtime.baseURL {
            let wire = registry.repairStoredBase(matching: base)
            if wire.absoluteString != base.absoluteString {
                runtime.baseURL = wire
                supervisor.noteReconnect("url.repaired", GatewayURL.originForDisplay(wire))
            }
        }

        guard let captured = currentReconnectAuthority() else {
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
            return stale("no-authority")
        }
        if let source, !reconnectSourceCompatible(source, with: captured) {
            return stale("source-mismatch")
        }
        guard supervisor.reconnectGeneration == attemptGeneration else {
            return stale("generation")
        }
        guard let authority = await rebindReconnectAuthorityIfNeeded(captured) else {
            let reason = await reconnectAuthorityFailureReason(captured) ?? "authority"
            return stale(reason)
        }
        guard supervisor.reconnectGeneration == attemptGeneration else {
            return stale("generation")
        }

        // Fence Operator status before the first await below. This generation
        // remains in force on every exact-source failure path.
        OperatorSettingsRuntime.shared.beginReconnectAttempt()

        if let pending = supervisor.backgroundInvalidateTask {
            supervisor.noteReconnect("invalidate.await")
            let finished = await Self.awaitBackgroundInvalidate(
                pending,
                seconds: PostBootReconnectPolicy.backgroundInvalidateTimeout)
            if supervisor.backgroundInvalidateTask != nil {
                supervisor.backgroundInvalidateTask = nil
            }
            if !finished {
                supervisor.noteReconnect("invalidate.timeout")
                pending.cancel()
            }
        }
        guard supervisor.reconnectGeneration == attemptGeneration else {
            return stale("generation")
        }
        if Task.isCancelled { return stale("cancelled") }

        // Re-check after invalidate await — a dual wake may have rebound the
        // live row. Prefer a fresh same-gateway authority over dead-ending.
        guard let liveAuthority = await rebindReconnectAuthorityIfNeeded(
            currentReconnectAuthority() ?? authority
        ) else {
            let reason = await reconnectAuthorityFailureReason(authority) ?? "authority"
            return stale(reason)
        }
        if let source, !reconnectSourceCompatible(source, with: liveAuthority) {
            return stale("source-mismatch")
        }

        do {
            let tryNumber = supervisor.episodeAttempt + 1
            supervisor.noteReconnect(
                "connect.started",
                "try \(tryNumber) \(GatewayURL.originForDisplay(liveAuthority.baseURL))")
            try await supervisor.dial(liveAuthority.client)
            supervisor.noteReconnect("gateway.ready")
        } catch AuthError.sessionExpired {
            guard supervisor.reconnectGeneration == attemptGeneration,
                  reconnectSessionExpiryIsCurrent(liveAuthority) else {
                return stale("session-fence")
            }
            supervisor.noteReconnect("connect.failed", "session-expired")
            supervisor.reauthGateway = liveAuthority.baseURL
            supervisor.note(error: AuthError.sessionExpired,
                            forGatewayID: liveAuthority.gatewayID)
            isOffline = true
            return .reauth
        } catch {
            guard supervisor.reconnectGeneration == attemptGeneration,
                  await reconnectAuthorityIsCurrent(liveAuthority) else {
                return stale("fail-fence")
            }
            supervisor.noteReconnect("connect.failed", GatewayDiagnostics.shortMessage(for: error))
            isOffline = true
            registry.noteState(.offline, forURL: liveAuthority.baseURL)
            supervisor.note(error: error, forGatewayID: liveAuthority.gatewayID)
            connections = registry.rows
            return .retryable
        }

        guard supervisor.reconnectGeneration == attemptGeneration,
              await reconnectAuthorityIsCurrent(liveAuthority) else {
            return stale("adopt-fence")
        }
        // Park runtime sids only after the replacement socket is up. Doing
        // this before a dial that then fails left the open chat unbound and
        // invited a hydrate to replace its transcript with an empty page.
        let parked = parkPrimarySessionsForReconnect()
        supervisor.reauthGateway = nil
        let adopted = await adoptReconnectedLink(authority: liveAuthority, parked: parked)
        return adopted ? .success : stale("adopt")
    }

    /// Wait for resign teardown, but never longer than `seconds`. A hung
    /// `close()` left device 8cea17a on `redial.scheduled` with no dial.
    private static func awaitBackgroundInvalidate(
        _ pending: Task<Void, Never>, seconds: TimeInterval
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await pending.value
                return true
            }
            group.addTask {
                let ns = UInt64(max(seconds, 0) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                return false
            }
            let finished = await group.next() ?? false
            group.cancelAll()
            return finished
        }
    }

    /// Remember durable chats and drop only the dead runtime sid. Transcripts
    /// stay in memory — `ensureSession(hydrate: false)` rebinds them.
    func parkPrimarySessionsForReconnect() -> [String] {
        let primaryChats = chats.filter { GatewayBotRoute(qualifiedID: $0.key) == nil }
        let parked = primaryChats.filter { $0.value.storedSessionID != nil }.map(\.key)
        for (botID, chat) in primaryChats {
            if let sessionID = chat.sessionID, !sessionID.isEmpty {
                LiveRuntime.shared.reconnectParkedSessionIDs[botID] = sessionID
            }
            chat.sessionID = nil
            chat.isTyping = false
        }
        return parked
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

        // Bind with defer_history (open-chat policy). The 5923674 device fail
        // waited here on a full session.resume of every parked forever-chat
        // (hydrate: false still downloaded history, then threw it away). That
        // is the same 20s MainActor stall as first-open. Do not hydrate.
        let bindOrder = parked.sorted { left, right in
            left == openBotID && right != openBotID
        }
        for botID in bindOrder {
            guard await adoptedReconnectAuthorityIsCurrent(
                authority, generation: adoptedGeneration) else { return false }
            ConnectionSupervisor.shared.noteReconnect("resume.sent", botID)
            _ = try? await ensureSession(botID: botID, hydrate: false)
            let bound = chats[botID]?.sessionID?.isEmpty == false
            ConnectionSupervisor.shared.noteReconnect(
                bound ? "resume.ack" : "resume.failed", botID)
            guard await adoptedReconnectAuthorityIsCurrent(
                authority, generation: adoptedGeneration) else { return false }
        }

        connections = ConnectionRegistry.shared.rows
        await flushComposeQueue()
        guard await adoptedReconnectAuthorityIsCurrent(
            authority, generation: adoptedGeneration) else { return false }
        exactStoredSessionSourceDidReconnect()
        ConnectionSupervisor.shared.resetEpisode(for: .cleanOpen)
        ConnectionSupervisor.shared.noteReconnect("adopted")
        // Roster / routines / hide / rooms must not hold the live link.
        Task { @MainActor [weak self] in
            await self?.resyncSurfacesAfterReconnect(
                authority: authority, generation: adoptedGeneration)
        }
        return true
    }

    private func resyncSurfacesAfterReconnect(
        authority: SupervisedReconnectAuthority, generation: Int
    ) async {
        guard await adoptedReconnectAuthorityIsCurrent(
            authority, generation: generation) else { return }
        try? await refreshRoster()
        guard await adoptedReconnectAuthorityIsCurrent(
            authority, generation: generation) else { return }
        await refreshRoutinesLive(force: true)
        guard await adoptedReconnectAuthorityIsCurrent(
            authority, generation: generation) else { return }
        await hideOwnedBotSessions()
        guard await adoptedReconnectAuthorityIsCurrent(
            authority, generation: generation) else { return }
        connections = ConnectionRegistry.shared.rows
        if let gatewayID = LiveRuntime.shared.gatewayID {
            await pullAndReseedRoomProjection(gatewayID: gatewayID)
        }
    }

    /// Supervised reconnect finishes after the foreground/network callbacks
    /// that initiated it. Signal the retained exact-route queue only once the
    /// replacement link, roster, and parked sessions have been adopted.
    func exactStoredSessionSourceDidReconnect() {
        retryExactStoredSessionNavigation()
    }

    /// The client's event pump finishes exactly when the socket dies; awaiting
    /// it is the disconnect signal (ws-protocol §3 — liveness is socket-level).
    /// The pump must be the only `events` consumer — if `connect()` already
    /// iterated that stream for `gateway.ready`, this wait returns immediately
    /// and the banner looks like a failed reconnect.
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
            // Resign already owns the next redial. Starting one here is
            // how a hung `isReconnecting` dial survived into the next wake.
            guard !ConnectionSupervisor.shared.suspendedForBackground else { return }
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
        guard !supervisor.suspendedForBackground,
              runtime.reconnectTask == nil, !supervisor.isReconnecting,
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
                let outcome = await self.attemptReconnectOutcome(
                    expected: currentSource,
                    generation: supervisor.reconnectGeneration)
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
        // Escalation is a real problem — stop suppressing unreachable chrome.
        supervisor.endOfflineChromeGrace()
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
        ConnectionSupervisor.shared.reconnectGeneration &+= 1
        ConnectionSupervisor.shared.isReconnecting = false

        if runtime.baseURL?.absoluteString == baseURL.absoluteString, client != nil {
            let outcome = await attemptReconnectOutcome(
                generation: ConnectionSupervisor.shared.reconnectGeneration)
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
            } else if model.mode == .live, model.showsOfflineUnreachableChrome {
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
    private var reconnectButtonLabel: String {
        let trying = model.isReconnecting || model.isSupervisedReconnectLooping
        guard trying else { return copy.reconnectCTA(theme.id) }
        let n = max(model.reconnectTryNumber, 1)
        return "\(copy.reconnecting(theme.id)) · try \(n)"
    }

    private var offlineContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                headline(copy.linkDownTitle(theme.id), tone: theme.warn)
                Spacer(minLength: 8)
                LinkBannerButton(theme: theme,
                                 label: reconnectButtonLabel,
                                 role: .primary) {
                    model.reconnectNow()
                }
                .disabled(model.isReconnecting)
                .opacity(model.isReconnecting ? 0.6 : 1)
            }
            if !model.lastReconnectStep.isEmpty {
                Text(model.lastReconnectStep)
                    .font(bodyFont)
                    .foregroundStyle(theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(model.lastReconnectStep))
            }
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
