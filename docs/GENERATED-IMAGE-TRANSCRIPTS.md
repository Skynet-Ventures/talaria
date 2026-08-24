# Generated-image transcript cards

Talaria renders a specialist transcript card only for the exact,
case-sensitive Hermes `image_generate` tool. This slice was checked against
Hermes `77d6c78cf52ec9f2c3245174cf763ff32a75d572`.

## Authority and admission

- A specialist result must be a JSON object, or a bounded serialized JSON
  object string, with explicit `success: true`.
- Display authority prefers `host_image`, then `image`.
  `agent_visible_image` is retained only as an exact echo-de-duplication value;
  it is never fetched or displayed by itself.
- Results with a missing/false success bit, missing or malformed image value,
  an unsupported/relative/control/bidi path, a private/credentialed URL, or a
  nonexact tool name remain generic tool evidence.
- Tool-result `data:` URLs are not admitted. Current Hermes produces a URL or
  absolute host path, and inline data cannot round-trip the retained tool and
  raw transcript bounds. The authenticated `/api/media` response remains a
  separately bounded data-URL envelope.
- A nameless completion can retain one bounded inert Codable candidate. Only
  an exact tool-call ID paired with a later exact `image_generate` start can
  promote it; another exact name discards it.

Raw stored rows, live events, and canonical stored/live overlays use the same
exact-ID pairing and monotonic failure rules. Sparse success replay cannot
erase a meaningful failure. Failed, malformed, and incomplete generations
stay in the generic tool presentation.

## Loading and presentation

Pending and ready cards use the argument's landscape/square/portrait hint;
decoded raster dimensions replace the hint after a valid image loads. The
card is a standalone ordered transcript run and completed images remain
visible in Quiet mode as assistant content. Transcript find indexes neither
the card nor tool payloads.

Gateway paths are fetched only from the exact producing gateway client through
authenticated, bounded, no-redirect `/api/media`. Publication is fenced by
gateway/profile, chat object, stored and live session IDs, connection
generation, routed/primary event generation, and profile lifecycle. Public
HTTP(S) images never auto-fetch: **Load image** is an explicit 44-point action,
uses no gateway credentials, rejects redirects and private/credentialed hosts,
and stays within the mobile byte/raster/frame/dimension budgets. A separate
explicit browser-open action is the fallback.

Ready images open an inspect sheet and expose the system share sheet for save,
share, or another installed destination. Controls use semantic text styles,
44-point targets, bounded VoiceOver status, and no shimmer or spatial
animation under reduced motion. The feature never auto-navigates.

After exact successful live/stored authority exists, Talaria removes only the
known `host_image`, `image`, and `agent_visible_image` values, including their
exact matching Markdown-image and `#media` link forms. Unrelated embedded
images and surrounding prose remain.

## Verification

`GeneratedMediaTests` and `GeneratedImageTranscriptTests` cover exact-name and
success authority, object/string decoding, path/URL/envelope bounds, controls
and bidi, Codable re-admission, raw/live/canonical exact-ID pairing,
completion-before-start, duplicate names, nonimage discard, monotonic failure,
exact echo stripping, source identity, decode/raster refusal, ordering, Quiet
mode, transcript-find exclusion, accessibility, and reduced-motion policy.
Real gateway and physical-device loading/share behavior remains a certification
item rather than a completed claim.
