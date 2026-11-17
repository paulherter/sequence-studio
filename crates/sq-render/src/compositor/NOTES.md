# compositor (R4a) notes

Ported: `RenderLayer`/`RenderNode` tree (layer.rs), `Compositor+Uniforms` (uniforms.rs, byte layouts tested), `PixelFormats+Portable`,
the color pass plan (plan.rs), `GPUColorChain` (color_chain.rs, generic `colorChainInPlace` kernel only), `LayerColorResolver`,
`GPUCompositor` + `resampleLinear` (gpu_compositor.rs). `ColorKernelSource` (specialised kernels) and the Metal-only files are not ported.

## Seam for R4b (clip effect passes)
`EffectHooks` (gpu_compositor.rs) is what R4b implements and hands to `GpuCompositor::with_hooks`: `finish_layer` (Crop, Rounded
Corners, blur, shadows, filters, keys, masks, film look; default draws the layer plainly), `encode_picture_mattes`, `blend_intermediate`
(frame blend/flow), `temporal_intermediate`, `begin_render`. Helpers R4b needs are public on `GpuCompositor`: `acquire`, `scratch_buffer`,
`draw_all`, `plain`, `convert`, `chain`, `dummy`, `adjustment`, `picture_scopes`, `limits_color_work`, `color_resolver`. The adjustment
layer, transition sides (cover and long-blur pre-pass), stencil, pair, group and the grade path are in the core (Swift had them in
`GPUCompositor+Effects`, they need no effect kernel).

## Deviations
- Intermediates come from `Gpu::acquire` and are reserved until the next `render` (Swift: own free/inFlight lists).
- `RenderLayer::color_pipeline` is `Option<Arc<ColorPipeline>>`, mattes are `Arc<SubjectMatte>` (cheap clones, pointer identity for the upload cache).
- The `Prepared*` color stage fields became `pub(crate)` (color/stages.rs, color/graph_stages.rs) and `effective_source` too: the planner reads them.
- Bind state persists across draws in a wgpu pass, so every draw sets all five picture slots (unused ones get the 1x1 dummy).
- No Swift PNG golden of `GPUCompositorReference` could be produced (disk guard: the Swift build needs 15 GB); the oracle is CPU maths per
  feature (tests_gpu.rs) plus the Metal-vs-D3D12 dump compare of the core reference tree (`SQ_GPU_DUMP` / `SQ_GPU_GOLDEN`).
