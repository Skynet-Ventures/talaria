import XCTest
@testable import TalariaKit

final class TranscriptPartsTests: XCTestCase {
    private func payload(_ parts: [JSONValue], mode: String? = nil,
                         clipped: Bool = false) -> JSONValue {
        var object: [String: JSONValue] = [
            "parts_version": .number(1),
            "parts": .array(parts),
            "parts_clipped": .bool(clipped),
        ]
        if let mode { object["parts_mode"] = .string(mode) }
        return .object(object)
    }

    private func part(_ kind: String, text: String? = nil,
                      id: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["kind": .string(kind)]
        if let text { object["text"] = .string(text) }
        if let id { object["id"] = .string(id) }
        return .object(object)
    }

    func testKnownUnknownMalformedAndLegacyFallback() throws {
        let update = try XCTUnwrap(TranscriptPartsCodec.update(from: payload([
            part("text", text: "hello", id: "assistant-stream"),
            .object(["kind": .string("future-kind"), "evidence": .string("kept")]),
            .string("bad"),
        ])))
        XCTAssertEqual(update.envelope.parts[0].kind, .text)
        XCTAssertEqual(update.envelope.parts[1].kind, .unknown)
        XCTAssertEqual(update.envelope.parts[1].sourceKind, "future-kind")
        XCTAssertTrue(update.envelope.parts.contains { $0.kind == .malformed })
        XCTAssertTrue(update.envelope.clipped)

        let malformed = TranscriptPartsCodec.update(from: .object([
            "parts_version": .number(2), "parts": .array([]),
        ]), legacyText: "legacy", legacyReasoning: "thought")
        XCTAssertEqual(malformed?.envelope.parts.map(\.kind),
                       [.reasoning, .text, .malformed])
        XCTAssertNil(TranscriptPartsCodec.update(from: .object(["text": .string("legacy")])))

        let badMode = try XCTUnwrap(TranscriptPartsCodec.update(
            from: payload([part("text", text: "wire")], mode: "merge"),
            legacyText: "legacy", defaultMode: .append))
        XCTAssertEqual(badMode.mode, .append)
        XCTAssertTrue(badMode.envelope.clipped)
        XCTAssertEqual(badMode.envelope.parts.first?.text, "legacy")
    }

    func testAppendReplaceSealAndLongStableStreamCoalescing() throws {
        var current: TranscriptPartsEnvelope?
        for index in 0..<200 {
            let update = try XCTUnwrap(TranscriptPartsCodec.update(from: payload([
                part("text", text: "\(index),", id: "assistant-stream"),
            ], mode: "append")))
            current = TranscriptPartsCodec.apply(update, to: current)
        }
        XCTAssertEqual(current?.parts.count, 1)
        XCTAssertEqual(current?.parts[0].text,
                       (0..<200).map { "\($0)," }.joined())
        XCTAssertFalse(current?.clipped ?? true)

        let seal = try XCTUnwrap(TranscriptPartsCodec.update(from: payload([
            part("text", text: "duplicate", id: "assistant-stream"),
        ], mode: "seal")))
        XCTAssertEqual(TranscriptPartsCodec.apply(seal, to: current), current)
        let replace = try XCTUnwrap(TranscriptPartsCodec.update(from: payload([
            part("text", text: "final", id: "assistant-final"),
        ], mode: "replace")))
        XCTAssertEqual(TranscriptPartsCodec.apply(replace, to: current).parts[0].text, "final")
    }

    func testPartCountDepthAndScalarBoundsExposeClipping() throws {
        let many = (0..<100).map { part("text", text: "\($0)", id: "id-\($0)") }
        let envelope = try XCTUnwrap(TranscriptPartsCodec.update(from: payload(many)))
            .envelope
        XCTAssertLessThanOrEqual(envelope.parts.count, TranscriptPartsCodec.maximumParts)
        XCTAssertTrue(envelope.clipped)
        XCTAssertEqual(envelope.parts.last?.kind, .clipped)

        var nested: JSONValue = .string("leaf")
        for _ in 0...TranscriptPartsCodec.maximumDepth { nested = .array([nested]) }
        let deep = try XCTUnwrap(TranscriptPartsCodec.update(from: payload([
            .object(["kind": .string("tool-result"), "value": nested]),
        ]))).envelope
        XCTAssertTrue(deep.clipped)

        let huge = String(repeating: "界", count: TranscriptPartsCodec.maximumStringScalars + 1)
        let bounded = try XCTUnwrap(TranscriptPartsCodec.update(from: payload([
            part("text", text: huge),
        ]))).envelope
        XCTAssertTrue(bounded.clipped)
        XCTAssertLessThanOrEqual(bounded.parts[0].text?.unicodeScalars.count ?? 0,
                                 TranscriptPartsCodec.maximumStringScalars)
    }

    func testCanonicalCodableAndChatMessageRoundTripPreserveWireFields() throws {
        let envelope = try XCTUnwrap(TranscriptPartsCodec.update(from: payload([
            .object([
                "kind": .string("unknown"), "source_type": .string("future-kind"),
                "id": .string("x"),
                "mime_type": .string("application/x-test"),
                "content_kind": .string("opaque"),
                "completed_at": .number(42), "evidence": .string("retained"),
            ]),
        ]))).envelope
        let message = ChatMessage(author: .bot, text: "legacy", orderedParts: envelope)
        let decoded = try JSONDecoder().decode(
            ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded, message)
        let roundTrip = try XCTUnwrap(decoded.orderedParts?.parts.first)
        XCTAssertEqual(roundTrip.sourceKind, "future-kind")
        XCTAssertEqual(roundTrip.mimeType, "application/x-test")
        XCTAssertEqual(roundTrip.contentKind, "opaque")
        XCTAssertEqual(roundTrip.completedAt, 42)

        let json = try XCTUnwrap(try JSONValue.from(decoded.orderedParts))
        let rawPart = try XCTUnwrap(json["parts"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(rawPart["kind"]?.stringValue, "unknown")
        XCTAssertEqual(rawPart["source_type"]?.stringValue, "future-kind")
        XCTAssertEqual(rawPart["mime_type"]?.stringValue, "application/x-test")
        XCTAssertNil(rawPart["mimeType"])

        let defensiveEnvelope = try XCTUnwrap(TranscriptPartsCodec.update(from: payload([
            .object(["kind": .string("even-newer-kind")]),
        ]))).envelope
        let defensive = try XCTUnwrap(defensiveEnvelope.parts.first)
        XCTAssertEqual(defensive.kind, .unknown)
        XCTAssertEqual(defensive.sourceKind, "even-newer-kind")
    }

    func testOrderedProjectionPairsExactToolOnceAndPreservesOrder() {
        let call = ToolCall(id: "local", name: "terminal", context: "x",
                            state: .done, gatewayToolID: "call-1")
        let envelope = TranscriptPartsEnvelope(parts: [
            TranscriptPart(kind: .reasoning, text: "think"),
            TranscriptPart(kind: .text, text: "before"),
            TranscriptPart(kind: .toolCall, id: "call-1", name: "terminal"),
            TranscriptPart(kind: .toolResult, id: "call-1", name: "terminal"),
            TranscriptPart(kind: .text, text: "after"),
        ])
        XCTAssertEqual(OrderedTranscriptPresentation.project(envelope, toolCalls: [call]), [
            .reasoning("think"), .text("before"), .tools([call]), .text("after"),
        ])
    }

    func testLegacyProjectionWinsForMediaAndGeneratedEchoCompatibility() {
        let media = TranscriptPartsEnvelope(parts: [
            TranscriptPart(kind: .text, text: "before MEDIA:/tmp/a.png after"),
            TranscriptPart(kind: .toolCall, id: "x"),
        ])
        XCTAssertFalse(OrderedTranscriptPresentation.shouldRenderOrdered(
            media, legacyText: "before MEDIA:/tmp/a.png after",
            projectedVisibleText: "before MEDIA:/tmp/a.png after"))
        let echo = TranscriptPartsEnvelope(parts: [
            TranscriptPart(kind: .text, text: "prose /tmp/generated.png"),
            TranscriptPart(kind: .toolCall, id: "x"),
        ])
        XCTAssertFalse(OrderedTranscriptPresentation.shouldRenderOrdered(
            echo, legacyText: "prose /tmp/generated.png", projectedVisibleText: "prose "))
    }

    func testTypedLiveToolAndRetainedUserPartsDecodeWithoutGrantingReferenceAuthority() throws {
        let toolStart = TypedGatewayEvent(GatewayEvent(
            type: "tool.start", sessionID: "s", payload: payload([
                part("tool-call", id: "call-1"),
            ], mode: "append")))
        guard case .toolStart(let start) = toolStart else {
            return XCTFail("expected tool start")
        }
        XCTAssertEqual(start.parts?.envelope.parts.first?.kind, .toolCall)

        let toolComplete = TypedGatewayEvent(GatewayEvent(
            type: "tool.complete", sessionID: "s", payload: .object([
                "id": .string("call-1"), "name": .string("terminal"),
                "result": .object(["stdout": .string("ok")]),
                "parts_version": .number(1), "parts_mode": .string("append"),
                "parts": .array([.object([
                    "kind": .string("tool-result"), "id": .string("call-1"),
                    "value": .object(["stdout": .string("ok")]),
                ])]),
            ])))
        guard case .toolComplete(let complete) = toolComplete else {
            return XCTFail("expected tool complete")
        }
        XCTAssertEqual(complete.parts?.envelope.parts.first?.value?["stdout"]?.stringValue,
                       "ok")

        let retained = try XCTUnwrap(RetainedInflightTurn(.object([
            "user": .string("show"), "assistant": .string(""),
            "streaming": .bool(true),
            "user_parts": .array([.object([
                "kind": .string("image"),
                "ref": .string("https://example.test/inert.png"),
            ])]),
            "user_parts_clipped": .bool(false),
        ])))
        XCTAssertEqual(retained.userParts?.parts.first?.kind, .image)
        XCTAssertEqual(retained.userParts?.parts.first?.ref,
                       "https://example.test/inert.png")
    }
}
