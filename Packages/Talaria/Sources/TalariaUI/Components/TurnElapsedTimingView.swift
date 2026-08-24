import SwiftUI
import TalariaKit
import TalariaTheme

enum TurnElapsedTimingPresentation {
    static let liveAnchorID = "chat-turn-elapsed"
}

enum TurnTranscriptActivityRefreshPolicy {
    static let ordinaryInterval: TimeInterval = 1
    static let draftingInterval = TurnTranscriptActivityPolicy.draftingRevealDelay

    static func interval(for activity: TurnTranscriptActivity) -> TimeInterval {
        activity.phase?.kind == .draftingTool ? draftingInterval : ordinaryInterval
    }
}

/// Tail-only activity across text, reasoning, interim and tool gaps. The pure
/// policy decides when a wait deserves a row; TimelineView supplies only the
/// local display clock and never invokes an iOS Live Activity.
struct TurnTranscriptActivityView: View {
    let activity: TurnTranscriptActivity
    let turnStartedAt: Date?
    let isTurnRunning: Bool
    let isAwaitingInput: Bool
    let toolNarratesWait: Bool
    let theme: ThemePack

    var body: some View {
        TimelineView(.periodic(
            from: .now,
            by: TurnTranscriptActivityRefreshPolicy.interval(for: activity)
        )) { context in
            if let presentation = TurnTranscriptActivityPolicy.presentation(
                activity: activity, turnStartedAt: turnStartedAt,
                now: context.date, isTurnRunning: isTurnRunning,
                isAwaitingInput: isAwaitingInput,
                toolNarratesWait: toolNarratesWait
            ) {
                let seconds = TurnElapsedTimingPolicy.liveSeconds(
                    startedAt: presentation.startedAt, now: context.date)
                let label = presentation.label ?? "Working"
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                    Text("\(label) · \(TurnElapsedTimingPolicy.formatted(seconds: seconds))")
                        .font(.caption.monospacedDigit())
                        .lineLimit(2)
                }
                .foregroundStyle(theme.sub)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(
                    "Assistant activity. \(label). Elapsed \(TurnElapsedTimingPolicy.formatted(seconds: seconds))"))
            }
        }
        .id(TurnElapsedTimingPresentation.liveAnchorID)
    }
}

struct SettledTurnDurationView: View {
    let seconds: Int
    let theme: ThemePack

    var body: some View {
        Label(TurnElapsedTimingPolicy.formatted(seconds: seconds), systemImage: "clock")
            .font(.caption.monospacedDigit())
            .foregroundStyle(theme.faint)
            .accessibilityLabel(Text(
                "Turn duration \(TurnElapsedTimingPolicy.formatted(seconds: seconds))"))
    }
}
