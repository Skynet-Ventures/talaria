import SwiftUI
import TalariaKit
import TalariaTheme

enum RosterRoomPolicy {
    static func showsEmpty(primaryBots: Int, rooms: Int, foreignBots: Int,
                           isSearching: Bool) -> Bool {
        primaryBots == 0 && rooms == 0 && foreignBots == 0 && !isSearching
    }

    static func matches(_ room: RoomRecord, needle: String) -> Bool {
        room.name.lowercased().contains(needle)
            || room.members.contains { member in
                (member.title ?? "").lowercased().contains(needle)
                    || (member.friendlyName ?? "").lowercased().contains(needle)
                    || member.handle.lowercased().contains(needle)
                    || (member.sourceLabel ?? "").lowercased().contains(needle)
            }
    }
}

/// Visibility is a view policy, deliberately separate from `RosterSignals`.
/// A hidden profile still participates in rooms, mentions, unread, and normal
/// roster ranking; this tiny gate is the sole place the primary list elects
/// not to paint it until this particular view's Show Hidden state says so.
enum RosterVisibilityPolicy {
    static func includesPrimary(hidden: Bool, showingHidden: Bool) -> Bool {
        !hidden || showingHidden
    }

    static func rowOpacity(hidden: Bool, showingHidden: Bool) -> Double {
        hidden && showingHidden ? 0.48 : 1
    }

    /// Hidden is display-only: unread remains live and needs one visible escape
    /// hatch on the control that reveals those rows.
    static func hiddenUnreadCount(bots: [Bot], hiddenIDs: Set<String>) -> Int {
        bots.lazy.filter { hiddenIDs.contains($0.id) }
            .reduce(0) { $0 + max(0, $1.unread) }
    }
}

/// Immutable destructive-dialog authority. The row and its exact gateway
/// lifecycle target are resolved together before presentation, so a route
/// disappearing between the long-press and the dialog cannot leave a
/// cancel-only sheet or redirect the eventual confirmation.
struct RosterDeleteCandidate: Identifiable, Equatable {
    let bot: Bot
    let target: ProfileLifecycleTarget

    var id: String { target.rosterID }

    private init(bot: Bot, target: ProfileLifecycleTarget) {
        self.bot = bot
        self.target = target
    }

    static func resolve(bot: Bot, target: ProfileLifecycleTarget?) -> Self? {
        guard bot.id != "default",
              let target,
              target.rosterID == bot.id,
              target.route.profile != "default"
        else { return nil }
        return Self(bot: bot, target: target)
    }
}

// The roster — the app's home screen. Themed kicker+title header with the
// search glyph, theme cycler, network chip and "+" (new bot); an offline
// banner when the gateway is unreachable; staggered-entrance bot rows with
// live status lines (working bots tick an elapsed timer every second, in each
// theme's own time format); the roster-count footer.
// Ported from Talaria.dc.html `data-screen-label="Roster"`.
//
// Phase 4 adds the ranking and presence craft the desktop plugin gets from its
// 5 s `profiles.list` poll, sourced here from `AppModelLive+Cosmetics`
// (BOT-MODE-PARITY §4.2-4.4, plugin.js:7637-7666, 3823-3839, 86-150):
//
//   * **Messaging-app order.** Pinned bots float as a group; inside each
//     group, recency — `max(created, last_active)` — rules. A brand-new bot
//     tops the list until someone else gets a message, and the primary bot
//     competes on recency like everyone else.
//   * **Two dots, two meanings.** Solid + bigger = you have something to read;
//     smaller + breathing = a fresh conversation (90 seconds) or worker
//     signal (150 seconds). They coexist and are never merged.
//   * **Presence never reorders.** A bot waking up lights its dot; it does not
//     move under a thumb mid-tap.
//   * **Motion.** Idle faces sway (±1.5°); a working face leans into its work,
//     which is a more legible status cue than any spinner. The row entrance
//     stays Talaria's own, capped so a 40-bot roster does not read as a slow
//     load, and never replayed on a refresh or a scroll back.

public struct RosterView: View {
    private let model: AppModel
    private let onSearch: () -> Void
    private let onCreate: () -> Void
    private let onConnections: () -> Void

    /// The look-and-soul sheet, opened from a row's long-press menu. The
    /// roster is where desktop puts Edit Profile too (plugin.js:4051-4111);
    /// before this the only way in was to open the bot first.
    @State private var editing: Bot?
    @State private var deleting: RosterDeleteCandidate?
    /// This is deliberately view-local. Hiding a Bot Mode row is durable
    /// metadata; choosing to inspect those rows is a momentary roster choice
    /// and must not follow the user onto another device or another launch.
    @State private var showHidden = false
    /// The in-place roster filter (plugin.js:7831-7842). Deliberately NOT the
    /// palette's query: the palette is a cross-surface jump (bots, sessions,
    /// artifacts, actions) and replaces the screen, where this narrows the list
    /// under the thumb without leaving it. Desktop has only the second one.
    @State private var search = ""
    @Environment(\.talariaReducedMotion) private var reducedMotion

    public init(model: AppModel,
                onSearch: @escaping () -> Void = {},
                onCreate: @escaping () -> Void = {},
                onConnections: @escaping () -> Void = {}) {
        self.model = model
        self.onSearch = onSearch
        self.onCreate = onCreate
        self.onConnections = onConnections
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    /// Skipped onboarding with no gateway: an honest empty roster with a way
    /// forward, instead of silently faked demo data.
    private var emptyState: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                AvatarView(shape: .hexagon, hue: .violet, size: 40, theme: theme)
                    .opacity(0.35)
                AvatarView(shape: .squircle, hue: .amber, size: 32, theme: theme)
                    .opacity(0.25)
                AvatarView(shape: .diamond, hue: .pink, size: 28, theme: theme)
                    .opacity(0.18)
            }
            Text(copy.emptyRosterTitle)
                .font(theme.display(20))
                .foregroundStyle(theme.ink)
            Text(copy.emptyRosterBody)
                .font(theme.body(14))
                .foregroundStyle(theme.sub)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Button(action: onConnections) {
                Text(copy.obCta0)
                    .font(theme.mono(12, weight: .bold))
                    .foregroundStyle(theme.accentFg)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(theme.accent,
                                in: RoundedRectangle(cornerRadius: theme.buttonRadius == 0 ? 0 : theme.buttonRadius + 2))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    /// A roster consisting only of hidden primary rows must not collapse into
    /// a blank scroll view. This is not the create-first empty state: the
    /// profiles still exist and their unread/room identities remain live, so
    /// the only honest action is to reveal them for this view session.
    private var hiddenOnlyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "eye.slash")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(theme.faint)
            Text("Hidden bots")
                .font(theme.body(15, weight: .semibold))
                .foregroundStyle(theme.ink)
            Text("Hidden bots still receive messages and can participate in rooms.")
                .font(theme.body(12))
                .foregroundStyle(theme.sub)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button("Show Hidden") { showHidden = true }
                .buttonStyle(.plain)
                .font(theme.body(12, weight: .bold))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(theme.accent.opacity(0.1), in: Capsule())
                .accessibilityHint(Text("Shows hidden bots only for this roster view"))
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity)
    }

    private var listGap: CGFloat {
        switch theme.rowStyle {
        case .ledger: 0
        case .terminal: 7
        case .card: 8
        }
    }

    // MARK: - Search (desktop `filterBots`)

    /// Desktop's needle: trimmed, lowercased, one leading '@' stripped
    /// (plugin.js:2964, ported in `RosterSearch`). Empty means "not
    /// searching", which is why a bare "@" lists the whole roster instead of
    /// nothing — upstream's `if (!needle) return roster`.
    private var needle: String { RosterSearch.needle(search) }

    private var isSearching: Bool { !needle.isEmpty }

    private enum HomeRosterItem: Identifiable {
        case bot(Bot)
        case foreign(ForeignRosterEntry)
        case room(RoomRecord)

        var id: String {
            switch self {
            case .bot(let bot): "bot:\(bot.id)"
            case .foreign(let entry): "bot:\(entry.id)"
            case .room(let room): "room:\(room.id.description)"
            }
        }
    }

    /// The rows the list draws: `rankedBots` narrowed, never re-sorted. The
    /// filter is applied to the array in the order it is already painted, so
    /// pinned-then-recency survives typing (plugin.js:2961-2962, 7657-7668).
    private var visibleBots: [Bot] {
        let narrowed = model.rankedBots.filterBots(
            needle: needle, connectionLabel: model.activeConnectionLabel)
        guard !showHidden else { return narrowed }
        // Primary Bot Mode metadata affects only these primary display rows.
        // Do not apply it to rooms, foreign rows, or the union that supplies
        // mention resolution: a hidden profile remains a participant there.
        return narrowed.filter {
            RosterVisibilityPolicy.includesPrimary(hidden: model.isRosterHidden($0.id),
                                                   showingHidden: showHidden)
        }
    }

    private var hiddenBotCount: Int {
        model.bots.lazy.filter { model.isRosterHidden($0.id) }.count
    }

    private var hiddenUnreadCount: Int {
        let hidden = Set(model.bots.lazy.filter { model.isRosterHidden($0.id) }.map(\.id))
        return RosterVisibilityPolicy.hiddenUnreadCount(bots: model.bots, hiddenIDs: hidden)
    }

    private var visibleRooms: [RoomRecord] {
        guard !needle.isEmpty else { return model.rooms }
        return model.rooms.filter { RosterRoomPolicy.matches($0, needle: needle) }
    }

    /// Rooms and bots share one messaging roster. Pinned bots retain their
    /// explicit top group; everything else is ordered by real conversation
    /// recency, so an active room moves naturally beside an active bot rather
    /// than living in a second shelf users have to remember to inspect.
    private var visibleHomeItems: [HomeRosterItem] {
        (visibleBots.map(HomeRosterItem.bot)
            + visibleForeign.map(HomeRosterItem.foreign)
            + visibleRooms.map(HomeRosterItem.room))
            .enumerated()
            .sorted { left, right in
                let lp = isPinned(left.element)
                let rp = isPinned(right.element)
                if lp != rp { return lp }
                let la = activityDate(left.element)
                let ra = activityDate(right.element)
                if la != ra { return la > ra }
                return left.offset < right.offset
            }
            .map(\.element)
    }

    private func isPinned(_ item: HomeRosterItem) -> Bool {
        if case .bot(let bot) = item { return model.isPinned(bot.id) }
        return false
    }

    private func activityDate(_ item: HomeRosterItem) -> Double {
        switch item {
        case .bot(let bot): RosterSignals.shared.activity(of: bot.id)
        case .foreign(let entry): (entry.lastActive ?? 0) * 1_000
        case .room(let room): room.lastActivityAt.timeIntervalSince1970 * 1_000
        }
    }

    private var visibleForeign: [ForeignRosterEntry] {
        model.foreignRosterEntries(matching: needle)
    }

    /// Desktop renders the field only when there is a roster to narrow
    /// (plugin.js:7831 `roster.length ? … : null`) — an empty roster shows the
    /// create-first empty state instead of a dead search box. Its `roster` is
    /// the union, so a phone whose only rows live on other gateways still gets
    /// a field.
    private var showsSearchField: Bool {
        !model.bots.isEmpty || !model.foreignRosterEntries.isEmpty || !model.rooms.isEmpty
    }

    /// Both halves of the union came back empty for a live query — desktop's
    /// `No bots match “…”` (plugin.js:7874-7885).
    private var showsNoMatches: Bool {
        isSearching && visibleBots.isEmpty && visibleForeign.isEmpty && visibleRooms.isEmpty
    }

    private var showsOnlyHiddenPrimary: Bool {
        !isSearching && !showHidden && hiddenBotCount > 0
            && visibleBots.isEmpty && visibleForeign.isEmpty && visibleRooms.isEmpty
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(theme: theme, kicker: copy.kickerHome, title: copy.titleHome) {
                headerControls
            }
            if model.showsOfflineUnreachableChrome {
                offlineBanner
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
            }
            roomMetadataOutboxBanner
                .padding(.horizontal, 16)
                .padding(.bottom, model.roomMetadataPendingCount > 0 ? 7 : 0)
            // Who is working right now — above the list, never inside it, and
            // zero height when nobody is (Components/ActiveNowStrip.swift,
            // plugin.js:6888-6937). A separate view by construction, so
            // presence can never reorder the rows beneath it — and, for the
            // same reason, it sits ABOVE the search field and reads the
            // unfiltered roster: desktop feeds the strip `roster` (7777) and
            // only the list below it `query` (7831), because "who is working"
            // is not a question about names.
            ActiveNowStrip(model: model)
            if showsSearchField {
                searchField
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(spacing: listGap) {
                    if RosterRoomPolicy.showsEmpty(primaryBots: model.bots.count,
                                                   rooms: model.rooms.count,
                                                   foreignBots: model.foreignRosterEntries.count,
                                                   isSearching: isSearching) {
                        emptyState
                            .padding(.top, 60)
                    } else if showsOnlyHiddenPrimary {
                        hiddenOnlyState
                    } else {
                        let ranked = visibleHomeItems
                        ForEach(Array(ranked.enumerated()), id: \.element.id) { index, item in
                            switch item {
                            case .bot(let bot):
                                row(for: bot, index: index)
                                    // Showing hidden is an inspection state,
                                    // not an unhide. Keep those rows visibly
                                    // secondary while their server metadata
                                    // remains `hidden: true`.
                                    .opacity(RosterVisibilityPolicy.rowOpacity(
                                        hidden: model.isRosterHidden(bot.id), showingHidden: showHidden))
                                    // Keyed by id, never by index: the entrance is
                                    // arrival, and a re-rank must not replay it.
                                    .modifier(RosterEntrance(botID: bot.id,
                                                             delay: Double(min(index, 12)) * 0.045))
                            case .foreign(let entry):
                                foreignRow(entry)
                                    .modifier(RosterEntrance(botID: entry.id,
                                                             delay: Double(min(index, 12)) * 0.045))
                            case .room(let room):
                                roomRow(room)
                                    .modifier(RosterEntrance(botID: "room:\(room.id.description)",
                                                             delay: Double(min(index, 12)) * 0.045))
                            }
                        }
                        .animation(.easeOut(duration: 0.35), value: ranked.map(\.id))
                    }
                    // Gateways that contributed no bot rows remain actionable
                    // footnotes. Actual foreign bots are already interleaved
                    // above with local bots and rooms by recency.
                    MultiGatewayRosterSection(model: model, needle: needle, includeEntries: false)
                    if showsNoMatches {
                        noMatchesRow
                            .padding(.top, 40)
                    }
                    // The footer is a census of the roster ("6 bots across 2
                    // gateways"), so it stands down while a query is narrowing
                    // the list — a count that does not match what is on screen
                    // reads as a bug, and desktop has no footer to consult.
                    if (!model.unionRosterBots.isEmpty || !model.rooms.isEmpty) && !isSearching {
                        footer
                            .padding(.top, 10)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 128) // clear the tab bar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.bg)
        // The second clause of the work-pose rule (plugin.js:3852-3856). The
        // faces below can see `Bot.status == .working` — a turn THIS app
        // watched start — but not the conversation/worker liveness windows,
        // which are the only way a cron run, the laptop or the CLI ever
        // reaches an avatar; they live in `AppModel`, which `TalariaTheme`
        // cannot import. Without
        // this line `talariaLiveBots` keeps its empty default and the whole
        // second clause is inert: the row's sway and its 6 pt dot say "alive"
        // while the face beside them stares idle.
        //
        // The set, not the union with `.working`: `AvatarView` already ORs the
        // first clause in, and publishing only the half it cannot compute
        // keeps the environment value stable while a turn starts and stops.
        .talariaLiveBots(Set(model.bots.lazy.filter { model.isActiveNow($0.id) }.map(\.id)))
        .sheet(item: $editing) { bot in
            CreateBotView(model: model, editing: bot)
        }
        .confirmationDialog(
            CopyPack.rosterDeleteTitle(
                theme.id,
                name: deleting.map { TalariaVoice.displayName(for: $0.bot, theme.id) } ?? ""),
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { candidate in
            Button(CopyPack.rosterDelete(theme.id), role: .destructive) {
                let doomed = candidate.bot
                let target = candidate.target
                deleting = nil
                Task {
                    let outcome = await model.deleteProfile(target, confirmed: true)
                    if case .deleted = outcome {
                        model.toast(kind: .success,
                                    title: CopyPack.rosterDeleted(theme.id, name: TalariaVoice.displayName(for: doomed, theme.id)),
                                    botID: doomed.id)
                    } else if case .refused(let reason) = outcome {
                        model.toast(kind: .failure,
                                    title: CopyPack.rosterDeleteFailed(theme.id),
                                    message: reason, botID: doomed.id)
                    }
                }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { _ in
            Text(CopyPack.rosterDeleteBody(theme.id))
        }
        // Ranking, the 90 s liveness window and the unread watermark all come
        // off one `profiles.list` poll. Armed here because the roster is the
        // first screen the app paints; the poll itself keeps running behind
        // other tabs (at a quarter cadence) so a cron delivery still badges.
        .task {
            RosterSignals.shared.rosterVisible = true
            model.startRosterSignals()
            // The approval-answer haptic watches a process-wide ledger rather
            // than any one screen, so it is armed from the first screen shown
            // and then covers the chat card, the Approvals tab and the push
            // banner alike (AppModelLive+Preview.swift).
            model.startFeelObservers()
            // Coming back from another tab, the numbers can be up to a slow
            // tick old; ask once on arrival rather than showing stale ranking.
            await model.refreshRosterSignalsNow()
            await model.loadRooms()
        }
        // The union roster's own refresh. It lives HERE rather than on the
        // section it feeds because that section sits inside a LazyVStack: below
        // the fold on a long roster SwiftUI never builds it, and a probe that
        // only runs when you happen to scroll to the bottom is not a refresh.
        // Tied to the screen, so leaving the tab stops dialling other people's
        // machines.
        .task { await model.superviseUnionRoster() }
        .onDisappear { RosterSignals.shared.rosterVisible = false }
        // Chat opens over the roster rather than replacing it, so this is the
        // one place that sees every route in — row tap, push, deep link,
        // palette. The bot you are reading must never badge you for the
        // conversation you are having with it.
        .onChange(of: model.openBotID) {
            if let botID = model.openBotID { model.noteChatOpened(botID) }
        }
        // The field only exists while there is a roster to narrow
        // (plugin.js:7831), so a roster that empties under a live query — the
        // gateway dropped, or the last bot was deleted — must not leave the
        // query filtering from behind a field that is no longer on screen.
        .onChange(of: showsSearchField) {
            if !showsSearchField { search = "" }
        }
    }

    @ViewBuilder private var roomMetadataOutboxBanner: some View {
        switch RoomMetadataOutboxPolicy.status(
            pendingCount: model.roomMetadataPendingCount,
            lastError: model.roomMetadataLastError
        ) {
        case .clear:
            EmptyView()
        case .waiting(let count):
            roomMetadataOutboxBannerContent(
                count: count,
                detail: "Room membership updates are waiting to sync.",
                isFailure: false
            )
        case .retryRequired(let count, _):
            roomMetadataOutboxBannerContent(
                count: count,
                detail: "Room membership could not sync. Reconnect the owning gateway and retry.",
                isFailure: true
            )
        }
    }

    private func roomMetadataOutboxBannerContent(count: Int, detail: String,
                                                  isFailure: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isFailure ? "exclamationmark.arrow.triangle.2.circlepath" :
                    "arrow.triangle.2.circlepath")
                .foregroundStyle(isFailure ? theme.danger : theme.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) room membership update\(count == 1 ? "" : "s") pending")
                    .font(theme.body(11, weight: .semibold)).foregroundStyle(theme.ink)
                Text(detail).font(theme.body(9.5)).foregroundStyle(theme.faint).lineLimit(2)
            }
            Spacer(minLength: 6)
            Button("Retry") { Task { await model.flushRoomMetadataOutbox() } }
                .buttonStyle(.plain).font(theme.body(10, weight: .bold))
                .foregroundStyle(theme.accent).frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Retry room membership updates")
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .background((isFailure ? theme.danger : theme.warn).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder((isFailure ? theme.danger : theme.warn).opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("room-metadata-outbox-banner")
    }

    // MARK: - Header controls

    private var headerControls: some View {
        HStack(spacing: 8) {
            HeaderIconButton(theme: theme, action: { model.requestSettings() }) { settingsGlyph }
                .accessibilityLabel(Text("Settings"))
            HeaderIconButton(theme: theme, action: onSearch) { searchGlyph }
            if hiddenBotCount > 0 {
                HeaderIconButton(theme: theme, action: { showHidden.toggle() }) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: showHidden ? "eye.slash" : "eye")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.ink)
                        if hiddenUnreadCount > 0 {
                            Circle()
                                .fill(theme.accent)
                                .frame(width: 6, height: 6)
                                .offset(x: 4, y: -4)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .accessibilityLabel(Text(hiddenUnreadCount > 0
                    ? "\(showHidden ? "Hide Hidden" : "Show Hidden"), \(hiddenUnreadCount) unread"
                    : (showHidden ? "Hide Hidden" : "Show Hidden")))
                .accessibilityHint(Text("Does not change hidden bot settings"))
                .accessibilityAddTraits(showHidden ? .isSelected : [])
            }
            netChip
            plusButton
        }
    }

    /// Desktop's bell / bell-slash (plugin.js:7732-7741): activity toasts on or
    /// off. Live only — demo mode's roster never moves a watermark, so the
    /// control would govern nothing there.
    ///
    /// The tooltip upstream carries ("Activity toasts on — click to silence")
    /// has no home on a phone, so it becomes the accessibility label, and the
    /// flip answers with a toast of its own.
    @ViewBuilder private var bellButton: some View {
        if model.mode == .live {
            let on = model.activityToastsEnabled
            HeaderIconButton(theme: theme, action: { model.setActivityToasts(!on) }) {
                bellGlyph(on: on)
            }
            .accessibilityLabel(Text(CopyPack.activityToastsToggle(on, theme.id)))
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }

    /// A bell, and the same bell struck through. Drawn rather than an SF Symbol
    /// for the same reason the magnifier beside it is: these two sit shoulder to
    /// shoulder and a system glyph next to a hand-drawn one reads as a mistake.
    private func bellGlyph(on: Bool) -> some View {
        let ink = on ? theme.ink : theme.ink.opacity(0.45)
        return ZStack {
            VStack(spacing: 0) {
                UnevenRoundedRectangle(topLeadingRadius: 4.5, bottomLeadingRadius: 0,
                                       bottomTrailingRadius: 0, topTrailingRadius: 4.5,
                                       style: .continuous)
                    .strokeBorder(ink, lineWidth: 1.4)
                    .frame(width: 9, height: 8.5)
                Rectangle().fill(ink).frame(width: 12, height: 1.4)
                Circle().fill(ink).frame(width: 2.6, height: 2.6).padding(.top, 0.6)
            }
            if !on {
                // The strike is drawn in the background colour first, then the
                // line — so it reads as a cut through the bell at any size
                // instead of a stroke laid over it.
                Rectangle().fill(theme.bg).frame(width: 17, height: 3)
                    .rotationEffect(.degrees(-45))
                Rectangle().fill(ink).frame(width: 17, height: 1.4)
                    .rotationEffect(.degrees(-45))
            }
        }
        .frame(width: 14, height: 14)
    }

    private var settingsGlyph: some View {
        Image(systemName: "gearshape")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(theme.ink)
    }

    /// Hand-drawn magnifier, matching the prototype's ring + handle.
    private var searchGlyph: some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .strokeBorder(theme.ink, lineWidth: 1.5)
                .frame(width: 9, height: 9)
            Rectangle()
                .fill(theme.ink)
                .frame(width: 5.5, height: 1.5)
                .rotationEffect(.degrees(45), anchor: .leading)
                .offset(x: 7, y: 7.5)
        }
        .frame(width: 14, height: 14)
    }

    /// Theme-cycle glyph: accent circle (soft), square (control), lozenge (ink).
    @ViewBuilder private var themeGlyph: some View {
        switch theme.id {
        case .soft:
            Circle().fill(theme.accent).frame(width: 13, height: 13)
        case .control:
            RoundedRectangle(cornerRadius: 2).fill(theme.accent).frame(width: 13, height: 13)
        case .ink:
            Rectangle().fill(theme.accent).frame(width: 11, height: 11)
                .rotationEffect(.degrees(45))
        }
    }

    private var netChip: some View {
        let chip = TalariaVoice.netChip(offline: model.showsOfflineUnreachableChrome,
                                        connections: model.connections,
                                        theme.id)
        let color = TalariaVoice.netColor(chip.tone, theme: theme)
        return Button(action: onConnections) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .shadow(color: theme.glowRadius > 0 ? color : .clear, radius: 4)
                    .glowPulse(period: 2.3)
                Text(chip.label)
                    .lineLimit(1)
                    .font(chipFont)
                    .tracking(theme.id == .ink ? 1.5 : 0)
                    .foregroundStyle(theme.id == .ink ? theme.ink.opacity(0.6) : theme.ink)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .chipShell(theme)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                model.requestCommandCenter(gatewayID: model.activeGatewayID)
            } label: {
                Label("Open Command Center", systemImage: "square.grid.2x2")
            }
        }
        .accessibilityLabel(Text("Connections, " + chip.label))
        .accessibilityHint(Text("Opens gateways and notifications"))
        .accessibilityAction(named: Text("Open Command Center")) {
            model.requestCommandCenter(gatewayID: model.activeGatewayID)
        }
    }

    private var chipFont: Font {
        switch theme.id {
        case .soft: theme.body(12, weight: .semibold)
        case .control: theme.mono(10.5, weight: .semibold)
        case .ink: theme.mono(9)
        }
    }

    private var plusButton: some View {
        Button(action: onCreate) {
            Text(verbatim: "+")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.id == .ink ? theme.bg : theme.accentFg)
                .padding(.bottom, 2)
                .frame(width: 32, height: 32)
                .background(theme.id == .ink ? theme.ink : theme.accent)
                .clipShape(plusShape)
                .contentShape(plusShape)
        }
        .buttonStyle(.plain)
        .shadow(color: plusShadow, radius: theme.glowRadius > 0 ? 9 : 5, y: theme.id == .soft ? 4 : 0)
    }

    private var plusShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .control ? 6 : 16, style: .continuous)
    }

    private var plusShadow: Color {
        switch theme.id {
        case .soft: theme.accent.opacity(0.32)
        case .control: theme.accent.opacity(0.35)
        case .ink: .clear
        }
    }

    // MARK: - Search field

    /// Desktop's roster `SearchField` (plugin.js:7831-7842): full width, one
    /// placeholder, aria-label 'Search bots'. It narrows the list in place —
    /// the magnifier in the header still opens the palette, which is a
    /// different verb (jump to anything, anywhere).
    private var searchField: some View {
        HStack(spacing: 9) {
            searchGlyph
                .opacity(0.5)
            TextField(CopyPack.rosterSearchPlaceholder(theme.id), text: $search)
                .font(searchFont)
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                #endif
                .textFieldStyle(.plain)
                .accessibilityLabel(Text(CopyPack.rosterSearchLabel(theme.id)))
            if !search.isEmpty {
                Button { search = "" } label: {
                    Text(verbatim: "✕")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.faint)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(CopyPack.rosterSearchClear(theme.id)))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(theme.panel)
        .clipShape(searchShape)
        .overlay(searchShape.strokeBorder(
            theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))
    }

    private var searchShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: min(theme.inputRadius, 19), style: .continuous)
    }

    private var searchFont: Font {
        switch theme.id {
        case .soft: theme.body(13.5)
        case .control: theme.mono(11.5)
        case .ink: theme.body(15)
        }
    }

    /// Desktop's `No bots match “<query>”` (plugin.js:7874-7885), which is a
    /// `role='status' aria-live='polite'` region — the SwiftUI equivalent is a
    /// plain label the focus lands on when the rows vanish.
    private var noMatchesRow: some View {
        Text(CopyPack.rosterSearchNoMatch(search.trimmingCharacters(in: .whitespaces), theme.id))
            .font(theme.id == .control ? theme.mono(11) : theme.body(theme.id == .ink ? 15 : 13))
            .italic(theme.id == .ink)
            .multilineTextAlignment(.center)
            .foregroundStyle(theme.sub)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
    }

    // MARK: - Offline banner

    private var offlineBanner: some View {
        Group {
            switch theme.id {
            case .soft:
                Text(copy.offline)
                    .font(theme.body(12, weight: .semibold))
                    .foregroundStyle(theme.danger)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(theme.danger.opacity(0.25), lineWidth: 1))
            case .control:
                Text(copy.offline)
                    .font(theme.mono(10.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(theme.danger)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.danger.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(theme.danger.opacity(0.35), lineWidth: 1))
            case .ink:
                Text(copy.offline)
                    .font(theme.mono(9))
                    .tracking(1.5)
                    .foregroundStyle(theme.danger)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(Rectangle().strokeBorder(theme.danger.opacity(0.5), lineWidth: 1))
            }
        }
    }

    // MARK: - Rows

    private func roomRow(_ room: RoomRecord) -> some View {
        RoomRow(room: room, theme: theme, avatarData: model.roomAvatarData(room.id)) {
            model.feedback(.open)
            model.openBotID = nil
            model.openRoomID = room.id
        }
        .padding(rowPadding)
        .background(rowBackground)
        .overlay(alignment: .bottom) {
            if theme.rowStyle == .ledger {
                Rectangle().fill(theme.ink.opacity(0.16)).frame(height: 1)
            }
        }
    }

    private func foreignRow(_ entry: ForeignRosterEntry) -> some View {
        let bot = model.rosterBot(for: entry)
        let badgeState: ConnectionBadge.State = entry.needsSignIn ? .needsSignIn
            : entry.isStale ? .stale : .live
        return Button {
            Task { @MainActor in await model.openForeignBot(entry) }
        } label: {
            HStack(alignment: .center, spacing: 13) {
                AvatarView(bot: bot, size: 38, theme: theme)
                    .opacity(entry.isStale || entry.needsSignIn ? 0.45 : 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        BotIdentityLabel(bot: bot, theme: theme, scale: .row)
                        ConnectionBadge(label: entry.connectionLabel,
                                        kind: entry.connectionKind,
                                        state: badgeState, theme: theme)
                    }
                    Text(foreignStatus(entry))
                        .font(previewFont(hot: false)).foregroundStyle(theme.faint)
                        .lineLimit(1).truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.faint)
            }
            .padding(rowPadding).background(rowBackground)
            .overlay(alignment: .bottom) {
                if theme.rowStyle == .ledger {
                    Rectangle().fill(theme.ink.opacity(0.1)).frame(height: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func foreignStatus(_ entry: ForeignRosterEntry) -> String {
        if entry.needsSignIn { return copy.gatewayNeedsSignIn(theme.id) }
        if entry.isStale {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return copy.gatewayLastSeen(
                formatter.localizedString(for: entry.fetchedAt, relativeTo: .now), theme.id)
        }
        let preview = entry.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty ? copy.remoteBotReady(entry.connectionLabel, theme.id) : preview
    }

    private func row(for bot: Bot, index: Int) -> some View {
        Button {
            // First statement, before any state write and before the async
            // resume — desktop's rule (plugin.js:3900), and the reason for it
            // is sharper on a phone: the feedback has to land under the thumb
            // that is still on the glass, however slow the open turns out to
            // be. It marks leaving this surface; nothing else on the roster
            // buzzes except the pin below.
            model.feedback(.open)
            // openChat, never a raw openBotID write: it is what resumes the
            // bot's canonical forever-chat and hydrates the transcript. A bare
            // navigation write opens an empty chat whose first send forks a
            // brand-new session away from the bot's real history.
            model.openChat(botID: bot.id)
        } label: {
            HStack(alignment: .center, spacing: 13) {
                avatar(for: bot)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        nameText(for: bot)
                        jobText(for: bot)
                    }
                    statusLine(for: bot, index: index)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 5) {
                    timeText(for: bot)
                    HStack(spacing: 6) {
                        activeDot(for: bot)
                        badge(for: bot)
                    }
                }
            }
            .padding(rowPadding)
            .background(rowBackground)
            .overlay(alignment: .bottom) {
                if theme.rowStyle == .ledger {
                    Rectangle().fill(theme.ink.opacity(0.16)).frame(height: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { rowMenu(for: bot) }
    }

    /// Desktop's row context menu (plugin.js:3466-3515). Tap still opens the
    /// forever-chat; long-press is how you reach Sessions, a scratch chat,
    /// look editing, duplicate, and delete without turning the roster into a
    /// session sidebar.
    @ViewBuilder private func rowMenu(for bot: Bot) -> some View {
        let pinned = model.isPinned(bot.id)
        let hidden = model.isRosterHidden(bot.id)
        Button {
            Task { await model.pinBotWithFeedback(botID: bot.id, pinned: !pinned) }
        } label: {
            Label(pinned ? CopyPack.rosterUnpin(theme.id) : CopyPack.rosterPin(theme.id),
                  systemImage: pinned ? "pin.slash" : "pin")
        }
        Button {
            NotificationCenter.default.post(name: .talariaOpenSessions, object: bot.id)
        } label: {
            Label(CopyPack.rosterSessions(theme.id), systemImage: "clock.arrow.circlepath")
        }
        Button {
            Task { _ = await model.setBotHidden(botID: bot.id, hidden: !hidden) }
        } label: {
            Label(hidden ? "Unhide" : "Hide", systemImage: hidden ? "eye" : "eye.slash")
        }
        Button {
            editing = bot
        } label: {
            Label(copy.editLook, systemImage: "paintbrush")
        }
        Button {
            Task { await model.duplicateBotWithFeedback(from: bot.id) }
        } label: {
            Label(CopyPack.rosterDuplicate(theme.id), systemImage: "plus.square.on.square")
        }
        Button {
            Task { await model.openScratchChat(botID: bot.id) }
        } label: {
            Label(CopyPack.rosterNewChat(theme.id), systemImage: "plus.bubble")
        }
        if let candidate = RosterDeleteCandidate.resolve(
            bot: bot, target: model.profileLifecycleTarget(rosterID: bot.id)
        ) {
            Button(role: .destructive) {
                deleting = candidate
            } label: {
                Label(CopyPack.rosterDelete(theme.id), systemImage: "trash")
            }
        }
    }

    private func avatar(for bot: Bot) -> some View {
        // A bot that spoke in the last 90 s wears its working face even when
        // this app never saw the turn — a cron run, the laptop, another client
        // (plugin.js:3852-3856: the pose is conditional, never ambient).
        let live = bot.status == .working || model.isActiveNow(bot.id)
        return ZStack {
            if bot.status == .working {
                WorkingPulse(color: theme.id == .ink ? theme.ink.opacity(0.55)
                                : theme.color(for: bot.hue),
                             lineWidth: theme.id == .soft ? 2 : 1.5)
                    .frame(width: 54, height: 54)
            }
            // One face path. `BotPortraitView` draws the profile's own portrait
            // when one has been fetched AND judged a real picture, and the live
            // geometric face otherwise — so the row cannot decide one way on
            // the first paint and the other way on the next poll.
            BotPortraitView(model: model, bot: bot, size: 46, theme: theme)
                .modifier(AvatarSway(botID: bot.id, working: live))
        }
        .frame(width: 46, height: 46)
        // Bot Mode's petMode: the profile's mascot keeps a working bot
        // company. Pinned to the avatar's corner like the prototype's marker —
        // an overlay, so a pet appearing never reflows the row, and it renders
        // nothing at all on a gateway without pets.
        .overlay(alignment: .bottomTrailing) {
            if bot.status == .working {
                PetCompanionView(model: model, bot: bot)
                    .offset(x: 4, y: 2)
            }
        }
    }

    /// Title + @handle, from the one identity path
    /// (Components/BotIdentity.swift) — the same pair the profile sheet
    /// renders, so a bot never reads two different names in two places.
    /// A pinned bot carries its marker at the head of the cluster, where
    /// desktop puts its 📌 (plugin.js:3972-3978), and it never truncates.
    private func nameText(for bot: Bot) -> some View {
        HStack(spacing: 5) {
            if model.isPinned(bot.id) {
                Image(systemName: "pin.fill")
                    .font(.system(size: theme.id == .ink ? 8.5 : 9.5))
                    .foregroundStyle(theme.faint)
                    .accessibilityLabel(Text(CopyPack.rosterPinnedMarker(theme.id)))
            }
            BotIdentityLabel(bot: bot, theme: theme, scale: .row)
        }
    }

    private func jobText(for bot: Bot) -> some View {
        Group {
            switch theme.id {
            case .soft:
                Text(bot.job).font(theme.body(11, weight: .semibold))
                    .foregroundStyle(theme.ink.opacity(0.38))
            case .control:
                Text(bot.job.uppercased()).font(theme.mono(9, weight: .semibold))
                    .tracking(1.2).foregroundStyle(theme.ink.opacity(0.35))
            case .ink:
                Text(bot.job.uppercased()).font(theme.mono(8.5))
                    .tracking(1.5).foregroundStyle(theme.ink.opacity(0.45))
            }
        }
        .lineLimit(1)
    }

    /// The live line: working = task + ticking elapsed, approval/mention/idle
    /// = preview, tinted and weighted per state. Control appends a blinking
    /// block cursor while working.
    ///
    /// The elapsed readout ticks on a timeline scoped to THIS row, and only
    /// while the row is working. It used to be one app-wide 1 s counter in
    /// view state, which repainted the whole roster every second whether or
    /// not anything was running — desktop's cost model is the opposite: "an
    /// empty roster costs zero frames" (BOT-MODE-PARITY §4.2).
    @ViewBuilder private func statusLine(for bot: Bot, index: Int) -> some View {
        if bot.status == .working {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                // Per-row second offset so timers don't tick in lockstep
                // (prototype: `(secs + i * 17) % 60`).
                let tick = Int(context.date.timeIntervalSinceReferenceDate)
                workingText(for: bot, seconds: (tick + index * 17) % 60)
            }
        } else {
            previewText(for: bot)
        }
    }

    /// A working row says what it is doing, not what it last said.
    private func workingText(for bot: Bot, seconds: Int) -> some View {
        HStack(spacing: 6) {
            Text(TalariaVoice.rosterLine(for: bot, seconds: seconds, theme.id))
                .font(previewFont(hot: true))
                .italic(theme.id == .ink)
                .foregroundStyle(previewColor(for: bot))
                .lineLimit(1)
                .truncationMode(.tail)
                .monospacedDigit()
            if theme.id == .control {
                BlinkingCursor(color: theme.color(for: bot.hue))
            }
        }
    }

    /// An idle row says what was last said — flattened out of markdown, with
    /// the delivery prefix moved into a `🤖 @sender` chip when another bot was
    /// the one talking (Components/RosterPreview.swift).
    private func previewText(for bot: Bot) -> some View {
        let preview = model.rosterPreview(for: bot)
        let hot = bot.mentionsYou || bot.status == .approval
        // Weight stays desktop's: a delivery is marked by the chip, the accent
        // and the italic, not by shouting. Only a mention or a held approval
        // earns the heavier face.
        return RosterPreviewLine(preview: preview,
                                 theme: theme,
                                 tint: previewColor(for: bot),
                                 font: previewFont(hot: hot),
                                 italic: theme.id == .ink && bot.mentionsYou)
    }

    /// Relative time — "4m", "2h" — reads better on a chat roster than a wall
    /// clock (plugin.js:4011-4016). A bot with no history gets the themed
    /// "new" rather than desktop's nothing: on a phone the column would
    /// otherwise look broken, and "new" is true.
    private func timeText(for bot: Bot) -> some View {
        let relative = model.rosterTimeLabel(bot.id)
        let label = relative.isEmpty
            ? (bot.previewTime.isEmpty ? CopyPack.rosterNever(theme.id) : bot.previewTime)
            : relative
        return Text(label)
            .font(timeFont)
            .monospacedDigit()
            .foregroundStyle(theme.id == .soft ? theme.ink.opacity(0.38) : theme.faint)
    }

    /// "Active in the last 90s" — 6 pt, opacity-pulsing, and deliberately a
    /// different animal from the unread badge beside it: solid and bigger
    /// means you have something to read, smaller and breathing means it is
    /// alive right now (plugin.js:4005-4010, BOT-MODE-PARITY §4.4).
    @ViewBuilder private func activeDot(for bot: Bot) -> some View {
        if model.isActiveNow(bot.id) {
            Group {
                if reducedMotion {
                    Circle().fill(theme.id == .ink ? theme.ink : theme.accent)
                } else {
                    Circle().fill(theme.id == .ink ? theme.ink : theme.accent)
                        .glowPulse(period: 1.2)
                }
            }
            .frame(width: 6, height: 6)
            .accessibilityLabel(Text(CopyPack.rosterActiveNow(theme.id)))
        }
    }

    private func previewFont(hot: Bool) -> Font {
        switch theme.id {
        case .soft: theme.body(13, weight: hot ? .semibold : .regular)
        case .control: theme.mono(11, weight: hot ? .semibold : .regular)
        case .ink: theme.body(14.5, weight: hot ? .semibold : .regular)
        }
    }

    private func previewColor(for bot: Bot) -> Color {
        if bot.mentionsYou {
            return theme.id == .control ? theme.color(for: .pink) : theme.accent
        }
        if bot.status == .approval {
            return theme.id == .control ? theme.warn : theme.danger
        }
        if bot.status == .working {
            return theme.id == .soft ? theme.color(for: bot.hue) : theme.ink
        }
        return theme.sub
    }

    private var timeFont: Font {
        switch theme.id {
        case .soft: theme.body(11, weight: .medium)
        case .control: theme.mono(10)
        case .ink: theme.mono(9)
        }
    }

    @ViewBuilder private func badge(for bot: Bot) -> some View {
        if bot.unread > 0 || bot.status == .approval {
            let isHold = bot.status == .approval
            let text = isHold ? "!" : String(bot.unread)
            let bg: Color = theme.id == .ink ? theme.danger
                : isHold ? (theme.id == .control ? theme.warn : theme.danger)
                : theme.accent
            let fg: Color = theme.id == .control ? theme.bg
                : theme.id == .ink ? theme.bg : theme.accentFg

            Group {
                switch theme.id {
                case .soft:
                    Text(text).font(theme.body(11, weight: .bold))
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(bg, in: RoundedRectangle(cornerRadius: 9))
                case .control:
                    Text(text).font(theme.mono(10, weight: .bold))
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(bg, in: RoundedRectangle(cornerRadius: 3))
                case .ink:
                    Text(text).font(theme.mono(9.5, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .background(bg, in: Circle())
                        .shadow(color: theme.ink.opacity(0.3), radius: 1.5, y: 1)
                }
            }
            .foregroundStyle(fg)
            // A bare digit beside a bot's name is read out as a number with no
            // noun attached — "3" could as easily be a model or a position in
            // the list. The hold marker has the same problem one step further
            // on: its glyph is "!", which VoiceOver reads as punctuation or not
            // at all.
            .accessibilityLabel(Text(isHold ? CopyPack.rosterHoldMarker(theme.id)
                                            : CopyPack.unreadBadge(bot.unread, theme.id)))
        }
    }

    private var rowPadding: EdgeInsets {
        switch theme.rowStyle {
        case .card: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        case .terminal: EdgeInsets(top: 12, leading: 13, bottom: 12, trailing: 13)
        case .ledger: EdgeInsets(top: 14, leading: 2, bottom: 14, trailing: 2)
        }
    }

    @ViewBuilder private var rowBackground: some View {
        switch theme.rowStyle {
        case .card:
            RoundedRectangle(cornerRadius: theme.rowRadius)
                .fill(theme.panel)
                .overlay(RoundedRectangle(cornerRadius: theme.rowRadius)
                    .strokeBorder(theme.ink.opacity(0.05), lineWidth: 1))
                .shadow(color: theme.ink.opacity(0.04), radius: 1.5, y: 1)
        case .terminal:
            RoundedRectangle(cornerRadius: theme.rowRadius)
                .fill(theme.panel)
                .overlay(RoundedRectangle(cornerRadius: theme.rowRadius)
                    .strokeBorder(theme.line, lineWidth: 1))
        case .ledger:
            Color.clear
        }
    }

    // MARK: - Footer

    private var footer: some View {
        let bots = TalariaVoice.rosterFooter(botCount: model.unionRosterBots.count,
                                             gatewayCount: max(model.connections.count, 1),
                                             theme.id)
        let roomCount = model.rooms.count
        let rooms = roomCount == 1 ? "1 room" : "\(roomCount) rooms"
        return Text(roomCount == 0 ? bots : "\(bots) · \(rooms)")
            .font(footFont)
            .tracking(theme.id == .soft ? 0 : theme.id == .control ? 1 : 2)
            .foregroundStyle(theme.id == .soft ? theme.ink.opacity(0.35)
                : theme.id == .control ? theme.ink.opacity(0.3) : theme.ink.opacity(0.4))
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
    }

    private var footFont: Font {
        switch theme.id {
        case .soft: theme.body(12)
        case .control: theme.mono(10)
        case .ink: theme.mono(8.5)
        }
    }
}

// MARK: - Roster copy (the three voices)

extension CopyPack {

    static func deletingProfile(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Deleting…"
        case .control: "DELETING…"
        case .ink: "unmaking…"
        }
    }

    static func rosterPin(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Pin to top"
        case .control: "PIN TO TOP"
        case .ink: "Keep at the head"
        }
    }

    static func rosterUnpin(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Unpin"
        case .control: "UNPIN"
        case .ink: "Release from the head"
        }
    }

    static func rosterDuplicate(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Duplicate"
        case .control: "DUPLICATE"
        case .ink: "Copy the familiar"
        }
    }

    static func rosterSessions(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Sessions"
        case .control: "SESSIONS"
        case .ink: "the other conversations"
        }
    }

    static func rosterNewChat(_ t: ThemeID) -> String {
        switch t {
        case .soft: "New chat with this agent"
        case .control: "NEW CHAT WITH THIS AGENT"
        case .ink: "open a throwaway page"
        }
    }

    static func rosterDelete(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Delete"
        case .control: "DELETE"
        case .ink: "unmake this familiar"
        }
    }

    static func rosterDeleteTitle(_ t: ThemeID, name: String) -> String {
        switch t {
        case .soft: "Delete \(name)?"
        case .control: "DELETE \(name.uppercased())?"
        case .ink: "Unmake \(name)?"
        }
    }

    static func rosterDeleteBody(_ t: ThemeID) -> String {
        switch t {
        case .soft: "This removes the profile, its forever-chat pin, and its look. The default Hermes profile cannot be deleted."
        case .control: "DESTROYS THE PROFILE, PIN, AND LOOK. DEFAULT CANNOT BE DELETED."
        case .ink: "The familiar, its pin, and its guise go together. Hermes itself cannot be unmade."
        }
    }

    static func rosterDeleted(_ t: ThemeID, name: String) -> String {
        switch t {
        case .soft: "Deleted \(name)"
        case .control: "DELETED \(name.uppercased())"
        case .ink: "\(name) is unmade"
        }
    }

    static func rosterDeleteFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Couldn’t delete this bot"
        case .control: "DELETE FAILED"
        case .ink: "It would not be unmade"
        }
    }

    /// Screen-reader name for the pin marker; desktop's tooltip is "Pinned".
    static func rosterPinnedMarker(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Pinned"
        case .control: "PINNED"
        case .ink: "kept at the head"
        }
    }

    /// Screen-reader name for the badge in its hold form. The glyph is a bare
    /// "!", which VoiceOver reads as punctuation or not at all.
    static func rosterHoldMarker(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Waiting for approval"
        case .control: "AWAITING APPROVAL"
        case .ink: "held, pending your leave"
        }
    }

    /// Screen-reader name for the liveness dot — desktop's title is
    /// "Active in the last 90s" (plugin.js:4008).
    static func rosterActiveNow(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Active in the last 90 seconds"
        case .control: "ACTIVE WITHIN 90S"
        case .ink: "stirring within the minute and a half"
        }
    }

    /// A bot with no conversation behind it yet.
    static func rosterNever(_ t: ThemeID) -> String {
        switch t {
        case .soft: "new"
        case .control: "NEW"
        case .ink: "unwritten"
        }
    }

    /// Desktop's placeholder is 'Search bots…' with the single ellipsis
    /// character, not three dots (plugin.js:7838).
    static func rosterSearchPlaceholder(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Search bots and rooms…"
        case .control: "FILTER ROSTER + ROOMS…"
        case .ink: "Seek a name or room…"
        }
    }

    /// Screen-reader name expands desktop's bot-only field because the mobile
    /// home roster also contains durable rooms.
    static func rosterSearchLabel(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Search bots and rooms"
        case .control: "FILTER ROSTER AND ROOMS"
        case .ink: "seek a name or room"
        }
    }

    static func rosterSearchClear(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Clear search"
        case .control: "CLEAR FILTER"
        case .ink: "let the roll stand whole"
        }
    }

    /// Desktop: `No bots match “<query>”` (plugin.js:7884). Rooms share this
    /// mobile list, so the empty result names both kinds. The query is shown
    /// as typed — the '@' strip is a matching rule, not a correction, so
    /// quoting the stripped needle back would look like a typo the app made.
    static func rosterSearchNoMatch(_ query: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: "No bots or rooms match “\(query)”"
        case .control: "NO MATCH: \(query.uppercased())"
        case .ink: "None on the roll answer to “\(query)”"
        }
    }
}

// MARK: - Local effects

/// The prototype's `cursorU`: a hard step blink, on for half the second.
private struct BlinkingCursor: View {
    var color: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            Rectangle()
                .fill(color)
                .frame(width: 6, height: 11)
                .opacity(on ? 1 : 0)
        }
    }
}

/// rowU — staggered fade + rise entrance.
///
/// Two rules from BOT-MODE-PARITY §4.2, which calls this Talaria's own
/// invention and better than desktop's nothing: the stagger is CAPPED by the
/// caller so a 40-bot roster does not spend two seconds arriving, and a row
/// only ever enters ONCE per gateway. Rows recycle constantly here — a
/// re-rank, a scroll back up, a tab switch — and animation that reads as
/// arrival the first time reads as a slow load every time after.
private struct RosterEntrance: ViewModifier {
    var botID: String
    var delay: Double
    @State private var shown = false
    @Environment(\.talariaReducedMotion) private var reducedMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            // Damped, the row still fades in — but it does not travel, and the
            // stagger collapses so the whole roster is legible at once.
            .offset(y: shown || reducedMotion ? 0 : 12)
            .onAppear {
                guard !shown else { return }
                guard RosterSignals.shared.entered.insert(botID).inserted else {
                    shown = true
                    return
                }
                if reducedMotion {
                    withAnimation(.easeOut(duration: 0.2)) { shown = true }
                } else {
                    withAnimation(.easeOut(duration: 0.45).delay(delay)) { shown = true }
                }
            }
    }
}

/// The idle sway and the working lean (plugin.js:999-1025, 3852-3856).
///
/// Desktop re-projects a 52-point face outline every frame; SwiftUI's answer
/// to the same impression is a static silhouette under a rotation, which is
/// what BOT-MODE-PARITY §4.2 recommends as "the single highest-leverage feel
/// change in this region". Idle is ±1.5° — breathing, not bouncing. Working
/// leans into the work, because a bot bent over its task is a more legible
/// status cue than any spinner.
///
/// Deliberately NOT desktop's per-frame clock: a repeating implicit animation
/// runs on the render server, so a swaying roster re-evaluates zero view
/// bodies and an idle phone is left alone. Desktop's own budget rule points
/// the same way — "an empty roster costs zero frames" — it just has to reach
/// it by hand in a browser.
private struct AvatarSway: ViewModifier {
    var botID: String
    var working: Bool
    @Environment(\.talariaReducedMotion) private var reducedMotion
    @State private var swung = false

    /// ±1.5° idle; working leans forward and sways wider.
    private var amplitude: Double { working ? 4 : 1.5 }
    private var center: Double { working ? -6 : 0 }
    private var period: Double { working ? 2.8 : 6.2 }

    /// Per-bot phase so a roster of faces never sways in lockstep. Stable
    /// across launches: the same bot always starts on the same beat.
    private var phase: Double {
        Double(abs(AppModel.stableHash(botID)) % 240) / 100
    }

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(reducedMotion ? 0 : center + (swung ? amplitude : -amplitude)),
                            anchor: UnitPoint(x: 0.5, y: 0.7))
            .animation(reducedMotion ? nil : .easeInOut(duration: period)
                        .repeatForever(autoreverses: true).delay(phase),
                       value: swung)
            .onAppear { swung = true }
            // Starting or finishing a turn changes the pose; toggling restarts
            // the repeat with the new lean instead of leaving it mid-swing on
            // the old one.
            .onChange(of: working) { swung.toggle() }
    }
}
