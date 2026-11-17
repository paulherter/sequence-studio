# sq-analysis notes

Scope: group g1 of Etappe 2b, the files the Windows build of `Packages/SQAnalysis` compiles (Package.swift `appleOnly` lists
the rest: Vision, CoreML, Accelerate, Metal users; none of it is ported).

## Choices
- Gyroflow: not used. `GyroflowEngine.swift` and the warp files are Apple-only in the Swift package, so nothing in this group
  calls the Rust engine in `Vendor/sqgyro`; only the portable `GyroAnalysisState` is here.
- LZFSE: C reference decoder vendored in `vendor/lzfse`, built with `cc`, called through a 10-line `ffi` module.
- Async to blocking: Swift `async`/`CancellationError` (AnalysisTurn, Reframe detect, StabilizationAnalyzing) are blocking calls
  with a `CancelToken` (defined in `analysis_turn`); no executor exists yet. A waiting turn polls its token every 2 ms.
- `SubjectLookAhead` takes any `PartialEq` key instead of a class identity; one thread per started job (Swift: one serial queue
  with at most one job in flight, which `start` also enforces).
- `FrameMatteStore::save_later`: one thread per key, joined in `wait_for_saves` (shortcut comment in the code).
- `AnalysisCacheLocation`: no `Bundle`; the legacy matte folder uses the name `SequenceStudio`. Caches folder per OS in
  `caches_directory`.
- `SubjectMaskQuality` reads and writes a `StringDefaults` trait instead of `UserDefaults`; `standard` is Quality on aarch64.
- `MagicMatteStore+Unavailable` is the form the Windows build compiles; the Mac store (MagicMask.swift) is not ported.
- `EdgeTAMOnnxError` has an extra `Onnx(OnnxError)` variant (Swift lets `OnnxError` through `throws`). The unused `pix` of the
  Swift `pending` tuple is dropped.
- `FrameMatteStore::edge` applies the spatial part of `MatteRefine.refine` (shrink/grow, box blur) with the helpers of
  sq-core-masks; the tone step is the identity for this caller. A frame bigger than 2^28 texels in a cache file is skipped
  instead of allocated.
- `SubjectLogitMath` keeps the Swift loops and is tested against `SubjectTrackRules::stats` / `SubjectCropPass::constrain`.
- Tests skipped by design: Swift tests of Apple-only files; `StabilizationCache`/`EdgeTAMLoader` lines of
  `AnalysisCacheLocationTests`; the `SubjectLogitMath` speed test (no Debug/Release gap in Rust); the real-model test skips
  without models.

## Swift quirks kept
- `MusicFit` sorts candidates with a tolerance comparator that is not a strict weak order; Rust's `sort_by` may panic on that,
  so a small stable merge sort is used. For inputs where the comparator is consistent the order is identical; elsewhere it
  can differ from Swift's sort.
- `MaskLag.report` and `SceneCutDetector` keep their Swift loop forms.

## Waiting on
- `MatteRefine.refine` (tone and spatial) in the effects port; `FrameMatteStore::edge` should call it.
