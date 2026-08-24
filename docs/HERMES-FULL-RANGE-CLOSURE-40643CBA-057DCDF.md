# Hermes full-range parity closure: `40643cba..057dcdf`

This is the master closure proof for the exact Hermes range
`40643cbaf9b767af146694131ffb8f8160f25e1c..057dcdf236f8a6a26721c10fcc6ccb72726e272a`.
It is the evidence that permits `parity/hermes-upstream.json` to move to
`057dcdf23`; no individual component ledger made that broader claim.

## Coverage

Seven fail-closed inventories cover the complete production range:

1. five designated authority files;
2. the authenticated client wire;
3. shared core runtime paths;
4. Desktop/Electron production code;
5. non-web CLI production code;
6. gateway/platform production code; and
7. the residual production tree after subtracting the preceding scopes.

Every component records exact endpoints, an every-parent commit/path inventory,
endpoint hashes where applicable, portable dispositions, predecessor
cross-references, and explicit exclusions. The residual ledger proves the
subtraction leaves zero undispositioned authority-backed portable gaps. The
master JSON pins both the metadata and TSV SHA-256 for all seven components so
an edit to any inventory invalidates the closure until it is re-reviewed.

“Zero undispositioned gaps” does **not** mean every item is merged or certified.
It means every production delta has a recorded outcome: implemented/covered,
open and awaiting merge or device proof, blocked on a named upstream contract,
host/other-client-only, merge integration, or explicit non-applicable Desktop
behavior.

## Portable work still open

- PR73 `73ab2bc9884f7223964d43c7db68d1260f7356fa`: heartbeat, foreground
  validation, replacement-transport retirement, and exact-current inbound
  recovery. Local suites pass; corrected physical-device installation and
  lock/return certification remain open.
- PR91 `cc3322f674ac388c55a9d2694efaaf7e941a1666`: durable host-update receipt
  recovery. Merge and disposable-host live proof remain open.
- PR94 `ff0ea1a6e91c3af0996f406dac0acf9f607cc166`: bounded discount presentation
  and Ox Alpha search aliases. Independent QA and CI are green, but its
  dependency chain and device proof remain open.
- PR95 review head `887de277b1ea9b9f2860b85e9e38b5fe8b2e8971`
  (implementation `4a06df18e768fe4bb8a206dc86f1dce0a08feec6`): exact-source push admission
  plus configured bot title/avatar presentation. Merge and device proof remain
  open.

These statuses are certification facts, not reasons to retain an older Hermes
source pin: the new pin says the source range has been audited and dispositioned.
Merge policy and device/live proof remain independently fail closed.

## Upstream-contract blockers

The new range retains three explicit blocker classes: one-shot cron re-arm;
learned-memory row/import/export management; and auxiliary-model/MoA
administration. Their component ledgers state the required bounded,
profile-qualified, revisioned contracts. The broader current audit continues
to own pre-existing blockers such as webhook administration, profile transfer,
relay deployment, and per-server MCP logs. Talaria must not invent mobile
mutation authority for any of them.

## Desktop/mobile disposition

Electron windowing, HUD/compositor geometry, translucency, native worktree/file
IPC, embedded browser panes, local process supervision, client-direct voice
credentials, safe-storage, and Desktop self-update shell mechanics are true
non-applicable host behaviors. Their mobile equivalents are existing iOS
navigation, Files/share boundaries, remote workspace/PTY contracts, APNs,
source-qualified gateway management, and narrowly scoped Live Activities—not
ports of Electron process or window APIs.

## Reproduce

```sh
python3 scripts/check_hermes_full_range_closure.py \
  --checkout /Users/joshua/talaria/hermes-agent-upstream
python3 -m unittest scripts/test_check_hermes_full_range_closure.py -v
python3 scripts/check_hermes_upstream.py \
  --checkout /Users/joshua/talaria/hermes-agent-upstream
```

The first command invokes all seven component checkers after validating the
master hashes. The final command separately proves the canonical target checkout
and its five authority-file hashes.
