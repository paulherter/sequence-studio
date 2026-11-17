// SPDX-License-Identifier: GPL-3.0-or-later
//! The CPU reference color pipeline of Sequence Studio (port of the pure files of Swift `SQRender/Color`): transfer
//! functions and gamuts, the tone map, LUTs, the color blocks (Basic, Creative, Wheels, Curves, Color Range, Zone Board,
//! Pro grade Steps), the per-clip `ColorPipeline` and the clip-to-pipeline builder. f32 math and operation order follow
//! the Swift code; the GPU passes, MSL/Slang sources, scopes passes and the GPU color chain live in the GPU layer.
//! See `crates/sq-render/NOTES-color.md` for what waits on it.

pub mod auto_tone;
pub mod clip_pipeline;
pub mod cube_lut;
pub mod gamut;
pub mod graph_stages;
pub mod hdr_conform;
pub mod look_thumbnail;
pub mod output;
pub mod pipeline;
pub mod scopes_reference;
pub mod source_space;
pub mod stages;
pub mod tone_mapping;
pub mod tone_math;
pub mod transfer;
pub mod vec;
pub mod white_balance;

pub use auto_tone::AutoTone;
pub use clip_pipeline::{CachingLutProvider, LutProvider, LutStamp, pipeline_from_clip_color};
pub use cube_lut::{CubeKind, CubeLut, CubeLutError, LutInterpolation};
pub use gamut::{Gamut, WhitePoint};
pub use graph_stages::KeyTerm;
pub use hdr_conform::HdrConform;
pub use output::{OutputTarget, SoftGamutCompression, rec709_encode};
pub use pipeline::{ColorOp, ColorPipeline, ColorStage, StageKind};
pub use source_space::{SourceColorSpace, SourceSpaceExt};
pub use tone_mapping::ToneMapping;
pub use vec::{Mat3, Mat3d, Vec3};
pub use white_balance::WhiteBalanceSolver;

#[cfg(test)]
mod testing;
#[cfg(test)]
mod tests_clip_pipeline;
#[cfg(test)]
mod tests_conform;
#[cfg(test)]
mod tests_cube_lut;
#[cfg(test)]
mod tests_graph_ops;
#[cfg(test)]
mod tests_oracle;
#[cfg(test)]
mod tests_pipeline;
