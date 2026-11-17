# oracle/sq-core-time

Golden outputs of the frozen Swift code for the Rust crate `sq-core-time` (docs/rust/ORACLE.md, split row `time`).
- `golden/ops.tsv`: ~10,000 seeded ops (Time, FrameRate, CMX timecode, easing/spring, ease names, word segmentation, text search) plus fixed edge tables. One TAB separated record per line: `op inputs... -> outputs...`; the header comments define every column and the LCG (`state = state * 6364136223846793005 + 1442695040888963407`, wrapping; Rust must replay it exactly). Doubles are IEEE bits (`f64` as 16 hex digits) plus a looser `%.17g` column.
- `golden/text-tables.tsv`: `standard_compare` (300 pairs), `ci_contains` (200), `graphemes` (140); the header names the Swift API behind each column.
- Regenerate (default seed 20261105, count 10000): `oracle/sq-core-time/run.sh [seed] [count]`. Plain `swiftc` from Xcode 27.1 (`DEVELOPER_DIR` is set by the script if that Xcode exists); the real SQCore sources are compiled with `swift-dump/main.swift` and `stubs.swift`. No SwiftPM.
- Not compiled whole: `TextSearch.swift` (the `Timeline` extension is cut off by awk) and `SequenceTimecode.swift` (the `timecodeStart` clamp is copied into the dumper as `timecodeStartClamp`).
- Limits found in Swift (traps) and avoided in the dump: `SpringEasing.interpolatedTime` overflows Int128 for |value| near 2^63 (dump stays within 2^40 / timescale 2^31); `CMXTimecode.string` overflows for frame counts near Int64.max (dump skips above 10^12).
- Lines with `skip` as output are inputs the dumper did not run (would trap or the generator made an overflowing multiple).
- Goldens are recorded on the Mac (Apple Foundation text rules); libm results (spring) may differ by ulps on other platforms.
