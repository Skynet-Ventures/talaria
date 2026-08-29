import SwiftUI
import TalariaKit
import TalariaTheme

#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Room records predate the shared Bot Mode grammar and retain dotted legacy
/// handles (for example `research.lead`). The room parser still accepts them,
/// so completion has a deliberately local trailing-token scanner rather than
/// borrowing `BotMention.activeToken`, whose global grammar correctly rejects
/// dots. Keeping this exception here prevents a room from offering an alias
/// that cannot be edited after its first dot.
private enum RoomMentionCompletion {
    static func activeToken(in text: String) -> (range: Range<String.Index>, token: String)? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at != text.startIndex,
           !text[text.index(before: at)].isWhitespace {
            return nil
        }
        let body = text[text.index(after: at)...]
        guard body.allSatisfy(isRoomHandleBody) else { return nil }
        if let first = body.first, !(first.isASCII && (first.isLetter || first.isNumber)) {
            return nil
        }
        return (at..<text.endIndex, body.lowercased())
    }

    private static func isRoomHandleBody(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber
            || character == "." || character == "_" || character == "-")
    }
}

/// Full-width mobile room composer. Attachments stay visible until the async
/// send has durably appended the user entry; a failed send never clears the
/// draft or loses the bytes needed for retry.
public struct RoomComposer: View {
    public let theme: ThemePack
    public let members: [RoomMember]
    public let placeholder: String
    public let submitLabel: String
    public let draftPersistenceError: String?
    public let onSubmit: (String, [RoomOutboundAttachment]) async throws -> Void

    private let externalDraft: Binding<String>?
    @State private var localDraft = ""
    @State private var attachments: [RoomOutboundAttachment] = []
    @State private var sending = false
    @State private var error: String?
    @State private var showAttachmentSources = false
    @State private var pendingAttachmentSource: AttachmentSourceAction?
    @State private var showFiles = false
    @State private var showPhotos = false
    @FocusState private var focused: Bool
    #if canImport(PhotosUI)
    @State private var photoItems: [PhotosPickerItem] = []
    #endif

    public init(theme: ThemePack, members: [RoomMember], placeholder: String,
                submitLabel: String = "Send",
                draft: Binding<String>? = nil,
                draftPersistenceError: String? = nil,
                onSubmit: @escaping (String, [RoomOutboundAttachment]) async throws -> Void) {
        self.theme = theme; self.members = members; self.placeholder = placeholder
        self.submitLabel = submitLabel; externalDraft = draft
        self.draftPersistenceError = draftPersistenceError; self.onSubmit = onSubmit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !attachments.isEmpty { attachmentTray }
            if let error {
                Text(error).font(theme.body(10)).foregroundStyle(theme.danger).lineLimit(2)
            }
            if let draftPersistenceError {
                Text(draftPersistenceError)
                    .font(theme.body(10)).foregroundStyle(theme.warn).lineLimit(2)
            }
            if !mentionOptions.isEmpty { mentionSuggestions }
            TextField(placeholder, text: draftBinding, axis: .vertical)
                .font(theme.body(14)).lineLimit(1...6).focused($focused)
                .textFieldStyle(.plain).padding(.horizontal, 12).padding(.vertical, 10)
                .background(theme.ink.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
                .disabled(sending)
                .accessibilityLabel(placeholder)
            HStack(spacing: 10) {
                Button { showAttachmentSources = true } label: {
                    Image(systemName: "paperclip").frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).foregroundStyle(theme.ink.opacity(0.7)).disabled(sending)
                .accessibilityLabel("Add attachment")
                Spacer()
                if !mentionHint.isEmpty {
                    Text(mentionHint).font(theme.mono(9)).foregroundStyle(theme.faint).lineLimit(1)
                }
                Button(action: send) {
                    HStack(spacing: 5) {
                        if sending { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.up") }
                        Text(submitLabel).font(theme.body(12, weight: .semibold))
                    }
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .background(canSend ? theme.accent : theme.faint.opacity(0.2),
                                in: Capsule())
                    .foregroundStyle(canSend ? Color.white : theme.faint)
                }
                .buttonStyle(.plain).disabled(!canSend || sending)
            }
        }
        .sheet(isPresented: $showAttachmentSources, onDismiss: performPendingAttachmentSource) {
            AttachmentSourceSheet(
                theme: theme,
                supportsPhotoLibrary: Self.supportsPhotoLibrary,
                allowsPaste: false,
                select: { action in
                    pendingAttachmentSource = action
                    showAttachmentSources = false
                },
                close: {
                    pendingAttachmentSource = nil
                    showAttachmentSources = false
                }
            )
        }
        #if canImport(PhotosUI)
        .photosPicker(isPresented: $showPhotos, selection: $photoItems,
                      maxSelectionCount: 6, matching: .images)
        .onChange(of: photoItems) { _, items in loadPhotos(items) }
        #endif
        #if canImport(UniformTypeIdentifiers)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.data, .pdf, .image],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { @MainActor in await loadFiles(urls) }
        }
        #endif
    }

    /// This must match the compile-time gate on the PhotosPicker modifier.
    /// The source sheet fails closed when PhotosUI is unavailable.
    private static var supportsPhotoLibrary: Bool {
        #if canImport(PhotosUI)
        true
        #else
        false
        #endif
    }

    private func performPendingAttachmentSource() {
        guard let action = pendingAttachmentSource else { return }
        pendingAttachmentSource = nil
        switch action {
        case .photos:
            #if canImport(PhotosUI)
            showPhotos = true
            #else
            assertionFailure("Photo Library was selected without PhotosUI support")
            #endif
        case .files:
            showFiles = true
        case .pasteImage:
            break // Room composers intentionally offer photo and file sources only.
        }
    }

    private var canSend: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
    }

    private var mentionHint: String {
        let handles = members.prefix(2).compactMap {
            RoomEngine.mentionInsertionTag(for: $0, among: members)
        }
            .map { "@\($0)" }.joined(separator: " ")
        return members.count > 2 ? "\(handles) …" : handles
    }

    private var mentionToken: String? {
        RoomMentionCompletion.activeToken(in: draftText)?.token
    }

    private var mentionOptions: [String] {
        guard let token = mentionToken else { return [] }
        // Room parsing and completion share RoomEngine's durable claim map:
        // an option can be found through a legacy handle or friendly raw name,
        // but only inserts a uniquely claimed friendly slug. A unique legacy
        // handle is the escape hatch for two seats with the same friendly
        // name. Reserved all/everyone remain broadcast verbs rather than
        // becoming a member identity.
        var options = ["everyone", "all"].filter { token.isEmpty || $0.hasPrefix(token) }
        for member in RoomEngine.mentionCompletionMembers(for: token, members: members) {
            guard let insertion = RoomEngine.mentionInsertionTag(for: member, among: members) else {
                continue
            }
            options.append(insertion)
        }
        var seen = Set<String>()
        return Array(options.filter { seen.insert($0).inserted }.prefix(6))
    }

    private var mentionSuggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(mentionOptions, id: \.self) { handle in
                    Button("@\(handle)") { insertMention(handle) }
                        .buttonStyle(.plain).font(theme.mono(10)).foregroundStyle(theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(theme.accent.opacity(0.09), in: Capsule())
                }
            }
        }.accessibilityLabel("Room mentions")
    }

    private func insertMention(_ handle: String) {
        guard let active = RoomMentionCompletion.activeToken(in: draftText) else { return }
        draftText = BotMention.complete(draftText, range: active.range, with: handle)
        focused = true
    }

    private var draftBinding: Binding<String> {
        Binding(get: { draftText }, set: { draftText = $0 })
    }

    private var draftText: String {
        get { externalDraft?.wrappedValue ?? localDraft }
        nonmutating set {
            if let externalDraft { externalDraft.wrappedValue = newValue }
            else { localDraft = newValue }
        }
    }

    private var attachmentTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 5) {
                        Image(systemName: attachment.kind == .image ? "photo" :
                                attachment.kind == .pdf ? "doc.richtext" : "doc")
                        Text(attachment.name).lineLimit(1)
                        Button { attachments.removeAll { $0.id == attachment.id } } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.name)")
                    }
                    .font(theme.body(10)).foregroundStyle(theme.ink.opacity(0.75))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(theme.ink.opacity(0.06), in: Capsule())
                }
            }
        }
    }

    private func send() {
        guard canSend, !sending else { return }
        let text = draftText
        let payload = attachments
        sending = true; error = nil
        Task { @MainActor in
            do {
                try await onSubmit(text, payload)
                draftText = RoomComposerDraftCompletionPolicy.result(
                    current: draftText, submitted: text, sendSucceeded: true)
                attachments = []; focused = false
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }

    #if canImport(PhotosUI)
    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photoItems = []
        Task { @MainActor in
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let shaped = AttachmentEncoder.gatewayImage(from: data, filename: "photo.heic") else {
                    continue
                }
                attachments.append(RoomOutboundAttachment(kind: .image,
                                                           name: "photo-\(attachments.count + 1).jpg",
                                                           data: shaped.data))
            }
        }
    }
    #endif

    private func loadFiles(_ urls: [URL]) async {
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let kind: RoomOutboundAttachment.Kind = AttachmentEncoder.isPDF(filename: url.lastPathComponent)
                ? .pdf : AttachmentEncoder.isImage(filename: url.lastPathComponent) ? .image : .file
            let cap = kind == .pdf ? AttachmentLimits.pdfBytes
                : kind == .image ? AttachmentLimits.imageBytes : AttachmentLimits.fileBytes
            guard data.count <= cap else {
                error = "\(url.lastPathComponent) is too large to attach."
                continue
            }
            if kind == .image,
               let shaped = AttachmentEncoder.gatewayImage(from: data, filename: url.lastPathComponent) {
                attachments.append(RoomOutboundAttachment(kind: .image,
                                                           name: shaped.filename, data: shaped.data))
            } else {
                attachments.append(RoomOutboundAttachment(kind: kind,
                                                           name: url.lastPathComponent, data: data))
            }
        }
    }
}
