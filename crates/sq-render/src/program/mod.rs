//! The program compositor: `LayerRequest`s of one display frame become `RenderLayer`s and the `RenderNode` tree, the
//! `GpuCompositor` draws it into a half-float canvas and the Present pass turns that into BT.709 code values (Swift
//! `WinCompositor`, `WinTimelineFrameSource`'s compositing half). `planes` turns `SQFrame` storage into textures
//! (design section 3); `compositor` is the frame recorder. See crates/sq-render/README.md.

pub mod compositor;
pub mod gyro_warp;
pub mod planes;

#[cfg(test)]
mod tests_parity;
#[cfg(test)]
mod tests_program;

pub use compositor::{
    GPU_WAIT_LIMIT, Inputs, LayerSource, OUTPUT_RING, ProgramCompositor, ProgramError, Raster, RenderOptions,
    RenderedFrame, Source,
};
pub use gyro_warp::{GyroMaps, WarpMap, warp_picture, warp_picture_scaled, warp_plane_cpu};
pub use planes::{CpuPlanes, PlaneCache, PlaneError, PlaneKey, to_gpu};
