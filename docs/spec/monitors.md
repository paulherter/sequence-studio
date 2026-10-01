# Premiere behaviour spec: monitors (Source/Program, 3/4-point edits, JKL, Project panel)

Job E, area `monitors`. Written from a cloud (Linux) run: nothing was built or run, every "today" cell comes from reading the code.

## Sources and confidence

- **Adobe's guide could not be fetched.** `scripts/fetch_adobe_guide.py` failed: `web.archive.org` and `helpx.adobe.com` are blocked by this
  environment's network policy (HTTP 403 on CONNECT). `docs/reference/adobe/` is therefore empty. Adobe wording appears only as web-search
  snippets, paraphrased. Re-run the script on a machine with access and re-check the rows marked (unverified).
- Behaviour is described in my own words. Pages cited by name: Adobe "Playing assets", "Three point edits", "Set In and Out points in the
  Source Monitor", "Open or clear a clip in the Source Monitor", "Customize the Icon View in Project panel"; Larry Jordan "Create a Fit-to-Fill
  Edit in Adobe Premiere Pro"; PremiumBeat "Premiere Pro Hover Scrub in the Project Panel"; ProVideo Coalition JKL/Match Frame posts; Adobe
  community threads on the Fit Clip dialog and preroll/postroll.
- Earlier work: `docs/audit/monitors.md` (what was built overnight) and `docs/PREMIERE-BEHAVIOR.md` sections 2.1-2.4, 5, 10. This file does not
  repeat rows that audit marks "same" unless there is a detail to check. Tags: **[W]** = confirmed by a web source above; (unverified) = from
  memory, check in the real app.
- Shortcuts are macOS. Verdicts: same / differs / missing. Sizes: S (under half a day), M (1-2 days), L (more).
- Line numbers are in the working tree of this branch. `P:` = `Packages/`, `A:` = `App/Sources/`. File names without a package: `SSCore/...` = `Packages/SSCore/Sources/SSCore/`; bare `MonitorPanel*`, `Project*`, `KeyRouter`, `CommandMap`, `EditorSession*` = `Packages/SSEditorUI/Sources/SSEditorUI/` (EditorSession in `Session/`); `PlaybackNudge`/`Playback` are in SSCore.

## 1. Marking (Source and Program)

| User action | Premiere | Sequence Studio today | Verdict | Fix |
|---|---|---|---|---|
| `I` in Source | In at the Source playhead. If an Out exists at or before it, Out is cleared. [W] | `SourceMonitor.markIn` stores In at `position`; `setSourceIn` clears an Out at or before it (A:SourceMonitor.swift:237, P:SSCore/SourceMarks.swift:23-29) | same | - |
| `O` in Source | Out is the last frame that is included: the marked frame belongs to the clip. [W] | stores `position + frameDuration` (exclusive end), `Go to Out` shows `o - fd` (A:SourceMonitor.swift:238, 170) | same | - |
| `O` in Program | Same rule: the frame under the playhead is the last frame inside the range. | `markOut` stores `end = playhead` (exclusive), so the playhead frame is NOT included; `goToOut` seeks to `io.end`, one frame past the range (P:EditorSession.swift:575-581, 398). Source and Program use opposite conventions | differs | S: Program Out stores `playhead + fd`, Go to Out seeks `end - fd`. Migrate nothing (existing marks stay valid, only new ones shift) |
| `O` at frame 0 in Program | Allowed: a one-frame range 0..1 frame. | `markOut` returns when `playhead == .zero` (P:EditorSession.swift:576) | differs | S: allow once Out convention above is `+fd` |
| `I` after an existing Out that is earlier, Program | Out is cleared (same as Source). (unverified for sequences) | In is set and Out jumps to sequence end (P:EditorSession.swift:568-573) | differs (unverified) | S |
| `X` Mark Clip, Source focused | Marks the whole loaded clip: In = start, Out = end. (unverified) | `handle` has no `.markClip`, so the command falls through and marks the SEQUENCE clip under the Program playhead (A:SourceMonitor.swift:254-281, A:AppController+Commands.swift:32,58) | differs | S |
| `X` Mark Clip, Program/Timeline | In/Out around the clip under the playhead on the highest targeted track. | targeted tracks else all, union of clips (`markClipRange`, P:SSCore/Timeline+ThreePoint.swift:116) | same | - |
| `Opt+I` / `Opt+O` / `Opt+X` | Clear In / Clear Out / Clear both. | bound globally, source and sequence variants exist (P:CommandMap.swift:61-62) | same | - |
| Clear In in Program | In goes away, Out stays; the range then runs from sequence start. | `clearIn` sets In to 0 and keeps Out (P:EditorSession+SourceEdit.swift:68-72) | same | - |
| `Shift+I` / `Shift+O` | Go to In / Out of the focused monitor. | yes, both monitors | same | - |
| Source marks and Undo | Source marks are clip metadata, not part of sequence undo. (unverified) | `setSourceMarks` amends all history states, so Undo never reverts them (P:EditorSession.swift:682-688) | same | - |
| In/Out duration readout | Duration of the range is shown next to the monitor timecode. | footer label "In/Out hh:mm:ss:ff" (P:MonitorPanelView.swift:205) | same | - |
| Drag the In/Out handle on the scrub strip | Dragging either end of the range in the strip moves that mark. (unverified) | strip only scrubs the playhead (P:MonitorScrubBar.swift:484-495) | missing | M |
| `M` in Source | Adds a clip marker to the loaded clip at the Source playhead. | status "Markers on source clips are not available yet." (A:SourceMonitor.swift:69,277) | missing | M (needs `Project.sourceMarkers` in SSCore) |

## 2. Transport and JKL

| User action | Premiere | Today | Verdict | Fix |
|---|---|---|---|---|
| `Space` | Play / stop. | `playPause` both monitors; Program restarts at 0 from the end (P:EditorSession.swift:333-337,355) | same | - |
| `L` repeated | 1x, 2x, 4x, 8x: each press doubles. [W] (ProVideo Coalition, community threads) | 1, 2, 4, 8, capped at 8 (P:SSCore/Playback.swift:64-79) | same | - |
| `J` repeated | Reverse, same doubling. [W] | mirrors L | same | - |
| Opposite key while playing fast | Does NOT restart at 1x: while playing forward faster than 1x, `J` takes one step down the ladder (4x to 2x to 1x); only at 1x does `J` reverse. [W] | opposite key always restarts at 1x in the new direction (`if !same { setRate(dir) }`, P:SSCore/Playback.swift:73-74) | differs | S: opposite key halves the speed; at 1x it reverses at 1x. Test: L,L,L (4x) then J gives 2x, J gives 1x, J gives -1x |
| `K` | Stop. | stops | same | - |
| `K+L` / `K+J` held | Slow play (about 1/4 speed, unverified), a tap steps one frame. | tap = one frame, hold past 0.25 s = 1/4 speed, release stops (P:KeyRouter.swift:15, P:SSCore/Playback.swift:97-101) | same (threshold unverified) | - |
| `Shift+L` / `Shift+J` | "Shuttle Slow": from a stop it starts slow and each press nudges the speed; Adobe calls the commands Shuttle Slow Right/Left. [W] Reports disagree whether the first speed is 1 fps or about 1.25x. | from stop 1.25x, then +/-1/4 per press up to 8x (P:SSCore/PlaybackNudge.swift:7-14) | differs? (unverified) | S once measured in the real app: change the start speed |
| Frame step `Left/Right`, 5 frames `Shift+Left/Right` | 1 frame, 5 frames (Preferences: large step). | yes, repeatable | same | M if the 5 should be a preference (S) |
| `Home` / `End` | Start / end. | Source `goToEnd` parks on the last frame, Program on `duration` (A:SourceMonitor.swift:167, P:EditorSession.swift:377) | differs in the Program case (unverified) | S: park Program on the last frame, like Source |
| `Up` / `Down` | Previous / next edit point (timeline focus). | Program and Timeline scopes only (P:CommandMap.swift:122) | same | - |
| Shift+Space ("Play In to Out with preroll/postroll" per Adobe's shortcut list) / Ctrl+Shift+Space (plain Play In to Out) | Shift+Space plays a few seconds before the In point to a few seconds after the Out; preroll default 3 s, postroll 2 s, set in Preferences > Playback. [W] Plain Play In to Out has its own key. | Shift+Space is mapped to plain Play In to Out, no preroll, and no key for the plain variant (P:CommandMap.swift:63, P:EditorSession+SourceEdit.swift:53-61) | differs | S for the key swap, M for preroll/postroll plus the two Preferences fields |
| `Shift+K` Play Around | Plays a few seconds before the playhead to a few seconds after, then returns to the start point. [W] | missing | missing | M (reuses preroll/postroll; return playhead on stop) |
| Playback stop returns playhead? | Play Around / Play In-Out variants return to where they began when they end. (unverified) | stays at Out | differs (unverified) | S, with the preroll item |
| Loop | Loop toggle in the transport (wrench) menu. | `Ctrl+L` (key unverified) and wrench menu (P:MonitorPanelView.swift:255-262) | same | - |
| Playback stops at the sequence end | Parks on the last frame. | `atEnd` parks at `end` (P:EditorSession.swift:303-332) | differs (unverified) | S |

## 3. Insert / Overwrite and 3/4-point edits

| User action | Premiere | Today | Verdict | Fix |
|---|---|---|---|---|
| `,` / `.` with Source In+Out, no sequence marks | Source range goes at the playhead on the patched tracks. [W] | `sourceEdit` (P:EditorSession+SourceEdit.swift:9-48) | same | - |
| Same with sequence In set | Placed at sequence In (3-point). [W] | `sourceEditPosition` = `inOut?.start ?? playhead` (P:SSCore/Timeline+SourceEdit.swift:22) | same | - |
| Only a sequence Out is set (no In) | 3-point edit back-timed: the clip ends at Out, the start is Out minus source duration. [W: "any three of the four points"] | `markOut` sets `inOut = (0, out)` so `sourceEditPosition` returns 0 and the clip is placed at the sequence start, ignoring Out (P:EditorSession.swift:575-581) | differs | M: keep In/Out as optional ends in SSCore (`Timeline.markIn/markOut: Time?`) or add an `isInExplicit` flag; then back-time |
| Sequence In and Out both set, source In/Out set (4-point) | If durations differ, a Fit Clip dialog offers: Change Clip Speed (Fit to Fill), Ignore Source In, Ignore Source Out, Ignore Sequence In, Ignore Sequence Out. [W] No dialog when the lengths match. The dialog has a "do not ask again" mode and can be re-enabled in Preferences > Timeline. [W] | sequence Out ignored; source length decides (P:SSCore/Timeline+SourceEdit.swift:20-22) | missing | L: `FourPointPlan` in SSCore (pure), sheet in the shell, Fit to Fill via `Timeline+Speed` |
| Source has In only | Out defaults to the clip end. | `sourceEditRange` (P:SSCore/Timeline+SourceEdit.swift:14-17) | same | - |
| Source has Out only | In defaults to the clip start. | same function | same | - |
| Insert pushes later clips | Targeted AND sync-locked tracks ripple; a clip under the point is split. | `threePointEdit` / `insert` honour sync lock (P:SSCore/Timeline+ThreePoint.swift:47-71) | same | - |
| No tracks targeted | Edit goes nowhere / warns. (unverified) | falls back to V1 + mirrored audio (P:SSCore/Timeline+SourceEdit.swift:27-40) | differs, friendlier | keep (record in DECISIONS) |
| Playhead after the edit | Moves to the end of the new clip. | `seek(to: endTime)` | same | - |
| Source patching (patch buttons V1/A1 in the track header, separate from target) | Source patch decides where the source tracks land; target decides what the edit buttons/keys act on. | one flag, `isTargeted`, does both (P:SSCore/Timeline+SourceEdit.swift:27-40) | missing | L (SSCore patch state per track, UI in track headers: timeline stream) |
| Insert/Overwrite when the loaded clip is a still | Uses the still's default duration (preference). (unverified) | fixed 5 s (P:EditorSession+SourceEdit.swift:13) | differs | S: read a `defaultStillDuration` from AppSettings |
| Drag picture into timeline | Drops both streams; Drag Video Only / Drag Audio Only icons drop one. | `StreamDragView` (P:MonitorPanelView.swift:351-403) | same | - |
| Drag from Source onto the Program monitor | Overlay / Insert / Overwrite drop zones. (unverified; newer versions) | none | missing | L, low value |
| Replace Edit, Opt+drag onto a clip | Replaces keeping length. | `Timeline+Replace.swift` exists, no Source-monitor or drag entry | missing in this area | defer to the timeline spec |
| Edit with several selected Project items | `,` `.` from a multi-selection of bin items places them in sequence order. (unverified) | `placeMedia(ids...)` does (P:EditorSession.swift:467) | same | - |
| Format mismatch: first clip into an empty sequence | Prompt "change sequence settings to match". | silently adopts the clip format when the sequence is empty and unlocked (P:EditorSession+SourceEdit.swift:18-28) | differs, friendlier | keep |

## 4. Source monitor behaviour

| User action | Premiere | Today | Verdict | Fix |
|---|---|---|---|---|
| Double-click a Project clip | Loads it in the Source monitor. | `doubleClicked` opens (P:ProjectPanelView.swift:487-494) | same | - |
| Drag a clip onto the Source monitor | Loads it. [W] | no drop target on the monitor | missing | S |
| Select several clips and open/drag them | They all load; the Source tab/dropdown lists them, one shows at a time. [W] | single clip only (A:SourceMonitor.swift:91) | missing | M: `SourceMonitorController.recent: [MediaRef.ID]` (max 20), a title popup in the panel header |
| Source title dropdown | Lists clips loaded earlier in the session, with Close / Close All. [W] | none | missing | M, same item as above |
| Load a sequence into Source | Allowed (nested view). (unverified) | not allowed | missing | defer |
| Audio-only clip in Source | Shows a waveform instead of a picture. | black picture (docs/audit/monitors.md:24) | missing | M (reuse `Waveform`/`WaveformDrawing`) |
| Clip's source timecode | The display can show the file's embedded start timecode. (unverified) | counts from 00:00:00:00 | differs (unverified) | M, needs SSMedia to read tmcd |
| Source playhead at open | Starts at the first frame (or last position when reopened). (unverified) | starts at `time ?? .zero` (A:SourceMonitor.swift:110) | same | - |
| Space etc. while Source not focused | Keys go to the focused panel. | `focusedPanel == .sourceMonitor` routing (A:AppController+Commands.swift:32) | same | - |
| Playing Source stops Program and vice versa | Yes (one at a time). | `onStartedPlaying` | same | - |
| Match Frame `F` | Loads the clip under the playhead into Source at the same frame, keeping its marks. | `matchFrame` selected, then targeted, then topmost (docs/audit/monitors.md:21) | same | - |
| Reverse Match Frame `Shift+R` | Moves the sequence playhead to the frame that Source shows, inside the used clip. | exists | same | - |
| Source button bar | Marker, In, Out, Go to In, Step back, Play, Step forward, Go to Out, Insert, Overwrite, Export Frame. | same order (P:MonitorPanelModel.swift:36-39) | same | - |
| Button editor (`+`) | Choose which buttons show; adds Lift, Extract, Toggle Zoom ... | none | missing | M, low value |
| Scrub strip | Whole clip length, In/Out range shaded, playhead. | height 14 pt, whole length (P:MonitorPanelView.swift:181, P:MonitorScrubBar.swift) | same | - |
| Zoom menu | Fit, 10, 25, 50, 75, 100, 150, 200, 400 %. (unverified) | Fit, 25, 50, 75, 100, 150, 200, 400 (P:MonitorPanelModel.swift:23-24) | differs (10 % missing, unverified) | S |
| Playback resolution | Full, 1/2, 1/4, 1/8, 1/16. | Full, 1/2, 1/4 (P:MonitorPanelModel.swift:10-16) | differs | S (SSMedia `DecodeScale` has to support 1/8) |
| Timecode: click to type | Digits, Enter jumps; `+10` relative. | `commitTimecodeText` parses a timecode only (P:MonitorPanelModel.swift:107) | same / relative form unverified | S: accept `+n`, `-n` |
| Timecode drag | Drag horizontally to scrub. | 2 pt per frame after a 3 pt dead zone (P:MonitorPanelView.swift:319) | same | - |

## 5. Program monitor

| User action | Premiere | Today | Verdict | Fix |
|---|---|---|---|---|
| Lift `;` | Removes the In-Out range on TARGETED tracks only; leaves a gap. If no track is targeted nothing happens. (unverified for the empty case) | targeted tracks, else ALL unlocked tracks (P:EditorSession.swift:442-453) | differs | S: decide and record. YouTube editors usually have V1/A1 targeted, so keep ours but log it in DECISIONS.md |
| Extract `'` | Same range, closes the gap on targeted and sync-locked tracks. | same helper; sync lock honoured by `extract` | same | - |
| Lift/Extract with no In/Out | Nothing / beep. | returns silently (P:EditorSession.swift:448-457) | same | S: flash a status message |
| Export Frame `Shift+E` | Saves a still of the current frame (dialog: name, format, "import into project"). | PNG/JPEG via a save panel; Cmd+Shift+E also bound (P:CommandMap.swift:64) | same (no "import into project") | S |
| Right-click menu | Mark In/Out, Go to, Clear, Add Marker, Lift/Extract, Match Frame, zoom, safe margins ... | built (A:EditorPanels.swift:395-430) | same | - |
| Safe margins | Toggle, action 90 % and title 80 % (percentages are Project Settings, unverified). | 90 / 80 fixed (P:MonitorPanelView.swift:335) | same | - |
| Double-click picture | Toggles direct-manipulation (motion). | other stream | - | - |
| Scroll / pinch | Zoom/pan when zoomed. (unverified) | pinch zoom and scroll pan exist | same | - |
| Playback resolution hint "paused resolution" | Separate paused vs playing resolution. | one setting | missing | S |
| Overlays (timecode, clip name) | Optional overlays. | none | missing | S, low value |
| Dropped-frame indicator | Yellow/red dot in the monitor on drops. (unverified) | `Stats.swift` collects, no indicator | missing | S: show a dot, valuable for the "feel" |

## 6. Project panel

| User action | Premiere | Today | Verdict | Fix |
|---|---|---|---|---|
| Double-click media / sequence / bin | Source monitor / Timeline / opens bin (in place by default). | list: media, sequence open, bin expands; icon view: `onOpen` (P:ProjectPanelView.swift:487-494, P:ProjectIconView.swift:231) | same | - |
| `Return` | Starts rename of the selected item. | yes (P:ProjectPanelView.swift:73-76) | same | - |
| `Delete` on used clip | Warns that the clip is in a sequence; offers to delete the usage too. (unverified) | silently keeps it and beeps (P:ProjectPanelModel.swift:164-166) | differs | S: status message "used in <Sequence>" |
| Delete a sequence | Allowed. | `case .sequence: continue` (P:ProjectPanelModel.swift:169) | missing | S (SSCore `Project.deleteSequence`, never the last one) |
| `Cmd+B` | New bin. | `newBin` | same | - |
| Hover scrub | Moving over a thumbnail scrubs it without a click; `I` / `O` while hovering set the clip's In/Out; `Shift+H` toggles the feature. [W] | pointer x over the thumbnail picks a frame (`HoverScrub.time`, P:ProjectThumbnails.swift:8-17, P:ProjectIconView.swift:299-323). No `I`/`O`, no toggle, no list-view hover | partly same | S: `I`/`O` while `hovered != nil` write `Project.sourceMarks`; S: toggle with a Project panel menu item and `Shift+H` |
| Poster frame | `Cmd+P` sets the thumbnail frame. [W] | poster is fixed at 10 % or max 2 s (P:ProjectThumbnails.swift:20-22) | missing | S |
| Thumbnail size | Slider. | 70-220 pt (P:ProjectPanelView.swift:203) | same | - |
| List columns, sort | Chosen from the panel menu, header click sorts. | header menu, sort (P:ProjectPanelView.swift:432-440) | same | - |
| Freeform view | Free layout. | none | missing | skip (low value) |
| Search `Cmd+F` | Find dialog with criteria. | filter field only | partly missing | M, later |
| New Sequence From Clip | Context menu / drag onto New Item. | context menu (P:ProjectPanelView.swift:757) | same | - |
| Context menu: Make Subclip, Duplicate, Proxy ... | Many entries. | entries we can run only | differs, intended | Make Subclip: M (needs `SubClip` in SSCore) |
| Offline media | Red marker; Link Media. | yes | same | - |
| Drag from Project to Source monitor | Loads. | missing (see 4) | missing | S |
| Space-to-play inside the Project preview | Plays the selected clip. (unverified) | none | missing | skip |

## 7. Ranked backlog (YouTube / TikTok editing first)

Each item is independent. "AC" = acceptance criteria that can be unit-tested; SSCore items belong in `Packages/SSCore/Tests`, session items in `SSEditorUITests`.

1. **JKL: opposite key decelerates.** `Shuttle.press(.j)` while `rate` is +4 returns +2, then +1, then -1 at 1x. S. AC: ladder test in `PlaybackTests`; K resets; slow mode unaffected.
2. **Source `X` marks the whole clip.** In Source focus `.markClip` sets In = 0, Out = duration (not the sequence). S. AC: `SourceMonitorController.handle(.markClip)` leaves `activeTimeline.inOut` untouched.
3. **Program Out convention.** Out stores `playhead + fd`; Go to Out shows `end - fd`; `O` allowed at frame 0. S. AC: mark In=10, Out=20 gives duration 11 frames; `goToOut` lands on frame 20.
4. **Sequence-Out-only edits are back-timed.** M. AC: `Timeline.sourceEditPlacement(sourceDuration:, inOut:, playhead:)` with only Out returns start `= out - duration`; with neither returns the playhead.
5. **Four-point edit with Fit Clip.** L. AC: pure `FourPointPlan` returns `.fitToFill(speed)` / `.ignoreSourceIn` / ... ; speed = sourceDuration / sequenceDuration as a rational; equal durations skip the dialog.
6. **Hover scrub `I`/`O`.** S. AC: with a hovered item, `I` at the hovered time writes `sourceMarks`; one fewer undo step is created (marks are not undoable).
7. **Drop a Project clip onto the Source monitor.** S. AC: `SourceMonitorController.open` called with the dropped ID; multi-select loads the first and records the rest in history.
8. **Source clip history popup.** M. AC: `recent` keeps 20 unique IDs, most recent first, removes IDs deleted from the project; Close/Close All.
9. **Preroll/postroll preference + Play Around (`Shift+K`) + Play In/Out with preroll.** M. AC: `PlaybackBounds.range` extended by 3 s / 2 s defaults, clamped to 0..duration; playhead returns to start on stop.
10. **Shift+Space / Ctrl+Shift+Space key swap.** S (after 9). AC: `CommandMap` has no duplicates, both bindings resolve.
11. **Delete used clip feedback.** S. AC: `ProjectPanelModel.delete` returns the blocking sequence names; the view shows them.
12. **Delete sequences from the Project panel.** S. AC: `Project.deleteSequence` refuses the last timeline and fixes `activeTimeline`; one undo step.
13. **Source markers (`M` in Source).** M. AC: markers saved per media in `ProjectFile`, round trip test, shown on the strip.
14. **Drag In/Out handles on the monitor strip.** M. AC: `MonitorScrubMath.hit(x:)` returns `.markIn/.markOut/.playhead` with 6 pt slop; dragging In past Out clears Out.
15. **Timecode field relative entry (`+10`, `-5`).** S. AC: `Timecode.parse("+10")` returns an offset; `commitTimecodeText` seeks `current + 10 frames`.
16. **Home/End park on the last frame in Program.** S (unverified in Premiere). AC: `goToEnd` seeks `duration - fd`.
17. **Playback resolution 1/8 and zoom 10 %.** S. AC: `MonitorQuality.allCases` has `.eighth`; zoom presets include `.percent(10)`.
18. **Poster frame (`Cmd+P`) and Shift+H hover toggle.** S each. AC: poster time stored in `MediaRef`, round trips; toggle persisted in AppSettings.
19. **Audio-only clip waveform in Source.** M. AC: view model returns waveform peaks for an audio-only `MediaRef`; no picture surface is requested.
20. **Dropped-frame indicator on Program/Source.** S. AC: `MonitorPanelModel.droppedFrames` increments from `Stats`, resets on seek.
21. **Source patch state separate from target.** L. AC: `Track.isSourcePatched` per kind, `sourceEditTargets` uses patch first; migration defaults to `isTargeted`.
22. **Lift/Extract with no range flash a message; record the "all tracks" fallback in DECISIONS.md.** S.
23. **Fixed "still" duration from Preferences.** S. AC: `sourceEdit` of a still uses `AppSettings.stillDuration`.
24. **Make Subclip.** M. AC: creates a `MediaRef` slice sharing the file with its own marks; renders and relinks as the parent.
25. **Find (`Cmd+F`) with criteria.** M. AC: `ProjectPanelModel.find(Criteria)` selects matches, supports name, label, offline.
26. **Button editor for the monitors.** M. AC: layout stored in AppSettings, the default equals `MonitorAction.buttonBar`.
27. **Export Frame: "import into project" checkbox.** S.
28. **Source timecode display (embedded start TC).** M. AC: `MediaInfo.startTimecode` read in SSMedia, shown when the setting is on.

## 8. Open questions for the Mac session

1. Measure the first speed of `Shift+L` from a stop and the preroll default in a real Premiere 2025/2026.
2. Does the Premiere sequence Out point include its own frame? (Source Out does [W]; the sequence side matches in my memory but is unverified.)
3. Does Lift/Extract do nothing when no track is targeted?
4. Is `Ctrl+L` Loop right on macOS?
5. Run `scripts/fetch_adobe_guide.py` locally and diff this file against the pages named at the top.
