# Current Hermes parity delta

This is the requirement ledger for Talaria baseline
`04695b91e8fe7cc59a8638e266b5b151c58144ab` against Hermes
`40643cbaf9b767af146694131ffb8f8160f25e1c`. It retains the audited move
from `b5455fdd16fe608214f91149233660e1836b067c` through
`9ef9b2d2d01eb4bcf9420973c5ef6c98f2176455` and
`c1e25cadffe539b058816be5fdfc9127d7199fa4`, records a disposition for every
commit through `18a15a46d81793f9bcbf7e9f4cd93d5db841b7ae`, and audits all 19
commits in the `18a15a46..efb6b40f` window and the bounded
`efb6b40f..40643cba` tree audit. It supplements the older
row-by-row ledgers; when they disagree, this exact-source delta is newer.

The authority hashes live in [`parity/hermes-upstream.json`](../parity/hermes-upstream.json).
The later five-file authority slice through `057dcdf23` is dispositioned
commit-by-commit in
[`HERMES-AUTHORITY-DELTA-40643CBA-057DCDF.md`](HERMES-AUTHORITY-DELTA-40643CBA-057DCDF.md).
That bounded ledger does not repin the canonical manifest or claim coverage of
the other 978 net-changed files in the complete range.
The independent production client-wire slice over `tui_gateway/**`,
`hermes_cli/web_routers/**`, and `hermes_cli/web_server.py` is dispositioned in
[`HERMES-CLIENT-WIRE-DELTA-40643CBA-057DCDF.md`](HERMES-CLIENT-WIRE-DELTA-40643CBA-057DCDF.md):
71 exact commits partition into 64 new ledger rows plus 7 authority-ledger
cross-references. It identifies durable restart-crossing update receipt
recovery as a separate runtime gap, and credits gateway heartbeat to open PR73
exact head `d1825fe8412a7ed6b6f4a430370545f0c8682bd4` rather than duplicating it.
That audit also remains too narrow to repin the canonical manifest.
An implementation row is not certified merely because it is checked below:
the evidence column names the remaining gateway or device proof explicitly.
The audit cutoff is the exact `40643cba` snapshot reviewed on 2026-08-20
(America/Los_Angeles). A later moving remote `HEAD` is a prompt for another
explicit audit, not a reason to silently repin or invalidate this reproducible
checkout and its hashes. Only an explicit audit that finds an authority-file
change or a material portable-contract delta creates a parity blocker;
metadata, test-only, or non-portable drift can be recorded without chasing the
moving head.

## Targeted webhook lifecycle audit at `e400e008`

Webhook administration was audited directly against exact Hermes source
`e400e0088767a596ee21985d661a924cb087775a`, with Talaria based beside the
final messaging-platform lifecycle head
`d38835ced5192fe2de314667a2a613e6713a7b38`. That is the correct dependency:
webhooks appear beside messaging in Desktop, but they use a separate admin
contract and must not inherit the safer profile-scoped messaging API by
association. The current webhook contract is **blocked for remote mobile
management**, so no phone transport, cache, polling loop, or mutation UI is
added.

Webhook subscriptions are profile-home scoped, not one process-global shared
store. `hermes_cli.webhook._subscriptions_path()` resolves
`webhook_subscriptions.json` beneath the active `get_hermes_home()`, and the
platform configuration is read and written through that active backend's
config. Desktop preserves this truth indirectly: its Electron main process
routes `/api/webhooks` requests to a retained or spawned backend for the
selected profile. That is a local process-routing mechanism, not a portable
remote gateway contract. The inbound receiver's
`/p/<profile>/webhooks/<route>` URL selects the agent profile for an incoming
event; it does not profile-scope the dashboard administration endpoints or
select a different subscription store.

All five admin operations in `hermes_cli/web_server.py` are unscoped:
`GET /api/webhooks`, `POST /api/webhooks/enable`, `POST /api/webhooks`,
`DELETE /api/webhooks/{name}`, and
`PUT /api/webhooks/{name}/enabled`. None accepts or echoes a resolved profile,
store revision, or route revision. A Talaria request therefore cannot prove
that the selected gateway/profile/client/generation still owns the returned
snapshot or mutation after an await. Adding an ignored `profile` query or body
field would not create authority.

The remaining safety gaps are independently blocking:

- the list and its nested events, skills, prompt, description, script, URL,
  target, and timestamp fields have no explicit collection, wire, or text
  bounds;
- create normalizes a caller-supplied name and unconditionally assigns
  `subs[name] = route`, silently replacing a concurrent/existing route and its
  secret instead of returning a conflict or requiring an expected revision;
- delivery targets and chat ids are free-form caller strings rather than ids
  admitted from an authoritative bounded target snapshot;
- create accepts executable `script` and external-delivery configuration in
  the same unfenced write, without a server-declared risk/capability contract;
- create returns the full HMAC secret. Reads redact it, but a safe phone flow
  requires a transient write-only credential and must never place a secret in
  model state, a toast, logs, retry state, or a response-derived display; and
- enabling calls `_restart_gateway_after_webhook_enable()` automatically.
  Its response reports restart initiation or failure only after the side
  effect, so Talaria cannot offer the required explicit, separately fenced
  maintenance decision and must not call it.

Toggle and delete do require a name that could be taken from a prior snapshot,
and subscription file replacement is atomic on disk, but neither fact closes
the missing profile/revision fence. There is also no exact-source
`webhooks.changed` event. Manual refresh would be the correct mobile freshness
model after a safe API exists; Desktop cache invalidation is not authority for
polling.

This row can resume only after Hermes provides bounded responses that echo the
canonical resolved profile and a store/route revision; exact profile-bearing
mutation bodies; conditional create/toggle/delete with conflict semantics;
server-declared delivery target ids and allowed fields; write-only secret
input with only `secret_set` returned; and enablement that reports
`pending_restart` without restarting. Talaria can then hold its captured pool
and profile-lifecycle leases across every REST await, revalidate the exact
gateway/profile/client/generation/route/revision, require confirmations for
delete or external delivery, and direct any restart through the existing
explicit maintenance fence.

## Targeted profile transfer and backup audit at `e400e008`

Profile duplicate/export/import and whole-Hermes backup were audited directly
against exact Hermes source
`e400e0088767a596ee21985d661a924cb087775a`. Talaria is based on
`d38835ced5192fe2de314667a2a613e6713a7b38`: this is the final current
management head, contains the complete profile-lifecycle serialization chain
through `f7e767989e36cb6670fbdf3be510525773c62b11`, and adds the latest leased
management traffic without changing profile-transfer authority. Basing on the
older profile feature commit would discard later lifecycle fencing.

The current wire does not justify a phone profile transfer flow. No import,
export, preview, Files/share integration, gateway restart, or live mutation is
added. The four superficially related operations have materially different
contracts:

### Duplicate

Talaria already implements Desktop's duplicate verb with gateway RPC
`profiles.create {name, clone_from, clone_all:true}`. Hermes rejects an
existing target, and copied credentials remain on the gateway rather than
crossing the phone. However the success payload echoes the requested `name`
and a host path; it does not return canonical source and target profile ids, a
profile/store revision, copied-field inventory, or a durable postcondition.
Credential mirroring also defaults on, while several model/MCP/skill/alias
follow-ups are best-effort. Current Talaria refreshes the roster and runs its
existing lifecycle activation, but a lost acknowledgement can still leave an
unreported created profile. This existing feature is not evidence that the
archive contracts are safe, and it should not be broadened or recertified as
transfer parity until Hermes returns canonical identities plus a mutation
receipt/revision that can be reconciled after ambiguity.

### Credential-free profile export/import

`POST /api/profiles/{name}/export` and `POST /api/profiles/import` exchange
**host filesystem paths, not archive bytes**. Desktop's native picker and its
local/pooled backend share one machine; an iPhone and a remote gateway do not.
Export has no authenticated download endpoint, byte length/hash/media receipt,
or resolved-profile echo. It accepts an arbitrary output path and arbitrary
extra text files. The exporter excludes `.env` and `auth.json` and force-
redacts recognized text files, but its own source notes that binary databases,
images, and other non-text artifacts in named profiles may still leave
unscrubbed. There is therefore no server assertion that an archive is safe to
share.

Import likewise accepts only a server-local path. Its extractor correctly
rejects traversal, links, multiple roots, `default`, and an existing target,
but it has no compressed-byte, expanded-byte, member-count, per-file, or text
bound; no manifest/preview or secret inventory; no dry-run token; and no
expected inventory revision. It moves the staged tree into place before
returning only `{name,path}` and an unbounded Desktop overlay. A phone cannot
preview what will be installed, prove the canonical target before mutation,
or reconcile a lost response without guessing.

### Whole-Hermes backup/restore

`POST /api/ops/backup` and `/api/ops/backup/download` are an existing Talaria
Command Center operator flow, not profile sharing. A full backup intentionally
contains `.env`, `auth.json`, `state.db`, and other restore credentials/state;
the contained files are permission-hardened on restore, not redacted for
sharing. The download is constrained to the active backend's backup directory,
and Talaria streams it under a client byte cap, but the API does not echo a
canonical profile/root, archive size/hash, secret classification, or backup
generation. It must never be offered as the substitute archive for a profile
share surface.

The general `/api/ops/import-upload` accepts at most 100 MiB of compressed ZIP
input, then spawns whole-root `hermes import`; `force=true` can overwrite the
running home after a Desktop confirmation. Its acknowledgement identifies a
background process, not the inspected contents, resolved root, revision, or
postcondition. It is destructive restore authority and is deliberately outside
this phone profile-transfer slice.

### Required portable contract

Mobile work can resume only when Hermes provides separate server-owned
prepare/commit contracts:

- export must accept and echo one canonical snapshot-declared profile id,
  produce an authenticated bounded byte download with size/hash/media type,
  and attest that credentials and unscreened binary state are absent;
- import must accept a bounded upload, enforce compressed/expanded/member/
  per-file/text limits, and return a bounded canonical manifest plus detected
  secret/risk facts without mutation;
- commit must consume an expiring prepare token, exact proposed target id and
  expected profile inventory revision, reject collisions with 409, never
  overwrite silently, and return a canonical revisioned postcondition;
- duplicate must return canonical source/target ids, explicit credential-copy
  policy and a reconcilable mutation receipt; and
- every stage must carry the profile in the request and response so Talaria can
  hold its exact gateway/client/pool-generation/profile-lifecycle leases across
  each await, revalidate afterward, and purge staged bytes on any source or
  lifecycle change.

With that authority, iOS can show a bounded import preview and explicit
confirmation, keep archive bytes in protected temporary storage, export
through Files/share sheet, and expose secrets only as boolean risk facts—never
raw values, previews, toasts, logs, retry state, or persisted model state.

## Targeted learned-memory management audit at `e400e008`

Learned-memory graph/detail/edit/delete and the apparent import/export surfaces
were audited directly against exact Hermes source
`e400e0088767a596ee21985d661a924cb087775a`, on serialized Talaria management
head `6d18411cb654047e1abadb728426cb2762f17de4`. This is distinct from the
already implemented built-in `MEMORY.md`/`USER.md` enablement, reset controls,
and external provider settings. The current row-management contract is
**blocked upstream**, so no phone list/editor/import/export UI or live memory
mutation is added.

Hermes exposes `GET /api/learning/graph`, `GET /api/learning/node`,
`PUT /api/learning/node`, and `DELETE /api/learning/node`. REST reads take a
profile query and mutations take a profile body field, and `_profile_scope`
rejects an unknown named profile. Responses do not echo the canonical resolved
profile, client/store generation, graph revision, or row revision, so the
request scope cannot be revalidated from the result. The parallel gateway RPCs
`learning.frames/detail/edit/delete` are weaker: they use the gateway process's
active home and accept no profile at all.

### Positional identity and whole-file mutation

Memory node ids are explicitly `memory:<source>:<global_index>`, where
`source` selects `MEMORY.md` or `USER.md` and the index is the row's current
position in the combined graph. Resolution rebuilds the entire card list and
only checks that the current row at that position still has the requested
source. If another writer inserts, removes, merges, or reorders a same-source
entry after the graph/detail read, the old id can edit or delete a different
memory. There is no content hash, immutable id, file revision, expected value,
or compare-and-swap precondition.

Memory edit/delete loads every delimiter-separated entry and rewrites the
whole file. The final rename is atomic for readers, but it does not prevent a
concurrent agent, curator, CLI, or dashboard writer from being lost. Success
returns only a prose message—not the affected immutable id, new revision, or a
postcondition snapshot. Memory deletion is permanent. Learned-skill ids are
names rather than positions and delete archives them, but detail/edit/archive
still have no source identity, expected revision, or mutation receipt; name
resolution and a concurrent file change can race in the same way.

### Bounds and sensitive content

`/api/learning/graph` is a full recursive skill scan plus every memory chunk,
all derived edges, clusters, and statistics. It has no cursor, page size,
collection cap, response byte cap, saturation/truncation fact, or snapshot
revision. Graph labels and memory previews are clipped for presentation, but
row and edge counts remain unbounded. `/api/learning/node` returns the full
skill or memory content with no wire/text cap, and the edit model accepts an
unbounded content string. A client-side limit after receipt cannot prevent
pathological decode/allocation or prove a complete identity set.

Learned memory is returned as raw user/agent prose with no redaction or
server-declared sensitive/secret classification. That can be legitimate for a
local editor, but it is not authority to persist content in phone model state,
logs, toasts, retry state, or an export artifact. A future mobile surface needs
protected transient storage and server-side risk facts; it must never infer
that prose is secret-free.

### Import/export and curator distinction

There is no server learned-memory import or export endpoint at this snapshot.
Desktop's Star Map share code serializes a visualization, not memory data: it
drops memory prose, trims labels, quantizes time, synthesizes new positional
ids on decode, and shows the result locally without writing it to Hermes. It is
neither a backup nor an import preview and cannot be used as a mutation source.

The existing `/api/curator` pause/run controls operate the background
**skill** curator and are already represented as an operator-maintenance
surface. They expose no learned-memory rows, proposed mutation set, revisions,
or commit token. Running the curator is therefore not a substitute for phone
memory curation, and no automatic run is added by this slice.

### Required portable contract

Mobile work can resume only after Hermes provides:

- paginated, explicitly wire/row/text-bounded profile snapshots that echo the
  canonical profile and one stable snapshot revision, with honest saturation;
- immutable server-generated ids for memory and learned-skill rows, independent
  of file position or display name, plus per-row revisions/content hashes;
- bounded detail reads that echo profile/id/revision and classify sensitive
  content without returning raw secret values in metadata;
- edit/archive/delete mutations carrying profile, immutable id, and expected
  revision, returning 409 on conflict and a canonical revisioned postcondition;
- explicit destructive semantics—archive/restore where possible, permanent
  delete separately confirmed—and no rewrite-whole-file lost-update window;
- bounded export bytes with a secret-treatment attestation, and bounded import
  upload followed by a non-mutating manifest/risk preview plus expiring
  prepare token and revision-checked commit; and
- an exact-source change event or manual-refresh contract. Polling an
  unrevisioned full graph is not a safe freshness strategy.

Talaria can then hold the exact gateway/client/pool-generation/profile-
lifecycle leases across each await, revalidate profile/id/revision before
publication and mutation, require an explicit destructive confirmation, and
purge protected row/export bytes whenever source authority changes.

## Targeted auxiliary-model administration audit at `057dcdf23`

Auxiliary model assignment, goal judging/contract drafting, vision, and their
timeouts were audited directly against exact Hermes source
`057dcdf236f8a6a26721c10fcc6ccb72726e272a`, on serialized Talaria
management head `1ec216d77e156f72d6184b82c252cdff26bb6eda`. This is distinct
from Talaria's existing main inference-provider/OAuth/custom-endpoint settings
and operator controls. The current auxiliary administration contract is
**blocked upstream**, so no phone editor, credential flow, config mutation, or
restart is added.

Hermes has two overlapping administration paths. The dedicated
`GET /api/model/auxiliary?profile=...` returns a fixed set of 12 task rows
(`vision`, `web_extract`, `compression`, `skills_hub`, `approval`, `mcp`,
`title_generation`, `review`, `triage_specifier`, `kanban_decomposer`,
`profile_describer`, and `curator`) with provider, model, and base URL.
`POST /api/model/set` can assign or reset those same slots, taking profile in
the body with precedence over the query. The list is bounded by that static
server tuple and the read does not return stored API keys, but its returned
provider/model/base-URL strings have no declared text or wire bounds.

That narrower path still lacks mutation authority. Neither response echoes a
canonical resolved profile, config revision, per-slot revision, or model-
catalog revision. The write accepts arbitrary unbounded provider/model/base
URL strings rather than requiring an id from the profile-scoped
`/api/model/options` snapshot, has no expected revision or 409 conflict, and
returns only the submitted assignment—not a revisioned read-back
postcondition. A blank task bulk-writes every declared slot, while
`task="__reset__"` resets every slot. Credential clearing is coupled to some
provider changes or the all-slot reset; there is no explicit, independently
confirmed clear for one custom endpoint. A same-provider custom credential
cannot be cleared through this route. Assignments apply to new sessions only;
they do not require or trigger a gateway restart.

### Goal judge, contract drafting, and the generic config route

`auxiliary.goal_judge` is not in the dedicated 12-slot tuple, so the dedicated
read omits it and the dedicated write rejects it as an unknown task. Goal
evaluation and goal-contract drafting both use the same `goal_judge` auxiliary
task. At this snapshot they correctly consume
`auxiliary.goal_judge.{provider,model,base_url,api_key,timeout,extra_body,
reasoning_effort}`; `max_tokens` is also honored when hand-authored even though
it is absent from the default/schema record. A positive timeout is accepted as
an arbitrary float with no upper bound, and a positive max-token value as an
arbitrary integer with no upper bound.

Those values are reachable only through generic `GET/PUT /api/config` and the
schema/default endpoints. The schema is recursively inferred from defaults:
auxiliary providers and models are ordinary strings rather than options tied
to the live model catalog, numeric fields carry no declared range, and empty
`extra_body` objects do not declare an allowed nested shape. `ConfigUpdate`
accepts an arbitrary dictionary, deep-merges it into the profile config, and
returns only `{ok:true}`. It has no admitted-field enforcement, expected
revision, conflict response, or canonical postcondition.

The generic read is also not a safe secret surface. It normalizes only the
main-model shape and otherwise returns the nested config record, including a
literal `auxiliary.<task>.api_key` when one is stored there. The schema may
be rendered by a client as a password field, but client-side masking does not
make the wire write-only. A phone must not fetch this record into model state,
logs, toasts, retry state, or persistence merely to edit one timeout. The
dedicated model setter accepts a transient key but persists it in config and
exposes no `credential_configured` fact or one-slot clear operation.

The same split affects other declared auxiliary tasks. Defaults also contain
`memory_query_rewrite`, `tts_audio_tags`, `monitor`, `background_review`,
`moa_reference`, and `moa_aggregator`, but they are absent from the dedicated
auxiliary snapshot. MoA has a separate API and remains a separate parity
slice. Plugin-registered auxiliary tasks can be resolved at runtime but are
also absent from this administration tuple. Talaria must not copy either the
12-slot tuple or the larger defaults list into a static mobile catalog and
pretend it is gateway authority.

### Required portable contract

Mobile work can resume only after Hermes provides:

- a bounded, profile-scoped auxiliary snapshot that declares every manageable
  task id, display/risk metadata, allowed fields, numeric ranges, clear
  semantics, and the current assignment while echoing canonical profile and
  one config/snapshot revision;
- gateway-driven bounded provider/model options tied to that snapshot (or a
  stable catalog revision), including task capability such as vision, without
  accepting a stale or undeclared selection silently;
- write-only credential inputs, `credential_configured` booleans on reads,
  and a separate explicit per-slot credential clear that never returns raw
  secret text;
- exact profile/task/expected-revision mutations with 409 conflicts and a
  bounded canonical revisioned postcondition, plus a separately confirmed
  all-slot reset if bulk reset remains supported;
- declared finite bounds for provider/model/base URL, timeout, token,
  concurrency, and any structured provider options—no arbitrary `extra_body`
  pass-through on the mobile route; and
- an exact-source change event or an explicit manual-refresh contract. No
  polling or restart is required merely to configure new-session defaults.

Talaria can then hold its exact gateway/client/pool-generation/profile-
lifecycle leases across discovery and mutation awaits, admit only
snapshot-declared task/field/option identities, revalidate the revision before
and after writes, keep credentials transient, and disclose honestly that an
assignment affects new sessions rather than a currently running chat.

### Targeted current movement after `e400e008`

The exact `e400e008..057dcdf23` movement does not close this blocker.
`7dde1b8b0` adds runtime MCP tool-call timeout precedence (per-server timeout,
then `timeouts.mcp.tool_call`, then 300 seconds) but exposes no new bounded,
profile-scoped client wire or revisioned mutation contract; it is not authority
for a mobile auxiliary/MCP timeout control. The six Linux Desktop HUD
geometry, input, zoom, reset, and documentation commits are native
window/compositor behavior with no portable iOS management surface. The final
`057dcdf23` commit is their merge plus the MCP timeout change. The auxiliary
API, secret exposure, task-list split, and revision gaps above are unchanged.

## Targeted MoA administration audit at `057dcdf23`

Mixture-of-Agents preset administration and its separate chat-time invocation
paths were audited directly against exact Hermes source
`057dcdf236f8a6a26721c10fcc6ccb72726e272a`, on serialized Talaria management
head `ebc1c577887c1f98e992a9900cbb43a4f95fe6e9`. The current administration
contract is **blocked upstream**, so no phone preset editor, automatic MoA
execution, live model call, config mutation, or restart is added.

Talaria already consumes one safe invocation projection: the gateway-driven
`model.options` catalog can include a virtual `moa` provider whose models are
the configured preset names. Talaria renders those names separately and a user
can explicitly select one for the current session; it deliberately never
persists a MoA selection as the profile default. That is not preset
administration. Hermes also has a `/moa <prompt>` one-shot command that swaps
the live session to the default preset for one turn and then restores the
prior model. This slice does not add a shortcut, background trigger, or any
other automatic invocation of that cost-bearing command.

### Dedicated REST contract

Hermes exposes `GET /api/model/moa?profile=...` and
`PUT /api/model/moa`. The write takes a profile in the body with precedence
over the query. Both enter the requested profile scope, and the dedicated
payload contains no API keys: reference and aggregator credentials resolve
through the separately configured providers. The write validator correctly
rejects incomplete slots, a preset with no complete reference, and recursive
use of the virtual `moa` provider. `reference_timeout` rejects booleans,
non-finite values, zero, and negative values, and degraded-reference policy is
typed as `loud` or `silent`.

Those positives do not supply concurrency-safe authority. Reads and writes
echo neither the canonical resolved profile nor a config/preset revision.
Writes replace the submitted preset map inside the profile config with no
expected revision, 409 conflict, mutation receipt, or independent read-back
postcondition. Two phones, Desktop, CLI, or an active agent can therefore lose
one another's preset changes. There is no `moa.changed` event; an unrevisioned
manual reread cannot reconcile an ambiguous write.

### Options, bounds, and cost controls

The REST snapshot does not declare allowed reference/aggregator provider-model
pairs. The CLI's slot picker separately asks the live inventory for configured
providers and at most 200 models, while `/api/model/options` exposes MoA
**preset names** in its virtual row—not a revision-bound worker-slot option
set. The MoA write accepts arbitrary provider/model strings without proving
that they were admitted by the same profile snapshot.

Preset count, preset-name length, reference count, and provider/model text have
no declared request or response bounds. Runtime parallelism is capped by the
private `_MAX_REFERENCE_WORKERS = 8` constant, but an unbounded reference list
is still fully queued and billed; neither the cap nor a maximum admitted
reference count is returned as API metadata. `fanout="per_iteration"` can
repeat the entire advisor set on every tool-loop iteration, and `every_n:<N>`
has no declared upper bound. The API provides no aggregate price estimate,
maximum call multiplier, or risk fact tying references, cadence, and the
acting aggregator together.

Numeric controls are also not a declared safe range. Reference and aggregator
temperatures accept arbitrary floats without a finite/range validator.
`reference_timeout` is finite and positive but unbounded above.
`reference_max_tokens` and per-reference token caps normalize only to positive
integers with no maximum; preset `max_tokens` accepts negative or arbitrarily
large integers. The acting MoA runtime does not in fact consult that preset
`max_tokens` field—the aggregator uses the normal acting request's token
behavior—so presenting it as an authoritative aggregator cap would be false.
Reasoning effort accepts an arbitrary string at the request model and silently
drops an unrecognized value during normalization instead of rejecting it.

### Lossy round trips and privacy risk

The dedicated types cannot faithfully round-trip the normalized read:

- normalized reference slots may contain a per-slot `max_tokens`, but
  `MoaModelSlot` does not declare that field, so Pydantic strips it on PUT and
  a whole-preset save silently loses the cap;
- the normalized GET returns top-level `privacy_filter`, but
  `MoaConfigPayload` does not accept it. Every PUT constructs a raw object
  without that key, normalization supplies the empty/off default, and
  `cfg["moa"].update(normalized)` overwrites an existing `display` or `full`
  privacy filter with off; and
- `save_traces` and `trace_dir` are omitted from the normalized response and
  payload. The current merge preserves those hidden keys, but a phone cannot
  disclose that full prompts, advisor outputs, usage, and aggregator data may
  be written to server JSONL traces or safely manage that high-risk state.

This matters beyond configuration polish. Advisors may receive conversation
content across several external providers. `privacy_filter="display"` still
passes raw advisor text to the aggregator, `full` additionally redacts that
injected text, and the default is off. `degraded_reference_policy="silent"`
can suppress failed-advisor disclosure. A mobile editor must show these data-
movement, trace, degraded-result, fanout, latency, and cost consequences before
enabling or broadening a preset; the current response cannot support an honest
summary and its write actively weakens an existing privacy setting.

Configuration and execution also have different freshness semantics. An MoA
facade reloads its named preset after the config file's modification stamp
changes, so a preset save may affect the next call of a session already using
that preset. The REST route itself does not invoke a model and does not require
or trigger a gateway restart, but “configuration only” does not mean “future
new sessions only.” A safe postcondition must state which revision active
sessions will observe.

### Required portable contract

Mobile MoA administration can resume only after Hermes provides:

- a bounded profile-scoped snapshot that echoes canonical profile and one
  config revision, declares finite preset/reference/name/text limits, and
  round-trips every manageable field without erasing hidden settings;
- bounded gateway-declared reference and aggregator provider/model options,
  capabilities, availability, and pricing tied to that snapshot or a stable
  catalog revision—never a static phone catalog;
- declared finite ranges/options for temperature, timeouts, token caps,
  reasoning effort, reference count, worker concurrency, and fanout cadence,
  with invalid input rejected rather than silently normalized;
- exact profile plus expected-revision writes, 409 conflicts, and a canonical
  revisioned postcondition. Preset delete/default/active changes need explicit
  operations or an equally precise atomic mutation set rather than an
  unqualified whole-map replacement;
- faithful privacy/tracing facts and mutations, with protected trace location
  handling and explicit confirmation for enabling raw traces, weakening
  privacy, hiding degraded advisors, adding providers/references, or increasing
  fanout/cost; and
- a server-calculated bounded execution-risk summary (maximum parallelism and
  call multiplier plus available price facts) and an exact-source change event
  or explicit revisioned manual-refresh contract.

Talaria can then hold its exact gateway/client/pool-generation/profile-
lifecycle leases across discovery and writes, admit only snapshot-declared
identities and ranges, revalidate revision and source before/after every await,
and keep administration separate from the existing explicit, session-only MoA
invocation path.

## Targeted relay deployment lifecycle audit at `057dcdf23`

Relay enrollment, deployment routing, and credential scope were audited
directly against exact Hermes source
`057dcdf236f8a6a26721c10fcc6ccb72726e272a`, on serialized Talaria management
head `12c793037fe839ddf0ffa3724ec085187fd2fb32`. The portable management contract
is **blocked upstream**, so Talaria adds no enrollment, routing mutation,
external relay call, automatic restart, or inferred mobile toggle.

Hermes has no relay enrollment or deployment-routing REST/RPC surface.
`hermes gateway enroll` is a host CLI flow: it exchanges a single-use token
with the external connector, receives a relay secret and delivery key once,
then sequentially writes relay identity and credentials into the active
profile `.env`. The external token is consumed and the secret minted before
those local writes finish, so a local write failure can leave partial state or
an orphaned enrollment. The flow has no prepare/preview, confirmation receipt,
revision/CAS, atomic local commit, canonical postcondition, or remote revoke /
unenroll operation. Managed installs are rejected and a gateway restart is
explicitly required. Connector revocation is terminal rather than a safe
phone-managed lifecycle.

The scope split is intentionally asymmetric. `GATEWAY_RELAY_SECRET`,
`GATEWAY_RELAY_ID`, `GATEWAY_RELAY_DELIVERY_KEY`, and identity-provider
credentials are profile-scoped authentication. Deployment and routing stamps,
including relay URL/endpoint, allowed-direct platforms, platform/bot/route
filters, instance id, wake URL, and display name, are process-global. Writing
those stamps into a secondary multiplex profile can be ineffective even while
its profile credential remains valid. An environment-stamped relay also
disables direct messaging adapters process-wide by default unless the explicit
allow-direct escape hatch is set; config-only `gateway.relay_url` retains an
older additive behavior. A profile-local switch cannot truthfully represent
either topology.

The generic profile `/api/env` and `/api/config` routes are not substitutes:
they expose no canonical process/deployment identity, topology revision, CAS,
conflict, atomic enrollment receipt, or routing postcondition, and their scope
cannot prove that a process-global stamp took effect. The messaging-platform
catalog also exposes a `relay` row without declared relay credential fields;
that row is not authority for deployment lifecycle mutation. Talaria now keeps
it visible as a read-only **Deployment managed** row and rejects relay updates
and connection tests in the client as defense in depth. Direct messaging rows
remain profile-scoped. Pairing and the existing separately confirmed,
lifecycle-fenced Gateway Operations restart surface remain distinct.

Portable relay management can resume only after Hermes supplies a bounded
snapshot that echoes canonical process/deployment and profile identities,
declares every manageable field and its effective scope, returns only boolean
secret-presence facts, and includes topology plus credential revisions. It
also needs a prepare/confirm enrollment protocol that does not consume the
single-use external token until an atomic commit can succeed, write-only secret
handling, expected-revision mutations with 409 conflicts and canonical
postconditions, explicit revoke/recovery semantics, and an exact statement of
whether a separately confirmed restart is required. Routing changes must
disclose their process-wide direct-adapter, duplicate-ingress, session, and
scale-to-zero effects. Talaria can then hold exact gateway/client/generation
and profile-lifecycle leases across the bounded snapshot and commit without
pretending process routing belongs to the selected profile.

## Upstream movement after `c1e25cad`

The GitHub comparison reports 13 commits ahead of `c1e25cad` (a 14-commit
audit window when the prior pinned endpoint is included). Of the five hashed
authority files, only `apps/desktop/src/plugins/hermes-bots/plugin.js` changed:
57 additions and 6 deletions. Its SHA-256 moved from
`400a731d5263ef47927bcb261560fb626d7e285299c8a532319b73c5a5f9df22` to
`349d68988509f48bd6a9a84f3740252d09770699f80ff3e28dd7d55c74613927`.
The Bot Mode, Desktop, and multi-connection guides plus `apps/desktop/DESIGN.md`
are byte-for-byte unchanged at their pinned hashes.

| Commits | Upstream change | Talaria disposition |
|---|---|---|
| `c1e25cad` | Prior exact-source baseline: canonical-chat adoption, friendly mentions, activity/hiding, room prompt recovery, immutable room identity, source-qualified commands/MCP, and profile-scoped Projects. | Implemented on `main` by PR #31 at `04695b91`; the live gateway/device proofs below remain open. |
| `847a9df`, `8794e5a` | `auxiliary.goal_judge.timeout` now controls goal judging and contract drafting instead of a hard-coded 30 seconds. | Still open under management parity. Talaria has no auxiliary goal-judge administration surface; do not classify this runtime/config behavior as mobile-complete. |
| `770f9a5`, `ba501f0` | Bot Mode mention autocomplete and mention middleware now read the connection-suffixed live union-roster cache, with a freshest-stale fallback. | Already satisfied by architecture: both Talaria paths synchronously consume `AppModel.unionRosterBots` in `AppModelLive+A2A.swift`. They never perform Desktop's incorrect bare TanStack cache lookup. Existing mention protocol checks exercise union duplicates and `SourceQualifiedRoutingTests` exercises a foreign route. |
| `76952ba` | Mention completion self-filtering and middleware sender identity follow the focused on-screen bot rather than the gateway socket's launch profile. | Already satisfied: `ChatView` supplies its source-qualified `botID` as `speaking`, `MentionField` supplies its owning bot, and `MentionResolver.isSpeaker` compares the full route. `testQualifiedRemoteMentionSpeakerExcludesOnlyItself` pins the foreign-focused case. |
| `ed2d01a` | Core and contributed bare `@handle` completions are deduplicated while `@diff`, `@staged`, and typed context references remain distinct. | No client change required. Talaria has one shared bot-completion provider over a canonical union roster rather than Desktop's merged provider stack; `MentionCompletions` emits one row per roster identity and retains source-qualified collision handles. Keep this rule in the regenerated mention ledger. |
| `5969ea1`, `b9855f5`, `19c6a11` | OpenCode Zen/Go catalogs gained models and corrected GPT/Grok/Muse Spark API routing; `x-preview-f-free` gained a 1M context fallback. | Gateway-driven. Talaria loads `model.options` through `GatewayClient+Models.swift` and does not copy Hermes' curated provider catalog or choose its inference wire protocol. Certify catalog refresh against the pinned gateway; no static iOS catalog edit is warranted. |
| `309e883`, `9629653`, `892ec7a` | Contributor-email metadata only. | N/A to user-visible or gateway parity. |
| `95057c2` | Desktop/web enable the React Compiler and fix plugin-translation invalidation exposed by memoization. | Renderer-local implementation detail. Talaria is native SwiftUI and does not share React compilation or the Desktop plugin i18n registry; N/A to portable behavior. |

The new mention regressions change Desktop's correctness, not Talaria's
contract shape. They therefore move the authority pin without moving a parity
row. The goal-judge timeout is a real portable management gap, and the model
changes require live catalog evidence because their data is supplied by the
gateway.

## Upstream movement after `95057c2`

Hermes moved another 12 commits to `18a15a46`. None of the five hashed
authority files changed, so the plugin hash above and the other four manifest
hashes remain exact. The portable behavior still needs a disposition because
gateway and cron contracts changed outside the Desktop authority set.

| Commits | Upstream change | Talaria disposition |
|---|---|---|
| `949aff6` | Desktop Vite formatting only. | N/A; no runtime or portable behavior change. |
| `5210dd4` | Connector approval sends now distinguish sent, definite failure, and ambiguous timeout. Ambiguous delivery keeps the prompt registered and forbids duplicate resend/text fallback. Pending-approval tool results tell the agent not to reissue a variant. Streamed interim/seal frames retain block-format hints. | No new Talaria RPC/event shape. The retained pending prompt is compatible with Talaria's source-qualified approval recovery; add a live connector-fronted delayed-ack case before calling approval recovery certified. Formatting hints and agent tool text are gateway/messaging behavior, not an iOS renderer contract. |
| `57fe01e`, `424d07e`, `d4f7c2d` | Approval, clarify, slash-confirm, and expiry acknowledgements are interim, fire-and-forget sends. They cannot absorb/seal the turn's open draft or deadlock the relay read loop waiting for their own result frame. | No client change required. Certify that a Talaria approval/clarify response during a connector-streamed turn leaves one continuing stream and one final answer, with no duplicate fallback message. |
| `a7cfe39`, `952d1ce` | Clarify prompt sends adopt the same ambiguous-timeout classification, preserve registration, retain failure diagnostics, and continue into the existing bounded wait. | Talaria's clarify and room-prompt state already keys the exact gateway/session/request and rebuilds from resume. Add a delayed connector acknowledgement to the live single/multi-select and room recovery matrix. |
| `4e1dd1a`, `58258af`, `991af03`, `43c6dac` | Raw cron jobs gain optional `reasoning_effort`; precedence is per-job pin over per-model override over global effort. Empty clears, invalid values fail before persistence, and model tool dispatch cannot set it even though formatted jobs report it. Desktop's upstream mutation remains CLI-owned; Talaria's product decision explicitly authorizes a guarded mobile REST mutation for this job-owned field. | Implemented as an explicitly authorized mobile REST mutation. `CronJobDetail` and `RoutineEditorView` decode/display the raw value, preserve unknown values on unrelated edits, and send only canonical/clear values through the exact REST PUT normalizer. The model tool remains read-only; live certification remains open. |
| `18a15a4` | Windows updater progress self-test retries transient listener stalls. | Test-only; no portable client contract change. |

This range adds live cases and one management field, not a reason to alter the
five authority hashes or to claim existing gateway-dependent rows complete.

## Upstream movement after `18a15a46`

The exact Git graph from `18a15a46` (exclusive) through `efb6b40f` (inclusive)
contains 19 commits: nine memory/OpenCode/runtime commits on the first parent,
nine relay-exclusive/enrollment commits on the merged topic branch, and the
merge commit. The combined delta is 25 files, 1,352 additions, and 100
deletions. None of the five authority files changed; their recomputed SHA-256
values are exactly the values already recorded in the manifest. That does not
make the non-authority changes non-portable, so every commit is dispositioned
below against the exact `efb6b40f` source.

| Commit | Exact source change | Talaria disposition |
|---|---|---|
| `67292ec` | `gateway/config.py:_apply_env_overrides` makes an environment-stamped `GATEWAY_RELAY_URL` relay-exclusive: direct messaging adapters are disabled, while `local`, `api_server`, and `webhook` survive. YAML-only relay configuration remains additive. | **N/A to the Talaria client wire; existing management gap.** This is process deployment behavior, not a new RPC/event shape. Talaria still lacks messaging-platform/connector lifecycle management, so it cannot configure or inspect this policy from the phone. Connector deployments need the live guard in `TESTING.md`; no iOS transport change is warranted. |
| `2d3f5c1` | Adds truthy `GATEWAY_RELAY_ALLOW_DIRECT_PLATFORMS` as the explicit environment opt-out from relay-exclusive mode (`gateway/config.py:2776-2785`). | **N/A to client wire.** It is an operator-owned environment escape hatch. Keep direct-plus-relay behavior in the deployment matrix; do not invent a mobile toggle unsupported by a gateway API. |
| `477a022` | Routes the relay URL and opt-out reads through the secret-scope-aware `getenv` in `gateway/config.py`. | **Final mechanism retained; initial interpretation superseded.** `f8c3635` establishes the final contract: those routing reads resolve process-global values while relay authentication material remains profile-scoped. No profile-local routing contract is claimed. |
| `2ef095c` | Makes the `gateway/config.py` relay-exclusive sweep logs source-neutral and distinguishes warning/info wording. | **N/A.** Gateway log presentation only; Talaria receives no new field. |
| `55a272d` | Adds `tests/gateway/test_config.py` regressions for scoped relay stamps, explicit/automatic adapter log levels, and cleanup of the internal `_enabled_explicit` marker. | **Test-only.** No production source or mobile contract change. |
| `5a5d6b9` | `agent_init` and `tools/memory_tool.py` share one built-in-store flag resolver; the memory availability check opts out of the generic 30-second tool-check cache (`tools/registry.py:no_cache_check_fn`). | **Implemented client controls; gateway proof open.** Talaria already decodes and independently writes `memory.memory_enabled` and `memory.user_profile_enabled` in `OperatorSettings.swift`. The fresh per-turn tool surface is gateway-owned; certify a live config flip without claiming the existing parser test proves agent behavior. |
| `c809d96` | Parses built-in memory flags with Hermes' boolean parser, so quoted `"false"` is false rather than Python-truthy. | **Implemented path; no wire change.** Talaria writes JSON booleans, and the pinned gateway now also handles legacy/string config consistently. Retain this in the one-store-at-a-time live case. |
| `2cf7b36` | Enforces `MEMORY.md` and `USER.md` permissions independently in direct and staged writes, normalizes malformed/missing memory config, and advertises only enabled `target` enum values from one per-definition snapshot (`tools/memory_tool.py:1177-1234,1335-1389`; `agent/agent_init.py:1811-1832`). | **Implemented controls; certification open.** Talaria exposes both switches and write approval, but does not consume the agent's internal function schema. Verify enabled-target success, disabled-target rejection, and approval replay after a setting change against the exact gateway. |
| `7c9285a` | Bounds model-supplied invalid memory targets with `_bound_error_text` and restores the `Use 'memory' or 'user'` recovery hint. | **Gateway-owned / no client change.** Talaria's generic tool-result path can render the bounded error; no new response shape exists. Upstream automated coverage is source evidence, not a mobile certification claim. |
| `f9cd51e` | Extends OpenCode Go family routing in `hermes_cli/models.py` and `runtime_provider.py` to custom `opencode-go-*` providers and sends Go/Zen Grok models through Responses rather than chat completions. | **Implemented server-driven path; live proof open.** Talaria manages custom endpoints and consumes gateway `model.options`; it does not select the provider HTTP transport. Exercise a Talaria-created OpenCode endpoint and model switch against the pinned gateway. |
| `12a3a35` | Makes the OpenCode matching in `hermes_cli/models.py` and `runtime_provider.py` case-insensitive and symmetric for custom Zen and Go providers. | **Implemented server-driven path.** No catalog/RPC shape changed. Talaria's Name / Base URL / Model form sends no independent id and Hermes lowercases the generated slug, so a mixed-case provider id is not a Talaria-created endpoint case. The pinned upstream tests cover it; any additional live proof must use a hand-written disposable gateway config. |
| `a83c391` | Centralizes `opencode_provider_family`, applies it to switching/normalization, and aliases OpenCode-reserved `web_search`/`search_files` function names on the provider wire before mapping them back to canonical Hermes tool calls (`agent/transports/codex.py:62-110,556-560,789-800`). | **Implemented generic client surface; live proof open.** The alias is deliberately invisible to Talaria, whose ordinary tool cards should still receive canonical names. Verify both tools complete without an OpenCode 400 and without exposing `hermes_*` names. |
| `4978039` | For named custom providers or arbitrary names hosted on `opencode.ai`, derives API mode per effective model and heals the `/v1` suffix unless the user explicitly configured a transport (`hermes_cli/runtime_provider.py:1243-1278`). | **Implemented server-driven path; live proof open.** Talaria's custom-endpoint editor supplies name/URL/model and relies on Hermes for runtime selection. Test Responses, Messages, and Chat Completions model families; no static iOS routing table belongs here. |
| `533886c` | Adds `contributors/emails/Lesnak1@users.noreply.github.com`. | **N/A metadata-only.** |
| `f8c3635` | Classifies relay URL/endpoint/allow-direct/platform/route/wake/display routing stamps as process-global deployment configuration, while relay secrets, ids, delivery keys, and IDP credentials remain profile-scoped (`agent/secret_scope.py:117-133`). | **N/A to client wire; existing deployment-management gap.** This is the final contract that supersedes `477a022`. Talaria must not surface profile-local relay routing as if it were effective process configuration. |
| `3d25fd5` | Adds a `hermes_cli/gateway_enroll.py` warning when `hermes gateway enroll` writes relay URL/wake stamps into a secondary multiplex profile whose isolated `.env` cannot activate process-global routing. | **N/A CLI-only.** Talaria has no gateway-enroll RPC and should not imitate a host-local credential writer. |
| `d97cb8f` | Adds `tests/gateway/relay/test_relay_registration.py` coverage for config/registration agreement under process-only versus profile-only relay URL stamps. | **Test-only.** No production source change. |
| `6360113` | Corrects the enroll warning to read multiplex topology from the default Hermes root (or its environment override), with resolved-path secondary-profile detection (`hermes_cli/gateway_enroll.py:294-350`). | **N/A CLI-only.** This fixes the warning's authority but adds no mobile contract. |
| `efb6b40` | Merge commit joining the relay-exclusive topic branch to the memory/OpenCode first parent; it has no additional merge-resolution delta beyond the two audited parents. | **Merge-only.** No twentieth behavior is inferred. |

This window creates no new Talaria wire decoder requirement. It strengthens
gateway behavior behind three existing mobile surfaces: connector-backed
messaging deployment, built-in memory switches, and custom inference endpoints.
The first remains an existing management gap; the latter two have client
controls but still require the exact live cases below.

## Authority-changing movement after `efb6b40f`

`40643cba` is a descendant of `efb6b40f`. The reachable range contains 181
commits because it includes merged and replayed history, while the exact net
tree delta is bounded to 20 files: 3,134 additions and 85 deletions. The Bot
Mode plugin hash moved from `349d6898...` to `738e108f...`, and the Bot Mode
guide moved from `d13ab467...` to `3b614687...`. The other three authority
files recompute to their prior hashes. The earlier 19-commit ledger above is
retained; this section dispositions every file in the later net tree rather
than treating merge ancestry as 181 independent product changes.

| Exact net files / contributing commits | Contract | Talaria disposition |
|---|---|---|
| `apps/desktop/src/plugins/hermes-bots/plugin.js`, `apps/desktop/src/plugins/hermes-bots/tests/group-chat.test.mjs`, `website/docs/user-guide/bot-mode.md` (`64d393cb`, `7656a2ad`, `3b83b5e1`, `5d75a466`, `c6745da7`, `a976560e`, `7af4b8ee`) | Bot rooms publish a bounded version-3 projection in default-profile `ui_meta["hermes-bots-groups"]` to every reachable gateway. Durable `id:<roomId>` identity survives rename; explicit, bounded tombstones represent disband; missing/truncated projection data never means deletion. Recent logs merge idempotently by stable message id, while revisioned room fields converge. Desktop hydrates remote state, fans out writes, retries per gateway, and reseeds on reconnect. | **Implemented; live certification remains.** Talaria hydrates the safe projected subset into protected room storage without replacing richer local state, publishes to every reachable credentialed gateway, serializes each gateway lane, and reseeds on adoption, reconnect, and foreground recovery. Disconnected lanes remain suppressed until reconnect proves reachability. Missing projection is inert; explicit tombstones are durable and locally applied before reconnect. The six-case live matrix below is still required before claiming certified cross-client convergence. |
| `tui_gateway/methods_profiles.py`, `tui_gateway/server.py`, `tests/tui_gateway/test_profiles_ui_meta_cas.py` (`3b83b5e1`) | `profiles.list` exposes `ui_meta_revisions` (including `{}` for a CAS-capable profile). `profiles.configure` accepts per-key `ui_meta_expected_revisions`; under a dedicated lock it either increments and returns revisions or returns `applied.ui_meta=false` plus `ui_meta_conflicts`. Deleted-key revisions persist so stale writers cannot recreate data. Omitting expectations retains legacy best-effort writes. | **Implemented; live certification remains.** Talaria distinguishes omitted revision maps from CAS-capable `{}`, performs reread/merge/retry and exact-increment read-back under one connection-generation/traffic lease, retries each gateway on the bounded 1/2/4/8/16/30/30/30-second ladder, and retains an explicitly detected legacy best-effort fallback. |
| `hermes_cli/update_receipt.py`, `hermes_cli/update_cmd.py`, `hermes_cli/build_info.py`, `gateway/status.py`, `tests/hermes_cli/test_update_receipt.py` (`1d74833d`, `1acbeed1`) | Host updates now retain structured receipts and compare each live gateway's stamped `code_sha`/`code_version` with the updated code identity. | **Host/CLI operational behavior.** No new Talaria RPC response is introduced by these files. It strengthens the existing gateway-update/version-evidence gap; a native receipt surface would need a gateway API rather than reading host files. |
| `.dockerignore`, `docker/stage2-hook.sh`, `tests/tools/test_stage2_hook_api_server_keygen.py` (`7a17a1b8`, plus packaging cleanup in the range) | Container stage 2 bootstraps `API_SERVER_KEY` even when no `.env` exists and adds deployment regressions. | **Deployment-only.** It can improve first-boot reachability but creates no mobile wire shape. |
| `plugins/platforms/telegram/adapter.py`, `tests/gateway/test_telegram_rich_messages.py`, `website/docs/user-guide/messaging/telegram.md` (`790c8501`, `216c98aa`, `40643cba`) | Telegram rich final messages are sent persistently after DM drafts; draft-final cleanup no longer consumes the durable final, and docs clarify the behavior. | **Messaging-adapter-only.** Talaria is not the Telegram renderer and receives no new client event shape. |
| `gateway/stream_consumer.py` (`216c98aa`) | Draft-final cleanup is scoped so a later persistent final remains fresh. | **Gateway-owned delivery fix.** Retain one-final/no-duplicate live messaging evidence; no Talaria decoder change. |
| `website/docs/guides/manage-hermes-cloud-with-mcp.md`, `website/sidebars.ts` (`f4a03081`, `46e1a59d`) | Adds Cloud Portal MCP management documentation and navigation. | **Docs-only for Talaria parity.** Existing generic MCP/chat surfaces can invoke server tools; this adds no native protocol obligation. |

The precise shared-room client obligation is deliberately narrower than a full
transcript replica: preserve Talaria's protected full local log and durable
outbox, consume and publish the bounded projection (48,000-byte envelope, 16
recent messages, 1,200 text characters per message, 24,000 image characters),
merge stable message ids and revisioned fields, and never infer deletion from
omission. Use immutable room ids, final id tombstones for disband, revisioned
legacy-name tombstones only for migration, and fan out through every attached
default-profile gateway. A rename keeps the id; disband then same-name recreate
mints a new id. CAS must be tracked per gateway and per metadata key, with
conflict reread/merge/retry and read-back confirmation. Older gateways are
supported only through explicit feature detection. Foreign client-local
connection ids hydrate as visible, view-only frozen seats until an exact local
gateway identity exists; labels are never guessed and frozen seats never run.
Storage and scheduler policy are automated-test covered, while production
wiring and Desktop/mobile convergence remain uncertified until the retained
live matrix in `TESTING.md` passes.

The wire envelope is `{version: 3, updatedAt, rooms, deleted?}`. Room keys are
`id:<roomId>` or migration-only `name:<legacyName>`; a room carries `name`,
optional `roomId`, `log`, `revision`, source-qualified `members`, and optional
`image`. Projected log rows carry optional stable `id`, structured `from`,
`text`, `at`, and optional `thread`. One upstream storage helper
(`durableGroupChatRooms`, plugin lines 796-814 at this pin) omits `roomId`,
while the normal update path persists it and the guide/tests require durable
identity. Talaria must retain `roomId`; it must not copy that helper omission
as a client contract.

Talaria uses an empty-string `image` field as a compatible property-presence
extension for an explicit mobile avatar removal. The pinned Desktop receiver
already treats a present empty image as clear, while an absent image remains
ambiguous because size bounding can omit it. A Desktop-origin omission is
therefore never inferred as removal.

## Current-source corrections

| Contract | Talaria disposition | Automated evidence | Remaining certification |
|---|---|---|---|
| Canonical Bot Chat exact registry, adopt-before-kickoff, and bounded hydration retry | Updated for Hermes `a4f16e3f`. Bot-row opens exact-list `{profile,title:"Bot Chat",include_hidden:true}` on every tap, resume the resolved tip while retaining the durable root, and never infer identity from recency or legacy `ui_meta.chat`. Lookup failure cannot mint. Birth rechecks, creates hidden, titles before adopt/kickoff, preserves the named row on kickoff failure, and retains ambiguity leases. `/new` matches durable or resolved identity. | `CanonicalSessionProtocolTests`, `BotModeRuntimePolicyTests`, `TranscriptRuntimeRemediationTests`, `ProfileLifecycleTests`, source-qualified routing tests | Real primary and foreign profiles: exact existing chat, compression lineage, missing row birth, title-RPC compatibility, definite/ambiguous kickoff failure, lookup outage, and scratch-session `/new` |
| Friendly renamed mentions | Implemented. Bot Mode title and raw core `display_name` both remain accepted; legacy handles, including the default agent, remain routable; reserved friendly aliases cannot claim broadcast/user words; exact forms win before collapsed ambiguity. Room members retain both identities. | Mention/handle protocol checks, `RoomEngineTests`, `BotModeRuntimePolicyTests` | Two gateways with colliding friendly, collapsed, and legacy forms; roster disappearance and relaunch |
| Agent Inbox attribution provenance | Implemented fail-closed. Current Hermes `message_agent` transcript prefixes can carry a display handle without an authenticated source route. Talaria preserves markerless endpoints as opaque presentation identities for both inbound rows and mirrored replies; it never qualifies them with the recipient session's gateway or borrows a colliding union-roster bot. Legacy rows with an explicit immutable route remain source-qualified. | `SourceQualifiedRoutingTests` markerless sender/reply and duplicate-roster cases | Two live gateways with the same handle, including a markerless inbound message and reply round trip |
| Preferred/last conversation activity plus worker-session liveness | Implemented. Conversation activity alone controls unread/ranking; a valid worker stamp contributes live presentation for 150 seconds and display age without reordering. | Preferred-session checks and `BotModeRuntimePolicyTests` | Real worker child session, clock-skew/future stamp, remote gateway row |
| Roster Hide/Unhide | Implemented as display-only `ui_meta["hermes-bots"].hidden`. Unhide writes literal `false`; hidden rows retain mentions, rooms, polling, and unread but do not emit activity toasts. Show Hidden is session-local and dims inspection rows. | Cosmetics protocol checks and `BotModeRuntimePolicyTests` | Desktop/mobile round trip, hidden unread arrival, failed write rollback |
| Hidden room-member clarification and approval | Implemented as runtime-only prompt state rebuilt from `session.resume`. Clarify wins when both fields exist; cards use the exact room/member/runtime/request identity and owning gateway. Approval requires a positive resolved count. Batch answers are sequential, resume accepted locks from `pending_clarify.answers`, and never resend locked questions. | `RoomPendingPromptTests`, `RoomRoutingTests` | Cross-gateway approval and single/multi-select/batch clarify; partial batch relaunch; desktop resolves first; 20-minute hard cap |
| Room pending deadline/recovery | Implemented. A blocked non-running session cannot become a pass. Busy or awaiting-user state extends the sliding 180-second deadline up to the 20-minute hard cap; the cap clears transient prompt UI while leaving durable timed-out work for later harvest/re-mirroring. | `RoomRoutingTests` | Background/relaunch near both deadlines; rename, member removal, and disband while a prompt is open |
| Immutable room member-session identity | Implemented with the durable Talaria `RoomID`, independent of the editable room name. Rename preserves identity; delete and same-name recreation mint a different identity and cannot resume the deleted room's title-based sessions. Existing durable session IDs remain first authority and legacy name-titled rooms retain an explicit migration fallback. | `RoomRoutingTests` | Rename and same-name recreation against real primary and foreign profiles |
| Shared gateway room projection and profile-metadata CAS | Implemented. Talaria combines its bounded, separately persisted ledger with safe rich-room hydration, reachable-credentialed-gateway fan-out, per-gateway serialization/retry, exact CAS read-back, bounded legacy fallback, and adoption/reconnect/foreground reseeding. Foreign client-local routes hydrate as frozen view-only seats until exact local authority exists. Privacy deletion fences suspended sync, and startup applies cached tombstones before network recovery. | Focused `RoomStoreTests`, `RoomEngineTests`, `RoomProjectionRuntimeTests`, `ProfileUIMetaCASTests`, and cached-tombstone/settings `RoomRoutingTests` regressions cover storage and scheduler policy. Production target discovery and lifecycle-hook wiring are source-reviewed but remain part of live certification; upstream group-room and profile-CAS suites remain the pinned authority. | Run and retain all six live Desktop/phone/gateway cases in `TESTING.md` |
| Source-qualified slash commands | Implemented. Catalog/completion/resolve caches are per physical gateway; `slash.exec` captures the client and session that own the selected bot and connection generation. Typed output/send/skill/prefill/alias results are decoded without an unsafe unconditional `command.dispatch` fallback. Follow-up send failure retains a recoverable draft without replaying the first RPC. | `SourceQualifiedRoutingTests` | Two live gateways with the same runtime session id; supported structured results; plugin/quick-command collision remains rejected |
| Source-qualified MCP setup prompts | Implemented with `(gateway, request_id)` identity, secondary event routing, exact-source expiration and response. | `SourceQualifiedRoutingTests` | Same request id on two live gateways and one expired response |
| Profile-scoped Projects | Implemented against current `projects.discover_repos`, `projects.tree`, and `projects.project_sessions`. Every read/write carries the verified raw profile; discovery uses `scan:true` and completes before tree hydration. Same-gateway client replacement and profile lifecycle invalidate authority. Partial or saturated trees fail closed. | `WorkspaceProjectsProfileScopeTests`, `WorkspaceCommandCenterTests` | Two profiles with colliding project ids; zero-session remote repo scan; profile rename/delete during mutation |
| Connector prompt-delivery ambiguity | No new client wire shape. Existing approval/clarify recovery retains exact source identity and resumes pending state; current Hermes now also keeps connector-side prompt registration on an ambiguous send timeout. | `SourceQualifiedRoutingTests`, `RoomPendingPromptTests`, `RoomRoutingTests` | Delayed connector acknowledgements for approval and clarify, including a response during a streamed turn with no deadlock, sealed draft, duplicate card, or duplicate final |
| Independent built-in memory stores | Implemented controls. Talaria decodes and writes both built-in store flags independently and exposes the write-approval switch; exact Hermes now makes the live tool schema and both direct/staged writes honor the same flags. | `SourceQualifiedRoutingTests.testOperatorConfigParsesOnlySafeMobileControls`; upstream memory regression suite retained at `40643cba` | Flip each store independently on a disposable profile, begin a fresh turn, prove enabled writes succeed and disabled direct plus approved/staged writes fail with bounded recovery text |
| Custom OpenCode family routing and tools | No new Talaria wire shape. Custom endpoint CRUD/activation and gateway-driven model catalogs are implemented; Hermes owns family detection, per-model API mode, `/v1` healing, and reserved tool aliases. | `InferenceProviderManagementTests`, model catalog/switch tests; upstream custom-runtime and Codex transport suites | Create/activate a lowercase family-suffixed Go/Zen endpoint from Talaria; run Responses, Messages, and Chat Completions models plus canonical `web_search` and `search_files` tool calls. If mixed-case provider matching needs additional live proof, use a hand-written disposable gateway config rather than attributing that id to Talaria's form. |
| Relay deployment and exclusive stamps | Audited at exact `057dcdf23` and blocked upstream for mobile mutation. Routing stamps are process-global while relay identity/credentials are profile-scoped; enrollment is a one-shot external host CLI flow with sequential local writes, no prepare/CAS/postcondition/revoke API, and an explicit restart. Generic profile env/config routes cannot prove effective process topology. Talaria keeps the catalog's relay row visible but read-only as **Deployment managed**, rejects relay platform mutation/test authority, and never implies a profile-local routing toggle. | `MessagingPlatformManagementTests.testRelayCatalogRowRemainsVisibleButCannotMintProfileMutationAuthority`; upstream config, secret-scope, relay-registration, enrollment, and multiplex warning tests retained at `057dcdf23` | Required portable contract above; then disposable connector deployment proof of relay-only sweep, opt-out, multiplex scope, atomic enrollment/recovery, separately confirmed restart, and revocation |
| Messaging-platform lifecycle | Implemented against current Hermes `GET /api/messaging/platforms`, `PUT /api/messaging/platforms/{id}`, `POST /api/messaging/platforms/{id}/test`, and live `platforms.changed` at upstream `77d6c78c`. Talaria captures the exact gateway/profile/client/pool generation, admits only bounded snapshot-declared platform ids and environment keys, sends the profile in both query and mutation body, and revalidates every awaited boundary. Catalog reads, writes and connection tests all hold the captured pool-slot plus profile-lifecycle lease across their REST await. Platform/env collections and display text are explicitly capped; an over-cap platform list is rejected wholesale so an unseen duplicate cannot mint prefix authority, while omitted rows are disclosed. Credentials exist only as transient `SecureField` drafts; stored values project to the boolean **Configured**, while server 409/404/timeout messages and non-optimistic enablement remain authoritative. The deployment-managed relay row is visible but read-only and cannot mint profile mutation/test authority. Pairing stays a separate Connections surface. No automatic restart exists: `pending_restart` points explicitly to the existing fenced Gateway Operations control. | `MessagingPlatformManagementTests` (20 focused cases: decode/redaction, collection/display bounds and visible rejection, relay deployment-scope rejection, lease success/failure, blank-secret rejection, identity bounds, body profile, allowlist/clear, source/profile/client switches, stale suppression, 409/404/timeout, change-event refresh) | Two profiles on a multiplex gateway, including a port-binding adapter 409; physical Slack/Discord/Telegram credential save-clear-test; background `platforms.changed`; Dynamic Type/VoiceOver; fenced manual restart |

## Portable current-Hermes work still open

| Surface | Status / next proof |
|---|---|
| Gateway PTY | Implemented in Command Center with an authenticated SwiftTerm renderer, exact gateway/profile binding, OAuth ticket refresh, opaque reattach tokens, resize, ordered byte delivery, and lifecycle recovery. Automated gates are present; live-gateway and real-device certification remain open. Hermes does not confirm whether a token reattached or recreated a PTY after its detached TTL, and exposes no remote terminate endpoint, so Talaria asks before a potentially expired reattach and only promises local cleanup. |
| Projects filesystem | Blocked upstream for safe mobile use: `/api/fs` does not return authoritative resolved-target/root containment proof and writes have no atomic expected-hash/`If-Match`. Talaria must remain fail-closed rather than provide best-effort editing. |
| Unknown explicit Project profile | Hermes currently falls back to the launch profile. Talaria revalidates the selected route immediately before writes and fails closed, but Hermes should reject an explicit unknown profile. |
| Cron per-job reasoning effort | Implemented as an explicitly authorized mobile REST mutation. Talaria decodes and displays the raw field, preserves unknown values on unrelated edits, and sends only canonical/clear values through the exact REST PUT normalizer, which delegates to Hermes' canonical `cron.jobs.update_job` validation. The model tool remains read-only and cannot set this job-owned field. Live certification remains open. |
| Rich transcript parity | Partial: markdown, tables, code, working avatar, transcript actions, jump-to-bottom, exact-source message-level child creation, and bounded typed tool-history hydration now exist. The mobile generic fallback groups larger runs and discloses status, arguments, result, provenance, and diagnostics without name/prose pairing. Explicit file-edit diffs now hydrate and overlay only by exact tool id, then render as bounded, sanitized, selectable mobile disclosures with +/- counts; live gateway/device proof remains open. Persistent multimodal parts, generated images/lightbox, specialist ANSI/search/math/diagram renderers, per-message TTS, whole-turn timing, the N/M alternative-branch picker, lineage presentation, and tour/activity remain. |
| Management parity | Partial: provider/model/profile/capability/routine/memory/voice/operator and messaging-platform lifecycle surfaces exist. Relay deployment, subagent tree/live tail/files/cost, MCP per-server logs, auxiliary model administration, and MoA administration remain. Relay deployment is explicitly blocked by the targeted `057dcdf23` audit: enrollment is CLI/external-call-only and revisionless, process-global routing differs from profile credentials, and generic profile env/config writes cannot prove effective topology. Talaria therefore exposes relay read-only and rejects profile-platform mutation/test authority. Webhook lifecycle is explicitly blocked by the exact `e400e008` audit above: the profile-home-scoped store is exposed through profile-unscoped, revisionless admin routes; create overwrites collisions and returns the secret; enable automatically restarts the gateway. Profile import/export is also explicitly blocked: Desktop exchanges host paths, export has no bounded credential-free byte receipt/download, and import has no bounded preview/prepare/revision contract. Existing duplicate and whole-backup flows do not supply that authority. Learned-memory curation/import/export is explicitly blocked by the targeted audit above: memory ids are positional, mutations rewrite whole files without CAS, graph/detail payloads are unpaginated or unbounded, and the Star Map share code is visualization-only. Auxiliary administration is explicitly blocked by the exact `057dcdf23` audit above: the dedicated endpoint exposes only 12 revisionless slots and omits goal judge, while the generic config route returns raw nested API keys and has no allowlist, bounds, CAS, conflict, or postcondition. MoA administration is also explicitly blocked by the targeted `057dcdf23` audit: the revisionless whole-preset write has unbounded reference/cost controls and lossy round trips that erase per-slot token caps and disable an existing privacy filter. Talaria's gateway-declared session-only MoA preset selection remains invocation, not administration. |
| Git/System depth | Partial: core review and guarded mutations exist. Base/commit/ship context, dirty-worktree recovery, worktree-session integration, usage periods/daily/model/skill detail, and multi-gateway backend update orchestration remain. |
| Artifact completeness | Exact retained-source discovery is implemented with atomic no-dial snapshots, sequential reads, compacted rows, collision isolation, and explicit bounded/stale/failure state. Retained bodies use the exact captured client only after `/api/files` proves one canonical locked root; root and body responses are wire-bounded, authority is rechecked after awaits, and sign-out purges source-owned bytes. Hermes `session.list` still has no global continuation, transcript offsets remain informational under Talaria's 150-item cap, and gateways returning `locked_root: nil` remain fail-closed. Live certification remains open. |

## True platform exceptions

These are genuinely local Desktop behaviors and are not copied literally:

- Finder/Explorer reveal and native path pickers for the gateway host.
- Electron titlebar, placement, HUD, always-on-top, translucency, and local
  multi-window management.
- Launching a separate desktop terminal emulator or locally spawning backends.
- Replacing Talaria's signed binary; App Store/TestFlight owns iOS app updates.
- Native Windows PTY when the gateway itself has no supported PTY backend.

Remote Git, Projects, gateway maintenance, and the authenticated gateway PTY
are portable mobile equivalents, not exceptions.

## Certification still required

- Exact `40643cba` gateway or a documented compatible release, plus a second
  gateway for collision and detach tests.
- Real-device long-thread, background/foreground, Wi-Fi/cellular handoff,
  queued-send, room prompt, attachment, and reduced-motion checks.
- Debug APNs approval and final-response delivery were observed on the paired
  device, but a retained repository/PR certification report containing every
  field required by `TESTING.md` section 5 is still pending. Mention/routine,
  interrupted and profile-filter negative cases, exact-session cold-launch tap
  routing, and the complete TestFlight production matrix remain open.
- A supervisor that outlives the gateway for honest offline/recovered push;
  a sidecar on the same failed host is not sufficient evidence.
