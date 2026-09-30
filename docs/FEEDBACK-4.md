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
