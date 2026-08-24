import XCTest
@testable import TalariaKit
@testable import TalariaUI

@MainActor
final class ToolWebSearchRenderingTests: XCTestCase {
    func testExactNameAliasesAndWrappersAdmitOnlyExplicitRows() throws {
        for key in ["web", "results", "search_results", "sources", "items",
                    "organic_results", "matches", "documents"] {
            let admission = ToolWebSearchCodec.admit(
                toolName: "web_search", arguments: ["query": "swift"],
                result: .object([key: .array([[
                    "title": "Swift", "url": "https://swift.org/docs",
                    "snippet": "Language docs",
                ]])]))
            XCTAssertEqual(try XCTUnwrap(admission.output).hits.first?.destinationHost,
                           "swift.org", key)
        }
        let wrapped = ToolWebSearchCodec.admit(
            toolName: "web_search", arguments: ["search_term": "bounded"],
            result: "{\"payload\":{\"data\":{\"results\":[{\"name\":\"Result\",\"href\":\"https://example.com/a\",\"description\":\"literal\"}]}}}")
        XCTAssertEqual(wrapped.output?.query, "bounded")
        XCTAssertEqual(wrapped.output?.hits.first?.title, "Result")
        XCTAssertNil(ToolWebSearchCodec.admit(
            toolName: "web_search", arguments: nil,
            result: "Visit https://example.com").output)
    }

    func testNameAdmissionIsExactAndOtherSearchToolsStayGeneric() {
        let result: JSONValue = ["results": [[
            "title": "x", "url": "https://example.com",
        ]]]
        XCTAssertTrue(ToolWebSearchCodec.isWebSearchTool("web_search"))
        for name in ["WEB_SEARCH", "Web_Search", "search", "search_web", "browser.search"] {
            XCTAssertFalse(ToolWebSearchCodec.isWebSearchTool(name))
            XCTAssertNil(ToolWebSearchCodec.admit(
                toolName: name, arguments: nil, result: result).output)
            XCTAssertNil(ToolCompletePayload([
                "name": .string(name), "result": result,
            ]).deferredWebSearchOutput)
        }
    }

    func testURLDeceptionAndUnsafeDestinationsAreRejected() throws {
        let output = try XCTUnwrap(ToolWebSearchCodec.admit(
            toolName: "web_search", arguments: nil,
            result: ["results": [
                ["title": "Trusted Bank", "url": "https://evil.example/login"],
                ["title": "userinfo", "url": "https://trusted.example@evil.example/x"],
                ["title": "script", "url": "javascript:alert(1)"],
                ["title": "data", "url": "data:text/plain,x"],
                ["title": "ftp", "url": "ftp://example.com/x"],
                ["title": "opaque", "url": "https:example.com"],
            ]]).output)
        XCTAssertEqual(output.hits.first?.destinationHost, "evil.example")
        XCTAssertTrue(WebSearchPresentationPolicy.accessibilityLabel(output.hits[0])
            .contains("Destination host, evil.example"))
        XCTAssertTrue(output.hits.dropFirst().allSatisfy { $0.url == nil })
        for url in ["https://example.com\\@evil.test", "https://example.com/%0aevil",
                    "https://exa\u{202E}mple.com"] {
            XCTAssertNil(ToolWebSearchCodec.admittedURL(url))
        }
    }

    func testBoundsControlsAndBidiAreSanitizedBeforePresentation() throws {
        let rows: [JSONValue] = (0..<100).map { index in
            ["title": .string("\u{001B}]0;spoof\u{0007}Title \(index)\u{202E}"),
             "url": .string("https://example.com/\(index)"),
             "snippet": .string(String(repeating: "s", count: 2_000))]
        }
        let output = try XCTUnwrap(ToolWebSearchCodec.candidate(
            arguments: ["query": .string("q\u{202E}")], result: .object(["results": .array(rows)])))
        XCTAssertEqual(output.hits.count, ToolWebSearchCodec.maximumHits)
        XCTAssertTrue(output.isTruncated)
        XCTAssertFalse(output.hits[0].title.contains("spoof"))
        XCTAssertFalse(output.hits[0].title.unicodeScalars.contains { $0.value == 0x202E })
        XCTAssertLessThanOrEqual(output.hits[0].snippet?.unicodeScalars.count ?? .max,
                                 ToolWebSearchCodec.maximumSnippetScalars)
    }

    func testContainerAndTraversalBudgetsFailClosed() {
        let huge = String(repeating: "x", count: ToolWebSearchCodec.maximumContainerScalars + 1)
        XCTAssertNil(ToolWebSearchCodec.candidate(arguments: nil, result: .string(huge)))
        var nested: JSONValue = ["results": [["title": "too deep"]]]
        for _ in 0..<(ToolWebSearchCodec.maximumTraversalDepth + 2) {
            nested = ["payload": nested]
        }
        let exhausted = ToolWebSearchCodec.candidate(arguments: nil, result: nested)
        XCTAssertEqual(exhausted?.state, .malformed)
        XCTAssertTrue(exhausted?.isTruncated == true)
        XCTAssertTrue(exhausted?.hits.isEmpty == true)
    }

    func testSnapshotReadmissionBoundsRowsAndUnsafeFields() throws {
        let rows = (0..<20).map { index in
            "{\"title\":\"row \(index)\",\"url\":\"javascript:alert(1)\",\"snippet\":\"ok\"}"
        }.joined(separator: ",")
        let data = "{\"state\":\"available\",\"hits\":[\(rows)]}".data(using: .utf8)!
        let output = try JSONDecoder().decode(ToolWebSearchOutput.self, from: data)
        XCTAssertEqual(output.hits.count, ToolWebSearchCodec.maximumHits)
        XCTAssertTrue(output.isTruncated)
        XCTAssertTrue(output.hits.allSatisfy { $0.url == nil })
    }

    func testCompletionBeforeStartPromotesBoundedNamelessCandidateAndCoalescesGenerating() throws {
        let model = AppModel()
        let botID = "web-order-\(UUID().uuidString)"
        let sessionID = "web-session-\(UUID().uuidString)"
        let runtime = LiveRuntime.shared
        let oldGatewayID = runtime.gatewayID
        let oldMapping = runtime.sessionToBot[sessionID]
        defer {
            runtime.gatewayID = oldGatewayID; runtime.sessionToBot[sessionID] = oldMapping
            ChatRuntime.shared.turnFloor[botID] = nil; model.chats[botID] = nil
        }
        model.mode = .live; runtime.gatewayID = "web-gateway"
        runtime.sessionToBot[sessionID] = botID
        model.chat(for: botID).sessionID = sessionID
        model.routeToolEvent(GatewayEvent(type: "message.start", sessionID: sessionID, payload: nil))
        model.routeToolEvent(GatewayEvent(type: "tool.generating", sessionID: sessionID,
                                          payload: ["name": "web_search"]))
        model.routeToolEvent(GatewayEvent(type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "X", "result": ["response": [
                "success": false, "results": [[
                    "title": "Result", "url": "https://example.com",
                ]],
            ]]]))
        var before = try XCTUnwrap(model.chats[botID]?.messages.last?.toolCalls
            .first(where: { $0.gatewayToolID == "X" }))
        XCTAssertEqual(before.state, .done,
                       "search-specific failure stays inert before exact name authority")
        XCTAssertNil(before.webSearchOutput)
        XCTAssertNotNil(before.deferredWebSearchOutput)
        XCTAssertTrue(before.deferredWebSearchHasExplicitError)
        model.routeToolEvent(GatewayEvent(type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "X", "name": "web_search", "args": ["query": "q"]]))
        let calls = try XCTUnwrap(model.chats[botID]?.messages.last?.toolCalls)
        XCTAssertEqual(calls.count, 1)
        before = try XCTUnwrap(calls.first)
        XCTAssertEqual(before.gatewayToolID, "X")
        XCTAssertEqual(before.state, .failed)
        XCTAssertEqual(before.webSearchOutput?.query, "q")
        XCTAssertNil(before.deferredWebSearchOutput)
        XCTAssertFalse(before.deferredWebSearchHasExplicitError)

        model.routeToolEvent(GatewayEvent(type: "tool.generating", sessionID: sessionID,
                                          payload: ["name": "read_file"]))
        model.routeToolEvent(GatewayEvent(type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "Y", "result": ["response": [
                "success": false, "results": [["title": "must stay inert"]],
            ]]]))
        model.routeToolEvent(GatewayEvent(type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "Y", "name": "read_file", "args": ["path": "a"]]))
        let nonweb = try XCTUnwrap(model.chats[botID]?.messages.last?.toolCalls
            .first(where: { $0.gatewayToolID == "Y" }))
        XCTAssertEqual(nonweb.state, .done)
        XCTAssertNil(nonweb.webSearchOutput)
        XCTAssertNil(nonweb.deferredWebSearchOutput)
        XCTAssertFalse(nonweb.deferredWebSearchHasExplicitError)
    }

    func testLateStartADoesNotConsumeGeneratingPlaceholderB() throws {
        let model = AppModel()
        let botID = "web-late-\(UUID().uuidString)"
        let sessionID = "web-late-session-\(UUID().uuidString)"
        let runtime = LiveRuntime.shared
        let oldGatewayID = runtime.gatewayID
        let oldMapping = runtime.sessionToBot[sessionID]
        defer {
            runtime.gatewayID = oldGatewayID; runtime.sessionToBot[sessionID] = oldMapping
            ChatRuntime.shared.turnFloor[botID] = nil; model.chats[botID] = nil
        }
        model.mode = .live; runtime.gatewayID = "web-late-gateway"
        runtime.sessionToBot[sessionID] = botID; model.chat(for: botID).sessionID = sessionID
        model.routeToolEvent(GatewayEvent(type: "message.start", sessionID: sessionID, payload: nil))
        model.routeToolEvent(GatewayEvent(type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "A", "name": "web_search", "args": ["query": "A"]]))
        model.routeToolEvent(GatewayEvent(type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "A", "name": "web_search", "result": ["results": [["title": "A"]]]]))
        let settled = try XCTUnwrap(model.chats[botID]?.messages.last?.toolCalls.first)
        model.routeToolEvent(GatewayEvent(type: "tool.generating", sessionID: sessionID,
                                          payload: ["name": "web_search"]))
        model.routeToolEvent(GatewayEvent(type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "A", "name": "web_search", "args": ["query": "wrong"]]))
        let calls = try XCTUnwrap(model.chats[botID]?.messages.last?.toolCalls)
        XCTAssertEqual(calls.first(where: { $0.gatewayToolID == "A" }), settled)
        XCTAssertNotNil(calls.first(where: { $0.id.hasPrefix(ChatRuntime.generatingPrefix) }))
    }

    func testRawOmittedNamePairsOnlyByExactIDAndDuplicateNamesStaySeparate() throws {
        let transcript: JSONValue = ["messages": [
            ["id": 1, "role": "assistant", "content": "", "tool_calls": [
                ["id": "A", "function": ["name": "web_search", "arguments": "{\"query\":\"one\"}"]],
                ["id": "B", "function": ["name": "web_search", "arguments": "{\"query\":\"two\"}"]],
            ]],
            ["id": 2, "role": "tool", "tool_call_id": "B",
             "content": ["results": [["title": "second", "url": "https://b.example"]]]],
            ["id": 3, "role": "tool", "tool_call_id": "A",
             "content": "{\"response\":{\"success\":false,\"results\":[{\"title\":\"first\",\"url\":\"https://a.example\"}]}}"],
        ]]
        let calls = AppModel.chatMessages(fromTranscript: transcript).flatMap(\.toolCalls)
        XCTAssertEqual(calls.first(where: { $0.gatewayToolID == "A" })?.webSearchOutput?.hits.first?.title,
                       "first")
        XCTAssertEqual(calls.first(where: { $0.gatewayToolID == "B" })?.webSearchOutput?.hits.first?.title,
                       "second")
        XCTAssertEqual(calls.first(where: { $0.gatewayToolID == "A" })?.state, .failed)
    }

    func testMeaningfulFailureAndSpecialistEvidenceAreMonotonic() throws {
        let model = AppModel()
        let botID = "web-failure-\(UUID().uuidString)"
        let sessionID = "web-failure-session-\(UUID().uuidString)"
        let runtime = LiveRuntime.shared
        let oldGatewayID = runtime.gatewayID
        let oldMapping = runtime.sessionToBot[sessionID]
        defer {
            runtime.gatewayID = oldGatewayID; runtime.sessionToBot[sessionID] = oldMapping
            ChatRuntime.shared.turnFloor[botID] = nil; model.chats[botID] = nil
        }
        model.mode = .live; runtime.gatewayID = "web-failure-gateway"
        runtime.sessionToBot[sessionID] = botID; model.chat(for: botID).sessionID = sessionID
        model.routeToolEvent(GatewayEvent(type: "message.start", sessionID: sessionID, payload: nil))
        model.routeToolEvent(GatewayEvent(type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "F", "name": "web_search", "args": ["query": "failed"]]))
        model.routeToolEvent(GatewayEvent(type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "F", "name": "web_search", "summary": "denied",
                      "error": "denied", "result": ["results": [["title": "evidence"]]]]))
        model.routeToolEvent(GatewayEvent(type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "F", "result": ["message": "sparse replay"]]))
        let call = try XCTUnwrap(model.chats[botID]?.messages.last?.toolCalls.first)
        XCTAssertEqual(call.state, .failed)
        XCTAssertEqual(call.summary, "denied")
        XCTAssertEqual(call.webSearchOutput?.hits.first?.title, "evidence")
    }

    func testExactOverlayUsesLiveBodyAndStoredQueryWhilePreservingStoredFailure() throws {
        let id = UUID()
        let storedOutput = ToolWebSearchOutput(
            state: .available, query: "stored query",
            hits: [ToolWebSearchHit(id: 0, title: "stored")])
        let liveOutput = ToolWebSearchOutput(
            state: .available, hits: [ToolWebSearchHit(id: 0, title: "live")])
        let storedSuccess = ChatMessage(id: id, author: .bot, text: "done", toolCalls: [
            ToolCall(id: "stored", name: "web_search", context: "", state: .done,
                     gatewayToolID: "wire", webSearchOutput: storedOutput,
                     provenance: .stored),
        ], rowID: 7)
        let live = ChatMessage(id: id, author: .bot, text: "done", toolCalls: [
            ToolCall(id: "live", name: "web_search", context: "", state: .done,
                     gatewayToolID: "wire", webSearchOutput: liveOutput,
                     provenance: .live),
        ], rowID: 7)
        let success = try XCTUnwrap(TranscriptHydrationMerge.merge(
            history: [storedSuccess], baseline: [live], current: [live], clearWhenEmpty: false)
            .first?.toolCalls.first)
        XCTAssertEqual(success.webSearchOutput?.hits.first?.title, "live")
        XCTAssertEqual(success.webSearchOutput?.query, "stored query")
        XCTAssertEqual(success.provenance, .stored)

        let stored = ChatMessage(id: id, author: .bot, text: "done", toolCalls: [
            ToolCall(id: "stored", name: "web_search", context: "", state: .failed,
                     gatewayToolID: "wire", webSearchOutput: storedOutput,
                     provenance: .stored),
        ], rowID: 7)
        let call = try XCTUnwrap(TranscriptHydrationMerge.merge(
            history: [stored], baseline: [live], current: [live], clearWhenEmpty: false)
            .first?.toolCalls.first)
        XCTAssertEqual(call.state, .failed)
        XCTAssertEqual(call.webSearchOutput?.hits.first?.title, "stored")
        XCTAssertEqual(call.webSearchOutput?.query, "stored query")
        XCTAssertEqual(call.provenance, .stored)

        let deferredStored = ChatMessage(id: id, author: .bot, text: "done", toolCalls: [
            ToolCall(
                id: "stored-deferred", name: "Tool", context: "", state: .done,
                gatewayToolID: "wire", deferredWebSearchOutput: storedOutput,
                deferredWebSearchHasExplicitError: true, provenance: .stored),
        ], rowID: 7)
        let promoted = try XCTUnwrap(TranscriptHydrationMerge.merge(
            history: [deferredStored], baseline: [live], current: [live],
            clearWhenEmpty: false).first?.toolCalls.first)
        XCTAssertEqual(promoted.name, "web_search")
        XCTAssertEqual(promoted.state, .failed)
        XCTAssertNotNil(promoted.webSearchOutput)
        XCTAssertNil(promoted.deferredWebSearchOutput)
        XCTAssertFalse(promoted.deferredWebSearchHasExplicitError)
    }

    func testCandidateAndToolCallCodableRemainBoundedAndInert() throws {
        let candidate = try XCTUnwrap(ToolWebSearchCodec.candidate(
            arguments: nil, result: ["results": [["title": "candidate"]]]))
        var call = ToolCall(
            id: "x", name: "Tool", context: "", state: .done,
            gatewayToolID: "x", deferredWebSearchOutput: candidate,
            deferredWebSearchHasExplicitError: true)
        call = try JSONDecoder().decode(ToolCall.self, from: JSONEncoder().encode(call))
        XCTAssertNil(call.webSearchOutput)
        XCTAssertEqual(call.deferredWebSearchOutput?.hits.first?.title, "candidate")
        XCTAssertTrue(call.deferredWebSearchHasExplicitError)
        XCTAssertNil(ToolWebSearchCodec.admit(
            toolName: "WEB_SEARCH", arguments: nil,
            result: ["results": [["title": "candidate"]]]).output)
    }

    func testDuplicateRawReplayCannotEraseMeaningfulFailedGenericEvidence() throws {
        let transcript: JSONValue = ["messages": [
            ["id": 1, "role": "assistant", "content": "", "tool_calls": [[
                "id": "duplicate", "function": ["name": "read_file", "arguments": "{}"],
            ]]],
            ["id": 2, "role": "tool", "tool_call_id": "duplicate",
             "tool_name": "read_file", "context": "permission denied",
             "content": ["error": "permission denied", "evidence": "original"]],
            ["id": 3, "role": "tool", "tool_call_id": "duplicate",
             "tool_name": "read_file", "context": "late benign replay",
             "content": ["message": "late"]],
        ]]
        let call = try XCTUnwrap(AppModel.chatMessages(fromTranscript: transcript)
            .flatMap(\.toolCalls).first(where: { $0.gatewayToolID == "duplicate" }))
        XCTAssertEqual(call.state, .failed)
        XCTAssertEqual(call.summary, "permission denied")
        XCTAssertEqual(call.result?.json?["evidence"]?.stringValue, "original")
        XCTAssertTrue(call.resultText?.contains("original") == true)
        XCTAssertFalse(call.resultText?.contains("late") == true)
    }

    func testSpecialistDoesNotEraseGenericResultEvidence() throws {
        let payload = ToolCompletePayload([
            "tool_id": "evidence", "name": "web_search",
            "result": ["results": [["title": "result",
                                       "url": "https://example.com"]],
                       "request_id": "retained-generic-evidence"],
        ])
        XCTAssertNotNil(payload.webSearchOutput)
        XCTAssertEqual(payload.result?.json?["request_id"]?.stringValue,
                       "retained-generic-evidence")
    }

    func testPresentationOrderAccessibilitySelectionAndMotionPolicies() {
        let output = ToolWebSearchOutput(state: .available,
            hits: [ToolWebSearchHit(id: 0, title: "result", url: "https://example.com")])
        let diff = ToolFileDiff(sourceField: .diff, state: .available,
                                unifiedDiff: "+x", addedLines: 1)
        let structured = ToolStructuredOutput(stdout: ToolOutputStream(
            state: .available, segments: [ToolANSISegment(id: 0, text: "stdout")]))
        let calls = [
            ToolCall(id: "generic", name: "read_file", context: "", state: .done),
            ToolCall(id: "web", name: "web_search", context: "", state: .done,
                     webSearchOutput: output),
            ToolCall(id: "diff", name: "patch", context: "", state: .done, fileDiff: diff),
            ToolCall(id: "structured", name: "terminal", context: "", state: .done,
                     structuredOutput: structured),
            ToolCall(id: "generic2", name: "read_file", context: "", state: .done),
        ]
        XCTAssertEqual(ToolRunPresentationPolicy.presentationRuns(calls).map { $0.map(\.id) },
                       [["generic"], ["web"], ["diff"], ["structured", "generic2"]])
        XCTAssertEqual(WebSearchPresentationPolicy.minimumInteractiveDimension, 44)
        XCTAssertEqual(WebSearchPresentationPolicy.titleTextStyle, .subheadline)
        XCTAssertEqual(WebSearchPresentationPolicy.hostTextStyle, .caption)
        XCTAssertEqual(WebSearchPresentationPolicy.snippetTextStyle, .caption)
        XCTAssertTrue(WebSearchPresentationPolicy.snippetsAreSelectable)
        XCTAssertTrue(WebSearchPresentationPolicy.disclosureHonorsReducedMotion)
        XCTAssertEqual(WebSearchPresentationPolicy.visibleDestinationHost(output.hits[0]),
                       "example.com")
    }
}
