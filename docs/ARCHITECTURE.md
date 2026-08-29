# Talaria architecture

How the app is put together, and the handful of protocol facts you must not
violate. Read alongside [PARITY.md](../PARITY.md) (what exists) and
[CONTRIBUTING.md](../CONTRIBUTING.md) (how to work here).

## Package & target layout

Everything that can live outside an Xcode project does, so the bulk of the app
compiles and tests with plain `swift build` on macOS (CI does exactly this):

```
app/
├── Packages/Talaria/            Swift package (iOS 17+ / macOS 14+), zero dependencies
│   ├── Sources/
│   │   ├── TalariaKit/          Gateway protocol client + domain models. No UI.
│   │   │   ├── GatewayTransport.swift   JSON-RPC 2.0 over URLSessionWebSocketTask
│   │   │   ├── GatewayClient.swift      Typed RPC surface + event fan-out
│   │   │   ├── GatewayAuth.swift        Token / native-PKCE / ws-ticket auth
│   │   │   ├── GatewayEvents.swift      Typed server→client events
│   │   │   ├── Models.swift             Domain models (Bot, Approval, Routine…)
│   │   │   ├── DemoData.swift           Demo roster (ported from the prototype)
│   │   │   ├── KeychainStore.swift      Credential storage
│   │   │   ├── LoopbackListener.swift   127.0.0.1 redirect catcher for PKCE
│   │   │   ├── JSONValue.swift          Dynamic JSON (the wire is schemaless)
│   │   │   ├── InferenceProvider.swift  BYO-inference seam (chat-only backends)
│   │   │   ├── NousPortalClient.swift   Portal device-code OAuth + streaming chat
│   │   │   ├── LiveActivityModel.swift  BotWorkAttributes (shared w/ widget ext)
│   │   │   └── ProtocolChecks.swift     XCTest-free conformance checks
│   │   ├── TalariaTheme/        Theme engine: ThemePack + CopyPack + ThemeManager
│   │   │                        + AvatarView (shape × hue, scanning eyes)
│   │   ├── TalariaUI/           SwiftUI layer
│   │   │   ├── AppModel.swift           Observable state tree (demo | live)
│   │   │   ├── AppModelLive.swift       Live driver: connect, event routing, RPCs
│   │   │   ├── AuthController.swift     Sign-in orchestration (probe→token/PKCE)
│   │   │   ├── ConnectionRegistry.swift Saved gateways + health probes
│   │   │   ├── LiveActivityController.swift  ActivityKit driver
│   │   │   ├── PushCoordinator.swift    Notification categories, APNs, routing
│   │   │   ├── Components/              Shared themed chrome (ScreenHeader…)
│   │   │   └── Screens/                 BotSheet, CreateBot, Routines,
│   │   │                                Artifacts, SearchPalette (more porting)
│   │   └── TalariaVerify/       `swift run talaria-verify` → ProtocolChecks.runAll()
│   └── Tests/TalariaKitTests/   Thin XCTest wrapper over the same checks
├── Packages/TalariaLocal/       OPTIONAL on-device inference (MLX + HF hub).
│                                Separate package so the main app links no
│                                third-party code unless the user opts in.
│                                See docs/LOCAL-INFERENCE.md.
├── ios/                         XcodeGen shell: project.yml + resources.
│   ├── Talaria/                 App target (App/ entry point still pending),
│   │                            Resources (icon, fonts), Support (plists).
│   ├── TalariaWidgets/          Widget extension: Live Activity render side.
│   └── TalariaNotificationService/  NSE: decrypt/enrich relay pushes (scaffold).
│                                `xcodegen generate` produces Talaria.xcodeproj;
│                                the project file is never checked in.
└── relay/talaria-push/          Gateway-side APNs push relay (Python plugin +
                                 sidecar): config.py, devices.py, apns.py landed;
                                 push fan-out, hermes hooks, sidecar next.
```

Dependency direction: `TalariaUI → TalariaTheme → TalariaKit`. TalariaKit has
zero UI imports; TalariaTheme depends on Kit only for model enums
(`AvatarShape`, `AvatarHue`). No third-party packages in `Packages/Talaria` —
URLSession WebSockets, Security.framework, Network.framework, CryptoKit, and
(in the app targets) ActivityKit/WidgetKit cover it. The only third-party code
in the repo lives in `Packages/TalariaLocal` (MLX, swift-transformers) and is
never linked unless the user opts into local models.

iOS-only surfaces (ActivityKit, haptics, UNUserNotificationCenter) are gated
with `#if os(iOS)` / `canImport` so `swift build` keeps working on a bare Mac
toolchain.

## Data flow: WS events → GatewayClient → AppModel → SwiftUI

```
hermes serve /api/ws
      │  one JSON object per WS text frame
      ▼
GatewayTransport (actor)
      │  • requests: id-correlated; pooled handlers respond OUT OF ORDER,
      │    so correlation is strictly by id, never by arrival order
      │  • events: AsyncStream<GatewayEvent> in arrival order
      ▼
GatewayClient (actor, one per gateway connection)
      │  • owns credential + transport lifecycle, re-mints tickets
      │  • typed RPC wrappers (profiles.*, session.*, prompt.submit, …)
      │  • fan-out: addEventHandler → every registered handler
      ▼
TypedGatewayEvent(event)          – exhaustive switch; unknown types flow
      │                             through as .other (no protocol churn)
      ▼
AppModel (@MainActor @Observable) + AppModel+Live (the event router)
      │  • mode: .demo | .live — same state tree, two drivers
      │  • bots / approvals / activity / chats[botID] → ChatState / …
      │  • live: deltas append to the streaming row, approvals badge the
      │    roster, sessions.changed/cron.changed trigger refreshes
      ▼
SwiftUI screens (TalariaUI)       – read the observable tree, call
      │                             AppModel intents (send, resolveApproval…)
      ▼
side pipelines observing the same tree:
  LiveActivityController → ActivityKit (Dynamic Island / lock screen)
  PushCoordinator        → UNUserNotificationCenter (categories, routing)
```

Two transports feed the model in live mode:

- **WS RPC + events** — everything interactive (roster, turns, approvals).
- **REST** — bulk hydration only: paginated transcripts via
  `GET /api/sessions/{id}/messages` (used with `defer_history` resumes), auth
  endpoints, `/api/status` health probes. Auth attaches per credential
  (`X-Hermes-Session-Token` header vs `Bearer`).

Protocol facts baked into the transport (do not "fix" these):

- The server coalesces `message.delta`/`thinking.delta`/`reasoning.delta`
  into ~33 ms batches — expect bursts of deltas back-to-back.
- Current gateways advertise `heartbeat: true` in `gateway.ready` and answer
  `gateway.ping`. Talaria sends an application heartbeat every 15 seconds and
  invalidates a socket after 45 seconds without inbound traffic, allowing the
  owning reconnect supervisor to replace a silent half-open connection.
  Gateways that do not advertise the capability retain the older
  URLSession/WebSocket close-event path.
- Current gateways also advertise an opaque `replay_epoch`, stamp each
  session-bound event as `{type, session_id, seq, payload}`, and answer
  `session.events.since {session_id,last_seen}` with
  `{events,latest_seq,truncated,count,epoch}`. `seq` is monotonic per runtime
  session and meaningful only inside the advertised process epoch. Older
  gateways omit the capability and retain snapshot-only reconnect recovery.
  The optional `session.events.stats` diagnostics RPC is decoded strictly as
  `{sessions,events,max_per_session}`; malformed occupancy is never displayed
  as a reassuring zero.
- The first frame after accept is the `gateway.ready` event —
  `GatewayTransport.connect()` treats its arrival as connection success and
  captures the skin payload.
- Events use envelope `{type, session_id, payload}`; `session_id: ""` marks a
  global broadcast (`sessions.changed`, `cron.changed`, …).

## Auth flows (summary — code is the reference)

Full implementation with upstream file/line pointers:
`Sources/TalariaKit/GatewayAuth.swift`; UI orchestration in
`Sources/TalariaUI/AuthController.swift`.

1. **Session token** (loopback/trusted): pasted dashboard token → REST header
   `X-Hermes-Session-Token`, WS `?token=`. `AuthController` validates the
   paste with a real authenticated call before persisting.
2. **Native PKCE** (gated gateways — any non-loopback bind): `NativePKCEFlow`
   builds S256 challenge + state; system browser opens
   `auth/native/authorize` with `redirect_uri=http://127.0.0.1:<port>/callback`
   served by `LoopbackListener` (Network.framework, one-shot); the state is
   verified *before* the code is redeemed at `POST auth/native/token` for a
   `TokenSet` (access + refresh, refresh triggered at `expiresAt − 60 s`,
   matching desktop). Nous Portal, self-hosted OIDC, and the
   username/password provider all ride this same broker — password providers
   just land the browser on the gateway's `/login` form first.
3. **WS tickets**: in gated mode the WebSocket never uses tokens — a
   single-use 30 s ticket from `POST /api/auth/ws-ticket` is minted
   immediately before *every* dial (`GatewayClient.connect()` does this
   unconditionally for OAuth credentials).

`AuthController` drives the phased UI (`probing → waitingForBrowser →
exchanging → done | failed`) and jumps straight to `done` when a stored
Keychain credential still works against the probed gateway.

**Storage split** (`ConnectionRegistry`): gateway *metadata* (name, kind,
normalized URL, last roster size) lives in UserDefaults; *credentials* live
only in the Keychain (`KeychainStore`, keyed by normalized base URL,
`kSecAttrAccessibleAfterFirstUnlock`) — never UserDefaults, files, or logs.
The registry also runs parallel `/api/status` health probes with a 5 s
timeout session (timeout ⇒ `asleep`, other failures ⇒ `offline`) and measures
ping for the Connections rows. See [SECURITY.md](../SECURITY.md).

Separate seam, not gateway auth: `NousPortalClient` implements the CLI's
*device-code* flow against Nous Portal (client id `hermes-cli`, rotating
single-use refresh token in the `x-nous-refresh-token` header, hard host
allowlists for portal and inference base URLs) for the gatewayless chat tier
— see [LOCAL-INFERENCE.md](LOCAL-INFERENCE.md).

## Theming: token packs + copy packs

The design's three souls are two parallel packs, both switched by
`ThemeManager` and persisted under the same key the prototype used
(`talaria-theme`):

- **`ThemePack`** — visual tokens: colors (exact hex values lifted from the
  prototype's `packs()`), typography families (system / IBM Plex Mono /
  Cormorant Garamond — fonts bundled in `ios/Talaria/Resources/Fonts`),
  radii, row style (`card` / `terminal` / `ledger`), tab-bar style, glow
  radii, avatar-eye geometry.
- **`CopyPack`** — the *voice*: every user-facing string exists per theme
  (Approvals → Holds → The Seals; Approve & send → RELEASE → grant the seal).
  Screens must never hard-code a string that exists in the pack, and never
  hard-code a color or font at all — that rule is what makes three-themes-not-
  three-apps work. It reaches beyond screens: `PushCoordinator` re-registers
  the notification action titles whenever the theme changes, so even lock-
  screen buttons speak the current voice.

`AvatarView`/`AvatarSilhouette` implement the shared avatar language (6
geometric shapes × hue palette per theme, blinking eyes, scan-while-working)
— cosmetics are client-side (stored under `ui_meta["talaria"]` on the
profile, with a stable-hash fallback for profiles created elsewhere), so
profiles stay clean.

## Demo mode mirrors the prototype

`AppMode.demo` is a first-class driver, not a mock: `DemoData` is a verbatim
port of the design prototype's `hermes-data.js` (same six bots, approvals,
routines, artifacts, context breakdown), and `AppModel.enterDemoMode()` loads
it into the exact state tree live mode fills. Scripted replies arrive on a
0.9–1.8 s delay like the prototype's; `PushCoordinator` can even preview the
relay's push payload shapes as local notifications. This is the onboarding
"Explore with demo data" path and what App Review exercises — every screen
must work in both modes, which keeps screens honest about depending only on
`AppModel`, never on a socket.

`talaria-verify` cross-checks demo integrity (every approval/routine/artifact
references a roster bot) so demo mode can't silently rot.

## Session id duality (the one thing everyone trips on)

Every live session has **two ids**, and they are not interchangeable:

| Id | Shape | Use for |
|---|---|---|
| runtime sid (`session_id`) | 8 hex chars, new per attach | All RPCs (`prompt.submit`, `approval.respond`…) and event routing — events arrive stamped with the runtime sid |
| stored key (`stored_session_id` / `session_key`) | durable | `session.resume` across reconnects, REST transcript hydration, cross-referencing the roster |

`LiveSession` carries both; `ChatState` keeps both (`sessionID`,
`storedSessionID`). A resume returns a **new** runtime sid for the same stored
key — rebind event routing on every resume (`AppModel+Live` does this in its
session-to-bot map). Gotcha preserved from upstream: the `session.title`
event's *payload* `session_id` is the durable key while the *envelope*
`session_id` is the runtime sid.

## Reconnect strategy

Sockets die constantly on a phone (backgrounding, cell↔Wi-Fi handoff, elevator
rides). The design leans on the gateway's session-parking behavior:

1. `GatewayTransport` is single-shot: on any receive error it fails all
   pending requests, finishes the event stream, and reports `.disconnected`.
   It never reconnects itself.
2. `GatewayClient.connect()` is the reconnect: refresh OAuth tokens if near
   expiry → mint a fresh WS ticket (single-use, 30 s TTL — never reuse) →
   new transport → wait for `gateway.ready`.
3. Before any resume/list snapshot can overwrite the disconnected interval,
   `GatewayClient` requests a bounded replay suffix for every retained session
   cursor. Live frames racing those requests remain parked. A same-epoch,
   contiguous answer is applied in server array order; overlapping live frames
   are then released through the same per-session sequence gate, exactly once.
   Epoch changes clear poisoned cursors. Malformed, failed, bounded, or
   `truncated` answers are surfaced as uncertain and force snapshot
   reconciliation rather than claiming the interval was complete.
4. On disconnect the gateway **parks** live sessions for a ~20 s grace window.
   Reconnecting and calling `session.resume` with the *stored key* inside that
   window reattaches the live in-memory session, replaying `inflight` partial
   assistant text, the queued prompt, and `pending_approval`/`pending_clarify`
   — enough to rebuild the chat mid-turn. After the window, resume still works
   but cold-loads from storage.
5. Built: an explicit, source-qualified durable composer queue plus the
   existing in-memory ordinary-send recovery path. The Queue control persists
   text-only rows keyed by gateway, profile, and stored session;
   `flushComposeQueue()` resumes that exact stored session and drains only when
   it reports no running/in-flight turn, approval, or clarify state. Normal
   mid-turn Send remains steer-first and never creates durable queue authority.
   Stop parks still-local durable rows before interrupting. The legacy
   `composeQueue` remains compatibility recovery for ordinary sends, not a
   replayable durable queue. The app-level scene-phase observer, foreground
   health re-probe, network-restored liveness nudge, supervised full-jitter
   reconnect, and post-adoption queue flush are implemented. Foregrounding
   reseeds exact open-session liveness rather than blindly resuming every
   historical chat.

Request timeouts follow desktop's per-call overrides: default 120 s,
`prompt.submit` 1800 s (the ack can legitimately take that long),
`session.resume` 180 s, `image.generate` 300 s.

## Live Activity & push pipelines

Two app-process observers sit beside the screens, both driven purely by
`AppModel` state (so demo mode exercises them too):

- **Live Activity** — the ActivityKit attributes (`BotWorkAttributes`: bot
  identity + avatar shape/hue fixed, task/startedAt/pending-approvals
  dynamic) live in TalariaKit because the app process *starts* activities
  (`LiveActivityController`, `withObservationTracking` re-armed per change,
  one activity system-wide, most-recently-working bot wins) while the
  `TalariaWidgets` extension *renders* them. Elapsed time uses
  `Text(timerInterval:)` so the island clock ticks without pushes. Tap
  deep-links `talaria://bot/<id>`. The render view (`BotWorkLiveActivity`)
  is still to be written.
- **Push** — `PushCoordinator` owns notification authorization, the
  `TALARIA_APPROVAL` actionable category (approve from the lock screen with
  `authenticationRequired`, titles in the current theme's voice), APNs
  registration (device token exposed async for the relay handshake), and
  deep-link routing back into `AppModel`. The wire contract with the
  `relay/talaria-push` gateway plugin is the design's push shape
  (`{kind, gateway_id, bot, title, body, approval_request_id, session_id}` +
  `mutable-content: 1`); the `TalariaNotificationService` extension decorates
  those cleartext payloads and shares the same userInfo keys.
