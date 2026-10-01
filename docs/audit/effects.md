# Audit: Effect Controls, keyframes, Effects panel, speed (stream `effects`)

Sources: Adobe Premiere Pro user guide mirror (`docs/reference/adobe`, pages on keyframes, applying effects, animating effects),
`docs/PREMIERE-BEHAVIOR.md`. "(guide)" = confirmed there. "(community)" = standard Premiere behaviour that the guide does not spell out,
not verified against a running Premiere.

| Feature | Premiere | Sequence Studio now | Gap | Done tonight |
|---|---|---|---|---|
| Stopwatch on | Adds a key at the playhead (guide) | Same | none | already there, covered by tests |
| Stopwatch off | Confirmation, all keys deleted, value at playhead kept (guide) | Same (alert text names the property) | none | already there |
| Change value, stopwatch on | Adds / updates key at playhead (guide) | Same; with selected keys: relative edit | none | test added |
| Select keys | Click, Shift-click, marquee; click property name selects all its keys (guide) | Click, Shift-click, marquee, summary keys on collapsed rows | name click missing | click on property name selects all its keys |
| Move keys | Drag in time; replaces key it lands on (guide) | Same, frame-snapped, one undo step | Shift snap missing | Shift while dragging snaps to playhead, clip ends, other keys (community) |
| Duplicate keys | Option-drag (community) | none | missing | Option-drag leaves copies behind, one undo step |
| Delete keys | Delete, Edit > Clear (guide) | Delete / Forward Delete (selected keys first, else selected effect) | none | already there |
| Copy / paste keys | Cmd+C / Cmd+V at playhead, also to another compatible property (guide) | none | missing | Cmd+C, Cmd+X, Cmd+V at playhead; across clips; one copied property pastes onto the focused property of the same type; keys past the clip end are dropped; pasted keys become the selection |
| Key right-click menu | Temporal interpolation: Linear, Bezier, Auto/Continuous Bezier, Hold, Ease In, Ease Out; spatial; Copy/Paste/Delete (community) | Old easing preset list with side picker | wrong entries | Linear, Bezier, Ease In, Ease Out, Easy Ease, Hold, Saved Curves submenu (Fast Start/End, user curves, Save Curve), Copy, Paste (only if possible), Delete. Ease In / Ease Out change one side only. Auto / Continuous Bezier and spatial entries not offered: the model has no such modes |
| Glyph follows interpolation | Linear diamond, bezier / ease circle-ish, hold square (community) | Glyph read the left neighbour's interpolation, so Ease In next to a linear key stayed a diamond | bug | Glyph now reads the handles like the renderer does |
| Value scrub | Drag; Shift x10, Cmd (Mac) fine (community) | Shift x10, Option x0.1 | Cmd missing | Cmd = fine too |
| Type value | Click, type, Enter | Same | none | already there |
| Tab between fields | Tab moves to the next value field | none | missing | Tab / Shift-Tab commit and open the next field in reading order |
| Arrow nudge | none in Premiere; fine to have | Arrows step the focused field; Up/Down while typing | none | already there |
| Uniform Scale | Checkbox; Width / Height when off (guide) | Scale always uniform | missing | Checkbox row under Scale; off shows Width and Height; on makes both equal; opens unchecked for non-uniform clips |
| Reset per property / per effect | Circular arrow (guide) | Both, plus Reset All and reset at playhead | none | already there |
| fx toggle | Per effect, also Motion / Opacity | Per applied effect (Rounded Corners). Motion / Opacity / Volume have none | Motion / Opacity fx toggle missing | not done: renderer has no "disabled Motion" path, would be dead UI |
| Twirl state per clip kind | Remembered (community) | One global state | missing | Remembered per clip kind (video / audio), kept across launches |
| Effect search | Search field in Effects panel | none | missing | Search field, filters by name or bin |
| Effect bins | Video Effects, Audio Effects, Video Transitions, Audio Transitions | Flat list | missing | Bins as headings; only "Video Effects" is listed because nothing else exists |
| Apply effect | Drag onto clip; double-click applies to selected clips (guide) | Same | none | already there |
| Reorder effects in Effect Controls | Drag (guide) | n/a | Only one effect kind exists (Rounded Corners, one instance per clip), nothing to reorder. Fixed effects are fixed. | not done, revisit when a second effect exists |
| Delete selected effect | Delete / Backspace; fixed effects cannot be removed (guide) | Same | none | already there |
| Copy / paste effect | Select effect in Effect Controls, Cmd+C, paste onto clip (guide) | none | missing | Cmd+C / Cmd+X / Cmd+V on a selected effect header and "Copy" / "Paste" in its right-click menu; pastes onto the clip shown in Effect Controls |
| Paste Attributes / Remove Attributes | Edit > Paste Attributes (Cmd+Opt+V), clip menu Remove Attributes (guide) | Command listed in the Edit menu, not implemented | missing | not done: timeline-selection command, belongs with the timeline clipboard (stream timeline owns copy / paste of clips) |
| Video transitions (Cmd+D), audio crossfade (Cmd+Shift+D) | Drag onto cut, edge drag changes duration | **Engine has none.** No transition type in `SQCore.Model`, no overlap handling in `Evaluation`, no two-source blend in the compositor, no audio crossfade between clips. | whole feature | not done, not faked. Needed: a `Transition` value on the cut (kind, duration, alignment), evaluation of both clips' handles around the cut, a compositor pass blending two layers, an audio gain ramp pair, trim limits (handle media), timeline drawing |
| Clip Speed / Duration (Cmd+R) | Speed %, duration, reverse, ripple, maintain pitch | **No speed model.** `Clip.duration == source.duration`, `PlaybackRate` is transport only. | whole feature | not done. Needed: rational `speed` (sign = reverse) on `Clip`, timeline duration = source / speed, source time mapping in `Evaluation`, ripple in the edit logic, audio resampling with pitch preserve in `SQPlayback` / `SQExport`, thumbnails and waveforms scaled |
| Opacity blend mode | Dropdown under Opacity | Renderer has no blend modes | missing | not done (renderer) |
| Crop | Effect with edge values | Not in renderer | missing | Paul: later |

## Not verified
- Exact Option-drag and Shift-drag behaviour of keyframes in current Premiere (not in the guide).
- Which interpolation entries current Premiere shows for non-spatial properties (guide describes the methods, not the menu).
- Whether Cmd or Option is Premiere's fine-scrub modifier (both work here).

## Try this
See the final report.
