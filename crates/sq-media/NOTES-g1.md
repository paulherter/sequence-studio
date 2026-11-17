# sq-media group g1 notes

## Ported (tests beside the code)
- `vorbis_decoder`: all of VorbisDecoder.swift. The IMDCT's DCT-IV (vDSP in Swift, unscaled) is a radix-2 FFT in f64.
  Differential test `decodes_like_the_swift_decoder` replays a synthetic stream (3 residue types, coupling, 4 modes) from
  `oracle/sq-media/golden/vorbis.tsv`; regenerate with `oracle/sq-media/run.sh` (plain swiftc, the real Swift file). Tolerance 1e-5 + 1e-4 relative.
- `mxfklv`: MxfUl, MxfKlv, MxfBytes, MxfBer, MxfFileReader. Names follow the Rust style (`MxfUl`, not `MXFUL`). `pread` is `FileExt::read_at` /
  `seek_read`, so no unsafe. Items Swift marks `internal` are `#[doc(hidden)] pub`.
- `peak_pyramid` (`ScalarPeakAccumulator`, `PeakPyramid`, new `PeakError` for the two error sources of `waveform_from`),
  `waveform_envelope` (inherent `impl WaveformData` plus `AudioGainPlanPeakExt` for `AudioGainPlan.peak(of:source:)`),
  `sony_metadata` (XML through `sq_prproj_reader::fastxml`: UTF-8 only), `color_tag_detection` (`detect` only),
  `media_file_ops` (all of it, see below).
- New dependencies in Cargo.toml: `sq-core-audio`, `sq-core-color`, `sq-prproj-reader` (all workspace paths).

## Not ported (Apple frameworks, outside the portable path; the Windows Swift build excludes them too)
- `MXFDemuxer.swift` (CoreMedia formats, CMSampleBuffer; also `MXFStill`), `WebMReadback.swift` (AVFoundation),
  `WebMStill.swift` (CoreImage), `SQMediaTestSupport/RLEMovWriter.swift` (AVFoundation). The modules stay empty skeletons.
  Pure helper inside WebMReadback: `frameIndices(in:range:)`; port it with the Windows frame reader if wanted.

## Waiting on
- `CameraMetadata.read(forClip:boxes:)` (canon_metadata.rs, g3) needs `SonyMetadata::sidecar_url`, `listing`, `embedded_boxes`
  (all pub here) and `CanonMetadata::from_maker_notes`/`from_xml`. `ColorTagDetection.detect(url:...)` (second overload) and its test
  `sidecarBesideTheClipIsRead` wait for that plus `EmbeddedMeta.lutHeader(inClip:)` (g2 embedded_lut.rs).
- Cross-group uses that compile only with the other groups merged: peak_pyramid -> media_error, memory_audio_source (AudioSource),
  waveform_data; sony_metadata -> canon_metadata (BOX_UUID, CameraMetadata::sidecar_data); color_tag_detection -> canon_metadata, codec_config.
- `MediaManagement.swift` (SQCore) is not ported in any crate (sq-core-model only has `ImportMode`). `media_file_ops` carries the three
  functions it calls (`is_inside`, `unique_name`, `collect_plan`, `CollectItem`) in a private `management` module; move them to
  sq-core-project with the rest of that file (`resolveStoredPath` is used by a MediaFileOps test and stays unported).
- Swift tests not ported: `realFiles` (Sony, needs the user's footage), vorbis/WebM tests that need `TestMedia` (no demuxer yet),
  `screenshotFromDesktopSurvivesDeletingTheOriginal` (`MediaRef.status`), `aStoredLUTPathResolvesAbsolute...` (MediaManagement),
  `aCanceledCopyLeavesNoTemporary` (no CancelToken).

## Deviations from Swift
- `MediaFileOps.trash` is the Windows branch (`Failure::NoTrash`); the Mac passes its own remover. Finder aliases are not told from files.
- `identity_key` / `same_file` on Unix use device and inode of an existing file (exact), the lowercased resolved path elsewhere.
- `is_inside` always compares case-insensitively (Swift asks the volume and falls back to this).
- `verified_copy` renames with a hard link first so an existing destination is never replaced (Swift `moveItem` fails the same way).
- `Task.checkCancellation` in `verified_copy` is not ported (no CancelToken yet). `remove_stale_temporaries` takes `now` and seconds.
- Vorbis: a stream with equal floor x positions divides by zero (Swift traps there too).
- `SonyMetadata::directory_listings` is global like Swift's; the folder-listing test serializes with a lock.
