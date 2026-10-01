# Review: SQEditorUI (Job B)

Read-only review (Linux, nothing built or run). Every source file under `Packages/SQEditorUI/Sources/SQEditorUI` was read in full by five reviewers (session/core, timeline, effects/keyframes, color/text/captions/monitors, project/library). Paths are relative to that directory. Line numbers are as of `main` at review time. Findings are provable from the code; none has a failing test yet (UI package, not buildable on Linux).

**Status pass (round 2, against current main):** see the Status line under each finding. Tests: Packages/SQEditorUI/Tests/SQEditorUITests/ReviewRound2Tests.swift plus tests added to existing suites.

Overall: edit paths (`perform`/`attempt`/`commit`, gestures, speed, colour, gain, captions) give one undo step per action; time math is rational; no overlap or linked A/V bugs found in move/trim/roll. Issues are concentrated in media placement, waveform memory, retimed-clip volume keys, session lifecycle and input parsing.

## High

1. **WaveformCache has no byte budget; resamples whole file on main thread.** `WaveformDrawing.swift:214-227`, called from `:69-70`, `ClipDrawing.swift:159`, `TimelineView.draw`.

   **Status: FIXED (306b7e3): cache has a 64 MB byte budget; above 500 columns/s the draw reads the visible range directly. The first resample per zoom bucket (below 500 columns/s) still runs on the main thread.**
   At the 400 pt/frame zoom cap a 10-min stereo file needs ~7M columns (~110 MB per entry); a 2 h file ~1.3 GB per channel. Cache limits entry count (24), not bytes, and the first draw per zoom bucket resamples inside `draw(_:)` (main-thread stall, also on playhead redraws).
   Fix: resample only the visible range or fall back to `data.peaks(in:buckets:)` above ~2k columns/s; add a byte budget (e.g. 64 MB); build off the main thread.

## Medium

2. **`placeMedia` puts clips off the frame grid.** `Session/EditorSession.swift:486-503` (lines 493-494, 502). Uses raw source duration/mark range; only the first `at` is snapped and `Timeline.threePointEdit` doesn't snap. A 23.976 fps clip in a 29.97 fps sequence gives off-grid ends and following items; later edits/seeks assume frame alignment (sub-frame gaps/overlaps, A/V cuts off-frame). `sourceEdit` handles this at `Session/EditorSession+SourceEdit.swift:34-40`.

   **Status: FIXED (031ac29): placeMedia uses the same frame-grid plan as sourceEdit; stills keep their default length.**
   Fix: same logic as `sourceEdit` in the loop: `d = source.duration.snapped(to: frameDuration)`, min 1 frame, clamp to media end, `at += d`, snap `at` each iteration.

3. **Volume rubber band uses `source.duration` for clip-local time; keys are timeline-local.** `VolumeLine.swift:59,73-77,84-88,94`; same clamp in SQCore `AudioGain.swift:88-91` (`moveVolumeKey`). Keys are relative to `start` in timeline seconds, clip width is `clip.duration = source.duration/speed`. At 50% speed, points/diamonds are drawn at the wrong x, `hit()` (correct) disagrees with drawing, clicks in the second half clamp to the wrong time, keys can't be dragged into the second half; at 200% keys can be placed past the clip end.

   **Status: LEFT FOR AUDIO STREAM (volume rubber band, TimelineView+VolumeLine / SQCore AudioGain moveVolumeKey). Not checked on current main.**
   Fix: use `clip.duration` in all four places and in the `moveVolumeKey` clamp.

4. **`onRejection` never fires for gesture rejections.** `TimelineView.swift:465-468`, `TimelineInteraction.swift:445-455`. `publish` sets `isRejected` but never `rejectionMessage` (only `reject()`, used by Nest). Status message documented at `TimelineView.swift:47-48` never appears for drag/trim/razor. `wasRejected` is also read before `mouseUp`'s final `mouseDragged`, and the `defer` clears state.

   **Status: FIXED (0b5bd37): publish sets rejectionMessage; mouseUp exposes releasedRejection after the final drag.**
   Fix: set `rejectionMessage = Self.message(for: error)` in `publish`'s catch; capture rejection state after `mouseUp` work, before the `defer`.

5. **Scopes read the engine's reused render target from another command queue.** `ColorPanels.swift:236-241`, `ScopesView.swift:189-197`. `RenderLoop.target()` (`SQPlayback/RenderLoop.swift:587-596`) reuses one texture; scopes (own `MTLCommandQueue`, refresh ~60 ms) can read a half-written frame during playback (flicker/tearing). The repo's own comment at `RenderLoop.swift:111-113` says readbacks belong on the engine's command buffer.

   **Status: FIXED (33f1c92): scopes take a private copy blitted on the engine's command buffer (requestFrameCapture). Not run on a GPU here.**
   Fix: use the `requestFrameCapture` path (as eyedropper/Auto), blit into a scope-owned texture, then `ScopesGPU.encode` on that.

6. **Text inspector colour-well undo session never closes / swallows edits.** `TextInspectorView.swift:268-278`, `TextInspectorModel.swift:52-61`. `colorEdit` closes its session from a `Task` after 500 ms with `[weak self]`; if the view is gone `endEditing()` never runs and `sessionDepth` stays 1 (later edits merge into a stale step; `onEndEditing` never fires). Any edit within 500 ms (Bold, size, selection change then `load`) is merged into the colour step, possibly onto a different clip.

   **Status: FIXED (e59bebe): load(style:) closes an open session; the view ends it in deinit.**
   Fix: end the session in `deinit` and in `model.load`, or close on colour-panel/well deactivation instead of a timer.

7. **Overwrite-confirmation sheet presented repeatedly.** `CaptionsPanelView.swift:147,188-200`. `refresh()` calls `confirmOverwrite()` on every observed change while `needsOverwriteConfirmation` is true, queuing duplicate `beginSheetModal` sheets.

   **Status: FIXED (c792095): one overwrite sheet at a time.**
   Fix: `confirmPending` flag, reset in the completion.

8. **Unchecking Uniform Scale doesn't rebuild the Scale row.** `EffectControlsView.swift:112-123`, `EffectControlsPremiere.swift:52-65`. `observe()` never reads `model.uniformScale`; with Width == Height `setUniformScale(false)` returns early without `commit`, so nothing tracked changes and the row stays single-field until an unrelated change.

   **Status: FIXED (46acc72): observe() reads uniformScale.**
   Fix: `_ = model.uniformScale` (and `model.frameDuration`) in the tracking closure.

9. **Opening/creating/recovering a project doesn't stop playback or reset session state.** `Session/EditorSession.swift:647-663` (`replace(with:)`). Seeks to zero but never pauses; `isPlaying`, `bounds` (In/Out, loop) and `clipboard` (pasted clips reference unknown media IDs) survive.

   **Status: FIXED (e81cefb): open/new stops playback, resets bounds and clipboard.**
   Fix: `engine.pause()`, `isPlaying = false`, `bounds = PlaybackBounds()`, `clipboard = nil`.

10. **Icon view shows `currentBin`, not `browseBin`.** `ProjectIconView.swift:137`, `ProjectPanelView.swift:687,711-716`. After picking a sub-bin in list mode and switching to icons, the grid shows the sub-bin but label/up button use `browseBin` (root): up is disabled, user can't navigate out.

   **Status: FIXED (9542e1b): switching to icons sets currentBin = browseBin.**
    Fix: `reload()` and `targetBin(for:)` (`:345`) use `browseBin`, or set `currentBin = browseBin` in `viewModeChanged`.

11. **Every finished thumbnail rebuilds the Library grid.** `LibraryPanelView.swift:262-303` (read at `:273`, disk read at `:409-413`). Each completion calls `collection.reloadData()`/`table.reloadData()`, dropping selection, and every visible cell re-reads `NSImage(contentsOf:)` uncached on the main thread: O(N²) main-thread I/O.

   **Status: FIXED (1455779): selection kept across refresh; thumbnail files cached in an NSCache. Per-item reload not done.**
    Fix: bounded `NSCache` keyed by URL; reload only the changed item; preserve selection.

12. **Still-image decode on the main thread.** `ProjectThumbnails.swift:55-60`. `requestPoster`'s `Task` inherits `@MainActor`, so nonisolated `stillThumbnail` (`CGImageSource…`) runs on main; 400 photos hitch the UI.

   **Status: FIXED (09a4438): still thumbnail decode is @concurrent. No test (thread not observable).**
    Fix: `await Task.detached { … }.value` or `@concurrent`.

13. **Export frame-rate picker never matches NTSC rates.** `Export/ExportDialogModel.swift:98-102` (getter), `:28`, `ExportDialogView.swift:112-114`. Getter returns `Double(timescale)/Double(value)` = 29.97002997…, not tag `29.97`; Picker shows blank/invalid for 23.976/29.97/59.94 incl. default `.matchSource`.

   **Status: FIXED (a1d0b16): fps getter returns the picker tag for NTSC rates.**
    Fix: return nearest `frameRates` entry (tol ~0.01) or bind the Picker to `Time` tags.

## Low (crashes on input)

14. **Timecode parse overflow.** `Timecode.swift:56,66-76`: hours field unbounded; `9999999999999:00:00:00` in the Speed/Duration dialog overflows `fps * (3600*h+…)` / `frameDuration * frames` (`Time.*` unchecked, `SQCore Time.swift:65`) and traps. Fix: cap `h` (e.g. 999) or use `multipliedReportingOverflow`.

   **Status: FIXED (dceee5e): hours capped at 9999.**
15. **Markers timecode parse overflow.** `MarkersPanelModel.swift:105-111`: same overflow typing a huge value into In/Duration. Same fix.

   **Status: FIXED (dceee5e, 4b9b1d4): parts capped; marker parsing now goes through the shared Timecode.**
16. **Create Captions "Minimum duration" trap.** `CaptionsTabView.swift:399-401`: `Int64((secs*1000).rounded())` traps on `1e30`/`inf`. Fix: require finite and clamp (e.g. ≤3600).

   **Status: FIXED (dceee5e): CaptionsPanelModel.minDuration(seconds:) clamps to 0...3600; gap clamped to 3600 frames.**
17. **NaN pixel trap.** `Color/ColorPickHub.swift:164` (`FrameSampler.display8`), `Color/ColorControls.swift:442-444`: `UInt8(min(max(v,0),1)*255+0.5)` traps on NaN (half-NaN pixels, LUT output). Fix: map NaN to 0 first.

   **Status: FIXED (dceee5e): FrameSampler.byte maps NaN to 0.**
18. **Zero-value frame duration divides by zero.** `ProjectPanelModel.swift:228,274,294`, `ProjectPanelColumns.swift:23`, `ProjectThumbnails.swift:14-16` (`HoverScrub.time`): `Time` only enforces `timescale > 0`; a probe returning `nominalFrameDuration` value 0 traps in `frameIndex`/`snapped`/`floorDiv`. Fix: treat `fd.value <= 0` as no video.

   **Status: FIXED (dceee5e): durationString, timecode and HoverScrub ignore a zero frame duration.**

## Low (state, undo, consistency)

19. **Markers panel commits on every end-of-editing.** `MarkersPanelView.swift:109-115`: Esc/click-away with no change still commits (possible no-op undo step); In/Duration display is frame-floored so merely entering/leaving a non-frame-aligned marker silently moves it. Fix: skip if string unchanged or `NSCancelTextMovement`.

   **Status: FIXED (4b9b1d4): unchanged text commits no edit.**
20. **Marker timecode is non-drop, monitor is drop-frame.** `MarkersPanelModel.swift:87-112` vs `MonitorPanelModel.timecode`, `TextPanelView.swift:89-90`: at 29.97/59.94 the same time shows differently (~3.6 s/h drift) and typed timecodes seek differently. Fix: reuse `SQCore.Timecode` with the drop-frame flag.

   **Status: FIXED (4b9b1d4): marker timecode uses Timecode with drop-frame at 29.97/59.94.**
21. **Double used for time/frame math.** `CaptionsPanelModel.swift:241-244` (`gapFrames`), `CaptionsTabView.swift:374-376` (`fill()`): Double division + 0.5. `MonitorScrubBar.swift:21-24`: quantises to 1e-5 of duration (single frames unaddressable past ~100k frames; below pixel resolution in practice). Fix: rational math / `frameIndex(frameDuration:)`.

   **Status: NOT REPRODUCED: the Double math rounds to the same frame for every real frame rate; the scrub-bar quantisation (1e-5 of the duration) is far below one pixel. No change.**
22. **Double-click gives two undo steps.** `Color/ColorCurveEditor.swift:147-160` (add then remove point), `Color/ColorControls.swift:94-103` (jump then reset): two undos to return. Fix: coalesce with previous step on `clickCount == 2` or defer the action to mouse-up.

   **Status: VERIFIED, NOT FIXED: needs an undo-coalescing API across view and model (a behaviour decision). Left open.**
23. **Audio Gain dialog never shows peak for a single clip.** `AudioGainDialog.swift:77-78`: `?:` binds looser than `+`, so the peak suffix attaches only to the multi-clip branch. Fix: parenthesise the ternary.

   **Status: LEFT FOR AUDIO STREAM (AudioGainDialog).**
24. **Speed dialog reports a change when value is unchanged.** `SpeedDialogModel.swift:70,86-88`: `edited` is always set, so OK with 100 on a 100% clip applies a no-op `SpeedChange` (possible empty undo step). Fix: compare against originals.

   **Status: FIXED (6b2e00f): typing the current speed or duration sets no change.**
25. **`zoomToFit` bypasses zoom limits.** `TimelineView.swift:323`: `.fit` skips `TimelineZoom.clamp`; a 1-frame sequence gives ~800 pt/frame (> 400 cap). Fix: clamp.

   **Status: FIXED (a1d0b16): zoomToFit clamps to the limits.**
26. **Waveform build after `invalidate` stores stale peaks; never retried/evicted.** `TimelineWaveforms.swift:37-48,53-55`: in-flight task isn't cancelled, writes old peaks after relink; `failed` permanent; `data` never evicted. Fix: per-id generation/task handle; clear `failed` on relink.

   **Status: FIXED (8eaca9f): generation counter per media discards stale builds. Not done: retry of failed builds without relink, eviction of data.**
27. **`ClipSectionsView` stale state.** `ClipSectionsView.swift:222-224,248-249,251-263`: `loadText` decode failure leaves `textClipID`/`textTemplate` on the previous clip while the editor is visible (typing edits the previous clip); `loadAudio` miss keeps old `audioTrackID`; `audioHosts/Models/Presets` never pruned (leaks NSViews, stale presets reappear with reused IDs). Fix: clear on failure; prune in `sync`.

   **Status: FIXED (9c88bd4): failed loads clear the ids, deleted tracks pruned.**
28. **Switching active sequence leaves playback running.** `Session/EditorSession.swift:189-196` (`setActiveTimeline`; via `addSequence` `:536`, `newSequence(fromMedia:)` `+SourceEdit.swift:91`): no pause, playhead not clamped/reset. Fix: `stopPlayback()` and seek/clamp.

   **Status: ALREADY FIXED on main (stopForSequenceChange and clampPlayheadToActiveSequence in setActiveTimeline).**
29. **Replace Footage doesn't re-prepare media.** `Session/EditorSession+SourceEdit.swift:96-98`, `EditorSession.swift:236-240,247`: unlike `relinkMedia`, doesn't `requestedMedia.remove(id)`, so the new file opens lazily on first decode (hitch). Fix: remove id.

   **Status: FIXED (996eb52): replaceFootage removes the id from requestedMedia. No test (needs a real file open).**
30. **Undo rewind/squash silently no-op at history limit.** `Session/EditorSession+Generators.swift:44-53`, `EditorSession.swift:198-205`, `SQCore History.swift:43,63,72`: with a full 200-entry stack, adding trims the oldest so `count > depth` is false; Type tool leaves "Delete Empty Text" as a second step and `foldUndo` leaves two steps. Fix: monotonic step counter/depth token adjusted on trim.

   **Status: ALREADY FIXED on main (History keeps a `dropped` counter, undoDepth is monotonic).**
31. **`replaceCaptionText` returns 0 instead of nil when refused.** `Session/EditorSession+Captions.swift:69-74`: throwing `attempt` (locked track) leaves `n == 0` so `ok || n == 0` returns 0, contradicting the doc comment. Fix: `guard ok else { return nil }`, detect "ran, no matches" separately.

   **Status: FIXED (996eb52): returns nil when the edit threw.**
32. **Workspace store resets on any decode failure and ignores version.** `Session/WorkspaceStore.swift:59-62`: next save overwrites custom workspaces; `WorkspaceLibrary.decoded(from:)` version check not applied. Fix: back up unreadable file; apply version check.

   **Status: FIXED (d5af62b): unreadable or newer file copied to workspaces.json.corrupt before defaults.**
33. **Resolver: unbounded still cache.** `Session/ProjectMediaResolver.swift:37,214`: every still stays decoded (up to 8192 px, ~100 MB+) for the project lifetime. Fix: LRU/byte budget.

   **Status: FIXED (8a8cf15): 512 MB byte budget, oldest evicted first.**
34. **Resolver: LUT cache cleared on every media add.** `Session/ProjectMediaResolver.swift:89-91`: new keys compare against nil `refs` entry and count as a path change, invalidating colour pipelines. Fix: only when the key existed and its path changed.

   **Status: FIXED (996eb52): only a changed path of a known item clears the LUT cache. No test (cache not observable).**
35. **Failed poster never retried.** `ProjectThumbnails.swift:49,66-68`: `failed` only cleared by `forget(id)`; offline→online doesn't clear it. Fix: clear on state change or key by (id, mtime).

   **Status: FIXED (09a4438): failure cleared when the item shows offline again.**
36. **Poster cache keyed by id only.** `ProjectIconView.swift:172-181`, `ProjectThumbnails.swift:49`: enlarging the thumb slider stretches a small cached poster. Fix: key by (id, height bucket).

   **Status: FIXED (09a4438): a larger thumbnail size requests a sharper poster.**
37. **Duplicate media on overlapping imports.** `ProjectPanelModel.swift:181-204`: `known` snapshotted before the `await`; the same file dropped twice during a probe is added twice (`ProjectDrop.classify` same). Fix: re-filter against current `project.media` paths inside `commit`.

   **Status: FIXED (0d89691): commit re-filters against current media paths. ProjectDrop.classify not changed.**
38. **`visiblePresets` ascending comparator not a strict ordering.** `Library/LibraryPanelModel.swift:202-205`: `c != .orderedDescending` is true for equal names. Fix: `ascending ? c == .orderedAscending : c == .orderedDescending`.

   **Status: FIXED (a1d0b16): comparator made strict. No observable failure in a test (sort is stable in practice).**
39. **Favorites overwritten after failed load.** `Library/LibraryPanelModel.swift:79,222-225`: `try?` turns a decode error into empty favorites; next toggle saves over the unreadable file. Fix: distinguish missing vs. corrupt; back up before first save.

   **Status: PARTLY ALREADY FIXED on main (corrupt files are backed up in SQLibrary). FIXED (a1d0b16): a newer-version file is no longer overwritten.**
40. **Library `thumbnails`/`failedPreviews`/`previewTasks` not pruned on `removeFolder`.** `Library/LibraryPanelModel.swift:44-45,93-100,133-138`. Minor growth. Fix: prune and cancel tasks.

   **Status: FIXED (a92c04c): removeFolder prunes thumbnails, failures and preview tasks.**
41. **Scope redraw dropped while GPU busy.** `ScopesView.swift:201-203`: `redraw()` returns on failed `tryAcquire`; resize/kind change while a frame is in flight isn't retried (stale while paused). Fix: `needsRedraw` flag re-run from completion handler.

   **Status: FIXED (33f1c92): redraw runs after the frame in flight. Not run on a GPU here.**
42. **TextPanelView keeps stale `sourceURL`.** `TextPanelView.swift:124`: set only on model creation; relink/replace with reused clip id transcribes the old path. Fix: refresh in `sync`.

   **Status: FIXED (ee853cc): transcript model follows the clip's current file path.**

## Not reported (speculative, no trigger in this package)
`CompressorBandsView.bandRanges` traps if `crossoversHz` is unsorted; `mouseDragged` indexes out of range if `crossoversHz` shrinks mid-drag.

## Checked, no finding
Undo coalescing/gestures, `History` commit semantics, linked-group dedupe in nudge/trim/EdgeEdits, `updateMove/Trim/Roll/snappedDelta`, drop-frame timecode formulas, Workspace/Docking tree math, `KeyRouter`/`CommandMap`/`MenuSpec` (no duplicate bindings), `ProjectSaveQueue` actor, save dirty tracking, `AppSettings`/`DefaultsMigration`, ColorInspectorModel gestures, ColorWheel math, TransformOverlay geometry, meters, no Swift 6 violations found, look-preview (64) and RecentLUTs (8) caches bounded.
