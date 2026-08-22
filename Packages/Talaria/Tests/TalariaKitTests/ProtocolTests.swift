#if canImport(XCTest)
import XCTest
@testable import TalariaKit

// XCTest is unavailable on toolchain-only (no Xcode) hosts; the same checks
// run everywhere via `swift run talaria-verify`. Keep these as separate test
// methods so CI identifies the broken contract instead of reporting one opaque
// "testAll" failure.
final class ProtocolXCTests: XCTestCase {
    func testEventEnvelopeDecoding() throws { try ProtocolChecks.eventEnvelopeDecoding() }
    func testUsageParsing() throws { try ProtocolChecks.usageParsing() }
    func testGatewayURLNormalization() throws { try ProtocolChecks.gatewayURLNormalization() }
    func testWebSocketURLBuilding() throws { try ProtocolChecks.webSocketURLBuilding() }
    func testPKCEChallengeShape() throws { try ProtocolChecks.pkceChallengeShape() }
    func testTokenSetRefreshWindow() throws { try ProtocolChecks.tokenSetRefreshWindow() }
    func testDemoDataIntegrity() throws { try ProtocolChecks.demoDataIntegrity() }
    func testLiveSessionParsing() throws { try ProtocolChecks.liveSessionParsing() }
    func testGatewayBotRouting() throws { try ProtocolChecks.gatewayBotRouting() }
    func testCanonicalSessionParsing() throws { try ProtocolChecks.canonicalSessionParsing() }
    func testRosterSearchSemantics() throws { try ProtocolChecks.rosterSearchSemantics() }
    func testMentionRouting() throws { try ProtocolChecks.mentionRouting() }
    func testAgentHandleRules() throws { try ProtocolChecks.agentHandleRules() }
    func testRosterCosmeticsSurviveRefresh() throws {
        try ProtocolChecks.rosterCosmeticsSurviveRefresh()
    }
    func testUnreadWatermarks() throws { try ProtocolChecks.unreadWatermarks() }
    func testToastPairing() throws { try ProtocolChecks.toastPairing() }
    func testBotModeNotices() throws { try ProtocolChecks.botModeNotices() }
    func testTranscriptActing() throws { try ProtocolChecks.transcriptActing() }
    func testMessageBranching() throws { try ProtocolChecks.messageBranching() }
}
#endif
