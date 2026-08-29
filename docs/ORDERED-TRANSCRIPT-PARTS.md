# Ordered transcript parts

Talaria consumes Hermes' additive `parts_version: 1` transcript contract while
keeping the legacy `text`, reasoning, and tool fields authoritative for older
gateways and persistence snapshots.

The consumer admits at most 64 parts, 256 nested JSON nodes, depth 8, 65,536
Unicode scalars, and 256 KiB of encoded envelope data. Unknown and malformed
parts remain inert evidence; image, audio, and file references do not create
new file or network authority. Exact tool-call IDs are required before an
ordered tool part can reuse an existing interactive `ToolCall`.

Live `append`, `replace`, and `seal` updates are source-fenced like legacy
message events. Adjacent stable-ID streaming text frames are compacted before
the part-count limit. A complete terminal replacement may consolidate ordinary
live segment rows only when it is unclipped, contains no malformed marker, and
its bounded text parts exactly cover the already-rendered segment text. The
combined raw text continues through the existing echo and `MEDIA:` projections;
otherwise prior interim/tool rows remain visible.

Mobile renders structural parts in admitted order with existing thought, text,
and tool surfaces. Plain reasoning-then-text envelopes stay on the established
legacy rendering path. That same path is also retained when whole-message
generated-image echo suppression or `MEDIA:` projection changes the text, so
display, find, copy, and voice continue sharing the existing safe projection.
