import Foundation

// JSON-RPC 2.0 over WebSocket against `hermes serve` at /api/ws.
//
// Wire facts (tui_gateway/ws.py, hermes_cli/web_server.py):
// - One JSON object per WS text frame, both directions.
// - Client requests: {"jsonrpc":"2.0","id":…,"method":…,"params":{…}}.
// - Server: responses ({id, result|error}) and events
//   ({"method":"event","params":{type, session_id, payload}}).
// - Pooled handlers respond OUT OF ORDER — correlate strictly by id.
// - Streaming deltas are coalesced server-side (~30 fps); expect bursts.
// - Current gateways advertise `heartbeat:true` on gateway.ready and answer
//   `gateway.ping`; Talaria then detects silent half-open sockets. Older peers
//   remain on the URLSession/WebSocket close-event path.
// - Current gateways also advertise an opaque `replay_epoch`, stamp session
//   events with `params.seq`, and answer `session.events.since` after a drop.
// - On disconnect, live sessions are parked for ~20 s; reconnect and
//   session.resume within the grace window reattaches in-flight state.

public struct GatewayError: Error, Sendable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code; self.message = message; self.data = data
    }

    // Application error codes the client special-cases.
    public static let sessionNotFound = 4001
    public static let sessionBusy = 4009
    public static let resumeTooLarge = 4130
}

public enum TransportState: Sendable, Equatable {
    case idle
    case connecting
    /// Connected and past the gateway.ready frame.
    case ready
    case disconnected(reason: String?)
}

/// Low-level JSON-RPC WebSocket transport. One instance per live socket;
/// `GatewayClient` owns reconnect policy and re-creates transports.
public actor GatewayTransport {
    static let replayOverflowEventType = "talaria.internal.replay-buffer-overflow"
    public struct SequencedResponse: Sendable {
        public var value: JSONValue
        public var inboundSequence: UInt64
    }
    private let url: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var nextID = 1
    private var pending: [String: CheckedContinuation<SequencedResponse, Error>] = [:]
    private var inboundSequence: UInt64 = 0
    private var eventContinuation: AsyncStream<GatewayEvent>.Continuation?
    private let heartbeatPolicy: GatewayHeartbeatPolicy
    private var heartbeat = GatewayHeartbeatState(policy: .current)
    private var heartbeatTask: Task<Void, Never>?
    /// Process identity advertised by gateway.ready. Sequence numbers may be
    /// compared only while this exact value is unchanged.
    private(set) public var replayEpoch: String?
    private(set) public var replayBufferOverflowed = false
    private(set) public var state: TransportState = .idle

    /// All server events, in arrival order. Single consumer.
    public nonisolated let events: AsyncStream<GatewayEvent>
    private nonisolated let eventsCont: AsyncStream<GatewayEvent>.Continuation

    public init(url: URL, session: URLSession = .shared,
                heartbeatPolicy: GatewayHeartbeatPolicy = .current) {
        self.url = url
        self.session = session
        self.heartbeatPolicy = heartbeatPolicy
        self.heartbeat = GatewayHeartbeatState(policy: heartbeatPolicy)
        var cont: AsyncStream<GatewayEvent>.Continuation!
        // Replay negotiation intentionally parks live frames for a bounded
        // five-second window. Keep that queue finite too; a current gateway's
        // seq gap caused by overflow retires the socket instead of silently
        // publishing out of order.
        self.events = AsyncStream(
            bufferingPolicy: .bufferingNewest(GatewayReplayCodec.maximumTotalEvents)
        ) { cont = $0 }
        self.eventsCont = cont
    }

    /// Open the socket and wait for the `gateway.ready` event.
    /// The ready frame is the first thing the server sends after accept.
    public func connect(timeout: TimeInterval = 15) async throws {
        guard task == nil else { return }
        state = .connecting
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 * 1024 * 1024
        self.task = task
        task.resume()
        Task { await self.receiveLoop(task) }

        // The server sends gateway.ready immediately on accept; treat its
        // arrival as connection success.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in self.events where event.type == "gateway.ready" {
                    return
                }
                throw GatewayError(code: -1, message: "socket closed before gateway.ready")
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw GatewayError(code: -2, message: "timed out waiting for gateway.ready")
            }
            try await group.next()
            group.cancelAll()
        }
        state = .ready
    }

    public func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        finish(reason: "closed")
    }

    /// Send a JSON-RPC request and await its response (correlated by id;
    /// responses may arrive out of order relative to other requests).
    public func request(_ method: String, params: JSONValue? = nil,
                        timeout: TimeInterval = 120) async throws -> JSONValue {
        try await requestSequenced(method, params: params, timeout: timeout).value
    }

    /// Request plus the exact inbound frame position of its response. Callers
    /// can use this as a lossless event/snapshot boundary.
    public func requestSequenced(_ method: String, params: JSONValue? = nil,
                                 timeout: TimeInterval = 120) async throws -> SequencedResponse {
        guard let task else {
            throw GatewayError(code: -3, message: "not connected")
        }
        let id = String(nextID)
        nextID += 1

        var frame: [String: JSONValue] = [
            "jsonrpc": "2.0",
            "id": .string(id),
            "method": .string(method),
        ]
        if let params { frame["params"] = params }
        let data = try JSONEncoder().encode(JSONValue.object(frame))
        guard let text = String(data: data, encoding: .utf8) else {
            throw GatewayError(code: -4, message: "encode failure")
        }

        // Install the continuation before the socket send. A fast response
        // (or a send failure) must always find and settle its exact waiter.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SequencedResponse, Error>) in
                pending[id] = cont
                Task {
                    do {
                        try await task.send(.string(text))
                    } catch {
                        await self.failPending(id: id, error: error)
                    }
                }
                Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    await self.failPending(id: id, error: GatewayError(
                        code: -5, message: "request timed out: \(method)"))
                }
            }
        } onCancel: {
            Task { await self.failPending(id: id,
                                          error: GatewayError(code: -6, message: "request cancelled")) }
        }
    }

    // MARK: - Internals

    private func registerPending(
        id: String, _ cont: CheckedContinuation<SequencedResponse, Error>
    ) {
        pending[id] = cont
    }

    private func failPending(id: String, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while true {
            do {
                let message = try await task.receive()
                heartbeat.recordInbound(responseID: nil, now: Self.uptime)
                switch message {
                case .string(let text):
                    handleFrame(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { handleFrame(text) }
                @unknown default:
                    break
                }
            } catch {
                finish(reason: (error as NSError).localizedDescription)
                return
            }
        }
    }

    private func handleFrame(_ text: String) {
        inboundSequence &+= 1
        let frameSequence = inboundSequence
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let obj = value.objectValue else { return }

        // Event notification: {"method":"event","params":{type,session_id,payload}}
        if obj["method"]?.stringValue == "event", let params = obj["params"] {
            if params["type"]?.stringValue == "gateway.ready" {
                let advertised = params["payload"]?["heartbeat"]?.boolValue == true
                replayEpoch = Self.admittedReplayEpoch(
                    params["payload"]?["replay_epoch"])
                heartbeat.activate(advertised: advertised, now: Self.uptime)
                if advertised { startHeartbeat() }
            }
            let event = GatewayEvent(type: params["type"]?.stringValue ?? "",
                                     sessionID: params["session_id"]?.stringValue ?? "",
                                     payload: params["payload"],
                                     sequence: Self.admittedSequence(params["seq"]),
                                     inboundSequence: frameSequence)
            enqueueEvent(event)
            return
        }

        // Response: correlate by id. id may be encoded as string or number.
        let id: String? = obj["id"]?.stringValue ?? obj["id"]?.intValue.map(String.init)
        heartbeat.recordInbound(responseID: id, now: Self.uptime)
        if id?.hasPrefix("talaria-heartbeat-") == true { return }
        guard let id, let cont = pending.removeValue(forKey: id) else { return }

        if let error = obj["error"] {
            cont.resume(throwing: GatewayError(code: error["code"]?.intValue ?? -32603,
                                               message: error["message"]?.stringValue ?? "error",
                                               data: error["data"]))
        } else {
            cont.resume(returning: SequencedResponse(
                value: obj["result"] ?? .null,
                inboundSequence: frameSequence))
        }
    }

    private func finish(reason: String?) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        heartbeat.stop()
        state = .disconnected(reason: reason)
        task = nil
        for (_, cont) in pending {
            cont.resume(throwing: GatewayError(code: -7, message: "connection lost"))
        }
        pending.removeAll()
        eventsCont.finish()
    }

    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func enqueueEvent(_ event: GatewayEvent) {
        if replayBufferOverflowed {
            // Once bounded parking overflows, keep an invalidation marker in
            // the newest buffer slot instead of publishing a partial,
            // previously-untracked tail as complete.
            eventsCont.yield(GatewayEvent(
                type: Self.replayOverflowEventType, sessionID: "", payload: nil))
            return
        }
        if case .dropped = eventsCont.yield(event) {
            replayBufferOverflowed = true
            eventsCont.yield(GatewayEvent(
                type: Self.replayOverflowEventType, sessionID: "", payload: nil))
        }
    }

    func enqueueEventForTesting(_ event: GatewayEvent) { enqueueEvent(event) }

    static func admittedSequence(_ value: JSONValue?) -> UInt64? {
        guard let number = value?.doubleValue, number.isFinite, number >= 1,
              number.rounded(.towardZero) == number,
              number <= GatewayReplayCodec.maximumSafeJSONInteger else { return nil }
        return UInt64(number)
    }

    static func admittedReplayEpoch(_ value: JSONValue?) -> String? {
        guard let raw = value?.stringValue else { return nil }
        let epoch = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !epoch.isEmpty, epoch.unicodeScalars.count <= 256 else { return nil }
        return epoch
    }

    private func startHeartbeat() {
        guard heartbeatPolicy.isEnabled, heartbeatTask == nil else { return }
        let interval = heartbeatPolicy.interval
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch { return }
                guard !Task.isCancelled, let self else { return }
                await self.heartbeatTick()
            }
        }
    }

    private func heartbeatTick() {
        guard case .ready = state, let socket = task else { return }
        switch heartbeat.tick(now: Self.uptime) {
        case .none:
            return
        case .invalidate:
            socket.cancel(with: .goingAway,
                          reason: Data("heartbeat acknowledgement timed out".utf8))
            finish(reason: "heartbeat acknowledgement timed out")
        case .send(let id):
            let frame = JSONValue.object([
                "jsonrpc": .string("2.0"),
                "id": .string(id),
                "method": .string("gateway.ping"),
                "params": .object([:]),
            ])
            guard let data = try? JSONEncoder().encode(frame),
                  let text = String(data: data, encoding: .utf8) else {
                socket.cancel(with: .goingAway, reason: nil)
                finish(reason: "heartbeat encode failure")
                return
            }
            Task { [weak self, weak socket] in
                guard let socket else { return }
                do {
                    try await socket.send(.string(text))
                } catch {
                    await self?.heartbeatSendFailed(socket: socket, error: error)
                }
            }
        }
    }

    private func heartbeatSendFailed(socket: URLSessionWebSocketTask, error: Error) {
        guard task === socket, case .ready = state else { return }
        socket.cancel(with: .goingAway, reason: nil)
        finish(reason: "heartbeat send failed: \((error as NSError).localizedDescription)")
    }
}
