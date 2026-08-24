# Whole-turn transcript activity

Authority audited: Hermes Desktop `origin/main` at
`057dcdf236f8a6a26721c10fcc6ccb72726e272a`, specifically
`turn-activity.ts`, `turn-activity.test.ts`, `status.tsx`, and the tail mount in
`assistant-message.tsx`.

Talaria keeps this feature inside the current chat transcript. It is unrelated
to ActivityKit and never creates a lock-screen Live Activity.

## Portable behavior

- A newly observed running turn shows `Working` until its first visible text,
  reasoning, interim, or tool boundary.
- After visible output, an unnamed activity row returns only after two quiet
  seconds. Its elapsed value starts at the last locally observed boundary.
- Admitted provider-wait frames, tool drafting, and compaction use bounded
  named phases. Drafting waits 200 ms before reveal; compaction retains the
  whole-turn clock when Hermes supplied or Talaria locally observed it.
- A visible running tool in Advanced transcript detail narrates its own wait,
  so the generic row is suppressed. Quiet detail does not hide upstream
  activity merely because the underlying tool is omitted.
- Approval and bridge prompts suppress duplicate activity narration while the
  user is expected to respond.

All admission is for the exact current `(gateway, runtime session, bot)` route.
Terminal events, an authoritative idle observation, session replacement, stop,
watchdog cleanup, and chat teardown clear live activity through the same turn
lifecycle that owns elapsed timing. Reconnect can replay retained assistant
output, but the wire has no timestamp for its last visible boundary: Talaria
therefore starts a fresh quiet observation at resume instead of inventing
historical elapsed time. Stored transcript history never hydrates live
activity.

Labels are capped at 160 Unicode scalars, collapse whitespace, and remove C0,
C1, and bidirectional formatting controls before presentation. The row is
read-only, exposes a single accessibility label, uses Dynamic Type, and adds no
motion.
