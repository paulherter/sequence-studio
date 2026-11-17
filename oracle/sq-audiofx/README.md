# sq-audiofx oracle

`golden/g2.tsv`: output of the Swift stages of group g2 (multiband, limiters, gate, delay, reverb, repair stages, notch,
graphic EQ, de-esser, pitch shift, disguise voice) for fixed inputs: name, FNV-1a hash of the output Float bits, shape,
sampled values. Regenerate: copy `Packages/SQCore` and `Packages/SQAudioFX` to a scratch folder, replace the package tests by
`swift-dump-g2/Dump.swift` and run `DUMP_OUT=<file> /usr/bin/swift test --filter Dump` there (the dump needs `@testable`
access, so it runs as a test; the shell's swiftly shim fails to link, use `/usr/bin/swift`).
Pitch Shift and Disguise Voice ran on Accelerate's FFT; the Rust port uses the portable radix-2 FFT, so those rows are
compared with a tolerance (`crates/sq-audiofx/tests/g2_golden.rs`).
