# Audit: colour panel (Lumetri-like) and stability

Stream `colour-stability`, 2026-10-01 night. Sources: `docs/PREMIERE-BEHAVIOR.md`, Adobe user guide mirror in
`docs/reference/adobe` (pages "Adjust color using RGB and Hue Saturation Curves", "Auto Color", "Color workflows" /
Basic Correction). "(unverified)" = not found in those pages.

## Part A: colour panel

| Feature | Premiere | Sequence Studio now | Gap | Done tonight? |
|---|---|---|---|---|
| Slider ranges | Temperature, Tint, Contrast, Highlights, Shadows, Whites, Blacks -100..100; Exposure -5..5; Saturation 0..200 (ranges and Vibrance -100..100 not stated in the mirrored pages: unverified, kept from the earlier decision) | Same; clamped in `ColorParam.write` | none | already right, tests cover every param |
| Double-click slider | Resets that slider | Resets (`LumetriSlider`, one undo step) | none | already right |
| Value box | Click to type, drag to scrub | Was type only. Now `ScrubField`: drag scrubs (Shift x10, Option x0.1), click types, arrows step; one gesture = one undo step | scrub missing | yes |
| Section checkbox | Bypasses the section | Switch per section, one undo step | none | already right |
| Reset | Per section / Tone Reset / per effect | Section Reset existed. New: Tone Reset (Light group) and per-effect Reset in the effect title row | tone + effect reset missing | yes |
| Auto (Basic) | Sets the tonal scale, minimises clipping; uses frame sampling over the clip | New Auto in the Light group: Exposure and Blacks from the Program frame as shown (`AutoTone`), added to current values | Whole-clip sampling, Whites/Contrast/Highlights/Shadows not driven (slider reach limits) | yes (current frame only) |
| White balance eyedropper | Click neutral area in Program monitor | Click in the Program monitor (asynchronous readback from the render loop, correct under zoom/pan): 5 x 5 mean of the composite; disabled with a tooltip when other layers are visible or the clip has several Colour effects, `WhiteBalanceSolver` sets Temperature and Tint, one undo step, crosshair cursor, click outside the picture cancels | Cmd = 10 x 10 sample; no Esc cancel | yes |
| Look thumbnail | Shows the look on the clip's frame | Shows the clip's frame at the playhead (composite already holds the look), updated 120 ms after the last change, not while playing; synthetic picture if the playhead is outside the clip | Thumbnails of the other looks in the popup | yes |
| Curves: RGB | Master/R/G/B; Cmd-click deletes a point; Shift locks x | Existed; Cmd-click delete and Shift x-lock added (double-click also deletes) | none | yes |
| Curves: Hue Saturation | Hue vs Sat, Hue vs Hue, Hue vs Luma, Luma vs Sat, Sat vs Sat; all sample the colour entering the section; eyedropper adds 3 points | New: all five, popup + editor in the Curves section, hue strip under the plot, wrap-around, CPU and Metal maths with parity test, project v14 | Eyedropper that adds 3 points; Lumetri's preset points | yes |
| Creative: Faded Film, Vibrance, Saturation, Tint wheels | Real maths | Already real (CPU and GPU, parity tests) | none | already right |
| Creative: Sharpen | Spatial sharpen | Disabled row, no maths. The colour chain is per pixel; Sharpen needs a neighbourhood pass in the compositor | Open | no (documented) |
| HSL Secondary | Key by H/S/L, correct the key | Disabled placeholder (toggle and body inactive) | Open | no (documented, only if time remained) |
| Scopes | Waveform, Parade, Vectorscope, Histogram | All four exist (GPU), update on playhead, project, media changes and every colour edit (`onChange` -> `scheduleRefresh`, coalesced 60 ms) | A refresh right after an edit can show the frame before the engine re-rendered (the engine renders asynchronously) | checked by reading, not changed |
| Copy / paste colour | Copy / Paste Attributes between clips | New "Copy Colour" / "Paste Colour" in the panel: pastes the Colour effects onto all selected picture clips as one undo step; the target keeps its footage interpretation; LUTs embedded in the other clip's media are dropped | The global Paste Attributes command (Cmd+Opt+V) is declared but not implemented anywhere: another stream's area | yes (panel) |
| Adjustment layers | Colour on an adjustment layer | No adjustment layers in the app | n/a | n/a |
| Colour order | Basic, Creative, RGB Curves, Hue Sat Curves, Wheels, HSL Secondary, Vignette | Same (Basic sliders before the Input LUT by Paul's rule) | none | verified |

File format: v14 (`ColorEffect.hueCurves`, encoded only when not flat). Migrations v10 -> v11 -> v12 -> v13 -> v14 tested.

## Part B: stability

| Item | Finding | Done |
|---|---|---|
| `redrawPerformance200Clips` | Single-sample median against a 4 ms budget that an idle run already hits at 3-4 ms | Best of up to 4 rounds, assertion 6 ms (1.5 x the target), rounds logged |
| `CaptionsPanelModelTests.rapidEditsCoalesce` (and the sibling) | Fixed 150 ms sleep around a 20 ms debounce; late timer under load left the transcript unchanged | Wait for the effect (poll, 5 s limit) |
| `AudioEngineTests.playsAtAllRatesWithoutUnderruns` | Real-time audio under machine load | Up to 3 attempts; every attempt must fail to fail the test |
| SQText hang in fontd under `scripts/test.sh` | Not reproducible here (passes). Probable cause: parallel CoreText font matching wedging in fontd | `scripts/test.sh`: SQText `--no-parallel`, per-package watchdog (900 s, `SQ_TEST_TIMEOUT`) that kills the process tree and retries once |
| Undo/redo symmetry | 17 session actions (delete, ripple delete, add edit, marks, trims, lift/extract, new sequence, nest, paste colour, replace clip) each exactly one step and redo restores exactly | `EdgeCaseTests`, no bug found |
| Edit fuzz | 40 seeds x 250 random edits (trim, roll, slip, slide, move, move-insert, ripple delete/trim, add edit, lift, extract) on a linked A/V timeline: invariants hold, refused edits change nothing | `TimelineFuzzTests`, no bug found |
| Playhead, empty timeline, 1-frame clips, clips at 0, audio-only / video-only, mixed frame rates, portrait sequence | Behave; cuts at edges or inside a 1-frame clip leave no undo step | `EdgeCaseTests` |
| Performance (headless EngineBench copy, release, M1 Max, load average 30-50 from other streams' builds, so everything is pessimistic) | 1080p HEVC (IMG_1281): seek to first frame 87 ms, play() to first new frame 23 ms, 10 s playback 0 dropped / 25 skipped grid frames (late pacer ticks under load), tick p50 3.5 ms. 4K Sony 4:2:2 10-bit (C2160): seek 371 ms, play start 41 ms, 10 s 0 dropped / 3 skipped, tick p50 2.0 ms. Scrub (20 cold random seeks): 1080p median 70 / p95 300 ms, 4K median 297 / p95 454 ms, same as the earlier acceptance run (69 and 266 ms) and equal to the standalone decode time, i.e. decode-bound | No regression, nothing changed |
