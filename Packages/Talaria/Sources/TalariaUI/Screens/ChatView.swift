import SwiftUI
import TalariaKit
import TalariaTheme

// Per-bot chat, pushed from the roster. Header with back / avatar / themed
// state line / routines button (header tap opens the bot sheet); the message
// list (sys rows, bot bubbles with block markdown, tool chips, papers-digest
// and inline-approval cards, user bubbles with offline queued notes, typing
// dots); quick replies; the model/context/YOLO strip; and the composer with
// mic → voice, attachments, slash commands, and a send button that becomes a
// stop control while a turn runs.
// Ported from Talaria.dc.html `data-screen-label="Chat"`.
//
// The inline approval card is wired to the same state as the Approvals tab:
// pending == the ref is still in model.approvals; deciding here removes it
// there (and vice versa), with the outcome word remembered in ApprovalOutcomes.

// MARK: - Approval outcome ledger

/// AppModel removes an approval on resolve, but decided cards keep rendering
/// with their themed done-word ("Approved — sent" / "RELEASED — RAN CLEAN" /
/// "sealed — done cleanly"). This ledger keeps the card data + outcome for
/// every approval this process has seen, shared by the inline chat card and
/// the push banner.
@MainActor
@Observable
public final class ApprovalOutcomes {
    public static let shared = ApprovalOutcomes()

    public private(set) var snapshots: [String: Approval] = [:]
    public private(set) var outcomes: [String: Bool] = [:]

    public init() {}

    /// Cache the card data while the approval is still pending.
    public func remember(_ approval: Approval) {
        if snapshots[approval.id] == nil { snapshots[approval.id] = approval }
    }

    /// Record a decision made anywhere in the app.
    public func record(_ approval: Approval, approved: Bool) {
        snapshots[approval.id] = approval
        outcomes[approval.id] = approved
    }

    /// A response that did not reach its owning gateway is not an outcome.
    /// Reopen the card so the user can retry and a pending sweep can merge it.
    func reopen(_ approvalID: String) {
        outcomes.removeValue(forKey: approvalID)
        ApprovalBridges.shared.decided.removeValue(forKey: approvalID)
    }

    /// Record + resolve in one step — the path every approve/deny control
    /// in this module should take.
    public func resolve(_ approval: Approval, approve: Bool, in model: AppModel) {
        record(approval, approved: approve)
        model.resolveApproval(approval, approve: approve)
    }
}

// MARK: - ChatView

public struct ChatView: View {
    private let model: AppModel
    private let botID: String
    private let onOpenProfile: () -> Void
    private let onRoutines: () -> Void
    private let onVoice: () -> Void

    @State private var draft = ""
    @State private var editingMessage: ChatMessage?
    @State private var pendingRestore: ChatMessage?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.talariaReducedMotion) private var reducedMotion
    @ScaledMetric(relativeTo: .body) private var softComposerSize = 14.5
    @ScaledMetric(relativeTo: .body) private var controlComposerSize = 13
    @ScaledMetric(relativeTo: .body) private var inkComposerSize = 15
    @State private var showModelSheet = false
    @State private var showCommands = false
    @State private var initialTranscriptAnchor = InitialTranscriptAnchorState()
    @State private var followingLatest = true
    @State private var jumpToLatestToken = 0
    @State private var transcriptGeometry = TranscriptGeometryReadiness()
    @FocusState private var composerFocused: Bool

    /// Tapback set, matching desktop's reaction picker.
    private static let reactionEmojis = ["👍", "❤️", "🎉", "🙏", "🤔", "👎"]

    public init(model: AppModel, botID: String,
                onOpenProfile: @escaping () -> Void = {},
                onRoutines: @escaping () -> Void = {},
                onVoice: @escaping () -> Void = {}) {
        self.model = model
        self.botID = botID
        self.onOpenProfile = onOpenProfile
        self.onRoutines = onRoutines
        self.onVoice = onVoice
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }

    /// The one identity path (Components/BotIdentity.swift).
    private var bot: Bot { model.identity(botID) }

    private var botColor: Color { theme.color(for: bot.hue) }
    private var chat: ChatState? { model.chats[botID] }
    private var messages: [ChatMessage] { chat?.messages ?? [] }
    private var pendingSlashPrefill: SlashPrefillBinding? {
        guard let route = model.stateRoute(for: botID) ?? model.gatewayRoute(for: botID) else { return nil }
        return CommandsRuntime.shared.slashPrefills[route]
    }

    /// A turn is in flight: the send button is a stop control and typed text
    /// steers instead of submitting.
    private var turnRunning: Bool {
        (chat?.isRunning ?? false) || (chat?.isTyping ?? false)
    }

    private var hasUnresolvedFailedTurnRetry: Bool {
        model.hasUnresolvedFailedTurnRetry(in: botID)
    }

    /// Presentation alone is side-effect free. A system swipe or drag to
    /// dismiss travels through the same controller invalidation as Cancel, so
    /// an in-flight result cannot republish this sheet later.
    private var privateDiagnosticsSheetPresented: Binding<Bool> {
        Binding(
            get: { model.privateDiagnosticsShare != nil },
            set: { presented in
                guard !presented, let id = model.privateDiagnosticsShare?.id else { return }
                model.dismissPrivateDiagnosticsShare(id: id)
            }
        )
    }

    private var attachmentCount: Int { chat?.attachments.count ?? 0 }
    private var transcriptPolicy: TranscriptPresentationPolicy {
        TranscriptPresentationPolicy(detail: model.settings.transcriptDetail)
    }

    private var hasLiveTranscriptDetail: Bool {
        messages.contains { message in
            (message.isStreaming && !(message.reasoning ?? "").isEmpty)
                || message.toolCalls.contains { $0.state == .running }
        }
    }

    private var quickReplies: [String] {
        model.mode == .demo ? (DemoData.quickReplies[botID] ?? []) : []
    }

    /// Canonical open is in flight and the transcript is still empty — show
    /// a light loading surface instead of a blank chat for ~3s (device
    /// 8cea17a after the fat-resume wait was removed).
    private var isOpeningChat: Bool {
        model.mode == .live
            && messages.isEmpty
            && (chat?.isOpeningCanonicalChat == true)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .bottomTrailing) {
                if isOpeningChat {
                    chatOpeningPlaceholder
                } else {
                    messageList
                }
                if showsJumpToLatest {
                    jumpToLatestButton
                        .padding(.trailing, 16)
                        .padding(.bottom, 10)
                        .transition(reducedMotion ? .opacity
                            : .scale(scale: 0.9).combined(with: .opacity))
                }
            }
            if transcriptPolicy.detail == .advanced { modelStrip }
            if !quickReplies.isEmpty {
                quickReplyRow
            }
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
        .onAppear {
            seedChatIfNeeded()
            // Idempotent: RootView attaches the router at connect time so
            // background bots keep their chips; this is the safety net for a
            // chat opened before that ran.
            model.attachChatEventRouter()
            consumeSlashPrefillIfSafe()
        }
        .onChange(of: pendingSlashPrefill) { _, _ in consumeSlashPrefillIfSafe() }
        .onChange(of: draft) { _, _ in consumeSlashPrefillIfSafe() }
        .sheet(isPresented: privateDiagnosticsSheetPresented) {
            if let state = model.privateDiagnosticsShare {
                NousDiagnosticsConsentSheet(
                    state: state,
                    theme: theme,
                    upload: { model.uploadPrivateDiagnosticsShare(id: state.id) },
                    cancel: { model.dismissPrivateDiagnosticsShare(id: state.id) }
                )
                .id(state.id)
            }
        }
        .confirmationDialog(copy.rewindConfirmTitle(theme.id),
                            isPresented: Binding(
                                get: { pendingRestore != nil },
                                set: { if !$0 { pendingRestore = nil } }),
                            titleVisibility: .visible) {
            Button(copy.rewindMessage(theme.id), role: .destructive) {
                if let pendingRestore {
                    model.rewind(to: pendingRestore, in: botID)
                }
                pendingRestore = nil
            }
            Button(copy.rewindCancel(theme.id), role: .cancel) {
                pendingRestore = nil
            }
        } message: {
            Text(copy.rewindConfirmMessage(theme.id))
        }
    }

    /// `slash.exec` can return a prefill after this view has been replaced or
    /// after the user has started typing. Consume only for this selected,
    /// current chat and never replace a nonempty draft; the source-qualified
    /// runtime entry remains recoverable until a later safe opportunity.
    private func consumeSlashPrefillIfSafe() {
        guard let binding = pendingSlashPrefill,
              let currentChat = chat,
              let route = model.stateRoute(for: botID) ?? model.gatewayRoute(for: botID)
        else { return }
        let connectionGeneration = CommandsRuntime.shared
            .connectionGenerations[route.gatewayID]
        guard SlashPrefillPolicy.identityMatches(
            binding, currentRoute: route,
            currentConnectionGeneration: connectionGeneration,
            currentChatID: ObjectIdentifier(currentChat),
            currentStoredID: currentChat.storedSessionID,
            currentRuntimeID: currentChat.sessionID) else {
            if CommandsRuntime.shared.slashPrefills[route] == binding {
                CommandsRuntime.shared.slashPrefills.removeValue(forKey: route)
            }
            return
        }
        guard
              SlashPrefillPolicy.mayApply(
                binding, draft: draft, selectedBotID: model.openBotID,
                currentRoute: route,
                currentConnectionGeneration: connectionGeneration,
                currentChatID: ObjectIdentifier(currentChat),
                currentStoredID: currentChat.storedSessionID,
                currentRuntimeID: currentChat.sessionID),
              let prefill = model.takeSlashPrefill(for: botID, chat: currentChat,
                                                   draft: draft) else { return }
        draft = prefill
        editingMessage = nil
        composerFocused = true
    }

    /// Demo bots without history open on their roster preview, like the
    /// prototype's `[{ from:'bot', text: preview }]` fallback.
    ///
    /// Demo only. In live mode `openChat` hydrates the real transcript, and
    /// seeding here painted the roster preview as a message the bot never sent
    /// — an empty forever-chat has to look empty, not fake.
    private func seedChatIfNeeded() {
        guard model.mode == .demo else { return }
        guard model.chats[botID] == nil else { return }
        let chat = model.chat(for: botID)
        if chat.messages.isEmpty, !bot.preview.isEmpty {
            chat.messages.append(ChatMessage(author: .bot, time: bot.previewTime,
                                             text: bot.preview))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            HeaderIconButton(theme: theme, size: 31, action: { model.openBotID = nil }) {
                Text(verbatim: "‹")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.id == .ink ? theme.ink : theme.accent)
                    .padding(.bottom, 2)
            }
            ZStack {
                BotPortraitView(model: model, bot: bot, size: 36, theme: theme)
            }
            .frame(width: 36, height: 36)
            .overlay(alignment: .bottomTrailing) {
                PetCompanionView(model: model, bot: bot)
                    .offset(x: 3, y: 2)
            }
            Button(action: onOpenProfile) {
                VStack(alignment: .leading, spacing: 1) {
                    nameLine
                    stateLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            routinesButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.line).frame(height: 1)
        }
    }

    private var nameLine: some View {
        let name = TalariaVoice.displayName(for: bot, theme.id)
        return Group {
            switch theme.id {
            case .soft: Text(verbatim: "\(name) ›").font(theme.body(16, weight: .bold))
            case .control: Text(verbatim: "\(name) ›").font(theme.body(15, weight: .bold))
            case .ink: Text(verbatim: "\(name) ›").font(theme.body(19, weight: .bold).smallCaps()).tracking(0.5)
            }
        }
        .foregroundStyle(theme.ink)
        .lineLimit(1)
    }

    private var stateLine: some View {
        let line = TalariaVoice.chatStateLine(for: bot, theme.id)
        let color: Color = switch bot.status {
        case .working: theme.ok
        case .approval: theme.id == .control ? theme.warn : theme.danger
        case .idle: theme.faint
        }
        return Group {
            switch theme.id {
            case .soft: Text(line).font(theme.body(11.5, weight: .medium))
            case .control: Text(line.uppercased()).font(theme.mono(9.5)).tracking(0.8)
            case .ink: Text(line.uppercased()).font(theme.mono(8.5)).tracking(1.5)
            }
        }
        .foregroundStyle(color)
        .lineLimit(1)
    }

    private var routinesButton: some View {
        Button(action: onRoutines) {
            Group {
                switch theme.id {
                case .soft:
                    Text(copy.routinesBtn).font(theme.body(12, weight: .semibold))
                        .foregroundStyle(theme.ink)
                case .control:
                    Text(copy.routinesBtn).font(theme.mono(10, weight: .semibold))
                        .tracking(1).foregroundStyle(theme.ink)
                case .ink:
                    Text(copy.routinesBtn).font(theme.body(13, weight: .semibold).smallCaps())
                        .tracking(1).foregroundStyle(theme.ink)
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 11)
            .chipShell(theme)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Message list

    /// Inline placeholder while `enterCanonicalChat` hydrates. Not a modal —
    /// composer and header stay usable; only the blank transcript is filled.
    private var chatOpeningPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            ProgressView()
                .tint(theme.accent)
            Text(chatOpeningLabel)
                .font(theme.body(13, weight: .medium))
                .foregroundStyle(theme.sub)
                .accessibilityLabel(Text(chatOpeningLabel))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
    }

    private var chatOpeningLabel: String {
        switch theme.id {
        case .soft: "Loading chat…"
        case .control: "LOADING CHAT"
        case .ink: "Loading chat"
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if ChatTranscriptLayoutPolicy.usesLazyStack(messageCount: messages.count) {
                        LazyVStack(alignment: .leading, spacing: 11) { transcriptRows }
                    } else {
                        VStack(alignment: .leading, spacing: 11) { transcriptRows }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)
                // Tapping the transcript puts the keyboard away. A bot's
                // answer is usually longer than the third of the screen left
                // above an open keyboard, so reading is the common intent and
                // it deserves the cheapest possible gesture.
                //
                // `.contentShape` first: a VStack of bubbles only receives
                // taps where a bubble actually is, and the gaps between them
                // are exactly where a thumb lands when it means "dismiss".
                .contentShape(Rectangle())
                .onTapGesture { composerFocused = false }
            }
            // Drag the transcript down and the keyboard follows the finger,
            // rather than vanishing at some threshold.
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .coordinateSpace(name: "talaria.chat.transcript")
            .background(
                GeometryReader { viewport in
                    Color.clear.preference(
                        key: TranscriptViewportHeightKey.self,
                        value: viewport.size.height)
                }
            )
            .onPreferenceChange(TranscriptBottomInsetKey.self) { minY in
                transcriptGeometry.recordBottom(minY: minY)
                refreshFollowingLatest()
            }
            .onPreferenceChange(TranscriptViewportHeightKey.self) { height in
                transcriptGeometry.recordViewport(height: height)
                refreshFollowingLatest()
            }
            .task(id: initialTranscriptAnchorKey) {
                guard let attempt = initialTranscriptAnchor.begin(
                    botID: botID, messageCount: messages.count
                ) else { return }
                guard await anchorTranscript(proxy, attempt: attempt),
                      initialTranscriptAnchor.complete(
                        attempt, currentBotID: botID, isCancelled: Task.isCancelled
                      )
                else { return }
                // A completed attempt had no user departure. Geometry will
                // keep this honest once both probes have reported.
                followingLatest = true
            }
            .onChange(of: messages.count) {
                guard initialTranscriptAnchor.isSettled(for: botID), followingLatest else { return }
                withAnimation(ChatComposerLayoutPolicy.animation(
                    reducedMotion: reducedMotion, duration: 0.25
                )) {
                    proxy.scrollTo(transcriptAnchorID, anchor: .bottom)
                }
            }
            .onChange(of: chat?.isTyping ?? false) {
                guard followingLatest else { return }
                withAnimation(ChatComposerLayoutPolicy.animation(
                    reducedMotion: reducedMotion, duration: 0.25
                )) {
                    proxy.scrollTo(transcriptAnchorID, anchor: .bottom)
                }
            }
            .onChange(of: botID) {
                followingLatest = true
            }
            .onChange(of: jumpToLatestToken) {
                withAnimation(ChatComposerLayoutPolicy.animation(
                    reducedMotion: reducedMotion, duration: 0.25
                )) {
                    proxy.scrollTo(transcriptAnchorID, anchor: .bottom)
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        guard initialTranscriptAnchor.userDeparted(
                            botID: botID, messageCount: messages.count
                        ) else { return }
                        // Taking control of the scroll settles the initial
                        // anchor without finishing it. No later layout pass
                        // may pull the transcript back down or restore this.
                        followingLatest = false
                    }
            )
        }
    }

    private var showsJumpToLatest: Bool {
        ChatTranscriptLayoutPolicy.showsJumpControl(
            isFollowingLatest: followingLatest, messageCount: messages.count)
    }

    private var jumpToLatestButton: some View {
        Button {
            followingLatest = true
            jumpToLatestToken += 1
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(theme.id == .ink ? theme.bg : theme.accentFg)
                .frame(width: 36, height: 36)
                .background(theme.id == .ink ? theme.ink : theme.accent)
                .clipShape(Circle())
                .shadow(color: theme.ink.opacity(0.18), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Jump to latest"))
    }

    private var initialTranscriptAnchorKey: String {
        "\(botID)\u{1f}\(messages.count)\u{1f}\(String(describing: messages.last?.id))"
    }

    private var showingWorkingAvatar: Bool {
        transcriptPolicy.showsWorkingAvatar(
            isTurnRunning: turnRunning,
            hasLiveDetail: hasLiveTranscriptDetail
        )
    }

    private var transcriptAnchorID: String {
        ChatTranscriptLayoutPolicy.anchorID(
            lastMessageID: messages.last?.id,
            showingWorkingAvatar: showingWorkingAvatar
        )
    }

    @ViewBuilder private var transcriptRows: some View {
        if chat?.transcriptHasOlder == true {
            Button {
                Task { await model.loadOlderTranscript(botID: botID) }
            } label: {
                Text(copy.earlierMessages)
                    .font(theme.id == .soft ? theme.body(12, weight: .semibold) : theme.mono(10))
                    .foregroundStyle(theme.sub)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .disabled(chat?.isLoadingOlderTranscript == true)
            .opacity(chat?.isLoadingOlderTranscript == true ? 0.55 : 1)
            .accessibilityLabel(Text(copy.earlierMessages))
        }
        ForEach(messages) { message in
            messageRow(message)
                .id(message.id.uuidString)
        }
        if showingWorkingAvatar {
            TranscriptWorkingAvatar(model: model, bot: bot, theme: theme,
                                    label: copy.workingLabel(theme.id))
                .modifier(ChatEntrance())
                .id(ChatTranscriptLayoutPolicy.workingAnchorID)
        }
        Color.clear.frame(height: 1).id(ChatTranscriptLayoutPolicy.emptyAnchorID)
            .background(
                GeometryReader { geo in
                    let frame = geo.frame(in: .named("talaria.chat.transcript"))
                    Color.clear.preference(
                        key: TranscriptBottomInsetKey.self,
                        value: frame.minY)
                }
            )
    }

    private func refreshFollowingLatest() {
        guard let distance = transcriptGeometry.distanceFromBottom else { return }
        followingLatest = ChatTranscriptLayoutPolicy.isFollowingLatest(
            distanceFromBottom: distance)
    }

    private func anchorTranscript(_ proxy: ScrollViewProxy,
                                  attempt: InitialTranscriptAnchorState.Attempt) async -> Bool {
        for delay in ChatTranscriptLayoutPolicy.layoutPassesMs {
            guard initialTranscriptAnchor.shouldContinue(
                attempt, currentBotID: botID, isCancelled: Task.isCancelled
            ) else { return false }
            if delay > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(delay))
                } catch {
                    return false
                }
            } else {
                await Task.yield()
            }
            guard initialTranscriptAnchor.shouldContinue(
                attempt, currentBotID: botID, isCancelled: Task.isCancelled
            ) else { return false }
            proxy.scrollTo(transcriptAnchorID, anchor: .bottom)
        }
        return true
    }

    @ViewBuilder private func messageRow(_ message: ChatMessage) -> some View {
        switch message.author {
        case .system: systemRow(message)
        case .bot: botRow(message)
        case .user: userRow(message)
        }
    }

    // MARK: System rows

    private func systemRow(_ message: ChatMessage) -> some View {
        HStack(spacing: 8) {
            if theme.id == .ink {
                Rectangle().fill(theme.line).frame(height: 1)
            } else {
                Spacer(minLength: 0)
            }
            sysPill(message.text)
            if theme.id == .ink {
                Rectangle().fill(theme.line).frame(height: 1)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private func sysPill(_ text: String) -> some View {
        switch theme.id {
        case .soft:
            Text(text)
                .font(theme.body(11, weight: .semibold))
                .foregroundStyle(theme.ink.opacity(0.4))
                .padding(.vertical, 5)
                .padding(.horizontal, 12)
                .background(theme.ink.opacity(0.05), in: Capsule())
                .lineLimit(1)
        case .control:
            Text(text.uppercased())
                .font(theme.mono(9.5))
                .tracking(1)
                .foregroundStyle(theme.ink.opacity(0.4))
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(theme.lineStrong.opacity(0.6), lineWidth: 1))
                .lineLimit(1)
        case .ink:
            Text(text.uppercased())
                .font(theme.mono(8))
                .tracking(1.5)
                .foregroundStyle(theme.ink.opacity(0.45))
                .lineLimit(1)
                .fixedSize()
        }
    }

    // MARK: Bot rows

    private func botRow(_ message: ChatMessage) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if theme.id == .ink {
                    Text(verbatim: "\(TalariaVoice.plainUpper(for: bot)) · \(message.time ?? "now")")
                        .font(theme.mono(8))
                        .tracking(1.5)
                        .foregroundStyle(theme.ink.opacity(0.45))
                        .padding(.bottom, 4)
                }
                if let reasoning = message.reasoning, !reasoning.isEmpty,
                   transcriptPolicy.showsReasoning(isLive: message.isStreaming) {
                    ThoughtBlock(reasoning: reasoning, theme: theme,
                                 isLive: message.isStreaming && message.text.isEmpty)
                        .padding(.bottom, message.text.isEmpty ? 0 : 5)
                }
                if !message.text.isEmpty {
                    botBubble(message.text)
                        .contextMenu { messageMenu(message) }
                }
                let visibleToolCalls = transcriptPolicy.visibleToolCalls(message.toolCalls)
                if !visibleToolCalls.isEmpty {
                    ToolCallList(calls: visibleToolCalls, theme: theme, copy: copy, accent: botColor)
                        .padding(.top, message.text.isEmpty ? 0 : 7)
                        .padding(.leading, theme.id == .ink ? 12 : 0)
                }
                if let card = message.card {
                    cardView(card)
                        .padding(.top, 8)
                        .padding(.leading, theme.id == .ink ? 14 : 0)
                }
                if let failure = message.failure {
                    FailedTurnCard(
                        failure: failure,
                        theme: theme,
                        canRetry: model.canRetryFailedTurn(message, in: botID),
                        canDismiss: model.canDismissFailedTurn(message, in: botID),
                        retry: { model.retryFailedTurn(message, in: botID) },
                        dismiss: { model.dismissFailedTurn(message, in: botID) },
                        openSettings: { model.requestSettings() },
                        sendDiagnostics: diagnosticsAction(for: message)
                    )
                    .padding(.top, 8)
                    .padding(.leading, theme.id == .ink ? 12 : 0)
                }
                if let emoji = model.reaction(for: message) {
                    reactionBadge(emoji)
                        .padding(.top, 4)
                        .padding(.leading, theme.id == .ink ? 12 : 10)
                }
            }
            Spacer(minLength: 44) // ≈ the prototype's 86% max width
        }
        .modifier(ChatEntrance())
    }

    private func diagnosticsAction(for message: ChatMessage) -> (() -> Void)? {
        guard model.canPreparePrivateDiagnosticsShare(for: message, in: botID) else {
            return nil
        }
        return { _ = model.preparePrivateDiagnosticsShare(for: message, in: botID) }
    }

    @ViewBuilder private func botBubble(_ text: String) -> some View {
        switch theme.id {
        case .soft:
            MarkdownText(text, theme: theme, size: 14.5,
                         color: theme.ink.opacity(0.94), lineSpacing: 3)
                .padding(.vertical, 11)
                .padding(.horizontal, 14)
                .background(theme.panel,
                            in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 6,
                                                       bottomTrailingRadius: 20, topTrailingRadius: 20))
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 6,
                                                bottomTrailingRadius: 20, topTrailingRadius: 20)
                    .strokeBorder(theme.ink.opacity(0.06), lineWidth: 1))
                .shadow(color: theme.ink.opacity(0.04), radius: 1, y: 1)
        case .control:
            MarkdownText(text, theme: theme, size: 14,
                         color: theme.ink.opacity(0.88), lineSpacing: 3.5)
                .padding(.vertical, 11)
                .padding(.horizontal, 13)
                .background(theme.panel,
                            in: UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 3,
                                                       bottomTrailingRadius: 10, topTrailingRadius: 10))
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 3,
                                                bottomTrailingRadius: 10, topTrailingRadius: 10)
                    .strokeBorder(theme.line, lineWidth: 1))
        case .ink:
            // Flat manuscript text with a colored left rule — no bubble.
            MarkdownText(text, theme: theme, size: 16.5, color: theme.ink, lineSpacing: 4)
                .padding(.vertical, 2)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(botColor).frame(width: 2)
                }
        }
    }

    // MARK: Message actions (long press)

    @ViewBuilder private func messageMenu(_ message: ChatMessage) -> some View {
        Button {
            copyToPasteboard(message.text)
        } label: {
            Label(copy.copyMessage(theme.id), systemImage: "doc.on.doc")
        }
        if message.author == .user, model.canActOnTranscript(message, in: botID) {
            Button {
                editingMessage = message
                draft = message.text
                composerFocused = true
            } label: {
                Label(copy.editMessage(theme.id), systemImage: "pencil")
            }
            Button(role: .destructive) {
                pendingRestore = message
            } label: {
                Label(copy.rewindMessage(theme.id), systemImage: "arrow.uturn.backward")
            }
        }
        // Failed turns own a classifier-gated plain Retry on their card.
        // Never leak the ordinary destructive Regenerate action around that
        // verdict through the long-press menu.
        if message.author == .bot,
           FailedTurnCardPolicy.allowsOrdinaryAssistantActions(for: message.failure),
           model.canActOnTranscript(message, in: botID) {
            Button {
                model.regenerate(from: message, in: botID)
            } label: {
                Label(copy.regenerateMessage(theme.id), systemImage: "arrow.clockwise")
            }
        }
        if message.author == .bot,
           FailedTurnCardPolicy.allowsOrdinaryAssistantActions(for: message.failure),
           model.canBranchFromMessage(message, in: botID) {
            Button {
                model.branchFromMessage(message, in: botID)
            } label: {
                Label("Branch from here", systemImage: "arrow.triangle.branch")
            }
        }
        if model.canReact(to: message, in: botID) {
            Menu {
                ForEach(Self.reactionEmojis, id: \.self) { emoji in
                    Button(emoji) { model.react(to: message, in: botID, emoji: emoji) }
                }
            } label: {
                Label(copy.reactMessage(theme.id), systemImage: "face.smiling")
            }
        }
    }

    private func reactionBadge(_ emoji: String) -> some View {
        Text(emoji)
            .font(.system(size: 12))
            .padding(.vertical, 3)
            .padding(.horizontal, 7)
            .background(theme.id == .ink ? Color.clear : theme.panel,
                        in: Capsule())
            .overlay(Capsule().strokeBorder(theme.line, lineWidth: 1))
    }

    @ViewBuilder private func cardView(_ card: MessageCard) -> some View {
        switch card {
        case .papers(let papers): papersCard(papers)
        case .approvalRef(let ref): approvalCard(ref: ref)
        }
    }

    // MARK: Papers digest card

    private static let inkFigures = ["fig. i", "fig. ii", "fig. iii"]

    private func papersCard(_ papers: [MessageCard.Paper]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(copy.digestHead)
                .font(theme.mono(theme.id == .ink ? 8 : 9, weight: .bold))
                .tracking(theme.id == .ink ? 2 : 1.5)
                .foregroundStyle(theme.id == .control ? theme.accent
                    : theme.ink.opacity(theme.id == .ink ? 0.55 : 0.45))
                .padding(.vertical, 8)
                .padding(.horizontal, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.line).frame(height: 1)
                }
            ForEach(Array(papers.enumerated()), id: \.offset) { index, paper in
                paperRow(paper, index: index)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(theme.line).frame(height: 1)
                    }
            }
            Button {
                // Full digest lives with the artifact — jump to the vault.
                model.selectedTab = .artifacts
                model.openBotID = nil
            } label: {
                Group {
                    switch theme.id {
                    case .soft:
                        Text(copy.digestLink).font(theme.body(12.5, weight: .bold))
                    case .control:
                        Text(copy.digestLink).font(theme.mono(10, weight: .bold)).tracking(1)
                    case .ink:
                        Text(copy.digestLink).font(theme.body(14, weight: .bold).smallCaps()).tracking(1)
                    }
                }
                .foregroundStyle(theme.accent)
                .padding(.vertical, 9)
                .padding(.horizontal, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(cardChrome)
    }

    private func paperRow(_ paper: MessageCard.Paper, index: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(theme.id == .ink
                 ? (index < Self.inkFigures.count ? Self.inkFigures[index] : "fig.")
                 : "▪")
                .font(theme.mono(9))
                .foregroundStyle(botColor)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 0) {
                Text(paper.title)
                    .font(theme.body(theme.id == .ink ? 15.5 : 13.5,
                                     weight: theme.id == .control ? .semibold : .bold))
                    .foregroundStyle(theme.ink)
                Text(paper.meta)
                    .font(theme.id == .soft ? theme.body(11) : theme.mono(theme.id == .ink ? 8.5 : 9.5))
                    .tracking(theme.id == .ink ? 0.5 : 0)
                    .foregroundStyle(theme.id == .soft ? theme.ink.opacity(0.45)
                        : theme.id == .control ? theme.ink.opacity(0.42) : theme.ink.opacity(0.5))
                    .padding(.top, 2)
                Text(paper.summary)
                    .font(theme.body(theme.id == .ink ? 14 : 12.5))
                    .italic(theme.id == .ink)
                    .lineSpacing(2.5)
                    .foregroundStyle(theme.ink.opacity(theme.id == .ink ? 0.75 : 0.65))
                    .padding(.top, 3)
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var cardChrome: some View {
        switch theme.id {
        case .soft:
            RoundedRectangle(cornerRadius: 18)
                .fill(theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(theme.ink.opacity(0.06), lineWidth: 1))
                .shadow(color: theme.ink.opacity(0.04), radius: 1, y: 1)
        case .control:
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(theme.lineStrong.opacity(0.7), lineWidth: 1))
        case .ink:
            Rectangle()
                .fill(theme.panel)
                .overlay(Rectangle().strokeBorder(theme.ink.opacity(0.35), lineWidth: 1))
        }
    }

    // MARK: Inline approval card

    /// The card itself (choices, done-word, hazard chrome) belongs to the
    /// approvals surface — Components/InlineApprovalCard.swift — and binds to
    /// the same ApprovalOutcomes ledger this file defines.
    private func approvalCard(ref: String) -> some View {
        InlineApprovalCard(model: model, approvalID: ref, botID: botID)
    }

    // MARK: User rows

    private func userRow(_ message: ChatMessage) -> some View {
        let queued = model.composeQueue.contains {
            $0.botID == botID && $0.text == message.text
        }
        return HStack(spacing: 0) {
            Spacer(minLength: 70) // ≈ the prototype's 78% max width
            VStack(alignment: .trailing, spacing: 3) {
                userBubble(message.text)
                    .contextMenu { messageMenu(message) }
                if queued {
                    Text(copy.queued)
                        .font(theme.id == .soft ? theme.body(11, weight: .medium) : theme.mono(9))
                        .foregroundStyle(theme.faint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .modifier(ChatEntrance())
    }

    @ViewBuilder private func userBubble(_ text: String) -> some View {
        switch theme.id {
        case .soft:
            MarkdownText(text, theme: theme, size: 14.5, color: theme.accentFg,
                         lineSpacing: 3, onAccent: true)
                .padding(.vertical, 11)
                .padding(.horizontal, 14)
                .background(LinearGradient(colors: [theme.color(for: .violet), theme.accent],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20,
                                                       bottomTrailingRadius: 6, topTrailingRadius: 20))
                .shadow(color: theme.accent.opacity(0.24), radius: 6, y: 4)
        case .control:
            MarkdownText(text, theme: theme, size: 14, color: theme.ink, lineSpacing: 3.5)
                .padding(.vertical, 11)
                .padding(.horizontal, 13)
                .background(theme.accent.opacity(0.12),
                            in: UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10,
                                                       bottomTrailingRadius: 3, topTrailingRadius: 10))
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10,
                                                bottomTrailingRadius: 3, topTrailingRadius: 10)
                    .strokeBorder(theme.accent.opacity(0.25), lineWidth: 1))
        case .ink:
            MarkdownText(text, theme: theme, size: 15.5, color: theme.bg,
                         lineSpacing: 3, onAccent: true)
                .padding(.vertical, 11)
                .padding(.horizontal, 15)
                .background(theme.ink,
                            in: UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16,
                                                       bottomTrailingRadius: 3, topTrailingRadius: 16))
        }
    }

    // MARK: - Model / context / YOLO strip

    private var contextPercent: Int {
        if let live = chat?.usage?.contextPercent { return live }
        let seeded = DemoData.chats[botID]?.count ?? (bot.preview.isEmpty ? 0 : 1)
        let extra = max(0, messages.count - seeded)
        return min(92, 34 + extra * 3)
    }

    private var modelShort: String {
        let pinned = bot.pinnedModel ?? model.models.first ?? ""
        return pinned.components(separatedBy: " ").first ?? pinned
    }

    private var yoloOn: Bool { chat?.yolo ?? false }

    private var modelStrip: some View {
        HStack(spacing: 8) {
            Button {
                showModelSheet = true
            } label: {
                Text(verbatim: "⌘ \(modelShort)")
                    .font(chipStripFont)
                    .foregroundStyle(theme.id == .ink ? theme.ink.opacity(0.6) : theme.ink)
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showModelSheet) {
                ModelEffortSheet(model: model, botID: botID)
            }
            Spacer(minLength: 8)
            Capsule()
                .fill(theme.line)
                .frame(width: 52, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(theme.accent)
                        .frame(width: 52 * CGFloat(contextPercent) / 100)
                }
            Text(verbatim: "\(contextPercent)%")
                .font(chipStripFont)
                .foregroundStyle(theme.id == .soft ? theme.ink.opacity(0.4) : theme.faint)
                .monospacedDigit()
            Button {
                model.setYolo(botID: botID, enabled: !yoloOn)
            } label: {
                Text(verbatim: "YOLO")
                    .font(chipStripFont)
                    .foregroundStyle(yoloOn ? theme.warn : theme.faint)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 11)
        .chipShell(theme)
        .padding(.horizontal, 16)
        .padding(.bottom, 7)
    }

    private var chipStripFont: Font {
        switch theme.id {
        case .soft: theme.body(12, weight: .semibold)
        case .control: theme.mono(10.5, weight: .semibold)
        case .ink: theme.mono(9)
        }
    }

    // MARK: - Quick replies

    private var quickReplyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(quickReplies, id: \.self) { reply in
                    Button {
                        model.sendOrSteer(text: reply, to: botID)
                    } label: {
                        quickChip(reply)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder private func quickChip(_ text: String) -> some View {
        switch theme.id {
        case .soft:
            Text(text)
                .font(theme.body(13, weight: .semibold))
                .foregroundStyle(theme.accent)
                .padding(.vertical, 8)
                .padding(.horizontal, 13)
                .background(theme.accent.opacity(0.06), in: Capsule())
                .overlay(Capsule().strokeBorder(theme.accent.opacity(0.35), lineWidth: 1.5))
        case .control:
            Text(text)
                .font(theme.mono(10.5, weight: .semibold))
                .foregroundStyle(theme.accent)
                .padding(.vertical, 8)
                .padding(.horizontal, 13)
                .background(theme.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.accent.opacity(0.3), lineWidth: 1))
        case .ink:
            Text(text)
                .font(theme.body(14, weight: .semibold).smallCaps())
                .tracking(0.5)
                .foregroundStyle(theme.ink)
                .padding(.vertical, 8)
                .padding(.horizontal, 13)
                .background(theme.ink.opacity(0.03))
                .overlay(Rectangle().strokeBorder(theme.ink.opacity(0.4), lineWidth: 1))
        }
    }


    @ViewBuilder private var queuedPromptStrip: some View {
        let items = model.queuedPrompts(for: botID)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(copy.promptQueueTitle(theme.id, count: items.count))
                    .font(theme.id == .control ? theme.mono(9.5, weight: .semibold) : theme.body(11.5, weight: .semibold))
                    .foregroundStyle(theme.sub)
                ForEach(items, id: \.id) { item in
                    HStack(spacing: 8) {
                        Text(item.text)
                            .font(theme.body(13))
                            .foregroundStyle(theme.ink)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Button {
                            model.dismissQueuedPrompt(id: item.id)
                        } label: {
                            Text(copy.promptQueueRemove(theme.id))
                                .font(theme.body(12, weight: .semibold))
                                .foregroundStyle(theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(theme.inset, in: RoundedRectangle(cornerRadius: theme.buttonRadius, style: .continuous))
                }
                Text(copy.promptQueueNotice(theme.id))
                    .font(theme.body(10.5))
                    .foregroundStyle(theme.faint)
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Staged attachments (attachments agent owns the tray + picker).
            AttachmentTray(model: model, botID: botID)
            queuedPromptStrip
            if turnRunning, model.mode == .live {
                steerHint
            }
            // The @-completion rows, above the field because the keyboard owns
            // everything below it. Kept out of the stack entirely when there
            // is nothing to offer, so no gap opens over the composer.
            let handles = mentionSuggestions
            if !handles.isEmpty {
                MentionSuggestionStrip(theme: theme, items: handles, pick: complete(with:))
            }
            // The editor owns the full container width. Controls live on a
            // fixed toolbar below it, so a 320 pt phone never turns prose into
            // the narrow vertical column produced by three inline buttons.
            TextField("", text: $draft,
                      prompt: Text(copy.composer(bot)).foregroundStyle(theme.faint),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...ChatComposerLayoutPolicy.maxEditorLines(
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize
                ))
                .font(composerFont)
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .focused($composerFocused)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(composerFieldChrome)

            HStack(alignment: .center, spacing: 8) {
                HeaderIconButton(theme: theme, size: 40, action: onVoice) {
                    HStack(spacing: 3) {
                        micBar(height: 14, color: theme.accent)
                        micBar(height: 8, color: theme.accentFaint)
                    }
                }
                .frame(minWidth: ChatComposerLayoutPolicy.controlHitTarget,
                       minHeight: ChatComposerLayoutPolicy.controlHitTarget)
                .accessibilityLabel(copy.voiceLabel(theme.id))
                attachButton
                Spacer(minLength: 8)
                sendOrStopButton
            }
            .frame(minHeight: ChatComposerLayoutPolicy.controlHitTarget)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        // The strip appears and disappears per keystroke; without a transition
        // the field jumps under the thumb mid-word.
        .animation(TalariaMotionTokens.spatialAnimation(.fast,
                                                        reducedMotion: reducedMotion),
                   value: mentionSuggestions.map(\.botID))
        // "/" as the first character opens the command palette; Cancel just
        // dismisses it and leaves the draft (and the keyboard) where they were.
        .onChange(of: draft) { _, new in
            if new == "/" { showCommands = true }
        }
        .sheet(isPresented: $showCommands, onDismiss: {
            // Cancel (or a zero-argument command that ran from the palette)
            // leaves the lone "/" behind — clear it and hand the keyboard back.
            if draft == "/" { draft = "" }
            composerFocused = true
        }) {
            CommandPaletteSheet(model: model, botID: botID) { picked in
                draft = picked
                showCommands = false
            }
        }
    }

    // MARK: - @-mention completion (plugin.js:7996-8043)

    /// The handles worth offering for the token being typed.
    ///
    /// Desktop registers its provider into EVERY composer (plugin.js:7996-7997
    /// — "active in ANY composer", issue #88060), and this is the composer
    /// that matters on a phone: the handoff sheet is a deliberate act, a chat
    /// message is where an @handle actually gets typed. Everything about the
    /// rows is the shared provider (`bots.mentionSuggestions`), which is
    /// synchronous by contract because it answers per keystroke.
    ///
    /// The guards are Talaria's, and each names a path where picking a handle
    /// would insert a token that does NOT route:
    ///
    ///  * demo mode and offline — `routeMentions` bails on both
    ///    (AppModelLive+A2A.swift:444) and an offline draft is queued as
    ///    written, so the mention would reach the model as literal text;
    ///  * mid-turn — a send while a turn runs STEERS, and steering is
    ///    deliberately mention-free (`sendOrSteer`, AppModelLive+Chat.swift:253);
    ///  * a slash draft — `send()` hands anything starting with "/" to
    ///    `runSlash`, which never reaches the middleware. This also keeps the
    ///    strip out of the lone-"/" palette gesture's way.
    ///
    /// Upstream has no equivalent because it has no steer path, no offline
    /// queue and no demo world; the honest reading is that a completion is an
    /// offer to route, so it is only made where routing happens.
    private var mentionSuggestions: [MentionSuggestion] {
        guard model.mode == .live, !model.isOffline, !turnRunning,
              !draft.hasPrefix("/"),
              let active = BotMention.activeToken(in: draft) else { return [] }
        return model.mentionSuggestions(for: active.token, speaking: botID)
    }

    /// Swap the half-typed token for the chosen handle and keep the keyboard.
    private func complete(with item: MentionSuggestion) {
        guard let active = BotMention.activeToken(in: draft) else { return }
        draft = BotMention.complete(draft, range: active.range, with: item.handle)
        composerFocused = true
    }

    /// Paperclip → the attachments agent's picker, badged with what is staged.
    private var attachButton: some View {
        HeaderIconButton(theme: theme, size: 40,
                         action: { model.presentAttachmentPicker(botID: botID) }) {
            Image(systemName: "paperclip")
                .font(.system(size: 15, weight: theme.id == .ink ? .regular : .medium))
                .foregroundStyle(attachmentCount > 0 ? theme.accent : theme.ink.opacity(0.55))
        }
        .frame(minWidth: ChatComposerLayoutPolicy.controlHitTarget,
               minHeight: ChatComposerLayoutPolicy.controlHitTarget)
        .overlay(alignment: .topTrailing) {
            if attachmentCount > 0 {
                Text(verbatim: "\(attachmentCount)")
                    .font(theme.mono(8, weight: .bold))
                    .foregroundStyle(theme.accentFg)
                    .frame(width: 14, height: 14)
                    .background(theme.accent, in: Circle())
                    .offset(x: 3, y: -3)
            }
        }
        .accessibilityLabel(copy.attachLabel(theme.id))
    }

    /// Mid-turn sends steer the running turn instead of interrupting it —
    /// desktop's behavior, and worth saying out loud on a phone.
    private var steerHint: some View {
        HStack(spacing: 6) {
            Text(verbatim: "↳")
                .font(theme.mono(10))
                .foregroundStyle(theme.accent)
            Text(copy.steerHint(theme.id))
                .font(theme.id == .soft ? theme.body(11, weight: .medium) : theme.mono(9))
                .tracking(theme.id == .ink ? 1 : 0)
                .foregroundStyle(theme.faint)
                .lineLimit(2)
        }
        .padding(.horizontal, 4)
    }

    private func micBar(height: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: theme.id == .soft ? 2.25 : theme.id == .control ? 1 : 2)
            .fill(color)
            .frame(width: 4.5, height: height)
    }

    private var composerFont: Font {
        switch theme.id {
        case .soft: theme.body(softComposerSize)
        case .control: theme.mono(controlComposerSize)
        case .ink: theme.body(inkComposerSize)
        }
    }

    @ViewBuilder private var composerFieldChrome: some View {
        switch theme.id {
        case .soft:
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(theme.ink.opacity(0.09), lineWidth: 1))
        case .control:
            RoundedRectangle(cornerRadius: 8).fill(theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.lineStrong.opacity(0.8), lineWidth: 1))
        case .ink:
            RoundedRectangle(cornerRadius: 2).fill(theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(theme.ink.opacity(0.4), lineWidth: 1))
        }
    }

    private var sendShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.id == .control ? 8 : 20, style: .continuous)
    }

    private var sendBackground: Color {
        if turnRunning {
            return switch theme.id {
            case .soft: theme.danger
            case .control: theme.danger.opacity(0.14)
            case .ink: theme.ink
            }
        }
        if !canSend {
            return switch theme.id {
            case .soft: theme.ink.opacity(0.18)
            case .control: theme.ink.opacity(0.14)
            case .ink: theme.ink.opacity(0.3)
            }
        }
        return theme.accent
    }

    /// Attachments alone are a valid turn — the gateway supplies the implicit
    /// "what is this?" prompt for an image sent without words.
    private var canSend: Bool {
        guard !model.isBranchingFromMessage(in: botID),
              !hasUnresolvedFailedTurnRetry else { return false }
        return switch composerAction {
        case .disabled, .stop: false
        default: true
        }
    }

    private var composerAction: ChatComposerAction {
        ChatComposerActionPolicy.action(draft: draft, attachmentCount: attachmentCount,
                                        isTurnRunning: turnRunning,
                                        hasUnresolvedFailedTurnRetry:
                                            hasUnresolvedFailedTurnRetry)
    }

    private var stopGlyphColor: Color {
        switch theme.id {
        case .soft: theme.accentFg
        case .control: theme.danger
        case .ink: theme.bg
        }
    }

    /// The single highest-value control on this screen: while a turn runs the
    /// send button becomes stop (session.interrupt), so a runaway bot can be
    /// halted from the phone.
    /// Stop is what the button means only when there is nothing to send.
    /// With a draft in hand it is a send button even mid-turn — that send
    /// steers or queues (the hint above the field says which), which is what
    /// you wanted when you typed. Reaching for the return key to get past a
    /// permanent stop button was the old behaviour.
    private var showsStop: Bool { composerAction == .stop }

    private var sendOrStopButton: some View {
        Button {
            if showsStop {
                model.stopTurn(botID: botID)
            } else {
                send()
            }
        } label: {
            ZStack {
                if showsStop {
                    RoundedRectangle(cornerRadius: theme.id == .soft ? 3
                                        : theme.id == .control ? 1 : 2)
                        .fill(stopGlyphColor)
                        .frame(width: 12, height: 12)
                        .transition(TalariaMotionTokens.iconSwapTransition(
                            reducedMotion: reducedMotion))
                } else {
                    Text(verbatim: "↑")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(theme.accentFg)
                        .transition(TalariaMotionTokens.iconSwapTransition(
                            reducedMotion: reducedMotion))
                }
            }
            .frame(width: 20, height: 20)
            .frame(width: ChatComposerLayoutPolicy.controlHitTarget,
                   height: ChatComposerLayoutPolicy.controlHitTarget)
            .background(sendBackground, in: sendShape)
            .overlay {
                if showsStop, theme.id != .soft {
                    sendShape.strokeBorder(theme.danger.opacity(0.55), lineWidth: 1)
                }
            }
            .contentShape(sendShape)
        }
        .buttonStyle(.plain)
        .disabled(!canSend && !showsStop)
        .shadow(color: showsStop && theme.glowRadius > 0 ? theme.danger.opacity(0.45) : .clear,
                radius: 8)
        .animation(TalariaMotionTokens.opacityAnimation(.fast, reducedMotion: reducedMotion),
                   value: canSend)
        .animation(TalariaMotionTokens.opacityAnimation(.fast, reducedMotion: reducedMotion),
                   value: turnRunning)
        .animation(TalariaMotionTokens.opacityAnimation(.fast, reducedMotion: reducedMotion),
                   value: showsStop)
        .accessibilityLabel(showsStop ? copy.stopLabel(theme.id) : copy.sendLabel(theme.id))
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard canSend else { return }
        // A lone "/" is a request for the palette, not a command to run.
        if text == "/" {
            showCommands = true
            return
        }
        // Slash commands are not prompts: they go to slash.exec, which appends
        // its own user echo and leaves anything staged in the tray alone for
        // the next real turn.
        if text.hasPrefix("/") {
            draft = ""
            editingMessage = nil
            Task { await model.runSlash(text, botID: botID) }
            return
        }
        if let editing = editingMessage {
            guard model.canActOnTranscript(editing, in: botID) else { return }
            draft = ""
            editingMessage = nil
            model.editMessage(editing, in: botID, to: text)
            return
        }
        draft = ""
        model.sendOrSteer(text: text, to: botID)
    }
}

// MARK: - Chat copy (per-theme voice for the surfaces added here)

extension CopyPack {

    /// Stop button label (accessibility + control-theme readout).
    func stopLabel(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Stop"
        case .control: "ABORT TURN"
        case .ink: "stay its hand"
        }
    }

    func sendLabel(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Send"
        case .control: "TRANSMIT"
        case .ink: "send"
        }
    }

    func voiceLabel(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Start voice conversation"
        case .control: "OPEN VOICE CHANNEL"
        case .ink: "speak with it"
        }
    }

    func workingLabel(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Working"
        case .control: "WORKING"
        case .ink: "at work"
        }
    }

    /// System row appended when the user stops a running turn.
    func stopNote(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Stopped by you"
        case .control: "TURN INTERRUPTED BY OPERATOR"
        case .ink: "you stayed its hand"
        }
    }

    /// Composer hint while a turn is in flight.
    func steerHint(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Working — what you send now steers this turn instead of interrupting it."
        case .control: "TURN LIVE — INPUT INJECTS AS STEER, NO INTERRUPT"
        case .ink: "it works — a word now is whispered into the task, not over it"
        }
    }

    func attachLabel(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Attach a file"
        case .control: "ATTACH PAYLOAD"
        case .ink: "enclose something"
        }
    }

    func promptQueueTitle(_ theme: ThemeID, count: Int) -> String {
        switch theme {
        case .soft: "Queued · \(count)"
        case .control: "QUEUED \(count)"
        case .ink: "waiting · \(count)"
        }
    }
    func promptQueueRemove(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Dismiss"
        case .control: "DISMISS"
        case .ink: "hide this note"
        }
    }

    func promptQueueNotice(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Dismiss only hides this notice; Hermes still runs the queued prompt."
        case .control: "DISMISS HIDES LOCAL MIRROR ONLY — GATEWAY EXECUTION CONTINUES"
        case .ink: "Hiding the note does not unspeak the waiting words."
        }
    }

    func copyMessage(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Copy text"
        case .control: "COPY"
        case .ink: "take a copy"
        }
    }

    func reactMessage(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "React"
        case .control: "MARK"
        case .ink: "leave a mark"
        }
    }

    func editMessage(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Edit"
        case .control: "REVISE"
        case .ink: "amend the words"
        }
    }

    func rewindMessage(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Rewind from here"
        case .control: "RESTORE CHECKPOINT"
        case .ink: "return to this hour"
        }
    }

    func regenerateMessage(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Regenerate"
        case .control: "RERUN"
        case .ink: "ask again"
        }
    }

    func rewindCancel(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Cancel"
        case .control: "CANCEL"
        case .ink: "leave it"
        }
    }

    func rewindConfirmTitle(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Rewind this chat?"
        case .control: "RESTORE THIS CHECKPOINT?"
        case .ink: "unwind the later hours?"
        }
    }

    func rewindConfirmMessage(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "Everything after this message will be dropped, then the same prompt runs again."
        case .control: "DROPS THIS TURN AND EVERYTHING AFTER IT, THEN RESUBMITS."
        case .ink: "What followed this word is struck out, and the word is spoken once more."
        }
    }

    /// Tool chip: running with no argument preview yet.
    func toolRunning(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "running…"
        case .control: "RUNNING"
        case .ink: "at work"
        }
    }

    func toolFailed(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "failed"
        case .control: "FAULT"
        case .ink: "it faltered"
        }
    }

    /// Header above an expanded tool result.
    func toolResultHead(_ theme: ThemeID) -> String {
        switch theme {
        case .soft: "RESULT"
        case .control: "RETURN"
        case .ink: "WHAT CAME BACK"
        }
    }
}

// MARK: - Entrance

/// rowU for chat messages — quick fade + rise.
private struct ChatEntrance: ViewModifier {
    @State private var shown = false
    @Environment(\.talariaReducedMotion) private var reducedMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: reducedMotion ? 0 : (shown ? 0 : 12))
            .onAppear {
                withAnimation(reducedMotion
                    ? TalariaMotionTokens.opacityAnimation(.fast, reducedMotion: true)
                    : TalariaMotionTokens.spatialAnimation(.deliberate, reducedMotion: false)) {
                    shown = true
                }
            }
    }
}

// MARK: - Thought block (desktop reasoning parity)

/// The collapsible reasoning block above a bot message — desktop's "Thought ›"
/// row. While reasoning is streaming ahead of the first visible token it shows
/// a live tail instead of a chevron.
struct ThoughtBlock: View {
    var reasoning: String
    var theme: ThemePack
    var isLive: Bool

    @State private var expanded = false
    @Environment(\.talariaReducedMotion) private var reducedMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(TalariaMotionTokens.spatialAnimation(
                    .quick, reducedMotion: reducedMotion
                )) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(isLive ? "thinking" : "Thought")
                        .font(theme.mono(10, weight: .semibold))
                        .foregroundStyle(theme.faint)
                    if isLive {
                        Circle().fill(theme.accent)
                            .frame(width: 5, height: 5)
                            .shadow(color: theme.accent.opacity(0.6), radius: 3)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(theme.faint)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded || isLive {
                Text(isLive ? String(reasoning.suffix(280)) : reasoning)
                    .font(theme.mono(11))
                    .lineSpacing(3)
                    .foregroundStyle(theme.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(theme.inset.opacity(theme.id == .ink ? 0 : 1),
                                in: RoundedRectangle(cornerRadius: theme.cardRadius == 0 ? 0 : 10))
                    .overlay(alignment: .leading) {
                        if theme.id == .ink {
                            Rectangle().fill(theme.line).frame(width: 2)
                        }
                    }
            }
        }
    }
}


/// The preference stream has no meaningful scalar default: `0` can be an
/// actual coordinate, and treating two default zeroes as a measurement makes
/// an unlaid-out transcript look as though it is already at the live edge.
struct TranscriptGeometryReadiness: Equatable {
    private(set) var bottomMinY: CGFloat?
    private(set) var viewportHeight: CGFloat?

    var isReady: Bool {
        bottomMinY != nil && (viewportHeight ?? 0) > 0
    }

    var distanceFromBottom: CGFloat? {
        guard isReady, let bottomMinY, let viewportHeight else { return nil }
        return bottomMinY - viewportHeight
    }

    mutating func recordBottom(minY: CGFloat?) {
        bottomMinY = minY
    }

    mutating func recordViewport(height: CGFloat?) {
        viewportHeight = height
    }
}

/// One initial-anchor attempt belongs to the bot and to the user-interaction
/// generation in which it began. A drag settles that bot without completing
/// the attempt, invalidating every delayed pass while leaving the user's
/// `followingLatest` choice alone.
struct InitialTranscriptAnchorState: Equatable {
    struct Attempt: Equatable {
        let botID: String
        fileprivate let generation: UInt
    }

    private(set) var settledBotID: String?
    private var generation: UInt = 0

    func begin(botID: String, messageCount: Int) -> Attempt? {
        guard messageCount > 0, settledBotID != botID else { return nil }
        return Attempt(botID: botID, generation: generation)
    }

    func isSettled(for botID: String) -> Bool {
        settledBotID == botID
    }

    func shouldContinue(_ attempt: Attempt, currentBotID: String,
                        isCancelled: Bool) -> Bool {
        !isCancelled
            && currentBotID == attempt.botID
            && settledBotID != attempt.botID
            && generation == attempt.generation
    }

    mutating func complete(_ attempt: Attempt, currentBotID: String,
                           isCancelled: Bool = false) -> Bool {
        guard shouldContinue(attempt, currentBotID: currentBotID,
                             isCancelled: isCancelled)
        else { return false }
        settledBotID = attempt.botID
        return true
    }

    mutating func userDeparted(botID: String, messageCount: Int) -> Bool {
        guard messageCount > 0, settledBotID != botID else { return false }
        generation &+= 1
        settledBotID = botID
        return true
    }
}

private struct TranscriptBottomInsetKey: PreferenceKey {
    static var defaultValue: CGFloat?
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

private struct TranscriptViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat?
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}
