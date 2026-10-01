# SQPlayback + SQRender deep review (Job B)

Read-only review (Linux cannot build these packages: AppKit, Metal, AVFoundation). Nothing was compiled or run, so every
finding is by reading only. Verify on the Mac before fixing; each entry says how confident I am.

Read in full: every file under `Packages/SQPlayback/Sources` (render loop, decode scheduler, frame cache, prefetch planner,
clocks, audio engine / feeder / retimer / ring / scrub, playback engine) and `Packages/SQRender/Sources` (compositor and its
MSL, presenter, pixel formats, the whole `Color/` folder: CPU maths, MSL port, LUTs, resolver, scopes). Tests were only
grepped to see whether a case is covered. Line numbers are in the files named; paths relative to `Packages/SQPlayback/Sources/SQPlayback`
or `Packages/SQRender/Sources/SQRender`.

CPU-vs-Metal check of the colour chain: I compared every stage of `ColorStages.swift` / `ColorPipeline.swift` /
`TransferFunctions.swift` / `CubeLUT.swift` / `ScopesReference.swift` with `ColorShaderSource.swift` / `ScopeShaderSource.swift`
line by line (constants, flag bits, uniform packing, pass splitting, domain hand-over between passes, Swift vs MSL struct
layouts: `CompositeUniforms` 160 B, `Sec` 128 B, `ColorHeader`, scope uniforms). **No mismatch found.** Details at the end.

Status key: FIXED / NOT A BUG / OPEN / LEFT TO audio-shortform. Statuses were added on the overnight pass (branch worktree-agent-a3c7ae2a7f087dc3e) and refer to current main.

Severity: **H** = visible wrong result in normal use, **M** = wrong in a plausible situation, **L** = narrow or cosmetic.

## Playback

1. **M (high confidence) Nested sequences are never prefetched, and their frames are first in line to be evicted.**
   `Prefetch.swift:363` plans with `timeline.videoLayers(at: t)` without a `sequences` resolver, so clips of a nested
   sequence produce no layers and no jobs. `RenderLoop.swift:642-650` only adds the GOP of a *miss of the frame on screen*.
   `RenderLoop.mapping` (`:697-705`) filters `!$0.isNested`, so frames of media used inside a nested sequence map to `nil` =
   "unplaceable, evicted first" (`FrameCache.swift:285`, `:289-292`).
   Scenario: nested clip, 30 fps, 30-frame GOPs, normal play: every GOP boundary is a miss (drop), the GOP then decodes
   while the previous picture is held; frames of the next GOP are never decoded ahead. With the cache full the frames of
   the current GOP are the first victims. Fix: give `PrefetchPlanner.jobs` the `sequences` dictionary and call
   `videoLayers(at:sequences:)`; make `mapping` walk nested clips (inner media time -> inner timeline time -> outer time).
   Test (headless, `ManualClock`): nested clip over a 3 s GOP-1 s clip, play 2 s, expect no drops after the first GOP.
    **Status: FIXED. Verified on main: the planner resolved no nested clips (a miss of the visible frame was the only thing that pulled a GOP, added later) and `RenderLoop.mapping` skipped nested clips. `PrefetchPlanner.jobs(sequences:)` now plans inner clips, `RenderLoop.mapping(_:sequences:)` maps inner media time -> outer time through the nested clip. Tests: `NestedPlaybackPlanTests`.**

2. **M (medium) Audio watchdog can fire during normal priming and silently turn the audio off.**
   `AudioClock.swift:123` sets `progressNanos = restartNanos` at every restart, and `sample()` (`:54`) reports `stalled`
   after 250 ms without a consuming render call. While the output primes (`AudioEngine.swift:99,103`: silence, no
   `stamp`) nothing counts as progress. The feeder must first open the source (`AudioFeeder.swift:337`, `AVAsset` open on a
   cold or network file), mix and flush. A cold open over 250 ms makes `SwitchingClock.now()` (`AudioClock.swift:191-203`) switch to
   the host clock and set `audioFailed`: playback then runs silent with `audioUnavailable == true` until the next `play()`.
   Fix: do not count time before the flush was acknowledged (`s.base == nil`) against the watchdog, or give priming
   its own, longer timeout (e.g. 2 s).
    **Status: FIXED. Verified with `ManualAudio(autoFlush: false)`: 1 s of priming tripped the 250 ms watchdog. Before the first audio of a restart was consumed the limit is now 2 s (`AudioClock.primingTimeoutNanos`), afterwards 250 ms as before. Tests: `AudioClockReviewTests`.**

3. **M (medium, verify on device) Reverse play to the timeline start hangs ~250 ms, then falls back to the host clock.**
   The render loop stops reverse playback inside frame 0 only when `now < fd` (`RenderLoop.swift:383`, comment `:381`).
   But `AudioClock.position` subtracts output latency (`AudioClock.swift:149`), so after the feeder has played frame 0
   (`AudioFeeder.swift:269` stops producing) the clock rests at about `M/sr + outputLatency x |rate|`. At -1x with a
   built-in output that is ~10-20 ms (< fd at 30 fps, passes); at 60 fps, on Bluetooth, or at -2x/-4x (TimePitch adds ~64 ms,
   scaled by |rate|) it stays above `fd`. Audio is no longer consumed (`AudioEngine.swift:114` `guard n > 0`), so after 250 ms
   the watchdog switches clocks (`audioFailed = true`), the host clock runs negative and stops. Visible: a freeze at
   the first frames, and "audio unavailable" after every reverse run to the start. Fix: in reverse treat the audio clock as
   at the start once `feeder.position == 0` and the ring is drained, or clamp to zero in `AudioClock.position` for reverse.
    **Status: FIXED (clock side). Reproduced with 60 ms output latency: the reverse clock rested at 0.07 s (-1x) and 0.13 s (-2x), never inside frame 0. `AudioClock` now reports frame 0 once everything from the anchor down to the start was consumed. Tests: `reversePlayReachesTheStartDespiteOutputLatency`. A real-device check (Bluetooth, built-in) is still advisable.**

4. **M (high confidence) Relinking an *online* media to another file keeps showing/playing the old one.**
   `MediaTable.forgetOffline` (`RenderLoop.swift:64-66`) drops only offline and still entries; a `.ready` demuxer stays.
   `DecodeScheduler.decoders` (`DecodeScheduler.swift:27,98`) keeps the decoder per media UUID, the frame cache is keyed by
   (media UUID, pts), `AudioFeeder.sources` (`AudioFeeder.swift:139,337`) and the scrub mixer keep the source.
   `AudioFeeder.invalidateSources()` (`:363`) is never called anywhere in the repo, and nothing calls `FrameCache.removeAll()`.
   `ProjectMediaResolver.update` (SQEditorUI, `ProjectMediaResolver.swift:84-90`) does drop its own cache on a path change,
   so the engine is the only stale layer. Offline-to-online relink works (entry was offline); online-to-other-file does not
   until the app restarts. Fix: `PlaybackEngine.mediaChanged(_ ids: Set<UUID>)` that clears the `MediaTable` entry, the
   scheduler's decoder, cache keys of that media and the feeder/scrub sources.
    **Status: FIXED for video, OPEN for audio. `PlaybackEngine.mediaChanged(_:)` drops the demuxer, track info, damage marks, decoder (`DecodeScheduler.forget`) and every cached frame of the media; `EditorSession.syncMedia` calls it for media whose path changed (relink, undo of a relink). The audio feeder/scrub sources of that media are not refreshed (that is `AudioFeeder`, see 13): left to the audio-shortform stream. Tests: `mediaChangedReopensDecodesAndDropsOldFrames`, `DecoderLifetimeTests.forgetDropsTheDecoder`, `RelinkEngineTests`.**

5. **M (high confidence) `DecodeScheduler` never releases decoders.** `decoders[job.media] = decoder` (`:98`) is never removed
   and `executors` (`:30`, one dispatch queue per media) neither. Each decoder is a `VTVideoDecoder` (a VideoToolbox session,
   hardware sessions are limited). A long session that touches many clips keeps one session per media until the engine is
   deallocated. Fix: LRU of decoders (keep the media inside the prefetch window plus 2), `invalidate()` the others
   (`VideoDecoding` already has `invalidate()`).
    **Status: FIXED. `DecodeScheduler` keeps decoders of media the queue still wants plus the 2 most recently used idle ones and invalidates the rest (VideoToolbox sessions are released); the per-media dispatch queue goes with it. Tests: `decodersOfMediaOutsideTheWindowAreReleased`.**

6. **L (high) A decode failure inside the decoder discards the decoder.** `finished` (`DecodeScheduler.swift:100-104`) stores the
   decoder only on success, so after any thrown `decode` the next job (other GOP) creates a new `VTVideoDecoder`. Fine for
   corrupt media, wasteful for transient errors. Keep the decoder when the error is per-GOP.
    **Status: FIXED. `VTVideoDecoder` resets its own session state after a failed decode, so the scheduler keeps the decoder after a throw. Tests: `decoderSurvivesAFailedGOP`.**

7. **L (medium) Failed render is not retried until the next invalidation.** `RenderLoop.swift:427-429` sets `presented = false`
   on a throw (group texture allocation, encoder missing), but `:449` still records `renderedGeneration = generation` and
   `lastTime` stays; while paused at the same frame no tick renders again. Only an invalidation recovers. Fix: leave
   `renderedGeneration` untouched when `presented` is false.
    **Status: FIXED. A composite that was not presented no longer marks the generation as rendered; the next ticks retry, and a persistent failure gives up after 30 consecutive failures (`RenderLoop.maxRenderRetries`) so a paused loop does not spin. Tests: `failedCompositeIsRetriedOnTheNextTick`.**

8. **L (medium) Resolver can run on the render thread.** `layer(for:)` calls `media.demuxer(r.media)` (`RenderLoop.swift:558`)
   -> `MediaTable.entry` -> `resolver.demuxer` (`:24-34`) when the media was not resolved by a prefetch yet (e.g. a clip added
   by an edit, display link ticks before `prefetch(at:)` finishes on `resolveQueue`). The header comment says opening may
   block. Also two threads can resolve the same media at once (resolve outside the lock, `:27-30`), opening the asset twice.
   Fix: on the render thread use `resolvedDemuxer` and draw `.loading` until the prefetch resolved it.
    **Status: FIXED. Verified: `layer(for:)` and the tick's own prefetch both called the resolver on the render thread. The render thread now only reads resolved media (`MediaTable.known`); an unresolved media shows the held frame / loading placeholder while `resolveSoon` opens it on the resolve queue (ordered in the submit chain, so `waitForDecodes` covers it), then replans and redraws. Resolution is serialised per media (no double open). Tests: `resolverIsNeverCalledOnTheRenderThread`.**

9. **L (high) Quality change leaves a second copy of frames in the cache.** Keys include `scale` (`FrameCache.swift:129`) but
   eviction distance (`:279-285`) ignores it, so old-scale frames are as "near" as new ones and survive; after switching
   Full -> Half -> Full the cache can hold both until the budget is hit. Fix: give frames whose scale differs from the
   current one an infinite distance (nil) in `score`.
    **Status: FIXED. `FrameCache.setFocus(scale:)`: frames of another decode scale count as unplaceable and go first when the budget is full (they stay while there is room, so switching back is still free). Tests: `framesOfAnotherScaleAreEvictedFirst`.**

10. **L (high) `PlaybackEngine.scrub/step` call `isAudible` on every event** (`PlaybackEngine.swift:143,204` -> `:198`):
    `audioSegments(in: 0..<duration)` is O(all clips) on the main actor per mouse event. Cache the result per timeline
    version (it is already recomputed in `setTimeline` for `selectClock`).
    **Status: FIXED. `PlaybackEngine` computes `isAudible` once per `setTimeline`. Measured: the walk costs 4.6 ms on a 2000-clip timeline and ran on the main actor per scrub/step event (before); now a bool read (after).**

## Audio

11. **M (medium) Ring `pop` can play a few flushed frames after a flush that races it.** `RingBuffer.swift:85-94` loads
    `readIndex`, then `flushEpoch`, then `writeIndex`. If the producer calls `flush()` and pushes new data between the epoch
    load and the `writeIndex` load, the consumer reads from the old `rd` (frames the producer already freed, possibly already
    overwritten after a wrap) and plays up to one render quantum of stale audio in the new anchor (click / old sound). Window is
    microseconds, so rare; each seek during play is a chance. Fix: after loading `w`, re-load `flushEpoch`; if it changed, redo
    the epoch branch before reading.
    **Status: FIXED (small and local, `RingBuffer.swift`). Verified with a hook between the epoch and write-index loads: `pop` played the pre-flush frames instead of 9,8. `pop` now re-checks the epoch after loading the write index. Tests: `RingFlushRaceTests`.**

12. **L (medium) `ScrubVoice.render` throws away a valid pending grain after `cancel`.** `ScrubAudio.swift:209-214`: on the first
    render after a `cancel()` the voice unconditionally empties `pending`. A grain published for the *new* generation
    (user ends a scrub and starts the next within one render quantum, ~10 ms) is dropped. Fix: release `pending` only if
    `info[p].generation != gen` (that check already exists in `take`).
    **Status: FIXED (`ScrubAudio.swift`). A grain published for the new generation survives the first render after `cancel`. Tests: `ScrubVoiceCancelTests` (red before the fix).**

13. **L (high) `AudioFeeder.invalidateSources()` is not thread-safe** (`AudioFeeder.swift:363`) against the feeder thread that
    reads/writes `sources` (`:337`), and the doc comment lists only four callable-from-other-threads methods. Currently unused,
    which is bug 4. When wired up, route it through the generation mechanism (clear `sources` on the feeder thread at the next flush).
    **Status: LEFT TO audio-shortform (AudioFeeder). Still unused and not thread-safe; it is what a relink must call for audio (see 4).**

14. **L (high) A source that fails to open is retried on every block** (`AudioFeeder.swift:337-338`): ~47 times per second the
    feeder calls the resolver, which may do file I/O, for a missing file under the playhead. Negative-cache per media until
    `invalidateSources()`.
    **Status: LEFT TO audio-shortform (AudioFeeder).**

15. **L (medium) `AudioFeeder.stop()` then `start()` quickly can leave two feeder threads.** `stop()` (`:238`) only clears
    `running`; the old thread exits at its next loop test. If `start()` (`:225`) sets `running` again first (the engine does
    `shutdown()` then `prepare()` after a device change or tests), both threads run and the SPSC ring gets two producers.
    Fix: a per-start token compared in the loop.
    **Status: LEFT TO audio-shortform (AudioFeeder).**

16. **L (low) Audio and video are not compensated for display latency.** Video time is `gridTime(audioClock.now())` and the
    drawable is presented one vsync later; audio output latency is subtracted, display latency is not. Constant 16-33 ms
    video lag at most; measure with a flash/beep clip before changing.
    **Status: NOT CHANGED. Not provable by reading; needs a flash/beep measurement on a display.**

## Render / colour

17. **M (high confidence for the mechanism) Vignette on a rotated phone clip uses the wrong aspect.** `Compositor.swift:362-372`
    runs the colour chain into `mid` of the *unrotated buffer size*, and `ColorShaderSource.swift:377-378` derives `uv` and
    `aspect` from that texture; the quarter turn is applied later in the fragment shader (`CompositorShaderSource.swift:85-90`).
    For a 1920x1080 buffer with rotation 90 (portrait phone video) the vignette ellipse (`Roundness > 0`,
    `aspectMix`, `ColorStages.swift:251`) is stretched along the wrong axis; with roundness 0 (circle in normalised
    coordinates) the result is unaffected. Fix: pass an `upright aspect` and swap `uv` axes for odd quarter turns in the chain header.
    **Status: FIXED. `ColorPipelineGPU.encode(quarterTurned:)` (new header word, the MSL struct mirrors it): for 90/270 degree clips the vignette uses the shown picture's aspect and axes; the compositor passes the flag at both call sites (single layer and frame blend). Tests: `VignetteQuarterTurnTests` (GPU vs CPU reference on the upright picture).**

18. **M (high confidence this is not implemented; plan item) The viewer is not colour managed.** `PLAN.md:74` promises a
    ColorSync-managed Program monitor; `Presenter.swift:12-14` writes BT.709-encoded values into a BGRA8 drawable and no code
    in the repo sets `CAMetalLayer.colorspace` (`grep colorspace` finds nothing). On a Display P3 screen (every current Mac)
    Rec.709 primaries are shown as P3, i.e. over-saturated, and the 709 OETF (~gamma 1.96) is shown on a ~2.2 display.
    `ARCHITECTURE.md:210` and the Presenter comment say Phase 3 replaces this stage; I found no entry in `docs/DECISIONS.md`
    that defers it. Not a code bug, a gap between plan and code.
    Fix options: tag the layer `itur_709` (ColorSync converts, gamma stays "as decoded"), or convert to display P3 in the
    presenter shader; Paul judges which "looks like QuickTime".
    **Status: OPEN, decision for Paul. Confirmed: no `CAMetalLayer.colorspace` anywhere and still no entry in docs/DECISIONS.md. Not a code bug, and it changes how every pixel looks, so not touched. Recommendation: tag the layer `itur_709` (ColorSync converts primaries and TRC) and compare with QuickTime on the Display P3 screen.**

19. **L (medium) `LayerColorResolver` can flash another clip's grade.** `pipeline(for:media:)` on a cache miss returns
    `previous[media]` (`LayerColorResolver.swift:70`), the last pipeline built for that *media*, not for that clip colour. Two
    clips of the same media with different grades: after `cacheLimit` (256) clears all entries (`:135`; reachable by dragging a
    slider, each value is a new key) both clips draw with whichever was built last until their rebuilds land. Fix: key `previous`
    by `Key` minus the colour values, or by clip id; evict least-recently-used instead of `removeAll()`.
    **Status: FIXED. `pipeline(for:media:owner:)`: the fallback while a grade is rebuilt is the one last served for the same clip (`owner`, passed by the render loop), not for the media; a full cache drops the oldest quarter instead of everything. Tests: `LayerColorResolverReviewTests`.**

20. **L (high) Colour chain setup is rebuilt per layer per frame.** `ColorPipelineGPU.passes(for:)` (`ColorPipelineGPU.swift:104`)
    allocates sections and copies curve tables (up to 3 KB) every call, and `Compositor.prepareLayer` calls `encode` for each
    graded layer on every render. Cache the `[Pass]` inside `ColorPipeline` (it is a value type compiled once in `compile()`).
    **Status: FIXED. `ColorPipeline.gpuPasses` is built once in `compile()` (also when `ops`, `source` or `toneMapping` change). Measured on the heavy test chain: 16.5 us per graded layer per frame before, 0.12 us after.**

21. **L (medium) White-balance eyedropper ignores the pre-conversion gamut.** `WhiteBalanceSolver` solves with
    `PreparedBasic(..., gamut: .rec709)` on the working-linear sample, while for the first effect the real WB matrix is built
    in the *source* gamut (`ColorPipeline.compile`, `gamut = pre ? source.gamut : rec709`). For S-Log3/S-Gamut3.Cine and
    HLG clips the solved Temperature/Tint is slightly off (hue shift of the neutralised pick). Fine for Rec.709 clips.
    **Status: NOT A BUG. A white-balance matrix is an XYZ chromatic adaptation conjugated with the gamut, so applying it in the source gamut before the conversion equals applying it in Rec.709 after it (same D65 white). Test `whiteBalanceIsGamutIndependent` shows the matrices equal to 1e-4. No change.**

22. **L (low) Quality notes (not bugs).** Bilinear sampling without mipmaps means large downscales alias (4K clip at 25 %;
    exactly 2x is fine). Filtering happens on gamma-encoded values, not linear. Chroma siting is not applied (CbCr sampled
    at luma-centred coordinates). `CVMetalTextureCache` is never flushed (`Compositor.swift:141`); the default texture age
    should purge it, check memory in Instruments with many clips.
    **Status: NOT CHANGED (quality notes, not bugs). `CVMetalTextureCacheFlush` is not called in the playback compositor (the export frame source does); worth a memory check in Instruments with many clips.**

## Checked and found correct (so nobody re-reads them)

- `FrameCache`: budget never exceeded, candidate rejection, index kept sorted, `nearest` binary search, low-water
  eviction. `PrefetchPlanner`: window, priorities, dedupe by GOP, reverse.
- Clocks: `ManualClock`/`HostClock` are exact rational; re-anchor rounding is bounded (1 ns); `now()` cannot go backwards.
  `AudioClock` lock order (`state` -> feeder `flushState`) has no cycle; `SwitchingClock` ops serialisation holds.
- `AudioRetimer` is stateless per output sample (resample and Hann-grain OLA), grains clamp inside `[srcStart, srcEnd)`;
  the `precondition` on speed <= 100 matches `ClipSpeed.maximum`. `AudioFeeder` rational-to-frame helpers
  (`ceilFrame`, `roundFrame`) are right for negatives and ties; segment origin maths for forward/reversed retime matches
  `Timeline.audioSegments`.
- `RingBuffer`: SPSC index handling, fade/tail logic, seqlock acknowledgement. `AudioRenderCore` priming/stop-fade state machine.
- `ScrubGrainPlanner` / `ScrubVoice` slot accounting (4 slots: playing, tail, pending, being written).
- Colour: S-Log3 and BT.709 formulas and constants, HLG OETF/OOTF and its derived scale, Krystek white-point maths, Bradford,
  S-Gamut3.Cine / BT.2020 / 709 primaries, Fritsch-Carlson spline, curve and hue tables, `.cube` parser and 1D/3D tetrahedral
  lookup (CPU and MSL identical, 1D rows of 4096), LUT texture cache (identity by buffer address is safe because the entry
  keeps the array alive), pass splitting (sections <= 8, one LUT, curve tables <= 3 so `setBytes` stays below 4 KB, domain flag
  between passes), in-place `read_write` kernel, AutoTone composition of Exposure/Blacks, scopes binning and orientation
  (GPU = CPU reference), compositor uniforms layout, premultiplied blending, rotation direction, corner radius / edge AA,
  quarter-turn texture lookups, 10-bit MSB-aligned range maths, YCbCr matrices.

## Suggested order

1. Item 1 (nested playback), item 4 and 5 (stale media, decoder leak): user-visible in everyday editing.
2. Items 2 and 3 together (watchdog rules), then item 18 (colour management decision, Paul).
3. Item 17 and 11/12 are small, local fixes with a test each.

Tests that can be written without a GPU: planner with a nested timeline (item 1), `FrameCache` eviction with a nested
mapping and with two scales (items 1, 9), `AudioClock` + `ManualAudio` reverse to zero with output latency above one frame
(item 3), watchdog with a slow flush (`ManualAudio(autoFlush: false)`, item 2), `RingBuffer` flush race with a hook between
the epoch and write-index loads (item 11), `ScrubVoice` cancel-then-publish (item 12).
