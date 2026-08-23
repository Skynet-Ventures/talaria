import Foundation

// High-level typed client for one gateway connection. Owns the transport,
// re-mints WS tickets on every (re)connect, refreshes OAuth tokens, and wraps
// the RPC surface Talaria uses. Method/param shapes follow
// .research/ws-protocol.md (verified against tui_gateway/*.py).

public struct HermesProfile: Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var path: String?
    public var isDefault: Bool
    public var model: String?
    public var provider: String?
    public var description: String?
    public var skillCount: Int
    /// Compatibility projection for older callers. New roster policy keeps
    /// preview identity (`previewSession`) separate from activity/unread
    /// identity (`freshestConversationSession`). `rawLastSession` keeps the
    /// untouched wire value for callers that need to distinguish the inputs.
    public var lastSession: ProfileSessionRef?
    /// `last_session` exactly as the gateway sent it, before any preview fold.
    public var rawLastSession: ProfileSessionRef?
    /// `preferred_session` — the gateway's precise answer about the ONE
    /// session this client asked about (its canonical-chat pin), as opposed to
    /// `last_session`'s "whatever is newest".
    public var preferredSession: PreferredSession
    /// The worker's live turn, deliberately separate from conversation
    /// activity. A fresh worker can animate an already-visible row, but it
    /// must never advance unread watermarks or reorder the roster.
    public var workerSession: WorkerSessionRef?
    /// The raw core profile `display_name`. It is identity input for friendly
    /// mentions, not the visual Bot Mode title and therefore must not be
    /// reconstructed from a rendered roster label.
    public var displayName: String?
    public var uiMeta: JSONValue?
    /// Gateway-owned compare-and-swap revisions for the top-level `ui_meta`
    /// keys. `nil` means the gateway omitted the field (legacy/no CAS);
    /// an empty map is positive evidence that CAS is supported and every
    /// untouched key is currently at revision zero.
    public var uiMetaRevisions: [String: Int]?
    public var hasAvatar: Bool

    /// A present revision field is authority, so malformed values cannot be
    /// collapsed into `nil` and mistaken for a legacy gateway. The roster
    /// decoder rejects the whole answer when this is false.
    var hasValidUIMetaRevisionsWire: Bool

    public struct ProfileSessionRef: Sendable {
        public var id: String
        /// `resolved_id` — the live compression tip for `id`, equal to `id`
        /// when the lineage was never compressed. Only `preferred_session`
        /// carries it (methods_profiles.py:104-112); `last_session` leaves it
        /// nil. `id` stays the caller's durable pin, which is why a compaction
        /// on the laptop does not orphan a phone's pin.
        public var resolvedID: String?
        /// The lineage root's title. A compressed tip can have its own title,
        /// so canonical-session checks use this when it is present rather than
        /// guessing from the leaf title.
        public var rootTitle: String?
        public var title: String?
        public var preview: String?
        public var startedAt: Double?
        public var lastActive: Double?
        public var messageCount: Int

        /// The exact Bot Mode plumbing identity. A compressed tip may have a
        /// renamed leaf, so an authoritative root title wins when present.
        public var isCanonicalBotChat: Bool {
            let trimmedRoot = rootTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            // Some gateway/store combinations serialize an absent root as an
            // empty string. Empty is not authoritative evidence: treat it as
            // absent so a legacy exact leaf title can still prove Bot Chat.
            let root = trimmedRoot?.isEmpty == false ? trimmedRoot : nil
            let trimmedLeaf = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let leaf = trimmedLeaf?.isEmpty == false ? trimmedLeaf : nil
            return root == "Bot Chat" || (root == nil && leaf == "Bot Chat")
        }

        /// A resolved pin with history is durable user intent even when its
        /// title drifted. Only an empty, non-Bot-Chat target is a stray draft.
        public var isViableCanonicalPin: Bool {
            isCanonicalBotChat || messageCount > 0
        }

        init?(_ v: JSONValue?) {
            guard let id = v?["id"]?.stringValue else { return nil }
            self.id = id
            resolvedID = v?["resolved_id"]?.stringValue
            rootTitle = v?["root_title"]?.stringValue
            title = v?["title"]?.stringValue
            preview = v?["preview"]?.stringValue
            startedAt = v?["started_at"]?.doubleValue
            lastActive = v?["last_active"]?.doubleValue
            messageCount = v?["message_count"]?.intValue ?? 0
        }
    }

    /// Minimal worker-session data from `profiles.list`. Unlike a conversation
    /// summary, a worker update is useful even when a gateway omits its id, so
    /// it intentionally does not reuse `ProfileSessionRef`'s id-required
    /// parser. The timestamp is policy data only: consumers use it for the
    /// 150-second live window and never for unread or ranking.
    public struct WorkerSessionRef: Sendable, Equatable {
        public static let liveWindow: TimeInterval = 150

        public var id: String?
        public var lastActive: Double?

        init?(_ v: JSONValue?) {
            guard let object = v?.objectValue else { return nil }
            id = object["id"]?.stringValue ?? object["session_id"]?.stringValue
            lastActive = object["last_active"]?.doubleValue
            // An arbitrary object is not evidence of a live worker. Preserve
            // a valid partial answer (timestamp without id) but reject a
            // shape with no usable worker identity or activity at all.
            guard id != nil || lastActive != nil else { return nil }
        }

        /// Whether the worker is still inside Hermes' live-turn window. A
        /// small future skew is tolerated, but an arbitrarily future timestamp
        /// is not allowed to hold a row live forever; malformed/missing stamps
        /// are never promoted into liveness.
        public func isLive(at now: Double, within window: TimeInterval = liveWindow) -> Bool {
            guard let lastActive, window >= 0 else { return false }
            return abs(now - lastActive) <= window
        }
    }

    /// The three answers `profiles.list` can give about a pin, and the reason
    /// the difference is load-bearing rather than pedantic
    /// (methods_profiles.py:63-130, plugin.js:2857-2880):
    ///
    /// - **absent** — this client sent no pin for the profile, *or* the
    ///   gateway predates `preferred_session_ids` and ignored the parameter.
    ///   Verified against a live 0.20.3 gateway on 2026-08-18: the row keys
    ///   come back `name, path, is_default, model, provider, description,
    ///   skill_count, last_session, ui_meta, has_avatar` — no
    ///   `preferred_session` at all. The pin is innocent.
    /// - **null** — a gateway that *does* speak the contract saying the row is
    ///   definitively gone (missing, archived, or a denied internal source).
    ///   Modelled, but deliberately not wired to canonical-chat recovery:
    ///   `attachCanonicalSession` re-anchors off `session.resume`'s 4007
    ///   instead, which is definitive for the exact operation the tap is about
    ///   to perform and costs no extra round trip. Kept distinct from *absent*
    ///   so the distinction survives in the model — collapsing the two is what
    ///   would let an old gateway's silence read as "the pin is dead".
    /// - **a summary** — the pin resolved, hidden sessions included and
    ///   compression lineages followed to their live tip.
    public enum PreferredSession: Sendable {
        case notRequested
        case gone
        case resolved(ProfileSessionRef)

        public var session: ProfileSessionRef? {
            if case .resolved(let session) = self { return session }
            return nil
        }

        /// The gateway omitted the key entirely. This is an inconclusive
        /// compatibility answer, never permission to clear or replace a
        /// durable pin. `notRequested` remains the source-compatible case
        /// spelling; this property names its wire meaning directly.
        public var isOmitted: Bool {
            if case .notRequested = self { return true }
            return false
        }

        /// True only when a gateway that speaks the contract said so. An older
        /// gateway can never produce this, which is what keeps a pin alive
        /// across a downgrade.
        public var isDefinitivelyGone: Bool {
            if case .gone = self { return true }
            return false
        }
    }

    init(_ v: JSONValue) {
        name = v["name"]?.stringValue ?? ""
        path = v["path"]?.stringValue
        isDefault = v["is_default"]?.boolValue ?? false
        model = v["model"]?.stringValue
        provider = v["provider"]?.stringValue
        description = v["description"]?.stringValue
        skillCount = v["skill_count"]?.intValue ?? 0
        lastSession = ProfileSessionRef(v["last_session"])
        rawLastSession = lastSession
        switch v["preferred_session"] {
        case .none: preferredSession = .notRequested
        case .some(.null): preferredSession = .gone
        case .some(let node): preferredSession = ProfileSessionRef(node).map(
            PreferredSession.resolved) ?? .notRequested
        }
        workerSession = WorkerSessionRef(v["worker_session"])
        displayName = v["display_name"]?.stringValue
        uiMeta = v["ui_meta"]
        let revisionField = Self.decodeUIMetaRevisions(v["ui_meta_revisions"])
        uiMetaRevisions = revisionField.revisions
        hasValidUIMetaRevisionsWire = revisionField.isValid
        hasAvatar = v["has_avatar"]?.boolValue ?? false
    }

    /// Hermes accepts only real, nonnegative integers here. `JSONValue` keeps
    /// numbers as `Double`, so `Int(exactly:)` is essential: `intValue` would
    /// silently turn 1.5 into 1 and could authorize a stale writer.
    private static func decodeUIMetaRevisions(_ value: JSONValue?)
        -> (revisions: [String: Int]?, isValid: Bool) {
        guard let value else { return (nil, true) }
        guard let object = value.objectValue else { return (nil, false) }
        var revisions: [String: Int] = [:]
        revisions.reserveCapacity(object.count)
        for (key, raw) in object {
            guard let number = raw.doubleValue,
                  number.isFinite,
                  let revision = Int(exactly: number),
                  revision >= 0 else {
                return (nil, false)
            }
            revisions[key] = revision
        }
        return (revisions, true)
    }

    /// The session whose text a roster row previews. The preferred session is
    /// the click identity and therefore wins even when an unrelated visible
    /// scratch conversation is newer. Older gateways simply omit it and fall
    /// back to `last_session`.
    public var previewSession: ProfileSessionRef? {
        preferredSession.session ?? rawLastSession ?? lastSession
    }

    /// The conversation activity source for unread, recency, liveness, and
    /// ordinary relative-age policy. Hermes may return a pinned/preferred
    /// session which is newer than `last_session`; activity chooses the fresher
    /// of both while preview remains anchored to the preferred click identity.
    ///
    /// This is pure. `rawLastSession` remains exactly what the wire carried,
    /// while `lastSession` is retained as a compatibility projection by
    /// `foldingCanonicalPreview()`.
    public var freshestConversationSession: ProfileSessionRef? {
        let last = rawLastSession ?? lastSession
        let preferred = preferredSession.session
        switch (preferred, last) {
        case (nil, nil): return nil
        case (let session?, nil): return session
        case (nil, let session?): return session
        case (let preferred?, let last?):
            switch (preferred.lastActive, last.lastActive) {
            case (let preferredStamp?, let lastStamp?):
                return preferredStamp >= lastStamp ? preferred : last
            case (.some, .none): return preferred
            case (.none, .some): return last
            case (.none, .none): return preferred
            }
        }
    }

    /// Compatibility projection for older preview call sites. It folds the
    /// whole preferred row rather than splicing only its text into another
    /// session's identity/stamp. Activity policy reads
    /// `freshestConversationSession` directly.
    func foldingCanonicalPreview() -> HermesProfile {
        var folded = self
        folded.lastSession = previewSession
        return folded
    }
}

public struct StoredSession: Sendable, Identifiable {
    public var id: String
    public var title: String
    public var preview: String?
    public var startedAt: Double?
    public var messageCount: Int
    public var source: String?

    init(_ v: JSONValue) {
        id = v["id"]?.stringValue ?? ""
        title = v["title"]?.stringValue ?? ""
        preview = v["preview"]?.stringValue
        startedAt = v["started_at"]?.doubleValue
        messageCount = v["message_count"]?.intValue ?? 0
        source = v["source"]?.stringValue
    }
}

public struct LiveSession: Sendable {
    /// Runtime sid (8 hex chars) — use for all RPCs and event routing.
    public var sessionID: String
    /// Durable key — use for session.resume across reconnects.
    public var storedSessionID: String
    public var messages: [JSONValue]
    public var info: SessionInfo
    public var running: Bool
    /// Partial in-flight turn replayed after a reconnect.
    public var inflight: JSONValue?
    /// Oldest unresolved approval, replayed on resume.
    public var pendingApproval: ApprovalRequest?
    /// Clarify question still blocking this session, replayed on resume
    /// (server.py `_pending_clarify_request_payload`). Unlike approvals there
    /// is no `clarify.pending` RPC, so this block is the only way to recover a
    /// question raised while the transport was detached.
    public var pendingClarify: JSONValue?

    init(_ v: JSONValue) {
        sessionID = v["session_id"]?.stringValue ?? ""
        storedSessionID = v["stored_session_id"]?.stringValue
            ?? v["session_key"]?.stringValue
            ?? v["resumed"]?.stringValue ?? ""
        messages = v["messages"]?.arrayValue ?? []
        info = SessionInfo(v["info"])
        running = v["running"]?.boolValue ?? false
        inflight = v["inflight"]
        pendingApproval = v["pending_approval"].map { ApprovalRequest($0, sessionID: v["session_id"]?.stringValue ?? "") }
        pendingClarify = v["pending_clarify"]
    }

    /// The exact durable/state evidence represented by this resume payload.
    /// Consumers must use this rather than treating the transport sequence as
    /// proof that every earlier event was included in the snapshot.
    public var snapshotEvidence: ResumeSnapshotEvidence {
        ResumeSnapshotEvidence(session: self)
    }
}

public struct CronJob: Sendable, Identifiable {
    public var id: String
    public var name: String
    public var schedule: String
    public var enabled: Bool
    public var nextRun: Double?
    public var lastRun: Double?
    public var raw: JSONValue

    init(_ v: JSONValue) {
        // `_format_job` (cronjob_tools.py:620) emits `job_id`, never `id`, and
        // every mutation addresses a job by it. Falling through to `name` — as
        // this did — meant enable/disable/delete targeted a title, so a
        // renamed or duplicate-titled job hit the wrong row or nothing at all.
        // Verified against a live gateway 2026-08-18: rows carry job_id.
        id = v["job_id"]?.stringValue ?? v["id"]?.stringValue ?? v["name"]?.stringValue ?? UUID().uuidString
        name = v["name"]?.stringValue ?? ""
        schedule = v["schedule"]?.stringValue ?? v["cron"]?.stringValue ?? ""
        enabled = v["enabled"]?.boolValue ?? true
        nextRun = v["next_run"]?.doubleValue
        lastRun = v["last_run"]?.doubleValue
        raw = v
    }
}

/// Incremental response storage shared by the bounded REST transport and its
/// focused tests. `URLSession.data(for:)` buffers an entire response before a
/// caller can inspect it; Hermes' managed-file endpoint permits 100 MB, so the
/// mobile client must reject both a declared oversize and a chunk that would
/// cross its own ceiling while bytes are still arriving.
struct GatewayBoundedResponseAccumulator: Sendable {
    let limit: Int
    private(set) var data = Data()

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func accepts(expectedContentLength: Int64) -> Bool {
        expectedContentLength < 0 || expectedContentLength <= Int64(limit)
    }

    mutating func append(_ chunk: Data) -> Bool {
        guard chunk.count <= limit - data.count else { return false }
        data.append(chunk)
        return true
    }
}

/// Package-test visibility for one bounded request's terminal ownership. The
/// production executor passes nil; focused cancellation tests use these
/// callbacks to prove a data task completes once and the session releases its
/// delegate after invalidation.
struct GatewayBoundedRESTLifetimeObserver: Sendable {
    var didCreate: @Sendable () -> Void
    var didComplete: @Sendable () -> Void
    var didRelease: @Sendable () -> Void
}

/// One-shot URLSession delegate that owns a bounded response transaction.
/// Cancellation propagates to the data task; a limit rejection is reported as
/// HTTP 413 so callers use the same mapping for Hermes' and Talaria's ceilings.
private final class GatewayBoundedRESTRequest: NSObject, URLSessionDataDelegate,
                                                @unchecked Sendable {
    private let lock = NSLock()
    private var accumulator: GatewayBoundedResponseAccumulator
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: URLResponse?
    private var callerCancelled = false
    private var exceeded = false
    private var completed = false
    private let configuration: URLSessionConfiguration
    private let lifetimeObserver: GatewayBoundedRESTLifetimeObserver?

    init(limit: Int, configuration: URLSessionConfiguration,
         lifetimeObserver: GatewayBoundedRESTLifetimeObserver?) {
        accumulator = GatewayBoundedResponseAccumulator(limit: limit)
        self.configuration = configuration
        self.lifetimeObserver = lifetimeObserver
        lifetimeObserver?.didCreate()
    }

    deinit { lifetimeObserver?.didRelease() }

    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if callerCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                configuration.timeoutIntervalForRequest = request.timeoutInterval
                configuration.timeoutIntervalForResource = request.timeoutInterval
                let session = URLSession(configuration: configuration, delegate: self,
                                         delegateQueue: nil)
                let task = session.dataTask(with: request)
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        lock.lock()
        callerCancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = continuation
        let session = session
        self.continuation = nil
        self.session = nil
        task = nil
        lock.unlock()

        lifetimeObserver?.didComplete()
        continuation?.resume(with: result)
        session?.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let accepted = accumulator.accepts(
            expectedContentLength: response.expectedContentLength)
        if accepted {
            self.response = response
        } else {
            exceeded = true
        }
        lock.unlock()
        completionHandler(accepted ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        lock.lock()
        let accepted = accumulator.append(data)
        if !accepted { exceeded = true }
        lock.unlock()
        if !accepted { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.lock()
        let result: Result<(Data, URLResponse), Error>
        if callerCancelled {
            result = .failure(CancellationError())
        } else if exceeded {
            result = .failure(GatewayError(
                code: 413,
                message: "Gateway response exceeds Talaria's bounded mobile limit."))
        } else if let error {
            result = .failure(error)
        } else if let response {
            result = .success((accumulator.data, response))
        } else {
            result = .failure(GatewayError(code: -11,
                                           message: "Gateway returned no REST response."))
        }
        lock.unlock()
        finish(result)
    }
}

enum GatewayBoundedRESTLoader {
    static func load(_ request: URLRequest, limit: Int,
                     configuration: URLSessionConfiguration = .ephemeral,
                     lifetimeObserver: GatewayBoundedRESTLifetimeObserver? = nil) async throws
        -> (Data, URLResponse) {
        try await GatewayBoundedRESTRequest(
            limit: limit, configuration: configuration,
            lifetimeObserver: lifetimeObserver).load(request)
    }
}

/// One gateway connection: transport lifecycle + typed RPCs.
public actor GatewayClient {
    public struct TrafficLease: Sendable {
        private let releaseOperation: @Sendable () async -> Void

        public init(release: @escaping @Sendable () async -> Void) {
            releaseOperation = release
        }

        public func release() async { await releaseOperation() }
    }

    public typealias TrafficAdmission = @Sendable () async -> TrafficLease?

    /// Local fail-closed rejection before any WebSocket or HTTP request can
    /// reach a gateway whose profile namespace is being mutated.
    public static let trafficFenced = -32_900
    /// A successful managed-files response that failed the captured
    /// root/canonical-path authority contract.
    public static let managedFileAuthorityUnproven = -32_901

    public let baseURL: URL
    private let auth: GatewayAuthClient
    private var credential: GatewayCredential
    private var transport: GatewayTransport?
    private let keychain: KeychainStore
    private var trafficAdmission: TrafficAdmission?
    typealias RESTExecutor = @Sendable (URLRequest, Int?) async throws -> (Data, URLResponse)
    private let restExecutor: RESTExecutor

    /// Re-published stream of all events from the current transport.
    public private(set) var eventsTask: Task<Void, Never>?
    private var eventHandlers: [UUID: @Sendable (GatewayEvent) -> Void] = [:]

    public init(baseURL: URL, credential: GatewayCredential,
                keychain: KeychainStore = KeychainStore()) {
        self.baseURL = baseURL
        self.auth = GatewayAuthClient(baseURL: baseURL)
        self.credential = credential
        self.keychain = keychain
        self.restExecutor = { request, limit in
            if let limit {
                return try await GatewayBoundedRESTLoader.load(request, limit: limit)
            }
            return try await URLSession.shared.data(for: request)
        }
    }

    /// Package-test initializer for production-path REST authority tests. The
    /// client still builds and authenticates the exact request and owns its
    /// lifecycle traffic lease; only the byte source is deterministic.
    init(baseURL: URL, credential: GatewayCredential,
         keychain: KeychainStore = KeychainStore(),
         restExecutor: @escaping RESTExecutor) {
        self.baseURL = baseURL
        self.auth = GatewayAuthClient(baseURL: baseURL)
        self.credential = credential
        self.keychain = keychain
        self.restExecutor = restExecutor
    }

    // MARK: - Event fan-out

    public func addEventHandler(_ handler: @escaping @Sendable (GatewayEvent) -> Void) -> UUID {
        let id = UUID()
        eventHandlers[id] = handler
        return id
    }

    public func removeEventHandler(_ id: UUID) {
        eventHandlers.removeValue(forKey: id)
    }

    /// Deterministic package-test seam for event/snapshot ordering. Production
    /// delivery still comes exclusively from the transport event task.
    func emitEventForTesting(_ event: GatewayEvent) {
        for handler in handlerSnapshot() { handler(event) }
    }

    /// Install the owning app's source-qualified lifecycle admission. The
    /// check lives on the client rather than only in route resolution so a
    /// mutation that begins after a caller obtains this actor still wins the
    /// final race immediately before transport use.
    public func setTrafficAdmission(_ admission: TrafficAdmission?) {
        trafficAdmission = admission
    }

    public func acquireTrafficLease() async throws -> TrafficLease? {
        if let trafficAdmission, let lease = await trafficAdmission() {
            return lease
        }
        if trafficAdmission != nil {
            throw GatewayError(
                code: Self.trafficFenced,
                message: "Gateway traffic is paused while a profile change is being resolved.")
        }
        return nil
    }

    // MARK: - Connection lifecycle

    public var isConnected: Bool {
        get async {
            guard let transport else { return false }
            return await transport.state == .ready
        }
    }

    /// Connect (or reconnect). Refreshes OAuth tokens when near expiry and
    /// mints a fresh single-use WS ticket per attempt.
    public func connect() async throws {
        if case .oauth(let tokens) = credential, tokens.needsRefresh {
            do {
                let refreshed = try await auth.refresh(tokens)
                credential = .oauth(refreshed)
                try? keychain.save(credential, for: baseURL)
            } catch AuthError.sessionExpired {
                keychain.delete(for: baseURL)
                throw AuthError.sessionExpired
            } catch AuthError.providerUnreachable {
                // Keep tokens; the access token may still be valid.
            }
        }

        let ticket: String?
        if case .oauth = credential {
            ticket = try await auth.mintWSTicket(credential: credential)
        } else {
            ticket = nil
        }

        let url = try auth.webSocketURL(credential: credential, ticket: ticket)
        let transport = GatewayTransport(url: url)
        self.transport = transport
        try await transport.connect()

        eventsTask?.cancel()
        eventsTask = Task {
            for await event in transport.events {
                for handler in self.handlerSnapshot() {
                    handler(event)
                }
            }
        }
    }

    private func handlerSnapshot() -> [@Sendable (GatewayEvent) -> Void] {
        Array(eventHandlers.values)
    }

    public func disconnect() async {
        await transport?.close()
        transport = nil
        eventsTask?.cancel()
    }

    @discardableResult
    public func rpc(_ method: String, _ params: JSONValue? = nil,
                    timeout: TimeInterval = 120) async throws -> JSONValue {
        let lease = try await acquireTrafficLease()
        do {
            guard let transport else { throw GatewayError(code: -3, message: "not connected") }
            let result = try await transport.request(method, params: params, timeout: timeout)
            await lease?.release()
            return result
        } catch {
            await lease?.release()
            throw error
        }
    }

    // MARK: - Status

    public func status() async throws -> GatewayStatus {
        try await auth.status()
    }

    // MARK: - Profiles (the bot roster)

    /// The roster, with each row's canonical-chat pin resolved precisely.
    ///
    /// `preferred_session_ids` — `{profile: stored_session_id}` — is the
    /// enabling call for the whole roster region: it lets the *gateway* answer
    /// "what about THIS conversation" per row (hidden sessions included,
    /// compression lineages followed) instead of the client inferring the
    /// canonical chat from `last_session` and previewing a conversation the
    /// tap will not open (hermes-agent#88200). Deliberately not `session.list`
    /// — a paginated, hidden-excluding window once misjudged live hidden pins
    /// as gone.
    ///
    /// Server side: `methods_profiles.py` `_preferred_session_row` +
    /// `profiles.list` (`preferred_ids = params.get("preferred_session_ids")`,
    /// resolved only when `include_sessions` is on). Client side this mirrors
    /// `preferredSessionIds(allMeta)` (plugin.js:2208-2231).
    ///
    /// Pins default to the ones harvested from the previous answer's own
    /// `ui_meta["hermes-bots"].chat` — the same store desktop reads them from
    /// — so every existing caller gets the round trip without threading pins
    /// through. A gateway that predates the parameter ignores it and simply
    /// omits `preferred_session`; verified live 2026-08-18 against 0.20.3,
    /// where the roster came back identical with and without the field.
    public func listProfiles(includeSessions: Bool = true,
                             preferredSessionIDs: [String: String]? = nil) async throws -> [HermesProfile] {
        var params: JSONValue = ["include_sessions": .bool(includeSessions)]
        let pins = preferredSessionIDs ?? preferredSessionPins
        // Sending an empty map would be a no-op the gateway still has to
        // parse; desktop omits the key entirely for the same reason.
        if includeSessions, !pins.isEmpty,
           case .object(var fields) = params {
            fields["preferred_session_ids"] = .object(pins.mapValues(JSONValue.string))
            params = .object(fields)
        }
        let result = try await rpc("profiles.list", params)
        guard let rawRows = result["profiles"]?.arrayValue else {
            throw GatewayError(code: -8, message: "profiles.list malformed response")
        }
        let rows = try Self.decodeProfileRows(rawRows)
        if !rows.isEmpty { rememberPins(from: rows) }
        return rows.map { $0.foldingCanonicalPreview() }
    }

    /// Strict profiles.list row decoding kept separate from transport so the
    /// compatibility/CAS boundary can be tested without a live gateway.
    static func decodeProfileRows(_ rawRows: [JSONValue]) throws -> [HermesProfile] {
        let rows = rawRows.map(HermesProfile.init)
        guard rows.allSatisfy({ !$0.name.isEmpty }) else {
            throw GatewayError(code: -8, message: "profiles.list contained malformed profile")
        }
        guard rows.allSatisfy(\.hasValidUIMetaRevisionsWire) else {
            throw GatewayError(code: -8,
                               message: "profiles.list contained malformed ui_meta_revisions")
        }
        return rows
    }

    /// Canonical-chat pins to resolve on the NEXT roster call. Self-priming
    /// from the block every answer already carries, which is where desktop's
    /// `$botMeta` gets them too.
    private var preferredSessionPins: [String: String] = [:]

    private func rememberPins(from rows: [HermesProfile]) {
        var harvested: [String: String] = [:]
        for row in rows {
            if let pin = row.uiMeta?["hermes-bots"]?["chat"]?.stringValue, !pin.isEmpty {
                harvested[row.name] = pin
            } else if row.uiMeta?["hermes-bots"]?.objectValue == nil,
                      let kept = preferredSessionPins[row.name] {
                // No server block at all — an older gateway, or one that
                // cannot persist ui_meta. Desktop's rule (plugin.js:441-470)
                // is that only an EXISTING block is authoritative, so a pin
                // this client learned locally survives; a block that exists
                // and omits `chat` really is a deletion and drops through.
                harvested[row.name] = kept
            }
        }
        preferredSessionPins = harvested
    }

    /// Tell the client about a pin before the gateway can: a canonical chat
    /// minted seconds ago is not in `ui_meta` until its write lands, and the
    /// poll in between would otherwise preview the wrong session once.
    public func notePreferredSessions(_ pins: [String: String]) {
        for (name, id) in pins where !id.isEmpty { preferredSessionPins[name] = id }
    }

    public func describeProfile(_ name: String) async throws -> JSONValue {
        try await rpc("profiles.describe", ["name": .string(name)])
    }

    /// Create a profile. `soul` becomes SOUL.md; `cloneFrom` = desktop
    /// Duplicate semantics.
    public func createProfile(name: String, description: String? = nil,
                              soul: String? = nil, cloneFrom: String? = nil,
                              model: String? = nil, provider: String? = nil) async throws {
        var params: [String: JSONValue] = ["name": .string(name)]
        if let description { params["description"] = .string(description) }
        if let soul { params["soul"] = .string(soul) }
        if let cloneFrom { params["clone_from"] = .string(cloneFrom); params["clone_all"] = .bool(true) }
        if let model { params["model"] = .string(model) }
        if let provider { params["provider"] = .string(provider) }
        try await rpc("profiles.create", .object(params))
    }

    public func configureProfile(name: String, description: String? = nil,
                                 soul: String? = nil, model: String? = nil,
                                 provider: String? = nil, disabledSkills: [String]? = nil,
                                 uiMeta: JSONValue? = nil) async throws {
        var params: [String: JSONValue] = ["name": .string(name)]
        if let description { params["description"] = .string(description) }
        if let soul { params["soul"] = .string(soul) }
        if let model { params["model"] = .string(model) }
        if let provider { params["provider"] = .string(provider) }
        if let disabledSkills { params["disabled_skills"] = .array(disabledSkills.map(JSONValue.string)) }
        if let uiMeta { params["ui_meta"] = uiMeta }
        try await rpc("profiles.configure", .object(params))
    }

    /// Custom avatar portrait (PNG/JPEG/WebP ≤ 2 MB), e.g. from image.generate.
    public func setProfileAvatar(name: String, dataURL: String) async throws {
        try await rpc("profiles.set_asset", ["name": .string(name), "asset": "avatar",
                                             "data": .string(dataURL)])
    }

    public func profileAvatar(name: String) async throws -> String? {
        let result = try await rpc("profiles.get_asset", ["name": .string(name), "asset": "avatar"])
        guard result["found"]?.boolValue == true else { return nil }
        return result["data"]?.stringValue
    }

    // MARK: - Sessions

    /// `includeHidden` is for the surfaces that OWN hidden sessions — the
    /// per-bot browser and the canonical-chat resolver. The flag stays off for
    /// every shared/global list, which is what `hidden` means upstream
    /// (methods_session.py:180-186). An older gateway ignores the unknown
    /// param and simply keeps hidden rows out.
    public func listSessions(limit: Int = 200, profile: String? = nil,
                             includeHidden: Bool = false) async throws -> [StoredSession] {
        var params: [String: JSONValue] = ["limit": .number(Double(limit))]
        if let profile { params["profile"] = .string(profile) }
        if includeHidden { params["include_hidden"] = .bool(true) }
        let result = try await rpc("session.list", .object(params))
        guard let rawRows = result["sessions"]?.arrayValue else {
            throw GatewayError(code: -8, message: "session.list malformed response")
        }
        let rows = rawRows.map(StoredSession.init)
        guard rows.allSatisfy({ !$0.id.isEmpty }) else {
            throw GatewayError(code: -8, message: "session.list contained malformed session")
        }
        return rows
    }

    /// `hidden` marks a session plugin-owned: it stays out of shared lists
    /// (recents, the resume picker) and is browsed only by the surface that
    /// owns it. Bot Mode's canonical chats are always born this way
    /// (plugin.js:2758-2763). Applied as `pending_hidden` until the row exists
    /// (methods_session.py:100, server.py:3014-3021); older gateways ignore it.
    /// Flip the generic hidden flag on a stored session and its compression
    /// lineage (methods_session.py:1183). Bot Mode uses this to keep forever
    /// chats and room member sessions out of shared recents while remaining
    /// resumable from the per-bot browser. Older gateways reject the RPC;
    /// callers must treat that as unsupported, not as a user-visible failure.
    @discardableResult
    public func setSessionHidden(_ sessionID: String, hidden: Bool) async throws -> Bool {
        let result = try await rpc("session.set_hidden",
                                   ["session_id": .string(sessionID),
                                    "hidden": .bool(hidden)])
        return result["hidden"]?.boolValue ?? hidden
    }

    public func createSession(profile: String? = nil, title: String? = nil,
                              model: String? = nil, hidden: Bool = false) async throws -> LiveSession {
        var params: [String: JSONValue] = ["source": "talaria", "cols": 100]
        if let profile { params["profile"] = .string(profile) }
        if let title { params["title"] = .string(title) }
        if let model { params["model"] = .string(model) }
        if hidden { params["hidden"] = .bool(true) }
        return LiveSession(try await rpc("session.create", .object(params)))
    }

    /// Resume a stored session by durable key. Within ~20 s of a disconnect
    /// this reattaches the live in-memory session with in-flight state.
    public func resumeSession(_ storedID: String, profile: String? = nil,
                              deferHistory: Bool = false) async throws -> LiveSession {
        var params: [String: JSONValue] = ["session_id": .string(storedID), "source": "talaria"]
        if let profile { params["profile"] = .string(profile) }
        if deferHistory { params["defer_history"] = .bool(true) }
        return LiveSession(try await rpc("session.resume", .object(params), timeout: 180))
    }

    /// Exact resume plus the transport frame boundary of the authoritative
    /// projection. Used by transactional navigation to replay only events that
    /// arrived after this snapshot.
    public func resumeSessionSequenced(_ storedID: String, profile: String? = nil,
                                       deferHistory: Bool = false) async throws
        -> (session: LiveSession, inboundSequence: UInt64) {
        let lease = try await acquireTrafficLease()
        do {
            guard let transport else {
                throw GatewayError(code: -3, message: "not connected")
            }
            var params: [String: JSONValue] = [
                "session_id": .string(storedID), "source": "talaria",
            ]
            if let profile { params["profile"] = .string(profile) }
            if deferHistory { params["defer_history"] = .bool(true) }
            let response = try await transport.requestSequenced(
                "session.resume", params: .object(params), timeout: 180)
            await lease?.release()
            return (LiveSession(response.value), response.inboundSequence)
        } catch {
            await lease?.release()
            throw error
        }
    }

    public func closeSession(_ sessionID: String) async throws {
        try await rpc("session.close", ["session_id": .string(sessionID)])
    }

    public func interruptSession(_ sessionID: String) async throws {
        try await rpc("session.interrupt", ["session_id": .string(sessionID)])
    }

    public func sessionUsage(_ sessionID: String) async throws -> Usage {
        Usage(try await rpc("session.usage", ["session_id": .string(sessionID)]))
    }

    public func contextBreakdown(_ sessionID: String) async throws -> [ContextSegment] {
        let result = try await rpc("session.context_breakdown", ["session_id": .string(sessionID)])
        let max = result["context_max"]?.doubleValue ?? 0
        return result["categories"]?.arrayValue?.compactMap { cat -> ContextSegment? in
            guard let label = cat["label"]?.stringValue ?? cat["name"]?.stringValue else { return nil }
            let tokens = cat["tokens"]?.doubleValue ?? cat["value"]?.doubleValue ?? 0
            let pct = max > 0 ? Int((tokens / max * 100).rounded()) : 0
            return ContextSegment(label: label, percent: pct)
        } ?? []
    }

    // MARK: - Prompting

    /// Submit a prompt; returns once accepted ({"status":"streaming"}).
    /// Tokens/tool events then stream to event handlers.
    @discardableResult
    public func submitPrompt(sessionID: String, text: String, queued: Bool = false,
                             truncate: TranscriptActing.TruncateAddress = .init()) async throws -> JSONValue {
        var params: [String: JSONValue] = ["session_id": .string(sessionID), "text": .string(text)]
        if queued { params["queued"] = .bool(true) }
        for (key, value) in TranscriptActing.truncateParams(truncate) {
            params[key] = value
        }
        return try await rpc("prompt.submit", .object(params), timeout: 1800)
    }

    public func steer(sessionID: String, text: String) async throws {
        try await rpc("session.steer", ["session_id": .string(sessionID), "text": .string(text)])
    }

    // MARK: - Approvals

    /// Answer a blocking approval. The parked run resumes on resolve.
    public func respondToApproval(sessionID: String, choice: ApprovalChoice,
                                  requestID: String? = nil) async throws {
        var params: [String: JSONValue] = ["session_id": .string(sessionID),
                                           "choice": .string(choice.rawValue)]
        if let requestID { params["request_id"] = .string(requestID) }
        try await rpc("approval.respond", .object(params))
    }

    public func pendingApprovals(sessionID: String) async throws -> [ApprovalRequest] {
        let result = try await rpc("approval.pending", ["session_id": .string(sessionID)])
        return result["approvals"]?.arrayValue?.map { ApprovalRequest($0, sessionID: sessionID) } ?? []
    }

    public func respondToClarify(sessionID: String, requestID: String, answer: String) async throws {
        try await rpc("clarify.respond", ["session_id": .string(sessionID),
                                          "request_id": .string(requestID),
                                          "answer": .string(answer)])
    }

    // MARK: - YOLO (per-session approval bypass, desktop status-bar parity)

    public func setYolo(sessionID: String, enabled: Bool) async throws {
        try await rpc("config.set", ["session_id": .string(sessionID), "key": "yolo",
                                     "value": .string(enabled ? "on" : "off"),
                                     "scope": "session"])
    }

    // MARK: - Models

    public func modelOptions(sessionID: String? = nil) async throws -> JSONValue {
        var params: [String: JSONValue] = [:]
        if let sessionID { params["session_id"] = .string(sessionID) }
        return try await rpc("model.options", .object(params))
    }

    /// Pass `provider` whenever it is known: `parse_model_switch_args`
    /// resolves a bare name within the CURRENT aggregator first
    /// (model_switch.py:713-716), so a self-hosted model set while a
    /// subscription provider is active gets looked up on the wrong endpoint.
    /// `--provider <slug>` is the documented spelling (model_switch.py:515).
    public func setSessionModel(sessionID: String, model: String,
                                provider: String? = nil) async throws {
        let slug = (provider ?? "").trimmingCharacters(in: .whitespaces)
        let value = slug.isEmpty ? model : "\(model) --provider \(slug)"
        try await rpc("config.set", ["session_id": .string(sessionID),
                                     "key": "model", "value": .string(value)])
    }

    /// Reasoning effort for the session ("none" | "low" | "medium" | "high" —
    /// the gateway validates; desktop's status-bar reasoning control parity).
    public func setReasoningEffort(sessionID: String, value: String) async throws {
        try await rpc("config.set", ["session_id": .string(sessionID),
                                     "key": "reasoning", "value": .string(value)])
    }

    // Device registration for the talaria-push relay lives in
    // GatewayClient+Providers.swift. It is deliberately the ONLY spelling: the
    // relay's upsert replaces the whole record, so a registration call that
    // cannot express `profile_filter` erases the caller's per-bot push filter
    // every time it runs. An earlier two-argument version here did exactly
    // that on every gateway connect.

    // MARK: - Cron (Routines)

    /// Jobs are namespaced "[bot:<name>] <routine>" by convention; runs land
    /// in the bot's own chat.
    public func cronManage(_ params: JSONValue) async throws -> JSONValue {
        try await rpc("cron.manage", params)
    }

    public func cronList() async throws -> [CronJob] {
        let result = try await rpc("cron.manage", ["action": "list"])
        let rows = result["jobs"]?.arrayValue ?? result["entries"]?.arrayValue ?? []
        return rows.map(CronJob.init)
    }

    // MARK: - Image generation (avatar portraits; works over remote gateways)

    public func generateImage(prompt: String, aspectRatio: String = "square") async throws -> String? {
        let result = try await rpc("image.generate",
                                   ["prompt": .string(prompt), "aspect_ratio": .string(aspectRatio)],
                                   timeout: 300)
        return result["image_data"]?.stringValue ?? result["image"]?.stringValue
    }

    // MARK: - Voice

    public func voiceStatus() async throws -> JSONValue {
        try await rpc("voice.toggle", ["action": "status"])
    }

    public func voiceSet(on: Bool) async throws {
        try await rpc("voice.toggle", ["action": .string(on ? "on" : "off")])
    }

    // MARK: - REST helpers

    // MARK: - Authenticated REST

    /// Perform an authenticated REST call against this gateway and return the
    /// raw body. The public seam cross-module extensions need: `auth` and
    /// `credential` are file-private, so TalariaUI extensions cannot build
    /// their own authorized requests.
    ///
    /// `path` is relative to the gateway root ("api/sessions/search"), and any
    /// reverse-proxy path prefix in `baseURL` is preserved.
    @discardableResult
    public func restData(path: String, method: String = "GET",
                         query: [URLQueryItem] = [], body: Data? = nil,
                         contentType: String = "application/json",
                         timeout: TimeInterval = 30) async throws -> Data {
        try await authenticatedRESTData(
            path: path, method: method, query: query, body: body,
            contentType: contentType, timeout: timeout, responseLimit: nil)
    }

    /// The same exact-client authenticated REST call with a hard wire-body
    /// ceiling. Unlike `data(for:)`, the bounded transport cancels as soon as
    /// Content-Length or cumulative chunks exceed `maximumResponseBytes`.
    @discardableResult
    public func restDataBounded(path: String, method: String = "GET",
                                query: [URLQueryItem] = [], body: Data? = nil,
                                contentType: String = "application/json",
                                timeout: TimeInterval = 30,
                                maximumResponseBytes: Int) async throws -> Data {
        guard maximumResponseBytes >= 0 else {
            throw GatewayError(code: -11, message: "Invalid REST response limit.")
        }
        return try await authenticatedRESTData(
            path: path, method: method, query: query, body: body,
            contentType: contentType, timeout: timeout,
            responseLimit: maximumResponseBytes)
    }

    private func authenticatedRESTData(
        path: String, method: String, query: [URLQueryItem], body: Data?,
        contentType: String, timeout: TimeInterval, responseLimit: Int?
    ) async throws -> Data {
        let lease = try await acquireTrafficLease()
        do {
            var comps = URLComponents(url: baseURL.appending(path: path),
                                      resolvingAgainstBaseURL: false)
            if !query.isEmpty { comps?.queryItems = query }
            guard let url = comps?.url else {
                throw GatewayError(code: -11, message: "bad REST path: \(path)")
            }
            var req = URLRequest(url: url, timeoutInterval: timeout)
            req.httpMethod = method
            if let body {
                req.httpBody = body
                req.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            auth.apply(credential: credential, to: &req)
            let (data, response) = try await restExecutor(req, responseLimit)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                let detail = (try? JSONDecoder().decode(JSONValue.self, from: data))?["detail"]?.stringValue
                throw GatewayError(code: code, message: detail ?? "HTTP \(code) for \(path)")
            }
            await lease?.release()
            return data
        } catch {
            await lease?.release()
            throw error
        }
    }

    /// `restData` decoded as JSON.
    @discardableResult
    public func restJSON(path: String, method: String = "GET",
                         query: [URLQueryItem] = [], body: JSONValue? = nil,
                         timeout: TimeInterval = 30) async throws -> JSONValue {
        let payload = try body.map { try JSONEncoder().encode($0) }
        let data = try await restData(path: path, method: method, query: query,
                                      body: payload, timeout: timeout)
        guard !data.isEmpty else { return .null }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Bounded authenticated REST decoded as JSON.
    @discardableResult
    public func restJSONBounded(path: String, method: String = "GET",
                                query: [URLQueryItem] = [], body: JSONValue? = nil,
                                timeout: TimeInterval = 30,
                                maximumResponseBytes: Int) async throws -> JSONValue {
        let payload = try body.map { try JSONEncoder().encode($0) }
        let data = try await restDataBounded(
            path: path, method: method, query: query, body: payload,
            timeout: timeout, maximumResponseBytes: maximumResponseBytes)
        guard !data.isEmpty else { return .null }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    // Transcript hydration lives in `latestSessionMessages`
    // (TalariaUI/AppModelLive+CanonicalChat.swift). The wrapper that used to
    // sit here sent only limit+offset, and the endpoint pages from the OLDEST
    // message whenever a `limit` arrives without `order`
    // (hermes_cli/web_routers/sessions.py:601-640) — so it opened a long chat
    // at its beginning — while omitting `profile` made it read the DEFAULT
    // profile's state.db and 404 for every other bot.
}
