# Stored transcript page contract

`StoredTranscriptPage` is TalariaKit's bounded, raw REST contract for one
stored Hermes transcript page. It deliberately does not create `ChatMessage`s,
own a cache, or decide how a screen renders a “Show earlier” control. Those
are later AppModel/UI responsibilities.

## Request

`GatewayClient.storedTranscriptPage(_:)` calls:

```text
GET /api/sessions/{storedSessionID}/messages
  ?profile={profile}
  &limit={1...500}
  &offset={nonnegative reverse offset}
  &order=latest
  &include_compacted=true
```

Hermes' `latest` order measures `offset` backward from the newest display row,
but returns the selected rows in chronological order. Thus a tail at offset 0
can be retained as-is, and the page at its `nextOffset` is ready to prepend.
The client clamps limits to 500, offsets to a finite defensive maximum, bounds
the response body to 8 MiB, and rejects an over-cap or malformed row response
instead of truncating it into a false transcript.

`include_compacted=true` is the normal path: rows retained by in-place context
compaction are durable display history. Soft-deleted rewind rows remain a
server-side concern and are not inferred by TalariaKit.

## Identity and source fencing

Every page carries both ids:

- `requestedSessionID` is the durable/root stored id addressed by the caller.
- `resolvedSessionID` is Hermes' echoed, compression-resolved tip.

The root is never replaced with the tip. A legacy response that lacks
`session_id` falls back to the requested root and says
`resolvedSessionIDWasEchoed == false`.

When a caller has route authority, it creates a
`StoredTranscriptPageSource(gatewayID:profile:storedSessionID:)` and passes it
to `StoredTranscriptPageRequest(source:...)`. The returned page retains that
immutable tuple; `page.matches(source)` is exact. A future AppModel ledger can
capture this tuple before an async read and discard a completion after a
gateway/profile/session switch without relying on global mutable state.

Rows remain raw, chronological `StoredTranscriptRow`s. `row_id` and REST `id`
are recognized as the same durable identity only if they agree. No id is
synthesized for legacy rows, and duplicate claimed ids reject the page. This
makes overlap handling possible without text-based guesses. `isCompacted`
preserves the route's `compacted` evidence while retaining the full raw row.

## Pagination truth

Current Hermes echoes this shape:

```json
{
  "session_id": "resolved-tip",
  "messages": ["…chronological rows…"],
  "pagination": {
    "limit": 200,
    "offset": 0,
    "order": "latest",
    "returned": 200
  }
}
```

TalariaKit requires the echoed `limit`, `offset`, `order`, and `returned` to
match the exact normalized request and row count. If a peer additionally sends
`total`, `has_more`, `incomplete`, or `include_compacted`, those values are
validated and retained. Contradictory totals, continuation flags, or row counts
are protocol failures.

`Pagination.continuation` distinguishes three cases:

- `complete`: the older direction is proven exhausted (a short page or an
  explicit/total-backed false continuation).
- `more`: Hermes explicitly proves an older page exists.
- `unknown`: a full page has no `total` or `has_more`; it may be the final
  page, so `hasMore` stays false while `incomplete` remains true.

This distinction prevents a full response from being mistaken for a proof of
more history, while still allowing a later ledger to offer another safe read.
`reportedIncomplete` retains an explicit future-server warning separately.

Older gateways can return `{session_id?, messages}` with no `pagination`. The
page is accepted only within the same row/body bounds and is marked
`hasPagingMetadata == false`; compatibility treats it as one complete bounded
read, never an invitation to issue an unbounded page loop.
