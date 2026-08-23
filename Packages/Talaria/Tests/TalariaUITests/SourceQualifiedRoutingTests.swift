#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI
import TalariaTheme

private actor CommandAcceptanceGate {
    private var isOpen = false
    private var hasArrival = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        hasArrival = true
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func arrived() -> Bool { hasArrival }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor CommandTaskProbe {
    private var value = false
    func mark() { value = true }
    func marked() -> Bool { value }
}

@MainActor
final class SourceQualifiedRoutingTests: XCTestCase {
    func testSlashExecutionDecodesHermesTypedResults() throws {
        XCTAssertEqual(try SlashExecutionResult(result: ["type": .string("send"), "message": .string("retry")]),
                       .send(message: "retry", notice: nil, display: nil))
        XCTAssertEqual(try SlashExecutionResult(result: ["type": .string("skill"), "message": .string("goal"), "name": .string("plan")]),
                       .skill(message: "goal", name: "plan", display: nil))
        XCTAssertEqual(try SlashExecutionResult(result: ["type": .string("prefill"), "message": .string("undo 2")]),
                       .prefill(message: "undo 2", notice: nil))
        XCTAssertEqual(try SlashExecutionResult(result: ["type": .string("alias"), "target": .string("/status")]), .alias(target: "/status"))
        XCTAssertEqual(try SlashExecutionResult(result: ["type": .string("exec"), "output": .string("ok")]), .exec("ok"))
        XCTAssertEqual(try SlashExecutionResult(result: ["output": .string("worker")]), .output("worker", warning: nil))
    }

    func testSlashExecutionRejectsUnknownOrPartialTypedResults() {
        XCTAssertThrowsError(try SlashExecutionResult(result: ["type": .string("send")]))
        XCTAssertThrowsError(try SlashExecutionResult(result: ["type": .string("mystery")]))
    }

    func testLivePromptSubmitAcceptsBusySteerAndRedirectWithoutReplay() throws {
        for status in ["streaming", "queued", "steered", "redirected"] {
            XCTAssertNoThrow(try AppModel.LivePromptSubmitReceipt.requireAccepted(
                .object(["status": .string(status)]), operation: "Prompt"))
        }
        XCTAssertThrowsError(try AppModel.LivePromptSubmitReceipt.requireAccepted(
            .object(["status": .string("rejected")]), operation: "Prompt"))
        XCTAssertThrowsError(try AppModel.LivePromptSubmitReceipt.requireAccepted(
            .object(["status": .string("unknown")]), operation: "Prompt"))
    }

    func testSlashPrefillPolicyRequiresExactConnectionChatAndSessionIdentity() {
        let route = GatewayBotRoute(gatewayID: "homelab", profile: "worker")
        let chat = ChatState()
        let otherChat = ChatState()
        let binding = SlashPrefillBinding(
            botID: route.qualifiedID, route: route, connectionGeneration: 7,
            chatID: ObjectIdentifier(chat), storedSessionID: "stored-a",
            runtimeSessionID: "runtime-a", message: "undo 2")
        func applies(draft: String = "", selected: String? = nil,
                     currentRoute: GatewayBotRoute? = nil, generation: UInt64? = nil,
                     chatID: ObjectIdentifier? = nil, stored: String? = nil,
                     runtime: String? = nil) -> Bool {
            SlashPrefillPolicy.mayApply(
                binding, draft: draft, selectedBotID: selected ?? route.qualifiedID,
                currentRoute: currentRoute ?? route,
                currentConnectionGeneration: generation ?? 7,
                currentChatID: chatID ?? ObjectIdentifier(chat),
                currentStoredID: stored ?? "stored-a",
                currentRuntimeID: runtime ?? "runtime-a")
        }

        XCTAssertTrue(applies())
        XCTAssertFalse(applies(draft: "newer"))
        XCTAssertFalse(applies(selected: "another"))
        XCTAssertFalse(applies(generation: 8))
        XCTAssertFalse(applies(chatID: ObjectIdentifier(otherChat)))
        XCTAssertFalse(applies(stored: "stored-b"))
        XCTAssertFalse(applies(runtime: "runtime-b"))
    }

    func testCatalogHidesOnlyStandaloneSkillsAndExplainsUnsafeBoundary() {
        let result: [String: JSONValue] = [
            "pairs": .array([
                .array([.string("/status"), .string("Show status")]),
                .array([.string("/research"), .string("Standalone skill")]),
                .array([.string("/quick"), .string("User command")]),
            ]),
            "categories": .array([
                .object(["name": .string("Session"),
                         "pairs": .array([.array([.string("/status"),
                                                   .string("Show status")])])]),
            ]),
            "skills": .object(["/research": .object([:])]),
            "skill_count": .number(1),
            "warning": .string(""),
        ]

        let catalog = SlashCatalog(result: result)

        XCTAssertEqual(catalog.commands.map(\.name), ["/status", "/quick"])
        XCTAssertEqual(catalog.skillCount, 0)
        XCTAssertEqual(catalog.unsupportedStandaloneSkillNames, ["/research"])
        XCTAssertTrue(catalog.warning.contains("slash.exec refuses"))
        let completions = SlashCompletions(items: [
            SlashCommand(name: "/research", description: "", category: "", kind: .skill),
            // A bundle has kind=skill in complete.slash but is absent from the
            // catalog's standalone `skills` map, so it remains executable.
            SlashCommand(name: "/backend", description: "", category: "", kind: .skill),
            SlashCommand(name: "/status", description: "", category: ""),
        ], replaceFrom: 0).hidingStandaloneSkills(catalog.unsupportedStandaloneSkillNames)
        XCTAssertEqual(completions.items.map(\.name), ["/backend", "/status"])
    }

    func testResolvedExactOrAliasedStandaloneSkillRemainsHidden() {
        let unsupported: Set<String> = ["/research"]
        let exact = SlashCommand(name: "/research", description: "", category: "")
        // command.resolve returns the canonical target for an alias, so this is
        // also the shape produced by resolving (for example) `/deep-research`.
        let aliasedCanonical = SlashCommand(
            name: "research", description: "", category: "", kind: .command)
        let bundle = SlashCommand(name: "/backend", description: "", category: "")

        XCTAssertNil(SlashResolvedCommandPolicy.visible(
            exact, unsupportedStandaloneSkillNames: unsupported))
        XCTAssertNil(SlashResolvedCommandPolicy.visible(
            aliasedCanonical, unsupportedStandaloneSkillNames: unsupported))
        XCTAssertEqual(SlashResolvedCommandPolicy.visible(
            bundle, unsupportedStandaloneSkillNames: unsupported), bundle)
    }

    func testMCPResponseReceiptDistinguishesAcceptedExpiredAndUncertain() throws {
        XCTAssertEqual(try MCPSetupResponseReceipt(result: .object(["status": .string("ok")])),
                       .accepted)
        XCTAssertEqual(try MCPSetupResponseReceipt(result: .object(["status": .string("expired")])),
                       .expired)
        XCTAssertThrowsError(try MCPSetupResponseReceipt(
            result: .object(["status": .string("mystery")])))
    }

    func testGeneratedSlashLeaseBlocksG2UntilSecondAcceptanceSettles() async throws {
        let url = try XCTUnwrap(URL(string: "https://slash-lease.example"))
        let credential = GatewayCredential.sessionToken("test")
        let first = GatewayClient(baseURL: url, credential: credential)
        let second = GatewayClient(baseURL: url, credential: credential)
        let pool = GatewayClientPool { _, _ in first }
        await pool.adopt(first, for: "gateway")
        let snapshot = try await pool.connectWithGeneration(
            gatewayID: "gateway", baseURL: url, credential: credential)
        let acceptance = CommandAcceptanceGate()
        let replacementStarted = CommandTaskProbe()

        let generated = Task { @MainActor in
            await pool.withCommandConnectionLease(snapshot, for: "gateway") {
                await acceptance.wait()
                return ObjectIdentifier(snapshot.client)
            }
        }
        for _ in 0..<100 {
            if await acceptance.arrived() { break }
            await Task.yield()
        }
        let generatedReachedAcceptance = await acceptance.arrived()
        XCTAssertTrue(generatedReachedAcceptance)

        let replacement = Task {
            await replacementStarted.mark()
            await pool.adopt(second, for: "gateway")
        }
        for _ in 0..<100 {
            if await replacementStarted.marked() { break }
            await Task.yield()
        }
        let replacementIsWaiting = await replacementStarted.marked()
        XCTAssertTrue(replacementIsWaiting)
        await Task.yield()
        let currentDuringSecondAcceptance = await pool.isCurrent(snapshot, for: "gateway")
        XCTAssertTrue(currentDuringSecondAcceptance,
                      "G2 must wait while the generated prompt is settling on G1")

        await acceptance.open()
        let submittedClient = await generated.value
        XCTAssertEqual(submittedClient, ObjectIdentifier(first),
                       "the second prompt must use the captured G1 client")
        await replacement.value
        let oldWasReplaced = await pool.isCurrent(snapshot, for: "gateway")
        XCTAssertFalse(oldWasReplaced)
        await pool.disconnectAll()
    }

    func testGeneratedSlashTrafficLeaseBlocksProfileLifecycleBetweenBoundaries() async throws {
        let gatewayID = "slash-lifecycle-lease"
        let url = try XCTUnwrap(URL(string: "https://slash-lifecycle.example"))
        let credential = GatewayCredential.sessionToken("test")
        let client = GatewayClient(baseURL: url, credential: credential)
        await client.setTrafficAdmission {
            await MainActor.run {
                ProfileLifecycleTrafficAdmission.acquire(gatewayID)
            }
        }
        let pool = GatewayClientPool { _, _ in client }
        await pool.adopt(client, for: gatewayID)
        let snapshot = try await pool.connectWithGeneration(
            gatewayID: gatewayID, baseURL: url, credential: credential)
        let acceptance = CommandAcceptanceGate()

        let generated = Task { @MainActor in
            try await pool.withCommandConnectionAndTrafficLease(
                snapshot, for: gatewayID
            ) {
                await acceptance.wait()
                return true
            }
        }
        for _ in 0..<100 {
            if await acceptance.arrived() { break }
            await Task.yield()
        }
        let reachedBoundary = await acceptance.arrived()
        XCTAssertTrue(reachedBoundary)
        XCTAssertFalse(ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID),
                       "rename/delete must not enter between slash.exec and generated submit")

        await acceptance.open()
        let settled = try await generated.value
        XCTAssertEqual(settled, true)
        XCTAssertTrue(ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID),
                      "the lifecycle fence must release after generated-submit settlement")
        ProfileLifecycleTrafficAdmission.endLifecycle(gatewayID)
        await pool.disconnectAll()
    }

    func testMCPStateFinalizesInsideLeaseBeforeReplacementPurgesG1() async throws {
        let url = try XCTUnwrap(URL(string: "https://mcp-lease.example"))
        let credential = GatewayCredential.sessionToken("test")
        let first = GatewayClient(baseURL: url, credential: credential)
        let second = GatewayClient(baseURL: url, credential: credential)
        let pool = GatewayClientPool { _, _ in first }
        await pool.adopt(first, for: "gateway")
        let snapshot = try await pool.connectWithGeneration(
            gatewayID: "gateway", baseURL: url, credential: credential)
        let response = CommandAcceptanceGate()
        let replacementStarted = CommandTaskProbe()
        var settlement = "in-flight"

        let answer = Task { @MainActor in
            await pool.withCommandConnectionLease(snapshot, for: "gateway") {
                await response.wait()
                settlement = "retryable"
                let stillG1 = await pool.isCurrent(snapshot, for: "gateway")
                return stillG1 && settlement == "retryable"
            }
        }
        for _ in 0..<100 {
            if await response.arrived() { break }
            await Task.yield()
        }
        let replacement = Task {
            await replacementStarted.mark()
            await pool.adopt(second, for: "gateway")
        }
        for _ in 0..<100 {
            if await replacementStarted.marked() { break }
            await Task.yield()
        }
        await Task.yield()
        XCTAssertEqual(settlement, "in-flight")
        let currentBeforeSettlement = await pool.isCurrent(snapshot, for: "gateway")
        XCTAssertTrue(currentBeforeSettlement)

        await response.open()
        let settledBeforeRelease = await answer.value
        XCTAssertEqual(settledBeforeRelease, true,
                       "retry/uncertain state must settle while G1 still owns the slot")
        await replacement.value
        XCTAssertEqual(settlement, "retryable")
        let currentAfterSettlement = await pool.isCurrent(snapshot, for: "gateway")
        XCTAssertFalse(currentAfterSettlement)
        await pool.disconnectAll()
    }

    func testGeneratedSlashRetainsDraftWhenCapturedGenerationWasReplaced() {
        XCTAssertEqual(SlashGeneratedSubmissionPolicy.decision(
            capturedGeneration: 7, observedGeneration: 8,
            clientMatches: false, bindingMatches: true), .retainDraft)
        XCTAssertEqual(SlashGeneratedSubmissionPolicy.decision(
            capturedGeneration: 7, observedGeneration: 7,
            clientMatches: true, bindingMatches: false), .retainDraft)
        XCTAssertEqual(SlashGeneratedSubmissionPolicy.decision(
            capturedGeneration: 7, observedGeneration: 7,
            clientMatches: true, bindingMatches: true), .submit)
    }

    func testGeneratedSlashEveryNonAcceptedSettlementRetainsDraft() {
        XCTAssertFalse(SlashGeneratedSettlementPolicy.requiresDraftRetention(.accepted))
        XCTAssertTrue(SlashGeneratedSettlementPolicy.requiresDraftRetention(.retained))
        XCTAssertTrue(SlashGeneratedSettlementPolicy.requiresDraftRetention(.failed),
                      "a definitive second-boundary rejection must retain the generated prompt")
    }

    func testGeneratedSlashRetainedSettlementShowsUpstreamNoticeAndRecovery() {
        let notice = "Goal resumed, continuing now."
        let recovery = SlashGeneratedSettlementPolicy.retainedDraftNotice

        XCTAssertEqual(SlashGeneratedSettlementPolicy.messages(
            for: .accepted, notice: notice), [notice])
        XCTAssertEqual(SlashGeneratedSettlementPolicy.messages(
            for: .retained, notice: notice), [notice, recovery])
        XCTAssertEqual(SlashGeneratedSettlementPolicy.messages(
            for: .failed, notice: notice), [notice, recovery])
        XCTAssertEqual(SlashGeneratedSettlementPolicy.messages(
            for: .retained, notice: nil), [recovery])
    }

    override func tearDown() {
        let runtime = LiveRuntime.shared
        runtime.gatewayID = nil
        runtime.defaultBotID = nil
        runtime.sessionToBot.removeAll()
        runtime.routedSessionToBot.removeAll()
        runtime.approvalTargets.removeAll()
        MultiGatewayRuntime.shared.routedUnread.removeAll()
        ApprovalBridges.shared.details.removeAll()
        ApprovalBridges.shared.prompts.removeAll()
        ApprovalBridges.shared.decided.removeAll()
        ApprovalBridges.shared.sweptSessions.removeAll()
        ApprovalBridges.shared.sweepFailures.removeAll()
        ApprovalBridges.shared.sweepEpochs.removeAll()
        FeedsRuntime.shared.cronJobs.removeAll()
        FeedsRuntime.shared.cronScope.removeAll()
        FeedsRuntime.shared.routineTargets.removeAll()
        FeedsRuntime.shared.inboxSessions.removeAll()
        CronDetailRuntime.shared.reset()
        CronDetailRuntime.shared.changeTick = 0
        CapabilityRuntime.shared.states.removeAll()
        ModelPickerRuntime.shared.states.removeAll()
        ApprovalPolicyRuntime.shared.reset()
        ProfileAssetStore.shared.flush()
        PetRuntime.shared.reset()
        CommandsRuntime.shared.mcpRequests.removeAll()
        CommandsRuntime.shared.mcpClients.removeAll()
        CommandsRuntime.shared.mcpResponsesInFlight.removeAll()
        CommandsRuntime.shared.mcpResponseErrors.removeAll()
        CommandsRuntime.shared.slashPrefills.removeAll()
        CommandsRuntime.shared.connectionGenerations.removeAll()
        CommandsRuntime.shared.catalogs.removeAll()
        CommandsRuntime.shared.routerPump?.cancel()
        CommandsRuntime.shared.routerPump = nil
        CommandsRuntime.shared.routerOwner = nil
        CommandsRuntime.shared.routerGatewayID = nil
        CommandsRuntime.shared.routerClient = nil
        CommandsRuntime.shared.routerHandlerID = nil
        SessionsRuntime.shared.resetPrimaryScope()
        SessionsRuntime.shared.resetRoutedScope(gatewayID: "homelab")
        A2ARuntime.shared.reset()
        super.tearDown()
    }

    func testSameRuntimeSessionIDRoutesByGateway() {
        let model = AppModel()
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.sessionToBot["deadbeef"] = "default"
        runtime.routedSessionToBot[
            GatewaySessionRoute(gatewayID: "homelab", sessionID: "deadbeef")
        ] = "homelab::researcher"

        XCTAssertEqual(model.botID(forSession: "deadbeef", sourceGatewayID: "primary"),
                       "default")
        XCTAssertEqual(model.botID(forSession: "deadbeef", sourceGatewayID: "homelab"),
                       "homelab::researcher")
        XCTAssertNil(model.botID(forSession: "deadbeef", sourceGatewayID: "unknown"))
    }

    func testMCPSetupRequestIdentityIncludesGatewayAndRequestID() {
        let model = AppModel()
        let event = GatewayEvent(
            type: "mcp.setup.request", sessionID: "same-runtime-session",
            payload: .object([
                "request_id": .string("same-request"),
                "server": .string("github"),
                "action": .string("install"),
            ])
        )

        model.handleMCPSetupRequest(event, sourceGatewayID: "primary")
        model.handleMCPSetupRequest(event, sourceGatewayID: "homelab")
        model.handleMCPSetupRequest(event, sourceGatewayID: "primary")

        let requests = CommandsRuntime.shared.mcpRequests
        XCTAssertEqual(requests.count, 2, "same-gateway duplicates must collapse only within that gateway")
        XCTAssertEqual(Set(requests.map(\.id)).count, 2)
        XCTAssertEqual(Set(requests.map(\.gatewayID)), Set(["primary", "homelab"]))

        model.handleMCPSetupRequest(
            GatewayEvent(type: "mcp.setup.expire", sessionID: "",
                         payload: .object(["request_id": .string("same-request")])),
            sourceGatewayID: "primary"
        )
        XCTAssertEqual(CommandsRuntime.shared.mcpRequests.map(\.gatewayID), ["homelab"],
                       "an expiry must not remove a colliding request on another source")
    }

    func testMCPIdentityIncludesConnectionGenerationAndFailureRemainsRetryable() {
        let state = CommandsRuntime.shared
        let model = AppModel()
        XCTAssertTrue(state.observeConnection(gatewayID: "primary", generation: 4))
        let request = MCPSetupRequest(
            gatewayID: "primary", connectionGeneration: 4,
            requestID: "same-request", sessionID: "runtime", server: "github",
            action: .install, reason: "needed")
        let replacementRoute = GatewayMCPSetupRoute(
            gatewayID: "primary", connectionGeneration: 5,
            requestID: "same-request")
        state.mcpRequests = [request]
        state.mcpResponsesInFlight = [request.route]

        XCTAssertNotEqual(request.route, replacementRoute)
        XCTAssertTrue(state.retainFailedMCPResponse(route: request.route,
                                                    detail: "transport closed"))
        XCTAssertEqual(state.mcpRequests, [request],
                       "a failed response must leave the card available to retry")
        XCTAssertFalse(state.mcpResponsesInFlight.contains(request.route))
        XCTAssertEqual(state.mcpResponseErrors[request.route], "transport closed")
        XCTAssertTrue(model.mcpSetupPrompt?.reason.contains("still open") == true,
                      "the retained card must explain the failure and retry path")
        XCTAssertFalse(state.retainFailedMCPResponse(route: request.route,
                                                     detail: "transport closed"),
                       "the same visible failure should not be appended twice")
    }

    func testConnectionReplacementPurgesOldPrefillAndMCPAuthority() {
        let state = CommandsRuntime.shared
        let route = GatewayBotRoute(gatewayID: "primary", profile: "default")
        let chat = ChatState()
        let request = MCPSetupRequest(
            gatewayID: "primary", connectionGeneration: 4,
            requestID: "request", sessionID: "runtime", server: "github",
            action: .install, reason: "needed")
        let client = GatewayClient(baseURL: URL(string: "https://commands.example")!,
                                   credential: .sessionToken("test"))
        XCTAssertTrue(state.observeConnection(gatewayID: "primary", generation: 4))
        state.slashPrefills[route] = SlashPrefillBinding(
            botID: "default", route: route, connectionGeneration: 4,
            chatID: ObjectIdentifier(chat), storedSessionID: "stored",
            runtimeSessionID: "runtime", message: "draft")
        state.mcpRequests = [request]
        state.mcpClients[request.route] = MCPClientBinding(
            client: client, connectionGeneration: 4)

        XCTAssertTrue(state.observeConnection(gatewayID: "primary", generation: 5))

        XCTAssertTrue(state.slashPrefills.isEmpty)
        XCTAssertTrue(state.mcpRequests.isEmpty)
        XCTAssertTrue(state.mcpClients.isEmpty)
        XCTAssertEqual(state.connectionGenerations["primary"], 5)
        XCTAssertFalse(state.observeConnection(gatewayID: "primary", generation: 4),
                       "a late old-client callback must not downgrade authority")
    }

    func testCommandCatalogRuntimeIsPhysicallyGatewayScoped() {
        let state = CommandsRuntime.shared
        let primary = state.catalog(for: "primary", owner: nil)
        let remote = state.catalog(for: "homelab", owner: nil)
        primary.catalog = [SlashCommand(name: "/primary", description: "", category: "")]
        remote.catalog = [SlashCommand(name: "/remote", description: "", category: "")]
        primary.catalogLoaded = true
        remote.catalogLoaded = true

        XCTAssertNotEqual(ObjectIdentifier(primary), ObjectIdentifier(remote))
        XCTAssertEqual(state.catalogs["primary"]?.catalog.map(\.name), ["/primary"])
        XCTAssertEqual(state.catalogs["homelab"]?.catalog.map(\.name), ["/remote"])
    }

    func testRemoteDeltaCannotMutateCollidingPrimaryChat() {
        let model = AppModel()
        model.mode = .live
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.sessionToBot["deadbeef"] = "default"
        runtime.routedSessionToBot[
            GatewaySessionRoute(gatewayID: "homelab", sessionID: "deadbeef")
        ] = "homelab::researcher"

        let event = GatewayEvent(type: "message.delta", sessionID: "deadbeef",
                                 payload: .object(["text": .string("remote answer")]))
        model.handle(event: event, sourceGatewayID: "homelab")

        XCTAssertTrue(model.chat(for: "default").messages.isEmpty)
        XCTAssertEqual(model.chat(for: "homelab::researcher").messages.last?.text,
                       "remote answer")
    }

    func testForeignOpenKeepsQualifiedIdentity() async {
        let model = AppModel()
        let entry = ForeignRosterEntry(gatewayID: "homelab",
                                       connectionLabel: "Homelab",
                                       connectionKind: .tailscale,
                                       profile: "researcher",
                                       handle: "researcher")

        await model.openForeignBot(entry)

        XCTAssertEqual(model.openBotID, "homelab::researcher")
        XCTAssertEqual(model.selectedTab, .home)
    }

    func testPrimaryResetPreservesRemoteSessionRouting() {
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.sessionToBot["aaaaaaaa"] = "default"
        let remote = GatewaySessionRoute(gatewayID: "homelab", sessionID: "bbbbbbbb")
        runtime.routedSessionToBot[remote] = "homelab::researcher"
        runtime.workingBotIDs = ["default", "homelab::researcher"]
        runtime.approvalTargets["primary"] = target(
            gatewayID: "primary", profile: "default", sessionID: "aaaaaaaa",
            requestID: "primary-wire")
        runtime.approvalTargets["remote"] = target(
            gatewayID: "homelab", profile: "researcher", sessionID: "bbbbbbbb",
            requestID: "remote-wire")

        runtime.resetSessionState()

        XCTAssertTrue(runtime.sessionToBot.isEmpty)
        XCTAssertEqual(runtime.routedSessionToBot[remote], "homelab::researcher")
        XCTAssertEqual(runtime.workingBotIDs, ["homelab::researcher"])
        XCTAssertNil(runtime.approvalTargets["primary"])
        XCTAssertEqual(runtime.approvalTargets["remote"]?.requestID, "remote-wire")
    }

    func testRemoteSessionTitleCannotPatchCollidingPrimaryStoredID() {
        let model = AppModel()
        model.mode = .live
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.sessionToBot["deadbeef"] = "default"
        runtime.routedSessionToBot[
            GatewaySessionRoute(gatewayID: "homelab", sessionID: "deadbeef")
        ] = "homelab::researcher"
        model.chat(for: "default").storedSessions = [
            SessionSummary(id: "same-row", title: "Primary", when: "now", messageCount: 1),
        ]
        model.chat(for: "homelab::researcher").storedSessions = [
            SessionSummary(id: "same-row", title: "Remote", when: "now", messageCount: 1),
        ]

        let event = GatewayEvent(type: "session.title", sessionID: "deadbeef",
                                 payload: .object([
                                    "session_id": .string("same-row"),
                                    "title": .string("Remote renamed"),
                                 ]))
        model.applySessionTitle(event, sourceGatewayID: "homelab")

        XCTAssertEqual(model.chat(for: "default").storedSessions[0].title, "Primary")
        XCTAssertEqual(model.chat(for: "homelab::researcher").storedSessions[0].title,
                       "Remote renamed")
        XCTAssertNil(SessionsRuntime.shared.titles[
            SessionsRuntime.key(botID: "default", sessionID: "same-row")])
        XCTAssertEqual(SessionsRuntime.shared.titles[
            SessionsRuntime.key(botID: "homelab::researcher", sessionID: "same-row")],
                       "Remote renamed")
    }

    func testRemoteCompletionPrunesOnlyExactGatewaySessionRoute() {
        let model = AppModel()
        model.mode = .live
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.sessionToBot["deadbeef"] = "default"
        runtime.routedSessionToBot[
            GatewaySessionRoute(gatewayID: "homelab", sessionID: "deadbeef")
        ] = "homelab::researcher"
        runtime.approvalTargets["primary-approval"] = target(
            gatewayID: "primary", profile: "default", sessionID: "deadbeef",
            requestID: "primary-wire")
        runtime.approvalTargets["remote-approval"] = target(
            gatewayID: "homelab", profile: "researcher", sessionID: "deadbeef",
            requestID: "remote-wire")
        model.approvals = [
            approval(id: "primary-approval", botID: "default"),
            approval(id: "remote-approval", botID: "homelab::researcher"),
        ]

        model.handle(event: GatewayEvent(
            type: "message.complete", sessionID: "deadbeef",
            payload: .object(["status": .string("complete"), "text": .string("")])),
            sourceGatewayID: "homelab")

        XCTAssertEqual(model.approvals.map(\.id), ["primary-approval"])
        XCTAssertEqual(runtime.approvalTargets["primary-approval"]?.session.sessionID,
                       "deadbeef")
        XCTAssertNil(runtime.approvalTargets["remote-approval"])
    }

    func testUnmappedRemoteApprovalCannotFallbackToPrimaryBot() {
        let model = AppModel()
        model.mode = .live
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.defaultBotID = "default"

        model.handle(event: approvalEvent(requestID: "orphaned", sessionID: "deadbeef"),
                     sourceGatewayID: "homelab")

        XCTAssertTrue(model.approvals.isEmpty)
        XCTAssertTrue(runtime.approvalTargets.isEmpty)
    }

    func testApprovalResponseRejectsMixedGatewayOwnership() {
        let model = AppModel()
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.approvalTargets["remote-approval"] = target(
            gatewayID: "homelab", profile: "researcher", sessionID: "deadbeef",
            requestID: "wire-request")
        let item = approval(id: "remote-approval", botID: "default")

        let target = model.approvalResponseTarget(
            for: item, botRoute: GatewayBotRoute(gatewayID: "primary", profile: "default"))

        XCTAssertNil(target)
    }

    func testApprovalResponseKeepsQualifiedRemoteDestination() {
        let model = AppModel()
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        let session = GatewaySessionRoute(gatewayID: "homelab", sessionID: "deadbeef")
        runtime.approvalTargets["remote-approval"] = target(
            gatewayID: "homelab", profile: "researcher", sessionID: "deadbeef",
            requestID: "wire-request")
        let item = approval(id: "remote-approval", botID: "homelab::researcher")
        let bot = GatewayBotRoute(gatewayID: "homelab", profile: "researcher")

        XCTAssertEqual(model.approvalResponseTarget(for: item, botRoute: bot),
                       ApprovalResponseTarget(bot: bot, session: session,
                                              requestID: "wire-request"))
    }

    func testSameApprovalRequestIDRemainsDistinctAcrossGateways() {
        let model = AppModel()
        model.mode = .live
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.sessionToBot["deadbeef"] = "default"
        runtime.routedSessionToBot[
            GatewaySessionRoute(gatewayID: "homelab", sessionID: "deadbeef")
        ] = "homelab::default"

        model.handle(event: approvalEvent(requestID: "same-request", sessionID: "deadbeef"),
                     sourceGatewayID: "primary")
        model.handle(event: approvalEvent(requestID: "same-request", sessionID: "deadbeef"),
                     sourceGatewayID: "homelab")

        XCTAssertEqual(model.approvals.count, 2)
        XCTAssertEqual(Set(model.approvals.map(\.id)).count, 2)
        XCTAssertEqual(Set(runtime.approvalTargets.values.map(\.requestID)), ["same-request"])
        XCTAssertEqual(Set(runtime.approvalTargets.values.map(\.session.gatewayID)),
                       ["primary", "homelab"])
    }

    func testCollidingBlockingPromptIDsDismissOnlyOwningGateway() {
        let model = AppModel()
        model.mode = .live
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        runtime.sessionToBot["deadbeef"] = "default"
        runtime.routedSessionToBot[
            GatewaySessionRoute(gatewayID: "homelab", sessionID: "deadbeef")
        ] = "homelab::default"
        let event = GatewayEvent(type: "clarify.request", sessionID: "deadbeef",
                                 payload: .object([
                                    "request_id": .string("same-request"),
                                    "question": .string("Continue?"),
                                 ]))

        model.handleBridgeEvent(event, sourceGatewayID: "primary")
        model.handleBridgeEvent(event, sourceGatewayID: "homelab")

        XCTAssertEqual(ApprovalBridges.shared.prompts.count, 2)
        XCTAssertEqual(Set(ApprovalBridges.shared.prompts.map(\.id)).count, 2)
        model.dismissBlockingPrompt("same-request")
        XCTAssertEqual(ApprovalBridges.shared.prompts.count, 2,
                       "a bare colliding request id must fail closed")
        model.dismissBlockingPrompt("same-request", sourceGatewayID: "homelab")
        XCTAssertEqual(ApprovalBridges.shared.prompts.map(\.gatewayID), ["primary"])
    }

    func testWireApprovalLookupUsesBotToDisambiguateGatewayCollision() {
        let model = AppModel()
        let runtime = LiveRuntime.shared
        let primaryID = GatewayApprovalRoute(gatewayID: "primary",
                                              requestID: "same-request").qualifiedID
        let remoteID = GatewayApprovalRoute(gatewayID: "homelab",
                                             requestID: "same-request").qualifiedID
        runtime.approvalTargets[primaryID] = target(
            gatewayID: "primary", profile: "default", sessionID: "aaaaaaaa",
            requestID: "same-request")
        runtime.approvalTargets[remoteID] = target(
            gatewayID: "homelab", profile: "default", sessionID: "bbbbbbbb",
            requestID: "same-request")
        model.approvals = [
            approval(id: primaryID, botID: "default"),
            approval(id: remoteID, botID: "homelab::default"),
        ]

        XCTAssertNil(model.approval(matchingWireRequestID: "same-request", botID: nil))
        XCTAssertEqual(model.approval(matchingWireRequestID: "same-request",
                                      botID: "homelab::default")?.id, remoteID)
    }

    func testGatewayDetachDropsOnlyItsApprovalSurfaces() {
        let model = AppModel()
        let runtime = LiveRuntime.shared
        let primaryID = GatewayApprovalRoute(gatewayID: "primary",
                                              requestID: "primary").qualifiedID
        let remoteID = GatewayApprovalRoute(gatewayID: "homelab",
                                             requestID: "remote").qualifiedID
        runtime.approvalTargets[primaryID] = target(
            gatewayID: "primary", profile: "default", sessionID: "aaaaaaaa",
            requestID: "primary")
        runtime.approvalTargets[remoteID] = target(
            gatewayID: "homelab", profile: "default", sessionID: "bbbbbbbb",
            requestID: "remote")
        model.approvals = [
            approval(id: primaryID, botID: "default"),
            approval(id: remoteID, botID: "homelab::default"),
        ]
        ApprovalBridges.shared.prompts = [
            BlockingPrompt(kind: .sudo, gatewayID: "primary", requestID: "prompt",
                           sessionID: "aaaaaaaa", botID: "default", question: ""),
            BlockingPrompt(kind: .sudo, gatewayID: "homelab", requestID: "prompt",
                           sessionID: "bbbbbbbb", botID: "homelab::default", question: ""),
        ]

        model.dropApprovalScope(gatewayID: "homelab")

        XCTAssertEqual(model.approvals.map(\.id), [primaryID])
        XCTAssertNotNil(runtime.approvalTargets[primaryID])
        XCTAssertNil(runtime.approvalTargets[remoteID])
        XCTAssertEqual(ApprovalBridges.shared.prompts.map(\.gatewayID), ["primary"])
    }

    func testApprovalPolicyStoresRemainDistinctAcrossGateways() {
        let model = AppModel()
        model.mode = .live
        LiveRuntime.shared.gatewayID = "primary"
        let runtime = ApprovalPolicyRuntime.shared

        runtime.selectedGatewayID = "primary"
        let primary = model.approvalPolicy
        primary.mode = .manual
        primary.pairing = PairingSnapshot(
            pending: [], approved: [PairedUser(platform: "telegram", userID: "one",
                                               userName: "One", approvedAt: nil)])

        runtime.selectedGatewayID = "homelab"
        let remote = model.approvalPolicy
        remote.mode = .smart
        remote.pairing = PairingSnapshot(
            pending: [], approved: [PairedUser(platform: "discord", userID: "two",
                                               userName: "Two", approvedAt: nil)])

        XCTAssertFalse(primary === remote)
        XCTAssertEqual(primary.mode, .manual)
        XCTAssertEqual(remote.mode, .smart)
        XCTAssertEqual(primary.pairing.approved.map(\.userID), ["one"])
        XCTAssertEqual(remote.pairing.approved.map(\.userID), ["two"])
    }

    func testApprovalPolicySelectionSurvivesPrimaryRoleTransition() {
        let model = AppModel()
        model.mode = .live
        let runtime = ApprovalPolicyRuntime.shared
        runtime.selectedGatewayID = "homelab"
        let selected = model.approvalPolicy
        selected.mode = .off

        LiveRuntime.shared.gatewayID = "primary"
        XCTAssertTrue(model.approvalPolicy === selected)
        LiveRuntime.shared.gatewayID = "homelab"
        XCTAssertTrue(model.approvalPolicy === selected)
        XCTAssertEqual(model.approvalPolicy.mode, .off)
    }

    func testSelectedRemotePolicyListsOnlyItsSessionBypasses() {
        let model = AppModel()
        model.mode = .live
        LiveRuntime.shared.gatewayID = "primary"
        ApprovalPolicyRuntime.shared.selectedGatewayID = "homelab"
        let primary = Bot.unlisted(id: "default")
        let remote = Bot.unlisted(id: "homelab::researcher")
        model.chat(for: primary.id).yolo = true
        model.chat(for: remote.id).yolo = true

        let visible = model.approvalSessionBypassBots(in: [primary, remote])

        XCTAssertEqual(visible.map(\.id), ["homelab::researcher"])
    }

    func testApprovalPolicyDetachDropsOnlyOwningGateway() {
        let model = AppModel()
        model.mode = .live
        let runtime = ApprovalPolicyRuntime.shared
        runtime.selectedGatewayID = "primary"
        let primary = model.approvalPolicy
        primary.mode = .smart
        runtime.selectedGatewayID = "homelab"
        let remote = model.approvalPolicy
        remote.mode = .off

        model.dropApprovalPolicyScope(gatewayID: "homelab")

        runtime.selectedGatewayID = "primary"
        XCTAssertTrue(model.approvalPolicy === primary)
        XCTAssertEqual(model.approvalPolicy.mode, .smart)
        runtime.selectedGatewayID = "homelab"
        XCTAssertFalse(model.approvalPolicy === remote)
        XCTAssertEqual(model.approvalPolicy.mode, .manual)
    }

    func testPairingChangeDuringReadQueuesOneFollowUpRefresh() async {
        let model = AppModel()
        let store = model.approvalPolicy
        store.isLoadingPairing = true

        await model.loadPairing()

        XCTAssertTrue(store.pairingRefreshPending)
        store.isLoadingPairing = false
        await model.loadPairing()
        await Task.yield()
        XCTAssertFalse(store.pairingRefreshPending)
        XCTAssertTrue(store.hasLoadedPairing)
        XCTAssertEqual(store.pairingSupport, .supported)
    }

    func testFailedApprovalResponseReopensCardAndClearsFalseOutcome() {
        let model = AppModel()
        let item = approval(id: "retry", botID: "default")
        ApprovalOutcomes.shared.record(item, approved: true)
        ApprovalBridges.shared.decided[item.id] = .always

        model.restoreFailedApproval(item)

        XCTAssertEqual(model.approvals, [item])
        XCTAssertNil(ApprovalOutcomes.shared.choice(for: item.id))
    }

    func testCollidingRoutineIDsKeepDistinctGatewayTargets() {
        let model = AppModel()
        model.mode = .live
        LiveRuntime.shared.gatewayID = "primary"
        let primary = routine(id: "same", botID: "default")
        let remoteID = GatewayRoutineRoute(gatewayID: "homelab", jobID: "same").qualifiedID
        let remote = routine(id: remoteID, botID: "homelab::default")
        FeedsRuntime.shared.routineTargets[primary.id] = RoutineTarget(
            route: GatewayRoutineRoute(gatewayID: "primary", jobID: "same"),
            bot: GatewayBotRoute(gatewayID: "primary", profile: "default"), profile: nil)
        FeedsRuntime.shared.routineTargets[remote.id] = RoutineTarget(
            route: GatewayRoutineRoute(gatewayID: "homelab", jobID: "same"),
            bot: GatewayBotRoute(gatewayID: "homelab", profile: "default"), profile: "default")

        XCTAssertTrue(model.routineHasFullManagement(primary))
        XCTAssertTrue(model.routineHasFullManagement(remote))
        XCTAssertEqual(model.routineTarget(primary.id)?.route,
                       GatewayRoutineRoute(gatewayID: "primary", jobID: "same"))
        XCTAssertEqual(model.routineTarget(remote.id)?.route,
                       GatewayRoutineRoute(gatewayID: "homelab", jobID: "same"))
        XCTAssertEqual(model.cronScope(primary.id), nil)
        XCTAssertEqual(model.cronScope(remote.id), "default")
        XCTAssertEqual(model.routineGatewayID(routineID: primary.id), "primary")
        XCTAssertEqual(model.routineGatewayID(routineID: remote.id), "homelab")
        XCTAssertEqual(model.routineGatewayID(botID: "default"), "primary")
        XCTAssertEqual(model.routineGatewayID(botID: "homelab::default"), "homelab")
    }

    func testCollidingCronActivityUsesPrimaryAndRetainedSourceIdentity() {
        let primaryTarget = RoutineTarget(
            route: GatewayRoutineRoute(gatewayID: "primary", jobID: "same"),
            bot: GatewayBotRoute(gatewayID: "primary", profile: "default"),
            profile: "default")
        let retainedTarget = RoutineTarget(
            route: GatewayRoutineRoute(gatewayID: "homelab", jobID: "same"),
            bot: GatewayBotRoute(gatewayID: "homelab", profile: "default"),
            profile: "default")
        let primaryFence = CronRoutineMutationFence(
            routineID: "same", target: primaryTarget,
            source: CronSourceMutationFence(
                gatewayID: "primary", profile: "default", generation: .primary(4)),
            profileGeneration: 8)
        let retainedFence = CronRoutineMutationFence(
            routineID: "same", target: retainedTarget,
            source: CronSourceMutationFence(
                gatewayID: "homelab", profile: "default", generation: .retained(9)),
            profileGeneration: 8)

        XCTAssertNotEqual(primaryFence.activityIdentity, retainedFence.activityIdentity)
    }

    func testRoutineRESTCapabilityAndDeliveryCachesAreGatewayScoped() {
        let model = AppModel()
        model.mode = .live
        LiveRuntime.shared.gatewayID = "primary"
        // The cache is valid only for the exact live client that produced its
        // generation fence; seed that client so this remains a cache-isolation
        // test rather than an offline/no-authority case.
        model.client = GatewayClient(
            baseURL: URL(string: "http://primary.test")!,
            credential: .sessionToken("test"))
        let primary = routine(id: "same", botID: "default")
        let remoteID = GatewayRoutineRoute(gatewayID: "homelab", jobID: "same").qualifiedID
        let remote = routine(id: remoteID, botID: "homelab::default")
        FeedsRuntime.shared.routineTargets[primary.id] = RoutineTarget(
            route: GatewayRoutineRoute(gatewayID: "primary", jobID: "same"),
            bot: GatewayBotRoute(gatewayID: "primary", profile: "default"), profile: nil)
        FeedsRuntime.shared.routineTargets[remote.id] = RoutineTarget(
            route: GatewayRoutineRoute(gatewayID: "homelab", jobID: "same"),
            bot: GatewayBotRoute(gatewayID: "homelab", profile: "default"), profile: nil)
        let runtime = CronDetailRuntime.shared
        runtime.restSupported["primary"] = false
        runtime.restSupported["homelab"] = true
        runtime.deliveryTargets["primary"] = [CronDeliveryTarget(["id": "local"])]
        runtime.deliveryTargets["homelab"] = [CronDeliveryTarget(["id": "telegram"])]
        let remoteClient = GatewayClient(
            baseURL: URL(string: "http://homelab.test")!,
            credential: .sessionToken("test"))
        let remotePump = Task<Void, Never> {}
        MultiGatewayRuntime.shared.routedEventGenerations["homelab"] = 1
        MultiGatewayRuntime.shared.routedEvents["homelab"] = MultiGatewayRuntime.RoutedEvents(
            client: remoteClient, handlerID: UUID(), pump: remotePump, generation: 1)
        runtime.deliveryGeneration["primary"] = model.cronDeliverySourceFence(
            routineID: primary.id, botID: "primary::deceptive")?.fence
        runtime.deliveryGeneration["homelab"] = model.cronDeliverySourceFence(
            routineID: remote.id, botID: "homelab::deceptive")?.fence
        defer {
            runtime.deliveryGeneration.removeValue(forKey: "primary")
            runtime.deliveryGeneration.removeValue(forKey: "homelab")
            MultiGatewayRuntime.shared.routedEvents.removeValue(forKey: "homelab")
            MultiGatewayRuntime.shared.routedEventGenerations.removeValue(forKey: "homelab")
            remotePump.cancel()
        }

        XCTAssertEqual(model.cronDeliveryTargets(routineID: primary.id).map(\.id), ["local"])
        XCTAssertEqual(model.cronDeliveryTargets(routineID: remote.id).map(\.id), ["telegram"])
        XCTAssertEqual(runtime.restSupported[model.routineGatewayID(routineID: primary.id)!], false)
        XCTAssertEqual(runtime.restSupported[model.routineGatewayID(routineID: remote.id)!], true)
    }

    func testUnscopedTaggedRoutineKeepsDisplayBotForSocketManagementOnly() {
        let model = AppModel()
        model.mode = .live
        LiveRuntime.shared.gatewayID = "primary"
        let routine = routine(id: "created", botID: "worker")
        FeedsRuntime.shared.routineTargets[routine.id] = RoutineTarget(
            route: GatewayRoutineRoute(gatewayID: "primary", jobID: "created"),
            bot: GatewayBotRoute(gatewayID: "primary", profile: "worker"),
            profile: nil)
        defer { FeedsRuntime.shared.routineTargets.removeValue(forKey: routine.id) }

        XCTAssertEqual(routine.botID, "worker")
        XCTAssertTrue(model.routineHasFullManagement(routine))
        XCTAssertEqual(model.cronScope(routine.id), nil)
        XCTAssertEqual(model.routineGatewayID(routineID: routine.id), "primary")
        XCTAssertFalse(model.cronRESTReady(routineID: routine.id, botID: "primary::worker"))
        XCTAssertEqual(model.cronDeliverySourceFence(
            routineID: routine.id, botID: "primary::worker")?.fence.profile, nil)
    }

    func testRoutineRunTranscriptKeepsOwningGateway() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        LiveRuntime.shared.defaultBotID = "default"
        let primaryID = "same"
        let remoteID = GatewayRoutineRoute(gatewayID: "homelab", jobID: "same").qualifiedID
        FeedsRuntime.shared.routineTargets[primaryID] = RoutineTarget(
            route: GatewayRoutineRoute(gatewayID: "primary", jobID: "same"),
            bot: GatewayBotRoute(gatewayID: "primary", profile: "default"), profile: nil)
        FeedsRuntime.shared.routineTargets[remoteID] = RoutineTarget(
            route: GatewayRoutineRoute(gatewayID: "homelab", jobID: "same"),
            bot: GatewayBotRoute(gatewayID: "homelab", profile: "default"), profile: nil)
        let run = CronRun(["id": "cron_same_1", "profile": "default"])

        XCTAssertEqual(model.routineRunBotID(run, routineID: primaryID,
                                             fallbackBotID: "default"), "default")
        XCTAssertEqual(model.routineRunBotID(run, routineID: remoteID,
                                             fallbackBotID: "default"), "homelab::default")
    }

    func testCollidingCapabilityProfilesKeepDistinctGatewayState() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        let primary = model.capabilities(for: "default")
        let remote = model.capabilities(for: "homelab::default")

        XCTAssertFalse(primary === remote)
        XCTAssertEqual(primary.target,
                       CapabilityTarget(gatewayID: "primary", profile: "default"))
        XCTAssertEqual(remote.target,
                       CapabilityTarget(gatewayID: "homelab", profile: "default"))
        XCTAssertNotEqual(primary.target?.stateKey, remote.target?.stateKey)
        XCTAssertEqual(model.capabilityTarget(profileID: "homelab::default")?.profile,
                       "default")
    }

    func testCapabilityStateFollowsGatewayRoleWithoutCollision() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        let before = model.capabilities(for: "default")
        LiveRuntime.shared.gatewayID = "homelab"
        let after = model.capabilities(for: "default")

        XCTAssertFalse(before === after)
        XCTAssertEqual(before.target?.gatewayID, "primary")
        XCTAssertEqual(after.target?.gatewayID, "homelab")
    }

    func testCapabilityGatewayDetachPreservesOtherGatewayState() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        let primary = model.capabilities(for: "default")
        let remote = model.capabilities(for: "homelab::default")
        let primaryKey = primary.target!.stateKey
        let remoteKey = remote.target!.stateKey
        remote.skills = [SkillEntry(name: "browser", category: "web",
                                    scope: .profile, enabled: true)]
        remote.busy.insert("skill:browser")
        remote.hasLoaded = true

        model.dropCapabilityScope(gatewayID: "homelab")

        XCTAssertTrue(CapabilityRuntime.shared.states[primaryKey] === primary)
        XCTAssertNil(CapabilityRuntime.shared.states[remoteKey])
        XCTAssertTrue(remote.skills.isEmpty)
        XCTAssertTrue(remote.busy.isEmpty)
        XCTAssertFalse(remote.hasLoaded)
    }

    func testProfileRPCIdentityStripsOnlyTheQualifiedSource() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"

        XCTAssertEqual(model.profileRoute(for: "default"),
                       GatewayBotRoute(gatewayID: "primary", profile: "default"))
        XCTAssertEqual(model.profileRoute(for: "homelab::default"),
                       GatewayBotRoute(gatewayID: "homelab", profile: "default"))
        XCTAssertEqual(model.cloneID(for: "homelab::default"), "default-2")
    }

    func testPortraitCacheKeepsCollidingProfilesInGatewayScopes() {
        let store = ProfileAssetStore.shared
        LiveRuntime.shared.gatewayID = "primary"
        let primary = Data([0x01])
        let remote = Data([0x02])

        store.set(primary, for: "default")
        store.set(remote, for: "homelab::default")

        XCTAssertEqual(store.portrait(for: "default"), primary)
        XCTAssertEqual(store.portrait(for: "homelab::default"), remote)
        store.drop(gatewayID: "homelab")
        XCTAssertEqual(store.portrait(for: "default"), primary)
        XCTAssertNil(store.portrait(for: "homelab::default"))
        store.set(remote, for: "homelab::default")
        LiveRuntime.shared.gatewayID = "homelab"
        XCTAssertEqual(store.portrait(for: "default"), remote)
    }

    func testProfileEditRequiresEveryIndependentSectionAcknowledgement() {
        let edit = ProfileEdit(description: "Ops", soul: "Careful",
                               model: "model-a", provider: "provider-a",
                               disabledSkills: ["browser"], enabledToolsets: [],
                               uiMeta: .object(["hermes-bots": .object([:])]))

        XCTAssertEqual(edit.expectedAppliedSections,
                       ["description", "soul", "model", "skills", "toolsets", "ui_meta"])
        XCTAssertFalse(edit.wasFullyApplied([
            "description": true, "soul": true, "model": true,
            "skills": true, "toolsets": false, "ui_meta": true
        ]))
        XCTAssertTrue(edit.wasFullyApplied(Dictionary(
            uniqueKeysWithValues: edit.expectedAppliedSections.map { ($0, true) })))
        let invalidPin = ProfileEdit(model: "model-a")
        XCTAssertFalse(invalidPin.isWireValid)
        XCTAssertFalse(invalidPin.wasFullyApplied([:]))
    }

    func testCollidingPetProfilesKeepDistinctGatewayState() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        let primary = model.pets(for: "default")
        let remote = model.pets(for: "homelab::default")

        XCTAssertFalse(primary === remote)
        XCTAssertEqual(primary.target, PetTarget(gatewayID: "primary", profile: "default"))
        XCTAssertEqual(remote.target, PetTarget(gatewayID: "homelab", profile: "default"))
        XCTAssertNotEqual(primary.target?.stateKey, remote.target?.stateKey)
    }

    func testPetUnsupportedCapabilityIsScopedToItsGateway() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        PetRuntime.shared.unsupportedGateways.insert("homelab")

        XCTAssertTrue(model.pets(for: "default").supported)
        XCTAssertFalse(model.pets(for: "homelab::default").supported)
    }

    func testPetGatewayDetachScrubsOnlyOwningSource() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        let primary = model.pets(for: "default")
        let remote = model.pets(for: "homelab::default")
        primary.hasLoaded = true
        remote.hasLoaded = true
        remote.notice = "private remote failure"
        remote.busy.insert("select:fox")
        let primaryKey = primary.target!.stateKey
        let remoteKey = remote.target!.stateKey
        PetRuntime.shared.loadIDs[primaryKey] = UUID()
        PetRuntime.shared.loadIDs[remoteKey] = UUID()
        PetRuntime.shared.refreshTasks["primary"] = Task {}
        PetRuntime.shared.refreshTasks["homelab"] = Task {}

        model.dropPetScope(gatewayID: "homelab")

        XCTAssertTrue(PetRuntime.shared.states[primaryKey] === primary)
        XCTAssertNil(PetRuntime.shared.states[remoteKey])
        XCTAssertTrue(primary.hasLoaded)
        XCTAssertFalse(remote.hasLoaded)
        XCTAssertNil(remote.notice)
        XCTAssertTrue(remote.busy.isEmpty)
        XCTAssertNotNil(PetRuntime.shared.loadIDs[primaryKey])
        XCTAssertNil(PetRuntime.shared.loadIDs[remoteKey])
        XCTAssertNotNil(PetRuntime.shared.refreshTasks["primary"])
        XCTAssertNil(PetRuntime.shared.refreshTasks["homelab"])
    }

    func testPetGenerationProgressRequiresOwningGateway() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        let remote = model.pets(for: "homelab::default")
        remote.generation.phase = .drafting
        PetRuntime.shared.generatingProfiles["homelab"] = remote.target!.stateKey
        let event = GatewayEvent(type: "pet.generate.progress", sessionID: "",
                                 payload: .object(["token": .string("remote-token"),
                                                   "count": .number(4)]))

        model.routePetEvent(event, sourceGatewayID: "primary")
        XCTAssertTrue(remote.generation.token.isEmpty)
        model.routePetEvent(event, sourceGatewayID: "homelab")
        XCTAssertEqual(remote.generation.token, "remote-token")
        XCTAssertEqual(remote.generation.expectedDrafts, 4)
    }

    func testPetGenerationRunsAreIndependentPerGateway() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        let primary = model.pets(for: "default")
        let remote = model.pets(for: "homelab::default")
        let runtime = PetRuntime.shared
        primary.generation.phase = .drafting
        remote.generation.phase = .drafting
        runtime.generatingProfiles["primary"] = primary.target!.stateKey
        runtime.generatingProfiles["homelab"] = remote.target!.stateKey
        runtime.runIDs["primary"] = UUID()
        runtime.runIDs["homelab"] = UUID()
        runtime.runTasks["primary"] = Task { try? await Task.sleep(for: .seconds(10)) }
        runtime.runTasks["homelab"] = Task { try? await Task.sleep(for: .seconds(10)) }

        model.dropPetScope(gatewayID: "homelab")

        XCTAssertNotNil(runtime.runTasks["primary"])
        XCTAssertNotNil(runtime.runIDs["primary"])
        XCTAssertEqual(runtime.generatingProfiles["primary"], primary.target!.stateKey)
        XCTAssertNil(runtime.runTasks["homelab"])
        XCTAssertNil(runtime.runIDs["homelab"])
        XCTAssertNil(runtime.generatingProfiles["homelab"])
    }

    func testCollidingModelPickersKeepDistinctGatewayState() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        let primary = model.modelPicker(for: "default")
        let remote = model.modelPicker(for: "homelab::default")

        XCTAssertFalse(primary === remote)
        XCTAssertEqual(primary.target, GatewayBotRoute(gatewayID: "primary", profile: "default"))
        XCTAssertEqual(remote.target, GatewayBotRoute(gatewayID: "homelab", profile: "default"))
        primary.catalog.model = "primary-model"
        remote.catalog.model = "remote-model"
        XCTAssertEqual(primary.catalog.model, "primary-model")
        XCTAssertEqual(remote.catalog.model, "remote-model")
    }

    func testModelPickerFollowsGatewayRoleWithoutCollision() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        let originalPrimary = model.modelPicker(for: "default")
        originalPrimary.catalog.model = "primary-model"

        LiveRuntime.shared.gatewayID = "homelab"
        let formerPrimaryAsRemote = model.modelPicker(for: "primary::default")
        let newPrimary = model.modelPicker(for: "default")

        XCTAssertTrue(formerPrimaryAsRemote === originalPrimary)
        XCTAssertEqual(formerPrimaryAsRemote.catalog.model, "primary-model")
        XCTAssertFalse(newPrimary === originalPrimary)
        XCTAssertEqual(newPrimary.target,
                       GatewayBotRoute(gatewayID: "homelab", profile: "default"))
    }

    func testModelSettingsTargetPrefersExplicitGateway() {
        XCTAssertEqual(GatewaySettingsTargetFence.resolve(
            selected: "homelab", available: ["primary", "homelab"],
            active: "primary", runtime: "primary"), "homelab")
        XCTAssertEqual(GatewaySettingsTargetFence.resolve(
            selected: nil, available: ["primary"],
            active: "primary", runtime: "stale"), "primary")
        XCTAssertEqual(GatewaySettingsTargetFence.resolve(
            selected: nil, available: [],
            active: nil, runtime: "reconnecting"), "reconnecting")
        XCTAssertEqual(GatewaySettingsTargetFence.resolve(
            selected: "deleted", available: ["primary"],
            active: "primary", runtime: "primary"), "primary")
    }

    func testModelSettingsRejectsLateResultAfterGatewayRoundTrip() {
        // A → B → A has the same apparent gateway id, but not the same
        // generation. The first A request must not paint over the second.
        XCTAssertFalse(GatewaySettingsTargetFence.accepts(
            stateGatewayID: "primary", targetGatewayID: "primary",
            generation: 4, currentGeneration: 6))
        XCTAssertFalse(GatewaySettingsTargetFence.accepts(
            stateGatewayID: "homelab", targetGatewayID: "primary",
            generation: 6, currentGeneration: 6))
        XCTAssertTrue(GatewaySettingsTargetFence.accepts(
            stateGatewayID: "primary", targetGatewayID: "primary",
            generation: 6, currentGeneration: 6))
    }

    func testModelSettingsRejectsLateMutationErrorAfterGatewaySwitch() {
        // Mutation errors use the same fence as successes. A failure from the
        // old gateway must not become the notice shown for the newly selected
        // gateway, even when the async operation itself throws.
        XCTAssertFalse(GatewaySettingsTargetFence.accepts(
            stateGatewayID: "homelab", targetGatewayID: "primary",
            generation: 8, currentGeneration: 9))
        XCTAssertFalse(GatewaySettingsTargetFence.accepts(
            stateGatewayID: "primary", targetGatewayID: "primary",
            generation: 8, currentGeneration: 9))
    }

    func testOperatorConfigParsesOnlySafeMobileControls() {
        let parsed = GatewayOperatorConfig(.object([
            "agent": .object(["max_turns": .number(750),
                              "image_input_mode": .string("text")]),
            "memory": .object(["memory_enabled": .bool(false),
                               "user_profile_enabled": .bool(true),
                               "write_approval": .bool(true)]),
        ]))
        XCTAssertEqual(parsed.maxTurns, 750)
        XCTAssertEqual(parsed.imageInputMode, "text")
        XCTAssertFalse(parsed.memoryEnabled)
        XCTAssertTrue(parsed.userProfileEnabled)
        XCTAssertTrue(parsed.memoryWriteApproval)
    }

    func testOperatorConfigFailsClosedToDocumentedDefaults() {
        let parsed = GatewayOperatorConfig(.object([
            "agent": .object(["max_turns": .number(0),
                              "image_input_mode": .string("invented")]),
        ]))
        XCTAssertEqual(parsed.maxTurns, 1)
        XCTAssertEqual(parsed.imageInputMode, "auto")
        XCTAssertTrue(parsed.memoryEnabled)
        XCTAssertTrue(parsed.userProfileEnabled)
        XCTAssertFalse(parsed.memoryWriteApproval)
    }

    func testModelGatewayDetachScrubsOnlyOwningSource() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        let primary = model.modelPicker(for: "default")
        let remote = model.modelPicker(for: "homelab::default")
        primary.pendingConfirmation = PendingModelConfirmation(
            provider: "primary-provider", model: "primary-model", message: "primary")
        remote.pendingConfirmation = PendingModelConfirmation(
            provider: "remote-provider", model: "remote-model", message: "remote")

        model.dropModelScope(gatewayID: "homelab")

        XCTAssertTrue(model.modelPicker(for: "default") === primary)
        XCTAssertFalse(model.modelPicker(for: "homelab::default") === remote)
        XCTAssertEqual(primary.pendingConfirmation?.provider, "primary-provider")
        XCTAssertNil(remote.pendingConfirmation)
        XCTAssertFalse(remote.hasLoaded)
        XCTAssertNil(remote.loadError)
        XCTAssertNil(remote.busyRow)
    }

    func testRoutineGatewayDetachPreservesOtherGatewayRows() {
        let model = AppModel()
        let primary = routine(id: "primary-job", botID: "default")
        let remoteID = GatewayRoutineRoute(gatewayID: "homelab", jobID: "remote-job").qualifiedID
        let remote = routine(id: remoteID, botID: "homelab::default")
        let orphanedCacheRow = routine(id: "stale-cache", botID: "homelab::researcher")
        model.routines = [primary, remote, orphanedCacheRow]
        FeedsRuntime.shared.routineTargets[primary.id] = RoutineTarget(
            route: GatewayRoutineRoute(gatewayID: "primary", jobID: "primary-job"),
            bot: GatewayBotRoute(gatewayID: "primary", profile: "default"), profile: nil)
        FeedsRuntime.shared.routineTargets[remote.id] = RoutineTarget(
            route: GatewayRoutineRoute(gatewayID: "homelab", jobID: "remote-job"),
            bot: GatewayBotRoute(gatewayID: "homelab", profile: "default"), profile: nil)
        CronDetailRuntime.shared.detail[primary.id] = CronJobDetail(["id": "primary-job"])
        CronDetailRuntime.shared.detail[remote.id] = CronJobDetail(["id": "remote-job"])
        CronDetailRuntime.shared.deliveryTargets["primary"] = [CronDeliveryTarget(["id": "local"])]
        CronDetailRuntime.shared.deliveryTargets["homelab"] = [CronDeliveryTarget(["id": "telegram"])]
        CronDetailRuntime.shared.restSupported["primary"] = true
        CronDetailRuntime.shared.restSupported["homelab"] = true

        model.dropRoutineScope(gatewayID: "homelab")

        XCTAssertEqual(model.routines, [primary])
        XCTAssertNotNil(FeedsRuntime.shared.routineTargets[primary.id])
        XCTAssertNil(FeedsRuntime.shared.routineTargets[remote.id])
        XCTAssertNotNil(CronDetailRuntime.shared.detail[primary.id])
        XCTAssertNil(CronDetailRuntime.shared.detail[remote.id])
        XCTAssertNotNil(CronDetailRuntime.shared.deliveryTargets["primary"])
        XCTAssertNil(CronDetailRuntime.shared.deliveryTargets["homelab"])
        XCTAssertEqual(CronDetailRuntime.shared.restSupported["primary"], true)
        XCTAssertNil(CronDetailRuntime.shared.restSupported["homelab"])
    }

    func testUnreadWatermarksKeepCollidingProfilesInSeparateGatewayScopes() {
        let suite = "talaria-unread-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UnreadWatermarkStore(defaults: defaults)
        let primary = URL(string: "https://primary.example")!
        let homelab = URL(string: "https://homelab.example")!

        XCTAssertTrue(store.ingest(["default": 100], openBot: nil, scope: primary).isEmpty)
        XCTAssertTrue(store.ingest(["default": 500], openBot: nil, scope: homelab).isEmpty)
        XCTAssertEqual(store.ingest(["default": 101], openBot: nil, scope: primary),
                       ["default"])
        XCTAssertEqual(store.ingest(["default": 501], openBot: nil, scope: homelab),
                       ["default"])
    }

    func testUnreadAcknowledgeNamesItsGatewayExplicitly() {
        let suite = "talaria-unread-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UnreadWatermarkStore(defaults: defaults)
        let primary = URL(string: "https://primary.example")!
        let homelab = URL(string: "https://homelab.example")!
        _ = store.ingest(["default": 100], openBot: nil, scope: primary)
        _ = store.ingest(["default": 100], openBot: nil, scope: homelab)

        store.acknowledge("default", scope: homelab)

        XCTAssertEqual(store.ingest(["default": 200], openBot: nil, scope: primary),
                       ["default"])
        XCTAssertTrue(store.ingest(["default": 200], openBot: nil, scope: homelab).isEmpty)
    }

    func testRemoteUnreadCannotBadgeOrClearCollidingPrimaryBot() {
        let model = AppModel()
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        model.bots = [.unlisted(id: "default")]
        let remote = GatewayBotRoute(gatewayID: "homelab", profile: "default")

        model.recordUnread(for: remote.qualifiedID)

        XCTAssertEqual(model.bots[0].unread, 0)
        XCTAssertEqual(MultiGatewayRuntime.shared.routedUnread[remote], 1)
        XCTAssertEqual(model.totalRosterUnread, 1)

        model.recordUnread(for: "default")
        model.clearUnread(for: remote.qualifiedID)

        XCTAssertEqual(model.bots[0].unread, 1)
        XCTAssertNil(MultiGatewayRuntime.shared.routedUnread[remote])
    }

    func testRemoteCompletionBadgesOnlyItsQualifiedBot() {
        let model = AppModel()
        model.mode = .live
        model.bots = [.unlisted(id: "default")]
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        let route = GatewaySessionRoute(gatewayID: "homelab", sessionID: "deadbeef")
        runtime.routedSessionToBot[route] = "homelab::default"
        let remote = GatewayBotRoute(gatewayID: "homelab", profile: "default")

        model.handle(event: GatewayEvent(
            type: "message.complete", sessionID: "deadbeef",
            payload: .object(["status": .string("complete"), "text": .string("done")])),
            sourceGatewayID: "homelab")

        XCTAssertEqual(model.bots[0].unread, 0)
        XCTAssertEqual(MultiGatewayRuntime.shared.routedUnread[remote], 1)
    }

    func testOpeningRemoteChatClearsOnlyItsQualifiedUnread() {
        let model = AppModel()
        model.mode = .demo
        model.bots = [.unlisted(id: "default")]
        model.bots[0].unread = 2
        let remote = GatewayBotRoute(gatewayID: "homelab", profile: "default")
        MultiGatewayRuntime.shared.routedUnread[remote] = 3

        model.openChat(botID: remote.qualifiedID)

        XCTAssertEqual(model.bots[0].unread, 2)
        XCTAssertNil(MultiGatewayRuntime.shared.routedUnread[remote])
    }

    func testUnreadCountSurvivesGatewayRoleTransitionsExactlyOnce() {
        let model = AppModel()
        let runtime = LiveRuntime.shared
        runtime.gatewayID = "primary"
        model.bots = [.unlisted(id: "default")]
        model.bots[0].unread = 3
        let route = GatewayBotRoute(gatewayID: "primary", profile: "default")

        model.preservePrimaryUnreadForGatewaySwitch()

        XCTAssertEqual(MultiGatewayRuntime.shared.routedUnread[route], 3)
        model.bots = []
        XCTAssertEqual(model.takeRoutedUnreadForPrimary(profile: "default"), 3)
        XCTAssertNil(MultiGatewayRuntime.shared.routedUnread[route])
        XCTAssertEqual(model.takeRoutedUnreadForPrimary(profile: "default"), 0)
    }

    func testQualifiedRemoteMentionSpeakerExcludesOnlyItself() {
        let primary = Bot.unlisted(id: "default")
        let remote = Bot(id: "homelab::default", job: "", shape: .circle, hue: .teal,
                         handleOverride: "default-homelab",
                         remoteSource: BotSource(profile: "default", gatewayID: "homelab",
                                                 connectionLabel: "Homelab"))

        let result = MentionResolver.resolve("@default check", roster: [primary, remote],
                                             speaking: "homelab::default")

        XCTAssertEqual(result.bots.map(\.id), ["default"])
    }

    func testForeignMentionIdentifiesExactSourceWithoutClientDelivery() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        let remote = Bot(id: "homelab::researcher", job: "", shape: .circle, hue: .teal,
                         remoteSource: BotSource(profile: "researcher", gatewayID: "homelab",
                                                 connectionLabel: "Homelab"))
        let draft = MentionMiddleware.route("@researcher investigate", roster: [remote],
                                            speaking: "default")

        XCTAssertEqual(draft.recipients.map(\.id), ["homelab::researcher"])
        XCTAssertTrue(draft.unreachable.isEmpty)
        XCTAssertTrue(draft.text.contains(
            "identity{handle=@researcher;profile=researcher}"))
        XCTAssertFalse(draft.text.contains("Homelab"),
                       "free-form device labels never enter model input")
        XCTAssertTrue(draft.text.contains("message_agent"))
        XCTAssertFalse(draft.text.contains("Talaria is delivering"))
        XCTAssertFalse(draft.text.contains("hermes -p"))
        XCTAssertFalse(draft.text.contains("prompt.submit"))
        XCTAssertEqual(model.a2aEndpoint(for: remote)?.route,
                       GatewayBotRoute(gatewayID: "homelab", profile: "researcher"))
    }

    func testAgentInboxHeaderControlsUsePhoneMinimumHitTarget() {
        XCTAssertEqual(AgentInboxLayoutPolicy.minimumControlSize, 44)
    }

    func testA2AProductionSourceHasNoRecipientPromptTransport() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/TalariaUI/AppModelLive+A2A.swift"),
            encoding: .utf8)
        for forbidden in [
            "deliverHandoff", "dispatchHandoff", "submitHandoff",
            "rpc(\"prompt.submit\"", "static func attributed(",
        ] {
            XCTAssertFalse(source.contains(forbidden),
                           "A2A production source restored recipient transport: \(forbidden)")
        }
    }

    func testRemoteDefaultEndpointKeepsRouteHandleAndBareAttributionHandleDistinct() {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "primary"
        let remote = Bot(id: "homelab::default", job: "", shape: .circle, hue: .teal,
                         handleOverride: "default-homelab",
                         remoteSource: BotSource(profile: "default", gatewayID: "homelab",
                                                 connectionLabel: "Homelab"))

        let endpoint = model.a2aEndpoint(for: remote)

        XCTAssertEqual(endpoint?.handle, "default-homelab")
        XCTAssertEqual(endpoint?.attributionHandle, "hermes")
        XCTAssertEqual(endpoint?.route,
                       GatewayBotRoute(gatewayID: "homelab", profile: "default"))
    }

    func testAttemptDeliveryKeysIsolateEqualProfilesBodiesAndSessions() {
        let body = "same body"
        let attempt = UUID()
        let primary = GatewayBotRoute(gatewayID: "primary", profile: "default")
        let remote = GatewayBotRoute(gatewayID: "homelab", profile: "default")

        let primaryKey = AppModel.deliveryKey(route: primary, body: body, attemptID: attempt)
        let remoteKey = AppModel.deliveryKey(route: remote, body: body, attemptID: attempt)
        let repeatKey = AppModel.deliveryKey(route: primary, body: body, attemptID: UUID())

        XCTAssertEqual(Set([primaryKey, remoteKey, repeatKey]).count, 3)
    }

    func testOptimisticDeliveryLookupUsesAttemptUUIDBeforeEqualBodyFallback() {
        let model = AppModel()
        let route = GatewayBotRoute(gatewayID: "primary", profile: "default")
        let firstID = UUID()
        let secondID = UUID()
        let firstKey = AppModel.deliveryKey(route: route, body: "same", attemptID: firstID)
        let secondKey = AppModel.deliveryKey(route: route, body: "same", attemptID: secondID)
        A2ARuntime.shared.deliveries[firstKey] = A2ADelivery(
            to: "default", route: route, attemptID: firstID,
            bodyHash: AppModel.stableHash("same"), queuedBehindRun: false,
            state: .replied, at: Date(timeIntervalSince1970: 1))
        A2ARuntime.shared.deliveries[secondKey] = A2ADelivery(
            to: "default", route: route, attemptID: secondID,
            bodyHash: AppModel.stableHash("same"), queuedBehindRun: true,
            state: .waiting, at: Date(timeIntervalSince1970: 2))
        let firstRow = A2AMessage(id: firstID, fromBotID: "ops", toBotID: "default",
                                  time: "now", text: "same")

        XCTAssertEqual(model.delivery(for: firstRow)?.state, .replied)
        XCTAssertEqual(model.delivery(for: firstRow)?.attemptID, firstID)
    }

    func testA2AScopeResetCancelsOnlyOwningGateway() {
        let runtime = A2ARuntime.shared
        let primary = GatewayBotRoute(gatewayID: "primary", profile: "default")
        let remote = GatewayBotRoute(gatewayID: "homelab", profile: "default")
        let primaryKey = AppModel.deliveryKey(route: primary, body: "same", attemptID: UUID())
        let remoteKey = AppModel.deliveryKey(route: remote, body: "same", attemptID: UUID())
        let primaryTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        let remoteTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        runtime.watchers[primaryKey] = primaryTask
        runtime.watchers[remoteKey] = remoteTask
        runtime.watcherScopes[primaryKey] = "primary"
        runtime.watcherScopes[remoteKey] = "homelab"
        runtime.deliveries[primaryKey] = A2ADelivery(
            to: "default", route: primary, queuedBehindRun: false,
            state: .waiting, at: Date())
        runtime.deliveries[remoteKey] = A2ADelivery(
            to: "homelab::default", route: remote, queuedBehindRun: false,
            state: .waiting, at: Date())

        runtime.reset(gatewayID: "homelab")

        XCTAssertFalse(primaryTask.isCancelled)
        XCTAssertTrue(remoteTask.isCancelled)
        XCTAssertNotNil(runtime.deliveries[primaryKey])
        XCTAssertNil(runtime.deliveries[remoteKey])
        primaryTask.cancel()
    }

    func testSecondaryProfileRenameMigratesA2ASenderRecipientAndWatchOwnership() {
        let runtime = A2ARuntime.shared
        runtime.reset()
        defer { runtime.reset() }

        let source = GatewayBotRoute(gatewayID: "homelab", profile: "worker")
        let destination = GatewayBotRoute(gatewayID: "homelab", profile: "renamed")
        let primary = GatewayBotRoute(gatewayID: "primary", profile: "ops")
        let sibling = GatewayBotRoute(gatewayID: "homelab", profile: "sibling")
        let sourceEndpoint = A2AEndpoint(
            rosterID: source.qualifiedID, route: source,
            displayTitle: "Worker", handle: "worker",
            attributionHandle: "worker", connectionLabel: "Homelab")
        let primaryEndpoint = A2AEndpoint(
            rosterID: "ops", route: primary,
            displayTitle: "Ops", handle: "ops",
            attributionHandle: "ops", connectionLabel: "Primary")
        let siblingEndpoint = A2AEndpoint(
            rosterID: sibling.qualifiedID, route: sibling,
            displayTitle: "Sibling", handle: "sibling",
            attributionHandle: "sibling", connectionLabel: "Homelab")

        let incomingID = UUID()
        let incomingKey = AppModel.deliveryKey(route: source, body: "in", attemptID: incomingID)
        runtime.deliveries[incomingKey] = A2ADelivery(
            to: source.qualifiedID, route: source, senderRoute: primary,
            senderRosterID: "ops", attemptID: incomingID,
            bodyHash: AppModel.stableHash("in"), queuedBehindRun: false,
            state: .waiting, at: Date())
        let outgoingID = UUID()
        let outgoingKey = AppModel.deliveryKey(route: sibling, body: "out", attemptID: outgoingID)
        runtime.deliveries[outgoingKey] = A2ADelivery(
            to: sibling.qualifiedID, route: sibling, senderRoute: source,
            senderRosterID: source.qualifiedID, attemptID: outgoingID,
            bodyHash: AppModel.stableHash("out"), queuedBehindRun: false,
            state: .waiting, at: Date())
        let siblingID = UUID()
        let siblingKey = AppModel.deliveryKey(route: sibling, body: "sibling", attemptID: siblingID)
        runtime.deliveries[siblingKey] = A2ADelivery(
            to: sibling.qualifiedID, route: sibling, senderRoute: primary,
            senderRosterID: "ops", attemptID: siblingID,
            bodyHash: AppModel.stableHash("sibling"), queuedBehindRun: false,
            state: .waiting, at: Date())

        let incomingWatchGeneration = installLegacyWatcher(runtime,
            key: incomingKey, target: sourceEndpoint, sender: primaryEndpoint)
        let outgoingWatchGeneration = installLegacyWatcher(runtime,
            key: outgoingKey, target: siblingEndpoint, sender: sourceEndpoint)
        runtime.watchers[incomingKey] = Task { try? await Task.sleep(for: .seconds(60)) }
        runtime.watchers[outgoingKey] = Task { try? await Task.sleep(for: .seconds(60)) }
        let oldGeneration = runtime.routeGeneration(for: source)

        runtime.retireProfileRoute(source, sourceBotIDs: [source.qualifiedID],
                                   preserveForRename: true)
        XCTAssertEqual(runtime.watcherGeneration[incomingKey], incomingWatchGeneration)
        XCTAssertEqual(runtime.watcherRegistrations[incomingKey]?.paused, true)
        XCTAssertEqual(runtime.watcherGeneration[outgoingKey], outgoingWatchGeneration)
        XCTAssertEqual(runtime.watcherRegistrations[outgoingKey]?.paused, true)
        XCTAssertFalse(runtime.accepts(route: source, generation: oldGeneration))

        runtime.migrateProfileRoute(from: source, to: destination,
                                    sourceBotIDs: [source.qualifiedID],
                                    destinationBotID: destination.qualifiedID)

        XCTAssertEqual(runtime.deliveries[incomingKey]?.route, destination)
        XCTAssertEqual(runtime.deliveries[incomingKey]?.to, destination.qualifiedID)
        XCTAssertEqual(runtime.deliveries[outgoingKey]?.senderRoute, destination)
        XCTAssertEqual(runtime.deliveries[outgoingKey]?.senderRosterID,
                       destination.qualifiedID)
        XCTAssertEqual(runtime.deliveries[siblingKey]?.route, sibling)
        XCTAssertEqual(runtime.deliveries[siblingKey]?.senderRoute, primary)
        let incomingOwner = runtime.watcherRegistrations[incomingKey]
        XCTAssertEqual(incomingOwner?.target.route, destination)
        XCTAssertEqual(incomingOwner?.target.rosterID, destination.qualifiedID)
        let outgoingOwner = runtime.watcherRegistrations[outgoingKey]
        XCTAssertEqual(outgoingOwner?.sender.route, destination)
        XCTAssertEqual(outgoingOwner?.sender.rosterID, destination.qualifiedID)
        XCTAssertFalse(runtime.accepts(
            route: source, generation: runtime.routeGeneration(for: source)))
        XCTAssertTrue(runtime.accepts(
            route: destination, generation: runtime.routeGeneration(for: destination)))
    }

    func testSecondaryProfileDeleteRetiresA2AStateWithoutTouchingSibling() {
        let runtime = A2ARuntime.shared
        runtime.reset()
        defer { runtime.reset() }

        let source = GatewayBotRoute(gatewayID: "homelab", profile: "worker")
        let sibling = GatewayBotRoute(gatewayID: "homelab", profile: "sibling")
        let primary = GatewayBotRoute(gatewayID: "primary", profile: "ops")
        let sourceEndpoint = A2AEndpoint(
            rosterID: source.qualifiedID, route: source,
            displayTitle: "Worker", handle: "worker",
            attributionHandle: "worker", connectionLabel: "Homelab")
        let primaryEndpoint = A2AEndpoint(
            rosterID: "ops", route: primary,
            displayTitle: "Ops", handle: "ops",
            attributionHandle: "ops", connectionLabel: "Primary")
        let siblingEndpoint = A2AEndpoint(
            rosterID: sibling.qualifiedID, route: sibling,
            displayTitle: "Sibling", handle: "sibling",
            attributionHandle: "sibling", connectionLabel: "Homelab")
        let sourceID = UUID()
        let sourceKey = AppModel.deliveryKey(route: source, body: "delete", attemptID: sourceID)
        runtime.deliveries[sourceKey] = A2ADelivery(
            to: source.qualifiedID, route: source, senderRoute: primary,
            senderRosterID: "ops", attemptID: sourceID,
            bodyHash: AppModel.stableHash("delete"), queuedBehindRun: false,
            state: .waiting, at: Date())
        let siblingID = UUID()
        let siblingKey = AppModel.deliveryKey(route: sibling, body: "keep", attemptID: siblingID)
        runtime.deliveries[siblingKey] = A2ADelivery(
            to: sibling.qualifiedID, route: sibling, senderRoute: primary,
            senderRosterID: "ops", attemptID: siblingID,
            bodyHash: AppModel.stableHash("keep"), queuedBehindRun: false,
            state: .waiting, at: Date())
        let generation = installLegacyWatcher(runtime,
            key: sourceKey, target: sourceEndpoint, sender: primaryEndpoint)
        let siblingGeneration = installLegacyWatcher(runtime,
            key: siblingKey, target: siblingEndpoint, sender: primaryEndpoint)
        let sourceTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        let siblingTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        runtime.watchers[sourceKey] = sourceTask
        runtime.watchers[siblingKey] = siblingTask
        let oldGeneration = runtime.routeGeneration(for: source)
        runtime.retireProfileRoute(source, sourceBotIDs: [source.qualifiedID])

        XCTAssertTrue(sourceTask.isCancelled)
        XCTAssertFalse(siblingTask.isCancelled)
        XCTAssertNil(runtime.deliveries[sourceKey])
        XCTAssertNotNil(runtime.deliveries[siblingKey])
        XCTAssertNil(runtime.watcherRegistrations[sourceKey])
        XCTAssertNotNil(runtime.watcherRegistrations[siblingKey])
        XCTAssertFalse(runtime.accepts(route: source, generation: oldGeneration))
        XCTAssertFalse(runtime.accepts(
            route: source, generation: runtime.routeGeneration(for: source)))
        XCTAssertNotNil(runtime.watcherRegistrations[siblingKey])
        XCTAssertEqual(runtime.watcherGeneration[siblingKey], siblingGeneration)
        runtime.watchers[siblingKey]?.cancel()
        XCTAssertEqual(runtime.watcherGeneration[sourceKey], nil)
        XCTAssertEqual(generation, 1)
    }

    func testA2APreservedPrimaryRouteSurvivesGatewayReset() {
        let runtime = A2ARuntime.shared
        runtime.reset()
        defer { runtime.reset() }
        let route = GatewayBotRoute(gatewayID: "primary", profile: "default")
        let sender = A2AEndpoint(rosterID: "primary::ops", route: route,
                                 displayTitle: "Ops", handle: "ops",
                                 attributionHandle: "ops", connectionLabel: nil)
        let target = A2AEndpoint(rosterID: route.profile, route: route,
                                 displayTitle: "Default", handle: "default",
                                 attributionHandle: "default", connectionLabel: nil)
        let key = "preserved"
        let watchGeneration = installLegacyWatcher(
            runtime, key: key, target: target, sender: sender)
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        runtime.watchers[key] = task
        runtime.deliveries[key] = A2ADelivery(
            to: target.rosterID, route: route, senderRoute: route,
            senderRosterID: sender.rosterID, attemptID: UUID(),
            queuedBehindRun: true, state: .waiting, at: Date())
        runtime.retireProfileRoute(route, sourceBotIDs: [route.profile],
                                   preserveForRename: true)
        runtime.preserveRouteAcrossGatewayReset(route)
        runtime.reset(gatewayID: route.gatewayID)

        XCTAssertNotNil(runtime.deliveries[key])
        XCTAssertNotNil(runtime.watcherRegistrations[key])
        XCTAssertFalse(task.isCancelled)
        XCTAssertEqual(runtime.watcherGeneration[key], watchGeneration)
        XCTAssertEqual(runtime.watcherRegistrations[key]?.paused, true)
        task.cancel()
    }

    func testPrimaryRenameDropScopePreservesVisibleOptimisticAcceptedRow() {
        let model = AppModel()
        let runtime = A2ARuntime.shared
        runtime.reset()
        defer {
            runtime.reset()
            model.agentInbox.removeAll()
        }
        let route = GatewayBotRoute(gatewayID: "primary", profile: "default")
        let attempt = UUID()
        let key = AppModel.deliveryKey(route: route, body: "rename", attemptID: attempt)
        runtime.deliveries[key] = A2ADelivery(
            to: route.profile, route: route, senderRoute: route,
            senderRosterID: route.profile, attemptID: attempt,
            queuedBehindRun: false, state: .waiting, at: Date())
        runtime.optimisticRows[attempt] = route.gatewayID
        runtime.optimisticOwners[attempt] = A2AOptimisticOwner(
            target: route, targetRosterID: route.profile,
            sender: route, senderRosterID: route.profile)
        model.agentInbox = [A2AMessage(id: attempt, fromBotID: route.profile,
                                       toBotID: route.profile, time: "now",
                                       text: "accepted")]

        runtime.preserveRouteAcrossGatewayReset(route)
        model.dropA2AScope(gatewayID: route.gatewayID, wasPrimary: true)

        XCTAssertEqual(model.agentInbox.map(\.id), [attempt])
        XCTAssertNotNil(runtime.deliveries[key])
        XCTAssertEqual(runtime.optimisticRows[attempt], route.gatewayID)
    }

    func testCapturedPrimaryDisconnectScrubsBareScopeButPreservesRemote() {
        let model = AppModel()
        let primaryID = UUID()
        let remoteID = UUID()
        let untrackedReplyID = UUID()
        model.agentInbox = [
            A2AMessage(id: primaryID, fromBotID: "ops", toBotID: "default",
                       time: "now", text: "primary"),
            A2AMessage(id: remoteID, fromBotID: "ops", toBotID: "homelab::default",
                       time: "now", text: "remote"),
            A2AMessage(id: untrackedReplyID, fromBotID: "homelab::default",
                       toBotID: "default", time: "now", text: "reply"),
        ]
        FeedsRuntime.shared.inboxSessions = [
            primaryID: SessionRef(gatewayID: "primary", botID: "default", storedID: "same"),
            remoteID: SessionRef(gatewayID: "homelab", botID: "homelab::default",
                                 storedID: "same"),
        ]
        let primary = GatewayBotRoute(gatewayID: "primary", profile: "default")
        let remote = GatewayBotRoute(gatewayID: "homelab", profile: "default")
        A2ARuntime.shared.optimisticRows[untrackedReplyID] = "homelab"
        A2ARuntime.shared.optimisticOwners[untrackedReplyID] = A2AOptimisticOwner(
            target: remote, targetRosterID: remote.qualifiedID,
            sender: primary, senderRosterID: "default")
        defer { A2ARuntime.shared.reset() }
        // Reproduce the deliberate-disconnect ordering that previously lost
        // source identity before A2A teardown.
        LiveRuntime.shared.gatewayID = nil

        model.detachA2ARouter(departingGatewayID: "primary")

        XCTAssertEqual(model.agentInbox.map(\.id), [remoteID])
        XCTAssertNil(FeedsRuntime.shared.inboxSessions[primaryID])
        XCTAssertEqual(FeedsRuntime.shared.inboxSessions[remoteID]?.gatewayID, "homelab")
    }

    func testFederatedInboxMergePreservesUnscannedRemoteAndReplacesAnchoredOptimistic() {
        let primaryID = UUID()
        let remoteAttempt = UUID()
        let legacyRemoteID = UUID()
        let primary = A2AMessage(id: primaryID, fromBotID: "ops", toBotID: "default",
                                 time: "now", text: "primary old")
        let remote = A2AMessage(id: remoteAttempt, fromBotID: "ops",
                                toBotID: "homelab::default", time: "now", text: "remote")
        // Older persisted rows can have bare participants on both sides. The
        // source-qualified SessionRef, not the colliding ids, owns them.
        let legacyRemote = A2AMessage(id: legacyRemoteID, fromBotID: "ops",
                                      toBotID: "default", time: "now", text: "legacy remote")
        let refs = [
            primaryID: SessionRef(gatewayID: "primary", botID: "default", storedID: "same"),
            remoteAttempt: SessionRef(gatewayID: "homelab", botID: "homelab::default",
                                      storedID: "same"),
            legacyRemoteID: SessionRef(gatewayID: "homelab", botID: "default",
                                       storedID: "same"),
        ]
        let primaryServer = A2AMessage(id: UUID(), fromBotID: "ci", toBotID: "default",
                                       time: "now", text: "primary fresh")
        let primaryRef = SessionRef(gatewayID: "primary", botID: "default", storedID: "same")

        let first = A2AInboxMerge.merge(
            existing: [primary, remote, legacyRemote], existingRefs: refs,
            server: [(primaryServer, Date(), primaryRef)], successfulGateways: ["primary"],
            optimisticRows: [remoteAttempt: "homelab"], primaryGatewayID: "primary", limit: 80)

        XCTAssertEqual(Set(first.messages.map(\.id)),
                       [remoteAttempt, legacyRemoteID, primaryServer.id])
        XCTAssertEqual(first.refs[remoteAttempt]?.gatewayID, "homelab")
        XCTAssertEqual(first.refs[legacyRemoteID]?.gatewayID, "homelab")

        let remoteServer = A2AMessage(id: remoteAttempt, fromBotID: "ops",
                                      toBotID: "homelab::default", time: "now", text: "remote")
        let remoteRef = SessionRef(gatewayID: "homelab", botID: "homelab::default",
                                   storedID: "same")
        let second = A2AInboxMerge.merge(
            existing: first.messages, existingRefs: first.refs,
            server: [(remoteServer, Date(), remoteRef)], successfulGateways: ["homelab"],
            optimisticRows: [remoteAttempt: "homelab"], primaryGatewayID: "primary", limit: 80)

        XCTAssertEqual(second.messages.filter { $0.id == remoteAttempt }.count, 1)
        XCTAssertEqual(second.refs[remoteAttempt]?.gatewayID, "homelab")
        XCTAssertTrue(second.settled.contains(remoteAttempt))
    }

    func testSessionRefReopensItsCapturedGatewayAcrossPrimaryRoleChanges() {
        let ref = SessionRef(gatewayID: "homelab", botID: "default", storedID: "same")

        XCTAssertEqual(ref.rosterID(activeGatewayID: "primary"), "homelab::default")
        XCTAssertEqual(ref.rosterID(activeGatewayID: "homelab"), "default")
        XCTAssertNil(SessionRef(gatewayID: "", botID: "default", storedID: "same")
            .rosterID(activeGatewayID: "primary"))
    }

    func testInboxParserClearsAttributionAfterOrdinaryUserTurn() {
        let rows: [JSONValue] = [
            .object(["role": .string("user"),
                     "content": .string("Message from 🤖 Ops (@ops): first")]),
            .object(["role": .string("user"),
                     "content": .string("ordinary user turn")]),
            .object(["role": .string("assistant"),
                     "content": .string("ordinary answer")]),
        ]

        let parsed = AppModel.inboxMessages(in: rows, owner: "worker")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.0.fromBotID, "ops")
        XCTAssertEqual(parsed.first?.0.text, "first")
    }

    func testInboxParserClearsAttributionAfterEmptyUserRow() {
        let rows: [JSONValue] = [
            .object(["role": .string("user"),
                     "content": .string("Message from 🤖 Ops (@ops): first")]),
            .object(["role": .string("user"), "content": .string(" ")]),
            .object(["role": .string("assistant"),
                     "content": .string("must not be attributed")]),
        ]

        let parsed = AppModel.inboxMessages(in: rows, owner: "worker")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.0.text, "first")
    }

    func testAcceptedUntrackedDeliveryKeepsPortableSenderOwnership() {
        let senderRoute = GatewayBotRoute(gatewayID: "primary", profile: "ops")
        let targetRoute = GatewayBotRoute(gatewayID: "homelab", profile: "worker")
        let sender = A2AEndpoint(rosterID: "ops", route: senderRoute,
                                 displayTitle: "Ops", handle: "ops",
                                 attributionHandle: "ops", connectionLabel: nil)
        let target = A2AEndpoint(rosterID: targetRoute.qualifiedID, route: targetRoute,
                                 displayTitle: "Worker", handle: "worker",
                                 attributionHandle: "worker", connectionLabel: nil)
        let attempt = UUID()
        let key = AppModel.deliveryKey(route: targetRoute, body: "accepted",
                                       attemptID: attempt)
        A2ARuntime.shared.deliveries[key] = A2ADelivery(
            to: target.rosterID, route: targetRoute,
            senderRoute: senderRoute, senderRosterID: sender.rosterID,
            attemptID: attempt, queuedBehindRun: true,
            state: .waiting, at: Date())
        defer { A2ARuntime.shared.reset() }

        XCTAssertEqual(A2ARuntime.shared.deliveries[key]?.senderRoute, senderRoute)
        XCTAssertEqual(A2ARuntime.shared.deliveries[key]?.state, .waiting)
        XCTAssertNil(A2ARuntime.shared.optimisticRows[attempt])
    }

    func testA2AParserKeepsMultiWordDisplayTitleAndExtractsHandleAnchor() {
        let attempt = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        let wire = "Message from 🤖 Operations Control (@ops) "
            + "[Talaria handoff attempt \(attempt.uuidString.lowercased())]: check status"

        XCTAssertEqual(AppModel.a2aSender(in: wire), "ops")
        XCTAssertEqual(AppModel.strippedA2A(wire), "check status")
        XCTAssertTrue(wire.contains("Operations Control"))
        XCTAssertNotNil(A2AWire.attemptID(in: wire))
    }

    func testA2AWireKeepsImmutableSenderRouteAcrossDuplicateHandles() {
        let primary = GatewayBotRoute(gatewayID: "primary", profile: "default")
        let remote = GatewayBotRoute(gatewayID: "homelab", profile: "default")
        let primaryWire = legacyAttributedRow(
            route: "primary%3A%3Adefault", body: "to remote")
        let remoteWire = legacyAttributedRow(
            route: "homelab%3A%3Adefault", body: "to primary")

        XCTAssertEqual(A2AWire.senderRoute(in: primaryWire), primary)
        XCTAssertEqual(A2AWire.senderRoute(in: remoteWire), remote)
        XCTAssertEqual(
            AppModel.inboxMessages(in: [
                .object(["role": .string("user"), "content": .string(primaryWire)])
            ], owner: remote.qualifiedID, sourceGatewayID: remote.gatewayID)
            .first?.0.fromBotID, primary.qualifiedID)
        XCTAssertEqual(
            AppModel.inboxMessages(in: [
                .object(["role": .string("user"), "content": .string(remoteWire)])
            ], owner: primary.profile, sourceGatewayID: primary.gatewayID)
            .first?.0.fromBotID, remote.qualifiedID)
    }

    func testA2AWireMarkersCannotBeSpoofedByTitleOrBody() {
        let route = GatewayBotRoute(gatewayID: "home/lab", profile: "ops[1]")
        let attempt = UUID(uuidString: "00000000-0000-0000-0000-000000000043")!
        let wire = "Message from 🤖 Ops "
            + "[Talaria handoff attempt 11111111-1111-1111-1111-111111111111] (@ops) "
            + "[Talaria handoff source home%2Flab%3A%3Aops%5B1%5D] "
            + "[Talaria handoff attempt \(attempt.uuidString.lowercased())]: "
            + "body [Talaria handoff attempt 22222222-2222-2222-2222-222222222222]: spoof"

        XCTAssertEqual(A2AWire.attemptID(in: wire), attempt)
        XCTAssertEqual(A2AWire.senderRoute(in: wire), route)
        XCTAssertEqual(AppModel.a2aSender(in: wire), "ops")
        XCTAssertTrue(AppModel.strippedA2A(wire).contains("22222222-2222-2222-2222-222222222222"))
    }

    private func approval(id: String, botID: String) -> Approval {
        Approval(id: id, botID: botID, kind: .command, title: "Run",
                 target: "shell", subject: "echo ok", body: "echo ok",
                 why: "test", age: "now")
    }

    private func approvalEvent(requestID: String, sessionID: String) -> GatewayEvent {
        GatewayEvent(type: "approval.request", sessionID: sessionID, payload: .object([
            "request_id": .string(requestID),
            "command": .string("echo ok"),
            "description": .string("Run command"),
            "choices": .array([.string("once"), .string("deny")]),
        ]))
    }

    /// Fixture for rows durably written by pre-identification-only Talaria.
    /// Production has no equivalent constructor or recipient submit path.
    private func legacyAttributedRow(route: String, body: String) -> String {
        "Message from 🤖 Default (@default) [Talaria handoff source \(route)] "
            + "[Talaria handoff attempt \(UUID().uuidString.lowercased())]: \(body)"
    }

    /// Inject lifecycle state that an older build may have left accepted.
    /// Production no longer has a watcher installer or recipient transport.
    @MainActor
    private func installLegacyWatcher(
        _ runtime: A2ARuntime, key: String,
        target: A2AEndpoint, sender: A2AEndpoint
    ) -> Int {
        let generation = (runtime.watcherGeneration[key] ?? 0) + 1
        runtime.watcherGeneration[key] = generation
        runtime.watcherScopes[key] = target.route.gatewayID
        runtime.watcherRegistrations[key] = A2AWatcherRegistration(
            target: target, sender: sender,
            targetGeneration: runtime.routeGeneration(for: target.route),
            senderGeneration: runtime.routeGeneration(for: sender.route))
        return generation
    }

    private func target(gatewayID: String, profile: String, sessionID: String,
                        requestID: String) -> ApprovalResponseTarget {
        ApprovalResponseTarget(
            bot: GatewayBotRoute(gatewayID: gatewayID, profile: profile),
            session: GatewaySessionRoute(gatewayID: gatewayID, sessionID: sessionID),
            requestID: requestID)
    }

    private func routine(id: String, botID: String) -> Routine {
        Routine(id: id, botID: botID, name: "Backup", schedule: "every 1h",
                next: "in 1h", last: "", isOn: true)
    }

    func testPrimaryForeverChatPersistsModelGloballyAndMoAStaysSession() {
        let model = AppModel()
        XCTAssertTrue(model.shouldPersistModelAsDefault(botID: "default", provider: "anthropic"))
        XCTAssertTrue(model.shouldPersistModelAsDefault(botID: "seek", provider: "anthropic"))
        XCTAssertTrue(model.shouldPersistModelAsDefault(botID: "homelab::default", provider: "anthropic"))
        XCTAssertFalse(model.shouldPersistModelAsDefault(botID: "default", provider: "moa"))
        XCTAssertEqual(
            GatewayClient.modelSwitchValue(model: "claude-sonnet-4.6", provider: "anthropic",
                                           persistAsDefault: true),
            "claude-sonnet-4.6 --provider anthropic --global"
        )
        XCTAssertEqual(
            GatewayClient.modelSwitchValue(model: "ensemble", provider: "moa",
                                           persistAsDefault: false),
            "ensemble --provider moa --session"
        )
    }

    func testRosterCompanionCopyMatchesBotModePlugin() {
        XCTAssertEqual(CopyPack.rosterNewChat(.soft), "New chat with this agent")
        XCTAssertEqual(CopyPack.rosterSessions(.soft), "Sessions")
        XCTAssertEqual(CopyPack.rosterDelete(.soft), "Delete")
        XCTAssertEqual(CopyPack.rosterPin(.soft), "Pin to top")
        XCTAssertEqual(CopyPack.soft.toastScratchFailed(.soft), "Couldn’t start a new chat")
    }
}
#endif
