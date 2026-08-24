#if canImport(XCTest)
import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class TranscriptBackfillTests: XCTestCase {
    private actor StoredPageGate {
        enum Plan: Sendable {
            case data(Data)
            case gatewayError(Int)
        }

        private var plans: [Plan]
        private var hold = false
        private var held: CheckedContinuation<Plan, Never>?
        private var didStart = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private(set) var attempts = 0

        init(plans: [Plan]) { self.plans = plans }

        func holdNextRead() { hold = true }

        func next() async -> Plan {
            attempts += 1
            didStart = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if hold {
                hold = false
                return await withCheckedContinuation { held = $0 }
            }
            return plans.removeFirst()
        }

        func waitForStart() async {
            guard !didStart else { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func release(_ plan: Plan) {
            held?.resume(returning: plan)
            held = nil
        }

        func attemptCount() -> Int { attempts }
    }

    private func row(_ id: Int? = nil, role: String = "user", text: String,
                     compacted: Bool = false, extra: [String: JSONValue] = [:]) -> JSONValue {
        var value: [String: JSONValue] = [
            "role": .string(role),
            "content": .string(text),
            "timestamp": .number(1_700_000_000),
        ]
        if let id { value["id"] = .number(Double(id)) }
        if compacted {
            value["compacted"] = .number(1)
            value["active"] = .number(0)
        }
        for (key, item) in extra { value[key] = item }
        return .object(value)
    }

    private func page(source: StoredTranscriptPageSource, rows: [JSONValue],
                      offset: Int, limit: Int = 2, tip: String = "tip",
                      total: Int? = nil, hasMore: Bool? = nil) throws -> StoredTranscriptPage {
        var pagination: [String: JSONValue] = [
            "limit": .number(Double(limit)),
            "offset": .number(Double(offset)),
            "order": .string("latest"),
            "returned": .number(Double(rows.count)),
        ]
        if let total { pagination["total"] = .number(Double(total)) }
        if let hasMore { pagination["has_more"] = .bool(hasMore) }
        return try StoredTranscriptPage(payload: .object([
            "session_id": .string(tip),
            "messages": .array(rows),
            "pagination": .object(pagination),
        ]), request: StoredTranscriptPageRequest(source: source, offset: offset,
                                                  limit: limit, includeCompacted: true))
    }

    private func source(_ gateway: String = "gateway-a") -> StoredTranscriptPageSource {
        StoredTranscriptPageSource(gatewayID: gateway, profile: "research",
                                  storedSessionID: "root-session")
    }

    private func pageData(source: StoredTranscriptPageSource, rows: [JSONValue],
                          offset: Int, total: Int, hasMore: Bool,
                          tip: String = "tip") throws -> Data {
        var pagination: [String: JSONValue] = [
            "limit": .number(200),
            "offset": .number(Double(offset)),
            "order": .string("latest"),
            "returned": .number(Double(rows.count)),
            "total": .number(Double(total)),
            "has_more": .bool(hasMore),
        ]
        // The source page contract treats an omitted compacted echo as a
        // compatibility field; include it here to prove the actual request
        // path still carries the durable-history setting.
        pagination["include_compacted"] = .bool(true)
        return try JSONEncoder().encode(JSONValue.object([
            "session_id": .string(tip), "messages": .array(rows),
            "pagination": .object(pagination),
        ]))
    }

    private func client(gate: StoredPageGate) throws -> GatewayClient {
        GatewayClient(
            baseURL: try XCTUnwrap(URL(string: "https://gateway.example")),
            credential: .sessionToken("test"),
            restExecutor: { request, _ in
                switch await gate.next() {
                case .data(let data):
                    return (data, HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"])!)
                case .gatewayError(let code):
                    throw GatewayError(code: code, message: "planned failure")
                }
            })
    }

    @MainActor
    private func installLiveLedger(model: AppModel, client: GatewayClient,
                                   gatewayID: String)
        async throws -> (ChatState, StoredTranscriptPageSource, String) {
        model.mode = .live
        model.client = client
        LiveRuntime.shared.gatewayID = gatewayID
        let route = GatewayBotRoute(gatewayID: gatewayID, profile: "research")
        let botID = route.qualifiedID
        let chat = model.chat(for: botID)
        chat.sessionID = "runtime"
        chat.storedSessionID = "root-session"
        let exact = StoredTranscriptPageSource(
            gatewayID: gatewayID, profile: route.profile, storedSessionID: "root-session")
        let tailRows = [row(3, text: "third")]
            + (4...202).map { row($0, text: "tail-\(String($0))") }
        let tail = try page(source: exact, rows: tailRows, offset: 0, limit: 200,
                            total: 202, hasMore: true)
        XCTAssertEqual(model.gatewayRoute(for: botID), route)
        let capturedAuthority = await model.captureTranscriptHydrationSourceAuthority(
            route: route, client: client)
        let authority = try XCTUnwrap(capturedAuthority)
        await model.installTranscriptBackfillTail(
            tail, botID: botID, chat: chat, route: route, authority: authority,
            runtimeSessionID: "runtime")
        XCTAssertEqual(chat.transcriptBackfill.status, .more)
        return (chat, exact, botID)
    }

    func testFullShortAndUnknownPagesProduceHonestBackfillStates() throws {
        let exact = source()
        let full = try page(source: exact, rows: [
            row(3, text: "third"), row(4, text: "fourth"),
        ], offset: 0, total: 4, hasMore: true)
        var ledger = try StoredTranscriptBackfillLedger(tail: full, source: exact)
        XCTAssertEqual(ledger.status, .more)
        XCTAssertEqual(ledger.nextOffset, 2)

        _ = try ledger.prepend(page(source: exact, rows: [row(1, text: "first")],
                                    offset: 2, total: 3, hasMore: false))
        XCTAssertEqual(ledger.status, .exhausted)
        XCTAssertNil(ledger.nextOffset)

        let unknownTail = try page(source: exact, rows: [
            row(3, text: "third"), row(4, text: "fourth"),
        ], offset: 0)
        var unknown = try StoredTranscriptBackfillLedger(tail: unknownTail, source: exact)
        XCTAssertEqual(unknown.status, .unknown)
        XCTAssertEqual(unknown.nextOffset, 2)
        _ = try unknown.prepend(page(source: exact, rows: [row(2, text: "second")],
                                     offset: 2))
        XCTAssertEqual(unknown.status, .exhausted,
                       "a short page proves the older direction is complete")
    }

    func testRepeatedPagesStopAtFiniteForegroundLedgerLimit() throws {
        let exact = source()
        let pageSize = StoredTranscriptPageRequest.defaultLimit
        let serverTotal = TranscriptBackfillLimits.maximumRetainedRows + pageSize
        let newestStart = serverTotal - pageSize + 1
        let tail = try page(
            source: exact,
            rows: (newestStart...serverTotal).map { row($0, text: "row-\($0)") },
            offset: 0, limit: pageSize, total: serverTotal, hasMore: true)
        var ledger = try StoredTranscriptBackfillLedger(tail: tail, source: exact)

        for offset in stride(from: pageSize,
                             through: TranscriptBackfillLimits.maximumRetainedRows - pageSize,
                             by: pageSize) {
            let upper = serverTotal - offset
            let lower = upper - pageSize + 1
            _ = try ledger.prepend(page(
                source: exact,
                rows: (lower...upper).map { row($0, text: "row-\($0)") },
                offset: offset, limit: pageSize, total: serverTotal, hasMore: true))
        }

        XCTAssertEqual(ledger.rows.count, TranscriptBackfillLimits.maximumRetainedRows)
        XCTAssertEqual(ledger.status, .limited)
        XCTAssertNil(ledger.nextOffset)
    }

    func testCompactionAndResolvedTipNeverRewriteDurableRoot() throws {
        let exact = source()
        let tail = try page(source: exact, rows: [
            row(2, text: "compacted", compacted: true), row(3, text: "tail"),
        ], offset: 0, tip: "resolved-tip-a", total: 4, hasMore: true)
        var ledger = try StoredTranscriptBackfillLedger(tail: tail, source: exact)
        XCTAssertEqual(ledger.rootStoredSessionID, "root-session")
        XCTAssertEqual(ledger.resolvedSessionID, "resolved-tip-a")
        XCTAssertTrue(ledger.rows.first?.isCompacted == true)

        _ = try ledger.prepend(page(source: exact, rows: [row(1, text: "older")],
                                    offset: 2, tip: "resolved-tip-b", total: 3,
                                    hasMore: false))
        XCTAssertEqual(ledger.rootStoredSessionID, "root-session")
        XCTAssertEqual(ledger.source.storedSessionID, "root-session")
        XCTAssertEqual(ledger.resolvedSessionID, "resolved-tip-b")
    }

    func testAppendBetweenReversePagesUsesOnlyDurableIdentityOverlap() throws {
        let exact = source()
        let tail = try page(source: exact, rows: [
            row(30, text: "same words"), row(31, text: "tail"),
        ], offset: 0, total: 4, hasMore: true)
        var ledger = try StoredTranscriptBackfillLedger(tail: tail, source: exact)
        // A new tail row can shift `offset: 2`; the page overlaps the retained
        // id 30. Its repeated body is deliberately irrelevant to the merge.
        let older = try page(source: exact, rows: [
            row(28, text: "same words"), row(30, text: "same words"),
        ], offset: 2, total: 5, hasMore: true)
        let fresh = try ledger.prepend(older)

        XCTAssertEqual(fresh.compactMap(\.rowID), [28])
        XCTAssertEqual(ledger.rows.compactMap(\.rowID), [28, 30, 31])
        XCTAssertEqual(Set(ledger.rows.compactMap(\.identity)).count, ledger.rows.count)
    }

    func testForeignSourceAndIdentitylessSeamAreRejectedRatherThanGuessed() throws {
        let exact = source()
        let tail = try page(source: exact, rows: [row(3, text: "tail"), row(4, text: "tail")],
                            offset: 0, total: 4, hasMore: true)
        var ledger = try StoredTranscriptBackfillLedger(tail: tail, source: exact)
        let foreign = source("gateway-b")
        XCTAssertThrowsError(try ledger.prepend(page(source: foreign,
                                                     rows: [row(1, text: "older")],
                                                     offset: 2, total: 3, hasMore: false))) {
            XCTAssertEqual($0 as? StoredTranscriptBackfillLedger.MergeError, .sourceMismatch)
        }

        let idlessTail = try page(source: exact, rows: [
            row(nil, text: "same text"), row(4, text: "tail"),
        ], offset: 0, total: 4, hasMore: true)
        var idless = try StoredTranscriptBackfillLedger(tail: idlessTail, source: exact)
        XCTAssertThrowsError(try idless.prepend(page(source: exact,
                                                      rows: [row(1, text: "same text")],
                                                      offset: 2, total: 3, hasMore: false))) {
            XCTAssertEqual($0 as? StoredTranscriptBackfillLedger.MergeError, .identitylessOverlap)
        }
    }

    @MainActor
    func testRawLedgerRehydratesOrderedPartsAndToolResultsAcrossPageSeam() throws {
        let exact = source()
        let toolCall: JSONValue = [
            "id": "call-1",
            "function": ["name": "terminal", "arguments": "{\"command\":\"pwd\"}"],
        ]
        let older = row(1, role: "assistant", text: "", extra: [
            "tool_calls": .array([toolCall]),
        ])
        let tail = try page(source: exact, rows: [
            row(2, role: "tool", text: "{\"stdout\":\"/tmp\"}", extra: [
                "tool_call_id": .string("call-1"), "tool_name": .string("terminal"),
            ]),
            row(3, role: "assistant", text: "Done", extra: [
                "parts_version": .number(1),
                "parts": .array([
                    ["kind": "text", "id": "answer", "text": "Done"],
                    ["kind": "image", "id": "image", "ref": "artifact://result"],
                ]),
            ]),
        ], offset: 0, total: 3, hasMore: true)
        var ledger = try StoredTranscriptBackfillLedger(tail: tail, source: exact)
        _ = try ledger.prepend(page(source: exact, rows: [older], offset: 2,
                                    total: 3, hasMore: false))

        let hydrated = AppModel.chatMessages(
            fromTranscript: .array(ledger.rows.map(\.raw)), maximumRows: ledger.rows.count)
        let message = try XCTUnwrap(hydrated.last)
        XCTAssertEqual(message.text, "Done")
        XCTAssertEqual(message.toolCalls.first?.gatewayToolID, "call-1")
        XCTAssertEqual(message.toolCalls.first?.structuredOutput?.stdout?.plainText, "/tmp")
        XCTAssertEqual(message.orderedParts?.parts.map(\.kind), [.text, .image])
    }

    func testTopControlCopyAndReaderAnchorPolicyStayHonest() {
        XCTAssertEqual(TranscriptBackfillPresentation(status: .loading).controlTitle,
                       "Loading earlier messages…")
        XCTAssertEqual(TranscriptBackfillPresentation(status: .exhausted).controlDetail,
                       "No earlier messages are available.")
        XCTAssertEqual(TranscriptBackfillPresentation(status: .unknown).controlDetail,
                       "Older messages may be available.")
        XCTAssertEqual(TranscriptBackfillPresentation(status: .failed).controlDetail,
                       "Couldn’t load earlier messages. Try again.")
        XCTAssertEqual(TranscriptBackfillPresentation(status: .limited).controlTitle,
                       "Earlier history limit reached")
        XCTAssertFalse(TranscriptBackfillPresentation(status: .limited).canLoadEarlier)

        XCTAssertEqual(TranscriptPrependAnchorPolicy.anchor(in: [
            TranscriptRowFrame(id: "above", minY: -80, maxY: -4),
            TranscriptRowFrame(id: "reading", minY: -3, maxY: 70),
            TranscriptRowFrame(id: "later", minY: 75, maxY: 110),
        ], fallback: "fallback"), "reading")
        XCTAssertEqual(TranscriptPrependAnchorPolicy.anchor(in: [
            TranscriptRowFrame(id: "above", minY: -80, maxY: -4),
        ], fallback: "fallback"), "fallback")
    }

    @MainActor
    func testFailedOlderReadRetainsCursorForOneExplicitRetry() async throws {
        let oldGateway = LiveRuntime.shared.gatewayID
        let oldGeneration = LiveRuntime.shared.generation
        defer {
            LiveRuntime.shared.gatewayID = oldGateway
            LiveRuntime.shared.generation = oldGeneration
        }
        let gateway = "backfill-retry-\(UUID().uuidString)"
        let exact = StoredTranscriptPageSource(
            gatewayID: gateway, profile: "research", storedSessionID: "root-session")
        let response = try pageData(source: exact, rows: [
            row(1, text: "first"), row(2, text: "second"),
        ], offset: 200, total: 202, hasMore: false)
        let gate = StoredPageGate(plans: [.gatewayError(-7), .data(response)])
        let model = AppModel()
        let gatewayClient = try client(gate: gate)
        let (chat, source, botID) = try await installLiveLedger(
            model: model, client: gatewayClient, gatewayID: gateway)
        defer { TranscriptBackfillRuntime.shared.cancel(source: source) }

        let firstResult = await model.loadEarlierTranscript(botID: botID)
        XCTAssertFalse(firstResult)
        XCTAssertEqual(chat.transcriptBackfill.status, .failed)
        XCTAssertTrue(chat.transcriptBackfill.canLoadEarlier)
        let retryResult = await model.loadEarlierTranscript(botID: botID)
        XCTAssertTrue(retryResult)
        XCTAssertEqual(chat.transcriptBackfill.status, .exhausted)
        XCTAssertEqual(chat.messages.count, 202)
        XCTAssertEqual(chat.messages.prefix(3).map(\.text), ["first", "second", "third"])
        XCTAssertEqual(chat.messages.last?.text, "tail-202")
        let attempts = await gate.attemptCount()
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testOneReadPerSourceAndSessionReplacementDiscardLatePage() async throws {
        let oldGateway = LiveRuntime.shared.gatewayID
        let oldGeneration = LiveRuntime.shared.generation
        defer {
            LiveRuntime.shared.gatewayID = oldGateway
            LiveRuntime.shared.generation = oldGeneration
        }
        let gateway = "backfill-session-race-\(UUID().uuidString)"
        let exact = StoredTranscriptPageSource(
            gatewayID: gateway, profile: "research", storedSessionID: "root-session")
        let response = try pageData(source: exact, rows: [
            row(1, text: "first"), row(2, text: "second"),
        ], offset: 200, total: 202, hasMore: false)
        let gate = StoredPageGate(plans: [])
        await gate.holdNextRead()
        let model = AppModel()
        let gatewayClient = try client(gate: gate)
        let (chat, source, botID) = try await installLiveLedger(
            model: model, client: gatewayClient, gatewayID: gateway)
        defer { TranscriptBackfillRuntime.shared.cancel(source: source) }

        let first = Task { @MainActor in await model.loadEarlierTranscript(botID: botID) }
        await gate.waitForStart()
        let second = Task { @MainActor in await model.loadEarlierTranscript(botID: botID) }
        chat.storedSessionID = "replacement-session"
        await gate.release(.data(response))

        let firstResult = await first.value
        let secondResult = await second.value
        let attempts = await gate.attemptCount()
        XCTAssertFalse(firstResult)
        XCTAssertFalse(secondResult)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(chat.storedSessionID, "replacement-session")
        XCTAssertEqual(chat.messages, [])
        XCTAssertEqual(chat.transcriptBackfill.status, .unavailable)
    }

    @MainActor
    func testGenerationAndChatReplacementDiscardLateCompletion() async throws {
        let oldGateway = LiveRuntime.shared.gatewayID
        let oldGeneration = LiveRuntime.shared.generation
        defer {
            LiveRuntime.shared.gatewayID = oldGateway
            LiveRuntime.shared.generation = oldGeneration
        }
        let gateway = "backfill-generation-race-\(UUID().uuidString)"
        let exact = StoredTranscriptPageSource(
            gatewayID: gateway, profile: "research", storedSessionID: "root-session")
        let response = try pageData(source: exact, rows: [
            row(1, text: "first"), row(2, text: "second"),
        ], offset: 200, total: 202, hasMore: false)
        let gate = StoredPageGate(plans: [])
        await gate.holdNextRead()
        let model = AppModel()
        let gatewayClient = try client(gate: gate)
        let (_, source, botID) = try await installLiveLedger(
            model: model, client: gatewayClient, gatewayID: gateway)
        defer { TranscriptBackfillRuntime.shared.cancel(source: source) }

        let task = Task { @MainActor in await model.loadEarlierTranscript(botID: botID) }
        await gate.waitForStart()
        // Neither a captured generation nor the exact ChatState object may be
        // replaced while an older page is suspended. Both changes make the
        // page stale even though its root/profile strings still look valid.
        LiveRuntime.shared.generation &+= 1
        model.chats[botID] = ChatState(messages: [
            ChatMessage(author: .system, text: "replacement chat"),
        ])
        await gate.release(.data(response))

        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertEqual(model.chats[botID]?.messages.map(\.text), ["replacement chat"])
        XCTAssertNil(model.chats[botID]?.transcriptBackfill.source)
    }
}
#endif
