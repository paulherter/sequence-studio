# sq-gpu

GPU device layer on wgpu 30 (Metal on the Mac, D3D12 on Windows). Design: docs/rust/render-playback-export-design.md.

- `gpu`: `Gpu` (one device and queue for UI, program and export; the 3 samplers are created first and never dropped),
  `GpuCommands` with the compute and render encoders (`set_pipeline`, `set_input(slot)`, `set_output`, `set_buffer`,
  `set_constants`, `dispatch`/`draw`), `submit` (frames and uniform chunks are released when the GPU finished).
- `layout`: the fixed 35-entry bind group mirroring `shaders-src/Bindings.slang`, plus the `DrawQuads` layout, `PixelFormat`.
- `pipelines`: the 64 lazy pipelines (57 compute, 7 draws) from the committed shader outputs; the only `unsafe` is the
  passthrough module creation in `pipelines/passthrough.rs`.
- `uniforms`: constant blocks in an arena, bound with dynamic offsets (no immediates).
- `frames`: `GpuTexture`, `TexturePool`, `GpuFrame` (`Arc`, `keep`).
- `readback`: texture/buffer readback through pooled staging buffers.

## Shaders
`shaders-src/` is a copy of `Packages/SQGPU/Shaders` (the Swift tree is frozen) with the storage buffers patched to
`(RW)ByteAddressBuffer` (wgpu binds D3D12 storage buffers as raw views) and `DrawQuads` re-numbered for the wgpu slot rules.
It is compiled without `SQ_METAL`: every backend runs the portable branches (target copy to `in6` instead of framebuffer fetch,
normalized part sampling). `cargo xtask shaders` (slangc: Mac `~/tools/slang`, PC `C:\Users\paul\slang`) writes
`shaders/msl/` (per module), `shaders/dxil/` (per entry; only on Windows, needs the Windows SDK DXC), `reflection.json` and
`entries.rs`, and checks the reflection against the fixed layout. `--spirv` also writes SPIR-V (11 MB, not committed).

## Tests
`cargo xtask check sq-gpu` (GPU tests skip with a note when no adapter exists). The five g2 passes and all 64 pipelines run on
both machines; `SQ_GPU_DUMP=<dir>` writes the outputs, `SQ_GPU_GOLDEN=<dir>` compares with the other backend (<= 1/255).
