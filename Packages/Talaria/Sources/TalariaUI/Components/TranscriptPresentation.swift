import SwiftUI
import TalariaKit
import TalariaTheme

/// Device-local transcript presentation. This deliberately does not mirror
/// Hermes' `details_mode` or `reasoning` configuration: changing it never
/// changes what the gateway records, what another client sees, or how a model
/// reasons. Talaria keeps every event and can reveal it immediately.
public struct TranscriptPresentationPolicy: Sendable, Equatable {
    public enum Detail: String, CaseIterable, Sendable, Identifiable {
        case quiet
        case advanced

        public var id: String { rawValue }
    }

    public var detail: Detail

    public init(detail: Detail) { self.detail = detail }

    public func showsReasoning(isLive _: Bool) -> Bool {
        detail == .advanced
    }

    /// Quiet mode is avatar-only while work is active. Every tool detail,
    /// including failures, remains in the model and appears immediately when
    /// Advanced is enabled; none of it competes with the bot-focused view.
    public func visibleToolCalls(_ calls: [ToolCall]) -> [ToolCall] {
        detail == .quiet ? [] : calls
    }

    /// A quiet transcript always uses the face as its busy affordance.
    /// Advanced mode uses it only before any live reasoning/tool row exists,
    /// avoiding two simultaneous indicators for the same work.
    public func showsWorkingAvatar(isTurnRunning: Bool, hasLiveDetail: Bool) -> Bool {
        guard isTurnRunning else { return false }
        return detail == .quiet || !hasLiveDetail
    }
}

/// Layout facts kept outside SwiftUI's view tree so narrow-phone and Dynamic
/// Type behavior are testable without snapshots. The toolbar is a separate
/// row, so its controls never subtract from the editor allocation.
public enum ChatComposerLayoutPolicy {
    public static let controlHitTarget: CGFloat = 44

    public static func maxEditorLines(isAccessibilitySize: Bool) -> Int {
        isAccessibilitySize ? 4 : 6
    }

    public static func editorWidth(containerWidth: CGFloat, horizontalInsets: CGFloat) -> CGFloat {
        max(0, containerWidth - horizontalInsets * 2)
    }

    public static func animation(reducedMotion: Bool, duration: Double) -> Animation? {
        reducedMotion ? nil : .easeOut(duration: duration)
    }
}

public enum TranscriptMotionPolicy {
    /// A static partial arc still communicates "running" without continuous
    /// rotation when the device/app requests reduced motion.
    public static func toolSpinnerDegrees(spinning: Bool, reducedMotion: Bool) -> Double {
        reducedMotion ? 45 : (spinning ? 360 : 0)
    }
}

public enum ChatComposerAction: Sendable, Equatable {
    case disabled
    case palette
    case slash
    case submit
    case steer
    case stop
}

public enum ChatComposerActionPolicy {
    public static func action(draft: String, attachmentCount: Int, isTurnRunning: Bool,
                              hasUnresolvedFailedTurnRetry: Bool = false) -> ChatComposerAction {
        let text = draft.trimmingCharacters(in: .whitespaces)
        let hasPayload = !text.isEmpty || attachmentCount > 0
        // An unresolved Retry owns the next same-session lifecycle event. Keep
        // Stop available for that operation, but never present a draft or
        // attachment as sendable until its ownership is settled.
        if hasUnresolvedFailedTurnRetry, hasPayload { return .disabled }
        if text == "/" { return .palette }
        if text.hasPrefix("/") { return .slash }
        // session.steer requires text. An attachment-only payload would fall
        // through to prompt.submit, so it stays staged and the button remains
        // Stop until the current turn settles.
        if isTurnRunning { return text.isEmpty ? .stop : .steer }
        return hasPayload ? .submit : .disabled
    }
}

/// Chat transcript scrolling facts. A long LazyVStack only measures the
/// rows near the current estimated offset, so anchoring to a trailing spacer
/// can land on a blank region until the user drags. Eager stacks stay fully
/// measured; lazy stacks scroll to the last real message (or the working
/// avatar) across a few layout passes.
public enum ChatTranscriptLayoutPolicy {
    public static let eagerStackLimit = 64
    public static let layoutPassesMs: [UInt64] = [16, 120, 360]
    public static let workingAnchorID = "chat-working"
    public static let emptyAnchorID = "chat-bottom"

    public static func usesLazyStack(messageCount: Int) -> Bool {
        messageCount > eagerStackLimit
    }

    public static func anchorID(lastMessageID: UUID?, showingWorkingAvatar: Bool) -> String {
        // The working row is a real, measured LazyVStack child. Never target
        // the trailing geometry probe for a live turn: on a long transcript
        // SwiftUI can satisfy that estimated spacer offset before measuring
        // the tail rows, leaving the entire viewport blank until a drag.
        if showingWorkingAvatar { return workingAnchorID }
        if let lastMessageID { return lastMessageID.uuidString }
        return emptyAnchorID
    }

    /// How far from the latest row still counts as "following" the live turn.
    public static let followBottomSlop: CGFloat = 120

    public static func isFollowingLatest(distanceFromBottom: CGFloat) -> Bool {
        distanceFromBottom <= followBottomSlop
    }

    public static func showsJumpControl(isFollowingLatest: Bool, messageCount: Int) -> Bool {
        !isFollowingLatest && messageCount > 0
    }
}

/// Interactive pop for the custom chat overlay. Talaria does not use a
/// NavigationStack for bot chats, so iOS never installs its system edge
/// gesture. These thresholds match that gesture closely enough to feel native
/// without stealing horizontal scrolls from the transcript.
public enum ChatSwipeBackPolicy {
    public static let edgeWidth: CGFloat = 28
    public static let minimumDistance: CGFloat = 16
    public static let commitFraction: CGFloat = 0.28
    public static let commitVelocity: CGFloat = 720

    public static func shouldBegin(startX: CGFloat) -> Bool {
        startX <= edgeWidth
    }

    public static func shouldCommit(translationX: CGFloat, predictedX: CGFloat,
                                    containerWidth: CGFloat) -> Bool {
        let width = max(containerWidth, 1)
        return translationX >= width * commitFraction || predictedX >= commitVelocity
    }
}

/// The compact Grok-style activity affordance. A generated portrait stays
/// still, while the canonical geometric face receives `isWorking` and owns
/// its normal animation/reduced-motion behavior.
struct TranscriptWorkingAvatar: View {
    var model: AppModel?
    var bot: Bot?
    var fallbackHue: AvatarHue = .violet
    var theme: ThemePack
    var label: String

    @Environment(\.talariaReducedMotion) private var reducedMotion
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 7) {
            avatar
            Text(label)
                .font(theme.id == .soft ? theme.body(11, weight: .medium) : theme.mono(9))
                .foregroundStyle(theme.faint)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var avatar: some View {
        Group {
            if let model, let bot {
                BotPortraitView(model: model, bot: bot, size: 28, theme: theme, isWorking: true)
                    .overlay(alignment: .bottomTrailing) {
                        PetCompanionView(model: model, bot: bot)
                            .offset(x: 2, y: 1)
                    }
            } else {
                AvatarView(shape: .squircle, hue: fallbackHue, size: 28,
                           isWorking: true, theme: theme, identity: "talaria-solo")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(theme.accent)
                .frame(width: 7, height: 7)
                .overlay(Circle().stroke(theme.bg, lineWidth: 1.5))
                .scaleEffect(reducedMotion ? 1 : (pulsing ? 1.18 : 0.72))
                .opacity(reducedMotion ? 0.75 : (pulsing ? 1 : 0.45))
                .animation(reducedMotion ? nil
                           : .easeInOut(duration: 0.65).repeatForever(autoreverses: true),
                           value: pulsing)
        }
        .onAppear { pulsing = !reducedMotion }
        .onChange(of: reducedMotion) { _, reduced in pulsing = !reduced }
    }
}
