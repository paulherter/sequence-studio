// Swift: Packages/SQGPU/Sources/SQGPUKernels (Passes, ScopeBinning, ReferenceGraph, ReferenceFamilies)
//! Compositor core and effect passes on `sq-gpu`: the kernel table and its dispatch helpers, the planning both the GPU
//! passes and the CPU references share, the scope binning (CPU twin of `Scopes.slang`) and the headless reference graphs.

pub mod kernels;
pub mod plan;
pub mod reference_families;
pub mod reference_graph;
pub mod scope_binning;
pub mod uniforms;

pub use kernels::{Dispatch, Kernel, Kernels, OutlineStyle, Scratch};
pub use plan::{PixelRect, smear_passes, smear_taps};
pub use scope_binning::{ScopeCounts, ScopeLayout};
pub use uniforms::{Block, BlurU, FilterU, FlowU};

#[cfg(test)]
mod tests;
