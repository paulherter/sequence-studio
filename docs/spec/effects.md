# Premiere behaviour spec: effects (Effect Controls, keyframes, interpolation, speed, time remapping, transitions)

Job E, area `effects`. Written by the cloud job from code reading plus web hints.

**Source limits (read this first).**
- `scripts/fetch_adobe_guide.py` could not run: the cloud proxy denies `helpx.adobe.com` and `web.archive.org`, so `docs/reference/adobe/` is empty.
  Nothing below was checked against Adobe's own pages. Re-run the job on a machine with access to confirm the "Hint" rows.
- Behaviour comes from web-search hints, cited by page name: Adobe help "Controlling effect changes using keyframe interpolation",
  Frame.io "Insider Tips: Use Keyframe Interpolation for Smoother Animation", Frame.io "Three Ways to Manipulate Time in Premiere Pro",
  PremiumBeat "3 approaches for time remapping in Adobe Premiere Pro", Adobe "Premiere Pro add transitions" tutorial, Larry Jordan "Discover the hidden controls in keyframes".
- Premiere facts we know from experience but no source confirmed are marked **(memory)**. Treat both as unverified until checked on a Mac with Premiere.
- Our side was read in the code at `main` (9d6c43a). The older `docs/audit/effects.md` is partly stale; the code wins.

Verdicts: same / differs / missing. Sizes: S (under a day, one package), M (a few days, 2 packages), L (engine work).
Paths are under `Packages/` unless noted. SSEditorUI = `SSEditorUI/Sources/SSEditorUI`, SSCore = `SSCore/Sources/SSCore`.

## 1. Effect Controls panel: properties and values

| User action | Premiere result | Sequence Studio today | Verdict | Fix |
|---|---|---|---|---|
| Open panel for the selected clip | Shows fixed effects Motion, Opacity (video) or Volume (audio), then applied effects, in order | Sections Motion, Opacity, Rounded Corners, Volume (`EffectControlsModel.swift:7-30`) | same, but only one applied effect kind | – |
| Motion properties | Position, Scale, Scale Width, Uniform Scale, Rotation, Anchor Point, Anti-flicker Filter (memory) | Position, Scale, Rotation, Anchor Point; Uniform Scale checkbox (`EffectControlsView.swift:499-523`) | differs: no Anti-flicker (low value) | none |
| Opacity | Opacity %, Blend Mode dropdown | Opacity 0-100 % (`EffectControlsModel.swift:displayRange`), no blend mode | missing blend modes | L (renderer) |
| Volume | Bypass, Level in dB, Channel Volume, Panner (memory) | Level in dB, -60 floor = silence, max +15 (`:75-130`) | differs: no Bypass, channel volume, pan | M |
| Scale range | 0-10000 % (memory) | 0-10000 % | same | – |
| Value scrub (drag the blue number) | Drag changes value; Shift speeds up, Ctrl/Cmd slows (memory) | px x step, Shift x10, Option or Command x0.1 (`ScrubField.swift:14,176`); steps: scale/opacity/rotation 0.5, position 1, dB 0.1 (`EffectControlsModel.swift:displayStep`) | same (feel is Paul's call) | – |
| Click number, type, Enter | Inline edit | Same, Esc cancels, Up/Down step (`ScrubField.swift:15`) | same | – |
| Tab in a text field | Moves to next field (memory) | Tab / Shift-Tab commit and move (`ScrubField.swift:225`) | same | – |
| Reset (circular arrow) | Restores default, keys removed (memory) | Reset, Reset All, Reset Value at Playhead in right-click (`EffectControlsView.swift:455-470`) | same, extra entry | – |
| Twirl a section | Remembered per clip type (memory) | Per clip kind (`collapsedSections`) | same | – |
| fx toggle on Motion / Opacity | Eye-style toggle bypasses the effect | Only on applied effects; none on Motion/Opacity/Volume | missing | M (renderer needs a "motion disabled" path) |
| Right-click effect header | Cut, Copy, Paste, Clear (memory) | Copy, Paste (`EffectControlsView.swift:321-346`) | differs: no Cut/Clear entries | S |

## 2. Keyframes in Effect Controls

| User action | Premiere result | Sequence Studio today | Verdict | Fix |
|---|---|---|---|---|
| Stopwatch on | Key at playhead with current value | `toggleStopwatch` (`EffectControlsModel.swift:402`) | same | – |
| Stopwatch off | Warning, all keys deleted (memory) | Returns `.needsConfirmation` then deletes (`:402-420`) | same | – |
| Add/remove key button (diamond between arrows) | Toggles key at playhead | `toggleKeyAtPlayhead` (`:422`) | same | – |
| Go to previous / next key | Arrow buttons; also Opt+Left/Right is not a Premiere default (memory: Premiere has no default key) | Buttons (`:458`); Option+Left/Right bound in timeline (`CommandMap.swift:119`) | differs: extra shortcut, harmless | – |
| Add Keyframe shortcut | None by default (memory) | Option+K (`CommandMap.swift:120`) | differs, harmless | – |
| Change value with stopwatch on | New key or update at playhead; with keys selected, edit moves selection relatively (memory) | `setValue` (`:467`), relative edit with selection (`selectedKeysAtPlayhead` `:541`) | same | – |
| Click a key | Selects it; Shift adds; marquee selects many | Lanes view (`EffectKeyframeLanesView.swift:150-211`) | same | – |
| Click property name | Selects all keys of that property (memory) | Per audit: done | same | verify with a test (S) |
| Drag key | Moves in time, replaces a key it lands on | `moveSelection` (`:657`), frame snapped | same | – |
| Shift-drag key | Snaps to playhead and other keys (memory) | Snaps to playhead and other keys (`EffectKeyframeLanesView.swift:178`) | same | – |
| Option-drag key | Copies keys (memory) | Leaves copies behind (`:173`, `KeyframesPremiere.swift moveDuplicating`) | same | – |
| Delete | Removes selected keys | `deleteSelection` (`:699`); falls back to selected effect (`:861`) | same | – |
| Cmd+C / V keys | Paste at playhead onto same property, or onto the selected property of the same type | `KeyframesClipboard`, `retargeted` (`KeyframesPremiere.swift`) | same | – |
| Key right-click menu | Temporal Interpolation: Linear, Bezier, Auto Bezier, Continuous Bezier, Ease In, Ease Out, Hold; Spatial Interpolation for Position (Hint: Adobe help, Frame.io) | Linear, Bezier, Ease In, Ease Out, Easy Ease, Hold, Saved Curves, Copy, Paste, Delete (`EffectKeyframeLanesView.swift:249-290`) | differs: Auto Bezier, Continuous Bezier, spatial entries missing; Easy Ease and Saved Curves are ours | M |
| Ease In / Ease Out | Convert key to Bezier with a default curve; change one side (Hint: Frame.io) | One side only (`KeyframesPremiere.swift:23`: `.in`, `.out`) | same | – |
| Hold | Value jumps; line is flat after the key (Hint: Adobe help) | `.hold` on the key's outgoing side (`KeyframesModel.swift segmentValue`) | same | – |
| Auto Bezier | Handles recomputed for a smooth curve whenever neighbours change (Hint) | No such mode: handles are stored once | missing | M |
| Continuous Bezier | Moving one handle mirrors the smoothness of the other (Hint) | Handles are independent | missing | M |
| Glyph per interpolation | Linear diamond, bezier / auto / continuous round, hold square (memory) | `KeyGlyph.swift` from handles | same | – |
| Value graph / speed graph | Twirl the property to show a graph; speed graph shows rate (memory) | Value and speed graph, `toggleSpeedGraph` Shift+F3 (`CommandMap.swift:120`, `KeyframeGraphView.swift`) | same | – |
| Graph zoom | Zoom bar below timeline area | `KeyframeZoomBar.swift` (double-click fits `:79`) | same | – |
| Position motion path in Program | Path with spatial handles, drag points | `KeyframesSpatial.swift`, `TransformOverlayView.swift` | same | – |
| Spatial keys: Auto Bezier, Linear for position | Position keys are Auto Bezier by default (memory) | Spatial tangents default to zero (straight) (`KeyframesModel.swift:Vec2.interpolate`) | differs: Premiere curves the path by default | M |
| Default new-key interpolation | Linear (memory) | `.linear` (`Keyframe.init`) | same | – |
| Easy Ease shortcut | None in Premiere; F9 is After Effects (memory) | F9, Shift+F9, Cmd+Shift+F9 (`CommandMap.swift:116`) | differs, deliberate | – |

## 3. Keyframes on the timeline

| User action | Premiere result | Sequence Studio today | Verdict | Fix |
|---|---|---|---|---|
| Opacity / Volume rubber band on clip | Line over clip, drag to change, Cmd-click adds point, "Show Clip Keyframes" menu (Hint: PremiumBeat) | Timeline draws waveform only (`TimelineView.swift`, no keyframe drawing found by grep) | missing | L |
| Drag rubber band up/down | Changes level of whole clip or segment | none | missing | L |
| Pen tool (P) | Adds and moves keys on the line (Hint) | none | missing | L |
| Audio gain Cmd+G style | Audio Gain dialog (memory) | none found in effects area | missing | belongs to text-audio spec |
| Clip fx badge | Shows fx on clips with effects (memory) | none | missing | S |

## 4. Effects panel and applying effects

| User action | Premiere result | Sequence Studio today | Verdict | Fix |
|---|---|---|---|---|
| Panel bins | Presets, Lumetri Presets, Audio Effects, Audio Transitions, Video Effects, Video Transitions (memory) | Only "Video Effects" with Rounded Corners (`TemplateListPanelView.swift:160-180`) | missing | grows with each new effect |
| Search | Field filters by name, expands bins | Filters title or category (`:182 rows(matching:)`) | same | – |
| Drag effect onto clip | Applied; works on many selected clips if all selected | `sequenceEffectID` drag (`:195`) | same | – |
| Double-click effect | Applies to selected clips (memory) | Per hint text on panel (`:200`) | same | – |
| Second instance of same effect | Allowed, stacked | One per clip (`ClipEffect.roundedCorners` getter/setter `ClipEffect.swift:44`) | differs | M |
| Reorder effects by dragging header | Order changes the result | Not possible, one effect | missing | M, after a second effect kind exists |
| Effect catalogue | Dozens of Video Effects (Crop, Gaussian Blur, Transform, Mirror, Ultra Key...) | One | missing | L each; see backlog |
| Paste Attributes | Cmd+Opt+V, choose which attributes (memory) | Listed in Edit menu, not implemented (per audit) | missing | M |

## 5. Speed and time remapping

| User action | Premiere result | Sequence Studio today | Verdict | Fix |
|---|---|---|---|---|
| Cmd+R on clip | Dialog: Speed %, Duration, Reverse, Maintain Audio Pitch, Ripple Edit Shifting Trailing Clips, Time Interpolation (Hint: Adobe tutorials) | Cmd+R `.speedDuration` (`CommandMap.swift:109`), context menu entry (`TimelineContextMenu.swift:59`) | same, except Time Interpolation choice | S |
| Speed range | 1 % to 10000 % | `ClipSpeed.minimum`/`maximum` = 1/100 and 100/1 (`ClipSpeed.swift:11-12`) | same | – |
| Reverse | Negative speed shown | `reversed` flag, negative typed speed reverses (`Timeline+Speed.swift:35`) | same | – |
| Time Interpolation | Frame Sampling, Frame Blending, Optical Flow (memory) | Nearest frame only | missing | L (blend M, optical flow L) |
| Rate Stretch tool (R) | Drag a clip edge: speed changes, in/out fixed | `rateStretch` (`Timeline+Speed.swift:125`) | same | – |
| Timeline clip name | Shows `[200%]` (memory) | `SpeedLabel.nameSuffix` (`TimelineView.swift:883`) | same | – |
| Time Remapping: Show Clip Keyframes > Time Remapping > Speed | Rubber band for speed; Cmd-click adds speed key; drag key halves apart to make a ramp; clip length follows (Hint: Frame.io, PremiumBeat) | none: constant speed only (`ClipSpeed` is one ratio; `Clip.speed` single value) | missing | L |
| Speed key split | Key splits in two with a draggable ramp between (Hint) | none | missing | L |
| Time remap freeze frame | Hold on a time key (memory) | none | missing | L; a Freeze Frame command is a cheaper M first |
| Add Frame Hold / Freeze Frame (Shift+E style) | Clip > Video Options > Frame Hold; Add Frame Hold (memory) | none | missing | M |
| Audio when speed changes | Pitch kept unless unchecked | Overlap-add stretch or resample (`SSPlayback/AudioRetimer.swift`) | same | – |

## 6. Transitions

| User action | Premiere result | Sequence Studio today | Verdict | Fix |
|---|---|---|---|---|
| Drag transition onto cut | Centred on cut by default, 30 frames, cross dissolve (Hint: Adobe tutorial, lynda course) | No transition type in the model: `rg Transition` in SSCore/SSRender finds nothing | missing | L |
| Apply default transition (video) | Cmd+D to the nearest cut, or selected edit (memory); one source says Shift+D, which is the Windows/old shortcut (Hint: search result) | none | missing | L |
| Apply default audio transition | Cmd+Shift+D, Constant Power 1 s (memory) | none | missing | M after video |
| Default duration | 30 frames video (Hint), 1 s audio; set in Preferences > General (Hint) | none | missing | S once exists |
| Edge drag | Dragging edge of transition on timeline shortens or lengthens it; dragging the body moves alignment (Hint: lynda course) | none | missing | M |
| Alignment | Center at Cut, Start at Cut, End at Cut (memory) | none | missing | part of model |
| Handles needed | Needs extra source beyond the cut; otherwise warns and repeats frames (memory) | none | missing | part of model |
| Double-click transition | Opens its controls in Effect Controls | none | missing | M |
| Fade in/out on clip ends | Dip to Black at a clip edge (memory) | Opacity keys by hand only | missing | S as a preset on top of keys |

## 7. Ranked backlog (YouTube / TikTok first)

Each item stands alone. "Accept" is a unit test unless stated. SSCore tests run on Linux.

1. **Fade in / Fade out presets** (S, SSCore + EditorUI). Command "Fade In/Out" writes two opacity keys (and two volume keys on audio) at clip start/end, one undo step.
   Accept: 1 s fade on a 5 s clip gives opacity keys 0 at 0 s, 1 at 1 s; undo restores the snapshot; clips shorter than 2x fade clamp to half length.
2. **Freeze Frame / Add Frame Hold** (M, SSCore). Splits the clip at the playhead and holds that source frame for N seconds.
   Accept: duration = requested rational; source range at every time of the held part equals the one frame; neighbours ripple per setting; one undo step.
3. **Cross dissolve model + evaluation** (L, SSCore). `Transition` value on a cut: kind, duration (rational), alignment, handles used.
   Accept: evaluation near a cut returns both clips with weights summing to 1; duration clamps to available handles; no overlaps appear on the track; project file round-trips.
4. **Apply Default Transition command** (M, SSCore + EditorUI), depends on 3. Accept: nearest cut to playhead gets a 30-frame (sequence frames) dissolve; second apply replaces, not stacks.
5. **Compositor two-layer blend** (L, SSRender), depends on 3. Accept: midpoint frame of black to white test clips is 50 % grey within 1 level.
6. **Audio crossfade (constant power)** (M, SSCore + SSPlayback/SSExport), depends on 3. Accept: gain pair at midpoint is 0.707 each; sum of power constant across the fade.
7. **Transition edge drag and alignment** (M, EditorUI), depends on 3. Accept: pure geometry test: drag math clamps to handles and snaps to frames.
8. **Time Remapping model: speed keys** (L, SSCore). Piecewise speed track per clip, source time = integral, in rationals.
   Accept: two constant segments give exact source times at boundaries; clip duration follows; reversed segments allowed; project migration keeps constant-speed clips equal.
9. **Speed ramp UI (rubber band + split keys)** (L, EditorUI), depends on 8. Accept: geometry test for split key halves and ramp handles.
10. **Time interpolation: Frame Blend** (M, SSRender). Accept: at 50 % speed between frames A and B, output pixel = mix by fractional source position.
11. **Auto Bezier interpolation** (M, SSCore). Accept: moving a neighbour key recomputes handles; the curve through three keys has no overshoot beyond the key values.
12. **Continuous Bezier interpolation** (S, SSCore). Accept: editing one handle updates the other so tangents are collinear.
13. **Spatial interpolation default for Position** (M, SSCore). Accept: new position keys on a 3-key path produce a smooth tangent; Linear spatial choice zeroes tangents.
14. **Key menu parity entries** (S, EditorUI), depends on 11-12. Accept: menu spec lists Auto Bezier, Continuous Bezier in Premiere order.
15. **Gaussian Blur effect** (L, SSRender + SSCore). Parameter "Blurriness", animatable. Accept: radius 0 is identity; parameter round-trips; keys evaluate.
16. **Crop effect** (M). Edges left/right/top/bottom %, Accept: 100 % total width crops to empty; keys evaluate.
17. **Opacity blend modes** (L, SSRender). Accept: Multiply, Screen, Overlay, Add produce known pixel results on 2 test pixels.
18. **Timeline rubber band for Opacity / Volume** (L, EditorUI). Accept: hit-test and drag math maps y to value and back (dB and %).
19. **Cmd-click on rubber band adds a key** (S, EditorUI), depends on 18. Accept: one key at the clicked time with the current interpolated value.
20. **Second instance of an effect** (M, SSCore). Accept: two Rounded Corners on one clip evaluate in order; delete removes the selected one.
21. **Reorder effects by drag** (M), depends on 20. Accept: order change is one undo step and changes evaluation order.
22. **Paste Attributes** (M). Accept: Motion, Opacity, effects chosen in a dialog copy over; keys offset by clip start; one undo step.
23. **Volume Bypass and Channel Volume** (M, SSAudioFX). Accept: bypass gives unity gain at all times.
24. **Mirror, Transform, Ultra Key effects** (L each, order by value: Ultra Key for green screen). Accept per effect: identity at defaults.
25. **fx toggle for Motion / Opacity** (M). Accept: disabled Motion renders at default transform while values stay stored.
26. **Effect header Cut / Clear entries** (S). Accept: menu spec test.
27. **fx badge on clips with effects** (S, EditorUI). Accept: draw decision is a pure function of `clip.effects` and non-default Motion/Opacity.
28. **Time Interpolation picker in Speed/Duration** (S, UI), depends on 10. Accept: choice stored on clip and survives project round-trip.
29. **Dip to Black / Dip to White transition** (S), depends on 3. Accept: midpoint weight of the dip colour is 1.
30. **Transition double-click shows controls** (M), depends on 3. Accept: model exposes duration and alignment fields with undo.
31. **Preferences: default transition durations** (S), depends on 3. Accept: preference values round-trip, used by item 4.
32. **Optical Flow interpolation** (L, SSRender). Last: large and rarely needed for short-form.

Items 1-2 deliver the most for short-form editing with the least engine risk. Items 3-7 are the largest visible gap against Premiere (transitions).
Open questions for Paul: whether Auto/Continuous Bezier are wanted at all (items 11-14), and whether transitions should wait for the SQ rename to land.
