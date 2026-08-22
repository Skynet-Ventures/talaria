import Foundation
import SwiftUI
import TalariaKit
import TalariaTheme
#if canImport(UIKit)
import UIKit
#endif

/// Presentation facts for a terminal assistant-turn failure. Keeping these
/// outside the view makes the action matrix, accessibility copy, and hostile
/// payload bounds independently testable.
public enum FailedTurnCardPolicy {
    public enum Action: String, CaseIterable, Sendable {
        case retry, settings, copy, dismiss
    }

    public enum ActionLayout: Sendable, Equatable {
        case wrapping
        case vertical
    }

    public static let controlHitTarget: CGFloat = 44
    public static let maximumDisplayedErrorScalars = 8_192
    public static let maximumSpokenErrorScalars = 512

    public static func title(for surface: TurnErrorSurface?) -> String {
        guard let layer = surface?.layer else { return "Turn failed" }
        switch layer {
        case .provider: return "Provider error"
        case .endpoint: return "Custom endpoint error"
        case .streaming: return "Streaming connection error"
        case .auth: return "Authentication error"
        case .billing: return "Out of credits"
        case .gateway: return "Gateway error"
        case .runtime: return "Local runtime error"
        case .disk: return "Disk full"
        }
    }

    public static func showsSettings(for surface: TurnErrorSurface?) -> Bool {
        guard let layer = surface?.layer else { return false }
        return [.provider, .endpoint, .auth, .billing].contains(layer)
    }

    /// `canRetry` includes exact-session/lifecycle availability. The
    /// classifier's deterministic verdict remains authoritative even when a
    /// stale caller accidentally says the action is available.
    public static func actions(for failure: TurnFailure, canRetry: Bool,
                               canDismiss: Bool = true) -> [Action] {
        var result: [Action] = []
        if canRetry, failure.errorSurface?.retryable != false { result.append(.retry) }
        if showsSettings(for: failure.errorSurface) { result.append(.settings) }
        result.append(.copy)
        if canDismiss { result.append(.dismiss) }
        return result
    }

    public static func actionLayout(isAccessibilitySize: Bool) -> ActionLayout {
        isAccessibilitySize ? .vertical : .wrapping
    }

    public static func allowsOrdinaryAssistantActions(for failure: TurnFailure?) -> Bool {
        failure == nil
    }

    public static func identity(for surface: TurnErrorSurface?) -> String? {
        guard let surface else { return nil }
        return [surface.provider, surface.model]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
            .nilIfEmpty
    }

    /// Cap before rendering or copying so one gateway error cannot create an
    /// unbounded Text layout. Unicode-scalar prefixing also avoids Character's
    /// combining-grapheme work on hostile input.
    public static func displayedMessage(_ message: String) -> String {
        let prefix = message.unicodeScalars.prefix(maximumDisplayedErrorScalars + 1)
        guard prefix.count > maximumDisplayedErrorScalars else { return message }
        return String(prefix.prefix(maximumDisplayedErrorScalars)) + "\n…error detail truncated"
    }

    public static func accessibilitySummary(for failure: TurnFailure) -> String {
        let title = title(for: failure.errorSurface)
        let identity = identity(for: failure.errorSurface)
        let spoken = failure.message.unicodeScalars.prefix(maximumSpokenErrorScalars + 1)
        let detail = spoken.count > maximumSpokenErrorScalars
            ? String(spoken.prefix(maximumSpokenErrorScalars)) + ". Error detail truncated"
            : failure.message
        return [title, identity, detail].compactMap { $0?.nilIfEmpty }.joined(separator: ". ")
    }

    public static func accessibilityLabel(for action: Action, copied: Bool = false) -> String {
        switch action {
        case .retry: return "Retry failed turn"
        case .settings: return "Open Settings"
        case .copy: return copied ? "Error details copied" : "Copy error details"
        case .dismiss: return "Dismiss error"
        }
    }

    /// Error prose is gateway-controlled. Keep it visibly inside one field in
    /// copied diagnostics so embedded line breaks cannot impersonate trusted
    /// `provider:`, `model:`, or `retryable:` metadata.
    public static func escapedDiagnosticsField(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(maximumDisplayedErrorScalars)
        for scalar in displayedMessage(value).unicodeScalars {
            switch scalar.value {
            case 0x5C: escaped += "\\\\"
            case 0x0A: escaped += "\\n"
            case 0x0D: escaped += "\\r"
            case 0x85, 0x2028, 0x2029:
                escaped += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    public static func diagnostics(for failure: TurnFailure,
                                   appVersion: String? = nil,
                                   now: Date = Date()) -> String {
        let surface = failure.errorSurface
        var lines = [
            "── Hermes error details ──",
            "time: \(ISO8601DateFormatter().string(from: now))",
        ]
        if let surface {
            lines.append("layer: \(surface.layer.rawValue)")
            lines.append("code: \(surface.code)")
            lines.append("retryable: \(surface.retryable)")
            if let provider = surface.provider { lines.append("provider: \(provider)") }
            if let model = surface.model { lines.append("model: \(model)") }
        }
        if let appVersion, !appVersion.isEmpty { lines.append("app: \(appVersion)") }
        lines.append("error: \(escapedDiagnosticsField(failure.message))")
        return lines.joined(separator: "\n")
    }
}

/// Same-turn recovery card. The transcript owns the actual lifecycle verbs;
/// this component only presents explicit closures so it cannot mutate a
/// gateway or accidentally act on a different session.
public struct FailedTurnCard: View {
    private let failure: TurnFailure
    private let theme: ThemePack
    private let canRetry: Bool
    private let canDismiss: Bool
    private let retry: () -> Void
    private let dismiss: () -> Void
    private let openSettings: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var copied = false

    public init(failure: TurnFailure, theme: ThemePack, canRetry: Bool, canDismiss: Bool,
                retry: @escaping () -> Void,
                dismiss: @escaping () -> Void,
                openSettings: @escaping () -> Void) {
        self.failure = failure
        self.theme = theme
        self.canRetry = canRetry
        self.canDismiss = canDismiss
        self.retry = retry
        self.dismiss = dismiss
        self.openSettings = openSettings
    }

    private var actions: [FailedTurnCardPolicy.Action] {
        FailedTurnCardPolicy.actions(
            for: failure, canRetry: canRetry, canDismiss: canDismiss)
            .filter { $0 != .dismiss }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.danger)
                    .accessibilityHidden(true)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(FailedTurnCardPolicy.title(for: failure.errorSurface))
                        .font(.headline)
                        .foregroundStyle(theme.ink)
                    if let identity = FailedTurnCardPolicy.identity(for: failure.errorSurface) {
                        Text(identity)
                            .font(.caption)
                            .foregroundStyle(theme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Collapse the visible title, identity, and error detail into
                // the bounded spoken projection. The action buttons remain
                // independent VoiceOver elements below.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(
                    FailedTurnCardPolicy.accessibilitySummary(for: failure)))
                .accessibilityAddTraits(.isHeader)
                if canDismiss {
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: FailedTurnCardPolicy.controlHitTarget,
                                   height: FailedTurnCardPolicy.controlHitTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.danger)
                    .accessibilityLabel(Text("Dismiss error"))
                }
            }

            Text(FailedTurnCardPolicy.displayedMessage(failure.message))
                .font(.body)
                .foregroundStyle(theme.ink.opacity(0.84))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityHidden(true)

            actionStrip
        }
        .padding(.leading, 13)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.danger.opacity(theme.id == .ink ? 0.04 : 0.07),
                    in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                .strokeBorder(theme.danger.opacity(0.34), lineWidth: 1)
        }
    }

    @ViewBuilder private var actionStrip: some View {
        if FailedTurnCardPolicy.actionLayout(
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) == .vertical {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(actions, id: \.rawValue) { actionButton($0, fillWidth: true) }
            }
        } else {
            FailedTurnActionFlow(spacing: 6) {
                ForEach(actions, id: \.rawValue) { actionButton($0, fillWidth: false) }
            }
        }
    }

    private func actionButton(_ action: FailedTurnCardPolicy.Action,
                              fillWidth: Bool) -> some View {
        Button {
            switch action {
            case .retry: retry()
            case .settings: openSettings()
            case .copy:
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                copyToPasteboard(FailedTurnCardPolicy.diagnostics(
                    for: failure, appVersion: version))
                copied = true
            case .dismiss: dismiss()
            }
        } label: {
            Label(actionLabel(action), systemImage: actionSymbol(action))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.danger)
                .padding(.horizontal, 11)
                .frame(maxWidth: fillWidth ? .infinity : nil,
                       minHeight: FailedTurnCardPolicy.controlHitTarget,
                       alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(theme.danger.opacity(0.06),
                    in: Capsule())
        .overlay(Capsule().strokeBorder(theme.danger.opacity(0.25), lineWidth: 1))
        .accessibilityLabel(Text(FailedTurnCardPolicy.accessibilityLabel(
            for: action, copied: copied)))
    }

    private func actionLabel(_ action: FailedTurnCardPolicy.Action) -> String {
        switch action {
        case .retry: "Retry"
        case .settings: "Settings"
        case .copy: copied ? "Copied" : "Copy"
        case .dismiss: "Dismiss"
        }
    }

    private func actionSymbol(_ action: FailedTurnCardPolicy.Action) -> String {
        switch action {
        case .retry: "arrow.clockwise"
        case .settings: "gearshape"
        case .copy: copied ? "checkmark" : "doc.on.doc"
        case .dismiss: "xmark"
        }
    }
}

private struct FailedTurnActionFlow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
