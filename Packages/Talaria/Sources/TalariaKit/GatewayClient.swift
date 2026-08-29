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
    /// Current Hermes' `canonical_session` registry answer. The gateway
    /// resolves the exact `Bot Chat` title in this profile's own database,
    /// including hidden rows and compression tips. Older gateways may instead
    /// answer the removed `preferred_session` contract as a decode fallback.
    public var canonicalSession: CanonicalSession

    /// Source-compatible projection for callers migrating from the removed
    /// `preferred_session` contract. Current identity never comes from a
    /// client-carried ui_meta chat pointer.
    public var preferredSession: PreferredSession { canonicalSession }
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
        /// when the lineage was never compressed. Current `canonical_session`
        /// and exact-title `session.list` carry it; `last_session` leaves it
        /// nil. `id` remains the durable title-registry row.
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
            guard let id = v?["id"]?.stringValue, !id.isEmpty else { return nil }
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

    /// The four answers `profiles.list` can give about the canonical Bot Chat
    /// registry row. The absent/null distinction is load-bearing:
    ///
    /// - **absent** — `include_sessions` was false or the gateway predates both
    ///   registry contracts. Inconclusive and eligible for legacy fallback.
    /// - **null** — current Hermes authoritatively found no eligible exact
    ///   `Bot Chat` registry row (missing, archived, or internal source).
    /// - **invalid** — the key was present but malformed. It is quarantined:
    ///   never publication/identity evidence and never permission to fall back
    ///   to an unrelated `last_session` preview.
    /// - **a summary** — the registry row resolved, hidden rows included and
    ///   compression lineages followed to their live tip.
    public enum CanonicalSession: Sendable {
        case notRequested
        case gone
        case invalid
        case resolved(ProfileSessionRef)

        public var session: ProfileSessionRef? {
            if case .resolved(let session) = self { return session }
            return nil
        }

        /// The gateway omitted the key entirely. This is an inconclusive
        /// compatibility answer, never permission to clear or replace an
        /// identity. `notRequested` remains the source-compatible case
        /// spelling during the migration.
        public var isOmitted: Bool {
            if case .notRequested = self { return true }
            return false
        }

        /// True only when a gateway that speaks a registry contract said so.
        public var isDefinitivelyGone: Bool {
            if case .gone = self { return true }
            return false
        }

        public var isMalformed: Bool {
            if case .invalid = self { return true }
            return false
        }
    }

    public typealias PreferredSession = CanonicalSession

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
        canonicalSession = Self.decodeCanonicalSession(v)
        workerSession = WorkerSessionRef(v["worker_session"])
        displayName = v["display_name"]?.stringValue
        uiMeta = v["ui_meta"]
        let revisionField = Self.decodeUIMetaRevisions(v["ui_meta_revisions"])
        uiMetaRevisions = revisionField.revisions
        hasValidUIMetaRevisionsWire = revisionField.isValid
        hasAvatar = v["has_avatar"]?.boolValue ?? false
    }

    /// A present current field is authoritative, including null or malformed.
    /// Only complete absence permits the removed preferred-session fallback.
    private static func decodeCanonicalSession(_ v: JSONValue) -> CanonicalSession {
        if let canonical = v["canonical_session"] {
            if canonical == .null { return .gone }
            guard let session = ProfileSessionRef(canonical), session.isCanonicalBotChat else {
                return .invalid
            }
            return .resolved(session)
        }
        // Older preferred_session described a client-requested durable pin,
        // not the current exact-title registry result. Preserve that legacy
        // compatibility policy separately; only presence of canonical_session
        // invokes the strict Bot Chat lineage proof above.
        if let preferred = v["preferred_session"] {
            if preferred == .null { return .gone }
            return ProfileSessionRef(preferred).map(CanonicalSession.resolved)
                ?? .invalid
        }
        return .notRequested
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

    /// The session whose text a roster row previews. The canonical title
    /// registry is the click identity and wins over unrelated recent activity.
    /// Older gateways fall back through legacy preferred and last_session.
    public var previewSession: ProfileSessionRef? {
        if canonicalSession.isMalformed { return nil }
        return canonicalSession.session ?? rawLastSession ?? lastSession
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
        let preferred = canonicalSession.session
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
    /// Live compression tip returned by exact-title lookup. The durable `id`
    /// remains the root registry row used for future title lookups.
    public var resolvedID: String?
    public var rootTitle: String?
    public var title: String
    public var preview: String?
    public var startedAt: Double?
    public var lastActive: Double?
    public var messageCount: Int
    public var source: String?

    init(_ v: JSONValue) {
        id = v["id"]?.stringValue ?? ""
        let resolved = v["resolved_id"]?.stringValue
        resolvedID = resolved?.isEmpty == false ? resolved : nil
        rootTitle = v["root_title"]?.stringValue
        title = v["title"]?.stringValue ?? ""
        preview = v["preview"]?.stringValue
        startedAt = v["started_at"]?.doubleValue
        lastActive = v["last_active"]?.doubleValue
        messageCount = v["message_count"]?.intValue ?? 0
        source = v["source"]?.stringValue
    }

    public var resumeID: String { resolvedID ?? id }

    func matchesExactTitle(_ expected: String) -> Bool {
        if let rootTitle, !rootTitle.isEmpty { return rootTitle == expected }
        return title == expected
    }
}

public struct SessionTitleReceipt: Sendable, Equatable {
    public var title: String
    public var pending: Bool
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
    /// Typed retained-turn projection. `nil` covers absent/null and malformed
    /// non-object containers. Lifecycle consumers should use this bounded
    /// projection; the raw field remains only for broader wire compatibility.
    public var retainedInflightAdmission: RetainedInflightTurnAdmission
    public var retainedInflight: RetainedInflightTurn? { retainedInflightAdmission.turn }
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
        retainedInflightAdmission = RetainedInflightTurnAdmission.admit(v["inflight"])
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
    /// A peer answered an exact-title request with an ordinary nonmatching
    /// listing, proving it ignored the current registry parameter. Callers
    /// must not reinterpret that indeterminate compatibility answer as an
    /// authoritative empty registry and mint a duplicate named session.
    public static let exactTitleLookupIndeterminate = -32_902
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
    typealias RPCExecutor = @Sendable (String, JSONValue?, TimeInterval) async throws -> JSONValue
    private let restExecutor: RESTExecutor
    /// Package-test readiness seam. Production always reads the exact current
    /// transport state; this only makes half-open/closed wake policy
    /// deterministic without opening a real WebSocket.
    private var foregroundReadinessForTesting: Bool?
    /// Package-test RPC seam used by foreground liveness and other
    /// transport-free lifecycle tests.
    private var rpcExecutorForTesting: RPCExecutor?

    /// Re-published stream of all events from the current transport.
    public private(set) var eventsTask: Task<Void, Never>?
    private var eventHandlers: [UUID: @Sendable (GatewayEvent) -> Void] = [:]

    public init(baseURL: URL, credential: GatewayCredential,
                keychain: KeychainStore = KeychainStore()) {
        let wire = GatewayURL.normalize(baseURL.absoluteString) ?? baseURL
        self.baseURL = wire
        self.auth = GatewayAuthClient(baseURL: wire)
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
        let wire = GatewayURL.normalize(baseURL.absoluteString) ?? baseURL
        self.baseURL = wire
        self.auth = GatewayAuthClient(baseURL: wire)
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
            if let foregroundReadinessForTesting {
                return foregroundReadinessForTesting
            }
            guard let transport else { return false }
            return await transport.state == .ready
        }
    }

    /// Compare against the credential currently owned by this client without
    /// exporting token material across the actor boundary. OAuth reconnects
    /// may rotate tokens before the WebSocket dial completes, so lifecycle
    /// fences compare the registry to this post-refresh authority.
    public func ownsCredential(_ candidate: GatewayCredential) -> Bool {
        credential == candidate
    }

    /// Deterministic seam for credential-rotation lifecycle tests.
    func replaceCredentialForTesting(_ replacement: GatewayCredential) {
        credential = replacement
    }

    func setForegroundReadinessForTesting(_ ready: Bool?) {
        foregroundReadinessForTesting = ready
    }

    func setRPCExecutorForTesting(_ executor: RPCExecutor?) {
        rpcExecutorForTesting = executor
    }

    /// Validate a socket immediately after iOS foregrounds the app. This is a
    /// short, bounded application RPC rather than a belief based on
    /// URLSessionWebSocketTask state: suspended half-open links often still
    /// report ready until their first write/response boundary.
    ///
    /// Current Hermes answers `{ "ok": true }`. A JSON-RPC method-not-found
    /// reply still proves the link is alive (older gateways). Timeouts,
    /// malformed replies, and transport errors enter supervised reconnect.
    /// Local lifecycle traffic rejection is not a link failure.
    public func validateForegroundLiveness() async -> ForegroundSocketLiveness {
        let ready: Bool
        if let foregroundReadinessForTesting {
            ready = foregroundReadinessForTesting
        } else if let transport {
            ready = await transport.state == .ready
        } else {
            ready = false
        }
        guard ready else { return .reconnectRequired }

        do {
            let result = try await rpc(
                "gateway.ping", .object([:]), timeout: ForegroundSocketPolicy.pingTimeout)
            return ForegroundSocketPolicy.outcome(transportReady: true, result: .success(result))
        } catch {
            return ForegroundSocketPolicy.outcome(transportReady: true, result: .failure(error))
        }
    }

    /// Drop the parked transport without sending. Used when iOS is about to
    /// suspend the process — any write onto that socket can wedge URLSession.
    public func invalidateTransportForBackground() async {
        if let previous = transport {
            await previous.close()
            transport = nil
        }
        eventsTask?.cancel()
        eventsTask = nil
    }

    /// Connect (or reconnect). Refreshes OAuth tokens when near expiry and
    /// mints a fresh single-use WS ticket per attempt.
    ///
    /// `readyTimeout` is the `gateway.ready` bound (default 15s). Redials
    /// pass `PostBootReconnectPolicy.redialReadyTimeout` so an unreachable
    /// host fails into the next visible try instead of one frozen 15s wait.
    public func connect(readyTimeout: TimeInterval = 15) async throws {
        try Task.checkCancellation()
        // Session-token connects used to go straight to WebSocket and wait
        // 15s for gateway.ready. Mini never logged the phone: no HTTP, and a
        // missing :9119 hit :80. Probe /api/status first (unauthenticated,
        // finite) so the journal names the exact origin and serve.log sees
        // the client before any ready wait.
        let wire = GatewayURL.normalize(baseURL.absoluteString) ?? baseURL
        let wireAuth = GatewayAuthClient(baseURL: wire)
        let probeTimeout = min(3, readyTimeout)
        do {
            _ = try await wireAuth.status(timeout: probeTimeout)
        } catch {
            throw GatewayError(
                code: -2,
                message: "status \(GatewayURL.originForDisplay(wire)): \(error.localizedDescription)")
        }
        if case .oauth(let tokens) = credential, tokens.needsRefresh {
            do {
                let refreshed = try await wireAuth.refresh(tokens)
                credential = .oauth(refreshed)
                try? keychain.save(credential, for: wire)
            } catch AuthError.sessionExpired {
                keychain.delete(for: wire)
                throw AuthError.sessionExpired
            } catch AuthError.providerUnreachable {
                // Keep tokens; the access token may still be valid.
            }
        }

        let ticket: String?
        if case .oauth = credential {
            ticket = try await wireAuth.mintWSTicket(credential: credential)
        } else {
            ticket = nil
        }

        try Task.checkCancellation()
        let url = try wireAuth.webSocketURL(credential: credential, ticket: ticket)
        // A reconnect must retire the previous receive loop and event stream
        // before a replacement transport is published. Leaving them running
        // makes the old pump finish later and look like a fresh drop.
        if let previous = transport {
            await previous.close()
            self.transport = nil
        }
        eventsTask?.cancel()
        eventsTask = nil

        try Task.checkCancellation()
        let transport = GatewayTransport(url: url)
        self.transport = transport
        // Single consumer of `events`. Start the pump BEFORE waiting for
        // ready so connect() does not own the iterator (that left RPCs
        // unanswered after gateway.ready — a ~15s dead link).
        eventsTask = Task {
            for await event in transport.events {
                for handler in self.handlerSnapshot() {
                    handler(event)
                }
            }
        }
        do {
            try await transport.connect(timeout: readyTimeout)
            try Task.checkCancellation()
        } catch {
            eventsTask?.cancel()
            eventsTask = nil
            throw error
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
            let result: JSONValue
            if let rpcExecutorForTesting {
                result = try await rpcExecutorForTesting(method, params, timeout)
            } else {
                guard let transport else { throw GatewayError(code: -3, message: "not connected") }
                result = try await transport.request(method, params: params, timeout: timeout)
            }
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

    /// Current Hermes resolves each profile's exact-title `Bot Chat` registry
    /// row server-side as `canonical_session`. No client session pointer is
    /// sent. The deprecated argument remains source-compatible while UI code
    /// migrates, but is intentionally ignored.
    public func listProfiles(includeSessions: Bool = true,
                             preferredSessionIDs: [String: String]? = nil) async throws -> [HermesProfile] {
        _ = preferredSessionIDs
        let params = Self.profileListParams(includeSessions: includeSessions)
        let result = try await rpc("profiles.list", params)
        guard let rawRows = result["profiles"]?.arrayValue else {
            throw GatewayError(code: -8, message: "profiles.list malformed response")
        }
        let rows = try Self.decodeProfileRows(rawRows)
        return rows.map { $0.foldingCanonicalPreview() }
    }

    static func profileListParams(includeSessions: Bool) -> JSONValue {
        ["include_sessions": .bool(includeSessions)]
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

    /// Deprecated compatibility hook. Current canonical identity is the
    /// server-side exact title registry, so client-carried pins are inert.
    public func notePreferredSessions(_ pins: [String: String]) {
        _ = pins
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
                             title: String? = nil,
                             includeHidden: Bool = false) async throws -> [StoredSession] {
        let admittedLimit = min(max(limit, 1), 200)
        let params = Self.sessionListParams(
            limit: admittedLimit, profile: profile, title: title, includeHidden: includeHidden)
        let result = try await rpc("session.list", params)
        guard let rawRows = result["sessions"]?.arrayValue else {
            throw GatewayError(code: -8, message: "session.list malformed response")
        }
        return try Self.decodeStoredSessionRows(rawRows, limit: admittedLimit, title: title)
    }

    static func decodeStoredSessionRows(_ rawRows: [JSONValue], limit: Int,
                                        title: String?) throws -> [StoredSession] {
        let admittedLimit = min(max(limit, 1), 200)
        // The old-gateway compatibility scan is deliberately no larger than
        // the legacy server's own default window. Bound before model creation
        // so a malformed peer cannot turn a one-row registry lookup into
        // unbounded client work.
        let rows = rawRows.prefix(title == nil ? admittedLimit : 200).map(StoredSession.init)
        guard rows.allSatisfy({ !$0.id.isEmpty }) else {
            throw GatewayError(code: -8, message: "session.list contained malformed session")
        }
        // Current Hermes performs an O(1) exact-title registry lookup. Older
        // gateways ignore `title` and return a normal window, so enforce the
        // same exact title/root rule locally instead of trusting the first row.
        if let title {
            let exact = Array(rows.filter { $0.matchesExactTitle(title) }.prefix(1))
            if exact.isEmpty, !rows.isEmpty {
                throw GatewayError(
                    code: exactTitleLookupIndeterminate,
                    message: "session.list did not honor exact title lookup")
            }
            return exact
        }
        return rows
    }

    static func exactSessionListParams(profile: String, title: String) -> JSONValue {
        sessionListParams(limit: 200, profile: profile, title: title, includeHidden: true)
    }

    private static func sessionListParams(limit: Int, profile: String?, title: String?,
                                          includeHidden: Bool) -> JSONValue {
        var params: [String: JSONValue] = [:]
        if title == nil { params["limit"] = .number(Double(min(max(limit, 1), 200))) }
        if let profile { params["profile"] = .string(profile) }
        if let title { params["title"] = .string(title) }
        if includeHidden { params["include_hidden"] = .bool(true) }
        return .object(params)
    }

    /// Exact current-Hermes registry lookup for one profile's canonical chat.
    /// `nil` is an authoritative miss on current gateways; older gateways are
    /// safely narrowed by the local exact-title filter above.
    public func canonicalBotChat(profile: String) async throws -> StoredSession? {
        try await listSessions(profile: profile, title: "Bot Chat", includeHidden: true).first
    }

    /// Name a live runtime session. Gateway errors, including an older
    /// gateway's method-not-found response, remain typed `GatewayError`s so UI
    /// compatibility policy can distinguish unsupported from a failed write.
    public func titleSession(runtimeID: String, title: String) async throws -> SessionTitleReceipt {
        let result = try await rpc(
            "session.title", Self.sessionTitleParams(runtimeID: runtimeID, title: title))
        return try Self.decodeSessionTitleReceipt(result)
    }

    static func decodeSessionTitleReceipt(_ result: JSONValue) throws -> SessionTitleReceipt {
        guard let title = result["title"]?.stringValue, !title.isEmpty,
              let pending = result["pending"]?.boolValue else {
            throw GatewayError(code: -8, message: "session.title malformed response")
        }
        return SessionTitleReceipt(title: title, pending: pending)
    }

    static func sessionTitleParams(runtimeID: String, title: String) -> JSONValue {
        ["session_id": .string(runtimeID), "title": .string(title)]
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
    /// Open-chat callers pass `deferHistory: true` so the ack is not the
    /// full transcript; mutation-proof callers keep the default.
    public func resumeSession(_ storedID: String, profile: String? = nil,
                              deferHistory: Bool = false) async throws -> LiveSession {
        LiveSession(try await rpc(
            "session.resume",
            Self.resumeSessionParams(storedID, profile: profile, deferHistory: deferHistory),
            timeout: 180))
    }

    public static func resumeSessionParams(_ storedID: String, profile: String? = nil,
                                           deferHistory: Bool = false) -> JSONValue {
        OpenChatHistoryPolicy.resumeSessionParams(
            storedID, profile: profile, deferHistory: deferHistory)
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
            let response = try await transport.requestSequenced(
                "session.resume",
                params: Self.resumeSessionParams(
                    storedID, profile: profile, deferHistory: deferHistory),
                timeout: 180)
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
