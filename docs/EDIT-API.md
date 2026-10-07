# Local edit API

Lets local tools and AI agents read the open project and edit it. Off by default: Settings > Advanced > Edit API
(`sq.api.enabled`). Code: `Packages/SQEditAPI` (pure logic + server), `App/Sources/EditAPIController.swift` (wiring),
`Tools/sqmcp` (MCP stdio shim).

## Security
- Binds 127.0.0.1 only (`acceptLocalOnly`, non-loopback peers dropped). Port `sq.api.port`, default 19790.
- Per-launch random token (32 bytes hex), `Authorization: Bearer <token>`, constant-time compare.
- `Host` must be `127.0.0.1:<port>` or `localhost:<port>`; an `Origin` header must be the same (DNS rebinding,
  browser pages). Headers <= 16 KB, body <= 1 MB, <= 1000 operations, no chunked bodies, at most 8 connections.
- 15 s per connection; a commit not applied by then is canceled, never applied late.
- Times: timescale 1...2^20 and at most 2^22 s either way, checked on the raw integers before any arithmetic.
- Discovery: `~/Library/Application Support/Sequence Studio/edit-api.json` `{port, token, pid}`, created with
  `O_CREAT|O_EXCL|O_NOFOLLOW` mode 0600 (verified), written while the server runs, removed when it stops.

## Endpoints
- `GET /v1/state` -> project read model: sequences, tracks, clips (`id, track, name, media, type, start, duration,
  source, link, enabled, speed, effects`), markers, media (no paths). Times are `{"value": Int, "timescale": Int}`.
- `POST /v1/commit` `{"sequence": <activeSequence from state>, "name"?: "Tighten", "dryRun"?: bool, "operations": [...]}`
  -> `{applied, sequence, undoName, diff}`. `diff` = clips `added` / `removed` / `changed` (before/after start, duration,
  source, track, enabled), `durationBefore/After`, `markersAdded/Removed`.
- `POST /v1/undo` `{"expectedName"?: "Agent: X"}` -> `{"undone": true}`; only an "Agent: ..." top step is undone.
- Errors: `{"error": "...", "operationIndex"?: n}`; 400 bad input or time, 401 token, 403 host/origin, 409 timeline
  gesture in progress / active sequence changed since read / undo top step not an agent's, 413 size, 422 an operation
  failed (`operationIndex` absent when the final nesting check failed), 503 canceled.

## Agent commit
All operations run in order on a copy of the sequence through `Project.edit` (same SQCore edits as the timeline
gestures); any failure throws, nothing changes (rollback), and the failing index comes back. Success is ONE undo step
"Agent: <name>" through `EditorSession.perform`. `dryRun` runs the same perform steps (style tokens, pending scale) on
a copy (`EditorSession.previewPerform`) and returns the diff. Refused while a timeline drag is in progress.

Operations (`op` + fields): `razor{at, tracks?}`, `rippleDelete{clips}`, `lift{clips}`, `extract{range, tracks?}`,
`liftRange{range, tracks?}`, `trim{clip, edge: head|tail, by}`, `rippleTrim{clip, edge, by}`, `move{clip, to, track?}`,
`slip{clip, by}`, `slide{clip, by}`, `roll{clip, by}`, `toggleEnabled{clips}`, `addMarker{at, name?}`.
`range` = `{start, duration}`; `tracks` omitted = every unlocked track.

## Ids
Sequence, track, clip, marker and effect ids are the model's persisted UUIDs: stable across undo/redo and save + reopen
(test `StableIDTests`; no project file version change). Razor gives right halves new ids: re-read state, or cut
ranges with `extract` / `liftRange` in the same batch.

## MCP
`Tools/sqmcp/build.sh`, then `claude mcp add sequence-studio -- <repo>/Tools/sqmcp/.build/release/sqmcp`.
Tools: `sq_get_state`, `sq_commit`, `sq_undo`. The shim reads the discovery file on each call.

```sh
f=~/Library/Application\ Support/Sequence\ Studio/edit-api.json
port=$(jq .port "$f"); token=$(jq -r .token "$f")
curl -s -H "Authorization: Bearer $token" http://127.0.0.1:$port/v1/state
```
