import Foundation

public enum RoomEngine {
    public static let minimumMembers = 2
    public static let maximumMembers = 6
    public static let maximumRounds = 3
    public static let maximumPosts = 10
    public static let historyLimit = 24
    public static let activityLimit = 50
    public static let retainedEntries = 96
    public static let legacyThreadGap: TimeInterval = 15 * 60

    public static func watermarkKey(threadID: RoomThreadID,
                                    member: GatewayBotRoute) -> String {
        "\(threadID.rawValue.uuidString.lowercased())::\(member.qualifiedID)"
    }

    public struct MentionResult: Equatable, Sendable {
        public var everyone: Bool
        public var ambiguous: Bool
        public var mentioned: Set<GatewayBotRoute>
        public init(everyone: Bool = false, ambiguous: Bool = false,
                    mentioned: Set<GatewayBotRoute> = []) {
            self.everyone = everyone; self.ambiguous = ambiguous
            self.mentioned = mentioned
        }
    }

    public static func validate(_ room: RoomRecord) throws {
        guard !room.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RoomValidationError.emptyName
        }
        // A profile deletion can retire the last one or more live seats while
        // preserving the room transcript. `formerMembers` is the durable
        // tombstone for those routes; such a room is inert until settings add
        // enough live members again, but it must remain decodable so a later
        // profile-id reuse cannot inherit its work.
        let minimum = room.formerMembers.isEmpty ? minimumMembers : 0
        guard (minimum...maximumMembers).contains(room.members.count) else {
            throw RoomValidationError.memberCount(room.members.count)
        }
        var routes = Set<GatewayBotRoute>()
        for member in room.members {
            guard validMember(member) else { throw RoomValidationError.invalidRoute }
            guard routes.insert(member.route).inserted else {
                throw RoomValidationError.duplicateMember(member.route)
            }
        }
        var formerRoutes = Set<GatewayBotRoute>()
        for member in room.formerMembers {
            guard validMember(member) else { throw RoomValidationError.invalidRoute }
            guard !routes.contains(member.route), formerRoutes.insert(member.route).inserted else {
                throw RoomValidationError.duplicateMember(member.route)
            }
        }
        let historicalRoutes = routes.union(formerRoutes)
        let routableRoutes = Set(room.members.filter {
            !$0.isFrozenProjection
        }.map(\.route))

        guard Set(room.threads.map(\.id)).count == room.threads.count,
              Set(room.entries.map(\.id)).count == room.entries.count,
              Set(room.attempts.map(\.id)).count == room.attempts.count,
              Set(room.drives.map(\.id)).count == room.drives.count,
              Set(room.activity.map(\.id)).count == room.activity.count
        else { throw RoomValidationError.duplicateIdentity }

        let threadIDs = Set(room.threads.map(\.id))
        for entry in room.entries {
            if let threadID = entry.threadID, !threadIDs.contains(threadID) {
                throw RoomValidationError.unknownThread
            }
            if entry.speaker == .member {
                guard let route = entry.memberRoute, historicalRoutes.contains(route) else {
                    throw RoomValidationError.invalidSpeaker
                }
            } else if entry.memberRoute != nil {
                throw RoomValidationError.invalidSpeaker
            }
            if entry.attachments.contains(where: { !validAttachment($0) }) {
                throw RoomValidationError.invalidAttachment
            }
        }
        if let avatar = room.avatar, !validAttachment(avatar) {
            throw RoomValidationError.invalidAttachment
        }
        if room.attempts.contains(where: {
            !threadIDs.contains($0.threadID)
                || !($0.finishedAt == nil ? routableRoutes : historicalRoutes).contains($0.member)
                || $0.baselineMessageCount < 0
                || $0.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || $0.promptAnchor != RoomAttempt.anchor(for: $0.id)
                || $0.promptHash != RoomAttempt.hash($0.promptText)
                || $0.storedSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || $0.runtimeSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || $0.stagedImagePaths.contains(where: {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                })
                || $0.outboundAttachments.contains(where: { !validAttachment($0) })
                || Set($0.outboundAttachments.map(\.id)).count != $0.outboundAttachments.count
                || ($0.finishedAt != nil && !$0.outboundAttachments.isEmpty)
        }) {
            throw RoomValidationError.invalidAttempt
        }
        if room.drives.contains(where: {
            !threadIDs.contains($0.threadID) || $0.round < 0 || $0.round >= maximumRounds
                || $0.nextMemberIndex < 0 || $0.nextMemberIndex > room.members.count
                || $0.posted < 0 || $0.posted > maximumPosts
                || $0.roundStartPosted < 0 || $0.roundStartPosted > $0.posted
                || Set($0.roundMembers).count != $0.roundMembers.count
                || !$0.roundMembers.allSatisfy(routableRoutes.contains)
                || $0.nextMemberIndex > $0.roundMembers.count
        }) { throw RoomValidationError.invalidDrive }
        if room.activity.contains(where: {
            ($0.threadID.map { !threadIDs.contains($0) } ?? false)
                || ($0.member.map { !historicalRoutes.contains($0) } ?? false)
        }) { throw RoomValidationError.unknownThread }
        let sessionKeys = Set(historicalRoutes.map(\.qualifiedID))
        if room.memberSessions.contains(where: {
            !sessionKeys.contains($0.key)
                || $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) { throw RoomValidationError.invalidRoute }
        let watermarkKeys = Set(threadIDs.flatMap { threadID in
            historicalRoutes.map { watermarkKey(threadID: threadID, member: $0) }
        })
        if room.watermarks.contains(where: {
            !watermarkKeys.contains($0.key) || $0.value < 0 || $0.value > room.entries.count
        }) {
            throw RoomValidationError.invalidWatermark
        }
        let activeRoutes = Set(room.members.map(\.route))
        guard room.memberHolds.count <= maximumMembers,
              Set(room.memberHolds.map(\.id)).count == room.memberHolds.count,
              Set(room.memberHolds.map(\.member)).count == room.memberHolds.count,
              room.memberHolds.allSatisfy({
                  $0.isStructurallyValid(activeMembers: activeRoutes, threadIDs: threadIDs)
              }) else { throw RoomValidationError.invalidRoute }
        guard room.entries.count <= retainedEntries,
              room.activity.count <= activityLimit,
              room.activity.allSatisfy({ $0.epoch == room.epoch })
        else { throw RoomValidationError.invalidBound }
    }

    public static func isPass(_ text: String?) -> Bool {
        let value = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return true }
        return value.range(of: #"^\(?\s*pass\s*\)?\.?$"#,
                           options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static func parseMentions(_ text: String, members: [RoomMember]) -> MentionResult {
        var forms: [String: GatewayBotRoute] = [:]
        var ambiguous = Set<String>()
        for member in members {
            let raw = member.mentionForms
            // A same-named member on two gateways must never be selected by a
            // bare collision. Poison the shared form; each unique qualified
            // handle remains available as the explicit route.
            for form in raw where !form.isEmpty {
                if ambiguous.contains(form) { continue }
                if let existing = forms[form], existing != member.route {
                    forms.removeValue(forKey: form)
                    ambiguous.insert(form)
                } else {
                    forms[form] = member.route
                }
            }
        }

        var result = MentionResult()
        guard let regex = try? NSRegularExpression(pattern: #"@([a-z0-9][a-z0-9._-]*)"#,
                                                   options: [.caseInsensitive]) else { return result }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges > 1 else { continue }
            let token = ns.substring(with: match.range(at: 1)).lowercased()
            if token == "everyone" || token == "all" { result.everyone = true; continue }
            if token == "user" { continue }
            // Exact forms win before a collapsed fallback is considered. A
            // unique @foo-bar must not be poisoned merely because another
            // member owns the separate compact @foobar spelling.
            if ambiguous.contains(token) {
                result.ambiguous = true
                continue
            }
            if let route = forms[token] {
                result.mentioned.insert(route)
                continue
            }
            let collapsed = collapse(token)
            if ambiguous.contains(collapsed) {
                result.ambiguous = true
                continue
            }
            if let route = forms[collapsed] { result.mentioned.insert(route) }
        }
        return result
    }

    /// The token a room completion can safely insert for one member. Friendly
    /// slugs win when they are unique across the durable room roster; otherwise
    /// a unique legacy handle is the explicit escape hatch. Returning nil is
    /// intentional when neither form can survive the parser's sticky
    /// ambiguity poisoning.
    public static func mentionInsertionTag(for member: RoomMember,
                                           among members: [RoomMember]) -> String? {
        var claims: [String: Int] = [:]
        for candidate in members {
            for form in candidate.mentionForms {
                claims[form, default: 0] += 1
            }
        }
        if let friendly = BotMention.friendlyTag(from: member.friendlyMentionName),
           claims[friendly] == 1 {
            return friendly
        }
        let legacy = member.handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Room broadcasts/reserved user addressing win over a member's legacy
        // handle, but default/hermes remain valid unique room identities.
        guard !legacy.isEmpty, !["all", "everyone", "user"].contains(legacy),
              claims[legacy] == 1 else {
            return nil
        }
        return legacy
    }

    /// Prefix completion over durable room member forms. `forms` includes the
    /// friendly slug/compact slug and legacy profile/handle spellings; the
    /// returned member may be found through any of them, but insertion is
    /// gated by `mentionInsertionTag(for:among:)` so a poisoned alias is never
    /// offered as if it were deliverable.
    public static func mentionCompletionMembers(for query: String,
                                                members: [RoomMember]) -> [RoomMember] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return members.filter { member in
            guard !member.isFrozenProjection else { return false }
            guard mentionInsertionTag(for: member, among: members) != nil else { return false }
            return needle.isEmpty || member.mentionForms.contains { $0.hasPrefix(needle) }
        }
    }

    public static func responders(entries: [RoomEntry], members: [RoomMember],
                                  threadID: RoomThreadID) -> [RoomMember] {
        let routable = members.filter { !$0.isFrozenProjection }
        let log = entries.filter { $0.threadID == threadID }
        guard let boundary = log.lastIndex(where: { $0.speaker == .user }) else {
            return routable
        }
        var mentions = MentionResult()
        for entry in log[boundary...] {
            let parsed = parseMentions(entry.text, members: members)
            mentions.everyone = mentions.everyone || parsed.everyone
            mentions.ambiguous = mentions.ambiguous || parsed.ambiguous
            mentions.mentioned.formUnion(parsed.mentioned)
        }
        if mentions.everyone { return routable }
        if mentions.mentioned.isEmpty { return mentions.ambiguous ? [] : routable }
        return routable.filter { mentions.mentioned.contains($0.route) }
    }

    /// The only entry point a driver needs for its round boundary. Returning
    /// no members at either cap makes the 3-round/10-post ceiling executable,
    /// not merely a UI convention.
    public static func scheduledResponders(entries: [RoomEntry], members: [RoomMember],
                                           threadID: RoomThreadID, round: Int,
                                           posted: Int) -> [RoomMember] {
        guard round >= 0, round < maximumRounds, posted >= 0, posted < maximumPosts else { return [] }
        let selected = responders(entries: entries, members: members, threadID: threadID)
        guard selected.count > 1 else { return selected }
        let shift = round % selected.count
        return Array(selected[shift...] + selected[..<shift])
    }

    /// Assign old unthreaded entries to stable thread ids. A user entry after
    /// a real 15-minute lull starts a new topic; follow-ups inside the window
    /// remain together. The first entry id anchors the synthetic thread id.
    @discardableResult
    public static func migrateLegacyThreads(in room: inout RoomRecord) -> Bool {
        var changed = false
        var current: RoomThreadID?
        var previousAt: Date?
        var known = Dictionary(uniqueKeysWithValues: room.threads.map { ($0.id, $0) })
        var observed: [RoomThreadID: (first: Date, last: Date)] = [:]

        func include(_ entry: RoomEntry, in threadID: RoomThreadID) {
            if known[threadID] == nil {
                known[threadID] = RoomThread(id: threadID, createdAt: entry.at)
                changed = true
            }
            if let bounds = observed[threadID] {
                observed[threadID] = (min(bounds.first, entry.at), max(bounds.last, entry.at))
            } else {
                observed[threadID] = (entry.at, entry.at)
            }
        }

        for index in room.entries.indices {
            if let existing = room.entries[index].threadID {
                current = existing
                previousAt = room.entries[index].at
                // A thread id without its summary is repairable, not
                // ambiguous: the entry itself supplies both timestamps.
                include(room.entries[index], in: existing)
                continue
            }
            let entry = room.entries[index]
            let lull = previousAt.map { entry.at.timeIntervalSince($0) > legacyThreadGap } ?? true
            if current == nil || (entry.speaker == .user && lull) {
                current = RoomThreadID(rawValue: entry.id.rawValue)
                known[current!] = RoomThread(id: current!, createdAt: entry.at)
            }
            room.entries[index].threadID = current
            if let current { include(entry, in: current) }
            previousAt = entry.at
            changed = true
        }
        for (threadID, bounds) in observed {
            guard var thread = known[threadID] else { continue }
            if thread.createdAt != bounds.first || thread.lastActivityAt != bounds.last {
                thread.createdAt = bounds.first
                thread.lastActivityAt = bounds.last
                known[threadID] = thread
                changed = true
            }
        }
        if changed {
            room.threads = known.values.sorted { $0.createdAt < $1.createdAt }
            room.updatedAt = Date()
        }
        return changed
    }

    public static func recordActivity(_ event: RoomActivity, in room: inout RoomRecord) {
        let current = room.activity.filter { $0.epoch == room.epoch }
        guard event.epoch == room.epoch else {
            room.activity = Array(current.suffix(activityLimit))
            return
        }
        room.activity = Array((current + [event]).suffix(activityLimit))
        room.updatedAt = max(room.updatedAt, event.at)
    }

    public static func append(_ entry: RoomEntry, to room: inout RoomRecord) throws {
        guard let threadID = entry.threadID,
              let threadIndex = room.threads.firstIndex(where: { $0.id == threadID })
        else { throw RoomValidationError.unknownThread }
        room.entries.append(entry)
        room.threads[threadIndex].lastActivityAt = max(room.threads[threadIndex].lastActivityAt, entry.at)
        room.updatedAt = max(room.updatedAt, entry.at)
        if entry.speaker == .member,
           entry.text.range(of: #"@user\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            room.needsUser = true
        }
    }

    public static func beginUserTurn(in room: inout RoomRecord, at: Date = Date()) -> RoomThreadID {
        room.epoch &+= 1
        room.needsUser = false
        room.activity.removeAll()
        let thread = RoomThread(createdAt: at)
        room.threads.append(thread)
        room.updatedAt = at
        return thread.id
    }

    private static func collapse(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: #"[\s._-]+"#, with: "",
                                                options: .regularExpression)
    }

    private static func validAttachment(_ attachment: RoomAttachment) -> Bool {
        !attachment.blobID.isEmpty && !attachment.blobID.contains("/")
            && !attachment.blobID.contains("\\") && !attachment.blobID.contains("..")
            && attachment.byteCount >= 0
            && attachment.contentHash.range(of: #"^[0-9a-f]{64}$"#,
                                            options: .regularExpression) != nil
    }

    private static func validMember(_ member: RoomMember) -> Bool {
        let gateway = member.route.gatewayID.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = member.route.profile.trimmingCharacters(in: .whitespacesAndNewlines)
        let handle = member.handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let friendly = member.friendlyName
        let friendlyIsSafe = friendly.map { value in
            value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                && BotMention.friendlyTag(from: value) != nil
        } ?? true
        let rawDisplayIsSafe = member.rawDisplayName.map { value in
            value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                && BotMention.friendlyTag(from: value) != nil
        } ?? true
        let rawConnectionIsSafe = member.rawProjectionConnectionID.map { value in
            !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                && value.count <= 128 && !value.contains(GatewayBotRoute.separator)
        } ?? !member.isFrozenProjection
        return !gateway.isEmpty && gateway == member.route.gatewayID
            && !profile.isEmpty && profile == member.route.profile
            && GatewayBotRoute(qualifiedID: member.route.qualifiedID) == member.route
            && handle == member.handle
            && handle.range(of: #"^[a-z0-9][a-z0-9._-]*$"#,
                            options: [.regularExpression, .caseInsensitive]) != nil
            && friendlyIsSafe && rawDisplayIsSafe && rawConnectionIsSafe
            && (!member.isFrozenProjection
                || member.rawProjectionConnectionID == member.route.gatewayID)
    }
}
