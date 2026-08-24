import XCTest
@testable import TalariaKit

private final class GeneratedMediaRedirectProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var observed: [URLRequest] = []
    static func reset() { lock.lock(); observed = []; lock.unlock() }
    static func requests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return observed
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.observed.append(request); Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://evil.example/steal"])!
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(
            url: URL(string: "https://evil.example/steal")!), redirectResponse: response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ManualGeneratedImageResolver: @unchecked Sendable {
    private final class Deadline: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private let action: @Sendable () -> Void

        init(action: @escaping @Sendable () -> Void) { self.action = action }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func fire() {
            lock.lock()
            let shouldFire = !cancelled
            cancelled = true
            lock.unlock()
            if shouldFire { action() }
        }
    }

    private let lock = NSLock()
    private var workers: [@Sendable () -> Void] = []
    private var deadlines: [Deadline] = []

    var workerDispatcher: RemoteGeneratedImagePolicy.WorkerDispatcher {
        { [weak self] worker in
            self?.lock.lock()
            self?.workers.append(worker)
            self?.lock.unlock()
        }
    }

    var deadlineScheduler: RemoteGeneratedImagePolicy.DeadlineScheduler {
        { [weak self] action in
            let deadline = Deadline(action: action)
            self?.lock.lock()
            self?.deadlines.append(deadline)
            self?.lock.unlock()
            return { deadline.cancel() }
        }
    }

    var workerCount: Int {
        lock.lock(); defer { lock.unlock() }
        return workers.count
    }

    func runNextWorker() {
        lock.lock()
        let worker = workers.isEmpty ? nil : workers.removeFirst()
        lock.unlock()
        worker?()
    }

    func fireNextDeadline() {
        lock.lock()
        let deadline = deadlines.isEmpty ? nil : deadlines.removeFirst()
        lock.unlock()
        deadline?.fire()
    }
}

final class GeneratedMediaTests: XCTestCase {
    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("condition did not become true")
    }

    func testExactNameObjectAndJSONStringAdmission() throws {
        let arguments = ToolPayloadCodec.arguments(from: ["aspect_ratio": "portrait"])
        let direct = try XCTUnwrap(ToolGeneratedImageCodec.admit(
            toolName: "image_generate", arguments: arguments,
            result: ["success": true, "host_image": "/tmp/host.png",
                     "image": "https://example.com/provider.png",
                     "agent_visible_image": "/sandbox/image.png"]))
        XCTAssertEqual(direct.source, "/tmp/host.png")
        XCTAssertEqual(direct.sourceKind, .gatewayPath)
        XCTAssertEqual(direct.aspect, .portrait)
        XCTAssertEqual(direct.echoSources,
                       ["/tmp/host.png", "https://example.com/provider.png",
                        "/sandbox/image.png"])

        let encoded: JSONValue = .string(
            #"{"success":true,"image":"https://example.com/image.webp"}"#)
        XCTAssertEqual(ToolGeneratedImageCodec.admit(
            toolName: "image_generate", arguments: nil, result: encoded)?.source,
            "https://example.com/image.webp")
        for wrong in ["Image_Generate", "IMAGE_GENERATE", "image.generate", "generate_image"] {
            XCTAssertNil(ToolGeneratedImageCodec.admit(
                toolName: wrong, arguments: nil, result: encoded), wrong)
        }
    }

    func testSuccessFalseMissingAndAgentVisibleOnlyStayGeneric() {
        XCTAssertNil(ToolGeneratedImageCodec.candidate(
            arguments: nil, result: ["success": false, "image": "/tmp/x.png"]))
        XCTAssertNil(ToolGeneratedImageCodec.candidate(
            arguments: nil, result: ["success": true, "error": "denied"]))
        XCTAssertNil(ToolGeneratedImageCodec.candidate(
            arguments: nil,
            result: ["success": true, "agent_visible_image": "/sandbox/x.png"]))
        XCTAssertNil(ToolGeneratedImageCodec.candidate(
            arguments: nil, result: ["image": "/tmp/missing-success.png"]))
    }

    func testSourceAdmissionRejectsControlsBidiRelativePrivateAndCredentials() {
        for source in ["relative.png", "/tmp/no-extension", "/tmp/x.svg",
                       "/tmp/x%2epng", "/tmp/x\u{0}.png", "/tmp/x\u{202E}.png",
                       "javascript:https://example.com/x.png",
                       "https://localhost/x.png", "https://127.0.0.1/x.png",
                       "https://10.2.3.4/x.png", "https://user@example.com/x.png"] {
            XCTAssertNil(ToolGeneratedImageCodec.admittedSource(source), source)
        }
        XCTAssertEqual(ToolGeneratedImageCodec.admittedSource("~/images/x.png")?.kind,
                       .gatewayPath)
        XCTAssertEqual(ToolGeneratedImageCodec.admittedSource("C:\\images\\x.jpg")?.kind,
                       .gatewayPath)
        XCTAssertEqual(ToolGeneratedImageCodec.admittedSource(
            "https://cdn.example/x.png")?.kind, .remoteURL)
        XCTAssertNil(ToolGeneratedImageCodec.admittedSource(
            "https://cdn.example/%0Aspoof.png"))
        XCTAssertNil(ToolGeneratedImageCodec.admittedSource(
            "https://cdn.example\\@evil.example/x.png"))
    }

    func testToolResultInlineDataIsRejectedButGatewayEnvelopeDecodeIsBounded() {
        let tiny = "data:image/png;base64,iVBORw0KGgo="
        XCTAssertNil(ToolGeneratedImageCodec.admittedSource(tiny))
        XCTAssertNotNil(ToolGeneratedImageCodec.inlineDataDecodedUpperBound(tiny),
                        "authenticated /api/media still returns a bounded data URL envelope")
        for invalid in ["data:image/svg+xml;base64,PHN2Zz4=",
                        "data:image/png,abc", "data:image/png;base64,abc!",
                        "data:text/plain;base64,eA=="] {
            XCTAssertNil(ToolGeneratedImageCodec.admittedSource(invalid), invalid)
        }
        let oversized = "data:image/png;base64,"
            + String(repeating: "A", count: ((ToolGeneratedImageCodec.maximumInlineDecodedBytes + 2) / 3) * 4 + 4)
        XCTAssertNil(ToolGeneratedImageCodec.admittedSource(oversized))
    }

    func testCodableReadmissionKeepsDeferredCandidateInert() throws {
        let candidate = try XCTUnwrap(ToolGeneratedImageCodec.candidate(
            arguments: nil, result: ["success": true, "image": "/tmp/x.png"]))
        var call = ToolCall(id: "x", name: "Tool", context: "", state: .done,
                            gatewayToolID: "x", deferredGeneratedImage: candidate)
        call = try JSONDecoder().decode(ToolCall.self, from: JSONEncoder().encode(call))
        XCTAssertNil(call.generatedImage)
        XCTAssertEqual(call.deferredGeneratedImage, candidate)

        let hostile = #"{"source":"relative.png","sourceKind":"gatewayPath","aspect":"square","echoSources":[]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(
            ToolGeneratedImage.self, from: Data(hostile.utf8)))
    }

    func testToolCompletePayloadKeepsEveryUnpairedCompletionDeferred() {
        let result: JSONValue = ["success": true, "image": "/tmp/x.png"]
        let nameless = ToolCompletePayload(["tool_id": "X", "result": result])
        XCTAssertNil(nameless.generatedImage)
        XCTAssertNotNil(nameless.deferredGeneratedImage)

        let exact = ToolCompletePayload([
            "tool_id": "X", "name": "image_generate", "result": result,
        ])
        XCTAssertNil(exact.generatedImage)
        XCTAssertNotNil(exact.deferredGeneratedImage)

        let other = ToolCompletePayload([
            "tool_id": "X", "name": "terminal", "result": result,
        ])
        XCTAssertNil(other.generatedImage)
        XCTAssertNil(other.deferredGeneratedImage)
    }

    func testEchoSuppressionRequiresExactSuccessfulAuthority() throws {
        let output = try XCTUnwrap(ToolGeneratedImageCodec.candidate(
            arguments: nil,
            result: ["success": true, "host_image": "/host/cat.png",
                     "agent_visible_image": "/sandbox/cat.png"]))
        let base = ToolCall(id: "x", name: "image_generate", context: "", state: .done,
                            gatewayToolID: "wire", generatedImage: output, provenance: .stored)
        let text = "Here. ![other](/unrelated/provider.png) "
            + "![cat](/host/cat.png) [media](#media:%2Fsandbox%2Fcat.png) "
            + "/sandbox/cat.png Done."
        XCTAssertEqual(GeneratedImageEchoPolicy.suppress(in: text, calls: [base]),
                       "Here. ![other](/unrelated/provider.png)    Done.")
        var failed = base; failed.state = .failed
        XCTAssertEqual(GeneratedImageEchoPolicy.suppress(in: text, calls: [failed]), text)
        var orphan = base; orphan.provenance = .unmatchedResult
        XCTAssertEqual(GeneratedImageEchoPolicy.suppress(in: text, calls: [orphan]), text)
    }

    func testRemoteHostPolicyRejectsPrivateRanges() {
        for host in ["localhost", "x.local", "0.1.2.3", "127.0.0.1",
                     "169.254.1.2", "172.16.0.1", "192.168.1.1", "::1",
                     "fe80::1", "fd00::1", "::ffff:127.0.0.1", "2130706433"] {
            XCTAssertFalse(RemoteGeneratedImagePolicy.hostIsPublic(host), host)
        }
        XCTAssertTrue(RemoteGeneratedImagePolicy.hostIsPublic("cdn.example.com"))
        XCTAssertTrue(RemoteGeneratedImagePolicy.hostIsPublic("fcdn.example.com"))
        XCTAssertTrue(RemoteGeneratedImagePolicy.hostIsPublic("127.0.0.1.example.com"))
        XCTAssertTrue(RemoteGeneratedImagePolicy.hostIsPublic("8.8.8.8"))
    }

    func testRemoteHostPolicyRejectsLegacyLiteralsAndResolvedPrivateAddresses() async {
        for host in ["0177.0.0.1", "0x7f000001", "127.1", "127.0.1",
                     "4294967295", "::ffff:7f00:1", "fe80::1%en0"] {
            XCTAssertFalse(RemoteGeneratedImagePolicy.hostIsPublic(host), host)
        }
        let privateResolver: RemoteGeneratedImagePolicy.Resolver = { _ in
            [.ipv4(93, 184, 216, 34), .ipv4(10, 0, 0, 1)]
        }
        let rejected = await RemoteGeneratedImagePolicy.resolvedHostIsPublic(
            "cdn.example.com", resolver: privateResolver)
        XCTAssertFalse(rejected)
        let publicResolver: RemoteGeneratedImagePolicy.Resolver = { _ in
            [.ipv4(93, 184, 216, 34), .ipv6([
                0x26, 0x06, 0x28, 0x00, 0x02, 0x20, 0, 1,
                0x02, 0x48, 0x18, 0x93, 0x25, 0xc8, 0x19, 0x46,
            ])]
        }
        let admitted = await RemoteGeneratedImagePolicy.resolvedHostIsPublic(
            "cdn.example.com", resolver: publicResolver)
        XCTAssertTrue(admitted)
        let oversizedResolver: RemoteGeneratedImagePolicy.Resolver = { _ in
            Array(repeating: .ipv4(93, 184, 216, 34),
                  count: RemoteGeneratedImagePolicy.maximumResolvedAddresses + 1)
        }
        let oversized = await RemoteGeneratedImagePolicy.resolvedHostIsPublic(
            "cdn.example.com", resolver: oversizedResolver)
        XCTAssertFalse(oversized)
        XCTAssertFalse(RemoteGeneratedImagePolicy.addressIsPublic(
            .ipv6(Array(repeating: 0, count: 10) + [0xff, 0xff, 127, 0, 0, 1])))

        do {
            _ = try await GeneratedRemoteImageLoader.load(
                URL(string: "https://cdn.example.com/image.png")!,
                resolver: privateResolver)
            XCTFail("the loader must reject DNS answers before opening a request")
        } catch let error as GatewayError {
            XCTAssertEqual(error.code, 403)
        } catch {
            XCTFail("unexpected DNS rejection error: \(error)")
        }
    }

    func testBlockingResolverTimeoutCancellationSaturationAndLateRelease() async {
        XCTAssertEqual(RemoteGeneratedImagePolicy.maximumBlockingResolvers, 2)
        XCTAssertEqual(RemoteGeneratedImagePolicy.resolverDeadlineSeconds, 2)
        let answer: [RemoteGeneratedImagePolicy.ResolvedAddress] = [
            .ipv4(93, 184, 216, 34),
        ]

        do {
            let gate = RemoteGeneratedImagePolicy.ResolutionGate(limit: 1)
            let harness = ManualGeneratedImageResolver()
            let task = Task {
                await RemoteGeneratedImagePolicy.boundedResolve(
                    host: "timeout.example", gate: gate,
                    blockingResolver: { _ in answer },
                    workerDispatcher: harness.workerDispatcher,
                    deadlineScheduler: harness.deadlineScheduler)
            }
            await waitUntil { harness.workerCount == 1 }
            XCTAssertEqual(gate.activeCountForTesting, 1)
            harness.fireNextDeadline()
            let timedOut = await task.value
            XCTAssertNil(timedOut, "deadline must return without waiting on the worker")
            XCTAssertEqual(gate.activeCountForTesting, 1,
                           "the OS resolver owns its slot until it actually returns")
            harness.runNextWorker()
            XCTAssertEqual(gate.activeCountForTesting, 0)
            let afterLateCompletion = await task.value
            XCTAssertNil(afterLateCompletion, "late completion must not resume twice")
        }

        do {
            let gate = RemoteGeneratedImagePolicy.ResolutionGate(limit: 1)
            let harness = ManualGeneratedImageResolver()
            let task = Task {
                await RemoteGeneratedImagePolicy.boundedResolve(
                    host: "cancel.example", gate: gate,
                    blockingResolver: { _ in answer },
                    workerDispatcher: harness.workerDispatcher,
                    deadlineScheduler: harness.deadlineScheduler)
            }
            await waitUntil { harness.workerCount == 1 }
            task.cancel()
            let cancelled = await task.value
            XCTAssertNil(cancelled, "cancellation must return without waiting on the worker")
            XCTAssertEqual(gate.activeCountForTesting, 1)
            harness.runNextWorker()
            XCTAssertEqual(gate.activeCountForTesting, 0)
            harness.fireNextDeadline()
            let afterCancelledCompletion = await task.value
            XCTAssertNil(afterCancelledCompletion)
        }

        do {
            let gate = RemoteGeneratedImagePolicy.ResolutionGate(limit: 2)
            let harness = ManualGeneratedImageResolver()
            func resolve(_ host: String) -> Task<[
                RemoteGeneratedImagePolicy.ResolvedAddress
            ]?, Never> {
                Task {
                    await RemoteGeneratedImagePolicy.boundedResolve(
                        host: host, gate: gate,
                        blockingResolver: { _ in answer },
                        workerDispatcher: harness.workerDispatcher,
                        deadlineScheduler: harness.deadlineScheduler)
                }
            }
            let first = resolve("one.example")
            let second = resolve("two.example")
            await waitUntil { harness.workerCount == 2 }
            XCTAssertEqual(gate.activeCountForTesting, 2)
            let saturated = resolve("three.example")
            let saturatedValue = await saturated.value
            XCTAssertNil(saturatedValue)
            XCTAssertEqual(harness.workerCount, 2,
                           "saturation must not dispatch another blocking resolver")

            harness.runNextWorker()
            XCTAssertEqual(gate.activeCountForTesting, 1)
            let admittedAfterRelease = resolve("four.example")
            await waitUntil { harness.workerCount == 2 }
            XCTAssertEqual(gate.activeCountForTesting, 2)
            harness.runNextWorker()
            harness.runNextWorker()
            let firstValue = await first.value
            let secondValue = await second.value
            let admittedValue = await admittedAfterRelease.value
            XCTAssertEqual(firstValue, answer)
            XCTAssertEqual(secondValue, answer)
            XCTAssertEqual(admittedValue, answer)
            XCTAssertEqual(gate.activeCountForTesting, 0)
        }
    }

    func testCandidateAndCodableBoundsFailClosed() throws {
        var object: [String: JSONValue] = [
            "success": true, "image": "/tmp/image.png",
        ]
        for index in 0...ToolGeneratedImageCodec.maximumResultObjectFields {
            object["padding-\(index)"] = "x"
        }
        XCTAssertNil(ToolGeneratedImageCodec.candidate(
            arguments: nil, result: .object(object)))
        let hugeString = String(repeating: "x",
            count: ToolGeneratedImageCodec.maximumSerializedResultBytes + 1)
        XCTAssertNil(ToolGeneratedImageCodec.candidate(
            arguments: nil, result: .string(hugeString)))
        XCTAssertNil(ToolGeneratedImageCodec.admittedSource(
            String(repeating: " ", count: ToolGeneratedImageCodec.maximumPathOrURLBytes + 1)
                + "/tmp/x.png"))

        let tooMany = #"{"source":"/tmp/x.png","sourceKind":"gatewayPath","aspect":"square","echoSources":["a","b","c","d"]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(
            ToolGeneratedImage.self, from: Data(tooMany.utf8)))
        let hugeEcho = #"{"source":"/tmp/x.png","sourceKind":"gatewayPath","aspect":"square","echoSources":[""#
            + String(repeating: "x", count: ToolGeneratedImageCodec.maximumPathOrURLBytes + 1)
            + #""]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(
            ToolGeneratedImage.self, from: Data(hugeEcho.utf8)))
    }

    func testEchoSuppressionPreservesAllUnrelatedFormatting() throws {
        let output = try XCTUnwrap(ToolGeneratedImageCodec.candidate(
            arguments: nil,
            result: ["success": true, "image": "/tmp/exact.png"]))
        let call = ToolCall(id: "x", name: "image_generate", context: "",
                            state: .done, gatewayToolID: "wire",
                            generatedImage: output, provenance: .live)
        let text = "Intro  keeps  spaces\n\n```swift\n  let x =  2\n```\n"
            + "![exact](/tmp/exact.png)\n\nEnd"
        XCTAssertEqual(GeneratedImageEchoPolicy.suppress(in: text, calls: [call]),
                       "Intro  keeps  spaces\n\n```swift\n  let x =  2\n```\n\n\nEnd")
        let message = ChatMessage(author: .bot, text: text, toolCalls: [call])
        XCTAssertEqual(GeneratedImageEchoPolicy.suppress(in: message),
                       GeneratedImageEchoPolicy.suppress(in: text, calls: [call]))
        XCTAssertEqual(GeneratedImageEchoPolicy.suppress(
            in: "/tmp/exact.png",
            calls: Array(repeating: call,
                         count: GeneratedImageEchoPolicy.maximumCalls + 1)), "")
        XCTAssertEqual(GeneratedImageEchoPolicy.suppress(
            in: String(repeating: "x",
                       count: GeneratedImageEchoPolicy.maximumTranscriptBytes + 1)
                + "/tmp/exact.png", calls: [call]), "")
    }

    func testGatewayMediaUsesExactBoundedNoRedirectExecutor() async throws {
        actor Calls {
            var ordinary = 0
            var protected = 0
            var request: URLRequest?
            func markOrdinary() { ordinary += 1 }
            func markProtected(_ value: URLRequest) { protected += 1; request = value }
            func snapshot() -> (Int, Int, URLRequest?) { (ordinary, protected, request) }
        }
        let calls = Calls()
        let responseBody = Data(#"{"data_url":"data:image/png;base64,iVBORw0KGgo="}"#.utf8)
        let response: @Sendable (URLRequest, Int?) async throws -> (Data, URLResponse) = {
            request, _ in
            await calls.markProtected(request)
            return (responseBody, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!)
        }
        let client = GatewayClient(
            baseURL: URL(string: "https://gateway.example/base")!,
            credential: .sessionToken("secret"),
            restExecutor: { request, _ in
                await calls.markOrdinary()
                return (Data(), HTTPURLResponse(
                    url: request.url!, statusCode: 500, httpVersion: nil,
                    headerFields: nil)!)
            },
            noRedirectRESTExecutor: response)
        let loaded = try await client.generatedMediaDataURL(path: "/tmp/cat.png")
        XCTAssertEqual(loaded, "data:image/png;base64,iVBORw0KGgo=")
        let snapshot = await calls.snapshot()
        XCTAssertEqual(snapshot.0, 0)
        XCTAssertEqual(snapshot.1, 1)
        XCTAssertTrue(snapshot.2?.url?.absoluteString.contains("/base/api/media") == true)
        XCTAssertEqual(snapshot.2?.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "path" })?.value
        }, "/tmp/cat.png")
        XCTAssertEqual(snapshot.2?.value(forHTTPHeaderField: "X-Hermes-Session-Token"),
                       "secret")
    }

    func testAssistantMediaBytesUseExactBoundedNoRedirectExecutor() async throws {
        actor Calls {
            var ordinary = 0
            var protected = 0
            var request: URLRequest?
            func markOrdinary() { ordinary += 1 }
            func markProtected(_ value: URLRequest) { protected += 1; request = value }
        }
        let calls = Calls()
        let body = Data("audio".utf8)
        let client = GatewayClient(
            baseURL: URL(string: "https://gateway.example/base")!,
            credential: .sessionToken("secret"),
            restExecutor: { request, _ in
                await calls.markOrdinary()
                return (Data(), HTTPURLResponse(
                    url: request.url!, statusCode: 500, httpVersion: nil,
                    headerFields: nil)!)
            },
            noRedirectRESTExecutor: { request, limit in
                await calls.markProtected(request)
                XCTAssertEqual(limit, 40 * 1_024 * 1_024)
                return (body, HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "audio/mpeg"])!)
            })
        let loaded = try await client.restDataResponseBoundedNoRedirect(
            path: "api/files/stream",
            query: [URLQueryItem(name: "path", value: "/tmp/voice.mp3")],
            maximumResponseBytes: 40 * 1_024 * 1_024)
        XCTAssertEqual(loaded.0, body)
        XCTAssertEqual((loaded.1 as? HTTPURLResponse)?.mimeType, "audio/mpeg")
        let ordinary = await calls.ordinary
        let protected = await calls.protected
        let request = await calls.request
        XCTAssertEqual(ordinary, 0)
        XCTAssertEqual(protected, 1)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "X-Hermes-Session-Token"),
                       "secret")
        XCTAssertEqual(request?.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "path" })?.value
        }, "/tmp/voice.mp3")
    }

    func testAssistantManagedImageAndFileUseReadRouteWithMIMEAndDecodedBound() async throws {
        actor Capture {
            var request: URLRequest?
            var limit: Int?
            func set(_ request: URLRequest, _ limit: Int?) {
                self.request = request; self.limit = limit
            }
        }
        let capture = Capture()
        let bytes = Data("document".utf8)
        let encoded = bytes.base64EncodedString()
        let body = Data(("{\"name\":\"report.pdf\",\"path\":\"/tmp/report.pdf\","
            + "\"size\":8,\"mime_type\":\"application/pdf\","
            + "\"data_url\":\"data:application/pdf;base64,\(encoded)\"}").utf8)
        let client = GatewayClient(
            baseURL: URL(string: "https://gateway.example/base")!,
            credential: .sessionToken("secret"),
            restExecutor: { request, _ in
                (Data(), HTTPURLResponse(
                    url: request.url!, statusCode: 500, httpVersion: nil,
                    headerFields: nil)!)
            },
            noRedirectRESTExecutor: { request, limit in
                await capture.set(request, limit)
                return (body, HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!)
            })
        let loaded = try await client.assistantManagedFile(
            path: "/tmp/report.pdf", maximumDecodedBytes: 40 * 1_024 * 1_024)
        XCTAssertEqual(loaded.data, bytes)
        XCTAssertEqual(loaded.mimeType, "application/pdf")
        let request = await capture.request
        XCTAssertTrue(request?.url?.absoluteString.contains("/base/api/files/read") == true)
        XCTAssertFalse(request?.url?.absoluteString.contains("/api/files/stream") == true)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "X-Hermes-Session-Token"),
                       "secret")
        let responseLimit = await capture.limit
        XCTAssertNotNil(responseLimit)
    }

    func testAssistantManagedFileRejectsDeclaredSizeMIMEAndDecodedLengthMismatch() async throws {
        for body in [
            #"{"size":9,"mime_type":"application/pdf","data_url":"data:application/pdf;base64,ZG9jdW1lbnQ="}"#,
            #"{"size":8,"mime_type":"application/pdf","data_url":"data:text/html;base64,ZG9jdW1lbnQ="}"#,
            #"{"size":7,"mime_type":"application/pdf","data_url":"data:application/pdf;base64,ZG9jdW1lbnQ="}"#,
        ] {
            let client = GatewayClient(
                baseURL: URL(string: "https://gateway.example")!,
                credential: .sessionToken("secret"),
                restExecutor: { request, _ in
                    (Data(), HTTPURLResponse(
                        url: request.url!, statusCode: 500, httpVersion: nil,
                        headerFields: nil)!)
                },
                noRedirectRESTExecutor: { request, _ in
                    (Data(body.utf8), HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!)
                })
            do {
                _ = try await client.assistantManagedFile(
                    path: "/tmp/report.pdf", maximumDecodedBytes: 8)
                XCTFail("malformed managed media must fail")
            } catch {}
        }
    }

    func testNoRedirectTransportDoesNotReplaySensitiveRequest() async {
        GeneratedMediaRedirectProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeneratedMediaRedirectProtocol.self]
        var request = URLRequest(url: URL(string: "https://gateway.example/api/media")!)
        request.setValue("secret", forHTTPHeaderField: "X-Hermes-Session-Token")
        _ = try? await GatewayBoundedRESTLoader.load(
            request, limit: 4_096, configuration: configuration, rejectsRedirects: true)
        let requests = GeneratedMediaRedirectProtocol.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.host, "gateway.example")
        XCTAssertFalse(requests.contains { $0.url?.host == "evil.example" })
    }

    func testRemoteAssistantMediaRejectsRedirectWithoutCredentialsOrReplay() async {
        GeneratedMediaRedirectProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeneratedMediaRedirectProtocol.self]
        let resolver: RemoteGeneratedImagePolicy.Resolver = { _ in
            [.ipv4(93, 184, 216, 34)]
        }
        do {
            _ = try await RemoteAssistantMediaLoader.load(
                URL(string: "https://cdn.example.com/voice.mp3")!,
                maximumBytes: 4_096, resolver: resolver,
                configuration: configuration)
            XCTFail("redirecting remote media must fail")
        } catch {}
        let requests = GeneratedMediaRedirectProtocol.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.host, "cdn.example.com")
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "X-Hermes-Session-Token"))
    }
}
