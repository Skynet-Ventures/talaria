import Foundation

/// How Talaria opens a conversation. The gateway can project a full
/// transcript inside `session.resume`, but that is the wrong first-paint
/// contract for a phone: a long forever-chat blocks the UI on one WS frame.
///
/// Open-chat therefore:
/// 1. resumes with `defer_history` so the bind is just identity + inflight;
/// 2. paints any in-memory rows immediately;
/// 3. hydrates the newest REST page (`order=latest`);
/// 4. treats that page as a window, not the whole history.
///
/// Mutation / kickoff proof paths keep a full resume; they are not this policy.
public enum OpenChatHistoryPolicy {
    public static let firstPageLimit = 200

    public static var resumeDefersHistory: Bool { true }

    public static func resumeSessionParams(_ storedID: String, profile: String? = nil,
                                           deferHistory: Bool) -> JSONValue {
        var params: [String: JSONValue] = [
            "session_id": .string(storedID),
            "source": "talaria",
        ]
        if let profile { params["profile"] = .string(profile) }
        if deferHistory { params["defer_history"] = .bool(true) }
        return .object(params)
    }

    /// `defer_history` asks the gateway for identity + inflight only. Mini
    /// still dumped a 584-message / ~360k-token forever-chat onto the WS
    /// (`ws write slow >10s`). That payload is not first paint — drop it and
    /// use the REST latest page.
    public static func openChatResumeMessages(_ messages: [JSONValue],
                                              historyDeferred: Bool) -> [JSONValue] {
        historyDeferred ? [] : messages
    }

    public static func latestMessagesQuery(profile: String?,
                                           limit: Int = firstPageLimit,
                                           offset: Int = 0) -> [URLQueryItem] {
        var query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "order", value: "latest"),
            URLQueryItem(name: "include_compacted", value: "true"),
        ]
        if offset > 0 {
            query.append(URLQueryItem(name: "offset", value: String(offset)))
        }
        if let profile, !profile.isEmpty {
            query.insert(URLQueryItem(name: "profile", value: profile), at: 0)
        }
        return query
    }

    /// A deferred resume stub is never the full conversation, even when it
    /// already contains a few rows. Only an empty non-deferred ack skips the
    /// latest-page read (legacy full-projection callers).
    public static func needsLatestPage(historyDeferred: Bool,
                                       resumeMessageCount: Int) -> Bool {
        historyDeferred || resumeMessageCount == 0
    }

    public enum HistorySource: Equatable, Sendable {
        case resumeProjection
        case latestPage
    }

    /// An older gateway that ignored `defer_history` may return more rows
    /// than the REST window. Keep the larger projection rather than
    /// truncating a chat the phone already paid to download.
    public static func authoritativeSource(resumeCount: Int,
                                           pageCount: Int) -> HistorySource {
        resumeCount > pageCount ? .resumeProjection : .latestPage
    }

    public static func hasOlderMessages(pageCount: Int, limit: Int,
                                        source: HistorySource) -> Bool {
        source == .latestPage && pageCount >= limit
    }

    /// Durable key we can address REST with before `session.resume` returns.
    /// A title-only target has to wait for the ack; using "Bot Chat" as a
    /// path segment would 404.
    public static func attachRestTarget(_ target: String, durableID: String?,
                                        canonicalTitle: String) -> String? {
        if let durableID {
            let trimmed = durableID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == canonicalTitle { return nil }
        return trimmed
    }

    /// Root id, resume tip, and the bound stored key are the same conversation.
    public static func sameBinding(_ stored: String?, target: String,
                                   durableID: String?) -> Bool {
        guard let stored, !stored.isEmpty else { return false }
        if stored == target { return true }
        if let durableID, stored == durableID { return true }
        return false
    }

    /// Rows that appeared or changed after the deferred stub was painted.
    /// Unchanged stub rows are first-paint placeholders and must not ride
    /// through as optimistic sends when the REST page arrives.
    public static func rowsNewerThanStub(current: [ChatMessage],
                                         stubSnapshot: [ChatMessage]) -> [ChatMessage] {
        let painted = Dictionary(uniqueKeysWithValues: stubSnapshot.map { ($0.id, $0) })
        return current.filter { message in
            guard let original = painted[message.id] else { return true }
            return original != message
        }
    }

    /// A REST prefetch started for one binding must not paint another.
    public static func acceptsPrefetchedPage(currentStoredID: String?,
                                             expectedStoredID: String?) -> Bool {
        guard let expected = expectedStoredID?
            .trimmingCharacters(in: .whitespacesAndNewlines), !expected.isEmpty
        else { return true }
        let current = currentStoredID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return current.isEmpty || current == expected
    }

    /// Older pages arrive oldest-first after `chatMessages` normalization.
    /// Drop rows the visible transcript already owns by durable id.
    public static func prepend(existing: [ChatMessage],
                               older: [ChatMessage]) -> [ChatMessage] {
        let existingRowIDs = Set(existing.compactMap(\.rowID))
        let unique = older.filter { message in
            guard let rowID = message.rowID else { return true }
            return !existingRowIDs.contains(rowID)
        }
        return unique + existing
    }
}
