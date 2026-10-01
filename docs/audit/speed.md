# Audit: clip speed (stream `speed`)

Before tonight: `Clip.timeline` duration was `source.duration`; `PlaybackRate` only drove the transport (J/K/L). No clip speed, no reverse.
"(community)" = standard Premiere behaviour, not verified against a running Premiere.

| Feature | Premiere | Sequence Studio now | Gap | Done tonight |
|---|---|---|---|---|
| Constant speed | Clip > Speed/Duration, 1 %...10000 % (community) | `Clip.speed` = exact ratio (`ClipSpeed`, clamp 1 %...10000 %), timeline length = `source.duration / speed`, frame-snapped | none | yes |
| Reverse | "Reverse Speed" checkbox, shown as -100 % | `Clip.reversed`; first frame shown = last source frame; typing a negative speed also reverses | none | yes |
| Speed/Duration dialog | Cmd+R, Clip menu, clip context menu; Speed, Duration, link, Reverse, Maintain Audio Pitch, Ripple Edit Shifting Trailing Clips | Same fields and places (Edit menu not needed) | none | yes |
| Link speed <-> duration | Link on: typing one changes the other. Off: speed typed keeps the length and changes the source range (community) | Same. Duration typed always changes the speed (the off-link duration case is a trim, not modelled) | small | partly |
| Ripple off | Clip grows only into free space, the rest is cut off (community) | Same: truncated at the next clip (shows less source) | none | yes |
| Ripple on | Trailing clips shift (community) | Shifts all unlocked sync-locked tracks like a ripple trim; shortening closes only as far as nothing collides | none | yes |
| Linked A/V | Both change together | Linked partners change together, one undo step | none | yes |
| Several clips selected | Speed applies to all | Speed applies to all (duration field disabled) | none | yes |
| Rate Stretch tool | R, drag an edge: speed changes, in/out stay | Tool R (Tools menu), edge snaps, grows only into free space, linked partners follow, one undo step | none | yes |
| Timeline badge | Clip name shows "[200%]" / "[-100%]" (community) | Same suffix on the clip name | none | yes |
| Trim / ripple / roll / slide / razor / lift / extract / paste on a retimed clip | Work in timeline time | Source range follows through speed and direction (exact rationals); split keeps the picture continuous; trim exposes more source at the clip's speed; slip moves source by frames x speed; keyframes stay in clip-timeline time | none | yes |
| Playback | Nearest frame, optical flow / frame blend options | Frame at the mapped source time (frame covering that time), no blending; GOP planner follows the mapped time, reversed clips decode a whole GOP at a time | blending, optical flow | no |
| Audio speed | Pitch kept by default | Time-stretch (overlap-add, pitch kept) or resample (pitch follows speed, "Maintain Audio Pitch" off); reversed audio plays reversed; same code for playback and export | WSOLA-grade quality | yes |
| Waveform on timeline | Follows speed | Mapped over the clip width (stretches with speed), mirrored when reversed | none | yes |
| Thumbnails | Follow speed | The timeline draws no clip thumbnails today | n/a | n/a |
| Speed ramps (time remapping) | Keyframed speed | not built | missing | no |
| Nested sequences, titles, stills | Nested can be retimed | Refused (`.speedUnsupported`, entry disabled in the context menu) | nested speed | no |
| Project file | | v14: `speed` {num, den}, `reversed`, `keepsPitch`; older files = 100 %, not reversed, pitch kept | none | yes |

## Numbers (1080x1920 H.264 30 fps, `ios26hier.mp4`, display-link engine, audio on, 5 s, M-series Mac)

| Case | Presented | Dropped |
|---|---|---|
| 100 % (control) | 146 | 0 |
| 200 % | 148 | 0 |
| 33.33 % | 150 | 0 |
| Reversed 100 % | 147 | 0 |
| Reversed 200 % | 144 | 0 |

Reverse costs no extra seek per frame: `PrefetchPlanner` maps timeline time to source time and decodes whole GOPs, so a reversed clip is the
same job list as forward play with the GOPs in descending order (a GOP is decoded once and its frames cached). 7 decode calls in 5 s at 2x,
3 at 1x. Bench: `SQ_REAL_MEDIA=1 swift test --filter SpeedRealMediaBenchTests` in `Packages/SSPlayback`.
