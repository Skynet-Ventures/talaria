import Foundation
import TalariaKit

// The shared-room gateway mirror is deliberately a side-table runtime. AppModel
// cannot gain stored properties from an extension, and there is one room world
// per process. A global debounce feeds independent gateway lanes; each lane has
// at most one read/merge/write/read-back transaction in flight.

struct RoomProjectionSyncTarget: Equatable, Sendable {
    var gatewayID: String
    var label: String?

    init(gatewayID: String, label: String? = nil) {
        self.gatewayID = gatewayID
        self.label = label
    }
}

/// The exact pooled connection generation protected for one complete
/// read/merge/write/read-back transaction. Production RPCs must use `client`
/// directly: resolving the route again inside the lease could select a newly
/// published AppModel client while the pool lease still protects its predecessor.
struct RoomProjectionLeasedTarget: Sendable {
    var target: RoomProjectionSyncTarget
    var client: GatewayClient?
    var connectionGeneration: UInt64

    init(target: RoomProjectionSyncTarget, client: GatewayClient? = nil,
         connectionGeneration: UInt64 = 0) {
        self.target = target
        self.client = client
        self.connectionGeneration = connectionGeneration
    }
}

struct RoomProjectionRemoteState: Equatable, Sendable {
    var projection: RoomProjectionEnvelope?
    var revision: Int
    var supportsCAS: Bool
    var profileName: String

    init(projection: RoomProjectionEnvelope?, revision: Int = 0,
         supportsCAS: Bool, profileName: String = "default") {
        self.projection = projection
        self.revision = max(0, revision)
        self.supportsCAS = supportsCAS
        self.profileName = profileName.isEmpty ? "default" : profileName
    }
}

struct RoomProjectionSyncJob: Equatable, Sendable {
    var allowEmpty: Bool
    var changedRooms: [String]
    var deletedRooms: [String]
    /// Internal transition intent: fan out only after this source lane has
    /// converged (or exhausted retries), so stale local state cannot race ahead.
    var reseedAfterAttempt: Bool

    init(allowEmpty: Bool = false, changedRooms: [String] = [],
         deletedRooms: [String] = [], reseedAfterAttempt: Bool = false) {
        self.allowEmpty = allowEmpty
        self.changedRooms = Self.unique(changedRooms)
        self.deletedRooms = Self.unique(deletedRooms)
        self.reseedAfterAttempt = reseedAfterAttempt
    }

    var hasExplicitEdits: Bool { !changedRooms.isEmpty || !deletedRooms.isEmpty }
    var preservingKeys: Set<String> { Set(changedRooms).union(deletedRooms) }

    func merging(_ newer: Self) -> Self {
        Self(allowEmpty: allowEmpty || newer.allowEmpty,
             changedRooms: changedRooms + newer.changedRooms,
             deletedRooms: deletedRooms + newer.deletedRooms,
             reseedAfterAttempt: reseedAfterAttempt || newer.reseedAfterAttempt)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Narrow network/storage seams. Production still exercises AppModel routing,
/// profiles.list/configure, RoomStore, and RoomRuntime; focused scheduler tests
/// can replace only these boundaries without inventing a gateway transport.
@MainActor
struct RoomProjectionSyncOperations {
    typealias LeasedOperation = @MainActor @Sendable (
        RoomProjectionLeasedTarget
    ) async throws -> Void

    var targets: (AppModel) async -> [RoomProjectionSyncTarget]
    var withTargetLease: (AppModel, RoomProjectionSyncTarget,
                          @escaping LeasedOperation) async throws -> Void
    var read: (RoomProjectionLeasedTarget) async throws
        -> RoomProjectionRemoteState
    var localProjection: (_ updatedAt: UInt64) async throws
        -> RoomProjectionEnvelope
    var reconcile: (_ incoming: RoomProjectionEnvelope,
                    _ target: RoomProjectionSyncTarget,
                    _ preservingKeys: Set<String>) async throws -> Void
    var writeCAS: (RoomProjectionLeasedTarget, String,
                   RoomProjectionEnvelope, Int) async throws
        -> ProfileConfigureResult
    var writeLegacy: (RoomProjectionLeasedTarget, String,
                      RoomProjectionEnvelope) async throws -> [String: Bool]
    var sleep: (Duration) async throws -> Void
    var nowMilliseconds: () -> UInt64

    static let production = Self(
        targets: { _ in
            let registry = ConnectionRegistry.shared
            return registry.saved.compactMap { gateway in
                guard gateway.baseURL != nil,
                      registry.credential(for: gateway) != nil else { return nil }
                return RoomProjectionSyncTarget(gatewayID: gateway.id,
                                                label: gateway.name)
            }
        },
        withTargetLease: { _, target, operation in
            let registry = ConnectionRegistry.shared
            guard let gateway = registry.saved.first(where: {
                $0.id == target.gatewayID
            }), let baseURL = gateway.baseURL,
                  let credential = registry.credential(for: gateway) else {
                throw AppModel.GatewayRouteError.unknownGateway(target.gatewayID)
            }
            let snapshot = try await registry.clientPool.connectWithGeneration(
                gatewayID: target.gatewayID,
                baseURL: baseURL,
                credential: credential)
            let completed = try await registry.clientPool
                .withCommandConnectionAndTrafficLease(
                    snapshot, for: target.gatewayID
                ) { @MainActor in
                    try await operation(RoomProjectionLeasedTarget(
                        target: target, client: snapshot.client,
                        connectionGeneration: snapshot.generation))
                    return true
                }
            guard completed == true else { throw CancellationError() }
        },
        read: { leased in
            guard let client = leased.client else { throw CancellationError() }
            let profiles = try await client.listProfiles(includeSessions: false)
            let profile = profiles.first {
                RoomProjectionSyncOperations.isExactDefaultProfileName($0.name)
            }
            guard let profile else {
                return RoomProjectionRemoteState(
                    projection: nil, supportsCAS: false)
            }
            // Nil and an empty map carry different protocol meanings. Merely
            // defaulting a missing map to [:] would send CAS to an old gateway.
            let revisions = profile.uiMetaRevisions
            return RoomProjectionRemoteState(
                projection: RoomProjectionEnvelope(uiMeta: profile.uiMeta),
                revision: revisions?[RoomProjectionEnvelope.metadataKey] ?? 0,
                supportsCAS: revisions != nil,
                profileName: profile.name)
        },
        localProjection: { updatedAt in
            try await RoomProjectionRuntime.productionLocalProjection(
                updatedAt: updatedAt)
        },
        reconcile: { incoming, _, preservingKeys in
            try await RoomProjectionRuntime.productionReconcile(
                incoming, preservingKeys: preservingKeys)
        },
        writeCAS: { leased, profileName, projection, expected in
            guard let client = leased.client else { throw CancellationError() }
            let edit = ProfileEdit(
                uiMeta: projection.uiMetaPatch,
                uiMetaExpectedRevisions: [RoomProjectionEnvelope.metadataKey: expected])
            return try await client.applyProfileEditResult(name: profileName, edit)
        },
        writeLegacy: { leased, profileName, projection in
            guard let client = leased.client else { throw CancellationError() }
            return try await client.applyProfileEdit(
                name: profileName, ProfileEdit(uiMeta: projection.uiMetaPatch))
        },
        sleep: { duration in try await Task.sleep(for: duration) },
        nowMilliseconds: {
            let milliseconds = Date().timeIntervalSince1970 * 1_000
            guard milliseconds.isFinite, milliseconds > 0 else { return 0 }
            return milliseconds >= Double(UInt64.max)
                ? UInt64.max : UInt64(milliseconds.rounded(.towardZero))
        })

    static func isExactDefaultProfileName(_ name: String) -> Bool {
        name == "default"
    }
}

private enum RoomProjectionSyncFailure: Error {
    case revisionOverflow
    case rejectedCAS
    case rejectedLegacy
    case missingReadback
    case staleReadback
}

@MainActor
final class RoomProjectionRuntime {
    static let shared = RoomProjectionRuntime()

    private struct TaskSlot {
        var token: UUID
        var task: Task<Void, Never>
    }

    private(set) var operations: RoomProjectionSyncOperations
    private let coalescingDelay: Duration
    private let retryDelays: [Duration]
    private let maximumRetries: Int

    private var generation: UInt64 = 0
    private var laneGenerations: [String: UInt64] = [:]
    private var suppressedGatewayIDs = Set<String>()
    private var debouncedJob: RoomProjectionSyncJob?
    private var debounceTask: TaskSlot?
    private var pendingByGateway: [String: RoomProjectionSyncJob] = [:]
    private var targetsByGateway: [String: RoomProjectionSyncTarget] = [:]
    private var workers: [String: TaskSlot] = [:]
    private var retryTasks: [String: TaskSlot] = [:]
    private var retryCounts: [String: Int] = [:]
    private var reseedRequestGenerations: [String: UInt64] = [:]

    convenience init() {
        self.init(operations: .production)
    }

    init(operations: RoomProjectionSyncOperations,
         coalescingDelay: Duration = .milliseconds(350),
         retryDelays: [Duration] = [
             .seconds(1), .seconds(2), .seconds(4), .seconds(8),
             .seconds(16), .seconds(30), .seconds(30), .seconds(30),
         ], maximumRetries: Int = 8) {
        self.operations = operations
        self.coalescingDelay = coalescingDelay
        self.retryDelays = retryDelays.isEmpty ? [.seconds(30)] : retryDelays
        self.maximumRetries = max(0, maximumRetries)
    }

    var hasPendingWork: Bool {
        debouncedJob != nil || debounceTask != nil || !pendingByGateway.isEmpty
            || !workers.isEmpty || !retryTasks.isEmpty
    }

    func pendingJob(gatewayID: String) -> RoomProjectionSyncJob? {
        pendingByGateway[gatewayID]
    }

    func retryCount(gatewayID: String) -> Int { retryCounts[gatewayID] ?? 0 }

    func schedule(model: AppModel, allowEmpty: Bool = false,
                  changedRooms: [String] = [], deletedRooms: [String] = []) {
        let incoming = RoomProjectionSyncJob(
            allowEmpty: allowEmpty,
            changedRooms: changedRooms,
            deletedRooms: deletedRooms)
        debouncedJob = debouncedJob.map { $0.merging(incoming) } ?? incoming
        debounceTask?.task.cancel()

        let token = UUID()
        let expectedGeneration = generation
        let delay = coalescingDelay
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.operations.sleep(delay) }
            catch {
                if self.debounceTask?.token == token { self.debounceTask = nil }
                return
            }
            guard !Task.isCancelled,
                  self.generation == expectedGeneration,
                  self.debounceTask?.token == token else { return }
            guard let job = self.debouncedJob else { return }
            self.debouncedJob = nil
            let targets = await self.operations.targets(model)
            guard !Task.isCancelled,
                  self.generation == expectedGeneration,
                  self.debounceTask?.token == token else { return }
            for target in targets {
                self.enqueue(job, target: target, model: model)
            }
            if self.debounceTask?.token == token { self.debounceTask = nil }
        }
        debounceTask = TaskSlot(token: token, task: task)
    }

    /// Reconnect/source-transition hook. The source lane starts immediately so
    /// its projection is observed before the debounced all-gateway reseed. The
    /// lane itself still performs the same serialized pull/merge transaction.
    func pullAndReseed(model: AppModel, gatewayID: String) async {
        let expectedGeneration = generation
        reseedRequestGenerations[gatewayID, default: 0] &+= 1
        let expectedReseedGeneration = reseedRequestGenerations[gatewayID, default: 0]
        suppressedGatewayIDs.remove(gatewayID)
        let targets = await operations.targets(model)
        guard !Task.isCancelled,
              generation == expectedGeneration,
              reseedRequestGenerations[gatewayID, default: 0]
                == expectedReseedGeneration,
              !suppressedGatewayIDs.contains(gatewayID) else { return }
        guard let target = targets.first(where: { $0.gatewayID == gatewayID }) else {
            return
        }
        enqueue(RoomProjectionSyncJob(reseedAfterAttempt: true),
                target: target, model: model)
    }

    func cancel(gatewayID: String) {
        suppressedGatewayIDs.insert(gatewayID)
        laneGenerations[gatewayID, default: 0] &+= 1
        reseedRequestGenerations[gatewayID, default: 0] &+= 1
        workers[gatewayID]?.task.cancel()
        retryTasks[gatewayID]?.task.cancel()
        workers[gatewayID] = nil
        retryTasks[gatewayID] = nil
        pendingByGateway[gatewayID] = nil
        targetsByGateway[gatewayID] = nil
        retryCounts[gatewayID] = nil
    }

    /// Delete Local Data must not let a delayed gateway read repopulate the
    /// newly erased RoomStore. Generation checks after every suspension make
    /// cancellation authoritative even if an RPC ignores task cancellation.
    func resetForPrivacyDeletion() {
        generation &+= 1
        debounceTask?.task.cancel()
        for slot in workers.values { slot.task.cancel() }
        for slot in retryTasks.values { slot.task.cancel() }
        debounceTask = nil
        debouncedJob = nil
        pendingByGateway.removeAll()
        targetsByGateway.removeAll()
        workers.removeAll()
        retryTasks.removeAll()
        retryCounts.removeAll()
        reseedRequestGenerations.removeAll()
        laneGenerations.removeAll()
        suppressedGatewayIDs.removeAll()
    }

    private func enqueue(_ job: RoomProjectionSyncJob,
                         target: RoomProjectionSyncTarget,
                         model: AppModel) {
        let gatewayID = target.gatewayID
        guard !gatewayID.isEmpty, !suppressedGatewayIDs.contains(gatewayID) else { return }
        targetsByGateway[gatewayID] = target
        pendingByGateway[gatewayID] = pendingByGateway[gatewayID]
            .map { $0.merging(job) } ?? job

        if let retry = retryTasks.removeValue(forKey: gatewayID) {
            retry.task.cancel()
        }
        startWorkerIfNeeded(gatewayID: gatewayID, model: model)
    }

    private func startWorkerIfNeeded(gatewayID: String, model: AppModel) {
        guard workers[gatewayID] == nil,
              retryTasks[gatewayID] == nil,
              pendingByGateway[gatewayID] != nil,
              targetsByGateway[gatewayID] != nil,
              !suppressedGatewayIDs.contains(gatewayID) else { return }

        let token = UUID()
        let expectedGeneration = generation
        let expectedLaneGeneration = laneGenerations[gatewayID, default: 0]
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runWorker(
                gatewayID: gatewayID,
                token: token,
                generation: expectedGeneration,
                laneGeneration: expectedLaneGeneration,
                model: model)
        }
        workers[gatewayID] = TaskSlot(token: token, task: task)
    }

    private func runWorker(gatewayID: String, token: UUID,
                           generation expectedGeneration: UInt64,
                           laneGeneration expectedLaneGeneration: UInt64,
                           model: AppModel) async {
        guard workerIsCurrent(gatewayID: gatewayID, token: token,
                              generation: expectedGeneration,
                              laneGeneration: expectedLaneGeneration),
              let job = pendingByGateway.removeValue(forKey: gatewayID),
              let target = targetsByGateway[gatewayID] else {
            finishStaleWorker(gatewayID: gatewayID, token: token)
            return
        }

        do {
            // Join the same admission domain as every protected room mutation.
            // Delete Local Data first closes admission and drains an active
            // projection transaction; its reset can then cancel queued lanes
            // without a suspended RoomStore reconcile running after erasure.
            try await RoomMutationGate.shared.withLock(
                "room-projection-sync:\(gatewayID)"
            ) {
                try await operations.withTargetLease(model, target) { leased in
                    try await self.perform(
                        job: job, leased: leased,
                        generation: expectedGeneration,
                        laneGeneration: expectedLaneGeneration,
                        workerToken: token)
                }
            }
            guard workerIsCurrent(gatewayID: gatewayID, token: token,
                                  generation: expectedGeneration,
                                  laneGeneration: expectedLaneGeneration) else { return }
            workers[gatewayID] = nil
            retryCounts[gatewayID] = nil
            if job.reseedAfterAttempt { schedule(model: model) }
            startWorkerIfNeeded(gatewayID: gatewayID, model: model)
        } catch {
            guard workerIsCurrent(gatewayID: gatewayID, token: token,
                                  generation: expectedGeneration,
                                  laneGeneration: expectedLaneGeneration),
                  !Task.isCancelled else { return }
            workers[gatewayID] = nil
            let retries = (retryCounts[gatewayID] ?? 0) + 1
            if retries > maximumRetries {
                retryCounts[gatewayID] = nil
                if job.reseedAfterAttempt { schedule(model: model) }
                // A newer job queued while this attempt was suspended remains
                // independent and must not be discarded with the capped one.
                startWorkerIfNeeded(gatewayID: gatewayID, model: model)
                return
            }
            retryCounts[gatewayID] = retries
            pendingByGateway[gatewayID] = pendingByGateway[gatewayID]
                .map { job.merging($0) } ?? job
            scheduleRetry(gatewayID: gatewayID, retry: retries,
                          generation: expectedGeneration,
                          laneGeneration: expectedLaneGeneration,
                          model: model)
        }
    }

    private func perform(job: RoomProjectionSyncJob,
                         leased: RoomProjectionLeasedTarget,
                         generation expectedGeneration: UInt64,
                         laneGeneration expectedLaneGeneration: UInt64,
                         workerToken: UUID) async throws {
        let target = leased.target
        let gatewayID = target.gatewayID
        let remote = try await operations.read(leased)
        try ensureWorkerCurrent(gatewayID: gatewayID, token: workerToken,
                                generation: expectedGeneration,
                                laneGeneration: expectedLaneGeneration)

        // This is an observation only when the namespaced block exists. An old
        // gateway's missing/truncated key must never be interpreted as empty.
        if let projection = remote.projection {
            let preserving = job.preservingKeys.union(
                newerPreservingKeys(gatewayID: gatewayID))
            try await operations.reconcile(projection, target, preserving)
            try ensureWorkerCurrent(gatewayID: gatewayID, token: workerToken,
                                    generation: expectedGeneration,
                                    laneGeneration: expectedLaneGeneration)
        }

        let now = operations.nowMilliseconds()
        let local = try await operations.localProjection(now)
        try ensureWorkerCurrent(gatewayID: gatewayID, token: workerToken,
                                generation: expectedGeneration,
                                laneGeneration: expectedLaneGeneration)
        // A fresh install with no local cache pulls, but does not publish an
        // empty value. Explicit final-room deletion opts in through allowEmpty.
        guard !local.rooms.isEmpty || !local.deleted.isEmpty || job.allowEmpty else {
            return
        }

        let (writeRevision, overflow) = remote.revision.addingReportingOverflow(1)
        guard !overflow, writeRevision >= 0,
              let roomWriteRevision = UInt64(exactly: writeRevision) else {
            throw RoomProjectionSyncFailure.revisionOverflow
        }
        let merged = RoomProjectionEnvelope.merging(
            remote: remote.projection,
            local: local,
            intent: RoomProjectionMergeIntent(
                changedRooms: job.changedRooms,
                deletedRooms: job.deletedRooms,
                writeRevision: roomWriteRevision),
            updatedAt: now)

        if !job.hasExplicitEdits,
           Self.payloadEqual(merged, remote.projection) {
            return
        }

        if remote.supportsCAS {
            let result = try await operations.writeCAS(
                leased, remote.profileName, merged, remote.revision)
            let expected = [RoomProjectionEnvelope.metadataKey: remote.revision]
            guard ProfileUIMetaCASPolicy.confirmsCommit(
                expectedRevisions: expected, result: result) else {
                throw RoomProjectionSyncFailure.rejectedCAS
            }
        } else {
            let applied = try await operations.writeLegacy(
                leased, remote.profileName, merged)
            let edit = ProfileEdit(uiMeta: merged.uiMetaPatch)
            guard edit.wasFullyApplied(applied) else {
                throw RoomProjectionSyncFailure.rejectedLegacy
            }
        }
        try ensureWorkerCurrent(gatewayID: gatewayID, token: workerToken,
                                generation: expectedGeneration,
                                laneGeneration: expectedLaneGeneration)

        // A configure acknowledgement is not the convergence boundary. Always
        // read the profile again and fold the authoritative result into local
        // storage, preserving edits that arrived while configure was suspended.
        let confirmed = try await operations.read(leased)
        try ensureWorkerCurrent(gatewayID: gatewayID, token: workerToken,
                                generation: expectedGeneration,
                                laneGeneration: expectedLaneGeneration)
        guard let confirmedProjection = confirmed.projection else {
            throw RoomProjectionSyncFailure.missingReadback
        }
        if remote.supportsCAS {
            guard confirmed.supportsCAS, confirmed.revision >= writeRevision else {
                throw RoomProjectionSyncFailure.staleReadback
            }
        }
        try await operations.reconcile(
            confirmedProjection, target,
            newerPreservingKeys(gatewayID: gatewayID))
        try ensureWorkerCurrent(gatewayID: gatewayID, token: workerToken,
                                generation: expectedGeneration,
                                laneGeneration: expectedLaneGeneration)
    }

    private func scheduleRetry(gatewayID: String, retry: Int,
                               generation expectedGeneration: UInt64,
                               laneGeneration expectedLaneGeneration: UInt64,
                               model: AppModel) {
        let token = UUID()
        let delay = retryDelays[min(max(0, retry - 1), retryDelays.count - 1)]
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.operations.sleep(delay) }
            catch {
                if self.retryTasks[gatewayID]?.token == token {
                    self.retryTasks[gatewayID] = nil
                }
                return
            }
            guard !Task.isCancelled,
                  self.generation == expectedGeneration,
                  self.laneGenerations[gatewayID, default: 0]
                    == expectedLaneGeneration,
                  self.retryTasks[gatewayID]?.token == token else { return }
            self.retryTasks[gatewayID] = nil
            self.startWorkerIfNeeded(gatewayID: gatewayID, model: model)
        }
        retryTasks[gatewayID] = TaskSlot(token: token, task: task)
    }

    private func newerPreservingKeys(gatewayID: String) -> Set<String> {
        var keys = pendingByGateway[gatewayID]?.preservingKeys ?? []
        if let debouncedJob { keys.formUnion(debouncedJob.preservingKeys) }
        return keys
    }

    private func workerIsCurrent(gatewayID: String, token: UUID,
                                 generation expectedGeneration: UInt64,
                                 laneGeneration expectedLaneGeneration: UInt64) -> Bool {
        generation == expectedGeneration
            && laneGenerations[gatewayID, default: 0] == expectedLaneGeneration
            && workers[gatewayID]?.token == token
            && !suppressedGatewayIDs.contains(gatewayID)
    }

    private func ensureWorkerCurrent(gatewayID: String, token: UUID,
                                     generation expectedGeneration: UInt64,
                                     laneGeneration expectedLaneGeneration: UInt64) throws {
        guard !Task.isCancelled,
              workerIsCurrent(gatewayID: gatewayID, token: token,
                              generation: expectedGeneration,
                              laneGeneration: expectedLaneGeneration) else {
            throw CancellationError()
        }
    }

    private func finishStaleWorker(gatewayID: String, token: UUID) {
        if workers[gatewayID]?.token == token { workers[gatewayID] = nil }
    }

    static func payloadEqual(_ left: RoomProjectionEnvelope,
                             _ right: RoomProjectionEnvelope?) -> Bool {
        let right = right ?? RoomProjectionEnvelope()
        return left.rooms == right.rooms && left.deleted == right.deleted
    }

    // MARK: - Production storage adapter

    fileprivate static func productionLocalProjection(updatedAt: UInt64) async throws
        -> RoomProjectionEnvelope {
        let store = RoomRuntime.shared.store
        let records = try await store.loadAll()
        let ledger = try await store.roomProjection()
        var images: [RoomID: String] = [:]
        for room in records {
            guard let avatar = room.avatar,
                  avatar.mediaType.lowercased().hasPrefix("image/"),
                  let data = try? await store.readBlob(roomID: room.id,
                                                       attachment: avatar) else { continue }
            images[room.id] = "data:\(avatar.mediaType);base64,"
                + data.base64EncodedString()
        }
        let projected = RoomProjectionEnvelope.projecting(
            records,
            revisions: Dictionary(uniqueKeysWithValues: records.map {
                ($0.id, $0.rawProjectionRevision)
            }),
            images: images,
            updatedAt: updatedAt)
        return RoomProjectionEnvelope.merging(
            remote: ledger, local: projected, updatedAt: updatedAt)
    }

    fileprivate static func productionReconcile(
        _ incoming: RoomProjectionEnvelope,
        preservingKeys: Set<String>
    ) async throws {
        let runtime = RoomRuntime.shared
        let store = runtime.store
        let ledger = try await store.roomProjection()
        let registry = ConnectionRegistry.shared
        let allowedGatewayIDs: Set<String> = Set(registry.saved.compactMap { gateway in
            guard gateway.baseURL != nil,
                  registry.credential(for: gateway) != nil else { return nil }
            return gateway.id
        })
        var preservingRoomIDs = Set<RoomID>()
        for key in preservingKeys {
            if let roomID = RoomProjectionEnvelope.localRoomID(forProjectionKey: key) {
                preservingRoomIDs.insert(roomID)
            }
            for (projectionKey, room) in ledger.rooms
            where projectionKey == key || room.name == key
                    || projectionKey == RoomProjectionEnvelope.legacyNameKey(key) {
                if let roomID = RoomProjectionEnvelope.localRoomID(
                    forProjectionKey: projectionKey) {
                    preservingRoomIDs.insert(roomID)
                }
            }
            preservingRoomIDs.formUnion(
                runtime.rooms.filter {
                    $0.name == key || $0.rawProjectionRoomKey == key
                        || RoomProjectionEnvelope.idKey($0.id.description) == key
                }.map(\.id))
        }

        let result = try await store.reconcileRoomProjection(
            incoming, preservingRoomIDs: preservingRoomIDs,
            allowedGatewayIDs: allowedGatewayIDs)
        runtime.retainComposerDrafts(for: Set(result.rooms.map(\.id)))
        runtime.rooms = result.rooms.sorted {
            if $0.lastActivityAt != $1.lastActivityAt {
                return $0.lastActivityAt > $1.lastActivityAt
            }
            return $0.id.description < $1.id.description
        }
        let retainedAvatarIDs = Set(result.rooms.compactMap {
            $0.avatar == nil ? nil : $0.id
        })
        runtime.avatarData = runtime.avatarData.filter {
            retainedAvatarIDs.contains($0.key)
        }
        for roomID in result.clearedImageRoomIDs {
            runtime.avatarData[roomID] = nil
        }
        for (roomID, data) in result.projectedImages {
            runtime.avatarData[roomID] = data
        }
    }
}

extension AppModel {
    /// Queue a bounded room projection update for every reachable configured
    /// gateway that still has a credential. Durable id keys are preferred over
    /// display names; disconnected lanes resume from reconnect reseeding.
    func scheduleRoomProjectionSync(allowEmpty: Bool = false,
                                    changedRooms: [String] = [],
                                    deletedRooms: [String] = []) {
        RoomProjectionRuntime.shared.schedule(
            model: self, allowEmpty: allowEmpty,
            changedRooms: changedRooms, deletedRooms: deletedRooms)
    }

    /// Gateway adoption/reconnect hook: receive from this source immediately,
    /// then reseed all reachable credentialed gateways after coalescing.
    func pullAndReseedRoomProjection(gatewayID: String) async {
        await RoomProjectionRuntime.shared.pullAndReseed(
            model: self, gatewayID: gatewayID)
    }

    /// Explicit sign-out/removal hook. Other gateways keep draining.
    func cancelRoomProjectionSync(gatewayID: String) {
        RoomProjectionRuntime.shared.cancel(gatewayID: gatewayID)
    }

    /// Call before deleting protected room data so no suspended observation can
    /// hydrate it again after the deletion boundary.
    func resetRoomProjectionSyncForPrivacyDeletion() {
        RoomProjectionRuntime.shared.resetForPrivacyDeletion()
    }
}
