import SwiftUI
import TalariaKit
import TalariaTheme

public enum BotProfileDetailPolicy {
    public static let recentSessionLimit = 3
    public static func recentSessions(_ sessions: [SessionSummary]) -> [SessionSummary] {
        Array(sessions.prefix(recentSessionLimit))
    }
    public static func showsAllSessions(total: Int) -> Bool {
        total > recentSessionLimit
    }
}

// Bot Profile sheet — design-map.md §4 "Bot Profile" (prototype screen `detail`).
//
// Large avatar (the profile's generated portrait when it has one) + description,
// stat cards, recent sessions, the context-window meter, the per-bot YOLO
// toggle, model pin, compact memory summary, and source-fenced profile actions.
//
// Live mode backs the sheet with real data on open: session.list {profile} for
// the sessions group, session.context_breakdown for the meter (only when the
// bot already has an attached session — opening a profile sheet must never
// mint one), profiles.describe for skill/toolset counts and the model pin, and
// profiles.get_asset for the portrait. Demo values remain the fallback so the
// canned world still reads correctly.

@MainActor
public struct BotSheetView: View {
    private let model: AppModel
    private let botID: String

    @Environment(\.dismiss) private var dismiss
    @State private var showEditor = false
    @State private var showPets = false
    @State private var showSessions = false
    @State private var showModels = false
    @State private var showDeleteConfirmation = false

    /// profiles.describe snapshot — skills/toolsets counts and the pin.
    @State private var snapshot: ProfileSnapshot?
    @State private var modelChoices: [ModelChoice] = []
    @State private var pinWarning = false
    @State private var duplicating = false
    @State private var duplicateFailed = false
    @State private var deletingProfile = false
    /// False until the open-time RPCs settle, so empty cards say "reading…"
    /// instead of claiming the bot has nothing.
    @State private var hydrated = false

    public init(model: AppModel, botID: String) {
        self.model = model
        self.botID = botID
    }

    public init(model: AppModel, bot: Bot) {
        self.init(model: model, botID: bot.id)
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    private var style: DetailStyle { DetailStyle(t: theme) }

    /// The one identity path (Components/BotIdentity.swift): the roster row
    /// when there is one, else an unlisted stand-in that still applies
    /// displayTitle/handle's rules.
    private var bot: Bot { model.identity(botID) }

    private var isLive: Bool { model.mode == .live }

    /// session.list rows when live; the demo dictionary otherwise.
    private var sessions: [SessionSummary] {
        let live = model.chats[botID]?.storedSessions ?? []
        if !live.isEmpty { return live }
        if isLive { return [] }
        return model.sessions[botID] ?? model.sessions["default"] ?? []
    }

    /// session.context_breakdown segments when live; the demo meter otherwise.
    private var contextSegments: [ContextSegment] {
        let live = model.chats[botID]?.contextSegments ?? []
        if !live.isEmpty { return live }
        return isLive ? [] : model.contextMeter
    }

    private var memory: BotMemory {
        model.memory[botID] ?? model.memory["default"]
            ?? BotMemory(skillCount: 0, memoryCount: 0, recent: [])
    }

    private var enabledSkillCount: Int {
        guard isLive else { return memory.skillCount }
        return snapshot.map { $0.skills.filter(\.enabled).count } ?? memory.skillCount
    }

    private var enabledToolsetCount: Int {
        snapshot.map { $0.toolsets.filter(\.enabled).count } ?? 0
    }

    private var yoloOn: Bool { model.chats[botID]?.yolo ?? false }

    private var contextTotal: Int {
        min(100, contextSegments.reduce(0) { $0 + $1.percent })
    }

    private var recentSessions: [SessionSummary] {
        BotProfileDetailPolicy.recentSessions(sessions)
    }

    // Star map: positions/sizes/delays ported from the prototype's `stars`.
    private static let stars: [(x: CGFloat, y: CGFloat)] = [
        (0.16, 0.26), (0.34, 0.12), (0.55, 0.20), (0.78, 0.30),
        (0.86, 0.62), (0.64, 0.74), (0.38, 0.64), (0.22, 0.48),
    ]

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    identityRow
                    statCards
                    sectionLabel(copy.sessionsSec)
                    sessionsGroup
                    sectionLabel(CopyPack.runtimeSection(theme.id))
                    runtimeCard
                    sectionLabel(copy.memorySec)
                    memorySummaryCard
                    sectionLabel(CopyPack.actionsSection(theme.id))
                    actionsGroup
                    if duplicateFailed {
                        Text(CopyPack.duplicateFailed(theme.id))
                            .font(style.footNoteFont)
                            .foregroundStyle(theme.danger)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 60)
            }
        }
        .background(theme.bg.ignoresSafeArea())
        .presentationBackground(theme.bg)
        // Re-read after an edit: skills, toolsets and the pin may all have moved.
        .sheet(isPresented: $showEditor, onDismiss: { Task { await hydrate() } }) {
            CreateBotView(model: model, editing: model.bot(botID))
        }
        .confirmationDialog(
            CopyPack.rosterDeleteTitle(
                theme.id, name: TalariaVoice.displayName(for: bot, theme.id)),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(CopyPack.rosterDelete(theme.id), role: .destructive) {
                deleteCurrentProfile()
            }
            Button(copy.cancel, role: .cancel) {}
        } message: {
            Text(CopyPack.rosterDeleteBody(theme.id))
        }
        .task(id: botID) { await hydrate() }
    }

    /// One pass of live hydration when the sheet opens. Every leg degrades on
    /// its own: a gateway that cannot answer one of them just leaves that card
    /// on its themed empty state.
    private func hydrate() async {
        async let choices = model.modelChoices(botID: botID)
        async let described = model.profileSnapshot(botID: botID)
        // session.list + session.context_breakdown live in AppModelLive+Sessions.
        await model.refreshSessions(botID: botID)
        await model.refreshContext(botID: botID)
        // Two small RPCs that decide whether this profile has a pet surface at
        // all; a gateway without one answers {enabled:false} / -32601 and the
        // row simply never appears.
        await model.probePets(profile: botID)
        modelChoices = await choices
        snapshot = await described
        hydrated = true
    }

    /// Empty-state text that never lies about which of the three cases it is:
    /// still loading, the gateway said why it failed, or genuinely empty.
    private func emptyLine(_ absent: String, error: String? = nil) -> String {
        if let error { return error }
        return hydrated ? absent : CopyPack.catalogLoading(theme.id)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Text("‹")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(style.backFg)
                    .frame(width: 31, height: 31)
                    .background(iconButtonChrome)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Same pair the roster row renders — title plus the @handle when
            // it adds anything (desktop's `showsHandle`).
            BotIdentityLabel(bot: bot, theme: theme, scale: .sheet)
                .layoutPriority(1)

            Spacer(minLength: 8)

            // The job yields first: a long title with its handle must not push
            // the identity into a truncation the job could have absorbed.
            Text(theme.id == .soft ? bot.job : bot.job.uppercased())
                .font(style.jobFont)
                .tracking(style.jobTracking)
                .foregroundStyle(theme.faint)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var iconButtonChrome: some View {
        let radius: CGFloat = theme.iconCornerFraction >= 0.5 ? 15.5 : theme.iconCornerFraction * 44
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if theme.id == .ink {
            shape.stroke(theme.lineStrong, lineWidth: 1)
        } else {
            shape.fill(theme.panel).overlay(shape.stroke(theme.line, lineWidth: 1))
        }
    }

    // MARK: - Identity + stats

    private var identityRow: some View {
        HStack(spacing: 13) {
            BotPortraitView(model: model, bot: bot, size: 58, theme: theme)
            // Fallback copy ported from the prototype (not part of CopyPack).
            Text(bot.description ?? "A fresh profile. Its story is unwritten.")
                .font(style.aSubPlainFont)
                .foregroundStyle(theme.sub)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Live mode counts what the gateway actually reports: stored sessions,
    /// enabled skills, enabled toolsets. "Memories" stays a demo-only number —
    /// no profiles.* RPC exposes memory rows.
    private var statCards: some View {
        HStack(spacing: 8) {
            statCard(String(sessions.count), CopyPack.statSessions(theme.id))
            if isLive {
                statCard(String(enabledToolsetCount), CopyPack.statToolsets(theme.id))
            } else {
                statCard(String(memory.memoryCount), CopyPack.statMemories(theme.id))
            }
            statCard(String(enabledSkillCount), CopyPack.statSkills(theme.id))
        }
    }

    private func statCard(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(style.apTitleFont)
                .foregroundStyle(theme.ink)
            Text(label)
                .font(style.timeFont)
                .foregroundStyle(theme.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .modifier(DetailCardChrome(theme: theme))
    }

    // MARK: - Recent sessions

    @ViewBuilder private var sessionsGroup: some View {
        if sessions.isEmpty {
            Text(emptyLine(CopyPack.noStoredSessions(theme.id),
                           error: model.sessionsLoadError(for: botID)))
                .font(style.aSubFont)
                .foregroundStyle(theme.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))
                .modifier(DetailCardChrome(theme: theme))
        } else {
            VStack(spacing: 0) {
                ForEach(recentSessions) { session in
                    Button {
                        openSession(session)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(session.title)
                                    .font(style.aTextFont)
                                    .foregroundStyle(theme.ink)
                                    .lineLimit(1)
                                Text("\(session.when) · \(session.messageCount) msgs")
                                    .font(style.timeFont)
                                    .foregroundStyle(theme.faint)
                            }
                            Spacer(minLength: 8)
                            Text("›")
                                .font(style.timeFont)
                                .foregroundStyle(theme.faint)
                        }
                        .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if theme.rowStyle == .ledger || session.id != recentSessions.last?.id {
                        Rectangle().fill(theme.line).frame(height: 1)
                    }
                }
                if BotProfileDetailPolicy.showsAllSessions(total: sessions.count) {
                    Button {
                        showSessions = true
                    } label: {
                        HStack {
                            Text(CopyPack.allSessions(sessions.count, theme.id))
                                .font(style.aTextFont)
                                .foregroundStyle(theme.accent)
                            Spacer()
                            Text("›").foregroundStyle(theme.faint)
                        }
                        .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .sheet(isPresented: $showSessions) {
                        SessionsSheet(model: model, botID: botID, onOpen: { _ in
                            model.selectedTab = .home
                            showSessions = false
                            Task { @MainActor in await Task.yield(); dismiss() }
                        })
                    }
                }
            }
            .modifier(DetailGroupChrome(theme: theme))
        }
    }

    /// Open the session the user tapped, not just the bot's latest one
    /// (session.resume by durable key, AppModelLive+Sessions).
    private func openSession(_ session: SessionSummary) {
        model.openStoredSession(session.id, botID: botID)
        model.selectedTab = .home
        dismiss()
    }

    // MARK: - Context window

    private var runtimeCard: some View {
        VStack(spacing: 0) {
            Button { showModels = true } label: {
                compactRow(title: copy.modelSec, value: pinnedModel ?? CopyPack.noModels(theme.id),
                           showsChevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Model, \(pinnedModel ?? CopyPack.noModels(theme.id))")
            .accessibilityHint("Opens the model picker")
            .sheet(isPresented: $showModels) {
                ProfileModelPicker(choices: modelChoices, selected: pinnedModel,
                                   theme: theme) { choice in
                    pinModel(choice)
                    showModels = false
                }
            }
            if pinWarning {
                divider
                Text(CopyPack.modelProviderUnknown(theme.id))
                    .font(style.aSubFont)
                    .foregroundStyle(theme.warn)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 9, leading: 13, bottom: 9, trailing: 13))
                    .accessibilityLabel(CopyPack.modelProviderUnknown(theme.id))
            }
            divider
            VStack(alignment: .leading, spacing: 7) {
                compactRow(title: copy.contextSec,
                           value: contextSegments.isEmpty ? "—" : "\(contextTotal)%")
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.line)
                        Capsule().fill(theme.accent)
                            .frame(width: geo.size.width * CGFloat(contextTotal) / 100)
                    }
                }
                .frame(height: 5)
            }
            .padding(EdgeInsets(top: 10, leading: 13, bottom: 10, trailing: 13))
            divider
            yoloCard
        }
        .modifier(DetailCardChrome(theme: theme))
    }

    private var memorySummaryCard: some View {
        VStack(spacing: 0) {
            compactRow(title: CopyPack.statSkills(theme.id), value: String(enabledSkillCount))
            divider
            compactRow(title: CopyPack.statSessions(theme.id), value: String(sessions.count))
            if isLive {
                divider
                Text(CopyPack.memoryNoRows(theme.id))
                    .font(style.footNoteFont)
                    .foregroundStyle(theme.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 9, leading: 13, bottom: 9, trailing: 13))
            }
        }
        .modifier(DetailCardChrome(theme: theme))
    }

    private var actionsGroup: some View {
        VStack(spacing: 0) {
            compactAction(copy.editLook) { showEditor = true }
            if model.pets(for: botID).hasSurface {
                divider
                compactAction(copy.petRow(theme.id)) { showPets = true }
                    .sheet(isPresented: $showPets) {
                        PetGalleryView(model: model, botID: botID)
                    }
            }
            divider
            compactAction(duplicating ? CopyPack.duplicating(theme.id) : copy.duplicate) {
                duplicateBot()
            }
            if let target = model.profileLifecycleTarget(rosterID: botID),
               target.route.profile != "default" {
                divider
                compactAction(
                    deletingProfile ? CopyPack.deletingProfile(theme.id) : CopyPack.rosterDelete(theme.id),
                    destructive: true
                ) {
                    showDeleteConfirmation = true
                }
                .disabled(deletingProfile)
            }
        }
        .modifier(DetailCardChrome(theme: theme))
    }

    private var divider: some View { Rectangle().fill(theme.line).frame(height: 1) }

    private func compactRow(title: String, value: String,
                            showsChevron: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(title).font(style.aTextFont).foregroundStyle(theme.ink)
            Spacer(minLength: 12)
            Text(value).font(style.aSubFont).foregroundStyle(theme.sub).lineLimit(1)
            if showsChevron { Text("›").foregroundStyle(theme.faint) }
        }
        .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))
        .contentShape(Rectangle())
    }

    private func compactAction(
        _ title: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(style.aTextFont)
                    .foregroundStyle(destructive ? theme.danger : theme.ink)
                Spacer()
                Text("›").foregroundStyle(theme.faint)
            }
            .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func deleteCurrentProfile() {
        guard !deletingProfile,
              let target = model.profileLifecycleTarget(rosterID: botID),
              target.route.profile != "default" else { return }
        deletingProfile = true
        let doomed = bot
        Task {
            let outcome = await model.deleteProfile(target, confirmed: true)
            deletingProfile = false
            switch outcome {
            case .deleted:
                model.toast(
                    kind: .success,
                    title: CopyPack.rosterDeleted(
                        theme.id, name: TalariaVoice.displayName(for: doomed, theme.id)),
                    botID: doomed.id)
                dismiss()
            case .refused(let reason):
                model.toast(kind: .failure,
                            title: CopyPack.rosterDeleteFailed(theme.id),
                            message: reason, botID: doomed.id)
            case .renamed:
                model.toast(kind: .failure,
                            title: CopyPack.rosterDeleteFailed(theme.id),
                            message: "Hermes returned an unexpected profile result.",
                            botID: doomed.id)
            }
        }
    }

    @ViewBuilder private var contextCard: some View {
        if contextSegments.isEmpty {
            Text(emptyLine(CopyPack.contextNeedsSession(theme.id)))
                .font(style.aSubFont)
                .foregroundStyle(theme.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 12, leading: 13, bottom: 12, trailing: 13))
                .modifier(DetailCardChrome(theme: theme))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        ForEach(Array(contextSegments.enumerated()), id: \.element.id) { index, segment in
                            Rectangle()
                                .fill(segmentColor(index))
                                .frame(width: geo.size.width * CGFloat(segment.percent) / 100)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: 6)
                .background(theme.line)
                .clipShape(RoundedRectangle(cornerRadius: 3))

                ForEach(Array(contextSegments.enumerated()), id: \.element.id) { index, segment in
                    HStack(spacing: 7) {
                        Circle()
                            .fill(segmentColor(index))
                            .frame(width: 7, height: 7)
                        Text(segment.label)
                            .font(style.aSubFont)
                            .foregroundStyle(theme.sub)
                        Spacer(minLength: 8)
                        Text("\(segment.percent)%")
                            .font(style.timeFont)
                            .foregroundStyle(theme.faint)
                    }
                    .padding(.top, 7)
                }
            }
            .padding(EdgeInsets(top: 12, leading: 13, bottom: 12, trailing: 13))
            .modifier(DetailCardChrome(theme: theme))
        }
    }

    /// Meter segments cycle through the avatar palette, same order everywhere.
    private func segmentColor(_ index: Int) -> Color {
        let hues: [AvatarHue] = [.teal, .violet, .amber, .green, .pink, .blue]
        return theme.color(for: hues[index % hues.count])
    }

    // MARK: - YOLO

    private var yoloCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(copy.yoloName)
                    .font(style.prefNameFont)
                    .foregroundStyle(yoloOn ? theme.warn : theme.faint)
                Text(copy.yoloSub)
                    .font(style.aSubFont)
                    .foregroundStyle(theme.sub)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            DetailToggle(isOn: yoloOn, theme: theme) {
                // AppModel.setYolo attaches the session first, so the toggle
                // is not a local-only lie when the bot has never been opened.
                model.setYolo(botID: botID, enabled: !yoloOn)
            }
        }
        .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))
    }

    // MARK: - Model pin

    @ViewBuilder private var modelChips: some View {
        if modelChoices.isEmpty {
            Text(emptyLine(CopyPack.noModels(theme.id)))
                .font(style.aSubFont)
                .foregroundStyle(theme.faint)
        } else {
            DetailChipFlow(spacing: 7) {
                ForEach(modelChoices) { choice in
                    DetailChip(text: choice.model,
                               selected: pinnedModel == choice.model,
                               theme: theme) {
                        pinModel(choice)
                    }
                }
            }
            if pinWarning {
                Text(CopyPack.modelProviderUnknown(theme.id))
                    .font(style.aSubFont)
                    .foregroundStyle(theme.warn)
            }
        }
    }

    /// The profile's pin, falling back to the gateway's current model so the
    /// row never renders with nothing selected.
    private var pinnedModel: String? {
        bot.pinnedModel ?? snapshot?.model.nilIfEmpty
            ?? modelChoices.first(where: \.isCurrent)?.model
    }

    /// profiles.configure {model, provider} — both halves or the gateway
    /// silently ignores the write (methods_profiles.py:751).
    private func pinModel(_ choice: ModelChoice) {
        let provider = choice.provider.isEmpty ? (snapshot?.provider ?? "") : choice.provider
        guard !isLive || !provider.isEmpty else {
            pinWarning = true
            return
        }
        pinWarning = false
        Task {
            await model.saveProfileEditWithFeedback(
                botID: botID,
                edit: ProfileEdit(model: choice.model, provider: provider))
        }
    }

    // MARK: - Memory (star map)

    /// The star map is decorative and stays. What it is drawn FROM is now
    /// honest in live mode: profiles.describe carries no memory rows, so the
    /// card reports the counts the gateway does report and says as much.
    private var memoryCard: some View {
        VStack(spacing: 0) {
            starMap
                .frame(height: 96)
            Rectangle().fill(theme.line).frame(height: 1)
            ForEach(Array(memoryLines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(style.aSubPlainFont)
                    .foregroundStyle(theme.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 9, leading: 13, bottom: 9, trailing: 13))
                if index < memoryLines.count - 1 {
                    Rectangle().fill(theme.line).frame(height: 1)
                }
            }
        }
        .modifier(DetailCardChrome(theme: theme))
    }

    private var memoryLines: [String] {
        guard isLive else { return memory.recent }
        return [CopyPack.memoryCounts(skills: enabledSkillCount,
                                      sessions: sessions.count, theme.id),
                CopyPack.memoryNoRows(theme.id)]
    }

    /// Star density tracks the real skill + session counts, so a busy bot's
    /// map is visibly denser than a fresh one's.
    private var starCount: Int {
        guard isLive else { return Self.stars.count }
        return max(3, min(Self.stars.count, enabledSkillCount + sessions.count))
    }

    private var starMap: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                constellationLine(geo, x: 0.18, y: 0.30, width: 0.44, degrees: 9)
                constellationLine(geo, x: 0.56, y: 0.24, width: 0.32, degrees: 38)
                constellationLine(geo, x: 0.24, y: 0.52, width: 0.38, degrees: -14)
                ForEach(Array(Self.stars.prefix(starCount).enumerated()), id: \.offset) { index, star in
                    TwinkleStar(color: theme.color(for: bot.hue),
                                size: index.isMultiple(of: 3) ? 5 : 3.5,
                                delay: Double(index) * 0.4)
                        .position(x: geo.size.width * star.x, y: geo.size.height * star.y)
                }
            }
        }
        .background(theme.inset)
    }

    private func constellationLine(_ geo: GeometryProxy, x: CGFloat, y: CGFloat,
                                   width: CGFloat, degrees: Double) -> some View {
        Rectangle()
            .fill(theme.line)
            .frame(width: geo.size.width * width, height: 1)
            .rotationEffect(.degrees(degrees), anchor: .leading)
            .offset(x: geo.size.width * x, y: geo.size.height * y)
    }

    // MARK: - Actions

    private func actionRow(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(style.aTextFont)
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(DetailCardChrome(theme: theme))
    }

    /// Desktop "Duplicate" semantics: profiles.create {clone_from,
    /// clone_all:true} — config, skills and memory into a sibling profile
    /// named `<id>-2` (first free suffix) — then a roster refresh.
    private func duplicateBot() {
        guard !duplicating, model.bot(botID) != nil else { return }
        duplicating = true
        duplicateFailed = false
        Task {
            // Narrated through the toast bus as well as the sheet's own inline
            // flag: the sheet dismisses on success, so the row that names the
            // clone has to land somewhere that outlives it (and in the Activity
            // ledger, which the inline flag never reached).
            let clone = await model.duplicateBotWithFeedback(from: botID)
            duplicating = false
            guard clone != nil else {
                duplicateFailed = true
                return
            }
            model.openBotID = nil
            model.selectedTab = .home
            dismiss()
        }
    }

    // MARK: - Section labels

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(style.secLabelFont)
            .tracking(style.secLabelTracking)
            .foregroundStyle(theme.faint)
            .padding(.top, 2)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

@MainActor
private struct ProfileModelPicker: View {
    let choices: [ModelChoice]
    let selected: String?
    let theme: ThemePack
    let choose: (ModelChoice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [ModelChoice] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return choices }
        return choices.filter {
            $0.model.lowercased().contains(needle)
                || $0.provider.lowercased().contains(needle)
                || $0.providerName.lowercased().contains(needle)
        }
    }

    private var groups: [(String, [ModelChoice])] {
        Dictionary(grouping: filtered) {
            $0.providerName.nilIfEmpty ?? $0.provider.nilIfEmpty ?? "Other"
        }
        .map { ($0.key, $0.value.sorted { $0.model < $1.model }) }
        .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1) { choice in
                            Button {
                                choose(choice)
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(choice.model)
                                            .font(theme.body(13.5, weight: .semibold))
                                            .foregroundStyle(theme.ink)
                                        if !choice.provider.isEmpty {
                                            Text(choice.provider)
                                                .font(theme.mono(9.5))
                                                .foregroundStyle(theme.faint)
                                        }
                                    }
                                    Spacer()
                                    if selected == choice.model {
                                        Text("✓").foregroundStyle(theme.accent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                choice.providerName.isEmpty
                                    ? choice.model
                                    : "\(choice.model), \(choice.providerName)"
                            )
                            .accessibilityValue(selected == choice.model ? "Selected" : "")
                            .accessibilityHint("Pins this model to the bot profile")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.bg)
            .searchable(text: $query, prompt: "Search models")
            .navigationTitle("Model")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationBackground(theme.bg)
        .presentationDetents([.large])
    }
}

// MARK: - Bot-sheet copy (the three voices)

extension CopyPack {

    static func runtimeSection(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Runtime"
        case .control: "RUNTIME"
        case .ink: "at work"
        }
    }

    static func actionsSection(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Profile"
        case .control: "PROFILE"
        case .ink: "the profile"
        }
    }

    static func allSessions(_ count: Int, _ t: ThemeID) -> String {
        switch t {
        case .soft: "See all \(count) sessions"
        case .control: "OPEN ALL \(count) SESSIONS"
        case .ink: "read all \(count) sittings"
        }
    }

    static func statSessions(_ t: ThemeID) -> String {
        switch t {
        case .soft: "sessions"
        case .control: "SESSIONS"
        case .ink: "sittings"
        }
    }

    static func statMemories(_ t: ThemeID) -> String {
        switch t {
        case .soft: "memories"
        case .control: "MEMORIES"
        case .ink: "memories"
        }
    }

    static func statSkills(_ t: ThemeID) -> String {
        switch t {
        case .soft: "skills"
        case .control: "SKILLS"
        case .ink: "gifts"
        }
    }

    static func statToolsets(_ t: ThemeID) -> String {
        switch t {
        case .soft: "toolsets"
        case .control: "TOOLSETS"
        case .ink: "implements"
        }
    }

    static func noStoredSessions(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No stored sessions yet — say something and one begins."
        case .control: "NO STORED SESSIONS — SESSION.LIST RETURNED NONE."
        case .ink: "No sittings are recorded. Speak, and one begins."
        }
    }

    static func contextNeedsSession(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The context meter fills once this bot has a live session — open its chat."
        case .control: "NO ATTACHED SESSION — CONTEXT BREAKDOWN UNAVAILABLE."
        case .ink: "The measure is taken only while a sitting is open."
        }
    }

    static func memoryCounts(skills: Int, sessions: Int, _ t: ThemeID) -> String {
        switch t {
        case .soft: "\(skills) skills enabled · \(sessions) sessions on record"
        case .control: "\(skills) SKILLS ENABLED · \(sessions) SESSIONS ON RECORD"
        case .ink: "\(skills) gifts held · \(sessions) sittings written down"
        }
    }

    static func memoryNoRows(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The gateway doesn’t expose memory rows, so this map is drawn from skills and sessions."
        case .control: "NO MEMORY ROWS IN PROFILES.DESCRIBE — MAP DERIVED FROM SKILLS + SESSIONS."
        case .ink: "The gateway keeps no ledger of memories; this chart is drawn from gifts and sittings."
        }
    }

    static func duplicating(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Duplicating…"
        case .control: "CLONING…"
        case .ink: "the copy is being made…"
        }
    }

    static func duplicateFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The gateway refused the duplicate — nothing was created."
        case .control: "CLONE REJECTED — NO PROFILE CREATED."
        case .ink: "The gateway refused the copy; nothing was made."
        }
    }
}

// MARK: - Per-theme styles (ported from the prototype's detail-screen CSS)

fileprivate struct DetailStyle {
    let t: ThemePack

    var backFg: Color { t.id == .ink ? t.ink : t.accent }

    // The header's name type scale lives in BotIdentityLabel(.sheet) — one
    // owner for the identity pair, here and on the roster.

    var jobFont: Font {
        switch t.id {
        case .soft: t.body(11, weight: .semibold)
        case .control: t.mono(9, weight: .semibold)
        case .ink: t.mono(8.5)
        }
    }

    var jobTracking: CGFloat { t.id == .soft ? 0 : 1.4 }

    var secLabelFont: Font {
        switch t.id {
        case .soft: t.body(11, weight: .heavy)
        case .control: t.mono(9, weight: .bold)
        case .ink: t.mono(8.5)
        }
    }

    var secLabelTracking: CGFloat { t.id == .soft ? 1 : 2 }

    var timeFont: Font {
        switch t.id {
        case .soft: t.body(11, weight: .medium)
        case .control: t.mono(10)
        case .ink: t.mono(9)
        }
    }

    var aTextFont: Font {
        switch t.id {
        case .soft: t.body(13.5, weight: .semibold)
        case .control: t.body(13, weight: .semibold)
        case .ink: t.body(15.5, weight: .semibold)
        }
    }

    var aSubFont: Font {
        switch t.id {
        case .soft: t.body(12)
        case .control: t.mono(10)
        case .ink: t.body(13).italic()
        }
    }

    var aSubPlainFont: Font {
        switch t.id {
        case .soft: t.body(13)
        case .control: t.body(12.5)
        case .ink: t.body(14.5)
        }
    }

    var apTitleFont: Font {
        switch t.id {
        case .soft: t.body(14.5, weight: .bold)
        case .control: t.body(14, weight: .bold)
        case .ink: t.body(17, weight: .bold)
        }
    }

    var prefNameFont: Font {
        switch t.id {
        case .soft: t.body(14, weight: .semibold)
        case .control: t.body(13.5, weight: .semibold)
        case .ink: t.body(16, weight: .semibold)
        }
    }

    var footNoteFont: Font {
        switch t.id {
        case .soft: t.body(11.5)
        case .control: t.mono(9.5)
        case .ink: t.body(13).italic()
        }
    }
}

// MARK: - Chrome

fileprivate struct DetailCardChrome: ViewModifier {
    let theme: ThemePack

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
        content
            .background(shape.fill(theme.panel))
            .clipShape(shape)
            .overlay(shape.stroke(theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))
            .shadow(color: theme.id == .soft ? theme.ink.opacity(0.04) : .clear, radius: 1.5, y: 1)
    }
}

fileprivate struct DetailGroupChrome: ViewModifier {
    let theme: ThemePack

    @ViewBuilder func body(content: Content) -> some View {
        if theme.rowStyle == .ledger {
            content // Ink: bare ruled ledger, no card chrome.
        } else {
            let shape = RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
            content
                .background(shape.fill(theme.panel))
                .clipShape(shape)
                .overlay(shape.stroke(theme.line, lineWidth: 1))
                .shadow(color: theme.id == .soft ? theme.ink.opacity(0.04) : .clear, radius: 1.5, y: 1)
        }
    }
}

// MARK: - Themed toggle (46×27, knob 21, per-theme track/knob)

fileprivate struct DetailToggle: View {
    let isOn: Bool
    let theme: ThemePack
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topLeading) {
                trackShape
                    .fill(trackFill)
                    .overlay(trackShape.stroke(trackStroke, lineWidth: 1))
                knob
                    .frame(width: 21, height: 21)
                    .offset(x: isOn ? 22.5 : 2.5, y: 3)
            }
            .frame(width: 46, height: 27)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: isOn)
    }

    private var trackShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .control ? 6 : 14, style: .continuous)
    }

    private var trackFill: Color {
        switch theme.id {
        case .soft: isOn ? theme.ok : theme.ink.opacity(0.12)
        case .control: isOn ? theme.accent.opacity(0.35) : theme.ink.opacity(0.08)
        case .ink: isOn ? theme.ok.opacity(0.25) : .clear
        }
    }

    private var trackStroke: Color {
        switch theme.id {
        case .soft: .clear
        case .control: theme.lineStrong
        case .ink: theme.ink.opacity(0.5)
        }
    }

    @ViewBuilder private var knob: some View {
        switch theme.id {
        case .soft:
            Circle().fill(theme.panel)
                .shadow(color: theme.ink.opacity(0.2), radius: 1.5, y: 1)
        case .control:
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(theme.ink)
        case .ink:
            Circle().fill(isOn ? theme.ink : theme.ink.opacity(0.35))
        }
    }
}

// MARK: - Selectable chip (prototype `chipSel`)
// Internal: shared with CreateBotView's Advanced section, which renders the
// same chip language.

struct DetailChip: View {
    let text: String
    let selected: Bool
    var struck: Bool = false
    let theme: ThemePack
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(font)
                .strikethrough(struck)
                .foregroundStyle(foreground)
                .padding(EdgeInsets(top: 7, leading: 11, bottom: 7, trailing: 11))
                .background(shape.fill(background))
                .overlay(shape.stroke(border, lineWidth: theme.id == .soft ? 1.5 : 1))
                .opacity(struck ? 0.55 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var shape: RoundedRectangle {
        let radius: CGFloat = switch theme.id {
        case .soft: 999
        case .control: 5
        case .ink: 0
        }
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    private var font: Font {
        switch theme.id {
        case .soft: theme.body(12, weight: .semibold)
        case .control: theme.mono(10, weight: .semibold)
        case .ink: theme.mono(9.5)
        }
    }

    private var foreground: Color {
        if selected {
            return theme.id == .ink ? theme.bg : theme.accent
        }
        return theme.sub
    }

    private var background: Color {
        guard selected else { return .clear }
        switch theme.id {
        case .soft: return theme.accent.opacity(0.07)
        case .control: return theme.accent.opacity(0.06)
        case .ink: return theme.ink
        }
    }

    private var border: Color {
        if selected {
            switch theme.id {
            case .soft: return theme.accent
            case .control: return theme.accent.opacity(0.5)
            case .ink: return theme.ink
            }
        }
        switch theme.id {
        case .soft: return theme.ink.opacity(0.12)
        case .control: return theme.line
        case .ink: return theme.ink.opacity(0.3)
        }
    }
}

// MARK: - Flow layout for wrapping chip rows (shared with CreateBotView)

struct DetailChipFlow: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Twinkling star (prototype `glowU` 2.8s, staggered)

fileprivate struct TwinkleStar: View {
    let color: Color
    let size: CGFloat
    let delay: Double

    @State private var lit = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(lit ? 1 : 0.45)
            .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true).delay(delay),
                       value: lit)
            .onAppear { lit = true }
    }
}
