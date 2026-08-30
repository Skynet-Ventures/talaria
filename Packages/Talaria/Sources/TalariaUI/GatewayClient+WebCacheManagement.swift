import Foundation
import TalariaKit

// Hermes' web-result-cache and browser-snapshot controls are ordinary
// profile-scoped config leaves.  This file deliberately stays on the existing
// authenticated GET/PUT /api/config surface rather than inventing a mobile
// RPC.  The contract below was read from Hermes 1bbb6e5:
//
//   tools/web_result_cache.py
//     web.cache_enabled       bool; missing means true
//     web.cache_ttl_minutes   float, clamped 1...1440
//     web.cache_exempt_hosts  exact / suffix / *. host patterns
//   tools/browser_tool.py
//     browser.snapshot_threshold integer, minimum 1000 (no source ceiling)
//   hermes_cli/web_server.py
//     GET /api/config?profile=... and deep-merge PUT /api/config
//
// A configuration response is intentionally retained as JSON where Hermes has
// no narrow schema.  A string such as `cache_enabled: "false"`, an out-of-
// range number, or a malformed host list must not be "helpfully" coerced and
// written back by a phone UI.  Only values the UI can represent losslessly are
// actionable; all other targeted values remain raw and read-only.

enum WebCacheManagedLeaf: CaseIterable, Sendable {
    case cacheEnabled
    case cacheTTLMinutes
    case cacheExemptHosts
    case snapshotThreshold

    var section: String {
        switch self {
        case .cacheEnabled, .cacheTTLMinutes, .cacheExemptHosts: "web"
        case .snapshotThreshold: "browser"
        }
    }

    var key: String {
        switch self {
        case .cacheEnabled: "cache_enabled"
        case .cacheTTLMinutes: "cache_ttl_minutes"
        case .cacheExemptHosts: "cache_exempt_hosts"
        case .snapshotThreshold: "snapshot_threshold"
        }
    }
}

enum WebCacheBooleanValue: Equatable, Sendable {
    case managed(Bool)
    case raw(JSONValue?)

    init(rawValue: JSONValue?) {
        guard let rawValue else {
            self = .managed(true)
            return
        }
        if let value = rawValue.boolValue {
            self = .managed(value)
        } else {
            self = .raw(rawValue)
        }
    }

    var value: Bool? {
        if case .managed(let value) = self { return value }
        return nil
    }

    var isManaged: Bool { value != nil }
}

enum WebCacheTTLMinutesValue: Equatable, Sendable {
    static let minimum = 1.0
    static let maximum = 1_440.0
    static let defaultValue = 20.0

    case managed(Double)
    case raw(JSONValue?)

    init(rawValue: JSONValue?) {
        guard let rawValue else {
            self = .managed(Self.defaultValue)
            return
        }
        guard let value = rawValue.doubleValue,
              value.isFinite,
              (Self.minimum...Self.maximum).contains(value) else {
            self = .raw(rawValue)
            return
        }
        self = .managed(value)
    }

    var value: Double? {
        if case .managed(let value) = self { return value }
        return nil
    }

    var isManaged: Bool { value != nil }

    /// Hermes accepts a float and clamps it at runtime.  Talaria only sends a
    /// canonical in-range, finite number; it never changes an existing raw
    /// out-of-range/string value merely because Hermes would clamp it.
    static func parseEditorValue(_ raw: String) -> Double? {
        guard raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Double(raw), value.isFinite,
              (Self.minimum...Self.maximum).contains(value) else { return nil }
        return value
    }

    static func editorText(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}

enum BrowserSnapshotThresholdValue: Equatable, Sendable {
    /// Hermes' only source-level constraint is this lower bound
    /// (`max(int(value), 1000)`).  It intentionally has no configuration
    /// ceiling; the wire guard below is only the largest integer JSONValue can
    /// carry exactly from Swift's Double-backed representation.
    static let minimum = 1_000
    static let defaultValue = 15_000
    static let maximumExactlyRepresentableOnWire = 9_007_199_254_740_991

    case managed(Int)
    case raw(JSONValue?)

    init(rawValue: JSONValue?) {
        guard let rawValue else {
            self = .managed(Self.defaultValue)
            return
        }
        guard let value = rawValue.doubleValue,
              value.isFinite,
              value.rounded(.towardZero) == value,
              value >= Double(Self.minimum),
              value <= Double(Self.maximumExactlyRepresentableOnWire) else {
            self = .raw(rawValue)
            return
        }
        self = .managed(Int(value))
    }

    var value: Int? {
        if case .managed(let value) = self { return value }
        return nil
    }

    var isManaged: Bool { value != nil }

    static func parseEditorValue(_ raw: String) -> Int? {
        guard raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Int(raw),
              value >= minimum,
              value <= maximumExactlyRepresentableOnWire else { return nil }
        return value
    }
}

/// Conservative editor validation for the *host/glob* subset that Hermes'
/// cache matcher understands.  Existing entries are never normalized: case,
/// order, and duplicates survive a read/edit/save round trip exactly.
enum WebCacheHostPattern {
    static let maximumEntries = 64
    static let maximumScalars = 253

    static func isSafe(_ raw: String) -> Bool {
        guard !raw.isEmpty,
              raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.unicodeScalars.count <= maximumScalars else { return false }

        var host = raw
        if host.hasPrefix("*.") {
            host.removeFirst(2)
        }
        // Hermes supports only the leading `*.` wildcard.  A URL, port, path,
        // bare star, or any other glob expression must stay out of this small
        // mobile editor; an already-saved one is preserved as opaque config.
        guard !host.isEmpty, !host.contains("*"), !host.contains(":"),
              !host.contains("/"), !host.contains("?"), !host.contains("#") else {
            return false
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        for label in labels {
            let scalars = Array(label.unicodeScalars)
            guard !scalars.isEmpty, scalars.count <= 63,
                  let first = scalars.first, let last = scalars.last,
                  isAlphaNumeric(first), isAlphaNumeric(last),
                  scalars.allSatisfy({ isAlphaNumeric($0) || $0.value == 45 }) else {
                return false
            }
        }
        return true
    }

    /// TextEditor uses one newline-delimited entry per line.  The individual
    /// values are constrained not to contain a newline, so this is lossless for
    /// every editable list.  No trimming, lowercasing, sorting, or dedupe.
    static func editorValues(_ text: String) -> [String]? {
        if text.isEmpty { return [] }
        let values = text.components(separatedBy: "\n")
        guard values.count <= maximumEntries, values.allSatisfy(isSafe) else { return nil }
        return values
    }

    private static func isAlphaNumeric(_ scalar: UnicodeScalar) -> Bool {
        (48...57).contains(scalar.value)
            || (65...90).contains(scalar.value)
            || (97...122).contains(scalar.value)
    }
}

enum WebCacheExemptHostsValue: Equatable, Sendable {
    case managed([String])
    case raw(JSONValue?)

    init(rawValue: JSONValue?) {
        guard let rawValue else {
            self = .managed([])
            return
        }
        guard let values = rawValue.arrayValue,
              values.count <= WebCacheHostPattern.maximumEntries else {
            self = .raw(rawValue)
            return
        }
        var hosts: [String] = []
        hosts.reserveCapacity(values.count)
        for value in values {
            guard let host = value.stringValue, WebCacheHostPattern.isSafe(host) else {
                self = .raw(rawValue)
                return
            }
            hosts.append(host)
        }
        self = .managed(hosts)
    }

    var values: [String]? {
        if case .managed(let values) = self { return values }
        return nil
    }

    var isManaged: Bool { values != nil }
}

/// Typed, loss-preserving projection of exactly the four supported leaves.
/// `rawWeb` and `rawBrowser` retain every sibling received from Hermes so the
/// caller can prove local updates do not erase newer/unknown configuration.
struct WebCacheConfiguration: Equatable, Sendable {
    private(set) var rawWeb: JSONValue?
    private(set) var rawBrowser: JSONValue?
    private(set) var cacheEnabled: WebCacheBooleanValue
    private(set) var cacheTTLMinutes: WebCacheTTLMinutesValue
    private(set) var cacheExemptHosts: WebCacheExemptHostsValue
    private(set) var snapshotThreshold: BrowserSnapshotThresholdValue

    init(_ response: JSONValue) {
        rawWeb = response["web"]
        rawBrowser = response["browser"]
        let web = rawWeb?.objectValue
        let browser = rawBrowser?.objectValue
        cacheEnabled = WebCacheBooleanValue(rawValue: web?["cache_enabled"])
        cacheTTLMinutes = WebCacheTTLMinutesValue(rawValue: web?["cache_ttl_minutes"])
        cacheExemptHosts = WebCacheExemptHostsValue(rawValue: web?["cache_exempt_hosts"])
        snapshotThreshold = BrowserSnapshotThresholdValue(rawValue: browser?["snapshot_threshold"])
    }

    mutating func apply(cacheEnabled value: Bool) {
        guard cacheEnabled.isManaged, var web = rawWeb?.objectValue else { return }
        web[WebCacheManagedLeaf.cacheEnabled.key] = .bool(value)
        rawWeb = .object(web)
        cacheEnabled = .managed(value)
    }

    mutating func apply(cacheTTLMinutes value: Double) {
        guard cacheTTLMinutes.isManaged, var web = rawWeb?.objectValue else { return }
        web[WebCacheManagedLeaf.cacheTTLMinutes.key] = .number(value)
        rawWeb = .object(web)
        cacheTTLMinutes = .managed(value)
    }

    mutating func apply(cacheExemptHosts values: [String]) {
        guard cacheExemptHosts.isManaged, var web = rawWeb?.objectValue else { return }
        web[WebCacheManagedLeaf.cacheExemptHosts.key] = .array(values.map(JSONValue.string))
        rawWeb = .object(web)
        cacheExemptHosts = .managed(values)
    }

    mutating func apply(snapshotThreshold value: Int) {
        guard snapshotThreshold.isManaged, var browser = rawBrowser?.objectValue else { return }
        browser[WebCacheManagedLeaf.snapshotThreshold.key] = .number(Double(value))
        rawBrowser = .object(browser)
        snapshotThreshold = .managed(value)
    }
}

/// Request construction is deliberately narrow.  `/api/config` deep-merges
/// this one leaf over the selected profile's on-disk document, preserving every
/// other web/browser key (including keys a later Hermes release adds).
enum WebCacheConfigurationRequest {
    static func query(profile: String?) -> [URLQueryItem] {
        guard let profile, !profile.isEmpty else { return [] }
        return [URLQueryItem(name: "profile", value: profile)]
    }

    static func body(leaf: WebCacheManagedLeaf, value: JSONValue,
                     profile: String?) -> JSONValue {
        let patch: JSONValue = .object([leaf.section: .object([leaf.key: value])])
        var body: [String: JSONValue] = ["config": patch]
        if let profile, !profile.isEmpty { body["profile"] = .string(profile) }
        return .object(body)
    }
}

extension GatewayClient {
    func webCacheConfiguration(profile: String?) async throws -> WebCacheConfiguration {
        WebCacheConfiguration(
            try await restJSON(path: "api/config", query: WebCacheConfigurationRequest.query(profile: profile),
                               timeout: 30))
    }

    func setWebCacheEnabled(_ value: Bool, profile: String?) async throws {
        try await writeWebCacheConfiguration(.cacheEnabled, value: .bool(value), profile: profile)
    }

    func setWebCacheTTLMinutes(_ value: Double, profile: String?) async throws {
        try await writeWebCacheConfiguration(.cacheTTLMinutes, value: .number(value), profile: profile)
    }

    func setWebCacheExemptHosts(_ values: [String], profile: String?) async throws {
        try await writeWebCacheConfiguration(
            .cacheExemptHosts, value: .array(values.map(JSONValue.string)), profile: profile)
    }

    func setBrowserSnapshotThreshold(_ value: Int, profile: String?) async throws {
        try await writeWebCacheConfiguration(
            .snapshotThreshold, value: .number(Double(value)), profile: profile)
    }

    private func writeWebCacheConfiguration(_ leaf: WebCacheManagedLeaf, value: JSONValue,
                                            profile: String?) async throws {
        let receipt = try await restJSON(
            path: "api/config", method: "PUT",
            body: WebCacheConfigurationRequest.body(leaf: leaf, value: value, profile: profile),
            timeout: 30)
        try GatewayOperationsPolicy.requireOKReceipt(receipt,
                                                      operation: "Update web cache configuration")
    }

}
