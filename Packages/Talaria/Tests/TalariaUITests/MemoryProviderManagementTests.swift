import XCTest
import TalariaKit
@testable import TalariaUI

final class MemoryProviderManagementTests: XCTestCase {
    func testInventorySeparatesGatewayStateAndSetupReadiness() {
        let value: JSONValue = [
            "active": "honcho",
            "builtin_files": ["memory": 81, "user": 19],
            "providers": [[
                "name": "honcho",
                "description": "Network memory",
                "available": false,
                "configured": true,
                "status": "unavailable",
                "setup": [
                    "pip_dependencies": ["honcho-ai"],
                    "external_dependencies": [["name": "sqlite", "install": "brew", "check": "sqlite3"]],
                    "required_env": ["HONCHO_API_KEY"],
                    "dependencies_installed": false,
                ],
            ]],
        ]

        let inventory = MemoryProviderInventory(value)

        XCTAssertEqual(inventory.activeGatewayDefault, "honcho")
        XCTAssertEqual(inventory.memoryBytes, 81)
        XCTAssertEqual(inventory.userBytes, 19)
        XCTAssertEqual(inventory.providers.first?.setup.pipDependencies, ["honcho-ai"])
        XCTAssertEqual(inventory.providers.first?.setup.externalDependencies, ["sqlite"])
        XCTAssertTrue(inventory.providers.first?.setup.hasWork == true)
    }

    func testDeclaredFieldsMapToMobileEditorKinds() {
        let value: JSONValue = [
            "name": "example",
            "label": "Example",
            "fields": [
                field("host", kind: "text", value: "localhost"),
                field("token", kind: "secret", value: "", isSet: true),
                field("mode", kind: "select", value: "fast",
                      options: [["value": "fast", "label": "Fast", "description": ""]]),
                field("enabled", kind: "bool", value: "true"),
                field("limit", kind: "number", value: "4.5"),
            ],
        ]

        let config = MemoryProviderDeclaredConfig(value)

        XCTAssertEqual(config.fields.map(\.kind), [.text, .secret, .select, .boolean, .number])
        XCTAssertEqual(config.fields[2].options.first?.value, "fast")
        XCTAssertTrue(config.fields[1].isSet)
    }

    func testBlankSecretIsOmittedWhileNonSecretBlankStillClearsOverride() {
        let value: JSONValue = [
            "name": "example",
            "fields": [
                field("token", kind: "secret", value: "", isSet: true),
                field("host", kind: "text", value: "old"),
                field("enabled", kind: "bool", value: "true"),
            ],
        ]
        let config = MemoryProviderDeclaredConfig(value)

        let submission = config.submission(from: [
            "token": "   ",
            "host": "",
            "enabled": "false",
        ])

        XCTAssertNil(submission["token"])
        XCTAssertEqual(submission["host"], .string(""))
        XCTAssertEqual(submission["enabled"], .string("false"))
    }

    func testNewSecretIsSubmittedWithoutTrimmingItsValue() {
        let value: JSONValue = [
            "name": "example",
            "fields": [field("token", kind: "secret", value: "")],
        ]
        let config = MemoryProviderDeclaredConfig(value)

        XCTAssertEqual(config.submission(from: ["token": "  opaque value  "])["token"],
                       .string("  opaque value  "))
    }

    func testCatalogKeepsProfileOnlyAndConfiguredProviders() {
        let gateway = MemoryProviderInventoryRow([
            "name": "gateway-provider", "description": "", "available": true,
            "configured": true, "status": "ready", "setup": [:],
        ])!

        let names = MemoryProviderCatalog.merge(
            profileSchema: ["", "profile-provider", "gateway-provider"],
            gatewayInventory: [gateway], active: "configured-but-missing")

        XCTAssertEqual(names, ["profile-provider", "gateway-provider", "configured-but-missing"])
    }

    func testCheckpointRequirementPreservesRawNonBooleanValue() {
        let configuration: JSONValue = [
            "memory": ["provider": "durable"],
            "compression": ["checkpoint_required": "yes"],
        ]

        let scoped = MemoryProviderScopeConfiguration(configuration)

        XCTAssertEqual(scoped.activeProvider, "durable")
        XCTAssertEqual(scoped.checkpointRequirement.rawValue, .string("yes"))
        XCTAssertEqual(scoped.checkpointRequirement.rawState, .unrecognized(.string("yes")))
        XCTAssertNil(scoped.checkpointRequirement.enabled)

        let state = CompressionCheckpointGateState.resolve(
            requirement: scoped.checkpointRequirement,
            activeProvider: scoped.activeProvider,
            inventory: checkpointInventory(apiVersion: 2))

        XCTAssertEqual(state, .unavailable(.checkpointValueUnrecognized(.string("yes"))))
        XCTAssertFalse(state.toggleIsVisible)
        XCTAssertFalse(state.isRecoverableConfigurationState)
    }

    func testCheckpointToggleRequiresReadyActiveProviderAndExplicitV2Advertisement() {
        let requirement = CompressionCheckpointRequirement(rawValue: .bool(false))
        let state = CompressionCheckpointGateState.resolve(
            requirement: requirement, activeProvider: "durable",
            inventory: checkpointInventory(apiVersion: 2))

        XCTAssertEqual(state, .controllable(enabled: false, provider: "durable", apiVersion: 2))
        XCTAssertTrue(state.toggleIsVisible)
        XCTAssertEqual(state.enabled, false)

        // A different provider advertising v2 cannot authorize the selected
        // provider. The gate is tied to the active provider, not a catalog row.
        let wrongProvider = CompressionCheckpointGateState.resolve(
            requirement: requirement, activeProvider: "other",
            inventory: checkpointInventory(apiVersion: 2))
        XCTAssertEqual(wrongProvider, .unavailable(.activeProviderNotReported("other")))
        XCTAssertFalse(wrongProvider.toggleIsVisible)
    }

    func testCheckpointGateBlocksEnabledRequirementRecoverablyWithoutV2Proof() {
        let requirement = CompressionCheckpointRequirement(rawValue: .bool(true))
        let state = CompressionCheckpointGateState.resolve(
            requirement: requirement, activeProvider: "durable",
            inventory: checkpointInventory(apiVersion: nil))

        XCTAssertEqual(state, .blocked(.checkpointAPINotAdvertised("durable")))
        XCTAssertTrue(state.isRecoverableConfigurationState)
        XCTAssertFalse(state.toggleIsVisible)
        XCTAssertEqual(state.blocker, .checkpointAPINotAdvertised("durable"))
    }

    func testCheckpointGateRejectsOldOrUnreadyCapabilityClaims() {
        let requirement = CompressionCheckpointRequirement(rawValue: .bool(true))

        let old = CompressionCheckpointGateState.resolve(
            requirement: requirement, activeProvider: "durable",
            inventory: checkpointInventory(apiVersion: 1))
        XCTAssertEqual(old, .blocked(.checkpointAPIVersionTooOld(provider: "durable", version: 1)))

        let unavailable = CompressionCheckpointGateState.resolve(
            requirement: requirement, activeProvider: "durable",
            inventory: checkpointInventory(apiVersion: 2, available: false, status: "unavailable"))
        XCTAssertEqual(unavailable, .blocked(.activeProviderNotReady("durable")))
        XCTAssertTrue(unavailable.isRecoverableConfigurationState)
    }

    func testCheckpointInventoryAcceptsOnlyExactNumericApiVersions() {
        let decimal = MemoryProviderInventoryRow([
            "name": "durable", "available": true, "configured": true, "status": "ready",
            "pre_compress_checkpoint_api_version": 2.5,
        ])
        let versionTwo = MemoryProviderInventoryRow([
            "name": "durable", "available": true, "configured": true, "status": "ready",
            "pre_compress_checkpoint_api_version": 2,
        ])

        XCTAssertEqual(decimal?.checkpointAPIVersionRaw, .number(2.5))
        XCTAssertNil(decimal?.checkpointAPIVersion)
        XCTAssertFalse(decimal?.advertisesCheckpointAPIV2 ?? true)
        XCTAssertEqual(versionTwo?.checkpointAPIVersion, 2)
        XCTAssertTrue(versionTwo?.advertisesCheckpointAPIV2 ?? false)
    }

    func testCheckpointBlockedPrerequisiteIsAnApplicationOutcomeNotTransportLoss() {
        let blocked = GatewayError(code: 409,
                                   message: "BLOCKED_MISSING_PREREQUISITE: provider unavailable")
        let disconnected = GatewayError(code: -7, message: "connection lost")

        XCTAssertTrue(CompressionCheckpointFailurePolicy.isBlockedPrerequisite(blocked))
        XCTAssertFalse(CompressionCheckpointFailurePolicy.isBlockedPrerequisite(disconnected))

        // Some gateway paths can return a result envelope rather than a JSON-RPC
        // error. A `compressed:false` flag must not downgrade the strict
        // checkpoint block into the ordinary lock-held/no-op state.
        let result = SessionCompression(.object([
            "status": .string("blocked"),
            "message": .string("BLOCKED_MISSING_PREREQUISITE: checkpoint failed"),
            "compressed": .bool(false),
        ]))
        XCTAssertEqual(result.outcome.rawValue, "blocked")
        XCTAssertEqual(result.headline, "BLOCKED_MISSING_PREREQUISITE: checkpoint failed")
    }

    func testDeclaredConfigSaveDoesNotImplyActivation() {
        XCTAssertEqual(MemoryProviderSaveSemantics.activeSelection(
            afterDeclaredSave: "builtin"), "builtin")
        XCTAssertEqual(MemoryProviderSaveSemantics.activeSelection(
                       afterDeclaredSave: "honcho"), "honcho")
    }

    func testSaveCopyPromisesConfigurationOnly() {
        let standardAction = MemoryProviderCopySemantics.saveAction(control: false)
        let standardNotice = MemoryProviderCopySemantics.savedNotice(
            control: false, provider: "honcho")
        let controlAction = MemoryProviderCopySemantics.saveAction(control: true)
        let controlNotice = MemoryProviderCopySemantics.savedNotice(
            control: true, provider: "honcho")

        XCTAssertEqual(standardAction, "Save provider configuration")
        XCTAssertTrue(standardNotice.contains("Activate it separately"))
        XCTAssertFalse((standardAction + standardNotice).lowercased().contains("selected"))
        XCTAssertEqual(controlAction, "SAVE PROVIDER CONFIG")
        XCTAssertEqual(controlNotice, "CONFIG SAVED: HONCHO")
    }

    func testDocumentationLinksRequireHTTPHost() {
        XCTAssertEqual(MemoryProviderDocumentationPolicy.externalURL(
            "https://docs.example/provider")?.absoluteString,
            "https://docs.example/provider")
        XCTAssertEqual(MemoryProviderDocumentationPolicy.externalURL(
            " http://localhost:8080/help ")?.absoluteString,
            "http://localhost:8080/help")
        XCTAssertNil(MemoryProviderDocumentationPolicy.externalURL("file:///etc/passwd"))
        XCTAssertNil(MemoryProviderDocumentationPolicy.externalURL("javascript:alert(1)"))
        XCTAssertNil(MemoryProviderDocumentationPolicy.externalURL("https:///missing-host"))
        XCTAssertNil(MemoryProviderDocumentationPolicy.externalURL("docs.example/provider"))
    }

    func testOAuthStatusParsesProfileCredentialState() {
        let status = MemoryProviderOAuthStatus([
            "state": "connected", "detail": "Honcho connected",
            "connected": true, "auth": "oauth",
        ])

        XCTAssertEqual(status.state, .connected)
        XCTAssertTrue(status.connected)
        XCTAssertEqual(status.authentication, "oauth")
    }

    func testReconnectDoesNotFinishFromOldCredentialWhileNewFlowIsPending() {
        let status = MemoryProviderOAuthStatus([
            "state": "pending", "detail": "waiting", "connected": true, "auth": "oauth",
        ])

        XCTAssertEqual(MemoryProviderOAuthPollDecision.decide(status: status, timedOut: false),
                       .keepWaiting)
        XCTAssertEqual(MemoryProviderOAuthPollDecision.decide(status: status, timedOut: true),
                       .failed("Phone polling timed out; the gateway browser flow may still finish."))
    }

    func testOAuthPollingRecognizesTerminalConnectionAndProviderError() {
        let connected = MemoryProviderOAuthStatus([
            "state": "connected", "detail": "done", "connected": true, "auth": "oauth",
        ])
        let failed = MemoryProviderOAuthStatus([
            // An old credential may remain connected when RECONNECT fails.
            "state": "error", "detail": "consent denied", "connected": true, "auth": "oauth",
        ])
        let wrongProfile = MemoryProviderOAuthStatus([
            "state": "connected", "detail": "done", "connected": false, "auth": nil,
        ])

        XCTAssertEqual(MemoryProviderOAuthPollDecision.decide(status: connected, timedOut: false),
                       .connected)
        XCTAssertEqual(MemoryProviderOAuthPollDecision.decide(status: failed, timedOut: false),
                       .failed("consent denied"))
        XCTAssertEqual(MemoryProviderOAuthPollDecision.decide(status: wrongProfile,
                                                               timedOut: false),
                       .failed("Authorization did not connect the selected profile."))
    }

    private func field(_ key: String, kind: String, value: JSONValue,
                       isSet: Bool = false, options: JSONValue = []) -> JSONValue {
        [
            "key": .string(key),
            "label": .string(key.capitalized),
            "kind": .string(kind),
            "description": "",
            "placeholder": "",
            "is_set": .bool(isSet),
            "value": value,
            "options": options,
        ]
    }

    private func checkpointInventory(apiVersion: Int?, available: Bool = true,
                                     status: String = "ready") -> MemoryProviderInventory {
        var provider: [String: JSONValue] = [
            "name": "durable",
            "description": "Durable archive",
            "available": .bool(available),
            "configured": true,
            "status": .string(status),
            "setup": [:],
        ]
        if let apiVersion {
            provider["pre_compress_checkpoint_api_version"] = .number(Double(apiVersion))
        }
        return MemoryProviderInventory([
            "active": "durable",
            "providers": [.object(provider)],
            "builtin_files": [:],
        ])
    }
}
