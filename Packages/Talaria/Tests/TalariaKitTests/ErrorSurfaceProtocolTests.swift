#if canImport(XCTest)
import XCTest
@testable import TalariaKit

final class ErrorSurfaceProtocolTests: XCTestCase {
    private func complete(_ surface: JSONValue?, status: JSONValue = "error",
                          partial: JSONValue? = nil) -> MessageCompletePayload {
        var payload: [String: JSONValue] = ["status": status, "error": "boom"]
        if let surface { payload["error_surface"] = surface }
        if let partial { payload["partial"] = partial }
        return MessageCompletePayload(.object(payload))
    }

    func testAdmitsAllExactLayersAndIdentity() {
        for layer in TurnErrorSurface.Layer.allCases {
            let payload = complete([
                "layer": .string(layer.rawValue), "code": "rate_limit",
                "retryable": false, "provider": "openrouter", "model": "test/m1"
            ])
            XCTAssertEqual(payload.errorSurface,
                           TurnErrorSurface(layer: layer, code: "rate_limit", retryable: false,
                                            provider: "openrouter", model: "test/m1"))
            XCTAssertFalse(payload.errorSurfaceAdmission.isMalformed)
        }
    }

    func testDistinguishesAbsentNullAndMalformedSurface() {
        if case .absent = complete(nil).errorSurfaceAdmission {} else { XCTFail("omitted") }
        if case .absent = complete(.null).errorSurfaceAdmission {} else { XCTFail("null") }
        for malformed: JSONValue in [
            "provider", [], ["layer": "unknown", "code": "x", "retryable": true]
        ] {
            XCTAssertTrue(complete(malformed).errorSurfaceAdmission.isMalformed)
        }

        for compatible: JSONValue in [
            ["layer": "gateway"],
            ["layer": "gateway", "code": 7, "retryable": "yes"],
            ["layer": "gateway", "code": "", "retryable": true,
             "provider": .null, "model": ""]
        ] {
            let payload = complete(compatible)
            XCTAssertEqual(payload.errorSurface?.code, "unknown")
            XCTAssertEqual(payload.errorSurface?.retryable, true)
            XCTAssertNil(payload.errorSurface?.provider)
            XCTAssertNil(payload.errorSurface?.model)
        }
    }

    func testBoundsAndRejectsControlOrBidiIdentityWithoutScanningWholeValue() {
        let huge = String(repeating: "x", count: TurnErrorSurface.maximumCodeScalars + 1)
        for unsafe in [huge, "\u{1B}[31mspoof", "safe\u{202E}txt", "\n"] {
            XCTAssertTrue(complete([
                "layer": "gateway", "code": .string(unsafe), "retryable": true
            ]).errorSurfaceAdmission.isMalformed)
        }
        let identity = String(repeating: "m", count: TurnErrorSurface.maximumIdentityScalars + 1)
        XCTAssertNil(complete([
            "layer": "provider", "code": "x", "retryable": true, "model": .string(identity)
        ]).errorSurface?.model)
    }

    func testCompletionStatusAndPartialAreFailClosed() {
        XCTAssertEqual(complete(nil).status, .error)
        XCTAssertEqual(complete(nil, status: "future").status, .malformed)
        XCTAssertEqual(MessageCompletePayload(nil).status, .complete)
        XCTAssertEqual(MessageCompletePayload(["text": "legacy success"]).status, .complete)
        XCTAssertEqual(MessageCompletePayload(["status": 7]).status, .malformed)
        XCTAssertFalse(complete(nil, partial: "yes").partial)
        XCTAssertTrue(complete(nil, partial: true).partial)
    }

    func testRetainedInflightCarriesExactFailureAndMalformedEvidence() throws {
        let raw: JSONValue = [
            "session_id": "runtime", "messages": [], "running": false,
            "info": [:],
            "inflight": [
                "user": "prompt", "assistant": "partial", "streaming": false,
                "corrections": ["first", "second"], "correction_offsets": [2, 7],
                "status": "error", "error": "rate limited", "recoverable": true,
                "error_surface": ["layer": "provider", "code": "rate_limit",
                                  "retryable": false]
            ]
        ]
        let live = LiveSession(raw)
        XCTAssertEqual(live.retainedInflight?.status, .error)
        XCTAssertEqual(live.retainedInflight?.error, "rate limited")
        XCTAssertEqual(live.retainedInflight?.errorSurface?.retryable, false)
        XCTAssertEqual(live.retainedInflight?.corrections, ["first", "second"])
        XCTAssertEqual(live.retainedInflight?.correctionOffsets, [2, 7])
        XCTAssertFalse(live.retainedInflight?.correctionsMalformed ?? true)

        let malformed = LiveSession([
            "session_id": "runtime", "messages": [], "running": false, "info": [:],
            "inflight": ["status": "error", "error": "boom",
                         "error_surface": ["layer": "not-a-layer"]]
        ])
        XCTAssertTrue(malformed.retainedInflight?.errorSurfaceAdmission.isMalformed == true)

        let absent = LiveSession(["session_id": "runtime", "messages": [],
                                  "running": false, "info": [:]])
        if case .absent = absent.retainedInflightAdmission {} else { XCTFail("absent") }
        let badRoot = LiveSession(["session_id": "runtime", "messages": [],
                                   "running": false, "info": [:], "inflight": "bad"])
        if case .malformed = badRoot.retainedInflightAdmission {} else { XCTFail("malformed") }
    }

    func testRetainedInflightBoundsCorrectionsAndRejectsMalformedOffsets() {
        let tooLong = String(repeating: "x", count: RetainedInflightTurn.maximumCorrectionScalars + 1)
        let live = LiveSession([
            "session_id": "runtime", "messages": [], "running": true, "info": [:],
            "inflight": ["corrections": [.string("safe"), .string(tooLong)],
                         "correction_offsets": [1, 1.5]]
        ])
        XCTAssertEqual(live.retainedInflight?.corrections.count, 2)
        XCTAssertEqual(live.retainedInflight?.corrections.first, "safe")
        XCTAssertTrue(live.retainedInflight?.corrections.last?
            .contains("correction clipped") == true)
        XCTAssertLessThanOrEqual(live.retainedInflight?.corrections.last?
            .unicodeScalars.count ?? .max, RetainedInflightTurn.maximumCorrectionScalars)
        XCTAssertNil(live.retainedInflight?.correctionOffsets)
        XCTAssertTrue(live.retainedInflight?.correctionsMalformed == true)

        let many = Array(repeating: JSONValue.string("n"),
                         count: RetainedInflightTurn.maximumCorrections + 1)
        let bounded = LiveSession([
            "session_id": "runtime", "messages": [], "running": true, "info": [:],
            "inflight": .object(["corrections": .array(many)])
        ])
        XCTAssertEqual(bounded.retainedInflight?.corrections.count,
                       RetainedInflightTurn.maximumCorrections)
        XCTAssertTrue(bounded.retainedInflight?.correctionsMalformed == true)
        XCTAssertEqual(bounded.retainedInflight?.corrections.last,
                       "[2 additional corrections omitted]")
    }

    func testOversizedCorrectionPreservesOrderAndCardinalityButRejectsOffsets() throws {
        let hostile = String(repeating: "\u{001B}\u{202E}", count: 1_000)
            + String(repeating: "x", count: 5_000)
        let live = LiveSession([
            "session_id": "runtime", "messages": [], "running": true, "info": [:],
            "inflight": [
                "corrections": ["first", .string(hostile), "third"],
                "correction_offsets": [1, 2, 3]
            ]
        ])
        let retained = try XCTUnwrap(live.retainedInflight)
        XCTAssertEqual(retained.corrections.count, 3)
        XCTAssertEqual(retained.corrections.first, "first")
        XCTAssertEqual(retained.corrections.last, "third")
        XCTAssertTrue(retained.corrections[1].contains("correction clipped"))
        XCTAssertLessThanOrEqual(retained.corrections[1].unicodeScalars.count,
                                 RetainedInflightTurn.maximumCorrectionScalars)
        XCTAssertFalse(retained.corrections[1].unicodeScalars.contains {
            $0.value == 0x1B || $0.value == 0x202E
        })
        XCTAssertEqual(retained.correctionOffsets, [1, 2, 3],
                       "typed evidence retains valid offsets for diagnostics")
        XCTAssertTrue(retained.correctionsMalformed,
                      "projection must conservatively ignore offsets after clipping")
    }

    func testControlsOnlyCorrectionRemainsVisibleAndDisablesOffsets() throws {
        let live = LiveSession([
            "session_id": "runtime", "messages": [], "running": true, "info": [:],
            "inflight": [
                "corrections": ["first", "\u{001B}\u{202E}\u{0000}", "third"],
                "correction_offsets": [1, 2, 3]
            ]
        ])
        let retained = try XCTUnwrap(live.retainedInflight)
        XCTAssertEqual(retained.corrections,
                       ["first", "[correction content removed]", "third"])
        XCTAssertEqual(retained.correctionOffsets, [1, 2, 3])
        XCTAssertTrue(retained.correctionsMalformed,
                      "projection must ignore offsets after removing unsafe content")
    }

    func testCorrectionOverflowUsesFinalSlotAsTruthfulSummary() throws {
        let corrections = (1...35).map { JSONValue.string("correction \($0)") }
        let offsets = (1...35).map { JSONValue.number(Double($0)) }
        let live = LiveSession([
            "session_id": "runtime", "messages": [], "running": true, "info": [:],
            "inflight": .object([
                "corrections": .array(corrections), "correction_offsets": .array(offsets)
            ])
        ])
        let retained = try XCTUnwrap(live.retainedInflight)
        XCTAssertEqual(retained.corrections.count, RetainedInflightTurn.maximumCorrections)
        XCTAssertEqual(retained.corrections[30], "correction 31")
        XCTAssertEqual(retained.corrections[31], "[4 additional corrections omitted]")
        XCTAssertNil(retained.correctionOffsets)
        XCTAssertTrue(retained.correctionsMalformed)
    }

    func testRetainedInflightBoundsAndSanitizesPrimaryBodiesBeforeProjection() throws {
        let controls = String(repeating: "\u{001B}\u{0000}\u{202E}", count: 3_000)
        let combining = "a" + String(repeating: "\u{0301}", count: 70_000)
        let hugeError = controls + String(repeating: "e", count: 40_000)
        let live = LiveSession([
            "session_id": "runtime", "messages": [], "running": false, "info": [:],
            "inflight": [
                "user": .string(controls + "safe user"),
                "assistant": .string(combining),
                "status": "error", "error": .string(hugeError)
            ]
        ])
        let retained = try XCTUnwrap(live.retainedInflight)
        XCTAssertEqual(retained.user, "safe user")
        XCTAssertLessThanOrEqual(retained.assistant?.unicodeScalars.count ?? .max,
                                 RetainedInflightTurn.maximumAssistantScalars)
        XCTAssertTrue(retained.assistant?.contains("turn detail clipped") == true)
        XCTAssertLessThanOrEqual(retained.error?.unicodeScalars.count ?? .max,
                                 RetainedInflightTurn.maximumErrorScalars)
        XCTAssertTrue(retained.error?.contains("turn detail clipped") == true)
        for value in [retained.user, retained.assistant, retained.error].compactMap({ $0 }) {
            XCTAssertFalse(value.unicodeScalars.contains {
                $0.value == 0 || $0.value == 0x1B || $0.value == 0x202E
            })
        }
    }

    func testChatMessageFailureCodableRemainsBackwardCompatible() throws {
        let old = #"{"id":"00000000-0000-0000-0000-000000000001","author":"bot","text":"hi","isStreaming":false,"toolCalls":[]}"#
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: Data(old.utf8))
        XCTAssertNil(decoded.failure)

        let message = ChatMessage(author: .bot, text: "partial", failure: TurnFailure(
            message: "rate limited", recoverable: true,
            errorSurface: TurnErrorSurface(layer: .provider, code: "rate_limit",
                                           retryable: false)))
        XCTAssertEqual(try JSONDecoder().decode(ChatMessage.self,
                                                from: JSONEncoder().encode(message)), message)

        let unsafe = #"{"layer":"provider","code":"safe\u202Espoof","retryable":true}"#
        XCTAssertThrowsError(try JSONDecoder().decode(TurnErrorSurface.self,
                                                       from: Data(unsafe.utf8)))
    }

    func testTurnFailureCodableSanitizesAndBoundsImportedSnapshotMessage() throws {
        let controls = String(repeating: "\u{001B}\u{0000}\u{202E}", count: 3_000)
        let safeTail = "safe\tline\nnext"
        let data = try JSONEncoder().encode(JSONValue.object([
            "message": .string(controls + safeTail), "recoverable": true
        ]))
        let decoded = try JSONDecoder().decode(TurnFailure.self, from: data)
        XCTAssertEqual(decoded.message, safeTail)
        XCTAssertTrue(decoded.recoverable)
        XCTAssertFalse(decoded.message.unicodeScalars.contains {
            $0.value == 0 || $0.value == 0x1B || $0.value == 0x202E
        })

        let combining = "a" + String(repeating: "\u{0301}", count: 40_000)
        let bounded = try JSONDecoder().decode(
            TurnFailure.self, from: JSONEncoder().encode(JSONValue.object([
                "message": .string(combining), "recoverable": false
            ])))
        XCTAssertLessThanOrEqual(bounded.message.unicodeScalars.count,
                                 TurnFailureMessageCodec.maximumVisibleScalars)
        XCTAssertTrue(bounded.message.contains("turn detail clipped"))

        let beyondRawCap = String(repeating: "\u{001B}",
                                  count: TurnFailureMessageCodec.maximumVisibleScalars * 4 + 1)
            + "hidden tail"
        let clipped = try JSONDecoder().decode(
            TurnFailure.self,
            from: JSONEncoder().encode(JSONValue.object([
                "message": .string(beyondRawCap), "recoverable": true
            ])))
        XCTAssertEqual(clipped.message, TurnFailureMessageCodec.clippedMarker)

        let roundTrip = TurnFailure(message: controls + "encoded safe", recoverable: true)
        XCTAssertEqual(try JSONDecoder().decode(
            TurnFailure.self, from: JSONEncoder().encode(roundTrip)).message, "encoded safe")
    }
}
#endif
