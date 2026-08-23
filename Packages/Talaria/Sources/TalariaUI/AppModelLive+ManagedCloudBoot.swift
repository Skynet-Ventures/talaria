import Foundation
import Observation
import TalariaKit

/// Internal control-flow evidence that an exact managed-cloud boot episode no
/// longer owns the captured generation, source, and gateway route. Keep this
/// distinct from caller cancellation: only proven supersession is safe for a
/// stale launch/switch caller to ignore without publishing offline state.
struct ManagedCloudBootSupersededError: Error {}

enum ManagedCloudBootTaskContext {
    @TaskLocal static var episode: ManagedCloudBootRuntime.Episode?
}

/// Terminal evidence from one exhausted pre-WebSocket managed-cloud boot
/// episode. Only the safe origin and structured HTTP status are retained;
/// response prose and bodies never enter observable UI state.
public struct ManagedCloudBootOutage: Sendable, Equatable {
    public let gatewayID: String
    public let sourceOrigin: String
    public let host: String
    public let statusCode: Int
    public let attempts: Int
    public let attemptsExhausted: Bool

    init(gatewayID: String, sourceOrigin: String, host: String,
         statusCode: Int, attempts: Int, attemptsExhausted: Bool) {
        self.gatewayID = gatewayID
        self.sourceOrigin = sourceOrigin
        self.host = host
        self.statusCode = statusCode
        self.attempts = attempts
        self.attemptsExhausted = attemptsExhausted
    }
}

@MainActor
@Observable
final class ManagedCloudBootRuntime {
    typealias Sleep = @MainActor (TimeInterval) async throws -> Void
    typealias RandomUnit = @MainActor () -> Double

    struct Episode: Equatable, Sendable {
        let token: UUID
        let generation: UInt64
        let sourceURL: URL
        let gatewayID: String
    }

    static let shared = ManagedCloudBootRuntime()

    var outage: ManagedCloudBootOutage?
    @ObservationIgnored var active: Episode?
    @ObservationIgnored var generation: UInt64 = 0
    @ObservationIgnored var sleep: Sleep = ManagedCloudBootRuntime.productionSleep
    @ObservationIgnored var randomUnit: RandomUnit = { Double.random(in: 0..<1) }

    private static let productionSleep: Sleep = { delay in
        guard delay > 0 else {
            await Task.yield()
            try Task.checkCancellation()
            return
        }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    func begin(sourceURL: URL, gatewayID: String) -> Episode {
        generation &+= 1
        let episode = Episode(token: UUID(), generation: generation,
                              sourceURL: sourceURL, gatewayID: gatewayID)
        active = episode
        outage = nil
        return episode
    }

    func invalidate(gatewayID: String? = nil) {
        if let gatewayID, active?.gatewayID != gatewayID,
           outage?.gatewayID != gatewayID { return }
        generation &+= 1
        active = nil
        outage = nil
    }

    func resetForTesting() {
        invalidate()
        sleep = Self.productionSleep
        randomUnit = { Double.random(in: 0..<1) }
    }

    func owns(_ episode: Episode) -> Bool {
        active == episode && generation == episode.generation
    }

    func retireIfOwned(_ episode: Episode) {
        guard owns(episode) else { return }
        active = nil
    }
}

extension AppModel {
    /// The current terminal managed-cloud pre-WebSocket outage, if the exact
    /// episode exhausted its bounded retry budget. This state is in-memory
    /// only and is cleared by success, invalidation, or a new explicit boot.
    public var managedCloudBootOutage: ManagedCloudBootOutage? {
        ManagedCloudBootRuntime.shared.outage
    }

    /// Run one exact pre-WebSocket boot operation for one captured source.
    /// The caller owns launch/source-switch selection and any later reconnect;
    /// this coordinator never reads or chooses another gateway. The operation
    /// must also fence any state it publishes internally against its captured
    /// source; this coordinator can suppress only its own stale completion.
    ///
    /// Only structured 502/503/504 failures from a strict managed-agent URL
    /// receive five full-jitter retries after the initial attempt. All other
    /// errors are returned immediately. Superseded episodes throw
    /// `ManagedCloudBootSupersededError`; caller cancellation remains
    /// `CancellationError`. Neither publishes terminal outage state.
    public func runManagedCloudBootEpisode(
        sourceURL: URL,
        gatewayID: String,
        operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        let runtime = ManagedCloudBootRuntime.shared
        let episode = runtime.begin(sourceURL: sourceURL, gatewayID: gatewayID)
        var attempts = 0

        while true {
            try requireManagedCloudBootOwnership(episode, runtime: runtime)
            do {
                attempts += 1
                try await ManagedCloudBootTaskContext.$episode.withValue(episode) {
                    try await operation()
                }
                try requireManagedCloudBootOwnership(episode, runtime: runtime)
                runtime.outage = nil
                runtime.active = nil
                return
            } catch {
                if error is CancellationError || Task.isCancelled {
                    guard runtime.owns(episode) else {
                        throw ManagedCloudBootSupersededError()
                    }
                    runtime.retireIfOwned(episode)
                    throw CancellationError()
                }
                try requireManagedCloudBootOwnership(episode, runtime: runtime)

                guard let http = error as? GatewayHTTPError,
                      let serverDown = ManagedCloudAvailabilityPolicy.preWebSocketServerDown(
                          url: episode.sourceURL, statusCode: http.statusCode)
                else {
                    runtime.retireIfOwned(episode)
                    throw error
                }

                let retryIndex = attempts - 1
                guard retryIndex < ManagedCloudAvailabilityPolicy.maximumAutomaticRetries,
                      let retry = ManagedCloudAvailabilityPolicy.bootRetry(
                          attempt: retryIndex, randomUnit: runtime.randomUnit())
                else {
                    runtime.outage = ManagedCloudBootOutage(
                        gatewayID: episode.gatewayID,
                        sourceOrigin: Self.safeManagedCloudOrigin(episode.sourceURL),
                        host: serverDown.host,
                        statusCode: serverDown.statusCode,
                        attempts: attempts,
                        attemptsExhausted: true
                    )
                    runtime.active = nil
                    throw error
                }

                try requireManagedCloudBootOwnership(episode, runtime: runtime)
                do {
                    try await runtime.sleep(retry.delay)
                } catch {
                    runtime.retireIfOwned(episode)
                    if error is CancellationError || Task.isCancelled {
                        throw CancellationError()
                    }
                    throw error
                }
                try requireManagedCloudBootOwnership(episode, runtime: runtime)
            }
        }
    }

    /// Explicitly invalidate the currently owned boot episode. Any suspended
    /// operation may finish remotely, but its completion can no longer publish
    /// success or outage state through this coordinator.
    public func invalidateManagedCloudBootEpisode(gatewayID: String? = nil) {
        ManagedCloudBootRuntime.shared.invalidate(gatewayID: gatewayID)
    }

    /// A connection transition nested inside the exact boot episode retains
    /// that episode. Any other transition proves a newer task/token/source
    /// owns connection selection and invalidates the stale boot before either
    /// caller can publish global health.
    func invalidateManagedCloudBootEpisodeUnlessOwnedByCurrentTask(sourceURL: URL) {
        let runtime = ManagedCloudBootRuntime.shared
        guard let active = runtime.active else { return }
        guard ManagedCloudBootTaskContext.episode == active,
              active.sourceURL == sourceURL else {
            runtime.invalidate()
            return
        }
    }

    private func requireManagedCloudBootOwnership(
        _ episode: ManagedCloudBootRuntime.Episode,
        runtime: ManagedCloudBootRuntime
    ) throws {
        try Task.checkCancellation()
        guard runtime.owns(episode) else { throw ManagedCloudBootSupersededError() }
    }

    static func safeManagedCloudOrigin(_ sourceURL: URL) -> String {
        guard var components = URLComponents(
            url: sourceURL, resolvingAgainstBaseURL: false),
              let host = sourceURL.host?.lowercased() else { return "" }
        components.user = nil
        components.password = nil
        components.host = host
        components.path = ""
        components.query = nil
        components.fragment = nil
        if let origin = components.url?.absoluteString {
            return origin.hasSuffix("/") ? String(origin.dropLast()) : origin
        }
        return host
    }
}
