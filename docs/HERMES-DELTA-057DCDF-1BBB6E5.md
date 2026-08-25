# Hermes delta audit: `057dcdf` through `1bbb6e5`

This is the exact-source audit of Hermes
`057dcdf236f8a6a26721c10fcc6ccb72726e272a` (exclusive) through
`1bbb6e5bce56e721ab685af4cd87df21bbff4d35` (inclusive), performed on
2026-08-25. It is intentionally additive to the complete
`40643cba..057dcdf` closure. It does not rewrite that evidence or move
Talaria's canonical Hermes pin.

The immediately following upstream range is covered separately by the
additive [`1bbb6e5..02c7ae9` successor audit](HERMES-DELTA-1BBB6E5-02C7AE9.md).
That range adds no new Talaria client work and does not change this audit's pin
decision.

The range contains **130 commits and 324 net-changed paths**, with 17,430
additions and 4,080 deletions. Every commit is listed in
[`hermes-delta-057dcdf-1bbb6e5-commits.tsv`](../parity/hermes-delta-057dcdf-1bbb6e5-commits.tsv),
including all topic-branch commits and merge commits. Every net-changed path is
listed in
[`hermes-delta-057dcdf-1bbb6e5-paths.tsv`](../parity/hermes-delta-057dcdf-1bbb6e5-paths.tsv).
The JSON manifest fixes their counts and SHA-256 values; the checker recomputes
the exact graph, subjects, parents, path statuses, line totals, and authority
hashes from an exact Hermes checkout.

## Classification

| Unit | iOS-portable | Desktop-only | tests / metadata / merge | Total |
|---|---:|---:|---:|---:|
| Commits | 73 | 19 | 38 | 130 |
| Net-changed paths | 133 | 94 | 97 | 324 |

`iOS-portable` includes server-owned runtime behavior that reaches Talaria
through an existing generic envelope. It does not mean every such row requires
Swift changes. The disposition column identifies the rows that do. A commit is
`Desktop-only` only when its production effect is local to Electron/web/TUI
presentation. Test, documentation, contributor metadata, formatting-only, and
merge commits are kept explicit rather than silently dropped.

## Five-file authority result

Four authority files are byte-for-byte unchanged:

- `apps/desktop/src/plugins/hermes-bots/plugin.js`
- `website/docs/user-guide/bot-mode.md`
- `website/docs/user-guide/multi-connection-desktop.md`
- `apps/desktop/DESIGN.md`

`website/docs/user-guide/desktop.md` changed from SHA-256 `889b20b…` to
`a32666f…`. Its substantive edits rename the page to “Hermes Desktop,” add the
Desktop download link, and document Hyprland HUD floating/pinning. Those edits
are Desktop-local. The authority change itself creates no iOS behavior, but it
must still be recorded and prevents reusing the previous five-file hash set.

## Material portable deltas

### 1. Lossless gateway event replay — open client implementation

Commits `87631bd8` and `beb79412` add a new wire contract:

- session-scoped event frames gain monotonic `params.seq`;
- `gateway.ready.payload.replay_epoch` identifies the process-local sequence
  namespace;
- `session.events.since {session_id,last_seen}` returns ordered `events`,
  `latest_seq`, `truncated`, `count`, and `epoch`;
- `session.events.stats` exposes bounded-buffer telemetry;
- the server retains at most 512 events per session and 64 sessions.

Talaria does not consume this contract. Its `GatewayTransport.inboundSequence`
is a client-local frame counter created afresh for each socket, and
`GatewayEvent` drops the server's `params.seq`. `gateway.ready` decoding also
drops `replay_epoch`; there is no `session.events.since` call. Heartbeats can
detect and replace a dead socket, but they cannot recover events emitted while
the phone was suspended or disconnected.

Required slice: retain source-qualified per-session server watermarks; adopt
and compare epochs; after reconnect hold racing live frames while bounded
replay runs; dispatch only increasing sequences; reset on process epoch change;
and treat `truncated:true` as a required authoritative history/session refresh,
not a successful replay. Legacy gateways without these fields remain on the
existing resume/backfill path. This should build on, not replace, Talaria's
client-local snapshot/event boundary.

### 2. Fail-closed pre-compress memory checkpoint v2 — open management

Commits `1104ffe0`, `70d0b1ff`, `8cc379b5`, `9e551d29`, and `1ee524f7` add
`compression.checkpoint_required`. When true, Hermes requires an active memory
provider advertising checkpoint API v2 and a successful durable checkpoint
before lossy compression. Missing capability or failure returns
`BLOCKED_MISSING_PREREQUISITE` and preserves the uncompressed transcript. The
gate suppresses native Responses compaction and post-turn micro-compaction and
rejects Codex app-server mode, where Hermes cannot control the real boundary.

Talaria has no control or capability proof for this setting. Required slice:
decode/preserve the raw setting, expose a guarded toggle only alongside an
authoritative checkpoint-capable provider, and present the blocked prerequisite
as a recoverable configuration state rather than a gateway disconnect.

### 3. Pluggable terminal environments and shared Docker identity — open management

Commit `04849107` replaces static terminal-backend enumeration with a plugin
registry and makes the REST backend list dynamic. Commits `15f7b729` and
`7a67bd07..d736f5d5` make persistent Docker containers profile-scoped and add
optional shared-container keys with collision-resistant identity labels.

Talaria has no dynamic terminal-backend administration contract. Required
slice: consume the gateway's live backend rows/status, select only an admitted
backend through the guarded API, represent setup/unavailable states, and
preserve profile/shared container identity. The phone must not attempt to load
host terminal plugins locally.

### 4. MCP catalog and include/exclude semantics — open management

The range adds a large curated remote-MCP catalog and `tools.default_excluded`,
including glob filters. Reinstall now preserves the user's include or exclude
mode; `tools.include: []` means an explicit empty whitelist; a failed probe
retains the prior filter; and exclude-mode UIs must not freeze a dynamic server
surface into a stale include list.

Talaria's existing `mcp.catalog` consumption automatically gains the new rows,
so the catalog additions need no static iOS copy. Its management surface does
not expose lossless per-server tool filters. Required slice: round-trip include
and exclude modes distinctly, preserve glob patterns and explicit empty lists,
and never clear a filter because a probe or reinstall was inconclusive.

### 5. Web/browser caching controls — open management

Commits `04603fc0..ba9fc55e` add TTL caches for `web_search` and `web_extract`,
successful-result single-flight behavior, and `web.cache_enabled`,
`web.cache_ttl_minutes`, and `web.cache_exempt_hosts`. Commit `6ce7ab8b` adds
`browser.snapshot_threshold`. Commit `a75ea37d` removes the
`auxiliary.web_extract` model slot and makes extracts/snapshots use bounded
truncate-and-store artifacts instead of LLM summaries.

Talaria's generic web-search/tool/artifact presentation remains wire-compatible,
including unknown `cached` metadata. Required management slice: bounded,
validated controls for the four live configuration fields, preserving unknown
values and host patterns. Auxiliary-model administration must not reintroduce
the removed `web_extract` slot.

## Portable changes with no new iOS wire

- OpenRouter `:nitro` and `:floor` variants now pass Hermes model validation.
  Talaria already consumes gateway `model.options`; certify those variants but
  do not add a static catalog.
- Signal chunks long cron and standalone messages; Telegram waits through a
  reconnect; Teams avoids an unbound SDK; MCP, LSP, terminal-child, and
  computer-use sessions recover more cleanly. These are gateway/runtime fixes.
- Computer-use MEDIA paths are repaired across direct, Docker, and sibling
  delivery surfaces. Talaria's existing media directive and artifact paths
  remain the client contract.
- Fallback transitions and primary recovery become visible in ordinary runtime
  status; approval guard tails add machine-readable outcome values. Neither
  changes the approval request/response RPC consumed by Talaria.
- OpenViking identity, skill review marks, memory toolset gating, background
  review handshakes, browser storage hardening, and browser/Codex networking are
  server-owned behavior.
- Removed FLUX 3 promotional core tools and the expanded MCP catalog are
  discovered dynamically; a mobile client must not keep stale hard-coded rows.

## True Desktop-only changes

The Electron/backend claim sentinel consumer, Hyprland HUD behavior, HUD glass
and enumeration diagnostics, global composer focus chord, modal context-menu
containment, native paste and UI-scale behavior, vibe-heart preference,
multi-tab embedded browser, Desktop preview state, and settled-turn scroll
behavior are local UI/windowing implementation. Talaria may use mobile-native
navigation and presentation; it must not imitate Electron window APIs.

The pending-clarify Desktop fixes are renderer-local implementations of a
portable behavior Talaria already owns: resume/activate rebuilds prompt state
from `pending_clarify`, Stop demotes unresolved cards, and a later snapshot can
re-arm them. Existing Talaria room/single-session recovery remains the mobile
equivalent; retain a live stop/resume/re-arm case during certification.

## Pin decision

Implementation follow-ups now exist for every material slice, but none changes
the pin decision until its exact head is independently reviewed, merged in
dependency order, and certified against the exact gateway:

| Slice | Review PR | Exact review head |
|---|---:|---|
| Lossless gateway event replay | #100 | `415267da3cefed759b9bfcca49dfc9a522c6e8c1` |
| Checkpoint-v2 management compatibility | #101 | `15a4b5f14690c723ff1bbdf5ef5ee965c9bb1c04` |
| MCP include/exclude semantics | #102 | `9dd943dd5cf5578d454a59540dffac8930e7ea22` |
| Web/browser cache management | #103 | `60f808c20ca4f278c00d92578498f775006e933c` |
| Dynamic terminal/shared Docker management | #104 | `2709ef68170ae103b74c855494dd889f04cbe736` |

PR #73 remains the dependency for replay. Exact-head CI or automated review on
an earlier SHA is not approval for a later SHA.

**Do not move the canonical pin.** Keep
`057dcdf236f8a6a26721c10fcc6ccb72726e272a` authoritative. The authority guide
edit is Desktop-only, but the range contains one new client wire contract and
four portable management deltas that are not implemented or certified at the
Talaria audit base. After those slices land in dependency order, rerun this
exact checker, certify reconnect replay and the management mutations against
an exact `1bbb6e5` gateway, then issue a separate repin PR with refreshed
authority hashes. A moving upstream HEAD is not permission to skip that gate.

## Reproduction

```bash
python3 scripts/check_hermes_delta_057dcdf_1bbb6e5.py
python3 scripts/check_hermes_delta_057dcdf_1bbb6e5.py \
  --checkout /path/to/exact/hermes-1bbb6e5
python3 -m unittest scripts/test_check_hermes_delta_057dcdf_1bbb6e5.py
```
