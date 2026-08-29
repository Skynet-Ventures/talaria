import Foundation
import Observation
import TalariaKit

// The persistent registry behind Connections → Gateways. Metadata (name, kind,
// normalized base URL, last roster size) lives in UserDefaults; credentials
// live only in the Keychain, keyed by the normalized base URL — the iOS
// analogue of desktop's safeStorage-encrypted connection store.
//
// Health probes hit the public `GET /api/status` endpoint (no auth required)
// via GatewayAuthClient.status(), measuring round-trip time for the ping
// column. Bot counts come from profiles.list once a live link is up and are
// cached so rows stay populated while a gateway is unreachable.
//
// Secondary rosters (Phase 4). Desktop paints ONE roster spanning every
// configured Connection: the Electron main process inventories each source and
// `buildAgentRoster` flattens them, applying the duplicate `@name-device` rule
// once across all of them (electron/connection-registry.ts:330-372). Talaria
// binds one gateway at a time, so the union is assembled here instead: each
// saved gateway is reached through `clientPool`; its `profiles.list` answer is
// cached and the authenticated connection remains available for source-routed
// bot and room operations. The AppModel primary connection still owns global
// navigation until those surfaces finish moving to source-qualified state.

/// One saved gateway — metadata only, never credentials.
public struct SavedGateway: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var kind: ConnectionKind
    /// Normalized base URL string (output of GatewayURL.normalize).
    public var urlString: String
    /// Last known roster size, refreshed from profiles.list once connected.
    public var lastBotCount: Int

    public var baseURL: URL? { URL(string: urlString) }

    public init(id: String = UUID().uuidString, name: String, kind: ConnectionKind,
                urlString: String, lastBotCount: Int = 0) {
        self.id = id; self.name = name; self.kind = kind
        self.urlString = urlString; self.lastBotCount = lastBotCount
    }
}

/// One profile enumerated from a gateway that is not the live one. Carries the
/// cosmetics that ride `ui_meta` (methods_profiles.py:212-226) so a foreign row
/// wears the same face it will wear after the switch. Canonical ids remain
/// source-qualified and runtime-only (stripped before persistence); unread and
/// live session bindings stay in their existing per-gateway stores.
public struct SecondaryProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    /// `ui_meta["hermes-bots"].title` — the desktop-set display title.
    public var title: String?
    /// Raw core `display_name`, intentionally separate from Bot Mode's title.
    /// It is carried through to `Bot.rawDisplayName` for friendly mention and
    /// room-member capture, rather than being reconstructed from a themed row.
    public var rawDisplayName: String?
    /// The profile's one-line description (its "job" on the roster row).
    public var job: String
    public var shape: AvatarShape?
    public var hue: AvatarHue?
    /// Preview of the resolved canonical session when available,
    /// otherwise raw last_session. This matches the identity a row opens.
    public var preview: String
    /// Preview from the session that supplied `lastActive`. Optional for
    /// persisted secondary rosters written by older Talaria builds.
    public var activityPreview: String?
    /// Freshest conversation activity, unix seconds.
    public var lastActive: Double?
    public var canonicalSessionID: String?
    public var canonicalResolvedID: String?

    public var canonicalChatID: String? {
        canonicalSessionID
    }

    public init(name: String, title: String? = nil, rawDisplayName: String? = nil, job: String = "",
                shape: AvatarShape? = nil, hue: AvatarHue? = nil,
                preview: String = "", activityPreview: String? = nil,
                lastActive: Double? = nil,
                canonicalSessionID: String? = nil, canonicalResolvedID: String? = nil) {
        self.name = name; self.title = title; self.job = job
        self.rawDisplayName = rawDisplayName
        self.shape = shape; self.hue = hue
        self.preview = preview; self.activityPreview = activityPreview
        self.lastActive = lastActive
        self.canonicalSessionID = canonicalSessionID
        self.canonicalResolvedID = canonicalResolvedID
    }
}

/// A saved gateway's last-known roster, and how much to trust it.
public struct SecondaryRoster: Codable, Sendable, Equatable {
    public enum Freshness: String, Codable, Sendable {
        /// Enumerated from this gateway during this launch.
        case fresh
        /// Last-known list; the gateway did not answer the most recent attempt,
        /// or answered without a self-consistent canonical-session projection.
        case stale
        /// Saved metadata with no Keychain credential — signed out here, or
        /// restored onto a new device. Nothing to list until sign-in.
        case needsSignIn
        /// The gateway answered, but has no profiles surface (-32601).
        case unsupported
    }

    public var profiles: [SecondaryProfile]
    /// When `profiles` was last successfully fetched.
    public var fetchedAt: Date
    public var freshness: Freshness

    public init(profiles: [SecondaryProfile], fetchedAt: Date, freshness: Freshness) {
        self.profiles = profiles; self.fetchedAt = fetchedAt; self.freshness = freshness
    }
}

/// Pure result of turning one authenticated profiles.list answer into rows the
/// union roster can safely publish. A response can still contribute cosmetics
/// and independent activity while its canonical preview is quarantined.
struct SecondaryRosterProjection: Sendable, Equatable {
    var profiles: [SecondaryProfile]
    var isCanonicalProjectionComplete: Bool

    var freshness: SecondaryRoster.Freshness {
        isCanonicalProjectionComplete ? .fresh : .stale
    }
}

/// One row of the union roster that lives on a gateway other than the live one.
///
/// `id` is desktop's source-qualified `botRosterKey` — `connectionId::name`
/// (plugin.js:2669) — because names alone are not unique across sources: two
/// connections can both expose `default`, and a bare-name key makes a list
/// repeat whole blocks of rows on every repaint.
public struct ForeignRosterEntry: Sendable, Equatable, Identifiable {
    public var id: String { GatewayBotRoute(gatewayID: gatewayID, profile: profile).qualifiedID }
    public var gatewayID: String
    public var connectionLabel: String
    public var connectionKind: ConnectionKind
    public var profile: String
    /// Bare profile name, or `<profile>-<label-slug>` when the name exists on
    /// more than one source (`agentHandle`, connection-registry.ts:137).
    public var handle: String
    public var title: String?
    /// Raw core `display_name` carried from the foreign gateway. It remains
    /// distinct from the desktop cosmetics title for the same reason it is on
    /// `SecondaryProfile`.
    public var rawDisplayName: String?
    public var job: String
    public var shape: AvatarShape?
    public var hue: AvatarHue?
    public var preview: String
    public var activityPreview: String?
    public var lastActive: Double?
    public var canonicalSessionID: String?
    public var canonicalResolvedID: String?
    public var canonicalChatID: String? {
        canonicalSessionID
    }
    /// When this row's gateway was last successfully listed — the age of the
    /// picture, as distinct from when the bot itself last spoke.
    public var fetchedAt: Date
    /// Last-known rather than just-fetched — the gateway is unreachable.
    public var isStale: Bool
    /// No credential in the Keychain for this gateway.
    public var needsSignIn: Bool

    public init(gatewayID: String, connectionLabel: String, connectionKind: ConnectionKind,
                profile: String, handle: String, title: String? = nil,
                rawDisplayName: String? = nil, job: String = "",
                shape: AvatarShape? = nil, hue: AvatarHue? = nil, preview: String = "",
                activityPreview: String? = nil, lastActive: Double? = nil,
                canonicalSessionID: String? = nil,
                canonicalResolvedID: String? = nil, fetchedAt: Date = Date(),
                isStale: Bool = false, needsSignIn: Bool = false) {
        self.gatewayID = gatewayID; self.connectionLabel = connectionLabel
        self.connectionKind = connectionKind; self.profile = profile; self.handle = handle
        self.title = title; self.rawDisplayName = rawDisplayName
        self.job = job; self.shape = shape; self.hue = hue
        self.preview = preview; self.activityPreview = activityPreview
        self.lastActive = lastActive; self.fetchedAt = fetchedAt
        self.canonicalSessionID = canonicalSessionID
        self.canonicalResolvedID = canonicalResolvedID
        self.isStale = isStale; self.needsSignIn = needsSignIn
    }
}

/// A saved gateway that contributed no rows, and why. Identifiable so the
/// roster can list them beside the rows without inventing a key.
public struct SecondaryRosterProblem: Sendable, Equatable, Identifiable {
    public var id: String { gateway.id }
    public var gateway: SavedGateway
    public var freshness: SecondaryRoster.Freshness

    public init(gateway: SavedGateway, freshness: SecondaryRoster.Freshness) {
        self.gateway = gateway; self.freshness = freshness
    }
}

private actor SecondaryConnectionCapture {
    private(set) var snapshot: GatewayClientPool.ConnectionSnapshot?

    func record(_ snapshot: GatewayClientPool.ConnectionSnapshot) {
        self.snapshot = snapshot
    }
}

private struct SecondaryRosterFetch: Sendable {
    var profiles: [HermesProfile]
    var connection: GatewayClientPool.ConnectionSnapshot
}

@MainActor
@Observable
public final class ConnectionRegistry {
    public static let shared = ConnectionRegistry()
    public static let defaultsKey = "talaria-gateways"
    /// Persisted secondary rosters: identity, cosmetics, and numeric recency
    /// only — never credentials, canonical ids, or transcript text.
    public static let rostersKey = "talaria-gateway-rosters"

    /// Latest health-probe result for one saved gateway.
    public struct Health: Sendable, Equatable {
        public var state: ConnectionState
        /// Measured round trip of GET /api/status, when reachable.
        public var pingMS: Int?
        public var version: String?
        public var authRequired: Bool

        public init(state: ConnectionState, pingMS: Int? = nil,
                    version: String? = nil, authRequired: Bool = false) {
            self.state = state; self.pingMS = pingMS
            self.version = version; self.authRequired = authRequired
        }
    }

    public private(set) var saved: [SavedGateway] = []
    public private(set) var health: [String: Health] = [:]
    /// Last-known roster of each saved gateway that is not the live one, keyed
    /// by gateway id. Persisted, so a secondary that is asleep still lists its
    /// bots — marked stale rather than vanishing.
    public private(set) var secondaryRosters: [String: SecondaryRoster] = [:]

    /// The gateway this app is bound to (or was last bound to). Set from the
    /// live link's own reports — `noteState(.connected)` and `noteBotCount`
    /// are only ever called for the connected gateway — and used to keep the
    /// secondary enumerator from opening a second socket to it.
    public private(set) var liveGatewayURL: URL?

    private let keychain: KeychainStore
    private let defaults: UserDefaults
    @ObservationIgnored public let clientPool: GatewayClientPool
    /// Short-timeout session so a sleeping LAN box fails fast, not in 60 s.
    private let probeSession: URLSession
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    /// One enumeration pass at a time; a foreground burst must not stack dials.
    @ObservationIgnored private var enumerationTask: Task<Void, Never>?
    /// AppModel owns source-qualified UI teardown. Keep only a weak capture in
    /// the installed closure so the registry singleton cannot retain the app
    /// model, and invoke it before releasing a failed secondary client.
    @ObservationIgnored private var secondaryTeardown:
        (@MainActor (String, GatewayClientPool.ConnectionSnapshot) async -> Void)?
    /// Owner callback after one or more secondary sources publish a fresh,
    /// authenticated roster. One enumeration pass produces at most one signal.
    @ObservationIgnored private var secondaryRefresh:
        (@MainActor (Set<String>) -> Void)?
    /// gateway id → when we last *attempted* a dial, so a gateway that refuses
    /// to answer is not re-dialled on every probe tick.
    @ObservationIgnored private var lastEnumerationAttempt: [String: Date] = [:]
    /// Exact URL-keyed credentials installed only by focused tests. The shared
    /// registry otherwise has no injectable credential store, while XCTest's
    /// sandbox cannot reliably write the real Keychain. Keeping the override
    /// at this authority boundary exercises the same `credential(for:)` reads
    /// as production without weakening or bypassing their later fences.
    @ObservationIgnored private var credentialOverridesForTesting:
        [String: GatewayCredential] = [:]

    public init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore(),
                clientPool: GatewayClientPool = GatewayClientPool()) {
        self.defaults = defaults
        self.keychain = keychain
        self.clientPool = clientPool
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        self.probeSession = URLSession(configuration: config)
        if let data = defaults.data(forKey: Self.defaultsKey),
           let list = try? JSONDecoder().decode([SavedGateway].self, from: data) {
            saved = list
        }
        if let data = defaults.data(forKey: Self.rostersKey),
           let cached = try? JSONDecoder().decode([String: SecondaryRoster].self, from: data) {
            // Everything restored from disk describes a gateway we have not
            // talked to yet this launch.
            secondaryRosters = cached.mapValues { roster in
                var row = roster
                if row.freshness == .fresh { row.freshness = .stale }
                return row
            }
        }
    }

    // MARK: - CRUD (metadata → UserDefaults, credential → Keychain)

    /// Add or update a gateway. The URL is normalized like desktop's
    /// connection-config; an existing row with the same normalized URL is
    /// updated in place so re-adding never duplicates.
    @discardableResult
    public func upsert(urlString: String, name: String? = nil, kind: ConnectionKind? = nil,
                       credential: GatewayCredential? = nil) -> SavedGateway? {
        guard let base = GatewayURL.normalize(urlString) else { return nil }
        if let credential { try? keychain.save(credential, for: base) }
        let normalized = base.absoluteString
        if let idx = saved.firstIndex(where: { $0.urlString == normalized }) {
            if let name, !name.isEmpty { saved[idx].name = name }
            if let kind { saved[idx].kind = kind }
            persist()
            return saved[idx]
        }
        let row = SavedGateway(name: (name?.isEmpty == false ? name! : nil) ?? base.host() ?? normalized,
                               kind: kind ?? Self.inferKind(host: base.host() ?? ""),
                               urlString: normalized)
        saved.append(row)
        persist()
        return row
    }

    public func remove(id: String) {
        guard let idx = saved.firstIndex(where: { $0.id == id }) else { return }
        if let base = saved[idx].baseURL {
            keychain.delete(for: base)
            credentialOverridesForTesting.removeValue(forKey: base.absoluteString)
        }
        health.removeValue(forKey: id)
        secondaryRosters.removeValue(forKey: id)
        lastEnumerationAttempt.removeValue(forKey: id)
        saved.remove(at: idx)
        persist()
        persistRosters()
    }

    public func rename(id: String, to name: String) {
        guard let idx = saved.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        saved[idx].name = name
        persist()
    }

    public func gateway(forURL url: URL) -> SavedGateway? {
        saved.first { $0.urlString == url.absoluteString }
    }

    public func credential(for gateway: SavedGateway) -> GatewayCredential? {
        guard let base = gateway.baseURL else { return nil }
        return credentialOverridesForTesting[base.absoluteString]
            ?? keychain.load(for: base)
    }

    public func setCredential(_ credential: GatewayCredential, for gateway: SavedGateway) {
        guard let base = gateway.baseURL else { return }
        try? keychain.save(credential, for: base)
    }

    /// Deterministic credential-store seam for focused tests. Overrides never
    /// persist and are removed with their gateway; nil restores real Keychain
    /// lookup for this exact normalized URL.
    internal func setCredentialForTesting(_ credential: GatewayCredential?,
                                          for gateway: SavedGateway) {
        guard let base = gateway.baseURL else { return }
        credentialOverridesForTesting[base.absoluteString] = credential
    }

    // MARK: - Live-link feedback

    /// Roster size from profiles.list once a live connection is up.
    public func noteBotCount(_ count: Int, forURL url: URL) {
        // Only the live link reports its own roster size, so this doubles as
        // the "this is the gateway we are bound to" beacon the secondary
        // enumerator needs in order to skip it.
        liveGatewayURL = url
        guard let idx = saved.firstIndex(where: { $0.urlString == url.absoluteString }),
              saved[idx].lastBotCount != count else { return }
        saved[idx].lastBotCount = count
        persist()
    }

    /// Direct state report from the live WS link (connect / drop) so the row
    /// flips without waiting for the next HTTP probe.
    public func noteState(_ state: ConnectionState, pingMS: Int? = nil, forURL url: URL) {
        // Same beacon as noteBotCount: the live link is the only caller that
        // reports .connected here (the HTTP probe writes `health` directly).
        // Deliberately not cleared on .offline — a dropped socket is still the
        // gateway this app is bound to, and dialling it as a "secondary" while
        // reconnect is racing would open a second socket to the same host.
        if state == .connected { liveGatewayURL = url }
        guard let row = gateway(forURL: url) else { return }
        var h = health[row.id] ?? Health(state: state)
        h.state = state
        if let pingMS { h.pingMS = pingMS }
        if state == .offline || state == .asleep { h.pingMS = nil }
        health[row.id] = h
    }

    /// Record a status-probe answer without changing the live-source beacon.
    /// Only the primary WebSocket calls `noteState(.connected)` or
    /// `noteBotCount`; a healthy secondary must remain diagnostic state only.
    ///
    /// HTTP `GET /api/status` must not overwrite the live socket's state:
    /// a reachable host after lock can look connected while the WebSocket is
    /// half-open, and a brief status blip must not mark a live socket offline.
    internal func noteProbeHealth(_ value: Health, forURL url: URL) {
        guard let row = gateway(forURL: url) else { return }
        if liveGatewayURL?.absoluteString == url.absoluteString,
           let current = health[row.id] {
            let liveOwnsState = current.state == .connected
                || current.state == .offline
                || current.state == .asleep
            if liveOwnsState, value.state != current.state {
                var merged = current
                if let pingMS = value.pingMS { merged.pingMS = pingMS }
                if let version = value.version { merged.version = version }
                merged.authRequired = value.authRequired
                health[row.id] = merged
                return
            }
        }
        health[row.id] = value
    }

    // MARK: - Health probes

    /// Keep the rows fresh while the Connections screen (or the app) is in
    /// the foreground: probe now, then on an interval. Idempotent.
    public func startAutoProbe(every seconds: TimeInterval = 20) {
        stopAutoProbe()
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probeAll()
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    public func stopAutoProbe() {
        probeTask?.cancel()
        probeTask = nil
    }

    /// Install the owner-side teardown for retained secondary connections.
    /// This is deliberately a callback rather than a registry → AppModel
    /// reference: ConnectionRegistry is also used by routing and health
    /// surfaces, and a strong reference here would make the app model and its
    /// singleton lifetime-coupled.
    internal func setSecondaryTeardown(_ handler:
                                       (@MainActor (String, GatewayClientPool.ConnectionSnapshot) async -> Void)?) {
        secondaryTeardown = handler
    }

    internal func setSecondaryRefresh(_ handler: (@MainActor (Set<String>) -> Void)?) {
        secondaryRefresh = handler
    }

    /// Focused roster-projection test seam. Runtime enumeration remains the
    /// sole production writer; tests use this to seed the same cache consumed
    /// by `foreignRosterEntries`/`unionRosterBots` without opening a socket.
    internal func setSecondaryRosterForTesting(_ roster: SecondaryRoster?,
                                               gatewayID: String) {
        secondaryRosters[gatewayID] = roster
    }

    /// Probe every saved gateway in parallel.
    public func probeAll() async {
        let rows = saved
        await withTaskGroup(of: Void.self) { group in
            for row in rows {
                group.addTask { [weak self] in await self?.probe(row) }
            }
        }
        // Now that health is fresh, top up the secondary rosters — detached,
        // because callers await probeAll() to paint the Connections list and a
        // WebSocket dial is an order of magnitude slower than a status GET.
        kickSecondaryEnumeration()
    }

    /// One async health probe: GET /api/status with a measured round trip.
    /// Timeout reads as `asleep` (host not answering — likely a sleeping
    /// machine); any other failure reads as `offline`.
    public func probe(_ gateway: SavedGateway) async {
        guard let base = gateway.baseURL else {
            health[gateway.id] = Health(state: .offline)
            return
        }
        noteProbeHealth(Health(state: .connecting,
                               pingMS: health[gateway.id]?.pingMS,
                               version: health[gateway.id]?.version,
                               authRequired: health[gateway.id]?.authRequired ?? false),
                        forURL: base)
        let auth = GatewayAuthClient(baseURL: base, session: probeSession)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let status = try await auth.status()
            let elapsed = start.duration(to: clock.now)
            let ms = max(1, Int((elapsed / .milliseconds(1)).rounded()))
            noteProbeHealth(Health(state: .connected, pingMS: ms,
                                   version: status.version,
                                   authRequired: status.authRequired),
                            forURL: base)
        } catch {
            let timedOut = (error as? URLError)?.code == .timedOut
            noteProbeHealth(Health(state: timedOut ? .asleep : .offline), forURL: base)
        }
    }

    // MARK: - Secondary rosters (the union roster's other sources)

    /// Enumerate saved gateways in the background. Fire-and-forget and
    /// self-coalescing: a foreground burst, a Connections repaint and the
    /// roster's own refresh all land on the one in-flight pass.
    public func kickSecondaryEnumeration(activeURL: URL? = nil) {
        guard enumerationTask == nil else { return }
        let active = activeURL ?? liveGatewayURL
        let excluded = Set([active?.absoluteString].compactMap { $0 })
        enumerationTask = Task { [weak self] in
            // A short debounce, not a delay for its own sake: at cold launch
            // this fires from the scene becoming active, in a race with the
            // launch reconnect. Letting that reconnect land first is what keeps
            // us from opening a probe socket to the very gateway about to
            // become live. `enumerate` re-checks the same thing at dial time,
            // for the case where the reconnect is slower than this.
            try? await Task.sleep(for: .seconds(2))
            await self?.enumerateSecondaryRosters(excluding: excluded)
            self?.enumerationTask = nil
        }
    }

    /// Ask every saved gateway for its roster, except the URLs in `excluding` —
    /// which is how the caller says "this one already has a live socket".
    /// An empty set means nothing is live and every saved gateway is fair game.
    ///
    /// Each answer costs one short-lived WebSocket: dial, `profiles.list`,
    /// hang up. `minInterval` keeps a gateway from being re-dialled on every
    /// probe tick — desktop's own inventory is equally conservative about
    /// re-enumerating a source that is not the active one
    /// (`shouldRetrySshInventory`, connection-registry.ts:288-302).
    @discardableResult
    public func enumerateSecondaryRosters(excluding: Set<String>,
                                          minInterval: TimeInterval = 90) async -> Set<String> {
        let now = Date()
        let targets = saved.filter { gateway in
            guard !excluding.contains(gateway.urlString) else { return false }
            guard let attempted = lastEnumerationAttempt[gateway.id] else { return true }
            return now.timeIntervalSince(attempted) >= minInterval
        }
        guard !targets.isEmpty else { return [] }
        // Cache whatever we learned even if the pass is cut short — a
        // half-finished sweep still leaves the roster better than it found it.
        defer { persistRosters() }
        var succeeded: Set<String> = []
        for gateway in targets {
            if Task.isCancelled { break }
            if await enumerate(gateway) { succeeded.insert(gateway.id) }
        }
        if !succeeded.isEmpty { secondaryRefresh?(succeeded) }
        return succeeded
    }

    /// Refresh one retained source in response to that gateway's own change
    /// event. This bypasses the periodic sweep interval because the source has
    /// just told us its roster/session projection changed.
    public func refreshSecondaryRoster(gatewayID: String) async {
        guard let gateway = saved.first(where: { $0.id == gatewayID }) else { return }
        if gateway.urlString == liveGatewayURL?.absoluteString { return }
        lastEnumerationAttempt[gatewayID] = Date()
        let succeeded = await enumerate(gateway)
        persistRosters()
        if succeeded { secondaryRefresh?([gatewayID]) }
    }

    /// One gateway's roster. Every failure keeps whatever was listed before —
    /// an unreachable homelab should read "last seen 3h ago", not go blank.
    private func enumerate(_ gateway: SavedGateway) async -> Bool {
        guard let base = gateway.baseURL else { return false }
        // Re-checked here, not only when the sweep was planned: a connect that
        // lands mid-sweep makes this gateway the live one, and a second socket
        // to a host we already hold open is never worth a roster refresh the
        // live link is about to deliver anyway. Not recorded as an attempt —
        // this gateway was skipped, not tried.
        guard base.absoluteString != liveGatewayURL?.absoluteString else { return false }
        lastEnumerationAttempt[gateway.id] = Date()
        guard let credential = credential(for: gateway) else {
            mark(gateway.id, .needsSignIn)
            return false
        }
        // A gateway the status probe just found asleep or offline will not
        // answer a WebSocket either; skip the dial and keep the cache.
        if let state = health[gateway.id]?.state, state == .offline || state == .asleep {
            mark(gateway.id, .stale)
            return false
        }

        let capture = SecondaryConnectionCapture()
        do {
            let fetched = try await Self.withTimeout(seconds: 12) {
                let connection = try await self.clientPool.connectWithGeneration(
                    gatewayID: gateway.id, baseURL: base, credential: credential)
                // include_sessions gives the preview + last_active in the same
                // round trip (methods_profiles.py:22-31); a foreign row is only
                // worth painting if it can say when that machine last spoke.
                await capture.record(connection)
                let profiles = try await connection.client.listProfiles(includeSessions: true)
                return SecondaryRosterFetch(profiles: profiles, connection: connection)
            }
            // A replacement/adoption may have won while profiles.list was
            // suspended. Its answer must not overwrite the replacement's
            // roster state.
            guard base.absoluteString != liveGatewayURL?.absoluteString,
                  let lease = await clientPool.acquireLease(
                      fetched.connection, for: gateway.id) else {
                return false
            }
            // The live source can switch while lease acquisition suspends on
            // the pool actor. Re-check the same source fence immediately
            // before publishing, so a newly-live gateway never receives a
            // roster fetched while it was secondary.
            guard base.absoluteString != liveGatewayURL?.absoluteString else {
                await clientPool.release(lease)
                return false
            }
            let projection = Self.secondaryRosterProjection(from: fetched.profiles)
            secondaryRosters[gateway.id] = SecondaryRoster(
                profiles: projection.profiles,
                fetchedAt: Date(),
                freshness: projection.freshness)
            noteBotCountForSecondary(projection.profiles.count, gatewayID: gateway.id)
            await clientPool.release(lease)
            return true
        } catch let error as GatewayError where error.code == GatewayClient.methodNotFound {
            guard let expected = await capture.snapshot,
                  await teardownSecondaryConnection(gatewayID: gateway.id, expected: expected) else {
                return false
            }
            // A gateway too old for profiles.list has no roster to contribute.
            // Hide the surface rather than showing an error nobody can act on.
            mark(gateway.id, .unsupported)
            return false
        } catch AuthError.sessionExpired {
            guard let expected = await capture.snapshot,
                  await teardownSecondaryConnection(gatewayID: gateway.id, expected: expected) else {
                return false
            }
            // The credential is gone/rejected; ConnectionSupervisor owns the
            // re-auth prompt for the LIVE gateway, and a secondary simply
            // reads as needing sign-in until the user switches to it.
            mark(gateway.id, .needsSignIn)
            return false
        } catch {
            guard let expected = await capture.snapshot,
                  await teardownSecondaryConnection(gatewayID: gateway.id, expected: expected) else {
                return false
            }
            mark(gateway.id, .stale)
            return false
        }
    }

    /// Drop source-qualified UI state while the failed client identity is
    /// still known, then release the pooled transport. The ordering matters:
    /// `dropWorkspaceScope` advances its generation and cancels in-flight
    /// loads, so a response already suspended on this client cannot publish
    /// after the pool slot disappears.
    internal func teardownSecondaryConnection(
        gatewayID: String, expected: GatewayClientPool.ConnectionSnapshot
    ) async -> Bool {
        // The saved row is metadata, not the identity of the transport that
        // failed. It can disappear while an enumeration error is unwinding
        // (the user removed the connection, or a settings refresh replaced
        // its metadata). The captured snapshot remains the authority for the
        // guarded disconnect; use its client URL for the active-source fence
        // so the row's absence cannot strand the old pooled client.
        let expectedURL = await expected.client.baseURL.absoluteString
        guard expectedURL != liveGatewayURL?.absoluteString,
              let lease = await clientPool.acquireLease(expected, for: gatewayID) else {
            return false
        }
        // Lease acquisition may have suspended while the user switched to
        // this gateway. Do not let a stale secondary failure tear down the
        // newly-active source.
        guard expectedURL != liveGatewayURL?.absoluteString else {
            await clientPool.release(lease)
            return false
        }
        if let secondaryTeardown {
            await secondaryTeardown(gatewayID, expected)
        }
        // AppModel teardown is async and can overlap a user-initiated source
        // switch. Revalidate before the guarded pool removal as well; the
        // lease protects replacement adoption, while this fence protects a
        // source that became active during the callback.
        guard expectedURL != liveGatewayURL?.absoluteString else {
            await clientPool.release(lease)
            return false
        }
        if await clientPool.disconnectIfCurrent(expected, for: gatewayID, lease: lease) {
            return true
        }
        await clientPool.release(lease)
        return false
    }

    /// Roster size for a gateway we are not connected to, so the Connections
    /// row stops reporting whatever it happened to hold the last time it was
    /// the live one.
    private func noteBotCountForSecondary(_ count: Int, gatewayID: String) {
        guard let idx = saved.firstIndex(where: { $0.id == gatewayID }),
              saved[idx].lastBotCount != count else { return }
        saved[idx].lastBotCount = count
        persist()
    }

    /// Record why a gateway could not be listed, without throwing away what it
    /// listed last time — desktop keeps previously painted remote rows for the
    /// same reason (plugin.js:2359-2394): a source going quiet must not empty
    /// the roster. Only `.unsupported` clears, because a gateway that has no
    /// profiles surface never had rows of its own to keep.
    private func mark(_ gatewayID: String, _ freshness: SecondaryRoster.Freshness) {
        var roster = secondaryRosters[gatewayID]
            ?? SecondaryRoster(profiles: [], fetchedAt: .distantPast, freshness: freshness)
        roster.freshness = freshness
        if freshness == .unsupported { roster.profiles = [] }
        secondaryRosters[gatewayID] = roster
    }

    nonisolated static func secondaryProfile(from profile: HermesProfile) -> SecondaryProfile {
        // The live roster's precedence, not a second copy of it: desktop Bot
        // Mode's own block wins over Talaria's mirror, so a bot titled or
        // recolored on desktop reads identically here (plugin.js
        // mergeServerMeta:432-482). Left optional deliberately — a secondary row
        // that stores no cosmetics falls back to the name hash at the point of
        // use, where the disambiguated profile name is known.
        let desk = BotModeMeta(uiMeta: profile.uiMeta)
        let shape = BotCosmetics.storedShape(for: profile)
        let hue = BotCosmetics.storedHue(for: profile)
        let canonical = profile.canonicalSession.session
        return SecondaryProfile(name: profile.name,
                                title: desk?.title,
                                rawDisplayName: profile.displayName,
                                job: profile.description ?? "",
                                shape: shape,
                                hue: hue,
                                // Canonical preview comes only from the
                                // authoritative registry projection; activity
                                // remains independently freshest below.
                                preview: profile.canonicalSession.isMalformed
                                    ? ""
                                    : canonical?.preview ?? profile.rawLastSession?.preview ?? "",
                                activityPreview:
                                    profile.freshestConversationSession?.preview ?? "",
                                lastActive: profile.freshestConversationSession?.lastActive,
                                canonicalSessionID: canonical?.id,
                                canonicalResolvedID: canonical?.resolvedID)
    }

    /// Convert a final profiles.list answer into publishable secondary rows.
    /// This seam is deliberately transport-free so omission of the current
    /// registry projection remains a stale, compatibility-only answer.
    nonisolated static func secondaryRosterProjection(
        from profiles: [HermesProfile]
    ) -> SecondaryRosterProjection {
        let candidates = profiles.filter { !$0.name.isEmpty }
        return SecondaryRosterProjection(
            profiles: candidates.map(Self.secondaryProfile(from:)),
            isCanonicalProjectionComplete:
                candidates.allSatisfy {
                    !$0.canonicalSession.isOmitted && !$0.canonicalSession.isMalformed
                })
    }

    /// Whether this gateway supplied the current canonical-session contract.
    nonisolated static func secondaryCanonicalProjectionIsExact(
        _ profile: HermesProfile
    ) -> Bool {
        !profile.canonicalSession.isOmitted && !profile.canonicalSession.isMalformed
    }

    /// Bound an await that has no deadline of its own. `GatewayClient.connect`
    /// already caps the socket handshake, but token refresh and the RPC round
    /// trip after it do not, and a secondary must never hold the enumerator.
    static func withTimeout<T: Sendable>(seconds: TimeInterval,
                                         _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw URLError(.timedOut) }
            return first
        }
    }

    // MARK: - The union roster

    /// Foreign rows for the one roster that spans every configured Connection.
    ///
    /// Port of `buildAgentRoster` (electron/connection-registry.ts:330-372):
    /// collapse to one identity per connection+profile, count bare names ONCE
    /// across every source — the live gateway included — and hand duplicates
    /// the `<profile>-<label-slug>` handle. The live gateway's own rows are not
    /// returned; they are already the roster.
    ///
    /// `activeGatewayID` nil means nothing is connected, so every saved gateway
    /// is a foreign source — the honest empty state still lists what it knows.
    public func foreignRoster(activeProfiles: [String],
                              activeGatewayID: String?) -> [ForeignRosterEntry] {
        let liveID = activeGatewayID
        let duplicated = duplicatedProfileNames(activeProfiles: activeProfiles,
                                                activeGatewayID: liveID)

        var entries: [ForeignRosterEntry] = []
        for gateway in saved where gateway.id != liveID {
            guard let roster = secondaryRosters[gateway.id] else { continue }
            let stale = roster.freshness == .stale
            let needsSignIn = roster.freshness == .needsSignIn
            var seen = Set<String>()
            for profile in roster.profiles {
                let name = AgentHandle.profileName(profile.name)
                guard seen.insert(name).inserted else { continue }
                entries.append(ForeignRosterEntry(
                    gatewayID: gateway.id,
                    connectionLabel: gateway.name,
                    connectionKind: gateway.kind,
                    profile: name,
                    handle: AgentHandle.mint(profile: name,
                                             connectionLabel: gateway.name,
                                             duplicated: duplicated.contains(name)),
                    title: profile.title,
                    rawDisplayName: profile.rawDisplayName,
                    job: profile.job,
                    shape: profile.shape,
                    hue: profile.hue,
                    preview: profile.preview,
                    activityPreview: profile.activityPreview,
                    lastActive: profile.lastActive,
                    canonicalSessionID: profile.canonicalSessionID,
                    canonicalResolvedID: profile.canonicalResolvedID,
                    fetchedAt: roster.fetchedAt,
                    isStale: stale,
                    needsSignIn: needsSignIn))
            }
        }
        // Newest-spoken first within a gateway, gateways in saved order — the
        // same "who moved most recently" ordering the live roster reads by.
        return entries.sorted { lhs, rhs in
            if lhs.gatewayID != rhs.gatewayID {
                return (saved.firstIndex { $0.id == lhs.gatewayID } ?? 0)
                    < (saved.firstIndex { $0.id == rhs.gatewayID } ?? 0)
            }
            return (lhs.lastActive ?? 0) > (rhs.lastActive ?? 0)
        }
    }

    /// Profile names that exist on more than one registered source — the input
    /// to the `@name-device` rule, computed ONCE across every source.
    ///
    /// The counting itself is `AgentHandle.duplicatedNames` (a port of
    /// connection-registry.ts:341-358, and the only place the per-source
    /// dedupe lives); the registry's job is to say what the sources ARE. The
    /// live gateway is one of them — upstream counts every identity including
    /// the active connection's, and stamps the suffix on every colliding one
    /// (:362-370) — which is why the phone's OWN `default` becomes
    /// `default-macbook` the moment a saved gateway also carries `default`,
    /// rather than only the far side being renamed.
    ///
    /// `activeGatewayID` nil means nothing is connected: every saved gateway
    /// is then a secondary source, and `activeProfiles` is whatever the roster
    /// last held.
    public func duplicatedProfileNames(activeProfiles: [String],
                                       activeGatewayID: String?) -> Set<String> {
        var sources: [[String]] = [activeProfiles]
        for gateway in saved where gateway.id != activeGatewayID {
            guard let roster = secondaryRosters[gateway.id] else { continue }
            sources.append(roster.profiles.map(\.name))
        }
        return AgentHandle.duplicatedNames(across: sources)
    }

    /// Saved gateways that could not be listed and why — for the roster
    /// section's footnote. Only gateways the user could act on are reported.
    public func secondaryRosterProblems(activeGatewayID: String?) -> [SecondaryRosterProblem] {
        saved.compactMap { gateway in
            guard gateway.id != activeGatewayID,
                  let roster = secondaryRosters[gateway.id],
                  roster.profiles.isEmpty,
                  roster.freshness == .needsSignIn || roster.freshness == .stale
            else { return nil }
            return SecondaryRosterProblem(gateway: gateway, freshness: roster.freshness)
        }
    }

    // `labelSlug`, `agentHandle` and the profile-name normalisation used to
    // live here. They moved to TalariaKit/AgentHandle.swift so `talaria-verify`
    // — which links TalariaKit alone — can pin them: the slug has to be
    // reproduced byte-for-byte on both machines or `@name-device` stops
    // round-tripping, and that is not a thing to hold by memory.

    // MARK: - Rows for the Connections screen

    /// Saved gateways as display rows (AppModel.connections shape).
    public var rows: [GatewayConnection] {
        saved.map { gw in
            let h = health[gw.id]
            return GatewayConnection(
                id: gw.id,
                name: gw.name,
                kind: gw.kind,
                address: Self.address(for: gw),
                state: h?.state ?? .offline,
                ping: h?.pingMS.map { "\($0)ms" } ?? "—",
                botCount: gw.lastBotCount)
        }
    }

    // MARK: - Helpers

    static func address(for gateway: SavedGateway) -> String {
        guard let url = gateway.baseURL, let host = url.host() else { return gateway.urlString }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    /// Best-guess kind from the host: Tailscale CGNAT / MagicDNS → tailscale,
    /// RFC1918 + .local + loopback → lan, everything else → cloud.
    static func inferKind(host: String) -> ConnectionKind {
        let h = host.lowercased()
        if h.hasSuffix(".ts.net") { return .tailscale }
        if h == "localhost" || h.hasSuffix(".local") { return .lan }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            if parts[0] == 100, (64...127).contains(parts[1]) { return .tailscale }
            if parts[0] == 10 { return .lan }
            if parts[0] == 127 { return .lan }
            if parts[0] == 192, parts[1] == 168 { return .lan }
            if parts[0] == 172, (16...31).contains(parts[1]) { return .lan }
            if parts[0] == 169, parts[1] == 254 { return .lan }
        }
        return .cloud
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Names, cosmetics, and numeric recency only — both preview channels are
    /// dropped on the way to disk, which makes the promise at `rostersKey` true.
    ///
    /// It is not a trade either: a roster restored from disk is forced `.stale`
    /// (see `init`), and a stale row shows the age of the picture rather than
    /// its preview. So a persisted preview is never painted — it would only
    /// leave another machine's conversation sitting in plaintext UserDefaults,
    /// which is backed up off the device, to buy nothing.
    nonisolated static func sanitizedSecondaryRostersForPersistence(
        _ rosters: [String: SecondaryRoster]
    ) -> [String: SecondaryRoster] {
        rosters.mapValues { roster -> SecondaryRoster in
            var row = roster
            row.profiles = row.profiles.map { profile in
                var stripped = profile
                stripped.preview = ""
                stripped.activityPreview = nil
                // Canonical ids are runtime routing state. Rehydrate them from
                // their authenticated owner instead of persisting another
                // gateway's conversation pointer in UserDefaults.
                stripped.canonicalSessionID = nil
                stripped.canonicalResolvedID = nil
                return stripped
            }
            return row
        }
    }

    private func persistRosters() {
        let sanitized = Self.sanitizedSecondaryRostersForPersistence(secondaryRosters)
        if let data = try? JSONEncoder().encode(sanitized) {
            defaults.set(data, forKey: Self.rostersKey)
        }
    }
}
