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

## 2026-10-01 Paul: app icon
App icon = spectrum timeline track with porcelain playhead (final 1b3), near-black; sources in App/AppIcon.icon (Liquid Glass .icon, ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon).
## 2026-10-01 [auto] Scale is relative to source pixels (project v10)
Premiere semantics: Scale 100 % = one upright source pixel per sequence pixel (a 4K clip in a 1080-wide sequence fills the width at 50 %; a phone clip counts with its rotation applied). Before, 100 % meant "aspect-fitted", so a rotated 4K clip needed 180 % to fill. The compositor draws a layer at its native size (`RenderLayer.nativeSize`, also for reduced-quality decodes); nested sequences the same with the inner format size. v9 -> v10 multiplies every picture clip's Scale (value and keys) by its fit scale (`Project.migrateScaleToSourcePixels`, needs probe info; clips without info and generators keep their value), so nothing moves on screen. Corner radii stay in px of the fitted layer (converted in the compositor), so the effect values need no migration. New clips are placed at the fit value (like "Default Media Scaling: Set to Frame Size"); the clip that sets the sequence format stays at 100 %. Clip context menu: "Set to Frame Size" and "Scale to Frame Size" both write the fit value into Scale (keyframes of Scale are removed, one undo step); Premiere's two items differ only by resampling, which we do not do. The Program-monitor transform overlay is not wired yet: when it is, pass `mediaPixelSize` to `TransformOverlayGeometry`.
