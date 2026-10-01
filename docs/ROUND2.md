# Round-2 plan: six parallel streams

Basis: the four spec backlogs, feel/engine research, audits, FEEDBACK-5 and the SQCore review. Excluded: `transitions` (v17: cross dissolve, audio crossfades, Cmd+D, the transition model in `Transition*.swift`, plus Dip to Black/White, double-click transition and default-duration preferences) and the cloud SQCore review fixes. I did not re-check which backlog items are already built. Each agent's step 1 is a code-reading inventory, and an item that already exists becomes a test-only item.

Rules for all streams (OVERNIGHT.md):
- Own worktree, `git merge main` first and last.
- Tests first for SQCore logic.
- Rational time only; one undo step per user action.
- Run `scripts/test.sh <Package>`, then `xcodegen generate && scripts/build.sh`.
- Audit table in `docs/audit/<stream>-2.md`.
- Never push or merge into main.

Shared hot files (additive only, new functions in new files or extensions wherever possible): `App/Sources/AppController+Commands.swift`, `EditorPanels.swift`, `EditorSession*.swift`, `MenuBuilder.swift`, `MenuSpec.swift`, `CommandMap.swift`, `EditorCommand.swift`, `KeyRouter.swift`, `AppSettings.swift`, `SQCore/ProjectFile.swift`, `Model.swift`, `Timeline.swift`, `Clip` struct fields.

Project-file bump protocol:
- v17 is transitions.
- Each stream below owns exactly one version number.
- A stream adds only its own `case N-1 -> N` migration block and its own test, never anything else in `ProjectFile.swift`.
- `currentVersion` is set on merge to the highest number present.
- Merge order is by version number.
- New fields are optional with defaults, so old files decode unchanged.

## Stream 1: `timeline-edit` (project file v18)

Value: the everyday cutting verbs and handling speed. Covers FEEDBACK-5 #1 (zoom speed) and the feel research.

Items (timeline.md backlog number in brackets):
1. [1] Q/W Shift/Opt variants.
   - AC: A=[0,10), B=[10,20), playhead 7: Shift+W gives A=[0,7), B=[7,20); Opt+W gives A=[0,7) with a gap [7,10); plain W ripples B back 3.
   - One undo step each.
2. [2] Cmd+Opt drag = insert copy.
   - AC: the copy lands at the drop time, later clips ripple by its duration, the original stays.
3. [3] Zoom tool click, Opt-click and marquee.
   - AC: pure `zoomClick(scale:anchorX:zoomOut:)` keeps the time under the anchor fixed; marquee returns a fitting scale and scrollX.
4. Zoom feel pass (FEEDBACK-5 #1, [32][33]).
   - AC: constants in `TimelineZoom` changed so one key press goes fit to about 1 s in at most 2 presses and zooms out to fit in 1 (constants plus tests).
   - Measure real Premiere numbers on the Mac; ask Paul first if they cannot be measured.
5. [18] Enable/Disable clip (Shift+E), `Clip.isEnabled`.
   - AC: disabled clips are skipped by the render and the audio mix, decode as true from old files, and round-trip.
   - Needs the bump.
   - The audio side of this item is the same field; text-audio #28 is not a separate task.
6. [6] Duplicate (Shift+Cmd+/).
   - AC: copies land after the selection end on the same tracks, links kept, selection moves to the copies.
   - Must not collide with transitions' Cmd+D.
7. [5] Ctrl+T cycles the trim type of the selected edit.
8. [7] and [29] In/Out marks and keyframe times as snap targets.
   - AC: `snapPoints` includes them within the threshold.
9. Hold-S momentary snap invert during drags, and edge autoscroll while dragging a clip or playhead (feel.md #2, #3).
   - AC: the pure `autoscrollSpeed(distanceFromEdge:)` function is monotonic, zero in the interior, and capped.
10. [8] Opt+Up/Down moves selected clips one lane.
    - AC: locked tracks refuse and the outermost lane blocks.
11. [10][13] Target-toggle modifiers (Shift/Opt-click) and Shift-constrained drag axis lock.
12. [14] Marker drag in the ruler, clamped at 0 and snapping to clip edges (the marker duration UI is not now).

Owns: `Packages/SQCore/Sources/SQCore/Timeline+RangeEdits.swift`, `Timeline+Trim*.swift`, new `Timeline+Duplicate.swift` and `Timeline+Enable.swift`. In SQEditorUI: `TimelineInteraction.swift`, `TimelineZoom*.swift`, `TimelineGeometry.swift`, `TimelineCursorMap.swift`, `EdgeEdits.swift`, `PlayheadLogic.swift`, `TimelineView.swift`, `ToolState.swift`. App: `AppController+TimelineOps.swift`.

Additive only: `Timeline.swift`, `Model.swift` (adds `isEnabled`), `CommandMap`, `EditorCommand`, `AppController+Commands.swift`.

Must NOT touch: transition model and rendering, `SQRender` and `SQPlayback` internals (the disabled-clip skip is a one-line filter in the clip-resolution function only), the monitors, `Timeline+Captions`, speed code.

Verify against Adobe text: Q/W Shift/Opt semantics, Opt+Up/Down, Shift-constrained drag, Ctrl+T cycle order, and the zoom key behaviour. Grep `docs/reference/adobe/*.txt` for "ripple trim", "Opt+Q" and "zoom".

## Stream 2: `source-project-flow` (project file v19)

Value: getting footage in and marking it quickly. Covers the monitors.md backlog, FEEDBACK-5 #2-4, and Project-panel speed.

Items:
1. [1] JKL decelerate.
   - AC: `Shuttle.press(.j)` at +4 returns +2, then +1, then -1; K resets.
   - Also clamp 8x (review finding 4), which is in `Playback.swift`.
   - Coordinate: that file is the only SQCore-review overlap; this stream owns it.
2. [2] Source `X` marks the whole clip and leaves the sequence in/out untouched.
3. [3][4] Program Out convention and back-timed edits.
   - AC: In=10, Out=20 gives a duration of 11 frames.
   - A pure `Timeline.sourceEditPlacement` with only Out returns `out - duration`.
4. [7] Drop a Project clip onto the Source monitor, and [8] Source history popup of 20 unique IDs.
5. [6] Hover-scrub `I`/`O` writing `sourceMarks`, and Shift+H toggle ([18], persisted in `AppSettings`).
6. [13] Source markers (`M` in Source).
   - AC: saved per media, round-trip test.
   - Needs the bump.
7. [14] Drag In/Out handles on the strip.
   - AC: `MonitorScrubMath.hit(x:)` returns markIn, markOut or playhead with 6 pt slop.
8. [9] Preroll/postroll preference and Play Around (Shift+K).
   - AC: `PlaybackBounds.range` is extended by 3 s / 2 s and clamped.
9. [15] Relative timecode entry (`+10`, `-5`).
10. [11][12] Delete used clip feedback and delete sequences.
    - AC: `ProjectPanelModel.delete` returns the blocking sequence names; `Project.deleteSequence` refuses the last sequence, fixes `activeTimeline`, and is one undo step.
11. Poster frame (Cmd+P) stored in `MediaRef` (bump), plus Find (Cmd+F) with name/label/offline criteria.
12. Monitor feel from FEEDBACK-5 #2-4.
    - AC: handle drag scales uniformly unless Uniform Scale is off; the anchor point is draggable at the centre (hit-test priority); a rotate cursor is shown outside corners.
    - First check if the earlier monitors stream already did these; if so, add regression tests only.
13. Scrub latency HUD and cache-state ruler strip (feel.md #1, #5).
    - AC: `FrameCache.cachedRanges()` is a pure query test.
    - The strip drawing is the only edit it makes in `RulerView`.

Owns: `SQEditorUI/MonitorPanelModel.swift`, `MonitorScrubBar.swift`, `MonitorViewMapping.swift`, `ProgramSurfaceView.swift`, `OverlayCursors.swift`, `ProjectPanel*.swift`, `ProjectThumbnails.swift`, `ProjectIconView.swift`, `SQCore/Playback.swift`, `Project+MediaOps.swift`, new `SourceMarkers.swift`, `App/Sources/SourceMonitor.swift`, `SQPlayback/FrameCache.swift` and `Stats.swift`.

Additive only: `ProjectFile.swift`, `Model.swift` (`MediaRef` fields), `CommandMap`, `AppSettings`, `RulerView.swift`.

Must NOT touch: `Timeline*.swift` edit logic, clip drawing, transitions, captions, effects, speed.

Verify against Adobe text: preroll defaults and Play Around, whether Out includes its own frame (open question 2), Shift+H and Cmd+P hover and poster behaviour, and the Shift+L first speed. Grep for "preroll", "Play Around", "Poster Frame".

## Stream 3: `audio-shortform` (project file v20)

Value: dialogue and music polish for talking-head and TikTok. Builds on the merged gain and rubber band work.

Items (text-audio.md numbers):
1. [2] `[` / `]` gain keys.
   - AC: three clips selected go +1 dB in one undo step, Shift moves 6 dB, the floor never mutes, video clips are ignored.
2. [3] Audio fade handles on clip edges.
   - AC: a 1 s head drag creates volume keys 0 and 0 dB at 1 s; undo restores exactly; sub-frame snaps to 0; the handle follows trim.
   - This is the audio half of effects #1, and the same shared `FadeKeys` function is used by the effects stream. This stream owns that function (`SQCore/Fades.swift`); the effects stream calls it. Merge this stream before effects work uses it, or add it additively.
3. [4] Cmd-click on the rubber band adds a key (the volume line exists), with keys that cannot cross neighbours.
4. [12] Auto-duck music under dialogue.
   - AC: pure function in `SQAudioFX` from dialogue ranges, amount and fade to rational-time keys; none without dialogue; a re-run replaces generated keys.
5. [13] Match loudness.
   - AC: -23 LUFS clip with target -14 gets +9 dB (+-0.1); silence is unchanged; clamped.
6. [20] Track pan and volume.
   - AC: constant-power pan, hard left silences the right channel, persisted, export identical to playback (shared function).
   - Needs the bump.
7. [19] Stereo peak meter with clip latch.
   - AC: the hold time constant is documented, and a sample at or above 0 dBFS sets the latch until reset.
8. [23] Clip tags Dialogue/Music/SFX (default loudness target -14 / 6 dB lower).
9. [30] Pause shortening (silence removal), detection in `SQAudioFX`.
   - AC: ranges below the threshold and longer than N ms are rippled out leaving a fixed pad; frame-aligned; one undo step.
   - This is a timeline edit, not a change to media. Add a line to `docs/DECISIONS.md` and flag it for Paul before merge.

Owns: `SQAudioFX/*`, `SQPlayback/AudioFeeder*`, `SQEditorUI/AudioGainDialog.swift`, `AudioMeterView.swift`, `LoudnessMeterView.swift`, `TimelineView+VolumeLine.swift`, `TimelineWaveforms.swift`, `App/Sources/EditorPanels+Volume.swift`, `AppController+AudioGain.swift`, new `SQCore/Fades.swift`, `Ducking.swift`, `TrackPan.swift`.

Additive only: `Model.swift` (track pan/volume, clip tag), `ProjectFile.swift`, `CommandMap`, `SQExport` mix path (one call to the shared pan/gain function).

Must NOT touch: audio crossfade or transition code (transitions owns it), `Timeline+Captions`, SQText, video effects, timeline trim logic.

Verify against Adobe text: whether `[`/`]` gain steps and the clip-gain versus volume relation match, and the fade handle behaviour. Grep for "Audio Gain", "fade", "Normalize".

## Stream 4: `captions-text` (project file v21)

Value: the TikTok caption look and text workflow.

Items:
1. [6] Hard minimum caption duration.
   - AC: a 0.3 s caption before a 2 s pause is extended without overlap; property test for no overlaps and order kept.
2. [5] Create Captions options.
   - AC: `CaptionPreset.minGap`; the one-line preset yields `lines.count == 1`.
3. [7] Split and merge caption.
   - AC: the pieces cover the same range, the line splits at a word boundary, and split at an edge is refused.
4. [8][22] Add caption at playhead, delete caption, and timeline selection showing in the Captions tab.
   - Also fix review finding 9, the sub-frame neighbour overlap in `Captions.swift`; this stream owns that file.
5. [9] Caption-track style changes all items except those with explicit overrides.
6. [31] Karaoke word highlight, the TikTok look.
   - AC: word timings produce per-word colour keys; deterministic render test.
   - Largest item, so it is last.
7. [16] Type tool click on existing text edits it.
   - AC: hit test returns the topmost text clip and undo depth is unchanged.
8. [17] Tracking, italic and all-caps.
   - AC: width grows linearly with tracking; all-caps changes glyphs, not stored text.
9. [14][25] Stroke position (outside/centre, bounds grow by w) and shadow angle/distance.
10. [18] Six align-to-frame buttons.
11. [21] Transcript search with next/previous.
12. [27] Default text duration preference.

Owns: `SQText/*`, `SQTranscribe/*`, `SQCore/Captions.swift`, `SQCore/TextClip*.swift`, `SQEditorUI/Caption*.swift`, `Text*.swift`, `App/Sources/AppController+Captions.swift`, `EditorPanels+Captions.swift`.

Additive only: `ProjectFile.swift`, `Model.swift`, `CommandMap`, `ToolState` (Type-tool click behaviour only).

Must NOT touch: `TimelineInteraction` (item 7 uses a hit-test function in the text module that the timeline calls through a new small hook; add the hook line only), audio, effects, speed.

Verify against Adobe text: the Create Captions dialog fields and defaults, and the Type tool click and area text behaviour. Grep for "Create captions", "Type tool", "stroke".

## Stream 5: `effects-look` (project file v22)

Value: everyday visual tools and the clip-level fx workflow.

Items (effects.md numbers):
1. [1] Fade In/Out preset command (video opacity keys).
   - AC: 1 s fade on a 5 s clip gives opacity keys 0 at 0 and 1 at 1 s; undo restores; clips shorter than 2x clamp to half.
   - Audio part reuses `Fades.swift` from stream 3.
2. [2] Freeze Frame / Add Frame Hold.
   - AC: the held part's source range is one frame at every time; duration is the requested rational; neighbours ripple per setting.
3. [20][21] Second instance of an effect and drag reorder.
   - AC: evaluation order follows the list; one undo step.
   - Needs the bump (per-instance ids).
4. [16] Crop and [15] Gaussian Blur (Blurriness animatable).
   - AC: blur 0 is identity; 100 % total crop is empty.
   - Also the colour audit's Sharpen gap as a neighbourhood pass if time remains.
5. [17] Opacity blend modes (Multiply, Screen, Overlay, Add).
   - AC: known results on 2 test pixels, CPU and GPU parity.
   - Needs the bump.
6. [22] Paste Attributes.
   - AC: motion, opacity and effects copy with keys offset to the target clip start, in one undo step.
   - Timeline #22 is assigned here, not to stream 1.
7. [27][25][26] fx badge as a pure draw decision, fx toggle for Motion/Opacity, and Cut/Clear in the effect header menu.
8. [24] Ultra Key (green screen), last; only if the first seven are done.
9. Cmd-click on the Opacity rubber band adds a key.
   - AC: one key at the clicked time with the current interpolated value (analogous to audio item 3).
   - Uses the geometry already in the volume line; adds a separate opacity-line file.

Owns: `SQRender/*` effect and compositor files (new `Effects/Crop*.swift`, `GaussianBlur*.swift`, `BlendModes.swift`), `SQCore/Effects*.swift`, `Timeline+FreezeFrame.swift`, `Timeline+PasteAttributes.swift`, `SQEditorUI/EffectControls*.swift`, `ClipDrawing.swift` (fx badge only), `App/Sources/AppController+EffectControls.swift`.

Additive only: `Model.swift` (blend mode, effect instance ids), `ProjectFile.swift`, `CommandMap`, `EditorCommand`.

Must NOT touch: `Packages/SQRender` transition blending (transitions owns the two-layer compositor path; blend modes go into the single-layer composite function only), colour/Lumetri files, speed and time-remap files, `TimelineInteraction`.

Verify against Adobe text: blend mode list and order, Paste Attributes dialog contents, Freeze Frame versus Add Frame Hold, and the fx badge colours. Grep for "Paste Attributes", "Frame Hold", "blend mode".

## Stream 6: `speed-time` (project file v23)

Value: velocity edits and time tools for TikTok. Biggest single gap in spec/effects after transitions.

Items:
1. [8] Time Remapping model, `SpeedKeys` per clip.
   - AC: two constant segments give exact rational source times at the boundary; clip duration follows; reversed segments are allowed.
   - Migration keeps constant-speed clips (v14 `speed` / `reversed`) equal.
   - Needs the bump.
2. Source time = integral of the speed track, in rationals.
   - AC: ramp segments use an integer-exact formula; a property test of monotonic source time for positive speeds.
3. [9] Speed-ramp UI: speed rubber band over the clip, key split halves, ramp handles.
   - AC: pure geometry tests for split halves and ramp handles.
4. Render and audio path honour the remap.
   - AC: audio follows the remap with pitch kept per `keepsPitch`; export equals playback on a test clip.
5. [10] Frame Blend time interpolation.
   - AC: at 50 % speed between A and B, output = mix by the fractional source position.
6. [28] Time Interpolation picker in Speed/Duration, stored on the clip.
   - Optical Flow is not now.
7. Nested sequences can be retimed (audit/speed.md gap). AC: `.speedUnsupported` no longer returned for nested clips when the inner duration is derived at edit time (also review finding 6).
8. Retime keeps captions and keys.
   - AC: clip-local keyframes scale with a constant speed change, the rest unchanged; document Premiere's rule.

Owns: `SQCore/Speed*.swift` and `Retime*.swift` (new `SpeedKeys.swift`), `Nesting.swift`, `SQEditorUI/SpeedDialogModel.swift`, `SpeedDurationSheet.swift`, `App/Sources/AppController+Speed.swift`, `SQPlayback` source-time resolution and `AudioFeeder` time-map (one function), `SQRender` frame-blend sampler.

Additive only: `Model.swift` (`Clip.speedKeys`), `ProjectFile.swift`, `TimelineView.swift` (draw hook), `CommandMap`.

Must NOT touch: effects list, blend modes, fades, captions, audio gain/pan code, trim logic.

Verify against Adobe text: rubber-band behaviour (Time Remapping: split keys, ramp handles, Cmd-drag), the Frame Blend wording, and speed percentage limits. Grep for "Time Remapping", "speed keyframe", "Frame Blending".

## Not now

- **Group/Ungroup, Trim mode (double-click a cut), two-up/four-up displays, source patching:** all large, and they touch every edit function, so they would conflict with streams 1 and 2. A follow-up round after merge.
- **Marker duration UI, out-of-sync badge, Move/Slip into Sync, clip markers:** low value for solo short-form cutting.
- **Auto/Continuous Bezier and spatial interpolation (effects 11-14):** Paul has not confirmed he wants them; defaults are acceptable.
- **Optical Flow, fill gradient, kerning, responsive design pin, freeform Project view, Button editor:** low value or large.
- **Make Subclip:** would sit with the source stream but needs a `SubClip` model and relinking, so it is deferred to avoid a second bump there.
- **Filler-word removal from transcript:** needs a decision change; pause shortening is the safe first step.
- **Optimised-media proxy preference for scrubbing (feel #6):** needs a measured Mac session first.
- **HSL Secondary and Sharpen:** colour stream gaps; Sharpen is only an optional stretch in stream 5.
- **SQCore review findings 3, 5-12:** owned by the cloud session. Streams 2, 4 and 6 touch only findings 4, 9 and 6 (as stated above); the cloud session must not edit those files for those items at the same time.
- **Re-fetching the Adobe guide ([40]):** the files exist in `docs/reference/adobe`; each stream verifies its own rows with grep and marks them "verified" or "corrected" in the stream audit.

### Critical Files for Implementation
- /Users/paul/Documents/SequenceStudio/Packages/SQCore/Sources/SQCore/ProjectFile.swift
- /Users/paul/Documents/SequenceStudio/Packages/SQCore/Sources/SQCore/Model.swift
- /Users/paul/Documents/SequenceStudio/Packages/SQEditorUI/Sources/SQEditorUI/CommandMap.swift
- /Users/paul/Documents/SequenceStudio/App/Sources/AppController+Commands.swift
- /Users/paul/Documents/SequenceStudio/Packages/SQEditorUI/Sources/SQEditorUI/TimelineInteraction.swift
