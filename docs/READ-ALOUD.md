# Per-message Read Aloud

Talaria carries Hermes Desktop's explicit assistant-message **Read Aloud**
action as a mobile-first context-menu action. It is deliberately separate from
Voice Mode and auto-speak: opening a chat, receiving a reply, or leaving the
app idle never starts speech and never starts a Live Activity.

## Spoken-content boundary

Only a completed, non-streaming assistant row that is currently present in the
displayed transcript is eligible. The input is
`AssistantMediaProjection.copyText(in:)`, not the raw transcript envelope, so
reasoning, tool arguments/results, MEDIA references, generated-image echoes,
hidden alternatives, user text and system rows are outside the speech path.
`ReadAloudPolicy` then applies scalar/byte/work bounds and removes fenced code,
raw URL destinations, Markdown tables/decoration, emoji, controls and bidi
formatting. Empty, clipped, failed and hostile projections fail closed.

## Runtime authority

One `ReadAloudRuntime` lease owns the operation. It binds:

- source-qualified bot plus exact gateway/profile;
- exact in-memory chat UUID and message UUID;
- the exact sanitized text and its stable fingerprint;
- exact `GatewayClient` identity and primary/pool connection generation; and
- the profile-lifecycle generation captured before provider work.

Those facts are re-proved after synthesis and again immediately before phone
playback. Stop, a newer Read Aloud request, leaving the chat, transcript/text
replacement, reconnect/client replacement, source teardown, or profile
rename/delete invalidates the old generation. A late provider completion is
therefore discarded rather than spoken into a different chat or source.

## Phone audio ownership and transport

Read Aloud and Voice Mode share one main-actor audio coordinator. A Read Aloud
request cannot take the speaker while Voice Mode owns it. Starting Voice Mode
stops an active one-shot read before it claims the microphone/speaker pair;
stale releases cannot clear a newer owner.

TTS uses the selected profile's authenticated `POST /api/audio/speak` request.
The response is wire-bounded, redirects are rejected before credential replay,
the data URL is size-preflighted before base64 allocation, decoding is strict,
and only an allowlisted audio MIME whose body/header declarations agree is
accepted. User-facing failure copy is fixed and non-secret.

The active row alone shows a compact Dynamic Type-aware control with a 44-point
minimum target: **Preparing audio — Stop** or **Stop reading aloud**. VoiceOver
receives explicit labels, hints, and preparing/reading/stopped announcements;
reduced-motion users get a static preparing glyph.

Hermes reference (2026-08-24):
`apps/desktop/src/lib/speech-text.ts`, `lib/voice-playback.ts`, and
`components/assistant-ui/thread/assistant-message.tsx`.
