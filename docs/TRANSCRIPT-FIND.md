# In-transcript find

Talaria’s find bar is a device-local navigation surface for the chat currently
open. It reads only the current `ChatState.messages` projection, makes no
REST/RPC call, searches no other bot or session, and writes nothing to Hermes.

## Search contract

- Only already-displayable foreground text from user and assistant messages is
  indexed. Markdown is projected through the same renderer used for painting,
  so visible link labels, lists, quotes, inline code, code blocks, and table
  cells remain searchable while raw delimiters and link destinations do not.
- System rows, cards, reasoning, tool names/arguments/results, timestamps, and
  metadata are excluded; searching never expands a hidden detail surface.
- Matching is locale-stable, case-insensitive, canonically equivalent,
  diacritic-sensitive, non-overlapping, and never crosses rendered segments.
- Query input is bounded before grapheme work (256 characters and 1 KiB of
  UTF-8). The index is bounded to 1,000 messages, 4,096 segments, and
  1,000,000 indexed characters, with per-message source/field/line caps and
  bounded match groups/occurrences. The raw message traversal budget is
  applied before author/empty-text filtering to the newest bounded window,
  which remains in chronological transcript order. Search independently
  bounds outer entries even when entries contain no searchable segments.
  Oversized raw Markdown is omitted as a whole rather than prefix-parsed, so a
  cutoff cannot expose a hidden link destination or turn a table fragment into
  paragraph text. A clipped index reports `+` in its count.

Oversized combining-mark, link, and line-flood inputs are omitted before
Markdown parsing. Query controls and bidirectional overrides are removed
within the input budget. The searchable model stores one count per matching
segment; the selected range is resolved lazily, keeping occurrence memory
bounded even when one segment contains many matches.

## Identity and interaction

Each match is addressed by durable transcript row id, author, rendered segment,
and occurrence. Rows without a durable id use their current message UUID as a
revision-scoped fallback. Duplicate text therefore remains distinct, and a
rehydration or earlier insertion does not move the selected occurrence to the
wrong message. Previous/next navigation is one-based, wraps at both ends, and
the selected occurrence is highlighted only in its current message.

Indexing and search are debounced, cancellable, and generation-fenced. A
changed query, transcript mutation, bot/source replacement, or stored/runtime
session change invalidates stale results and prevents an old row from driving
scroll. Find owns transcript scrolling while a match is selected: initial
anchoring and live-edge follow are suppressed, while closing find clears its
query/highlight without changing the user’s scroll position.

Selecting the sole match is still an active selection (ordinal `0`); its
explicit navigation revision drives a centered scroll/recenter on every
Previous or Next activation, and jump-to-latest remains hidden while find owns
the scroll.

Find controls expose at least a 44-point hit target and status text reports an
accessible one-based position. When reduced motion is enabled, find
transitions use opacity/no spatial movement; normal motion may use the standard
slide/fade animation.
