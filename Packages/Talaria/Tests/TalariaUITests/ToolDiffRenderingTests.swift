import XCTest
@testable import TalariaKit
@testable import TalariaUI

@MainActor
final class ToolDiffRenderingTests: XCTestCase {
    func testLiveCompletionRetainsExplicitFileEditDiff() throws {
        let payload = ToolCompletePayload([
            "tool_id": "edit-1", "name": "patch",
            "args": ["path": "/repo/Sources/App.swift"],
            "inline_diff": "--- a/App.swift\n+++ b/App.swift\n@@ -1 +1 @@\n-old\n+new",
            "result": ["message": "updated"],
        ])
        let diff = try XCTUnwrap(payload.fileDiff)
        XCTAssertEqual(diff.sourceField, .inlineDiff)
        XCTAssertEqual(diff.path, "/repo/Sources/App.swift")
        XCTAssertEqual(diff.addedLines, 1)
        XCTAssertEqual(diff.removedLines, 1)
        XCTAssertFalse(diff.isTruncated)
    }

    func testNonFileToolsNeverBecomeDiffSpecialists() {
        XCTAssertNil(ToolDiffCodec.extract(
            toolName: "terminal", arguments: nil,
            result: ["diff": "+not a file-edit contract"]))
        XCTAssertNil(ToolCompletePayload([
            "name": "skill_manage", "inline_diff": "+not in this slice",
        ]).fileDiff)
    }

    func testCompletionBeforeStartUsesExactIDAndStartOnlyEnrichesPath() throws {
        let model = AppModel()
        let botID = "diff-order-\(UUID().uuidString)"
        let sessionID = "diff-session-\(UUID().uuidString)"
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
        runtime.gatewayID = "diff-order-gateway"
        runtime.sessionToBot[sessionID] = botID
        model.chat(for: botID).sessionID = sessionID
        model.routeToolEvent(GatewayEvent(type: "message.start", sessionID: sessionID, payload: nil))
        model.routeToolEvent(GatewayEvent(
            type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "diff-wire",
                      "inline_diff": "┊ review diff\n@@ -1 +1 @@\n-old\n+live body"]))
        model.routeToolEvent(GatewayEvent(
            type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "diff-wire", "name": "patch",
                      "args": ["path": "/repo/App.swift"]]))

        let calls = try XCTUnwrap(model.chats[botID]?.messages.last?.toolCalls)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].gatewayToolID, "diff-wire")
        XCTAssertEqual(calls[0].fileDiff?.path, "/repo/App.swift")
        XCTAssertEqual(calls[0].fileDiff?.unifiedDiff,
                       "@@ -1 +1 @@\n-old\n+live body")
        XCTAssertNil(calls[0].deferredFileDiff)
    }

    func testNamelessNestedCompletionBeforeStartIsReadmittedByExactID() throws {
        let model = AppModel()
        let botID = "nested-order-\(UUID().uuidString)"
        let sessionID = "nested-session-\(UUID().uuidString)"
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
        runtime.gatewayID = "nested-gateway"
        runtime.sessionToBot[sessionID] = botID
        model.chat(for: botID).sessionID = sessionID
        model.routeToolEvent(GatewayEvent(type: "message.start", sessionID: sessionID, payload: nil))
        model.routeToolEvent(GatewayEvent(
            type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "nested-wire",
                      "result": ["diff": "-before\n+after"]]))
        model.routeToolEvent(GatewayEvent(
            type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "nested-wire", "name": "write_file",
                      "args": ["path": "/repo/Nested.swift"]]))

        let call = try XCTUnwrap(model.chats[botID]?.messages.last?.toolCalls.first)
        XCTAssertEqual(call.name, "write_file")
        XCTAssertEqual(call.fileDiff?.sourceField, .diff)
        XCTAssertEqual(call.fileDiff?.unifiedDiff, "-before\n+after")
        XCTAssertEqual(call.fileDiff?.path, "/repo/Nested.swift")
        XCTAssertNil(call.deferredFileDiff)
    }

    func testGeneratingThenNamelessCompletionThenStartCoalescesExactInvocation() throws {
        let model = AppModel()
        let botID = "generating-order-\(UUID().uuidString)"
        let sessionID = "generating-session-\(UUID().uuidString)"
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
        runtime.gatewayID = "generating-gateway"
        runtime.sessionToBot[sessionID] = botID
        model.chat(for: botID).sessionID = sessionID
        model.routeToolEvent(GatewayEvent(type: "message.start", sessionID: sessionID, payload: nil))
        model.routeToolEvent(GatewayEvent(
            type: "tool.generating", sessionID: sessionID,
            payload: ["name": "patch", "context": "preparing edit"]))
        model.routeToolEvent(GatewayEvent(
            type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "exact-X",
                      "inline_diff": "-before\n+after",
                      "result": ["message": "updated"]]))
        model.routeToolEvent(GatewayEvent(
            type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "exact-X", "name": "patch",
                      "args": ["path": "/repo/Coalesced.swift"]]))

        let calls = try XCTUnwrap(model.chats[botID]?.messages.last?.toolCalls)
        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.gatewayToolID, "exact-X")
        XCTAssertEqual(calls.filter { $0.gatewayToolID == "exact-X" }.count, 1)
        XCTAssertFalse(call.id.hasPrefix(ChatRuntime.generatingPrefix))
        XCTAssertEqual(call.name, "patch")
        XCTAssertEqual(call.state, .done)
        XCTAssertEqual(call.arguments?.json?["path"]?.stringValue,
                       "/repo/Coalesced.swift")
        XCTAssertEqual(call.fileDiff?.path, "/repo/Coalesced.swift")
        XCTAssertEqual(call.fileDiff?.unifiedDiff, "-before\n+after")
        XCTAssertNil(call.deferredFileDiff)
    }

    func testLateStartADoesNotConsumeGeneratingPlaceholderB() throws {
        let model = AppModel()
        let botID = "late-start-\(UUID().uuidString)"
        let sessionID = "late-start-session-\(UUID().uuidString)"
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
        runtime.gatewayID = "late-start-gateway"
        runtime.sessionToBot[sessionID] = botID
        model.chat(for: botID).sessionID = sessionID
        model.routeToolEvent(GatewayEvent(type: "message.start", sessionID: sessionID, payload: nil))
        model.routeToolEvent(GatewayEvent(
            type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "A", "name": "patch",
                      "context": "edit A", "args": ["path": "/repo/A.swift"]]))
        model.routeToolEvent(GatewayEvent(
            type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "A", "name": "patch", "summary": "A done",
                      "inline_diff": "-old A\n+new A", "result": ["ok": true]]))
        let settledA = try XCTUnwrap(model.chats[botID]?.messages.last?.toolCalls
            .first(where: { $0.gatewayToolID == "A" }))

        model.routeToolEvent(GatewayEvent(
            type: "tool.generating", sessionID: sessionID,
            payload: ["name": "patch", "context": "preparing B"]))
        model.routeToolEvent(GatewayEvent(
            type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "A", "name": "patch",
                      "context": "late replay must not replace A",
                      "args": ["path": "/repo/not-A.swift"]]))

        let calls = try XCTUnwrap(model.chats[botID]?.messages.last?.toolCalls)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.filter { $0.gatewayToolID == "A" }.count, 1)
        XCTAssertEqual(calls.first(where: { $0.gatewayToolID == "A" }), settledA)
        let pendingB = try XCTUnwrap(calls.first(where: {
            $0.id.hasPrefix(ChatRuntime.generatingPrefix)
        }))
        XCTAssertEqual(pendingB.name, "patch")
        XCTAssertEqual(pendingB.state, .running)
        XCTAssertNil(pendingB.gatewayToolID)
    }

    func testSparseReplayCannotEraseExactLiveDiff() throws {
        let model = AppModel()
        let botID = "diff-replay-\(UUID().uuidString)"
        let sessionID = "diff-replay-session-\(UUID().uuidString)"
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
        runtime.gatewayID = "diff-replay-gateway"
        runtime.sessionToBot[sessionID] = botID
        model.chat(for: botID).sessionID = sessionID
        model.routeToolEvent(GatewayEvent(type: "message.start", sessionID: sessionID, payload: nil))
        model.routeToolEvent(GatewayEvent(
            type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "wire", "name": "edit_file",
                      "args": ["path": "/repo/A.swift"]]))
        model.routeToolEvent(GatewayEvent(
            type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "wire", "name": "edit_file",
                      "inline_diff": "-first\n+second", "result": ["ok": true]]))
        model.routeToolEvent(GatewayEvent(
            type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "wire", "name": "edit_file",
                      "result": ["message": "sparse replay"]]))

        let call = try XCTUnwrap(model.chats[botID]?.messages.last?.toolCalls.first)
        XCTAssertEqual(call.fileDiff?.unifiedDiff, "-first\n+second")
        XCTAssertEqual(call.fileDiff?.path, "/repo/A.swift")
    }

    func testRawHydrationPairsDiffAndPathOnlyByExactID() throws {
        let transcript: JSONValue = ["messages": [
            ["id": 1, "role": "assistant", "content": "", "tool_calls": [
                ["id": "edit-a", "function": ["name": "patch",
                    "arguments": "{\"path\":\"/repo/A.swift\"}"]],
                ["id": "edit-b", "function": ["name": "patch",
                    "arguments": "{\"path\":\"/repo/B.swift\"}"]],
            ]],
            ["id": 2, "role": "tool", "tool_call_id": "edit-b",
             "tool_name": "patch", "content": ["diff": "+second"]],
            ["id": 3, "role": "tool", "tool_call_id": "edit-a",
             "tool_name": "patch", "content": "{\"diff\":\"+first\"}"],
        ]]
        let calls = AppModel.chatMessages(fromTranscript: transcript).flatMap(\.toolCalls)
        let first = try XCTUnwrap(calls.first(where: { $0.gatewayToolID == "edit-a" }))
        let second = try XCTUnwrap(calls.first(where: { $0.gatewayToolID == "edit-b" }))
        XCTAssertEqual(first.fileDiff?.path, "/repo/A.swift")
        XCTAssertEqual(first.fileDiff?.unifiedDiff, "+first")
        XCTAssertEqual(second.fileDiff?.path, "/repo/B.swift")
        XCTAssertEqual(second.fileDiff?.unifiedDiff, "+second")
    }

    func testNamelessRawResultIsReadmittedUsingExactPairedCallName() throws {
        let transcript: JSONValue = ["messages": [
            ["id": 1, "role": "assistant", "content": "", "tool_calls": [[
                "id": "paired", "function": ["name": "edit_file",
                    "arguments": "{\"path\":\"/repo/Paired.swift\"}"],
            ]]],
            ["id": 2, "role": "tool", "tool_call_id": "paired",
             "content": ["inline_diff": "-old\n+new"]],
        ]]
        let call = try XCTUnwrap(AppModel.chatMessages(fromTranscript: transcript)
            .flatMap(\.toolCalls).first)
        XCTAssertEqual(call.name, "edit_file")
        XCTAssertEqual(call.fileDiff?.path, "/repo/Paired.swift")
        XCTAssertEqual(call.fileDiff?.unifiedDiff, "-old\n+new")
        XCTAssertNil(call.deferredFileDiff)
    }

    func testIDLessStoredDiffStaysUnmatched() throws {
        let transcript: JSONValue = ["messages": [
            ["id": 1, "role": "assistant", "content": "", "tool_calls": [[
                "id": "identified", "function": ["name": "patch", "arguments": "{}"],
            ]]],
            ["id": 2, "role": "tool", "tool_name": "patch",
             "content": ["diff": "+orphan"]],
        ]]
        let calls = AppModel.chatMessages(fromTranscript: transcript).flatMap(\.toolCalls)
        XCTAssertNil(calls.first(where: { $0.gatewayToolID == "identified" })?.fileDiff)
        XCTAssertEqual(calls.first(where: { $0.gatewayToolID == nil })?.fileDiff?.unifiedDiff,
                       "+orphan")
    }

    func testMalformedAndEmptyFieldsRemainExplicit() throws {
        let malformed = try XCTUnwrap(ToolDiffCodec.extract(
            toolName: "write_file", arguments: ["path": "a.swift"],
            result: ["inline_diff": ["not": "text"]]))
        XCTAssertEqual(malformed.state, .malformed)
        XCTAssertNil(malformed.unifiedDiff)
        XCTAssertTrue(malformed.diagnostic?.contains("not a text") == true)

        let empty = try XCTUnwrap(ToolDiffCodec.extract(
            toolName: "patch", arguments: nil,
            result: ["diff": "\u{001B}[31m\u{001B}[0m"]))
        XCTAssertEqual(empty.state, .malformed)
        XCTAssertTrue(empty.diagnostic?.contains("no displayable") == true)
    }

    func testBoundsApplyBeforeNormalizationSplittingAndRendering() throws {
        let tooManyLines = (0..<(ToolDiffCodec.maximumLines + 20))
            .map { "+line \($0)" }.joined(separator: "\n")
        let diff = try XCTUnwrap(ToolDiffCodec.extract(
            toolName: "patch", arguments: nil, result: ["diff": .string(tooManyLines)]))
        XCTAssertTrue(diff.isTruncated)
        XCTAssertLessThanOrEqual(diff.unifiedDiff?.unicodeScalars.count ?? .max,
                                 ToolDiffCodec.maximumCharacters)
        XCTAssertEqual(FileDiffPresentationPolicy.lines(diff).count,
                       ToolDiffCodec.maximumLines)

        let combining = "+" + String(repeating: "\u{0301}", count: 100_000)
        let scalarBounded = try XCTUnwrap(ToolDiffCodec.extract(
            toolName: "edit_file", arguments: nil,
            result: ["inline_diff": .string(combining)]))
        XCTAssertTrue(scalarBounded.isTruncated)
        XCTAssertLessThanOrEqual(scalarBounded.unifiedDiff?.unicodeScalars.count ?? .max,
                                 ToolDiffCodec.maximumCharacters)
    }

    func testTerminalControlsBidiAndHostilePathAreSanitized() throws {
        let hostilePath = "\u{001B}]0;spoof\u{0007}/repo\n/\u{202E}App.swift"
            + String(repeating: "\u{0301}", count: 10_000)
        let controlled = "\u{001B}[31m┊ review diff\u{001B}[0m\n"
            + "\u{001B}]0;secret\u{0007}@@ -1 +1 @@\n"
            + "-old\u{202E}txt\n+new\u{001B}[2Ktxt\n"
            + "\u{001B}Pprivate\u{001B}\\"
        let diff = try XCTUnwrap(ToolDiffCodec.extract(
            toolName: "patch", arguments: ["path": .string(hostilePath)],
            result: ["inline_diff": .string(controlled)]))
        XCTAssertFalse(diff.unifiedDiff?.contains("review diff") == true)
        XCTAssertFalse(diff.unifiedDiff?.contains("secret") == true)
        XCTAssertFalse(diff.unifiedDiff?.contains("private") == true)
        XCTAssertFalse(diff.unifiedDiff?.unicodeScalars.contains(where: {
            $0.value == 0x1B || $0.value == 0x202E
        }) == true)
        let path = try XCTUnwrap(diff.path)
        XCTAssertFalse(path.contains("spoof"))
        XCTAssertFalse(path.contains("\n"))
        XCTAssertLessThanOrEqual(path.unicodeScalars.count,
                                 ToolDiffCodec.maximumPathCharacters)
    }

    func testLiteralRowsClassifyWithoutExecutingOrParsingMarkdown() throws {
        let diff = try XCTUnwrap(ToolDiffCodec.extract(
            toolName: "patch", arguments: nil,
            result: ["diff": "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-`rm -rf /`\n+$(touch nope)\n unchanged"]))
        let rows = FileDiffPresentationPolicy.lines(diff)
        XCTAssertEqual(rows.map(\.kind), [.header, .header, .header, .header,
                                           .removal, .addition, .context])
        XCTAssertEqual(rows[4].text, "-`rm -rf /`")
        XCTAssertEqual(rows[5].text, "+$(touch nope)")
    }

    func testExactOverlayEnrichesPathWithoutReplacingLiveBody() throws {
        let messageID = UUID()
        let storedDiff = ToolFileDiff(sourceField: .diff, state: .available,
                                      path: "/repo/App.swift",
                                      unifiedDiff: "-stored\n+stored",
                                      addedLines: 1, removedLines: 1)
        let liveDiff = ToolFileDiff(sourceField: .inlineDiff, state: .available,
                                    unifiedDiff: "-live\n+live",
                                    addedLines: 1, removedLines: 1)
        let stored = ChatMessage(id: messageID, author: .bot, text: "done", toolCalls: [
            ToolCall(id: "stored", name: "patch", context: "", state: .done,
                     gatewayToolID: "wire", fileDiff: storedDiff),
        ], rowID: 9)
        let live = ChatMessage(id: messageID, author: .bot, text: "done", toolCalls: [
            ToolCall(id: "live", name: "patch", context: "", state: .done,
                     gatewayToolID: "wire", fileDiff: liveDiff),
        ], rowID: 9)
        let merged = TranscriptHydrationMerge.merge(
            history: [stored], baseline: [live], current: [live], clearWhenEmpty: false)
        let diff = try XCTUnwrap(merged.first?.toolCalls.first?.fileDiff)
        XCTAssertEqual(diff.path, "/repo/App.swift")
        XCTAssertEqual(diff.unifiedDiff, "-live\n+live")
        XCTAssertEqual(diff.sourceField, .inlineDiff)
    }

    func testExactOverlayPreservesMeaningfulStoredFailure() throws {
        let messageID = UUID()
        let diff = ToolFileDiff(sourceField: .diff, state: .available,
                                unifiedDiff: "+attempted", addedLines: 1)
        let stored = ChatMessage(id: messageID, author: .bot, text: "done", toolCalls: [
            ToolCall(id: "stored", name: "patch", context: "", state: .failed,
                     gatewayToolID: "wire", result: ToolPayloadCodec.result(from: [
                        "error": "permission denied",
                     ]), fileDiff: diff),
        ], rowID: 9)
        let live = ChatMessage(id: messageID, author: .bot, text: "done", toolCalls: [
            ToolCall(id: "live", name: "patch", context: "", state: .done,
                     gatewayToolID: "wire"),
        ], rowID: 9)
        let merged = TranscriptHydrationMerge.merge(
            history: [stored], baseline: [live], current: [live], clearWhenEmpty: false)
        XCTAssertEqual(merged.first?.toolCalls.first?.state, .failed)
        XCTAssertEqual(merged.first?.toolCalls.first?.fileDiff, diff)
    }

    func testMeaningfulErrorSemanticsRemainStrict() {
        XCTAssertTrue(AppModel.toolFailed(
            payload: ["error": "permission denied"], summary: nil, resultText: nil))
        XCTAssertTrue(AppModel.toolFailed(
            payload: ["is_error": true], summary: nil, resultText: nil))
        for value: JSONValue in [.bool(false), .null, .string("   ")] {
            XCTAssertFalse(AppModel.toolFailed(
                payload: ["error": value], summary: "error in prose", resultText: "error"))
        }
        XCTAssertFalse(AppModel.toolFailed(
            payload: ["result": "error appears in successful file content"],
            summary: "error appears", resultText: "error appears"))
    }

    func testFailedLiveDiffEvidenceIsMonotonicAcrossSparseReplay() throws {
        let model = AppModel()
        let botID = "failed-replay-\(UUID().uuidString)"
        let sessionID = "failed-replay-session-\(UUID().uuidString)"
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
        runtime.gatewayID = "failed-replay-gateway"
        runtime.sessionToBot[sessionID] = botID
        model.chat(for: botID).sessionID = sessionID
        model.routeToolEvent(GatewayEvent(type: "message.start", sessionID: sessionID, payload: nil))
        model.routeToolEvent(GatewayEvent(
            type: "tool.start", sessionID: sessionID,
            payload: ["tool_id": "failed-wire", "name": "patch",
                      "args": ["path": "/repo/Failure.swift"]]))
        model.routeToolEvent(GatewayEvent(
            type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "failed-wire", "name": "patch",
                      "summary": "permission denied", "error": "permission denied",
                      "result": ["error": "permission denied", "evidence": "original"],
                      "inline_diff": "-old\n+attempted"]))
        model.routeToolEvent(GatewayEvent(
            type: "tool.complete", sessionID: sessionID,
            payload: ["tool_id": "failed-wire",
                      "summary": "sparse replay", "result": ["message": "late"]]))

        let call = try XCTUnwrap(model.chats[botID]?.messages.last?.toolCalls.first)
        XCTAssertEqual(call.state, .failed)
        XCTAssertEqual(call.summary, "permission denied")
        XCTAssertEqual(call.result?.json?["evidence"]?.stringValue, "original")
        XCTAssertEqual(call.fileDiff?.unifiedDiff, "-old\n+attempted")
        XCTAssertEqual(call.fileDiff?.path, "/repo/Failure.swift")
    }

    func testFileEditNamesAreExactAndCaseSensitive() {
        XCTAssertTrue(ToolDiffCodec.isFileEditTool("patch"))
        XCTAssertTrue(ToolDiffCodec.isFileEditTool("edit_file"))
        XCTAssertTrue(ToolDiffCodec.isFileEditTool("write_file"))
        XCTAssertFalse(ToolDiffCodec.isFileEditTool("PATCH"))
        XCTAssertNil(ToolDiffCodec.extract(
            toolName: "PATCH", arguments: nil, result: ["diff": "+unsafe alias"]))
        let payload = ToolCompletePayload([
            "tool_id": "upper", "name": "PATCH", "inline_diff": "+candidate",
        ])
        XCTAssertNil(payload.fileDiff)
        XCTAssertNotNil(payload.deferredFileDiff,
                        "bounded material may remain inert until an exact valid start name")
    }

    func testSpecialistsPartitionGenericRunsInOrder() {
        let diff = ToolFileDiff(sourceField: .diff, state: .available,
                                unifiedDiff: "+new", addedLines: 1)
        let calls = [
            ToolCall(id: "read", name: "read_file", context: "", state: .done),
            ToolCall(id: "patch", name: "patch", context: "", state: .done,
                     fileDiff: diff),
            ToolCall(id: "shell", name: "terminal", context: "", state: .done),
            ToolCall(id: "search", name: "search_files", context: "", state: .done),
        ]
        XCTAssertEqual(ToolRunPresentationPolicy.presentationRuns(calls).map { $0.map(\.id) },
                       [["read"], ["patch"], ["shell", "search"]])
    }

    func testMobileDisclosureAccessibilityAndSelectionPolicies() {
        let diff = ToolFileDiff(sourceField: .inlineDiff, state: .malformed,
                                addedLines: 2, removedLines: 1, isTruncated: true)
        XCTAssertEqual(FileDiffPresentationPolicy.minimumInteractiveDimension, 44)
        XCTAssertEqual(FileDiffPresentationPolicy.titleTextStyle, .subheadline)
        XCTAssertEqual(FileDiffPresentationPolicy.metadataTextStyle, .caption)
        XCTAssertEqual(FileDiffPresentationPolicy.bodyTextStyle, .caption)
        XCTAssertTrue(FileDiffPresentationPolicy.diffTextIsSelectable)
        XCTAssertTrue(FileDiffPresentationPolicy.disclosureUsesReducedMotionEnvironment)
        XCTAssertEqual(FileDiffPresentationPolicy.accessibilityValue(diff, failed: true),
                       "File edit failed, 2 additions, 1 removals, diff malformed, preview truncated")
        XCTAssertEqual(FileDiffPresentationPolicy.basename("C:\\repo\\App.swift"), "App.swift")
    }

    func testToolCallCodableRoundTripRetainsDiff() throws {
        let call = ToolCall(
            id: "one", name: "write_file", context: "", state: .done,
            gatewayToolID: "wire",
            fileDiff: ToolFileDiff(sourceField: .inlineDiff, state: .available,
                                   path: "/repo/a", unifiedDiff: "+x", addedLines: 1))
        let decoded = try JSONDecoder().decode(ToolCall.self,
                                               from: JSONEncoder().encode(call))
        XCTAssertEqual(decoded, call)
    }
}
