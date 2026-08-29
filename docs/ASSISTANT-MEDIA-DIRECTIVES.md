# Assistant MEDIA directive projection

`AssistantMediaProjection` is a pure TalariaKit parser for assistant-authored
transcript text. It does not mutate or persist input, fetch media, or choose a
UI. Display, Copy, voice, and transcript find consume the same ordered
projection without independently exposing raw directive paths.

## Grammar and output

The introducer is exact and case-sensitive: `MEDIA:`. Horizontal whitespace
after the colon is optional. A value is either a non-whitespace token or a
same-line value enclosed by matching single quotes, double quotes, or
backticks. The public projection contains ordered `.text(String)` and
`.media(Reference)` runs. Text runs preserve every non-directive byte.

Each reference retains the exact unquoted value, zero-based ordinal, Desktop
extension classification, bounded display name, stable non-authoritative
fingerprint, and half-open UTF-8 range of the complete directive in the source.
Classification ignores query and fragment suffixes and uses this exact map:

- image: `bmp gif jpeg jpg png svg webp`
- audio: `flac m4a mp3 ogg opus wav`
- video: `avi mkv mov mp4 webm`
- everything else: file

For streaming text, an unclosed quoted value or an unquoted token at the live
end remains exact prose and sets `hasPendingDirective`. A closing quote,
horizontal delimiter, or completed line makes the candidate safe to project.

## Deliberate safety divergence

Desktop scans permissively. Talaria intentionally treats directives inside
backtick or tilde fenced code, same-line inline-code spans, blockquotes, and
bounded escape-aware JSON object/array string spans as literal prose. This
keeps documentation and examples from becoming active media references.

Before normalization, percent decoding, lowercasing, or projection, the parser
enforces independent input UTF-8/scalar, total scan-work, directive-count, and
value UTF-8/scalar limits. NUL, unsafe controls, and bidirectional formatting
characters fail closed. A hard-limit result has no partial runs or references
and exposes `isClipped`; persisted source text remains untouched.

## Transport and lifecycle

Cards never load automatically. A local card requires an explicit Load action;
a public URL action also names the external host before contact. Producing-
gateway audio/video uses the authenticated, bounded, no-redirect streaming
route. Images and generic files use the authenticated, bounded, no-redirect
managed-file read route. Public URLs use an ephemeral no-cookie/no-credential
session, reject redirects, private address literals, and private DNS answers,
and are downloaded to a bounded local file before playback.

Every load is tied to the exact route, profile, stored/live session, chat and
message identity, visible source text, directive ordinal/value, retained
client, credential, lifecycle, and event generation. These are re-proved before
the request, after bytes arrive, and immediately before publication. Remote DNS
can still rebind after preflight; no gateway credentials are sent to the public
host, and a redirect is never followed.

Raster bytes use the existing format/frame/dimension/pixel policy. SVG remains
file-only. Audio/video must expose a bounded number of real tracks, finite
duration, and (for video) positive transformed dimensions within the pixel
budget. Playback never starts automatically, only one item owns playback, and
players pause on app inactivity, source mutation, chat/card disappearance, and
replacement by another item. Only `talaria-assistant-media-*` temporary folders
created by this feature are removed by its cleanup path.
