# sq-media group g3 (MXF file/metadata/audio, source timecode, Canon, sample index, VP9 header, AudioSource)

Ported: `mxffile`, `mxfmetadata`, `mxfaudio_source`, `source_timecode`, `canon_metadata`, `sample_index`, `vp9_header`,
`memory_audio_source` (holds the `AudioSource` trait), `sqmedia`.

Not ported (Apple frameworks, portable path is the reference): `test_clip_writer`, `frame_stamp`, `pngmov_writer`
(AVFoundation / CoreVideo / ImageIO). The modules stay empty skeletons.

## Seams
- `AudioSource` (memory_audio_source.rs): `read(&self, source_frame, buffer: &mut [f32], channel) -> Result<usize, MediaError>`,
  `buffer.len()` is the Swift `count`; `is_mono()` defaults to false; `Send + Sync`. Sq-media-ffmpeg and playback implement it.
- `Demuxing` / `VideoDecoding` are g2 files, not in this group.

## Waiting on (other groups; this code is written against their Swift names)
- g1 `mxfklv`: `MxfUl` (Copy, Hash, `hi`/`lo`, `new(&[u8])`, `byte`, `matches(&[u8], at)`, `partition_kind`, `is_*`, `track_number`,
  `metadata_set_kind`), `MxfKlv` (`key`, `offset`, `value_offset`, `length`, `end()`), `MxfBytes` (`new(Vec<u8>)`,
  `from_reader(Arc<MxfFileReader>)`, `detached(count)`, `count()`, `u8/u16/u32/u64/uint/position/ul`, `slice`, `with_bytes(range, |&[u8]|)`,
  `klv(offset)`, `fits(&klv)`), `MxfFileReader` (`open(&Path) -> Option`, public `size`, `modified`). Must be `Send + Sync`.
  While developing, local stand-ins with exactly this API were used (not committed).
- g1 `mxfdemuxer`: `Built` (the sample index a demuxer builds), stored in `Shared.built`.
- g2 `media_error`: `MediaError` (merged shape: `Unreadable`, `UnsupportedCodec(String)`, `DecodeFailed(i32)`, `Truncated`).
- g1 `sony_metadata` / `color_tag_detection`: `CameraMetadata::read(forClip:)` and the Canon "detection order" tests need
  `SonyMetadata` and `ColorDetection`; `CameraMetadata` here only has `MAX_SIDECAR_BYTES` and `sidecar_data`.
- Swift MXF tests that need `MXFDemuxer` (isIntraOnly, index counts, samples, broken index, temporal offsets, sample index built once)
  and the H.264 test stream writer are left to g1's demuxer port. The fixture (`mxffile::fixture`) is the Swift `MXFFixture`
  with opaque picture payloads instead of tiny H.264 streams.

## Deviations and decisions
- `MXFAudioSource.open` is `async` in Swift without awaiting; the Rust `open` is synchronous.
- `streamAll` throws `CancellationError`; Rust returns `StreamAllError::{Cancelled, Body(E)}`.
- The MXF parse cache is one global `static Mutex<Vec<(key, MxfFile)>>` (Swift: `Mutex` static). `Shared` is an `Arc` of two mutexes
  (sample index built by a demuxer, build counter); both live as long as the last file or cached parse.
- Canon sidecar XML: a small scanner in `canon_metadata.rs` (documented `shortcut:`) stands in for `XMLParser`; it skips comments,
  CDATA, processing instructions and DOCTYPE, decodes the five entities and numeric references, and rejects unbalanced tags.
- MXF integer fields keep Swift `Int` as `i64` for descriptor values and `usize` for offsets; `SampleIndex` ordinals are `i64`.
- `SourceTimecode::read` returns `io::Result<Option<_>>` (Foundation file errors).
- Color tags of `MxfPictureDescriptor` return the CoreMedia constant strings as `&'static str`.
- `SampleIndex::gop` returns `usize::MAX..=0` (empty) where Swift would trap on an impossible range.
