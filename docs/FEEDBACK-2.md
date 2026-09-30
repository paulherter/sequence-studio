# Paul's feedback, second app test (2026-10-01)

Praised: adding/dragging clips works well; keyframes work; "crazy how fast it already is".

## Media / picture
- M1 Still images (PNG/JPG…) can't be imported — support stills (default 5 s, like Premiere's still duration).
- M2 Portrait phone videos are imported as landscape (rotation metadata / preferredTransform ignored): must display upright everywhere (probe dimensions, decode/compositor, thumbnails, sequence format from first clip).
- M3 Stacked clips: where an upper clip doesn't cover the frame (letterbox/pillarbox of rotated/other-aspect clips) the area shows light grey instead of the clip below — letterbox areas must be transparent.
- M4 Resizing the Program monitor stretches the picture — always aspect-fit.

## Timeline
- T1 New sequences start with 4 video + 4 audio tracks.
- T2 Growing the timeline panel grows only V1/A1 → grow all tracks evenly (uniform heights), or keep heights and show more tracks.
- T3 Space doesn't start playback (regression); only the Play button works.

## Effect Controls / keyframes
- K1 Reset button per property and per effect (Premiere's reset arrow).
- K2 Keyframe area needs its own time ruler with timecode and a draggable playhead head (like Premiere).
- K3 Dragging a keyframe mostly horizontally must not change its value (axis lock unless clearly vertical); limit handle/influence drags like Premiere.
- K4 Opening a property graph shows a big empty area on the left — fit to the keys / clip range.
- K5 Speed graph is the default view (Value stays available).
- K6 Eased keyframes change their glyph (Premiere: linear diamond vs. bezier/ease hourglass shapes).
- K7 Rounded Corners appears on every clip by default — effects must only appear after the effect is applied (drag onto clip).
