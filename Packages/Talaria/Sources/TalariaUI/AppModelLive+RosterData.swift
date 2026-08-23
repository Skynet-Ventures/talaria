import Foundation
import TalariaKit
import TalariaTheme

// ── Roster data: the canonical-chat round trip and the liveness set ──────────
//
// Two halves of Bot Mode roster policy, both derived from the SAME
// `profiles.list` answer the roster already polls — no second RPC, because
// `include_sessions` costs a per-profile database scan gateway-side
// (methods_profiles.py `_latest_profile_session_row`).
//
// **1. `canonical_session`.** Current Hermes resolves the profile's exact
// hidden `Bot Chat` registry row server-side. It drives preview while activity
// uses the fresher of canonical and visible `last_session`. No client pointer
// is sent, persisted, grandfathered, or inferred from recency.
//
// **2. The active-now set.** Desktop's `activeBots` (plugin.js:3831-3839): the
// bot the gateway is running a turn for, plus every bot whose conversation
// landed inside the 90-second liveness window or whose separate worker session
// is live for 150 seconds. Pure, and it follows the roster's own order —
// presence must never reorder or hide the list beneath it, which is the whole
// reason the upstream function is written as a filter over the roster rather
// than a sort of its own.
//
// Older gateways omit `canonical_session`; that compatibility omission is
// inconclusive and never permission to infer identity from `last_session`.

extension AppModel {

    // MARK: - The canonical-chat round trip

    /// Source-compatible appearance hook. Canonical identity is now entirely
    /// gateway-owned (`canonical_session` + exact-title lookup), so there is no
    /// client pointer to synchronize.
    public func syncCanonicalPins() async {
        // Intentionally empty. Kept until the view call site can be removed
        // without coupling this canonical migration to ActiveNowStrip.
    }

    // MARK: - The active-now set

    /// Bots that are working right now, in the roster's own order.
    ///
    /// Desktop's `activeBots` (plugin.js:3831-3839) is
    /// `busyTurn || inWindow`:
    ///
    /// * **busyTurn** — upstream is `bot.name === activeProfile &&
    ///   gatewayState === 'busy'`, which is a single-profile desktop's way of
    ///   saying "this bot is mid-turn". Talaria tracks that per bot already
    ///   (`LiveRuntime.workingBotIDs` → `Bot.status`), so the port reads the
    ///   per-bot flag instead of guessing from a global gateway state. The
    ///   upstream comment is emphatic that this is *not* "every bot whenever
    ///   the gateway is busy", and the per-bot form cannot drift into that.
    /// * **inWindow** — freshest conversation activity within 90 s, or a
    ///   separate `worker_session.last_active` inside Hermes' 150 s worker
    ///   window. The worker half is display-only liveness: it never enters the
    ///   rank or unread watermark, which both read conversation activity.
    ///
    /// Output follows `rankedBots`, so the strip reads top-to-bottom in the
    /// same order as the list under it and presence can never reorder that
    /// list. `remoteSource` needs no filter here: Talaria's `bots` are always
    /// the live gateway's own, and foreign rows live in their own section.
    public func activeNowBots(now: Date = .now) -> [Bot] {
        // Hidden is a display preference, so it does not suppress the worker
        // poll or unread watermark. It does suppress this visual rail: showing
        // a hidden bot above the roster would leak the very row the user chose
        // not to see. Foreign rows are never in `rankedBots` and therefore
        // remain untouched by this primary-only rule.
        rankedBots.filter {
            !isRosterHidden($0.id)
                && ($0.status == .working || isActiveNow($0.id, now: now))
        }
    }

    /// Just the ids — what a view diffs on to decide whether membership
    /// actually changed, without holding whole rows.
    public func activeNowBotIDs(now: Date = .now) -> [String] {
        activeNowBots(now: now).map(\.id)
    }
}

// MARK: - Copy

extension CopyPack {

    /// The strip's own label. Desktop prints an uppercase tracked "Active now"
    /// (plugin.js:6905-6908); each pack says the same thing in its own voice.
    static func activeNowTitle(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Active now"
        case .control: "ACTIVE NOW"
        case .ink: "stirring"
        }
    }

    /// Screen-reader name for the strip as a region.
    static func activeNowRegion(_ t: ThemeID) -> String {
        switch t {
        case .soft: "Active now"
        case .control: "ACTIVE NOW"
        case .ink: "Those stirring now"
        }
    }

    /// Chip action. Desktop's tooltip is `Open <Name>'s chat`
    /// (plugin.js:6919); on a phone the same words are the VoiceOver label.
    static func activeNowOpen(_ name: String, _ t: ThemeID) -> String {
        switch t {
        case .soft: "Open \(name)'s chat"
        case .control: "OPEN \(name.uppercased()) CHAT"
        case .ink: "Turn to \(name)"
        }
    }

    /// Announced when a bot joins the strip — desktop gets this free from
    /// `aria-live="polite"` on the region (plugin.js:6896-6898). VoiceOver
    /// needs the sentence written out.
    static func activeNowJoined(_ names: [String], _ t: ThemeID) -> String {
        let list = names.joined(separator: ", ")
        switch t {
        case .soft:
            return names.count == 1 ? "\(list) is active now" : "\(list) are active now"
        case .control:
            return "ACTIVE: \(list.uppercased())"
        case .ink:
            return names.count == 1 ? "\(list) stirs" : "\(list) stir"
        }
    }
}
