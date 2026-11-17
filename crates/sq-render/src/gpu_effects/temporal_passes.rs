// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Effects/TemporalPasses.swift
//! Deflicker, Video Denoise and Trails on the GPU (Slang modules TemporalStats, DeflickerGains, TemporalDenoise, SpatialDenoise,
//! TemporalTrails). A frame is a pair of planes (luma or RGB, chroma or a dummy). The layer's `CompositeU` block (the
//! compositor's uniforms of the plain draw) is passed as bytes: it tells the kernels how to read the planes.

use super::scratch::{Block, Scratch};
use sq_core_effects::temporal_effects::{TemporalDenoise, TemporalFilter};
use sq_gpu::frames::GpuTexture;
use sq_gpu::gpu::{Gpu, GpuCommands, GpuError};
use sq_gpu::layout::PixelFormat;
use std::sync::Arc;

/// Most echoes the trails kernel binds (+ the center in slot 0).
pub const TRAIL_SLOTS: usize = 9;
/// Deflicker gain grid (Best: per tile; Fast uses the same tiles for its frame mean).
pub const DEFLICKER_TILES: (u32, u32) = (16, 9);
/// Most frames the denoise kernel binds (center + 5 each side).
pub const TEMPORAL_SLOTS: usize = 11;

const FLAG_DENOISE: u32 = 1;
const FLAG_DEFLICKER: u32 = 2;
const FLAG_BEST: u32 = 4;
const FLAG_LINEAR_OUT: u32 = 8;

/// One frame's planes.
pub type Planes = (GpuTexture, GpuTexture);

/// Called on the filtered picture to grade it in place (the layer's color pipeline); an error aborts the filter.
pub type Grade<'a> = &'a mut dyn FnMut(&mut GpuCommands, &GpuTexture) -> Result<(), GpuError>;

/// Thresholds (encoded 0...1 units) of the temporal stage, from the effect's 0...1 controls: `(luma, color, motion)`.
pub fn thresholds(d: &TemporalDenoise) -> (f32, f32, f32) {
    (
        if d.luma > 0.0 { (0.01 + d.luma * 0.15) as f32 } else { 0.0 },
        if d.color > 0.0 { (0.01 + d.color * 0.15) as f32 } else { 0.0 },
        (0.05 + d.motion_limit * 0.3) as f32,
    )
}

/// How many neighbor frames `filter` reads before and after the center (nearest first).
pub fn neighbor_limits(filter: &TemporalFilter) -> (usize, usize) {
    let temporal = filter.denoise.filter(TemporalDenoise::is_temporal).map_or(0, |d| d.frames_each_side);
    let want = temporal.max(filter.deflicker.map_or(0, |d| d.frames_each_side)) as usize;
    // Trails read back in source order, or ahead for a backward (reversed) clip: the frames the viewer has seen.
    let (back, reach) = filter.trails.map_or((false, 0), |t| (t.backward, t.reach() as usize));
    (want.max(if back { 0 } else { reach }), want.max(if back { reach } else { 0 }))
}

/// The frames and layer state a filter run reads.
pub struct TemporalInput<'a> {
    /// The shown frame.
    pub center: &'a Planes,
    /// Frames before it, nearest first (same size and kind).
    pub before: &'a [Planes],
    /// Frames after it, nearest first.
    pub after: &'a [Planes],
    /// The `CompositeU` bytes of the layer's plain draw.
    pub composite: &'a [u8],
    /// Frame size in px.
    pub size: (u32, u32),
}

/// The five temporal pipelines' dispatch code, with the dummies unused slots point at.
pub struct TemporalPasses {
    gpu: Arc<Gpu>,
    dummy: GpuTexture,
    dummy_buffer: wgpu::Buffer,
}

fn run_kernel(
    gpu: &Gpu,
    enc: &mut sq_gpu::gpu::ComputeEncoder<'_>,
    module: &'static str,
    entry: &'static str,
) -> Result<(), GpuError> {
    enc.set_pipeline(&gpu.compute_pipeline(module, entry, PixelFormat::Rgba16Float)?);
    Ok(())
}

impl TemporalPasses {
    /// The passes on `gpu`.
    pub fn new(gpu: &Arc<Gpu>) -> Self {
        Self {
            gpu: Arc::clone(gpu),
            dummy: gpu.texture(1, 1, PixelFormat::Rgba16Float),
            dummy_buffer: gpu.storage_buffer(16),
        }
    }

    /// Runs the filter on the center planes (with their neighbors, nearest first) into an intermediate, then `grade` (the
    /// layer's color pipeline in place; `None` = the inverse BT.709 OETF in the kernels): straight working-linear color plus
    /// alpha, drawn with `linearize = 0`. `None` when nothing runs.
    #[allow(clippy::too_many_lines)]
    pub fn run(
        &self,
        cmds: &mut GpuCommands,
        scratch: &mut Scratch,
        filter: &TemporalFilter,
        input: &TemporalInput<'_>,
        grade: Option<Grade<'_>>,
    ) -> Result<Option<GpuTexture>, GpuError> {
        let (w, h) = input.size;
        let (before, after) = (input.before, input.after);
        let dn = filter.denoise.as_ref();
        let df = filter.deflicker.as_ref();
        let temporal_denoise = dn.is_some_and(TemporalDenoise::is_temporal);
        let n_before = dn.filter(|_| temporal_denoise).map_or(0, |d| (d.frames_each_side as usize).min(before.len()));
        let n_after = dn.filter(|_| temporal_denoise).map_or(0, |d| (d.frames_each_side as usize).min(after.len()));
        let df_before = df.map_or(0, |d| (d.frames_each_side as usize).min(before.len()));
        let df_after = df.map_or(0, |d| (d.frames_each_side as usize).min(after.len()));
        let spatial_on = dn.is_some_and(TemporalDenoise::is_spatial);
        // Trails: echo k is the frame `offsets[k]` back; the first one missing (clip start, not decoded yet, another size) ends
        // the list, so a reduced-size center only ever blends reduced-size echoes.
        let mut echoes: Vec<&Planes> = Vec::new();
        let mut weights: Vec<f32> = Vec::new();
        if let Some(tr) = &filter.trails {
            let seen = if tr.backward { after } else { before };
            for (o, wt) in tr.offsets().into_iter().zip(tr.weights()) {
                let Some(p) = seen.get((o - 1) as usize) else { break };
                echoes.push(p);
                weights.push(wt as f32);
            }
        }
        let trails_on = !echoes.is_empty();
        let prepass = n_before + n_after > 0 || df.is_some() || spatial_on;
        if !prepass && !trails_on {
            return Ok(None);
        }

        let mid = scratch.image(w, h);
        let mut out = mid.clone();
        let graded = grade.is_some();

        // 1. Deflicker: tile means of every frame used, then the gains.
        let stats_before = if df.is_some() { n_before.max(df_before) } else { n_before };
        let stats_after = if df.is_some() { n_after.max(df_after) } else { n_after };
        let (mut flags, mut tiles_x, mut tiles_y) = (0u32, 1u32, 1u32);
        let mut gain_buffer = self.dummy_buffer.clone();
        if let Some(df) = df {
            let (tx, ty) = DEFLICKER_TILES;
            let tiles = tx * ty;
            let stat_frames: Vec<&Planes> = std::iter::once(input.center)
                .chain(before.iter().take(stats_before))
                .chain(after.iter().take(stats_after))
                .collect();
            let bytes = (stat_frames.len() as u64) * u64::from(tiles) * 4;
            let (means, gains) = (self.gpu.storage_buffer(bytes), self.gpu.storage_buffer(bytes));
            let mut enc = cmds.compute();
            run_kernel(&self.gpu, &mut enc, "TemporalStats", "temporalStats")?;
            enc.set_constants(input.composite, 0)?;
            enc.set_buffer(&means, 2)?;
            for (j, f) in stat_frames.iter().enumerate() {
                enc.set_input(&f.0, 0)?;
                enc.set_input(&f.1, 1)?;
                enc.set_constants(Block::new().u32s(&[j as u32, tx, ty, 0]).bytes(), 1)?;
                // One 16 x 16 group per tile.
                enc.dispatch(tx * 16, ty * 16)?;
            }
            let d = Block::new()
                .u32s(&[
                    stat_frames.len() as u32,
                    tiles,
                    df_before as u32,
                    df_after as u32,
                    stats_before as u32,
                    u32::from(df.local),
                ])
                .f32s(&[df.strength as f32, 0.0]);
            run_kernel(&self.gpu, &mut enc, "DeflickerGains", "deflickerGains")?;
            enc.set_buffer(&means, 2)?;
            enc.set_buffer(&gains, 3)?;
            enc.set_constants(d.bytes(), 0)?;
            enc.dispatch(tiles, 1)?;
            gain_buffer = gains;
            flags |= FLAG_DEFLICKER;
            (tiles_x, tiles_y) = (tx, ty);
        }

        // 2. Temporal denoise (+ deflicker gain) of the center into `mid`, straight encoded color (or linear when it is last).
        let (mut luma_s, mut color_s, mut motion, mut keep) = (0.0f32, 0.0f32, 1.0f32, 0.0f32);
        let (mut search_step, mut search_count) = (1i32, 1u32);
        if let Some(dn) = dn.filter(|_| n_before + n_after > 0) {
            flags |= FLAG_DENOISE;
            (luma_s, color_s, motion) = thresholds(dn);
            keep = dn.keep_original as f32;
            if dn.best {
                flags |= FLAG_BEST;
                let unit = ((f64::from(h) / 1080.0).round() as i32).max(1);
                (search_count, search_step) = match dn.motion_search {
                    0 => (1, 1),
                    1 => (5, 2 * unit),
                    _ => (9, 4 * unit),
                };
            }
        }
        if !spatial_on && !graded && !trails_on {
            flags |= FLAG_LINEAR_OUT;
        }
        let temporal_block = Block::new()
            .u32s(&[(1 + n_before + n_after) as u32, n_before as u32, stats_before as u32, flags])
            .f32s(&[luma_s, color_s, motion, keep])
            .i32s(&[search_step])
            .u32s(&[search_count, tiles_x, tiles_y]);
        let mut enc = cmds.compute();
        if prepass {
            run_kernel(&self.gpu, &mut enc, "TemporalDenoise", "temporalDenoise")?;
            let slots: Vec<&Planes> = std::iter::once(input.center)
                .chain(before.iter().take(n_before))
                .chain(after.iter().take(n_after))
                .collect();
            for i in 0..TEMPORAL_SLOTS {
                let f = slots.get(i).copied();
                enc.set_input(f.map_or(&self.dummy, |p| &p.0), i)?;
                enc.set_input(f.map_or(&self.dummy, |p| &p.1), TEMPORAL_SLOTS + i)?;
            }
            enc.set_output(&mid);
            enc.set_constants(input.composite, 0)?;
            enc.set_constants(temporal_block.bytes(), 1)?;
            enc.set_buffer(&gain_buffer, 3)?;
            enc.dispatch(w, h)?;

            // 3. Spatial smoothing.
            if let Some(dn) = dn.filter(|_| spatial_on) {
                let sp = scratch.image(w, h);
                let s = ((f64::from(h) / 1080.0).round() as i32).max(1);
                let (radius, step) = match dn.detail_size {
                    1 => (1, s),
                    2 => (2, s),
                    _ => (2, 2 * s),
                };
                let luma = if dn.spatial_luma > 0.0 { (0.004 + dn.spatial_luma * 0.06) as f32 } else { 0.0 };
                let color = if dn.spatial_color > 0.0 { (0.004 + dn.spatial_color * 0.08) as f32 } else { 0.0 };
                let su = Block::new().i32s(&[radius, step]).f32s(&[luma, color]).u32s(&[
                    u32::from(!graded && !trails_on),
                    0,
                    0,
                    0,
                ]);
                run_kernel(&self.gpu, &mut enc, "SpatialDenoise", "spatialDenoise")?;
                enc.set_input(&mid, 0)?;
                enc.set_output(&sp);
                enc.set_constants(su.bytes(), 0)?;
                enc.dispatch(w, h)?;
                out = sp;
            }
        }

        // 3b. Trails over the (filtered) center.
        if let (true, Some(tr)) = (trails_on, &filter.trails) {
            let mut w0 = [0.0f32; 4];
            let mut w1 = [0.0f32; 4];
            for (k, wt) in weights.iter().enumerate() {
                if k < 4 { w0[k] = *wt } else { w1[k - 4] = *wt }
            }
            let tu = Block::new()
                .u32s(&[echoes.len() as u32, tr.blend as u32, u32::from(prepass) | if graded { 0 } else { 2 }, 0])
                .f32s(&w0)
                .f32s(&w1);
            let dst = if prepass { scratch.image(w, h) } else { mid.clone() };
            run_kernel(&self.gpu, &mut enc, "TemporalTrails", "temporalTrails")?;
            let slots: Vec<&Planes> = std::iter::once(input.center).chain(echoes.iter().copied()).collect();
            for i in 0..TRAIL_SLOTS {
                let f = slots.get(i).copied();
                enc.set_input(f.map_or(&self.dummy, |p| &p.0), i)?;
                enc.set_input(f.map_or(&self.dummy, |p| &p.1), TRAIL_SLOTS + i)?;
            }
            enc.set_input(if prepass { &out } else { &self.dummy }, 2 * TRAIL_SLOTS)?;
            enc.set_output(&dst);
            enc.set_constants(input.composite, 0)?;
            enc.set_constants(tu.bytes(), 1)?;
            enc.dispatch(w, h)?;
            out = dst;
        }
        drop(enc);

        // 4. The layer's color pipeline on the filtered picture.
        if let Some(grade) = grade {
            grade(cmds, &out)?;
        }
        Ok(Some(out))
    }
}
