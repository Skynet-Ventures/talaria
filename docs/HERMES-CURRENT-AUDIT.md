# Current Hermes parity delta

This is the requirement ledger for Talaria baseline
`04695b91e8fe7cc59a8638e266b5b151c58144ab` against Hermes
`40643cbaf9b767af146694131ffb8f8160f25e1c`. It retains the audited move
from `b5455fdd16fe608214f91149233660e1836b067c` through
`9ef9b2d2d01eb4bcf9420973c5ef6c98f2176455` and
`c1e25cadffe539b058816be5fdfc9127d7199fa4`, records a disposition for every
commit through `18a15a46d81793f9bcbf7e9f4cd93d5db841b7ae`, and audits all 19
commits in the `18a15a46..efb6b40f` window and the bounded
`efb6b40f..40643cba` tree audit. It supplements the older
row-by-row ledgers; when they disagree, this exact-source delta is newer.

The authority hashes live in [`parity/hermes-upstream.json`](../parity/hermes-upstream.json).
An implementation row is not certified merely because it is checked below:
the evidence column names the remaining gateway or device proof explicitly.
The audit cutoff is the exact `40643cba` snapshot reviewed on 2026-08-20
(America/Los_Angeles). A later moving remote `HEAD` is a prompt for another
explicit audit, not a reason to silently repin or invalidate this reproducible
checkout and its hashes. Only an explicit audit that finds an authority-file
change or a material portable-contract delta creates a parity blocker;
metadata, test-only, or non-portable drift can be recorded without chasing the
moving head.

## Open-stack implementation scope

Rich-transcript hydration through assistant `MEDIA:` projection and the
durable Queue dispositions below describe the still-open PR #54-#63 stack
ending at Talaria `ab6c89f09ebc6260a0e15ce38efb862c0ba32580`. They do not
claim those slices are present on released `main`
(`a8463632e409620d471cfd40d25b2197015ae00d` at this edit), and remain
provisional until the exact independently reviewed heads merge.

## Upstream movement after `c1e25cad`

The GitHub comparison reports 13 commits ahead of `c1e25cad` (a 14-commit
audit window when the prior pinned endpoint is included). Of the five hashed
authority files, only `apps/desktop/src/plugins/hermes-bots/plugin.js` changed:
57 additions and 6 deletions. Its SHA-256 moved from
`400a731d5263ef47927bcb261560fb626d7e285299c8a532319b73c5a5f9df22` to
`349d68988509f48bd6a9a84f3740252d09770699f80ff3e28dd7d55c74613927`.
The Bot Mode, Desktop, and multi-connection guides plus `apps/desktop/DESIGN.md`
are byte-for-byte unchanged at their pinned hashes.

| Commits | Upstream change | Talaria disposition |
|---|---|---|
| `c1e25cad` | Prior exact-source baseline: canonical-chat adoption, friendly mentions, activity/hiding, room prompt recovery, immutable room identity, source-qualified commands/MCP, and profile-scoped Projects. | Implemented on `main` by PR #31 at `04695b91`; the live gateway/device proofs below remain open. |
| `847a9df`, `8794e5a` | `auxiliary.goal_judge.timeout` now controls goal judging and contract drafting instead of a hard-coded 30 seconds. | Still open under management parity. Talaria has no auxiliary goal-judge administration surface; do not classify this runtime/config behavior as mobile-complete. |
| `770f9a5`, `ba501f0` | Bot Mode mention autocomplete and mention middleware now read the connection-suffixed live union-roster cache, with a freshest-stale fallback. | Already satisfied by architecture: both Talaria paths synchronously consume `AppModel.unionRosterBots` in `AppModelLive+A2A.swift`. They never perform Desktop's incorrect bare TanStack cache lookup. Existing mention protocol checks exercise union duplicates and `SourceQualifiedRoutingTests` exercises a foreign route. |
| `76952ba` | Mention completion self-filtering and middleware sender identity follow the focused on-screen bot rather than the gateway socket's launch profile. | Already satisfied: `ChatView` supplies its source-qualified `botID` as `speaking`, `MentionField` supplies its owning bot, and `MentionResolver.isSpeaker` compares the full route. `testQualifiedRemoteMentionSpeakerExcludesOnlyItself` pins the foreign-focused case. |
| `ed2d01a` | Core and contributed bare `@handle` completions are deduplicated while `@diff`, `@staged`, and typed context references remain distinct. | No client change required. Talaria has one shared bot-completion provider over a canonical union roster rather than Desktop's merged provider stack; `MentionCompletions` emits one row per roster identity and retains source-qualified collision handles. Keep this rule in the regenerated mention ledger. |
| `5969ea1`, `b9855f5`, `19c6a11` | OpenCode Zen/Go catalogs gained models and corrected GPT/Grok/Muse Spark API routing; `x-preview-f-free` gained a 1M context fallback. | Gateway-driven. Talaria loads `model.options` through `GatewayClient+Models.swift` and does not copy Hermes' curated provider catalog or choose its inference wire protocol. Certify catalog refresh against the pinned gateway; no static iOS catalog edit is warranted. |
| `309e883`, `9629653`, `892ec7a` | Contributor-email metadata only. | N/A to user-visible or gateway parity. |
| `95057c2` | Desktop/web enable the React Compiler and fix plugin-translation invalidation exposed by memoization. | Renderer-local implementation detail. Talaria is native SwiftUI and does not share React compilation or the Desktop plugin i18n registry; N/A to portable behavior. |

The new mention regressions change Desktop's correctness, not Talaria's
contract shape. They therefore move the authority pin without moving a parity
row. The goal-judge timeout is a real portable management gap, and the model
changes require live catalog evidence because their data is supplied by the
gateway.

## Upstream movement after `95057c2`

Hermes moved another 12 commits to `18a15a46`. None of the five hashed
authority files changed, so the plugin hash above and the other four manifest
hashes remain exact. The portable behavior still needs a disposition because
gateway and cron contracts changed outside the Desktop authority set.

| Commits | Upstream change | Talaria disposition |
|---|---|---|
| `949aff6` | Desktop Vite formatting only. | N/A; no runtime or portable behavior change. |
| `5210dd4` | Connector approval sends now distinguish sent, definite failure, and ambiguous timeout. Ambiguous delivery keeps the prompt registered and forbids duplicate resend/text fallback. Pending-approval tool results tell the agent not to reissue a variant. Streamed interim/seal frames retain block-format hints. | No new Talaria RPC/event shape. The retained pending prompt is compatible with Talaria's source-qualified approval recovery; add a live connector-fronted delayed-ack case before calling approval recovery certified. Formatting hints and agent tool text are gateway/messaging behavior, not an iOS renderer contract. |
| `57fe01e`, `424d07e`, `d4f7c2d` | Approval, clarify, slash-confirm, and expiry acknowledgements are interim, fire-and-forget sends. They cannot absorb/seal the turn's open draft or deadlock the relay read loop waiting for their own result frame. | No client change required. Certify that a Talaria approval/clarify response during a connector-streamed turn leaves one continuing stream and one final answer, with no duplicate fallback message. |
| `a7cfe39`, `952d1ce` | Clarify prompt sends adopt the same ambiguous-timeout classification, preserve registration, retain failure diagnostics, and continue into the existing bounded wait. | Talaria's clarify and room-prompt state already keys the exact gateway/session/request and rebuilds from resume. Add a delayed connector acknowledgement to the live single/multi-select and room recovery matrix. |
| `4e1dd1a`, `58258af`, `991af03`, `43c6dac` | Raw cron jobs gain optional `reasoning_effort`; precedence is per-job pin over per-model override over global effort. Empty clears, invalid values fail before persistence, and model tool dispatch cannot set it even though formatted jobs report it. Desktop's upstream mutation remains CLI-owned; Talaria's product decision explicitly authorizes a guarded mobile REST mutation for this job-owned field. | Implemented as an explicitly authorized mobile REST mutation. `CronJobDetail` and `RoutineEditorView` decode/display the raw value, preserve unknown values on unrelated edits, and send only canonical/clear values through the exact REST PUT normalizer. The model tool remains read-only; live certification remains open. |
| `18a15a4` | Windows updater progress self-test retries transient listener stalls. | Test-only; no portable client contract change. |

This range adds live cases and one management field, not a reason to alter the
five authority hashes or to claim existing gateway-dependent rows complete.

## Upstream movement after `18a15a46`

The exact Git graph from `18a15a46` (exclusive) through `efb6b40f` (inclusive)
contains 19 commits: nine memory/OpenCode/runtime commits on the first parent,
nine relay-exclusive/enrollment commits on the merged topic branch, and the
merge commit. The combined delta is 25 files, 1,352 additions, and 100
deletions. None of the five authority files changed; their recomputed SHA-256
values are exactly the values already recorded in the manifest. That does not
make the non-authority changes non-portable, so every commit is dispositioned
below against the exact `efb6b40f` source.

| Commit | Exact source change | Talaria disposition |
|---|---|---|
| `67292ec` | `gateway/config.py:_apply_env_overrides` makes an environment-stamped `GATEWAY_RELAY_URL` relay-exclusive: direct messaging adapters are disabled, while `local`, `api_server`, and `webhook` survive. YAML-only relay configuration remains additive. | **N/A to the Talaria client wire; existing management gap.** This is process deployment behavior, not a new RPC/event shape. Talaria still lacks messaging-platform/connector lifecycle management, so it cannot configure or inspect this policy from the phone. Connector deployments need the live guard in `TESTING.md`; no iOS transport change is warranted. |
| `2d3f5c1` | Adds truthy `GATEWAY_RELAY_ALLOW_DIRECT_PLATFORMS` as the explicit environment opt-out from relay-exclusive mode (`gateway/config.py:2776-2785`). | **N/A to client wire.** It is an operator-owned environment escape hatch. Keep direct-plus-relay behavior in the deployment matrix; do not invent a mobile toggle unsupported by a gateway API. |
| `477a022` | Routes the relay URL and opt-out reads through the secret-scope-aware `getenv` in `gateway/config.py`. | **Final mechanism retained; initial interpretation superseded.** `f8c3635` establishes the final contract: those routing reads resolve process-global values while relay authentication material remains profile-scoped. No profile-local routing contract is claimed. |
| `2ef095c` | Makes the `gateway/config.py` relay-exclusive sweep logs source-neutral and distinguishes warning/info wording. | **N/A.** Gateway log presentation only; Talaria receives no new field. |
| `55a272d` | Adds `tests/gateway/test_config.py` regressions for scoped relay stamps, explicit/automatic adapter log levels, and cleanup of the internal `_enabled_explicit` marker. | **Test-only.** No production source or mobile contract change. |
| `5a5d6b9` | `agent_init` and `tools/memory_tool.py` share one built-in-store flag resolver; the memory availability check opts out of the generic 30-second tool-check cache (`tools/registry.py:no_cache_check_fn`). | **Implemented client controls; gateway proof open.** Talaria already decodes and independently writes `memory.memory_enabled` and `memory.user_profile_enabled` in `OperatorSettings.swift`. The fresh per-turn tool surface is gateway-owned; certify a live config flip without claiming the existing parser test proves agent behavior. |
| `c809d96` | Parses built-in memory flags with Hermes' boolean parser, so quoted `"false"` is false rather than Python-truthy. | **Implemented path; no wire change.** Talaria writes JSON booleans, and the pinned gateway now also handles legacy/string config consistently. Retain this in the one-store-at-a-time live case. |
| `2cf7b36` | Enforces `MEMORY.md` and `USER.md` permissions independently in direct and staged writes, normalizes malformed/missing memory config, and advertises only enabled `target` enum values from one per-definition snapshot (`tools/memory_tool.py:1177-1234,1335-1389`; `agent/agent_init.py:1811-1832`). | **Implemented controls; certification open.** Talaria exposes both switches and write approval, but does not consume the agent's internal function schema. Verify enabled-target success, disabled-target rejection, and approval replay after a setting change against the exact gateway. |
| `7c9285a` | Bounds model-supplied invalid memory targets with `_bound_error_text` and restores the `Use 'memory' or 'user'` recovery hint. | **Gateway-owned / no client change.** Talaria's generic tool-result path can render the bounded error; no new response shape exists. Upstream automated coverage is source evidence, not a mobile certification claim. |
| `f9cd51e` | Extends OpenCode Go family routing in `hermes_cli/models.py` and `runtime_provider.py` to custom `opencode-go-*` providers and sends Go/Zen Grok models through Responses rather than chat completions. | **Implemented server-driven path; live proof open.** Talaria manages custom endpoints and consumes gateway `model.options`; it does not select the provider HTTP transport. Exercise a Talaria-created OpenCode endpoint and model switch against the pinned gateway. |
| `12a3a35` | Makes the OpenCode matching in `hermes_cli/models.py` and `runtime_provider.py` case-insensitive and symmetric for custom Zen and Go providers. | **Implemented server-driven path.** No catalog/RPC shape changed. Talaria's Name / Base URL / Model form sends no independent id and Hermes lowercases the generated slug, so a mixed-case provider id is not a Talaria-created endpoint case. The pinned upstream tests cover it; any additional live proof must use a hand-written disposable gateway config. |
| `a83c391` | Centralizes `opencode_provider_family`, applies it to switching/normalization, and aliases OpenCode-reserved `web_search`/`search_files` function names on the provider wire before mapping them back to canonical Hermes tool calls (`agent/transports/codex.py:62-110,556-560,789-800`). | **Implemented generic client surface; live proof open.** The alias is deliberately invisible to Talaria, whose ordinary tool cards should still receive canonical names. Verify both tools complete without an OpenCode 400 and without exposing `hermes_*` names. |
| `4978039` | For named custom providers or arbitrary names hosted on `opencode.ai`, derives API mode per effective model and heals the `/v1` suffix unless the user explicitly configured a transport (`hermes_cli/runtime_provider.py:1243-1278`). | **Implemented server-driven path; live proof open.** Talaria's custom-endpoint editor supplies name/URL/model and relies on Hermes for runtime selection. Test Responses, Messages, and Chat Completions model families; no static iOS routing table belongs here. |
| `533886c` | Adds `contributors/emails/Lesnak1@users.noreply.github.com`. | **N/A metadata-only.** |
| `f8c3635` | Classifies relay URL/endpoint/allow-direct/platform/route/wake/display routing stamps as process-global deployment configuration, while relay secrets, ids, delivery keys, and IDP credentials remain profile-scoped (`agent/secret_scope.py:117-133`). | **N/A to client wire; existing deployment-management gap.** This is the final contract that supersedes `477a022`. Talaria must not surface profile-local relay routing as if it were effective process configuration. |
| `3d25fd5` | Adds a `hermes_cli/gateway_enroll.py` warning when `hermes gateway enroll` writes relay URL/wake stamps into a secondary multiplex profile whose isolated `.env` cannot activate process-global routing. | **N/A CLI-only.** Talaria has no gateway-enroll RPC and should not imitate a host-local credential writer. |
| `d97cb8f` | Adds `tests/gateway/relay/test_relay_registration.py` coverage for config/registration agreement under process-only versus profile-only relay URL stamps. | **Test-only.** No production source change. |
| `6360113` | Corrects the enroll warning to read multiplex topology from the default Hermes root (or its environment override), with resolved-path secondary-profile detection (`hermes_cli/gateway_enroll.py:294-350`). | **N/A CLI-only.** This fixes the warning's authority but adds no mobile contract. |
| `efb6b40` | Merge commit joining the relay-exclusive topic branch to the memory/OpenCode first parent; it has no additional merge-resolution delta beyond the two audited parents. | **Merge-only.** No twentieth behavior is inferred. |

This window creates no new Talaria wire decoder requirement. It strengthens
gateway behavior behind three existing mobile surfaces: connector-backed
messaging deployment, built-in memory switches, and custom inference endpoints.
The first remains an existing management gap; the latter two have client
controls but still require the exact live cases below.

## Authority-changing movement after `efb6b40f`

`40643cba` is a descendant of `efb6b40f`. The reachable range contains 181
commits because it includes merged and replayed history, while the exact net
tree delta is bounded to 20 files: 3,134 additions and 85 deletions. The Bot
Mode plugin hash moved from `349d6898...` to `738e108f...`, and the Bot Mode
guide moved from `d13ab467...` to `3b614687...`. The other three authority
files recompute to their prior hashes. The earlier 19-commit ledger above is
retained; this section dispositions every file in the later net tree rather
than treating merge ancestry as 181 independent product changes.

| Exact net files / contributing commits | Contract | Talaria disposition |
|---|---|---|
| `apps/desktop/src/plugins/hermes-bots/plugin.js`, `apps/desktop/src/plugins/hermes-bots/tests/group-chat.test.mjs`, `website/docs/user-guide/bot-mode.md` (`64d393cb`, `7656a2ad`, `3b83b5e1`, `5d75a466`, `c6745da7`, `a976560e`, `7af4b8ee`) | Bot rooms publish a bounded version-3 projection in default-profile `ui_meta["hermes-bots-groups"]` to every reachable gateway. Durable `id:<roomId>` identity survives rename; explicit, bounded tombstones represent disband; missing/truncated projection data never means deletion. Recent logs merge idempotently by stable message id, while revisioned room fields converge. Desktop hydrates remote state, fans out writes, retries per gateway, and reseeds on reconnect. | **Implemented; live certification remains.** Talaria hydrates the safe projected subset into protected room storage without replacing richer local state, publishes to every reachable credentialed gateway, serializes each gateway lane, and reseeds on adoption, reconnect, and foreground recovery. Disconnected lanes remain suppressed until reconnect proves reachability. Missing projection is inert; explicit tombstones are durable and locally applied before reconnect. The six-case live matrix below is still required before claiming certified cross-client convergence. |
| `tui_gateway/methods_profiles.py`, `tui_gateway/server.py`, `tests/tui_gateway/test_profiles_ui_meta_cas.py` (`3b83b5e1`) | `profiles.list` exposes `ui_meta_revisions` (including `{}` for a CAS-capable profile). `profiles.configure` accepts per-key `ui_meta_expected_revisions`; under a dedicated lock it either increments and returns revisions or returns `applied.ui_meta=false` plus `ui_meta_conflicts`. Deleted-key revisions persist so stale writers cannot recreate data. Omitting expectations retains legacy best-effort writes. | **Implemented; live certification remains.** Talaria distinguishes omitted revision maps from CAS-capable `{}`, performs reread/merge/retry and exact-increment read-back under one connection-generation/traffic lease, retries each gateway on the bounded 1/2/4/8/16/30/30/30-second ladder, and retains an explicitly detected legacy best-effort fallback. |
| `hermes_cli/update_receipt.py`, `hermes_cli/update_cmd.py`, `hermes_cli/build_info.py`, `gateway/status.py`, `tests/hermes_cli/test_update_receipt.py` (`1d74833d`, `1acbeed1`) | Host updates now retain structured receipts and compare each live gateway's stamped `code_sha`/`code_version` with the updated code identity. | **Host/CLI operational behavior.** No new Talaria RPC response is introduced by these files. It strengthens the existing gateway-update/version-evidence gap; a native receipt surface would need a gateway API rather than reading host files. |
| `.dockerignore`, `docker/stage2-hook.sh`, `tests/tools/test_stage2_hook_api_server_keygen.py` (`7a17a1b8`, plus packaging cleanup in the range) | Container stage 2 bootstraps `API_SERVER_KEY` even when no `.env` exists and adds deployment regressions. | **Deployment-only.** It can improve first-boot reachability but creates no mobile wire shape. |
| `plugins/platforms/telegram/adapter.py`, `tests/gateway/test_telegram_rich_messages.py`, `website/docs/user-guide/messaging/telegram.md` (`790c8501`, `216c98aa`, `40643cba`) | Telegram rich final messages are sent persistently after DM drafts; draft-final cleanup no longer consumes the durable final, and docs clarify the behavior. | **Messaging-adapter-only.** Talaria is not the Telegram renderer and receives no new client event shape. |
| `gateway/stream_consumer.py` (`216c98aa`) | Draft-final cleanup is scoped so a later persistent final remains fresh. | **Gateway-owned delivery fix.** Retain one-final/no-duplicate live messaging evidence; no Talaria decoder change. |
| `website/docs/guides/manage-hermes-cloud-with-mcp.md`, `website/sidebars.ts` (`f4a03081`, `46e1a59d`) | Adds Cloud Portal MCP management documentation and navigation. | **Docs-only for Talaria parity.** Existing generic MCP/chat surfaces can invoke server tools; this adds no native protocol obligation. |

The precise shared-room client obligation is deliberately narrower than a full
transcript replica: preserve Talaria's protected full local log and durable
outbox, consume and publish the bounded projection (48,000-byte envelope, 16
recent messages, 1,200 text characters per message, 24,000 image characters),
merge stable message ids and revisioned fields, and never infer deletion from
omission. Use immutable room ids, final id tombstones for disband, revisioned
legacy-name tombstones only for migration, and fan out through every attached
default-profile gateway. A rename keeps the id; disband then same-name recreate
mints a new id. CAS must be tracked per gateway and per metadata key, with
conflict reread/merge/retry and read-back confirmation. Older gateways are
supported only through explicit feature detection. Foreign client-local
connection ids hydrate as visible, view-only frozen seats until an exact local
gateway identity exists; labels are never guessed and frozen seats never run.
Storage and scheduler policy are automated-test covered, while production
wiring and Desktop/mobile convergence remain uncertified until the retained
live matrix in `TESTING.md` passes.

The wire envelope is `{version: 3, updatedAt, rooms, deleted?}`. Room keys are
`id:<roomId>` or migration-only `name:<legacyName>`; a room carries `name`,
optional `roomId`, `log`, `revision`, source-qualified `members`, and optional
`image`. Projected log rows carry optional stable `id`, structured `from`,
`text`, `at`, and optional `thread`. One upstream storage helper
(`durableGroupChatRooms`, plugin lines 796-814 at this pin) omits `roomId`,
while the normal update path persists it and the guide/tests require durable
identity. Talaria must retain `roomId`; it must not copy that helper omission
as a client contract.

Talaria uses an empty-string `image` field as a compatible property-presence
extension for an explicit mobile avatar removal. The pinned Desktop receiver
already treats a present empty image as clear, while an absent image remains
ambiguous because size bounding can omit it. A Desktop-origin omission is
therefore never inferred as removal.

## Current-source corrections

| Contract | Talaria disposition | Automated evidence | Remaining certification |
|---|---|---|---|
| Canonical Bot Chat exact registry, adopt-before-kickoff, and bounded hydration retry | Updated for Hermes `a4f16e3f`. Bot-row opens exact-list `{profile,title:"Bot Chat",include_hidden:true}` on every tap, resume the resolved tip while retaining the durable root, and never infer identity from recency or legacy `ui_meta.chat`. Lookup failure cannot mint. Birth rechecks, creates hidden, titles before adopt/kickoff, preserves the named row on kickoff failure, and retains ambiguity leases. `/new` matches durable or resolved identity. | `CanonicalSessionProtocolTests`, `BotModeRuntimePolicyTests`, `TranscriptRuntimeRemediationTests`, `ProfileLifecycleTests`, source-qualified routing tests | Real primary and foreign profiles: exact existing chat, compression lineage, missing row birth, title-RPC compatibility, definite/ambiguous kickoff failure, lookup outage, and scratch-session `/new` |
| Friendly renamed mentions | Implemented. Bot Mode title and raw core `display_name` both remain accepted; legacy handles, including the default agent, remain routable; reserved friendly aliases cannot claim broadcast/user words; exact forms win before collapsed ambiguity. Room members retain both identities. | Mention/handle protocol checks, `RoomEngineTests`, `BotModeRuntimePolicyTests` | Two gateways with colliding friendly, collapsed, and legacy forms; roster disappearance and relaunch |
| Agent Inbox attribution provenance | Implemented fail-closed. Current Hermes `message_agent` transcript prefixes can carry a display handle without an authenticated source route. Talaria preserves markerless endpoints as opaque presentation identities for both inbound rows and mirrored replies; it never qualifies them with the recipient session's gateway or borrows a colliding union-roster bot. Legacy rows with an explicit immutable route remain source-qualified. | `SourceQualifiedRoutingTests` markerless sender/reply and duplicate-roster cases | Two live gateways with the same handle, including a markerless inbound message and reply round trip |
| Preferred/last conversation activity plus worker-session liveness | Implemented. Conversation activity alone controls unread/ranking; a valid worker stamp contributes live presentation for 150 seconds and display age without reordering. | Preferred-session checks and `BotModeRuntimePolicyTests` | Real worker child session, clock-skew/future stamp, remote gateway row |
| Roster Hide/Unhide | Implemented as display-only `ui_meta["hermes-bots"].hidden`. Unhide writes literal `false`; hidden rows retain mentions, rooms, polling, and unread but do not emit activity toasts. Show Hidden is session-local and dims inspection rows. | Cosmetics protocol checks and `BotModeRuntimePolicyTests` | Desktop/mobile round trip, hidden unread arrival, failed write rollback |
| Hidden room-member clarification and approval | Implemented as runtime-only prompt state rebuilt from `session.resume`. Clarify wins when both fields exist; cards use the exact room/member/runtime/request identity and owning gateway. Approval requires a positive resolved count. Batch answers are sequential, resume accepted locks from `pending_clarify.answers`, and never resend locked questions. | `RoomPendingPromptTests`, `RoomRoutingTests` | Cross-gateway approval and single/multi-select/batch clarify; partial batch relaunch; desktop resolves first; 20-minute hard cap |
| Room pending deadline/recovery | Implemented. A blocked non-running session cannot become a pass. Busy or awaiting-user state extends the sliding 180-second deadline up to the 20-minute hard cap; the cap clears transient prompt UI while leaving durable timed-out work for later harvest/re-mirroring. | `RoomRoutingTests` | Background/relaunch near both deadlines; rename, member removal, and disband while a prompt is open |
| Immutable room member-session identity | Implemented with the durable Talaria `RoomID`, independent of the editable room name. Rename preserves identity; delete and same-name recreation mint a different identity and cannot resume the deleted room's title-based sessions. Existing durable session IDs remain first authority and legacy name-titled rooms retain an explicit migration fallback. | `RoomRoutingTests` | Rename and same-name recreation against real primary and foreign profiles |
| Shared gateway room projection and profile-metadata CAS | Implemented. Talaria combines its bounded, separately persisted ledger with safe rich-room hydration, reachable-credentialed-gateway fan-out, per-gateway serialization/retry, exact CAS read-back, bounded legacy fallback, and adoption/reconnect/foreground reseeding. Foreign client-local routes hydrate as frozen view-only seats until exact local authority exists. Privacy deletion fences suspended sync, and startup applies cached tombstones before network recovery. | Focused `RoomStoreTests`, `RoomEngineTests`, `RoomProjectionRuntimeTests`, `ProfileUIMetaCASTests`, and cached-tombstone/settings `RoomRoutingTests` regressions cover storage and scheduler policy. Production target discovery and lifecycle-hook wiring are source-reviewed but remain part of live certification; upstream group-room and profile-CAS suites remain the pinned authority. | Run and retain all six live Desktop/phone/gateway cases in `TESTING.md` |
| Source-qualified slash commands | Implemented. Catalog/completion/resolve caches are per physical gateway; `slash.exec` captures the client and session that own the selected bot and connection generation. Typed output/send/skill/prefill/alias results are decoded without an unsafe unconditional `command.dispatch` fallback. Follow-up send failure retains a recoverable draft without replaying the first RPC. | `SourceQualifiedRoutingTests` | Two live gateways with the same runtime session id; supported structured results; plugin/quick-command collision remains rejected |
| Source-qualified MCP setup prompts | Implemented with `(gateway, request_id)` identity, secondary event routing, exact-source expiration and response. | `SourceQualifiedRoutingTests` | Same request id on two live gateways and one expired response |
| Profile-scoped Projects | Implemented against current `projects.discover_repos`, `projects.tree`, and `projects.project_sessions`. Every read/write carries the verified raw profile; discovery uses `scan:true` and completes before tree hydration. Same-gateway client replacement and profile lifecycle invalidate authority. Partial or saturated trees fail closed. | `WorkspaceProjectsProfileScopeTests`, `WorkspaceCommandCenterTests` | Two profiles with colliding project ids; zero-session remote repo scan; profile rename/delete during mutation |
| Connector prompt-delivery ambiguity | No new client wire shape. Existing approval/clarify recovery retains exact source identity and resumes pending state; current Hermes now also keeps connector-side prompt registration on an ambiguous send timeout. | `SourceQualifiedRoutingTests`, `RoomPendingPromptTests`, `RoomRoutingTests` | Delayed connector acknowledgements for approval and clarify, including a response during a streamed turn with no deadlock, sealed draft, duplicate card, or duplicate final |
| Independent built-in memory stores | Implemented controls. Talaria decodes and writes both built-in store flags independently and exposes the write-approval switch; exact Hermes now makes the live tool schema and both direct/staged writes honor the same flags. | `SourceQualifiedRoutingTests.testOperatorConfigParsesOnlySafeMobileControls`; upstream memory regression suite retained at `40643cba` | Flip each store independently on a disposable profile, begin a fresh turn, prove enabled writes succeed and disabled direct plus approved/staged writes fail with bounded recovery text |
| Custom OpenCode family routing and tools | No new Talaria wire shape. Custom endpoint CRUD/activation and gateway-driven model catalogs are implemented; Hermes owns family detection, per-model API mode, `/v1` healing, and reserved tool aliases. | `InferenceProviderManagementTests`, model catalog/switch tests; upstream custom-runtime and Codex transport suites | Create/activate a lowercase family-suffixed Go/Zen endpoint from Talaria; run Responses, Messages, and Chat Completions models plus canonical `web_search` and `search_files` tool calls. If mixed-case provider matching needs additional live proof, use a hand-written disposable gateway config rather than attributing that id to Talaria's form. |
| Relay-exclusive deployment stamps | No client decoder change. Environment-stamped relay-exclusive routing and the allow-direct escape hatch are gateway deployment policy; process-global routing/profile-scoped credentials are upstream authority. | Upstream config, secret-scope, relay-registration, and enroll-warning tests retained at `40643cba` | Disposable connector deployment: relay-only sweep, explicit opt-out, surviving API/webhook surfaces, multiplex process/profile separation, and secondary-profile enroll warning |

## Portable current-Hermes work still open

| Surface | Status / next proof |
|---|---|
| Gateway PTY | Implemented in Command Center with an authenticated SwiftTerm renderer, exact gateway/profile binding, OAuth ticket refresh, opaque reattach tokens, resize, ordered byte delivery, and lifecycle recovery. Automated gates are present; live-gateway and real-device certification remain open. Hermes does not confirm whether a token reattached or recreated a PTY after its detached TTL, and exposes no remote terminate endpoint, so Talaria asks before a potentially expired reattach and only promises local cleanup. |
| Projects filesystem | Blocked upstream for safe mobile use: `/api/fs` does not return authoritative resolved-target/root containment proof and writes have no atomic expected-hash/`If-Match`. Talaria must remain fail-closed rather than provide best-effort editing. |
| Unknown explicit Project profile | Hermes currently falls back to the launch profile. Talaria revalidates the selected route immediately before writes and fails closed, but Hermes should reject an explicit unknown profile. |
| Cron per-job reasoning effort | Implemented as an explicitly authorized mobile REST mutation. Talaria decodes and displays the raw field, preserves unknown values on unrelated edits, and sends only canonical/clear values through the exact REST PUT normalizer, which delegates to Hermes' canonical `cron.jobs.update_job` validation. The model tool remains read-only and cannot set this job-owned field. Live certification remains open. |
| Rich transcript parity | Partial on the open stack described above: markdown, tables, code, quiet/advanced tools, working avatar, transcript actions, jump-to-bottom, local transcript find, exact-source message-level child creation, bounded current-chat N/M response alternatives, typed tool-history hydration, bounded ordered multimodal/tool parts, file-edit diffs, structured terminal output with bounded ANSI styling, web-search result cards, exact successful generated-image cards/lightbox/share, explicit assistant `MEDIA:` image/audio/video/file cards, and normalized durable session-lineage presentation exist there. The ordered-parts and lineage consumers rely on additive Hermes contracts in `NousResearch/hermes-agent#93720` and `NousResearch/hermes-agent#93675`; neither may be called release-certified until its producer lands. The separate explicit text-only durable Queue has source/session-qualified persistence, edit/pause/remove/uncertainty semantics, and focused automated coverage. Assistant `MEDIA:` loads are all explicit and source-fenced. Generated public-URL images also require explicit contact, while an admitted gateway-path generated image starts its bounded authenticated load when its card appears. Gateway assistant-media images/files use managed reads, audio/video use the stream route, and public URLs use bounded no-credential/no-redirect loading. Live gateway/device proof remains open. Specialist math/diagram renderers, per-message TTS, whole-turn timing, and tour/activity remain. Desktop N/M selection changes only local renderer visibility; it sends no gateway RPC and cannot be reconstructed from a normal resume. Talaria mirrors that narrow behavior with an ephemeral exact-bound shelf and does not infer alternatives after resume. Durable `session.branch` child creation and the lineage browser are distinct from that local alternative group. |
| Management parity | Partial: provider/model/profile/capability/routine/memory/voice/operator surfaces exist. Messaging platform/webhook/relay-deployment lifecycle, subagent tree/live tail/files/cost, learned-memory curation, profile import/export, MCP per-server logs, auxiliary goal-judge/vision slots (including `auxiliary.goal_judge.timeout`), and MoA administration remain. |
| Git/System depth | Partial: core review and guarded mutations exist. Base/commit/ship context, dirty-worktree recovery, worktree-session integration, usage periods/daily/model/skill detail, and multi-gateway backend update orchestration remain. |
| Artifact completeness | Exact retained-source discovery is implemented with atomic no-dial snapshots, sequential reads, compacted rows, collision isolation, and explicit bounded/stale/failure state. Retained bodies use the exact captured client only after `/api/files` proves one canonical locked root; root and body responses are wire-bounded, authority is rechecked after awaits, and sign-out purges source-owned bytes. Hermes `session.list` still has no global continuation, transcript offsets remain informational under Talaria's 150-item cap, and gateways returning `locked_root: nil` remain fail-closed. Live certification remains open. |

## True platform exceptions

An exception must be tied to the Desktop host or renderer itself. A missing RPC,
an unfinished screen, an uncertified implementation, or an awkward phone layout
is not an exception. The current classifications are:

| Desktop behavior | Classification on iOS | Boundary that remains authoritative |
|---|---|---|
| Electron titlebar, pane docking, saved window placement, HUD, always-on-top, translucency, and local multi-window geometry | **True exception.** Talaria uses navigation stacks, sheets, and compact phone layouts; it does not reproduce pixel-for-pixel window management. | The portable destination and state must remain reachable and restorable. |
| Pointer hover, hover pre-warm, native tooltips, drag regions, and CSS cursor states | **Literal interaction is a true exception; purpose is not.** Touch-down/on-appear prefetch, long press, visible labels, and VoiceOver hints are the mobile equivalents. | Discoverability and first-open latency still require implementation and device evidence. |
| DOM/SVG/CSS/React compiler, QueryClient, renderer plugin registration, and contribution-id plumbing | **True renderer exception.** SwiftUI, `AppModel`, and explicit lifecycle wiring replace these mechanisms. | Transferable semantics such as idempotent registration, invalidate-after-mutation, reduced motion, and state restoration still apply. |
| Desktop global shortcuts and shell menu integration | **True exception where they address window/plugin hosting.** Hardware-keyboard shortcuts may be added as mobile convenience, but Bot Mode registers no parity-defining keybinds. | Every essential operation must remain reachable by touch and VoiceOver. |
| Finder/Explorer reveal and a path picker running on the gateway host | **True host-local exception.** Talaria uses a gateway-authorized Files/Projects browser and must not imply that an iOS picker selects a remote host path. | Remote reads/writes are portable, but writes remain fail-closed without resolved-target/root and atomic conflict proof. |
| Launching a separate local terminal emulator or spawning a Hermes backend on the client machine | **True host-local exception.** The authenticated gateway PTY and gateway operations are the mobile equivalents. | PTY/backend support must exist on the selected gateway; source/profile authority may never be guessed. |
| Native Windows PTY when the selected gateway exposes no supported PTY backend | **True host capability exception.** A phone cannot manufacture a missing remote PTY service. | Show the unsupported state honestly; do not silently fall back to another gateway. |
| Replacing the running app binary or applying a Desktop updater | **True distribution exception.** App Store/TestFlight owns signed iOS updates. | Gateway compatibility and release-channel state still need visible, testable handling. |
| Local desktop notifications, tray/dock badges, and foreground toast placement | **Presentation exception only.** APNs, the local activity journal, badges, and in-app toasts carry the portable signal. | Source identity, filtering, action routing, negative cases, and Debug/production APNs must be certified separately. |
| Desktop main-window progress chrome | **Presentation exception only.** A Live Activity is permitted for sustained operational tool work, not ordinary open chats or short answers. | Start/update/end policy, background cleanup, and reduced-motion behavior remain device-certification requirements. |

The following are explicitly **not** platform exceptions: union-roster routing,
rooms, canonical chats, durable queued work, rich transcripts and generated
media, attachments, notification delivery, provider/profile/routine management,
remote Git/Projects/files, gateway maintenance, and authenticated PTY access.
They are either implemented-but-uncertified or remain portable work in the
ledger above.

## Certification still required

- Exact `40643cba` gateway or a documented compatible release, plus a second
  gateway for collision and detach tests.
- Real-device long-thread, background/foreground, Wi-Fi/cellular handoff,
  queued-send, room prompt, attachment, and reduced-motion checks.
- Debug APNs approval and final-response delivery were observed on the paired
  device, but a retained repository/PR certification report containing every
  field required by `TESTING.md` section 5 is still pending. Mention/routine,
  interrupted and profile-filter negative cases, exact-session cold-launch tap
  routing, and the complete TestFlight production matrix remain open.
- A supervisor that outlives the gateway for honest offline/recovered push;
  a sidecar on the same failed host is not sufficient evidence.

Record these results with the stable ids and mandatory environment/evidence
fields in [`REAL-DEVICE-CERTIFICATION.md`](REAL-DEVICE-CERTIFICATION.md).
Implemented source and passing automated tests do not pre-fill a device result.
