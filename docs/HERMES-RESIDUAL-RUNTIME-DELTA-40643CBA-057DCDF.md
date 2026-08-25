# Hermes residual runtime delta: `40643cba..057dcdf`

This is the final non-overlapping production inventory for the exact Hermes
upstream range `40643cbaf9b767af146694131ffb8f8160f25e1c..057dcdf236f8a6a26721c10fcc6ccb72726e272a`.
It is deliberately an every-parent audit: each merge records the union of its
diff against every parent, not just first-parent history.

The machine-readable source of truth is
[`parity/hermes-residual-runtime-delta-40643cba-057dcdf.json`](../parity/hermes-residual-runtime-delta-40643cba-057dcdf.json),
with one auditable commit/path row in
[`parity/hermes-residual-runtime-delta-40643cba-057dcdf.tsv`](../parity/hermes-residual-runtime-delta-40643cba-057dcdf.tsv).

## Result

There are 201 residual production commits (34 merges), 303 distinct
every-parent history paths, and 67 endpoint net-change paths. The history-path
union SHA-256 is
`fe0d4ee4fc13e10790cf1e46794b3f4e7d7742245646faf37a3fb1d9fcc78ab9`.

| Classification | Commits | Disposition |
| --- | ---: | --- |
| Portable already covered | 56 | 27 predecessor-covered, 26 live dynamic catalog, 2 heartbeat slice, 1 PR94 parent-merged/not-main/uncertified |
| Upstream-contract-blocked | 5 | Do not implement a phone mutation |
| Other-client-only | 27 | Dashboard, TUI, ACP, installer, browser/voice controller, or third-party platform adapter |
| Host-only | 79 | Hermes runtime, state, plugin/provider, tool, scheduler, security, or local process behavior |
| Merge integration | 34 | Literal every-parent topology/accounting row |
| Portable gap | 0 | No actionable authority-backed mobile gap found |

The five blocked rows are intentional, visible findings rather than host-only
catch-alls: `a0ca7c1` is one-shot rearm; `65c5865` is the auxiliary review
slot; and `97850af`, `497d6d5`, and `32fb12a` are learned-memory provider
changes whose management surface remains unsafe.

## Scope subtraction and exclusions

The residual includes executable source under `agent/`, `cron/`, `tools/`,
`plugins/`, `ui-tui/`, `web/`, `acp_adapter/`, non-Desktop `apps/`,
`providers/`, and top-level runtime Python files such as `cli.py`,
`batch_runner.py`, and `hermes_state*.py`.

It subtracts the already-owned authority files, client-wire roots
(`tui_gateway/**` and Hermes CLI web wire), the exact 30 PR93 core-runtime
paths, `apps/desktop/**`, `hermes_cli/**`, and `gateway/**`. This leaves no
double-counted Desktop, CLI, gateway/platform, client-wire, authority, or
core-runtime production path.

Tests/fixtures are excluded as verification material; docs/locales as
non-runtime prose; styles/assets/static/generated media as non-executable
presentation; build/config/lock files as metadata rather than independently
portable contracts; and non-source/out-of-root files to keep the inventory
bounded. The JSON records the exact rule and reason for each exclusion class;
the checker rejects scope drift.

## Portable conclusions

`1bf8bd2c7d2057de4fdf80236b0b017f7d7097e4` adds the exact search aliases
`x-preview-f-free -> ox-alpha, ox` to the dashboard/TUI pickers. It is covered
by PR94 implementation
`ff0ea1a6e91c3af0996f406dac0acf9f607cc166`, now merged into parent branch
`codex/model-contract-copy` as `5cb68d2dd38539b2f5de789e7be95a545437ca22`.
PR94 is not in `main` or device/live-gateway certified. Its bounded discount hint
also closes pre-existing presentation debt from pre-range `649472f` / PARITY
row 390, not a newly introduced `057dcdf` wire contract.

`9153be2a5126f8280839a58d143ddcf80afc6d12` and
`e3f695e5e00ef8718d8829fbe44fd3d2e36ed236` add shared/TUI heartbeat and
reconnect behavior. The narrow existing Talaria basis is
`codex/gateway-heartbeat@e5abb0fae3ca84757631f835495fa1f15bfda016`; it adds
bounded heartbeat/foreground validation, monitors early initial adoption, retires superseded transports, and
lets exact-current authenticated inbound traffic reconcile a stale offline
publication. Its full 1,111 XCTest + 39 Swift Testing suite and
`talaria-verify` pass and its corrected signed build succeeds; installation
and lock/return proof remain open. It remains a transport slice, not a mutation authority.

Compaction, canonical session state, and Bot Chat/A2A result projections are
already consumed through pinned client-wire/authority contracts and current
Talaria rich-transcript and message-agent projection heads. Provider/catalog
changes are read from gateway-declared `model.options`; no static provider
table, provider credential write, or routing inference is justified. MCP and
skills residual changes remain host tool/capability behavior; the existing
`codex/mcp-live-reload@9851fca979f40b08df283855de290de4e3f04568` context does
not create broader mobile MCP configuration authority.

## Explicit blockers

`a0ca7c19204e514f9590ce3b812e029b315ab9e9` adds
`cron.jobs.rearm_oneshot`, but target `tui_gateway/methods_tools.py` admits
only `remove`, `pause`, and `resume` for `cron.manage`; neither it nor the
dashboard REST host exposes `rearm_oneshot`. A phone rearm operation therefore
needs Hermes to provide an authenticated profile-scoped canonical-job action,
with exactly one server-now or bounded ISO `run_at`, server-side one-shot and
live-claim checks, canonical job/profile postcondition, and revision or
mutation receipt. Only then should a narrow slice use
`codex/current-hermes-cron-push-isolation@28e9f713e4aa46fc78fbaa1ef19abf0892ff3c8e`.

`65c58651b0e34ab3d2c25b7024609ef9c7b7ffef` labels the `review` auxiliary slot
in the dashboard. It does not make auxiliary model/config writes safe for a
phone. The exact blocker is recorded by
`codex/auxiliary-model-administration@ebc1c577887c1f98e992a9900cbb43a4f95fe6e9`:
mobile needs a bounded profile-scoped snapshot/options contract, write-only
credentials and clear facts, expected-revision mutations with 409 plus a
canonical postcondition, finite field bounds, and a refresh/change contract.

The residual Hindsight timestamp commits are likewise not learned-memory
management authority. The current graph/detail/edit/delete/import/export
surface remains unbounded and unrevisioned. It needs immutable IDs/revisions,
bounded secret-safe detail, revisioned mutations, bounded prepare/commit
import/export, and an explicit refresh/change contract before mobile work.

## Predecessor evidence

Pinned predecessors are PR85 authority
`879078e3ef54d1af2d6e0208105c0cf93c71979c`, PR90 client-wire
`69d066bd3c213b8de69fa78735f20327f05f7123`, and PR93 core-runtime
`7e46a9ab4e68f4f74ecc68fe2222798883a66091`. The audit also records all
intersections with the three current, uncommitted closure manifests: Desktop
(TSV SHA-256 `9dd0832633b57697e43c97ce456a602f4b38f9f6073cf7807aba92654d6c16e4`),
CLI (`3c34e6b9daa562b29571fcf63687c4bcb9336edbcb8c0106fc3fa40db3986e85`),
and gateway/platform
(`7d82ecd09a4e5e4dc4f281f5daa7446326636908f63d1c40989806c1655d5d5b`).

Their exact intersections are 9 authority, 31 client-wire, 30 core-runtime,
35 Desktop-current, 57 CLI-current, and 9 gateway/platform-current references
(171 total; multiple predecessor references on a commit are intentional).

## Verification

Run:

```bash
python3 scripts/check_hermes_residual_runtime_delta.py \
  --checkout /Users/joshua/talaria/hermes-agent-upstream
python3 scripts/test_check_hermes_residual_runtime_delta.py
```

The checker recomputes the every-parent union, final-net and nine critical
endpoint hashes, predecessor intersections, scope/exclusion behavior, source
presence/absence assertions, and Talaria reference parents. The test suite
contains deterministic metadata/TSV/source/predecessor corruption cases.
