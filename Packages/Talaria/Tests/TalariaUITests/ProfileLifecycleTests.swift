import Foundation
import Testing
import TalariaKit
@testable import TalariaUI

@Suite("Source-qualified profile lifecycle", .serialized)
struct ProfileLifecycleTests {
    @Test func renameRequestCarriesExactRESTMethodPathBodyAndCredential() throws {
        let request = try GatewayREST.profileLifecycleRequest(
            baseURL: #require(URL(string: "https://gateway.example/base/")),
            credential: .sessionToken("secret"), profile: "worker one",
            method: "PATCH", newName: "renamed")
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.absoluteString == "https://gateway.example/base/api/profiles/worker%20one")
        #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "secret")
        let body = try #require(request.httpBody)
        let decoded = try JSONDecoder().decode([String: String].self, from: body)
        #expect(decoded == ["new_name": "renamed"])
    }

    @Test func oauthDeleteRequestDoesNotCarryRenameBody() throws {
        let tokens = TokenSet(accessToken: "access", refreshToken: "refresh",
                              expiresAt: 4_000_000_000, provider: "nous", userID: nil)
        let request = try GatewayREST.profileLifecycleRequest(
            baseURL: #require(URL(string: "https://gateway.example")),
            credential: .oauth(tokens), profile: "worker", method: "DELETE")
        #expect(request.httpMethod == "DELETE")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
    }

    @Test func authoritativeInventoryRequestIsAuthenticatedAndPathPreserving() throws {
        let request = GatewayREST.profileInventoryRequest(
            baseURL: try #require(URL(string: "https://gateway.example/base/")),
            credential: .sessionToken("secret"))
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://gateway.example/base/api/profiles")
        #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "secret")
    }

    @Test func authoritativeInventoryRejectsAnyMalformedOrConflictingRow() throws {
        let valid: JSONValue = ["profiles": [
            ["name": "default", "display_name": "Hermes Prime"],
            ["name": "worker"],
        ]]
        #expect(try GatewayREST.decodeProfileNames(valid) == ["default", "worker"])
        let inventory = try GatewayREST.decodeProfileInventory(valid)
        #expect(inventory["default"]?.displayName == "Hermes Prime")
        #expect(inventory["worker"]?.displayName == nil)

        let invalid: [JSONValue] = [
            ["profiles": [["name": "default"], [:]]],
            ["profiles": [["name": "default"], ["name": ""]]],
            ["profiles": [["name": "worker"], ["name": "worker"]]],
            ["profiles": [["name": "worker"], ["name": "Worker"]]],
            ["profiles": [["name": " worker"]]],
        ]
        for value in invalid {
            #expect(throws: GatewayError.self) {
                _ = try GatewayREST.decodeProfileNames(value)
            }
        }
    }

    @Test func disconnectedPoolSentinelFencesRedialUntilReleased() async throws {
        let base = try #require(URL(string: "https://gateway.example"))
        let fallback = GatewayClient(baseURL: base, credential: .sessionToken("fallback"))
        let pool = GatewayClientPool { _, _ in fallback }
        let sentinel = GatewayClient(baseURL: base, credential: .sessionToken("sentinel"))
        await pool.adopt(sentinel, for: "mac")
        let routed = try await pool.connect(gatewayID: "mac", baseURL: base,
                                            credential: .sessionToken("new"))
        #expect(routed === sentinel)
        #expect(!(await routed.isConnected))
    }

    @Test func clientAdmissionRejectsRPCAndRESTBeforeTransportOrNetworkUse() async throws {
        let client = GatewayClient(
            baseURL: try #require(URL(string: "https://gateway.invalid")),
            credential: .sessionToken("unused"))
        await client.setTrafficAdmission { nil }

        do {
            _ = try await client.rpc("profiles.list")
            Issue.record("fenced RPC unexpectedly reached transport")
        } catch let error as GatewayError {
            #expect(error.code == GatewayClient.trafficFenced)
        }

        do {
            _ = try await client.restJSON(path: "api/config", timeout: 1)
            Issue.record("fenced REST unexpectedly reached URLSession")
        } catch let error as GatewayError {
            #expect(error.code == GatewayClient.trafficFenced)
        }
    }

    @Test @MainActor func ordinaryTrafficLeaseExcludesLifecycleForItsEntireAwait() async throws {
        let gatewayID = "lease-\(UUID().uuidString)"
        let lease = try #require(ProfileLifecycleTrafficAdmission.acquire(gatewayID))
        let concurrentLease = try #require(ProfileLifecycleTrafficAdmission.acquire(gatewayID))
        #expect(!ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID))

        await lease.release()
        #expect(!ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID))
        await concurrentLease.release()
        #expect(ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID))
        #expect(ProfileLifecycleTrafficAdmission.acquire(gatewayID) == nil)
        ProfileLifecycleTrafficAdmission.endLifecycle(gatewayID)

        let replacement = try #require(ProfileLifecycleTrafficAdmission.acquire(gatewayID))
        await replacement.release()
    }

    @Test @MainActor
    func authoritativeReconciliationReopensOwnerReconnectAndDefaultRosterRefresh() async throws {
        let gatewayID = "authoritative-\(UUID().uuidString)"
        #expect(ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID))

        // Reconnect and the default-profile roster refresh use the same
        // ordinary client/REST admission as every external caller. Neither is
        // allowed while Hermes' filesystem mutation is unresolved.
        #expect(ProfileLifecycleTrafficAdmission.acquire(gatewayID) == nil)

        let recoveryLease =
            ProfileLifecycleTrafficAdmission.finishAuthoritativeReconciliation(gatewayID)
        #expect(!ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID))
        let ownerTraffic = try #require(
            ProfileLifecycleTrafficAdmission.acquire(gatewayID))
        await ownerTraffic.release()
        #expect(!ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID))
        await recoveryLease.release()
        #expect(ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID))
        ProfileLifecycleTrafficAdmission.endLifecycle(gatewayID)
    }

    @Test @MainActor func completedLeaseCannotReleaseASuccessorLifecycle() async {
        let gatewayID = "successor-\(UUID().uuidString)"
        #expect(ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID))
        let first = ProfileLifecycleExclusiveLease(gatewayID: gatewayID)
        let recoveryLease = first.finishAuthoritativeReconciliation()

        #expect(!ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID))
        first.releaseIfHeld()
        #expect(!ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID))
        await recoveryLease.release()
        #expect(ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID))
        ProfileLifecycleTrafficAdmission.endLifecycle(gatewayID)
    }

    @Test func retiredARecoveryCannotReplaceLaterBPrimaryOrInFlightSwitch() {
        let retiredA = ProfileLifecycleRetirement(
            wasActive: true, connectionGeneration: 41)
        #expect(!ProfileLifecycleRecoveryPolicy.mayRestorePrimary(
            retirement: retiredA, currentGeneration: 42,
            currentGatewayID: "gateway-b", hasClient: true,
            switchInProgress: false))
        #expect(!ProfileLifecycleRecoveryPolicy.mayRestorePrimary(
            retirement: retiredA, currentGeneration: 41,
            currentGatewayID: nil, hasClient: false,
            switchInProgress: true))
    }

    @Test func retiredPrimaryRecoveryIsAllowedOnlyWhileStillUnclaimed() {
        let retiredA = ProfileLifecycleRetirement(
            wasActive: true, connectionGeneration: 41)
        #expect(ProfileLifecycleRecoveryPolicy.mayRestorePrimary(
            retirement: retiredA, currentGeneration: 41,
            currentGatewayID: nil, hasClient: false,
            switchInProgress: false))
        #expect(!ProfileLifecycleRecoveryPolicy.mayRestorePrimary(
            retirement: retiredA, currentGeneration: 41,
            currentGatewayID: "gateway-b", hasClient: true,
            switchInProgress: false))
    }

    @Test func switchingBKeepsRetiredAReconciliationQualifiedDuringNilGatewayWindow() {
        let retiredA = ProfileLifecycleRetirement(
            wasActive: true, connectionGeneration: 41)
        let mayRestore = ProfileLifecycleRecoveryPolicy.mayRestorePrimary(
            retirement: retiredA, currentGeneration: 41,
            currentGatewayID: nil, hasClient: true,
            switchInProgress: true)
        #expect(!mayRestore)

        let target = ProfileLifecycleTarget(
            rosterID: "worker",
            route: GatewayBotRoute(gatewayID: "gateway-a", profile: "worker"))
        let plan = ProfileLifecycleStatePlan(
            target: target, canonicalNewName: "renamed",
            currentPrimaryGatewayID: nil,
            restorePrimaryIfUnclaimed: mayRestore)
        #expect(plan.sourceIDs == ["gateway-a::worker"])
        #expect(plan.destinationID == "gateway-a::renamed")
        #expect(!plan.destinationIsPrimary)
    }

    @Test @MainActor func retirementDisconnectExcludesBSwitchUntilCleanupCompletes() {
        let supervisor = ConnectionSupervisor.shared
        let original = supervisor.isReconnecting
        supervisor.isReconnecting = false
        defer { supervisor.isReconnecting = original }

        #expect(ProfileLifecycleSwitchClaim.acquire())
        // This is the exact admission check switchGateway(B) performs while
        // disconnectGateway(A) is suspended in the client-pool await.
        #expect(!ProfileLifecycleSwitchClaim.acquire())
        ProfileLifecycleSwitchClaim.release()

        #expect(ProfileLifecycleSwitchClaim.acquire())
        ProfileLifecycleSwitchClaim.release()
    }

    @Test @MainActor func clientReleasesOrdinaryLeaseOnTransportFailure() async throws {
        let gatewayID = "release-\(UUID().uuidString)"
        let client = GatewayClient(
            baseURL: try #require(URL(string: "https://gateway.invalid")),
            credential: .sessionToken("unused"))
        await client.setTrafficAdmission {
            await ProfileLifecycleTrafficAdmission.acquire(gatewayID)
        }

        do {
            _ = try await client.rpc("profiles.list")
            Issue.record("disconnected test client unexpectedly completed an RPC")
        } catch let error as GatewayError {
            #expect(error.code == -3)
        }

        #expect(ProfileLifecycleTrafficAdmission.beginLifecycle(gatewayID))
        ProfileLifecycleTrafficAdmission.endLifecycle(gatewayID)
    }

    @Test func defaultRenameResponsePreservesCanonicalIdentity() {
        let result = ProfileRenameResult(.object([
            "ok": .bool(true), "name": .string("default"),
            "display_name": .string("Hermes Prime"),
        ]))
        #expect(result?.name == "default")
        #expect(result?.displayName == "Hermes Prime")
    }

    @Test func renameResponseWithoutCanonicalIdentityFailsClosed() {
        #expect(ProfileRenameResult(.object(["ok": .bool(true)])) == nil)
        #expect(ProfileRenameResult(.object(["ok": .bool(true), "name": .string("  ")])) == nil)
    }

    @Test func profileNamePolicyMirrorsHermesReservedNames() {
        for reserved in ["hermes", "default", "test", "tmp", "root", "sudo",
                         "chat", "gateway", "config", "sessions", "profile", "acp"] {
            #expect(!ProfileNamePolicy.validatesNamedProfile(reserved))
        }
        #expect(ProfileNamePolicy.validatesNamedProfile("worker_2"))
        #expect(!ProfileNamePolicy.validatesNamedProfile("Worker"))
        #expect(!ProfileNamePolicy.validatesNamedProfile("../worker"))
    }

    @Test func acceptedSourceOverwritesAnyStaleDestinationCache() {
        var cache = ["old": "source", "new": "stale-destination"]
        ProfileLifecycleCache.moveFirst(&cache, from: ["old", "qualified-old"], to: "new")
        #expect(cache == ["new": "source"])
        var absentSource = ["new": "stale-destination"]
        ProfileLifecycleCache.moveFirst(&absentSource, from: ["old"], to: "new")
        #expect(absentSource.isEmpty)
    }

    @Test func queuedWorkRekeysBeforeReconnectOrIsDroppedOnDelete() {
        var renamed = [(botID: "old", text: "send me"),
                       (botID: "other", text: "leave me")]
        ProfileLifecycleQueue.reconcile(&renamed, sources: ["old", "mac::old"],
                                        destination: "new")
        #expect(renamed.map(\.botID) == ["new", "other"])
        #expect(renamed.map(\.text) == ["send me", "leave me"])

        var deleted = renamed
        ProfileLifecycleQueue.reconcile(&deleted, sources: ["new"], destination: nil)
        #expect(deleted.map(\.botID) == ["other"])
    }

    @Test func mutationPostconditionsResolveCommitFailureAndUncertainty() {
        #expect(ProfileLifecyclePostcondition.rename(
            names: ["default", "new"], source: "old", destination: "new") == .committed)
        #expect(ProfileLifecyclePostcondition.rename(
            names: ["default", "old"], source: "old", destination: "new") == .notCommitted)
        #expect(ProfileLifecyclePostcondition.rename(
            names: ["default"], source: "old", destination: "new") == .indeterminate)
        #expect(ProfileLifecyclePostcondition.delete(
            names: ["default"], source: "old") == .committed)
        #expect(ProfileLifecyclePostcondition.delete(
            names: ["default", "old"], source: "old") == .notCommitted)
    }

    @Test func lostDefaultRenameResponseUsesAuthoritativeDisplayNamePostcondition() {
        let committed = [
            "default": ProfileInventoryEntry(name: "default", displayName: "Hermes Prime"),
        ]
        #expect(ProfileLifecyclePostcondition.displayRename(
            inventory: committed, source: "default", requested: "Hermes Prime") == .committed)

        let notCommitted = [
            "default": ProfileInventoryEntry(name: "default", displayName: "Hermes"),
        ]
        #expect(ProfileLifecyclePostcondition.displayRename(
            inventory: notCommitted, source: "default", requested: "Hermes Prime") == .notCommitted)

        // Hermes' directory-scan fallback omits display_name. Presence of the
        // canonical default row alone cannot resolve a lost PATCH response.
        let fallback = [
            "default": ProfileInventoryEntry(name: "default", displayName: nil),
        ]
        #expect(ProfileLifecyclePostcondition.displayRename(
            inventory: fallback, source: "default", requested: "Hermes Prime") == .indeterminate)
        #expect(ProfileLifecyclePostcondition.displayRename(
            inventory: [:], source: "default", requested: "Hermes Prime") == .indeterminate)
    }

    @Test func completionFenceRejectsLateOrForeignResults() {
        #expect(ProfileLifecycleCompletionFence.accepts(
            generation: 4, currentGeneration: 4,
            gatewayID: "mac", currentGatewayID: "mac"))
        #expect(!ProfileLifecycleCompletionFence.accepts(
            generation: 3, currentGeneration: 4,
            gatewayID: "mac", currentGatewayID: "mac"))
        #expect(!ProfileLifecycleCompletionFence.accepts(
            generation: 4, currentGeneration: 4,
            gatewayID: "homelab", currentGatewayID: "mac"))
    }

    @Test func idempotentDefaultRenameDoesNotArmNextPickerSuppression() {
        #expect(!ProfileLifecycleCompletionSelection.requiresSuppression(
            current: "default", next: "default"))
        #expect(ProfileLifecycleCompletionSelection.requiresSuppression(
            current: "default", next: "worker"))
        #expect(ProfileLifecycleCompletionSelection.requiresSuppression(
            current: "homelab::default", next: "homelab::worker"))
    }

    @Test func statePlanNeverBorrowsCollidingBareNameAfterGatewaySwitch() {
        let target = ProfileLifecycleTarget(
            rosterID: "default",
            route: GatewayBotRoute(gatewayID: "mac", profile: "default"))
        let plan = ProfileLifecycleStatePlan(target: target, canonicalNewName: "renamed",
                                             currentPrimaryGatewayID: "homelab")
        #expect(plan.sourceIDs == ["mac::default"])
        #expect(plan.destinationID == "mac::renamed")
        #expect(!plan.sourceIDs.contains("default"))
    }

    @Test func statePlanUsesBareKeysOnlyForTheStillOwningPrimary() {
        let target = ProfileLifecycleTarget(
            rosterID: "default",
            route: GatewayBotRoute(gatewayID: "mac", profile: "default"))
        let plan = ProfileLifecycleStatePlan(target: target, canonicalNewName: "renamed",
                                             currentPrimaryGatewayID: "mac")
        #expect(plan.sourceIDs == ["mac::default"])
        #expect(plan.destinationID == "renamed")
        #expect(plan.destinationIsPrimary)
    }

    @Test func deletePlanHasNoDestination() {
        let target = ProfileLifecycleTarget(
            rosterID: "homelab::worker",
            route: GatewayBotRoute(gatewayID: "homelab", profile: "worker"))
        let plan = ProfileLifecycleStatePlan(target: target, canonicalNewName: nil,
                                             currentPrimaryGatewayID: "mac")
        #expect(plan.sourceIDs == ["homelab::worker"])
        #expect(plan.destinationID == nil)
    }

    @Test func disconnectedFormerPrimaryStillScrubsItsCapturedBareKey() {
        let target = ProfileLifecycleTarget(
            rosterID: "worker",
            route: GatewayBotRoute(gatewayID: "mac", profile: "worker"))
        let plan = ProfileLifecycleStatePlan(target: target, canonicalNewName: "renamed",
                                             currentPrimaryGatewayID: nil,
                                             restorePrimaryIfUnclaimed: true)
        #expect(plan.sourceIDs == ["mac::worker"])
        #expect(plan.destinationID == "renamed")
        #expect(plan.destinationIsPrimary)
    }

    @Test @MainActor func callerParksBareStateBeforePrimaryCanSwitch() throws {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "mac"
        let target = ProfileLifecycleTarget(
            rosterID: "worker",
            route: GatewayBotRoute(gatewayID: "mac", profile: "worker"))
        let sourceChat = ChatState(messages: [])
        let staleQualified = ChatState(messages: [])
        model.chats = ["worker": sourceChat, "mac::worker": staleQualified]
        model.composeQueue = [(botID: "worker", text: "source")]

        model.parkProfileLifecycleState(target)
        LiveRuntime.shared.gatewayID = "homelab"
        let collidingNewPrimary = ChatState(messages: [])
        model.chats["worker"] = collidingNewPrimary
        let plan = ProfileLifecycleStatePlan(target: target, canonicalNewName: "renamed",
                                             currentPrimaryGatewayID: LiveRuntime.shared.gatewayID,
                                             restorePrimaryIfUnclaimed: true)
        ProfileLifecycleCache.moveFirst(&model.chats, from: plan.sourceIDs,
                                        to: try #require(plan.destinationID))

        #expect(model.chats["worker"] === collidingNewPrimary)
        #expect(model.chats["mac::renamed"] === sourceChat)
        #expect(!plan.sourceIDs.contains("worker"))
        LiveRuntime.shared.gatewayID = nil
    }

    @Test @MainActor func activePrimaryRetirementRestoresOnlyExactPendingStopForRename() throws {
        let model = AppModel()
        let gatewayID = "primary-stop-\(UUID().uuidString)"
        let target = ProfileLifecycleTarget(
            rosterID: "worker",
            route: GatewayBotRoute(gatewayID: gatewayID, profile: "worker"))
        let siblingRoute = GatewayBotRoute(gatewayID: gatewayID, profile: "sibling")
        let targetChat = ChatState(messages: [])
        targetChat.storedSessionID = "stored-target"
        targetChat.sessionID = "runtime-target"
        model.chats["worker"] = targetChat
        let siblingChat = ChatState(messages: [])
        siblingChat.storedSessionID = "stored-sibling"
        model.chats[siblingRoute.qualifiedID] = siblingChat
        LiveRuntime.shared.gatewayID = gatewayID
        ChatRuntime.shared.pendingStopRequests["worker"] = PendingStopRequest(
            botID: "worker", route: target.route, storedID: "stored-target",
            sessionID: "runtime-target", chatID: ObjectIdentifier(targetChat),
            generation: LiveRuntime.shared.generation)
        ChatRuntime.shared.pendingStopRequests[siblingRoute.qualifiedID] = PendingStopRequest(
            botID: siblingRoute.qualifiedID, route: siblingRoute,
            storedID: "stored-sibling", sessionID: "runtime-sibling",
            chatID: ObjectIdentifier(siblingChat), generation: LiveRuntime.shared.generation)
        defer {
            ChatRuntime.shared.pendingStopRequests.removeAll()
            model.chats.removeValue(forKey: "worker")
            model.chats.removeValue(forKey: target.route.qualifiedID)
            model.chats.removeValue(forKey: siblingRoute.qualifiedID)
            LiveRuntime.shared.gatewayID = nil
        }

        // This is the exact primary rename pre-retirement parking boundary.
        model.parkProfileLifecycleState(target)
        #expect(ChatRuntime.shared.pendingStopRequests[target.route.qualifiedID]?.storedID
                == "stored-target")

        // disconnectGateway clears the whole departing gateway. Lifecycle
        // ownership restores only the captured target before reconciliation.
        ChatRuntime.shared.clearPendingStops(forGatewayID: gatewayID)
        #expect(ChatRuntime.shared.pendingStopRequests[target.route.qualifiedID] == nil)
        #expect(ChatRuntime.shared.pendingStopRequests[siblingRoute.qualifiedID] == nil)
        model.restoreProfileLifecyclePendingStop(target, parked: true)
        #expect(ChatRuntime.shared.pendingStopRequests[target.route.qualifiedID] != nil)
        #expect(ChatRuntime.shared.pendingStopRequests[siblingRoute.qualifiedID] == nil)

        let renamed = GatewayBotRoute(gatewayID: gatewayID, profile: "renamed")
        #expect(ChatRuntime.shared.rekeyPendingStop(
            fromBotIDs: [target.route.qualifiedID, target.route.profile],
            fromRoute: target.route, toBotID: renamed.qualifiedID, toRoute: renamed,
            chatID: ObjectIdentifier(targetChat), storedID: "stored-target"))
        #expect(ChatRuntime.shared.pendingStopRequests[target.route.qualifiedID] == nil)
        #expect(ChatRuntime.shared.pendingStopRequests[renamed.qualifiedID]?.route == renamed)
        #expect(ChatRuntime.shared.pendingStopRequests[siblingRoute.qualifiedID] == nil)
    }

    @Test @MainActor func refusedPrimaryRenameRestoresPendingStopToBareOwner() throws {
        let model = AppModel()
        let gatewayID = "primary-refused-stop-\(UUID().uuidString)"
        let target = ProfileLifecycleTarget(
            rosterID: "worker",
            route: GatewayBotRoute(gatewayID: gatewayID, profile: "worker"))
        let chat = ChatState(messages: [])
        chat.storedSessionID = "stored-target"
        chat.sessionID = "runtime-target"
        model.chats["worker"] = chat
        LiveRuntime.shared.gatewayID = gatewayID
        ChatRuntime.shared.pendingStopRequests["worker"] = PendingStopRequest(
            botID: "worker", route: target.route, storedID: "stored-target",
            sessionID: "runtime-target", chatID: ObjectIdentifier(chat),
            generation: LiveRuntime.shared.generation)
        defer {
            ChatRuntime.shared.pendingStopRequests.removeAll()
            model.chats.removeValue(forKey: "worker")
            model.chats.removeValue(forKey: target.route.qualifiedID)
            LiveRuntime.shared.gatewayID = nil
        }

        model.parkProfileLifecycleState(target)
        ChatRuntime.shared.clearPendingStops(forGatewayID: gatewayID)
        model.restoreProfileLifecyclePendingStop(target, parked: true)
        LiveRuntime.shared.gatewayID = nil
        model.restoreParkedProfileLifecycleStateIfNeeded(target, wasActive: true)

        #expect(ChatRuntime.shared.pendingStopRequests["worker"] != nil)
        #expect(ChatRuntime.shared.pendingStopRequests[target.route.qualifiedID] == nil)
        #expect(model.chats["worker"]?.storedSessionID == "stored-target")
    }

    @Test @MainActor func failedMutationRestoresBareStateOnlyWithoutNewPrimaryOwner() {
        let target = ProfileLifecycleTarget(
            rosterID: "worker",
            route: GatewayBotRoute(gatewayID: "mac", profile: "worker"))

        let reconnecting = AppModel()
        LiveRuntime.shared.gatewayID = "mac"
        let reconnectingChat = ChatState(messages: [])
        reconnecting.chats["worker"] = reconnectingChat
        reconnecting.parkProfileLifecycleState(target)
        LiveRuntime.shared.gatewayID = nil
        reconnecting.restoreParkedProfileLifecycleStateIfNeeded(target, wasActive: true)
        #expect(reconnecting.chats["worker"] === reconnectingChat)
        #expect(reconnecting.chats["mac::worker"] == nil)

        let switched = AppModel()
        LiveRuntime.shared.gatewayID = "mac"
        let parkedChat = ChatState(messages: [])
        switched.chats["worker"] = parkedChat
        switched.parkProfileLifecycleState(target)
        LiveRuntime.shared.gatewayID = "homelab"
        let newPrimaryChat = ChatState(messages: [])
        switched.chats["worker"] = newPrimaryChat
        switched.restoreParkedProfileLifecycleStateIfNeeded(target, wasActive: true)
        #expect(switched.chats["worker"] === newPrimaryChat)
        #expect(switched.chats["mac::worker"] === parkedChat)
        LiveRuntime.shared.gatewayID = nil
    }

    @Test @MainActor func abortScrubsPublishersAndInvalidatesLateCompletions() async throws {
        let model = AppModel()
        LiveRuntime.shared.gatewayID = "mac"
        let target = ProfileLifecycleTarget(
            rosterID: "worker",
            route: GatewayBotRoute(gatewayID: "mac", profile: "worker"))
        let attachment = PendingAttachment(id: "attachment", kind: .image, name: "ghost.png")
        model.chats["worker"] = ChatState(messages: [])
        model.chats["worker"]?.sessionID = "session"
        model.chats["worker"]?.isRunning = true
        model.chats["worker"]?.attachments = [attachment]
        AttachmentRuntime.shared.staged[attachment.id] = .init(paths: ["/ghost"], refText: nil)
        AttachmentRuntime.shared.uploading.insert(attachment.id)
        AttachmentRuntime.shared.chooserBotID = "worker"

        let watchdog = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        ChatRuntime.shared.submitWatchdogs["worker"] = watchdog
        ChatRuntime.shared.turnFloor["worker"] = 4
        LivenessRuntime.shared.unverifiableSince["worker"] = ContinuousClock.now

        let prompt = BlockingPrompt(kind: .secret, gatewayID: "mac", requestID: "request",
                                    sessionID: "session", botID: "worker", question: "secret")
        ApprovalBridges.shared.prompts = [prompt]
        ApprovalBridges.shared.sweptSessions = [
            GatewaySessionRoute(gatewayID: "mac", sessionID: "session"),
        ]
        LiveRuntime.shared.sessionToBot["session"] = "worker"

        let deliveryKey = AppModel.deliveryKey(to: "worker", body: "hello")
        let replyWatch = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        A2ARuntime.shared.watchers[deliveryKey] = replyWatch
        A2ARuntime.shared.watcherGeneration[deliveryKey] = 1
        A2ARuntime.shared.deliveries[deliveryKey] = A2ADelivery(
            to: "worker", queuedBehindRun: false, state: .waiting, at: Date())
        let lifecycle = try #require(model.profileLifecycleGenerationToken(for: "worker"))

        model.abortProfileRuntime(target)

        #expect(watchdog.isCancelled)
        #expect(replyWatch.isCancelled)
        #expect(ChatRuntime.shared.submitWatchdogs["worker"] == nil)
        #expect(ChatRuntime.shared.turnFloor["worker"] == nil)
        #expect(model.chats["worker"]?.attachments.isEmpty == true)
        #expect(model.chats["worker"]?.sessionID == nil)
        #expect(model.chats["worker"]?.isRunning == false)
        #expect(AttachmentRuntime.shared.staged[attachment.id] == nil)
        #expect(!AttachmentRuntime.shared.uploading.contains(attachment.id))
        #expect(AttachmentRuntime.shared.chooserBotID == nil)
        #expect(LivenessRuntime.shared.unverifiableSince["worker"] == nil)
        #expect(ApprovalBridges.shared.prompts.isEmpty)
        #expect(ApprovalBridges.shared.sweptSessions.isEmpty)
        #expect(A2ARuntime.shared.watchers.isEmpty)
        #expect(A2ARuntime.shared.deliveries[deliveryKey] == nil)
        #expect(!model.profileLifecycleAccepts(lifecycle))

        try await model.activateProfileLifecycleRoute(gatewayID: "mac", profile: "worker")
        let replacementLifecycle = try #require(model.profileLifecycleGenerationToken(for: "worker"))
        #expect(replacementLifecycle != lifecycle)
        #expect(model.profileLifecycleAccepts(replacementLifecycle))
        LiveRuntime.shared.gatewayID = nil
        LiveRuntime.shared.sessionToBot.removeAll()
        A2ARuntime.shared.reset()
        ApprovalBridges.shared.prompts.removeAll()
    }

    @Test @MainActor
    func abortRetiresExactRouteMutationAndCanonicalKickoffState() throws {
        let model = AppModel()
        let gatewayID = "route-retire-\(UUID().uuidString)"
        let profile = "worker"
        let route = GatewayBotRoute(gatewayID: gatewayID, profile: profile)
        let siblingRoute = GatewayBotRoute(gatewayID: gatewayID, profile: "sibling")
        let chat = ChatState(messages: [])
        chat.storedSessionID = "stored-worker"
        model.chats[profile] = chat
        model.chats[siblingRoute.qualifiedID] = ChatState(messages: [])
        LiveRuntime.shared.gatewayID = gatewayID
        LiveRuntime.shared.sessionToBot["runtime-worker"] = profile
        LiveRuntime.shared.sessionToBot["runtime-sibling"] = siblingRoute.qualifiedID
        LiveRuntime.shared.workingBotIDs = [profile, siblingRoute.qualifiedID]

        let actionID = UUID()
        ChatRuntime.shared.transcriptActions[profile] = actionID
        ChatRuntime.shared.transcriptActionGenerations[profile] = 7
        ChatRuntime.shared.queuedBindings[actionID] = QueuedPromptBinding(
            botID: profile, sessionID: "runtime-worker", storedID: "stored-worker",
            route: route, eligibleAfterCurrentTurn: true, order: 1)
        model.promptQueue = [(id: actionID, botID: profile, text: "queued")]

        let siblingID = UUID()
        ChatRuntime.shared.transcriptActions[siblingRoute.qualifiedID] = siblingID
        let kickoff = CanonicalKickoffLease(
            id: UUID(), botID: profile, sessionID: "runtime-worker",
            storedID: "stored-worker", rowID: nil, chatID: ObjectIdentifier(chat),
            route: route)
        CanonicalChatRuntime.shared.kickoffs[profile] = kickoff.id
        CanonicalChatRuntime.shared.kickoffLeases[profile] = kickoff
        CanonicalChatRuntime.shared.ambiguousKickoffs[profile] = kickoff

        defer {
            ChatRuntime.shared.transcriptActions.removeAll()
            ChatRuntime.shared.transcriptActionGenerations.removeAll()
            ChatRuntime.shared.queuedBindings.removeAll()
            ChatRuntime.shared.queuedLifecycles.removeAll()
            ChatRuntime.shared.pendingQueuedSubmissions.removeAll()
            model.promptQueue.removeAll()
            CanonicalChatRuntime.shared.kickoffs.removeAll()
            CanonicalChatRuntime.shared.kickoffLeases.removeAll()
            CanonicalChatRuntime.shared.ambiguousKickoffs.removeAll()
            model.chats.removeAll()
            LiveRuntime.shared.sessionToBot.removeAll()
            LiveRuntime.shared.workingBotIDs.removeAll()
            LiveRuntime.shared.gatewayID = nil
        }

        model.abortProfileRuntime(ProfileLifecycleTarget(rosterID: profile, route: route))

        #expect(ChatRuntime.shared.transcriptActions[profile] == nil)
        #expect(ChatRuntime.shared.transcriptActionGenerations[profile] == nil)
        #expect(ChatRuntime.shared.queuedBindings[actionID] == nil)
        #expect(model.promptQueue.isEmpty)
        #expect(CanonicalChatRuntime.shared.kickoffs[profile] == nil)
        #expect(CanonicalChatRuntime.shared.kickoffLeases[profile] == nil)
        #expect(CanonicalChatRuntime.shared.ambiguousKickoffs[profile] == nil)
        #expect(ChatRuntime.shared.transcriptActions[siblingRoute.qualifiedID] == siblingID)
        #expect(LiveRuntime.shared.sessionToBot["runtime-worker"] == nil)
        #expect(LiveRuntime.shared.sessionToBot["runtime-sibling"] == siblingRoute.qualifiedID)
        #expect(!LiveRuntime.shared.workingBotIDs.contains(profile))
        #expect(LiveRuntime.shared.workingBotIDs.contains(siblingRoute.qualifiedID))
    }

    @Test @MainActor
    func primaryParkingMovesQueuedPromptWithQualifiedOwnerAndRestoresIt() throws {
        let model = AppModel()
        let gatewayID = "queue-park-(UUID().uuidString)"
        let profile = "worker"
        let route = GatewayBotRoute(gatewayID: gatewayID, profile: profile)
        let chat = ChatState(messages: [])
        chat.sessionID = "runtime"
        chat.storedSessionID = "stored"
        model.chats[profile] = chat
        LiveRuntime.shared.gatewayID = gatewayID
        ChatRuntime.shared.queuedBindings.removeAll()
        ChatRuntime.shared.queuedLifecycles.removeAll()
        ChatRuntime.shared.pendingQueuedSubmissions.removeAll()
        model.promptQueue.removeAll()
        defer {
            ChatRuntime.shared.queuedBindings.removeAll()
            ChatRuntime.shared.queuedLifecycles.removeAll()
            ChatRuntime.shared.pendingQueuedSubmissions.removeAll()
            model.promptQueue.removeAll()
            model.chats.removeAll()
            LiveRuntime.shared.gatewayID = nil
        }

        model.enqueuePrompt("queued", botID: profile, sessionID: "runtime")
        let rowID = try #require(model.promptQueue.first?.id)
        model.parkProfileLifecycleState(
            ProfileLifecycleTarget(rosterID: profile, route: route))

        #expect(model.chats[route.qualifiedID] === chat)
        #expect(model.promptQueue.first?.botID == route.qualifiedID)
        #expect(ChatRuntime.shared.queuedBindings[rowID]?.botID == route.qualifiedID)

        model.restoreParkedProfileLifecycleStateIfNeeded(
            ProfileLifecycleTarget(rosterID: profile, route: route), wasActive: true)

        #expect(model.chats[profile] === chat)
        #expect(model.promptQueue.first?.botID == profile)
        #expect(ChatRuntime.shared.queuedBindings[rowID]?.botID == profile)
    }

    @Test @MainActor
    func profileLifecycleParkingRetiresCanonicalOpenWorkWithoutPointerState() throws {
        let model = AppModel()
        let gatewayID = "pin-refused-(UUID().uuidString)"
        let profile = "worker"
        let route = GatewayBotRoute(gatewayID: gatewayID, profile: profile)
        let chat = ChatState(messages: [])
        chat.storedSessionID = "stored-canonical"
        model.chats[profile] = chat
        LiveRuntime.shared.gatewayID = gatewayID
        defer {
            model.chats.removeAll()
            LiveRuntime.shared.gatewayID = nil
        }

        model.parkProfileLifecycleCanonicalState(
            ProfileLifecycleTarget(rosterID: profile, route: route))
        model.restoreParkedProfileLifecycleCanonicalStateIfNeeded(
            ProfileLifecycleTarget(rosterID: profile, route: route), preferPrimary: true)
        #expect(CanonicalChatRuntime.shared.opens[profile] == nil)
    }

    @Test @MainActor
    func roomLifecycleDeleteTombstoneReopensOnlyAfterDefinitiveRefusal() async {
        let model = AppModel()
        let route = GatewayBotRoute(
            gatewayID: "room-lifecycle-(UUID().uuidString)", profile: "worker")
        let runtime = RoomRuntime.shared
        defer {
            runtime.retiredProfileRoutes.remove(route)
            runtime.profileRouteGenerations.removeValue(forKey: route)
        }

        let token = model.prepareRoomProfileLifecycle(source: route, deleting: true)
        #expect(runtime.retiredProfileRoutes.contains(route))
        #expect(!runtime.acceptsProfileRoute(route, generation: token.generation))

        // A refused delete is the only path that may reopen the source route;
        // an uncertain/committed delete keeps the tombstone in place.
        await model.abortRoomProfileLifecycle(token)
        #expect(!runtime.retiredProfileRoutes.contains(route))
        #expect(runtime.profileRouteGeneration(route) > token.generation)
    }

    @Test @MainActor func unreadLifecycleRekeysSourceMarkOverStaleDestination() throws {
        let suite = "ProfileLifecycleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UnreadWatermarkStore(defaults: defaults)
        let scope = try #require(URL(string: "https://gateway.example"))
        #expect(store.ingest(["old": 10, "new": 1], openBot: nil, scope: scope).isEmpty)
        store.reconcileProfileLifecycle(profile: "old", newProfile: "new", scope: scope)
        #expect(store.ingest(["new": 10], openBot: nil, scope: scope).isEmpty)
        #expect(store.ingest(["new": 11], openBot: nil, scope: scope) == ["new"])
    }
}
