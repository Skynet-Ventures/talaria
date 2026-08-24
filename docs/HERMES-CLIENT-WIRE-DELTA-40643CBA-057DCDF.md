# Hermes client-wire delta, `40643cba..057dcdf23`

This is the bounded client-wire companion to the five-file authority ledger.
It audits every unique commit in the exact Hermes range
`40643cbaf9b767af146694131ffb8f8160f25e1c..057dcdf236f8a6a26721c10fcc6ccb72726e272a`
that touches production `tui_gateway/**`, `hermes_cli/web_routers/**`, or
`hermes_cli/web_server.py`. It does **not** repin
[`parity/hermes-upstream.json`](../parity/hermes-upstream.json), claim coverage
of files outside this scope, or certify retained live-proof rows.

The machine-readable inventory is split deliberately:

- 71 unique commits touch this scope.
- 7 also occur in the existing five-file authority ledger and are referenced
  there rather than counted twice.
- The remaining 64 commits appear exactly once in
  [`parity/hermes-client-wire-delta-40643cba-057dcdf.tsv`](../parity/hermes-client-wire-delta-40643cba-057dcdf.tsv).
- History across all merge parents touches 22 production paths. The exact
  endpoint tree has 12 net-changed paths, `+2,798/-418`. Endpoint SHA-256
  hashes, including explicit absent files, are retained in
  [`parity/hermes-client-wire-delta-40643cba-057dcdf.json`](../parity/hermes-client-wire-delta-40643cba-057dcdf.json).

Each TSV row records the exact commit, all scoped paths changed against any
parent, semantic cluster, disposition, request/response/event/security impact,
portable contract, Talaria evidence, and required implementation or live
proof. Merge commits are inspected against every parent, so a path introduced
by either side cannot disappear from the audit merely because the merge's
first-parent diff is empty.

## Reproduce the partition

```sh
python3 scripts/check_hermes_client_wire_delta.py
python3 scripts/check_hermes_client_wire_delta.py \
  --checkout /path/to/hermes-agent
python3 -m unittest scripts/test_check_hermes_client_wire_delta.py
```

The exact-checkout mode derives the 71-commit inventory and path union from Git
objects, intersects it with the existing authority ledger, proves the
`64 + 7 = 71` partition, and verifies both endpoint blob hashes. It fails on a
missing or duplicate commit, endpoint/path drift, intersection drift, an
unknown disposition/impact, or a changed cluster count.

## Semantic clusters

| Cluster | New rows | Portable disposition |
|---|---:|---|
| W01 transcript rewind and response carriers | 13 | Exact row-id truncation and survivor consumption exist; optional survivor rebinding remains retained live proof, not a confirmed decoder gap. |
| W02 browser controller | 6 | Authenticated dashboard broker is local/Desktop administration; Talaria must not expose the host browser-controller capability. |
| W03 private diagnostics | 1 | Gateway-owned diagnostic hardening; no new mobile wire shape. |
| W04 session/profile correctness | 7 | Canonical/profile/source-qualified behavior is implemented; exact collision and lifecycle cases remain live proof where identified per row. |
| W05 bot relay delivery | 5 | Gateway-owned delivery and recovery, cross-referenced to the authority ledger where applicable; physical connector proof remains explicit. |
| W06 dashboard update/config | 11 | One portable update receipt gap is identified below; local dashboard configuration and host process controls are not copied to iOS. |
| W07 approval/review | 3 | Durable approval identity is wire-compatible and exact-source fenced in Talaria; reconnect/collision remains certification. |
| W08 client-direct voice | 1 | Desktop's provider-key response is intentionally not portable; Talaria keeps voice server-mediated. |
| W09 WebSocket/session lifecycle | 13 | Mostly gateway-owned lifecycle correctness; no guessed client authority. |
| W10 dashboard security | 3 | Browser origin/CSP/session hardening is dashboard-only and remains gateway-owned. |
| W11 application heartbeat | 1 | Implemented on open PR73, exact head `73ab2bc9884f7223964d43c7db68d1260f7356fa`; retain corrected-device sleep/Wi-Fi/socket-retirement proof and do not duplicate it here. |

The seven authority intersections are exact commits `8f30e9c7`, `98f6fc54`,
`9c829f96`, `a2da0ab7`, `a9860d41`, `b274b346`, and `d3e087fd`. Their wire paths
are still verified by this checker, while their semantic authority disposition
remains owned by
[`HERMES-AUTHORITY-DELTA-40643CBA-057DCDF.md`](HERMES-AUTHORITY-DELTA-40643CBA-057DCDF.md).

## Confirmed portable gap

Hermes dashboard update orchestration added a durable `action_id`/receipt that
can recover a successful host update after the initiating process restarts.
Talaria's current update status policy still requires the original process id
on every status response and does not admit the durable receipt as replacement
authority. A successful restart-crossing update can therefore be rejected as
stale even when the exact gateway reports the matching durable action.

This needs a separate runtime PR. It must bind the receipt to the exact gateway,
request, operation, profile/client/pool generation and expected update target;
bound every receipt/status response; revalidate after each await; reject
receipt collisions and old-generation completions; and prove restart recovery,
disconnect, timeout, malformed/oversized receipt, and same-id cross-gateway
cases. This audit makes no product change.

## Final-source findings that are not new gaps

- Current Hermes advertises and handles `gateway.ping`. Talaria heartbeat is
  already implemented on open PR73 at the exact head above, fully green but
  absent from this audit's PR85 base. Its disposition is
  `portable-implemented-open-pr-live-proof`.
- `approval.respond` retains durable request identity. Talaria already captures
  the exact request, gateway, runtime and durable target, so the remaining
  reconnect/collision work is certification rather than a client incompatibility.
- The transcript rewind response carries survivor row ids that Talaria consumes.
  The additional rebind map is optional for the current mobile contract; the
  composite-carrier case remains explicit live proof.
- Bot relay delivery, canonical recovery, scheduler execution and orphan
  cleanup are gateway-owned behaviors unless a row explicitly names a retained
  mobile proof.
- `/api/audio/voice-config` exposes provider configuration for Desktop's direct
  playback path. Pulling provider secrets to the phone would weaken Talaria's
  server-mediated voice boundary and is intentionally out of scope.

This ledger closes only the stated 22-path client-wire slice. The canonical pin
stayed at `40643cba` until the wider upstream range was independently complete;
the seven-ledger full-range closure now supplies that proof and owns the move
to `057dcdf23`.
