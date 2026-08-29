import Foundation
import TalariaKit

extension ChatState {
    /// Start a newly observed turn. Local submit calls replace an idle/stale
    /// origin; message.start preserves the earlier submit origin for the same
    /// turn and only fills an absent value.
    func beginTurnTiming(at date: Date, replacingExisting: Bool) {
        if replacingExisting || turnStartedAt == nil { turnStartedAt = date }
    }

    func clearTurnTiming() {
        turnStartedAt = nil
    }
}

extension AppModel {
    /// Reconcile the whole-turn clock at an authoritative resume/bind. A
    /// gateway timestamp wins when valid. The only local origin that may
    /// survive a missing timestamp is a first-submit bind from nil to its
    /// newly created runtime session; a reconnect or replacement cannot reuse
    /// the old process-local clock as historical evidence.
    func adoptTurnTiming(
        from live: LiveSession,
        in chat: ChatState,
        priorRuntimeSessionID: String?,
        priorLocalStart: Date?,
        now: Date = Date()
    ) {
        guard live.running || live.hasInflightTurn else {
            chat.clearTurnTiming()
            return
        }
        if let gatewayStart = TurnElapsedTimingPolicy.admittedStartDate(
            epochSeconds: live.turnStartedAtEpochSeconds, now: now) {
            chat.turnStartedAt = gatewayStart
        } else if priorRuntimeSessionID == nil, let priorLocalStart {
            chat.turnStartedAt = priorLocalStart
        } else {
            chat.clearTurnTiming()
        }
    }

    /// `session.info` may arrive after submit but before message.start. Keep a
    /// locally observed origin, otherwise prefer Hermes' timestamp, otherwise
    /// begin measuring only from this live observation (never from history).
    func observeTurnTiming(
        from info: SessionInfo,
        in chat: ChatState,
        now: Date = Date()
    ) {
        guard info.running else {
            if chat.messages.last?.isStreaming != true { chat.clearTurnTiming() }
            return
        }
        guard chat.turnStartedAt == nil else { return }
        chat.turnStartedAt = TurnElapsedTimingPolicy.admittedStartDate(
            epochSeconds: info.turnStartedAtEpochSeconds, now: now) ?? now
    }

    /// Close the observed clock and attach it only to the newest assistant row
    /// owned by the current turn floor. A terminal event with no observed
    /// start clears live state but cannot invent a historical duration.
    @discardableResult
    func settleTurnTiming(
        in chat: ChatState,
        botID: String,
        completedAt: Date = Date()
    ) -> Int? {
        let startedAt = chat.turnStartedAt
        chat.clearTurnTiming()
        guard let startedAt,
              let duration = TurnElapsedTimingPolicy.settledSeconds(
                startedAt: startedAt, completedAt: completedAt) else { return nil }
        let floor = min(max(0, ChatRuntime.shared.turnFloor[botID] ?? 0),
                        chat.messages.count)
        guard let index = chat.messages.indices.reversed().first(where: {
            $0 >= floor && chat.messages[$0].author == .bot
        }) else { return duration }
        chat.messages[index].turnDurationSeconds = duration
        return duration
    }
}
