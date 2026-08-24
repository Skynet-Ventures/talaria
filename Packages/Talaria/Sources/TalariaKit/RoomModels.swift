import CryptoKit
import Foundation

// Room identity is intentionally independent from a display name. Renaming a
// room cannot re-key its transcript, attachments, sessions, or open view.
public struct RoomID: Codable, Hashable, Sendable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID
    public var id: UUID { rawValue }
    public var description: String { rawValue.uuidString.lowercased() }

    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct RoomThreadID: Codable, Hashable, Sendable, Identifiable {
    public let rawValue: UUID
    public var id: UUID { rawValue }
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct RoomEntryID: Codable, Hashable, Sendable, Identifiable {
    public let rawValue: UUID
    public var id: UUID { rawValue }
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct RoomAttemptID: Codable, Hashable, Sendable, Identifiable {
    public let rawValue: UUID
    public var id: UUID { rawValue }
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct RoomActivityID: Codable, Hashable, Sendable, Identifiable {
    public let rawValue: UUID
    public var id: UUID { rawValue }
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// A seat is always source-qualified. Bare profile names are never durable
/// room identity because two retained gateways may both expose `default`.
public struct RoomMember: Codable, Hashable, Sendable, Identifiable {
    public let route: GatewayBotRoute
    public var title: String?
    /// The durable raw friendly identity captured when this seat was selected.
    /// It survives a later roster disappearance so room mentions keep the
    /// same `@research-buddy` spelling instead of falling back to a mutable
    /// profile handle or a themed visual label.
    public var friendlyName: String?
    /// Core profile `display_name` captured independently of Bot Mode's
    /// friendly title. Both remain valid room aliases after the roster vanishes.
    public var rawDisplayName: String?
    public var handle: String
    public var sourceLabel: String?
    /// Exact Desktop projection connection id. It is retained independently
    /// from routing authority so a client-local source slug can round-trip
    /// without being mistaken for a configured Talaria gateway.
    public var rawProjectionConnectionID: String?
    /// A projected seat whose source id is not an exact configured gateway on
    /// this device. Frozen seats remain visible transcript identity but are
    /// never eligible for responder scheduling or transport.
    public var isFrozenProjection: Bool
    public var id: GatewayBotRoute { route }

    public init(route: GatewayBotRoute, title: String? = nil,
                handle: String? = nil, sourceLabel: String? = nil,
                friendlyName: String? = nil, rawDisplayName: String? = nil,
                rawProjectionConnectionID: String? = nil,
                isFrozenProjection: Bool = false) {
        self.route = route
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.friendlyName = Self.normalizedFriendlyName(friendlyName)
        self.rawDisplayName = Self.normalizedFriendlyName(rawDisplayName)
        let proposed = handle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.handle = proposed.isEmpty
            ? (route.profile.lowercased() == "default" ? "hermes" : route.profile)
            : proposed
        self.sourceLabel = sourceLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawConnection = rawProjectionConnectionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawProjectionConnectionID = rawConnection?.isEmpty == false ? rawConnection : nil
        self.isFrozenProjection = isFrozenProjection
    }

    /// The identity which produces room-friendly mention forms. New records
    /// use `friendlyName`; legacy records did not have it, so their retained
    /// title remains the safest compatible fallback. The profile is last: it
    /// is stable, but it is not necessarily what the user saw when choosing
    /// the member.
    public var friendlyMentionName: String {
        if let friendlyName, !friendlyName.isEmpty { return friendlyName }
        if let title, !title.isEmpty { return title }
        return route.profile
    }

    /// All preserved friendly identity inputs. `friendlyName` selects the
    /// canonical insertion tag, while title/core display aliases stay valid
    /// resolvers so a later rename cannot strand an older room draft.
    public var friendlyMentionNames: [String] {
        let candidates = [friendlyName, title, rawDisplayName].compactMap {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return [route.profile] }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.lowercased()).inserted }
    }

    /// All safe spellings a room mention parser can map to this exact,
    /// source-qualified seat. Legacy handle/profile forms remain available;
    /// reserved words and unsafe friendly aliases never become destinations.
    public var mentionForms: Set<String> {
        var forms = Set<String>()
        for legacy in [route.profile, handle] {
            let normalized = legacy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { continue }
            forms.insert(normalized)
            forms.insert(Self.collapsedMentionForm(normalized))
        }
        for name in friendlyMentionNames {
            forms.formUnion(BotMention.friendlyForms(from: name))
        }
        return forms
    }

    private enum CodingKeys: String, CodingKey {
        case route, title, friendlyName, rawDisplayName, handle, sourceLabel
        case rawProjectionConnectionID, isFrozenProjection
    }

    /// `friendlyName` is additive. Decode all pre-existing identity fields
    /// exactly as their synthesized Codable representation did, while an old
    /// room that naturally has no new key receives nil rather than becoming
    /// unreadable. Invalid new optional data is ignored rather than allowed to
    /// claim a mention address.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        route = try values.decode(GatewayBotRoute.self, forKey: .route)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        handle = try values.decode(String.self, forKey: .handle)
        sourceLabel = try values.decodeIfPresent(String.self, forKey: .sourceLabel)
        friendlyName = Self.normalizedFriendlyName(
            try? values.decodeIfPresent(String.self, forKey: .friendlyName))
        rawDisplayName = Self.normalizedFriendlyName(
            try? values.decodeIfPresent(String.self, forKey: .rawDisplayName))
        let decodedRawConnection = try? values.decodeIfPresent(
            String.self, forKey: .rawProjectionConnectionID)
        let rawConnection = (decodedRawConnection ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        rawProjectionConnectionID = rawConnection?.isEmpty == false ? rawConnection : nil
        isFrozenProjection = (try? values.decodeIfPresent(
            Bool.self, forKey: .isFrozenProjection)) ?? nil ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(route, forKey: .route)
        try values.encodeIfPresent(title, forKey: .title)
        try values.encodeIfPresent(friendlyName, forKey: .friendlyName)
        try values.encodeIfPresent(rawDisplayName, forKey: .rawDisplayName)
        try values.encode(handle, forKey: .handle)
        try values.encodeIfPresent(sourceLabel, forKey: .sourceLabel)
        try values.encodeIfPresent(rawProjectionConnectionID,
                                   forKey: .rawProjectionConnectionID)
        if isFrozenProjection {
            try values.encode(true, forKey: .isFrozenProjection)
        }
    }

    private static func normalizedFriendlyName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // A name which cannot produce a safe non-reserved tag is not durable
        // mention identity. Keep the seat and its legacy forms intact.
        return BotMention.friendlyTag(from: trimmed) == nil ? nil : trimmed
    }

    private static func collapsedMentionForm(_ value: String) -> String {
        value.replacingOccurrences(of: #"[._-]+"#, with: "",
                                   options: .regularExpression)
    }
}

public struct RoomAttachment: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var blobID: String
    public var fileName: String
    public var mediaType: String
    public var byteCount: Int64
    public var contentHash: String
    public var createdAt: Date

    public init(id: UUID = UUID(), blobID: String, fileName: String,
                mediaType: String, byteCount: Int64, contentHash: String,
                createdAt: Date = Date()) {
        self.id = id; self.blobID = blobID; self.fileName = fileName
        self.mediaType = mediaType; self.byteCount = byteCount
        self.contentHash = contentHash; self.createdAt = createdAt
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct RoomThread: Codable, Hashable, Sendable, Identifiable {
    public let id: RoomThreadID
    public var createdAt: Date
    public var lastActivityAt: Date

    public init(id: RoomThreadID = RoomThreadID(), createdAt: Date = Date(),
                lastActivityAt: Date? = nil) {
        self.id = id; self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt ?? createdAt
    }
}

public enum RoomSpeakerKind: String, Codable, Sendable { case user, member }

public struct RoomEntry: Codable, Hashable, Sendable, Identifiable {
    public let id: RoomEntryID
    /// Exact Hermes projection identity. Opaque ids are deterministically
    /// mapped into Talaria's UUID identity space, but this raw value remains
    /// the wire authority so publishing never leaks the local mapped UUID.
    public var rawProjectionEntryID: String?
    /// Exact projected thread identity for the same reason. It lives on the
    /// entry because the compact projection has no separate thread records.
    public var rawProjectionThreadID: String?
    /// Optional only for decoding pre-thread room logs. RoomStore migrates it
    /// before returning the room and immediately persists the repaired record.
    public var threadID: RoomThreadID?
    public var speaker: RoomSpeakerKind
    public var memberRoute: GatewayBotRoute?
    public var speakerName: String
    public var sourceLabel: String?
    public var text: String
    public var at: Date
    public var attachments: [RoomAttachment]

    public init(id: RoomEntryID = RoomEntryID(), threadID: RoomThreadID? = nil,
                rawProjectionEntryID: String? = nil,
                rawProjectionThreadID: String? = nil,
                speaker: RoomSpeakerKind, memberRoute: GatewayBotRoute? = nil,
                speakerName: String, sourceLabel: String? = nil, text: String,
                at: Date = Date(), attachments: [RoomAttachment] = []) {
        self.id = id; self.threadID = threadID
        self.rawProjectionEntryID = rawProjectionEntryID
        self.rawProjectionThreadID = rawProjectionThreadID
        self.speaker = speaker
        self.memberRoute = memberRoute; self.speakerName = speakerName
        self.sourceLabel = sourceLabel; self.text = text; self.at = at
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case id, rawProjectionEntryID, rawProjectionThreadID, threadID
        case speaker, memberRoute, speakerName, sourceLabel, text, at, attachments
    }

    /// Entries written before room attachments and threads shipped omitted
    /// those additive keys. Decode their safe empty/nil meanings here so the
    /// enclosing store can perform the deterministic thread migration.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(RoomEntryID.self, forKey: .id)
        rawProjectionEntryID = try values.decodeIfPresent(
            String.self, forKey: .rawProjectionEntryID)
        rawProjectionThreadID = try values.decodeIfPresent(
            String.self, forKey: .rawProjectionThreadID)
        threadID = try values.decodeIfPresent(RoomThreadID.self, forKey: .threadID)
        speaker = try values.decode(RoomSpeakerKind.self, forKey: .speaker)
        memberRoute = try values.decodeIfPresent(GatewayBotRoute.self, forKey: .memberRoute)
        speakerName = try values.decode(String.self, forKey: .speakerName)
        sourceLabel = try values.decodeIfPresent(String.self, forKey: .sourceLabel)
        text = try values.decode(String.self, forKey: .text)
        at = try values.decode(Date.self, forKey: .at)
        attachments = try values.decodeIfPresent([RoomAttachment].self, forKey: .attachments) ?? []
    }
}

public enum RoomAttemptState: String, Codable, Sendable {
    /// `accepted` means prompt.submit returned an acknowledgement. `uncertain`
    /// means the transport failed after send and MUST be reconciled by the
    /// attempt marker before any retry; it is not equivalent to `queued`.
    /// `waiting` proves no submit occurred because the member session was
    /// already busy. Relaunch reconciliation may submit this same persisted
    /// attempt once the session is read-only confirmed idle.
    case queued, waiting, accepted, uncertain, working, replied, passed, timedOut, failed, cancelled, delivered
}

/// Durable attempt identity makes a late reply reconcilable after a restart.
public struct RoomAttempt: Codable, Hashable, Sendable, Identifiable {
    public let id: RoomAttemptID
    public let threadID: RoomThreadID
    public let member: GatewayBotRoute
    public let epoch: UInt64
    public var state: RoomAttemptState
    /// Exact persisted submit identity. The anchor finds this user row after
    /// acknowledgement loss; the hash detects a mismatched local record.
    public let promptAnchor: String
    public let promptHash: String
    public let promptText: String
    public var storedSessionID: String
    public var runtimeSessionID: String
    /// Gateway-side image/PDF queue paths survive an uncertain submit. They
    /// are detached only after exact reconciliation reaches a terminal state.
    public var stagedImagePaths: [String]
    /// Exact local blobs that belonged to this persisted prompt delta. A
    /// waiting attempt may outlive the transcript window that first referenced
    /// them, so durable descriptors (not only entry ids) are required to stage
    /// the same payload once the member session becomes idle.
    public var outboundAttachments: [RoomAttachment]
    public var baselineMessageCount: Int
    public var startedAt: Date
    public var finishedAt: Date?

    public init(id: RoomAttemptID = RoomAttemptID(), threadID: RoomThreadID,
                member: GatewayBotRoute, epoch: UInt64,
                promptText: String, storedSessionID: String, runtimeSessionID: String,
                stagedImagePaths: [String] = [],
                outboundAttachments: [RoomAttachment] = [],
                state: RoomAttemptState = .queued, baselineMessageCount: Int = 0,
                startedAt: Date = Date(), finishedAt: Date? = nil) {
        self.id = id; self.threadID = threadID; self.member = member
        self.epoch = epoch; self.state = state
        self.promptAnchor = Self.anchor(for: id)
        self.promptHash = Self.hash(promptText)
        self.promptText = promptText
        self.storedSessionID = storedSessionID
        self.runtimeSessionID = runtimeSessionID
        self.stagedImagePaths = stagedImagePaths
        self.outboundAttachments = outboundAttachments
        self.baselineMessageCount = baselineMessageCount
        self.startedAt = startedAt; self.finishedAt = finishedAt
    }

    public static func anchor(for id: RoomAttemptID) -> String {
        "<!-- talaria-room-attempt:\(id.rawValue.uuidString.lowercased()) -->"
    }

    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey {
        case id, threadID, member, epoch, state, promptAnchor, promptHash, promptText
        case storedSessionID, runtimeSessionID, stagedImagePaths, outboundAttachments
        case baselineMessageCount, startedAt, finishedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(RoomAttemptID.self, forKey: .id)
        threadID = try values.decode(RoomThreadID.self, forKey: .threadID)
        member = try values.decode(GatewayBotRoute.self, forKey: .member)
        epoch = try values.decode(UInt64.self, forKey: .epoch)
        state = try values.decode(RoomAttemptState.self, forKey: .state)
        promptAnchor = try values.decode(String.self, forKey: .promptAnchor)
        promptHash = try values.decode(String.self, forKey: .promptHash)
        promptText = try values.decode(String.self, forKey: .promptText)
        storedSessionID = try values.decode(String.self, forKey: .storedSessionID)
        runtimeSessionID = try values.decode(String.self, forKey: .runtimeSessionID)
        stagedImagePaths = try values.decodeIfPresent([String].self,
                                                      forKey: .stagedImagePaths) ?? []
        outboundAttachments = try values.decodeIfPresent([RoomAttachment].self,
                                                          forKey: .outboundAttachments) ?? []
        baselineMessageCount = try values.decode(Int.self, forKey: .baselineMessageCount)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        finishedAt = try values.decodeIfPresent(Date.self, forKey: .finishedAt)
    }
}

public enum RoomActivityKind: String, Codable, Sendable {
    case queued, working, replied, passed, uncertain, timedOut, failed, cancelled, settled, delivered
    case held
}

public enum RoomDriveStatus: String, Codable, Sendable {
    case queued, running, settling
}

/// Relaunch-safe cursor for one thread drive. The runtime advances this only
/// at member boundaries and persists it with the room before taking the next
/// action, so reopening never starts the thread again from round zero.
public struct RoomDriveState: Codable, Hashable, Sendable, Identifiable {
    public let threadID: RoomThreadID
    public let epoch: UInt64
    public var round: Int
    /// Frozen source-qualified order for the current round. Mention parsing is
    /// recomputed between rounds, not after every member; persisting the list
    /// prevents a relaunch from reshaping the queue around replies already
    /// appended earlier in this same round.
    public var roundMembers: [GatewayBotRoute]
    public var nextMemberIndex: Int
    public var posted: Int
    /// Cumulative post count captured at the beginning of this round. On
    /// relaunch, `posted > roundStartPosted` proves somebody already spoke;
    /// without it a crash mid-round could falsely settle after later passes.
    public var roundStartPosted: Int
    public var status: RoomDriveStatus
    public var updatedAt: Date
    public var id: RoomThreadID { threadID }

    public init(threadID: RoomThreadID, epoch: UInt64, round: Int = 0,
                roundMembers: [GatewayBotRoute] = [],
                nextMemberIndex: Int = 0, posted: Int = 0,
                roundStartPosted: Int? = nil,
                status: RoomDriveStatus = .queued, updatedAt: Date = Date()) {
        self.threadID = threadID; self.epoch = epoch; self.round = round
        self.roundMembers = roundMembers
        self.nextMemberIndex = nextMemberIndex; self.posted = posted
        self.roundStartPosted = roundStartPosted ?? posted
        self.status = status; self.updatedAt = updatedAt
    }
}

public struct RoomActivity: Codable, Hashable, Sendable, Identifiable {
    public let id: RoomActivityID
    public let epoch: UInt64
    public var kind: RoomActivityKind
    public var member: GatewayBotRoute?
    public var threadID: RoomThreadID?
    public var at: Date

    public init(id: RoomActivityID = RoomActivityID(), epoch: UInt64,
                kind: RoomActivityKind, member: GatewayBotRoute? = nil,
                threadID: RoomThreadID? = nil, at: Date = Date()) {
        self.id = id; self.epoch = epoch; self.kind = kind
        self.member = member; self.threadID = threadID; self.at = at
    }
}

public struct RoomRecord: Codable, Hashable, Sendable, Identifiable {
    /// Session-title identity version written with the room record. Rooms
    /// created before immutable session titles had no version and decode as
    /// `legacyNameSessionTitleVersion`; newly created rooms always use the
    /// stable `RoomID` title.
    public static let legacyNameSessionTitleVersion: UInt8 = 0
    public static let immutableIDSessionTitleVersion: UInt8 = 1

    public let id: RoomID
    /// Exact `id:<opaque>` or migration-only `name:<legacy>` projection key
    /// which introduced this rich protected room. Nil marks a local room.
    public var rawProjectionRoomKey: String?
    /// Last projection revision whose safe identity overlay was considered.
    /// Message union is independent and may still accept missing rows from an
    /// older bounded projection without replacing rich local state.
    public var rawProjectionRevision: UInt64
    public var name: String
    /// Version 0 is an on-disk compatibility marker, never a request to title
    /// a newly created member session by the editable display name. The room
    /// transport tries the immutable RoomID first, then the captured legacy
    /// title only while resolving an already-existing pre-version room.
    public var sessionTitleIdentityVersion: UInt8
    /// Exact display name used by pre-version `Group: <name>` sessions. It is
    /// captured during decode and deliberately does not change on rename.
    public var legacySessionTitleName: String?
    public var members: [RoomMember]
    /// Seats removed from the live responder roster but retained as durable
    /// transcript/attempt identities. They never receive new work.
    public var formerMembers: [RoomMember]
    /// Custom room portrait in the protected room blob directory.
    public var avatar: RoomAttachment?
    public var threads: [RoomThread]
    public var entries: [RoomEntry]
    public var attempts: [RoomAttempt]
    /// Usually one current drive; retained as an array because a new user send
    /// in a different thread may queue while the prior member reaches its safe
    /// cancellation boundary.
    public var drives: [RoomDriveState]
    public var activity: [RoomActivity]
    /// Stored-session ids keyed by `GatewayBotRoute.qualifiedID`.
    public var memberSessions: [String: String]
    /// Entry watermarks keyed by `<thread UUID>::<qualified member route>`.
    public var watermarks: [String: Int]
    /// Local-only sticky member holds. Never projected into shared ui_meta.
    public var memberHolds: [RoomMemberHold]
    public var epoch: UInt64
    public var needsUser: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: RoomID = RoomID(), name: String, members: [RoomMember],
                rawProjectionRoomKey: String? = nil,
                rawProjectionRevision: UInt64 = 0,
                sessionTitleIdentityVersion: UInt8 = Self.immutableIDSessionTitleVersion,
                legacySessionTitleName: String? = nil,
                formerMembers: [RoomMember] = [],
                avatar: RoomAttachment? = nil,
                threads: [RoomThread] = [], entries: [RoomEntry] = [],
                attempts: [RoomAttempt] = [], drives: [RoomDriveState] = [],
                activity: [RoomActivity] = [],
                memberSessions: [String: String] = [:], watermarks: [String: Int] = [:],
                memberHolds: [RoomMemberHold] = [],
                epoch: UInt64 = 0, needsUser: Bool = false,
                createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id; self.rawProjectionRoomKey = rawProjectionRoomKey
        self.rawProjectionRevision = rawProjectionRevision; self.name = name
        self.sessionTitleIdentityVersion = sessionTitleIdentityVersion
        self.legacySessionTitleName = sessionTitleIdentityVersion
            == Self.legacyNameSessionTitleVersion ? (legacySessionTitleName ?? name) : nil
        self.members = members
        self.formerMembers = formerMembers; self.avatar = avatar
        self.threads = threads; self.entries = entries; self.attempts = attempts
        self.drives = drives
        self.activity = activity; self.memberSessions = memberSessions
        self.watermarks = watermarks; self.memberHolds = memberHolds
        self.epoch = epoch; self.needsUser = needsUser
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, rawProjectionRoomKey, rawProjectionRevision, name
        case sessionTitleIdentityVersion, legacySessionTitleName
        case members, formerMembers, avatar, threads, entries, attempts, drives
        case activity, memberSessions, watermarks, memberHolds, epoch, needsUser, createdAt, updatedAt
    }

    /// Additive room-state fields decode to their original empty meanings.
    /// Stable identity, name, member routes, entries, and creation time remain
    /// required: inventing any of those would turn corrupt data into a
    /// different room rather than migrating the room the user actually had.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(RoomID.self, forKey: .id)
        rawProjectionRoomKey = try values.decodeIfPresent(
            String.self, forKey: .rawProjectionRoomKey)
        rawProjectionRevision = try values.decodeIfPresent(
            UInt64.self, forKey: .rawProjectionRevision) ?? 0
        name = try values.decode(String.self, forKey: .name)
        sessionTitleIdentityVersion = try values.decodeIfPresent(
            UInt8.self, forKey: .sessionTitleIdentityVersion
        ) ?? Self.legacyNameSessionTitleVersion
        if sessionTitleIdentityVersion == Self.legacyNameSessionTitleVersion {
            legacySessionTitleName = try values.decodeIfPresent(
                String.self, forKey: .legacySessionTitleName
            ) ?? name
        } else {
            // A stale compatibility value must never opt a current/future
            // identity version back into mutable-name lookup.
            legacySessionTitleName = nil
        }
        members = try values.decode([RoomMember].self, forKey: .members)
        formerMembers = try values.decodeIfPresent([RoomMember].self, forKey: .formerMembers) ?? []
        avatar = try values.decodeIfPresent(RoomAttachment.self, forKey: .avatar)
        threads = try values.decodeIfPresent([RoomThread].self, forKey: .threads) ?? []
        entries = try values.decode([RoomEntry].self, forKey: .entries)
        attempts = try values.decodeIfPresent([RoomAttempt].self, forKey: .attempts) ?? []
        drives = try values.decodeIfPresent([RoomDriveState].self, forKey: .drives) ?? []
        activity = try values.decodeIfPresent([RoomActivity].self, forKey: .activity) ?? []
        memberSessions = try values.decodeIfPresent([String: String].self,
                                                    forKey: .memberSessions) ?? [:]
        watermarks = try values.decodeIfPresent([String: Int].self, forKey: .watermarks) ?? [:]
        memberHolds = try values.decodeIfPresent([RoomMemberHold].self,
                                                 forKey: .memberHolds) ?? []
        epoch = try values.decodeIfPresent(UInt64.self, forKey: .epoch) ?? 0
        needsUser = try values.decodeIfPresent(Bool.self, forKey: .needsUser) ?? false
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    public var lastActivityAt: Date { entries.last?.at ?? createdAt }
}

// MARK: - Shared room projection

/// The source-qualified member descriptor stored in Desktop Bot Mode's
/// `ui_meta["hermes-bots-groups"]` room projection.  This is deliberately a
/// wire/display model, not a replacement for `RoomMember`: the full local room
/// keeps its richer, validated routing identity even when a bounded projection
/// omits it.
public struct RoomProjectionMember: Codable, Hashable, Sendable {
    public var name: String
    public var handle: String?
    public var connectionID: String?
    public var connectionKind: String?
    public var connectionLabel: String?
    public var sourceScoped: Bool

    public init(name: String, handle: String? = nil,
                connectionID: String? = nil, connectionKind: String? = nil,
                connectionLabel: String? = nil, sourceScoped: Bool = false) {
        self.name = Self.prefix(name, limit: 128)
        self.handle = Self.optionalPrefix(handle, limit: 128)
        self.connectionID = Self.optionalPrefix(connectionID, limit: 128)
        self.connectionKind = Self.optionalPrefix(connectionKind, limit: 64)
        self.connectionLabel = Self.optionalPrefix(connectionLabel, limit: 128)
        self.sourceScoped = sourceScoped
    }

    private enum CodingKeys: String, CodingKey {
        case name, handle, connectionID = "connectionId", connectionKind
        case connectionLabel, sourceScoped
    }

    private static func prefix(_ value: String, limit: Int) -> String {
        String(value.prefix(limit))
    }

    private static func optionalPrefix(_ value: String?, limit: Int) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return prefix(value, limit: limit)
    }
}

/// The compact `from` object on a projected log row.
public struct RoomProjectionAuthor: Codable, Hashable, Sendable {
    public var kind: RoomSpeakerKind
    public var name: String
    public var source: String?

    public init(kind: RoomSpeakerKind, name: String, source: String? = nil) {
        self.kind = kind
        let fallback = kind == .member ? "Bot" : "You"
        self.name = String((name.isEmpty ? fallback : name).prefix(128))
        if let source, !source.isEmpty {
            self.source = String(source.prefix(128))
        } else {
            self.source = nil
        }
    }
}

/// A stable-id display row in the shared projection. Attachment bytes and
/// other orchestration state intentionally remain in protected local storage.
public struct RoomProjectionEntry: Codable, Hashable, Sendable {
    public var id: String?
    public var from: RoomProjectionAuthor
    public var text: String
    /// Unix epoch milliseconds, matching Desktop's `Date.now()` wire value.
    public var at: Int64
    public var thread: String?

    public init(id: String? = nil, from: RoomProjectionAuthor, text: String,
                at: Int64, thread: String? = nil) {
        if let id, !id.isEmpty { self.id = String(id.prefix(160)) }
        else { self.id = nil }
        self.from = from
        self.text = String(text.prefix(RoomProjectionEnvelope.maximumTextCharacters))
        self.at = at
        if let thread, !thread.isEmpty { self.thread = String(thread.prefix(128)) }
        else { self.thread = nil }
    }
}

/// One compact room value under an `id:<roomId>` or migration-only
/// `name:<legacy>` projection key.
public struct RoomProjectionRoom: Codable, Hashable, Sendable {
    public var name: String
    /// Desktop room ids are opaque strings (not necessarily UUIDs), so the
    /// exact value is retained separately from Talaria's local `RoomID`.
    public var roomID: String?
    public var log: [RoomProjectionEntry]
    public var revision: UInt64
    public var members: [RoomProjectionMember]
    public var image: String?

    public init(name: String, roomID: String? = nil,
                log: [RoomProjectionEntry] = [], revision: UInt64 = 0,
                members: [RoomProjectionMember] = [], image: String? = nil) {
        self.name = String(name.prefix(64))
        if let roomID, !roomID.isEmpty { self.roomID = String(roomID.prefix(128)) }
        else { self.roomID = nil }
        self.log = Array(log.suffix(RoomProjectionEnvelope.maximumMessagesPerRoom))
        self.revision = revision
        self.members = Array(members.prefix(RoomProjectionEnvelope.maximumMembersPerRoom))
        if let image, image.count <= RoomProjectionEnvelope.maximumImageCharacters {
            self.image = image
        } else {
            self.image = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name, roomID = "roomId", log, revision, members, image
    }

    fileprivate func bounded() -> Self {
        Self(name: name, roomID: roomID, log: log, revision: revision,
             members: members, image: image)
    }
}

/// Local-writer information used while folding a CAS winner into a retry.
/// The merge itself is gateway-independent: callers provide only the room
/// fields changed by the local writer and the revision that write should own.
public struct RoomProjectionMergeIntent: Equatable, Sendable {
    public var changedRooms: [String]
    public var deletedRooms: [String]
    public var writeRevision: UInt64
    /// Local-only room keys whose image field must be emitted as the explicit
    /// empty-string clear sentinel. Absence remains compaction/omission.
    public var clearedImages: [String]

    public init(changedRooms: [String] = [], deletedRooms: [String] = [],
                writeRevision: UInt64 = 0, clearedImages: [String] = []) {
        self.changedRooms = Self.unique(changedRooms)
        self.deletedRooms = Self.unique(deletedRooms)
        self.writeRevision = writeRevision
        self.clearedImages = Self.unique(clearedImages)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Version-3 value stored at `ui_meta["hermes-bots-groups"]`.
///
/// This ledger is purposefully independent from RoomStore's full transcript.
/// A missing room or message is merely a bounded/partial projection; only an
/// explicit tombstone can delete projection state. `id:` tombstones are final,
/// while `name:` tombstones retain the revision-gated v1/v2 migration rule.
public struct RoomProjectionEnvelope: Codable, Equatable, Sendable {
    public static let metadataKey = "hermes-bots-groups"
    public static let currentVersion = 3
    public static let maximumGatewayJSONBytes = 48_000
    public static let maximumMessagesPerRoom = 16
    public static let maximumTextCharacters = 1_200
    public static let maximumImageCharacters = 24_000
    public static let maximumMembersPerRoom = 6
    public static let maximumTombstones = 64

    public var version: Int
    /// Unix epoch milliseconds. The caller supplies it so projection building
    /// and conflict resolution stay deterministic and easy to test.
    public var updatedAt: UInt64
    public var rooms: [String: RoomProjectionRoom]
    /// Values are gateway metadata revisions, never device wall-clock order.
    public var deleted: [String: UInt64]

    public init(updatedAt: UInt64 = 0,
                rooms: [String: RoomProjectionRoom] = [:],
                deleted: [String: UInt64] = [:]) {
        version = Self.currentVersion
        self.updatedAt = updatedAt
        self.rooms = rooms
        self.deleted = deleted
        canonicalizeAndBound()
    }

    private enum CodingKeys: String, CodingKey { case version, updatedAt, rooms, deleted }

    /// Decode gateway data leniently at the room/row boundary while still
    /// requiring a JSON object at the root. One malformed/truncated row cannot
    /// turn the rest of a valid projection into an apparent empty deletion.
    public init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        guard raw.objectValue != nil else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Room projection must be a JSON object"))
        }
        self = Self.normalized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.currentVersion, forKey: .version)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(rooms, forKey: .rooms)
        if !deleted.isEmpty { try values.encode(deleted, forKey: .deleted) }
    }

    public static func idKey(_ roomID: String) -> String {
        "id:\(String(roomID.prefix(128)))"
    }

    public static func legacyNameKey(_ name: String) -> String {
        "name:\(String(name.prefix(64)))"
    }

    public static func isRoomKey(_ value: String) -> Bool {
        keyParts(value) != nil
    }

    /// Deterministically bridge a Hermes room key into Talaria's UUID model.
    /// A real id-keyed UUID remains byte-for-byte the same UUID. Opaque and
    /// legacy keys use a namespaced UUIDv5 mapping which is stable across
    /// devices and process launches without making the mapped value wire data.
    public static func localRoomID(forProjectionKey key: String) -> RoomID? {
        guard let parts = keyParts(key) else { return nil }
        if parts.kind == .id, let uuid = UUID(uuidString: parts.value) {
            return RoomID(rawValue: uuid)
        }
        return RoomID(rawValue: projectionUUID(namespace: "room", rawValue: key))
    }

    /// Deterministic local identity for an optional opaque projected thread.
    /// Callers retain the raw value separately when they publish it again.
    public static func localThreadID(forProjectionID rawValue: String) -> RoomThreadID? {
        guard !rawValue.isEmpty, rawValue.count <= 128 else { return nil }
        if let uuid = UUID(uuidString: rawValue) { return RoomThreadID(rawValue: uuid) }
        return RoomThreadID(rawValue: projectionUUID(namespace: "thread", rawValue: rawValue))
    }

    /// Deterministic local identity for an optional opaque projected entry.
    /// Real UUIDs are deliberately unchanged.
    public static func localEntryID(forProjectionID rawValue: String) -> RoomEntryID? {
        guard !rawValue.isEmpty, rawValue.count <= 160 else { return nil }
        if let uuid = UUID(uuidString: rawValue) { return RoomEntryID(rawValue: uuid) }
        return RoomEntryID(rawValue: projectionUUID(namespace: "entry", rawValue: rawValue))
    }

    /// Read the projection block out of a complete `ui_meta` object. Nil means
    /// the key is absent or not an object; callers must not reinterpret that as
    /// an empty authoritative snapshot.
    public init?(uiMeta: JSONValue?) {
        guard let raw = uiMeta?.objectValue?[Self.metadataKey], raw.objectValue != nil else {
            return nil
        }
        self = Self.normalized(raw)
    }

    /// The complete top-level patch accepted by profiles.configure.
    public var uiMetaPatch: JSONValue {
        // Public value fields make fixture construction and pure merges
        // ergonomic, but outbound gateway data must always cross the bounds
        // fence again after any caller mutation.
        guard let raw = try? JSONValue.from(bounded()) else { return .object([:]) }
        return .object([Self.metadataKey: raw])
    }

    /// RoomStore persists only the canonical v3 shape emitted by this build.
    /// Gateway input deliberately normalizes malformed rows leniently, while
    /// a present malformed on-disk ledger is corruption and must fail closed
    /// rather than silently erasing rooms or tombstones on the next write.
    static func strictlyDecodedPersisted(_ raw: JSONValue) -> Self? {
        guard raw.objectValue != nil else { return nil }
        let normalized = Self.normalized(raw)
        guard let canonical = try? JSONValue.from(normalized),
              canonical == raw else { return nil }
        return normalized
    }

    /// Lift v1 wall-clock and v2 name-keyed snapshots into the v3 identity
    /// space. V1 tombstone timestamps become revision zero so clocks can never
    /// outrank a real gateway revision. An id-keyed v3 room always recovers its
    /// `roomId` from the key, fixing the exact Desktop persistence omission.
    public static func normalized(_ raw: JSONValue?) -> Self {
        guard let object = raw?.objectValue else { return Self() }
        let sourceVersion = nonnegativeInt(object["version"])
        let updatedAt = nonnegativeUInt(object["updatedAt"])
        let rawRooms = object["rooms"]?.objectValue ?? [:]
        var rooms: [String: RoomProjectionRoom] = [:]

        for rawKey in rawRooms.keys.sorted() {
            guard let roomObject = rawRooms[rawKey]?.objectValue,
                  let rawLog = roomObject["log"]?.arrayValue else { continue }

            let key: String
            let forcedName: String?
            let forcedRoomID: String?
            if sourceVersion >= Self.currentVersion {
                guard let parts = keyParts(rawKey) else { continue }
                key = rawKey
                forcedName = parts.kind == .legacyName ? parts.value : nil
                forcedRoomID = parts.kind == .id ? parts.value : nil
            } else {
                let legacyName = String(rawKey.prefix(64))
                guard !legacyName.isEmpty else { continue }
                key = legacyNameKey(legacyName)
                forcedName = legacyName
                forcedRoomID = nil
            }

            let name = string(roomObject["name"]) ?? forcedName ?? forcedRoomID ?? ""
            guard !name.isEmpty else { continue }
            let entries = rawLog.compactMap(parseEntry)
            let members = (roomObject["members"]?.arrayValue ?? []).compactMap(parseMember)
            let image = string(roomObject["image"])
            let room = RoomProjectionRoom(
                name: name,
                roomID: forcedRoomID,
                log: entries,
                revision: nonnegativeUInt(roomObject["revision"]),
                members: members,
                image: image
            )
            rooms[key] = preferredRoom(existing: rooms[key], candidate: room)
        }

        var deleted: [String: UInt64] = [:]
        for rawKey in (object["deleted"]?.objectValue ?? [:]).keys.sorted() {
            let key: String
            if sourceVersion >= Self.currentVersion {
                guard keyParts(rawKey) != nil else { continue }
                key = rawKey
            } else {
                let legacyName = String(rawKey.prefix(64))
                guard !legacyName.isEmpty else { continue }
                key = legacyNameKey(legacyName)
            }
            let revision = sourceVersion >= 2
                ? nonnegativeUInt(object["deleted"]?.objectValue?[rawKey]) : 0
            deleted[key] = max(deleted[key] ?? 0, revision)
        }
        return Self(updatedAt: updatedAt, rooms: rooms, deleted: deleted)
    }

    /// Build the bounded display projection of Talaria's protected rooms.
    /// Local UUIDs become durable ids. Hydrated opaque ids retain their exact
    /// raw room/message/thread strings instead of leaking mapped UUIDs back to
    /// Hermes, while attachment bytes remain local.
    public static func projecting(
        _ records: [RoomRecord],
        revisions: [RoomID: UInt64] = [:],
        images: [RoomID: String] = [:],
        updatedAt: UInt64
    ) -> Self {
        var rooms: [String: RoomProjectionRoom] = [:]
        for record in records {
            guard !record.entries.isEmpty else { continue }
            let members = record.members.map { member in
                RoomProjectionMember(
                    name: member.route.profile,
                    handle: member.handle,
                    connectionID: member.rawProjectionConnectionID
                        ?? member.route.gatewayID,
                    connectionLabel: member.sourceLabel,
                    sourceScoped: true
                )
            }
            let entries = record.entries.suffix(Self.maximumMessagesPerRoom).map { entry in
                RoomProjectionEntry(
                    id: entry.rawProjectionEntryID
                        ?? entry.id.rawValue.uuidString.lowercased(),
                    from: RoomProjectionAuthor(
                        kind: entry.speaker,
                        name: entry.speakerName,
                        source: entry.memberRoute?.gatewayID ?? entry.sourceLabel
                    ),
                    text: entry.text,
                    at: milliseconds(entry.at),
                    thread: entry.rawProjectionThreadID
                        ?? entry.threadID?.rawValue.uuidString.lowercased()
                )
            }
            let localKey = idKey(record.id.description)
            let roomKey = record.rawProjectionRoomKey.flatMap {
                isRoomKey($0) ? $0 : nil
            } ?? localKey
            let roomID = keyParts(roomKey).flatMap {
                $0.kind == .id ? $0.value : nil
            }
            rooms[roomKey] = RoomProjectionRoom(
                name: record.name, roomID: roomID, log: entries,
                revision: revisions[record.id] ?? record.rawProjectionRevision,
                members: members, image: images[record.id]
            )
        }
        return Self(updatedAt: updatedAt, rooms: rooms)
    }

    /// Pure pull-before-push/CAS-retry merge. The first snapshot is the remote
    /// winner and the second is the local writer. Omitted rooms and messages
    /// are unioned, never deleted. Identity fields follow room revision; equal
    /// revisions prefer local fields and union source-qualified members.
    public static func merging(
        remote: Self?,
        local: Self?,
        intent: RoomProjectionMergeIntent = RoomProjectionMergeIntent(),
        updatedAt: UInt64? = nil
    ) -> Self {
        let remote = (remote ?? Self()).bounded()
        let local = (local ?? Self()).bounded()

        func keys(for label: String, in envelope: Self) -> Set<String> {
            var matches = Set<String>()
            for (key, room) in envelope.rooms {
                if key == label || room.name == label || key == legacyNameKey(label) {
                    matches.insert(key)
                }
            }
            if isRoomKey(label) { matches.insert(label) }
            else if matches.isEmpty { matches.insert(legacyNameKey(label)) }
            return matches
        }

        var changed = Set<String>()
        for label in intent.changedRooms {
            changed.formUnion(keys(for: label, in: local))
        }
        var clearedImages = Set<String>()
        for label in intent.clearedImages {
            clearedImages.formUnion(keys(for: label, in: remote))
            clearedImages.formUnion(keys(for: label, in: local))
        }

        var deleted: [String: UInt64] = [:]
        for source in [remote, local] {
            for (key, revision) in source.deleted where isRoomKey(key) {
                deleted[key] = max(deleted[key] ?? 0, revision)
            }
        }
        for label in intent.deletedRooms {
            let resolved = keys(for: label, in: remote).union(keys(for: label, in: local))
            for key in resolved where !changed.contains(key) {
                deleted[key] = max(deleted[key] ?? 0, intent.writeRevision)
            }
        }

        var rooms: [String: RoomProjectionRoom] = [:]
        let roomKeys = Set(remote.rooms.keys).union(local.rooms.keys)
        for key in roomKeys.sorted() {
            let remoteRoom = remote.rooms[key]
            let localRoom = local.rooms[key]
            guard remoteRoom != nil || localRoom != nil else { continue }
            let remoteRevision = remoteRoom?.revision ?? 0
            let localRevision = changed.contains(key)
                ? intent.writeRevision : (localRoom?.revision ?? 0)

            var entriesByKey: [String: RoomProjectionEntry] = [:]
            for entry in (remoteRoom?.log ?? []) + (localRoom?.log ?? []) {
                entriesByKey[entryKey(entry)] = entry
            }
            let entries = entriesByKey.values.sorted {
                if $0.at != $1.at { return $0.at < $1.at }
                return entryKey($0) < entryKey($1)
            }

            let identity: RoomProjectionRoom
            let members: [RoomProjectionMember]
            let image: String?
            if clearedImages.contains(key), localRevision >= remoteRevision {
                identity = localRoom ?? remoteRoom!
                members = localRevision > remoteRevision
                    ? (localRoom?.members ?? [])
                    : unionMembers(remoteRoom?.members ?? [], localRoom?.members ?? [])
                image = ""
            } else if localRevision > remoteRevision {
                identity = localRoom ?? remoteRoom!
                members = localRoom?.members ?? []
                // Image is optional because envelope bounding may remove it.
                // Absence is therefore omission, not an explicit clear.
                image = localRoom?.image ?? remoteRoom?.image
            } else if remoteRevision > localRevision {
                identity = remoteRoom ?? localRoom!
                members = remoteRoom?.members ?? []
                image = remoteRoom?.image ?? localRoom?.image
            } else {
                identity = localRoom ?? remoteRoom!
                members = unionMembers(remoteRoom?.members ?? [], localRoom?.members ?? [])
                image = localRoom?.image ?? remoteRoom?.image
            }

            let keyRoomID = key.hasPrefix("id:") ? String(key.dropFirst(3)) : nil
            rooms[key] = RoomProjectionRoom(
                name: identity.name,
                roomID: keyRoomID,
                log: entries,
                revision: max(remoteRevision, localRevision),
                members: members,
                image: image
            )
        }

        for (key, revision) in deleted {
            if key.hasPrefix("id:") {
                // Ids are single-use. No revision can legitimately recreate
                // the same id, so even a high-revision lagging copy stays dead.
                rooms.removeValue(forKey: key)
            } else if revision >= (rooms[key]?.revision ?? 0) {
                rooms.removeValue(forKey: key)
            } else {
                // A higher-revision legacy room is an explicit recreation.
                deleted.removeValue(forKey: key)
            }
        }

        return Self(
            updatedAt: updatedAt ?? max(remote.updatedAt, local.updatedAt),
            rooms: rooms,
            deleted: deleted
        )
    }

    public func merging(
        local: Self,
        intent: RoomProjectionMergeIntent = RoomProjectionMergeIntent(),
        updatedAt: UInt64? = nil
    ) -> Self {
        Self.merging(remote: self, local: local, intent: intent, updatedAt: updatedAt)
    }

    /// Return a canonical bounded copy after public-property mutation.
    public func bounded() -> Self {
        Self(updatedAt: updatedAt, rooms: rooms, deleted: deleted)
    }

    /// Conservative approximation of Python's default ensure-ascii JSON size,
    /// including its separator spaces. This mirrors the exact Desktop guard.
    public var gatewayJSONSize: Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else { return .max }
        return json.unicodeScalars.reduce(into: 0) { size, scalar in
            if scalar.value <= 0x7f {
                size += 1
                if scalar == "," || scalar == ":" { size += 1 }
            } else {
                size += scalar.value <= 0xffff ? 6 : 12
            }
        }
    }

    private enum ProjectionKeyKind { case id, legacyName }
    private struct ProjectionKeyParts {
        var kind: ProjectionKeyKind
        var value: String
    }

    private static func keyParts(_ key: String) -> ProjectionKeyParts? {
        if key.hasPrefix("id:") {
            let value = String(key.dropFirst(3))
            guard !value.isEmpty, value.count <= 128 else { return nil }
            return ProjectionKeyParts(kind: .id, value: value)
        }
        if key.hasPrefix("name:") {
            let value = String(key.dropFirst(5))
            guard !value.isEmpty, value.count <= 64 else { return nil }
            return ProjectionKeyParts(kind: .legacyName, value: value)
        }
        return nil
    }

    private mutating func canonicalizeAndBound() {
        version = Self.currentVersion
        var canonicalRooms: [String: RoomProjectionRoom] = [:]
        for originalKey in rooms.keys.sorted() {
            guard var room = rooms[originalKey]?.bounded() else { continue }
            let key: String
            if let parts = Self.keyParts(originalKey) {
                key = originalKey
                if parts.kind == .id { room.roomID = parts.value }
                else { room.roomID = nil }
            } else if let roomID = room.roomID, !roomID.isEmpty {
                key = Self.idKey(roomID)
                room.roomID = String(roomID.prefix(128))
            } else if !room.name.isEmpty {
                key = Self.legacyNameKey(room.name)
                room.roomID = nil
            } else {
                continue
            }
            canonicalRooms[key] = Self.preferredRoom(
                existing: canonicalRooms[key], candidate: room)
        }
        rooms = canonicalRooms

        var canonicalDeleted: [String: UInt64] = [:]
        for key in deleted.keys.sorted() where Self.isRoomKey(key) {
            canonicalDeleted[key] = max(canonicalDeleted[key] ?? 0, deleted[key] ?? 0)
        }
        // A merge can legitimately union two already-bounded 64-tombstone
        // gateway snapshots. Hermes applies every unioned tombstone before
        // retaining the newest 64 for onward propagation; bounding first can
        // resurrect a room whose lower-ranked tombstone was just dropped.
        for (key, revision) in canonicalDeleted {
            if key.hasPrefix("id:") || revision >= (rooms[key]?.revision ?? 0) {
                rooms.removeValue(forKey: key)
            } else {
                canonicalDeleted.removeValue(forKey: key)
            }
        }
        deleted = Dictionary(
            uniqueKeysWithValues: canonicalDeleted.sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }.prefix(Self.maximumTombstones).map { ($0.key, $0.value) }
        )

        let ranked = rooms.keys.sorted { leftKey, rightKey in
            let left = rooms[leftKey]?.log.last?.at ?? 0
            let right = rooms[rightKey]?.log.last?.at ?? 0
            if left != right { return left < right }
            return leftKey < rightKey
        }
        for key in ranked {
            while (rooms[key]?.log.count ?? 0) > 1
                    && gatewayJSONSize > Self.maximumGatewayJSONBytes {
                rooms[key]?.log.removeFirst()
            }
            if rooms[key]?.image != nil && gatewayJSONSize > Self.maximumGatewayJSONBytes {
                rooms[key]?.image = nil
            }
            if gatewayJSONSize > Self.maximumGatewayJSONBytes {
                rooms.removeValue(forKey: key)
            }
        }
        if gatewayJSONSize > Self.maximumGatewayJSONBytes {
            for item in deleted.sorted(by: {
                if $0.value != $1.value { return $0.value < $1.value }
                return $0.key > $1.key
            }) where gatewayJSONSize > Self.maximumGatewayJSONBytes {
                deleted.removeValue(forKey: item.key)
            }
        }
    }

    private static func preferredRoom(existing: RoomProjectionRoom?,
                                      candidate: RoomProjectionRoom) -> RoomProjectionRoom {
        guard let existing else { return candidate }
        if candidate.revision != existing.revision {
            return candidate.revision > existing.revision ? candidate : existing
        }
        let left = (try? JSONEncoder().encode(existing)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let right = (try? JSONEncoder().encode(candidate)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return right > left ? candidate : existing
    }

    private static func parseEntry(_ value: JSONValue) -> RoomProjectionEntry? {
        guard let object = value.objectValue else { return nil }
        let kind: RoomSpeakerKind = string(object["from"]?["kind"])
            == RoomSpeakerKind.member.rawValue ? .member : .user
        let fallback = kind == .member ? "Bot" : "You"
        let author = RoomProjectionAuthor(
            kind: kind,
            name: string(object["from"]?["name"]) ?? fallback,
            source: string(object["from"]?["source"])
        )
        return RoomProjectionEntry(
            id: string(object["id"]), from: author,
            text: string(object["text"]) ?? "",
            at: signedInteger(object["at"]),
            thread: string(object["thread"])
        )
    }

    private static func parseMember(_ value: JSONValue) -> RoomProjectionMember? {
        guard let object = value.objectValue else { return nil }
        return RoomProjectionMember(
            name: string(object["name"]) ?? "",
            handle: string(object["handle"]),
            connectionID: string(object["connectionId"]),
            connectionKind: string(object["connectionKind"]),
            connectionLabel: string(object["connectionLabel"]),
            sourceScoped: object["sourceScoped"]?.boolValue == true
        )
    }

    private static func entryKey(_ entry: RoomProjectionEntry) -> String {
        if let id = entry.id { return "id:\(id)" }
        var thread = entry.thread ?? "legacy"
        if thread.hasPrefix("legacy-"),
           !thread.dropFirst("legacy-".count).isEmpty,
           thread.dropFirst("legacy-".count).allSatisfy(\.isNumber) {
            thread = "legacy"
        }
        return lengthKey([
            String(entry.at), entry.from.kind.rawValue, entry.from.name,
            entry.from.source ?? "", thread, entry.text,
        ])
    }

    private static func memberKey(_ member: RoomProjectionMember) -> String {
        lengthKey([
            member.connectionID ?? "", member.connectionLabel ?? "",
            member.handle ?? "", member.name,
        ])
    }

    private static func lengthKey(_ values: [String]) -> String {
        values.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    private static func unionMembers(_ remote: [RoomProjectionMember],
                                     _ local: [RoomProjectionMember]) -> [RoomProjectionMember] {
        var ordered: [RoomProjectionMember] = []
        var indices: [String: Int] = [:]
        for member in remote + local {
            let key = memberKey(member)
            if let index = indices[key] { ordered[index] = member }
            else {
                indices[key] = ordered.count
                ordered.append(member)
            }
        }
        return Array(ordered.prefix(Self.maximumMembersPerRoom))
    }

    private static func string(_ value: JSONValue?) -> String? {
        value?.stringValue
    }

    private static func nonnegativeInt(_ value: JSONValue?) -> Int {
        let number = value?.doubleValue ?? 0
        guard number.isFinite, number > 0 else { return 0 }
        return number >= Double(Int.max) ? Int.max : Int(number.rounded(.towardZero))
    }

    private static func nonnegativeUInt(_ value: JSONValue?) -> UInt64 {
        let number = value?.doubleValue ?? 0
        guard number.isFinite, number > 0 else { return 0 }
        if number >= Double(UInt64.max) { return UInt64.max }
        return UInt64(number.rounded(.towardZero))
    }

    private static func signedInteger(_ value: JSONValue?) -> Int64 {
        let number = value?.doubleValue ?? 0
        guard number.isFinite else { return 0 }
        if number >= Double(Int64.max) { return Int64.max }
        if number <= Double(Int64.min) { return Int64.min }
        return Int64(number.rounded(.towardZero))
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite else { return 0 }
        if value >= Double(Int64.max) { return Int64.max }
        if value <= Double(Int64.min) { return Int64.min }
        return Int64(value.rounded())
    }

    /// RFC 4122 UUIDv5 using the standard DNS namespace and a Talaria-specific
    /// typed name. SHA-1 is required by UUIDv5; it is used only for stable
    /// identity mapping, never for authentication or integrity.
    private static func projectionUUID(namespace: String, rawValue: String) -> UUID {
        let dnsNamespace = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        var input = Data()
        var namespaceBytes = dnsNamespace.uuid
        withUnsafeBytes(of: &namespaceBytes) { input.append(contentsOf: $0) }
        input.append(contentsOf: "talaria.room-projection.\(namespace)\u{0}\(rawValue)".utf8)
        var bytes = Array(Insecure.SHA1.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

public struct RoomMetadataMutation: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case add, remove, rename }

    public static let maximumNameLength = 64

    public var id: UUID
    public var route: GatewayBotRoute
    public var kind: Kind
    public var oldName: String?
    public var newName: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), route: GatewayBotRoute, kind: Kind,
                oldName: String? = nil, newName: String? = nil,
                createdAt: Date = Date()) {
        self.id = id; self.route = route; self.kind = kind
        self.oldName = oldName; self.newName = newName; self.createdAt = createdAt
    }

    /// Validate the durable server-metadata command before it can enter the
    /// outbox.  These records survive room deletion, so a malformed command
    /// must never become an immortal retry loop after the UI that created it
    /// is gone.
    public func isStructurallyValid() -> Bool {
        guard !route.gatewayID.isEmpty, !route.profile.isEmpty,
              route == GatewayBotRoute(qualifiedID: route.qualifiedID),
              route.gatewayID.count <= 512, route.profile.count <= 256 else { return false }
        func validName(_ value: String?) -> Bool {
            guard let value else { return false }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return value == trimmed && !trimmed.isEmpty && trimmed.count <= Self.maximumNameLength
        }
        switch kind {
        case .add:
            return oldName == nil && validName(newName)
        case .remove:
            return validName(oldName) && newName == nil
        case .rename:
            return validName(oldName) && validName(newName) && oldName != newName
        }
    }
}

public enum RoomValidationError: Error, Equatable, Sendable {
    case emptyName
    case memberCount(Int)
    case invalidRoute
    case duplicateMember(GatewayBotRoute)
    case duplicateIdentity
    case unknownThread
    case invalidSpeaker
    case invalidAttachment
    case invalidAttempt
    case invalidDrive
    case invalidWatermark
    case invalidBound
}
