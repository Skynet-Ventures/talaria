import Foundation

/// One host-agnostic post-boot WebSocket reconnect delay.
public struct PostBootReconnectDelay: Sendable, Equatable {
    /// Nonnegative attempt used to choose the exponential ceiling.
    public let attempt: Int
    public let ceiling: TimeInterval
    /// Full-jitter selection in `[0, ceiling)`.
    public let delay: TimeInterval

    init(attempt: Int, ceiling: TimeInterval, delay: TimeInterval) {
        self.attempt = attempt
        self.ceiling = ceiling
        self.delay = delay
    }
}

/// Events which start a fresh post-boot reconnect episode.
public enum PostBootReconnectResetReason: Sendable, Equatable {
    case cleanOpen
    case manualWake
}

/// Reset value for lifecycle-owned reconnect counters and elapsed time.
public struct PostBootReconnectEpisode: Sendable, Equatable {
    public let attempt: Int
    public let elapsed: TimeInterval

    init(attempt: Int, elapsed: TimeInterval) {
        self.attempt = attempt
        self.elapsed = elapsed
    }
}

/// Pure current-Hermes post-boot reconnect policy. Unlike managed-cloud boot
/// recovery, this policy has no host requirement and no retry-count limit.
public enum PostBootReconnectPolicy {
    public static let baseDelay: TimeInterval = 0.3
    public static let maximumDelay: TimeInterval = 15
    public static let recoveryEscalationThreshold: TimeInterval = 45
    /// Ready bound for a redial, not the first user-tapped connect.
    /// Device journal (`Gateway unreachable`) plus a 15s `connect()` looks
    /// like a 20s freeze when the phone cannot complete TCP to Mini.
    /// A shorter ready wait makes each try visible and the next try start.
    public static let redialReadyTimeout: TimeInterval = 5

    /// Full-jitter delay for an indefinitely available reconnect attempt.
    /// Negative attempts safely normalize to the first retry; very large
    /// attempts take the capped path without exponentiation or overflow.
    public static func delay(attempt: Int, randomUnit: Double) -> PostBootReconnectDelay {
        let safeAttempt = max(0, attempt)
        let ceiling: TimeInterval
        if safeAttempt >= 6 {
            ceiling = maximumDelay
        } else {
            ceiling = min(maximumDelay, baseDelay * Double(1 << safeAttempt))
        }

        let unit: Double
        if randomUnit.isNaN || randomUnit <= 0 {
            unit = 0
        } else if !randomUnit.isFinite || randomUnit >= 1 {
            unit = 1.nextDown
        } else {
            unit = randomUnit
        }
        return PostBootReconnectDelay(
            attempt: safeAttempt, ceiling: ceiling, delay: unit * ceiling)
    }

    /// Hermes escalates recovery based on elapsed episode time, not attempts.
    public static func shouldEscalateRecovery(elapsed: TimeInterval) -> Bool {
        guard elapsed.isFinite || elapsed == .infinity else { return false }
        return elapsed >= recoveryEscalationThreshold
    }

    /// Both a clean socket open and an explicit manual wake begin a fresh
    /// episode. The reason stays explicit so lifecycle call sites remain
    /// auditable even though their reset value is identical.
    public static func resetEpisode(for reason: PostBootReconnectResetReason)
        -> PostBootReconnectEpisode {
        switch reason {
        case .cleanOpen, .manualWake:
            PostBootReconnectEpisode(attempt: 0, elapsed: 0)
        }
    }
}
