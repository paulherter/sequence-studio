// SPDX-License-Identifier: GPL-3.0-or-later
//! The kernel table lives in [`crate::passes`] (one home); this module keeps the CPU-plan to constant-block bridge.

use super::scratch::Block;
use crate::effects::image_filters::FilterUniforms;
use crate::effects::simd::Float4;

pub use crate::passes::{Kernel, Kernels};

/// The 96-byte `FilterU` block of `Filters.slang` (HLSL packing).
pub fn filter_block(u: &FilterUniforms) -> Block {
    let f4 = |v: &Float4| [v.x, v.y, v.z, v.w];
    Block::new()
        .f32s(&f4(&u.a))
        .f32s(&f4(&u.b))
        .f32s(&[u.center.x, u.center.y, u.frame.x, u.frame.y])
        .i32s(&[u.i.x, u.i.y, u.i.z, u.i.w])
        .f32s(&f4(&u.c))
        .f32s(&f4(&u.d))
}
