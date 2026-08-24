# Hermes core-runtime delta: `40643cba..057dcdf`

This is the machine-checkable mobile-parity ledger for Hermes core agent,
runtime, cron, and tooling behavior. The canonical per-commit evidence is the
[new-row TSV](../parity/hermes-core-runtime-delta-40643cba-057dcdf.tsv) and the
[metadata/cross-reference manifest](../parity/hermes-core-runtime-delta-40643cba-057dcdf.json).
The checker rejects omissions, duplicates, path drift, parent-union drift,
predecessor-ledger drift, endpoint-tree drift, and pinned-slice drift.

## Scope correction and boundary

The original audit note said “31 paths / 112 commits.” The path total was an
arithmetic error: the exact manifest is **30 paths** (18 `agent/` paths, 3
`cron/` paths, 8 `tools/` paths, and `run_agent.py`) and still derives exactly
**112 commits**. The manifest is deliberately not broadened to invent a
thirty-first path.

The scope excludes `tui_gateway/**`, `hermes_cli/web_routers/**`, and
`hermes_cli/web_server.py`; those are owned by the client-wire ledger. It also
does not claim or alter the active durable host-update recovery work.

The upstream input is the exact reachable range:

```
40643cbaf9b767af146694131ffb8f8160f25e1c..057dcdf236f8a6a26721c10fcc6ccb72726e272a
```

For every reachable commit, the checker evaluates every parent with
`git diff --name-only <parent> <commit> -- <exact manifest>`. A merge enters
the inventory if the union of those parent diffs touches the manifest. This is
why merge evidence is retained instead of relying on a first-parent path log.
The final-net tree is separately verified with SHA-256 blobs at both endpoints.

## Exact partition

| Partition | Count | Pinned evidence |
| --- | ---: | --- |
| New core-runtime ledger rows | 94 | [TSV](../parity/hermes-core-runtime-delta-40643cba-057dcdf.tsv) |
| PR85 authority cross-references | 7 | `879078e3ef54d1af2d6e0208105c0cf93c71979c` |
| PR90 client-wire cross-references | 11 | `69d066bd3c213b8de69fa78735f20327f05f7123` |
| Total every-parent scoped commits | 112 | exact upstream range above |

The PR85 cross-references are
`0404020f7b944398db529a0d09726a0e5f3c06a4`,
`052513f65b6db0b6328dfe8d2c7efb21849fdc3f`,
`334bcbac93b044d29da88507af4ee8d6415d5c2b`,
`723dbda0414ce2d8fdc86283b76302537d91b724`,
`98f6fc549a338b3903b6e86e31b8b0210671b991`,
`a2da0ab797edf5e7ca7d3f64591facbbc37ec7f2`, and
`e26d91dc11ea32f2f1af2c9778d424172f834431`.

The PR90 cross-references are
`12395e57b4a3e7fa3610408c043011ec7ba2f8ad`,
`1a95d0d58e59669f8dc1b0b955e372411f6be410`,
`3e5e4c5d20006e0f29f5389224ee0265e444dd3f`,
`3f075d41dd593191b4bcf11fb608b72d698c3d3e`,
`7ca19874593becb81aa742aae5800eac8c9088d2`,
`a5b326a471d2e5cdf6741fbfd0913c85f6866aaa`,
`abf87e7248b0218a56fb7f05be8379c7d19dfa7f`,
`d524cc9a16e13be42762984d21c1e4d19fbce24e`,
`d65b7d0760235210f5cf29c0eaaf98fe10078546`,
`ec5e369fe68f4abb3188767c751d6166d2139f0a`, and
`fcea2175e23fdeb95f7e615f0cc7d6e5f3f485b0`.

The JSON manifest has the exact source-path union for all 112 hashes. It also
holds the cross-reference path unions, so a cross-reference cannot hide a
core-runtime path that was not covered by its predecessor ledger.

## Mobile relevance and narrow slices

| Cluster | New rows | Upstream source/symbols | Disposition | Narrow Talaria dependency base |
| --- | ---: | --- | --- | --- |
| R01 compaction and transcript continuity | 14 | `agent/context_compressor.py::salvage_grown_transcript`, `agent/conversation_compression.py::CompressionCommitFence`, `agent/native_compaction.py::prune_pre_checkpoint_items` | portable, covered | `codex/rich-transcript-hydration` @ `d5bad705f1c19d716eea4abb8de1ba4206659dde` |
| R02 review and subagent lifecycle | 10 | `agent/background_review.py::cancel_background_review_for_live_turn`, `agent/review_engine.py::build_review_task`, `agent/subagent_lifecycle.py::SubagentState` | portable, covered | `codex/subagent-live-presentation` @ `07e3c68c6d2010edb00fd63414b31c878af2b8d2` |
| R03 tool/turn/provider settlement | 14 | `agent/tool_executor.py::_pairing_tool_call_id`, `agent/codex_runtime.py::make_codex_app_server_event_bridge`, `agent/gemini_native_adapter.py` | portable, covered; one test-only row | `codex/rich-transcript-structured-output` @ `fdee839fdc1fda8a4a8233ff5e459795d09752b0` |
| R04 failure, retry, interrupt | 7 | `agent/error_classifier.py::classify_api_error`, `agent/error_surface.py::build_error_surface_from_exception`, `agent/conversation_loop.py::_is_interpreter_shutdown_error` | portable where surfaced; host/desktop where annotated | `codex/current-hermes-error-surface-v2` @ `928205afd3e5f9a708f462a55b2613ee6633f3ae` |
| R05 cron execution and retirement | 18 | `cron/jobs.py::get_due_jobs`, `_write_missed_oneshot_diagnostic`, `cron/scheduler_provider.py::fire_overdue_jobs` | portable where wire exists; 3 upstream-contract blocked; 1 superseded | `codex/current-hermes-cron-push-isolation` @ `28e9f713e4aa46fc78fbaa1ef19abf0892ff3c8e` |
| R06 terminal/process/host lifecycle | 10 | `tools/terminal_tool.py::_current_session_key`, `tools/process_registry.py::ProcessRegistry`, `tools/code_execution_tool.py` | host-only; one test-only row | `codex/mobile-gateway-pty` @ `c7f64a6462d7e2c19a6714eca7d0fe8c5de4f699` is UI context, not a port of host ownership |
| R07 provider and host runtime | 8 | `agent/agent_runtime_helpers.py`, `agent/codex_runtime.py::run_codex_app_server_turn` | host-only / verify on host | no application runtime slice required |
| R09 merge-parent integration | 13 | all exact merge-parent path unions in the JSON manifest | merge integration only | validate constituent slices |

The ledger's `classification` and `disposition` columns deliberately separate
portable mobile behavior from gateway/desktop host behavior. In particular,
terminal ownership, process registry, provider credentials, CLI output, and
SDK request transforms are not app-runtime ports merely because they touch an
agent/tool path.

## One-shot retirement observability is blocked upstream

The three blocked hashes are
`b37a5bc0dfd83be4d557369f6ca05736c15333b3`,
`ed8ee9a871d9e804e6f19102abfee17a3b2683b8`, and
`29c5a12e04497dfb18d5432f9416f837bfe80919`.

At target `057dcdf`, `cron/jobs.py::_write_missed_oneshot_diagnostic` writes a
best-effort `save_job_output(...)` artifact. The `get_due_jobs` grace path then
calls that helper and removes the record with `raw_jobs.remove(rj)`. The hosted
misfire path in `cron/scheduler_provider.py::fire_overdue_jobs` only logs and
skips the same out-of-grace one-shot. None supplies a typed gateway event or a
durable list/detail retirement reason for Talaria to render. The checker proves
all four source assertions at the pinned target, so the disposition is
`upstream-contract-blocked`, not an unimplemented mobile feature.

The minimal upstream contract is a source-qualified, durable retirement reason
on cron list/detail data or an explicit typed retirement event. Once it exists,
the cron slice can consume it without broadening agent, terminal, or host
lifecycle scope.

## Reproduce

```sh
python3 scripts/check_hermes_core_runtime_delta.py
python3 scripts/check_hermes_core_runtime_delta.py \
  --checkout /Users/joshua/talaria/hermes-agent-upstream
python3 -m unittest scripts/test_check_hermes_core_runtime_delta.py -v
make verify
```

`make verify` invokes the inherited `talaria-verify` gate. The checker itself
is intentionally standalone so its upstream checkout and merge-parent proof
remain explicit and reproducible.
