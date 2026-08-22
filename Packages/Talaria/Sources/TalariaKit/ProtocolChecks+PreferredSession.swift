import Foundation

// Dual-generation canonical Bot Chat registry checks pinned to Hermes
// a4f16e3f. Current profiles.list returns canonical_session on every row when
// include_sessions is true. Older gateways may return preferred_session or
// omit both. A present current field always wins, including null/malformed.
extension ProtocolChecks {

    static func canonicalSessionParsing() throws {
        let current = HermesProfile(try decodeCanonicalJSON("""
        {"name":"default",
         "last_session":{"id":"scratch","title":"Scratch","preview":"newer activity",
                         "last_active":200,"message_count":2},
         "canonical_session":{"id":"root","resolved_id":"tip","root_title":"Bot Chat",
                              "title":"Bot Chat (continued)","preview":"canonical preview",
                              "last_active":190,"message_count":12},
         "preferred_session":{"id":"legacy-wrong","title":"Bot Chat","message_count":1}}
        """))
        guard case .resolved(let canonical) = current.canonicalSession else {
            throw CheckFailure(description: "FAILED: canonical_session must resolve")
        }
        try expect(canonical.id == "root" && canonical.resolvedID == "tip",
                   "canonical registry root and compression tip are retained")
        try expect(current.preferredSession.session?.id == "root",
                   "compatibility projection exposes canonical, not conflicting preferred")
        try expect(current.previewSession?.preview == "canonical preview",
                   "canonical identity owns preview over unrelated recent activity")
        try expect(current.freshestConversationSession?.id == "scratch",
                   "conversation activity remains independent from canonical preview")

        let absent = HermesProfile(try decodeCanonicalJSON("""
        {"name":"old","last_session":{"id":"last","title":"Last","message_count":1}}
        """))
        try expect(absent.canonicalSession.isOmitted,
                   "missing canonical and preferred fields remain inconclusive")
        try expect(absent.previewSession?.id == "last", "absent registry falls back to last_session")

        let legacy = HermesProfile(try decodeCanonicalJSON("""
        {"name":"legacy","preferred_session":{"id":"old-root","resolved_id":"old-tip",
          "title":"Drifted historical title","message_count":4}}
        """))
        try expect(legacy.canonicalSession.session?.id == "old-root"
                    && legacy.canonicalSession.session?.resolvedID == "old-tip",
                   "older requested-pin preferred_session retains its separate compatibility policy")

        let currentNull = HermesProfile(try decodeCanonicalJSON("""
        {"name":"gone","canonical_session":null,
         "preferred_session":{"id":"must-not-win","title":"Bot Chat","message_count":9}}
        """))
        try expect(currentNull.canonicalSession.isDefinitivelyGone,
                   "current explicit null overrides a legacy resolved pointer")

        let malformedCurrent = HermesProfile(try decodeCanonicalJSON("""
        {"name":"malformed","canonical_session":{"title":"Bot Chat"},
         "preferred_session":{"id":"must-not-win","title":"Bot Chat","message_count":9}}
        """))
        try expect(malformedCurrent.canonicalSession.isMalformed
                    && !malformedCurrent.canonicalSession.isOmitted
                    && malformedCurrent.canonicalSession.session == nil,
                   "malformed present canonical is quarantined and never falls back")
        try expect(malformedCurrent.previewSession == nil,
                   "malformed canonical cannot borrow unrelated last_session preview")

        let emptyID = HermesProfile(try decodeCanonicalJSON("""
        {"name":"empty","last_session":{"id":"scratch","title":"Scratch"},
         "canonical_session":{"id":"","title":"Bot Chat"},
         "preferred_session":{"id":"must-not-win","title":"Bot Chat"}}
        """))
        try expect(emptyID.canonicalSession.isMalformed
                    && emptyID.canonicalSession.session == nil
                    && emptyID.previewSession == nil,
                   "empty canonical id is invalid and current presence still blocks legacy fallback")

        for malformedEvidence in [
            """
            {"name":"wrong-root","last_session":{"id":"scratch","title":"Scratch"},
             "canonical_session":{"id":"candidate","root_title":"Other","title":"Bot Chat"}}
            """,
            """
            {"name":"wrong-leaf","last_session":{"id":"scratch","title":"Scratch"},
             "canonical_session":{"id":"candidate","title":"Other"}}
            """,
        ] {
            let profile = HermesProfile(try decodeCanonicalJSON(malformedEvidence))
            try expect(profile.canonicalSession.isMalformed
                        && profile.canonicalSession.session == nil
                        && profile.previewSession == nil,
                       "current canonical rows require exact Bot Chat lineage evidence")
        }

        guard case .object(let profileParams) = GatewayClient.profileListParams(
            includeSessions: true) else {
            throw CheckFailure(description: "FAILED: profiles.list params must be an object")
        }
        try expect(profileParams == ["include_sessions": .bool(true)],
                   "current profiles.list emits no preferred_session_ids")

        guard case .object(let exactParams) = GatewayClient.exactSessionListParams(
            profile: "research", title: "Bot Chat") else {
            throw CheckFailure(description: "FAILED: exact session.list params must be an object")
        }
        try expect(exactParams == [
            "profile": .string("research"), "title": .string("Bot Chat"),
            "include_hidden": .bool(true),
        ], "exact title lookup is profile-scoped and includes owned hidden rows")
        try expect(GatewayClient.sessionTitleParams(
            runtimeID: "runtime-1", title: "Bot Chat") == [
                "session_id": .string("runtime-1"), "title": .string("Bot Chat"),
            ], "session.title uses the live runtime id and exact canonical title")
        let titleReceipt = try GatewayClient.decodeSessionTitleReceipt([
            "title": .string("Bot Chat"), "pending": .bool(false),
        ])
        try expect(titleReceipt == SessionTitleReceipt(title: "Bot Chat", pending: false),
                   "session.title receipt retains exact title ownership fields")
        for malformed: JSONValue in [
            .object([:]),
            .null,
            ["title": .number(1), "pending": .bool(false)],
            ["title": .string("Bot Chat"), "pending": .string("false")],
        ] {
            do {
                _ = try GatewayClient.decodeSessionTitleReceipt(malformed)
                throw CheckFailure(description:
                    "FAILED: malformed session.title receipt must fail closed")
            } catch let error as GatewayError {
                try expect(error.code == -8,
                           "malformed session.title receipt remains a typed protocol failure")
            }
        }

        let exact = StoredSession(try decodeCanonicalJSON("""
        {"id":"root","resolved_id":"tip","root_title":"Bot Chat",
         "title":"Bot Chat (continued)","last_active":123,"message_count":7}
        """))
        try expect(exact.resumeID == "tip" && exact.rootTitle == "Bot Chat"
                    && exact.lastActive == 123,
                   "exact session rows retain root, tip, and activity fields")
        try expect(exact.matchesExactTitle("Bot Chat")
                    && !exact.matchesExactTitle("Bot"),
                   "old-gateway fallback filtering is exact on title/root")
        let noncanonicalLeaf = StoredSession(try decodeCanonicalJSON("""
        {"id":"other-root","resolved_id":"tip","root_title":"Other",
         "title":"Bot Chat","message_count":1}
        """))
        try expect(!noncanonicalLeaf.matchesExactTitle("Bot Chat"),
                   "a compressed noncanonical lineage cannot borrow Bot Chat from its leaf")
        let legacyLeaf = StoredSession(try decodeCanonicalJSON("""
        {"id":"legacy","title":"Bot Chat","message_count":1}
        """))
        try expect(legacyLeaf.matchesExactTitle("Bot Chat"),
                   "an older row without root_title still falls back to its exact leaf title")

        let oversizedRows = (0..<240).map { index in
            JSONValue.object([
                "id": .string("row-\(index)"),
                "title": .string(index == 220 ? "Bot Chat" : "Other"),
            ])
        }
        do {
            _ = try GatewayClient.decodeStoredSessionRows(
                oversizedRows, limit: 200, title: "Bot Chat")
            throw CheckFailure(description:
                "FAILED: ignored exact-title request must stay indeterminate")
        } catch let error as GatewayError {
            try expect(error.code == GatewayClient.exactTitleLookupIndeterminate,
                       "nonmatching compatibility window cannot authorize canonical birth")
        }
        try expect(try GatewayClient.decodeStoredSessionRows(
            [], limit: 200, title: "Bot Chat").isEmpty,
                   "an authoritative empty exact lookup remains a safe registry miss")

        let legacyMeta: JSONValue = ["hermes-bots": [
            "chat": "legacy-pointer", "groups": ["Ops"],
        ]]
        try expect(BotModeMeta(uiMeta: legacyMeta)?.legacyPinnedChat == "legacy-pointer",
                   "legacy chat metadata remains safely decodable")
        try expect(BotModeMeta.membershipProjection(["Ops"])["chat"] == nil,
                   "current metadata projections never write the removed chat pointer")
    }

    private static func decodeCanonicalJSON(_ source: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
    }
}
