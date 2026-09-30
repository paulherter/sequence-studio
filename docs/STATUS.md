# Status

## Slice board (autopilot, merged 2026-09-30)
One list across all work streams. Detail and history stay in the reference files: PHASE3 (color), PHASE4 (keyframes),
PHASE5 (audio FX), PHASE7 (text), PHASE8 (captions), EXPORT, LIBRARY, PROXY, REVIEW-1. Phase 2 detail: section below.

**Done**
- Phase 1 SSCore; Phase 2 P2-01…04, E-01, E-02.
- Color core (PHASE3 1–8): transfer/gamut/Bradford, `.cube` + tetrahedral, correction + tone map, pipeline, log2 saturation, Metal color chain, GPU scopes. HLG OOTF.
- Keyframe core (PHASE4 1–8) + `Clip.animation`, file format v3.
- SSAudioFX (PHASE5 1–6): gain/automation, presets, RNNoise + mix, own 4-band compressor, R128 metering, offline chain with resampling.
- SSText (PHASE7 1–4) + anchored animations, template v3. SSTranscribe (PHASE8 1–4). SSLibrary (LIBRARY 1–5).
- SSExport (EXPORT 1–7) + sidecar SRT. SSProxy (PROXY a–f) + auto-generation policy, LRU cap, color rule.
- REVIEW-1: all 10 findings fixed.

**Autopilot handoff (2026-09-30, usage limit). On main since the board was written:** E-05 clocks, E-10 audio feed/ring buffer, U-01/U-02/T-01 (new package SSEditorUI), SSCore bins + source marks (file v4), autosave/crash recovery, SSMedia relink, SSAudioFX realtime chain, REVIEW-2 fixes (Proxy, Library, Text; SSExport X1-X4 handed to the export session), GPL-3.0 + README.
**Finished on worktree branches, NOT yet on main** (bring with explicit paths; all tested):
- Integrator branch (agent aa372150…, `worktree-agent-aa372150755d48675`): merges E-07 compositor (reviewed clean), SSText TextRenderer, SSMedia Waveform + SSLibrary MediaPreviewProvider, SSEditorUI ScrubField, docking, keyframe graph, export dialog, scopes, text/audio/color inspectors, captions panel, Library panel, T-08 thumbnailer + meter, transform overlay, K-01 command map. Check it finished green, then bring it.
- E-04 FrameCache `worktree-agent-af1484b4a26699528` (reviewed + fixed): waits for Phase 2's E-03; then delete the `// TEMP` DecodeScale block and `import SSMedia`.
- Still running at handoff (check their branches): SSCore v5 nesting + caption tracks + rounded corners; T-02 timeline drawing; U-05 Project panel UI; SSExport TimelineFrameSource + caption burn-in; Effect Controls panel; Sony embedded LUT extraction.
**Other sessions:** Phase 2 session owns E-03 (in progress), E-06, E-08, E-09, E-11+, U-03/U-04, T-03..T-07, M-01/M-02, K-02. Color slice 9 on hold (Paul). Export session: loudness normaliser + REVIEW-2 X1-X4.
**Known:** SSMedia full suite fails in the shared tree while Phase 2's uncommitted VideoDecoder WIP is present. Merge helper used: bring.py (copies a branch's changed files, only its own STATUS lines).

**Next (in order, blocked-by in brackets)**
1. Phase 2 engine E-03…E-14, then shell/timeline/monitors/shortcuts U/T/M/K (section below). Critical path.
2. (REVIEW-1 done.)
3. PHASE3 slice 9: `ColorCorrection` → SSCore (`Clip.color`), per-clip source override (Interpret Footage), SonyMetadata → `SourceColorSpace`; embedded camera LUT [SonyMetadata].
4. Library decisions recorded (DECISIONS.md [auto]); SSLibrary follow-up running (preview cache LRU cap, backup pruning).
5. SSAudioFX realtime path for playback (no allocation in render, latency compensation) [E-10/E-11 API]; volume into `AudioSegment`.
6. SSText rendering (rasterize layout + style into a texture for the compositor) [E-07].
7. Integration [E-07/E-09]: color chain + scopes in compositor, keyframed transform in compositor (units: canvas px from centre), proxies in playback (PROXY §SSPlayback integration), SSExport `FrameSource` from the real renderer + caption burn-in.
8. UI [U-04, T-02]: Effect Controls (graph editor, easing menu, summary rows), captions flow (Transcribe → edit → CC → Enter), Library panel, color UI + scopes, export dialog + queue.
9. Phase 6 nesting + multiple sequences. 10. Phase 9: tab groups + drag-to-dock, workspaces, autosave/crash recovery, relink, performance.

**Open (Paul, at milestones)**: HLG vs QuickTime (needs `TestMedia/iphone-hlg.mov`, missing); denoise / compressor voicing by ear; text animation feel; E-12 scrub audio by ear.

## Current: Phase 2 planned (slices below), next slice: E-03
Engine interfaces: docs/ARCHITECTURE.md. One slice per fresh implementer context, in order unless marked parallel-safe (‖).
Each slice: read CLAUDE.md, ARCHITECTURE.md (named section) and only the listed files; tests first where logic is pure;
finish with `scripts/test.sh <Pkg>` green (+ `scripts/build.sh` for app slices) and one line here marking it done.
Integration tests that need real footage read `SS_MEDIA_DIR` (default `~/Documents/Videos`) and skip when absent.

## Phase 1 (done) — SSCore headless
Done in Phase 1: `Time`/`TimeRange`, `Clip`, `Track` (overwrite / insert / split / remove / ripple delete), `Timeline` with **sequence-wide ripple** (31 tests green): `rippleDelete`, `rippleTrim` (head/tail), `insert`; plain `trim`, `roll`, `slip`, `move` (overwrite) in Timeline+Edits.swift, all link-aware ; snapping in Snapping.swift (`snapPoints`, `snap`, `snapMove`; threshold passed in by the UI) ; snapshot undo `History<State>` with coalescing + dirty tracking ; `Project` + `MediaRef` (path/bookmark/fingerprint, relink status) and versioned `.ssproj` package (`ProjectFile` write/read/migrations/autosave) (87 tests green). Tracks have `isLocked` and `syncLock`; ripple shifts every unlocked sync-locked track, locked tracks never move and an edit on a locked track throws. Linked A/V partners are deleted/trimmed together.
Phase 1 follow-up (Timeline+RangeEdits.swift, 103 tests green): `lift(range, tracks:)`, `extract(range, tracks:)` (sync-lock aware, closes only as far as nothing collides), `slide(id, by:)` (neighbour edges adjust, clamped, partners follow), `moveInsert(id, to:, track:)` (Cmd-drag; source gap closes, destination ripples, `start` in pre-edit coordinates; linked A/V start offsets (J/L cuts) preserved), `Track.clear(range)`. No keymap layer exists yet, so `;` `'` `U` and the Cmd modifier are not wired. Not built: roll/move with ripple mode, keyframes.

## Phase 2 slices
Legend: **Files** to create/change · **API** (see ARCHITECTURE.md §) · **Accept** = done when.

### A. Model prep (SSCore, tests first)
- [x] **P2-01 Sequence format + track/sequence flags.** Files: SSCore Timeline.swift, Model.swift, new Marker.swift, ProjectFile.swift (v2 migration), tests. API §3 (`SequenceFormat`, `Marker`, Track name/isVisible/isMuted/isSolo/isTargeted/height, Timeline inOut/markers). Accept: v1 fixture JSON loads as v2 with defaults; round-trip tests; all existing SSCore tests green.
- [x] **P2-02 Evaluation.** Files: SSCore new Evaluation.swift + tests. API §3 `videoLayers(at:)`, `audioSegments(in:)`, `editPoints()`, `duration`. Accept: tests cover gaps, hidden track, mute/solo, clip edges (half-open), stacked order V1→Vn, source offset after slip.
- [x] **P2-03 Rate + shuttle.** ‖ Files: SSCore new Playback.swift + tests. API §3 `PlaybackRate`, `Shuttle`. Accept: table test of Premiere J/K/L sequences (L L L → 4×, J after L → −1, K+L held → 1/4, K+tap → ±1 frame, K → 0).
- [x] **P2-04 Edit helpers for cutting.** ‖ Files: SSCore Timeline+Edits.swift (or new Timeline+ThreePoint.swift) + tests. Reuse Timeline+RangeEdits.swift (`lift(range)`, `extract`, `moveInsert`). New API: `lift(_ ids:)` (link-aware delete of selected clips), `overwrite(_ placements:at:)`, `threePointEdit(source: TimeRange, media:, targets:, at:, mode: .insert/.overwrite)` building linked A/V clips, `addEdit(at:tracks:)` (Cmd+K / all tracks), `rippleTrimToPlayhead(_ edge:, at:, tracks:)` (Q/W), `extendEdit(to:)` (E). Accept: tests incl. locked tracks throw, sync lock honoured, links kept.

### B. Engine (SSMedia / SSRender / SSPlayback)
- [x] **E-01 Synthetic test media.** (done: `SSMediaTestSupport` = TestClipSpec/TestClipWriter/FrameStamp, .mov output; note: start offset gives a leading duplicate frame 0 at pts 0 when read via AVAssetReader; unfinished audio input stalls video, see writer.) Files: SSMedia Package.swift (+ target `SSMediaTestSupport`), TestSupport/TestClipWriter.swift, FrameStamp.swift. Writes small H.264 (B-frames on, GOP 12) / HEVC 10-bit clips via AVAssetWriter with the frame number stamped as a binary block pattern, optional VFR timestamps, optional start offset; stereo 48 kHz audio with 1-sample clicks at known times. `FrameStamp.read(CVPixelBuffer) -> Int?`. Accept: generate 60 frames, read every frame back through AVAssetReader, all numbers match.
- [x] **E-02 SampleIndex + Demuxer + probe.** (done: `MediaInfo` types live in SSCore, `MediaRef.info` optional; `AVDemuxer(url:)`, `MediaImporter.probe`, `CodecConfig` (avcC/hvcC bit depth+chroma). Notes: the media file itself has no duplicate frame for start-offset clips, the index has exactly frameCount entries from pts 0; H.264 GOP from AVAssetWriter is 11 frames in presentation order (keyint 12 counts decode order), B-frames of the next GOP's neighbours precede the sync in decode order; `previousSync(before:)` = nearest sync with smaller presentation index, 0 if none; Sony C2160 probes 3840x2160 avc1 4:2:2 10-bit untagged, 29.97.) Files: SSMedia SampleIndex.swift, Demuxer.swift (`AVSampleCursor`/`AVSampleBufferGenerator`), MediaImporter.swift, MediaInfo.swift (+ SSCore: `MediaRef.info: MediaInfo?` if placed there) + tests. API §4. Accept: pure tests on synthetic tables (VFR lookup, GOP ranges, B-frame reorder); on generated clips pts start at 0 with start offset; `probe` on Sony C2160 reports 3840×2160, 4:2:2 10-bit, untagged (skips without media).
- [ ] **E-03 VTVideoDecoder.** Files: SSMedia VideoDecoder.swift + tests. API §4 `VideoDecoding`, `DecodedFrame`, `DecodeScale`, `MediaError`. Reuse spike's session setup (Tools/DecodeSpike Support.swift `VTDec`). Accept: generated clip decodes with correct frame stamps for a full-clip range, a mid-GOP range, and two contiguous ranges (second call does not reseek: count sync-sample submissions); Sony GOP decodes hardware (skip w/o media).
- [ ] **E-04 FrameCache.** ‖ Files: SSPlayback FrameCache.swift + tests. API §6. Accept: tests with fake payloads: budget never exceeded, eviction order (far first, behind-direction ×2), `nearest` lookup, concurrent insert/lookup from 8 tasks under TSan-clean `swift test --sanitize=thread`.
- [x] **E-05 Clocks.** ‖ Files: SSPlayback Clock.swift + tests. API §6 `PlaybackClock`, `HostClock`, `ManualClock`. Accept: ManualClock at rates 1, −1, 1/4, 8 gives exact rational positions; HostClock 1 s sleep within ±2 ms; no Double in public API. done (autopilot): Clock.swift (PlaybackClock + setRate/seek, HostClock, ManualClock), reviewed, 20 tests.
- [ ] **E-06 PrefetchPlanner + DecodeScheduler.** Files: SSPlayback Prefetch.swift, DecodeScheduler.swift + tests. API §6. Accept: planner tests (forward, reverse, 8×, seek replaces queue, already-cached GOPs skipped, three stacked clips interleaved by time); scheduler test with a fake decoder: one job per media in flight, cancel on `submit` of a new queue.
- [ ] **E-07 Compositor v0.** Files: SSRender Compositor.swift, Shaders.metal (package resource), PixelFormats.swift + tests. API §5. YCbCr (420v, x420, x422, and compressed variants or fallback, see §5 risk) → RGB with the tagged matrix, aspect-fit, stack, placeholder colours. Accept: offscreen render of a generated frame, readback of 4 probe pixels within 1/255 of expected; 9:16 sequence with 16:9 layer is pillar/letterboxed correctly; 3 stacked 4K layers encode+GPU < 4 ms (logged).
- [ ] **E-08 Presenter + viewer view.** Files: SSRender Presenter.swift; SSEditorUI (or App, see open decision) ViewerView.swift (NSView, CAMetalLayer, CAMetalDisplayLink on a render thread). API §5. Accept: app shows the compositor output of a generated clip, Fit and 100 %, resize without tearing; surround #0C0C0C. Screenshot once.
- [ ] **E-09 PlaybackEngine (video).** Files: SSPlayback PlaybackEngine.swift, RenderLoop.swift, MediaResolver.swift, Stats.swift + tests. API §6. Accept (headless, ManualClock, generated media): play 60 frames → stamps 0…59 in order, 0 drops; seek to frame 37 presents 37; step −1 ×10 after play presents 36…27 from cache; `setTimeline` after a trim changes the composite without cache flush; stats filled.
- [x] **E-10 Audio feed + mixer.** Files: SSMedia AudioSource.swift; SSPlayback AudioFeeder.swift, RingBuffer.swift + tests. API §4 `AudioSource`, §7. Accept: pure tests with fake sources: sample-exact clip boundaries, reverse block order, mute/solo, ring buffer SPSC wrap; generated clip clicks land at exact sample positions. done (autopilot): AudioSource (+MemoryAudioSource, AssetAudioSource with reader-side SRC), RingBuffer (SPSC, flush epoch, consumed counter), AudioFeeder (mix/fill/thread, reverse, mute/solo, clip volume via Clip.volume(at:)). 5 + 10 + 5 tests.
- [ ] **E-11 AudioEngine + AudioClock.** Files: SSPlayback AudioEngine.swift, AudioClock.swift; PlaybackEngine switches to AudioClock when audio is audible. API §7. Accept: plays generated clip at rates 1, 2, 8, −1, 1/4 with pitch preserved (TimePitch), no underruns in 60 s (counter); simulated drift test (fake consumed-frame counter, 10 min) ≤ 1 frame; seek/rate change has 5 ms fades (unit test on the fade envelope).
- [ ] **E-12 Scrub audio.** Files: SSPlayback ScrubAudio.swift; engine `beginScrub/scrub/endScrub`, `step` grain. Accept: unit test that grain joins are continuous (no step > threshold at crossfades); **Paul judges by ear vs Premiere** (drag, step, J/K/L all speeds). Record verdict here.
- [ ] **E-13 File edge cases.** Files: SSMedia Demuxer/VideoDecoder error paths, SSRender placeholder use, tests. Accept: truncated copy of a generated clip (cut at 60 %) plays the good part then placeholder, no crash; garbage file → `.unreadable`; VFR clip on a 30 fps sequence maps to the right frames; edit-list offset clip starts at its first presented frame.
- [ ] **E-14 EngineBench + acceptance run.** Files: Tools/EngineBench (Package.swift, main.swift). ARCHITECTURE §9. Accept: the four PLAN.md Phase 2 numbers measured on M1 Max release build and written here with commit hash: 3× Sony C2160 60 s 0 drops · backward step p95 ≤ 8 ms · drift 10 min ≤ 1 frame · memory peak. If a number misses: stop and report, no tuning inside this slice.

### C. Shell and timeline
- [x] **U-01 Theme.** ‖ Files: SSEditorUI Theme.swift (colors, fonts, metrics from docs/DESIGN.md). Accept: every DESIGN.md token has a named constant; unit test checks a few hex values. done: Theme.swift (Colors, Fonts, Spacing, Radius, Metrics), 4 tests.
- [x] **U-02 Workspace layout tree.** ‖ Files: SSEditorUI Workspace.swift + tests. Tree `split(axis, [child], fractions)` / `tabs([PanelID], selected)`; built-ins "Editing – PC", "Editing – MacBook" (docs/UX.md §1); ops show/hide panel, select tab, set fractions, maximize. Codable. Accept: tests for both built-ins' structure, hide→show restores position, JSON round trip. done: Workspace.swift, hidden panels stay in the tree (show restores position), 11 tests.
- [ ] **U-03 EditorSession.** Files: App/Sources/EditorSession.swift (+ tests if moved to SSEditorUI). `@MainActor @Observable`: `History<Project>`, active timeline, playhead, selection, `perform(_ name:, coalescing:, _ edit:)`, open/save/autosave (ProjectFile), owns Program `PlaybackEngine` and pushes `setTimeline` after each commit. Accept: undo/redo updates engine timeline; dirty flag; autosave timer writes a snapshot.
- [ ] **U-04 Window shell.** Files: App SequenceStudioApp.swift, MainWindow.swift, Toolbar.swift, SplitHost.swift (NSSplitView from the tree, 1 pt black dividers), TabStrip.swift (capsule tabs), placeholder panels. Toolbar: import, tasks (placeholder), Edit | Color (Color disabled until Phase 3), panel toggles, workspace menu, Export (disabled). Accept: both workspaces switch from the menu, splits resize and persist per workspace, panels hide/show. One screenshot for Paul.
- [ ] **U-05 Import + Project panel.** Files: App/SSEditorUI ProjectPanel.swift (NSOutlineView), SSCore `Bin` model (tests first), SSMedia MediaImporter use. Columns Name / Format / Duration, offline in red, New Bin, drag files in, Cmd+I, drag items out (pasteboard type with media IDs). Background probe. Accept: import Sony + iPhone clip, formats shown; project saves/reopens with bins. Model done (autopilot): `Bin`/`BinItem` tree in SSCore Bin.swift (`Project.rootBin`, newBin/renameBin/move (cycle-safe)/deleteBin (children to parent)/sortBin stable/normalizeBins), project file v4. UI remains.
- [x] **T-01 Timeline geometry.** ‖ Files: SSEditorUI TimelineGeometry.swift + tests. time↔x at zoom (rational in, CGFloat out only at the view edge), track rows (V1 32, A1 26, others 20, user height), header 124, tool column 38, hit test → `.ruler / .header(track) / .clip(id, zone: body|head|tail) / .gap(track, time)`, trim handle width 6 pt. Accept: tests for round-trip mapping at extreme zoom, hit zones at clip edges, snapping threshold in pt → Time. done: TimelineGeometry.swift, 12 tests.
- [ ] **T-02 Timeline view (draw only).** Files: SSEditorUI TimelineView.swift, RulerView.swift, TrackHeaderView.swift, ClipDrawing.swift. Ruler (timecode, In/Out band, markers), headers (target chip, name, eye / mute+solo, lock on hover), clips (type colours, name strip, 2 pt yellow selection), playhead, scroll + zoom (pinch, `+ - \`), tool column. Accept: 200-clip timeline redraw < 4 ms (measured, logged); screenshot for Paul.
- [ ] **T-03 Playhead + scrubbing.** Files: TimelineView (ruler interaction), EditorSession. Drag in ruler → `engine.scrub`, click → seek, playhead follows playback with page auto-scroll. Accept: frame-exact position after drag (test via geometry), scrub audio audible.
- [ ] **T-04 Selection tool.** Files: SSEditorUI TimelineInteraction.swift (+ tests for pure parts). Click/Shift/marquee select, linked selection toggle, move with snapping (`S`), cross-track move, drag past last track adds a track, Delete (lift) / Shift+Delete (ripple). One undo step per gesture. Accept: interaction tests on geometry + SSCore results; manual feel check by Paul.
- [ ] **T-05 Trim and cut tools.** Files: TimelineInteraction.swift, ToolColumn.swift. Selection-edge trim, `B` ripple, `N` roll, `Y` slip, `U` slide, `C` razor, `A` track select forward, `H` hand; Cmd-drag = `moveInsert`; `Cmd+K`/`Cmd+Shift+K`, `Q`/`W`, `E` via P2-04. Program monitor shows trim frame while dragging. Accept: each tool test through the interaction layer; Paul checks feel.
- [ ] **T-06 Drag and drop to timeline.** Files: TimelineView drop handling, EditorSession. From Project/Source: overwrite by default, `Cmd` = insert, linked A/V on targeted tracks, ghost with snapping; first clip into an empty project creates a sequence matching the clip (UX 4.1). Accept: drop Sony clip into empty project → 3840×2160 29.97 sequence, V1+A1 linked; 2 clicks.
- [ ] **T-07 Track header functions.** ‖ Files: TrackHeaderView, EditorSession. Targeting, eye, mute, solo, lock, height drag, add/delete track; engine reflects eye/mute/solo live. Accept: toggles undoable; hidden V2 disappears from the Program monitor on the next frame.
- [ ] **T-08 Clip thumbnails + audio meter.** ‖ Files: SSMedia Thumbnailer.swift (first frame, cached per media), ClipDrawing, SSEditorUI AudioMeterView.swift (engine meter tap). Accept: first frame only on tracks ≥ 32 pt; meter shows peak with hold, green/yellow/red.

### D. Monitors and shortcuts
- [ ] **M-01 Program monitor panel.** Files: SSEditorUI ProgramMonitor.swift. Viewer (E-08), timecode 18 light, Fit popup, quality popup Full/½/¼ (→ `DecodeScale`), transport (play, step, Mark In/Out, Add Marker, Go to In/Out). Accept: quality ½ halves decode size (stats), In/Out shows on ruler.
- [ ] **M-02 Source monitor.** Files: SSEditorUI SourceMonitor.swift, EditorSession. Tab next to Program; double-click a clip in Project/timeline opens it; second `PlaybackEngine` on a one-clip timeline; source In/Out stored per media (`Project.sourceMarks`, SSCore, tests first); `,` insert / `.` overwrite via P2-04; drag video-only / audio-only handles. Accept: I/O in source, `,` inserts at playhead on targeted tracks, linked; only one engine plays at a time. Model done (autopilot): `Project.sourceMarks` + `SourceMarks` (markIn/markOut, setSourceIn/Out, clear), project file v4. UI remains.
- [ ] **K-01 Command map + keyboard routing.** Files: SSEditorUI Commands.swift (`EditorCommand` enum, Premiere default map from UX.md §3), App menus (File, Edit, Clip, Sequence, View, Window). Focus-aware routing (timeline / Program / Source / Project). J/K/L with key-down/up for K-held (P2-03; call `Shuttle.holdElapsed(key)` ~0.25 s after L/J goes down while K is held, else it stays a ±1 frame tap), `←/→` (Shift 5), `↑/↓`, Home/End, I/O, Shift+I/O, Opt+X, X, `;` `'` lift/extract In–Out, Space, S, M, tool keys, zoom keys, `Shift+1…7`. Accept: table test command map has no duplicate bindings; manual pass through UX 4.2 fully keyboard-driven.
- [ ] **K-02 Panel maximize + wrap-up.** Files: SplitHost, Workspace. `` ` `` maximizes hovered panel; workspace menu. Then Phase 2 review: run EngineBench again, Paul's ear test (E-12) and cut test (UX 4.1–4.2), update PLAN/STATUS.

Deferred on purpose (later phases): waveforms (Phase 5), Color page contents (Phase 3), Opt+drag duplicate, Type tool `T`, caption tracks.

## Open decisions
- (none) SSEditorUI package approved 2026-09-30, see DECISIONS.md.

## Phase 0 (done) — engine route B decided
Done: XcodeGen project (`project.yml`, empty SwiftUI app), six packages in `Packages/` (SSCore, SSMedia, SSRender, SSPlayback, SSExport, SSTranscribe, each with one placeholder test), `scripts/build.sh`, `scripts/test.sh [Package]` (errors only), decode/scrub spike in `Tools/DecodeSpike`.
Engine: Route B (own VideoToolbox path), see DECISIONS.md; Phase 2 acceptance criteria + risk items in PLAN.md.

## UI design (2026-09-30, done: Paul approved)
Canvas artifact "Sequence Studio UI": https://claude.ai/artifact/6mArdzhxkp4P9abYXJHP63 (private).
Tokens + screens: 1 workspace 9:16, 2 Effect Controls speed graph + easing menu, 3a/3b captions, 4a export, 4b export details,
4c export queue, 5 quick color + Scopes tab, 6 Color page (Edit | Color switch). UX.md, PLAN.md and DECISIONS.md updated to match.
Direction: Final Cut / Compositor look with AppKit controls, Premiere handling but never Premiere's glyphs; scrubbable values (no sliders); compact tracks; one color per clip type; one radius/spacing scale (tokens.css in the canvas).
Done. Handoff: docs/DESIGN.md. The artifact is the copy of record (canvas sources were only in the session scratchpad).

## Environment gotcha
`swift` on PATH is the swiftly shim (6.3.3) and links against the CLT SDK (MacOSX27.0.sdk) → "tapi error: malformed file". Use `/usr/bin/swift` (Xcode toolchain). The scripts already do. Package tools-version is 6.2 (needed for `.macOS(.v26)`).

## Spike results (M1 Max, release build, `Tools/DecodeSpike`; rerun: `cd Tools/DecodeSpike && /usr/bin/swift build -c release && .build/release/DecodeSpike [Sony|iPhone|<path>]`)
Route A = AVFoundation (AVAssetReader / AVComposition + custom `AVVideoCompositing` / AVPlayer seek). Route B = own `VTDecompressionSession` fed by `AVSampleCursor` + `AVSampleBufferGenerator` (no cache, no renderer). First 240 frames of each clip. Compositor is a no-op (no Metal), so these are decode + hand-off costs only.

| Clip | Format | Route B: VT hardware | Route B: VT software | A: reader decode | A: reader + composition + compositor |
|---|---|---|---|---|---|
| Sony C2160.MP4 | H.264 High 4:2:2 10-bit, 3840×2160, 29.97, 140 Mbit/s, GOP≈27, no color tags | **266 fps** (HW) | **fails** (-8969, 0/241 frames) | 166 fps | 212 fps |
| iPhone IMG_1281.MOV | HEVC Main 8-bit, 1920×1080, 59.96, 12 Mbit/s, GOP≈47, BT.709 | 2800 fps (HW) | 1290 fps | 364 fps | 483 fps |
| extra: iPhone 18 Pro/P1000065.MP4 | HEVC Main10 4:2:0 10-bit, 3840×2560, 29.97, 48 Mbit/s, GOP≈14, BT.709 | 619 fps (HW) | 183 fps | 183 fps | 195 fps |

Scrub latency (20 random targets, then 30 adjacent single-frame steps; time from seek call until the frame reaches the compositor / is decoded):

| Clip | B: VT random access (decode from previous sync frame) | A: AVPlayer+compositor random seek | A: AVPlayer+compositor 1-frame step |
|---|---|---|---|
| Sony C2160 | med 95 / p95 136 ms (up to 30 frames deep) | med 94 / p95 133 ms | med 11 / p95 32 ms |
| iPhone IMG_1281 | med 12 / p95 21 ms (up to 55 deep) | med 7 / p95 20 ms | med 1 / p95 3 ms |
| P1000065 (4K HEVC 10-bit) | med 19 / p95 29 ms (up to 15 deep) | med 18 / p95 36 ms | med 11 / p95 21 ms |

Native decoded formats: Sony `x422` (10-bit 4:2:2, VT hands out the Apple-compressed `&xf2` variant), P1000065 `x420`, iPhone IMG_1281 `420v` (compressed `&8v0` from VT).

### What the numbers say
- Hardware decode works on this M1 Max for all three, **including H.264 4:2:2 10-bit** (Sony). That clip has no software fallback through VideoToolbox: hardware only, ~9× realtime for one stream.
- Both routes land within noise of each other on random-access scrub (Sony ~95 ms both; cost is GOP depth × per-frame decode). Route A's 1-frame step is fast because AVPlayer keeps decoding forward; B would need the same (keep the session, decode next sample) plus a frame cache to match.
- Route A reader tops out below raw VT on the Sony clip (166–212 vs 266 fps) — irrelevant for one stream at 30 fps, may matter for stacked 4K layers.
- Not measured: multi-stream (stacked 4K layers), reverse playback / backward step, real Metal compositor cost, memory, audio sync. iPhone 1080p HW number (2800 fps) is pipelined throughput and likely optimistic; treat 1080p as "not a bottleneck".

### Caveats
- **No HLG/HDR iPhone clip exists in ~/Documents/Videos** (scanned all 210 files: iPhone clips are BT.709, 8-bit or 10-bit). HLG decode, color tags and tone mapping are untested. Sony clips carry no color tags at all (`? / ? / ?`) → S-Log3 must be assigned by us (detect by camera metadata or user choice).
- Sony clip is landscape 3840×2160, not vertical as previously noted.
- Timings vary run to run by ~10% (random targets); the spike is Swift 5 mode, throwaway code.

## Known facts
- Sony: long-GOP (GOP≈27) H.264 High 4:2:2 10-bit L5.1, 140 Mbit/s, LPCM audio.
- 124 of the 210 clips in ~/Documents/Videos are ProRes (`apcs`, 1080×1920) — likely exports.

