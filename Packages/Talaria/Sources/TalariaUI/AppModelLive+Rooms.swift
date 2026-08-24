import Foundation
import Observation
import TalariaKit

// Mobile room orchestration. Hermes Desktop's room loop is deterministic:
// one source-qualified member at a time, at most three rounds and ten posts,
// with per-thread/member watermarks. Talaria replaces the old 250 ms hand-off
// with a task chain: only one driver can own a room's side effects.

@MainActor
@Observable
final class RoomRuntime {
    static let shared = RoomRuntime()

    var rooms: [RoomRecord] = []
    var avatarData: [RoomID: Data] = [:]
    var openRoomID: RoomID?
    var loadError: String?
    var metadataPendingCount = 0
    var metadataLastError: String?
    var profileLifecycleError: String?
    var composerDrafts: [RoomID: String] = [:]
    var composerDraftErrors: [RoomID: String] = [:]
    var isLoaded = false
    /// Blocking prompts belong to the live hidden session, not to the durable
    /// room transcript.  The compound key intentionally includes the source
    /// gateway: two retained gateways can both expose a `default` profile.
    var pendingPrompts: [RoomPendingPromptKey: RoomPendingPrompt] = [:]

    @ObservationIgnored var store = RoomStore.shared
    @ObservationIgnored var driveTasks: [RoomID: Task<Void, Never>] = [:]
    @ObservationIgnored var driveTokens: [RoomID: UUID] = [:]
    /// A settled drive can still own accepted/uncertain/timed-out provider
    /// work. Keep harvesting it for a bounded period without retaining the
    /// serialized drive owner itself.
    @ObservationIgnored var postSettleHarvestTasks: [RoomID: Task<Void, Never>] = [:]
    @ObservationIgnored var postSettleHarvestTokens: [RoomID: UUID] = [:]
    @ObservationIgnored var postSettleHarvestInterval: Duration = .seconds(5)
    @ObservationIgnored var postSettleHarvestLimit = 60
    @ObservationIgnored var pollInterval: Duration = .seconds(2)
    @ObservationIgnored var baseTurnTimeout: TimeInterval = 180
    @ObservationIgnored var hardTurnTimeout: TimeInterval = 20 * 60
    @ObservationIgnored var driveOperation: (@MainActor (AppModel, RoomID) async -> Void)?
    @ObservationIgnored var loadOperation: (() async throws -> [RoomRecord])?
    @ObservationIgnored var submitOperation:
        (@MainActor (RoomAttempt, RoomMemberSessionSnapshot, [RoomOutboundAttachment]) async -> RoomPromptSubmission)?
    @ObservationIgnored var metadataMutationOperation:
        (@MainActor (RoomMetadataMutation) async throws -> Void)?
    /// Test seam for a successful `session.resume` read. Production always
    /// uses the source-routed client below; keeping the seam at this narrow
    /// boundary lets adversarial policy tests avoid inventing a gateway.
    @ObservationIgnored var sessionReadOperation:
        (@MainActor (RoomAttempt) async throws -> RoomMemberSessionSnapshot)?
    /// Test seam for prompt answers. The value is the fully source-qualified
    /// wire shape, so tests can prove an answer cannot borrow a foreground or
    /// same-named member's client.
    @ObservationIgnored var pendingPromptResponseOperation:
        (@MainActor (RoomPendingPromptResponse) async throws -> JSONValue)?
    /// Test seam immediately after room-name collision proof and before the
    /// durable room/outbox commit. Production leaves it nil. Keeping the seam
    /// at this boundary lets concurrency tests suspend the winning mutation
    /// without weakening the namespace lock itself.
    @ObservationIgnored var roomNameCommitBarrier: (@MainActor () async -> Void)?
    @ObservationIgnored var composerDraftTasks: [RoomID: Task<Void, Never>] = [:]
    @ObservationIgnored var composerDraftGenerations: [RoomID: UInt64] = [:]
    /// A batch may partially succeed before a later question fails. Remember
    /// only confirmed question ids for this live request so retrying the card
    /// does not duplicate a response Hermes already acknowledged.
    @ObservationIgnored var answeredPromptQuestions: [RoomPendingPromptKey: PromptProgress] = [:]
    /// Source-qualified lifecycle generations fence metadata flushes and room
    /// drive completions that outlive a profile rename/delete await.
    @ObservationIgnored var profileRouteGenerations: [GatewayBotRoute: UInt64] = [:]
    @ObservationIgnored var retiredProfileRoutes: Set<GatewayBotRoute> = []
    @ObservationIgnored var deferredProfileRearmRooms: Set<RoomID> = []

    func replace(_ room: RoomRecord) {
        if let index = rooms.firstIndex(where: { $0.id == room.id }) { rooms[index] = room }
        else { rooms.append(room) }
        rooms.sort {
            if $0.lastActivityAt != $1.lastActivityAt { return $0.lastActivityAt > $1.lastActivityAt }
            return $0.id.description < $1.id.description
        }
    }

    func remove(_ id: RoomID) {
        cancelPostSettleHarvest(roomID: id)
        rooms.removeAll { $0.id == id }
        clearPendingPrompts(roomID: id)
        if openRoomID == id { openRoomID = nil }
    }

    func cancelPostSettleHarvest(roomID: RoomID) {
        postSettleHarvestTasks[roomID]?.cancel()
        postSettleHarvestTasks[roomID] = nil
        postSettleHarvestTokens[roomID] = nil
    }

    func profileRouteGeneration(_ route: GatewayBotRoute) -> UInt64 {
        profileRouteGenerations[route, default: 0]
    }

    func bumpProfileRouteGeneration(_ route: GatewayBotRoute) -> UInt64 {
        let next = profileRouteGenerations[route, default: 0] &+ 1
        profileRouteGenerations[route] = next
        return next
    }

    func acceptsProfileRoute(_ route: GatewayBotRoute,
                             generation: UInt64) -> Bool {
        !retiredProfileRoutes.contains(route)
            && profileRouteGenerations[route, default: 0] == generation
    }

    struct PromptProgress: Sendable {
        var attemptID: RoomAttemptID
        var threadID: RoomThreadID
        var epoch: UInt64
        var requestID: String
        var fingerprint: RoomPendingPromptFingerprint
        var answeredQuestionIDs: Set<String>
        /// Server-replayed locks and locally confirmed partial batch answers.
        /// Keeping their text live-only lets the card show "accepted" without
        /// ever writing a human tool response into RoomRecord/transcript.
        var lockedAnswersByQuestionID: [String: String] = [:]

        init(prompt: RoomPendingPrompt, answeredQuestionIDs: Set<String> = [],
             lockedAnswersByQuestionID: [String: String] = [:]) {
            attemptID = prompt.attemptID
            threadID = prompt.threadID
            epoch = prompt.epoch
            requestID = prompt.requestID
            fingerprint = prompt.stableFingerprint
            self.answeredQuestionIDs = answeredQuestionIDs
            self.lockedAnswersByQuestionID = lockedAnswersByQuestionID
        }

        func matches(_ prompt: RoomPendingPrompt) -> Bool {
            attemptID == prompt.attemptID
                && threadID == prompt.threadID
                && epoch == prompt.epoch
                && requestID == prompt.requestID
                && fingerprint == prompt.stableFingerprint
        }
    }

    /// Publish a prompt only after a *successful* hidden-session resume. A
    /// failed/transient read simply never reaches this function, preserving
    /// the card and its SwiftUI draft. The same request can update its runtime
    /// SID after reconnect without resetting draft/progress; a new request
    /// atomically replaces both.
    func synchronizePendingPrompt(roomID: RoomID, attempt: RoomAttempt,
                                  snapshot: RoomMemberSessionSnapshot) {
        let key = RoomPendingPromptKey(roomID: roomID, route: attempt.member)
        guard let prompt = snapshot.pendingPrompt(roomID: roomID,
                                                  route: attempt.member,
                                                  attempt: attempt) else {
            pendingPrompts.removeValue(forKey: key)
            answeredPromptQuestions.removeValue(forKey: key)
            return
        }
        var progress = answeredPromptQuestions[key]
        if progress?.matches(prompt) != true {
            progress = .init(prompt: prompt)
        }
        // Replayed locks are monotonic for one request. A delayed resume that
        // lacks an already accepted question cannot make it editable or send
        // it again; a newly replayed lock joins the existing progress.
        for (questionID, answer) in prompt.lockedAnswersByQuestionID
        where progress?.lockedAnswersByQuestionID[questionID] == nil {
            progress?.lockedAnswersByQuestionID[questionID] = answer
        }
        progress?.answeredQuestionIDs.formUnion(prompt.lockedQuestionIDs)
        if let progress { answeredPromptQuestions[key] = progress }

        var merged = prompt
        merged.lockedAnswersByQuestionID = progress?.lockedAnswersByQuestionID ?? [:]
        pendingPrompts[key] = merged
    }

    func clearPendingPrompt(for attempt: RoomAttempt, roomID: RoomID) {
        let key = RoomPendingPromptKey(roomID: roomID, route: attempt.member)
        guard pendingPrompts[key]?.attemptID == attempt.id else { return }
        pendingPrompts.removeValue(forKey: key)
        answeredPromptQuestions.removeValue(forKey: key)
    }

    func clearPendingPrompts(roomID: RoomID) {
        let keys = pendingPrompts.keys.filter { $0.roomID == roomID }
        for key in keys {
            pendingPrompts.removeValue(forKey: key)
            answeredPromptQuestions.removeValue(forKey: key)
        }
    }

    func clearPendingPrompts(route: GatewayBotRoute) {
        let keys = pendingPrompts.keys.filter { $0.route == route }
        for key in keys {
            pendingPrompts.removeValue(forKey: key)
            answeredPromptQuestions.removeValue(forKey: key)
        }
    }

    /// Profile rename preserves a room's stable ids. Re-key only an
    /// unambiguous live card; if a destination collision somehow exists, drop
    /// the stale source instead of making either prompt answerable on the
    /// wrong identity.
    func migratePendingPrompts(from source: GatewayBotRoute, to destination: GatewayBotRoute) {
        let sourceEntries = pendingPrompts.filter { $0.key.route == source }
        for (oldKey, oldPrompt) in sourceEntries {
            let newKey = RoomPendingPromptKey(roomID: oldKey.roomID, route: destination)
            let progress = answeredPromptQuestions.removeValue(forKey: oldKey)
            pendingPrompts.removeValue(forKey: oldKey)
            guard pendingPrompts[newKey] == nil else { continue }
            var prompt = oldPrompt
            prompt.key = newKey
            pendingPrompts[newKey] = prompt
            if let progress { answeredPromptQuestions[newKey] = progress }
        }
    }
}

/// Answers stay typed until they cross the source-qualified room transport.
/// A batch is represented by multiple values in the order of the normalized
/// `RoomPendingPrompt.questions`, not by one lossy comma-joined payload.
public enum RoomPendingPromptAnswer: Sendable {
    case approval(ApprovalChoice)
    case text(String, questionID: String? = nil)
    case selections([String], questionID: String? = nil)

    fileprivate var questionID: String? {
        switch self {
        case .approval: nil
        case let .text(_, questionID), let .selections(_, questionID): questionID
        }
    }

    fileprivate var questionKey: String {
        switch self {
        case .approval: "__approval__"
        case let .text(_, questionID), let .selections(_, questionID):
            questionID ?? "__single__"
        }
    }

    fileprivate var lockedAnswer: String? {
        switch self {
        case .approval: nil
        case let .text(value, _): value
        case let .selections(values, _): RoomPendingPrompt.multiSelectAnswer(values)
        }
    }
}

enum RoomPendingPromptRuntimeError: LocalizedError, Equatable {
    case stale
    case malformedAnswer
    case emptyAnswer
    case unresolvedApproval

    var errorDescription: String? {
        switch self {
        case .stale: "This request changed in Hermes. Check the latest prompt before answering."
        case .malformedAnswer: "This answer no longer matches the pending request."
        case .emptyAnswer: "Enter or choose an answer before sending."
        case .unresolvedApproval: "Hermes did not confirm that approval was applied."
        }
    }
}

/// MainActor-side token captured before a profile lifecycle REST await. The
/// durable RoomStore mutation is performed only after the server postcondition
/// commits, while this token prevents the old source completion from writing
/// into a reused destination in the meantime.
struct RoomProfileLifecycleToken: Equatable, Sendable {
    var source: GatewayBotRoute
    var generation: UInt64
}

@MainActor
final class RoomMutationGate {
    static let shared = RoomMutationGate()
    /// Every operation which can claim a room display name acquires this key
    /// first. Per-room mutation keys follow it in `withLocks`, giving the whole
    /// name namespace one ordering without nesting admission scopes.
    static let roomNameNamespaceKey = "room-name-namespace"
    static let metadataOutboxKey = "metadata-outbox"
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var held = Set<String>()
    private var waiters: [String: [Waiter]] = [:]
    private var activeOperations = 0
    private var quiescing = false
    private var admissionWaiters: [Waiter] = []
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var drainedWaiter: CheckedContinuation<Void, Never>?

    func queuedWaiterCount(for key: String) -> Int { waiters[key]?.count ?? 0 }
    var quiescenceIsPending: Bool { quiescing }

    func withLock<T>(_ key: String, _ operation: () async throws -> T) async throws -> T {
        try await withLocks([key], operation)
    }

    /// Acquire several keys under one admitted operation. Nested `withLock`
    /// calls are unsafe here: quiescence can begin after the outer admission,
    /// block the inner admission, and then wait forever for the outer owner.
    /// One admission plus ordered acquisition avoids that cycle.
    func withLocks<T>(_ keys: [String], _ operation: () async throws -> T) async throws -> T {
        guard await enterOperation() else { throw CancellationError() }
        var ownedKeys: [String] = []
        var seen = Set<String>()
        let orderedKeys = keys.filter { seen.insert($0).inserted }
        defer {
            for key in ownedKeys.reversed() { release(key) }
            leaveOperation()
        }
        for key in orderedKeys {
            guard await acquire(key) else { throw CancellationError() }
            ownedKeys.append(key)
        }
        try Task.checkCancellation()
        return try await operation()
    }

    /// Exclusive local-data boundary. New mutations wait outside; existing
    /// create/send/settings/disband work drains before deletion begins.
    func withQuiescence<T>(_ operation: () async throws -> T) async rethrows -> T {
        await acquireQuiescence()
        if activeOperations > 0 {
            await withCheckedContinuation { drainedWaiter = $0 }
        }
        defer {
            if !quiescenceWaiters.isEmpty {
                quiescenceWaiters.removeFirst().resume()
            } else {
                quiescing = false
                let queued = admissionWaiters
                admissionWaiters.removeAll()
                // Claim admission synchronously before resuming, so another
                // quiescence cannot slip between release and waiter wake-up.
                activeOperations += queued.count
                for waiter in queued { waiter.continuation.resume(returning: true) }
            }
        }
        return try await operation()
    }

    private func acquireQuiescence() async {
        if !quiescing { quiescing = true; return }
        await withCheckedContinuation { quiescenceWaiters.append($0) }
        // Ownership is handed directly by the prior exclusive caller; the
        // admission gate intentionally remains closed between them.
    }

    private func enterOperation() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard quiescing else { activeOperations += 1; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { admissionWaiters.append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelAdmission(id) }
        }
    }

    private func leaveOperation() {
        activeOperations = max(0, activeOperations - 1)
        if quiescing, activeOperations == 0, let waiter = drainedWaiter {
            drainedWaiter = nil
            waiter.resume()
        }
    }

    private func acquire(_ key: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        if held.insert(key).inserted { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { waiters[key, default: []].append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelKeyWaiter(key, id: id) }
        }
    }

    private func release(_ key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            if queue.isEmpty { waiters[key] = nil } else { waiters[key] = queue }
            next.continuation.resume(returning: true)
        } else { held.remove(key) }
    }

    private func cancelAdmission(_ id: UUID) {
        guard let index = admissionWaiters.firstIndex(where: { $0.id == id }) else { return }
        admissionWaiters.remove(at: index).continuation.resume(returning: false)
    }

    private func cancelKeyWaiter(_ key: String, id: UUID) {
        guard var queue = waiters[key],
              let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let waiter = queue.remove(at: index)
        if queue.isEmpty { waiters[key] = nil } else { waiters[key] = queue }
        waiter.continuation.resume(returning: false)
    }
}

public enum RoomNameError: LocalizedError, Equatable {
    case empty
    case taken
    public var errorDescription: String? {
        switch self {
        case .empty: "Room name cannot be empty."
        case .taken: "A room with that name already exists."
        }
    }
}

public enum RoomSettingsError: LocalizedError, Equatable {
    case memberBusy
    public var errorDescription: String? {
        "A bot is still working in this room. Wait for its turn to settle before removing it."
    }
}

public enum RoomNamePolicy {
    public static let maximumLength = 64

    public static func normalized(_ proposed: String) throws -> String {
        let value = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw RoomNameError.empty }
        return String(value.prefix(maximumLength))
    }

    public static func unique(_ proposed: String, existing: [String]) throws -> String {
        let base = try normalized(proposed)
        let used = Set(existing.map { $0.lowercased() })
        guard used.contains(base.lowercased()) else { return base }
        var suffix = 2
        while true {
            let tail = " \(suffix)"
            let candidate = String(base.prefix(maximumLength - tail.count)) + tail
            if !used.contains(candidate.lowercased()) { return candidate }
            suffix += 1
        }
    }
}

/// Transcript attention and transport uncertainty are deliberately separate.
/// `RoomRecord.needsUser` is owned only by an explicit `@user` mention (and is
/// cleared by the user's next turn); delivery state is derived from durable
/// attempts so reconciling or abandoning transport work cannot erase it.
public enum RoomDeliveryPolicy {
    public static func unresolvedAttempts(in room: RoomRecord) -> [RoomAttempt] {
        room.attempts.filter {
            $0.finishedAt == nil && [.working, .uncertain, .timedOut].contains($0.state)
        }
    }

    public static func hasUnresolvedDelivery(_ room: RoomRecord) -> Bool {
        !unresolvedAttempts(in: room).isEmpty
    }
}

public enum RoomMetadataOutboxStatus: Equatable, Sendable {
    case clear
    case waiting(count: Int)
    case retryRequired(count: Int, message: String)
}

public enum RoomMetadataOutboxPolicy {
    public static func status(pendingCount: Int, lastError: String?) -> RoomMetadataOutboxStatus {
        guard pendingCount > 0 else { return .clear }
        if let lastError, !lastError.isEmpty {
            return .retryRequired(count: pendingCount, message: lastError)
        }
        return .waiting(count: pendingCount)
    }
}

public extension AppModel {
    var rooms: [RoomRecord] { RoomRuntime.shared.rooms }
    var roomMetadataPendingCount: Int { RoomRuntime.shared.metadataPendingCount }
    var roomMetadataLastError: String? { RoomRuntime.shared.metadataLastError }
    var roomProfileLifecycleError: String? { RoomRuntime.shared.profileLifecycleError }
    var openRoomID: RoomID? {
        get { RoomRuntime.shared.openRoomID }
        set { RoomRuntime.shared.openRoomID = newValue }
    }

    func room(_ id: RoomID) -> RoomRecord? {
        RoomRuntime.shared.rooms.first { $0.id == id }
    }

    func roomAvatarData(_ id: RoomID) -> Data? { RoomRuntime.shared.avatarData[id] }

    private func roomProjectionKey(_ room: RoomRecord) -> String {
        room.rawProjectionRoomKey ?? RoomProjectionEnvelope.idKey(room.id.description)
    }

    /// Live, source-qualified prompts currently blocking this room. These are
    /// deliberately separate from `RoomRecord.needsUser`, which remains the
    /// transcript-only `@user` attention bit.
    func roomPendingPrompts(_ roomID: RoomID) -> [RoomPendingPrompt] {
        RoomRuntime.shared.pendingPrompts.values
            .filter { $0.roomID == roomID }
            .sorted { lhs, rhs in
                if lhs.route.gatewayID != rhs.route.gatewayID {
                    return lhs.route.gatewayID < rhs.route.gatewayID
                }
                return lhs.route.profile < rhs.route.profile
            }
    }

    /// Answer a live hidden-session prompt through the client that owns its
    /// exact source route. A card can disappear only after Hermes confirms an
    /// approval (`resolved > 0`) or every sequential clarify response
    /// succeeds; a transient error intentionally leaves the same card/draft
    /// in place for retry.
    func respondToRoomPendingPrompt(_ prompt: RoomPendingPrompt,
                                    answers: [RoomPendingPromptAnswer]) async throws {
        let roomID = prompt.roomID
        try await RoomMutationGate.shared.withLock(roomID.description) {
            let runtime = RoomRuntime.shared
            guard runtime.pendingPrompts[prompt.key] == prompt,
                  let room = try await runtime.store.room(id: roomID),
                  let attempt = room.attempts.first(where: { $0.id == prompt.attemptID }),
                  attempt.finishedAt == nil,
                  attempt.member == prompt.route,
                  attempt.threadID == prompt.threadID,
                  attempt.epoch == prompt.epoch,
                  runtime.acceptsProfileRoute(prompt.route,
                                              generation: runtime.profileRouteGeneration(prompt.route))
            else { throw RoomPendingPromptRuntimeError.stale }

            let alreadyAnswered: Set<String>
            if let progress = runtime.answeredPromptQuestions[prompt.key],
               progress.matches(prompt) {
                alreadyAnswered = progress.answeredQuestionIDs
            } else {
                alreadyAnswered = []
            }
            let ordered = try roomPendingPromptAnswerPlan(
                prompt: prompt, answers: answers, alreadyAnswered: alreadyAnswered)

            for answer in ordered {
                let approvalResolved = try await sendRoomPendingPromptResponse(prompt, answer: answer)
                if case .approval = answer, (approvalResolved ?? 0) <= 0 {
                    // Do not echo, complete, or remove an approval card until
                    // Hermes positively acknowledges that it resolved one.
                    throw RoomPendingPromptRuntimeError.unresolvedApproval
                }
                guard runtime.acceptsProfileRoute(
                    prompt.route, generation: runtime.profileRouteGeneration(prompt.route)
                ), Self.roomPromptResponseIdentityMatches(
                    runtime.pendingPrompts[prompt.key], expected: prompt)
                else { throw RoomPendingPromptRuntimeError.stale }
                var progress = runtime.answeredPromptQuestions[prompt.key]
                if progress?.matches(prompt) != true {
                    progress = .init(prompt: prompt)
                }
                progress?.answeredQuestionIDs.insert(answer.questionKey)
                if prompt.isBatchClarify, let questionID = answer.questionID,
                   let accepted = answer.lockedAnswer {
                    progress?.lockedAnswersByQuestionID[questionID] = accepted
                    if var visible = runtime.pendingPrompts[prompt.key],
                       Self.roomPromptResponseIdentityMatches(visible, expected: prompt) {
                        visible.lockedAnswersByQuestionID[questionID] = accepted
                        runtime.pendingPrompts[prompt.key] = visible
                    }
                }
                if let progress { runtime.answeredPromptQuestions[prompt.key] = progress }
            }

            // A newer attempt must remain visible even if an old response
            // returned after a reconnect. Full durable producer identity is
            // the narrow postcondition that permits removal here.
            if Self.roomPromptResponseIdentityMatches(
                runtime.pendingPrompts[prompt.key], expected: prompt) {
                runtime.pendingPrompts.removeValue(forKey: prompt.key)
                runtime.answeredPromptQuestions.removeValue(forKey: prompt.key)
            }
        }
        // A confirmed answer can expose another nested prompt or the member's
        // reply. Reconciliation is read-only and will re-mirror that result.
        scheduleRoomReconciliation(roomID: roomID)
    }

    /// A request id is scoped by Hermes' live request table, not a durable
    /// room identity. A reconnect/restart may reuse one for a different room
    /// attempt, so an old response completion may mutate/remove a card only
    /// when the whole durable producer identity still matches. The runtime SID
    /// is intentionally excluded: the same logical request can acquire a new
    /// connection-local SID after a successful `session.resume`.
    private nonisolated static func roomPromptResponseIdentityMatches(
        _ current: RoomPendingPrompt?, expected: RoomPendingPrompt
    ) -> Bool {
        guard let current else { return false }
        return current.key == expected.key
            && current.attemptID == expected.attemptID
            && current.threadID == expected.threadID
            && current.epoch == expected.epoch
            && current.requestID == expected.requestID
            && current.stableFingerprint == expected.stableFingerprint
    }

    func reconcileRoom(_ roomID: RoomID) {
        scheduleRoomReconciliation(roomID: roomID)
    }

    private func roomPendingPromptAnswerPlan(
        prompt: RoomPendingPrompt, answers: [RoomPendingPromptAnswer],
        alreadyAnswered: Set<String>
    ) throws -> [RoomPendingPromptAnswer] {
        switch prompt.kind {
        case .approval:
            guard answers.count == 1, case let .approval(choice) = answers[0],
                  prompt.approvalChoices.contains(where: { $0.rawValue == choice.rawValue })
            else { throw RoomPendingPromptRuntimeError.malformedAnswer }
            return answers

        case .clarify:
            guard !answers.isEmpty else { throw RoomPendingPromptRuntimeError.emptyAnswer }
            if prompt.isBatchClarify {
                let remaining = prompt.questions.filter {
                    guard let questionID = $0.questionID else { return false }
                    return !prompt.isQuestionLocked($0) && !alreadyAnswered.contains(questionID)
                }
                guard !remaining.isEmpty, answers.count == remaining.count else {
                    throw RoomPendingPromptRuntimeError.malformedAnswer
                }
                var byQuestionID: [String: RoomPendingPromptAnswer] = [:]
                for answer in answers {
                    guard let questionID = answer.questionID,
                          byQuestionID[questionID] == nil else {
                        throw RoomPendingPromptRuntimeError.malformedAnswer
                    }
                    byQuestionID[questionID] = answer
                }
                return try remaining.map { question in
                    guard let questionID = question.questionID,
                          let answer = byQuestionID[questionID] else {
                        throw RoomPendingPromptRuntimeError.malformedAnswer
                    }
                    try validateRoomPendingPrompt(answer, for: question)
                    return answer
                }
            }

            guard prompt.questions.count == 1, answers.count == 1,
                  answers[0].questionID == nil else {
                throw RoomPendingPromptRuntimeError.malformedAnswer
            }
            try validateRoomPendingPrompt(answers[0], for: prompt.questions[0])
            return answers
        }
    }

    private func validateRoomPendingPrompt(_ answer: RoomPendingPromptAnswer,
                                           for question: RoomPendingClarifyQuestion) throws {
        switch answer {
        case let .text(value, _):
            guard !question.multiSelect else { throw RoomPendingPromptRuntimeError.malformedAnswer }
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RoomPendingPromptRuntimeError.emptyAnswer
            }
        case let .selections(values, _):
            guard question.multiSelect else { throw RoomPendingPromptRuntimeError.malformedAnswer }
            guard !values.isEmpty else { throw RoomPendingPromptRuntimeError.emptyAnswer }
        case .approval:
            throw RoomPendingPromptRuntimeError.malformedAnswer
        }
    }

    /// Build through the prompt helpers before choosing a transport. The
    /// production branch deliberately calls the finalized GatewayClient
    /// overloads rather than generic RPC, while the test seam observes the
    /// same exact source-qualified wire value.
    private func sendRoomPendingPromptResponse(
        _ prompt: RoomPendingPrompt, answer: RoomPendingPromptAnswer
    ) async throws -> Int? {
        let runtime = RoomRuntime.shared
        if let operation = runtime.pendingPromptResponseOperation {
            let response: RoomPendingPromptResponse
            switch answer {
            case let .approval(choice): response = try prompt.approvalResponse(choice: choice)
            case let .text(value, questionID):
                response = try prompt.clarifyResponse(answer: value, questionID: questionID)
            case let .selections(values, questionID):
                response = try prompt.clarifyResponse(selections: values, questionID: questionID)
            }
            let result = try await operation(response)
            if case .approval = answer {
                return RoomPendingPrompt.resolvedApprovalCount(in: result)
            }
            return nil
        }

        let client = try await routedClient(for: prompt.route)
        switch answer {
        case let .approval(choice):
            return try await client.respondToRoomPrompt(prompt, choice: choice)
        case let .text(value, questionID):
            try await client.respondToRoomPrompt(prompt, answer: value, questionID: questionID)
        case let .selections(values, questionID):
            try await client.respondToRoomPrompt(prompt, selections: values, questionID: questionID)
        }
        return nil
    }

    /// Explicit fail-closed resolution for a turn whose acceptance cannot be
    /// proven. Talaria never retries it automatically; the user may abandon
    /// the durable attempt after checking the owning Hermes session.
    func abandonRoomAttempt(roomID: RoomID, attemptID: RoomAttemptID) async {
        let updated = try? await RoomMutationGate.shared.withLock(roomID.description) {
            let runtime = RoomRuntime.shared
            if let room = try await runtime.store.room(id: roomID),
               let attempt = room.attempts.first(where: { $0.id == attemptID }),
               !attempt.stagedImagePaths.isEmpty,
               runtime.acceptsProfileRoute(attempt.member,
                                           generation: runtime.profileRouteGeneration(attempt.member)),
               let client = try? await routedClient(for: attempt.member) {
               await client.detachRoomStagedImages(attempt.stagedImagePaths,
                                                    sessionID: attempt.runtimeSessionID)
            }
            guard let current = try await runtime.store.room(id: roomID),
                  let attempt = current.attempts.first(where: { $0.id == attemptID }),
                  runtime.acceptsProfileRoute(attempt.member,
                                              generation: runtime.profileRouteGeneration(attempt.member))
            else { throw CancellationError() }
            return try await runtime.store.mutate(roomID: roomID) { room in
                guard let index = room.attempts.firstIndex(where: { $0.id == attemptID }),
                      room.attempts[index].finishedAt == nil else { throw CancellationError() }
                let attempt = room.attempts[index]
                room.attempts[index].state = .cancelled
                room.attempts[index].finishedAt = Date()
                room.attempts[index].outboundAttachments = []
                room.attempts[index].stagedImagePaths = []
                RoomEngine.recordActivity(RoomActivity(epoch: attempt.epoch, kind: .cancelled,
                                                       member: attempt.member,
                                                       threadID: attempt.threadID), in: &room)
            }
        }
        if let updated {
            RoomRuntime.shared.replace(updated)
            if let attempt = updated.attempts.first(where: { $0.id == attemptID }) {
                RoomRuntime.shared.clearPendingPrompt(for: attempt, roomID: roomID)
            }
        }
    }

    func roomStorageUsage() async -> RoomStorageUsage? {
        try? await RoomStore.shared.storageUsage()
    }

    @discardableResult
    internal func prepareRoomProfileLifecycle(
        source route: GatewayBotRoute, deleting: Bool = false
    ) -> RoomProfileLifecycleToken {
        let runtime = RoomRuntime.shared
        let generation = runtime.bumpProfileRouteGeneration(route)
        if deleting { runtime.retiredProfileRoutes.insert(route) }
        let affected = runtime.rooms.filter { room in
            room.members.contains(where: { $0.route == route })
                || room.formerMembers.contains(where: { $0.route == route })
                || room.attempts.contains(where: { $0.member == route })
                || room.memberSessions[route.qualifiedID] != nil
        }.map(\.id)
        for id in affected {
            runtime.driveTasks[id]?.cancel()
            runtime.driveTokens[id] = UUID()
            runtime.cancelPostSettleHarvest(roomID: id)
        }
        return RoomProfileLifecycleToken(source: route, generation: generation)
    }

    internal func commitRoomProfileRename(
        _ token: RoomProfileLifecycleToken, destination: GatewayBotRoute
    ) async throws {
        let runtime = RoomRuntime.shared
        guard runtime.profileRouteGeneration(token.source) == token.generation
        else { throw CancellationError() }
        try await RoomMutationGate.shared.withLock("profile-route:\(token.source.qualifiedID)") {
            let result = try await runtime.store.migrateProfileRoute(
                from: token.source, to: destination)
            try await runtime.store.clearProfileRouteLifecycleIntent(token.source)
            guard runtime.profileRouteGeneration(token.source) == token.generation
            else { throw CancellationError() }
            runtime.retiredProfileRoutes.remove(token.source)
            runtime.retiredProfileRoutes.remove(destination)
            _ = runtime.bumpProfileRouteGeneration(destination)
            runtime.migratePendingPrompts(from: token.source, to: destination)
            runtime.rooms = result.rooms.sorted { $0.lastActivityAt > $1.lastActivityAt }
            runtime.metadataPendingCount = (try? await runtime.store.metadataOutbox().count) ?? 0
            for room in result.rooms {
                runtime.deferredProfileRearmRooms.insert(room.id)
            }
        }
        scheduleRoomProjectionSync(changedRooms: runtime.rooms.map {
            $0.rawProjectionRoomKey ?? RoomProjectionEnvelope.idKey($0.id.description)
        })
    }

    /// Durable preflight fence. This is awaited before the profile REST call,
    /// so a crash during the remote mutation restarts with the source route
    /// retired rather than replaying its outbox into a reused profile.
    internal func persistRoomProfileLifecycleFence(
        source route: GatewayBotRoute, deleting: Bool = false
    ) async throws -> RoomProfileLifecycleToken {
        let token = prepareRoomProfileLifecycle(source: route, deleting: deleting)
        let runtime = RoomRuntime.shared
        try await RoomMutationGate.shared.withLock("profile-route:\(route.qualifiedID)") {
            try await runtime.store.beginProfileRouteLifecycleIntent(route)
            runtime.retiredProfileRoutes.insert(route)
        }
        return token
    }

    internal func commitRoomProfileRemoval(
        _ token: RoomProfileLifecycleToken
    ) async throws {
        let runtime = RoomRuntime.shared
        guard runtime.profileRouteGeneration(token.source) == token.generation else {
            throw CancellationError()
        }
        try await RoomMutationGate.shared.withLock("profile-route:\(token.source.qualifiedID)") {
            let result = try await runtime.store.retireProfileRoute(token.source)
            try await runtime.store.clearProfileRouteLifecycleIntent(token.source)
            guard runtime.profileRouteGeneration(token.source) == token.generation else {
                throw CancellationError()
            }
            runtime.retiredProfileRoutes.insert(token.source)
            runtime.clearPendingPrompts(route: token.source)
            runtime.rooms = result.rooms.sorted { $0.lastActivityAt > $1.lastActivityAt }
            runtime.metadataPendingCount = (try? await runtime.store.metadataOutbox().count) ?? 0
        }
        scheduleRoomProjectionSync(changedRooms: runtime.rooms.map {
            $0.rawProjectionRoomKey ?? RoomProjectionEnvelope.idKey($0.id.description)
        })
    }

    /// Fail closed after Hermes has committed but local reconciliation could
    /// not finish. The actor write is retried here so a restart observes the
    /// durable tombstone rather than replaying the source outbox.
    internal func failClosedRoomProfileRoute(_ route: GatewayBotRoute) async {
        do {
            try await RoomMutationGate.shared.withLock("profile-route:\(route.qualifiedID)") {
                let result = try await RoomRuntime.shared.store.retireProfileRoute(route)
                RoomRuntime.shared.rooms = result.rooms.sorted { $0.lastActivityAt > $1.lastActivityAt }
            }
        } catch {
            RoomRuntime.shared.profileLifecycleError =
                "Room state for \(route.qualifiedID) is fenced; retry reconciliation before reuse."
        }
        RoomRuntime.shared.retiredProfileRoutes.insert(route)
        RoomRuntime.shared.clearPendingPrompts(route: route)
        scheduleRoomProjectionSync(changedRooms: RoomRuntime.shared.rooms.map {
            $0.rawProjectionRoomKey ?? RoomProjectionEnvelope.idKey($0.id.description)
        })
    }

    internal func abortRoomProfileLifecycle(_ token: RoomProfileLifecycleToken) async {
        do {
            try await RoomMutationGate.shared.withLock("profile-route:\(token.source.qualifiedID)") {
                try await RoomRuntime.shared.store.clearProfileRouteLifecycleIntent(token.source)
            }
        } catch {
            RoomRuntime.shared.profileLifecycleError =
                "Profile route remains fenced because its durable lifecycle intent could not be cleared."
            return
        }
        abortRoomProfileLifecycleMemory(token)
    }

    private func abortRoomProfileLifecycleMemory(_ token: RoomProfileLifecycleToken) {
        let runtime = RoomRuntime.shared
        guard runtime.profileRouteGeneration(token.source) == token.generation else { return }
        _ = runtime.bumpProfileRouteGeneration(token.source)
        runtime.retiredProfileRoutes.remove(token.source)
        let affected = runtime.rooms.filter { room in
            room.members.contains { $0.route == token.source }
                || room.formerMembers.contains { $0.route == token.source }
                || room.attempts.contains { $0.member == token.source && $0.finishedAt == nil }
        }
        for room in affected {
            runtime.deferredProfileRearmRooms.insert(room.id)
        }
    }

    /// Called after the profile lifecycle traffic lease is released. Keeping
    /// this separate from commit/abort prevents a drive from opening a new
    /// provider request while Hermes is still fenced for the old route.
    internal func rearmDeferredRoomProfileWork() {
        let runtime = RoomRuntime.shared
        let pending = runtime.deferredProfileRearmRooms
        runtime.deferredProfileRearmRooms.removeAll()
        for id in pending {
            guard let room = runtime.rooms.first(where: { $0.id == id }) else { continue }
            if !room.drives.isEmpty { scheduleRoomDrive(roomID: id) }
            else if room.attempts.contains(where: { $0.finishedAt == nil }) {
                scheduleRoomReconciliation(roomID: id)
            }
        }
    }

    internal func activateRoomProfileRoute(_ route: GatewayBotRoute) async throws {
        let runtime = RoomRuntime.shared
        let generation = runtime.profileRouteGeneration(route)
        try await RoomMutationGate.shared.withLock("profile-route:\(route.qualifiedID)") {
            try await runtime.store.activateProfileRoute(route)
            guard runtime.profileRouteGeneration(route) == generation else {
                throw CancellationError()
            }
            runtime.retiredProfileRoutes.remove(route)
            _ = runtime.bumpProfileRouteGeneration(route)
        }
        runtime.profileLifecycleError = nil
    }

    /// Settings → Delete local data. New room mutations are held outside the
    /// boundary, existing mutations and drive owners drain, then index/blobs
    /// are deleted before admission reopens. This prevents an in-flight create
    /// or send from resurrecting storage after the user saw deletion finish.
    func deleteAllRoomData() async throws {
        var deletionError: Error?
        var roomsToResume: [RoomRecord] = []
        await RoomMutationGate.shared.withQuiescence {
            resetRoomProjectionSyncForPrivacyDeletion()
            let runtime = RoomRuntime.shared
            let tasks = Array(runtime.driveTasks.values)
                + Array(runtime.postSettleHarvestTasks.values)
            for task in tasks { task.cancel() }
            for task in tasks { await task.value }
            // Local-data deletion does not mutate Hermes. In particular, an
            // accepted/uncertain prompt may still own queued provider payloads;
            // stripping them remotely would change an in-flight turn.
            do {
                try await runtime.store.deleteAll()
            } catch RoomStoreError.deleteCleanupFailed {
                // The empty index is authoritative, so no room can resurrect;
                // clear runtime but surface that residual files may remain.
                resetRoomRuntimeAfterDeletion(runtime)
                deletionError = RoomStoreError.deleteCleanupFailed
            } catch {
                // Empty-index publication failed. Preserve the in-memory world
                // so Settings cannot claim erasure or hide data that remains.
                // The quiescence boundary already cancelled every owner;
                // replace those stale task slots and resume exactly from the
                // durable drive/attempt ledger—never by replaying a prompt.
                runtime.driveTasks.removeAll()
                runtime.driveTokens.removeAll()
                runtime.postSettleHarvestTasks.removeAll()
                runtime.postSettleHarvestTokens.removeAll()
                roomsToResume = runtime.rooms
                deletionError = error
            }
            if deletionError == nil { resetRoomRuntimeAfterDeletion(runtime) }
        }
        // Resume after exclusive deletion admission reopens. A task created
        // while the quiescence owner is unwinding could otherwise inherit a
        // stale cancellation/admission boundary and never run.
        for room in roomsToResume {
            if !room.drives.isEmpty { scheduleRoomDrive(roomID: room.id) }
            else if room.attempts.contains(where: { $0.finishedAt == nil }) {
                scheduleRoomReconciliation(roomID: room.id)
            }
        }
        if let deletionError { throw deletionError }
    }

    private func resetRoomRuntimeAfterDeletion(_ runtime: RoomRuntime) {
            runtime.driveTasks.removeAll()
            runtime.driveTokens.removeAll()
            runtime.postSettleHarvestTasks.removeAll()
            runtime.postSettleHarvestTokens.removeAll()
            runtime.rooms = []
            runtime.avatarData = [:]
            runtime.openRoomID = nil
            runtime.loadError = nil
            runtime.metadataPendingCount = 0
            runtime.metadataLastError = nil
            runtime.profileLifecycleError = nil
            for task in runtime.composerDraftTasks.values { task.cancel() }
            runtime.composerDraftTasks.removeAll()
            runtime.composerDraftGenerations.removeAll()
            runtime.composerDrafts.removeAll()
            runtime.composerDraftErrors.removeAll()
            runtime.isLoaded = false
            runtime.pendingPrompts.removeAll()
            runtime.answeredPromptQuestions.removeAll()
            runtime.profileRouteGenerations.removeAll()
            runtime.retiredProfileRoutes.removeAll()
            runtime.deferredProfileRearmRooms.removeAll()
    }

    /// Root integration hook: call once when the roster shell appears. It is
    /// idempotent and resumes only durable queued/running drives.
    func loadRooms() async {
        _ = try? await RoomMutationGate.shared.withLock("load") {
            await loadRoomsUnlocked()
        }
        await flushRoomMetadataOutbox()
    }

    private func loadRoomsUnlocked() async {
        let runtime = RoomRuntime.shared
        guard !runtime.isLoaded else { return }
        do {
            let loaded: [RoomRecord]
            if let operation = runtime.loadOperation {
                loaded = try await operation()
            } else {
                _ = try await runtime.store.loadAll()
                let cachedProjection = try await runtime.store.roomProjection()
                let reconciled = try await runtime.store.reconcileRoomProjection(
                    cachedProjection)
                loaded = reconciled.rooms
                for roomID in reconciled.clearedImageRoomIDs {
                    runtime.avatarData[roomID] = nil
                }
                for (roomID, data) in reconciled.projectedImages {
                    runtime.avatarData[roomID] = data
                }
            }
            runtime.rooms = loaded.sorted { $0.lastActivityAt > $1.lastActivityAt }
            runtime.retiredProfileRoutes = (try? await runtime.store.retiredMetadataRoutes()) ?? []
            for room in loaded {
                if let avatar = room.avatar,
                   let data = try? await runtime.store.readBlob(roomID: room.id, attachment: avatar) {
                    runtime.avatarData[room.id] = data
                }
            }
            runtime.loadError = nil
            runtime.isLoaded = true
            if let gatewayID = LiveRuntime.shared.gatewayID {
                await pullAndReseedRoomProjection(gatewayID: gatewayID)
            }
            for room in runtime.rooms {
                if !room.drives.isEmpty { scheduleRoomDrive(roomID: room.id) }
                else if room.attempts.contains(where: { $0.finishedAt == nil }) {
                    scheduleRoomReconciliation(roomID: room.id)
                }
            }
        } catch {
            runtime.loadError = error.localizedDescription
        }
    }

    /// Members come from the union roster and are source-qualified before
    /// persistence, so duplicate profile names on two gateways never collide.
    @discardableResult
    func createRoom(name: String, members: [RoomMember]) async throws -> RoomID {
        try await RoomMutationGate.shared.withLocks([
            RoomMutationGate.roomNameNamespaceKey,
            RoomMutationGate.metadataOutboxKey,
        ]) {
            let roomID = try await createRoomUnlocked(name: name, members: members)
            await flushRoomMetadataOutboxAlreadyAdmitted()
            return roomID
        }
    }

    private func createRoomUnlocked(name: String, members proposedMembers: [RoomMember]) async throws -> RoomID {
        let existing = try await RoomRuntime.shared.store.loadAll().map(\.name)
        let trimmed = try RoomNamePolicy.unique(name, existing: existing)
        let unique = proposedMembers.reduce(into: [RoomMember]()) { members, member in
            if !members.contains(where: { $0.route == member.route }) { members.append(member) }
        }
        if let retired = unique.first(where: { RoomRuntime.shared.retiredProfileRoutes.contains($0.route) }) {
            throw RoomStoreError.retiredRoute(retired.route)
        }
        await RoomRuntime.shared.roomNameCommitBarrier?()
        var record = RoomRecord(name: trimmed, members: unique)
        try RoomEngine.validate(record)
        record.updatedAt = Date()
        let metadata = record.members.map {
            RoomMetadataMutation(route: $0.route, kind: .add, newName: record.name)
        }
        try await RoomRuntime.shared.store.upsert(record, metadataMutations: metadata)
        RoomRuntime.shared.replace(record)
        RoomRuntime.shared.openRoomID = record.id
        scheduleRoomProjectionSync(changedRooms: [roomProjectionKey(record)])
        return record.id
    }

    func renameRoom(_ roomID: RoomID, name: String) async throws {
        try await RoomMutationGate.shared.withLocks([
            RoomMutationGate.roomNameNamespaceKey, roomID.description,
            RoomMutationGate.metadataOutboxKey,
        ]) {
            try await renameRoomUnlocked(roomID, name: name)
            await flushRoomMetadataOutboxAlreadyAdmitted()
        }
    }

    func updateRoomSettings(_ roomID: RoomID, name: String, members proposedMembers: [RoomMember],
                            avatar: RoomOutboundAttachment? = nil,
                            removeAvatar: Bool = false) async throws {
        try await RoomMutationGate.shared.withLocks([
            RoomMutationGate.roomNameNamespaceKey, roomID.description,
            RoomMutationGate.metadataOutboxKey,
        ]) {
            guard let before = try await RoomRuntime.shared.store.room(id: roomID) else {
                throw RoomStoreError.roomNotFound(roomID)
            }
            let normalized = try RoomNamePolicy.normalized(name)
            let otherNames = try await RoomRuntime.shared.store.loadAll()
                .filter { $0.id != roomID }.map { $0.name.lowercased() }
            guard !otherNames.contains(normalized.lowercased()) else { throw RoomNameError.taken }
            await RoomRuntime.shared.roomNameCommitBarrier?()

            let proposed = proposedMembers.reduce(into: [RoomMember]()) { result, member in
                if !result.contains(where: { $0.route == member.route }) { result.append(member) }
            }
            // A projected member whose connection is not configured on this
            // device is a view-only seat. Preserve the authoritative record if
            // a caller omits or attempts to rewrite it. Projection hydration,
            // which verifies configured connection ids, owns thawing the seat.
            let members = before.members.filter(\.isFrozenProjection).reduce(into: proposed) {
                result, frozen in
                if let proposedIndex = result.firstIndex(where: { $0.route == frozen.route }) {
                    result[proposedIndex] = frozen
                } else {
                    result.append(frozen)
                }
            }
            if let retired = members.first(where: { RoomRuntime.shared.retiredProfileRoutes.contains($0.route) }) {
                throw RoomStoreError.retiredRoute(retired.route)
            }
            guard (RoomEngine.minimumMembers...RoomEngine.maximumMembers).contains(members.count) else {
                throw RoomValidationError.memberCount(members.count)
            }
            let activeRoutes = Set(members.map(\.route))
            let membershipChanged = activeRoutes != Set(before.members.map(\.route))
            let removed = before.members.filter { !activeRoutes.contains($0.route) }
            if before.attempts.contains(where: { attempt in
                removed.contains(where: { $0.route == attempt.member }) && attempt.finishedAt == nil
            }) { throw RoomSettingsError.memberBusy }
            // A prompt is live-only and can arrive a poll before the durable
            // attempt state changes. Removing that seat would strand the
            // source-qualified answer, so fail closed in either representation.
            if RoomRuntime.shared.pendingPrompts.keys.contains(where: { key in
                key.roomID == roomID && removed.contains(where: { $0.route == key.route })
            }) { throw RoomSettingsError.memberBusy }

            var storedAvatar: RoomAttachment?
            if let avatar {
                storedAvatar = try await RoomRuntime.shared.store.storeBlob(
                    roomID: roomID, data: avatar.data, fileName: avatar.name,
                    mediaType: AttachmentEncoder.mimeType(forFilename: avatar.name))
            }
            let avatarToStore = storedAvatar
            let beforeRoutes = Set(before.members.map(\.route))
            let afterRoutes = Set(members.map(\.route))
            var metadata: [RoomMetadataMutation] = before.members
                .filter { !$0.isFrozenProjection && !afterRoutes.contains($0.route) }
                .map { RoomMetadataMutation(route: $0.route, kind: .remove,
                                            oldName: before.name) }
            metadata += members.filter {
                !$0.isFrozenProjection && !beforeRoutes.contains($0.route)
            }.map {
                RoomMetadataMutation(route: $0.route, kind: .add, newName: normalized)
            }
            if before.name != normalized {
                metadata += members.filter {
                    !$0.isFrozenProjection && beforeRoutes.contains($0.route)
                }.map {
                    RoomMetadataMutation(route: $0.route, kind: .rename,
                                         oldName: before.name, newName: normalized)
                }
            }
            let previousProjectionKey = roomProjectionKey(before)
            let promotesLegacyProjection = before.name != normalized
                && previousProjectionKey.hasPrefix("name:")
            let promotedProjectionKey = RoomProjectionEnvelope.idKey(
                before.id.description)
            let changedProjectionKey = promotesLegacyProjection
                ? promotedProjectionKey : previousProjectionKey
            let projectionIntent = RoomProjectionMergeIntent(
                changedRooms: [changedProjectionKey],
                deletedRooms: promotesLegacyProjection ? [previousProjectionKey] : [],
                writeRevision: before.rawProjectionRevision == .max
                    ? .max : before.rawProjectionRevision + 1,
                clearedImages: removeAvatar ? [changedProjectionKey] : [])
            let result: RoomRecord
            do {
                result = try await RoomRuntime.shared.store.mutate(
                    roomID: roomID, metadataMutations: metadata,
                    projectionIntent: projectionIntent
                ) { current in
                    if promotesLegacyProjection {
                        // A legacy name-key maps its local UUID from the old
                        // name and therefore cannot be re-keyed to another
                        // name without changing protected RoomID. Promote the
                        // rename to this room's immutable local id and retire
                        // the old migration key with the sync intent below.
                        current.rawProjectionRoomKey = RoomProjectionEnvelope.idKey(
                            current.id.description)
                    }
                    current.name = normalized
                    let currentRoutes = Set(members.map(\.route))
                    if membershipChanged {
                        current.epoch &+= 1
                        current.drives.removeAll()
                        current.activity.removeAll()
                    }
                    let departed = current.members.filter { !currentRoutes.contains($0.route) }
                    for member in departed where !current.formerMembers.contains(where: { $0.route == member.route }) {
                        current.formerMembers.append(member)
                    }
                    current.formerMembers.removeAll { currentRoutes.contains($0.route) }
                    current.members = members
                    if removeAvatar { current.avatar = nil }
                    else if let avatarToStore { current.avatar = avatarToStore }
                    current.updatedAt = Date()
                }
            } catch {
                _ = try? await RoomRuntime.shared.store.pruneOrphanedBlobs()
                throw error
            }

            _ = try? await RoomRuntime.shared.store.pruneOrphanedBlobs()
            if let avatar { RoomRuntime.shared.avatarData[roomID] = avatar.data }
            else if removeAvatar { RoomRuntime.shared.avatarData[roomID] = nil }
            RoomRuntime.shared.replace(result)
            scheduleRoomProjectionSync(
                changedRooms: [changedProjectionKey],
                deletedRooms: promotesLegacyProjection ? [previousProjectionKey] : []
            )
            await flushRoomMetadataOutboxAlreadyAdmitted()
        }
    }

    private func renameRoomUnlocked(_ roomID: RoomID, name: String) async throws {
        guard var room = try await RoomRuntime.shared.store.room(id: roomID) else {
            throw RoomStoreError.roomNotFound(roomID)
        }
        let oldName = room.name
        let normalized = try RoomNamePolicy.normalized(name)
        let otherNames = try await RoomRuntime.shared.store.loadAll()
            .filter { $0.id != roomID }.map { $0.name.lowercased() }
        guard !otherNames.contains(normalized.lowercased()) else { throw RoomNameError.taken }
        await RoomRuntime.shared.roomNameCommitBarrier?()
        let metadata = room.members.filter { !$0.isFrozenProjection }.map {
            RoomMetadataMutation(route: $0.route, kind: .rename,
                                 oldName: oldName, newName: normalized)
        }
        let previousProjectionKey = roomProjectionKey(room)
        let promotesLegacyProjection = room.name != normalized
            && previousProjectionKey.hasPrefix("name:")
        let promotedProjectionKey = RoomProjectionEnvelope.idKey(room.id.description)
        let changedProjectionKey = promotesLegacyProjection
            ? promotedProjectionKey : previousProjectionKey
        let projectionIntent = RoomProjectionMergeIntent(
            changedRooms: [changedProjectionKey],
            deletedRooms: promotesLegacyProjection ? [previousProjectionKey] : [],
            writeRevision: room.rawProjectionRevision == .max
                ? .max : room.rawProjectionRevision + 1)
        room = try await RoomRuntime.shared.store.mutate(
            roomID: roomID, metadataMutations: metadata,
            projectionIntent: projectionIntent
        ) { current in
            if promotesLegacyProjection {
                current.rawProjectionRoomKey = RoomProjectionEnvelope.idKey(
                    current.id.description)
            }
            current.name = normalized
            current.updatedAt = Date()
        }
        RoomRuntime.shared.replace(room)
        scheduleRoomProjectionSync(
            changedRooms: [changedProjectionKey],
            deletedRooms: promotesLegacyProjection ? [previousProjectionKey] : []
        )
    }

    /// Invalidate/persist first, cancel and await the sole driver second,
    /// delete durable room+blobs third, retire navigation last.
    func disbandRoom(_ roomID: RoomID) async throws {
        try await RoomMutationGate.shared.withLocks([
            roomID.description, RoomMutationGate.metadataOutboxKey,
        ]) {
            try await disbandRoomUnlocked(roomID)
            await flushRoomMetadataOutboxAlreadyAdmitted()
        }
    }

    private func disbandRoomUnlocked(_ roomID: RoomID) async throws {
        let runtime = RoomRuntime.shared
        guard var room = try await runtime.store.room(id: roomID) else {
            throw RoomStoreError.roomNotFound(roomID)
        }
        room = try await runtime.store.mutate(roomID: roomID) { current in
            current.epoch &+= 1
            for index in current.attempts.indices where current.attempts[index].finishedAt == nil {
                current.attempts[index].state = .cancelled
                current.attempts[index].finishedAt = Date()
                current.attempts[index].outboundAttachments = []
            }
            current.drives.removeAll()
            RoomEngine.recordActivity(RoomActivity(epoch: current.epoch, kind: .cancelled), in: &current)
        }
        runtime.replace(room)

        let task = runtime.driveTasks[roomID]
        let harvestTask = runtime.postSettleHarvestTasks[roomID]
        task?.cancel()
        harvestTask?.cancel()
        await task?.value
        await harvestTask?.value
        // Explicit disband proves these uncertain turns are abandoned. Undo
        // any queued image/PDF state before deleting the durable path ledger.
        for attempt in room.attempts where !attempt.stagedImagePaths.isEmpty {
            if let client = try? await routedClient(for: attempt.member) {
                await client.detachRoomStagedImages(attempt.stagedImagePaths,
                                                   sessionID: attempt.runtimeSessionID)
            }
        }
        let metadata = room.members.filter { !$0.isFrozenProjection }.map {
            RoomMetadataMutation(route: $0.route, kind: .remove, oldName: room.name)
        }
        let projectionKey = roomProjectionKey(room)
        let nextRevision = room.rawProjectionRevision == .max
            ? UInt64.max : room.rawProjectionRevision + 1
        // Publish the anti-resurrection fact to protected storage before the
        // rich record disappears. A crash between these commits may leave a
        // room beside its tombstone, but it can never lose the tombstone and
        // later republish the disbanded immutable id.
        _ = try await runtime.store.mergeRoomProjection(
            RoomProjectionEnvelope(),
            intent: RoomProjectionMergeIntent(
                deletedRooms: [projectionKey], writeRevision: nextRevision
            )
        )
        try await runtime.store.delete(roomID: roomID, metadataMutations: metadata)
        runtime.retireComposerDraft(roomID)
        runtime.driveTasks[roomID] = nil
        runtime.driveTokens[roomID] = nil
        runtime.postSettleHarvestTasks[roomID] = nil
        runtime.postSettleHarvestTokens[roomID] = nil
        runtime.clearPendingPrompts(roomID: roomID)
        runtime.remove(roomID)
        scheduleRoomProjectionSync(
            allowEmpty: true, deletedRooms: [projectionKey]
        )
    }

    /// Main composer mints a stable topic; a reply supplies its thread id.
    /// Blobs commit before the entry references them.
    @discardableResult
    func sendRoomMessage(roomID: RoomID, text: String,
                         threadID: RoomThreadID? = nil,
                         attachments: [RoomOutboundAttachment] = []) async throws -> RoomThreadID {
        try await RoomMutationGate.shared.withLock(roomID.description) {
            try await sendRoomMessageUnlocked(roomID: roomID, text: text,
                                              threadID: threadID, attachments: attachments)
        }
    }

    private func sendRoomMessageUnlocked(roomID: RoomID, text: String,
                                         threadID: RoomThreadID?,
                                         attachments: [RoomOutboundAttachment]) async throws -> RoomThreadID {
        let runtime = RoomRuntime.shared
        guard let existing = try await runtime.store.room(id: roomID) else {
            throw RoomStoreError.roomNotFound(roomID)
        }
        guard !existing.members.contains(where: {
            runtime.retiredProfileRoutes.contains($0.route)
        }) else { throw CancellationError() }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !attachments.isEmpty else {
            throw GatewayError(code: -8, message: "A room message cannot be empty.")
        }

        // Revoke an old post-settle owner before the epoch changes or blob
        // staging suspends. Cancelling only from `scheduleRoomDrive` left a
        // wide attachment-write window in which an E harvest could publish a
        // reply into the new E+1 send.
        runtime.cancelPostSettleHarvest(roomID: roomID)

        let target = threadID ?? RoomThreadID()
        let room = try await runtime.store.mutate(roomID: roomID) { current in
            current.epoch &+= 1
            current.needsUser = false
            current.activity.removeAll()
            if let threadID {
                guard current.threads.contains(where: { $0.id == threadID }) else {
                    throw RoomValidationError.unknownThread
                }
            } else {
                current.threads.append(RoomThread(id: target))
            }
        }
        var storedAttachments: [RoomAttachment] = []
        do {
            for attachment in attachments {
                let mediaType: String = switch attachment.kind {
                case .image: AttachmentEncoder.mimeType(forFilename: attachment.name)
                case .pdf: "application/pdf"
                case .file: AttachmentEncoder.mimeType(forFilename: attachment.name)
                }
                storedAttachments.append(try await runtime.store.storeBlob(
                    roomID: roomID, data: attachment.data, fileName: attachment.name,
                    mediaType: mediaType))
            }
        } catch {
            _ = try? await runtime.store.pruneOrphanedBlobs()
            throw error
        }

        let expectedEpoch = room.epoch
        let attachmentsToStore = storedAttachments
        let final: RoomRecord
        do {
            final = try await runtime.store.mutate(roomID: roomID) { current in
                // This public mutation gate prevents another send, while an
                // older driver may only observe supersession and retire.
                guard current.epoch == expectedEpoch else { throw CancellationError() }
                try RoomEngine.append(RoomEntry(threadID: target, speaker: .user,
                                                speakerName: "You", text: body,
                                                attachments: attachmentsToStore), to: &current)
                current.drives.removeAll { $0.epoch != current.epoch }
                current.drives.append(RoomDriveState(threadID: target, epoch: current.epoch))
                RoomEngine.recordActivity(RoomActivity(epoch: current.epoch, kind: .queued,
                                                       threadID: target), in: &current)
            }
        } catch {
            _ = try? await runtime.store.pruneOrphanedBlobs()
            throw error
        }
        runtime.replace(final)
        scheduleRoomProjectionSync(changedRooms: [roomProjectionKey(final)])
        scheduleRoomDrive(roomID: roomID)
        return target
    }
}

// MARK: - Serialized driver

extension AppModel {
    /// Capture only durable identity supplied by Hermes/Bot Mode. A themed
    /// roster label (for example Ink's uppercase alias or a remote-default
    /// device label) is presentation and must never become a room mention.
    func capturedRoomMember(for bot: Bot, route: GatewayBotRoute,
                            sourceLabel: String?) -> RoomMember {
        let title = bot.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitTitle = title?.isEmpty == false ? title : nil
        let display = bot.rawDisplayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawDisplay = display?.isEmpty == false ? display : nil
        return RoomMember(route: route, title: explicitTitle, handle: bot.handle,
                          sourceLabel: sourceLabel,
                          friendlyName: explicitTitle ?? rawDisplay,
                          rawDisplayName: rawDisplay)
    }

    func flushRoomMetadataOutbox() async {
        _ = try? await RoomMutationGate.shared.withLock(
            RoomMutationGate.metadataOutboxKey
        ) {
            await flushRoomMetadataOutboxAlreadyAdmitted()
        }
    }

    /// Drain the durable FIFO while the caller already owns the metadata-outbox
    /// key under one RoomMutationGate admission. Room create/rename/settings/
    /// disband use this path so delete-all quiescence can wait for the outer
    /// owner without blocking a nested admission that owner needs to finish.
    private func flushRoomMetadataOutboxAlreadyAdmitted() async {
        let runtime = RoomRuntime.shared
        let mutations: [RoomMetadataMutation]
        do { mutations = try await runtime.store.metadataOutbox() }
        catch {
            runtime.metadataLastError = error.localizedDescription
            return
        }
        runtime.metadataPendingCount = mutations.count
        if mutations.isEmpty { runtime.metadataLastError = nil; return }
        var blockedRoutes = Set<GatewayBotRoute>()
        for mutation in mutations {
            guard !blockedRoutes.contains(mutation.route) else { continue }
            let generation = runtime.profileRouteGeneration(mutation.route)
            guard runtime.acceptsProfileRoute(mutation.route, generation: generation) else {
                blockedRoutes.insert(mutation.route)
                continue
            }
            do {
                if let operation = runtime.metadataMutationOperation {
                    try await operation(mutation)
                } else {
                    try await applyRoomMetadataMutation(mutation)
                }
                // A committed profile rename may have rewritten this same id
                // while the network request was suspended. Do not let the old
                // completion remove the destination mutation.
                guard runtime.acceptsProfileRoute(mutation.route,
                                                  generation: generation) else {
                    blockedRoutes.insert(mutation.route)
                    continue
                }
                try await runtime.store.removeMetadataMutation(
                    id: mutation.id, matching: mutation)
                runtime.metadataPendingCount = max(0, runtime.metadataPendingCount - 1)
                runtime.metadataLastError = nil
            } catch {
                // Keep the exact source-qualified mutation durable. A later
                // union-roster refresh/reconnect retries it in order.
                runtime.metadataLastError = error.localizedDescription
                blockedRoutes.insert(mutation.route)
            }
        }
    }

    private func applyRoomMetadataMutation(_ mutation: RoomMetadataMutation) async throws {
        let client = try await routedClient(for: mutation.route)
        try await withBotModeMetaMutation(route: mutation.route) {
            let profiles = try await client.listProfiles(includeSessions: false)
            guard let profile = profiles.first(where: { $0.name == mutation.route.profile }) else {
                throw GatewayError(code: -8, message: "Room member profile is unavailable.")
            }
            var block = profile.uiMeta?["hermes-bots"]?.objectValue ?? [:]
            var groups = BotModeMeta(uiMeta: profile.uiMeta)?.groups ?? []
            switch mutation.kind {
            case .add:
                guard let name = mutation.newName, !name.isEmpty else {
                    throw GatewayError(code: -8, message: "Room metadata add is malformed.")
                }
                if !groups.contains(name) { groups.append(name) }
            case .remove:
                guard let name = mutation.oldName, !name.isEmpty else {
                    throw GatewayError(code: -8, message: "Room metadata removal is malformed.")
                }
                groups.removeAll { $0 == name }
            case .rename:
                guard let oldName = mutation.oldName, let newName = mutation.newName,
                      !oldName.isEmpty, !newName.isEmpty else {
                    throw GatewayError(code: -8, message: "Room metadata rename is malformed.")
                }
                // Desktop maps the existing ordered membership in place.
                // Appending would change the legacy `group` projection when
                // the renamed room was first in the array.
                groups = BotModeMeta.replacingGroup(oldName, with: newName, in: groups)
            }
            for (key, value) in BotModeMeta.membershipProjection(groups) { block[key] = value }
            let applied = try await client.applyProfileEdit(
                name: mutation.route.profile,
                ProfileEdit(uiMeta: .object(["hermes-bots": .object(block)])))
            guard applied["ui_meta"] == true else {
                throw GatewayError(code: -8, message: "Hermes did not confirm room metadata.")
            }
        }
    }

    func scheduleRoomDrive(roomID: RoomID) {
        let runtime = RoomRuntime.shared
        runtime.cancelPostSettleHarvest(roomID: roomID)
        let prior = runtime.driveTasks[roomID]
        let token = UUID()
        runtime.driveTokens[roomID] = token
        let next = Task { @MainActor [weak self] in
            await prior?.value
            guard !Task.isCancelled, let self else { return }
            if let operation = RoomRuntime.shared.driveOperation {
                await operation(self, roomID)
            } else {
                await self.runRoomDrive(roomID: roomID)
            }
            if RoomRuntime.shared.driveTokens[roomID] == token {
                RoomRuntime.shared.driveTasks[roomID] = nil
                RoomRuntime.shared.driveTokens[roomID] = nil
            }
        }
        runtime.driveTasks[roomID] = next
    }

    func scheduleRoomReconciliation(roomID: RoomID) {
        let runtime = RoomRuntime.shared
        runtime.cancelPostSettleHarvest(roomID: roomID)
        let prior = runtime.driveTasks[roomID]
        let token = UUID()
        runtime.driveTokens[roomID] = token
        let next = Task { @MainActor [weak self] in
            await prior?.value
            guard !Task.isCancelled, let self,
                  let room = try? await RoomRuntime.shared.store.room(id: roomID) else { return }
            await self.harvestRoomAttempts(roomID: roomID, epoch: room.epoch)
            if !Task.isCancelled,
               let refreshed = try? await RoomRuntime.shared.store.room(id: roomID),
               refreshed.drives.contains(where: { $0.epoch == refreshed.epoch }) {
                await self.runRoomDrive(roomID: roomID)
            } else if !Task.isCancelled,
                      let refreshed = try? await RoomRuntime.shared.store.room(id: roomID),
                      refreshed.epoch == room.epoch,
                      Self.hasStrandedRoomAttempts(refreshed) {
                // Relaunch/reconnect reconciliation has no drive to settle,
                // but owns the same durable stranded-work obligation.
                self.schedulePostSettleRoomHarvest(roomID: roomID, epoch: room.epoch)
            }
            if RoomRuntime.shared.driveTokens[roomID] == token {
                RoomRuntime.shared.driveTasks[roomID] = nil
                RoomRuntime.shared.driveTokens[roomID] = nil
            }
        }
        runtime.driveTasks[roomID] = next
    }

    /// c1e25-style background reconciliation for work that outlived the room
    /// drive. It is bounded, source/epoch fenced, and independently
    /// cancellable so a new user send or disband cannot race an old harvest.
    func schedulePostSettleRoomHarvest(roomID: RoomID, epoch: UInt64) {
        let runtime = RoomRuntime.shared
        runtime.cancelPostSettleHarvest(roomID: roomID)
        guard runtime.postSettleHarvestLimit > 0 else { return }
        let token = UUID()
        runtime.postSettleHarvestTokens[roomID] = token
        let interval = runtime.postSettleHarvestInterval
        let limit = runtime.postSettleHarvestLimit
        let task = Task { @MainActor [weak self] in
            defer {
                if RoomRuntime.shared.postSettleHarvestTokens[roomID] == token {
                    RoomRuntime.shared.postSettleHarvestTasks[roomID] = nil
                    RoomRuntime.shared.postSettleHarvestTokens[roomID] = nil
                }
            }
            for _ in 0..<limit {
                do { try await Task.sleep(for: interval) }
                catch { return }
                guard !Task.isCancelled, let self,
                      RoomRuntime.shared.postSettleHarvestTokens[roomID] == token,
                      RoomRuntime.shared.driveTokens[roomID] == nil,
                      let room = try? await RoomRuntime.shared.store.room(id: roomID),
                      room.epoch == epoch else { return }
                guard Self.hasStrandedRoomAttempts(room) else { return }
                await self.harvestRoomAttempts(roomID: roomID, epoch: epoch,
                                               harvestToken: token)
            }
        }
        runtime.postSettleHarvestTasks[roomID] = task
    }

    /// Revalidate a reconciliation owner after every suspension. `epoch` is
    /// the room snapshot the caller owns (not necessarily the attempt's epoch:
    /// a new serialized drive may deliberately reconcile older accepted work).
    /// A post-settle token additionally prevents an older task from publishing
    /// after a same-epoch replacement scheduler took ownership.
    private func roomHarvestOwnerIsCurrent(roomID: RoomID, epoch: UInt64,
                                           harvestToken: UUID?) async -> Bool {
        guard !Task.isCancelled else { return false }
        if let harvestToken,
           RoomRuntime.shared.postSettleHarvestTokens[roomID] != harvestToken {
            return false
        }
        guard let room = try? await RoomRuntime.shared.store.room(id: roomID),
              room.epoch == epoch else { return false }
        guard !Task.isCancelled else { return false }
        if let harvestToken,
           RoomRuntime.shared.postSettleHarvestTokens[roomID] != harvestToken {
            return false
        }
        return true
    }

    private nonisolated static func hasStrandedRoomAttempts(_ room: RoomRecord) -> Bool {
        room.attempts.contains {
            $0.finishedAt == nil
                && [.waiting, .accepted, .uncertain, .working, .timedOut]
                    .contains($0.state)
        }
    }

    private func roomRouteGenerationSnapshot(_ room: RoomRecord)
        -> [GatewayBotRoute: UInt64] {
        var routes = Set(room.members.map(\.route))
        routes.formUnion(room.formerMembers.map(\.route))
        routes.formUnion(room.attempts.map(\.member))
        routes.formUnion(room.drives.flatMap(\.roundMembers))
        routes.formUnion(room.activity.compactMap(\.member))
        routes.formUnion(room.memberSessions.keys.compactMap(GatewayBotRoute.init(qualifiedID:)))
        return Dictionary(uniqueKeysWithValues: routes.map {
            ($0, RoomRuntime.shared.profileRouteGeneration($0))
        })
    }

    private func acceptsRoomRouteGenerations(
        _ generations: [GatewayBotRoute: UInt64]
    ) -> Bool {
        generations.allSatisfy {
            RoomRuntime.shared.acceptsProfileRoute($0.key, generation: $0.value)
        }
    }

    func runRoomDrive(roomID: RoomID) async {
        let runtime = RoomRuntime.shared
        guard let initial = try? await runtime.store.room(id: roomID) else { return }
        let routeGenerations = roomRouteGenerationSnapshot(initial)
        while !Task.isCancelled {
            guard acceptsRoomRouteGenerations(routeGenerations) else { return }
            guard var room = try? await runtime.store.room(id: roomID),
                  let driveIndex = room.drives.firstIndex(where: { $0.epoch == room.epoch })
            else { return }
            var drive = room.drives[driveIndex]
            guard drive.round < RoomEngine.maximumRounds,
                  drive.posted < RoomEngine.maximumPosts else {
                guard acceptsRoomRouteGenerations(routeGenerations) else { return }
                await settleRoomDrive(roomID: roomID, epoch: drive.epoch,
                                      threadID: drive.threadID,
                                      routeGenerations: routeGenerations)
                return
            }

            // Late-result reconciliation precedes any new selection.
            await harvestRoomAttempts(roomID: roomID, epoch: drive.epoch)
            guard acceptsRoomRouteGenerations(routeGenerations) else { return }
            guard let refreshed = try? await runtime.store.room(id: roomID),
                  refreshed.epoch == drive.epoch,
                  let refreshedDrive = refreshed.drives.first(where: { $0.epoch == drive.epoch })
            else { return }
            room = refreshed
            drive = refreshedDrive

            let responders: [RoomMember]
            if drive.roundMembers.isEmpty {
                responders = RoomEngine.scheduledResponders(
                    entries: room.entries, members: room.members, threadID: drive.threadID,
                    round: drive.round, posted: drive.posted)
                drive.roundMembers = responders.map(\.route)
                let driveToPersist = drive
                let expectedEpoch = drive.epoch
                guard acceptsRoomRouteGenerations(routeGenerations) else { return }
                guard let updated = try? await runtime.store.mutate(roomID: roomID, { current in
                    guard current.epoch == expectedEpoch,
                          let index = current.drives.firstIndex(where: { $0.epoch == expectedEpoch })
                    else { throw CancellationError() }
                    current.drives[index] = driveToPersist
                }) else { return }
                room = updated
                runtime.replace(updated)
            } else {
                responders = drive.roundMembers.compactMap { route in
                    room.members.first { $0.route == route }
                }
            }
            if responders.isEmpty || drive.nextMemberIndex >= responders.count {
                // Durable roundStartPosted keeps this correct after a crash in
                // the middle of a round.
                if drive.posted == drive.roundStartPosted {
                    guard acceptsRoomRouteGenerations(routeGenerations) else { return }
                    await settleRoomDrive(roomID: roomID, epoch: drive.epoch,
                                          threadID: drive.threadID,
                                          routeGenerations: routeGenerations)
                    return
                }
                drive.round += 1
                drive.roundMembers = []
                drive.nextMemberIndex = 0
                drive.roundStartPosted = drive.posted
                drive.status = .running
                drive.updatedAt = Date()
                let driveToPersist = drive
                let expectedEpoch = drive.epoch
                guard acceptsRoomRouteGenerations(routeGenerations) else { return }
                guard let updated = try? await runtime.store.mutate(roomID: roomID, { current in
                    guard current.epoch == expectedEpoch,
                          let index = current.drives.firstIndex(where: { $0.epoch == expectedEpoch })
                    else { throw CancellationError() }
                    current.drives[index] = driveToPersist
                }) else { return }
                runtime.replace(updated)
                continue
            }

            let member = responders[drive.nextMemberIndex]
            guard runtime.acceptsProfileRoute(
                member.route, generation: routeGenerations[member.route] ?? 0) else { return }
            await runRoomMemberBoundary(roomID: roomID, epoch: drive.epoch,
                                        threadID: drive.threadID, member: member)
            guard acceptsRoomRouteGenerations(routeGenerations) else { return }

            let expectedEpoch = drive.epoch
            if let parked = try? await runtime.store.room(id: roomID),
               parked.epoch == expectedEpoch,
               parked.attempts.contains(where: {
                   $0.epoch == expectedEpoch && $0.member == member.route
                       && $0.state == .waiting && $0.finishedAt == nil
               }) {
                try? await Task.sleep(for: runtime.pollInterval)
                continue
            }
            guard acceptsRoomRouteGenerations(routeGenerations),
                  let nextRoom = try? await runtime.store.mutate(roomID: roomID, { current in
                guard current.epoch == expectedEpoch,
                      let index = current.drives.firstIndex(where: { $0.epoch == expectedEpoch })
                else { throw CancellationError() }
                current.drives[index].nextMemberIndex += 1
                current.drives[index].status = .running
                current.drives[index].updatedAt = Date()
            }) else { return }
            guard acceptsRoomRouteGenerations(routeGenerations) else { return }
            runtime.replace(nextRoom)
        }
    }

    func runRoomMemberBoundary(roomID: RoomID, epoch: UInt64,
                               threadID: RoomThreadID, member: RoomMember) async {
        let runtime = RoomRuntime.shared
        guard var room = try? await runtime.store.room(id: roomID), room.epoch == epoch else { return }
        let routeGeneration = runtime.profileRouteGeneration(member.route)
        guard runtime.acceptsProfileRoute(member.route, generation: routeGeneration) else { return }

        // An accepted/uncertain/timed-out attempt is stranded work. Harvest it
        // at boundaries; never submit a replacement into that session.
        if room.attempts.contains(where: {
            $0.member == member.route && $0.finishedAt == nil &&
                [.waiting, .accepted, .uncertain, .working, .timedOut].contains($0.state)
        }) {
            await harvestRoomAttempts(roomID: roomID, epoch: epoch, member: member.route)
            return
        }

        let key = RoomEngine.watermarkKey(threadID: threadID, member: member.route)
        let seen = room.watermarks[key] ?? 0
        let delta = Array(room.entries.dropFirst(min(seen, room.entries.count)))
            .filter { $0.threadID == threadID }
        guard !delta.isEmpty else { return }

        let client: GatewayClient
        do { client = try await routedClient(for: member.route) }
        catch {
            await persistRoomActivity(roomID: roomID, epoch: epoch, kind: .failed,
                                      member: member.route, threadID: threadID,
                                      routeGeneration: routeGeneration)
            return
        }
        guard runtime.acceptsProfileRoute(member.route, generation: routeGeneration) else { return }

        let session: RoomMemberSessionSnapshot
        do {
            session = try await client.ensureRoomSession(
                roomID: room.id,
                projectionRoomKey: room.rawProjectionRoomKey,
                sessionTitleIdentityVersion: room.sessionTitleIdentityVersion,
                legacySessionTitleName: room.legacySessionTitleName,
                profile: member.route.profile,
                storedID: room.memberSessions[member.route.qualifiedID])
        } catch {
            await persistRoomActivity(roomID: roomID, epoch: epoch, kind: .failed,
                                      member: member.route, threadID: threadID,
                                      routeGeneration: routeGeneration)
            return
        }
        guard runtime.acceptsProfileRoute(member.route, generation: routeGeneration) else { return }

        let prompt = roomTurnPrompt(room: room, viewer: member,
                                    delta: Array(delta.suffix(RoomEngine.historyLimit)))
        let exactAttachments = delta.flatMap(\.attachments)
        // `.working` is persisted BEFORE the network acceptance boundary. A
        // crash or local result-save failure can then only reconcile by exact
        // marker; it can never treat the turn as unsent and duplicate it.
        let initialState: RoomAttemptState = session.running ? .waiting : .working
        let attempt = RoomAttempt(threadID: threadID, member: member.route, epoch: epoch,
                                  promptText: prompt, storedSessionID: session.storedID,
                                  runtimeSessionID: session.runtimeID,
                                  outboundAttachments: exactAttachments, state: initialState,
                                  baselineMessageCount: session.messageCount)
        if session.running {
            // Durable wait proves no room prompt was submitted. Reconciliation
            // watches until idle, then settles this boundary without a blind
            // submission; a later round can consider fresh deltas normally.
            guard runtime.acceptsProfileRoute(member.route, generation: routeGeneration) else { return }
            if let waiting = try? await runtime.store.mutate(roomID: roomID, { current in
                guard current.epoch == epoch else { throw CancellationError() }
                current.memberSessions[member.route.qualifiedID] = session.storedID
                current.attempts.append(attempt)
                RoomEngine.recordActivity(RoomActivity(epoch: epoch, kind: .queued,
                                                       member: member.route, threadID: threadID),
                                          in: &current)
            }) {
                guard runtime.acceptsProfileRoute(member.route, generation: routeGeneration) else { return }
                runtime.replace(waiting)
            }
            return
        }

        guard runtime.acceptsProfileRoute(member.route, generation: routeGeneration) else { return }
        guard let persisted = try? await runtime.store.mutate(roomID: roomID, { current in
            guard current.epoch == epoch else { throw CancellationError() }
            current.memberSessions[member.route.qualifiedID] = session.storedID
            current.attempts.append(attempt)
            RoomEngine.recordActivity(RoomActivity(epoch: epoch, kind: .working,
                                                   member: member.route, threadID: threadID), in: &current)
        }) else { return }
        guard runtime.acceptsProfileRoute(member.route, generation: routeGeneration) else { return }
        room = persisted
        runtime.replace(persisted)

        let outbound = await roomOutboundAttachments(roomID: roomID,
                                                     descriptors: attempt.outboundAttachments)
        let submitted: RoomPromptSubmission
        if let operation = runtime.submitOperation {
            submitted = await operation(attempt, session, outbound)
        } else {
            submitted = await client.submitRoomPrompt(
                attempt: attempt, session: session,
                profile: member.route.profile, attachments: outbound)
        }

        guard runtime.acceptsProfileRoute(member.route, generation: routeGeneration) else { return }
        let saved = await persistRoomSubmission(roomID: roomID, attemptID: attempt.id,
                                                member: member.route, epoch: epoch,
                                                threadID: threadID, submitted: submitted,
                                                routeGeneration: routeGeneration)
        if saved, case .accepted = submitted.acceptance {
            await waitForRoomReply(roomID: roomID, attemptID: attempt.id)
        }
    }

    @discardableResult
    func persistRoomSubmission(roomID: RoomID, attemptID: RoomAttemptID,
                               member: GatewayBotRoute, epoch: UInt64,
                               threadID: RoomThreadID,
                               submitted: RoomPromptSubmission,
                               routeGeneration: UInt64? = nil) async -> Bool {
        let runtime = RoomRuntime.shared
        if let routeGeneration,
           !runtime.acceptsProfileRoute(member, generation: routeGeneration) { return false }
        guard let room = try? await runtime.store.mutate(roomID: roomID, { current in
            guard let index = current.attempts.firstIndex(where: { $0.id == attemptID })
            else { throw CancellationError() }
            guard current.attempts[index].member == member,
                  current.attempts[index].epoch == epoch else { throw CancellationError() }
            current.attempts[index].baselineMessageCount = submitted.baseline
            current.attempts[index].storedSessionID = submitted.storedID
            current.attempts[index].runtimeSessionID = submitted.runtimeID
            current.attempts[index].stagedImagePaths = submitted.stagedImagePaths
            switch submitted.acceptance {
            case .accepted:
                current.attempts[index].state = .accepted
                current.memberSessions[member.qualifiedID] = submitted.storedID
            case .uncertain:
                current.attempts[index].state = .uncertain
                RoomEngine.recordActivity(RoomActivity(epoch: epoch, kind: .uncertain,
                                                       member: member, threadID: threadID), in: &current)
            case .busy:
                current.attempts[index].state = .waiting
                RoomEngine.recordActivity(RoomActivity(epoch: epoch, kind: .queued,
                                                       member: member, threadID: threadID), in: &current)
            case .rejected:
                current.attempts[index].state = .failed
                current.attempts[index].finishedAt = Date()
                current.attempts[index].outboundAttachments = []
                RoomEngine.recordActivity(RoomActivity(epoch: epoch, kind: .failed,
                                                       member: member, threadID: threadID), in: &current)
            }
        }) else { return false }
        if let routeGeneration,
           !runtime.acceptsProfileRoute(member, generation: routeGeneration) { return false }
        runtime.replace(room)
        return true
    }

    /// A resume is the only authoritative observation of a hidden member
    /// prompt. Tests may substitute the read itself, but production always
    /// reacquires the client for the attempt's source-qualified route.
    private func readRoomSession(for attempt: RoomAttempt) async throws -> RoomMemberSessionSnapshot {
        if let operation = RoomRuntime.shared.sessionReadOperation {
            return try await operation(attempt)
        }
        let client = try await routedClient(for: attempt.member)
        return try await client.readRoomSession(storedID: attempt.storedSessionID,
                                                profile: attempt.member.profile)
    }

    func waitForRoomReply(roomID: RoomID, attemptID: RoomAttemptID) async {
        let runtime = RoomRuntime.shared
        let started = Date()
        var deadline = started.addingTimeInterval(runtime.baseTurnTimeout)
        while !Task.isCancelled, Date() < deadline {
            guard let current = try? await runtime.store.room(id: roomID),
                  let currentAttempt = current.attempts.first(where: { $0.id == attemptID }),
                  current.epoch == currentAttempt.epoch else { return }
            try? await Task.sleep(for: runtime.pollInterval)
            guard let room = try? await runtime.store.room(id: roomID),
                  let attempt = room.attempts.first(where: { $0.id == attemptID }),
                  attempt.finishedAt == nil,
                  room.epoch == attempt.epoch,
                  let member = room.members.first(where: { $0.route == attempt.member }),
                  let routeGeneration = Optional(runtime.profileRouteGeneration(attempt.member))
            else { return }
            guard runtime.acceptsProfileRoute(attempt.member,
                                              generation: routeGeneration) else { return }
            let session: RoomMemberSessionSnapshot
            do { session = try await readRoomSession(for: attempt) }
            catch {
                // A transient resume failure cannot dismiss a card or make a
                // durable attempt appear complete.
                return
            }
            guard await roomHarvestOwnerIsCurrent(roomID: roomID, epoch: attempt.epoch,
                                                  harvestToken: nil),
                  runtime.acceptsProfileRoute(attempt.member,
                                              generation: routeGeneration) else { return }
            runtime.synchronizePendingPrompt(roomID: roomID, attempt: attempt, snapshot: session)
            if session.awaitingUser {
                // A valid clarify/approval parks the member even when Hermes
                // reports `running: false`. Keep sliding the normal 180 s
                // window, bounded by the 20 minute hard cap.
                deadline = min(started.addingTimeInterval(runtime.hardTurnTimeout),
                               max(deadline, Date().addingTimeInterval(runtime.baseTurnTimeout)))
                continue
            }
            if let reply = session.assistantReply(for: attempt), !session.running {
                await finishRoomAttempt(roomID: roomID, attemptID: attemptID,
                                        member: member, reply: reply, delivered: false,
                                        routeGeneration: routeGeneration,
                                        expectedRoomEpoch: attempt.epoch)
                return
            }
            if session.running {
                deadline = min(started.addingTimeInterval(runtime.hardTurnTimeout),
                               max(deadline, Date().addingTimeInterval(runtime.baseTurnTimeout)))
            } else if session.containsAttempt(attempt) {
                // Accepted with no assistant row (tool-only/no output): pass.
                await finishRoomAttempt(roomID: roomID, attemptID: attemptID,
                                        member: member, reply: nil, delivered: false,
                                        routeGeneration: routeGeneration,
                                        expectedRoomEpoch: attempt.epoch)
                return
            }
        }
        guard let timeoutRoom = try? await runtime.store.room(id: roomID),
              let timeoutAttempt = timeoutRoom.attempts.first(where: { $0.id == attemptID }),
              runtime.acceptsProfileRoute(timeoutAttempt.member,
                                          generation: runtime.profileRouteGeneration(timeoutAttempt.member)),
              let room = try? await runtime.store.mutate(roomID: roomID, { current in
            guard let index = current.attempts.firstIndex(where: { $0.id == attemptID }),
                  current.attempts[index].finishedAt == nil,
                  current.epoch == current.attempts[index].epoch else { throw CancellationError() }
            current.attempts[index].state = .timedOut
            RoomEngine.recordActivity(RoomActivity(epoch: current.attempts[index].epoch,
                                                   kind: .timedOut,
                                                   member: current.attempts[index].member,
                                                   threadID: current.attempts[index].threadID), in: &current)
        }) else { return }
        guard runtime.acceptsProfileRoute(timeoutAttempt.member,
                                          generation: runtime.profileRouteGeneration(timeoutAttempt.member)) else { return }
        runtime.replace(room)
        // The timeout is durable stranded work, but its old live prompt is
        // not. A later successful harvest can safely mirror it again.
        runtime.clearPendingPrompt(for: timeoutAttempt, roomID: roomID)
    }

    /// Reconcile accepted/uncertain/timed-out work. Uncertainty becomes
    /// accepted only when the exact marker is present. Neither path submits.
    func harvestRoomAttempts(roomID: RoomID, epoch: UInt64,
                             member: GatewayBotRoute? = nil,
                             harvestToken: UUID? = nil) async {
        let runtime = RoomRuntime.shared
        guard await roomHarvestOwnerIsCurrent(roomID: roomID, epoch: epoch,
                                              harvestToken: harvestToken),
              let room = try? await runtime.store.room(id: roomID),
              room.epoch == epoch else { return }
        let pending = room.attempts.filter {
            $0.finishedAt == nil && (member == nil || $0.member == member) &&
                [.waiting, .accepted, .uncertain, .working, .timedOut].contains($0.state)
        }
        for attempt in pending {
            guard await roomHarvestOwnerIsCurrent(roomID: roomID, epoch: epoch,
                                                  harvestToken: harvestToken),
                  let current = try? await runtime.store.room(id: roomID),
                  current.epoch == epoch else { return }
            let routeGeneration = runtime.profileRouteGeneration(attempt.member)
            guard runtime.acceptsProfileRoute(attempt.member, generation: routeGeneration) else {
                continue
            }
            if attempt.state == .waiting, current.epoch != attempt.epoch {
                if let cancelled = try? await runtime.store.mutate(roomID: roomID, { value in
                    guard !Task.isCancelled, value.epoch == epoch else {
                        throw CancellationError()
                    }
                    guard let index = value.attempts.firstIndex(where: { $0.id == attempt.id }),
                          value.attempts[index].state == .waiting else { throw CancellationError() }
                    value.attempts[index].state = .cancelled
                    value.attempts[index].finishedAt = Date()
                    value.attempts[index].outboundAttachments = []
                }) { runtime.replace(cancelled) }
                continue
            }
            guard let seat = current.members.first(where: { $0.route == attempt.member }) else { continue }
            let session: RoomMemberSessionSnapshot
            do { session = try await readRoomSession(for: attempt) }
            catch {
                // A transient resume error must retain an already mirrored
                // card; only a successful resume owns prompt replacement.
                continue
            }
            guard await roomHarvestOwnerIsCurrent(roomID: roomID, epoch: epoch,
                                                  harvestToken: harvestToken),
                  runtime.acceptsProfileRoute(attempt.member,
                                              generation: routeGeneration) else { continue }
            // A successful resume with no pending request clears a card for
            // this exact accepted attempt. A pre-submit `.waiting` attempt is
            // excluded until its marker proves the hidden prompt is ours.
            let ownsPrompt = ![.waiting, .working, .uncertain].contains(attempt.state)
                || session.containsAttempt(attempt)
            if ownsPrompt {
                runtime.synchronizePendingPrompt(roomID: roomID, attempt: attempt, snapshot: session)
            }
            if attempt.state == .waiting {
                if session.awaitingUser {
                    // A waiting attempt normally means the hidden session was
                    // busy before its room turn crossed the wire. Only attach
                    // a card if the exact durable marker proves this prompt is
                    // now this room attempt rather than unrelated foreground
                    // work in the same hidden session.
                    guard session.containsAttempt(attempt) else { continue }
                    runtime.synchronizePendingPrompt(roomID: roomID, attempt: attempt,
                                                     snapshot: session)
                    if let accepted = try? await runtime.store.mutate(roomID: roomID, { value in
                        guard !Task.isCancelled, value.epoch == epoch else {
                            throw CancellationError()
                        }
                        guard let index = value.attempts.firstIndex(where: { $0.id == attempt.id })
                        else { throw CancellationError() }
                        value.attempts[index].state = .accepted
                    }) { runtime.replace(accepted) }
                    continue
                }
                guard !session.running else { continue }
                if session.containsAttempt(attempt) {
                    runtime.synchronizePendingPrompt(roomID: roomID, attempt: attempt,
                                                     snapshot: session)
                    if let accepted = try? await runtime.store.mutate(roomID: roomID, { value in
                        guard !Task.isCancelled, value.epoch == epoch else {
                            throw CancellationError()
                        }
                        guard let index = value.attempts.firstIndex(where: { $0.id == attempt.id })
                        else { throw CancellationError() }
                        value.attempts[index].state = .accepted
                    }) {
                        guard runtime.acceptsProfileRoute(attempt.member,
                                                          generation: routeGeneration) else { continue }
                        runtime.replace(accepted)
                    }
                } else {
                    await submitWaitingRoomAttempt(roomID: roomID, attempt: attempt,
                                                   session: session,
                                                   expectedRoomEpoch: epoch,
                                                   harvestToken: harvestToken)
                    continue
                }
            }
            // A valid clarify/approval is neither a completed reply nor an
            // idle tool-only pass, including when Hermes reports non-running.
            if session.awaitingUser { continue }
            if !session.running, !session.containsAttempt(attempt),
               [.working, .uncertain, .timedOut].contains(attempt.state) {
                if let unresolved = try? await runtime.store.mutate(roomID: roomID, { value in
                    guard !Task.isCancelled, value.epoch == epoch else {
                        throw CancellationError()
                    }
                    guard let index = value.attempts.firstIndex(where: { $0.id == attempt.id }),
                          value.attempts[index].finishedAt == nil else { throw CancellationError() }
                    if value.attempts[index].state == .working {
                        value.attempts[index].state = .uncertain
                    }
                    if !value.activity.contains(where: {
                        $0.epoch == attempt.epoch && $0.member == attempt.member
                            && $0.threadID == attempt.threadID && $0.kind == .uncertain
                    }) {
                        RoomEngine.recordActivity(RoomActivity(epoch: attempt.epoch,
                                                               kind: .uncertain,
                                                               member: attempt.member,
                                                               threadID: attempt.threadID), in: &value)
                    }
                }) {
                    guard runtime.acceptsProfileRoute(attempt.member,
                                                      generation: routeGeneration) else { continue }
                    runtime.replace(unresolved)
                }
                continue
            }
            if let reply = session.assistantReply(for: attempt), !session.running {
                await finishRoomAttempt(roomID: roomID, attemptID: attempt.id,
                                        member: seat, reply: reply, delivered: true,
                                        routeGeneration: routeGeneration,
                                        expectedRoomEpoch: epoch,
                                        harvestToken: harvestToken)
            } else if !session.running, session.containsAttempt(attempt) {
                await finishRoomAttempt(roomID: roomID, attemptID: attempt.id,
                                        member: seat, reply: nil, delivered: true,
                                        routeGeneration: routeGeneration,
                                        expectedRoomEpoch: epoch,
                                        harvestToken: harvestToken)
            }
        }
    }

    /// Busy→idle hand-off. The compare-and-set is the exactly-once boundary:
    /// only `.waiting` may become `.working`; relaunch sees working and can
    /// reconcile the marker but can never enter this submit path again.
    func submitWaitingRoomAttempt(roomID: RoomID, attempt: RoomAttempt,
                                  session: RoomMemberSessionSnapshot,
                                  client: GatewayClient? = nil,
                                  expectedRoomEpoch: UInt64? = nil,
                                  harvestToken: UUID? = nil) async {
        let runtime = RoomRuntime.shared
        let routeGeneration = runtime.profileRouteGeneration(attempt.member)
        if let expectedRoomEpoch,
           !(await roomHarvestOwnerIsCurrent(roomID: roomID, epoch: expectedRoomEpoch,
                                             harvestToken: harvestToken)) { return }
        guard !session.running,
              runtime.acceptsProfileRoute(attempt.member, generation: routeGeneration),
              let claimed = try? await runtime.store.mutate(roomID: roomID, { value in
                  guard !Task.isCancelled else { throw CancellationError() }
                  if let expectedRoomEpoch, value.epoch != expectedRoomEpoch {
                      throw CancellationError()
                  }
                  guard let index = value.attempts.firstIndex(where: { $0.id == attempt.id }),
                        value.attempts[index].state == .waiting,
                        value.attempts[index].member == attempt.member,
                        value.attempts[index].epoch == attempt.epoch else { throw CancellationError() }
                  if value.epoch != attempt.epoch {
                      value.attempts[index].state = .cancelled
                      value.attempts[index].finishedAt = Date()
                      value.attempts[index].outboundAttachments = []
                      return
                  }
                  value.attempts[index].state = .working
                  value.attempts[index].baselineMessageCount = session.messageCount
                  value.attempts[index].storedSessionID = session.storedID
                  value.attempts[index].runtimeSessionID = session.runtimeID
              }), let claimedAttempt = claimed.attempts.first(where: { $0.id == attempt.id })
        else { return }
        runtime.replace(claimed)
        guard claimedAttempt.state == .working else { return }
        guard runtime.acceptsProfileRoute(attempt.member, generation: routeGeneration) else { return }
        if let expectedRoomEpoch,
           !(await roomHarvestOwnerIsCurrent(roomID: roomID, epoch: expectedRoomEpoch,
                                             harvestToken: harvestToken)) { return }
        let payloads = await roomOutboundAttachments(
            roomID: roomID, descriptors: claimedAttempt.outboundAttachments)
        if let expectedRoomEpoch,
           !(await roomHarvestOwnerIsCurrent(roomID: roomID, epoch: expectedRoomEpoch,
                                             harvestToken: harvestToken)) { return }
        let submitted: RoomPromptSubmission
        if let operation = runtime.submitOperation {
            submitted = await operation(claimedAttempt, session, payloads)
        } else {
            let sourceClient: GatewayClient
            if let client { sourceClient = client }
            else if let routed = try? await routedClient(for: claimedAttempt.member) {
                sourceClient = routed
            } else {
                return
            }
            submitted = await sourceClient.submitRoomPrompt(
                attempt: claimedAttempt, session: session,
                profile: claimedAttempt.member.profile, attachments: payloads)
        }
        guard runtime.acceptsProfileRoute(attempt.member, generation: routeGeneration) else { return }
        let saved = await persistRoomSubmission(
            roomID: roomID, attemptID: claimedAttempt.id,
            member: claimedAttempt.member, epoch: claimedAttempt.epoch,
            threadID: claimedAttempt.threadID, submitted: submitted,
            routeGeneration: routeGeneration)
        if saved, case .accepted = submitted.acceptance {
            await waitForRoomReply(roomID: roomID, attemptID: claimedAttempt.id)
        }
    }

    func finishRoomAttempt(roomID: RoomID, attemptID: RoomAttemptID,
                           member: RoomMember, reply: String?, delivered: Bool,
                           routeGeneration: UInt64? = nil,
                           expectedRoomEpoch: UInt64? = nil,
                           harvestToken: UUID? = nil) async {
        let runtime = RoomRuntime.shared
        if let routeGeneration,
           !runtime.acceptsProfileRoute(member.route, generation: routeGeneration) { return }
        if let expectedRoomEpoch,
           !(await roomHarvestOwnerIsCurrent(roomID: roomID, epoch: expectedRoomEpoch,
                                             harvestToken: harvestToken)) { return }
        guard let room = try? await runtime.store.mutate(roomID: roomID, { current in
            guard !Task.isCancelled else { throw CancellationError() }
            if let expectedRoomEpoch, current.epoch != expectedRoomEpoch {
                throw CancellationError()
            }
            guard let index = current.attempts.firstIndex(where: { $0.id == attemptID }),
                  current.attempts[index].finishedAt == nil,
                  current.attempts[index].member == member.route else { throw CancellationError() }
            let attempt = current.attempts[index]
            let pass = RoomEngine.isPass(reply)
            current.attempts[index].state = pass ? .passed : (delivered ? .delivered : .replied)
            current.attempts[index].finishedAt = Date()
            current.attempts[index].stagedImagePaths = []
            current.attempts[index].outboundAttachments = []
            if !pass, let reply {
                let label = member.title?.isEmpty == false ? member.title! :
                    (member.route.profile.lowercased() == "default" ? "Hermes" : member.route.profile)
                try RoomEngine.append(RoomEntry(threadID: attempt.threadID, speaker: .member,
                                                memberRoute: member.route, speakerName: label,
                                                sourceLabel: member.sourceLabel, text: reply), to: &current)
                if let driveIndex = current.drives.firstIndex(where: { $0.epoch == attempt.epoch }) {
                    current.drives[driveIndex].posted += 1
                }
            }
            current.watermarks[RoomEngine.watermarkKey(threadID: attempt.threadID,
                                                       member: member.route)] = current.entries.count
            RoomEngine.recordActivity(RoomActivity(epoch: attempt.epoch,
                                                   kind: pass ? .passed : (delivered ? .delivered : .replied),
                                                   member: member.route, threadID: attempt.threadID), in: &current)
        }) else { return }
        if let routeGeneration,
           !runtime.acceptsProfileRoute(member.route, generation: routeGeneration) { return }
        if let expectedRoomEpoch,
           !(await roomHarvestOwnerIsCurrent(roomID: roomID, epoch: expectedRoomEpoch,
                                             harvestToken: harvestToken)) { return }
        runtime.replace(room)
        if let reply, !RoomEngine.isPass(reply) {
            scheduleRoomProjectionSync(changedRooms: [roomProjectionKey(room)])
        }
        if let completed = room.attempts.first(where: { $0.id == attemptID }) {
            runtime.clearPendingPrompt(for: completed, roomID: roomID)
        }
    }

    func settleRoomDrive(roomID: RoomID, epoch: UInt64, threadID: RoomThreadID,
                         routeGenerations: [GatewayBotRoute: UInt64]? = nil) async {
        let runtime = RoomRuntime.shared
        if let routeGenerations,
           !acceptsRoomRouteGenerations(routeGenerations) { return }
        guard let room = try? await runtime.store.mutate(roomID: roomID, { current in
            guard current.epoch == epoch else { throw CancellationError() }
            current.drives.removeAll { $0.epoch == epoch }
            RoomEngine.recordActivity(RoomActivity(epoch: epoch, kind: .settled,
                                                   threadID: threadID), in: &current)
        }) else { return }
        if let routeGenerations,
           !acceptsRoomRouteGenerations(routeGenerations) { return }
        runtime.replace(room)
        if Self.hasStrandedRoomAttempts(room) {
            schedulePostSettleRoomHarvest(roomID: roomID, epoch: epoch)
        }
    }

    func persistRoomActivity(roomID: RoomID, epoch: UInt64, kind: RoomActivityKind,
                             member: GatewayBotRoute?, threadID: RoomThreadID?,
                             routeGeneration: UInt64? = nil) async {
        if let member, let routeGeneration = routeGeneration,
           !RoomRuntime.shared.acceptsProfileRoute(member, generation: routeGeneration) { return }
        guard let room = try? await RoomRuntime.shared.store.mutate(roomID: roomID, { current in
            guard current.epoch == epoch else { throw CancellationError() }
            RoomEngine.recordActivity(RoomActivity(epoch: epoch, kind: kind,
                                                   member: member, threadID: threadID), in: &current)
        }) else { return }
        if let member, let routeGeneration = routeGeneration,
           !RoomRuntime.shared.acceptsProfileRoute(member, generation: routeGeneration) { return }
        RoomRuntime.shared.replace(room)
    }

    func roomTurnPrompt(room: RoomRecord, viewer: RoomMember, delta: [RoomEntry]) -> String {
        let peers = room.members.filter { $0.route != viewer.route }.map { member in
            let title = member.title?.isEmpty == false ? "\(member.title!) (@\(member.handle))" : "@\(member.handle)"
            return member.sourceLabel.map { "\(title) [on \($0)]" } ?? title
        }.joined(separator: ", ")
        let lines = delta.map { entry -> String in
            let files = entry.attachments.map { attachment in
                let label = attachment.mediaType == "application/pdf" ? "attached PDF" :
                    (attachment.mediaType.hasPrefix("image/") ? "attached image" : "attached file")
                return "[\(label): \(attachment.fileName)]"
            }.joined(separator: " ")
            if entry.speaker == .user { return "You (user): \(entry.text) \(files)" }
            let you = entry.memberRoute == viewer.route ? " (you)" : ""
            let source = entry.sourceLabel.map { " [\($0)]" } ?? ""
            return "\(entry.speakerName)\(you)\(source): \(entry.text) \(files)"
        }
        return ([
            "[Group chat: \"\(room.name)\"] You are @\(viewer.handle), one participant in a group chat with \(peers.isEmpty ? "no one else yet" : peers) and the user.",
            "", "New messages in this thread since your last turn (oldest first):",
        ] + lines.map { "  \($0)" } + [
            "", "Rules for this room:",
            "- Reply with ONE conversational message only when you have something new worth adding. Give substantive work at full quality; keep chatter short.",
            "- If you have nothing new to add, reply with exactly \"(pass)\".",
            "- Mention a teammate as @name to pull them in; mention @user only for a judgment call or result. Do not repeat points already made.",
            "- Never reveal content from private 1:1 chats. Your reply text goes to the room verbatim."
        ]).joined(separator: "\n")
    }

    func roomOutboundAttachments(roomID: RoomID,
                                 descriptors: [RoomAttachment]) async -> [RoomOutboundAttachment] {
        let store = RoomRuntime.shared.store
        var result: [RoomOutboundAttachment] = []
        for attachment in descriptors {
            guard let data = try? await store.readBlob(roomID: roomID, attachment: attachment) else { continue }
            let kind: RoomOutboundAttachment.Kind = attachment.mediaType == "application/pdf" ? .pdf :
                (attachment.mediaType.hasPrefix("image/") ? .image : .file)
            result.append(RoomOutboundAttachment(id: attachment.id, kind: kind,
                                                 name: attachment.fileName, data: data))
        }
        return result
    }
}
