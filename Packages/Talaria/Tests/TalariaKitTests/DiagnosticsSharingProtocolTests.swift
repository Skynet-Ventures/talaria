import XCTest
@testable import TalariaKit

final class DiagnosticsSharingProtocolTests: XCTestCase {
    func testExactMethodTimeoutAndMobileOnlyParameters() {
        XCTAssertEqual(NousDiagnosticsSharingProtocol.method, "diagnostics.share_nous")
        XCTAssertEqual(NousDiagnosticsSharingProtocol.timeout, 120)
        XCTAssertEqual(
            NousDiagnosticsSharingProtocol.requestParameters(errorContext: nil),
            .object([:])
        )
        XCTAssertEqual(
            NousDiagnosticsSharingProtocol.requestParameters(errorContext: "  \n\t "),
            .object([:])
        )

        let params = NousDiagnosticsSharingProtocol.requestParameters(
            errorContext: "provider\u{202E}: boom\u{0}\nretry")
        XCTAssertEqual(params.objectValue?.keys.sorted(), ["error_context"])
        XCTAssertEqual(params["error_context"]?.stringValue, "provider: boom\nretry")
        XCTAssertNil(params["extra_files"])
        XCTAssertNil(params["log_lines"])
        XCTAssertNil(params["redact"])
    }

    func testContextAdmissionIsBoundedByRawWorkAndVisibleScalars() throws {
        let source = String(repeating: "x\u{1B}", count: 20_000) + "uninspected-tail"
        let params = NousDiagnosticsSharingProtocol.requestParameters(errorContext: source)
        let admitted = try XCTUnwrap(params["error_context"]?.stringValue)
        XCTAssertLessThanOrEqual(admitted.unicodeScalars.count, 8_000)
        XCTAssertTrue(admitted.hasSuffix("\n… [diagnostic context clipped]"))
        XCTAssertFalse(admitted.contains("uninspected-tail"))
        XCTAssertFalse(admitted.unicodeScalars.contains(where: { $0.value == 0x1B }))
    }

    func testStrictSuccessReceiptAdmitsNousHTTPSViewerOrOpaqueID() throws {
        let receipt = try NousDiagnosticsSharingProtocol.decodeReceipt([
            "ok": true,
            "view_url": "https://portal.nousresearch.com/diagnostics/abc?token=signed",
            "upload_id": "diag_123",
            "expires_at": "2026-09-01T00:00:00Z",
            "future_field": 1,
        ])
        XCTAssertEqual(receipt.viewURL?.absoluteString,
                       "https://portal.nousresearch.com/diagnostics/abc?token=signed")
        XCTAssertEqual(receipt.uploadID, "diag_123")
        XCTAssertEqual(receipt.expiresAt, "2026-09-01T00:00:00Z")

        let idOnly = try NousDiagnosticsSharingProtocol.decodeReceipt([
            "ok": true, "view_url": nil, "upload_id": "diag_456", "expires_at": nil,
        ])
        XCTAssertNil(idOnly.viewURL)
        XCTAssertEqual(idOnly.uploadID, "diag_456")
    }

    func testFailureReceiptIsTypedSanitizedAndBounded() {
        let huge = String(repeating: "failure\u{202E}\u{1B}", count: 2_000)
        XCTAssertThrowsError(try NousDiagnosticsSharingProtocol.decodeReceipt([
            "ok": false, "error": .string(huge),
        ])) { error in
            guard case .rejected(let message) = error as? NousDiagnosticsShareError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertLessThanOrEqual(message.unicodeScalars.count, 2_048)
            XCTAssertTrue(message.hasSuffix("\n… [diagnostics error clipped]"))
            XCTAssertFalse(message.unicodeScalars.contains(where: {
                $0.value == 0x1B || $0.value == 0x202E
            }))
        }
    }

    func testMalformedAndLinklessReceiptsFailClosed() {
        let malformed: [JSONValue] = [
            .null,
            [],
            [:],
            ["ok": "true", "upload_id": "id"],
            ["ok": true],
            ["ok": true, "view_url": "https://portal.nousresearch.com/a", "error": "odd"],
            ["ok": true, "upload_id": 4],
            ["ok": true, "upload_id": " \n "],
            ["ok": false],
            ["ok": false, "error": false],
            ["ok": false, "error": "\u{1B}\u{202E}"],
        ]
        for value in malformed {
            XCTAssertThrowsError(try NousDiagnosticsSharingProtocol.decodeReceipt(value)) { error in
                guard case .malformedReceipt = error as? NousDiagnosticsShareError else {
                    return XCTFail("unexpected error for \(value): \(error)")
                }
            }
        }
    }

    func testViewerURLAdmissionRejectsUntrustedOrAmbiguousDestinations() {
        let accepted = [
            "https://nousresearch.com/view/1",
            "https://portal.nousresearch.com/view/1",
            "https://diagnostics.portal.nousresearch.com/view/1?token=a",
        ]
        for source in accepted {
            XCTAssertNotNil(NousDiagnosticsSharingProtocol.admittedViewURL(source), source)
        }

        let rejected = [
            "http://portal.nousresearch.com/view/1",
            "https://user:pass@portal.nousresearch.com/view/1",
            "https://portal.nousresearch.com.evil.example/view/1",
            "https://nousresearch.com@evil.example/view/1",
            "https://portal.nousresearch.com/line\nfeed",
            "https://portal.nousresearch.com/\u{202E}spoof",
            "https://127.0.0.1/view/1",
            "https://localhost/view/1",
            "javascript:alert(1)",
            String(repeating: "a", count: 2_049),
        ]
        for source in rejected {
            XCTAssertNil(NousDiagnosticsSharingProtocol.admittedViewURL(source), source)
        }
    }

    func testIdentityFieldsCannotBeClippedOrControlSanitizedIntoReferences() {
        for value: JSONValue in [
            ["ok": true, "upload_id": .string(String(repeating: "a", count: 257))],
            ["ok": true, "upload_id": "abc\u{202E}def"],
            ["ok": true, "upload_id": "abc\ndef"],
            ["ok": true, "upload_id": "abc\u{2028}def"],
            ["ok": true, "upload_id": "abc", "expires_at": .string(String(repeating: "e", count: 257))],
            ["ok": true, "upload_id": "abc", "expires_at": "x\u{0}y"],
        ] {
            XCTAssertThrowsError(try NousDiagnosticsSharingProtocol.decodeReceipt(value))
        }
    }

    func testMethodNotFoundRemainsASeparateGatewayErrorContract() {
        let unsupported = GatewayError(code: -32601, message: "Method not found")
        XCTAssertEqual(unsupported.code, -32601)
    }
}
