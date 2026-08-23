import XCTest
import TalariaKit
@testable import TalariaUI

final class BotProfileDetailPolicyTests: XCTestCase {
    func testRecentSessionsCapsAtThreeAndPreservesGatewayOrder() {
        let sessions = (0..<5).map {
            SessionSummary(id: "s\($0)", title: "Session \($0)", when: "now",
                           messageCount: $0)
        }
        XCTAssertEqual(BotProfileDetailPolicy.recentSessions(sessions).map(\.id),
                       ["s0", "s1", "s2"])
    }

    func testSeeAllAppearsOnlyPastInlineCapacity() {
        XCTAssertFalse(BotProfileDetailPolicy.showsAllSessions(total: 3))
        XCTAssertTrue(BotProfileDetailPolicy.showsAllSessions(total: 4))
    }
}
