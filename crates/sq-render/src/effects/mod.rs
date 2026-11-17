// SPDX-License-Identifier: GPL-3.0-or-later
//! Effect plans and their CPU references (the oracle of the GPU kernels): blend modes, keys, crop mask, whole-picture and
//! style filters, Gaussian blur, plus the frame geometry the compositor derives from a layer transform. Pure float code with
//! the operation order of the Swift references; see crates/sq-render/NOTES-effects.md for what waits on other tasks.

// The references keep Swift's float semantics: `!(a > b)` is deliberately not `a <= b` (NaN takes the other branch), and the
// literals are the ones Swift has.
#![allow(clippy::neg_cmp_op_on_partial_ord, clippy::excessive_precision)]

pub mod blend_modes;
pub mod crop_mask;
pub mod display_view;
pub mod frame_blend;
pub mod gaussian_blur;
pub mod image_filters;
pub mod motion_blur_node;
pub mod simd;
pub mod style_filters;
pub mod ultra_key;
pub mod view_choices;
pub mod view_gamma;
pub mod visible_source_region;

#[cfg(test)]
mod golden;

#[cfg(test)]
mod tests;
