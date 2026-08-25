import XCTest
import TalariaKit
@testable import TalariaUI

final class WebCacheManagementTests: XCTestCase {
    func testConfigRequestWritesOnlyTheTargetLeafAndProfile() {
        let query = WebCacheConfigurationRequest.query(profile: "research")
        XCTAssertEqual(query.map(\.name), ["profile"])
        XCTAssertEqual(query.map(\.value), ["research"])
        XCTAssertTrue(WebCacheConfigurationRequest.query(profile: nil).isEmpty)

        let body = WebCacheConfigurationRequest.body(
            leaf: .cacheTTLMinutes, value: .number(12.5), profile: "research")

        XCTAssertEqual(body, .object([
            "config": .object([
                "web": .object(["cache_ttl_minutes": .number(12.5)]),
            ]),
            "profile": .string("research"),
        ]))

        let snapshot = WebCacheConfigurationRequest.body(
            leaf: .snapshotThreshold, value: .number(30_000), profile: nil)
        XCTAssertEqual(snapshot, .object([
            "config": .object([
                "browser": .object(["snapshot_threshold": .number(30_000)]),
            ]),
        ]))
    }

    func testManagedLeafSetHasNoAuxiliaryWebExtractPath() {
        let leaves = Set(WebCacheManagedLeaf.allCases.map { "\($0.section).\($0.key)" })
        XCTAssertEqual(leaves, [
            "web.cache_enabled",
            "web.cache_ttl_minutes",
            "web.cache_exempt_hosts",
            "browser.snapshot_threshold",
        ])
    }

    func testOmittedLeavesUseExactHermesDefaultsButExplicitNullStaysRaw() {
        let defaults = WebCacheConfiguration(["web": [:], "browser": [:]])
        XCTAssertEqual(defaults.cacheEnabled.value, true)
        XCTAssertEqual(defaults.cacheTTLMinutes.value, 20)
        XCTAssertEqual(defaults.cacheExemptHosts.values, [])
        XCTAssertEqual(defaults.snapshotThreshold.value, 15_000)

        let explicitNulls = WebCacheConfiguration([
            "web": [
                "cache_enabled": JSONValue.null,
                "cache_ttl_minutes": JSONValue.null,
                "cache_exempt_hosts": JSONValue.null,
            ],
            "browser": ["snapshot_threshold": JSONValue.null],
        ])
        XCTAssertFalse(explicitNulls.cacheEnabled.isManaged)
        XCTAssertFalse(explicitNulls.cacheTTLMinutes.isManaged)
        XCTAssertFalse(explicitNulls.cacheExemptHosts.isManaged)
        XCTAssertFalse(explicitNulls.snapshotThreshold.isManaged)
    }

    func testTypedProjectionRetainsUnknownWebAndBrowserSiblingsAcrossLeafUpdate() {
        let response: JSONValue = [
            "web": [
                "cache_enabled": true,
                "cache_ttl_minutes": 12.5,
                "cache_exempt_hosts": ["MYSITE.VERCEL.APP", "*.ngrok-free.app",
                                       "MYSITE.VERCEL.APP"],
                "future_cache_metadata": ["cached": true, "version": 7],
            ],
            "browser": [
                "snapshot_threshold": 30_000,
                "future_browser_mode": ["enabled": true],
            ],
        ]
        var configuration = WebCacheConfiguration(response)

        XCTAssertEqual(configuration.cacheEnabled.value, true)
        XCTAssertEqual(configuration.cacheTTLMinutes.value, 12.5)
        XCTAssertEqual(configuration.cacheExemptHosts.values,
                       ["MYSITE.VERCEL.APP", "*.ngrok-free.app", "MYSITE.VERCEL.APP"])
        XCTAssertEqual(configuration.snapshotThreshold.value, 30_000)

        configuration.apply(cacheTTLMinutes: 60)
        configuration.apply(snapshotThreshold: 45_000)

        XCTAssertEqual(configuration.rawWeb?.objectValue?["future_cache_metadata"],
                       .object(["cached": true, "version": 7]))
        XCTAssertEqual(configuration.rawBrowser?.objectValue?["future_browser_mode"],
                       .object(["enabled": true]))
        XCTAssertEqual(configuration.rawWeb?.objectValue?["cache_exempt_hosts"],
                       .array(["MYSITE.VERCEL.APP", "*.ngrok-free.app", "MYSITE.VERCEL.APP"]))
    }

    func testHermesTTLBoundsAndBrowserMinimumAreRepresentedWithoutCoercion() {
        XCTAssertEqual(WebCacheTTLMinutesValue(rawValue: .number(1)).value, 1)
        XCTAssertEqual(WebCacheTTLMinutesValue(rawValue: .number(1_440)).value, 1_440)
        XCTAssertNil(WebCacheTTLMinutesValue(rawValue: .number(0)).value)
        XCTAssertNil(WebCacheTTLMinutesValue(rawValue: .number(1_441)).value)
        XCTAssertEqual(WebCacheTTLMinutesValue.parseEditorValue("1.25"), 1.25)
        XCTAssertNil(WebCacheTTLMinutesValue.parseEditorValue(" 20"))

        XCTAssertEqual(BrowserSnapshotThresholdValue(rawValue: .number(1_000)).value, 1_000)
        // Hermes has no source-level upper clamp; this proves Talaria does not
        // incorrectly reuse the cache TTL's 1,440-minute ceiling for snapshots.
        XCTAssertEqual(BrowserSnapshotThresholdValue(rawValue: .number(2_000_001)).value,
                       2_000_001)
        XCTAssertNil(BrowserSnapshotThresholdValue(rawValue: .number(999)).value)
        XCTAssertNil(BrowserSnapshotThresholdValue(rawValue: .number(1_000.5)).value)
        XCTAssertEqual(BrowserSnapshotThresholdValue.parseEditorValue("30000"), 30_000)
        XCTAssertNil(BrowserSnapshotThresholdValue.parseEditorValue("1000.5"))
    }

    func testHostGlobListIsLosslessAndConservativelyValidated() {
        let hosts = ["MYSITE.VERCEL.APP", "*.ngrok-free.app", "preview.mysite.dev",
                     "MYSITE.VERCEL.APP"]
        let value = WebCacheExemptHostsValue(rawValue: .array(hosts.map(JSONValue.string)))

        XCTAssertEqual(value.values, hosts)
        XCTAssertEqual(WebCacheHostPattern.editorValues(hosts.joined(separator: "\n")), hosts)
        XCTAssertTrue(WebCacheHostPattern.isSafe("*.ngrok-free.app"))
        XCTAssertTrue(WebCacheHostPattern.isSafe("MYSITE.VERCEL.APP"))
        XCTAssertFalse(WebCacheHostPattern.isSafe("https://mysite.vercel.app"))
        XCTAssertFalse(WebCacheHostPattern.isSafe("mysite.vercel.app:443"))
        XCTAssertFalse(WebCacheHostPattern.isSafe("*.bad*glob.example"))
        XCTAssertFalse(WebCacheHostPattern.isSafe(" mysite.vercel.app"))
        XCTAssertNil(WebCacheHostPattern.editorValues("mysite.vercel.app\n"))
    }

    func testRawTargetedValuesRemainNonActionableForTheUI() {
        var configuration = WebCacheConfiguration([
            "web": [
                "cache_enabled": "false",
                "cache_ttl_minutes": "20",
                "cache_exempt_hosts": ["mysite.vercel.app", "https://unmanaged.example"],
            ],
            "browser": ["snapshot_threshold": 999.5],
        ])

        XCTAssertFalse(configuration.cacheEnabled.isManaged)
        XCTAssertFalse(configuration.cacheTTLMinutes.isManaged)
        XCTAssertFalse(configuration.cacheExemptHosts.isManaged)
        XCTAssertFalse(configuration.snapshotThreshold.isManaged)
        XCTAssertEqual(configuration.rawWeb?.objectValue?["cache_enabled"], .string("false"))
        XCTAssertEqual(configuration.rawBrowser?.objectValue?["snapshot_threshold"], .number(999.5))

        // The model's update helpers themselves decline to rewrite an opaque
        // target. This remains true even if a future caller bypasses the UI's
        // visible-control guard.
        configuration.apply(cacheEnabled: true)
        configuration.apply(cacheTTLMinutes: 30)
        configuration.apply(cacheExemptHosts: ["safe.example"])
        configuration.apply(snapshotThreshold: 30_000)
        XCTAssertEqual(configuration.rawWeb?.objectValue?["cache_enabled"], .string("false"))
        XCTAssertEqual(configuration.rawWeb?.objectValue?["cache_ttl_minutes"], .string("20"))
        XCTAssertEqual(configuration.rawBrowser?.objectValue?["snapshot_threshold"], .number(999.5))
    }

    func testSourceProfileAndGenerationFenceRejectsStaleUICompletion() {
        let captured = WebCacheSettingsScope(gatewayID: "gateway-a", profile: "research",
                                             generation: 8)
        XCTAssertTrue(WebCacheSettingsScopeFence.accepts(current: captured, captured: captured))
        XCTAssertFalse(WebCacheSettingsScopeFence.accepts(
            current: WebCacheSettingsScope(gatewayID: "gateway-b", profile: "research",
                                            generation: 8), captured: captured))
        XCTAssertFalse(WebCacheSettingsScopeFence.accepts(
            current: WebCacheSettingsScope(gatewayID: "gateway-a", profile: "other",
                                            generation: 8), captured: captured))
        XCTAssertFalse(WebCacheSettingsScopeFence.accepts(
            current: WebCacheSettingsScope(gatewayID: "gateway-a", profile: "research",
                                            generation: 9), captured: captured))
    }
}
