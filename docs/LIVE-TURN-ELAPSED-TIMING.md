# Live turn elapsed timing

Talaria presents the current assistant turn's elapsed wall time inside the
chat transcript. This is an in-app transcript feature only. It does not start,
update, end, or otherwise depend on an iOS Live Activity, Dynamic Island, push
notification, or lock-screen surface.

## Hermes authority

Audited against Hermes `origin/main` at
`057dcdf236f8a6a26721c10fcc6ccb72726e272a`:

- `apps/desktop/src/app/session/hooks/use-prompt-actions/submit.ts` seeds
  `turnStartedAt` at submit time.
- `message.start` preserves that origin or starts one when the turn was first
  observed remotely.
- `session.info` and `session.resume` accept gateway `turn_started_at` epoch
  seconds so a currently running turn can keep its real origin across a view
  switch or reconnect.
- `apps/desktop/src/app/session/hooks/use-message-stream/index.ts` computes a
  rounded, minimum-one-second `durationS` before clearing the live origin and
  places it on the final assistant message.
- Historical messages with no observed start do not receive a duration. The
  reusable Desktop timing hook explicitly distinguishes a watched duration
  from history that arrived already complete.

## Talaria contract

For a fresh local submit, Talaria starts the clock at the UI submit
boundary, before `message.start`. A start event preserves that earlier origin;
an independently observed remote start begins at receipt time. A valid
`session.info` timestamp seeds an otherwise absent clock, while an
authoritative resume timestamp replaces any local estimate; both pass the
same finite/clock-bound validation first.

While the exact chat is running, a compact semantic-font, monospaced clock is
mounted at the transcript tail and ticks once per second. It has no animation
and therefore requires no Reduced Motion exception. On terminal
`message.complete`, Talaria clears the live origin, rounds the observed wall
time to the nearest second with a one-second minimum, and displays the value
on the newest assistant row owned by the current turn floor. Error completion
clears the same clock; it annotates an assistant row only when one exists.

Timing is bounded to seven days, with five minutes of tolerated future clock
skew. Values outside that window remain absent rather than producing an
unbounded or negative counter. Formatting matches Desktop: `59s`, then
`1:00`, with total minutes continuing beyond one hour.

## Historical and lifecycle truth

`ChatMessage.turnDurationSeconds` is optional. Transcript hydration does not
populate it because the stored Hermes transcript contract carries message
timestamps but not whole-turn duration. Older encoded messages decode it as
nil. Talaria never subtracts adjacent message timestamps or uses a session's
creation/last-active time as a substitute.

A first-submit bind from no runtime session may preserve its locally observed
origin. A reconnect, profile/session replacement, idle resume, invalid
timestamp, watchdog abandonment, or authoritative stop clears live timing
unless the current resume provides a valid `turn_started_at`. Thus a new turn
cannot inherit a prior chat's elapsed value and a loaded historical answer
cannot acquire a fabricated duration.
