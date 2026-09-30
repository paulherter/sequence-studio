# SSProxy: optimized media and proxies

Pulled forward from "later": long-GOP Sony footage (XAVC S, 4 GB files) scrubs slowly.
Standalone package `Packages/SSProxy`, depends on SSCore only (not SSMedia). May import AVFoundation/VideoToolbox.

## Slices
a) Model: `ProxyKind`, `SourceFingerprint`, `ProxyRecord`.
b) `ProxyCache`: folder + atomic JSON index, `.partial` staging, evict/remove/size.
c) `ProxyTranscoder` (AVAssetReader/Writer, ProRes, color tags, audio, timecode, cancel).
d) `ProxyQueue` actor with injected transcoder protocol (fake in unit tests).
e) `ProxyProvider`: lookup API for playback + ready notifications.
f) Integration test on a 5 s cut of a real Sony clip (skipped if the file is missing).

## Decisions
- Kinds: `.optimized` = ProRes 422 (apcn) full res; `.proxyHalf` / `.proxyQuarter` = ProRes 422 Proxy (apco) at 1/2, 1/4 size. Scale is an integer divisor (1/2/4), no Double.
- Fingerprint = file size + mtime (ms) + SHA-256 of first and last 64 KB (whole file if <= 128 KB). Path independent: survives move/rename. A copy (new mtime) is a different source. Edits strictly in the middle of a file that keep size and mtime are not detected (accepted).
- Cache key = (fingerprint, kind). Files are named `<fingerprint-id>.<kind>.mov`; index stores relative names only.
- Output is always written to `<name>.mov.partial` and renamed when finished; stale partials are purged on demand (`purgePartials()`).
- Video: hardware decode via AVAssetReader (v210 4:2:2 10-bit buffers), scaled by the writer input, ProRes via AVAssetWriter. Color primaries/transfer/matrix are copied from the source format description to `AVVideoColorPropertiesKey` if the source carries all three. Sample timestamps are passed through unchanged (frame rate and VFR preserved); preferredTransform is kept.
- Audio: decoded to Linear PCM (16 bit for compressed/16 bit sources, else 24 bit), same channel count and rate, one output track per source track. Simplest lossless-enough path that keeps all channels; files are larger than AAC but PCM is what editors want for scrubbing.
- Timecode: a source `tmcd` track is copied and associated to the video track. If the source has none (Sony MP4 keeps timecode in the NRT XML sidecar / udta), nothing is written (gap; the caller owns sidecar timecode).
- Progress: `Double` fraction 0...1 (presentation fraction only, not timeline time). Queue exposes `AsyncStream<JobInfo>` per job and for the whole queue.
- Cancel: Task cancellation cancels reader and writer and deletes the partial file.

## SSPlayback integration (not implemented here)
1. On clip import/open, the app calls `queue.enqueue(source, .proxyHalf)` (user preference or auto for long-GOP).
2. Where SSPlayback builds its decoder for a source URL, it asks `provider.cachedLookup(for: url, preferring: [.optimized, .proxyHalf, .proxyQuarter])` (sync, stat-only, never reads file content) or the async `optimizedFile(...)` on first use. If a `ProxyLookup` is returned it decodes `lookup.url` instead; `lookup.scaleDivisor` tells the compositor how to keep effect coordinates in source pixel space (scale by divisor).
3. Sample times, timecode and color tags are identical to the source, so no time remapping is needed.
4. `provider.readyEvents()` fires when a proxy finishes; SSPlayback re-resolves affected sources and swaps the decoder at the next seek/stop (never mid-frame).
5. Export always uses the original source, never a proxy (provider is playback-only).

## Measured (C2160.MP4, 5 s cut from 0 s, 3840x2160 29.97p H.264, M-series Mac, hardware decode)
- optimized (apcn, 3840x2160): 1.25 s wall (~4x realtime), 318 MB for 5 s (~64 MB/s).
- proxyQuarter (apco, 960x540): 1.27 s wall (~4x realtime), 6 MB. Decode-bound: both take the same time.
- Frame count (150) and every presentation time identical to the source (<= 1 us). Audio 2 ch kept.
- Fixed on the way: the writer default media timescale (600) rounded 29.97 fps PTS; now `mediaTimeScale` = source track timescale.

## Not preserved / open
- Source file has NO color tags (S-Log3 lives in the Sony NRT XML, not the container). The ProRes encoder then tags the proxy BT.709 (primaries/transfer/matrix). Tagged sources are copied exactly (code path present, not exercised by the Sony file). Sony/log interpretation must therefore key on the ORIGINAL file, never on the proxy.
- Timecode: copy of a source tmcd track is implemented but untested (the Sony clip has none). No tmcd is synthesized from sidecar/udta timecode.
- Start offset inside a cut (`timeRange` start != 0) is only used by tests; timecode for such cuts is not rebased.
- Cache eviction policy (LRU, max size) is API only; nothing calls `evict` automatically.
