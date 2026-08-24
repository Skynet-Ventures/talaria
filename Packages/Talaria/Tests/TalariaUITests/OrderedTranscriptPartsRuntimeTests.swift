#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class OrderedTranscriptPartsRuntimeTests: XCTestCase {
    @MainActor
    func testHydrationPreservesOrderedRowsAndLegacyFallback() throws {
        let transcript: JSONValue = ["messages": [
            ["id": 1, "role": "user", "content": "Ask",
             "parts_version": 1, "parts": [
                ["kind": "text", "id": "user", "text": "Ask"],
             ]],
            ["id": 2, "role": "assistant", "content": "Before after",
             "parts_version": 1, "parts": [
                ["kind": "text", "text": "Before "],
                ["kind": "image", "ref": "https://example.test/inert.png"],
                ["kind": "text", "text": "after"],
             ], "parts_clipped": true],
            ["id": 3, "role": "assistant", "content": "old gateway"],
        ]]
        let messages = AppModel.chatMessages(fromTranscript: transcript)
        XCTAssertEqual(messages[0].orderedParts?.parts.first?.text, "Ask")
        XCTAssertEqual(messages[1].orderedParts?.parts.map(\.kind),
                       [.text, .image, .text, .clipped])
        XCTAssertTrue(messages[1].orderedParts?.clipped ?? false)
        XCTAssertNil(messages[2].orderedParts)
        XCTAssertEqual(messages[2].text, "old gateway")
    }

    @MainActor
    func testLiveReasoningAppendSealAndEqualTerminalReplace() throws {
        let model = AppModel()
        model.mode = .live
        let botID = "remote::parts"
        let sid = "parts-runtime"
        let route = GatewaySessionRoute(gatewayID: "remote", sessionID: sid)
        LiveRuntime.shared.routedSessionToBot[route] = botID
        defer {
            LiveRuntime.shared.routedSessionToBot[route] = nil
            ChatRuntime.shared.turnFloor[botID] = nil
        }
        let chat = model.chat(for: botID)
        chat.messages = [ChatMessage(author: .user, text: "Ask")]

        model.handle(event: GatewayEvent(type: "message.start", sessionID: sid,
            payload: ["parts_version": 1, "parts": [
                ["kind": "text", "id": "user", "text": "Ask"],
            ]]), sourceGatewayID: "remote")
        model.handle(event: GatewayEvent(type: "reasoning.delta", sessionID: sid,
            payload: ["text": "Think "]), sourceGatewayID: "remote")
        model.handle(event: GatewayEvent(type: "message.delta", sessionID: sid,
            payload: ["text": "Done", "parts_version": 1, "parts_mode": "append",
                      "parts": [["kind": "text", "id": "assistant-stream",
                                 "text": "Done"]]]), sourceGatewayID: "remote")
        model.handle(event: GatewayEvent(type: "reasoning.delta", sessionID: sid,
            payload: ["text": "more"]), sourceGatewayID: "remote")
        model.handle(event: GatewayEvent(type: "message.interim", sessionID: sid,
            payload: ["text": "Done", "already_streamed": true,
                      "parts_version": 1, "parts_mode": "seal",
                      "parts": [["kind": "text", "text": "Done"]]]),
            sourceGatewayID: "remote")
        model.handle(event: GatewayEvent(type: "message.complete", sessionID: sid,
            payload: ["status": "complete", "text": "Done",
                      "parts_version": 1, "parts_mode": "replace",
                      "parts": [["kind": "reasoning", "text": "Think more"],
                                ["kind": "text", "text": "Done"]]]),
            sourceGatewayID: "remote")

        let assistant = try XCTUnwrap(chat.messages.last)
        XCTAssertEqual(assistant.text, "Done")
        XCTAssertFalse(assistant.isStreaming)
        XCTAssertEqual(assistant.orderedParts?.parts.map(\.kind), [.reasoning, .text])
        XCTAssertEqual(assistant.orderedParts?.parts.first?.text, "Think more")
    }

    @MainActor
    func testWrongSourceCannotPublishOrderedParts() {
        let model = AppModel()
        model.mode = .live
        let botID = "remote::parts"
        let sid = "parts-runtime"
        let route = GatewaySessionRoute(gatewayID: "remote", sessionID: sid)
        LiveRuntime.shared.routedSessionToBot[route] = botID
        defer { LiveRuntime.shared.routedSessionToBot[route] = nil }
        let chat = model.chat(for: botID)
        chat.messages = [ChatMessage(author: .user, text: "Ask")]

        model.handle(event: GatewayEvent(type: "message.delta", sessionID: sid,
            payload: ["text": "wrong", "parts_version": 1,
                      "parts": [["kind": "text", "text": "wrong"]]]),
            sourceGatewayID: "primary")
        XCTAssertEqual(chat.messages.count, 1)
        XCTAssertNil(chat.messages[0].orderedParts)
    }

    @MainActor
    func testTerminalWholeRunReplaceCollapsesOrdinaryInterimRows() throws {
        let model = AppModel()
        model.mode = .live
        let botID = "remote::segments"
        let sid = "segments-runtime"
        let route = GatewaySessionRoute(gatewayID: "remote", sessionID: sid)
        LiveRuntime.shared.routedSessionToBot[route] = botID
        defer {
            LiveRuntime.shared.routedSessionToBot[route] = nil
            ChatRuntime.shared.turnFloor[botID] = nil
        }
        let chat = model.chat(for: botID)
        chat.messages = [ChatMessage(author: .user, text: "Ask")]
        model.handle(event: GatewayEvent(type: "message.start", sessionID: sid,
                                          payload: [:]), sourceGatewayID: "remote")
        model.handle(event: GatewayEvent(type: "message.delta", sessionID: sid,
            payload: ["text": "A", "parts_version": 1, "parts_mode": "append",
                      "parts": [["kind": "text", "id": "assistant-stream",
                                 "text": "A"]]]), sourceGatewayID: "remote")
        model.handle(event: GatewayEvent(type: "message.interim", sessionID: sid,
            payload: ["text": "A", "already_streamed": true,
                      "parts_version": 1, "parts_mode": "seal",
                      "parts": [["kind": "text", "text": "A"]]]),
            sourceGatewayID: "remote")
        model.routeToolEvent(GatewayEvent(type: "tool.start", sessionID: sid,
            payload: ["tool_id": "call-1", "name": "terminal",
                      "parts_version": 1, "parts_mode": "append",
                      "parts": [["kind": "tool-call", "id": "call-1",
                                 "name": "terminal"]]]), sourceGatewayID: "remote")
        model.routeToolEvent(GatewayEvent(type: "tool.complete", sessionID: sid,
            payload: ["tool_id": "call-1", "name": "terminal",
                      "result": ["stdout": "ok"],
                      "parts_version": 1, "parts_mode": "append",
                      "parts": [["kind": "tool-result", "id": "call-1",
                                 "name": "terminal", "value": ["stdout": "ok"]]]]),
            sourceGatewayID: "remote")
        model.handle(event: GatewayEvent(type: "message.delta", sessionID: sid,
            payload: ["text": "B", "parts_version": 1, "parts_mode": "append",
                      "parts": [["kind": "text", "id": "assistant-stream",
                                 "text": "B"]]]), sourceGatewayID: "remote")
        XCTAssertEqual(chat.messages.count, 3)
        model.handle(event: GatewayEvent(type: "message.complete", sessionID: sid,
            payload: ["status": "complete", "text": "B",
                      "parts_version": 1, "parts_mode": "replace",
                      "parts": [
                        ["kind": "text", "text": "A"],
                        ["kind": "tool-call", "id": "call-1", "name": "terminal"],
                        ["kind": "tool-result", "id": "call-1", "name": "terminal",
                         "value": ["stdout": "ok"]],
                        ["kind": "text", "text": "B"],
                      ]]),
            sourceGatewayID: "remote")

        XCTAssertEqual(chat.messages.count, 2)
        let assistant = try XCTUnwrap(chat.messages.last)
        XCTAssertEqual(assistant.text, "AB")
        XCTAssertEqual(assistant.toolCalls.count, 1)
        let envelope = try XCTUnwrap(assistant.orderedParts)
        XCTAssertEqual(OrderedTranscriptPresentation.project(
            envelope, toolCalls: assistant.toolCalls), [
                .text("A"), .tools(assistant.toolCalls), .text("B"),
            ])
        XCTAssertEqual(AssistantMediaProjection.copyText(in: assistant), "AB")
        let index = try TranscriptFindPolicy.makeIndex(messages: [assistant])
        XCTAssertEqual(try TranscriptFindPolicy.search("AB", in: index).total, 1)
    }

    @MainActor
    func testClippedTerminalReplaceNeverErasesPriorInterimRows() {
        let model = AppModel()
        model.mode = .live
        let botID = "remote::clipped-segments"
        let sid = "clipped-runtime"
        let route = GatewaySessionRoute(gatewayID: "remote", sessionID: sid)
        LiveRuntime.shared.routedSessionToBot[route] = botID
        defer {
            LiveRuntime.shared.routedSessionToBot[route] = nil
            ChatRuntime.shared.turnFloor[botID] = nil
        }
        let chat = model.chat(for: botID)
        chat.messages = [ChatMessage(author: .user, text: "Ask")]
        model.handle(event: GatewayEvent(type: "message.start", sessionID: sid,
                                          payload: [:]), sourceGatewayID: "remote")
        model.handle(event: GatewayEvent(type: "message.delta", sessionID: sid,
            payload: ["text": "A", "parts_version": 1, "parts_mode": "append",
                      "parts": [["kind": "text", "text": "A"]]]),
            sourceGatewayID: "remote")
        model.handle(event: GatewayEvent(type: "message.interim", sessionID: sid,
            payload: ["text": "A", "already_streamed": true,
                      "parts_version": 1, "parts_mode": "seal",
                      "parts": [["kind": "text", "text": "A"]]]),
            sourceGatewayID: "remote")
        model.handle(event: GatewayEvent(type: "message.delta", sessionID: sid,
            payload: ["text": "B", "parts_version": 1, "parts_mode": "append",
                      "parts": [["kind": "text", "text": "B"]]]),
            sourceGatewayID: "remote")
        model.handle(event: GatewayEvent(type: "message.complete", sessionID: sid,
            payload: ["status": "complete", "text": "B",
                      "parts_version": 1, "parts_mode": "replace",
                      "parts_clipped": true,
                      "parts": [["kind": "text", "text": "A"],
                                ["kind": "text", "text": "B"]]]),
            sourceGatewayID: "remote")

        XCTAssertEqual(chat.messages.map(\.text), ["Ask", "A", "B"])
        XCTAssertTrue(chat.messages.last?.orderedParts?.clipped ?? false)
    }

    @MainActor
    func testExactToolPartsMergeOnceAndMediaReferenceRemainsInert() throws {
        let model = AppModel()
        model.mode = .live
        let botID = "remote::tools"
        let sid = "tool-runtime"
        let route = GatewaySessionRoute(gatewayID: "remote", sessionID: sid)
        LiveRuntime.shared.routedSessionToBot[route] = botID
        defer {
            LiveRuntime.shared.routedSessionToBot[route] = nil
            ChatRuntime.shared.turnFloor[botID] = nil
        }
        let chat = model.chat(for: botID)
        chat.messages = [ChatMessage(author: .user, text: "Run")]
        model.routeToolEvent(GatewayEvent(type: "message.start", sessionID: sid,
                                          payload: [:]), sourceGatewayID: "remote")

        let start = GatewayEvent(type: "tool.start", sessionID: sid, payload: [
            "tool_id": "call-1", "name": "terminal", "args": ["command": "pwd"],
            "parts_version": 1, "parts_mode": "append", "parts": [
                ["kind": "tool-call", "id": "call-1", "name": "terminal"],
            ],
        ])
        let complete = GatewayEvent(type: "tool.complete", sessionID: sid, payload: [
            "tool_id": "call-1", "name": "terminal",
            "result": ["stdout": "/tmp\n", "stderr": ""],
            "parts_version": 1, "parts_mode": "append", "parts": [
                ["kind": "tool-result", "id": "call-1", "name": "terminal",
                 "value": ["stdout": "/tmp\n"]],
                ["kind": "image", "ref": "https://example.test/inert.png"],
            ],
        ])
        model.routeToolEvent(start, sourceGatewayID: "remote")
        model.routeToolEvent(complete, sourceGatewayID: "remote")

        let assistant = try XCTUnwrap(chat.messages.last)
        XCTAssertEqual(assistant.toolCalls.count, 1)
        XCTAssertEqual(assistant.toolCalls[0].gatewayToolID, "call-1")
        XCTAssertEqual(assistant.toolCalls[0].structuredOutput?.stdout?.plainText, "/tmp\n")
        let envelope = try XCTUnwrap(assistant.orderedParts)
        let runs = OrderedTranscriptPresentation.project(
            envelope, toolCalls: assistant.toolCalls)
        XCTAssertEqual(runs.filter {
            if case .tools = $0 { return true }; return false
        }.count, 1)
        XCTAssertTrue(runs.contains {
            if case .attachment(kind: .image, _, _, _) = $0 { return true }; return false
        })
        XCTAssertFalse(OrderedTranscriptInteractionPolicy.allowsAttachmentInteraction(
            archived: false))
        XCTAssertFalse(OrderedTranscriptInteractionPolicy.allowsToolInteraction(
            archived: true))
    }

    @MainActor
    func testRetainedPartsReconnectProjectionMatchesCanonicalEnvelope() throws {
        let retained = try XCTUnwrap(RetainedInflightTurn(.object([
            "user": .string("Ask"), "assistant": .string("Answer"),
            "streaming": .bool(true), "parts_version": .number(1),
            "user_parts": .array([.object([
                "kind": .string("text"), "id": .string("user"),
                "text": .string("Ask"),
            ])]),
            "parts": .array([
                .object(["kind": .string("reasoning"), "text": .string("Think")]),
                .object(["kind": .string("text"), "text": .string("Answer")]),
            ]),
        ])))
        let rows = AppModel.retainedInflightProjection(retained, failure: nil)
        XCTAssertEqual(rows.first?.orderedParts, retained.userParts)
        XCTAssertEqual(rows.last?.orderedParts, retained.parts)
        XCTAssertEqual(rows.last?.text, "Answer")
    }

    @MainActor
    func testPlainOrderedUserStillUsesLegacyFindProjection() throws {
        let ordered = TranscriptPartsEnvelope(parts: [
            TranscriptPart(kind: .text, id: "user", text: "needle"),
        ])
        XCTAssertFalse(OrderedTranscriptPresentation.shouldRenderOrdered(
            ordered, legacyText: "needle", projectedVisibleText: "needle"))
        let message = ChatMessage(author: .user, text: "needle", orderedParts: ordered)
        let index = try TranscriptFindPolicy.makeIndex(messages: [message])
        XCTAssertEqual(try TranscriptFindPolicy.search("needle", in: index).total, 1)
    }
}
#endif
