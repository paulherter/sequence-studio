# Paul's feedback, fourth app test (2026-10-01) — TO DO next (not started)

Timeline dragging works well. Most problems are in Effect Controls / keyframes.

## Effect Controls / keyframes
1. Eased-keyframe glyphs are tiny and too fine — make them bigger/bolder (Premiere size).
2. Expanding a property shows the keyframes twice (lane + graph). Premiere shows each key once, with the curve attached — merge lane and graph into one view when expanded.
3. The keyframe time ruler/playhead must be at the TOP of the keyframe area (like the timeline ruler), not at the bottom.
4. Zoom in/out in the keyframe area (like the timeline: pinch, +/-, zoom slider) so small segments/handles are reachable.
5. Speed-graph handles: dragging left/right must stay horizontal (axis-locked); vertical movement only when clearly intended (bounce). Must feel intuitive.
6. After dragging a keyframe to another time, it must NOT stay selected; changing a value at the playhead then creates a new key there (instead of editing the moved key).
7. Reset on an animated property: offer resetting the value at the playhead (create/replace key with default) instead of only "delete all keys"; keep "reset all" as a separate option.
8. The expanded graph view is cluttered (too many numbers; left column nearly empty except Value/Speed). Clean it up (Premiere-like: few labels, clear curve).

## Timeline / playback
9. During playback the timeline must not force-follow the playhead: the user can scroll anywhere (Premiere: page-scroll only when the playhead leaves the view, and manual scroll wins).
10. Jumping the playhead far away shows a brief black frame before the picture — keep the last frame until the new one is decoded.

## Tools / monitor
11. Type tool (T): click in the Program monitor to add text there (generator text clip), edit in place.
12. Direct manipulation in the Program monitor: with Motion selected, drag to move, handles to scale, rotate — values update in Effect Controls (TransformOverlayView exists, needs wiring).

Pending tests by Paul: new colour panel (blocks, Input LUT, wheels).

## Additions after colour test (screenshots of Premiere in docs/reference/premiere/, local only)
Colour works better now, but the panel is still confusing for a Premiere user ("all over the place", hard to see what does what).
13. Colour panel layout like Premiere's Lumetri panel (14–16.webp): ONE effect "Colour" with collapsible sections in one column, each with a toggle switch on the right: Basic Correction (Input LUT popup at its top, Intensity; subgroup "Colour": WB eyedropper, Temperature slider with blue→orange track, Tint green→magenta, Saturation; subgroup "Light": Exposure, Contrast, Highlights, Shadows, Whites, Blacks), Creative (Look popup with preview thumbnail + prev/next arrows, Intensity; Adjustments: Faded Film, Sharpen, Vibrance, Saturation, Shadow/Highlight tint wheels, Tint Balance), Curves (RGB curves with channel dots, Hue vs Sat / Hue vs Hue …), Colour Wheels & Match, HSL Secondary, Vignette. Values right-aligned in blue, editable by typing; everything in one clean row layout. Paul mainly uses Basic Correction + Creative.
   OPEN: processing order — Paul wants correction before the LUT, but Premiere puts the Input LUT at the top of Basic Correction. Decide with Paul before building (e.g. Input LUT row at top but applied after the Basic Correction sliders, or an explicit toggle).
14. Keyframe editing must feel like Premiere (17–22.webp): changing a value on a keyframe just updates the number and curve — no mode change or "selection" feeling while dragging. Premiere layout: ruler + clip bar at the top of the keyframe area; keys appear once in the property row; expanding a property shows value graph + velocity graph directly under that row; zoom scrollbar with round handles at the bottom; current timecode bottom-left; per-row reset; ◀ ◆ ▶ keyframe navigation next to the value; eased keys = clear hourglass glyph; collapsed effects show summary dots.
15. Hand tool (H) also works in the Program monitor: pan the picture; trackpad scroll/pinch to pan/zoom the monitor (Premiere).
16. Bug: dragging the playhead over a clip's name strip erases the name; it comes back only after another redraw (dirty-rect/overdraw issue in TimelineView/ClipDrawing).
17. Snapping with Shift while dragging the playhead: in the timeline it sticks to clip edges/edit points (and shows the snap), in the keyframe area it sticks to keyframes (Premiere).
Goal restated by Paul: not identical to Premiere, but better — nicer UI, above all a faster workflow; adopt Premiere's smart details.
18. Scrubbing the playhead in Effect Controls while playing must stop playback, exactly like the timeline ruler.
19. Effect Controls split: the divider between the left (properties) and right (keyframes) area shows even with no clip selected — hide it (empty state) then; when a clip is selected the divider must be draggable (min/max widths, persisted), like Premiere.
20. Q / W (ripple trim to playhead): after Q the playhead moves with the content so it stays on the same picture — it lands on the new edit point (Premiere). General rule for ripple edits at the playhead.
21. Selection outline of clips: white instead of yellow.
22. Transcribe doesn't work yet (known, needs wiring + test).
23. Program monitor: show the anchor point of the selected clip (Motion selected / clicked), draggable; smart guides — invisible snap lines (canvas centre, edges, other layers) like Photoshop/Premiere/After Effects.
24. Audio meter panel is missing: a (dockable) meter panel right of the timeline by default; tools column stays left of the timeline (compare 23.webp).
25. Header space is far too tall: our title bar + toolbar eat vertical space. Make it compact like Premiere (23.webp: one slim bar with Import/Edit/Export and workspace name) — save space everywhere.
26. Text clips can be added but render nothing in the Program monitor → wire TextGenerator into playback (and export). In Effect Controls, Motion and Opacity sections come before the Text section.
27. Tool column order (Paul's Premiere setup): Selection, Razor, Slip (move clip content), Pen, Shape (rectangle/ellipse/polygon — long-press menu), Mask tools, Hand, Type. NOTE: Pen/Shape/Mask were non-goals for V1 (DECISIONS) — Paul now wants them; treat as scope addition (later), reorder the existing tools now and leave slots.
