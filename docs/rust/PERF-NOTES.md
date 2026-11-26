# Playback performance notes (Rust app)

Measured with the headless engine benchmark (no window): the real Program engine (VideoToolbox decode, GPU compositor,
host clock), a loop paced at 60 Hz that does what the window does with each new composite, then a scrub of 120 requests
at 60 Hz, 2 frames apart, forward and back.

    target/release/sequence-studio <clip> --engine-bench <out.txt>

Clips (made with ffmpeg from TestMedia/stock/city-traffic.mp4, not committed; no S-Log3 camera file is in the test media,
so the 10-bit 4:2:2 file stands in for one: same codec family as XAVC S/S-I, same decode load):

- 1080p: `-c:v libx264 -crf 14 -pix_fmt yuv422p10le -g 25 -bf 2`, 1920x1080, 30 fps, h264 High 4:2:2 10-bit
- 4K: `-vf scale=3840:2160 -c:v libx264 -crf 18 -pix_fmt yuv420p -g 30 -bf 2`, 3840x2160, 30 fps, 8-bit 4:2:0

Mac (Apple Silicon, 2026-11-09, machine load 25-30 from other jobs, so treat small differences as noise):

| | 1080p 10-bit 4:2:2 before | after | 4K before | after |
|---|---|---|---|---|
| composites at 1x (6 s) | 180 (30.0/s), 0 dropped | 180, 0 dropped | 180 (30.0/s), 0 dropped | 180, 0 dropped |
| monitor take p50 / p95 / max | 6.17 / 7.30 / 7.97 ms | 0.88 / 1.89 / 5.88 ms | 14.14 / 14.62 / 28.65 ms | 1.47 / 3.74 / 10.84 ms |
| process CPU per picture | 7.61 ms (23 % core) | 3.83 ms (11 %) | 15.94 ms (48 %) | 3.94 ms (12 %) |
| scrub to exact frame p50 / p95 / max | 5.97 / 11.48 / 19.58 ms | 2.68 / 9.17 / 16.00 ms | 25.92 / 67.69 / 77.13 ms | 25.58 / 59.43 / 70.57 ms |

"before": every composite was read back to the CPU, mapped through the display gamma table on the CPU and uploaded
again. "after": a GPU copy (kept for scopes, eyedropper and snapshots, read back only when they ask) plus the
`DisplayGamma.slang` pass into a texture the window renderer samples directly. The pass looks up the same 256-entry table
(`sq-draw/src/display_gamma.rs`), so the picture is bit-identical (test `gpu_pass_equals_the_cpu_table`).

Picture gaps p95 ~51 ms in both runs: 30 fps content on a 60 Hz loop that is not phase-locked to the frame grid shows a
repeated tick now and then; the window gets a wake per composite (`on_shown`), so this is a benchmark-loop artifact
plus scheduling noise under load, not a decode limit. 4K scrub latency is bound by decode (VideoToolbox, long GOP).

## Scrub fill, display lead, frame phase lock (2026-11-09, machine load 55-65, so only large differences count)

- `engine/core.rs fill_step`: a resting playhead (paused, or between scrub steps) fills the cache 16 frames in the move
  direction and 8 against it, 8 frames per decode, one decode per tick, nothing past 3/4 of the cache budget; the want gate
  drops a fill the playhead left. `SQ_SCRUB_FILL=0` turns it off. Test: `a_resting_playhead_fills_the_cache_ahead_and_behind_so_a_scrub_back_hits_it`.
- `engine/display_pacing.rs` (Swift DisplayLead + FramePhaseLock): the window loop reports its frame ticks
  (`playback::display_timing()`), the engine picks the frame for clock + (refresh interval + frame callback time), changes it
  only at display ticks and keeps the changes midway between ticks. No present timestamps in winit: the lead is an estimate.
  `SQ_BENCH_NO_PACING=1` runs the benchmark without it.

| 60 Hz loop | 1080p before | after | 4K before | after |
|---|---|---|---|---|
| picture gap p95 | 50.5 ms | 36.1 ms | 50.0 ms | 35.7 ms |
| scrub forward leg p50 / p95 | 1.56 / 12.65 ms | 1.58 / 12.88 ms | 32.10 / 62.94 ms | 32.07 / 58.33 ms |
| scrub back leg p50 / p95 | 1.52 / 2.12 ms | 1.53 / 1.67 ms | 23.55 / 58.52 ms | 22.45 / 66.55 ms |

4K scrub stays decode-bound in this benchmark: the benchmark engine has a 1 GB cache (a 4K frame is 12 MB), so the
forward leg's pictures are evicted before the back leg returns; the app takes the cache size from `MemoryBudget`.

Open: PlayStart (clock start laid out on the display: the lead now ramps in over the first frames), the playhead reported to
the host is still the led frame (Swift keeps it on the clock), a real present-time source, decode-ahead tuned per GOP, a
Windows and Linux run.

## Mac decode: VideoToolbox vs software (2026-11-09)

The Mac opener (`DefaultOpener`, sq-playback media_source.rs) already tries sq-video-hw (direct VideoToolbox) first for H.264,
HEVC and ProRes 4:2:0 / 4:2:2 at 8 and 10 bit, full range included (xf20 / xf22 layouts); `supports_hardware_decode` in
sq-media-ffmpeg is only the D3D11VA rule. FFmpeg software runs when VT refuses a stream (the log line `videotoolbox: ... using
software`) or with `SQ_FORCE_SW_DECODE=1` (benchmark reference). `--engine-bench` now also prints cold seeks (24 jumps >= 40
frames apart). M-series Mac under load 30-50, 30 fps clips 40 Mb/s, GOP 30, 2 B-frames, full range, source city-traffic.mp4
(4K clips are upscaled 1080p). Process CPU per picture, VT / software, and cold seek p50 / p95 ms, VT / software:

| clip | CPU ms (% core) VT | CPU ms (% core) sw | cold seek VT | cold seek sw |
|---|---|---|---|---|
| H.264 1080p 8-bit 4:2:0 | 2.6 (8) | 10.7 (32) | 1.6 / 11 | 2.2 / 85 |
| H.264 1080p 10-bit 4:2:2 | 2.3 (7) | 14.6 (44) | 1.8 / 18 | 2.9 / 201 |
| H.264 4K 10-bit 4:2:2 | 3.4 (10) | 39.9 (120) | 37 / 68 | 300 / 508 |
| HEVC 1080p 8-bit 4:2:0 | 2.5 (7) | 30.7 (92) | 1.7 / 19 | 5.6 / 361 |
| HEVC 1080p 10-bit 4:2:2 | 2.9 (9) | 39.1 (117) | 6.4 / 22 | 2.7 / 307 |
| HEVC 4K 10-bit 4:2:0 | 2.8 (8) | 70.6 (212) | 30 / 45 | 389 / 684 |
| HEVC 4K 10-bit 4:2:2 | 2.9 (9) | 69.6 (226) | 34 / 56 | 884 / 1488 (3 missed > 2 s) |

All 12 clips (1080p / 4K x H.264 / HEVC x 8-bit 4:2:0, 10-bit 4:2:0, 10-bit 4:2:2) opened in hardware, none dropped a frame
in 6 s at 1x. Pixels: sq-video-hw oracle tests (`hevc_422_10_bit_full_range_frames_equal_ffmpeg`,
`hevc_422_10_bit_video_range_frames_equal_ffmpeg`, `h264_422_10_bit_full_range_frames_equal_ffmpeg`) are bit-exact against
FFmpeg's software p210le planes, stricter than the 2/255 budget.

## Present check: what the window gets while scrubbing and playing (2026-11-09)

`sequence-studio <clip> --present-check <out.txt>` (`present_check.rs`) drives the real engine and the window's picture path
(`playback::pump`, GPU display pass) offscreen: a 400-tick random-walk scrub at 60 Hz (steps 1-30 frames, 30 % direction
flips, a 20-tick hold every 50 ticks), then 1x, 2x and -1x play. Every new picture is read back from the texture the window
samples and compared with a ground truth of the clip's first 330 frames (FFmpeg software, one paused settled frame at a time,
same compositor and display pass): bit-identical (exact), close (reduced detail while moving, by design), a clean picture of
another frame (wrong; split by the picture's own `exact` flag), or no clean frame (unmatched: torn, mixed, garbage).
Test: `scrub_and_play_hand_the_window_only_the_frames_they_claim` (11 s 320x180 long-GOP clip, 60 ms decode delay so stand-ins
appear). Clips: city-traffic 640x360 h264 10-bit 4:2:2 GOP 15, and C2177.MP4 (Sony 4K h264 4:2:2 10-bit full range, the
first 12 s stream-copied).

| defect (scrub + play legs) | Windows sw before | after | Mac VT after |
|---|---|---|---|
| 640x360: wrong, claimed exact | 5 scrub + 29 reverse | 0 | 0 |
| C2177: wrong, claimed exact | 1 scrub | 0 | 0 (2 in 2x, within the classifier's noise, see below) |
| C2177: content backwards in play | 3 (2x) | 2 (2x) | 0 |
| unmatched | 0 | 0 | C2177: 6 scrub, 4 at 2x (see below) |

Root cause of the wrong frames: a stand-in (nearby cached frame) was composited under the wanted frame's plane-cache key
(`Source.index` = wanted index), so the exact picture that replaced it reused the stand-in's planes and claimed to be exact
(also on the Mac: a VideoToolbox frame is cached the same way). Fixed in `core.rs picture_for` (returns the key of the picture
it hands out). Playing stand-ins also fell back to the nearest frame either way (one ahead of the playhead) and could be older
than the picture on screen: `stand_in_index` now keeps the screen instead (`played_through`).

Open: on the Mac, VideoToolbox pictures are not bit-identical to FFmpeg's (mean 0.11 code values on the 32x18 grid), and the
C2177 frames differ from their neighbours by only ~0.6, so the classifier's "unmatched" there is not yet proof of torn
pictures; the next step is a ground truth from the hardware engine itself (bit-exact for full-detail pictures). Windows 4K
legs are decode-bound (FFmpeg software 4K 4:2:2 10-bit, many declared stand-ins) and the 4K readback of every picture makes
the loop late (71-270 ticks), so their skip/held counts are not pacing numbers.

### C2177 frame 118: stale references after a seek (2026-11-09)

Cause, found with `SQ_CHECK_DUMP=<dir>` (bad pictures and the settled frames around them as PNG, per-pixel diff) and a
checksum of every VideoToolbox output: the same frame decoded differently on different seeks, always in the GOPs of a
non-IDR I. C2177 alternates IDR and non-IDR I every 15 frames (open GOP, leading B-frames, `max_num_ref_frames` 2). A flush
(`finish`) only pushes pictures out; the session keeps its reference list, and a non-IDR I does not clear it, so after a
seek P80 was predicted from an earlier decode's P80 (same `frame_num`) instead of I77: macroblock garbage, claimed exact.
Second cause: after a fresh start at an open GOP's I, its leading B-frames (no references) were decoded and handed out, and
a later call could continue into them. Fixes: a seek whose first sample is no IDR/BLA picture opens a new session (p50 6 ms,
max 30 ms at 4K, 53 of 110 seeks); leading pictures of the session's start are not sent (as Swift) and never returned;
`plan::start` / `DecodePlan::start` continue only when every frame's references lie after the session's start (`origin`).
Reverse play asked for one frame per tick, which cost a GOP decode per frame: it now decodes the window from the sync
sample to the playhead once and plays it backwards from the cache, asking for the window before it 10 frames early.

| C2177, Mac VT, present check | before | after |
|---|---|---|
| frames decoded differently on different seeks | 84 of 335 | 0 of 335 |
| scrub unmatched (claimed exact) | 2-7 (1-2) | 0 |
| 2x unmatched / wrong claimed exact | 1 / 2 | 0 / 0 |
| -1x exact pictures | 0 of 62-86 | 41 of 43 (19 skipped, loaded Mac: 230 late loop ticks) |

Tests: `leading_pictures_after_a_start_at_their_gop_seek_back` (sq-video-hw), `seek_to_a_leading_picture_starts_one_gop_earlier`
(sq-media-ffmpeg), `idr_pictures_clear_references_non_idr_sync_samples_do_not`, `reverse_play_decodes_whole_gops_and_shows_exact_frames`.

## Many layers (perf-layers), 2026-11-16

A fixed test project, generated by code, for playback with many layers at once: 1080p30, 20 s, five picture layers
(bottom to top) and two sound tracks. `crates/sequence-studio/src/perf_project.rs` builds it (fixed ids and values, so every
machine gets the same project); `scripts/perf-media.sh` makes the pictures with ffmpeg (generated, with film-like noise,
never committed).

| track | content | heavy element |
|---|---|---|
| V1 | 4K30 HEVC 10-bit 4:2:0, 100 Mb/s, scale 0.5 | Blur (amount 40) |
| V2 | two 1080p30 H.264 clips (40 Mb/s), 70 % opacity | Blur (amount 12) on both, 2 s Cross Dissolve at 10 s |
| V3 | 1080p30 H.264 picture in picture, scale 0.35 | Drop Shadow (opacity 75, distance 24, softness 40) |
| V4 | 1080p30 H.264, scale 0.45, flies from side to side (a position key every 1.5 s, eased, never at rest) | Motion Blur (shutter angle 180) |
| V5 | title "PERF LAYERS 1080p30" | |
| A1, A2 | music (stereo AAC), voice (mono AAC) | |

The effect kinds are the catalog's (`gaussianBlur` "Blur", `dropShadow`, `crossDissolve`). Motion Blur is the Motion section's
shutter angle of the flying layer, not the temporal "Motion Blur" effect. Copies without one element sit beside the project:
`-no-blur`, `-no-shadow`, `-no-motion-blur`, `-no-dissolve`, `-no-4k` (V1 empty).

### How to run (Linux, Mac, Windows)

    cargo build --release -p sequence-studio
    scripts/perf-layers.sh target/release/sequence-studio <media folder> <out folder> [runs=3]

The script makes the media (`FFMPEG=<binary>` when ffmpeg with libx264 and libx265 is not on PATH), the project and its copies
(`sequence-studio --perf-project <out>/perf-layers.sqproj --media <folder>`: media paths are absolute, so run it on each machine),
plays the 20 s at 1x through `sequence-studio <project> --play-bench <result.txt> --size 1920x1080` with `SQ_BENCH_SECS=21`
(3 times per project) and prints the median of every number. Raw runs: `<out>/<name>.run<N>.txt`; stderr goes to
`<name>.run<N>.log` (with `SQ_PERF=1` set it holds the engine's per-second status and stage log). Without bash (Windows VM) run the same
commands by hand in PowerShell (`$env:SQ_BENCH_SECS = 21`) and read the `RESULT` line of each file; the media commands are in
`scripts/perf-media.sh`.

`--page color` (with `--play-bench`) draws the Color page UI (source tiles, scopes, wheels) during Play through the same page switch as `--ui-shot --page color`; the report gets a `page: color` line and the usual numbers (frames shown/expected, drops, gaps, UI frame time).

What `--play-bench` reports (one `RESULT` line for scripts): first picture after open, Play to the first new picture, frames
shown against expected and dropped (the engine's counters), the gaps between new frame positions on screen (p50, p95, max,
how many over 50 and 100 ms), late frames and the engine's per-stage times. A frame is late when a layer was still a
stand-in (nearby older picture) as the next frame replaced it, and `maxlag` is how many frames the stalest layer was behind:
the engine's dropped counter does not see either, and they decide whether the picture really plays smoothly. Since 2026-11-16
the engine counts them itself (`Status.late_frames`, `max_lag`, `first_late`; `engine/late_frames.rs`) and the `RESULT` line has
`late` = dropped + stand-in frames, the number the viewer sees (`stale` is the stand-in part). The report also says where it
happens: the first stand-in frames and the gaps over 50 ms in seconds on the timeline, and UI frames over 25 ms.
It does not measure the window's present or vsync, nor the GPU time of effects (`compose` is the CPU side: recording,
upload, submit, no wait for the GPU).

Linux runs are silent: the headless run gets a private `XDG_RUNTIME_DIR`, so no audio device opens ("No audio output", the host
clock drives playback) and nothing reaches the real speakers; the audio mix is not exercised. On the Mac the app opens the real
output unless `SQ_AUDIO_NULL=1` is set (no device is opened, the host clock drives playback, silent): set it for every offscreen
run, else the music and voice tracks play out loud. Linux decodes big pictures (3 Mpixel and up) on the GPU through VA-API and
the rest in software (FFmpeg, see "Fixes" below); Mac and Windows use VideoToolbox and D3D11VA, so their numbers will differ a lot.
`PERF_ONLY="full no-dissolve" scripts/perf-layers.sh ...` measures just those copies. Memory: the frame cache fills to its budget
(1/4 of RAM, at most 8 GB, `engine/memory_budget.rs`), so the app's RSS climbs by about 270 MB/s during this run; on a shared
machine run it under a memory cap and set `SQ_RAM_GB=16` (4 GB cache).

### Linux PC (RX 9070 XT, Ryzen 7 9700X, release build, other builds ran beside it: load 5 to 8), median of 3 runs

| project | frames shown of 600 | dropped | late frames | stalest layer behind | frame gap p50 / p95 / max (ms) |
|---|---|---|---|---|---|
| full | 598 | 1 | 482 | 33 frames | 33.3 / 35.0 / 66.7 |
| no Blur | 597 | 2 | 505 | 43 | 33.3 / 35.1 / 100.8 |
| no Drop Shadow | 598 | 1 | 504 | 46 | 33.3 / 35.0 / 66.3 |
| no Motion Blur | 598 | 1 | 512 | 42 | 33.3 / 35.0 / 67.1 |
| no Cross Dissolve | 599 | 0 | 519 | 45 | 33.3 / 35.1 / 40.0 |
| no 4K layer | 598 | 1 | 3 | 2 | 33.3 / 34.2 / 66.6 |

First picture 73 to 81 ms after open, Play to the first new picture 38 to 39 ms (all variants).

What it says:

- The picture does not play smoothly although only 1 of 600 frames counts as dropped: in 80 to 87 % of the frames the 4K
  layer is a stand-in, and it falls behind by up to 33 to 46 frames (1.1 to 1.5 s). Without the 4K layer there are 3 late frames
  and at most 2 frames of lag. The engine's counters hide this.
- Top cost: software decode of the 4K HEVC 10-bit clip. 34.1 ms per picture (budget 33.3 ms) on one lane, 556 pictures
  delivered in 21 s against 600 needed, while four 1080p H.264 lanes decode beside it (13.0 ms per picture each). Alone the
  4K file plays at the limit (`--engine-bench`: 29.8 of 30 fps, 0 dropped in 6 s, same machine), so any other decode work or
  load tips it over. Everything else is small next to it: download of a decoded picture 1.9 ms, compose 1.1 ms CPU (max 3 ms;
  it ran 2514 times for 600 frames, about 4 per displayed frame, following the 2436 decoded pictures that arrived), arrive 0.27 ms.
- Blur, Drop Shadow and Motion Blur change none of the numbers (drops, lag, gaps, compose time) beyond run-to-run noise on this
  GPU at 1080p; their GPU time is not separable with the current probes (needs GPU timestamps).
- The Cross Dissolve costs one dropped frame and a gap of 66 ms or more where it starts (9 s): every copy that has it shows
  that, `-no-dissolve` shows 0 dropped and a max gap of 40 ms.
- `SQ_PLAY_PROBE=1` (`sq-playback/src/probe.rs`) is a seek-latency probe (session, request, first frame, exact, glass); the
  per-stage play numbers come from the engine's `PlayStats` (`engine/stats.rs`), printed by `--play-bench` and by `SQ_PERF=1`.

Open: re-run on a quiet machine, then on the Mac (VideoToolbox) and in the Windows VM (D3D11VA). On Linux every decoder in
these runs is software (the engine log says `hevc (software)`, `h264 (software)`).

### Mac (MacBook Pro, Apple M1 Max, macOS 27.2.1, VideoToolbox, release build of rs/w47-mac), median of 3 runs, 2026-11-16

`SQ_AUDIO_NULL=1` (silent, host clock). The machine was not quiet: Spotlight indexed the new media folder and other jobs ran,
the load average went from 26 to 199 during the runs. Audio mix not exercised.

| project | frames shown of 600 | dropped | late frames | stalest layer behind | frame gap p50 / p95 / max (ms) | first picture after open (ms) |
|---|---|---|---|---|---|---|
| full | 599 | 0 | 0 | 0 | 33.3 / 34.5 / 40.1 | 209 |
| no Blur | 596 | 3 | 0 | 0 | 33.4 / 35.8 / 105.6 | 471 |
| no Drop Shadow | 598 | 1 | 2 | 2 | 33.3 / 35.3 / 75.7 | 187 |
| no Motion Blur | 599 | 0 | 0 | 0 | 33.3 / 39.2 / 54.7 | 219 |
| no Cross Dissolve | 599 | 0 | 0 | 0 | 33.3 / 39.3 / 95.5 | 228 |
| no 4K layer | 599 | 0 | 0 | 0 | 33.3 / 38.4 / 52.6 | 266 |

Play to the first new picture 38 to 39 ms (all variants). The first run of the full project (cold files) dropped 13 frames with
a 575 ms gap and 17 late frames (decode max 566 ms): the two warm runs dropped none (max gap 40 ms). Unlike Linux (software
decode, the 4K layer a stand-in in 80 to 87 % of the frames) the Mac plays all five layers with no late frames: VideoToolbox
decodes the 4K HEVC clip beside four 1080p lanes within the frame budget. The few drops and gaps over 50 ms in other copies
coincide with the load spikes, not with an element (the full project, with every element, is the cleanest median).
Open: the Windows VM (D3D11VA); a re-run on a quiet Mac.
### Fixes (w47-perf2, 2026-11-16): before and after on the Linux PC, median of 3, release build, other jobs on the machine (load 5 to 10)

Late frames, honest count (dropped + stand-in), whole project:

| step | late of 600 | dropped | stalest layer behind | frame gap max (ms) | 4K lane per picture |
|---|---|---|---|---|---|
| before: all software (`SQ_FORCE_SW_DECODE=1`) | 525 | 2 | 66 frames | 99.9 | 34 ms, one picture short of the clock |
| everything on VA-API | 516 | 1 | 74 | 91.7 | 36 ms (1080p H.264 lanes 25 ms: queued behind it) |
| 4K on VA-API, 1080p in software | 2 | 1 | 2 | 65.9 | 23 ms |
| + prefetch of the dissolve's first frame | 0 | 0 | 0 | 36.6 | 23 ms |

After, every copy of the project: full, no Blur, no Drop Shadow, no Motion Blur, no Cross Dissolve, no 4K layer: 599 shown, 0
dropped, 0 late, 0 behind, frame gap p50 33.3 / p95 34.3 to 35.3 / max 35.9 to 36.7 ms. Under a memory cap (`SQ_RAM_GB=16`) two
runs of three: 0 late; the third ran beside another job's 8-core test (load 13: 1080p software decode 25 ms instead of 12) and
was late in every frame, so a busy CPU still shows. Software 1080p lanes cost CPU, the GPU lane costs the one decode engine.

Causes:

- Software 4K HEVC 10-bit: one core, 34 ms a picture. VA-API (RX 9070 XT, the FFmpeg deps build has `vaapi`): 18 ms of the single
  decode engine plus 1.2 ms to copy the 25 MB out (`av_hwframe_transfer_data`; the 18 ms is the surface sync inside it).
  Isolated: 4K 44 fps against 32 in software, 1080p H.264 173 against 87 fps.
- All five lanes on the GPU is worse: the engine is shared, the 1080p lanes queue behind the 4K picture. `DEFAULT_MIN_HARDWARE_PIXELS`
  (`decode/hardware.rs`, `SQ_HW_MIN_PIXELS` overrides, 0 = everything on the GPU) sends only pictures of 3 Mpixel and more to the
  GPU on Linux; Windows keeps every stream on D3D11VA (not measured there).
- The hitch at the dissolve start (9.03 s: a 67 to 100 ms gap, one dropped frame, stand-ins at 9.2 to 9.5 s): the prefetch warmed an
  incoming clip's picture at its own start (`start = t - local_time`), but a centered dissolve shows the clip a second earlier, so its
  first frames decoded cold. `first_visible` (`engine/core.rs`) finds the first frame the clip shows by halving. Not the shader
  compile: a background warm-up of the transition pipeline changed nothing and was dropped.
- Hardware frames are bit-identical to software ones (max difference 0 of 166 M samples for H.264 8-bit video and full range and
  HEVC 8 and 10 bit; tests `hardware_*_frames_match_software`, which also compare the layout and range the planes are read as).
  The frames come out as NV12 / P010 like the software path's downloads, and `download_layout` (stream flags) is the one place that
  decides range and matrix.

GPU time per element: `sq-gpu` and `sq-render` have no timestamp queries (`wgpu::Features::TIMESTAMP_QUERY` is not requested), so
Blur, Drop Shadow and Motion Blur still cannot be timed on the GPU; with 0 late frames they change none of the numbers. Next step:
request the feature and write a timestamp pair around each pass of `GpuCompositor`.

Open: Windows numbers (commands for the VM are in the report of this change), an AV1 clip on VA-API (the hardware path now asks for
FFmpeg's native `av1` decoder instead of libdav1d, untested), and a 4K picture on a busy CPU is still the CPU's job in the 1080p
lanes.
