import Foundation

/// Current Hermes' additive application-level heartbeat policy. Older
/// gateways never advertise support, so Talaria leaves their sockets on the
/// existing URLSession/WebSocket lifecycle path.
public struct GatewayHeartbeatPolicy: Sendable, Equatable {
    public static let current = GatewayHeartbeatPolicy(interval: 15, deadline: 45)

    public let interval: TimeInterval
    public let deadline: TimeInterval

    public init(interval: TimeInterval, deadline: TimeInterval) {
        self.interval = interval.isFinite ? max(0, interval) : 0
        self.deadline = deadline.isFinite ? max(0, deadline) : 0
    }

    public var isEnabled: Bool { interval > 0 && deadline > 0 }
}

/// Pure state machine used by `GatewayTransport`. Uptime values are monotonic
/// seconds, never wall-clock dates, so clock changes cannot manufacture a dead
/// socket or keep a half-open generation alive.
struct GatewayHeartbeatState: Sendable, Equatable {
    enum Action: Sendable, Equatable {
        case none
        case send(id: String)
        case invalidate
    }

    let policy: GatewayHeartbeatPolicy
    private(set) var advertised = false
    private(set) var lastInboundAt: TimeInterval = 0
    private(set) var pendingID: String?
    private var sequence: UInt64 = 0

    init(policy: GatewayHeartbeatPolicy) {
        self.policy = policy
    }

    mutating func activate(advertised: Bool, now: TimeInterval) {
        self.advertised = advertised && policy.isEnabled
        lastInboundAt = now
        pendingID = nil
    }

    mutating func recordInbound(responseID: String?, now: TimeInterval) {
        lastInboundAt = now
        if responseID == pendingID { pendingID = nil }
    }

    mutating func tick(now: TimeInterval) -> Action {
        guard advertised else { return .none }
        guard now.isFinite, lastInboundAt.isFinite else { return .invalidate }
        if max(0, now - lastInboundAt) >= policy.deadline { return .invalidate }
        guard pendingID == nil else { return .none }
        sequence &+= 1
        let id = "talaria-heartbeat-\(sequence)"
        pendingID = id
        return .send(id: id)
    }

    mutating func stop() {
        advertised = false
        pendingID = nil
    }
}
