# Hermes `9d9f44d` architecture audit

This is Talaria's exact-source audit of official Hermes main at
`9d9f44d63826b18503f44c754e48e1f4f83b3a6e`, performed 2026-08-29 against
Talaria main `f2f97ee4cc0ba973f162b0a3df3011639f5fd7c2`. It supersedes the moving-head
cutoff in `HERMES-CURRENT-AUDIT.md`; that document remains the historical
implementation ledger for earlier ranges.

The prior audited Hermes endpoint was
`02c7ae956e42891d5e337a921b45de0a6067146d`. It is an ancestor of this pin;
the exact range contains 920 commits. Bot Mode was split from the former
single `plugin.js` into typed modules. The machine-readable authority therefore
pins the new module boundary rather than pretending the deleted monolith is
still the source of truth.

The final `299c652a..9d9f44d6` commit edits only `agent/prompt_builder.py` to
shorten Desktop widget/MCP teaching. It changes none of the ten pinned Bot
Mode/Desktop authority files and introduces no client wire or portable iOS
behavior. It is included so this audit and the updated mini gateway share one
exact upstream head.

## Portable client changes

| Upstream authority | Contract | Talaria disposition |
|---|---|---|
| `316e51ae`, `84e17db0`, `af53d029`; `tui_gateway/methods_session.py`, `server.py`, `hermes-bots/canonical-chat.ts`, `group-turns.ts` | `session.create` accepts `follow_profile_config`; room members additionally send `room_plumbing`. Resumed Bot Mode-owned sessions use the profile's current provider/model rather than a stale stored pin. | **Implementation required.** Canonical Bot Chat must send `follow_profile_config:true`; room member sessions must send both flags. Ordinary and scratch sessions must omit them. |
| `fd565c80`, `77edf1b4`, `cb75983a`, `07b87f14`, `962b308b`, `6fdaef6a`, `db127f75`; Desktop session owner/router modules | Session and profile actions retain exact connection/profile/session ownership. Same session ids in different profiles are distinct rows. | **Existing architecture, retain and certify.** Talaria uses source-qualified routes and gateway/profile-qualified room/session stores. Add any missing collision cases; do not collapse by bare session id. |
| `01f7ce5b`, `9faa6853`; `hermes_cli/web_routers/sessions.py` | `POST /api/sessions/owner-backfill` with optional profile returns `{ok, stamped, profile}`. New Desktop also keeps a read-only cross-backend transcript fallback for legacy rows. | **New compatibility slice.** Invoke only against an unambiguous owning gateway/profile, treat 404 as version skew, and never turn fallback discovery into mutation authority. |
| `25525799`, `7450266a`, `8fe4816e`, `61b6788d`; profile/model controls | A guarded profile model change may return `confirm_required` and `confirm_message`; resend only after consent with `confirm_expensive_model:true`. | **Already implemented.** Talaria's shared live model control decodes the guarded result and uses the same confirmation path from settings and Bot profile. Retain source qualification. |
| `213ae08e`, `c19849cd`, `a7ea1564`, `62534e2b`; Desktop gateway-event compaction state | “Compacting” clears only on a compacted status, resume, or `session.info.running=false`. | **No equivalent retained client state.** Talaria's manual compaction is one awaited, source-fenced RPC and returns the gateway receipt directly; it does not publish Desktop's independently persistent “compacting” composer state or clear one from an idle timer. Ordinary turn activity already settles from `message.complete`, `error`, resume/session-info, and the authoritative active-session snapshot. Revisit only if Talaria adds background compaction presentation. |

## Server-owned changes

- Gateway heartbeat persistence, orphan sweeping, state DB journaling and stale
  `model_config` cleanup are Hermes server authority. Talaria consumes the live
  wire and must not duplicate server recovery policy.
- Cron incident persistence/acknowledgement is server/CLI owned. A rendered
  `delivery_outcome:"suppressed_acked"` is a non-error terminal outcome.
- Model catalog additions and provider routing stay gateway-driven; Talaria
  must not copy upstream's static catalog.
- Relay voice/media and Slack unfurl changes are gateway/platform behavior.

## Desktop-only / iOS equivalents

- The TSX/design-system rewrite is not portable code. Talaria retains native,
  mobile-first SwiftUI while following the typed Bot Mode product contracts.
- Electron dial claims, safe storage, SSH lifecycle, HUD/windows, browser and
  updater/TCC work are iOS N/A or map to existing iOS keychain/background
  lifecycle authorities.
- Pointer hover warming is iOS N/A; any future mobile equivalent must be
  bounded prefetch-on-visibility and may not activate or reroute a bot.

## Explicit non-contract

Hermes commit `874fab0c` introduced replay `seq`/`epoch`/`trace_id` behavior,
then `9f05b065` reverted it. The current tree does not expose that protocol.
Talaria must not pin or implement the reverted wire shape.

## Remaining implementation order

1. Land the additive Bot Mode session-create contract.
2. Add the source-fenced owner-backfill/read-only legacy transcript slice.
3. Run the existing source-qualified ownership/collision matrix and exact
   gateway/device Bot Chat + room provider-switch certification.

The pin records an audit, not certification. Gateway- and device-dependent
rows remain open until their retained live cases pass.
