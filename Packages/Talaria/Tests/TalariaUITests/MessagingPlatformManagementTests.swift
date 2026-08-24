import XCTest
@testable import TalariaKit
@testable import TalariaUI

private actor MessagingTestGate {
    private var opened = false
    private var didArrive = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        didArrive = true
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func arrived() -> Bool { didArrive }

    func open() {
        opened = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private actor MessagingRESTProbe {
    private var requestCount = 0

    func execute(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        throw GatewayError(code: -99, message: "request should not be sent")
    }

    func count() -> Int { requestCount }
}

@MainActor
private final class MessagingFakeTransport: MessagingPlatformTransport {
    var connection: MessagingPlatformConnection
    var isConnectionCurrent = true
    var catalog: MessagingPlatformCatalog
    var resolveError: Error?
    var loadError: Error?
    var updateError: Error?
    var checkError: Error?
    var checkResult = MessagingPlatformTestResult([
        "ok": true, "state": "connected", "message": "Connected.",
    ])
    var resolveGate: MessagingTestGate?
    var loadGate: MessagingTestGate?
    var updateGate: MessagingTestGate?
    var loadCount = 0
    var updateCount = 0
    var lastMutationDebug = ""
    var handlers: [UUID: @Sendable (GatewayEvent) -> Void] = [:]

    init(connection: MessagingPlatformConnection, catalog: MessagingPlatformCatalog) {
        self.connection = connection
        self.catalog = catalog
    }

    func resolve(gatewayID: String) async throws -> MessagingPlatformConnection {
        if let resolveGate { await resolveGate.wait() }
        if let resolveError { throw resolveError }
        return connection
    }

    func isCurrent(_ connection: MessagingPlatformConnection) async -> Bool {
        isConnectionCurrent && MessagingPlatformConnection.same(connection, self.connection)
    }

    func load(connection: MessagingPlatformConnection,
              profile: String) async throws -> MessagingPlatformCatalog {
        loadCount += 1
        if let loadGate { await loadGate.wait() }
        if let loadError { throw loadError }
        return catalog
    }

    func update(connection: MessagingPlatformConnection,
                authority: MessagingPlatformMutationAuthority,
                mutation: MessagingPlatformMutation,
                profile: String) async throws {
        updateCount += 1
        lastMutationDebug = String(reflecting: mutation)
        if let updateGate { await updateGate.wait() }
        if let updateError { throw updateError }
    }

    func check(connection: MessagingPlatformConnection,
               authority: MessagingPlatformMutationAuthority,
               profile: String) async throws -> MessagingPlatformTestResult {
        if let checkError { throw checkError }
        return checkResult
    }

    func subscribe(connection: MessagingPlatformConnection,
                   handler: @escaping @Sendable (GatewayEvent) -> Void) async -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    func unsubscribe(connection: MessagingPlatformConnection, id: UUID) async {
        handlers.removeValue(forKey: id)
    }
}

@MainActor
final class MessagingPlatformManagementTests: XCTestCase {
    func testCatalogDecodesOnlySafeUniqueRowsAndNeverRetainsRedactedCredential() {
        let secret = "super-secret-token"
        let catalog = MessagingPlatformCatalog([
            "gateway_start_command": "hermes gateway start",
            "platforms": [
                platformValue(redacted: secret),
                platformValue(id: "../../slack"),
                platformValue(id: "duplicate"),
                platformValue(id: "duplicate"),
                platformValue(id: "ambiguous-fields", fields: [field("TOKEN"), field("TOKEN")]),
            ],
        ])

        XCTAssertEqual(catalog.platforms.map(\.id), ["slack"])
        XCTAssertEqual(catalog.platforms[0].environment.map(\.key), ["SLACK_BOT_TOKEN"])
        XCTAssertTrue(catalog.platforms[0].environment[0].isConfigured)
        XCTAssertTrue(catalog.hasOmissions)
        XCTAssertFalse(String(reflecting: catalog).contains(secret))
    }

    func testOversizedPlatformListIsRejectedWithoutPrefixAuthority() {
        let rows = (0...MessagingPlatformCatalog.maximumPlatforms).map {
            platformValue(id: "platform\($0)")
        }
        let catalog = MessagingPlatformCatalog(["platforms": .array(rows)])

        XCTAssertTrue(catalog.platforms.isEmpty)
        XCTAssertTrue(catalog.rejectedOversizedPlatformList)
        XCTAssertEqual(catalog.omittedRowCount, MessagingPlatformCatalog.maximumPlatforms + 1)
    }

    func testOversizedEnvironmentRowIsOmittedWhileIndependentSafeRowRemainsBounded() {
        let tooManyFields = (0...MessagingPlatform.maximumEnvironmentFields).map {
            field("TOKEN_\($0)")
        }
        let catalog = MessagingPlatformCatalog([
            "platforms": .array([
                platformValue(id: "discord", fields: tooManyFields),
                platformValue(id: "slack"),
            ]),
        ])

        XCTAssertEqual(catalog.platforms.map(\.id), ["slack"])
        XCTAssertEqual(catalog.omittedRowCount, 1)
        XCTAssertTrue(catalog.hasOmissions)
    }

    func testMalformedDuplicateRawPlatformIDCannotLeaveMutationAuthority() {
        let valid = platformValue(id: "slack")
        var malformed = valid.objectValue ?? [:]
        malformed["env_vars"] = .array((0...MessagingPlatform.maximumEnvironmentFields).map {
            field("SLACK_FIELD_\($0)")
        })
        let catalog = MessagingPlatformCatalog([
            "platforms": .array([valid, .object(malformed)]),
        ])

        XCTAssertTrue(catalog.platforms.isEmpty)
        XCTAssertEqual(catalog.omittedRowCount, 2)
        XCTAssertTrue(catalog.hasOmissions)
    }

    func testOversizedCatalogIsVisibleAndCannotAuthorizeMutation() async {
        let setup = makeCoordinator()
        setup.transport.catalog = MessagingPlatformCatalog([
            "platforms": .array((0...MessagingPlatformCatalog.maximumPlatforms).map {
                platformValue(id: "platform\($0)")
            }),
        ])
        setup.coordinator.select(gatewayID: "gateway-a", profile: "alpha")
        await setup.coordinator.refresh()

        XCTAssertTrue(setup.coordinator.platforms.isEmpty)
        XCTAssertTrue(setup.coordinator.noticeIsWarning)
        XCTAssertTrue(setup.coordinator.notice?.contains("too many") == true)
        let accepted = await setup.coordinator.setEnabled(true, platformID: "platform0")
        XCTAssertFalse(accepted)
        XCTAssertEqual(setup.transport.updateCount, 0)
    }

    func testDisplayTextIsScalarBounded() {
        var object = platformValue().objectValue ?? [:]
        object["name"] = .string(String(repeating: "x", count: 3_000))
        let catalog = MessagingPlatformCatalog([
            "platforms": .array([.object(object)]),
        ])
        XCTAssertEqual(catalog.platforms.first?.name.unicodeScalars.count, 2_048)
    }

    func testBodyProfileBeatsQueryScopeAndDebugDescriptionContainsKeysOnly() {
        let secret = "body-profile-secret"
        let mutation = MessagingPlatformMutation(
            enabled: true, environment: ["SLACK_BOT_TOKEN": secret],
            clearEnvironment: ["SLACK_APP_TOKEN"])
        let body = mutation.wireBody(profile: "research")

        XCTAssertEqual(body["profile"], .string("research"))
        XCTAssertEqual(body["enabled"], .bool(true))
        XCTAssertEqual(body["env"]?["SLACK_BOT_TOKEN"], .string(secret))
        XCTAssertFalse(String(reflecting: mutation).contains(secret))
        XCTAssertTrue(String(reflecting: mutation).contains("SLACK_BOT_TOKEN"))
    }

    func testMutationAllowlistSeparatesSaveAndClearAndRejectsAmbiguity() {
        let authority = MessagingPlatformMutationAuthority(
            platformID: "slack", environmentKeys: ["SLACK_BOT_TOKEN", "SLACK_APP_TOKEN"])
        XCTAssertTrue(MessagingPlatformMutationValidation.admits(
            MessagingPlatformMutation(environment: ["SLACK_BOT_TOKEN": "new"]),
            authority: authority))
        XCTAssertTrue(MessagingPlatformMutationValidation.admits(
            MessagingPlatformMutation(clearEnvironment: ["SLACK_APP_TOKEN"]),
            authority: authority))
        XCTAssertFalse(MessagingPlatformMutationValidation.admits(
            MessagingPlatformMutation(environment: ["HOME": "no"]), authority: authority))
        XCTAssertFalse(MessagingPlatformMutationValidation.admits(
            MessagingPlatformMutation(environment: ["SLACK_APP_TOKEN": "new"],
                                      clearEnvironment: ["SLACK_APP_TOKEN"]),
            authority: authority))
    }

    func testRelayCatalogRowRemainsVisibleButCannotMintProfileMutationAuthority() {
        let catalog = MessagingPlatformCatalog([
            "platforms": .array([
                platformValue(id: "relay", fields: []),
                platformValue(id: "slack"),
            ]),
        ])

        XCTAssertEqual(catalog.platforms.map(\.id), ["relay", "slack"])
        XCTAssertTrue(catalog.platforms[0].isDeploymentManaged)
        XCTAssertFalse(catalog.platforms[1].isDeploymentManaged)
        XCTAssertFalse(MessagingPlatformMutationValidation.admits(
            MessagingPlatformMutation(enabled: true),
            authority: catalog.platforms[0].authority
        ))
        XCTAssertTrue(MessagingPlatformMutationValidation.admits(
            MessagingPlatformMutation(enabled: true),
            authority: catalog.platforms[1].authority
        ))
    }

    func testRelayUpdateAndCheckRejectBeforeAnyRESTRequest() async throws {
        let probe = MessagingRESTProbe()
        let client = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://gateway.example")),
            credential: .sessionToken("test"),
            restExecutor: { request, _ in try await probe.execute(request) }
        )
        let authority = MessagingPlatformMutationAuthority(
            platformID: "relay", environmentKeys: [])

        do {
            try await client.updateMessagingPlatform(
                authority: authority,
                mutation: MessagingPlatformMutation(enabled: true),
                profile: "default")
            XCTFail("relay update must fail before REST dispatch")
        } catch let error as GatewayError {
            XCTAssertEqual(error.code, 409)
        }

        do {
            _ = try await client.testMessagingPlatform(
                authority: authority, profile: "default")
            XCTFail("relay connection check must fail before REST dispatch")
        } catch let error as GatewayError {
            XCTAssertEqual(error.code, 409)
        }

        let requestCount = await probe.count()
        XCTAssertEqual(requestCount, 0)
    }

    func testProfileAndInterpolatedIdentitiesMatchHermesBounds() {
        XCTAssertEqual(MessagingPlatformIdentityAdmission.profile("default"), "default")
        XCTAssertEqual(MessagingPlatformIdentityAdmission.profile("research-2"), "research-2")
        XCTAssertNil(MessagingPlatformIdentityAdmission.profile("Research"))
        XCTAssertNil(MessagingPlatformIdentityAdmission.profile("../research"))
        XCTAssertNil(MessagingPlatformIdentityAdmission.profile("-research"))
        XCTAssertNil(MessagingPlatformIdentityAdmission.profile(String(repeating: "a", count: 65)))
        XCTAssertNil(MessagingPlatformIdentityAdmission.platform("slack/path"))
        XCTAssertNil(MessagingPlatformIdentityAdmission.environmentKey("SLACK-TOKEN"))
    }

    func testProfileSwitchWhileConnectionResolutionIsSuspendedSuppressesOldCatalog() async throws {
        let setup = makeCoordinator()
        let gate = MessagingTestGate()
        setup.transport.resolveGate = gate
        setup.coordinator.select(gatewayID: "gateway-a", profile: "alpha")
        let task = Task { await setup.coordinator.refresh() }
        try await waitUntil { await gate.arrived() }

        setup.coordinator.select(gatewayID: "gateway-a", profile: "beta")
        await gate.open()
        await task.value

        XCTAssertTrue(setup.coordinator.platforms.isEmpty)
        XCTAssertEqual(setup.coordinator.scope?.profile, "beta")
    }

    func testGatewayAndProfileSwitchDuringWriteSuppressesReceiptAndRefetch() async throws {
        let setup = makeCoordinator()
        setup.coordinator.select(gatewayID: "gateway-a", profile: "alpha")
        await setup.coordinator.refresh()
        XCTAssertFalse(setup.coordinator.platforms.isEmpty)
        let gate = MessagingTestGate()
        setup.transport.updateGate = gate
        let task = Task {
            await setup.coordinator.setEnabled(true, platformID: "slack")
        }
        try await waitUntil { await gate.arrived() }

        setup.coordinator.select(gatewayID: "gateway-b", profile: "beta")
        await gate.open()
        let accepted = await task.value
        XCTAssertFalse(accepted)

        XCTAssertTrue(setup.coordinator.platforms.isEmpty)
        XCTAssertEqual(setup.transport.loadCount, 1,
                       "a stale successful write must not refetch/publish into the new scope")
    }

    func testReplacementConnectionDuringLoadSuppressesStaleSnapshot() async throws {
        let setup = makeCoordinator()
        let gate = MessagingTestGate()
        setup.transport.loadGate = gate
        setup.coordinator.select(gatewayID: "gateway-a", profile: "alpha")
        let task = Task { await setup.coordinator.refresh() }
        try await waitUntil { await gate.arrived() }
        setup.transport.isConnectionCurrent = false
        await gate.open()
        await task.value
        XCTAssertTrue(setup.coordinator.platforms.isEmpty)
    }

    func test409PreservesServerTruthWithoutOptimisticEnable() async {
        let setup = makeCoordinator(enabled: false)
        setup.coordinator.select(gatewayID: "gateway-a", profile: "alpha")
        await setup.coordinator.refresh()
        setup.transport.updateError = GatewayError(
            code: 409,
            message: "Cannot enable 'slack' on profile 'alpha': multiplex port-binding conflict")

        let accepted = await setup.coordinator.setEnabled(true, platformID: "slack")
        XCTAssertFalse(accepted)
        XCTAssertEqual(setup.coordinator.platforms.first?.isEnabled, false)
        XCTAssertTrue(setup.coordinator.notice?.contains("multiplex") == true)
    }

    func test404IsHonestUnsupportedAndTimeoutMessageRemainsActionable() async {
        let missing = makeCoordinator()
        missing.transport.loadError = GatewayError(code: 404, message: "Not Found")
        missing.coordinator.select(gatewayID: "gateway-a", profile: "alpha")
        await missing.coordinator.refresh()
        XCTAssertTrue(missing.coordinator.unsupported)
        XCTAssertTrue(missing.coordinator.notice?.contains("does not expose") == true)

        let timeout = makeCoordinator()
        timeout.transport.loadError = GatewayError(code: -5, message: "request timed out")
        timeout.coordinator.select(gatewayID: "gateway-a", profile: "alpha")
        await timeout.coordinator.refresh()
        XCTAssertFalse(timeout.coordinator.unsupported)
        XCTAssertEqual(timeout.coordinator.notice, "request timed out")
    }

    func testSubmittedSecretNeverEntersCoordinatorStateDebugOrFailureNotice() async {
        let setup = makeCoordinator()
        let secret = "never-store-me-4981"
        setup.coordinator.select(gatewayID: "gateway-a", profile: "alpha")
        await setup.coordinator.refresh()
        setup.transport.updateError = GatewayError(
            code: 400, message: "Credential \(secret) was rejected")

        let accepted = await setup.coordinator.saveCredentials(
            platformID: "slack", values: ["SLACK_BOT_TOKEN": secret])
        XCTAssertFalse(accepted)
        XCTAssertFalse(setup.transport.lastMutationDebug.contains(secret))
        XCTAssertFalse(setup.coordinator.notice?.contains(secret) == true)
        XCTAssertTrue(setup.coordinator.notice?.contains("[credential redacted]") == true)
        XCTAssertFalse(String(reflecting: setup.coordinator.platforms).contains(secret))
    }

    func testWhitespaceCredentialDoesNotProduceAFalseSaveReceipt() async {
        let setup = makeCoordinator()
        setup.coordinator.select(gatewayID: "gateway-a", profile: "alpha")
        await setup.coordinator.refresh()

        let accepted = await setup.coordinator.saveCredentials(
            platformID: "slack", values: ["SLACK_BOT_TOKEN": "  \n "])

        XCTAssertFalse(accepted)
        XCTAssertEqual(setup.transport.updateCount, 0)
        XCTAssertTrue(setup.coordinator.notice?.contains("Enter at least one") == true)
    }

    func testOnlyExactSourcePlatformsChangedRefreshesCurrentProfile() async throws {
        let setup = makeCoordinator()
        setup.coordinator.select(gatewayID: "gateway-a", profile: "alpha")
        await setup.coordinator.refresh()
        XCTAssertEqual(setup.transport.loadCount, 1)
        let wrongClient = GatewayClient(
            baseURL: URL(string: "https://wrong.example")!,
            credential: .sessionToken("test"))
        let wrong = MessagingPlatformConnection(
            gatewayID: "gateway-b", client: wrongClient, generation: 1)
        let event = GatewayEvent(type: "platforms.changed", sessionID: "", payload: [:])

        setup.coordinator.receivePlatformsChanged(source: wrong, profile: "alpha", event: event)
        setup.coordinator.receivePlatformsChanged(
            source: setup.transport.connection, profile: "beta", event: event)
        await Task.yield()
        XCTAssertEqual(setup.transport.loadCount, 1)

        setup.coordinator.receivePlatformsChanged(
            source: setup.transport.connection, profile: "alpha", event: event)
        try await waitUntil { setup.transport.loadCount == 2 }
        XCTAssertEqual(setup.coordinator.changeEventRefreshCount, 1)
    }

    func testExactConnectionLeaseBlocksReplacementAndProfileLifecycleAcrossAwait() async throws {
        let first = GatewayClient(baseURL: URL(string: "https://lease-one.example")!,
                                  credential: .sessionToken("one"))
        let second = GatewayClient(baseURL: URL(string: "https://lease-two.example")!,
                                   credential: .sessionToken("two"))
        let pool = GatewayClientPool { _, _ in first }
        await pool.adopt(first, for: "gateway-a")
        let snapshot = try await pool.connectWithGeneration(
            gatewayID: "gateway-a", baseURL: first.baseURL,
            credential: .sessionToken("one"))
        let connection = MessagingPlatformConnection(
            gatewayID: "gateway-a", client: first, generation: snapshot.generation)
        let gate = MessagingTestGate()

        let operation = Task { @MainActor in
            try await MessagingPlatformExactConnectionLease.perform(
                connection: connection, pool: pool
            ) { _ in
                await gate.wait()
                return true
            }
        }
        try await waitUntil { await gate.arrived() }

        XCTAssertFalse(ProfileLifecycleTrafficAdmission.beginLifecycle("gateway-a"))
        let replacement = Task { await pool.adopt(second, for: "gateway-a") }
        await Task.yield()
        let currentWhileLeased = await pool.isCurrent(snapshot, for: "gateway-a")
        XCTAssertTrue(currentWhileLeased,
                      "replacement must wait for the exact REST operation")

        await gate.open()
        let completed = try await operation.value
        XCTAssertTrue(completed)
        await replacement.value
        let currentAfterReplacement = await pool.isCurrent(snapshot, for: "gateway-a")
        XCTAssertFalse(currentAfterReplacement)

        XCTAssertTrue(ProfileLifecycleTrafficAdmission.beginLifecycle("gateway-a"),
                      "traffic admission must be released on completion")
        ProfileLifecycleTrafficAdmission.endLifecycle("gateway-a")
        await pool.disconnectAll()
    }

    func testExactConnectionLeaseReleasesBothAuthoritiesAfterFailure() async throws {
        let client = GatewayClient(baseURL: URL(string: "https://lease-failure.example")!,
                                   credential: .sessionToken("one"))
        let pool = GatewayClientPool { _, _ in client }
        await pool.adopt(client, for: "gateway-failure")
        let snapshot = try await pool.connectWithGeneration(
            gatewayID: "gateway-failure", baseURL: client.baseURL,
            credential: .sessionToken("one"))
        let connection = MessagingPlatformConnection(
            gatewayID: "gateway-failure", client: client, generation: snapshot.generation)

        do {
            _ = try await MessagingPlatformExactConnectionLease.perform(
                connection: connection, pool: pool
            ) { _ -> Bool in
                throw GatewayError(code: -5, message: "timeout")
            }
            XCTFail("injected transport failure must escape")
        } catch {
            XCTAssertEqual((error as? GatewayError)?.code, -5)
        }

        XCTAssertTrue(ProfileLifecycleTrafficAdmission.beginLifecycle("gateway-failure"))
        ProfileLifecycleTrafficAdmission.endLifecycle("gateway-failure")
        let replacement = GatewayClient(
            baseURL: URL(string: "https://lease-failure-replacement.example")!,
            credential: .sessionToken("two"))
        await pool.adopt(replacement, for: "gateway-failure")
        let stillCurrent = await pool.isCurrent(snapshot, for: "gateway-failure")
        XCTAssertFalse(stillCurrent)
        await pool.disconnectAll()
    }

    private func makeCoordinator(enabled: Bool = false) -> (
        coordinator: MessagingPlatformLifecycleCoordinator,
        transport: MessagingFakeTransport
    ) {
        let client = GatewayClient(baseURL: URL(string: "https://gateway.example")!,
                                   credential: .sessionToken("test"))
        let connection = MessagingPlatformConnection(
            gatewayID: "gateway-a", client: client, generation: 7)
        let transport = MessagingFakeTransport(
            connection: connection,
            catalog: MessagingPlatformCatalog([
                "gateway_start_command": "hermes gateway start --replace",
                "platforms": [platformValue(enabled: enabled)],
            ]))
        return (MessagingPlatformLifecycleCoordinator(transport: transport), transport)
    }

    private func platformValue(
        id: String = "slack", enabled: Bool = false,
        fields: [JSONValue]? = nil, redacted: String = "…token"
    ) -> JSONValue {
        [
            "id": .string(id), "name": "Slack", "description": "Slack bot",
            "docs_url": "https://docs.example/slack", "enabled": .bool(enabled),
            "configured": true, "gateway_running": true,
            "state": .string(enabled ? "connected" : "disabled"),
            "env_vars": .array(fields ?? [field("SLACK_BOT_TOKEN", redacted: redacted)]),
        ]
    }

    private func field(_ key: String, redacted: String = "…token") -> JSONValue {
        [
            "key": .string(key), "prompt": "Bot token", "required": true,
            "is_set": true, "is_password": true,
            "redacted_value": .string(redacted),
        ]
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () async -> Bool,
        iterations: Int = 1_000
    ) async throws {
        for _ in 0..<iterations {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for asynchronous test boundary")
    }
}
