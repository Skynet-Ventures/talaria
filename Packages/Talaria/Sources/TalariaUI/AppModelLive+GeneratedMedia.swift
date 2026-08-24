import Foundation
import ImageIO
import TalariaKit

@MainActor
struct GeneratedImagePresentationSource {
    let model: AppModel
    let botID: String
    let route: GatewayBotRoute
    let storedSessionID: String
    let liveSessionID: String

    var identity: String {
        [route.gatewayID, route.profile, storedSessionID, liveSessionID]
            .joined(separator: "\u{1f}")
    }
}

enum GeneratedImageLoadResult: Sendable {
    case image(Data)
    case externalApprovalRequired
    case unavailable(String)
}

enum GeneratedImageRasterPolicy {
    static let maximumDimension = 8_192
    static let maximumPixels = 40_000_000
    static let maximumFrames = 1

    static func dimensions(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetCount(source) <= maximumFrames,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        let w = width.intValue, h = height.intValue
        guard w > 0, h > 0, w <= maximumDimension, h <= maximumDimension,
              w <= maximumPixels / h else { return nil }
        return CGSize(width: w, height: h)
    }
}

private struct GeneratedImageLoadAuthority: Sendable {
    let botID: String
    let route: GatewayBotRoute
    let storedSessionID: String
    let liveSessionID: String
    let chatID: ObjectIdentifier
    let output: ToolGeneratedImage
    let lifecycle: ProfileLifecycleGenerationToken
    let transcript: TranscriptHydrationSourceAuthority
    let snapshot: GatewayClientPool.ConnectionSnapshot
    let registryURL: String
    let registryCredential: GatewayCredential
}

extension AppModel {
    func loadGeneratedImage(_ output: ToolGeneratedImage,
                            from source: GeneratedImagePresentationSource,
                            allowRemote: Bool = false) async -> GeneratedImageLoadResult {
        guard source.model === self,
              let authority = await captureGeneratedImageAuthority(output, from: source)
        else { return .unavailable("The producing chat is no longer current.") }

        let bytes: Data
        do {
            switch output.sourceKind {
            case .gatewayPath:
                let dataURL = try await authority.snapshot.client
                    .generatedMediaDataURL(path: output.source)
                guard let decoded = Self.decodeGeneratedImageDataURL(dataURL) else {
                    return .unavailable("The gateway returned malformed image data.")
                }
                bytes = decoded
            case .remoteURL:
                guard allowRemote else { return .externalApprovalRequired }
                guard let url = URL(string: output.source) else {
                    return .unavailable("The generated image link was invalid.")
                }
                bytes = try await GeneratedRemoteImageLoader.load(url)
            }
        } catch is CancellationError {
            return .unavailable("Image loading was cancelled.")
        } catch {
            return .unavailable("The generated image could not be loaded.")
        }

        guard !Task.isCancelled,
              bytes.count <= ToolGeneratedImageCodec.maximumInlineDecodedBytes,
              GeneratedImageRasterPolicy.dimensions(bytes) != nil,
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
        return accepted ? .image(bytes)
            : .unavailable("The producing chat changed before the image loaded.")
    }

    private func captureGeneratedImageAuthority(
        _ output: ToolGeneratedImage,
        from source: GeneratedImagePresentationSource
    ) async -> GeneratedImageLoadAuthority? {
        guard !Task.isCancelled, mode == .live,
              (stateRoute(for: source.botID) ?? gatewayRoute(for: source.botID)) == source.route,
              let chat = chats[source.botID],
              chat.storedSessionID == source.storedSessionID,
              (chat.sessionID ?? "") == source.liveSessionID,
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
        return GeneratedImageLoadAuthority(
            botID: source.botID, route: source.route,
            storedSessionID: source.storedSessionID,
            liveSessionID: source.liveSessionID, chatID: chatID, output: output,
            lifecycle: lifecycle, transcript: transcript,
            snapshot: retainedSource.connection, registryURL: saved.urlString,
            registryCredential: credential)
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
              (stateRoute(for: authority.botID) ?? gatewayRoute(for: authority.botID))
                == authority.route,
              let chat = chats[authority.botID], ObjectIdentifier(chat) == authority.chatID,
              chat.storedSessionID == authority.storedSessionID,
              (chat.sessionID ?? "") == authority.liveSessionID,
              let saved = registry.saved.first(where: { $0.id == authority.route.gatewayID }),
              saved.urlString == authority.registryURL,
              authority.snapshot.baseURL?.absoluteString == saved.urlString,
              registry.credential(for: saved) == authority.registryCredential else {
            return false
        }
        return true
    }

    static func decodeGeneratedImageDataURL(_ value: String) -> Data? {
        guard ToolGeneratedImageCodec.inlineDataDecodedUpperBound(value) != nil,
              let comma = value.firstIndex(of: ","),
              let data = Data(base64Encoded: String(value[value.index(after: comma)...])),
              data.count <= ToolGeneratedImageCodec.maximumInlineDecodedBytes else { return nil }
        return data
    }
}
