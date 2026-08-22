#if canImport(XCTest)
import XCTest
@testable import TalariaKit

final class CanonicalSessionProtocolTests: XCTestCase {
    func testCurrentCanonicalWinsOverLegacyPreferredAndKeepsRootTip() throws {
        let profile = HermesProfile(try json("""
        {"name":"default",
         "canonical_session":{"id":"root","resolved_id":"tip","root_title":"Bot Chat",
                              "title":"Bot Chat (continued)","message_count":5},
         "preferred_session":{"id":"legacy","title":"Bot Chat","message_count":2}}
        """))
        XCTAssertEqual(profile.canonicalSession.session?.id, "root")
        XCTAssertEqual(profile.canonicalSession.session?.resolvedID, "tip")
        XCTAssertEqual(profile.preferredSession.session?.id, "root")
    }

    func testCurrentNullAndMalformedNeverFallBackButAbsentDoes() throws {
        let null = HermesProfile(try json("""
        {"name":"null","canonical_session":null,
         "preferred_session":{"id":"legacy","title":"Bot Chat"}}
        """))
        XCTAssertTrue(null.canonicalSession.isDefinitivelyGone)

        let malformed = HermesProfile(try json("""
        {"name":"bad","canonical_session":{"title":"Bot Chat"},
         "preferred_session":{"id":"legacy","title":"Bot Chat"}}
        """))
        XCTAssertTrue(malformed.canonicalSession.isMalformed)
        XCTAssertFalse(malformed.canonicalSession.isOmitted)
        XCTAssertNil(malformed.canonicalSession.session)
        XCTAssertNil(malformed.previewSession)

        let emptyID = HermesProfile(try json("""
        {"name":"empty","last_session":{"id":"scratch","title":"Scratch"},
         "canonical_session":{"id":"","title":"Bot Chat"},
         "preferred_session":{"id":"must-not-win","title":"Bot Chat"}}
        """))
        XCTAssertTrue(emptyID.canonicalSession.isMalformed)
        XCTAssertNil(emptyID.canonicalSession.session)
        XCTAssertNil(emptyID.previewSession)

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
            let profile = HermesProfile(try json(malformedEvidence))
            XCTAssertTrue(profile.canonicalSession.isMalformed)
            XCTAssertNil(profile.canonicalSession.session)
            XCTAssertNil(profile.previewSession)
        }

        let legacy = HermesProfile(try json("""
        {"name":"old","preferred_session":{"id":"legacy","resolved_id":"tip",
          "title":"Drifted historical title","message_count":4}}
        """))
        XCTAssertEqual(legacy.canonicalSession.session?.id, "legacy")
        XCTAssertEqual(legacy.canonicalSession.session?.resolvedID, "tip")
    }

    func testCurrentRequestShapesAndExactFallbackModel() throws {
        XCTAssertEqual(GatewayClient.profileListParams(includeSessions: true),
                       ["include_sessions": true])
        XCTAssertEqual(GatewayClient.exactSessionListParams(
            profile: "research", title: "Bot Chat"), [
                "profile": "research", "title": "Bot Chat", "include_hidden": true,
            ])
        XCTAssertEqual(GatewayClient.sessionTitleParams(
            runtimeID: "runtime-1", title: "Bot Chat"), [
                "session_id": "runtime-1", "title": "Bot Chat",
            ])
        XCTAssertEqual(try GatewayClient.decodeSessionTitleReceipt([
            "title": "Bot Chat", "pending": false,
        ]), SessionTitleReceipt(title: "Bot Chat", pending: false))
        for malformed: JSONValue in [
            .object([:]),
            .null,
            ["title": .number(1), "pending": .bool(false)],
            ["title": .string("Bot Chat"), "pending": .string("false")],
        ] {
            XCTAssertThrowsError(try GatewayClient.decodeSessionTitleReceipt(malformed)) { error in
                XCTAssertEqual((error as? GatewayError)?.code, -8)
            }
        }

        let row = StoredSession(try json("""
        {"id":"root","resolved_id":"tip","root_title":"Bot Chat",
         "title":"Bot Chat (continued)","last_active":42,"message_count":3}
        """))
        XCTAssertEqual(row.resumeID, "tip")
        XCTAssertEqual(row.lastActive, 42)
        XCTAssertTrue(row.matchesExactTitle("Bot Chat"))
        XCTAssertFalse(row.matchesExactTitle("Bot"))

        let noncanonicalLeaf = StoredSession(try json("""
        {"id":"other-root","resolved_id":"tip","root_title":"Other",
         "title":"Bot Chat","message_count":1}
        """))
        XCTAssertFalse(noncanonicalLeaf.matchesExactTitle("Bot Chat"))
        let legacyLeaf = StoredSession(try json("""
        {"id":"legacy","title":"Bot Chat","message_count":1}
        """))
        XCTAssertTrue(legacyLeaf.matchesExactTitle("Bot Chat"))

        let oversized = (0..<240).map { index in
            JSONValue.object([
                "id": .string("row-\(index)"),
                "title": .string(index == 220 ? "Bot Chat" : "Other"),
            ])
        }
        XCTAssertThrowsError(try GatewayClient.decodeStoredSessionRows(
            oversized, limit: 200, title: "Bot Chat")) { error in
            XCTAssertEqual((error as? GatewayError)?.code,
                           GatewayClient.exactTitleLookupIndeterminate)
        }
        XCTAssertTrue(try GatewayClient.decodeStoredSessionRows(
            [], limit: 200, title: "Bot Chat").isEmpty)
        var withinWindow = oversized
        withinWindow[199] = .object([
            "id": .string("canonical"), "title": .string("Bot Chat"),
        ])
        XCTAssertEqual(try GatewayClient.decodeStoredSessionRows(
            withinWindow, limit: 200, title: "Bot Chat").first?.id, "canonical")
    }

    func testLegacyChatMetadataIsDecodeOnly() {
        let meta = BotModeMeta(uiMeta: ["hermes-bots": [
            "chat": "legacy", "groups": ["Ops"],
        ]])
        XCTAssertEqual(meta?.legacyPinnedChat, "legacy")
        XCTAssertNil(BotModeMeta.membershipProjection(["Ops"])["chat"])
    }

    private func json(_ source: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
    }
}
#endif
