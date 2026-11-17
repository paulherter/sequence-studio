# sq-analysis

Analysis: stabilization, mattes, magic mask, subject tracking, benchmarks (portable engines). One module per Swift file (Apple-only files are not ported: the portable path is the reference).

Test: `cargo xtask check sq-analysis`.

Unsafe code: denied in this crate and allowed only in the `ffi` module of `src/lzfse.rs` (one call into Apple's LZFSE decoder,
vendored unmodified in `vendor/lzfse` with its BSD-3 license and built by `build.rs` with `cc`). `[lints]` therefore repeats the
workspace lints instead of inheriting them, since `forbid` cannot be relaxed.

Real-model test: `edge_tamonnx::tests::a_disc_follows_the_click_and_moves` runs EdgeTAM when `SQ_SUBJECT_MASK_MODELS` points at the
five `edgetam_*.onnx` files and an ONNX Runtime can be loaded (the PC: `SQ_ONNX_RUNTIME` names a newer onnxruntime.dll than the old one in system32); otherwise it prints why and passes.
