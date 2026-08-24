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
- A nameless completion or standalone result carrying the exact image name can
  retain one bounded inert Codable candidate. Only an exact, nonempty
  tool-call ID paired with a retained or live exact `image_generate` invocation
  can promote it; another exact name discards it.

Candidate object work is capped at 32 fields and serialized result strings use
a 20,000-byte ceiling derived from the retained tool-payload limit. Sources and
the at-most three echo values are byte/scalar checked before normalization. Codable decode
checks the unkeyed echo count and each decoded string. `JSONDecoder` necessarily
allocates a single string before the field-level check; the enclosing bounded
transcript/persistence envelope remains the outer allocation boundary.

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
gateway/profile, stable message identity, exact gateway tool ID and output,
chat object, stored and live session IDs, connection generation,
routed/primary event generation, and profile lifecycle. These facts are
re-proved before the request, after bytes arrive, and while the final retained
connection lease is held.

Public HTTP(S) images never auto-fetch: **Load image** is an explicit 44-point
action that contacts the displayed external host. The ephemeral request sends
no gateway credentials or cookies, rejects redirects and URL credentials,
rejects legacy numeric IP spellings, and performs a pre-connect DNS check that
fails if any answer is private, loopback, link-local, multicast, or unspecified;
the resolver traversal is capped at 64 answers.
That separate DNS lookup cannot pin URLSession's later connection address, so a
DNS change between preflight and connect remains a documented residual risk.
A separate explicit browser-open action remains available.

ImageIO must identify the bytes as a single-frame PNG, JPEG, WebP, GIF, or BMP
within the byte/dimension/pixel budgets. MIME and suffix never admit TIFF, ICO,
SVG, HEIC/HEIF, animation, or unknown bytes. The detected format supplies the
share filename extension; bytes are never mislabeled PNG.

Ready images open an inspect sheet and expose the system share sheet for save,
share, or another installed destination. Load failures retain the hinted aspect
surface and expose a fresh-authority 44-point **Retry** action. Controls use
semantic text styles, 44-point targets, polite VoiceOver loading/status updates,
and no shimmer or spatial animation under reduced motion. The feature never
auto-navigates.

After exact successful live/stored authority exists, Talaria removes only the
known `host_image`, `image`, and `agent_visible_image` values, including their
exact matching Markdown-image and `#media` link forms. The visible transcript,
Copy, voice reply and local find projections share this rule. Unrelated bytes,
indentation, blank lines, code, tables, embedded images and prose remain exact.

## Verification

`GeneratedMediaTests` and `GeneratedImageTranscriptTests` cover exact-name and
success authority, object/string decoding, path/URL/envelope bounds, controls
and bidi, Codable re-admission, raw/live/canonical exact-ID pairing,
completion-before-start, duplicate names, nonimage discard, monotonic failure,
exact formatting-preserving echo stripping, source identity, legacy/private IP
and injectable DNS refusal, real TIFF/ICO and raster-bomb refusal, typed share
format, ordering, Quiet mode, transcript-find exclusion, accessibility, retry,
and reduced-motion policy.
Real gateway and physical-device loading/share behavior remains a certification
item rather than a completed claim.
