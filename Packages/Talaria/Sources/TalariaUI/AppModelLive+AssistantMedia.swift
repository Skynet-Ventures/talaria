import AVFoundation
import Foundation
import TalariaKit

@MainActor
final class AssistantMediaRuntime {
    static let shared = AssistantMediaRuntime()
    var afterTranscriptAuthorityCaptureForTesting: (() async -> Void)?
    private init() {}
}

@MainActor
struct AssistantMediaPresentationSource {
    let model: AppModel
    let botID: String
    let route: GatewayBotRoute
    let storedSessionID: String
    let liveSessionID: String
    let messageRowID: Int?
    let messageRevisionID: UUID
    let visibleMessageText: String
    let reference: AssistantMediaProjection.Reference

    var identity: String {
        [route.gatewayID, route.profile, storedSessionID, liveSessionID,
         messageRowID.map(String.init) ?? "revision:\(messageRevisionID.uuidString)",
         reference.fingerprint].joined(separator: "\u{1f}")
    }

    func identifies(_ message: ChatMessage) -> Bool {
        if let messageRowID { return message.rowID == messageRowID }
        return message.id == messageRevisionID
    }
}

enum AssistantMediaLoadResult: Sendable {
    case image(Data, GeneratedImageRasterMetadata)
    case localFile(URL, AssistantMediaProjection.Kind)
    case externalApprovalRequired(String)
    case unavailable(String)
}

enum AssistantMediaAVPolicy {
    static let maximumDuration: Double = 86_400
    static let maximumTracks = 8
    static let maximumDimension: Double = 8_192
    static let maximumPixels: Double = 40_000_000
    static let metadataDeadline: Duration = .seconds(5)

    static func admits(duration: Double, trackCount: Int,
                       width: Double? = nil, height: Double? = nil) -> Bool {
        guard duration.isFinite, duration > 0, duration <= maximumDuration,
              trackCount > 0, trackCount <= maximumTracks else { return false }
        guard let width, let height else { return true }
        let w = abs(width), h = abs(height)
        return w.isFinite && h.isFinite && w > 0 && h > 0
            && w <= maximumDimension && h <= maximumDimension
            && w <= maximumPixels / h
    }
}

private struct AssistantMediaLoadAuthority: Sendable {
    let botID: String
    let route: GatewayBotRoute
    let storedSessionID: String
    let liveSessionID: String
    let chatID: ObjectIdentifier
    let messageRowID: Int?
    let messageRevisionID: UUID
    let visibleMessageText: String
    let reference: AssistantMediaProjection.Reference
    let admitted: AssistantMediaSourcePolicy.AdmittedSource
    let lifecycle: ProfileLifecycleGenerationToken
    let transcript: TranscriptHydrationSourceAuthority
    let snapshot: GatewayClientPool.ConnectionSnapshot
    let registryURL: String
    let registryCredential: GatewayCredential
}

extension AppModel {
    func loadAssistantMedia(from source: AssistantMediaPresentationSource,
                            allowRemote: Bool = false) async -> AssistantMediaLoadResult {
        guard source.model === self else {
            return .unavailable("The producing chat is no longer current.")
        }
        guard let admitted = AssistantMediaSourcePolicy.admit(source.reference.rawValue) else {
            return .unavailable("This media path is not supported on mobile.")
        }
        guard
              let authority = await captureAssistantMediaAuthority(source, admitted: admitted),
              assistantMediaAuthorityAcceptsSynchronously(authority) else {
            return .unavailable("The producing chat is no longer current.")
        }

        if case .remoteURL(let url) = admitted.location, !allowRemote {
            return .externalApprovalRequired(url.host() ?? "external host")
        }

        let bytes: Data
        let responseMIME: String?
        do {
            guard assistantMediaAuthorityAcceptsSynchronously(authority) else {
                return .unavailable("The producing chat changed before the media request.")
            }
            switch admitted.location {
            case .gatewayPath(let path):
                if AssistantMediaSourcePolicy.gatewayFetchRoute(
                    for: admitted.presentationKind) == .stream {
                    let response = try await authority.snapshot.client
                        .restDataResponseBoundedNoRedirect(
                            path: "api/files/stream",
                            query: [URLQueryItem(name: "path", value: path)],
                            timeout: 60,
                            maximumResponseBytes: AssistantMediaSourcePolicy.maximumDownloadBytes)
                    bytes = response.0
                    responseMIME = (response.1 as? HTTPURLResponse)?.mimeType?.lowercased()
                } else {
                    let payload = try await authority.snapshot.client.assistantManagedFile(
                        path: path,
                        maximumDecodedBytes: AssistantMediaSourcePolicy.maximumDownloadBytes)
                    bytes = payload.data
                    responseMIME = payload.mimeType
                }
            case .remoteURL(let url):
                let payload = try await RemoteAssistantMediaLoader.load(
                    url, maximumBytes: AssistantMediaSourcePolicy.maximumDownloadBytes)
                bytes = payload.data
                responseMIME = payload.mimeType
            }
        } catch is CancellationError {
            return .unavailable("Media loading was cancelled.")
        } catch {
            return .unavailable("The media could not be loaded.")
        }

        guard !Task.isCancelled, !bytes.isEmpty,
              bytes.count <= AssistantMediaSourcePolicy.maximumDownloadBytes,
              AssistantMediaSourcePolicy.responseMIMEIsAllowed(
                responseMIME, for: admitted.presentationKind),
              await assistantMediaAuthorityIsCurrent(authority) else {
            return .unavailable("The producing chat changed before the media loaded.")
        }

        switch admitted.presentationKind {
        case .image:
            guard let raster = GeneratedImageRasterPolicy.inspect(bytes) else {
                return .unavailable("This image format is not safe to preview inline.")
            }
            return await finalizeAssistantMediaResult(
                .image(bytes, raster), authority: authority, ownedURL: nil)
        case .audio, .video, .file:
            let file: URL
            do {
                file = try Self.materializeAssistantMedia(
                    data: bytes, suggestedName: admitted.displayName)
                if admitted.presentationKind == .audio || admitted.presentationKind == .video {
                    guard await Self.playableMediaIsValid(
                        file, kind: admitted.presentationKind) else {
                        Self.removeOwnedAssistantMedia(file)
                        return .unavailable("This media file could not be played safely.")
                    }
                }
            } catch {
                return .unavailable("The media could not be prepared on this device.")
            }
            return await finalizeAssistantMediaResult(
                .localFile(file, admitted.presentationKind),
                authority: authority, ownedURL: file)
        }
    }

    private func finalizeAssistantMediaResult(
        _ result: AssistantMediaLoadResult,
        authority: AssistantMediaLoadAuthority,
        ownedURL: URL?
    ) async -> AssistantMediaLoadResult {
        let pool = ConnectionRegistry.shared.clientPool
        guard let lease = await pool.acquireLease(authority.snapshot,
                                                  for: authority.route.gatewayID) else {
            if let ownedURL { Self.removeOwnedAssistantMedia(ownedURL) }
            return .unavailable("The producing gateway is no longer current.")
        }
        let accepted = assistantMediaAuthorityAcceptsSynchronously(authority)
        await pool.release(lease)
        if !accepted, let ownedURL { Self.removeOwnedAssistantMedia(ownedURL) }
        return accepted ? result
            : .unavailable("The producing chat changed before the media loaded.")
    }

    private func captureAssistantMediaAuthority(
        _ source: AssistantMediaPresentationSource,
        admitted: AssistantMediaSourcePolicy.AdmittedSource
    ) async -> AssistantMediaLoadAuthority? {
        guard !Task.isCancelled, mode == .live,
              (stateRoute(for: source.botID) ?? gatewayRoute(for: source.botID)) == source.route,
              let chat = chats[source.botID],
              chat.storedSessionID == source.storedSessionID,
              (chat.sessionID ?? "") == source.liveSessionID,
              currentAssistantMediaReference(in: chat, source: source) == source.reference,
              !source.storedSessionID.isEmpty,
              let lifecycle = profileLifecycleGenerationToken(for: source.botID),
              lifecycle.route == source.route else { return nil }
        let chatID = ObjectIdentifier(chat)
        let registry = ConnectionRegistry.shared
        guard let saved = registry.saved.first(where: { $0.id == source.route.gatewayID }),
              let credential = registry.credential(for: saved) else { return nil }
        let retained = await registry.clientPool.retainedConnectionSnapshots()
        guard !Task.isCancelled,
              let currentChat = chats[source.botID], ObjectIdentifier(currentChat) == chatID,
              currentChat.storedSessionID == source.storedSessionID,
              (currentChat.sessionID ?? "") == source.liveSessionID,
              currentAssistantMediaReference(in: currentChat, source: source) == source.reference,
              (stateRoute(for: source.botID) ?? gatewayRoute(for: source.botID)) == source.route,
              profileLifecycleAccepts(lifecycle),
              let currentSaved = registry.saved.first(where: { $0.id == source.route.gatewayID }),
              currentSaved.urlString == saved.urlString,
              registry.credential(for: currentSaved) == credential,
              let retainedSource = retained.first(where: { snapshot in
                  snapshot.gatewayID == source.route.gatewayID
                      && snapshot.connection.baseURL?.absoluteString == saved.urlString
              }) else { return nil }
        let transcript = await captureTranscriptHydrationSourceAuthority(
            route: source.route, client: retainedSource.connection.client,
            expectedPooledSnapshot: source.route.gatewayID == LiveRuntime.shared.gatewayID
                ? nil : retainedSource.connection)
        guard let transcript else { return nil }
        let authority = AssistantMediaLoadAuthority(
            botID: source.botID, route: source.route,
            storedSessionID: source.storedSessionID,
            liveSessionID: source.liveSessionID, chatID: chatID,
            messageRowID: source.messageRowID,
            messageRevisionID: source.messageRevisionID,
            visibleMessageText: source.visibleMessageText,
            reference: source.reference, admitted: admitted,
            lifecycle: lifecycle, transcript: transcript,
            snapshot: retainedSource.connection, registryURL: saved.urlString,
            registryCredential: credential)
        if let hook = AssistantMediaRuntime.shared.afterTranscriptAuthorityCaptureForTesting {
            await hook()
        }
        guard assistantMediaAuthorityAcceptsSynchronously(authority) else { return nil }
        return authority
    }

    private func assistantMediaAuthorityIsCurrent(
        _ authority: AssistantMediaLoadAuthority
    ) async -> Bool {
        guard await transcriptHydrationSourceIsCurrent(authority.transcript),
              await ConnectionRegistry.shared.clientPool.isCurrent(
                authority.snapshot, for: authority.route.gatewayID) else { return false }
        return assistantMediaAuthorityAcceptsSynchronously(authority)
    }

    private func assistantMediaAuthorityAcceptsSynchronously(
        _ authority: AssistantMediaLoadAuthority
    ) -> Bool {
        let registry = ConnectionRegistry.shared
        let source = AssistantMediaPresentationSource(
            model: self, botID: authority.botID, route: authority.route,
            storedSessionID: authority.storedSessionID,
            liveSessionID: authority.liveSessionID,
            messageRowID: authority.messageRowID,
            messageRevisionID: authority.messageRevisionID,
            visibleMessageText: authority.visibleMessageText,
            reference: authority.reference)
        guard !Task.isCancelled, mode == .live,
              profileLifecycleAccepts(authority.lifecycle),
              profileLifecycleAllowsGatewayTraffic(authority.route.gatewayID),
              assistantMediaTranscriptSourceAcceptsSynchronously(authority),
              (stateRoute(for: authority.botID) ?? gatewayRoute(for: authority.botID))
                == authority.route,
              let chat = chats[authority.botID], ObjectIdentifier(chat) == authority.chatID,
              chat.storedSessionID == authority.storedSessionID,
              (chat.sessionID ?? "") == authority.liveSessionID,
              currentAssistantMediaReference(in: chat, source: source) == authority.reference,
              AssistantMediaSourcePolicy.admit(authority.reference.rawValue) == authority.admitted,
              let saved = registry.saved.first(where: { $0.id == authority.route.gatewayID }),
              saved.urlString == authority.registryURL,
              authority.snapshot.baseURL?.absoluteString == saved.urlString,
              registry.credential(for: saved) == authority.registryCredential else { return false }
        return true
    }

    private func assistantMediaTranscriptSourceAcceptsSynchronously(
        _ authority: AssistantMediaLoadAuthority
    ) -> Bool {
        let transcript = authority.transcript
        guard transcript.route == authority.route,
              LiveRuntime.shared.generation == transcript.liveGeneration,
              ObjectIdentifier(authority.snapshot.client)
                == ObjectIdentifier(transcript.client) else { return false }
        if transcript.wasPrimary {
            return LiveRuntime.shared.gatewayID == authority.route.gatewayID
                && self.client.map(ObjectIdentifier.init)
                    == ObjectIdentifier(transcript.client)
        }
        guard LiveRuntime.shared.gatewayID != authority.route.gatewayID,
              let generation = transcript.routedEventGeneration,
              let routed = MultiGatewayRuntime.shared.routedEvents[
                authority.route.gatewayID] else { return false }
        return ObjectIdentifier(routed.client) == ObjectIdentifier(transcript.client)
            && routed.generation == generation
            && MultiGatewayRuntime.shared.routedEventGenerations[
                authority.route.gatewayID] == generation
    }

    private func currentAssistantMediaReference(
        in chat: ChatState, source: AssistantMediaPresentationSource
    ) -> AssistantMediaProjection.Reference? {
        var matched: ChatMessage?
        for message in chat.messages where source.identifies(message) {
            guard matched == nil else { return nil }
            matched = message
        }
        guard let message = matched, message.author == .bot else { return nil }
        let visible = GeneratedImageEchoPolicy.suppress(in: message)
        guard visible == source.visibleMessageText else { return nil }
        let projection = AssistantMediaProjection.project(
            visible, isStreaming: message.isStreaming)
        guard !projection.isClipped else { return nil }
        let matches = projection.references.filter {
            $0.ordinal == source.reference.ordinal
                && $0.fingerprint == source.reference.fingerprint
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func playableMediaIsValid(
        _ url: URL, kind: AssistantMediaProjection.Kind
    ) async -> Bool {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask { await inspectPlayableMedia(url, kind: kind) }
            group.addTask {
                do {
                    try await Task.sleep(for: AssistantMediaAVPolicy.metadataDeadline)
                } catch {
                    return false
                }
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private static func inspectPlayableMedia(
        _ url: URL, kind: AssistantMediaProjection.Kind
    ) async -> Bool {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds
            let allTracks = try await asset.load(.tracks)
            switch kind {
            case .audio:
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                return !tracks.isEmpty && AssistantMediaAVPolicy.admits(
                    duration: duration, trackCount: allTracks.count)
            case .video:
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else { return false }
                let size = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let transformed = CGRect(origin: .zero, size: size)
                    .applying(transform).standardized.size
                return AssistantMediaAVPolicy.admits(
                    duration: duration, trackCount: allTracks.count,
                    width: transformed.width, height: transformed.height)
            case .image, .file:
                return false
            }
        } catch {
            return false
        }
    }

    static func removeOwnedAssistantMedia(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        guard folder.lastPathComponent.hasPrefix(
            AssistantMediaSourcePolicy.temporaryFolderPrefix) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    private static func materializeAssistantMedia(
        data: Data, suggestedName: String
    ) throws -> URL {
        let safe = suggestedName.map { character in
            character.isLetter || character.isNumber || "._- ".contains(character)
                ? character : "-"
        }
        let name = String(safe).trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "\(AssistantMediaSourcePolicy.temporaryFolderPrefix)\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: folder) } }
        let destination = folder.appending(
            path: name.isEmpty ? "media.bin" : String(name.prefix(100)))
        try data.write(to: destination, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: destination.path)
        #endif
        try Task.checkCancellation()
        completed = true
        return destination
    }
}

enum AssistantMediaSourcePolicy {
    static let maximumDownloadBytes = 40 * 1_024 * 1_024
    static let temporaryFolderPrefix = "talaria-assistant-media-"

    enum GatewayFetchRoute: Sendable, Equatable { case managedRead, stream }

    static func gatewayFetchRoute(
        for kind: AssistantMediaProjection.Kind
    ) -> GatewayFetchRoute {
        kind == .audio || kind == .video ? .stream : .managedRead
    }

    enum Location: Sendable, Equatable {
        case gatewayPath(String)
        case remoteURL(URL)
    }

    struct AdmittedSource: Sendable, Equatable {
        let location: Location
        let presentationKind: AssistantMediaProjection.Kind
        let displayName: String
    }

    static func admit(_ raw: String) -> AdmittedSource? {
        guard raw.utf8.count <= AssistantMediaProjection.maximumValueUTF8Bytes,
              raw.unicodeScalars.prefix(AssistantMediaProjection.maximumValueScalars + 1).count
                <= AssistantMediaProjection.maximumValueScalars,
              !raw.unicodeScalars.contains(where: unsafeScalar) else { return nil }
        let lower = raw.lowercased()
        let location: Location
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard !raw.contains("\\"), let decoded = raw.removingPercentEncoding,
                  !decoded.unicodeScalars.contains(where: unsafeScalar),
                  let parts = URLComponents(string: raw),
                  let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = parts.host, !host.isEmpty,
                  parts.user == nil, parts.password == nil,
                  RemoteGeneratedImagePolicy.hostIsPublic(host),
                  let url = parts.url else { return nil }
            location = .remoteURL(url)
        } else {
            guard !raw.contains("%") else { return nil }
            var path = raw
            if lower.hasPrefix("file://") {
                guard let url = URL(string: raw), url.scheme?.lowercased() == "file",
                      url.host == nil || url.host?.isEmpty == true || url.host == "localhost"
                else { return nil }
                path = url.path(percentEncoded: false)
            } else if raw.contains(":") {
                guard raw.range(of: #"^[A-Za-z]:[\\/]"#,
                                options: .regularExpression) != nil else { return nil }
            }
            let normalized: String
            if path.hasPrefix("~/") {
                normalized = path
            } else {
                guard let parsed = WorkspaceRemotePath.normalized(path),
                      WorkspaceRemotePath.isAbsolute(parsed),
                      !WorkspaceRemotePath.isFilesystemRoot(parsed) else { return nil }
                normalized = parsed
            }
            location = .gatewayPath(normalized)
        }
        var kind = AssistantMediaProjection.classify(raw)
        let clean = raw.split(separator: "?", maxSplits: 1).first
            .flatMap { $0.split(separator: "#", maxSplits: 1).first }.map(String.init) ?? raw
        if clean.lowercased().hasSuffix(".svg") { kind = .file }
        let name = clean.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last
            .map(String.init) ?? "media"
        return AdmittedSource(location: location, presentationKind: kind,
                              displayName: name.isEmpty ? "media" : String(name.prefix(100)))
    }

    static func responseMIMEIsAllowed(_ mime: String?,
                                      for kind: AssistantMediaProjection.Kind) -> Bool {
        guard let mime else { return true }
        switch kind {
        case .image: return mime.hasPrefix("image/") || mime == "application/octet-stream"
        case .audio:
            return mime.hasPrefix("audio/") || mime == "application/ogg"
                || mime == "application/octet-stream"
        case .video:
            return mime.hasPrefix("video/") || mime == "application/ogg"
                || mime == "application/octet-stream"
        case .file:
            return mime != "text/html" && mime != "application/xhtml+xml"
        }
    }

    private static func unsafeScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7f...0x9f).contains(scalar.value)
            || scalar.value == 0x061c || (0x200e...0x200f).contains(scalar.value)
            || (0x202a...0x202e).contains(scalar.value)
            || (0x2066...0x2069).contains(scalar.value)
    }
}
