# Export core (SSExport)

Scope: `Packages/SSExport` only. Sources: PLAN.md (Export, Rec.709 1-1-1), docs/UX.md §4.6, docs/DESIGN.md screens 4a–4c.
UI, renderer and sheet are out of scope; the real renderer plugs in later via `FrameSource`.

## Slices (tests first, each one commit)
1. **Settings model** (`ExportSettings`, `VideoSettings`, `ColorSettings`, `AudioSettings`, `CaptionMode`, `RangeSelection`):
   Codable value types. Video: codec (h264/hevc), size, frame duration (`Time`), profile, bitrate mode (avg/max), keyframe interval, hardware encoding.
   Color: output Rec.709, tag 1-1-1 (primaries/transfer/matrix). Audio: AAC, sample rate, channels, bitrate, loudness target (−14 LUFS, optional; model only).
   Captions: none / burnIn / sidecarSRT (model only). Validation (even dimensions, bitrate > 0) and size estimate.
2. **Social presets** (`ExportPreset`): TikTok, Reels, Shorts × H.264/HEVC, 1080×1920, 30 fps default, bitrates, 1-1-1. Default = 9:16 H.264.
3. **Frame protocol** (`FrameSource`): `frameCount`/`frameDuration`, `func frame(at index: Int) async throws -> CVPixelBuffer`;
   `AudioSource` (PCM chunks). `TestPatternSource` generates colour bars + frame counter for tests.
4. **Writer pipeline** (`ExportWriter`): AVAssetWriter, video input + pixel buffer adaptor, correct colour tags in compression
   properties (`AVVideoColorPropertiesKey`: ITU_R_709_2 ×3) and on pixel buffers (attachments), progress + cancellation.
5. **Colour tag readback test**: export test pattern, read back via AVAssetTrack format description extensions
   (primaries, transfer, YCbCr matrix), assert 1-1-1, for H.264 and HEVC.
6. **Audio AAC**: AAC track from an `AudioSource`, test reads format ID/sample rate/channels back.
7. **Batch queue** (`ExportQueue` actor): jobs for several sequences (id, name, settings, sources), sequential run, states
   waiting/running/done/failed/cancelled, progress stream, cancel, unique output file names per sequence.

## Status
All 7 slices implemented in `Packages/SSExport` (28 tests). Slices 2+3 share one commit.
- Tests export real 64x112 files (H.264 and HEVC both encode at that size, software path, `hardwareEncoding = false`).
- SSPlayback/SSRender dependencies kept (they compile); nothing from them is used yet.
- `ExportWriter.export(video:audio:settings:to:progress:)` writes video + optional AAC, interleaved; cancel = task cancel (partial file removed).
- `ExportQueue` actor: `enqueue`, `runAll`, `cancel`, `status`, `updates()` stream. Unique names: `Name.mp4`, `Name 2.mp4`, ... (checks disk + reserved names).
- Open: renderer `FrameSource` adapter, sidecar SRT / burn-in (model only), loudness normalisation (model only), 10-bit/HDR output.
