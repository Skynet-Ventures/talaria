import Foundation

enum StoredTranscriptIdentityPolicy {
    static let maximumIdentityBytes = 1_024

    static func admits(_ raw: String, pathComponent: Bool = false) -> Bool {
        guard !raw.isEmpty,
              raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.utf8.count <= maximumIdentityBytes,
              raw != ".", raw != ".." else { return false }
        return !raw.unicodeScalars.contains(where: {
            $0.value < 0x20 || (0x7f...0x9f).contains($0.value)
                || $0.value == 0x061c || (0x200e...0x200f).contains($0.value)
                || (0x202a...0x202e).contains($0.value)
                || (0x2066...0x2069).contains($0.value)
                || (pathComponent && ($0 == "/" || $0 == "\\"))
        })
    }
}

/// Immutable source evidence for a stored-transcript read.
///
/// Hermes' REST route only echoes the resolved session id; it cannot know
/// which saved gateway connection issued the request. A caller that owns
/// source routing can therefore capture this value before starting the read,
/// retain it with the task, and accept the result only when it still matches.
/// The type deliberately owns no registry or mutable state.
public struct StoredTranscriptPageSource: Sendable, Hashable, Equatable {
    /// App-owned stable gateway/connection identity, not a URL or credential.
    public let gatewayID: String
    /// Exact profile/state-store namespace that owns the stored session.
    public let profile: String
    /// Durable/root session identity used in the REST path. This deliberately
    /// remains distinct from a compression-lineage tip returned by Hermes.
    public let storedSessionID: String

    public init(gatewayID: String, profile: String, storedSessionID: String) {
        self.gatewayID = gatewayID
        self.profile = profile
        self.storedSessionID = storedSessionID
    }

    /// An empty source must never be treated as authority for a later ledger.
    public var isUsable: Bool {
        StoredTranscriptIdentityPolicy.admits(gatewayID)
            && StoredTranscriptIdentityPolicy.admits(profile)
            && StoredTranscriptIdentityPolicy.admits(storedSessionID, pathComponent: true)
    }
}

/// One bounded request to Hermes' stored transcript REST route.
///
/// The endpoint's `latest` order is reverse-paged: `offset == 0` is the
/// newest page, but the rows in that page are still chronological. This value
/// carries the normalized request so a decoded echo can be verified before a
/// caller grafts a page into a transcript.
public struct StoredTranscriptPageRequest: Sendable, Equatable {
    /// Hermes caps this route at 500 rows. Keeping the client cap identical
    /// prevents a gateway from silently changing the requested page shape.
    public static let maximumLimit = 500
    /// Tail hydration remains deliberately smaller than the gateway ceiling.
    public static let defaultLimit = 200
    /// A defensive ceiling for accidental or hostile offset arithmetic. It is
    /// much larger than the app can display, but keeps query construction and
    /// continuation math finite.
    public static let maximumOffset = 1_000_000_000

    /// The durable id addressed in `/api/sessions/{id}/messages`.
    public let storedSessionID: String
    /// `nil` means the gateway's own/default profile. An explicit source uses
    /// the non-empty profile from `StoredTranscriptPageSource` instead.
    public let profile: String?
    /// Number of newest rows skipped before selecting this page.
    public let offset: Int
    /// The normalized server page size, always in `1...maximumLimit`.
    public let limit: Int
    /// Whether the route must retain compacted display rows. It defaults to
    /// true because compacted rows are durable transcript history, not audit
    /// debris.
    public let includeCompacted: Bool
    /// Optional app-owned authority captured with the request. The client does
    /// not interpret it; later state owners use it to reject stale results.
    public let source: StoredTranscriptPageSource?

    public init(storedSessionID: String, profile: String? = nil,
                offset: Int = 0, limit: Int = Self.defaultLimit,
                includeCompacted: Bool = true) {
        self.storedSessionID = storedSessionID
        self.profile = profile
        self.offset = Self.boundedOffset(offset)
        self.limit = Self.boundedLimit(limit)
        self.includeCompacted = includeCompacted
        source = nil
    }

    /// Build a request already bound to an app-owned source tuple. This is the
    /// form a future transcript ledger should capture before its asynchronous
    /// REST read begins.
    public init(source: StoredTranscriptPageSource, offset: Int = 0,
                limit: Int = Self.defaultLimit, includeCompacted: Bool = true) {
        storedSessionID = source.storedSessionID
        profile = source.profile
        self.offset = Self.boundedOffset(offset)
        self.limit = Self.boundedLimit(limit)
        self.includeCompacted = includeCompacted
        self.source = source
    }

    /// The request can be constructed from user-derived input, so validate the
    /// identifier again at the transport boundary rather than relying on a
    /// later URL failure.
    public var hasUsableStoredSessionID: Bool {
        StoredTranscriptIdentityPolicy.admits(storedSessionID, pathComponent: true)
    }

    static func boundedLimit(_ proposed: Int) -> Int {
        min(max(proposed, 1), maximumLimit)
    }

    static func boundedOffset(_ proposed: Int) -> Int {
        min(max(proposed, 0), maximumOffset)
    }
}

/// Raw stored transcript row plus the durable identity that can safely dedupe
/// overlapping reverse pages.
///
/// The raw payload is retained without projection so a later UI can use the
/// same row fields as the existing transcript hydrator. `row_id` is the WS
/// spelling and `id` is the REST/SQLite spelling; when both exist they must
/// agree rather than letting a malformed peer pick an identity arbitrarily.
public struct StoredTranscriptRow: Sendable, Equatable {
    public enum Identity: Sendable, Hashable, Equatable {
        case integer(Int)
        case string(String)
    }

    /// Exact JSON object the gateway returned, including future fields.
    public let raw: JSONValue
    /// Stable durable identity when the gateway supplied one. It is optional
    /// for older peers, never synthesized from text or page position.
    public let identity: Identity?
    /// Convenience for Hermes' normal SQLite integer ids. This is the same
    /// durable identity current AppModel hydration calls `rowID`.
    public var rowID: Int? {
        guard case .integer(let value) = identity else { return nil }
        return value
    }
    /// Evidence that this row was retained through in-place compaction. The
    /// raw `compacted` field remains available even if a future peer changes
    /// its representation.
    public let isCompacted: Bool

    init(raw: JSONValue) throws {
        guard raw.objectValue != nil else {
            throw StoredTranscriptPage.protocolError("transcript row was not an object")
        }
        let rowIdentity = try Self.decodeIdentity(raw["row_id"], field: "row_id")
        let databaseIdentity = try Self.decodeIdentity(raw["id"], field: "id")
        if let rowIdentity, let databaseIdentity, rowIdentity != databaseIdentity {
            throw StoredTranscriptPage.protocolError("transcript row identity conflicted")
        }
        self.raw = raw
        identity = rowIdentity ?? databaseIdentity
        isCompacted = raw["compacted"]?.boolValue == true
            || raw["compacted"]?.doubleValue == 1
    }

    private static func decodeIdentity(_ value: JSONValue?, field: String) throws -> Identity? {
        guard let value else { return nil }
        if let number = value.doubleValue {
            guard number.isFinite, number >= 0, let integer = Int(exactly: number) else {
                throw StoredTranscriptPage.protocolError("transcript row \(field) was not an integer")
            }
            return .integer(integer)
        }
        if let string = value.stringValue {
            guard StoredTranscriptIdentityPolicy.admits(string) else {
                throw StoredTranscriptPage.protocolError("transcript row \(field) was invalid")
            }
            return .string(string)
        }
        throw StoredTranscriptPage.protocolError("transcript row \(field) was malformed")
    }
}

/// A page from `GET /api/sessions/{id}/messages`.
///
/// The page is intentionally source-neutral: it preserves raw stored rows and
/// transport truth, but does not create `ChatMessage`s, update a cache, or
/// decide how a view should merge an overlap. `source` is only immutable
/// caller-supplied evidence for a future ledger.
public struct StoredTranscriptPage: Sendable, Equatable {
    /// Hermes' route-level row cap and this model's maximum decoded row count.
    public static let maximumRows = StoredTranscriptPageRequest.maximumLimit
    /// Bounded REST body ceiling. The limit includes JSON structure and row
    /// content, so a malformed gateway cannot make a 500-row page allocate an
    /// unbounded transcript before row validation happens.
    public static let maximumResponseBytes = 8 * 1024 * 1024

    public enum Order: String, Sendable, Equatable {
        case latest
        case oldest
    }

    /// Whether the response proves that another page exists in the requested
    /// direction. A full current-Hermes page without `total`/`has_more` is
    /// deliberately `unknown`, not a false claim that history continues.
    public enum Continuation: Sendable, Equatable {
        case complete
        case more
        case unknown
    }

    /// Echoed or compatibility-projected paging facts. `hasMore == false`
    /// alone does not prove completeness when `continuation == .unknown`; use
    /// `incomplete` or `continuation` when a caller needs that distinction.
    public struct Pagination: Sendable, Equatable {
        public let offset: Int
        public let limit: Int
        public let returned: Int
        /// Optional server-reported display-row total. Missing is distinct from
        /// zero and remains missing for the legacy response shape.
        public let total: Int?
        public let order: Order
        public let continuation: Continuation
        /// Optional future-server declaration retained independently from the
        /// continuation inference above.
        public let reportedIncomplete: Bool?
        /// `false` means an older gateway omitted `pagination`; the values
        /// below are a bounded compatibility projection, never an echoed fact.
        public let hasPagingMetadata: Bool

        public var hasMore: Bool { continuation == .more }
        public var hasKnownContinuation: Bool { continuation != .unknown }
        /// True whenever a caller cannot safely treat this page as the entire
        /// requested direction, including a full page whose continuation is
        /// not explicitly reported by the current Hermes route.
        public var incomplete: Bool {
            reportedIncomplete == true || continuation != .complete
        }
        /// The next reverse-page offset only when pagination itself might not
        /// finish the requested direction. A separate server `incomplete`
        /// warning is evidence to surface, not permission to make an
        /// unbounded continuation request.
        public var nextOffset: Int? {
            guard continuation != .complete else { return nil }
            let (next, overflow) = offset.addingReportingOverflow(returned)
            guard !overflow, next <= StoredTranscriptPageRequest.maximumOffset else { return nil }
            return next
        }
    }

    /// Exact normalized request, including any app-owned source evidence.
    public let request: StoredTranscriptPageRequest
    /// The server-resolved compression-lineage tip. On a legacy response that
    /// lacks `session_id`, this is the requested durable id and
    /// `resolvedSessionIDWasEchoed` is false.
    public let resolvedSessionID: String
    public let resolvedSessionIDWasEchoed: Bool
    /// Rows remain in the response's chronological order; no sorting,
    /// de-duplication, or projection occurs at this protocol boundary.
    public let rows: [StoredTranscriptRow]
    public let pagination: Pagination

    public var requestedSessionID: String { request.storedSessionID }
    public var source: StoredTranscriptPageSource? { request.source }
    /// Source-compatible raw-row spelling for code that already calls stored
    /// transcript records `messages`.
    public var messages: [JSONValue] { rows.map(\.raw) }
    public var offset: Int { pagination.offset }
    public var limit: Int { pagination.limit }
    public var returned: Int { pagination.returned }
    public var total: Int? { pagination.total }
    public var order: Order { pagination.order }
    public var continuation: Continuation { pagination.continuation }
    public var hasMore: Bool { pagination.hasMore }
    public var hasKnownContinuation: Bool { pagination.hasKnownContinuation }
    public var incomplete: Bool { pagination.incomplete }
    public var reportedIncomplete: Bool? { pagination.reportedIncomplete }
    public var nextOffset: Int? { pagination.nextOffset }
    public var hasPagingMetadata: Bool { pagination.hasPagingMetadata }
    public var includesCompacted: Bool { request.includeCompacted }
    public var hasCompactedRows: Bool { rows.contains(where: { $0.isCompacted }) }

    /// A stale result cannot pass just because two gateways happen to use the
    /// same profile and stored session id. Pages without a captured source are
    /// intentionally not accepted by this exact comparison.
    public func matches(_ source: StoredTranscriptPageSource) -> Bool {
        source.isUsable && self.source == source
    }

    /// Decode and validate a page against the exact normalized request that
    /// produced it. Current Hermes must echo all pagination controls. Older
    /// Hermes versions omit `pagination` entirely and are treated as one
    /// bounded complete response for compatibility.
    public init(payload: JSONValue, request: StoredTranscriptPageRequest) throws {
        guard request.hasUsableStoredSessionID else {
            throw Self.protocolError("stored transcript request had no usable session id")
        }
        guard let object = payload.objectValue,
              let rawRows = object["messages"]?.arrayValue else {
            throw Self.protocolError("stored transcript response was malformed")
        }
        guard rawRows.count <= Self.maximumRows else {
            throw Self.protocolError("stored transcript response exceeded row cap")
        }

        let rows = try rawRows.map(StoredTranscriptRow.init(raw:))
        var knownIdentities = Set<StoredTranscriptRow.Identity>()
        for row in rows {
            if let identity = row.identity, !knownIdentities.insert(identity).inserted {
                throw Self.protocolError("stored transcript response repeated a row identity")
            }
        }

        let sessionValue = object["session_id"]
        let echoedSessionID: String?
        if let sessionValue {
            guard let value = sessionValue.stringValue,
                  StoredTranscriptIdentityPolicy.admits(value, pathComponent: true) else {
                throw Self.protocolError("stored transcript response had malformed session identity")
            }
            echoedSessionID = value
        } else {
            echoedSessionID = nil
        }

        self.request = request
        self.resolvedSessionID = echoedSessionID ?? request.storedSessionID
        self.resolvedSessionIDWasEchoed = echoedSessionID != nil
        self.rows = rows

        guard let paginationValue = object["pagination"] else {
            // The historical response shape was `{session_id?, messages}` and
            // ignored any paging query. It is a complete, bounded one-shot
            // read, but callers can still distinguish the inferred controls
            // from a current endpoint echo through `hasPagingMetadata`.
            pagination = Pagination(
                offset: 0,
                limit: rows.count,
                returned: rows.count,
                total: nil,
                order: .latest,
                continuation: .complete,
                reportedIncomplete: nil,
                hasPagingMetadata: false
            )
            return
        }

        guard let paging = paginationValue.objectValue else {
            throw Self.protocolError("stored transcript pagination was malformed")
        }
        let echoedLimit = try Self.requiredNonnegativeInteger(paging["limit"], field: "limit")
        let echoedOffset = try Self.requiredNonnegativeInteger(paging["offset"], field: "offset")
        let echoedReturned = try Self.requiredNonnegativeInteger(paging["returned"], field: "returned")
        guard echoedLimit <= StoredTranscriptPageRequest.maximumLimit,
              echoedOffset <= StoredTranscriptPageRequest.maximumOffset,
              echoedReturned == rows.count,
              echoedReturned <= echoedLimit else {
            throw Self.protocolError("stored transcript pagination conflicted with rows")
        }
        guard let orderString = paging["order"]?.stringValue,
              let echoedOrder = Order(rawValue: orderString) else {
            throw Self.protocolError("stored transcript pagination had invalid order")
        }
        guard echoedLimit == request.limit,
              echoedOffset == request.offset,
              echoedOrder == .latest else {
            throw Self.protocolError("stored transcript pagination changed request")
        }

        if let compacted = paging["include_compacted"] {
            guard let echoedCompacted = compacted.boolValue,
                  echoedCompacted == request.includeCompacted else {
                throw Self.protocolError("stored transcript pagination changed compacted policy")
            }
        }

        let total = try Self.optionalNonnegativeInteger(paging["total"], field: "total")
        let explicitHasMore = try Self.optionalBoolean(paging["has_more"], field: "has_more")
        let reportedIncomplete = try Self.optionalBoolean(paging["incomplete"], field: "incomplete")
        let (end, endOverflow) = echoedOffset.addingReportingOverflow(echoedReturned)
        guard !endOverflow else {
            throw Self.protocolError("stored transcript pagination overflowed")
        }

        let totalContinuation: Bool?
        if let total {
            guard total >= end else {
                throw Self.protocolError("stored transcript total preceded page")
            }
            // A non-empty display set cannot yield an empty in-range page.
            guard !(echoedReturned == 0 && echoedOffset < total) else {
                throw Self.protocolError("stored transcript total conflicted with empty page")
            }
            totalContinuation = end < total
        } else {
            totalContinuation = nil
        }

        if let explicitHasMore, let totalContinuation,
           explicitHasMore != totalContinuation {
            throw Self.protocolError("stored transcript has_more conflicted with total")
        }
        // Hermes fills a contiguous page before reporting more rows. A short
        // page paired with `has_more: true` would otherwise invite an infinite
        // page loop over a malformed peer.
        if explicitHasMore == true && echoedReturned < echoedLimit {
            throw Self.protocolError("stored transcript has_more conflicted with short page")
        }
        if let totalContinuation, totalContinuation, echoedReturned < echoedLimit {
            throw Self.protocolError("stored transcript total conflicted with short page")
        }

        let continuation: Continuation
        if let explicitHasMore = explicitHasMore ?? totalContinuation {
            continuation = explicitHasMore ? .more : .complete
        } else if echoedReturned < echoedLimit {
            // The current route returns a short final page even before it grows
            // `total`/`has_more`; this is enough to prove the older direction
            // is exhausted.
            continuation = .complete
        } else {
            // A full page can be the end exactly at the requested limit. Do
            // not turn that possibility into a false positive continuation.
            continuation = .unknown
        }

        pagination = Pagination(
            offset: echoedOffset,
            limit: echoedLimit,
            returned: echoedReturned,
            total: total,
            order: echoedOrder,
            continuation: continuation,
            reportedIncomplete: reportedIncomplete,
            hasPagingMetadata: true
        )
    }

    static func protocolError(_ message: String) -> GatewayError {
        GatewayError(code: -8, message: "stored transcript page: \(message)")
    }

    private static func requiredNonnegativeInteger(_ value: JSONValue?, field: String) throws -> Int {
        guard let value else {
            throw protocolError("stored transcript pagination omitted \(field)")
        }
        guard let number = value.doubleValue,
              number.isFinite,
              number >= 0,
              let integer = Int(exactly: number) else {
            throw protocolError("stored transcript pagination had invalid \(field)")
        }
        return integer
    }

    private static func optionalNonnegativeInteger(_ value: JSONValue?, field: String) throws -> Int? {
        guard let value else { return nil }
        return try requiredNonnegativeInteger(value, field: field)
    }

    private static func optionalBoolean(_ value: JSONValue?, field: String) throws -> Bool? {
        guard let value else { return nil }
        guard let boolean = value.boolValue else {
            throw protocolError("stored transcript pagination had invalid \(field)")
        }
        return boolean
    }
}
