import Foundation
import TalariaKit

/// Pure admission state shared with tests. Generic chat "working" is not
/// authority for a Lock Screen surface; only an explicit operation that
/// survives the grace period is admitted.
public struct LiveActivityWorkAdmission: Sendable, Equatable {
    public static let graceSeconds: Double = 20
    private var pending: [String: Set<String>] = [:]
    private var admitted: [String: Set<String>] = [:]

    public init() {}

    @discardableResult public mutating func begin(botID: String, operationID: String) -> Bool {
        guard !botID.isEmpty, !operationID.isEmpty else { return false }
        return pending[botID, default: []].insert(operationID).inserted
    }

    @discardableResult public mutating func admit(botID: String, operationID: String) -> Bool {
        guard pending[botID]?.remove(operationID) != nil else { return false }
        if pending[botID]?.isEmpty == true { pending[botID] = nil }
        admitted[botID, default: []].insert(operationID)
        return true
    }

    public mutating func end(botID: String, operationID: String) {
        pending[botID]?.remove(operationID)
        admitted[botID]?.remove(operationID)
        if pending[botID]?.isEmpty == true { pending[botID] = nil }
        if admitted[botID]?.isEmpty == true { admitted[botID] = nil }
    }

    public mutating func endAll(botID: String) {
        pending[botID] = nil
        admitted[botID] = nil
    }

    public var admittedBotIDs: Set<String> { Set(admitted.keys) }
    public var trackedBotIDs: Set<String> { Set(pending.keys).union(admitted.keys) }
}

// Drives the "<bot> is working" Live Activity (lock screen + Dynamic Island)
// from AppModel state. Mirrors the prototype's island pill: it appears while
// any bot is working, shows the avatar + phosphor elapsed clock, and taps
// deep-link into that bot's chat (talaria://bot/<id>).
//
// Policy (from the design map): one activity per bot, at most one concurrent
// activity overall, preferring the most recently started working bot; ends
// when the roster goes idle.

#if os(iOS) && canImport(ActivityKit)
import ActivityKit

@MainActor
public final class LiveActivityController {

    public static let shared = LiveActivityController()

    /// Mirrors the prototype's `liveActivity` tweak. Setting this false ends
    /// any running activity and stops new ones from starting.
    public var isEnabled: Bool = true {
        didSet { if isEnabled != oldValue { sync() } }
    }

    private weak var model: AppModel?
    private var activity: Activity<BotWorkAttributes>?
    private var lastState: BotWorkAttributes.ContentState?
    /// When each bot was first seen working — "most recent" is decided here.
    private var workingSince: [String: Date] = [:]
    private var workAdmission = LiveActivityWorkAdmission()
    private struct OperationKey: Hashable { let botID: String; let operationID: String }
    private var admissionTasks: [OperationKey: Task<Void, Never>] = [:]
    private var attached = false

    public init() {}

    // MARK: - Attach / detach

    /// Start mirroring the model. Uses withObservationTracking re-armed on
    /// every change: reads inside `sync()` register dependencies on
    /// `model.bots` / `model.approvals`, so any roster or approval mutation
    /// schedules another pass on the main actor.
    public func attach(to model: AppModel) {
        // Idempotent: the app target attaches at launch and the root view
        // re-attaches on appear; re-arming for the same model would stack a
        // second observation chain.
        if attached, self.model === model { return }
        self.model = model
        attached = true
        adoptOrEndOrphans()
        arm()
    }

    /// Stop observing and tear down any running activity.
    public func detach() {
        attached = false
        model = nil
        workingSince = [:]
        admissionTasks.values.forEach { $0.cancel() }
        admissionTasks = [:]
        workAdmission = LiveActivityWorkAdmission()
        stopActivity()
    }

    private func arm() {
        guard attached, let model else { return }
        withObservationTracking {
            self.sync(reading: model)
        } onChange: { [weak self] in
            // onChange fires on willSet; hop to the main actor so the next
            // pass reads settled values, then re-arm.
            Task { @MainActor [weak self] in
                guard let self, self.attached else { return }
                self.arm()
            }
        }
    }

    // MARK: - Sync

    private func sync() {
        guard let model else { return }
        sync(reading: model)
    }

    private func sync(reading model: AppModel) {
        let allWorking = model.workingBots
        let workingIDs = Set(allWorking.map(\.id))
        for stale in workAdmission.trackedBotIDs.subtracting(workingIDs) {
            endAllOperationalWorkInternal(botID: stale)
        }
        let admitted = workAdmission.admittedBotIDs
        let working = allWorking.filter { admitted.contains($0.id) }
        let pending = model.pendingApprovalCount()

        // Track when each bot began working; drop the ones that stopped.
        let now = Date()
        let eligibleIDs = Set(working.map(\.id))
        for bot in working where workingSince[bot.id] == nil {
            workingSince[bot.id] = now
        }
        workingSince = workingSince.filter { eligibleIDs.contains($0.key) }

        guard isEnabled, !working.isEmpty else {
            stopActivity()
            return
        }

        // Cap 1 concurrent: feature the most recently started working bot;
        // ties (e.g. everything seen at attach) break toward roster order,
        // matching the prototype's `bots.find(b => b.working)`.
        let featured = working
            .enumerated()
            .sorted { a, b in
                let ta = workingSince[a.element.id] ?? .distantPast
                let tb = workingSince[b.element.id] ?? .distantPast
                if ta != tb { return ta > tb }
                return a.offset < b.offset
            }
            .first!.element

        if let activity, activity.attributes.botID == featured.id {
            updateActivity(task: taskLine(for: featured), pendingApprovals: pending)
        } else {
            startActivity(for: featured, pendingApprovals: pending)
        }
    }

    /// The island's task line; falls back to the bot's job when the runtime
    /// hasn't labeled the turn yet.
    private func taskLine(for bot: Bot) -> String {
        bot.task ?? bot.job
    }

    // MARK: - Public start / update / stop

    /// A concrete tool may earn a Live Activity only if it is still running
    /// after the grace period. Short tools and ordinary model turns stay off
    /// the Lock Screen entirely.
    public func beginOperationalWork(botID: String, operationID: String) {
        guard workAdmission.begin(botID: botID, operationID: operationID) else { return }
        let key = OperationKey(botID: botID, operationID: operationID)
        admissionTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(LiveActivityWorkAdmission.graceSeconds))
            guard !Task.isCancelled, let self else { return }
            self.admissionTasks[key] = nil
            guard self.workAdmission.admit(botID: botID, operationID: operationID) else { return }
            self.sync()
        }
    }

    public func endOperationalWork(botID: String, operationID: String) {
        let key = OperationKey(botID: botID, operationID: operationID)
        admissionTasks.removeValue(forKey: key)?.cancel()
        workAdmission.end(botID: botID, operationID: operationID)
        sync()
    }

    public func endAllOperationalWork(botID: String) {
        endAllOperationalWorkInternal(botID: botID)
        sync()
    }

    private func endAllOperationalWorkInternal(botID: String) {
        let keys = admissionTasks.keys.filter { $0.botID == botID }
        for key in keys {
            admissionTasks.removeValue(forKey: key)?.cancel()
        }
        workAdmission.endAll(botID: botID)
    }

    /// Start (or replace) the single concurrent activity for `bot`.
    public func startActivity(for bot: Bot, pendingApprovals: Int) {
        guard isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // Dedupe: never a second activity for the same bot.
        if let activity, activity.attributes.botID == bot.id { return }
        stopActivity()

        // Both halves of the identity, never the raw profile id: the widget
        // chooses its theme at render time and applies the same
        // title-or-@handle rule as TalariaVoice.displayName(for:). Sending only
        // the handle made the island read "@researcher-1" for a bot the app
        // calls "Athena".
        let attributes = BotWorkAttributes(
            botID: bot.id, botName: bot.handle, botTitle: bot.displayTitle,
            shape: bot.shape, hue: bot.hue)
        let state = BotWorkAttributes.ContentState(
            task: taskLine(for: bot),
            startedAt: Date().addingTimeInterval(-Double(bot.minutesElapsed) * 60),
            pendingApprovals: pendingApprovals)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil)
            lastState = state
        } catch {
            // Denied / budget exhausted — the in-app surfaces still cover it.
            activity = nil
            lastState = nil
        }
    }

    /// Push new dynamic content into the running activity (no-op when nothing
    /// changed, so observation-driven passes stay cheap).
    public func updateActivity(task: String, pendingApprovals: Int) {
        guard let activity, let previous = lastState else { return }
        var state = previous
        state.task = task
        state.pendingApprovals = pendingApprovals
        guard state != previous else { return }
        lastState = state
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    /// End the running activity immediately (roster idle, disable, detach).
    public func stopActivity() {
        guard let activity else { return }
        self.activity = nil
        let finalState = lastState
        lastState = nil
        Task {
            let content = finalState.map { ActivityContent(state: $0, staleDate: nil) }
            await activity.end(content, dismissalPolicy: .immediate)
        }
    }

    // MARK: - Launch cleanup

    /// A previous process may have left activities behind. Adopt one so the
    /// next sync can update or end it; end any extras (cap 1 concurrent).
    private func adoptOrEndOrphans() {
        for existing in Activity<BotWorkAttributes>.activities {
            if activity == nil {
                activity = existing
                lastState = existing.content.state
            } else {
                Task { await existing.end(nil, dismissalPolicy: .immediate) }
            }
        }
    }
}

#else

// macOS / non-ActivityKit builds: a no-op shim so call sites in the app model
// layer don't need their own platform gates.
@MainActor
public final class LiveActivityController {
    public static let shared = LiveActivityController()
    public var isEnabled: Bool = true
    public init() {}
    public func attach(to model: AppModel) {}
    public func detach() {}
    public func stopActivity() {}
    public func beginOperationalWork(botID: String, operationID: String) {}
    public func endOperationalWork(botID: String, operationID: String) {}
    public func endAllOperationalWork(botID: String) {}
}

#endif
