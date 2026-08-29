# Durable Hermes host-update recovery

Authority audited line by line: Hermes
`057dcdf236f8a6a26721c10fcc6ccb72726e272a`.

## Exact wire

- `hermes_cli/web_server.py:update_hermes` creates a lowercase 32-hex
  `action_id`, passes it as `HERMES_ACTION_ID`, and returns it with the
  positive action-process PID. A live duplicate is coalesced to the existing
  action and identity.
- `hermes_cli/update_cmd.py:_print_update_completion` writes
  `=== hermes-update completed <action_id> ===` only for a valid identity.
  `web_server.py:_durable_completed_update_action_id` recovers that marker
  from the bounded durable `update.log` tail after the web host restarts.
- `GET /api/actions/hermes-update/status` returns bounded `lines`, process
  state, the recovered `action_id`, and `_latest_update_receipt_summary()`.
  The summary is `{outcome,started_at,finished_at,pre_sha,post_sha,
  post_version,fleet_states}`. The full receipt is separately available at
  `GET /api/hermes/update/receipt`.
- The receipt itself has no action ID. It is correlated client-side only when
  the status also carries the exact completion identity and the receipt began
  no earlier than the locally recorded start (with Desktop's 60-second clock
  slack). `tests/hermes_cli/test_update_receipt_endpoint.py` pins receipt
  fallback: `success -> exit 0`, `partial -> exit 1`, while an unfinished
  `running` receipt proves no terminal result.
- PID is the detached update child only while the same host process retains
  its `Popen`. Restart clears that registry and normally returns a null PID.
  Receipt PID, update-lock PID, gateway PID, and action PID are never mixed.

## Talaria contract

Talaria persists one minimal, source-qualified no-replay record: gateway,
optional profile, canonical action ID, initial advisory PID, local start time,
and ambiguity bit. It contains no credential, URL, log, command output, or
receipt body and is capped at 4 KiB. A malformed/missing action ID is retained
only as an ambiguous legacy tombstone and cannot be presented as safely
accepted.

Initial connection, supervised reconnect, app relaunch adoption, and the open
Operator screen perform status reads only. They never replay the update POST.
Publication requires the same gateway, client identity, live generation, and
connection revision. A replacement/null PID is accepted only with the exact
action completion marker and a fresh coherent structured receipt. Legacy peers
without an action ID remain ambiguous even when a PID happens to match; a
same-process running status may omit `action_id` and is shown only as advisory
progress while the durable fence remains. Replacement-PID running recovery is
not claimed: a running receipt is not durable because `latest.json` is written
only at finalization. Wrong source/action, stale or
future receipt, reversed timestamps, malformed/saturated status, terminal
regression, and exit/receipt disagreement preserve ambiguity.

Ordinary sign-out and cache clearing intentionally preserve this authority so
signing back in cannot replay a still-running update. Exact gateway removal
(including full local-data deletion) purges it. Correlated terminal recovery
removes persistence but leaves an honest recovered result in the current UI
until acknowledged.

## Live-proof matrix

No live update or restart was invoked while implementing this feature.

| Scenario | Deterministic proof | Remaining live proof |
|---|---|---|
| Start -> disconnect -> restarted terminal | Exact marker + fresh receipt + replacement/null PID policy tests | One disposable gateway update |
| App relaunch | UserDefaults rehydration and automatic post-adoption status scheduling | Relaunch during a disposable update |
| Failure / partial / refused | Exact receipt/exit mapping tests | Capture each host outcome if practical |
| Legacy peer | Same/replacement/null PID all remain ambiguous; missing ID persists a no-replay tombstone | Old gateway fixture |
| Source/client/generation race | Publication lease tests | Multi-gateway disconnect race |
| Cleanup | Wrong-gateway preservation, exact removal, terminal regression tests | None |
