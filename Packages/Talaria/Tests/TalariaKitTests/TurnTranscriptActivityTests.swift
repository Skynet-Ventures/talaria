#if canImport(XCTest)
import XCTest
@testable import TalariaKit

final class TurnTranscriptActivityTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testActivityAppearsImmediatelyBeforeOutputAndOnlyAfterQuietBoundaryLater() {
        var activity = TurnTranscriptActivity()
        activity.begin(at: start, replacingExisting: true)

        XCTAssertEqual(TurnTranscriptActivityPolicy.presentation(
            activity: activity, turnStartedAt: start, now: start,
            isTurnRunning: true, isAwaitingInput: false, toolNarratesWait: false)?.kind,
            .awaitingResponse)

        activity.recordVisibleProgress(at: start.addingTimeInterval(3))
        XCTAssertNil(TurnTranscriptActivityPolicy.presentation(
            activity: activity, turnStartedAt: start,
            now: start.addingTimeInterval(4.99), isTurnRunning: true,
            isAwaitingInput: false, toolNarratesWait: false))
        let quiet = TurnTranscriptActivityPolicy.presentation(
            activity: activity, turnStartedAt: start,
            now: start.addingTimeInterval(5), isTurnRunning: true,
            isAwaitingInput: false, toolNarratesWait: false)
        XCTAssertEqual(quiet?.kind, .quietGap)
        XCTAssertEqual(quiet?.startedAt, start.addingTimeInterval(3))
    }

    func testNamedPhasesReplaceDeterministicallyAndDraftingHasRevealDelay() {
        var activity = TurnTranscriptActivity()
        activity.begin(at: start, replacingExisting: true)
        activity.namePhase(.draftingTool, label: "Preparing browser", startedAt: start)

        XCTAssertNil(TurnTranscriptActivityPolicy.presentation(
            activity: activity, turnStartedAt: start,
            now: start.addingTimeInterval(0.199), isTurnRunning: true,
            isAwaitingInput: false, toolNarratesWait: false))
        XCTAssertEqual(TurnTranscriptActivityPolicy.presentation(
            activity: activity, turnStartedAt: start,
            now: start.addingTimeInterval(0.2), isTurnRunning: true,
            isAwaitingInput: false, toolNarratesWait: false)?.label,
            "Preparing browser")
        activity.namePhase(.draftingTool, label: "Preparing browser",
                           startedAt: start.addingTimeInterval(1))
        XCTAssertEqual(activity.phase?.startedAt, start,
                       "an identical phase update must not restart elapsed time")

        activity.namePhase(.compacting, label: "Summarizing thread",
                           startedAt: start.addingTimeInterval(7))
        let compacting = TurnTranscriptActivityPolicy.presentation(
            activity: activity, turnStartedAt: start,
            now: start.addingTimeInterval(8), isTurnRunning: true,
            isAwaitingInput: false, toolNarratesWait: false)
        XCTAssertEqual(compacting?.kind, .named(.compacting))
        XCTAssertEqual(compacting?.startedAt, start,
                       "compaction reports whole-turn elapsed time")
    }

    func testAwaitingInputAndVisibleRunningToolSuppressDuplicateNarration() {
        var activity = TurnTranscriptActivity()
        activity.begin(at: start, replacingExisting: true)
        XCTAssertNil(TurnTranscriptActivityPolicy.presentation(
            activity: activity, turnStartedAt: start, now: start,
            isTurnRunning: true, isAwaitingInput: true, toolNarratesWait: false))
        XCTAssertNil(TurnTranscriptActivityPolicy.presentation(
            activity: activity, turnStartedAt: start, now: start,
            isTurnRunning: true, isAwaitingInput: false, toolNarratesWait: true))
        XCTAssertNil(TurnTranscriptActivityPolicy.presentation(
            activity: activity, turnStartedAt: start, now: start,
            isTurnRunning: false, isAwaitingInput: false, toolNarratesWait: false))
    }

    func testProviderWaitAdmissionAndLabelsAreBoundedAndControlSafe() throws {
        XCTAssertEqual(TurnTranscriptActivityPolicy.providerWaitLabel(
            "  ⏳ Waiting on provider capacity  "), "⏳ Waiting on provider capacity")
        XCTAssertNil(TurnTranscriptActivityPolicy.providerWaitLabel("ordinary thought"))
        XCTAssertNil(TurnTranscriptActivityPolicy.providerWaitLabel("⏳ still working"))

        let admitted = try XCTUnwrap(TurnTranscriptActivityPolicy.admittedLabel(
            "\u{202E}  tool\nname  " + String(repeating: "x", count: 300)))
        XCTAssertEqual(admitted.prefix(9), "tool name")
        XCTAssertLessThanOrEqual(admitted.unicodeScalars.count,
                                 TurnTranscriptActivityPolicy.maximumLabelScalars)
        XCTAssertFalse(admitted.unicodeScalars.contains { $0.value == 0x202E })
    }
}
#endif
