import Foundation

/// Result of proving the current WebSocket after iOS resumes the process.
/// A local lifecycle traffic fence is deliberately not a link failure: the
/// fence is profile-mutation authority and must never start reconnect around
/// an in-flight rename/delete.
public enum ForegroundSocketLiveness: Sendable, Equatable {
    case healthy
    case reconnectRequired
    case trafficFenced
}

/// Pure wake-time socket verdict. URLSessionWebSocketTask often still reports
/// `.ready` after iOS has parked a half-open link; only a bounded RPC (or a
/// JSON-RPC error that still crossed the wire) proves the socket survived.
public enum ForegroundSocketPolicy {
    public static let pingTimeout: TimeInterval = 3
    /// JSON-RPC "Method not found" — older Hermes has no `gateway.ping`, but
    /// the error frame still proves the transport is alive.
    public static let methodNotFound = -32601

    /// Classify an already-attempted (or skipped) foreground ping.
    public static func outcome(
        transportReady: Bool,
        result: Result<JSONValue, Error>
    ) -> ForegroundSocketLiveness {
        guard transportReady else { return .reconnectRequired }
        switch result {
        case .success(let value):
            guard value.objectValue?["ok"]?.boolValue == true else {
                return .reconnectRequired
            }
            return .healthy
        case .failure(let error):
            if let gateway = error as? GatewayError {
                if gateway.code == GatewayClient.trafficFenced { return .trafficFenced }
                if gateway.code == methodNotFound { return .healthy }
            }
            return .reconnectRequired
        }
    }
}
