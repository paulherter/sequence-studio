# sq-render `effects` (task R3)

Rust port of the effect plans and CPU references of `Packages/SQRender/Sources/SQRender/Effects/*` plus FrameBlend,
MotionBlurNode, VisibleSourceRegion, ViewGamma and PortableSIMD. Files are in `src/effects/`.

## Ported
- `simd.rs`: `V2/V3/V4<S>` (f32/f64), `Int4`, `Matrix2/3` with Swift operator semantics (PortableSIMD). `SWIFT_FLOAT_PI`: Swift's
  `Float.pi` is pi rounded toward zero (0x40490FDA), one ulp below Rust's `f32::consts::PI`; every Swift `.pi` used as a Float
  must use it (hue shift, wave, spherize), else results differ by ulps.
- `blend_modes.rs`, `crop_mask.rs`, `ultra_key.rs`, `gaussian_blur.rs` (weights, blur, `Plan`), `image_filters.rs` (+ the pure
  `GPUFilterPlan`/`GPUFilterUniforms` of SQGPUKernels: `pixel_rect`, `smear_taps`, `smear_passes`, `FilterUniforms`),
  `style_filters.rs` (`plan` for all 31 style filters, every CPU reference, homography, perspective inverse),
  `frame_blend.rs` (weight), `motion_blur_node.rs` (sample transform), `view_gamma.rs`, `visible_source_region.rs`.
- Oracle: `oracle/sq-render/effects/run.sh` builds the real Swift files with plain swiftc (SQCore built once by
  `build-sqcore.sh`) and dumps `golden/effects.tsv` (2051 rows: blend grid, keys, crop, blur plans, image and style filter
  images, uniforms, region geometry). `src/effects/golden.rs` compares all rows at 1e-6 (relative above 1). Strictly equal
  except 2 style rows (twirl, kaleidoscope) that differ by ~3e-7: the -O Swift build fuses `sinf`/`cosf` into
  `__sincosf_stret`; the Rust debug build calls them separately.
- Swift tests translated into `src/effects/tests.rs` (blend, keys, sharpen/unsharp, smear, mirror, noise, glow, mosaic, style
  color and geometry, lens, rolling shutter, perspective inverse, homography) and per file (frame blend, view gamma, crop,
  motion blur, visible region).
- Decision: `matte_tone_f` (Swift `MatteRefine.toneF`) lives in `ultra_key.rs` with a shortcut comment; sq-core-masks
  `matte_refine` has only morph/box blur. Move it there when that crate is next touched.

## Waiting on
- Files that import Metal stay out: AntiFlickerPass, CompositorEffects, CompositorMasks, FilmLookPass, TemporalPass.
- Not in the brief's list (Effects/*, no Metal): EffectChainPlan, EffectPasses, FilmLookPlan, MaskData, OpticalFlowPasses,
  OutlineFilters, TemporalPasses. They need ColorPipeline/RenderLayer types of R2/R4; not ported here.
- `FrameBlend` struct (needs `SQFrame` use in a render layer and `OpticalFlowRequest`); only `weight` is ported.
- `RenderNode.motionBlurred` (needs `RenderLayer`, `RenderNode`, `LayerRequest`); the transform math is ported
  (`motion_blur_node::sample_transform`).
- `VisibleSourceRegion.isPointwise` (needs `ColorPipeline`/`ClipEffects.segments`) and `averagesBeforeGrading` (needs
  `SourceColorSpace`).
- StyleFilters' MSL kernel text and the GPU halves of the Swift tests (GPU matches reference, cost budgets, ViewGamma
  presenter test): they belong to the Slang kernels and the GPU layer (R4b).
