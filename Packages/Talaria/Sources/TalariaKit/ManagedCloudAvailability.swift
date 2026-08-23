import Foundation

/// Exact pre-WebSocket "managed backend is down" evidence. This does not
/// describe a post-boot WebSocket disconnect; reconnect policy remains a
/// separate lifecycle concern.
public struct ManagedCloudServerDown: Sendable, Equatable {
    public let host: String
    public let statusCode: Int

    init(host: String, statusCode: Int) {
        self.host = host
        self.statusCode = statusCode
    }
}

/// One bounded automatic retry after the initial remote-boot failure.
public struct ManagedCloudBootRetry: Sendable, Equatable {
    /// Zero-based retry index. Current Hermes permits exactly `0...4`.
    public let attempt: Int
    /// Exponential ceiling before full jitter is applied.
    public let ceiling: TimeInterval
    /// Selected delay in `[0, ceiling)`.
    public let delay: TimeInterval

    init(attempt: Int, ceiling: TimeInterval, delay: TimeInterval) {
        self.attempt = attempt
        self.ceiling = ceiling
        self.delay = delay
    }
}

/// Pure current-Hermes managed-cloud classification and pre-boot retry policy.
/// It performs no network work and retains no retry state.
public enum ManagedCloudAvailabilityPolicy {
    public static let managedDomain = "agents.nousresearch.com"
    public static let maximumAutomaticRetries = 5
    public static let initialRetryCeiling: TimeInterval = 2
    public static let maximumRetryCeiling: TimeInterval = 15

    /// Hermes-managed agents are strict DNS subdomains of
    /// `agents.nousresearch.com`; the apex itself is not an agent.
    public static func isManagedAgentURL(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil,
              let rawHost = url.host, !rawHost.isEmpty else { return false }
        let host = rawHost.lowercased()
        let suffix = ".\(managedDomain)"
        guard host.hasSuffix(suffix), host.count > suffix.count else { return false }
        return isValidDNSName(host)
    }

    /// Classify only the server-down statuses surfaced before WebSocket boot.
    /// Other HTTP failures and all post-boot disconnects return `nil`.
    public static func preWebSocketServerDown(url: URL, statusCode: Int)
        -> ManagedCloudServerDown? {
        guard isManagedAgentURL(url), isServerDownStatus(statusCode),
              let host = url.host?.lowercased() else { return nil }
        return ManagedCloudServerDown(host: host, statusCode: statusCode)
    }

    public static func isServerDownStatus(_ statusCode: Int) -> Bool {
        statusCode == 502 || statusCode == 503 || statusCode == 504
    }

    /// Return the full-jitter delay for retry `attempt`, where `0` is the
    /// first retry after the initial failure. Five retries are permitted.
    ///
    /// `randomUnit` is injectable for deterministic tests. Values outside the
    /// mathematical `[0, 1)` unit interval are safely normalized: negative or
    /// NaN values become zero, and one/positive infinity clamp just below one.
    public static func bootRetry(attempt: Int, randomUnit: Double)
        -> ManagedCloudBootRetry? {
        guard attempt >= 0, attempt < maximumAutomaticRetries else { return nil }

        // The bounded attempt domain avoids exponent overflow entirely.
        let exponential = initialRetryCeiling * Double(1 << attempt)
        let ceiling = min(maximumRetryCeiling, exponential)
        let unit: Double
        if randomUnit.isNaN || randomUnit <= 0 {
            unit = 0
        } else if !randomUnit.isFinite || randomUnit >= 1 {
            unit = 1.nextDown
        } else {
            unit = randomUnit
        }
        return ManagedCloudBootRetry(
            attempt: attempt, ceiling: ceiling, delay: unit * ceiling)
    }

    private static func isValidDNSName(_ host: String) -> Bool {
        guard host.count <= 253, host.first != ".", host.last != "." else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= 63,
                  label.first != "-", label.last != "-",
                  label.unicodeScalars.allSatisfy({ scalar in
                      scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)
                          || scalar == "-")
                  }) else { return false }
        }
        return true
    }
}
