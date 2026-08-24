import Foundation

/// Local-only room composer text. The immutable RoomID is the sole identity:
/// display names and member routes are deliberately absent so a rename keeps
/// the draft while a same-name replacement cannot inherit it.
public struct RoomComposerDraft: Codable, Equatable, Sendable {
    public let roomID: RoomID
    public let text: String

    public init(roomID: RoomID, text: String) {
        self.roomID = roomID
        self.text = text
    }
}

public enum RoomComposerDraftPolicy {
    public static let maximumScalars = 4_096
    public static let maximumUTF8Bytes = 16_384
    public static let maximumDraftCount = 128
    public static let maximumStoredUTF8Bytes = 1_048_576

    /// Preserve the user's exact whitespace and scalar sequence while fitting
    /// both independent limits. Scalar iteration never persists a partial
    /// UTF-8 code unit sequence.
    public static func bounded(_ value: String) -> String {
        guard value.unicodeScalars.count > maximumScalars
                || value.utf8.count > maximumUTF8Bytes else { return value }
        var result = String.UnicodeScalarView()
        var bytes = 0
        for scalar in value.unicodeScalars.prefix(maximumScalars) {
            let scalarBytes = String(scalar).utf8.count
            guard bytes + scalarBytes <= maximumUTF8Bytes else { break }
            result.append(scalar)
            bytes += scalarBytes
        }
        return String(result)
    }

    public static func admits(_ draft: RoomComposerDraft) -> Bool {
        !draft.text.isEmpty && bounded(draft.text) == draft.text
    }

    public static func admits(_ drafts: [RoomComposerDraft]) -> Bool {
        drafts.count <= maximumDraftCount
            && Set(drafts.map(\.roomID)).count == drafts.count
            && drafts.allSatisfy(admits)
            && drafts.reduce(0, { $0 + $1.text.utf8.count }) <= maximumStoredUTF8Bytes
    }
}

/// Pure completion rule shared by the SwiftUI composer and deterministic
/// tests. A successful send clears only the exact submitted snapshot; failure
/// or newer text preserves the current draft.
public enum RoomComposerDraftCompletionPolicy {
    public static func result(current: String, submitted: String,
                              sendSucceeded: Bool) -> String {
        sendSucceeded && current == submitted ? "" : current
    }
}
