# Hermes authority-file delta: `40643cba..057dcdf23`

This is the bounded authority-file slice of the larger current-Hermes audit.
It did **not** independently move Talaria's canonical upstream pin. The later
seven-ledger full-range closure gives the other production scopes the same
explicit treatment and authorizes the canonical move to `057dcdf23`.

The machine ledger is
[`parity/hermes-authority-delta-40643cba-057dcdf.tsv`](../parity/hermes-authority-delta-40643cba-057dcdf.tsv),
with endpoint and hash metadata in
[`parity/hermes-authority-delta-40643cba-057dcdf.json`](../parity/hermes-authority-delta-40643cba-057dcdf.json).
It contains exactly one row for each of the 63 unique commits reachable in
`40643cbaf9b767af146694131ffb8f8160f25e1c..057dcdf236f8a6a26721c10fcc6ccb72726e272a`
that touches at least one of Talaria's five authority files. Paths are the
exact union for that commit. Every row records a semantic cluster, portable
contract, Talaria evidence/disposition, and required implementation or proof.

Run the static and exact-checkout gates with:

```sh
python3 scripts/check_hermes_authority_delta.py
python3 scripts/check_hermes_authority_delta.py --checkout /exact/hermes-agent
python3 -m unittest scripts/test_check_hermes_authority_delta.py
```

The checkout gate derives the commit/path set from Git, rejects missing,
duplicate, extra, or path-mismatched rows, and recomputes both endpoint hashes
for every authority file. This makes later edits fail closed instead of
turning a prose claim into an unaudited repin.

## Exact authority hashes

| Authority file | `40643cba` | `057dcdf23` | Result |
|---|---|---|---|
| `apps/desktop/src/plugins/hermes-bots/plugin.js` | `738e108f12134bf651b9e43a795d87c6b24dd0bd3c2e0da1e533b1912fb2783e` | `a26cebc5e3b76096f288f0ad2a30f66550894b2c33bcc2a2fca0c5d12b5094b1` | changed |
| `website/docs/user-guide/bot-mode.md` | `3b614687a88c6da3213fcaef6f6a0d1a801a2bfed4407c36c5666b6d588d4e97` | `43136a19bd8ec6766083f6fec49b924d0b42a1c6e9736ebd865cae97017c0915` | changed |
| `website/docs/user-guide/desktop.md` | `0d69317f4b78160b5f747acbca8267e4a8025ebd2153d1c2e133d8b85d0e3e9c` | `889b20baf56abe60ee7dd79e019b2314854a9bb737939e81b51a779d41e1eb3a` | changed |
| `website/docs/user-guide/multi-connection-desktop.md` | `ef5cb45bee0ace82bcad61f8a94db00ea6ec95bc56218b434ed7e28bd09ec422` | same | unchanged |
| `apps/desktop/DESIGN.md` | `5967f00ea0b44928c6f88736658e9d3d2bf6ad9fdd790cb3fa635910c5d1c27d` | same | unchanged |

## Semantic disposition

The ledger deliberately classifies outcomes, not commit-title prefixes.
Intermediate and merge commits remain explicit rows so a future checker cannot
hide them behind a final tree diff.

| Cluster | Commits | Portable contract and disposition |
|---|---:|---|
| C01 canonical routing | 11 | Remote actions bind their exact connection; canonical Bot Chat identity is title/lineage based, persisted before use, resumes its resolved tip, and fails closed. Talaria implements the source-qualified lease and needs the retained two-gateway/ambiguity/interruption live matrix. One intermediate last-conversation rule is explicitly superseded; three merge integrations add no independent client feature. |
| C02 A2A and cron | 7 | `message_agent` owns structured Bot-Chat-only delivery, cross-connection attribution remains source-qualified, and cron Bot Chat delivery is gateway-owned. Talaria implements the client boundary and presentation; retry/compression, typed failure delivery, cron execution, and final delivery require live gateway proof. |
| C03 roster ownership | 8 | Global roster rows, aliases, Bot surfaces, refresh failures, and wake/reconnect behavior preserve owner routes rather than ambient connection state. Talaria's union roster and pool/profile lifecycle leases implement this; multi-gateway lifecycle proof remains open. |
| C04 room lifecycle | 11 | Durable room ids/tombstones, rename identity, orphan/frozen seats, strict action routing, connection deletion, and disband cleanup are portable and implemented with automated evidence plus live convergence still open. Desktop IME Enter handling is platform-only. **One product gap was found:** Talaria's `RoomComposer` draft is view-local and is not retained per room. |
| C05 attention and relay | 7 | Portable attention/unread outcomes exist in Talaria. Desktop's local relay-drain socket/push scheduler is correctly classified Desktop-only because iOS consumes gateway events/native push rather than hosting that process. Notification race/deduplication remains live proof, not a request to port the drain loop. |
| C06 room-turn consistency | 6 | Stable entry anchors, deduplication, fail-closed resume, and retained socket authority exist. **One product gap was found:** Talaria has no explicit, durable, source-qualified per-member stop/hold and resume contract; the upstream sticky-stop behavior therefore needs a separate runtime PR. |
| C07 Desktop shell | 7 | Hover-close, home re-fronting, Linux/Wayland/X11 HUD behavior, and Electron tab handling are true Desktop-only behavior. Mobile routine/chat navigation already supplies the portable selection outcome. The Bot-profile session cleanup is not merely shell chrome: its five-minute, timestamp-fail-closed grace protects real gateway rows, and Talaria lacks that bounded fallback sweep. |
| C08 failed turns and diagnostics | 6 | Typed layer/error identity, classifier-gated exact-session retry, bounded copy, and consented private diagnostics are implemented with automated evidence and remaining device/live proof. The temporary Portal support link and its revert are both retained as superseded rows. |

Counts sum to 63. No row uses an authority hash as evidence of runtime
certification: automated Talaria evidence and remaining physical
gateway/device proof are stated separately.

## New product gaps (separate runtime work)

This audit changes no product source.

1. **Per-room composer drafts.** `RoomComposer` owns `draft` and attachments in
   SwiftUI `@State`, so switching or reconstructing a room discards unsent
   work. A runtime PR should add a bounded store keyed by durable `RoomID`,
   preserve drafts across rename, purge them on room deletion/privacy reset,
   and define attachment-byte ownership explicitly.
2. **Sticky member stop/resume.** Talaria's room drive has concurrency gates and
   fail-closed recovery, but no user-visible exact-member hold/resume state.
   A runtime PR must bind the hold to room id, source-qualified member route,
   thread/epoch and profile/pool generation; stopping one member must not stop
   peers, and reconnect must not silently clear the hold.
3. **Bounded stale Bot-session reconciliation.** Talaria hides canonical and
   room sessions whose ids it already owns, but does not enumerate a bot
   profile's visible sessions to reconcile otherwise orphaned `Bot Chat`/room
   plumbing. A separate runtime PR must use an exact source-qualified profile,
   a bounded session inventory, and upstream's five-minute grace. Missing,
   malformed, millisecond, or future creation timestamps must remain visible;
   only proven old plumbing may receive `session.set_hidden`.

These are portable gaps, not reasons to weaken the checker or repin early.

## Relationship to existing audits

[`HERMES-CURRENT-AUDIT.md`](HERMES-CURRENT-AUDIT.md) remains authoritative for
the targeted webhook, profile-transfer, learned-memory, auxiliary-model, MoA,
relay-deployment, shared-room CAS/projection, and certification analyses.
Those targeted snapshots are cross-referenced by the evidence column where
they genuinely overlap; they are not claimed to disposition unrelated Bot
Mode or Desktop-guide commits. This ledger closes only the five-file authority
slice. The complete production-range proof and canonical repin are owned by
[`HERMES-FULL-RANGE-CLOSURE-40643CBA-057DCDF.md`](HERMES-FULL-RANGE-CLOSURE-40643CBA-057DCDF.md),
not by this component in isolation.
