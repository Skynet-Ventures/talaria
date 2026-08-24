import ImageIO
import XCTest
@testable import TalariaKit
@testable import TalariaUI

private actor GeneratedImageRequestCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

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
        XCTAssertEqual(GeneratedImagePresentationPolicy.retryLabel, "Retry")
        XCTAssertEqual(GeneratedImagePresentationPolicy.accessibilityLiveRegion, "polite")
        XCTAssertEqual(GeneratedImagePresentationPolicy.titleTextStyle, .subheadline)
        XCTAssertFalse(GeneratedImagePresentationPolicy.reducedMotionUsesSpatialAnimation)
        XCTAssertEqual(GeneratedImagePresentationPolicy.accessibilityValue(
            call: calls[1], loaded: true), "Generated image ready")
        XCTAssertEqual(GeneratedImagePresentationPolicy.accessibilityValue(
            call: calls[1], loaded: false, loading: true),
            "Loading generated image")
        XCTAssertEqual(GeneratedImagePresentationPolicy.accessibilityValue(
            call: calls[1], loaded: false, remoteApprovalRequired: true),
            "Generated image requires permission to load")
        XCTAssertEqual(GeneratedImagePresentationPolicy.accessibilityValue(
            call: calls[1], loaded: false, failed: true),
            "Generated image unavailable. Retry available")
        let hint: CGFloat = 9.0 / 16.0
        for state in GeneratedImagePresentationPolicy.UnloadedState.allCases {
            XCTAssertEqual(GeneratedImagePresentationPolicy.unloadedSurfaceAspectRatio(
                state: state, hint: hint), hint,
                "every unloaded UI branch must use the fixed hinted-aspect surface")
        }
    }

    func testMutationDuringFinalAuthorityAwaitPreventsAnyImageRequest() async throws {
        let registry = ConnectionRegistry.shared
        let live = LiveRuntime.shared
        let events = MultiGatewayRuntime.shared
        let oldGateway = live.gatewayID
        let oldBaseURL = live.baseURL
        let oldGeneration = live.generation
        let nonce = UUID().uuidString
        let url = try XCTUnwrap(URL(string: "https://image-authority-\(nonce).example"))
        let credential = GatewayCredential.sessionToken("image-authority-\(nonce)")
        let gateway = try XCTUnwrap(registry.upsert(
            urlString: url.absoluteString, name: "Image authority", credential: credential))
        registry.setCredentialForTesting(credential, for: gateway)
        let requests = GeneratedImageRequestCounter()
        let client = GatewayClient(
            baseURL: try XCTUnwrap(gateway.baseURL), credential: credential,
            restExecutor: { request, _ in
                await requests.record()
                return (Data(), HTTPURLResponse(
                    url: request.url!, statusCode: 500, httpVersion: nil,
                    headerFields: nil)!)
            })
        await registry.clientPool.adopt(client, for: gateway.id)
        let route = GatewayBotRoute(gatewayID: gateway.id, profile: "worker")
        let botID = route.qualifiedID
        let pump = Task<Void, Never> {}
        let oldEvents = events.routedEvents[gateway.id]
        let oldEventGeneration = events.routedEventGenerations[gateway.id]
        defer {
            GeneratedImageRuntime.shared.afterTranscriptAuthorityCaptureForTesting = nil
            pump.cancel()
            events.routedEvents[gateway.id] = oldEvents
            events.routedEventGenerations[gateway.id] = oldEventGeneration
            live.gatewayID = oldGateway
            live.baseURL = oldBaseURL
            live.generation = oldGeneration
            registry.setCredentialForTesting(nil, for: gateway)
            if registry.saved.contains(where: { $0.id == gateway.id }) {
                registry.remove(id: gateway.id)
            }
        }
        live.gatewayID = "unrelated-primary-\(nonce)"
        live.baseURL = nil
        live.generation &+= 1
        events.routedEventGenerations[gateway.id] = 41
        events.routedEvents[gateway.id] = MultiGatewayRuntime.RoutedEvents(
            client: client, handlerID: UUID(), pump: pump, generation: 41)

        let model = AppModel()
        model.mode = .live
        let call = ToolCall(id: "call", name: "image_generate", context: "",
                            state: .done, gatewayToolID: "wire",
                            generatedImage: try output(), provenance: .live)
        let message = ChatMessage(author: .bot, text: "", toolCalls: [call], rowID: 7)
        let chat = ChatState(messages: [message])
        chat.storedSessionID = "stored"
        chat.sessionID = "live"
        model.chats[botID] = chat
        let source = GeneratedImagePresentationSource(
            model: model, botID: botID, route: route,
            storedSessionID: "stored", liveSessionID: "live",
            messageRowID: 7, messageRevisionID: message.id)
        var hookRan = false
        GeneratedImageRuntime.shared.afterTranscriptAuthorityCaptureForTesting = {
            hookRan = true
            chat.messages[0].toolCalls[0].state = .failed
        }

        let result = await model.loadGeneratedImage(call, from: source)
        if case .unavailable = result {} else {
            XCTFail("mutated exact call must fail closed")
        }
        XCTAssertTrue(hookRan)
        let requestCount = await requests.count
        XCTAssertEqual(requestCount, 0,
                       "the post-await synchronous proof must precede request dispatch")
        model.clearProfileLifecycleRouteForTesting(route)
        await registry.clientPool.disconnect(gatewayID: gateway.id)
    }

    func testSamePathAcrossSourcesHasDistinctTaskIdentityAndNoAuthorityFailsClosed() async throws {
        let model = AppModel()
        let first = GeneratedImagePresentationSource(
            model: model, botID: "one",
            route: GatewayBotRoute(gatewayID: "A", profile: "default"),
            storedSessionID: "stored", liveSessionID: "live",
            messageRowID: 1, messageRevisionID: UUID())
        let second = GeneratedImagePresentationSource(
            model: model, botID: "two",
            route: GatewayBotRoute(gatewayID: "B", profile: "default"),
            storedSessionID: "stored", liveSessionID: "live",
            messageRowID: 1, messageRevisionID: UUID())
        XCTAssertNotEqual(first.identity, second.identity)
        let call = ToolCall(id: "orphan", name: "image_generate", context: "",
                            state: .done, gatewayToolID: "wire",
                            generatedImage: try output(), provenance: .unmatchedResult)
        let result = await model.loadGeneratedImage(call, from: first)
        guard case .unavailable = result else {
            return XCTFail("A source without exact live authority must fail closed")
        }

        let rowMessage = ChatMessage(id: UUID(), author: .bot, text: "", rowID: 1)
        XCTAssertTrue(first.identifies(rowMessage))
        XCTAssertFalse(first.identifies(ChatMessage(
            id: first.messageRevisionID, author: .bot, text: "", rowID: 2)),
            "a durable row identity cannot fall back to a coincidental revision id")
    }

    func testCompletedAuthorityRequiresExactPairedCurrentEvidence() throws {
        let image = try output()
        var call = ToolCall(id: "x", name: "image_generate", context: "",
                            state: .done, gatewayToolID: "wire",
                            generatedImage: image, provenance: .stored)
        XCTAssertTrue(GeneratedImageEchoPolicy.hasSuccessfulAuthority(call))
        call.gatewayToolID = nil
        XCTAssertFalse(GeneratedImageEchoPolicy.hasSuccessfulAuthority(call))
        call.gatewayToolID = "wire"; call.provenance = .unmatchedResult
        XCTAssertFalse(GeneratedImageEchoPolicy.hasSuccessfulAuthority(call))
        call.provenance = .live; call.state = .failed
        XCTAssertFalse(GeneratedImageEchoPolicy.hasSuccessfulAuthority(call))
        call.state = .done; call.name = "Image_Generate"
        XCTAssertFalse(GeneratedImageEchoPolicy.hasSuccessfulAuthority(call))
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

    func testRasterPolicyUsesActualAllowlistAndTypedExtension() throws {
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let pngMetadata = try XCTUnwrap(GeneratedImageRasterPolicy.inspect(png))
        XCTAssertEqual(pngMetadata.format, .png)
        XCTAssertEqual(pngMetadata.format.fileExtension, "png")
        XCTAssertNil(GeneratedImageRasterPolicy.inspect(png, expectedMIME: "image/jpeg"))

        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let tiff = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            tiff, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, frame, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertEqual(CGImageSourceGetType(try XCTUnwrap(
            CGImageSourceCreateWithData(tiff as CFData, nil))) as String?, "public.tiff")
        XCTAssertNil(GeneratedImageRasterPolicy.inspect(tiff as Data))

        // A complete 1x1 32-bit ICO: directory, bitmap header, BGRA pixel,
        // and one padded AND-mask scanline. ImageIO recognizes the container,
        // while the specialist raster allowlist rejects it.
        let icoBytes: [UInt8] = [
            0,0,1,0,1,0, 1,1,0,0,1,0,32,0,48,0,0,0,22,0,0,0,
            40,0,0,0,1,0,0,0,2,0,0,0,1,0,32,0,0,0,0,0,4,0,0,0,
            0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
            0,0,255,255, 0,0,0,0,
        ]
        let ico = Data(icoBytes)
        XCTAssertNotNil(CGImageSourceCreateWithData(ico as CFData, nil))
        XCTAssertNil(GeneratedImageRasterPolicy.inspect(ico))
    }

    func testRawNamedStandaloneImageResultRemainsInertUntilInvocationPairing() throws {
        let transcript: JSONValue = ["messages": [[
            "id": 9, "role": "tool", "tool_call_id": "orphan",
            "name": "image_generate",
            "content": ["success": true, "image": "/tmp/orphan.png"],
        ]]]
        let call = try XCTUnwrap(AppModel.chatMessages(fromTranscript: transcript)
            .flatMap(\.toolCalls).first)
        XCTAssertNil(call.generatedImage)
        XCTAssertNotNil(call.deferredGeneratedImage)
        XCTAssertFalse(GeneratedImageEchoPolicy.hasSuccessfulAuthority(call))
        XCTAssertFalse(ToolRunPresentationPolicy.isGeneratedImageSpecialist(call))
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
