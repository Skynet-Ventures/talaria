#if canImport(XCTest)
import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

private actor ArtifactBodyGate {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        await withCheckedContinuation { waiters.append($0) }
    }

    func hasEntered() -> Bool { entered }

    func release() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private func artifactBodyEventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<2_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

private actor ArtifactBodyConnectorCounter {
    private var calls = 0
    func record() { calls += 1 }
    func value() -> Int { calls }
}

private actor ArtifactBodyRESTServer {
    struct RequestRecord: Sendable {
        var path: String
        var method: String?
        var requestedPath: String?
        var responseLimit: Int?
        var sessionToken: String?
    }

    private var rootPayload: JSONValue
    private var bodyPayload: JSONValue
    private var rootGate: ArtifactBodyGate?
    private var bodyGate: ArtifactBodyGate?
    private var bodyFailures = 0
    private var records: [RequestRecord] = []

    init(root: JSONValue, body: JSONValue) {
        rootPayload = root
        bodyPayload = body
    }

    func setRoot(_ value: JSONValue) { rootPayload = value }
    func setBody(_ value: JSONValue) { bodyPayload = value }
    func blockRoot(on gate: ArtifactBodyGate?) { rootGate = gate }
    func blockBody(on gate: ArtifactBodyGate?) { bodyGate = gate }
    func failNextBodyReads(_ count: Int) { bodyFailures = max(0, count) }

    func requests() -> [RequestRecord] { records }

    func execute(_ request: URLRequest, responseLimit: Int?) async throws
        -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        records.append(RequestRecord(
            path: path,
            method: request.httpMethod,
            requestedPath: request.url.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "path" })?.value
            },
            responseLimit: responseLimit,
            sessionToken: request.value(forHTTPHeaderField: "X-Hermes-Session-Token")
        ))
        let isBody = path.hasSuffix("/api/files/read")
        if isBody, let gate = bodyGate { await gate.wait() }
        if !isBody, let gate = rootGate { await gate.wait() }
        if isBody, bodyFailures > 0 {
            bodyFailures -= 1
            throw URLError(.timedOut)
        }
        let payload = isBody ? bodyPayload : rootPayload
        let data = try JSONEncoder().encode(payload)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json",
                "Content-Length": String(data.count),
            ])!
        return (data, response)
    }
}

private final class ArtifactBodyBoundedURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode {
        case declared(length: Int, chunks: [Data])
        case cumulative(chunks: [Data])
    }

    private static let stateLock = NSLock()
    private static var mode: Mode = .cumulative(chunks: [])
    private static var deliveredChunks = 0
    private static var wasStopped = false

    private let instanceLock = NSLock()
    private var stopped = false

    static func reset(_ next: Mode) {
        stateLock.lock()
        mode = next
        deliveredChunks = 0
        wasStopped = false
        stateLock.unlock()
    }

    static func state() -> (delivered: Int, stopped: Bool) {
        stateLock.lock(); defer { stateLock.unlock() }
        return (deliveredChunks, wasStopped)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.stateLock.lock()
        let mode = Self.mode
        Self.stateLock.unlock()
        let headers: [String: String]
        let chunks: [Data]
        switch mode {
        case .declared(let length, let values):
            headers = ["Content-Type": "application/json",
                       "Content-Length": String(length)]
            chunks = values
        case .cumulative(let values):
            headers = ["Content-Type": "application/json"]
            chunks = values
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        deliver(chunks, index: 0)
    }

    override func stopLoading() {
        instanceLock.lock()
        stopped = true
        instanceLock.unlock()
        Self.stateLock.lock()
        Self.wasStopped = true
        Self.stateLock.unlock()
    }

    private func deliver(_ chunks: [Data], index: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self else { return }
            self.instanceLock.lock()
            let stopped = self.stopped
            self.instanceLock.unlock()
            guard !stopped else { return }
            guard index < chunks.count else {
                self.client?.urlProtocolDidFinishLoading(self)
                return
            }
            Self.stateLock.lock()
            Self.deliveredChunks += 1
            Self.stateLock.unlock()
            self.client?.urlProtocol(self, didLoad: chunks[index])
            self.deliver(chunks, index: index + 1)
        }
    }
}

private final class ArtifactBodyBoundedLifetimeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var created = 0
    private var completed = 0
    private var released = 0

    var observer: GatewayBoundedRESTLifetimeObserver {
        GatewayBoundedRESTLifetimeObserver(
            didCreate: { [weak self] in self?.recordCreated() },
            didComplete: { [weak self] in self?.recordCompleted() },
            didRelease: { [weak self] in self?.recordReleased() }
        )
    }

    func snapshot() -> (created: Int, completed: Int, released: Int) {
        lock.lock(); defer { lock.unlock() }
        return (created, completed, released)
    }

    private func recordCreated() {
        lock.lock(); created += 1; lock.unlock()
    }

    private func recordCompleted() {
        lock.lock(); completed += 1; lock.unlock()
    }

    private func recordReleased() {
        lock.lock(); released += 1; lock.unlock()
    }
}

@MainActor
final class ArtifactBodyAuthorityTests: XCTestCase {
    private struct Fixture {
        var model: AppModel
        var gateway: SavedGateway
        var client: GatewayClient
        var server: ArtifactBodyRESTServer
        var artifact: Artifact
        var source: ArtifactProvenance
        var profile: String
        var path: String
        var root: String
        var credential: GatewayCredential
    }

    private static func rootPayload(_ root: String?) -> JSONValue {
        guard let root else {
            return .object([
                "path": .string("/Users/hermes"),
                "root": .null,
                "locked_root": .null,
                "can_change_path": .bool(true),
                "entries": .array([]),
            ])
        }
        return .object([
            "path": .string(root),
            "root": .string(root),
            "locked_root": .string(root),
            "can_change_path": .bool(false),
            "entries": .array([]),
        ])
    }

    private static func bodyPayload(path: String, root: String, data: Data,
                                    mime: String = "text/plain") -> JSONValue {
        .object([
            "name": .string((path as NSString).lastPathComponent),
            "path": .string(path),
            "root": .string(root),
            "locked_root": .string(root),
            "can_change_path": .bool(false),
            "size": .number(Double(data.count)),
            "mime_type": .string(mime),
            "data_url": .string("data:\(mime);base64,\(data.base64EncodedString())"),
        ])
    }

    private func unavailable(_ body: ArtifactBody) -> ArtifactUnavailable? {
        guard case .unavailable(let reason) = body else { return nil }
        return reason
    }

    private func bodyData(_ body: ArtifactBody) -> Data? {
        body.data
    }

    private func withFixture(
        path: String = "/srv/hermes-managed/report.txt",
        data: Data = Data("retained body".utf8),
        _ operation: @MainActor (Fixture) async throws -> Void
    ) async throws {
        let registry = ConnectionRegistry.shared
        let live = LiveRuntime.shared
        let workspace = WorkspaceRuntime.shared
        let feeds = FeedsRuntime.shared
        let oldGatewayID = live.gatewayID
        let oldBaseURL = live.baseURL
        let oldGeneration = live.generation
        let oldWorkspaceGatewayID = workspace.gatewayID
        let oldWorkspaceRoots = workspace.fileRoots
        let oldWorkspaceSources = workspace.fileRootSources
        let oldArtifactSessions = feeds.artifactSessions

        ArtifactStore.shared.flush()
        ArtifactBodyRuntime.shared.beforePublicationForTesting = nil
        workspace.gatewayID = nil
        workspace.fileRoots = []
        workspace.fileRootSources = [:]

        let nonce = UUID().uuidString
        let url = try XCTUnwrap(URL(string: "https://artifact-body-\(nonce).example/base/"))
        let credential = GatewayCredential.sessionToken("artifact-body-token-\(nonce)")
        let gateway = try XCTUnwrap(registry.upsert(
            urlString: url.absoluteString,
            name: "Artifact body retained",
            credential: credential
        ))
        let oldSecondaryRoster = registry.secondaryRosters[gateway.id]
        registry.setCredentialForTesting(credential, for: gateway)
        let root = "/srv/hermes-managed"
        let server = ArtifactBodyRESTServer(
            root: Self.rootPayload(root),
            body: Self.bodyPayload(path: path, root: root, data: data)
        )
        let client = GatewayClient(
            baseURL: try XCTUnwrap(gateway.baseURL), credential: credential,
            restExecutor: { request, limit in
                try await server.execute(request, responseLimit: limit)
            }
        )
        await registry.clientPool.adopt(client, for: gateway.id)

        let profile = "retained-worker"
        let retainedRoute = GatewayBotRoute(gatewayID: gateway.id, profile: profile)
        registry.setSecondaryRosterForTesting(
            SecondaryRoster(
                profiles: [SecondaryProfile(name: profile)],
                fetchedAt: Date(), freshness: .fresh),
            gatewayID: gateway.id)
        live.gatewayID = "unrelated-primary-\(nonce)"
        live.baseURL = nil
        live.generation &+= 1
        let model = AppModel()
        model.mode = .live
        model.bots = []
        XCTAssertEqual(registry.credential(for: gateway), credential,
                       "the fixture must not depend on XCTest Keychain access")
        XCTAssertFalse(model.bots.contains { $0.id == retainedRoute.qualifiedID },
                       "a retained profile must never be installed as a primary bot")
        XCTAssertTrue(model.unionRosterBots.contains { $0.id == retainedRoute.qualifiedID },
                      "the exact retained route must come from the production union roster")
        let artifact = AppModel.artifact(
            from: path,
            botID: profile,
            sessionID: "stored-session",
            sessionTitle: "Retained output",
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        model.artifacts = [artifact]
        feeds.artifactSessions[artifact.id] = SessionRef(
            gatewayID: gateway.id,
            botID: profile,
            storedID: "stored-session"
        )
        let source = try XCTUnwrap(model.artifactProvenance(artifact))
        let fixture = Fixture(
            model: model,
            gateway: gateway,
            client: client,
            server: server,
            artifact: artifact,
            source: source,
            profile: profile,
            path: path,
            root: root,
            credential: credential
        )

        var caught: Error?
        do { try await operation(fixture) } catch { caught = error }

        ArtifactBodyRuntime.shared.beforePublicationForTesting = nil
        ArtifactStore.shared.flush()
        model.clearProfileLifecycleRouteForTesting(
            GatewayBotRoute(gatewayID: gateway.id, profile: profile))
        await registry.clientPool.disconnect(gatewayID: gateway.id)
        registry.setSecondaryRosterForTesting(oldSecondaryRoster, gatewayID: gateway.id)
        registry.setCredentialForTesting(nil, for: gateway)
        if registry.saved.contains(where: { $0.id == gateway.id }) {
            registry.remove(id: gateway.id)
        }
        feeds.artifactSessions = oldArtifactSessions
        workspace.gatewayID = oldWorkspaceGatewayID
        workspace.fileRoots = oldWorkspaceRoots
        workspace.fileRootSources = oldWorkspaceSources
        live.gatewayID = oldGatewayID
        live.baseURL = oldBaseURL
        live.generation = oldGeneration
        if let caught { throw caught }
    }

    func testExactRetainedClientSucceedsWithoutActiveWorkspaceRuntime() async throws {
        try await withFixture { fixture in
            XCTAssertNil(WorkspaceRuntime.shared.gatewayID)
            XCTAssertTrue(WorkspaceRuntime.shared.fileRoots.isEmpty)

            let body = await fixture.model.loadArtifact(fixture.artifact)

            XCTAssertEqual(bodyData(body), Data("retained body".utf8))
            XCTAssertEqual(fixture.model.artifactBody(fixture.artifact)?.data,
                           Data("retained body".utf8))
            let requests = await fixture.server.requests()
            XCTAssertEqual(requests.map(\.path), ["/base/api/files", "/base/api/files/read"])
            XCTAssertEqual(requests.map(\.method), ["GET", "GET"])
            guard requests.count == 2 else {
                return XCTFail("expected one root proof and one exact body request")
            }
            let rootRequest = requests[0]
            let bodyRequest = requests[1]
            XCTAssertNil(rootRequest.requestedPath)
            XCTAssertEqual(bodyRequest.requestedPath, fixture.path)
            XCTAssertEqual(
                rootRequest.responseLimit,
                WorkspaceFileSizePolicy.maximumManagedRootResponseBytes)
            XCTAssertEqual(
                bodyRequest.responseLimit,
                WorkspaceFileSizePolicy.maximumManagedReadResponseBytes)
            guard case .sessionToken(let token) = fixture.credential else {
                return XCTFail("fixture must use session-token authentication")
            }
            XCTAssertEqual(Set(requests.compactMap(\.sessionToken)), [token],
                           "both REST calls must be authenticated by the exact retained client")
        }
    }

    func testConnectingSnapshotEnumerationOmitsSlotAndNeverStartsAnotherDial() async throws {
        let counter = ArtifactBodyConnectorCounter()
        let gate = ArtifactBodyGate()
        let url = try XCTUnwrap(URL(string: "https://artifact-connecting.example"))
        let pool = GatewayClientPool { baseURL, credential in
            await counter.record()
            await gate.wait()
            return GatewayClient(baseURL: baseURL, credential: credential)
        }
        let task = Task {
            try? await pool.connect(
                gatewayID: "connecting", baseURL: url,
                credential: .sessionToken("connecting-token"))
        }
        let connectorEntered = await artifactBodyEventually { await counter.value() == 1 }
        XCTAssertTrue(connectorEntered)
        let retained = await pool.retainedConnectionSnapshots()
        let connectorCalls = await counter.value()
        XCTAssertTrue(retained.isEmpty)
        XCTAssertEqual(connectorCalls, 1,
                       "enumerating retained sources must never dial or join the connection")

        task.cancel()
        await gate.release()
        _ = await task.value
    }

    func testNilAndFilesystemRootProofsRemainUnprovenWithoutBodyRead() async throws {
        try await withFixture { fixture in
            await fixture.server.setRoot(Self.rootPayload(nil))
            let nilRootBody = await fixture.model.loadArtifact(fixture.artifact)
            let firstRequests = await fixture.server.requests()
            XCTAssertEqual(unavailable(nilRootBody), .unproven)
            XCTAssertEqual(firstRequests.count, 1)

            ArtifactStore.shared.flush()
            await fixture.server.setRoot(Self.rootPayload("/"))
            let filesystemRootBody = await fixture.model.loadArtifact(fixture.artifact)
            let secondRequests = await fixture.server.requests()
            XCTAssertEqual(unavailable(filesystemRootBody), .unproven)
            XCTAssertEqual(secondRequests.count, 2)
        }
    }

    func testRootChangeAndReturnedPathMismatchFailClosed() async throws {
        try await withFixture { fixture in
            await fixture.server.setBody(Self.bodyPayload(
                path: fixture.path,
                root: "/srv/replacement-root",
                data: Data("wrong root".utf8)
            ))
            let wrongRootBody = await fixture.model.loadArtifact(fixture.artifact)
            XCTAssertEqual(unavailable(wrongRootBody), .unproven)

            ArtifactStore.shared.flush()
            await fixture.server.setBody(Self.bodyPayload(
                path: "\(fixture.root)/other.txt",
                root: fixture.root,
                data: Data("wrong path".utf8)
            ))
            let wrongPathBody = await fixture.model.loadArtifact(fixture.artifact)
            XCTAssertEqual(unavailable(wrongPathBody), .unproven)
        }
    }

    func testSymlinkEscapeAndSensitivePathFailClosed() async throws {
        try await withFixture { fixture in
            await fixture.server.setBody(Self.bodyPayload(
                path: "/private/outside/report.txt",
                root: fixture.root,
                data: Data("escaped".utf8)
            ))
            let escapedBody = await fixture.model.loadArtifact(fixture.artifact)
            XCTAssertEqual(unavailable(escapedBody), .unproven)
        }

        try await withFixture(path: "/srv/hermes-managed/.ssh/id_ed25519") { fixture in
            let sensitiveBody = await fixture.model.loadArtifact(fixture.artifact)
            let requests = await fixture.server.requests()
            XCTAssertEqual(unavailable(sensitiveBody), .unproven)
            XCTAssertTrue(requests.isEmpty,
                          "sensitive paths must fail before either exact-client REST request")
        }
    }

    func testReplacementDuringRootReadRejectsBodyAndCache() async throws {
        try await withFixture { fixture in
            let gate = ArtifactBodyGate()
            await fixture.server.blockRoot(on: gate)
            let task = Task { await fixture.model.loadArtifact(fixture.artifact) }
            let rootEntered = await artifactBodyEventually { await gate.hasEntered() }
            XCTAssertTrue(rootEntered)

            let replacementServer = ArtifactBodyRESTServer(
                root: Self.rootPayload(fixture.root),
                body: Self.bodyPayload(path: fixture.path, root: fixture.root,
                                       data: Data("replacement".utf8)))
            let replacement = GatewayClient(
                baseURL: fixture.gateway.baseURL!, credential: fixture.credential,
                restExecutor: { request, limit in
                    try await replacementServer.execute(request, responseLimit: limit)
                })
            await ConnectionRegistry.shared.clientPool.adopt(
                replacement, for: fixture.gateway.id)
            await gate.release()

            let result = await task.value
            let sourceRequests = await fixture.server.requests()
            let replacementRequests = await replacementServer.requests()
            XCTAssertEqual(unavailable(result), .notLive)
            XCTAssertNil(ArtifactStore.shared.body(for: fixture.source))
            XCTAssertEqual(sourceRequests.count, 1)
            XCTAssertTrue(replacementRequests.isEmpty)
        }
    }

    func testReplacementDuringBodyReadAndPublicationRejectsCache() async throws {
        try await withFixture { fixture in
            let gate = ArtifactBodyGate()
            await fixture.server.blockBody(on: gate)
            let task = Task { await fixture.model.loadArtifact(fixture.artifact) }
            let bodyEntered = await artifactBodyEventually { await gate.hasEntered() }
            XCTAssertTrue(bodyEntered)
            let replacement = GatewayClient(
                baseURL: fixture.gateway.baseURL!, credential: fixture.credential,
                restExecutor: { request, _ in
                    throw URLError(.cannotConnectToHost)
                })
            await ConnectionRegistry.shared.clientPool.adopt(replacement, for: fixture.gateway.id)
            await gate.release()

            let result = await task.value
            XCTAssertEqual(unavailable(result), .notLive)
            XCTAssertNil(ArtifactStore.shared.body(for: fixture.source))
        }

        try await withFixture { fixture in
            ArtifactBodyRuntime.shared.beforePublicationForTesting = {
                let replacement = GatewayClient(
                    baseURL: fixture.gateway.baseURL!, credential: fixture.credential,
                    restExecutor: { _, _ in throw URLError(.cannotConnectToHost) })
                await ConnectionRegistry.shared.clientPool.adopt(
                    replacement, for: fixture.gateway.id)
            }
            let result = await fixture.model.loadArtifact(fixture.artifact)
            XCTAssertEqual(unavailable(result), .notLive)
            XCTAssertNil(ArtifactStore.shared.body(for: fixture.source))
        }
    }

    func testCredentialProfileAndProvenanceChangesRejectPublication() async throws {
        try await withFixture { fixture in
            ArtifactBodyRuntime.shared.beforePublicationForTesting = {
                ConnectionRegistry.shared.setCredentialForTesting(
                    .sessionToken("changed"), for: fixture.gateway)
            }
            let result = await fixture.model.loadArtifact(fixture.artifact)
            XCTAssertEqual(unavailable(result), .notLive)
            XCTAssertNil(ArtifactStore.shared.body(for: fixture.source))
        }

        try await withFixture { fixture in
            ArtifactBodyRuntime.shared.beforePublicationForTesting = {
                fixture.model.invalidateProfileLifecycleRouteForTesting(
                    GatewayBotRoute(gatewayID: fixture.gateway.id,
                                    profile: fixture.profile))
            }
            let result = await fixture.model.loadArtifact(fixture.artifact)
            XCTAssertEqual(unavailable(result), .notLive)
            XCTAssertNil(ArtifactStore.shared.body(for: fixture.source))
        }

        try await withFixture { fixture in
            ArtifactBodyRuntime.shared.beforePublicationForTesting = {
                FeedsRuntime.shared.artifactSessions[fixture.artifact.id] = SessionRef(
                    gatewayID: fixture.gateway.id,
                    botID: fixture.profile,
                    storedID: "different-session")
            }
            let result = await fixture.model.loadArtifact(fixture.artifact)
            XCTAssertEqual(unavailable(result), .notLive)
            XCTAssertNil(ArtifactStore.shared.body(for: fixture.source))
        }
    }

    func testRegistryEndpointMismatchRejectsBeforeExactClientRead() async throws {
        try await withFixture { fixture in
            let wrongURL = try XCTUnwrap(URL(
                string: "https://replacement-endpoint.example/base/"))
            let wrongServer = ArtifactBodyRESTServer(
                root: Self.rootPayload(fixture.root),
                body: Self.bodyPayload(path: fixture.path, root: fixture.root,
                                       data: Data("wrong endpoint".utf8)))
            let wrongClient = GatewayClient(
                baseURL: wrongURL,
                credential: fixture.credential,
                restExecutor: { request, limit in
                    try await wrongServer.execute(request, responseLimit: limit)
                })
            await ConnectionRegistry.shared.clientPool.adopt(
                wrongClient, for: fixture.gateway.id)

            let result = await fixture.model.loadArtifact(fixture.artifact)
            let requests = await wrongServer.requests()
            XCTAssertEqual(unavailable(result), .notLive)
            XCTAssertTrue(requests.isEmpty,
                          "a pool endpoint that disagrees with registry authority must not read")
            XCTAssertNil(ArtifactStore.shared.body(for: fixture.source))
        }
    }

    func testNewConnectionGenerationNeverJoinsOldInflightFetch() async throws {
        try await withFixture { fixture in
            let oldGate = ArtifactBodyGate()
            await fixture.server.blockBody(on: oldGate)
            let oldTask = Task { await fixture.model.loadArtifact(fixture.artifact) }
            let oldEntered = await artifactBodyEventually { await oldGate.hasEntered() }
            XCTAssertTrue(oldEntered)

            let newServer = ArtifactBodyRESTServer(
                root: Self.rootPayload(fixture.root),
                body: Self.bodyPayload(path: fixture.path, root: fixture.root,
                                       data: Data("new generation".utf8)))
            let replacement = GatewayClient(
                baseURL: fixture.gateway.baseURL!, credential: fixture.credential,
                restExecutor: { request, limit in
                    try await newServer.execute(request, responseLimit: limit)
                })
            await ConnectionRegistry.shared.clientPool.adopt(replacement, for: fixture.gateway.id)

            let newBody = await fixture.model.loadArtifact(fixture.artifact)
            let newRequests = await newServer.requests()
            XCTAssertEqual(bodyData(newBody), Data("new generation".utf8))
            XCTAssertEqual(newRequests.count, 2)
            await oldGate.release()
            let oldBody = await oldTask.value
            XCTAssertEqual(unavailable(oldBody), .notLive)
            XCTAssertEqual(ArtifactStore.shared.body(for: fixture.source)?.data,
                           Data("new generation".utf8))
        }
    }

    func testSharedWaiterCancellationDoesNotCancelSiblingFetch() async throws {
        try await withFixture { fixture in
            let gate = ArtifactBodyGate()
            await fixture.server.blockBody(on: gate)
            let first = Task { await fixture.model.loadArtifact(fixture.artifact) }
            let bodyEntered = await artifactBodyEventually { await gate.hasEntered() }
            XCTAssertTrue(bodyEntered)
            let second = Task { await fixture.model.loadArtifact(fixture.artifact) }
            let joined = await artifactBodyEventually {
                ArtifactStore.shared.inflightWaiterCount(for: fixture.source) == 2
            }
            XCTAssertTrue(joined)

            first.cancel()
            let releasedOne = await artifactBodyEventually {
                ArtifactStore.shared.inflightWaiterCount(for: fixture.source) == 1
            }
            XCTAssertTrue(releasedOne)
            await gate.release()

            let firstBody = await first.value
            let secondBody = await second.value
            let requests = await fixture.server.requests()
            XCTAssertEqual(unavailable(firstBody), .notLive)
            XCTAssertEqual(bodyData(secondBody), Data("retained body".utf8))
            XCTAssertEqual(requests.filter {
                $0.path.hasSuffix("/api/files/read")
            }.count, 1)
        }
    }

    func testTransientFailureIsNotCachedAndRetries() async throws {
        try await withFixture { fixture in
            await fixture.server.failNextBodyReads(1)
            let first = await fixture.model.loadArtifact(fixture.artifact)
            XCTAssertNotNil(unavailable(first))
            XCTAssertNil(ArtifactStore.shared.body(for: fixture.source))

            let second = await fixture.model.loadArtifact(fixture.artifact)
            let requests = await fixture.server.requests()
            XCTAssertEqual(bodyData(second), Data("retained body".utf8))
            XCTAssertEqual(requests.filter {
                $0.path.hasSuffix("/api/files/read")
            }.count, 2)
        }
    }

    func testFailureCompletionPreservesPriorSuccessfulCacheEntry() {
        let store = ArtifactStore.shared
        store.flush()
        defer { store.flush() }
        let source = ArtifactProvenance(
            gatewayID: "retained", profile: "worker",
            sessionID: "stored", value: "/managed/report.txt")
        let success = ArtifactBody.binary(Data("prior".utf8), mime: "text/plain")
        let successLease = store.acquire(for: source) { Task { success } }
        XCTAssertTrue(store.finish(success, lease: successLease, for: source))

        let failedKey = ArtifactFetchKey(
            source: source, connectionGeneration: 9,
            baseURLString: "https://replacement.example/")
        let failure = ArtifactBody.unavailable(.noREST)
        let failureLease = store.acquire(for: failedKey) { Task { failure } }
        XCTAssertFalse(store.finish(failure, lease: failureLease, for: source))
        XCTAssertEqual(store.body(for: source)?.data, Data("prior".utf8))
        XCTAssertEqual(store.inflightWaiterCount(for: failedKey), 0)
    }

    func testDeclaredAndCumulativeWireBoundsStopBeforeOversizeBuffering() {
        let limit = 32
        var accumulator = GatewayBoundedResponseAccumulator(limit: limit)
        XCTAssertFalse(accumulator.accepts(expectedContentLength: Int64(limit + 1)))
        XCTAssertTrue(accumulator.data.isEmpty,
                      "declared oversize must abort before any response body is buffered")
        XCTAssertTrue(accumulator.accepts(expectedContentLength: -1))
        XCTAssertTrue(accumulator.append(Data(repeating: 0x41, count: 20)))
        XCTAssertFalse(accumulator.append(Data(repeating: 0x42, count: 20)))
        XCTAssertEqual(accumulator.data.count, 20,
                       "the crossing chunk must be rejected rather than partially buffered")
    }

    func testBoundedDataTaskCancelsDeclaredAndCumulativeOversizeResponses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtifactBodyBoundedURLProtocol.self]
        var request = URLRequest(url: try XCTUnwrap(URL(
            string: "https://bounded-artifact.test/api/files/read")))
        request.timeoutInterval = 2

        ArtifactBodyBoundedURLProtocol.reset(.declared(
            length: 33, chunks: [Data(repeating: 0x41, count: 33)]))
        do {
            _ = try await GatewayBoundedRESTLoader.load(
                request, limit: 32, configuration: configuration)
            XCTFail("declared oversize response must fail")
        } catch let error as GatewayError {
            XCTAssertEqual(error.code, 413)
        }
        let declared = ArtifactBodyBoundedURLProtocol.state()
        XCTAssertTrue(declared.stopped)
        XCTAssertEqual(declared.delivered, 0,
                       "Content-Length must abort before URLProtocol delivers body bytes")

        ArtifactBodyBoundedURLProtocol.reset(.cumulative(chunks: [
            Data(repeating: 0x41, count: 20),
            Data(repeating: 0x42, count: 20),
            Data(repeating: 0x43, count: 20),
        ]))
        do {
            _ = try await GatewayBoundedRESTLoader.load(
                request, limit: 32, configuration: configuration)
            XCTFail("cumulative oversize response must fail")
        } catch let error as GatewayError {
            XCTAssertEqual(error.code, 413)
        }
        let cumulative = ArtifactBodyBoundedURLProtocol.state()
        XCTAssertTrue(cumulative.stopped)
        XCTAssertEqual(cumulative.delivered, 2,
                       "the task must cancel on the crossing chunk before the full body arrives")
    }

    func testOversizedRootProofResponsesAreBoundedAndRemainUnproven() async throws {
        try await withFixture { fixture in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ArtifactBodyBoundedURLProtocol.self]
            let boundedClient = GatewayClient(
                baseURL: fixture.gateway.baseURL!, credential: fixture.credential,
                restExecutor: { request, limit in
                    guard let limit else {
                        throw GatewayError(
                            code: -11,
                            message: "Managed-root proof must use bounded transport.")
                    }
                    return try await GatewayBoundedRESTLoader.load(
                        request, limit: limit, configuration: configuration)
                })
            await ConnectionRegistry.shared.clientPool.adopt(
                boundedClient, for: fixture.gateway.id)

            let cap = WorkspaceFileSizePolicy.maximumManagedRootResponseBytes
            ArtifactBodyBoundedURLProtocol.reset(.declared(
                length: cap + 1,
                chunks: [Data(repeating: 0x41, count: 32)]))

            let declaredBody = await fixture.model.loadArtifact(fixture.artifact)

            XCTAssertEqual(unavailable(declaredBody), .unproven,
                           "an oversized proof is not evidence that the artifact body is large")
            let declared = ArtifactBodyBoundedURLProtocol.state()
            XCTAssertTrue(declared.stopped)
            XCTAssertEqual(declared.delivered, 0,
                           "declared oversize root proof must stop before buffering body bytes")

            ArtifactStore.shared.flush()
            ArtifactBodyBoundedURLProtocol.reset(.cumulative(chunks: [
                Data(repeating: 0x41, count: cap * 3 / 4),
                Data(repeating: 0x42, count: cap * 3 / 4),
                Data(repeating: 0x43, count: 64),
            ]))

            let cumulativeBody = await fixture.model.loadArtifact(fixture.artifact)

            XCTAssertEqual(unavailable(cumulativeBody), .unproven,
                           "root-proof overflow must remain a capability failure")
            let cumulative = ArtifactBodyBoundedURLProtocol.state()
            XCTAssertTrue(cumulative.stopped)
            XCTAssertEqual(cumulative.delivered, 2,
                           "the crossing root-proof chunk must cancel before full buffering")
        }
    }

    func testBoundedLoaderMidstreamCancellationCompletesOnceAndReleasesSessionDelegate()
        async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtifactBodyBoundedURLProtocol.self]
        ArtifactBodyBoundedURLProtocol.reset(.cumulative(
            chunks: (0..<100).map { _ in Data(repeating: 0x41, count: 4_096) }))
        var request = URLRequest(url: try XCTUnwrap(URL(
            string: "https://bounded-artifact.test/api/files")))
        request.timeoutInterval = 2
        let lifetime = ArtifactBodyBoundedLifetimeProbe()

        let task = Task {
            try await GatewayBoundedRESTLoader.load(
                request,
                limit: WorkspaceFileSizePolicy.maximumManagedRootResponseBytes,
                configuration: configuration,
                lifetimeObserver: lifetime.observer)
        }
        var enteredMidstream = false
        for _ in 0..<200 {
            if ArtifactBodyBoundedURLProtocol.state().delivered >= 2 {
                enteredMidstream = true
                break
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(enteredMidstream,
                      "the request must be actively streaming before caller cancellation")

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("caller cancellation must terminate the bounded request")
        } catch is CancellationError {
            // Expected: caller cancellation wins over URLSession's transport error.
        } catch {
            XCTFail("expected CancellationError, received \(error)")
        }

        var released = false
        for _ in 0..<200 {
            if lifetime.snapshot().released == 1 {
                released = true
                break
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(released, "the invalidated session must release its delegate")
        let stopped = ArtifactBodyBoundedURLProtocol.state()
        let terminal = lifetime.snapshot()
        XCTAssertTrue(stopped.stopped, "caller cancellation must cancel the data task")
        XCTAssertEqual(terminal.created, 1)
        XCTAssertEqual(terminal.completed, 1,
                       "the checked continuation must have exactly one terminal resume")
        XCTAssertEqual(terminal.released, 1)

        try? await Task.sleep(for: .milliseconds(100))
        let afterDelay = ArtifactBodyBoundedURLProtocol.state()
        let afterDelayLifetime = lifetime.snapshot()
        XCTAssertEqual(afterDelay.delivered, stopped.delivered,
                       "no body callback may arrive after task cancellation")
        XCTAssertEqual(afterDelayLifetime.completed, 1,
                       "late delegate callbacks must not resume the continuation again")
        XCTAssertEqual(afterDelayLifetime.released, 1)
    }

    func testArtifactFailureMappingKeepsAuthorityAndHTTPOutcomesDistinct() {
        XCTAssertEqual(AppModel.artifactFailure(
            GatewayError(code: 404, message: "gone")), .missing)
        XCTAssertEqual(AppModel.artifactFailure(
            GatewayError(code: 410, message: "gone")), .missing)
        XCTAssertEqual(AppModel.artifactFailure(
            GatewayError(code: 403, message: "denied")), .refused)
        XCTAssertEqual(AppModel.artifactFailure(
            GatewayError(code: 415, message: "denied")), .refused)
        XCTAssertEqual(AppModel.artifactFailure(
            GatewayError(code: 413, message: "large")), .tooLarge)
        XCTAssertEqual(AppModel.artifactFailure(GatewayError(
            code: GatewayClient.managedFileAuthorityUnproven,
            message: "proof changed")), .unproven)
        XCTAssertEqual(AppModel.artifactFailure(CancellationError()), .notLive)
    }

    func testMalformedOrMismatchedManagedBodyIsUnreadableNotAuthorityProof() {
        let root = "/srv/hermes-managed"
        let path = "\(root)/report.txt"
        let malformed: JSONValue = .object([
            "name": .string("report.txt"),
            "path": .string(path),
            "root": .string(root),
            "locked_root": .string(root),
            "size": .number(4),
            "mime_type": .string("text/plain"),
            "data_url": .string("data:text/plain;base64,YWJj"),
        ])
        XCTAssertThrowsError(try ManagedFileBody(
            validatingArtifact: malformed,
            requestedPath: path,
            expectedLockedRoot: root
        )) { error in
            XCTAssertEqual((error as? GatewayError)?.code, 502)
            guard case .unreadable = AppModel.artifactFailure(error) else {
                return XCTFail("a non-security body mismatch must remain unreadable")
            }
        }
    }

    func testCrossGatewayCollisionKeepsBodiesSourceQualified() async throws {
        try await withFixture { first in
            let registry = ConnectionRegistry.shared
            let nonce = UUID().uuidString
            let secondURL = try XCTUnwrap(URL(
                string: "https://artifact-second-\(nonce).example/base/"))
            let secondCredential = GatewayCredential.sessionToken("second-token")
            let secondGateway = try XCTUnwrap(registry.upsert(
                urlString: secondURL.absoluteString,
                name: "Second artifact gateway",
                credential: secondCredential))
            let oldSecondRoster = registry.secondaryRosters[secondGateway.id]
            registry.setCredentialForTesting(secondCredential, for: secondGateway)
            registry.setSecondaryRosterForTesting(
                SecondaryRoster(
                    profiles: [SecondaryProfile(name: first.profile)],
                    fetchedAt: Date(), freshness: .fresh),
                gatewayID: secondGateway.id)
            let secondServer = ArtifactBodyRESTServer(
                root: Self.rootPayload(first.root),
                body: Self.bodyPayload(path: first.path, root: first.root,
                                       data: Data("second body".utf8)))
            let secondClient = GatewayClient(
                baseURL: secondGateway.baseURL!, credential: secondCredential,
                restExecutor: { request, limit in
                    try await secondServer.execute(request, responseLimit: limit)
                })
            await registry.clientPool.adopt(secondClient, for: secondGateway.id)
            defer {
                registry.setSecondaryRosterForTesting(
                    oldSecondRoster, gatewayID: secondGateway.id)
                registry.setCredentialForTesting(nil, for: secondGateway)
                registry.remove(id: secondGateway.id)
            }
            let secondRoute = GatewayBotRoute(
                gatewayID: secondGateway.id, profile: first.profile)
            XCTAssertFalse(first.model.bots.contains { $0.id == secondRoute.qualifiedID })
            XCTAssertTrue(first.model.unionRosterBots.contains {
                $0.id == secondRoute.qualifiedID
            })

            let secondArtifact = AppModel.artifact(
                from: first.path,
                botID: first.profile,
                sessionID: "stored-session",
                sessionTitle: "Collision",
                at: Date(timeIntervalSince1970: 1_700_000_001))
            first.model.artifacts.append(secondArtifact)
            FeedsRuntime.shared.artifactSessions[secondArtifact.id] = SessionRef(
                gatewayID: secondGateway.id,
                botID: first.profile,
                storedID: "stored-session")

            let firstBody = await first.model.loadArtifact(first.artifact)
            let secondBody = await first.model.loadArtifact(secondArtifact)
            let firstRequests = await first.server.requests()
            let secondRequests = await secondServer.requests()
            XCTAssertEqual(bodyData(firstBody), Data("retained body".utf8))
            XCTAssertEqual(bodyData(secondBody), Data("second body".utf8))
            XCTAssertEqual(firstRequests.count, 2)
            XCTAssertEqual(secondRequests.count, 2)

            first.model.clearProfileLifecycleRouteForTesting(
                GatewayBotRoute(gatewayID: secondGateway.id, profile: first.profile))
            await registry.clientPool.disconnect(gatewayID: secondGateway.id)
        }
    }

    func testRetainedRemovalPurgesBodiesThumbnailsInflightAndOwnedMedia() async throws {
        try await withFixture { fixture in
            let store = ArtifactStore.shared
            let png = Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
            let imageSource = fixture.source
            let imageLease = store.acquire(for: imageSource) { Task { .image(png) } }
            XCTAssertTrue(store.finish(.image(png), lease: imageLease, for: imageSource))

            let mediaSource = ArtifactProvenance(
                gatewayID: fixture.gateway.id,
                profile: fixture.profile,
                sessionID: "media-session",
                value: "\(fixture.root)/clip.mp4")
            let mediaURL = try GatewayREST.materializeMedia(
                data: Data("media".utf8), suggestedName: "clip.mp4")
            let mediaBody = ArtifactBody.media(mediaURL)
            let mediaLease = store.acquire(for: mediaSource) { Task { mediaBody } }
            XCTAssertTrue(store.finish(mediaBody, lease: mediaLease, for: mediaSource))

            let inflightSource = ArtifactProvenance(
                gatewayID: fixture.gateway.id,
                profile: fixture.profile,
                sessionID: "inflight-session",
                value: "\(fixture.root)/pending.mp4")
            let inflightURL = try GatewayREST.materializeMedia(
                data: Data("pending".utf8), suggestedName: "pending.mp4")
            let inflightBody = ArtifactBody.media(inflightURL)
            let inflightLease = store.acquire(for: inflightSource) {
                Task {
                    try? await Task.sleep(for: .seconds(30))
                    return inflightBody
                }
            }
            store.retainInflightMedia(inflightBody, lease: inflightLease)
            XCTAssertNotNil(store.body(for: imageSource))
            XCTAssertTrue(FileManager.default.fileExists(atPath: mediaURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: inflightURL.path))

            await fixture.model.removeGateway(fixture.gateway)

            XCTAssertNil(store.body(for: imageSource))
            XCTAssertNil(store.thumbnail(for: imageSource))
            XCTAssertNil(store.body(for: mediaSource))
            XCTAssertEqual(store.inflightWaiterCount(for: inflightSource), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: inflightURL.path))
        }
    }
}
#endif
