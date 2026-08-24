import Foundation
import Observation
import SwiftUI
import TalariaKit
import TalariaTheme

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// The bot's stored sessions — desktop's sidebar session list, folded into one
// phone sheet (PARITY.md §4 "Sessions & history").
//
// This is a POWER-USER surface and stays one. The canonical forever-chat is the
// mobile model: you tap a bot and you are in its conversation, always. Session
// management is a desktop concern, so every verb past "open" lives behind a
// long-press or a swipe inside this sheet and none of it is ever primary
// navigation (ROADMAP decision #4).
//
// Rows come from session.list {limit:200, profile, include_hidden}; tapping one
// resumes it by durable key and rebinds the chat. Long-press carries the verbs:
// pin, rename, export, archive, delete, and — on the row that is currently
// bound to this bot's chat — branch and compress. Typing filters the loaded
// rows and, past two characters, also runs the gateway's full-text index so a
// phrase from inside a conversation finds it.

@MainActor
public struct SessionsSheet: View {
    private let model: AppModel
    private let botID: String
    private let onOpenTerminal: ((String, String, String) -> Void)?
    private let onOpen: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var query = ""
    @State private var loading = true
    @State private var loadError: String?
    /// Full-text hits that are not already in the loaded page.
    @State private var hits: [SessionSearchHit] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var outcome: SessionActionOutcome?
    @State private var working = false
    @State private var renameTarget: String?
    @State private var renameText = ""
    @State private var showArchived = false
    @State private var exported: ExportedFile?
    @State private var expandedRootIDs: Set<String> = []
    @FocusState private var renameFocused: Bool

    /// `onOpen` fires after the chat has been rebound onto the tapped
    /// session, so the host can bring the chat forward.
    public init(model: AppModel, botID: String,
                onOpenTerminal: ((String, String, String) -> Void)? = nil,
                onOpen: ((String) -> Void)? = nil) {
        self.model = model
        self.botID = botID
        self.onOpenTerminal = onOpenTerminal
        self.onOpen = onOpen
    }

    private var theme: ThemePack { model.theme.pack }
    private var copy: CopyPack { model.theme.copy }
    // MARK: - Rows

    /// One list row, from either the loaded page or the full-text index.
    private struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let when: String
        let messageCount: Int
        let preview: String
        /// A full-text hit outside the loaded page — no local counts for it.
        let remote: Bool
        var pinned: Bool = false
        var rootID: String
        var logicalLevel: Int = 0
        var orphan: Bool = false
        var branchCount: Int = 0
        var hasChildren: Bool = false
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var lineage: SessionLineageProjection {
        let summaries = (model.chats[botID]?.storedSessions ?? []).map { summary in
            var projected = summary
            if projected.preview == nil {
                projected.preview = model.sessionPreview(summary.id, botID: botID)
            }
            return projected
        }
        return SessionLineageProjection(summaries)
    }

    private var currentRootID: String? {
        guard let currentSessionID else { return nil }
        return lineage.entries.first(where: { $0.id == currentSessionID
            || $0.summary.lineageRootID == currentSessionID })?.rootID
    }

    private var rootsExpandedForPresentation: Set<String> {
        var roots = expandedRootIDs
        if let currentRootID { roots.insert(currentRootID) }
        return roots
    }

    /// Loaded rows are projected into durable lineage before filtering. A pin
    /// on any descendant promotes the entire root group without detaching that
    /// descendant from its parent.
    private var storedRows: [Row] {
        let needle = trimmedQuery
        let searched = lineage.search(needle)
        let pinnedRoots = Set(lineage.entries.compactMap { entry in
            model.isSessionPinned(entry.id, botID: botID) ? entry.rootID : nil
        })
        let ordered = searched.filter { pinnedRoots.contains($0.rootID) }
            + searched.filter { !pinnedRoots.contains($0.rootID) }
        let expanded = rootsExpandedForPresentation
        let branchCounts = Dictionary(grouping: lineage.entries, by: \.rootID)
            .mapValues { max(0, $0.count - 1) }
        return ordered.compactMap { entry in
            guard !needle.isEmpty || entry.isRoot || expanded.contains(entry.rootID) else {
                return nil
            }
            let session = entry.summary
            let preview = session.preview
                ?? model.sessionPreview(session.id, botID: botID) ?? ""
            return Row(id: session.id, title: session.title, when: session.when,
                       messageCount: session.messageCount, preview: preview,
                       remote: false,
                       pinned: model.isSessionPinned(session.id, botID: botID),
                       rootID: entry.rootID, logicalLevel: entry.logicalLevel,
                       orphan: entry.isOrphan,
                       branchCount: entry.isRoot ? (branchCounts[entry.rootID] ?? 0) : 0,
                       hasChildren: entry.isRoot && (branchCounts[entry.rootID] ?? 0) > 0)
        }
    }

    private var remoteRows: [Row] {
        let known = Set((model.chats[botID]?.storedSessions ?? []).map(\.id))
        return hits.compactMap { hit in
            guard SessionsSheetLineagePresentationPolicy.isFullTextOnly(
                sessionID: hit.sessionID, knownSessionIDs: known) else { return nil }
            return Row(id: hit.sessionID, title: hit.title, when: hit.when,
                       messageCount: 0, preview: hit.snippet, remote: true,
                       rootID: hit.sessionID)
        }
    }

    private var archived: [ArchivedSessionRecord] { model.archivedSessions(botID: botID) }

    private var isEmpty: Bool { storedRows.isEmpty && remoteRows.isEmpty }

    /// The session this bot's chat is currently bound to. Branch and compress
    /// resolve RUNTIME sids, so they are only offered on the row the gateway
    /// already holds live — anything else would need a silent resume behind the
    /// user's back (GatewayClient+Sessions.swift, ws-protocol.md §7.4).
    private var currentSessionID: String? { model.chats[botID]?.storedSessionID }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(theme: theme, kicker: copy.sessKicker(theme.id),
                         title: copy.sessionsSec) {
                HStack(spacing: 8) {
                    if model.mode == .live { overflow }
                    HeaderIconButton(theme: theme, action: { dismiss() }) {
                        Text(verbatim: "✕")
                            .font(theme.body(13, weight: .bold))
                            .foregroundStyle(theme.id == .ink ? theme.ink : theme.sub)
                    }
                }
            }

            searchField
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            if working || outcome != nil {
                statusCard
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            list
        }
        .background(theme.bg.ignoresSafeArea())
        .presentationBackground(theme.bg)
        .presentationDetents([.large])
        .overlay { if renameTarget != nil { renameOverlay } }
        .sheet(item: $exported) { file in
            #if os(iOS)
            TalariaShareSheet(items: [file.url]) { exported = nil }
            #else
            EmptyView()
            #endif
        }
        .task(id: botID) { await load() }
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: - Header pieces

    /// Turn controls for the session the chat is on right now. These are the
    /// ones that act on a LIVE session (runtime sid), which is why they hang off
    /// the header rather than off an arbitrary row.
    private var overflow: some View {
        Menu {
            Button(copy.sessBranch(theme.id)) { run { await model.branchSession(botID: botID) } }
            Button(copy.sessCompress(theme.id)) { run { await model.compressSession(botID: botID) } }
            Button(copy.sessExport(theme.id)) { run { await model.exportSession(botID: botID) } }
        } label: {
            Text(verbatim: "···")
                .font(theme.body(15, weight: .black))
                .foregroundStyle(theme.id == .ink ? theme.ink : theme.accent)
                .frame(width: 32, height: 32)
                .background(theme.id == .ink ? Color.clear : theme.panel)
                .clipShape(iconShape)
                .overlay(iconShape.strokeBorder(theme.id == .soft ? theme.line : theme.lineStrong,
                                                lineWidth: 1))
                .contentShape(iconShape)
        }
        .menuStyle(.borderlessButton)
        .disabled(working)
        .opacity(working ? 0.5 : 1)
    }

    private var iconShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 32 * theme.iconCornerFraction, style: .continuous)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Text(verbatim: "⌕")
                .font(theme.mono(15, weight: .semibold))
                .foregroundStyle(theme.faint)
            TextField(copy.sessSearchPlaceholder(theme.id), text: $query)
                .textFieldStyle(.plain)
                .font(theme.id == .control ? theme.mono(12) : theme.body(13.5))
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
                .onChange(of: query) { _, _ in scheduleSearch() }
            if !query.isEmpty {
                Button {
                    query = ""
                    hits = []
                } label: {
                    Text(verbatim: "✕")
                        .font(theme.body(11, weight: .bold))
                        .foregroundStyle(theme.faint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(theme.inset,
                    in: RoundedRectangle(cornerRadius: theme.inputRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.inputRadius, style: .continuous)
            .strokeBorder(theme.line, lineWidth: 1))
    }

    /// One slot for both "an action is running" and "here is what it did".
    private var statusCard: some View {
        HStack(alignment: .top, spacing: 9) {
            if working {
                ProgressView().controlSize(.small).tint(theme.accent)
            } else if let outcome {
                Text(verbatim: outcome.ok ? "✓" : "!")
                    .font(theme.mono(12, weight: .bold))
                    .foregroundStyle(outcome.ok ? theme.ok : theme.danger)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(working ? copy.sessWorking(theme.id) : (outcome?.headline ?? ""))
                    .font(theme.id == .control ? theme.mono(11, weight: .semibold)
                                               : theme.body(12.5, weight: .semibold))
                    .foregroundStyle(theme.ink)
                if let detail = outcome?.detail, !detail.isEmpty, !working {
                    Text(detail)
                        .font(theme.id == .control ? theme.mono(9.5) : theme.body(11.5))
                        .foregroundStyle(theme.sub)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !working, outcome != nil {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { outcome = nil }
                } label: {
                    Text(verbatim: "✕")
                        .font(theme.body(11, weight: .bold))
                        .foregroundStyle(theme.faint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panel,
                    in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
            .strokeBorder(outcome?.ok == false ? theme.danger.opacity(0.5) : theme.line,
                          lineWidth: 1))
    }

    // MARK: - List

    private var list: some View {
        List {
            if loading {
                loadingRow
            } else if let loadError {
                noteRow(loadError, tone: theme.danger)
            } else if isEmpty {
                noteRow(trimmedQuery.isEmpty ? copy.sessEmpty(theme.id)
                                             : copy.sessNoMatches(theme.id),
                        tone: theme.sub)
            }

            ForEach(storedRows) { row in sessionRow(row) }

            if !remoteRows.isEmpty {
                sectionLabel(copy.sessFullText(theme.id))
                ForEach(remoteRows) { row in sessionRow(row) }
            }

            if !archived.isEmpty { archivedSection }

            if !loading, !isEmpty {
                noteRow(copy.sessFootnote(theme.id, canArchive: model.sessionFlagsSupported),
                        tone: theme.faint)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .refreshable { await load() }
    }

    private func sessionRow(_ row: Row) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Button {
                open(row)
            } label: {
                sessionRowLabel(row)
                    .frame(maxWidth: .infinity, minHeight:
                            SessionsSheetLineagePresentationPolicy.minimumActionSize,
                           alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(SessionsSheetLineagePresentationPolicy.voiceOverLabel(
                title: row.title, logicalLevel: row.logicalLevel,
                branchCount: row.branchCount, orphan: row.orphan,
                current: row.id == currentSessionID))

            if row.hasChildren, trimmedQuery.isEmpty {
                Button {
                    toggleExpanded(row.rootID)
                } label: {
                    Text(verbatim: rootsExpandedForPresentation.contains(row.rootID) ? "▾" : "▸")
                        .font(theme.mono(11, weight: .bold))
                        .foregroundStyle(theme.faint)
                        .frame(minWidth: SessionsSheetLineagePresentationPolicy.minimumActionSize,
                               minHeight: SessionsSheetLineagePresentationPolicy.minimumActionSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(rootsExpandedForPresentation.contains(row.rootID)
                                    ? "Collapse branches" : "Expand branches")
                .accessibilityValue("\(row.branchCount) branches")
            }
        }
        .padding(.leading, CGFloat(
            SessionsSheetLineagePresentationPolicy.visualIndentLevel(row.logicalLevel)) * 14)
        .modifier(SessionRowChrome(theme: theme))
        .listRowInsets(EdgeInsets(top: theme.rowStyle == .ledger ? 0 : 3, leading: 20,
                                  bottom: theme.rowStyle == .ledger ? 0 : 3, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(theme.bg)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Archive is the safe phone gesture, so it takes the swipe slot and
            // delete moves to the long-press menu (PARITY.md §sidebars-nav:249).
            // A row that cannot be archived keeps the old pair, or delete would
            // have no reachable affordance at all.
            if canArchive(row) {
                Button { archive(row) } label: { Text(copy.sessArchive(theme.id)) }
                    .tint(theme.warn)
            } else {
                Button(role: .destructive) { delete(row) } label: {
                    Text(copy.sessDelete(theme.id))
                }
            }
            Button { startRename(row) } label: {
                Text(copy.sessRename(theme.id))
            }
            .tint(theme.accent)
        }
        .contextMenu { rowMenu(row) }
    }

    private func sessionRowLabel(_ row: Row) -> some View {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        if row.pinned {
                            Text(verbatim: "◆")
                                .font(theme.mono(9, weight: .bold))
                                .foregroundStyle(theme.accent)
                        }
                        Text(row.title)
                            .font(theme.id == .ink ? theme.body(15.5, weight: .semibold)
                                                   : theme.body(13.5, weight: .semibold))
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                        if row.orphan {
                            Text(verbatim: "Branch")
                                .font(theme.mono(8, weight: .semibold))
                                .foregroundStyle(theme.faint)
                        }
                    }
                    Text(metaLine(row))
                        .font(theme.id == .soft ? theme.body(11, weight: .medium)
                                                : theme.mono(theme.id == .ink ? 9 : 10))
                        .foregroundStyle(theme.faint)
                        .lineLimit(1)
                    if !row.preview.isEmpty {
                        Text(row.preview)
                            .font(theme.id == .control ? theme.mono(10)
                                                       : theme.body(theme.id == .ink ? 13 : 12))
                            .italic(theme.id == .ink)
                            .foregroundStyle(theme.sub)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if row.branchCount > 0 {
                        Text("\(row.branchCount) \(row.branchCount == 1 ? "branch" : "branches")")
                            .font(theme.id == .soft ? theme.body(10, weight: .medium)
                                                    : theme.mono(9, weight: .semibold))
                            .foregroundStyle(theme.faint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: "›")
                    .font(theme.body(13, weight: .semibold))
                    .foregroundStyle(theme.faint)
                    .padding(.top, 1)
            }
            .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))
    }

    private func toggleExpanded(_ rootID: String) {
        let update = {
            if expandedRootIDs.contains(rootID) {
                expandedRootIDs.remove(rootID)
            } else {
                expandedRootIDs.insert(rootID)
            }
        }
        if reduceMotion { update() }
        else { withAnimation(.easeOut(duration: 0.2)) { update() } }
    }

    /// The tucked-away verb set. Long-press is deliberately the only door: none
    /// of this competes with tapping a bot and being in its chat.
    @ViewBuilder private func rowMenu(_ row: Row) -> some View {
        if model.sessionFlagsSupported, !row.remote {
            Button(row.pinned ? copy.sessUnpin(theme.id) : copy.sessPin(theme.id)) {
                pin(row, pinned: !row.pinned)
            }
        }
        Button(copy.sessRename(theme.id)) { startRename(row) }
        if row.id == currentSessionID {
            Button(copy.sessBranch(theme.id)) { run { await model.branchSession(botID: botID) } }
            Button(copy.sessCompress(theme.id)) { run { await model.compressSession(botID: botID) } }
        }
        Button(copy.sessShare(theme.id)) { share(row) }
        Button(copy.sessCopyID(theme.id)) { model.copySessionID(row.id) }
        Button("Open in Advanced Terminal") { openInTerminal(row) }
        if canArchive(row) {
            Button(copy.sessArchive(theme.id)) { archive(row) }
        }
        Button(copy.sessDelete(theme.id), role: .destructive) { delete(row) }
    }

    /// The bot's forever-chat is deliberately not archivable. Archiving drops a
    /// row out of `session.list`, and canonical resolution's last-resort probe
    /// reads that list to decide whether a bot has any history at all
    /// (AppModelLive+CanonicalChat.swift, step (c)) — so archiving the one chat
    /// that IS the product could send the next open down the birth path and
    /// fork the conversation. Delete stays available; it clears the binding
    /// honestly instead of hiding it.
    private func canArchive(_ row: Row) -> Bool {
        guard model.sessionFlagsSupported, !row.remote else { return false }
        return !model.isCanonicalChat(row.id, botID: botID)
    }

    private func openInTerminal(_ row: Row) {
        guard let route = model.profileRoute(for: botID) else { return }
        if let onOpenTerminal {
            onOpenTerminal(route.gatewayID, route.profile, row.id)
            dismiss()
            return
        }
        dismiss()
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .talariaOpenCommandCenter,
                object: nil,
                userInfo: [
                    "gatewayID": route.gatewayID,
                    "profile": route.profile,
                    "terminalResume": row.id,
                ]
            )
        }
    }

    private func metaLine(_ row: Row) -> String {
        guard !row.remote, row.messageCount > 0 else { return row.when }
        return "\(row.when) · \(row.messageCount) \(copy.sessMessages(theme.id))"
    }

    // MARK: Archived

    /// Archived rows are gone from `session.list` (it filters `archived = 0`),
    /// and the REST archived listing cannot return the hidden Bot Mode ones —
    /// so the ledger this device wrote when it archived them is what keeps
    /// Restore reachable. Collapsed by default; this is not a destination.
    @ViewBuilder private var archivedSection: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { showArchived.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: showArchived ? "▾" : "▸")
                    .font(theme.mono(9, weight: .bold))
                    .foregroundStyle(theme.faint)
                Text("\(copy.sessArchivedSection(theme.id)) \(archived.count)")
                    .font(theme.id == .soft ? theme.body(11, weight: .heavy)
                                            : theme.mono(9, weight: .bold))
                    .tracking(theme.id == .soft ? 1 : 2)
                    .foregroundStyle(theme.faint)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(theme.bg)

        if showArchived {
            ForEach(archived) { record in archivedRow(record) }
        }
    }

    private func archivedRow(_ record: ArchivedSessionRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(theme.id == .ink ? theme.body(15, weight: .semibold)
                                           : theme.body(13, weight: .semibold))
                    .foregroundStyle(theme.sub)
                    .lineLimit(1)
                Text(record.when)
                    .font(theme.mono(theme.id == .ink ? 9 : 10))
                    .foregroundStyle(theme.faint)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(copy.sessRestore(theme.id)) { restore(record) }
                .font(theme.id == .control ? theme.mono(10, weight: .semibold)
                                           : theme.body(12, weight: .semibold))
                .foregroundStyle(theme.accent)
                .buttonStyle(.plain)
        }
        .padding(EdgeInsets(top: 10, leading: 13, bottom: 10, trailing: 13))
        .opacity(0.85)
        .modifier(SessionRowChrome(theme: theme))
        .listRowInsets(EdgeInsets(top: theme.rowStyle == .ledger ? 0 : 3, leading: 20,
                                  bottom: theme.rowStyle == .ledger ? 0 : 3, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(theme.bg)
        .contextMenu {
            Button(copy.sessRestore(theme.id)) { restore(record) }
            Button(copy.sessDelete(theme.id), role: .destructive) { deleteArchived(record) }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(theme.accent)
            Text(verbatim: "session.list…")
                .font(theme.mono(11))
                .foregroundStyle(theme.faint)
        }
        .padding(.vertical, 10)
        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(theme.bg)
    }

    private func noteRow(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(theme.id == .control ? theme.mono(10) : theme.body(12))
            .italic(theme.id == .ink)
            .foregroundStyle(tone)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(theme.bg)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(theme.id == .soft ? theme.body(11, weight: .heavy) : theme.mono(9, weight: .bold))
            .tracking(theme.id == .soft ? 1 : 2)
            .foregroundStyle(theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .padding(.bottom, 2)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(theme.bg)
    }

    // MARK: - Rename (themed; a system alert would break all three looks)

    private var renameOverlay: some View {
        ZStack {
            theme.bg.opacity(theme.id == .control ? 0.86 : 0.72)
                .ignoresSafeArea()
                .onTapGesture { cancelRename() }

            VStack(alignment: .leading, spacing: 12) {
                Text(copy.sessRenameTitle(theme.id))
                    .font(theme.id == .ink ? theme.display(20, weight: .bold).smallCaps()
                                           : theme.body(16, weight: .heavy))
                    .foregroundStyle(theme.ink)

                TextField(copy.sessRenamePlaceholder(theme.id), text: $renameText)
                    .textFieldStyle(.plain)
                    .font(theme.id == .control ? theme.mono(13) : theme.body(14))
                    .foregroundStyle(theme.ink)
                    .tint(theme.accent)
                    .focused($renameFocused)
                    .onSubmit { commitRename() }
                    .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
                    .background(theme.inset,
                                in: RoundedRectangle(cornerRadius: theme.inputRadius,
                                                     style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: theme.inputRadius, style: .continuous)
                        .strokeBorder(theme.line, lineWidth: 1))

                // The secondary button style is the deny/abort treatment
                // (red-bordered in control) — wrong voice for a cancel, so
                // this uses the sheets' quiet text-button affordance.
                HStack(spacing: 12) {
                    Button(copy.cancel) { cancelRename() }
                        .font(theme.body(13, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .buttonStyle(.plain)
                    Spacer(minLength: 8)
                    ThemedPrimaryButton(theme: theme, title: copy.sessRenameOK(theme.id),
                                        compact: true) {
                        commitRename()
                    }
                    .frame(maxWidth: 150)
                }
            }
            .padding(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            .frame(maxWidth: 340)
            .background(theme.panel,
                        in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                .strokeBorder(theme.id == .ink ? theme.lineStrong : theme.line, lineWidth: 1))
            .padding(.horizontal, 24)
        }
        .transition(.opacity)
    }

    // MARK: - Actions

    private func load() async {
        await model.refreshSessions(botID: botID)
        loadError = model.sessionsLoadError(for: botID)
        loading = false
        // Pins are written through to the gateway but read back from it too,
        // so a reinstalled phone recovers what desktop pinned.
        await model.syncSessionFlags(botID: botID)
    }

    private func open(_ row: Row) {
        model.openStoredSession(row.id, botID: botID)
        onOpen?(row.id)
        dismiss()
    }

    private func delete(_ row: Row) {
        Task { @MainActor in
            working = true
            // Narrated through the toast bus (and mirrored into the Activity
            // ledger); the inline banner below stays for the failure the user is
            // looking straight at, since a root-hosted toast cannot be seen over
            // this sheet.
            let failure = await model.deleteSessionWithFeedback(row.id, botID: botID,
                                                                title: row.title)
            working = false
            hits.removeAll { $0.sessionID == row.id }
            if let failure {
                withAnimation(.easeOut(duration: 0.2)) {
                    outcome = SessionActionOutcome(ok: false, headline: failure)
                }
            } else {
                model.forgetSessionFlags(row.id, botID: botID)
            }
        }
    }

    private func deleteArchived(_ record: ArchivedSessionRecord) {
        Task { @MainActor in
            working = true
            let failure = await model.deleteSessionWithFeedback(record.sessionID,
                                                                botID: botID,
                                                                title: record.title)
            working = false
            if let failure {
                withAnimation(.easeOut(duration: 0.2)) {
                    outcome = SessionActionOutcome(ok: false, headline: failure)
                }
            } else {
                model.forgetSessionFlags(record.sessionID, botID: botID)
            }
        }
    }

    private func pin(_ row: Row, pinned: Bool) {
        Task { @MainActor in
            working = true
            let failure = await model.setSessionPinned(row.id, botID: botID, pinned: pinned)
            working = false
            if let failure {
                withAnimation(.easeOut(duration: 0.2)) {
                    outcome = SessionActionOutcome(ok: false, headline: failure)
                }
            }
        }
    }

    private func archive(_ row: Row) {
        Task { @MainActor in
            working = true
            let failure = await model.archiveStoredSession(row.id, botID: botID, title: row.title,
                                                           when: row.when)
            working = false
            hits.removeAll { $0.sessionID == row.id }
            withAnimation(.easeOut(duration: 0.2)) {
                outcome = failure.map { SessionActionOutcome(ok: false, headline: $0) }
                    ?? SessionActionOutcome(ok: true, headline: copy.sessArchived(theme.id),
                                            detail: row.title)
            }
        }
    }

    private func restore(_ record: ArchivedSessionRecord) {
        Task { @MainActor in
            working = true
            let failure = await model.restoreArchivedSession(record)
            working = false
            if let failure {
                withAnimation(.easeOut(duration: 0.2)) {
                    outcome = SessionActionOutcome(ok: false, headline: failure)
                }
            } else {
                await load()
            }
        }
    }

    /// Pull the whole transcript as JSON and hand it to the share sheet. This
    /// is the phone's export: `session.save` writes a snapshot on the GATEWAY
    /// host (still in the header overflow, still useful), but a copy you can
    /// actually send someone has to come over the wire.
    private func share(_ row: Row) {
        Task { @MainActor in
            working = true
            let result = await model.exportStoredSession(row.id, botID: botID, title: row.title)
            working = false
            switch result {
            case .ready(let url):
                #if os(iOS)
                exported = ExportedFile(url: url)
                #else
                withAnimation(.easeOut(duration: 0.2)) {
                    outcome = SessionActionOutcome(ok: true,
                                                   headline: copy.sessShared(theme.id),
                                                   detail: url.path)
                }
                #endif
            case .failed(let reason):
                withAnimation(.easeOut(duration: 0.2)) {
                    outcome = SessionActionOutcome(ok: false, headline: reason)
                }
            }
        }
    }

    private func startRename(_ row: Row) {
        renameText = row.title
        withAnimation(.easeOut(duration: 0.2)) { renameTarget = row.id }
        renameFocused = true
    }

    private func cancelRename() {
        renameFocused = false
        withAnimation(.easeOut(duration: 0.2)) { renameTarget = nil }
    }

    private func commitRename() {
        guard let id = renameTarget else { return }
        let title = renameText
        cancelRename()
        Task { @MainActor in
            working = true
            let failure = await model.renameSessionWithFeedback(id, botID: botID, to: title)
            working = false
            if let failure {
                withAnimation(.easeOut(duration: 0.2)) {
                    outcome = SessionActionOutcome(ok: false, headline: failure)
                }
            } else {
                // A renamed row can also be a full-text hit; keep both in step.
                hits = hits.map { hit in
                    guard hit.sessionID == id else { return hit }
                    var renamed = hit
                    renamed.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    return renamed
                }
            }
        }
    }

    /// Run one overflow action, showing the spinner while it is in flight.
    private func run(_ action: @escaping () async -> SessionActionOutcome) {
        guard !working else { return }
        Task { @MainActor in
            withAnimation(.easeOut(duration: 0.2)) {
                outcome = nil
                working = true
            }
            let result = await action()
            withAnimation(.easeOut(duration: 0.2)) {
                working = false
                outcome = result
            }
        }
    }

    /// Local filtering is instant; the gateway's FTS index is a round trip, so
    /// it is debounced and only runs once the query is worth an index lookup.
    private func scheduleSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.mode == .live, !model.isOffline, q.count >= 2 else {
            hits = []
            return
        }
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let found = await model.searchSessions(q, botID: botID)
            guard !Task.isCancelled,
                  q == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            hits = found
        }
    }
}

// MARK: - Lineage presentation policy

/// Framework-light constants and accessibility copy kept outside the view so
/// layout and VoiceOver behavior can be verified without snapshot tests.
enum SessionsSheetLineagePresentationPolicy {
    static let minimumActionSize: CGFloat = 44
    static let maximumVisualIndentLevel = 2
    static let maximumAnnouncedLogicalLevel = SessionLineageProjection.maximumDepth

    static func visualIndentLevel(_ logicalLevel: Int) -> Int {
        min(max(0, logicalLevel), maximumVisualIndentLevel)
    }

    static func isFullTextOnly(sessionID: String, knownSessionIDs: Set<String>) -> Bool {
        !knownSessionIDs.contains(sessionID)
    }

    static func voiceOverLabel(title: String, logicalLevel: Int,
                               branchCount: Int, orphan: Bool,
                               current: Bool) -> String {
        var parts = [title]
        if logicalLevel > 0 {
            let bounded = min(logicalLevel, maximumAnnouncedLogicalLevel)
            parts.append("branch level \(bounded)")
        } else if orphan {
            parts.append("branch")
        }
        if branchCount > 0 {
            parts.append("\(branchCount) \(branchCount == 1 ? "branch" : "branches")")
        }
        if current { parts.append("current session") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Row chrome (card / terminal panel / ruled ledger)

private struct SessionRowChrome: ViewModifier {
    let theme: ThemePack

    @ViewBuilder func body(content: Content) -> some View {
        if theme.rowStyle == .ledger {
            // Ink: bare ledger lines, no card chrome.
            content.overlay(alignment: .bottom) {
                Rectangle().fill(theme.line).frame(height: 1)
            }
        } else {
            let shape = RoundedRectangle(cornerRadius: theme.rowRadius, style: .continuous)
            content
                .background(shape.fill(theme.panel))
                .clipShape(shape)
                .overlay(shape.strokeBorder(theme.line, lineWidth: 1))
                .shadow(color: theme.rowStyle == .card ? theme.ink.opacity(0.04) : .clear,
                        radius: 2, y: 1)
        }
    }
}

// MARK: - Durable session flags (pin / archive)

/// One session this device archived, kept so Restore stays reachable.
///
/// It has to be kept: `session.list` filters `archived = 0`
/// (hermes_state.py:8766) and the REST archived listing never returns hidden
/// rows — and every Bot Mode session, the canonical forever-chat included, is
/// born hidden (plugin.js:2540, 2759-2763). Without this ledger, archiving a
/// bot's own chat from the phone would put it somewhere the phone cannot look.
public struct ArchivedSessionRecord: Codable, Sendable, Identifiable, Equatable {
    public var sessionID: String
    public var botID: String
    public var gateway: String
    public var title: String
    public var when: String
    public var at: Double

    public var id: String { gateway + "|" + botID + "|" + sessionID }
}

/// Pin state and the archive ledger, per gateway. Observable so the sheet
/// repaints the moment a verb lands.
///
/// Pins are a hybrid on purpose, and desktop's sidebar is the same shape: the
/// durable flag is written to the gateway (`PATCH /api/sessions/{id} {pinned}`)
/// so a pin made on the phone shows up on the desktop, while the local set is
/// what the list actually sorts on — because the gateway's session listing
/// cannot report the flag for hidden Bot Mode rows, which is most of them.
@MainActor
@Observable
public final class SessionVerbStore {
    public static let shared = SessionVerbStore()

    /// "<gateway>|<bot>|<session>" for every pinned session.
    private(set) var pinned: Set<String> = []
    private(set) var archived: [ArchivedSessionRecord] = []
    /// nil until probed on this gateway; false once it proves it has no
    /// session-flags route, which hides pin and archive rather than offering
    /// buttons that cannot work.
    var supported: Bool?
    @ObservationIgnored private var probedGateway: String?

    static let pinsKey = "talaria-session-pins"
    static let archiveKey = "talaria-session-archive"

    /// Restored eagerly rather than lazily: the sheet reads pin state inside
    /// `body`, and a lazy load would mutate observed state mid-render.
    private init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.array(forKey: Self.pinsKey) as? [String] {
            pinned = Set(raw)
        }
        if let data = defaults.data(forKey: Self.archiveKey),
           let rows = try? JSONDecoder().decode([ArchivedSessionRecord].self, from: data) {
            archived = rows
        }
    }

    func gateway() -> String {
        LiveRuntime.shared.baseURL?.absoluteString ?? "demo"
    }

    func key(_ sessionID: String, botID: String) -> String {
        gateway() + "|" + botID + "|" + sessionID
    }

    func isPinned(_ sessionID: String, botID: String) -> Bool {
        pinned.contains(key(sessionID, botID: botID))
    }

    func setPinned(_ sessionID: String, botID: String, _ value: Bool) {
        let id = key(sessionID, botID: botID)
        if value { pinned.insert(id) } else { pinned.remove(id) }
        UserDefaults.standard.set(Array(pinned), forKey: Self.pinsKey)
    }

    /// Replace this bot's pins with the gateway's own answer, keeping every pin
    /// the server could not speak for (hidden rows it never lists).
    func adoptServerPins(_ ids: Set<String>, seen: Set<String>, botID: String) {
        let prefix = gateway() + "|" + botID + "|"
        for sessionID in seen {
            let id = prefix + sessionID
            if ids.contains(sessionID) { pinned.insert(id) } else { pinned.remove(id) }
        }
        UserDefaults.standard.set(Array(pinned), forKey: Self.pinsKey)
    }

    func rows(botID: String) -> [ArchivedSessionRecord] {
        let gateway = gateway()
        return archived
            .filter { $0.gateway == gateway && $0.botID == botID }
            .sorted { $0.at > $1.at }
    }

    func remember(_ record: ArchivedSessionRecord) {
        archived.removeAll { $0.id == record.id }
        archived.insert(record, at: 0)
        if archived.count > 200 { archived.removeLast(archived.count - 200) }
        persistArchive()
    }

    func forget(_ sessionID: String, botID: String) {
        let id = key(sessionID, botID: botID)
        archived.removeAll { $0.id == id }
        pinned.remove(id)
        UserDefaults.standard.set(Array(pinned), forKey: Self.pinsKey)
        persistArchive()
    }

    private func persistArchive() {
        guard let data = try? JSONEncoder().encode(archived) else { return }
        UserDefaults.standard.set(data, forKey: Self.archiveKey)
    }

    /// A gateway swap re-opens the question of whether these routes exist.
    func noteGateway() {
        let current = gateway()
        guard probedGateway != current else { return }
        probedGateway = current
        supported = nil
    }
}

// MARK: - Session verbs (durable-key REST)

public extension AppModel {

    /// True while pin/archive are worth offering: live, with a reachable HTTP
    /// credential, and on a gateway that has not refused the route. A gateway
    /// without it simply never shows those two verbs.
    var sessionFlagsSupported: Bool {
        guard mode == .live, !isOffline, gatewayRESTContext() != nil else { return false }
        return SessionVerbStore.shared.supported != false
    }

    func isSessionPinned(_ sessionID: String, botID: String) -> Bool {
        SessionVerbStore.shared.isPinned(sessionID, botID: botID)
    }

    /// Is this row the bot's canonical forever-chat? Match either durable root
    /// or resolved tip from the authoritative roster projection.
    func isCanonicalChat(_ sessionID: String, botID: String) -> Bool {
        isCurrentCanonicalSession(botID: botID, sessionID: sessionID)
    }

    func archivedSessions(botID: String) -> [ArchivedSessionRecord] {
        SessionVerbStore.shared.rows(botID: botID)
    }

    /// Drop every local trace of a session (after a delete).
    func forgetSessionFlags(_ sessionID: String, botID: String) {
        SessionVerbStore.shared.forget(sessionID, botID: botID)
    }

    /// Pin or unpin. Optimistic — the row jumps immediately — and rolled back
    /// if the gateway refuses, because a pin that silently did not take is
    /// worse than one that visibly failed.
    func setSessionPinned(_ sessionID: String, botID: String, pinned: Bool) async -> String? {
        let store = SessionVerbStore.shared
        guard let (base, credential) = gatewayRESTContext() else {
            return theme.copy.needsRESTNote(theme.themeID)
        }
        store.setPinned(sessionID, botID: botID, pinned)
        do {
            try await GatewayREST.patchSession(baseURL: base, credential: credential,
                                               sessionID: sessionID, profile: botID,
                                               pinned: pinned)
            return nil
        } catch {
            store.setPinned(sessionID, botID: botID, !pinned)
            noteFlagsRoute(error)
            return Self.sessionFailure(error, theme: theme)
        }
    }

    /// Soft-archive: the row leaves every list without the transcript being
    /// destroyed. Deliberately NOT `session.set_hidden` — Bot Mode sessions are
    /// already born hidden (plugin.js:2540, 2759-2763), so clearing `hidden` on
    /// a restore would leak a bot's forever-chat into desktop's global sidebar.
    /// `archived` is the flag that means "put this away", and it is reversible.
    func archiveStoredSession(_ sessionID: String, botID: String, title: String,
                              when: String) async -> String? {
        guard let (base, credential) = gatewayRESTContext() else {
            return theme.copy.needsRESTNote(theme.themeID)
        }
        do {
            try await GatewayREST.patchSession(baseURL: base, credential: credential,
                                               sessionID: sessionID, profile: botID,
                                               archived: true)
        } catch {
            noteFlagsRoute(error)
            return Self.sessionFailure(error, theme: theme)
        }
        SessionVerbStore.shared.remember(
            ArchivedSessionRecord(sessionID: sessionID, botID: botID,
                                  gateway: SessionVerbStore.shared.gateway(),
                                  title: title, when: when,
                                  at: Date().timeIntervalSince1970))
        await refreshSessions(botID: botID)
        return nil
    }

    func restoreArchivedSession(_ record: ArchivedSessionRecord) async -> String? {
        guard let (base, credential) = gatewayRESTContext() else {
            return theme.copy.needsRESTNote(theme.themeID)
        }
        do {
            try await GatewayREST.patchSession(baseURL: base, credential: credential,
                                               sessionID: record.sessionID,
                                               profile: record.botID, archived: false)
        } catch let error as GatewayError where error.code == 404 {
            // Already gone from the store; the ledger row is the stale thing.
            SessionVerbStore.shared.forget(record.sessionID, botID: record.botID)
            return nil
        } catch {
            noteFlagsRoute(error)
            return Self.sessionFailure(error, theme: theme)
        }
        SessionVerbStore.shared.forget(record.sessionID, botID: record.botID)
        return nil
    }

    /// Reconcile local pins against the gateway's own flags, and prove the
    /// route exists at the same time. The listing cannot see hidden rows, so
    /// only the sessions it DID return are reconciled — a local pin on a hidden
    /// Bot Mode chat is left exactly as it was rather than being cleared by an
    /// answer that was never about it.
    func syncSessionFlags(botID: String) async {
        let store = SessionVerbStore.shared
        store.noteGateway()
        guard mode == .live, !isOffline, let (base, credential) = gatewayRESTContext() else {
            return
        }
        do {
            let rows = try await GatewayREST.sessionFlags(baseURL: base, credential: credential,
                                                          profile: botID)
            store.supported = true
            store.adoptServerPins(Set(rows.filter(\.value.pinned).map(\.key)),
                                  seen: Set(rows.keys), botID: botID)
        } catch {
            noteFlagsRoute(error)
        }
    }

    /// A 404/405 from the flags routes means this gateway predates them; hide
    /// the verbs rather than showing buttons that answer with an error the user
    /// cannot act on. Anything else (a dropped link, a 500) is transient and
    /// leaves the surface alone.
    private func noteFlagsRoute(_ error: Error) {
        guard let gateway = error as? GatewayError else { return }
        if gateway.code == 404 || gateway.code == 405 || gateway.code == 501 {
            SessionVerbStore.shared.supported = false
        }
    }

    /// Copy the durable session key — the id every gateway RPC, the CLI's
    /// `--continue` and the desktop's own row menu speak.
    func copySessionID(_ sessionID: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = sessionID
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sessionID, forType: .string)
        #endif
    }

    /// Whole transcript as JSON, staged as a file for the share sheet
    /// (`GET /api/sessions/{id}/export`, web_routers/sessions.py:735 — metadata
    /// plus every message, keyset-paginated server-side).
    func exportStoredSession(_ sessionID: String, botID: String,
                             title: String) async -> SessionExport {
        guard mode == .live, !isOffline else {
            return .failed(theme.copy.sessUnreachable(theme.themeID))
        }
        guard let (base, credential) = gatewayRESTContext() else {
            return .failed(theme.copy.needsRESTNote(theme.themeID))
        }
        do {
            let data = try await GatewayREST.exportSession(baseURL: base, credential: credential,
                                                           sessionID: sessionID, profile: botID)
            let name = Self.exportFilename(title: title, sessionID: sessionID)
            return .ready(try TalariaExportBox.write(data, named: name))
        } catch {
            return .failed(Self.sessionFailure(error, theme: theme))
        }
    }

    /// "morning-triage-4f1c8b.json" — the session's own name where it has one,
    /// always suffixed with the key so two exports never collide.
    static func exportFilename(title: String, sessionID: String) -> String {
        let cleaned = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let slug = String(cleaned).split(separator: "-").joined(separator: "-")
        let stem = slug.isEmpty ? "session" : String(slug.prefix(48))
        return stem + "-" + String(sessionID.prefix(8)) + ".json"
    }
}

// MARK: - REST (durable-key session routes)

/// A staged transcript export, or why there is none.
public enum SessionExport: Sendable {
    case ready(URL)
    case failed(String)
}

/// One session row's durable flags, as the REST listing reports them.
public struct SessionRowFlags: Sendable, Equatable {
    public var pinned: Bool
    public var archived: Bool
}

public extension GatewayREST {

    /// `PATCH /api/sessions/{id}` (web_routers/sessions.py:685) — title, pin,
    /// archive and read-state on the DURABLE key. The WS `session.title` RPC
    /// only resolves runtime sids, and there is no WS pin/archive at all, so
    /// this is the only door for a row nobody has resumed.
    static func patchSession(baseURL: URL, credential: GatewayCredential, sessionID: String,
                             profile: String?, pinned: Bool? = nil,
                             archived: Bool? = nil) async throws {
        var payload: [String: JSONValue] = [:]
        if let pinned { payload["pinned"] = .bool(pinned) }
        if let archived { payload["archived"] = .bool(archived) }
        if let profile, !profile.isEmpty { payload["profile"] = .string(profile) }
        guard payload["pinned"] != nil || payload["archived"] != nil else { return }
        let body = try JSONEncoder().encode(JSONValue.object(payload))
        _ = try await restJSON(baseURL: baseURL, credential: credential,
                               path: "api/sessions/\(sessionID)", method: "PATCH",
                               body: body, what: "session")
    }

    /// `GET /api/sessions/{id}/export` (web_routers/sessions.py:735) — the
    /// session's metadata and its whole transcript, streamed as one JSON
    /// document. A big conversation is genuinely big, hence the long timeout.
    static func exportSession(baseURL: URL, credential: GatewayCredential, sessionID: String,
                              profile: String?) async throws -> Data {
        var query: [URLQueryItem] = []
        if let profile, !profile.isEmpty {
            query.append(URLQueryItem(name: "profile", value: profile))
        }
        return try await restData(baseURL: baseURL, credential: credential,
                                  path: "api/sessions/\(sessionID)/export",
                                  query: query, timeout: 120, what: "export")
    }

    /// `GET /api/sessions` (web_routers/sessions.py:53) — the only listing that
    /// reports the durable `pinned`/`archived` booleans.
    ///
    /// It cannot see hidden rows (`list_sessions_rich` defaults
    /// `include_hidden=False`, hermes_state.py:8768) and Bot Mode sessions are
    /// always hidden, so callers must treat this as "the flags for the rows it
    /// DID return" and never as the complete picture.
    static func sessionFlags(baseURL: URL, credential: GatewayCredential, profile: String?,
                             limit: Int = 100) async throws -> [String: SessionRowFlags] {
        var query = [URLQueryItem(name: "limit", value: String(min(limit, 100))),
                     URLQueryItem(name: "archived", value: "include"),
                     URLQueryItem(name: "order", value: "recent")]
        if let profile, !profile.isEmpty {
            query.append(URLQueryItem(name: "profile", value: profile))
        }
        let payload = try await restJSON(baseURL: baseURL, credential: credential,
                                         path: "api/sessions", query: query, what: "sessions")
        var out: [String: SessionRowFlags] = [:]
        for row in payload["sessions"]?.arrayValue ?? [] {
            guard let id = row["id"]?.stringValue, !id.isEmpty else { continue }
            out[id] = SessionRowFlags(pinned: row["pinned"]?.boolValue ?? false,
                                      archived: row["archived"]?.boolValue ?? false)
        }
        return out
    }
}

// MARK: - Sessions copy (three voices, same shape as CopyPack proper)

extension CopyPack {
    func sessKicker(_ t: ThemeID) -> String {
        switch t {
        case .soft: "KEPT ON THE GATEWAY"
        case .control: "SESSION STORE"
        case .ink: "WRITTEN IN THE HOUSE"
        }
    }

    func sessSearchPlaceholder(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Search titles and transcripts…"
        case .control: "QUERY TITLES / TRANSCRIPTS…"
        case .ink: "seek among the audiences…"
        }
    }

    func sessEmpty(_ t: ThemeID) -> String {
        switch t {
        case .soft: "No stored sessions yet. Say something and this bot's first conversation lands here."
        case .control: "NO STORED SESSIONS. FIRST TRANSMISSION CREATES ONE."
        case .ink: "Nothing is written here yet. Speak, and the first audience is recorded."
        }
    }

    func sessNoMatches(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Nothing matches that."
        case .control: "NO MATCHES."
        case .ink: "Nothing of that name is written here."
        }
    }

    func sessFullText(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Found in transcripts"
        case .control: "TRANSCRIPT MATCHES"
        case .ink: "FOUND WITHIN THE TEXT"
        }
    }

    func sessMessages(_ t: ThemeID) -> String {
        switch t {
        case .soft: "msgs"
        case .control: "MSG"
        case .ink: "exchanges"
        }
    }

    /// Teaches the gesture vocabulary that is actually on this build — archive
    /// only appears when the gateway can do it.
    func sessFootnote(_ t: ThemeID, canArchive: Bool) -> String {
        switch (t, canArchive) {
        case (.soft, true):
            return "Swipe a session to archive or rename it. Press and hold for pin, export and delete. Tap to pick up where it left off."
        case (.soft, false):
            return "Swipe a session to rename or delete it. Press and hold for export. Tap to pick up where it left off."
        case (.control, true):
            return "SWIPE: ARCHIVE / RENAME. HOLD: PIN · EXPORT · DELETE. TAP TO REATTACH."
        case (.control, false):
            return "SWIPE: RENAME / DELETE. HOLD: EXPORT. TAP TO REATTACH."
        case (.ink, true):
            return "Draw a row aside to set it by or rename it; hold it for the pin, a copy, or to strike it out. Touch one to resume that audience."
        case (.ink, false):
            return "Draw a row aside to rename or strike it out; hold it to take a copy. Touch one to resume that audience."
        }
    }

    func sessWorking(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Working…"
        case .control: "EXECUTING…"
        case .ink: "the work is under way…"
        }
    }

    func sessRename(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Rename"
        case .control: "RENAME"
        case .ink: "rename"
        }
    }

    func sessDelete(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Delete"
        case .control: "DELETE"
        case .ink: "strike out"
        }
    }

    func sessPin(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Pin to top"
        case .control: "PIN"
        case .ink: "keep it foremost"
        }
    }

    func sessUnpin(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Unpin"
        case .control: "UNPIN"
        case .ink: "let it fall back"
        }
    }

    func sessArchive(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Archive"
        case .control: "ARCHIVE"
        case .ink: "set it by"
        }
    }

    func sessArchived(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Archived — restore it from the section below."
        case .control: "ARCHIVED — RESTORABLE BELOW."
        case .ink: "Set by; it may be called back from below."
        }
    }

    func sessArchivedSection(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Archived"
        case .control: "ARCHIVED"
        case .ink: "SET ASIDE"
        }
    }

    func sessRestore(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Restore"
        case .control: "RESTORE"
        case .ink: "call it back"
        }
    }

    func sessCopyID(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Copy session id"
        case .control: "COPY SESSION ID"
        case .ink: "copy its mark"
        }
    }

    /// The row-level export: the transcript itself, on this phone.
    func sessShare(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Share transcript…"
        case .control: "EXPORT TRANSCRIPT"
        case .ink: "carry the record away"
        }
    }

    func sessShared(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Transcript written"
        case .control: "TRANSCRIPT WRITTEN"
        case .ink: "The record is copied out"
        }
    }

    func sessRenameTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Rename session"
        case .control: "RENAME SESSION"
        case .ink: "Rename this audience"
        }
    }

    func sessRenamePlaceholder(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Session title"
        case .control: "TITLE"
        case .ink: "its title"
        }
    }

    func sessRenameOK(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Rename"
        case .control: "SET"
        case .ink: "inscribe"
        }
    }

    func sessRenameEmpty(_ t: ThemeID) -> String {
        switch t {
        case .soft: "A session needs a title."
        case .control: "TITLE REQUIRED."
        case .ink: "It must be given a name."
        }
    }

    func sessBranch(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Branch this session"
        case .control: "BRANCH"
        case .ink: "fork this audience"
        }
    }

    func sessCompress(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Compress context"
        case .control: "COMPRESS CONTEXT"
        case .ink: "distil the vessel"
        }
    }

    func sessExport(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Snapshot on the gateway"
        case .control: "SNAPSHOT ON HOST"
        case .ink: "seal a copy in the house"
        }
    }

    func sessBranched(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Branched — the fork is in the list below."
        case .control: "BRANCHED — FORK ADDED TO STORE."
        case .ink: "Forked; the new audience is written below."
        }
    }

    func sessExported(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Snapshot written on the gateway"
        case .control: "SNAPSHOT WRITTEN ON GATEWAY HOST"
        case .ink: "A copy is sealed in the house"
        }
    }

    func sessNoLiveSession(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Open this bot's chat first — these act on a live session."
        case .control: "NO LIVE SESSION — ATTACH BEFORE ISSUING CONTROLS."
        case .ink: "No audience is in progress; open one first."
        }
    }

    func sessDeleteLive(_ t: ThemeID) -> String {
        switch t {
        case .soft: "That session is still running. Stop the turn, then delete it."
        case .control: "SESSION LIVE — INTERRUPT BEFORE DELETE."
        case .ink: "It is still at work; you cannot strike it out yet."
        }
    }

    func sessUnreachable(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Sessions live on the gateway — reconnect to read them."
        case .control: "LINK DOWN — SESSION STORE UNREACHABLE."
        case .ink: "The way is severed; the past audiences cannot be read."
        }
    }

    func sessFailed(_ t: ThemeID) -> String {
        switch t {
        case .soft: "The gateway refused that."
        case .control: "GATEWAY REFUSED."
        case .ink: "The house would not have it."
        }
    }
}
