# Talaria durable composer queue

Talaria persists explicit follow-up prompts as text-only rows keyed by
`(gateway id, profile, stored session id)`. Runtime Hermes session IDs are
never durable queue authority. The envelope lives at
`Application Support/Talaria/composer-queue-v1.json`, is atomically replaced,
and uses complete-until-first-user-authentication protection on iOS.

The queue is bounded to 100 entries, 8,000 characters per entry, 80,000 total
characters, and a 2 MB persisted envelope (the byte cap is enforced on both
read and write). A source session drains in FIFO order; at most two unrelated
source sessions drain concurrently. The drain resumes the exact stored
session and sends only after that exact session reports the same non-empty
stored session ID, idle with no in-flight turn, approval, or clarify state. It
holds the exact pooled connection and profile-traffic leases across that
resume/submit boundary, so a managed-cloud replacement or profile lifecycle
fence cannot retarget the wire call. A source/client or receipt ambiguity
becomes `uncertain` and is never replayed.

## State and ownership

- `local/ready` is device-owned and may automatically drain.
- `parked` is device-owned but paused. Stop parks local rows synchronously
  before its interrupt begins.
- `submitting` has crossed the local wire boundary and is not editable,
  removable, parked, or replayed by another path.
- `accepted/gateway-owned` is an accepted mirror, not local work. Hiding it
  only hides the local panel record; it does not cancel Hermes work.
- `uncertain` is retained for explicit acknowledgement and never auto-replays.
- `retry-exhausted` has spent its persisted automatic retry budget. It is still
  editable and can be explicitly resumed, but it is not automatically
  replayable or claimable. Relaunch and reconnect do not reset it or make it
  replayable again.

Malformed, oversized, or invalid envelopes fail closed. A persisted
`submitting` row normalizes to `uncertain` on the next launch. A transient
protected-file read does not overwrite the original envelope. A protection
attribute or size failure before replacement leaves the prior atomic envelope
intact and rolls back the in-memory mutation; the queue can be retried after
storage recovers.

## Explicit Queue and editing

Normal Send remains steer-first while a turn is running. The separate Queue
control admits only raw text and creates no optimistic user bubble. Attachments
are refused because Hermes attachment state is session-global and cannot be
proven to belong to a later queued turn.

The mobile queue panel provides a text-only editor for `local/ready`,
`parked`, and `retry-exhausted` rows. It has no attachments, Send, or Steer
controls. Editing preserves the row ID, source key, FIFO order, and creation
time; it updates text and update time. A parked row remains parked. Editing a
retry-exhausted row resets it to `local/ready` with a fresh automatic-failure
budget. `submitting`, gateway-owned, and uncertain rows reject edits.

Only this explicit durable Queue control creates replayable durable work.
Ordinary Send, steer-first delivery, and their legacy in-memory recovery path
never import a prompt into the durable queue after the fact.

An editor reserves one exact source-qualified row. That reservation blocks the
FIFO head rather than letting a later prompt leapfrog stale text. Save is one
atomic store transaction; validation or persistence failure leaves the saved
row untouched. Cancel, successful save, and failed save release the reservation.

## Lifecycle fences

Profile rename/delete parks source rows before the remote mutation. Once the
remote result is authoritative, rename migrates and resumes those rows under
the new qualified route; delete removes the exact source rows. A failed durable
commit leaves the lifecycle fenced rather than guessing a replay destination.
Gateway sign-out/removal takes the existing lifecycle traffic gate before it
retires the gateway's durable rows; if removal cannot persist, rows are
quarantined or the source remains intact for retry.

One definitive pre-wire refusal (including HTTP/RPC 409 without a matching
`message.start`) consumes one automatic attempt and yields the lane; repeated
flushes/reconnects spend the remaining bounded attempts. A 409 with a matching
pre-receipt `message.start` is execution proof and retires only that exact
submitting row. Hermes does not expose a client idempotency key,
prompt-submit lookup, or client-authoritative cancel for a lost receipt. Those
are protocol limits, so Talaria deliberately records uncertainty rather than
trying text-based replay.
