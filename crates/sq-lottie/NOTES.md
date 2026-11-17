# sq-lottie notes

Ported: `LottieDocument.swift` (document cache, frame timing, key, 8-bit to linear premultiplied floats). `LottieRenderer.swift` is the Mac side
(CoreVideo buffers, byte-budget frame cache `cacheBudget`) and is not ported; `lottie_renderer.rs` holds the rasterizer seam instead.
`LottieSpec`, `LottieInfo`, `LottieTiming` already live in `sq-core-graphics` (`lottie_generator`) and are used from there.
Not ported: `LottieRendererTests.swift` (Mac). `LottiePortableFrameTests` is ported against a fake `LottieEngine` that paints a square, so
the pixel path (size, key, premultiply, linearize) is covered; the ThorVG drawing itself is not.

## Seam
- Swift keeps one `Document` per (clip, payload fingerprint) in a static dictionary and calls `sqlottie_open/render/close`. Here
  `LottieRenderer` owns the cache (no global state) and talks to `LottieEngine::open` -> `LottieDrawing::render(frame, w, h)`; the handle sits in a
  `Mutex` like the Swift `Mutex(())` around ThorVG.
- `LayerRequest` is the one from `sq-core-effects`; only `clip`, `generator` and `local_time` are read.
- `frame_key` / `portable_frame` take `&self` (the cache is internal); `clear_cache` replaces `LottieRenderer.clearCache()` (documents only; the Mac frame cache is not here).

## Vendor-build decision (open, for the maintainer)
ThorVG v1.1.2 (MIT) is 134 files of C++ in `Packages/SQLottie/Sources/CThorVG` plus the shim `sqlottie.cpp` (C++ API -> `sqlottie_open/info/render/close`).
Not copied now. Proposal:
1. A separate crate `sq-lottie-thorvg` (so `sq-lottie` stays free of C++ and unsafe code) holds `vendor/thorvg` (the 134 files, MIT license kept) and `vendor/sqlottie.cpp`,
   built by `build.rs` with `cc::Build::new().cpp(true)` (software renderer, Lottie + raw loaders only, `Initializer::init(0)` for single-threaded, deterministic draws;
   the same defines as `Package.swift`: no SIMD, no threads), and one `ffi` module with `unsafe_code = "allow"` that implements `LottieEngine`/`LottieDrawing`.
2. Needs a C++17 toolchain on the build machines (MSVC on the PC is enough; `cc` finds it). Record ThorVG in `docs/THIRD_PARTY.md` as it is today.
3. The golden for the frame pixels comes from the Swift ThorVG build (`oracle/sq-lottie/`): same renderer code, so bit equality is expected on the same platform and a tolerance across platforms.
