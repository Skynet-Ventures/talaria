#if canImport(XCTest)
import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class TranscriptToolHydrationTests: XCTestCase {
    @MainActor
    func testRawHistoryPairsTypedCallsAndResultsInTranscriptOrder() throws {
        let payload: JSONValue = ["messages": [
            ["id": 1, "role": "user", "content": "Inspect"],
            ["id": 2, "role": "assistant", "content": "", "tool_calls": [
                ["id": "call-a", "function": ["name": "terminal",
                    "arguments": "{\"command\":\"alpha\"}"]],
                ["id": "call-b", "function": ["name": "terminal",
                    "arguments": "{\"command\":\"bravo\"}"]],
            ]],
            ["id": 3, "role": "tool", "tool_call_id": "call-a",
             "tool_name": "terminal", "content": "{\"stdout\":\"A\"}"],
            ["id": 4, "role": "tool", "tool_call_id": "call-b",
             "tool_name": "terminal", "content": "{\"stdout\":\"B\"}"],
            ["id": 5, "role": "assistant", "content": "Done."],
        ]]

        let messages = AppModel.chatMessages(fromTranscript: payload)
        XCTAssertEqual(messages.map(\.text), ["Inspect", "Done."])
        let calls = try XCTUnwrap(messages.last?.toolCalls)
        XCTAssertEqual(calls.map(\.gatewayToolID), ["call-a", "call-b"])
        XCTAssertEqual(Set(calls.map(\.id)).count, 2)
        XCTAssertEqual(calls[0].arguments?.json?["command"]?.stringValue, "alpha")
        XCTAssertEqual(calls[1].result?.json?["stdout"]?.stringValue, "B")
        XCTAssertEqual(calls.map(\.state), [.done, .done])
    }

    @MainActor
    func testDisplayProjectionRetainsTruthfulCompletedToolWithoutInventedOutput() throws {
        let payload: JSONValue = ["messages": [
            ["role": "user", "text": "Find it", "row_id": 1],
            ["role": "tool", "name": "search_files", "context": "settings",
             "args": ["query": "settings"]],
            ["role": "assistant", "text": "Found it.", "row_id": 3],
        ]]

        let call = try XCTUnwrap(
            AppModel.chatMessages(fromTranscript: payload).last?.toolCalls.first)
        XCTAssertEqual(call.state, .done)
        XCTAssertEqual(call.provenance, .projection)
        XCTAssertNil(call.gatewayToolID)
        XCTAssertEqual(call.arguments?.json?["query"]?.stringValue, "settings")
        XCTAssertEqual(call.result?.kind, .unavailable)
    }

    @MainActor
    func testOnlyLatestUnmatchedParallelBatchCanHydrateAsRunning() throws {
        let payload: JSONValue = ["messages": [
            ["id": 10, "role": "assistant", "content": "", "tool_calls": [
                ["id": "old", "function": ["name": "read_file", "arguments": "{}"]],
            ]],
            ["id": 11, "role": "assistant", "content": "", "tool_calls": [
                ["id": "tail-a", "function": ["name": "terminal", "arguments": "{}"]],
                ["id": "tail-b", "function": ["name": "terminal", "arguments": "{}"]],
            ]],
        ]]

        let messages = AppModel.chatMessages(
            fromTranscript: payload, toolsMayBeRunning: true)
        let calls = messages.flatMap(\.toolCalls)
        XCTAssertEqual(calls.map(\.state), [.done, .running, .running])
        XCTAssertEqual(calls.last?.gatewayToolID, "tail-b")
        XCTAssertEqual(calls[0].result?.kind, .unavailable)
        XCTAssertNil(calls[1].result)
        XCTAssertNil(calls.last?.result)
    }

    @MainActor
    func testRawDatabaseRowIDNeverImpersonatesToolExecutionID() throws {
        let payload: JSONValue = ["messages": [
            ["id": 1, "role": "assistant", "content": "", "tool_calls": [
                ["id": "3", "function": ["name": "terminal", "arguments": "{}"]],
            ]],
            ["id": 3, "role": "tool", "tool_name": "terminal", "content": "orphan"],
            ["id": 4, "role": "assistant", "content": "Done."],
        ]]

        let calls = try XCTUnwrap(
            AppModel.chatMessages(fromTranscript: payload).last?.toolCalls)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].gatewayToolID, "3")
        XCTAssertEqual(calls[0].result?.kind, .unavailable)
        XCTAssertNil(calls[1].gatewayToolID)
        XCTAssertEqual(calls[1].result?.displayText, "orphan")
        XCTAssertNotEqual(calls[0].id, calls[1].id)
    }

    func testMalformedAndHostilePayloadWorkIsBounded() throws {
        let huge = String(repeating: "x", count: 100_000)
        let malformed = ToolPayloadCodec.arguments(from: .string("{\(huge)"))
        XCTAssertEqual(malformed?.kind, .malformed)
        XCTAssertLessThanOrEqual(malformed?.text?.count ?? .max,
                                 ToolPayloadCodec.maximumDiagnosticCharacters)

        var nested: JSONValue = .string("ok")
        for _ in 0..<40 { nested = .array([nested]) }
        let rejected = ToolPayloadCodec.result(from: nested)
        XCTAssertEqual(rejected?.kind, .malformed)
    }

    @MainActor
    func testExplicitFailureEvidenceRejectsFalseNullAndEmptyValues() {
        for value: JSONValue in [.bool(false), .null, .string(""), .array([]), .object([:])] {
            XCTAssertFalse(AppModel.toolFailed(
                payload: ["error": value], summary: "error in harmless output",
                resultText: "failed is just prose"))
        }
        XCTAssertTrue(AppModel.toolFailed(
            payload: ["error": "permission denied"], summary: nil, resultText: nil))
        XCTAssertTrue(AppModel.toolFailed(
            payload: ["result": ["is_error": true]], summary: nil, resultText: nil))
    }

    func testOversizedLiveToolIdentityAndNameAreRejectedBeforeRetention() {
        let oversizedID = String(repeating: "i", count: 10_000)
        let oversizedName = String(repeating: "n", count: 10_000)
        let start = ToolStartPayload([
            "tool_id": .string(oversizedID), "name": .string(oversizedName),
        ])
        XCTAssertTrue(start.toolID.isEmpty)
        XCTAssertTrue(start.name.isEmpty)
    }

    func testControlAndBidirectionalToolIdentitiesAreRejectedBeforeRetention() {
        for hostile in ["call\u{0001}id", "call\u{061C}id", "call\u{200E}id",
                        "call\u{202E}id", "call\u{2067}id"] {
            let start = ToolStartPayload([
                "tool_id": .string(hostile), "name": .string("terminal"),
            ])
            XCTAssertTrue(start.toolID.isEmpty)
        }
    }

    func testPresentationAdmissionIsScalarBoundedAndRemovesSpoofingControls() throws {
        let combining = "e" + String(repeating: "\u{0301}", count: 25_000)
        let payload = try XCTUnwrap(ToolPayloadCodec.result(from: .string(combining)))
        XCTAssertLessThanOrEqual(payload.displayText?.unicodeScalars.count ?? .max,
                                 ToolPayloadCodec.maximumResultCharacters)
        XCTAssertTrue(payload.isTruncated)
        XCTAssertTrue(payload.displayText?.hasSuffix("\n… [truncated]") == true)

        let hostile = "left\tcolumn\nline\u{0000}\u{0085}\u{202E}right"
        let sanitized = try XCTUnwrap(
            ToolPayloadCodec.directArguments(from: .string(hostile)))
        XCTAssertEqual(sanitized.displayText, "left\tcolumn\nlineright")
        XCTAssertTrue(sanitized.isTruncated,
                      "removed presentation controls remain observable as sanitization")
    }

    func testSingleAndExpandedCallsUseDynamicTypeStylesAndTwoCallGrouping() {
        let calls = [
            ToolCall(id: "one", name: "read_file", context: "a", state: .done),
            ToolCall(id: "two", name: "terminal", context: "b", state: .failed),
        ]
        XCTAssertTrue(ToolRunPresentationPolicy.shouldGroup(calls))
        XCTAssertFalse(ToolRunPresentationPolicy.shouldGroup(Array(calls.prefix(1))))
        XCTAssertEqual(ToolRunPresentationPolicy.summary(calls),
                       "2 tools · 1 completed · 1 failed")
        XCTAssertEqual(ToolRunPresentationPolicy.minimumInteractiveDimension, 44)
        XCTAssertEqual(ToolRunPresentationPolicy.summaryTextStyle, .subheadline)
        XCTAssertEqual(ToolRunPresentationPolicy.callNameTextStyle, .subheadline)
        XCTAssertEqual(ToolRunPresentationPolicy.callSubtitleTextStyle, .caption)
        XCTAssertEqual(ToolRunPresentationPolicy.callDurationTextStyle, .caption2)
        XCTAssertEqual(ToolRunPresentationPolicy.statusGlyphTextStyle, .caption)
        XCTAssertEqual(ToolRunPresentationPolicy.disclosureGlyphTextStyle, .caption2)
        XCTAssertEqual(ToolRunPresentationPolicy.detailHeadingTextStyle, .caption2)
        XCTAssertEqual(ToolRunPresentationPolicy.detailBodyTextStyle, .caption)
        XCTAssertEqual(ToolRunPresentationPolicy.copyGlyphTextStyle, .caption)
    }

    @MainActor
    func testIdlessLiveCompletionNeverPairsBySameName() throws {
        let model = AppModel()
        let botID = "exact-gateway::worker"
        let sessionID = "exact-session-\(UUID().uuidString)"
        let runtime = LiveRuntime.shared
        let oldGateway = runtime.gatewayID
        let oldMapping = runtime.sessionToBot[sessionID]
        defer {
            runtime.gatewayID = oldGateway
            runtime.sessionToBot[sessionID] = oldMapping
            ChatRuntime.shared.turnFloor[botID] = nil
            model.chats[botID] = nil
        }
        model.mode = .live
        runtime.gatewayID = "exact-gateway"
        runtime.sessionToBot[sessionID] = botID
        model.chat(for: botID).sessionID = sessionID
        model.routeToolEvent(GatewayEvent(
            type: "message.start", sessionID: sessionID, payload: nil))
        model.routeToolEvent(GatewayEvent(
            type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "one", "name": "terminal"]))
        model.routeToolEvent(GatewayEvent(
            type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "two", "name": "terminal"]))
        model.routeToolEvent(GatewayEvent(
            type: "tool.complete", sessionID: sessionID,
            payload: ["name": "terminal", "result": ["stdout": "orphan"]]))

        let calls = try XCTUnwrap(model.chats[botID]?.messages.last?.toolCalls)
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0].state, .running)
        XCTAssertEqual(calls[1].state, .running)
        XCTAssertNil(calls[2].gatewayToolID)
        XCTAssertEqual(calls[2].provenance, .unmatchedResult)
    }

    @MainActor
    func testExactResultSettlesOnlyItsCallInsideActiveTailBatch() throws {
        let payload: JSONValue = ["messages": [
            ["id": 1, "role": "assistant", "content": "", "tool_calls": [
                ["id": "old", "function": ["name": "terminal", "arguments": "{}"]],
            ]],
            ["id": 2, "role": "assistant", "content": "", "tool_calls": [
                ["id": "a", "function": ["name": "terminal", "arguments": "{}"]],
                ["id": "b", "function": ["name": "terminal", "arguments": "{}"]],
            ]],
            ["id": 3, "role": "tool", "tool_call_id": "a",
             "tool_name": "terminal", "content": "ok"],
        ]]
        let calls = AppModel.chatMessages(
            fromTranscript: payload, toolsMayBeRunning: true).flatMap(\.toolCalls)
        XCTAssertEqual(calls.map(\.state), [.done, .done, .running])
    }

    @MainActor
    func testRunningProjectionAlwaysReadsRawTailForHiddenToolCalls() async throws {
        let chat = ChatState()
        let resume: [JSONValue] = [
            ["role": "user", "text": "Inspect", "row_id": 1],
            ["role": "assistant", "text": "Still working", "row_id": 2],
        ]
        let raw: JSONValue = ["messages": [
            ["id": 1, "role": "user", "content": "Inspect"],
            ["id": 2, "role": "assistant", "content": "Still working"],
            ["id": 3, "role": "assistant", "content": "", "tool_calls": [
                ["id": "hidden", "function": ["name": "terminal", "arguments": "{}"]],
            ]],
        ]]
        var reads = 0
        try await AppModel.hydrateTranscript(
            chat: chat, resumeMessages: resume, clearWhenEmpty: true,
            toolsMayBeRunning: true,
            fallback: { reads += 1; return raw }, accepts: { true })
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(chat.messages.flatMap(\.toolCalls).first?.gatewayToolID, "hidden")
        XCTAssertEqual(chat.messages.flatMap(\.toolCalls).first?.state, .running)
    }

    @MainActor
    func testLiveOverlayCannotDowngradeStoredTypedResult() async throws {
        let live = ToolCall(id: "wire", name: "terminal", context: "pwd",
                            state: .running, gatewayToolID: "wire")
        let chat = ChatState(messages: [
            ChatMessage(author: .bot, text: "Done", toolCalls: [live], rowID: 4),
        ])
        let raw: [JSONValue] = [
            ["id": 2, "role": "assistant", "content": "", "tool_calls": [
                ["id": "wire", "function": ["name": "terminal",
                    "arguments": "{\"command\":\"pwd\"}"]],
            ]],
            ["id": 3, "role": "tool", "tool_call_id": "wire",
             "tool_name": "terminal", "content": "{\"cwd\":\"/tmp\"}"],
            ["id": 4, "role": "assistant", "content": "Done"],
        ]
        try await AppModel.hydrateTranscript(
            chat: chat, resumeMessages: raw, clearWhenEmpty: false,
            fallback: { nil }, accepts: { true })
        let merged = try XCTUnwrap(chat.messages.last?.toolCalls.first)
        XCTAssertEqual(merged.state, .running)
        XCTAssertEqual(merged.arguments?.json?["command"]?.stringValue, "pwd")
        XCTAssertEqual(merged.result?.json?["cwd"]?.stringValue, "/tmp")
        XCTAssertEqual(merged.provenance, .stored)
    }

    @MainActor
    func testToolSupplementPreservesProtectedTerminalFailure() async throws {
        let chat = ChatState(messages: [
            ChatMessage(author: .bot, text: "partial", failure: TurnFailure(
                message: "stream failed", recoverable: true)),
        ])
        let protected = try XCTUnwrap(chat.messages.first?.id)
        let key = ObjectIdentifier(chat)
        ChatRuntime.shared.retainedFailureRows[key] = [protected]
        defer { ChatRuntime.shared.retainedFailureRows[key] = nil }
        let resume: [JSONValue] = [
            ["role": "tool", "name": "terminal", "context": "pwd"],
            ["role": "assistant", "text": "Stored answer", "row_id": 4],
        ]
        let raw: JSONValue = ["messages": [
            ["id": 2, "role": "assistant", "content": "", "tool_calls": [
                ["id": "call", "function": ["name": "terminal", "arguments": "{}"]],
            ]],
            ["id": 3, "role": "tool", "tool_call_id": "call",
             "tool_name": "terminal", "content": "{\"cwd\":\"/tmp\"}"],
            ["id": 4, "role": "assistant", "content": "Stored answer"],
        ]]
        var reads = 0

        try await AppModel.hydrateTranscript(
            chat: chat, resumeMessages: resume, clearWhenEmpty: true,
            fallback: { reads += 1; return raw }, accepts: { true })

        XCTAssertEqual(reads, 1)
        XCTAssertTrue(chat.messages.contains(where: {
            $0.id == protected && $0.failure?.message == "stream failed"
        }))
        XCTAssertEqual(chat.messages.flatMap(\.toolCalls).first?.result?.json?["cwd"]?.stringValue,
                       "/tmp")
    }

    func testStoredTranscriptFetchEnforcesRowAndWireByteCaps() async throws {
        let url = try XCTUnwrap(URL(string: "https://history.example"))
        let client = GatewayClient(
            baseURL: url, credential: .sessionToken("history"),
            restExecutor: { request, responseLimit in
                XCTAssertEqual(responseLimit,
                               StoredTranscriptHydrationPayloadPolicy.maximumResponseBytes)
                let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
                XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "limit" })?.value,
                               String(StoredTranscriptHydrationPayloadPolicy.maximumRows))
                let data = Data("{\"messages\":[]}".utf8)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!
                return (data, response)
            })

        _ = try await client.latestSessionMessages(
            storedID: "stored", profile: "worker", limit: 50_000)
    }

    @MainActor
    func testSecondaryPoolReplacementInvalidatesTranscriptPublicationAuthority() async throws {
        let gatewayID = "secondary-history-\(UUID().uuidString)"
        let route = GatewayBotRoute(gatewayID: gatewayID, profile: "worker")
        let url = try XCTUnwrap(URL(string: "https://secondary.example"))
        let first = GatewayClient(baseURL: url, credential: .sessionToken("one"))
        let replacement = GatewayClient(baseURL: url, credential: .sessionToken("two"))
        let pool = GatewayClientPool { _, _ in first }
        await pool.adopt(first, for: gatewayID)
        let snapshot = try await pool.connectWithGeneration(
            gatewayID: gatewayID, baseURL: url, credential: .sessionToken("one"))

        let model = AppModel()
        model.mode = .live
        let runtime = LiveRuntime.shared
        let events = MultiGatewayRuntime.shared
        let oldGateway = runtime.gatewayID
        let oldGeneration = runtime.generation
        let oldEvents = events.routedEvents[gatewayID]
        let oldEventGeneration = events.routedEventGenerations[gatewayID]
        let pump = Task<Void, Never> {}
        defer {
            pump.cancel()
            runtime.gatewayID = oldGateway
            runtime.generation = oldGeneration
            events.routedEvents[gatewayID] = oldEvents
            events.routedEventGenerations[gatewayID] = oldEventGeneration
        }
        runtime.gatewayID = "primary-\(UUID().uuidString)"
        runtime.generation &+= 1
        events.routedEventGenerations[gatewayID] = 9
        events.routedEvents[gatewayID] = MultiGatewayRuntime.RoutedEvents(
            client: first, handlerID: UUID(), pump: pump, generation: 9)
        let authority = TranscriptHydrationSourceAuthority(
            route: route, client: first, liveGeneration: runtime.generation,
            wasPrimary: false, pooledSnapshot: snapshot,
            routedEventGeneration: 9, pool: pool)

        let before = await model.transcriptHydrationSourceIsCurrent(authority)
        XCTAssertTrue(before)
        await pool.adopt(replacement, for: gatewayID)
        let after = await model.transcriptHydrationSourceIsCurrent(authority)
        XCTAssertFalse(after)
        await pool.disconnectAll()
    }

    @MainActor
    func testSuspendedStoredSessionHydrationRejectsBindingTransition() async throws {
        let model = AppModel()
        model.mode = .live
        let runtime = LiveRuntime.shared
        let oldGateway = runtime.gatewayID
        defer { runtime.gatewayID = oldGateway }
        runtime.gatewayID = "stored-source"
        let botID = "worker"
        let route = GatewayBotRoute(gatewayID: "stored-source", profile: botID)
        let chat = ChatState(messages: [ChatMessage(author: .bot, text: "baseline")])
        chat.sessionID = "runtime-a"
        chat.storedSessionID = "stored-a"
        model.chats[botID] = chat
        let gate = StoredHydrationGate()

        XCTAssertTrue(model.storedSessionHydrationBindingIsCurrent(
            botID: botID, chat: chat, runtimeSessionID: "runtime-a",
            storedSessionID: "stored-a", route: route))
        XCTAssertFalse(model.storedSessionHydrationBindingIsCurrent(
            botID: botID, chat: chat, runtimeSessionID: "runtime-a",
            storedSessionID: "stored-b", route: route))
        XCTAssertFalse(model.storedSessionHydrationBindingIsCurrent(
            botID: botID, chat: chat, runtimeSessionID: "runtime-a",
            storedSessionID: "stored-a",
            route: GatewayBotRoute(gatewayID: "other", profile: botID)))

        let hydration = Task<Void, Error> { @MainActor in
            try await AppModel.hydrateTranscript(
                chat: chat, resumeMessages: [], clearWhenEmpty: true,
                fallback: { await gate.load() },
                accepts: {
                    model.storedSessionHydrationBindingIsCurrent(
                        botID: botID, chat: chat, runtimeSessionID: "runtime-a",
                        storedSessionID: "stored-a", route: route)
                })
        }
        await gate.waitUntilEntered()
        chat.sessionID = "runtime-b"
        chat.messages = [ChatMessage(author: .bot, text: "new binding wins")]
        await gate.release(["messages": [
            ["role": "assistant", "text": "stale stored transcript"],
        ]])

        do {
            try await hydration.value
            XCTFail("binding transition unexpectedly accepted stale hydration")
        } catch is CancellationError {
            // Expected: exact ChatState remains, but its runtime binding changed.
        }
        XCTAssertEqual(chat.messages.map(\.text), ["new binding wins"])

        let replacement = ChatState()
        replacement.sessionID = "runtime-a"
        replacement.storedSessionID = "stored-a"
        model.chats[botID] = replacement
        XCTAssertFalse(model.storedSessionHydrationBindingIsCurrent(
            botID: botID, chat: chat, runtimeSessionID: "runtime-a",
            storedSessionID: "stored-a", route: route))
    }
}

private actor StoredHydrationGate {
    private var entered = false
    private var payload: JSONValue?
    private var continuation: CheckedContinuation<Void, Never>?

    func load() async -> JSONValue? {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        return payload
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func release(_ value: JSONValue?) {
        payload = value
        continuation?.resume()
        continuation = nil
    }
}
#endif
