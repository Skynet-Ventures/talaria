# Hermes Desktop/Electron delta: `40643cba..057dcdf`

This is the machine-checkable, mobile-parity disposition for the Hermes
Desktop renderer and Electron production delta. The canonical inventory is the
[TSV](../parity/hermes-desktop-delta-40643cba-057dcdf.tsv); its full path,
endpoint-hash, predecessor, and slice manifest is the
[JSON](../parity/hermes-desktop-delta-40643cba-057dcdf.json). The checker
rejects a first-parent-only inventory, path omissions, duplicate commits,
predecessor intersection drift, endpoint-tree/blob drift, and a changed
classification/disposition policy.

## Boundary and method

The upstream input is exactly:

```
40643cbaf9b767af146694131ffb8f8160f25e1c..057dcdf236f8a6a26721c10fcc6ccb72726e272a
```

The only scoped roots are `apps/desktop/src/**` and
`apps/desktop/electron/**`. For every reachable commit, the inventory compares
the commit to **every parent** and unions the changed paths:

```
git diff --name-only <parent> <commit> -- apps/desktop/src apps/desktop/electron
```

That produces 241 scoped commits, including 34 merge commits. The historical
union is 1,072 paths; the final net tree is separately checked at the two
endpoints and contains 345 changed paths. The path classification is evidence,
not a feature claim:

| Historical path kind | Count | Final-net count |
| --- | ---: | ---: |
| Production renderer/runtime | 561 | 161 |
| Test, fixture, or generated test support | 498 | 175 |
| Locale | 7 | 6 |
| Style | 3 | 2 |
| Build/type support | 3 | 1 |

The endpoint subtree IDs are:

| Subtree | Base | Target |
| --- | --- | --- |
| `apps/desktop/src` | `d29f91347a7645d0a29aa80d887a0eb6b5c3af78` | `e91c8525ca176ef0874d423c0d0df80b843e1a6d` |
| `apps/desktop/electron` | `901e99e9b9460500847fca95d15fd91b6e5a82f8` | `0490b6a1f2d5b25abb0fb26f7f0b42e31ba6cef0` |

The JSON assigns a machine-checked kind to every one of the 1,072 historical
paths and holds SHA-256 hashes for every one of the 345 final-net files. A few
useful Git-blob endpoint witnesses are `lib/model-search-text.ts`
`5cbe59d3… → 2717e7aa…`, `components/model-picker.tsx`
`b835b6d8… → 4f5415f9…`, `store/native-notifications.ts`
`3e7e1c8c… → 09edafc2…`, `store/updates.ts`
`476354e1… → f6e977f9…`, and `electron/gateway-file-download.ts`
`acdca972… → 40fa98ce…`.

## Exact predecessor partition

Desktop commits overlap existing ledgers, so the TSV retains all 241 commits
and names exact predecessor ownership in its `predecessors` column rather than
duplicating a portable slice. The checker reads the predecessor TSV/metadata
from their pinned commits, not from the working tree.

| Predecessor ledger | Pinned Talaria head | Desktop intersections |
| --- | --- | ---: |
| Authority / PR85 | `879078e3ef54d1af2d6e0208105c0cf93c71979c` | 60 |
| Client wire / PR90 | `69d066bd3c213b8de69fa78735f20327f05f7123` | 14 |
| Core runtime | `7e46a9ab4e68f4f74ecc68fe2222798883a66091` | 27 |
| Union after exact overlap | — | 87 |

The exact non-duplicating predecessor combinations are 54 authority-only, 6
authority+core, 6 client-wire-only, 8 client-wire+core, and 13 core-only.
This leaves 154 Desktop-specific/non-predecessor commits for this ledger to
classify; it does not imply 154 mobile gaps.

## Mobile findings and narrow dependencies

| Cluster | Representative upstream commits and symbols | Disposition | Existing/open Talaria dependency |
| --- | --- | --- | --- |
| Notification identity, avatar, and source routing | `09047ec69` `store/native-notifications.ts::respondToApprovalAction`; `9c829f96`, `bb63e0c4` `plugin.js::drainRelayOutboxes` / `scheduleRelayPushDrain` | source-qualified predecessor coverage; Desktop relay drain itself is Desktop-only | authority PR85; PR95 exact review head `1b50d7969810c33582caaad5273b8e83520ad54d` (implementation `4a06df18e768fe4bb8a206dc86f1dce0a08feec6`) |
| Bot profile density, rooms, roster and source ownership | `b42d8279`, `0c474d78`, `1b18442f`, `c29c9d17` in `plugins/hermes-bots/plugin.js` | already owned by authority/current slices; no duplicate renderer port | `codex/current-hermes-compact-bot-profile` @ `44829a1b5193b363f1ab747a825487bff1d7bf75`; drafts `1d88002454ec70c06bc3aa60fa44248a1b848cfd`; holds `d27e7839aeb94fcf79438513b3f31da7306e1dbf`; stale-session reconciliation `23bf4e618a4b772bc2b7b6c4dc30f456d8ff14d0` |
| Steer-versus-queue, reconnect and gateway lifecycle | `53471925`, `11fd82cf`, `77dd0699` routed submit recovery; `17f8e24c`, `5ef205d8`, `e8d5660b` boot bounds; `febed060` wake reconnect | covered by source-qualified queue/recovery work, not an Electron copy | `codex/current-hermes-durable-composer-queue-v2` @ `ce5851f26bfc2853a37a18aac125d875a6316b34` |
| Update receipts | `b90289b0` `store/updates.ts::receiptProvesOutcome` / `finishBackendApply` | covered by the active host-recovery slice; no change to that implementation from this ledger | `codex/durable-host-update-recovery` @ `cc3322f674ac388c55a9d2694efaaf7e941a1666` |
| Transcript, tools and error presentation | `9f8dca34`, `40f3e58f`, `98f6fc54`, `334bcbac`, `02e270a4`, `bed7e975`; `lib/chat-messages`, `assistant-ui`, tool renderers | predecessor/current transcript work; `b614e265` is local lazy syntax-diff bundle handling only | rich transcript hydration `d5bad705f1c19d716eea4abb8de1ba4206659dde`; structured output `fdee839fdc1fda8a4a8233ff5e459795d09752b0`; diff renderer `f0d5aa814c3c6411419dfef2e00d9ff711d78a59` |
| Attachments, media, files and artifacts | `6eb77df1` media route, `0b62c27b` / `30150fd` / `9abeb89a` connection-scoped files; `use-project-tree.ts::loadRoot` / `revalidateTree`; `gateway-file-download.ts::resolveGatewayFileBackend` | remote mobile behavior is already sliced; local file streaming/worktrees stay Desktop host behavior | attachment picker `9f26348d576004d40da8b3f03c2cb6c93b4333c3`; artifact remote body `9591d177ec271b06a017c879b3b643d6c228c1a1` |
| Git/worktree/PR UI | `electron/git-worktree-ops.ts`, `lib/desktop-git.ts`, pane/tree UI | Desktop-local filesystem/process UI; no phone-host port | non-applicable; retain remote Git/artifact product backlog separately |
| HUD, transitions and motion | `3c196444`, `6e64e6b9`, `f33b260`, `67a5d7bc`, `433f518c`, `11f3ebe2`, `fab0de1c`, `b595fcd5`, `d467da91`, `81baae6b`, `3f590e68`, `db6c282c`, `b4849330`, `765e3a2f`, `73dcd75a` | Electron/HUD/compositor-only | no port; the mobile operational analogue remains `codex/current-hermes-live-activity-policy` @ `2b4dcd47df49e32e1d39c95a16ab9520033590bd` |

The TSV's policy is intentionally conservative: 58 entries are direct
predecessor cross-references, 18 are covered by a named open slice, 45 are
Desktop-only, 34 are merge-parent integration evidence, 18 are test/fixture
only, and 65 are renderer context with no new narrow mobile slice. The counts
are checked, not hand-maintained prose.

## The two actionable model-picker deltas

These are the only newly actionable, narrow mobile presentation gaps found in
the production Desktop delta:

| Upstream commit | Desktop source/symbol | Exact Talaria implementation | Status |
| --- | --- | --- | --- |
| `1bf8bd2c7d2057de4fdf80236b0b017f7d7097e4` | `apps/desktop/src/lib/model-search-text.ts::MODEL_SEARCH_ALIASES` / `modelSearchText`; `x-preview-f-free → ox-alpha, ox` | PR94 `ff0ea1a6e91c3af0996f406dac0acf9f607cc166`: `ModelLabels.searchText`, covered by `testCurrentHermesOxAlphaAliasIsSearchOnly` | Implemented on `codex/model-discount-presentation`; **not merged and not device/live-gateway certified** |
| `bd93a5f3160dc84d1891e27b49bffeb88483d8f0` | `apps/desktop/src/components/model-picker.tsx::ModelPrice`; free/sale `discount_percent` badge | PR94: `GatewayClient+Models.swift::ModelPriceTag.boundedDiscountPercent`, `ModelEffortSheet.swift::ModelPricePresentation`, settings-row presentation, bounded-parser tests | Implemented on `codex/model-discount-presentation`; **not merged and not device/live-gateway certified** |

PR94 deliberately preserves gateway ownership: catalog identity, display
identity, provider ownership, availability, and routing do not move to the
phone. Its contract tests reject non-finite, non-integral, out-of-range, and
malformed discount values; only an exact 1–100 percent marker renders.

## Desktop-only and existing-backlog distinctions

`1ad47333` per-profile Electron connection override/safe-storage, `10f0d227`
client-direct voice credentials, `beb84835` embedded browser pane, Desktop
worktree/file IPC, window translucency, HUD input/geometry, compositor spinners,
and desktop self-update shell mechanics are explicitly non-applicable to the
mobile runtime. They must not be reclassified as missing Swift code merely
because they appear in the Desktop range.

`0a171fffef0e50aef4b26718c484431f4247a4bb` is separately marked
`existing-backlog`: `store/goals.ts` derives state from slash-command prose and
uses `DONE_LINGER_MS`. A live session-scoped mobile status stack is broader than
this timer and needs a typed gateway contract, so this commit does not justify a
new narrow port. Existing PARITY.md backlog also remains the home for richer
media/transcript cards, deeper artifacts pagination/unlocked roots, and the
larger provider/onboarding/settings surface; those are not claimed as newly
introduced by this range.

## Reproduce

```sh
python3 scripts/check_hermes_desktop_delta.py
python3 scripts/check_hermes_desktop_delta.py \
  --checkout /Users/joshua/talaria/hermes-agent-upstream
python3 -m unittest scripts/test_check_hermes_desktop_delta.py -v
make verify
```

The exact-checkout command verifies every parent-path union, all 1,072 scoped
paths, the 345 final-net SHA-256 pairs, endpoint subtree IDs, pinned
predecessor ledgers, source assertions, and the recorded open-slice/PR94 refs.
