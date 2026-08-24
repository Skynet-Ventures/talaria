import Foundation

// MARK: - Stored transcript REST paging

extension GatewayClient {
    /// Read one exact reverse page from a durable transcript.
    ///
    /// Hermes resolves `storedSessionID` through compression lineage before it
    /// reads, then echoes the resolved tip as `session_id`. The request keeps
    /// the durable/root id while `StoredTranscriptPage` preserves both values;
    /// callers must never replace a stored binding with that transient tip.
    ///
    /// The transport is intentionally bounded before JSON decoding. A normal
    /// Hermes endpoint is capped at 500 rows, but row bodies are untrusted and
    /// can contain tool output, so row-count validation alone is not enough.
    public func storedTranscriptPage(_ request: StoredTranscriptPageRequest) async throws
        -> StoredTranscriptPage {
        guard request.hasUsableStoredSessionID else {
            throw GatewayError(code: -11, message: "Stored transcript request has no usable session id.")
        }
        let component = try Self.storedTranscriptPathComponent(request.storedSessionID)
        var query: [URLQueryItem] = []
        if let profile = request.profile, !profile.isEmpty {
            query.append(URLQueryItem(name: "profile", value: profile))
        }
        query.append(contentsOf: [
            URLQueryItem(name: "limit", value: String(request.limit)),
            URLQueryItem(name: "offset", value: String(request.offset)),
            URLQueryItem(name: "order", value: StoredTranscriptPage.Order.latest.rawValue),
            URLQueryItem(name: "include_compacted", value: request.includeCompacted ? "true" : "false"),
        ])

        let data = try await restDataBounded(
            path: "api/sessions/\(component)/messages",
            query: query,
            timeout: 25,
            maximumResponseBytes: StoredTranscriptPage.maximumResponseBytes
        )
        // `restDataBounded` enforces this in production as bytes arrive. Keep
        // the check here as well so a package-test executor cannot accidentally
        // make the production page decoder accept an oversize body.
        guard data.count <= StoredTranscriptPage.maximumResponseBytes else {
            throw StoredTranscriptPage.protocolError("stored transcript response exceeded byte cap")
        }
        let payload: JSONValue
        do {
            payload = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw StoredTranscriptPage.protocolError("stored transcript response was not JSON")
        }
        return try Self.decodeStoredTranscriptPage(payload, request: request)
    }

    /// Convenience overload for callers that have not yet captured a
    /// gateway/profile/stored-session source tuple. New long-lived UI work
    /// should prefer the request initializer taking `StoredTranscriptPageSource`.
    public func storedTranscriptPage(storedSessionID: String, profile: String? = nil,
                                     offset: Int = 0,
                                     limit: Int = StoredTranscriptPageRequest.defaultLimit,
                                     includeCompacted: Bool = true) async throws
        -> StoredTranscriptPage {
        try await storedTranscriptPage(
            StoredTranscriptPageRequest(
                storedSessionID: storedSessionID,
                profile: profile,
                offset: offset,
                limit: limit,
                includeCompacted: includeCompacted
            )
        )
    }

    /// Kept transport-free for focused protocol tests and callers that have
    /// already captured authenticated response bytes through a stronger
    /// boundary. It validates the exact request echo before returning rows.
    static func decodeStoredTranscriptPage(_ payload: JSONValue,
                                            request: StoredTranscriptPageRequest) throws
        -> StoredTranscriptPage {
        try StoredTranscriptPage(payload: payload, request: request)
    }

    private static func storedTranscriptPathComponent(_ raw: String) throws -> String {
        // `URL.appending(path:)` escapes opaque characters itself, but a slash
        // would become an extra path component and dot segments are subject to
        // proxy normalization. Reject only those path-changing forms (plus
        // controls), so opaque legacy ids are not needlessly narrowed.
        guard StoredTranscriptIdentityPolicy.admits(raw, pathComponent: true) else {
            throw GatewayError(code: -11, message: "Stored transcript request has an invalid session id.")
        }
        return raw
    }
}
