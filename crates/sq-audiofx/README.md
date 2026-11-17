# sq-audiofx

Own audio DSP: effects, loudness, pitch, noise reduction. One module per Swift file (Apple-only files are not ported: the portable path is the reference).

Test: `cargo xtask check sq-audiofx`.

RNNoise (BSD-3-Clause) is vendored in `vendor/rnnoise` and built by `build.rs`. This crate uses `unsafe_code = "deny"` instead of the
workspace `forbid`: the only `unsafe` is the `ffi` module in `src/rnnoise_denoiser.rs`. Notes for the ports: `NOTES-g1.md`, `NOTES-g2.md`.
