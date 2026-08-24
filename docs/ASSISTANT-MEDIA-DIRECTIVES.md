# Assistant MEDIA directive projection

`AssistantMediaProjection` is a pure TalariaKit parser for assistant-authored
transcript text. It does not mutate or persist input, fetch media, or choose a
UI. Display, Copy, voice, and transcript find can consume the same ordered
projection later without independently exposing raw directive paths.

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
JSON-looking example lines as literal prose. This keeps documentation and
examples from becoming active media references.

Before normalization, percent decoding, lowercasing, or projection, the parser
enforces independent input UTF-8/scalar, total scan-work, directive-count, and
value UTF-8/scalar limits. NUL, unsafe controls, and bidirectional formatting
characters fail closed. A hard-limit result has no partial runs or references
and exposes `isClipped`; persisted source text remains untouched.

## Scope

This slice provides parsing and focused policy tests only. Transport,
authorization, media loading, cards, and display/Copy/voice/find wiring are
separate integration work.
