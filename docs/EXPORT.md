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
Slices 1-7 plus the follow-ups below are implemented in `Packages/SSExport` (53 tests).
- Tests export real 64x112 files (H.264, HEVC, ProRes software path / `hardwareEncoding = false` where applicable).
- `ExportWriter.export(video:audio:settings:to:progress:)` writes video + optional audio, interleaved; cancel = task cancel (partial file removed).
  Audio is fed non-blocking while video waits (and vice versa) and the audio input is finished as soon as its source ends;
  otherwise AVAssetWriter's interleaving deadlocks for longer clips.
- `ExportQueue` actor: `enqueue`, `runAll`, `cancel`, `status`, `updates()`. Unique names `Name.<ext>`, `Name 2.<ext>`, ...; extension from `ExportSettings.fileExtension` (mov for mastering codecs, else mp4).
- **Sidecar SRT** (`SRTWriter`, commit ca266dd): from SSTranscribe captions, rational timecodes, range offset/clip, CRLF, UTF-8; queue writes it next to the video (`ExportJobStatus.sidecarURL`).
- **Loudness normalisation** (`LoudnessNormalizer`, `NormalizedAudioSource`): `AudioSettings.loudness: LoudnessNormalization?` (default -14 LUFS / -1 dBTP, both editable).
  Pass 1 measures integrated LUFS + true peak (SSAudioFX `LoudnessMeter`), pass 2 applies one linear gain = target - measured, reduced so true peak <= ceiling.
  Needs a `RewindableAudioSource` (else `ExportError.loudnessNeedsRewindableSource`). Legacy `loudnessTarget` (Int) still decodes.
- **ProRes 422 HQ master** (`ExportSettings.proRes422HQMaster`): `VideoCodec.prores422HQ` ('apch', MOV, Rec.709 1-1-1, no bitrate/profile/keyframe props),
  `AudioCodec.pcm` with `pcmBitDepth` (24 default), 48 kHz stereo. Social presets stay H.264/HEVC only.
- Review-2 fixes X1-X4: audio-shorter-than-video test (timeout guarded); unique names case-insensitive (reserved lowercased) and reserve the `.srt` too;
  a sidecar failure keeps the finished video and sets `ExportJobStatus.sidecarError`; SRT cues are clamped to >= 0 before the empty check.
  `AudioSettings.loudnessTarget: Int?` is a computed, non-Codable compatibility view of `loudness` (used by SSEditorUI).
- Done (autopilot): `TimelineFrameSource` (compositor → Rec.709 BGRA/420v, injected `FrameProvider`) and `CaptionBurnIn`. Real sources (this commit): `DecoderFrameProvider` (VTVideoDecoder per media on a dedicated queue, forward decode without reseek), text generator layers and nested sequences in `TimelineFrameSource` (`RenderLayer.Content.linearPremultiplied`), `TimelineAudioSource` (AudioFeeder mix incl. per-track FX presets, 48 kHz stereo, rewindable so loudness normalisation works), `ExportSourceBuilder` (used by the shell's export jobs). Open: caption burn-in from project caption tracks (sidecar SRT is wired), per-track presets from the project (builder takes them, shell passes none yet), per-clip color pipeline in export, 10-bit/HDR output (settings only).
