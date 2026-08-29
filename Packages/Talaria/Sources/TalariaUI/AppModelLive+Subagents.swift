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
