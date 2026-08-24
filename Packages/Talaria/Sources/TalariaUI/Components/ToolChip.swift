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

    static func isGeneratedImageSpecialist(_ call: ToolCall) -> Bool {
        call.name == ToolGeneratedImageCodec.exactToolName
            && (call.state == .running
                || GeneratedImageEchoPolicy.hasSuccessfulAuthority(call))
    }

    /// File diffs are review deliverables, not collapsible activity. Preserve
    /// order while grouping only the ordinary calls around them.
    static func presentationRuns(_ calls: [ToolCall]) -> [[ToolCall]] {
        var runs: [[ToolCall]] = []
        var generic: [ToolCall] = []
        func flush() {
            guard !generic.isEmpty else { return }
            runs.append(generic)
            generic.removeAll(keepingCapacity: true)
        }
        for call in calls {
            if (call.fileDiff != nil && ToolDiffCodec.isFileEditTool(call.name))
                || (call.webSearchOutput != nil
                    && ToolWebSearchCodec.isWebSearchTool(call.name))
                || isGeneratedImageSpecialist(call) {
                flush()
                runs.append([call])
            } else {
                generic.append(call)
            }
        }
        flush()
        return runs
    }

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
    private let generatedImageSource: GeneratedImagePresentationSource?

    public init(calls: [ToolCall], theme: ThemePack, copy: CopyPack, accent: Color) {
        self.calls = calls
        self.theme = theme
        self.copy = copy
        self.accent = accent
        generatedImageSource = nil
    }

    init(calls: [ToolCall], theme: ThemePack, copy: CopyPack, accent: Color,
         generatedImageSource: GeneratedImagePresentationSource?) {
        self.calls = calls
        self.theme = theme
        self.copy = copy
        self.accent = accent
        self.generatedImageSource = generatedImageSource
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: theme.id == .ink ? 2 : 5) {
            ForEach(Array(ToolRunPresentationPolicy.presentationRuns(calls).enumerated()),
                    id: \.offset) { _, run in
                if run.count == 1, let call = run.first,
                   call.fileDiff != nil, ToolDiffCodec.isFileEditTool(call.name) {
                    FileDiffCard(call: call, theme: theme, accent: accent)
                } else if run.count == 1, let call = run.first,
                          ToolRunPresentationPolicy.isGeneratedImageSpecialist(call),
                          let generatedImageSource {
                    GeneratedImageCard(call: call, source: generatedImageSource,
                                       theme: theme, accent: accent)
                } else {
                    GenericToolRun(calls: run, theme: theme, copy: copy, accent: accent)
                }
            }
        }
    }
}

private struct GenericToolRun: View {
    let calls: [ToolCall]
    let theme: ThemePack
    let copy: CopyPack
    let accent: Color
    @State private var expanded = false
    @Environment(\.talariaReducedMotion) private var reducedMotion

    var body: some View {
        if ToolRunPresentationPolicy.shouldGroup(calls) {
            Button {
                withAnimation(reducedMotion ? nil : .easeOut(duration: 0.18)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver")
                    Text(ToolRunPresentationPolicy.summary(calls))
                        .font(.system(ToolRunPresentationPolicy.summaryTextStyle).weight(.semibold))
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
            .accessibilityLabel("Tool activity, \(ToolRunPresentationPolicy.summary(calls))")
            .accessibilityHint(expanded ? "Collapses tool details" : "Shows each tool call")
            if expanded {
                ForEach(calls) { call in
                    ToolChip(call: call, theme: theme, copy: copy, accent: accent)
                }
            }
        } else if let call = calls.first {
            ToolChip(call: call, theme: theme, copy: copy, accent: accent)
        }
    }
}

struct FileDiffLine: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable { case addition, removal, context, header }
    var id: Int
    var kind: Kind
    var text: String
}

enum FileDiffPresentationPolicy {
    static let minimumInteractiveDimension: CGFloat = 44
    static let titleTextStyle: Font.TextStyle = .subheadline
    static let metadataTextStyle: Font.TextStyle = .caption
    static let bodyTextStyle: Font.TextStyle = .caption
    static let diffTextIsSelectable = true
    static let disclosureUsesReducedMotionEnvironment = true

    static func lines(_ diff: ToolFileDiff) -> [FileDiffLine] {
        guard diff.state == .available, let unified = diff.unifiedDiff else { return [] }
        return unified.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(ToolDiffCodec.maximumLines).enumerated().map { offset, slice in
                let text = String(slice)
                let kind: FileDiffLine.Kind
                if text.hasPrefix("+") && !text.hasPrefix("+++") {
                    kind = .addition
                } else if text.hasPrefix("-") && !text.hasPrefix("---") {
                    kind = .removal
                } else if text.hasPrefix("@@") || text.hasPrefix("diff --git")
                            || text.hasPrefix("index ") || text.hasPrefix("---")
                            || text.hasPrefix("+++") {
                    kind = .header
                } else {
                    kind = .context
                }
                return FileDiffLine(id: offset, kind: kind, text: text)
            }
    }

    static func basename(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "Changed file" }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        return normalized.split(separator: "/").last.map(String.init) ?? normalized
    }

    static func accessibilityValue(_ diff: ToolFileDiff, failed: Bool) -> String {
        var parts = [failed ? "File edit failed" : "File edit completed",
                     "\(diff.addedLines) additions", "\(diff.removedLines) removals"]
        if diff.state == .malformed { parts.append("diff malformed") }
        if diff.isTruncated { parts.append("preview truncated") }
        return parts.joined(separator: ", ")
    }
}

/// Mobile specialist disclosure for one bounded, literal file-edit diff.
private struct FileDiffCard: View {
    let call: ToolCall
    let theme: ThemePack
    let accent: Color

    @State private var expanded = true
    @State private var copied = false
    @Environment(\.talariaReducedMotion) private var reducedMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var diff: ToolFileDiff { call.fileDiff! }
    private var rows: [FileDiffLine] { FileDiffPresentationPolicy.lines(diff) }
    private var failed: Bool { call.state == .failed }
    private var title: String { FileDiffPresentationPolicy.basename(diff.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reducedMotion ? nil : .easeOut(duration: 0.18)) {
                    expanded.toggle()
                }
            } label: {
                HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center,
                       spacing: 7) {
                    Text(verbatim: failed ? "✕" : (theme.id == .ink ? "·" : "✓"))
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .foregroundStyle(failed ? theme.danger : theme.ok)
                        .frame(width: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: title)
                            .font(.system(FileDiffPresentationPolicy.titleTextStyle).weight(.semibold))
                            .foregroundStyle(failed ? theme.danger : theme.ink.opacity(0.88))
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                            .truncationMode(.middle)
                        if dynamicTypeSize.isAccessibilitySize,
                           let path = diff.path, path != title {
                            Text(verbatim: path)
                                .font(.system(FileDiffPresentationPolicy.metadataTextStyle,
                                              design: .monospaced))
                                .foregroundStyle(theme.faint)
                                .lineLimit(3).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 4)
                    if diff.addedLines > 0 {
                        Text(verbatim: "+\(diff.addedLines)").foregroundStyle(theme.ok)
                    }
                    if diff.removedLines > 0 {
                        Text(verbatim: "−\(diff.removedLines)").foregroundStyle(theme.danger)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(.caption2).weight(.bold)).foregroundStyle(theme.faint)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.system(FileDiffPresentationPolicy.metadataTextStyle,
                              design: .monospaced).weight(.semibold))
                .padding(.vertical, theme.id == .ink ? 5 : 7)
                .padding(.horizontal, theme.id == .ink ? 8 : 10)
                .frame(minHeight: FileDiffPresentationPolicy.minimumInteractiveDimension)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("File diff, \(title)")
            .accessibilityValue(FileDiffPresentationPolicy.accessibilityValue(diff, failed: failed))
            .accessibilityHint(expanded ? "Double-tap to hide the diff." : "Double-tap to show the diff.")

            if expanded { diffBody }
        }
        .background(chrome)
    }

    private var diffBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if failed {
                Text(call.summary?.isEmpty == false
                     ? call.summary! : "The file-edit tool reported a failure.")
                    .font(.system(FileDiffPresentationPolicy.titleTextStyle))
                    .foregroundStyle(theme.danger)
                    .textSelection(.enabled)
            }
            if let diagnostic = diff.diagnostic {
                Label(diagnostic, systemImage: diff.state == .malformed
                      ? "exclamationmark.triangle" : "scissors")
                    .font(.system(FileDiffPresentationPolicy.titleTextStyle))
                    .foregroundStyle(diff.state == .malformed ? theme.danger : theme.faint)
                    .textSelection(.enabled)
            }
            if !rows.isEmpty {
                HStack(spacing: 6) {
                    Text(verbatim: diff.path ?? diff.sourceField.rawValue)
                        .font(.system(FileDiffPresentationPolicy.metadataTextStyle,
                                      design: .monospaced).weight(.semibold))
                        .foregroundStyle(theme.faint).lineLimit(2).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button {
                        guard let unified = diff.unifiedDiff else { return }
                        copyToPasteboard(unified)
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption).foregroundStyle(copied ? theme.ok : theme.faint)
                            .frame(minWidth: FileDiffPresentationPolicy.minimumInteractiveDimension,
                                   minHeight: FileDiffPresentationPolicy.minimumInteractiveDimension)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(copied ? "Diff copied" : "Copy diff")
                    .accessibilityHint("Copies the bounded diff preview to the clipboard.")
                }
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            Text(verbatim: row.text.isEmpty ? " " : row.text)
                                .font(.system(FileDiffPresentationPolicy.bodyTextStyle,
                                              design: .monospaced))
                                .foregroundStyle(foreground(for: row.kind))
                                .padding(.horizontal, 7).padding(.vertical, 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(background(for: row.kind))
                                .fixedSize(horizontal: true, vertical: false)
                                .textSelection(.enabled)
                                .accessibilityLabel(accessibilityLabel(for: row))
                        }
                    }
                }
                .frame(maxHeight: 240)
                .accessibilityLabel("Selectable unified diff preview")
            }
        }
        .padding(.horizontal, theme.id == .ink ? 8 : 10)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func foreground(for kind: FileDiffLine.Kind) -> Color {
        switch kind {
        case .addition: theme.ok
        case .removal: theme.danger
        case .header: theme.faint
        case .context: theme.sub
        }
    }

    private func background(for kind: FileDiffLine.Kind) -> Color {
        switch kind {
        case .addition: theme.ok.opacity(0.1)
        case .removal: theme.danger.opacity(0.1)
        case .context, .header: .clear
        }
    }

    private func accessibilityLabel(for row: FileDiffLine) -> String {
        switch row.kind {
        case .addition: "Added: \(String(row.text.dropFirst()))"
        case .removal: "Removed: \(String(row.text.dropFirst()))"
        case .context: "Context: \(row.text)"
        case .header: "Diff header: \(row.text)"
        }
    }

    @ViewBuilder private var chrome: some View {
        switch theme.id {
        case .soft:
            RoundedRectangle(cornerRadius: 12).fill(theme.inset)
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(failed ? theme.danger.opacity(0.5) : accent.opacity(0.25),
                                  lineWidth: 1))
        case .control:
            RoundedRectangle(cornerRadius: 6).fill(theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(failed ? theme.danger.opacity(0.6)
                                  : theme.lineStrong.opacity(0.7), lineWidth: 1))
        case .ink:
            Rectangle().fill(Color.clear)
                .overlay(alignment: .bottom) { Rectangle().fill(theme.line).frame(height: 1) }
        }
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
        if call.structuredOutput == nil,
           let payload = call.result, let result = payload.displayText, !result.isEmpty {
            sections.append("Result (\(payloadLabel(payload)))\n\(result)")
        } else if call.structuredOutput == nil,
                  let result = call.resultText, !result.isEmpty {
            sections.append("Result (text)\n\(result)")
        } else if let residual = call.structuredOutput?.residualText,
                  !residual.isEmpty {
            sections.append("Result metadata\n\(residual)")
        } else if let summary = call.summary, !summary.isEmpty, summary != call.context {
            sections.append("Result\n\(summary)")
        }
        if let diagnostic = call.diagnostic, !diagnostic.isEmpty {
            sections.append("Note\n\(diagnostic)")
        }
        return sections.count > 2 || call.provenance != .live
            ? sections.joined(separator: "\n\n") : nil
    }

    private var expandable: Bool {
        (detail != nil || call.structuredOutput != nil || call.webSearchOutput != nil)
            && call.state != .running
    }

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

            if expanded {
                if let output = call.structuredOutput {
                    StructuredToolOutputView(output: output, theme: theme)
                }
                if let output = call.webSearchOutput,
                   ToolWebSearchCodec.isWebSearchTool(call.name) {
                    WebSearchResultsView(output: output, theme: theme)
                }
                if let detail { resultPanel(detail) }
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

private struct WebSearchResultsView: View {
    let output: ToolWebSearchOutput
    let theme: ThemePack

    private var presented: ToolWebSearchOutput {
        ToolWebSearchOutput(
            state: output.state, query: output.query, hits: output.hits,
            isTruncated: output.isTruncated, diagnostic: output.diagnostic)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let query = presented.query {
                Text(verbatim: query)
                    .font(.system(.subheadline))
                    .foregroundStyle(theme.sub)
                    .textSelection(.enabled)
                    .accessibilityLabel("Search query, \(query)")
            }
            if let diagnostic = presented.diagnostic {
                Text(verbatim: diagnostic)
                    .font(.system(.caption))
                    .foregroundStyle(presented.state == .malformed ? theme.danger : theme.faint)
                    .textSelection(.enabled)
            }
            if presented.state == .available, presented.hits.isEmpty {
                Text("No search results were retained.")
                    .font(.system(.caption)).foregroundStyle(theme.faint)
            }
            ForEach(presented.hits) { hit in
                WebSearchHitRow(hit: hit, theme: theme)
            }
        }
        .padding(.horizontal, theme.id == .ink ? 8 : 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}

private struct WebSearchHitRow: View {
    let hit: ToolWebSearchHit
    let theme: ThemePack
    @State private var copiedLink = false
    @State private var copiedSnippet = false

    private var safeURL: String? { ToolWebSearchCodec.admittedURL(hit.url) }
    private var host: String? { WebSearchPresentationPolicy.visibleDestinationHost(hit) }
    private var title: String { hit.title.isEmpty ? (host ?? "Search result") : hit.title }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    if let rawURL = safeURL, let url = URL(string: rawURL) {
                        Link(destination: url) {
                            HStack(spacing: 4) {
                                Text(verbatim: title).lineLimit(3)
                                Image(systemName: "arrow.up.right").accessibilityHidden(true)
                            }
                            .font(.system(WebSearchPresentationPolicy.titleTextStyle)
                                .weight(.semibold))
                            .foregroundStyle(theme.accent)
                            .frame(minHeight: WebSearchPresentationPolicy.minimumInteractiveDimension,
                                   alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .accessibilityLabel(WebSearchPresentationPolicy.accessibilityLabel(hit))
                        .accessibilityHint("Opens this destination in your browser.")
                    } else {
                        Text(verbatim: title)
                            .font(.system(WebSearchPresentationPolicy.titleTextStyle)
                                .weight(.semibold))
                            .foregroundStyle(theme.ink)
                    }
                    if let host {
                        Text(verbatim: host)
                            .font(.system(WebSearchPresentationPolicy.hostTextStyle)
                                .weight(.medium))
                            .foregroundStyle(theme.faint)
                            .textSelection(.enabled)
                            .accessibilityLabel("Destination host, \(host)")
                    }
                }
                Spacer(minLength: 0)
                if let rawURL = safeURL {
                    Button {
                        copyToPasteboard(rawURL); copiedLink = true
                    } label: {
                        Image(systemName: copiedLink ? "checkmark" : "doc.on.doc")
                            .frame(minWidth: WebSearchPresentationPolicy.minimumInteractiveDimension,
                                   minHeight: WebSearchPresentationPolicy.minimumInteractiveDimension)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(copiedLink ? "Link copied" : "Copy result link")
                }
            }
            if let snippet = hit.snippet {
                HStack(alignment: .top, spacing: 4) {
                    Text(verbatim: snippet)
                        .font(.system(WebSearchPresentationPolicy.snippetTextStyle))
                        .foregroundStyle(theme.sub)
                        .lineLimit(5)
                        .textSelection(.enabled)
                        .accessibilityLabel("Snippet, \(snippet)")
                    Spacer(minLength: 0)
                    Button {
                        copyToPasteboard(snippet); copiedSnippet = true
                    } label: {
                        Image(systemName: copiedSnippet ? "checkmark" : "doc.on.doc")
                            .frame(minWidth: WebSearchPresentationPolicy.minimumInteractiveDimension,
                                   minHeight: WebSearchPresentationPolicy.minimumInteractiveDimension)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(copiedSnippet ? "Snippet copied" : "Copy snippet")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

private struct StructuredToolOutputView: View {
    let output: ToolStructuredOutput
    let theme: ThemePack

    @ScaledMetric(relativeTo: .body) private var diagnosticSize: CGFloat = 10.5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let diagnostic = output.diagnostic {
                Text(diagnostic)
                    .font(theme.body(diagnosticSize))
                    .foregroundStyle(theme.faint)
            }
            if let stdout = output.stdout {
                ToolOutputSection(label: "stdout", stream: stdout, theme: theme)
            }
            if let stderr = output.stderr {
                // stderr is a channel label, not a failure claim. Git, npm and
                // many healthy CLIs write informational progress here.
                ToolOutputSection(label: "stderr", stream: stderr, theme: theme)
            }
        }
        .padding(.horizontal, theme.id == .ink ? 8 : 10)
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
    }
}

private struct ToolOutputSection: View {
    let label: String
    let stream: ToolOutputStream
    let theme: ThemePack

    @State private var copied = false
    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = 10.5
    @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 9

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label.uppercased())
                    .font(theme.mono(labelSize, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(theme.faint)
                Spacer(minLength: 0)
                if !stream.copyText.isEmpty {
                    Button {
                        copyToPasteboard(stream.copyText)
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(copied ? theme.ok : theme.faint)
                            .frame(minWidth: ToolRunPresentationPolicy.minimumInteractiveDimension,
                                   minHeight: ToolRunPresentationPolicy.minimumInteractiveDimension)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(copied ? "\(label) copied" : "Copy \(label)")
                    .accessibilityHint("Copies the bounded plain-text \(label) output.")
                }
            }
            if let diagnostic = stream.diagnostic {
                Text(diagnostic)
                    .font(theme.body(textSize))
                    .foregroundStyle(stream.state == .malformed ? theme.danger : theme.faint)
            }
            if stream.state == .available, !stream.segments.isEmpty {
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    ansiText
                        .font(theme.mono(textSize))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                }
                .frame(maxHeight: 180)
                // Expose one bounded stream summary. Styled Text descendants
                // must not independently hand VoiceOver the full 10k preview.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(label) output")
                .accessibilityValue(ToolOutputPresentationPolicy.accessibilityValue(stream))
            }
        }
    }

    private var ansiText: Text {
        stream.segments.reduce(Text("")) { partial, segment in
            var piece = Text(segment.text).foregroundColor(color(for: segment.foreground))
            if segment.bold { piece = piece.bold() }
            return partial + piece
        }
    }

    private func color(for foreground: ToolANSISegment.Foreground?) -> Color {
        guard let foreground else { return theme.sub }
        switch foreground {
        case .black: return theme.ink.opacity(0.72)
        case .red: return .red.opacity(0.84)
        case .green: return .green.opacity(0.82)
        case .yellow: return .orange.opacity(0.88)
        case .blue: return .blue.opacity(0.84)
        case .magenta: return .purple.opacity(0.84)
        case .cyan: return .cyan.opacity(0.84)
        case .white: return theme.ink.opacity(0.75)
        case .brightBlack: return theme.faint
        case .brightRed: return .red
        case .brightGreen: return .green
        case .brightYellow: return .orange
        case .brightBlue: return .blue
        case .brightMagenta: return .pink
        case .brightCyan: return .cyan
        case .brightWhite: return theme.ink
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
