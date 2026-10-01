# Spec: timeline (selection, trims, tools, snapping, track headers, markers, navigation)

Job E, area `timeline`. Written by reading the code on `main` plus `docs/PREMIERE-BEHAVIOR.md` and `docs/audit/timeline.md`.

## Sources and confidence (read first)
- `scripts/fetch_adobe_guide.py` could not run in the cloud: `web.archive.org` and `helpx.adobe.com` are blocked by the egress
  proxy. `docs/reference/adobe/` is empty, so **no Adobe page was read in this run**.
- Premiere behaviour below comes from `docs/PREMIERE-BEHAVIOR.md` (tags kept: [S] = sourced, "unverified" = memory) plus one
  web search. New facts from that search, in own words:
  - Q/W with Shift = rolling variant (the cut moves, the clip under the playhead gets shorter and the neighbour longer, total
    length unchanged); Q/W with Option = non-ripple, the gap stays. Plain Q/W = ripple. (ProVideo Coalition, "Do you know the
    Adobe Premiere Pro trimming keyboard shortcuts"; Adobe Learn "trimming timeline premiere cc".)
  - In Trim mode a Cmd-click on the monitor images switches between regular (red) and ripple (yellow) trimming.
- Rows marked **(verify)** must be checked on a Mac against the real app before the fix is built. Our side (file:line) is read
  from code and is reliable.
- Re-run the fetch script from a Mac and re-check every **(verify)** row; this file does not replace that.

Sizes: S = under half a day, M = 1-2 days, L = more. "Verdict": same / differs / missing.

## 1. Selection

| User action | Premiere result | Sequence Studio today | Verdict | Fix |
|---|---|---|---|---|
| Click clip body | Selects clip plus linked partners when Linked Selection is on | `TimelineInteraction.swift:184-208` selects the link group; Option inverts per gesture (`:145`) | same | - |
| Shift-click clip | Toggles clip (group) in selection | `:204-205` | same | - |
| Click empty area | Deselects; playhead does not move | `:215-218` clears selection, starts marquee | same | - |
| Drag on empty area | Marquee; Shift adds | `:415` `updateMarquee`, `baseSelection` kept on Shift | same | - |
| Click on a gap | Selects the gap; Delete closes it | `:210-214`, gap highlight, ripple delete | same | - |
| Click clip edge (Selection tool) | Selects the edge (red); Cmd = ripple (yellow) | `:186-203` edge selection, `ripple: m.contains(.command)` | same | - |
| Shift-click second edge | Adds edge; both sides of a cut = rolling | `:194-196`, `EdgeEdits.isRoll` | same | - |
| Click edge on a track that is not selected, other tracks | Edge selection can span tracks via Shift-click | Same code path; no per-track restriction | same | - |
| Double-click a cut | Selects the cut, opens Trim mode (two-up Program monitor, -5 -1 +1 +5 buttons) | Only captions and markers handle `clickCount == 2` (`TimelineView.swift:401,406`) | missing | L |
| Ctrl+T (cycle trim type of selected edit) | Ripple in, ripple out, roll | No command in `EditorCommand.swift` | missing | S |
| Preference "select nearest edit point" | Click near a cut picks roll or ripple by pointer position | `nearestEdge` (`:434`) only used by B/N tools | missing | M, verify |
| Opt-click clip | Selects only that clip of a linked pair | `:145` inverts linked selection while Option is held | same | - |
| Track Select Forward (A) click | Clip and everything to the right on that track; Shift = all tracks | `:219-223`, `selectForward` (`:406`) | same | - |
| Track Select Backward (Shift+A) | Same, to the left | `:219`, `toolState.selectBackward` | same | - |
| Cmd+A / Shift+Cmd+A | Select all / deselect | `CommandMap.swift:101`, `AppController+TimelineOps.swift:34-35` | same | - |
| D | Select clip at playhead (targeted track) | `selectClipAtPlayhead`, key at `CommandMap.swift:102` | same | - |
| `/` | Mark the selection's In/Out | `markSelection` | same | - |

## 2. Moving, copying, inserting by mouse

| User action | Premiere result | Sequence Studio today | Verdict | Fix |
|---|---|---|---|---|
| Drag a clip | Overwrite move, gap left behind | `updateMove` (`:479`); drag starts after 3 pt (`:42`) | same | - |
| Drag with Cmd | Insert move: gap closes behind, opens at drop | `:497-515` `.moveInsert` | same | - |
| Drag with Opt | Copy, original stays; cursor shows plus | `copying` (`:481`), no copy cursor (`audit/timeline.md`) | differs (cursor) | S |
| Cmd+Opt drag | Insert a copy | `copying = option && !insert` (`:481`): Cmd wins, no insert-copy | missing | S, verify |
| Drag to other track | Linked partner keeps its track | lane logic `:528-560`, video up k = audio down k | differs, verify (Premiere may keep partner's track) | S |
| Drag past time 0 | Clamped at 0 | `d = max(d, .zero - minStart)` (`:495`) | same | - |
| Drag to empty area above/below | New track created | `dropRow` `isNew`, `.addTrack` | same | - |
| Drag a clip while holding Shift | Constrain to horizontal/vertical (unverified) | none | missing | S, verify |
| Move snaps | Head and tail snap to cuts, playhead, markers, 0 | `snapMove` (`Snapping.swift:~75`), threshold 8 pt (`TimelineGeometry.swift:56`) | same | - |

## 3. Trims

| User action | Premiere result | Sequence Studio today | Verdict | Fix |
|---|---|---|---|---|
| Hover edge | Red bracket cursor, 6 pt-ish zone | Handle 6 pt, shrinks to 1/3 of narrow clips (`TimelineGeometry.swift:55,198`) | same | - |
| Drag edge | Regular trim, shortening leaves a gap, stops at neighbour and at source end | `updateTrim` (`:617`), `Timeline.trim` (`Timeline+Edits.swift:30`) | same | - |
| Cmd-drag edge | Ripple trim, yellow bracket | Edge selection `ripple` flag (`:188`); orange highlight | same (cursor differs: no modifier-follow, `audit/timeline.md`) | M |
| B (ripple tool) drag | Ripple, two-up Program monitor during drag | `:224-227`; no two-up view | differs | L |
| N (rolling tool) drag | Moves the cut, total length constant | `updateRoll` (`:639`) | same | - |
| Drag between two clips with Selection tool, both edges selected | Roll | `EdgeEdits.isRoll` | same | - |
| R (rate stretch) | Changes speed, source range unchanged | `.rateStretch` (`:228,632`) | same | - |
| Y (slip) drag | In/Out move together; media follows pointer; 4-up monitor | `updateSlip` (`:652`); no 4-up view | differs (monitor only) | L |
| U (slide) drag | Clip moves, neighbours trim | `updateSlide` (`:659`) | same | - |
| Trim a linked clip | Partner trims by the same amount; Opt trims one side | `group(..., linked:)` in all updates | same | - |
| Opt+Left/Right with edge selected | Trim 1 frame | Handled via `.previousKeyframe/.nextKeyframe` fall-through (`AppController+TimelineOps.swift:46-52`) | same, fragile (shares keys) | S |
| Opt+Shift+Left/Right | Trim 5 frames (Preferences > Trim) | `CommandMap.swift:107`; 5 is hard-coded | differs (not a preference) | S |
| Q / W | Ripple trim previous/next edit to playhead on targeted tracks | `session.rippleTrimToPlayhead` (`AppController+Commands.swift:82-83`) | same | - |
| Shift+Q / Shift+W | Rolling variant (moves the cut to the playhead, length unchanged) | not bound | missing | S |
| Opt+Q / Opt+W | Non-ripple trim to playhead, gap stays | not bound | missing | S |
| E | Extend selected edit to playhead | `session.extendEdit` (`EditorSession+TimelineOps.swift:62`) | same | - |
| Playhead after Q | Stays where the picture is (new edit point) | FEEDBACK-4 #20, implemented | same | - |
| Trim past neighbour or source end | Clamped, "end of media" cue | clamped in `Timeline.trim`; no visual cue | differs (cue) | S |
| Nudge selected clips | Opt+Left/Right in docs; audit says Cmd+Left/Right 1 frame, +Shift 5 | `CommandMap.swift:105-106` Cmd+arrows | same as audit; **(verify)** which one Premiere uses | S |
| Opt+Up/Down on selection | Move clip to track above/below | not bound | missing | S, verify |

## 4. Tools

| Tool / key | Premiere | Sequence Studio today | Verdict | Fix |
|---|---|---|---|---|
| Selection V, Track Fwd A, Track Back Shift+A, Ripple B, Rolling N, Rate R, Razor C, Slip Y, Slide U, Hand H, Zoom Z, Type T | keys as listed | `CommandMap.swift` tools block | same | - |
| Razor click | Cuts clip and linked partner at click | `:237-242`, `razorPreview` (`:685`) | same | - |
| Razor + Shift | Cuts all tracks (locked excluded) | `:243-248` | same | - |
| Razor snapping | Snaps to playhead when snapping on | `:689` | same | - |
| Zoom tool click / Opt-click / marquee | Zoom in / out / to marquee | `.zoom` tool exists; no click handler in `mouseDown` switch (`:172-252`) falls to `default: return` | missing | S |
| Hand drag | Pans timeline | `:165-169, 265` | same | - |
| Pen (P) | Adds keyframes on rubber bands | not a timeline tool here | missing | L (effects area) |
| Tools sticky | Stay armed until changed | assumed same | same | - |

## 5. Snapping

| Aspect | Premiere | Sequence Studio today | Verdict | Fix |
|---|---|---|---|---|
| Toggle | S and magnet button | `CommandMap.swift:100` and ruler-corner button (`TimelineView.swift:742`) | same | - |
| Targets | Cut points on all tracks, playhead, markers, In/Out marks, time 0 | `Timeline.snapPoints` (`Snapping.swift:~24`): clip edges, playhead, markers, 0 | differs: In/Out marks, clip markers, keyframes missing | S |
| Threshold | Screen pixels, not time | 8 pt (`TimelineGeometry.swift:56`); playhead 10 pt (`PlayheadLogic.swift:25`) | same (Premiere's exact value unknown, verify) | - |
| No snap hit | Frame grid | `snap(... frameDuration:)` falls back to frame grid | same | - |
| Snap guide | Thin vertical line across tracks | `SnapGuides.swift` | same | - |
| Scrubbing the playhead | Snaps only while Shift held | `PlayheadSnap` (`PlayheadLogic.swift:23`), `scrubTime(shift:)` | same | - |
| Dragging a clip with snapping off | No snap, frame grid still applies (unverified) | frame snap only when snapping on (`snappedDelta`, `:674`: returns raw delta when off) | differs, verify | S |

## 6. Track headers

| User action | Premiere result | Sequence Studio today | Verdict | Fix |
|---|---|---|---|---|
| Target toggle (V1/A1 block) | Toggles target; Shift adds, Opt solo (unverified) | one chip, one flag (`audit/timeline.md`) | differs | S |
| Source patch | Separate from target, per source channel | not modelled | missing | L |
| Sync lock toggle | Per track | header button (`audit/timeline.md`) | same | - |
| Track lock | Padlock, hatched clips, no edits | model `isLocked` (`Model.swift:~239`), SSCore refuses | same | - |
| Eye / M / S | Visibility, mute, solo | `Model.swift:266` fields | same | - |
| Drag header bottom edge | Resize that track; Shift = all of the kind | `TrackSizing.swift:11-18` (min 18, max 240, grab 3), `TimelineView.swift:392-400,416-420` | same | - |
| Double-click header edge | Toggle two standard heights (verify) | not handled | missing | S, verify |
| Opt+scroll on headers | Track height (verify) | Opt/Cmd+scroll zooms time (`TimelineView.swift:335`) | differs | S, verify |
| Cmd+= / Cmd+- (video), Opt+= / Opt+- (audio) | Taller/shorter | `CommandMap.swift:113-114` | same | - |
| Shift+= / Shift+- | Expand / minimize all | `:115` | same | - |
| Drag split between V and A | Moves visible split | `TrackSizing.splitDragged` | same | - |
| Right-click header | Add/Delete track, Rename | `TimelineContextMenu.swift` | same | - |
| Height persistence | Per sequence | `TrackSizing.swift:84` (UserDefaults key per sequence) and `Track.height` | same | - |

## 7. Markers

| User action | Premiere result | Sequence Studio today | Verdict | Fix |
|---|---|---|---|---|
| M | Add marker at playhead; M again on the same spot opens the dialog | `Timeline.markAtPlayhead` (`Timeline+Markers.swift:44`) | same | - |
| Double-click marker in ruler | Opens dialog | `TimelineView.swift:406` | same | - |
| Shift+M / Shift+Cmd+M | Next / previous marker | `CommandMap.swift:68`, `Timeline+Markers.swift:50-51` | same | - |
| Drag marker in ruler | Moves it | `moveMarker` exists; no ruler drag (`audit/timeline.md`) | missing | S |
| Marker with duration | Range shown in ruler | `Marker.duration` stored, UI missing | missing | M |
| Clip markers | Attached to clips, move with them | not modelled | missing | L |
| Markers on ripple/insert | Sequence markers do not move (unverified) | `shiftMarkers(from:by:)` (`Timeline+Markers.swift:62`) exists; callers not checked | verify | S |
| Colours | 8 colours | `Marker.color` | same | - |

## 8. Navigation, scroll, zoom

| User action | Premiere result | Sequence Studio today | Verdict | Fix |
|---|---|---|---|---|
| Left/Right, Shift+Left/Right | 1 / 5 frames | `CommandMap.swift:44-45` (5 hard-coded) | same | - |
| Up / Down | Previous/next edit on targeted tracks; Shift = any track | `:96,103` | same | - |
| Home / End | Sequence start / end | `:46` | same | - |
| `=` / `-` | Zoom in/out, fixed factor | factor 2.5 per key (`TimelineZoom.swift:7`) | differs: Premiere's step unknown, 2.5 is coarse | S, verify |
| `\` | Fit, press again restores | `zoomToFit` (`TimelineView.swift:305`) | same | - |
| Opt/Cmd + scroll | Zoom around pointer | `scrollWheel` (`:333-340`), anchor = pointer | same | - |
| Pinch | Zoom | `magnify` (`:352`), gain 4.5 | same | - |
| Shift+scroll | Horizontal scroll | `:344` | same | - |
| Mouse wheel notch | Scrolls | 24 pt per notch (`:342`) | verify feel | - |
| Zoom limits | Max about 1 frame across screen (unverified) | min 0.02 pt/s, max 400 pt/frame, 4 frames across at max (`TimelineZoom.swift:15-19`) | same | - |
| Navigator bar | Handles zoom, middle pans, double-click fits | `TimelineZoomBar.swift:11` (16 pt) | same | - |
| Click ruler / drag | Seek / scrub, playback keeps correct state | `TimelineView.swift:405-410` | same | - |
| Auto-scroll when playing | Page / smooth / none (Preferences) | Page only, manual scroll wins (`PlayheadLogic.swift:4-24`) | differs: no Smooth/None preference | M |
| Playhead x at page | lands at left | margin 24 pt (`PlayheadLogic.swift:19`) | same | - |

## 9. Context menus and edit commands

| Item | Premiere | Sequence Studio today | Verdict | Fix |
|---|---|---|---|---|
| Clip menu | Cut, Copy, Paste, Paste Insert, Clear, Ripple Delete, Link, Nest, Label, Rename | `TimelineContextMenu.swift` per `audit/timeline.md` | same | - |
| Group / Ungroup (Cmd+G) | Groups clips | `.group` bound (`CommandMap.swift:108`), no model | missing | L |
| Enable/Disable clip (Shift+Cmd+E) | Disables output | not modelled | missing | M |
| Speed/Duration (Cmd+R) | Dialog | `.speedDuration` → `requestSpeedDuration` (`AppController+Commands.swift:92`) | same | - |
| Paste Attributes (Cmd+Opt+V) | Copies effects/keyframes | `.pasteAttributes` bound; handler not in `executeTimelineOp` | verify | M |
| Duplicate (Shift+Cmd+/) | Duplicates selection | missing | S |
| Reveal in Project | yes | removed | missing | S |
| Out-of-sync badge + Move/Slip into Sync | Red badge with offset | not shown | missing | M |

## 10. Feel numbers (ours today)

| Parameter | Value | Where |
|---|---|---|
| Drag threshold | 3 pt | `TimelineInteraction.swift:42` |
| Snap threshold | 8 pt (clips), 10 pt (playhead scrub) | `TimelineGeometry.swift:56`, `PlayheadLogic.swift:25` |
| Trim handle | 6 pt max, 1/3 of narrow clips | `TimelineGeometry.swift:55,198` |
| Zoom key step | x2.5 | `TimelineZoom.swift:7` |
| Wheel zoom gain | precise 0.02, wheel 0.2; pinch 4.5 | `TimelineZoom.swift:9-13` |
| Track height | min 18, max 240, step 8, thin below 22 | `TrackSizing.swift:11-16` |
| Ruler | 22 pt | `TimelineGeometry.swift:50` |
| Wheel notch | 24 pt | `TimelineView.swift:342` |

Premiere's own numbers for these are not in any source we could read; measure them on a Mac (screen recording, 60 fps) before tuning.

## Ranked backlog (YouTube/TikTok editing first)

Each item stands alone. "AC" = acceptance criteria that a unit test can check (SSCore or SSEditorUI logic, no UI).

1. **Q/W Shift and Opt variants** (S). AC: with clip A [0,10) and B [10,20) and playhead at 7, Shift+W rolls the cut to 7 (A = [0,7), B = [7,20), sequence end unchanged); Opt+W trims A to [0,7) and leaves a gap [7,10); plain W ripples B back by 3. Undo is one step each.
2. **Cmd+Opt drag = insert copy** (S). AC: `move(copy: true)` combined with insert adds a copy at the drop time, ripples later clips by its duration, keeps the original; one undo step.
3. **Zoom tool click / Opt-click / marquee** (S). AC: pure function `zoomClick(scale, anchorX, zoomOut:)` returns a scale multiplied or divided by the key step with the time under the anchor fixed; marquee returns scale and scrollX that fit the dragged range.
4. **Drag marker in ruler** (S). AC: `moveMarker` through the interaction layer clamps at 0, snaps to clip edges when snapping is on, one undo step.
5. **Ctrl+T cycle trim type of selected edit** (S). AC: `EdgeSelection` cycles ripple-in, ripple-out, roll, then back; selection of edges is unchanged except for the ripple flag and the added/dropped side.
6. **Duplicate (Shift+Cmd+/)** (S). AC: copies selected clips immediately after the selection's end on the same tracks (overwrite), links kept between copies, selection moves to the copies, one undo step.
7. **Snap targets: In/Out marks** (S). AC: `Timeline.snapPoints` includes In and Out when set; snap to them within threshold.
8. **Opt+Up/Down moves selected clips one track** (S, verify). AC: video clips move up a lane, audio clips down (mirrored), blocked at the outermost lane, locked tracks refuse, one undo step.
9. **Trim large step as a preference** (S). AC: step defaults to 5, setting 1...30 changes `trimBackward5/Forward5` and Shift+arrow step result.
10. **Target toggle modifiers** (S). AC: Shift-click toggles one track without clearing; Opt-click targets only that track.
11. **Double-click header edge toggles height** (S, verify). AC: `TrackSizing.toggled(rows:track:wholeKind:)` flips between minimized height and the default; Shift applies to the whole kind.
12. **Trim end-of-media cue** (S). AC: `Timeline.trim` result reports `clampedBySource` so the UI can draw the cue; no change in resulting times.
13. **Shift-constrained drag** (S, verify). AC: `updateMove` with Shift locks the axis that moved first for the rest of the gesture.
14. **Marker duration UI** (M). AC: marker with duration > 0 reports its range; `markers(in:)` includes a marker whose range overlaps; range drag changes duration, one undo step.
15. **Auto-scroll preference: Smooth / None** (M). AC: `TimelineFollow` gains a mode; None never returns a scroll; Smooth returns a scrollX that keeps the playhead at a fixed offset.
16. **Out-of-sync badge** (M). AC: `Timeline.syncOffsets(for:)` returns the frame offset between linked clips' source-in vs timeline start; zero when aligned; sign matches Premiere's (verify).
17. **Move into Sync / Slip into Sync** (M). AC: the first moves the clip so offset = 0; the second slips it so offset = 0; both one undo step, refused on locked tracks.
18. **Enable/Disable clip** (M). AC: `Clip.isEnabled` default true, decoded as true from old files; disabled clips are skipped by the render and audio mix; round-trips in the project file.
19. **Select nearest edit point automatically** (M, verify). AC: `EdgeEdits.nearestEdit(at:x, tolerance:)` returns roll when within the middle zone of a cut, otherwise ripple or regular per side.
20. **Cmd-hover ripple cursor** (M). AC: cursor-mapping function returns the ripple variant when Cmd is held over an edge handle and the plain variant otherwise (pure function in `TimelineCursorMap.swift`).
21. **Opt-hover copy cursor** (S). AC: cursor-mapping function returns the copy variant over a clip body when Option is held.
22. **Paste Attributes** (M). AC: copies effects, keyframes and speed (not position or source range) from one clip to selected clips; keyframe times are offset to the target clip's start; one undo step.
23. **Group / Ungroup** (L). AC: grouped clips select and move together, survive copy/paste as a group; ungroup restores individuals; old files decode with no groups.
24. **Trim mode (double-click a cut)** (L). AC (model only): `TrimSession` holds an edit, a type, and applies -5/-1/+1/+5 as ripple or roll with one undo step per press; Ctrl+T cycles.
25. **Two-up display during ripple/roll** (L). AC: pure function returns outgoing and incoming source frames for the edit; Mac side draws them.
26. **Four-up display during slip/slide** (L). AC: same, for four frames.
27. **Source patching** (L). AC: per source channel patch state (video, audio 1...n), Insert/Overwrite use patches while Cmd+V and Lift/Extract use targets.
28. **Clip markers** (L). AC: markers stored on the clip, move with it on move/trim/ripple, removed with it, copy/paste keeps them.
29. **Keyframe snap targets** (S). AC: snapPoints can include clip keyframe times when "show keyframes" is on.
30. **Marker snap on ripple** (S, verify). AC: ripple/insert/extract shift or keep sequence markers per Premiere's rule (verify first); test both outcomes of the chosen rule.
31. **Reveal in Project** (S). AC: command selects the clip's media in the Project panel model.
32. **Wheel and zoom feel pass** (S). AC: none unit-testable; record Premiere numbers (zoom per key, scroll per notch) then update the constants and their tests.
33. **Zoom key step review** (S, verify). AC: `keyStep` constant changed to the measured Premiere value; `TimelineZoom` tests updated.
34. **Opt+scroll on track headers changes height** (S, verify). AC: `TrackSizing.scrolled(rows:track:delta:wholeKind:)` clamps to min/max.
35. **Frame-snap when snapping is off** (S, verify). AC: with snapping off, a drag delta still lands on whole frames (or not, per verified rule).
36. **Gap selection across tracks** (S, verify). AC: Shift-click on gaps on several tracks selects them; ripple delete removes the common range or refuses as Premiere does.
37. **Linked drag to another track keeps partner's track** (S, verify). AC: moving V1 clip up one lane leaves its linked A1 clip on A1.
38. **Trim shortcuts without Opt+arrow keyframe collision** (S). AC: `CommandMap` has distinct bindings for keyframe navigation and trim; `duplicates` stays empty; trim works with an edge selected in the timeline scope only.
39. **Lift/Extract on selected clips vs In/Out** (S, verify). AC: with clips selected, lift removes those clips; otherwise In/Out range on targeted tracks.
40. **Re-run Adobe fetch and verify rows** (S). AC: `docs/reference/adobe/` exists locally, every **(verify)** row above is confirmed or corrected in this file.
