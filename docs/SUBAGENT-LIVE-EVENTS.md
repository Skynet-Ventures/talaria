# Subagent live-event foundation

Talaria now has a bounded, foreground-only reducer for Hermes parent-session
`subagent.*` events. This is model and routing groundwork only: it does not add
a screen, controls, a child-session opener, persistence, or reconnect replay.

## Wire contract and identity

The authoritative relay is Hermes
`tui_gateway/server.py:_on_tool_progress` (the `subagent.*` block around lines
6597–6747 in the pinned source). Talaria recognizes `start`, `thinking`,
`tool`, `progress`, `complete`, and `text`; an unknown suffix or a malformed
identity remains a raw `GatewayEvent` and cannot create a row.

Every branch key is exactly:

```
(gateway_id, parent_runtime_session_id, subagent_id)
```

`goal`, `model`, tool labels, task indexes, and all visible names are display
evidence only. Parent/child attachment uses only `parent_id` within that exact
keyspace. A child received before its parent remains retained and attaches when
the matching parent arrives. Missing, cyclic, or too-deep edges become marked
orphans; Talaria never guesses a parent from a name.

`child_session_id` is retained as `SubagentChildSessionReference`, including
the gateway id, parent runtime session id, subagent id, and child session key.
It is deliberately not modeled as a child runtime sid: Hermes documents it as
the durable key a later surface would pass to `session.resume`.

## Admission and reducer rules

The typed decoder admits the current identity/hierarchy/status, task, model,
token/API, duration/cost, file, output-tail, text, and summary fields. Identity
strings are strict and un-clipped. Display strings are control-safe and capped;
invalid fields are ignored rather than clearing earlier evidence. Current hard
limits are:

| Item | Limit |
| --- | ---: |
| Live nodes | 128 |
| Derived hierarchy depth | 8 |
| Identity/model/text | 256 / 256 / 4,096 Unicode scalars |
| Files per read/write list | 40 (1,024 scalars each) |
| Output-tail rows / preview | 8 / 600 scalars |
| Toolsets | 32 |
| Counter values | 1,000,000,000,000 |
| Duration / optional USD cost | 1 year / $1,000,000,000 |

New nodes beyond the cap are rejected while already-admitted nodes remain
unchanged; the immutable snapshot records truncation. Node ordering is stable:
parents precede attached children, siblings keep first-admitted order, and
exact key fields provide the final deterministic tiebreaker. Transport sequence
numbers reject a stale sequenced update; a synthetic unsequenced test frame
cannot overwrite sequenced live evidence.

Terminal outcomes (`completed`, `failed`, `error`, `timeout`, `interrupted`,
`cancelled`, `stopped`) are sticky; backend-native `canceled` is normalized to
`cancelled`. Later progress cannot resurrect a terminal branch. An absent
status on `subagent.complete` defaults to `completed`, while an explicit
unknown or still-active (`queued`/`running`) completion status fails closed to
`failed`. Valid later completion evidence can still fill sparse
summary/counter fields without changing the established outcome.

The upstream delegation producer currently computes optional `cost_usd`; the
current gateway relay block forwards the integer rollups and duration but does
not yet serialize that optional field. Talaria accepts a finite bounded
`cost_usd` if/when the relay supplies it, but deliberately does not infer one.

## Source fence and lifecycle

`AppModel` routes a typed event only after all of these checks:

1. live mode;
2. a nonempty source gateway id;
3. exact runtime-session-to-bot ownership on that gateway;
4. the current `ChatState` still owns that same gateway/session; and
5. an active `SubagentSourceFence` for that exact gateway and parent runtime
   session.

Session bind activates the fence. Rebind, `session.reclaimed`, stored-session
drop, primary reset, and retained-secondary reset tear down only the matching
gateway/session fence. A same short sid on another gateway, or another parent
session on the same gateway, survives unchanged.

This is intentionally **foreground live parity only**. Hermes has no
authoritative `subagent.snapshot` or `subagent.list` contract from which a new
runtime session could prove the prior live tree. On reconnect/rebind Talaria
therefore clears only the exact old fence and starts fresh; it does not invent
recovery or persist advisory branch state. Reconnect persistence requires an
upstream snapshot/list contract with source and parent-session provenance.
