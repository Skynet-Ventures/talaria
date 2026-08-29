import XCTest
@testable import TalariaKit

final class AssistantResponseAlternativesTests: XCTestCase {
    private func binding(source: UUID, chat: UUID = UUID(), stored: String = "stored",
                         runtime: String = "runtime") -> AssistantResponseAlternativesBinding {
        AssistantResponseAlternativesBinding(
            chatID: chat, sourceUserID: source, storedSessionID: stored,
            runtimeSessionID: runtime, gatewayID: "gateway", profile: "profile")
    }

    func testRepeatedRegenerateKeepsStableGroupOrderAndNewRunIdentity() {
        let source = ChatMessage(author: .user, text: "same", rowID: 1)
        let first = ChatMessage(author: .bot, text: "answer A", rowID: 2)
        let second = ChatMessage(author: .bot, text: "answer B", rowID: 3)
        let key = binding(source: source.id)

        let one = AssistantResponseAlternativesPolicy.record(
            [first], binding: key)
        let groupID = one.groups[0].id
        let two = AssistantResponseAlternativesPolicy.record(
            [second], binding: key, state: one)

        XCTAssertEqual(two.groups.count, 1)
        XCTAssertEqual(two.groups[0].id, groupID)
        XCTAssertEqual(two.groups[0].alternatives.map { $0.messages[0].text },
                       ["answer A", "answer B"])
        XCTAssertNotEqual(two.groups[0].alternatives[0].id,
                          two.groups[0].alternatives[1].id)
        XCTAssertNil(two.selectedAlternativeIndex, "newest/current is the default")
        XCTAssertEqual(AssistantResponseAlternativesPolicy.responsePosition(in: two)?.total, 3)
    }

    func testDuplicatePromptTextUsesExactSourceIdentity() {
        let first = AssistantResponseAlternativesPolicy.record(
            [ChatMessage(author: .bot, text: "same answer")],
            binding: binding(source: UUID()))
        let second = AssistantResponseAlternativesPolicy.record(
            [ChatMessage(author: .bot, text: "same answer")],
            binding: binding(source: UUID()), state: first)

        XCTAssertEqual(second.groups.count, 2)
        XCTAssertNotEqual(second.groups[0].binding.sourceUserID,
                          second.groups[1].binding.sourceUserID)
    }

    func testNavigationStopsAtBothBoundariesWithoutWrapping() throws {
        let key = binding(source: UUID())
        var state = AssistantResponseAlternatives()
        state = AssistantResponseAlternativesPolicy.record(
            [ChatMessage(author: .bot, text: "old")], binding: key, state: state)
        state = AssistantResponseAlternativesPolicy.record(
            [ChatMessage(author: .bot, text: "older")], binding: key, state: state)

        XCTAssertNil(state.selectedAlternativeIndex)
        state = AssistantResponseAlternativesPolicy.previous(in: state)
        XCTAssertEqual(state.selectedAlternativeIndex, 1)
        state = AssistantResponseAlternativesPolicy.previous(in: state)
        XCTAssertEqual(state.selectedAlternativeIndex, 0)
        XCTAssertEqual(AssistantResponseAlternativesPolicy.previous(in: state), state)
        state = AssistantResponseAlternativesPolicy.next(in: state)
        XCTAssertEqual(state.selectedAlternativeIndex, 1)
        state = AssistantResponseAlternativesPolicy.next(in: state)
        XCTAssertNil(state.selectedAlternativeIndex)
        XCTAssertEqual(AssistantResponseAlternativesPolicy.next(in: state), state)

        let current = ChatMessage(author: .bot, text: "current")
        let source = ChatMessage(id: key.sourceUserID, author: .user, text: "prompt")
        let displayed = AssistantResponseAlternativesPolicy.displayedMessages(
            current: [source, current], state: state, binding: key)
        XCTAssertEqual(displayed.map(\.text), ["prompt", "current"])
    }

    func testArchivedProjectionPreservesFullEvidenceAndCurrentProjection() throws {
        let source = ChatMessage(author: .user, text: "prompt")
        let tool = ToolCall(id: "tool-1", name: "terminal", context: "echo",
                            state: .failed, resultText: "failed output",
                            result: ToolPayload(kind: .text, text: "failed output"))
        let failure = TurnFailure(message: "terminal failed", recoverable: true)
        let old = ChatMessage(author: .bot, text: "old answer", card: .approvalRef("approval"),
                              reasoning: "old thought", toolCalls: [tool], failure: failure)
        let current = ChatMessage(author: .bot, text: "new answer")
        let key = binding(source: source.id)
        var state = AssistantResponseAlternativesPolicy.record([old], binding: key)
        let groupID = try XCTUnwrap(state.selectedGroupID)
        state = AssistantResponseAlternativesPolicy.select(
            groupID: groupID, archivedIndex: 0, in: state)

        let displayed = AssistantResponseAlternativesPolicy.displayedMessages(
            current: [source, current], state: state, binding: key)
        XCTAssertEqual(displayed.count, 2)
        XCTAssertEqual(displayed[1], old)
        XCTAssertEqual(displayed[1].toolCalls[0].resultText, "failed output")
        XCTAssertTrue(AssistantResponseAlternativesPolicy.isArchived(
            displayed[1], in: state))
    }

    func testHostileRunsAreBoundedAndExplicitlyClipped() {
        let hostile = ChatMessage(
            author: .bot,
            text: String(repeating: "x", count:
                AssistantResponseAlternativesPolicy.maximumVisibleScalarsPerRun + 10),
            toolCalls: (0..<300).map {
                ToolCall(id: "tool-\($0)", name: "terminal",
                         context: String(repeating: "y", count: 50_000))
            })
        let run = AssistantResponseAlternativesPolicy.boundedRun([hostile])

        XCTAssertTrue(run.isClipped)
        XCTAssertLessThanOrEqual(run.messages.count,
                                 AssistantResponseAlternativesPolicy.maximumMessagesPerRun)
        XCTAssertLessThanOrEqual(
            run.messages.reduce(0) { $0 + $1.text.unicodeScalars.count },
            AssistantResponseAlternativesPolicy.maximumVisibleScalarsPerRun)
        XCTAssertGreaterThan(run.clippedVisibleScalars, 0)
    }

    func testRebindPreservesGroupIdentityAndPruningKeepsEarlierTurns() throws {
        let firstSource = UUID()
        let laterSource = UUID()
        let replacementSource = UUID()
        let firstBinding = binding(source: firstSource)
        let laterBinding = binding(source: laterSource, chat: firstBinding.chatID,
                                   stored: firstBinding.storedSessionID,
                                   runtime: firstBinding.runtimeSessionID)
        let first = AssistantResponseAlternativesPolicy.record(
            [ChatMessage(author: .bot, text: "first")], binding: firstBinding)
        var state = AssistantResponseAlternativesPolicy.record(
            [ChatMessage(author: .bot, text: "later")], binding: laterBinding,
            state: first)
        let firstGroupID = try XCTUnwrap(state.groups.first?.id)
        let firstRunID = try XCTUnwrap(state.groups.first?.alternatives.first?.id)

        state = AssistantResponseAlternativesPolicy.pruning(
            sourceUserIDs: [laterSource], in: state)
        let replacementBinding = binding(source: replacementSource,
                                         chat: firstBinding.chatID,
                                         stored: firstBinding.storedSessionID,
                                         runtime: firstBinding.runtimeSessionID)
        state = AssistantResponseAlternativesPolicy.rebindSourceUserID(
            from: firstSource, to: replacementSource,
            matching: replacementBinding, in: state)

        XCTAssertEqual(state.groups.count, 1)
        XCTAssertEqual(state.groups[0].id, firstGroupID)
        XCTAssertEqual(state.groups[0].alternatives[0].id, firstRunID)
        XCTAssertEqual(state.groups[0].binding.sourceUserID, replacementSource)
    }

    func testBoundedRunCapsPayloadTextMultiByteAndWork() throws {
        let hostile = String(repeating: "🧑🏽‍💻", count: 50_000)
        let payload = ToolPayload(kind: .text, text: hostile)
        let calls = (0..<20_000).map { index in
            ToolCall(id: "tool-(index)", name: "terminal",
                     context: hostile, arguments: payload, result: payload)
        }
        let run = AssistantResponseAlternativesPolicy.boundedRun([
            ChatMessage(author: .bot, text: hostile, toolCalls: calls),
            ChatMessage(author: .bot, text: hostile),
        ])

        XCTAssertLessThanOrEqual(run.messages.count,
                                 AssistantResponseAlternativesPolicy.maximumMessagesPerRun)
        XCTAssertLessThanOrEqual(run.workItems,
                                 AssistantResponseAlternativesPolicy.maximumWorkItemsPerRun)
        XCTAssertLessThanOrEqual(run.visibleScalars,
                                 AssistantResponseAlternativesPolicy.maximumVisibleScalarsPerRun)
        XCTAssertLessThanOrEqual(run.bytes,
                                 AssistantResponseAlternativesPolicy.maximumBytesPerRun)
        let retainedPayloadText = run.messages.flatMap(\.toolCalls).flatMap {
            [$0.arguments?.text, $0.result?.text].compactMap { $0 }
        }.joined()
        XCTAssertLessThanOrEqual(
            retainedPayloadText.unicodeScalars.count,
            AssistantResponseAlternativesPolicy.maximumVisibleScalarsPerRun)
        XCTAssertLessThanOrEqual(
            retainedPayloadText.utf8.count,
            AssistantResponseAlternativesPolicy.maximumBytesPerRun)
        XCTAssertTrue(run.isClipped)
    }

    func testWorkCapReservesEveryAdmittedMessageBeforeToolCalls() {
        let messageCount = AssistantResponseAlternativesPolicy.maximumMessagesPerRun
        let callsPerMessage = 128
        let source = (0..<messageCount).map { messageIndex in
            ChatMessage(
                author: .bot, text: "message-\(messageIndex)",
                toolCalls: (0..<callsPerMessage).map { toolIndex in
                    ToolCall(id: "tool-\(messageIndex)-\(toolIndex)",
                             name: "terminal", context: "echo")
                })
        }
        let run = AssistantResponseAlternativesPolicy.boundedRun(source)

        XCTAssertEqual(run.messages.count, messageCount,
                       "work clipping must not erase later assistant rows")
        XCTAssertEqual(run.workItems,
                       AssistantResponseAlternativesPolicy.maximumWorkItemsPerRun)
        XCTAssertLessThanOrEqual(run.workItems,
                                 AssistantResponseAlternativesPolicy.maximumWorkItemsPerRun)
        let fullMessages = (AssistantResponseAlternativesPolicy.maximumWorkItemsPerRun
            - messageCount) / callsPerMessage
        XCTAssertEqual(run.messages.prefix(fullMessages).map(\.toolCalls.count),
                       Array(repeating: callsPerMessage, count: fullMessages))
        XCTAssertEqual(run.messages.dropFirst(fullMessages).flatMap(\.toolCalls).count,
                       AssistantResponseAlternativesPolicy.maximumWorkItemsPerRun
                           - messageCount - (fullMessages * callsPerMessage))
        XCTAssertTrue(run.isClipped)
    }

    func testControlPlacementsFollowFinalBotRowForEverySourceGroup() throws {
        let chatID = UUID()
        let source1 = ChatMessage(author: .user, text: "one")
        let firstBot = ChatMessage(author: .bot, text: "one / first")
        let finalBot = ChatMessage(author: .bot, text: "one / final",
                                   toolCalls: [ToolCall(id: "tool-1", name: "terminal",
                                                        context: "echo")])
        let source2 = ChatMessage(author: .user, text: "two")
        let secondFirstBot = ChatMessage(author: .bot, text: "two / first")
        let secondFinalBot = ChatMessage(author: .bot, text: "two / final")
        let key1 = binding(source: source1.id, chat: chatID)
        let key2 = binding(source: source2.id, chat: chatID)
        var state = AssistantResponseAlternativesPolicy.record(
            [ChatMessage(author: .bot, text: "old one")], binding: key1)
        state = AssistantResponseAlternativesPolicy.record(
            [ChatMessage(author: .bot, text: "old two")], binding: key2, state: state)
        let displayed = [source1, firstBot, finalBot, source2, secondFirstBot, secondFinalBot]
        let placements = AssistantResponseAlternativesPolicy.controlPlacements(
            current: displayed, state: state, binding: key2)

        XCTAssertEqual(placements.count, 2)
        XCTAssertEqual(Set(placements.map(\.groupID)), Set(state.groups.map(\.id)))
        XCTAssertEqual(placements.first(where: { $0.groupID == state.groups[0].id })?.botMessageID,
                       finalBot.id)
        XCTAssertEqual(placements.first(where: { $0.groupID == state.groups[1].id })?.botMessageID,
                       secondFinalBot.id)
        for placement in placements {
            let sourceIndex = try XCTUnwrap(displayed.firstIndex {
                $0.id == placement.sourceUserID
            })
            let botIndex = try XCTUnwrap(displayed.firstIndex {
                $0.id == placement.botMessageID
            })
            XCTAssertGreaterThan(botIndex, sourceIndex,
                                 "a navigator cannot precede its prompt")
            XCTAssertEqual(displayed[botIndex].author, .bot)
        }
    }

    func testSelectedArchivedMultiRowRunMovesOnlyThatGroupPlacement() throws {
        let chatID = UUID()
        let source1 = ChatMessage(author: .user, text: "one")
        let currentOne = ChatMessage(author: .bot, text: "current one")
        let source2 = ChatMessage(author: .user, text: "two")
        let currentTwo = ChatMessage(author: .bot, text: "current two")
        let oldOneFirst = ChatMessage(author: .bot, text: "old one / first")
        let oldOneTool = ChatMessage(author: .bot, text: "", toolCalls: [
            ToolCall(id: "old-tool", name: "terminal", context: "echo")
        ])
        let oldOneFinal = ChatMessage(author: .bot, text: "old one / final")
        let key1 = binding(source: source1.id, chat: chatID)
        let key2 = binding(source: source2.id, chat: chatID)
        var state = AssistantResponseAlternativesPolicy.record(
            [oldOneFirst, oldOneTool, oldOneFinal], binding: key1)
        state = AssistantResponseAlternativesPolicy.record(
            [ChatMessage(author: .bot, text: "old two")], binding: key2, state: state)
        state = AssistantResponseAlternativesPolicy.select(
            groupID: try XCTUnwrap(state.groups.first?.id), archivedIndex: 0, in: state)
        let current = [source1, currentOne, source2, currentTwo]
        let placements = AssistantResponseAlternativesPolicy.controlPlacements(
            current: current, state: state, binding: key2)
        let projected = AssistantResponseAlternativesPolicy.displayedMessages(
            current: current, state: state, binding: key1)

        XCTAssertEqual(placements.count, 2)
        XCTAssertEqual(placements.first(where: { $0.groupID == state.groups[0].id })?.botMessageID,
                       oldOneFinal.id)
        XCTAssertEqual(placements.first(where: { $0.groupID == state.groups[1].id })?.botMessageID,
                       currentTwo.id)
        XCTAssertEqual(projected.map(\.id),
                       [source1.id, oldOneFirst.id, oldOneTool.id, oldOneFinal.id,
                        source2.id, currentTwo.id])
    }
}
