#if canImport(XCTest)
import XCTest
import TalariaKit
@testable import TalariaUI

private actor ArtifactDiscoveryConnectorCounter {
    private(set) var calls = 0
    func record() { calls += 1 }
    func read() -> Int { calls }
}

private actor ArtifactDiscoveryGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func hasEntered() -> Bool { entered }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ArtifactDiscoveryMarker {
    private var marked = false
    func mark() { marked = true }
    func read() -> Bool { marked }
}

private func artifactEventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<2_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

@MainActor
final class ArtifactDiscoveryRuntimeTests: XCTestCase {
    private struct Fixture {
        var model: AppModel
        var primary: SavedGateway
        var primaryClient: GatewayClient
        var primaryProfile: String
        var remote: SavedGateway?
        var remoteClient: GatewayClient?
        var remoteProfile: String?
        var oldGatewayID: String?
        var oldBaseURL: URL?
        var oldGeneration: Int
    }

    private func session(_ id: String = "stored", messageCount: Int = 1)
        -> ArtifactDiscoverySession {
        ArtifactDiscoverySession(
            id: id,
            title: "Session",
            preview: "preview",
            startedAt: 1_700_000_000,
            messageCount: messageCount
        )
    }

    private func window(_ sessions: [ArtifactDiscoverySession], limit: Int = 6,
                        returnedCount: Int? = nil) -> ArtifactSessionListWindow {
        ArtifactSessionListWindow(
            sessions: sessions,
            requestedLimit: limit,
            returnedCount: returnedCount ?? sessions.count
        )
    }

    private func artifactRow(_ value: String, timestamp: Double = 1_700_000_000) -> JSONValue {
        .object([
            "role": .string("assistant"),
            "content": .string("Created [output](\(value))"),
            "timestamp": .number(timestamp)
        ])
    }

    private func page(messages: [JSONValue], sessionID: String = "resolved-tip",
                      limit: Int = 150, offset: Int = 0,
                      returnedCount: Int? = nil) -> ArtifactTranscriptPage {
        ArtifactTranscriptPage(
            resolvedSessionID: sessionID,
            messages: messages,
            limit: limit,
            offset: offset,
            returnedCount: returnedCount ?? messages.count
        )
    }

    @discardableResult
    private func seedPriorArtifact(model: AppModel, gatewayID: String,
                                   profile: String, value: String = "/tmp/prior.md")
        -> Artifact {
        let artifact = AppModel.artifact(
            from: value,
            botID: profile,
            sessionID: "\(gatewayID)\u{1f}prior-stored",
            sessionTitle: "Prior",
            at: Date(timeIntervalSince1970: 1_600_000_000)
        )
        model.artifacts = [artifact]
        FeedsRuntime.shared.artifactSessions[artifact.id] = SessionRef(
            gatewayID: gatewayID,
            botID: profile,
            storedID: "prior-stored"
        )
        FeedsRuntime.shared.artifactDiscoveryStatus[gatewayID] = .incomplete(
            cursor: nil,
            reason: "prior bounded snapshot"
        )
        return artifact
    }

    private func clearArtifactRuntime() async {
        let runtime = FeedsRuntime.shared
        let task = runtime.artifactsTask
        task?.cancel()
        await task?.value
        runtime.artifactsTask = nil
        runtime.artifactsTaskID = nil
        runtime.artifactsScanning = false
        runtime.artifactScanGeneration &+= 1
        runtime.lastArtifactScan = nil
        runtime.artifactSessions = [:]
        runtime.artifactDiscoveryStatus = [:]
        runtime.artifactScannedSessions = [:]
        runtime.artifactsNote = ""
        runtime.artifactProfilesReadForTesting = nil
        runtime.artifactSessionsReadForTesting = nil
        runtime.artifactTranscriptReadForTesting = nil
        runtime.artifactAfterAuthorityCaptureForTesting = nil
        runtime.artifactBeforePublicationForTesting = nil
    }

    private func withFixture(
        includeRemote: Bool = false,
        remoteProfile requestedRemoteProfile: String? = nil,
        _ body: @MainActor (Fixture) async throws -> Void
    ) async throws {
        await clearArtifactRuntime()
        let registry = ConnectionRegistry.shared
        let live = LiveRuntime.shared
        let oldGatewayID = live.gatewayID
        let oldBaseURL = live.baseURL
        let oldGeneration = live.generation
        let nonce = UUID().uuidString
        let primaryURL = try XCTUnwrap(URL(
            string: "https://artifact-primary-\(nonce).example"))
        let primary = try XCTUnwrap(registry.upsert(
            urlString: primaryURL.absoluteString,
            name: "Artifact primary",
            credential: .sessionToken("artifact-primary-token-\(nonce)")))
        let primaryClient = GatewayClient(
            baseURL: primaryURL,
            credential: .sessionToken("artifact-primary-token-\(nonce)"))
        await registry.clientPool.adopt(primaryClient, for: primary.id)

        let profile = "collision"
        let remoteProfile = requestedRemoteProfile ?? profile
        let model = AppModel()
        model.mode = .live
        model.client = primaryClient
        model.bots = [
            Bot(id: profile, job: "", shape: .circle, hue: .violet)
        ]
        live.gatewayID = primary.id
        live.baseURL = primaryURL
        live.generation &+= 1

        var remote: SavedGateway?
        var remoteClient: GatewayClient?
        if includeRemote {
            let remoteURL = try XCTUnwrap(URL(
                string: "https://artifact-remote-\(nonce).example"))
            let saved = try XCTUnwrap(registry.upsert(
                urlString: remoteURL.absoluteString,
                name: "Artifact remote",
                credential: .sessionToken("artifact-remote-token-\(nonce)")))
            let client = GatewayClient(
                baseURL: remoteURL,
                credential: .sessionToken("artifact-remote-token-\(nonce)"))
            await registry.clientPool.adopt(client, for: saved.id)
            registry.setSecondaryRosterForTesting(
                SecondaryRoster(
                    profiles: [SecondaryProfile(name: remoteProfile)],
                    fetchedAt: Date(),
                    freshness: .fresh
                ),
                gatewayID: saved.id
            )
            remote = saved
            remoteClient = client
        }

        let fixtureProfiles: [String: [String]] = {
            var profiles = [primary.id: [profile]]
            if let remote { profiles[remote.id] = [remoteProfile] }
            return profiles
        }()
        FeedsRuntime.shared.artifactProfilesReadForTesting = { gatewayID, _ in
            fixtureProfiles[gatewayID] ?? []
        }

        let fixture = Fixture(
            model: model,
            primary: primary,
            primaryClient: primaryClient,
            primaryProfile: profile,
            remote: remote,
            remoteClient: remoteClient,
            remoteProfile: includeRemote ? remoteProfile : nil,
            oldGatewayID: oldGatewayID,
            oldBaseURL: oldBaseURL,
            oldGeneration: oldGeneration
        )
        var caught: Error?
        do { try await body(fixture) } catch { caught = error }

        await clearArtifactRuntime()
        model.client = nil
        model.clearProfileLifecycleRouteForTesting(
            GatewayBotRoute(gatewayID: primary.id, profile: profile))
        if let remote {
            model.clearProfileLifecycleRouteForTesting(
                GatewayBotRoute(gatewayID: remote.id, profile: remoteProfile))
            await registry.clientPool.disconnect(gatewayID: remote.id)
            registry.remove(id: remote.id)
        }
        await registry.clientPool.disconnect(gatewayID: primary.id)
        registry.remove(id: primary.id)
        live.gatewayID = oldGatewayID
        live.baseURL = oldBaseURL
        live.generation = oldGeneration
        if let caught { throw caught }
    }

    func testRetainedSnapshotEnumerationIsAtomicAndNeverDials() async throws {
        let counter = ArtifactDiscoveryConnectorCounter()
        let base = try XCTUnwrap(URL(string: "https://enumeration.example"))
        let pool = GatewayClientPool { url, credential in
            await counter.record()
            return GatewayClient(baseURL: url, credential: credential)
        }
        let first = GatewayClient(baseURL: base, credential: .sessionToken("first"))
        let second = GatewayClient(baseURL: base, credential: .sessionToken("second"))
        await pool.adopt(second, for: "two")
        await pool.adopt(first, for: "one")

        let captured = await pool.retainedConnectionSnapshots()
        let connectorCalls = await counter.read()
        XCTAssertEqual(captured.map(\.gatewayID), ["one", "two"])
        XCTAssertEqual(connectorCalls, 0)
        XCTAssertEqual(
            captured.map { ObjectIdentifier($0.connection.client) },
            [ObjectIdentifier(first), ObjectIdentifier(second)]
        )
        XCTAssertEqual(captured.compactMap { $0.connection.baseURL }, [base, base])

        let replacement = GatewayClient(
            baseURL: base, credential: .sessionToken("replacement"))
        await pool.adopt(replacement, for: "one")
        let firstIsCurrent = await pool.isCurrent(captured[0].connection, for: "one")
        let secondIsCurrent = await pool.isCurrent(captured[1].connection, for: "two")
        XCTAssertFalse(firstIsCurrent)
        XCTAssertTrue(secondIsCurrent)
        await pool.disconnectAll()
    }

    func testRetainedSnapshotEnumerationOmitsConnectingSlotWithoutJoiningIt() async throws {
        let counter = ArtifactDiscoveryConnectorCounter()
        let gate = ArtifactDiscoveryGate()
        let base = try XCTUnwrap(URL(string: "https://connecting-enumeration.example"))
        let credential = GatewayCredential.sessionToken("connecting")
        let pool = GatewayClientPool { url, credential in
            await counter.record()
            await gate.wait()
            return GatewayClient(baseURL: url, credential: credential)
        }
        let connection = Task {
            try await pool.connect(
                gatewayID: "connecting", baseURL: base, credential: credential)
        }
        let connectorEntered = await artifactEventually { await gate.hasEntered() }
        XCTAssertTrue(connectorEntered)

        let whileConnecting = await pool.retainedConnectionSnapshots()
        let callsAfterEnumeration = await counter.read()
        XCTAssertTrue(whileConnecting.isEmpty)
        XCTAssertEqual(callsAfterEnumeration, 1,
                       "enumeration must neither join nor duplicate the in-flight dial")

        await gate.release()
        _ = try await connection.value
        let afterPublication = await pool.retainedConnectionSnapshots()
        XCTAssertEqual(afterPublication.map(\.gatewayID), ["connecting"])
        await pool.disconnectAll()
    }

    func testTwoRetainedGatewaysKeepCollidingProfileSessionAndArtifactDistinct() async throws {
        try await withFixture(includeRemote: true) { fixture in
            let runtime = FeedsRuntime.shared
            let remote = try XCTUnwrap(fixture.remote)
            let remoteClient = try XCTUnwrap(fixture.remoteClient)
            var profileClients: [String: ObjectIdentifier] = [:]
            var sessionClients: [String: ObjectIdentifier] = [:]
            var transcriptClients: [String: ObjectIdentifier] = [:]
            runtime.artifactProfilesReadForTesting = { gatewayID, client in
                profileClients[gatewayID] = ObjectIdentifier(client)
                return [fixture.primaryProfile]
            }
            runtime.artifactSessionsReadForTesting = { gatewayID, _, client, limit in
                sessionClients[gatewayID] = ObjectIdentifier(client)
                return self.window([self.session("same-stored")], limit: limit)
            }
            runtime.artifactTranscriptReadForTesting = {
                gatewayID, _, _, client, _, limit in
                transcriptClients[gatewayID] = ObjectIdentifier(client)
                return self.page(
                    messages: [self.artifactRow("/tmp/collision.md")],
                    sessionID: "same-resolved",
                    limit: limit
                )
            }

            XCTAssertEqual(fixture.model.bots.map(\.id), [fixture.primaryProfile],
                           "primary bots must not be manually seeded with retained rows")
            XCTAssertEqual(fixture.model.foreignRosterEntries.map(\.gatewayID), [remote.id])
            XCTAssertEqual(
                fixture.model.foreignRosterEntries.map(\.profile), [fixture.primaryProfile])
            XCTAssertEqual(fixture.model.unionRosterBots.count, 2)

            await fixture.model.refreshArtifacts(force: true)

            XCTAssertEqual(sessionClients[fixture.primary.id],
                           ObjectIdentifier(fixture.primaryClient))
            XCTAssertEqual(sessionClients[remote.id], ObjectIdentifier(remoteClient))
            XCTAssertEqual(profileClients, sessionClients)
            XCTAssertEqual(transcriptClients, sessionClients)
            XCTAssertEqual(fixture.model.artifacts.count, 2)
            XCTAssertEqual(Set(fixture.model.artifacts.map(\.id)).count, 2)
            XCTAssertEqual(
                Set(runtime.artifactSessions.values.map(\.gatewayID)),
                [fixture.primary.id, remote.id]
            )
            for gatewayID in [fixture.primary.id, remote.id] {
                guard case .incomplete(cursor: nil, reason: let reason)? =
                        runtime.artifactDiscoveryStatus[gatewayID] else {
                    return XCTFail("expected bounded incomplete source")
                }
                XCTAssertTrue(reason.contains("bounded window"))
            }
        }
    }

    func testRetainedProfileAbsentFromPrimaryBotsScansThroughProductionUnionRoster()
        async throws {
        try await withFixture(includeRemote: true, remoteProfile: "remote-only") { fixture in
            let runtime = FeedsRuntime.shared
            let remote = try XCTUnwrap(fixture.remote)
            let remoteProfile = try XCTUnwrap(fixture.remoteProfile)
            XCTAssertEqual(fixture.model.bots.map(\.id), [fixture.primaryProfile])
            XCTAssertFalse(fixture.model.bots.contains(where: { $0.id == remoteProfile }))
            XCTAssertEqual(fixture.model.foreignRosterEntries.map(\.profile), [remoteProfile])

            runtime.artifactSessionsReadForTesting = { gatewayID, profile, _, limit in
                if gatewayID == remote.id {
                    XCTAssertEqual(profile, remoteProfile)
                    return self.window([self.session("remote-only-stored")], limit: limit)
                }
                return self.window([], limit: limit)
            }
            runtime.artifactTranscriptReadForTesting = {
                gatewayID, profile, _, _, offset, limit in
                XCTAssertEqual(gatewayID, remote.id)
                XCTAssertEqual(profile, remoteProfile)
                return self.page(
                    messages: [self.artifactRow("/tmp/remote-only.md")],
                    limit: limit,
                    offset: offset
                )
            }

            await fixture.model.refreshArtifacts(force: true)

            let discovered = try XCTUnwrap(fixture.model.artifacts.first {
                AppModel.artifactValue($0.id) == "/tmp/remote-only.md"
            })
            XCTAssertEqual(runtime.artifactSessions[discovered.id], SessionRef(
                gatewayID: remote.id,
                botID: remoteProfile,
                storedID: "remote-only-stored"
            ))
        }
    }

    func testInitialEndpointAuthorityRejectionMarksPriorSourceStaleWithoutDeletingRows()
        async throws {
        try await withFixture(includeRemote: true) { fixture in
            let runtime = FeedsRuntime.shared
            let remote = try XCTUnwrap(fixture.remote)
            let remoteProfile = try XCTUnwrap(fixture.remoteProfile)
            let prior = seedPriorArtifact(
                model: fixture.model,
                gatewayID: remote.id,
                profile: remoteProfile
            )
            var profileReads: [String] = []
            runtime.artifactProfilesReadForTesting = { gatewayID, _ in
                profileReads.append(gatewayID)
                return gatewayID == fixture.primary.id
                    ? [fixture.primaryProfile] : [remoteProfile]
            }
            runtime.artifactSessionsReadForTesting = { _, _, _, limit in
                self.window([], limit: limit)
            }

            let wrongURL = try XCTUnwrap(URL(
                string: "https://wrong-artifact-source-\(UUID().uuidString).example"))
            await ConnectionRegistry.shared.clientPool.adopt(
                GatewayClient(baseURL: wrongURL, credential: .sessionToken("wrong-source")),
                for: remote.id
            )
            await fixture.model.refreshArtifacts(force: true)

            XCTAssertFalse(profileReads.contains(remote.id),
                           "rejected construction must not read the retained source")
            XCTAssertTrue(fixture.model.artifacts.contains(where: { $0.id == prior.id }))
            guard case .stale(reason: let reason)? =
                    runtime.artifactDiscoveryStatus[remote.id] else {
                return XCTFail("rejected retained authority must stale its prior result")
            }
            XCTAssertTrue(reason.contains("endpoint authority changed"))
            XCTAssertNil(runtime.lastArtifactScan)
        }
    }

    func testInitialCurrentnessFailureMarksPriorSourceStaleUnderGatewayBarrier()
        async throws {
        try await withFixture(includeRemote: true) { fixture in
            let runtime = FeedsRuntime.shared
            let remote = try XCTUnwrap(fixture.remote)
            let remoteURL = try XCTUnwrap(remote.baseURL)
            let remoteProfile = try XCTUnwrap(fixture.remoteProfile)
            let prior = seedPriorArtifact(
                model: fixture.model,
                gatewayID: remote.id,
                profile: remoteProfile
            )
            var profileReads: [String] = []
            runtime.artifactProfilesReadForTesting = { gatewayID, _ in
                profileReads.append(gatewayID)
                return gatewayID == fixture.primary.id
                    ? [fixture.primaryProfile] : [remoteProfile]
            }
            runtime.artifactSessionsReadForTesting = { _, _, _, limit in
                self.window([], limit: limit)
            }
            runtime.artifactAfterAuthorityCaptureForTesting = {
                let replacement = GatewayClient(
                    baseURL: remoteURL,
                    credential: .sessionToken("post-capture-replacement")
                )
                await ConnectionRegistry.shared.clientPool.adopt(
                    replacement, for: remote.id)
            }

            await fixture.model.refreshArtifacts(force: true)

            XCTAssertFalse(profileReads.contains(remote.id),
                           "a replaced captured source must fail before profiles.list")
            XCTAssertTrue(fixture.model.artifacts.contains(where: { $0.id == prior.id }))
            guard case .stale(reason: let reason)? =
                    runtime.artifactDiscoveryStatus[remote.id] else {
                return XCTFail("initial currentness failure must stale its prior result")
            }
            XCTAssertTrue(reason.contains("before discovery admission"))
            XCTAssertNil(runtime.lastArtifactScan)
        }
    }

    func testSaturatedSessionListIsIncompleteWithoutInventedCursor() async throws {
        try await withFixture { fixture in
            FeedsRuntime.shared.artifactSessionsReadForTesting = {
                _, _, _, limit in
                self.window(
                    (0..<limit).map { self.session("stored-\($0)", messageCount: 0) },
                    limit: limit,
                    returnedCount: limit
                )
            }

            await fixture.model.refreshArtifacts(force: true)

            guard case .incomplete(cursor: let cursor, reason: let reason)? =
                    FeedsRuntime.shared.artifactDiscoveryStatus[fixture.primary.id] else {
                return XCTFail("expected saturated incomplete source")
            }
            XCTAssertNil(cursor)
            XCTAssertTrue(reason.contains("upstream window"))
        }
    }

    func testFullTranscriptPageStoresOnlyInformationalOffsetContinuation() async throws {
        try await withFixture { fixture in
            let runtime = FeedsRuntime.shared
            runtime.artifactSessionsReadForTesting = { _, _, _, limit in
                self.window([self.session("long-stored")], limit: limit)
            }
            runtime.artifactTranscriptReadForTesting = { _, _, _, _, offset, limit in
                var rows = [self.artifactRow("/tmp/long.md")]
                rows.append(contentsOf: (1..<limit).map { index in
                    .object([
                        "role": .string("assistant"),
                        "content": .string("ordinary row \(index)")
                    ])
                })
                return self.page(
                    messages: rows,
                    sessionID: "resolved-long",
                    limit: limit,
                    offset: offset,
                    returnedCount: limit
                )
            }

            await fixture.model.refreshArtifacts(force: true)

            guard case .incomplete(cursor: let cursor?, reason: let reason)? =
                    runtime.artifactDiscoveryStatus[fixture.primary.id] else {
                return XCTFail("expected transcript continuation")
            }
            XCTAssertEqual(cursor.profile, fixture.primaryProfile)
            XCTAssertEqual(cursor.storedSessionID, "long-stored")
            XCTAssertEqual(cursor.resolvedSessionID, "resolved-long")
            XCTAssertEqual(cursor.offset, 150)
            XCTAssertTrue(reason.contains("informational"))
            XCTAssertTrue(reason.contains("not pageable"))
        }
    }

    func testOneSourceFailurePreservesItsPriorSnapshotAndDoesNotMaskPeer() async throws {
        try await withFixture(includeRemote: true) { fixture in
            let runtime = FeedsRuntime.shared
            let remote = try XCTUnwrap(fixture.remote)
            let prior = AppModel.artifact(
                from: "/tmp/prior.md",
                botID: fixture.primaryProfile,
                sessionID: "\(remote.id)\u{1f}prior-stored",
                sessionTitle: "Prior",
                at: Date(timeIntervalSince1970: 1_600_000_000)
            )
            fixture.model.artifacts = [prior]
            runtime.artifactSessions[prior.id] = SessionRef(
                gatewayID: remote.id,
                botID: fixture.primaryProfile,
                storedID: "prior-stored"
            )
            runtime.artifactDiscoveryStatus[remote.id] = .incomplete(
                cursor: nil, reason: "prior bounded snapshot")
            runtime.artifactSessionsReadForTesting = { gatewayID, _, _, limit in
                if gatewayID == remote.id { throw URLError(.cannotConnectToHost) }
                return self.window([], limit: limit)
            }

            await fixture.model.refreshArtifacts(force: true)

            XCTAssertTrue(fixture.model.artifacts.contains(where: { $0.id == prior.id }))
            guard case .stale(reason: let staleReason)? =
                    runtime.artifactDiscoveryStatus[remote.id] else {
                return XCTFail("failed source with prior rows must be stale")
            }
            XCTAssertTrue(staleReason.contains(fixture.primaryProfile))
            guard case .incomplete? =
                    runtime.artifactDiscoveryStatus[fixture.primary.id] else {
                return XCTFail("healthy peer must still publish")
            }
            XCTAssertNotNil(runtime.lastArtifactScan,
                            "a handled source failure completes the scan attempt")
        }
    }

    func testCancellationDoesNotAdvanceThrottleOrPublishPartialResult() async throws {
        try await withFixture { fixture in
            let runtime = FeedsRuntime.shared
            let started = ArtifactDiscoveryMarker()
            runtime.artifactSessionsReadForTesting = { _, _, _, _ in
                await started.mark()
                try await Task.sleep(for: .seconds(30))
                return self.window([])
            }

            let caller = Task { @MainActor in
                await fixture.model.refreshArtifacts(force: true)
            }
            let didStart = await artifactEventually { await started.read() }
            XCTAssertTrue(didStart)
            caller.cancel()
            await caller.value

            XCTAssertNil(runtime.lastArtifactScan)
            XCTAssertNil(runtime.artifactsTask)
            XCTAssertNil(runtime.artifactsTaskID)
            XCTAssertFalse(runtime.artifactsScanning)
            XCTAssertNil(runtime.artifactDiscoveryStatus[fixture.primary.id])
        }
    }

    func testRetainedReplacementDuringTranscriptReadRejectsOldClientResult() async throws {
        try await withFixture(includeRemote: true) { fixture in
            let runtime = FeedsRuntime.shared
            let remote = try XCTUnwrap(fixture.remote)
            let oldRemoteClient = try XCTUnwrap(fixture.remoteClient)
            let gate = ArtifactDiscoveryGate()
            runtime.artifactDiscoveryStatus[remote.id] = .incomplete(
                cursor: nil, reason: "prior exact snapshot")
            runtime.artifactSessionsReadForTesting = { gatewayID, _, _, limit in
                gatewayID == remote.id
                    ? self.window([self.session("remote-stored")], limit: limit)
                    : self.window([], limit: limit)
            }
            runtime.artifactTranscriptReadForTesting = {
                gatewayID, _, _, client, offset, limit in
                XCTAssertEqual(ObjectIdentifier(client), ObjectIdentifier(oldRemoteClient))
                if gatewayID == remote.id { await gate.wait() }
                return self.page(
                    messages: [self.artifactRow("/tmp/replaced.md")],
                    limit: limit,
                    offset: offset
                )
            }

            let scan = Task { @MainActor in
                await fixture.model.refreshArtifacts(force: true)
            }
            let reachedTranscript = await artifactEventually { await gate.hasEntered() }
            XCTAssertTrue(reachedTranscript)
            let replacement = GatewayClient(
                baseURL: try XCTUnwrap(remote.baseURL),
                credential: .sessionToken("replacement"))
            await ConnectionRegistry.shared.clientPool.adopt(replacement, for: remote.id)
            await gate.release()
            await scan.value

            XCTAssertFalse(fixture.model.artifacts.contains {
                AppModel.artifactValue($0.id) == "/tmp/replaced.md"
            })
            guard case .stale(reason: let reason)? =
                    runtime.artifactDiscoveryStatus[remote.id] else {
                return XCTFail("replaced retained source must remain explicitly stale")
            }
            XCTAssertTrue(reason.contains("prior exact-source snapshot retained"))
            XCTAssertNil(runtime.lastArtifactScan)
        }
    }

    func testReplacementBetweenFinalReadAndPublicationLosesCapturedLease() async throws {
        try await withFixture(includeRemote: true) { fixture in
            let runtime = FeedsRuntime.shared
            let remote = try XCTUnwrap(fixture.remote)
            let remoteURL = try XCTUnwrap(remote.baseURL)
            runtime.artifactDiscoveryStatus[remote.id] = .incomplete(
                cursor: nil, reason: "prior exact snapshot")
            runtime.artifactSessionsReadForTesting = { gatewayID, _, _, limit in
                gatewayID == remote.id
                    ? self.window([self.session("remote-stored")], limit: limit)
                    : self.window([], limit: limit)
            }
            runtime.artifactTranscriptReadForTesting = { _, _, _, _, offset, limit in
                self.page(
                    messages: [self.artifactRow("/tmp/lease-gap.md")],
                    limit: limit,
                    offset: offset
                )
            }
            runtime.artifactBeforePublicationForTesting = { gatewayID, _ in
                guard gatewayID == remote.id else { return }
                let replacement = GatewayClient(
                    baseURL: remoteURL,
                    credential: .sessionToken("publication-replacement"))
                await ConnectionRegistry.shared.clientPool.adopt(
                    replacement, for: remote.id)
            }

            await fixture.model.refreshArtifacts(force: true)

            XCTAssertFalse(fixture.model.artifacts.contains {
                AppModel.artifactValue($0.id) == "/tmp/lease-gap.md"
            })
            guard case .stale(reason: let reason)? =
                    runtime.artifactDiscoveryStatus[remote.id] else {
                return XCTFail("publication-gap replacement must remain explicitly stale")
            }
            XCTAssertTrue(reason.contains("prior exact-source snapshot retained"))
            XCTAssertNil(runtime.lastArtifactScan)
        }
    }

    func testProfileLifecycleChangeDuringProfileInventoryRejectsSessionReadAndPublication()
        async throws {
        try await withFixture { fixture in
            let runtime = FeedsRuntime.shared
            let gate = ArtifactDiscoveryGate()
            let sessionRead = ArtifactDiscoveryMarker()
            let route = GatewayBotRoute(
                gatewayID: fixture.primary.id,
                profile: fixture.primaryProfile
            )
            runtime.artifactDiscoveryStatus[fixture.primary.id] = .incomplete(
                cursor: nil, reason: "prior exact snapshot")
            runtime.artifactProfilesReadForTesting = { _, _ in
                await gate.wait()
                return [fixture.primaryProfile]
            }
            runtime.artifactSessionsReadForTesting = { _, _, _, limit in
                await sessionRead.mark()
                return self.window([], limit: limit)
            }

            let scan = Task { @MainActor in
                await fixture.model.refreshArtifacts(force: true)
            }
            let reachedTranscript = await artifactEventually { await gate.hasEntered() }
            XCTAssertTrue(reachedTranscript)
            fixture.model.invalidateProfileLifecycleRouteForTesting(route)
            await gate.release()
            await scan.value

            XCTAssertFalse(fixture.model.artifacts.contains {
                AppModel.artifactValue($0.id) == "/tmp/lifecycle-race.md"
            })
            let didReadSessions = await sessionRead.read()
            XCTAssertFalse(didReadSessions)
            guard case .stale(reason: let reason)? =
                    runtime.artifactDiscoveryStatus[fixture.primary.id] else {
                return XCTFail("profile lifecycle race must leave the prior snapshot stale")
            }
            XCTAssertTrue(reason.contains("prior exact-source snapshot retained"))
            XCTAssertNil(runtime.lastArtifactScan)
        }
    }

    func testRegistryCredentialRotationDuringTranscriptReadRejectsPublication() async throws {
        try await withFixture { fixture in
            let runtime = FeedsRuntime.shared
            let gate = ArtifactDiscoveryGate()
            runtime.artifactDiscoveryStatus[fixture.primary.id] = .incomplete(
                cursor: nil, reason: "prior exact snapshot")
            runtime.artifactSessionsReadForTesting = { _, _, _, limit in
                self.window([self.session("credential-stored")], limit: limit)
            }
            runtime.artifactTranscriptReadForTesting = { _, _, _, _, offset, limit in
                await gate.wait()
                return self.page(
                    messages: [self.artifactRow("/tmp/credential-race.md")],
                    limit: limit,
                    offset: offset
                )
            }

            let scan = Task { @MainActor in
                await fixture.model.refreshArtifacts(force: true)
            }
            let reachedTranscript = await artifactEventually { await gate.hasEntered() }
            XCTAssertTrue(reachedTranscript)
            ConnectionRegistry.shared.setCredential(
                .sessionToken("rotated-credential"),
                for: fixture.primary
            )
            await gate.release()
            await scan.value

            XCTAssertFalse(fixture.model.artifacts.contains {
                AppModel.artifactValue($0.id) == "/tmp/credential-race.md"
            })
            guard case .stale(reason: let reason)? =
                    runtime.artifactDiscoveryStatus[fixture.primary.id] else {
                return XCTFail("credential race must leave the prior snapshot stale")
            }
            XCTAssertTrue(reason.contains("prior exact-source snapshot retained"))
            XCTAssertNil(runtime.lastArtifactScan)
        }
    }

    func testTranscriptEnvelopeDecodesResolvedIdentityAndEchoedPagination() throws {
        let payload: JSONValue = .object([
            "session_id": .string("resolved-tip"),
            "messages": .array([
                .object(["role": .string("user"), "content": .string("one")]),
                .object(["role": .string("assistant"), "content": .string("two")])
            ]),
            "pagination": .object([
                "limit": .number(2),
                "offset": .number(3),
                "returned": .number(2),
                "order": .string("latest")
            ])
        ])
        let decoded = try ArtifactTranscriptPage(payload: payload)
        XCTAssertEqual(decoded.resolvedSessionID, "resolved-tip")
        XCTAssertEqual(decoded.offset, 3)
        XCTAssertEqual(decoded.returnedCount, 2)
        XCTAssertEqual(decoded.continuationOffset, 5)

        let malformed: JSONValue = .object([
            "session_id": .string("resolved-tip"),
            "messages": .array([]),
            "pagination": .object([
                "limit": .number(2),
                "offset": .number(0),
                "returned": .number(1),
                "order": .string("latest")
            ])
        ])
        XCTAssertThrowsError(try ArtifactTranscriptPage(payload: malformed))
    }

    func testPrimaryClientIdentityChangeKeepsRemoteArtifactRefsAndCards() async throws {
        try await withFixture(includeRemote: true) { fixture in
            let remote = try XCTUnwrap(fixture.remote)
            let primary = seedPriorArtifact(
                model: fixture.model, gatewayID: fixture.primary.id,
                profile: fixture.primaryProfile, value: "/tmp/primary.md")
            let remoteCard = AppModel.artifact(
                from: "/tmp/remote.md",
                botID: fixture.primaryProfile,
                sessionID: "\(remote.id)\u{1f}remote-stored",
                sessionTitle: "Remote",
                at: Date(timeIntervalSince1970: 1_700_000_000)
            )
            fixture.model.artifacts = [primary, remoteCard]
            FeedsRuntime.shared.artifactSessions[remoteCard.id] = SessionRef(
                gatewayID: remote.id,
                botID: fixture.primaryProfile,
                storedID: "remote-stored"
            )
            FeedsRuntime.shared.artifactDiscoveryStatus[remote.id] = .incomplete(
                cursor: nil, reason: "remote snapshot")

            FeedsRuntime.shared.routedClient = ObjectIdentifier(fixture.primaryClient)
            fixture.model.client = GatewayClient(
                baseURL: try XCTUnwrap(fixture.primary.baseURL),
                credential: .sessionToken("rotated-primary-client"))
            fixture.model.reconcileFeeds()

            XCTAssertEqual(
                FeedsRuntime.shared.artifactSessions[remoteCard.id]?.gatewayID, remote.id,
                "a primary client identity change must preserve remote session refs")
            XCTAssertEqual(
                FeedsRuntime.shared.artifactSessions[primary.id]?.gatewayID, fixture.primary.id)
            XCTAssertTrue(fixture.model.artifacts.contains { $0.id == remoteCard.id })
            XCTAssertTrue(fixture.model.artifacts.contains { $0.id == primary.id })
        }
    }

    func testDropArtifactScopeRemovesOnlyThatGatewayCardsAndRefs() async throws {
        try await withFixture(includeRemote: true) { fixture in
            let remote = try XCTUnwrap(fixture.remote)
            let primary = seedPriorArtifact(
                model: fixture.model, gatewayID: fixture.primary.id,
                profile: fixture.primaryProfile, value: "/tmp/primary.md")
            let remoteCard = AppModel.artifact(
                from: "/tmp/remote.md",
                botID: fixture.primaryProfile,
                sessionID: "\(remote.id)\u{1f}remote-stored",
                sessionTitle: "Remote",
                at: Date(timeIntervalSince1970: 1_700_000_000)
            )
            fixture.model.artifacts.append(remoteCard)
            FeedsRuntime.shared.artifactSessions[remoteCard.id] = SessionRef(
                gatewayID: remote.id,
                botID: fixture.primaryProfile,
                storedID: "remote-stored"
            )
            FeedsRuntime.shared.artifactDiscoveryStatus[remote.id] = .incomplete(
                cursor: nil, reason: "remote snapshot")

            fixture.model.dropArtifactScope(gatewayID: fixture.primary.id)

            XCTAssertFalse(fixture.model.artifacts.contains { $0.id == primary.id })
            XCTAssertNil(FeedsRuntime.shared.artifactSessions[primary.id])
            XCTAssertNil(FeedsRuntime.shared.artifactDiscoveryStatus[fixture.primary.id])
            XCTAssertTrue(fixture.model.artifacts.contains { $0.id == remoteCard.id })
            XCTAssertEqual(
                FeedsRuntime.shared.artifactSessions[remoteCard.id]?.gatewayID, remote.id)
        }
    }

    func testPrimarySignOutKeepsRemoteArtifactCards() async throws {
        try await withFixture(includeRemote: true) { fixture in
            let remote = try XCTUnwrap(fixture.remote)
            let primary = seedPriorArtifact(
                model: fixture.model, gatewayID: fixture.primary.id,
                profile: fixture.primaryProfile, value: "/tmp/primary.md")
            let remoteCard = AppModel.artifact(
                from: "/tmp/remote.md",
                botID: fixture.primaryProfile,
                sessionID: "\(remote.id)\u{1f}remote-stored",
                sessionTitle: "Remote",
                at: Date(timeIntervalSince1970: 1_700_000_000)
            )
            fixture.model.artifacts = [primary, remoteCard]
            FeedsRuntime.shared.artifactSessions[remoteCard.id] = SessionRef(
                gatewayID: remote.id,
                botID: fixture.primaryProfile,
                storedID: "remote-stored"
            )

            await fixture.model.signOutGateway(fixture.primary)

            XCTAssertFalse(fixture.model.artifacts.contains { $0.id == primary.id })
            XCTAssertNil(FeedsRuntime.shared.artifactSessions[primary.id])
            XCTAssertTrue(fixture.model.artifacts.contains { $0.id == remoteCard.id },
                          "primary sign-out must restore remote gallery cards")
            XCTAssertEqual(
                FeedsRuntime.shared.artifactSessions[remoteCard.id]?.gatewayID, remote.id)
        }
    }

    func testOpenArtifactWithoutRefDoesNotOpenCollidingPrimary() async throws {
        try await withFixture(includeRemote: true) { fixture in
            fixture.model.selectedTab = .artifacts
            fixture.model.openBotID = nil
            let orphan = AppModel.artifact(
                from: "/tmp/orphan.md",
                botID: fixture.primaryProfile,
                sessionID: "missing-ref",
                sessionTitle: "Orphan",
                at: Date()
            )
            fixture.model.artifacts = [orphan]

            fixture.model.openArtifact(orphan)

            XCTAssertNil(fixture.model.openBotID,
                         "a missing artifact ref must not openChat the colliding primary profile")
            XCTAssertEqual(fixture.model.selectedTab, .artifacts)
        }
    }

    func testLoadArtifactRefusesCacheAfterSourceCredentialIsDeleted() async throws {
        try await withFixture(includeRemote: true) { fixture in
            let remote = try XCTUnwrap(fixture.remote)
            let store = ArtifactStore.shared
            store.flush()
            let workspace = WorkspaceRuntime.shared
            let priorGateway = workspace.gatewayID
            let priorRoots = workspace.fileRoots
            let priorSources = workspace.fileRootSources
            defer {
                store.flush()
                workspace.gatewayID = priorGateway
                workspace.fileRoots = priorRoots
                workspace.fileRootSources = priorSources
            }

            workspace.gatewayID = remote.id
            workspace.fileRoots = ["/srv/hermes-managed"]
            workspace.fileRootSources = ["/srv/hermes-managed": .managed]
            let value = "/srv/hermes-managed/cached.bin"
            let source = ArtifactProvenance(
                gatewayID: remote.id, profile: fixture.primaryProfile,
                sessionID: "cached-stored", value: value)
            let lease = store.acquire(for: source) {
                Task { ArtifactBody.binary(Data([0xCC]), mime: "application/octet-stream") }
            }
            XCTAssertTrue(store.finish(
                .binary(Data([0xCC]), mime: "application/octet-stream"),
                lease: lease, for: source))
            XCTAssertEqual(store.body(for: source)?.data, Data([0xCC]))

            let artifact = AppModel.artifact(
                from: value,
                botID: fixture.primaryProfile,
                sessionID: "\(remote.id)\u{1f}cached-stored",
                sessionTitle: "Cached",
                at: Date()
            )
            FeedsRuntime.shared.artifactSessions[artifact.id] = SessionRef(
                gatewayID: remote.id,
                botID: fixture.primaryProfile,
                storedID: "cached-stored"
            )
            ConnectionSupervisor.shared.keychain.delete(for: try XCTUnwrap(remote.baseURL))

            let loaded = await fixture.model.loadArtifact(artifact)
            guard case .unavailable(.noREST) = loaded else {
                return XCTFail("a cache hit must not outlive the source credential")
            }
            XCTAssertNil(store.body(for: source),
                         "refusing a dead credential must evict that source's leftover bytes")
            XCTAssertNil(fixture.model.artifactBody(artifact))
        }
    }

    func testSecondarySignOutPurgesThatGatewayBodiesAndRefs() async throws {
        try await withFixture(includeRemote: true) { fixture in
            try await assertSecondaryTeardownPurges(
                fixture, operation: { await $0.signOutGateway($1) })
            XCTAssertNotNil(
                ConnectionRegistry.shared.saved.first { $0.id == fixture.remote?.id },
                "sign-out keeps the saved row")
        }
    }

    func testSecondaryRemovePurgesThatGatewayBodiesAndRefs() async throws {
        try await withFixture(includeRemote: true) { fixture in
            let remoteID = try XCTUnwrap(fixture.remote?.id)
            try await assertSecondaryTeardownPurges(
                fixture, operation: { await $0.removeGateway($1) })
            XCTAssertNil(ConnectionRegistry.shared.saved.first { $0.id == remoteID })
        }
    }

    private func assertSecondaryTeardownPurges(
        _ fixture: Fixture,
        operation: @MainActor (AppModel, SavedGateway) async -> Void
    ) async throws {
        let remote = try XCTUnwrap(fixture.remote)
        let store = ArtifactStore.shared
        store.flush()
        defer { store.flush() }

        let remoteSource = ArtifactProvenance(
            gatewayID: remote.id, profile: fixture.primaryProfile,
            sessionID: "remote-stored", value: "/tmp/remote.bin")
        let primarySource = ArtifactProvenance(
            gatewayID: fixture.primary.id, profile: fixture.primaryProfile,
            sessionID: "primary-stored", value: "/tmp/primary.bin")
        func publish(_ body: ArtifactBody, _ source: ArtifactProvenance) {
            let lease = store.acquire(for: source) { Task { body } }
            XCTAssertTrue(store.finish(body, lease: lease, for: source))
        }
        publish(.binary(Data([0xAA]), mime: "application/octet-stream"), remoteSource)
        publish(.binary(Data([0xBB]), mime: "application/octet-stream"), primarySource)

        let folder = FileManager.default.temporaryDirectory
            .appending(path: "talaria-media-secondary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "clip.mp4")
        try Data("remote media".utf8).write(to: file)
        let mediaSource = ArtifactProvenance(
            gatewayID: remote.id, profile: fixture.primaryProfile,
            sessionID: "remote-media", value: "/managed/clip.mp4")
        publish(.media(file), mediaSource)

        let remoteCard = AppModel.artifact(
            from: "/tmp/remote.bin",
            botID: fixture.primaryProfile,
            sessionID: "\(remote.id)\u{1f}remote-stored",
            sessionTitle: "Remote",
            at: Date()
        )
        fixture.model.artifacts.append(remoteCard)
        FeedsRuntime.shared.artifactSessions[remoteCard.id] = SessionRef(
            gatewayID: remote.id,
            botID: fixture.primaryProfile,
            storedID: "remote-stored"
        )

        await operation(fixture.model, remote)

        XCTAssertNil(store.body(for: remoteSource),
                     "secondary teardown must purge that gateway's cached bodies")
        XCTAssertNil(store.body(for: mediaSource))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "owned media for the signed-out source must be deleted")
        XCTAssertEqual(store.body(for: primarySource)?.data, Data([0xBB]),
                       "a peer gateway's cache must survive secondary teardown")
        XCTAssertNil(FeedsRuntime.shared.artifactSessions[remoteCard.id])
        XCTAssertFalse(fixture.model.artifacts.contains { $0.id == remoteCard.id })
        XCTAssertNil(ConnectionRegistry.shared.credential(for: remote))
    }
}
#endif
