import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class AssistantResponseAlternativesRuntimeTests: XCTestCase {
    @MainActor
    private func stage(
        botID: String, chat: ChatState,
        operationID: UUID = UUID(), previousSourceUserID: UUID,
        sourceUserID: UUID, previousAssistantRun: [ChatMessage],
        invalidatedSourceUserIDs: Set<UUID> = []
    ) -> TranscriptActionLease {
        let route = try! XCTUnwrap(GatewayBotRoute(qualifiedID: botID))
        let binding = AssistantResponseAlternativesBinding(
            chatID: chat.chatIdentity, sourceUserID: sourceUserID,
            storedSessionID: chat.storedSessionID ?? "stored",
            runtimeSessionID: chat.sessionID ?? "runtime",
            gatewayID: route.gatewayID, profile: route.profile)
        ChatRuntime.shared.assistantResponseAlternativeStages[botID] =
            AssistantResponseAlternativeStage(
                operationID: operationID, botID: botID,
                chatID: ObjectIdentifier(chat), binding: binding,
                previousSourceUserID: previousSourceUserID,
                invalidatedSourceUserIDs: invalidatedSourceUserIDs,
                previousAssistantRun: previousAssistantRun)
        return TranscriptActionLease(
            id: operationID, botID: botID,
            sessionID: chat.sessionID ?? "runtime",
            storedID: chat.storedSessionID ?? "stored",
            gatewayID: route.gatewayID, profile: route.profile,
            generation: LiveRuntime.shared.generation,
            chatID: ObjectIdentifier(chat), optimisticID: sourceUserID,
            baseline: chat.messages)
    }

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
                previousSourceUserID: source.id,
                invalidatedSourceUserIDs: [],
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

    @MainActor
    func testThreeSuccessiveRegeneratesMigrateOneGroupAndAppendAllRuns() throws {
        let model = AppModel()
        let botID = "gateway::alternatives-three-\(UUID().uuidString)"
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        var source = ChatMessage(author: .user, text: "prompt 0")
        var current = ChatMessage(author: .bot, text: "answer 0")
        chat.messages = [source, current]
        var groupID: UUID?

        for index in 1...3 {
            let replacement = ChatMessage(author: .user, text: "prompt \(index)")
            let next = ChatMessage(author: .bot, text: "answer \(index)")
            chat.messages = [replacement, next]
            let lease = stage(
                botID: botID, chat: chat,
                previousSourceUserID: source.id, sourceUserID: replacement.id,
                previousAssistantRun: [current])
            XCTAssertTrue(model.commitAssistantResponseAlternativeIfProven(lease))
            groupID = groupID ?? chat.assistantResponseAlternatives.groups.first?.id
            source = replacement
            current = next
        }
        defer {
            ChatRuntime.shared.assistantResponseAlternativeStages[botID] = nil
            model.chats.removeValue(forKey: botID)
        }

        let group = try XCTUnwrap(chat.assistantResponseAlternatives.groups.first)
        XCTAssertEqual(chat.assistantResponseAlternatives.groups.count, 1)
        XCTAssertEqual(group.id, groupID)
        XCTAssertEqual(group.alternatives.count, 3)
        XCTAssertEqual(group.alternatives.map { $0.messages[0].text },
                       ["answer 0", "answer 1", "answer 2"])
        XCTAssertNil(chat.assistantResponseAlternatives.selectedAlternativeIndex)
        XCTAssertEqual(
            AssistantResponseAlternativesPolicy.responsePosition(groupID: group.id,
                                                                  in: chat.assistantResponseAlternatives)?.total,
            4)
    }

    @MainActor
    func testDefiniteRefusalDropsOnlyUncommittedStage() throws {
        let model = AppModel()
        let botID = "gateway::alternatives-refusal-\(UUID().uuidString)"
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let firstSource = ChatMessage(author: .user, text: "prompt 0")
        let firstReplacement = ChatMessage(author: .user, text: "prompt 1")
        let firstRun = ChatMessage(author: .bot, text: "answer 0")
        chat.messages = [firstReplacement, ChatMessage(author: .bot, text: "answer 1")]
        let firstLease = stage(
            botID: botID, chat: chat,
            previousSourceUserID: firstSource.id, sourceUserID: firstReplacement.id,
            previousAssistantRun: [firstRun])
        XCTAssertTrue(model.commitAssistantResponseAlternativeIfProven(firstLease))
        let committed = try XCTUnwrap(chat.assistantResponseAlternatives.groups.first)

        let secondSource = firstReplacement
        let secondReplacement = ChatMessage(author: .user, text: "prompt 2")
        chat.messages = [secondReplacement, ChatMessage(author: .bot, text: "answer 2")]
        let refusalLease = stage(
            botID: botID, chat: chat,
            previousSourceUserID: secondSource.id, sourceUserID: secondReplacement.id,
            previousAssistantRun: [ChatMessage(author: .bot, text: "answer 1")])
        model.clearAssistantResponseAlternativeIfOwned(refusalLease)
        defer {
            ChatRuntime.shared.assistantResponseAlternativeStages[botID] = nil
            model.chats.removeValue(forKey: botID)
        }

        XCTAssertEqual(chat.assistantResponseAlternatives.groups.count, 1)
        XCTAssertEqual(chat.assistantResponseAlternatives.groups[0], committed)
    }

    @MainActor
    func testRegeneratePrunesOnlyGroupsFromDestructivelyTruncatedLaterTurns() throws {
        let model = AppModel()
        let botID = "gateway::alternatives-prune-\(UUID().uuidString)"
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        let older = ChatMessage(author: .user, text: "older")
        let later = ChatMessage(author: .user, text: "later")
        let replacement = ChatMessage(author: .user, text: "older replacement")
        chat.messages = [replacement, ChatMessage(author: .bot, text: "current")]
        let route = try XCTUnwrap(GatewayBotRoute(qualifiedID: botID))
        let olderBinding = AssistantResponseAlternativesBinding(
            chatID: chat.chatIdentity, sourceUserID: older.id,
            storedSessionID: "stored", runtimeSessionID: "runtime",
            gatewayID: route.gatewayID, profile: route.profile)
        let laterBinding = AssistantResponseAlternativesBinding(
            chatID: chat.chatIdentity, sourceUserID: later.id,
            storedSessionID: "stored", runtimeSessionID: "runtime",
            gatewayID: route.gatewayID, profile: route.profile)
        var shelf = AssistantResponseAlternativesPolicy.record(
            [ChatMessage(author: .bot, text: "older answer")], binding: olderBinding)
        shelf = AssistantResponseAlternativesPolicy.record(
            [ChatMessage(author: .bot, text: "later answer")], binding: laterBinding,
            state: shelf)
        chat.assistantResponseAlternatives = shelf
        chat.assistantResponseBinding = laterBinding

        let lease = stage(
            botID: botID, chat: chat,
            previousSourceUserID: older.id, sourceUserID: replacement.id,
            previousAssistantRun: [ChatMessage(author: .bot, text: "current")],
            invalidatedSourceUserIDs: [later.id])
        XCTAssertTrue(model.commitAssistantResponseAlternativeIfProven(lease))
        defer {
            ChatRuntime.shared.assistantResponseAlternativeStages[botID] = nil
            model.chats.removeValue(forKey: botID)
        }

        XCTAssertEqual(chat.assistantResponseAlternatives.groups.count, 1)
        XCTAssertEqual(chat.assistantResponseAlternatives.groups[0].binding.sourceUserID,
                       replacement.id)
        XCTAssertEqual(chat.assistantResponseAlternatives.groups[0].alternatives.count, 2)
        XCTAssertFalse(chat.assistantResponseAlternatives.groups.contains {
            $0.binding.sourceUserID == later.id
        })
    }

    @MainActor
    func testSelectionCanAddressEveryGroupWithOneArchivedProjection() throws {
        let chat = ChatState()
        let source1 = ChatMessage(author: .user, text: "one")
        let source2 = ChatMessage(author: .user, text: "two")
        let current1 = ChatMessage(author: .bot, text: "current one")
        let current2 = ChatMessage(author: .bot, text: "current two")
        chat.messages = [source1, current1, source2, current2]
        let key1 = AssistantResponseAlternativesBinding(
            chatID: chat.chatIdentity, sourceUserID: source1.id,
            storedSessionID: "stored", runtimeSessionID: "runtime",
            gatewayID: "gateway", profile: "worker")
        let key2 = AssistantResponseAlternativesBinding(
            chatID: chat.chatIdentity, sourceUserID: source2.id,
            storedSessionID: "stored", runtimeSessionID: "runtime",
            gatewayID: "gateway", profile: "worker")
        var state = AssistantResponseAlternativesPolicy.record(
            [ChatMessage(author: .bot, text: "old one")], binding: key1)
        state = AssistantResponseAlternativesPolicy.record(
            [ChatMessage(author: .bot, text: "old two")], binding: key2, state: state)
        chat.assistantResponseAlternatives = state
        chat.assistantResponseBinding = key2

        XCTAssertTrue(chat.selectAssistantResponseGroup(
            try XCTUnwrap(state.groups.first?.id), archivedIndex: 0))
        XCTAssertEqual(chat.displayedMessages().map(\.text),
                       ["one", "old one", "two", "current two"])
        XCTAssertTrue(chat.selectAssistantResponseGroup(
            try XCTUnwrap(state.groups.last?.id), archivedIndex: 0))
        XCTAssertEqual(chat.displayedMessages().map(\.text),
                       ["one", "current one", "two", "old two"])
        XCTAssertEqual(chat.assistantResponseAlternatives.selectedGroupID,
                       state.groups.last?.id)
    }
}
