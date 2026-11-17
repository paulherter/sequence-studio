# sq-render `gpu_effects` (task R4b)

GPU half of the effect chain on `sq-gpu` (wgpu, committed Slang outputs). Files are in `src/gpu_effects/`; the CPU references of
`src/effects/` are the oracle.

## Ported
- `kernels.rs`: `Kernel` (every converted kernel with module, entry, `out0` format), `Kernels` (dispatch/run, blur, smear comb,
  mosaic, outline, long shadow, sharpen, mirror, noise, anti-flicker, encode709, premultiply, blend_frames). This is Swift
  `GPUKernels` (SQGPUKernels/Passes.swift) because R1's `passes` module was empty when R4b ran; if R1 ports it, make R1's the one and
  delete this (keep `Kernel::spec` in one place).
- `effect_passes.rs`: `EffectPasses` (blur, Drop Shadow, every ImageFilter incl. the style families, Outline, Long Shadow).
- `temporal_passes.rs`: Deflicker, Video Denoise (temporal best/fast, spatial), Trails; takes the `CompositeU` bytes as `&[u8]`.
- `optical_flow_passes.rs`: `OpticalFlowPasses` (measure, interpolate, working size) and `FlowStore` (= `GPUFlowStore`, the field
  cache per frame pair). Also defines `FlowPairKey`, `FlowQuality`, `OpticalFlowRequest` (Swift RenderLayer.swift): R4a's
  `RenderLayer` must use these instead of its own copies.
- `scope_passes.rs`: `ScopePasses` (clear/accumulate/max/resolve), plus `ScopeLayout`, `ScopeCounts`, `ScopeSelection`, `ScopePlanes`
  (Swift ScopeBinning.swift types; R1's `ScopeBinning` port should re-export these or replace them).
- `look_passes.rs`: film look kernel + `LookUniforms` (FilmLookPlan), anti-flicker kernel, weight and column reference.
- `mask_data.rs`: `mask_entries`, `matte_slots`, `opacity_masks`, `ScreenMap` (+ `from_placement`, `scaled`), `pack_mattes`
  (the half-float packing of `GPUCompositor.matteTexture`), `mask_scope` kernel pass.
- `effect_chain_plan.rs`: `pixel_budget`, `works_at_reduced_size`, `effect_chain_factor`, `repeat_edge_rect`, `lin`.
- `outline_filters.rs`: `jump_steps`, `shadow_plane_size`, `shadow_steps`.
- `scratch.rs`: `Scratch` (pooled intermediates kept until dropped), `Block` (constant-block bytes), `half`/`unhalf`.

## Tests
- `tests_effects.rs`: GPU vs CPU reference at 0.01 (the Swift look-test tolerance) for sharpen, unsharp, short and long smear,
  mirror, noise, glow, mosaic, all 29 style filters and posterize; blur (0.005, with/without repeated edges); Drop Shadow, Outline,
  Long Shadow analytic checks.
- `tests_flow_temporal.rs`: optical flow vs ground truth (fe < 0.25 x blend, < 3 steps), cut falls back to blend, flow cache;
  temporal denoise variance, moving detail, deflicker (fast/best/half strength), spatial denoise, trails.
- `tests_scope_look.rs`: exact scope counts on a flat picture (histogram, waveform, parade, vectorscope, resolved plane, stride),
  film look, anti-flicker vs column reference, mask scope.
- `golden.rs`: 90 rows from the real Swift plan files (`oracle/sq-render/gpu-effects/run.sh` -> `golden/gpu-effects.tsv`): jump
  steps, plane size, shadow steps, chain factor, pixel budget, repeat-edge rect, look uniforms, mask entries, screen map.
- GPU tests skip with a note when no adapter exists.

## Waiting on (R4a `compositor`)
- Everything in `GPUCompositor+Effects.swift` that orchestrates draws: `finishLayer`, `applyMasks` (buffer upload, matte cache),
  `encodePictureMattes`, `transitionSides`, `applyLook`/`applyAntiFlicker` (upright draw first), `gradeSegment`, `adjustment`,
  `blendIntermediate`, `temporalIntermediate`, and `GPUCompositor.flowPasses()`. They need `Draw`, `RenderLayer`,
  `Compositor.Uniforms` (and its 368-byte `CompositeU` serialization), the draw pass and the color chain. Building blocks here:
  `EffectPasses`, `TemporalPasses::run`, `FlowStore::field` + `interpolate`, `Kernels::{encode709, premultiply, blend_frames,
  anti_flicker}`, `LookPasses`, `mask_scope`.
- Compositor-uniform helpers from EffectChainPlan/FilmLookPlan/MaskData that write into `Uniforms`: `configure`, `cutToMaskRect`,
  `cropVector`, `applyWeave`, `screenFromLocal` (use `ScreenMap::from_placement`), `maskedGradeColor/Owner/Media`.
- Transition kernels (`transitionCoverMin`, `transitionPreBlur`, `transitionMix`) and `TransitionUniforms`: R4a/R5.
- Frame-blend wiring of `FrameBlend` (struct) and `RenderNode.motionBlurred`: need `RenderLayer`.

## Notes for the next task
- wgpu: bindings persist across dispatches inside one compute pass. A texture left in an unused input slot still counts as read
  when a later dispatch writes it (validation error "conflicting usages"). `Kernels::dispatch` therefore fills the first 5 input
  slots with a dummy; code that records its own dispatches (temporal passes) sets every slot it reads.
- A pass that records several dispatches shares one `ComputeEncoder` (dispatches see each other's writes); copies
  (`GpuCommands::copy`) need the encoder dropped first.
- Scratch intermediates must live until the command buffer is submitted (`Scratch` dropped after `submit`).

## R5 integration (done)
- One home per type: `passes` owns `Kernel`/`Kernels`/`Dispatch`/`Scratch`/`PixelRect`/`ScopeLayout`/`ScopeCounts`; `compositor::layer`
  owns `FlowPairKey`/`FlowQuality`/`OpticalFlowRequest`; `gpu_effects` re-exports. Open: three differently shaped constant-block
  builders still exist (`compositor::block::Block` aligned writer, `passes::uniforms::Block` offset writer, `gpu_effects::scratch::Block`
  chained writer); merge when one of them is touched again.
- `gpu_effects::hooks::ClipEffectHooks` implements `EffectHooks` (finish_layer incl. segments/shadow/filter/grade/mask scope/look/weave,
  Picture mattes, blend + flow, temporal). `ClipEffectHooks::compositor(&gpu)` renders the full tree. Transition sides and the adjustment
  layer stayed in the core (`GpuCompositor`), as R4a had them.
- `program`: `ProgramCompositor` (WinCompositor) + `planes::to_gpu`/`PlaneCache`/`CpuPlanes`. Titles, shapes, Lottie, captions and the Magic
  matte store arrive as `LayerSource::Raster` / `Inputs::mattes` from the caller (playback/export crates).
- Oracle: `program::tests_program` (code values from the maths, full scene dump `SQ_GPU_DUMP`/`SQ_GPU_GOLDEN`: Metal vs D3D12 max 1/255,
  0 % over) and `gpu_effects::tests_tree`. No Swift frame goldens were recorded (the Swift Windows engine needs a 15 GB build).
