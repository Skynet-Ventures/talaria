import ImageIO
import SwiftUI
import TalariaKit
import TalariaTheme

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
enum GeneratedImagePresentationPolicy {
    static let minimumInteractiveDimension: CGFloat = 44
    static let titleTextStyle: Font.TextStyle = .subheadline
    static let statusTextStyle: Font.TextStyle = .caption
    static let pendingMessage = "The generated image will appear here."
    static let loadRemoteLabel = "Load image"
    static let reducedMotionUsesSpatialAnimation = false

    static func accessibilityValue(call: ToolCall, loaded: Bool) -> String {
        if call.state == .running { return "Generating image" }
        return loaded ? "Generated image ready" : "Generated image not loaded"
    }
}

@MainActor
struct GeneratedImageCard: View {
    let call: ToolCall
    let source: GeneratedImagePresentationSource
    let theme: ThemePack
    let accent: Color

    @State private var data: Data?
    @State private var status: String?
    @State private var remoteApprovalRequired = false
    @State private var loading = false
    @State private var viewerPresented = false
    @State private var exported: ExportedFile?
    @State private var loadTask: Task<Void, Never>?
    @State private var presentationTask: Task<Void, Never>?
    @Environment(\.talariaReducedMotion) private var reducedMotion
    @Environment(\.openURL) private var openURL

    private var output: ToolGeneratedImage? { call.generatedImage }
    private var hintRatio: CGFloat {
        CGFloat(output?.aspect.ratio
            ?? ToolGeneratedImageCodec.aspectHint(from: call.arguments).ratio)
    }
    private var actualRatio: CGFloat {
        guard let data, let size = GeneratedImageRasterPolicy.dimensions(data) else {
            return hintRatio
        }
        return size.width / size.height
    }
    private var taskIdentity: String {
        [source.identity, call.gatewayToolID ?? call.id, call.state.rawValue,
         output?.source ?? ""].joined(separator: "\u{1f}")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if loading || call.state == .running {
                    ProgressView().controlSize(.small).tint(accent)
                } else {
                    Image(systemName: data == nil ? "photo.badge.exclamationmark" : "sparkles")
                        .foregroundStyle(data == nil ? theme.warn : accent)
                }
                Text(call.state == .running ? "Generating image" : "Generated image")
                    .font(.system(GeneratedImagePresentationPolicy.titleTextStyle).weight(.semibold))
                    .foregroundStyle(theme.ink)
                Spacer(minLength: 4)
                if data != nil {
                    Button(action: share) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                    .accessibilityLabel("Share generated image")
                }
            }

            preview

            if output?.sourceKind == .remoteURL,
               let raw = output?.source, let url = URL(string: raw) {
                Button { openURL(url) } label: {
                    Label("Open image link", systemImage: "safari")
                        .font(.system(GeneratedImagePresentationPolicy.statusTextStyle)
                            .weight(.semibold))
                        .frame(maxWidth: .infinity,
                               minHeight: GeneratedImagePresentationPolicy.minimumInteractiveDimension)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .accessibilityHint("Opens the public image URL in your browser")
            }

            if let status {
                Text(status)
                    .font(.system(GeneratedImagePresentationPolicy.statusTextStyle))
                    .foregroundStyle(theme.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Generated image status. \(status)")
            }
        }
        .padding(10)
        .background(theme.panel,
                    in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
            .strokeBorder(accent.opacity(0.32), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityValue(GeneratedImagePresentationPolicy.accessibilityValue(
            call: call, loaded: data != nil))
        .transaction { transaction in
            if reducedMotion { transaction.animation = nil }
        }
        .onChange(of: taskIdentity) { _, _ in reset() }
        .task(id: taskIdentity) {
            guard call.state == .done, output != nil else { return }
            await load(allowRemote: false)
        }
        .generatedImageInspection(isPresented: $viewerPresented) {
            if let data, let image = GeneratedImageRendering.image(data) {
                GeneratedImageViewer(image: image, theme: theme,
                                     close: { viewerPresented = false },
                                     share: shareFromViewer)
                    .presentationBackground(theme.bg)
            }
        }
        .sheet(item: $exported, onDismiss: cleanupExport) { file in
            #if os(iOS)
            TalariaShareSheet(items: [file.url]) {
                file.removeOwnedShareCopy()
                exported = nil
            }
            #else
            EmptyView()
            #endif
        }
        .onDisappear { reset() }
    }

    @ViewBuilder private var preview: some View {
        if let data, let image = GeneratedImageRendering.image(data) {
            Button {
                viewerPresented = true
            } label: {
                image.resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(actualRatio, contentMode: .fit)
                    .background(theme.inset)
                    .clipShape(RoundedRectangle(cornerRadius: theme.rowRadius,
                                                style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minHeight: GeneratedImagePresentationPolicy.minimumInteractiveDimension)
            .accessibilityLabel("Generated image")
            .accessibilityHint("Opens a full-screen image viewer")
        } else if remoteApprovalRequired {
            Button {
                loadTask?.cancel()
                loadTask = Task { await load(allowRemote: true) }
            } label: {
                HStack {
                    if loading { ProgressView().controlSize(.small) }
                    Text(GeneratedImagePresentationPolicy.loadRemoteLabel)
                        .font(.system(GeneratedImagePresentationPolicy.titleTextStyle)
                            .weight(.semibold))
                    Spacer()
                    Image(systemName: "arrow.down.circle")
                }
                .foregroundStyle(accent)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity,
                       minHeight: GeneratedImagePresentationPolicy.minimumInteractiveDimension)
                .background(theme.inset,
                            in: RoundedRectangle(cornerRadius: theme.rowRadius,
                                                 style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(loading)
            .accessibilityLabel(loading ? "Loading external generated image" : "Load image")
            .accessibilityHint("Contacts the public image host shown by the tool")
        } else {
            Text(call.state == .running
                 ? GeneratedImagePresentationPolicy.pendingMessage
                 : (status ?? "Loading from the producing gateway…"))
                .font(.system(GeneratedImagePresentationPolicy.statusTextStyle))
                .foregroundStyle(theme.sub)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .aspectRatio(hintRatio, contentMode: .fit)
                .background(theme.inset,
                            in: RoundedRectangle(cornerRadius: theme.rowRadius,
                                                 style: .continuous))
        }
    }

    private func load(allowRemote: Bool) async {
        guard let output else { return }
        loading = true
        status = nil
        let result = await source.model.loadGeneratedImage(
            output, from: source, allowRemote: allowRemote)
        guard !Task.isCancelled, output == self.output else { return }
        loading = false
        switch result {
        case .image(let bytes):
            guard GeneratedImageRendering.image(bytes) != nil else {
                status = "The returned bytes could not be decoded as an image."
                return
            }
            data = bytes
            remoteApprovalRequired = false
        case .externalApprovalRequired:
            remoteApprovalRequired = true
            status = "External images load only after you ask."
        case .unavailable(let message):
            status = message
        }
    }

    private func reset() {
        loadTask?.cancel()
        loadTask = nil
        presentationTask?.cancel()
        presentationTask = nil
        data = nil
        status = nil
        loading = false
        remoteApprovalRequired = false
        viewerPresented = false
        cleanupExport()
    }

    private func share() {
        guard let data else { return }
        do {
            exported = ExportedFile(url: try TalariaExportBox.write(
                data, named: "generated-image.\(GeneratedImageRendering.extension(for: data))"))
        } catch {
            status = "The image could not be prepared for sharing or saving."
        }
    }

    private func shareFromViewer() {
        viewerPresented = false
        presentationTask?.cancel()
        presentationTask = Task { @MainActor in
            if !reducedMotion {
                try? await Task.sleep(for: .milliseconds(220))
            }
            guard !Task.isCancelled else { return }
            share()
            presentationTask = nil
        }
    }

    private func cleanupExport() {
        exported?.removeOwnedShareCopy()
        exported = nil
    }
}

private extension View {
    @ViewBuilder
    func generatedImageInspection<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }
}

@MainActor
private enum GeneratedImageRendering {
    static func image(_ data: Data) -> Image? {
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

    static func `extension`(for data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else { return "png" }
        if type.contains("jpeg") { return "jpg" }
        if type.contains("webp") { return "webp" }
        if type.contains("gif") { return "gif" }
        if type.contains("heic") { return "heic" }
        if type.contains("heif") { return "heif" }
        if type.contains("bmp") { return "bmp" }
        return "png"
    }
}

@MainActor
private struct GeneratedImageViewer: View {
    let image: Image
    let theme: ThemePack
    let close: () -> Void
    let share: () -> Void

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            image.resizable().scaledToFit()
                .padding(.horizontal, 8)
                .ignoresSafeArea(edges: .bottom)
            VStack {
                HStack {
                    action("xmark", label: "Close generated image", operation: close)
                    Spacer()
                    action("square.and.arrow.up", label: "Share or save generated image",
                           operation: share)
                }
                .padding(12)
                Spacer()
            }
        }
    }

    private func action(_ symbol: String, label: String,
                        operation: @escaping () -> Void) -> some View {
        Button(action: operation) {
            Image(systemName: symbol)
                .frame(width: 44, height: 44)
                .background(theme.panel.opacity(0.92), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.ink)
        .accessibilityLabel(label)
    }
}
