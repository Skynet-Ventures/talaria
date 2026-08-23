#if canImport(XCTest)
import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class FailedTurnPresentationTests: XCTestCase {
    func testExactLayerLabelsAndGenericFallback() {
        let expected: [TurnErrorSurface.Layer: String] = [
            .provider: "Provider error",
            .endpoint: "Custom endpoint error",
            .streaming: "Streaming connection error",
            .auth: "Authentication error",
            .billing: "Out of credits",
            .gateway: "Gateway error",
            .runtime: "Local runtime error",
            .disk: "Disk full",
        ]
        for (layer, title) in expected {
            let surface = TurnErrorSurface(layer: layer, code: "x", retryable: true)
            XCTAssertEqual(FailedTurnCardPolicy.title(for: surface), title)
        }
        XCTAssertEqual(FailedTurnCardPolicy.title(for: nil), "Turn failed")
    }

    func testActionPolicyHonorsClassifierAndLayer() {
        func failure(_ layer: TurnErrorSurface.Layer?, retryable: Bool = true) -> TurnFailure {
            TurnFailure(message: "boom", recoverable: true,
                        errorSurface: layer.map {
                            TurnErrorSurface(layer: $0, code: "x", retryable: retryable)
                        })
        }

        XCTAssertEqual(FailedTurnCardPolicy.actions(
            for: failure(nil), canRetry: true), [.retry, .copy, .dismiss])
        XCTAssertEqual(FailedTurnCardPolicy.actions(
            for: failure(.provider), canRetry: true),
                       [.retry, .settings, .copy, .dismiss])
        XCTAssertEqual(FailedTurnCardPolicy.actions(
            for: failure(.auth, retryable: false), canRetry: true),
                       [.settings, .copy, .dismiss])
        XCTAssertEqual(FailedTurnCardPolicy.actions(
            for: failure(.streaming), canRetry: false), [.copy, .dismiss])
        XCTAssertEqual(FailedTurnCardPolicy.actions(
            for: failure(.streaming), canRetry: false, canDismiss: false), [.copy])

        for layer in TurnErrorSurface.Layer.allCases {
            XCTAssertEqual(FailedTurnCardPolicy.showsSettings(for:
                TurnErrorSurface(layer: layer, code: "x", retryable: true)),
                [.provider, .endpoint, .auth, .billing].contains(layer))
        }
    }

    @MainActor
    func testExactRetryOwnerHidesDismissThroughPreparedAndSubmittingPhases() throws {
        let model = AppModel()
        model.mode = .live
        let botID = "primary::worker"
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let failed = ChatMessage(
            author: .bot, text: "partial",
            failure: TurnFailure(message: "failed", recoverable: true))
        let user = ChatMessage(author: .user, text: "retry", rowID: 1)
        chat.messages = [user, failed]

        let request = try XCTUnwrap(model.prepareFailedTurnRetry(failed, in: botID))
        XCTAssertFalse(model.canDismissFailedTurn(failed, in: botID))
        XCTAssertFalse(FailedTurnCardPolicy.actions(
            for: try XCTUnwrap(failed.failure), canRetry: false,
            canDismiss: model.canDismissFailedTurn(failed, in: botID)).contains(.dismiss))

        XCTAssertTrue(model.applyFailedRetryAuthoritativeBaseline(
            request, in: botID, rows: [user]))
        XCTAssertTrue(model.admitFailedTurnRetrySubmission(request, in: botID))
        XCTAssertFalse(model.canDismissFailedTurn(failed, in: botID))

        model.settleFailedTurnRetry(request, result: .failed, in: botID, chat: chat)
        XCTAssertTrue(model.canDismissFailedTurn(failed, in: botID))
    }

    func testCapturedIdentityAndDiagnosticsNeverUseForegroundState() {
        let failure = TurnFailure(
            message: "rate limited", recoverable: true,
            errorSurface: TurnErrorSurface(
                layer: .provider, code: "rate_limit", retryable: false,
                provider: "openrouter", model: "failed/model"))
        XCTAssertEqual(FailedTurnCardPolicy.identity(for: failure.errorSurface),
                       "openrouter · failed/model")

        let details = FailedTurnCardPolicy.diagnostics(
            for: failure, appVersion: "1.2.3",
            now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(details.contains("layer: provider"))
        XCTAssertTrue(details.contains("code: rate_limit"))
        XCTAssertTrue(details.contains("retryable: false"))
        XCTAssertTrue(details.contains("provider: openrouter"))
        XCTAssertTrue(details.contains("model: failed/model"))
        XCTAssertTrue(details.contains("app: 1.2.3"))
        XCTAssertTrue(details.contains("error: rate limited"))
    }

    func testDiagnosticsEscapeUntrustedLineStructure() {
        let failure = TurnFailure(
            message: "boom\nprovider: attacker\rretryable: true\u{2028}model: spoof\\path",
            recoverable: true)

        let details = FailedTurnCardPolicy.diagnostics(
            for: failure, now: Date(timeIntervalSince1970: 0))

        XCTAssertFalse(details.contains("\nprovider: attacker"))
        XCTAssertFalse(details.contains("\nretryable: true"))
        XCTAssertFalse(details.contains("\nmodel: spoof"))
        XCTAssertTrue(details.contains(
            #"error: boom\nprovider: attacker\rretryable: true\u{2028}model: spoof\\path"#))
    }

    func testAccessibilitySummaryNamesLayerIdentityAndError() {
        let failure = TurnFailure(
            message: "connection reset", recoverable: true,
            errorSurface: TurnErrorSurface(
                layer: .streaming, code: "stream_drop", retryable: true,
                provider: "custom:lab", model: "local-model"))
        XCTAssertEqual(FailedTurnCardPolicy.accessibilitySummary(for: failure),
                       "Streaming connection error. custom:lab · local-model. connection reset")
    }

    func testErrorDisplayIsScalarBoundedAndReportsTruncation() {
        let exact = String(repeating: "x", count: FailedTurnCardPolicy.maximumDisplayedErrorScalars)
        XCTAssertEqual(FailedTurnCardPolicy.displayedMessage(exact), exact)

        let combining = "a" + String(repeating: "\u{0301}",
                                     count: FailedTurnCardPolicy.maximumDisplayedErrorScalars + 500)
        let bounded = FailedTurnCardPolicy.displayedMessage(combining)
        XCTAssertTrue(bounded.hasSuffix("…error detail truncated"))
        XCTAssertLessThanOrEqual(bounded.unicodeScalars.count,
                                 FailedTurnCardPolicy.maximumDisplayedErrorScalars + 25)

        let spoken = FailedTurnCardPolicy.accessibilitySummary(for:
            TurnFailure(message: combining, recoverable: true))
        XCTAssertTrue(spoken.hasSuffix("Error detail truncated"))
        XCTAssertLessThanOrEqual(spoken.unicodeScalars.count,
                                 FailedTurnCardPolicy.maximumSpokenErrorScalars + 50)
    }

    func testMobileControlsAndAccessibilityLayoutPolicy() {
        XCTAssertGreaterThanOrEqual(FailedTurnCardPolicy.controlHitTarget, 44)
        XCTAssertEqual(FailedTurnCardPolicy.actionLayout(isAccessibilitySize: false), .wrapping)
        XCTAssertEqual(FailedTurnCardPolicy.actionLayout(isAccessibilitySize: true), .vertical)
        XCTAssertTrue(FailedTurnCardPolicy.allowsOrdinaryAssistantActions(for: nil))
        XCTAssertFalse(FailedTurnCardPolicy.allowsOrdinaryAssistantActions(for:
            TurnFailure(message: "failed", recoverable: true)))
        XCTAssertEqual(FailedTurnCardPolicy.accessibilityLabel(for: .settings),
                       "Open Settings")
        XCTAssertEqual(FailedTurnCardPolicy.accessibilityLabel(for: .copy, copied: true),
                       "Error details copied")
    }
}
#endif
