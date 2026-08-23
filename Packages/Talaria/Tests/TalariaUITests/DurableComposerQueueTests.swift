#if canImport(XCTest)
import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

private actor DurableQueueRPCProbe {
    enum SubmitResult: Sendable { case accepted, ambiguous }
    enum ResumeState: Sendable, Equatable {
        case idle
        case running
        case inflight
        case approval
        case clarify
    }

    private var running = false
    private var resumeStates: [String: ResumeState] = [:]
    private var submitResult: SubmitResult = .accepted
    private var submittedTexts: [String] = []
    private var rpcMethods: [String] = []
    private var beforeSubmit: (@Sendable () async -> Void)?

    func setRunning(_ value: Bool) { running = value }
    func setResumeState(_ state: ResumeState, for storedID: String) {
        resumeStates[storedID] = state
    }
    func setSubmitResult(_ value: SubmitResult) { submitResult = value }
    func setBeforeSubmit(_ value: (@Sendable () async -> Void)?) {
        beforeSubmit = value
    }
    func submitted() -> [String] { submittedTexts }
    func methods() -> [String] { rpcMethods }

    func execute(_ method: String, params: JSONValue?) async throws -> JSONValue {
        rpcMethods.append(method)
        switch method {
        case "session.resume":
            let storedID = params?["session_id"]?.stringValue ?? ""
            let state = resumeStates[storedID] ?? (running ? .running : .idle)
            var payload: [String: JSONValue] = [
                "session_id": .string("runtime-\(storedID)"),
                "stored_session_id": .string(storedID),
                "running": .bool(state == .running),
                "inflight": state == .inflight
                    ? .object(["status": .string("running")]) : .null,
                "pending_approval": .null,
                "pending_clarify": .null,
            ]
            if state == .approval {
                payload["pending_approval"] = .object([
                    "request_id": .string("approval-\(storedID)"),
                    "command": .string("test command"),
                ])
            }
            if state == .clarify {
                payload["pending_clarify"] = .object([
                    "request_id": .string("clarify-\(storedID)"),
                    "question": .string("test question"),
                ])
            }
            return .object(payload)
        case "prompt.submit":
            await beforeSubmit?()
            let text = params?["text"]?.stringValue ?? ""
            submittedTexts.append(text)
            if submitResult == .ambiguous {
                throw URLError(.networkConnectionLost)
            }
            return .object(["status": .string("queued")])
        case "session.steer":
            return .object(["status": .string("queued")])
        default:
            throw GatewayError(code: -8, message: "unexpected RPC \(method)")
        }
    }
}

@MainActor
final class DurableComposerQueueTests: XCTestCase {
    private enum TestFailure: Error { case persistence }

    private func makeStore() -> (DurableComposerQueueStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-durable-queue-test-\(UUID().uuidString).json")
        return (DurableComposerQueueStore(fileURL: url), url)
    }

    private func key(_ suffix: String = "one") -> DurableComposerQueueKey {
        DurableComposerQueueKey(gatewayID: "gateway", profile: "worker",
                                storedSessionID: "stored-\(suffix)")
    }

    private func eventually(_ predicate: @escaping () async -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if await predicate() { return true }
            await Task.yield()
        }
        return await predicate()
    }

    func testReplaceLocalTextPreservesIdentityAndStateRules() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID()
        let created = Date(timeIntervalSince1970: 100)
        let updated = Date(timeIntervalSince1970: 200)
        let first = try store.enqueue(key: key(), text: " before ", id: id,
                                      now: created)
        let replaced = try store.replaceLocalText(id: id, text: " after ", now: updated)
        XCTAssertEqual(replaced.id, first.id)
        XCTAssertEqual(replaced.key, first.key)
        XCTAssertEqual(replaced.order, first.order)
        XCTAssertEqual(replaced.createdAt, created)
        XCTAssertEqual(replaced.updatedAt, updated)
        XCTAssertEqual(replaced.text, "after")
        XCTAssertEqual(replaced.state, .localReady)

        let parked = try store.enqueue(key: key("parked"), text: "wait",
                                       state: .parked)
        XCTAssertEqual(try store.replaceLocalText(id: parked.id, text: "still wait").state,
                       .parked)

        let exhausted = try store.enqueue(
            key: key("retry"), text: "old", state: .retryExhausted)
        let revised = try store.replaceLocalText(id: exhausted.id, text: "new")
        XCTAssertEqual(revised.state, .localReady)
        XCTAssertEqual(revised.automaticFailures, 0)
        XCTAssertNil(revised.lastError)
    }

    func testReplaceRejectsGatewayOwnedAndUncertainStates() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        for state in [DurableComposerQueueState.submitting, .acceptedGatewayOwned, .uncertain] {
            let entry = try store.enqueue(key: key(state.rawValue), text: "protected", state: state)
            XCTAssertThrowsError(try store.replaceLocalText(id: entry.id, text: "changed")) { error in
                XCTAssertEqual(error as? DurableComposerQueueStoreError,
                               .protectedEntry(state: state))
            }
            XCTAssertEqual(store.entry(id: entry.id)?.text, "protected")
        }
    }

    func testReplacePersistsAcrossReopenAndRollsBackWhenPersistenceFails() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let entry = try store.enqueue(key: key(), text: "before")
        let replaced = try store.replaceLocalText(id: entry.id, text: "after")
        let reopened = DurableComposerQueueStore(fileURL: url)
        XCTAssertEqual(reopened.entry(id: entry.id), replaced)

        reopened.persistOverrideForTesting = { throw TestFailure.persistence }
        XCTAssertThrowsError(try reopened.replaceLocalText(id: entry.id, text: "lost"))
        XCTAssertEqual(reopened.entry(id: entry.id)?.text, "after")
        XCTAssertEqual(reopened.entry(id: entry.id)?.state, .localReady)

        let reopenedAfterFailure = DurableComposerQueueStore(fileURL: url)
        XCTAssertEqual(reopenedAfterFailure.entry(id: entry.id), replaced)
    }

    func testRetryExhaustionSurvivesRelaunchUntilExplicitResumeOrEdit() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let entry = try store.enqueue(
            key: key(), text: "do not replay", state: .retryExhausted)

        let reloaded = DurableComposerQueueStore(fileURL: url)
        XCTAssertEqual(reloaded.entry(id: entry.id)?.state, .retryExhausted)
        XCTAssertNil(DurableComposerQueuePolicy.nextFIFOEntry(
            reloaded.entries(for: entry.key)))
    }

    func testAtomicLifecycleMigrationRollsBackRouteAndParkedState() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = GatewayBotRoute(gatewayID: "gateway", profile: "old")
        let destination = GatewayBotRoute(gatewayID: "gateway", profile: "new")
        let entry = try store.enqueue(
            key: DurableComposerQueueKey(route: source, storedSessionID: "stored"),
            text: "stay fenced", state: .parked)
        store.persistOverrideForTesting = { throw TestFailure.persistence }

        XCTAssertThrowsError(try store.migrateRouteAndResume(
            from: source, to: destination))
        XCTAssertEqual(store.entry(id: entry.id)?.key.route, source)
        XCTAssertEqual(store.entry(id: entry.id)?.state, .parked)
    }

    func testReplacementUsesTotalTextDeltaRatherThanAddingBothBodies() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let body = String(repeating: "a", count: DurableComposerQueuePolicy.maxTextLength)
        for index in 0..<9 {
            _ = try store.enqueue(key: key("\(index)"), text: body)
        }
        let nearLimit = try store.enqueue(
            key: key("near"), text: String(repeating: "b", count: body.count - 1))
        let revised = try store.replaceLocalText(id: nearLimit.id, text: body)
        XCTAssertEqual(revised.text.count, DurableComposerQueuePolicy.maxTextLength)
        XCTAssertEqual(store.allEntries().reduce(0) { $0 + $1.text.count },
                       DurableComposerQueuePolicy.maxTotalTextLength)
    }

    func testExactEditReservationBlocksFIFOHeadAndReleasesAfterSaveOrFailure() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let route = GatewayBotRoute(gatewayID: "gateway", profile: "worker")
        let first = try store.enqueue(
            key: DurableComposerQueueKey(route: route, storedSessionID: "stored"), text: "first")
        let second = try store.enqueue(
            key: DurableComposerQueueKey(route: route, storedSessionID: "stored"), text: "second")
        XCTAssertEqual(DurableComposerQueuePolicy.nextFIFOEntry(
            store.entries(for: first.key))?.id, first.id)
        XCTAssertNil(DurableComposerQueuePolicy.nextFIFOEntry(
            store.entries(for: first.key), reservedIDs: [first.id]))

        let model = AppModel(queueStore: store)
        let botID = route.qualifiedID
        model.mode = .live
        model.chat(for: botID).storedSessionID = "stored"
        XCTAssertNotNil(model.beginEditingDurableQueuedPrompt(id: first.id, botID: botID))
        XCTAssertFalse(model.claimDurableComposerEntry(id: first.id))
        XCTAssertNil(model.beginEditingDurableQueuedPrompt(id: second.id, botID: "other::worker"))

        XCTAssertTrue(model.saveEditingDurableQueuedPrompt(
            id: first.id, botID: botID, text: "saved revision"))
        XCTAssertEqual(store.entry(id: first.id)?.text, "saved revision")
        XCTAssertTrue(model.claimDurableComposerEntry(id: first.id))
        model.releaseDurableComposerEntryClaim(first.id)

        XCTAssertNotNil(model.beginEditingDurableQueuedPrompt(id: first.id, botID: botID))
        store.persistOverrideForTesting = { throw TestFailure.persistence }
        XCTAssertFalse(model.saveEditingDurableQueuedPrompt(
            id: first.id, botID: botID, text: "must roll back"))
        store.persistOverrideForTesting = nil
        XCTAssertEqual(store.entry(id: first.id)?.text, "saved revision")
        XCTAssertTrue(model.claimDurableComposerEntry(id: first.id))
        model.releaseDurableComposerEntryClaim(first.id)

        XCTAssertNotNil(model.beginEditingDurableQueuedPrompt(id: first.id, botID: botID))
        model.chat(for: botID).storedSessionID = "different"
        XCTAssertFalse(model.saveEditingDurableQueuedPrompt(
            id: first.id, botID: botID, text: "must not move"))
        XCTAssertEqual(store.entry(id: first.id)?.text, "saved revision")
        model.chat(for: botID).storedSessionID = "stored"
        XCTAssertTrue(model.claimDurableComposerEntry(id: first.id))
        model.releaseDurableComposerEntryClaim(first.id)

        XCTAssertNotNil(model.beginEditingDurableQueuedPrompt(id: first.id, botID: botID))
        model.cancelEditingDurableQueuedPrompt(id: first.id, botID: botID)
        XCTAssertTrue(model.claimDurableComposerEntry(id: first.id))
        model.releaseDurableComposerEntryClaim(first.id)
    }

    func testExplicitQueuePersistsWithoutOptimisticTranscriptBubble() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let route = GatewayBotRoute(gatewayID: "gateway", profile: "worker")
        let model = AppModel(queueStore: store)
        model.mode = .live
        let chat = model.chat(for: route.qualifiedID)
        chat.storedSessionID = "stored"
        XCTAssertTrue(model.queuePrompt(text: "follow up", to: route.qualifiedID))
        XCTAssertTrue(chat.messages.isEmpty)
        let entry = try XCTUnwrap(store.entries(for: DurableComposerQueueKey(
            route: route, storedSessionID: "stored")).first)
        XCTAssertEqual(entry.text, "follow up")
        XCTAssertEqual(entry.state, .localReady)
    }

    func testProjectionRefreshPreservesNonDurableRecoveryAndSteerRows() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(queueStore: store)
        let legacyComposeID = UUID()
        model.appendComposeQueue(botID: "legacy", text: "attachment recovery",
                                 id: legacyComposeID)
        let legacyPromptID = UUID()
        model.promptQueue.append((id: legacyPromptID, botID: "legacy",
                                  text: "ordinary steer mirror"))

        let durable = try store.enqueue(key: key(), text: "durable")
        model.reloadDurableComposerQueueProjection()

        XCTAssertTrue(model.composeQueueIDs.contains(legacyComposeID))
        XCTAssertTrue(model.composeQueueIDs.contains(durable.id))
        XCTAssertTrue(model.composeQueue.contains {
            $0.botID == "legacy" && $0.text == "attachment recovery"
        })
        XCTAssertTrue(model.promptQueue.contains { $0.id == legacyPromptID })

        try store.remove(id: durable.id)
        model.reloadDurableComposerQueueProjection()
        XCTAssertEqual(model.composeQueueIDs, [legacyComposeID])
        XCTAssertEqual(model.promptQueue.map(\.id), [legacyPromptID])
    }

    func testNormalRecoveryNeverCreatesReplayableDurableAuthority() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AppModel(queueStore: store)
        let id = UUID()
        let route = GatewayBotRoute(gatewayID: "gateway", profile: "worker")
        model.appendComposeQueue(
            botID: route.qualifiedID, text: "ordinary recovery", id: id,
            route: route, storedID: "stored", sessionID: "runtime")

        XCTAssertNil(store.entry(id: id))
        XCTAssertEqual(model.composeQueueIDs, [id])
    }

    func testDurableDrainWaitsForExactIdleAndFailsClosedAfterLostReceipt() async throws {
        let explicitNulls = LiveSession(.object([
            "session_id": .string("runtime"),
            "stored_session_id": .string("stored"),
            "pending_approval": .null,
            "pending_clarify": .null,
        ]))
        XCTAssertNil(explicitNulls.pendingApproval)
        XCTAssertNil(explicitNulls.pendingClarify)
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let registry = ConnectionRegistry.shared
        let baseURL = try XCTUnwrap(URL(string: "https://queue-\(UUID().uuidString).example"))
        let saved = try XCTUnwrap(registry.upsert(
            urlString: baseURL.absoluteString, name: "Queue test",
            credential: .sessionToken("queue-test-token")))
        defer { registry.remove(id: saved.id) }

        let oldGatewayID = LiveRuntime.shared.gatewayID
        let oldBaseURL = LiveRuntime.shared.baseURL
        let oldGeneration = LiveRuntime.shared.generation
        var acceptedBindingID: UUID?
        defer {
            if let acceptedBindingID {
                ChatRuntime.shared.queuedBindings[acceptedBindingID] = nil
            }
            LiveRuntime.shared.gatewayID = oldGatewayID
            LiveRuntime.shared.baseURL = oldBaseURL
            LiveRuntime.shared.generation = oldGeneration
        }

        let probe = DurableQueueRPCProbe()
        let client = GatewayClient(baseURL: baseURL,
                                   credential: .sessionToken("queue-test-token"))
        await client.setRPCExecutorForTesting { method, params, _ in
            try await probe.execute(method, params: params)
        }
        let model = AppModel(queueStore: store)
        model.mode = .live
        model.isOffline = false
        model.client = client
        LiveRuntime.shared.gatewayID = saved.id
        LiveRuntime.shared.baseURL = baseURL
        LiveRuntime.shared.generation = oldGeneration + 1
        let route = GatewayBotRoute(gatewayID: saved.id, profile: "worker")
        let chat = model.chat(for: "worker")
        chat.storedSessionID = "stored"
        let first = try store.enqueue(
            key: DurableComposerQueueKey(route: route, storedSessionID: "stored"),
            text: "wait until idle")
        acceptedBindingID = first.id
        model.reloadDurableComposerQueueProjection()

        await probe.setRunning(true)
        await model.flushComposeQueue()
        XCTAssertEqual(store.entry(id: first.id)?.state, .localReady)
        let noSubmittedTexts = await probe.submitted()
        XCTAssertTrue(noSubmittedTexts.isEmpty)

        await probe.setRunning(false)
        await model.flushComposeQueue()
        let acceptedTexts = await probe.submitted()
        XCTAssertEqual(acceptedTexts, ["wait until idle"])
        XCTAssertEqual(store.entry(id: first.id)?.state, .acceptedGatewayOwned)

        let uncertain = try store.enqueue(
            key: first.key, text: "never replay this receipt")
        await probe.setSubmitResult(.ambiguous)
        await model.flushComposeQueue()
        XCTAssertEqual(store.entry(id: uncertain.id)?.state, .uncertain)
        let uncertainTexts = await probe.submitted()
        XCTAssertEqual(uncertainTexts,
                       ["wait until idle", "never replay this receipt"])

        await probe.setSubmitResult(.accepted)
        await model.flushComposeQueue()
        XCTAssertEqual(store.entry(id: uncertain.id)?.state, .uncertain)
        let replayAttemptTexts = await probe.submitted()
        XCTAssertEqual(replayAttemptTexts,
                       ["wait until idle", "never replay this receipt"])
    }

    func testDurableDrainKeepsRunningInflightApprovalAndClarifyHeadsLocal() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let registry = ConnectionRegistry.shared
        let baseURL = try XCTUnwrap(URL(
            string: "https://queue-non-idle-\(UUID().uuidString).example"))
        let saved = try XCTUnwrap(registry.upsert(
            urlString: baseURL.absoluteString, name: "Queue non-idle test",
            credential: .sessionToken("queue-test-token")))
        defer { registry.remove(id: saved.id) }

        let oldGatewayID = LiveRuntime.shared.gatewayID
        let oldBaseURL = LiveRuntime.shared.baseURL
        let oldGeneration = LiveRuntime.shared.generation
        var entryIDs = Set<UUID>()
        defer {
            for id in entryIDs { ChatRuntime.shared.queuedBindings[id] = nil }
            LiveRuntime.shared.gatewayID = oldGatewayID
            LiveRuntime.shared.baseURL = oldBaseURL
            LiveRuntime.shared.generation = oldGeneration
        }

        let probe = DurableQueueRPCProbe()
        let client = GatewayClient(baseURL: baseURL,
                                   credential: .sessionToken("queue-test-token"))
        await client.setRPCExecutorForTesting { method, params, _ in
            try await probe.execute(method, params: params)
        }
        let model = AppModel(queueStore: store)
        model.mode = .live
        model.isOffline = false
        model.client = client
        LiveRuntime.shared.gatewayID = saved.id
        LiveRuntime.shared.baseURL = baseURL
        LiveRuntime.shared.generation = oldGeneration + 1

        let route = GatewayBotRoute(gatewayID: saved.id, profile: "worker")
        let states: [(String, DurableQueueRPCProbe.ResumeState)] = [
            ("running", .running),
            ("inflight", .inflight),
            ("approval", .approval),
            ("clarify", .clarify),
        ]
        var entries: [DurableComposerQueueEntry] = []
        for (storedID, state) in states {
            await probe.setResumeState(state, for: storedID)
            let entry = try store.enqueue(
                key: DurableComposerQueueKey(route: route, storedSessionID: storedID),
                text: "remain local for \(storedID)")
            entries.append(entry)
            entryIDs.insert(entry.id)
        }
        model.reloadDurableComposerQueueProjection()

        await model.flushComposeQueue()

        for entry in entries {
            XCTAssertEqual(store.entry(id: entry.id)?.state, .localReady)
        }
        let methods = await probe.methods()
        XCTAssertEqual(methods.filter { $0 == "session.resume" }.count, states.count)
        XCTAssertFalse(methods.contains("prompt.submit"))
        let submitted = await probe.submitted()
        XCTAssertTrue(submitted.isEmpty)
    }

    func testEditReservationBlocksActualFIFODrainUntilReleased() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let registry = ConnectionRegistry.shared
        let baseURL = try XCTUnwrap(URL(
            string: "https://queue-reservation-\(UUID().uuidString).example"))
        let saved = try XCTUnwrap(registry.upsert(
            urlString: baseURL.absoluteString, name: "Queue reservation test",
            credential: .sessionToken("queue-test-token")))
        defer { registry.remove(id: saved.id) }

        let oldGatewayID = LiveRuntime.shared.gatewayID
        let oldBaseURL = LiveRuntime.shared.baseURL
        let oldGeneration = LiveRuntime.shared.generation
        var entryIDs = Set<UUID>()
        defer {
            for id in entryIDs { ChatRuntime.shared.queuedBindings[id] = nil }
            LiveRuntime.shared.gatewayID = oldGatewayID
            LiveRuntime.shared.baseURL = oldBaseURL
            LiveRuntime.shared.generation = oldGeneration
        }

        let probe = DurableQueueRPCProbe()
        let client = GatewayClient(baseURL: baseURL,
                                   credential: .sessionToken("queue-test-token"))
        await client.setRPCExecutorForTesting { method, params, _ in
            try await probe.execute(method, params: params)
        }
        let model = AppModel(queueStore: store)
        model.mode = .live
        model.isOffline = false
        model.client = client
        LiveRuntime.shared.gatewayID = saved.id
        LiveRuntime.shared.baseURL = baseURL
        LiveRuntime.shared.generation = oldGeneration + 1
        let route = GatewayBotRoute(gatewayID: saved.id, profile: "worker")
        let chat = model.chat(for: "worker")
        chat.storedSessionID = "stored"
        let first = try store.enqueue(
            key: DurableComposerQueueKey(route: route, storedSessionID: "stored"),
            text: "first")
        let second = try store.enqueue(
            key: first.key, text: "second")
        entryIDs.formUnion([first.id, second.id])
        model.reloadDurableComposerQueueProjection()

        XCTAssertNotNil(model.beginEditingDurableQueuedPrompt(id: first.id, botID: "worker"))
        await model.flushComposeQueue()
        let blockedSubmissionTexts = await probe.submitted()
        XCTAssertTrue(blockedSubmissionTexts.isEmpty)
        XCTAssertEqual(store.entry(id: first.id)?.state, .localReady)
        XCTAssertEqual(store.entry(id: second.id)?.state, .localReady)

        model.cancelEditingDurableQueuedPrompt(id: first.id, botID: "worker")
        await model.flushComposeQueue()
        let releasedSubmissionTexts = await probe.submitted()
        XCTAssertEqual(releasedSubmissionTexts, ["first", "second"])
        XCTAssertEqual(store.entry(id: first.id)?.state, .acceptedGatewayOwned)
        XCTAssertEqual(store.entry(id: second.id)?.state, .acceptedGatewayOwned)
    }

    func testOrdinaryMidTurnSendUsesSessionSteerInsteadOfPromptSubmit() async throws {
        let registry = ConnectionRegistry.shared
        let baseURL = try XCTUnwrap(URL(
            string: "https://queue-steer-\(UUID().uuidString).example"))
        let saved = try XCTUnwrap(registry.upsert(
            urlString: baseURL.absoluteString, name: "Queue steer test",
            credential: .sessionToken("queue-test-token")))
        defer { registry.remove(id: saved.id) }

        let oldGatewayID = LiveRuntime.shared.gatewayID
        let oldBaseURL = LiveRuntime.shared.baseURL
        let oldGeneration = LiveRuntime.shared.generation
        let botID = "worker"
        defer {
            ChatRuntime.shared.steerActions[botID] = nil
            ChatRuntime.shared.steerFences[botID] = nil
            LiveRuntime.shared.gatewayID = oldGatewayID
            LiveRuntime.shared.baseURL = oldBaseURL
            LiveRuntime.shared.generation = oldGeneration
        }

        let probe = DurableQueueRPCProbe()
        let client = GatewayClient(baseURL: baseURL,
                                   credential: .sessionToken("queue-test-token"))
        await client.setRPCExecutorForTesting { method, params, _ in
            try await probe.execute(method, params: params)
        }
        let model = AppModel()
        model.mode = .live
        model.isOffline = false
        model.client = client
        LiveRuntime.shared.gatewayID = saved.id
        LiveRuntime.shared.baseURL = baseURL
        LiveRuntime.shared.generation = oldGeneration + 1
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime-stored"
        chat.storedSessionID = "stored"
        chat.isRunning = true

        model.sendOrSteer(text: "steer this turn", to: botID)

        let receivedSteer = await eventually {
            let methods = await probe.methods()
            return methods.contains("session.steer")
        }
        XCTAssertTrue(receivedSteer)
        let methods = await probe.methods()
        XCTAssertEqual(methods, ["session.steer"])
        XCTAssertFalse(methods.contains("prompt.submit"))
    }

    func testMessageStartBeforeReceiptRetiresExactSubmittingRow() async throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let registry = ConnectionRegistry.shared
        let baseURL = try XCTUnwrap(URL(
            string: "https://queue-early-\(UUID().uuidString).example"))
        let saved = try XCTUnwrap(registry.upsert(
            urlString: baseURL.absoluteString, name: "Queue early start",
            credential: .sessionToken("queue-test-token")))
        defer { registry.remove(id: saved.id) }

        let oldGatewayID = LiveRuntime.shared.gatewayID
        let oldBaseURL = LiveRuntime.shared.baseURL
        let oldGeneration = LiveRuntime.shared.generation
        defer {
            LiveRuntime.shared.gatewayID = oldGatewayID
            LiveRuntime.shared.baseURL = oldBaseURL
            LiveRuntime.shared.generation = oldGeneration
        }

        let probe = DurableQueueRPCProbe()
        let client = GatewayClient(baseURL: baseURL,
                                   credential: .sessionToken("queue-test-token"))
        let model = AppModel(queueStore: store)
        model.mode = .live
        model.isOffline = false
        model.client = client
        LiveRuntime.shared.gatewayID = saved.id
        LiveRuntime.shared.baseURL = baseURL
        LiveRuntime.shared.generation = oldGeneration + 1
        let route = GatewayBotRoute(gatewayID: saved.id, profile: "worker")
        let entry = try store.enqueue(
            key: DurableComposerQueueKey(route: route, storedSessionID: "stored"),
            text: "start first")
        model.reloadDurableComposerQueueProjection()
        await probe.setBeforeSubmit {
            await MainActor.run {
                model.routeToolEvent(
                    GatewayEvent(type: "message.start",
                                 sessionID: "runtime-stored", payload: [:]),
                    sourceGatewayID: saved.id)
            }
        }
        await client.setRPCExecutorForTesting { method, params, _ in
            try await probe.execute(method, params: params)
        }

        await model.flushComposeQueue()

        XCTAssertNil(store.entry(id: entry.id))
        XCTAssertTrue(model.durableComposerQueueWireSubmissions.isEmpty)
        XCTAssertTrue(model.durableComposerQueueStartsBeforeReceipt.isEmpty)
        let submitted = await probe.submitted()
        XCTAssertEqual(submitted, ["start first"])
    }

    func testStopParksExactLocalQueueBeforeAnyInterruptTask() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let route = GatewayBotRoute(gatewayID: "gateway", profile: "worker")
        let entry = try store.enqueue(
            key: DurableComposerQueueKey(route: route, storedSessionID: "stored"),
            text: "pause me")
        let model = AppModel(queueStore: store)
        model.mode = .live
        let chat = model.chat(for: route.qualifiedID)
        chat.storedSessionID = "stored"
        chat.isRunning = true

        model.stopTurn(botID: route.qualifiedID)

        XCTAssertEqual(store.entry(id: entry.id)?.state, .parked)
        ChatRuntime.shared.stopFences[route.qualifiedID] = nil
    }

    func testQueuePresentationPolicyMakesQueueTextOnlyDuringLiveTurn() {
        XCTAssertEqual(DurableComposerQueuePresentationPolicy.queueAction(
            isLive: true, isTurnRunning: true, hasAttachments: false, hasText: true), .available)
        XCTAssertEqual(DurableComposerQueuePresentationPolicy.queueAction(
            isLive: true, isTurnRunning: true, hasAttachments: true, hasText: true),
                       .attachmentExplanation)
        XCTAssertEqual(DurableComposerQueuePresentationPolicy.queueAction(
            isLive: true, isTurnRunning: false, hasAttachments: false, hasText: true), .hidden)
        XCTAssertTrue(DurableComposerQueueState.localReady.isLocallyEditable)
        XCTAssertTrue(DurableComposerQueueState.parked.isLocallyEditable)
        XCTAssertTrue(DurableComposerQueueState.retryExhausted.isLocallyEditable)
        XCTAssertFalse(DurableComposerQueueState.submitting.isLocallyEditable)
        XCTAssertFalse(DurableComposerQueueState.acceptedGatewayOwned.isLocallyEditable)
        XCTAssertFalse(DurableComposerQueueState.uncertain.isLocallyEditable)
    }
}
#endif
