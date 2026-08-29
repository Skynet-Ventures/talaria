import Foundation
import TalariaKit

/// The durable identity of locally queued composer text. Runtime session IDs
/// are intentionally excluded: Hermes may rotate them during reconnect.
public struct DurableComposerQueueKey: Codable, Hashable, Sendable, Equatable {
    public var gatewayID: String
    public var profile: String
    public var storedSessionID: String

    public init(gatewayID: String, profile: String, storedSessionID: String) {
        self.gatewayID = gatewayID
        self.profile = profile
        self.storedSessionID = storedSessionID
    }

    public init(route: GatewayBotRoute, storedSessionID: String) {
        self.init(gatewayID: route.gatewayID, profile: route.profile,
                  storedSessionID: storedSessionID)
    }

    public var route: GatewayBotRoute {
        GatewayBotRoute(gatewayID: gatewayID, profile: profile)
    }

    public var qualifiedID: String {
        gatewayID + "::" + profile + "::" + storedSessionID
    }

    public var isValid: Bool {
        !gatewayID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !storedSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Gateway-owned and uncertain rows are deliberately distinct from local work:
/// neither is ever sent again automatically.
public enum DurableComposerQueueState: String, Codable, Sendable, Equatable,
    CaseIterable, Identifiable {
    case localReady = "local/ready"
    case parked
    case submitting
    case acceptedGatewayOwned = "accepted/gateway-owned"
    case uncertain
    case retryExhausted = "retry-exhausted"

    public var id: String { rawValue }

    public var isLocalReplayable: Bool {
        // The name is retained for source compatibility with the first queue
        // cut, but this is specifically *automatic* replayability. A
        // retry-exhausted row is still locally editable and explicitly
        // resumable; it must never be claimed by reconnect/flush work until
        // that explicit action moves it back to localReady.
        self == .localReady
    }

    /// Automatic reconnect/foreground draining may claim only this state.
    /// Keeping the narrower name at call sites prevents retry-exhausted from
    /// being mistaken for a transient delivery failure.
    public var isAutomaticallyReplayable: Bool {
        self == .localReady
    }

    /// A queue editor may only alter text still owned by this device.
    public var isLocallyEditable: Bool {
        switch self {
        case .localReady, .parked, .retryExhausted: true
        case .submitting, .acceptedGatewayOwned, .uncertain: false
        }
    }

    public var isTerminalLocalState: Bool {
        switch self {
        case .uncertain, .acceptedGatewayOwned: true
        case .localReady, .parked, .submitting, .retryExhausted: false
        }
    }
}

/// A bounded text-only entry. Attachments are intentionally absent because
/// Hermes attachment state is session-global and cannot be safely replayed.
public struct DurableComposerQueueEntry: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var key: DurableComposerQueueKey
    public var text: String
    public var state: DurableComposerQueueState
    public var createdAt: Date
    public var updatedAt: Date
    public var automaticFailures: Int
    public var lastError: String?
    /// Monotonic, per-store FIFO order. It is not wall-clock time.
    public var order: UInt64

    public init(id: UUID = UUID(), key: DurableComposerQueueKey, text: String,
                state: DurableComposerQueueState = .localReady,
                createdAt: Date = Date(), updatedAt: Date = Date(),
                automaticFailures: Int = 0, lastError: String? = nil,
                order: UInt64 = 0) {
        self.id = id
        self.key = key
        self.text = text
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.automaticFailures = automaticFailures
        self.lastError = lastError
        self.order = order
    }
}

public enum DurableComposerQueueStoreError: Error, Sendable, Equatable,
    CustomStringConvertible, LocalizedError {
    case invalidSessionKey
    case emptyText
    case textTooLong(maximum: Int)
    case entryLimitReached(maximum: Int)
    case totalTextLimitReached(maximum: Int)
    case entryNotFound
    case invalidTransition(from: DurableComposerQueueState, to: DurableComposerQueueState)
    case protectedEntry(state: DurableComposerQueueState)
    case attachmentRefused
    case unavailableAfterReadFailure
    case identityCollision
    case persistedBytesLimitReached(maximum: Int)

    public var description: String {
        switch self {
        case .invalidSessionKey:
            "A durable gateway, profile, and stored session are required."
        case .emptyText:
            "A queued prompt needs text."
        case .textTooLong(let maximum):
            "Queued prompt text is limited to \(maximum) characters."
        case .entryLimitReached(let maximum):
            "The local prompt queue is full (\(maximum) entries)."
        case .totalTextLimitReached(let maximum):
            "The local prompt queue is full (\(maximum) text characters)."
        case .entryNotFound:
            "That queued prompt no longer exists."
        case .invalidTransition(let from, let to):
            "Queued prompt cannot move from \(from.rawValue) to \(to.rawValue)."
        case .protectedEntry(let state):
            "A \(state.rawValue) queued prompt needs its explicit resolution action."
        case .attachmentRefused:
            "Attachments cannot be queued safely; send them while this session is connected."
        case .unavailableAfterReadFailure:
            "The saved prompt queue is temporarily unavailable and was left unchanged."
        case .identityCollision:
            "That queued prompt identity already belongs to different work."
        case .persistedBytesLimitReached(let maximum):
            "The saved prompt queue exceeds its \(maximum)-byte storage limit."
        }
    }

    public var errorDescription: String? { description }
}

public enum DurableComposerQueuePolicy {
    public static let schemaVersion = 1
    public static let maxEntries = 100
    public static let maxTextLength = 8_000
    public static let maxTotalTextLength = 80_000
    public static let maxPersistedBytes = 2_000_000
    public static let maxAutomaticFailures = 4
    public static let maxConcurrentSessions = 2

    public static func validate(text: String, attachments: Int = 0) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DurableComposerQueueStoreError.emptyText }
        guard trimmed.count <= maxTextLength else {
            throw DurableComposerQueueStoreError.textTooLong(maximum: maxTextLength)
        }
        guard attachments == 0 else {
            throw DurableComposerQueueStoreError.attachmentRefused
        }
    }

    public static func shouldAutoDrain(state: DurableComposerQueueState,
                                       isTurnRunning: Bool) -> Bool {
        state == .localReady && !isTurnRunning
    }

    /// Return the one local row eligible to cross a source session's FIFO
    /// boundary. Accepted mirrors have already crossed it; every other
    /// non-ready state, including an exact editor reservation, blocks later
    /// rows rather than allowing text to leapfrog the user's revision.
    public static func nextFIFOEntry(
        _ rows: [DurableComposerQueueEntry],
        reservedIDs: Set<UUID> = []
    ) -> DurableComposerQueueEntry? {
        for row in rows.sorted(by: { $0.order < $1.order }) {
            switch row.state {
            case .acceptedGatewayOwned:
                continue
            case .localReady:
                return reservedIDs.contains(row.id) ? nil : row
            case .parked, .submitting, .uncertain, .retryExhausted:
                return nil
            }
        }
        return nil
    }
}

/// Small pure decisions used by the phone-first queue controls.
public enum DurableComposerQueuePresentationPolicy {
    public enum StripMode: Equatable, Sendable {
        case hidden
        case singleRow
        case compactSummary
    }

    public enum QueueAction: Equatable, Sendable {
        case hidden
        case available
        case attachmentExplanation
    }

    public static func stripMode(entryCount: Int,
                                 isAccessibilitySize: Bool = false) -> StripMode {
        guard entryCount > 0 else { return .hidden }
        if isAccessibilitySize { return .compactSummary }
        return entryCount == 1 ? .singleRow : .compactSummary
    }

    public static func usesStackedActions(inPanel: Bool,
                                          isAccessibilitySize: Bool) -> Bool {
        inPanel && isAccessibilitySize
    }

    public static func queueAction(isLive: Bool, isTurnRunning: Bool,
                                   hasAttachments: Bool, hasText: Bool,
                                   isBranching: Bool = false) -> QueueAction {
        guard isLive, isTurnRunning, !isBranching else { return .hidden }
        if hasAttachments { return .attachmentExplanation }
        return hasText ? .available : .hidden
    }
}

/// Serializes a source session while allowing a small number of unrelated
/// source sessions to drain concurrently.
public actor DurableComposerQueueDrainLimiter {
    public static let shared = DurableComposerQueueDrainLimiter()

    private var active: Set<DurableComposerQueueKey> = []
    private struct Waiter {
        let id: UUID
        let key: DurableComposerQueueKey
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var waiters: [Waiter] = []

    public init() {}

    public func withLane<T: Sendable>(
        for key: DurableComposerQueueKey,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        try await acquire(key)
        defer { release(key) }
        try Task.checkCancellation()
        return try await operation()
    }

    public func activeSessionCount() -> Int { active.count }
    public func waitingCount() -> Int { waiters.count }

    private func acquire(_ key: DurableComposerQueueKey) async throws {
        guard !active.contains(key), active.count < DurableComposerQueuePolicy.maxConcurrentSessions else {
            let waiterID = UUID()
            let granted = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume(returning: false)
                    } else if !active.contains(key),
                              active.count < DurableComposerQueuePolicy.maxConcurrentSessions {
                        active.insert(key)
                        continuation.resume(returning: true)
                    } else {
                        waiters.append(Waiter(id: waiterID, key: key, continuation: continuation))
                    }
                }
            } onCancel: {
                Task { await self.cancel(waiterID: waiterID) }
            }
            guard granted else { throw CancellationError() }
            return
        }
        active.insert(key)
    }

    private func release(_ key: DurableComposerQueueKey) {
        active.remove(key)
        grantAvailableLanes()
    }

    private func grantAvailableLanes() {
        while active.count < DurableComposerQueuePolicy.maxConcurrentSessions {
            guard let index = waiters.firstIndex(where: { !active.contains($0.key) }) else { return }
            let waiter = waiters.remove(at: index)
            active.insert(waiter.key)
            waiter.continuation.resume(returning: true)
        }
    }

    private func cancel(waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
        grantAvailableLanes()
    }
}

/// Atomically persisted, source-qualified, text-only queue.
@MainActor
public final class DurableComposerQueueStore {
    public static let shared = DurableComposerQueueStore()

    public let fileURL: URL
    private let fileManager: FileManager
    private var entries: [DurableComposerQueueEntry]
    public private(set) var loadedCorruptData = false
    public private(set) var loadedReadFailure = false
    public private(set) var loadFailureDescription: String?
    private var nextOrder: UInt64
    /// Test seams; production always writes an atomically replaced envelope.
    var persistOverrideForTesting: (() throws -> Void)?
    var protectionAssertionForTesting: (() throws -> Void)?

    private struct Snapshot: Codable {
        var schemaVersion: Int
        var nextOrder: UInt64
        var entries: [DurableComposerQueueEntry]
    }

    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultURL(fileManager: fileManager)
        let result = Self.read(from: self.fileURL, fileManager: fileManager)
        entries = result.entries
        loadedCorruptData = result.corrupt
        loadedReadFailure = result.readFailure != nil
        loadFailureDescription = result.readFailure
        nextOrder = max(result.nextOrder, result.entries.map(\.order).max() ?? 0)
        if result.normalized {
            do {
                try persist()
            } catch {
                // The memory projection is already fail-closed. Preserve the
                // original envelope rather than pretending normalisation stuck.
                loadedCorruptData = true
            }
        }
    }

    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory,
                                    in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("Talaria", isDirectory: true)
            .appendingPathComponent("composer-queue-v1.json")
    }

    public func allEntries() -> [DurableComposerQueueEntry] {
        entries.sorted { $0.order < $1.order }
    }

    public func entries(for key: DurableComposerQueueKey) -> [DurableComposerQueueEntry] {
        allEntries().filter { $0.key == key }
    }

    public func entry(id: UUID) -> DurableComposerQueueEntry? {
        entries.first { $0.id == id }
    }

    @discardableResult
    public func enqueue(key: DurableComposerQueueKey, text: String,
                        id: UUID = UUID(), state: DurableComposerQueueState = .localReady,
                        now: Date = Date()) throws -> DurableComposerQueueEntry {
        guard key.isValid else { throw DurableComposerQueueStoreError.invalidSessionKey }
        try DurableComposerQueuePolicy.validate(text: text)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = entries.first(where: { $0.id == id }) {
            guard existing.key == key, existing.text == trimmed, existing.state == state else {
                throw DurableComposerQueueStoreError.identityCollision
            }
            return existing
        }
        guard entries.count < DurableComposerQueuePolicy.maxEntries else {
            throw DurableComposerQueueStoreError.entryLimitReached(
                maximum: DurableComposerQueuePolicy.maxEntries)
        }
        let total = entries.reduce(0) { $0 + $1.text.count }
        guard total + trimmed.count <= DurableComposerQueuePolicy.maxTotalTextLength else {
            throw DurableComposerQueueStoreError.totalTextLimitReached(
                maximum: DurableComposerQueuePolicy.maxTotalTextLength)
        }
        return try mutateAndPersist {
            nextOrder &+= 1
            let entry = DurableComposerQueueEntry(id: id, key: key, text: trimmed,
                                                  state: state, createdAt: now,
                                                  updatedAt: now, order: nextOrder)
            entries.append(entry)
            return entry
        }
    }

    @discardableResult
    public func enqueue(key: DurableComposerQueueKey, text: String, attachments: Int,
                        id: UUID = UUID(), now: Date = Date()) throws -> DurableComposerQueueEntry {
        guard key.isValid else { throw DurableComposerQueueStoreError.invalidSessionKey }
        try DurableComposerQueuePolicy.validate(text: text, attachments: attachments)
        return try enqueue(key: key, text: text, id: id, now: now)
    }

    /// Replace text only while this device remains the owner. Key, identity,
    /// FIFO order, and original creation time are immutable. A revised
    /// retry-exhausted row becomes a fresh local attempt; a parked row stays
    /// parked and therefore cannot accidentally resume because it was edited.
    @discardableResult
    public func replaceLocalText(id: UUID, text: String,
                                 now: Date = Date()) throws -> DurableComposerQueueEntry {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw DurableComposerQueueStoreError.entryNotFound
        }
        let prior = entries[index]
        guard prior.state.isLocallyEditable else {
            throw DurableComposerQueueStoreError.protectedEntry(state: prior.state)
        }
        try DurableComposerQueuePolicy.validate(text: text)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let totalWithoutPrior = entries.reduce(0) { $0 + $1.text.count } - prior.text.count
        guard totalWithoutPrior + trimmed.count <= DurableComposerQueuePolicy.maxTotalTextLength else {
            throw DurableComposerQueueStoreError.totalTextLimitReached(
                maximum: DurableComposerQueuePolicy.maxTotalTextLength)
        }
        return try mutateAndPersist {
            entries[index].text = trimmed
            entries[index].updatedAt = now
            if entries[index].state == .retryExhausted {
                entries[index].state = .localReady
                entries[index].automaticFailures = 0
                entries[index].lastError = nil
            }
            return entries[index]
        }
    }

    @discardableResult
    public func setState(id: UUID, state: DurableComposerQueueState,
                         error: String? = nil, now: Date = Date()) throws -> DurableComposerQueueEntry {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw DurableComposerQueueStoreError.entryNotFound
        }
        let old = entries[index].state
        guard Self.isAllowedTransition(from: old, to: state) else {
            throw DurableComposerQueueStoreError.invalidTransition(from: old, to: state)
        }
        return try mutateAndPersist {
            entries[index].state = state
            entries[index].updatedAt = now
            entries[index].lastError = error
            return entries[index]
        }
    }

    public func markSubmitting(id: UUID, now: Date = Date()) throws {
        _ = try setState(id: id, state: .submitting, now: now)
    }

    public func markAcceptedGatewayOwned(id: UUID, now: Date = Date()) throws {
        _ = try setState(id: id, state: .acceptedGatewayOwned, now: now)
    }

    public func markUncertain(id: UUID, error: String? = nil, now: Date = Date()) throws {
        _ = try setState(id: id, state: .uncertain, error: error, now: now)
    }

    public func markLocalReady(id: UUID, error: String? = nil, now: Date = Date()) throws {
        _ = try setState(id: id, state: .localReady, error: error, now: now)
    }

    @discardableResult
    public func recordAutomaticFailure(id: UUID, error: String? = nil,
                                       now: Date = Date()) throws -> DurableComposerQueueEntry {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw DurableComposerQueueStoreError.entryNotFound
        }
        guard entries[index].state == .localReady else {
            throw DurableComposerQueueStoreError.invalidTransition(
                from: entries[index].state, to: .localReady)
        }
        return try mutateAndPersist {
            entries[index].automaticFailures = min(
                DurableComposerQueuePolicy.maxAutomaticFailures,
                entries[index].automaticFailures + 1)
            entries[index].lastError = error
            entries[index].updatedAt = now
            entries[index].state = entries[index].automaticFailures >= DurableComposerQueuePolicy.maxAutomaticFailures
                ? .retryExhausted : .localReady
            return entries[index]
        }
    }

    public func resetAutomaticFailures(id: UUID, now: Date = Date()) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw DurableComposerQueueStoreError.entryNotFound
        }
        try mutateAndPersist {
            entries[index].automaticFailures = 0
            entries[index].lastError = nil
            entries[index].updatedAt = now
            if entries[index].state == .retryExhausted { entries[index].state = .localReady }
        }
    }

    /// Stop uses this before it starts an interrupt. In-flight and gateway-owned
    /// rows remain as-is because client code cannot prove they were cancelled.
    public func park(key: DurableComposerQueueKey, now: Date = Date()) throws {
        try mutateAndPersist {
            for index in entries.indices where entries[index].key == key {
                switch entries[index].state {
                case .localReady, .retryExhausted:
                    entries[index].state = .parked
                    entries[index].updatedAt = now
                case .parked, .submitting, .acceptedGatewayOwned, .uncertain:
                    break
                }
            }
        }
    }

    public func park(route: GatewayBotRoute, now: Date = Date()) throws {
        try mutateAndPersist {
            for index in entries.indices where entries[index].key.route == route {
                switch entries[index].state {
                case .localReady, .retryExhausted:
                    entries[index].state = .parked
                    entries[index].updatedAt = now
                case .parked, .submitting, .acceptedGatewayOwned, .uncertain:
                    break
                }
            }
        }
    }

    public func resume(key: DurableComposerQueueKey, now: Date = Date()) throws {
        try mutateAndPersist {
            for index in entries.indices where entries[index].key == key {
                resumeEntry(at: index, now: now)
            }
        }
    }

    public func resume(route: GatewayBotRoute, now: Date = Date()) throws {
        try mutateAndPersist {
            for index in entries.indices where entries[index].key.route == route {
                resumeEntry(at: index, now: now)
            }
        }
    }

    private func resumeEntry(at index: Int, now: Date) {
        switch entries[index].state {
        case .parked, .retryExhausted:
            entries[index].state = .localReady
            entries[index].automaticFailures = 0
            entries[index].lastError = nil
            entries[index].updatedAt = now
        case .localReady, .submitting, .acceptedGatewayOwned, .uncertain:
            break
        }
    }

    public func removeUncertain(id: UUID) throws {
        guard entries.contains(where: { $0.id == id && $0.state == .uncertain }) else { return }
        try mutateAndPersist { entries.removeAll { $0.id == id } }
    }

    public func remove(id: UUID) throws {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        guard entry.state.isLocallyEditable else {
            throw DurableComposerQueueStoreError.protectedEntry(state: entry.state)
        }
        try mutateAndPersist { entries.removeAll { $0.id == id } }
    }

    public func removeLocal(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        let targets = entries.filter { ids.contains($0.id) }
        guard targets.count == ids.count else { throw DurableComposerQueueStoreError.entryNotFound }
        guard targets.allSatisfy({ $0.state.isLocallyEditable }) else {
            let state = targets.first(where: { !$0.state.isLocallyEditable })?.state ?? .uncertain
            throw DurableComposerQueueStoreError.protectedEntry(state: state)
        }
        try mutateAndPersist { entries.removeAll { ids.contains($0.id) } }
    }

    @discardableResult
    public func removeAcceptedForExecution(id: UUID) throws -> DurableComposerQueueEntry? {
        guard let index = entries.firstIndex(where: {
            $0.id == id && $0.state == .acceptedGatewayOwned
        }) else { return nil }
        return try mutateAndPersist { entries.remove(at: index) }
    }

    public func removeAcceptedForExecution(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        let targets = entries.filter { ids.contains($0.id) }
        guard targets.count == ids.count else { throw DurableComposerQueueStoreError.entryNotFound }
        guard targets.allSatisfy({ $0.state == .acceptedGatewayOwned }) else {
            let state = targets.first(where: { $0.state != .acceptedGatewayOwned })?.state ?? .uncertain
            throw DurableComposerQueueStoreError.protectedEntry(state: state)
        }
        try mutateAndPersist { entries.removeAll { ids.contains($0.id) } }
    }

    /// A matching message.start is execution proof even when it races ahead
    /// of the prompt.submit receipt. Only the exact pre-wire submitting row
    /// may be retired through this door.
    public func removeSubmittingForExecution(id: UUID) throws {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        guard entry.state == .submitting else {
            throw DurableComposerQueueStoreError.protectedEntry(state: entry.state)
        }
        try mutateAndPersist { entries.removeAll { $0.id == id } }
    }

    public func removeForExecution(localIDs: Set<UUID>, acceptedIDs: Set<UUID>) throws {
        let ids = localIDs.union(acceptedIDs)
        guard !ids.isEmpty else { return }
        let targets = entries.filter { ids.contains($0.id) }
        guard targets.count == ids.count else { throw DurableComposerQueueStoreError.entryNotFound }
        guard targets.allSatisfy({ entry in
            localIDs.contains(entry.id)
                ? entry.state.isLocallyEditable
                : acceptedIDs.contains(entry.id) && entry.state == .acceptedGatewayOwned
        }) else {
            let state = targets.first(where: { entry in
                localIDs.contains(entry.id)
                    ? !entry.state.isLocallyEditable
                    : entry.state != .acceptedGatewayOwned
            })?.state ?? .uncertain
            throw DurableComposerQueueStoreError.protectedEntry(state: state)
        }
        try mutateAndPersist { entries.removeAll { ids.contains($0.id) } }
    }

    /// Re-key only a changed durable identity, never an ephemeral runtime sid.
    public func migrateStoredSession(route: GatewayBotRoute, fromStoredID: String,
                                     toStoredID: String, now: Date = Date()) throws {
        guard !fromStoredID.isEmpty, !toStoredID.isEmpty, fromStoredID != toStoredID else { return }
        let old = DurableComposerQueueKey(route: route, storedSessionID: fromStoredID)
        let new = DurableComposerQueueKey(route: route, storedSessionID: toStoredID)
        try mutateAndPersist {
            for index in entries.indices where entries[index].key == old {
                entries[index].key = new
                entries[index].updatedAt = now
            }
        }
    }

    public func migrateRoute(from: GatewayBotRoute, to: GatewayBotRoute,
                             storedID: String? = nil, now: Date = Date()) throws {
        try mutateAndPersist {
            for index in entries.indices {
                let key = entries[index].key
                guard key.gatewayID == from.gatewayID, key.profile == from.profile,
                      storedID == nil || key.storedSessionID == storedID else { continue }
                entries[index].key = DurableComposerQueueKey(
                    route: to, storedSessionID: key.storedSessionID)
                entries[index].updatedAt = now
            }
        }
    }

    /// Rename migration and replay resumption are one persisted transaction.
    /// A failed write leaves the original route parked in both memory and the
    /// durable envelope; no intermediate destination can escape to disk.
    public func migrateRouteAndResume(
        from: GatewayBotRoute, to: GatewayBotRoute,
        storedID: String? = nil, now: Date = Date()
    ) throws {
        try mutateAndPersist {
            for index in entries.indices {
                let key = entries[index].key
                guard key.gatewayID == from.gatewayID,
                      key.profile == from.profile,
                      storedID == nil || key.storedSessionID == storedID else { continue }
                entries[index].key = DurableComposerQueueKey(
                    route: to, storedSessionID: key.storedSessionID)
                resumeEntry(at: index, now: now)
                entries[index].updatedAt = now
            }
        }
    }

    public func remove(route: GatewayBotRoute, storedID: String? = nil) throws {
        try mutateAndPersist {
            entries.removeAll {
                $0.key.gatewayID == route.gatewayID && $0.key.profile == route.profile
                    && (storedID == nil || $0.key.storedSessionID == storedID)
            }
        }
    }

    public func remove(gatewayID: String) throws {
        try mutateAndPersist { entries.removeAll { $0.key.gatewayID == gatewayID } }
    }

    public func quarantine(route: GatewayBotRoute, storedID: String? = nil,
                           reason: String, now: Date = Date()) throws {
        try mutateAndPersist {
            for index in entries.indices {
                let entry = entries[index]
                guard entry.key.route == route,
                      storedID == nil || entry.key.storedSessionID == storedID,
                      entry.state != .uncertain else { continue }
                entries[index].state = .uncertain
                entries[index].lastError = reason
                entries[index].updatedAt = now
            }
        }
    }

    public func quarantine(gatewayID: String, reason: String,
                           now: Date = Date()) throws {
        try mutateAndPersist {
            for index in entries.indices where entries[index].key.gatewayID == gatewayID {
                guard entries[index].state != .uncertain else { continue }
                entries[index].state = .uncertain
                entries[index].lastError = reason
                entries[index].updatedAt = now
            }
        }
    }

    public func clearCorruptData() throws {
        guard !loadedReadFailure else {
            throw DurableComposerQueueStoreError.unavailableAfterReadFailure
        }
        let oldEntries = entries
        let oldNextOrder = nextOrder
        let oldCorrupt = loadedCorruptData
        let oldReadFailure = loadedReadFailure
        let oldDescription = loadFailureDescription
        entries = []
        nextOrder = 0
        loadedCorruptData = false
        loadedReadFailure = false
        loadFailureDescription = nil
        do {
            try persist()
        } catch {
            entries = oldEntries
            nextOrder = oldNextOrder
            loadedCorruptData = oldCorrupt
            loadedReadFailure = oldReadFailure
            loadFailureDescription = oldDescription
            throw error
        }
    }

    private static func isAllowedTransition(from: DurableComposerQueueState,
                                            to: DurableComposerQueueState) -> Bool {
        if from == to { return true }
        return switch (from, to) {
        case (.localReady, .submitting), (.localReady, .parked),
             (.localReady, .uncertain), (.localReady, .retryExhausted),
             (.localReady, .acceptedGatewayOwned), (.submitting, .acceptedGatewayOwned),
             (.submitting, .localReady), (.submitting, .uncertain),
             (.parked, .localReady), (.parked, .uncertain),
             (.retryExhausted, .localReady), (.retryExhausted, .parked),
             (.acceptedGatewayOwned, .uncertain):
            true
        case (.uncertain, _), (.acceptedGatewayOwned, _),
             (.parked, .submitting), (.parked, .acceptedGatewayOwned):
            false
        default:
            false
        }
    }

    private func persist() throws {
        if let persistOverrideForTesting {
            try persistOverrideForTesting()
            return
        }
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = Snapshot(schemaVersion: DurableComposerQueuePolicy.schemaVersion,
                                nextOrder: nextOrder,
                                entries: entries.sorted { $0.order < $1.order })
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= DurableComposerQueuePolicy.maxPersistedBytes else {
            throw DurableComposerQueueStoreError.persistedBytesLimitReached(
                maximum: DurableComposerQueuePolicy.maxPersistedBytes)
        }
        let temporaryURL = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        try data.write(to: temporaryURL, options: options)
        #if os(iOS)
        let protection: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ]
        try fileManager.setAttributes(protection, ofItemAtPath: directory.path)
        try fileManager.setAttributes(protection, ofItemAtPath: temporaryURL.path)
        #endif
        try protectionAssertionForTesting?()
        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        }
        // The temporary file receives its protection class before the atomic
        // replacement. Do not try to clean up the destination after that
        // replacement: if a platform reports a protection-attribute failure,
        // deleting the destination would destroy both the previous snapshot
        // and the newly committed one. A failed pre-replacement protection
        // assertion leaves the old file untouched and mutateAndPersist rolls
        // the in-memory projection back, so the next launch can recover.
    }

    @discardableResult
    private func mutateAndPersist<T>(_ mutation: () throws -> T) throws -> T {
        guard !loadedReadFailure else {
            throw DurableComposerQueueStoreError.unavailableAfterReadFailure
        }
        let oldEntries = entries
        let oldNextOrder = nextOrder
        do {
            let result = try mutation()
            try persist()
            return result
        } catch {
            entries = oldEntries
            nextOrder = oldNextOrder
            throw error
        }
    }

    private static func read(from url: URL, fileManager: FileManager)
        -> (entries: [DurableComposerQueueEntry], nextOrder: UInt64,
            corrupt: Bool, normalized: Bool, readFailure: String?) {
        guard fileManager.fileExists(atPath: url.path) else { return ([], 0, false, false, nil) }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            return ([], 0, false, false, error.localizedDescription)
        }
        guard let byteCount = (attributes[.size] as? NSNumber)?.intValue, byteCount >= 0 else {
            return ([], 0, false, false, "The durable queue file size could not be read safely.")
        }
        guard byteCount <= DurableComposerQueuePolicy.maxPersistedBytes else {
            try? fileManager.removeItem(at: url)
            return ([], 0, true, false, nil)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return ([], 0, false, false, error.localizedDescription)
        }
        let snapshot: Snapshot
        do {
            snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            try? fileManager.removeItem(at: url)
            return ([], 0, true, false, nil)
        }
        let uniqueIDs = Set(snapshot.entries.map(\.id))
        let uniqueOrders = Set(snapshot.entries.map(\.order))
        guard snapshot.schemaVersion == DurableComposerQueuePolicy.schemaVersion,
              snapshot.entries.count <= DurableComposerQueuePolicy.maxEntries,
              uniqueIDs.count == snapshot.entries.count,
              uniqueOrders.count == snapshot.entries.count,
              snapshot.entries.allSatisfy({ $0.key.isValid
                  && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && $0.text.count <= DurableComposerQueuePolicy.maxTextLength
                  && $0.order > 0
                  && (0...DurableComposerQueuePolicy.maxAutomaticFailures).contains($0.automaticFailures) }),
              snapshot.entries.reduce(0, { $0 + $1.text.count })
                  <= DurableComposerQueuePolicy.maxTotalTextLength else {
            try? fileManager.removeItem(at: url)
            return ([], 0, true, false, nil)
        }
        var normalized = false
        let now = Date()
        let normalizedEntries = snapshot.entries.sorted { $0.order < $1.order }.map { original in
            var entry = original
            if entry.state == .submitting {
                entry.state = .uncertain
                entry.lastError = entry.lastError
                    ?? "The app ended while this prompt was being submitted; it will not be replayed automatically."
                entry.updatedAt = now
                normalized = true
            } else if entry.state == .localReady && entry.automaticFailures > 0 {
                entry.state = .localReady
                entry.automaticFailures = 0
                entry.lastError = nil
                entry.updatedAt = now
                normalized = true
            }
            return entry
        }
        return (normalizedEntries, snapshot.nextOrder, false, normalized, nil)
    }
}

public typealias ComposerQueueKey = DurableComposerQueueKey
public typealias ComposerQueueEntry = DurableComposerQueueEntry
public typealias ComposerQueueState = DurableComposerQueueState
