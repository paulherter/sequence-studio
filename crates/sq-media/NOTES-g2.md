# sq-media group g2 notes

## Ported
`media_error`, `codec_config`, `h264_annex_b`, `waveform_data`, `embedded_lut`, `web_mfile`, `demuxing`, `demuxer_handoff`,
`tone_audio_source`, `video_decoding`; `web_maudio_source` and `web_mdemuxer` only in part (below).

## Not ported (Apple frameworks; the Windows build of the Swift package leaves them out)
- `WebMAudioSource`: the packet table, runs and `AVAudioConverter` resampling; `OpusPacketDecoder` / `AACPacketDecoder`
  decoders. Ported from that file: `OpusPacketDecoder::samples_in`, `PCMPacketDecoder`, the AAC AudioSpecificConfig
  reader and `esds` writer, `WebMAudioSource::stereo`.
- `WebMDemuxer`: CoreMedia format descriptions, sample buffers, VideoToolbox registration, the pts/dts index build.
  Ported: `codec_name`, the AVC/HEVC ids. A Windows WebM demuxer (FFmpeg) needs the index build (dts from reordered
  presentation times) written against `SampleIndex` when that path is ported.
- Swift tests needing media or Apple code: `EmbeddedLUTTests.realClipEmbeddedLUT` (reads `~/Documents/Videos`, also
  needs `SonyMetadata`), `DemuxerHandoffTests` (needs `AVDemuxer`; replaced by tests on a fake `Demuxing`), the
  `WebMDemuxer`/`WebMAudioSource` round-trip tests (Matroska H.264, Opus alignment, AAC encode), `WaveformTests` that build
  a waveform from a generated clip (replaced by tests on a hand-built `WaveformData` with the same expectations).

## Decisions
- `async` trait methods return `BoxFuture` (`demuxing.rs`) so `dyn Demuxing` stays possible (needed by `DemuxerHandoff`).
  Cancellation (`Task.checkCancellation`) = dropping the future; `MediaError` has no cancelled case.
- `VideoDecoding.decode(_:deliver:)` / `(_:neededFrom:deliver:)` overloads are `decode_deliver` / `decode_needed_from`;
  the escaping `@Sendable` closure is `FrameSink = Box<dyn Fn(DecodedFrame) + Send + Sync>`.
- Frame index ranges (`ClosedRange<Int>`) are `RangeInclusive<usize>`; decode ordinals stay `i64` like `SampleIndex`.
- `DemuxerHandoff` takes `now: Timestamp` (no clock read) and holds `Arc<dyn Demuxing>`. Ownership: `ENTRIES`
  (static `Mutex<Vec<Entry>>`) owns the cache entries until taken, expired or dropped by capacity; shared-by: any thread
  calling `store`/`take`; the demuxer is shared with the caller through the `Arc` (demuxers are immutable after init).
  `ENABLED` is an `AtomicBool`. Paths are made absolute lexically (`standardizedFileURL` also resolves symlinks).
- `WebMFile` reads the whole file into memory (Swift memory-maps it); `WebMFile::open` caches the last 6 parsed files in a
  static `Mutex` (Arc-shared, immutable). `WebMFile::from_data` parses in-memory bytes (tests).
- `EmbeddedMeta` readers report I/O and corrupt-read errors as `MediaError::Unreadable` (Swift throws Cocoa/IO errors).
- `ToneAudioSource` adds `sq-core-audio` to Cargo.toml `[dependencies]` for `ToneSpec`.
- Test-only: the Matroska writer lives in `web_mfile::test_writer` (`pub(crate)`, `#[cfg(test)]`) for other modules' tests.

## Swift quirks (behavior kept unless noted)
- EBML parser: Swift traps (index out of range, `Int(UInt64)` overflow, `body + size` overflow) on hostile sizes; Rust
  reads missing bytes as 0, treats sizes above `Int64.max` as end of parsing, and saturates offsets. No crash, no new accept path
  for sane files.
- `EmbeddedMeta` box walk: Swift traps on `pos + size` overflow (64-bit box sizes); Rust stops the walk.
- `AACPacketDecoder`/`CodecConfig.avc`: `sps[4...]` traps if emulation prevention shrank the SPS below 4 bytes; Rust uses an empty slice.
- `WaveformData.serialized()` traps when a field exceeds 32 bits; Rust saturates. `channel_count` etc. are `usize` (Swift `Int`):
  a negative value in JSON is rejected where Swift would accept it.

## Waiting on
Nothing blocking. `sample_index` and `memory_audio_source` (g3) are used as ported on `rs/2b-m3`; this branch merged that
branch to compile (the merge commit is the only g3 content here).
