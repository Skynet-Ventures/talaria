#if canImport(XCTest)
import Foundation
import XCTest
@testable import TalariaKit
@testable import TalariaUI

private actor MCPReloadGate {
    private var open = false
    private var arrived = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        arrived = true
        guard !open else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func hasArrived() -> Bool { arrived }

    func release() {
        open = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor MCPReloadRPCProbe {
    enum AddOutcome: Sendable {
        case accepted
        case rejected
        case ambiguous
    }

    struct Call: Sendable, Equatable {
        var method: String
        var params: JSONValue?
    }

    private let addOutcome: AddOutcome
    private let addGate: MCPReloadGate?
    private var calls: [Call] = []

    init(addOutcome: AddOutcome = .accepted, addGate: MCPReloadGate? = nil) {
        self.addOutcome = addOutcome
        self.addGate = addGate
    }

    func execute(_ method: String, params: JSONValue?) async throws -> JSONValue {
        calls.append(Call(method: method, params: params))
        switch method {
        case "mcp.servers.add":
            if let addGate { await addGate.wait() }
            switch addOutcome {
            case .accepted:
                return .object([:])
            case .rejected:
                throw GatewayError(code: 5024, message: "MCP config rejected")
            case .ambiguous:
                throw URLError(.networkConnectionLost)
            }
        case "reload.mcp":
            return .object([
                "status": .string("reloaded"),
                "loaded_rev": .string("mcp-revision"),
            ])
        case "mcp.servers.list":
            return .object(["servers": .array([])])
        case "mcp.catalog":
            return .object(["servers": .array([])])
        default:
            return .object([:])
        }
    }

    func calls(for method: String) -> [Call] {
        calls.filter { $0.method == method }
    }

    func methods() -> [String] { calls.map(\.method) }
}

@MainActor
private struct MCPReloadRuntimeSnapshot {
    var gatewayID: String?
    var baseURL: URL?
    var generation: Int
    var sessionToBot: [String: String]
    var routedSessionToBot: [GatewaySessionRoute: String]
}

@MainActor
private struct MCPReloadPrimaryFixture {
    var model: AppModel
    var client: GatewayClient
    var saved: SavedGateway
    var runtime: MCPReloadRuntimeSnapshot
}

@MainActor
final class MCPReloadCapabilityTests: XCTestCase {
    private func eventually(_ predicate: @escaping () async -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if await predicate() { return true }
            await Task.yield()
        }
        return await predicate()
    }

    private func makePrimaryFixture() throws -> MCPReloadPrimaryFixture {
        let runtime = LiveRuntime.shared
        let snapshot = MCPReloadRuntimeSnapshot(
            gatewayID: runtime.gatewayID,
            baseURL: runtime.baseURL,
            generation: runtime.generation,
            sessionToBot: runtime.sessionToBot,
            routedSessionToBot: runtime.routedSessionToBot)
        CapabilityRuntime.shared.states.removeAll()

        let url = URL(string: "https://mcp-reload-\(UUID().uuidString).example")!
        let registry = ConnectionRegistry.shared
        let saved = try XCTUnwrap(registry.upsert(urlString: url.absoluteString,
                                                  name: "MCP reload test"))
        let baseURL = try XCTUnwrap(saved.baseURL)
        let client = GatewayClient(baseURL: baseURL,
                                   credential: .sessionToken("mcp-reload-test"))
        let model = AppModel()
        model.mode = .live
        model.isOffline = false
        model.client = client
        runtime.gatewayID = saved.id
        runtime.baseURL = baseURL
        runtime.generation = snapshot.generation + 1
        runtime.sessionToBot = [:]
        runtime.routedSessionToBot = [:]
        return MCPReloadPrimaryFixture(model: model, client: client, saved: saved,
                                       runtime: snapshot)
    }

    private func restore(_ fixture: MCPReloadPrimaryFixture,
                         additionalGateways: [SavedGateway] = []) {
        let registry = ConnectionRegistry.shared
        let gateways = [fixture.saved] + additionalGateways
        let gatewayIDs = gateways.map(\.id)
        for gateway in gateways {
            registry.remove(id: gateway.id)
        }
        let runtime = LiveRuntime.shared
        runtime.gatewayID = fixture.runtime.gatewayID
        runtime.baseURL = fixture.runtime.baseURL
        runtime.generation = fixture.runtime.generation
        runtime.sessionToBot = fixture.runtime.sessionToBot
        runtime.routedSessionToBot = fixture.runtime.routedSessionToBot
        CapabilityRuntime.shared.states.removeAll()
        let pool = registry.clientPool
        Task {
            for gatewayID in gatewayIDs {
                await pool.disconnect(gatewayID: gatewayID)
            }
        }
    }

    private func bindPrimary(_ fixture: MCPReloadPrimaryFixture,
                             profile: String = "worker", sessionID: String = "runtime-worker") {
        let chat = fixture.model.chat(for: profile)
        chat.sessionID = sessionID
        LiveRuntime.shared.sessionToBot[sessionID] = profile
    }

    private func install(_ probe: MCPReloadRPCProbe, on client: GatewayClient) async {
        await client.setRPCExecutorForTesting { method, params, _ in
            try await probe.execute(method, params: params)
        }
    }

    func testReloadWrapperSendsConfirmedExactRuntimeSessionAndRequiresAck() async throws {
        let probe = MCPReloadRPCProbe()
        let client = GatewayClient(
            baseURL: URL(string: "https://mcp-reload-wrapper.example")!,
            credential: .sessionToken("mcp-reload-test"))
        await install(probe, on: client)

        let receipt = try await client.reloadMCP(sessionID: "runtime-session")

        XCTAssertEqual(receipt.loadedRevision, "mcp-revision")
        let reloadCalls = await probe.calls(for: "reload.mcp")
        let call = try XCTUnwrap(reloadCalls.first)
        XCTAssertEqual(call.params, .object([
            "confirm": .bool(true),
            "session_id": .string("runtime-session"),
        ]))
    }

    func testPersistedMCPChangeWithoutExactRuntimeDefersToNextSession() async throws {
        let fixture = try makePrimaryFixture()
        defer { restore(fixture) }
        let probe = MCPReloadRPCProbe()
        await install(probe, on: fixture.client)

        let accepted = await fixture.model.addMCPServer(
            name: "calendar", url: "https://calendar.example/mcp", command: nil,
            args: [], profile: "worker")

        let state = fixture.model.capabilities(for: "worker")
        XCTAssertTrue(accepted, "the persisted config receipt remains successful")
        XCTAssertEqual(state.mcpReloadState, .takesEffectNextSession)
        XCTAssertTrue(state.notice?.contains("takes effect next session") == true,
                      state.notice ?? "missing next-session notice")
        let reloadCalls = await probe.calls(for: "reload.mcp")
        XCTAssertTrue(reloadCalls.isEmpty)
    }

    func testAcknowledgedReloadUsesTheExactActiveRuntimeSession() async throws {
        let fixture = try makePrimaryFixture()
        defer { restore(fixture) }
        let probe = MCPReloadRPCProbe()
        await install(probe, on: fixture.client)
        bindPrimary(fixture, sessionID: "runtime-exact")

        let accepted = await fixture.model.addMCPServer(
            name: "calendar", url: "https://calendar.example/mcp", command: nil,
            args: [], profile: "worker")

        let state = fixture.model.capabilities(for: "worker")
        XCTAssertTrue(accepted)
        XCTAssertEqual(state.mcpReloadState, .reloaded)
        XCTAssertNil(state.notice)
        let reloadCalls = await probe.calls(for: "reload.mcp")
        let reload = try XCTUnwrap(reloadCalls.first)
        XCTAssertEqual(reload.params?["session_id"]?.stringValue, "runtime-exact")
        let methods = await probe.methods()
        XCTAssertLessThan(try XCTUnwrap(methods.firstIndex(of: "mcp.servers.add")),
                          try XCTUnwrap(methods.firstIndex(of: "reload.mcp")))
    }

    func testForeignCapabilitySourceReloadsOnlyItsOwnQualifiedRuntimeSession() async throws {
        let fixture = try makePrimaryFixture()
        let registry = ConnectionRegistry.shared
        let remoteURL = URL(string: "https://mcp-reload-remote-\(UUID().uuidString).example")!
        let remote = try XCTUnwrap(registry.upsert(urlString: remoteURL.absoluteString,
                                                   name: "Remote MCP reload"))
        registry.setCredentialForTesting(.sessionToken("remote-mcp-reload"), for: remote)
        defer { restore(fixture, additionalGateways: [remote]) }

        let primaryProbe = MCPReloadRPCProbe()
        await install(primaryProbe, on: fixture.client)
        bindPrimary(fixture, profile: "worker", sessionID: "shared-runtime")

        let remoteProbe = MCPReloadRPCProbe()
        let remoteClient = GatewayClient(baseURL: try XCTUnwrap(remote.baseURL),
                                         credential: .sessionToken("remote-mcp-reload"))
        await install(remoteProbe, on: remoteClient)
        await registry.clientPool.adopt(remoteClient, for: remote.id)

        let route = GatewayBotRoute(gatewayID: remote.id, profile: "worker")
        let remoteChat = fixture.model.chat(for: route.qualifiedID)
        remoteChat.sessionID = "shared-runtime"
        LiveRuntime.shared.routedSessionToBot[
            GatewaySessionRoute(gatewayID: remote.id, sessionID: "shared-runtime")
        ] = route.qualifiedID

        let accepted = await fixture.model.addMCPServer(
            name: "remote-calendar", url: "https://calendar.example/mcp", command: nil,
            args: [], profile: route.qualifiedID)

        XCTAssertTrue(accepted)
        let primaryReloadCalls = await primaryProbe.calls(for: "reload.mcp")
        let remoteReloadCalls = await remoteProbe.calls(for: "reload.mcp")
        XCTAssertTrue(primaryReloadCalls.isEmpty)
        let reload = try XCTUnwrap(remoteReloadCalls.first)
        XCTAssertEqual(reload.params?["session_id"]?.stringValue, "shared-runtime")
        XCTAssertEqual(fixture.model.capabilities(for: route.qualifiedID).mcpReloadState,
                       .reloaded)
    }

    func testSessionReplacementDuringPersistAwaitDoesNotReloadTheReplacement() async throws {
        let fixture = try makePrimaryFixture()
        defer { restore(fixture) }
        let gate = MCPReloadGate()
        let probe = MCPReloadRPCProbe(addGate: gate)
        await install(probe, on: fixture.client)
        bindPrimary(fixture, sessionID: "runtime-before")

        let mutation = Task { @MainActor in
            await fixture.model.addMCPServer(
                name: "calendar", url: "https://calendar.example/mcp", command: nil,
                args: [], profile: "worker")
        }
        let addArrived = await eventually { await gate.hasArrived() }
        XCTAssertTrue(addArrived)

        let chat = fixture.model.chat(for: "worker")
        LiveRuntime.shared.sessionToBot["runtime-before"] = nil
        chat.sessionID = "runtime-after"
        LiveRuntime.shared.sessionToBot["runtime-after"] = "worker"
        await gate.release()

        let accepted = await mutation.value
        XCTAssertTrue(accepted)
        let state = fixture.model.capabilities(for: "worker")
        XCTAssertEqual(state.mcpReloadState, .takesEffectNextSession)
        XCTAssertTrue(state.notice?.contains("takes effect next session") == true,
                      state.notice ?? "missing next-session notice")
        let reloadCalls = await probe.calls(for: "reload.mcp")
        XCTAssertTrue(reloadCalls.isEmpty)
    }

    func testRejectedMCPMutationDoesNotReload() async throws {
        let fixture = try makePrimaryFixture()
        defer { restore(fixture) }
        let probe = MCPReloadRPCProbe(addOutcome: .rejected)
        await install(probe, on: fixture.client)
        bindPrimary(fixture)

        let accepted = await fixture.model.addMCPServer(
            name: "calendar", url: "https://calendar.example/mcp", command: nil,
            args: [], profile: "worker")

        XCTAssertFalse(accepted)
        let addCalls = await probe.calls(for: "mcp.servers.add")
        let reloadCalls = await probe.calls(for: "reload.mcp")
        XCTAssertEqual(addCalls.count, 1)
        XCTAssertTrue(reloadCalls.isEmpty)
    }

    func testAmbiguousMCPMutationNeverReplaysOrReloads() async throws {
        let fixture = try makePrimaryFixture()
        defer { restore(fixture) }
        let probe = MCPReloadRPCProbe(addOutcome: .ambiguous)
        await install(probe, on: fixture.client)
        bindPrimary(fixture)

        let accepted = await fixture.model.addMCPServer(
            name: "calendar", url: "https://calendar.example/mcp", command: nil,
            args: [], profile: "worker")

        XCTAssertFalse(accepted)
        let addCalls = await probe.calls(for: "mcp.servers.add")
        let reloadCalls = await probe.calls(for: "reload.mcp")
        XCTAssertEqual(addCalls.count, 1)
        XCTAssertTrue(reloadCalls.isEmpty)
    }
}
#endif
