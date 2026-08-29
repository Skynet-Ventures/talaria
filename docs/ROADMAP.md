# Talaria roadmap — phased plan to Bot Mode parity

**Status: phases 0–5 landed in the overnight run of 2026-08-18, and subsequent
reviewed slices added current-Hermes contracts, source-qualified multi-gateway
state, standalone shared rooms with CAS, push corrections, and authenticated
Advanced Terminal.** Informal live use has confirmed response/approval push
delivery, but it is not retained certification evidence. The complete Debug /
TestFlight, room-convergence, PTY, reconnect, and row-specific live matrices in
[`TESTING.md`](../TESTING.md) remain authoritative.

The reviewed transcript stack now also includes exact file diffs, structured
terminal/execute-code output, web-search results, foreground find, and bounded
`image_generate` cards. Generated-image gateway loading and share behavior are
built and package-tested but still require retained real-device certification;
see [`GENERATED-IMAGE-TRANSCRIPTS.md`](GENERATED-IMAGE-TRANSCRIPTS.md).

Written 2026-08-18 from three sources: the 1,190-row desktop audit
([PARITY.md](../PARITY.md)), the 443-row Bot Mode plugin audit
([BOT-MODE-PARITY.md](BOT-MODE-PARITY.md)), and three bugs found by driving the
app against a live gateway.

The ordering principle: **correctness before capability, liveness before
surface area, and Bot Mode before everything else.** A phone that shows the
wrong state is worse than a phone missing a screen, and a beautiful settings
screen on top of a chat that loses your history is a bad trade.

---

## Phase 0 — Correctness (blocking; ~1 day) · ✅ **landed 2026-08-18** (`4cc1d41`)

> All three bugs fixed. 0.1 and 0.3 are one mechanism: `AppModelLive+CanonicalChat.swift`,
> the single door every open and send funnels through (pin → canonical title →
> previewed session → birth), with the pin written back to `ui_meta["hermes-bots"].chat`.
> Every entry point now routes through `openChat(botID:)`. 0.2 is `Components/BotIdentity.swift` —
> one identity path, and `CopyPack.composer` takes the resolved handle.
> **Unverified against a gateway**, which is exactly where this phase's risk now lives.

Three live bugs, all found in one session of real use. Everything else waits.

### 0.1 Chat opens without its history · **critical**

`RosterView.swift:260` sets `model.openBotID = bot.id` directly and never
calls `AppModel.openChat(botID:)` — the function that resumes the stored
session and hydrates the transcript. Nothing else calls it either, so on a
real gateway:

- the chat opens with no history, showing only the roster preview line that
  `ChatView.seedChatIfNeeded()` injects as a fake message;
- the first message you send calls `ensureSession`, which **creates a new
  session** instead of continuing the bot's conversation.

That second effect is the serious one: every phone conversation silently
forks a fresh session, orphaned from the bot's real history — precisely the
"list of sessions" drift that BOT-MODE-PARITY warns is the end of the product.

*Fix:* route every entry point (roster row, deep link, push tap, search
result, activity row) through `openChat(botID:)`, and delete the preview-seed
fallback once hydration is real. Add a regression check that opening a bot
with a known session yields a non-empty transcript.

### 0.2 Bot identity is inconsistent across screens · **high**

`BotSheetView.swift:58` defines its own local `displayName` that hardcodes
`"@" + botID`, bypassing `Bot.displayTitle`. Same class of bug in the
composer placeholder (`CopyPack.composer(botID)` → "Transmit to @default"
instead of the handle @hermes). The chat header is correct, which is why it
reads "Skynet" while the sheet behind it reads "@default".

*Fix:* one identity path. Delete the local helper, make `CopyPack.composer`
take the resolved handle, and audit every remaining `botID`-as-display-string
call site.

### 0.3 The canonical forever-chat is not honored · **critical**

Desktop pins one canonical chat per bot in `ui_meta["hermes-bots"].chat` and
opens *always* there — never "most recent session"
(plugin.js:2726-2800). Talaria resumes `last_session` instead, so a cron
delivery or a subagent run can hijack what you see when you tap a bot.

*Fix:* read the pin, resume it, fall back to resume-by-title then create.
Write the pin back when a chat is created so desktop and phone agree. This is
the single most load-bearing behavior in Bot Mode.

---

## Phase 1 — Liveness (~2–3 days) · ✅ **landed 2026-08-18** (`ecfeb37`)

> Items 1–3 and 5 landed: `AppModelLive+Liveness.swift` (foreground re-seed and
> reaper over `session.active_list`, coalesced and generation-guarded),
> `Components/NetworkMonitor.swift` (NWPathMonitor nudge with a settle delay and
> nudge floor), and voice now submits through `sendOrSteer`, so a voice-started
> turn has a stop button. **Item 4 remains open and cannot be closed without a
> gateway** — the reconnect grace and `inflight` replay are still built-never-exercised.

A phone suspends; desktop does not. This is the systemic theme behind the
largest cluster of ⭕ rows, and it produces *wrong state*, not missing
features — a bot can appear to spin forever because the turn finished while
the app was backgrounded.

1. **Foreground re-seed** — on `scenePhase == .active`, call
   `session.active_list` and reconcile: clear working state for turns that
   ended, re-attach ones still running, refresh the roster.
2. **Reconnect nudge on network restore** — `NWPathMonitor` triggers an
   immediate reconnect instead of waiting out the backoff.
3. **Runtime reaper** — a bot marked working with no live session and no
   events for N seconds gets cleared rather than spinning forever.
4. **Reconnect grace, verified live** — kill the socket mid-turn and confirm
   the ~20 s park/reattach path and `inflight` replay actually work. Built,
   never exercised.
5. **Stop button on voice turns** — voice submits via `send` rather than
   `sendOrSteer`, so a voice-started turn has no stop control (known,
   deliberately deferred).

---

## Phase 2 — Settings (~3–4 days) · ✅ **landed 2026-08-18** (`2b7610c`)

> `Screens/SettingsView.swift` plus `Screens/Settings/*`: Gateways, Appearance
> (themes, text size, motion), Notifications, Models & providers, Voice, Solo,
> Privacy & data, About & diagnostics, and the desktop pointer. Scope is decision
> 1 below, not desktop's 202 controls. One real bug fixed on the way: the
> connect-time push handshake re-sends the stored `profile_filter`, which it
> previously erased on every connect.

Desktop has **202 discrete settings controls**; Talaria has no settings screen
at all. That single absence is ~17% of the entire audit gap, and it is one
decision rather than 130 features.

The goal is **not** 202 controls on a phone. It is one Settings screen with
the controls a phone-first operator actually reaches for, and honest pointers
to desktop for the rest:

- **Gateways** — the connection registry (exists in Connections; move/merge).
- **Appearance** — themes (exists), plus text size and reduce-motion.
- **Notifications** — the card that exists, plus per-bot preferences wired to
  the relay's `profile_filter`; event-kind filtering remains a gateway-process
  setting (`TALARIA_PUSH_EVENTS`), not a device preference.
- **Models & providers** — default model, reasoning effort, API keys
  (`model.save_key`), provider connect/disconnect.
- **Voice** — input/output device behavior, TTS on/off, wake settings.
- **Privacy & data** — what's stored on device, Keychain contents, sign out,
  clear cache, delete local data.
- **About & diagnostics** — versions, gateway contract, logs, "report an
  issue" bundle.

Explicitly *not* on mobile: env-var editing, config.yaml raw editing, storage
paths, update channels — those get a "manage on desktop" pointer.

---

## Phase 3 — Managing the fleet (~4–5 days) · ✅ **landed 2026-08-18** (`42be6e5`)

> All five: cron CRUD with run history (`RoutineEditorView.swift`,
> `AppModelLive+Cron2.swift`), session verbs behind long-press per decision 4
> (`SessionsSheet.swift`), a real artifacts index that fetches and previews bytes,
> approval policy (mode, bypass, wait, allowlist revoke — `ApprovalSettingsView.swift`),
> and pairing approvals (`PairingView.swift`). Every one of these is a write path
> to a gateway and none has been run against one.

The audit's other big theme: Talaria reads and answers well, but cannot
administer. Ordered by how often a phone-first operator needs it.

1. **Cron editing + run history** — create/edit/delete schedules and see what
   a routine actually did. Currently list + toggle only.
2. **Session management** — pin, archive, rename, delete, and a real
   sessions-per-bot browser (the sheet exists; the verbs mostly don't).
3. **Approvals depth** — pattern allowlists, approval modes
   (manual/smart/off), and the pairing-approval queue.
4. **Artifacts** — a genuine outputs index with preview and share-sheet
   export, rather than the derived list.
5. **Credentials & pairing** — messaging-platform pairing approvals, which
   today can only be done from desktop or CLI.

---

## Phase 4 — Bot Mode depth (~4–5 days) · ✅ **landed 2026-08-18** (`de6063b`)

> A2A with attribution and @mention routing (`AppModelLive+A2A.swift`,
> `Components/MentionField.swift`), the multi-gateway union roster
> (`AppModelLive+MultiGateway.swift`, `ConnectionRegistry.swift`), the cosmetics
> bridge made two-way per decision 3 (`AppModelLive+Cosmetics.swift`), avatar
> generation (`Components/AvatarPicker.swift`), and roster craft — recency, the
> 90 s liveness window, pinning, the unread watermark. Standalone group rooms
> and retained-gateway federation landed in the subsequent rooms/federation
> slice; live-gateway/device certification remains open.

The parts of the plugin that make it feel like a fleet rather than a list.

1. **A2A / Agent Inbox for real** — cross-profile handoffs with attribution,
   @mention routing between bots, and the compose path.
2. **Multi-gateway roster** — one roster spanning Connections, with
   `name-device` handle disambiguation and per-row connection labels.
3. **Bot cosmetics round-trip** — write `ui_meta["hermes-bots"]` back (title,
   shape, color) so phone edits show up on desktop; today we only read.
4. **Avatar generation** — `image.generate` → `profiles.set_asset` portraits.
5. **Roster craft** — the plugin's ordering/ranking rules, "active in the last
   90s", unread semantics, and the entrance/idle motion detailed in the
   BOT-MODE-PARITY design notes.

---

## Phase 5 — Solo mode (~1 week) · ✅ **landed 2026-08-18** (`6f99ec0`)

> `SoloEngine.swift`, `FoundationModelsProvider.swift` (Apple Foundation Models
> as the default tier, gated three ways for an iOS 17 target), `SoloTools.swift`
> (seven families, two gates: the permission keeps a tool out of the registry
> entirely, the approval uses the same vocabulary as a gateway bot), and the
> explainer plus Solo settings. MLX and Portal are **seams, not shipped tiers**.
> This is the one phase whose core loop can be exercised without a gateway — and
> it was not, because it needs a device with Apple Intelligence on.

Per [SOLO-MODE.md](SOLO-MODE.md), already agreed: Apple Foundation Models as
the default on-device tier, MLX as the power path, Portal as serverless, a
small iOS-permitted tool set, and the explainer GUI that shows exactly what
you get locally versus with a gateway. Sequenced last because it is additive —
it makes Talaria useful *without* a gateway, but it does not make Talaria
correct *with* one.

---

## Mobile ceiling and mobile equivalents

The current Hermes gateway changed this boundary. iOS still cannot `fork` or
`exec` a local shell, launch a desktop terminal emulator, reveal files in
Finder/Explorer, replace its own signed binary, install VS Code themes, or
reproduce Electron HUD/always-on-top/titlebar behavior. Those remain genuinely
desktop-local.

Remote operator capabilities are **not** n/a merely because their Desktop UI
is local. Audited Hermes `40643cba` exposes an authenticated `/api/pty` WebSocket with
profile/session binding, opaque reattach tokens, bounded replay, resize, and
native TUI approvals; a mobile advanced terminal is therefore portable. The
gateway also exposes guarded Git, Projects, Files, and maintenance APIs. iOS
Talaria presents these as source-qualified remote controls with explicit safety
boundaries, while App Store/TestFlight—not Hermes—owns Talaria app updates.

The remaining true exceptions and their closest mobile equivalents are tracked
row by row in [PARITY.md](../PARITY.md#mobile-ceiling).

---

## Sequencing rationale

- **0 before everything** — the history bug silently forks sessions. Every
  day it ships, real conversations get orphaned.
- **1 before 2** — a settings screen that toggles things while the roster
  shows stale state is polish on a broken foundation.
- **2 before 3** — settings is one bounded screen that closes the single
  largest counted gap and gives 3's features somewhere to live.
- **3 before 4** — administering the fleet you have beats enriching how the
  fleet talks to itself.
- **5 last** — additive, and it deserves the explainer GUI done properly
  rather than rushed.

## Decisions (settled 2026-08-18)

1. **Settings scope — as proposed.** No raw config/env editing on device: you
   can just *ask a bot* to make config changes, which is a better mobile
   affordance than a text editor for YAML. Mobile settings stay the controls a
   phone-first operator reaches for; everything else points at desktop.
2. **Phase 3 before Phase 4 — unchanged.**
3. **Cosmetics round-trip — yes, write back.** Phone edits write
   `ui_meta["hermes-bots"]` so desktop sees them, matching desktop's own
   merge semantics (server block authoritative, local-only fields preserved).
   This moves into Phase 0 alongside reading the canonical-chat pin, since
   both touch the same block.
4. **Session verbs — mostly a desktop concern.** The canonical forever-chat is
   the mobile model. Pin/archive/delete land as a tucked-away *power-user*
   surface (long-press in the sessions sheet), never as primary navigation.

---

<a id="what-is-actually-left"></a>

## What is actually left (reconciled 2026-08-21)

Reconciled against pinned Hermes `40643cba`, the current source, and reviewed
delivery through Advanced Terminal. Ordered by what a phone-first operator
loses, not by effort.

### 1. Verification, which is now the whole critical path

Some gateway/device paths have now been exercised informally, including real
response and approval notifications. That does not satisfy the retained
evidence standard. The critical path is still the complete live matrix in
[`TESTING.md`](../TESTING.md): canonical chat/reconnect, push Debug and
TestFlight cases, shared-room convergence/CAS, current-Hermes deployment
behavior, and Advanced Terminal across both auth modes, radio/background/TTL,
close taxonomy, accessibility, and cleanup.

Phase 1's own item 4 — kill the socket mid-turn, confirm the ~20 s park/reattach
and the `inflight` replay — is unchanged from the original plan and is still the
single best test of the client.

### Push relay certification gate

The relay implementation and its APNs contract are source-reviewed, but push
is not complete until it has real gateway and real-device evidence. A green
build or the Settings **Send test push** button is insufficient: `/test` is a
synthetic display probe that intentionally bypasses `TALARIA_PUSH_EVENTS` and
`profile_filter`.

Use [TESTING.md §5](../TESTING.md#5-live-gateway-and-push-certification) and
the relay's [certification order](../relay/README.md#live-gatewaydevice-certification)
to record, against the pinned Hermes revision:

- one Debug/sandbox pass (`aps-environment=development`, registration
  `environment: "dev"`) and one TestFlight/production pass
  (`aps-environment=production`, registration `environment: "prod"`);
- one `registered 6 hooks` log line from each process that should observe
  events, with environment inheritance checked separately for `hermes serve`,
  messaging gateway, and cron;
- approval, final-response-ready (including fallback/error-summary), mention,
  and routine events, including the interrupted negative case and
  source-qualified deep links; legacy long-task polling is tested separately
  with `response` disabled;
- an allowed and disallowed real profile for `profile_filter`, plus the
  intentionally different `/test` result; and
- sidecar polling/offline/recovered evidence, with its session-bound event,
  mention, polling, and profile-attribution limitations called out.

Until that matrix is recorded, keep push/background rows partial and describe
them as implemented-but-uncertified rather than production-ready.

### 2. Bot Mode implementation complete; certification remains

- **Group rooms / multi-bot chats — implemented, certification pending.** The
  room row is interleaved into the roster; the mobile room view has threaded
  speaker attribution, deterministic responder selection, a bounded three-round/
  ten-post drive, `(pass)`, watermarks, `@user` attention, activity, attachments,
  settings, rename and disband. Member sessions and metadata are source-qualified
  across retained gateways. Automated Swift, protocol, Debug and Release gates
  are green; live Hermes and phone reliability checks are still required before
  this can be called production-certified.
- Canonical `/new` and `/reset` protection, the `hideOwnedBotSessions`
  reconciliation sweep, and the source-qualified pet gallery/mutations have
  landed. Their remaining work is row-specific live-gateway/device evidence,
  not another client implementation pass.

### Advanced Terminal — implemented, certification pending

Command Center now opens an exact gateway/profile/durable session through
Hermes’ authenticated `/api/pty`, renders with SwiftTerm, preserves ordered
backpressure, handles resize/reconnect/close semantics, and clears scoped
attachment state on profile/gateway/privacy lifecycle events. It is not
production-certified until the real-device matrix in `TESTING.md` is retained.

### 3. Remaining management depth

Operator Settings now includes `agent.max_turns`, persistent-memory controls,
image-input mode, and gateway logs. Remaining management work is messaging /
webhook / relay lifecycle, subagent tree/live-tail/files/cost, learned-memory
curation and import/export, MCP logs, auxiliary goal-judge/vision slots, and
MoA management. Implemented routine reasoning effort still needs its live
create/edit/clone/run certification cases.

### 4. Known-latent, not yet a bug

- **APNs environment now follows the signed configuration.** Debug uses the
  sandbox entitlement and registers/sends `dev`; Release uses the production
  entitlement and registers/sends `prod`. `TALARIA_APNS_ENV` is only the relay
  fallback when a device registration omits its environment. Both builds carry
  the Time Sensitive entitlement used by approval and gateway alerts; current
  Apple SDKs no longer require a separate authorization option. The relay
  source-stamps every multi-gateway payload and bounds APNs storage with
  per-kind expiration. Live gateway/device certification remains open; follow
  the dedicated gate above.
- **`ConnectionRegistry.startAutoProbe` is still dead code** (PARITY.md row on
  backstop polling). Harmless, but it is a probe nobody calls.
- **Solo's `BridgedTool` silently drops any tool whose parameters are not a flat
  object** of string/integer/number/boolean. Safe direction, but a future tool
  with a nested or array argument would vanish from the on-device tier with no
  diagnostic. Worth an assertion before the tool set grows.

### 5. Remaining transcript and session depth

Message edit, rewind/restore, regenerate, and message-level child creation are
implemented. Desktop's N/M regenerate alternatives are client-local response
siblings; selecting one does not switch Hermes' durable context and a normal
resume cannot reconstruct them. The separate `session.branch` durable child
contract is already implemented. Talaria now retains bounded current-ChatState
alternatives only after an accepted receipt or exact effect proof, renders the
selected local response inertly, and keeps the newest durable model context.
Live gateway and physical-device certification remain open. The open dependency
stack now adds normalized durable session-tree presentation and bounded ordered
multimodal/tool parts. Both consume explicit Hermes producer contracts rather
than inferring identity or order; the corresponding upstream Hermes PRs must
land before release certification. Other remaining depth includes math/diagram
presentation, per-message TTS, whole-turn timing, tours, and
transcript-wide activity. Bounded diff, ANSI terminal, web-search, generated-
image lightbox/share, and explicit assistant image/audio/video/file cards are
implemented on the open transcript stack. The explicit durable composer queue is now a separate,
source-qualified, text-only phone interaction; it still needs retained live
gateway/device certification, not a broader queue CRUD surface. The remaining
work should be split into independently reviewed slices after the certification
critical path.
