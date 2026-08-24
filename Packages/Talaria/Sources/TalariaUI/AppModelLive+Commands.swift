import SwiftUI
import TalariaKit
import TalariaTheme

// Live-mode slash commands + the mcp.setup answer path.
//
// Two jobs here:
//
// 1. Slash commands. Typed "/status" used to reach the LLM as prose; it now
//    goes through slash.exec against the bot's own session and its {output}
//    lands as a system row. The catalog behind the palette is fetched once per
//    gateway and cached.
//
// 2. The mcp.setup correctness fix. The gateway parks the agent's tool thread
//    for 600 s waiting on mcp.setup.respond; nothing in Talaria answered it, so
//    an agent-initiated MCP setup silently stalled the whole turn. We now
//    surface the request and answer it — including an immediate decline, which
//    is the difference between a 1-second "not here" and a 10-minute hang.
//
//    Talaria cannot actually run the flow: install/enable/authorize are REST +
//    browser-OAuth surfaces the desktop renderer owns (PUT /api/mcp/servers/
//    <name>/enabled and friends), with no WebSocket twin. So both buttons
//    answer `declined` — the one status the tool documents as "continue
//    without the server" — and differ only in the detail the agent reads.

// MARK: - Runtime state (side table)

/// Observable book-keeping for commands. `AppModel`'s stored properties live in
/// AppModel.swift (another owner) and extensions cannot add storage, so this
/// rides alongside `LiveRuntime` as a MainActor singleton. It is `@Observable`
/// because the palette and the MCP prompt read it from a SwiftUI body.
@MainActor
@Observable
final class CommandCatalogRuntime {
    /// The physical gateway that owns this catalog. Slash catalog endpoints do
    /// not accept `profile`; their only valid scope is the connected gateway.
    let gatewayID: String

    /// Identity of the exact connection the cache belongs to. A reconnect can
    /// retain its gateway id but replace the command registry underneath us.
    var clientOwner: ObjectIdentifier?
    var connectionGeneration: UInt64?
    var catalog: [SlashCommand] = []
    var skillCount = 0
    var unsupportedStandaloneSkillNames: Set<String> = []
    /// Server-side discovery warning (skills/quick-commands), banner-worthy.
    var warning = ""
    /// The catalog RPC failed — the palette shows a themed retry state.
    var failed = false
    var catalogLoaded = false
    var catalogTask: Task<[SlashCommand], Never>?
    @ObservationIgnored var generation: UInt64 = 0

    init(gatewayID: String, clientOwner: ObjectIdentifier? = nil) {
        self.gatewayID = gatewayID
        self.clientOwner = clientOwner
    }

    func invalidate(owner: ObjectIdentifier?, connectionGeneration: UInt64? = nil) {
        catalogTask?.cancel()
        catalogTask = nil
        catalog = []
        skillCount = 0
        unsupportedStandaloneSkillNames = []
        warning = ""
        failed = false
        catalogLoaded = false
        clientOwner = owner
        self.connectionGeneration = connectionGeneration
        generation &+= 1
    }
}

@MainActor
@Observable
final class CommandsRuntime {
    static let shared = CommandsRuntime()

    /// One cache per *physical* gateway. A profile route chooses its gateway
    /// before it reaches this state; it must never create a profile cache key
    /// because commands.catalog/complete.slash/command.resolve are not
    /// profile-scoped upstream.
    var catalogs: [String: CommandCatalogRuntime] = [:]

    /// A prefill is deliberately retained until the exact composer consumes
    /// it. Route alone is insufficient: a reconnect can reuse the route, and a
    /// newly-opened durable chat can reuse both route and bot id.
    var slashPrefills: [GatewayBotRoute: SlashPrefillBinding] = [:]

    /// Latest accepted pool generation per gateway. Pool generations are
    /// monotonic; a late event from an older generation is rejected rather
    /// than being allowed to downgrade this authority.
    var connectionGenerations: [String: UInt64] = [:]

    /// Unanswered mcp.setup.request events, oldest first. Each one is a parked
    /// agent thread, so the queue is normally 0 or 1 deep.
    var mcpRequests: [MCPSetupRequest] = []

    /// The exact client that emitted each parked request. A request id is only
    /// unique within one gateway process, so a later active-client lookup is
    /// not an authority to answer it on a different source.
    @ObservationIgnored var mcpClients: [GatewayMCPSetupRoute: MCPClientBinding] = [:]
    var mcpResponsesInFlight: Set<GatewayMCPSetupRoute> = []
    var mcpResponseErrors: [GatewayMCPSetupRoute: String] = [:]

    /// The client the event router is attached to, and its pump.
    var routerOwner: ObjectIdentifier?
    var routerGatewayID: String?
    @ObservationIgnored var routerClient: GatewayClient?
    @ObservationIgnored var routerHandlerID: UUID?
    var routerPump: Task<Void, Never>?

    func catalog(for gatewayID: String, owner: ObjectIdentifier?, generation: UInt64? = nil) -> CommandCatalogRuntime {
        if let state = catalogs[gatewayID] {
            if state.clientOwner != owner || state.connectionGeneration != generation {
                state.invalidate(owner: owner, connectionGeneration: generation)
            }
            return state
        }
        let state = CommandCatalogRuntime(gatewayID: gatewayID, clientOwner: owner)
        state.connectionGeneration = generation
        catalogs[gatewayID] = state
        return state
    }

    /// Accept an exact current connection generation. A greater generation is
    /// a replacement and atomically invalidates state owned by the prior
    /// process. A lesser generation is a late event and fails closed.
    @discardableResult
    func observeConnection(gatewayID: String, generation: UInt64) -> Bool {
        if let current = connectionGenerations[gatewayID] {
            guard generation >= current else { return false }
            if generation > current { drop(gatewayID: gatewayID) }
        }
        connectionGenerations[gatewayID] = generation
        return true
    }

    func drop(gatewayID: String) {
        catalogs[gatewayID]?.invalidate(owner: nil)
        catalogs.removeValue(forKey: gatewayID)
        slashPrefills = slashPrefills.filter { $0.key.gatewayID != gatewayID }
        mcpRequests.removeAll { $0.gatewayID == gatewayID }
        mcpClients = mcpClients.filter { $0.key.gatewayID != gatewayID }
        mcpResponsesInFlight = mcpResponsesInFlight.filter { $0.gatewayID != gatewayID }
        mcpResponseErrors = mcpResponseErrors.filter { $0.key.gatewayID != gatewayID }
        connectionGenerations.removeValue(forKey: gatewayID)
    }

    /// Keep a failed MCP request queued for an explicit retry. Returns true
    /// only when the visible error changed, avoiding duplicate transcript spam.
    @discardableResult
    func retainFailedMCPResponse(route: GatewayMCPSetupRoute, detail: String) -> Bool {
        mcpResponsesInFlight.remove(route)
        guard mcpRequests.contains(where: { $0.route == route }) else { return false }
        return mcpResponseErrors.updateValue(detail, forKey: route) != detail
    }
}

struct SlashPrefillBinding: Equatable {
    var botID: String
    var route: GatewayBotRoute
    var connectionGeneration: UInt64
    var chatID: ObjectIdentifier
    var storedSessionID: String?
    var runtimeSessionID: String
    var message: String
}

enum SlashPrefillPolicy {
    static func identityMatches(_ binding: SlashPrefillBinding,
                                currentRoute: GatewayBotRoute?,
                                currentConnectionGeneration: UInt64?,
                                currentChatID: ObjectIdentifier?, currentStoredID: String?,
                                currentRuntimeID: String?) -> Bool {
        currentRoute == binding.route
            && currentConnectionGeneration == binding.connectionGeneration
            && currentChatID == binding.chatID
            && currentStoredID == binding.storedSessionID
            && currentRuntimeID == binding.runtimeSessionID
    }

    static func mayApply(_ binding: SlashPrefillBinding, draft: String,
                         selectedBotID: String?, currentRoute: GatewayBotRoute?,
                         currentConnectionGeneration: UInt64?,
                         currentChatID: ObjectIdentifier?, currentStoredID: String?,
                         currentRuntimeID: String?) -> Bool {
        draft.isEmpty
            && selectedBotID == binding.botID
            && identityMatches(
                binding, currentRoute: currentRoute,
                currentConnectionGeneration: currentConnectionGeneration,
                currentChatID: currentChatID, currentStoredID: currentStoredID,
                currentRuntimeID: currentRuntimeID)
    }
}

enum SlashResolvedCommandPolicy {
    /// `command.resolve` reports every canonical hit as a command, including a
    /// standalone skill reached through an alias. The exact connection's
    /// catalog is therefore the authority for whether the hit may be shown.
    static func visible(_ command: SlashCommand?,
                        unsupportedStandaloneSkillNames: Set<String>) -> SlashCommand? {
        guard let command,
              !unsupportedStandaloneSkillNames.contains(
                SlashCatalog.normalizedName(command.name)) else { return nil }
        return command
    }
}

enum SlashGeneratedSubmissionPolicy {
    enum Decision: Equatable { case submit, retainDraft }

    static func decision(capturedGeneration: UInt64, observedGeneration: UInt64?,
                         clientMatches: Bool, bindingMatches: Bool) -> Decision {
        guard observedGeneration == capturedGeneration,
              clientMatches, bindingMatches else { return .retainDraft }
        return .submit
    }
}

enum SlashGeneratedSettlementPolicy {
    static let retainedDraftNotice =
        "Generated command input was kept as a recoverable draft."

    /// `slash.exec` has already accepted before the synthesized prompt crosses
    /// its own boundary. Anything short of authoritative prompt acceptance
    /// must therefore preserve that prompt for the user instead of dropping it.
    static func requiresDraftRetention(_ result: AppModel.LiveSendResult) -> Bool {
        switch result {
        case .accepted:
            false
        case .retained, .failed:
            true
        }
    }

    /// An upstream notice describes the accepted slash operation; it does not
    /// describe whether the second prompt boundary settled. Keep both facts
    /// visible when that generated prompt had to be retained.
    static func messages(for result: AppModel.LiveSendResult,
                         notice: String?) -> [String] {
        let upstreamNotice = notice.flatMap { $0.isEmpty ? nil : $0 }
        switch result {
        case .accepted:
            return upstreamNotice.map { [$0] } ?? []
        case .retained, .failed:
            return [upstreamNotice, retainedDraftNotice].compactMap { $0 }
        }
    }
}

struct MCPClientBinding {
    var client: GatewayClient
    var connectionGeneration: UInt64
}

extension GatewayClientPool {
    /// Run a command/MCP acceptance boundary while the exact pooled client
    /// still owns its slot. The actor remains re-entrant while `operation`
    /// awaits, but the lease token makes adopt/disconnect wait. Keeping the
    /// release in this actor-isolated defer is important: callers can settle
    /// their MainActor state before a replacement process is allowed to purge
    /// the old generation's authority.
    func withCommandConnectionLease<Result: Sendable>(
        _ snapshot: ConnectionSnapshot,
        for gatewayID: String,
        operation: @MainActor @Sendable () async throws -> Result
    ) async rethrows -> Result? {
        guard let lease = await acquireLease(snapshot, for: gatewayID) else { return nil }
        defer { release(lease) }
        return try await operation()
    }

    /// Keep both kinds of source authority across a compound command boundary.
    /// The pool lease prevents G2 adoption while the ordinary-traffic lease
    /// prevents a profile rename/delete from entering between `slash.exec` and
    /// the generated prompt it asks Talaria to submit.
    func withCommandConnectionAndTrafficLease<Result: Sendable>(
        _ snapshot: ConnectionSnapshot,
        for gatewayID: String,
        operation: @MainActor @Sendable () async throws -> Result
    ) async throws -> Result? {
        guard let poolLease = await acquireLease(snapshot, for: gatewayID) else { return nil }
        defer { release(poolLease) }
        let trafficLease = try await snapshot.client.acquireTrafficLease()
        do {
            let result = try await operation()
            await trafficLease?.release()
            return result
        } catch {
            await trafficLease?.release()
            throw error
        }
    }
}

// MARK: - MCP setup request

/// A parked `mcp.setup.request` (server.py:6228 → _block, 600 s).
public struct GatewayMCPSetupRoute: Hashable, Sendable, Identifiable {
    public var gatewayID: String
    public var connectionGeneration: UInt64
    public var requestID: String

    /// Delimit the variable-length gateway id so two sources cannot fabricate
    /// the same UI identity through string concatenation.
    public var id: String {
        "mcp:\(gatewayID.count):\(gatewayID)\u{1f}\(connectionGeneration)\u{1f}\(requestID)"
    }

    public init(gatewayID: String, connectionGeneration: UInt64 = 0,
                requestID: String) {
        self.gatewayID = gatewayID
        self.connectionGeneration = connectionGeneration
        self.requestID = requestID
    }
}

public struct MCPSetupRequest: Identifiable, Sendable, Equatable {
    public enum Action: String, Sendable, Equatable { case install, enable, authorize }

    public var id: String { route.id }
    /// The physical gateway that emitted this event. Request IDs are not
    /// process-global, so this is part of the response authority.
    public var gatewayID: String
    /// Exact pool slot generation that emitted the request.
    public var connectionGeneration: UInt64
    public var requestID: String
    /// Runtime session id the request belongs to ("" for a global emit).
    public var sessionID: String
    /// Catalog name (install) or configured server name (enable/authorize).
    public var server: String
    public var action: Action
    /// The agent's justification, shown verbatim.
    public var reason: String

    public var route: GatewayMCPSetupRoute {
        GatewayMCPSetupRoute(gatewayID: gatewayID,
                             connectionGeneration: connectionGeneration,
                             requestID: requestID)
    }

    init?(_ event: GatewayEvent, gatewayID: String, connectionGeneration: UInt64) {
        let payload = event.payload
        let requestID = payload?["request_id"]?.stringValue ?? ""
        let server = payload?["server"]?.stringValue ?? ""
        guard !gatewayID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !requestID.isEmpty, !server.isEmpty else { return nil }
        self.gatewayID = gatewayID
        self.connectionGeneration = connectionGeneration
        self.requestID = requestID
        self.sessionID = event.sessionID
        self.server = server
        // The tool validates the enum before emitting; anything else is a
        // newer gateway and installs are the documented default.
        self.action = Action(rawValue: payload?["action"]?.stringValue ?? "") ?? .install
        self.reason = payload?["reason"]?.stringValue ?? ""
    }

    public init(gatewayID: String, connectionGeneration: UInt64 = 0,
                requestID: String, sessionID: String, server: String,
                action: Action, reason: String) {
        self.gatewayID = gatewayID
        self.connectionGeneration = connectionGeneration
        self.requestID = requestID
        self.sessionID = sessionID
        self.server = server; self.action = action; self.reason = reason
    }

    /// Compatibility initializer for local presentation fixtures. It cannot
    /// answer a gateway request until a source-qualified route is supplied.
    public init(requestID: String, sessionID: String, server: String,
                action: Action, reason: String) {
        self.init(gatewayID: "", requestID: requestID, sessionID: sessionID,
                  server: server, action: action, reason: reason)
    }
}

/// What the user chose on the MCP setup card. Both answers unblock the agent
/// immediately; only the detail text differs.
public enum MCPSetupAnswer: Sendable, Equatable {
    /// "I'll do it on desktop" — the agent should carry on without the server.
    case deferToDesktop
    /// "No" — the agent must not propose this server again.
    case decline
}

extension AppModel {

    private func commandConnection(gatewayID: String) async throws -> GatewayClientPool.ConnectionSnapshot {
        let registry = ConnectionRegistry.shared
        guard let gateway = registry.saved.first(where: { $0.id == gatewayID }),
              let baseURL = gateway.baseURL,
              let credential = registry.credential(for: gateway) else { throw GatewayRouteError.unknownGateway(gatewayID) }
        let snapshot = try await registry.clientPool.connectWithGeneration(gatewayID: gatewayID, baseURL: baseURL, credential: credential)
        guard profileLifecycleAllowsGatewayTraffic(gatewayID),
              gatewayID != activeGatewayID || client.map(ObjectIdentifier.init) == ObjectIdentifier(snapshot.client) else { throw CancellationError() }
        guard CommandsRuntime.shared.observeConnection(
            gatewayID: gatewayID, generation: snapshot.generation) else {
            throw CancellationError()
        }
        return snapshot
    }

    private func commandConnectionIsCurrent(_ snapshot: GatewayClientPool.ConnectionSnapshot, gatewayID: String) async -> Bool {
        guard profileLifecycleAllowsGatewayTraffic(gatewayID),
              await ConnectionRegistry.shared.clientPool.isCurrent(snapshot, for: gatewayID) else { return false }
        return gatewayID != activeGatewayID || client.map(ObjectIdentifier.init) == ObjectIdentifier(snapshot.client)
    }

    /// Consume a source-qualified slash prefill. The chat composer calls this
    /// when it becomes active; no prefill may leak to another gateway/profile.
    func takeSlashPrefill(for botID: String, chat: ChatState, draft: String) -> String? {
        guard let route = stateRoute(for: botID) ?? gatewayRoute(for: botID),
              let binding = CommandsRuntime.shared.slashPrefills[route] else { return nil }
        guard SlashPrefillPolicy.mayApply(
            binding, draft: draft, selectedBotID: openBotID, currentRoute: route,
            currentConnectionGeneration: CommandsRuntime.shared.connectionGenerations[route.gatewayID],
            currentChatID: ObjectIdentifier(chat), currentStoredID: chat.storedSessionID,
            currentRuntimeID: chat.sessionID) else {
            CommandsRuntime.shared.slashPrefills.removeValue(forKey: route)
            return nil
        }
        return CommandsRuntime.shared.slashPrefills.removeValue(forKey: route)?.message
    }

    // MARK: - Catalog

    /// The source for catalog/completion/resolve. A bot route selects a
    /// physical gateway first; Hermes deliberately has no `profile` parameter
    /// on these command RPCs.
    private func commandGatewayID(for botID: String?) -> String? {
        if let botID {
            return (stateRoute(for: botID) ?? gatewayRoute(for: botID))?.gatewayID
        }
        return activeGatewayID ?? (client == nil ? nil : LiveRuntime.shared.gatewayID)
    }

    /// The slash catalog for a bot's physical gateway. Cached independently by
    /// gateway and connection identity so two retained sources with the same
    /// command spelling cannot overwrite one another.
    public func slashCatalog(for botID: String? = nil) async -> [SlashCommand] {
        guard mode == .live else { return mode == .demo ? Self.demoSlashCatalog : [] }
        guard let gatewayID = commandGatewayID(for: botID) else { return [] }
        let snapshot: GatewayClientPool.ConnectionSnapshot
        do {
            snapshot = try await commandConnection(gatewayID: gatewayID)
        } catch {
            let state = CommandsRuntime.shared.catalog(for: gatewayID, owner: nil)
            state.catalog = []
            state.failed = true
            state.warning = Self.commandErrorDetail(error)
            return []
        }

        let client = snapshot.client
        let state = CommandsRuntime.shared.catalog(for: gatewayID, owner: ObjectIdentifier(client), generation: snapshot.generation)
        if state.catalogLoaded { return state.catalog }
        if let inflight = state.catalogTask { return await inflight.value }

        let generation = state.generation
        let owner = ObjectIdentifier(client)
        let task = Task<[SlashCommand], Never> { @MainActor in
            do {
                let catalog = try await client.commandsCatalog()
                guard await self.commandConnectionIsCurrent(snapshot, gatewayID: gatewayID), state.generation == generation, state.clientOwner == owner, state.connectionGeneration == snapshot.generation else {
                    return state.catalog
                }
                state.catalog = catalog.commands
                state.skillCount = catalog.skillCount
                state.unsupportedStandaloneSkillNames = catalog.unsupportedStandaloneSkillNames
                state.warning = catalog.warning
                state.failed = false
                state.catalogLoaded = true
            } catch {
                guard await self.commandConnectionIsCurrent(snapshot, gatewayID: gatewayID), state.generation == generation, state.clientOwner == owner, state.connectionGeneration == snapshot.generation else {
                    return state.catalog
                }
                state.catalog = []
                state.unsupportedStandaloneSkillNames = []
                state.failed = true
                state.warning = Self.commandErrorDetail(error)
                state.catalogLoaded = false
            }
            if await self.commandConnectionIsCurrent(snapshot, gatewayID: gatewayID), state.generation == generation, state.clientOwner == owner, state.connectionGeneration == snapshot.generation {
                state.catalogTask = nil
            }
            return state.catalog
        }
        state.catalogTask = task
        return await task.value
    }

    /// Drop only the requesting bot's physical-gateway catalog cache.
    public func reloadSlashCatalog(for botID: String? = nil) async -> [SlashCommand] {
        guard let gatewayID = commandGatewayID(for: botID) else {
            return mode == .demo ? Self.demoSlashCatalog : []
        }
        let owner = (try? await routedClient(gatewayID: gatewayID)).map(ObjectIdentifier.init)
        CommandsRuntime.shared.catalog(for: gatewayID, owner: owner).invalidate(owner: owner)
        return await slashCatalog(for: botID)
    }

    public func slashCatalogWarning(for botID: String? = nil) -> String {
        guard let gatewayID = commandGatewayID(for: botID) else { return "" }
        return CommandsRuntime.shared.catalogs[gatewayID]?.warning ?? ""
    }

    public func slashCatalogFailed(for botID: String? = nil) -> Bool {
        guard let gatewayID = commandGatewayID(for: botID) else { return false }
        return CommandsRuntime.shared.catalogs[gatewayID]?.failed ?? false
    }

    public func slashSkillCount(for botID: String? = nil) -> Int {
        guard let gatewayID = commandGatewayID(for: botID) else { return 0 }
        return CommandsRuntime.shared.catalogs[gatewayID]?.skillCount ?? 0
    }

    /// Compatibility accessors for primary-only callers. The palette passes
    /// its bot id so its state cannot read another physical gateway's cache.
    public var slashCatalogWarning: String { slashCatalogWarning(for: nil) }
    public var slashCatalogFailed: Bool { slashCatalogFailed(for: nil) }
    public var slashSkillCount: Int { slashSkillCount(for: nil) }

    /// Live completion for composer text starting with "/". Completion is
    /// physical-gateway scoped, never profile scoped.
    public func slashCompletions(for text: String, botID: String? = nil) async -> SlashCompletions {
        guard mode == .live, text.hasPrefix("/") else { return .empty }
        // commands.catalog is the only c1e25 shape that distinguishes a
        // standalone skill (unsafe here) from a bundle (slash.exec-safe).
        _ = await slashCatalog(for: botID)
        guard
              let gatewayID = commandGatewayID(for: botID),
              let snapshot = try? await commandConnection(gatewayID: gatewayID) else { return .empty }
        let result = try? await snapshot.client.completeSlash(text)
        guard await commandConnectionIsCurrent(snapshot, gatewayID: gatewayID) else { return .empty }
        guard let state = CommandsRuntime.shared.catalogs[gatewayID],
              state.catalogLoaded else {
            // Without catalog authority, complete.slash's generic `skill`
            // kind cannot distinguish a safe bundle from a rejected standalone
            // skill. Fail closed and keep ordinary commands only.
            let completion = result ?? .empty
            return SlashCompletions(items: completion.items.filter { $0.kind != .skill },
                                    replaceFrom: completion.replaceFrom)
        }
        return (result ?? .empty).hidingStandaloneSkills(
            state.unsupportedStandaloneSkillNames)
    }

    /// Resolve an alias/partial on the selected bot's physical gateway.
    public func resolveSlashCommand(_ name: String, botID: String? = nil) async -> SlashCommand? {
        guard mode == .live else { return nil }
        _ = await slashCatalog(for: botID)
        guard let gatewayID = commandGatewayID(for: botID),
              let snapshot = try? await commandConnection(gatewayID: gatewayID) else { return nil }
        let result = try? await snapshot.client.resolveCommand(name)
        guard await commandConnectionIsCurrent(snapshot, gatewayID: gatewayID),
              let catalog = CommandsRuntime.shared.catalogs[gatewayID],
              catalog.catalogLoaded,
              catalog.clientOwner == ObjectIdentifier(snapshot.client),
              catalog.connectionGeneration == snapshot.generation else { return nil }
        return SlashResolvedCommandPolicy.visible(
            result,
            unsupportedStandaloneSkillNames: catalog.unsupportedStandaloneSkillNames)
    }

    // MARK: - Execution

    /// Run "/x …" against the bot's session and drop the result into its chat.
    /// The command is echoed as the user's line (they asked for it, from the
    /// composer or the palette) and `{output}` lands as a system row.
    public func runSlash(_ command: String, botID: String) async {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let line = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        let chat = chat(for: botID)
        let themeID = theme.themeID
        let copy = theme.copy

        chat.messages.append(ChatMessage(author: .user, time: AppModel.clock(), text: line))

        guard mode == .live,
              let route = stateRoute(for: botID) ?? gatewayRoute(for: botID) else {
            chat.messages.append(ChatMessage(author: .system, time: AppModel.clock(),
                                             text: copy.commandsUnavailable(themeID)))
            return
        }

        // c1e25 explicitly rejects standalone skills from slash.exec and asks
        // callers to retry with command.dispatch. That retry is not safe when
        // quick/plugin names collide, so fail before crossing either boundary.
        _ = await slashCatalog(for: botID)
        let commandName = SlashCatalog.normalizedName(
            line.split(whereSeparator: \Character.isWhitespace).first.map(String.init) ?? line)
        if CommandsRuntime.shared.catalogs[route.gatewayID]?
            .unsupportedStandaloneSkillNames.contains(commandName) == true {
            guard bindingRouteMatches(route, botID: botID) else { return }
            chat.messages.append(ChatMessage(
                author: .system, time: AppModel.clock(),
                text: "This standalone skill requires Hermes command.dispatch. "
                    + "Talaria will not replay a slash command through that unsafe fallback; "
                    + "run it from Hermes Desktop or a terminal."))
            return
        }

        // Own the typing indicator only if nothing else is already streaming,
        // and never clear it out from under a live turn.
        let ownsTyping = !chat.isTyping
        if ownsTyping { chat.isTyping = true }
        defer {
            if ownsTyping, !LiveRuntime.shared.workingBotIDs.contains(botID) {
                chat.isTyping = false
            }
        }

        let chatID = ObjectIdentifier(chat)
        do {
            // Capture the route and its client before awaiting a session. A
            // remote bot's runtime session id can collide with one on the
            // primary gateway, so `self.client` is never an execution authority
            // for slash.exec.
            let snapshot = try await commandConnection(gatewayID: route.gatewayID)
            let client = snapshot.client
            let settled = try await ConnectionRegistry.shared.clientPool
                .withCommandConnectionAndTrafficLease(snapshot, for: route.gatewayID) { @MainActor in
                    await attachRoutedEventsIfNeeded(
                        client: client, gatewayID: route.gatewayID)
                    guard bindingRouteMatches(route, botID: botID) else {
                        throw CancellationError()
                    }
                    let sessionID = try await ensureSlashSession(
                        botID: botID, route: route, client: client, hydrate: false)
                    let storedSessionID = chat.storedSessionID
                    guard await commandConnectionIsCurrent(
                        snapshot, gatewayID: route.gatewayID),
                          bindingRouteMatches(route, botID: botID),
                          chats[botID].map({ ObjectIdentifier($0) == chatID }) == true,
                          chat.sessionID == sessionID,
                          chat.storedSessionID == storedSessionID else {
                        throw CancellationError()
                    }
                    let result = try await client.execSlash(
                        sessionID: sessionID, command: line)
                    // A send/skill result crosses two acceptance boundaries:
                    // slash.exec on G1, then the synthesized prompt on G1.
                    // Keep the same pool lease over both and pass the captured
                    // client directly; a helper that resolves by route here can
                    // silently submit to a newly adopted G2.
                    let stillOwned = await commandConnectionIsCurrent(
                        snapshot, gatewayID: route.gatewayID)
                        && CommandsRuntime.shared.connectionGenerations[route.gatewayID]
                            == snapshot.generation
                        && bindingRouteMatches(route, botID: botID)
                        && chats[botID].map({ ObjectIdentifier($0) == chatID }) == true
                        && chat.sessionID == sessionID
                        && chat.storedSessionID == storedSessionID
                    switch result {
                    case let .send(message, notice, display):
                        await submitSlashGenerated(
                            message: message, display: display, notice: notice,
                            botID: botID, route: route, chat: chat,
                            sessionID: sessionID, storedSessionID: storedSessionID,
                            snapshot: snapshot, client: client)
                    case let .skill(message, name, display):
                        await submitSlashGenerated(
                            message: message, display: display,
                            notice: "Running skill /\(name).", botID: botID,
                            route: route, chat: chat, sessionID: sessionID,
                            storedSessionID: storedSessionID,
                            snapshot: snapshot, client: client)
                    case let .output(output, warning):
                        guard stillOwned else { throw CancellationError() }
                        let body = output.trimmingCharacters(in: .whitespacesAndNewlines)
                        chat.messages.append(ChatMessage(
                            author: .system, time: AppModel.clock(),
                            text: body.isEmpty
                                ? copy.commandsNoOutput(themeID) : Self.cap(output: body)))
                        if let warning, !warning.isEmpty {
                            chat.messages.append(ChatMessage(
                                author: .system, time: AppModel.clock(), text: warning))
                        }
                    case let .exec(output):
                        guard stillOwned else { throw CancellationError() }
                        let body = output.trimmingCharacters(in: .whitespacesAndNewlines)
                        chat.messages.append(ChatMessage(
                            author: .system, time: AppModel.clock(),
                            text: body.isEmpty
                                ? copy.commandsNoOutput(themeID) : Self.cap(output: body)))
                    case let .alias(target):
                        guard stillOwned else { throw CancellationError() }
                        chat.messages.append(ChatMessage(
                            author: .system, time: AppModel.clock(),
                            text: "Resolved alias to \(target)."))
                    case let .prefill(message, notice):
                        guard stillOwned else { throw CancellationError() }
                        CommandsRuntime.shared.slashPrefills[route] = SlashPrefillBinding(
                            botID: botID, route: route,
                            connectionGeneration: snapshot.generation,
                            chatID: chatID, storedSessionID: storedSessionID,
                            runtimeSessionID: sessionID, message: message)
                        chat.messages.append(ChatMessage(
                            author: .system, time: AppModel.clock(),
                            text: notice ?? "Draft ready in the composer."))
                    }
                    return true
                }
            guard settled == true else { throw CancellationError() }
        } catch is CancellationError {
            // The captured source was replaced while an await was in flight.
            // Its user echo remains attributed to the former chat, but no
            // completion/error may bleed into the replacement route.
        } catch {
            guard bindingRouteMatches(route, botID: botID),
                  chats[botID].map({ ObjectIdentifier($0) == chatID }) == true else { return }
            chat.messages.append(ChatMessage(
                author: .system, time: AppModel.clock(),
                text: copy.commandsFailed(themeID, command: line,
                                          detail: Self.commandErrorDetail(error))))
        }
    }

    /// The slash RPC already crossed its acceptance boundary. Submit the
    /// generated prompt through the captured client while the caller still
    /// holds G1's pool lease. A failed/invalidated second boundary is retained
    /// as a source-qualified draft; never retry slash.exec or fall back to
    /// command.dispatch (quick/plugin names can shadow it).
    private func submitSlashGenerated(message: String, display: String?, notice: String?,
                                      botID: String, route: GatewayBotRoute, chat: ChatState,
                                      sessionID: String, storedSessionID: String?,
                                      snapshot: GatewayClientPool.ConnectionSnapshot,
                                      client: GatewayClient) async {
        let id = UUID()
        chat.messages.append(ChatMessage(id: id, author: .user, time: AppModel.clock(),
                                         text: display ?? message))
        let composeID = UUID()
        let chatID = ObjectIdentifier(chat)
        let baselineDurableUserRowIDs = Set(chat.messages.compactMap { row in
            row.author == .user ? row.rowID : nil
        })
        let baselineDurableUserRowIDWatermark = baselineDurableUserRowIDs.max()
        let baselineUndurableMatchingUserCount = chat.messages.filter {
            $0.author == .user && $0.rowID == nil && $0.text == message
        }.count
        let lifecycleToken = profileLifecycleGenerationToken(for: botID)

        func retainDraft(ambiguous: Bool = false) {
            normalizeComposeQueueIDs()
            if ambiguous, let storedSessionID, !storedSessionID.isEmpty {
                ChatRuntime.shared.offlineComposeFences[composeID] = OfflineComposeFence(
                    itemID: composeID, botID: botID, text: message, route: route,
                    sessionID: sessionID, storedID: storedSessionID, chatID: chatID,
                    baselineDurableUserRowIDs: baselineDurableUserRowIDs,
                    baselineDurableUserRowIDWatermark: baselineDurableUserRowIDWatermark,
                    baselineUndurableMatchingUserCount: baselineUndurableMatchingUserCount)
            }
            appendComposeQueue(
                botID: botID, text: message, id: composeID, route: route,
                storedID: storedSessionID, sessionID: sessionID, chatID: chatID)
        }

        func settle(_ result: LiveSendResult, ambiguous: Bool = false) {
            if SlashGeneratedSettlementPolicy.requiresDraftRetention(result) {
                retainDraft(ambiguous: ambiguous)
            }
            appendSlashGeneratedSettlement(
                result, notice: notice, botID: botID, route: route, chat: chat,
                chatID: chatID)
        }

        // This helper is called only inside `withCommandConnectionLease`.
        // Check the complete captured binding anyway: profile lifecycle state
        // or the visible ChatState can change independently of pool adoption.
        // In that case slash.exec has already accepted on G1, so the generated
        // prompt becomes a recoverable draft instead of being lost or sent to
        // whatever route now occupies the same UI id.
        func ownsGeneratedSubmission() -> Bool {
            let clientMatches = ObjectIdentifier(snapshot.client)
                == ObjectIdentifier(client)
            let bindingMatches = bindingRouteMatches(route, botID: botID)
                && chats[botID].map({ ObjectIdentifier($0) == chatID }) == true
                && chat.storedSessionID == storedSessionID
                && chat.sessionID == sessionID
                && bindingSessionID(for: botID) == sessionID
            guard SlashGeneratedSubmissionPolicy.decision(
                capturedGeneration: snapshot.generation,
                observedGeneration: CommandsRuntime.shared
                    .connectionGenerations[route.gatewayID],
                clientMatches: clientMatches,
                bindingMatches: bindingMatches) == .submit else { return false }
            guard mode == .live,
                  !mutationIsFenced(botID: botID),
                  chat.messages.contains(where: { $0.id == id }),
                  let lifecycleToken,
                  profileLifecycleAccepts(lifecycleToken) else { return false }
            return true
        }

        let result: LiveSendResult
        guard ownsGeneratedSubmission() else {
            settle(.retained)
            return
        }

        var submitStarted = false
        var ambiguousFailure = false
        do {
            submitStarted = true
            let receipt = try await client.submitPrompt(sessionID: sessionID, text: message)
            try LivePromptSubmitReceipt.requireAccepted(receipt, operation: "Prompt")
            // Acceptance belongs to G1 even if presentation ownership moved
            // during the await. Never queue an accepted prompt for G2 replay.
            ChatRuntime.shared.offlineComposeFences[composeID] = nil
            result = .accepted
        } catch let error as GatewayError where error.code == -3 || error.code == -7 {
            ambiguousFailure = submitStarted
            result = .retained
        } catch {
            if submitStarted, PromptMutationFailure.isAmbiguous(error) {
                ambiguousFailure = true
                result = .retained
            } else if !ownsGeneratedSubmission() {
                result = .retained
            } else {
                let detail = (error as? GatewayError)?.message ?? error.localizedDescription
                chat.messages.append(ChatMessage(author: .system, text: detail))
                result = .failed
            }
        }
        settle(result, ambiguous: ambiguousFailure)
    }

    private func appendSlashGeneratedSettlement(
        _ result: LiveSendResult, notice: String?, botID: String,
        route: GatewayBotRoute, chat: ChatState, chatID: ObjectIdentifier
    ) {
        // A replaced ChatState must not receive G1's status line. The draft is
        // still retained in the source-qualified compose queue above.
        guard bindingRouteMatches(route, botID: botID),
              chats[botID].map({ ObjectIdentifier($0) == chatID }) == true else { return }
        for message in SlashGeneratedSettlementPolicy.messages(for: result, notice: notice) {
            chat.messages.append(ChatMessage(author: .system, time: AppModel.clock(),
                                             text: message))
        }
    }

    /// Slash output is unbounded server-side (/history on a long session runs
    /// to megabytes); the transcript keeps a readable head.
    static func cap(output: String) -> String {
        let limit = 4_000
        guard output.count > limit else { return output }
        return String(output.prefix(limit)) + "\n…"
    }

    static func commandErrorDetail(_ error: Error) -> String {
        (error as? GatewayError)?.message ?? error.localizedDescription
    }

    /// A source-pinned sibling of `ensureSession`. The ordinary helper resolves
    /// its route when it starts; slash.exec has already captured a route/client
    /// pair and must not let an active-gateway switch change either authority.
    private func ensureSlashSession(botID: String, route: GatewayBotRoute,
                                    client: GatewayClient, hydrate: Bool) async throws -> String {
        let runtime = LiveRuntime.shared
        let chat = chat(for: botID)
        if let sessionID = chat.sessionID {
            guard bindingRouteMatches(route, botID: botID) else { throw CancellationError() }
            return sessionID
        }
        if let pending = runtime.attachTasks[botID] {
            let sessionID = try await pending.value
            guard bindingRouteMatches(route, botID: botID), chat.sessionID == sessionID else {
                throw CancellationError()
            }
            return sessionID
        }
        let task = Task<String, Error> { @MainActor in
            try await self.attachCanonicalSession(botID: botID, route: route,
                                                  client: client, hydrate: hydrate)
        }
        runtime.attachTasks[botID] = task
        defer {
            if runtime.attachTasks[botID] == task { runtime.attachTasks[botID] = nil }
        }
        let sessionID = try await task.value
        guard bindingRouteMatches(route, botID: botID), chat.sessionID == sessionID else {
            throw CancellationError()
        }
        return sessionID
    }

    // MARK: - mcp.setup bridge

    /// The oldest unanswered MCP setup request, or nil. `MCPSetupPrompt` reads
    /// this; the agent thread stays parked until it is answered.
    public var mcpSetupPrompt: MCPSetupRequest? {
        let state = CommandsRuntime.shared
        guard var request = state.mcpRequests.first else { return nil }
        if let error = state.mcpResponseErrors[request.route] {
            let retry = "Talaria could not deliver the previous response: \(error) "
                + "This request is still open; choose again to retry."
            request.reason = [request.reason, retry].filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }
        return request
    }

    /// Subscribe to the mcp.setup.* events on the current client. Idempotent
    /// per connection — safe to call from a `.task` that reruns, and it
    /// re-attaches automatically after a reconnect swaps the client.
    public func attachCommandsEventRouter() {
        guard mode == .live, let client,
              let gatewayID = activeGatewayID ?? LiveRuntime.shared.gatewayID,
              !gatewayID.isEmpty else { return }
        let state = CommandsRuntime.shared
        let owner = ObjectIdentifier(client)
        guard state.routerOwner != owner || state.routerGatewayID != gatewayID else { return }

        state.routerPump?.cancel()
        if let previousClient = state.routerClient, let previousHandler = state.routerHandlerID {
            Task { await previousClient.removeEventHandler(previousHandler) }
        }
        if let priorGateway = state.routerGatewayID, priorGateway != gatewayID {
            state.drop(gatewayID: priorGateway)
        } else if state.routerOwner != owner {
            // A reconnect to the same gateway represents a new server process;
            // its old request ids are no longer valid response authority.
            state.drop(gatewayID: gatewayID)
        }
        state.routerOwner = owner
        state.routerGatewayID = gatewayID
        state.routerClient = client
        state.routerHandlerID = nil

        // Same funnel AppModelLive uses: events fan out on the client's actor,
        // one AsyncStream hands them to MainActor in wire order.
        let (stream, continuation) = AsyncStream.makeStream(
            of: GatewayEpochEventDelivery.self)
        state.routerPump = Task { @MainActor [weak self] in
            for await delivery in stream {
                guard state.routerOwner == owner,
                      state.routerGatewayID == gatewayID,
                      state.routerClient === client,
                      await client.isCurrentReadyTransport(
                        epoch: delivery.transportEpoch) else { continue }
                await self?.handleMCPSetupWireEvent(delivery.event, sourceGatewayID: gatewayID,
                                                    sourceClient: client)
            }
        }
        Task { @MainActor in
            let handlerID = await client.addEpochEventHandler { event, transportEpoch in
                guard event.type.hasPrefix("mcp.setup.") else { return }
                continuation.yield(GatewayEpochEventDelivery(
                    event: event, transportEpoch: transportEpoch))
            }
            guard state.routerOwner == owner, state.routerGatewayID == gatewayID,
                  state.routerClient.map(ObjectIdentifier.init) == owner else {
                await client.removeEventHandler(handlerID)
                return
            }
            state.routerHandlerID = handlerID
        }
    }

    /// Route one mcp.setup.* event. Public and de-duplicating so the
    /// integrator can also call it straight from the central event switch
    /// instead of (or as well as) `attachCommandsEventRouter()`.
    /// Accept a wire event only while its exact pooled client/generation still
    /// owns the source. A late callback from a disconnected client cannot
    /// suppress a replacement request with the same request_id.
    func handleMCPSetupWireEvent(_ event: GatewayEvent, sourceGatewayID: String,
                                 sourceClient: GatewayClient) async {
        guard let snapshot = try? await commandConnection(gatewayID: sourceGatewayID),
              ObjectIdentifier(snapshot.client) == ObjectIdentifier(sourceClient),
              await commandConnectionIsCurrent(snapshot, gatewayID: sourceGatewayID) else {
            return
        }
        handleMCPSetupRequest(event, sourceGatewayID: sourceGatewayID,
                              sourceClient: sourceClient,
                              sourceConnectionGeneration: snapshot.generation)
    }

    public func handleMCPSetupRequest(_ event: GatewayEvent, sourceGatewayID: String? = nil,
                                      sourceClient: GatewayClient? = nil,
                                      sourceConnectionGeneration: UInt64 = 0) {
        guard let gatewayID = (sourceGatewayID ?? LiveRuntime.shared.gatewayID)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !gatewayID.isEmpty else { return }
        let state = CommandsRuntime.shared
        guard state.observeConnection(gatewayID: gatewayID,
                                      generation: sourceConnectionGeneration) else { return }
        switch event.type {
        case "mcp.setup.request":
            guard let request = MCPSetupRequest(
                event, gatewayID: gatewayID,
                connectionGeneration: sourceConnectionGeneration) else { return }
            if state.mcpRequests.contains(where: { $0.route == request.route }) {
                // A duplicate replay after handler attachment may be the first
                // copy carrying an exact client binding (tests/local fixtures
                // can insert the presentation request first).
                if let sourceClient {
                    state.mcpClients[request.route] = MCPClientBinding(
                        client: sourceClient,
                        connectionGeneration: sourceConnectionGeneration)
                }
                return
            }
            state.mcpRequests.append(request)
            if let sourceClient {
                state.mcpClients[request.route] = MCPClientBinding(
                    client: sourceClient,
                    connectionGeneration: sourceConnectionGeneration)
            }
        case "mcp.setup.expire":
            // The 600 s window closed server-side; the tool already returned
            // "unanswered". Drop the card rather than answering into the void.
            let requestID = event.payload?["request_id"]?.stringValue ?? ""
            guard !requestID.isEmpty else { return }
            let route = GatewayMCPSetupRoute(
                gatewayID: gatewayID,
                connectionGeneration: sourceConnectionGeneration,
                requestID: requestID)
            state.mcpRequests.removeAll { $0.route == route }
            state.mcpClients.removeValue(forKey: route)
            state.mcpResponsesInFlight.remove(route)
            state.mcpResponseErrors.removeValue(forKey: route)
        default:
            break
        }
    }

    /// Answer a parked MCP setup request and unblock the agent. The card stays
    /// until Hermes acknowledges the exact response, so a transport failure is
    /// visible and retryable rather than becoming a silent ten-minute stall.
    public func answerMCPSetup(_ request: MCPSetupRequest, _ answer: MCPSetupAnswer) {
        let state = CommandsRuntime.shared
        guard !request.gatewayID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              mode == .live else { return }
        let route = request.route
        guard state.mcpRequests.contains(where: { $0.route == route }),
              state.mcpResponsesInFlight.insert(route).inserted else { return }
        state.mcpResponseErrors.removeValue(forKey: route)

        // Answer only the connection which emitted this exact (gateway,
        // generation, request_id) tuple. Falling back to the current primary
        // could unblock an unrelated colliding request on a replacement.
        guard let binding = state.mcpClients[route],
              binding.connectionGeneration == request.connectionGeneration else {
            let detail = "The exact gateway connection for this request is unavailable."
            if state.retainFailedMCPResponse(route: route, detail: detail) {
                appendMCPSetupNotice(request, "\(detail) The request remains open for retry.")
            }
            return
        }
        // The agent reads this detail, not the user — plain English, never a
        // themed string.
        let detail: String
        switch answer {
        case .decline:
            detail = "The user declined \(request.server) on Talaria (iOS). "
                + "Do not propose this server again in this session."
        case .deferToDesktop:
            detail = "Talaria (iOS) cannot run MCP install/enable/authorize flows — "
                + "they need the Hermes desktop app or `hermes mcp install \(request.server)` "
                + "in a terminal. The user saw the request and will set it up there. "
                + "Continue without \(request.server) for now."
        }
        Task { @MainActor in
            let pool = ConnectionRegistry.shared.clientPool
            let snapshot = GatewayClientPool.ConnectionSnapshot(
                client: binding.client, generation: binding.connectionGeneration)
            let settled = await pool.withCommandConnectionLease(
                snapshot, for: request.gatewayID
            ) { @MainActor in
                // Receipt classification and every corresponding state
                // mutation stay inside the exact G1 lease. Releasing before
                // this block used to let G2 purge the request between the wire
                // acknowledgement and its accepted/expired/retry settlement.
                do {
                    let receipt = try await binding.client.respondToMCPSetup(
                        requestID: request.requestID, status: "declined",
                        server: request.server, detail: detail)
                    guard state.mcpRequests.contains(where: { $0.route == route }) else {
                        state.mcpResponsesInFlight.remove(route)
                        return true
                    }
                    switch receipt {
                    case .accepted:
                        let copy = theme.copy, themeID = theme.themeID
                        finishMCPSetupResponse(
                            request, route: route,
                            notice: answer == .decline
                                ? copy.mcpSetupDeclinedLine(themeID, server: request.server)
                                : copy.mcpSetupDeferredLine(themeID, server: request.server))
                    case .expired:
                        finishMCPSetupResponse(
                            request, route: route,
                            notice: "This MCP setup request expired before Hermes received the response. No action was taken.")
                    }
                } catch {
                    guard state.mcpRequests.contains(where: { $0.route == route }) else {
                        state.mcpResponsesInFlight.remove(route)
                        return true
                    }
                    let detail = Self.commandErrorDetail(error)
                    if state.retainFailedMCPResponse(route: route, detail: detail) {
                        appendMCPSetupNotice(
                            request,
                            "Could not answer the MCP setup request: \(detail) The request is still open; try again.")
                    }
                }
                return true
            }
            guard settled == true else {
                finishMCPSetupResponse(
                    request, route: route,
                    notice: "The connection was replaced before Talaria could answer this MCP setup request. No response was delivered.")
                return
            }
        }
    }

    private func finishMCPSetupResponse(_ request: MCPSetupRequest,
                                        route: GatewayMCPSetupRoute,
                                        notice: String) {
        let state = CommandsRuntime.shared
        state.mcpRequests.removeAll { $0.route == route }
        state.mcpClients.removeValue(forKey: route)
        state.mcpResponsesInFlight.remove(route)
        state.mcpResponseErrors.removeValue(forKey: route)
        appendMCPSetupNotice(request, notice)
    }

    private func appendMCPSetupNotice(_ request: MCPSetupRequest, _ notice: String) {
        guard let botID = botID(forSession: request.sessionID,
                               sourceGatewayID: request.gatewayID) else { return }
        chat(for: botID).messages.append(ChatMessage(
            author: .system, time: AppModel.clock(), text: notice))
    }

    /// Drop source-scoped command/MCP state when a retained secondary is
    /// detached. Called by the multi-gateway lifecycle before its client is
    /// released, preventing old request IDs from surviving a reconnect.
    func dropCommandsScope(gatewayID: String) {
        let state = CommandsRuntime.shared
        state.drop(gatewayID: gatewayID)
        guard state.routerGatewayID == gatewayID else { return }
        state.routerPump?.cancel()
        if let client = state.routerClient, let handler = state.routerHandlerID {
            Task { await client.removeEventHandler(handler) }
        }
        state.routerOwner = nil
        state.routerGatewayID = nil
        state.routerClient = nil
        state.routerHandlerID = nil
        state.routerPump = nil
    }

    // MARK: - Demo catalog

    /// Real commands from the upstream registry (hermes_cli/commands.py
    /// COMMAND_REGISTRY) with their real descriptions and argument hints, so
    /// the demo palette shows the true shape of the feature without inventing
    /// a command surface. Running one in demo mode says so.
    static let demoSlashCatalog: [SlashCommand] = [
        SlashCommand(name: "/status", description: "Show session, model, token, and context info",
                     category: "Session"),
        SlashCommand(name: "/context", description: "Show the context window with usage gauge and category breakdown",
                     category: "Session", usage: "all", aliases: ["/ctx"]),
        SlashCommand(name: "/compress", description: "Compress conversation context",
                     category: "Session", usage: "[here [N] | focus topic | --preview]",
                     aliases: ["/compact"]),
        SlashCommand(name: "/undo", description: "Back up N user turns and re-prompt (default 1)",
                     category: "Session", usage: "[N]"),
        SlashCommand(name: "/retry", description: "Retry the last message (resend to agent)",
                     category: "Session"),
        SlashCommand(name: "/save", description: "Export the current conversation",
                     category: "Session", usage: "<json|md|html> [filename] [redact]"),
        SlashCommand(name: "/new", description: "Start a new session (fresh session ID + history)",
                     category: "Session", usage: "[name]", aliases: ["/reset"]),
        SlashCommand(name: "/title", description: "Set a title for the current session",
                     category: "Session", usage: "[name]"),
        SlashCommand(name: "/branch", description: "Branch the current session (explore a different path)",
                     category: "Session", usage: "[name]", aliases: ["/fork"]),
        SlashCommand(name: "/agents", description: "Show active agents and running tasks",
                     category: "Session", aliases: ["/tasks"]),
        SlashCommand(name: "/resume", description: "Resume a previously-named session",
                     category: "Session", usage: "[name]"),
        SlashCommand(name: "/model", description: "Switch model (session-scoped; --global to persist)",
                     category: "Configuration", usage: "[model] [--provider name] [--global]"),
        SlashCommand(name: "/personality", description: "Set a predefined personality",
                     category: "Configuration", usage: "[name]"),
        SlashCommand(name: "/whoami", description: "Show your slash command access (admin / user)",
                     category: "Info"),
        SlashCommand(name: "/profile", description: "Show active profile name and home directory",
                     category: "Info"),
        SlashCommand(name: "/web-research", description: "Research a topic across the open web and summarize",
                     category: "", kind: .skill, usage: "<topic>"),
        SlashCommand(name: "/image-gen", description: "Generate an image from a prompt",
                     category: "", kind: .skill, usage: "<prompt>"),
    ]
}
