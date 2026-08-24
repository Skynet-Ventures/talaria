#if canImport(XCTest)
import XCTest
@testable import TalariaKit

final class SubagentEventDecodingTests: XCTestCase {
    func testCurrentHermesSubagentPayloadDecodesTypedBoundedFields() throws {
        let event = GatewayEvent(
            type: "subagent.complete", sessionID: "parent-runtime",
            payload: .object([
                "subagent_id": .string("sa-child"),
                "parent_id": .string("sa-root"),
                "child_session_id": .string("stored-child"),
                "goal": .string("Inspect the integration"),
                "model": .string("small-model"),
                "task_count": .number(3),
                "task_index": .number(1),
                "depth": .number(1),
                "tool_count": .number(2),
                "toolsets": .array([.string("terminal"), .string("files")]),
                "status": .string("timeout"),
                "summary": .string("Timed out after a useful partial result"),
                "input_tokens": .number(11),
                "output_tokens": .number(12),
                "reasoning_tokens": .number(13),
                "api_calls": .number(2),
                "duration_seconds": .number(4.5),
                "cost_usd": .number(0.0125),
                "files_read": .array([.string("Sources/A.swift")]),
                "files_written": .array([.string("Sources/B.swift")]),
                "output_tail": .array([
                    .object([
                        "tool": .string("terminal"),
                        "preview": .string("tests passed"),
                        "is_error": .bool(false),
                    ])
                ]),
            ])
        )

        guard case .subagent(let subagent) = TypedGatewayEvent(event) else {
            return XCTFail("expected typed subagent event")
        }
        XCTAssertEqual(subagent.kind, .complete)
        XCTAssertEqual(subagent.parentRuntimeSessionID, "parent-runtime")
        XCTAssertEqual(subagent.subagentID, "sa-child")
        XCTAssertEqual(subagent.parentSubagentID, "sa-root")
        XCTAssertEqual(subagent.childSessionID, "stored-child")
        XCTAssertEqual(subagent.status, .value(.timeout))
        XCTAssertEqual(subagent.tokenUsage.inputTokens, 11)
        XCTAssertEqual(subagent.tokenUsage.outputTokens, 12)
        XCTAssertEqual(subagent.tokenUsage.reasoningTokens, 13)
        XCTAssertEqual(subagent.tokenUsage.apiCalls, 2)
        XCTAssertEqual(subagent.cost.durationSeconds, 4.5)
        XCTAssertEqual(subagent.cost.costUSD, 0.0125)
        XCTAssertEqual(subagent.filesRead, ["Sources/A.swift"])
        XCTAssertEqual(subagent.filesWritten, ["Sources/B.swift"])
        XCTAssertEqual(subagent.outputTail?.first?.tool, "terminal")
    }

    func testUnknownOrMalformedSubagentFramesStayRaw() {
        let missingIdentity = GatewayEvent(
            type: "subagent.start", sessionID: "parent", payload: .object([:]))
        let malformedIdentity = GatewayEvent(
            type: "subagent.start", sessionID: "parent\u{202E}",
            payload: .object(["subagent_id": .string("sa")]))
        let whitespaceIdentity = GatewayEvent(
            type: "subagent.start", sessionID: "parent\n",
            payload: .object(["subagent_id": .string("sa")]))
        let unknownSuffix = GatewayEvent(
            type: "subagent.future", sessionID: "parent",
            payload: .object(["subagent_id": .string("sa")]))

        for event in [missingIdentity, malformedIdentity, whitespaceIdentity, unknownSuffix] {
            guard case .other(let raw) = TypedGatewayEvent(event) else {
                return XCTFail("unsafe subagent frame must remain raw")
            }
            XCTAssertEqual(raw.type, event.type)
        }
    }

    func testMalformedOptionalScalarsDoNotBecomeInventedValues() {
        let event = GatewayEvent(
            type: "subagent.complete", sessionID: "parent",
            payload: .object([
                "subagent_id": .string("sa"),
                "status": .string("new-terminal-state"),
                "depth": .number(-1),
                "input_tokens": .number(1.5),
                "duration_seconds": .number(Double.infinity),
                "cost_usd": .number(-0.1),
                "child_session_id": .string("child\u{202E}"),
            ])
        )
        guard case .subagent(let subagent) = TypedGatewayEvent(event) else {
            return XCTFail("identity-valid payload remains a typed sparse event")
        }
        XCTAssertEqual(subagent.status, .malformed)
        XCTAssertNil(subagent.reportedDepth)
        XCTAssertNil(subagent.tokenUsage.inputTokens)
        XCTAssertNil(subagent.cost.durationSeconds)
        XCTAssertNil(subagent.cost.costUSD)
        XCTAssertNil(subagent.childSessionID)
    }

    func testBackendCanceledStatusNormalizesToCanonicalCancelled() {
        let event = GatewayEvent(
            type: "subagent.complete", sessionID: "parent",
            payload: .object([
                "subagent_id": .string("sa"),
                "status": .string("canceled"),
            ])
        )

        guard case .subagent(let subagent) = TypedGatewayEvent(event) else {
            return XCTFail("expected typed subagent event")
        }
        XCTAssertEqual(subagent.status, .value(.cancelled))
    }
}
#endif
