import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class PrivateDiagnosticsControllerTests: XCTestCase {
    private actor SuspendedUpload {
        private var calls = 0
        private var continuation: CheckedContinuation<Void, Never>?

        func run() async -> NousDiagnosticsShareReceipt {
            calls += 1
            await withCheckedContinuation { continuation = $0 }
            return NousDiagnosticsShareReceipt(
                viewURL: URL(string: "https://portal.nousresearch.com/diagnostics/ok"),
                uploadID: "diag_ok", expiresAt: nil)
        }

        func callCount() -> Int { calls }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private actor ScriptedUpload {
        enum Outcome: Sendable {
            case success
            case unsupported
            case rejected
            case malformed
            case connection
        }

        private var outcomes: [Outcome]
        private var calls = 0

        init(_ outcomes: [Outcome]) { self.outcomes = outcomes }

        func run() throws -> NousDiagnosticsShareReceipt {
            calls += 1
            let outcome = outcomes.isEmpty ? .connection : outcomes.removeFirst()
            switch outcome {
            case .success:
                return NousDiagnosticsShareReceipt(
                    viewURL: URL(string: "https://portal.nousresearch.com/diagnostics/success"),
                    uploadID: "diag_success", expiresAt: "later")
            case .unsupported:
                throw GatewayError(code: -32601, message: "Method not found")
            case .rejected:
                throw NousDiagnosticsShareError.rejected(message: "Private service refused upload")
            case .malformed:
                throw NousDiagnosticsShareError.malformedReceipt(reason: "missing safe reference")
            case .connection:
                throw GatewayError(code: -7, message: "connection lost")
            }
        }

        func callCount() -> Int { calls }
    }

    @MainActor
    private struct Fixture {
        let model: AppModel
        let botID: String
        let route: GatewayBotRoute
        let chat: ChatState
        let message: ChatMessage
        let client: GatewayClient
    }

    @MainActor
    private func fixture() -> Fixture {
        let model = AppModel()
        model.mode = .live
        let botID = "worker"
        let gatewayID = "gateway-diagnostics-tests"
        let route = GatewayBotRoute(gatewayID: gatewayID, profile: botID)
        let baseURL = URL(string: "https://diagnostics-tests.example")!
        let client = GatewayClient(baseURL: baseURL, credential: .sessionToken("test"))
        let failure = TurnFailure(
            message: "provider failed\nprovider: untrusted continuation",
            recoverable: true,
            errorSurface: TurnErrorSurface(
                layer: .provider, code: "provider_error", retryable: true,
                provider: "captured-provider", model: "captured-model"))
        let message = ChatMessage(
            author: .bot, text: "partial response", rowID: 42, failure: failure)
        let chat = ChatState(messages: [
            ChatMessage(author: .user, text: "hello", rowID: 41), message,
        ])
        chat.storedSessionID = "stored-session"
        chat.sessionID = "runtime-session"
        model.chats[botID] = chat
        model.client = client
        LiveRuntime.shared.gatewayID = gatewayID
        LiveRuntime.shared.baseURL = baseURL
        LiveRuntime.shared.generation = 17
        model.clearProfileLifecycleRouteForTesting(route)
        PrivateDiagnosticsRuntime.shared.resetForTesting()
        PrivateDiagnosticsRuntime.shared.clientCurrentOverride = { expected, candidate in
            expected == route && ObjectIdentifier(candidate) == ObjectIdentifier(client)
        }
        return Fixture(model: model, botID: botID, route: route, chat: chat,
                       message: message, client: client)
    }

    @MainActor
    private func tearDownFixture(_ fixture: Fixture) {
        PrivateDiagnosticsRuntime.shared.resetForTesting()
        fixture.model.clearProfileLifecycleRouteForTesting(fixture.route)
        fixture.model.client = nil
        LiveRuntime.shared.gatewayID = nil
        LiveRuntime.shared.baseURL = nil
        LiveRuntime.shared.generation = 0
    }

    private func eventually(_ predicate: @escaping @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await predicate() { return true }
            await Task.yield()
        }
        return await predicate()
    }

    @MainActor
    func testPreparationIsSynchronousBoundedAndMakesZeroNetworkRequests() async throws {
        let fixture = fixture()
        defer { tearDownFixture(fixture) }
        let uploader = ScriptedUpload([.success])
        PrivateDiagnosticsRuntime.shared.uploadOperation = { _, _ in try await uploader.run() }

        let id = try XCTUnwrap(fixture.model.preparePrivateDiagnosticsShare(
            for: fixture.message, in: fixture.botID))

        let callsBeforeConsent = await uploader.callCount()
        XCTAssertEqual(callsBeforeConsent, 0)
        let state = try XCTUnwrap(fixture.model.privateDiagnosticsShare)
        XCTAssertEqual(state.id, id)
        XCTAssertEqual(state.phase, .consent)
        XCTAssertEqual(state.request.botID, fixture.botID)
        XCTAssertEqual(state.request.messageID, fixture.message.id)
        XCTAssertTrue(state.request.errorContext.contains("Hermes error details"))
        XCTAssertTrue(state.request.errorContext.contains("captured-provider"))
        XCTAssertTrue(state.request.errorContext.contains("captured-model"))
        XCTAssertLessThanOrEqual(
            state.request.errorContext.unicodeScalars.count,
            FailedTurnCardPolicy.maximumDisplayedErrorScalars + 1_024)
    }

    @MainActor
    func testAvailabilityPolicyIsPureAndUnavailablePreparationIsANoop() async throws {
        let fixture = fixture()
        defer { tearDownFixture(fixture) }
        let uploader = ScriptedUpload([.success])
        PrivateDiagnosticsRuntime.shared.uploadOperation = { _, _ in try await uploader.run() }

        XCTAssertTrue(fixture.model.canPreparePrivateDiagnosticsShare(
            for: fixture.message, in: fixture.botID))
        XCTAssertNil(fixture.model.privateDiagnosticsShare)
        let callsAfterPolicy = await uploader.callCount()
        XCTAssertEqual(callsAfterPolicy, 0)

        fixture.model.isOffline = true
        XCTAssertFalse(fixture.model.canPreparePrivateDiagnosticsShare(
            for: fixture.message, in: fixture.botID))
        XCTAssertNil(fixture.model.preparePrivateDiagnosticsShare(
            for: fixture.message, in: fixture.botID))
        XCTAssertNil(fixture.model.privateDiagnosticsShare)
        let callsAfterUnavailablePrepare = await uploader.callCount()
        XCTAssertEqual(callsAfterUnavailablePrepare, 0)

        fixture.model.isOffline = false
        fixture.model.mode = .demo
        XCTAssertFalse(fixture.model.canPreparePrivateDiagnosticsShare(
            for: fixture.message, in: fixture.botID))
    }

    @MainActor
    func testDoubleConfirmClaimsExactlyOneUpload() async throws {
        let fixture = fixture()
        defer { tearDownFixture(fixture) }
        let uploader = SuspendedUpload()
        PrivateDiagnosticsRuntime.shared.uploadOperation = { _, _ in await uploader.run() }
        let id = try XCTUnwrap(fixture.model.preparePrivateDiagnosticsShare(
            for: fixture.message, in: fixture.botID))

        fixture.model.uploadPrivateDiagnosticsShare(id: id)
        fixture.model.uploadPrivateDiagnosticsShare(id: id)
        let claimedOnce = await eventually { await uploader.callCount() == 1 }
        XCTAssertTrue(claimedOnce)
        XCTAssertEqual(fixture.model.privateDiagnosticsShare?.phase, .uploading)

        await uploader.release()
        let succeeded = await eventually {
            guard case .success = fixture.model.privateDiagnosticsShare?.phase else { return false }
            return true
        }
        XCTAssertTrue(succeeded)
        let finalCalls = await uploader.callCount()
        XCTAssertEqual(finalCalls, 1)
    }

    @MainActor
    func testDismissalInvalidatesImmediatelyAndLateCompletionCannotRepublish() async throws {
        let fixture = fixture()
        defer { tearDownFixture(fixture) }
        let uploader = SuspendedUpload()
        PrivateDiagnosticsRuntime.shared.uploadOperation = { _, _ in await uploader.run() }
        let id = try XCTUnwrap(fixture.model.preparePrivateDiagnosticsShare(
            for: fixture.message, in: fixture.botID))
        fixture.model.uploadPrivateDiagnosticsShare(id: id)
        let started = await eventually { await uploader.callCount() == 1 }
        XCTAssertTrue(started)

        fixture.model.dismissPrivateDiagnosticsShare(id: id)
        XCTAssertNil(fixture.model.privateDiagnosticsShare)
        await uploader.release()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(fixture.model.privateDiagnosticsShare)
    }

    @MainActor
    func testSessionRouteProfileClientAndGenerationChangesRetireWithoutRPC() async throws {
        enum Mutation: CaseIterable {
            case offline, session, storedSession, message, route, profile, client, generation
        }

        for mutation in Mutation.allCases {
            let fixture = fixture()
            let uploader = ScriptedUpload([.success])
            PrivateDiagnosticsRuntime.shared.uploadOperation = { _, _ in try await uploader.run() }
            let id = try XCTUnwrap(fixture.model.preparePrivateDiagnosticsShare(
                for: fixture.message, in: fixture.botID))

            switch mutation {
            case .offline:
                fixture.model.isOffline = true
            case .session:
                fixture.chat.sessionID = "replacement-session"
            case .storedSession:
                fixture.chat.storedSessionID = "replacement-stored-session"
            case .message:
                fixture.chat.messages.removeAll { $0.id == fixture.message.id }
            case .route:
                LiveRuntime.shared.gatewayID = "another-gateway"
            case .profile:
                fixture.model.invalidateProfileLifecycleRouteForTesting(fixture.route)
            case .client:
                fixture.model.client = GatewayClient(
                    baseURL: URL(string: "https://replacement.example")!,
                    credential: .sessionToken("replacement"))
            case .generation:
                LiveRuntime.shared.generation += 1
            }

            fixture.model.uploadPrivateDiagnosticsShare(id: id)
            XCTAssertNil(fixture.model.privateDiagnosticsShare, "mutation: \(mutation)")
            let calls = await uploader.callCount()
            XCTAssertEqual(calls, 0, "mutation: \(mutation)")
            tearDownFixture(fixture)
        }
    }

    @MainActor
    func testClientOrGenerationReplacementDuringUploadSuppressesCompletion() async throws {
        for replaceClient in [false, true] {
            let fixture = fixture()
            let uploader = SuspendedUpload()
            PrivateDiagnosticsRuntime.shared.uploadOperation = { _, _ in await uploader.run() }
            let id = try XCTUnwrap(fixture.model.preparePrivateDiagnosticsShare(
                for: fixture.message, in: fixture.botID))
            fixture.model.uploadPrivateDiagnosticsShare(id: id)
            let started = await eventually { await uploader.callCount() == 1 }
            XCTAssertTrue(started)

            if replaceClient {
                fixture.model.client = GatewayClient(
                    baseURL: URL(string: "https://replacement.example")!,
                    credential: .sessionToken("replacement"))
            } else {
                LiveRuntime.shared.generation += 1
            }
            await uploader.release()
            let retired = await eventually { fixture.model.privateDiagnosticsShare == nil }
            XCTAssertTrue(retired)
            tearDownFixture(fixture)
        }
    }

    @MainActor
    func testSuccessTypedErrorsAndExplicitRetryMapping() async throws {
        let expected: [(ScriptedUpload.Outcome, PrivateDiagnosticsShareFailure?)] = [
            (.success, nil),
            (.unsupported, .unsupported),
            (.rejected, .rejected("Private service refused upload")),
            (.malformed, .malformedResponse),
            (.connection, .connection("connection lost")),
        ]

        for (outcome, expectedFailure) in expected {
            let fixture = fixture()
            let uploader = ScriptedUpload([outcome])
            PrivateDiagnosticsRuntime.shared.uploadOperation = { _, _ in try await uploader.run() }
            let id = try XCTUnwrap(fixture.model.preparePrivateDiagnosticsShare(
                for: fixture.message, in: fixture.botID))
            fixture.model.uploadPrivateDiagnosticsShare(id: id)

            let mapped = await eventually {
                guard let phase = fixture.model.privateDiagnosticsShare?.phase else { return false }
                switch phase {
                case .success: return expectedFailure == nil
                case .failure(let actual): return actual == expectedFailure
                default: return false
                }
            }
            XCTAssertTrue(mapped, "outcome: \(outcome)")
            let calls = await uploader.callCount()
            XCTAssertEqual(calls, 1)
            tearDownFixture(fixture)
        }

        let fixture = fixture()
        defer { tearDownFixture(fixture) }
        let retry = ScriptedUpload([.connection, .success])
        PrivateDiagnosticsRuntime.shared.uploadOperation = { _, _ in try await retry.run() }
        let id = try XCTUnwrap(fixture.model.preparePrivateDiagnosticsShare(
            for: fixture.message, in: fixture.botID))
        fixture.model.uploadPrivateDiagnosticsShare(id: id)
        let firstFailed = await eventually {
            guard case .failure(.connection) = fixture.model.privateDiagnosticsShare?.phase
            else { return false }
            return true
        }
        XCTAssertTrue(firstFailed)
        let firstCalls = await retry.callCount()
        XCTAssertEqual(firstCalls, 1)

        fixture.model.uploadPrivateDiagnosticsShare(id: id)
        let retrySucceeded = await eventually {
            guard case .success = fixture.model.privateDiagnosticsShare?.phase else { return false }
            return true
        }
        XCTAssertTrue(retrySucceeded)
        let retryCalls = await retry.callCount()
        XCTAssertEqual(retryCalls, 2)
    }

    @MainActor
    func testHostileConnectionErrorTextIsBoundedAndControlSanitized() async throws {
        let fixture = fixture()
        defer { tearDownFixture(fixture) }
        PrivateDiagnosticsRuntime.shared.uploadOperation = { _, _ in
            throw GatewayError(
                code: -7,
                message: "boom\u{1B}\u{202E}\nprovider: spoof" + String(repeating: "x", count: 2_000))
        }
        let id = try XCTUnwrap(fixture.model.preparePrivateDiagnosticsShare(
            for: fixture.message, in: fixture.botID))
        fixture.model.uploadPrivateDiagnosticsShare(id: id)

        let sanitized = await eventually {
            guard case .failure(.connection(let message)) =
                    fixture.model.privateDiagnosticsShare?.phase else { return false }
            return message.hasPrefix("boom\nprovider: spoof")
                && message.unicodeScalars.count <= 512
                && !message.unicodeScalars.contains(where: {
                    $0.value == 0x1B || $0.value == 0x202E
                })
        }
        XCTAssertTrue(sanitized)
    }

    @MainActor
    func testUploadNeverMutatesDraftTranscriptAttachmentsOrQueues() async throws {
        let fixture = fixture()
        defer { tearDownFixture(fixture) }
        fixture.model.composeQueue = [(botID: fixture.botID, text: "offline draft")]
        fixture.model.promptQueue = [(id: UUID(), botID: fixture.botID, text: "queued prompt")]
        let messages = fixture.chat.messages
        let attachments = fixture.chat.attachments
        let composeQueue = fixture.model.composeQueue
        let promptQueue = fixture.model.promptQueue
        let uploader = ScriptedUpload([.success])
        PrivateDiagnosticsRuntime.shared.uploadOperation = { _, _ in try await uploader.run() }

        let id = try XCTUnwrap(fixture.model.preparePrivateDiagnosticsShare(
            for: fixture.message, in: fixture.botID))
        fixture.model.uploadPrivateDiagnosticsShare(id: id)
        let succeeded = await eventually {
            guard case .success = fixture.model.privateDiagnosticsShare?.phase else { return false }
            return true
        }
        XCTAssertTrue(succeeded)

        XCTAssertEqual(fixture.chat.messages, messages)
        XCTAssertEqual(fixture.chat.attachments, attachments)
        XCTAssertEqual(fixture.model.composeQueue.map { "\($0.botID)|\($0.text)" },
                       composeQueue.map { "\($0.botID)|\($0.text)" })
        XCTAssertEqual(fixture.model.promptQueue.map { "\($0.id)|\($0.botID)|\($0.text)" },
                       promptQueue.map { "\($0.id)|\($0.botID)|\($0.text)" })
    }
}
