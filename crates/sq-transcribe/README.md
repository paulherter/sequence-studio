# sq-transcribe

Transcription service seam, transcript model, captions and subtitle readers. One module per Swift file (Apple-only files are not ported: the portable path is the reference).

Test: `cargo xtask check sq-transcribe`.

Unsafe code: denied in the crate and allowed only in the `ffi` module of `src/whisper_runtime.rs`, which calls the vendored C face
(`vendor/csqwhisper.c`, built with `cc`; it loads `whisper.dll` at run time, so nothing links against whisper.cpp). `[lints]` repeats the
workspace lints for that reason, as in `sq-onnx`.
