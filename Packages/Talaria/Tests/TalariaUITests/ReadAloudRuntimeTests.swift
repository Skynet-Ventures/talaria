#if canImport(XCTest)
import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

private actor ReadAloudRequestProbe {
    struct Record: Sendable {
        let request: URLRequest
        let limit: Int?
        let noRedirect: Bool
    }
    private var records: [Record] = []

    func execute(_ request: URLRequest, limit: Int?, noRedirect: Bool,
                 payload: JSONValue) async throws -> (Data, URLResponse) {
        records.append(Record(request: request, limit: limit, noRedirect: noRedirect))
        let data = try JSONEncoder().encode(payload)
        return (data, HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!)
    }

    func snapshot() -> [Record] { records }
}

@MainActor
final class ReadAloudRuntimeTests: XCTestCase {
    func testMessageAuthorityRejectsEveryIdentityAndTextMutationCollision() throws {
        let route = GatewayBotRoute(gatewayID: "mini", profile: "worker")
        let message = ChatMessage(id: UUID(), author: .bot, text: "Visible answer.")
        let chatID = UUID()
        let authority = ReadAloudMessageAuthority(
            botID: route.qualifiedID, chatID: chatID, messageID: message.id,
            preparedText: try XCTUnwrap(ReadAloudPolicy.preparedText(for: message)),
            route: route)

        XCTAssertTrue(authority.accepts(
            botID: route.qualifiedID, chatID: chatID, message: message, route: route))
        XCTAssertFalse(authority.accepts(
            botID: "other", chatID: chatID, message: message, route: route))
        XCTAssertFalse(authority.accepts(
            botID: route.qualifiedID, chatID: UUID(), message: message, route: route))
        XCTAssertFalse(authority.accepts(
            botID: route.qualifiedID, chatID: chatID,
            message: ChatMessage(id: UUID(), author: .bot, text: message.text), route: route))
        XCTAssertFalse(authority.accepts(
            botID: route.qualifiedID, chatID: chatID,
            message: ChatMessage(id: message.id, author: .bot, text: "mutated"), route: route))
        XCTAssertFalse(authority.accepts(
            botID: route.qualifiedID, chatID: chatID, message: message,
            route: GatewayBotRoute(gatewayID: "other", profile: "worker")))
        XCTAssertFalse(authority.accepts(
            botID: route.qualifiedID, chatID: chatID, message: message,
            route: GatewayBotRoute(gatewayID: "mini", profile: "other")))
        var streaming = message
        streaming.isStreaming = true
        XCTAssertFalse(authority.accepts(
            botID: route.qualifiedID, chatID: chatID, message: streaming, route: route))
    }

    func testStopAndNewReadInvalidateEveryStaleCompletion() {
        var fence = ReadAloudLeaseFence()
        let first = UUID()
        let firstGeneration = fence.begin(first)
        XCTAssertTrue(fence.accepts(id: first, generation: firstGeneration))
        fence.invalidate()
        XCTAssertFalse(fence.accepts(id: first, generation: firstGeneration))

        let second = UUID()
        let secondGeneration = fence.begin(second)
        XCTAssertFalse(fence.accepts(id: first, generation: firstGeneration))
        XCTAssertTrue(fence.accepts(id: second, generation: secondGeneration))
        XCTAssertFalse(fence.accepts(id: second, generation: firstGeneration))
    }

    func testSourceAuthorityRejectsReconnectLifecycleAndGatewayProfileCollisions() {
        let client = GatewayClient(
            baseURL: URL(string: "https://one.example")!,
            credential: .sessionToken("one"))
        let otherClient = GatewayClient(
            baseURL: URL(string: "https://two.example")!,
            credential: .sessionToken("two"))
        let route = GatewayBotRoute(gatewayID: "gateway-a", profile: "default")
        let proof = ReadAloudSourceAuthority(
            route: route, clientIdentity: ObjectIdentifier(client),
            connectionGeneration: .primary(7), profileLifecycleGeneration: 3)
        func accepts(route candidateRoute: GatewayBotRoute = route,
                     client candidateClient: GatewayClient = client,
                     connection: ReadAloudSourceAuthority.ConnectionGeneration = .primary(7),
                     lifecycle: UInt64 = 3) -> Bool {
            proof.accepts(
                route: candidateRoute, clientIdentity: ObjectIdentifier(candidateClient),
                connectionGeneration: connection,
                profileLifecycleGeneration: lifecycle)
        }
        XCTAssertTrue(accepts())
        XCTAssertFalse(accepts(client: otherClient))
        XCTAssertFalse(accepts(connection: .primary(8)))
        XCTAssertFalse(accepts(connection: .pooled(7)))
        XCTAssertFalse(accepts(lifecycle: 4))
        XCTAssertFalse(accepts(route: GatewayBotRoute(
            gatewayID: "gateway-b", profile: "default")))
        XCTAssertFalse(accepts(route: GatewayBotRoute(
            gatewayID: "gateway-a", profile: "worker")))
    }

    func testOnePhoneAudioOwnerAndVoiceArbitration() throws {
        let coordinator = MobileAudioOwnership.shared
        if let existing = coordinator.owner { coordinator.release(existing) }
        let read = try XCTUnwrap(coordinator.acquire(.readAloud))
        XCTAssertNil(coordinator.acquire(.voiceSession))
        XCTAssertFalse(coordinator.release(
            MobileAudioOwnership.Lease(id: UUID(), kind: .readAloud)))
        XCTAssertEqual(coordinator.owner, read, "a stale stop cannot release the active owner")
        XCTAssertTrue(coordinator.release(read))
        let voice = try XCTUnwrap(coordinator.acquire(.voiceSession))
        XCTAssertNil(coordinator.acquire(.readAloud))
        coordinator.release(voice)
        XCTAssertNil(coordinator.owner)
    }

    func testCompactControlLabelsAreExplicitAndBounded() {
        XCTAssertEqual(ReadAloudPresentation.minimumControlHeight, 44)
        XCTAssertEqual(ReadAloudPresentation.controlLabel(.preparing),
                       "Preparing audio — Stop")
        XCTAssertEqual(ReadAloudPresentation.controlLabel(.speaking),
                       "Stop reading aloud")
        XCTAssertTrue(ReadAloudPresentation.accessibilityHint(.preparing).contains("Cancels"))
        XCTAssertTrue(ReadAloudPresentation.accessibilityHint(.speaking).contains("immediately"))
    }

    func testSynthesisUsesExactProfileBodyAuthBoundAndNoRedirectTransport() async throws {
        let probe = ReadAloudRequestProbe()
        let audio = Data("audio".utf8)
        let payload: JSONValue = [
            "data_url": .string("data:audio/mpeg;base64,\(audio.base64EncodedString())"),
            "mime_type": .string("audio/mpeg"),
            "provider": .string("test"),
        ]
        let client = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://gateway.example/base/")),
            credential: .sessionToken("top-secret"),
            restExecutor: { request, limit in
                try await probe.execute(
                    request, limit: limit, noRedirect: false, payload: payload)
            },
            noRedirectRESTExecutor: { request, limit in
                try await probe.execute(
                    request, limit: limit, noRedirect: true, payload: payload)
            })

        let result = try await client.synthesizeSpeech(
            text: "Only this visible prose.", profile: "worker one")
        XCTAssertEqual(result.data, audio)
        let records = await probe.snapshot()
        let record = try XCTUnwrap(records.only)
        XCTAssertTrue(record.noRedirect)
        XCTAssertEqual(record.limit, GatewayClient.maximumSpeechResponseBytes)
        XCTAssertEqual(record.request.httpMethod, "POST")
        XCTAssertEqual(record.request.url?.absoluteString,
                       "https://gateway.example/base/api/audio/speak?profile=worker%20one")
        XCTAssertEqual(record.request.value(forHTTPHeaderField: "X-Hermes-Session-Token"),
                       "top-secret")
        let body = try XCTUnwrap(record.request.httpBody)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: body),
                       ["text": .string("Only this visible prose.")])
    }

    func testAudioDecoderRejectsMalformedOversizeAndMIMEConfusion() {
        XCTAssertNil(GatewayClient.decodeDataURL("https://example/audio.mp3"))
        XCTAssertNil(GatewayClient.decodeDataURL("data:text/plain;base64,QQ=="))
        XCTAssertNil(GatewayClient.decodeDataURL("data:audio/mpeg,QQ=="))
        XCTAssertNil(GatewayClient.decodeDataURL("data:audio/mpeg;base64,QQ$="))
        XCTAssertNil(GatewayClient.decodeDataURL(
            "data:audio/mpeg;base64,QUJDREVGRw==", maximumDecodedBytes: 4))
        let valid = GatewayClient.decodeDataURL(
            "data:audio/wav;base64,QUJDRA==", maximumDecodedBytes: 4)
        XCTAssertEqual(valid?.data, Data("ABCD".utf8))
        XCTAssertEqual(valid?.mimeType, "audio/wav")
    }

    func testDeclaredMIMECannotOverrideDataURLMIME() async throws {
        let payload: JSONValue = [
            "data_url": .string("data:audio/mpeg;base64,QQ=="),
            "mime_type": .string("audio/wav"),
        ]
        let client = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://gateway.example")),
            credential: .sessionToken("token"),
            restExecutor: { request, _ in
                let data = try JSONEncoder().encode(payload)
                return (data, HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: nil)!)
            })
        do {
            _ = try await client.synthesizeSpeech(text: "hello", profile: "default")
            XCTFail("MIME confusion must fail closed")
        } catch let error as GatewayError {
            XCTAssertTrue(error.message.contains("inconsistent"))
            XCTAssertFalse(error.message.contains("token"))
        }
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
#endif
