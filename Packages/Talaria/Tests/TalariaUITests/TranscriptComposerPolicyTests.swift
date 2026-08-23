#if canImport(XCTest)
import Foundation
import Observation
import XCTest
@testable import TalariaKit
@testable import TalariaTheme
@testable import TalariaUI

final class TranscriptComposerPolicyTests: XCTestCase {
    @MainActor
    func testTranscriptPreferenceDefaultsPersistsAndResetsLocally() {
        let suite = "talaria.tests.transcript.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = TalariaSettingsStore(defaults: defaults)
        XCTAssertEqual(first.transcriptDetail, .quiet)
        first.transcriptDetail = .advanced
        XCTAssertEqual(TalariaSettingsStore(defaults: defaults).transcriptDetail, .advanced)

        first.resetToDefaults()
        XCTAssertEqual(first.transcriptDetail, .quiet)
        XCTAssertEqual(defaults.string(forKey: TalariaSettingsStore.transcriptDetailKey), "quiet")
    }

    func testQuietPresentationHidesAllToolDetails() {
        let calls = [
            ToolCall(id: "running", name: "read", context: "", state: .running),
            ToolCall(id: "done", name: "search", context: "", state: .done),
            ToolCall(id: "failed", name: "terminal", context: "", state: .failed),
        ]
        let quiet = TranscriptPresentationPolicy(detail: .quiet)
        XCTAssertTrue(quiet.visibleToolCalls(calls).isEmpty)
        XCTAssertFalse(quiet.showsReasoning(isLive: true))
        XCTAssertTrue(quiet.showsWorkingAvatar(isTurnRunning: true, hasLiveDetail: true))
    }

    func testAdvancedPresentationShowsAllDetailWithoutDuplicateLiveAvatar() {
        let calls = [
            ToolCall(id: "done", name: "search", context: "", state: .done),
            ToolCall(id: "failed", name: "terminal", context: "", state: .failed),
        ]
        let advanced = TranscriptPresentationPolicy(detail: .advanced)
        XCTAssertEqual(advanced.visibleToolCalls(calls), calls)
        XCTAssertTrue(advanced.showsReasoning(isLive: false))
        XCTAssertTrue(advanced.showsWorkingAvatar(isTurnRunning: true, hasLiveDetail: false))
        XCTAssertFalse(advanced.showsWorkingAvatar(isTurnRunning: true, hasLiveDetail: true))
    }

    @MainActor
    func testDuplicateToolStartIDCoalescesAndCompletesExactlyOnce() {
        let model = AppModel()
        model.mode = .live
        let runtime = LiveRuntime.shared
        let sessionID = "duplicate-tool-runtime"
        let botID = "worker"
        let previousGatewayID = runtime.gatewayID
        let previous = runtime.sessionToBot[sessionID]
        runtime.gatewayID = "primary"
        runtime.sessionToBot[sessionID] = botID
        model.chat(for: botID).sessionID = sessionID
        defer {
            runtime.sessionToBot[sessionID] = previous
            runtime.gatewayID = previousGatewayID
        }

        let start = GatewayEvent(
            type: "tool.start", sessionID: sessionID,
            payload: .object([
                "tool_id": .string("same-tool-id"),
                "name": .string("search"),
                "context": .string("first"),
            ]))
        model.routeToolEvent(start)
        model.routeToolEvent(GatewayEvent(
            type: "tool.start", sessionID: sessionID,
            payload: .object([
                "tool_id": .string("same-tool-id"),
                "name": .string("search"),
                "context": .string("updated"),
            ])))
        model.routeToolEvent(GatewayEvent(
            type: "tool.complete", sessionID: sessionID,
            payload: .object([
                "tool_id": .string("same-tool-id"),
                "name": .string("search"),
                "summary": .string("done"),
                "result": .object(["count": .number(1)]),
            ])))

        let calls = model.chat(for: botID).messages.flatMap(\.toolCalls)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.id, "same-tool-id")
        XCTAssertEqual(calls.first?.context, "updated")
        XCTAssertEqual(calls.first?.state, .done)
        XCTAssertEqual(calls.first?.summary, "done")
    }

    func testIdleAvatarKeepsIndependentBreatheAndGazeMotionWithoutWorkState() {
        let first = FacePose.at(.idle, t: 0, phase: 0)
        let later = FacePose.at(.idle, t: 1.25, phase: 0.8)
        XCTAssertFalse(first.working)
        XCTAssertFalse(later.working)
        XCTAssertNotEqual(first.roll, later.roll)
        XCTAssertNotEqual(first.gazeX, later.gazeX)
        XCTAssertNotEqual(first.gazeY, later.gazeY)
        XCTAssertEqual(first.eyeScale, 1)
        XCTAssertGreaterThan(FacePose.at(.work, t: 0).eyeScale, 1)
    }

    func testComposerAllocatesFullEditorWidthAndAccessibleControls() {
        for width: CGFloat in [320, 375, 430] {
            XCTAssertEqual(
                ChatComposerLayoutPolicy.editorWidth(containerWidth: width, horizontalInsets: 14),
                width - 28
            )
        }
        XCTAssertGreaterThanOrEqual(ChatComposerLayoutPolicy.controlHitTarget, 44)
        XCTAssertEqual(ChatComposerLayoutPolicy.maxEditorLines(isAccessibilitySize: false), 6)
        XCTAssertEqual(ChatComposerLayoutPolicy.maxEditorLines(isAccessibilitySize: true), 4)
        XCTAssertNil(ChatComposerLayoutPolicy.animation(reducedMotion: true, duration: 0.2))
        XCTAssertNotNil(ChatComposerLayoutPolicy.animation(reducedMotion: false, duration: 0.2))
        XCTAssertEqual(TranscriptMotionPolicy.toolSpinnerDegrees(spinning: true,
                                                                 reducedMotion: true), 45)
        XCTAssertEqual(TranscriptMotionPolicy.toolSpinnerDegrees(spinning: true,
                                                                 reducedMotion: false), 360)
    }

    func testComposerActionMatrixPreservesSubmitSteerSlashAndStop() {
        XCTAssertEqual(action("   ", attachments: 0, running: false), .disabled)
        XCTAssertEqual(action("", attachments: 1, running: false), .submit)
        XCTAssertEqual(action("/", attachments: 0, running: false), .palette)
        XCTAssertEqual(action("/help", attachments: 0, running: false), .slash)
        XCTAssertEqual(action("", attachments: 0, running: true), .stop)
        XCTAssertEqual(action("more detail", attachments: 0, running: true), .steer)
        XCTAssertEqual(action("", attachments: 1, running: true), .stop)
    }

    func testUnresolvedFailedRetryDisablesDraftSendButPreservesStop() {
        XCTAssertEqual(action("keep this draft", attachments: 0, running: true,
                              unresolvedRetry: true), .disabled)
        XCTAssertEqual(action("/help", attachments: 0, running: false,
                              unresolvedRetry: true), .disabled)
        XCTAssertEqual(action("", attachments: 1, running: false,
                              unresolvedRetry: true), .disabled)
        XCTAssertEqual(action("", attachments: 0, running: true,
                              unresolvedRetry: true), .stop)
        XCTAssertEqual(action("keep this draft", attachments: 0, running: true,
                              unresolvedRetry: false), .steer)
    }

    @MainActor
    func testPreparedRetryPublishesImmediateDraftDisableAndSettlementRestoresSend() throws {
        let model = AppModel()
        model.mode = .live
        let botID = "primary::worker"
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let failed = ChatMessage(
            author: .bot, text: "partial",
            failure: TurnFailure(message: "failed", recoverable: true))
        chat.messages = [ChatMessage(author: .user, text: "retry", rowID: 1), failed]
        let published = expectation(description: "observable retry ownership published")
        withObservationTracking {
            _ = model.hasUnresolvedFailedTurnRetry(in: botID)
        } onChange: {
            published.fulfill()
        }
        let draft = "keep this preflight draft"

        let request = try XCTUnwrap(model.prepareFailedTurnRetry(failed, in: botID))

        wait(for: [published], timeout: 0.1)
        XCTAssertTrue(chat.hasUnresolvedRetry)
        XCTAssertFalse(chat.isRunning, "REST preflight must not expose Stop")
        XCTAssertEqual(action(draft, attachments: 0, running: false,
                              unresolvedRetry: model.hasUnresolvedFailedTurnRetry(in: botID)),
                       .disabled)

        let restored = expectation(description: "observable retry ownership restored")
        withObservationTracking {
            _ = model.hasUnresolvedFailedTurnRetry(in: botID)
        } onChange: {
            restored.fulfill()
        }
        model.settleFailedTurnRetry(request, result: .retained, in: botID, chat: chat)

        wait(for: [restored], timeout: 0.1)
        XCTAssertFalse(chat.hasUnresolvedRetry)
        XCTAssertEqual(action(draft, attachments: 0, running: false,
                              unresolvedRetry: model.hasUnresolvedFailedTurnRetry(in: botID)),
                       .submit)
    }

    func testLongTranscriptUsesLazyStackAndRealMessageAnchor() {
        XCTAssertFalse(ChatTranscriptLayoutPolicy.usesLazyStack(messageCount: 8))
        XCTAssertFalse(ChatTranscriptLayoutPolicy.usesLazyStack(messageCount: 64))
        XCTAssertTrue(ChatTranscriptLayoutPolicy.usesLazyStack(messageCount: 65))

        let last = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        XCTAssertEqual(
            ChatTranscriptLayoutPolicy.anchorID(lastMessageID: last, showingWorkingAvatar: false),
            last.uuidString
        )
        XCTAssertEqual(
            ChatTranscriptLayoutPolicy.anchorID(lastMessageID: last, showingWorkingAvatar: true),
            "chat-working"
        )
        XCTAssertEqual(
            ChatTranscriptLayoutPolicy.anchorID(lastMessageID: nil, showingWorkingAvatar: false),
            "chat-bottom"
        )
        XCTAssertEqual(ChatTranscriptLayoutPolicy.layoutPassesMs, [16, 120, 360])
    }

    func testRosterHeaderHidesRawGatewayAddresses() {
        let ip = GatewayConnection(id: "a", name: "100.87.108.5", kind: .tailscale,
                                   address: "100.87.108.5:9119", state: .connected,
                                   ping: "12ms", botCount: 6)
        XCTAssertTrue(TalariaVoice.looksLikeNetworkAddress("100.87.108.5"))
        XCTAssertTrue(TalariaVoice.looksLikeNetworkAddress("100.87.108.5:9119"))
        XCTAssertTrue(TalariaVoice.looksLikeNetworkAddress("studio.local"))
        XCTAssertTrue(TalariaVoice.looksLikeNetworkAddress("api.example.com"))
        XCTAssertTrue(TalariaVoice.looksLikeNetworkAddress("[fd7a:115c:a1e0::1]:9119"))
        XCTAssertTrue(TalariaVoice.looksLikeNetworkAddress("localhost:9119"))
        XCTAssertFalse(TalariaVoice.looksLikeNetworkAddress("Home"))
        XCTAssertTrue(TalariaVoice.looksLikeNetworkAddress("John.Doe"))
        XCTAssertTrue(TalariaVoice.looksLikeNetworkAddress("NAS.office"))
        XCTAssertFalse(TalariaVoice.looksLikeNetworkAddress("v2.0"))
        XCTAssertEqual(TalariaVoice.friendlyGatewayLabel(ip, .soft), "Home")
        let named = GatewayConnection(id: "b", name: "Studio", kind: .lan,
                                      address: "studio.local", state: .connected,
                                      ping: "4ms", botCount: 2)
        XCTAssertEqual(TalariaVoice.friendlyGatewayLabel(named, .soft), "Studio")
        let dottedName = GatewayConnection(id: "d", name: "John.Doe", kind: .lan,
                                           address: "studio.local", state: .connected,
                                           ping: "4ms", botCount: 2)
        XCTAssertEqual(TalariaVoice.friendlyGatewayLabel(dottedName, .soft), "John.Doe")
        let lowercaseDottedName = GatewayConnection(
            id: "f", name: "john.doe", kind: .lan, address: "studio.local",
            state: .connected, ping: "4ms", botCount: 2)
        XCTAssertEqual(TalariaVoice.friendlyGatewayLabel(lowercaseDottedName, .soft), "john.doe")
        let mixedCaseRawHost = GatewayConnection(
            id: "g", name: "NAS.office", kind: .lan, address: "nas.OFFICE:9119",
            state: .connected, ping: "4ms", botCount: 2)
        XCTAssertEqual(TalariaVoice.friendlyGatewayLabel(mixedCaseRawHost, .soft), "Nearby")
        let versionName = GatewayConnection(id: "e", name: "v2.0", kind: .tailscale,
                                            address: "100.87.108.5:9119", state: .connected,
                                            ping: "12ms", botCount: 2)
        XCTAssertEqual(TalariaVoice.friendlyGatewayLabel(versionName, .soft), "v2.0")
        let cloud = GatewayConnection(id: "c", name: "org", kind: .cloud,
                                      address: "acme", state: .connected,
                                      ping: "", botCount: 1)
        XCTAssertEqual(TalariaVoice.netChip(offline: false, connections: [cloud], .soft).label, "Cloud")
        XCTAssertEqual(TalariaVoice.netChip(offline: true, connections: [ip], .soft).label, "offline")
    }

    func testJumpToLatestAppearsOnlyAfterLeavingTheLiveEdge() {
        var geometry = TranscriptGeometryReadiness()
        XCTAssertFalse(geometry.isReady)
        XCTAssertNil(geometry.distanceFromBottom)
        geometry.recordBottom(minY: 0)
        geometry.recordViewport(height: 0)
        XCTAssertFalse(geometry.isReady, "preference defaults are not live geometry")
        XCTAssertNil(geometry.distanceFromBottom)
        geometry.recordViewport(height: 640)
        XCTAssertTrue(geometry.isReady)
        XCTAssertEqual(geometry.distanceFromBottom, -640)

        XCTAssertTrue(ChatTranscriptLayoutPolicy.isFollowingLatest(distanceFromBottom: 0))
        XCTAssertTrue(ChatTranscriptLayoutPolicy.isFollowingLatest(distanceFromBottom: 120))
        XCTAssertFalse(ChatTranscriptLayoutPolicy.isFollowingLatest(distanceFromBottom: 121))
        XCTAssertFalse(ChatTranscriptLayoutPolicy.showsJumpControl(isFollowingLatest: true, messageCount: 40))
        XCTAssertTrue(ChatTranscriptLayoutPolicy.showsJumpControl(isFollowingLatest: false, messageCount: 40))
        XCTAssertFalse(ChatTranscriptLayoutPolicy.showsJumpControl(isFollowingLatest: false, messageCount: 0))
    }

    func testInitialAnchorBeginsWhenAnEmptyTranscriptReceivesItsFirstMessage() {
        var state = InitialTranscriptAnchorState()
        XCTAssertNil(state.begin(botID: "default", messageCount: 0))

        let attempt = state.begin(botID: "default", messageCount: 1)
        XCTAssertNotNil(attempt)
        XCTAssertTrue(state.shouldContinue(attempt!, currentBotID: "default",
                                           isCancelled: false))
        XCTAssertTrue(state.complete(attempt!, currentBotID: "default"))
        XCTAssertTrue(state.isSettled(for: "default"))
        XCTAssertNil(state.begin(botID: "default", messageCount: 2))
    }

    func testUserScrollOrCancellationStopsEveryRemainingInitialAnchorPass() {
        var state = InitialTranscriptAnchorState()
        let cancelled = state.begin(botID: "default", messageCount: 1)!
        XCTAssertFalse(state.shouldContinue(cancelled, currentBotID: "default",
                                            isCancelled: true))
        XCTAssertFalse(state.complete(cancelled, currentBotID: "default",
                                      isCancelled: true))

        let departed = state.begin(botID: "default", messageCount: 1)!
        XCTAssertTrue(state.userDeparted(botID: "default", messageCount: 1))
        XCTAssertFalse(state.shouldContinue(departed, currentBotID: "default",
                                            isCancelled: false))
        XCTAssertFalse(state.complete(departed, currentBotID: "default"),
                       "a departed attempt must not restore followingLatest")
        XCTAssertTrue(state.isSettled(for: "default"))
    }

    func testChatSwipeBackOnlyCommitsFromTheLeadingEdge() {
        XCTAssertTrue(ChatSwipeBackPolicy.shouldBegin(startX: 8))
        XCTAssertTrue(ChatSwipeBackPolicy.shouldBegin(startX: 28))
        XCTAssertFalse(ChatSwipeBackPolicy.shouldBegin(startX: 40))
        XCTAssertTrue(ChatSwipeBackPolicy.shouldCommit(translationX: 120, predictedX: 0, containerWidth: 390))
        XCTAssertTrue(ChatSwipeBackPolicy.shouldCommit(translationX: 20, predictedX: 800, containerWidth: 390))
        XCTAssertFalse(ChatSwipeBackPolicy.shouldCommit(translationX: 40, predictedX: 80, containerWidth: 390))
    }

    private func action(_ draft: String, attachments: Int,
                        running: Bool, unresolvedRetry: Bool = false) -> ChatComposerAction {
        ChatComposerActionPolicy.action(draft: draft, attachmentCount: attachments,
                                        isTurnRunning: running,
                                        hasUnresolvedFailedTurnRetry: unresolvedRetry)
    }
}
#endif
