import SwiftUI
import TalariaKit
import TalariaTheme
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Mobile-first threaded room timeline. The newest thread opens by default;
/// older topics collapse to summaries and keep their own reply composer.
public struct RoomView: View {
    private let model: AppModel
    public let roomID: RoomID
    @State private var expanded = Set<RoomThreadID>()
    @State private var collapsed = Set<RoomThreadID>()
    @State private var activityOpen = false
    @State private var confirmDisband = false
    @State private var abandonAttemptID: RoomAttemptID?
    @State private var showSettings = false
    @State private var disbanding = false
    @State private var error: String?

    public init(model: AppModel, roomID: RoomID) {
        self.model = model; self.roomID = roomID
    }

    private var theme: ThemePack { model.theme.pack }
    private var room: RoomRecord? { model.room(roomID) }
    private var newestThreadID: RoomThreadID? {
        room?.threads.max(by: { $0.lastActivityAt < $1.lastActivityAt })?.id
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if let room {
                if let error {
                    Text(error).font(theme.body(11)).foregroundStyle(theme.danger)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.roomMetadataPendingCount > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("\(model.roomMetadataPendingCount) membership update\(model.roomMetadataPendingCount == 1 ? "" : "s") waiting for a gateway")
                            .lineLimit(2)
                        Spacer()
                        Button("Retry") { Task { await model.flushRoomMetadataOutbox() } }
                            .buttonStyle(.plain).font(theme.body(10, weight: .semibold))
                            .frame(minHeight: 44)
                    }
                    .font(theme.body(10)).foregroundStyle(theme.warn)
                    .padding(.horizontal, 14).background(theme.warn.opacity(0.06))
                }
                pendingPromptPanel(room)
                unresolvedPanel(room)
                activityPanel(room)
                timeline(room)
                let liveMembers = room.members.filter { !$0.isFrozenProjection }
                if liveMembers.isEmpty {
                    frozenRoomNotice
                        .padding(10).background(theme.bg)
                        .overlay(alignment: .top) {
                            Rectangle().fill(theme.line).frame(height: 1)
                        }
                } else {
                    RoomComposer(theme: theme, members: liveMembers,
                                 placeholder: "New thread in \(room.name)…",
                                 submitLabel: "New Thread",
                                 draft: Binding(
                                     get: { model.roomComposerDraft(roomID) },
                                     set: { model.updateRoomComposerDraft($0, roomID: roomID) }
                                 ),
                                 draftPersistenceError: model.roomComposerDraftError(roomID)
                    ) { text, attachments in
                        _ = try await model.sendRoomMessage(roomID: roomID, text: text,
                                                            attachments: attachments)
                        try await model.clearRoomComposerDraftAfterSend(
                            roomID, submitted: text)
                    }
                    .padding(10).background(theme.bg)
                    .overlay(alignment: .top) {
                        Rectangle().fill(theme.line).frame(height: 1)
                    }
                }
            } else {
                ContentUnavailableView("Room unavailable", systemImage: "person.3",
                                       description: Text("It may have been disbanded on this device."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.bg)
        .task {
            await model.loadRooms()
            await model.loadRoomComposerDraft(roomID)
            model.reconcileRoom(roomID)
        }
        .confirmationDialog("Disband this room?", isPresented: $confirmDisband,
                            titleVisibility: .visible) {
            Button("Disband", role: .destructive, action: disband)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The local room log and attachments are removed. Member sessions stay in Hermes.")
        }
        .alert("Mark this turn as not sent?", isPresented: Binding(
            get: { abandonAttemptID != nil },
            set: { if !$0 { abandonAttemptID = nil } }
        )) {
            Button("Keep checking", role: .cancel) { abandonAttemptID = nil }
            Button("Mark Not Sent", role: .destructive) {
                guard let attemptID = abandonAttemptID else { return }
                abandonAttemptID = nil
                Task { await model.abandonRoomAttempt(roomID: roomID, attemptID: attemptID) }
            }
        } message: {
            Text("Only do this after checking the owning Hermes session. Talaria will never retry an unconfirmed turn automatically.")
        }
        .sheet(isPresented: $showSettings) {
            if let room { RoomSettingsView(model: model, room: room) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { model.openRoomID = nil } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }.buttonStyle(.plain).foregroundStyle(theme.accent)
            if let room {
                RoomAvatarView(room: room, theme: theme,
                               data: model.roomAvatarData(room.id), size: 38)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(room?.name ?? "Room").font(theme.body(16, weight: .bold))
                    .foregroundStyle(theme.ink).lineLimit(1)
                Text(room.map { value in
                    value.members.prefix(3).map {
                        "@\($0.handle)" + ($0.sourceLabel.map { "-\($0)" } ?? "")
                    }.joined(separator: " · ")
                } ?? "")
                    .font(theme.mono(9)).foregroundStyle(theme.faint)
            }
            Spacer()
            if room != nil {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").frame(width: 44, height: 44)
                }.buttonStyle(.plain).foregroundStyle(theme.faint)
                Button { confirmDisband = true } label: {
                    Image(systemName: "trash").frame(width: 44, height: 44)
                }.buttonStyle(.plain).foregroundStyle(theme.danger).disabled(disbanding)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line).frame(height: 1) }
    }

    @ViewBuilder private func activityPanel(_ room: RoomRecord) -> some View {
        let current = room.activity.filter { $0.epoch == room.epoch }
        if !current.isEmpty {
            DisclosureGroup(isExpanded: $activityOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(current) { event in
                        HStack(spacing: 6) {
                            Circle().fill(activityColor(event.kind)).frame(width: 6, height: 6)
                            Text(activityText(event, room: room)).font(theme.body(10))
                                .foregroundStyle(theme.faint)
                        }
                    }
                }.padding(.top, 6)
            } label: {
                HStack(spacing: 6) {
                    if !room.drives.isEmpty { ProgressView().controlSize(.mini) }
                    Text(room.drives.isEmpty ? "Latest run" : "Room is working")
                        .font(theme.body(11, weight: .semibold)).foregroundStyle(theme.faint)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(theme.ink.opacity(0.025))
        }
    }

    @ViewBuilder private func unresolvedPanel(_ room: RoomRecord) -> some View {
        let unresolved = RoomDeliveryPolicy.unresolvedAttempts(in: room)
        if !unresolved.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Delivery needs confirmation")
                    .font(theme.body(12, weight: .bold)).foregroundStyle(theme.warn)
                Text("Talaria cannot prove whether these turns reached Hermes. They will not be sent again automatically.")
                    .font(theme.body(10)).foregroundStyle(theme.faint)
                ForEach(unresolved) { attempt in
                    HStack(spacing: 8) {
                        let members = room.members + room.formerMembers
                        let member = members.first { $0.route == attempt.member }
                        Text("@\(member?.handle ?? attempt.member.profile)")
                            .font(theme.mono(10, weight: .semibold)).foregroundStyle(theme.ink)
                        Spacer()
                        Button("Check Again") { model.reconcileRoom(roomID) }
                            .buttonStyle(.plain).font(theme.body(10, weight: .semibold))
                            .frame(minHeight: 44).foregroundStyle(theme.accent)
                        Button("Mark Not Sent") { abandonAttemptID = attempt.id }
                            .buttonStyle(.plain).font(theme.body(10, weight: .semibold))
                            .frame(minHeight: 44).foregroundStyle(theme.danger)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(theme.warn.opacity(0.08))
            .overlay(alignment: .bottom) { Rectangle().fill(theme.warn.opacity(0.3)).frame(height: 1) }
        }
    }

    /// A Hermes tool/clarify block is live session state, not a transcript
    /// mention. Keep it visually distinct from delivery uncertainty so the
    /// `needsUser` badge remains reserved for an explicit `@user` message.
    @ViewBuilder private func pendingPromptPanel(_ room: RoomRecord) -> some View {
        let prompts = model.roomPendingPrompts(room.id)
        if !prompts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(prompts.count == 1 ? "Waiting for your answer" : "Waiting for your answers")
                    .font(theme.body(12, weight: .bold)).foregroundStyle(theme.accent)
                Text("A room member is paused in Hermes. Your response stays on that member's source gateway.")
                    .font(theme.body(10)).foregroundStyle(theme.faint)
                ForEach(prompts, id: \.attemptID) { prompt in
                    let member = (room.members + room.formerMembers)
                        .first(where: { $0.route == prompt.route })
                    RoomPendingPromptCard(prompt: prompt, member: member, theme: theme) { answers in
                        try await model.respondToRoomPendingPrompt(prompt, answers: answers)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(theme.accent.opacity(0.055))
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.accent.opacity(0.22)).frame(height: 1)
            }
        }
    }

    private func timeline(_ room: RoomRecord) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if room.entries.isEmpty {
                        Text("Say something — every bot in this room hears the thread.")
                            .font(theme.body(13)).foregroundStyle(theme.faint)
                            .frame(maxWidth: .infinity).padding(.top, 50)
                    }
                    ForEach(sortedThreads(room)) { thread in
                        threadBlock(thread, room: room).id(thread.id.rawValue)
                    }
                    Color.clear.frame(height: 1).id("room-bottom")
                }.padding(12)
            }
            .onChange(of: room.entries.count) { _, _ in
                withAnimation { proxy.scrollTo("room-bottom", anchor: .bottom) }
            }
        }
    }

    private func sortedThreads(_ room: RoomRecord) -> [RoomThread] {
        room.threads.sorted { $0.lastActivityAt < $1.lastActivityAt }
    }

    private var frozenRoomNotice: some View {
        Label("View only — connect an exact source gateway to reply",
              systemImage: "lock")
            .font(theme.body(11, weight: .semibold))
            .foregroundStyle(theme.faint)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    @ViewBuilder private func threadBlock(_ thread: RoomThread, room: RoomRecord) -> some View {
        let entries = room.entries.filter { $0.threadID == thread.id }
        let isExpanded = !collapsed.contains(thread.id)
            && (expanded.contains(thread.id) || thread.id == newestThreadID)
        if isExpanded {
            VStack(alignment: .leading, spacing: 7) {
                Button {
                    expanded.remove(thread.id); collapsed.insert(thread.id)
                } label: {
                    Label("Collapse thread", systemImage: "chevron.down")
                        .font(theme.body(10)).foregroundStyle(theme.faint)
                }.buttonStyle(.plain)
                ForEach(entries) { entry in entryRow(entry, room: room) }
                let liveMembers = room.members.filter { !$0.isFrozenProjection }
                if liveMembers.isEmpty {
                    frozenRoomNotice.padding(.top, 3)
                } else {
                    RoomComposer(theme: theme, members: liveMembers,
                                 placeholder: "Reply in thread…", submitLabel: "Reply") { text, attachments in
                        _ = try await model.sendRoomMessage(roomID: roomID, text: text,
                                                            threadID: thread.id,
                                                            attachments: attachments)
                    }
                    .padding(.top, 3)
                }
            }
            .padding(9).background(theme.ink.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .leading) { Rectangle().fill(theme.accent.opacity(0.4)).frame(width: 2) }
        } else {
            Button { collapsed.remove(thread.id); expanded.insert(thread.id) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                    Text(threadSummary(entries)).lineLimit(1)
                    Spacer()
                    Text("\(max(0, entries.count - 1)) replies").font(theme.mono(9))
                }
                .font(theme.body(11)).foregroundStyle(theme.faint).padding(9)
                .background(theme.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain)
        }
    }

    private func entryRow(_ entry: RoomEntry, room: RoomRecord) -> some View {
        let user = entry.speaker == .user
        return HStack(alignment: .top, spacing: 8) {
            if !user {
                Circle().fill(theme.accent.opacity(0.16)).frame(width: 28, height: 28)
                    .overlay(Text(String(entry.speakerName.prefix(1))).font(theme.body(11, weight: .bold)))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(entry.speakerName).font(theme.body(11, weight: .bold))
                        .foregroundStyle(user ? theme.ink : theme.accent)
                    if let route = entry.memberRoute {
                        let identity = (room.members + room.formerMembers)
                            .first(where: { $0.route == route })
                        Text("@\(identity?.handle ?? route.profile)"
                             + ((identity?.sourceLabel ?? entry.sourceLabel).map { " · \($0)" } ?? ""))
                            .font(theme.mono(8)).foregroundStyle(theme.faint).lineLimit(1)
                    }
                    Spacer()
                    Text(entry.at, style: .time).font(theme.mono(8)).foregroundStyle(theme.faint)
                }
                if !entry.text.isEmpty {
                    MarkdownText(entry.text, theme: theme, size: 13, color: theme.ink)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if !entry.attachments.isEmpty { attachmentChips(entry.attachments) }
            }
        }
        .padding(user ? 8 : 2)
        .background(user ? theme.ink.opacity(0.045) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9))
    }

    private func attachmentChips(_ attachments: [RoomAttachment]) -> some View {
        FlowLayout(spacing: 5) {
            ForEach(attachments) { attachment in
                RoomAttachmentPreview(roomID: roomID, attachment: attachment, theme: theme)
            }
        }
    }

    private func threadSummary(_ entries: [RoomEntry]) -> String {
        let head = entries.first(where: { $0.speaker == .user }) ?? entries.first
        let text = head?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "Thread" : text
    }

    private func activityText(_ activity: RoomActivity, room: RoomRecord) -> String {
        let member = activity.member.flatMap { route in
            (room.members + room.formerMembers).first(where: { $0.route == route })?.title
                ?? route.profile
        }
        return [member, activity.kind.rawValue].compactMap { $0 }.joined(separator: " · ")
    }

    private func activityColor(_ kind: RoomActivityKind) -> Color {
        switch kind {
        case .replied, .delivered, .settled: theme.ok
        case .failed, .timedOut, .cancelled: theme.danger
        case .uncertain: theme.warn
        default: theme.accent
        }
    }

    private func disband() {
        disbanding = true; error = nil
        Task { @MainActor in
            do { try await model.disbandRoom(roomID) }
            catch { self.error = error.localizedDescription }
            disbanding = false
        }
    }
}

private struct RoomSettingsView: View {
    let model: AppModel
    let room: RoomRecord
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var selected: [RoomMember]
    @State private var avatarPayload: RoomOutboundAttachment?
    @State private var removeAvatar = false
    @State private var saving = false
    @State private var error: String?
    #if canImport(PhotosUI)
    @State private var photo: PhotosPickerItem?
    #endif

    init(model: AppModel, room: RoomRecord) {
        self.model = model; self.room = room
        _name = State(initialValue: room.name)
        _selected = State(initialValue: room.members)
    }

    private var theme: ThemePack { model.theme.pack }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    RoomAvatarView(room: room, theme: theme,
                                   data: avatarPayload?.data ?? model.roomAvatarData(room.id), size: 58)
                    VStack(alignment: .leading, spacing: 4) {
                        #if canImport(PhotosUI)
                        PhotosPicker("Choose room image", selection: $photo, matching: .images)
                            .onChange(of: photo) { _, value in loadPhoto(value) }
                        #endif
                        if room.avatar != nil || avatarPayload != nil {
                            Button("Use member faces", role: .destructive) {
                                avatarPayload = nil; removeAvatar = true
                            }
                        }
                    }.font(theme.body(12, weight: .semibold))
                }.frame(maxWidth: .infinity, alignment: .leading)

                TextField("Room name", text: $name).textFieldStyle(.plain)
                    .font(theme.body(15, weight: .semibold)).padding(12)
                    .background(theme.ink.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                HStack {
                    Text("Members").font(theme.body(12, weight: .semibold))
                    Spacer(); Text("\(selected.count)/6").font(theme.mono(10))
                }.foregroundStyle(theme.faint)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(unavailableMembers) { member in
                            unavailableMemberRow(member)
                        }
                        ForEach(model.unionRosterBots) { bot in
                            let route = model.gatewayRoute(for: bot.id)
                            let checked = route.map { value in selected.contains { $0.route == value } } ?? false
                            let cannotAdd = !checked && selected.count >= RoomEngine.maximumMembers
                            Button {
                                guard let route else { return }
                                if checked {
                                    if selected.count > RoomEngine.minimumMembers {
                                        selected.removeAll { $0.route == route }
                                    }
                                } else if !cannotAdd {
                                    selected.append(model.capturedRoomMember(
                                        for: bot, route: route,
                                        sourceLabel: bot.remoteSource?.connectionLabel
                                            ?? model.activeConnectionLabel))
                                }
                            } label: {
                                HStack(spacing: 9) {
                                    AvatarView(bot: bot, size: 32, theme: theme)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(TalariaVoice.displayName(for: bot, model.theme.themeID))
                                        Text("@\(bot.handle)" + (bot.remoteSource.map { " · \($0.connectionLabel)" } ?? ""))
                                            .font(theme.mono(8)).foregroundStyle(theme.faint)
                                    }
                                    Spacer()
                                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(checked ? theme.accent : theme.faint)
                                }.frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(cannotAdd)
                        }
                    }
                }
                if let error { Text(error).font(theme.body(11)).foregroundStyle(theme.danger) }
            }
            .padding(16).background(theme.bg).navigationTitle("Room Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save", action: save).disabled(saving || selected.count < 2)
                }
            }
        }
    }

    #if canImport(PhotosUI)
    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task { @MainActor in
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let shaped = AttachmentEncoder.gatewayImage(from: data, filename: "room.heic") else { return }
            let portrait = AttachmentEncoder.thumbnail(from: shaped.data, maxPixel: 512) ?? shaped.data
            avatarPayload = RoomOutboundAttachment(kind: .image, name: "room.jpg", data: portrait)
            removeAvatar = false; photo = nil
        }
    }
    #endif

    private func save() {
        saving = true; error = nil
        Task { @MainActor in
            do {
                try await model.updateRoomSettings(room.id, name: name,
                                                   members: selected,
                                                   avatar: avatarPayload,
                                                   removeAvatar: removeAvatar)
                dismiss()
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }

    private var unavailableMembers: [RoomMember] {
        let visible = Set(model.unionRosterBots.compactMap { model.gatewayRoute(for: $0.id) })
        return selected.filter { !visible.contains($0.route) }
    }

    private func unavailableMemberRow(_ member: RoomMember) -> some View {
        HStack(spacing: 9) {
            Circle().fill(theme.faint.opacity(0.15)).frame(width: 32, height: 32)
                .overlay(Image(systemName: member.isFrozenProjection ? "lock" : "moon.zzz")
                    .font(.system(size: 11)).foregroundStyle(theme.faint))
            VStack(alignment: .leading, spacing: 1) {
                Text(member.title ?? member.route.profile)
                Text("@\(member.handle) · \(member.sourceLabel ?? member.route.gatewayID) · \(member.isFrozenProjection ? "shared · view only" : "offline")")
                    .font(theme.mono(8)).foregroundStyle(theme.faint)
            }
            Spacer()
            if member.isFrozenProjection {
                Image(systemName: "lock.fill")
                    .frame(width: 44, height: 44)
                    .foregroundStyle(theme.faint)
                    .accessibilityLabel("Shared member is view only")
            } else {
                Button {
                    if selected.count > RoomEngine.minimumMembers {
                        selected.removeAll { $0.route == member.route }
                    }
                } label: { Image(systemName: "minus.circle").frame(width: 44, height: 44) }
                    .buttonStyle(.plain).foregroundStyle(theme.danger)
            }
        }.frame(minHeight: 44)
    }
}

/// Tiny wrapping layout for attachment chips; avoids a horizontal scroller in
/// already narrow thread rails.
private struct FlowLayout: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing; row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += row + spacing; row = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                       proposal: ProposedViewSize(size))
            x += size.width + spacing; row = max(row, size.height)
        }
    }
}

/// One share-sheet export with a real filename. Sharing `Data` makes the
/// activity controller invent an opaque name and generic content type; a file
/// URL lets Files, Mail, AirDrop, and document providers retain both.
struct RoomAttachmentExport: Equatable {
    static let directoryPrefix = "talaria-room-share-"

    let fileURL: URL
    let directoryURL: URL

    static func prepare(data: Data, fileName: String, mediaType: String,
                        baseDirectory: URL = FileManager.default.temporaryDirectory) throws -> Self {
        let directory = baseDirectory.appendingPathComponent(
            directoryPrefix + UUID().uuidString.lowercased(), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(
                sanitizedFileName(fileName, mediaType: mediaType), isDirectory: false)
            try data.write(to: target, options: .atomic)
            return Self(fileURL: target, directoryURL: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func sanitizedFileName(_ proposed: String, mediaType: String) -> String {
        // Treat both POSIX and Windows separators as hostile. `lastPathComponent`
        // alone does not strip a backslash on Apple platforms.
        let leaf = proposed.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        let cleaned = String(leaf.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet(charactersIn: ":").contains(scalar) { return "-" }
            return Character(String(scalar))
        }).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ".")))
        var name = cleaned.isEmpty ? "attachment" : String(cleaned.prefix(160))

        #if canImport(UniformTypeIdentifiers)
        if let declared = UTType(mimeType: mediaType),
           let preferred = preferredExtension(for: mediaType, declared: declared) {
            let currentExtension = URL(fileURLWithPath: name).pathExtension
            let current = currentExtension.isEmpty ? nil : UTType(filenameExtension: currentExtension)
            let matches = currentExtension.caseInsensitiveCompare(preferred) == .orderedSame
                || (current.map { $0.conforms(to: declared) || declared.conforms(to: $0) } ?? false)
            if !matches {
                let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
                name = (stem.isEmpty ? "attachment" : stem) + "." + preferred
            }
        }
        #endif
        return name
    }

    #if canImport(UniformTypeIdentifiers)
    private static func preferredExtension(for mediaType: String, declared: UTType) -> String? {
        // Some macOS SDKs expose a dynamic MIME type whose preferred extension
        // is nil. Keep the common mobile attachment types deterministic, then
        // defer to the system registry for everything else.
        switch mediaType.lowercased() {
        case "application/pdf": "pdf"
        case "image/png": "png"
        case "image/jpeg": "jpg"
        case "image/heic": "heic"
        case "text/plain": "txt"
        default: declared == .data ? nil : declared.preferredFilenameExtension
        }
    }
    #endif

    func remove() {
        guard directoryURL.lastPathComponent.hasPrefix(Self.directoryPrefix) else { return }
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private struct RoomAttachmentPreview: View {
    let roomID: RoomID
    let attachment: RoomAttachment
    let theme: ThemePack
    @State private var data: Data?
    @State private var export: RoomAttachmentExport?
    @State private var isPresented = false
    @State private var loadError: String?

    var body: some View {
        Button {
            isPresented = true
            Task {
                await loadData()
                await prepareExport()
            }
        } label: {
            Group {
                if attachment.mediaType.hasPrefix("image/"),
                   let data, let image = platformImage(data) {
                    image.resizable().scaledToFill().frame(width: 112, height: 82)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line, lineWidth: 1))
                } else {
                    Label(attachment.fileName,
                          systemImage: attachment.mediaType == "application/pdf" ? "doc.richtext" : "doc")
                        .font(theme.body(9)).foregroundStyle(theme.faint).lineLimit(1)
                        .padding(.horizontal, 7).padding(.vertical, 5)
                        .background(theme.ink.opacity(0.055), in: Capsule())
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(attachment.fileName)")
        .task {
            if attachment.mediaType.hasPrefix("image/") {
                await loadData()
            }
        }
        .sheet(isPresented: $isPresented, onDismiss: removeExport) {
            NavigationStack {
                VStack(spacing: 18) {
                    if attachment.mediaType.hasPrefix("image/"),
                       let data, let image = platformImage(data) {
                        image.resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 420)
                    } else {
                        Image(systemName: attachment.mediaType == "application/pdf"
                              ? "doc.richtext" : "doc")
                            .font(.system(size: 54)).foregroundStyle(theme.faint)
                    }
                    Text(attachment.fileName).font(theme.body(14, weight: .semibold))
                        .foregroundStyle(theme.ink).multilineTextAlignment(.center)
                    Text(ByteCountFormatter.string(fromByteCount: attachment.byteCount,
                                                   countStyle: .file))
                        .font(theme.mono(10)).foregroundStyle(theme.faint)
                    if let export {
                        ShareLink(item: export.fileURL,
                                  preview: SharePreview(export.fileURL.lastPathComponent)) {
                            Label("Share or Save", systemImage: "square.and.arrow.up")
                                .frame(minHeight: 44)
                        }
                    } else if let loadError {
                        Text(loadError).font(theme.body(11)).foregroundStyle(theme.danger)
                    } else {
                        ProgressView()
                    }
                    Spacer()
                }
                .padding(20).background(theme.bg)
                .onDisappear(perform: removeExport)
                .navigationTitle("Attachment")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isPresented = false }
                    }
                }
            }
        }
        .onDisappear(perform: removeExport)
    }

    @MainActor private func loadData() async {
        guard data == nil else { return }
        do {
            data = try await RoomStore.shared.readBlob(roomID: roomID, attachment: attachment)
            loadError = nil
        } catch { loadError = error.localizedDescription }
    }

    @MainActor private func prepareExport() async {
        guard isPresented, export == nil, let data else { return }
        do {
            export = try RoomAttachmentExport.prepare(
                data: data, fileName: attachment.fileName, mediaType: attachment.mediaType)
            loadError = nil
        } catch { loadError = error.localizedDescription }
    }

    private func removeExport() {
        export?.remove()
        export = nil
    }

    private func platformImage(_ data: Data) -> Image? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        return nil
        #endif
    }
}
