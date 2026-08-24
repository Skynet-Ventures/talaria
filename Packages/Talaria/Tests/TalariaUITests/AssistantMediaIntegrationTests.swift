import XCTest
@testable import TalariaKit
@testable import TalariaUI

private actor AssistantMediaRequestCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

@MainActor
final class AssistantMediaIntegrationTests: XCTestCase {
    func testSourceAdmissionMIMEAndPresentationPolicies() throws {
        XCTAssertEqual(AssistantMediaPresentationPolicy.minimumInteractiveDimension, 44)
        XCTAssertFalse(AssistantMediaPresentationPolicy.automaticallyStartsPlayback)
        XCTAssertTrue(AssistantMediaPresentationPolicy.pausesWhenInactive)
        XCTAssertTrue(AssistantMediaPresentationPolicy.accessibilityAnnouncements)

        let local = try XCTUnwrap(AssistantMediaSourcePolicy.admit("/tmp/voice.mp3"))
        XCTAssertEqual(local.presentationKind, .audio)
        XCTAssertEqual(local.displayName, "voice.mp3")
        XCTAssertEqual(local.location, .gatewayPath("/tmp/voice.mp3"))
        let remote = try XCTUnwrap(AssistantMediaSourcePolicy.admit(
            "https://cdn.example.com/movie.mp4?token=x"))
        XCTAssertEqual(remote.presentationKind, .video)
        XCTAssertEqual(remote.displayName, "movie.mp4")
        XCTAssertEqual(remote.location, .remoteURL(
            URL(string: "https://cdn.example.com/movie.mp4?token=x")!))
        XCTAssertEqual(AssistantMediaSourcePolicy.admit("/tmp/vector.svg")?.presentationKind,
                       .file, "SVG must never enter the inline raster decoder")

        for rejected in ["relative.mp3", "/", "file:///", "https://user:pass@example.com/a.mp3",
                         "http://127.0.0.1/a.mp3", "data:audio/mpeg;base64,AAAA",
                         "/tmp/bad\u{202e}.mp3"] {
            XCTAssertNil(AssistantMediaSourcePolicy.admit(rejected), rejected)
        }
        XCTAssertTrue(AssistantMediaSourcePolicy.responseMIMEIsAllowed("audio/mpeg", for: .audio))
        XCTAssertFalse(AssistantMediaSourcePolicy.responseMIMEIsAllowed("text/html", for: .audio))
        XCTAssertFalse(AssistantMediaSourcePolicy.responseMIMEIsAllowed("text/html", for: .file))
    }

    func testSourceIdentityIsRouteSessionMessageAndDirectiveQualified() throws {
        let model = AppModel()
        let text = "one MEDIA: /tmp/a.mp3\ntwo MEDIA: /tmp/a.mp3\n"
        let references = AssistantMediaProjection.project(text).references
        XCTAssertEqual(references.count, 2)
        let first = AssistantMediaPresentationSource(
            model: model, botID: "A",
            route: GatewayBotRoute(gatewayID: "gateway", profile: "worker"),
            storedSessionID: "stored", liveSessionID: "live", messageRowID: 1,
            messageRevisionID: UUID(), visibleMessageText: text, reference: references[0])
        let second = AssistantMediaPresentationSource(
            model: model, botID: "A",
            route: GatewayBotRoute(gatewayID: "gateway", profile: "worker"),
            storedSessionID: "stored", liveSessionID: "live", messageRowID: 1,
            messageRevisionID: UUID(), visibleMessageText: text, reference: references[1])
        XCTAssertNotEqual(first.identity, second.identity)
    }

    func testFindIndexesOrderedProseRunsButNeverDirectivePaths() throws {
        let message = ChatMessage(
            author: .bot,
            text: "Before needle\n\nMEDIA: /tmp/private-needle.png\n\nAfter needle",
            rowID: 4)
        let index = try TranscriptFindPolicy.makeIndex(messages: [message])
        XCTAssertEqual(try TranscriptFindPolicy.search("needle", in: index).total, 2)
        XCTAssertEqual(try TranscriptFindPolicy.search("private-needle", in: index).total, 0)
        XCTAssertGreaterThanOrEqual(index.entries.first?.segments.count ?? 0, 2,
                                    "text on either side of a card stays independently addressable")
    }

    func testMutationAfterTranscriptAuthorityCapturePreventsMediaRequest() async throws {
        let registry = ConnectionRegistry.shared
        let live = LiveRuntime.shared
        let events = MultiGatewayRuntime.shared
        let oldGateway = live.gatewayID
        let oldBaseURL = live.baseURL
        let oldGeneration = live.generation
        let nonce = UUID().uuidString
        let url = try XCTUnwrap(URL(string: "https://media-authority-\(nonce).example"))
        let credential = GatewayCredential.sessionToken("media-authority-\(nonce)")
        let gateway = try XCTUnwrap(registry.upsert(
            urlString: url.absoluteString, name: "Media authority", credential: credential))
        registry.setCredentialForTesting(credential, for: gateway)
        let requests = AssistantMediaRequestCounter()
        let executor: @Sendable (URLRequest, Int?) async throws -> (Data, URLResponse) = {
            request, _ in
            await requests.record()
            return (Data(), HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil,
                headerFields: nil)!)
        }
        let client = GatewayClient(
            baseURL: try XCTUnwrap(gateway.baseURL), credential: credential,
            restExecutor: executor, noRedirectRESTExecutor: executor)
        await registry.clientPool.adopt(client, for: gateway.id)
        let route = GatewayBotRoute(gatewayID: gateway.id, profile: "worker")
        let botID = route.qualifiedID
        let pump = Task<Void, Never> {}
        let oldEvents = events.routedEvents[gateway.id]
        let oldEventGeneration = events.routedEventGenerations[gateway.id]
        defer {
            AssistantMediaRuntime.shared.afterTranscriptAuthorityCaptureForTesting = nil
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
        events.routedEventGenerations[gateway.id] = 71
        events.routedEvents[gateway.id] = MultiGatewayRuntime.RoutedEvents(
            client: client, handlerID: UUID(), pump: pump, generation: 71)

        let model = AppModel()
        model.mode = .live
        let text = "Listen: MEDIA: /tmp/voice.mp3\n"
        let message = ChatMessage(author: .bot, text: text, rowID: 9)
        let chat = ChatState(messages: [message])
        chat.storedSessionID = "stored"
        chat.sessionID = "live"
        model.chats[botID] = chat
        let reference = try XCTUnwrap(AssistantMediaProjection.project(text).references.first)
        let source = AssistantMediaPresentationSource(
            model: model, botID: botID, route: route,
            storedSessionID: "stored", liveSessionID: "live",
            messageRowID: 9, messageRevisionID: message.id,
            visibleMessageText: text, reference: reference)
        var hookRan = false
        AssistantMediaRuntime.shared.afterTranscriptAuthorityCaptureForTesting = {
            hookRan = true
            chat.messages[0].text = "The directive was removed."
        }

        let result = await model.loadAssistantMedia(from: source)
        guard case .unavailable = result else {
            return XCTFail("mutated exact directive must fail closed")
        }
        XCTAssertTrue(hookRan)
        let requestCount = await requests.count
        XCTAssertEqual(requestCount, 0,
                       "the post-await synchronous proof must precede request dispatch")
        model.clearProfileLifecycleRouteForTesting(route)
        await registry.clientPool.disconnect(gatewayID: gateway.id)
    }
}
