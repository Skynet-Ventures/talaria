import Foundation
import TalariaKit

// Session management beyond the create/resume/list wrappers in TalariaKit:
// the row actions (rename, delete), the turn controls (branch, compress,
// save) and cross-session full-text search.
//
// Two transports, deliberately — this is not a style choice:
// - WS RPCs resolve their `session_id` against the gateway's live `_sessions`
//   table (server.py:_sess_nowait / _sess), so session.title, session.branch,
//   session.compress and session.save only work on a session THIS process has
//   resumed; anything else answers 4001. They take the RUNTIME sid.
// - REST (hermes_cli/web_routers/sessions.py) reads the profile's state.db
//   directly off the DURABLE key, so renaming or searching a session nobody
//   has resumed has to go over HTTP.
//
// Shapes verified against .research/ws-protocol.md §7.4 and the upstream
// sources referenced above.

// MARK: - Result types

/// One cross-session search result (GET /api/sessions/search).
public struct SessionSearchHit: Identifiable, Sendable, Equatable {
    /// Unique across the merged multi-profile result set.
    public var id: String { botID + "/" + sessionID }
    /// Durable session key, already resolved to the compression-lineage tip
    /// upstream — hand it straight to session.resume.
    public var sessionID: String
    /// Owning profile. The index is per-profile (each bot has its own
    /// state.db), so this is the profile the hit was fetched for, not a
    /// field on the wire.
    public var botID: String
    public var title: String
    /// FTS excerpt around the match, or the session preview for an id match.
    public var snippet: String
    /// Display stamp ("today 08:31", "Mon 09:12").
    public var when: String
    /// Unix seconds; the sort key when hits from several profiles merge.
    public var lastActive: Double

    public init(sessionID: String, botID: String, title: String, snippet: String,
                when: String, lastActive: Double) {
        self.sessionID = sessionID; self.botID = botID; self.title = title
        self.snippet = snippet; self.when = when; self.lastActive = lastActive
    }
}

/// session.compress result, normalized across the gateway's successful,
/// lock-held, and fail-closed checkpoint-prerequisite shapes.
public struct SessionCompression: Sendable {
    public enum Outcome: String, Sendable {
        case compressed, aborted, skipped, blocked
    }

    public var outcome: Outcome
    /// Upstream's own headline ("Compressed: 84 → 12 messages").
    public var headline: String
    /// "Approx request size: ~48,120 → ~9,400 tokens".
    public var tokenLine: String
    public var note: String?
    public var beforeMessages: Int
    public var afterMessages: Int
    public var beforeTokens: Int
    public var afterTokens: Int
    public var removed: Int
    /// Post-compression transcript projection, same shape as session.resume —
    /// desktop replaces the transcript with it.
    public var messages: [JSONValue]

    init(_ v: JSONValue) {
        messages = v["messages"]?.arrayValue ?? []
        beforeMessages = v["before_messages"]?.intValue ?? 0
        afterMessages = v["after_messages"]?.intValue ?? 0
        beforeTokens = v["before_tokens"]?.intValue ?? 0
        afterTokens = v["after_tokens"]?.intValue ?? 0
        removed = v["removed"]?.intValue ?? 0

        let status = v["status"]?.stringValue
        let message = v["message"]?.stringValue
        if CompressionCheckpointFailurePolicy.isBlockedPrerequisite(status)
            || CompressionCheckpointFailurePolicy.isBlockedPrerequisite(message) {
            outcome = .blocked
            headline = message ?? "Compression is blocked until a durable checkpoint is available."
            tokenLine = ""
            note = v["detail"]?.stringValue
            return
        }

        // A held compression lock is a no-op, not a failure: auto-compaction
        // is already doing the work.
        if v["lock_held"]?.boolValue == true || v["compressed"]?.boolValue == false {
            outcome = .skipped
            headline = v["message"]?.stringValue ?? "Compression is already running."
            tokenLine = ""
            note = nil
            return
        }

        let summary = v["summary"]
        outcome = Outcome(rawValue: status ?? "compressed") ?? .compressed
        headline = message ?? summary?["headline"]?.stringValue
            ?? "\(beforeMessages) → \(afterMessages) messages"
        tokenLine = summary?["token_line"]?.stringValue
            ?? (beforeTokens > 0 ? "~\(beforeTokens) → ~\(afterTokens) tokens" : "")
        note = summary?["note"]?.stringValue
    }
}

/// session.branch result — the fork, already persisted with the parent's
/// lineage marker.
public struct SessionBranch: Sendable {
    /// Runtime sid of the fork (bound to this transport).
    public var sessionID: String
    /// Durable key; what the session list and resume use.
    public var storedSessionID: String
    public var title: String
    public var parent: String
    public var messageCount: Int

    init(_ v: JSONValue) {
        sessionID = v["session_id"]?.stringValue ?? ""
        storedSessionID = v["stored_session_id"]?.stringValue ?? ""
        title = v["title"]?.stringValue ?? ""
        parent = v["parent"]?.stringValue ?? ""
        messageCount = v["message_count"]?.doubleValue.flatMap(Int.init(exactly:)) ?? -1
    }
}

/// The success envelope is the only proof that `session.branch` produced the
/// child Talaria asked for. A malformed/wrong-parent/count response is an
/// ambiguous mutation outcome: never open it and never replay the write.
enum SessionBranchAckAuthority {
    static func requireExact(_ branch: SessionBranch,
                             parentRuntimeSessionID: String,
                             parentStoredSessionID: String,
                             requestedCount: Int) throws {
        let trim = CharacterSet.whitespacesAndNewlines
        guard requestedCount > 0,
              !branch.sessionID.isEmpty,
              branch.sessionID == branch.sessionID.trimmingCharacters(in: trim),
              !branch.storedSessionID.isEmpty,
              branch.storedSessionID
                == branch.storedSessionID.trimmingCharacters(in: trim) else {
            throw AckValidationError(
                operation: "Branch session",
                detail: "Hermes returned no usable child session identity.")
        }
        guard branch.sessionID != parentRuntimeSessionID,
              branch.storedSessionID != parentStoredSessionID else {
            throw AckValidationError(
                operation: "Branch session",
                detail: "Hermes returned the parent as the branch child.")
        }
        guard branch.parent == parentStoredSessionID else {
            throw AckValidationError(
                operation: "Branch session",
                detail: "Hermes returned a different parent session identity.")
        }
        guard branch.messageCount == requestedCount else {
            throw AckValidationError(
                operation: "Branch session",
                detail: "Hermes returned a different branch message count.")
        }
    }
}

// MARK: - Session timestamps

/// Session stamps in the design's session-row voice: "today 08:31",
/// "yest 08:52", "Mon 09:12", "12 Mar". Shared by the sheet, the search hits
/// and the bot sheet so every session row reads the same.
enum SessionClock {
    static func stamp(_ unix: Double?) -> String {
        guard let unix, unix > 0 else { return "new" }
        let date = Date(timeIntervalSince1970: unix)
        let calendar = Calendar.current
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        if calendar.isDateInToday(date) { return "today " + clock.string(from: date) }
        if calendar.isDateInYesterday(date) { return "yest " + clock.string(from: date) }
        let now = Date()
        if let week = calendar.date(byAdding: .day, value: -7, to: now), date > week {
            let day = DateFormatter()
            day.dateFormat = "EEE"
            return day.string(from: date) + " " + clock.string(from: date)
        }
        let old = DateFormatter()
        old.dateFormat = "d MMM"
        return old.string(from: date)
    }
}

// MARK: - RPCs

extension GatewayClient {

    // MARK: Row actions

    /// Delete a stored session and its transcript files. Answers **4023**
    /// when the session is still live in the gateway process — deleting rows
    /// out from under a running agent corrupts message ordering, so upstream
    /// refuses and the caller must surface that.
    public func deleteSession(_ storedID: String, profile: String? = nil) async throws {
        var params: [String: JSONValue] = ["session_id": .string(storedID)]
        if let profile { params["profile"] = .string(profile) }
        try await rpc("session.delete", .object(params))
    }

    /// Rename a LIVE session (session.title set). Returns the title the
    /// gateway settled on — it re-emits session.info, so the strip resyncs.
    /// Use `renameStoredSession` for a session that is not resumed.
    @discardableResult
    public func setSessionTitle(sessionID: String, title: String) async throws -> String {
        let result = try await rpc("session.title", ["session_id": .string(sessionID),
                                                     "title": .string(title)])
        return result["title"]?.stringValue ?? title
    }

    // MARK: Turn controls

    /// Fork the conversation. The child carries `parent_session_id` lineage
    /// and a `_branched_from` marker so it stays visible in every session
    /// list. Errors **4008** when the session has nothing to fork yet.
    public func branchSession(_ sessionID: String, name: String? = nil,
                              count: Int? = nil) async throws -> SessionBranch {
        var params: [String: JSONValue] = ["session_id": .string(sessionID)]
        if let name, !name.isEmpty { params["name"] = .string(name) }
        if let count, count > 0 { params["count"] = .number(Double(count)) }
        return SessionBranch(try await rpc("session.branch", .object(params), timeout: 300))
    }

    /// Manual compaction. Errors **4009** while a turn is running — upstream
    /// requires an interrupt first. Summarization is a model call, so this
    /// can legitimately take minutes.
    public func compressSession(_ sessionID: String,
                                focusTopic: String? = nil) async throws -> SessionCompression {
        var params: [String: JSONValue] = ["session_id": .string(sessionID)]
        if let focusTopic, !focusTopic.isEmpty { params["focus_topic"] = .string(focusTopic) }
        return SessionCompression(try await rpc("session.compress", .object(params), timeout: 600))
    }

    /// Server-side JSON snapshot under `~/.hermes/sessions/saved/` on the
    /// GATEWAY host. Returns that path.
    public func saveSession(_ sessionID: String) async throws -> String {
        let result = try await rpc("session.save", ["session_id": .string(sessionID)], timeout: 300)
        return result["file"]?.stringValue ?? result["path"]?.stringValue ?? ""
    }

    // MARK: - REST (durable-key surfaces)

    /// Rename a stored session that is not live (PATCH /api/sessions/{id}).
    /// The WS session.title RPC only resolves runtime sids, so this is the
    /// only path that works for a row the user never opened.
    @discardableResult
    public func renameStoredSession(_ storedID: String, title: String,
                                    profile: String? = nil) async throws -> String {
        let url = baseURL.appending(path: "api/sessions/\(storedID)")
        var req = authedRequest(url, method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: JSONValue] = ["title": .string(title)]
        if let profile { body["profile"] = .string(profile) }
        req.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        let payload = try await send(req, describing: "rename")
        return payload["title"]?.stringValue ?? title
    }

    /// Cross-session full-text search for ONE profile
    /// (GET /api/sessions/search). Each profile owns its own state.db, so a
    /// roster-wide search is a fan-out over this call.
    public func searchSessions(query: String, profile: String? = nil,
                               limit: Int = 8) async throws -> [SessionSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var comps = URLComponents(url: baseURL.appending(path: "api/sessions/search"),
                                  resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "q", value: trimmed),
                     URLQueryItem(name: "limit", value: String(limit))]
        if let profile, !profile.isEmpty {
            items.append(URLQueryItem(name: "profile", value: profile))
        }
        comps?.queryItems = items
        guard let url = comps?.url else { return [] }
        let payload = try await send(authedRequest(url, method: "GET"), describing: "search")
        return (payload["results"]?.arrayValue ?? []).compactMap { row in
            guard let id = row["session_id"]?.stringValue ?? row["id"]?.stringValue,
                  !id.isEmpty else { return nil }
            let stamp = row["last_active"]?.doubleValue
                ?? row["started_at"]?.doubleValue
                ?? row["session_started"]?.doubleValue
            let title = row["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                ?? Self.fallbackTitle(id: id, preview: row["preview"]?.stringValue)
            return SessionSearchHit(
                sessionID: id,
                botID: profile ?? "",
                title: title,
                snippet: Self.cleanSnippet(row["snippet"]?.stringValue
                    ?? row["preview"]?.stringValue ?? ""),
                when: SessionClock.stamp(stamp),
                lastActive: stamp ?? 0)
        }
    }

    /// An untitled session shows the first line of its transcript, like the
    /// desktop sidebar; a session with neither gets its key.
    static func fallbackTitle(id: String, preview: String?) -> String {
        let line = (preview ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if line.isEmpty { return "Session " + id.prefix(8) }
        return line.count > 64 ? String(line.prefix(63)) + "…" : line
    }

    /// FTS snippets arrive wrapped in SQLite highlight markers
    /// (`snippet(…, '>>>', '<<<', '...', 40)`, hermes_state_search.py:1392).
    /// A phone row has no room for highlighting, so drop the markers and
    /// flatten the whitespace.
    static func cleanSnippet(_ raw: String) -> String {
        raw.replacingOccurrences(of: ">>>", with: "")
            .replacingOccurrences(of: "<<<", with: "")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    // MARK: REST plumbing

    /// Attach this gateway's REST credential. `GatewayClient`'s own copy is
    /// file-private in TalariaKit, so read the Keychain record `connect()`
    /// writes refreshed OAuth tokens back into — one store, always current.
    private func authedRequest(_ url: URL, method: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let credential = KeychainStore().load(for: baseURL) {
            GatewayAuthClient(baseURL: baseURL).apply(credential: credential, to: &req)
        }
        return req
    }

    /// Run a REST request and decode it, mapping HTTP failures onto
    /// `GatewayError` so callers handle one error type.
    private func send(_ request: URLRequest, describing what: String) async throws -> JSONValue {
        let lease = try await acquireTrafficLease()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let payload = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
            guard (200..<300).contains(code) else {
                let detail = payload["detail"]?.stringValue ?? payload["error"]?.stringValue
                throw GatewayError(code: code,
                                   message: detail ?? "\(what) failed (HTTP \(code))")
            }
            await lease?.release()
            return payload
        } catch {
            await lease?.release()
            throw error
        }
    }
}
