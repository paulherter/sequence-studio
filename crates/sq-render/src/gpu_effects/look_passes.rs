// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Effects/FilmLookPlan.swift (`LookUniforms`, `lookUniforms`), Effects/FilmLookPass.swift, Effects/AntiFlickerPass.swift
//! The film / tape look as one kernel pass at the end of a layer's effect chain, and Motion's Anti-flicker Filter. The layer's
//! final draw is drawn upright into an image first (the compositor's job); these are the kernels that read it.

use super::kernels::Kernels;
use super::scratch::Block;
use sq_core_color::FilmLook;
use sq_gpu::frames::GpuTexture;
use sq_gpu::gpu::{Gpu, GpuCommands, GpuError};
use sq_gpu::layout::PixelFormat;
use std::sync::Arc;

const FLAG_GRAIN: u32 = 1;
const FLAG_SCANLINES: u32 = 8;
const FLAG_CHROMA: u32 = 16;
const FLAG_TRACKING: u32 = 32;
const FLAG_AGED: u32 = 64;

/// `LookU` of FilmLook.slang (112 bytes).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LookUniforms {
    pub dims: [f32; 4],
    pub ids: [u32; 4],
    pub grain: [f32; 4],
    pub scan: [f32; 4],
    pub chroma: [f32; 4],
    pub track: [f32; 4],
    pub aged: [f32; 4],
}

impl LookUniforms {
    /// The uniforms of the look kernel for a layer `width` x `height` px (`scale` = layer px per 1080-line px).
    pub fn new(look: &FilmLook, width: u32, height: u32) -> Self {
        let mut u = Self {
            dims: [width as f32, height as f32, height as f32 / 1080.0, look.grain.map_or(0.0, |g| g.color as f32)],
            ids: [0; 4],
            grain: [0.0; 4],
            scan: [0.0; 4],
            chroma: [0.0; 4],
            track: [0.0; 4],
            aged: [0.0; 4],
        };
        u.dims[2] = height as f32 / 1080.0;
        let mut flags = 0;
        if let Some(g) = &look.grain {
            flags |= FLAG_GRAIN;
            u.grain = [g.amount as f32, g.size as f32, g.softness as f32, g.luma_weight as f32];
            u.ids[1] = g.seed;
        }
        if let Some(a) = &look.aged {
            flags |= FLAG_AGED;
            u.aged = [a.dust as f32, a.scratches as f32, a.flicker as f32, 0.0];
            u.ids[3] = a.seed;
        }
        if let Some(s) = &look.scanlines {
            flags |= FLAG_SCANLINES;
            u.scan = [s.intensity as f32, s.spacing as f32, s.thickness as f32, 0.0];
        }
        if let Some(c) = &look.chroma_bleed {
            flags |= FLAG_CHROMA;
            u.chroma = [c.bleed as f32, c.shift as f32, 0.0, 0.0];
        }
        if let Some(t) = &look.tracking {
            flags |= FLAG_TRACKING;
            u.track = [t.amount as f32, t.band_height as f32, t.phase as f32, 0.0];
            u.ids[2] = t.seed;
        }
        u.ids[0] = flags;
        u
    }

    fn block(&self) -> Block {
        Block::new()
            .f32s(&self.dims)
            .u32s(&self.ids)
            .f32s(&self.grain)
            .f32s(&self.scan)
            .f32s(&self.chroma)
            .f32s(&self.track)
            .f32s(&self.aged)
    }
}

/// Weight of each neighbor row of the Anti-flicker Filter for a strength (clamped to 0...1): `[k, 1 - 2k, k]`, `k` = strength / 4.
pub fn anti_flicker_weight(strength: f64) -> f32 {
    (strength.clamp(0.0, 1.0) / 4.0) as f32
}

/// CPU reference of the Anti-flicker Filter on one column (rows top to bottom, edge rows repeat).
pub fn anti_flicker_column(column: &[f32], strength: f64) -> Vec<f32> {
    let k = anti_flicker_weight(strength);
    if k <= 0.0 || column.len() < 2 {
        return column.to_vec();
    }
    (0..column.len())
        .map(|i| {
            k * column[i.saturating_sub(1)] + (1.0 - 2.0 * k) * column[i] + k * column[(i + 1).min(column.len() - 1)]
        })
        .collect()
}

/// The look and anti-flicker kernels of one device.
pub struct LookPasses {
    gpu: Arc<Gpu>,
    kernels: Kernels,
}

impl LookPasses {
    /// The passes on `gpu`.
    pub fn new(gpu: &Arc<Gpu>) -> Self {
        Self { gpu: Arc::clone(gpu), kernels: Kernels::new(gpu) }
    }

    /// The look kernel: tracking noise, chroma bleed, grain and scanlines of `look` on `src` into `dst` (same size).
    pub fn film_look(
        &self,
        cmds: &mut GpuCommands,
        look: &FilmLook,
        src: &GpuTexture,
        dst: &GpuTexture,
    ) -> Result<(), GpuError> {
        let u = LookUniforms::new(look, dst.width(), dst.height());
        let mut enc = cmds.compute();
        enc.set_pipeline(&self.gpu.compute_pipeline("FilmLook", "filmLook", PixelFormat::Rgba16Float)?);
        enc.set_input(src, 0)?;
        enc.set_output(dst);
        enc.set_constants(u.block().bytes(), 0)?;
        enc.dispatch(dst.width(), dst.height())
    }

    /// The vertical softening of `src` into `dst` for a strength 0...1.
    pub fn anti_flicker(
        &self,
        cmds: &mut GpuCommands,
        src: &GpuTexture,
        dst: &GpuTexture,
        strength: f64,
    ) -> Result<(), GpuError> {
        self.kernels.anti_flicker(cmds, src, dst, anti_flicker_weight(strength))
    }
}
