# Transcript backfill in Talaria

The first stored-transcript read remains the existing 200-row newest tail.
When Hermes proves (or cannot rule out) older history, Talaria can expose a
small **Show earlier** control at the top of the chat.

## Authority

The UI ledger is bound before a read starts to the exact:

```text
(gateway ID, profile, durable/root stored session ID, ChatState, client, generation)
```

It never turns Hermes' echoed compression-resolved `session_id` into the
request target. That value is retained only as observed tip evidence; later
pages keep addressing the same durable root.

Every completion must pass both `StoredTranscriptPage.matches(source)` and the
existing transcript source-authority check again. A gateway/profile/session,
client-generation, or in-memory-chat replacement therefore cancels or drops a
late page instead of publishing it to a same-named replacement chat.

## Paging and overlap

Pages use `order=latest` and are chronological within a response. The ledger
prepends them and keeps their raw `StoredTranscriptRow`s. It only removes an
overlap when the durable `row_id`/`id` identity matches exactly; it never uses
message text, timestamps, or generated `ChatMessage` UUIDs as identity.

An identity-less page seam is rejected rather than guessed. This is deliberate:
an append can land between reverse-page reads, so an id-less row could be a
duplicate or a distinct repeated prompt. A non-suffix overlap is also rejected
because it cannot be placed chronologically without inventing ordering facts.

The accepted raw ledger is then sent through the existing transcript hydrator
as one chronological sequence. That preserves tool call/result pairing and the
ordered-part, generated-media, and response-alternative invariants already
implemented by the chat surface.

## User-visible continuation truth

| Gateway evidence | Top-of-chat state |
| --- | --- |
| Explicit/short final page | `Beginning of conversation` |
| Explicit `has_more` / total-backed continuation | `Show earlier` |
| Full page without continuation metadata | `Show earlier` + “Older messages may be available.” |
| Failed bounded page | `Show earlier` + retry copy |
| 2,000 retained raw rows with more server history | `Earlier history limit reached` |

`unknown` is intentionally not converted into either “more” or “complete.”
Only one bounded page is read per user action, and only one read may be active
for an exact source at once. The foreground raw ledger additionally stops at
2,000 rows so repeated reads cannot turn the transport's much larger offset
ceiling into unbounded main-actor projection work.

## Scroll behavior

Before requesting a page, ChatView records the first message row intersecting
the reader viewport. After a successful prepend it scrolls that exact row back
to the top without animation. A drag, find navigation, or source replacement
cancels that pending restoration. Backfill never invokes the live-tail
follow/jump-to-bottom path, so it does not steal manual reader ownership.
