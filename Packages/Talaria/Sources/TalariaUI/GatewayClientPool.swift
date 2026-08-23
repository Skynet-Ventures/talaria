import Foundation
import TalariaKit

/// Long-lived gateway clients keyed by saved-connection id.
///
/// The primary app connection remains authoritative for global navigation
/// while the pool is introduced. Remote bot and room operations obtain their
/// owning client here instead of tearing that primary world down. Concurrent
/// callers share one connection attempt, and a failed attempt is evicted so a
/// later foreground/reachability event can retry.
public actor GatewayClientPool {
    public typealias Connector = @Sendable (URL, GatewayCredential) async throws -> GatewayClient
    typealias LifecycleAdmissionInstaller = @Sendable (GatewayClient, String) async -> Void

    /// The exact pooled connection a caller started work against. The client
    /// identity alone is not enough: `adopt` can replace it with another
    /// client, and a later slot can theoretically reuse the same object in a
    /// test or reconnect path. The slot generation closes both races.
    public struct ConnectionSnapshot: Sendable {
        public let client: GatewayClient
        public let generation: UInt64
        /// Endpoint captured when this client won the pool slot. Keeping it in
        /// the pool-owned snapshot lets exact-source callers compare registry
        /// identity without hopping onto the client actor and reopening the
        /// enumeration race.
        public let baseURL: URL?

        public init(client: GatewayClient, generation: UInt64, baseURL: URL? = nil) {
            self.client = client
            self.generation = generation
            self.baseURL = baseURL
        }
    }

    /// One already-published connection retained by the pool. Enumeration is
    /// an actor-isolated snapshot of the whole registry: callers never observe
    /// half of a concurrent adoption and, unlike `connect`, this API can never
    /// start or join a dial.
    public struct RetainedConnectionSnapshot: Sendable {
        public let gatewayID: String
        public let connection: ConnectionSnapshot

        public init(gatewayID: String, connection: ConnectionSnapshot) {
            self.gatewayID = gatewayID
            self.connection = connection
        }
    }

    /// A short critical-section lease for source teardown or roster
    /// publication. Pool adoption waits while the lease is held, so a caller
    /// cannot re-check a snapshot and then mutate AppModel/registry state after
    /// a replacement has already won the slot.
    public struct ConnectionLease: Sendable {
        public let snapshot: ConnectionSnapshot
        public let gatewayID: String
        fileprivate let token: UUID

        fileprivate init(snapshot: ConnectionSnapshot, gatewayID: String, token: UUID) {
            self.snapshot = snapshot
            self.gatewayID = gatewayID
            self.token = token
        }
    }

    /// Source-keyed barrier used when a caller must publish a conservative
    /// stale result precisely because no exact connection authority survived.
    /// Unlike `ConnectionLease`, this does not assert that a slot exists; it
    /// only prevents adopt/disconnect from changing that gateway while the
    /// synchronous source-qualified publication lands.
    struct GatewayBarrierLease: Sendable {
        let gatewayID: String
        fileprivate let token: UUID
    }

    private struct LeaseWaiter {
        let token: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct Slot {
        var generation: UInt64
        var baseURL: URL
        var task: Task<GatewayClient, Error>?
        var client: GatewayClient?
        var leaseToken: UUID?
    }

    private var slots: [String: Slot] = [:]
    private var nextGeneration: UInt64 = 0
    private let connector: Connector
    private let lifecycleAdmissionInstaller: LifecycleAdmissionInstaller?
    /// One exclusive pool barrier per source. An operation lease retains this
    /// token through publication; adopt/disconnect hold it only across their
    /// synchronous slot mutation. Keeping the owner outside `Slot` lets a
    /// guarded disconnect hand the barrier onward after removing the slot.
    private var leaseOwners: [String: UUID] = [:]
    private var leaseWaiters: [String: [LeaseWaiter]] = [:]
    private var publicationWaiterCounts: [String: Int] = [:]

    public init() {
        connector = { baseURL, credential in
            let client = GatewayClient(baseURL: baseURL, credential: credential)
            try await client.connect()
            return client
        }
        lifecycleAdmissionInstaller = nil
    }

    /// Test/support initializer. Production uses the connecting initializer
    /// above; an injected connector makes coalescing and retry behavior
    /// deterministic without opening a network socket.
    public init(connector: @escaping Connector) {
        self.connector = connector
        lifecycleAdmissionInstaller = nil
    }

    /// Deterministic test seam for the actor hop required to install profile
    /// lifecycle admission on a replacement client. Production always uses
    /// the real installer below.
    init(connector: @escaping Connector,
         lifecycleAdmissionInstaller: @escaping LifecycleAdmissionInstaller) {
        self.connector = connector
        self.lifecycleAdmissionInstaller = lifecycleAdmissionInstaller
    }

    public func client(for gatewayID: String) -> GatewayClient? {
        slots[gatewayID]?.client
    }

    public func connectedGatewayIDs() -> Set<String> {
        Set(slots.compactMap { key, slot in slot.client == nil ? nil : key })
    }

    /// Atomically enumerate every connection that is already published.
    /// Connecting slots are intentionally omitted and no connector is ever
    /// invoked; background discovery must not wake or dial a gateway.
    public func retainedConnectionSnapshots() -> [RetainedConnectionSnapshot] {
        slots.compactMap { gatewayID, slot in
            guard let client = slot.client, slot.task == nil else { return nil }
            return RetainedConnectionSnapshot(
                gatewayID: gatewayID,
                connection: ConnectionSnapshot(
                    client: client, generation: slot.generation, baseURL: slot.baseURL)
            )
        }
        .sorted { $0.gatewayID < $1.gatewayID }
    }

    /// Return the existing live client, share an in-flight dial, or start one.
    public func connect(gatewayID: String, baseURL: URL,
                        credential: GatewayCredential) async throws -> GatewayClient {
        try await connectWithGeneration(gatewayID: gatewayID, baseURL: baseURL,
                                        credential: credential).client
    }

    /// The same coalesced connection operation as `connect`, carrying the
    /// generation that owns the returned client. Callers that may outlive a
    /// reconnect use this instead of trying to read the generation in a
    /// second actor hop.
    public func connectWithGeneration(
        gatewayID: String, baseURL: URL, credential: GatewayCredential
    ) async throws -> ConnectionSnapshot {
        if let slot = slots[gatewayID], let client = slot.client {
            return ConnectionSnapshot(
                client: client, generation: slot.generation, baseURL: slot.baseURL)
        }
        if let slot = slots[gatewayID], let task = slot.task {
            return try await publishedConnection(
                task, gatewayID: gatewayID, generation: slot.generation)
        }

        nextGeneration &+= 1
        let generation = nextGeneration
        let connector = self.connector
        // The shared task is the complete publication transaction, not merely
        // the socket dial. Every coalesced caller therefore remains parked
        // through lifecycle-admission installation and the final actor-owned
        // slot mutation; no caller can receive an unadmitted client while the
        // slot still contains only `task`.
        let task = Task { [weak self] () throws -> GatewayClient in
            var connectedClient: GatewayClient?
            do {
                let client = try await connector(baseURL, credential)
                connectedClient = client
                try Task.checkCancellation()
                guard let self else { throw CancellationError() }
                try await self.publishConnectedClient(
                    client, gatewayID: gatewayID, generation: generation)
                return client
            } catch {
                await connectedClient?.disconnect()
                if let self {
                    await self.clearConnectingSlotIfCurrent(
                        gatewayID: gatewayID, generation: generation)
                }
                throw error
            }
        }
        slots[gatewayID] = Slot(generation: generation, baseURL: baseURL,
                                 task: task, client: nil, leaseToken: nil)
        return try await publishedConnection(
            task, gatewayID: gatewayID, generation: generation)
    }

    /// Whether this exact client still owns the named slot.
    public func isCurrent(_ snapshot: ConnectionSnapshot, for gatewayID: String) -> Bool {
        guard let slot = slots[gatewayID], slot.generation == snapshot.generation,
              let client = slot.client else { return false }
        return ObjectIdentifier(client) == ObjectIdentifier(snapshot.client)
    }

    /// Reserve the current slot for one short source-qualified mutation. The
    /// reservation is acquired on the pool actor; once it succeeds, `adopt`
    /// and ordinary disconnects wait until `release` (or the guarded
    /// disconnect) completes.
    public func acquireLease(_ snapshot: ConnectionSnapshot,
                             for gatewayID: String) async -> ConnectionLease? {
        guard let token = await acquireLeaseBarrier(gatewayID: gatewayID) else { return nil }
        guard let slot = slots[gatewayID], slot.generation == snapshot.generation,
              let client = slot.client,
              ObjectIdentifier(client) == ObjectIdentifier(snapshot.client),
              slot.leaseToken == nil else {
            releaseLeaseBarrier(token, gatewayID: gatewayID)
            return nil
        }
        let lease = ConnectionLease(snapshot: snapshot, gatewayID: gatewayID,
                                    token: token)
        slots[gatewayID]?.leaseToken = lease.token
        return lease
    }

    /// Release a critical-section lease without disconnecting its client.
    public func release(_ lease: ConnectionLease) {
        guard leaseOwners[lease.gatewayID] == lease.token else { return }
        if slots[lease.gatewayID]?.leaseToken == lease.token {
            slots[lease.gatewayID]?.leaseToken = nil
        }
        releaseLeaseBarrier(lease.token, gatewayID: lease.gatewayID)
    }

    func acquireGatewayBarrier(for gatewayID: String) async -> GatewayBarrierLease? {
        guard !gatewayID.isEmpty,
              let token = await acquireLeaseBarrier(gatewayID: gatewayID) else { return nil }
        return GatewayBarrierLease(gatewayID: gatewayID, token: token)
    }

    func release(_ lease: GatewayBarrierLease) {
        releaseLeaseBarrier(lease.token, gatewayID: lease.gatewayID)
    }

    /// Disconnect only if the slot still belongs to the expected connection.
    /// This check and removal are one actor operation, so an old roster
    /// failure cannot disconnect a client adopted after that failure began.
    @discardableResult
    public func disconnectIfCurrent(_ snapshot: ConnectionSnapshot,
                                    for gatewayID: String,
                                    lease: ConnectionLease? = nil) async -> Bool {
        let ownedLease: ConnectionLease?
        if let lease {
            ownedLease = lease
        } else {
            // Preserve the original conditional-disconnect API for callers
            // that do not also own a cleanup section. Acquiring a lease here
            // still makes the identity check and slot removal safe against a
            // concurrent adoption; the registry path passes its existing
            // lease so AppModel cleanup and removal remain one section.
            ownedLease = await acquireLease(snapshot, for: gatewayID)
        }
        guard let slot = slots[gatewayID], slot.generation == snapshot.generation,
              let client = slot.client,
              ObjectIdentifier(client) == ObjectIdentifier(snapshot.client),
              let ownedLease,
              slot.leaseToken == ownedLease.token,
              leaseOwners[gatewayID] == ownedLease.token else {
            if lease == nil, let ownedLease { release(ownedLease) }
            return false
        }
        slots[gatewayID] = nil
        releaseLeaseBarrier(ownedLease.token, gatewayID: gatewayID)
        await client.disconnect()
        return true
    }

    /// Register a client already connected by the primary AppModel path.
    /// Replacing a different pooled client closes the old one after the new
    /// identity is installed, so a re-entrant lookup never returns the loser.
    public func adopt(_ client: GatewayClient, for gatewayID: String) async {
        _ = try? await adoptWithGeneration(client, for: gatewayID)
    }

    /// The same adoption transaction, returning the exact generation installed
    /// by this call. A caller that loses source authority after this suspension
    /// can use `disconnectIfCurrent` without racing a later re-adoption — even
    /// when that later owner deliberately reuses the same client object.
    @discardableResult
    public func adoptWithGeneration(_ client: GatewayClient, for gatewayID: String) async throws
        -> ConnectionSnapshot {
        let baseURL = await client.baseURL
        // Install admission before entering the pool barrier. This actor hop
        // used to occur after `waitForLease`; a second operation could acquire
        // a lease during the hop and then be overwritten by this adoption.
        await installLifecycleAdmission(on: client, gatewayID: gatewayID)
        guard let reservation = await acquireLeaseBarrier(gatewayID: gatewayID) else {
            throw CancellationError()
        }
        let previous = slots[gatewayID]
        nextGeneration &+= 1
        let generation = nextGeneration
        slots[gatewayID] = Slot(generation: generation, baseURL: baseURL,
                                 task: nil, client: client, leaseToken: nil)
        releaseLeaseBarrier(reservation, gatewayID: gatewayID)

        previous?.task?.cancel()
        if let old = previous?.client, ObjectIdentifier(old) != ObjectIdentifier(client) {
            await old.disconnect()
        } else if let task = previous?.task, let old = try? await task.value,
                  ObjectIdentifier(old) != ObjectIdentifier(client) {
            await old.disconnect()
        }
        return ConnectionSnapshot(client: client, generation: generation, baseURL: baseURL)
    }

    public func disconnect(gatewayID: String) async {
        guard let reservation = await acquireLeaseBarrier(gatewayID: gatewayID) else { return }
        let slot = slots.removeValue(forKey: gatewayID)
        releaseLeaseBarrier(reservation, gatewayID: gatewayID)
        guard let slot else { return }
        slot.task?.cancel()
        if let client = slot.client {
            await client.disconnect()
        } else if let task = slot.task, let client = try? await task.value {
            await client.disconnect()
        }
    }

    public func disconnectAll() async {
        let ids = Array(slots.keys)
        for id in ids { await disconnect(gatewayID: id) }
    }

    private func installLifecycleAdmission(on client: GatewayClient, gatewayID: String) async {
        if let lifecycleAdmissionInstaller {
            await lifecycleAdmissionInstaller(client, gatewayID)
            return
        }
        await client.setTrafficAdmission {
            await ProfileLifecycleTrafficAdmission.acquire(gatewayID)
        }
    }

    /// Finish an in-flight dial on the pool actor. Admission installation is
    /// the sole suspension before publication; a concurrent adopt/disconnect
    /// may replace the generation during that hop, so both cancellation and
    /// generation are re-proven immediately before the slot becomes visible.
    private func publishConnectedClient(_ client: GatewayClient, gatewayID: String,
                                        generation: UInt64) async throws {
        await installLifecycleAdmission(on: client, gatewayID: gatewayID)
        try Task.checkCancellation()
        guard let current = slots[gatewayID], current.generation == generation,
              current.client == nil, current.task != nil else {
            throw CancellationError()
        }
        slots[gatewayID] = Slot(generation: generation, baseURL: current.baseURL,
                                task: nil, client: client, leaseToken: nil)
    }

    /// Await the one shared publication transaction, then validate that its
    /// exact client still owns the exact generation. A cancelled waiter never
    /// cancels shared work for other callers and never receives the result.
    private func publishedConnection(_ task: Task<GatewayClient, Error>,
                                     gatewayID: String,
                                     generation: UInt64) async throws -> ConnectionSnapshot {
        try Task.checkCancellation()
        publicationWaiterCounts[gatewayID, default: 0] += 1
        defer {
            let remaining = max(0, publicationWaiterCounts[gatewayID, default: 1] - 1)
            publicationWaiterCounts[gatewayID] = remaining == 0 ? nil : remaining
        }
        let client = try await task.value
        try Task.checkCancellation()
        guard let current = slots[gatewayID], current.generation == generation,
              let published = current.client,
              ObjectIdentifier(published) == ObjectIdentifier(client),
              current.task == nil else {
            throw CancellationError()
        }
        return ConnectionSnapshot(
            client: published, generation: generation, baseURL: current.baseURL)
    }

    private func clearConnectingSlotIfCurrent(gatewayID: String, generation: UInt64) {
        guard let current = slots[gatewayID], current.generation == generation,
              current.client == nil else { return }
        slots[gatewayID] = nil
    }

    /// Acquire the source's exclusive pool barrier. A released owner hands the
    /// token directly to one FIFO waiter before resuming it, so wakeups cannot
    /// race each other or be overtaken by a new caller. The loop re-checks the
    /// handed-off identity after every suspension; cancellation removes a
    /// queued waiter, and a cancelled granted waiter releases its handoff.
    private func acquireLeaseBarrier(gatewayID: String) async -> UUID? {
        let token = UUID()
        while true {
            guard !Task.isCancelled else {
                if leaseOwners[gatewayID] == token {
                    releaseLeaseBarrier(token, gatewayID: gatewayID)
                }
                return nil
            }
            if leaseOwners[gatewayID] == token { return token }
            if leaseOwners[gatewayID] == nil {
                leaseOwners[gatewayID] = token
                return token
            }

            let granted = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume(returning: false)
                    } else if leaseOwners[gatewayID] == nil {
                        // The owner may have released between the loop check
                        // and continuation installation. Claim synchronously
                        // instead of waiting for a wakeup that already passed.
                        leaseOwners[gatewayID] = token
                        continuation.resume(returning: true)
                    } else {
                        leaseWaiters[gatewayID, default: []].append(
                            LeaseWaiter(token: token, continuation: continuation)
                        )
                    }
                }
            } onCancel: {
                Task { await self.cancelLeaseWaiter(token, gatewayID: gatewayID) }
            }
            guard granted else { return nil }
            // Re-check in the loop. Direct handoff installs `token` before the
            // continuation resumes, while cancellation may have retired it.
        }
    }

    private func releaseLeaseBarrier(_ token: UUID, gatewayID: String) {
        guard leaseOwners[gatewayID] == token else { return }
        leaseOwners[gatewayID] = nil
        resumeNextLeaseWaiter(gatewayID: gatewayID)
    }

    private func resumeNextLeaseWaiter(gatewayID: String) {
        guard leaseOwners[gatewayID] == nil,
              var queue = leaseWaiters[gatewayID], !queue.isEmpty else { return }
        let next = queue.removeFirst()
        if queue.isEmpty { leaseWaiters[gatewayID] = nil }
        else { leaseWaiters[gatewayID] = queue }
        leaseOwners[gatewayID] = next.token
        next.continuation.resume(returning: true)
    }

    private func cancelLeaseWaiter(_ token: UUID, gatewayID: String) {
        guard var queue = leaseWaiters[gatewayID],
              let index = queue.firstIndex(where: { $0.token == token }) else { return }
        let waiter = queue.remove(at: index)
        if queue.isEmpty { leaseWaiters[gatewayID] = nil }
        else { leaseWaiters[gatewayID] = queue }
        waiter.continuation.resume(returning: false)
    }

    /// Focused concurrency-test visibility; production callers do not need to
    /// observe the barrier queue.
    func queuedLeaseWaiterCount(for gatewayID: String) -> Int {
        leaseWaiters[gatewayID]?.count ?? 0
    }

    func connectingPublicationWaiterCount(for gatewayID: String) -> Int {
        publicationWaiterCounts[gatewayID] ?? 0
    }
}
