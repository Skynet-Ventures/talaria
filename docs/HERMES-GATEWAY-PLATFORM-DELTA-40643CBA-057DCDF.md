# Hermes gateway/platform delta: `40643cba..057dcdf`

This ledger closes the production `gateway/**` and `gateway/platforms/**` audit against exact Hermes endpoints `40643cbaf9b767af146694131ffb8f8160f25e1c` and `057dcdf236f8a6a26721c10fcc6ccb72726e272a`. It unions every parent diff for merge commits and excludes paths containing `test`, `tests`, `fixture`, `fixtures`, or `generated`.

## Exact inventory

- 82 scoped commits touch 43 production history paths.
- 48 commits are classified here; 34 are predecessor-owned cross-references (PR85 authority: 3, PR90 client-wire: 21, PR93 core-runtime: 10).
- The endpoint diff retains 22 files, each pinned by base/target SHA-256 (`absent` denotes a missing endpoint blob).
- Machine sources: `parity/hermes-gateway-platform-delta-40643cba-057dcdf.json` and `.tsv`; `scripts/check_hermes_gateway_platform_delta.py` recomputes the every-parent inventory and endpoint hashes.

## Mobile disposition

Five API/profile projection commits are portable and already covered by Talaria source-qualified routing/presentation behavior. Thirty-eight host-runtime commits remain host-only or require host verification: browser control, platform adapter authorization/pairing, delivery-ledger recovery, startup redelivery, session database recovery, process/control-socket lifecycle, shutdown watchdogs, and platform maintenance. Five merge commits are retained explicitly as merge integration. Predecessor-owned commits are not double-classified.

## Push leakage and bot presentation

The audit confirmed a Talaria relay gap: `long_task` timing/admission and the legacy active-session sidecar could observe turns without trusted originating-platform provenance, allowing Slack, Telegram, Discord, webhook, cron, missing, unknown, or spoofed sources to create Talaria pushes. Notification presentation also needed one bounded profile lookup across response, approval, and long-task alerts while preserving raw routing identity.

PR95 (`codex/source-qualified-push-presentation`, exact review head `887de277b1ea9b9f2860b85e9e38b5fe8b2e8971`; implementation commit `4a06df18e768fe4bb8a206dc86f1dce0a08feec6`) implements both contracts: only exact `talaria`/`desktop` turn sources enter long-task timing, sidecar timing fails closed without provenance and keys titles by `(bot, platform, session)`, and configured display/avatar presentation is separated from raw bot/source/deeplink routing. The review head includes merged main after the isolated bounded-REST test-stability dependency landed, so the notification diff remains four files. Its status is **implemented, unmerged, and live-device proof remains open**; this ledger does not claim merge or device certification. Routine/cron pushes remain disabled.

## Verification

```sh
python3 scripts/check_hermes_gateway_platform_delta.py
python3 scripts/check_hermes_gateway_platform_delta.py --checkout /Users/joshua/talaria/hermes-agent-upstream
python3 -m unittest scripts/test_check_hermes_gateway_platform_delta.py
```

Static validation fails closed on count/schema/classification/head/hash drift. Exact-checkout validation requires the full upstream object store and recomputes all 82 every-parent unions, the 43-path union, 22-file endpoint diff, source assertions, and PR95 assertions.
