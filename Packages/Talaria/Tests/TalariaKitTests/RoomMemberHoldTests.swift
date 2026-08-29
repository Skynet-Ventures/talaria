#if canImport(XCTest)
import XCTest
@testable import TalariaKit

final class RoomMemberHoldTests: XCTestCase {
    private let route = GatewayBotRoute(gatewayID: "mini", profile: "default")
    private let peer = GatewayBotRoute(gatewayID: "lab", profile: "peer")

    func testHoldRoundTripsAndLegacyRoomDefaultsEmpty() throws {
        let thread = RoomThread()
        let hold = RoomMemberHold(member: route, driveEpoch: 4,
                                  threadID: thread.id, attemptID: RoomAttemptID(),
                                  storedSessionID: "stored", runtimeSessionID: "runtime",
                                  interruptState: .ambiguous,
                                  reason: String(repeating: "🛑", count: 400))
        let room = RoomRecord(name: "Held", members: [RoomMember(route: route),
                                                       RoomMember(route: peer)],
                              threads: [thread], memberHolds: [hold], epoch: 4)
        let restored = try JSONDecoder().decode(
            RoomRecord.self, from: JSONEncoder().encode(room))
        XCTAssertEqual(restored.memberHolds.first?.member, route)
        XCTAssertEqual(restored.memberHolds.first?.interruptState, .ambiguous)
        XCTAssertLessThanOrEqual(restored.memberHolds[0].reason.unicodeScalars.count,
                                 RoomMemberHold.maximumReasonScalars)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(room)) as? [String: Any])
        legacy.removeValue(forKey: "memberHolds")
        let decoded = try JSONDecoder().decode(
            RoomRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.memberHolds, [])
    }

    func testHoldValidationRejectsDuplicateRouteAndMalformedSessionIdentity() {
        let members = [RoomMember(route: route), RoomMember(route: peer)]
        var duplicate = RoomRecord(name: "Duplicate", members: members,
                                   memberHolds: [RoomMemberHold(member: route, driveEpoch: 0),
                                                 RoomMemberHold(member: route, driveEpoch: 0)])
        XCTAssertThrowsError(try RoomEngine.validate(duplicate))
        duplicate.memberHolds = [RoomMemberHold(
            member: route, driveEpoch: 0, attemptID: RoomAttemptID(),
            storedSessionID: " stored", runtimeSessionID: "runtime")]
        XCTAssertThrowsError(try RoomEngine.validate(duplicate))
    }

    func testProfileRenameMigratesExactHoldAndCollisionPurgesFailClosed() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-hold-store-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let destination = GatewayBotRoute(gatewayID: "mini", profile: "renamed")
        let room = RoomRecord(name: "Rename", members: [RoomMember(route: route),
                                                         RoomMember(route: peer)],
                              memberHolds: [RoomMemberHold(member: route, driveEpoch: 0)])
        try await store.upsert(room)
        _ = try await store.migrateProfileRoute(from: route, to: destination)
        let migrated = try await store.room(id: room.id)
        XCTAssertEqual(migrated?.memberHolds.map(\.member), [destination])

        let colliding = RoomRecord(name: "Collision",
                                   members: [RoomMember(route: route),
                                             RoomMember(route: destination)],
                                   memberHolds: [RoomMemberHold(member: route, driveEpoch: 0),
                                                 RoomMemberHold(member: destination, driveEpoch: 0)])
        try await store.upsert(colliding)
        _ = try await store.migrateProfileRoute(from: route, to: destination)
        let failedClosed = try await store.room(id: colliding.id)
        XCTAssertEqual(failedClosed?.memberHolds, [])
    }

    func testRetirementDeleteAndSameNameRecreationCannotInheritHold() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-hold-lifecycle-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let original = RoomRecord(name: "Same", members: [RoomMember(route: route),
                                                           RoomMember(route: peer)],
                                  memberHolds: [RoomMemberHold(member: route, driveEpoch: 0)])
        try await store.upsert(original)
        _ = try await store.retireProfileRoute(route)
        let retired = try await store.room(id: original.id)
        XCTAssertEqual(retired?.memberHolds, [])
        try await store.delete(roomID: original.id)

        let replacement = RoomRecord(name: "Same", members: [RoomMember(route: route),
                                                              RoomMember(route: peer)])
        try await store.upsert(replacement)
        XCTAssertNotEqual(original.id, replacement.id)
        let reloaded = try await RoomStore(baseDirectory: base).room(id: replacement.id)
        XCTAssertEqual(reloaded?.memberHolds, [])
    }

    func testRelaunchMigratesPendingToAmbiguousAndPersistsTerminalStatesUnchanged() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-hold-recovery-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: route, epoch: 9,
                                  promptText: "possibly interrupted",
                                  storedSessionID: "stored", runtimeSessionID: "runtime",
                                  state: .accepted)
        let old = Date(timeIntervalSince1970: 10)
        let pending = RoomMemberHold(member: route, driveEpoch: 9,
                                     threadID: thread.id, attemptID: attempt.id,
                                     storedSessionID: attempt.storedSessionID,
                                     runtimeSessionID: attempt.runtimeSessionID,
                                     interruptState: .pending,
                                     createdAt: old, updatedAt: old)
        let terminal = RoomMemberHold(member: peer, driveEpoch: 9,
                                      interruptState: .notNeeded,
                                      createdAt: old, updatedAt: old)
        let room = RoomRecord(name: "Recover", members: [RoomMember(route: route),
                                                          RoomMember(route: peer)],
                              threads: [thread], attempts: [attempt],
                              memberHolds: [pending, terminal], epoch: 9,
                              createdAt: old, updatedAt: old)
        try await RoomStore(baseDirectory: base).upsert(room)

        let firstRelaunch = RoomStore(baseDirectory: base)
        let firstLoad = try await firstRelaunch.loadAll()
        let migrated = try XCTUnwrap(firstLoad.first)
        XCTAssertEqual(migrated.memberHolds[0].interruptState, .ambiguous)
        XCTAssertGreaterThan(migrated.memberHolds[0].updatedAt, old)
        XCTAssertEqual(migrated.memberHolds[0].id, pending.id)
        XCTAssertEqual(migrated.memberHolds[0].attemptID, pending.attemptID)
        XCTAssertEqual(migrated.memberHolds[1], terminal)

        // A second independent reader proves the normalized envelope was
        // atomically persisted rather than changed only in the first cache.
        let secondRelaunch = RoomStore(baseDirectory: base)
        let secondLoad = try await secondRelaunch.loadAll()
        let persisted = try XCTUnwrap(secondLoad.first)
        XCTAssertEqual(persisted.memberHolds[0], migrated.memberHolds[0])
        XCTAssertEqual(persisted.memberHolds[1], terminal)
    }
}
#endif
