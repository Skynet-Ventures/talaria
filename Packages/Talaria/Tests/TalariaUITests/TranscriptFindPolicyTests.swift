#if canImport(XCTest)
import XCTest
import SwiftUI
@testable import TalariaKit
@testable import TalariaTheme
@testable import TalariaUI

final class TranscriptFindPolicyTests: XCTestCase {
    func testIndexUsesOnlyAlreadyDisplayableUserAndBotForegroundText() throws {
        let bot = ChatMessage(author: .bot, text: "# **Visible** [label](https://secret.example)\n\n```swift\nlet codeNeedle = 1\n```\n\n| tableNeedle | value |\n| --- | --- |\n| shown | cell |",
                              reasoning: "private thought", toolCalls: [
            ToolCall(id: "tool", name: "secret_tool", context: "private argument",
                     state: .done, resultText: "private result")
        ], rowID: 9)
        let user = ChatMessage(author: .user, text: "User-visible needle", rowID: 10)
        let system = ChatMessage(author: .system, text: "system needle", rowID: 11)
        let index = try TranscriptFindPolicy.makeIndex(messages: [bot, user, system])
        let joined = index.entries.flatMap(\.segments).joined(separator: "|")

        XCTAssertTrue(joined.contains("Visible"))
        XCTAssertTrue(joined.contains("label"))
        XCTAssertTrue(joined.contains("codeNeedle"))
        XCTAssertTrue(joined.contains("tableNeedle"))
        XCTAssertTrue(joined.contains("User-visible needle"))
        XCTAssertFalse(joined.contains("https://"))
        XCTAssertFalse(joined.contains("**"))
        XCTAssertFalse(joined.contains("system needle"))
        XCTAssertFalse(joined.contains("private thought"))
        XCTAssertFalse(joined.contains("secret_tool"))
        XCTAssertEqual(try TranscriptFindPolicy.search("needle", in: index).total, 3)
        XCTAssertEqual(try TranscriptFindPolicy.search("codeNeedle", in: index).total, 1)
        XCTAssertEqual(try TranscriptFindPolicy.search("tableNeedle", in: index).total, 1)
    }

    func testCardsAndToolPayloadsDoNotExpandTheSearchSurface() throws {
        let cards = MessageCard.papers([
            .init(title: "Hidden paper", meta: "private", summary: "card-only")
        ])
        let index = try TranscriptFindPolicy.makeIndex(messages: [
            ChatMessage(author: .bot, text: "Foreground", card: cards,
                        toolCalls: [ToolCall(id: "t", name: "terminal", context: "secret",
                                             state: .done, resultText: "hidden result")])
        ])
        XCTAssertEqual(try TranscriptFindPolicy.search("Foreground", in: index).total, 1)
        XCTAssertEqual(try TranscriptFindPolicy.search("Hidden paper", in: index).total, 0)
        XCTAssertEqual(try TranscriptFindPolicy.search("secret", in: index).total, 0)
        XCTAssertEqual(try TranscriptFindPolicy.search("hidden result", in: index).total, 0)
    }

    func testCanonicalCaseAndDiacriticMatchingIsSegmentLocalAndNonOverlapping() throws {
        let revision = UUID()
        let index = TranscriptFindIndex(entries: [
            .init(rowID: 1, author: .user, revisionID: revision,
                  segments: ["Cafe\u{301} CAFÉ cafe banana", "cross", "boundary"])
        ])
        XCTAssertEqual(try TranscriptFindPolicy.search("café", in: index).total, 2)
        XCTAssertEqual(try TranscriptFindPolicy.search("CAFE", in: index).total, 1)
        XCTAssertEqual(try TranscriptFindPolicy.search("ana", in: index).total, 1)
        XCTAssertEqual(try TranscriptFindPolicy.search("ssb", in: index).total, 0)
    }

    func testDuplicateTextKeepsDistinctDurableAddressesAndOccurrenceNavigation() throws {
        let first = TranscriptFindIndex.Entry(
            rowID: 4, author: .bot, revisionID: UUID(), segments: ["needle needle"])
        let second = TranscriptFindIndex.Entry(
            rowID: 5, author: .bot, revisionID: UUID(), segments: ["needle"])
        let result = try TranscriptFindPolicy.search(
            "needle", in: TranscriptFindIndex(entries: [first, second]))
        XCTAssertEqual(result.total, 3)
        XCTAssertEqual(result.groups.count, 2)
        XCTAssertEqual(result.groups.map(\.address.rowID), [4, 5])
        XCTAssertEqual(TranscriptFindPolicy.selection(in: result, ordinal: 0)?.occurrenceInSegment, 0)
        XCTAssertEqual(TranscriptFindPolicy.selection(in: result, ordinal: 1)?.occurrenceInSegment, 1)
        XCTAssertEqual(TranscriptFindPolicy.selection(in: result, ordinal: 2)?.address.rowID, 5)
        XCTAssertNil(TranscriptFindPolicy.selection(in: result, ordinal: 3))
        XCTAssertEqual(TranscriptFindPolicy.ordinal(
            of: TranscriptFindPolicy.selection(in: result, ordinal: 2)!, in: result), 2)
        XCTAssertEqual(TranscriptFindPolicy.movedOrdinal(current: 0, delta: -1, total: 3), 2)
        XCTAssertEqual(TranscriptFindPolicy.movedOrdinal(current: 2, delta: 1, total: 3), 0)
        XCTAssertEqual(TranscriptFindPolicy.movedOrdinal(current: 1, delta: 7, total: 3), 2)
    }

    func testDurableRowIdentitySurvivesRehydrationAndEarlierInsertion() throws {
        let selectedIndex = TranscriptFindIndex(entries: [
            .init(rowID: 10, author: .bot, revisionID: UUID(), segments: ["needle needle"])
        ])
        let selected = try XCTUnwrap(TranscriptFindPolicy.selection(
            in: TranscriptFindPolicy.search("needle", in: selectedIndex), ordinal: 1))
        let refreshed = TranscriptFindIndex(entries: [
            .init(rowID: 5, author: .user, revisionID: UUID(), segments: ["needle"]),
            .init(rowID: 10, author: .bot, revisionID: UUID(), segments: ["needle needle"]),
        ])
        let refreshedResult = try TranscriptFindPolicy.search("needle", in: refreshed)
        XCTAssertEqual(TranscriptFindPolicy.ordinal(of: selected, in: refreshedResult), 2)
        XCTAssertTrue(selected.address.identifies(
            ChatMessage(author: .bot, text: "replacement", rowID: 10)))
        XCTAssertFalse(selected.address.identifies(
            ChatMessage(author: .user, text: "wrong author", rowID: 10)))
    }

    func testUUIDFallbackIsRevisionScopedWhenDurableRowIDIsAbsent() {
        let revision = UUID()
        let address = TranscriptFindAddress(rowID: nil, author: .system,
                                            revisionID: revision, segment: 0)
        XCTAssertTrue(address.identifies(ChatMessage(id: revision, author: .system, text: "x")))
        XCTAssertFalse(address.identifies(ChatMessage(author: .system, text: "x")))
        XCTAssertFalse(address.identifies(ChatMessage(id: revision, author: .user, text: "x")))
    }

    func testQueryAndIndexBudgetsBoundBytesCharactersFieldsMessagesAndSegments() throws {
        let oversizedQuery = String(repeating: "🧑🏽‍💻", count: 400)
        let admitted = TranscriptFindPolicy.admittedQueryInput(oversizedQuery)
        XCTAssertLessThanOrEqual(admitted.count, TranscriptFindPolicy.maximumQueryCharacters)
        XCTAssertLessThanOrEqual(admitted.utf8.count, TranscriptFindPolicy.maximumQueryBytes)
        XCTAssertEqual(TranscriptFindPolicy.boundedQuery(oversizedQuery),
                       admitted.trimmingCharacters(in: .whitespacesAndNewlines))

        let message = ChatMessage(author: .user,
                                  text: String(repeating: "a",
                                               count: TranscriptFindPolicy.maximumFieldCharacters + 10))
        let index = try TranscriptFindPolicy.makeIndex(messages: [message])
        XCTAssertTrue(index.isTruncated)
        XCTAssertEqual(index.entries[0].segments[0].count,
                       TranscriptFindPolicy.maximumFieldCharacters)
        XCTAssertLessThanOrEqual(TranscriptFindPolicy.maximumSegmentsPerMessage, 512)
        XCTAssertLessThanOrEqual(TranscriptFindPolicy.maximumIndexedSegments, 4_096)
        XCTAssertLessThanOrEqual(TranscriptFindPolicy.maximumIndexedMessages, 1_000)
        XCTAssertLessThanOrEqual(TranscriptFindPolicy.maximumMatchGroups, 2_048)
        XCTAssertLessThanOrEqual(TranscriptFindPolicy.maximumMatches, 10_000)
    }

    func testResultOccurrencesAndGroupsStopAtIndependentHardCaps() throws {
        let occurrenceIndex = TranscriptFindIndex(entries: [
            .init(rowID: 1, author: .user, revisionID: UUID(),
                  segments: [String(repeating: "x ",
                    count: TranscriptFindPolicy.maximumMatches + 100)])
        ])
        let occurrences = try TranscriptFindPolicy.search("x", in: occurrenceIndex)
        XCTAssertEqual(occurrences.total, TranscriptFindPolicy.maximumMatches)
        XCTAssertEqual(occurrences.groups.count, 1)
        XCTAssertTrue(occurrences.isTruncated)

        let groupIndex = TranscriptFindIndex(entries: [
            .init(rowID: 2, author: .bot, revisionID: UUID(),
                  segments: Array(repeating: "match",
                    count: TranscriptFindPolicy.maximumMatchGroups + 10))
        ])
        let groups = try TranscriptFindPolicy.search("match", in: groupIndex)
        XCTAssertEqual(groups.groups.count, TranscriptFindPolicy.maximumMatchGroups)
        XCTAssertEqual(groups.total, TranscriptFindPolicy.maximumMatchGroups)
        XCTAssertTrue(groups.isTruncated)
    }

    func testHostileCombiningControlsAndHugeSourceAreRejectedBeforeParsing() throws {
        XCTAssertEqual(
            TranscriptFindPolicy.admittedQueryInput("nee\u{202E}d\u{0}le"),
            "needle")
        let graphemeBomb = "a" + String(repeating: "\u{301}", count: 260_000)
        XCTAssertEqual(graphemeBomb.count, 1)
        XCTAssertGreaterThan(graphemeBomb.utf8.count,
                             TranscriptFindPolicy.maximumSourceBytesPerMessage)
        let bombIndex = try TranscriptFindPolicy.makeIndex(messages: [
            ChatMessage(author: .user, text: graphemeBomb)
        ])
        XCTAssertTrue(bombIndex.isTruncated)
        XCTAssertTrue(bombIndex.entries.isEmpty)

        let rawLink = "[visible](https://hidden-prefix.example/"
            + String(repeating: "x", count: TranscriptFindPolicy.maximumSourceCharactersPerMessage)
        let linkIndex = try TranscriptFindPolicy.makeIndex(messages: [
            ChatMessage(author: .bot, text: rawLink)
        ])
        XCTAssertTrue(linkIndex.isTruncated)
        XCTAssertTrue(linkIndex.entries.isEmpty)
        XCTAssertEqual(try TranscriptFindPolicy.search("hidden-prefix", in: linkIndex).total, 0)
    }

    func testSegmentAndLineCapsNeverPrefixParseHiddenMarkdown() throws {
        let paragraphs = (0..<600).map { index in
            index == 0 ? "first-marker" : (index == 599 ? "late-marker" : "paragraph-\(index)")
        }.joined(separator: "\n\n")
        let segmentIndex = try TranscriptFindPolicy.makeIndex(messages: [
            ChatMessage(author: .user, text: paragraphs)
        ])
        XCTAssertTrue(segmentIndex.isTruncated)
        XCTAssertEqual(try TranscriptFindPolicy.search("first-marker", in: segmentIndex).total, 1)
        XCTAssertEqual(try TranscriptFindPolicy.search("late-marker", in: segmentIndex).total, 0)

        for separator in ["\r", "\u{2028}"] {
            let raw = Array(repeating: "safe",
                            count: TranscriptFindPolicy.maximumSourceLinesPerMessage + 1)
                .joined(separator: separator)
            let index = try TranscriptFindPolicy.makeIndex(messages: [
                ChatMessage(author: .user, text: raw)
            ])
            XCTAssertTrue(index.isTruncated)
            XCTAssertTrue(index.entries.isEmpty)
        }
    }

    func testFreshnessGenerationAndSourceReplacementInvalidateStaleResults() throws {
        let index = TranscriptFindIndex(entries: [
            .init(rowID: 1, author: .user, revisionID: UUID(), segments: ["alpha beta"])
        ])
        let alpha = try TranscriptFindPolicy.search("alpha", in: index)
        let source = TranscriptFindSourceIdentity(botID: "bot", storedSessionID: "stored", liveSessionID: "live")
        XCTAssertTrue(TranscriptFindPolicy.isCurrent(
            alpha, query: "alpha", resultIndexRevision: 4, currentIndexRevision: 4,
            resultMessageGeneration: 8, currentMessageGeneration: 8,
            resultSource: source, currentSource: source))
        XCTAssertFalse(TranscriptFindPolicy.isCurrent(
            alpha, query: "ALPHA", resultIndexRevision: 4, currentIndexRevision: 4,
            resultMessageGeneration: 8, currentMessageGeneration: 8,
            resultSource: source, currentSource: source))
        XCTAssertFalse(TranscriptFindPolicy.isCurrent(
            alpha, query: "beta", resultIndexRevision: 4, currentIndexRevision: 4,
            resultMessageGeneration: 8, currentMessageGeneration: 8,
            resultSource: source, currentSource: source))
        XCTAssertFalse(TranscriptFindPolicy.isCurrent(
            alpha, query: "alpha", resultIndexRevision: 4, currentIndexRevision: 4,
            resultMessageGeneration: 8, currentMessageGeneration: 8,
            resultSource: source,
            currentSource: TranscriptFindSourceIdentity(
                botID: "replacement", storedSessionID: "stored", liveSessionID: "live")))
        XCTAssertTrue(TranscriptFindPolicy.isCurrent(
            alpha, query: "alpha", resultIndexRevision: 4, currentIndexRevision: 4,
            resultMessageGeneration: 8, currentMessageGeneration: 8,
            resultSource: source, currentSource: source))
        XCTAssertFalse(TranscriptFindPolicy.isCurrent(
            alpha, query: "alpha", resultIndexRevision: 4, currentIndexRevision: 4,
            resultMessageGeneration: 8, currentMessageGeneration: 9,
            resultSource: source, currentSource: source))
        XCTAssertFalse(TranscriptFindPolicy.isCurrent(
            alpha, query: "alpha", resultIndexRevision: 4, currentIndexRevision: 5,
            resultMessageGeneration: 8, currentMessageGeneration: 8,
            resultSource: source, currentSource: source))
        XCTAssertTrue(TranscriptFindPolicy.isIndexReady(
            indexMessageGeneration: 8, currentMessageGeneration: 8,
            indexSource: source, currentSource: source))
        XCTAssertFalse(TranscriptFindPolicy.isIndexReady(
            indexMessageGeneration: 7, currentMessageGeneration: 8,
            indexSource: source, currentSource: source))
        XCTAssertFalse(TranscriptFindPolicy.isIndexReady(
            indexMessageGeneration: 8, currentMessageGeneration: 8,
            indexSource: source,
            currentSource: TranscriptFindSourceIdentity(
                botID: "replacement", storedSessionID: "stored", liveSessionID: "live")))
        XCTAssertFalse(TranscriptFindPolicy.isIndexReady(
            indexMessageGeneration: 8, currentMessageGeneration: 8,
            indexSource: TranscriptFindSourceIdentity(
                botID: "bot", storedSessionID: "stored", liveSessionID: "live",
                gatewayID: "gateway-a", profile: "default"),
            currentSource: TranscriptFindSourceIdentity(
                botID: "bot", storedSessionID: "stored", liveSessionID: "live",
                gatewayID: "gateway-b", profile: "default")))
    }

    func testStatusAccessibilityReportsOneBasedPositionAndClipping() {
        let clipped = TranscriptFindResult(query: "needle", groups: [], total: 0,
                                           isTruncated: true)
        let noMatches = TranscriptFindStatusPolicy.resolved(result: clipped, ordinal: 0)
        XCTAssertEqual(noMatches.visual, "No matches in indexed text+")
        XCTAssertEqual(noMatches.accessibility,
                       "No matches in indexed text; transcript clipped")

        let result = TranscriptFindResult(query: "needle", total: 3)
        let status = TranscriptFindStatusPolicy.resolved(result: result, ordinal: 1)
        XCTAssertEqual(status.visual, "2 of 3")
        XCTAssertEqual(status.accessibility, "Match 2 of 3")
        XCTAssertEqual(TranscriptFindStatusPolicy.resolved(
            result: result, ordinal: 99).visual, "3 of 3")
    }

    func testInteractionPoliciesOwnScrollAndKeepInitialAnchorOutOfFind() {
        XCTAssertGreaterThanOrEqual(TranscriptFindPolicy.minimumInteractiveDimension, 44)
        XCTAssertFalse(TranscriptFindPolicy.allowsAutomaticFollow(hasSelection: true))
        XCTAssertTrue(TranscriptFindPolicy.allowsAutomaticFollow(hasSelection: false))
        XCTAssertFalse(TranscriptFindPolicy.allowsHiddenDetailExpansion())
        XCTAssertFalse(TranscriptFindPolicy.allowsInitialAnchor(isFindOwningScroll: true))
        XCTAssertTrue(TranscriptFindPolicy.allowsInitialAnchor(isFindOwningScroll: false))
        XCTAssertTrue((150...200).contains(Int(TranscriptFindPolicy.debounceMilliseconds)))
    }

    func testReducedMotionUsesOpacityOnlyForFindTransitionsWhenPolicyIsExposed() {
        XCTAssertFalse(TranscriptFindPolicy.usesAnimatedNavigation(reducedMotion: true))
        XCTAssertTrue(TranscriptFindPolicy.usesAnimatedNavigation(reducedMotion: false))
    }

    func testFindScrollOwnershipInvalidatesDelayedInitialAnchorAttempt() {
        var anchor = InitialTranscriptAnchorState()
        let attempt = anchor.begin(botID: "default", messageCount: 1)!
        XCTAssertTrue(anchor.shouldContinue(attempt, currentBotID: "default", isCancelled: false))
        XCTAssertTrue(anchor.userDeparted(botID: "default", messageCount: 1))
        XCTAssertFalse(anchor.shouldContinue(attempt, currentBotID: "default", isCancelled: false))
        XCTAssertFalse(anchor.complete(attempt, currentBotID: "default"))
    }
}
#endif
