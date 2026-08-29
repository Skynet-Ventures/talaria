import SwiftUI
import TalariaKit
import TalariaTheme

// Inline tool cards under an assistant bubble — desktop renders a tool block
// per call with a structured summary, duration and expandable result; this is
// the phone-sized version of the same thing.
//
// State comes straight off the wire: tool.generating parks a chip while the
// model writes arguments, tool.start names it and shows the ≤80-char argument
// preview, tool.complete stamps duration + summary. Chips stay collapsed —
// a tap opens the full result text, which scrolls in both axes so a 4k-line
// grep result can never take the transcript with it.

// MARK: - List

enum ToolRunPresentationPolicy {
    static let minimumInteractiveDimension: CGFloat = 44
    static let summaryTextStyle: Font.TextStyle = .subheadline
    static let callNameTextStyle: Font.TextStyle = .subheadline
    static let callSubtitleTextStyle: Font.TextStyle = .caption
    static let callDurationTextStyle: Font.TextStyle = .caption2
    static let statusGlyphTextStyle: Font.TextStyle = .caption
    static let disclosureGlyphTextStyle: Font.TextStyle = .caption2
    static let detailHeadingTextStyle: Font.TextStyle = .caption2
    static let detailBodyTextStyle: Font.TextStyle = .caption
    static let copyGlyphTextStyle: Font.TextStyle = .caption

    static func shouldGroup(_ calls: [ToolCall]) -> Bool { calls.count > 1 }

    static func summary(_ calls: [ToolCall]) -> String {
        let running = calls.filter { $0.state == .running }.count
        let failed = calls.filter { $0.state == .failed }.count
        let done = calls.count - running - failed
        var pieces = ["\(calls.count) tools"]
        if done > 0 { pieces.append("\(done) completed") }
        if running > 0 { pieces.append("\(running) running") }
        if failed > 0 { pieces.append("\(failed) failed") }
        return pieces.joined(separator: " · ")
    }
}

public struct ToolCallList: View {
    private let calls: [ToolCall]
    private let theme: ThemePack
    private let copy: CopyPack
    private let accent: Color
    @State private var expanded = false
    @Environment(\.talariaReducedMotion) private var reducedMotion

    public init(calls: [ToolCall], theme: ThemePack, copy: CopyPack, accent: Color) {
        self.calls = calls
        self.theme = theme
        self.copy = copy
        self.accent = accent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.id == .ink ? 2 : 5) {
            if ToolRunPresentationPolicy.shouldGroup(calls) {
                Button {
                    withAnimation(reducedMotion ? nil : .easeOut(duration: 0.18)) {
                        expanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "wrench.and.screwdriver")
                        Text(toolSummary).font(
                            .system(ToolRunPresentationPolicy.summaryTextStyle)
                                .weight(.semibold))
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .foregroundStyle(theme.sub)
                    .padding(.horizontal, 10)
                    .frame(minHeight: ToolRunPresentationPolicy.minimumInteractiveDimension)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tool activity, \(toolSummary)")
                .accessibilityHint(expanded ? "Collapses tool details" : "Shows each tool call")
                if expanded {
                    ForEach(calls) { call in
                        ToolChip(call: call, theme: theme, copy: copy, accent: accent)
                    }
                }
            } else {
                ForEach(calls) { call in
                    ToolChip(call: call, theme: theme, copy: copy, accent: accent)
                }
            }
        }
    }

    private var toolSummary: String {
        ToolRunPresentationPolicy.summary(calls)
    }
}

// MARK: - Chip

public struct ToolChip: View {
    private let call: ToolCall
    private let theme: ThemePack
    private let copy: CopyPack
    private let accent: Color

    @State private var expanded = false
    @State private var copied = false
    @Environment(\.talariaReducedMotion) private var reducedMotion

    public init(call: ToolCall, theme: ThemePack, copy: CopyPack, accent: Color) {
        self.call = call
        self.theme = theme
        self.copy = copy
        self.accent = accent
    }

    private var detail: String? {
        var sections = ["Status: \(statusText)", "Source: \(sourceText)"]
        if let payload = call.arguments, let arguments = payload.displayText,
           !arguments.isEmpty {
            sections.append("Arguments (\(payloadLabel(payload)))\n\(arguments)")
        }
        if let payload = call.result, let result = payload.displayText, !result.isEmpty {
            sections.append("Result (\(payloadLabel(payload)))\n\(result)")
        } else if let result = call.resultText, !result.isEmpty {
            sections.append("Result (text)\n\(result)")
        } else if let summary = call.summary, !summary.isEmpty, summary != call.context {
            sections.append("Result\n\(summary)")
        }
        if let diagnostic = call.diagnostic, !diagnostic.isEmpty {
            sections.append("Note\n\(diagnostic)")
        }
        return sections.count > 2 || call.provenance != .live
            ? sections.joined(separator: "\n\n") : nil
    }

    private var expandable: Bool { detail != nil }

    private var statusText: String {
        switch call.state { case .running: "Running"; case .done: "Completed"; case .failed: "Failed" }
    }

    private var sourceText: String {
        switch call.provenance {
        case .live: "Live event"
        case .stored: "Saved transcript"
        case .projection: "Resume projection"
        case .unmatchedResult: "Unpaired saved result"
        case .malformed: "Malformed saved record"
        }
    }

    private func payloadLabel(_ payload: ToolPayload) -> String {
        let kind: String
        switch payload.kind {
        case .json: kind = "JSON"
        case .text: kind = "text"
        case .unavailable: kind = "unavailable"
        case .malformed: kind = "malformed"
        }
        return payload.isTruncated ? "\(kind), truncated" : kind
    }

    private var stateColor: Color {
        switch call.state {
        case .running: theme.id == .control ? theme.accent : accent
        case .done: theme.id == .ink ? theme.ink.opacity(0.5) : theme.ok
        case .failed: theme.danger
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard expandable else { return }
                withAnimation(reducedMotion ? nil : .easeOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                headline
                    .padding(.vertical, theme.id == .ink ? 5 : 7)
                    .padding(.horizontal, theme.id == .ink ? 8 : 10)
                    .contentShape(Rectangle())
                    .frame(minHeight: ToolRunPresentationPolicy.minimumInteractiveDimension)
            }
            .buttonStyle(.plain)
            .disabled(!expandable)
            .accessibilityLabel("\(call.name), \(statusText)")
            .accessibilityValue(subtitle)
            .accessibilityHint(expandable
                ? (expanded ? "Collapses arguments and result" : "Shows arguments and result")
                : "No additional detail")

            if expanded, let detail {
                resultPanel(detail)
            }
        }
        .background(chrome)
    }

    // MARK: Collapsed line

    private var headline: some View {
        HStack(spacing: 7) {
            glyph
            Text(nameText)
                .font(nameFont)
                .tracking(theme.id == .soft ? 0 : theme.id == .control ? 1 : 0.8)
                .foregroundStyle(theme.id == .control ? stateColor : theme.ink.opacity(0.85))
                .lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(subtitleFont)
                    .italic(theme.id == .ink)
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let duration = durationText {
                Text(duration)
                    .font(.system(
                        ToolRunPresentationPolicy.callDurationTextStyle,
                        design: .monospaced))
                    .foregroundStyle(theme.faint)
                    .monospacedDigit()
            }
            if expandable {
                Image(systemName: "chevron.right")
                    .font(.system(ToolRunPresentationPolicy.disclosureGlyphTextStyle)
                        .weight(.bold))
                    .foregroundStyle(theme.faint)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
    }

    @ViewBuilder private var glyph: some View {
        switch call.state {
        case .running:
            ToolSpinner(color: stateColor, theme: theme)
        case .done:
            Text(verbatim: theme.id == .ink ? "·" : "✓")
                .font(.system(
                    ToolRunPresentationPolicy.statusGlyphTextStyle,
                    design: .monospaced).weight(.bold))
                .foregroundStyle(stateColor)
                .frame(width: 10)
        case .failed:
            Text(verbatim: "✕")
                .font(.system(
                    ToolRunPresentationPolicy.statusGlyphTextStyle,
                    design: .monospaced).weight(.bold))
                .foregroundStyle(stateColor)
                .frame(width: 10)
        }
    }

    private var nameText: String {
        switch theme.id {
        case .soft: call.name
        case .control: call.name.uppercased()
        case .ink: call.name
        }
    }

    private var nameFont: Font {
        switch theme.id {
        case .soft:
            .system(ToolRunPresentationPolicy.callNameTextStyle,
                    design: .rounded).weight(.semibold)
        case .control:
            .system(ToolRunPresentationPolicy.callNameTextStyle,
                    design: .monospaced).weight(.semibold)
        case .ink:
            .system(ToolRunPresentationPolicy.callNameTextStyle,
                    design: .serif).weight(.semibold).smallCaps()
        }
    }

    private var subtitleFont: Font {
        switch theme.id {
        case .soft:
            .system(ToolRunPresentationPolicy.callSubtitleTextStyle,
                    design: .rounded)
        case .control:
            .system(ToolRunPresentationPolicy.callSubtitleTextStyle,
                    design: .monospaced)
        case .ink:
            .system(ToolRunPresentationPolicy.callSubtitleTextStyle,
                    design: .serif)
        }
    }

    /// Argument preview while running; the result summary once it lands.
    private var subtitle: String {
        switch call.state {
        case .running:
            return call.context.isEmpty ? copy.toolRunning(theme.id) : call.context
        case .done:
            if let summary = call.summary, !summary.isEmpty { return summary }
            return call.context
        case .failed:
            if let summary = call.summary, !summary.isEmpty { return summary }
            return copy.toolFailed(theme.id)
        }
    }

    private var durationText: String? {
        guard let seconds = call.durationSeconds, seconds > 0 else { return nil }
        if seconds < 1 { return "\(Int(seconds * 1000))ms" }
        return String(format: "%.1fs", seconds)
    }

    // MARK: Expanded result

    private func resultPanel(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(copy.toolResultHead(theme.id))
                    .font(.system(
                        ToolRunPresentationPolicy.detailHeadingTextStyle,
                        design: .monospaced).weight(.semibold))
                    .tracking(1.4)
                    .foregroundStyle(theme.faint)
                Spacer(minLength: 0)
                Button {
                    copyToPasteboard(text)
                    copied = true
                } label: {
                    Text(copied ? "✓" : "⧉")
                        .font(.system(
                            ToolRunPresentationPolicy.copyGlyphTextStyle,
                            design: .monospaced))
                        .foregroundStyle(copied ? theme.ok : theme.faint)
                        .frame(width: 22, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minWidth: ToolRunPresentationPolicy.minimumInteractiveDimension,
                       minHeight: ToolRunPresentationPolicy.minimumInteractiveDimension)
                .accessibilityLabel(copied ? "Copied tool detail" : "Copy tool detail")
            }
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                Text(text)
                    .font(.system(
                        ToolRunPresentationPolicy.detailBodyTextStyle,
                        design: .monospaced))
                    .lineSpacing(2)
                    .foregroundStyle(theme.sub)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
            }
            .frame(maxHeight: 220)
        }
        .padding(.horizontal, theme.id == .ink ? 8 : 10)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Chrome

    @ViewBuilder private var chrome: some View {
        switch theme.id {
        case .soft:
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.inset)
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(call.state == .running ? accent.opacity(0.3) : theme.line,
                                  lineWidth: 1))
        case .control:
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(call.state == .running ? theme.accent.opacity(0.4)
                                    : theme.lineStrong.opacity(0.7),
                                  lineWidth: 1))
        case .ink:
            // Ledger entry, not a card: one hairline under the row.
            Rectangle()
                .fill(Color.clear)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.line).frame(height: 1)
                }
        }
    }
}

// MARK: - Spinner

/// The running marker: a rotating arc (soft/ink) that also carries the control
/// theme's phosphor glow.
struct ToolSpinner: View {
    var color: Color
    var theme: ThemePack

    @State private var spinning = false
    @Environment(\.talariaReducedMotion) private var reducedMotion

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, style: StrokeStyle(lineWidth: 1.7,
                                              lineCap: theme.id == .ink ? .butt : .round))
            .frame(width: 10, height: 10)
            .rotationEffect(.degrees(TranscriptMotionPolicy.toolSpinnerDegrees(
                spinning: spinning, reducedMotion: reducedMotion
            )))
            .animation(reducedMotion ? nil
                       : .linear(duration: 0.9).repeatForever(autoreverses: false),
                       value: spinning)
            .shadow(color: theme.glowRadius > 0 ? color.opacity(0.7) : .clear, radius: 4)
            .onAppear { spinning = !reducedMotion }
            .onChange(of: reducedMotion) { _, reduced in spinning = !reduced }
    }
}
