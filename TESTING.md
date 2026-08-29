# Testing Talaria

Thanks for trying this. Talaria is young and moving fast — this guide gets you
from clone to a working app against your own gateway, and tells you honestly
what to expect when you get there.

**You need:** macOS with **Xcode 16+**, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), and a reachable **`hermes serve`** gateway. Push
notifications additionally need a paid Apple Developer account; everything
else works with a free one.

---

## 1. Simulator (fastest — no Apple account needed)

```sh
git clone https://github.com/Skynet-Ventures/talaria.git && cd talaria
make ios
```

That runs `xcodegen generate` in `ios/` and builds the `Talaria` scheme. Open
`ios/Talaria.xcodeproj` and run, or build straight from the command line:

```sh
cd ios
xcodebuild -project Talaria.xcodeproj -scheme Talaria \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build -quiet build CODE_SIGNING_ALLOWED=NO
```

The Simulator can reach a gateway on your LAN or over Tailscale, so this is a
real test, not a toy one. Onboarding also offers **“Explore with demo data”**
if you just want to look around without a gateway.

## 2. Your own iPhone

The project's default bundle id belongs to this repo's author, so **use your
own** — pass `TALARIA_BUNDLE_ID` and your Apple team id:

```sh
cd ios && xcodegen generate
xcodebuild -project Talaria.xcodeproj -scheme Talaria \
  -destination 'generic/platform=iOS' -derivedDataPath build-device \
  -allowProvisioningUpdates build \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=YOURTEAMID \
  TALARIA_BUNDLE_ID=com.yourname.talaria \
  CODE_SIGN_ENTITLEMENTS=Talaria/Support/Talaria-dev.entitlements
```

Your team id is in [developer.apple.com/account](https://developer.apple.com/account)
under Membership.

**Why `Talaria-dev.entitlements`:** the full entitlements file declares an App
Group, which CLI automatic signing cannot provision. The dev variant drops it
and keeps push. The only casualty is a theme lookup the widget makes through
the shared container, which falls back gracefully.

For a custom bundle id, the APNs topic must be exact: set
`TALARIA_APNS_TOPIC` in the gateway relay environment to the signed app's
`PRODUCT_BUNDLE_IDENTIFIER` (the value supplied by `TALARIA_BUNDLE_ID`), with
no suffix or alternate identifier. For a TestFlight/Release build, keep
`aps-environment=production` and update the Release App ID, push capability,
provisioning profile, and application-group entitlement consistently. If the
bundle id changes, change the Release app-group identifier and the matching
widget/extension provisioning profiles too; do not ship a custom-bundle app
signed with the stock `group.bot.talaria.ios` entitlement or a relay topic for
the old bundle.

Install and launch:

```sh
xcrun devicectl list devices        # find your device id
xcrun devicectl device install app --device <DEVICE_ID> \
  build-device/Build/Products/Debug-iphoneos/Talaria.app
xcrun devicectl device process launch --device <DEVICE_ID> com.yourname.talaria
```

First run needs the phone plugged in and unlocked, and you must tap **Trust**.
After that pairing sticks and **you can install over Wi-Fi** — same commands,
no cable, as long as both machines are on the same network.

Also: on the phone, enable **Settings → Privacy & Security → Developer Mode**.

## 3. Connecting to your gateway

Run the gateway where your bots live. Bind it somewhere the phone can reach —
loopback will not do:

```sh
hermes serve --host 0.0.0.0 --port 9119       # or your Tailscale IP
```

In onboarding (or Connections → add gateway) enter the URL, e.g.
`http://100.x.y.z:9119`. Three ways in, matching Hermes Desktop:

| Mode | When | How |
| --- | --- | --- |
| **Session token** | loopback / fully trusted | paste the dashboard session token |
| **Sign in with Nous Research** | any non-loopback bind (gated) | in-app OAuth (RFC 8252 PKCE) |
| **Username & password** | trusted LAN / tailnet | the gateway's basic-auth provider, same in-app flow |

Sign-in runs in an **in-app web sheet**, not Safari. That is deliberate:
Lockdown Mode blocks `http://` on non-standard ports, which breaks the
loopback redirect the standard flow depends on. The sheet intercepts the
callback before any socket is dialed, so sign-in works with Lockdown Mode on.

Tokens live only in the iOS Keychain. There is no Talaria account and no
server of ours in the path — your phone talks to your gateway.

## 4. Push notifications (optional)

Push needs a gateway-side relay, since hermes-agent has no APNs support
upstream. It ships here: [`relay/`](relay/). You will need an APNs `.p8` key,
its Key ID, and your Team ID. Follow [`relay/README.md`](relay/README.md),
then in the app: **Connections → Notifications → Enable → Send test push**.
That card shows every link in the chain (iOS permission → APNs token → relay
registration), so you can see exactly where it breaks.

The test button is deliberately synthetic: it proves the APNs credentials,
token, presentation, and registration path, but it bypasses both the
process-wide `TALARIA_PUSH_EVENTS` allow-list and the device's `profile_filter`.
Use the live procedure below before treating a real bot event as certified.

## 5. Live gateway and push certification

This is the minimum evidence for a push/parity claim. Run it against a
disposable profile on a real reachable `hermes serve` gateway and a real iPhone;
the Simulator cannot receive APNs. Keep the gateway revision, app build
configuration, relay environment, redacted `/devices` record, and log excerpts
with the test report.

### Debug / sandbox pass

1. Check out the exact Hermes revision pinned in
   [`docs/PARITY-BASELINE.md`](docs/PARITY-BASELINE.md) and install the copied
   `relay/talaria-push` directory into the gateway's root plugin directory.
   Enable it and restart every process that can run the test (`hermes serve`,
   `hermes gateway`, and cron).
2. Put the APNs credentials and `TALARIA_APNS_ENV=dev` in each process's
   environment. The Debug app uses
   `Talaria/Support/Talaria-dev.entitlements` (`aps-environment=development`),
   so register the device with `environment: "dev"`. A shell export is only
   inherited by children; separate systemd/launchd units need their own
   `EnvironmentFile`, and editing a file does not update an already-running
   daemon.
3. With `HERMES_PLUGINS_DEBUG=1` or the gateway log visible, expect one
   `talaria-push: registered 6 hooks ...` line per Hermes process that loads
   the plugin after restart. Six is the current registration count; it is not
   six pushes per turn. A process with `TALARIA_PUSH_DISABLE=1` registers no
   hooks. If the line is absent in the process that owns an event, that event
   cannot be observed in hook mode.
4. In Talaria, enable notifications and confirm `GET /devices` (through the
   authenticated gateway) shows the expected `environment`, `gateway_id`, and
   `profile_filter`. Send the test push once. This is only the APNs baseline,
   not proof that a real profile event will fan out.
5. Trigger each supported real event in turn: a gateway approval and actual
   Approve/Later response; a final-response-ready turn (including a
   fallback/error summary); and an inbound @mention. Confirm the notification category,
   source deep-link, bot identity, and body. Verify that an interrupted turn
   emits no response push while a non-interrupted fallback/error summary does.
   To exercise the legacy long-task path, explicitly remove `response` from
   `TALARIA_PUSH_EVENTS`, lower
   `TALARIA_PUSH_LONG_TASK_MIN_S` in the disposable unit, and restore the
   normal values afterwards. Also complete a Slack-owned and a local cron job
   and confirm both remain silent: routine push is fail-closed until Hermes
   exposes immutable job creator/delivery provenance.

### Profile filtering and sidecar pass

Register a second device (or change one record) with a non-empty
`profile_filter`, then trigger one allowed and one disallowed profile. Only
the allowed real event should arrive. Repeat **Send test push** and expect it
to arrive even when `talaria-test` is not in the allow-list: `/test` directly
targets selected registrations so the setup button cannot be blocked by a
profile choice. This intentional difference is why a green test button cannot
close the filter test.

If sidecar mode is part of the deployment, run it under a supervisor that can
outlive the gateway (ideally on another host). Split `TALARIA_PUSH_EVENTS` so
hook and sidecar producers do not overlap. Exercise its approval/long-task
polling, confirm cron remains silent, then stop the gateway for three health intervals
and restart it; record both offline and recovered alerts. The sidecar cannot
see messaging-gateway @mentions, receives no session-bound `message.complete`
event, approximates long-task completion from polling, and currently uses one
`TALARIA_PUSH_BOT_NAME` for approval/long-task attribution rather than being
profile-aware. Do not claim per-profile sidecar or mention fidelity from this
pass.

### TestFlight / production pass

Repeat the APNs baseline and the real-event checks with a fresh TestFlight
install. Release signs `Talaria/Support/Talaria.entitlements`
(`aps-environment=production`), so register the new token as
`environment: "prod"` and use `TALARIA_APNS_ENV=prod` as the relay fallback.
Production and sandbox tokens/hosts are not interchangeable; a wrong pairing
can produce `BadDeviceToken`/`Unregistered` and the relay will prune the
record. A production push is not certified by a successful Debug push.

Do not mark the push row complete until the corresponding real event has been
observed on the intended APNs environment and the negative/filter/sidecar
cases above are recorded. Full relay contract and payload details remain in
[`relay/README.md`](relay/README.md).

## 6. Exact `40643cba` gateway-delta checks

The parity cutoff is a reproducible snapshot, not whatever Hermes `HEAD` is
when this guide is read. Before recording any result, check out
`40643cbaf9b767af146694131ffb8f8160f25e1c` and verify both its identity and
the five authority-file hashes:

```sh
python3 scripts/check_hermes_upstream.py
python3 scripts/check_hermes_upstream.py --checkout /path/to/hermes-agent
```

`python3 scripts/check_hermes_upstream.py --remote` is only a drift report. A
newer remote `HEAD` does not invalidate the audited checkout and is not a
reason to repin without reviewing the later commit range.

Retain the exact gateway commit, Talaria commit/build, selected profile and
gateway, redacted config, request/result log excerpts, and expected/actual
result for each case below. Upstream unit tests establish the source contract;
they do not certify Talaria's live behavior.

### Relay-exclusive deployment

Use a disposable connector-fronted gateway with at least one directly enabled
messaging adapter. An environment `GATEWAY_RELAY_URL` should enable relay and
disable direct messaging adapters, including an explicitly configured one,
while local, API-server, and webhook surfaces remain available. Repeat with
`GATEWAY_RELAY_ALLOW_DIRECT_PLATFORMS=true` and expect the direct adapter to
remain enabled. A relay URL configured only in YAML remains additive.

For a multiplex gateway, prove routing stamps come from the process/default
root while relay secrets remain isolated per profile. A profile-only routing
stamp must not half-enable config or registration. Finally, run gateway enroll
from a secondary profile and retain the warning that its URL/wake stamps will
not activate from that profile's isolated `.env`. These are deployment checks,
not evidence that Talaria implements messaging/relay administration; that
mobile management surface remains open.

### Independent built-in memory stores

From Talaria's gateway operator settings on a disposable profile, enable only
`USER.md`, start a fresh turn, and verify the memory tool advertises/accepts
only the `user` target while direct and approved/staged `memory` writes are
rejected. Repeat with only `MEMORY.md` enabled and the inverse expectations.
Then disable both and verify the built-in memory tool is unavailable; re-enable
one store and start another turn to prove the old availability decision was
not retained. Record the bounded invalid-target error and its recovery hint.

### Custom OpenCode family routing and tools

Using credentials authorized for the test, create and activate a custom
OpenCode Go or Zen endpoint from Talaria's Name / Base URL / Model form. Use a
lowercase family-suffixed name such as `opencode-go-bridge`; Hermes derives the
endpoint id from that name and lowercases it. Exercise one Responses model
(GPT/Grok), one Messages model (MiniMax/Qwen/Claude as appropriate), and one
Chat Completions model (DeepSeek/GLM/Kimi as appropriate), switching between
them so a stripped `/v1` must be restored. A transport explicitly configured
on the gateway remains authoritative; Talaria's custom-endpoint editor does
not expose that field.

Talaria cannot create a mixed-case provider id: its form sends no independent
id, and Hermes generates a lowercase slug. If the case-insensitive provider
predicate needs live proof beyond the pinned upstream tests, hand-write a
mixed-case family key such as `OpenCode-Go-Bridge` plus the matching
`model.provider` in a disposable gateway config, restart that gateway, and run
the relevant model there. Record this as gateway-config evidence, not as a
Talaria-created endpoint case.

On a Responses model, trigger both `web_search` and `search_files`. The request
must avoid the provider's reserved-name HTTP 400, while Talaria's tool cards
and Hermes dispatch retain the canonical names; a visible `hermes_web_search`
or `hermes_search_files` name is a failure. Do not call this path certified
until the retained report covers endpoint save/activate, model switches, one
completed answer per API family, and both tool calls.

### Shared room projection and profile-metadata CAS (implementation gate)

This is not yet a passing live certification case. Exact Hermes publishes
bounded version-3 room projections in default-profile
`ui_meta["hermes-bots-groups"]` and exposes per-key `ui_meta_revisions`.
Talaria now has bounded projection/ledger storage, safe protected-room
hydration, reachable-credentialed-gateway fan-out, per-gateway serialization and
bounded conflict retry, exact CAS read-back confirmation, feature-detected
legacy fallback, and adoption/reconnect/foreground reseeding. Focused tests
cover the storage and scheduler policies, including privacy cancellation and
applying a cached disband tombstone before network recovery. Production target
discovery, connection leasing, and lifecycle-hook wiring are source-reviewed;
the live matrix below remains their certification gate. Do not claim certified
Desktop/mobile shared-room convergence from automated tests alone.

First pin the gateway protocol directly: two clients must read the same
revision, then submit different `profiles.configure` writes with that expected
revision. Exactly one succeeds and increments it; the loser receives
`applied.ui_meta=false`, an exact `ui_meta_conflicts` expected/actual pair, and
the current revision. Delete the key and prove its revision survives deletion
so the stale client cannot recreate it. Also prove that omission of
`ui_meta_expected_revisions` retains the documented legacy best-effort path.

Retain a two-Desktop/one-phone report covering:

1. Hydration of name, picture, source-qualified members, and bounded recent
   transcript from each attached gateway without replacing Talaria's full
   protected local transcript. A foreign client-local connection id must stay
   visible as a view-only frozen seat, never route by label, and become live
   only after an exact configured gateway identity exists.
2. A concurrent Desktop/phone write conflict followed by reread, stable-id
   merge, CAS retry, exact revision increment, and read-back confirmation.
3. Rename with the same immutable room id; disband with a final `id:`
   tombstone; and same-name recreation with a fresh id and fresh sessions.
4. A truncated or missing remote projection that does **not** delete local
   rooms/messages, plus explicit tombstone propagation that does. Verify an
   absent bounded image preserves the prior avatar while Talaria's present
   empty-string clear removes it on a peer and does not resurrect after restart.
5. One gateway offline during create/rename/disband, later reconnect and
   reseed, and fan-out to every other reachable default-profile gateway.
6. Feature detection against an older gateway with no `ui_meta_revisions`,
   exercising only the bounded legacy fallback without presenting it as
   conflict-safe.
7. On the phone, type distinct unsent main-composer text in two rooms, switch
   repeatedly, background and terminate the app, then relaunch and confirm
   each immutable room restores only its own text. Rename one room and retain
   its draft. Prove a failed/uncertain send preserves it and an acknowledged
   send clears only that room. Disband and same-name recreate must restore no
   old text; an authoritative remote tombstone and Settings → Delete Local
   Data must also purge it. Confirm no draft text appears in either gateway's
   shared `hermes-bots-groups` profile metadata.
8. In a two-member room, start an exact member turn, open Member controls,
   choose Hold, and confirm. The selected member must remain held while the
   peer keeps receiving rounds; relaunch and reconnect must retain the hold.
   Force a disconnect after interrupt dispatch and verify the UI reports an
   uncertain stop without resuming or retrying it. Reconnect with a rebound
   runtime session and verify it remains held. Also terminate the app while
   the row says the stop is pending; relaunch must show an uncertain result,
   issue no automatic interrupt retry, and keep skipping that member. Explicit
   Resume must release only that exact member. Repeat across room rename and
   exact profile rename, then prove member removal/re-add, disband/same-name
   recreation, remote
   tombstone, and Delete Local Data inherit no actionable hold.

The projection limit is 48,000 bytes with at most 16 recent messages per room,
1,200 text characters per projected message, and a 24,000-character image.
Exceed each bound in the fixture and verify graceful trimming, never implicit
deletion. Until all eight cases are retained, cross-client shared rooms remain
uncertified even if standalone room routing passes.

---

## What to expect

Talaria is **Bot Mode on a phone** — a roster of your Hermes profiles, each
with one forever-chat — not a session manager. If it starts feeling like a
list of sessions, that is a bug.

The older row-by-row ledgers remain useful historical evidence, but their
percentages have not yet been regenerated against the current Hermes pin. The
authoritative status and remaining certification are in
[docs/PARITY-BASELINE.md](docs/PARITY-BASELINE.md); broad Desktop coverage is
still catalogued in [PARITY.md](PARITY.md).

**Works today:** the roster, chat with streaming, reasoning ("Thought") blocks,
tool chips, block markdown, approvals with the full choice set, model picker
grouped by provider, sessions, cron, capabilities (skills/MCP/toolsets), voice,
attachments, slash commands, pets, three themes, Live Activity.

**Known rough edges:** standalone multi-bot rooms, source-qualified commands,
and profile-scoped Projects are implemented, but their real multi-gateway,
prompt/relaunch, and device certification remains open. A phone that sleeps
mid-turn can briefly show a bot as still working, and several other surfaces
have not completed their live-gateway matrix, so please report anything that
looks confidently wrong.

## Reporting a bug

A screenshot plus these four things makes almost any report actionable:

1. **What you did** and what you expected.
2. **Device + iOS version**, and whether **Lockdown Mode** is on.
3. **Gateway**: `hermes --version`, how it is bound (loopback / LAN /
   Tailscale / cloud), and which auth mode you used.
4. **Anything in the gateway log** (`~/.hermes/logs/serve.log`) around the
   time it happened.

Please redact tokens, `.p8` contents, and gateway URLs you would rather not
share publicly. If it is a **security** issue — auth, Keychain, the approval
path, or the relay — do not open a public issue; see
[SECURITY.md](SECURITY.md).

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) has the details. The short version: commits
need a DCO sign-off (`git commit -s`), the Xcode project is generated so never
commit `Talaria.xcodeproj`, and features should map to a row in the parity
docs. Protocol changes belong upstream in
[hermes-agent](https://github.com/NousResearch/hermes-agent) — Talaria speaks
its `/api/ws` surface as-is.
## Advanced Terminal live certification

Automated tests cover PTY target validation, exact query encoding, session-token
and OAuth-ticket authentication, ordered byte delivery, close-code recovery,
resize frames, renderer input policy, and lifecycle detachment. Before marking
Advanced Terminal certified, run this matrix against the pinned Hermes gateway
and a real iPhone/iPad:

Informal app use is not a certification artifact. Response-ready and approval
pushes have been observed on-device, but no retained terminal matrix is recorded
yet; every item below remains open.

- Sign in once with a dashboard session token and once with gated native OAuth;
  prove each reconnect mints a fresh ticket and a near-expiry token refreshes.
- Select a non-default profile, type and paste through the native TUI, exercise
  an approval, rotate the device, and verify output, keyboard, copy, links, and
  VoiceOver focus remain correct.
- Background briefly and cross Wi-Fi/cellular boundaries; prove ordered replay
  reattaches the same token without replaying uncertain input.
- Leave the app detached for at least 30 minutes. Talaria must ask before
  reconnecting because Hermes does not disclose whether the expired token will
  reattach or create a new PTY.
- Open the same attachment elsewhere and prove `4409` stops reconnecting; prove
  child exit `4410`, auth `4401`, unavailable `4404`, and server `1011` states
  require explicit recovery instead of looping.
- Rename/delete the selected profile, switch/remove/sign out of the gateway,
  and run privacy reset. Local sockets, transcript buffers, and attach tokens
  must be gone. Record that Hermes has no remote terminate endpoint and may keep
  a detached remote child until its server-side TTL.
