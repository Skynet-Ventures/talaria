#if canImport(XCTest)
import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

/// Narrow integration checks for the policy that sits between the typed Hermes
/// roster and Bot Mode's UI. These deliberately avoid a transport: the risky
/// regressions are target selection, retry identity, and display-only state.
final class BotModeRuntimePolicyTests: XCTestCase {
    func testExactCanonicalEvidenceUsesRootTitleBeforeLeafTitle() {
        let compressed = profile(
            name: "compressed",
            last: session(id: "durable-root", resolvedID: "live-tip",
                          title: "Renamed leaf", rootTitle: "Bot Chat"))
        XCTAssertEqual(CanonicalBotChatEvidence.durableID(in: compressed.rawLastSession),
                       "durable-root")

        // A root is authoritative when supplied. A leaf named Bot Chat below
        // some other root is not Bot Mode's canonical session.
        let misleadingLeaf = profile(
            name: "misleading",
            last: session(id: "scratch", title: "Bot Chat", rootTitle: "Scratch"))
        XCTAssertNil(CanonicalBotChatEvidence.durableID(in: misleadingLeaf.rawLastSession))

        // Older gateway rows lack root_title, where the old exact title is the
        // compatible proof rather than an arbitrary newest-session lookup.
        let legacy = profile(name: "legacy", last: session(id: "old", title: "Bot Chat"))
        XCTAssertEqual(CanonicalBotChatEvidence.durableID(in: legacy.rawLastSession), "old")

        let padded = profile(
            name: "padded",
            last: session(id: "trimmed", title: "  Bot Chat\n", rootTitle: "   "))
        XCTAssertEqual(CanonicalBotChatEvidence.durableID(in: padded.rawLastSession),
                       "trimmed", "an empty root is absent and title evidence is trimmed")
    }

    func testCanonicalTitleOwnershipRejectsPendingAndMismatchedReceipts() {
        XCTAssertTrue(CanonicalTitleOwnership.isAuthoritative(
            SessionTitleReceipt(title: "Bot Chat", pending: false)))
        XCTAssertFalse(CanonicalTitleOwnership.isAuthoritative(
            SessionTitleReceipt(title: "Bot Chat", pending: true)),
            "pending materialization cannot authorize kickoff")
        XCTAssertFalse(CanonicalTitleOwnership.isAuthoritative(
            SessionTitleReceipt(title: "Bot Chat 2", pending: false)),
            "a UNIQUE-race loser cannot authorize kickoff")
    }

    func testMalformedTitleReceiptsCannotReachCanonicalOwnership() {
        for malformed: JSONValue in [
            .object([:]),
            .null,
            ["title": .number(1), "pending": .bool(false)],
            ["title": .string("Bot Chat"), "pending": .string("false")],
        ] {
            XCTAssertThrowsError(try GatewayClient.decodeSessionTitleReceipt(malformed))
        }
    }

    @MainActor
    func testIndeterminateCanonicalLookupPreservesScratchTranscriptAndQueue() {
        let id = "scratch-preserve-\(UUID().uuidString.lowercased())"
        let model = AppModel()
        let chat = model.chat(for: id)
        chat.sessionID = "runtime-scratch"
        chat.storedSessionID = "stored-scratch"
        chat.messages = [ChatMessage(author: .user, text: "unsent context")]
        model.composeQueue = [(botID: id, text: "queued context")]
        defer {
            model.chats[id] = nil
            model.composeQueue.removeAll { $0.botID == id }
        }

        model.applyCanonicalScratchRelease(botID: id, decision: .preserve)

        XCTAssertEqual(chat.sessionID, "runtime-scratch")
        XCTAssertEqual(chat.storedSessionID, "stored-scratch")
        XCTAssertEqual(chat.messages.map(\.text), ["unsent context"])
        XCTAssertEqual(model.composeQueue.filter { $0.botID == id }.map(\.text),
                       ["queued context"])
    }

    @MainActor
    func testRosterProjectsCanonicalSessionWithoutAdoptingRecentScratch() {
        let id = "registry-\(UUID().uuidString.lowercased())"
        let model = AppModel()
        defer { LiveRuntime.shared.canonicalSessionByBot[id] = nil }
        model.applyRosterAnswer([
            profile(name: id,
                    last: session(id: "scratch", title: "Cron", lastActive: 30),
                    canonical: session(id: "canonical", resolvedID: "tip",
                                       title: "Bot Chat", lastActive: 20)),
        ])
        XCTAssertEqual(LiveRuntime.shared.canonicalSessionByBot[id]?.id, "canonical")
        XCTAssertEqual(model.canonicalSessionIDs(botID: id), ["canonical", "tip"])
        XCTAssertFalse(model.isCurrentCanonicalSession(botID: id, sessionID: "scratch"))
    }

    @MainActor
    func testCanonicalHydrationRetriesOnlyTypedTimeoutOnSameDurableTarget() async throws {
        let chat = ChatState()
        var targets: [String] = []
        let payload: JSONValue = .object([
            "messages": .array([
                .object(["role": .string("assistant"), "text": .string("second read")]),
            ]),
        ])

        try await AppModel.hydrateCanonicalTranscript(
            chat: chat, resumeMessages: [], clearWhenEmpty: true, storedID: "durable-target",
            fallback: { target in
                targets.append(target)
                if targets.count == 1 { throw URLError(.timedOut) }
                return payload
            },
            accepts: { true })

        XCTAssertEqual(targets, ["durable-target", "durable-target"])
        XCTAssertEqual(chat.messages.map(\.text), ["second read"])
    }

    @MainActor
    func testCanonicalHydrationDoesNotRetryUntypedFailure() async {
        let chat = ChatState()
        var targets: [String] = []
        do {
            try await AppModel.hydrateCanonicalTranscript(
                chat: chat, resumeMessages: [], clearWhenEmpty: true, storedID: "durable-target",
                fallback: { target in
                    targets.append(target)
                    throw URLError(.cannotConnectToHost)
                },
                accepts: { true })
            XCTFail("a non-timeout fallback failure must escape")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotConnectToHost)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(targets, ["durable-target"])
    }

    @MainActor
    func testCanonicalHydrationPersistentTimeoutRethrowsOriginalURLFailure() async {
        let chat = ChatState()
        let first = URLError(.timedOut, userInfo: ["attempt": "first"])
        let second = URLError(.timedOut, userInfo: ["attempt": "second"])
        var attempts = 0
        do {
            try await AppModel.hydrateCanonicalTranscript(
                chat: chat, resumeMessages: [], clearWhenEmpty: true,
                storedID: "durable-target",
                fallback: { _ in
                    attempts += 1
                    throw attempts == 1 ? first : second
                },
                accepts: { true })
            XCTFail("a persistent timeout must escape after one retry")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
            XCTAssertEqual(error.userInfo["attempt"] as? String, "second",
                           "the retry sentinel must not replace the original URL error")
        } catch {
            XCTFail("expected original URLError, got \(type(of: error)): \(error)")
        }
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testWorkerActivityIsLiveButCannotRankOrReorderConversation() {
        let id = "worker-\(UUID().uuidString.lowercased())"
        let scope = URL(string: "https://\(id).example")!
        let signals = RosterSignals.shared
        signals.rescope(to: scope)
        defer { signals.rescope(to: nil) }

        signals.ingest([
            profile(
                name: id,
                last: session(id: "ordinary", title: "Scratch", preview: "older", lastActive: 100),
                canonical: session(id: "preferred", title: "Bot Chat", preview: "preferred", lastActive: 200),
                worker: .object(["last_active": .number(1_000)])),
        ])

        // Preferred wins ordinary conversation time; a much newer worker is
        // intentionally absent from this value and from the ranking key.
        XCTAssertEqual(signals.lastActive[id], 200)
        XCTAssertEqual(signals.previews[id], "preferred")
        XCTAssertEqual(signals.activity(of: id), 200_000)
        XCTAssertTrue(signals.activeNow(id, now: Date(timeIntervalSince1970: 1_149)))
        XCTAssertFalse(signals.activeNow(id, now: Date(timeIntervalSince1970: 1_151)))
    }

    @MainActor
    func testCanonicalOwnsPreviewWhileFresherLastOwnsActivityAndUnreadIdentity() {
        let id = "split-\(UUID().uuidString.lowercased())"
        let scope = URL(string: "https://\(id).example")!
        let signals = RosterSignals.shared
        signals.rescope(to: scope)
        defer {
            signals.rescope(to: nil)
            LiveRuntime.shared.lastSessionByBot.removeValue(forKey: id)
        }
        let row = profile(
            name: id,
            last: session(id: "fresh-scratch", title: "Scratch",
                          preview: "unrelated but newer", lastActive: 300),
            canonical: session(id: "forever", title: "Bot Chat",
                               preview: "canonical preview", lastActive: 200,
                               messageCount: 4))
        signals.ingest([row])
        XCTAssertEqual(signals.previews[id], "canonical preview")
        XCTAssertEqual(signals.activityPreviews[id], "unrelated but newer")
        XCTAssertEqual(signals.lastActive[id], 300)

        let model = AppModel()
        model.applyRosterAnswer([row])
        XCTAssertEqual(model.bots.first?.preview, "canonical preview")
        XCTAssertEqual(LiveRuntime.shared.lastSessionByBot[id], "fresh-scratch")
    }

    @MainActor
    func testAuthoritativeEmptyCanonicalPreviewClearsStaleRowText() {
        let id = "empty-preview-\(UUID().uuidString.lowercased())"
        let model = AppModel()
        model.bots = [Bot(id: id, job: "", shape: .circle, hue: .violet,
                          preview: "stale canonical words")]
        model.applyRosterAnswer([
            profile(name: id,
                    canonical: session(id: "canonical", title: "Bot Chat",
                                       messageCount: 2)),
        ])
        XCTAssertEqual(model.bots.first?.preview, "Ready when you are.")
        XCTAssertEqual(RosterSignals.shared.previews[id], "")
    }

    @MainActor
    func testWorkerFutureStampCannotStayLiveAndOnlyChangesDisplayAgeWhileLive() {
        let id = "worker-future-\(UUID().uuidString.lowercased())"
        let scope = URL(string: "https://\(id).example")!
        let signals = RosterSignals.shared
        signals.rescope(to: scope)
        defer { signals.rescope(to: nil) }
        signals.ingest([
            profile(name: id,
                    last: session(id: "chat", title: "Scratch", lastActive: 100),
                    worker: .object(["last_active": .number(200)])),
        ])

        XCTAssertEqual(signals.activity(of: id), 100_000,
                       "worker activity never participates in rank/unread recency")
        XCTAssertEqual(signals.lastActiveDate(id, now: Date(timeIntervalSince1970: 250))?
            .timeIntervalSince1970, 200,
                       "a live newer worker may improve only the displayed age")
        XCTAssertEqual(signals.lastActiveDate(id, now: Date(timeIntervalSince1970: 400))?
            .timeIntervalSince1970, 100,
                       "expired worker activity no longer changes the row age")

        signals.ingest([
            profile(name: id,
                    last: session(id: "chat", title: "Scratch", lastActive: 100),
                    worker: .object(["last_active": .number(10_000)])),
        ])
        XCTAssertFalse(signals.activeNow(id, now: Date(timeIntervalSince1970: 1_000)),
                       "far-future worker stamps are not live forever")
        XCTAssertEqual(signals.lastActiveDate(id, now: Date(timeIntervalSince1970: 1_000))?
            .timeIntervalSince1970, 100)
    }

    @MainActor
    func testRosterGoneCanonicalNeverAdoptsLatestSession() {
        let id = "gone-registry-\(UUID().uuidString.lowercased())"
        let model = AppModel()
        model.applyRosterAnswer([
            profile(name: id, last: session(id: "cron", title: "Cron"), canonical: .null),
        ])
        XCTAssertNil(LiveRuntime.shared.canonicalSessionByBot[id])
        XCTAssertEqual(LiveRuntime.shared.lastSessionByBot[id], "cron")
        XCTAssertFalse(model.isCurrentCanonicalSession(botID: id, sessionID: "cron"))
    }

    @MainActor
    func testInconclusiveCanonicalSnapshotsPreserveGuardIdentityUntilExplicitGone() {
        let id = "canonical-fence-\(UUID().uuidString.lowercased())"
        let model = AppModel()
        defer { LiveRuntime.shared.canonicalSessionByBot[id] = nil }

        model.applyRosterAnswer([
            profile(name: id, canonical: session(
                id: "durable", resolvedID: "tip", title: "Bot Chat")),
        ])
        XCTAssertEqual(model.canonicalSessionIDs(botID: id), ["durable", "tip"])

        model.applyRosterAnswer([
            profile(name: id, last: session(id: "scratch", title: "Cron")),
        ])
        XCTAssertEqual(model.canonicalSessionIDs(botID: id), ["durable", "tip"],
                       "an omitted compatibility answer is inconclusive")

        model.applyRosterAnswer([
            profile(name: id, last: session(id: "scratch-2", title: "Cron",
                                            preview: "unrelated scratch text"),
                    canonical: ["title": "Bot Chat"]),
        ])
        XCTAssertEqual(model.canonicalSessionIDs(botID: id), ["durable", "tip"],
                       "a malformed current answer is quarantined, not a clear")
        XCTAssertNotEqual(model.bots.first?.preview, "unrelated scratch text",
                          "malformed canonical data cannot publish scratch text")

        for invalidEvidence: JSONValue in [
            session(id: "wrong-root", title: "Bot Chat", rootTitle: "Other"),
            session(id: "wrong-leaf", title: "Other"),
        ] {
            model.applyRosterAnswer([
                profile(name: id,
                        last: session(id: "scratch-3", title: "Cron",
                                      preview: "still unrelated"),
                        canonical: invalidEvidence),
            ])
            XCTAssertEqual(model.canonicalSessionIDs(botID: id), ["durable", "tip"],
                           "non-Bot-Chat current evidence preserves prior authority")
            XCTAssertNotEqual(model.bots.first?.preview, "still unrelated",
                              "non-Bot-Chat current evidence cannot publish scratch preview")
        }

        model.applyRosterAnswer([profile(name: id, canonical: .null)])
        XCTAssertTrue(model.canonicalSessionIDs(botID: id).isEmpty,
                      "only authoritative gone clears the guard identity")
    }

    @MainActor
    func testHiddenRowsKeepUnreadButSuppressPrimaryActivityToastAndRail() {
        let id = "hidden-\(UUID().uuidString.lowercased())"
        let scope = URL(string: "https://\(id).example")!
        let signals = RosterSignals.shared
        signals.rescope(to: scope)
        let previousToastPreference = ActivityToastPref.shared.enabled
        defer {
            ActivityToastPref.shared.set(previousToastPreference)
            ToastBus.shared.clear()
            signals.rescope(to: nil)
        }

        let model = AppModel()
        model.bots = [Bot(id: id, job: "", shape: .circle, hue: .violet)]
        signals.ingest([
            profile(name: id, last: session(id: "chat", title: "Scratch", lastActive: 500)),
        ])
        signals.setHidden(id, true)
        ActivityToastPref.shared.set(true)
        ToastBus.shared.clear()

        model.applyUnreadWatermark([id])

        XCTAssertEqual(model.bots.first?.unread, 1)
        XCTAssertTrue(ToastBus.shared.toasts.isEmpty)
        XCTAssertTrue(model.rankedBots.contains(where: { $0.id == id }),
                      "hidden is display-only, not a roster membership deletion")
        XCTAssertFalse(model.activeNowBots(now: Date(timeIntervalSince1970: 501))
            .contains(where: { $0.id == id }))
    }

    func testShowHiddenIsAPrimaryDisplayOnlyPolicyWithDimmedInspectionRows() {
        XCTAssertFalse(RosterVisibilityPolicy.includesPrimary(hidden: true, showingHidden: false))
        XCTAssertTrue(RosterVisibilityPolicy.includesPrimary(hidden: true, showingHidden: true))
        XCTAssertTrue(RosterVisibilityPolicy.includesPrimary(hidden: false, showingHidden: false))
        XCTAssertEqual(RosterVisibilityPolicy.rowOpacity(hidden: true, showingHidden: true), 0.48)
        XCTAssertEqual(RosterVisibilityPolicy.rowOpacity(hidden: true, showingHidden: false), 1)
        let hidden = Bot(id: "hidden", job: "", shape: .circle, hue: .violet, unread: 3)
        let visible = Bot(id: "visible", job: "", shape: .circle, hue: .blue, unread: 9)
        XCTAssertEqual(RosterVisibilityPolicy.hiddenUnreadCount(
            bots: [hidden, visible], hiddenIDs: ["hidden"]), 3,
                       "the eye control badges only unread hidden rows")
    }

    func testRoomSearchKeepsCapturedFriendlyNameAfterTheRosterChanges() {
        let room = RoomRecord(name: "Launch", members: [
            RoomMember(route: GatewayBotRoute(gatewayID: "lab", profile: "research"),
                       title: "Analysis", handle: "research-lab", sourceLabel: "Lab",
                       friendlyName: "Research Buddy"),
        ])
        XCTAssertTrue(RosterRoomPolicy.matches(room, needle: "buddy"))
    }

    @MainActor
    func testRoomMemberCaptureNeverPersistsRenderedFallbackAlias() {
        let model = AppModel()
        let route = GatewayBotRoute(gatewayID: "lab", profile: "code_review")
        let generic = Bot(id: route.qualifiedID, job: "", shape: .circle, hue: .green,
                          handleOverride: "code-review-lab",
                          remoteSource: BotSource(profile: route.profile,
                                                  gatewayID: route.gatewayID,
                                                  connectionLabel: "Home Lab"))
        let captured = model.capturedRoomMember(for: generic, route: route,
                                                sourceLabel: "Home Lab")
        XCTAssertNil(captured.title)
        XCTAssertNil(captured.friendlyName)
        XCTAssertNil(captured.rawDisplayName)
        XCTAssertFalse(captured.friendlyMentionNames.contains(generic.displayTitle))

        var explicit = generic
        explicit.title = "Code Friend"
        explicit.rawDisplayName = "Core Reviewer"
        let named = model.capturedRoomMember(for: explicit, route: route,
                                             sourceLabel: "Home Lab")
        XCTAssertEqual(named.title, "Code Friend")
        XCTAssertEqual(named.friendlyName, "Code Friend")
        XCTAssertEqual(named.rawDisplayName, "Core Reviewer")
    }

    @MainActor
    func testForeignRawDisplayNameSurvivesSecondaryAndRosterBotProjection() {
        let rosterProfile = profile(
            name: "research",
            displayName: "Research Buddy",
            last: session(id: "last", title: "Scratch", preview: "ordinary", lastActive: 30),
            canonical: session(id: "preferred", title: "Bot Chat", preview: "canonical",
                               lastActive: 20, messageCount: 2),
            meta: ["hermes-bots": ["chat": "preferred"]])
        let secondary = ConnectionRegistry.secondaryProfile(from: rosterProfile)
        XCTAssertEqual(secondary.rawDisplayName, "Research Buddy")
        XCTAssertEqual(secondary.preview, "canonical")
        XCTAssertEqual(secondary.activityPreview, "ordinary")
        XCTAssertEqual(secondary.lastActive, 30)
        XCTAssertEqual(secondary.canonicalSessionID, "preferred")

        let entry = ForeignRosterEntry(
            gatewayID: "lab", connectionLabel: "Lab", connectionKind: .lan,
            profile: secondary.name, handle: "research-lab", title: secondary.title,
            rawDisplayName: secondary.rawDisplayName, job: secondary.job,
            shape: secondary.shape, hue: secondary.hue, preview: secondary.preview,
            lastActive: secondary.lastActive,
            canonicalSessionID: secondary.canonicalSessionID,
            canonicalResolvedID: secondary.canonicalResolvedID)
        let model = AppModel()
        let bot = model.rosterBot(for: entry)
        XCTAssertEqual(bot.rawDisplayName, "Research Buddy")
        XCTAssertEqual(bot.friendlyMentionName, "Research Buddy")
        XCTAssertEqual(entry.canonicalChatID, "preferred")
    }

    func testSecondaryPublicationUsesCanonicalSessionNotLegacyMetadataPointer() throws {
        // This is the payload retained by enumerate when its precision retry
        // throws: the profile/cosmetic and activity portions are authenticated,
        // but preferred_session still describes the client's old pin.
        let firstAnswer = profile(
            name: "research",
            displayName: "Research Buddy",
            last: session(id: "latest", title: "Scratch",
                          preview: "fresh independent activity", lastActive: 400),
            canonical: session(id: "old-pin", title: "Bot Chat",
                               preview: "wrong canonical words", lastActive: 300),
            meta: ["hermes-bots": [
                "chat": "new-pin", "title": "Research Lead", "shape": "hexagon",
            ]])

        let projection = ConnectionRegistry.secondaryRosterProjection(from: [firstAnswer])
        let row = try XCTUnwrap(projection.profiles.first)

        XCTAssertTrue(projection.isCanonicalProjectionComplete)
        XCTAssertEqual(projection.freshness, .fresh)
        XCTAssertEqual(row.title, "Research Lead")
        XCTAssertEqual(row.rawDisplayName, "Research Buddy")
        XCTAssertEqual(row.shape, .hexagon)
        XCTAssertEqual(row.canonicalSessionID, "old-pin")
        XCTAssertEqual(row.preview, "wrong canonical words")
        XCTAssertEqual(row.activityPreview, "fresh independent activity")
        XCTAssertEqual(row.lastActive, 400)
    }

    func testSecondaryPublicationQuarantinesPresentMalformedCanonicalSession() throws {
        let malformed = HermesProfile(.object([
            "name": .string("research"),
            "last_session": session(id: "scratch", title: "Scratch",
                                    preview: "unrelated words", lastActive: 400),
            "canonical_session": .object(["id": .string("")]),
            "preferred_session": session(id: "must-not-win", title: "Bot Chat",
                                           preview: "legacy words"),
        ]))

        let projection = ConnectionRegistry.secondaryRosterProjection(from: [malformed])
        let row = try XCTUnwrap(projection.profiles.first)
        XCTAssertFalse(projection.isCanonicalProjectionComplete)
        XCTAssertFalse(ConnectionRegistry.secondaryCanonicalProjectionIsExact(malformed))
        XCTAssertNil(row.canonicalSessionID)
        XCTAssertTrue(row.preview.isEmpty,
                      "malformed canonical data must not borrow last_session presentation")
    }

    func testSecondaryPublicationIgnoresConcurrentLegacyPointerChange() throws {
        let firstAnswer = profile(
            name: "research",
            canonical: session(id: "old-pin", title: "Bot Chat"),
            meta: ["hermes-bots": ["chat": "requested-pin"]])
        _ = firstAnswer

        // While the retry for requested-pin was in flight, another client
        // moved ui_meta to newest-pin. The response resolved the requested
        // identity correctly, but it no longer describes its own final pin.
        let retryAnswer = profile(
            name: "research",
            last: session(id: "ordinary", title: "Scratch",
                          preview: "ordinary activity", lastActive: 200),
            canonical: session(id: "requested-pin", title: "Bot Chat",
                               preview: "superseded canonical words", lastActive: 500),
            meta: ["hermes-bots": ["chat": "newest-pin", "title": "Current Name"]])
        let projection = ConnectionRegistry.secondaryRosterProjection(from: [retryAnswer])
        let row = try XCTUnwrap(projection.profiles.first)

        XCTAssertTrue(projection.isCanonicalProjectionComplete)
        XCTAssertEqual(projection.freshness, .fresh)
        XCTAssertEqual(row.title, "Current Name")
        XCTAssertEqual(row.canonicalSessionID, "requested-pin")
        XCTAssertEqual(row.preview, "superseded canonical words")
        XCTAssertEqual(row.activityPreview, "superseded canonical words",
                       "the freshest activity remains valid independently of click identity")
        XCTAssertEqual(row.lastActive, 500)
    }

    func testSecondaryRosterPersistencePayloadContainsNoConversationProjection() throws {
        let canonicalWords = "PRIVATE-CANONICAL-\(UUID().uuidString)"
        let activityWords = "PRIVATE-ACTIVITY-\(UUID().uuidString)"
        let pin = "PRIVATE-PIN-\(UUID().uuidString)"
        let preferred = "PRIVATE-PREFERRED-\(UUID().uuidString)"
        let input = [
            "lab": SecondaryRoster(
                profiles: [SecondaryProfile(
                    name: "research", title: "Safe cosmetic", rawDisplayName: "Safe identity",
                    job: "Safe job", shape: .hexagon, hue: .violet,
                    preview: canonicalWords, activityPreview: activityWords,
                    lastActive: 123, canonicalSessionID: pin,
                    canonicalResolvedID: preferred)],
                fetchedAt: Date(timeIntervalSince1970: 456), freshness: .fresh),
        ]

        let sanitized = ConnectionRegistry.sanitizedSecondaryRostersForPersistence(input)
        let payload = try JSONEncoder().encode(sanitized)
        let encoded = try XCTUnwrap(String(data: payload, encoding: .utf8))
        for privateValue in [canonicalWords, activityWords, pin, preferred] {
            XCTAssertFalse(encoded.contains(privateValue),
                           "UserDefaults payload leaked runtime conversation data")
        }

        let decoded = try JSONDecoder().decode([String: SecondaryRoster].self, from: payload)
        let row = try XCTUnwrap(decoded["lab"]?.profiles.first)
        XCTAssertTrue(row.preview.isEmpty)
        XCTAssertNil(row.activityPreview)
        XCTAssertNil(row.canonicalSessionID)
        XCTAssertNil(row.canonicalResolvedID)
        XCTAssertEqual(row.title, "Safe cosmetic")
        XCTAssertEqual(row.rawDisplayName, "Safe identity")
        XCTAssertEqual(row.job, "Safe job")
        XCTAssertEqual(row.shape, .hexagon)
        XCTAssertEqual(row.hue, .violet)
        XCTAssertEqual(row.lastActive, 123)
        XCTAssertEqual(decoded["lab"]?.freshness, .fresh)
    }

    func testFriendlyAliasesPreserveSeparatorsFilterReservedAndRequireRenameMetadata() {
        XCTAssertEqual(BotMention.friendlyForms(from: "Code_Review-2"), ["code_review-2"])
        XCTAssertEqual(BotMention.friendlyForms(from: "A ll"), ["a-ll"])
        XCTAssertEqual(BotMention.friendlyForms(from: "Her mes"), ["her-mes"])
        XCTAssertTrue(BotMention.friendlyForms(from: "_private").isEmpty)
        let generic = Bot(id: "code_review", job: "", shape: .circle, hue: .green)
        XCTAssertTrue(generic.friendlyMentionNames.isEmpty)
        XCTAssertFalse(generic.mentionForms.contains("codereview"))
        XCTAssertTrue(generic.mentionForms.contains("code_review"))
    }

    private func profile(name: String, displayName: String? = nil,
                         last: JSONValue? = nil, canonical: JSONValue? = nil,
                         worker: JSONValue? = nil, meta: JSONValue? = nil) -> HermesProfile {
        var raw: [String: JSONValue] = ["name": .string(name)]
        if let displayName { raw["display_name"] = .string(displayName) }
        if let last { raw["last_session"] = last }
        if let canonical { raw["canonical_session"] = canonical }
        if let worker { raw["worker_session"] = worker }
        if let meta { raw["ui_meta"] = meta }
        return HermesProfile(.object(raw))
    }

    private func session(id: String, resolvedID: String? = nil,
                         title: String? = nil, rootTitle: String? = nil,
                         preview: String? = nil,
                         lastActive: Double? = nil,
                         messageCount: Int? = nil) -> JSONValue {
        var raw: [String: JSONValue] = ["id": .string(id)]
        if let resolvedID { raw["resolved_id"] = .string(resolvedID) }
        if let title { raw["title"] = .string(title) }
        if let rootTitle { raw["root_title"] = .string(rootTitle) }
        if let preview { raw["preview"] = .string(preview) }
        if let lastActive { raw["last_active"] = .number(lastActive) }
        if let messageCount { raw["message_count"] = .number(Double(messageCount)) }
        return .object(raw)
    }
}
#endif
