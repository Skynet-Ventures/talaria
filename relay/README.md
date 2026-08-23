# talaria-push-relay

Gateway-side APNs push relay for **Talaria**, the iOS client for
[hermes-agent]. Ships as a standard hermes plugin (`talaria-push/`) plus an
optional standalone sidecar watcher, and is written to be upstreamable into
hermes-agent — MIT licensed, no Talaria-app dependencies, pure Python.

```
relay/
├── pyproject.toml            pip package "talaria-push-relay" (sidecar installs)
├── .env.example              every knob, systemd EnvironmentFile-friendly
├── LICENSE                   MIT
└── talaria-push/             ← the hermes plugin dir (copy to ~/.hermes/plugins/)
    ├── plugin.yaml           manifest (kind: standalone, hooks: [...])
    ├── __init__.py           register(ctx) → observer hooks
    ├── LICENSE
    ├── dashboard/
    │   ├── manifest.json     hidden tab + api: plugin_api.py
    │   ├── plugin_api.py     REST routes → /api/plugins/talaria-push/*
    │   └── dist/index.js     inert classic script (REST-only plugin)
    └── talaria_push_relay/   importable package (shared by all three load paths)
        ├── config.py         TALARIA_* env parsing
        ├── devices.py        devices.json registry (0600, flock, atomic writes)
        ├── apns.py           HTTP/2 APNs client, ES256 JWT (~50 min cache), 410-prune
        ├── push.py           payload contract + fan-out worker + dedupe
        ├── events.py         hermes plugin hook handlers (in-process mode)
        └── sidecar.py        standalone WS/REST watcher (sidecar mode)
```

## Two modes, one payload contract

| | **Hook mode** (plugin) | **Sidecar mode** (`talaria-push-sidecar`) |
|---|---|---|
| Runs | inside every hermes process that loads plugins (`hermes serve`, `hermes gateway`, CLI, cron) | separate process; connects to `ws://host:9119/api/ws` + REST like the served SPA (auth-flows.md §2) |
| Sees | plugin lifecycle hooks (`VALID_HOOKS`) | `session.active_list` / `approval.pending` RPC polling, global WS broadcasts, `/api/cron/jobs`, `/api/health` |
| Best at | approvals at the instant they block, final responses, @mentions, per-turn timing | approval **request ids**, gateway offline/recovered |

Run either alone, or both together with `TALARIA_PUSH_EVENTS` split so no
event kind is enabled in both processes (otherwise the phone buzzes twice).
`.env.example` shows the recommended split.

`TALARIA_PUSH_EVENTS` is a **process-wide allow-list**. If it is omitted, the
safe live kinds are enabled in that process: `approval`, `long_task`,
`response`, `mention`, and `gateway`. `routine` remains a recognized synthetic
display kind but has no live producer: current Hermes completion data cannot
distinguish Slack-owned cron from a Talaria-created routine. The
setting is checked before an event enters the APNs queue; it is not a per-device
or per-profile preference. A normal hook-mode turn emits `response` only when
its Hermes `platform` is exactly `talaria` (Talaria GatewayClient) or `desktop`
(Desktop chat panel). Standalone TUI, messaging-adapter, CLI, server/tool,
subagent, relay, cron, missing, and unknown platforms do not emit a Talaria
response push. When `response` is enabled, the legacy duration-only `long_task`
notification is suppressed so one turn cannot buzz twice. A sidecar has no
`post_llm_call` producer, so a sidecar-only deployment must explicitly omit
`response` if it needs the polling-based `long_task` event. Use
`TALARIA_PUSH_DISABLE=1` as the process kill switch. In a hook+sidecar
deployment, configure each process explicitly so a kind is owned by exactly
one producer.

## What fires today vs. needs upstream hooks (honest table)

Sources verified against the upstream checkout (paths relative to
`hermes-agent`):

| Event (HANDOFF spec) | Hook mode today | Sidecar mode today | Gap / upstream ask |
|---|---|---|---|
| **Approval request** | ✅ `pre_approval_request` hook (`tools/approval.py`) fires in the process running the blocked agent, before the notify callback. **But the hook kwargs carry no `request_id`** — pushes send `approval_request_id: ""`; the iOS client fetches the concrete id via the `approval.pending` RPC, or answers FIFO (`approval.respond` without `request_id` resolves the oldest, ws-protocol.md §8). | ✅ Polls `approval.pending` per active session (~2 s) — full fidelity incl. `request_id`, at polling latency. | Upstream ask: add `request_id` to the `pre_approval_request` kwargs (one-line change at the fire sites; `approval_data` already holds it). Then hook mode is exact and the sidecar's approval poller can be retired. |
| **Final response** | ✅ `post_llm_call` fires once when a non-interrupted turn has any non-empty final response (including fallback/error summaries); emits a source-qualified `response` push only for `platform="talaria"` or `platform="desktop"`. Standalone TUI, Slack, webhook, Telegram, other messaging adapters, CLI, server/tool, subagent, relay, cron, missing, and unknown platforms fail closed. | ❌ A fresh sidecar WS connection does not receive session-bound `message.complete` / response events. | The hook payload is the pinned Hermes contract (`session_id`, `task_id`, `turn_id`, `user_message`, `assistant_response`, `conversation_history`, `model`, `platform`). Talaria GatewayClient hardcodes `talaria`, the Desktop chat panel hardcodes `desktop`, and standalone Hermes TUI resolves to `tui`. |
| **Long task done (>10 min)** | ✅ `pre_llm_call` + `on_session_end` remain the fallback when `response` is disabled. With the default response event enabled, the duration-only push is suppressed. | ⚠️ Approximated from idle↔streaming transitions in `session.active_list`; set `TALARIA_PUSH_EVENTS` without `response` if this is the sidecar's completion signal (resolution = 2 s poll; can't tell success from in-turn error). | The response event supersedes the legacy duration-only notification for normal hook turns. |
| **Routine (cron) finished** | ❌ Fail-closed: `on_session_end(platform="cron")` lacks job id/name, creator surface, origin, and resolved delivery audience. | ❌ Fail-closed: mutable `[bot:…]` names and delivery fields cannot prove creator provenance. | Upstream ask: a structured `cron_job_completed` event carrying job id/name, profile, immutable creator surface, and resolved delivery targets. Only exact Talaria/Desktop provenance may be admitted; Slack/missing/unknown must reject. |
| **@mention in A2A / gateway messages** | ✅ `pre_gateway_dispatch` observer sees every user-originated inbound `MessageEvent` in the messaging gateway — all platforms including `a2a` — and scans for `@<handle>` (`TALARIA_PUSH_MENTION_HANDLES`, default = profile name). Always returns `None` (never alters dispatch). | ❌ Messaging-gateway inbound traffic never crosses the `/api/ws` surface. | None — hook mode covers it. Caveat: fires per *gateway process*, so mentions of bot B are seen by B's gateway; install/enable the plugin for each bot profile that should push. |
| **Gateway offline / recovered** | ❌ Structurally impossible — a dead process can't self-report, and there is no shipped shutdown hook that survives SIGKILL/power loss. | ✅ `/api/health` heartbeat; N consecutive failures ⇒ "offline", first success after ⇒ "recovered". **Only meaningful if the sidecar outlives the gateway** — run it under systemd/launchd, ideally on a different machine over Tailscale. A sidecar on the same host that dies with the host detects nothing; that residual gap needs an off-host watchdog and is out of scope here. | Inherent; no hook can fix this. |

Also honestly: hook mode requires the plugin to be **enabled** and the env
vars present in each hermes process. `hermes serve` (WS/iOS sessions),
`hermes gateway` (messaging), and cron all call `discover_plugins()`, so one
enable covers them — but a bare `hermes chat` in an env without
`TALARIA_APNS_*` simply won't push (it logs one warning and stays silent).

### Hook details and the expected log line

The pinned Hermes 18a15 revision does expose a real
`post_llm_call` observer. It fires **once per turn when the tool loop has
produced any non-empty final response and the turn is not interrupted**. The
response may be a normal answer or a fallback/error summary; success is not a
precondition. An interrupted turn does not fire it. An iteration-limit turn
does fire it when Hermes has produced a non-empty fallback response.
Its response payload includes `session_id`, `task_id`, `turn_id`,
`user_message`, `assistant_response`, `conversation_history`, `model`, and
`platform`. Its return value is ignored. This is the per-turn response hook;
it is not the session-bound WebSocket `message.complete` event.

The current `talaria-push` 0.1 plugin registers `post_llm_call` and emits a
source-qualified `response` push from it only when `platform` is exactly
`talaria` or `desktop`. Standalone TUI, messaging adapters (`slack`, `webhook`,
`telegram`, and peers), CLI, API server/web UI, tool, subagent, relay, cron,
missing, and unknown platforms fail closed; cron never emits a live `routine`
push without immutable creator and delivery provenance.
`post_approval_response` only clears approval dedupe state. This distinction
matters when reading logs:
`events.py` registers six hooks and should emit one line like this **per
Hermes process that loads the plugin** after restart:

```text
talaria-push: registered 6 hooks (bot=ops-bot, events=approval,response,mention)
```

The exact bot and enabled-event list vary. Six is the registration count, not
the number of callbacks expected for one turn. With `TALARIA_PUSH_DISABLE=1`,
the plugin deliberately registers zero hooks and logs that it is disabled.

Environment is inherited by child processes, not shared magically between
already-running services. Export the variables before launching each process,
or put the same `EnvironmentFile` on every systemd/launchd unit that runs
`hermes serve`, `hermes gateway`, or cron. A sidecar is another process and has
its own copy of `TALARIA_PUSH_EVENTS` and `TALARIA_APNS_*`; changing a shell
file does not change a daemon until it is restarted.

## Install (plugin / hook mode)

1. Copy the plugin dir into the hermes root (not a profile dir — user
   plugins load from `~/.hermes/plugins/` for every profile):

   ```sh
   cp -R relay/talaria-push ~/.hermes/plugins/talaria-push
   ```

   (Real copy, not a symlink — the web server resolves plugin paths and
   refuses files outside the plugin directory.)

2. Install the one wheel hermes doesn't ship, into hermes' Python env:

   ```sh
   python -m pip install 'h2>=4.1'    # httpx's HTTP/2 transport for APNs
   ```

3. Enable it (user plugins are disabled until allow-listed):

   ```sh
   hermes plugins enable talaria-push
   ```

   or add `talaria-push` to `plugins.enabled` in `~/.hermes/config.yaml`.

4. Configure APNs env vars (see `.env.example`) in the environment of the
   hermes processes — for a systemd-managed `hermes serve`:
   `EnvironmentFile=%h/.hermes/talaria-push/relay.env`.

5. Restart `hermes serve` / `hermes gateway`. Verify:

   ```sh
   curl -H "X-Hermes-Session-Token: $TOKEN" \
        http://127.0.0.1:9119/api/plugins/talaria-push/status
   ```

**Per-bot profiles:** profiles started as `hermes -p <bot>` share the root
`~/.hermes/plugins/`, and the device registry deliberately lives under the
*root* home (`~/.hermes/talaria-push/devices.json`) so one registration
covers every bot. Mention handles default to each process's own profile
name.

## Install (sidecar mode)

```sh
pip install ./relay              # installs talaria-push-relay + talaria-push-sidecar
cp relay/.env.example ~/.hermes/talaria-push/relay.env  # then edit
set -a; . ~/.hermes/talaria-push/relay.env; set +a
talaria-push-sidecar --base-url http://127.0.0.1:9119
```

The sidecar refuses to start without APNs config. Loopback/static-token
gateways only: it authenticates like the served SPA (`?token=` on the WS,
`X-Hermes-Session-Token` on REST), auto-scraping the token from `GET /`
when `TALARIA_GATEWAY_TOKEN` is unset. Gated (OAuth, non-loopback)
deployments need the sidecar co-located on the gateway host pointing at
`http://127.0.0.1:9119`.

The sidecar is deliberately a **best-effort complement**, not a second gateway
runtime. A fresh `/api/ws` connection receives global broadcasts, not the
session-bound `message.complete` stream; approvals and long tasks are therefore
read by polling `session.active_list` and `approval.pending`. Polling can be
late, cannot distinguish every in-turn error from a vanished session, and never
sees messaging-gateway inbound traffic, so `mention` remains hook-only. Routine
names come from the cron REST backstop, not from a completion hook.

The current sidecar also uses one `TALARIA_PUSH_BOT_NAME` (default `hermes`)
for approval and long-task events while it watches the gateway. It is not a
profile-aware replacement for one hook-loaded process per bot. For a gateway
with several profiles, use hook mode in each profile process, or run separate
sidecars with carefully split scopes and event kinds; otherwise attribution,
`profile_filter`, or duplicate suppression can be misleading. Finally,
offline/recovered alerts are only meaningful when the sidecar outlives the
gateway. A sidecar on the same host cannot report a host power loss; use an
off-host supervisor for that guarantee.

## Device registration API

Mounted like every dashboard plugin router at
`/api/plugins/talaria-push/` and **session-authenticated by the same
middleware as all `/api/*` routes** — `X-Hermes-Session-Token` header on
loopback, cookie/OAuth session on gated binds. The plugin adds no separate
secret on purpose: dashboard auth is the trust boundary.

```
POST   /api/plugins/talaria-push/devices
       {"device_token": "<hex>", "platform": "ios",
        "environment": "dev"|"prod", "gateway_id": "<saved-connection-id>",
        "profile_filter": ["ops-bot"]?}
GET    /api/plugins/talaria-push/devices
DELETE /api/plugins/talaria-push/devices            {"device_token": "<hex>"}
DELETE /api/plugins/talaria-push/devices/{token}
GET    /api/plugins/talaria-push/status
POST   /api/plugins/talaria-push/test               {"device_token"?: "...", "kind"?: "mention"}
```

`environment` selects APNs sandbox (`dev`, Xcode builds) vs production
(`prod`, TestFlight/App Store) per device. `gateway_id` is the phone's stable
source identity for this gateway; the relay echoes it into every payload so
colliding profile/session/approval ids cannot route to another saved machine.
`profile_filter` limits which **bots/profiles** may push to that device (empty
= all); it is not an event-kind filter. Registrations are idempotent upserts —
the iOS app re-POSTs its token on every launch.

The build and registration environments must agree:

| Talaria build | Signed entitlement | Device registration | APNs host |
|---|---|---|---|
| Xcode Debug / development install | `aps-environment=development` | `environment: "dev"` | `api.sandbox.push.apple.com` |
| TestFlight / App Store Release | `aps-environment=production` | `environment: "prod"` | `api.push.apple.com` |

`TALARIA_APNS_ENV` is only the relay fallback for a registration that omitted
its environment; the per-device value wins when present. A sandbox token is
not valid on the production host (and vice versa), so register a fresh token
when moving between Debug and TestFlight.

There is one intentional test-route exception: `POST /test` sends the
synthetic `talaria-test` event directly to every selected registered device.
It does **not** apply `profile_filter` or `TALARIA_PUSH_EVENTS`; this makes the
button useful for proving APNs credentials, token, and presentation. A real
hook/sidecar event goes through the dispatcher and `DeviceStore.for_bot`, so
its `profile_filter` is enforced. A successful test push therefore does not
prove that a real profile is allowed to push.

The test route defaults to the non-actionable `mention` shape because its
synthetic bot/session are not authoritative Hermes identities. Passing
`{"kind":"approval"}` remains useful for inspecting category presentation,
but its Approve action deliberately fails closed rather than answering work.

Store: `~/.hermes/talaria-push/devices.json`, `0600`, atomic tmp+rename
writes under an advisory `flock`, corrupt files quarantined as
`devices.corrupt`. `410 Unregistered` / `400 BadDeviceToken` from APNs
auto-prunes the record.

## Push payload contract (iOS side)

```jsonc
{
  "aps": {
    "alert": {"title": "ops-bot needs approval", "body": "rm -rf build …"},
    "sound": "default",
    "thread-id": "ops-bot",
    "category": "TALARIA_APPROVAL",        // TALARIA_RESPONSE | TALARIA_TASK |
                                           // TALARIA_MENTION | TALARIA_ROUTINE |
                                           // TALARIA_GATEWAY
    "interruption-level": "time-sensitive" // approval + gateway; others "active"
  },
  "kind": "approval",                      // approval|long_task|response|mention|
                                           // routine|gateway
  "gateway_id": "2F80…",                  // source-qualified app connection id
  "bot": "ops-bot",
  "session_id": "ab12cd34",
  "approval_request_id": "9f3c…",          // "" in hook mode (see gap table)
  "title": "…", "body": "…",
  "deeplink": "talaria://approvals"        // gateway→talaria://connections,
                                           // else talaria://bot/<bot>?session_id=…
}
```

`TALARIA_APPROVAL` is the category the iOS client registers its actionable
Approve/Later notification buttons against (per the HANDOFF spec).
`interruption-level: time-sensitive` requires the Time Sensitive
Notifications capability on the app id; the relay deliberately does not
use `critical` (needs a special Apple entitlement).

## APNs client notes

Pure Python, no pyapns2/aioapns: one authenticated HTTP/2 POST per
notification via `httpx` (+`h2`). Provider JWTs are ES256-signed with the
`.p8` key (`cryptography`) and cached ~50 minutes (Apple wants 20–60);
`403 ExpiredProviderToken` drops the cache and re-mints on the next send.
Sandbox and production hosts get separate pooled connections. Transient
`429/5xx` get one bounded retry; everything else is logged and dropped —
pushes are best-effort by design, approvals remain safe because the
upstream approval flow times out and denies on its own (ws-protocol.md §8).

## Live gateway/device certification

Static inspection, a green build, and the `/test` endpoint are not production
certification. Use a disposable Hermes profile and a real iPhone, and record
the gateway revision, Talaria build, relay environment, device-registration
record (with the token redacted), and the relevant gateway/relay log excerpts.
The complete app procedure is in [TESTING.md](../TESTING.md#5-live-gateway-and-push-certification); the relay-specific order is:

1. Check out the exact pinned Hermes revision and install/enable the copied
   `talaria-push` plugin. Put the same APNs environment and credentials in
   every process that can run the test (`hermes serve`, messaging gateway,
   and cron), then restart them. Expect the `registered 6 hooks` line once per
   process; a missing line means that process cannot produce hook pushes.
2. Build and install a Debug Talaria app with the development entitlement.
   Register its token as `environment: "dev"`, confirm `gateway_id` and the
   intended `profile_filter` in `GET /devices`, and use `POST /test` only to
   establish the APNs/token/presentation baseline. For TestFlight, repeat with
   a fresh production token, the Release entitlement, `environment: "prod"`,
   and `TALARIA_APNS_ENV=prod` as the fallback.
3. With `TALARIA_PUSH_EVENTS` temporarily set to one kind per producer, drive
   each real path: a gateway approval (including an actual Approve/Later
   response), a final-response-ready turn (including a fallback/error summary),
   an inbound @mention, and a cron routine. Confirm the source-qualified
   deep link, body truncation, and that an interrupted turn emits no response
   push while a non-interrupted fallback/error summary does. To test legacy
   long-task polling instead, exclude `response` and lower
   `TALARIA_PUSH_LONG_TASK_MIN_S` in the disposable unit; restore both values
   afterwards.
4. Register a second device/profile combination with a non-empty
   `profile_filter`. Trigger an allowed and a disallowed bot and verify only
   the allowed event arrives. Repeat the `/test` call and note that it is
   intentionally delivered even when the synthetic `talaria-test` bot is not
   in the filter; this is why `/test` cannot close the real-event check.
5. If sidecar mode is in scope, run it under a supervisor separate from the
   gateway, exercise approval/long-task polling and routine discovery, then
   stop the gateway for three health intervals and bring it back. Record the
   offline/recovered alerts and the known polling/profile limitations. Do not
   mark mention fidelity or per-profile sidecar attribution as certified.

Do not promote a push/parity row from partial to complete until a real device
has observed the corresponding event over the intended APNs environment and
the failure cases above have been recorded. A successful `/test` proves only
that one synthetic APNs delivery path worked.

## Security notes

- **Registration is dashboard-authenticated** — anyone with dashboard
  access can register a device and will then receive approval prompts and
  message previews. That matches the dashboard trust model (dashboard
  access already grants full approval control), but treat dashboard
  tokens accordingly.
- **Push bodies leak context** by nature: approval pushes carry the
  (upstream-redacted) command text; mention pushes carry message text.
  APNs is end-to-end TLS to Apple, but notification previews sit on the
  lock screen — the iOS client should honor "hide previews".
  Everything is truncated (≤120/≤900 chars) well below the 4 KB cap.
- **Secrets**: the `.p8` key never leaves disk; keep it `0600`. The relay
  never logs tokens or JWTs, and logs device tokens only as `…last8`.
- `devices.json` and its directory are created `0600`/`0700`.
- The sidecar's scraped session token grants full dashboard control —
  it lives only in process memory, is never written to disk, and the
  sidecar only calls read-only RPCs (`session.active_list`,
  `approval.pending`) and `GET` REST routes.
- The plugin registers **observer** hooks only; `pre_gateway_dispatch`
  always returns `None`, so it can never skip/rewrite messages, and a
  crashing handler is isolated by both the upstream dispatcher and the
  relay's own never-raise wrappers.

## Upstreaming

`talaria-push/` is self-contained, MIT (this whole component, unlike the
Talaria app itself, is plain MIT so it can land in hermes-agent),
manifest v2, no imports from the Talaria app, and follows the same
layout as bundled plugins (`plugin.yaml` + `register(ctx)` +
`dashboard/plugin_api.py`). The two upstream asks in the gap table
(`request_id` on `pre_approval_request`, a `cron_job_completed` hook)
would let hook mode cover everything except offline detection.

[hermes-agent]: https://github.com/NousResearch/hermes-agent
