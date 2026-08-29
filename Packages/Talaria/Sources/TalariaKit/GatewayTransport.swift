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
// - No application-level heartbeat is required; on public binds the server
//   pings at the protocol level every 20 s.
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
    public struct SequencedResponse: Sendable {
        public var value: JSONValue
        public var inboundSequence: UInt64
    }
    private let url: URL
    private let session: URLSession
    private let ownsSession: Bool
    private var task: URLSessionWebSocketTask?
    private var nextID = 1
    private var pending: [String: CheckedContinuation<SequencedResponse, Error>] = [:]
    private var inboundSequence: UInt64 = 0
    private var eventContinuation: AsyncStream<GatewayEvent>.Continuation?
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var sawReady = false
    private(set) public var state: TransportState = .idle

    /// All server events, in arrival order. Single consumer.
    public nonisolated let events: AsyncStream<GatewayEvent>
    private nonisolated let eventsCont: AsyncStream<GatewayEvent>.Continuation

    public init(url: URL, session: URLSession? = nil) {
        self.url = url
        if let session {
            self.session = session
            self.ownsSession = false
        } else {
            // A dedicated ephemeral session per socket. Writing onto a
            // half-open `URLSession.shared` WebSocket after iOS parks the
            // process wedges the shared session; the next dial never returns.
            // Ephemeral session, Apple request/resource timeouts left at
            // defaults. Those clocks are for finite HTTP transfers: a
            // WebSocket never "finishes", and request=15s is shorter than
            // Hermes' 20s protocol ping. Connect is bounded in `connect()`.
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
            self.ownsSession = true
        }
        var cont: AsyncStream<GatewayEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.eventsCont = cont
    }

    /// Open the socket and wait for the `gateway.ready` event.
    /// The ready frame is the first thing the server sends after accept.
    ///
    /// Ready is signaled here, not by iterating `events`. That stream is
    /// single-consumer: this waiter owning the iterator left the client's
    /// event pump with nothing, so the supervised monitor treated a live
    /// socket as already dead (15s ready bound, then a dead redial).
    public func connect(timeout: TimeInterval = 15) async throws {
        guard task == nil else { return }
        state = .connecting
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 * 1024 * 1024
        self.task = task
        task.resume()
        Task { await self.receiveLoop(task) }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await self.waitForReady()
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw GatewayError(code: -2, message: "timed out waiting for gateway.ready")
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            close()
            throw error
        }
        state = .ready
    }

    private func waitForReady() async throws {
        if sawReady { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if sawReady {
                    cont.resume()
                } else {
                    readyWaiter = cont
                }
            }
        } onCancel: {
            Task { await self.failReadyWaiter(CancellationError()) }
        }
    }

    private func failReadyWaiter(_ error: Error) {
        readyWaiter?.resume(throwing: error)
        readyWaiter = nil
    }

    public func close() {
        task?.cancel(with: .goingAway, reason: nil)
        finish(reason: "closed")
        if ownsSession {
            session.finishTasksAndInvalidate()
        }
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
            let event = GatewayEvent(type: params["type"]?.stringValue ?? "",
                                     sessionID: params["session_id"]?.stringValue ?? "",
                                     payload: params["payload"],
                                     inboundSequence: frameSequence)
            if event.type == "gateway.ready" {
                sawReady = true
                readyWaiter?.resume()
                readyWaiter = nil
            }
            eventsCont.yield(event)
            return
        }

        // Response: correlate by id. id may be encoded as string or number.
        let id: String? = obj["id"]?.stringValue ?? obj["id"]?.intValue.map(String.init)
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
        state = .disconnected(reason: reason)
        task = nil
        failReadyWaiter(GatewayError(code: -1, message: "socket closed before gateway.ready"))
        for (_, cont) in pending {
            cont.resume(throwing: GatewayError(code: -7, message: "connection lost"))
        }
        pending.removeAll()
        eventsCont.finish()
    }
}
