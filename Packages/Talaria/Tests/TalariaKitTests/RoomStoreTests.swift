#if canImport(XCTest)
import XCTest
@testable import TalariaKit

final class RoomStoreTests: XCTestCase {
    private let projectedGatewayIDs: Set<String> = ["mini", "lab"]
    private func temporaryBase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("talaria-room-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func members() -> [RoomMember] {
        [
            RoomMember(route: GatewayBotRoute(gatewayID: "mini", profile: "default")),
            RoomMember(route: GatewayBotRoute(gatewayID: "lab", profile: "ops")),
        ]
    }

    private func projectedMembers() -> [RoomProjectionMember] {
        [
            RoomProjectionMember(name: "research", handle: "research",
                                 connectionID: "mini", connectionLabel: "Mini",
                                 sourceScoped: true),
            RoomProjectionMember(name: "ops", handle: "ops",
                                 connectionID: "lab", connectionLabel: "Lab",
                                 sourceScoped: true),
        ]
    }

    private func projectedRoom(name: String = "Shared", revision: UInt64 = 1,
                               entries: [RoomProjectionEntry] = [],
                               members: [RoomProjectionMember]? = nil,
                               image: String? = nil) -> RoomProjectionRoom {
        RoomProjectionRoom(name: name, roomID: "opaque-room", log: entries,
                           revision: revision, members: members ?? projectedMembers(),
                           image: image)
    }

    func testStandaloneRoomRoundTripsWithoutProfileMetadata() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let id = RoomID()
        let room = RoomRecord(id: id, name: "Standalone", members: members())
        let writer = RoomStore(baseDirectory: base)
        try await writer.upsert(room)

        let reader = RoomStore(baseDirectory: base)
        let restored = try await reader.loadAll()
        XCTAssertEqual(restored.map(\.id), [id])
        XCTAssertEqual(restored.first?.name, "Standalone")
    }

    func testComposerDraftSurvivesReloadAndRenameByImmutableRoomID() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let room = RoomRecord(name: "Before", members: members())
        try await store.upsert(room)
        try await store.setComposerDraft("half typed 🚀", roomID: room.id)
        _ = try await store.mutate(roomID: room.id) { $0.name = "After" }

        let relaunched = RoomStore(baseDirectory: base)
        let restoredDraft = try await relaunched.composerDraft(roomID: room.id)
        let restoredRoom = try await relaunched.room(id: room.id)
        XCTAssertEqual(restoredDraft, "half typed 🚀")
        XCTAssertEqual(restoredRoom?.name, "After")
    }

    func testComposerDraftDeleteAndSameNameRecreationCannotInherit() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let original = RoomRecord(name: "Same", members: members())
        try await store.upsert(original)
        try await store.setComposerDraft("belongs only to original", roomID: original.id)
        try await store.delete(roomID: original.id)

        let replacement = RoomRecord(name: "Same", members: members())
        try await store.upsert(replacement)
        XCTAssertNotEqual(original.id, replacement.id)
        let replacementDraft = try await store.composerDraft(roomID: replacement.id)
        XCTAssertEqual(replacementDraft, "")
        do {
            _ = try await store.composerDraft(roomID: original.id)
            XCTFail("a deleted immutable identity must not retain draft authority")
        } catch {
            XCTAssertEqual(error as? RoomStoreError, .roomNotFound(original.id))
        }
        let index = try String(contentsOf: base.appendingPathComponent("Rooms/rooms-v1.json"),
                               encoding: .utf8)
        XCTAssertFalse(index.contains("belongs only to original"))
    }

    func testDeleteAllPurgesComposerDraftFromAuthoritativeEmptyCommit() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let room = RoomRecord(name: "Private", members: members())
        try await store.upsert(room)
        try await store.setComposerDraft("erase this local draft", roomID: room.id)
        try await store.deleteAll()

        let relaunched = RoomStore(baseDirectory: base)
        let restoredRooms = try await relaunched.loadAll()
        XCTAssertTrue(restoredRooms.isEmpty)
        do {
            _ = try await relaunched.composerDraft(roomID: room.id)
            XCTFail("privacy deletion must remove draft and room identity together")
        } catch {
            XCTAssertEqual(error as? RoomStoreError, .roomNotFound(room.id))
        }
    }

    func testLegacyEnvelopeWithoutComposerDraftFieldMigratesToEmpty() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let room = RoomRecord(name: "Legacy", members: members())
        let writer = RoomStore(baseDirectory: base)
        try await writer.upsert(room)
        let indexURL = base.appendingPathComponent("Rooms/rooms-v1.json")
        let data = try Data(contentsOf: indexURL)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "composerDrafts")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: indexURL, options: .atomic)

        let migrated = RoomStore(baseDirectory: base)
        let migratedDraft = try await migrated.composerDraft(roomID: room.id)
        XCTAssertEqual(migratedDraft, "")
    }

    func testMalformedDuplicateComposerDraftRowsFailClosed() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let room = RoomRecord(name: "Duplicate", members: members())
        let writer = RoomStore(baseDirectory: base)
        try await writer.upsert(room)
        try await writer.setComposerDraft("one", roomID: room.id)
        let indexURL = base.appendingPathComponent("Rooms/rooms-v1.json")
        let data = try Data(contentsOf: indexURL)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let drafts = try XCTUnwrap(object["composerDrafts"] as? [[String: Any]])
        object["composerDrafts"] = drafts + drafts
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: indexURL, options: .atomic)

        do {
            _ = try await RoomStore(baseDirectory: base).loadAll()
            XCTFail("duplicate immutable draft identities must fail closed")
        } catch {
            XCTAssertEqual(error as? RoomStoreError, .corruptIndex)
        }
    }

    func testMalformedIndexFailsClosedInsteadOfReturningEmpty() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Rooms", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{not-json".utf8).write(to: root.appendingPathComponent("rooms-v1.json"))
        let store = RoomStore(baseDirectory: base)
        do {
            _ = try await store.loadAll()
            XCTFail("corrupt index must not masquerade as an empty store")
        } catch {
            XCTAssertEqual(error as? RoomStoreError, .corruptIndex)
        }
    }

    func testBlobIsSeparateProtectedStorageAndAccountingIsExact() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        var room = RoomRecord(name: "Files", members: members())
        try await store.upsert(room)
        let payload = Data("room attachment secret bytes".utf8)
        let attachment = try await store.storeBlob(roomID: room.id, data: payload,
                                                   fileName: "note.txt", mediaType: "text/plain")
        let thread = RoomThread()
        room.threads = [thread]
        room.entries = [RoomEntry(threadID: thread.id, speaker: .user, speakerName: "You",
                                  text: "attached", attachments: [attachment])]
        try await store.upsert(room)

        let restoredPayload = try await store.readBlob(roomID: room.id, attachment: attachment)
        XCTAssertEqual(restoredPayload, payload)
        let usage = try await store.storageUsage()
        XCTAssertEqual(usage.blobBytes, Int64(payload.count))
        XCTAssertGreaterThan(usage.indexBytes, 0)
        XCTAssertEqual(usage.totalBytes, usage.indexBytes + Int64(payload.count))
        let index = try String(contentsOf: base.appendingPathComponent("Rooms/rooms-v1.json"),
                               encoding: .utf8)
        XCTAssertFalse(index.contains("room attachment secret bytes"))
        // Injected stores are deterministic test fixtures and remain writable
        // even when the macOS login session is locked. Real Application
        // Support storage always enables complete file protection.
        let injectedProtectsFiles = await store.protectsFiles
        let applicationProtectsFiles = await RoomStore().protectsFiles
        XCTAssertFalse(injectedProtectsFiles)
        XCTAssertTrue(applicationProtectsFiles)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: base.appendingPathComponent("Rooms/rooms-v1.json.tmp").path))
    }

    func testTranscriptPruningDeletesOnlyUnreferencedBlobAndAdjustsWatermark() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        var room = RoomRecord(name: "Bounded", members: members())
        try await store.upsert(room)
        let first = try await store.storeBlob(roomID: room.id, data: Data([1]),
                                              fileName: "old", mediaType: "application/octet-stream")
        let retained = try await store.storeBlob(roomID: room.id, data: Data([2, 3]),
                                                 fileName: "new", mediaType: "application/octet-stream")
        let thread = RoomThread()
        room.threads = [thread]
        room.entries = (0...RoomEngine.retainedEntries).map { index in
            RoomEntry(threadID: thread.id, speaker: .user, speakerName: "You", text: "\(index)",
                      attachments: index == 0 ? [first] : (index == 1 ? [retained] : []))
        }
        let mark = RoomEngine.watermarkKey(threadID: thread.id, member: room.members[0].route)
        room.watermarks = [mark: room.entries.count]
        try await store.upsert(room)
        let loaded = try await store.room(id: room.id)
        let restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.entries.count, RoomEngine.retainedEntries)
        XCTAssertEqual(restored.entries.first?.attachments, [retained])
        XCTAssertEqual(restored.watermarks[mark], RoomEngine.retainedEntries)
        do {
            _ = try await store.readBlob(roomID: room.id, attachment: first)
            XCTFail("pruned blob should be removed")
        } catch { XCTAssertEqual(error as? RoomStoreError, .attachmentNotFound) }
        let retainedPayload = try await store.readBlob(roomID: room.id, attachment: retained)
        XCTAssertEqual(retainedPayload, Data([2, 3]))
    }

    func testPruningRetainsUnfinishedAttemptAndRemovesOrphanWatermark() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let old = RoomThread(createdAt: Date(timeIntervalSince1970: 1))
        let abandoned = RoomThread(createdAt: Date(timeIntervalSince1970: 2))
        let current = RoomThread(createdAt: Date(timeIntervalSince1970: 3))
        let routes = members()
        let attempt = RoomAttempt(threadID: old.id, member: routes[0].route, epoch: 1,
                                  promptText: "reconcile exactly", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", state: .uncertain)
        var entries = [
            RoomEntry(threadID: old.id, speaker: .user, speakerName: "You", text: "old"),
            RoomEntry(threadID: abandoned.id, speaker: .user, speakerName: "You", text: "done"),
        ]
        entries += (0..<RoomEngine.retainedEntries).map {
            RoomEntry(threadID: current.id, speaker: .user, speakerName: "You", text: "new-\($0)")
        }
        let oldMark = RoomEngine.watermarkKey(threadID: old.id, member: routes[0].route)
        let abandonedMark = RoomEngine.watermarkKey(threadID: abandoned.id, member: routes[0].route)
        let room = RoomRecord(name: "Reconcile", members: routes,
                              threads: [old, abandoned, current], entries: entries,
                              attempts: [attempt], watermarks: [oldMark: 1, abandonedMark: 2],
                              epoch: 1)

        try await store.upsert(room)
        let loaded = try await store.room(id: room.id)
        let restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.entries.count, RoomEngine.retainedEntries)
        XCTAssertTrue(restored.threads.contains { $0.id == old.id })
        XCTAssertFalse(restored.threads.contains { $0.id == abandoned.id })
        XCTAssertEqual(restored.attempts.first?.id, attempt.id)
        XCTAssertEqual(restored.attempts.first?.state, .uncertain)
        XCTAssertEqual(restored.watermarks[oldMark], 0)
        XCTAssertNil(restored.watermarks[abandonedMark])
        XCTAssertNoThrow(try RoomEngine.validate(restored))
    }

    func testPrunedEntryBlobSurvivesUntilExactAttemptFinishes() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let old = RoomThread(createdAt: Date(timeIntervalSince1970: 1))
        let current = RoomThread(createdAt: Date(timeIntervalSince1970: 2))
        let routes = members()
        var room = RoomRecord(name: "Exact payload", members: routes,
                              threads: [old, current], epoch: 1)
        try await store.upsert(room)
        let attachment = try await store.storeBlob(roomID: room.id, data: Data([7, 8, 9]),
                                                   fileName: "payload.png", mediaType: "image/png")
        let attempt = RoomAttempt(threadID: old.id, member: routes[0].route, epoch: 1,
                                  promptText: "wait with image", storedSessionID: "stored",
                                  runtimeSessionID: "runtime",
                                  outboundAttachments: [attachment], state: .waiting)
        room.entries = [
            RoomEntry(threadID: old.id, speaker: .user, speakerName: "You", text: "old",
                      attachments: [attachment]),
        ] + (0..<RoomEngine.retainedEntries).map {
            RoomEntry(threadID: current.id, speaker: .user, speakerName: "You", text: "new-\($0)")
        }
        room.attempts = [attempt]
        try await store.upsert(room)

        let loaded = try await store.room(id: room.id)
        let afterPrune = try XCTUnwrap(loaded)
        XCTAssertFalse(afterPrune.entries.flatMap(\.attachments).contains(attachment))
        XCTAssertEqual(afterPrune.attempts.first?.outboundAttachments, [attachment])
        let payload = try await store.readBlob(roomID: room.id, attachment: attachment)
        XCTAssertEqual(payload, Data([7, 8, 9]))

        _ = try await store.mutate(roomID: room.id) { value in
            value.attempts[0].state = .cancelled
            value.attempts[0].finishedAt = Date()
            value.attempts[0].outboundAttachments = []
        }
        do {
            _ = try await store.readBlob(roomID: room.id, attachment: attachment)
            XCTFail("terminal attempt must release its no-longer-referenced blob")
        } catch { XCTAssertEqual(error as? RoomStoreError, .attachmentNotFound) }
    }

    func testMissingReferencedBlobFailsClosedOnFreshLoad() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        var room = RoomRecord(name: "Missing", members: members())
        try await store.upsert(room)
        let attachment = try await store.storeBlob(roomID: room.id, data: Data([7]),
                                                   fileName: "x", mediaType: "x/test")
        let thread = RoomThread()
        room.threads = [thread]
        room.entries = [RoomEntry(threadID: thread.id, speaker: .user, speakerName: "You",
                                  text: "x", attachments: [attachment])]
        try await store.upsert(room)
        let blob = base.appendingPathComponent("Rooms/blobs/\(room.id.description)/\(attachment.blobID)")
        try FileManager.default.removeItem(at: blob)
        let reader = RoomStore(baseDirectory: base)
        do {
            _ = try await reader.loadAll()
            XCTFail("missing referenced bytes must not load as healthy")
        } catch { XCTAssertEqual(error as? RoomStoreError, .corruptAttachment) }
    }

    func testSameSizeBlobTamperingFailsHashValidation() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        var room = RoomRecord(name: "Tamper", members: members())
        try await store.upsert(room)
        let attachment = try await store.storeBlob(roomID: room.id, data: Data([7]),
                                                   fileName: "x", mediaType: "x/test")
        let thread = RoomThread()
        room.threads = [thread]
        room.entries = [RoomEntry(threadID: thread.id, speaker: .user, speakerName: "You",
                                  text: "x", attachments: [attachment])]
        try await store.upsert(room)
        let blob = base.appendingPathComponent("Rooms/blobs/\(room.id.description)/\(attachment.blobID)")
        try Data([8]).write(to: blob)
        do {
            _ = try await RoomStore(baseDirectory: base).loadAll()
            XCTFail("same-size content corruption must not pass the size check")
        } catch { XCTAssertEqual(error as? RoomStoreError, .corruptAttachment) }
    }

    func testOrphanPruningAndRoomDeletionReclaimStorage() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let room = RoomRecord(name: "Delete", members: members())
        try await store.upsert(room)
        _ = try await store.storeBlob(roomID: room.id, data: Data([1, 2, 3]),
                                      fileName: "orphan", mediaType: "x/test")
        let pruned = try await store.pruneOrphanedBlobs()
        XCTAssertEqual(pruned, 1)
        let usage = try await store.storageUsage()
        XCTAssertEqual(usage.blobBytes, 0)
        try await store.delete(roomID: room.id)
        let rooms = try await store.loadAll()
        XCTAssertTrue(rooms.isEmpty)
        do {
            try await store.delete(roomID: room.id)
            XCTFail("second delete must identify missing room")
        } catch { XCTAssertEqual(error as? RoomStoreError, .roomNotFound(room.id)) }
    }

    func testDeleteAllRemovesIndexBlobsAndReloadsEmpty() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        var room = RoomRecord(name: "Erase", members: members())
        try await store.upsert(room)
        room.avatar = try await store.storeBlob(roomID: room.id, data: Data([4, 5, 6]),
                                                fileName: "room.png", mediaType: "image/png")
        try await store.upsert(room)
        let intact = try await RoomStore(baseDirectory: base).loadAll()
        XCTAssertEqual(intact.first?.avatar, room.avatar)
        let before = try await store.storageUsage()
        XCTAssertGreaterThan(before.totalBytes, 0)

        try await store.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("Rooms").path))
        let cached = try await store.loadAll()
        XCTAssertTrue(cached.isEmpty)
        let fresh = RoomStore(baseDirectory: base)
        let reloaded = try await fresh.loadAll()
        XCTAssertTrue(reloaded.isEmpty)
        let after = try await fresh.storageUsage()
        XCTAssertEqual(after, RoomStorageUsage())
    }

    func testDeleteAllRecoversCorruptIndex() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Rooms", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: root.appendingPathComponent("rooms-v1.json"))
        let store = RoomStore(baseDirectory: base)
        try await store.deleteAll()
        let rooms = try await store.loadAll()
        XCTAssertTrue(rooms.isEmpty)
    }

    func testAtomicMutationDoesNotLoseConcurrentEntries() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let thread = RoomThread()
        let room = RoomRecord(name: "Serialized", members: members(), threads: [thread])
        try await store.upsert(room)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    _ = try await store.mutate(roomID: room.id) { record in
                        let entry = RoomEntry(threadID: thread.id, speaker: .user,
                                              speakerName: "You", text: "entry-\(index)")
                        try RoomEngine.append(entry, to: &record)
                    }
                }
            }
            try await group.waitForAll()
        }
        let loaded = try await store.room(id: room.id)
        let restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.entries.count, 20)
        XCTAssertEqual(Set(restored.entries.map(\.text)).count, 20)
    }

    func testSymlinkedStoreAndIndexFailClosed() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("Rooms", isDirectory: true),
            withDestinationURL: outside)
        do {
            _ = try await RoomStore(baseDirectory: base).loadAll()
            XCTFail("symlinked root must fail closed")
        } catch { XCTAssertEqual(error as? RoomStoreError, .unsafePath) }

        try FileManager.default.removeItem(at: base.appendingPathComponent("Rooms"))
        let root = base.appendingPathComponent("Rooms", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = base.appendingPathComponent("outside-index")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("rooms-v1.json"), withDestinationURL: target)
        do {
            _ = try await RoomStore(baseDirectory: base).loadAll()
            XCTFail("symlinked index must fail closed")
        } catch { XCTAssertEqual(error as? RoomStoreError, .unsafePath) }
    }

    func testLegacyThreadMigrationIsPersistedOnLoad() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        var room = RoomRecord(name: "Legacy", members: members(), entries: [
            RoomEntry(speaker: .user, speakerName: "You", text: "hello")
        ])
        // Upsert itself migrates, proving callers cannot persist threadless
        // records; a fresh reader sees the same stable id.
        try await store.upsert(room)
        let loaded = try await store.room(id: room.id)
        room = try XCTUnwrap(loaded)
        let threadID = try XCTUnwrap(room.entries.first?.threadID)
        let reader = RoomStore(baseDirectory: base)
        let restored = try await reader.room(id: room.id)
        XCTAssertEqual(restored?.entries.first?.threadID, threadID)
    }

    func testLiteralPreThreadWireShapeDecodesAndMigrates() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Rooms", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let room = RoomRecord(name: "Legacy wire", members: members(), entries: [
            RoomEntry(speaker: .user, speakerName: "You", text: "before threads")
        ])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(room)) as? [String: Any])
        for key in ["formerMembers", "avatar", "threads", "attempts", "drives", "activity",
                    "memberSessions", "watermarks", "epoch", "needsUser", "updatedAt",
                    "sessionTitleIdentityVersion", "legacySessionTitleName"] {
            object.removeValue(forKey: key)
        }
        var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        entries[0].removeValue(forKey: "threadID")
        entries[0].removeValue(forKey: "sourceLabel")
        entries[0].removeValue(forKey: "attachments")
        object["entries"] = entries
        let envelope: [String: Any] = ["version": RoomStore.schemaVersion, "rooms": [object]]
        try JSONSerialization.data(withJSONObject: envelope)
            .write(to: root.appendingPathComponent("rooms-v1.json"))

        let store = RoomStore(baseDirectory: base)
        let loaded = try await store.loadAll()
        let restored = try XCTUnwrap(loaded.first)
        XCTAssertEqual(restored.id, room.id)
        XCTAssertEqual(restored.sessionTitleIdentityVersion,
                       RoomRecord.legacyNameSessionTitleVersion)
        XCTAssertEqual(restored.legacySessionTitleName, "Legacy wire")
        XCTAssertEqual(restored.entries.first?.attachments, [])
        XCTAssertNotNil(restored.entries.first?.threadID)
        XCTAssertEqual(restored.threads.count, 1)
        XCTAssertNoThrow(try RoomEngine.validate(restored))

        let persisted = try String(contentsOf: root.appendingPathComponent("rooms-v1.json"),
                                   encoding: .utf8)
        XCTAssertTrue(persisted.contains("\"threads\""))
        XCTAssertTrue(persisted.contains("\"attachments\""))
        XCTAssertTrue(persisted.contains("\"sessionTitleIdentityVersion\""))
        XCTAssertTrue(persisted.contains("\"legacySessionTitleName\":\"Legacy wire\""))
    }

    func testLegacySessionTitleMigrationSurvivesDisplayRenameAndReload() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Rooms", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = RoomRecord(name: "Original", members: members(), entries: [])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(legacy)) as? [String: Any])
        object.removeValue(forKey: "sessionTitleIdentityVersion")
        object.removeValue(forKey: "legacySessionTitleName")
        let envelope: [String: Any] = ["version": RoomStore.schemaVersion, "rooms": [object]]
        try JSONSerialization.data(withJSONObject: envelope)
            .write(to: root.appendingPathComponent("rooms-v1.json"))

        let store = RoomStore(baseDirectory: base)
        let loaded = try await store.loadAll()
        let decoded = try XCTUnwrap(loaded.first)
        XCTAssertEqual(decoded.sessionTitleIdentityVersion,
                       RoomRecord.legacyNameSessionTitleVersion)
        XCTAssertEqual(decoded.legacySessionTitleName, "Original")

        _ = try await store.mutate(roomID: decoded.id) { room in
            room.name = "Renamed"
        }
        let reloadedValue = try await RoomStore(baseDirectory: base).room(id: decoded.id)
        let reloaded = try XCTUnwrap(reloadedValue)
        XCTAssertEqual(reloaded.name, "Renamed")
        XCTAssertEqual(reloaded.sessionTitleIdentityVersion,
                       RoomRecord.legacyNameSessionTitleVersion)
        XCTAssertEqual(reloaded.legacySessionTitleName, "Original")
    }

    func testNewRoomRecordRoundTripsImmutableSessionTitleIdentity() throws {
        let room = RoomRecord(name: "Fresh", members: members())
        XCTAssertEqual(room.sessionTitleIdentityVersion,
                       RoomRecord.immutableIDSessionTitleVersion)
        XCTAssertNil(room.legacySessionTitleName)

        let decoded = try JSONDecoder().decode(RoomRecord.self,
                                               from: JSONEncoder().encode(room))
        XCTAssertEqual(decoded.sessionTitleIdentityVersion,
                       RoomRecord.immutableIDSessionTitleVersion)
        XCTAssertNil(decoded.legacySessionTitleName)
    }

    func testMetadataOutboxIsAtomicWithRoomCreateAndDisband() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let room = RoomRecord(name: "Fleet", members: members())
        let add = RoomMetadataMutation(route: room.members[0].route,
                                       kind: .add, newName: room.name)
        try await store.upsert(room, metadataMutations: [add])

        let fresh = RoomStore(baseDirectory: base)
        let createdOutbox = try await fresh.metadataOutbox()
        XCTAssertEqual(createdOutbox, [add])
        let remove = RoomMetadataMutation(route: room.members[0].route,
                                          kind: .remove, oldName: room.name)
        try await fresh.delete(roomID: room.id, metadataMutations: [remove])
        let deletedRoom = try await fresh.room(id: room.id)
        let deletedOutbox = try await fresh.metadataOutbox()
        XCTAssertNil(deletedRoom)
        XCTAssertEqual(deletedOutbox, [add, remove])

        try await fresh.removeMetadataMutation(id: add.id)
        let remainingOutbox = try await fresh.metadataOutbox()
        XCTAssertEqual(remainingOutbox, [remove])
        try await fresh.deleteAll()
        let erased = RoomStore(baseDirectory: base)
        let erasedOutbox = try await erased.metadataOutbox()
        XCTAssertEqual(erasedOutbox, [])
    }

    func testProfileRouteMigrationRekeysEveryRoomProjectionAndOnlyExactOutboxRoutes()
        async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = GatewayBotRoute(gatewayID: "mini", profile: "old")
        let destination = GatewayBotRoute(gatewayID: "mini", profile: "new")
        let sibling = GatewayBotRoute(gatewayID: "lab", profile: "old")
        let sourceMember = RoomMember(route: source, handle: "old",
                                      friendlyName: "Research Buddy")
        let siblingMember = RoomMember(route: sibling, handle: "old-lab")
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: source, epoch: 1,
                                  promptText: "pending", storedSessionID: "stored-old",
                                  runtimeSessionID: "runtime-old", state: .accepted)
        let sourceWatermark = RoomEngine.watermarkKey(threadID: thread.id, member: source)
        let siblingWatermark = RoomEngine.watermarkKey(threadID: thread.id, member: sibling)
        let room = RoomRecord(name: "Fleet", members: [sourceMember, siblingMember],
                              threads: [thread], entries: [
                                  RoomEntry(threadID: thread.id, speaker: .member,
                                            memberRoute: source, speakerName: "old",
                                            text: "hello")
                              ], attempts: [attempt], drives: [
                                  RoomDriveState(threadID: thread.id, epoch: 1,
                                                 roundMembers: [source, sibling],
                                                 nextMemberIndex: 1)
                              ], activity: [
                                  RoomActivity(epoch: 1, kind: .working, member: source,
                                               threadID: thread.id)
                              ], memberSessions: [source.qualifiedID: "stored-old",
                                                  sibling.qualifiedID: "stored-lab"],
                              watermarks: [sourceWatermark: 1, siblingWatermark: 1], epoch: 1)
        let sourceMutation = RoomMetadataMutation(route: source, kind: .rename,
                                                  oldName: "Fleet", newName: "Fleet 2")
        let siblingMutation = RoomMetadataMutation(route: sibling, kind: .rename,
                                                   oldName: "Fleet", newName: "Fleet 2")
        let store = RoomStore(baseDirectory: base)
        try await store.upsert(room, metadataMutations: [sourceMutation, siblingMutation])

        let result = try await store.migrateProfileRoute(from: source, to: destination)
        let migrated = try XCTUnwrap(result.rooms.first)
        XCTAssertEqual(migrated.members.map(\.route), [destination, sibling])
        XCTAssertEqual(migrated.members.first?.friendlyName, "Research Buddy")
        XCTAssertEqual(migrated.entries.first?.memberRoute, destination)
        XCTAssertEqual(migrated.attempts.first?.member, destination)
        XCTAssertEqual(migrated.drives.first?.roundMembers, [destination, sibling])
        XCTAssertEqual(migrated.activity.first?.member, destination)
        XCTAssertEqual(migrated.memberSessions[destination.qualifiedID], "stored-old")
        XCTAssertNil(migrated.memberSessions[source.qualifiedID])
        XCTAssertEqual(migrated.watermarks[RoomEngine.watermarkKey(threadID: thread.id,
                                                                   member: destination)], 1)
        XCTAssertEqual(migrated.watermarks[siblingWatermark], 1)
        XCTAssertNil(migrated.watermarks[sourceWatermark])

        let outbox = try await store.metadataOutbox()
        XCTAssertEqual(outbox.map(\.route), [destination, sibling])
        XCTAssertEqual(result.migratedMutationCount, 1)
        let fresh = RoomStore(baseDirectory: base)
        let freshOutbox = try await fresh.metadataOutbox()
        XCTAssertEqual(freshOutbox.map(\.route), [destination, sibling])
        let loaded = try await fresh.loadAll()
        let reloaded = try XCTUnwrap(loaded.first)
        XCTAssertEqual(reloaded.members.first?.friendlyName, "Research Buddy")
    }

    func testProfileRouteRetirementMovesSeatAndSettlesDurableWork() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = GatewayBotRoute(gatewayID: "mini", profile: "old")
        let sibling = GatewayBotRoute(gatewayID: "lab", profile: "peer")
        let thread = RoomThread()
        let attempt = RoomAttempt(threadID: thread.id, member: source, epoch: 1,
                                  promptText: "pending", storedSessionID: "stored",
                                  runtimeSessionID: "runtime", state: .working)
        let room = RoomRecord(name: "Fleet", members: [
            RoomMember(route: source), RoomMember(route: sibling)
        ], threads: [thread], entries: [
            RoomEntry(threadID: thread.id, speaker: .user, speakerName: "You", text: "go")
        ], attempts: [attempt], drives: [
            RoomDriveState(threadID: thread.id, epoch: 1,
                           roundMembers: [source, sibling], nextMemberIndex: 1)
        ], epoch: 1)
        let mutation = RoomMetadataMutation(route: source, kind: .rename,
                                            oldName: "Fleet", newName: "Fleet 2")
        let store = RoomStore(baseDirectory: base)
        try await store.upsert(room, metadataMutations: [mutation])

        _ = try await store.retireProfileRoute(source)
        let retiredValue = try await store.room(id: room.id)
        let retired = try XCTUnwrap(retiredValue)
        XCTAssertEqual(retired.members.map(\.route), [sibling])
        XCTAssertEqual(retired.formerMembers.map(\.route), [source])
        XCTAssertEqual(retired.attempts.first?.state, .cancelled)
        XCTAssertNotNil(retired.attempts.first?.finishedAt)
        XCTAssertTrue(retired.drives.isEmpty)
        let pending = try await store.metadataOutbox()
        XCTAssertTrue(pending.isEmpty)
        let retiredRoutes = try await store.retiredMetadataRoutes()
        XCTAssertEqual(retiredRoutes, [source])
        XCTAssertNoThrow(try RoomEngine.validate(retired))
    }

    func testProfileRouteMigrationDedupesLiveDestinationDriveCursor() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = GatewayBotRoute(gatewayID: "mini", profile: "old")
        let destination = GatewayBotRoute(gatewayID: "mini", profile: "new")
        let peer = GatewayBotRoute(gatewayID: "lab", profile: "peer")
        let thread = RoomThread()
        let room = RoomRecord(name: "Fleet", members: [
            RoomMember(route: source), RoomMember(route: destination), RoomMember(route: peer)
        ], threads: [thread], entries: [
            RoomEntry(threadID: thread.id, speaker: .user, speakerName: "You", text: "go")
        ], drives: [RoomDriveState(threadID: thread.id, epoch: 1,
                                   roundMembers: [source, destination, peer],
                                   nextMemberIndex: 1)], epoch: 1)
        let store = RoomStore(baseDirectory: base)
        try await store.upsert(room)
        let result = try await store.migrateProfileRoute(from: source, to: destination)
        let migrated = try XCTUnwrap(result.rooms.first)
        XCTAssertEqual(migrated.drives.first?.roundMembers, [destination, peer])
        XCTAssertEqual(migrated.drives.first?.nextMemberIndex, 1)
        XCTAssertNoThrow(try RoomEngine.validate(migrated))
    }

    func testMetadataRenamePreservesOrderedLegacyProjectionAndDedupes() {
        let renamed = BotModeMeta.replacingGroup("A", with: "C", in: ["A", "B"])
        XCTAssertEqual(renamed, ["C", "B"])
        XCTAssertEqual(BotModeMeta.membershipProjection(renamed)["group"], .string("C"))
        XCTAssertEqual(BotModeMeta.replacingGroup("A", with: "B", in: ["A", "B"]), ["B"])
    }

    func testMetadataOutboxRejectsMalformedDuplicateAndOversizedCommands() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let room = RoomRecord(name: "Fleet", members: members())
        let valid = RoomMetadataMutation(route: room.members[0].route,
                                         kind: .add, newName: room.name)
        let malformed = RoomMetadataMutation(route: room.members[0].route,
                                             kind: .rename, oldName: "Fleet", newName: " ")
        do { try await store.upsert(room, metadataMutations: [malformed]); XCTFail("accepted malformed") }
        catch { XCTAssertEqual(error as? RoomStoreError, .corruptIndex) }
        do { try await store.upsert(room, metadataMutations: [valid, valid]); XCTFail("accepted duplicate") }
        catch { XCTAssertEqual(error as? RoomStoreError, .corruptIndex) }
        let oversized = (0...RoomStore.maximumMetadataOutboxCount).map { offset in
            RoomMetadataMutation(route: room.members[0].route, kind: .add,
                                 newName: "R\(offset)")
        }
        do { try await store.upsert(room, metadataMutations: oversized); XCTFail("accepted oversized") }
        catch { XCTAssertEqual(error as? RoomStoreError, .corruptIndex) }
    }

    func testMalformedPersistedMetadataOutboxFailsClosedOnLoad() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let room = RoomRecord(name: "Fleet", members: members())
        let valid = RoomMetadataMutation(route: room.members[0].route,
                                         kind: .add, newName: room.name)
        try await RoomStore(baseDirectory: base).upsert(room, metadataMutations: [valid])
        let indexURL = base.appendingPathComponent("Rooms/rooms-v1.json")
        let data = try Data(contentsOf: indexURL)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var outbox = try XCTUnwrap(root["metadataOutbox"] as? [[String: Any]])
        outbox[0]["newName"] = ""
        root["metadataOutbox"] = outbox
        try JSONSerialization.data(withJSONObject: root).write(to: indexURL, options: .atomic)

        do {
            _ = try await RoomStore(baseDirectory: base).loadAll()
            XCTFail("malformed durable outbox must fail closed")
        } catch {
            XCTAssertEqual(error as? RoomStoreError, .corruptIndex)
        }
    }

    func testRoomProjectionNormalizesLegacyVersionsAndRestoresDurableRoomID() throws {
        let v1: JSONValue = [
            "version": 1,
            "updatedAt": 55,
            "rooms": [
                "Legacy": [
                    "log": [[
                        "from": ["kind": "user", "name": "You"],
                        "text": "old", "at": 10,
                    ]],
                    "members": [["name": "research"]],
                ],
            ],
            "deleted": ["Gone": 999_999_999],
        ]
        let normalizedV1 = RoomProjectionEnvelope.normalized(v1)
        XCTAssertEqual(normalizedV1.version, 3)
        XCTAssertEqual(normalizedV1.rooms["name:Legacy"]?.name, "Legacy")
        XCTAssertEqual(normalizedV1.deleted["name:Gone"], 0,
                       "v1 wall-clock tombstones must not become revisions")

        let v2: JSONValue = [
            "version": 2,
            "rooms": [
                "Legacy": ["revision": 7, "log": []],
            ],
            "deleted": ["Gone": 8],
        ]
        let normalizedV2 = RoomProjectionEnvelope.normalized(v2)
        XCTAssertEqual(normalizedV2.rooms["name:Legacy"]?.revision, 7)
        XCTAssertEqual(normalizedV2.deleted["name:Gone"], 8)

        // Exact upstream durableGroupChatRooms omitted roomId. The durable
        // id-key is nevertheless sufficient and must repair the stored value.
        let omittedID: JSONValue = [
            "version": 3,
            "rooms": [
                "id:r-keep": ["name": "Renamed", "revision": 4, "log": []],
            ],
        ]
        let repaired = RoomProjectionEnvelope.normalized(omittedID)
        XCTAssertEqual(repaired.rooms["id:r-keep"]?.roomID, "r-keep")
        let roundTrip = try JSONDecoder().decode(
            RoomProjectionEnvelope.self,
            from: JSONEncoder().encode(repaired)
        )
        XCTAssertEqual(roundTrip.rooms["id:r-keep"]?.roomID, "r-keep")
    }

    func testRoomProjectionBoundsMessagesTextImageEnvelopeAndTombstones() {
        let author = RoomProjectionAuthor(kind: .member, name: "research")
        let log = (0..<40).map { index in
            RoomProjectionEntry(id: "m-\(index)", from: author,
                                text: "\(index):" + String(repeating: "🧠", count: 2_000),
                                at: Int64(index))
        }
        var rooms: [String: RoomProjectionRoom] = [:]
        for index in 0..<12 {
            rooms["id:r-\(index)"] = RoomProjectionRoom(
                name: "Room \(index)", roomID: "r-\(index)", log: log,
                members: (0..<10).map {
                    RoomProjectionMember(name: "member-\($0)", connectionID: "gateway-\($0)")
                },
                image: index == 11 ? String(repeating: "x", count: 24_001) : nil
            )
        }
        let deleted = Dictionary(uniqueKeysWithValues: (0..<100).map {
            ("id:dead-\($0)", UInt64($0))
        })
        let envelope = RoomProjectionEnvelope(updatedAt: 42, rooms: rooms, deleted: deleted)

        XCTAssertLessThanOrEqual(envelope.gatewayJSONSize,
                                 RoomProjectionEnvelope.maximumGatewayJSONBytes)
        XCTAssertLessThanOrEqual(envelope.deleted.count,
                                 RoomProjectionEnvelope.maximumTombstones)
        XCTAssertTrue(envelope.rooms.values.allSatisfy {
            $0.log.count <= RoomProjectionEnvelope.maximumMessagesPerRoom
                && $0.log.allSatisfy {
                    $0.text.count <= RoomProjectionEnvelope.maximumTextCharacters
                }
                && $0.members.count <= RoomProjectionEnvelope.maximumMembersPerRoom
                && ($0.image?.count ?? 0) <= RoomProjectionEnvelope.maximumImageCharacters
        })
        XCTAssertEqual(envelope.deleted.values.max(), 99)

        var mutated = RoomProjectionEnvelope()
        mutated.rooms = rooms
        mutated.deleted = deleted
        let outbound = RoomProjectionEnvelope(uiMeta: mutated.uiMetaPatch)
        XCTAssertNotNil(outbound)
        XCTAssertLessThanOrEqual(outbound?.gatewayJSONSize ?? .max,
                                 RoomProjectionEnvelope.maximumGatewayJSONBytes)
        XCTAssertLessThanOrEqual(outbound?.deleted.count ?? .max,
                                 RoomProjectionEnvelope.maximumTombstones)
        XCTAssertTrue(outbound?.rooms.values.allSatisfy {
            $0.log.count <= RoomProjectionEnvelope.maximumMessagesPerRoom
        } == true)
    }

    func testRoomProjectionAppliesUnionedTombstonesBeforeRetentionBound() {
        let user = RoomProjectionAuthor(kind: .user, name: "You")
        let victimKey = "id:victim"
        let victim = RoomProjectionRoom(
            name: "Victim", roomID: "victim",
            log: [RoomProjectionEntry(id: "old", from: user, text: "old", at: 1)],
            revision: 999
        )
        let remoteDeleted = Dictionary(uniqueKeysWithValues: (0..<63).map {
            ("id:remote-\($0)", UInt64(200 + $0))
        })
        var localDeleted = Dictionary(uniqueKeysWithValues: (0..<63).map {
            ("id:local-\($0)", UInt64(100 + $0))
        })
        localDeleted[victimKey] = 1

        let merged = RoomProjectionEnvelope.merging(
            remote: RoomProjectionEnvelope(rooms: [victimKey: victim],
                                           deleted: remoteDeleted),
            local: RoomProjectionEnvelope(deleted: localDeleted)
        )

        XCTAssertNil(merged.rooms[victimKey],
                     "every explicit id tombstone applies before retention bounding")
        XCTAssertLessThanOrEqual(merged.deleted.count,
                                 RoomProjectionEnvelope.maximumTombstones)
        XCTAssertNil(merged.deleted[victimKey],
                     "the lower-ranked applied tombstone need not be retained")
    }

    func testRoomProjectionMergeUnionsOmissionsAndAppliesTombstoneClasses() {
        let user = RoomProjectionAuthor(kind: .user, name: "You")
        let remote = RoomProjectionEnvelope(rooms: [
            "id:shared": RoomProjectionRoom(
                name: "Old", roomID: "shared",
                log: [RoomProjectionEntry(id: "remote", from: user,
                                          text: "remote", at: 20)],
                revision: 4,
                members: [RoomProjectionMember(name: "remote")]
            ),
            "id:zombie": RoomProjectionRoom(
                name: "Zombie", roomID: "zombie",
                log: [RoomProjectionEntry(id: "stale", from: user,
                                          text: "stale", at: 1)],
                revision: 40
            ),
            "name:Legacy": RoomProjectionRoom(
                name: "Legacy",
                log: [RoomProjectionEntry(id: "legacy", from: user,
                                          text: "old", at: 1)],
                revision: 8
            ),
            "id:remote-only": RoomProjectionRoom(name: "Remote only", roomID: "remote-only",
                                                   log: [], revision: 1),
        ])
        let local = RoomProjectionEnvelope(rooms: [
            "id:shared": RoomProjectionRoom(
                name: "New", roomID: "shared",
                log: [RoomProjectionEntry(id: "local", from: user,
                                          text: "local", at: 10)],
                revision: 4,
                members: [RoomProjectionMember(name: "local")]
            ),
        ], deleted: ["id:zombie": 3, "name:Legacy": 7])

        let merged = RoomProjectionEnvelope.merging(
            remote: remote, local: local,
            intent: RoomProjectionMergeIntent(changedRooms: ["id:shared"],
                                              writeRevision: 5),
            updatedAt: 99
        )
        XCTAssertEqual(merged.rooms["id:shared"]?.name, "New")
        XCTAssertEqual(merged.rooms["id:shared"]?.revision, 5)
        XCTAssertEqual(merged.rooms["id:shared"]?.log.map(\.id), ["local", "remote"])
        XCTAssertNotNil(merged.rooms["id:remote-only"],
                        "missing local projection rows are not deletions")
        XCTAssertNil(merged.rooms["id:zombie"], "id tombstones are final")
        XCTAssertEqual(merged.deleted["id:zombie"], 3)
        XCTAssertNotNil(merged.rooms["name:Legacy"],
                        "older legacy tombstone cannot delete a newer room revision")
        XCTAssertNil(merged.deleted["name:Legacy"])

        let disbanded = RoomProjectionEnvelope.merging(
            remote: merged,
            local: RoomProjectionEnvelope(),
            intent: RoomProjectionMergeIntent(deletedRooms: ["id:shared"],
                                              writeRevision: 6)
        )
        XCTAssertNil(disbanded.rooms["id:shared"])
        XCTAssertEqual(disbanded.deleted["id:shared"], 6)
    }

    func testRoomProjectionRenameJobPreservesDurableIDAndRetiresLegacyName() {
        let user = RoomProjectionAuthor(kind: .user, name: "You")
        let history = [RoomProjectionEntry(id: "h1", from: user,
                                           text: "history", at: 5)]
        let remote = RoomProjectionEnvelope(rooms: [
            "id:room-3": RoomProjectionRoom(
                name: "Old", roomID: "room-3", log: history, revision: 2
            ),
        ])
        let local = RoomProjectionEnvelope(rooms: [
            "id:room-3": RoomProjectionRoom(
                name: "New", roomID: "room-3", log: history, revision: 2
            ),
        ])

        // This is the exact Desktop rename job shape. The old and new display
        // labels resolve to the same immutable id key, which must never be
        // tombstoned. A legacy name-key tombstone still retires v1/v2 copies.
        let renamed = RoomProjectionEnvelope.merging(
            remote: remote,
            local: local,
            intent: RoomProjectionMergeIntent(
                changedRooms: ["New"], deletedRooms: ["Old"], writeRevision: 3
            )
        )

        XCTAssertEqual(renamed.rooms["id:room-3"]?.name, "New")
        XCTAssertEqual(renamed.rooms["id:room-3"]?.revision, 3)
        XCTAssertNil(renamed.deleted["id:room-3"])
        XCTAssertEqual(renamed.deleted["name:Old"], 3)
    }

    func testRoomStorePersistsProjectionLedgerWithoutPruningRichRooms() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let thread = RoomThread()
        let localRoom = RoomRecord(name: "Protected", members: members(),
                                   threads: [thread], entries: [
            RoomEntry(threadID: thread.id, speaker: .user, speakerName: "You",
                      text: "full protected transcript")
        ])
        try await store.upsert(localRoom)

        let projected = RoomProjectionEnvelope(rooms: [
            "id:desktop-room": RoomProjectionRoom(
                name: "Desktop", roomID: "desktop-room",
                log: [RoomProjectionEntry(
                    id: "desktop-message",
                    from: RoomProjectionAuthor(kind: .member, name: "research"),
                    text: "bounded remote", at: 1
                )],
                revision: 2,
                members: [RoomProjectionMember(name: "research", connectionID: "mini",
                                                sourceScoped: true)]
            ),
        ])
        _ = try await store.mergeRoomProjection(projected)
        // A truncated/empty later projection cannot imply deletion.
        _ = try await store.mergeRoomProjection(RoomProjectionEnvelope(updatedAt: 3))

        let reader = RoomStore(baseDirectory: base)
        let restoredProjection = try await reader.roomProjection()
        XCTAssertEqual(restoredProjection.rooms, projected.rooms)
        XCTAssertEqual(restoredProjection.updatedAt, 3)
        let restoredRooms = try await reader.loadAll()
        XCTAssertEqual(restoredRooms.first?.entries.first?.text, "full protected transcript")

        let tombstone = RoomProjectionEnvelope(deleted: ["id:desktop-room": 3])
        let deleted = try await reader.mergeRoomProjection(tombstone)
        XCTAssertNil(deleted.rooms["id:desktop-room"])
        XCTAssertEqual(deleted.deleted["id:desktop-room"], 3)
        let protectedRoom = try await reader.room(id: localRoom.id)
        XCTAssertEqual(protectedRoom?.entries.count, 1)

        try await reader.deleteAll()
        let emptyProjection = try await reader.roomProjection()
        XCTAssertEqual(emptyProjection, RoomProjectionEnvelope())
    }

    func testMalformedPersistedProjectionFailsClosedInsteadOfErasingLedger() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        _ = try await store.loadAll()
        _ = try await store.mergeRoomProjection(RoomProjectionEnvelope(rooms: [
            "id:kept": RoomProjectionRoom(name: "Kept", roomID: "kept", log: []),
        ]))

        let indexURL = base.appendingPathComponent("Rooms/rooms-v1.json")
        let data = try Data(contentsOf: indexURL)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        root["roomProjection"] = [
            "version": 3,
            "updatedAt": 0,
            "rooms": "truncated",
        ]
        try JSONSerialization.data(withJSONObject: root).write(to: indexURL, options: .atomic)

        do {
            _ = try await RoomStore(baseDirectory: base).loadAll()
            XCTFail("a present malformed durable projection must fail closed")
        } catch {
            XCTAssertEqual(error as? RoomStoreError, .corruptIndex)
        }
    }

    func testOpaqueProjectionIdentitiesHydrateDeterministicallyAndPublishUnchanged() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let key = "id:desktop/opaque-room"
        let entry = RoomProjectionEntry(
            id: "message:opaque/7",
            from: RoomProjectionAuthor(kind: .member, name: "research", source: "mini"),
            text: "from Desktop", at: 1_700_000_000_000,
            thread: "thread:opaque/main"
        )
        let projection = RoomProjectionEnvelope(rooms: [
            key: RoomProjectionRoom(name: "Opaque", roomID: "desktop/opaque-room",
                                    log: [entry], revision: 4,
                                    members: projectedMembers()),
        ])

        let store = RoomStore(baseDirectory: base)
        let result = try await store.reconcileRoomProjection(
            projection, allowedGatewayIDs: projectedGatewayIDs)
        let room = try XCTUnwrap(result.rooms.first)
        XCTAssertEqual(room.id, RoomProjectionEnvelope.localRoomID(forProjectionKey: key))
        XCTAssertEqual(room.rawProjectionRoomKey, key)
        XCTAssertEqual(room.rawProjectionRevision, 4)
        XCTAssertEqual(room.entries.first?.rawProjectionEntryID, "message:opaque/7")
        XCTAssertEqual(room.entries.first?.rawProjectionThreadID, "thread:opaque/main")
        XCTAssertEqual(room.entries.first?.memberRoute,
                       GatewayBotRoute(gatewayID: "mini", profile: "research"))

        let republished = RoomProjectionEnvelope.projecting(result.rooms, updatedAt: 9)
        XCTAssertEqual(Set(republished.rooms.keys), [key])
        XCTAssertEqual(republished.rooms[key]?.roomID, "desktop/opaque-room")
        XCTAssertEqual(republished.rooms[key]?.log.first?.id, "message:opaque/7")
        XCTAssertEqual(republished.rooms[key]?.log.first?.thread, "thread:opaque/main")
        XCTAssertEqual(republished.rooms[key]?.revision, 4)

        let uuid = UUID(uuidString: "5D35C654-7692-49B2-BC23-2D36EDDCFB40")!
        XCTAssertEqual(RoomProjectionEnvelope.localRoomID(
            forProjectionKey: "id:\(uuid.uuidString)")?.rawValue, uuid)
        XCTAssertEqual(RoomProjectionEnvelope.localThreadID(
            forProjectionID: uuid.uuidString)?.rawValue, uuid)
        XCTAssertEqual(RoomProjectionEnvelope.localEntryID(
            forProjectionID: uuid.uuidString)?.rawValue, uuid)
        XCTAssertEqual(RoomProjectionEnvelope.localRoomID(forProjectionKey: key),
                       RoomProjectionEnvelope.localRoomID(forProjectionKey: key))
        XCTAssertNotEqual(RoomProjectionEnvelope.localThreadID(
            forProjectionID: "same-opaque")?.rawValue,
                          RoomProjectionEnvelope.localEntryID(
            forProjectionID: "same-opaque")?.rawValue)
    }

    func testColdProjectionHydrationPersistsRichRoomLedgerAndStrictImageBytes() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let imageBytes = Data([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
        let image = "data:image/png;base64,\(imageBytes.base64EncodedString())"
        let log = [
            RoomProjectionEntry(
                id: "u-1", from: RoomProjectionAuthor(kind: .user, name: "You"),
                text: "question", at: 1_000, thread: "topic-a"),
            RoomProjectionEntry(
                id: "m-1", from: RoomProjectionAuthor(
                    kind: .member, name: "ops", source: "lab"),
                text: "answer", at: 2_000, thread: "topic-a"),
        ]
        let projection = RoomProjectionEnvelope(updatedAt: 3, rooms: [
            "id:opaque-room": projectedRoom(entries: log, image: image),
        ])
        let store = RoomStore(baseDirectory: base)
        let committed = try await store.reconcileRoomProjection(
            projection, allowedGatewayIDs: projectedGatewayIDs)
        let room = try XCTUnwrap(committed.rooms.first)

        XCTAssertEqual(room.members.map(\.route), [
            GatewayBotRoute(gatewayID: "mini", profile: "research"),
            GatewayBotRoute(gatewayID: "lab", profile: "ops"),
        ])
        XCTAssertEqual(room.entries.map(\.text), ["question", "answer"])
        XCTAssertEqual(room.threads.count, 1)
        XCTAssertEqual(committed.projectedImages[room.id], imageBytes)

        let reader = RoomStore(baseDirectory: base)
        let restored = try await reader.loadAll()
        let restoredProjection = try await reader.roomProjection()
        XCTAssertEqual(restored, committed.rooms)
        XCTAssertEqual(restoredProjection, committed.roomProjection)

        let malformed = RoomProjectionEnvelope(rooms: [
            "id:bad-image": RoomProjectionRoom(
                name: "Bad image", roomID: "bad-image", log: [], revision: 1,
                members: projectedMembers(), image: "data:image/png;base64,%%%"),
        ])
        let afterMalformed = try await reader.reconcileRoomProjection(
            malformed, allowedGatewayIDs: projectedGatewayIDs)
        let badID = try XCTUnwrap(RoomProjectionEnvelope.localRoomID(
            forProjectionKey: "id:bad-image"))
        XCTAssertNotNil(afterMalformed.rooms.first { $0.id == badID })
        XCTAssertNil(afterMalformed.projectedImages[badID])
    }

    func testRichSameIDEntryAndRuntimeStateWinWhileMissingProjectionRowsUnion() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let key = "id:opaque-room"
        let initial = RoomProjectionEnvelope(rooms: [
            key: projectedRoom(entries: [RoomProjectionEntry(
                id: "shared-message",
                from: RoomProjectionAuthor(kind: .user, name: "You"),
                text: "projected original", at: 1_000, thread: "topic")]),
        ])
        let store = RoomStore(baseDirectory: base)
        let first = try await store.reconcileRoomProjection(
            initial, allowedGatewayIDs: projectedGatewayIDs)
        let roomID = try XCTUnwrap(first.rooms.first?.id)
        let attachment = try await store.storeBlob(
            roomID: roomID, data: Data([4, 5, 6]), fileName: "rich.bin",
            mediaType: "application/octet-stream")
        let rich = try await store.mutate(roomID: roomID) { room in
            room.entries[0].text = "full protected local text"
            room.entries[0].attachments = [attachment]
            room.memberSessions[room.members[0].route.qualifiedID] = "stored-session"
            let thread = room.entries[0].threadID!
            room.watermarks[RoomEngine.watermarkKey(
                threadID: thread, member: room.members[0].route)] = 1
            room.attempts = [RoomAttempt(
                threadID: thread, member: room.members[0].route, epoch: room.epoch,
                promptText: "protected attempt", storedSessionID: "stored",
                runtimeSessionID: "runtime", state: .accepted,
                baselineMessageCount: 1)]
        }

        let incoming = RoomProjectionEnvelope(rooms: [
            key: projectedRoom(revision: 2, entries: [
                RoomProjectionEntry(
                    id: "shared-message",
                    from: RoomProjectionAuthor(kind: .user, name: "You"),
                    text: "short remote replacement", at: 1_000, thread: "topic"),
                RoomProjectionEntry(
                    id: "new-message",
                    from: RoomProjectionAuthor(kind: .member, name: "ops", source: "lab"),
                    text: "missing remote row", at: 2_000, thread: "topic"),
            ]),
        ])
        let reconciled = try await store.reconcileRoomProjection(
            incoming, allowedGatewayIDs: projectedGatewayIDs)
        let room = try XCTUnwrap(reconciled.rooms.first { $0.id == roomID })
        XCTAssertEqual(room.entries.map(\.text),
                       ["full protected local text", "missing remote row"])
        XCTAssertEqual(room.entries[0].attachments, [attachment])
        XCTAssertEqual(room.memberSessions, rich.memberSessions)
        XCTAssertEqual(room.watermarks, rich.watermarks)
        XCTAssertEqual(room.attempts, rich.attempts)
        let payload = try await store.readBlob(roomID: roomID, attachment: attachment)
        XCTAssertEqual(payload, Data([4, 5, 6]))
    }

    func testHigherRevisionRenamesSameRoomAndPreservesRicherMemberFields() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let key = "id:rename-opaque"
        let store = RoomStore(baseDirectory: base)
        let first = try await store.reconcileRoomProjection(RoomProjectionEnvelope(rooms: [
            key: RoomProjectionRoom(name: "Old", roomID: "rename-opaque", log: [],
                                    revision: 1, members: projectedMembers()),
        ]), allowedGatewayIDs: projectedGatewayIDs)
        let roomID = try XCTUnwrap(first.rooms.first?.id)
        _ = try await store.mutate(roomID: roomID) { room in
            room.members[0].title = "Rich local title"
            room.members[0].friendlyName = "Research Buddy"
            room.members[0].rawDisplayName = "Research Core"
            room.members[0].sourceLabel = "Trusted Mini"
        }
        var newerMembers = projectedMembers()
        newerMembers[0].handle = "remote-handle"
        newerMembers[0].connectionLabel = "Remote Label"
        let renamed = try await store.reconcileRoomProjection(RoomProjectionEnvelope(rooms: [
            key: RoomProjectionRoom(name: "New", roomID: "rename-opaque", log: [],
                                    revision: 2, members: newerMembers),
        ]), allowedGatewayIDs: projectedGatewayIDs)
        let room = try XCTUnwrap(renamed.rooms.first { $0.id == roomID })
        XCTAssertEqual(renamed.rooms.count, 1)
        XCTAssertEqual(room.name, "New")
        XCTAssertEqual(room.rawProjectionRevision, 2)
        XCTAssertEqual(room.members[0].title, "Rich local title")
        XCTAssertEqual(room.members[0].friendlyName, "Research Buddy")
        XCTAssertEqual(room.members[0].rawDisplayName, "Research Core")
        XCTAssertEqual(room.members[0].sourceLabel, "Trusted Mini")
        XCTAssertEqual(room.members[0].handle, "research")
    }

    func testUnsafeHigherRevisionIdentityOverlayStaysLedgerOnlyUntilSafe() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let key = "id:safe-overlay"
        let store = RoomStore(baseDirectory: base)
        let first = try await store.reconcileRoomProjection(RoomProjectionEnvelope(rooms: [
            key: RoomProjectionRoom(name: "Protected", roomID: "safe-overlay", log: [],
                                    revision: 1, members: projectedMembers()),
        ]), allowedGatewayIDs: projectedGatewayIDs)
        let roomID = try XCTUnwrap(first.rooms.first?.id)
        let image = "data:image/png;base64,\(Data([1, 2, 3]).base64EncodedString())"
        let unsafe = try await store.reconcileRoomProjection(RoomProjectionEnvelope(rooms: [
            key: RoomProjectionRoom(
                name: "Unsafe rename", roomID: "safe-overlay", log: [], revision: 2,
                members: [projectedMembers()[0]], image: image),
        ]), allowedGatewayIDs: projectedGatewayIDs)
        let protected = try XCTUnwrap(unsafe.rooms.first { $0.id == roomID })
        XCTAssertEqual(protected.name, "Protected")
        XCTAssertEqual(protected.rawProjectionRevision, 1)
        XCTAssertNil(unsafe.projectedImages[roomID])
        XCTAssertEqual(unsafe.roomProjection.rooms[key]?.name, "Unsafe rename",
                       "the untrusted identity remains available in the ledger")

        let safe = try await store.reconcileRoomProjection(RoomProjectionEnvelope(rooms: [
            key: RoomProjectionRoom(name: "Safe rename", roomID: "safe-overlay", log: [],
                                    revision: 2, members: projectedMembers(), image: image),
        ]), allowedGatewayIDs: projectedGatewayIDs)
        let renamed = try XCTUnwrap(safe.rooms.first { $0.id == roomID })
        XCTAssertEqual(renamed.name, "Safe rename")
        XCTAssertEqual(renamed.rawProjectionRevision, 2)
        XCTAssertEqual(safe.projectedImages[roomID], Data([1, 2, 3]))
    }

    func testProjectionTombstonesDeleteMatchingRichRoomsUnlessExplicitlyPreserved() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let idKey = "id:tombstone-opaque"
        let legacyKey = "name:Legacy"
        let store = RoomStore(baseDirectory: base)
        let hydrated = try await store.reconcileRoomProjection(RoomProjectionEnvelope(rooms: [
            idKey: RoomProjectionRoom(name: "ID room", roomID: "tombstone-opaque",
                                      log: [], revision: 3, members: projectedMembers()),
            legacyKey: RoomProjectionRoom(name: "Legacy", log: [], revision: 3,
                                          members: projectedMembers()),
        ]), allowedGatewayIDs: projectedGatewayIDs)
        let idRoomID = try XCTUnwrap(RoomProjectionEnvelope.localRoomID(
            forProjectionKey: idKey))
        let legacyRoomID = try XCTUnwrap(RoomProjectionEnvelope.localRoomID(
            forProjectionKey: legacyKey))
        XCTAssertEqual(Set(hydrated.rooms.map(\.id)), [idRoomID, legacyRoomID])
        try await store.setComposerDraft("preserved until fence releases", roomID: idRoomID)
        try await store.setComposerDraft("delete with remote room", roomID: legacyRoomID)

        let fenced = try await store.reconcileRoomProjection(
            RoomProjectionEnvelope(deleted: [idKey: 1, legacyKey: 3]),
            preservingRoomIDs: [idRoomID],
            allowedGatewayIDs: projectedGatewayIDs)
        XCTAssertNotNil(fenced.rooms.first { $0.id == idRoomID })
        XCTAssertNil(fenced.rooms.first { $0.id == legacyRoomID })
        let preservedDraft = try await store.composerDraft(roomID: idRoomID)
        XCTAssertEqual(preservedDraft, "preserved until fence releases")
        do {
            _ = try await store.composerDraft(roomID: legacyRoomID)
            XCTFail("an authoritative remote deletion must purge its local draft")
        } catch {
            XCTAssertEqual(error as? RoomStoreError, .roomNotFound(legacyRoomID))
        }
        XCTAssertNil(fenced.roomProjection.rooms[idKey])
        XCTAssertNil(fenced.roomProjection.rooms[legacyKey])

        // The durable id tombstone remains authoritative after the temporary
        // preservation fence is released. An empty projection is omission,
        // but it does not erase that explicit prior deletion.
        let released = try await store.reconcileRoomProjection(RoomProjectionEnvelope())
        XCTAssertNil(released.rooms.first { $0.id == idRoomID })
        XCTAssertTrue(released.rooms.isEmpty)
        do {
            _ = try await store.composerDraft(roomID: idRoomID)
            XCTFail("the released tombstone must purge the formerly fenced draft")
        } catch {
            XCTAssertEqual(error as? RoomStoreError, .roomNotFound(idRoomID))
        }
    }

    func testMalformedModernMembersOrUnroutableAuthorsRemainLedgerOnly() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let malformedMembers = [
            RoomProjectionMember(name: "research", connectionID: "mini",
                                 sourceScoped: true),
            RoomProjectionMember(name: "legacy-bare"),
        ]
        let badAuthorLog = [RoomProjectionEntry(
            id: "bad-author",
            from: RoomProjectionAuthor(kind: .member, name: "ghost", source: "unknown"),
            text: "cannot route safely", at: 1, thread: "main")]
        let projection = RoomProjectionEnvelope(rooms: [
            "id:bad-members": RoomProjectionRoom(
                name: "Bad members", roomID: "bad-members", log: [], revision: 1,
                members: malformedMembers),
            "id:bad-author": RoomProjectionRoom(
                name: "Bad author", roomID: "bad-author", log: badAuthorLog,
                revision: 1, members: projectedMembers()),
        ])
        let store = RoomStore(baseDirectory: base)
        let result = try await store.reconcileRoomProjection(
            projection, allowedGatewayIDs: projectedGatewayIDs)
        XCTAssertTrue(result.rooms.isEmpty)
        XCTAssertEqual(Set(result.roomProjection.rooms.keys),
                       ["id:bad-members", "id:bad-author"])

        let reader = RoomStore(baseDirectory: base)
        let restoredRooms = try await reader.loadAll()
        let restoredProjection = try await reader.roomProjection()
        XCTAssertTrue(restoredRooms.isEmpty)
        XCTAssertEqual(restoredProjection, result.roomProjection)
    }

    func testProjectionOmissionNeverDeletesHydratedRichRoom() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let first = try await store.reconcileRoomProjection(RoomProjectionEnvelope(rooms: [
            "id:omitted": RoomProjectionRoom(name: "Omitted", roomID: "omitted",
                                              log: [], revision: 1,
                                              members: projectedMembers()),
        ]), allowedGatewayIDs: projectedGatewayIDs)
        let roomID = try XCTUnwrap(first.rooms.first?.id)
        let omitted = try await store.reconcileRoomProjection(
            RoomProjectionEnvelope(updatedAt: 99),
            allowedGatewayIDs: projectedGatewayIDs)
        XCTAssertNotNil(omitted.rooms.first { $0.id == roomID })
        XCTAssertNotNil(omitted.roomProjection.rooms["id:omitted"])
    }

    func testDesktopLocalConnectionIDsHydrateAsFrozenAndRoundTripRawIdentity() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let key = "id:foreign-room"
        let talariaGatewayID = "8e10f644-5843-49d3-a37f-720542f94713"
        let desktopConnectionID = "ssh-mini-studio"
        let imageBytes = Data([1, 3, 3, 7])
        let image = "data:image/png;base64,\(imageBytes.base64EncodedString())"
        let projection = RoomProjectionEnvelope(rooms: [
            key: RoomProjectionRoom(
                name: "Portable room", roomID: "foreign-room", log: [
                    RoomProjectionEntry(
                        id: "desktop-message", from: RoomProjectionAuthor(
                            kind: .member, name: "desktop-worker",
                            source: desktopConnectionID),
                        text: "visible from Desktop", at: 10, thread: "desktop-thread")
                ], revision: 1,
                members: [
                    RoomProjectionMember(name: "phone-worker", handle: "phone-worker",
                                         connectionID: talariaGatewayID,
                                         connectionLabel: "Phone gateway",
                                         sourceScoped: true),
                    RoomProjectionMember(name: "desktop-worker", handle: "desktop-worker",
                                         connectionID: desktopConnectionID,
                                         connectionLabel: "Joshua's Mini",
                                         sourceScoped: true),
                ], image: image),
        ])
        let store = RoomStore(baseDirectory: base)

        let hydrated = try await store.reconcileRoomProjection(
            projection, allowedGatewayIDs: [talariaGatewayID])
        let room = try XCTUnwrap(hydrated.rooms.first)
        XCTAssertEqual(room.name, "Portable room")
        XCTAssertEqual(room.entries.map(\.text), ["visible from Desktop"])
        XCTAssertEqual(hydrated.projectedImages[room.id], imageBytes)
        XCTAssertEqual(room.members.map(\.isFrozenProjection), [false, true])
        XCTAssertEqual(room.members.map(\.rawProjectionConnectionID),
                       [talariaGatewayID, desktopConnectionID])
        XCTAssertEqual(room.members[1].sourceLabel, "Joshua's Mini")

        let republished = RoomProjectionEnvelope.projecting(
            hydrated.rooms, updatedAt: 20)
        XCTAssertEqual(republished.rooms[key]?.members.map(\.connectionID),
                       [talariaGatewayID, desktopConnectionID])

        let fresh = RoomStore(baseDirectory: base)
        let restoredRooms = try await fresh.loadAll()
        let restored = try XCTUnwrap(restoredRooms.first)
        XCTAssertTrue(restored.members[1].isFrozenProjection)
        XCTAssertEqual(restored.members[1].rawProjectionConnectionID,
                       desktopConnectionID)

        let thawed = try await fresh.reconcileRoomProjection(
            projection,
            allowedGatewayIDs: [talariaGatewayID, desktopConnectionID])
        XCTAssertEqual(thawed.rooms.first?.members.map(\.isFrozenProjection),
                       [false, false],
                       "device-local authority must thaw without a remote revision bump")
    }

    func testAllUnknownProjectedSourcesStillHydrateVisibleButInert() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RoomStore(baseDirectory: base)
        let result = try await store.reconcileRoomProjection(
            RoomProjectionEnvelope(rooms: [
                "id:frozen": RoomProjectionRoom(
                    name: "Frozen", roomID: "frozen", log: [], revision: 1,
                    members: [
                        RoomProjectionMember(name: "one", connectionID: "desktop-a",
                                             sourceScoped: true),
                        RoomProjectionMember(name: "two", connectionID: "desktop-b",
                                             sourceScoped: true),
                    ])
            ]))
        let room = try XCTUnwrap(result.rooms.first)
        XCTAssertTrue(room.members.allSatisfy(\.isFrozenProjection))
        XCTAssertNoThrow(try RoomEngine.validate(room))
    }

    func testAtomicLegacyRenamePersistsPromotionAndOldKeyTombstoneAcrossRestart() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let oldKey = "name:Legacy"
        let entry = RoomProjectionEntry(
            id: "message-1", from: RoomProjectionAuthor(kind: .user, name: "You"),
            text: "hello", at: 1, thread: "thread-1")
        let store = RoomStore(baseDirectory: base)
        let hydrated = try await store.reconcileRoomProjection(
            RoomProjectionEnvelope(rooms: [
                oldKey: RoomProjectionRoom(name: "Legacy", log: [entry], revision: 3,
                                           members: projectedMembers()),
            ]), allowedGatewayIDs: projectedGatewayIDs)
        let roomID = try XCTUnwrap(hydrated.rooms.first?.id)
        let newKey = RoomProjectionEnvelope.idKey(roomID.description)

        _ = try await store.mutate(
            roomID: roomID,
            projectionIntent: RoomProjectionMergeIntent(
                changedRooms: [newKey], deletedRooms: ["Legacy"], writeRevision: 4)
        ) { room in
            room.rawProjectionRoomKey = newKey
            room.name = "Renamed"
        }

        let fresh = RoomStore(baseDirectory: base)
        let richValue = try await fresh.room(id: roomID)
        let rich = try XCTUnwrap(richValue)
        let ledger = try await fresh.roomProjection()
        XCTAssertEqual(rich.name, "Renamed")
        XCTAssertEqual(rich.rawProjectionRoomKey, newKey)
        XCTAssertEqual(rich.rawProjectionRevision, 4)
        XCTAssertEqual(ledger.rooms[newKey]?.name, "Renamed")
        XCTAssertNil(ledger.rooms[oldKey])
        XCTAssertEqual(ledger.deleted[oldKey], 4)

        let restarted = try await fresh.reconcileRoomProjection(
            ledger, allowedGatewayIDs: projectedGatewayIDs)
        XCTAssertEqual(restarted.rooms.map(\.id), [roomID])
        XCTAssertEqual(restarted.rooms.first?.name, "Renamed")
    }

    func testAtomicProjectionIntentAdvancesPastAStalePreparedRevision() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let oldKey = "name:Legacy"
        let store = RoomStore(baseDirectory: base)
        let hydrated = try await store.reconcileRoomProjection(
            RoomProjectionEnvelope(rooms: [
                oldKey: RoomProjectionRoom(
                    name: "Legacy",
                    log: [RoomProjectionEntry(
                        id: "message-1",
                        from: RoomProjectionAuthor(kind: .user, name: "You"),
                        text: "hello", at: 1, thread: "thread-1")],
                    revision: 9, members: projectedMembers()),
            ]), allowedGatewayIDs: projectedGatewayIDs)
        let roomID = try XCTUnwrap(hydrated.rooms.first?.id)
        let newKey = RoomProjectionEnvelope.idKey(roomID.description)

        let renamed = try await store.mutate(
            roomID: roomID,
            projectionIntent: RoomProjectionMergeIntent(
                changedRooms: [newKey], deletedRooms: [oldKey], writeRevision: 4)
        ) { room in
            room.rawProjectionRoomKey = newKey
            room.name = "Renamed"
        }

        let ledger = try await store.roomProjection()
        XCTAssertEqual(renamed.rawProjectionRevision, 10)
        XCTAssertEqual(ledger.rooms[newKey]?.revision, 10)
        XCTAssertEqual(ledger.deleted[oldKey], 10)
    }

    func testProfileLifecycleAtomicallyAdvancesProjectionAcrossRestart() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let key = "id:lifecycle-room"
        let source = GatewayBotRoute(gatewayID: "mini", profile: "research")
        let destination = GatewayBotRoute(gatewayID: "mini", profile: "renamed")
        let entry = RoomProjectionEntry(
            id: "message-1", from: RoomProjectionAuthor(
                kind: .member, name: "research", source: "mini"),
            text: "answer", at: 1, thread: "thread-1")
        let store = RoomStore(baseDirectory: base)
        _ = try await store.reconcileRoomProjection(
            RoomProjectionEnvelope(rooms: [
                key: RoomProjectionRoom(name: "Lifecycle", roomID: "lifecycle-room",
                                        log: [entry], revision: 7,
                                        members: projectedMembers()),
            ]), allowedGatewayIDs: projectedGatewayIDs)

        _ = try await store.migrateProfileRoute(from: source, to: destination)
        let afterRename = RoomStore(baseDirectory: base)
        let renamedLedger = try await afterRename.roomProjection()
        let renamedRooms = try await afterRename.loadAll()
        let renamedRoom = try XCTUnwrap(renamedRooms.first)
        XCTAssertEqual(renamedRoom.members.first?.route, destination)
        XCTAssertEqual(renamedRoom.rawProjectionRevision, 8)
        XCTAssertEqual(renamedLedger.rooms[key]?.revision, 8)
        XCTAssertEqual(renamedLedger.rooms[key]?.members.first?.name, "renamed")
        XCTAssertFalse(renamedLedger.rooms[key]?.members.contains {
            $0.connectionID == "mini" && $0.name == "research"
        } ?? true)

        _ = try await afterRename.retireProfileRoute(destination)
        let afterRemoval = RoomStore(baseDirectory: base)
        let removedLedger = try await afterRemoval.roomProjection()
        let removedRooms = try await afterRemoval.loadAll()
        let removedRoom = try XCTUnwrap(removedRooms.first)
        XCTAssertEqual(removedRoom.members.map(\.route.gatewayID), ["lab"])
        XCTAssertEqual(removedRoom.rawProjectionRevision, 9)
        XCTAssertEqual(removedLedger.rooms[key]?.revision, 9)
        XCTAssertFalse(removedLedger.rooms[key]?.members.contains {
            $0.connectionID == "mini"
        } ?? true)
    }

    func testHigherRevisionOmittedImagePreservesExistingImageAfterBounding() {
        let image = "data:image/png;base64," + String(repeating: "A", count: 23_000)
        let maximalMembers = (0..<6).map { index in
            RoomProjectionMember(
                name: String(repeating: "n", count: 128),
                handle: String(repeating: "h", count: 128),
                connectionID: "gateway-\(index)-" + String(repeating: "g", count: 110),
                connectionLabel: String(repeating: "l", count: 128),
                sourceScoped: true)
        }
        let largeLog = (0..<16).map { index in
            RoomProjectionEntry(
                id: "entry-\(index)", from: RoomProjectionAuthor(kind: .user, name: "You"),
                text: String(repeating: "x", count: 1_200), at: Int64(index),
                thread: "thread")
        }
        let key = "id:image-room"
        let prior = RoomProjectionEnvelope(rooms: [
            key: RoomProjectionRoom(name: "Before", roomID: "image-room",
                                    log: [largeLog[0]], revision: 1,
                                    members: projectedMembers(), image: image),
        ])
        var boundedWinner = RoomProjectionEnvelope(rooms: [
            key: RoomProjectionRoom(name: "After", roomID: "image-room",
                                    log: largeLog, revision: 2,
                                    members: maximalMembers, image: image),
            "id:newer-large-room": RoomProjectionRoom(
                name: "Newer", roomID: "newer-large-room",
                log: [RoomProjectionEntry(
                    id: "newer", from: RoomProjectionAuthor(kind: .user, name: "You"),
                    text: String(repeating: "z", count: 1_200), at: 10_000)],
                revision: 1, members: maximalMembers, image: image),
        ])
        XCTAssertNil(boundedWinner.rooms[key]?.image,
                     "the fixture must exercise size-driven image omission")
        // Isolate the compacted winning row. The second room exists only to
        // prove that the omission came from envelope bounding; a later gateway
        // may independently omit that other room as another partial snapshot.
        boundedWinner.rooms.removeValue(forKey: "id:newer-large-room")

        let merged = RoomProjectionEnvelope.merging(
            remote: prior, local: boundedWinner, updatedAt: 10)
        XCTAssertEqual(merged.rooms[key]?.name, "After")
        XCTAssertEqual(merged.rooms[key]?.revision, 2)
        XCTAssertEqual(merged.rooms[key]?.image, image)
    }

    func testExplicitImageClearSentinelWinsAndPersistsAtomically() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let key = "id:image-clear-room"
        let image = "data:image/png;base64,\(Data([1, 2, 3]).base64EncodedString())"
        let entry = RoomProjectionEntry(
            id: "message", from: RoomProjectionAuthor(kind: .user, name: "You"),
            text: "hello", at: 1, thread: "thread")
        let store = RoomStore(baseDirectory: base)
        let hydrated = try await store.reconcileRoomProjection(
            RoomProjectionEnvelope(rooms: [
                key: RoomProjectionRoom(name: "Picture", roomID: "image-clear-room",
                                        log: [entry], revision: 3,
                                        members: projectedMembers(), image: image)
            ]), allowedGatewayIDs: projectedGatewayIDs)
        let roomID = try XCTUnwrap(hydrated.rooms.first?.id)

        _ = try await store.mutate(
            roomID: roomID,
            projectionIntent: RoomProjectionMergeIntent(
                changedRooms: [key], writeRevision: 4,
                clearedImages: [key])) { room in
            room.avatar = nil
        }

        let fresh = RoomStore(baseDirectory: base)
        let ledger = try await fresh.roomProjection()
        XCTAssertEqual(ledger.rooms[key]?.revision, 4)
        XCTAssertEqual(ledger.rooms[key]?.image, "",
                       "empty string is property-presence clear, not omission")
        let encoded = try JSONEncoder().encode(ledger)
        let decoded = try JSONDecoder().decode(RoomProjectionEnvelope.self, from: encoded)
        XCTAssertEqual(decoded.rooms[key]?.image, "")

        let laterOmission = RoomProjectionEnvelope(rooms: [
            key: RoomProjectionRoom(name: "Renamed", roomID: "image-clear-room",
                                    log: [entry], revision: 5,
                                    members: projectedMembers())
        ])
        let stillCleared = RoomProjectionEnvelope.merging(
            remote: ledger, local: laterOmission)
        XCTAssertEqual(stillCleared.rooms[key]?.image, "",
                       "a later bounded omission must not resurrect old bytes")
    }

    func testAuthoritativePeerImageClearRemovesRichAvatarAndSignalsCacheEviction() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let key = "id:peer-clear-room"
        let imageBytes = Data([7, 8, 9])
        let image = "data:image/png;base64,\(imageBytes.base64EncodedString())"
        let entry = RoomProjectionEntry(
            id: "message", from: RoomProjectionAuthor(kind: .user, name: "You"),
            text: "hello", at: 1, thread: "thread")
        let roomValue: (UInt64, String?) -> RoomProjectionRoom = { revision, image in
            RoomProjectionRoom(name: "Peer", roomID: "peer-clear-room",
                               log: [entry], revision: revision,
                               members: self.projectedMembers(), image: image)
        }
        let store = RoomStore(baseDirectory: base)
        let hydrated = try await store.reconcileRoomProjection(
            RoomProjectionEnvelope(rooms: [key: roomValue(3, image)]),
            allowedGatewayIDs: projectedGatewayIDs)
        let roomID = try XCTUnwrap(hydrated.rooms.first?.id)
        let avatarBytes = Data([0x89, 0x50, 0x4e, 0x47])
        let attachment = try await store.storeBlob(
            roomID: roomID, data: avatarBytes, fileName: "local.png",
            mediaType: "image/png")
        _ = try await store.mutate(roomID: roomID) { room in
            room.avatar = attachment
        }

        let omitted = try await store.reconcileRoomProjection(
            RoomProjectionEnvelope(rooms: [key: roomValue(4, nil)]),
            allowedGatewayIDs: projectedGatewayIDs)
        XCTAssertEqual(omitted.rooms.first?.avatar, attachment)
        XCTAssertTrue(omitted.clearedImageRoomIDs.isEmpty)
        XCTAssertEqual(omitted.projectedImages[roomID], imageBytes)
        let retainedAvatarBytes = try await store.readBlob(
            roomID: roomID, attachment: attachment)
        XCTAssertEqual(retainedAvatarBytes, avatarBytes)

        let cleared = try await store.reconcileRoomProjection(
            RoomProjectionEnvelope(rooms: [key: roomValue(5, "")]),
            allowedGatewayIDs: projectedGatewayIDs)
        XCTAssertNil(cleared.rooms.first?.avatar)
        XCTAssertEqual(cleared.clearedImageRoomIDs, Set([roomID]))
        XCTAssertNil(cleared.projectedImages[roomID])
        do {
            _ = try await store.readBlob(roomID: roomID, attachment: attachment)
            XCTFail("the atomically unreferenced rich avatar blob must be reclaimed")
        } catch {
            XCTAssertEqual(error as? RoomStoreError, .attachmentNotFound)
        }

        let fresh = RoomStore(baseDirectory: base)
        let restored = try await fresh.room(id: roomID)
        let ledger = try await fresh.roomProjection()
        XCTAssertNil(restored?.avatar)
        XCTAssertEqual(ledger.rooms[key]?.image, "")
    }

    func testPeerAvatarClearRetainsBlobSharedByCommittedEntry() async throws {
        let base = try temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let key = "id:shared-avatar-blob"
        let projectedEntry = RoomProjectionEntry(
            id: "shared-entry", from: RoomProjectionAuthor(kind: .user, name: "You"),
            text: "keeps the picture", at: 1, thread: "thread")
        let store = RoomStore(baseDirectory: base)
        let hydrated = try await store.reconcileRoomProjection(
            RoomProjectionEnvelope(rooms: [
                key: RoomProjectionRoom(
                    name: "Shared blob", roomID: "shared-avatar-blob",
                    log: [projectedEntry], revision: 1,
                    members: projectedMembers(),
                    image: "data:image/png;base64,AQID")
            ]), allowedGatewayIDs: projectedGatewayIDs)
        let roomID = try XCTUnwrap(hydrated.rooms.first?.id)
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 4, 5, 6])
        let attachment = try await store.storeBlob(
            roomID: roomID, data: bytes, fileName: "shared.png",
            mediaType: "image/png")
        _ = try await store.mutate(roomID: roomID) { room in
            room.avatar = attachment
            room.entries[0].attachments = [attachment]
        }

        let cleared = try await store.reconcileRoomProjection(
            RoomProjectionEnvelope(rooms: [
                key: RoomProjectionRoom(
                    name: "Shared blob", roomID: "shared-avatar-blob",
                    log: [projectedEntry], revision: 2,
                    members: projectedMembers(), image: "")
            ]), allowedGatewayIDs: projectedGatewayIDs)
        let committed = try XCTUnwrap(cleared.rooms.first)
        XCTAssertNil(committed.avatar)
        XCTAssertEqual(committed.entries.first?.attachments, [attachment])
        XCTAssertEqual(cleared.clearedImageRoomIDs, Set([roomID]))
        let retained = try await store.readBlob(roomID: roomID, attachment: attachment)
        XCTAssertEqual(retained, bytes)

        let fresh = RoomStore(baseDirectory: base)
        let restoredRooms = try await fresh.loadAll()
        let restored = try XCTUnwrap(restoredRooms.first)
        XCTAssertNil(restored.avatar)
        XCTAssertEqual(restored.entries.first?.attachments, [attachment])
        let restoredBytes = try await fresh.readBlob(
            roomID: roomID, attachment: attachment)
        XCTAssertEqual(restoredBytes, bytes)
    }
}
#endif
