import Foundation
import TalariaKit

extension AppModel {
    /// Immutable, source-qualified data for a later presentation surface. No
    /// mutable store internals escape through AppModel.
    public func subagentLiveSnapshot(for source: SubagentSourceFence) -> SubagentLiveSnapshot {
        SubagentLiveRuntime.shared.store.snapshot(for: source)
    }

    /// Read one branch only by its full gateway/parent/id key. A visible goal
    /// or model label is intentionally not accepted as a lookup key.
    public func subagentLiveSummary(for key: SubagentNodeKey) -> SubagentNodeSummary? {
        SubagentLiveRuntime.shared.store.summary(for: key)
    }

    /// Return the durable child key only while the visible node still belongs
    /// to this exact bot/gateway/runtime source and the current profile's
    /// source-qualified stored-session list independently contains it.
    /// Merely receiving `child_session_id` is evidence, not navigation
    /// authority: an absent/stale row remains inert in the presentation.
    public func provenSubagentChildStoredSessionID(
        for node: SubagentNodeSummary, botID: String,
        source: SubagentSourceFence
    ) -> String? {
        guard let currentNode = SubagentLiveRuntime.shared.store.summary(for: node.key),
              currentNode.childSession == node.childSession else { return nil }
        let route = stateRoute(for: botID) ?? gatewayRoute(for: botID)
        let current = chats[botID]
        return SubagentLivePresentationPolicy.provenChildStoredSessionID(
            node: currentNode,
            source: source,
            currentGatewayID: route?.gatewayID,
            currentRuntimeSessionID: current?.sessionID,
            availableStoredSessionIDs: Set(current?.storedSessions.map(\.id) ?? [])
        )
    }

    /// Synchronous tap boundary for child navigation. The exact-current proof
    /// above and `openStoredSession` both run on MainActor without an await in
    /// between, so route/profile/session ownership cannot change between the
    /// check and the existing durable-session open transaction.
    @discardableResult
    public func openProvenSubagentChildSession(
        for node: SubagentNodeSummary, botID: String,
        source: SubagentSourceFence
    ) -> Bool {
        guard let storedID = provenSubagentChildStoredSessionID(
            for: node, botID: botID, source: source
        ) else { return false }
        openStoredSession(storedID, botID: botID)
        return true
    }

    /// Admit one parent-session `subagent.*` frame into the foreground-only
    /// reducer.  The raw event has already been received from a particular
    /// client, but the gateway id and current ChatState ownership are both
    /// checked again here so an old routed pump cannot publish into a reused
    /// runtime sid.
    func routeSubagentEvent(_ event: GatewayEvent, typed: TypedGatewayEvent,
                            sourceGatewayID: String?) {
        guard mode == .live,
              case .subagent(let subagent) = typed,
              let sourceGatewayID,
              subagent.parentRuntimeSessionID == event.sessionID,
              let botID = botID(forSession: event.sessionID,
                                sourceGatewayID: sourceGatewayID),
              currentChatOwnsMessageEvent(botID: botID, sessionID: event.sessionID,
                                          sourceGatewayID: sourceGatewayID),
              let source = SubagentSourceFence(gatewayID: sourceGatewayID,
                                                parentRuntimeSessionID: event.sessionID),
              SubagentLiveRuntime.shared.store.isActive(source)
        else { return }
        _ = SubagentLiveRuntime.shared.store.reduce(
            subagent, source: source, inboundSequence: event.inboundSequence)
    }
}
