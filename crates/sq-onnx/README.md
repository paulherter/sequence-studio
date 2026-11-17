# sq-onnx

ONNX Runtime session wrapper. `run` takes float32 tensors; `run_typed` also takes int64 and bool tensors and fetches chosen outputs by name (text models, sq-translate). The runtime (`onnxruntime.dll`) is loaded at run time, so the app starts
without it and reports `OnnxError::Unavailable` when it is missing; the same C face runs on the Mac (`libonnxruntime.dylib` from `Contents/Frameworks`, `SQ_ONNXRUNTIME` for a folder).

Design: the loader and the session code stay in the vendored C file `vendor/csqonnx.c` (built with `cc`, MIT ONNX Runtime header
in `vendor/ort`, license `vendor/ORT-LICENSE-MIT.txt`). ONNX Runtime's C API is a table of about 300 function pointers whose
layout lives in a 380 KB header; a Rust port would have to mirror that table by hand, with far more unsafe code than the
50 lines of `ffi` that call the six C functions. Unsafe code is denied in this crate and allowed only in the `ffi` module of `src/onnx_model.rs`
(`[lints]` therefore repeats the workspace lints instead of inheriting them, since `forbid` cannot be relaxed).

## Execution providers

`Provider::choose` is the one place that picks: `SQ_ONNX_PROVIDER=cpu|directml|coreml|auto` (default `auto`; the old `SQ_ONNX_CPU` means `cpu`).
`auto` gives the platform accelerator (DirectML on Windows, Core ML on the Mac) to models whose caller passes `accelerate = true`
(EdgeTAM: Magic Mask, Anonymize) and the CPU to the rest. A provider that is missing or refuses a model falls back to the CPU in
`sqort_open`, and one stderr line says which provider ran (`onnx: <file> runs on directml`). `Provider::force` overrides it inside a process (tests).

Measured on the PC (RX 9070 XT, release build, DirectML vs CPU; the DirectML run matched the CPU run, mask IoU 1.0000):

| Model | CPU | DirectML |
|---|---|---|
| EdgeTAM, per tracked frame (640x360 test clip) | 1063 ms | 124 ms |
| YuNet + YOLOX-tiny, per picture pair | 86.5 ms | 20.5 ms |
| Whisper base / small, per audio second | 0.18 to 0.27 s / 1.17 s | crashes (access violation): stays CPU |
| OPUS-MT en-de, per sentence | 0.68 s | crashes (access violation): stays CPU |

Measured on the Mac (release app, 30-frame 640x360 disk clip, EdgeTAM, Core ML vs CPU; IoU against the true disk 0.960 vs 0.962):

| Model | CPU | Core ML |
|---|---|---|
| EdgeTAM, per tracked frame | 755 ms | 986 ms (model load 14 s vs 0.35 s) |

Core ML is slower than the CPU for EdgeTAM, so `auto` stays on the CPU on the Mac; `SQ_ONNX_PROVIDER=coreml` forces it.

The int8-quantized Whisper and OPUS-MT parts crash DirectML, so those callers pass `accelerate = false`; do not force `directml` for them.

Test: `cargo xtask check sq-onnx`.
