import Foundation
import SwiftUI
import TalariaTheme
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Block-level markdown for chat bubbles. Desktop renders the transcript with
// streamdown/assistant-ui; this is the dependency-free native equivalent:
// blocks (paragraphs, headings, bullet/ordered lists, fenced code, blockquotes,
// rules, pipe tables) are parsed here, while inline spans ride Foundation's
// AttributedString markdown so bold/italic/code/links stay one code path.
//
// Two rules drive the layout: a code block never wraps (it scrolls inside its
// own horizontal scroller, so a 400-char shell line cannot blow up the bubble
// or the transcript), and nothing else is greedy — a plain-text bubble still
// hugs its content exactly like the pre-markdown Text did.

// MARK: - Block model

struct MarkdownBlock: Identifiable {
    let id = UUID()
    var kind: Kind

    enum Kind {
        case paragraph(AttributedString)
        case heading(level: Int, text: AttributedString)
        case list(items: [MarkdownListItem], ordered: Bool)
        case code(language: String?, source: String)
        /// Nested blocks — a quote can carry lists and code like any other body.
        case quote([MarkdownBlock])
        case rule
        case table(header: [AttributedString], rows: [[AttributedString]])
    }
}

struct MarkdownListItem: Identifiable {
    let id = UUID()
    /// Nesting depth (two spaces or one tab per level).
    var indent: Int
    /// Ordered-list number; nil for bullets.
    var ordinal: Int?
    /// Task-list state for `- [ ]` / `- [x]` items.
    var checked: Bool?
    var content: AttributedString
}

// MARK: - Parser

enum MarkdownParser {

    static func parse(_ source: String,
                      isCancelled: () -> Bool = { false }) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(MarkdownBlock(kind: .paragraph(inline(paragraph.joined(separator: "\n")))))
            paragraph.removeAll()
        }

        while index < lines.count {
            if isCancelled() { break }
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code — consumed verbatim, including blank lines. An
            // unterminated fence (a stream still mid-block) runs to the end,
            // which is what the user is watching happen.
            if let fence = fenceToken(trimmed) {
                flushParagraph()
                let language = String(trimmed.dropFirst(fence.count))
                    .trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count, !isCancelled() {
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        index += 1
                        break
                    }
                    body.append(lines[index])
                    index += 1
                }
                blocks.append(MarkdownBlock(kind: .code(language: language.isEmpty ? nil : language,
                                                        source: body.joined(separator: "\n"))))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .rule))
                index += 1
                continue
            }

            if let (level, text) = heading(trimmed) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .heading(level: level, text: inline(text))))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count, !isCancelled() {
                    let line = lines[index].trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix(">") else { break }
                    var stripped = String(line.dropFirst())
                    if stripped.hasPrefix(" ") { stripped.removeFirst() }
                    quoted.append(stripped)
                    index += 1
                }
                blocks.append(MarkdownBlock(kind: .quote(parse(
                    quoted.joined(separator: "\n"), isCancelled: isCancelled))))
                continue
            }

            if let table = parseTable(lines, from: &index, isCancelled: isCancelled) {
                flushParagraph()
                blocks.append(table)
                continue
            }

            if listMarker(raw) != nil {
                flushParagraph()
                var items: [MarkdownListItem] = []
                var ordered = false
                while index < lines.count, !isCancelled(),
                      let marker = listMarker(lines[index]) {
                    ordered = ordered || marker.ordinal != nil
                    items.append(MarkdownListItem(indent: marker.indent, ordinal: marker.ordinal,
                                                  checked: marker.checked,
                                                  content: inline(marker.content)))
                    index += 1
                    // Indented continuation lines belong to the item above.
                    while index < lines.count, !isCancelled(),
                          listMarker(lines[index]) == nil,
                          lines[index].hasPrefix(" ") || lines[index].hasPrefix("\t"),
                          !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                        let more = lines[index].trimmingCharacters(in: .whitespaces)
                        items[items.count - 1].content += AttributedString(" ") + inline(more)
                        index += 1
                    }
                }
                blocks.append(MarkdownBlock(kind: .list(items: items, ordered: ordered)))
                continue
            }

            paragraph.append(raw)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: Line classification

    private static func fenceToken(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let squeezed = trimmed.filter { !$0.isWhitespace }
        guard squeezed.count >= 3 else { return false }
        return squeezed.allSatisfy { $0 == "-" } || squeezed.allSatisfy { $0 == "*" }
            || squeezed.allSatisfy { $0 == "_" }
    }

    private static func heading(_ trimmed: String) -> (Int, String)? {
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }
        guard hashes.count <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return (hashes.count, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func listMarker(_ line: String)
    -> (indent: Int, ordinal: Int?, checked: Bool?, content: String)? {
        var leading = 0
        for character in line {
            if character == " " { leading += 1 }
            else if character == "\t" { leading += 4 }
            else { break }
        }
        let rest = line.trimmingCharacters(in: .whitespaces)
        let indent = min(leading / 2, 4)

        for bullet in ["- ", "* ", "+ "] where rest.hasPrefix(bullet) {
            var content = String(rest.dropFirst(2))
            var checked: Bool?
            if content.hasPrefix("[ ] ") { checked = false; content = String(content.dropFirst(4)) }
            else if content.lowercased().hasPrefix("[x] ") { checked = true; content = String(content.dropFirst(4)) }
            return (indent, nil, checked, content)
        }

        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") {
                return (indent, Int(digits), nil, String(after.dropFirst(2)))
            }
        }
        return nil
    }

    /// GFM pipe table: a header row followed by a `|---|:--:|` separator.
    private static func parseTable(_ lines: [String], from index: inout Int,
                                   isCancelled: () -> Bool) -> MarkdownBlock? {
        let header = lines[index].trimmingCharacters(in: .whitespaces)
        guard header.hasPrefix("|"), index + 1 < lines.count else { return nil }
        let divider = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard divider.hasPrefix("|"), divider.contains("-"),
              divider.allSatisfy({ "|-: ".contains($0) }) else { return nil }

        let headerCells = cells(header).map(inline)
        var rows: [[AttributedString]] = []
        index += 2
        while index < lines.count, !isCancelled() {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("|") else { break }
            rows.append(cells(line).map(inline))
            index += 1
        }
        return MarkdownBlock(kind: .table(header: headerCells, rows: rows))
    }

    private static func cells(_ row: String) -> [String] {
        var trimmed = row
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Inline spans only — block syntax is already peeled off by the caller,
    /// and whitespace is preserved so soft line breaks survive.
    static func inline(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// Foreground strings painted by MarkdownText, in exact segment order.
    /// Markdown delimiters and link destinations are absent because the
    /// projection uses the same parsed AttributedString characters as the UI.
    static func searchSegments(_ source: String,
                               isCancelled: () -> Bool = { false }) -> [String] {
        searchSegments(in: parse(source, isCancelled: isCancelled))
    }

    private static func searchSegments(in blocks: [MarkdownBlock]) -> [String] {
        blocks.flatMap { block in
            switch block.kind {
            case .paragraph(let text), .heading(_, let text):
                return [String(text.characters)]
            case .list(let items, _):
                return items.map { String($0.content.characters) }
            case .code(_, let source):
                return [source]
            case .quote(let nested):
                return searchSegments(in: nested)
            case .rule:
                return []
            case .table(let header, let rows):
                return header.map { String($0.characters) }
                    + rows.flatMap { $0.map { String($0.characters) } }
            }
        }
    }

    static func segmentCount(_ block: MarkdownBlock) -> Int {
        switch block.kind {
        case .paragraph, .heading, .code: return 1
        case .list(let items, _): return items.count
        case .quote(let nested): return nested.reduce(0) { $0 + segmentCount($1) }
        case .rule: return 0
        case .table(let header, let rows):
            return header.count + rows.reduce(0) { $0 + $1.count }
        }
    }
}

// MARK: - Parse cache

/// A streaming bubble re-parses on every delta; a bounded cache keeps that off
/// the render path for everything already on screen.
@MainActor
enum MarkdownCache {
    private static var store: [String: [MarkdownBlock]] = [:]
    private static var order: [String] = []
    private static let limit = 160

    static func blocks(for text: String) -> [MarkdownBlock] {
        if let hit = store[text] { return hit }
        let parsed = MarkdownParser.parse(text)
        store[text] = parsed
        order.append(text)
        if order.count > limit {
            store.removeValue(forKey: order.removeFirst())
        }
        return parsed
    }
}

// MARK: - Inline markdown (single-line callers)

/// Inline markdown (bold/italic/code) with whitespace preserved; falls back to
/// the raw text on parse failure. Block syntax goes through `MarkdownText`.
func chatMarkdown(_ text: String) -> AttributedString {
    MarkdownParser.inline(text)
}

func transcriptFindHighlighted(_ attributed: AttributedString, query: String,
                               occurrence: Int, color: Color,
                               foreground: Color = .black) -> AttributedString {
    let plain = String(attributed.characters)
    guard let selected = TranscriptFindPolicy.range(
        of: query, occurrence: occurrence, in: plain) else { return attributed }
    let lowerOffset = plain.distance(from: plain.startIndex, to: selected.lowerBound)
    let upperOffset = plain.distance(from: plain.startIndex, to: selected.upperBound)
    var output = attributed
    let lower = output.characters.index(output.characters.startIndex, offsetBy: lowerOffset)
    let upper = output.characters.index(output.characters.startIndex, offsetBy: upperOffset)
    output[lower..<upper].backgroundColor = color
    output[lower..<upper].foregroundColor = foreground
    return output
}

// MARK: - Pasteboard

/// Copy helper shared by the code-block button and the message long-press menu.
func copyToPasteboard(_ text: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #elseif canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

// MARK: - MarkdownText

public struct MarkdownText: View {
    private let source: String
    private let theme: ThemePack
    private let size: CGFloat
    private let color: Color
    private let lineSpacing: CGFloat
    /// True inside a bubble painted with the accent (soft/ink user bubbles):
    /// code panels and rules are then derived from the text color, not the
    /// page tokens, so they stay legible on the gradient.
    private let onAccent: Bool
    private let findHighlight: TranscriptFindSelection?

    public init(_ text: String, theme: ThemePack, size: CGFloat, color: Color,
                lineSpacing: CGFloat = 3, onAccent: Bool = false) {
        self.source = text
        self.theme = theme
        self.size = size
        self.color = color
        self.lineSpacing = lineSpacing
        self.onAccent = onAccent
        self.findHighlight = nil
    }

    init(_ text: String, theme: ThemePack, size: CGFloat, color: Color,
         lineSpacing: CGFloat = 3, onAccent: Bool = false,
         findHighlight: TranscriptFindSelection?) {
        self.source = text
        self.theme = theme
        self.size = size
        self.color = color
        self.lineSpacing = lineSpacing
        self.onAccent = onAccent
        self.findHighlight = findHighlight
    }

    public var body: some View {
        let blocks = MarkdownCache.blocks(for: source)
        // The overwhelmingly common case is one paragraph — render it as the
        // bare Text it was before block support, so bubbles keep hugging.
        if blocks.count == 1, case .paragraph(let text) = blocks[0].kind {
            paragraphText(text, segment: 0)
        } else {
            VStack(alignment: .leading, spacing: blockSpacing) {
                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    blockView(block, segmentStart: findHighlight == nil
                        ? 0 : segmentStart(for: index, in: blocks))
                }
            }
        }
    }

    // MARK: Blocks

    /// AnyView because a blockquote renders blocks recursively.
    private func blockView(_ block: MarkdownBlock, segmentStart: Int) -> AnyView {
        switch block.kind {
        case .paragraph(let text):
            return AnyView(paragraphText(text, segment: segmentStart))
        case .heading(let level, let text):
            return AnyView(headingText(text, level: level, segment: segmentStart))
        case .list(let items, let ordered):
            return AnyView(listView(items, ordered: ordered, segmentStart: segmentStart))
        case .code(let language, let source):
            return AnyView(CodeBlock(source: source, language: language, theme: theme,
                                     size: size, color: color, onAccent: onAccent,
                                     findHighlight: findHighlight, segment: segmentStart))
        case .quote(let nested):
            return AnyView(quoteView(nested, segmentStart: segmentStart))
        case .rule:
            return AnyView(ruleView)
        case .table(let header, let rows):
            return AnyView(tableView(header: header, rows: rows,
                                     segmentStart: segmentStart))
        }
    }

    private func paragraphText(_ text: AttributedString, segment: Int) -> some View {
        Text(highlighted(styled(text), segment: segment))
            .font(theme.body(size))
            .lineSpacing(lineSpacing)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func headingText(_ text: AttributedString, level: Int, segment: Int) -> some View {
        let scale: CGFloat = switch level {
        case 1: 6
        case 2: 3.5
        case 3: 1.5
        default: 0
        }
        return Group {
            switch theme.id {
            case .soft:
                Text(highlighted(styled(text), segment: segment))
                    .font(theme.body(size + scale, weight: .bold))
                    .tracking(-0.2)
            case .control:
                Text(highlighted(styled(text), segment: segment))
                    .font(theme.mono(size + scale - 1.5, weight: .bold))
                    .tracking(level <= 2 ? 1.2 : 0.6)
                    .textCase(level <= 2 ? .uppercase : nil)
            case .ink:
                Text(highlighted(styled(text), segment: segment))
                    .font(theme.display(size + scale + 1).smallCaps())
                    .tracking(0.6)
            }
        }
        .foregroundStyle(color)
        .padding(.top, level <= 2 ? 2 : 0)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func listView(_ items: [MarkdownListItem], ordered: Bool,
                          segmentStart: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(marker(for: item, ordered: ordered))
                        .font(markerFont)
                        .foregroundStyle(markerColor)
                        .frame(minWidth: ordered ? 16 : 9, alignment: .leading)
                        .monospacedDigit()
                    Text(highlighted(styled(item.content), segment: segmentStart + offset))
                        .font(theme.body(size))
                        .lineSpacing(lineSpacing)
                        .foregroundStyle(color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(item.indent) * 14)
            }
        }
    }

    private func marker(for item: MarkdownListItem, ordered: Bool) -> String {
        if let checked = item.checked { return checked ? "☑" : "☐" }
        if let ordinal = item.ordinal { return "\(ordinal)." }
        guard !ordered else { return "•" }
        switch theme.id {
        case .soft: return item.indent % 2 == 0 ? "•" : "◦"
        case .control: return item.indent % 2 == 0 ? "▸" : "·"
        case .ink: return item.indent % 2 == 0 ? "—" : "·"
        }
    }

    private func quoteView(_ nested: [MarkdownBlock], segmentStart: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(onAccent ? color.opacity(0.35) : theme.lineStrong)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: blockSpacing) {
                ForEach(Array(nested.enumerated()), id: \.element.id) { index, block in
                    blockView(block, segmentStart: findHighlight == nil ? 0
                        : segmentStart + self.segmentStart(for: index, in: nested))
                }
            }
            .opacity(0.86)
            .italic(theme.id == .ink)
        }
    }

    private var ruleView: some View {
        Group {
            if theme.id == .ink {
                HStack(spacing: 8) {
                    Rectangle().fill(ruleColor).frame(height: 1)
                    Rectangle()
                        .fill(ruleColor)
                        .frame(width: 4, height: 4)
                        .rotationEffect(.degrees(45))
                    Rectangle().fill(ruleColor).frame(height: 1)
                }
            } else {
                Rectangle().fill(ruleColor).frame(height: 1)
            }
        }
        .padding(.vertical, 2)
    }

    private func tableView(header: [AttributedString], rows: [[AttributedString]],
                           segmentStart: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { offset, cell in
                        Text(highlighted(styled(cell), segment: segmentStart + offset))
                            .font(theme.body(size - 0.5, weight: .bold))
                            .foregroundStyle(color)
                    }
                }
                Rectangle().fill(ruleColor).frame(height: 1)
                    .gridCellColumns(max(header.count, 1))
                ForEach(Array(rows.enumerated()), id: \.offset) { rowOffset, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { cellOffset, cell in
                            let priorCells = rows.prefix(rowOffset).reduce(0) { $0 + $1.count }
                            Text(highlighted(styled(cell), segment: segmentStart
                                + header.count + priorCells + cellOffset))
                                .font(theme.body(size - 0.5))
                                .foregroundStyle(color.opacity(0.88))
                        }
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .fixedSize(horizontal: true, vertical: false)
        }
        .background(panelFill, in: RoundedRectangle(cornerRadius: theme.cardRadius == 0 ? 0 : 8))
        .overlay(RoundedRectangle(cornerRadius: theme.cardRadius == 0 ? 0 : 8)
            .strokeBorder(ruleColor, lineWidth: 1))
    }

    // MARK: Inline styling

    /// SwiftUI resolves bold/italic intents against the environment font on its
    /// own; only code spans and links need explicit treatment.
    private func styled(_ attributed: AttributedString) -> AttributedString {
        let runs = attributed.runs.map { ($0.range, $0.inlinePresentationIntent, $0.link != nil) }
        var out = attributed
        for (range, intent, isLink) in runs {
            if intent?.contains(.code) == true {
                out[range].font = theme.mono(size - 1)
                out[range].foregroundColor = onAccent ? color : theme.accent
            }
            if intent?.contains(.strikethrough) == true {
                out[range].strikethroughStyle = .single
            }
            if isLink {
                out[range].foregroundColor = onAccent ? color : theme.accent
                out[range].underlineStyle = .single
            }
        }
        return out
    }

    private func highlighted(_ attributed: AttributedString, segment: Int) -> AttributedString {
        guard let findHighlight,
              findHighlight.address.segment == segment else { return attributed }
        return transcriptFindHighlighted(
            attributed, query: findHighlight.query,
            occurrence: findHighlight.occurrenceInSegment,
            color: theme.warn, foreground: theme.bg)
    }

    private func segmentStart(for index: Int, in blocks: [MarkdownBlock]) -> Int {
        blocks.prefix(index).reduce(0) { $0 + MarkdownParser.segmentCount($1) }
    }

    // MARK: Tokens

    private var blockSpacing: CGFloat {
        switch theme.id {
        case .soft: 8
        case .control: 7
        case .ink: 9
        }
    }

    private var markerFont: Font {
        theme.id == .soft ? theme.body(size, weight: .semibold) : theme.mono(size - 2)
    }

    private var markerColor: Color {
        onAccent ? color.opacity(0.75) : theme.accent
    }

    private var ruleColor: Color {
        onAccent ? color.opacity(0.3) : theme.line
    }

    private var panelFill: Color {
        onAccent ? color.opacity(0.12) : theme.inset
    }
}

// MARK: - Code block

/// Monospaced, never wrapped: long lines scroll horizontally inside the block
/// instead of forcing the transcript wide or being truncated away.
private struct CodeBlock: View {
    var source: String
    var language: String?
    var theme: ThemePack
    var size: CGFloat
    var color: Color
    var onAccent: Bool
    var findHighlight: TranscriptFindSelection?
    var segment: Int

    @State private var copied = false

    private var fill: Color {
        onAccent ? color.opacity(0.12) : theme.id == .soft ? theme.inset : theme.bg
    }

    private var border: Color {
        onAccent ? color.opacity(0.25) : theme.id == .control ? theme.lineStrong : theme.line
    }

    private var radius: CGFloat { theme.cardRadius == 0 ? 0 : 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.horizontal, showsIndicators: false) {
                Text(codeText)
                    .font(theme.mono(size - 1.5))
                    .lineSpacing(2.5)
                    .foregroundStyle(color.opacity(0.92))
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .background(fill, in: RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(border, lineWidth: 1))
    }

    private var codeText: AttributedString {
        let plain = AttributedString(source)
        guard let findHighlight,
              findHighlight.address.segment == segment else { return plain }
        return transcriptFindHighlighted(
            plain, query: findHighlight.query,
            occurrence: findHighlight.occurrenceInSegment,
            color: theme.warn, foreground: theme.bg)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(theme.mono(8.5, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(onAccent ? color.opacity(0.7) : theme.faint)
            }
            Spacer(minLength: 0)
            Button {
                copyToPasteboard(source)
                copied = true
            } label: {
                Text(copied ? "✓" : "⧉")
                    .font(theme.mono(11))
                    .foregroundStyle(copied ? theme.ok : (onAccent ? color.opacity(0.7) : theme.faint))
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.top, 6)
        .padding(.bottom, 1)
    }
}
