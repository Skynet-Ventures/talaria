import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class AssistantResponseAlternativesRuntimeTests: XCTestCase {
    @MainActor
    func testRegeneratePlanCapturesSourceAndCompleteOldAssistantRun() throws {
        let source = ChatMessage(author: .user, text: "prompt", rowID: 1)
        let first = ChatMessage(author: .bot, text: "first", reasoning: "thought", rowID: 2)
        let toolOnly = ChatMessage(author: .bot, text: "", toolCalls: [
            ToolCall(id: "tool", name: "terminal", context: "echo", state: .failed,
                     resultText: "failed")
        ], rowID: 3)
        let later = ChatMessage(author: .user, text: "later", rowID: 4)
        let plan: TranscriptActing.Plan = try XCTUnwrap(TranscriptActing.planReload(
            [source, first, toolOnly, later], from: first.id))

        XCTAssertEqual(plan.kind, TranscriptActing.Plan.Kind.regenerate)
        XCTAssertEqual(plan.sourceUserID, source.id)
        XCTAssertEqual(plan.previousAssistantRun, [first, toolOnly])
        XCTAssertEqual(TranscriptActing.truncateParams(plan.truncate), [
            "confirm_truncate": .bool(true),
            "truncate_before_row_id": .number(1),
            "confirm_empty_truncate": .bool(true),
        ])
    }

    @MainActor
    func testBindingReplacementClearsLocalShelf() {
        let chat = ChatState()
        let source = ChatMessage(author: .user, text: "prompt")
        let key = AssistantResponseAlternativesBinding(
            chatID: chat.chatIdentity, sourceUserID: source.id,
            storedSessionID: "stored-a", runtimeSessionID: "runtime-a",
            gatewayID: "gateway", profile: "worker")
        chat.messages = [source, ChatMessage(author: .bot, text: "new")]
        chat.assistantResponseBinding = key
        chat.assistantResponseAlternatives = AssistantResponseAlternativesPolicy.record(
            [ChatMessage(author: .bot, text: "old")], binding: key)
        XCTAssertFalse(chat.assistantResponseAlternatives.groups.isEmpty)

        chat.sessionID = "runtime-b"
        XCTAssertTrue(chat.assistantResponseAlternatives.groups.isEmpty)
        XCTAssertNil(chat.assistantResponseBinding)

        chat.assistantResponseBinding = key
        chat.assistantResponseAlternatives = AssistantResponseAlternativesPolicy.record(
            [ChatMessage(author: .bot, text: "old")], binding: key)
        chat.storedSessionID = "stored-b"
        XCTAssertTrue(chat.assistantResponseAlternatives.groups.isEmpty)
    }

    @MainActor
    func testOrdinarySendReturnsSelectionToNewestBeforeSubmission() {
        let model = AppModel()
        model.mode = .demo
        let chat = model.chat(for: "worker")
        let source = ChatMessage(author: .user, text: "prompt")
        let key = AssistantResponseAlternativesBinding(
            chatID: chat.chatIdentity, sourceUserID: source.id,
            storedSessionID: "", runtimeSessionID: "", gatewayID: "", profile: "worker")
        chat.assistantResponseBinding = key
        chat.assistantResponseAlternatives = AssistantResponseAlternativesPolicy.record(
            [ChatMessage(author: .bot, text: "old")], binding: key)
        let groupID = try! XCTUnwrap(chat.assistantResponseAlternatives.selectedGroupID)
        chat.assistantResponseAlternatives = AssistantResponseAlternativesPolicy.select(
            groupID: groupID, archivedIndex: 0,
            in: chat.assistantResponseAlternatives)
        XCTAssertTrue(chat.isShowingArchivedResponseAlternative)

        XCTAssertTrue(model.send(text: "new prompt", to: "worker"))
        XCTAssertFalse(chat.isShowingArchivedResponseAlternative)
        ChatRuntime.shared.demoTurns["worker"]?.cancel()
        ChatRuntime.shared.demoTurns["worker"] = nil
    }

    @MainActor
    func testFindIndexesOnlySelectedDisplayedProjection() throws {
        let source = ChatMessage(author: .user, text: "prompt")
        let current = ChatMessage(author: .bot, text: "current-only")
        let old = ChatMessage(author: .bot, text: "archived-only")
        let key = AssistantResponseAlternativesBinding(
            chatID: UUID(), sourceUserID: source.id,
            storedSessionID: "stored", runtimeSessionID: "runtime",
            gatewayID: "gateway", profile: "worker")
        var state = AssistantResponseAlternativesPolicy.record([old], binding: key)
        state = AssistantResponseAlternativesPolicy.select(
            groupID: try XCTUnwrap(state.selectedGroupID), archivedIndex: 0, in: state)
        let displayed = AssistantResponseAlternativesPolicy.displayedMessages(
            current: [source, current], state: state, binding: key)
        let index = try TranscriptFindPolicy.makeIndex(messages: displayed)
        XCTAssertEqual(try TranscriptFindPolicy.search("archived-only", in: index).total, 1)
        XCTAssertEqual(try TranscriptFindPolicy.search("current-only", in: index).total, 0)
    }

    @MainActor
    func testAcceptedOrProvenStageCommitsExactlyOnceAndAmbiguousStageIsNotVisible() {
        let model = AppModel()
        let botID = "gateway::worker"
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let source = ChatMessage(author: .user, text: "prompt")
        chat.messages = [source, ChatMessage(author: .user, text: "replacement")]
        let operationID = UUID()
        let route = GatewayBotRoute(gatewayID: "gateway", profile: "worker")
        let binding = AssistantResponseAlternativesBinding(
            chatID: chat.chatIdentity, sourceUserID: chat.messages[1].id,
            storedSessionID: "stored", runtimeSessionID: "runtime",
            gatewayID: route.gatewayID, profile: route.profile)
        ChatRuntime.shared.assistantResponseAlternativeStages[botID] =
            AssistantResponseAlternativeStage(
                operationID: operationID, botID: botID,
                chatID: ObjectIdentifier(chat), binding: binding,
                previousAssistantRun: [ChatMessage(author: .bot, text: "old")])
        let lease = TranscriptActionLease(
            id: operationID, botID: botID, sessionID: "runtime", storedID: "stored",
            gatewayID: route.gatewayID, profile: route.profile,
            generation: LiveRuntime.shared.generation, chatID: ObjectIdentifier(chat),
            optimisticID: chat.messages[1].id, baseline: [source])
        defer {
            ChatRuntime.shared.assistantResponseAlternativeStages[botID] = nil
            model.chats.removeValue(forKey: botID)
        }

        XCTAssertTrue(chat.assistantResponseAlternatives.groups.isEmpty,
                      "an ambiguous staged receipt has no visible group")
        XCTAssertTrue(model.commitAssistantResponseAlternativeIfProven(lease))
        XCTAssertFalse(model.commitAssistantResponseAlternativeIfProven(lease),
                       "the same accepted/effect-proof lease cannot append twice")
        XCTAssertEqual(chat.assistantResponseAlternatives.groups.count, 1)
        XCTAssertEqual(chat.assistantResponseAlternatives.groups[0].alternatives.count, 1)
    }
}
