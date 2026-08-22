import SwiftUI
import TalariaKit
import TalariaTheme

enum AgentInboxLayoutPolicy {
    static let minimumControlSize: CGFloat = 44
}

// Agent Inbox — Agent Inbox / Comms / The Parley. The cross-bot traffic feed:
// each row is a from-avatar, "from → to" names (copy.a2aSep — "unto" in ink;
// "all" renders as a broadcast), the message body (italic and quoted in ink),
// and a footer attribution note. Ported from Talaria.dc.html
// `data-screen-label="Agent Inbox"`.
//
// There is no inbox object to fetch. The feed is each profile's own Bot Chat,
// read over transcript REST and split back into from → to rows by Hermes'
// attribution prefix. `AppModelLive+A2A.swift` keeps it live. Sending is no
// longer client-owned: `message_agent` exists only inside a canonical Bot Chat
// and composes/delivers the agent's own message. This screen therefore opens a
// Bot Chat instead of forwarding human-authored text itself.

public struct AgentInboxView: View {
    private let model: AppModel

    @State private var showCompose = false

    public init(model: AppModel) {
        self.model = model
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var feeds: FeedsRuntime { FeedsRuntime.shared }

    private var listGap: CGFloat {
        switch theme.rowStyle {
        case .ledger: 0
        case .terminal: 7
        case .card: 8
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: listGap) {
                    ForEach(Array(model.agentInbox.enumerated()), id: \.element.id) { index, message in
                        A2ARow(message: message,
                               fromBot: model.bot(model.resolvedBotID(message.fromBotID)),
                               toBot: model.bot(message.toBotID),
                               delivery: model.delivery(for: message),
                               theme: theme, copy: copy) {
                            model.openInboxMessage(message)
                        }
                        .modifier(RowEntrance(delay: Double(min(index, 12)) * 0.055))
                    }

                    if model.agentInbox.isEmpty { emptyState }
                    if model.mode == .live { composeRow }
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 128) // clear the tab bar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
        .task {
            model.attachActivityRouter()
            // Sweeps now, then follows sessions.changed with a slow poll behind
            // it. Paired with endInboxLive so a screen nobody is looking at
            // stops costing radio.
            model.beginInboxLive()
        }
        .onDisappear { model.endInboxLive() }
        .sheet(isPresented: $showCompose) {
            AgentMessagingTargetSheet(model: model)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    if theme.showsKicker {
                        Text(copy.kickerA2A)
                            .font(theme.mono(theme.id == .ink ? 9 : 9.5, weight: .semibold))
                            .tracking(theme.id == .control ? 2.5 : 2)
                            .foregroundStyle(theme.id == .ink ? theme.sub : theme.accent)
                            .padding(.bottom, theme.id == .control ? 3 : 1)
                    }
                    Text(copy.titleA2A)
                        .font(titleFont)
                        .tracking(theme.smallCapsTitles ? 0.5 : -0.5)
                        .foregroundStyle(theme.ink)
                }
                Spacer(minLength: 6)
                if model.mode == .live {
                    HeaderIconButton(theme: theme, size: 32) {
                        model.sweepInbox(after: 0)
                    } glyph: {
                        Text(verbatim: "↻")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.id == .ink ? theme.ink : theme.accent)
                            .opacity(feeds.inboxScanning ? 0.4 : 1)
                    }
                    .disabled(feeds.inboxScanning)
                }
            }
            Text(copy.a2aLead)
                .font(theme.body(theme.id == .ink ? 14 : 12.5))
                .italic(theme.id == .ink)
                .foregroundStyle(theme.id == .ink ? theme.sub : theme.faint)
                .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var titleFont: Font {
        switch theme.id {
        case .soft: theme.display(31)
        case .control: theme.display(27)
        case .ink: theme.display(28).smallCaps()
        }
    }

    // MARK: Compose + empty state

    private var composeRow: some View {
        Button {
            showCompose = true
        } label: {
            Text(openAgentChatLabel)
                .font(composeFont)
                .foregroundStyle(theme.id == .ink ? theme.sub : theme.faint)
                .frame(maxWidth: .infinity)
                .padding(12)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.rowRadius > 0 ? theme.cardRadius : 0,
                                     style: .continuous)
                        .strokeBorder(theme.id == .ink ? theme.lineStrong : theme.dashColor,
                                      style: StrokeStyle(lineWidth: theme.id == .soft ? 1.5 : 1,
                                                         dash: [5, 4]))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .disabled(model.unionRosterBots.isEmpty)
        .accessibilityHint("Choose a Bot Chat where Hermes can use message_agent")
    }

    private var openAgentChatLabel: String {
        switch theme.id {
        case .soft: "Open a Bot Chat to message an agent"
        case .control: "OPEN BOT CHAT FOR AGENT MESSAGE"
        case .ink: "open a Bot Chat to send word"
        }
    }

    private var composeFont: Font {
        switch theme.id {
        case .soft: theme.body(13, weight: .bold)
        case .control: theme.mono(10.5, weight: .semibold)
        case .ink: theme.body(14.5, weight: .semibold).smallCaps()
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(feeds.inboxScanning ? copy.scanningLabel(theme.id) : copy.inboxEmptyTitle(theme.id))
                .font(theme.id == .control ? theme.mono(12, weight: .bold)
                                           : theme.body(15, weight: .bold))
                .foregroundStyle(theme.ink)
            Text(copy.inboxEmptyBody(theme.id))
                .font(footFont)
                .italic(theme.id == .ink)
                .foregroundStyle(theme.faint)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 22)
    }

    // MARK: Footer

    /// The attribution note — handoffs are real cross-profile messages — plus
    /// the live provenance line once a sweep has run.
    private var footer: some View {
        VStack(spacing: 4) {
            Text(copy.a2aFoot)
                .font(footFont)
                .tracking(theme.id == .soft ? 0 : (theme.id == .ink ? 2 : 1))
                .textCase(theme.id == .ink ? .uppercase : nil)
                .foregroundStyle(theme.faint)
                .multilineTextAlignment(.center)
            if model.mode == .live, !feeds.inboxNote.isEmpty {
                Text(feeds.inboxNote)
                    .font(footFont)
                    .foregroundStyle(theme.faint)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var footFont: Font {
        switch theme.id {
        case .soft: theme.body(12)
        case .control: theme.mono(10)
        case .ink: theme.mono(8.5)
        }
    }
}

// MARK: - Row

private struct A2ARow: View {
    let message: A2AMessage
    let fromBot: Bot?
    let toBot: Bot?
    let delivery: A2ADelivery?
    let theme: ThemePack
    let copy: CopyPack
    let open: () -> Void

    /// Progressive disclosure, ported from desktop's group transcript
    /// (plugin.js:7316-7332): the line stays quiet by default and expands to
    /// carry the @handles on demand. Desktop hovers; touch taps the names.
    @State private var revealed = false

    private var isBroadcast: Bool { message.toBotID == "all" }

    private var fromColor: Color { theme.color(for: fromBot?.hue ?? .teal) }

    /// Broadcasts render muted; direct messages take the recipient's hue.
    private var toColor: Color {
        isBroadcast ? theme.sub : theme.color(for: toBot?.hue ?? .teal)
    }

    /// Only offer the reveal when a handle would actually add something —
    /// desktop's `showsHandle` rule (plugin.js:2721). An untitled bot's name IS
    /// its handle, so tapping it would be a gesture with nothing to say; the
    /// tap falls through to opening the conversation instead.
    private var canReveal: Bool {
        (fromBot?.showsHandle ?? false) || (!isBroadcast && (toBot?.showsHandle ?? false))
    }

    private var fromName: String {
        let name = TalariaVoice.displayName(fromBot, id: message.fromBotID, theme.id)
        guard revealed, let fromBot, fromBot.showsHandle else { return name }
        return "\(name) (@\(fromBot.handle))"
    }

    /// "all bots" / "ALL" / "All" for broadcasts, else the themed bot name.
    private var toName: String {
        guard !isBroadcast else {
            switch theme.id {
            case .soft: return "all bots"
            case .control: return "ALL"
            case .ink: return "All"
            }
        }
        let name = TalariaVoice.displayName(toBot, id: message.toBotID, theme.id)
        guard revealed, let toBot, toBot.showsHandle else { return name }
        return "\(name) (@\(toBot.handle))"
    }

    /// Ink wraps the parley in quotation marks.
    private var bodyText: String {
        theme.id == .ink ? "“\(message.text)”" : message.text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(shape: fromBot?.shape ?? .circle,
                       hue: fromBot?.hue ?? .teal,
                       size: 26, theme: theme)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // Tapping the names reveals the handles; tapping anywhere
                    // else opens the conversation the message lives in. The
                    // inner gesture wins because SwiftUI delivers a tap to the
                    // innermost view that handles it.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(fromName)
                            .font(nameFont)
                            .foregroundStyle(fromColor)
                            .lineLimit(1)
                        Text(copy.a2aSep)
                            .font(sepFont)
                            .italic(theme.id == .ink)
                            .foregroundStyle(sepColor)
                            .lineLimit(1)
                        Text(toName)
                            .font(nameFont)
                            .foregroundStyle(toColor)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard canReveal else { return open() }
                        withAnimation(.easeOut(duration: 0.16)) { revealed.toggle() }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Text(canReveal ? copy.a2aRevealHint(theme.id)
                                                      : copy.a2aOpenHint(theme.id)))

                    Spacer(minLength: 6)
                    Text(message.time)
                        .font(timeFont)
                        .foregroundStyle(theme.faint)
                        .lineLimit(1)
                }
                Text(bodyText)
                    .font(bodyFont)
                    .italic(theme.id == .ink)
                    .foregroundStyle(bodyColor)
                    .lineSpacing(2.5)
                    .multilineTextAlignment(.leading)
                    .lineLimit(6)
                if let note = deliveryNote { deliveryLine(note) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(A2ARowChrome(theme: theme))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Delivery state

    /// Compatibility status for a delivery accepted by an older Talaria
    /// build. Current builds never create these rows client-side, but retaining
    /// their read projection avoids lying while legacy watcher state settles.
    private var deliveryNote: (text: String, tone: Color)? {
        guard let delivery else { return nil }
        switch delivery.state {
        case .waiting:
            return delivery.queuedBehindRun
                ? (copy.a2aQueuedNote(theme.id), theme.warn)
                : (copy.a2aWaitingNote(theme.id), theme.faint)
        case .replied:
            return (copy.a2aRepliedNote(theme.id), theme.ok)
        case .quiet:
            return (copy.a2aQuietNote(theme.id), theme.faint)
        case .failed(let reason):
            return (copy.a2aFailedNote(theme.id, reason: reason), theme.danger)
        }
    }

    private func deliveryLine(_ note: (text: String, tone: Color)) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: theme.id == .control ? "▸" : "·")
                .font(noteFont)
                .foregroundStyle(note.tone)
            Text(note.text)
                .font(noteFont)
                .italic(theme.id == .ink)
                .foregroundStyle(note.tone)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nameFont: Font {
        switch theme.id {
        case .soft: theme.body(12.5, weight: .bold)
        case .control: theme.mono(10.5, weight: .bold)
        case .ink: theme.body(15.5, weight: .bold).smallCaps()
        }
    }

    private var sepFont: Font {
        switch theme.id {
        case .soft: theme.body(12)
        case .control: theme.mono(10.5)
        case .ink: theme.body(13)
        }
    }

    private var sepColor: Color {
        theme.id == .ink ? theme.faint : theme.ink.opacity(theme.id == .control ? 0.3 : 0.35)
    }

    private var timeFont: Font {
        switch theme.id {
        case .soft: theme.body(11, weight: .medium)
        case .control: theme.mono(10)
        case .ink: theme.mono(9)
        }
    }

    private var bodyFont: Font {
        switch theme.id {
        case .soft: theme.body(13.5)
        case .control: theme.body(13)
        case .ink: theme.body(15.5)
        }
    }

    private var noteFont: Font {
        switch theme.id {
        case .soft: theme.body(11)
        case .control: theme.mono(9)
        case .ink: theme.mono(9)
        }
    }

    private var bodyColor: Color {
        theme.id == .ink ? theme.ink.opacity(0.85) : theme.ink.opacity(0.92)
    }
}

// MARK: - Agent messaging entry point

/// Pick the Bot Chat in which the user wants to ask for agent-to-agent work.
/// Talaria intentionally collects no message here: forwarding that text would
/// bypass Hermes' Bot-Chat-only `message_agent` tool and its compose/privacy
/// contract. `openChat` enters the canonical resolver owned by the chat stack.
private struct AgentMessagingTargetSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    Text(instruction)
                        .font(footFont)
                        .foregroundStyle(theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)
                    ForEach(model.unionRosterBots) { bot in
                        Button {
                            model.openChat(botID: bot.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                AvatarView(shape: bot.shape, hue: bot.hue,
                                           size: 28, theme: theme)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(TalariaVoice.displayName(for: bot, theme.id))
                                        .font(theme.body(13, weight: .semibold))
                                        .foregroundStyle(theme.ink)
                                    Text("@\(bot.handle)"
                                         + (bot.remoteSource.map {
                                             " · \($0.connectionLabel)"
                                         } ?? ""))
                                        .font(theme.mono(9.5))
                                        .foregroundStyle(theme.faint)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(theme.faint)
                            }
                            .frame(minHeight: 44)
                            .padding(.horizontal, 12)
                            .chipShell(theme)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(bot.displayTitle) Bot Chat")
                        .accessibilityHint("Ask this agent to message a teammate")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
        }
        .background(theme.bg.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Text(copy.cancel)
                    .font(headerButtonFont)
                    .foregroundStyle(theme.id == .soft ? theme.accent : theme.sub)
                    .frame(minWidth: AgentInboxLayoutPolicy.minimumControlSize,
                           minHeight: AgentInboxLayoutPolicy.minimumControlSize,
                           alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Text(sheetTitle)
                .font(titleFont)
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
    }

    private var sheetTitle: String {
        switch theme.id {
        case .soft: "Choose an agent"
        case .control: "CHOOSE AGENT"
        case .ink: "choose an agent"
        }
    }

    private var instruction: String {
        switch theme.id {
        case .soft: "Open a Bot Chat, then ask that agent to message a teammate. Hermes composes and delivers the agent's own message with message_agent."
        case .control: "OPEN A BOT CHAT, THEN ASK THAT AGENT TO MESSAGE A TEAMMATE. HERMES OWNS DELIVERY THROUGH MESSAGE_AGENT."
        case .ink: "Choose whose Bot Chat to enter, then ask that agent to carry a composed message to its teammate."
        }
    }

    private var titleFont: Font {
        switch theme.id {
        case .soft: theme.body(17, weight: .heavy)
        case .control: theme.mono(13, weight: .bold)
        case .ink: theme.display(20, weight: .bold).smallCaps()
        }
    }

    private var headerButtonFont: Font {
        switch theme.id {
        case .soft: theme.body(14, weight: .semibold)
        case .control: theme.mono(11, weight: .semibold)
        case .ink: theme.body(14, weight: .semibold).smallCaps()
        }
    }

    private var footFont: Font {
        switch theme.id {
        case .soft: theme.body(11.5)
        case .control: theme.mono(9.5)
        case .ink: theme.body(13)
        }
    }
}

// MARK: - Row chrome (file-scoped copy; each screen file keeps its own)

/// Row chrome per rowStyle: soft = floating card, control = terminal panel,
/// ink = ruled ledger line.
private struct A2ARowChrome: ViewModifier {
    let theme: ThemePack

    func body(content: Content) -> some View {
        switch theme.rowStyle {
        case .card:
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                    .strokeBorder(theme.ink.opacity(0.05), lineWidth: 1))
                .shadow(color: theme.ink.opacity(0.04), radius: 3, y: 1)
        case .terminal:
            content
                .padding(.horizontal, 13)
                .padding(.vertical, 12)
                .background(theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
                    .strokeBorder(theme.line, lineWidth: 1))
        case .ledger:
            content
                .padding(.horizontal, 2)
                .padding(.vertical, 14)
                .overlay(alignment: .bottom) { theme.line.frame(height: 1) }
        }
    }
}

private extension ThemePack {
    var dashColor: Color {
        switch id {
        case .soft: ink.opacity(0.15)
        case .control: accent.opacity(0.25)
        case .ink: lineStrong
        }
    }
}

private struct RowEntrance: ViewModifier {
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .onAppear {
                withAnimation(.easeOut(duration: 0.42).delay(delay)) { shown = true }
            }
    }
}

extension CopyPack {
    func a2aRevealHint(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Show handles"
        case .control: "SHOW HANDLES"
        case .ink: "show their true names"
        }
    }

    func a2aOpenHint(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Open the conversation"
        case .control: "OPEN SESSION"
        case .ink: "open the audience"
        }
    }
}
