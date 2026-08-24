import Foundation
import Observation
import TalariaKit

struct MessagingPlatformScope: Equatable, Sendable {
    let gatewayID: String
    let profile: String

    init?(gatewayID: String?, profile: String?) {
        guard let gatewayID, !gatewayID.isEmpty,
              let profile = MessagingPlatformIdentityAdmission.profile(profile) else { return nil }
        self.gatewayID = gatewayID
        self.profile = profile
    }
}

struct MessagingPlatformConnection: Sendable {
    let gatewayID: String
    let client: GatewayClient
    let generation: UInt64

    static func same(_ lhs: Self?, _ rhs: Self?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.gatewayID == rhs.gatewayID && lhs.generation == rhs.generation
            && ObjectIdentifier(lhs.client) == ObjectIdentifier(rhs.client)
    }
}

@MainActor
protocol MessagingPlatformTransport: AnyObject {
    func resolve(gatewayID: String) async throws -> MessagingPlatformConnection
    func isCurrent(_ connection: MessagingPlatformConnection) async -> Bool
    func load(connection: MessagingPlatformConnection,
              profile: String) async throws -> MessagingPlatformCatalog
    func update(connection: MessagingPlatformConnection,
                authority: MessagingPlatformMutationAuthority,
                mutation: MessagingPlatformMutation,
                profile: String) async throws
    func check(connection: MessagingPlatformConnection,
               authority: MessagingPlatformMutationAuthority,
               profile: String) async throws -> MessagingPlatformTestResult
    func subscribe(connection: MessagingPlatformConnection,
                   handler: @escaping @Sendable (GatewayEvent) -> Void) async -> UUID
    func unsubscribe(connection: MessagingPlatformConnection, id: UUID) async
}

/// Exact-source state machine behind Settings → Connections & Notifications.
/// The screen never talks to a "current" client after choosing a target. Each
/// result is admitted only if gateway, profile, client identity, pool slot
/// generation, and local scope generation still match.
@MainActor
@Observable
final class MessagingPlatformLifecycleCoordinator {
    private(set) var scope: MessagingPlatformScope?
    private(set) var platforms: [MessagingPlatform] = []
    private(set) var gatewayStartCommand = ""
    private(set) var isLoading = false
    private(set) var busyAction: String?
    private(set) var notice: String?
    private(set) var noticeIsWarning = false
    private(set) var unsupported = false
    private(set) var changeEventRefreshCount = 0

    @ObservationIgnored private let transport: MessagingPlatformTransport
    @ObservationIgnored private var scopeGeneration: UInt64 = 0
    @ObservationIgnored private var catalogConnection: MessagingPlatformConnection?
    @ObservationIgnored private var subscription: (MessagingPlatformConnection, UUID)?

    init(transport: MessagingPlatformTransport) {
        self.transport = transport
    }

    func select(gatewayID: String?, profile: String?) {
        let next = MessagingPlatformScope(gatewayID: gatewayID, profile: profile)
        guard next != scope else { return }
        scopeGeneration &+= 1
        scope = next
        platforms = []
        gatewayStartCommand = ""
        isLoading = false
        busyAction = nil
        notice = next == nil
            ? "Choose a connected gateway and an exact Hermes profile to manage messaging platforms."
            : nil
        noticeIsWarning = next == nil
        unsupported = false
        catalogConnection = nil
        detachSubscription()
    }

    func refresh() async {
        guard let scope else { return }
        let generation = scopeGeneration
        isLoading = true
        defer { if accepts(scope: scope, generation: generation) { isLoading = false } }
        do {
            let connection = try await transport.resolve(gatewayID: scope.gatewayID)
            guard accepts(scope: scope, generation: generation),
                  await transport.isCurrent(connection) else { return }
            let catalog = try await transport.load(connection: connection, profile: scope.profile)
            guard accepts(scope: scope, generation: generation),
                  await transport.isCurrent(connection) else { return }
            publish(catalog: catalog, success: nil)
            catalogConnection = connection
            unsupported = false
            await replaceSubscription(connection: connection, scope: scope,
                                      generation: generation)
        } catch {
            guard accepts(scope: scope, generation: generation) else { return }
            publish(error: error, submittedSecrets: [])
        }
    }

    func saveCredentials(platformID: String, values: [String: String]) async -> Bool {
        let nonempty = values.filter {
            !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !nonempty.isEmpty else {
            notice = "Enter at least one new credential before saving. Existing credentials stay configured."
            noticeIsWarning = true
            return false
        }
        return await mutate(platformID: platformID,
                            mutation: MessagingPlatformMutation(environment: nonempty),
                            action: "save:\(platformID)", success: "Credentials saved.")
    }

    func setEnabled(_ enabled: Bool, platformID: String) async -> Bool {
        await mutate(platformID: platformID,
                     mutation: MessagingPlatformMutation(enabled: enabled),
                     action: "enabled:\(platformID)",
                     success: enabled ? "Platform enabled." : "Platform disabled.")
    }

    func clearCredential(platformID: String, key: String) async -> Bool {
        await mutate(platformID: platformID,
                     mutation: MessagingPlatformMutation(clearEnvironment: [key]),
                     action: "clear:\(platformID):\(key)", success: "Credential cleared.")
    }

    func checkConnection(platformID: String) async -> Bool {
        guard let capture = mutationCapture(platformID: platformID) else { return false }
        busyAction = "check:\(platformID)"
        defer { if accepts(capture) { busyAction = nil } }
        do {
            guard await transport.isCurrent(capture.connection) else { return false }
            let result = try await transport.check(
                connection: capture.connection, authority: capture.authority,
                profile: capture.scope.profile)
            guard accepts(capture), await transport.isCurrent(capture.connection) else {
                return false
            }
            notice = result.message.isEmpty
                ? (result.ok ? "Connection is healthy." : "Connection check did not pass.")
                : result.message
            noticeIsWarning = !result.ok
            return result.ok
        } catch {
            guard accepts(capture) else { return false }
            publish(error: error, submittedSecrets: [])
            return false
        }
    }

    /// Exposed to the source-qualified event pump and focused tests. A global
    /// `platforms.changed` contains no ids; its authority comes entirely from
    /// the exact subscribed client/generation plus the retained profile scope.
    func receivePlatformsChanged(
        source: MessagingPlatformConnection, profile: String, event: GatewayEvent
    ) {
        guard event.type == "platforms.changed", event.isGlobal,
              let scope, scope.profile == profile, scope.gatewayID == source.gatewayID,
              MessagingPlatformConnection.same(source, catalogConnection) else { return }
        let generation = scopeGeneration
        Task { @MainActor [weak self] in
            guard let self, self.accepts(scope: scope, generation: generation),
                  await self.transport.isCurrent(source) else { return }
            self.changeEventRefreshCount += 1
            await self.refresh()
        }
    }

    func tearDown() { detachSubscription() }

    private struct MutationCapture {
        let scope: MessagingPlatformScope
        let generation: UInt64
        let connection: MessagingPlatformConnection
        let authority: MessagingPlatformMutationAuthority
    }

    private func mutationCapture(platformID: String) -> MutationCapture? {
        guard let scope, let connection = catalogConnection,
              let platform = platforms.first(where: { $0.id == platformID }),
              MessagingPlatformIdentityAdmission.platform(platformID) == platformID else {
            notice = "Refresh the platform list before changing it."
            noticeIsWarning = true
            return nil
        }
        return MutationCapture(scope: scope, generation: scopeGeneration,
                               connection: connection, authority: platform.authority)
    }

    private func mutate(platformID: String, mutation: MessagingPlatformMutation,
                        action: String, success: String) async -> Bool {
        guard let capture = mutationCapture(platformID: platformID) else { return false }
        let submittedSecrets = mutation.submittedSecrets
        busyAction = action
        defer { if accepts(capture) { busyAction = nil } }
        do {
            guard await transport.isCurrent(capture.connection) else { return false }
            try await transport.update(
                connection: capture.connection, authority: capture.authority,
                mutation: mutation, profile: capture.scope.profile)
            guard accepts(capture), await transport.isCurrent(capture.connection) else {
                return false
            }
            // Never paint optimistic enable/configured state. The authoritative
            // GET on the exact same connection decides what the row says.
            let catalog = try await transport.load(
                connection: capture.connection, profile: capture.scope.profile)
            guard accepts(capture), await transport.isCurrent(capture.connection) else {
                return false
            }
            publish(catalog: catalog, success: success)
            return true
        } catch {
            guard accepts(capture) else { return false }
            publish(error: error, submittedSecrets: submittedSecrets)
            return false
        }
    }

    private func accepts(scope: MessagingPlatformScope, generation: UInt64) -> Bool {
        self.scope == scope && scopeGeneration == generation
    }

    private func accepts(_ capture: MutationCapture) -> Bool {
        accepts(scope: capture.scope, generation: capture.generation)
            && MessagingPlatformConnection.same(capture.connection, catalogConnection)
    }

    private func publish(error: Error, submittedSecrets: [String]) {
        let gatewayError = error as? GatewayError
        unsupported = gatewayError?.code == 404
        if unsupported {
            notice = "This gateway does not expose messaging-platform management. Update Hermes to manage channels from Talaria."
        } else {
            let raw = gatewayError?.message ?? error.localizedDescription
            notice = MessagingPlatformSecretRedaction.serverMessage(
                raw, submittedSecrets: submittedSecrets)
        }
        noticeIsWarning = true
    }

    private func publish(catalog: MessagingPlatformCatalog, success: String?) {
        platforms = catalog.platforms
        gatewayStartCommand = catalog.gatewayStartCommand
        if catalog.rejectedOversizedPlatformList {
            notice = (success.map { "\($0) " } ?? "")
                + "The gateway reported too many messaging platforms. Talaria rejected the list so an unseen duplicate cannot authorize a mutation."
            noticeIsWarning = true
        } else if catalog.hasOmissions {
            notice = (success.map { "\($0) " } ?? "")
                + "\(catalog.omittedRowCount) unsafe, ambiguous or oversized platform row(s) were omitted. Admitted rows remain source-declared."
            noticeIsWarning = true
        } else {
            notice = success
            noticeIsWarning = false
        }
    }

    private func replaceSubscription(
        connection: MessagingPlatformConnection, scope: MessagingPlatformScope,
        generation: UInt64
    ) async {
        if let subscription,
           MessagingPlatformConnection.same(subscription.0, connection) { return }
        detachSubscription()
        let id = await transport.subscribe(connection: connection) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.accepts(scope: scope, generation: generation) else { return }
                self.receivePlatformsChanged(source: connection, profile: scope.profile, event: event)
            }
        }
        guard accepts(scope: scope, generation: generation),
              await transport.isCurrent(connection) else {
            await transport.unsubscribe(connection: connection, id: id)
            return
        }
        subscription = (connection, id)
    }

    private func detachSubscription() {
        guard let old = subscription else { return }
        subscription = nil
        Task { @MainActor [transport] in
            await transport.unsubscribe(connection: old.0, id: old.1)
        }
    }
}

@MainActor
enum MessagingPlatformExactConnectionLease {
    /// Hold replacement and profile-lifecycle admission across the complete
    /// REST await. Reads and tests are just as profile-sensitive as writes:
    /// resolving an exact client and then releasing authority before the HTTP
    /// response arrives would let a rename/delete or reconnect publish stale
    /// configuration into the newly selected scope.
    static func perform<Value: Sendable>(
        connection: MessagingPlatformConnection,
        operation: @escaping @Sendable (GatewayClient) async throws -> Value
    ) async throws -> Value {
        try await perform(connection: connection,
                          pool: ConnectionRegistry.shared.clientPool,
                          operation: operation)
    }

    static func perform<Value: Sendable>(
        connection: MessagingPlatformConnection,
        pool: GatewayClientPool,
        operation: @escaping @Sendable (GatewayClient) async throws -> Value
    ) async throws -> Value {
        let snapshot = GatewayClientPool.ConnectionSnapshot(
            client: connection.client, generation: connection.generation)
        guard let poolLease = await pool.acquireLease(snapshot, for: connection.gatewayID) else {
            throw CancellationError()
        }
        guard let trafficLease = ProfileLifecycleTrafficAdmission.acquire(connection.gatewayID) else {
            await pool.release(poolLease)
            throw GatewayError(code: GatewayClient.trafficFenced,
                               message: "Gateway traffic is paused during a profile change.")
        }

        do {
            let value = try await operation(connection.client)
            await trafficLease.release()
            await pool.release(poolLease)
            return value
        } catch {
            await trafficLease.release()
            await pool.release(poolLease)
            throw error
        }
    }
}

@MainActor
private final class LiveMessagingPlatformTransport: MessagingPlatformTransport {
    weak var model: AppModel?

    init(model: AppModel) { self.model = model }

    func resolve(gatewayID: String) async throws -> MessagingPlatformConnection {
        guard let model, model.mode == .live,
              model.profileLifecycleAllowsGatewayTraffic(gatewayID) else {
            throw GatewayError(code: GatewayClient.trafficFenced,
                               message: "Gateway traffic is unavailable during this profile change.")
        }
        let registry = ConnectionRegistry.shared
        guard let gateway = registry.saved.first(where: { $0.id == gatewayID }),
              let baseURL = gateway.baseURL,
              let credential = registry.credential(for: gateway) else {
            throw GatewayError(code: -12,
                               message: "The selected gateway is unavailable or needs sign-in.")
        }
        let snapshot = try await registry.clientPool.connectWithGeneration(
            gatewayID: gatewayID, baseURL: baseURL, credential: credential)
        guard model.profileLifecycleAllowsGatewayTraffic(gatewayID),
              gatewayID != model.activeGatewayID
                || model.client.map(ObjectIdentifier.init) == ObjectIdentifier(snapshot.client)
        else { throw CancellationError() }
        return MessagingPlatformConnection(gatewayID: gatewayID, client: snapshot.client,
                                           generation: snapshot.generation)
    }

    func isCurrent(_ connection: MessagingPlatformConnection) async -> Bool {
        guard let model, model.profileLifecycleAllowsGatewayTraffic(connection.gatewayID),
              await ConnectionRegistry.shared.clientPool.isCurrent(
                .init(client: connection.client, generation: connection.generation),
                for: connection.gatewayID) else { return false }
        return connection.gatewayID != model.activeGatewayID
            || model.client.map(ObjectIdentifier.init) == ObjectIdentifier(connection.client)
    }

    func load(connection: MessagingPlatformConnection,
              profile: String) async throws -> MessagingPlatformCatalog {
        try await MessagingPlatformExactConnectionLease.perform(connection: connection) { client in
            try await client.messagingPlatforms(profile: profile)
        }
    }

    func update(connection: MessagingPlatformConnection,
                authority: MessagingPlatformMutationAuthority,
                mutation: MessagingPlatformMutation,
                profile: String) async throws {
        try await MessagingPlatformExactConnectionLease.perform(connection: connection) { client in
            try await client.updateMessagingPlatform(
                authority: authority, mutation: mutation, profile: profile)
        }
    }

    func check(connection: MessagingPlatformConnection,
               authority: MessagingPlatformMutationAuthority,
               profile: String) async throws -> MessagingPlatformTestResult {
        try await MessagingPlatformExactConnectionLease.perform(connection: connection) { client in
            try await client.testMessagingPlatform(authority: authority, profile: profile)
        }
    }

    func subscribe(connection: MessagingPlatformConnection,
                   handler: @escaping @Sendable (GatewayEvent) -> Void) async -> UUID {
        await connection.client.addEventHandler(handler)
    }

    func unsubscribe(connection: MessagingPlatformConnection, id: UUID) async {
        await connection.client.removeEventHandler(id)
    }
}

extension AppModel {
    func makeMessagingPlatformLifecycle() -> MessagingPlatformLifecycleCoordinator {
        MessagingPlatformLifecycleCoordinator(transport: LiveMessagingPlatformTransport(model: self))
    }
}
