import Foundation
import TalariaKit

/// Process-local owner for the foreground `SubagentLiveStore`.  AppModel has
/// no extension storage, so this mirrors the other live runtime side tables
/// while keeping every operation keyed by an exact gateway/runtime-session
/// fence.
@MainActor
final class SubagentLiveRuntime {
    static let shared = SubagentLiveRuntime()

    let store = SubagentLiveStore()

    private init() {}

    func activate(gatewayID: String?, parentRuntimeSessionID: String) {
        guard let gatewayID,
              let source = SubagentSourceFence(gatewayID: gatewayID,
                                                parentRuntimeSessionID: parentRuntimeSessionID)
        else { return }
        store.activate(source)
    }

    func tearDown(gatewayID: String?, parentRuntimeSessionID: String) {
        guard let gatewayID,
              let source = SubagentSourceFence(gatewayID: gatewayID,
                                                parentRuntimeSessionID: parentRuntimeSessionID)
        else { return }
        store.tearDown(source)
    }
}
