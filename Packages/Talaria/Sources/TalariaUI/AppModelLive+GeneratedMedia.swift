import Foundation
import ImageIO
import TalariaKit

@MainActor
final class GeneratedImageRuntime {
    static let shared = GeneratedImageRuntime()
    var afterTranscriptAuthorityCaptureForTesting: (() async -> Void)?
    private init() {}
}

@MainActor
struct GeneratedImagePresentationSource {
    let model: AppModel
    let botID: String
    let route: GatewayBotRoute
    let storedSessionID: String
    let liveSessionID: String
    let messageRowID: Int?
    let messageRevisionID: UUID

    var identity: String {
        [route.gatewayID, route.profile, storedSessionID, liveSessionID,
         messageRowID.map(String.init) ?? "revision:\(messageRevisionID.uuidString)"]
            .joined(separator: "\u{1f}")
    }

    func identifies(_ message: ChatMessage) -> Bool {
        if let messageRowID { return message.rowID == messageRowID }
        return message.id == messageRevisionID
    }
}

enum GeneratedImageLoadResult: Sendable {
    case image(Data, GeneratedImageRasterMetadata)
    case externalApprovalRequired
    case unavailable(String)
}

enum GeneratedImageRasterFormat: String, Sendable, Equatable {
    case png, jpeg, webp, gif, bmp

    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    var mimeType: String { self == .jpeg ? "image/jpeg" : "image/\(rawValue)" }
}

struct GeneratedImageRasterMetadata: Sendable, Equatable {
    let width: Int
    let height: Int
    let format: GeneratedImageRasterFormat
}

enum GeneratedImageRasterPolicy {
    static let maximumDimension = 8_192
    static let maximumPixels = 40_000_000
    static let maximumFrames = 1

    static func inspect(_ data: Data, expectedMIME: String? = nil)
        -> GeneratedImageRasterMetadata? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == maximumFrames,
              let rawType = CGImageSourceGetType(source) as String?,
              let format = format(for: rawType),
              expectedMIME == nil || expectedMIME?.lowercased() == format.mimeType,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        let w = width.intValue, h = height.intValue
        guard w > 0, h > 0, w <= maximumDimension, h <= maximumDimension,
              w <= maximumPixels / h else { return nil }
        return GeneratedImageRasterMetadata(width: w, height: h, format: format)
    }

    static func dimensions(_ data: Data) -> CGSize? {
        guard let value = inspect(data) else { return nil }
        return CGSize(width: value.width, height: value.height)
    }

    private static func format(for rawType: String) -> GeneratedImageRasterFormat? {
        switch rawType.lowercased() {
        case "public.png": return .png
        case "public.jpeg", "public.jpg": return .jpeg
        case "org.webmproject.webp", "public.webp": return .webp
        case "com.compuserve.gif", "public.gif": return .gif
        case "com.microsoft.bmp", "public.bmp": return .bmp
        default: return nil
        }
    }
}

private struct GeneratedImageLoadAuthority: Sendable {
    let botID: String
    let route: GatewayBotRoute
    let storedSessionID: String
    let liveSessionID: String
    let chatID: ObjectIdentifier
    let messageRowID: Int?
    let messageRevisionID: UUID
    let gatewayToolID: String
    let output: ToolGeneratedImage
    let lifecycle: ProfileLifecycleGenerationToken
    let transcript: TranscriptHydrationSourceAuthority
    let snapshot: GatewayClientPool.ConnectionSnapshot
    let registryURL: String
    let registryCredential: GatewayCredential
}

extension AppModel {
    func loadGeneratedImage(_ call: ToolCall,
                            from source: GeneratedImagePresentationSource,
                            allowRemote: Bool = false) async -> GeneratedImageLoadResult {
        guard source.model === self,
              GeneratedImageEchoPolicy.hasSuccessfulAuthority(call),
              let output = call.generatedImage,
              let authority = await captureGeneratedImageAuthority(call, from: source),
              generatedImageAuthorityAcceptsSynchronously(authority)
        else { return .unavailable("The producing chat is no longer current.") }

        let bytes: Data
        let expectedMIME: String?
        do {
            switch output.sourceKind {
            case .gatewayPath:
                guard generatedImageAuthorityAcceptsSynchronously(authority) else {
                    return .unavailable("The producing chat changed before the image request.")
                }
                let dataURL = try await authority.snapshot.client
                    .generatedMediaDataURL(path: output.source)
                guard let decoded = Self.decodeGeneratedImageDataURL(dataURL) else {
                    return .unavailable("The gateway returned malformed image data.")
                }
                bytes = decoded.data
                expectedMIME = decoded.mimeType
            case .remoteURL:
                guard allowRemote else { return .externalApprovalRequired }
                guard let url = URL(string: output.source) else {
                    return .unavailable("The generated image link was invalid.")
                }
                guard generatedImageAuthorityAcceptsSynchronously(authority) else {
                    return .unavailable("The producing chat changed before the image request.")
                }
                bytes = try await GeneratedRemoteImageLoader.load(url)
                expectedMIME = nil
            }
        } catch is CancellationError {
            return .unavailable("Image loading was cancelled.")
        } catch {
            return .unavailable("The generated image could not be loaded.")
        }

        guard !Task.isCancelled,
              bytes.count <= ToolGeneratedImageCodec.maximumInlineDecodedBytes,
              let raster = GeneratedImageRasterPolicy.inspect(bytes, expectedMIME: expectedMIME),
              await generatedImageAuthorityIsCurrent(authority) else {
            return .unavailable("The producing chat changed before the image loaded.")
        }

        // Hold the exact retained slot across the final synchronous authority
        // check and return. A replacement connection cannot publish old bytes.
        let pool = ConnectionRegistry.shared.clientPool
        guard let lease = await pool.acquireLease(authority.snapshot,
                                                  for: authority.route.gatewayID) else {
            return .unavailable("The producing gateway is no longer current.")
        }
        let accepted = generatedImageAuthorityAcceptsSynchronously(authority)
        await pool.release(lease)
        return accepted ? .image(bytes, raster)
            : .unavailable("The producing chat changed before the image loaded.")
    }

    private func captureGeneratedImageAuthority(
        _ call: ToolCall,
        from source: GeneratedImagePresentationSource
    ) async -> GeneratedImageLoadAuthority? {
        guard !Task.isCancelled, mode == .live,
              GeneratedImageEchoPolicy.hasSuccessfulAuthority(call),
              let toolID = call.gatewayToolID, !toolID.isEmpty,
              let output = call.generatedImage,
              (stateRoute(for: source.botID) ?? gatewayRoute(for: source.botID)) == source.route,
              let chat = chats[source.botID],
              chat.storedSessionID == source.storedSessionID,
              (chat.sessionID ?? "") == source.liveSessionID,
              currentGeneratedImageCall(in: chat, source: source,
                                        gatewayToolID: toolID) == call,
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
              currentGeneratedImageCall(in: currentChat, source: source,
                                        gatewayToolID: toolID) == call,
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
        let authority = GeneratedImageLoadAuthority(
            botID: source.botID, route: source.route,
            storedSessionID: source.storedSessionID,
            liveSessionID: source.liveSessionID, chatID: chatID,
            messageRowID: source.messageRowID,
            messageRevisionID: source.messageRevisionID,
            gatewayToolID: toolID, output: output,
            lifecycle: lifecycle, transcript: transcript,
            snapshot: retainedSource.connection, registryURL: saved.urlString,
            registryCredential: credential)
        if let hook = GeneratedImageRuntime.shared.afterTranscriptAuthorityCaptureForTesting {
            await hook()
        }
        guard generatedImageAuthorityAcceptsSynchronously(authority) else { return nil }
        return authority
    }

    private func generatedImageAuthorityIsCurrent(
        _ authority: GeneratedImageLoadAuthority
    ) async -> Bool {
        guard await transcriptHydrationSourceIsCurrent(authority.transcript),
              await ConnectionRegistry.shared.clientPool.isCurrent(
                authority.snapshot, for: authority.route.gatewayID) else { return false }
        return generatedImageAuthorityAcceptsSynchronously(authority)
    }

    private func generatedImageAuthorityAcceptsSynchronously(
        _ authority: GeneratedImageLoadAuthority
    ) -> Bool {
        let registry = ConnectionRegistry.shared
        guard !Task.isCancelled, mode == .live,
              profileLifecycleAccepts(authority.lifecycle),
              profileLifecycleAllowsGatewayTraffic(authority.route.gatewayID),
              generatedImageTranscriptSourceAcceptsSynchronously(authority),
              (stateRoute(for: authority.botID) ?? gatewayRoute(for: authority.botID))
                == authority.route,
              let chat = chats[authority.botID], ObjectIdentifier(chat) == authority.chatID,
              chat.storedSessionID == authority.storedSessionID,
              (chat.sessionID ?? "") == authority.liveSessionID,
              let currentCall = currentGeneratedImageCall(
                in: chat,
                source: GeneratedImagePresentationSource(
                    model: self, botID: authority.botID, route: authority.route,
                    storedSessionID: authority.storedSessionID,
                    liveSessionID: authority.liveSessionID,
                    messageRowID: authority.messageRowID,
                    messageRevisionID: authority.messageRevisionID),
                gatewayToolID: authority.gatewayToolID),
              GeneratedImageEchoPolicy.hasSuccessfulAuthority(currentCall),
              currentCall.generatedImage == authority.output,
              let saved = registry.saved.first(where: { $0.id == authority.route.gatewayID }),
              saved.urlString == authority.registryURL,
              authority.snapshot.baseURL?.absoluteString == saved.urlString,
              registry.credential(for: saved) == authority.registryCredential else {
            return false
        }
        return true
    }

    private func generatedImageTranscriptSourceAcceptsSynchronously(
        _ authority: GeneratedImageLoadAuthority
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

    private func currentGeneratedImageCall(
        in chat: ChatState, source: GeneratedImagePresentationSource,
        gatewayToolID: String
    ) -> ToolCall? {
        var matchedMessage: ChatMessage?
        for message in chat.messages where source.identifies(message) {
            guard matchedMessage == nil else { return nil }
            matchedMessage = message
        }
        guard let message = matchedMessage else { return nil }
        var matchedCall: ToolCall?
        for call in message.toolCalls where call.gatewayToolID == gatewayToolID {
            guard matchedCall == nil else { return nil }
            matchedCall = call
        }
        return matchedCall
    }

    static func decodeGeneratedImageDataURL(_ value: String)
        -> (data: Data, mimeType: String)? {
        guard ToolGeneratedImageCodec.inlineDataDecodedUpperBound(value) != nil,
              let comma = value.firstIndex(of: ","),
              let data = Data(base64Encoded: String(value[value.index(after: comma)...])),
              data.count <= ToolGeneratedImageCodec.maximumInlineDecodedBytes else { return nil }
        return (data, String(value[..<comma]).dropLast(";base64".count).lowercased())
    }
}
