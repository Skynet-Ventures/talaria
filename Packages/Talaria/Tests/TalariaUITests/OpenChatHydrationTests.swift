#if canImport(XCTest)
import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class OpenChatHydrationTests: XCTestCase {
    @MainActor
    override func tearDown() {
        CanonicalChatRuntime.shared.opens.removeValue(forKey: "hermes")
        LiveRuntime.shared.attachTasks.removeValue(forKey: "hermes")
        LiveRuntime.shared.lastSessionByBot.removeValue(forKey: "hermes")
        LiveRuntime.shared.canonicalSessionByBot.removeValue(forKey: "hermes")
        super.tearDown()
    }

    @MainActor
    func testDeferredStubPaintsBeforeRESTPageArrives() async throws {
        let chat = ChatState()
        let barrier = OpenChatPageBarrier()
        let hydration = Task<Void, Error> { @MainActor in
            try await AppModel.hydrateOpenChatTranscript(
                chat: chat,
                resumeMessages: [
                    .object(["role": .string("user"), "text": .string("stub"), "row_id": .number(1)]),
                ],
                historyDeferred: true,
                clearWhenEmpty: true,
                latestPage: { await barrier.load() },
                accepts: { true })
        }

        await barrier.waitUntilEntered()
        XCTAssertEqual(chat.messages.map(\.text), ["stub"],
                       "first paint must not wait for the REST page")
        XCTAssertFalse(chat.transcriptHasOlder)

        let page: JSONValue = ["messages": [
            ["role": "user", "text": "full question", "row_id": 10],
            ["role": "assistant", "text": "full answer", "row_id": 11],
        ]]
        await barrier.release(page)
        try await hydration.value
        XCTAssertEqual(chat.messages.map(\.text), ["full question", "full answer"])
        XCTAssertEqual(chat.messages.map(\.rowID), [10, 11])
        XCTAssertFalse(chat.messages.contains(where: { $0.text == "stub" }),
                       "the deferred stub must not remain after the latest page lands")
        XCTAssertFalse(chat.transcriptHasOlder)
        XCTAssertEqual(chat.transcriptOlderOffset, 2)
    }

    @MainActor
    func testOptimisticSendDuringLatestPageIsPreserved() async throws {
        let chat = ChatState()
        let barrier = OpenChatPageBarrier()
        let hydration = Task<Void, Error> { @MainActor in
            try await AppModel.hydrateOpenChatTranscript(
                chat: chat,
                resumeMessages: [
                    .object(["role": .string("assistant"), "text": .string("old"), "row_id": .number(2)]),
                ],
                historyDeferred: true,
                clearWhenEmpty: false,
                latestPage: { await barrier.load() },
                accepts: { true })
        }

        await barrier.waitUntilEntered()
        chat.messages.append(ChatMessage(author: .user, text: "new question"))
        let page: JSONValue = ["messages": [
            ["role": "assistant", "text": "old", "row_id": 2],
            ["role": "user", "text": "prior", "row_id": 3],
        ]]
        await barrier.release(page)
        try await hydration.value

        XCTAssertTrue(chat.messages.contains(where: {
            $0.author == .user && $0.text == "new question"
        }))
        XCTAssertTrue(chat.messages.contains(where: { $0.rowID == 2 }))
    }

    @MainActor
    func testFullResumePageIsNotTruncatedBySmallerRESTWindow() async throws {
        let chat = ChatState()
        var pageReads = 0
        let resume = (1...5).map { index -> JSONValue in
            .object([
                "role": .string(index % 2 == 0 ? "assistant" : "user"),
                "text": .string("row-\(index)"),
                "row_id": .number(Double(index)),
            ])
        }

        try await AppModel.hydrateOpenChatTranscript(
            chat: chat,
            resumeMessages: resume,
            historyDeferred: true,
            clearWhenEmpty: true,
            firstPageLimit: 2,
            latestPage: {
                pageReads += 1
                let page: JSONValue = ["messages": [
                    ["role": "user", "text": "row-4", "row_id": 4],
                    ["role": "assistant", "text": "row-5", "row_id": 5],
                ]]
                return page
            },
            accepts: { true })

        XCTAssertEqual(pageReads, 1, "deferred resume must still request the latest page")
        XCTAssertEqual(chat.messages.map(\.text), ["row-1", "row-2", "row-3", "row-4", "row-5"])
        XCTAssertFalse(chat.transcriptHasOlder,
                       "a larger resume projection is the full window, not a truncated page")
    }

    @MainActor
    func testLatestPageMarksOlderHistoryWhenItHitsTheLimit() async throws {
        let chat = ChatState()
        let rows = (1...OpenChatHistoryPolicy.firstPageLimit).map { index -> [String: JSONValue] in
            [
                "role": .string("assistant"),
                "text": .string("m\(index)"),
                "row_id": .number(Double(index)),
            ]
        }

        try await AppModel.hydrateOpenChatTranscript(
            chat: chat,
            resumeMessages: [],
            historyDeferred: true,
            clearWhenEmpty: true,
            latestPage: { ["messages": .array(rows.map(JSONValue.object))] },
            accepts: { true })

        XCTAssertEqual(chat.messages.count, OpenChatHistoryPolicy.firstPageLimit)
        XCTAssertTrue(chat.transcriptHasOlder)
        XCTAssertEqual(chat.transcriptOlderOffset, OpenChatHistoryPolicy.firstPageLimit)
    }

    @MainActor
    func testEmptyLatestPageDoesNotClobberPopulatedLocalRows() async throws {
        let cached = [
            ChatMessage(author: .user, text: "still on the phone"),
            ChatMessage(author: .bot, text: "gateway still has this"),
        ]
        let chat = ChatState(messages: cached)

        try await AppModel.hydrateOpenChatTranscript(
            chat: chat,
            resumeMessages: [],
            historyDeferred: true,
            clearWhenEmpty: true,
            latestPage: { ["messages": []] },
            accepts: { true })

        XCTAssertEqual(chat.messages.map(\.text), cached.map(\.text))
    }

    @MainActor
    func testFailedLatestPageKeepsCachedOrStubRows() async throws {
        let cached = ChatMessage(author: .bot, text: "already on screen", rowID: 7)
        let chat = ChatState(messages: [cached])

        try await AppModel.hydrateOpenChatTranscript(
            chat: chat,
            resumeMessages: [
                .object(["role": .string("assistant"), "text": .string("stub"), "row_id": .number(8)]),
            ],
            historyDeferred: true,
            clearWhenEmpty: true,
            latestPage: { nil },
            accepts: { true })

        XCTAssertTrue(chat.messages.contains(where: { $0.text == "stub" }))
        XCTAssertTrue(chat.messages.contains(where: { $0.text == "already on screen" }))
    }

    func testSameBindingTreatsRootAndResumeTipAsOneConversation() {
        XCTAssertTrue(AppModel.sameOpenChatBinding(
            "root", target: "tip", durableID: "root"))
        XCTAssertTrue(AppModel.sameOpenChatBinding(
            "tip", target: "tip", durableID: "root"))
        XCTAssertFalse(AppModel.sameOpenChatBinding(
            "other", target: "tip", durableID: "root"))
        XCTAssertFalse(AppModel.sameOpenChatBinding(
            nil, target: "tip", durableID: "root"))
    }

    func testTitleOnlyResumeDoesNotPrefetchREST() {
        XCTAssertNil(AppModel.attachRestTarget("Bot Chat", durableID: nil))
        XCTAssertEqual(AppModel.attachRestTarget("Bot Chat", durableID: "root"), "root")
        XCTAssertEqual(AppModel.attachRestTarget("stored-1", durableID: nil), "stored-1")
    }

    func testDeferredResumeDropsGiantGatewayDump() {
        let dump = (1...20).map { index -> JSONValue in
            .object([
                "role": .string("assistant"),
                "text": .string("m\(index)"),
                "row_id": .number(Double(index)),
            ])
        }
        XCTAssertTrue(
            OpenChatHistoryPolicy.openChatResumeMessages(dump, historyDeferred: true).isEmpty,
            "Mini dumped a 584-msg forever-chat despite defer_history; drop it")
        XCTAssertEqual(
            OpenChatHistoryPolicy.openChatResumeMessages(dump, historyDeferred: false).count, 20)
    }

    @MainActor
    func testEnterCanonicalChatDoesNotAwaitInflightAttach() async {
        let model = AppModel()
        model.mode = .live
        model.isOffline = false
        defer {
            CanonicalChatRuntime.shared.opens.removeValue(forKey: "hermes")
            LiveRuntime.shared.attachTasks.removeValue(forKey: "hermes")
        }

        var held: CheckedContinuation<Void, Never>?
        let hung = Task<Void, Never> { @MainActor in
            await withCheckedContinuation { held = $0 }
        }
        // A hung attach (fat resume) must not block the open path.
        LiveRuntime.shared.attachTasks["hermes"] = Task { @MainActor in
            await hung.value
            return "sid"
        }
        CanonicalChatRuntime.shared.opens["hermes"] = Task { @MainActor in
            await hung.value
        }

        let started = ContinuousClock.now
        await model.enterCanonicalChat(botID: "hermes")
        let elapsed = ContinuousClock.now - started
        XCTAssertLessThan(elapsed, .milliseconds(500),
                          "default-chat open must not wait on a fat resume attach")

        for _ in 0..<50 where held == nil { await Task.yield() }
        held?.resume()
        hung.cancel()
        CanonicalChatRuntime.shared.opens.removeValue(forKey: "hermes")
        LiveRuntime.shared.attachTasks.removeValue(forKey: "hermes")
    }

    @MainActor
    func testEnterCanonicalChatReturnsBeforeBackgroundAttachFinishes() async {
        let model = AppModel()
        model.mode = .live
        model.isOffline = false
        model.bots = [Bot(id: "hermes", job: "home", shape: .circle, hue: .blue,
                          preview: "cached")]
        defer {
            CanonicalChatRuntime.shared.opens.removeValue(forKey: "hermes")
        }

        let started = ContinuousClock.now
        await model.enterCanonicalChat(botID: "hermes")
        let elapsed = ContinuousClock.now - started
        XCTAssertLessThan(elapsed, .milliseconds(500),
                          "open must return before attachCanonicalSession/resume")
        // Open schedules background attach and returns; the slot is set
        // before return even when the attach later fails for no-route.
        XCTAssertNotNil(CanonicalChatRuntime.shared.opens["hermes"])
        await CanonicalChatRuntime.shared.opens["hermes"]?.value
    }
}

private actor OpenChatPageBarrier {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<JSONValue?, Never>?

    func load() async -> JSONValue? {
        entered = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters.removeAll()
        return await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release(_ value: JSONValue?) async {
        releaseContinuation?.resume(returning: value)
        releaseContinuation = nil
    }
}
#endif
