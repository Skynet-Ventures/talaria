import Foundation

// ── Unread watermarks: the diff itself ───────────────────────────────────────
//
// BOT-PARITY-PLAN Phase D1. Desktop Bot Mode does not count messages to decide
// what is unread — it keeps a per-bot high-water mark of
// `last_session.last_active` and re-reads the roster on a timer
// (`trackInboundActivity`, plugin.js:86-150). Any bot whose stamp has moved
// past its mark, and whose chat is not the one on screen, gets the dot.
//
// That indirection is the whole point. An event-derived count only sees traffic
// that arrived while this app was attached and awake, which on a phone is a
// small and arbitrary slice of the truth. The watermark is a comparison against
// the gateway's own record, so ONE poll after a cold launch catches every path
// at once: a cron delivery, a CLI turn, the laptop, a bot-to-bot handoff, work
// that finished while the screen was off.
//
// This file is the decision and nothing else — no storage, no gateway, no
// SwiftUI — so `talaria-verify` can replay a captured roster sequence through
// it on every build (ProtocolChecks+Unread.swift). The durable half lives in
// TalariaUI/AppModelLive+Unread.swift.
//
// Four rules, each with a plausible wrong version:
//
// * The mark advances BEFORE both guards (plugin.js:120-122). It records what
//   the phone has *observed*, not what the user has read — so a poll that
//   deliberately raises no badge still moves it. Otherwise leaving a chat would
//   badge you for the reply you just watched arrive.
// * `max(prev, ts)` — never backwards. A compressed lineage, a restored
//   `state.db`, or a gateway whose clock stepped back must not resurrect
//   already-read traffic.
// * `ts > prev`, strictly. A roster answer repeating the same stamp (the common
//   case: nothing happened) is silence, not news.
// * A bot with no `last_session` at all reads `ts = 0` and can never badge.
//
// ── Wire source, current Hermes a4f16e3f ────────────────────────────────────
//
// `profiles.list {include_sessions: true}` reports `last_session` (newest
// conversation activity) independently from `canonical_session` (the exact
// Bot Chat registry identity). Talaria keeps preview/click identity canonical
// while folding the freshest retained conversation stamp into this policy; it
// never sends a client-carried session pointer. The captured activity sequence
// that originally established the phone policy was:
//
//   default     1787085050.329278  "[Cron delivery: markets-close-wrap] …"
//   code-review null                (no last_session on any of the 12 polls)
//   deepseek    1787018593.668624   flat
//   ez-qa       1787085212.957258 → 1787085312.02232 → 1787085321.234668
//   simmy       1786902827.011681   flat
//
// `ez-qa` moved twice inside four minutes from a client that was not this
// phone, and nothing else moved: exactly the cross-source delivery the model is
// for. `default`'s newest line is a cron delivery — traffic no event-driven
// count on this device would ever have seen. `code-review` is the null case.
// Those three snapshots are the fixture `ProtocolChecks+Unread` replays.

/// One gateway's marks. Codable because the phone persists it: see the note on
/// `seeded` for why that is a deliberate divergence from upstream.
public struct UnreadWatermarkScope: Codable, Equatable, Sendable {

    /// This phone has seen this gateway's roster at least once.
    ///
    /// **The one deliberate divergence from upstream.** `watermarksSeeded` is a
    /// module-level flag in the plugin, reset only when the renderer reloads —
    /// on a laptop that is measured in days, so "seeded once per mount" and
    /// "seeded once, ever" are nearly the same statement. On a phone the process
    /// is killed minutes after backgrounding, and a per-launch seed would
    /// swallow the entire population of activity this model exists to catch:
    /// every cold start would quietly declare the backlog read. So the flag is
    /// persisted alongside the marks, and "seeded" means *this phone has seen
    /// this gateway's roster at least once* — a fresh install still opens on a
    /// calm roster instead of badging years of history, which is the property
    /// upstream's flag is protecting.
    public var seeded: Bool

    /// bot id → newest activity this phone has observed, unix seconds.
    public var marks: [String: Double]

    /// Device clock, used for evicting the least recently used scope and
    /// nothing else.
    public var touched: Double

    public init(seeded: Bool = false, marks: [String: Double] = [:], touched: Double = 0) {
        self.seeded = seeded; self.marks = marks; self.touched = touched
    }
}

public enum UnreadWatermarks {

    /// Gateways remembered. Beyond this the least recently seen is dropped —
    /// its bots simply re-seed silently if it ever comes back, which is the same
    /// calm first screen a fresh install gets.
    public static let scopeLimit = 8

    /// Marks per gateway. A roster this size is already far past what the screen
    /// can express; the cap only exists so a pathological gateway cannot grow
    /// the blob without bound.
    public static let markLimit = 512

    public struct Fold: Equatable, Sendable {
        public var scope: UnreadWatermarkScope
        /// Bots whose activity moved past their mark and are not spared.
        /// Sorted, so a caller reporting or animating the set is deterministic
        /// where dictionary iteration is not.
        public var moved: [String]
    }

    /// Fold one roster answer in — upstream's `trackInboundActivity`
    /// (plugin.js:113-150).
    ///
    /// - Parameters:
    ///   - activity: bot id → `last_session.last_active` in unix seconds, the
    ///     full roster in one call. An EMPTY dictionary is never a statement
    ///     about anything: it is what a torn-down or re-scoping roster looks
    ///     like, and seeding on it would declare a gateway seen that this phone
    ///     has not actually listed yet — so it is returned untouched.
    ///   - spared: bots that must not badge from this answer. The chat on
    ///     screen (plugin.js:129-132), plus whatever the caller's own grace
    ///     window adds.
    public static func fold(_ scope: UnreadWatermarkScope, activity: [String: Double],
                            spared: Set<String> = [], now: Double) -> Fold {
        guard !activity.isEmpty else { return Fold(scope: scope, moved: []) }
        var next = scope
        let seeding = !next.seeded
        next.seeded = true
        next.touched = now

        var moved: [String] = []
        for (botID, stamp) in activity {
            let ts = max(0, stamp)
            let previous = next.marks[botID] ?? 0
            // Monotonic, and raised BEFORE either guard below: the mark says
            // what this phone has seen, not what the user has read
            // (plugin.js:120-122).
            next.marks[botID] = max(previous, ts)
            guard !seeding, ts > previous, !spared.contains(botID) else { continue }
            moved.append(botID)
        }

        // Marks for bots absent from this answer are KEPT. Upstream drops one
        // only when the bot itself is deleted (plugin.js:564), and the
        // difference matters: a roster that momentarily omits a row would
        // otherwise come back with a zeroed mark and badge its entire history.
        if next.marks.count > markLimit {
            let survivors = next.marks.sorted { $0.value > $1.value }.prefix(markLimit)
            next.marks = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
        }
        return Fold(scope: next, moved: moved.sorted())
    }

    /// The user is looking at this bot: its mark jumps to the newest activity
    /// this phone has observed, whether or not a poll has landed since.
    ///
    /// Desktop clears the flag before any RPC runs (plugin.js:3915-3918),
    /// because a tap that has to wait for a round trip to clear a dot reads as a
    /// broken tap.
    public static func acknowledge(_ botID: String, observed: Double,
                                   in scope: UnreadWatermarkScope,
                                   now: Double) -> UnreadWatermarkScope {
        var next = scope
        next.marks[botID] = max(next.marks[botID] ?? 0, observed)
        next.touched = now
        return next
    }

    // There is deliberately no per-bot `forget` here. plugin.js:561-566 drops
    // `rosterWatermarks.delete(bot.name)` when a profile is deleted, and that
    // is the one case where dropping a mark is right — but Talaria has no
    // profile-delete path at all (no `profiles.delete` call anywhere), so the
    // function would have no caller and the `fold` rule above, which
    // deliberately KEEPS marks for bots merely missing from an answer, would be
    // the only thing standing. Add it with the delete verb, not before it.

    /// Keep the `scopeLimit` most recently touched gateways.
    public static func evict(_ scopes: [String: UnreadWatermarkScope]) -> [String: UnreadWatermarkScope] {
        guard scopes.count > scopeLimit else { return scopes }
        let keep = scopes.sorted { $0.value.touched > $1.value.touched }.prefix(scopeLimit)
        return Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }
}
