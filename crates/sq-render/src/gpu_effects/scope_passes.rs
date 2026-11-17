// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Color/ScopePasses.swift, SQGPUKernels/ScopeBinning.swift (`ScopeLayout`, `ScopeCounts`)
//! The scope compute passes (Slang module Scopes: clear, accumulate, maxima, resolve). The source is a working-linear texture
//! (`Rgba16Float` / `Rgba32Float`); the counts buffer has [`ScopeLayout::total_count`] `u32` slots.

use sq_gpu::frames::GpuTexture;
use sq_gpu::gpu::{Gpu, GpuCommands, GpuError};
use sq_gpu::layout::{GROUP_SIDE, PixelFormat};
use std::sync::Arc;

use super::scratch::Block;

pub use crate::passes::scope_binning::{ScopeCounts, ScopeLayout};

/// Which scopes to accumulate (bit set).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScopeSelection(pub u32);

impl ScopeSelection {
    pub const WAVEFORM_LUMA: Self = Self(1);
    pub const WAVEFORM_PARADE: Self = Self(2);
    pub const VECTORSCOPE: Self = Self(4);
    pub const HISTOGRAM: Self = Self(8);
    pub const ALL: Self = Self(15);
}

impl std::ops::BitOr for ScopeSelection {
    type Output = Self;
    fn bitor(self, rhs: Self) -> Self {
        Self(self.0 | rhs.0)
    }
}

/// The `r32Float` planes `encode` resolves into (`count / max`): waveform W x L, parade 3W x L, vectorscope N x N, histogram
/// 256 x 4.
pub struct ScopePlanes {
    pub waveform_luma: GpuTexture,
    pub waveform_parade: GpuTexture,
    pub vectorscope: GpuTexture,
    pub histogram: GpuTexture,
}

impl ScopePlanes {
    /// New planes for `layout`.
    pub fn new(gpu: &Gpu, layout: &ScopeLayout) -> Self {
        let tex = |w: usize, h: usize| gpu.texture(w as u32, h as u32, PixelFormat::R32Float);
        Self {
            waveform_luma: tex(layout.waveform_width, layout.waveform_levels),
            waveform_parade: tex(3 * layout.waveform_width, layout.waveform_levels),
            vectorscope: tex(layout.vectorscope_size, layout.vectorscope_size),
            histogram: tex(ScopeLayout::HISTOGRAM_BINS, 4),
        }
    }
}

/// `ScopeU` of Scopes.slang (80 bytes).
#[derive(Default, Clone, Copy)]
struct Uniforms {
    width: u32,
    height: u32,
    stride: u32,
    flags: u32,
    wave_w: u32,
    wave_l: u32,
    vec_n: u32,
    off_wave_luma: u32,
    off_parade: u32,
    off_vector: u32,
    off_hist: u32,
    offset: u32,
    count: u32,
    max_index: u32,
    out_w: u32,
    out_h: u32,
}

/// Row width of the linear kernels (clear, max): index `y * ROW_WIDTH + x`.
const ROW_WIDTH: u32 = 1024;

impl Uniforms {
    fn block(&self) -> Block {
        Block::new()
            .u32s(&[self.width, self.height, self.stride, self.flags])
            .u32s(&[self.wave_w, self.wave_l, self.vec_n, ROW_WIDTH])
            .u32s(&[self.off_wave_luma, self.off_parade, self.off_vector, self.off_hist])
            .u32s(&[self.offset, self.count, self.max_index, 0])
            .u32s(&[self.out_w, self.out_h, 0, 0])
    }
}

/// The scope passes of one device.
pub struct ScopePasses {
    gpu: Arc<Gpu>,
}

impl ScopePasses {
    /// The passes on `gpu`.
    pub fn new(gpu: &Arc<Gpu>) -> Self {
        Self { gpu: Arc::clone(gpu) }
    }

    /// A zeroed counts buffer for `layout`.
    pub fn make_counts(&self, layout: &ScopeLayout) -> wgpu::Buffer {
        self.gpu.storage_buffer(layout.total_count() as u64 * 4)
    }

    #[allow(clippy::too_many_arguments)]
    /// Clears, accumulates (every `pixel_stride`-th pixel in x and y), finds the maxima and, with `planes`, resolves them.
    pub fn encode(
        &self,
        cmds: &mut GpuCommands,
        source: &GpuTexture,
        counts: &wgpu::Buffer,
        layout: &ScopeLayout,
        planes: Option<&ScopePlanes>,
        scopes: ScopeSelection,
        pixel_stride: u32,
    ) -> Result<(), GpuError> {
        let step = pixel_stride.max(1);
        let l = layout;
        let mut u = Uniforms {
            width: source.width(),
            height: source.height(),
            stride: step,
            flags: scopes.0,
            wave_w: l.waveform_width as u32,
            wave_l: l.waveform_levels as u32,
            vec_n: l.vectorscope_size as u32,
            off_wave_luma: l.offset_waveform_luma() as u32,
            off_parade: l.offset_parade() as u32,
            off_vector: l.offset_vector() as u32,
            off_hist: l.offset_histogram() as u32,
            ..Uniforms::default()
        };
        let pipeline = |entry: &'static str, out: PixelFormat| self.gpu.compute_pipeline("Scopes", entry, out);
        let color = PixelFormat::Rgba16Float;
        let mut enc = cmds.compute();
        // Linear kernels index y * ROW_WIDTH + x, in whole 16 x 16 groups (scopeFindMax reduces over a full group).
        let linear = |enc: &mut sq_gpu::gpu::ComputeEncoder<'_>, n: usize| {
            let rows = (n as u32).div_ceil(ROW_WIDTH);
            enc.dispatch(ROW_WIDTH, rows.div_ceil(GROUP_SIDE) * GROUP_SIDE)
        };
        enc.set_buffer(counts, 2)?;
        u.offset = 0;
        u.count = l.total_count() as u32;
        enc.set_pipeline(&pipeline("scopeClear", color)?);
        enc.set_constants(u.block().bytes(), 0)?;
        linear(&mut enc, l.total_count())?;
        enc.set_pipeline(&pipeline("scopeAccumulate", color)?);
        enc.set_input(source, 0)?;
        enc.set_constants(u.block().bytes(), 0)?;
        enc.dispatch(source.width().div_ceil(step), source.height().div_ceil(step))?;
        let regions = [
            (l.offset_waveform_luma(), l.waveform_luma_count(), 0),
            (l.offset_parade(), l.parade_count(), 1),
            (l.offset_vector(), l.vector_count(), 2),
            (l.offset_histogram(), l.histogram_count(), 3),
        ];
        enc.set_pipeline(&pipeline("scopeFindMax", color)?);
        for (off, count, index) in regions {
            u.offset = off as u32;
            u.count = count as u32;
            u.max_index = (l.offset_maxima() + index) as u32;
            enc.set_constants(u.block().bytes(), 0)?;
            linear(&mut enc, count)?;
        }
        if let Some(p) = planes {
            enc.set_pipeline(&pipeline("scopeResolve", PixelFormat::R32Float)?);
            let outs = [
                (&p.waveform_luma, l.offset_waveform_luma(), 0),
                (&p.waveform_parade, l.offset_parade(), 1),
                (&p.vectorscope, l.offset_vector(), 2),
                (&p.histogram, l.offset_histogram(), 3),
            ];
            for (tex, off, idx) in outs {
                u.offset = off as u32;
                u.max_index = (l.offset_maxima() + idx) as u32;
                u.out_w = tex.width();
                u.out_h = tex.height();
                enc.set_constants(u.block().bytes(), 0)?;
                enc.set_output(tex);
                enc.dispatch(tex.width(), tex.height())?;
            }
        }
        Ok(())
    }

    /// The counts buffer as [`ScopeCounts`] (waits for the GPU).
    pub fn read(&self, counts: &wgpu::Buffer, layout: &ScopeLayout) -> Result<ScopeCounts, GpuError> {
        let bytes = self.gpu.read_buffer(counts, layout.total_count() as u64 * 4)?;
        let words: Vec<u32> = bytes.as_chunks::<4>().0.iter().map(|c| u32::from_le_bytes(*c)).collect();
        ScopeCounts::from_words(*layout, &words).ok_or_else(|| GpuError::Readback("scope counts too short".into()))
    }

    /// One measurement in its own command buffer: encode, wait, read.
    pub fn measure(
        &self,
        source: &GpuTexture,
        counts: &wgpu::Buffer,
        layout: &ScopeLayout,
        scopes: ScopeSelection,
        pixel_stride: u32,
    ) -> Result<ScopeCounts, GpuError> {
        let mut cmds = self.gpu.commands();
        self.encode(&mut cmds, source, counts, layout, None, scopes, pixel_stride)?;
        self.gpu.submit_and_wait(cmds)?;
        self.read(counts, layout)
    }
}
