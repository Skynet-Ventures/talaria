import SwiftUI
import TalariaKit
import TalariaTheme

// Reusable screen chrome: the kicker+title header every top-level screen uses,
// plus the small themed atoms (icon buttons, chip shells) and the themed
// strings that live *outside* CopyPack in the design prototype (bot display
// names, elapsed formats, state lines, net-chip labels, done-words).
// Ported from Talaria.dc.html: T.kickerCss/titleCss/ornDisplay + renderVals().

// MARK: - ScreenHeader

/// Kicker + title header, per theme:
/// - soft: no kicker, 31pt heavy title
/// - control: phosphor mono kicker + 27pt heavy title
/// - ink: ornament rule, mono kicker, 28pt Cormorant small-caps title
public struct ScreenHeader<Trailing: View>: View {
    public var theme: ThemePack
    public var kicker: String?
    public var title: String
    @ViewBuilder public var trailing: () -> Trailing

    public init(theme: ThemePack, kicker: String? = nil, title: String,
                @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.theme = theme
        self.kicker = kicker
        self.title = title
        self.trailing = trailing
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if theme.id == .ink {
                ornament
            }
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: theme.id == .control ? 3 : 1) {
                    if theme.showsKicker, let kicker, !kicker.isEmpty {
                        Text(kicker)
                            .font(theme.mono(9.5, weight: .semibold))
                            .tracking(theme.id == .control ? 2.5 : 2)
                            .foregroundStyle(theme.id == .ink ? theme.sub : theme.accent)
                            .lineLimit(1)
                    }
                    titleText
                }
                Spacer(minLength: 8)
                trailing()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var titleText: some View {
        switch theme.id {
        case .soft:
            Text(title)
                .font(theme.body(31, weight: .heavy))
                .tracking(-0.6)
                .foregroundStyle(theme.ink)
                .lineLimit(1)
        case .control:
            Text(title)
                .font(theme.body(27, weight: .heavy))
                .tracking(-0.4)
                .foregroundStyle(theme.ink)
                .lineLimit(1)
        case .ink:
            Text(title)
                .font(theme.display(28).smallCaps())
                .tracking(0.5)
                .foregroundStyle(theme.ink)
                .lineLimit(1)
        }
    }

    /// Ink's line — ◆ — line rule above the header.
    private var ornament: some View {
        HStack(spacing: 10) {
            Rectangle().fill(theme.lineStrong).frame(height: 1)
            Rectangle()
                .fill(theme.ink)
                .frame(width: 6, height: 6)
                .rotationEffect(.degrees(45))
            Rectangle().fill(theme.lineStrong).frame(height: 1)
        }
    }
}

// MARK: - Icon button

/// The 32pt round/rounded icon button used across headers (search glyph,
/// theme cycler, back chevron, sheet closers). Silhouette follows
/// `iconCornerFraction`; chrome follows the theme's iconBtnCss.
public struct HeaderIconButton<Glyph: View>: View {
    public var theme: ThemePack
    public var size: CGFloat
    public var hitTargetSize: CGFloat?
    public var showsChrome: Bool
    public var action: () -> Void
    @ViewBuilder public var glyph: () -> Glyph

    public init(theme: ThemePack, size: CGFloat = 32, hitTargetSize: CGFloat? = nil,
                action: @escaping () -> Void,
                @ViewBuilder glyph: @escaping () -> Glyph) {
        self.init(theme: theme, size: size, showsChrome: true,
                  hitTargetSize: hitTargetSize, action: action, glyph: glyph)
    }

    public init(theme: ThemePack, size: CGFloat = 32, showsChrome: Bool,
                hitTargetSize: CGFloat? = nil,
                action: @escaping () -> Void, @ViewBuilder glyph: @escaping () -> Glyph) {
        self.theme = theme
        self.size = size
        self.showsChrome = showsChrome
        self.hitTargetSize = hitTargetSize
        self.action = action
        self.glyph = glyph
    }

    public var body: some View {
        Button(action: action) {
            glyph()
                .frame(width: size, height: size)
                .background(showsChrome && theme.id != .ink ? theme.panel : Color.clear)
                .clipShape(shape)
                .overlay {
                    if showsChrome {
                        shape.strokeBorder(borderColor, lineWidth: 1)
                    }
                }
                .frame(minWidth: hitTargetSize ?? size,
                       minHeight: hitTargetSize ?? size)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * theme.iconCornerFraction, style: .continuous)
    }

    private var borderColor: Color {
        theme.id == .soft ? theme.line : theme.lineStrong
    }
}

// MARK: - Chip shell

/// The pill/panel chrome behind small chips (net chip, model strip, routines
/// button): capsule card in soft, bordered panel in control, hairline square
/// in ink.
public struct ChipShell: ViewModifier {
    public var theme: ThemePack

    public init(theme: ThemePack) { self.theme = theme }

    public func body(content: Content) -> some View {
        let radius = theme.id == .ink ? theme.inputRadius : theme.buttonRadius
        if theme.chipIsCapsule {
            content
                .background(theme.panel)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(theme.line, lineWidth: 1))
                .shadow(color: theme.ink.opacity(0.04), radius: 1, y: 1)
        } else {
            content
                .background(theme.id == .ink ? Color.clear : theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(theme.id == .ink ? theme.lineStrong : theme.lineStrong.opacity(0.8),
                                  lineWidth: 1))
        }
    }
}

public extension View {
    func chipShell(_ theme: ThemePack) -> some View {
        modifier(ChipShell(theme: theme))
    }
}

// MARK: - Themed action buttons

/// The btnPriCss treatment: violet capsule-ish card in soft, phosphor block in
/// control, ink-black seal button in ink. Used by approval cards, push
/// banners and onboarding CTAs.
public struct ThemedPrimaryButton: View {
    public var theme: ThemePack
    public var title: String
    public var compact: Bool
    public var action: () -> Void

    public init(theme: ThemePack, title: String, compact: Bool = false,
                action: @escaping () -> Void) {
        self.theme = theme; self.title = title; self.compact = compact; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity)
                .padding(.vertical, compact ? 7 : 10)
                .background(theme.id == .ink ? theme.ink : theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: theme.buttonRadius))
                .contentShape(RoundedRectangle(cornerRadius: theme.buttonRadius))
        }
        .buttonStyle(.plain)
        .shadow(color: theme.glowRadius > 0 ? theme.accent.opacity(0.22)
                    : theme.id == .soft ? theme.accent.opacity(0.28) : .clear,
                radius: theme.glowRadius > 0 ? 8 : 5, y: theme.id == .soft ? 4 : 0)
    }

    @ViewBuilder private var label: some View {
        switch theme.id {
        case .soft:
            Text(title).font(theme.body(13.5, weight: .bold)).foregroundStyle(theme.accentFg)
        case .control:
            Text(title).font(theme.mono(11, weight: .bold)).tracking(1.5)
                .foregroundStyle(theme.accentFg)
        case .ink:
            Text(title).font(theme.body(15, weight: .bold).smallCaps()).tracking(1.5)
                .foregroundStyle(theme.bg)
        }
    }
}

/// The btnSecCss treatment: quiet gray in soft, red-bordered ABORT in
/// control, vermilion-ruled refuse in ink.
public struct ThemedSecondaryButton: View {
    public var theme: ThemePack
    public var title: String
    public var compact: Bool
    public var fillsWidth: Bool
    public var action: () -> Void

    public init(theme: ThemePack, title: String, compact: Bool = false,
                fillsWidth: Bool = false, action: @escaping () -> Void) {
        self.theme = theme; self.title = title; self.compact = compact
        self.fillsWidth = fillsWidth; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            label
                .padding(.vertical, compact ? 7 : 10)
                .padding(.horizontal, fillsWidth ? 0 : 16)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .background(theme.id == .soft ? theme.ink.opacity(0.05) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: theme.buttonRadius))
                .overlay(RoundedRectangle(cornerRadius: theme.buttonRadius)
                    .strokeBorder(borderColor, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: theme.buttonRadius))
        }
        .buttonStyle(.plain)
    }

    private var borderColor: Color {
        switch theme.id {
        case .soft: .clear
        case .control: theme.danger.opacity(0.4)
        case .ink: theme.accent.opacity(0.6)
        }
    }

    @ViewBuilder private var label: some View {
        switch theme.id {
        case .soft:
            Text(title).font(theme.body(13.5, weight: .bold)).foregroundStyle(theme.ink)
        case .control:
            Text(title).font(theme.mono(11, weight: .bold)).tracking(1.5)
                .foregroundStyle(theme.danger)
        case .ink:
            Text(title).font(theme.body(15, weight: .bold).smallCaps()).tracking(1)
                .foregroundStyle(theme.accent)
        }
    }
}

// MARK: - Glow pulse

/// The prototype's `glowU` keyframe: opacity breathing .45 → 1, used on
/// status dots and pending-approval markers.
public struct GlowPulse: ViewModifier {
    public var period: Double
    @State private var dim = false

    public init(period: Double = 2.2) { self.period = period }

    public func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: period / 2).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

public extension View {
    /// Apply the glowU opacity pulse.
    func glowPulse(period: Double = 2.2) -> some View {
        modifier(GlowPulse(period: period))
    }
}

// MARK: - Themed voice (strings outside CopyPack)

/// Themed logic the prototype computes outside `copy()` — display names,
/// elapsed-time formats, roster/chat status lines, net-chip labels, roster
/// footer and approval done-words. Kept here so Roster/Chat/banner and any
/// other screen agree on the voice.
public enum TalariaVoice {

    public static func capitalized(_ id: String) -> String {
        guard let first = id.first else { return id }
        return String(first).uppercased() + id.dropFirst()
    }

    // The bare-id overloads that used to live here (`displayName(_ id:)` and
    // `plainUpper(_ id:)`) are gone. Both re-derived a name from the profile
    // id — `plainUpper` printed it verbatim, so the primary profile shouted
    // DEFAULT where every other surface says HERMES — which is the split
    // identity Phase 0 removed. A call site holding only an id now goes
    // through `AppModel.identity(_:)`; one holding an optional Bot uses the
    // `displayName(_:id:_:)` overload in Components/BotIdentity.swift.

    /// Desktop Bot Mode's title (plugin.js `displayName`): a user-set title,
    /// "Hermes" for the primary "default" profile, else the de-slugged
    /// profile name. Ink renders it small-caps, so it stays unprefixed there;
    /// the other packs keep the prototype's @-prefix only when the bot has no
    /// distinct title, so a titled bot reads "skynet" rather than "@skynet".
    public static func displayName(for bot: Bot, _ theme: ThemeID) -> String {
        bot.showsHandle || theme == .ink ? bot.displayTitle : "@" + bot.handle
    }

    /// The @handle you tag a bot with (plugin.js `botHandle`): the profile
    /// name, except "default" → @hermes. Shown beside the title only when the
    /// two differ, matching desktop's `showsHandle`.
    public static func handle(for bot: Bot) -> String {
        "@" + bot.handle
    }

    /// Elapsed-time readout: soft "4m 12s" · control "04:12" · ink "4 minutes gone".
    public static func elapsed(minutes: Int, seconds: Int, _ theme: ThemeID) -> String {
        switch theme {
        case .control: String(format: "%02d:%02d", minutes, seconds)
        case .ink: "\(minutes) minutes gone"
        case .soft: "\(minutes)m \(seconds)s"
        }
    }

    /// The roster row's live line: working = task + ticking elapsed
    /// (control prefixes "▸ "), otherwise the last-message preview.
    public static func rosterLine(for bot: Bot, seconds: Int, _ theme: ThemeID) -> String {
        guard bot.status == .working, let task = bot.task else { return bot.preview }
        let el = elapsed(minutes: bot.minutesElapsed, seconds: seconds, theme)
        let sep = theme == .ink ? " — " : " · "
        return (theme == .control ? "▸ " : "") + task + sep + el
    }

    /// The chat header's state line under the bot name.
    public static func chatStateLine(for bot: Bot, _ theme: ThemeID) -> String {
        switch bot.status {
        case .working:
            return bot.task ?? bot.preview
        case .approval:
            switch theme {
            case .ink: return "held — awaiting your seal"
            case .control: return "HOLD — waiting on you"
            case .soft: return "blocked — waiting on you"
            }
        case .idle:
            return theme == .ink ? "at rest · memory warm" : "idle · memory warm"
        }
    }

    /// Approval card outcome line: "Approved — sent" / "RELEASED — RAN CLEAN"
    /// / "sealed — done cleanly", and the denial forms.
    public static func doneWord(kind: ApprovalKind, approved: Bool, _ theme: ThemeID) -> String {
        guard approved else {
            switch theme {
            case .ink: return "refused — the familiar knows"
            case .control: return "ABORTED — AGENT NOTIFIED"
            case .soft: return "Denied — bot notified"
            }
        }
        let act: String
        switch kind {
        case .email: act = theme == .control ? "SENT" : "sent"
        case .command: act = theme == .control ? "RAN CLEAN" : theme == .ink ? "done cleanly" : "ran clean"
        case .post, .other: act = "scheduled"
        }
        switch theme {
        case .ink: return "sealed — " + act
        case .control: return "RELEASED — " + act
        case .soft: return "Approved — " + act
        }
    }

    /// Roster footer: "6 bots · 3 gateways · profiles are the bots" in each voice.
    public static func rosterFooter(botCount: Int, gatewayCount: Int, _ theme: ThemeID) -> String {
        switch theme {
        case .ink: "\(botCount) FAMILIARS · \(gatewayCount) WAYS · THE PROFILES ARE THE BOTS"
        case .control: "\(botCount) AGENTS · \(gatewayCount) UPLINKS · PROFILES ARE THE BOTS"
        case .soft: "\(botCount) bots · \(gatewayCount) gateways · profiles are the bots"
        }
    }

    public enum NetTone: Sendable { case up, cloud, down }

    /// Header net chip: label + tone, from live connection state.
    public static func netChip(offline: Bool, connections: [GatewayConnection],
                               _ theme: ThemeID) -> (label: String, tone: NetTone) {
        if offline {
            switch theme {
            case .ink: return ("SEVERED", .down)
            case .control: return ("NO LINK", .down)
            case .soft: return ("offline", .down)
            }
        }
        let primary = connections.first { $0.state == .connected } ?? connections.first
        let label = friendlyGatewayLabel(primary, theme)
        let tone: NetTone = {
            if primary?.kind == .cloud { return .cloud }
            return .up
        }()
        return (label, tone)
    }

    /// Never show a raw host/IP in the roster header. A saved display name
    /// wins; otherwise Tailscale/LAN/Cloud become human words, and an address
    /// that looks like an IP or hostname collapses to Home.
    public static func friendlyGatewayLabel(_ connection: GatewayConnection?,
                                            _ theme: ThemeID) -> String {
        if let connection {
            let trimmed = connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if connection.kind == .cloud {
                return theme == .ink ? "BY CLOUD" : "Cloud"
            }
            if !trimmed.isEmpty,
               !isRawGatewayLabel(trimmed, address: connection.address) {
                return theme == .ink ? trimmed.uppercased() : trimmed
            }
            switch connection.kind {
            case .cloud:
                return theme == .ink ? "BY CLOUD" : "Cloud"
            case .tailscale:
                return theme == .ink ? "HOME" : "Home"
            case .lan:
                return theme == .ink ? "NEARBY" : "Nearby"
            }
        }
        return theme == .ink ? "HOME" : "Home"
    }

    public static func looksLikeNetworkAddress(_ value: String) -> Bool {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return true }

        if looksLikeLiteralNetworkEndpoint(candidate) { return true }
        let labels = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy(isHostnameLabel)
        else { return false }

        return !looksLikeVersionLabel(candidate.lowercased())
    }

    /// A syntactically host-like saved label is still a label when it differs
    /// from the connection endpoint. Discovery defaults mirror the endpoint's
    /// host, so compare those case-insensitively instead of guessing intent
    /// from capitalization. Literal IP/URL/port forms always stay private.
    private static func isRawGatewayLabel(_ label: String, address: String) -> Bool {
        if let addressHost = parsedNetworkHost(address) {
            if normalizedHost(label) == addressHost { return true }
            return looksLikeLiteralNetworkEndpoint(label)
        }
        return looksLikeNetworkAddress(label)
    }

    private static func parsedNetworkHost(_ address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let value = trimmed.contains("://") ? trimmed : "talaria://\(trimmed)"
        guard let host = URLComponents(string: value)?.host, !host.isEmpty else { return nil }
        return normalizedHost(host)
    }

    private static func normalizedHost(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
            .lowercased()
    }

    private static func looksLikeLiteralNetworkEndpoint(_ candidate: String) -> Bool {
        let lowercased = candidate.lowercased()
        if lowercased.contains("://") { return true }
        if candidate.first == "[", candidate.contains("]") { return true }

        let colonCount = candidate.filter { $0 == ":" }.count
        if colonCount > 1 { return true }
        if colonCount == 1,
           let separator = candidate.lastIndex(of: ":") {
            let host = candidate[..<separator]
            let port = candidate[candidate.index(after: separator)...]
            if !host.isEmpty, !port.isEmpty, port.allSatisfy(\.isNumber) {
                return true
            }
        }

        if lowercased == "localhost" { return true }
        let labels = candidate.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count == 4 && labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy(\.isNumber)
        }
    }

    private static func isHostnameLabel(_ label: Substring) -> Bool {
        guard let first = label.first, let last = label.last,
              first != "-", last != "-"
        else { return false }
        return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private static func looksLikeVersionLabel(_ value: String) -> Bool {
        guard value.first == "v" else { return false }
        let numeric = value.dropFirst()
        let components = numeric.split(separator: ".", omittingEmptySubsequences: false)
        return components.count >= 2
            && components.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// Dot/label color for a net tone.
    public static func netColor(_ tone: NetTone, theme: ThemePack) -> Color {
        switch tone {
        case .up: theme.id == .control ? theme.accent : theme.ok
        case .cloud: theme.color(for: .blue)
        case .down: theme.danger
        }
    }
}
