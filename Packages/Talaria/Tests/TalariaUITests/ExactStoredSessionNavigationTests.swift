#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI

private actor RoutedEventProbe {
    private(set) var events: [GatewayEvent] = []

    func record(_ event: GatewayEvent) { events.append(event) }
}

@MainActor
final class ExactStoredSessionNavigationTests: XCTestCase {
    private func route(gateway: String = "primary", profile: String = "inbox",
                       session: String = "stored-42") throws -> ExactStoredSessionRoute {
        try XCTUnwrap(ExactStoredSessionRoute(
            gatewayID: gateway, profile: profile, storedSessionID: session))
    }

    func testColdLaunchRequestWaitsForRestoreThenOpensExactlyOnce() async throws {
        let queue = ExactStoredSessionRouteQueue()
        let exact = try route()
        var restored = false
        var opened: [ExactStoredSessionRoute] = []
        var failures: [String] = []

        XCTAssertEqual(queue.submit(
            ExactStoredSessionRouteRequest(
                route: exact, origin: .deepLink, waitsForLaunchRestore: true),
            alreadyVisible: false,
            execute: { request in
                guard restored else { return .deferred }
                opened.append(request.route)
                return .opened
            },
            reject: { _, message in failures.append(message) }), .started)
        await queue.awaitCurrentAttempt()

        XCTAssertEqual(queue.pending?.route, exact)
        XCTAssertTrue(opened.isEmpty)
        restored = true
        queue.nudge()
        await queue.awaitCurrentAttempt()

        XCTAssertEqual(opened, [exact])
        XCTAssertEqual(queue.completedOpenCount, 1)
        XCTAssertNil(queue.pending)
        XCTAssertTrue(failures.isEmpty)
    }

    func testColdLaunchResponseNotificationDoesNotUseTransientDemoMode() async throws {
        let model = AppModel()
        let registry = ConnectionRegistry.shared
        let baseURL = try XCTUnwrap(URL(
            string: "https://cold-push-\(UUID().uuidString).example"))
        let saved = try XCTUnwrap(registry.upsert(
            urlString: baseURL.absoluteString,
            name: "Cold push",
            credential: .sessionToken("cold-push-token")))
        let exact = try route(gateway: saved.id)
        var authoritativeOpens: [ExactStoredSessionRoute] = []
        var attempts = 0
        model.exactStoredSessionSourceReadinessOverride = { _ in
            attempts += 1
            guard model.launchWorldRestoreCompleted, model.mode == .live else {
                return false
            }
            return true
        }
        model.exactStoredSessionOpenOverride = { route in
            authoritativeOpens.append(route)
        }
        defer {
            model.exactStoredSessionSourceReadinessOverride = nil
            model.exactStoredSessionOpenOverride = nil
            registry.remove(id: saved.id)
        }

        // AppModel deliberately initializes in `.demo` while launch restore
        // chooses a real saved world. That transient value is not permission
        // to use openStoredSession's canned-world path.
        XCTAssertEqual(model.mode, .demo)
        XCTAssertFalse(model.demoDataLoaded)
        PushDefaultActionRouter.route(
            PushNotificationPayload(
                wireKind: PushKind.response.rawValue,
                kind: .response,
                gatewayID: exact.gatewayID,
                bot: exact.profile,
                title: "inbox",
                body: "Response ready",
                approvalRequestID: nil,
                sessionID: exact.storedSessionID,
                deeplink: URL(string: "talaria://bot/inbox?session_id=stored-42&gateway_id=\(saved.id)")),
            in: model,
            knownGatewayIDs: [exact.gatewayID])
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()

        XCTAssertEqual(attempts, 0,
                       "launch-pending route must not cross the source boundary")
        XCTAssertEqual(model.exactStoredSessionRouteQueue.pending?.route, exact)
        XCTAssertNil(model.openBotID, "cold response must not mutate demo navigation")
        XCTAssertTrue(model.chats.isEmpty, "cold response must not create a demo/shadow chat")
        XCTAssertTrue(authoritativeOpens.isEmpty)

        model.mode = .live
        model.completeLaunchWorldRestore()
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(authoritativeOpens, [exact])
        XCTAssertEqual(model.exactStoredSessionRouteQueue.completedOpenCount, 1)
        XCTAssertNil(model.exactStoredSessionRouteQueue.pending)
    }

    func testOfflineColdTapRetriesExactSavedSourceAfterNetworkRestores() async throws {
        let model = AppModel()
        let registry = ConnectionRegistry.shared
        let baseURL = try XCTUnwrap(URL(
            string: "https://offline-push-\(UUID().uuidString).example"))
        let saved = try XCTUnwrap(registry.upsert(
            urlString: baseURL.absoluteString,
            name: "Offline push",
            credential: .sessionToken("offline-push-token")))
        let exact = try route(gateway: saved.id)
        var networkAvailable = false
        var dialAttempts = 0
        var authoritativeOpens: [ExactStoredSessionRoute] = []
        model.exactStoredSessionSourceReadinessOverride = { requested in
            XCTAssertEqual(requested.gatewayID, saved.id,
                           "retry must dial only the stamped saved source")
            dialAttempts += 1
            guard networkAvailable else { throw URLError(.notConnectedToInternet) }
            model.mode = .live
            return true
        }
        model.exactStoredSessionOpenOverride = { route in
            authoritativeOpens.append(route)
        }
        defer {
            model.exactStoredSessionSourceReadinessOverride = nil
            model.exactStoredSessionOpenOverride = nil
            registry.remove(id: saved.id)
        }

        PushDefaultActionRouter.route(
            PushNotificationPayload(
                wireKind: PushKind.response.rawValue,
                kind: .response,
                gatewayID: saved.id,
                bot: exact.profile,
                title: "inbox",
                body: "Response ready",
                approvalRequestID: nil,
                sessionID: exact.storedSessionID,
                deeplink: nil),
            in: model,
            knownGatewayIDs: [saved.id])
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()
        XCTAssertEqual(dialAttempts, 0, "launch restore owns the first connection pass")

        // The launch pass exhausted this saved source while offline. Its
        // completion immediately attempts the retained route's exact source.
        model.completeLaunchWorldRestore()
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()
        XCTAssertEqual(dialAttempts, 1)
        XCTAssertTrue(authoritativeOpens.isEmpty)
        XCTAssertEqual(model.exactStoredSessionRouteQueue.pending?.route, exact)

        networkAvailable = true
        model.retryExactStoredSessionNavigation()
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()

        XCTAssertEqual(dialAttempts, 2)
        XCTAssertEqual(authoritativeOpens, [exact])
        XCTAssertEqual(model.exactStoredSessionRouteQueue.completedOpenCount, 1)
        XCTAssertNil(model.exactStoredSessionRouteQueue.pending)
    }

    func testAdoptedExactLiveSourceOpensOnceWhenInitialRosterRefreshTimesOut() async throws {
        let model = AppModel()
        let registry = ConnectionRegistry.shared
        let runtime = LiveRuntime.shared
        let baseURL = try XCTUnwrap(URL(
            string: "https://adopted-push-\(UUID().uuidString).example"))
        let fallbackURL = try XCTUnwrap(URL(
            string: "https://fallback-push-\(UUID().uuidString).example"))
        let credential = GatewayCredential.sessionToken("adopted-push-token")
        let saved = try XCTUnwrap(registry.upsert(
            urlString: baseURL.absoluteString,
            name: "Adopted push",
            credential: credential))
        let fallback = try XCTUnwrap(registry.upsert(
            urlString: fallbackURL.absoluteString,
            name: "Must not fallback",
            credential: .sessionToken("fallback-push-token")))
        let exact = try route(gateway: saved.id)
        let client = GatewayClient(baseURL: baseURL, credential: credential)
        let previousBaseURL = runtime.baseURL
        let previousGatewayID = runtime.gatewayID
        var authoritativeOpens: [ExactStoredSessionRoute] = []
        var refreshObservedExactAdoption = false
        model.exactStoredSessionOpenOverride = { route in
            authoritativeOpens.append(route)
        }
        defer {
            model.exactStoredSessionOpenOverride = nil
            model.client = nil
            runtime.baseURL = previousBaseURL
            runtime.gatewayID = previousGatewayID
            runtime.monitorTask?.cancel()
            runtime.monitorTask = nil
            registry.remove(id: saved.id)
            registry.remove(id: fallback.id)
        }

        // Retain the cold route without allowing its first attempt to cross the
        // launch/source boundary. No source-readiness override is installed.
        model.openExactStoredSession(exact, origin: .notification)
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()
        XCTAssertNil(model.exactStoredSessionSourceReadinessOverride)
        XCTAssertEqual(model.exactStoredSessionRouteQueue.pending?.route, exact)
        XCTAssertTrue(authoritativeOpens.isEmpty)

        model.launchWorldRestoreCompleted = true
        model.client = client
        model.mode = .live
        runtime.baseURL = baseURL
        await client.setForegroundReadinessForTesting(true)

        do {
            try await model.finishConnectedGatewayAdoption(
                client, baseURL: baseURL, credential: credential,
                rosterRefresh: {
                    let adopted = await registry.clientPool.client(for: saved.id)
                    refreshObservedExactAdoption = model.activeGatewayID == saved.id
                        && adopted.map(ObjectIdentifier.init) == ObjectIdentifier(client)
                    throw GatewayError(code: -5, message: "RPC timed out")
                })
            XCTFail("the injected ancillary roster timeout must propagate")
        } catch let error as GatewayError {
            XCTAssertEqual(error.code, -5)
        }

        // The adoption-boundary nudge survives the thrown ancillary refresh.
        // It proves production readiness from the saved live source and opens
        // through the exact route seam once; no alternate saved source is used.
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()
        XCTAssertTrue(refreshObservedExactAdoption)
        XCTAssertEqual(model.activeGatewayID, saved.id)
        XCTAssertEqual(authoritativeOpens, [exact])
        XCTAssertEqual(model.exactStoredSessionRouteQueue.completedOpenCount, 1)
        XCTAssertNil(model.exactStoredSessionRouteQueue.pending)
        let fallbackClient = await registry.clientPool.client(for: fallback.id)
        XCTAssertNil(fallbackClient)

        model.retryExactStoredSessionNavigation()
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()
        XCTAssertEqual(authoritativeOpens, [exact], "later nudges must not double-open")

        await registry.clientPool.disconnect(gatewayID: saved.id)
    }

    func testSupervisedReconnectSuccessReplaysDeferredRouteExactlyOnce() async throws {
        let model = AppModel()
        let registry = ConnectionRegistry.shared
        let baseURL = try XCTUnwrap(URL(
            string: "https://supervised-push-\(UUID().uuidString).example"))
        let saved = try XCTUnwrap(registry.upsert(
            urlString: baseURL.absoluteString,
            name: "Supervised push",
            credential: .sessionToken("supervised-push-token")))
        let exact = try route(gateway: saved.id)
        var reconnected = false
        var opens: [ExactStoredSessionRoute] = []
        model.mode = .live
        model.launchWorldRestoreCompleted = true
        model.exactStoredSessionSourceReadinessOverride = { _ in reconnected }
        model.exactStoredSessionOpenOverride = { opens.append($0) }
        defer {
            model.exactStoredSessionSourceReadinessOverride = nil
            model.exactStoredSessionOpenOverride = nil
            registry.remove(id: saved.id)
        }

        PushDefaultActionRouter.route(
            PushNotificationPayload(
                wireKind: PushKind.response.rawValue,
                kind: .response,
                gatewayID: saved.id,
                bot: exact.profile,
                title: "inbox",
                body: "Response ready",
                approvalRequestID: nil,
                sessionID: exact.storedSessionID,
                deeplink: nil),
            in: model,
            knownGatewayIDs: [saved.id])
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()
        XCTAssertEqual(model.exactStoredSessionRouteQueue.pending?.route, exact)
        XCTAssertTrue(opens.isEmpty)

        reconnected = true
        model.exactStoredSessionSourceDidReconnect()
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()

        XCTAssertEqual(opens, [exact])
        XCTAssertEqual(model.exactStoredSessionRouteQueue.completedOpenCount, 1)
        XCTAssertNil(model.exactStoredSessionRouteQueue.pending)
    }

    func testPeriodicSecondaryReconnectReplaysOnlyMatchingForeignRoute() async throws {
        let model = AppModel()
        let registry = ConnectionRegistry.shared
        let baseURL = try XCTUnwrap(URL(
            string: "https://foreign-push-\(UUID().uuidString).example"))
        let saved = try XCTUnwrap(registry.upsert(
            urlString: baseURL.absoluteString,
            name: "Foreign push",
            credential: .sessionToken("foreign-push-token")))
        let exact = try route(gateway: saved.id)
        var secondaryReady = false
        var attempts = 0
        var opens: [ExactStoredSessionRoute] = []
        model.mode = .live
        model.launchWorldRestoreCompleted = true
        model.exactStoredSessionSourceReadinessOverride = { _ in
            attempts += 1
            return secondaryReady
        }
        model.exactStoredSessionOpenOverride = { opens.append($0) }
        defer {
            model.exactStoredSessionSourceReadinessOverride = nil
            model.exactStoredSessionOpenOverride = nil
            registry.remove(id: saved.id)
        }

        PushDefaultActionRouter.route(
            PushNotificationPayload(
                wireKind: PushKind.response.rawValue,
                kind: .response,
                gatewayID: saved.id,
                bot: exact.profile,
                title: "inbox",
                body: "Response ready",
                approvalRequestID: nil,
                sessionID: exact.storedSessionID,
                deeplink: nil),
            in: model,
            knownGatewayIDs: [saved.id])
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()
        XCTAssertEqual(attempts, 1)

        model.exactStoredSessionSecondarySourcesDidRefresh(["unrelated-source"])
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()
        XCTAssertEqual(attempts, 1, "unrelated enumeration must not retry the route")

        secondaryReady = true
        model.exactStoredSessionSecondarySourcesDidRefresh([saved.id])
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(opens, [exact])
        XCTAssertEqual(model.exactStoredSessionRouteQueue.completedOpenCount, 1)
        XCTAssertNil(model.exactStoredSessionRouteQueue.pending)
    }

    func testRPCTimeoutDefersAndNextNudgeReplaysOnce() async throws {
        XCTAssertTrue(ExactStoredSessionRouteRetryPolicy.isTransient(
            GatewayError(code: -5, message: "RPC timed out")))
        XCTAssertFalse(ExactStoredSessionRouteRetryPolicy.isTransient(
            GatewayError(code: 401, message: "Unauthorized")))

        let queue = ExactStoredSessionRouteQueue()
        let exact = try route()
        var attempts = 0
        var opens = 0
        _ = queue.submit(
            ExactStoredSessionRouteRequest(
                route: exact, origin: .notification, waitsForLaunchRestore: false),
            alreadyVisible: false,
            execute: { _ in
                attempts += 1
                if attempts == 1 {
                    let timeout = GatewayError(code: -5, message: "RPC timed out")
                    return ExactStoredSessionRouteRetryPolicy.isTransient(timeout)
                        ? .deferred : .rejected(timeout.localizedDescription)
                }
                opens += 1
                return .opened
            },
            reject: { _, message in XCTFail("timeout must remain retryable: \(message)") })
        await queue.awaitCurrentAttempt()
        XCTAssertEqual(queue.pending?.route, exact)

        queue.nudge()
        await queue.awaitCurrentAttempt()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(queue.completedOpenCount, 1)
        XCTAssertNil(queue.pending)
    }

    func testDuplicateURLAndNotificationDelegateCoalesceAcrossColdRestore() async throws {
        let url = try XCTUnwrap(URL(
            string: "talaria://bot/inbox?session_id=stored-42&gateway_id=primary"))
        guard case .storedSession(let exact) = try XCTUnwrap(TalariaDeepLink(url: url)) else {
            return XCTFail("expected exact stored-session route")
        }
        let queue = ExactStoredSessionRouteQueue()
        var ready = false
        var opens = 0
        let execute: ExactStoredSessionRouteQueue.Execute = { _ in
            guard ready else { return .deferred }
            opens += 1
            return .opened
        }
        let reject: ExactStoredSessionRouteQueue.Reject = { _, _ in
            XCTFail("duplicate route must not reject")
        }

        XCTAssertEqual(queue.submit(
            ExactStoredSessionRouteRequest(
                route: exact, origin: .deepLink, waitsForLaunchRestore: true),
            alreadyVisible: false, execute: execute, reject: reject), .started)
        await queue.awaitCurrentAttempt()
        XCTAssertEqual(queue.submit(
            ExactStoredSessionRouteRequest(
                route: exact, origin: .notification, waitsForLaunchRestore: true),
            alreadyVisible: false, execute: execute, reject: reject), .duplicate)

        ready = true
        queue.nudge()
        await queue.awaitCurrentAttempt()
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(queue.completedOpenCount, 1)
    }

    func testActiveAndForeignRosterKeysPreserveSameExactAuthority() throws {
        let primary = try route(gateway: "primary", profile: "same", session: "collision")
        let foreign = try route(gateway: "homelab", profile: "same", session: "collision")

        XCTAssertEqual(primary.rosterID(activeGatewayID: "primary"), "same")
        XCTAssertEqual(foreign.rosterID(activeGatewayID: "primary"), "homelab::same")
        XCTAssertEqual(primary.botRoute,
                       GatewayBotRoute(gatewayID: "primary", profile: "same"))
        XCTAssertEqual(foreign.botRoute,
                       GatewayBotRoute(gatewayID: "homelab", profile: "same"))
        XCTAssertNotEqual(primary, foreign,
                          "colliding profile/session ids on two gateways are distinct routes")
    }

    func testLatestDistinctRouteSupersedesAndCancelsOlderOpen() async throws {
        let queue = ExactStoredSessionRouteQueue()
        let first = try route(session: "stored-old")
        let second = try route(gateway: "homelab", session: "stored-new")
        var firstStarted = false
        var opened: [ExactStoredSessionRoute] = []
        let execute: ExactStoredSessionRouteQueue.Execute = { request in
            if request.route == first {
                firstStarted = true
                do {
                    try await Task.sleep(for: .seconds(30))
                    opened.append(request.route)
                    return .opened
                } catch {
                    return .deferred
                }
            }
            opened.append(request.route)
            return .opened
        }
        let reject: ExactStoredSessionRouteQueue.Reject = { _, message in
            XCTFail("unexpected rejection: \(message)")
        }

        _ = queue.submit(
            ExactStoredSessionRouteRequest(
                route: first, origin: .notification, waitsForLaunchRestore: false),
            alreadyVisible: false, execute: execute, reject: reject)
        while !firstStarted { await Task.yield() }
        _ = queue.submit(
            ExactStoredSessionRouteRequest(
                route: second, origin: .deepLink, waitsForLaunchRestore: false),
            alreadyVisible: false, execute: execute, reject: reject)
        await queue.awaitCurrentAttempt()

        XCTAssertEqual(opened, [second])
        XCTAssertEqual(queue.completedOpenCount, 1)
        XCTAssertNil(queue.pending)
    }

    func testReconnectNudgeDuringCancellationIsNotLostOrDoubleOpened() async throws {
        let queue = ExactStoredSessionRouteQueue()
        let exact = try route()
        var attempts = 0
        var firstAttemptStarted = false
        var opens = 0

        _ = queue.submit(
            ExactStoredSessionRouteRequest(
                route: exact, origin: .notification, waitsForLaunchRestore: false),
            alreadyVisible: false,
            execute: { _ in
                attempts += 1
                if attempts == 1 {
                    firstAttemptStarted = true
                    await Task.yield()
                    return .deferred
                }
                opens += 1
                return .opened
            },
            reject: { _, message in XCTFail("unexpected rejection: \(message)") })
        while !firstAttemptStarted { await Task.yield() }
        queue.nudge()
        await queue.awaitCurrentAttempt()

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(queue.completedOpenCount, 1)
        XCTAssertNil(queue.pending)
    }

    func testUnknownOrDeletedSourceRejectsWithoutOpening() async throws {
        let queue = ExactStoredSessionRouteQueue()
        let exact = try route(gateway: "deleted")
        var rejection: (ExactStoredSessionRoute, String)?

        _ = queue.submit(
            ExactStoredSessionRouteRequest(
                route: exact, origin: .deepLink, waitsForLaunchRestore: true),
            alreadyVisible: false,
            execute: { _ in
                .rejected("That response came from a gateway that is no longer saved.")
            },
            reject: { route, message in rejection = (route, message) })
        await queue.awaitCurrentAttempt()

        XCTAssertEqual(rejection?.0, exact)
        XCTAssertTrue(rejection?.1.contains("no longer saved") == true)
        XCTAssertNil(queue.pending)
        XCTAssertEqual(queue.completedOpenCount, 0)
    }

    func testUnknownAndMissingCredentialRejectBeforeAnyConnectionRetry() async throws {
        let unknownModel = AppModel()
        unknownModel.launchWorldRestoreCompleted = true
        var sourceAttempts = 0
        unknownModel.exactStoredSessionSourceReadinessOverride = { _ in
            sourceAttempts += 1
            return true
        }
        unknownModel.openExactStoredSession(
            try route(gateway: "definitely-not-saved"), origin: .deepLink)
        await unknownModel.exactStoredSessionRouteQueue.awaitCurrentAttempt()
        XCTAssertEqual(sourceAttempts, 0)
        XCTAssertNil(unknownModel.exactStoredSessionRouteQueue.pending)
        XCTAssertEqual(unknownModel.exactStoredSessionRouteQueue.completedOpenCount, 0)

        let registry = ConnectionRegistry.shared
        let baseURL = try XCTUnwrap(URL(
            string: "https://signed-out-push-\(UUID().uuidString).example"))
        let saved = try XCTUnwrap(registry.upsert(
            urlString: baseURL.absoluteString,
            name: "Signed out push",
            credential: nil))
        let signedOutModel = AppModel()
        signedOutModel.launchWorldRestoreCompleted = true
        signedOutModel.exactStoredSessionSourceReadinessOverride = { _ in
            sourceAttempts += 1
            return true
        }
        defer {
            unknownModel.exactStoredSessionSourceReadinessOverride = nil
            signedOutModel.exactStoredSessionSourceReadinessOverride = nil
            registry.remove(id: saved.id)
            ToastBus.shared.clear()
        }

        signedOutModel.openExactStoredSession(
            try route(gateway: saved.id), origin: .notification)
        await signedOutModel.exactStoredSessionRouteQueue.awaitCurrentAttempt()
        XCTAssertEqual(sourceAttempts, 0)
        XCTAssertNil(signedOutModel.exactStoredSessionRouteQueue.pending)
        XCTAssertEqual(signedOutModel.exactStoredSessionRouteQueue.completedOpenCount, 0)
        XCTAssertNil(signedOutModel.openBotID)
    }

    func testFreshProfileAuthorityRejectsStaleDeletedAndAmbiguousProfiles() throws {
        let exact = try route(profile: "researcher")
        XCTAssertNoThrow(try ExactStoredSessionRouteAuthority.requireCurrent(
            exact, profileNames: ["default", "researcher"]))
        XCTAssertThrowsError(try ExactStoredSessionRouteAuthority.requireCurrent(
            exact, profileNames: ["default"])) { error in
                XCTAssertEqual(error as? ExactStoredSessionRouteAuthorityError,
                               .missingProfile(exact))
            }
        XCTAssertThrowsError(try ExactStoredSessionRouteAuthority.requireCurrent(
            exact, profileNames: ["Researcher", "researcher"])) { error in
                XCTAssertEqual(error as? ExactStoredSessionRouteAuthorityError,
                               .invalidProfileInventory)
        }
    }

    func testSameStoredIDAckFromWrongProfileFailsClosedAcrossABA() throws {
        let exact = try route(profile: "researcher", session: "same-stored-key")
        XCTAssertNoThrow(try ExactStoredSessionResumeAckAuthority.requireExact(
            route: exact.botRoute,
            requestedStoredSessionID: exact.storedSessionID,
            returnedStoredSessionID: "same-stored-key",
            returnedProfile: "researcher"))

        XCTAssertThrowsError(try ExactStoredSessionResumeAckAuthority.requireExact(
            route: exact.botRoute,
            requestedStoredSessionID: exact.storedSessionID,
            returnedStoredSessionID: "same-stored-key",
            returnedProfile: "default")) { error in
                XCTAssertEqual(error as? ExactStoredSessionResumeAckAuthorityError,
                               .profileMismatch)
            }
        XCTAssertThrowsError(try ExactStoredSessionResumeAckAuthority.requireExact(
            route: exact.botRoute,
            requestedStoredSessionID: exact.storedSessionID,
            returnedStoredSessionID: "same-stored-key",
            returnedProfile: "")) { error in
                XCTAssertEqual(error as? ExactStoredSessionResumeAckAuthorityError,
                               .profileMismatch)
        }
    }

    func testResumeSnapshotEvidenceKeepsNonSnapshotEventsAndRequiresExactMessageProof() {
        let session = LiveSession(.object([
            "session_id": .string("runtime-evidence"),
            "stored_session_id": .string("stored-evidence"),
            "messages": .array([
                .object(["role": .string("assistant"),
                         "text": .string("already in resume")]),
            ]),
            "info": .object(["profile_name": .string("researcher")]),
        ]))
        let evidence = session.snapshotEvidence
        let complete = GatewayEvent(
            type: "message.complete", sessionID: session.sessionID,
            payload: .object(["text": .string("already in resume"),
                              "status": .string("complete")]),
            inboundSequence: 4)
        XCTAssertTrue(evidence.represents(complete))

        // These frames can precede the response but are not durable rows in
        // the resume projection. Sequence alone must never discard them.
        XCTAssertFalse(evidence.represents(GatewayEvent(
            type: "tool.start", sessionID: session.sessionID,
            payload: .object(["tool_id": .string("tool-1"),
                              "name": .string("search")]), inboundSequence: 5)))
        XCTAssertFalse(evidence.represents(GatewayEvent(
            type: "status.update", sessionID: session.sessionID,
            payload: .object(["kind": .string("working"),
                              "text": .string("Searching")]), inboundSequence: 6)))

        let duplicateText = LiveSession(.object([
            "session_id": .string("runtime-evidence"),
            "stored_session_id": .string("stored-evidence"),
            "messages": .array([
                .object(["role": .string("assistant"),
                         "text": .string("already in resume")]),
                .object(["role": .string("assistant"),
                         "text": .string("already in resume")]),
            ]),
            "info": .object(["profile_name": .string("researcher")]),
        ]))
        XCTAssertFalse(duplicateText.snapshotEvidence.represents(complete),
                       "duplicate text without a durable row id is not proof")
    }

    func testRoutedGateSameClientHandoffAndRollbackAreLossless() throws {
        let client = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://gate-\(UUID().uuidString).example")),
            credential: .sessionToken("gate-token"))
        let gate = RoutedEventGate(client: client, generation: 12)
        let target = GatewayEvent(
            type: "message.complete", sessionID: "new-runtime",
            payload: .object(["text": .string("target")]), inboundSequence: 11)
        let unrelated = GatewayEvent(
            type: "tool.start", sessionID: "other-runtime",
            payload: .object(["name": .string("search")]), inboundSequence: 12)
        let global = GatewayEvent(
            type: "status.update", sessionID: "",
            payload: .object(["text": .string("global")]), inboundSequence: 13)

        gate.beginStaging()
        XCTAssertFalse(gate.claimForPump(target))
        XCTAssertFalse(gate.claimForPump(unrelated))
        XCTAssertTrue(gate.claimForPump(global), "global stays with old pump")

        let returned = gate.finishStaging(targetSessionID: "new-runtime")
        XCTAssertEqual(returned.count, 1)
        XCTAssertEqual(returned.first?.type, unrelated.type)
        XCTAssertEqual(returned.first?.inboundSequence, unrelated.inboundSequence)
        gate.prepareOldReplay(returned)
        XCTAssertTrue(gate.claimForPump(unrelated), "old pump owns returned unrelated frame")
        XCTAssertTrue(gate.claimForStaged(target), "staged pump owns target frame")
        XCTAssertFalse(gate.claimForStaged(unrelated), "no duplicate cross-pump delivery")

        let replayed = gate.restoreForRollback()
        XCTAssertEqual(replayed.count, 1)
        XCTAssertEqual(replayed.first?.inboundSequence, target.inboundSequence)
        XCTAssertTrue(gate.claimForPump(target), "rollback restores old target authority")

        gate.retire()
        XCTAssertFalse(gate.claimForPump(GatewayEvent(
            type: "message.complete", sessionID: "old-runtime", payload: nil,
            inboundSequence: 14)), "retired generation rejects stale frames")
    }

    func testRetiredStagedGateRejectsOldUnsequencedButAcceptsTargetAndNewFrames() throws {
        let client = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://gate-unsequenced-\(UUID().uuidString).example")),
            credential: .sessionToken("gate-unsequenced-token"))
        let gate = RoutedEventGate(client: client, generation: 13)
        let old = GatewayEvent(
            type: "status.update", sessionID: "other-runtime",
            payload: .object(["text": .string("old")]), inboundSequence: 0)
        let target = GatewayEvent(
            type: "tool.start", sessionID: "new-runtime",
            payload: .object(["name": .string("search")]), inboundSequence: 0)

        gate.beginStaging()
        XCTAssertFalse(gate.claimForPump(old))
        XCTAssertFalse(gate.claimForPump(target))
        let returned = gate.finishStaging(targetSessionID: "new-runtime")
        XCTAssertEqual(returned.count, 1)
        gate.prepareOldReplay(returned)
        XCTAssertTrue(gate.claimForPump(old), "old unsequenced frame replays to old pump")
        XCTAssertTrue(gate.claimForStaged(target), "target frame remains staged-owned")

        gate.retireForStagedReplacement()
        XCTAssertFalse(gate.claimForStaged(old),
                       "old unsequenced frame must not replay through replacement")
        XCTAssertFalse(gate.claimForStaged(target),
                       "already-delivered target frame must remain exactly once")
        let fresh = GatewayEvent(
            type: "status.update", sessionID: "other-runtime",
            payload: .object(["text": .string("fresh")]), inboundSequence: 0)
        XCTAssertTrue(gate.claimForStaged(fresh),
                      "a new unsequenced frame after retirement is admitted")
        XCTAssertFalse(gate.claimForStaged(fresh),
                       "the new unsequenced frame is still delivered once")
    }

    func testPrepareIdentityMismatchRetiresStagingGateAfterPoolFlip() async throws {
        let model = AppModel()
        let gatewayID = "prepare-same-client-flip-\(UUID().uuidString)"
        let oldClient = GatewayClient(
            baseURL: try XCTUnwrap(URL(
                string: "https://prepare-same-old-\(UUID().uuidString).example")),
            credential: .sessionToken("prepare-same-old-token"))
        let replacementClient = GatewayClient(
            baseURL: try XCTUnwrap(URL(
                string: "https://prepare-same-new-\(UUID().uuidString).example")),
            credential: .sessionToken("prepare-same-new-token"))
        let pool = ConnectionRegistry.shared.clientPool
        await pool.adopt(oldClient, for: gatewayID)

        let (oldStream, oldContinuation) = AsyncStream.makeStream(of: GatewayEvent.self)
        let oldHandler = await oldClient.addEventHandler { oldContinuation.yield($0) }
        let oldGate = RoutedEventGate(client: oldClient, generation: 41)
        let oldProbe = RoutedEventProbe()
        let oldPump = Task { @MainActor in
            for await event in oldStream {
                guard oldGate.claimForPump(event) else { continue }
                await oldProbe.record(event)
            }
        }
        let runtime = MultiGatewayRuntime.shared
        runtime.routedEventGenerations[gatewayID] = 41
        runtime.routedEvents[gatewayID] = .init(
            client: oldClient, handlerID: oldHandler, pump: oldPump,
            continuation: oldContinuation, gate: oldGate, generation: 41)
        let oldApprovalEpoch = ApprovalBridges.shared.sweepEpochs[gatewayID]
        ApprovalBridges.shared.sweepEpochs[gatewayID] = 17
        let oldGatewayID = LiveRuntime.shared.gatewayID
        LiveRuntime.shared.gatewayID = "primary-prepare-same-client-flip"
        defer {
            oldGate.retire()
            oldPump.cancel()
            oldContinuation.finish()
            Task { await oldClient.removeEventHandler(oldHandler) }
            runtime.routedEvents[gatewayID] = nil
            runtime.routedEventGenerations[gatewayID] = nil
            ApprovalBridges.shared.sweepEpochs[gatewayID] = oldApprovalEpoch
            LiveRuntime.shared.gatewayID = oldGatewayID
            Task { await pool.disconnect(gatewayID: gatewayID) }
        }

        // This is the in-flight same-client handoff state when the pool slot
        // is replaced by a newer client before the staged handler is checked.
        oldGate.beginStaging()
        await oldClient.emitEventForTesting(GatewayEvent(
            type: "message.complete", sessionID: "queued-old-runtime",
            payload: .object(["text": .string("queued before pool flip")]),
            inboundSequence: 1))
        await pool.adopt(replacementClient, for: gatewayID)

        let prepared = await model.prepareExactRoutedEvents(
            client: oldClient, gatewayID: gatewayID)
        XCTAssertNil(prepared)
        XCTAssertFalse(oldGate.isOpen,
                       "a stale same-client gate must not be restored after the pool flip")
        XCTAssertNil(runtime.routedEvents[gatewayID])
        XCTAssertEqual(runtime.routedEventGenerations[gatewayID], 42)
        XCTAssertEqual(ApprovalBridges.shared.sweepEpochs[gatewayID], 18,
                       "clearing the captured runtime must fence its old approval sweep")

        for _ in 0..<20 { await Task.yield() }
        let observed = await oldProbe.events
        XCTAssertTrue(observed.isEmpty,
                      "queued old frames must not replay after stale cleanup")
    }

    func testPrepareIdentityMismatchRetiresDifferentClientAndRejectsQueuedOldFrames()
        async throws {
        let model = AppModel()
        let gatewayID = "prepare-different-client-flip-\(UUID().uuidString)"
        let oldClient = GatewayClient(
            baseURL: try XCTUnwrap(URL(
                string: "https://prepare-different-old-\(UUID().uuidString).example")),
            credential: .sessionToken("prepare-different-old-token"))
        let attemptedClient = GatewayClient(
            baseURL: try XCTUnwrap(URL(
                string: "https://prepare-different-attempted-\(UUID().uuidString).example")),
            credential: .sessionToken("prepare-different-attempted-token"))
        let replacementClient = GatewayClient(
            baseURL: try XCTUnwrap(URL(
                string: "https://prepare-different-new-\(UUID().uuidString).example")),
            credential: .sessionToken("prepare-different-new-token"))
        let pool = ConnectionRegistry.shared.clientPool
        await pool.adopt(oldClient, for: gatewayID)

        let (oldStream, oldContinuation) = AsyncStream.makeStream(of: GatewayEvent.self)
        let oldHandler = await oldClient.addEventHandler { oldContinuation.yield($0) }
        let oldGate = RoutedEventGate(client: oldClient, generation: 51)
        let oldProbe = RoutedEventProbe()
        let oldPump = Task { @MainActor in
            for await event in oldStream {
                guard oldGate.claimForPump(event) else { continue }
                await oldProbe.record(event)
            }
        }
        let runtime = MultiGatewayRuntime.shared
        runtime.routedEventGenerations[gatewayID] = 51
        runtime.routedEvents[gatewayID] = .init(
            client: oldClient, handlerID: oldHandler, pump: oldPump,
            continuation: oldContinuation, gate: oldGate, generation: 51)
        let oldGatewayID = LiveRuntime.shared.gatewayID
        LiveRuntime.shared.gatewayID = "primary-prepare-different-client-flip"
        MultiGatewayRuntime.shared.prepareAfterHandlerInstallationForTesting = {
            _, _, _ in
            // The different-client path retires the old gate before this hook
            // runs. This frame is therefore queued at the stale boundary and
            // must never reach the old pump.
            await oldClient.emitEventForTesting(GatewayEvent(
                type: "message.complete", sessionID: "queued-different-old-runtime",
                payload: .object(["text": .string("queued after retire")]),
                inboundSequence: 2))
            await Task.yield()
        }
        defer {
            MultiGatewayRuntime.shared.prepareAfterHandlerInstallationForTesting = nil
            oldGate.retire()
            oldPump.cancel()
            oldContinuation.finish()
            Task { await oldClient.removeEventHandler(oldHandler) }
            runtime.routedEvents[gatewayID] = nil
            runtime.routedEventGenerations[gatewayID] = nil
            LiveRuntime.shared.gatewayID = oldGatewayID
            Task { await pool.disconnect(gatewayID: gatewayID) }
        }

        await pool.adopt(replacementClient, for: gatewayID)
        let prepared = await model.prepareExactRoutedEvents(
            client: attemptedClient, gatewayID: gatewayID)
        XCTAssertNil(prepared)
        XCTAssertFalse(oldGate.isOpen,
                       "a retired different-client gate must remain closed")
        XCTAssertNil(runtime.routedEvents[gatewayID])
        XCTAssertEqual(runtime.routedEventGenerations[gatewayID], 52)

        for _ in 0..<20 { await Task.yield() }
        let observed = await oldProbe.events
        XCTAssertTrue(observed.isEmpty,
                      "queued old frames must be rejected by the retired gate")
    }

    func testPrepareIdentityMismatchPreservesConcurrentNewerRuntimePublication()
        async throws {
        let model = AppModel()
        let gatewayID = "prepare-newer-runtime-wins-\(UUID().uuidString)"
        let oldClient = GatewayClient(
            baseURL: try XCTUnwrap(URL(
                string: "https://prepare-newer-old-\(UUID().uuidString).example")),
            credential: .sessionToken("prepare-newer-old-token"))
        let attemptedClient = GatewayClient(
            baseURL: try XCTUnwrap(URL(
                string: "https://prepare-newer-attempted-\(UUID().uuidString).example")),
            credential: .sessionToken("prepare-newer-attempted-token"))
        let newerClient = GatewayClient(
            baseURL: try XCTUnwrap(URL(
                string: "https://prepare-newer-current-\(UUID().uuidString).example")),
            credential: .sessionToken("prepare-newer-current-token"))
        let pool = ConnectionRegistry.shared.clientPool
        await pool.adopt(oldClient, for: gatewayID)

        let (oldStream, oldContinuation) = AsyncStream.makeStream(of: GatewayEvent.self)
        let oldHandler = await oldClient.addEventHandler { oldContinuation.yield($0) }
        let oldGate = RoutedEventGate(client: oldClient, generation: 61)
        let oldProbe = RoutedEventProbe()
        let oldPump = Task { @MainActor in
            for await event in oldStream {
                guard oldGate.claimForPump(event) else { continue }
                await oldProbe.record(event)
            }
        }

        let (_, newContinuation) = AsyncStream.makeStream(of: GatewayEvent.self)
        let newerProbe = RoutedEventProbe()
        let newerHandler = await newerClient.addEventHandler { event in
            Task { await newerProbe.record(event) }
            newContinuation.yield(event)
        }
        let newerGate = RoutedEventGate(client: newerClient, generation: 77)
        let newerPump = Task<Void, Never> {}
        let runtime = MultiGatewayRuntime.shared
        runtime.routedEventGenerations[gatewayID] = 61
        runtime.routedEvents[gatewayID] = .init(
            client: oldClient, handlerID: oldHandler, pump: oldPump,
            continuation: oldContinuation, gate: oldGate, generation: 61)
        let oldApprovalEpoch = ApprovalBridges.shared.sweepEpochs[gatewayID]
        ApprovalBridges.shared.sweepEpochs[gatewayID] = 61
        let oldGatewayID = LiveRuntime.shared.gatewayID
        LiveRuntime.shared.gatewayID = "primary-prepare-newer-runtime-wins"
        MultiGatewayRuntime.shared.prepareAfterHandlerInstallationForTesting = {
            gatewayID, _, _ in
            // Publish the newer owner before the stale prepare resumes its
            // pool check. The failed attempt must not erase this entry.
            runtime.routedEventGenerations[gatewayID] = 77
            runtime.routedEvents[gatewayID] = .init(
                client: newerClient, handlerID: newerHandler, pump: newerPump,
                continuation: newContinuation, gate: newerGate, generation: 77)
            ApprovalBridges.shared.sweepEpochs[gatewayID] = 91
            await pool.adopt(newerClient, for: gatewayID)
            await oldClient.emitEventForTesting(GatewayEvent(
                type: "message.complete", sessionID: "queued-old-after-newer",
                payload: .object(["text": .string("old must stay closed")]),
                inboundSequence: 3))
        }
        defer {
            MultiGatewayRuntime.shared.prepareAfterHandlerInstallationForTesting = nil
            oldGate.retire()
            newerGate.retire()
            oldPump.cancel()
            newerPump.cancel()
            oldContinuation.finish()
            newContinuation.finish()
            Task { await oldClient.removeEventHandler(oldHandler) }
            Task { await newerClient.removeEventHandler(newerHandler) }
            runtime.routedEvents[gatewayID] = nil
            runtime.routedEventGenerations[gatewayID] = nil
            ApprovalBridges.shared.sweepEpochs[gatewayID] = oldApprovalEpoch
            LiveRuntime.shared.gatewayID = oldGatewayID
            Task { await pool.disconnect(gatewayID: gatewayID) }
        }

        let prepared = await model.prepareExactRoutedEvents(
            client: attemptedClient, gatewayID: gatewayID)
        XCTAssertNil(prepared)
        XCTAssertFalse(oldGate.isOpen)
        XCTAssertEqual(runtime.routedEvents[gatewayID]?.handlerID, newerHandler,
                       "a newer runtime publication must survive stale cleanup")
        XCTAssertEqual(runtime.routedEvents[gatewayID].map {
            ObjectIdentifier($0.client) == ObjectIdentifier(newerClient)
        }, true)
        XCTAssertEqual(runtime.routedEventGenerations[gatewayID], 77)
        XCTAssertEqual(ApprovalBridges.shared.sweepEpochs[gatewayID], 91,
                       "stale cleanup must not reset the newer owner's approval scope")

        await newerClient.emitEventForTesting(GatewayEvent(
            type: "message.complete", sessionID: "newer-runtime",
            payload: .object(["text": .string("newer survives")]),
            inboundSequence: 4))
        for _ in 0..<100 {
            let count = await newerProbe.events.count
            if count > 0 { break }
            await Task.yield()
        }
        let oldEvents = await oldProbe.events
        let newerEvents = await newerProbe.events
        XCTAssertTrue(oldEvents.isEmpty,
                      "the captured old source must reject queued frames")
        XCTAssertEqual(newerEvents.map(\.inboundSequence), [4],
                       "the concurrent newer source remains live")
    }

    func testForeignExactOpenStagesAlongsideExistingSameClientPump() async throws {
        let model = AppModel()
        let gatewayID = "foreign-existing-pump-(UUID().uuidString)"
        let route = GatewayBotRoute(gatewayID: gatewayID, profile: "researcher")
        let target = route.qualifiedID
        let client = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://existing-pump-(UUID().uuidString).example")),
            credential: .sessionToken("existing-pump-token"))
        let pool = ConnectionRegistry.shared.clientPool
        await pool.adopt(client, for: gatewayID)
        let oldGatewayID = LiveRuntime.shared.gatewayID
        let oldMode = model.mode
        let oldHandler = await client.addEventHandler { _ in }
        let oldPump = Task<Void, Never> {}
        let runtime = MultiGatewayRuntime.shared
        let previousGeneration = runtime.routedEventGenerations[gatewayID, default: 0]
        runtime.routedEvents[gatewayID] = .init(
            client: client, handlerID: oldHandler, pump: oldPump,
            generation: previousGeneration)
        model.mode = .live
        model.bots = [Bot(id: target, job: "", shape: .circle, hue: .violet)]
        model.chats[target] = ChatState()
        LiveRuntime.shared.gatewayID = "primary-existing-pump"
        defer {
            oldPump.cancel()
            Task { await client.removeEventHandler(oldHandler) }
            runtime.routedEvents[gatewayID] = nil
            runtime.routedEventGenerations[gatewayID] = nil
            LiveRuntime.shared.gatewayID = oldGatewayID
            model.mode = oldMode
            Task { await pool.disconnect(gatewayID: gatewayID) }
        }

        let opened = try await model.openStoredSessionAwaiting(
            "wanted-stored", botID: target, route: route, client: client,
            validateBeforeBinding: {},
            catchUpResumeForTesting: {
                (LiveSession(.object([
                    "session_id": .string("existing-pump-runtime"),
                    "stored_session_id": .string("wanted-stored"),
                    "info": .object(["profile_name": .string("researcher")]),
                ])), 3)
            })

        XCTAssertTrue(opened)
        XCTAssertNotEqual(runtime.routedEvents[gatewayID]?.handlerID, oldHandler,
                          "exact foreign open installs an additional staged handler")
        XCTAssertEqual(runtime.routedEvents[gatewayID].map {
            ObjectIdentifier($0.client) == ObjectIdentifier(client)
        }, true)
        await model.removeRoutedEventSubscription(gatewayID: gatewayID)
        await pool.disconnect(gatewayID: gatewayID)
    }

    func testExistingSameClientPumpPartitionsDurableTransientAndGlobalFramesOnce() async throws {
        let model = AppModel()
        let gatewayID = "foreign-existing-events-\(UUID().uuidString)"
        let route = GatewayBotRoute(gatewayID: gatewayID, profile: "researcher")
        let target = route.qualifiedID
        let otherRoute = GatewayBotRoute(gatewayID: gatewayID, profile: "other")
        let other = otherRoute.qualifiedID
        let client = GatewayClient(
            baseURL: try XCTUnwrap(URL(
                string: "https://existing-events-\(UUID().uuidString).example")),
            credential: .sessionToken("existing-events-token"))
        let pool = ConnectionRegistry.shared.clientPool
        await pool.adopt(client, for: gatewayID)

        let (oldStream, oldContinuation) = AsyncStream.makeStream(of: GatewayEvent.self)
        let oldHandler = await client.addEventHandler { oldContinuation.yield($0) }
        let oldGate = RoutedEventGate(client: client, generation: 30)
        let oldProbe = RoutedEventProbe()
        let oldPump = Task { @MainActor in
            for await event in oldStream {
                guard oldGate.claimForPump(event) else { continue }
                await oldProbe.record(event)
                model.handle(event: event, sourceGatewayID: gatewayID)
            }
        }
        let runtime = MultiGatewayRuntime.shared
        let oldGeneration: UInt64 = 30
        runtime.routedEventGenerations[gatewayID] = oldGeneration
        runtime.routedEvents[gatewayID] = .init(
            client: client, handlerID: oldHandler, pump: oldPump,
            continuation: oldContinuation, gate: oldGate, generation: oldGeneration)

        let oldGatewayID = LiveRuntime.shared.gatewayID
        let oldMode = model.mode
        model.mode = .live
        model.bots = [
            Bot(id: target, job: "", shape: .circle, hue: .violet),
            Bot(id: other, job: "", shape: .circle, hue: .blue),
        ]
        let targetChat = ChatState(messages: [
            ChatMessage(author: .bot, text: "old target"),
        ])
        let otherChat = ChatState()
        model.chats[target] = targetChat
        model.chats[other] = otherChat
        LiveRuntime.shared.gatewayID = "primary-existing-events"
        defer {
            oldGate.retire()
            oldPump.cancel()
            oldContinuation.finish()
            Task { await client.removeEventHandler(oldHandler) }
            runtime.routedEvents[gatewayID] = nil
            runtime.routedEventGenerations[gatewayID] = nil
            runtime.routedUnread[otherRoute] = nil
            LiveRuntime.shared.routedSessionToBot.removeValue(forKey:
                GatewaySessionRoute(gatewayID: gatewayID, sessionID: "other-runtime"))
            LiveRuntime.shared.routedSessionToBot.removeValue(forKey:
                GatewaySessionRoute(gatewayID: gatewayID, sessionID: "new-runtime"))
            LiveRuntime.shared.gatewayID = oldGatewayID
            model.mode = oldMode
            Task { await pool.disconnect(gatewayID: gatewayID) }
        }

        LiveRuntime.shared.routedSessionToBot[GatewaySessionRoute(
            gatewayID: gatewayID, sessionID: "other-runtime")] = other

        let opened = try await model.openStoredSessionAwaiting(
            "wanted-stored", botID: target, route: route, client: client,
            validateBeforeBinding: {},
            catchUpResumeForTesting: {
                // The old and staged handlers both observe these frames. The
                // gate must keep the old pump's unrelated/global ownership,
                // while allowing the staged pump to retain transient target
                // state that the resume projection cannot represent.
                await client.emitEventForTesting(GatewayEvent(
                    type: "message.complete", sessionID: "new-runtime",
                    payload: .object([
                        "text": .string("already in resume"),
                        "status": .string("complete"),
                    ]), inboundSequence: 1))
                await client.emitEventForTesting(GatewayEvent(
                    type: "tool.start", sessionID: "new-runtime",
                    payload: .object(["tool_id": .string("tool-1"),
                                     "name": .string("search")]), inboundSequence: 2))
                await client.emitEventForTesting(GatewayEvent(
                    type: "message.complete", sessionID: "other-runtime",
                    payload: .object([
                        "text": .string("other once"),
                        "status": .string("complete"),
                    ]), inboundSequence: 3))
                await client.emitEventForTesting(GatewayEvent(
                    type: "status.update", sessionID: "",
                    payload: .object(["text": .string("global once")]),
                    inboundSequence: 4))
                for _ in 0..<4 { await Task.yield() }
                return (LiveSession(.object([
                    "session_id": .string("new-runtime"),
                    "stored_session_id": .string("wanted-stored"),
                    "messages": .array([
                        .object(["role": .string("assistant"),
                                 "text": .string("already in resume")]),
                    ]),
                    "info": .object(["profile_name": .string("researcher")]),
                ])), 10)
            })

        XCTAssertTrue(opened)
        XCTAssertEqual(targetChat.messages.map(\.text), ["already in resume"],
                       "the pre-response durable row is represented once")
        for _ in 0..<100 where targetChat.messages.flatMap(\.toolCalls).isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(targetChat.messages.flatMap(\.toolCalls).map(\.name), ["search"],
                       "transient tool state is retained even below the resume boundary")
        XCTAssertEqual(otherChat.messages.map(\.text), ["other once"],
                       "unrelated same-client frames stay with the old pump")
        for _ in 0..<100 where runtime.routedUnread[otherRoute] != 1 {
            await Task.yield()
        }
        XCTAssertEqual(runtime.routedUnread[otherRoute], 1,
                       "an old-owned unrelated completion must not replay through the replacement")
        let oldSequences = await oldProbe.events.map(\.inboundSequence)
        XCTAssertEqual(oldSequences.filter { $0 == 3 }.count, 1)
        XCTAssertEqual(oldSequences.filter { $0 == 4 }.count, 1)
        XCTAssertFalse(oldSequences.contains(1), "snapshot-owned target row is staged")
        XCTAssertFalse(oldSequences.contains(2), "target transient is staged")

        // The old handler has now been retired and removed. Frames that first
        // arrive after that boundary must still flow through the replacement,
        // exactly once, for both an unrelated session and the newly adopted
        // target session.
        await client.emitEventForTesting(GatewayEvent(
            type: "message.complete", sessionID: "other-runtime",
            payload: .object([
                "text": .string("other after retirement"),
                "status": .string("complete"),
            ]), inboundSequence: 20))
        await client.emitEventForTesting(GatewayEvent(
            type: "message.complete", sessionID: "new-runtime",
            payload: .object([
                "text": .string("target after retirement"),
                "status": .string("complete"),
            ]), inboundSequence: 21))
        for _ in 0..<100 where otherChat.messages.count < 2
            || targetChat.messages.filter({ $0.text == "target after retirement" }).isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(otherChat.messages.map(\.text),
                       ["other once", "other after retirement"],
                       "a post-retire unrelated frame is delivered once")
        XCTAssertEqual(runtime.routedUnread[otherRoute], 2,
                       "the post-retire unrelated completion increments unread once")
        XCTAssertEqual(targetChat.messages.filter { $0.text == "target after retirement" }.count,
                       1,
                       "a post-retire target frame is delivered once")

        await model.removeRoutedEventSubscription(gatewayID: gatewayID)
        await pool.disconnect(gatewayID: gatewayID)
    }

    func testDifferentClientRollbackRetiresBothGenerationsAndRejectsQueuedOldClientEvents()
        async throws {
        let model = AppModel()
        let gatewayID = "foreign-rollback-gate-\(UUID().uuidString)"
        let oldClient = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://old-gate-\(UUID().uuidString).example")),
            credential: .sessionToken("old-gate-token"))
        let newClient = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://new-gate-\(UUID().uuidString).example")),
            credential: .sessionToken("new-gate-token"))
        let pool = ConnectionRegistry.shared.clientPool
        await pool.adopt(newClient, for: gatewayID)
        let (oldStream, oldContinuation) = AsyncStream.makeStream(of: GatewayEvent.self)
        let oldHandler = await oldClient.addEventHandler { oldContinuation.yield($0) }
        let oldGate = RoutedEventGate(client: oldClient, generation: 27)
        let probe = RoutedEventProbe()
        let oldPump = Task { @MainActor in
            for await event in oldStream {
                guard oldGate.claimForPump(event) else { continue }
                await probe.record(event)
            }
        }
        let runtime = MultiGatewayRuntime.shared
        let oldGeneration: UInt64 = 27
        runtime.routedEventGenerations[gatewayID] = oldGeneration
        runtime.routedEvents[gatewayID] = .init(
            client: oldClient, handlerID: oldHandler, pump: oldPump,
            continuation: oldContinuation, gate: oldGate, generation: oldGeneration)
        let oldApprovalEpoch = ApprovalBridges.shared.sweepEpochs[gatewayID]
        ApprovalBridges.shared.sweepEpochs[gatewayID] = 19
        let oldGatewayID = LiveRuntime.shared.gatewayID
        LiveRuntime.shared.gatewayID = "primary-rollback-gate"
        defer {
            oldPump.cancel()
            oldContinuation.finish()
            Task { await oldClient.removeEventHandler(oldHandler) }
            runtime.routedEvents[gatewayID] = nil
            runtime.routedEventGenerations[gatewayID] = nil
            ApprovalBridges.shared.sweepEpochs[gatewayID] = oldApprovalEpoch
            LiveRuntime.shared.gatewayID = oldGatewayID
            Task { await pool.disconnect(gatewayID: gatewayID) }
        }

        let preparedValue = await model.prepareExactRoutedEvents(
            client: newClient, gatewayID: gatewayID)
        let prepared = try XCTUnwrap(preparedValue)
        let transaction = try model.commitExactRoutedEvents(
            prepared, snapshotSequence: 10, snapshotSessionID: "new-runtime")

        await oldClient.emitEventForTesting(GatewayEvent(
            type: "message.complete", sessionID: "old-runtime",
            payload: .object(["text": .string("stale")]), inboundSequence: 9))
        await Task.yield()
        let observedOldEvents = await probe.events
        XCTAssertTrue(observedOldEvents.isEmpty,
                      "retired old client/generation cannot deliver queued frames")

        transaction.rollback()
        await transaction.cleanupSupersededPrevious()
        await transaction.prepared.discardAfterRollback()
        XCTAssertNil(runtime.routedEvents[gatewayID],
                     "a different-client rollback must not republish the retired source")
        XCTAssertEqual(runtime.routedEventGenerations[gatewayID], oldGeneration + 2,
                       "rollback leaves a monotonic fence after the replacement generation")
        XCTAssertNotEqual(ApprovalBridges.shared.sweepEpochs[gatewayID], 19,
                          "stale approval sweep state must not be restored")
        XCTAssertFalse(oldGate.isOpen, "a different-client rollback keeps old gate retired")
        await oldClient.emitEventForTesting(GatewayEvent(
            type: "message.complete", sessionID: "old-runtime",
            payload: .object(["text": .string("restored")]), inboundSequence: 15))
        let restoredEvents = await probe.events
        XCTAssertEqual(restoredEvents.map(\.inboundSequence), [],
                       "retired old-client frames must never replay after rollback")
    }

    func testExactOpenAuthorityFailuresPreserveVisibleChatTranscriptAndUnread() async throws {
        let model = AppModel()
        let gatewayID = "foreign-exact-transaction-\(UUID().uuidString)"
        let profile = "researcher"
        let route = GatewayBotRoute(gatewayID: gatewayID, profile: profile)
        let target = route.qualifiedID
        let client = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://exact-transaction.example")),
            credential: .sessionToken("unused-test-token"))
        let sentinelClient = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://sentinel-events.example")),
            credential: .sessionToken("unused-sentinel-token"))
        let (sentinelStream, sentinelContinuation) =
            AsyncStream.makeStream(of: GatewayEvent.self)
        let sentinelHandler = await sentinelClient.addEventHandler {
            sentinelContinuation.yield($0)
        }
        let sentinelGate = RoutedEventGate(client: sentinelClient, generation: 41)
        let sentinelProbe = RoutedEventProbe()
        let sentinelPump = Task { @MainActor in
            for await event in sentinelStream {
                guard sentinelGate.claimForPump(event) else { continue }
                await sentinelProbe.record(event)
            }
        }
        let eventRuntime = MultiGatewayRuntime.shared
        eventRuntime.routedEventGenerations[gatewayID] = 41
        eventRuntime.routedEvents[gatewayID] = .init(
            client: sentinelClient, handlerID: sentinelHandler, pump: sentinelPump,
            continuation: sentinelContinuation, gate: sentinelGate, generation: 41)
        eventRuntime.routedUnread[route] = 7
        let approvalID = "approval-exact-transaction"
        LiveRuntime.shared.approvalTargets[approvalID] = ApprovalResponseTarget(
            bot: route,
            session: GatewaySessionRoute(gatewayID: gatewayID, sessionID: "approval-runtime"),
            requestID: "approval-wire")
        let pool = ConnectionRegistry.shared.clientPool
        await pool.adopt(client, for: gatewayID)
        let previous = ChatState(messages: [
            ChatMessage(author: .bot, text: "keep the visible transcript"),
        ])
        previous.sessionID = "visible-runtime"
        previous.storedSessionID = "visible-stored"
        let targetChat = ChatState(messages: [
            ChatMessage(author: .bot, text: "keep the target transcript too"),
        ])
        targetChat.sessionID = "target-old-runtime"
        targetChat.storedSessionID = "target-old-stored"
        model.mode = .live
        model.openBotID = "visible"
        model.chats["visible"] = previous
        model.chats[target] = targetChat
        model.bots = [Bot(
            id: target, job: "", shape: .circle, hue: .violet, unread: 7)]
        let oldGatewayID = LiveRuntime.shared.gatewayID
        LiveRuntime.shared.gatewayID = "primary-exact-transaction"
        defer {
            sentinelGate.retire()
            sentinelPump.cancel()
            sentinelContinuation.finish()
            Task { await sentinelClient.removeEventHandler(sentinelHandler) }
            eventRuntime.routedEvents[gatewayID] = nil
            eventRuntime.routedEventGenerations[gatewayID] = nil
            eventRuntime.routedUnread[route] = nil
            LiveRuntime.shared.approvalTargets[approvalID] = nil
            LiveRuntime.shared.gatewayID = oldGatewayID
            LiveRuntime.shared.routedSessionToBot.removeValue(forKey: GatewaySessionRoute(
                gatewayID: gatewayID, sessionID: "wrong-runtime"))
            LiveRuntime.shared.routedSessionToBot.removeValue(forKey: GatewaySessionRoute(
                gatewayID: gatewayID, sessionID: "right-runtime"))
        }

        do {
            _ = try await model.openStoredSessionAwaiting(
                "wanted-stored", botID: target, route: route, client: client,
                validateBeforeBinding: {
                    XCTFail("a wrong-profile ACK must fail before the second authority check")
                },
                resumeForTesting: {
                    LiveSession(.object([
                        "session_id": .string("wrong-runtime"),
                        "stored_session_id": .string("wanted-stored"),
                        "info": .object(["profile_name": .string("default")]),
                    ]))
                })
            XCTFail("wrong-profile resume must be rejected")
        } catch {
            XCTAssertTrue(error is AckValidationError)
        }

        XCTAssertEqual(model.openBotID, "visible")
        XCTAssertTrue(model.chats["visible"] === previous)
        XCTAssertEqual(previous.messages.map(\.text), ["keep the visible transcript"])
        XCTAssertTrue(model.chats[target] === targetChat)
        XCTAssertEqual(targetChat.messages.map(\.text), ["keep the target transcript too"])
        XCTAssertEqual(targetChat.sessionID, "target-old-runtime")
        XCTAssertEqual(targetChat.storedSessionID, "target-old-stored")
        XCTAssertEqual(eventRuntime.routedUnread[route], 7)
        XCTAssertFalse(sentinelGate.isOpen,
                       "a different-client pre-commit failure must keep the old gate closed")
        XCTAssertNil(eventRuntime.routedEvents[gatewayID],
                     "a different-client pre-commit failure must not restore old runtime")
        XCTAssertEqual(eventRuntime.routedEventGenerations[gatewayID], 42)
        XCTAssertNotNil(LiveRuntime.shared.approvalTargets[approvalID])
        await sentinelClient.emitEventForTesting(GatewayEvent(
            type: "message.complete", sessionID: "stale-runtime",
            payload: .object(["text": .string("stale")]), inboundSequence: 1))
        for _ in 0..<20 { await Task.yield() }
        let staleEvents = await sentinelProbe.events
        XCTAssertTrue(staleEvents.isEmpty,
                      "queued old frames must be rejected after stale cleanup")

        do {
            _ = try await model.openStoredSessionAwaiting(
                "wanted-stored", botID: target, route: route, client: client,
                validateBeforeBinding: {
                    throw ExactStoredSessionRouteAuthorityError.missingProfile(
                        try XCTUnwrap(ExactStoredSessionRoute(
                            gatewayID: gatewayID, profile: profile,
                            storedSessionID: "wanted-stored")))
                },
                resumeForTesting: {
                    LiveSession(.object([
                        "session_id": .string("right-runtime"),
                        "stored_session_id": .string("wanted-stored"),
                        "info": .object(["profile_name": .string(profile)]),
                    ]))
                })
            XCTFail("post-resume profile deletion must be rejected")
        } catch {
            XCTAssertTrue(error is ExactStoredSessionRouteAuthorityError)
        }

        XCTAssertEqual(model.openBotID, "visible")
        XCTAssertTrue(model.chats["visible"] === previous)
        XCTAssertEqual(previous.messages.map(\.text), ["keep the visible transcript"])
        XCTAssertTrue(model.chats[target] === targetChat)
        XCTAssertEqual(targetChat.messages.map(\.text), ["keep the target transcript too"])
        XCTAssertEqual(targetChat.sessionID, "target-old-runtime")
        XCTAssertEqual(targetChat.storedSessionID, "target-old-stored")
        XCTAssertEqual(eventRuntime.routedUnread[route], 7)
        XCTAssertNil(eventRuntime.routedEvents[gatewayID])
        XCTAssertEqual(eventRuntime.routedEventGenerations[gatewayID], 42)
        XCTAssertNotNil(LiveRuntime.shared.approvalTargets[approvalID])

        do {
            _ = try await model.openStoredSessionAwaiting(
                "wanted-stored", botID: target, route: route, client: client,
                validateBeforeBinding: {},
                resumeForTesting: {
                    LiveSession(.object([
                        "session_id": .string("right-runtime"),
                        "stored_session_id": .string("wanted-stored"),
                        "info": .object(["profile_name": .string(profile)]),
                    ]))
                },
                catchUpResumeForTesting: {
                    (LiveSession(.object([
                        "session_id": .string("wrong-runtime"),
                        "stored_session_id": .string("wanted-stored"),
                        "info": .object(["profile_name": .string("default")]),
                    ])), 20)
                })
            XCTFail("a catch-up mismatch must reject transactionally")
        } catch {
            XCTAssertTrue(error is AckValidationError)
        }
        XCTAssertEqual(model.openBotID, "visible")
        XCTAssertEqual(targetChat.messages.map(\.text), ["keep the target transcript too"])
        XCTAssertEqual(targetChat.sessionID, "target-old-runtime")
        XCTAssertEqual(targetChat.storedSessionID, "target-old-stored")
        XCTAssertEqual(eventRuntime.routedUnread[route], 7)
        XCTAssertNil(eventRuntime.routedEvents[gatewayID])
        XCTAssertEqual(eventRuntime.routedEventGenerations[gatewayID], 42)
        XCTAssertNotNil(LiveRuntime.shared.approvalTargets[approvalID])

        await pool.disconnect(gatewayID: gatewayID)
    }

    func testSameClientPreCommitDiscardRestoresParkedTargetEvents() async throws {
        let model = AppModel()
        let gatewayID = "same-client-precommit-discard-\(UUID().uuidString)"
        let route = GatewayBotRoute(gatewayID: gatewayID, profile: "researcher")
        let target = route.qualifiedID
        let client = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://same-client-discard-\(UUID().uuidString).example")),
            credential: .sessionToken("same-client-discard-token"))
        let pool = ConnectionRegistry.shared.clientPool
        await pool.adopt(client, for: gatewayID)

        let (oldStream, oldContinuation) = AsyncStream.makeStream(of: GatewayEvent.self)
        let oldHandler = await client.addEventHandler { oldContinuation.yield($0) }
        let oldGate = RoutedEventGate(client: client, generation: 55)
        let probe = RoutedEventProbe()
        let oldPump = Task { @MainActor in
            for await event in oldStream {
                guard oldGate.claimForPump(event) else { continue }
                await probe.record(event)
            }
        }
        let runtime = MultiGatewayRuntime.shared
        runtime.routedEventGenerations[gatewayID] = 55
        runtime.routedEvents[gatewayID] = .init(
            client: client, handlerID: oldHandler, pump: oldPump,
            continuation: oldContinuation, gate: oldGate, generation: 55)
        let oldApprovalEpoch = ApprovalBridges.shared.sweepEpochs[gatewayID]
        ApprovalBridges.shared.sweepEpochs[gatewayID] = 33
        let oldGatewayID = LiveRuntime.shared.gatewayID
        let oldMode = model.mode
        let oldBots = model.bots
        let oldChat = model.chats[target]
        LiveRuntime.shared.gatewayID = "primary-same-client-discard"
        model.mode = .live
        model.bots = [Bot(id: target, job: "", shape: .circle, hue: .violet)]
        model.chats[target] = ChatState()
        defer {
            oldGate.retire()
            oldPump.cancel()
            oldContinuation.finish()
            Task { await client.removeEventHandler(oldHandler) }
            runtime.routedEvents[gatewayID] = nil
            runtime.routedEventGenerations[gatewayID] = nil
            ApprovalBridges.shared.sweepEpochs[gatewayID] = oldApprovalEpoch
            LiveRuntime.shared.gatewayID = oldGatewayID
            model.mode = oldMode
            model.bots = oldBots
            if let oldChat { model.chats[target] = oldChat }
            else { model.chats[target] = nil }
            Task { await pool.disconnect(gatewayID: gatewayID) }
        }

        do {
            _ = try await model.openStoredSessionAwaiting(
                "same-client-stored", botID: target, route: route, client: client,
                validateBeforeBinding: {
                    XCTFail("authority validation must not run after a failed resume")
                },
                resumeForTesting: {
                    await client.emitEventForTesting(GatewayEvent(
                        type: "message.complete", sessionID: "same-client-runtime",
                        payload: .object(["text": .string("parked")]),
                        inboundSequence: 7))
                    throw GatewayError(code: -7, message: "resume failed")
                })
            XCTFail("failed resume must not publish exact navigation")
        } catch let error as GatewayError {
            XCTAssertEqual(error.code, -7)
        }

        XCTAssertTrue(oldGate.isOpen,
                      "same-client pre-commit failure restores the old gate")
        XCTAssertEqual(runtime.routedEvents[gatewayID]?.handlerID, oldHandler)
        XCTAssertEqual(runtime.routedEventGenerations[gatewayID], 55)
        XCTAssertEqual(ApprovalBridges.shared.sweepEpochs[gatewayID], 33)
        for _ in 0..<100 {
            if await probe.events.count > 0 { break }
            await Task.yield()
        }
        let replayedEvents = await probe.events
        XCTAssertEqual(replayedEvents.map(\.inboundSequence), [7],
                       "a parked same-client target frame replays exactly once")
    }

    func testDifferentClientPreCommitDiscardPreservesConcurrentNewerPublication()
        async throws {
        let model = AppModel()
        let gatewayID = "different-client-concurrent-discard-\(UUID().uuidString)"
        let route = GatewayBotRoute(gatewayID: gatewayID, profile: "researcher")
        let target = route.qualifiedID
        let oldClient = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://discard-old-\(UUID().uuidString).example")),
            credential: .sessionToken("discard-old-token"))
        let attemptedClient = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://discard-attempted-\(UUID().uuidString).example")),
            credential: .sessionToken("discard-attempted-token"))
        let newerClient = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://discard-newer-\(UUID().uuidString).example")),
            credential: .sessionToken("discard-newer-token"))
        let pool = ConnectionRegistry.shared.clientPool
        await pool.adopt(attemptedClient, for: gatewayID)

        let (oldStream, oldContinuation) = AsyncStream.makeStream(of: GatewayEvent.self)
        let oldHandler = await oldClient.addEventHandler { oldContinuation.yield($0) }
        let oldGate = RoutedEventGate(client: oldClient, generation: 61)
        let oldProbe = RoutedEventProbe()
        let oldPump = Task { @MainActor in
            for await event in oldStream {
                guard oldGate.claimForPump(event) else { continue }
                await oldProbe.record(event)
            }
        }
        let (_, newContinuation) = AsyncStream.makeStream(of: GatewayEvent.self)
        let newerHandler = await newerClient.addEventHandler { newContinuation.yield($0) }
        let newerGate = RoutedEventGate(client: newerClient, generation: 77)
        let newerPump = Task<Void, Never> {}
        let runtime = MultiGatewayRuntime.shared
        runtime.routedEventGenerations[gatewayID] = 61
        runtime.routedEvents[gatewayID] = .init(
            client: oldClient, handlerID: oldHandler, pump: oldPump,
            continuation: oldContinuation, gate: oldGate, generation: 61)
        let oldApprovalEpoch = ApprovalBridges.shared.sweepEpochs[gatewayID]
        ApprovalBridges.shared.sweepEpochs[gatewayID] = 91
        let oldGatewayID = LiveRuntime.shared.gatewayID
        let oldMode = model.mode
        let oldBots = model.bots
        let oldChat = model.chats[target]
        LiveRuntime.shared.gatewayID = "primary-concurrent-discard"
        model.mode = .live
        model.bots = [Bot(id: target, job: "", shape: .circle, hue: .violet)]
        model.chats[target] = ChatState()
        defer {
            oldGate.retire()
            oldPump.cancel()
            oldContinuation.finish()
            newerGate.retire()
            newerPump.cancel()
            newContinuation.finish()
            Task { await oldClient.removeEventHandler(oldHandler) }
            Task { await newerClient.removeEventHandler(newerHandler) }
            runtime.routedEvents[gatewayID] = nil
            runtime.routedEventGenerations[gatewayID] = nil
            ApprovalBridges.shared.sweepEpochs[gatewayID] = oldApprovalEpoch
            LiveRuntime.shared.gatewayID = oldGatewayID
            model.mode = oldMode
            model.bots = oldBots
            if let oldChat { model.chats[target] = oldChat }
            else { model.chats[target] = nil }
            Task { await pool.disconnect(gatewayID: gatewayID) }
        }

        do {
            _ = try await model.openStoredSessionAwaiting(
                "concurrent-discard-stored", botID: target, route: route,
                client: attemptedClient,
                validateBeforeBinding: {
                    XCTFail("authority validation must not run after a failed resume")
                },
                resumeForTesting: {
                    await pool.adopt(newerClient, for: gatewayID)
                    runtime.routedEventGenerations[gatewayID] = 77
                    runtime.routedEvents[gatewayID] = .init(
                        client: newerClient, handlerID: newerHandler, pump: newerPump,
                        continuation: newContinuation, gate: newerGate, generation: 77)
                    throw GatewayError(code: -7, message: "resume failed")
                })
            XCTFail("failed resume must not publish exact navigation")
        } catch let error as GatewayError {
            XCTAssertEqual(error.code, -7)
        }

        XCTAssertFalse(oldGate.isOpen)
        XCTAssertEqual(runtime.routedEvents[gatewayID]?.handlerID, newerHandler,
                       "a concurrent newer publication must survive stale discard")
        XCTAssertEqual(runtime.routedEvents[gatewayID].map {
            ObjectIdentifier($0.client) == ObjectIdentifier(newerClient)
        }, true)
        XCTAssertEqual(runtime.routedEventGenerations[gatewayID], 77)
        XCTAssertEqual(ApprovalBridges.shared.sweepEpochs[gatewayID], 91,
                       "stale cleanup must not reset newer approval scope")
        await oldClient.emitEventForTesting(GatewayEvent(
            type: "message.complete", sessionID: "old-runtime",
            payload: .object(["text": .string("stale")]), inboundSequence: 3))
        for _ in 0..<20 { await Task.yield() }
        let staleEvents = await oldProbe.events
        XCTAssertTrue(staleEvents.isEmpty)
    }

    func testExactOpenRejectsMissingDurableAckWithoutBackfill() async throws {
        let model = AppModel()
        let route = GatewayBotRoute(gatewayID: "missing-durable", profile: "researcher")
        let client = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://missing-durable.example")),
            credential: .sessionToken("unused-test-token"))
        var postAuthorityCalled = false

        do {
            _ = try await model.openStoredSessionAwaiting(
                "requested-stored", botID: route.qualifiedID,
                route: route, client: client,
                validateBeforeBinding: { postAuthorityCalled = true },
                resumeForTesting: {
                    LiveSession(.object([
                        "session_id": .string("runtime-without-durable-ack"),
                        "info": .object(["profile_name": .string("researcher")]),
                    ]))
                })
            XCTFail("an omitted durable ACK must never be backfilled from the request")
        } catch let error as AckValidationError {
            XCTAssertTrue(error.localizedDescription.contains("durable session identity"))
        }
        XCTAssertFalse(postAuthorityCalled)
        XCTAssertNil(model.openBotID)
        XCTAssertTrue(model.chats.isEmpty)
    }

    func testExactOpenPublishesOnlyAfterResumeAndFreshProfileAuthority() async throws {
        let model = AppModel()
        let gatewayID = "foreign-exact-positive-\(UUID().uuidString)"
        let profile = "researcher"
        let route = GatewayBotRoute(gatewayID: gatewayID, profile: profile)
        let target = route.qualifiedID
        let client = GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://exact-positive.example")),
            credential: .sessionToken("unused-test-token"))
        let previous = ChatState(messages: [
            ChatMessage(author: .bot, text: "old visible transcript"),
        ])
        let targetChat = ChatState(messages: [
            ChatMessage(author: .bot, text: "old target transcript"),
        ])
        let otherRoute = GatewayBotRoute(gatewayID: gatewayID, profile: "other")
        let otherTarget = otherRoute.qualifiedID
        let otherChat = ChatState(messages: [])
        targetChat.sessionID = "old-runtime"
        targetChat.storedSessionID = "old-stored"
        model.mode = .live
        model.openBotID = "visible"
        model.chats["visible"] = previous
        model.chats[target] = targetChat
        model.bots = [
            Bot(id: target, job: "", shape: .circle, hue: .violet, unread: 5),
            Bot(id: otherTarget, job: "", shape: .circle, hue: .blue),
        ]
        model.chats[otherTarget] = otherChat
        let oldGatewayID = LiveRuntime.shared.gatewayID
        LiveRuntime.shared.gatewayID = "primary-exact-positive"
        let pool = ConnectionRegistry.shared.clientPool
        await pool.adopt(client, for: gatewayID)
        LiveRuntime.shared.routedSessionToBot[GatewaySessionRoute(
            gatewayID: gatewayID, sessionID: "other-runtime")] = otherTarget
        let initialEventGeneration = MultiGatewayRuntime.shared
            .routedEventGenerations[gatewayID, default: 0]
        MultiGatewayRuntime.shared.routedUnread[route] = 5
        var observedBeforeResume = false
        var observedBeforeAuthority = false
        var validationCount = 0
        let opened: Bool
        do {
            opened = try await model.openStoredSessionAwaiting(
                "wanted-stored", botID: target, route: route, client: client,
                validateBeforeBinding: {
                    validationCount += 1
                    observedBeforeAuthority = model.openBotID == "visible"
                        && targetChat.messages.map(\.text) == ["old target transcript"]
                        && MultiGatewayRuntime.shared.routedUnread[route] == 5
                    if validationCount == 1 {
                        await client.emitEventForTesting(GatewayEvent(
                            type: "message.complete", sessionID: "new-runtime",
                            payload: .object([
                                "text": .string("post-snapshot response"),
                                "status": .string("complete"),
                            ]), inboundSequence: 11))
                    }
                },
                catchUpResumeForTesting: {
                    observedBeforeResume = model.openBotID == "visible"
                        && targetChat.messages.map(\.text) == ["old target transcript"]
                        && MultiGatewayRuntime.shared.routedUnread[route] == 5
                    await client.emitEventForTesting(GatewayEvent(
                        type: "message.complete", sessionID: "other-runtime",
                        payload: .object([
                            "text": .string("other before snapshot"),
                            "status": .string("complete"),
                        ]), inboundSequence: 4))
                    // This frame precedes the response boundary and is already
                    // represented by the returned snapshot, so replaying it
                    // would duplicate the completed message.
                    await client.emitEventForTesting(GatewayEvent(
                        type: "message.complete", sessionID: "new-runtime",
                        payload: .object([
                            "text": .string("snapshot response"),
                            "status": .string("complete"),
                        ]), inboundSequence: 9))
                    await client.emitEventForTesting(GatewayEvent(
                        type: "tool.start", sessionID: "new-runtime",
                        payload: .object([
                            "tool_id": .string("pre-response-tool"),
                            "name": .string("search"),
                            "context": .string("before resume"),
                        ]), inboundSequence: 7))
                    await client.emitEventForTesting(GatewayEvent(
                        type: "status.update", sessionID: "new-runtime",
                        payload: .object([
                            "kind": .string("working"),
                            "text": .string("still working"),
                        ]), inboundSequence: 8))
                    return (LiveSession(.object([
                        "session_id": .string("new-runtime"),
                        "stored_session_id": .string("wanted-stored"),
                        "messages": .array([
                            .object(["role": .string("assistant"),
                                     "text": .string("snapshot response")]),
                        ]),
                        "info": .object(["profile_name": .string(profile)]),
                    ])), 10)
                })
        } catch {
            await model.removeRoutedEventSubscription(gatewayID: gatewayID)
            await pool.disconnect(gatewayID: gatewayID)
            MultiGatewayRuntime.shared.routedUnread[route] = nil
            LiveRuntime.shared.routedSessionToBot.removeValue(forKey: GatewaySessionRoute(
                gatewayID: gatewayID, sessionID: "other-runtime"))
            LiveRuntime.shared.gatewayID = oldGatewayID
            throw error
        }

        XCTAssertTrue(opened)
        XCTAssertTrue(observedBeforeResume)
        XCTAssertTrue(observedBeforeAuthority)
        XCTAssertEqual(model.openBotID, target)
        XCTAssertTrue(model.chats[target] === targetChat)
        XCTAssertEqual(targetChat.sessionID, "new-runtime")
        XCTAssertEqual(targetChat.storedSessionID, "wanted-stored")
        for _ in 0..<100 where !targetChat.messages.contains(where: {
            $0.text == "post-snapshot response"
        }) { await Task.yield() }
        XCTAssertEqual(targetChat.messages.map(\.text),
                       ["snapshot response", "post-snapshot response"])
        XCTAssertEqual(targetChat.messages.flatMap(\.toolCalls).map(\.name), ["search"],
                       "pre-response tool state is not a durable message-row snapshot")
        XCTAssertEqual(otherChat.messages.map(\.text), ["other before snapshot"],
                       "a pre-resume event for another session must not be dropped")
        XCTAssertNil(MultiGatewayRuntime.shared.routedUnread[route])
        XCTAssertEqual(previous.messages.map(\.text), ["old visible transcript"])
        XCTAssertEqual(
            MultiGatewayRuntime.shared.routedEventGenerations[gatewayID],
            initialEventGeneration + 1,
            "one staged swap owns one new routed-event generation")
        XCTAssertTrue(MultiGatewayRuntime.shared.routedEvents[gatewayID].map {
            ObjectIdentifier($0.client) == ObjectIdentifier(client)
        } == true)
        XCTAssertEqual(
            LiveRuntime.shared.routedSessionToBot[GatewaySessionRoute(
                gatewayID: gatewayID, sessionID: "new-runtime")], target)

        await model.removeRoutedEventSubscription(gatewayID: gatewayID)
        await pool.disconnect(gatewayID: gatewayID)
        MultiGatewayRuntime.shared.routedUnread[route] = nil
        LiveRuntime.shared.routedSessionToBot.removeValue(forKey: GatewaySessionRoute(
            gatewayID: gatewayID, sessionID: "other-runtime"))
        LiveRuntime.shared.routedSessionToBot.removeValue(forKey: GatewaySessionRoute(
            gatewayID: gatewayID, sessionID: "new-runtime"))
        LiveRuntime.shared.gatewayID = oldGatewayID
    }

    func testLifecycleMutationDuringFinalPoolFenceCannotPublish() async throws {
        let model = AppModel()
        let registry = ConnectionRegistry.shared
        let gatewayID = "foreign-fence-race-\(UUID().uuidString)"
        let profile = "researcher"
        let route = GatewayBotRoute(gatewayID: gatewayID, profile: profile)
        let target = route.qualifiedID
        let baseURL = try XCTUnwrap(URL(
            string: "https://fence-race-\(UUID().uuidString).example"))
        let saved = try XCTUnwrap(registry.upsert(
            urlString: baseURL.absoluteString,
            name: "Fence race",
            credential: .sessionToken("fence-race-token")))
        let client = GatewayClient(
            baseURL: baseURL,
            credential: .sessionToken("fence-race-token"))
        let pool = registry.clientPool
        await pool.adopt(client, for: gatewayID)
        let snapshot = try await pool.connectWithGeneration(
            gatewayID: gatewayID, baseURL: baseURL,
            credential: .sessionToken("fence-race-token"))
        let oldGatewayID = LiveRuntime.shared.gatewayID
        let oldHook = SessionsRuntime.shared.sourceFenceAfterPoolCheckForTesting
        model.mode = .live
        model.chats[target] = ChatState(messages: [
            ChatMessage(author: .bot, text: "old transcript"),
        ])
        model.bots = [Bot(id: target, job: "", shape: .circle, hue: .violet)]
        LiveRuntime.shared.gatewayID = "primary-fence-race"
        SessionsRuntime.shared.sourceFenceAfterPoolCheckForTesting = {
            // This bumps the captured route generation while the pool actor
            // query is in flight. The post-await fence must reject the stale
            // resume before it can commit its prepared handler.
            try? await model.activateProfileLifecycleRoute(
                gatewayID: gatewayID, profile: profile)
        }
        defer {
            SessionsRuntime.shared.sourceFenceAfterPoolCheckForTesting = oldHook
            LiveRuntime.shared.gatewayID = oldGatewayID
            registry.remove(id: saved.id)
        }

        do {
            _ = try await model.openStoredSessionAwaiting(
                "wanted-stored", botID: target, route: route, client: client,
                validateBeforeBinding: {},
                catchUpResumeForTesting: {
                    (LiveSession(.object([
                        "session_id": .string("fence-runtime"),
                        "stored_session_id": .string("wanted-stored"),
                        "info": .object(["profile_name": .string(profile)]),
                    ])), 10)
                },
                sourceSnapshot: snapshot)
            XCTFail("a lifecycle mutation during the final pool fence must reject the open")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertNil(model.openBotID)
        XCTAssertNil(MultiGatewayRuntime.shared.routedEvents[gatewayID])
        XCTAssertNil(MultiGatewayRuntime.shared.routedEventGenerations[gatewayID])
        await pool.disconnect(gatewayID: gatewayID)
    }

    func testCredentialRemovalDuringFinalPoolFenceCannotPublish() async throws {
        let model = AppModel()
        let registry = ConnectionRegistry.shared
        let profile = "researcher"
        let baseURL = try XCTUnwrap(URL(
            string: "https://credential-fence-\(UUID().uuidString).example"))
        let saved = try XCTUnwrap(registry.upsert(
            urlString: baseURL.absoluteString,
            name: "Credential fence",
            credential: .sessionToken("credential-fence-token")))
        let gatewayID = saved.id
        let route = GatewayBotRoute(gatewayID: gatewayID, profile: profile)
        let target = route.qualifiedID
        let client = GatewayClient(
            baseURL: baseURL,
            credential: .sessionToken("credential-fence-token"))
        let pool = registry.clientPool
        await pool.adopt(client, for: gatewayID)
        let snapshot = try await pool.connectWithGeneration(
            gatewayID: gatewayID, baseURL: baseURL,
            credential: .sessionToken("credential-fence-token"))
        let oldGatewayID = LiveRuntime.shared.gatewayID
        let oldHook = SessionsRuntime.shared.sourceFenceAfterPoolCheckForTesting
        model.mode = .live
        model.bots = [Bot(id: target, job: "", shape: .circle, hue: .violet)]
        model.chats[target] = ChatState()
        LiveRuntime.shared.gatewayID = "primary-credential-fence"
        SessionsRuntime.shared.sourceFenceAfterPoolCheckForTesting = {
            ConnectionSupervisor.shared.keychain.delete(for: baseURL)
        }
        defer {
            SessionsRuntime.shared.sourceFenceAfterPoolCheckForTesting = oldHook
            LiveRuntime.shared.gatewayID = oldGatewayID
            registry.remove(id: saved.id)
            Task { await pool.disconnect(gatewayID: gatewayID) }
        }

        do {
            _ = try await model.openStoredSessionAwaiting(
                "wanted-stored", botID: target, route: route, client: client,
                validateBeforeBinding: {},
                catchUpResumeForTesting: {
                    (LiveSession(.object([
                        "session_id": .string("credential-fence-runtime"),
                        "stored_session_id": .string("wanted-stored"),
                        "info": .object(["profile_name": .string(profile)]),
                    ])), 10)
                },
                sourceSnapshot: snapshot)
            XCTFail("missing current credential must reject the exact open")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertNil(model.openBotID)
        XCTAssertNil(MultiGatewayRuntime.shared.routedEvents[gatewayID])
        await pool.disconnect(gatewayID: gatewayID)
    }

    private func runExactOpenTeardownRace(remove: Bool) async throws {
        let model = AppModel()
        let registry = ConnectionRegistry.shared
        let primaryURL = try XCTUnwrap(URL(
            string: "https://exact-teardown-primary-\(UUID().uuidString).example"))
        let secondaryURL = try XCTUnwrap(URL(
            string: "https://exact-teardown-secondary-\(UUID().uuidString).example"))
        let primary = try XCTUnwrap(registry.upsert(
            urlString: primaryURL.absoluteString,
            name: "Exact teardown primary",
            credential: .sessionToken("exact-teardown-primary-token")))
        let secondary = try XCTUnwrap(registry.upsert(
            urlString: secondaryURL.absoluteString,
            name: "Exact teardown secondary",
            credential: .sessionToken("exact-teardown-secondary-token")))
        let route = try XCTUnwrap(ExactStoredSessionRoute(
            gatewayID: secondary.id, profile: "researcher", storedSessionID: "wanted-stored"))
        let target = route.botRoute.qualifiedID
        let primaryClient = GatewayClient(
            baseURL: primaryURL,
            credential: .sessionToken("exact-teardown-primary-token"))
        let secondaryClient = GatewayClient(
            baseURL: secondaryURL,
            credential: .sessionToken("exact-teardown-secondary-token"))
        let pool = registry.clientPool
        await pool.adopt(secondaryClient, for: secondary.id)

        let oldGatewayID = LiveRuntime.shared.gatewayID
        let oldBaseURL = LiveRuntime.shared.baseURL
        let oldClient = model.client
        let oldMode = model.mode
        let oldLeaseHook = SessionsRuntime.shared.exactOpenAfterPoolLeaseForTesting
        var leaseHeld = false
        var releaseLease: (() -> Void)?
        SessionsRuntime.shared.exactOpenAfterPoolLeaseForTesting = { gatewayID in
            XCTAssertEqual(gatewayID, secondary.id)
            leaseHeld = true
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                releaseLease = { continuation.resume() }
            }
        }
        model.mode = .live
        model.client = primaryClient
        model.launchWorldRestoreCompleted = true
        model.bots = [Bot(id: target, job: "", shape: .circle, hue: .violet)]
        model.chats[target] = ChatState()
        LiveRuntime.shared.gatewayID = primary.id
        LiveRuntime.shared.baseURL = primaryURL

        defer {
            releaseLease?()
            SessionsRuntime.shared.exactOpenAfterPoolLeaseForTesting = oldLeaseHook
            model.client = oldClient
            model.mode = oldMode
            LiveRuntime.shared.gatewayID = oldGatewayID
            LiveRuntime.shared.baseURL = oldBaseURL
            model.exactStoredSessionSourceInvalidations.remove(secondary.id)
            model.exactStoredSessionSourceTeardownCounts.removeValue(forKey: secondary.id)
            registry.remove(id: primary.id)
            registry.remove(id: secondary.id)
        }

        model.openExactStoredSession(route, origin: .notification)
        for _ in 0..<100 where !leaseHeld { await Task.yield() }
        XCTAssertTrue(leaseHeld, "exact navigation must hold the source pool lease")

        let teardownTask = Task { @MainActor in
            if remove {
                await model.removeGateway(secondary)
            } else {
                await model.signOutGateway(secondary)
            }
        }
        for _ in 0..<100 where !model.exactStoredSessionSourceIsInvalidated(
            gatewayID: secondary.id) {
            await Task.yield()
        }
        XCTAssertTrue(model.exactStoredSessionSourceIsInvalidated(gatewayID: secondary.id))
        releaseLease?()
        releaseLease = nil

        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()
        await teardownTask.value
        await model.exactStoredSessionRouteQueue.awaitCurrentAttempt()

        XCTAssertNil(model.openBotID,
                     "a teardown-invalidated exact open must not publish navigation")
        XCTAssertNil(MultiGatewayRuntime.shared.routedEvents[secondary.id],
                     "post-disconnect exact detach must leave no routed pump")
        XCTAssertFalse(model.exactStoredSessionSourceIsInvalidated(gatewayID: secondary.id),
                       "durable row/credential removal makes the transient mark unnecessary")
        if remove {
            XCTAssertNil(registry.saved.first(where: { $0.id == secondary.id }))
        } else {
            let retained = try XCTUnwrap(registry.saved.first(where: { $0.id == secondary.id }))
            XCTAssertNil(registry.credential(for: retained))
            registry.setCredential(.sessionToken("exact-teardown-reauth-token"), for: retained)
            model.clearExactStoredSessionSourceInvalidationIfCredentialed(
                gatewayID: secondary.id)
            XCTAssertFalse(model.exactStoredSessionSourceIsInvalidated(gatewayID: secondary.id),
                           "a later credentialed reauth can recover the source")
        }
        await pool.disconnect(gatewayID: secondary.id)
    }

    func testSignOutInvalidatesInFlightExactOpenBeforePoolDisconnect() async throws {
        try await runExactOpenTeardownRace(remove: false)
    }

    func testRemoveInvalidatesInFlightExactOpenBeforePoolDisconnect() async throws {
        try await runExactOpenTeardownRace(remove: true)
    }

    func testDeepLinkParserRetainsUnknownSourceForVisibleAuthorityFailure() throws {
        let url = try XCTUnwrap(URL(
            string: "talaria://bot/inbox?session_id=stored-42&gateway_id=not-saved-yet"))
        XCTAssertEqual(TalariaDeepLink(url: url), .storedSession(try route(
            gateway: "not-saved-yet", profile: "inbox", session: "stored-42")))

        let qualified = try XCTUnwrap(URL(
            string: "talaria://bot/homelab::inbox?session_id=stored-43"))
        XCTAssertEqual(TalariaDeepLink(url: qualified), .storedSession(try route(
            gateway: "homelab", profile: "inbox", session: "stored-43")))
    }

    func testDeepLinkParserRejectsAmbiguousOrNonExactRoutes() throws {
        XCTAssertNil(TalariaDeepLink(url: try XCTUnwrap(URL(
            string: "talaria://bot/inbox?session_id=stored-42"))))
        XCTAssertNil(TalariaDeepLink(url: try XCTUnwrap(URL(
            string: "talaria://bot/homelab::inbox?session_id=stored-42&gateway_id=other"))))
        XCTAssertNil(TalariaDeepLink(url: try XCTUnwrap(URL(
            string: "talaria://bot/inbox/extra?session_id=stored-42&gateway_id=homelab"))))
        XCTAssertNil(TalariaDeepLink(url: try XCTUnwrap(URL(
            string: "talaria://bot/inbox?session_id=a&session_id=b&gateway_id=homelab"))))
    }
}
#endif
