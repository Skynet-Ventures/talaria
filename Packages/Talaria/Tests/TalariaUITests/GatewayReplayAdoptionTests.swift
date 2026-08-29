#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI

@MainActor
final class GatewayReplayAdoptionTests: XCTestCase {
    override func tearDown() {
        LiveRuntime.shared.sessionToBot.removeAll()
        LiveRuntime.shared.reconnectParkedSessionIDs.removeAll()
        LiveRuntime.shared.primaryEpochHandlerID = nil
        super.tearDown()
    }

    func testPreparedReplayMutatesPrimaryTranscriptBeforeCommitReturns() async throws {
        let model = AppModel()
        let client = GatewayClient(
            baseURL: URL(string: "https://replay-ui.example")!,
            credential: .sessionToken("test"))
        model.mode = .live
        model.client = client
        let botID = "hermes"
        let sessionID = "retired-sid"
        model.bots = [Bot(id: botID, job: "", shape: .circle, hue: .violet)]
        let chat = model.chat(for: botID)
        chat.sessionID = nil
        LiveRuntime.shared.gatewayID = "gateway-a"
        LiveRuntime.shared.reconnectParkedSessionIDs[botID] = sessionID
        model.restoreParkedReplayRoutes()
        XCTAssertEqual(chat.sessionID, sessionID)
        XCTAssertEqual(LiveRuntime.shared.sessionToBot[sessionID], botID)
        await client.setForegroundReadinessForTesting(true)
        await client.installPreparedReplayForTesting(events: [
            GatewayEvent(type: "message.start", sessionID: sessionID,
                         payload: [:], sequence: 8),
            GatewayEvent(type: "message.delta", sessionID: sessionID,
                         payload: ["text": "recovered"], sequence: 9),
            GatewayEvent(type: "message.complete", sessionID: sessionID,
                         payload: ["text": "recovered", "status": "complete"],
                         sequence: 10),
        ], certainty: .complete)

        let prepared = await client.prepareCurrentTransportForEvents()
        let publication = try XCTUnwrap(prepared)
        let applied = await model.applyPreparedGatewayReplay(
            publication, client: client, sourceGatewayID: "gateway-a")
        let watermarks = await client.replayWatermarksForTesting()

        XCTAssertTrue(applied)
        XCTAssertEqual(chat.messages.last?.text, "recovered")
        XCTAssertFalse(chat.messages.last?.isStreaming ?? true)
        XCTAssertFalse(chat.isTyping)
        XCTAssertEqual(watermarks, [sessionID: 10])
    }
}
#endif
