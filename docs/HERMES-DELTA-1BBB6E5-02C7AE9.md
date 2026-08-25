# Hermes successor audit: `1bbb6e5` through `02c7ae9`

This additive audit covers Hermes
`1bbb6e5bce56e721ab685af4cd87df21bbff4d35` (exclusive) through
`02c7ae956e42891d5e337a921b45de0a6067146d` (inclusive), as observed on
2026-08-25. It extends the prior `057dcdf..1bbb6e5` audit without weakening its
open implementation and certification gates.

The successor range contains **3 commits and 6 net-changed paths**, with 180
additions and 9 deletions. The exact commit and path inventories are fixed by
[`hermes-delta-1bbb6e5-02c7ae9.json`](../parity/hermes-delta-1bbb6e5-02c7ae9.json)
and independently recomputed by the checker.

## Disposition

- `cbd8de8a` binds the live system-prompt rebuild to the session working
  directory after a model switch. This is a server-owned correctness fix. It
  does not change the model-switch, configuration, session, or event wire
  contract consumed by Talaria.
- `90ee4460` translates Desktop sidebar `recents_profile` values through the
  managed-SSH alias map.
- `02c7ae95` stamps Desktop session-list REST calls with the active profile.
  Both Desktop commits operate inside Electron/REST routing. Talaria already
  routes session operations through the owning source-qualified
  `GatewayBotRoute` and has no Electron alias layer.

The five authority files audited at `1bbb6e5` are byte-for-byte unchanged.
There is therefore **no new Talaria client implementation** in this successor
range.

## Pin decision

**Do not move the canonical pin.** Keep
`057dcdf236f8a6a26721c10fcc6ccb72726e272a` authoritative. The preceding audit's
five portable slices still require dependency-ordered merge and exact-gateway
certification. A server-only successor does not waive those gates.

## Reproduction

```bash
python3 scripts/check_hermes_delta_1bbb6e5_02c7ae9.py
python3 scripts/check_hermes_delta_1bbb6e5_02c7ae9.py \
  --checkout /path/to/exact/hermes-02c7ae9
python3 -m unittest scripts/test_check_hermes_delta_1bbb6e5_02c7ae9.py
```
