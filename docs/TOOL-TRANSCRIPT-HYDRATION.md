# Typed tool transcript hydration

Talaria reconstructs generic tool calls from both Hermes transcript shapes:

- resume display projections retain a completed, explicitly incomplete tool
  row when raw output or a stable call id is absent;
- bounded raw history pairs assistant `tool_calls` and `role: tool` results
  only by exact `tool_id` / `tool_call_id` and keeps arguments/results typed;
- an active resume may mark unmatched calls running only in the newest
  assistant tool-call batch. Older unmatched batches always settle, while a
  matching result in the newest batch remains settled.

The raw supplement is limited to 200 rows and 1 MiB before JSON decode. Tool
payloads also enforce Unicode-scalar, structure-depth, node, and display caps
before rendering. Presentation admission preserves ordinary tabs/newlines but
removes C0/C1 and bidirectional spoofing controls. Malformed or unpaired
records remain visible with a bounded diagnostic; Talaria never pairs them by
tool name, prose, or database row id.

Transcript pages are normalized to oldest-first before the 200-row cap, so a
newest-first 201-row response drops its oldest row. Duplicate exact
`tool_id`/`tool_call_id` values are ambiguous evidence: every colliding call or
result stays visible with a diagnostic and no result is guessed. Liveness
rehydration uses the same raw-supplement-then-graft path as foreground reads;
when a longer page has no durable anchor, protected terminal-failure rows keep
their UUID and failure evidence, while fetched canonical text/tool state wins
and unmatched protected rows are inserted in order. Stale protected IDs are
pruned after publication.

Publication remains source-qualified across every suspension. Primary reads
retain the exact app client. Secondary reads additionally retain the pool-slot
generation and routed event-pump generation, then re-check route, profile,
runtime session, durable session, chat identity, lifecycle, and source after
the await. Existing protected terminal failures and newer queue/attachment
rows participate in the normal transcript merge and cannot be erased by a raw
supplement.

The mobile generic renderer groups two or more calls behind a compact summary.
Each call exposes status, bounded arguments, result, provenance, and
diagnostic through a 44-point disclosure/copy surface with VoiceOver labels
and reduced-motion expansion. Generated media, diffs, search results, and
other specialist renderers are intentionally separate follow-up slices.
