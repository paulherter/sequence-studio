# Spec: text, captions and audio (Premiere Pro vs Sequence Studio)

Area `text-audio` of CLOUD.md Job E. Written on Linux by reading code; nothing was run.

## Sources and confidence

- Adobe's guide could NOT be fetched: `scripts/fetch_adobe_guide.py` needs web.archive.org, which the cloud proxy denies (HTTP 403 on CONNECT);
  helpx.adobe.com and larryjordan.com are denied too. `docs/reference/adobe/` is therefore empty. Re-run the script on a machine with access
  and diff this spec against it.
- Behaviour below comes from web-search summaries (hints only) and from `docs/PREMIERE-BEHAVIOR.md` sections 8 and 9. Own wording throughout.
  Tags: **[S]** = seen in a search result, **(unverified)** = working knowledge, check in the real app.
  - Type tool point/area text, Essential Graphics: Evergreen helpwiki "Titles - Essential Graphics"; Adobe community threads on text boxes and justify.
  - Audio Gain dialog, `[` `]`: Evergreen helpwiki "Audio Levels - Premiere Pro"; Adobe community thread on the 1 dB shortcut.
  - Rubber band, Cmd-click keyframe, fade handles, Constant Power: filmdaft.com "how to fade audio in and out premiere pro"; ProVideo Coalition.
  - Create Captions limits: Adobe community threads "Create captions minimum duration" and "caption character length".
  - Essential Sound / Auto-Match: Larry Jordan "Modify Essential Sound Panel Settings"; Adobe "essential sound panel" learn page.
- Today = the code on `main` at the time of writing (paths relative to repo root, `Packages/` shortened to `P/`).

Overall picture: text has a solid render/style core (SSText) but only point-style text with a fixed template; captions are strong
(transcribe, segment, SRT in/out, burn-in) but have no caption-specific editing panel parity; audio has a good DSP/automation core
(volume keyframes, loudness, compressor) but NO timeline-level audio editing UX: no gain dialog, no rubber band, no fades, no crossfades, no mixer.

---

## 1. Type tool and text creation

| User action | Premiere result | Sequence Studio today | Verdict | Fix |
|---|---|---|---|---|
| `T` | Selects Type tool; cursor becomes an I-beam [S] | `CommandMap.swift:76` binds `t` to tool(.type); `ProgramSurfaceView.swift:103` shows `iBeam` cursor in the whole view | same | - |
| Single click on Program monitor with Type tool | Creates **point text**: no box, grows sideways with the text, clicked spot is the text origin; text is selected for typing [S] | `ProgramSurfaceView.swift:115-117` -> `EditorPanels.swift:472` places a clip with placeholder "Text" selected-all, centre at the click (`MonitorViewMapping.swift:101`, clamped to canvas) | differs: origin is the text centre, Premiere anchors by the click point and justification; no box at all | S: option for left-anchored point text (click = baseline-left) |
| Click-drag with Type tool | Creates **area text** (box): wraps inside the box, box handles resize the frame, justify options become active [S] | Drag is ignored (`mouseDown` only, no drag branch, `ProgramSurfaceView.swift:112-117`); layout supports `maxWidth` (`P/SSText/.../TextLayout.swift:65`) but the template has no box width | missing | M: add `boxWidth/boxHeight` to `TextTemplate`, drag creates it, resize handles in overlay |
| New text clip length | Uses the still-image default duration preference, 5 s default (unverified for text) | `EditorSession+Generators.swift:10`: `Time(5,1)` fixed | same (hard-coded) | S: read a still-duration preference |
| New text clip track | Placed on the video track under the playhead / highest targeted, above existing content (unverified rule) | `EditorSession+Generators.swift:15-19`: top-most unlocked video track free in the range, else top-most unlocked | same-ish | - |
| Click with Type tool on **existing** text | Enters edit mode on that text instead of creating a new one (unverified, common behaviour) | Always creates a new clip (`ProgramSurfaceView.swift:117`); editing existing text is by double-click on Select tool? see 1b | differs | M: hit-test text clips under the click, edit instead of create |
| Esc / click outside / switch tool | Commits the text [S] | `ProgramSurfaceView.swift:19,114` ends editing on tool change and on click; empty new text is discarded with no undo entry (`EditorSession+Generators.swift:38`) | same (better: no empty clip) | - |
| Undo after typing | Typing session is one step | Add + typing folded into one "Add Text" (`EditorSession.swift:204`) | same | - |
| Esc while editing | Exits edit mode, clip stays selected | Same (`ProgramSurfaceView` `endTextEditing`) | same | - |
| Cmd+Return / Enter | Commits (unverified) | Not checked | unknown | S: verify and add |

### 1b. Editing existing text

| User action | Premiere | Sequence Studio today | Verdict | Fix |
|---|---|---|---|---|
| Double-click text in Program monitor (Selection tool) | Switches to in-place edit with the Type tool [S] | `beginTextEditing` exists (`EditorPanels.swift:483`); confirm the double-click route in `TransformOverlayView` | unknown | S: test + wire if absent |
| Double-click a graphic clip in the timeline | Opens it in Essential Graphics Edit tab / selects text | Not found | missing | S |
| Selection + Enter in Effect Controls text field | Edits text field | `TextInspectorModel` has style setters, no text-body field found | missing | S |

## 2. Text properties (Essential Graphics > Edit)

Premiere's Edit tab for a text layer: font, style, size, tracking, kerning, leading, faux bold/italic, all caps/small caps, underline,
alignment (left/centre/right + justify variants with a box), fill, stroke(s), background, shadow(s), plus Align and Transform
(position, scale, rotation, opacity, anchor) and Responsive Design (pin to another layer, time fixed intro/outro) [S].

| Property | Premiere | Sequence Studio today (`P/SSText/.../TextStyle.swift`, `P/SSEditorUI/.../TextInspectorModel.swift`) | Verdict | Fix |
|---|---|---|---|---|
| Font family + weight | Family and style popup | `fontName` + `FontWeight` thin..black (`TextStyle.swift:12-16`, setters `TextInspectorModel.swift:98-99`) | same (finer weights) | - |
| Size | Points, default in the 60s for titles (unverified) | `size` default 48, min 1 (`TextStyle.swift:62,67`) | differs (default only) | S |
| Tracking (letter spacing) | Numeric field | Not in `TextStyle` | missing | M: add `tracking`, apply in layout kerning attribute, tests on layout width |
| Kerning pair adjust | Numeric / auto | Not in `TextStyle` | missing | M (low value for social editing) |
| Leading | Numeric | `lineSpacing` extra points (`TextStyle.swift:57`, `TextInspectorModel.swift:103`) | same-ish (extra vs absolute) | - |
| Faux bold / italic, underline, all caps, small caps | Toggle buttons | Not present | missing | M: italic + all-caps first (common for TikTok captions) |
| Alignment | L/C/R, plus justify variants with a box [S] | `.left/.center/.right` (`TextStyle.swift:20`) | differs (no justify, needs box first) | S after area text |
| Fill | Colour, gradients, eyedropper | solid `RGBAColor` (`TextStyle.swift:55`) | differs (no gradient) | L (low priority) |
| Stroke | Several strokes, align inside/centre/outside, join | One stroke with colour and width (`:56`, inspector `:108-110`) | differs | M: stroke position (outside) is what makes outlined captions legible |
| Background | Fill of a rectangle behind text, padding via size/opacity/corner | `TextBackground` colour, padding, radius (`TextStyle.swift:25-31`, inspector `:115-120`) | same | - |
| Shadow | Several shadows: colour, opacity, angle, distance, size, blur | One shadow: colour, offsetX/Y, blur (`:34-43`, inspector `:125-128`) | differs (offset not angle/distance; single) | S: expose angle/distance UI over offset |
| Transform: position, scale, rotation, opacity, anchor | Align and Transform section | Via clip `animation` (position etc.) in Effect Controls; text clip goes through the same Motion section | same | - |
| Align-to-frame buttons | Six buttons: left/centre/right, top/middle/bottom | Not found | missing | S: 6 commands with tests (position maths in `MonitorViewMapping`) |
| Responsive design (pin) | Pin text to a shape; keep in/out durations fixed when trimming | Not present | missing | L (skip) |
| Text presets / styles | Save as style; "Linked style" updates all uses (current Premiere) (unverified) | Preset save/apply by id (`TextInspectorModel.swift:135-162`) copies values, not linked | differs | M: linked styles (backlog, medium value) |
| Templates / animation presets | MOGRT in Browse tab | `TextTemplateCatalog`, in/out animations (`TextInspectorModel.swift:169-192`, `P/SSText/.../KeyframeTemplate.swift`) | same-ish (own format) | - |

## 3. Captions

### 3a. Workflow and defaults

| User action | Premiere | Sequence Studio today | Verdict | Fix |
|---|---|---|---|---|
| Window > Text > Transcript tab > Transcribe | Pick language, audio source, run speech-to-text; result is a text list with speaker labels, click a word to seek, edit text in place [S] (S9 in PREMIERE-BEHAVIOR) | `TextPanelView.swift:180` tabs Transcript/Captions; `CaptionsPanelModel.swift` (language list `:25`, progress, word click seek via `onSeek`) | same (no speakers) | S: speaker labels are out of scope |
| Languages | Dozens | de-DE, en-US, en-GB, fr-FR, es-ES, it-IT (`CaptionsPanelModel.swift:25`) | differs | S: list installed on-device recogniser locales |
| Re-transcribe over existing transcript | Asks to replace | `needsOverwriteConfirmation` (`CaptionsPanelModel.swift:43`) | same | - |
| Create captions dialog | Choose format (open captions/subtitle/CEA), style, **max characters per line** (default 42, may go to 72 since release 22) [S], **minimum duration** (1.2 s observed) [S], **gap between captions** (frames), **lines**: single or double [S] | Preset popup only (`TextPanelView.swift:142`), one built-in `Standard`: 42 chars, 2 lines, max 6 s, soft min 1 s, pause break 0.8 s (`P/SSTranscribe/.../CaptionPreset.swift:25-27`) | differs: no dialog, no gap setting, no single/double choice, no editable numbers | M: Create Captions sheet with numeric fields; gap = frames inserted between captions |
| Minimum duration semantics | Hard: a caption is held on screen for at least this long (community reports it is sometimes ignored) [S] | Soft: only suppresses a sentence-end split (`CaptionSegmenter.swift:56-59`); a short last caption stays short | differs | S: hard min duration that extends into the gap before the next caption |
| Sentence ends | A full stop in the transcript starts a new caption [S] | Splits on `. ! ? ...` only when half a line full and >= min duration (`CaptionSegmenter.swift:56-59`) | differs (intentionally gentler) | - |
| Where captions go | A caption track (own track type) above video; one track per language/format | `Timeline.captionTracks`, first caption track created on demand (`EditorSession+Generators.swift:68`, `P/SSCore/.../Captions.swift:24`) | same | - |
| Multiple caption tracks / languages | Yes | Model supports many; panel writes to the first only (`replaceCaptions` doc) | differs | M |

### 3b. Editing caption clips

| User action | Premiere | Sequence Studio today | Verdict | Fix |
|---|---|---|---|---|
| Select a caption in the timeline | Text panel jumps to the Captions tab with that caption | Not wired to the panel (`TextPanelView.swift:236 sync` handles clips) | unknown | S |
| Double-click a caption | Edit text in place (unverified) | `TimelineView.swift:401-403` -> `onEditCaptionText` | same | - |
| Drag caption body | Moves, bounded by neighbours | `CaptionTrack.move` clamps to neighbours and 0 (`Captions.swift:79`) | same | - |
| Drag a caption edge | Trim; captions on a track cannot overlap | `CaptionTrack.trim` clamps by neighbour/0/min duration (`Captions.swift:95`) | same | - |
| Split / merge buttons in Captions tab | Split at playhead, merge with next | Not found in model API (only `setLines`, `move`, `trim`, `remove`) | missing | M: `splitCaption(at:)`, `mergeCaption(with:next)` in SSCore, tests first (rational time, one undo step) |
| Add caption manually (+ button) | Adds a caption at playhead (default 3 s? unverified) | Not found | missing | S |
| Delete a caption | Delete / Ripple Delete | `remove` exists; ripple closes span via `closeSpan` (`Captions.swift:117`) | same | - |
| Ripple on video tracks | Caption tracks follow sync lock | `syncLock`, `followsRipple`, `openGap`, `closeSpan` | same | - |
| Style a caption | Essential Graphics > Edit with caption style; "Apply to all captions" via track style | `styleRef`/`animationRef` per item, library `P/SSText/.../CaptionPresets.swift` (classic, bold-box, outline; none/fade/fade-out/pop-in) | differs: styles are per caption through refs; no panel to restyle the whole track | M: caption-track style (one change updates all), L: per-word highlight (not in Premiere either, but key for TikTok) |
| Import SRT / caption file | File > Import, captions track created | `SRTReader.swift` in SSTranscribe | same (verify UI wiring) | S |
| Export SRT / sidecar | Export dialog: captions as sidecar/burn-in | `SRTWriter.swift`, `CaptionBurnIn.swift` | same | - |
| Open captions burn-in | Toggle in Export | `P/SSExport/.../CaptionBurnIn.swift` | same | - |

### 3c. Transcript-based editing (Text-Based Editing)

| User action | Premiere | Today | Verdict | Fix |
|---|---|---|---|---|
| Delete words in transcript removes media | Yes (Text-Based Editing, ripple-deletes the span) | DECISION: text edits never touch media (`CaptionsPanelModel.swift:6`); `TranscriptEditing.swift` rewrites text only | differs by decision | L, only after an explicit decision in DECISIONS.md. Filler-word removal is a big YouTube win. |
| Search in transcript / filler word detection | Search box; "Delete filler words" / pauses | Not found | missing | M: search field with next/previous (S), pause shortening (L) |

## 4. Audio gain, volume and levels

| User action | Premiere result | Sequence Studio today | Verdict | Fix |
|---|---|---|---|---|
| Clip volume in Effect Controls | Audio > Volume > Level in dB, range minus infinity to +15 dB, keyframable; default 0 dB [S] (PREMIERE-BEHAVIOR 8) | `EffectControlsModel.swift:122` range `silenceDB...15`; stored linear 0.001 floor (`:79`); keyframes `ClipAnimation.swift:67,123` | same | - |
| Volume curve between keys | Bezier/linear per key; ease types | `AnimatedProperty<Double>` with keyframe track; audio engine linear in dB between control points every 64 samples (`P/SSAudioFX/.../Gain.swift:35,86-110`) | same-ish: curve shape evaluated in linear amplitude? `VolumeAutomation.dB(at:)` uses `KeyframeTrack<Double>` in dB, but clips store linear volume (`ClipAnimation.swift:123`) | S: test that a fade from 0 to -inf dB is smooth, not abrupt (linear-amplitude interpolation is steep near zero) |
| `G` | Audio Gain dialog for the selected clips: Set Gain to (dB), Adjust Gain by (dB), Normalize Max Peak to, Normalize All Peaks to; shows peak amplitude [S] | No command, no key (`CommandMap.swift` has no `g` without modifier) | missing | M: `Clip.gainDB` (static, separate from volume), dialog, peak scan from waveform cache; tests for set/adjust/normalise maths |
| `[` / `]` | Lower / raise gain of selected clip by 1 dB; Shift = 6 dB (as listed in PREMIERE-BEHAVIOR) [S]; thread reports muting below about -24 dB with the shortcut [S] | Unbound: `KeyMapping.swift:14` maps the key codes but `CommandMap` has no audio-gain command | missing | S: after `gainDB` exists; clamp at the floor instead of muting |
| Rubber band on audio clip (Selection tool) | White line across the waveform at the volume level; drag it vertically = whole-clip level; shows tooltip in dB [S] | Not drawn: `WaveformDrawing.swift:36` takes a `volumeDB` closure only to scale the waveform | missing | M: draw line in `ClipDrawing` (rect hit zone +-4 px), drag edits volume, one undo step per drag |
| Add keyframe on rubber band | Cmd-click (cursor gets a plus) or click with Pen tool [S] | Pen tool slot reserved, no function (`TimelineCursorMap.swift:31`) | missing | M |
| Move keyframe | Drag, vertical = level, horizontal = time, cannot pass neighbours | Keyframes only editable in Effect Controls graph (`KeyframeGraphView.swift`) | missing in timeline | M (same code path as above) |
| Show clip vs track keyframes | Track header menu / badge menu | No track-level volume | missing | M with mixer |
| Fade handles | Small handle at the clip's audio edge, drag inward to make a fade in/out (current Premiere) [S] | None | missing | M: handle at both edges, creates two keys (0 dB at/after the handle, silence at the edge); important for music beds |
| Waveform | Per channel, rectified option, zoom with track height | `WaveformDrawing.swift` with cache, applies volume | same | - |
| Mute / Solo track | Header `M` / `S` buttons; solo mutes the others | `TrackHeaderView.swift:44,79`; model flags `Model.swift:245-247`; solo logic in `Evaluation.swift:144-155`, `PlaybackEngine.swift:189` | same | - |
| Mute a clip (Enable/Disable) | Clip > Enable (Shift+E) greys the clip | Not verified for audio | unknown | S |
| Audio meters | Vertical bars with peak hold, clip light that stays red, per channel | `LoudnessMeterView.swift` is LUFS (M/S/I) with true peak and a -14 LUFS target line; no per-channel peak bars | differs | M: stereo peak meter, 0 dBFS clip latch, click to reset |
| Track Mixer | Faders, pan, mute/solo/record, automation modes Read/Latch/Touch/Write | No mixer; per-track FX inspector only (`TrackAudioInspectorModel.swift`) | missing | L: start with track volume+pan in header (S/M) |
| Track pan | Mixer knob / Effect Controls Panner | `VolumeAutomation.pan` exists in DSP (`Gain.swift:29-32,55-66`), no UI path found | missing UI | S |
| Audio scrubbing | Dragging playhead plays slices | `P/SSPlayback/.../ScrubAudio.swift` (5 ms raised-cosine grain joins, `:31`) | same | - |
| Audio units | Display samples or milliseconds in timecode | Not checked | unknown | - |

## 5. Transitions and fades between clips

| User action | Premiere | Sequence Studio today | Verdict | Fix |
|---|---|---|---|---|
| Drop Constant Gain / Constant Power / Exponential Fade on an audio cut | Crossfade centred on the cut; default duration 1 s (preference default one second, unverified); Constant Power is the usual default [S] | `TemplateListPanelView.swift:170` says audio transitions have no template yet | missing | M: `AudioTransition` model on a clip edge (duration, curve), render in `AudioFeeder` (cos/sin law), export parity in `TimelineAudioSource` |
| Edit the crossfade | Drag edges, double-click for duration, Effect Controls alignment (centre/start/end) | n/a | missing | M |
| Default audio transition | Cmd+Shift+D applies default to selected cut | n/a | missing | S after the model exists |

## 6. Loudness and Essential Sound

| User action | Premiere | Sequence Studio today | Verdict | Fix |
|---|---|---|---|---|
| Essential Sound > tag clip as Dialogue / Music / SFX / Ambience | Each tag gets its own controls (repair, clarity, loudness, ducking) [S] | Track presets in `P/SSAudioFX/.../Presets.swift` (preset popup in inspector); no clip tags | differs | M: tags as clip metadata that pick a preset |
| Auto-Match loudness | Measures the clip and sets gain to a target LUFS; Premiere defaults: dialogue -23 LUFS, music about -25, SFX about -21 [S] (people use -16 for web) | `Loudness.swift` can measure; export normalisation target -14 LUFS, ceiling -1 dBTP (`ExportSettings.swift:60-64`) | missing as editing action | M: "Match Loudness" button -> sets `gainDB` from integrated LUFS; YouTube target -14, TikTok about -14 |
| Auto-ducking music under dialogue | Essential Sound > Ducking: sensitivity, duck amount (dB), fade duration; writes keyframes on the music clip [S] | Not present | missing | M: generate volume keys from dialogue activity (pure function of VAD ranges -> keys, easy to unit-test) |
| Noise reduction / DeNoise, DeReverb | Sliders | RNNoise denoiser stage (`RNNoiseDenoiser.swift`, `DenoiseStage.swift`) in the track inspector | same-ish | - |
| Export loudness normalisation | Not a standard export option; done with Loudness Normaliser effect or Essential Sound | `LoudnessNormalizer.swift` in SSExport | better | - |

## 7. Shortcuts (macOS defaults) touched by this area

| Key | Premiere | Today |
|---|---|---|
| T | Type tool | bound |
| G | Audio Gain dialog | unbound |
| `[` / `]` | Gain -1 / +1 dB (Shift = 6 dB) | unbound |
| Cmd+Shift+D | Apply default transition (video default; audio with Cmd+Shift+Opt+D? unverified) | unbound |
| Shift+E | Enable/disable clip | unverified |
| Text panel / Essential Graphics window | Window menu | `.text` panel command exists (`EditorCommand.swift:187`) |

---

## Ranked backlog (most valuable for YouTube/TikTok editing first)

Each item stands alone. "AC" = acceptance criteria that can be unit-tested (Swift Testing in the named package).

1. **Clip gain (`gainDB`) + Audio Gain dialog (`G`)** - M, SSCore + SSEditorUI.
   AC: `Clip.gainDB` default 0, decoded as 0 when absent; set/adjust/normalise-to-peak maths with peak from a supplied value; applies to selected clips as ONE undo step; playback and export apply gain once (volume * gain); clamp -inf..+24 dB.
2. **`[` / `]` gain keys (1 dB, Shift = 6 dB)** - S, SSEditorUI CommandMap. AC: three clips selected -> all +1 dB in one undo step; at the floor stays at the floor (never mutes); video clips ignored.
3. **Audio fade handles on clip edges** - M. AC: dragging the head handle 1 s creates keys (0 at clip start in silence, 0 dB at 1 s) on `volume`; undo restores exactly; fade shorter than one frame snaps to 0; handle follows trim.
4. **Rubber band with drag and Cmd-click keyframes** - M. AC: hit zone maths unit-tested in `TimelineGeometry`; drag changes clip level; Cmd-click adds one key at the clicked time (clip-local); keys cannot cross neighbours; one undo step per drag.
5. **Create Captions sheet (chars, min duration, gap, one/two lines)** - M, SSTranscribe + panel. AC: `CaptionPreset` gains `minGap`; segmenter never outputs a caption shorter than `minDuration` unless the clip ends; gaps between captions >= `minGap` frames when the source has room; single-line preset yields `lines.count == 1`.
6. **Hard minimum caption duration** - S, SSTranscribe. AC: a 0.3 s caption followed by a 2 s pause is extended to `minDuration` without overlapping the next caption; property test: no overlaps, order kept.
7. **Split and merge caption** - M, SSCore. AC: split at time t inside an item yields two items covering the same range, lines split at the nearest word boundary; merge joins lines and ranges; both one undo step; split at start/end refused.
8. **Add caption at playhead / delete selected caption (ripple option)** - S. AC: new caption 2 s (or up to next caption), never overlaps; refuses on locked track.
9. **Caption-track style: change style once for all captions** - M. AC: setting `styleRef` on the track updates every item; items with explicit override keep theirs.
10. **Audio crossfade (Constant Power default) on a cut** - M, SSCore + SSPlayback + SSExport. AC: at the cut centre both gains are 1/sqrt(2) (+-0.01); sum of squared gains stays 1 over the whole fade; playback and export produce identical samples; duration clamped by available handle.
11. **Default audio transition shortcut** - S, after 10. AC: applies to all selected audio cuts in one undo step.
12. **Auto-duck music under dialogue** - M, SSAudioFX (pure). AC: given dialogue activity ranges, amount, fade length -> keyframes on the music clip; no keys when no dialogue; keys rational time; re-run replaces earlier generated keys.
13. **Match Loudness (set gain from integrated LUFS to target)** - M. AC: -23 LUFS clip with target -14 gets +9 dB (+-0.1); silence gets no change; result clamped.
14. **Stroke position (outside / centre) for text** - M, SSText. AC: outside stroke width w grows the glyph bounds by w; layout bounds test; old projects decode as centre.
15. **Area text (drag with Type tool) with box width** - M. AC: `boxWidth` nil = point text (unchanged); drag creates box with the dragged width; wrapping uses `TextLayout.maxWidth`; minimum width 20 px.
16. **Type tool click on existing text edits it** - M. AC: hit test returns the topmost text clip at the point; click edits it, no new clip, undo depth unchanged.
17. **Tracking (letter spacing) and italic / all-caps text** - M, SSText. AC: width grows linearly with tracking; all-caps changes glyphs not stored text; italic decodes default false.
18. **Align-to-frame buttons (six)** - S. AC: left/centre/right and top/middle/bottom set `position` so the layout bounds touch the canvas edge or centre.
19. **Stereo peak meter with clip latch** - M, SSEditorUI + SSPlayback. AC: peak hold falls after a fixed hold time (choose and document the number); clip latch stays until reset; a sample at 0 dBFS or above sets the latch.
20. **Track pan and track volume in header or mixer-lite** - M. AC: pan -1..1 constant power (centre 0 dB, hard left right channel silent); persisted; export matches playback.
21. **Transcript search with next/previous** - S. AC: case-insensitive; returns word indices; seek to the word's start.
22. **Select caption in timeline -> Captions tab shows it** - S. AC: selection change publishes the caption id; model selects the row.
23. **Clip tags Dialogue/Music/SFX/Ambience -> default preset and loudness target** - M. AC: tag stored on clip; defaults -14 LUFS dialogue for web, music 6 dB lower (documented).
24. **Linked text styles** - M. AC: edit a style, all clips linked to it update; unlink copies values.
25. **Text shadow angle / distance fields** - S. AC: angle 90 deg, distance 4 gives offsetY 4 down.
26. **More recognition languages from the system** - S. AC: list equals the supported locales reported by the recogniser adapter (injected in tests).
27. **Default text duration preference** - S. AC: preference 3 s -> new text clip 3 s.
28. **Enable/disable clip (Shift+E) for audio** - S. AC: disabled clip silent in playback and export; undoable.
29. **Filler-word removal from transcript (ripple delete spans)** - L, needs a DECISIONS.md change first. AC: removing words n..m deletes that source span on all linked tracks as one undo step; A/V stay linked.
30. **Pause shortening (silence removal) for talking-head clips** - L, SSAudioFX detection + SSCore edit. AC: ranges below a threshold longer than N ms are rippled out leaving a fixed pad; frame-aligned; undo one step.
31. **Karaoke-style word highlight for captions** - L (not Premiere parity; the TikTok look). AC: word timings drive per-word colour keyframes; deterministic render test.
32. **Fill gradient for text** - L. Low priority.
33. **Kerning pairs** - M. Low priority.
34. **Responsive design pin** - L. Skip unless asked.
35. **Multiple caption tracks / languages in the panel** - M. AC: panel can target a track; create-captions never touches other tracks.

(35 items; the cap is 40.)

## Open questions for Paul

1. Should transcript edits ever change media (filler words, pause removal)? Today's DECISION says no; items 29 and 30 need a new decision.
2. Is gain a separate `gainDB` on the clip (Premiere: separate from Volume) or folded into the volume curve? The spec assumes separate, so `[` `]` do not disturb keyframes.
3. Is audio keyframe interpolation meant to be in dB (as `VolumeAutomation` does) or in linear amplitude (clip `volume` is stored linear)? Check which one actually drives playback in `AudioFeeder.swift:333-380`.
