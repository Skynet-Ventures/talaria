#if canImport(XCTest)
import XCTest
@testable import TalariaKit

final class OpenChatHistoryPolicyTests: XCTestCase {
    func testOpenChatResumeDefersHistoryAndNamesTheWireFlag() {
        XCTAssertTrue(OpenChatHistoryPolicy.resumeDefersHistory)
        let params = GatewayClient.resumeSessionParams(
            "stored-1", profile: "research",
            deferHistory: OpenChatHistoryPolicy.resumeDefersHistory)
        XCTAssertEqual(params["session_id"]?.stringValue, "stored-1")
        XCTAssertEqual(params["source"]?.stringValue, "talaria")
        XCTAssertEqual(params["profile"]?.stringValue, "research")
        XCTAssertEqual(params["defer_history"]?.boolValue, true)

        let full = GatewayClient.resumeSessionParams("stored-1", deferHistory: false)
        XCTAssertNil(full["defer_history"])
    }

    func testLatestPageQueryIsNewestWindowNotOldestPrefix() {
        let query = OpenChatHistoryPolicy.latestMessagesQuery(
            profile: "research", limit: 200, offset: 0)
        XCTAssertEqual(query.map(\.name), ["profile", "limit", "order", "include_compacted"])
        XCTAssertEqual(query.map(\.value), ["research", "200", "latest", "true"])

        let older = OpenChatHistoryPolicy.latestMessagesQuery(
            profile: nil, limit: 200, offset: 200)
        XCTAssertEqual(older.map(\.name), ["limit", "order", "include_compacted", "offset"])
        XCTAssertEqual(older.last?.value, "200")
    }

    func testDeferredStubStillNeedsTheLatestPage() {
        XCTAssertTrue(OpenChatHistoryPolicy.needsLatestPage(
            historyDeferred: true, resumeMessageCount: 8))
        XCTAssertTrue(OpenChatHistoryPolicy.needsLatestPage(
            historyDeferred: true, resumeMessageCount: 0))
        XCTAssertTrue(OpenChatHistoryPolicy.needsLatestPage(
            historyDeferred: false, resumeMessageCount: 0))
        XCTAssertFalse(OpenChatHistoryPolicy.needsLatestPage(
            historyDeferred: false, resumeMessageCount: 40))
    }

    func testLargerResumeProjectionWinsOverASmallerRESTWindow() {
        XCTAssertEqual(
            OpenChatHistoryPolicy.authoritativeSource(resumeCount: 800, pageCount: 200),
            .resumeProjection)
        XCTAssertEqual(
            OpenChatHistoryPolicy.authoritativeSource(resumeCount: 4, pageCount: 200),
            .latestPage)
        XCTAssertTrue(OpenChatHistoryPolicy.hasOlderMessages(
            pageCount: 200, limit: 200, source: .latestPage))
        XCTAssertFalse(OpenChatHistoryPolicy.hasOlderMessages(
            pageCount: 40, limit: 200, source: .latestPage))
        XCTAssertFalse(OpenChatHistoryPolicy.hasOlderMessages(
            pageCount: 800, limit: 200, source: .resumeProjection))
    }

    func testSameBindingTreatsRootAndResumeTipAsOneConversation() {
        XCTAssertTrue(OpenChatHistoryPolicy.sameBinding(
            "root", target: "tip", durableID: "root"))
        XCTAssertTrue(OpenChatHistoryPolicy.sameBinding(
            "tip", target: "tip", durableID: "root"))
        XCTAssertFalse(OpenChatHistoryPolicy.sameBinding(
            "other", target: "tip", durableID: "root"))
        XCTAssertFalse(OpenChatHistoryPolicy.sameBinding(
            nil, target: "tip", durableID: "root"))
    }

    func testTitleOnlyResumeDoesNotPrefetchREST() {
        XCTAssertNil(OpenChatHistoryPolicy.attachRestTarget(
            "Bot Chat", durableID: nil, canonicalTitle: "Bot Chat"))
        XCTAssertEqual(OpenChatHistoryPolicy.attachRestTarget(
            "Bot Chat", durableID: "root", canonicalTitle: "Bot Chat"), "root")
        XCTAssertEqual(OpenChatHistoryPolicy.attachRestTarget(
            "stored-1", durableID: nil, canonicalTitle: "Bot Chat"), "stored-1")
    }

    func testPrependDropsDuplicateDurableRows() {
        let visible = [
            ChatMessage(author: .user, text: "later", rowID: 3),
            ChatMessage(author: .bot, text: "answer", rowID: 4),
        ]
        let older = [
            ChatMessage(author: .user, text: "earlier", rowID: 1),
            ChatMessage(author: .bot, text: "old answer", rowID: 2),
            ChatMessage(author: .user, text: "later duplicate", rowID: 3),
        ]
        let merged = OpenChatHistoryPolicy.prepend(existing: visible, older: older)
        XCTAssertEqual(merged.map(\.text), ["earlier", "old answer", "later", "answer"])
        XCTAssertEqual(merged.map(\.rowID), [1, 2, 3, 4])
    }
}
#endif
