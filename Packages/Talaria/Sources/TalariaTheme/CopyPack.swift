import Foundation
import TalariaKit

/// Per-theme voice. Approvals become Holds become Seals; Approve becomes
/// RELEASE becomes grant-the-seal. Ported 1:1 from the prototype's copy().
public struct CopyPack: Sendable {
    public enum Tab: String, CaseIterable, Sendable {
        case home, activity, approvals, a2a, artifacts
    }

    public var kickerHome: String
    public var titleHome: String
    public var kickerActivity: String
    public var titleActivity: String
    public var titleApprovals: String
    public var kickerA2A: String
    public var titleA2A: String
    public var approvalsLead: String
    public var a2aLead: String
    public var a2aSep: String
    public var a2aFoot: String
    public var routinesBtn: String
    public var kickerRoutines: String
    public var titleRoutines: String
    public var next: String
    public var newRoutine: String
    public var otherBots: String
    public var cronNote: String
    public var kickerConn: String
    public var titleConn: String
    public var appearance: String
    public var gatewaysSec: String
    public var addGateway: String
    public var notifySec: String
    public var pushNote: String
    public var tag: String
    public var unto: String
    public var approve: String
    public var approveSend: String
    public var deny: String
    public var pendChip: String
    public var digestHead: String
    public var digestLink: String
    public var cancel: String
    public var createTitle: String
    public var createOk: String
    public var advTitle: String
    public var modelSec: String
    public var skillsSec: String
    public var skillsNote: String
    public var phName: String
    public var phJob: String
    public var phDesc: String
    public var createNote: String
    public var voiceHead: String
    public var voiceQuote: String
    public var mute: String
    public var textBtn: String
    public var bnMeta: String
    public var offline: String
    public var titleArtifacts: String
    public var kickerArtifacts: String
    public var artifactsLead: String
    public var sessionsSec: String
    public var contextSec: String
    public var yoloName: String
    public var yoloSub: String
    public var memorySec: String
    public var duplicate: String
    public var editLook: String
    public var deleteNote: String
    public var searchPh: String
    public var queued: String
    public var later: String
    public var obSkip: String
    public var obTitle0: String
    public var obSub0: String
    public var obBody0: String
    public var obCta0: String
    public var obAlt0: String
    public var obTitle1: String
    public var obNote1: String
    public var obCta1: String
    public var obTitle2: String
    public var obOauth: String
    public var obBasic: String
    public var obNote2: String
    public var obTitle3: String
    public var obLook: String
    public var obNotifT: String
    public var obNotifS: String
    public var obAllow: String
    public var obAllowed: String
    public var obCta3: String
    /// Tab bar labels in order: home, activity, approvals, a2a, artifacts.
    public var tabs: [(label: String, tab: Tab)]
    // Post-prototype copy (defaulted so every theme inherits the base voice).
    public var cloudURLPlaceholder: String = "agent dashboard URL — https://…"
    public var cloudURLHint: String = "Paste your cloud agent's dashboard URL from portal.nousresearch.com — in-app agent discovery is coming. It signs in with the same Nous OAuth flow."
    public var noGatewayNote: String = "No gateway to sign in to yet — go back and enter your gateway's URL, or explore with demo data."
    public var emptyRosterTitle: String = "No bots yet"
    public var emptyRosterBody: String = "Connect a gateway and your Hermes profiles appear here — same roster as your desktop."
    public var demoBannerTitle: String = "Exploring demo data"
    public var demoBannerBody: String = "Everything here is canned. Connect a real gateway below, or step out."
    public var demoLeave: String = "Leave demo mode"
    public var demoReonboard: String = "Show onboarding again"
    /// Composer placeholder. Takes the bot, not its profile id, so the
    /// placeholder resolves through the one identity path — the @handle you
    /// would actually tag (default → @hermes) or the display title — and
    /// never prints the raw profile name.
    public var composer: @Sendable (Bot) -> String
    public var earlierMessages: String = "Earlier messages"

    public static func pack(for theme: ThemeID) -> CopyPack {
        switch theme {
        case .soft: .soft
        case .control: .control
        case .ink: .ink
        }
    }

    public static let soft = CopyPack(
        kickerHome: "TALARIA // UPLINK", titleHome: "Bots",
        kickerActivity: "EVENT LOG", titleActivity: "Activity",
        titleApprovals: "Approvals",
        kickerA2A: "AGENT ⇄ AGENT", titleA2A: "Agent Inbox",
        approvalsLead: "Bots block on these — clear them and work resumes.",
        a2aLead: "Bots talking to bots. You watch; @mention to steer.",
        a2aSep: "→",
        a2aFoot: "Handoffs run as real cross-profile messages with attribution.",
        routinesBtn: "Routines", kickerRoutines: "HERMES CRON", titleRoutines: "Routines ·",
        next: "next", newRoutine: "+ New routine — “every morning at 7, …”", otherBots: "Other bots",
        cronNote: "Backed by Hermes cron as [bot:name] entries — runs land in this bot’s chat.",
        kickerConn: "UPLINKS", titleConn: "Connections", appearance: "Appearance",
        gatewaysSec: "Gateways", addGateway: "+ Add gateway — URL or Hermes Cloud",
        notifySec: "Notify me when",
        pushNote: "Agent replies, mentions and finished work arrive over APNs from the gateway’s push relay; Time Sensitive approvals can break through Focus when iOS allows it.",
        tag: "NEEDS APPROVAL", unto: "to",
        approve: "Approve", approveSend: "Approve & send", deny: "Deny", pendChip: "PENDING",
        digestHead: "DIGEST · 3 OF 6", digestLink: "Open full digest →",
        cancel: "Cancel", createTitle: "New Bot", createOk: "Create", advTitle: "Advanced",
        modelSec: "MODEL PIN", skillsSec: "SKILLS",
        skillsNote: "Tap to exclude a bundled skill from this profile.",
        phName: "name — the profile id", phJob: "Job — e.g. Email triage",
        phDesc: "Personality & standing orders — becomes SOUL.md",
        createNote: "Creates a full Hermes profile via profiles.create — isolated config, memory, skills and history.",
        voiceHead: "VOICE ·",
        voiceQuote: "“Two more KV-cache papers queued. Want the summaries in tomorrow’s digest, or now?”",
        mute: "MUTE", textBtn: "TEXT", bnMeta: "now · TALARIA",
        offline: "Gateway unreachable — showing last known state. Bots keep working on homelab.",
        titleArtifacts: "Artifacts", kickerArtifacts: "SESSION OUTPUTS",
        artifactsLead: "What your bots produced — tap one to jump to its session.",
        sessionsSec: "Recent sessions", contextSec: "Context window",
        yoloName: "YOLO mode",
        yoloSub: "Skips dangerous-command approvals for this bot. Know what you are turning off.",
        memorySec: "Memory", duplicate: "Duplicate bot", editLook: "Edit look & soul",
        deleteNote: "Non-default profiles can be deleted after confirmation.",
        searchPh: "Bots, sessions, artifacts, actions…",
        queued: "queued · sends when linked", later: "Later",
        obSkip: "Skip", obTitle0: "Talaria", obSub0: "Your agents, in your pocket.",
        obBody0: "Every bot is a Hermes profile on your gateway — this phone is a window onto the same roster as your desktop.",
        obCta0: "Connect a gateway", obAlt0: "Explore with demo data",
        obTitle1: "Point at your gateway",
        obNote1: "The app speaks to a running hermes serve — the same JSON-RPC and WebSocket surface the desktop uses.",
        obCta1: "Continue",
        obTitle2: "Sign in", obOauth: "Sign in with Nous Research", obBasic: "Username & password",
        obNote2: "OAuth for anything beyond your own network; basic auth only on a trusted LAN or tailnet.",
        obTitle3: "6 bots found on homelab", obLook: "Pick a look",
        obNotifT: "Notifications",
        obNotifS: "Approvals, agent replies, mentions, finished runs — the gateway pushes, your phone pings.",
        obAllow: "Allow", obAllowed: "Enabled ✓", obCta3: "Enter the roster",
        tabs: [("Bots", .home), ("Activity", .activity), ("Approvals", .approvals),
               ("Inbox", .a2a), ("Artifacts", .artifacts)],
        composer: { bot in "Message @\(bot.handle)" }
    )

    public static let control: CopyPack = {
        var c = CopyPack.soft
        c.titleHome = "Roster"
        c.titleApprovals = "Holds"
        c.titleA2A = "Comms"
        c.approvalsLead = "Agents are blocked on these. Release or abort."
        c.a2aLead = "Cross-profile traffic, attributed. You watch; @mention to steer."
        c.routinesBtn = "CRON"
        c.tag = "HOLD — APPROVAL REQUIRED"
        c.approve = "RELEASE"; c.approveSend = "RELEASE"; c.deny = "ABORT"; c.pendChip = "HOLD"
        c.unto = "→"
        c.cancel = "CANCEL"; c.createTitle = "New Agent"; c.createOk = "DEPLOY"; c.advTitle = "ADVANCED"
        c.otherBots = "OTHER AGENTS"
        c.a2aFoot = "hermes -p <bot> chat -c \"Agent Inbox\" — real handoffs"
        c.addGateway = "+ ADD UPLINK — URL / HERMES CLOUD"
        c.digestLink = "OPEN FULL DIGEST →"
        c.newRoutine = "+ NEW ROUTINE — \"every morning at 7, …\""
        c.bnMeta = "NOW·TALARIA"
        c.offline = "LINK DOWN — LAST KNOWN STATE. AGENTS CONTINUE ON HOMELAB."
        c.voiceHead = "VOICE LINK ·"
        c.titleArtifacts = "Vault"
        c.queued = "QUEUED — NO LINK"; c.later = "LATER"
        c.duplicate = "DUPLICATE AGENT"; c.editLook = "EDIT LOOK & SOUL"
        c.sessionsSec = "RECENT SESSIONS"; c.contextSec = "CONTEXT WINDOW"
        c.memorySec = "MEMORY"; c.yoloName = "YOLO MODE"
        c.tabs = [("BOTS", .home), ("FEED", .activity), ("HOLDS", .approvals),
                  ("COMMS", .a2a), ("VAULT", .artifacts)]
        c.composer = { bot in "Transmit to @\(bot.handle)" }
        return c
    }()

    public static let ink: CopyPack = {
        var c = CopyPack.soft
        c.kickerHome = "THE HOUSE OF HERMES"; c.titleHome = "The Roster"
        c.kickerActivity = "EVERY DEED, RECORDED"; c.titleActivity = "The Ledger"
        c.titleApprovals = "The Seals"
        c.kickerA2A = "FAMILIARS CONFER · YOU OBSERVE"; c.titleA2A = "The Parley"
        c.approvalsLead = "The familiars wait upon your hand."
        c.a2aLead = "Cross-profile messages, attributed. @mention to steer."
        c.a2aSep = "unto"
        c.a2aFoot = "CROSS-PROFILE MESSAGES, ATTRIBUTED"
        c.routinesBtn = "rites"; c.kickerRoutines = "KEPT BY HERMES CRON"; c.titleRoutines = "The Rites of"
        c.newRoutine = "+ inscribe a new rite — “every morning at seven…”"
        c.otherBots = "OF THE OTHER FAMILIARS"
        c.cronNote = "Kept as [bot:name] cron entries; each run is written into this familiar’s chat."
        c.kickerConn = "GATEWAYS & TIDINGS"; c.titleConn = "The Ways"; c.appearance = "THE GUISE"
        c.gatewaysSec = "THE WAYS"; c.addGateway = "+ open a new way — url or hermes cloud"
        c.notifySec = "SEND TIDINGS WHEN"
        c.pushNote = "Replies, mentions and finished work travel by APNs through the gateway’s push relay; a waiting seal may break through Focus."
        c.tag = "AWAITING YOUR SEAL"; c.unto = "unto"
        c.approve = "grant the seal"; c.approveSend = "grant the seal"; c.deny = "refuse"; c.pendChip = ""
        c.digestHead = "THE MORNING DIGEST · FIG. I–III"; c.digestLink = "open the full digest →"
        c.cancel = "abandon"; c.createTitle = "A Summoning"; c.createOk = "summon"; c.advTitle = "the finer arts"
        c.skillsSec = "GIFTS (SKILLS)"; c.skillsNote = "Strike through a gift to withhold it."
        c.phName = "true name — the profile id"; c.phJob = "Office — e.g. Email triage"
        c.phDesc = "Nature & standing orders — inscribed as SOUL.md"
        c.createNote = "A full Hermes profile is inscribed — config, memory, gifts and history — via profiles.create."
        c.voiceHead = "AUDIENCE WITH"
        c.voiceQuote = "“Two more KV-cache papers are queued. Shall I fold the summaries into tomorrow’s digest, or read them now?”"
        c.mute = "hush"; c.textBtn = "write"; c.bnMeta = "NOW · TALARIA"
        c.offline = "THE LINK IS SEVERED — LAST KNOWN STATE SHOWN. THE FAMILIARS WORK ON."
        c.titleArtifacts = "The Relics"; c.kickerArtifacts = "WHAT THE FAMILIARS MADE"
        c.artifactsLead = "Their works, kept. Touch one to return to its making."
        c.queued = "held — the way is severed"; c.later = "later"
        c.duplicate = "duplicate this familiar"; c.editLook = "refashion its guise & soul"
        c.sessionsSec = "PAST AUDIENCES"; c.contextSec = "THE VESSEL (CONTEXT)"
        c.memorySec = "WHAT IT REMEMBERS"
        c.yoloName = "unchained (yolo)"
        c.yoloSub = "It will act without your seal on dangerous commands."
        c.obTitle3 = "Six familiars await"; c.obLook = "choose the guise"
        c.tabs = [("bots", .home), ("ledger", .activity), ("seals", .approvals),
                  ("parley", .a2a), ("relics", .artifacts)]
        // Ink names its familiars rather than tagging them, so this voice
        // takes the title (@handle is a machine address, not a form of address).
        c.composer = { bot in "Address \(bot.displayTitle)…" }
        return c
    }()
}
