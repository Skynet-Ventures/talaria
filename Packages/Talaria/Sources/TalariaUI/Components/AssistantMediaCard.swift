import AVKit
import ImageIO
import SwiftUI
import TalariaKit
import TalariaTheme

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum AssistantMediaPresentationPolicy {
    static let minimumInteractiveDimension: CGFloat = 44
    static let automaticallyStartsPlayback = false
    static let loadsAutomatically = false
    static let rendersUnavailableWithoutAuthority = true
    static let pausesWhenInactive = true
    static let waitingOwnsPlayback = true
    static let observesNativePlayerStatus = true
    static let accessibilityAnnouncements = true
}

@MainActor
final class AssistantMediaPlaybackCoordinator {
    static let shared = AssistantMediaPlaybackCoordinator()
    private var current: AVPlayer?
    private var currentID: String?
    private var deactivateCurrent: (() -> Void)?
    var activeIDForTesting: String? { currentID }

    func activate(_ player: AVPlayer, id: String,
                  onDeactivated: @escaping () -> Void) {
        if current !== player || currentID != id {
            current?.pause()
            deactivateCurrent?()
        }
        current = player
        currentID = id
        deactivateCurrent = onDeactivated
    }

    func deactivate(_ player: AVPlayer, id: String) {
        player.pause()
        if current === player, currentID == id {
            current = nil
            currentID = nil
            deactivateCurrent = nil
        }
    }
}

@MainActor
struct AssistantMediaCard: View {
    let source: AssistantMediaPresentationSource
    let theme: ThemePack
    let accent: Color

    init(source: AssistantMediaPresentationSource, theme: ThemePack, accent: Color) {
        self.source = source
        self.theme = theme
        self.accent = accent
    }

    @State private var state: LoadState = .idle
    @State private var loadTask: Task<Void, Never>?
    @State private var player: AVPlayer?
    @State private var playerStatusObservation: NSKeyValueObservation?
    @State private var playing = false
    @State private var viewerPresented = false
    @State private var sharedFile: ExportedFile?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.talariaReducedMotion) private var reducedMotion

    private enum LoadState {
        case idle
        case loading
        case permission(host: String)
        case image(Data, GeneratedImageRasterMetadata)
        case file(URL, AssistantMediaProjection.Kind)
        case failure(String)
    }

    private var kind: AssistantMediaProjection.Kind {
        AssistantMediaSourcePolicy.admit(source.reference.rawValue)?.presentationKind
            ?? source.reference.kind
    }
    private var statusValue: String {
        switch state {
        case .idle: return "\(kindLabel) not loaded"
        case .loading: return "Loading \(kindLabel.lowercased())"
        case .permission(let host): return "Permission required to contact \(host)"
        case .image: return "Image ready"
        case .file(_, let kind): return "\(label(for: kind)) ready"
        case .failure: return "\(kindLabel) unavailable. Retry available"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kindLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.ink)
                    Text(headerDetail)
                        .font(.caption)
                        .foregroundStyle(theme.sub)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 4)
                if case .image = state { shareButton }
                if case .file = state { shareButton }
            }
            content
        }
        .padding(10)
        .background(theme.panel,
                    in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
            .strokeBorder(accent.opacity(0.28), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityValue(statusValue)
        .transaction { if reducedMotion { $0.animation = nil } }
        .onChange(of: source.identity) { _, _ in reset() }
        .onChange(of: statusValue) { _, value in announce(value) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { pause() }
        }
        .onDisappear { reset() }
        .sheet(item: $sharedFile, onDismiss: cleanupShare) { file in
            #if os(iOS)
            TalariaShareSheet(items: [file.url]) { sharedFile = nil }
            #else
            EmptyView()
            #endif
        }
        .sheet(isPresented: $viewerPresented) { imageViewer }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .idle:
            VStack(alignment: .leading, spacing: 8) {
                if let host = externalHost {
                    Text("Loads from \(host) only after you ask.")
                        .font(.caption).foregroundStyle(theme.sub)
                        .textSelection(.enabled)
                } else {
                    Text("Loads from the producing gateway only after you ask.")
                        .font(.caption).foregroundStyle(theme.sub)
                }
                actionButton("Load \(kindLabel.lowercased())",
                             symbol: "arrow.down.circle") {
                    startLoad(allowRemote: externalHost != nil)
                }
            }
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(accent)
                Text("Loading from the producing gateway…")
                    .font(.caption).foregroundStyle(theme.sub)
            }
            .frame(minHeight: 44)
        case .permission(let host):
            VStack(alignment: .leading, spacing: 8) {
                Text("This will contact \(host).")
                    .font(.caption).foregroundStyle(theme.sub)
                    .textSelection(.enabled)
                actionButton("Load \(kindLabel.lowercased())", symbol: "arrow.down.circle") {
                    startLoad(allowRemote: true)
                }
                .accessibilityHint("Contacts the public media host shown above")
            }
        case .image(let data, let raster):
            if let image = renderImage(data) {
                Button { viewerPresented = true } label: {
                    image.resizable().scaledToFit()
                        .frame(maxWidth: .infinity)
                        .aspectRatio(CGFloat(raster.width) / CGFloat(raster.height),
                                     contentMode: .fit)
                        .background(theme.inset)
                        .clipShape(RoundedRectangle(cornerRadius: theme.rowRadius,
                                                    style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityLabel("Open \(source.reference.displayName)")
                .accessibilityHint("Shows the image full screen")
            }
        case .file(let url, let kind):
            switch kind {
            case .audio:
                audioControls(url)
            case .video:
                videoPlayer(url)
            case .file, .image:
                actionButton("Open or share file", symbol: "square.and.arrow.up") { share() }
            }
        case .failure(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.caption).foregroundStyle(theme.warn)
                actionButton("Retry", symbol: "arrow.clockwise") {
                    startLoad(allowRemote: true)
                }
            }
        }
    }

    private var shareButton: some View {
        Button(action: share) {
                Image(systemName: "square.and.arrow.up")
                .frame(width: AssistantMediaPresentationPolicy.minimumInteractiveDimension,
                       height: AssistantMediaPresentationPolicy.minimumInteractiveDimension)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(accent)
        .accessibilityLabel("Share \(source.reference.displayName)")
    }

    private func audioControls(_ url: URL) -> some View {
        HStack(spacing: 10) {
            Button { togglePlayback(url) } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .frame(width: 44, height: 44)
                    .background(accent.opacity(0.14), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).foregroundStyle(accent)
            .accessibilityLabel(playing ? "Pause audio" : "Play audio")
            Text(playing ? "Playing" : "Ready to play")
                .font(.caption).foregroundStyle(theme.sub)
            Spacer()
        }
    }

    private func videoPlayer(_ url: URL) -> some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(minHeight: 120)
            } else {
                actionButton("Prepare video", symbol: "play.rectangle") {
                    let next = AVPlayer(url: url)
                    installPlayer(next)
                }
            }
        }
        .accessibilityLabel("Video \(source.reference.displayName)")
    }

    private var imageViewer: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            if case .image(let data, _) = state, let image = renderImage(data) {
                image.resizable().scaledToFit().padding(8)
            }
            VStack {
                HStack {
                    Button { viewerPresented = false } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                            .background(theme.panel.opacity(0.92), in: Circle())
                    }
                    .buttonStyle(.plain).foregroundStyle(theme.ink)
                    .accessibilityLabel("Close image")
                    Spacer()
                    shareButton
                }
                .padding(12)
                Spacer()
            }
        }
    }

    private func actionButton(_ title: String, symbol: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(accent)
    }

    private func startLoad(allowRemote: Bool) {
        loadTask?.cancel()
        loadTask = Task { await load(allowRemote: allowRemote) }
    }

    private func load(allowRemote: Bool) async {
        cleanupLoadedFile()
        state = .loading
        let result = await source.model.loadAssistantMedia(
            from: source, allowRemote: allowRemote)
        guard !Task.isCancelled else {
            if case .localFile(let url, _) = result {
                AppModel.removeOwnedAssistantMedia(url)
            }
            return
        }
        switch result {
        case .image(let data, let raster): state = .image(data, raster)
        case .localFile(let url, let kind):
            state = .file(url, kind)
            if kind == .video { installPlayer(AVPlayer(url: url)) }
        case .externalApprovalRequired(let host): state = .permission(host: host)
        case .unavailable(let message): state = .failure(message)
        }
    }

    private func togglePlayback(_ url: URL) {
        let active = player ?? AVPlayer(url: url)
        if player == nil { installPlayer(active) }
        if playing {
            active.pause()
            playing = false
        } else {
            AssistantMediaPlaybackCoordinator.shared.activate(
                active, id: source.identity, onDeactivated: { playing = false })
            active.play()
            playing = true
        }
    }

    private func pause() {
        guard let player else { return }
        AssistantMediaPlaybackCoordinator.shared.deactivate(
            player, id: source.identity)
        playing = false
    }

    private func installPlayer(_ next: AVPlayer) {
        playerStatusObservation?.invalidate()
        player = next
        let identity = source.identity
        let playing = $playing
        playerStatusObservation = next.observe(
            \.timeControlStatus, options: [.initial, .new]) { player, change in
            guard let status = change.newValue else { return }
            Task { @MainActor in
                switch status {
                case .playing, .waitingToPlayAtSpecifiedRate:
                    AssistantMediaPlaybackCoordinator.shared.activate(
                        player, id: identity,
                        onDeactivated: { playing.wrappedValue = false })
                    playing.wrappedValue = true
                case .paused:
                    AssistantMediaPlaybackCoordinator.shared.deactivate(
                        player, id: identity)
                    playing.wrappedValue = false
                @unknown default:
                    break
                }
            }
        }
    }

    private func share() {
        switch state {
        case .image(let data, let raster):
            let base = (source.reference.displayName as NSString)
                .deletingPathExtension
            guard let url = try? TalariaExportBox.write(
                data, named: "\(base.isEmpty ? "image" : base).\(raster.format.fileExtension)")
            else { return }
            sharedFile = ExportedFile(url: url)
        case .file(let url, _):
            sharedFile = ExportedFile(url: url)
        default:
            break
        }
    }

    private func cleanupShare() {
        guard let sharedFile else { return }
        if case .file(let loaded, _) = state, loaded == sharedFile.url {
            self.sharedFile = nil
            return
        }
        sharedFile.removeOwnedShareCopy()
        self.sharedFile = nil
    }

    private func cleanupLoadedFile() {
        pause()
        playerStatusObservation?.invalidate()
        playerStatusObservation = nil
        player = nil
        if case .file(let url, _) = state {
            AppModel.removeOwnedAssistantMedia(url)
        }
    }

    private func reset() {
        loadTask?.cancel()
        loadTask = nil
        viewerPresented = false
        cleanupShare()
        cleanupLoadedFile()
        state = .idle
    }

    private var kindLabel: String { label(for: kind) }
    private var headerDetail: String {
        guard let host = externalHost else { return source.reference.displayName }
        return "\(source.reference.displayName) · \(host)"
    }
    private var externalHost: String? {
        guard let admitted = AssistantMediaSourcePolicy.admit(source.reference.rawValue),
              case .remoteURL(let url) = admitted.location else { return nil }
        return url.host()
    }
    private func label(for kind: AssistantMediaProjection.Kind) -> String {
        switch kind {
        case .image: return "Image"
        case .audio: return "Audio"
        case .video: return "Video"
        case .file: return "File"
        }
    }
    private var symbol: String {
        switch kind {
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "play.rectangle"
        case .file: return "doc"
        }
    }

    private func renderImage(_ data: Data) -> Image? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4_096,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        #if canImport(UIKit)
        return Image(uiImage: UIImage(cgImage: cg))
        #elseif canImport(AppKit)
        return Image(nsImage: NSImage(cgImage: cg,
            size: NSSize(width: cg.width, height: cg.height)))
        #else
        return nil
        #endif
    }

    private func announce(_ value: String) {
        #if canImport(UIKit)
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: value)
        #endif
    }
}

struct AssistantMediaUnavailableCard: View {
    let reference: AssistantMediaProjection.Reference
    let theme: ThemePack
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(theme.warn)
                .frame(width: AssistantMediaPresentationPolicy.minimumInteractiveDimension,
                       height: AssistantMediaPresentationPolicy.minimumInteractiveDimension)
            VStack(alignment: .leading, spacing: 3) {
                Text(reference.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.ink)
                    .textSelection(.enabled)
                Text("Media is unavailable until its producing live session is current.")
                    .font(.caption)
                    .foregroundStyle(theme.sub)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(theme.panel,
                    in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
            .strokeBorder(accent.opacity(0.22), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Media unavailable. \(reference.displayName)")
    }
}
