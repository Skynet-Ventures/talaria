import Foundation
import Observation
import TalariaKit
#if canImport(UIKit)
import UIKit
#endif

public enum ReadAloudPlaybackStatus: Sendable, Equatable {
    case preparing
    case speaking
}

enum ReadAloudPresentation {
    static let minimumControlHeight: CGFloat = 44

    static func controlLabel(_ status: ReadAloudPlaybackStatus) -> String {
        switch status {
        case .preparing: return "Preparing audio — Stop"
        case .speaking: return "Stop reading aloud"
        }
    }

    static func accessibilityHint(_ status: ReadAloudPlaybackStatus) -> String {
        switch status {
        case .preparing: return "Cancels audio preparation for this message."
        case .speaking: return "Stops this message immediately."
        }
    }
}

/// Pure generation fence used by the observable runtime. Cancellation alone
/// is not an authority proof: a provider may finish after ignoring it.
struct ReadAloudLeaseFence: Equatable, Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var leaseID: UUID?

    mutating func begin(_ id: UUID) -> UInt64 {
        generation &+= 1
        leaseID = id
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
        leaseID = nil
    }

    func accepts(id: UUID, generation candidate: UInt64) -> Bool {
        leaseID == id && generation == candidate
    }
}

/// Synchronous half of playback admission, separated so every collision and
/// transcript mutation can be exhaustively tested without an audio device.
struct ReadAloudMessageAuthority: Equatable, Sendable {
    let botID: String
    let chatID: UUID
    let messageID: UUID
    let preparedText: String
    let visibleTextFingerprint: String
    let route: GatewayBotRoute

    init(botID: String, chatID: UUID, messageID: UUID,
         preparedText: String, route: GatewayBotRoute) {
        self.botID = botID
        self.chatID = chatID
        self.messageID = messageID
        self.preparedText = preparedText
        self.visibleTextFingerprint = ReadAloudPolicy.fingerprint(preparedText)
        self.route = route
    }

    func accepts(botID candidateBot: String, chatID candidateChat: UUID,
                 message: ChatMessage, route candidateRoute: GatewayBotRoute) -> Bool {
        guard candidateBot == botID, candidateChat == chatID,
              message.id == messageID, candidateRoute == route,
              let current = ReadAloudPolicy.preparedText(for: message) else { return false }
        return current == preparedText
            && ReadAloudPolicy.fingerprint(current) == visibleTextFingerprint
    }
}

struct ReadAloudSourceAuthority: Equatable, Sendable {
    enum ConnectionGeneration: Equatable, Sendable {
        case primary(Int)
        case pooled(UInt64)
    }

    let route: GatewayBotRoute
    let clientIdentity: ObjectIdentifier
    let connectionGeneration: ConnectionGeneration
    let profileLifecycleGeneration: UInt64

    func accepts(route candidateRoute: GatewayBotRoute,
                 clientIdentity candidateClient: ObjectIdentifier,
                 connectionGeneration candidateConnection: ConnectionGeneration,
                 profileLifecycleGeneration candidateLifecycle: UInt64) -> Bool {
        route == candidateRoute
            && clientIdentity == candidateClient
            && connectionGeneration == candidateConnection
            && profileLifecycleGeneration == candidateLifecycle
    }
}

@MainActor
@Observable
final class MobileAudioOwnership {
    static let shared = MobileAudioOwnership()

    enum Kind: Sendable, Equatable { case readAloud, voiceSession }
    struct Lease: Sendable, Equatable {
        let id: UUID
        let kind: Kind
    }

    private(set) var owner: Lease?

    func acquire(_ kind: Kind, id: UUID = UUID()) -> Lease? {
        guard owner == nil else { return nil }
        let lease = Lease(id: id, kind: kind)
        owner = lease
        return lease
    }

    @discardableResult
    func release(_ lease: Lease) -> Bool {
        guard owner == lease else { return false }
        owner = nil
        return true
    }

    func owns(_ lease: Lease) -> Bool { owner == lease }
}

@MainActor
struct ReadAloudPlaybackLease {
    enum ConnectionAuthority {
        case primary(generation: Int)
        case pooled(GatewayClientPool.ConnectionSnapshot)
    }

    let id: UUID
    let generation: UInt64
    let message: ReadAloudMessageAuthority
    let client: GatewayClient
    let connection: ConnectionAuthority
    let profileLifecycle: ProfileLifecycleGenerationToken
    let source: ReadAloudSourceAuthority
    let audio: MobileAudioOwnership.Lease
}

/// One process-wide playback lease. Every provider suspension is followed by
/// exact source, chat, message, text, client and lifecycle revalidation before
/// sound can start.
@MainActor
@Observable
public final class ReadAloudRuntime {
    public static let shared = ReadAloudRuntime()

    public private(set) var status: ReadAloudPlaybackStatus?
    public private(set) var activeBotID: String?
    public private(set) var activeMessageID: UUID?
    public private(set) var lastFailure: String?

    @ObservationIgnored private var fence = ReadAloudLeaseFence()
    @ObservationIgnored private var lease: ReadAloudPlaybackLease?
    @ObservationIgnored private var pendingRoute: GatewayBotRoute?
    @ObservationIgnored private var pendingBotID: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let player = VoicePlayer()

    private init() {}

    public func isActive(messageID: UUID, botID: String) -> Bool {
        activeMessageID == messageID && activeBotID == botID && status != nil
    }

    func request(model: AppModel, message: ChatMessage, botID: String) {
        stop(announcement: nil)
        lastFailure = nil
        guard let route = model.profileRoute(for: botID) else {
            lastFailure = "This message couldn’t be read aloud."
            announce("This message couldn’t be read aloud.")
            return
        }
        pendingRoute = route
        pendingBotID = botID
        let requestID = UUID()
        let generation = fence.begin(requestID)
        task = Task { @MainActor [weak self, weak model] in
            guard let self, let model else { return }
            await self.prepareAndPlay(
                model: model, message: message, botID: botID,
                requestID: requestID, generation: generation)
        }
    }

    public func stop() { stop(announcement: "Stopped reading aloud.") }

    func stopIfOwned(botID: String) {
        guard activeBotID == botID || pendingBotID == botID else { return }
        stop(announcement: nil)
    }

    func sourceDidInvalidate(gatewayID: String, profile: String? = nil) {
        let route = lease?.message.route ?? pendingRoute
        guard let route, route.gatewayID == gatewayID,
              profile == nil || route.profile == profile else { return }
        stop(announcement: nil)
    }

    func visibleTranscriptDidChange(model: AppModel, botID: String) {
        guard let lease, lease.message.botID == botID else { return }
        Task { @MainActor [weak self, weak model] in
            guard let self, let model else { return }
            _ = await self.accepts(lease, in: model)
        }
    }

    /// Voice Mode has stronger foreground audio ownership. It stops a current
    /// one-shot read before claiming the microphone/speaker pair, and refuses
    /// honestly if another voice overlay already owns them.
    func acquireVoiceAudio() -> MobileAudioOwnership.Lease? {
        stop(announcement: nil)
        return MobileAudioOwnership.shared.acquire(.voiceSession)
    }

    func releaseVoiceAudio(_ lease: MobileAudioOwnership.Lease) {
        MobileAudioOwnership.shared.release(lease)
    }

    private func prepareAndPlay(
        model: AppModel, message: ChatMessage, botID: String,
        requestID: UUID, generation: UInt64
    ) async {
        guard fence.accepts(id: requestID, generation: generation),
              model.mode == .live,
              let prepared = ReadAloudPolicy.preparedText(for: message),
              let route = model.profileRoute(for: botID),
              let lifecycle = model.profileLifecycleGenerationToken(for: botID),
              lifecycle.route == route else {
            failIfCurrent(requestID, generation: generation)
            return
        }
        let chat = model.chat(for: botID)
        guard model.openBotID == botID,
              chat.displayedMessages().contains(where: { $0.id == message.id }) else {
            failIfCurrent(requestID, generation: generation)
            return
        }

        enum InitialConnection {
            case primary(client: GatewayClient, generation: Int)
            case pooled(GatewayClientPool.ConnectionSnapshot?)
        }
        let initialConnection: InitialConnection
        if route.gatewayID == LiveRuntime.shared.gatewayID {
            guard let initialClient = model.client else {
                failIfCurrent(requestID, generation: generation)
                return
            }
            initialConnection = .primary(
                client: initialClient, generation: LiveRuntime.shared.generation)
        } else {
            let existing = await ConnectionRegistry.shared.clientPool
                .retainedConnectionSnapshots().first(where: {
                    $0.gatewayID == route.gatewayID
                })?.connection
            guard fence.accepts(id: requestID, generation: generation),
                  model.profileRoute(for: botID) == route,
                  model.profileLifecycleAccepts(lifecycle) else { return }
            initialConnection = .pooled(existing)
        }

        let context: (route: GatewayBotRoute, client: GatewayClient)
        do {
            context = try await model.profileContext(for: botID)
        } catch {
            failIfCurrent(requestID, generation: generation)
            return
        }
        guard fence.accepts(id: requestID, generation: generation),
              context.route == route,
              model.profileLifecycleAccepts(lifecycle),
              model.openBotID == botID,
              chat.chatIdentity == model.chat(for: botID).chatIdentity,
              chat.displayedMessages().contains(where: { current in
                  current.id == message.id
                      && ReadAloudPolicy.preparedText(for: current) == prepared
              }) else {
            failIfCurrent(requestID, generation: generation)
            return
        }

        let connection: ReadAloudPlaybackLease.ConnectionAuthority
        let source: ReadAloudSourceAuthority
        switch initialConnection {
        case .primary(let initialClient, let initialGeneration):
            guard route.gatewayID == LiveRuntime.shared.gatewayID,
                  LiveRuntime.shared.generation == initialGeneration,
                  model.client.map(ObjectIdentifier.init) == ObjectIdentifier(initialClient),
                  ObjectIdentifier(context.client) == ObjectIdentifier(initialClient) else {
                failIfCurrent(requestID, generation: generation)
                return
            }
            connection = .primary(generation: initialGeneration)
            source = ReadAloudSourceAuthority(
                route: route, clientIdentity: ObjectIdentifier(context.client),
                connectionGeneration: .primary(initialGeneration),
                profileLifecycleGeneration: lifecycle.generation)
        case .pooled(let existing):
            let snapshots = await ConnectionRegistry.shared.clientPool.retainedConnectionSnapshots()
            guard fence.accepts(id: requestID, generation: generation),
                  let snapshot = snapshots.first(where: {
                      $0.gatewayID == route.gatewayID
                          && ObjectIdentifier($0.connection.client)
                              == ObjectIdentifier(context.client)
                  })?.connection,
                  existing.map({
                      $0.generation == snapshot.generation
                          && ObjectIdentifier($0.client) == ObjectIdentifier(snapshot.client)
                  }) ?? true else {
                failIfCurrent(requestID, generation: generation)
                return
            }
            connection = .pooled(snapshot)
            source = ReadAloudSourceAuthority(
                route: route, clientIdentity: ObjectIdentifier(context.client),
                connectionGeneration: .pooled(snapshot.generation),
                profileLifecycleGeneration: lifecycle.generation)
        }

        guard fence.accepts(id: requestID, generation: generation),
              let audio = MobileAudioOwnership.shared.acquire(
                .readAloud, id: requestID) else {
            failIfCurrent(requestID, generation: generation)
            return
        }
        let lease = ReadAloudPlaybackLease(
            id: requestID, generation: generation,
            message: ReadAloudMessageAuthority(
                botID: botID, chatID: chat.chatIdentity,
                messageID: message.id, preparedText: prepared, route: route),
            client: context.client,
            connection: connection, profileLifecycle: lifecycle,
            source: source, audio: audio)
        self.lease = lease
        pendingRoute = nil
        pendingBotID = nil
        activeBotID = botID
        activeMessageID = message.id
        status = .preparing
        announce("Preparing audio.")

        let audioResult: SpokenAudio
        do {
            audioResult = try await context.client.synthesizeSpeech(
                text: prepared, profile: route.profile)
        } catch {
            failIfCurrent(requestID, generation: generation)
            return
        }

        // Re-prove once after synthesis and again at the final sound boundary.
        guard await accepts(lease, in: model) else { return }
        status = .speaking
        announce("Reading aloud.")
        guard await accepts(lease, in: model) else { return }
        let played = await player.play(audioResult.data)
        guard fence.accepts(id: requestID, generation: generation) else { return }
        if played {
            finish(lease)
        } else {
            failIfCurrent(requestID, generation: generation)
        }
    }

    private func accepts(_ candidate: ReadAloudPlaybackLease,
                         in model: AppModel) async -> Bool {
        guard lease?.id == candidate.id,
              fence.accepts(id: candidate.id, generation: candidate.generation),
              MobileAudioOwnership.shared.owns(candidate.audio),
              model.mode == .live, model.openBotID == candidate.message.botID,
              model.profileRoute(for: candidate.message.botID) == candidate.message.route,
              model.profileLifecycleAccepts(candidate.profileLifecycle) else {
            invalidate(candidate)
            return false
        }
        let chat = model.chat(for: candidate.message.botID)
        guard chat.chatIdentity == candidate.message.chatID,
              let current = chat.displayedMessages().first(where: {
                  $0.id == candidate.message.messageID
              }),
              candidate.message.accepts(
                botID: candidate.message.botID, chatID: chat.chatIdentity,
                message: current, route: candidate.message.route) else {
            invalidate(candidate)
            return false
        }
        switch candidate.connection {
        case .primary(let generation):
            guard let currentClient = model.client,
                  candidate.source.accepts(
                    route: candidate.message.route,
                    clientIdentity: ObjectIdentifier(currentClient),
                    connectionGeneration: .primary(LiveRuntime.shared.generation),
                    profileLifecycleGeneration: candidate.profileLifecycle.generation),
                  LiveRuntime.shared.gatewayID == candidate.message.route.gatewayID,
                  LiveRuntime.shared.generation == generation else {
                invalidate(candidate)
                return false
            }
        case .pooled(let snapshot):
            guard await ConnectionRegistry.shared.clientPool.isCurrent(
                snapshot, for: candidate.message.route.gatewayID) else {
                invalidate(candidate)
                return false
            }
            // The actor hop itself is a race boundary. Re-prove the synchronous
            // message/lifecycle generation before allowing the caller onward.
            guard lease?.id == candidate.id,
                  fence.accepts(id: candidate.id, generation: candidate.generation),
                  model.profileLifecycleAccepts(candidate.profileLifecycle) else {
                invalidate(candidate)
                return false
            }
            guard candidate.source.accepts(
                route: candidate.message.route,
                clientIdentity: ObjectIdentifier(snapshot.client),
                connectionGeneration: .pooled(snapshot.generation),
                profileLifecycleGeneration: candidate.profileLifecycle.generation) else {
                invalidate(candidate)
                return false
            }
        }
        return true
    }

    private func finish(_ candidate: ReadAloudPlaybackLease) {
        guard lease?.id == candidate.id else { return }
        if MobileAudioOwnership.shared.release(candidate.audio) {
            VoiceAudioSession.deactivate()
        }
        lease = nil
        pendingRoute = nil
        pendingBotID = nil
        task = nil
        status = nil
        activeBotID = nil
        activeMessageID = nil
        fence.invalidate()
    }

    private func invalidate(_ candidate: ReadAloudPlaybackLease) {
        guard lease?.id == candidate.id else { return }
        stop(announcement: nil)
    }

    private func failIfCurrent(_ id: UUID, generation: UInt64) {
        guard fence.accepts(id: id, generation: generation) else { return }
        lastFailure = "This message couldn’t be read aloud."
        stop(announcement: nil, preserveFailure: true)
        announce("This message couldn’t be read aloud.")
    }

    private func stop(announcement: String?, preserveFailure: Bool = false) {
        let hadWork = task != nil || lease != nil || status != nil
        guard hadWork else {
            if !preserveFailure { lastFailure = nil }
            return
        }
        task?.cancel()
        task = nil
        player.stop()
        if let lease,
           MobileAudioOwnership.shared.release(lease.audio) {
            VoiceAudioSession.deactivate()
        }
        lease = nil
        pendingRoute = nil
        pendingBotID = nil
        status = nil
        activeBotID = nil
        activeMessageID = nil
        fence.invalidate()
        if !preserveFailure { lastFailure = nil }
        if let announcement { announce(announcement) }
    }

    private func announce(_ value: String) {
        #if canImport(UIKit)
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: value)
        #endif
    }
}

extension AppModel {
    public var readAloud: ReadAloudRuntime { .shared }

    public func canReadAloud(_ message: ChatMessage, in botID: String) -> Bool {
        guard mode == .live, openBotID == botID,
              profileRoute(for: botID) != nil,
              let current = chats[botID]?.displayedMessages().first(where: {
                  $0.id == message.id
              }) else { return false }
        return ReadAloudPolicy.preparedText(for: current) != nil
    }

    public func readMessageAloud(_ message: ChatMessage, in botID: String) {
        ReadAloudRuntime.shared.request(model: self, message: message, botID: botID)
    }

    public func stopReadingAloud() { ReadAloudRuntime.shared.stop() }

    func acquireVoiceAudioOwnership() -> MobileAudioOwnership.Lease? {
        ReadAloudRuntime.shared.acquireVoiceAudio()
    }

    func releaseVoiceAudioOwnership(_ lease: MobileAudioOwnership.Lease) {
        ReadAloudRuntime.shared.releaseVoiceAudio(lease)
    }
}
