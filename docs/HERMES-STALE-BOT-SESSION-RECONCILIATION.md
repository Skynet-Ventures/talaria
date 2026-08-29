# Hermes stale Bot-session reconciliation

This slice audits and ports the Bot Mode session sweep from exact Hermes
authority `057dcdf236f8a6a26721c10fcc6ccb72726e272a`. It does not change gateway,
notification, messaging-platform, room-composer, member-hold, transcript timing,
or Live Activity behavior.

## Exact upstream authority

- `apps/desktop/src/plugins/hermes-bots/plugin.js`, especially
  `isBotModeSweepTitle`, `isBotModeSweepCandidate`, and
  `sweepBotProfileSessions` at the exact pin above.
- `apps/desktop/src/plugins/hermes-bots/tests/hide-bot-chats.test.mjs` at the
  exact pin above.
- `1b18442f36099765354d60c390d569155e662b64` introduced the five-minute
  creation grace and fail-closed timestamp parsing.
- `8fca54f9f15cc3b5a12a16b7d03e838df4bd72a7` pinned the 299/300-second
  boundary and missing-timestamp behavior.

Hermes enumerates each roster bot's own profile with a 200-row limit, considers
only visible rows named exactly `Bot Chat`, exactly `Agent Inbox`, or prefixed
`Group: `, and calls `session.set_hidden` only after a valid epoch-seconds
creation timestamp is at least five minutes old. Missing, malformed,
millisecond-scale, and future timestamps stay visible. A subsequent visible-only
list makes the operation idempotent.

## Talaria portable contract

Talaria preserves the title and timestamp contract and adds the authority proof
required by a reconnecting, multi-gateway mobile client:

1. A claim is an exact source-qualified `(gateway, profile)` roster route. The
   retained client-pool connection, connection generation, profile lifecycle
   token, and primary-client generation/identity are captured together.
2. `session.list` is issued only to that retained source and exact profile. The
   result must be a complete, authoritative page: `has_more == false`, a present
   `total` equal to the original pre-cap row count, and fewer than 200 rows. The
   pre-cap count is retained, so 201 raw rows with a lying `total: 200` cannot
   pass after client truncation. Legacy, partial, inconsistent, saturated, or
   same-source duplicate-ID inventories are retained unchanged.
3. Canonical Bot Chat roots and resolved tips plus exact current room-member
   session IDs are `mustHideOwnedSessionIDs`: if a complete visible inventory
   contains one, Talaria repairs it to `hidden:true` regardless of age or title,
   preserving the preexisting exact-owned behavior. The roster's recent durable
   session and the profile's current live chat are separately protected from the
   stale-orphan heuristic. This protects scratch work without leaving legacy
   current Bot plumbing visible, including across a room rename.
4. A valid candidate must have a nonempty ID, an exact plumbing title, and a
   finite positive epoch-seconds timestamp no later than `now` and at least 300
   seconds old. Unknown, zero, nonfinite, future, and millisecond-scale values
   are non-candidates.
5. A session ID claimed by more than one exact source is retained and disclosed
   as a collision. The hide mutation repeats the exact profile on the wire;
   only an old, unprotected orphan unique to one source may be hidden.
6. Source authority is re-proved after inventory fetch, before mutation-lease
   acquisition, after lease acquisition, after `session.set_hidden`, after
   lease release, and between candidates. A source/profile/client/generation
   race stops that plan. The pool mutation lease prevents connection adoption
   during the mutation itself.
7. Inventory failures, stale authority, incomplete inventories, collisions,
   and mutation failures are non-destructive and reach bounded per-gateway
   diagnostics without session content, profile names, IDs, or transport
   secrets.
8. One main-actor reconciliation gate coalesces overlapping connect/reconnect
   sweeps. Repeated complete sweeps are idempotent because hidden rows are not
   returned by the visible inventory.

## Implementation and proof

- Runtime and policy:
  `Packages/Talaria/Sources/TalariaUI/AppModelLive+BotSessionReconciliation.swift`
- Connect/reconnect hook:
  `Packages/Talaria/Sources/TalariaUI/AppModelLive+CanonicalChat.swift`
- Focused tests:
  `Packages/Talaria/Tests/TalariaUITests/BotSessionReconciliationTests.swift`

The focused suite proves exact profile routing, valid/invalid timestamp
admission, the 299/300 boundary, legacy visible canonical/current-room repair,
current scratch/recent-chat protection, rename/deleted-room outcomes, incomplete
and saturated inventory retention, lying over-cap totals, same-source duplicate
IDs, idempotence, cross-profile ID collision retention, source mutation after
an await, mutation-time authority loss, duplicate claims, and
mutation/inventory failure behavior.

## Deliberate mobile strengthening

Desktop's sweep is fire-and-forget and accepts the returned prefix even when a
larger inventory may exist. Talaria refuses destructive inference unless the
bounded page proves it is the whole visible inventory, and it protects known
live ownership before applying the shared title heuristic. This is a stricter
admission rule, not a divergent title or age contract.
