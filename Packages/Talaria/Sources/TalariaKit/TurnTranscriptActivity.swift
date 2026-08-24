import Foundation

/// Current-process presentation state for the exact live assistant turn.
/// It is deliberately absent from transcript persistence: stored history has
/// no authority to reconstruct when an already-finished turn was quiet.
public struct TurnTranscriptActivity: Sendable, Equatable {
    public enum PhaseKind: String, Sendable, Equatable {
        case compacting
        case draftingTool
        case providerWait
    }

    public struct Phase: Sendable, Equatable {
        public var kind: PhaseKind
        public var label: String
        public var startedAt: Date

        public init(kind: PhaseKind, label: String, startedAt: Date) {
            self.kind = kind
            self.label = label
            self.startedAt = startedAt
        }
    }

    public var isActive = false
    public var hasVisibleProgress = false
    public var lastVisibleProgressAt: Date?
    public var phase: Phase?

    public init() {}

    public mutating func begin(at date: Date, replacingExisting: Bool) {
        guard replacingExisting || !isActive else { return }
        isActive = true
        hasVisibleProgress = false
        lastVisibleProgressAt = date
        phase = nil
    }

    public mutating func recordVisibleProgress(at date: Date) {
        guard isActive else { return }
        hasVisibleProgress = true
        lastVisibleProgressAt = date
        phase = nil
    }

    public mutating func namePhase(_ kind: PhaseKind, label: String,
                                   startedAt: Date) {
        guard isActive,
              let label = TurnTranscriptActivityPolicy.admittedLabel(label) else { return }
        if phase?.kind == kind, phase?.label == label { return }
        phase = Phase(kind: kind, label: label, startedAt: startedAt)
    }

    public mutating func clearPhase() {
        phase = nil
    }

    public mutating func clear() {
        self = TurnTranscriptActivity()
    }
}

public enum TurnTranscriptActivityPolicy {
    public static let quietDelay: TimeInterval = 2
    public static let draftingRevealDelay: TimeInterval = 0.2
    public static let maximumLabelScalars = 160

    public enum PresentationKind: Sendable, Equatable {
        case awaitingResponse
        case named(TurnTranscriptActivity.PhaseKind)
        case quietGap
    }

    public struct Presentation: Sendable, Equatable {
        public var kind: PresentationKind
        public var label: String?
        public var startedAt: Date

        public init(kind: PresentationKind, label: String?, startedAt: Date) {
            self.kind = kind
            self.label = label
            self.startedAt = startedAt
        }
    }

    /// Desktop accepts only its explained wait frames; spinner rewrites stay
    /// presentation noise. Preserve the admitted original wording for parity.
    public static func providerWaitLabel(_ raw: String) -> String? {
        guard let value = admittedLabel(raw) else { return nil }
        let lower = value.lowercased()
        let prefixes = [
            "⏳ waiting on", "⏳ no output", "⏳ no response", "⏳ model returned",
            "⚠ waiting on", "⚠ no output", "⚠ no response", "⚠ model returned",
            "↻ waiting on", "↻ no output", "↻ no response", "↻ model returned",
        ]
        return prefixes.contains(where: { lower.hasPrefix($0) }) ? value : nil
    }

    public static func draftingLabel(toolName: String) -> String? {
        admittedLabel(toolName).map { "Preparing \($0)" }
    }

    public static func presentation(
        activity: TurnTranscriptActivity,
        turnStartedAt: Date?,
        now: Date,
        isTurnRunning: Bool,
        isAwaitingInput: Bool,
        toolNarratesWait: Bool
    ) -> Presentation? {
        guard activity.isActive, isTurnRunning, !isAwaitingInput,
              !toolNarratesWait else { return nil }

        if let phase = activity.phase {
            let revealDelay = phase.kind == .draftingTool ? draftingRevealDelay : 0
            guard now.timeIntervalSince(phase.startedAt) >= revealDelay else { return nil }
            let origin = phase.kind == .compacting
                ? (turnStartedAt ?? phase.startedAt) : phase.startedAt
            return Presentation(kind: .named(phase.kind), label: phase.label,
                                startedAt: origin)
        }

        if !activity.hasVisibleProgress {
            return Presentation(kind: .awaitingResponse, label: nil,
                                startedAt: turnStartedAt
                                    ?? activity.lastVisibleProgressAt ?? now)
        }

        guard let last = activity.lastVisibleProgressAt,
              now.timeIntervalSince(last) >= quietDelay else { return nil }
        return Presentation(kind: .quietGap, label: nil, startedAt: last)
    }

    public static func admittedLabel(_ raw: String) -> String? {
        var output = String.UnicodeScalarView()
        var previousWasSpace = false
        for scalar in raw.unicodeScalars {
            let value = scalar.value
            if value < 0x20 || value == 0x7F || (0x80...0x9F).contains(value)
                || value == 0x061C || value == 0x200E || value == 0x200F
                || (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value) {
                if scalar == "\n" || scalar == "\r" || scalar == "\t" {
                    if !previousWasSpace { output.append(" "); previousWasSpace = true }
                }
                continue
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !previousWasSpace { output.append(" "); previousWasSpace = true }
            } else {
                output.append(scalar)
                previousWasSpace = false
            }
            if output.count >= maximumLabelScalars { break }
        }
        let value = String(output).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
