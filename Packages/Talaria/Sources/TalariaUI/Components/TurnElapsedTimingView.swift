import SwiftUI
import TalariaKit
import TalariaTheme

enum TurnElapsedTimingPresentation {
    static let liveAnchorID = "chat-turn-elapsed"
}

/// In-transcript whole-turn clock. It exists only while the current chat owns
/// live start evidence; the one-second timeline is therefore never mounted
/// for idle or historical conversations.
struct LiveTurnElapsedTimingView: View {
    let startedAt: Date
    let theme: ThemePack

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = TurnElapsedTimingPolicy.liveSeconds(
                startedAt: startedAt, now: context.date)
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
                Text("Working · \(TurnElapsedTimingPolicy.formatted(seconds: seconds))")
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(theme.sub)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(
                "Assistant working. Elapsed \(TurnElapsedTimingPolicy.formatted(seconds: seconds))"))
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
