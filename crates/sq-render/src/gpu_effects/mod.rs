//! GPU effect passes of the render graph: the compute kernels of the effect chain (blur, Drop Shadow, whole-picture and style
//! filters, Outline, Long Shadow), the temporal passes (Deflicker, Video Denoise, Trails), optical flow, the film look and
//! anti-flicker kernels, the scope passes, and the pure plans behind them (effect chain, masks, look uniforms). The CPU
//! references in `crate::effects` are the test oracle. See `crates/sq-render/NOTES-gpu-effects.md`.

pub mod effect_chain_plan;
pub mod effect_passes;
pub mod hooks;
pub mod kernels;
pub mod look_passes;
pub mod mask_data;
pub mod optical_flow_passes;
pub mod outline_filters;
pub mod scope_passes;
pub mod scratch;
pub mod temporal_passes;
pub mod uniform_plan;

#[cfg(test)]
mod golden;
#[cfg(test)]
mod testing;
#[cfg(test)]
mod tests_effects;
#[cfg(test)]
mod tests_flow_temporal;
#[cfg(test)]
mod tests_scope_look;
#[cfg(test)]
mod tests_tree;

pub use hooks::ClipEffectHooks;
