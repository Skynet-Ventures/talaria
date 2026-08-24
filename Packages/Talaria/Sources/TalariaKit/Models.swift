import Foundation

// Domain models for Talaria. Shapes mirror the design prototype's
// `hermes-data.js` (the design-approved data contract) and are re-mapped onto
// the live `hermes serve` RPC payloads in GatewayClient+Mapping.swift.

// MARK: - Avatars

/// The Bot Mode avatar language: geometric shape × hue, with blinking eyes
/// that scan while the bot works. Cosmetics are client-side only; profiles
/// stay clean.
public enum AvatarShape: String, Codable, CaseIterable, Sendable {
    case circle, squircle, hexagon, triangle, diamond, pentagon
}

public enum AvatarHue: String, Codable, CaseIterable, Sendable {
    case teal, violet, amber, green, pink, blue
    /// Reserved pseudo-hue for gateway-originated events in feeds.
    case gateway
}

// MARK: - Bots

public enum BotStatus: String, Codable, Sendable {
    /// Actively running a session turn.
    case working
    /// Blocked on a pending approval.
    case approval
    case idle
}

/// Where a roster row was listed from, when that is not the live gateway.
///
/// Desktop's union roster keeps thin `remoteSource: true` rows in the SAME
/// array as the live ones (plugin.js:2348-2356), each carrying its bare
/// profile `name` beside a source-qualified key, plus the connection id and
/// the device label. Talaria folds that key onto `Bot.id` — it has to, so two
/// gateways' `default` rows can coexist in one `ForEach` (`botRosterKey`,
/// plugin.js:2664-2670) — which is exactly why the bare name has to ride
/// along here: `id` is `"<gatewayID>::<profile>"` and no @handle resolves to
/// that.
public struct BotSource: Codable, Sendable, Equatable {
    /// The profile name as its own gateway knows it — desktop's `bot.name`,
    /// the form `resolveRosterMentions` registers beside the handle (2445).
    public var profile: String
    /// Saved-gateway id of the source (`connectionId`).
    public var gatewayID: String
    /// Display label of the source (`connectionLabel`) — the device half of
    /// the `@name-device` handle, the fourth `filterBots` match field (2976),
    /// and the tail of the completion meta line (8034).
    public var connectionLabel: String

    public init(profile: String, gatewayID: String, connectionLabel: String) {
        self.profile = profile
        self.gatewayID = gatewayID
        self.connectionLabel = connectionLabel
    }
}

/// A bot is a Hermes profile (`~/.hermes/profiles/<name>/`) — isolated config,
/// memory, skills, credentials and history. Talaria is a window onto the same
/// roster as desktop Bot Mode; there is no separate store.
public struct Bot: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var job: String
    public var shape: AvatarShape
    public var hue: AvatarHue
    public var status: BotStatus
    /// Short description of the in-flight task while `status == .working`.
    public var task: String?
    /// Minutes elapsed on the current task.
    public var minutesElapsed: Int
    public var preview: String
    public var previewTime: String
    public var unread: Int
    public var mentionsYou: Bool
    public var description: String?
    /// Pinned model override for this profile (nil = gateway default).
    public var pinnedModel: String?
    /// User-set display title from desktop Bot Mode
    /// (`ui_meta["hermes-bots"].title`). Shared with desktop so a bot renamed
    /// there reads the same here.
    public var title: String?
    /// Raw core-profile `display_name` from `profiles.list`. This is kept
    /// distinct from `title`: the latter is Bot Mode metadata and can be
    /// locally retained across a stale poll, while this is the gateway's own
    /// identity input for friendly mentions.
    public var rawDisplayName: String?
    /// Explicit @handle when the roster precomputed one (multi-gateway rosters
    /// disambiguate duplicates as `name-device`).
    public var handleOverride: String?
    /// Set when this row was listed from a gateway other than the live one —
    /// desktop's `remoteSource` flag and the three fields that travel with it
    /// (plugin.js:2348-2356). Nil means the row is on the socket this app
    /// holds, which is the only place a handoff can be delivered.
    public var remoteSource: BotSource?

    public init(id: String, job: String, shape: AvatarShape, hue: AvatarHue,
                status: BotStatus = .idle, task: String? = nil, minutesElapsed: Int = 0,
                preview: String = "", previewTime: String = "", unread: Int = 0,
                mentionsYou: Bool = false, description: String? = nil, pinnedModel: String? = nil,
                title: String? = nil, handleOverride: String? = nil,
                remoteSource: BotSource? = nil, rawDisplayName: String? = nil) {
        self.id = id; self.job = job; self.shape = shape; self.hue = hue
        self.status = status; self.task = task; self.minutesElapsed = minutesElapsed
        self.preview = preview; self.previewTime = previewTime; self.unread = unread
        self.mentionsYou = mentionsYou; self.description = description; self.pinnedModel = pinnedModel
        self.title = title; self.handleOverride = handleOverride
        self.remoteSource = remoteSource
        self.rawDisplayName = rawDisplayName
    }
}

// MARK: - Identity (desktop Bot Mode parity)

// Desktop renders two stable identities per roster row: a customizable
// display name and the profile's @handle. Ported verbatim from
// apps/desktop/src/plugins/hermes-bots/plugin.js `displayName()` (2935) and
// `botHandle()` (2406) so the same profile reads identically in both apps.
public extension Bot {

    /// The friendly name — `displayName()` (plugin.js:2935-2958), all FOUR of
    /// its rules. A row on another gateway whose profile is `default` reads
    /// its device label; a user title wins next; the primary profile is
    /// literally named "default", which "reads like nobody bothered", so it
    /// presents as Hermes; everything else is de-slugged and title-cased.
    ///
    /// RULE 1 IS THE ONE WITH A HISTORY (2941-2943). Without it the far
    /// machine's primary agent and this one's are the same word on two rows —
    /// `Hermes` above `Hermes` — and neither the roster, the search field nor
    /// the @-completion meta line can tell them apart. Upstream keys it off
    /// `remoteSource` and pointedly NOT off `sourceScoped`: an annotated
    /// ACTIVE row carries `sourceScoped` too, and keying off that renamed
    /// users' own main agent to an IP-derived label (community report,
    /// Aug 17 2026). `remoteSource == nil` is the same guard, which is why the
    /// live gateway's own `default` still reads Hermes here.
    ///
    /// THE LABEL WINS OVER A TITLE, because that is the order upstream wrote:
    /// 2941 returns before the `meta.title` check at 2949. Upstream can never
    /// reach the case where the two disagree — `botRosterMeta` returns null
    /// for any remote row (2717-2719) and a thin row is pushed with no title
    /// field at all (2349-2356) — but Talaria's foreign rows are richer, and
    /// carry the far gateway's own `ui_meta` title. There is no upstream
    /// behaviour to copy for a TITLED foreign `default`, so what upstream
    /// actually wrote is kept rather than a precedence that exists nowhere in
    /// the plugin.
    ///
    /// De-slugs `profileName`, not `id`: desktop reads `displayName(profile)`
    /// off `profile.name` (plugin.js:8033), and a foreign row's `id` is the
    /// source-qualified key, which would title-case to "Homelab::default".
    var displayTitle: String {
        if let remoteSource,
           profileName.trimmingCharacters(in: .whitespaces).lowercased() == "default" {
            // `&& bot.connectionLabel` (2941): a source with no label has
            // nothing to rename the row to, so it falls through to Hermes
            // rather than to an empty title.
            let label = remoteSource.connectionLabel.trimmingCharacters(in: .whitespaces)
            if !label.isEmpty { return label }
        }
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title.trimmingCharacters(in: .whitespaces)
        }
        if let rawDisplayName,
           !rawDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return rawDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let name = profileName
        if name.trimmingCharacters(in: .whitespaces).lowercased() == "default" {
            return "Hermes"
        }
        let spaced = name.replacingOccurrences(of: "[-_]+", with: " ",
                                               options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return spaced.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// The @handle you tag the bot with — the profile name, except "default",
    /// which is tagged @hermes.
    ///
    /// The precomputed `@name-device` form WINS, and it wins over the
    /// default→hermes rule on the next line (plugin.js:2407-2411). That is not
    /// an accident of ordering: when `default` exists on two gateways the
    /// handles are `@default-macbook` / `@default-homelab`, never
    /// `@hermes-macbook`, and plain `@hermes` then addresses nobody. The
    /// `handleOverride != id` guard is upstream's `bot.handle !== name` — it
    /// is what lets a UNIQUE union row fall back to the bare-name path.
    var handle: String {
        if let handleOverride, handleOverride != id { return handleOverride }
        return profileName.trimmingCharacters(in: .whitespaces).lowercased() == "default"
            ? "hermes" : profileName
    }

    /// The bare profile name this row answers to on its own gateway — the
    /// second form `resolveRosterMentions` registers (plugin.js:2445), and the
    /// string a gateway call will actually accept as a profile.
    ///
    /// Equal to `id` for every live row. It differs only for a foreign one,
    /// whose `id` is the source-qualified `botRosterKey` (plugin.js:2669) and
    /// therefore addresses nothing.
    var profileName: String { remoteSource?.profile ?? id }

    /// The user-facing identity from which friendly @mentions are derived.
    /// Bot Mode metadata wins because it is an explicit user choice; the core
    /// `display_name` is the final wire fallback before visual presentation
    /// humanizes the profile slug. Only the first two are actual rename
    /// metadata: the generic `displayTitle` fallback must never manufacture a
    /// second @-identity such as `codereview` for profile `code_review`.
    var friendlyMentionName: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let rawDisplayName,
           !rawDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return rawDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return displayTitle
    }

    /// Every retained friendly identity that can address this bot. A Bot Mode
    /// title chooses the insertion spelling, but it does not erase the core
    /// profile display name: both may have been visible to another client and
    /// must remain accepted aliases.
    var friendlyMentionNames: [String] {
        let candidates = [title, rawDisplayName].compactMap {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.lowercased()).inserted }
    }

    /// The safe friendly insertion token, if this bot's display identity can
    /// become one without claiming a reserved address. Completion falls back
    /// to a non-reserved legacy handle when this is nil.
    var friendlyMentionTag: String? {
        friendlyMentionNames.lazy.compactMap(BotMention.friendlyTag(from:)).first
    }

    /// What completion inserts: the friendly tag whenever one is safe, then a
    /// legacy handle. It is deliberately not `displayTitle`, which can contain
    /// spaces or punctuation the mention grammar cannot route.
    var mentionInsertionTag: String? {
        if let friendlyMentionTag { return friendlyMentionTag }
        let legacy = handle.lowercased()
        return legacy.isEmpty ? nil : legacy
    }

    /// Every safe token that can reach this bot. The resolver builds one union
    /// map from these forms and poisons collisions rather than guessing.
    var mentionForms: Set<String> {
        var forms = Set<String>()
        for legacy in [handle, profileName, handleOverride].compactMap({ $0 }) {
            let normalized = legacy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { continue }
            forms.insert(normalized)
        }
        for name in friendlyMentionNames {
            forms.formUnion(BotMention.friendlyForms(from: name))
        }
        return forms
    }

    /// Match forms completion may search without changing the inserted token.
    /// The friendly string itself is included so a gateway's core
    /// `display_name` can find a metadata-renamed bot (for example typing
    /// `@writer` can offer insertion `@research-buddy`).
    var mentionCompletionForms: Set<String> {
        var forms = mentionForms
        for display in friendlyMentionNames {
            forms.formUnion(BotMention.searchForms(from: display))
        }
        return forms
    }

    /// Desktop only shows the handle alongside the title when they differ.
    ///
    /// Upstream computes the display half from a STRIPPED `{ name }` object
    /// (plugin.js:2721-2723), which carries no `remoteSource` — so
    /// `displayName`'s rule 1 cannot fire inside `showsHandle`, and a foreign
    /// `default` reads its device label in the row while hiding its `@hermes`.
    /// Talaria compares the REAL display name instead, and that is deliberate:
    /// `TalariaVoice.displayName` collapses a row whose title and handle agree
    /// down to "@handle" (Components/ScreenHeader.swift:318), so taking
    /// upstream's stripped reading here would print `@hermes` INSTEAD of the
    /// label — hiding, in two of the three themes, the very thing rule 1
    /// exists to show. The extra handle a foreign row shows is one the row
    /// really answers to.
    var showsHandle: Bool {
        displayTitle.lowercased() != handle.lowercased()
    }
}

// MARK: - Roster search (desktop `filterBots`)

// One needle, four fields, and no re-ranking. Ported from
// plugin.js `filterBots()` (2963-2981) and kept here, in the module both the
// roster and the palette import, so the phone cannot grow two different ideas
// of what typing "hermes" finds.
//
// The asymmetry with @-mention completion is deliberate upstream and preserved
// here: search is forgiving (substring, four fields, a leading '@' shrugged
// off) because it is exploration; completion is strict (prefix, handle only,
// capped at 8 — AppModelLive+A2A.swift) because it inserts a token that has to
// resolve.
public enum RosterSearch {

    /// Desktop's needle (plugin.js:2964): trim, lowercase, then strip exactly
    /// ONE leading '@'. `"@hermes"`, `"@Hermes"` and `" @hermes "` all narrow
    /// to `hermes`; `"@@ops"` narrows to `"@ops"`, because only one '@' goes.
    public static func needle(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
    }

    /// The per-row predicate (plugin.js:2970-2980): case-insensitive
    /// **substring** — not prefix — OR'd across four fields.
    ///
    ///  1. the display name, i.e. what the row actually reads (2971);
    ///  2. the raw profile id (2972);
    ///  3. the @handle (2973);
    ///  4. the device label (2976), so "homelab" finds every bot living on the
    ///     Homelab connection.
    ///
    /// The job/description and the preview line are deliberately NOT matched.
    /// Desktop has only those four locals in the filter body, and preview
    /// matching would make results move while you read them — the preview
    /// changes every time the bot speaks.
    ///
    /// An empty needle matches everything, which is the identity that makes
    /// `filterBots` a no-op rather than a blank list (2966-2968).
    public static func matches(needle: String,
                               displayName: String,
                               profile: String,
                               handle: String,
                               connectionLabel: String? = nil) -> Bool {
        guard !needle.isEmpty else { return true }
        return displayName.lowercased().contains(needle)
            || profile.lowercased().contains(needle)
            || handle.lowercased().contains(needle)
            || (connectionLabel?.lowercased().contains(needle) ?? false)
    }
}

public extension Bot {

    /// This row's side of `filterBots`. `connectionLabel` is the device the row
    /// lives on: desktop annotates every union row with its source's label
    /// (plugin.js:2337 for active rows, 2353 for thin remote ones) and searches
    /// it, so the label is passed in rather than derived — a live profile does
    /// not know which machine it was listed from.
    ///
    /// A row that DOES know wins: a foreign row carries its own
    /// `remoteSource.connectionLabel`, and in a union array the caller has only
    /// one label to hand down. Upstream reads the label off the row for the
    /// same reason (2976 filters on `bot.connectionLabel`).
    ///
    /// The profile field is `profileName`, never `id` — matching the
    /// source-qualified key would let a needle that fell inside a gateway id
    /// silently match rows nothing on screen says it should.
    func matchesRosterSearch(_ needle: String, connectionLabel: String? = nil) -> Bool {
        RosterSearch.matches(needle: needle,
                             displayName: displayTitle,
                             profile: profileName,
                             handle: handle,
                             connectionLabel: remoteSource?.connectionLabel ?? connectionLabel)
    }
}

public extension Array where Element == Bot {

    /// `filterBots(roster, metaByName, query)` (plugin.js:2963).
    ///
    /// Narrowing ONLY. `Array.prototype.filter` preserves input order and the
    /// upstream doc comment says it outright — "Keep the current activity
    /// order — search narrows the roster, it never re-ranks it"
    /// (plugin.js:2961-2962). So callers pass the roster in the order it is
    /// already painted (`rankedBots`, pinned-then-recency), never a re-sorted
    /// copy, and the surviving rows stay where the eye left them.
    ///
    /// An empty needle returns the roster untouched (plugin.js:2966-2968) —
    /// which is also why a bare "@" lists everyone rather than nobody.
    func filterBots(needle: String, connectionLabel: String? = nil) -> [Bot] {
        guard !needle.isEmpty else { return self }
        return filter { $0.matchesRosterSearch(needle, connectionLabel: connectionLabel) }
    }
}

// MARK: - Chat

public enum MessageAuthor: String, Codable, Sendable {
    case system = "sys"
    case bot
    case user
}

/// Inline rich cards a bot message can carry.
public enum MessageCard: Codable, Sendable, Equatable {
    case papers([Paper])
    case approvalRef(String)

    public struct Paper: Codable, Sendable, Equatable {
        public var title: String
        public var meta: String
        public var summary: String
        public init(title: String, meta: String, summary: String) {
            self.title = title; self.meta = meta; self.summary = summary
        }
    }
}

/// A bounded retained tool argument or result. Raw gateway history is an
/// untrusted presentation source, so structural JSON is kept only when its
/// complete rendering fits the relevant budget; a clipped JSON prefix is
/// never represented as valid JSON.
public struct ToolPayload: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case json, text, unavailable, malformed
    }

    public var kind: Kind
    public var json: JSONValue?
    public var text: String?
    public var isTruncated: Bool

    public init(kind: Kind, json: JSONValue? = nil, text: String? = nil,
                isTruncated: Bool = false) {
        self.kind = kind
        self.json = json
        self.text = text
        self.isTruncated = isTruncated
    }

    public var displayText: String? { text }
}

/// One tool invocation inside a turn, rendered as a collapsible chip in the
/// transcript (desktop shows these inline under the assistant message).
public struct ToolCall: Identifiable, Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case running, done, failed }

    public enum Provenance: String, Codable, Sendable {
        case live, stored, projection, unmatchedResult, malformed
    }

    /// Stable presentation identity. This is deliberately distinct from the
    /// provider id because malformed/repeated/orphaned rows must not collide
    /// in SwiftUI's `ForEach`.
    public var id: String
    /// Exact `tool_id` / `tool_call_id`, when Hermes retained one. Pairing
    /// never falls back to a same-named tool or matching text.
    public var gatewayToolID: String?
    public var name: String
    /// ≤80-char argument preview from tool.start.
    public var context: String
    public var state: State
    /// One-line result summary from tool.complete.
    public var summary: String?
    /// Full result text, shown when the chip is expanded.
    public var resultText: String?
    public var durationSeconds: Double?
    public var arguments: ToolPayload?
    public var result: ToolPayload?
    /// Bounded specialist evidence for edit_file/patch/write_file only.
    public var fileDiff: ToolFileDiff?
    /// Bounded explicit diff material awaiting an exact file-edit tool name.
    /// Never rendered or treated as a specialist until promoted by exact ID.
    public var deferredFileDiff: ToolFileDiff?
    public var provenance: Provenance
    public var diagnostic: String?

    public init(id: String, name: String, context: String, state: State = .running,
                summary: String? = nil, resultText: String? = nil,
                durationSeconds: Double? = nil, gatewayToolID: String? = nil,
                arguments: ToolPayload? = nil, result: ToolPayload? = nil,
                fileDiff: ToolFileDiff? = nil,
                deferredFileDiff: ToolFileDiff? = nil,
                provenance: Provenance = .live, diagnostic: String? = nil) {
        self.id = id; self.name = name; self.context = context; self.state = state
        self.summary = summary; self.resultText = resultText
        self.durationSeconds = durationSeconds
        self.gatewayToolID = gatewayToolID
        self.arguments = arguments; self.result = result
        self.fileDiff = fileDiff
        self.deferredFileDiff = deferredFileDiff
        self.provenance = provenance; self.diagnostic = diagnostic
    }

    private enum CodingKeys: String, CodingKey {
        case id, gatewayToolID, name, context, state, summary, resultText
        case durationSeconds, arguments, result, fileDiff, deferredFileDiff
        case provenance, diagnostic
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        context = try values.decode(String.self, forKey: .context)
        state = try values.decodeIfPresent(State.self, forKey: .state) ?? .running
        gatewayToolID = try values.decodeIfPresent(String.self, forKey: .gatewayToolID)
            ?? (id.hasPrefix("generating:") ? nil : id)
        summary = try values.decodeIfPresent(String.self, forKey: .summary)
        resultText = try values.decodeIfPresent(String.self, forKey: .resultText)
        durationSeconds = try values.decodeIfPresent(Double.self, forKey: .durationSeconds)
        arguments = try values.decodeIfPresent(ToolPayload.self, forKey: .arguments)
        result = try values.decodeIfPresent(ToolPayload.self, forKey: .result)
        fileDiff = try values.decodeIfPresent(ToolFileDiff.self, forKey: .fileDiff)
        deferredFileDiff = try values.decodeIfPresent(
            ToolFileDiff.self, forKey: .deferredFileDiff)
        provenance = try values.decodeIfPresent(Provenance.self, forKey: .provenance) ?? .live
        diagnostic = try values.decodeIfPresent(String.self, forKey: .diagnostic)
    }
}

/// A file/image staged on the composer, consumed by the next prompt.submit.
public struct PendingAttachment: Identifiable, Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case image, pdf, file }

    public var id: String
    public var kind: Kind
    public var name: String
    /// Gateway-side path returned by the attach RPC.
    public var path: String?
    /// Local thumbnail data for images (never sent again).
    public var thumbnail: Data?

    public init(id: String = UUID().uuidString, kind: Kind, name: String,
                path: String? = nil, thumbnail: Data? = nil) {
        self.id = id; self.kind = kind; self.name = name
        self.path = path; self.thumbnail = thumbnail
    }
}

enum TurnFailureMessageCodec {
    static let maximumVisibleScalars = 8_192
    static let clippedMarker = "\n… [turn detail clipped]"

    /// Imported snapshots are an untrusted presentation source. Keep work and
    /// retained storage finite, preserve ordinary tabs/newlines, and strip
    /// controls that can spoof the card or copied diagnostics. A distinct raw
    /// cap retains safe text behind dense controls without permitting an
    /// unbounded scan.
    static func admit(_ value: String) -> String {
        let markerScalars = clippedMarker.unicodeScalars
        let markerCount = markerScalars.count
        let rawWorkMaximum = maximumVisibleScalars * 4
        let raw = value.unicodeScalars.prefix(rawWorkMaximum + 1)
        let rawWasClipped = raw.count > rawWorkMaximum
        var safe = String.UnicodeScalarView()
        safe.reserveCapacity(maximumVisibleScalars + 1)
        var safeCount = 0
        for scalar in raw.prefix(rawWorkMaximum) {
            if scalar.value == 0x09 || scalar.value == 0x0A {
                safe.append(scalar)
                safeCount += 1
            } else if !isUnsafeControl(scalar.value) {
                safe.append(scalar)
                safeCount += 1
            }
            if safeCount > maximumVisibleScalars { break }
        }
        guard rawWasClipped || safeCount > maximumVisibleScalars else {
            return String(safe)
        }
        let contentCount = max(0, maximumVisibleScalars - markerCount)
        var clipped = String.UnicodeScalarView(safe.prefix(contentCount))
        clipped.append(contentsOf: markerScalars.prefix(
            maximumVisibleScalars - clipped.count))
        return String(clipped)
    }

    private static func isUnsafeControl(_ value: UInt32) -> Bool {
        if value <= 0x1F || (0x7F...0x9F).contains(value) { return true }
        switch value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        default:
            return false
        }
    }
}

public struct TurnFailure: Codable, Sendable, Equatable {
    public var message: String
    public var recoverable: Bool
    public var errorSurface: TurnErrorSurface?

    public init(message: String, recoverable: Bool,
                errorSurface: TurnErrorSurface? = nil) {
        self.message = message
        self.recoverable = recoverable
        self.errorSurface = errorSurface
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = TurnFailureMessageCodec.admit(
            try container.decode(String.self, forKey: .message))
        recoverable = try container.decode(Bool.self, forKey: .recoverable)
        errorSurface = try container.decodeIfPresent(TurnErrorSurface.self,
                                                     forKey: .errorSurface)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(TurnFailureMessageCodec.admit(message), forKey: .message)
        try container.encode(recoverable, forKey: .recoverable)
        try container.encodeIfPresent(errorSurface, forKey: .errorSurface)
    }

    private enum CodingKeys: String, CodingKey {
        case message, recoverable, errorSurface
    }
}

public struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var author: MessageAuthor
    public var time: String?
    public var text: String
    public var card: MessageCard?
    /// Set while tokens are still streaming in.
    public var isStreaming: Bool
    /// Model reasoning/thinking that preceded this message (reasoning.delta /
    /// thinking.delta accumulation, or the stored transcript's reasoning
    /// fields). Rendered as a collapsible "Thought" block, desktop parity.
    public var reasoning: String?
    /// Tools this turn ran, in call order (tool.start / tool.complete).
    public var toolCalls: [ToolCall]
    /// Durable transcript row id — needed for reactions and rewind.
    public var rowID: Int?
    /// Terminal failure metadata belongs to the assistant turn rather than a
    /// separate system row. Optional preserves decoding of older snapshots.
    public var failure: TurnFailure?

    public init(id: UUID = UUID(), author: MessageAuthor, time: String? = nil,
                text: String, card: MessageCard? = nil, isStreaming: Bool = false,
                reasoning: String? = nil, toolCalls: [ToolCall] = [], rowID: Int? = nil,
                failure: TurnFailure? = nil) {
        self.id = id; self.author = author; self.time = time
        self.text = text; self.card = card; self.isStreaming = isStreaming
        self.reasoning = reasoning; self.toolCalls = toolCalls; self.rowID = rowID
        self.failure = failure
    }
}

// MARK: - Approvals

public enum ApprovalKind: String, Codable, Sendable {
    case email, command = "cmd", post, other
}

/// A pending approval request. Bots block before anything risky leaves —
/// outbound email, shell commands, public posts — and resume on approve/deny.
public struct Approval: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var botID: String
    public var kind: ApprovalKind
    public var title: String
    public var target: String
    public var subject: String
    public var body: String
    public var why: String
    public var age: String

    public init(id: String, botID: String, kind: ApprovalKind, title: String,
                target: String, subject: String, body: String, why: String, age: String) {
        self.id = id; self.botID = botID; self.kind = kind; self.title = title
        self.target = target; self.subject = subject; self.body = body
        self.why = why; self.age = age
    }
}

// MARK: - Routines

/// A scheduled routine, backed by Hermes cron with jobs namespaced
/// `[bot:<name>] <routine>`. Runs land in the bot's own chat.
public struct Routine: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var botID: String
    public var name: String
    public var schedule: String
    public var next: String
    public var last: String
    public var isOn: Bool

    public init(id: String, botID: String, name: String, schedule: String,
                next: String, last: String, isOn: Bool) {
        self.id = id; self.botID = botID; self.name = name
        self.schedule = schedule; self.next = next; self.last = last; self.isOn = isOn
    }
}

// MARK: - Activity feed

public enum ActivityKind: String, Codable, Sendable {
    case approval, mention, routine, task, gateway, approved
}

public struct ActivityItem: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var time: String
    public var botID: String
    public var kind: ActivityKind
    public var text: String
    public var subtext: String
    public var pending: Bool

    public init(id: UUID = UUID(), time: String, botID: String, kind: ActivityKind,
                text: String, subtext: String, pending: Bool = false) {
        self.id = id; self.time = time; self.botID = botID; self.kind = kind
        self.text = text; self.subtext = subtext; self.pending = pending
    }
}

public struct ActivityDay: Identifiable, Codable, Sendable, Equatable {
    public var id: String { day }
    public var day: String
    public var items: [ActivityItem]
    public init(day: String, items: [ActivityItem]) {
        self.day = day; self.items = items
    }
}

// MARK: - Agent Inbox (bot ⇄ bot)

/// Cross-profile handoffs run upstream as
/// `hermes -p <bot> chat -c "Agent Inbox" -q "..."` with attribution.
public struct A2AMessage: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var fromBotID: String
    /// `false` when current Hermes supplied only a display handle and no
    /// authenticated source route. Optional keeps older encoded rows
    /// source-compatible; an absent value means the historical known route.
    public var fromBotRouteKnown: Bool?
    /// Receiving bot id, or "all" for a broadcast.
    public var toBotID: String
    /// Mirrors `fromBotRouteKnown` for the recipient endpoint. A reply to a
    /// markerless sender must not borrow a colliding roster identity either.
    public var toBotRouteKnown: Bool?
    public var time: String
    public var text: String

    public init(id: UUID = UUID(), fromBotID: String, fromBotRouteKnown: Bool? = true,
                toBotID: String, toBotRouteKnown: Bool? = true,
                time: String, text: String) {
        self.id = id; self.fromBotID = fromBotID; self.toBotID = toBotID
        self.fromBotRouteKnown = fromBotRouteKnown
        self.toBotRouteKnown = toBotRouteKnown
        self.time = time; self.text = text
    }
}

// MARK: - Connections

public enum ConnectionKind: String, Codable, Sendable {
    case tailscale, lan, cloud
}

public enum ConnectionState: String, Codable, Sendable {
    case connected, asleep, offline, connecting
}

/// A named gateway connection — Tailscale/LAN URL or Hermes Cloud — matching
/// desktop's Settings → Connections registry.
public struct GatewayConnection: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var kind: ConnectionKind
    /// Host:port for tailscale/lan; org slug for cloud.
    public var address: String
    public var state: ConnectionState
    public var ping: String
    public var botCount: Int

    public init(id: String, name: String, kind: ConnectionKind, address: String,
                state: ConnectionState, ping: String, botCount: Int) {
        self.id = id; self.name = name; self.kind = kind; self.address = address
        self.state = state; self.ping = ping; self.botCount = botCount
    }
}

// MARK: - Notifications

public enum PushKind: String, Codable, CaseIterable, Sendable {
    case approval, response, routine, mention, task, gateway
}

public struct NotificationPref: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var kind: PushKind
    public var name: String
    public var subtitle: String
    public var isOn: Bool
    /// Critical alerts can break through Focus (approvals only).
    public var isCritical: Bool

    public init(id: String, kind: PushKind, name: String, subtitle: String,
                isOn: Bool, isCritical: Bool = false) {
        self.id = id; self.kind = kind; self.name = name; self.subtitle = subtitle
        self.isOn = isOn; self.isCritical = isCritical
    }
}

// MARK: - Sessions

public struct SessionSummary: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var when: String
    public var messageCount: Int

    public init(id: String, title: String, when: String, messageCount: Int) {
        self.id = id; self.title = title; self.when = when; self.messageCount = messageCount
    }
}

// MARK: - Artifacts

public enum ArtifactKind: String, Codable, Sendable {
    case image, file, link, media
}

public struct Artifact: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var botID: String
    public var kind: ArtifactKind
    /// Uppercased extension chip for files ("MD", "CSV", …).
    public var ext: String?
    public var title: String
    public var meta: String
    public var when: String

    public init(id: String, botID: String, kind: ArtifactKind, ext: String? = nil,
                title: String, meta: String, when: String) {
        self.id = id; self.botID = botID; self.kind = kind; self.ext = ext
        self.title = title; self.meta = meta; self.when = when
    }
}

// MARK: - Memory & context

public struct BotMemory: Codable, Sendable, Equatable {
    public var skillCount: Int
    public var memoryCount: Int
    public var recent: [String]

    public init(skillCount: Int, memoryCount: Int, recent: [String]) {
        self.skillCount = skillCount; self.memoryCount = memoryCount; self.recent = recent
    }
}

/// One segment of the context-window meter (same source as the desktop
/// status-bar meter).
public struct ContextSegment: Identifiable, Codable, Sendable, Equatable {
    public var id: String { label }
    public var label: String
    /// Percentage of the window, 0–100.
    public var percent: Int

    public init(label: String, percent: Int) {
        self.label = label; self.percent = percent
    }
}
