# Decisions

- 2026-09-30: Name "Sequence Studio". macOS 26+, Apple Silicon only. License GPL-3.0. English everywhere.
- 2026-09-30: Own data model + own Metal renderer; engine route decided after Phase 0 spike.
- 2026-09-30: Panels: fixed splits in Phase 2, Premiere-style tab groups + drag-to-dock + workspaces in Phase 9. Layout stored as a tree from day one.
- 2026-09-30: No magnetic timeline. Easing is a core feature (bezier handles, value + speed graph, presets). Fewer clicks than Premiere, esp. captions.
- 2026-09-30: UX plan (docs/UX.md) before Figma and before Phase 2.
- 2026-09-30: UX plan approved (docs/UX.md). Default workspace from Paul's Premiere "Editing – PC"; Phase 2 ships two built-in workspaces (PC, MacBook) with a menu switch, custom docking stays Phase 9. No modes/pages, Export button in title bar.
- 2026-09-30: Effect Controls: summary keyframes on collapsed rows, right-click easing templates (own saved curves), relative multi-keyframe editing per property, stopwatch keyframing. All keyframes/volume edited in Effect Controls/Properties, none in the timeline.
- 2026-09-30: Transcript editing is text-only (never cuts media); re-transcribe overwrites. Caption/text styling lives in Properties.
- 2026-09-30: V1 adds Library (disk folders + own presets incl. animated text templates, own format, no .mogrt) late with text templates, and multi-sequence export. No Pen/Rectangle, no voice-over recording.
- 2026-09-30: UI visual language from the design canvas (docs/UX.md §7): Final Cut/AppKit look, Premiere behaviour but never Premiere glyphs; scrubbable values instead of sliders; animate diamond + eye toggles; keyframe shape = interpolation; compact tracks; one colour per clip type, first frame only.
- 2026-09-30: **Changes UX plan "no modes/pages":** two pages, Edit and Color (Final Cut-style colour wheels), switched in the title bar. A page is a built-in workspace on the same sequence, not a separate mode. (Paul)
- 2026-09-30: V1 scope additions: scopes (waveform, vectorscope), export details (Show Details) incl. loudness normalisation and sidecar .srt, background export queue with progress. Text-based cutting in the transcript stays out. (Paul)
- 2026-09-30: Color processing order, deliberately unlike Lumetri: the Color inspector is processed top to bottom as shown: Correction (WB, exposure… on the full log signal) → Conversion LUT (optional camera LUT; otherwise automatic color-managed conversion) → Creative LUT + intensity → curves, wheels, HSL, vignette → Rec.709 output. (Paul)
- 2026-10-01 Paul: colour controls like Lumetri, but modular blocks; default Basic Correction → Input LUT; further corrections/Creative LUT/Curves/Wheels/Vignette addable and reorderable. **Supersedes the 2026-09-30 "deliberately unlike Lumetri" order where it differs, not the correction-before-LUT default:** the default stack is still Basic Correction → Input LUT (conversion), the Input LUT block is always visible under Basic Correction with its popup in the header row and exists once per clip (it is the conversion step, cannot be removed, only disabled = automatic conversion). Blocks above it work on the source signal, blocks below it on display-referred Rec.709; Basic Correction works in both positions (see the 2026-10-01 colour maths entry).
- 2026-09-30: HLG input applies the BT.2100 OOTF (system gamma 1.2, 1000-nit display, luminance-based) in the HLG→linear path; working linear is normalised so HLG reference white (75 %, 203 nits) = 1.0. To be verified against QuickTime with TestMedia/iphone-hlg.mov. (Paul)
- 2026-09-30: Engine route B: own VideoToolbox decode path (AVFoundation demux, own clock, frame cache), not AVComposition + custom compositor. Spike showed a tie on scrub; B wins on backward step/reverse and fits eased speed ramps, nesting and live edits. No second spike; its checks became Phase 2 acceptance criteria in PLAN.md. (Paul)

## 2026-09-30 Ripple is timeline-wide (Premiere behaviour)
- Ripple edits shift all tracks with sync lock on; locked tracks stay, edits on them throw. Type is `Timeline` (not `Sequence`, avoids `Swift.Sequence`).
- Ripple that would collide on another track is limited, not cut through: ripple delete / shorten closes the gap only as far as every shifting track allows (returns the applied amount). Clips straddling the edit point on other tracks are never split or trimmed; extending just pushes whole clips at/after the old end. Cutting through other tracks = a separate extract op, not built yet.
- Ripple head trim keeps the clip's start, later content shifts (Premiere).
- `Clip.mediaDuration` (optional) bounds tail extension; head extension is bounded by source start 0.


## 2026-09-30 New package SSEditorUI
- AppKit timeline, viewer, monitor panels, theme, workspace tree and command map live in a new package `SSEditorUI` (depends on SSCore, SSMedia, SSRender, SSPlayback) so UI logic is testable with `swift test` instead of building the app. `App` keeps the shell, lifecycle, EditorSession and menus. (Paul)

## 2026-09-30 [auto] Library open questions (LIBRARY.md 1–10)
1. Overlay detection is lazy: the preview provider probes alpha when it first makes a thumbnail and caches `hasAlpha` with the preview; the scan stays extension-only.
2. Extension list stays as is; files the decoder can't open show as unsupported at probe time instead of being hidden.
3. V1 ships not sandboxed (direct download, like Premiere). Bookmarks are still stored so moved folders resolve.
4. Skipping hidden files, package contents and outside-pointing symlinks: OK.
5. `FSEventsFolderWatcher` gets its manual check with the Library panel slice.
6. Search matches the file name only (Premiere Media Browser); path/tag search after V1.
7. Favorites keyed by folder id + relative path; a rename drops the favorite. Accepted.
8. Preview cache gets an LRU cap of 2 GB, same pattern as SSProxy (lastAccess, evict oldest first).
9. Preset export/import is after V1.
10. Keep the 3 newest `.corrupt-*` backups per file, prune older ones on the next backup.

## 2026-09-30 [auto] SSEditorUI U-01/U-02/T-01
- Theme: fixed sRGB constants (dark only), tabular digits everywhere.
- Panels: effectControls, text, properties, programMonitor, sourceMonitor, library, effects, project, timeline (tool column + meter belong to timeline).
- Built-in layouts: PC = [left 0.75 | right 0.25]; left = top [EffectControls/Text/Properties 0.6 | Program/Source 0.4] over timeline (0.55/0.45); right = Library over Effects/Project. MacBook = [left 0.68 | Program/Source full height]; left = top [Library/Effects 0.4 | Effect Controls 0.6] over [Project 0.25 | timeline 0.75].
- Hidden panels stay in the tree (show restores exact place); min fraction 0.05; maximize is a state, not a tree edit.
- Timeline: ruler 22 pt; tracks V(n)…V1 then A1…A(n); `Track.height` ignored in favour of per-track overrides; trim handle = min(6 pt, clip width / 3); edges half-open; snap threshold 8 pt.

## 2026-09-30 [auto] Project license: GPL-3.0-or-later
- Reason: the project already borrows GPL-3.0 code (palmier-pro reference) and permits only GPL-3.0-compatible sources (GPL, MIT, BSD, Apache-2.0). GPL-3.0-or-later is the license that stays compatible with all of them.
- LICENSE holds the canonical text from gnu.org; README and CONTRIBUTING state the terms.

## 2026-09-30 [auto] Embedded camera LUT (PHASE3 question 6)
- Clips with an embedded look (Sony "Look Control data" item, decoded by `EmbeddedMeta.lut(inClip:)`) load it automatically as the Conversion LUT when the clip is imported, like Premiere's "use embedded LUT". The Conversion LUT slot shows "Embedded: <name>" with a toggle to turn it off (per clip, stored in the clip's color settings); the popup still lists it so it can be replaced by a file LUT. Clips without an embedded look keep the automatic color-managed conversion.

## 2026-09-30 [auto] Text layers are generator clips
- Text clips are SSCore generator clips (`ClipSource.generator`, kind "text", opaque payload = SSText TextTemplate + AnimationSet, project file v6). SSCore stays free of SSText.
- Position/scale/rotation of a text layer come from the clip's Motion (keyframable like any clip, Premiere-like); the template itself has no position. The block is centred on the canvas before the clip transform.
- Text in-animations are anchored to the clip start, so a split text clip replays its in-animation on the right half (accepted; revisit if it feels wrong).

## 2026-09-30 Color slice 9: per-clip color model
- 2026-09-30 Paul: slice 9 go.
- [auto] `ClipColor` (static, keyframe-free) on `Clip.color`; `ColorCorrection` parameters moved to SSCore (SSRender keeps the math, typealias for source compatibility). Order Correction -> Conversion LUT -> Creative LUT.
- [auto] Conversion LUT: `nil` = none, `.automatic` (default) = embedded camera LUT when `useEmbeddedLUT` and the media has one, `.file`/`.embedded` explicit. Automatic embedded applies only while the effective source is S-Log3 (Sony look LUTs expect S-Log3 input); an explicit `.embedded` always applies.
- [auto] `MediaInfo.detectedColorSpace` / `embeddedLUTName` filled once at import (HLG+2020 tags, else Sony NRT metadata, else Rec.709). Project file v7 = identity migration.
- [auto] PQ / HDR10 sources are not supported in V1: they are detected as Rec.709 (TODO in `ColorDetection`). HLG is detected from the transfer tag alone (primaries missing or P3 still mean HLG/BT.2020).
- [auto] Project file v6 -> v7 stays an identity migration; old media has `MediaInfo.needsColorDetection == true` and the app runs `ColorDetection.detect(url:)` on open/relink to fill `detectedColorSpace` / `embeddedLUTName`.

## 2026-09-30 Paul: feedback after first app test
- Toolbar stays minimal and exactly like the design canvas (docs/DESIGN.md screen 1): Import on the left, Edit | Color centred; no panel toggles or workspace controls in the toolbar. Panels are shown/hidden via the **Window** menu (checkmark per panel, Premiere-style). A Settings window (⌘,) is needed.
- No Properties panel. Clip-specific controls (text style for text clips, audio, etc.) live in Effect Controls (Premiere); colour lives on the Color page.
- **Text** panel = Premiere's Text panel: Transcript + Captions (edit transcript, create captions). Text templates belong to the Library (Text Templates), not the Text panel.
- Effects are applied by **dragging an effect from the Effects panel onto a clip** in the timeline (no "Apply to Selection" button). Later: a Ctrl+Space quick palette (DaVinci-style) to search effects and apply to the selected clip with Enter.
- Dragging media into the timeline shows a live ghost of the clip at the drop position (move to place, release to commit, Esc or drag out to cancel), like Premiere — not just a "+" cursor.
- Resizing panels/window must never break layouts.
- S-Log3 footage currently shows only yellow (placeholder) — must decode and display.

## 2026-09-30 Implemented: shell per Paul's feedback
- Toolbar is Import | Edit-Color | Export only. Window menu = Workspaces submenu + one checkmark item per panel (click toggles, shortcut shows/focuses) + Maximize. Export ring moved to the status bar.
- `PanelID.properties` removed; new `.colorInspector` and `.scopes` (Color page panels; Edit layouts hold them hidden). Saved layouts migrate (`WorkspaceMigration.dropUnknownPanels`); an old Color page is reset to the new layout.
- Layout robustness: every panel has a minimum size (`PanelID.minSize`); split fractions are clamped to the minimums (`LayoutMetrics.clampedFractions`), the window minimum follows the visible layout, panels and splits clip to their bounds.
- Settings window (`AppSettings`, UserDefaults). Autosave interval and audio output are read at launch; the audio output device is stored but not yet used by the engine.

## [auto] Timeline track area fills the panel
Extra panel height is water-filled over the tracks (video weight 3, audio 2) up to caps video 120, audio 90 pt per track (uniform per kind, every track grows, not only V1/A1); user-resized tracks stay fixed. Only beyond the caps is there empty space. Chosen over a centre divider because it needs no new layout mode and hit testing keeps using one row list (`TimelineGeometry.viewportHeight`).

## 2026-10-01 [auto] New sequences: 4 video + 4 audio tracks
`Timeline.defaultTracks()` (V1-V4, A1-A4, first of each targeted) is used by New Sequence, the first-clip/untitled project and the demo. Key monitor: only an editable NSTextView keeps keys; a non-editable field editor no longer swallows Space/J/K/L (FEEDBACK-2 T3).

## 2026-10-01 [auto] Effects are an explicit per-clip list (project v9)
`Clip.effects: [ClipEffect]` (id, kind, enabled, animatable parameters) replaces `ClipAnimation.cornerRadius`; no entry = effect not applied, no Effect Controls section, renderer ignores it. v8 -> v9: a non-default radius becomes an applied Rounded Corners effect, default = not applied. The effect's default (also what Reset restores) is Radius 24. While Effect Controls has focus, Delete/Backspace act on its selected keys, then the selected effect, never on timeline clips.

## 2026-10-01 Colour: Lumetri-like ordered blocks (project v11)
- `ClipColor` = `source` + `useEmbeddedLUT` + `sections: [ColorSection]` (kinds: basicCorrection, inputLUT, creative, curves, wheels, vignette; each has `id`, `enabled`, parameters). v10 -> v11: the old correction / conversion LUT / creative LUT fields decode into Basic Correction, Input LUT, (Creative) in the old order; a bypassed slot becomes a disabled block. The look is close, not bit-identical (new maths).
- Maths (SSRender `ColorStages`): every block works on a *tone signal* `t` = Rec.709-encoded picture signal. After the Input LUT that is the display signal itself; before it the block is wrapped (`t = OETF(source-linear)` -> maths -> inverse), so the same controls feel the same in both positions. Temperature/Tint and Exposure act on linear light (Bradford white balance in the gamut of that position, exposure = gain in stops); Contrast is linear around t = 0.45; Shadows scale the dark end multiplicatively (black stays black), Highlights add a soft-masked offset; Whites/Blacks move the white/black point (levels); Saturation around luma; Vibrance protects saturated colours and skin hues. Each tone stage is monotone on its own, so the tone curve cannot fold at any slider combination (tested with random extremes).
- Creative: look LUT + intensity, then Faded Film, Vibrance, Saturation, Shadow/Highlight Tint (+ balance). Curves: RGB (master + R/G/B), monotone cubic, baked into 64-entry tables. Wheels: lift / gamma / gain with luminance masks and per-wheel luminance slider, master saturation. Vignette: amount, midpoint, roundness, feather.
- Not built (open): Sharpen, Hue/Sat curves, HSL Secondary, HDR White/Specular, Match.
- GPU: the chain is split into passes (max 8 blocks, one LUT and 3 curve tables per pass; later passes run in place). CPU `ColorPipeline.process` stays the reference (GPU within 2e-4 relative).
- Viewer display path checked: Rec.709-tagged footage is decoded to working-linear with the inverse BT.709 OETF and written with the forward OETF into an unmanaged `bgra8` CAMetalLayer (no colour space set), so untouched footage is a code-value pass-through: no double or missing gamma. QuickTime colour-manages BT.709 -> display (gamma ~1.96 -> display), so mid-tones can differ slightly from our pass-through (not measured against QuickTime yet). Left as is.
## 2026-10-01 Paul: app icon
App icon = spectrum timeline track with porcelain playhead (final 1b3), near-black; sources in App/AppIcon.icon (Liquid Glass .icon, ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon).
## 2026-10-01 [auto] Scale is relative to source pixels (project v10)
Premiere semantics: Scale 100 % = one upright source pixel per sequence pixel (a 4K clip in a 1080-wide sequence fills the width at 50 %; a phone clip counts with its rotation applied). Before, 100 % meant "aspect-fitted", so a rotated 4K clip needed 180 % to fill. The compositor draws a layer at its native size (`RenderLayer.nativeSize`, also for reduced-quality decodes); nested sequences the same with the inner format size. v9 -> v10 multiplies every picture clip's Scale (value and keys) by its fit scale (`Project.migrateScaleToSourcePixels`, needs probe info; clips without info and generators keep their value), so nothing moves on screen. Corner radii stay in px of the fitted layer (converted in the compositor), so the effect values need no migration. New clips are placed at the fit value (like "Default Media Scaling: Set to Frame Size"); the clip that sets the sequence format stays at 100 %. Clip context menu: "Set to Frame Size" and "Scale to Frame Size" both write the fit value into Scale (keyframes of Scale are removed, one undo step); Premiere's two items differ only by resampling, which we do not do. The Program-monitor transform overlay is not wired yet: when it is, pass `mediaPixelSize` to `TransformOverlayGeometry`.

## 2026-10-01 Paul: plan decisions after fourth test
- Colour panel = fixed Lumetri-like sections in one column (Basic Correction, Creative, Curves, Colour Wheels, HSL Secondary, Vignette), each collapsible with a toggle on the right; for more, add a second "Colour" effect (Premiere style). Replaces the free "+" blocks UI.
- Input LUT popup sits at the top of Basic Correction (like Premiere), but the Basic Correction sliders are applied to the log signal BEFORE the LUT.
- Expanded keyframe property shows only the speed graph under the row; keys appear once (in the row). Value graph optional via context menu.
- Crop in Motion: later.
- Timeline follows playback page-wise; manual scrolling wins until playback restarts.
- Type tool (T) like Premiere: click in Program monitor → text clip on the top free video track at the playhead (5 s), type immediately; style in Effect Controls › Text.

## 2026-10-01 [C2] Program monitor interaction
- Overlay anchor: the crosshair is draggable directly only when it sits away from the picture centre; otherwise Option-drag on the picture moves it (picture stays, Position compensated). Smart guides (canvas centre/edges, other layers' edges/centres, 6 view px, Cmd disables) apply to moves; magenta lines while dragging.
- Monitor pan/zoom is a view property (`ViewerZoom.view(scale, centerX, centerY)`, centre in sequence px), never the clip transform. Scroll pans (only when not Fit), pinch and Cmd/Option+scroll zoom about the cursor, double-click with Hand = Fit, Fit popup resets.
- Type tool: a new text box left empty is removed when editing ends. The edit field only shows caret and selection; the real text is the rendered one.
- Text overlay box = text raster at scale 1 (position shifted by the raster centre); animation scale/rotation of in/out animations are not shown on the overlay.
## 2026-10-01 Stream A: Effect Controls keyframe area (implementer choices, Paul to confirm by feel)
- A value edit always applies at the playhead; selected keys only take it when the playhead sits on one of them (then all selected keys shift together). A key selected elsewhere never captures an edit. A key that was just moved is deselected.
- Reset button on an animated property = value at the playhead (key created/replaced); "Reset All" (right-click) drops the keys.
- Text/Audio section now sits below the Motion/Opacity/Volume rows. Divider min 324 pt / keyframe area min 160 pt, persisted in UserDefaults `effectControls.labelWidth`.
- Zoom: pinch, Option/Cmd+scroll, +/-/\ (when Effect Controls has focus), horizontal scroll pans, bottom zoom bar (round handles, double-click = fit). Handle drags in the graph are axis-locked (vertical only when |dy| >= 1.5 |dx|), Shift frees both.
## 2026-10-01 Colour panel rebuilt as fixed sections (project v12)
- `ClipColor.effects: [ColorEffect]` replaces the v11 block list. One effect = fixed sections with toggles; processing order inside an effect is Basic Correction sliders, Input LUT, Creative, Curves, Wheels, Vignette. The first effect's Input LUT is the conversion step (full strength, sliders before it work on the source signal); later effects are display-referred and their Input LUT is a normal look with intensity.
- The Basic Correction toggle also switches the Input LUT off (the first effect then falls back to the built-in conversion, log footage stays viewable).
- v11 migration: first block of each kind fills effect 1, further blocks become effect 2, 3, ...; block order is not kept; a bypassed Input LUT becomes "none". A bypassed Basic Correction with a live Input LUT migrates as an enabled, neutral Basic Correction so the LUT survives (the bypassed slider values are dropped). v10 sliders already ran before the conversion LUT, same as now, so no reordering is needed.

- 2026-10-01 Paul: app icon is "Klappe C1" for now (clapperboard filling the icon shape, edge-to-edge stripes, framed Aurora panel, Liquid Glass). Sources: icon-work/klappe/C1.icon, generator notes in the canvas artifact.
## 2026-10-01 [colour-stability] Hue Saturation Curves, project v14, eyedropper, Auto
- Project v14 (v13 is the markers change from the timeline stream): `ColorEffect.hueCurves` (Hue vs Sat, Hue vs Hue, Hue vs Luma, Luma vs Sat, Sat vs Sat). y = 0.5 is "no change"; hue curves wrap around. Encoded only when not flat, so untouched effects keep their v12 JSON; v13 -> v14 is an identity migration (missing key = flat). They live in the Curves section (its switch, neutral check and Reset cover them) and run after the RGB curves; all five sample the colour entering the block and act together (as in Premiere). Maths: hue shift up to +-60 degrees by rotation about the grey axis, saturation x0..x2, luma +-1 stop; hue-keyed adjustments fade out towards grey. CPU (`PreparedHueCurves`) and Metal (`hueCurvesStage`) match 1:1 (GPU parity test); a block uses two of the three curve-table slots of a pass.
- White-balance eyedropper: click in the Program monitor, 5 x 5 mean of the composite (working-linear) at the click, `WhiteBalanceSolver` finds the extra Temperature/Tint that make it neutral and adds them to the current values (exact for Temperature, close for Tint). One undo step. `ColorPickHub` carries the click from `ProgramSurfaceView`.
- Basic Correction Auto (next to a new tone Reset, as in Premiere's Tone group): analyses the Program frame as shown, raises Exposure so the bright end sits at ~0.96 and sets Blacks (reach is limited to +-0.1 by the slider) for the dark end; added to the current values, so a second press is stable. Whites, Contrast, Highlights, Shadows are left alone. Premiere's Auto also uses frame sampling over the whole clip; ours uses the current frame only.
- Creative look preview now shows the clip's frame at the playhead (the composite already contains the look); synthetic picture only when the playhead is outside the clip.
- Not done: Sharpen (needs a spatial pass, the colour chain is per pixel), HSL Secondary (placeholder stays, disabled).
- `scripts/test.sh`: per-package watchdog (default 900 s, `SQ_TEST_TIMEOUT`), kills the process tree and retries once; SSText runs `--no-parallel` like SSMedia (a stuck fontd call used to hang the whole run). Timing tests judge best-of-rounds (redraw 200 clips, audio underruns) or wait for the effect (captions debounce) instead of one noisy sample.

- 2026-10-01 Paul: never abbreviate Sequence Studio as "SS"/"ss" (Nazi reference). Abbreviation is SQ/sq, project files are `.sqproj` (old `.ssproj` files must still open). Packages SSCore… → SQCore…, env vars `SS_*` → `SQ_*`, defaults keys `ss.*` → `sq.*`. Done as one mechanical rename after the night streams are merged, to avoid conflicts with open branches.
- Review fixes (colour-stability): pixel readback (eyedropper, Auto, look preview) no longer reads the engine's reused target on a second queue or waits for the GPU. `PlaybackEngine.requestFrameCapture(key:)` has the render loop encode the readback on its own command buffer right after the frame (or on its queue behind it when idle); results arrive on the main actor; requests are coalesced per key; the look preview is one request in flight, never while playing, at most every 150 ms.
- Eyedropper and Auto measure the composite of the Program monitor, so they are disabled (tooltip says why) when another layer is visible at the playhead, the clip has more than one Colour effect, or the playhead is outside the clip. The sample is taken after the whole effect; the solver adds the correction to the current values.
- Hue-keyed curves wrap: the model keeps first and last point at the same y; the maths drops a point at x = 1 (first point wins), repeats the period to both sides, and treats one point as a flat curve at its y (never the diagonal). Colour is not applied by the renderer to text/generator layers, so the panel hides for them and Paste Colour skips them.
- `scripts/test.sh` watchdog is an inactivity timeout (`SQ_TEST_IDLE`, default 300 s without output) that kills only its own process group; no machine-wide pkill.

## 2026-10-01 Constant clip speed (project v14)
- `Clip.speed` is an exact ratio (`ClipSpeed` num/den, clamp 1 %...10000 %, Premiere's range), `Clip.reversed`, `Clip.keepsPitch`. `Clip.source` stays "the media range used"; timeline duration = `source.duration / speed` (`Clip.duration`). Edits choose `source.duration = frames * frameDuration * speed`, so timeline lengths stay whole frames and source ranges are exact rationals (no Double in the model).
- Reversed: the clip's first frame is the last frame of `source`; `Clip.sourceTime(at:frameDuration:)` is the one mapping used by evaluation, planner, render and export. Head/tail handles swap for reversed clips (`Clip.headHandle`, `tailRoom`, timeline time).
- Keyframes stay in clip-timeline time (they move with `extendHead`, not with the source).
- Nested sequences, titles and stills are not retimed yet (`EditError.speedUnsupported`).
- Audio: `AudioFeeder` retimes per segment with `AudioRetimer` (stateless per output sample): overlap-add time-stretch when "Maintain Audio Pitch" is on, linear resampling when off, mirrored reads for reverse. Playback and export share it (`TimelineAudioSource` uses the feeder), so they cannot disagree. The transport rate (J/K/L) still uses AVAudioUnitTimePitch, separately.
- Video: no frame blending; the frame covering the mapped source time is shown.
- File version: v14 (v13 belongs to the timeline stream), migration is the identity.
