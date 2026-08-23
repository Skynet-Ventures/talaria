import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

@MainActor
final class AdvancedTerminalCoordinatorTests: XCTestCase {
    func testInitialSessionLaunchWaitsForExactSourceAndNeverLeaksResumeAfterSwitch() {
        var binding = AdvancedTerminalSourceBinding(
            initialGatewayID: "gateway-a",
            initialProfile: "default",
            initialResume: "durable-session-a"
        )

        XCTAssertNil(binding.request(
            workspaceGatewayID: "gateway-b",
            workspaceProfile: "other",
            knownProfiles: ["other"]
        ))
        XCTAssertFalse(binding.hasBoundInitialTarget)

        XCTAssertEqual(binding.request(
            workspaceGatewayID: "gateway-a",
            workspaceProfile: "default",
            knownProfiles: ["default"]
        ), AdvancedTerminalLaunchRequest(
            gatewayID: "gateway-a", profile: "default", resume: "durable-session-a"
        ))
        XCTAssertTrue(binding.hasBoundInitialTarget)

        // `resume` is a durable Hermes session identifier, not a one-shot
        // bearer. Recreating the Terminal tab on the same proven source must
        // reattach the same session.
        XCTAssertEqual(binding.request(
            workspaceGatewayID: "gateway-a",
            workspaceProfile: "default",
            knownProfiles: ["default"]
        ), AdvancedTerminalLaunchRequest(
            gatewayID: "gateway-a", profile: "default", resume: "durable-session-a"
        ))

        XCTAssertEqual(binding.request(
            workspaceGatewayID: "gateway-b",
            workspaceProfile: "other",
            knownProfiles: ["other"]
        ), AdvancedTerminalLaunchRequest(
            gatewayID: "gateway-b", profile: "other", resume: nil
        ))
        XCTAssertTrue(binding.hasLeftInitialTarget)

        XCTAssertEqual(binding.request(
            workspaceGatewayID: "gateway-a",
            workspaceProfile: "default",
            knownProfiles: ["default"]
        ), AdvancedTerminalLaunchRequest(
            gatewayID: "gateway-a", profile: "default", resume: nil
        ))
    }

    func testResumeWithoutExactInitialSourceFailsClosed() {
        var binding = AdvancedTerminalSourceBinding(
            initialGatewayID: nil,
            initialProfile: nil,
            initialResume: "unscoped-session"
        )

        XCTAssertNil(binding.request(
            workspaceGatewayID: "gateway-a",
            workspaceProfile: "default",
            knownProfiles: ["default"]
        ))
    }

    func testOrdinaryPinnedGatewayWaitsForFreshProfileAuthority() {
        var binding = AdvancedTerminalSourceBinding(
            initialGatewayID: "gateway-a",
            initialProfile: nil,
            initialResume: nil
        )

        XCTAssertNil(binding.request(
            workspaceGatewayID: "gateway-b",
            workspaceProfile: "default",
            knownProfiles: ["default"]
        ))
        XCTAssertNil(binding.request(
            workspaceGatewayID: "gateway-a",
            workspaceProfile: nil,
            knownProfiles: []
        ))
        XCTAssertNil(binding.request(
            workspaceGatewayID: "gateway-a",
            workspaceProfile: "default",
            knownProfiles: []
        ))
        XCTAssertEqual(binding.request(
            workspaceGatewayID: "gateway-a",
            workspaceProfile: "default",
            knownProfiles: ["default"]
        ), AdvancedTerminalLaunchRequest(
            gatewayID: "gateway-a", profile: "default", resume: nil
        ))
    }

    func testExplicitPickerTransitionClearsResumeBeforeWorkspaceChanges() {
        var binding = AdvancedTerminalSourceBinding(
            initialGatewayID: "gateway-a",
            initialProfile: "alpha",
            initialResume: "session-a"
        )
        _ = binding.request(
            workspaceGatewayID: "gateway-a",
            workspaceProfile: "alpha",
            knownProfiles: ["alpha", "beta"]
        )

        binding.clearResumeForSourceChange()

        XCTAssertEqual(binding.request(
            workspaceGatewayID: "gateway-a",
            workspaceProfile: "beta",
            knownProfiles: ["alpha", "beta"]
        ), AdvancedTerminalLaunchRequest(
            gatewayID: "gateway-a", profile: "beta", resume: nil
        ))
        XCTAssertEqual(binding.freshSessionRequest(
            workspaceGatewayID: "gateway-a",
            workspaceProfile: "beta",
            knownProfiles: ["alpha", "beta"]
        ), AdvancedTerminalLaunchRequest(
            gatewayID: "gateway-a", profile: "beta", resume: nil
        ))
    }

    func testWaitScreenFreshSessionDoesNotAuthorizeLeftoverWorkspace() {
        var binding = AdvancedTerminalSourceBinding(
            initialGatewayID: "gateway-a",
            initialProfile: "default",
            initialResume: "durable-session-a"
        )

        XCTAssertNil(binding.freshSessionRequest(
            workspaceGatewayID: "gateway-b",
            workspaceProfile: "other",
            knownProfiles: ["other"]
        ))
        XCTAssertFalse(binding.hasBoundInitialTarget)
        XCTAssertFalse(binding.hasLeftInitialTarget)
    }

    func testSameSourceFreshSessionDropsResume() {
        var binding = AdvancedTerminalSourceBinding(
            initialGatewayID: "gateway-a",
            initialProfile: "default",
            initialResume: "durable-session-a"
        )

        XCTAssertEqual(binding.freshSessionRequest(
            workspaceGatewayID: "gateway-a",
            workspaceProfile: "default",
            knownProfiles: ["default"]
        ), AdvancedTerminalLaunchRequest(
            gatewayID: "gateway-a", profile: "default", resume: nil
        ))
        XCTAssertTrue(binding.hasBoundInitialTarget)
        XCTAssertFalse(binding.hasLeftInitialTarget)

        XCTAssertEqual(binding.freshSessionRequest(
            workspaceGatewayID: "gateway-a",
            workspaceProfile: "default",
            knownProfiles: ["default"]
        ), AdvancedTerminalLaunchRequest(
            gatewayID: "gateway-a", profile: "default", resume: nil
        ))
    }

    func testUnscopedResumeFreshSessionFailsClosed() {
        var binding = AdvancedTerminalSourceBinding(
            initialGatewayID: nil,
            initialProfile: nil,
            initialResume: "unscoped-session"
        )

        XCTAssertNil(binding.freshSessionRequest(
            workspaceGatewayID: "gateway-a",
            workspaceProfile: "default",
            knownProfiles: ["default"]
        ))
    }

    func testNewSessionOnWaitScreenDoesNotDialDialableLeftover() throws {
        let leftover = try seedDialableWorkspace(
            host: "leftover-b-\(UUID().uuidString)",
            profile: "other"
        )
        defer { tearDownSeededWorkspace(leftover) }

        let probe = AdvancedTerminalCoordinator()
        defer { probe.stop() }
        probe.startFromWorkspace(
            AdvancedTerminalLaunchRequest(
                gatewayID: leftover.id, profile: "other", resume: nil
            ),
            fresh: true
        )
        XCTAssertEqual(probe.profile, "other",
                       "leftover B must be authoritative enough to open a PTY")

        var binding = AdvancedTerminalSourceBinding(
            initialGatewayID: "gateway-a",
            initialProfile: "default",
            initialResume: "durable-session-a"
        )
        let coordinator = AdvancedTerminalCoordinator()
        defer { coordinator.stop() }
        coordinator.startNewSession(&binding)

        XCTAssertEqual(
            coordinator.message,
            "Preparing the requested gateway and profile before opening Advanced Terminal."
        )
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNotEqual(coordinator.profile, "other")
        XCTAssertNotEqual(coordinator.gatewayName, leftover.name)
        XCTAssertFalse(binding.hasBoundInitialTarget)
    }

    func testSameSourceNewSessionStartsFreshWithoutResume() throws {
        let source = try seedDialableWorkspace(
            host: "requested-a-\(UUID().uuidString)",
            profile: "default"
        )
        defer { tearDownSeededWorkspace(source) }

        let store = GatewayPTYAttachmentStore.shared
        let beforeFresh = store.token(gatewayID: source.id, profile: "default", resume: nil)
        let beforeResume = store.token(
            gatewayID: source.id, profile: "default", resume: "durable-session-a")

        var binding = AdvancedTerminalSourceBinding(
            initialGatewayID: source.id,
            initialProfile: "default",
            initialResume: "durable-session-a"
        )
        let coordinator = AdvancedTerminalCoordinator()
        defer { coordinator.stop() }
        coordinator.startNewSession(&binding)

        XCTAssertEqual(coordinator.profile, "default")
        XCTAssertEqual(coordinator.gatewayName, source.name)
        XCTAssertTrue(coordinator.message.isEmpty)
        XCTAssertTrue(binding.hasBoundInitialTarget)
        XCTAssertFalse(binding.hasLeftInitialTarget)
        XCTAssertNotEqual(
            beforeFresh,
            store.token(gatewayID: source.id, profile: "default", resume: nil),
            "a new session must rotate the unscoped attach token"
        )
        XCTAssertEqual(
            beforeResume,
            store.token(gatewayID: source.id, profile: "default", resume: "durable-session-a"),
            "a new session must not consume the durable resume attach"
        )

        store.remove(gatewayID: source.id)
    }

    func testAttachmentTokensAreStableScopedRotatableAndRemovable() {
        let suite = "AdvancedTerminalCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GatewayPTYAttachmentStore(defaults: defaults)

        let first = store.token(gatewayID: "a|b", profile: "default", resume: nil)
        XCTAssertEqual(first, store.token(gatewayID: "a|b", profile: "default", resume: nil))
        XCTAssertNotEqual(first, store.token(gatewayID: "a", profile: "b|default", resume: nil))
        XCTAssertNotEqual(first, store.token(gatewayID: "a|b", profile: "default", resume: "session"))

        let rotated = store.rotate(gatewayID: "a|b", profile: "default", resume: nil)
        XCTAssertNotEqual(first, rotated)
        XCTAssertEqual(rotated, store.token(gatewayID: "a|b", profile: "default", resume: nil))

        store.remove(gatewayID: "a|b")
        XCTAssertNotEqual(rotated, store.token(gatewayID: "a|b", profile: "default", resume: nil))
    }

    func testDetachedTTLRequiresExplicitDecisionAtSafetyBoundary() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(AdvancedTerminalCoordinator.needsResumeDecision(
            backgroundedAt: start,
            now: start.addingTimeInterval(AdvancedTerminalCoordinator.detachedSessionSafetyWindow - 1)
        ))
        XCTAssertTrue(AdvancedTerminalCoordinator.needsResumeDecision(
            backgroundedAt: start,
            now: start.addingTimeInterval(AdvancedTerminalCoordinator.detachedSessionSafetyWindow)
        ))
    }

    func testRepeatedInactiveSignalPreservesOriginalDetachTime() {
        let coordinator = AdvancedTerminalCoordinator()
        let start = Date(timeIntervalSince1970: 2_000)
        coordinator.setForeground(false, now: start)
        coordinator.setForeground(false, now: start.addingTimeInterval(1_700))
        coordinator.setForeground(true, now: start.addingTimeInterval(1_741))
        XCTAssertTrue(coordinator.requiresResumeDecision)
    }

    @discardableResult
    private func seedDialableWorkspace(host: String, profile: String) throws -> SavedGateway {
        let registry = ConnectionRegistry.shared
        let gateway = try XCTUnwrap(registry.upsert(
            urlString: "https://\(host).example",
            name: host,
            credential: .sessionToken("leftover-token-\(host)")
        ))
        let workspace = WorkspaceRuntime.shared
        workspace.gatewayID = gateway.id
        workspace.profile = profile
        workspace.profiles = [WorkspaceProfileSource(profile: profile)]
        return gateway
    }

    private func tearDownSeededWorkspace(_ gateway: SavedGateway) {
        AdvancedTerminalCoordinator.shared.stop()
        GatewayPTYAttachmentStore.shared.remove(gatewayID: gateway.id)
        ConnectionRegistry.shared.remove(id: gateway.id)
        _ = WorkspaceRuntime.shared.begin(gatewayID: nil)
    }
}
