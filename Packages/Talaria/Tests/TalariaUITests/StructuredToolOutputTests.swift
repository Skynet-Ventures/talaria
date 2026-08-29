#if canImport(XCTest)
import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

@MainActor
final class StructuredToolOutputTests: XCTestCase {
    func testBenignErrorValuesDoNotDeclareStructuredOrLiveFailure() {
        let benign: [JSONValue] = [.null, .bool(false), .number(0), .string("")]

        for value in benign {
            let admission = ToolOutputCodec.admit(
                toolName: "terminal",
                result: ["stdout": "ok", "error": value])
            XCTAssertFalse(admission.hasExplicitError, "Unexpected failure for \(value)")
            XCTAssertFalse(AppModel.toolFailed(
                payload: ["error": value],
                summary: "error is ordinary output",
                resultText: "error is ordinary output"))
        }

        XCTAssertTrue(ToolOutputCodec.admit(
            toolName: "terminal",
            result: ["stdout": "", "error": "permission denied"]).hasExplicitError)
        XCTAssertTrue(AppModel.toolFailed(
            payload: ["error": "permission denied"], summary: nil, resultText: nil))
    }

    func testStructuredAdmissionUsesExactCaseSensitiveToolNames() {
        let result: JSONValue = ["stdout": "ok"]
        XCTAssertNotNil(ToolOutputCodec.extract(toolName: "terminal", result: result))
        XCTAssertNotNil(ToolOutputCodec.extract(toolName: "execute_code", result: result))
        XCTAssertNil(ToolOutputCodec.extract(toolName: "Terminal", result: result))
        XCTAssertNil(ToolOutputCodec.extract(toolName: "Execute_Code", result: result))
    }

    func testOnlyValidBoundedSerializedObjectsPromoteFromJSONStrings() throws {
        let valid = ToolOutputCodec.admit(
            toolName: "terminal",
            result: .string("{\"stdout\":\"encoded\",\"stderr\":\"warning\"}"))
        XCTAssertEqual(valid.output?.stdout?.plainText, "encoded")
        XCTAssertEqual(valid.output?.stderr?.plainText, "warning")

        for lookalike in ["{not-json", "prefix {\"stdout\":\"spoof\"}",
                          "[INFO] stdout: spoof"] {
            let admission = ToolOutputCodec.admit(
                toolName: "terminal", result: .string(lookalike))
            XCTAssertNil(admission.output, "Prose/lookalike must stay generic")
            XCTAssertEqual(admission.genericResult?.kind, .text)
            XCTAssertEqual(admission.genericResult?.displayText, lookalike)
        }

        let oversized = "{\"stdout\":\""
            + String(repeating: "x", count: 256_001) + "\"}"
        let bounded = ToolOutputCodec.admit(
            toolName: "terminal", result: .string(oversized))
        XCTAssertNil(bounded.output, "Oversized serialized JSON must not decode")
        XCTAssertEqual(bounded.genericResult?.kind, .text)
        XCTAssertTrue(bounded.genericResult?.isTruncated == true)
    }

    func testStructuredOutputMergingKeepsStoredChannelsWhenLiveCompletionIsSparse() throws {
        let stored = ToolStructuredOutput(
            stdout: ToolOutputStream(state: .available,
                                     segments: [ToolANSISegment(id: 0, text: "stored stdout")]),
            stderr: ToolOutputStream(state: .available,
                                     segments: [ToolANSISegment(id: 0, text: "stored stderr")]),
            residualText: "{\n  \"exit_code\" : 0\n}")
        let live = ToolStructuredOutput(
            stdout: ToolOutputStream(state: .available,
                                     segments: [ToolANSISegment(id: 0, text: "live stdout")]))

        let merged = try XCTUnwrap(ToolStructuredOutput.merging(
            newer: live, preserving: stored))
        XCTAssertEqual(merged.stdout?.plainText, "live stdout")
        XCTAssertEqual(merged.stderr?.plainText, "stored stderr")
        XCTAssertEqual(merged.residualText, stored.residualText)
    }

    func testRawOmittedToolNameUsesExactIDAmongDuplicateToolNames() throws {
        let transcript: JSONValue = ["messages": [
            ["id": 1, "role": "assistant", "content": "", "tool_calls": [
                ["id": "call-a", "function": [
                    "name": "terminal", "arguments": "{\"command\":\"alpha\"}",
                ]],
                ["id": "call-b", "function": [
                    "name": "terminal", "arguments": "{\"command\":\"bravo\"}",
                ]],
            ]],
            // Neither result carries tool_name. The duplicate display names
            // must not become a pairing key; the wire ids are authoritative.
            ["id": 2, "role": "tool", "tool_call_id": "call-b",
             "content": ["stdout": "B"]],
            ["id": 3, "role": "tool", "tool_call_id": "call-a",
             "content": ["stdout": "A"]],
        ]]

        let calls = AppModel.chatMessages(fromTranscript: transcript)
            .flatMap(\.toolCalls)
        XCTAssertEqual(calls.map(\.gatewayToolID), ["call-a", "call-b"])
        XCTAssertEqual(calls.map(\.name), ["terminal", "terminal"])
        XCTAssertEqual(calls[0].structuredOutput?.stdout?.plainText, "A")
        XCTAssertEqual(calls[1].structuredOutput?.stdout?.plainText, "B")
    }

    func testLiveSparseCompletionReAdmitsUsingEstablishedExactCallName() throws {
        let model = AppModel()
        let botID = "structured-output-live-name-\(UUID().uuidString)"
        let sessionID = "structured-output-live-session-\(UUID().uuidString)"
        let runtime = LiveRuntime.shared
        let oldGatewayID = runtime.gatewayID
        let oldMapping = runtime.sessionToBot[sessionID]
        defer {
            runtime.gatewayID = oldGatewayID
            runtime.sessionToBot[sessionID] = oldMapping
            ChatRuntime.shared.turnFloor[botID] = nil
            model.chats[botID] = nil
        }

        model.mode = .live
        runtime.gatewayID = "structured-output-live-gateway"
        runtime.sessionToBot[sessionID] = botID
        model.chat(for: botID).sessionID = sessionID
        model.routeToolEvent(GatewayEvent(
            type: "message.start", sessionID: sessionID, payload: nil))
        model.routeToolEvent(GatewayEvent(
            type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "exact-live", "name": "terminal"]))
        // The completion's name is omitted, so the established exact start
        // call must supply the specialist identity before re-admission.
        model.routeToolEvent(GatewayEvent(
            type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "exact-live",
                      "result": ["stdout": "ok", "stderr": "warning"]]))

        let call = try XCTUnwrap(model.chats[botID]?.messages.flatMap(\.toolCalls).first)
        XCTAssertEqual(call.name, "terminal")
        XCTAssertEqual(call.gatewayToolID, "exact-live")
        XCTAssertEqual(call.structuredOutput?.stdout?.plainText, "ok")
        XCTAssertEqual(call.structuredOutput?.stderr?.plainText, "warning")
    }

    func testNamelessTopLevelCompletionStaysGenericUntilExactTerminalStart() throws {
        let model = AppModel()
        let botID = "structured-output-before-start-\(UUID().uuidString)"
        let sessionID = "structured-output-before-start-session-\(UUID().uuidString)"
        let runtime = LiveRuntime.shared
        let oldGatewayID = runtime.gatewayID
        let oldMapping = runtime.sessionToBot[sessionID]
        defer {
            runtime.gatewayID = oldGatewayID
            runtime.sessionToBot[sessionID] = oldMapping
            ChatRuntime.shared.turnFloor[botID] = nil
            model.chats[botID] = nil
        }

        model.mode = .live
        runtime.gatewayID = "structured-output-before-start-gateway"
        runtime.sessionToBot[sessionID] = botID
        model.chat(for: botID).sessionID = sessionID
        model.routeToolEvent(GatewayEvent(
            type: "message.start", sessionID: sessionID, payload: nil))
        model.routeToolEvent(GatewayEvent(
            type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "before-start",
                      "error": "permission denied",
                      "result": ["stdout": "top-level", "exit_code": 2]]))

        let before = try XCTUnwrap(model.chats[botID]?.messages.flatMap(\.toolCalls)
            .first(where: { $0.gatewayToolID == "before-start" }))
        XCTAssertEqual(before.name, "Tool")
        XCTAssertNil(before.structuredOutput,
                     "A nameless completion must not render a specialist by guesswork")
        XCTAssertEqual(before.deferredStructuredOutput?.stdout?.plainText, "top-level")
        XCTAssertTrue(before.deferredStructuredOutput?.stderr == nil)
        XCTAssertLessThanOrEqual(
            before.deferredStructuredOutput?.stdout?.plainText.unicodeScalars.count ?? .max,
            ToolOutputCodec.maximumStreamScalars)
        XCTAssertEqual(before.result?.kind, .json)
        XCTAssertTrue(before.result?.displayText?.contains("top-level") == true)
        XCTAssertEqual(before.state, .failed)

        let encoded = try JSONEncoder().encode(before)
        let decoded = try JSONDecoder().decode(ToolCall.self, from: encoded)
        XCTAssertEqual(decoded, before,
                       "The inert deferred candidate and generic evidence must be Codable")
        XCTAssertEqual(decoded.deferredStructuredOutput?.stdout?.plainText, "top-level")

        model.routeToolEvent(GatewayEvent(
            type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "before-start", "name": "terminal"]))

        let after = try XCTUnwrap(model.chats[botID]?.messages.flatMap(\.toolCalls)
            .first(where: { $0.gatewayToolID == "before-start" }))
        XCTAssertEqual(after.name, "terminal")
        XCTAssertEqual(after.structuredOutput?.stdout?.plainText, "top-level")
        XCTAssertNil(after.deferredStructuredOutput)
        XCTAssertEqual(after.state, .failed,
                       "Promotion must preserve the original failure evidence")
        XCTAssertNotNil(after.result,
                        "Specialist promotion must not erase generic result evidence")
    }

    func testNamelessNestedValidJSONPromotesForExecuteCodeAfterExactStart() throws {
        let model = AppModel()
        let botID = "structured-output-nested-before-start-\(UUID().uuidString)"
        let sessionID = "structured-output-nested-session-\(UUID().uuidString)"
        let runtime = LiveRuntime.shared
        let oldGatewayID = runtime.gatewayID
        let oldMapping = runtime.sessionToBot[sessionID]
        defer {
            runtime.gatewayID = oldGatewayID
            runtime.sessionToBot[sessionID] = oldMapping
            ChatRuntime.shared.turnFloor[botID] = nil
            model.chats[botID] = nil
        }

        model.mode = .live
        runtime.gatewayID = "structured-output-nested-gateway"
        runtime.sessionToBot[sessionID] = botID
        model.chat(for: botID).sessionID = sessionID
        model.routeToolEvent(GatewayEvent(
            type: "message.start", sessionID: sessionID, payload: nil))
        let serialized = "{\"stdout\":\"nested stdout\",\"stderr\":\"nested stderr\"}"
        model.routeToolEvent(GatewayEvent(
            type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "nested-before-start",
                      "result": .string(serialized)]))

        let before = try XCTUnwrap(model.chats[botID]?.messages.flatMap(\.toolCalls)
            .first(where: { $0.gatewayToolID == "nested-before-start" }))
        XCTAssertNil(before.structuredOutput)
        XCTAssertEqual(before.deferredStructuredOutput?.stdout?.plainText, "nested stdout")
        XCTAssertEqual(before.deferredStructuredOutput?.stderr?.plainText, "nested stderr")
        XCTAssertEqual(before.result?.kind, .json)

        model.routeToolEvent(GatewayEvent(
            type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "nested-before-start", "name": "execute_code"]))

        let after = try XCTUnwrap(model.chats[botID]?.messages.flatMap(\.toolCalls)
            .first(where: { $0.gatewayToolID == "nested-before-start" }))
        XCTAssertEqual(after.name, "execute_code")
        XCTAssertEqual(after.structuredOutput?.stdout?.plainText, "nested stdout")
        XCTAssertEqual(after.structuredOutput?.stderr?.plainText, "nested stderr")
        XCTAssertNil(after.deferredStructuredOutput)
        XCTAssertNotNil(after.result, "Generic decoded JSON remains available after promotion")
    }

    func testWrongCaseAndNonterminalStartsDiscardCandidateWithoutGenericOrFailureLoss() throws {
        let model = AppModel()
        let botID = "structured-output-inert-start-\(UUID().uuidString)"
        let sessionID = "structured-output-inert-session-\(UUID().uuidString)"
        let runtime = LiveRuntime.shared
        let oldGatewayID = runtime.gatewayID
        let oldMapping = runtime.sessionToBot[sessionID]
        defer {
            runtime.gatewayID = oldGatewayID
            runtime.sessionToBot[sessionID] = oldMapping
            ChatRuntime.shared.turnFloor[botID] = nil
            model.chats[botID] = nil
        }

        model.mode = .live
        runtime.gatewayID = "structured-output-inert-gateway"
        runtime.sessionToBot[sessionID] = botID
        model.chat(for: botID).sessionID = sessionID
        model.routeToolEvent(GatewayEvent(
            type: "message.start", sessionID: sessionID, payload: nil))
        model.routeToolEvent(GatewayEvent(
            type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "wrong-case",
                      "result": ["stdout": "must stay generic"]]))
        model.routeToolEvent(GatewayEvent(
            type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "nonterminal",
                      "error": "permission denied",
                      "result": ["stdout": "failed generic"]]))

        let before = try XCTUnwrap(model.chats[botID]?.messages.flatMap(\.toolCalls))
        XCTAssertNotNil(before.first(where: { $0.gatewayToolID == "wrong-case" })?
            .deferredStructuredOutput)
        XCTAssertNotNil(before.first(where: { $0.gatewayToolID == "nonterminal" })?
            .deferredStructuredOutput)

        model.routeToolEvent(GatewayEvent(
            type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "wrong-case", "name": "Terminal"]))
        model.routeToolEvent(GatewayEvent(
            type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "nonterminal", "name": "read_file"]))

        let calls = try XCTUnwrap(model.chats[botID]?.messages.flatMap(\.toolCalls))
        let wrongCase = try XCTUnwrap(calls.first(where: {
            $0.gatewayToolID == "wrong-case"
        }))
        XCTAssertEqual(wrongCase.name, "Terminal")
        XCTAssertNil(wrongCase.structuredOutput)
        XCTAssertNil(wrongCase.deferredStructuredOutput)
        XCTAssertNotNil(wrongCase.result)

        let nonterminal = try XCTUnwrap(calls.first(where: {
            $0.gatewayToolID == "nonterminal"
        }))
        XCTAssertEqual(nonterminal.name, "read_file")
        XCTAssertNil(nonterminal.structuredOutput)
        XCTAssertNil(nonterminal.deferredStructuredOutput)
        XCTAssertNotNil(nonterminal.result)
        XCTAssertEqual(nonterminal.state, .failed)
    }

    func testGeneratingNamelessCompletionThenStartCoalescesWithoutDuplicateOwnership() throws {
        let model = AppModel()
        let botID = "structured-output-generating-\(UUID().uuidString)"
        let sessionID = "structured-output-generating-session-\(UUID().uuidString)"
        let runtime = LiveRuntime.shared
        let oldGatewayID = runtime.gatewayID
        let oldMapping = runtime.sessionToBot[sessionID]
        defer {
            runtime.gatewayID = oldGatewayID
            runtime.sessionToBot[sessionID] = oldMapping
            ChatRuntime.shared.turnFloor[botID] = nil
            model.chats[botID] = nil
        }

        model.mode = .live
        runtime.gatewayID = "structured-output-generating-gateway"
        runtime.sessionToBot[sessionID] = botID
        model.chat(for: botID).sessionID = sessionID
        model.routeToolEvent(GatewayEvent(
            type: "message.start", sessionID: sessionID, payload: nil))
        model.routeToolEvent(GatewayEvent(
            type: "tool.generating", sessionID: sessionID,
            payload: ["name": "terminal", "context": "preparing command"]))
        model.routeToolEvent(GatewayEvent(
            type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "generating-exact",
                      "result": ["stdout": "coalesced"]]))

        let before = try XCTUnwrap(model.chats[botID]?.messages.flatMap(\.toolCalls))
        XCTAssertEqual(before.filter { $0.id.hasPrefix(ChatRuntime.generatingPrefix) }.count, 1)
        XCTAssertEqual(before.filter { $0.gatewayToolID == "generating-exact" }.count, 1)
        let pending = try XCTUnwrap(before.first(where: {
            $0.gatewayToolID == "generating-exact"
        }))
        XCTAssertNil(pending.structuredOutput)
        XCTAssertEqual(pending.deferredStructuredOutput?.stdout?.plainText, "coalesced")

        model.routeToolEvent(GatewayEvent(
            type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "generating-exact", "name": "terminal"]))

        let calls = try XCTUnwrap(model.chats[botID]?.messages.flatMap(\.toolCalls))
        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.gatewayToolID, "generating-exact")
        XCTAssertFalse(call.id.hasPrefix(ChatRuntime.generatingPrefix))
        XCTAssertEqual(call.name, "terminal")
        XCTAssertEqual(call.structuredOutput?.stdout?.plainText, "coalesced")
        XCTAssertNil(call.deferredStructuredOutput)
        XCTAssertNotNil(call.result, "Generic result evidence survives coalescing")
    }

    func testLateStartADoesNotConsumeGeneratingPlaceholderBForStructuredOutput() throws {
        let model = AppModel()
        let botID = "structured-output-late-placeholder-\(UUID().uuidString)"
        let sessionID = "structured-output-late-placeholder-session-\(UUID().uuidString)"
        let runtime = LiveRuntime.shared
        let oldGatewayID = runtime.gatewayID
        let oldMapping = runtime.sessionToBot[sessionID]
        defer {
            runtime.gatewayID = oldGatewayID
            runtime.sessionToBot[sessionID] = oldMapping
            ChatRuntime.shared.turnFloor[botID] = nil
            model.chats[botID] = nil
        }

        model.mode = .live
        runtime.gatewayID = "structured-output-late-placeholder-gateway"
        runtime.sessionToBot[sessionID] = botID
        model.chat(for: botID).sessionID = sessionID
        model.routeToolEvent(GatewayEvent(
            type: "message.start", sessionID: sessionID, payload: nil))
        model.routeToolEvent(GatewayEvent(
            type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "A", "name": "terminal", "context": "A"]))
        model.routeToolEvent(GatewayEvent(
            type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "A", "name": "terminal",
                      "result": ["stdout": "A done"]]))
        let settledA = try XCTUnwrap(model.chats[botID]?.messages.flatMap(\.toolCalls)
            .first(where: { $0.gatewayToolID == "A" }))

        model.routeToolEvent(GatewayEvent(
            type: "tool.generating", sessionID: sessionID,
            payload: ["name": "terminal", "context": "preparing B"]))
        model.routeToolEvent(GatewayEvent(
            type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "A", "name": "terminal",
                      "context": "late replay must not replace A"]))

        let calls = try XCTUnwrap(model.chats[botID]?.messages.flatMap(\.toolCalls))
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.filter { $0.gatewayToolID == "A" }.count, 1)
        XCTAssertEqual(calls.first(where: { $0.gatewayToolID == "A" }), settledA)
        let pendingB = try XCTUnwrap(calls.first(where: {
            $0.id.hasPrefix(ChatRuntime.generatingPrefix)
        }))
        XCTAssertEqual(pendingB.name, "terminal")
        XCTAssertEqual(pendingB.state, .running)
        XCTAssertNil(pendingB.gatewayToolID)
    }

    func testFailedLiveReplayIsMonotonicButFillsAPreviouslyMissingChannel() throws {
        let model = AppModel()
        let botID = "structured-output-failure-\(UUID().uuidString)"
        let sessionID = "structured-output-session-\(UUID().uuidString)"
        let runtime = LiveRuntime.shared
        let oldGatewayID = runtime.gatewayID
        let oldMapping = runtime.sessionToBot[sessionID]
        defer {
            runtime.gatewayID = oldGatewayID
            runtime.sessionToBot[sessionID] = oldMapping
            ChatRuntime.shared.turnFloor[botID] = nil
            model.chats[botID] = nil
        }

        model.mode = .live
        runtime.gatewayID = "structured-output-gateway"
        runtime.sessionToBot[sessionID] = botID
        model.chat(for: botID).sessionID = sessionID
        model.routeToolEvent(GatewayEvent(
            type: "message.start", sessionID: sessionID, payload: nil))
        model.routeToolEvent(GatewayEvent(
            type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "failed-output", "name": "terminal"]))
        model.routeToolEvent(GatewayEvent(
            type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "failed-output", "name": "terminal",
                      "error": "command failed",
                      "result": ["stdout": "failed stdout", "exit_code": 2]]))
        // A later sparse replay must not turn the failed invocation green, but
        // its newly available stderr channel is still useful evidence.
        model.routeToolEvent(GatewayEvent(
            type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "failed-output", "name": "terminal",
                      "error": false,
                      "result": ["stderr": "late stderr"]]))

        let call = try XCTUnwrap(model.chats[botID]?.messages.flatMap(\.toolCalls).first)
        XCTAssertEqual(call.state, .failed)
        XCTAssertEqual(call.structuredOutput?.stdout?.plainText, "failed stdout")
        XCTAssertEqual(call.structuredOutput?.stderr?.plainText, "late stderr")
        XCTAssertTrue(call.structuredOutput?.residualText?.contains("exit_code") == true)
    }

    func testANSISGRSubsetMatchesHermesDesktopStateSemantics() throws {
        let escape = "\u{001B}["
        let source = "plain \(escape)31mred\(escape)0m reset "
            + "\(escape)1mbold\(escape)22m regular "
            + "\(escape)1;32mboth\(escape)39mbold-only\(escape)m default "
            + "\(escape)92mbright"
        let stream = try XCTUnwrap(ToolOutputCodec.extract(
            toolName: "terminal", result: ["stdout": .string(source)])?.stdout)

        XCTAssertEqual(stream.segments, [
            ToolANSISegment(id: 0, text: "plain "),
            ToolANSISegment(id: 1, text: "red", foreground: .red),
            ToolANSISegment(id: 2, text: " reset "),
            ToolANSISegment(id: 3, text: "bold", bold: true),
            ToolANSISegment(id: 4, text: " regular "),
            ToolANSISegment(id: 5, text: "both", foreground: .green, bold: true),
            ToolANSISegment(id: 6, text: "bold-only", bold: true),
            ToolANSISegment(id: 7, text: " default "),
            ToolANSISegment(id: 8, text: "bright", foreground: .brightGreen),
        ])
        XCTAssertEqual(stream.copyText,
                       "plain red reset bold regular bothbold-only default bright")
    }

    func testUnsupportedANSIControlsAreConsumedWithoutApplyingTerminalBehavior() throws {
        let escape = "\u{001B}"
        let source = "before\(escape)[2Jmiddle\(escape)[10;5Hafter "
            + "\(escape)]0;hidden title\u{0007}visible "
            + "\(escape)[38;5;208mindexed \(escape)[38;2;10;20;30mtruecolor "
            + "\(escape)[31$mintermediate \u{009B}32$mc1-intermediate "
            + "\(escape)[31mred"
        let stream = try XCTUnwrap(ToolOutputCodec.extract(
            toolName: "execute_code", result: ["stdout": .string(source)])?.stdout)

        XCTAssertEqual(stream.plainText,
                       "beforemiddleafter visible indexed truecolor intermediate c1-intermediate red")
        XCTAssertEqual(stream.segments, [
            ToolANSISegment(
                id: 0, text: "beforemiddleafter visible indexed truecolor intermediate "
                    + "c1-intermediate "),
            ToolANSISegment(id: 1, text: "red", foreground: .red),
        ])
        XCTAssertFalse(stream.plainText.contains("hidden title"))
        XCTAssertFalse(stream.copyText.unicodeScalars.contains("\u{001B}"))
    }

    func testControlAndSegmentBombsRemainBoundedAndVisibleAsTruncated() throws {
        let hidden = "\u{001B}]" + String(
            repeating: "secret", count: ToolOutputCodec.maximumRawWorkScalars) + "TAIL"
        let controlStream = try XCTUnwrap(ToolOutputCodec.extract(
            toolName: "execute_code", result: ["stdout": .string(hidden)])?.stdout)
        XCTAssertEqual(controlStream.state, .available)
        XCTAssertTrue(controlStream.isTruncated)
        XCTAssertFalse(controlStream.plainText.contains("secret"))
        XCTAssertTrue(controlStream.plainText.contains("output truncated"))
        XCTAssertLessThanOrEqual(
            controlStream.plainText.unicodeScalars.count,
            ToolOutputCodec.maximumStreamScalars)

        let segments = (0..<1_000).map { index in
            "\u{001B}[\(index.isMultiple(of: 2) ? 31 : 32)m\(index)"
        }.joined()
        let segmentStream = try XCTUnwrap(ToolOutputCodec.extract(
            toolName: "terminal", result: ["stdout": .string(segments)])?.stdout)
        XCTAssertTrue(segmentStream.isTruncated)
        XCTAssertLessThanOrEqual(segmentStream.segments.count,
                                  ToolOutputCodec.maximumSegments)
        XCTAssertLessThanOrEqual(
            segmentStream.plainText.unicodeScalars.count,
            ToolOutputCodec.maximumStreamScalars)
        XCTAssertTrue(segmentStream.plainText.contains("output truncated"))
    }

    func testDirectStructuredJSONControlBombIsTreeBoundedBeforeRendering() throws {
        let hidden = "\u{001B}]" + String(
            repeating: "secret", count: ToolOutputCodec.maximumRawWorkScalars)
        let admission = ToolOutputCodec.admit(
            toolName: "terminal", result: .array([.string(hidden)]))

        XCTAssertNil(admission.output)
        XCTAssertEqual(admission.genericResult?.kind, .json)
        XCTAssertTrue(admission.genericResult?.isTruncated == true)
        XCTAssertNil(admission.genericResult?.json)
        XCTAssertTrue(admission.genericResult?.displayText?.contains("[truncated]") == true)
        XCTAssertFalse(admission.genericResult?.displayText?.contains("secret") == true)
        XCTAssertLessThanOrEqual(
            admission.genericResult?.displayText?.unicodeScalars.count ?? .max,
            ToolPayloadCodec.maximumResultCharacters)
    }

    func testHugeMetadataDictionaryIsBoundedAndRetainsPriorityFields() throws {
        var result: [String: JSONValue] = [
            "stdout": "ok", "exit_code": 7, "pid": 42,
        ]
        for index in 0..<10_000 {
            result["attacker-\(index)"] = .string("metadata")
        }

        let selection = ToolOutputCodec.selectMetadata(from: result)
        XCTAssertLessThanOrEqual(selection.inspectedKeyCount,
                                  ToolOutputCodec.maximumMetadataKeysInspected)
        XCTAssertLessThanOrEqual(selection.entries.count,
                                  ToolOutputCodec.maximumMetadataKeysAdmitted)
        XCTAssertTrue(selection.wasTruncated)
        XCTAssertTrue(selection.entries.contains(where: { $0.key == "exit_code" }))
        XCTAssertTrue(selection.entries.contains(where: { $0.key == "pid" }))
        XCTAssertFalse(selection.entries.contains(where: { $0.key == "stdout" }))
        XCTAssertFalse(selection.entries.contains(where: { $0.key == "stderr" }))

        let output = try XCTUnwrap(ToolOutputCodec.extract(
            toolName: "terminal", result: .object(result)))
        XCTAssertTrue(output.residualIsTruncated)
        XCTAssertTrue(output.residualText?.contains("exit_code") == true)
        XCTAssertTrue(output.residualText?.contains("pid") == true)
        XCTAssertLessThanOrEqual(
            output.residualText?.unicodeScalars.count ?? .max,
            ToolOutputCodec.maximumResidualScalars)
    }

    func testExactSourceAndProvenanceOverlayKeepsStoredSourceAndSparseLiveEvidence() throws {
        let messageID = UUID()
        let storedOutput = ToolStructuredOutput(
            stdout: ToolOutputStream(state: .available,
                                     segments: [ToolANSISegment(id: 0, text: "stored stdout")]),
            stderr: ToolOutputStream(state: .available,
                                     segments: [ToolANSISegment(id: 0, text: "stored stderr")]),
            residualText: "{\n  \"exit_code\" : 0\n}")
        let liveOutput = ToolStructuredOutput(
            stdout: ToolOutputStream(state: .available,
                                     segments: [ToolANSISegment(id: 0, text: "live stdout")]))
        let stored = ChatMessage(
            id: messageID, author: .bot, text: "done",
            toolCalls: [ToolCall(
                id: "stored-call", name: "terminal", context: "pwd", state: .done,
                gatewayToolID: "wire", structuredOutput: storedOutput,
                provenance: .stored)], rowID: 7)
        let live = ChatMessage(
            id: messageID, author: .bot, text: "done",
            toolCalls: [ToolCall(
                id: "live-call", name: "terminal", context: "pwd", state: .running,
                gatewayToolID: "wire", structuredOutput: liveOutput,
                provenance: .live)], rowID: 7)

        let merged = TranscriptHydrationMerge.merge(
            history: [stored], baseline: [live], current: [live], clearWhenEmpty: false)
        let call = try XCTUnwrap(merged.first?.toolCalls.first)
        XCTAssertEqual(call.gatewayToolID, "wire")
        // Canonical history remains the source of the retained row; live
        // evidence overlays its exact invocation without fabricating a new
        // durable provenance claim.
        XCTAssertEqual(call.provenance, .stored)
        XCTAssertEqual(call.structuredOutput?.stdout?.plainText, "live stdout")
        XCTAssertEqual(call.structuredOutput?.stderr?.plainText, "stored stderr")
        XCTAssertEqual(call.structuredOutput?.residualText, storedOutput.residualText)
    }

    func testCanonicalOverlayPromotesStoredNamelessDeferredChannelsByExactID() throws {
        let messageID = UUID()
        let deferred = ToolStructuredOutput(
            stderr: ToolOutputStream(state: .available,
                                     segments: [ToolANSISegment(id: 0, text: "stored stderr")]),
            residualText: "{\n  \"exit_code\" : 2\n}")
        let stored = ChatMessage(
            id: messageID, author: .bot, text: "done",
            toolCalls: [ToolCall(
                id: "stored-call", name: "Tool", context: "", state: .failed,
                gatewayToolID: "wire", result: ToolPayloadCodec.result(from: [
                    "error": "permission denied",
                ]), deferredStructuredOutput: deferred, provenance: .stored,
                diagnostic: "Retained result arrived before its start name.")], rowID: 13)
        let live = ChatMessage(
            id: messageID, author: .bot, text: "done",
            toolCalls: [ToolCall(
                id: "live-call", name: "terminal", context: "", state: .done,
                gatewayToolID: "wire",
                structuredOutput: ToolStructuredOutput(
                    stdout: ToolOutputStream(state: .available,
                                             segments: [ToolANSISegment(
                                                id: 0, text: "live stdout")])),
                provenance: .live)], rowID: 13)

        let merged = TranscriptHydrationMerge.merge(
            history: [stored], baseline: [live], current: [live], clearWhenEmpty: false)
        let call = try XCTUnwrap(merged.first?.toolCalls.first)
        XCTAssertEqual(call.gatewayToolID, "wire")
        XCTAssertEqual(call.name, "terminal")
        XCTAssertEqual(call.provenance, .stored,
                       "Canonical history remains the exact retained source")
        XCTAssertEqual(call.structuredOutput?.stdout?.plainText, "live stdout")
        XCTAssertEqual(call.structuredOutput?.stderr?.plainText, "stored stderr")
        XCTAssertEqual(call.structuredOutput?.residualText, deferred.residualText)
        XCTAssertNil(call.deferredStructuredOutput)
        XCTAssertEqual(call.state, .failed,
                       "Stored meaningful failure cannot be erased by a sparse live success")
        XCTAssertEqual(call.result?.json?["error"]?.stringValue, "permission denied")
    }

    func testVoiceOverPreviewIsBoundedWithoutChangingSelectableCopyText() throws {
        let source = String(repeating: "spoken\n", count: 2_000)
        let stream = try XCTUnwrap(ToolOutputCodec.extract(
            toolName: "terminal", result: ["stdout": .string(source)])?.stdout)
        let spoken = ToolOutputPresentationPolicy.accessibilityValue(stream)

        XCTAssertLessThanOrEqual(
            spoken.unicodeScalars.count,
            ToolOutputPresentationPolicy.maximumAccessibilityScalars + 2)
        XCTAssertFalse(spoken.contains("\n"))
        XCTAssertTrue(spoken.hasSuffix(" …"))
        XCTAssertEqual(stream.copyText, stream.plainText)
        XCTAssertGreaterThan(
            stream.copyText.unicodeScalars.count,
            ToolOutputPresentationPolicy.maximumAccessibilityScalars)
    }

    func testStructuredOutputAndToolCallCodableRoundTripPreservesProvenance() throws {
        let output = ToolStructuredOutput(
            stdout: ToolOutputStream(
                state: .available,
                segments: [ToolANSISegment(
                    id: 0, text: "green", foreground: .green, bold: true)]),
            stderr: ToolOutputStream(
                state: .malformed, diagnostic: "stderr was not text"),
            residualText: "{\n  \"pid\" : 42\n}", residualIsTruncated: false,
            diagnostic: nil)
        let call = ToolCall(
            id: "stored-call", name: "terminal", context: "pwd", state: .done,
            gatewayToolID: "wire", structuredOutput: output,
            deferredStructuredOutput: ToolStructuredOutput(
                stdout: ToolOutputStream(state: .available,
                                         segments: [ToolANSISegment(id: 0, text: "deferred")])),
            provenance: .stored,
            diagnostic: "hydrated from exact retained result")

        let data = try JSONEncoder().encode(call)
        let decoded = try JSONDecoder().decode(ToolCall.self, from: data)
        XCTAssertEqual(decoded, call)
        XCTAssertEqual(decoded.structuredOutput?.stdout?.segments.first?.foreground, .green)
        XCTAssertEqual(decoded.deferredStructuredOutput?.stdout?.plainText, "deferred")
        XCTAssertEqual(decoded.provenance, .stored)
    }
}
#endif
