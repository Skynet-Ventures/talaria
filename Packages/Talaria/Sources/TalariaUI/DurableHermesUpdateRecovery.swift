import Foundation
import TalariaKit

enum HermesUpdateActionIdentity {
    static let scalarCount = 32

    static func admit(_ raw: String?) -> String? {
        guard let raw, raw.unicodeScalars.count == scalarCount,
              raw.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...102).contains($0.value)
              }) else { return nil }
        return raw
    }

    static func admittedPID(_ raw: JSONValue?) -> Int? {
        guard let value = raw?.doubleValue, value.isFinite,
              value.rounded(.towardZero) == value,
              value > 0, value <= Double(Int32.max) else { return nil }
        return Int(value)
    }

    static func admittedExitCode(_ raw: JSONValue?) -> Int? {
        guard let value = raw?.doubleValue, value.isFinite,
              value.rounded(.towardZero) == value,
              abs(value) <= Double(Int32.max) else { return nil }
        return Int(value)
    }
}

enum HermesUpdateReceiptOutcome: String, Codable, Sendable {
    case running, success, partial, failed, refused

    var isTerminal: Bool { self != .running }
}

struct HermesUpdateReceiptSummary: Equatable, Sendable {
    static let maximumVersionScalars = 128
    static let maximumFleetStates = 16

    var outcome: HermesUpdateReceiptOutcome
    var startedAt: Date
    var finishedAt: Date?
    var postSHA: String?
    var postVersion: String?
    var fleetStates: [String]

    init?(_ value: JSONValue?) {
        guard let object = value?.objectValue,
              let rawOutcome = object["outcome"]?.stringValue,
              let outcome = HermesUpdateReceiptOutcome(rawValue: rawOutcome),
              let rawStarted = object["started_at"]?.stringValue,
              let startedAt = Self.parseDate(rawStarted) else { return nil }
        let finishedAt: Date?
        if let rawFinished = object["finished_at"], rawFinished != .null {
            guard let text = rawFinished.stringValue,
                  let parsed = Self.parseDate(text) else { return nil }
            finishedAt = parsed
        } else {
            finishedAt = nil
        }
        guard outcome.isTerminal == (finishedAt != nil),
              finishedAt.map({ $0 >= startedAt }) ?? true else { return nil }

        let postSHA = object["post_sha"]?.stringValue
        if let postSHA, !Self.isSHA(postSHA) { return nil }
        let postVersion = object["post_version"]?.stringValue
        if let postVersion,
           postVersion.isEmpty || postVersion.unicodeScalars.count > Self.maximumVersionScalars {
            return nil
        }
        guard let rawStates = object["fleet_states"]?.arrayValue,
              rawStates.count <= Self.maximumFleetStates else { return nil }
        let states = rawStates.compactMap(\.stringValue)
        guard states.count == rawStates.count,
              states.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.count <= 32 }) else { return nil }

        self.outcome = outcome
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.postSHA = postSHA
        self.postVersion = postVersion
        self.fleetStates = states
    }

    private static func isSHA(_ value: String) -> Bool {
        value.unicodeScalars.count == 40 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        guard !value.isEmpty, value.unicodeScalars.count <= 64 else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

struct HermesUpdateStatus: Equatable, Sendable {
    static let maximumLines = 2_000
    static let maximumLineScalars = 4_096
    static let maximumTotalLineScalars = 262_144

    var running: Bool
    var exitCode: Int?
    var pid: Int?
    var actionID: String?
    var lines: [String]
    var receipt: HermesUpdateReceiptSummary?

    init?(_ value: JSONValue) {
        guard let object = value.objectValue,
              object["name"]?.stringValue == "hermes-update",
              let running = object["running"]?.boolValue else { return nil }

        let pid: Int?
        if object["pid"] == nil || object["pid"] == .null {
            pid = nil
        } else {
            guard let admitted = HermesUpdateActionIdentity.admittedPID(object["pid"]) else {
                return nil
            }
            pid = admitted
        }
        let exitCode: Int?
        if object["exit_code"] == nil || object["exit_code"] == .null {
            exitCode = nil
        } else {
            guard let admitted = HermesUpdateActionIdentity.admittedExitCode(
                object["exit_code"]) else { return nil }
            exitCode = admitted
        }
        if !running, exitCode == nil { return nil }
        if running, exitCode != nil { return nil }

        let actionID: String?
        if let raw = object["action_id"], raw != .null {
            guard let admitted = HermesUpdateActionIdentity.admit(raw.stringValue) else { return nil }
            actionID = admitted
        } else {
            actionID = nil
        }

        guard let rawLines = object["lines"]?.arrayValue,
              rawLines.count <= Self.maximumLines else { return nil }
        var total = 0
        var lines: [String] = []
        lines.reserveCapacity(rawLines.count)
        for raw in rawLines {
            guard let line = raw.stringValue,
                  line.unicodeScalars.count <= Self.maximumLineScalars else { return nil }
            total += line.unicodeScalars.count
            guard total <= Self.maximumTotalLineScalars else { return nil }
            lines.append(line)
        }

        let receipt: HermesUpdateReceiptSummary?
        if let raw = object["receipt"], raw != .null {
            guard let admitted = HermesUpdateReceiptSummary(raw) else { return nil }
            receipt = admitted
        } else {
            receipt = nil
        }

        self.running = running
        self.exitCode = exitCode
        self.pid = pid
        self.actionID = actionID
        self.lines = lines
        self.receipt = receipt
    }

    func hasCompletionMarker(for actionID: String) -> Bool {
        lines.contains("=== hermes-update completed \(actionID) ===")
    }
}

struct DurableHermesUpdateRecord: Codable, Equatable, Sendable {
    static let maximumGatewayScalars = 256
    static let maximumProfileScalars = 256
    var gatewayID: String
    var profile: String?
    var actionID: String?
    var initialPID: Int
    var startedAt: Date
    var ambiguous: Bool

    var source: GatewayMaintenanceSource {
        GatewayMaintenanceSource(gatewayID: gatewayID, profile: profile)
    }

    var isValid: Bool {
        !gatewayID.isEmpty
            && gatewayID.unicodeScalars.count <= Self.maximumGatewayScalars
            && (profile?.unicodeScalars.count ?? 0) <= Self.maximumProfileScalars
            && (actionID.map { HermesUpdateActionIdentity.admit($0) == $0 }
                ?? ambiguous)
            && initialPID > 0
            && startedAt.timeIntervalSince1970.isFinite
    }
}

@MainActor
final class DurableHermesUpdateStore {
    static let shared = DurableHermesUpdateStore()
    static let storageKey = "talaria.hermesUpdateRecovery.v1"
    static let maximumPersistedBytes = 4_096

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load(now: Date = Date()) -> DurableHermesUpdateRecord? {
        guard let data = defaults.data(forKey: Self.storageKey),
              data.count <= Self.maximumPersistedBytes,
              let record = try? JSONDecoder().decode(DurableHermesUpdateRecord.self, from: data),
              record.isValid
        else {
            defaults.removeObject(forKey: Self.storageKey)
            return nil
        }
        return record
    }

    func save(_ record: DurableHermesUpdateRecord) -> Bool {
        guard record.isValid,
              let data = try? JSONEncoder().encode(record),
              data.count <= Self.maximumPersistedBytes else { return false }
        if let existing = load(), existing.actionID != record.actionID {
            return false
        }
        defaults.set(data, forKey: Self.storageKey)
        return true
    }

    func remove(gatewayID: String? = nil) {
        guard let gatewayID else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        if load()?.gatewayID == gatewayID {
            defaults.removeObject(forKey: Self.storageKey)
        }
    }
}

enum HermesUpdateRecoveryDecision: Equatable, Sendable {
    case running(pid: Int, restarted: Bool)
    case terminal(outcome: HermesUpdateReceiptOutcome, restarted: Bool)
    case ambiguous(reason: String)
}

enum HermesUpdateRecoveryPolicy {
    static let receiptClockSlack: TimeInterval = 60

    static func decide(record: DurableHermesUpdateRecord, value: JSONValue,
                       now: Date = Date()) -> HermesUpdateRecoveryDecision {
        guard let status = HermesUpdateStatus(value) else {
            return .ambiguous(reason: "Hermes returned a malformed or saturated update status.")
        }

        if let expectedActionID = record.actionID,
           let statusActionID = status.actionID,
           statusActionID != expectedActionID {
            return .ambiguous(reason: "Hermes reported a different durable update action.")
        }

        let pidChanged = status.pid.map { $0 != record.initialPID } ?? true
        if record.actionID == nil {
            return .ambiguous(
                reason: "This legacy Hermes peer supplied no durable update identity; PID is advisory only.")
        }

        if status.running {
            // Exact Hermes exposes `action_id` from the durable completion marker,
            // not from its in-memory running process table. The accepted start PID
            // can therefore provide same-process advisory progress only; it never
            // proves a terminal result and the durable fence remains persisted.
            if !pidChanged, status.receipt == nil {
                return .running(pid: record.initialPID, restarted: false)
            }
            return .ambiguous(
                reason: "A replacement update PID is not durable in this Hermes protocol.")
        }

        guard let expectedActionID = record.actionID,
              status.actionID == expectedActionID,
              status.hasCompletionMarker(for: expectedActionID) else {
            return .ambiguous(reason: "Hermes omitted the exact durable completion marker.")
        }

        guard let receipt = status.receipt,
              receipt.outcome.isTerminal,
              receipt.startedAt >= record.startedAt.addingTimeInterval(-receiptClockSlack),
              receipt.startedAt <= now.addingTimeInterval(receiptClockSlack),
              let finishedAt = receipt.finishedAt,
              finishedAt <= now.addingTimeInterval(receiptClockSlack) else {
            return .ambiguous(reason: "Hermes returned a stale or incomplete update receipt.")
        }
        let exitSucceeded = status.exitCode == 0
        guard exitSucceeded == (receipt.outcome == .success) else {
            return .ambiguous(reason: "Hermes update exit and receipt outcomes disagree.")
        }
        return .terminal(outcome: receipt.outcome, restarted: pidChanged)
    }
}

enum HermesUpdateRecoveryPublicationPolicy {
    static func accepts(capturedGatewayID: String, currentGatewayID: String?,
                        capturedGeneration: Int, currentGeneration: Int,
                        capturedConnectionRevision: UInt64,
                        currentConnectionRevision: UInt64,
                        capturedClient: ObjectIdentifier,
                        currentClient: ObjectIdentifier?) -> Bool {
        capturedGatewayID == currentGatewayID
            && capturedGeneration == currentGeneration
            && capturedConnectionRevision == currentConnectionRevision
            && capturedClient == currentClient
    }
}

@MainActor
extension AppModel {
    /// Reconcile a persisted update after initial adoption or a supervised
    /// reconnect. This performs a status read only; it can never replay POST.
    func scheduleDurableHermesUpdateRecovery(
        gatewayID: String, client: GatewayClient, generation: Int
    ) {
        guard GatewayMaintenanceRuntime.shared.updateRecord(gatewayID: gatewayID) != nil else {
            return
        }
        let connectionRevision = OperatorSettingsRuntime.shared.connectionRevision
        let clientID = ObjectIdentifier(client)
        Task { @MainActor [weak self] in
            guard let self,
                  let record = GatewayMaintenanceRuntime.shared.updateRecord(
                    gatewayID: gatewayID) else { return }
            do {
                let value = try await client.rawActionStatus(
                    name: "hermes-update", lines: HermesUpdateStatus.maximumLines)
                guard HermesUpdateRecoveryPublicationPolicy.accepts(
                    capturedGatewayID: gatewayID,
                    currentGatewayID: LiveRuntime.shared.gatewayID,
                    capturedGeneration: generation,
                    currentGeneration: LiveRuntime.shared.generation,
                    capturedConnectionRevision: connectionRevision,
                    currentConnectionRevision: OperatorSettingsRuntime.shared.connectionRevision,
                    capturedClient: clientID,
                    currentClient: self.client.map(ObjectIdentifier.init)
                ) else { return }
                GatewayMaintenanceRuntime.shared.applyUpdateRecovery(
                    HermesUpdateRecoveryPolicy.decide(record: record, value: value),
                    record: record)
            } catch is CancellationError {
                return
            } catch {
                guard HermesUpdateRecoveryPublicationPolicy.accepts(
                    capturedGatewayID: gatewayID,
                    currentGatewayID: LiveRuntime.shared.gatewayID,
                    capturedGeneration: generation,
                    currentGeneration: LiveRuntime.shared.generation,
                    capturedConnectionRevision: connectionRevision,
                    currentConnectionRevision: OperatorSettingsRuntime.shared.connectionRevision,
                    capturedClient: clientID,
                    currentClient: self.client.map(ObjectIdentifier.init)
                ) else { return }
                GatewayMaintenanceRuntime.shared.markUpdateRecoveryAmbiguous(
                    record: record,
                    reason: "The exact status could not be read after reconnect: \(error.localizedDescription)")
            }
        }
    }
}
