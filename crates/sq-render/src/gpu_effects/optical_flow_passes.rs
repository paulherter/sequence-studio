// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Effects/OpticalFlowPasses.swift, GPUCompositor+Flow.swift (`GPUFlowStore`), RenderLayer.swift (FlowPairKey, FlowQuality,
// OpticalFlowRequest)
//! Optical flow for `TimeInterpolation.opticalFlow` (Slang module OpticalFlow): the measuring and interpolation passes playback
//! and export both run, so they move the same pixels on every backend.
//!
//! Motion: dense pyramidal Lucas-Kanade on luma at a working size (long side 960, `Faster` 480), coarse to fine, a few
//! Gauss-weighted window iterations per level and a 3 x 3 median per level against outliers, measured both ways (A to B and B to
//! A), then a trust value per field (patch agreement along the vector times forward-backward consistency). Picture: two
//! candidates per output pixel moved to the instant `t`, weighted by how well their samples agree; where neither agrees the
//! plain frame blend shows (a failed estimate never looks worse than Blend frames).

use super::kernels::{Kernel, Kernels};
use super::scratch::{Block, Scratch};
use sq_gpu::frames::GpuTexture;
use sq_gpu::gpu::{Gpu, GpuCommands, GpuError};
use sq_gpu::layout::PixelFormat;
use std::collections::HashMap;
use std::sync::Arc;

pub use crate::compositor::layer::{FlowPairKey, FlowQuality, OpticalFlowRequest};

/// Forward and backward field with trust (`Rgba32Float`, working size).
#[derive(Clone)]
pub struct Field {
    pub forward: GpuTexture,
    pub backward: GpuTexture,
}

/// Working size of the motion estimate for a `width` x `height` frame.
pub fn working_size(width: u32, height: u32, quality: FlowQuality) -> (u32, u32) {
    // Never above 3/4 of the frame: the box prefilter of the reduction steadies the gradients (measured: at full size 8-bit
    // gradients made large motions converge worse, 1.5 vs 0.3 steps error on the 32 px test).
    let long = i64::from(width.max(height));
    let cap = quality.working_long_side().min(long * 3 / 4);
    if long <= cap || cap <= 0 {
        return (width, height);
    }
    let s = cap as f64 / long as f64;
    ((f64::from(width) * s).round().max(1.0) as u32, (f64::from(height) * s).round().max(1.0) as u32)
}

/// The measuring and interpolation passes.
pub struct OpticalFlowPasses {
    kernels: Kernels,
    gpu: Arc<Gpu>,
}

/// `FlowU` of OpticalFlow.slang (48 bytes).
#[derive(Default, Clone, Copy)]
struct FlowUniforms {
    radius: i32,
    lambda: f32,
    inv_two_sigma2: f32,
    max_step: f32,
    t: f32,
    linearize: u32,
    flow_scale: [f32; 2],
    sigma: f32,
    has_prev: u32,
}

impl FlowUniforms {
    fn block(&self) -> Block {
        Block::new()
            .i32s(&[self.radius])
            .f32s(&[self.lambda, self.inv_two_sigma2, self.max_step, self.t])
            .u32s(&[self.linearize])
            .f32s(&self.flow_scale)
            .f32s(&[self.sigma])
            .u32s(&[self.has_prev])
            .f32s(&[0.0, 0.0])
    }
}

impl OpticalFlowPasses {
    /// The passes on `gpu`.
    pub fn new(gpu: &Arc<Gpu>) -> Self {
        Self { kernels: Kernels::new(gpu), gpu: Arc::clone(gpu) }
    }

    /// Measures the flow pair of `a` and `b` (source-encoded RGB, full size) into `cmds`. The two kept fields are new
    /// textures; everything else is scratch.
    #[allow(clippy::too_many_lines)]
    pub fn measure(
        &self,
        cmds: &mut GpuCommands,
        scratch: &mut Scratch,
        a: &GpuTexture,
        b: &GpuTexture,
        quality: FlowQuality,
    ) -> Result<Field, GpuError> {
        let (w, h) = working_size(a.width(), a.height(), quality);
        let mut sizes = vec![(w, h)];
        while let Some(&(lw, lh)) = sizes.last() {
            if lw.min(lh) < 16 {
                break;
            }
            sizes.push((lw.div_ceil(2), lh.div_ceil(2)));
        }
        // Luma pyramids and gradients of both frames.
        let mut tex = |f: PixelFormat, s: &(u32, u32)| scratch.texture(s.0, s.1, f);
        let l0: Vec<GpuTexture> = sizes.iter().map(|s| tex(PixelFormat::R32Float, s)).collect();
        let l1: Vec<GpuTexture> = sizes.iter().map(|s| tex(PixelFormat::R32Float, s)).collect();
        let g0: Vec<GpuTexture> = sizes.iter().map(|s| tex(PixelFormat::Rg32Float, s)).collect();
        let g1: Vec<GpuTexture> = sizes.iter().map(|s| tex(PixelFormat::Rg32Float, s)).collect();
        // The two fields at full working size are kept (cache); every other level is scratch.
        let out_f = self.gpu.texture(w, h, PixelFormat::Rgba32Float);
        let out_b = self.gpu.texture(w, h, PixelFormat::Rgba32Float);
        let final_f = tex(PixelFormat::Rg32Float, &(w, h));
        let final_b = tex(PixelFormat::Rg32Float, &(w, h));
        let levels: Vec<Vec<(GpuTexture, GpuTexture)>> = (0..2)
            .map(|_| sizes.iter().map(|s| (tex(PixelFormat::Rg32Float, s), tex(PixelFormat::Rg32Float, s))).collect())
            .collect();

        let none = FlowUniforms::default().block();
        let k = &self.kernels;
        let mut enc = cmds.compute();
        for (src, dst) in [(a, &l0[0]), (b, &l1[0])] {
            k.dispatch(&mut enc, Kernel::OF_LUMA, &[src], dst, none.bytes(), None)?;
        }
        for i in 1..sizes.len() {
            for p in [&l0, &l1] {
                k.dispatch(&mut enc, Kernel::OF_DOWN, &[&p[i - 1]], &p[i], none.bytes(), None)?;
            }
        }
        for i in 0..sizes.len() {
            for (l, g) in [(&l0[i], &g0[i]), (&l1[i], &g1[i])] {
                k.dispatch(&mut enc, Kernel::OF_GRAD, &[l], g, none.bytes(), None)?;
            }
        }
        // Coarse to fine, both directions.
        let r = quality.radius();
        let sigma = r as f32 * 0.75 + 0.5;
        let lkp = FlowUniforms {
            radius: r,
            lambda: 1e-4,
            inv_two_sigma2: 1.0 / (2.0 * sigma * sigma),
            max_step: 2.0,
            ..Default::default()
        }
        .block();
        for (dir, dir_levels) in levels.iter().enumerate() {
            let (i0, i1, gi0, gi1) = if dir == 0 { (&l0, &l1, &g0, &g1) } else { (&l1, &l0, &g1, &g0) };
            let mut prev: Option<GpuTexture> = None;
            for level in (0..sizes.len()).rev() {
                let s = sizes[level];
                let (ping, pong) = &dir_levels[level];
                // Start: the coarser level's field scaled up (zero on the coarsest).
                let up = FlowUniforms { has_prev: u32::from(prev.is_some()), ..Default::default() }.block();
                k.dispatch(&mut enc, Kernel::OF_UP, &[prev.as_ref().unwrap_or(&l0[level])], ping, up.bytes(), None)?;
                let (mut cur, mut other) = (ping.clone(), pong.clone());
                let small = if u64::from(s.0) * u64::from(s.1) <= 160 * 90 { 2 } else { 0 };
                for _ in 0..quality.iterations() + small {
                    let inputs = [&i0[level], &gi0[level], &i1[level], &gi1[level], &cur];
                    k.dispatch(&mut enc, Kernel::OF_LK, &inputs, &other, lkp.bytes(), None)?;
                    std::mem::swap(&mut cur, &mut other);
                }
                let dst = if level == 0 { if dir == 0 { final_f.clone() } else { final_b.clone() } } else { other };
                k.dispatch(&mut enc, Kernel::OF_MEDIAN, &[&cur], &dst, none.bytes(), None)?;
                prev = Some(dst);
            }
        }
        // Trust of each field: patch agreement along the vector times forward-backward consistency.
        for (i0, i1, f, back, out) in
            [(&l0[0], &l1[0], &final_f, &final_b, &out_f), (&l1[0], &l0[0], &final_b, &final_f, &out_b)]
        {
            k.dispatch(&mut enc, Kernel::OF_CONFIDENCE, &[i0, i1, f, back], out, none.bytes(), None)?;
        }
        Ok(Field { forward: out_f, backward: out_b })
    }

    #[allow(clippy::too_many_arguments)]
    /// Writes the picture at `t` (0 = `a`, 1 = `b`) into `out`. `linearize`: `a`/`b` are source-encoded BT.709 (the mix runs in
    /// light, like Frame Blending); false: already working-linear.
    pub fn interpolate(
        &self,
        cmds: &mut GpuCommands,
        a: &GpuTexture,
        b: &GpuTexture,
        field: &Field,
        t: f32,
        linearize: bool,
        out: &GpuTexture,
    ) -> Result<(), GpuError> {
        let p = FlowUniforms {
            t,
            linearize: u32::from(linearize),
            sigma: 0.1,
            flow_scale: [
                out.width() as f32 / field.forward.width() as f32,
                out.height() as f32 / field.forward.height() as f32,
            ],
            ..Default::default()
        };
        self.kernels.run(
            cmds,
            Kernel::OF_INTERPOLATE,
            &[a, b, &field.forward, &field.backward],
            out,
            p.block().bytes(),
            None,
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct CacheKey {
    pair: FlowPairKey,
    quality: FlowQuality,
    width: u32,
    height: u32,
}

/// The flow passes with a field cache per source frame pair (a 25 % slow motion measures once per four output frames).
pub struct FlowStore {
    passes: OpticalFlowPasses,
    cache: HashMap<CacheKey, Field>,
    order: Vec<CacheKey>,
    /// Cap of cached fields in bytes.
    pub cache_byte_limit: u64,
    measured: usize,
}

fn field_bytes(f: &Field) -> u64 {
    [&f.forward, &f.backward].iter().map(|t| u64::from(t.width()) * u64::from(t.height()) * 16).sum()
}

impl FlowStore {
    /// An empty store on `gpu`.
    pub fn new(gpu: &Arc<Gpu>) -> Self {
        Self {
            passes: OpticalFlowPasses::new(gpu),
            cache: HashMap::new(),
            order: Vec::new(),
            cache_byte_limit: 128 << 20,
            measured: 0,
        }
    }

    /// The passes (for `interpolate`).
    pub fn passes(&self) -> &OpticalFlowPasses {
        &self.passes
    }

    /// Fields measured so far (a cached pair measures once).
    pub fn measure_count(&self) -> usize {
        self.measured
    }

    /// Fields in the cache.
    pub fn cached_pairs(&self) -> usize {
        self.cache.len()
    }

    /// Drops every cached field.
    pub fn trim(&mut self) {
        self.cache.clear();
        self.order.clear();
    }

    /// The field pair of `a` and `b` (source-encoded RGB, full size): cached or measured into `cmds`.
    pub fn field(
        &mut self,
        cmds: &mut GpuCommands,
        scratch: &mut Scratch,
        a: &GpuTexture,
        b: &GpuTexture,
        request: &OpticalFlowRequest,
    ) -> Result<Field, GpuError> {
        let key =
            request.key.map(|pair| CacheKey { pair, quality: request.quality, width: a.width(), height: a.height() });
        if let Some(key) = key
            && let Some(f) = self.cache.get(&key)
        {
            self.order.retain(|k| *k != key);
            self.order.push(key);
            return Ok(f.clone());
        }
        let f = self.passes.measure(cmds, scratch, a, b, request.quality)?;
        self.measured += 1;
        if let Some(key) = key {
            self.order.push(key);
            self.cache.insert(key, f.clone());
            let mut total: u64 = self.cache.values().map(field_bytes).sum();
            while total > self.cache_byte_limit && self.order.len() > 1 {
                let old = self.order.remove(0);
                if let Some(e) = self.cache.remove(&old) {
                    total -= field_bytes(&e);
                }
            }
        }
        Ok(f)
    }
}
