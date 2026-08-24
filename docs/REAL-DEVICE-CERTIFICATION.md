# Talaria real-device certification report

This is the reusable report for physical-device evidence. Copy this file into
the PR/release evidence location, keep the stable case ids unchanged, and fill
one result per tested build and environment. The template itself proves
nothing: every row begins **not run**.

Automated tests establish policy and wire behavior; they do not replace an iOS
device, a real compatible Hermes gateway, APNs, or a network transition. Do not
mark a case pass from source review, simulator behavior, a synthetic `/test`
notification, or memory of an earlier build.

## Report identity

| Field | Value |
|---|---|
| Report date/time and timezone | TODO |
| Tester | TODO |
| Talaria commit (40-character SHA) | TODO |
| Build configuration and build number | TODO (`Debug` / `TestFlight`; never combine) |
| App bundle id | TODO |
| Device model | TODO |
| iOS version | TODO |
| Gateway commit/version | TODO |
| Gateway source id / profile(s) | TODO (redact credentials, not identity labels needed to reproduce) |
| Second gateway commit/version, when used | TODO |
| Relay commit/version and supervisor | TODO |
| APNs environment | TODO (`sandbox` for Debug or `production` for TestFlight) |
| Starting network | TODO |
| Accessibility settings | TODO (Reduce Motion, Dynamic Type, VoiceOver) |

Allowed result values are `PASS`, `FAIL`, `BLOCKED`, and `NOT RUN`. A pass must
include timestamped evidence plus enough log/session identifiers to correlate
the phone with the selected gateway. A blocked result names the missing
external prerequisite; it is not a pass. Record secrets and full push tokens
only as redacted hashes or suffixes.

## Result index

| Case id | Area | Result | Evidence link / retained artifact | Notes |
|---|---|---|---|---|
| `DEV-THREAD-001` | Long transcript | NOT RUN | TODO | |
| `DEV-TOOL-001` | Retained/live specialist tool transcripts | NOT RUN | TODO | |
| `DEV-PARTS-001` | Ordered multimodal/tool transcript parts | NOT RUN | TODO | upstream producer required |
| `DEV-LINEAGE-001` | Durable session lineage and compression | NOT RUN | TODO | upstream producer required |
| `DEV-FIND-001` | Transcript find navigation and mutation | NOT RUN | TODO | |
| `DEV-ALT-001` | Regenerate response alternatives N/M | NOT RUN | TODO | |
| `DEV-MEDIA-001` | Generated image transcript cards | NOT RUN | TODO | |
| `DEV-MEDIA-002` | Assistant MEDIA image/audio/video/file cards | NOT RUN | TODO | |
| `DEV-LIFE-001` | Background/foreground, idle | NOT RUN | TODO | |
| `DEV-LIFE-002` | Background/foreground, active turn | NOT RUN | TODO | |
| `DEV-QUEUE-001` | Explicit durable Queue FIFO/edit | NOT RUN | TODO | |
| `DEV-QUEUE-002` | Queue relaunch/offline/uncertain | NOT RUN | TODO | |
| `DEV-ROOM-001` | Room sliding and hard deadlines | NOT RUN | TODO | |
| `DEV-ROOM-002` | Room prompt relaunch/recovery | NOT RUN | TODO | |
| `DEV-ATTACH-001` | Photo/PDF/file/clipboard sources | NOT RUN | TODO | |
| `DEV-ATTACH-002` | Attachment failure/relaunch | NOT RUN | TODO | |
| `DEV-A11Y-001` | Reduce Motion | NOT RUN | TODO | |
| `DEV-A11Y-002` | VoiceOver | NOT RUN | TODO | |
| `DEV-LAYOUT-001` | Rotation/layout restoration | NOT RUN | TODO | |
| `DEV-NET-001` | Wi-Fi → cellular handoff | NOT RUN | TODO | |
| `DEV-NET-002` | Cellular → Wi-Fi handoff | NOT RUN | TODO | |
| `DEV-GATEWAY-001` | Saved-gateway detach/credential/client replacement | NOT RUN | TODO | |
| `DEV-PROFILE-001` | Profile lifecycle and stale-callback fencing | NOT RUN | TODO | |
| `DEV-PTY-001` | PTY input/output/resize | NOT RUN | TODO | |
| `DEV-PTY-002` | PTY background/reattach/expiry | NOT RUN | TODO | |
| `PUSH-DBG-001` | Debug approval positive | NOT RUN | TODO | sandbox only |
| `PUSH-DBG-002` | Debug response positive | NOT RUN | TODO | sandbox only |
| `PUSH-DBG-003` | Debug mention and cold-launch tap | NOT RUN | TODO | sandbox only |
| `PUSH-NEG-001` | Cron/routine isolation | NOT RUN | TODO | no Talaria push expected |
| `PUSH-NEG-002` | Interrupted and profile-filter negatives | NOT RUN | TODO | no Talaria push expected |
| `PUSH-NEG-003` | Non-Talaria gateway/Slack isolation | NOT RUN | TODO | no Talaria push expected |
| `PUSH-PROD-001` | TestFlight production approval/response | NOT RUN | TODO | production only |
| `PUSH-PROD-002` | TestFlight production negative/tap routing | NOT RUN | TODO | production only |

## Case procedures

### `DEV-THREAD-001` — long transcript integrity

1. Open a source-qualified Bot Chat with a retained transcript large enough to
   exercise pagination/compaction and mixed markdown, code, table, and tool rows.
2. Scroll repeatedly to both ends, trigger a new streamed response, leave and
   re-enter the chat, then terminate and relaunch Talaria.
3. Pass only if row order and identity stay stable, no duplicate/blank jump is
   introduced, jump-to-bottom is honest, and the exact gateway/profile/session
   remains selected. Record transcript size, session ids, memory warning/crash
   observations, screen recording, and gateway timestamps.

### `DEV-TOOL-001` — retained/live specialist tool transcripts

1. Retain and then stream exact-id file-edit diff, structured terminal/execute,
   and web-search tool pairs, including pending, success, malformed, failed,
   duplicate, orphan, oversized, and unknown-tool evidence.
2. Switch chats and sources during one live completion, then relaunch and load
   the same stored session.
3. Pass only if stored/live overlay preserves one stable ordered row per exact
   tool identity, specialist cards admit only their bounded contracts, failure
   and malformed evidence remains visible through the generic fallback, source
   mutation cannot publish stale specialist state, and Quiet/Advanced mode does
   not hide meaningful failures. Retain raw redacted event order, stored rows,
   screenshots, and source/session identifiers.

### `DEV-PARTS-001` — ordered multimodal/tool transcript parts

1. Against a gateway containing the reviewed ordered-parts producer, run one
   logical turn with reasoning, prose, an exact tool call/result, an internal
   continuation nudge, image/file evidence, and terminal prose. Retain the turn,
   reconnect, and reopen it after app relaunch.
2. Repeat with append, seal, and terminal replace frames; then inject clipped,
   malformed, oversized, unknown-kind, duplicate-tool, cross-source, signed-URL,
   inline-data, and local-path evidence.
3. Pass only if live and retained views preserve the same source order and exact
   tool identity, the terminal replacement never erases earlier commentary,
   clipped/malformed replacements preserve prior evidence, legacy copy/find/media
   projections stay compatible, references remain inert until an authorized
   action, and a foreign gateway cannot publish. Retain redacted raw frames,
   stored rows, screenshots, source/session ids, and the exact producer commit.

### `DEV-LINEAGE-001` — durable session lineage and compression

1. Against a gateway containing the reviewed normalized-lineage producer,
   create a root, branch from an intermediate turn, compress the parent, branch
   again, compress the rotated parent tip, and page the session list across the
   lineage rows.
2. Open every row from Talaria, switch gateways with colliding profile/session
   titles, reconnect, relaunch, and repeat while one page is delayed.
3. Pass only if the UI groups by durable root/parent identity without title or
   recency inference, preserves branch attachment across repeated compression,
   opens the exact source-qualified stored session, rejects stale/foreign pages,
   and represents incomplete/saturated paging honestly. Retain normalized RPC
   rows, screenshots, exact ids, gateway labels, and the producer commit.

### `DEV-FIND-001` — transcript find

1. Open find with the hardware and software keyboard; exercise previous, next,
   wrap, zero/one/many matches, keyboard dismissal, and a match inside a long
   transcript above and below the viewport.
2. While one match is selected, append streamed text, replace stored history,
   switch chats, toggle VoiceOver and Reduce Motion, and manually scroll before
   invoking the next result.
3. Pass only if focus and match count are honest, one match re-centers without
   oscillation, mutation invalidates stale ranges, manual scrolling retains
   ownership until an explicit find navigation, wrapped navigation is stable,
   and announcements/motion obey the active accessibility settings.

### `DEV-ALT-001` — regenerate response alternatives

1. On one exact Bot Chat turn, regenerate three times and verify one response-
   local navigator advances through four complete versions. Repeat on an older
   turn with later conversation content present, then trigger one definite
   refusal and one controlled lost-receipt/effect-proof recovery.
2. Exercise multi-row reasoning/tool/failure responses, generated-image and
   assistant-MEDIA cards, Transcript Find, copy, ordinary Send, chat/source/
   profile/session replacement, background/foreground, VoiceOver, Dynamic Type,
   and Reduce Motion.
3. Pass only if controls render after the associated assistant run, stop at
   both boundaries, preserve one stable group across repeated regeneration,
   prune only turns actually removed by older-turn truncation, and never expose
   a navigable version before accepted/effect-proven mutation. Archived versions
   must be presentation-only: no retry/reaction/branch/diagnostics/media fetch or
   other network action. Find must index only the selected visible version,
   ordinary Send must return to newest, lifecycle replacement must clear the
   shelf, and relaunch must not reconstruct client-local versions. Retain the
   exact route/session ids, redacted gateway receipt/effect order, screenshots,
   VoiceOver announcements, and screen recording.

### `DEV-MEDIA-001` — exact generated-image transcript cards

1. Produce one successful `image_generate` result as a gateway path and one as
   a public URL; separately retain an orphan/unmatched result and a failed call.
2. Exercise pending, loading, public-host permission, failure/Retry, loaded,
   full-screen inspection, share/save, chat switch, background, relaunch,
   VoiceOver, and Reduce Motion. Include private and legacy-numeric IPs, a
   redirect, and a controlled DNS-answer change.
3. Pass only if exact successful invocation/message/source authority renders a
   card, orphan or failed evidence remains inert, public bytes are never fetched
   before the explicit action, no gateway credential or redirect reaches the
   public host, unsafe/animated/oversized raster evidence fails closed, and
   source mutation cannot publish stale bytes. The hinted aspect must stay fixed
   through pending/loading/permission/failure and update only from validated
   decoded dimensions; status changes must be announced without decorative
   motion. Private/legacy IPs and redirects must fail closed. Record the
   preflight-only DNS rebinding residual, gateway request logs, public-host
   request headers, screen capture, and the saved file type.

### `DEV-MEDIA-002` — generic assistant MEDIA cards

1. In one assistant transcript, emit ordered prose around gateway-local image,
   audio, video, and generic-file `MEDIA:` directives. Repeat with public URLs,
   duplicates, quoted paths containing spaces, and literal examples inside
   fenced/inline code, blockquotes, and JSON-looking example lines. Retain one
   exact protected fixture and one ordinary prose fixture so the bounded parser
   boundary is explicit rather than implying arbitrary inline JSON shielding.
2. Confirm every card is inert until **Load** is tapped. Exercise image inspect,
   audio play/pause/rebuffer, native video controls, file share/open, Retry,
   cancel during load/metadata, starting B while A plays, background/foreground,
   chat switch, source/session replacement, VoiceOver, and Reduce Motion.
3. Pass only if prose/card ordering matches stored and live text, examples never
   become requests, gateway images/files use managed reads while audio/video use
   the stream route, public hosts are named and receive no gateway credentials,
   only one player owns playback (including waiting/buffering), canceled owned
   files are removed, stuck metadata work stays bounded, and copy/voice/find omit
   raw directive paths without altering user-authored literal `MEDIA:` text.
   Retain correlated gateway/public-host logs, accessibility recording, and a
   temporary-folder before/after check.

### `DEV-LIFE-001` — idle background/foreground

1. Open an idle chat, background for at least 60 seconds, then foreground.
2. Pass only if the app reconnects without minting or selecting a different
   session, stale UI is labelled while offline, and an ordinary open chat does
   not start a Live Activity. Record lifecycle and connection logs.

### `DEV-LIFE-002` — active turn background/foreground

1. First finish operational tool work inside the 20-second admission grace and
   prove no Live Activity starts. Then run tool work beyond 20 seconds,
   background during the work, wait for at least one update, and foreground
   before or after end.
2. Pass only if transcript recovery is source/session exact, the short case
   remains silent, the sustained operational Live Activity starts/updates/ends
   once after admission, and no five-minute clock is shown merely for a normal
   answer. Record lock-screen video and correlated events.

### `DEV-QUEUE-001` — explicit Queue FIFO and edit

1. While a turn is running, use the distinct **Queue** control for at least
   three text-only prompts. Edit the middle ready row and remove another.
   Separately edit a parked row and a retry-exhausted row, hold an edit
   reservation on the FIFO head, and attempt edits while rows are submitting,
   accepted, and uncertain.
2. Let the current turn reach authoritative idle.
3. Pass only if normal Send remains steer-first, queued rows drain in final
   FIFO order one at a time, no optimistic assistant/user duplicate appears,
   and the edited text—not the old text—is submitted. Editing must preserve row
   identity, order, and creation time; retry-exhausted edits reset to ready,
   parked edits remain parked, active edit reservation blocks the head, and
   submitting/accepted/uncertain edits are rejected. Record stored/runtime
   session ids, row-state transitions, and gateway receipt/event ordering.

### `DEV-QUEUE-002` — relaunch, offline, Stop, and uncertainty

1. Exercise a queued row across app relaunch and a gateway outage; separately
   press Stop while queued work exists and induce one ambiguous submit receipt.
2. Pass only if relaunch retains exact source/profile/stored-session authority,
   Stop parks local rows, retry exhaustion remains visible, and ambiguous work
   becomes uncertain rather than replaying blindly. Attach before/after UI and
   gateway logs. Attachments must be refused by the durable Queue.

### `DEV-ROOM-001` — room deadline policy

1. Run a room member into approval and clarify states near the sliding
   180-second deadline and separately near the 20-minute hard cap.
2. Pass only if busy/awaiting-user extends the sliding deadline without
   exceeding the hard cap, blocked work never becomes a pass, and timed-out
   durable work remains harvestable. Record room id, member route, runtime
   session id, request id, and timestamps.

### `DEV-ROOM-002` — room relaunch and mutation recovery

1. Background and terminate Talaria with an open room prompt; relaunch and
   answer it. Repeat while renaming, removing a member, and disbanding.
2. Pass only if immutable room/member-session identity survives legitimate
   recovery, stale prompt UI cannot mutate retired identity, and shared
   projection/tombstones converge without resurrecting a room.

### `DEV-ATTACH-001` — physical picker sources

1. From the native source picker attach an image through PhotosPicker, a PDF,
   a generic file, and a clipboard image where supported by the device. Talaria
   does not currently expose a direct camera-capture action.
2. Submit each to the exact intended bot and one room.
3. Pass only if source choices are legible and accessible, staged filenames and
   previews are correct, bounded payloads reach only the selected route, and
   room export produces the intended bytes. Record sizes/types and screenshots.

### `DEV-ATTACH-002` — failure and relaunch

1. Exercise cancellation, an over-limit payload, unsupported/failed staging,
   background during staging, and relaunch before submission.
2. Pass only if failure is visible, no partial attachment is silently sent,
   recovery does not migrate to another source/session, and normal composer
   recovery does not convert attachment work into durable Queue authority.

### `DEV-A11Y-001` — Reduce Motion

1. Enable Reduce Motion before launch and visit roster/Active Now, chat/tool
   work, bot profile/model picker, rooms, attachment picker, and PTY.
2. Pass only if essential state remains visible without continuous decorative
   motion, no motion-dependent action becomes unreachable, and Live Activity
   state remains intelligible. Record settings and screen capture.

### `DEV-A11Y-002` — VoiceOver

1. With VoiceOver enabled, complete roster search/open, Active Now open, model
   selection, explicit Queue/edit, room prompt, attachment source selection,
   profile delete confirmation (cancel before destructive completion), and PTY
   escape/dismissal.
2. Pass only if reading/focus order is coherent, icon-only controls and model
   choices have useful labels/state/hints, dynamic notices are announced once,
   and no action traps focus. Record the spoken labels and failures.

### `DEV-LAYOUT-001` — rotation and restoration

1. Rotate between supported orientations on chat, compact bot profile/model
   picker, room prompt, attachment picker, and PTY; repeat during keyboard use.
2. Pass only if content remains reachable without horizontal clipping, sheets
   and focus recover, PTY resize reaches the correct session, and no route or
   draft changes. Record before/after screenshots and resize events.

### `DEV-NET-001` / `DEV-NET-002` — network handoff

1. With a streamed turn and then a queued row, hand off Wi-Fi → cellular for
   `DEV-NET-001`; repeat cellular → Wi-Fi for `DEV-NET-002`.
2. Include a second retained gateway and colliding profile names in one pass.
3. Pass only if the connection pool does not enter a restart loop, events and
   unread remain source-qualified, exact sessions recover, no accepted work is
   replayed, and stale clients cannot publish after replacement. Record iOS
   network state, gateway process uptime/restart count, socket logs, and routes.

### `DEV-GATEWAY-001` — detach and retained-client replacement

1. With transcript/media loading and an approval outstanding on gateway A,
   remove its saved gateway entry. Repeat by replacing A's credential and by
   reconnecting the same source id with a newly retained client while gateway B
   and a colliding profile name remain available.
2. Pass only if A's in-flight callbacks cannot publish after detach or
   replacement, no operation falls through to B, the retired credential is not
   reused, approval UI cannot answer the wrong source, and reconnect converges
   without a process restart loop. Retain connection generations, request ids,
   redacted credential suffixes, and gateway logs.

### `DEV-PROFILE-001` — profile lifecycle

1. Prove primary-profile delete refusal. On a non-primary foreign-source
   profile, exercise rename, duplicate, delete cancel, a failed delete/rollback,
   and successful delete while transcript/media work is in flight.
2. Pass only if every mutation stays on the exact route, failures restore an
   honest roster state, successful retirement cleans source-owned navigation
   and pending state, profile lifecycle generation fences old callbacks, and a
   same-named profile on another gateway is untouched. Retain before/after
   profile ids, route ids, mutation receipts, and stale-callback logs.

### `DEV-PTY-001` — PTY interaction

1. Open the authenticated terminal on a non-default source/profile, type and
   paste input, generate ordered output, rotate/resize, and dismiss locally.
2. Pass only if bytes remain ordered, resize is reflected remotely, credentials
   never appear in UI/log evidence, and all operations stay on the captured
   source/profile.

### `DEV-PTY-002` — PTY lifecycle

1. Background and foreground within detached TTL, then repeat after the token
   may have expired and after a gateway reconnect.
2. Pass only if valid reattach preserves the session, potentially expired
   reattach asks rather than overpromises, source replacement fences old bytes,
   and local cleanup is described honestly because Hermes exposes no remote
   terminate endpoint.

## Push certification

Debug and TestFlight are separate certifications. Never use a sandbox result to
pass a production row. Use real Hermes events; relay `/test` is presentation
diagnostics only. Each positive result records event kind, bot display name and
raw profile, source/gateway id, stored/runtime session ids where applicable,
redacted device-token suffix, APNs id/status, timestamps, notification title,
body, avatar/icon behavior, tap action, and foreground/background/cold-launch
state. Each negative result retains a quiet observation window and relay logs
showing why no Talaria fan-out occurred.

### Debug / sandbox positive cases

- `PUSH-DBG-001`: trigger a real approval request. Require correct bot display
  name (not `default: approval required`), exact source/session action routing,
  and successful approve/deny handling. Then hold simultaneous approvals whose
  request/session labels collide across two sources, retire one prompt/profile,
  and invoke its stale action. Pass only if request-id fallback cannot answer
  the surviving or wrong approval and the stale action fails closed.
- `PUSH-DBG-002`: trigger one non-interrupted non-empty final response through
  the `post_llm_call` producer. Require the bot display name without the
  `: response ready` suffix, source/session tap routing, and no duplicate legacy
  `long_task` notification.
- `PUSH-DBG-003`: trigger a real mention/A2A notification, then cold-launch from
  its tap. Require the exact owning gateway/profile/session and bot avatar when
  the payload/OS supports it; otherwise record the explicit icon limitation.

### Debug negative cases

- `PUSH-NEG-001`: run a Slack-delivered cron/routine. Observe beyond its normal
  completion window. Pass only when it produces no Talaria notification; a
  synthetic routine presentation probe does not count.
- `PUSH-NEG-002`: exercise an interrupted turn and a profile excluded by the
  device `profile_filter`. Neither may fan out. Also show that the process-wide
  `TALARIA_PUSH_EVENTS` allow-list is not misreported as a per-device kind
  preference.
- `PUSH-NEG-003`: produce messages on a Slack/non-Talaria gateway or sidecar
  path that is not a Talaria live session. Pass only when no Talaria push is
  generated and relay logs identify the isolation decision. A sidecar that
  dies with the gateway cannot prove offline/recovered delivery.

### TestFlight / production APNs

- `PUSH-PROD-001`: install the identified TestFlight build, prove the token is
  registered for `production`, and repeat real approval plus final-response
  positives with background and terminated app states.
- `PUSH-PROD-002`: repeat cron/routine, interrupted, profile-filter, and
  non-Talaria gateway negatives, then cold-launch from a real production push
  and verify exact-session routing.

Production passes require production APNs response evidence. A Debug install,
development provisioning profile, sandbox token, or TestFlight UI screenshot
without a real event is insufficient.

## Summary and sign-off

| Question | Answer |
|---|---|
| Failed case ids | TODO |
| Blocked case ids and external reason | TODO |
| Regressions filed | TODO |
| Build safe to call device-certified? | TODO — only `yes` when every required case for the release scope passes |
| Independent reviewer / date | TODO |

Document exclusions explicitly. An untested feature remains
implemented-but-uncertified; it must not be relabelled a platform exception.
