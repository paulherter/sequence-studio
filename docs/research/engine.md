# Research: how open-source editors solve the engine problems

Job F, topic `engine`. Method: shallow clones of the repos (read from the code, not only docs), checked 2026-10-01.
Nothing here is recorded in THIRD_PARTY.md. Our architecture reference: `docs/ARCHITECTURE.md`.
Caveat: this was read on Linux, nothing was built or run. Numbers quoted are defaults found in code, not measurements.

## Licence map (GPL-3.0-compatible check)

| Project | Licence (from COPYING / file headers) | Borrow code? |
|---|---|---|
| Olive (olive-editor/olive) | GPL-3.0-or-later | Yes (ideas and code, with attribution) |
| Kdenlive (KDE/kdenlive) | GPL-3.0 (COPYING; verify per file, KDE uses GPL-2+/3 mixes) | Yes, check each file header |
| Shotcut (mltframework/shotcut) | GPL-3.0 | Yes |
| MLT (mltframework/mlt) | Core LGPL-2.1+; `plusgpl`, `xine`, `rubberband` etc. GPL | Yes (LGPL-2.1+ is GPL-3 compatible) |
| libopenshot | LGPL-3.0 (the OpenShot app itself is GPL-3) | Yes |
| OpenTimelineIO | Apache-2.0 | Yes (Apache-2.0 is GPL-3 compatible) |
| Rubber Band library | GPL-2.0-or-later (commercial option) | Link/ideas only; we use Apple's AVAudioUnitTimePitch today. Verify before any dependency |

All of these are C++/Qt/FFmpeg: no Swift code is reusable as is. What we borrow is design, constants and algorithms, ported by hand.

## 1. Playback caching

**Olive** (`app/render/`): `PreviewAutoCacher` renders frames of the *sequence* (post-effects) in the background around the playhead
into a disk cache; `FrameHashCache` stores one file per frame keyed by a hash of the node graph at that time, so unchanged frames
survive edits; `PlaybackCache` keeps `validated_` / invalidated `TimeRangeList`s and only invalidates ranges touched by an edit.
`DiskManager` / `DiskCacheFolder` enforce a size limit and evict by last access (`Accessed()`, `CreatedFile()`). Config keys
`DiskCacheBehind` (default 0 s) and `DiskCacheAhead` set the window around the playhead.
**libopenshot**: `CacheMemory` is a byte-limited map plus an `ordered_frame_numbers` vector; `CleanUp()` drops the oldest numbers
when over `max_bytes`. Simple, and O(n) per op.
**MLT**: `mlt_cache` is a tiny LRU (default 4 items per cache line, max 200) for decoded objects; not a frame cache.

Compare ours: `FrameCache` keyed by media + source PTS (ARCHITECTURE.md §1), which is the better design for raw decoded frames:
edits never invalidate. Olive's idea only applies to a *composite* (render) cache for heavy effect frames.

Adopt:
- A byte-budgeted LRU for `FrameCache` that evicts by distance from playhead first, then recency (Olive/openshot evict by age only,
  which throws away frames just ahead of the playhead). SSPlayback, S–M.
- Range-based validity (`TimeRangeList`) for a future composite cache: invalidate only the edited range plus affected transitions.
  SSPlayback + SSCore (range set type, pure value type, testable on Linux), M.
- Cache key = hash of (clip graph + effect params + source PTS + output size) so undo restores the cache for free (Olive). M, later.
Borrow: Olive `app/render/diskmanager.cpp`, `playbackcache.cpp`, `framehashcache.cpp` (GPL-3.0-or-later).

## 2. Proxy / optimised media

**Shotcut** `src/proxymanager.cpp`: proxy = H.264 (`libx264 -preset veryfast -crf 23`) or hardware encoders, scale
`scale=width=-2:height=<resolution>`, **all-intra via `-g 1`** (GOP 1; `-g 2` for NVENC H.264, `-g 0` for NVENC HEVC), yadif when the
source is interlaced, full-range flag preserved, metadata copied back. Proxy lives in the project folder or a global folder; the
swap is at load time: the producer's `resource` is replaced by the proxy and the original path kept in a property, restored on save.
Images are proxied via `QImageJob` to a fixed size.
**Kdenlive** `src/jobs/proxytask.cpp`: proxy parameters are a per-document property (`proxyparams`, `proxyresize`, width substituted
for `%width`); audio is kept from the original (`-map 0:v -map 1:a -c:v copy` pass for external proxies); alpha sources get a VP9/VP8
profile; auto-proxy by clip size threshold; a task manager runs jobs with progress.

Compare ours: `SSProxy` already exists (`ProxyPolicy`, `ProxyQueue`, `ProxyTranscoder`, `ProxyCache`).
Adopt/verify:
- All-intra proxies (GOP 1) are what make scrubbing and reverse play cheap; check that our VideoToolbox proxy settings use
  intra-only (ProRes Proxy or HEVC/H.264 with keyframe interval 1). Reading `ProxyTranscoder.swift` for this is a 15-minute task. S.
- Keep the **original path as the identity** and swap the *decoder source* only, never the model (Shotcut restores on save). Confirms
  our "proxy is not in the project file" direction. Check DECISIONS.md. S.
- Take audio from the original, not the proxy (Kdenlive), so proxies never change loudness/sync. S.
- Interlaced and full-range handling flags. S.
Borrow: constants and filter strings from Shotcut `proxymanager.cpp` (GPL-3.0) as reference only; the ffmpeg commands do not port to AVFoundation.

## 3. Waveforms and thumbnails

**Olive**: `AudioWaveformCache` + `AudioVisualWaveform` store a multi-resolution min/max summary (mip levels) and `Draw()` picks the level
by `scale` (pixels per second), so zoom is cheap and the cost of drawing is O(pixels), not O(samples). Partial ranges drawn as they
are decoded (`DrawSubRect`).
**libopenshot** `AudioWaveformer`: extracts at a fixed `num_per_second`, stores `max_samples` / `min` per bucket, optional
normalisation, and applies clip volume/time keyframes on top of the *source* summary, so the cache is not invalidated by volume edits.
**Kdenlive** `jobs/audiolevels`: per-stream `QVector<int16_t>` levels, saved to a cache file keyed by the clip, reported progressively
via `progressCallback`; `jobs/cachetask.cpp` + `utils/thumbnailcache` store thumbnails keyed `(binId, position)` with a `persistent`
flag (volatile = memory only).

Adopt:
- Mip-level min/max peak file per audio stream (e.g. 1 pair per 256 samples, then x4 levels), computed once at import in the
  background, memory-mapped, drawn level-by-level. Pure maths: put the builder in SSCore or SSMedia (no AVFoundation needed for the
  reduction), unit tests on Linux. M.
- Apply gain/fades at draw time, never in the cache (libopenshot). S.
- Thumbnail key = (media id, source PTS rounded to a fixed grid), persistent on disk, LRU in memory; timeline asks for the nearest
  grid frame (Kdenlive). SSMedia + SSEditorUI, M.
Borrow: Olive `audiowaveformcache.cpp` / `audiovisualwaveform.cpp` (GPL-3.0-or-later) for the mip-level layout.

## 4. Render cache (effects / export)

Olive's approach (§1) is the only one with a persistent composite cache; Kdenlive has "timeline preview" (renders chunks of the timeline
to disk, invalidated per chunk when an edit touches it). Chunk-based invalidation is simpler than per-frame hashing and what we should
copy first. Adopt only when effects make real-time playback impossible; Phase 2 engine measures should decide. SSPlayback, L. Not now.

## 5. Pitch-preserving time-stretch

**MLT**: `producer_timewarp.c` changes the producer speed and, when `warp_pitch` is set, inserts the `rbpitch` filter
(`modules/rubberband/filter_rbpitch.cpp`) which compensates with Rubber Band: real-time mode (`OptionProcessRealTime`), engine
"finer", pitch scale clamped to 0.05–50, high-quality pitch + crisp transients for scales 0.5–2.0, and high-consistency + smooth
transients outside that range (to avoid memory blowup). The speed is applied by resampling, the pitch is corrected by the filter.
Compare ours: ARCHITECTURE.md routes audio through `AVAudioUnitTimePitch`, which is Apple's own stretcher.
Adopt:
- The same split: do speed by changing the read rate, correct pitch with a separate stage, bypass it when speed == 1.0 or pitch
  preservation is off. SSPlayback, S (design already matches).
- Quality tiers by speed range as Rubber Band does: crisp/transient-friendly in 0.5–2x, smooth outside; for us: choose
  `AVAudioUnitTimePitch.overlap` accordingly and test with speech at 0.25x/4x. S.
- Reverse and below-0.25x: mute or use grain repeat; MLT clamps. S.
Rubber Band itself (GPL-2.0+, C++) would be a dependency, not borrowed code; only worth it if Apple's unit sounds bad on speech at
2x. Decide after a listening test by Paul.

## 6. Transitions and compositing order

**MLT**: the timeline is a `multitrack` inside a `tractor`; tracks are layered bottom (index 0) to top, each upper track composited
over the result of those below by a `composite` / `qtblend` transition (`transition_composite.c`, 1230 lines: geometry, alpha, luma
wipes, per-frame rect interpolation) and audio by `mix` (`transition_mix.c`, with `start`/`end` gain ramp and `mixdown`).
A clip-to-clip transition is a transition service placed on the overlap of two clips *on the same track* (Kdenlive adds a hidden
second playlist or "mix" entries); the overlap region is real media from both clips.
**OpenTimelineIO**: `Stack` iterates bottom to top, upper images overlay lower ones; `Track` holds Clips, Gaps and `Transition`s
with `in_offset` / `out_offset` (the transition straddles the cut: part before, part after the cut point), `RationalTime` is
`value` + `rate` (stored as double, so not as strict as our rational Time).
Compare ours: `Timeline.videoLayers(at:)` (ARCHITECTURE.md §2) already gives bottom-to-top; matches.
Adopt:
- Model a cross-dissolve as `in_offset`/`out_offset` around the cut (OTIO) so it needs handle media on both sides; define the
  behaviour when handles are missing (clamp and show warning, like Premiere). SSCore, M. Tests on Linux.
- Audio crossfade uses equal-power by default for dissolves, linear option (`mix` start/end ramps). SSAudioFX, S.
- Composite in linear half-float (we already do), apply transition progress as a pure function `(a, b, t) -> pixel`, so effects can
  be tested without Metal. SSRender, S.
- OTIO import/export for interchange (Kdenlive has `src/otio`): Apache-2.0 lets us read the schema; a reader/writer in SSCore that does
  JSON only, no dependency. M. Useful for Resolve/FCP handoff.
Borrow: OTIO schema docs and `src/opentimelineio/transition.cpp` semantics (Apache-2.0). Nothing from MLT composite needed (CPU code).

## Ranked adoption list (most value for the current phase first)

| # | Item | Package | Effort | Source |
|---|---|---|---|---|
| 1 | Verify proxies are all-intra; take audio from original | SSProxy | S | Shotcut, Kdenlive |
| 2 | Playhead-distance + byte-budget eviction in `FrameCache` | SSPlayback | S–M | Olive, libopenshot (what not to do) |
| 3 | Mip-level audio peak file, gain applied at draw time | SSMedia / SSCore | M | Olive, libopenshot |
| 4 | Persistent thumbnail cache on a PTS grid | SSMedia, SSEditorUI | M | Kdenlive |
| 5 | Transition model with in/out offsets and handle clamping | SSCore | M | OTIO |
| 6 | Time-stretch quality tiers by speed, listening test | SSPlayback | S | MLT rbpitch |
| 7 | OTIO JSON import/export | SSCore | M | OTIO |
| 8 | Chunked timeline render cache (invalidate per range) | SSPlayback | L | Kdenlive preview, Olive |

## Open questions for Paul
- Is Rubber Band worth a GPL dependency if Apple's time-pitch is audibly worse on speech? (needs ears, not numbers)
- Do we want OTIO interchange before or after Phase 8 export work?
