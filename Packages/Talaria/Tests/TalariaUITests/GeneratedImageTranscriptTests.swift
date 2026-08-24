import ImageIO
import XCTest
@testable import TalariaKit
@testable import TalariaUI

@MainActor
final class GeneratedImageTranscriptTests: XCTestCase {
    private func output(_ path: String = "/tmp/image.png") throws -> ToolGeneratedImage {
        try XCTUnwrap(ToolGeneratedImageCodec.candidate(
            arguments: ToolPayloadCodec.arguments(from: ["aspect_ratio": "square"]),
            result: ["success": true, "image": .string(path)]))
    }

    func testCompletionBeforeStartPromotesOnlyExactIDAndCoalescesGenerating() throws {
        let model = AppModel()
        let botID = "image-order-\(UUID().uuidString)"
        let sessionID = "image-session-\(UUID().uuidString)"
        let runtime = LiveRuntime.shared
        let oldGateway = runtime.gatewayID
        let oldMapping = runtime.sessionToBot[sessionID]
        defer {
            runtime.gatewayID = oldGateway
            runtime.sessionToBot[sessionID] = oldMapping
            ChatRuntime.shared.turnFloor[botID] = nil
            model.chats[botID] = nil
        }
        model.mode = .live
        runtime.gatewayID = "image-gateway"
        runtime.sessionToBot[sessionID] = botID
        model.chat(for: botID).sessionID = sessionID
        model.routeToolEvent(GatewayEvent(type: "message.start", sessionID: sessionID,
                                          payload: nil))
        model.routeToolEvent(GatewayEvent(type: "tool.generating", sessionID: sessionID,
                                          payload: ["name": "image_generate"]))
        model.routeToolEvent(GatewayEvent(type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "A", "result": ["success": true,
                                                    "image": "/tmp/a.png"]]))
        var calls = try XCTUnwrap(model.chats[botID]?.messages.last?.toolCalls)
        let before = try XCTUnwrap(calls.first(where: { $0.gatewayToolID == "A" }))
        XCTAssertNil(before.generatedImage)
        XCTAssertNotNil(before.deferredGeneratedImage)

        model.routeToolEvent(GatewayEvent(type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "A", "name": "image_generate",
                      "args": ["aspect_ratio": "portrait"]]))
        calls = try XCTUnwrap(model.chats[botID]?.messages.last?.toolCalls)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.generatedImage?.source, "/tmp/a.png")
        XCTAssertNil(calls.first?.deferredGeneratedImage)

        model.routeToolEvent(GatewayEvent(type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "B", "result": ["success": true,
                                                    "image": "/tmp/b.png"]]))
        model.routeToolEvent(GatewayEvent(type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "B", "name": "terminal"]))
        let nonimage = try XCTUnwrap(model.chats[botID]?.messages.last?.toolCalls
            .first(where: { $0.gatewayToolID == "B" }))
        XCTAssertNil(nonimage.generatedImage)
        XCTAssertNil(nonimage.deferredGeneratedImage)
    }

    func testDuplicateNamesPairOnlyByRawExactID() throws {
        let transcript: JSONValue = ["messages": [
            ["id": 1, "role": "assistant", "content": "", "tool_calls": [
                ["id": "A", "function": ["name": "image_generate",
                                              "arguments": "{\"aspect_ratio\":\"square\"}"]],
                ["id": "B", "function": ["name": "image_generate",
                                              "arguments": "{}"]],
            ]],
            ["id": 2, "role": "tool", "tool_call_id": "B",
             "content": "{\"success\":true,\"image\":\"/tmp/b.png\"}"],
            ["id": 3, "role": "tool", "tool_call_id": "A",
             "content": ["success": true, "host_image": "/tmp/a.png"]],
        ]]
        let calls = AppModel.chatMessages(fromTranscript: transcript).flatMap(\.toolCalls)
        XCTAssertEqual(calls.first(where: { $0.gatewayToolID == "A" })?.generatedImage?.source,
                       "/tmp/a.png")
        XCTAssertEqual(calls.first(where: { $0.gatewayToolID == "B" })?.generatedImage?.source,
                       "/tmp/b.png")
        XCTAssertEqual(calls.first(where: { $0.gatewayToolID == "A" })?.generatedImage?.aspect,
                       .square)
    }

    func testFailureReplayIsMonotonicAndStaysGeneric() throws {
        let model = AppModel()
        let botID = "image-failure-\(UUID().uuidString)"
        let sessionID = "image-failure-session-\(UUID().uuidString)"
        let runtime = LiveRuntime.shared
        let oldGateway = runtime.gatewayID
        let oldMapping = runtime.sessionToBot[sessionID]
        defer {
            runtime.gatewayID = oldGateway
            runtime.sessionToBot[sessionID] = oldMapping
            ChatRuntime.shared.turnFloor[botID] = nil
            model.chats[botID] = nil
        }
        model.mode = .live; runtime.gatewayID = "image-failure-gateway"
        runtime.sessionToBot[sessionID] = botID
        model.chat(for: botID).sessionID = sessionID
        model.routeToolEvent(GatewayEvent(type: "message.start", sessionID: sessionID,
                                          payload: nil))
        model.routeToolEvent(GatewayEvent(type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "F", "name": "image_generate"]))
        model.routeToolEvent(GatewayEvent(type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "F", "name": "image_generate", "error": "denied",
                      "summary": "denied", "result": ["success": true,
                                                        "image": "/tmp/evidence.png"]]))
        model.routeToolEvent(GatewayEvent(type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "F", "result": ["message": "late benign replay"]]))
        let call = try XCTUnwrap(model.chats[botID]?.messages.last?.toolCalls.first)
        XCTAssertEqual(call.state, .failed)
        XCTAssertEqual(call.summary, "denied")
        XCTAssertEqual(call.generatedImage?.source, "/tmp/evidence.png")
        XCTAssertFalse(ToolRunPresentationPolicy.isGeneratedImageSpecialist(call))
    }

    func testCanonicalOverlayPromotesStoredDeferredAndPreservesFailure() throws {
        let id = UUID()
        let storedOutput = try output("/tmp/stored.png")
        let liveOutput = try output("/tmp/live.png")
        let stored = ChatMessage(id: id, author: .bot, text: "done", toolCalls: [
            ToolCall(id: "stored", name: "Tool", context: "", state: .failed,
                     gatewayToolID: "wire", deferredGeneratedImage: storedOutput,
                     provenance: .stored),
        ], rowID: 7)
        let live = ChatMessage(id: id, author: .bot, text: "done", toolCalls: [
            ToolCall(id: "live", name: "image_generate", context: "", state: .done,
                     gatewayToolID: "wire", generatedImage: liveOutput,
                     provenance: .live),
        ], rowID: 7)
        let call = try XCTUnwrap(TranscriptHydrationMerge.merge(
            history: [stored], baseline: [live], current: [live], clearWhenEmpty: false)
            .first?.toolCalls.first)
        XCTAssertEqual(call.name, "image_generate")
        XCTAssertEqual(call.state, .failed)
        XCTAssertEqual(call.generatedImage?.source, "/tmp/stored.png")
        XCTAssertNil(call.deferredGeneratedImage)
        XCTAssertEqual(call.provenance, .stored)
    }

    func testStandaloneOrderingQuietVisibilityAndAccessibilityPolicy() throws {
        let image = try output()
        let calls = [
            ToolCall(id: "g1", name: "read_file", context: "", state: .done),
            ToolCall(id: "image", name: "image_generate", context: "", state: .done,
                     gatewayToolID: "image", generatedImage: image),
            ToolCall(id: "g2", name: "read_file", context: "", state: .done),
        ]
        XCTAssertEqual(ToolRunPresentationPolicy.presentationRuns(calls).map { $0.map(\.id) },
                       [["g1"], ["image"], ["g2"]])
        XCTAssertEqual(TranscriptPresentationPolicy(detail: .quiet)
            .visibleToolCalls(calls).map(\.id), ["image"])
        XCTAssertEqual(GeneratedImagePresentationPolicy.minimumInteractiveDimension, 44)
        XCTAssertEqual(GeneratedImagePresentationPolicy.titleTextStyle, .subheadline)
        XCTAssertFalse(GeneratedImagePresentationPolicy.reducedMotionUsesSpatialAnimation)
        XCTAssertEqual(GeneratedImagePresentationPolicy.accessibilityValue(
            call: calls[1], loaded: true), "Generated image ready")
    }

    func testSamePathAcrossSourcesHasDistinctTaskIdentityAndNoAuthorityFailsClosed() async throws {
        let model = AppModel()
        let first = GeneratedImagePresentationSource(
            model: model, botID: "one",
            route: GatewayBotRoute(gatewayID: "A", profile: "default"),
            storedSessionID: "stored", liveSessionID: "live")
        let second = GeneratedImagePresentationSource(
            model: model, botID: "two",
            route: GatewayBotRoute(gatewayID: "B", profile: "default"),
            storedSessionID: "stored", liveSessionID: "live")
        XCTAssertNotEqual(first.identity, second.identity)
        let result = await model.loadGeneratedImage(try output(), from: first)
        guard case .unavailable = result else {
            return XCTFail("A source without exact live authority must fail closed")
        }
    }

    func testDecodeAndRasterBombPoliciesFailClosed() {
        XCTAssertNil(AppModel.decodeGeneratedImageDataURL(
            "data:image/png;base64,not-base64!"))
        XCTAssertNil(GeneratedImageRasterPolicy.dimensions(Data("not an image".utf8)))
    }

    func testRasterPolicyRejectsDimensionsAndAnimationBombs() throws {
        let pixel = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let huge = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAJxAAACcQCAQAAAAQR6qsAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        XCTAssertEqual(GeneratedImageRasterPolicy.dimensions(pixel), CGSize(width: 1, height: 1))
        XCTAssertNil(GeneratedImageRasterPolicy.dimensions(huge))

        let source = try XCTUnwrap(CGImageSourceCreateWithData(pixel as CFData, nil))
        let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let animated = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            animated, "com.compuserve.gif" as CFString, 2, nil))
        CGImageDestinationAddImage(destination, frame, nil)
        CGImageDestinationAddImage(destination, frame, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertNil(GeneratedImageRasterPolicy.dimensions(animated as Data))
    }

    func testTranscriptFindDoesNotIndexGeneratedCardPayload() throws {
        let message = ChatMessage(author: .bot,
                                  text: "visible prose ![echo](/tmp/image.png)", toolCalls: [
            ToolCall(id: "image", name: "image_generate", context: "hidden prompt needle",
                     state: .done, gatewayToolID: "image", generatedImage: try output()),
        ])
        let index = try TranscriptFindPolicy.makeIndex(messages: [message])
        XCTAssertEqual(try TranscriptFindPolicy.search("visible prose", in: index).total, 1)
        XCTAssertEqual(try TranscriptFindPolicy.search("echo", in: index).total, 0)
        XCTAssertEqual(try TranscriptFindPolicy.search("hidden prompt needle", in: index).total, 0)
        XCTAssertEqual(try TranscriptFindPolicy.search("tmp image", in: index).total, 0)
    }
}
