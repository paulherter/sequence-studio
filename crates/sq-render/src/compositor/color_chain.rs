// Swift: GPUColorChain.swift
//! The color chain on the GPU: the pass plan ([`super::plan::passes`]) run by the generic Slang kernel
//! `colorChainInPlace`, in place on a half-float picture.
//!
//! shortcut: always the generic interpreter kernel (the Mac class compiled specialised kernels per chain layout in the
//! background, same pixels); add them when grade cost shows up in profiles.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};

use sq_gpu::frames::GpuTexture;
use sq_gpu::gpu::{Gpu, GpuCommands};
use sq_gpu::layout::{PixelFormat, TABLE_SLOT};

use super::block::Block;
use super::layer::CompositorError;
use super::plan::{self, MAX_CURVES};
use crate::color::pipeline::ColorPipeline;
use crate::color::stages::CURVE_TABLE_COUNT;
use crate::color::vec::Vec3;
use crate::color::{CubeKind, CubeLut};

/// LUT textures kept (as the Mac class).
const MAX_CACHED_LUTS: usize = 16;
/// Row width of a 1D LUT texture.
const LUT_1D_ROW_WIDTH: usize = 4096;
/// Sections a `ColorChainU` block holds (`kMaxColorSections`).
const BLOCK_SECTIONS: usize = 24;
/// `ColorChainU` in bytes: the header and the section blocks.
const CHAIN_BYTES: usize = 32 + BLOCK_SECTIONS * 128;
/// `CurveRows` in bytes: `MAX_CURVES` tables of 64 rows of 16 bytes.
const CURVE_BYTES: usize = MAX_CURVES * CURVE_TABLE_COUNT * 16;

/// Keyed by the LUT's identity (the `Arc` is kept in the entry, so its address stays unique).
#[derive(Default)]
struct LutCache {
    entries: HashMap<usize, (Arc<CubeLut>, GpuTexture)>,
    order: Vec<usize>,
}

/// Runs a [`ColorPipeline`] on a half-float picture.
pub struct GpuColorChain {
    gpu: Arc<Gpu>,
    dummy_3d: GpuTexture,
    dummy_2d: GpuTexture,
    luts: Mutex<LutCache>,
}

impl GpuColorChain {
    pub fn new(gpu: &Arc<Gpu>) -> GpuColorChain {
        let dummy_3d = gpu.texture_3d(2, 2, 2, PixelFormat::Rgba32Float);
        let dummy_2d = gpu.texture(2, 1, PixelFormat::Rgba32Float);
        let zeros = [0u8; 2 * 2 * 2 * 16];
        gpu.upload_texture(&dummy_3d, &zeros, 2 * 16);
        gpu.upload_texture(&dummy_2d, &zeros[..32], 2 * 16);
        GpuColorChain { gpu: Arc::clone(gpu), dummy_3d, dummy_2d, luts: Mutex::new(LutCache::default()) }
    }

    /// Grades `texture` (half float, source-encoded R'G'B' as the compositor's conversion writes it, or BT.709-encoded for
    /// an adjustment layer) in place. `quarter_turned`: the vignette follows the upright picture.
    pub fn encode(
        &self,
        cmds: &mut GpuCommands,
        pipeline: &ColorPipeline,
        texture: &GpuTexture,
        quarter_turned: bool,
    ) -> Result<(), CompositorError> {
        let kernel = self.gpu.compute_pipeline("ColorChainInPlace", "colorChainInPlace", PixelFormat::Rgba16Float)?;
        for pass in plan::passes(pipeline, true) {
            let (mut t3, mut t1) = (self.dummy_3d.clone(), self.dummy_2d.clone());
            if let Some(lut) = &pass.lut {
                let t = self.lut_texture(lut)?;
                if lut.kind == CubeKind::Lut3D {
                    t3 = t;
                } else {
                    t1 = t;
                }
            }
            let mut header = pass.header;
            header.extra[0] = u32::from(quarter_turned);
            let mut block = Block::new();
            header.write(&mut block);
            for s in pass.sections.iter().take(BLOCK_SECTIONS) {
                s.write(&mut block);
            }
            let mut block = block.finish(16);
            block.resize(CHAIN_BYTES, 0);
            let mut curves = Block::new();
            for row in pass.curves.iter().take(CURVE_BYTES / 16) {
                curves.vec4(*row);
            }
            let mut curves = curves.finish(16);
            curves.resize(CURVE_BYTES, 0);
            let mut enc = cmds.compute();
            enc.set_pipeline(&kernel);
            enc.set_input(&t3, TABLE_SLOT)?;
            enc.set_input(&t1, 3)?;
            enc.set_constants(&block, 0)?;
            enc.set_constants(&curves, 1)?;
            enc.set_output(texture);
            enc.dispatch(texture.width(), texture.height())?;
        }
        Ok(())
    }

    /// The LUT as an `Rgba32Float` texture (3D cube, or 1D rows of `LUT_1D_ROW_WIDTH`); the last 16 are kept.
    fn lut_texture(&self, lut: &Arc<CubeLut>) -> Result<GpuTexture, CompositorError> {
        let expected = if lut.kind == CubeKind::Lut3D { lut.size.pow(3) } else { lut.size };
        if lut.size < 2 || lut.table.len() != expected {
            return Err(CompositorError::InvalidTarget(format!(
                "LUT: {} entries for size {}",
                lut.table.len(),
                lut.size
            )));
        }
        let key = Arc::as_ptr(lut) as usize;
        let mut cache = self.luts.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some((_, t)) = cache.entries.get(&key) {
            return Ok(t.clone());
        }
        let rgba = |table: &[Vec3]| -> Vec<u8> {
            table.iter().flat_map(|v| [v.x, v.y, v.z, 1.0]).flat_map(f32::to_le_bytes).collect()
        };
        let tex = if lut.kind == CubeKind::Lut3D {
            let t = self.gpu.texture_3d(lut.size as u32, lut.size as u32, lut.size as u32, PixelFormat::Rgba32Float);
            self.gpu.upload_texture(&t, &rgba(&lut.table), (lut.size * 16) as u32);
            t
        } else {
            let (w, h) = (LUT_1D_ROW_WIDTH, lut.size.div_ceil(LUT_1D_ROW_WIDTH));
            let mut table = lut.table.clone();
            table.resize(w * h, Vec3::ZERO);
            let mut bytes = rgba(&table);
            // Padding texels past the table are all zero.
            let used = lut.size * 16;
            bytes[used..].fill(0);
            let t = self.gpu.texture(w as u32, h as u32, PixelFormat::Rgba32Float);
            self.gpu.upload_texture(&t, &bytes, (w * 16) as u32);
            t
        };
        if cache.order.len() >= MAX_CACHED_LUTS && !cache.order.is_empty() {
            let old = cache.order.remove(0);
            cache.entries.remove(&old);
        }
        cache.entries.insert(key, (Arc::clone(lut), tex.clone()));
        cache.order.push(key);
        Ok(tex)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::color::{ColorOp, ToneMapping};
    use crate::compositor::gpu_test_support::{f16_to_f32, f32_to_f16, gpu, read_rgba16f, upload_rgba16f};
    use sq_core_model::{BasicCorrection, ColorSpaceID, RGBCurves, Vignette};

    /// Deterministic pixels in 0...1 (the LCG of the color tests).
    fn pixels(count: usize) -> Vec<f32> {
        let mut s = 99u64;
        let mut next = move || {
            s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (s >> 40) as f32 / (1u32 << 24) as f32
        };
        (0..count).flat_map(|_| [next(), next(), next(), 0.75]).collect()
    }

    fn look() -> Arc<CubeLut> {
        let n = 5usize;
        let d = (n - 1) as f32;
        let mut table = Vec::new();
        for b in 0..n {
            for g in 0..n {
                for r in 0..n {
                    let c = Vec3::new(r as f32 / d, g as f32 / d, b as f32 / d);
                    table.push(Vec3::new(c.x * 0.9 + 0.05 * c.y, c.y.powf(1.1), c.z * 0.8 + 0.1));
                }
            }
        }
        Arc::new(
            CubeLut::new("look", CubeKind::Lut3D, n, (Vec3::ZERO, Vec3::ONE), table, (false, false)).expect("table"),
        )
    }

    /// The chain against the CPU reference (`ColorPipeline::process_at`) on 64 x 64 random pixels. Half-float storage between
    /// passes limits the match: error is measured against max(|cpu|, 0.05) (the Swift normalized error, <= 2 passes).
    fn compare(name: &str, p: &ColorPipeline) -> Option<f32> {
        let gpu = gpu()?;
        let (w, h) = (64u32, 64u32);
        let px = pixels((w * h) as usize);
        let tex = upload_rgba16f(&gpu, w, h, &px);
        let chain = GpuColorChain::new(&gpu);
        let mut cmds = gpu.commands();
        chain.encode(&mut cmds, p, &tex, false).expect("encode");
        gpu.submit_and_wait(cmds).expect("submit");
        let got = read_rgba16f(&gpu, &tex);
        let mut worst = 0f32;
        for i in 0..(w * h) as usize {
            let uv = [((i as u32 % w) as f32 + 0.5) / w as f32, ((i as u32 / w) as f32 + 0.5) / h as f32];
            // The texture holds half floats: the CPU side starts from the same rounded input.
            let q = |v: f32| f16_to_f32(f32_to_f16(v));
            let src = Vec3::new(q(px[i * 4]), q(px[i * 4 + 1]), q(px[i * 4 + 2]));
            let cpu = p.process_at(src, uv, w as f32 / h as f32);
            for (c, v) in [cpu.x, cpu.y, cpu.z].into_iter().enumerate() {
                let g = got[i * 4 + c];
                worst = worst.max((g - v).abs() / v.abs().max(0.05));
            }
            assert!((got[i * 4 + 3] - 0.75).abs() < 1e-3, "{name}: alpha not passed through");
        }
        sq_os::errln!("{name}: worst normalized error {worst}");
        Some(worst)
    }

    fn basic() -> BasicCorrection {
        BasicCorrection {
            exposure: 0.6,
            contrast: 25.0,
            saturation: 115.0,
            temperature: 12.0,
            ..BasicCorrection::default()
        }
    }

    #[test]
    fn the_chain_matches_the_cpu_reference() {
        let conv = |s| ColorPipeline::new(s, vec![ColorOp::Conversion(None)], ToneMapping::default());
        let chains: Vec<(&str, ColorPipeline)> = vec![
            ("709 identity", conv(ColorSpaceID::Rec709)),
            ("slog3 conversion", conv(ColorSpaceID::SLog3SGamut3Cine)),
            ("hlg conversion", conv(ColorSpaceID::HlgBT2020)),
            (
                "project chain",
                ColorPipeline::new(
                    ColorSpaceID::SLog3SGamut3Cine,
                    vec![
                        ColorOp::Conversion(None),
                        ColorOp::Basic(basic()),
                        ColorOp::Look(look(), 0.8),
                        ColorOp::Curves(RGBCurves::default()),
                    ],
                    ToneMapping::default(),
                ),
            ),
            (
                "two LUTs, pre-conversion block, vignette",
                ColorPipeline::new(
                    ColorSpaceID::VLogVGamut,
                    vec![
                        ColorOp::Basic(basic()),
                        ColorOp::Conversion(Some(look())),
                        ColorOp::Look(look(), 1.0),
                        ColorOp::Vignette(Vignette { amount: -1.0, ..Vignette::default() }),
                    ],
                    ToneMapping::default(),
                ),
            ),
        ];
        for (name, p) in &chains {
            if let Some(worst) = compare(name, p) {
                assert!(worst <= 2e-2, "{name}: normalized error {worst}");
            }
        }
    }
}
