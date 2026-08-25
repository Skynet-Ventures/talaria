# Bounded file-edit diff rendering

Authority target: the repository-governed Hermes Desktop snapshot
`057dcdf236f8a6a26721c10fcc6ccb72726e272a`.

Talaria recognizes explicit `inline_diff` / `diff` fields only for the exact,
case-sensitive Hermes names `edit_file`, `patch`, and `write_file`. Live
`tool.complete` frames and exact raw stored-history rows use the same
`ToolFileDiff` decoder. Pairing and
overlay use only the exact gateway tool-call id; a matching tool name, path,
or patch body is never identity.

Hermes may omit the name from a sparse completion or retained role:`tool` row.
Talaria bounds and sanitizes that explicit diff material immediately but keeps
it inert. Only an exact-ID `tool.start` or paired assistant call with one of the
three exact names may promote it into the visible specialist model. Uppercase
or otherwise aliased names are not admitted.

The read-only mobile boundary retains at most 20,000 Unicode scalars and 400
display lines. It strips ANSI/OSC/DCS/SOS/PM/APC/CSI, C0/C1, and bidi display
controls before line statistics or rendering, removes Hermes' `┊ review diff`
chrome, and independently bounds/sanitizes the visible path. Non-string and
empty explicit fields remain malformed evidence. Nothing in this feature
parses Markdown, executes text, or mutates a file.

When exact live and stored copies overlap, the live diff body remains current.
A richer stored path may fill only an absent live path. A stored failed state
is retained only when PR57's meaningful protocol-error decoder established it;
words such as “error” in summaries, prose, or successful file contents remain
non-errors. Once an exact live completion establishes meaningful failure,
its failed state, result, summary, and diff remain monotonic against a later
sparse non-error replay for that invocation.

File diffs split surrounding generic tool runs and render as literal,
selectable monospaced lines with bounded +/- counts, truncation/malformed
diagnostics, copy, semantic Dynamic Type styles, VoiceOver line labels,
44-point disclosure/copy targets, and reduced-motion-aware disclosure.

Focused tests cover live ordering/replay, exact raw pairing, id-less results,
asymmetric exact-ID overlay, strict failure evidence, bounds, hostile controls
and paths, literal classification, Codable persistence, run partitioning,
selection, Dynamic Type, VoiceOver summaries, touch targets, and reduced
motion policy. Live gateway and physical-device visual certification remain
open.

This slice intentionally excludes ANSI-rendered generic output, structured
output, generated media, transcript find, web-search cards, and every
non-file-edit specialist.
