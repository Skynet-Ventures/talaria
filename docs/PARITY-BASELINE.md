# Current Hermes parity baseline

This is the authority for new Talaria parity work. The older row-by-row audits
remain useful historical evidence, but their percentages and source citations
are not current until they are regenerated against this baseline.

## Exact authority

- Hermes repository: <https://github.com/nousresearch/hermes-agent>
- Hermes commit: `299c652a66bcc915a2a1e10cd2b648f196ec4bba`
- Talaria baseline: `f2f97ee4cc0ba973f162b0a3df3011639f5fd7c2`
- Audited cutoff: 2026-08-29, exact `299c652a` snapshot
- Machine-readable pin and authority-file hashes:
  [`parity/hermes-upstream.json`](../parity/hermes-upstream.json)
- Audited contract delta and remaining certification:
  [`docs/HERMES-299C652-AUDIT.md`](HERMES-299C652-AUDIT.md)

The current `02c7ae95..299c652a` audit spans 919 upstream commits and a Bot
Mode source split from one `plugin.js` into typed modules. Portable deltas are
bounded: Bot-owned sessions follow current profile configuration, legacy
session ownership gains an exact-profile backfill endpoint plus read-only
fallback, guarded model changes share one confirmation handshake, and
compaction state requires durable terminal evidence. Session/profile routing
remains exact-source qualified. Catalog, state-database, relay, Electron and
presentation-system churn stays server-owned or iOS N/A. The exact
classification and implementation order are in the new audit; older sections
below remain historical range evidence.

The earlier `b5455fdd..c1e25cad` drift was material: it changed all five
authority files and added canonical-chat adoption, renamed-friendly mentions,
preferred/worker activity, roster hiding, room prompt mirroring, profile-scoped
Projects, remote repository scanning, immutable room-session identity, and the
reattachable authenticated PTY contract. Those corrections landed on Talaria
`main` in PR #31, with live certification deliberately still open.

The subsequent `c1e25cad..95057c2` drift is narrower. GitHub reports 13 commits
ahead; only the Bot Mode plugin changed among the five hashed authority files.
Desktop fixed union-roster cache reads, focused-bot identity, and duplicate
mention completions. Talaria already uses one `unionRosterBots` source and the
source-qualified speaking bot for both completion and routing. Outside the
hashed authority set, Hermes refreshed OpenCode catalogs/routing (gateway-driven
in Talaria), honored `auxiliary.goal_judge.timeout` (a remaining management
surface), and made React/compiler and contributor-only changes. The exact
per-commit dispositions are in the current audit. Moving the pin records that
review; it does not certify gateway- or device-dependent behavior.

The next `95057c2..18a15a46` move adds no authority-file hash changes. Its
portable deltas are gateway prompt-delivery semantics and per-job cron
reasoning. Approval/clarify sends now preserve registrations when connector
delivery times out ambiguously, and prompt lifecycle acknowledgements no longer
block the relay read loop or seal a live draft. Those are gateway fixes with no
new Talaria wire shape, but they extend the live certification matrix. Cron raw
jobs now expose an optional `reasoning_effort` override. Talaria's explicit
mobile product decision authorizes a source-fenced REST mutation for this
job-owned field: the phone preserves unknown values on unrelated edits and
canonicalizes/clears only authored values, while the model tool remains
read-only. Live certification remains open. Formatting, React build,
contributor, and Windows test-only commits do not create portable iOS behavior.

The final audited `18a15a46..efb6b40f` window contains exactly 19 commits
across two parents and their merge. All five authority files remain
byte-for-byte unchanged, but three portable gateway behaviors moved outside
that set. Environment-stamped connector deployments now default to
relay-exclusive messaging, with an explicit allow-direct escape hatch,
process-global routing stamps, profile-scoped credentials, and an accurate
secondary-multiplex enroll warning. Built-in `MEMORY.md` and `USER.md` flags now
drive one fresh per-turn tool schema and independently gate both direct and
approved/staged writes. Custom OpenCode Go/Zen providers now get family-wide,
case-insensitive model routing, per-model API mode and `/v1` healing, plus
provider-wire aliases for reserved `web_search`/`search_files` names that map
back before Hermes dispatch. Talaria needs no new decoder for these changes:
relay deployment management remains an existing gap, while the memory toggles
and custom-endpoint/model/tool surfaces exist but need the exact live cases in
`TESTING.md`. The current audit records a disposition for every commit,
including test, metadata, superseded-intermediate, and merge-only changes.

The later authority-changing `efb6b40f..40643cba` audit is bounded by its
exact net tree: 20 files, 3,134 additions, and 85 deletions. Bot Mode now
projects a bounded version-3 room summary through every reachable gateway's
default-profile `ui_meta["hermes-bots-groups"]`, with immutable room ids,
stable message ids, explicit tombstones, reconnect fan-out, and conflict-safe
merge. Gateway profiles add per-key `ui_meta_revisions` and optional
`ui_meta_expected_revisions` compare-and-swap writes. Talaria now has the
typed CAS wire contract plus a bounded version-3 decoder, merger, tombstone
model, separately persisted projection ledger, protected room hydration,
reachable-credentialed-gateway publication, conflict retry/read-back, and reconnect
reseeding. Its existing rooms remain full, durable local rooms. Cross-client
storage/scheduler policy is automated-test covered, while production wiring
and end-to-end convergence remain uncertified until the retained live matrix
passes. The other net changes are host update receipts
and fleet code identity, container first-boot key generation, Telegram final
rendering, and Cloud MCP documentation; the current audit classifies their
client impact file by file.

Run the local check against an exact Hermes checkout:

```sh
python3 scripts/check_hermes_upstream.py --checkout /path/to/hermes-agent
```

Check whether upstream has moved:

```sh
python3 scripts/check_hermes_upstream.py --remote
```

The exact checkout plus manifest hashes are the authoritative, blocking gate.
The scheduled upstream-drift workflow runs the latter command only as an
informational signal: a newer moving `HEAD` does not make this audited snapshot
non-reproducible and must not trigger an automatic repin. Review the later
commit range explicitly. Only an audited authority-file change or material
portable-contract delta is blocking; metadata, test-only, and non-portable
drift can be recorded without moving this cutoff.

## What “parity” means

Talaria is Bot Mode first. Its navigation and interaction design remain native
to a phone, while it provides the portable functionality of Hermes Desktop
behind that interface.

A capability is **present** only when all applicable parts are proven:

1. The user can reach and complete it in Talaria.
2. Request and event shapes match the pinned Hermes gateway.
3. Durable state survives relaunch and gateway reconnect where Desktop state
   is durable.
4. Errors and partial delivery are visible; failures never masquerade as
   successful delivery, a room pass, or a completed mutation.
5. Focused automated behavior tests pass.
6. Gateway-dependent behavior has been exercised against a real compatible
   gateway. Source review or the existence of an RPC wrapper alone is partial.
7. Background-sensitive behavior has real-device evidence before it is called
   complete.

Platform-specific presentation may differ. Device-local Desktop mechanisms
such as Electron window placement are not copied literally, but a portable
user capability is not “n/a” merely because the Desktop interaction cannot be
copied. For example, local terminal and filesystem UI become secure remote
gateway controls on iOS.

## Current honest status

The 2026-08-17 Desktop audit measured 30% covered portable behavior. Substantial
Bot Mode and portable Desktop work has landed since then, including the current
Hermes corrections in PR #31. There is no defensible newer percentage until
the granular ledgers are regenerated against this exact pin.

The current implementation is best described as a mobile Hermes client with
substantial Bot Mode support, not yet a 1:1 client. Source-qualified A2A,
standalone multi-member rooms, rich transcript interaction, and a guarded
gateway-backed Command Center are implemented and automated-gate certified;
they remain provisional until live-gateway and real-device certification. The
largest remaining product gaps are richer transcript media/tool presentation,
portable management depth (including auxiliary goal-judge controls), workspace
depth, and artifact pagination/unlocked-root exceptions. The authenticated gateway PTY is now
implemented, with live-gateway and real-device certification still open:

- Talaria retains authenticated clients for multiple gateways and routes chat,
  events, sessions, full approval recovery/prompts, and unread state by source.
  Routine listing, detail/history, create/edit/run/delete, and toggles are also
  routed. Skills, toolsets, plugins, and MCP/OAuth management are routed too;
  profile read/edit/create/duplicate, model catalogs, looks, and portraits are
  routed too. Pet state, galleries, selection, generation/hatching, and event
  progress are also source-qualified. Mobile management now includes typed,
  source-qualified inference OAuth/custom endpoints, voice providers, memory
  providers, profile rename/delete, runtime controls, logs, and push filters;
  these new paths remain partial until live-gateway certification.
- Talaria stores multiple ordered room memberships per bot, standalone room
  identity, a protected local transcript/blob index, and source-qualified
  member descriptors. Foreign members resolve through their retained owning
  gateway; accepted/uncertain sends are durable and never blindly replayed.
  Membership convergence uses a source-qualified persistent outbox so an
  offline create/rename/disband can finish after reconnect.
  The bounded `hermes-bots-groups` projection now adds explicit shared
  tombstones, safe protected hydration, reachable-credentialed-gateway fan-out, and
  per-key `ui_meta` compare-and-swap with retry/read-back. Cross-client room
  descriptors from another client's local connection registry remain visible
  as view-only frozen seats and are never routed by a guessed label. Convergence
  remains provisional until the live conflict/reconnect matrix is retained.
- Current Hermes also exposes agent-guided `tour.request` prompts and whole-turn
  activity across transcript gaps. Talaria's room work includes the bounded
  current-run activity feed; tours and transcript activity remain queued with
  the transcript batch rather than being mistaken for management API drift.

### Push status: implemented, not yet certified

The gateway relay, device registration/filtering, APNs fan-out, notification
actions, and source-qualified payloads are implemented. The filter contract is
deliberately split: `TALARIA_PUSH_EVENTS` is a process-wide event-kind
allow-list, while a device's `profile_filter` is a per-bot/profile allow-list;
neither is a per-device event-kind preference. The dashboard `/test` endpoint
is a synthetic presentation probe and intentionally bypasses both filters, so
it cannot establish real-event parity.

The pinned Hermes source also has a `post_llm_call` observer: it fires once when
a non-interrupted turn has any non-empty final response (including a
fallback/error summary) and includes `assistant_response`; it is not the
session-bound WebSocket `message.complete` event. The current relay registers
that hook and emits a source-qualified `response` push; cron turns are
fail-closed because Hermes does not expose immutable creator/delivery
provenance, and the legacy duration-only `long_task` push is
suppressed while `response` is enabled. The current plugin should therefore
log six hook registrations per process. A sidecar has no response producer and
must explicitly disable `response` if it needs polling-based long-task
notifications.

Debug and TestFlight are separate APNs environments (`dev`/sandbox versus
`prod`/production), and every Hermes process that can own an event needs its
own inherited environment. On 2026-08-20, real approval and final-response
notifications were observed on the paired Debug device, but no retained
repository/PR report yet records every field required by `TESTING.md` section
5. Treat certification as pending. Mention delivery, cron fail-closed
negatives, interrupted and profile-filter negative cases, exact-session cold-launch tap routing, honest
sidecar limitations, and the full TestFlight production matrix remain open.
Follow [TESTING.md §5](../TESTING.md#5-live-gateway-and-push-certification)
and the [relay certification procedure](../relay/README.md#live-gatewaydevice-certification)
before moving push rows from partial to complete.

## Delivery ledger

Reviewed follow-up work now includes transcript edit/rewind/regenerate,
Gateway Operations maintenance, files/git/projects, live pet presentation,
Bot Mode kickoff, response-ready APNs delivery, native motion, the
attachment-source redesign, and the current-Hermes contract corrections merged
in PR #31; later reviewed slices add notification/session authority, cron
reasoning effort, shared-room projection/CAS, authenticated Advanced Terminal,
and exact-source message-level child creation. Granular-ledger regeneration,
remaining portable surfaces, App Store
release, and independent live-gateway/device certification remain outstanding.

Every item below ships as one or more independently reviewable PRs. A checked
implementation item means its reviewed code is on `main`; it does not override
the completion rules above. Gateway- and device-dependent checked items remain
partial until the unchecked certification gates are recorded.

- [x] Pin the exact current Hermes authority and automate upstream drift detection.
- [ ] Regenerate both granular ledgers from the pinned source and stabilize the
      crash-recovery work as reviewable, tested slices.
- [x] Replace global gateway switching with a managed multi-connection pool and
      source-qualified state, events, sessions, and mutations.
- [x] Migrate group metadata to multiple memberships and standalone room identities.
      Local implementation merged; exact Hermes shared gateway projection and
      metadata CAS are implemented in the separately tracked item below.
- [x] Implement shared `hermes-bots-groups` projection consumption/publication,
      durable tombstones, reachable-gateway fan-out, per-key profile CAS conflict
      recovery, read-back confirmation, and legacy-gateway feature detection.
      Automated implementation is complete; the six live certification cases
      in `TESTING.md` remain open.
- [x] Implement cross-machine room delivery, explicit failure semantics,
      attachments, threads, and stranded-reply recovery. Implementation merged;
      the room prompt/relaunch matrix remains open.
- [x] Close the audited current Bot Mode implementation gaps: roster hiding,
      avatars, remote creation, target capabilities, mentions, routines,
      canonical chats, room prompts, and profile lifecycle. Live certification
      remains open row by row.
- [ ] Finish rich transcripts and full session interaction controls.
      Default working presentation is an animated agent avatar; tool activity
      and gateway-exposed reasoning summaries are opt-in advanced views.
      Multiline full-width capped composition, edit/rewind/regenerate, and
      message-level child creation are implemented; remaining work includes the
      N/M alternative-branch picker and lineage presentation, persistent rich
      media, grouped tool runs, advanced renderers, per-message TTS/timing, and
      a durable prompt queue.
- [ ] Finish mobile management for providers, models, profiles, tools, skills,
      MCP, plugins, messaging, learned-memory curation/import/export, auxiliary
      slots, and subagent depth. Routine per-job reasoning effort is implemented
      but remains live-certification pending.
- [ ] Finish artifact pagination and deeper Git/System UI. Exact retained-source
      discovery, explicit bounded/stale/failure state, and conditionally locked
      retained-body reads are implemented. Gateways returning `locked_root: nil`
      remain fail-closed, and live certification remains open;
      certify the implemented gateway-backed Files, Projects, Git, Command
      Center, and authenticated Advanced Terminal against their live matrices.
- [ ] Finish push, background, offline, reconciliation, and capability/version reliability.
      Push specifically remains implemented-but-uncertified until the Debug /
      TestFlight, real-event, filter, and sidecar matrix in TESTING.md is
      recorded.
- [ ] Certify the complete matrix against the pinned gateway and document only
      the remaining true platform exceptions.

Multi-connection implementation checkpoints:

- [x] Canonical source-qualified bot identity with fail-closed bare-name resolution.
- [x] Coalescing, retryable authenticated client pool shared by primary and
      secondary roster connections.
- [x] Source-qualified canonical chat state, streaming/tool events, and runtime
      session routing, including colliding short session ids.
- [x] Open, send, steer, stop, react, and change session controls for foreign
      bots without changing the primary connection.
- [x] Source-qualified stored-session list/open/rename/delete/branch/compress/
      export/search and title events, with collision-safe caches.
- [x] Source-qualified unread events, durable roster watermarks, badge clearing,
      and gateway-role transitions, including colliding profile names.
- [x] Source-qualified approval request identity, pending replay,
      acknowledgements, full-choice responses, and clarify/sudo/secret prompts.
- [x] Source-qualified routine roster, cron.changed refresh, safe legacy-job
      quarantine, and pause/resume routing.
- [x] Source-qualified routine detail/history/create/edit/run/delete with
      gateway-scoped REST credentials, caches, delivery targets, and transcripts.
- [x] Source-qualified capability state and skills/toolsets/plugins/MCP/OAuth
      mutations, including gateway detach and role-transition fencing.
- [x] Source-qualified profile read/edit/create/duplicate, model catalogs,
      cosmetics, and portrait asset state/mutations.
- [x] Source-qualified pet state, bitmap/thumbnail caches, gallery mutations,
      generation/hatching, progress events, and detach cleanup.
- [x] Source-qualified model catalogs, selection/confirmation, reasoning effort,
      fast mode, and picker-state detach cleanup.
- [x] Source-qualified gateway-global approval mode, timeout, allowlist
      revocation, bypass display, and messaging pairing administration with an
      explicit gateway selector and per-source live refresh.
- [x] Source-qualified gateway default model/reasoning settings, provider
      credential save/disconnect, and catalog refresh with generation-fenced
      reads and secret scrubbing across gateway switches.
- [x] Source-qualified inference OAuth/custom endpoints, dynamic memory and
      voice providers, profile rename/delete, push registration/filtering,
      runtime/image/memory controls, and authenticated log reads are implemented
      with captured-target/generation fencing. Live-gateway certification is
      still required before the delivery-ledger management row can close.

## Crash-recovery snapshot disposition

Commit `3139626a73b2e41bce0c3ef6e5dfa15b0817f5c6` is recovery material, not an
integration branch. It diverged from the Phase B baseline while independently
carrying versions of work that later landed through the reviewed Phase C and D
PRs. It must never be merged or cherry-picked wholesale.

- Phase C handles, search, and mentions already landed on `main`; their reviewed
  versions are authoritative.
- Phase D notifications, activity, unread state, and forever-chat protection
  already landed on `main`; their reviewed versions are authoritative.
- The snapshot's singular `group` room model is rejected because current Hermes
  uses multiple memberships and standalone rooms. Room work starts from the
  pinned upstream contract, not from that data model.
- Avatar/cosmetic pieces that are not already on `main` may be extracted later
  only after comparison with current Hermes blob-avatar behavior.
- No parity row moves merely because the snapshot contains an implementation.

CI now runs both the portable `talaria-verify` executable and individually
named XCTest cases. New pure behavior belongs in `TalariaKit` with focused
XCTest coverage; gateway and lifecycle slices add integration fixtures before
their status can move to present.

## Merge rule

Runtime PRs merge in dependency order. Each PR must identify the ledger rows it
moves, include focused tests, pass repository CI, and state any gateway/device
evidence still needed. Upstream drift is resolved before claiming new parity.
