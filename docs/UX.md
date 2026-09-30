# Sequence Studio — UX plan (step 0b)

Basis for the UI design (canvas: https://claude.ai/artifact/6mArdzhxkp4P9abYXJHP63, section 7 below). Follows PLAN.md "What it must feel like": cutting speed first, Premiere handling,
Final-Cut-clean look, classic tracks (no magnetic timeline), fewer clicks, easing as a core feature.
Reference: Paul's Premiere workspaces in `docs/reference/` ("EDITING - PC", "EDITING - MACBOOK").
Click counts are rough, unverified estimates. Section 6 lists what is not verified yet.

## 1. Window layout and workspaces

There is no single right layout, so **workspaces** (layouts switched from a menu in the title bar) are a core feature.
Layout is stored as a tree (splits → tab groups → panels). Phase 2 ships two built-in workspaces, "Editing – PC" and
"Editing – MacBook", switchable from the menu. Custom drag-to-dock layouts and saved user workspaces stay in Phase 9.

**Default "Editing – PC"** (from Paul's current workspace):

```
┌─────────────────────────────────────┬──────────────────┬───────────────────┐
│ [Effect Controls | Text | Color]│ Program Monitor  │ Library           │
│  (wide tab group)                    │ (tall, 9:16)     │  folders · search │
│                                      │ [Program|Source]  │  thumbnail grid   │
│                                      │                  ├───────────────────┤
│                                      │                  │ [Effects | Project]│
├──┬───────────────────────────────────┴──────────────────┤                   │
│T │ Sequence tabs · timecode · toolbar                   │                   │
│o │ Caption tracks C3..C1                                │                   │
│o │ Video V3..V1                                         │                   │
│l │ Audio A1..A4, Mix                                  ▐▌│ ← audio meter      │
└──┴──────────────────────────────────────────────────────┴───────────────────┘
```

- Title bar: **Import** (left), **Edit | Color** page switch (centre), **Export** (right). Nothing else (DESIGN screen 1). Panels are shown/hidden
  from the **Window** menu (one checkable item per panel, Workspaces submenu, Maximize Panel); export progress is a ring at the right end of the
  status bar (click → export queue popover). Settings: `Cmd+,` (General, Playback, Media, Keyboard).
- **Two pages, one sequence:** **Edit** (the workspaces below) and **Color** (section 2, Color page). A page is a built-in workspace with its
  own panels, not a separate mode: same sequence, same playhead, same selection, same undo. Switch with the title-bar control or `Shift+6` / `Shift+7`
  (unverified against Premiere's map, see section 6).
- **"Editing – MacBook"** (second built-in workspace, Phase 2): Program Monitor full height on the right,
  Library/Effects left, Effect Controls group in the middle, Project + timeline bottom left.
- Panels: resizable splits, show/hide, maximize the hovered panel with `` ` ``. Native macOS controls everywhere except
  timeline, monitors, keyframe graph. Standard macOS menus (File, Edit, Clip, Sequence, View, Window, Help).
- Essential Sound is dropped. Source Monitor is a tab next to Program (as in the MacBook workspace).

## 2. Panels

### Effect Controls (top-left tab group, first tab)
Selected clip. Groups (collapsible, **eye** toggles the group on/off), each property with an **animate diamond** (hollow = static, filled = animated;
our own glyph, no stopwatch): **Motion** (Position, Scale, Rotation, Anchor, Opacity),
**Effects** (Rounded Corners), **Color** (auto input transform S-Log3/HLG/SDR, WB, Exposure, Contrast,
Highlights, Shadows, Saturation, then Conversion LUT and Creative LUT popups, Reset; same order as the Color page), **Audio** (Volume).
- **Values are scrubbable text** (accent colour): drag left/right to change, click to type. No sliders, no always-visible fields.
  Animated properties show ‹ › to jump to the previous/next keyframe.
- Every animatable property has a disclosure chevron that opens its graph **in place** (no maximised view needed).
Right side: keyframe timeline, After-Effects style:
- **Summary keyframes:** a collapsed group or effect row still shows all keyframes of its children. They can be selected,
  moved in time and eased without expanding. All active keyframes are visible at a glance.
- **Keyframe shape shows interpolation:** diamond = linear, circle = eased (bezier), square = hold. Selected = accent.
- Per-parameter graph (expand a row): **Value | Speed** toggle, bezier handles, temporal and spatial interpolation
  (Position also shows the motion path with handles in the Program Monitor).
- **Relative multi-keyframe editing:** if several keyframes of the *same property* are selected and its value changes
  (drag in monitor, scrub the number, type it), all of them shift by the same delta. Other selected properties (e.g. Opacity)
  are untouched. Example: select both Position keys, drag up → whole move starts higher.

### Text (tab 2)
Premiere's Text panel. **Transcript** tab: Transcribe, language, editable transcript of the selected clip (edits change text only, never media).
**Captions** tab: caption list of the sequence, style preset, **Create Captions** (replaces the caption track, see 4.5).
Text templates are not here: they live in the Library (Text Templates) and are dragged to the timeline.

### Properties (removed)
There is no Properties panel. Text styling of a text clip is the **Text** section at the top of Effect Controls (text field, font, colour,
stroke, background, shadow, animation); an audio clip gets an **Audio** section (track preset, noise reduction, compressor) above Volume.
Transform, opacity and keyframes stay below in Effect Controls. Colour controls and Scopes are panels of the Color page.

### Program Monitor (top middle, tall)
Sequence playback, timecode, zoom (**Fit**), playback **quality popup (Full / 1/2 / 1/4)**, transport, Mark In/Out, Add Marker.
No format/resolution readout over the picture. A selected caption is edited in place (box + handles on the caption, not the frame). Direct manipulation
of the selected clip (move, scale, rotate, motion path). Color-managed to match QuickTime. Tab **Source**: clip preview, In/Out,
Insert `,` / Overwrite `.`, drag video-only/audio-only handles.

### Library (top right, late in V1 together with text templates)
User library, replaces what Premiere Composer does today:
- **Disk folders** (e.g. music folder) with thumbnails, search, favorites. Drag straight into the timeline. Audio previews (play/scrub) before dragging.
- **Own presets:** text templates, **animated text templates** (text + keyframes + easing saved as one item, own format, no .mogrt import),
  effect/easing presets, caption presets.

### Scopes (tab next to Library)
Waveform (luma, IRE) and vectorscope with skin-tone line, Rec.709. Same scopes, larger, on the Color page.

### Effects | Project (right, below Library)
- **Effects:** searchable tree of effects/presets (V1: Rounded Corners, audio presets, saved easing/text presets).
- **Project:** bins, icon/list toggle, search, columns Name / Format (S-Log3, HLG, offline in red) / Duration. Import by dragging in; context menu Relink, New Bin, Reveal.

### Timeline (bottom)
- **Tool column** (left, vertical): Selection `V`, Track Select Forward `A`, Ripple Edit `B`, Razor `C`, Slip `Y`,
  Hand `H`, Type `T`. (No Pen/Rectangle.)
- **Sequence tabs** on top (nested sequences open as tabs), **timecode** left, **toolbar:** insert/overwrite as nest or individual clips,
  snapping (`S`), linked selection, add marker, timeline display settings (wrench).
- **Track headers:** targeting chip (accent tint when targeted), track name, eye (video) / mute + solo (audio). Lock on hover.
- **Compact tracks** so 5+ layers fit on a MacBook: V1 32 pt, A1 26 pt, other tracks 20 pt (user-resizable).
- **Ruler:** In/Out range as a light band with edges, markers as small orange flags.
- **Caption tracks sit above the video tracks.** Audio meter on the right.
- **Clips:** one muted colour per type (video blue, audio green, nested sequence amber, text/graphics pink, captions purple),
  name on a strip; video shows **only the first frame** at the clip head and only on tall tracks; audio shows a waveform from the bottom.
  Selected clip: yellow border. Playhead: thin white line. **No keyframes or volume rubber bands in the timeline**: volume and all keyframes are edited in Effect Controls / Properties. Drag past the last track to add a track.

### Color page (second page)
Same sequence, same playhead. Left: **Scopes** (waveform, vectorscope). Centre: large viewer with **Before | After | Split**.
Right: one **Color** inspector in Lumetri structure, our look. **Rule: it is processed top to bottom, exactly as shown.**
Unlike Lumetri (input LUT first, sliders after it), corrections come before any LUT:
- **Source** (top row): camera detected (S-Log3 / S-Gamut3.Cine, HLG).
- **Correction:** white-balance eyedropper, Temperature, Tint, Saturation; Light: Exposure, Contrast, Highlights, Shadows, Whites, Blacks.
  Works on the full log signal.
- **Conversion LUT:** add a camera LUT (Load…, remove ×). Without one, S-Log3/HLG is converted automatically (color managed).
- **Creative:** Creative LUT (Load…) + Intensity.
- **Curves**, **Color Wheels** (Final Cut-style), **HSL Secondary**, **Vignette**, then the Rec.709 output.
Each section collapses and switches off with the eye; **Auto** / **Reset** on top. Values use thin centre-origin sliders with the scrubbable
value on the right; Temperature and Tint tracks show their colour direction. (The Edit page keeps slider-free Effect Controls.)
Bottom: **clip strip** of the sequence in order (first frame, number, dot = graded), **Copy Grade** / **Paste to Selected**; `↑ ↓` step clips.

## 3. Shortcut map

Premiere defaults, unchanged. Panel toggles use Premiere's `Shift+1…` set instead of my earlier `Cmd+1…5`.

| Key | Action | Key | Action |
|---|---|---|---|
| `V` `A` `Shift+A` | Select / Track fwd / Track back | `B` `N` `Y` `U` | Ripple / Roll / Slip / Slide |
| `C` `H` `Z` `T` | Razor / Hand / Zoom / Type | | |
| `Space` | Play/pause | `J` `K` `L` | Reverse / stop / forward (`K+J/L` slow) |
| `←` `→` | 1 frame (`Shift` = 5) | `↑` `↓` | Previous / next edit |
| `Home` `End` | Sequence start / end | `Shift+I` `Shift+O` | Go to In / Out |
| `I` `O` | Mark In / Out | `Opt+X` `X` | Clear In+Out / mark clip |
| `,` `.` | Insert / Overwrite | `F` `Shift+R` | Match frame / reverse |
| `Cmd+K` `Cmd+Shift+K` | Add edit / on all tracks | `Q` `W` | Ripple trim prev / next to playhead |
| `E` | Extend edit to playhead | `Delete` `Shift+Delete` | Delete / ripple delete |
| `S` | Snapping | `Cmd+L` `Cmd+G` | Link / group |
| `M` | Add marker | `Opt+drag` | Duplicate |
| `Cmd+C/X/V` | Copy/cut/paste (keyframes keep easing) | `Opt+Cmd+V` | Paste attributes, **no dialog**; with `Opt` held for the paste: dialog |
| `Cmd+Z` `Cmd+Shift+Z` | Undo / redo | `\` `+` `-` | Zoom fit / in / out |
| `Cmd+I` `Cmd+N` `Cmd+S` `Cmd+M` | Import / new sequence / save / export | `Shift+1…7` | Project, Source, Timeline, Program, Effect Controls, …, Effects (Premiere set) |

**Keyframes and easing (proposal, After Effects where sensible; J/K/L untouched).**
Note: F-keys need `fn` on a MacBook unless the system setting is changed. **Not yet checked against Premiere's default map** (Adobe's shortcut page was not reachable): verify in Premiere > Keyboard Shortcuts before Phase 4, and rebind on any collision.

| Key | Action |
|---|---|
| `F9` | Easy ease (selected keyframes) |
| `Shift+F9` / `Cmd+Shift+F9` | Ease in / ease out |
| `Cmd+Opt+H` | Toggle hold interpolation (AE) |
| `Opt+←` / `Opt+→` | Previous / next keyframe of the selected property (playhead jumps) |
| `Shift+F3` | Toggle Value / Speed graph (AE Graph Editor key) |
| `Opt+K` | Add keyframe at playhead on the selected property |

Not in V1: speed `Cmd+R`, rate stretch `R`, transitions `Cmd+D`.

## 4. Core flows

Clicks = mouse clicks/drags; keys counted separately. Premiere counts: rough, unverified estimates (Paul: "not important").

### 4.1 Import → first sequence
Drag files into **Project** (analyzed in background). Drag one clip onto the empty timeline: sequence matches its resolution, rate, aspect, no dialog.
Ours **2** vs Premiere **2–5**.

### 4.2 Cut
Double-click clip → Source tab; `J K L`, `I`, `O`, `,`/`.`. Timeline: `Cmd+K`, select, `Delete`/`Shift+Delete`; `B`, `N`, `Y`, `Q`/`W`.
0 mouse clicks when keyboard-driven, **identical to Premiere on purpose**. Gain is speed: no dialogs, smooth scrubbing.

### 4.3 Color
Quick fixes: Color group in Effect Controls (Edit page). Full grading: **Color page** (Final Cut-style, see section 2).
Log/HLG input transform is automatic. Order everywhere: Correction → Conversion LUT → Creative LUT → … → Rec.709 (see Color page).
LUT popups → pick (or **Load…** once). Values scrub; double-click resets.
Copy look: `Cmd+C`, select clips, `Opt+Cmd+V` (no dialog).

| | Ours | Premiere |
|---|---|---|
| Open color controls | 0 | 1–2 |
| LUT first time / already loaded | 3 / 2 | 5–6 / 3–4 |
| Log → correct base | 0 (auto) | 3–5 |
| Copy look to N clips | 2 + N select | 3–4 + dialog |

### 4.4 Keyframes and easing
1. Click the animate diamond on a property → keyframe at the playhead. Move playhead, change value (field, scrub or Program Monitor) → second keyframe.
2. **Shift a whole move:** select both keyframes of the property, change the value → both shift by the same delta.
3. **Ease:** select keyframes (marquee; a collapsed row's summary keyframes work too) → right-click → **easing template**
   ("Fast start", "Fast end", "Ease in/out", Linear, Hold, plus **my saved curves**) → all selected get exactly the same easing.
   Or `F9` / `Shift+F9` / `Cmd+Shift+F9`.
4. **Fine tune:** expand → Value / Speed graph, drag bezier handles. **Save curve** from the right-click menu; it appears in the template list.
5. Copy/paste keyframes keeps their easing.

| | Ours | Premiere |
|---|---|---|
| Two keyframes | 3 | 3 |
| Ease many keyframes | 3 (marquee, right-click, template) or 1 key | 5–6 per interpolation type |
| Shift a move by an offset | 1 (select both, drag) | not possible: move each key by hand |
| Reuse a custom curve | 3 | not possible |

### 4.5 Captions (at the end, after the edit)
1. **Text** tab → **Transcribe** (German, on-device; progress in place) → transcript appears there.
2. Correct text in the transcript. Rules: only text changes, never media. Unchanged words keep their timestamps; changed/inserted words
   are aligned to the neighbouring timing; captions update at exactly that spot.
3. **CC** button → preset picker opens with the default/last-used preset preselected → **Enter** → all captions are created as editable text layers on the caption track (no "convert to graphics").
4. Restyle: **Properties** tab → style / animation preset, applies to all captions at once.
5. After re-editing the video: re-transcribe. It overwrites transcript and captions, with a warning if there are manual edits.

Ours **2 clicks + Enter** (Transcribe, CC) vs Premiere **~10–14**; restyle all: 2 vs 4–6.

### 4.6 Export
`Cmd+M` or the title-bar **Export** button → dialog listing all sequences of the project with checkboxes (several at once, e.g. 3–4 videos), preset popup per sequence
(default: last used, first time 9:16 1080×1920 H.264 Rec.709), range, size estimate → **Export** → choose folder once (names prefilled from sequence names) → **Save**.
- **Show Details** (like the macOS print dialog) expands the same sheet: preset + Save as Preset…, sequences on the left (settings apply to the
  selected one), Video (format, codec, hardware encoding, resolution, frame rate, profile/level, bitrate mode + target/max, keyframe interval,
  max bit depth), Color (output space, HDR→SDR tone mapping, 1-1-1 tag), Audio (codec, sample rate, channels, bitrate, loudness normalisation
  to −14 LUFS), Captions (none / burn in / sidecar .srt), File (range, name).
- Exports run as a background queue; the title-bar tasks button shows a progress ring, its popover lists done / running / waiting jobs
  with stop and Show in Finder. Editing continues.
Ours **3** for one sequence, still **3** for four; Premiere **6–8** per sequence.

## 5. Scope notes
- V1: Library (user library + own presets, late, with text templates), Export of several sequences at once, **scopes**, **Color page**,
  export details incl. loudness normalisation and sidecar .srt.
- Out: Pen/Rectangle/shapes, voice-over recording, timeline keyframe/volume overlays, .mogrt import, text-based cutting in the transcript.
- Relative multi-keyframe editing: delta is relative to the selected keyframe's value; between keyframes, to the interpolated value shown.

## 6. Not verified
- Page switch shortcut (`Shift+6` / `Shift+7`) not checked against Premiere's defaults.
- Keyframe shortcuts (`F9` family, `Opt+←/→`, `Opt+K`, `Cmd+Opt+H`, `Shift+F3`) must not collide with Premiere's defaults. Check in Premiere before Phase 4.

## 7. Visual language (from the UI canvas, 2026-09-30)
- Final Cut / macOS 26 look with **AppKit controls** (capsule tabs, segmented controls, popups ⌃⌄, capsule search, checkboxes, push buttons).
  Premiere is the model for **behaviour only**, never for its glyphs (no fx badges, no stopwatches).
- Dark neutral greys without hue bias; one accent (system blue: text/icons #0A84FF, fills under white text #0A6CF0).
  Black 1 px dividers only between panes (draggable); hairlines inside a pane.
- SF Pro, four sizes (10 / 11 / 13 / 18 timecode), tabular digits; semibold only for titles.
- One radius scale (3 · 4 · 5 · 6 · 8 · 10 · 12 · 16) and 4 pt spacing (2 · 4 · 8 · 12 · 16 · 24, 6 = icon to label).
- Text contrast ≥ 4.5:1, including tertiary labels. Tokens live in the canvas `tokens.css`; names follow NSColor semantics.
