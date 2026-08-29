import Foundation

/// Bounded wall-clock policy for Hermes' live whole-turn timer.
///
/// Hermes reports `turn_started_at` as epoch seconds on `session.info` and
/// `session.resume`. Completed transcript rows do not carry a duration, so a
/// duration exists only when this process observed a local/live start.
public enum TurnElapsedTimingPolicy {
    /// Gateway recovery expires abandoned active turns far sooner than this.
    /// The larger display bound tolerates long legitimate work while keeping
    /// hostile or corrupt epoch values from creating an unbounded counter.
    public static let maximumDurationSeconds = 7 * 24 * 60 * 60
    public static let maximumFutureSkewSeconds: TimeInterval = 300

    public static func admittedEpochSeconds(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0,
              value <= Date.distantFuture.timeIntervalSince1970 else { return nil }
        return value
    }

    public static func admittedStartDate(
        epochSeconds: Double?, now: Date = Date()
    ) -> Date? {
        guard let epochSeconds = admittedEpochSeconds(epochSeconds) else { return nil }
        let start = Date(timeIntervalSince1970: epochSeconds)
        let age = now.timeIntervalSince(start)
        guard age >= -maximumFutureSkewSeconds,
              age <= TimeInterval(maximumDurationSeconds) else { return nil }
        return start
    }

    /// Live labels floor to whole seconds, matching Hermes Desktop. A small
    /// future skew reads as zero instead of a negative timer.
    public static func liveSeconds(startedAt: Date, now: Date = Date()) -> Int {
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        return min(maximumDurationSeconds, Int(elapsed.rounded(.down)))
    }

    /// Terminal durations round to the nearest second and have a one-second
    /// minimum, matching Desktop's settled `durationS` footer. A start later
    /// than the allowed clock-skew window is not credible completion evidence.
    public static func settledSeconds(startedAt: Date, completedAt: Date = Date()) -> Int? {
        let elapsed = completedAt.timeIntervalSince(startedAt)
        guard elapsed >= -maximumFutureSkewSeconds,
              elapsed <= TimeInterval(maximumDurationSeconds) else { return nil }
        return min(maximumDurationSeconds, max(1, Int(elapsed.rounded())))
    }

    public static func formatted(seconds: Int) -> String {
        let bounded = min(max(0, seconds), maximumDurationSeconds)
        if bounded < 60 { return "\(bounded)s" }
        return "\(bounded / 60):\(String(format: "%02d", bounded % 60))"
    }
}
