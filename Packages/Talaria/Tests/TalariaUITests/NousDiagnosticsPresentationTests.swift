#if canImport(XCTest)
import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class NousDiagnosticsPresentationTests: XCTestCase {
    func testFailedTurnActionIsExplicitAndOptIn() {
        let failure = TurnFailure(message: "failed", recoverable: true)
        XCTAssertFalse(FailedTurnCardPolicy.actions(
            for: failure, canRetry: false).contains(.sendDiagnostics))
        XCTAssertEqual(FailedTurnCardPolicy.actions(
            for: failure, canRetry: false, canDismiss: true,
            canSendDiagnostics: true), [.copy, .sendDiagnostics, .dismiss])
        XCTAssertEqual(FailedTurnCardPolicy.accessibilityLabel(for: .sendDiagnostics),
                       "Send private diagnostics to Nous")
    }

    func testConsentTruthfullyNamesPrivateScopeReadersRetentionAndLogBounds() {
        let disclosure = NousDiagnosticsConsentPolicy.disclosure
        XCTAssertTrue(disclosure.contains("privately inside Nous"))
        XCTAssertTrue(disclosure.contains("host’s OS"))
        XCTAssertTrue(disclosure.contains("software versions"))
        XCTAssertTrue(disclosure.contains("provider"))
        XCTAssertTrue(disclosure.contains("which API keys are configured"))
        XCTAssertTrue(disclosure.contains("never the key values"))
        XCTAssertTrue(disclosure.contains("512 KB"))
        XCTAssertTrue(disclosure.contains("agent.log"))
        XCTAssertTrue(disclosure.contains("gateway.log"))
        XCTAssertTrue(disclosure.contains("desktop.log"))
        XCTAssertTrue(disclosure.contains("conversation content"))
        XCTAssertTrue(disclosure.contains("tool output"))
        XCTAssertTrue(disclosure.contains("file paths"))
        XCTAssertTrue(disclosure.contains("Secrets are redacted"))
        XCTAssertTrue(disclosure.contains("Nous staff"))
        XCTAssertTrue(disclosure.contains("allowlisted Discord moderators"))
        XCTAssertTrue(disclosure.contains("14 days"))
    }

    func testMobileBoundaryDoesNotMisrepresentGatewayDesktopLog() {
        let boundary = NousDiagnosticsConsentPolicy.mobileBoundary
        XCTAssertTrue(boundary.contains("only the bounded error context"))
        XCTAssertTrue(boundary.contains("does not upload log files from this iPhone"))
        XCTAssertTrue(boundary.contains("desktop.log from the gateway host"))
    }

    func testFailureCopyDoesNotClaimMalformedReceiptMeansNoUpload() {
        XCTAssertEqual(NousDiagnosticsConsentPolicy.failureTitle(.unsupported),
                       "Not supported")
        XCTAssertEqual(NousDiagnosticsConsentPolicy.failureTitle(.malformedResponse),
                       "Upload failed")
        let malformed = NousDiagnosticsConsentPolicy.failureMessage(.malformedResponse)
        XCTAssertTrue(malformed.contains("receipt that could not be verified"))
        XCTAssertTrue(malformed.contains("No link was opened"))
        XCTAssertFalse(malformed.localizedCaseInsensitiveContains("nothing was uploaded"))
        XCTAssertFalse(malformed.localizedCaseInsensitiveContains("nothing was shared"))

        let hostile = NousDiagnosticsConsentPolicy.failureMessage(
            .connection("safe\u{202E}spoof\u{0000}\nnext"))
        XCTAssertEqual(hostile, "safespoof\nnext")
    }

    func testSuccessAndAccessibilityExposeOnlyAdmittedReceiptProjection() {
        let receipt = NousDiagnosticsShareReceipt(
            viewURL: URL(string: "https://portal.nousresearch.com/d/abc")!,
            uploadID: "safe-upload", expiresAt: "2040-01-01T00:00:00Z")
        XCTAssertEqual(NousDiagnosticsConsentPolicy.successReference(receipt),
                       "Upload ID: safe-upload")
        XCTAssertEqual(NousDiagnosticsConsentPolicy.accessibilityStatus(
            for: .success(receipt)),
            "Diagnostics upload complete. Upload ID: safe-upload")

        let linkOnly = NousDiagnosticsShareReceipt(
            viewURL: URL(string: "https://portal.nousresearch.com/d/abc")!,
            uploadID: nil, expiresAt: nil)
        XCTAssertEqual(NousDiagnosticsConsentPolicy.successReference(linkOnly),
                       "Private receipt: portal.nousresearch.com")
    }

    func testControlsMeetMobileHitTarget() {
        XCTAssertGreaterThanOrEqual(NousDiagnosticsConsentPolicy.controlHitTarget, 44)
        XCTAssertEqual(NousDiagnosticsConsentPolicy.githubIssuesURL.absoluteString,
                       "https://github.com/NousResearch/hermes-agent/issues")
        XCTAssertEqual(NousDiagnosticsConsentPolicy.portalHelpURL.absoluteString,
                       "https://portal.nousresearch.com/help")
        XCTAssertEqual(NousDiagnosticsConsentPolicy.discordURL.absoluteString,
                       "https://discord.gg/NousResearch")
    }
}
#endif
