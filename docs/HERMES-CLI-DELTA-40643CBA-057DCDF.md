# Hermes non-web CLI delta: `40643cba..057dcdf`

This is the machine-checkable Talaria parity inventory for production changes
under `hermes_cli/**` in the exact Hermes range
`40643cbaf9b767af146694131ffb8f8160f25e1c..057dcdf236f8a6a26721c10fcc6ccb72726e272a`.
The canonical evidence is the [TSV inventory](../parity/hermes-cli-delta-40643cba-057dcdf.tsv),
its [JSON manifest](../parity/hermes-cli-delta-40643cba-057dcdf.json), and the
[checker](../scripts/check_hermes_cli_delta.py).

The checker is intentionally not a first-parent log. For every reachable
commit it takes the union of `git diff --name-only <parent> <commit> --
hermes_cli` for every parent, then applies the stated scope rules. It verifies
the complete 167-row commit inventory, 30 merge rows, every row's parent-union
paths, 43 pinned predecessor references, and SHA-256 blobs for all 50
base-to-target final-net files.

## Scope and accounting

Excluded paths are `hermes_cli/web_server.py`, `hermes_cli/web_routers/**`,
test paths, and static/generated paths. The raw non-web history union has 126
paths. Two merge-only generated artifacts are intentionally removed from the
production inventory:

- `hermes_cli/data/plugin_index.json`
- `hermes_cli/observability/schemas/hermes.shared_metrics.v2.schema.json`

The resulting production union is **124 paths**, across **167 commits**.
`scopeCorrection` in the manifest preserves both counts and the exact excluded
artifact names so an accidental broadening or narrowing fails closed.

## Cross-reference partition

Unlike a successor-only ledger, this TSV retains every exact CLI commit and
places predecessor evidence in its `predecessors` column. That makes an
overlapping upstream commit auditable while permitting a CLI-specific
disposition where necessary.

| Pinned predecessor | Head | Referenced CLI commits |
| --- | --- | ---: |
| PR85 authority | `879078e3ef54d1af2d6e0208105c0cf93c71979c` | 6 |
| PR90 client-wire | `69d066bd3c213b8de69fa78735f20327f05f7123` | 17 |
| PR93 core-runtime | `7e46a9ab4e68f4f74ecc68fe2222798883a66091` | 20 |

The checker reads the predecessor TSV from each immutable head and requires
the exact `ledger:cluster` reference for every overlapping commit. It rejects
an omitted, stale, or ambiguous reference.

## Dispositions

Most update/launcher, service-manager, provider-routing, credential, plugin,
dashboard, curses, setup, skills-curation, and local diagnostic changes remain
host CLI or Desktop behavior. Dynamic provider/model data continues to be
consumed through the existing authenticated `model.options` catalog; Talaria
does not get a static provider-routing table or a phone credential mutation
surface from this range.

`a2da0ab797edf5e7ca7d3f64591facbbc37ec7f2` (bot-chat cron delivery) is
already portable through Talaria's generic delivery-target handling. It keeps
its PR85 predecessor reference and needs live proof, not a new iOS mutation.

The durable host-update recovery subset is explicitly recorded as
`covered-by-pr91-excluded`. PR91 is
`cc3322f674ac388c55a9d2694efaaf7e941a1666`; this ledger does not duplicate
its bounded receipt/status design or authorize a mobile restart/update path.
Raw `hermes update --plan` inventory is still host-local and unbounded for
mobile purposes.

### One-shot cron re-arm: blocked upstream contract

`a0ca7c19204e514f9590ce3b812e029b315ab9e9` adds explicit CLI re-arm through
`hermes_cli/console_engine.py::_cron_resume`,
`hermes_cli/cron.py::cron_resume`, and `hermes_cli/subcommands/cron.py`.
The target runtime has `cron.jobs::rearm_oneshot`, but `cron.manage` admits
only `remove`, `pause`, and `resume`; REST has no re-arm verb, and
`update_job` rejects terminal activation. This ledger intentionally overrides
the broader PR93 cron predecessor disposition for this CLI-specific action.

No Talaria mutation is authorized until upstream provides a bounded,
authenticated, profile-scoped re-arm contract with:

- a canonical immutable job ID;
- mutually exclusive server-now or bounded ISO `run_at` grammar;
- server-side one-shot and live-claim checks;
- canonical resolved-profile/job postcondition; and
- revision or mutation receipt semantics for uncertain requests.

Only after that authority exists is
`codex/current-hermes-cron-push-isolation@28e9f713e4aa46fc78fbaa1ef19abf0892ff3c8e`
a suitable narrow mobile dependency base.

### PR94 model presentation: local, unmerged, uncertified

The manifest records local-only PR94 commit
`ff0ea1a6e91c3af0996f406dac0acf9f607cc166`, based on
`27a12f11c3825cc8ada4860b60e298acdcc4fa37`. It covers:

- `1bf8bd2c7d2057de4fdf80236b0b017f7d7097e4` — search-only
  `x-preview-f-free → ox-alpha, ox` aliases; and
- `bd93a5f3160dc84d1891e27b49bffeb88483d8f0` — existing
  `discount_percent` presentation debt, including free Nous `-100%` rows.

The alias never changes display, identity, provider ownership, availability,
or routing. Discount rendering is read-only and limited to finite integral
`1...100` values. The discount gap is pre-existing PARITY.md row 390 /
pre-range `649472f`, not a newly claimed `057dcdf` wire contract. PR94 is
explicitly **not merged or certified**.

## Verification

Run from the Talaria checkout containing this ledger:

```sh
python3 scripts/check_hermes_cli_delta.py \
  --checkout /Users/joshua/talaria/hermes-agent-upstream
python3 scripts/test_check_hermes_cli_delta.py
```

The first command verifies exact endpoint commits, every-parent history,
predecessor source rows, final-net hashes, critical source assertions, and the
PR91/PR94 local reference parents. The test suite mutates fixture metadata and
rows to prove scope, classification, reference, and hash drift fail closed.
