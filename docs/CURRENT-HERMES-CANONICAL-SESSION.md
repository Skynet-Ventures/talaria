# Current Hermes canonical-session wire contract

Audit target: Hermes `a4f16e3fefdc537ef2e029006048444b9531839a`.

Current `profiles.list {include_sessions:true}` resolves each profile's exact
`Bot Chat` title registry row server-side and returns `canonical_session`:

- key absent: sessions were not requested or the gateway predates the current
  and legacy registry contracts; the answer is inconclusive;
- literal `null`: no eligible registry row exists (missing, archived, or an
  internal tool/kanban source);
- object: the durable registry `id`, live compression `resolved_id`,
  `root_title`, leaf `title`, bounded preview and activity/count fields. Current
  objects are admitted only when the authoritative root is exactly `Bot Chat`,
  or the exact leaf is `Bot Chat` when root evidence is absent/empty.

A present malformed object is a separate invalid state, not an omission. It
cannot publish canonical preview/identity and cannot fall back to unrelated
`last_session` text. Primary roster refreshes preserve the last authoritative
durable/resolved guard identity across omitted or invalid answers; explicit
`null` alone clears it.

A present `canonical_session` is authoritative over any simultaneously echoed
legacy `preferred_session`, including explicit null or malformed data. Talaria
decodes `preferred_session` only when the current key is absent, for older
gateway compatibility. That legacy field described a specifically requested
durable pointer and retains its separate decode policy; it is never allowed to
override any present current field. Normal profile listings no longer send the removed
`preferred_session_ids` request field.

The independent recovery lookup is exact and source-qualified:
`session.list {profile, title:"Bot Chat", include_hidden:true}`. Current Hermes
returns at most the title-registry row and retains its compression tip. Older
gateways may ignore `title`, so Talaria filters the bounded returned window by
an exact leaf/root title match before accepting a row; admission is capped at
the legacy server's 200-row default before model construction. A nonempty
window with no exact match proves the parameter was ignored (or the response
was malformed), so it raises a typed indeterminate error and can never
authorize canonical birth; a truly empty exact response remains a definitive
registry miss. The current
exact-list row carries `id` and `resolved_id`; the shared stored-session model
also retains `root_title` and `last_active` when a gateway supplies them.
`session.title` names a live runtime after creation; method-not-found and write
failures remain typed gateway errors rather than being folded into an
unsupported success.

Current canonical identity is no longer stored in
`ui_meta["hermes-bots"].chat`. Talaria still decodes that legacy pointer so an
older gateway can be displayed safely, but current metadata projections never
write it and no open, preview, guard, lifecycle, or routing path uses it as
authority. Bot-row opens always exact-list the source-qualified registry;
lookup failure propagates and never authorizes creation.

Birth is single-flighted per source-qualified bot. It rechecks the registry,
creates hidden, applies the exact `Bot Chat` title before local adoption, then
submits the kickoff. A method-not-found title RPC falls back to the eager create
title for older gateways. A supported title receipt must be non-pending and
return the exact title; pending/mismatched receipts re-query and adopt the
registry winner or fail without kickoff. Lookup/create/title failures preserve
the current scratch transcript and queue. A failed kickoff preserves the named row and binding,
while ambiguous acceptance retains its exact route/durable/runtime lease for
read-back reconciliation. The roster projection carries durable and resolved
ids for `/new`/`/reset` protection; explicit Sessions and Inbox bindings remain
scratch bindings, while every bot-row tap re-resolves the registry.
