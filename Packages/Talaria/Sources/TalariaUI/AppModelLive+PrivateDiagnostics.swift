import Foundation
import Observation
import TalariaKit

/// The immutable, user-visible payload captured before Talaria asks for
/// consent. `errorContext` is the same bounded diagnostics projection shown by
/// the failed-turn card; it never contains local logs, files, or a public-paste
/// fallback.
public struct PrivateDiagnosticsShareRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let botID: String
    public let messageID: UUID
    public let errorContext: String

    public init(id: UUID, botID: String, messageID: UUID, errorContext: String) {
        self.id = id
        self.botID = botID
        self.messageID = messageID
        self.errorContext = errorContext
    }
}

/// Failures the consent sheet can distinguish without exposing transport or
/// gateway implementation details as an apparently successful upload.
public enum PrivateDiagnosticsShareFailure: Sendable, Equatable {
    /// The connected Hermes predates `diagnostics.share_nous`.
    case unsupported
    /// The private Nous service explicitly declined the request.
    case rejected(String)
    /// Hermes answered, but did not return a safe, usable receipt.
    case malformedResponse
    /// Connectivity, routing, or another non-service failure.
    case connection(String)
}

/// Observable sheet state. A failed state is retryable only through another
/// explicit Upload tap, which claims a fresh attempt token.
public struct PrivateDiagnosticsShareState: Identifiable, Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case consent
        case uploading
        case success(NousDiagnosticsShareReceipt)
        case failure(PrivateDiagnosticsShareFailure)
    }

    public var id: UUID { request.id }
    public let request: PrivateDiagnosticsShareRequest
    public let phase: Phase

    public init(request: PrivateDiagnosticsShareRequest,
                phase: Phase) {
        self.request = request
        self.phase = phase
    }
}

/// Source-compatible spelling for non-view clients that prefer a standalone
/// policy type; presentation can use `PrivateDiagnosticsShareState.Phase`.
public typealias PrivateDiagnosticsSharePhase = PrivateDiagnosticsShareState.Phase

@MainActor
@Observable
final class PrivateDiagnosticsRuntime {
    typealias UploadOperation = @Sendable (GatewayClient, String?) async throws
        -> NousDiagnosticsShareReceipt
    typealias ClientCurrentOverride = @MainActor (GatewayBotRoute, GatewayClient) -> Bool

    static let shared = PrivateDiagnosticsRuntime()

    var state: PrivateDiagnosticsShareState?
    @ObservationIgnored fileprivate var authority: PrivateDiagnosticsAuthority?
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var presentationGeneration: UInt64 = 0
    @ObservationIgnored var activeClaim: UUID?
    @ObservationIgnored var uploadOperation: UploadOperation =
        PrivateDiagnosticsRuntime.productionUpload
    /// Focused test seam. Production proves primary/pool client ownership from
    /// the real runtimes and never installs this override.
    @ObservationIgnored var clientCurrentOverride: ClientCurrentOverride?

    private static let productionUpload: UploadOperation = { client, context in
        try await client.shareDiagnosticsToNous(errorContext: context)
    }

    func invalidate() {
        presentationGeneration &+= 1
        activeClaim = nil
        state = nil
        authority = nil
        task?.cancel()
        task = nil
    }

    func resetForTesting() {
        invalidate()
        uploadOperation = Self.productionUpload
        clientCurrentOverride = nil
    }
}

@MainActor
fileprivate struct PrivateDiagnosticsAuthority {
    let request: PrivateDiagnosticsShareRequest
    let route: GatewayBotRoute
    let chat: ChatState
    let chatIdentity: ObjectIdentifier
    let failure: TurnFailure
    let storedSessionID: String?
    let runtimeSessionID: String?
    let client: GatewayClient
    let clientIdentity: ObjectIdentifier
    let primaryGeneration: Int?
    let routedEventGeneration: UInt64?
    let profileGeneration: ProfileLifecycleGenerationToken
    let sourceBaseURL: URL?
}

extension AppModel {
    /// Presentation reads this computed property directly. Reading also
    /// retires a sheet whose chat/route/session/client authority changed while
    /// it was visible.
    public var privateDiagnosticsShare: PrivateDiagnosticsShareState? {
        let runtime = PrivateDiagnosticsRuntime.shared
        guard let state = runtime.state, let authority = runtime.authority else {
            return nil
        }
        guard privateDiagnosticsAuthorityIsCurrent(authority) else {
            runtime.invalidate()
            return nil
        }
        return state
    }

    /// Whether the exact card currently has a synchronously retained source
    /// authority. This is a pure presentation policy check: it neither opens
    /// consent nor dials, uploads, reads files, or mutates controller state.
    public func canPreparePrivateDiagnosticsShare(for message: ChatMessage,
                                                  in botID: String) -> Bool {
        privateDiagnosticsPreparationInput(for: message, in: botID) != nil
    }

    /// Prepare an exact failed-turn consent request synchronously. This method
    /// performs no actor hop, network request, client dial, file read, or log
    /// collection. A foreign-source card is eligible only when its already
    /// retained routed client is synchronously authoritative.
    @discardableResult
    public func preparePrivateDiagnosticsShare(for message: ChatMessage,
                                               in botID: String) -> UUID? {
        let id = UUID()
        guard let authority = privateDiagnosticsPreparation(
            for: message, in: botID, id: id) else { return nil }

        let runtime = PrivateDiagnosticsRuntime.shared
        runtime.invalidate()
        runtime.authority = authority
        runtime.state = PrivateDiagnosticsShareState(
            request: authority.request, phase: .consent)
        return id
    }

    /// Claim and perform one private upload. Calls made while an upload owns
    /// the sheet are ignored, so double taps produce one RPC. Calling again
    /// from a failure phase is a new explicit retry with a new claim token.
    public func uploadPrivateDiagnosticsShare(id: UUID) {
        let runtime = PrivateDiagnosticsRuntime.shared
        guard let state = runtime.state, state.id == id,
              let authority = runtime.authority,
              authority.request.id == id,
              privateDiagnosticsAuthorityIsCurrent(authority) else {
            if runtime.state?.id == id { runtime.invalidate() }
            return
        }
        switch state.phase {
        case .consent, .failure:
            break
        case .uploading, .success:
            return
        }

        let claim = UUID()
        let generation = runtime.presentationGeneration
        runtime.activeClaim = claim
        runtime.state = PrivateDiagnosticsShareState(
            request: authority.request, phase: .uploading)
        let upload = runtime.uploadOperation
        runtime.task?.cancel()
        runtime.task = Task { @MainActor [weak self] in
            guard let self else { return }

            // A secondary client lives in an actor-owned pool. Re-prove that
            // exact retained client before the RPC; this lookup never dials.
            if authority.route.gatewayID != LiveRuntime.shared.gatewayID {
                let current = await ConnectionRegistry.shared.clientPool.client(
                    for: authority.route.gatewayID)
                guard self.privateDiagnosticsClaimIsCurrent(
                    id: id, claim: claim, generation: generation, authority: authority),
                      current.map(ObjectIdentifier.init) == authority.clientIdentity else {
                    self.retirePrivateDiagnosticsClaimIfCurrent(
                        id: id, claim: claim, generation: generation)
                    return
                }
            }

            guard self.privateDiagnosticsClaimIsCurrent(
                id: id, claim: claim, generation: generation, authority: authority) else {
                self.retirePrivateDiagnosticsClaimIfCurrent(
                    id: id, claim: claim, generation: generation)
                return
            }

            let result: Result<NousDiagnosticsShareReceipt, Error>
            do {
                result = .success(try await upload(authority.client,
                                                   authority.request.errorContext))
            } catch {
                result = .failure(error)
            }

            // The RPC may already have reached Hermes. Dismissal or authority
            // loss only suppresses this stale completion; it cannot promise
            // cancellation of server-side work.
            guard self.privateDiagnosticsClaimIsCurrent(
                id: id, claim: claim, generation: generation, authority: authority) else {
                self.retirePrivateDiagnosticsClaimIfCurrent(
                    id: id, claim: claim, generation: generation)
                return
            }
            runtime.task = nil
            runtime.activeClaim = nil
            switch result {
            case .success(let receipt):
                runtime.state = PrivateDiagnosticsShareState(
                    request: authority.request, phase: .success(receipt))
            case .failure(let error):
                runtime.state = PrivateDiagnosticsShareState(
                    request: authority.request,
                    phase: .failure(Self.privateDiagnosticsFailure(error)))
            }
        }
    }

    /// Immediately invalidate local presentation ownership. Cancellation is
    /// best-effort for the waiting task only; no UI copy should claim that a
    /// server-side upload was cancelled.
    public func dismissPrivateDiagnosticsShare(id: UUID) {
        let runtime = PrivateDiagnosticsRuntime.shared
        guard runtime.state?.id == id else { return }
        runtime.invalidate()
    }

    private struct PrivateDiagnosticsSource {
        let client: GatewayClient
        let primaryGeneration: Int?
        let routedEventGeneration: UInt64?
        let baseURL: URL?
    }

    private struct PrivateDiagnosticsPreparationInput {
        let botID: String
        let failure: TurnFailure
        let chat: ChatState
        let route: GatewayBotRoute
        let profileGeneration: ProfileLifecycleGenerationToken
        let source: PrivateDiagnosticsSource
    }

    /// Lightweight, allocation-small eligibility check used from SwiftUI body
    /// evaluation. In particular it does not mint a presentation UUID or build
    /// the timestamped diagnostics projection.
    private func privateDiagnosticsPreparationInput(
        for message: ChatMessage, in botID: String
    ) -> PrivateDiagnosticsPreparationInput? {
        guard mode == .live,
              message.author == .bot,
              let failure = message.failure,
              let chat = chats[botID],
              let liveMessage = chat.messages.first(where: { $0.id == message.id }),
              liveMessage.failure == failure,
              let route = stateRoute(for: botID),
              !(route.gatewayID == LiveRuntime.shared.gatewayID && isOffline),
              let profileGeneration = profileLifecycleGenerationToken(for: botID),
              profileGeneration.route == route,
              let source = privateDiagnosticsSource(route: route),
              source.baseURL != nil,
              gatewayBaseURL(for: route) == source.baseURL else { return nil }
        return PrivateDiagnosticsPreparationInput(
            botID: botID, failure: failure, chat: chat,
            route: route, profileGeneration: profileGeneration, source: source)
    }

    private func privateDiagnosticsPreparation(
        for message: ChatMessage, in botID: String, id: UUID
    ) -> PrivateDiagnosticsAuthority? {
        guard let input = privateDiagnosticsPreparationInput(
            for: message, in: botID) else { return nil }

        let request = PrivateDiagnosticsShareRequest(
            id: id,
            botID: botID,
            messageID: message.id,
            errorContext: FailedTurnCardPolicy.diagnostics(for: input.failure)
        )
        let authority = PrivateDiagnosticsAuthority(
            request: request,
            route: input.route,
            chat: input.chat,
            chatIdentity: ObjectIdentifier(input.chat),
            failure: input.failure,
            storedSessionID: input.chat.storedSessionID,
            runtimeSessionID: input.chat.sessionID,
            client: input.source.client,
            clientIdentity: ObjectIdentifier(input.source.client),
            primaryGeneration: input.source.primaryGeneration,
            routedEventGeneration: input.source.routedEventGeneration,
            profileGeneration: input.profileGeneration,
            sourceBaseURL: input.source.baseURL
        )
        return privateDiagnosticsAuthorityIsCurrent(authority) ? authority : nil
    }

    private func privateDiagnosticsSource(route: GatewayBotRoute)
        -> PrivateDiagnosticsSource? {
        let runtime = PrivateDiagnosticsRuntime.shared
        if let override = runtime.clientCurrentOverride,
           let candidate = client,
           override(route, candidate) {
            return PrivateDiagnosticsSource(
                client: candidate,
                primaryGeneration: LiveRuntime.shared.generation,
                routedEventGeneration: nil,
                baseURL: LiveRuntime.shared.baseURL)
        }

        if route.gatewayID == LiveRuntime.shared.gatewayID,
           let client,
           activeGatewayID == route.gatewayID {
            return PrivateDiagnosticsSource(
                client: client,
                primaryGeneration: LiveRuntime.shared.generation,
                routedEventGeneration: nil,
                baseURL: LiveRuntime.shared.baseURL)
        }

        guard let routed = MultiGatewayRuntime.shared.routedEvents[route.gatewayID] else {
            return nil
        }
        return PrivateDiagnosticsSource(
            client: routed.client,
            primaryGeneration: nil,
            routedEventGeneration: routed.generation,
            baseURL: gatewayBaseURL(for: route))
    }

    private func privateDiagnosticsAuthorityIsCurrent(
        _ authority: PrivateDiagnosticsAuthority
    ) -> Bool {
        let runtime = PrivateDiagnosticsRuntime.shared
        if let override = runtime.clientCurrentOverride,
           !override(authority.route, authority.client) { return false }
        guard mode == .live,
              stateRoute(for: authority.request.botID) == authority.route,
              let chat = chats[authority.request.botID],
              chat === authority.chat,
              ObjectIdentifier(chat) == authority.chatIdentity,
              chat.storedSessionID == authority.storedSessionID,
              chat.sessionID == authority.runtimeSessionID,
              let message = chat.messages.first(where: {
                  $0.id == authority.request.messageID
              }),
              message.failure == authority.failure,
              profileLifecycleAccepts(authority.profileGeneration),
              authority.sourceBaseURL != nil,
              gatewayBaseURL(for: authority.route) == authority.sourceBaseURL else { return false }

        if let primaryGeneration = authority.primaryGeneration {
            return authority.route.gatewayID == LiveRuntime.shared.gatewayID
                && !isOffline
                && LiveRuntime.shared.generation == primaryGeneration
                && client.map(ObjectIdentifier.init) == authority.clientIdentity
        }
        guard let routedGeneration = authority.routedEventGeneration,
              let routed = MultiGatewayRuntime.shared.routedEvents[authority.route.gatewayID]
        else { return false }
        return routed.generation == routedGeneration
            && ObjectIdentifier(routed.client) == authority.clientIdentity
    }

    private func privateDiagnosticsClaimIsCurrent(
        id: UUID, claim: UUID, generation: UInt64,
        authority: PrivateDiagnosticsAuthority
    ) -> Bool {
        let runtime = PrivateDiagnosticsRuntime.shared
        return runtime.presentationGeneration == generation
            && runtime.activeClaim == claim
            && runtime.state?.id == id
            && runtime.authority?.request.id == id
            && privateDiagnosticsAuthorityIsCurrent(authority)
    }

    private func retirePrivateDiagnosticsClaimIfCurrent(
        id: UUID, claim: UUID, generation: UInt64
    ) {
        let runtime = PrivateDiagnosticsRuntime.shared
        guard runtime.presentationGeneration == generation,
              runtime.activeClaim == claim,
              runtime.state?.id == id else { return }
        runtime.invalidate()
    }

    private static func privateDiagnosticsFailure(_ error: Error)
        -> PrivateDiagnosticsShareFailure {
        if let gateway = error as? GatewayError, gateway.code == -32601 {
            return .unsupported
        }
        if let sharing = error as? NousDiagnosticsShareError {
            switch sharing {
            case .rejected(let message): return .rejected(message)
            case .malformedReceipt: return .malformedResponse
            }
        }
        let raw: String
        if let gateway = error as? GatewayError {
            raw = gateway.message
        } else if let localized = error as? LocalizedError,
                  let description = localized.errorDescription {
            raw = description
        } else {
            raw = (error as NSError).localizedDescription
        }
        let admitted = privateDiagnosticsConnectionMessage(raw)
        return .connection(admitted.isEmpty ? "Diagnostics upload failed." : admitted)
    }

    /// Transport prose is not trusted presentation. Inspect a bounded raw
    /// prefix, strip terminal/C0 and bidi controls, then cap the visible result
    /// so a gateway error cannot spoof or overwhelm the consent sheet.
    private static func privateDiagnosticsConnectionMessage(_ source: String) -> String {
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(512)
        for scalar in source.unicodeScalars.prefix(2_048) {
            if output.count == 512 { break }
            let value = scalar.value
            if value == 0x09 || value == 0x0A {
                output.append(scalar)
            } else if value >= 0x20, !(0x7F...0x9F).contains(value),
                      !privateDiagnosticsBidiControls.contains(value) {
                output.append(scalar)
            }
        }
        return String(String.UnicodeScalarView(output))
    }

    private static let privateDiagnosticsBidiControls: Set<UInt32> = [
        0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069,
    ]
}
