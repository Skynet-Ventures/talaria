#if canImport(XCTest)
import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

@MainActor
private func clearMaintenanceFenceForTest(_ runtime: GatewayMaintenanceRuntime) {
    guard let fence = runtime.fence else { return }
    switch fence.outcome {
    case .pending:
        runtime.releaseDefinite(source: fence.source, action: fence.action)
    case .accepted, .uncertain:
        _ = runtime.acknowledge(source: fence.source, action: fence.action)
    }
}

final class ArtifactOperationsRemediationTests: XCTestCase {
    @MainActor
    func testArtifactCacheSeparatesIdenticalPathsByExactGatewayProfileAndSession() {
        let store = ArtifactStore.shared
        store.flush()
        defer { store.flush() }
        let first = ArtifactProvenance(gatewayID: "gateway-a", profile: "worker",
                                       sessionID: "session-1", value: "/tmp/output.png")
        let second = ArtifactProvenance(gatewayID: "gateway-b", profile: "worker",
                                        sessionID: "session-1", value: "/tmp/output.png")
        let third = ArtifactProvenance(gatewayID: "gateway-a", profile: "worker",
                                       sessionID: "session-2", value: "/tmp/output.png")
        func publish(_ body: ArtifactBody, _ source: ArtifactProvenance) {
            let lease = store.acquire(for: source) { Task { body } }
            store.finish(body, lease: lease, for: source)
        }
        publish(.binary(Data([0xA]), mime: "application/octet-stream"), first)
        publish(.binary(Data([0xB]), mime: "application/octet-stream"), second)
        publish(.binary(Data([0xC]), mime: "application/octet-stream"), third)

        XCTAssertEqual(store.body(for: first)?.data, Data([0xA]))
        XCTAssertEqual(store.body(for: second)?.data, Data([0xB]))
        XCTAssertEqual(store.body(for: third)?.data, Data([0xC]))
    }

    @MainActor
    func testArtifactStoreFlushByGatewayLeavesPeerBodiesAndCancelsInflight() async throws {
        let store = ArtifactStore.shared
        store.flush()
        defer { store.flush() }

        let keep = ArtifactProvenance(gatewayID: "gateway-a", profile: "worker",
                                      sessionID: "session-1", value: "/tmp/keep.bin")
        let drop = ArtifactProvenance(gatewayID: "gateway-b", profile: "worker",
                                      sessionID: "session-1", value: "/tmp/drop.bin")
        func publish(_ body: ArtifactBody, _ source: ArtifactProvenance) {
            let lease = store.acquire(for: source) { Task { body } }
            XCTAssertTrue(store.finish(body, lease: lease, for: source))
        }
        publish(.binary(Data([0xA]), mime: "application/octet-stream"), keep)
        publish(.binary(Data([0xB]), mime: "application/octet-stream"), drop)

        let folder = FileManager.default.temporaryDirectory
            .appending(path: "talaria-media-flush-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "clip.mp4")
        try Data("drop media".utf8).write(to: file)
        let media = ArtifactProvenance(gatewayID: "gateway-b", profile: "worker",
                                       sessionID: "media", value: "/managed/clip.mp4")
        publish(.media(file), media)

        let inflightSource = ArtifactProvenance(
            gatewayID: "gateway-b", profile: "worker", sessionID: "inflight",
            value: "/tmp/inflight.bin")
        let inflightTask = Task<ArtifactBody, Never> {
            while !Task.isCancelled { await Task.yield() }
            return .unavailable(.notLive)
        }
        _ = store.acquire(for: inflightSource) { inflightTask }

        store.flush(gatewayID: "gateway-b")

        XCTAssertEqual(store.body(for: keep)?.data, Data([0xA]))
        XCTAssertNil(store.body(for: drop))
        XCTAssertNil(store.body(for: media))
        XCTAssertEqual(store.inflightWaiterCount(for: inflightSource), 0)
        XCTAssertTrue(inflightTask.isCancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "flush(gatewayID:) must delete that source's owned media")
        _ = await inflightTask.value
    }

    func testMediaRequestsKeepSessionAndOAuthSecretsOutOfURL() throws {
        let base = try XCTUnwrap(URL(string: "https://gateway.example/base/"))
        let session = try GatewayREST.authenticatedMediaRequest(
            baseURL: base, credential: .sessionToken("session-secret"), path: "/tmp/movie.mp4")
        XCTAssertFalse(try XCTUnwrap(session.url?.absoluteString).contains("session-secret"))
        XCTAssertEqual(session.value(forHTTPHeaderField: "X-Hermes-Session-Token"),
                       "session-secret")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(session.url),
                                     resolvingAgainstBaseURL: false)?.queryItems?.map(\.name),
                       ["path"])

        let tokens = TokenSet(accessToken: "oauth-secret", refreshToken: "refresh",
                              expiresAt: 4_000_000_000, provider: "nous", userID: nil)
        let oauth = try GatewayREST.authenticatedMediaRequest(
            baseURL: base, credential: .oauth(tokens), path: "/tmp/audio.m4a")
        XCTAssertFalse(try XCTUnwrap(oauth.url?.absoluteString).contains("oauth-secret"))
        XCTAssertEqual(oauth.value(forHTTPHeaderField: "Authorization"),
                       "Bearer oauth-secret")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(oauth.url),
                                     resolvingAgainstBaseURL: false)?.queryItems?.map(\.name),
                       ["path"])
    }

    func testManagedArtifactReadUsesPinnedHermesRouteAndExactPathQuery() throws {
        let base = try XCTUnwrap(URL(string: "https://gateway.example/base/"))
        let request = try GatewayREST.managedReadRequest(
            baseURL: base, credential: .sessionToken("session-secret"),
            path: "/srv/hermes-managed/renders/output.png")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/base/api/files/read")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url),
                                     resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "path", value: "/srv/hermes-managed/renders/output.png")])
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hermes-Session-Token"),
                       "session-secret")
        XCTAssertFalse(try XCTUnwrap(request.url?.absoluteString).contains("/read/managed"))
    }

    func testGatewayOperationsRequireCanApplyAndExactAcceptedReceipt() throws {
        let unavailable = GatewayCommandAction(.object([
            "can_apply": .bool(false), "update_available": .bool(true),
            "update_command": .string("docker pull hermes"),
        ]))
        XCTAssertFalse(GatewayOperationsPolicy.canApplyUpdate(unavailable))
        XCTAssertTrue(GatewayOperationsPolicy.canApplyUpdate(GatewayCommandAction(.object([
            "can_apply": .bool(true),
        ]))))

        let accepted = try GatewayOperationsPolicy.acceptedReceipt(.object([
            "ok": .bool(true), "name": .string("hermes-update"), "pid": .number(42),
        ]), expectedName: "hermes-update")
        XCTAssertTrue(accepted.ok)
        XCTAssertEqual(accepted.name, "hermes-update")
        XCTAssertEqual(accepted.pid, 42)

        for malformed: JSONValue in [
            .object(["name": .string("hermes-update"), "pid": .number(42)]),
            .object(["ok": .bool(true), "name": .string("other"), "pid": .number(42)]),
            .object(["ok": .bool(true), "name": .string("hermes-update")]),
            .object(["ok": .bool(true), "name": .string("hermes-update"), "pid": .number(0)]),
        ] {
            XCTAssertThrowsError(try GatewayOperationsPolicy.acceptedReceipt(
                malformed, expectedName: "hermes-update"))
        }
        XCTAssertTrue(GatewayOperationsPolicy.isAmbiguous(
            GatewayError(code: -5, message: "timeout")))
        XCTAssertFalse(GatewayOperationsPolicy.isAmbiguous(
            GatewayError(code: 409, message: "refused")))
        XCTAssertTrue(GatewayOperationsPolicy.shouldFence(
            postStarted: true, error: CancellationError()))
        XCTAssertFalse(GatewayOperationsPolicy.shouldFence(
            postStarted: false, error: CancellationError()))
    }

    func testEveryBackgroundOperationRequiresExactActionPIDReceipts() throws {
        for name in ["doctor", "security-audit", "backup", "curator-run",
                     "gateway-restart", "hermes-update"] {
            let accepted = try GatewayOperationsPolicy.acceptedReceipt(.object([
                "ok": .bool(true), "name": .string(name), "pid": .number(91),
            ]), expectedName: name)
            XCTAssertEqual(accepted.pid, 91)

            let running = try GatewayOperationsPolicy.statusReceipt(.object([
                "name": .string(name), "pid": .number(91), "running": .bool(true),
            ]), expectedName: name, expectedPID: 91)
            XCTAssertTrue(running.running)
            XCTAssertThrowsError(try GatewayOperationsPolicy.statusReceipt(.object([
                "name": .string(name), "pid": .number(92), "running": .bool(true),
            ]), expectedName: name, expectedPID: 91),
            "a replacement PID must never satisfy the accepted action poll")
            XCTAssertThrowsError(try GatewayOperationsPolicy.statusReceipt(.object([
                "name": .string(name), "pid": .number(91), "running": .bool(false),
            ]), expectedName: name, expectedPID: 91),
            "terminal status needs an explicit exit code")
        }
    }

    func testSynchronousOperationFamiliesRequireSemanticReceipts() throws {
        XCTAssertNoThrow(try GatewayOperationsPolicy.requireOKReceipt(.object([
            "ok": .bool(true),
        ]), operation: "Config update"))
        for malformed: JSONValue in [
            .object([:]), .object(["ok": .bool(false)]),
            .object(["ok": .string("true")]),
        ] {
            XCTAssertThrowsError(try GatewayOperationsPolicy.requireOKReceipt(
                malformed, operation: "Config update"))
        }
        XCTAssertTrue(GatewayOperationsPolicy.shouldFence(
            postStarted: true,
            error: AckValidationError(operation: "Config update")),
            "a malformed 2xx config response cannot release the no-replay fence")

        XCTAssertNoThrow(try GatewayOperationsPolicy.requireBooleanReceipt(.object([
            "ok": .bool(true), "paused": .bool(true),
        ]), operation: "Curator pause", field: "paused", expected: true))
        XCTAssertThrowsError(try GatewayOperationsPolicy.requireBooleanReceipt(.object([
            "ok": .bool(true), "paused": .bool(false),
        ]), operation: "Curator pause", field: "paused", expected: true))

        XCTAssertNoThrow(try GatewayOperationsPolicy.requireMemoryResetReceipt(.object([
            "ok": .bool(true), "deleted": .array([.string("memory")]),
        ])))
        XCTAssertThrowsError(try GatewayOperationsPolicy.requireMemoryResetReceipt(.object([
            "ok": .bool(true),
        ])))

        XCTAssertNoThrow(try GatewayOperationsPolicy.requireDebugShareReceipt(.object([
            "ok": .bool(true), "urls": .object([:]), "failures": .object([:]),
            "redacted": .bool(true), "auto_delete_seconds": .number(3_600),
        ])))
        XCTAssertThrowsError(try GatewayOperationsPolicy.requireDebugShareReceipt(.object([
            "ok": .bool(true), "urls": .object([:]), "failures": .object([:]),
            "redacted": .bool(false), "auto_delete_seconds": .number(3_600),
        ])))
    }

    @MainActor
    func testConfigMutationUsesPersistentCrossSurfaceMaintenanceAdmission() {
        let maintenance = GatewayMaintenanceRuntime.shared
        let workspace = WorkspaceRuntime.shared
        clearMaintenanceFenceForTest(maintenance)
        _ = workspace.begin(gatewayID: "gateway-a")
        defer {
            clearMaintenanceFenceForTest(maintenance)
            _ = workspace.begin(gatewayID: nil)
        }
        let source = GatewayMaintenanceSource(gatewayID: "gateway-a", profile: "worker")
        XCTAssertTrue(maintenance.begin(source: source, action: "config-agent.max_turns"))
        maintenance.markUncertain(source: source, action: "config-agent.max_turns")

        _ = workspace.begin(gatewayID: "gateway-b")

        XCTAssertEqual(maintenance.fence, GatewayMaintenanceFence(
            source: source, action: "config-agent.max_turns", outcome: .uncertain))
        XCTAssertNil(workspace.claimMutation())
        XCTAssertFalse(maintenance.begin(source: source, action: "doctor"))
    }

    @MainActor
    func testMaintenanceFenceSurvivesScopeChangesAndBlocksAcceptedOrAmbiguousReplay() {
        let runtime = GatewayMaintenanceRuntime.shared
        clearMaintenanceFenceForTest(runtime)
        defer { clearMaintenanceFenceForTest(runtime) }
        let source = GatewayMaintenanceSource(gatewayID: "gateway-a", profile: "worker")

        XCTAssertTrue(runtime.begin(source: source, action: "hermes-update"))
        runtime.accept(source: source, action: "hermes-update", pid: 0)
        XCTAssertEqual(runtime.fence?.outcome, .pending)
        runtime.accept(source: source, action: "hermes-update", pid: 77)
        XCTAssertEqual(runtime.fence,
                       GatewayMaintenanceFence(source: source, action: "hermes-update",
                                               outcome: .accepted(pid: 77)))
        XCTAssertFalse(runtime.begin(source: source, action: "gateway-restart"),
                       "an accepted update must block an overlapping restart")

        XCTAssertTrue(runtime.acknowledge(source: source, action: "hermes-update"))
        XCTAssertTrue(runtime.begin(source: source, action: "gateway-restart"))
        runtime.markUncertain(source: source, action: "gateway-restart")
        XCTAssertFalse(runtime.fence?.source.matches(gatewayID: "gateway-b", profile: nil) == true)
        XCTAssertTrue(runtime.fence?.source.matches(gatewayID: "gateway-a", profile: "worker") == true,
                      "the ambiguous fence must survive navigating away and back")
        XCTAssertFalse(runtime.begin(source: source, action: "hermes-update"))
    }

    @MainActor
    func testMaintenanceAcknowledgeRequiresExactSourceProfileAndAction() {
        let runtime = GatewayMaintenanceRuntime.shared
        clearMaintenanceFenceForTest(runtime)
        defer { clearMaintenanceFenceForTest(runtime) }

        let source = GatewayMaintenanceSource(gatewayID: "gateway-a", profile: "worker")
        XCTAssertTrue(runtime.begin(source: source, action: "gateway-restart"))
        XCTAssertFalse(runtime.canAcknowledge(source: source, action: "gateway-restart"),
                       "a pending receipt is not an acknowledgement")
        XCTAssertFalse(runtime.acknowledge(source: source, action: "gateway-restart"))
        XCTAssertNotNil(runtime.fence)

        runtime.accept(source: source, action: "gateway-restart", pid: 42)
        let mismatches = [
            (GatewayMaintenanceSource(gatewayID: "gateway-b", profile: "worker"), "gateway-restart"),
            (GatewayMaintenanceSource(gatewayID: "gateway-a", profile: nil), "gateway-restart"),
            (GatewayMaintenanceSource(gatewayID: "gateway-a", profile: "other"), "gateway-restart"),
            (source, "hermes-update"),
        ]
        for (mismatchedSource, action) in mismatches {
            XCTAssertFalse(runtime.canAcknowledge(source: mismatchedSource, action: action))
            XCTAssertFalse(runtime.acknowledge(source: mismatchedSource, action: action),
                           "a stale or differently scoped button must not clear the fence")
            XCTAssertNotNil(runtime.fence)
        }

        XCTAssertTrue(runtime.acknowledge(source: source, action: "gateway-restart"))
        XCTAssertNil(runtime.fence)
    }

    func testDelayedMaintenanceClientResolutionRejectsScopeFlipBeforePost() {
        let source = GatewayMaintenanceSource(gatewayID: "gateway-a", profile: "worker")
        XCTAssertTrue(GatewayOperationsPolicy.canIssuePost(
            source: source, capturedScopeKey: "gateway-a\u{1f}worker", capturedGeneration: 4,
            currentGatewayID: "gateway-a", currentProfile: "worker",
            currentScopeKey: "gateway-a\u{1f}worker", currentGeneration: 4))
        XCTAssertFalse(GatewayOperationsPolicy.canIssuePost(
            source: source, capturedScopeKey: "gateway-a\u{1f}worker", capturedGeneration: 4,
            currentGatewayID: "gateway-b", currentProfile: "worker",
            currentScopeKey: "gateway-b\u{1f}worker", currentGeneration: 5),
            "a scope flip while client resolution is suspended must prevent the POST")
    }

    @MainActor
    func testArtifactSweepIdentitySeparatesTwoSourcesWithSameProfilePathAndSession() {
        let row: JSONValue = .object([
            "role": .string("tool"), "tool_name": .string("image_generate"),
            "content": .string("MEDIA: /tmp/output.png"),
            "timestamp": .number(1_700_000_000),
        ])
        let first = AppModel.artifacts(in: [row], botID: "worker", sessionID: "same-session",
                                       sessionTitle: "render", sessionStart: nil,
                                       sourceGatewayID: "gateway-a")
        let second = AppModel.artifacts(in: [row], botID: "worker", sessionID: "same-session",
                                        sessionTitle: "render", sessionStart: nil,
                                        sourceGatewayID: "gateway-b")
        XCTAssertEqual(first.first?.botID, "worker")
        XCTAssertNotEqual(first.first?.id, second.first?.id)
        XCTAssertNotEqual(
            AppModel.artifactSourceKey(gatewayID: "gateway-a", botID: "worker",
                                       value: "/tmp/output.png"),
            AppModel.artifactSourceKey(gatewayID: "gateway-b", botID: "worker",
                                       value: "/tmp/output.png"))
        let sourceRoute = GatewayBotRoute(gatewayID: "gateway-a", profile: "worker")
        let foreignRoute = GatewayBotRoute(gatewayID: "gateway-b", profile: "worker")
        XCTAssertEqual(AppModel.artifactSweepProfile(route: sourceRoute,
                                                      sourceGatewayID: "gateway-a"), "worker")
        XCTAssertNil(AppModel.artifactSweepProfile(route: foreignRoute,
                                                    sourceGatewayID: "gateway-a"))
    }

    @MainActor
    func testArtifactFetchWaitersCancelOnlyTheSoleUnderlyingFetch() async {
        let store = ArtifactStore.shared
        store.flush()
        defer { store.flush() }
        let source = ArtifactProvenance(gatewayID: "gateway", profile: "worker",
                                        sessionID: "session", value: "/tmp/video.mp4")
        let task = Task<ArtifactBody, Never> {
            while !Task.isCancelled { await Task.yield() }
            return .unavailable(.notLive)
        }
        let first = store.acquire(for: source) { task }
        let second = store.acquire(for: source) { task }
        XCTAssertEqual(store.inflightWaiterCount(for: source), 2)
        store.release(first, cancelIfLast: true)
        XCTAssertEqual(store.inflightWaiterCount(for: source), 1)
        XCTAssertFalse(task.isCancelled)
        store.release(second, cancelIfLast: true)
        XCTAssertEqual(store.inflightWaiterCount(for: source), 0)
        XCTAssertTrue(task.isCancelled)
        _ = await task.value
    }

    @MainActor
    func testCancelledArtifactWaiterCannotDeleteMediaOwnedBySecondWaiter() async throws {
        let store = ArtifactStore.shared
        store.flush()
        defer { store.flush() }

        let folder = FileManager.default.temporaryDirectory
            .appending(path: "talaria-media-two-waiters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "clip.mp4")
        try Data("shared media".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: folder) }

        let source = ArtifactProvenance(gatewayID: "gateway", profile: "worker",
                                        sessionID: "session", value: "/managed/clip.mp4")
        let body = ArtifactBody.media(file)
        let task = Task<ArtifactBody, Never> { body }
        let first = store.acquire(for: source) { task }
        let second = store.acquire(for: source) { task }

        store.release(first, cancelIfLast: true)
        store.discard(body, lease: first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "a cancelled waiter cannot delete a file still owned by a sibling")

        XCTAssertTrue(store.finish(body, lease: second, for: source))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "the cache owner keeps shared media alive after publication")
        _ = await task.value
    }

    @MainActor
    func testMediaSweepDeletesOrphansButPreservesOldCachedAndInflightMedia() async throws {
        let store = ArtifactStore.shared
        store.flush()
        defer { store.flush() }
        let manager = FileManager.default
        let old = Date().addingTimeInterval(-7_200)

        func makeOldMediaFolder(_ label: String) throws -> (folder: URL, file: URL) {
            let folder = manager.temporaryDirectory
                .appending(path: "talaria-media-\(label)-\(UUID().uuidString)")
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: "clip.mp4")
            try Data("media".utf8).write(to: file)
            try manager.setAttributes([.modificationDate: old], ofItemAtPath: folder.path)
            return (folder, file)
        }

        let cached = try makeOldMediaFolder("cached")
        let cachedSource = ArtifactProvenance(
            gatewayID: "gateway", profile: "worker", sessionID: "cached-session",
            value: "/managed/cached.mp4")
        let cachedBody = ArtifactBody.media(cached.file)
        let cachedLease = store.acquire(for: cachedSource) { Task { cachedBody } }
        XCTAssertTrue(store.finish(cachedBody, lease: cachedLease, for: cachedSource))

        let inflight = try makeOldMediaFolder("inflight")
        let inflightSource = ArtifactProvenance(
            gatewayID: "gateway", profile: "worker", sessionID: "inflight-session",
            value: "/managed/inflight.mp4")
        let inflightBody = ArtifactBody.media(inflight.file)
        let inflightLease = store.acquire(for: inflightSource) { Task { inflightBody } }
        store.retainInflightMedia(inflightBody, lease: inflightLease)

        let orphan = try makeOldMediaFolder("orphan")
        let orphanModified = try XCTUnwrap(
            manager.attributesOfItem(atPath: orphan.folder.path)[.modificationDate] as? Date)
        XCTAssertLessThan(orphanModified, Date().addingTimeInterval(-3_600),
                          "fixture must be older than the media TTL")
        store.sweepOrphanMediaDownloads()

        XCTAssertTrue(manager.fileExists(atPath: cached.file.path),
                      "an old media body owned by ArtifactStore must survive TTL cleanup")
        XCTAssertTrue(manager.fileExists(atPath: inflight.file.path),
                      "an in-flight media result must survive TTL cleanup")
        XCTAssertFalse(manager.fileExists(atPath: orphan.folder.path),
                        "unowned old media folders remain safe to reap")

        store.release(inflightLease, cancelIfLast: true)
        _ = await inflightLease.task.value
        store.discard(inflightBody, lease: inflightLease)
    }

    @MainActor
    func testInlineDataCapAndOwnedShareCleanup() throws {
        let exactBytes = ArtifactStore.maxFetchBytes
        let exactEncoded = String(repeating: "A", count: ((exactBytes + 2) / 3) * 4)
        XCTAssertTrue(AppModel.dataURLFitsArtifactLimit("data:image/png;base64,\(exactEncoded)"))
        XCTAssertFalse(AppModel.dataURLFitsArtifactLimit(
            "data:image/png;base64,\(exactEncoded)AAAA"))
        let mediaFixture = "data:image/png;base64,\(exactEncoded)AAAA"
        if case .unavailable(.tooLarge) = AppModel.boundedArtifactDataURL(mediaFixture) {
            // Expected: `/api/media` is rejected before its oversized base64 is decoded.
        } else {
            XCTFail("oversized /api/media data URL must fail closed")
        }

        let staged = try TalariaExportBox.write(Data("share".utf8), named: "report.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        TalariaExportBox.removeOwned(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))

        let cachedMedia = FileManager.default.temporaryDirectory
            .appending(path: "talaria-media-test-\(UUID().uuidString)")
        try Data("media".utf8).write(to: cachedMedia)
        TalariaExportBox.removeOwned(cachedMedia)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachedMedia.path),
                      "share cleanup must never delete cached media")
        try FileManager.default.removeItem(at: cachedMedia)
    }

    @MainActor
    func testTranscriptHostPathsRequireValidatedManagedRootAndRejectCredentialPaths() {
        let gateway = "gateway-a"
        let root = "/srv/hermes-managed"
        let admitted = AppModel.artifactPathAdmission(
            "/srv/hermes-managed/renders/output.png", gatewayID: gateway,
            workspaceGatewayID: gateway, managedRoots: [root])
        XCTAssertEqual(admitted, .managed(path: "/srv/hermes-managed/renders/output.png",
                                          root: root))

        XCTAssertEqual(
            AppModel.artifactPathAdmission("/Users/alice/.hermes/auth.json",
                                           gatewayID: gateway,
                                           workspaceGatewayID: gateway,
                                           managedRoots: [root]),
            .unproven,
            "a transcript-mentioned absolute credential path is not a managed-file proof")
        XCTAssertEqual(
            AppModel.artifactPathAdmission("/srv/hermes-managed/.ssh/id_ed25519",
                                           gatewayID: gateway,
                                           workspaceGatewayID: gateway,
                                           managedRoots: [root]),
            .unproven,
            "sensitive paths remain blocked even when lexically under the managed root")
        XCTAssertEqual(
            AppModel.artifactPathAdmission("/srv/hermes-managed/../outside/report.png",
                                           gatewayID: gateway,
                                           workspaceGatewayID: gateway,
                                           managedRoots: [root]),
            .unproven,
            "normalization must not widen the managed root")
        XCTAssertEqual(
            AppModel.artifactPathAdmission("/srv/hermes-managed/renders/output.png",
                                           gatewayID: gateway,
                                           workspaceGatewayID: "gateway-b",
                                           managedRoots: [root]),
            .unproven,
            "a root from another gateway cannot authorize this transcript")
    }

    @MainActor
    func testManagedArtifactProofRejectsSymlinkResolvedOutsideLockedRoot() throws {
        let requested = "/srv/hermes-managed/renders/credential.png"
        let lexical = AppModel.artifactPathAdmission(
            requested, gatewayID: "gateway-a", workspaceGatewayID: "gateway-a",
            managedRoots: ["/srv/hermes-managed"])
        XCTAssertEqual(lexical, .managed(path: requested, root: "/srv/hermes-managed"))

        // The gateway's locked read route resolves the symlink before returning
        // `path`. A response that resolves outside the locked root must not be
        // accepted merely because the requested spelling was lexical-in-root.
        let response: JSONValue = .object([
            "name": .string("credential.png"),
            "path": .string("/Users/hermes/.config/credentials.png"),
            "root": .string("/srv/hermes-managed"),
            "locked_root": .string("/srv/hermes-managed"),
            "mime_type": .string("image/png"),
            "size": .number(3),
            "data_url": .string("data:image/png;base64,YWJj"),
        ])
        XCTAssertThrowsError(try GatewayREST.authoritativeManagedRead(
            response, requestedPath: requested),
        "the artifact reader must not accept a symlink escape")
        XCTAssertThrowsError(try ManagedFileBody(validatingManaged: response,
                                                 requestedPath: requested),
        "the authoritative managed response must reject a symlink escape")
    }

    @MainActor
    func testUnprovenTranscriptArtifactFailsClosedBeforeGatewayFetch() async {
        let workspace = WorkspaceRuntime.shared
        let priorGateway = workspace.gatewayID
        let priorRoots = workspace.fileRoots
        let priorSources = workspace.fileRootSources
        let feeds = FeedsRuntime.shared
        let priorSessions = feeds.artifactSessions
        defer {
            workspace.gatewayID = priorGateway
            workspace.fileRoots = priorRoots
            workspace.fileRootSources = priorSources
            feeds.artifactSessions = priorSessions
        }

        workspace.gatewayID = "gateway-a"
        workspace.fileRoots = ["/srv/hermes-managed"]
        workspace.fileRootSources = ["/srv/hermes-managed": .managed]

        let artifact = AppModel.artifact(from: "/Users/alice/.hermes/auth.json",
                                         botID: "worker", sessionID: "session-1",
                                         sessionTitle: "render", at: Date())
        feeds.artifactSessions[artifact.id] = SessionRef(
            gatewayID: "gateway-a", botID: "worker", storedID: "session-1")
        let model = AppModel()
        model.mode = .live

        let body = await model.loadArtifact(artifact)
        guard case .unavailable(.unproven) = body else {
            return XCTFail("an unproven transcript host path must not reach any REST file route")
        }
    }

    @MainActor
    func testDataURLBoundHonorsMissingAndFalseDeclaredSizes() {
        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        let value = "data:application/octet-stream;base64,\(bytes.base64EncodedString())"

        if case .image(let decoded) = AppModel.boundedArtifactDataURL(value, declaredSize: nil) {
            XCTAssertEqual(decoded, bytes, "missing size is still bounded by encoded and decoded checks")
        } else {
            XCTFail("a small data URL without a size declaration should decode")
        }
        if case .image(let decoded) = AppModel.boundedArtifactDataURL(value,
                                                                       declaredSize: bytes.count) {
            XCTAssertEqual(decoded, bytes)
        } else {
            XCTFail("a truthful declared size should be accepted")
        }
        if case .unavailable(.unreadable(_)) = AppModel.boundedArtifactDataURL(value,
                                                                                declaredSize: bytes.count - 1) {
            // A false low declaration is rejected after exact decode.
        } else {
            XCTFail("a false declared size must not be trusted")
        }
        if case .unavailable(.tooLarge) = AppModel.boundedArtifactDataURL(value,
                                                                           declaredSize: ArtifactStore.maxFetchBytes + 1) {
            // The server-declared ceiling is checked before decode.
        } else {
            XCTFail("a declared size over the mobile ceiling must fail closed")
        }

        let maximumBase64Characters = ((ArtifactStore.maxFetchBytes + 2) / 3) * 4
        let oversizedEncoded = String(repeating: "A", count: maximumBase64Characters + 4)
        let oversized = "data:image/png;base64,\(oversizedEncoded)"
        XCTAssertNil(AppModel.dataURLDecodedUpperBound(oversized),
                     "encoded-length preflight must reject oversized payloads")
        if case .unavailable(.tooLarge) = AppModel.boundedArtifactDataURL(oversized,
                                                                            declaredSize: nil) {
            // Missing server size cannot bypass encoded-length preflight.
        } else {
            XCTFail("an oversized encoded payload without a size must fail before decode")
        }
    }

    func testDeclaredFileSizeRejectsNonFiniteAndOutOfRangeNumbers() {
        let valid: JSONValue = .object(["size": .number(4)])
        XCTAssertEqual(try? GatewayREST.validatedDeclaredByteSize(valid), 4)
        XCTAssertNil(try? GatewayREST.validatedDeclaredByteSize(.object([:])))

        let malformed: [Double] = [
            1e300,
            Double.nan,
            Double.infinity,
            -Double.infinity,
            -1,
            1.5,
            Double(Int.max),
        ]
        for raw in malformed {
            XCTAssertThrowsError(
                try GatewayREST.validatedDeclaredByteSize(.object(["size": .number(raw)])),
                "size (raw) must be rejected before Int conversion")
        }
        XCTAssertThrowsError(try GatewayREST.validatedDeclaredByteSize(
            .object(["byteSize": .string("NaN")]))
        )
    }
}
#endif
