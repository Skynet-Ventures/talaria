import Foundation
import Network
import Observation

// The OS's view of the network path, reduced to the one question the reconnect
// ladder needs answered: "did the route just become usable again?"
//
// Why this exists at all: Talaria's reconnect is an exponential backoff capped
// at 15 s (AppModelLive+Reconnect.swift `scheduleSupervisedReconnect`). That
// ladder is correct for a gateway that is down, and wrong for a phone that
// walked out of a dead zone — the route came
// back in the first second and the user still waits out the sleep. Desktop
// hangs the same nudge off the browser's `online` event
// (app/gateway/hooks/use-gateway-boot.ts:547); NWPathMonitor is the iOS twin.
//
// Two things this deliberately does NOT do:
//   - it never dials, and never touches AppModel state. It reports a settled
//     path change and the caller decides. A monitor that reconnects on its own
//     would race the source-qualified supervised backoff loop.
//   - it never treats `.satisfied` as "the gateway is reachable". A satisfied
//     path to a captive-portal Wi-Fi is satisfied; only the dial itself knows.

/// A path reduced to two comparable scalars. Both halves matter: a
/// Wi-Fi→cellular handoff never leaves `.satisfied`, yet it kills every open
/// socket — and that is exactly what happens walking out of a building, which
/// is the case a phone hits far more often than a full outage.
public struct NetworkPathState: Sendable, Equatable {
    /// The OS believes traffic can be routed.
    public var isSatisfied: Bool
    /// Preferred interface: "wifi", "cellular", "wired", "other" or "none".
    /// Compared, never displayed — a change here means the sockets are dead
    /// even when `isSatisfied` never wavered.
    public var interface: String

    public init(isSatisfied: Bool, interface: String) {
        self.isSatisfied = isSatisfied
        self.interface = interface
    }
}

/// App-lifetime NWPathMonitor wrapper. One instance; `start` is idempotent.
@MainActor
@Observable
public final class NetworkMonitor {

    public static let shared = NetworkMonitor()

    /// Latest verdict from the OS. Optimistic until the first path update
    /// lands — NWPathMonitor answers asynchronously, and a false "offline" in
    /// that gap would make callers hold back a dial they should make.
    public private(set) var isOnline = true

    /// A handing-off radio flaps through several updates in quick succession;
    /// only the settled path is worth a reconnect. Trailing-edge debounce, so
    /// the burst's last update is the one that counts.
    static let settleDelay: Duration = .milliseconds(750)

    /// Floor between two nudges. A genuinely unstable link (a train, a lift)
    /// must not turn a reconnect into a dial loop; the backoff ladder is still
    /// running underneath and remains the retry of record.
    static let nudgeFloor: Duration = .seconds(5)

    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private let queue = DispatchQueue(label: "wtf.talaria.network-path")
    /// Last path seen. nil until the first update: that update describes the
    /// world as it already was, so it is a baseline and not a transition.
    @ObservationIgnored private var path: NetworkPathState?
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var lastNudge: ContinuousClock.Instant?
    @ObservationIgnored private var onUsablePath: (@MainActor () -> Void)?

    private init() {}

    /// Begin watching. Safe to call repeatedly — the second call only re-points
    /// the callback, so re-arming after a gateway swap costs nothing.
    public func start(onUsablePathChange: @escaping @MainActor () -> Void) {
        onUsablePath = onUsablePathChange
        guard monitor == nil else { return }

        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            // NWPath is reduced to Sendable scalars on the monitor's own queue;
            // the path object itself never crosses the actor hop.
            let next = NetworkPathState(isSatisfied: path.status == .satisfied,
                                        interface: NetworkMonitor.label(for: path))
            Task { @MainActor in self?.apply(next) }
        }
        monitor.start(queue: queue)
    }

    /// Tear the watch down. Only the deliberate teardown path needs this; the
    /// monitor is otherwise app-lifetime and costs nothing while quiet.
    public func stop() {
        settleTask?.cancel()
        settleTask = nil
        monitor?.cancel()
        monitor = nil
        path = nil
        onUsablePath = nil
    }

    // MARK: - Internals

    private func apply(_ next: NetworkPathState) {
        let previous = path
        path = next
        isOnline = next.isSatisfied

        // No previous path = the baseline update, not a transition. An
        // unsatisfied path is the outage itself, not the recovery from one.
        guard let previous, previous != next, next.isSatisfied else { return }
        scheduleNudge()
    }

    private func scheduleNudge() {
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: NetworkMonitor.settleDelay)
            guard !Task.isCancelled, let self, self.isOnline else { return }
            let now = ContinuousClock.now
            if let last = self.lastNudge, now - last < NetworkMonitor.nudgeFloor { return }
            self.lastNudge = now
            self.settleTask = nil
            self.onUsablePath?()
        }
    }

    /// Runs on the monitor queue, so it must stay off the actor.
    /// `usesInterfaceType` is asked in preference order — the first hit is the
    /// interface the route actually prefers.
    private nonisolated static func label(for path: NWPath) -> String {
        guard path.status == .satisfied else { return "none" }
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.cellular) { return "cellular" }
        if path.usesInterfaceType(.wiredEthernet) { return "wired" }
        return "other"
    }
}
