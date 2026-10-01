# Audit: time remapping (stream `speed-time`, project file v23)

Adobe rows verified by grep in `docs/reference/adobe/duration-speed.txt` (text not copied). "verified" / "corrected" / "not verifiable".

| Feature | Premiere | Sequence Studio now | Gap | Adobe check |
|---|---|---|---|---|
| Show the band | Clip right-click > Show Clip Keyframes > Time Remapping > Speed | Clip menu / context menu "Show Time Remapping" (selected video clips) | menu path simplified | verified |
| Add key | Cmd-click on the rubber band | Cmd-click on the line | none | verified |
| Change speed of a part | drag rubber band up/down; Shift = 5 % steps; segment gets shorter/longer | same, log scale 1/16x..16x, tooltip "Speed 250%" | none | verified |
| Split key / transition | drag right half right or left half left; halves = beginning and end of transition | same (ramp segment between halves); drag a half moves it; drag the shaded span moves the transition | none | verified |
| Move unsplit key | Option-click and drag | Option-drag a key | none | verified |
| Ease curve | Bezier curve handles, linear or smooth | Linear ramp only; the centre handle widens/narrows the transition | ease curve | verified (gap) |
| Remove transition / key | select half, Delete | right-click key or transition > Delete Speed Keyframe / Remove Speed Transition | no Delete key | verified (differs) |
| Palindrome reverse (Cmd-drag key) | extra segment plays forward again | not built; reversed segments exist in the model and Reverse Speed flips a whole clip | gesture | verified (gap) |
| Audio on a remapped clip | stays linked but at 100 %, goes out of sync | audio FOLLOWS the remap (plan AC), pitch kept per Maintain Audio Pitch | deliberate difference | corrected |
| Lengthened clip meets the next clip | trimmed where the next clip begins | same (grows only into free space) | none | verified |
| Remove effect | cannot toggle; disabling deletes keys, clip length follows | Clip > Remove Time Remapping: 100 % over the source used | none | verified |
| Frame Blending | Frame Sampling / Frame Blending / Optical Flow in Speed/Duration, Clip menu, context menu | picker in Speed/Duration (video clips), stored per clip, preview + export | Optical Flow; Clip-menu/context entries | verified |
| Speed limits | 1 %..10000 % | unchanged `ClipSpeed` clamp | - | not verifiable (not in the text) |
| Effect keyframes on remap | not stated in the text | stay on their timeline frames; only a constant speed change scales them | - | not verifiable |
| Nested sequences | can be retimed | constant speed and speed track; video, audio and gain go through the clip mapping; inner length refreshed at edit time | nested Frame Blending | n/a |

## Model and formula
`Clip.speedKeys` (nil = constant, bit-identical to before). Segments `(duration, from, to, reversed)` from clip-local 0, plus `origin`.
Ramp: `D(tau) = a*tau + (b-a)*tau^2/(2T)`, whole span `T*(a+b)/2`; exact 128-bit rationals; the only rounding is `Rational.time`
(denominator above 2^20 rounds to 1/2^20 s). Frame rule: forward frame starts at `position(x)`, reversed at `position(x+fd)`.
`Clip.sourceTime` / `timelineTime(forSource:)` / `sourceInstant` branch on the keys; evaluation, planner, export, audio use them.
Audio: `AudioTimeMap` (Double, closed form, chain through nested clips) + `AudioRetimer.renderMapped`; constant clips keep the old path.
`Clip.source` of a keyed clip is the hull of the track. Slip is disabled on remapped clips. Project file v23 identity migration.

## Numbers (1080x1920 H.264 30 fps, `ios26hier.mp4`, display-link engine, audio on, 5 s)
| Case | Presented | Dropped | Decode calls |
|---|---|---|---|
| control 100 % | 19 | 0 | 3 |
| ramp 100 -> 400 % (14 s source in 5 s) | 17 | 0 | 7 |
| ramp 100 -> 25 % | 16 | 0 | 1 |

Presented counts are low in this session for every case including the control (display link under load), dropped is 0.
Bench: `SQ_REAL_MEDIA=1 swift test --filter SpeedRealMediaBenchTests` in `Packages/SQPlayback`.
