# SQProxy: optimized media and proxies

Pulled forward from "later": long-GOP Sony footage (XAVC S, 4 GB files) scrubs slowly.
Standalone package `Packages/SQProxy`, depends on SQCore only (not SQMedia). May import AVFoundation/VideoToolbox.

## Slices
a) Model: `ProxyKind`, `SourceFingerprint`, `ProxyRecord`.
b) `ProxyCache`: folder + atomic JSON index, `.partial` staging, evict/remove/size.
c) `ProxyTranscoder` (AVAssetReader/Writer, ProRes, color tags, audio, cancel).
d) `ProxyQueue` actor with injected transcoder protocol (fake in unit tests).
e) `ProxyProvider`: lookup API for playback + ready notifications.
f) Integration test on a 5 s cut of a real Sony clip (skipped if the file is missing).

## Color rule (binding for SQPlayback / SQMedia)
**Color interpretation ALWAYS comes from the ORIGINAL source file** (container tags and the Sony NRT XML sidecar,
i.e. S-Log3). A proxy inherits the source's interpretation. The proxy's own BT.709 tag is an encoder default
(the Sony file carries no tags) and MUST be ignored: never read primaries/transfer/matrix from a proxy file to
interpret it. `ProxyLookup.colorInterpretation` is always `.fromSource` as a reminder; no code in SQProxy reads a
proxy's tags.

## Decisions
- Kinds: `.optimized` = ProRes 422 (apcn) full res; `.proxyHalf` / `.proxyQuarter` = ProRes 422 Proxy (apco) at 1/2, 1/4 size. Scale is an integer divisor (1/2/4), no Double.
- Fingerprint = file size + mtime (ms) + SHA-256 of first and last 64 KB (whole file if <= 128 KB). Path independent: survives move/rename. A copy (new mtime) is a different source. Edits strictly in the middle of a file that keep size and mtime are not detected (accepted).
- Cache key = (fingerprint, kind). Files are named `<fingerprint-id>.<kind>.mov`; index stores relative names only.
- Output is always written to `<name>.mov.partial` and renamed when finished; stale partials are purged on demand (`purgePartials()`).
- Video: hardware decode via AVAssetReader (v210 4:2:2 10-bit buffers), scaled by the writer input, ProRes via AVAssetWriter. Color primaries/transfer/matrix are copied from the source format description to `AVVideoColorPropertiesKey` if the source carries all three. Sample timestamps are passed through unchanged (frame rate and VFR preserved); preferredTransform is kept.
- Audio: decoded to Linear PCM (16 bit for compressed/16 bit sources, else 24 bit), same channel count and rate, one output track per source track. Simplest lossless-enough path that keeps all channels; files are larger than AAC but PCM is what editors want for scrubbing.
- No timecode track: proxies carry none. Timecode (container or Sony sidecar) comes from the original source, like color.
- Progress: `Double` fraction 0...1 (presentation fraction only, not timeline time). Queue exposes `AsyncStream<JobInfo>` per job and for the whole queue.
- Cancel: Task cancellation cancels reader and writer and deletes the partial file.

## Auto-generation policy
- `ProxyPolicy.decide(SourceSeekInfo)`: intra-only codecs (ProRes, DNxHD/HR, MJPEG, Cineform, ...) never get a proxy;
  otherwise a proxy when the largest distance between sync samples exceeds `maxSyncDistance` (default 8 frames).
  Unknown GOP: no proxy. Auto kind = `.proxyHalf` (ProRes 422 Proxy, half res).
- Input is the injectable `SourceSeekProbing` protocol; `AVSourceSeekProber` walks an `AVSampleCursor` over the first 600
  samples (sample table only, no media data read, ~ms).
- `ProxyAutoGenerator.sourceImported(url)` evaluates the policy and enqueues with `.background` priority
  (transcode Task runs at `.background`, pump queues at matching QoS). Probe failure = no proxy.
- Measured on C2160.MP4: avc1, max sync distance 30 -> needs proxy; its proxy (apco, distance 1) -> skipped (intra).
- Queue job priority: `.background` (auto) < `.utility` (default, manual) < `.userInitiated`; higher starts first.

## SQPlayback integration (not implemented here)
Intended use: proxies are for **scrubbing** (playhead drag: instant intra-frame access). Playback and paused frames
use the original.
1. On import the app calls `ProxyAutoGenerator.sourceImported(url)`; manual "Generate proxy" calls `queue.enqueue`.
   Call `queue.start()` once at launch (purges partials, enforces the cache cap).
2. `await provider.warm(url)` once per source, then when building a decoder call
   `provider.file(for: url, context: .scrubbing / .playback / .paused, settings: cache.settings)` (sync, stat-only).
   - `.scrubbing`: proxy if ready (half, quarter, then optimized), else nil (original).
   - `.playback`: proxy only if `settings.useProxiesForPlayback` (manual toggle, like Premiere, for slower Macs).
   - `.paused`: always nil: exact frames come from the original, even with the toggle on.
   `lookup.scaleDivisor` tells the compositor how to keep effect coordinates in source pixel space.
3. Sample times are identical to the source, no time remapping. Color/timecode: see the color rule above.
4. `provider.readyEvents()` fires when a proxy finishes; SQPlayback re-resolves affected sources and swaps the
   decoder at the next seek/stop (never mid-frame).
5. Export always uses the original source (provider is playback-only).

## Cache cap
- `ProxySettings.cacheCapBytes` (default 50 GB) and `useProxiesForPlayback`, persisted in `settings.json` in the
  cache folder (`cache.settings`, `cache.updateSettings {}`).
- LRU: `lastAccess` is refreshed on every successful lookup (in memory; persisted with the next index write or
  `cache.flushIndex()`, call on app quit). `enforceCap(protecting:)` evicts least-recently-used until under the cap.
- Runs automatically after each finished job (the just-finished proxy is protected, so a single proxy larger than the
  cap stays) and in `queue.start()`.

## Measured (C2160.MP4, 5 s cut from 0 s, 3840x2160 29.97p H.264, M-series Mac, hardware decode)
- optimized (apcn, 3840x2160): 1.25 s wall (~4x realtime), 318 MB for 5 s (~64 MB/s).
- proxyQuarter (apco, 960x540): 1.27 s wall (~4x realtime), 6 MB. Decode-bound: both take the same time.
- Frame count (150) and every presentation time identical to the source (<= 1 us). Audio 2 ch kept.
- Fixed on the way: the writer default media timescale (600) rounded 29.97 fps PTS; now `mediaTimeScale` = source track timescale.

## Not preserved / open
- Source file has NO color tags (S-Log3 lives in the Sony NRT XML). The ProRes encoder tags the proxy BT.709: ignore it (color rule).
- Tagged sources: their tags are copied to the proxy (code path present, not exercised by the Sony file); still never used for interpretation.
- Start offset inside a cut (`timeRange` start != 0) is only used by tests, on `ProxyTranscoding.transcode` directly. `ProxyQueue.enqueue` has no `timeRange` (REVIEW-2 P1): the cache key is (fingerprint, kind), so a partial proxy would be served for the whole file. Proxies are always whole-file; a ranged queue API would need the range in the key.
- Files in use by a decoder are not tracked; only LRU order and the just-finished proxy protect against eviction. If a
  decoder holds an evicted file open, macOS keeps the inode alive until it closes.
