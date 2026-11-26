//! Compositor: layer requests to GPU draws on `sq-gpu`. `layer` is the portable render model (`RenderLayer`,
//! `RenderNode` tree), `uniforms` the layer draw's constant blocks, `plan` the color chain's pass plan,
//! `color_chain` the chain on the GPU, `gpu_compositor` the node tree drawn with the Slang layer draws, `resolver` the
//! per-layer color pipeline cache. See crates/sq-render/README.md and docs/rust/render-playback-export-design.md.

mod block;
pub mod color_chain;
pub mod gpu_compositor;
#[cfg(test)]
pub(crate) mod gpu_test_support;
pub mod layer;
pub mod pixel_formats;
pub mod plan;
pub mod resolver;
pub mod uniforms;

#[cfg(test)]
mod tests_gpu;

pub use layer::{
    AdjustmentNode, CompositorError, Content, ContentPart, FlowPairKey, FlowQuality, FootageFill, FrameBlend,
    OpticalFlowRequest, PlaceholderKind, RenderLayer, RenderNode, TemporalFrames,
};
pub use uniforms::{ConvertUniforms, PreBlurUniforms, TransitionSideUniforms, TransitionUniforms, Uniforms};

pub use color_chain::GpuColorChain;
pub use gpu_compositor::{Draw, preview_shown_size, EffectHooks, GpuCompositor, Picture, PictureKind, PictureSource};
pub use resolver::LayerColorResolver;
