import SwiftUI
import Observation
import TalariaKit
import TalariaTheme

/// Connection-owned invalidation for Operator's source-qualified reads. The
/// view's local task id catches picker changes; this revision catches a real
/// gateway teardown/replacement even when the saved gateway row remains.
@MainActor
@Observable
final class OperatorSettingsRuntime {
    static let shared = OperatorSettingsRuntime()

    private(set) var connectionRevision: UInt64 = 0

    func invalidateConnectionScope() {
        connectionRevision &+= 1
    }

    /// Fence status requests before a reconnect starts awaiting the existing
    /// client. The client identity is intentionally unchanged during that
    /// await, so the epoch is the only boundary that rejects a late REST
    /// response while the transport is being replaced.
    func beginReconnectAttempt() {
        invalidateConnectionScope()
    }

    /// A successful reconnect gets a fresh post-dial scope as well. Keeping a
    /// separate bump preserves the same rule if the client actor completes its
    /// dial while an older status request is still returning.
    func completeReconnectAttempt() {
        invalidateConnectionScope()
    }
}

enum OperatorStatusRequestPolicy {
    static func allowsPublication(isOffline: Bool, reconnecting: Bool,
                                  requestedGatewayID: String?, activeGatewayID: String?) -> Bool {
        guard !reconnecting else { return false }
        guard isOffline else { return true }
        guard let requestedGatewayID, let activeGatewayID else { return false }
        return requestedGatewayID != activeGatewayID
    }

    static func accepts(capturedScopeKey: String, currentScopeKey: String,
                        capturedViewGeneration: Int, currentViewGeneration: Int,
                        capturedConnectionRevision: UInt64,
                        currentConnectionRevision: UInt64,
                        capturedLiveGeneration: Int, currentLiveGeneration: Int,
                        capturedClient: ObjectIdentifier,
                        currentClient: ObjectIdentifier?) -> Bool {
        capturedScopeKey == currentScopeKey
            && capturedViewGeneration == currentViewGeneration
            && capturedConnectionRevision == currentConnectionRevision
            && capturedLiveGeneration == currentLiveGeneration
            && currentClient == capturedClient
    }
}

// Phone-relevant Hermes runtime controls that were explicitly left open by
// the original Settings pass. These are all ordinary authenticated config or
// log routes in the pinned gateway; no raw YAML/env editor is introduced.
//
// Pinned Hermes authority (b5455fdd):
//   GET /api/config[?profile=]          hermes_cli/web_server.py:6794
//   PUT /api/config {config, profile}   hermes_cli/web_server.py:7595
//   GET /api/logs                       hermes_cli/web_server.py:12298
//   POST /api/gateway/restart           hermes_cli/web_server.py:4575
//   POST /api/hermes/update             hermes_cli/web_server.py:4665
//   GET /api/hermes/update/check        hermes_cli/web_server.py:4794
//   GET /api/actions/{name}/status      hermes_cli/web_server.py:5349
//   GET /api/analytics/usage            hermes_cli/web_server.py:15265
//   agent.max_turns default             hermes_cli/config_defaults.py:46
//   agent.image_input_mode semantics    hermes_cli/config_defaults.py:309
//   persistent-memory switches          hermes_cli/config_defaults.py:1796

struct GatewayOperatorConfig: Equatable, Sendable {
    var maxTurns: Int
    var memoryEnabled: Bool
    var userProfileEnabled: Bool
    var memoryWriteApproval: Bool
    var imageInputMode: String

    init(_ value: JSONValue) {
        maxTurns = max(1, min(5_000, value["agent"]?["max_turns"]?.intValue ?? 500))
        memoryEnabled = value["memory"]?["memory_enabled"]?.boolValue ?? true
        userProfileEnabled = value["memory"]?["user_profile_enabled"]?.boolValue ?? true
        memoryWriteApproval = value["memory"]?["write_approval"]?.boolValue ?? false
        let mode = value["agent"]?["image_input_mode"]?.stringValue ?? "auto"
        imageInputMode = Self.imageModes.contains(mode) ? mode : "auto"
    }

    static let imageModes = ["auto", "native", "text"]
}
public struct GatewayCommandAction: Equatable, Sendable {
    var name: String
    var ok: Bool
    var running: Bool
    var alreadyRunning: Bool
    var pid: Int?
    var actionID: String?
    var exitCode: Int?
    var message: String
    var lines: [String]
    var canApply: Bool
    var updateAvailable: Bool
    var behind: Int?
    var updateCommand: String
    var installMethod: String

    static let empty = GatewayCommandAction(
        name: "", ok: false, running: false, alreadyRunning: false,
        pid: nil, actionID: nil, exitCode: nil, message: "", lines: [], canApply: false,
        updateAvailable: false, behind: nil, updateCommand: "", installMethod: "")

    init(name: String, ok: Bool, running: Bool, alreadyRunning: Bool,
         pid: Int?, actionID: String? = nil, exitCode: Int?, message: String, lines: [String],
         canApply: Bool, updateAvailable: Bool, behind: Int?,
         updateCommand: String, installMethod: String) {
        self.name = name; self.ok = ok; self.running = running
        self.alreadyRunning = alreadyRunning; self.pid = pid; self.actionID = actionID
        self.exitCode = exitCode
        self.message = message; self.lines = lines; self.canApply = canApply
        self.updateAvailable = updateAvailable; self.behind = behind
        self.updateCommand = updateCommand; self.installMethod = installMethod
    }

    init(_ value: JSONValue, fallbackName: String = "") {
        name = value["name"]?.stringValue ?? fallbackName
        ok = value["ok"]?.boolValue ?? (value["running"]?.boolValue == true || value["exit_code"]?.intValue == 0)
        running = value["running"]?.boolValue ?? false
        alreadyRunning = value["already_running"]?.boolValue ?? false
        pid = value["pid"]?.intValue
        actionID = HermesUpdateActionIdentity.admit(value["action_id"]?.stringValue)
        exitCode = value["exit_code"]?.intValue
        message = value["message"]?.stringValue
            ?? value["error"]?.stringValue
            ?? value["detail"]?.stringValue
            ?? ""
        lines = value["lines"]?.arrayValue?.compactMap(\.stringValue) ?? []
        canApply = value["can_apply"]?.boolValue ?? false
        updateAvailable = value["update_available"]?.boolValue ?? false
        behind = value["behind"]?.intValue
        updateCommand = value["update_command"]?.stringValue ?? ""
        installMethod = value["install_method"]?.stringValue ?? ""
    }

    var isFinished: Bool { !running && (exitCode != nil || !ok) }
}

enum GatewayOperationsPolicy {
    static func canApplyUpdate(_ check: GatewayCommandAction) -> Bool {
        check.canApply == true
    }

    static func acceptedReceipt(_ value: JSONValue, expectedName: String) throws
        -> GatewayCommandAction {
        guard value["ok"]?.boolValue == true,
              value["name"]?.stringValue == expectedName,
              HermesUpdateActionIdentity.admittedPID(value["pid"]) != nil else {
            throw AckValidationError(
                operation: expectedName,
                detail: "Hermes omitted or changed the exact accepted action receipt.")
        }
        if expectedName != "hermes-update",
           let rawActionID = value["action_id"], rawActionID != .null,
           HermesUpdateActionIdentity.admit(rawActionID.stringValue) == nil {
            throw AckValidationError(operation: expectedName,
                                     detail: "Hermes returned a malformed action identity.")
        }
        return GatewayCommandAction(value)
    }

    static func statusReceipt(_ value: JSONValue, expectedName: String,
                              expectedPID: Int) throws -> GatewayCommandAction {
        guard expectedPID > 0,
              value["name"]?.stringValue == expectedName,
              value["pid"]?.intValue == expectedPID,
              value["running"]?.boolValue != nil else {
            throw AckValidationError(
                operation: expectedName,
                detail: "Hermes changed or omitted the exact action/PID status identity.")
        }
        if value["running"]?.boolValue == false,
           value["exit_code"]?.intValue == nil {
            throw AckValidationError(
                operation: expectedName,
                detail: "Hermes returned a terminal action without an exit code.")
        }
        return GatewayCommandAction(value)
    }

    static func requireBooleanReceipt(_ value: JSONValue, operation: String,
                                      field: String, expected: Bool) throws {
        guard value["ok"]?.boolValue == true,
              value[field]?.boolValue == expected else {
            throw AckValidationError(operation: operation,
                                     detail: "Hermes omitted the exact mutation receipt.")
        }
    }

    static func requireOKReceipt(_ value: JSONValue, operation: String) throws {
        guard value["ok"]?.boolValue == true else {
            throw AckValidationError(
                operation: operation, detail: "Hermes omitted the exact success receipt.")
        }
    }

    static func requireMemoryResetReceipt(_ value: JSONValue) throws -> GatewayMemoryResetResult {
        guard value["ok"]?.boolValue == true,
              value["deleted"]?.arrayValue?.allSatisfy({ $0.stringValue != nil }) == true else {
            throw AckValidationError(operation: "Memory reset",
                                     detail: "Hermes omitted the exact reset receipt.")
        }
        return GatewayMemoryResetResult(value)
    }

    static func requireDebugShareReceipt(_ value: JSONValue) throws -> GatewayDebugShare {
        guard value["ok"]?.boolValue == true,
              value["urls"]?.objectValue != nil,
              value["failures"]?.objectValue != nil,
              value["redacted"]?.boolValue == true,
              value["auto_delete_seconds"]?.intValue != nil else {
            throw AckValidationError(operation: "Debug share",
                                     detail: "Hermes omitted the exact redacted share receipt.")
        }
        return GatewayDebugShare(value)
    }

    static func isAmbiguous(_ error: Error) -> Bool {
        WorkspaceMutationUncertainty.isAmbiguous(error)
    }

    static func shouldFence(postStarted: Bool, error: Error) -> Bool {
        postStarted && (error is CancellationError || isAmbiguous(error))
    }

    static func canIssuePost(source: GatewayMaintenanceSource,
                             capturedScopeKey: String, capturedGeneration: Int,
                             currentGatewayID: String?, currentProfile: String?,
                             currentScopeKey: String, currentGeneration: Int) -> Bool {
        source.matches(gatewayID: currentGatewayID, profile: currentProfile)
            && capturedScopeKey == currentScopeKey
            && capturedGeneration == currentGeneration
    }
}

struct GatewayMaintenanceSource: Hashable, Sendable {
    var gatewayID: String
    var profile: String?

    var label: String {
        if let profile { return "gateway \(gatewayID) · profile @\(profile)" }
        return "gateway \(gatewayID) · gateway default"
    }

    func matches(gatewayID: String?, profile: String?) -> Bool {
        self.gatewayID == gatewayID && self.profile == profile
    }
}

enum GatewayMaintenanceOutcome: Equatable, Sendable {
    case pending
    case accepted(pid: Int)
    case uncertain
}

enum GatewayUpdateRecoveryPresentation: Equatable, Sendable {
    case recovering
    case running(restarted: Bool)
    case terminal(outcome: HermesUpdateReceiptOutcome, restarted: Bool)
    case ambiguous(reason: String)
}

struct GatewayMaintenanceFence: Equatable, Sendable {
    var source: GatewayMaintenanceSource
    var action: String
    var outcome: GatewayMaintenanceOutcome
    var updateRecovery: GatewayUpdateRecoveryPresentation?

    init(source: GatewayMaintenanceSource, action: String,
         outcome: GatewayMaintenanceOutcome,
         updateRecovery: GatewayUpdateRecoveryPresentation? = nil) {
        self.source = source
        self.action = action
        self.outcome = outcome
        self.updateRecovery = updateRecovery
    }
}

/// Gateway operations are no-replay mutations. Their fence outlives this view and
/// its selected scope so navigating away and back can never make an accepted
/// or ambiguous request look runnable again.
@MainActor
@Observable
final class GatewayMaintenanceRuntime {
    static let shared = GatewayMaintenanceRuntime()

    private(set) var fence: GatewayMaintenanceFence?
    @ObservationIgnored private var sharedOwner: UUID?
    @ObservationIgnored private let updateStore: DurableHermesUpdateStore

    convenience init() {
        self.init(updateStore: .shared)
    }

    init(updateStore: DurableHermesUpdateStore) {
        self.updateStore = updateStore
        guard let record = updateStore.load() else { return }
        sharedOwner = WorkspaceRuntime.shared.claimMutation()
        fence = GatewayMaintenanceFence(
            source: record.source, action: "hermes-update",
            outcome: .accepted(pid: record.initialPID), updateRecovery: .recovering)
    }

    func begin(source: GatewayMaintenanceSource, action: String) -> Bool {
        ensureSharedOwner()
        guard fence == nil, sharedOwner == nil,
              let owner = WorkspaceRuntime.shared.claimMutation() else { return false }
        sharedOwner = owner
        fence = GatewayMaintenanceFence(source: source, action: action, outcome: .pending)
        return true
    }

    func accept(source: GatewayMaintenanceSource, action: String, pid: Int) {
        guard pid > 0, fence?.source == source, fence?.action == action else { return }
        fence?.outcome = .accepted(pid: pid)
    }

    func acceptUpdate(source: GatewayMaintenanceSource, pid: Int,
                      actionID: String?, startedAt: Date) {
        guard pid > 0, fence?.source == source,
              fence?.action == "hermes-update" else { return }
        guard let actionID else {
            fence?.outcome = .uncertain
            fence?.updateRecovery = .ambiguous(
                reason: "Hermes omitted the durable update action identity.")
            let record = DurableHermesUpdateRecord(
                gatewayID: source.gatewayID, profile: source.profile,
                actionID: nil, initialPID: pid, startedAt: startedAt,
                ambiguous: true)
            _ = updateStore.save(record)
            return
        }
        let record = DurableHermesUpdateRecord(
            gatewayID: source.gatewayID, profile: source.profile,
            actionID: actionID, initialPID: pid, startedAt: startedAt,
            ambiguous: false)
        guard updateStore.save(record) else {
            fence?.outcome = .uncertain
            fence?.updateRecovery = .ambiguous(
                reason: "Talaria could not persist the durable update identity.")
            return
        }
        fence?.outcome = .accepted(pid: pid)
        fence?.updateRecovery = .recovering
    }

    func updateRecord(gatewayID: String) -> DurableHermesUpdateRecord? {
        ensureSharedOwner()
        guard let record = updateStore.load(), record.gatewayID == gatewayID,
              fence?.source == record.source, fence?.action == "hermes-update" else { return nil }
        return record
    }

    func updateRecord(source: GatewayMaintenanceSource) -> DurableHermesUpdateRecord? {
        guard let record = updateRecord(gatewayID: source.gatewayID),
              record.source == source else { return nil }
        return record
    }

    func applyUpdateRecovery(_ decision: HermesUpdateRecoveryDecision,
                             record: DurableHermesUpdateRecord) {
        guard updateStore.load() == record, fence?.source == record.source,
              fence?.action == "hermes-update" else { return }
        switch decision {
        case .running(let pid, let restarted):
            fence?.outcome = .accepted(pid: pid)
            fence?.updateRecovery = .running(restarted: restarted)
        case .terminal(let outcome, let restarted):
            fence?.outcome = .accepted(pid: record.initialPID)
            fence?.updateRecovery = .terminal(outcome: outcome, restarted: restarted)
            updateStore.remove(gatewayID: record.gatewayID)
        case .ambiguous(let reason):
            fence?.outcome = .uncertain
            fence?.updateRecovery = .ambiguous(reason: reason)
            var ambiguous = record
            ambiguous.ambiguous = true
            _ = updateStore.save(ambiguous)
        }
    }

    func markUpdateRecoveryAmbiguous(record: DurableHermesUpdateRecord, reason: String) {
        applyUpdateRecovery(.ambiguous(reason: reason), record: record)
    }

    func removeUpdateRecovery(gatewayID: String? = nil) {
        updateStore.remove(gatewayID: gatewayID)
        guard fence?.action == "hermes-update",
              gatewayID == nil || fence?.source.gatewayID == gatewayID else { return }
        clear()
    }

    func markUncertain(source: GatewayMaintenanceSource, action: String) {
        guard fence?.source == source, fence?.action == action else { return }
        fence?.outcome = .uncertain
    }

    func canAcknowledge(source: GatewayMaintenanceSource, action: String) -> Bool {
        guard let fence else { return false }
        return fence.outcome != .pending
            && fence.source == source
            && fence.action == action
    }

    /// Safe only when the POST was never sent or Hermes definitively refused.
    func releaseDefinite(source: GatewayMaintenanceSource, action: String) {
        guard fence?.source == source, fence?.action == action else { return }
        clear()
    }

    /// Explicit user reconciliation is the only way accepted/uncertain state
    /// leaves the ledger. The caller must identify the exact source and
    /// action still fenced; a button from a different gateway/profile must
    /// never clear another source's no-replay ledger.
    @discardableResult
    func acknowledge(source: GatewayMaintenanceSource, action: String) -> Bool {
        guard canAcknowledge(source: source, action: action) else { return false }
        clear()
        return true
    }

    func preservesWorkspaceMutation(owner: UUID?) -> Bool {
        ensureSharedOwner()
        return fence != nil && owner != nil && owner == sharedOwner
    }

    private func ensureSharedOwner() {
        if fence != nil, sharedOwner == nil {
            sharedOwner = WorkspaceRuntime.shared.claimMutation()
        }
    }

    private func clear() {
        if fence?.action == "hermes-update", let gatewayID = fence?.source.gatewayID {
            updateStore.remove(gatewayID: gatewayID)
        }
        if let sharedOwner { WorkspaceRuntime.shared.releaseMutation(sharedOwner) }
        sharedOwner = nil
        fence = nil
    }
}

public struct GatewayUsageModel: Equatable, Sendable {
    var name: String
    var tokens: Int
}

public struct GatewayUsageSnapshot: Equatable, Sendable {
    var days: Int
    var sessions: Int
    var apiCalls: Int
    var inputTokens: Int
    var outputTokens: Int
    var estimatedCost: Double
    var topModels: [GatewayUsageModel]

    static let empty = GatewayUsageSnapshot(days: 30, sessions: 0, apiCalls: 0,
                                            inputTokens: 0, outputTokens: 0,
                                            estimatedCost: 0, topModels: [])
    static let periods = [7, 30, 90]

    init(days: Int, sessions: Int, apiCalls: Int, inputTokens: Int, outputTokens: Int,
         estimatedCost: Double, topModels: [GatewayUsageModel]) {
        self.days = days; self.sessions = sessions; self.apiCalls = apiCalls
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.estimatedCost = estimatedCost; self.topModels = topModels
    }

    init(_ value: JSONValue, days: Int) {
        let totals = value["totals"]
        self.days = value["period_days"]?.intValue ?? days
        sessions = totals?["total_sessions"]?.intValue ?? 0
        apiCalls = totals?["total_api_calls"]?.intValue ?? 0
        inputTokens = totals?["total_input"]?.intValue ?? 0
        outputTokens = totals?["total_output"]?.intValue ?? 0
        estimatedCost = totals?["total_estimated_cost"]?.doubleValue ?? 0
        topModels = (value["by_model"]?.arrayValue ?? []).prefix(6).compactMap { row in
            guard let name = row["model"]?.stringValue, !name.isEmpty else { return nil }
            let tokens = (row["input_tokens"]?.intValue ?? 0) + (row["output_tokens"]?.intValue ?? 0)
            return GatewayUsageModel(name: name, tokens: tokens)
        }
    }
}

struct GatewayLogSnapshot: Equatable, Sendable {
    var file: String
    var lines: [String]

    init(_ value: JSONValue, fallbackFile: String) {
        file = value["file"]?.stringValue ?? fallbackFile
        lines = value["lines"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

public struct GatewayCuratorStatus: Equatable, Sendable {
    var enabled: Bool
    var paused: Bool
    var lastRunAt: String?

    static let empty = GatewayCuratorStatus(enabled: false, paused: false, lastRunAt: nil)

    init(enabled: Bool, paused: Bool, lastRunAt: String?) {
        self.enabled = enabled; self.paused = paused; self.lastRunAt = lastRunAt
    }

    init(_ value: JSONValue) {
        enabled = value["enabled"]?.boolValue ?? false
        paused = value["paused"]?.boolValue ?? false
        lastRunAt = value["last_run_at"]?.stringValue
    }

    var isActive: Bool { enabled && !paused }
}

public struct GatewayMemoryStoreStatus: Equatable, Sendable {
    var active: String
    var memoryBytes: Int
    var userBytes: Int

    static let empty = GatewayMemoryStoreStatus(active: "", memoryBytes: 0, userBytes: 0)

    init(active: String, memoryBytes: Int, userBytes: Int) {
        self.active = active; self.memoryBytes = memoryBytes; self.userBytes = userBytes
    }

    init(_ value: JSONValue) {
        active = value["active"]?.stringValue ?? ""
        let files = value["builtin_files"]
        memoryBytes = files?["memory"]?.intValue ?? 0
        userBytes = files?["user"]?.intValue ?? 0
    }
}

public struct GatewayNamedLink: Equatable, Sendable {
    public var key: String
    public var value: String
}

public struct GatewayDebugShare: Equatable, Sendable {
    public var ok: Bool
    public var urls: [GatewayNamedLink]
    public var failures: [GatewayNamedLink]
    public var redacted: Bool
    public var autoDeleteSeconds: Int?

    static let empty = GatewayDebugShare(ok: false, urls: [], failures: [],
                                         redacted: true, autoDeleteSeconds: nil)

    init(ok: Bool, urls: [GatewayNamedLink], failures: [GatewayNamedLink],
         redacted: Bool, autoDeleteSeconds: Int?) {
        self.ok = ok; self.urls = urls; self.failures = failures
        self.redacted = redacted; self.autoDeleteSeconds = autoDeleteSeconds
    }

    init(_ value: JSONValue) {
        ok = value["ok"]?.boolValue ?? false
        urls = (value["urls"]?.objectValue ?? [:]).compactMap { key, item in
            guard let url = item.stringValue, !url.isEmpty else { return nil }
            return GatewayNamedLink(key: key, value: url)
        }.sorted { $0.key < $1.key }
        failures = (value["failures"]?.objectValue ?? [:]).compactMap { key, item in
            guard let message = item.stringValue, !message.isEmpty else { return nil }
            return GatewayNamedLink(key: key, value: message)
        }.sorted { $0.key < $1.key }
        redacted = value["redacted"]?.boolValue ?? true
        autoDeleteSeconds = value["auto_delete_seconds"]?.intValue
    }
}

public struct GatewayMemoryResetResult: Equatable, Sendable {
    var ok: Bool
    var deleted: [String]

    init(_ value: JSONValue) {
        ok = value["ok"]?.boolValue ?? false
        deleted = value["deleted"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

extension GatewayClient {
    func operatorConfig(profile: String?) async throws -> GatewayOperatorConfig {
        var query: [URLQueryItem] = []
        if let profile, !profile.isEmpty {
            query.append(URLQueryItem(name: "profile", value: profile))
        }
        return GatewayOperatorConfig(try await restJSON(path: "api/config", query: query,
                                                        timeout: 30))
    }

    func gatewayLogs(file: String, level: String?, search: String,
                     lines: Int = 200) async throws -> GatewayLogSnapshot {
        var query = [URLQueryItem(name: "file", value: file),
                     URLQueryItem(name: "lines", value: String(max(1, min(500, lines))))]
        if let level, !level.isEmpty, level != "ALL" {
            query.append(URLQueryItem(name: "level", value: level))
        }
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { query.append(URLQueryItem(name: "search", value: trimmed)) }
        return GatewayLogSnapshot(
            try await restJSON(path: "api/logs", query: query, timeout: 30),
            fallbackFile: file)
    }

    func restartGateway(profile: String?) async throws -> GatewayCommandAction {
        var query: [URLQueryItem] = []
        if let profile, !profile.isEmpty {
            query.append(URLQueryItem(name: "profile", value: profile))
        }
        let value = try await restJSON(path: "api/gateway/restart", method: "POST",
                                       query: query, timeout: 30)
        return try GatewayOperationsPolicy.acceptedReceipt(
            value, expectedName: "gateway-restart")
    }

    func hermesUpdateCheck() async throws -> GatewayCommandAction {
        GatewayCommandAction(
            try await restJSON(path: "api/hermes/update/check", timeout: 30),
            fallbackName: "hermes-update")
    }

    func startHermesUpdate() async throws -> GatewayCommandAction {
        let value = try await restJSON(path: "api/hermes/update", method: "POST", timeout: 30)
        return try GatewayOperationsPolicy.acceptedReceipt(value, expectedName: "hermes-update")
    }

    func actionStatus(name: String, pid: Int, lines: Int = 80) async throws
        -> GatewayCommandAction {
        let value = try await rawActionStatus(name: name, lines: lines)
        return try GatewayOperationsPolicy.statusReceipt(
            value, expectedName: name, expectedPID: pid)
    }

    func rawActionStatus(name: String, lines: Int = 80) async throws -> JSONValue {
        try await restJSON(
            path: "api/actions/\(name)/status",
            query: [URLQueryItem(name: "lines", value: String(max(1, min(2_000, lines))))],
            timeout: 20)
    }

    func usageAnalytics(days: Int, profile: String?) async throws -> GatewayUsageSnapshot {
        let clamped = GatewayUsageSnapshot.periods.contains(days) ? days : 30
        var query = [URLQueryItem(name: "days", value: String(clamped))]
        if let profile, !profile.isEmpty {
            query.append(URLQueryItem(name: "profile", value: profile))
        }
        return GatewayUsageSnapshot(
            try await restJSON(path: "api/analytics/usage", query: query, timeout: 30),
            days: clamped)
    }

    func startDoctor() async throws -> GatewayCommandAction {
        let value = try await restJSON(path: "api/ops/doctor", method: "POST",
                                       body: .object([:]), timeout: 30)
        return try GatewayOperationsPolicy.acceptedReceipt(value, expectedName: "doctor")
    }

    func startSecurityAudit() async throws -> GatewayCommandAction {
        let value = try await restJSON(path: "api/ops/security-audit", method: "POST",
                                       body: .object([:]), timeout: 30)
        return try GatewayOperationsPolicy.acceptedReceipt(value, expectedName: "security-audit")
    }

    func startBackup() async throws -> GatewayCommandAction {
        let value = try await restJSON(path: "api/ops/backup", method: "POST",
                                       body: .object([:]), timeout: 30)
        return try GatewayOperationsPolicy.acceptedReceipt(value, expectedName: "backup")
    }

    func curatorStatus(profile: String?) async throws -> GatewayCuratorStatus {
        GatewayCuratorStatus(try await restJSON(path: "api/curator",
                                                query: profileQuery(profile), timeout: 30))
    }

    func setCuratorPaused(_ paused: Bool, profile: String?) async throws {
        let value = try await restJSON(path: "api/curator/paused", method: "PUT",
                                       query: profileQuery(profile),
                                       body: .object(["paused": .bool(paused)]), timeout: 30)
        try GatewayOperationsPolicy.requireBooleanReceipt(
            value, operation: "Curator pause", field: "paused", expected: paused)
    }

    func startCuratorRun(profile: String?) async throws -> GatewayCommandAction {
        let value = try await restJSON(path: "api/curator/run", method: "POST",
                                       query: profileQuery(profile), body: .object([:]), timeout: 30)
        return try GatewayOperationsPolicy.acceptedReceipt(value, expectedName: "curator-run")
    }

    func memoryStoreStatus(profile: String?) async throws -> GatewayMemoryStoreStatus {
        GatewayMemoryStoreStatus(try await restJSON(path: "api/memory",
                                                    query: profileQuery(profile), timeout: 30))
    }

    func resetMemoryStore(target: String, profile: String?) async throws -> GatewayMemoryResetResult {
        let value = try await restJSON(
            path: "api/memory/reset", method: "POST",
            query: profileQuery(profile),
            body: .object(["target": .string(target)]), timeout: 30)
        return try GatewayOperationsPolicy.requireMemoryResetReceipt(value)
    }

    func shareDebugReport() async throws -> GatewayDebugShare {
        let value = try await restJSON(
            path: "api/ops/debug-share", method: "POST",
            body: .object(["redact": .bool(true), "lines": .number(200)]),
            timeout: 120)
        return try GatewayOperationsPolicy.requireDebugShareReceipt(value)
    }

    private func profileQuery(_ profile: String?) -> [URLQueryItem] {
        guard let profile, !profile.isEmpty else { return [] }
        return [URLQueryItem(name: "profile", value: profile)]
    }
}

private enum MaintenancePrompt: Equatable {
    case restartGateway
    case updateHermes
    case backup
    case debugShare
    case resetMemory(String)

    var role: ButtonRole? {
        switch self {
        case .backup, .debugShare: nil
        case .restartGateway, .updateHermes, .resetMemory: .destructive
        }
    }

    func title(_ copy: CopyPack, _ theme: ThemeID) -> String {
        switch self {
        case .restartGateway: copy.settingsRestartConfirmTitle(theme)
        case .updateHermes: copy.settingsUpdateConfirmTitle(theme)
        case .backup: copy.settingsBackupConfirmTitle(theme)
        case .debugShare: copy.settingsDebugShareConfirmTitle(theme)
        case .resetMemory: copy.settingsResetMemoryConfirmTitle(theme)
        }
    }

    func message(_ copy: CopyPack, _ theme: ThemeID) -> String {
        switch self {
        case .restartGateway: copy.settingsRestartConfirmMessage(theme)
        case .updateHermes: copy.settingsUpdateConfirmMessage(theme)
        case .backup: copy.settingsBackupConfirmMessage(theme)
        case .debugShare: copy.settingsDebugShareConfirmMessage(theme)
        case .resetMemory(let target): copy.settingsResetMemoryConfirmMessage(theme, target: target)
        }
    }

    func confirmTitle(_ copy: CopyPack, _ theme: ThemeID) -> String {
        switch self {
        case .restartGateway: copy.settingsRestartGateway(theme)
        case .updateHermes: copy.settingsUpdateHermes(theme)
        case .backup: copy.settingsBackup(theme)
        case .debugShare: copy.settingsDebugShare(theme)
        case .resetMemory: copy.settingsResetMemoryConfirm(theme)
        }
    }
}

private struct OperatorMutationCapture {
    let source: GatewayMaintenanceSource
    let scopeKey: String
    let generation: Int
    let action: String
}

public struct OperatorSettingsSection: View {
    private let model: AppModel

    public init(model: AppModel) { self.model = model }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    @State private var selectedGatewayID: String?
    @State private var selectedProfile: String?
    @State private var stateScopeKey: String?
    @State private var generation = 0
    @State private var config: GatewayOperatorConfig?
    @State private var draftMaxTurns = 500
    @State private var draftImageMode = "auto"
    @State private var isLoading = false
    @State private var selectedGatewayStatus: GatewayStatus?
    @State private var selectedGatewayStatusError: String?
    @State private var isLoadingGatewayStatus = false
    @State private var gatewayStatusGeneration = 0
    @State private var busyField: String?
    @State private var notice: String?
    @State private var noticeIsWarning = false

    @State private var logFile = "agent"
    @State private var logLevel = "ALL"
    @State private var logSearch = ""
    @State private var logs = GatewayLogSnapshot(.null, fallbackFile: "agent")
    @State private var logError: String?
    @State private var isLoadingLogs = false
    @State private var logGeneration = 0
    @State private var usageDays = 30
    @State private var usage = GatewayUsageSnapshot.empty
    @State private var usageError: String?
    @State private var isLoadingUsage = false
    @State private var usageGeneration = 0
    @State private var updateCheck = GatewayCommandAction.empty
    @State private var action = GatewayCommandAction.empty
    @State private var actionName: String?
    @State private var curator = GatewayCuratorStatus.empty
    @State private var curatorError: String?
    @State private var isLoadingCurator = false
    @State private var memoryStore = GatewayMemoryStoreStatus.empty
    @State private var memoryStoreError: String?
    @State private var isLoadingMemoryStore = false
    @State private var debugShare = GatewayDebugShare.empty
    @State private var isSharingDebug = false
    @State private var pendingMaintenance: MaintenancePrompt?
    @State private var maintenanceOwner: UUID?

    private var maintenanceRuntime: GatewayMaintenanceRuntime { .shared }

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if gatewayChoices.count > 1 { gatewayPickerSection }
            if !profileChoices.isEmpty { profilePickerSection }
            systemSection
            usageSection
            maintenanceSection
            curatorSection
            memoryStoreSection
            runtimeSection
            memorySection
            imageSection
            logsSection
            if let notice {
                Text(notice)
                    .font(theme.mono(10.5))
                    .foregroundStyle(noticeIsWarning ? theme.warn : theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: scopeKey) {
            let key = scopeKey
            prepareForScope(key)
            await loadGatewayStatus(scopeKey: key)
            await loadConfig(scopeKey: key)
            guard stateScopeKey == key else { return }
            await loadLogs(scopeKey: key)
            await loadUsage(scopeKey: key)
            await loadUpdateCheck(scopeKey: key)
            await loadCurator(scopeKey: key)
            await loadMemoryStore(scopeKey: key)
            await recoverDurableUpdateIfNeeded(scopeKey: key)
        }
        .confirmationDialog(pendingMaintenance?.title(copy, theme.id) ?? "",
                            isPresented: Binding(
                                get: { pendingMaintenance != nil },
                                set: { if !$0 { pendingMaintenance = nil } }),
                            titleVisibility: .visible) {
            if let pendingMaintenance {
                Button(pendingMaintenance.confirmTitle(copy, theme.id), role: pendingMaintenance.role) {
                    Task { await confirmMaintenance(pendingMaintenance) }
                }
            }
            Button(copy.settingsMaintenanceCancel(theme.id), role: .cancel) {
                pendingMaintenance = nil
            }
        } message: {
            if let pendingMaintenance {
                Text(pendingMaintenance.message(copy, theme.id))
            }
        }
    }

    private var gatewayChoices: [SavedGateway] {
        model.mode == .live ? ConnectionRegistry.shared.saved : []
    }

    private var targetGatewayID: String? {
        GatewaySettingsTargetFence.resolve(selected: selectedGatewayID,
                                           available: Set(gatewayChoices.map(\.id)),
                                           active: model.activeGatewayID,
                                           runtime: LiveRuntime.shared.gatewayID)
    }

    private var selectedGatewayName: String {
        if let targetGatewayID,
           let gateway = gatewayChoices.first(where: { $0.id == targetGatewayID }) {
            return gateway.name
        }
        return targetGatewayID ?? "No live gateway"
    }

    private var profileChoices: [Bot] {
        let target = targetGatewayID
        return model.unionRosterBots.filter { bot in
            if let route = model.profileRoute(for: bot.id) { return route.gatewayID == target }
            return target == model.activeGatewayID
        }
    }

    private var targetProfile: String? {
        let available = Set(profileChoices.compactMap { model.profileRoute(for: $0.id)?.profile ?? $0.id })
        return selectedProfile.flatMap { available.contains($0) ? $0 : nil }
    }

    /// The source currently shown by Operator. A maintenance receipt may be
    /// acknowledged only while this exact gateway/profile is selected.
    private var targetMaintenanceSource: GatewayMaintenanceSource? {
        targetGatewayID.map {
            GatewayMaintenanceSource(gatewayID: $0, profile: targetProfile)
        }
    }

    private var scopeKey: String {
        let clientIdentity = model.client.map { String(describing: ObjectIdentifier($0)) } ?? "none"
        return "\(targetGatewayID ?? "demo")\u{1f}\(targetProfile ?? "__gateway__")"
            + "\u{1f}\(OperatorSettingsRuntime.shared.connectionRevision)"
            + "\u{1f}\(LiveRuntime.shared.generation)\u{1f}\(clientIdentity)"
            + "\u{1f}\(model.isOffline ? "offline" : "online")"
            + "\u{1f}\(ConnectionSupervisor.shared.isReconnecting ? "reconnecting" : "steady")"
    }

    private var gatewayPickerSection: some View {
        SettingsSection(theme: theme, title: copy.settingsOperatorGateway(theme.id),
                        footnote: copy.settingsOperatorGatewayNote(theme.id)) {
            SettingsGroup(theme: theme) {
                Picker(copy.settingsOperatorGateway(theme.id), selection: Binding(
                    get: { targetGatewayID }, set: { selectedGatewayID = $0; selectedProfile = nil })) {
                    ForEach(gatewayChoices) { gateway in
                        Text(gateway.name + (gateway.id == model.activeGatewayID
                                             ? copy.settingsModelGatewayActive(theme.id) : ""))
                            .tag(Optional(gateway.id))
                    }
                }
                .pickerStyle(.menu)
                .tint(theme.accent)
                .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            }
        }
    }

    private var profilePickerSection: some View {
        SettingsSection(theme: theme, title: copy.settingsOperatorProfile(theme.id),
                        footnote: copy.settingsOperatorProfileNote(theme.id)) {
            SettingsGroup(theme: theme) {
                Picker(copy.settingsOperatorProfile(theme.id), selection: $selectedProfile) {
                    Text(copy.settingsOperatorGatewayDefault(theme.id)).tag(String?.none)
                    ForEach(profileChoices) { bot in
                        Text(bot.displayTitle).tag(Optional(model.profileRoute(for: bot.id)?.profile ?? bot.id))
                    }
                }
                .pickerStyle(.menu)
                .tint(theme.accent)
                .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
            }
        }
    }

    private var systemSection: some View {
        let status = selectedGatewayStatus
        return SettingsSection(theme: theme, title: copy.settingsCommandCenter(theme.id),
                               footnote: copy.settingsCommandCenterNote(theme.id)) {
            SettingsGroup(theme: theme) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selected gateway: \(selectedGatewayName)")
                        .font(SettingsType.rowSubtitle(theme)).foregroundStyle(theme.sub)
                    if let status {
                        Text(copy.settingsGatewayRunning(theme.id, running: status.gatewayRunning))
                            .font(SettingsType.rowTitle(theme))
                        Text(copy.settingsGatewaySessions(theme.id,
                                                          version: status.version ?? "—",
                                                          sessions: status.activeSessions,
                                                          agents: status.activeAgents))
                            .font(SettingsType.rowSubtitle(theme)).foregroundStyle(theme.sub)
                        Text("Health: \(status.overall)")
                            .font(SettingsType.rowSubtitle(theme)).foregroundStyle(theme.sub)
                    } else if isLoadingGatewayStatus {
                        Text("Checking selected gateway status…")
                            .font(SettingsType.rowTitle(theme))
                    } else if let selectedGatewayStatusError {
                        Text("Selected gateway status unavailable")
                            .font(SettingsType.rowTitle(theme)).foregroundStyle(theme.warn)
                        Text(selectedGatewayStatusError)
                            .font(theme.mono(10)).foregroundStyle(theme.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Selected gateway status unavailable")
                            .font(SettingsType.rowTitle(theme)).foregroundStyle(theme.sub)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(SettingsRowChrome(theme: theme, isLast: true))
            }
            SettingsGroup(theme: theme) {
                SettingsActionRow(theme: theme, title: copy.settingsRestartGateway(theme.id),
                                  isBusy: actionName == "gateway-restart" && action.running,
                                  isLast: false) {
                    pendingMaintenance = .restartGateway
                }
                .disabled(maintenanceOwner != nil || maintenanceRuntime.fence != nil)
                SettingsActionRow(theme: theme, title: copy.settingsUpdateHermes(theme.id),
                                  isBusy: actionName == "hermes-update" && action.running,
                                  isLast: true) {
                    pendingMaintenance = .updateHermes
                }
                .disabled(!GatewayOperationsPolicy.canApplyUpdate(updateCheck)
                          || maintenanceOwner != nil || maintenanceRuntime.fence != nil)
            }
            if let fence = maintenanceRuntime.fence {
                VStack(alignment: .leading, spacing: 6) {
                    Text(maintenanceFenceMessage(fence))
                        .font(theme.mono(10)).foregroundStyle(theme.warn)
                    if let source = targetMaintenanceSource,
                       maintenanceRuntime.canAcknowledge(source: source, action: fence.action) {
                        Button("I reconciled this exact gateway action; allow another") {
                            guard let currentSource = targetMaintenanceSource,
                                  maintenanceRuntime.acknowledge(
                                      source: currentSource, action: fence.action) else { return }
                            action = .empty
                            actionName = nil
                            Task { await loadUpdateCheck(scopeKey: scopeKey) }
                        }
                        .font(theme.body(12, weight: .semibold))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)
            }
            if !updateCheck.message.isEmpty || updateCheck.updateAvailable || !updateCheck.updateCommand.isEmpty {
                Text(copy.settingsUpdateStatus(theme.id, check: updateCheck))
                    .font(theme.mono(10)).foregroundStyle(theme.sub)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
            if let actionName, !action.message.isEmpty || !action.lines.isEmpty || action.running {
                Text(copy.settingsActionStatus(theme.id, action: action, name: actionName))
                    .font(theme.mono(10)).foregroundStyle(action.exitCode == nil || action.exitCode == 0 ? theme.sub : theme.warn)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
        }
    }

    private var usageSection: some View {
        SettingsSection(theme: theme, title: copy.settingsUsageSection(theme.id),
                        footnote: copy.settingsUsageNote(theme.id)) {
            SettingsGroup(theme: theme) {
                Picker(copy.settingsUsageSection(theme.id), selection: $usageDays) {
                    ForEach(GatewayUsageSnapshot.periods, id: \.self) { days in
                        Text(copy.settingsUsagePeriod(theme.id, days: days)).tag(days)
                    }
                }
                .pickerStyle(.segmented)
                .padding(12)
                VStack(alignment: .leading, spacing: 6) {
                    Text(copy.settingsUsageTotals(theme.id, usage: usage))
                        .font(SettingsType.rowSubtitle(theme)).foregroundStyle(theme.sub)
                    ForEach(usage.topModels, id: \.name) { row in
                        Text("\(row.name) · \(row.tokens)")
                            .font(theme.mono(10)).foregroundStyle(theme.faint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.bottom, 10)
            }
            if let usageError {
                Text(usageError).font(theme.mono(10)).foregroundStyle(theme.warn)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
        }
        .onChange(of: usageDays) { _, _ in Task { await loadUsage(scopeKey: scopeKey) } }
    }

    private var maintenanceSection: some View {
        SettingsSection(theme: theme, title: copy.settingsMaintenanceSection(theme.id),
                        footnote: copy.settingsMaintenanceNote(theme.id)) {
            SettingsGroup(theme: theme) {
                SettingsActionRow(theme: theme, title: copy.settingsDoctor(theme.id),
                                  subtitle: copy.settingsDoctorNote(theme.id),
                                  isBusy: actionName == "doctor" && action.running,
                                  isLast: false) {
                    Task { await runAction("doctor") }
                }
                SettingsActionRow(theme: theme, title: copy.settingsSecurityAudit(theme.id),
                                  subtitle: copy.settingsSecurityAuditNote(theme.id),
                                  isBusy: actionName == "security-audit" && action.running,
                                  isLast: false) {
                    Task { await runAction("security-audit") }
                }
                SettingsActionRow(theme: theme, title: copy.settingsBackup(theme.id),
                                  subtitle: copy.settingsBackupNote(theme.id),
                                  isBusy: actionName == "backup" && action.running,
                                  isLast: false) {
                    pendingMaintenance = .backup
                }
                SettingsActionRow(theme: theme, title: copy.settingsDebugShare(theme.id),
                                  subtitle: copy.settingsDebugShareNote(theme.id),
                                  isBusy: isSharingDebug, isLast: true) {
                    pendingMaintenance = .debugShare
                }
            }
            .disabled(maintenanceRuntime.fence != nil)
            if let archive = action.message.isEmpty ? nil : action.message, actionName == "backup" {
                Text(archive).font(theme.mono(10)).foregroundStyle(theme.sub)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
            if !debugShare.urls.isEmpty || !debugShare.failures.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(debugShare.urls, id: \.key) { row in
                        Text("\(row.key): \(row.value)")
                            .font(theme.mono(10)).foregroundStyle(theme.sub)
                            .textSelection(.enabled)
                    }
                    ForEach(debugShare.failures, id: \.key) { row in
                        Text("\(row.key): \(row.value)")
                            .font(theme.mono(10)).foregroundStyle(theme.warn)
                    }
                    if let seconds = debugShare.autoDeleteSeconds {
                        Text(copy.settingsDebugShareExpiry(theme.id, seconds: seconds))
                            .font(theme.mono(10)).foregroundStyle(theme.faint)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var curatorSection: some View {
        SettingsSection(theme: theme, title: copy.settingsCuratorSection(theme.id),
                        footnote: copy.settingsCuratorNote(theme.id)) {
            SettingsGroup(theme: theme) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(copy.settingsCuratorState(theme.id, curator: curator))
                        .font(SettingsType.rowTitle(theme))
                    Text(copy.settingsCuratorLastRun(theme.id, curator: curator))
                        .font(SettingsType.rowSubtitle(theme)).foregroundStyle(theme.sub)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(SettingsRowChrome(theme: theme, isLast: false))
                if curator.enabled {
                    SettingsActionRow(theme: theme,
                                      title: curator.paused ? copy.settingsCuratorResume(theme.id)
                                                            : copy.settingsCuratorPause(theme.id),
                                      isBusy: busyField == "curator.paused", isLast: false) {
                        Task { await toggleCuratorPaused() }
                    }
                }
                SettingsActionRow(theme: theme, title: copy.settingsCuratorRun(theme.id),
                                  isBusy: actionName == "curator-run" && action.running,
                                  isLast: true) {
                    Task { await runAction("curator-run") }
                }
            }
            .disabled(maintenanceRuntime.fence != nil)
            if let curatorError {
                Text(curatorError).font(theme.mono(10)).foregroundStyle(theme.warn)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
        }
    }

    private var memoryStoreSection: some View {
        SettingsSection(theme: theme, title: copy.settingsMemoryStoreSection(theme.id),
                        footnote: copy.settingsMemoryStoreNote(theme.id, memory: memoryStore)) {
            SettingsGroup(theme: theme) {
                SettingsActionRow(theme: theme, title: copy.settingsResetMemoryFile(theme.id),
                                  subtitle: copy.settingsMemoryFileSize(theme.id, bytes: memoryStore.memoryBytes),
                                  isDestructive: true,
                                  isBusy: busyField == "memory.reset.memory",
                                  isLast: false) {
                    pendingMaintenance = .resetMemory("memory")
                }
                .disabled(memoryStore.memoryBytes <= 0 || maintenanceRuntime.fence != nil)
                SettingsActionRow(theme: theme, title: copy.settingsResetUserFile(theme.id),
                                  subtitle: copy.settingsMemoryFileSize(theme.id, bytes: memoryStore.userBytes),
                                  isDestructive: true,
                                  isBusy: busyField == "memory.reset.user",
                                  isLast: true) {
                    pendingMaintenance = .resetMemory("user")
                }
                .disabled(memoryStore.userBytes <= 0 || maintenanceRuntime.fence != nil)
            }
            if let memoryStoreError {
                Text(memoryStoreError).font(theme.mono(10)).foregroundStyle(theme.warn)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            }
        }
    }

    private var runtimeSection: some View {
        SettingsSection(theme: theme, title: copy.settingsRuntimeSection(theme.id),
                        footnote: copy.settingsRuntimeNote(theme.id)) {
            SettingsGroup(theme: theme) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(copy.settingsMaxTurns(theme.id)).font(SettingsType.rowTitle(theme))
                        Text(copy.settingsMaxTurnsNote(theme.id))
                            .font(SettingsType.rowSubtitle(theme)).foregroundStyle(theme.sub)
                    }
                    Spacer()
                    Stepper(value: $draftMaxTurns, in: 1...5_000, step: 25) {
                        Text("\(draftMaxTurns)").font(SettingsType.rowValue(theme))
                            .monospacedDigit().frame(minWidth: 44, alignment: .trailing)
                    }
                    .fixedSize()
                }
                .modifier(SettingsRowChrome(theme: theme, isLast: false))
                SettingsActionRow(theme: theme, title: copy.settingsSaveMaxTurns(theme.id),
                                  isBusy: busyField == "agent.max_turns", isLast: true) {
                    Task { await saveMaxTurns() }
                }
                .disabled(config == nil || draftMaxTurns == config?.maxTurns)
                .disabled(maintenanceRuntime.fence != nil)
            }
        }
    }

    private var memorySection: some View {
        SettingsSection(theme: theme, title: copy.settingsMemorySection(theme.id),
                        footnote: copy.settingsMemoryNote(theme.id)) {
            SettingsGroup(theme: theme) {
                SettingsToggleRow(theme: theme, title: copy.settingsMemoryEnabled(theme.id),
                                  subtitle: copy.settingsMemoryEnabledNote(theme.id),
                                  isOn: config?.memoryEnabled ?? false) {
                    Task { await saveBool(path: ["memory", "memory_enabled"],
                                          field: "memory.memory_enabled",
                                          value: !(config?.memoryEnabled ?? false),
                                          keyPath: \.memoryEnabled) }
                }
                SettingsToggleRow(theme: theme, title: copy.settingsUserProfileEnabled(theme.id),
                                  subtitle: copy.settingsUserProfileEnabledNote(theme.id),
                                  isOn: config?.userProfileEnabled ?? false) {
                    Task { await saveBool(path: ["memory", "user_profile_enabled"],
                                          field: "memory.user_profile_enabled",
                                          value: !(config?.userProfileEnabled ?? false),
                                          keyPath: \.userProfileEnabled) }
                }
                SettingsToggleRow(theme: theme, title: copy.settingsMemoryApproval(theme.id),
                                  subtitle: copy.settingsMemoryApprovalNote(theme.id),
                                  isOn: config?.memoryWriteApproval ?? false, isLast: true) {
                    Task { await saveBool(path: ["memory", "write_approval"],
                                          field: "memory.write_approval",
                                          value: !(config?.memoryWriteApproval ?? false),
                                          keyPath: \.memoryWriteApproval) }
                }
            }
            .disabled(config == nil || busyField != nil || maintenanceRuntime.fence != nil)
            .opacity(config == nil ? 0.55 : 1)
        }
    }

    private var imageSection: some View {
        SettingsSection(theme: theme, title: copy.settingsImageModeSection(theme.id),
                        footnote: copy.settingsImageModeNote(theme.id)) {
            SettingsGroup(theme: theme) {
                Picker(copy.settingsImageModeSection(theme.id), selection: $draftImageMode) {
                    ForEach(GatewayOperatorConfig.imageModes, id: \.self) { mode in
                        Text(copy.settingsImageModeLabel(theme.id, mode: mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(12)
                SettingsActionRow(theme: theme, title: copy.settingsSaveImageMode(theme.id),
                                  isBusy: busyField == "agent.image_input_mode", isLast: true) {
                    Task { await saveImageMode() }
                }
                .disabled(config == nil || draftImageMode == config?.imageInputMode)
                .disabled(maintenanceRuntime.fence != nil)
            }
        }
    }

    private var logsSection: some View {
        SettingsSection(theme: theme, title: copy.settingsLogsSection(theme.id),
                        footnote: copy.settingsLogsNote(theme.id)) {
            SettingsGroup(theme: theme) {
                HStack(spacing: 8) {
                    Picker("", selection: $logFile) {
                        ForEach(["agent", "errors", "gateway", "gui", "desktop", "mcp"], id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    Picker("", selection: $logLevel) {
                        ForEach(["ALL", "DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"], id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 10).padding(.vertical, 7)
                TextField(copy.settingsLogsSearch(theme.id), text: $logSearch)
                    .textFieldStyle(.plain).font(theme.mono(11))
                    .padding(.horizontal, 12).frame(height: 38)
                    .background(theme.inset)
                    .modifier(SettingsRowChrome(theme: theme, isLast: false))
                SettingsActionRow(theme: theme, title: copy.settingsLogsRefresh(theme.id),
                                  isBusy: isLoadingLogs, isLast: true) {
                    Task { await loadLogs(scopeKey: scopeKey) }
                }
            }
            if let logError {
                Text(logError).font(theme.mono(10)).foregroundStyle(theme.warn)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 2)
            } else if logs.lines.isEmpty, !isLoadingLogs {
                Text(copy.settingsLogsEmpty(theme.id)).font(theme.mono(10)).foregroundStyle(theme.faint)
                    .padding(.horizontal, 2)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(logs.lines.joined(separator: "\n"))
                        .font(theme.mono(9.5)).foregroundStyle(theme.sub)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 260)
                .background(theme.inset, in: RoundedRectangle(cornerRadius: theme.buttonRadius))
            }
        }
        .onChange(of: logFile) { _, _ in Task { await loadLogs(scopeKey: scopeKey) } }
        .onChange(of: logLevel) { _, _ in Task { await loadLogs(scopeKey: scopeKey) } }
    }

    private func prepareForScope(_ key: String) {
        guard stateScopeKey != key else { return }
        generation &+= 1
        stateScopeKey = key
        config = nil
        draftMaxTurns = 500
        draftImageMode = "auto"
        isLoading = false
        selectedGatewayStatus = nil
        selectedGatewayStatusError = nil
        isLoadingGatewayStatus = false
        gatewayStatusGeneration &+= 1
        busyField = nil
        notice = nil
        logs = GatewayLogSnapshot(.null, fallbackFile: logFile)
        logError = nil
        isLoadingLogs = false
        logGeneration &+= 1
        usage = GatewayUsageSnapshot.empty
        usageError = nil
        isLoadingUsage = false
        usageGeneration &+= 1
        updateCheck = GatewayCommandAction.empty
        action = GatewayCommandAction.empty
        actionName = nil
        curator = GatewayCuratorStatus.empty
        curatorError = nil
        isLoadingCurator = false
        memoryStore = GatewayMemoryStoreStatus.empty
        memoryStoreError = nil
        isLoadingMemoryStore = false
        debugShare = GatewayDebugShare.empty
        isSharingDebug = false
        pendingMaintenance = nil
        maintenanceOwner = nil
    }

    private func isCurrent(_ key: String, generation captured: Int) -> Bool {
        stateScopeKey == key && scopeKey == key && generation == captured
    }

    private func targetClient(gatewayID: String?) async throws -> GatewayClient {
        if let gatewayID { return try await model.routedClient(gatewayID: gatewayID) }
        if let client = model.client { return client }
        throw AppModel.GatewayRouteError.noRoute
    }

    private func loadGatewayStatus(scopeKey key: String) async {
        guard stateScopeKey == key else { return }
        gatewayStatusGeneration &+= 1
        let capturedStatusGeneration = gatewayStatusGeneration
        let captured = generation
        let gatewayID = targetGatewayID
        let statusGatewayID = gatewayID ?? model.activeGatewayID ?? LiveRuntime.shared.gatewayID
        let capturedConnectionRevision = OperatorSettingsRuntime.shared.connectionRevision
        let capturedLiveGeneration = LiveRuntime.shared.generation
        isLoadingGatewayStatus = true
        selectedGatewayStatus = nil
        selectedGatewayStatusError = nil
        defer {
            if isCurrent(key, generation: captured),
               gatewayStatusGeneration == capturedStatusGeneration {
                isLoadingGatewayStatus = false
            }
        }
        guard model.mode == .live, statusMayPublish(requestedGatewayID: gatewayID) else { return }
        var capturedClient: ObjectIdentifier?
        do {
            let client = try await targetClient(gatewayID: gatewayID)
            let clientIdentity = ObjectIdentifier(client)
            capturedClient = clientIdentity
            guard await statusRequestIsCurrent(
                key: key, generation: captured,
                statusGeneration: capturedStatusGeneration,
                gatewayID: statusGatewayID,
                requestedGatewayID: gatewayID,
                capturedConnectionRevision: capturedConnectionRevision,
                capturedLiveGeneration: capturedLiveGeneration,
                capturedClient: clientIdentity
            ) else { return }
            let loaded = try await client.status()
            guard await statusRequestIsCurrent(
                key: key, generation: captured,
                statusGeneration: capturedStatusGeneration,
                gatewayID: statusGatewayID,
                requestedGatewayID: gatewayID,
                capturedConnectionRevision: capturedConnectionRevision,
                capturedLiveGeneration: capturedLiveGeneration,
                capturedClient: clientIdentity
            ) else { return }
            selectedGatewayStatus = loaded
        } catch {
            guard let capturedClient,
                  await statusRequestIsCurrent(
                      key: key, generation: captured,
                      statusGeneration: capturedStatusGeneration,
                      gatewayID: statusGatewayID,
                      requestedGatewayID: gatewayID,
                      capturedConnectionRevision: capturedConnectionRevision,
                      capturedLiveGeneration: capturedLiveGeneration,
                      capturedClient: capturedClient
                  ) else { return }
            selectedGatewayStatusError = error.localizedDescription
        }
    }

    private func statusRequestIsCurrent(
        key: String, generation capturedGeneration: Int,
        statusGeneration capturedStatusGeneration: Int,
        gatewayID: String?, requestedGatewayID: String?, capturedConnectionRevision: UInt64,
        capturedLiveGeneration: Int, capturedClient: ObjectIdentifier
    ) async -> Bool {
        guard isCurrent(key, generation: capturedGeneration),
              gatewayStatusGeneration == capturedStatusGeneration,
              model.mode == .live,
              statusMayPublish(requestedGatewayID: requestedGatewayID) else { return false }
        let currentClient: GatewayClient?
        if let gatewayID, gatewayID != model.activeGatewayID {
            currentClient = await ConnectionRegistry.shared.clientPool.client(for: gatewayID)
        } else {
            currentClient = model.client
        }
        return OperatorStatusRequestPolicy.accepts(
            capturedScopeKey: key, currentScopeKey: scopeKey,
            capturedViewGeneration: capturedGeneration, currentViewGeneration: generation,
            capturedConnectionRevision: capturedConnectionRevision,
            currentConnectionRevision: OperatorSettingsRuntime.shared.connectionRevision,
            capturedLiveGeneration: capturedLiveGeneration,
            currentLiveGeneration: LiveRuntime.shared.generation,
            capturedClient: capturedClient,
            currentClient: currentClient.map(ObjectIdentifier.init)
        )
    }

    /// A primary status response is not useful while that primary is offline
    /// or any reconnect attempt is in flight. Saved secondary gateways remain
    /// eligible when the primary is merely offline, because their exact pool
    /// client is an independent source.
    private func statusMayPublish(requestedGatewayID: String?) -> Bool {
        OperatorStatusRequestPolicy.allowsPublication(
            isOffline: model.isOffline,
            reconnecting: ConnectionSupervisor.shared.isReconnecting,
            requestedGatewayID: requestedGatewayID,
            activeGatewayID: model.activeGatewayID
        )
    }

    private func loadConfig(scopeKey key: String) async {
        guard stateScopeKey == key, !isLoading else { return }
        generation &+= 1
        let captured = generation
        let gatewayID = targetGatewayID
        let profile = targetProfile
        isLoading = true
        defer { if isCurrent(key, generation: captured) { isLoading = false } }
        guard model.mode == .live else { return }
        do {
            let client = try await targetClient(gatewayID: gatewayID)
            guard isCurrent(key, generation: captured) else { return }
            let loaded = try await client.operatorConfig(profile: profile)
            guard isCurrent(key, generation: captured) else { return }
            config = loaded
            draftMaxTurns = loaded.maxTurns
            draftImageMode = loaded.imageInputMode
        } catch {
            guard isCurrent(key, generation: captured) else { return }
            setNotice(error.localizedDescription, warning: true)
        }
    }

    private func loadLogs(scopeKey key: String) async {
        guard stateScopeKey == key else { return }
        logGeneration &+= 1
        let capturedLogGeneration = logGeneration
        let captured = generation
        let gatewayID = targetGatewayID
        let file = logFile
        let level = logLevel
        let search = logSearch
        isLoadingLogs = true
        defer {
            if isCurrent(key, generation: captured), logGeneration == capturedLogGeneration {
                isLoadingLogs = false
            }
        }
        guard model.mode == .live else { return }
        do {
            let client = try await targetClient(gatewayID: gatewayID)
            guard isCurrent(key, generation: captured),
                  logGeneration == capturedLogGeneration else { return }
            let loaded = try await client.gatewayLogs(file: file, level: level, search: search)
            guard isCurrent(key, generation: captured),
                  logGeneration == capturedLogGeneration else { return }
            logs = loaded
            logError = nil
        } catch {
            guard isCurrent(key, generation: captured),
                  logGeneration == capturedLogGeneration else { return }
            logError = error.localizedDescription
        }
    }

    private func loadUsage(scopeKey key: String) async {
        guard stateScopeKey == key else { return }
        usageGeneration &+= 1
        let capturedUsage = usageGeneration
        let captured = generation
        let gatewayID = targetGatewayID
        let profile = targetProfile
        let days = usageDays
        isLoadingUsage = true
        defer {
            if isCurrent(key, generation: captured), usageGeneration == capturedUsage {
                isLoadingUsage = false
            }
        }
        guard model.mode == .live else { return }
        do {
            let client = try await targetClient(gatewayID: gatewayID)
            guard isCurrent(key, generation: captured), usageGeneration == capturedUsage else { return }
            let loaded = try await client.usageAnalytics(days: days, profile: profile)
            guard isCurrent(key, generation: captured), usageGeneration == capturedUsage else { return }
            usage = loaded
            usageError = nil
        } catch {
            guard isCurrent(key, generation: captured), usageGeneration == capturedUsage else { return }
            usageError = error.localizedDescription
        }
    }

    private func loadUpdateCheck(scopeKey key: String) async {
        guard stateScopeKey == key, model.mode == .live else { return }
        let captured = generation
        do {
            let client = try await targetClient(gatewayID: targetGatewayID)
            let loaded = try await client.hermesUpdateCheck()
            guard isCurrent(key, generation: captured) else { return }
            updateCheck = loaded
        } catch {
            guard isCurrent(key, generation: captured) else { return }
            updateCheck.message = error.localizedDescription
        }
    }

    private func recoverDurableUpdateIfNeeded(scopeKey key: String) async {
        guard stateScopeKey == key, model.mode == .live,
              let source = targetMaintenanceSource,
              let record = maintenanceRuntime.updateRecord(source: source) else { return }
        let gatewayID = source.gatewayID
        let capturedGeneration = generation
        let capturedConnectionRevision = OperatorSettingsRuntime.shared.connectionRevision
        let capturedLiveGeneration = LiveRuntime.shared.generation
        do {
            let client = try await targetClient(gatewayID: gatewayID)
            let clientID = ObjectIdentifier(client)
            for attempt in 0..<20 {
                guard isCurrent(key, generation: capturedGeneration) else { return }
                if attempt > 0 { try await Task.sleep(for: .milliseconds(1_200)) }
                let value = try await client.rawActionStatus(
                    name: "hermes-update", lines: HermesUpdateStatus.maximumLines)
                let currentClient = try? await targetClient(gatewayID: gatewayID)
                guard HermesUpdateRecoveryPublicationPolicy.accepts(
                    capturedGatewayID: gatewayID, currentGatewayID: targetGatewayID,
                    capturedGeneration: capturedLiveGeneration,
                    currentGeneration: LiveRuntime.shared.generation,
                    capturedConnectionRevision: capturedConnectionRevision,
                    currentConnectionRevision: OperatorSettingsRuntime.shared.connectionRevision,
                    capturedClient: clientID,
                    currentClient: currentClient.map(ObjectIdentifier.init)
                ), isCurrent(key, generation: capturedGeneration) else { return }

                let decision = HermesUpdateRecoveryPolicy.decide(record: record, value: value)
                maintenanceRuntime.applyUpdateRecovery(decision, record: record)
                actionName = "hermes-update"
                switch decision {
                case .running:
                    continue
                case .terminal, .ambiguous:
                    return
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(key, generation: capturedGeneration) else { return }
            maintenanceRuntime.markUpdateRecoveryAmbiguous(
                record: record,
                reason: "The exact status could not be read after reconnect: \(error.localizedDescription)")
        }
    }

    private func loadCurator(scopeKey key: String) async {
        guard stateScopeKey == key else { return }
        let captured = generation
        isLoadingCurator = true
        defer { if isCurrent(key, generation: captured) { isLoadingCurator = false } }
        guard model.mode == .live else { return }
        do {
            let client = try await targetClient(gatewayID: targetGatewayID)
            let loaded = try await client.curatorStatus(profile: targetProfile)
            guard isCurrent(key, generation: captured) else { return }
            curator = loaded
            curatorError = nil
        } catch {
            guard isCurrent(key, generation: captured) else { return }
            curatorError = error.localizedDescription
        }
    }

    private func loadMemoryStore(scopeKey key: String) async {
        guard stateScopeKey == key else { return }
        let captured = generation
        isLoadingMemoryStore = true
        defer { if isCurrent(key, generation: captured) { isLoadingMemoryStore = false } }
        guard model.mode == .live else { return }
        do {
            let client = try await targetClient(gatewayID: targetGatewayID)
            let loaded = try await client.memoryStoreStatus(profile: targetProfile)
            guard isCurrent(key, generation: captured) else { return }
            memoryStore = loaded
            memoryStoreError = nil
        } catch {
            guard isCurrent(key, generation: captured) else { return }
            memoryStoreError = error.localizedDescription
        }
    }

    private func toggleCuratorPaused() async {
        guard busyField == nil else { return }
        let next = !curator.paused
        let name = next ? "curator-pause" : "curator-resume"
        guard let capture = beginMutation(name) else { return }
        let key = capture.scopeKey
        let captured = capture.generation
        busyField = "curator.paused"
        defer { if isCurrent(key, generation: captured) { busyField = nil } }
        var postStarted = false
        do {
            let client = try await targetClient(gatewayID: capture.source.gatewayID)
            guard canPost(capture) else {
                maintenanceRuntime.releaseDefinite(source: capture.source, action: name)
                return
            }
            postStarted = true
            try await client.setCuratorPaused(next, profile: capture.source.profile)
            maintenanceRuntime.releaseDefinite(source: capture.source, action: name)
            guard isCurrent(key, generation: captured) else { return }
            curator.paused = next
            curatorError = nil
        } catch {
            finishFailedMutation(capture, postStarted: postStarted, error: error)
            guard isCurrent(key, generation: captured) else { return }
            curatorError = error.localizedDescription
        }
    }

    private func confirmMaintenance(_ prompt: MaintenancePrompt) async {
        pendingMaintenance = nil
        switch prompt {
        case .restartGateway:
            await runAction("gateway-restart")
        case .updateHermes:
            await runAction("hermes-update")
        case .backup:
            await runAction("backup")
        case .debugShare:
            await shareDebug()
        case .resetMemory(let target):
            await resetMemoryStore(target: target)
        }
    }

    private func shareDebug() async {
        guard !isSharingDebug else { return }
        guard let capture = beginMutation("debug-share") else { return }
        let key = capture.scopeKey
        let captured = capture.generation
        isSharingDebug = true
        defer { if isCurrent(key, generation: captured) { isSharingDebug = false } }
        var postStarted = false
        do {
            let client = try await targetClient(gatewayID: capture.source.gatewayID)
            guard canPost(capture) else {
                maintenanceRuntime.releaseDefinite(source: capture.source, action: capture.action)
                return
            }
            postStarted = true
            let result = try await client.shareDebugReport()
            maintenanceRuntime.releaseDefinite(source: capture.source, action: capture.action)
            guard isCurrent(key, generation: captured) else { return }
            debugShare = result
            setNotice(copy.settingsDebugShareDone(theme.id, share: result), warning: !result.ok)
        } catch {
            finishFailedMutation(capture, postStarted: postStarted, error: error)
            guard isCurrent(key, generation: captured) else { return }
            setNotice(error.localizedDescription, warning: true)
        }
    }

    private func resetMemoryStore(target: String) async {
        guard busyField == nil else { return }
        guard let capture = beginMutation("memory-reset-\(target)") else { return }
        let key = capture.scopeKey
        let captured = capture.generation
        busyField = "memory.reset.\(target)"
        defer { if isCurrent(key, generation: captured) { busyField = nil } }
        var postStarted = false
        do {
            let client = try await targetClient(gatewayID: capture.source.gatewayID)
            guard canPost(capture) else {
                maintenanceRuntime.releaseDefinite(source: capture.source, action: capture.action)
                return
            }
            postStarted = true
            let result = try await client.resetMemoryStore(
                target: target, profile: capture.source.profile)
            maintenanceRuntime.releaseDefinite(source: capture.source, action: capture.action)
            guard isCurrent(key, generation: captured) else { return }
            setNotice(copy.settingsResetMemoryDone(theme.id, result: result), warning: !result.ok)
            await loadMemoryStore(scopeKey: key)
        } catch {
            finishFailedMutation(capture, postStarted: postStarted, error: error)
            guard isCurrent(key, generation: captured) else { return }
            setNotice(error.localizedDescription, warning: true)
        }
    }

    private func runAction(_ name: String) async {
        if name == "hermes-update",
           !GatewayOperationsPolicy.canApplyUpdate(updateCheck) {
            setNotice(updateCheck.updateCommand.isEmpty
                      ? "Hermes did not authorize an in-app update."
                      : "This installation is externally managed. Use: \(updateCheck.updateCommand)",
                      warning: true)
            return
        }
        guard busyField == nil, maintenanceOwner == nil,
              let capture = beginMutation(name) else { return }
        let key = capture.scopeKey
        let captured = capture.generation
        let owner = UUID()
        maintenanceOwner = owner
        defer {
            if isCurrent(key, generation: captured), maintenanceOwner == owner {
                maintenanceOwner = nil
            }
        }
        actionName = name
        action = GatewayCommandAction.empty
        var postStarted = false
        let updateStartedAt = Date()
        do {
            let client = try await targetClient(gatewayID: capture.source.gatewayID)
            // Resolving a retained gateway can suspend. Recheck immediately
            // before the POST and use only the captured source values below.
            guard canPost(capture),
                  name != "hermes-update"
                    || GatewayOperationsPolicy.canApplyUpdate(updateCheck) else {
                maintenanceRuntime.releaseDefinite(source: capture.source, action: name)
                return
            }
            let started: GatewayCommandAction
            switch name {
            case "gateway-restart":
                postStarted = true
                started = try await client.restartGateway(profile: capture.source.profile)
            case "doctor":
                postStarted = true
                started = try await client.startDoctor()
            case "security-audit":
                postStarted = true
                started = try await client.startSecurityAudit()
            case "backup":
                postStarted = true
                started = try await client.startBackup()
            case "curator-run":
                postStarted = true
                started = try await client.startCuratorRun(profile: capture.source.profile)
            case "hermes-update":
                postStarted = true
                started = try await client.startHermesUpdate()
            default:
                throw GatewayError(code: 400, message: "Unsupported gateway operation.")
            }
            guard let pid = started.pid, pid > 0 else {
                throw AckValidationError(
                    operation: name, detail: "Hermes did not return a positive PID.")
            }
            if name == "hermes-update" {
                maintenanceRuntime.acceptUpdate(
                    source: capture.source, pid: pid,
                    actionID: started.actionID, startedAt: updateStartedAt)
            } else {
                maintenanceRuntime.accept(source: capture.source, action: name, pid: pid)
            }
            if name == "gateway-restart" || name == "hermes-update" {
                if isCurrent(key, generation: captured) {
                    action = started
                    action.message = name == "hermes-update" && started.actionID == nil
                        ? "Hermes omitted the durable update identity. Outcome is ambiguous; Talaria will not replay it."
                        : "Accepted by \(capture.source.label) with PID \(pid). Talaria will not replay it until you explicitly reconcile this receipt."
                }
                return
            }
            guard isCurrent(key, generation: captured) else { return }
            action = started
            await pollAction(name, pid: pid, source: capture.source, client: client,
                             scopeKey: key, generation: captured)
        } catch {
            if GatewayOperationsPolicy.shouldFence(postStarted: postStarted, error: error) {
                maintenanceRuntime.markUncertain(source: capture.source, action: name)
                if isCurrent(key, generation: captured) {
                    action.message = "Talaria could not prove the outcome on \(capture.source.label). It will not retry this action."
                    action.ok = false
                }
                return
            }
            maintenanceRuntime.releaseDefinite(source: capture.source, action: name)
            guard isCurrent(key, generation: captured) else { return }
            action.message = error.localizedDescription
            action.ok = false
        }
    }

    private func maintenanceFenceMessage(_ fence: GatewayMaintenanceFence) -> String {
        if let recovery = fence.updateRecovery {
            switch recovery {
            case .recovering:
                return "Recovering the exact accepted Hermes update on \(fence.source.label). Talaria will not replay it."
            case .running(let restarted):
                return restarted
                    ? "Recovered the exact Hermes update after its host process changed. It is still running."
                    : "Recovered the exact Hermes update. It is still running."
            case .terminal(let outcome, let restarted):
                let prefix = restarted ? "Recovered after the host restarted" : "Recovered"
                return "\(prefix): Hermes update finished with \(outcome.rawValue)."
            case .ambiguous(let reason):
                return "Hermes update recovery is ambiguous. \(reason) Talaria will not replay it."
            }
        }
        switch fence.outcome {
        case .pending:
            return "Starting \(fence.action) on \(fence.source.label). Other maintenance actions are blocked."
        case .accepted(let pid):
            return "Accepted \(fence.action) on \(fence.source.label), PID \(pid). Talaria will not replay or overlap it until you reconcile this exact action."
        case .uncertain:
            return "Outcome uncertain for \(fence.action) on \(fence.source.label). Talaria will not replay or overlap it until you reconcile this exact action."
        }
    }

    private func pollAction(_ name: String, pid: Int, source: GatewayMaintenanceSource,
                            client: GatewayClient, scopeKey key: String,
                            generation captured: Int) async {
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(1200))
            guard isCurrent(key, generation: captured) else { return }
            do {
                let status = try await client.actionStatus(name: name, pid: pid)
                guard isCurrent(key, generation: captured) else { return }
                action = status
                if !status.running {
                    maintenanceRuntime.releaseDefinite(source: source, action: name)
                    return
                }
            } catch {
                guard isCurrent(key, generation: captured) else { return }
                action.message = error.localizedDescription
                return
            }
        }
    }

    private func beginMutation(_ action: String) -> OperatorMutationCapture? {
        guard let gatewayID = targetGatewayID else {
            setNotice("Select an exact gateway before starting this action.", warning: true)
            return nil
        }
        let capture = OperatorMutationCapture(
            source: GatewayMaintenanceSource(gatewayID: gatewayID, profile: targetProfile),
            scopeKey: scopeKey, generation: generation, action: action)
        guard maintenanceRuntime.begin(source: capture.source, action: action) else {
            setNotice("Wait for the unresolved gateway action before starting another.", warning: true)
            return nil
        }
        return capture
    }

    private func canPost(_ capture: OperatorMutationCapture) -> Bool {
        GatewayOperationsPolicy.canIssuePost(
            source: capture.source,
            capturedScopeKey: capture.scopeKey,
            capturedGeneration: capture.generation,
            currentGatewayID: targetGatewayID,
            currentProfile: targetProfile,
            currentScopeKey: scopeKey,
            currentGeneration: generation)
    }

    private func finishFailedMutation(_ capture: OperatorMutationCapture,
                                      postStarted: Bool, error: Error) {
        if GatewayOperationsPolicy.shouldFence(postStarted: postStarted, error: error) {
            maintenanceRuntime.markUncertain(source: capture.source, action: capture.action)
        } else {
            maintenanceRuntime.releaseDefinite(source: capture.source, action: capture.action)
        }
    }

    private func saveMaxTurns() async {
        let value = max(1, min(5_000, draftMaxTurns))
        await save(path: ["agent", "max_turns"], field: "agent.max_turns",
                   value: .number(Double(value))) { $0.maxTurns = value }
    }

    private func saveImageMode() async {
        guard GatewayOperatorConfig.imageModes.contains(draftImageMode) else { return }
        let value = draftImageMode
        await save(path: ["agent", "image_input_mode"], field: "agent.image_input_mode",
                   value: .string(value)) { $0.imageInputMode = value }
    }

    private func saveBool(path: [String], field: String, value: Bool,
                          keyPath: WritableKeyPath<GatewayOperatorConfig, Bool>) async {
        await save(path: path, field: field, value: .bool(value)) { $0[keyPath: keyPath] = value }
    }

    private func save(path: [String], field: String, value: JSONValue,
                      apply: (inout GatewayOperatorConfig) -> Void) async {
        guard busyField == nil, var next = config,
              let capture = beginMutation("config-\(field)") else { return }
        let key = capture.scopeKey
        let captured = capture.generation
        busyField = field
        setNotice(nil, warning: false)
        defer { if isCurrent(key, generation: captured) { busyField = nil } }
        var postStarted = false
        do {
            let client = try await targetClient(gatewayID: capture.source.gatewayID)
            // Client resolution may dial a secondary gateway. Revalidate before
            // issuing the mutation, and keep the target values captured above so
            // a picker change can never retarget an in-flight save.
            guard canPost(capture) else {
                maintenanceRuntime.releaseDefinite(
                    source: capture.source, action: capture.action)
                return
            }
            postStarted = true
            try await client.setGatewayConfigValue(
                path: path, value: value, profile: capture.source.profile)
            maintenanceRuntime.releaseDefinite(source: capture.source, action: capture.action)
            guard isCurrent(key, generation: captured) else { return }
            apply(&next)
            config = next
            setNotice(copy.settingsOperatorSaved(theme.id, field: field), warning: false)
        } catch {
            finishFailedMutation(capture, postStarted: postStarted, error: error)
            guard isCurrent(key, generation: captured) else { return }
            setNotice(error.localizedDescription, warning: true)
        }
    }

    private func setNotice(_ text: String?, warning: Bool) {
        notice = text.flatMap { $0.isEmpty ? nil : $0 }
        noticeIsWarning = warning
    }
}

public extension CopyPack {
    func settingsOperatorGateway(_ t: ThemeID) -> String {
        switch t { case .soft: "Operator gateway"; case .control: "RUNTIME SOURCE"; case .ink: "the house being tended" }
    }
    func settingsOperatorGatewayNote(_ t: ThemeID) -> String {
        switch t { case .soft: "Runtime, memory and logs are owned by one gateway."; case .control: "RUNTIME CONFIG + LOGS ARE GATEWAY-LOCAL."; case .ink: "Choose the house whose workings you mean to tend." }
    }
    func settingsOperatorProfile(_ t: ThemeID) -> String {
        switch t { case .soft: "Applies to"; case .control: "PROFILE SCOPE"; case .ink: "whose rules these are" }
    }
    func settingsOperatorProfileNote(_ t: ThemeID) -> String {
        switch t { case .soft: "Runtime and memory can use a profile override. Logs remain gateway-wide."; case .control: "CONFIG MAY BE PROFILE-SCOPED. LOGS ARE ALWAYS GATEWAY-WIDE."; case .ink: "Name one resident for their rules; the house ledger below still belongs to everyone." }
    }
    func settingsOperatorGatewayDefault(_ t: ThemeID) -> String {
        switch t { case .soft: "Gateway default"; case .control: "GATEWAY DEFAULT"; case .ink: "the house rule" }
    }
    func settingsRuntimeSection(_ t: ThemeID) -> String {
        switch t { case .soft: "Agent runtime"; case .control: "AGENT RUNTIME"; case .ink: "how long the work may run" }
    }
    func settingsRuntimeNote(_ t: ThemeID) -> String {
        switch t { case .soft: "The tool-call ceiling for one turn. Lower values stop runaway work sooner."; case .control: "agent.max_turns — TOOL-CALL CEILING PER TURN."; case .ink: "A hard count beyond which one turn may travel no farther." }
    }
    func settingsMaxTurns(_ t: ThemeID) -> String { t == .control ? "MAX TURNS" : "Maximum turns" }
    func settingsMaxTurnsNote(_ t: ThemeID) -> String { t == .control ? "1–5000" : "1–5,000 tool-calling iterations" }
    func settingsSaveMaxTurns(_ t: ThemeID) -> String { t == .control ? "SAVE TURN CEILING" : "Save maximum turns" }
    func settingsMemorySection(_ t: ThemeID) -> String { t == .control ? "PERSISTENT MEMORY" : "Persistent memory" }
    func settingsMemoryNote(_ t: ThemeID) -> String { t == .control ? "BOUNDED MEMORY.md + USER.md INJECTION AND WRITE GATE." : "Controls the gateway’s bounded long-term memory and user profile." }
    func settingsMemoryEnabled(_ t: ThemeID) -> String { t == .control ? "MEMORY" : "Remember across chats" }
    func settingsMemoryEnabledNote(_ t: ThemeID) -> String { t == .control ? "memory.memory_enabled" : "Inject curated MEMORY.md context." }
    func settingsUserProfileEnabled(_ t: ThemeID) -> String { t == .control ? "USER PROFILE" : "Remember user profile" }
    func settingsUserProfileEnabledNote(_ t: ThemeID) -> String { t == .control ? "memory.user_profile_enabled" : "Inject curated USER.md context." }
    func settingsMemoryApproval(_ t: ThemeID) -> String { t == .control ? "APPROVE WRITES" : "Approve memory writes" }
    func settingsMemoryApprovalNote(_ t: ThemeID) -> String { t == .control ? "memory.write_approval" : "Review additions, replacements and removals before they persist." }
    func settingsImageModeSection(_ t: ThemeID) -> String { t == .control ? "IMAGE INPUT MODE" : "Image attachments" }
    func settingsImageModeNote(_ t: ThemeID) -> String { t == .control ? "auto | native | text — agent.image_input_mode" : "Choose whether images are sent natively or described as text first." }
    func settingsImageModeLabel(_ t: ThemeID, mode: String) -> String { t == .control ? mode.uppercased() : mode.capitalized }
    func settingsSaveImageMode(_ t: ThemeID) -> String { t == .control ? "SAVE IMAGE MODE" : "Save image mode" }
    func settingsLogsSection(_ t: ThemeID) -> String { t == .control ? "GATEWAY LOGS" : "Gateway logs" }
    func settingsLogsNote(_ t: ThemeID) -> String { t == .control ? "AUTHENTICATED GET /api/logs · READ-ONLY · LAST 200." : "Read-only tail from the selected gateway; nothing is uploaded." }
    func settingsLogsSearch(_ t: ThemeID) -> String { t == .control ? "SEARCH LOG TEXT" : "Search logs" }
    func settingsLogsRefresh(_ t: ThemeID) -> String { t == .control ? "REFRESH LOGS" : "Refresh logs" }
    func settingsLogsEmpty(_ t: ThemeID) -> String { t == .control ? "NO MATCHING LINES" : "No matching log lines." }
    func settingsOperatorSaved(_ t: ThemeID, field: String) -> String { t == .control ? "SAVED \(field)" : "Saved \(field)." }
    func settingsCommandCenter(_ t: ThemeID) -> String { t == .control ? "GATEWAY SYSTEM" : "Gateway system" }
    func settingsCommandCenterNote(_ t: ThemeID) -> String { t == .control ? "POST /api/gateway/restart + /api/hermes/update · POLL /api/actions/*/status." : "Restart this gateway or apply a Hermes update, then watch the action log." }
    func settingsGatewayRunning(_ t: ThemeID, running: Bool) -> String {
        if t == .control { return running ? "GATEWAY RUNNING" : "GATEWAY STOPPED" }
        return running ? "Gateway running" : "Gateway stopped"
    }
    func settingsGatewaySessions(_ t: ThemeID, version: String, sessions: Int, agents: Int) -> String {
        t == .control ? "HERMES \(version) · \(sessions) SESSIONS · \(agents) AGENTS" : "Hermes \(version) · \(sessions) active sessions · \(agents) agents"
    }
    func settingsRestartGateway(_ t: ThemeID) -> String { t == .control ? "RESTART GATEWAY" : "Restart gateway" }
    func settingsUpdateHermes(_ t: ThemeID) -> String { t == .control ? "UPDATE HERMES" : "Update Hermes" }
    func settingsRestartConfirmTitle(_ t: ThemeID) -> String {
        t == .control ? "RESTART THIS GATEWAY?" : "Restart this gateway?"
    }
    func settingsRestartConfirmMessage(_ t: ThemeID) -> String {
        t == .control
            ? "THE CONNECTION MAY CLOSE AFTER ACCEPTANCE. TALARIA WILL NOT RETRY."
            : "The selected gateway may disconnect immediately after accepting this request. Talaria will not retry it."
    }
    func settingsUpdateConfirmTitle(_ t: ThemeID) -> String {
        t == .control ? "UPDATE HERMES NOW?" : "Update Hermes now?"
    }
    func settingsUpdateConfirmMessage(_ t: ThemeID) -> String {
        t == .control
            ? "REQUIRES CAN_APPLY. THE CONNECTION MAY CLOSE. TALARIA WILL NOT RETRY."
            : "Hermes reported that this installation supports managed updates. The connection may close after acceptance, and Talaria will not retry."
    }
    func settingsUpdateStatus(_ t: ThemeID, check: GatewayCommandAction) -> String {
        if !check.message.isEmpty { return check.message }
        if !check.canApply, !check.updateCommand.isEmpty {
            return t == .control
                ? "MANAGED UPDATE UNAVAILABLE · \(check.updateCommand.uppercased())"
                : "Managed update unavailable. Recommended: \(check.updateCommand)"
        }
        if check.updateAvailable {
            let behind = check.behind.map(String.init) ?? "?"
            return t == .control ? "UPDATE AVAILABLE · \(behind) COMMITS BEHIND" : "Update available · \(behind) commits behind."
        }
        if !check.updateCommand.isEmpty {
            return t == .control ? check.updateCommand.uppercased() : check.updateCommand
        }
        return t == .control ? "UP TO DATE" : "Hermes is up to date."
    }
    func settingsActionStatus(_ t: ThemeID, action: GatewayCommandAction, name: String) -> String {
        let state: String
        if action.running { state = t == .control ? "RUNNING" : "running" }
        else if action.exitCode == 0 { state = t == .control ? "DONE" : "done" }
        else if action.ok, action.pid != nil { state = t == .control ? "ACCEPTED" : "accepted" }
        else { state = t == .control ? "FAILED" : "failed" }
        let tail = action.lines.suffix(3).joined(separator: "\n")
        let body = action.message.isEmpty ? tail : action.message
        return body.isEmpty ? "\(name) · \(state)" : "\(name) · \(state)\n\(body)"
    }
    func settingsUsageSection(_ t: ThemeID) -> String { t == .control ? "USAGE" : "Usage" }
    func settingsUsageNote(_ t: ThemeID) -> String { t == .control ? "GET /api/analytics/usage · 7/30/90 DAYS." : "Account-level sessions, API calls and tokens for the selected gateway." }
    func settingsUsagePeriod(_ t: ThemeID, days: Int) -> String { t == .control ? "\(days)D" : "\(days) days" }
    func settingsUsageTotals(_ t: ThemeID, usage: GatewayUsageSnapshot) -> String {
        let cost = String(format: "%.2f", usage.estimatedCost)
        return t == .control
            ? "\(usage.sessions) SESSIONS · \(usage.apiCalls) CALLS · \(usage.inputTokens)+\(usage.outputTokens) TOKENS · $\(cost)"
            : "\(usage.sessions) sessions · \(usage.apiCalls) API calls · \(usage.inputTokens) in / \(usage.outputTokens) out · $\(cost)"
    }
    func settingsMaintenanceSection(_ t: ThemeID) -> String { t == .control ? "MAINTENANCE" : "Maintenance" }
    func settingsMaintenanceNote(_ t: ThemeID) -> String { t == .control ? "POST /api/ops/doctor|security-audit|backup|debug-share." : "Run Hermes doctor, a security audit, a gateway backup, or a redacted debug share." }
    func settingsDoctor(_ t: ThemeID) -> String { t == .control ? "RUN DOCTOR" : "Run doctor" }
    func settingsDoctorNote(_ t: ThemeID) -> String { t == .control ? "hermes doctor — HEALTH CHECK." : "Checks gateway health and writes a tailed log." }
    func settingsSecurityAudit(_ t: ThemeID) -> String { t == .control ? "SECURITY AUDIT" : "Security audit" }
    func settingsSecurityAuditNote(_ t: ThemeID) -> String { t == .control ? "hermes security audit." : "Scans the gateway for common security issues." }
    func settingsBackup(_ t: ThemeID) -> String { t == .control ? "BACKUP" : "Backup" }
    func settingsBackupNote(_ t: ThemeID) -> String { t == .control ? "ZIP ON THE GATEWAY HOST." : "Writes a zip on the gateway host, not this phone." }
    func settingsDebugShare(_ t: ThemeID) -> String { t == .control ? "DEBUG SHARE" : "Share debug report" }
    func settingsDebugShareNote(_ t: ThemeID) -> String { t == .control ? "REDACTED UPLOAD · AUTO-DELETES." : "Uploads a redacted report and returns paste links." }
    func settingsDebugShareExpiry(_ t: ThemeID, seconds: Int) -> String {
        t == .control ? "AUTO-DELETE \(seconds)S" : "Links auto-delete after \(seconds) seconds."
    }
    func settingsCuratorSection(_ t: ThemeID) -> String { t == .control ? "CURATOR" : "Skill curator" }
    func settingsCuratorNote(_ t: ThemeID) -> String { t == .control ? "GET /api/curator · PUT paused · POST run." : "Background skill maintenance for this profile." }
    func settingsCuratorState(_ t: ThemeID, curator: GatewayCuratorStatus) -> String {
        if !curator.enabled { return t == .control ? "DISABLED" : "Disabled" }
        if curator.paused { return t == .control ? "PAUSED" : "Paused" }
        return t == .control ? "ACTIVE" : "Active"
    }
    func settingsCuratorLastRun(_ t: ThemeID, curator: GatewayCuratorStatus) -> String {
        if let last = curator.lastRunAt, !last.isEmpty {
            return t == .control ? "LAST RUN \(last)" : "Last run \(last)"
        }
        return t == .control ? "NEVER RAN" : "Never ran"
    }
    func settingsCuratorPause(_ t: ThemeID) -> String { t == .control ? "PAUSE" : "Pause" }
    func settingsCuratorResume(_ t: ThemeID) -> String { t == .control ? "RESUME" : "Resume" }
    func settingsCuratorRun(_ t: ThemeID) -> String { t == .control ? "RUN NOW" : "Run now" }
    func settingsMemoryStoreSection(_ t: ThemeID) -> String { t == .control ? "MEMORY FILES" : "Memory files" }
    func settingsMemoryStoreNote(_ t: ThemeID, memory: GatewayMemoryStoreStatus) -> String {
        let provider = memory.active.isEmpty ? "built-in" : memory.active
        return t == .control ? "PROVIDER \(provider.uppercased()) · RESET ERASES GATEWAY FILES." : "Active provider: \(provider). Reset deletes MEMORY.md or USER.md on the gateway."
    }
    func settingsResetMemoryFile(_ t: ThemeID) -> String { t == .control ? "RESET MEMORY.md" : "Reset MEMORY.md" }
    func settingsResetUserFile(_ t: ThemeID) -> String { t == .control ? "RESET USER.md" : "Reset USER.md" }
    func settingsMemoryFileSize(_ t: ThemeID, bytes: Int) -> String {
        if bytes <= 0 { return t == .control ? "EMPTY" : "Empty" }
        if bytes >= 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        if bytes >= 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return "\(bytes) B"
    }
    func settingsMaintenanceCancel(_ t: ThemeID) -> String { t == .control ? "CANCEL" : "Cancel" }
    func settingsBackupConfirmTitle(_ t: ThemeID) -> String { t == .control ? "BACKUP THIS GATEWAY?" : "Back up this gateway?" }
    func settingsBackupConfirmMessage(_ t: ThemeID) -> String { t == .control ? "WRITES A ZIP ON THE HOST. THE PHONE DOES NOT DOWNLOAD IT." : "This writes a zip on the gateway host. The phone does not download it." }
    func settingsDebugShareConfirmTitle(_ t: ThemeID) -> String { t == .control ? "UPLOAD REDACTED DEBUG REPORT?" : "Upload a redacted debug report?" }
    func settingsDebugShareConfirmMessage(_ t: ThemeID) -> String { t == .control ? "PASTES AUTO-DELETE. SECRETS ARE SCRUBBED." : "Creates shareable paste links. Secrets are scrubbed and the pastes auto-delete." }
    func settingsResetMemoryConfirmTitle(_ t: ThemeID) -> String { t == .control ? "DELETE MEMORY FILE?" : "Delete this memory file?" }
    func settingsResetMemoryConfirmMessage(_ t: ThemeID, target: String) -> String {
        t == .control ? "ERASES \(target.uppercased()).MD ON THE GATEWAY." : "This permanently deletes \(target.uppercased()).md on the selected gateway."
    }
    func settingsResetMemoryConfirm(_ t: ThemeID) -> String { t == .control ? "DELETE" : "Delete" }
    func settingsDebugShareDone(_ t: ThemeID, share: GatewayDebugShare) -> String {
        if share.urls.isEmpty { return t == .control ? "DEBUG SHARE RETURNED NO LINKS" : "Debug share returned no links." }
        return t == .control ? "DEBUG SHARE READY" : "Debug share ready."
    }
    func settingsResetMemoryDone(_ t: ThemeID, result: GatewayMemoryResetResult) -> String {
        let names = result.deleted.isEmpty ? "nothing" : result.deleted.joined(separator: ", ")
        return t == .control ? "DELETED \(names.uppercased())" : "Deleted \(names)."
    }
}
