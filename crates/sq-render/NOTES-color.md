# sq-render `color` module (R2) notes

CPU reference color pipeline, port of the pure files of Swift `Packages/SQRender/Sources/SQRender/Color`. Only
`crates/sq-render/src/color/` was edited. f32 math and operation order follow Swift.

## Done (Swift file -> Rust file)
- `ColorPipeline.swift` -> `pipeline.rs`, `source_space.rs` (`SourceColorSpace` is a type alias of the saved `ColorSpaceID`,
  the render side is the `SourceSpaceExt` trait; Swift's `isHDR` is `gets_tone_map`), `ColorStages.swift` -> `stages.rs`,
  `tone_math.rs`; `ColorGraphStages.swift` -> `graph_stages.rs`; `TransferFunctions(+Vendor).swift` -> `transfer.rs`;
  `Gamut.swift` -> `gamut.rs`; `ToneMapping.swift` -> `tone_mapping.rs`; `OutputTarget.swift`/`Rec709Output.swift` ->
  `output.rs`; `CubeLUT(+3DL,+VLT).swift` -> `cube_lut.rs`; `HDRConform.swift` -> `hdr_conform.rs`;
  `WhiteBalanceSolver.swift` -> `white_balance.rs`; `AutoTone.swift` -> `auto_tone.rs`; `LookThumbnail.swift` ->
  `look_thumbnail.rs`; `ClipColorPipeline.swift` (builder, `graphOps`, `LUTProvider`, `CachingLUTProvider`) ->
  `clip_pipeline.rs`; `ScopesReference.signal` -> `scopes_reference.rs`.
- Oracle: `oracle/sq-render/color/run.sh` compiles the pure Swift files plus all of SQCore with plain swiftc and writes
  `golden/color.tsv` (f32 bit patterns: 23 decode/encode curves, 14 gamuts, white-balance matrices, tone map, soft gamut,
  output targets, LUT lookups, 31 pipelines x 20 pixels, HDR conform, WB solver, Auto Tone, thumbnails).
  `tests_oracle.rs` replays it: 9849 floats, max relative error 9.5e-7 (limit 1e-6 on macOS, 2e-4 elsewhere: libm powf ulps, amplified by PQ).
- Ported Swift tests (all pure ones): ColorPipelineTests, CubeLUTTests, CubeLUT3DLTests, LUTInterpolationAndOutputTests,
  ToneMappingPeakTests, HDRTrimTests, WhiteBalanceSolverTests, LookThumbnailTests, TransferAndGamutTests (partly),
  ClipColorPipelineTests, LogModeConformTests (+ HDRConformMathTests), AutoToneTests, ColorGroupTests/ColorGraphKeyTests
  (lowering and CPU parts).
- Not ported one by one, covered by the golden dump instead: ColorStagesTests, HSLSecondary*Tests, ZoneBoardStageTests,
  InputTransformTests, VendorLogCurvesTests (all curves round-trip in `transfer.rs`).

## Waiting on (GPU layer / other tasks)
- `ColorPipelineGPU.swift`, `ColorPipelineGPU+Plan.swift`, `GPUColorChain.swift`, `LayerColorResolver.swift` (R4a), the Metal
  and MSL files (`ColorShaderSource`, `ColorKernelSource`), `Scopes.swift`, `ScopePasses(Check).swift`: need sq-gpu. The GPU
  planner reads `ColorPipeline::stages()` and the `flags()`/`matrix()` accessors of the prepared types (kept for it).
  Swift's `ColorPipeline.gpuPasses` is not part of the Rust `ColorPipeline`.
- `ScopesReference.compute/vectorscopeBin/cbcr/level` need `ScopeBinning` from Swift `SQGPUKernels` (not in the repo as a
  portable file yet); only `signal` is ported.
- Tests: ColorPipelineGPUTests, GradeFusionTests, ColorGraphRenderTests (GPU parts), ScopePassesTests, ScopesTests,
  LayerColorResolverTests, ColorReviewTests (GPU/cache parts), GPUTestSupport.

## Deviations and notes
- `Mat3::mul_vec` uses fused multiply-add like the Apple simd matrix routine; without it the Swift dump differs by 2e-6 on
  PQ-sensitive paths. FMA is exactly specified, so the result is the same on every platform (slower on x86 without FMA).
- `CubeLut::new` returns `Result` (Swift traps on a bad table); extra error case `InvalidTable`.
- `ToneMapping` has private clamped fields with setters (Swift `didSet`), `ColorPipeline` recompiles in its setters.
- `ClipColor.effectiveSource` / `usesInputLUT` are not in `sq-core-model`/`sq-core-color`; the builder holds private copies
  (`effective_source`, `log_mode == CameraLUT`). Move them next to `ClipColor` if another caller needs them.
- `ColorOp::Conversion/Look` hold `Arc<CubeLut>` (Swift copy-on-write arrays).
- Min/max clamps use `f32::clamp`, which propagates NaN like Swift's `min(max())`.
