import SwiftUI
import TalariaKit
import TalariaTheme

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// ── The cosmetics bridge, made two-way ───────────────────────────────────────
//
// Talaria has always READ desktop Bot Mode's `ui_meta["hermes-bots"]` block
// (title, shape, color, canonical-chat pin) and written only its own
// `ui_meta["talaria"]`. That made the bridge one-way: a bot recolored on the
// phone was invisible on the laptop, and desktop's next save won silently
// (BOT-MODE-PARITY Region 1 "ui_meta['hermes-bots'] write path", Region 2
// "Server cosmetics write"). ROADMAP decision #3 settles it — phone edits
// write back.
//
// Two contracts have to be honored exactly, and they pull in opposite
// directions:
//
// 1. `profiles.configure` merges ui_meta by TOP-LEVEL key only
//    (methods_profiles.py:714-724) — a nested block is replaced wholesale, and
//    a key set to null is deleted. So writing `{shape: …}` alone would erase
//    the bot's title, its group, its pin and its created stamp.
// 2. Desktop's `mergeServerMeta` (plugin.js:432-482) treats the server block
//    as authoritative and reads an OMITTED `chat` key as an authoritative
//    deletion of the canonical forever-chat.
//
// Together those mean every write here is read-merge-write over the LIVE
// block, never a bare patch: fetch the row, overlay only the keys this edit
// owns, send the whole thing back. `saveBotMeta` does the same upstream
// (plugin.js:201-227) for the same reason.
//
// The second half of this file is roster craft — the signals desktop derives
// from its 5 s `profiles.list` poll and Talaria had no source for: recency
// ranking, the 90-second liveness window, pinning, and the unread watermark
// that catches deliveries the phone slept through.

// MARK: - Vocabulary mapping (write direction)
//
// `BotModeLook` — the tables that turn a picked `AvatarShape`/`AvatarHue` into
// desktop's own shape word and hex — now lives in `TalariaKit/BotModeMeta.swift`,
// directly beneath the read direction it has to invert. It moved there so
// `ProtocolChecks` can execute the round trip instead of a comment asserting it;
// the write path below calls it unchanged.

/// Desktop's three-valued save outcome (plugin.js:246-269), ported because the
/// distinction is the difference between a silent legacy fallback and a real
/// failure the user must see.
public enum CosmeticsWrite: Sendable, Equatable {
    /// The gateway confirmed `applied.ui_meta == true`.
    case persisted
    /// The gateway answered without the `applied` contract — an older build
    /// that cannot store ui_meta at all. Desktop stays silent here because its
    /// plugin-local store keeps the look; Talaria has no local cosmetics store,
    /// so the sheet says so quietly once, rather than erroring.
    case unsupported
    /// The write genuinely did not land: the gateway said so, or the call threw.
    case failed
}

// MARK: - Roster signals (side table)

/// Everything the roster ranks and badges on, derived from `profiles.list` the
/// way desktop derives it (plugin.js:86-150, 3823-3839, 7637-7666).
///
/// `AppModel`'s stored properties live in AppModel.swift, which this phase does
/// not own, so this rides a MainActor singleton exactly as `LiveRuntime` and
/// `ProfileAssetStore` do. Everything is keyed inside one gateway scope and
/// dropped when the gateway changes — two gateways can both serve a profile
/// called "inbox", and one must never inherit the other's pin or watermark.
@MainActor
@Observable
public final class RosterSignals {
    public static let shared = RosterSignals()

    /// Conversation activity remains a 90-second presence signal. The newer
    /// `worker_session` window is kept separately below: a background worker
    /// can make a row look alive, but it must never become a conversation
    /// stamp, unread watermark, or ranking key.
    static let activeWindow: TimeInterval = 90

    /// Unix seconds of each bot's freshest *conversation* activity. This is
    /// the newer of canonical and last session, never worker activity.
    private(set) var lastActive: [String: Double] = [:]
    /// Unix seconds from the optional worker-session projection. Hermes keeps
    /// it on its own 150-second live window; it is intentionally absent from
    /// `activity(of:)` and every unread path.
    private(set) var workerActive: [String: Double] = [:]
    /// Keep the typed worker projection as well as its stamp. `isLive` owns
    /// the future-skew bound; reducing this to a timestamp alone would let a
    /// wildly future `last_active` hold a row in the rail forever.
    private(set) var workerSessions: [String: HermesProfile.WorkerSessionRef] = [:]
    /// Raw preview for the canonical/click identity. This stays aligned with
    /// the roster row even when a different session is the freshest activity.
    private(set) var previews: [String: String] = [:]
    /// Raw preview belonging to `lastActive`'s freshest conversation. Activity
    /// notifications must quote this session, never the older canonical row.
    private(set) var activityPreviews: [String: String] = [:]
    /// `ui_meta["hermes-bots"].created`, ms epoch (plugin.js:5400).
    private(set) var created: [String: Double] = [:]
    /// `ui_meta["hermes-bots"].pinned` — a plain boolean that rides ui_meta to
    /// every machine, so a laptop pin pins here too.
    private(set) var pinned: Set<String> = []
    /// Profiles whose Bot Mode metadata has `hidden: true`. This is a roster
    /// display preference, not session hiding: it never removes the bot from
    /// the union roster used by rooms or mentions.
    private(set) var hidden: Set<String> = []
    /// `has_avatar` from the same roster row. Consulting it is what keeps the
    /// first roster paint from firing one `profiles.get_asset` per bot for
    /// faces the gateway has already said do not exist.
    ///
    /// A fetch hint and nothing more. It says bytes EXIST, never that they are
    /// worth showing — on the maintainer's gateway all five profiles answer
    /// `has_avatar: true` with a 160×160 raster of their own vector face, and a
    /// client that let this flag pick the renderer swapped five live faces for
    /// five stills. What the bytes turn out to be is `ProfileAssetStore`'s
    /// verdict alone (AppModelLive+Profiles.swift `refreshAvatar`).
    private(set) var hasAvatar: Set<String> = []

    /// `ui_meta["hermes-bots"].imageKind` — the profile's own record of what
    /// its stored asset IS: `"photo"` for a picture a human chose, `"shape"`
    /// for a machine-made raster of the vector face. Desktop's fetch guard
    /// consults exactly this before refusing a 160×160 asset (plugin.js:415),
    /// which is what keeps a deliberately-chosen 160×160 photo displayable.
    private(set) var imageKind: [String: String] = [:]

    // There is deliberately no `selected`, no `watermarks` and no
    // `watermarksSeeded` here any more. This table kept a per-process copy of
    // the unread high-water marks and its own sticky selection to spare from
    // them, while the durable store kept a second copy under a second sparing
    // rule (AppModelLive+Unread.swift). Two tables ingesting the same stamps and
    // two functions writing the same badge is this repo's named bug class, and
    // both being idempotent only made the disagreement invisible. `lastActive`
    // below is the stamp; `UnreadWatermarkStore` is the memory of it.

    /// Rows whose entrance animation has already played. A refresh, a scroll
    /// back up, or a tab switch must not replay it (BOT-MODE-PARITY §4.2:
    /// "motion that reads as arrival for the first screenful must never read
    /// as a slow load for row 60").
    var entered: Set<String> = []

    /// The roster is on screen. Off-screen the poll keeps running — the unread
    /// badge has to catch a cron delivery while the user is in a chat — but at
    /// a quarter of the cadence.
    var rosterVisible = false

    var pollTask: Task<Void, Never>?
    /// A poll is in flight — so a screen asking for a fresh one on appear
    /// coalesces onto it instead of doubling the request.
    var polling = false
    /// Bots with a cosmetics write in flight; their local row wins over a
    /// roster answer that predates it.
    var writing: Set<String> = []
    /// This gateway has already told the user once that it cannot store looks.
    /// Desktop never says it at all, because its local store keeps the look;
    /// Talaria says it once and then stops, rather than blocking every save on
    /// a legacy gateway forever (plugin.js:248-262 documents that exact trap).
    var lookUnsupportedNoticed = false

    private var scope: String?

    /// Point the tables at the live gateway, dropping anything learned about a
    /// different one.
    func rescope(to base: URL?) {
        let next = base?.absoluteString
        guard next != scope else { return }
        scope = next
        lastActive.removeAll()
        workerActive.removeAll()
        workerSessions.removeAll()
        previews.removeAll()
        activityPreviews.removeAll()
        created.removeAll()
        pinned.removeAll()
        hidden.removeAll()
        hasAvatar.removeAll()
        imageKind.removeAll()
        entered.removeAll()
        writing.removeAll()
        lookUnsupportedNoticed = false
    }

    /// Fold one roster answer in: ranking, liveness, pins, `has_avatar`.
    ///
    /// The unread signal is deliberately poll-derived — it is the only model
    /// that catches every delivery path (cron, CLI, another machine, a
    /// bot-to-bot handoff, work finished while the phone was asleep) — but the
    /// marks it is compared against are durable and live elsewhere. What this
    /// leaves behind for them is `lastActive`, freshly restated for the whole
    /// roster; `AppModel.unreadMoves(scope:)` does the diff.
    func ingest(_ profiles: [HermesProfile]) {
        var seen = Set<String>()
        for profile in profiles {
            seen.insert(profile.name)
            if profile.hasAvatar { hasAvatar.insert(profile.name) } else { hasAvatar.remove(profile.name) }
            // One parser for the desktop block, the same one the roster map and
            // the secondary rosters read (TalariaKit/BotModeMeta.swift). Nil
            // here means the block is absent, never that it is empty.
            let block = BotModeMeta(uiMeta: profile.uiMeta)
            // A bot with a write in flight keeps the value the user just chose:
            // this answer was composed before that write and reading it as
            // authority would flip the row back under their thumb.
            if !writing.contains(profile.name) {
                created[profile.name] = block?.created ?? 0
                imageKind[profile.name] = block?.imageKind
                if block?.pinned == true {
                    pinned.insert(profile.name)
                } else if block != nil {
                    // The server block exists and does not claim the pin: that
                    // is an unpin from another machine, and it is authoritative
                    // (plugin.js:441-470).
                    pinned.remove(profile.name)
                }
                if block?.hidden == true {
                    hidden.insert(profile.name)
                } else {
                    // The absence of a truthy bit is the default visible
                    // state. Unlike a canonical pin, hidden has no legacy
                    // local authority to retain after a server answer.
                    hidden.remove(profile.name)
                }
            }

            // Preview follows click identity: a resolved canonical Bot Chat
            // always supplies the row text. Activity/unread independently use
            // the fresher of canonical and visible last_session, so a newer
            // scratch/cron delivery still advances recency without replacing
            // the forever-chat preview with unrelated text.
            lastActive[profile.name] = profile.freshestConversationSession?.lastActive ?? 0
            previews[profile.name] = profile.previewSession?.preview ?? ""
            activityPreviews[profile.name] =
                profile.freshestConversationSession?.preview ?? ""
            if let worker = profile.workerSession {
                workerSessions[profile.name] = worker
                workerActive[profile.name] = worker.lastActive ?? 0
            } else {
                workerSessions.removeValue(forKey: profile.name)
                workerActive[profile.name] = 0
            }
        }

        // A profile deleted elsewhere leaves no row to badge or rank.
        lastActive = lastActive.filter { seen.contains($0.key) }
        workerActive = workerActive.filter { seen.contains($0.key) }
        workerSessions = workerSessions.filter { seen.contains($0.key) }
        previews = previews.filter { seen.contains($0.key) }
        activityPreviews = activityPreviews.filter { seen.contains($0.key) }
        created = created.filter { seen.contains($0.key) }
        imageKind = imageKind.filter { seen.contains($0.key) }
        pinned = pinned.intersection(seen)
        hidden = hidden.intersection(seen)
        hasAvatar = hasAvatar.intersection(seen)
    }

    /// This profile's stored asset is a photo a human chose, so a 160×160 one
    /// is a real portrait rather than a rasterized face (plugin.js:415).
    func wantsStoredPhoto(_ botID: String) -> Bool { imageKind[botID] == "photo" }

    /// Record what this app just wrote to `imageKind`, so the guard above does
    /// not reject a portrait uploaded seconds ago just because the next
    /// `profiles.list` answer has not landed yet.
    func noteImageKind(_ botID: String, _ kind: String) { imageKind[botID] = kind }

    /// Desktop's `activityOf` (plugin.js:7641-7645): the newest of "this bot
    /// was created" and "this bot's last message", in ms. A freshly created bot
    /// therefore tops the roster until someone else gets a message.
    func activity(of botID: String) -> Double {
        max(created[botID] ?? 0, (lastActive[botID] ?? 0) * 1000)
    }

    func isPinned(_ botID: String) -> Bool { pinned.contains(botID) }

    func isHidden(_ botID: String) -> Bool { hidden.contains(botID) }

    func setPinned(_ botID: String, _ on: Bool) {
        if on { pinned.insert(botID) } else { pinned.remove(botID) }
    }

    func setHidden(_ botID: String, _ on: Bool) {
        if on { hidden.insert(botID) } else { hidden.remove(botID) }
    }

    /// True while the bot's newest activity is inside the 90 s window.
    func activeNow(_ botID: String, now: Date = .now) -> Bool {
        let nowSeconds = now.timeIntervalSince1970
        let conversationLive: Bool
        if let ts = lastActive[botID], ts > 0 {
            conversationLive = nowSeconds - ts < Self.activeWindow
        } else {
            conversationLive = false
        }
        guard !conversationLive else { return true }
        guard let worker = workerSessions[botID] else { return false }
        return worker.isLive(at: nowSeconds)
    }

    /// Timestamp displayed on the row. Conversation time remains the only
    /// ranking/unread input, but a currently live worker can make the row read
    /// as "now" when it is newer. Once its 150 s window expires, it vanishes
    /// from this presentation projection too.
    func lastActiveDate(_ botID: String, now: Date = .now) -> Date? {
        var timestamp = lastActive[botID] ?? 0
        let nowSeconds = now.timeIntervalSince1970
        if let worker = workerSessions[botID], worker.isLive(at: nowSeconds),
           let workerStamp = worker.lastActive, workerStamp > timestamp {
            timestamp = workerStamp
        }
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    func flush() {
        pollTask?.cancel()
        pollTask = nil
        rescope(to: nil)
    }
}

// MARK: - Reading the roster's signals

extension AppModel {

    /// Arm the signals poll. Called from the roster's `.task`, which is the
    /// first screen the app paints, and idempotent — a second call only
    /// re-scopes the tables to the gateway now connected.
    ///
    /// Desktop polls `profiles.list` every 5 s unconditionally (plugin.js:2218)
    /// because a laptop has no battery cliff and no suspended process. The
    /// phone shape of the same idea: 10 s while the roster is on screen, 40 s
    /// behind another tab — still fast enough that a cron delivery badges
    /// within a breath, and iOS suspends the timer outright once backgrounded.
    public func startRosterSignals() {
        let signals = RosterSignals.shared
        signals.rescope(to: LiveRuntime.shared.baseURL)
        guard signals.pollTask == nil else { return }
        signals.pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollRosterSignals()
                let visible = RosterSignals.shared.rosterVisible
                try? await Task.sleep(for: .seconds(visible ? 10 : 40))
            }
        }
    }

    /// Poll now rather than waiting out the current sleep — what a screen calls
    /// when it comes back on top and its numbers may be up to 40 s stale.
    /// Coalesces onto a poll already in flight.
    public func refreshRosterSignalsNow() async {
        guard !RosterSignals.shared.polling else { return }
        await pollRosterSignals()
    }

    /// One poll: `profiles.list` in, the whole roster out.
    ///
    /// Deliberately the same single call the connect-time refresh makes, not a
    /// second one beside it — `include_sessions` costs a per-profile DB scan
    /// gateway-side (methods_profiles.py:196) — and now deliberately the same
    /// single *builder* too. This used to freshen a subset of fields in place
    /// and re-derive cosmetics only when roster membership had changed, which
    /// meant a bot recolored on the laptop kept its old face here until someone
    /// created or deleted a profile, and meant the poll's own signals arrived on
    /// a different tick from the map that was supposed to agree with them.
    func pollRosterSignals() async {
        // Re-scoped on every tick, not only when the roster arms the poll: a
        // gateway switch has to invalidate pins and watermarks even if the user
        // made it from Connections and never came back to this screen.
        RosterSignals.shared.rescope(to: LiveRuntime.shared.baseURL)
        guard mode == .live, !isOffline, let client else { return }
        RosterSignals.shared.polling = true
        defer { RosterSignals.shared.polling = false }
        // Sampled before the await for the same reason `refreshRoster` samples
        // it: a pin written while this call was in flight must not be read back
        // out of a staler answer.
        guard let profiles = try? await client.listProfiles() else { return }
        applyRosterAnswer(profiles)
    }

    // The unread half of the roster answer lives in AppModelLive+Unread.swift:
    // `unreadMoves(scope:)` folds this answer's stamps into the durable marks
    // and `applyUnreadWatermark(_:)` writes the badges. It used to be here, over
    // a second watermark table kept by `RosterSignals` — see the note where that
    // table used to be for why one of the two had to go.

    /// The roster, in desktop's order (plugin.js:7657-7666): pinned bots float
    /// to the top **as a group**, and inside each group recency rules. Presence
    /// never reorders — a bot waking up does not move the list under a thumb.
    ///
    /// Sorts `liveRosterBots` rather than `bots`, so a row whose profile name
    /// also exists on a saved gateway paints the `@name-device` handle it is
    /// actually addressable by (plugin.js:2334 annotates the active-source row
    /// with exactly that). Same rows, same ids, same order — the annotation
    /// only rewrites `handleOverride`.
    public var rankedBots: [Bot] {
        let signals = RosterSignals.shared
        return liveRosterBots.enumerated().sorted { left, right in
            let lp = signals.isPinned(left.element.id)
            let rp = signals.isPinned(right.element.id)
            if lp != rp { return lp }
            let la = signals.activity(of: left.element.id)
            let ra = signals.activity(of: right.element.id)
            if la != ra { return la > ra }
            // No signal either way (a gateway that stores no ui_meta and a bot
            // with no history): keep the gateway's own order rather than
            // reshuffling on every repaint.
            return left.offset < right.offset
        }.map(\.element)
    }

    public func isPinned(_ botID: String) -> Bool { RosterSignals.shared.isPinned(botID) }

    /// Whether this primary roster row is hidden by Bot Mode metadata. Callers
    /// that build the union for rooms or @mentions must deliberately *not* use
    /// this as a membership filter; it is display-only roster state.
    public func isRosterHidden(_ botID: String) -> Bool {
        RosterSignals.shared.isHidden(botID)
    }

    public func isActiveNow(_ botID: String, now: Date = .now) -> Bool {
        RosterSignals.shared.activeNow(botID, now: now)
    }

    // There is deliberately no `hasStoredAvatar(_:)` here any more. It answered
    // "does a portrait exist?" from `has_avatar` — a promise about bytes nobody
    // had looked at yet — and every surface that drew a face branched on it,
    // choosing between `BotPortraitView` and `AvatarView` a second time when
    // `BotPortraitView` already makes exactly that choice from bytes actually
    // held. Two renderers picked by two different inputs is how a roster came
    // up correct and then changed identity on the next poll. One path now:
    // draw `BotPortraitView`, which shows a portrait when one has been fetched
    // AND passed the provenance guard, and the live vector face otherwise.

    // `noteChatOpened(_:)` — the one door every route into a chat reports
    // through — now lives beside the marks it advances
    // (AppModelLive+Unread.swift).

    /// Desktop's `relativeTime(last_active)` register — "4m", "2h", "3d" reads
    /// better on a chat roster than a wall clock, and a never-chatted bot gets
    /// nothing at all rather than a placeholder (plugin.js:4011-4016).
    public func rosterTimeLabel(_ botID: String, now: Date = .now) -> String {
        guard let date = RosterSignals.shared.lastActiveDate(botID, now: now) else { return "" }
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<604_800: return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / 604_800))w"
        }
    }

    /// `stripPreviewMarkdown` (plugin.js:2991-3007). Without it a bot that
    /// answers with a bulleted list puts literal asterisks and backticks in the
    /// roster; the plugin added this specifically so rows read "like Discord's".
    static func flattenPreview(_ raw: String) -> String {
        var text = raw
        func replace(_ pattern: String, _ template: String) {
            text = text.replacingOccurrences(of: pattern, with: template,
                                             options: [.regularExpression])
        }
        replace("```[\\s\\S]*?```", " ")          // fenced blocks
        replace("`([^`]*)`", "$1")                // inline code
        replace("!\\[([^\\]]*)\\]\\([^)]*\\)", "$1") // images → alt
        replace("\\[([^\\]]*)\\]\\([^)]*\\)", "$1")  // links → label
        replace("(\\*\\*|__)(.*?)\\1", "$2")      // bold
        replace("(?<![\\w*])\\*(?!\\s)([^*]+?)\\*(?![\\w*])", "$1") // emphasis
        replace("(?<![\\w_])_(?!\\s)([^_]+?)_(?![\\w_])", "$1")
        replace("~~(.*?)~~", "$1")                // strike
        replace("(?m)^\\s{0,3}#{1,6}\\s*", "")    // headings
        replace("(?m)^\\s{0,3}>\\s?", "")         // quotes
        replace("\\s+", " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Writing the look back

extension AppModel {

    /// The whole point of this phase: write `ui_meta["hermes-bots"]` so desktop
    /// sees the phone's edit.
    ///
    /// `custom: true` rides along on every explicit pick, because desktop's
    /// `botAppearance` (plugin.js:1641-1658) overrides the primary profile with
    /// a fixed violet squircle *unless* the user customized it — without the
    /// flag, a look chosen here for `default` would be ignored on the laptop.
    ///
    /// Talaria's own `ui_meta["talaria"]` block is written in the same call.
    /// It is a sibling TOP-LEVEL key, so the gateway's key-wise merge keeps
    /// both, and it remains the fallback for a bot whose desktop block a future
    /// gateway (or another client) drops.
    @discardableResult
    public func saveBotLook(botID: String, shape: AvatarShape, hue: AvatarHue,
                            title: String?) async -> CosmeticsWrite {
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Deliberately no `created` here. It is a birth stamp, not a touch
        // stamp: writing one on an edit would float a bot to the top of the
        // roster for having been recolored, which is not what the ranking key
        // means (plugin.js:7641 — max(created, last message)).
        let patch: [String: JSONValue?] = [
            "shape": .string(BotModeLook.shapeWord(shape)),
            "color": .string(BotModeLook.colorHex(hue)),
            "custom": .bool(true),
            // An empty title clears it back to the derived display name —
            // desktop saves `title.trim()` the same way (plugin.js:4995).
            "title": trimmed.isEmpty ? JSONValue?.none : .string(trimmed)
        ]

        applyLookLocally(botID: botID, shape: shape, hue: hue, title: trimmed)
        return await writeBotModeMeta(botID: botID, patch: patch, alsoTalaria: (shape, hue))
    }

    /// Pin to top (plugin.js:4056-4066). A plain boolean that rides ui_meta to
    /// every machine — pinning on the laptop pins on the phone, and the reverse
    /// is what this makes true.
    @discardableResult
    public func setBotPinned(botID: String, pinned: Bool) async -> CosmeticsWrite {
        // Optimistic: the row moves under the thumb that asked for it, before
        // any RPC (plugin.js:201-211 writes local first for the same reason).
        RosterSignals.shared.setPinned(botID, pinned)
        // `false` is written rather than deleted: desktop's merge reads a
        // present-but-false key as an explicit unpin, where an omitted one
        // would let a stale local pin on another machine stand.
        let outcome = await writeBotModeMeta(botID: botID, patch: ["pinned": .bool(pinned)],
                                             alsoTalaria: nil)
        // A pin is a one-tap action with no dialog to report into, so a write
        // that did not land undoes itself: the row sliding back is the message,
        // and it beats a phone that says pinned while the laptop disagrees.
        if outcome == .failed { RosterSignals.shared.setPinned(botID, !pinned) }
        return outcome
    }

    /// Desktop's roster Hide/Unhide is a Bot Mode metadata preference, not a
    /// session mutation.  `false` is intentionally written as a literal: an
    /// omitted key only means the legacy default and cannot carry an explicit
    /// unhide to another machine.
    @discardableResult
    public func setBotHidden(botID: String, hidden: Bool) async -> CosmeticsWrite {
        RosterSignals.shared.setHidden(botID, hidden)
        let outcome = await writeBotModeMeta(
            botID: botID,
            patch: BotModeMeta.hiddenProjection(hidden).mapValues { Optional($0) },
            alsoTalaria: nil)
        // This surface has no useful local fallback: it is specifically the
        // cross-device display setting. Avoid stranding a row invisibly hidden
        // on a gateway that rejected the mutation.
        if outcome != .persisted { RosterSignals.shared.setHidden(botID, !hidden) }
        return outcome
    }

    /// The ui_meta block a brand-new profile is born with. No merge needed —
    /// nothing exists yet — but the shape is identical to what an edit writes,
    /// `created` included, which is what floats a new bot to the top of the
    /// roster before it has said anything (plugin.js:5399-5401).
    public func newBotUIMeta(shape: AvatarShape, hue: AvatarHue, title: String) -> JSONValue {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var block: [String: JSONValue] = [
            "shape": .string(BotModeLook.shapeWord(shape)),
            "color": .string(BotModeLook.colorHex(hue)),
            "custom": .bool(true),
            "imageKind": .string("shape"),
            "created": .number(Date().timeIntervalSince1970 * 1000)
        ]
        if !trimmed.isEmpty { block["title"] = .string(trimmed) }
        return .object([
            "hermes-bots": .object(block),
            "talaria": .object(["shape": .string(shape.rawValue), "hue": .string(hue.rawValue)])
        ])
    }

    /// Read-merge-write over the live `ui_meta["hermes-bots"]` block.
    ///
    /// The read is deliberately fresh rather than the roster row in memory:
    /// ui_meta rides every `profiles.list`, but a desktop sitting beside the
    /// phone may have rewritten the block since the last poll, and the merge
    /// below decides what survives. `nil` in the patch deletes a key.
    private func writeBotModeMeta(botID: String, patch: [String: JSONValue?],
                                  alsoTalaria: (AvatarShape, AvatarHue)?) async -> CosmeticsWrite {
        guard mode == .live else { return .persisted }
        guard let context = try? await profileContext(for: botID) else { return .failed }
        let signals = RosterSignals.shared
        do {
            return try await withBotModeMetaMutation(route: context.route) {
                signals.writing.insert(botID)
                defer { signals.writing.remove(botID) }

                var block: [String: JSONValue] = [:]
                do {
                    let profiles = try await context.client.listProfiles(includeSessions: false)
                    guard let row = profiles.first(where: { $0.name == context.route.profile }) else {
                        return .failed
                    }
                    block = row.uiMeta?["hermes-bots"]?.objectValue ?? [:]
                } catch {
                    return .failed
                }

                // Legacy `chat` pointers are deliberately ignored and never
                // reasserted. Current Hermes resolves `(profile, "Bot Chat")`.
                block.removeValue(forKey: "chat")
                for (key, value) in patch {
                    if let value { block[key] = value } else { block.removeValue(forKey: key) }
                }

                var uiMeta: [String: JSONValue] = ["hermes-bots": .object(block)]
                if let (shape, hue) = alsoTalaria {
                    uiMeta["talaria"] = .object(["shape": .string(shape.rawValue),
                                                 "hue": .string(hue.rawValue)])
                }

                do {
                    let applied = try await context.client.applyProfileEdit(
                        name: context.route.profile, ProfileEdit(uiMeta: .object(uiMeta)))
                    if applied["ui_meta"] == true {
                        await refreshProfileRoster(gatewayID: context.route.gatewayID)
                        return .persisted
                    }
                    // No `applied` contract at all is the documented older-gateway
                    // shape, not a refusal (plugin.js:250-262).
                    return applied.isEmpty ? .unsupported : .failed
                } catch {
                    return .failed
                }
            }
        } catch {
            return .failed
        }
    }

    /// Mirror a saved look onto the roster row immediately, so the sheet's
    /// caller sees the change before the next poll — and so a row whose write
    /// is in flight is not freshened back to the old value.
    private func applyLookLocally(botID: String, shape: AvatarShape, hue: AvatarHue,
                                  title: String) {
        guard let index = bots.firstIndex(where: { $0.id == botID }) else { return }
        bots[index].shape = shape
        bots[index].hue = hue
        bots[index].title = title.isEmpty ? nil : title
    }
}

// MARK: - Avatar images (generate, upload, stage, commit)

/// An avatar edit in progress. Every source — generated, uploaded, cleared —
/// is STAGED and only written by Save, which is desktop's rule too
/// (plugin.js:2056-2060: a direct write here "gets clobbered by Save's own
/// image state"). It also means Cancel actually cancels: Talaria's first
/// portrait pass wrote `profiles.set_asset` the moment the button was tapped,
/// so backing out left the new face behind.
public struct AvatarDraft: Equatable, Sendable {
    /// Bytes the user picked or generated, not yet written.
    public var image: Data?
    /// The stored portrait should be removed on save.
    public var clearsImage = false

    public init(image: Data? = nil, clearsImage: Bool = false) {
        self.image = image
        self.clearsImage = clearsImage
    }

    public var isEmpty: Bool { image == nil && !clearsImage }
}

/// The staged generator's answer. `PortraitFailure` is a plain reason code
/// rather than an `Error` (it is the sheet's copy key, not a throw), so the
/// two outcomes are spelled out instead of going through `Result`.
public enum PortraitAttempt: Sendable {
    case image(Data)
    case failure(PortraitFailure)
}

extension AppModel {

    /// Generate a portrait WITHOUT writing it — the staged half of the flow.
    /// Returns the decoded bytes so the sheet can preview them, or why not.
    public func makePortrait(prompt: String, botID: String? = nil) async -> PortraitAttempt {
        guard mode == .live else { return .failure(.notLive) }
        let selectedClient: GatewayClient
        if let botID {
            guard let context = try? await profileContext(for: botID) else {
                return .failure(.failed(GatewayRouteError.noRoute.localizedDescription))
            }
            selectedClient = context.client
        } else {
            guard let client else { return .failure(.notLive) }
            selectedClient = client
        }
        let generated: GeneratedPortrait
        do {
            generated = try await selectedClient.generatePortrait(prompt: prompt)
        } catch let error as GatewayError {
            return .failure(.failed(error.message))
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
        guard generated.available else { return .failure(.unavailable) }
        if let message = generated.error, !message.isEmpty { return .failure(.failed(message)) }
        guard let raw = generated.dataURL else { return .failure(.noBytes) }
        guard let payload = ProfileAssetStore.assetDataURL(from: raw),
              let bytes = ProfileAssetStore.decode(dataURL: payload) else {
            return .failure(.tooLarge)
        }
        return .image(bytes)
    }

    /// Commit a staged avatar. Bytes go to the profile asset store, never into
    /// ui_meta: the block is capped at 64 KB and rides every `profiles.list`,
    /// which is exactly why desktop strips `image` before writing it
    /// (plugin.js:217-227).
    @discardableResult
    public func commitAvatarDraft(botID: String, draft: AvatarDraft) async -> PortraitFailure? {
        guard !draft.isEmpty else { return nil }
        if draft.clearsImage, draft.image == nil {
            if let failure = await clearAvatarPortrait(botID: botID) { return failure }
            await stampImageKind(botID: botID, photo: false)
            return nil
        }
        guard let bytes = draft.image else { return nil }
        guard mode == .live else {
            // Demo mode has no asset store; the cache alone carries the face.
            ProfileAssetStore.shared.set(bytes, for: botID)
            return nil
        }
        guard let context = try? await profileContext(for: botID) else {
            return .failed(GatewayRouteError.noRoute.localizedDescription)
        }
        let cacheID = context.route.qualifiedID
        let cacheEpoch = ProfileAssetStore.shared.captureEpoch()
        guard let payload = Self.assetDataURL(for: bytes) else { return .tooLarge }
        do {
            try await context.client.setProfileAvatar(name: context.route.profile,
                                                      dataURL: payload)
        } catch let error as GatewayError {
            return .failed(error.message)
        } catch {
            return .failed(error.localizedDescription)
        }
        if ProfileAssetStore.shared.isCurrent(epoch: cacheEpoch) {
            ProfileAssetStore.shared.set(bytes, for: cacheID)
        }
        await stampImageKind(botID: botID, photo: true)
        return nil
    }

    /// `imageKind` records "this is a real picture the user chose", not a
    /// machine-made copy of a vector face. Desktop's only consumer is its
    /// rasterization backfill guard (plugin.js:415), which refuses to park a
    /// 160 px render of a live face over a real photo — so stamping it keeps a
    /// Talaria-set portrait safe from a laptop's own housekeeping.
    private func stampImageKind(botID: String, photo: Bool) async {
        guard mode == .live else { return }
        let kind = photo ? "photo" : "shape"
        // Locally too, ahead of the roster answer that will carry it: Talaria's
        // own fetch guard reads `imageKind` (AppModelLive+Profiles.swift
        // `refreshAvatar`), and a portrait uploaded seconds ago must not be
        // refused for the ten seconds it takes the next `profiles.list` to say
        // what this write just said.
        RosterSignals.shared.noteImageKind(botID, kind)
        _ = await writeBotModeMeta(botID: botID,
                                   patch: ["imageKind": .string(kind)],
                                   alsoTalaria: nil)
    }

    /// Camera-roll bytes are HEIC on any modern iPhone and can be 12 MP —
    /// square-crop and downscale before either previewing or uploading, the
    /// same normalization desktop does at 256 px (plugin.js:1663-1681). 512
    /// keeps a portrait crisp on a 3× phone and still lands far under the
    /// 2 MB asset ceiling.
    public static func normalizedAvatarImage(_ data: Data) -> Data? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        let side = min(image.size.width, image.size.height)
        guard side > 0 else { return nil }
        let crop = CGRect(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2,
                          width: side, height: side)
        let target = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: target)
        let square = renderer.image { _ in
            image.draw(in: CGRect(x: -crop.origin.x * target.width / side,
                                  y: -crop.origin.y * target.height / side,
                                  width: image.size.width * target.width / side,
                                  height: image.size.height * target.height / side))
        }
        return square.jpegData(compressionQuality: 0.86)
        #else
        return ProfileAssetStore.reencodeJPEG(data, maxDimension: 512, quality: 0.86)
        #endif
    }

    /// Wrap already-normalized bytes as the data URL `profiles.set_asset`
    /// takes, re-encoding only if something oversized slipped through.
    static func assetDataURL(for data: Data) -> String? {
        if data.count <= ProfileAssetStore.maxAssetBytes {
            return "data:image/jpeg;base64," + data.base64EncodedString()
        }
        guard let smaller = ProfileAssetStore.reencodeJPEG(data, maxDimension: 512, quality: 0.8),
              smaller.count <= ProfileAssetStore.maxAssetBytes else { return nil }
        return "data:image/jpeg;base64," + smaller.base64EncodedString()
    }

    /// Desktop's custom-prompt wrapper (plugin.js:1786-1793): the user's words,
    /// plus the constraints that keep the result readable at 46 pt.
    public static func portraitPrompt(describe: String) -> String {
        describe.trimmingCharacters(in: .whitespacesAndNewlines)
            + ". Avatar for an AI agent: centered, bold flat vector style, "
            + "solid color background, no text."
    }
}
