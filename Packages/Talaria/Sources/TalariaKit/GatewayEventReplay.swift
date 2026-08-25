import Foundation

/// Why a reconnect could not prove a gap-free event history. Talaria still
/// refreshes authoritative snapshots, but it must tell the user that replay
/// itself was not complete rather than silently presenting stale state.
public enum GatewayReplayIssue: String, Sendable, Equatable, Hashable {
    case sourceRestarted
    case unsupportedGateway
    case requestFailed
    case malformedResponse
    case truncated
    case bounded
}

public enum GatewayReplayCertainty: Sendable, Equatable {
    /// Every requested session returned a contiguous, same-epoch suffix.
    case complete
    /// No prior sequenced session existed, so there was no gap to recover.
    case notNeeded
    /// Replay was unavailable or incomplete. Snapshot reconciliation is
    /// required and the UI must not claim the missed interval was recovered.
    case uncertain(Set<GatewayReplayIssue>)

    public var isCertain: Bool {
        switch self {
        case .complete, .notNeeded: return true
        case .uncertain: return false
        }
    }
}

/// Bounded replay prepared while live delivery from the replacement socket is
/// parked. AppModel applies these events before resume/list snapshots and then
/// commits the token, which releases overlapping live frames through the same
/// sequence gate.
public struct GatewayReplayPublication: Sendable {
    public let token: UUID
    public let events: [GatewayEvent]
    public let certainty: GatewayReplayCertainty
    public let sourceEpoch: String?
    public let requestedSessionCount: Int
    public let eventAuthorityEpoch: UInt64

    public init(token: UUID = UUID(), events: [GatewayEvent],
                certainty: GatewayReplayCertainty, sourceEpoch: String?,
                requestedSessionCount: Int, eventAuthorityEpoch: UInt64 = 0) {
        self.token = token
        self.events = events
        self.certainty = certainty
        self.sourceEpoch = sourceEpoch
        self.requestedSessionCount = requestedSessionCount
        self.eventAuthorityEpoch = eventAuthorityEpoch
    }
}

/// Bounded operational telemetry returned by `session.events.stats`.
public struct GatewayReplayStats: Sendable, Equatable {
    public let sessions: UInt64
    public let events: UInt64
    public let maximumPerSession: UInt64

    static func decode(_ value: JSONValue) -> GatewayReplayStats? {
        guard let sessions = GatewayReplayCodec.exactNonnegativeInteger(value["sessions"]),
              let events = GatewayReplayCodec.exactNonnegativeInteger(value["events"]),
              let maximum = GatewayReplayCodec.exactNonnegativeInteger(
                value["max_per_session"]),
              sessions <= 64, maximum <= 4_096,
              events <= sessions * maximum else { return nil }
        return GatewayReplayStats(
            sessions: sessions, events: events,
            maximumPerSession: maximum)
    }
}

struct GatewayReplayDecodedPage: Sendable {
    var events: [GatewayEvent]
    var latestSequence: UInt64
    var issue: GatewayReplayIssue?
}

enum GatewayReplayEpochDisposition: Sendable, Equatable {
    case noGap
    case replay(String)
    case restarted(String)
    case unsupported
}

enum GatewayReplayCodec {
    static let maximumSafeJSONInteger: Double = 9_007_199_254_740_991
    static let maximumSessions = 32
    static let maximumEventsPerSession = 512
    static let maximumTotalEvents = 2_048
    static let requestTimeout: TimeInterval = 5

    static func epochDisposition(previous: String?, current: String?,
                                 hasWatermarks: Bool) -> GatewayReplayEpochDisposition {
        guard hasWatermarks else { return .noGap }
        guard let current else { return .unsupported }
        guard previous == current else { return .restarted(current) }
        return .replay(current)
    }

    /// Strictly decode one `session.events.since` result. A present malformed
    /// field is never treated like an old gateway omission. Events must be
    /// bare dispatch objects, belong to the requested session, and retain
    /// exact increasing wire order.
    static func decode(_ value: JSONValue, sessionID: String, lastSeen: UInt64,
                       expectedEpoch: String) -> GatewayReplayDecodedPage? {
        guard let object = value.objectValue,
              let rawEvents = object["events"]?.arrayValue,
              rawEvents.count <= maximumEventsPerSession,
              let latest = exactNonnegativeInteger(object["latest_seq"]),
              let count = exactNonnegativeInteger(object["count"]),
              count == UInt64(rawEvents.count),
              let truncated = object["truncated"]?.boolValue,
              object["epoch"]?.stringValue == expectedEpoch else { return nil }

        var decoded: [GatewayEvent] = []
        decoded.reserveCapacity(rawEvents.count)
        var prior = lastSeen
        for raw in rawEvents {
            guard let row = raw.objectValue,
                  row["jsonrpc"] == nil, row["method"] == nil, row["params"] == nil,
                  let type = row["type"]?.stringValue, !type.isEmpty,
                  row["session_id"]?.stringValue == sessionID,
                  let sequence = exactPositiveInteger(row["seq"]),
                  sequence > prior else { return nil }
            // A non-truncated answer is a proof of a complete suffix, so any
            // hole is a malformed claim. A truncated page may start after the
            // requested cursor but must remain contiguous inside the page.
            if (!truncated || prior != lastSeen), sequence != prior + 1 { return nil }
            decoded.append(GatewayEvent(
                type: type, sessionID: sessionID, payload: row["payload"],
                sequence: sequence))
            prior = sequence
        }

        guard latest >= lastSeen, latest >= prior else { return nil }
        // The server's latest cursor and returned suffix must agree. An empty
        // unchanged answer is valid; an empty reset or hidden tail is not.
        guard (decoded.isEmpty && latest == lastSeen)
                || (!decoded.isEmpty && latest == prior) else { return nil }
        return GatewayReplayDecodedPage(
            events: decoded, latestSequence: latest,
            issue: truncated ? .truncated : nil)
    }

    static func exactPositiveInteger(_ value: JSONValue?) -> UInt64? {
        guard let integer = exactNonnegativeInteger(value), integer > 0 else { return nil }
        return integer
    }

    static func exactNonnegativeInteger(_ value: JSONValue?) -> UInt64? {
        guard let number = value?.doubleValue, number.isFinite, number >= 0,
              number.rounded(.towardZero) == number,
              number <= maximumSafeJSONInteger else { return nil }
        return UInt64(number)
    }
}
