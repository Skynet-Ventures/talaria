# Structured terminal and code output

Talaria gives Hermes' exact `terminal` and `execute_code` tools a bounded
structured presentation. A result is promoted only when the tool name matches
one of those names and the result contains an object with `stdout` and/or
`stderr`. Ordinary result prose, unknown tool names, and strings that merely
mention JSON fields without being valid bounded encoded objects remain generic
tool output.

The two streams are retained separately. ANSI parsing consumes terminal
controls and keeps only safe display text plus the supported foreground and
bold SGR state. OSC/DCS/SOS/PM/APC strings, CSI commands other than SGR, C0/C1
controls, and bidirectional overrides are removed. Tabs and safe newlines are
preserved; CRLF and lone CR normalize to a newline. Clipboard text is the
already-sanitized visible stream, never the raw gateway string.

Admission is finite before rendering work begins:

- parser work is capped at 100,000 Unicode scalars per stream;
- visible stream text is capped at 10,000 scalars, including its truncation
  marker;
- styled output is capped at 256 segments;
- residual metadata is tree-bounded before JSON serialization and capped at
  4,096 scalars;
- the generic result remains within the existing 20,000-character payload cap.

Control-heavy and combining-mark inputs therefore cannot create unbounded
parser, segment, or serialization work. If a control prefix consumes the raw
budget before any safe scalar is visible, the stream still exposes a bounded
truncation marker and diagnostic rather than silently disappearing.

When Hermes serializes a result into a string, Talaria decodes only a valid,
bounded JSON object string. Invalid JSON, prose that merely mentions
`stdout`, and JSON-looking prefixes remain generic text; arrays and scalar JSON
values also stay on the generic path. A nameless live completion may retain a
bounded generic result and an inert structured candidate, but that candidate
is promoted only after the same exact tool id receives an exact-case
`terminal` or `execute_code` start. A wrong-case or non-terminal start
discards the candidate while preserving generic result and failure evidence.

`stderr` is a channel label, not an implicit failure. Failure state comes only
from explicit protocol evidence: a meaningful `error`, `is_error: true`, or a
non-empty structured error value. `null`, `false`, numeric zero, and an empty
error string are benign. Residual fields such as `exit_code` and `pid` remain
available below the streams without duplicating `stdout` or `stderr` in the
generic payload.

Live completion and retained-history hydration use the same model. Results are
paired only by exact `tool_id`/`tool_call_id`; a missing raw `tool_name` is
filled from the exact paired assistant call, never from a same-named call.
Repeated completion frames merge channels field by field: a present newer
stream or residual replaces its counterpart, while an omitted field preserves
the evidence already retained. A later benign replay cannot erase a recorded
failure or replace its structured evidence.

Canonical history overlays use the same exact execution identity and preserve
source provenance. Sparse live output may update `stdout` while stored
`stderr`, residual metadata, and meaningful failure evidence remain visible.
The typed stream, segment, structured output, and tool-call models are
`Codable` for snapshot and hydration compatibility, including older tool-call
records that do not contain structured output.

VoiceOver receives a single-line preview capped at 500 scalars. Selectable
transcript text and copy retain the complete admitted stream independently.
This is a presentation-only projection: it does not execute commands,
interpret cursor movement, or mutate gateway or filesystem state. Physical
gateway/device visual certification remains a separate release check.
