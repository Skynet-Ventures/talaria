#if canImport(XCTest)
import XCTest
@testable import TalariaKit
@testable import TalariaUI

final class HermesUpdateRecoveryTests: XCTestCase {
    private let actionID = String(repeating: "a", count: 32)
    private let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func iso(_ date: Date) -> JSONValue {
        .string(ISO8601DateFormatter().string(from: date))
    }

    private func record(pid: Int = 101, ambiguous: Bool = false) -> DurableHermesUpdateRecord {
        DurableHermesUpdateRecord(
            gatewayID: "gateway-a", profile: "worker", actionID: actionID,
            initialPID: pid, startedAt: startedAt, ambiguous: ambiguous)
    }

    private func receipt(_ outcome: HermesUpdateReceiptOutcome,
                         started: Date? = nil) -> JSONValue {
        let start = started ?? startedAt.addingTimeInterval(1)
        return .object([
            "outcome": .string(outcome.rawValue),
            "started_at": iso(start),
            "finished_at": outcome.isTerminal
                ? iso(start.addingTimeInterval(10)) : .null,
            "post_sha": .string(String(repeating: "b", count: 40)),
            "post_version": .string("0.20.5"),
            "fleet_states": .array([.string("current")]),
        ])
    }

    private func status(running: Bool, pid: Int?, actionID: String?,
                        exitCode: Int?, outcome: HermesUpdateReceiptOutcome? = nil,
                        marker: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = [
            "name": .string("hermes-update"),
            "running": .bool(running),
            "pid": pid.map { .number(Double($0)) } ?? .null,
            "exit_code": exitCode.map { .number(Double($0)) } ?? .null,
            "lines": .array(marker.map { [.string($0)] } ?? []),
        ]
        if let actionID { object["action_id"] = .string(actionID) }
        if let outcome { object["receipt"] = receipt(outcome) }
        return .object(object)
    }

    func testRestartedTerminalRequiresExactActionMarkerAndFreshReceipt() {
        let marker = "=== hermes-update completed \(actionID) ==="
        let recovered = HermesUpdateRecoveryPolicy.decide(
            record: record(),
            value: status(running: false, pid: 909, actionID: actionID,
                          exitCode: 0, outcome: .success, marker: marker))
        XCTAssertEqual(recovered, .terminal(outcome: .success, restarted: true))

        let wrong = String(repeating: "c", count: 32)
        XCTAssertEqual(HermesUpdateRecoveryPolicy.decide(
            record: record(),
            value: status(running: false, pid: 909, actionID: wrong,
                          exitCode: 0, outcome: .success,
                          marker: "=== hermes-update completed \(wrong) ===")),
            .ambiguous(reason: "Hermes reported a different durable update action."))

        let missingReceipt = HermesUpdateRecoveryPolicy.decide(
            record: record(),
            value: status(running: false, pid: nil, actionID: actionID,
                          exitCode: 0, outcome: nil, marker: marker))
        guard case .ambiguous = missingReceipt else {
            return XCTFail("restart recovery without a structured receipt must fail closed")
        }
    }

    func testReceiptOutcomesAndExitCodeMustAgree() {
        let marker = "=== hermes-update completed \(actionID) ==="
        XCTAssertEqual(HermesUpdateRecoveryPolicy.decide(
            record: record(),
            value: status(running: false, pid: nil, actionID: actionID,
                          exitCode: 1, outcome: .partial, marker: marker)),
            .terminal(outcome: .partial, restarted: true))
        guard case .ambiguous = HermesUpdateRecoveryPolicy.decide(
            record: record(),
            value: status(running: false, pid: nil, actionID: actionID,
                          exitCode: 0, outcome: .partial, marker: marker)) else {
            return XCTFail("partial receipt with success exit must remain ambiguous")
        }
        for outcome in [HermesUpdateReceiptOutcome.failed, .refused] {
            guard case .ambiguous = HermesUpdateRecoveryPolicy.decide(
                record: record(),
                value: status(running: false, pid: nil, actionID: nil,
                              exitCode: 1, outcome: outcome)) else {
                return XCTFail("\(outcome.rawValue) has no durable action marker upstream")
            }
        }
    }

    func testReplacementPIDCannotRecoverRunningAction() {
        XCTAssertEqual(HermesUpdateRecoveryPolicy.decide(
            record: record(),
            value: status(running: true, pid: 101, actionID: nil,
                          exitCode: nil, outcome: nil)),
            .running(pid: 101, restarted: false))
        guard case .ambiguous = HermesUpdateRecoveryPolicy.decide(
            record: record(),
            value: status(running: true, pid: 202, actionID: actionID,
                          exitCode: nil, outcome: nil)) else {
            return XCTFail("replacement PID alone is not continuity proof")
        }
        guard case .ambiguous = HermesUpdateRecoveryPolicy.decide(
            record: record(),
            value: status(running: true, pid: 202, actionID: actionID,
                          exitCode: nil, outcome: .running)) else {
            return XCTFail("upstream does not persist a running receipt")
        }
    }

    func testLegacyPeerAlwaysRemainsAmbiguousEvenWithSamePID() {
        var legacy = record(ambiguous: true)
        legacy.actionID = nil
        guard case .ambiguous = HermesUpdateRecoveryPolicy.decide(
            record: legacy,
            value: status(running: true, pid: 101, actionID: nil,
                          exitCode: nil)) else {
            return XCTFail("legacy PID cannot prove a running action")
        }
        guard case .ambiguous = HermesUpdateRecoveryPolicy.decide(
            record: legacy,
            value: status(running: false, pid: 101, actionID: nil,
                          exitCode: 0)) else {
            return XCTFail("legacy PID cannot prove terminal identity after relaunch")
        }
        guard case .ambiguous = HermesUpdateRecoveryPolicy.decide(
            record: legacy,
            value: status(running: false, pid: nil, actionID: nil,
                          exitCode: 0)) else {
            return XCTFail("legacy restart cannot borrow durable semantics")
        }
    }

    func testMalformedStaleAndSaturatedStatusFailClosed() {
        let marker = "=== hermes-update completed \(actionID) ==="
        var staleObject = status(running: false, pid: nil, actionID: actionID,
                                 exitCode: 0, outcome: .success,
                                 marker: marker).objectValue ?? [:]
        staleObject["receipt"] = receipt(
            .success, started: startedAt.addingTimeInterval(-61))
        let stale = JSONValue.object(staleObject)
        for value in [
            stale,
            JSONValue.object([
                "name": .string("hermes-update"), "running": .bool(false),
                "exit_code": .number(0), "pid": .null,
                "action_id": .string("not-an-id"), "lines": .array([]),
            ]),
            JSONValue.object([
                "name": .string("hermes-update"), "running": .bool(true),
                "exit_code": .null, "pid": .number(101),
                "lines": .array(Array(repeating: .string("x"), count: 2_001)),
            ]),
            JSONValue.object([
                "name": .string("hermes-update"), "running": .bool(true),
                "exit_code": .null, "pid": .number(.nan), "lines": .array([]),
            ]),
        ] {
            guard case .ambiguous = HermesUpdateRecoveryPolicy.decide(
                record: record(), value: value) else {
                return XCTFail("untrusted status must remain ambiguous")
            }
        }
    }

    @MainActor
    func testStartReceiptWithoutCanonicalActionIDPersistsAmbiguousTombstone() throws {
        let legacy = try GatewayOperationsPolicy.acceptedReceipt(.object([
            "ok": .bool(true), "name": .string("hermes-update"),
            "pid": .number(101),
        ]), expectedName: "hermes-update")
        XCTAssertNil(legacy.actionID)
        let malformed = try GatewayOperationsPolicy.acceptedReceipt(.object([
            "ok": .bool(true), "name": .string("hermes-update"),
            "pid": .number(101), "action_id": .string(String(repeating: "A", count: 32)),
        ]), expectedName: "hermes-update")
        XCTAssertNil(malformed.actionID)

        let suite = "HermesUpdateRecoveryMissingID.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DurableHermesUpdateStore(defaults: defaults)
        let runtime = GatewayMaintenanceRuntime(updateStore: store)
        let source = GatewayMaintenanceSource(gatewayID: "gateway-a", profile: "worker")
        XCTAssertTrue(runtime.begin(source: source, action: "hermes-update"))
        runtime.acceptUpdate(source: source, pid: 101, actionID: nil,
                             startedAt: Date())
        XCTAssertEqual(runtime.fence?.outcome, .uncertain)
        XCTAssertNil(store.load()?.actionID)
        XCTAssertEqual(store.load()?.ambiguous, true)
        runtime.removeUpdateRecovery()
    }

    func testReceiptClockBoundsRejectFutureAndReversedIntervals() {
        let marker = "=== hermes-update completed \(actionID) ==="
        let now = startedAt.addingTimeInterval(30)
        var futureObject = status(
            running: false, pid: nil, actionID: actionID,
            exitCode: 0, outcome: .success, marker: marker).objectValue ?? [:]
        futureObject["receipt"] = receipt(
            .success, started: now.addingTimeInterval(61))
        guard case .ambiguous = HermesUpdateRecoveryPolicy.decide(
            record: record(), value: .object(futureObject), now: now) else {
            return XCTFail("future receipt must fail closed")
        }

        let reversed = JSONValue.object([
            "outcome": .string("success"),
            "started_at": iso(now),
            "finished_at": iso(now.addingTimeInterval(-1)),
            "post_sha": .string(String(repeating: "b", count: 40)),
            "post_version": .string("0.20.5"),
            "fleet_states": .array([]),
        ])
        XCTAssertNil(HermesUpdateReceiptSummary(reversed))
    }

    func testReceiptParsesExactPythonFractionalAndWholeSecondTimestamps() {
        for timestamps in [
            ("2026-08-24T15:12:12.123456+00:00", "2026-08-24T15:12:13.654321+00:00"),
            ("2026-08-24T15:12:12+00:00", "2026-08-24T15:12:13+00:00"),
        ] {
            let parsed = HermesUpdateReceiptSummary(.object([
                "outcome": .string("success"),
                "started_at": .string(timestamps.0),
                "finished_at": .string(timestamps.1),
                "post_sha": .string(String(repeating: "b", count: 40)),
                "post_version": .string("0.20.5"),
                "fleet_states": .array([.string("current")]),
            ]))
            XCTAssertNotNil(parsed)
            XCTAssertEqual(parsed?.finishedAt.map { $0 > parsed!.startedAt }, true)
        }
    }

    func testPublicationLeaseRejectsWrongSourceGenerationAndClient() {
        let client = NSObject()
        XCTAssertTrue(HermesUpdateRecoveryPublicationPolicy.accepts(
            capturedGatewayID: "gateway-a", currentGatewayID: "gateway-a",
            capturedGeneration: 4, currentGeneration: 4,
            capturedConnectionRevision: 8, currentConnectionRevision: 8,
            capturedClient: ObjectIdentifier(client),
            currentClient: ObjectIdentifier(client)))
        XCTAssertFalse(HermesUpdateRecoveryPublicationPolicy.accepts(
            capturedGatewayID: "gateway-a", currentGatewayID: "gateway-b",
            capturedGeneration: 4, currentGeneration: 4,
            capturedConnectionRevision: 8, currentConnectionRevision: 8,
            capturedClient: ObjectIdentifier(client),
            currentClient: ObjectIdentifier(client)))
        XCTAssertFalse(HermesUpdateRecoveryPublicationPolicy.accepts(
            capturedGatewayID: "gateway-a", currentGatewayID: "gateway-a",
            capturedGeneration: 4, currentGeneration: 5,
            capturedConnectionRevision: 8, currentConnectionRevision: 9,
            capturedClient: ObjectIdentifier(client),
            currentClient: ObjectIdentifier(NSObject())))
    }

    @MainActor
    func testStoreRelaunchCollisionTerminalRegressionAndCleanup() throws {
        let suite = "HermesUpdateRecoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DurableHermesUpdateStore(defaults: defaults)
        let first = record()
        XCTAssertTrue(store.save(first))
        XCTAssertEqual(DurableHermesUpdateStore(defaults: defaults).load(
            now: startedAt.addingTimeInterval(30)), first,
            "a fresh process must hydrate the exact unresolved action")

        var collision = first
        collision.actionID = String(repeating: "d", count: 32)
        XCTAssertFalse(store.save(collision))
        store.remove(gatewayID: "gateway-b")
        XCTAssertEqual(store.load(now: startedAt.addingTimeInterval(30)), first)

        let runtime = GatewayMaintenanceRuntime(updateStore: store)
        XCTAssertNil(runtime.updateRecord(source: GatewayMaintenanceSource(
            gatewayID: "gateway-a", profile: "other")))
        runtime.applyUpdateRecovery(
            .terminal(outcome: .success, restarted: true), record: first)
        XCTAssertNil(store.load(now: startedAt.addingTimeInterval(30)))
        runtime.applyUpdateRecovery(
            .running(pid: 999, restarted: true), record: first)
        XCTAssertNil(store.load(now: startedAt.addingTimeInterval(30)),
                     "a stale status cannot regress a terminal recovery")
        runtime.removeUpdateRecovery()
    }

    @MainActor
    func testPersistedFenceSurvivesWorkspaceClaimCollisionAndRetriesAdmission() throws {
        let suite = "HermesUpdateRecoveryClaim.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DurableHermesUpdateStore(defaults: defaults)
        var current = record()
        current.startedAt = Date()
        XCTAssertTrue(store.save(current))

        let blocker = try XCTUnwrap(WorkspaceRuntime.shared.claimMutation())
        let runtime = GatewayMaintenanceRuntime(updateStore: store)
        XCTAssertNotNil(runtime.fence,
                        "persisted no-replay authority must remain visible despite collision")
        XCTAssertEqual(runtime.updateRecord(gatewayID: "gateway-a"), current)
        WorkspaceRuntime.shared.releaseMutation(blocker)

        XCTAssertEqual(runtime.updateRecord(gatewayID: "gateway-a"), current)
        XCTAssertNil(WorkspaceRuntime.shared.claimMutation(),
                     "rechecking the record must retry and acquire workspace admission")
        runtime.removeUpdateRecovery()
        let released = try XCTUnwrap(WorkspaceRuntime.shared.claimMutation())
        WorkspaceRuntime.shared.releaseMutation(released)
    }
}
#endif
