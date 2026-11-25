# Local edit API

Lets local tools and AI agents read the open project and edit it. Off by default: Settings > Advanced > Edit API
(`sq.api.enabled`). Code: `crates/sq-edit-api` (logic and server).

## Security
- Binds 127.0.0.1 only (`acceptLocalOnly`, non-loopback peers dropped). Port `sq.api.port`, default 19790.
- Per-launch random token (32 bytes hex), `Authorization: Bearer <token>`, constant-time compare.
- `Host` must be `127.0.0.1:<port>` or `localhost:<port>`; an `Origin` header must be the same (DNS rebinding,
  browser pages). Headers <= 16 KB, body <= 1 MB, <= 1000 operations, no chunked bodies, at most 8 connections.
- 15 s per connection; a commit not applied by then is canceled, never applied late, and the call answers 503. Long calls (transcript,
  captions, import) answer before that (after 10 s) with the job shape, so the connection is never closed without a reply.
- Times: timescale 1...2^20 and at most 2^22 s either way, checked on the raw integers before any arithmetic.
- Discovery: `~/Library/Application Support/Sequence Studio/edit-api.json` `{port, token, pid}`, created with
  `O_CREAT|O_EXCL|O_NOFOLLOW` mode 0600 (verified), written while the server runs, removed when it stops.

## Endpoints
- `GET /v1/state` -> project read model: sequences (`width, height, fps {num, den, value}, sampleRate, frameDuration`),
  tracks (`kind, locked, muted, solo, visible`), clips (`id, track, name, media, type, start, duration, source, link,
  enabled, speed, effects`), markers, media (`path, size, duration, width, height, fps, hasAudio`), `playhead`, `file`
  (project file) and `dirty`. Times are `{"value": Int, "timescale": Int}`.
  A new project is not empty: it already holds "Sequence 01" (1920x1080, 25 fps) and `activeSequence` is its id. A commit that
  sends this id as `sequence` may start with `createSequence` (the new one becomes the open sequence; test
  `edit_api_host::tests`, the Reel commit); read `/v1/state` again for the new `activeSequence`.
- `POST /v1/commit` `{"sequence": <activeSequence from state>, "name"?: "Tighten", "dryRun"?: bool, "operations": [...]}`
  -> `{applied, sequence, undoName, diff}`. `diff` = clips `added` / `removed` / `changed` (before/after start, duration,
  source, track, enabled), `durationBefore/After`, `markersAdded/Removed`.
- `POST /v1/undo` `{"expectedName"?: "Agent: X"}` -> `{"undone": true}`; only an "Agent: ..." top step is undone.
- `POST /v1/redo` `{"expectedName"?}` -> `{"redone": true}`; only an "Agent: ..." step is redone (409 otherwise).
- `POST /v1/import` `{"paths": ["/abs/clip.mp4", ...]}` -> `{"media": [{path, media?, error?}]}`: the same import as a drop
  on the window (a file the project already has gives its existing item). Needs ids before `addClip`, so it is an
  endpoint, not a commit operation. Waits up to 10 s; a longer import goes on in the app (read `/v1/state`), the call
  answers 202 with a job id. Example: `curl -d '{"paths":["/Users/me/a.mp4"]}' .../v1/import`.
- `POST /v1/save` `{"path"?: "/abs/x.sqproj"}` -> `{"saved": path}`: saves the open project, or saves it as `path`.
- `POST /v1/open` `{"path": "/abs/x.sqproj", "discard"?: bool}` -> `{"opened": true}`; 409 while the open project has
  unsaved changes unless `discard` is true.
- `POST /v1/playhead` `{"at": {"value": 2, "timescale": 1}}` -> `{"playhead": ...}` (frame-snapped).
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
`slip{clip, by}`, `slide{clip, by}`, `roll{clip, by}`, `toggleEnabled{clips}`, `addMarker{at, name?}`, `setPixelAspect{media, aspect?}` (aspect `{num, den}` within 1:4 ... 4:1; omitted = what the file says; a media setting, counted in the diff as `pixelAspectChanges`).
`range` = `{start, duration}`; `tracks` omitted = every unlocked track.

Building a cut (ids come from `/v1/state`, media from `/v1/import`):
- `addClip{media, track?, at, sourceIn?, sourceOut?, linkAudio?: true, mode?: "overwrite"|"insert"}`: the Overwrite /
  Insert command of the UI (`EditorSession::place_media`); video with its linked audio, `linkAudio:false` = video only;
  `track` = the video track, default the drop rule. Example: `{"op":"addClip","media":"<id>","at":{"value":0,"timescale":1},"sourceIn":{"value":1,"timescale":1},"sourceOut":{"value":5,"timescale":1}}`.
- `removeClip{clips, ripple?: false}`: Lift, or Ripple Delete with `ripple:true`. `addTrack{kind: "video"|"audio"}`.
- `setClipSpeed{clip, speed: {num, den}}` (the source range stays, the clip gets shorter or longer), `setTrackState{track, mute?, solo?, lock?, visible?}`.
- `createSequence{name, width, height, fps, sampleRate?}` (the new sequence becomes the open one; `fps` = 24, 25, 30, 60,
  23.976, 29.97, 59.94, 119.88 or `{num, den}`; 1080x1920 at 30 works), `setActiveSequence{sequence}`,
  `setSequenceSettings{sequence?, width?, height?, fps?, sampleRate?}`. The answer carries `sequencesAdded` and `activeSequence`.
- A batch with `addClip`, `createSequence` or `setActiveSequence` runs operation by operation through the session
  commands and is still ONE undo step "Agent: <name>"; any failure rolls all of it back. No `dryRun` for such a batch (422).

## Parameters, effects and text graphics
Read: `GET /v1/clip/{id}/params` -> `{clip, params, effects, layers}`. Every inspector parameter is one entry
`{path, group, title, type: number|bool|choice|vec2|color|text, unit?, min?, max?, default, choices?, value, animated, keyframes?: [{at, value, interpolation}], effect?, layer?}`.
Paths: `motion.position|scale|rotation|anchor|tiltX|tiltY|shutterAngle|antiFlicker`, `opacity` (video clips), `audio.volumeDb`,
`audio.gainDb` (audio clips only), `effect.<effectId>.<key>` (value as stored; catalog range), and on a graphics clip `layer.<layerId>.<same>`
plus `layer.<layerId>.text` and `layer.<layerId>.style` (the full TextStyle). What the code does: a video clip takes `motion.*` and `opacity` and NO audio path (its sound is the linked audio clip: set
`audio.volumeDb` on that clip); an audio clip takes `audio.volumeDb` (keyable) and `audio.gainDb` (clip gain, -60...60, a plain
value: `setParam` only, `setKeyframe` is refused); a graphic layer takes `layer.<layerId>.motion.position|scale|rotation|...` and
`layer.<layerId>.opacity` (no audio). Any other path answers 422 "not a parameter of this clip". Units are the model's: scale 1 = 100 %, opacity 0...1,
position in sequence px from the center, y down. Key times `at` are clip-local (0 = clip start). Values: number, bool, choice index or title,
point `{x,y}` / `[x,y]` (one number = both axes), color `"#rrggbb(aa)"` / `[r,g,b,a]` 0...1.
`GET /v1/effects` -> `{effects:[{kind, title, scope: video|audio, params:[{key, title, type, unit?, min?, max?, default, choices?}]}]}`
(the Effects panel catalog; includes the `color` grade effect and every audio effect).

Operations: `setParam{clip, param, value}` (refused while the parameter has keys), `addEffect{clip, effect: kind, index?}`,
`removeEffect{clip, effect: id}`, `setKeyframe{clip, param, at, value, interpolation?: linear|hold|bezier}` (a key at the same time is replaced),
`removeKeyframe{clip, param, at}`, `addGraphic{track, at, duration, name?, layers: [...]}` (ONE graphics clip, layers bottom first),
`setTextLayer{clip, layer, ...fields}`, `addTextLayer{clip, index?, ...fields}`, `removeTextLayer{clip, layer}`.
Layer fields (all optional but `text` on a new layer; unknown keys are refused): `name, text, font, size, color, weight (100...900 or thin|light|regular|medium|semibold|bold|heavy|black), align (left|center|right), italic, tracking, lineSpacing, allCaps, style (raw TextStyle fields merged), position, scale, rotation, opacity`.
The commit reply's `diff.paramChanges` lists, per clip, each parameter that changed (`before` / `after` = `{value, keyframes?}`); the new clip of
`addGraphic` is in `diff.added`, its layer ids in the params read.
```sh
curl -s -H "Authorization: Bearer $token" -d '{"sequence":"<id>","name":"Titles","operations":[
 {"op":"addGraphic","track":"<video track>","at":{"value":0,"timescale":1},"duration":{"value":3,"timescale":1},
  "layers":[{"text":"Title","size":96,"color":"#ffffff"},{"text":"Subtitle","position":{"x":0,"y":120}}]},
 {"op":"setKeyframe","clip":"<clip>","param":"audio.volumeDb","at":{"value":1,"timescale":1},"value":-6}]}' http://127.0.0.1:$port/v1/commit
```
Not covered yet: text animators (`text_animator_model.rs`) and effects on a single layer (`addEffect` acts on the clip).

## Export, jobs, Sync Audio, first sequence
- `POST /v1/export {sequence?, path, preset?, range?}` -> `{job}` at once. The same model and queue as the Export sheet
  (`ShellHost::api_export`): `path` is absolute, no `..`, and ends in the preset's extension (`.mp4`); an existing file at
  `path` is replaced. `preset` = an id of `GET /v1/presets` (`{presets:[{id,name}]}`; `tiktok-9x16` is accepted as an alias
  of `tiktok-h264`); omitted = what the sheet would propose. `range` = `"entire"` (default), `"inOut"` or `{start, end}` (times).
  Loudness normalization is always OFF. Refusals (422): unknown preset/sequence, wrong extension, the sheet's own validation texts.
  Example: `{"path":"/Users/me/Exports/reel.mp4","preset":"tiktok-9x16"}`.
- `GET /v1/jobs/{id}` -> `{id, kind: export|import|transcript|captions, state: queued|running|done|failed, progress 0..1, result?, error?}`.
  ONE job map for every long call (`Jobs` in edit_api_host.rs; ids `export-N`, `import-N`, `transcript-N`, `captions-N`).
  `result` once done: export `{output}`, import `{media: [{path, media?, error?}]}`, transcript / captions what the call answers
  when it finishes at once. Unknown id: 404. `POST /v1/import` that does not end within 10 s answers 202
  `{job, message}` (it keeps running in the app); `POST /v1/media/transcript` and `/v1/addCaptions` that run longer than 10 s
  answer 200 with the same job shape plus `job` (the id). Example: `curl .../v1/jobs/export-1`.
- `/v1/import` takes media files and folders only; projects (.sqproj), Premiere projects, timelines, presets, templates,
  Lottie and subtitle files (also a `.sqproj` folder) are refused with 422 and the reason (they open dialogs the API cannot answer).
- `syncAudio{clip, to, retime?: true}` (session op, one undo step): the menu command "Sync Audio to Reference" for one clip
  (`EditorSession::sync_audio`): the fit is start timecodes when both files have one, else the shared SOUND (loudness-envelope
  waveform fit with drift), else capture dates (whole seconds). `retime` corrects drift by a constant speed (only for a sound fit).
  `clip` moves with its linked partners; `to` must play at 100 % and both must be in the open sequence. The files are read before
  the commit (can take a few seconds). 422 with the reason when nothing matches.
- A commit without `sequence` is accepted only while no sequence is open: its `createSequence` is the first step; the answer's
  `sequence` is the new one. With a sequence open `sequence` stays required (400).
- `POST /v1/save {path?, overwrite?}`: with `path` it behaves like Save As: the project is bound to that file afterwards. An
  existing file that is not the project's own is refused (409) unless `overwrite: true`. All paths: absolute, no `..`.
- A failing session batch also puts the playhead back (the selection is not restored).

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

## Unknown keys

Requests with unknown JSON keys are refused with `400`; nothing is applied.

## Perceive: see and understand the project and footage

These calls write files into `<support>/api-cache/` and answer with their paths (read the PNGs from disk). Times are
`{"value","timescale"}`. At most 24 frames per call, `width` at most 4096.

- `POST /v1/capture {sequence?, at, width?, contactSheet?}`: the timeline picture at `at` (one time or a list), rendered by
  the export's engine (effects, text, burned-in captions). `contactSheet {from,to,count}` adds one PNG grid with a timecode
  per tile. Example: `{"at":{"value":5,"timescale":1},"width":960}` returns `frames[{at,timecode,path,width,height}]`.
- `POST /v1/media/frames {media, at | count, width?}`: source frames of a media item (`count` = evenly spaced), same reply.
- `POST /v1/media/transcript {media | clip}`: words with times (`{text,from,to,confidence}`); a clip answers in sequence time.
  A long run answers the job shape (`{job, id, kind:"transcript", state:"running", progress}`) after 10 s: poll `GET /v1/jobs/{id}` (`state` running, done or failed, `result`).
- `POST /v1/media/levels {media | clip | sequence, from?, to?}`: `integratedLufs`, `truePeakDb`, `samplePeakDb`, `silences`
  (ranges below -50 dBFS of 0.4 s or more, `from`/`to` times).
- `POST /v1/media/scenes {media}`: answers `501` (no shot-cut engine behind the API yet).
- `POST /v1/importPremiere {path, dryRun?}`: File > Import Premiere Project into the open project as ONE undo step
  "Agent: Import Premiere". Reply: `sequences[{id,name,durationSeconds}]`, `sequenceIds`, `mediaIds`, `mapped`,
  `approximated`, `dropped`, `report[{feature,status,count,note}]`. Then read `/v1/state` to learn the editor's style.
- `GET /v1/captionStyles`: the caption styles (`default`, `outline`, `pill`), animations, layouts and positions `addCaptions` accepts.
- `POST /v1/addCaptions {clip | sequence, style?, wordByWord?, position?}`: the app's own Create Captions on the speech of a
  clip or a sequence (must be the sequence shown in the timeline). `wordByWord` (default true) uses the short-video preset, one
  word per caption; `position` is `top`, `center` (default) or `bottom`. ONE undo step "Agent: Add Captions". A long run answers
  a job id like transcript. Example: `{"clip":"<id>","style":"pill","wordByWord":true,"position":"center"}`.
