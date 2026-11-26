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
  `createSequence` never deletes that untouched "Sequence 01": it stays next to the new one. To work in a fresh project
  without a second sequence, use `setSequenceSettings{width, height, fps}` on it instead (the clean way).
  Times: every time may also be a bare number of seconds (`"at": 39.9` = 399/10 s, exact to the microsecond); it
  behaves exactly like the rational form. Off-frame times are not snapped by the API.
- `GET /v1/gaps?sequence=<id>` (default: the open sequence) -> `{sequence, frameDuration, gaps:[{track, kind, start, duration, before, after, shorterThanFrame}], black:[{start, duration}]}`:
  every gap between two clips of a track, also one shorter than a frame (rational times, test `gaps_lists_a_gap_shorter_than_a_frame_and_the_black_stretch`),
  and every stretch where no enabled clip of a visible video track shows (black frames). A commit that opens a gap answers it in `gapsOpened`.
- `POST /v1/commit` `{"sequence": <activeSequence from state>, "name"?: "Tighten", "dryRun"?: bool, "operations": [...]}`
  -> `{applied, sequence, undoName, diff}`; `sequence` is the new open sequence after a `createSequence`. A batch that changes
  nothing is never a silent 200: it answers `422` with the reason (a `trim`/`rippleTrim` that moved nothing names what stops it). `diff` = clips `added` / `removed` / `changed` (before/after start, duration,
  source, track, enabled), `durationBefore/After`, `markersAdded/Removed`.
- `POST /v1/undo` `{"expectedName"?: "Agent: X"}` -> `{"undone": true}`; only an "Agent: ..." top step is undone. An import through `/v1/import` is its own step "Agent: Import", so earlier agent steps stay reachable (test `import_is_an_agent_step_so_earlier_steps_can_be_undone`).
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
`liftRange{range, tracks?}`, `trim{clip, edge: head|tail, by, linked?: true}`, `rippleTrim{clip, edge, by, linked?: true}`, `link{clips}`, `unlink{clips}`, `move{clip, to, track?}`,
`slip{clip, by}`, `slide{clip, by}`, `roll{clip, by}`, `toggleEnabled{clips}`, `addMarker{at, name?}`, `setPixelAspect{media, aspect?}` (aspect `{num, den}` within 1:4 ... 4:1; omitted = what the file says; a media setting, counted in the diff as `pixelAspectChanges`).
`linked:false` is the UI's Alt-trim: only that clip changes, its linked partners stay (J/L cuts). `link`/`unlink` are Cmd+L / Unlink.
L-cut where clip A's sound runs 0.32 s under B's picture (A's sound `A_AUDIO` is linked to A's picture, which keeps its cut): `{"op":"trim","clip":"<A_AUDIO>","edge":"tail","by":{"value":8,"timescale":25},"linked":false}`;
a J-cut is the same on B's sound with `edge:"head"` and a negative `by`. Frame-exact when `by` is whole frames.
`range` = `{start, duration}`; `tracks` omitted = every unlocked track.

Building a cut (ids come from `/v1/state`, media from `/v1/import`):
- `addClip{media, track?, at, sourceIn?, sourceOut?, linkAudio?: true, mode?: "overwrite"|"insert"}`: the Overwrite /
  Insert command of the UI (`EditorSession::place_media`); video with its linked audio, `linkAudio:false` = video only;
  `track` = the video track, default the drop rule. `streams?: "both"|"video"|"audio"` (overrides `linkAudio`) and
  `duration?` (length on the timeline = `sourceOut` - `sourceIn`; not together with `sourceOut`). Sound only
  (`streams:"audio"`, or media without a picture such as WAV/MP3/M4A) needs an audio track: `track` = its id, default A1;
  a video track, an audio track for a picture, a media without sound or a sequence without audio track is a 422 (no track is created silently).
  Stills (PNG with alpha, JPG, after `/v1/import`) have no length: `duration` sets it, else the UI's default of 5 s; put them on a video track above V1 to overlay with transparency. Example: `{"op":"addClip","media":"<id>","at":{"value":0,"timescale":1},"sourceIn":{"value":1,"timescale":1},"sourceOut":{"value":5,"timescale":1}}`.
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
`removeKeyframe{clip, param, at}` (clip params, effect params `effect.<id>.<key>`, layer params),
`moveKeyframe{clip, param, from, to}` (clip-local times, rational or bare seconds; keeps value and ease/handles; refused when a key sits at `to`; e.g. `{"op":"moveKeyframe","clip":"<id>","param":"effect.<id>.blurriness","from":0.5,"to":0.75}`),
`shiftKeyframes{clip, param?, by, after?}` (moves the keys at or after `after`, all keys when absent, of one param or of every keyed param of the clip; all or nothing, refused when a key would leave the clip or land on one that stays; e.g. `{"op":"shiftKeyframes","clip":"<id>","by":-0.25,"after":0.75}`), `addGraphic{track, at, duration, name?, layers: [...]}` (ONE graphics clip, layers bottom first),
`setTextLayer{clip, layer, ...fields}`, `addTextLayer{clip, index?, ...fields}`, `removeTextLayer{clip, layer}`.
Text animators (the Text panel's animator rows; per character, word or line; one per side `in` = clip start / `out` = clip end, so `side` names it, default `in`):
`addTextAnimator{clip, layer, side?, effect, unit?, order?, easing?, duration?, stagger?, direction?, distance?, blur?, loops?, overshoot?, cursor?}` (refused when the side has one),
`setTextAnimator{clip, layer, side?, ...changed fields}` (refused when it has none), `removeTextAnimator{clip, layer, side?}`.
`setTextAccent{clip, layer, from, to?, color}` colors words `from`..`to` (word indexes, `to` exclusive, default from+1) of a text layer, the karaoke highlight held still; `{clear:true}` removes it; read back as `layers[].accent`. Example: `{"op":"setTextAccent","clip":"<id>","layer":"<id>","from":1,"color":"#FFEB00"}`.
`addMask{clip, shape: ellipse|rectangle, center?, size?, feather?, invert?, name?}` adds a Mask-tool mask (center and size `{x,y}`/`[x,y]` as frame fractions, default centered half size; `feather` px, default 10); read back as `masks[]` of the clip params. Example, round face window: `{"op":"addMask","clip":"<id>","shape":"ellipse","center":{"x":0.5,"y":0.4},"size":[0.4,0.6],"feather":60}`.
`effect` = fade|pop|slide|typewriter|blur|wave|pulse, `unit` = character|word|line (default word), `order` = forward|reverse|center, `easing` = linear|easeIn|easeOut|easeInOut|overshoot,
`duration` / `stagger` in ms 0...60000 (defaults 300 / by unit: character 30, word 80, line 150), `direction` = up|down|left|right, `distance` / `blur` px 0...2000, `loops` 1...50 (wave, pulse).
`cursor` (typewriter in-animator only, `null` removes it) = `{char?: "|", blink?: 530 (ms per on/off half), color?: "#rrggbb" (default the text color), holdAfter?: 600 (ms it stays after the last character)}`: a blinking cursor right after the last revealed character, same font and size, solid while typing, blinking after, gone after `holdAfter`; example `{"op":"addTextAnimator","clip":"<clip>","layer":"<layer>","effect":"typewriter","unit":"character","cursor":{"char":"_","blink":400,"holdAfter":900}}`. `overshoot` (1...3, pop only) sets the pop's peak scale (1.08 = 108 %); absent or null = the easing's own peak (about 1.098). A text layer's background pill follows the words its In animator reveals (grows from an empty round pill, shrinks again with the Out animator) with `style.background.followReveal: true` (e.g. `layers:[{text:"Hello big world", style:{background:{color:{red:1,green:0.2,blue:0.2,alpha:1}, padding:{horizontal:30,vertical:14}, cornerRadius:35, followReveal:true}}}]` plus an In animator `{effect:"fade", unit:"word"}`); one box over all lines. Tracking is a keyable param `layer.<id>.tracking` (points between letters, -20...200; keys replace the style's tracking while they exist, read back in `GET /v1/clip/<id>/params`); example title that flies in wide to tight in 8 frames at 30 fps: `setKeyframe{param:"layer.<id>.tracking", at:{value:0,timescale:1}, value:40, ease:"easeOut"}` + `setKeyframe{..., at:{value:8,timescale:30}, value:2, ease:"easeOut"}` (the same `ease` / handles as every other parameter). `GET /v1/textAnimators` lists these. Read back: `layers[].animators` = `{in?, out?}` and the params `layer.<id>.animator.in|out` (so `diff.paramChanges` shows them). Example: `{"op":"addTextAnimator","clip":"<clip>","layer":"<layer>","effect":"slide","unit":"word","direction":"left","stagger":120}`.
Layer fields (all optional but `text` on a new layer; unknown keys are refused): `name, text, font, size, color, weight (100...900 or thin|light|regular|medium|semibold|bold|heavy|black), align (left|center|right), italic, tracking, lineSpacing, allCaps, style (raw TextStyle fields merged), position, scale, rotation, opacity`.
Transitions read back: `GET /v1/state` has `sequences[].transitions` = `[{id, track, kind, duration, alignment, outgoing?, incoming?}]` (kinds as in `GET /v1/transitions`; only `incoming` = fade in at that head, only `outgoing` = fade out at that tail); the commit diff has `transitionsAdded` / `transitionsRemoved` in the same shape (`addTransition` shows the new one, `removeTransition` the gone one).
The commit reply's `diff.paramChanges` lists, per clip, each parameter that changed (`before` / `after` = `{value, keyframes?}`); the new clip of
`addGraphic` is in `diff.added`, its layer ids in the params read.
```sh
curl -s -H "Authorization: Bearer $token" -d '{"sequence":"<id>","name":"Titles","operations":[
 {"op":"addGraphic","track":"<video track>","at":{"value":0,"timescale":1},"duration":{"value":3,"timescale":1},
  "layers":[{"text":"Title","size":96,"color":"#ffffff"},{"text":"Subtitle","position":{"x":0,"y":120}}]},
 {"op":"setKeyframe","clip":"<clip>","param":"audio.volumeDb","at":{"value":1,"timescale":1},"value":-6}]}' http://127.0.0.1:$port/v1/commit
```
Ease handles on a key: `setKeyframe{..., ease?: linear|easeIn|easeOut|easeInOut}` applies the inspector's own curve (easeIn = Ease-in 100 %: slow start, speeds up;
easeOut = Ease-out 100 %; easeInOut = Ease-in-out 33 %), or explicit Premiere-style temporal handles `inHandle` / `outHandle: {influence: 0...100 (% of the segment), speed?}`
(`speed` in value units per second needs the neighbor key to exist and uses the Premiere importer's one conversion, `EaseHandle::from_speed`; left out = flat). `ease` and handles exclude each other; handles make the key `bezier`
unless `interpolation` says otherwise. Read back in `params[].keyframes[]` and `diff.paramChanges`: `inHandle` / `outHandle` = `{influence %, dy}`.
Example: `{"op":"setKeyframe","clip":"<clip>","param":"motion.scale","at":{"value":0,"timescale":1},"value":1,"outHandle":{"influence":80}}`.
Transitions: `GET /v1/transitions` lists every kind (`kind` wire name, name, `track` video|audio, `element`, `defaultSeconds`).
`addTransition{clip, edge: head|tail, kind, duration, alignment?: center|start|end}` or `addTransition{between: [outgoing, incoming], kind, duration, alignment?}` (touching clips);
the element kinds (move, zoom, pop) take a clip edge only. Same path as the Apply Transition command, with the kind's factory look. `removeTransition{transition: id}`. Example:
`{"op":"addTransition","clip":"<clip>","edge":"head","kind":"zoomIn","duration":{"value":1,"timescale":2}}`.
Effect presets: `GET /v1/effectPresets` lists the built-in presets (motion, keying, looks, audio chains; `at` = where their keys sit). `applyPreset{clip, preset: id|name, at?: head|tail, mode?: absolute|relative}`
runs the Effects panel's apply (one clip); `at` must match the preset's anchor. (`GET /v1/presets` stays the export presets.) Your own presets (saved or imported, Library > Presets, effect kind) are listed in the same call with `"user": true`, `kind`, `anchor` (start|end|stretch) and `at`; `applyPreset` takes their id or name (case-insensitive; a built-in name wins; two with one name need the id) through the same code as the panel and keeps the preset's own anchor (`at` must match it). Example: `{"op":"applyPreset","clip":"<clip>","preset":"Zoom Out & In / BOT"}`.
Keyed motion presets (ids as `applyPreset` takes them): `tailZoom` (last 19.4 f, 100 -> 110 %, single-sided: one clip), `headZoom` (130 -> 100 % over 19.4 f, single-sided: one clip), `overlayPop` (opacity pop + scale swell, keys scale with the clip length; not a cut transition), `talkPulse` (100 -> 110 -> 100 % over 110.1 f; not a cut transition); frames at 29.97 fps. Example: `{"op":"applyPreset","clip":"<clip>","preset":"tailZoom"}`.
`addZoomCut{outgoing, incoming, direction: in|out, outFrames?, inFrames?, fadeFrames?: 2}` (touching video clips) is the two-sided zoom transition at a cut, written as `setKeyframe` keys (`motion.scale`, `opacity`; a key at the same time is replaced, other keys stay): both pictures zoom the same way (in = 100 -> 110 %, out = 110 -> 100 %), the leaving clip eases in and the arriving one eases out (fastest at the cut), only the picture on the higher track fades `fadeFrames` (same track = hard cut, no fade). Default lengths: upper leaving 19 f, lower arriving 33 f, lower leaving 29 f, upper arriving 18 f, each capped at half the clip; a clip under 0.5 s gets no zoom. ONE undo step "Agent: Zoom cut" (when the batch has no `name`); `diff.paramChanges` reads the keys back. Example: `{"op":"addZoomCut","outgoing":"<clip>","incoming":"<clip>","direction":"in"}`.
Motion blur: `motion.shutterAngle` > 0 on a moving clip gives the compositor its sub-frame samples (test `shutter_angle_set_through_the_api...`).
Not covered yet: effects on a single layer (`addEffect` acts on the clip).

## Export, jobs, Sync Audio, first sequence
- `POST /v1/export {sequence?, path, preset?, range?}` -> `{job}` at once. The same model and queue as the Export sheet
  (`ShellHost::api_export`): `path` is absolute, no `..`, and ends in the preset's extension (`.mp4`); an existing file at
  `path` is replaced. `preset` = an id of `GET /v1/presets` (`{presets:[{id,name}]}`; `tiktok-9x16` is accepted as an alias
  of `tiktok-h264`); omitted = what the sheet would propose. `range` = `"entire"` (default), `"inOut"` or `{start, end}` (times).
  Loudness normalization is always OFF. Refusals (422): unknown preset/sequence, wrong extension, the sheet's own validation texts.
  Example: `{"path":"/Users/me/Exports/reel.mp4","preset":"tiktok-9x16"}`.
- `GET /v1/jobs/{id}` -> `{id, kind: export|import|transcript|captions|capture, state: queued|running|done|failed, progress 0..1, result?, error?}`.
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
  A capture that needs more than about 10 s (many frames) answers with the job shape and its `job` id like captions; read the frames from `GET /v1/jobs/<id>`.
  A frame that cannot be decoded (truncated file) fails within about 0.5 s with the engine's reason: `422` when a file does not open, else `500` (`render at <timecode>: decode ...`), never a 15 s wait and a 503.
- `POST /v1/media/frames {media, at | count, width?}`: source frames of a media item (`count` = evenly spaced), same reply.
- `POST /v1/media/transcript {media | clip}`: words with times (`{text,from,to,confidence}`); a clip answers in sequence time.
  A long run answers the job shape (`{job, id, kind:"transcript", state:"running", progress}`) after 10 s: poll `GET /v1/jobs/{id}` (`state` running, done or failed, `result`).
- `POST /v1/media/levels {media | clip | sequence, from?, to?}`: `integratedLufs`, `truePeakDb`, `samplePeakDb`, `silences`
  (ranges below -50 dBFS of 0.4 s or more, `from`/`to` times). `clip` measures that clip alone (with its linked partners)
  as it sounds: volume line, Audio Gain and effects applied (a clip at -60 dB reads silent); `media` is the raw file,
  `sequence` the whole mix.
- `POST /v1/media/scenes {media}`: answers `501` (no shot-cut engine behind the API yet).
- `POST /v1/importPremiere {path, dryRun?}`: File > Import Premiere Project into the open project as ONE undo step
  "Agent: Import Premiere". Reply: `sequences[{id,name,durationSeconds}]`, `sequenceIds`, `mediaIds`, `mapped`,
  `approximated`, `dropped`, `report[{feature,status,count,note}]`. Then read `/v1/state` to learn the editor's style.
- `GET /v1/state` lists each sequence's `captionTracks` (`{id, name, locked, visible, style, look?, items: [{id, text, from, to, style?}]}`, no word timings); a commit's `diff` reports `captionsAdded` / `captionsRemoved` (absent when 0), e.g. `"captionsAdded": 12` after `addCaptions`.
- `GET /v1/captionStyles`: the caption styles (`default`, `outline`, `pill`, `paul`), the `lookKeys`, animations, layouts and positions `addCaptions` accepts.
- `POST /v1/addCaptions {clip | sequence, style?, wordByWord?, position?, wordsPerCaption?, size?, color?, shadow?, box?, positionY?, font?, weight?}`: the app's own Create Captions on the speech of a
  clip or a sequence (must be the sequence shown in the timeline). `wordByWord` (default true) uses the short-video preset, one
  word per caption; `position` is `top`, `center` (default) or `bottom`. ONE undo step "Agent: Add Captions". A long run answers
  a job id like transcript. Example: `{"clip":"<id>","style":"pill","wordByWord":true,"position":"center"}`.
  Look at creation (same caption renderer as the Captions panel; the look is saved as a Caption Look in the app's Look store, like "save look" in the Captions panel, so it survives save and reopen; the same values make one entry): `wordsPerCaption` 1-3 (wins over `wordByWord`), `size`, `color` (`#rrggbb[aa]`),
  `shadow` `false | {blur, opacity, offset}`, `box` `false | {color, radius}`, `positionY` 0..1 of the frame height (wins over
  `position`), `font`, `weight`. `style:"paul"` = white Inter Bold, 2 words, y 0.7068, size 70 px at 1080 px sequence width (scales with the width), pop 90 % -> 105 % at frame 3 -> 100 % at frame 4 (linear), soft shadow, no box; its keys can be overridden.
  Example: `{"clip":"<id>","style":"paul","wordsPerCaption":3,"box":{"color":"#00000099","radius":12}}`.
  Own words instead of a transcript: `words: [{text, from, to}]` (sequence seconds, bare or rational; no speech recognition runs; needs `clip` or `sequence` only to name the sequence).
  A saved look by name: `look: "<name>"` (a look of the user's Look store, as the Captions panel lists it; read only; case-insensitive; 404 with the saved names when unknown; it brings its own style and segmentation, so it refuses `style`, `wordByWord`, `wordsPerCaption` and the look keys; `position` still applies).
  Example: `{"sequence":"<id>","look":"Caption Look 1","words":[{"text":"Hello","from":1.0,"to":1.4},{"text":"world","from":1.4,"to":2}]}`.
- `GET /v1/fonts`: `{count, families}`, the families of the font picker (bundled + installed). Use them as `font` in `addCaptions`,
  `addGraphic` and `setTextLayer`. A text layer's `style` object takes any TextStyle field, e.g. `"style":{"background":
  {"color":{"red":0,"green":0,"blue":0,"alpha":0.6},"padding":{"horizontal":24,"vertical":12},"cornerRadius":12},
  "shadow":{"color":{"red":0,"green":0,"blue":0,"alpha":0.6},"offsetX":0,"offsetY":2,"blur":8}}`.
  Not supported yet: per-word style runs inside one text layer (the text model has one style per layer, only a karaoke highlight
  range). Color emoji (Apple Color Emoji sbix, Noto CBDT) render in text layers and burned-in captions like in the UI.
