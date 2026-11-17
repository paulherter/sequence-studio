# sq-core-time

Bottom layer of the Sequence Studio core (port of part of Swift `SQCore`). Only `sq-*` dependency: `sq-prproj-reader`
(raw deflate, re-exported by `raw_inflate`).

## Public API
- `Time { value, timescale }` (i64/i64, always reduced, i128 intermediates, never panics on overflow: results clamp
  or approximate like Swift) and `TimeRange` (half-open). `FrameRate::sequence_frame_duration`.
- `Id` (UUID, uppercase text like Swift `uuidString`), `IdSource` (logic never makes random ids), `SequentialIds` for tests.
- `Timestamp` (Swift `Date`: f64 seconds since 2001); `timestamp::iso8601` for files written with `.iso8601`.
- `Keyframe<V>`, `KeyframeTrack<V>`, `KeyframeValue` (`f64`, `Vec2`; the model adds more), `Interpolation`,
  `EaseHandle`, `EasingCurve`, `EasingLibrary`, `SpatialPath`.
- `EncodeContext`: thread-local scope the project file writer opens; keyframes write compactly inside it and
  version-relevant content is recorded (`Seen`).
- `text::{standard_compare, ci_contains, graphemes}`: Finder sort, case-insensitive search, Swift Characters.
- `cmx_timecode::CmxTimecode` (EDL timecode text <-> frames, drop frame), `step_status::line` (frame-step status text).
- `easing_spring`: `SpringEasing` (progress, preview, `baked_keys` with ids from an `IdSource`), `interpolated_time`,
  `EasingCurve::preview_samples`, `EasingLibrary::spring_presets`. `ease_names`: `ease_name::*` constants and
  `EasingCurve::display_name` (built-ins matched by id).
- `word_segmentation`: caption/karaoke words (CJK per character, marks attach), indices count Characters.
  `text_search::matches`: case/diacritic insensitive search with UTF-16 ranges (`NSRange` locations).
- `sha256_digest` (portable FIPS 180-4, one-shot and `Sha256` stream), `raw_inflate::{inflate, zlib}`,
  `portable_png::decode` (all color types, 1-16 bits, not interlaced, straight RGBA8).

## Tests
`cargo xtask check sq-core-time`. `tests/oracle.rs` replays `oracle/sq-core-time/golden` (Swift output) and prints
which ops are matched and which are not ported yet (only `ts_start`, `Timeline.timecodeStart`, belongs to the model).

## Parity notes
- All ported numeric ops match the golden bit for bit (Time, ranges, frame math, bezier, tracks, spatial paths).
- `standard_compare` matches all 300 golden pairs and `ci_contains` all 200 (en_US). They are small rule sets, not
  ICU: scripts and marks beyond Latin-1/Latin Extended-A may still order differently; canonical equivalence covers
  Latin-1 accents only (`decompose_latin1`). New golden rows decide.
- Graphemes use `unicode-segmentation` (extended clusters); all 140 golden counts match.
- ISO 8601 writes whole seconds (floor); not yet checked against Foundation's formatter for fractional dates.
- Spring ops (`exp`, `ln`, `cos`, `sin` from the platform libm) match the golden bit for bit on the Mac; another libm may
  differ in the last bits.
- `text_search::matches` is a small folding matcher, not ICU: Latin-1 accents, lowercase plus sharp s, whole Characters
  (a skin-tone emoji also ends a hit unless diacritic sensitive, as Foundation does). New golden rows decide.
- `interpolated_time` wraps instead of trapping beyond about 2^63 value*timescale products.
- Left out: Swift tests that need `Compression` (system deflate), `CaptionItem`/`TextUnits`/`Timeline` (other crates).
