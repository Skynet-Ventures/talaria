# Local assistant response alternatives

Talaria keeps regenerate alternatives as a bounded, device-local presentation
shelf on the current `ChatState`. Hermes Desktop may truncate its gateway
transcript while retaining the previous assistant response in client-only
branch-group siblings; the shelf mirrors that narrow behavior without using
the durable `session.branch` API or creating session-tree state.

## Identity and ordering

Every shelf is bound to the exact in-memory chat, source user message,
gateway/profile route, durable session key, and runtime session id. Repeated
prompt text is not identity. One source user owns one ordered group of whole
assistant response runs, oldest to newest. The canonical current response is
the implicit newest entry; archived runs are value copies containing text,
reasoning, tools, cards, failures, and admitted specialist evidence.

The newest response is selected by default. Previous/next controls stop at
the oldest and newest boundaries; they do not wrap. A normal Send first
returns the display to the canonical newest response.

## Regenerate lifecycle

`TranscriptActing` marks regenerate separately from edit/rewind while keeping
the existing truncate parameters unchanged. Before the destructive submit,
the complete old assistant run is staged against the exact current chat and
source row. The run becomes navigable only after an accepted submit receipt,
or after the existing transcript effect proof settles an ambiguous receipt.

A definite refusal restores the optimistic transcript and discards the stage.
An ambiguous receipt retains the stage and no navigable group until exact
proof; no mutation verb is replayed. Runtime/session/profile/lifecycle
replacement and unsafe authoritative hydration clear the shelf. The shelf is
not persisted across relaunch and is not inferred from archived database rows.

## Presentation and safety

The selected archived run is rendered in place with 44-point previous/next
controls and an accessible, localized `Response N of M` status. The view
labels archived content as a local snapshot and states that model context
remains the newest response. Switching selection invalidates and rebuilds the
local Transcript Find index. Copy and voice may use only the displayed,
sanitized projection.

Archived runs have no reaction, retry, edit/regenerate, branch, diagnostics,
generated-image or assistant-MEDIA network authority. Specialist cards are
rendered inert when their source is an archived snapshot. The current newest
response retains ordinary actions.

## Bounds

The pure `AssistantResponseAlternativesPolicy` bounds groups, archived runs
per group, messages per run, visible scalars, work items, and estimated UTF-8
bytes. It marks clipped runs/groups/state explicitly and never evicts half of
an alternative group. Existing Talaria specialist codecs continue to own
their field-specific admission and evidence contracts.
