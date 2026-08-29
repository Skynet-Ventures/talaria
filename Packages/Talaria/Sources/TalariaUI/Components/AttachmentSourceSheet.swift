import SwiftUI
import TalariaTheme

/// A source selected in Talaria's attachment sheet. The presenting composer
/// dismisses the sheet first, then opens the corresponding system picker from
/// its `onDismiss` callback. That explicit handoff avoids stacked
/// presentations and timing-dependent delays.
public enum AttachmentSourceAction: String, CaseIterable, Equatable, Sendable {
    case photos
    case files
    case pasteImage
}

public struct AttachmentSourceOption: Identifiable, Equatable, Sendable {
    public let action: AttachmentSourceAction
    public let title: String
    public let detail: String
    public let systemImage: String

    public var id: AttachmentSourceAction { action }
}

/// Presentation data is kept outside the view so the available actions and
/// accessibility copy can be certified without presenting PhotosUI in tests.
public enum AttachmentSourcePresentation {
    public static let title = "Add to message"
    public static let minimumTouchTarget: CGFloat = 44
    public static let minimumRowHeight: CGFloat = 56
    public static let minimumTileHeight: CGFloat = 120
    public static let tileSpacing: CGFloat = 10
    public static let horizontalPadding: CGFloat = 16
    public static let verticalPadding: CGFloat = 12
    public static let compactHeaderHeight: CGFloat = 58
    public static let compactDividerHeight: CGFloat = 1
    public static let compactBottomInset: CGFloat = 16
    public static let enterPace: TalariaMotionTokens.Pace = .standard
    public static let dismissPace: TalariaMotionTokens.Pace = .fast

    public enum Layout: Equatable, Sendable {
        case tiles
        case rows
    }

    /// Normal text fits three actions into one compact palette row. VoiceOver
    /// and accessibility Dynamic Type use full-width rows so titles and detail
    /// copy never compete with a narrow tile.
    public static func layout(isAccessibilitySize: Bool) -> Layout {
        isAccessibilitySize ? .rows : .tiles
    }

    /// The largest non-Accessibility Dynamic Type tiers are already too wide
    /// for a three-column tile to keep its title and detail copy readable. Move
    /// them to the same measured row treatment before the `isAccessibilitySize`
    /// boundary, so the compact detent never clips scaled tile content.
    public static func layout(dynamicTypeSize: DynamicTypeSize) -> Layout {
        switch dynamicTypeSize {
        case .xxLarge, .xxxLarge:
            .rows
        default:
            layout(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
        }
    }

    /// The grid is deliberately capped at three columns. A two-item menu uses
    /// two wider tiles, while the normal three-item menu remains a true palette
    /// instead of becoming a stack of oversized rows.
    public static func tileColumnCount(optionCount: Int) -> Int {
        min(3, max(1, optionCount))
    }

    public static func tileRowCount(optionCount: Int, columns: Int? = nil) -> Int {
        let count = max(1, optionCount)
        let columnCount = max(1, min(columns ?? tileColumnCount(optionCount: count), count))
        return Int(ceil(Double(count) / Double(columnCount)))
    }

    /// The custom detent below uses this finite content estimate instead of the
    /// oversized medium detent. The accessibility branch intentionally uses
    /// the system large detent because scaled labels can grow beyond a
    /// deterministic row estimate.
    public static func compactDetentHeight(optionCount: Int, columns: Int? = nil) -> CGFloat {
        let rows = CGFloat(tileRowCount(optionCount: optionCount, columns: columns))
        let gaps = max(0, rows - 1) * tileSpacing
        return compactHeaderHeight
            + compactDividerHeight
            + verticalPadding * 2
            + rows * minimumTileHeight
            + gaps
            + compactBottomInset
    }

    public static func enterAnimation(reducedMotion: Bool) -> Animation? {
        TalariaMotionTokens.spatialAnimation(enterPace, reducedMotion: reducedMotion)
    }

    public static func dismissAnimation(reducedMotion: Bool) -> Animation? {
        TalariaMotionTokens.spatialAnimation(dismissPace, reducedMotion: reducedMotion)
    }

    /// Only advertise sources the presenter can actually open. Keeping this
    /// explicit avoids a dead Photo Library row on targets without PhotosUI.
    public static func options(
        supportsPhotoLibrary: Bool = false,
        allowsPaste: Bool
    ) -> [AttachmentSourceOption] {
        var result: [AttachmentSourceOption] = []
        if supportsPhotoLibrary {
            result.append(AttachmentSourceOption(
                action: .photos,
                title: "Photo Library",
                detail: "Choose up to 6 photos",
                systemImage: "photo.on.rectangle.angled"
            ))
        }
        result.append(
            AttachmentSourceOption(
                action: .files,
                title: "Files",
                detail: "Browse files and documents",
                systemImage: "folder"
            )
        )
        if allowsPaste {
            result.append(AttachmentSourceOption(
                action: .pasteImage,
                title: "Paste Image",
                detail: "Use an image from the clipboard",
                systemImage: "doc.on.clipboard"
            ))
        }
        return result
    }
}

/// Custom fitted detents are available on iOS 16/macOS 13, below Talaria's
/// iOS 17/macOS 14 floor. The finite source set always fits one normal palette
/// row, so the detent can stay stable while still respecting a short window.
private struct AttachmentSourceCompactDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        min(
            AttachmentSourcePresentation.compactDetentHeight(optionCount: 3),
            context.maxDetentValue
        )
    }
}

/// Talaria-owned source chooser. The actual photo and document surfaces remain
/// Apple's system pickers; this sheet only replaces the cramped action menu.
public struct AttachmentSourceSheet: View {
    public let theme: ThemePack
    public let supportsPhotoLibrary: Bool
    public let allowsPaste: Bool
    public let select: (AttachmentSourceAction) -> Void
    public let close: () -> Void

    @Environment(\.talariaReducedMotion) private var reducedMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var headingSize: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var rowTitleSize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption) private var detailSize: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var iconSide: CGFloat = 38
    @AccessibilityFocusState private var headingFocused: Bool
    @State private var contentVisible = false

    public init(
        theme: ThemePack,
        supportsPhotoLibrary: Bool = false,
        allowsPaste: Bool = true,
        select: @escaping (AttachmentSourceAction) -> Void,
        close: @escaping () -> Void
    ) {
        self.theme = theme
        self.supportsPhotoLibrary = supportsPhotoLibrary
        self.allowsPaste = allowsPaste
        self.select = select
        self.close = close
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(AttachmentSourcePresentation.title)
                    .font(theme.body(headingSize, weight: .bold))
                    .foregroundStyle(theme.ink)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($headingFocused)
                Spacer()
                Button(action: closeSheet) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 44, height: 44)
                        .background(theme.inset, in: Circle())
                        .overlay(Circle().strokeBorder(theme.line, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close attachment options")
            }
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Rectangle().fill(theme.line).frame(height: 1)

            sourceContent
        }
        .foregroundStyle(theme.ink)
        .background(theme.bg.ignoresSafeArea())
        .presentationDetents(layout == .rows
            ? [.large]
            : [.custom(AttachmentSourceCompactDetent.self)])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
        .presentationBackground(theme.bg)
        .opacity(reducedMotion || contentVisible ? 1 : 0)
        .offset(y: reducedMotion || contentVisible ? 0 : 8)
        .transaction { transaction in
            if reducedMotion { transaction.animation = nil }
        }
        .onAppear {
            headingFocused = true
            withAnimation(AttachmentSourcePresentation.enterAnimation(reducedMotion: reducedMotion)) {
                contentVisible = true
            }
        }
    }

    private var options: [AttachmentSourceOption] {
        AttachmentSourcePresentation.options(
            supportsPhotoLibrary: supportsPhotoLibrary,
            allowsPaste: allowsPaste
        )
    }

    private var layout: AttachmentSourcePresentation.Layout {
        AttachmentSourcePresentation.layout(dynamicTypeSize: dynamicTypeSize)
    }

    @ViewBuilder
    private var sourceContent: some View {
        switch layout {
        case .tiles:
            // The custom detent can be capped by a short landscape or
            // multitasking window. Keep every action reachable without
            // introducing bounce in the normal fitted portrait case.
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(minimum: AttachmentSourcePresentation.minimumTouchTarget),
                                                       spacing: AttachmentSourcePresentation.tileSpacing),
                                  count: AttachmentSourcePresentation.tileColumnCount(optionCount: options.count)),
                    spacing: AttachmentSourcePresentation.tileSpacing
                ) {
                    ForEach(options) { option in
                        sourceTile(option)
                    }
                }
                .padding(.horizontal, AttachmentSourcePresentation.horizontalPadding)
                .padding(.vertical, AttachmentSourcePresentation.verticalPadding)
            }
            .scrollBounceBehavior(.basedOnSize)

        case .rows:
            ScrollView {
                VStack(spacing: AttachmentSourcePresentation.tileSpacing) {
                    ForEach(options) { option in
                        sourceRow(option)
                    }
                }
                .padding(.horizontal, AttachmentSourcePresentation.horizontalPadding)
                .padding(.vertical, AttachmentSourcePresentation.verticalPadding)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func sourceTile(_ option: AttachmentSourceOption) -> some View {
        Button { choose(option.action) } label: {
            VStack(spacing: 7) {
                Image(systemName: option.systemImage)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: iconSide, height: iconSide)
                    .background(theme.accent.opacity(0.12), in: iconShape)
                    .accessibilityHidden(true)

                Text(option.title)
                    .font(theme.body(rowTitleSize, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                Text(option.detail)
                    .font(theme.body(detailSize))
                    .foregroundStyle(theme.faint)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: AttachmentSourcePresentation.minimumTileHeight)
            .background(theme.panel, in: tileShape)
            .overlay(tileShape.strokeBorder(theme.line, lineWidth: 1))
            .contentShape(tileShape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.title)
        .accessibilityHint(option.detail)
    }

    private func sourceRow(_ option: AttachmentSourceOption) -> some View {
        Button { choose(option.action) } label: {
            HStack(spacing: 14) {
                Image(systemName: option.systemImage)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: iconSide, height: iconSide)
                    .background(theme.accent.opacity(0.12), in: iconShape)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(theme.body(rowTitleSize, weight: .semibold))
                        .foregroundStyle(theme.ink)
                    Text(option.detail)
                        .font(theme.body(detailSize))
                        .foregroundStyle(theme.faint)
                }
                .multilineTextAlignment(.leading)

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.faint)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: AttachmentSourcePresentation.minimumRowHeight,
                   alignment: .leading)
            .background(theme.panel, in: rowShape)
            .overlay(rowShape.strokeBorder(theme.line, lineWidth: 1))
            .contentShape(rowShape)
        }
        .buttonStyle(.plain)
        // The button supplies its label and hint below. Ignoring the visual
        // children prevents VoiceOver from announcing the title/detail twice.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.title)
        .accessibilityHint(option.detail)
    }

    private func choose(_ action: AttachmentSourceAction) {
        // The parent owns the sheet binding and its system presentation
        // animator. This quick transaction is the native hint for the state
        // handoff; it does not promise to replace that outer system timing.
        withAnimation(AttachmentSourcePresentation.dismissAnimation(reducedMotion: reducedMotion)) {
            select(action)
        }
    }

    private func closeSheet() {
        // As above, keep the close hint local to the state mutation and let
        // SwiftUI own the sheet's actual dismissal curve.
        withAnimation(AttachmentSourcePresentation.dismissAnimation(reducedMotion: reducedMotion)) {
            close()
        }
    }

    private var rowShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: max(12, min(theme.cardRadius, 20)), style: .continuous)
    }

    private var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: max(12, min(theme.cardRadius, 20)), style: .continuous)
    }

    private var iconShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: max(8, iconSide * theme.iconCornerFraction), style: .continuous)
    }
}
