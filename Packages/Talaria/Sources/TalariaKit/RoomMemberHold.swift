import Foundation

public enum RoomMemberHoldInterruptState: String, Codable, Sendable {
    case notNeeded
    case pending
    case confirmed
    case alreadyIdle
    case staleAuthority
    case failed
    case ambiguous
}

/// Sticky, local room-driving authority. The enclosing RoomRecord supplies the
/// immutable RoomID; route plus hold id identifies one exact membership
/// instance until explicit removal/resume migrates or retires it.
public struct RoomMemberHold: Codable, Hashable, Sendable, Identifiable {
    public static let maximumReasonScalars = 256
    public static let maximumReasonUTF8Bytes = 1_024
    public static let maximumSessionIDScalars = 512

    public let id: UUID
    public var member: GatewayBotRoute
    public let driveEpoch: UInt64
    public let threadID: RoomThreadID?
    public let attemptID: RoomAttemptID?
    public let storedSessionID: String?
    public let runtimeSessionID: String?
    public var connectionGeneration: UInt64?
    public var interruptState: RoomMemberHoldInterruptState
    public let reason: String
    public let createdAt: Date
    public var updatedAt: Date
    public var lastNotedEpoch: UInt64?

    public init(id: UUID = UUID(), member: GatewayBotRoute, driveEpoch: UInt64,
                threadID: RoomThreadID? = nil, attemptID: RoomAttemptID? = nil,
                storedSessionID: String? = nil, runtimeSessionID: String? = nil,
                connectionGeneration: UInt64? = nil,
                interruptState: RoomMemberHoldInterruptState = .notNeeded,
                reason: String = "Held by you", createdAt: Date = Date(),
                updatedAt: Date? = nil, lastNotedEpoch: UInt64? = nil) {
        self.id = id; self.member = member; self.driveEpoch = driveEpoch
        self.threadID = threadID; self.attemptID = attemptID
        self.storedSessionID = storedSessionID
        self.runtimeSessionID = runtimeSessionID
        self.connectionGeneration = connectionGeneration
        self.interruptState = interruptState
        self.reason = Self.boundedReason(reason)
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
        self.lastNotedEpoch = lastNotedEpoch
    }

    public static func boundedReason(_ value: String) -> String {
        var output = String.UnicodeScalarView()
        var bytes = 0
        for scalar in value.unicodeScalars.prefix(maximumReasonScalars) {
            let count = String(scalar).utf8.count
            guard bytes + count <= maximumReasonUTF8Bytes else { break }
            output.append(scalar); bytes += count
        }
        let result = String(output).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Held by you" : result
    }

    public func isStructurallyValid(activeMembers: Set<GatewayBotRoute>,
                                    threadIDs: Set<RoomThreadID>) -> Bool {
        activeMembers.contains(member)
            && GatewayBotRoute(qualifiedID: member.qualifiedID) == member
            && Self.boundedReason(reason) == reason
            && (threadID.map(threadIDs.contains) ?? true)
            && (storedSessionID.map(Self.validSessionID) ?? true)
            && (runtimeSessionID.map(Self.validSessionID) ?? true)
            && ((attemptID == nil) == (threadID == nil))
            && (connectionGeneration == nil || attemptID != nil)
            && ((attemptID == nil && storedSessionID == nil && runtimeSessionID == nil)
                || (attemptID != nil && storedSessionID != nil && runtimeSessionID != nil))
    }

    private static func validSessionID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed == value
            && value.unicodeScalars.count <= maximumSessionIDScalars
    }
}
