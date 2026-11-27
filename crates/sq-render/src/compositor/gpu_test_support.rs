//! Helpers of the GPU tests: the shared device (tests skip with a note when the machine has no adapter) and half-float
//! conversion. Half floats store round toward zero on both backends (g2 report), so the CPU side of a comparison does the same.

use std::sync::{Arc, OnceLock};

use sq_gpu::frames::GpuTexture;
use sq_gpu::gpu::Gpu;
use sq_gpu::layout::PixelFormat;

pub(crate) fn gpu() -> Option<Arc<Gpu>> {
    static GPU: OnceLock<Option<Arc<Gpu>>> = OnceLock::new();
    GPU.get_or_init(|| match Gpu::new() {
        Ok(g) => {
            sq_os::errln!("adapter: {} ({:?})", g.info().name, g.info().backend);
            Some(g)
        }
        Err(e) => {
            sq_os::errln!("skipping GPU tests: {e}");
            None
        }
    })
    .clone()
}

/// Round to nearest even (uploads).
pub(crate) fn f32_to_f16(v: f32) -> u16 {
    let x = v.to_bits();
    let sign = ((x >> 16) & 0x8000) as u16;
    let exp = ((x >> 23) & 0xff) as i32;
    let mant = x & 0x7f_ffff;
    if exp == 255 {
        return sign | 0x7c00 | if mant != 0 { 0x200 } else { 0 };
    }
    let e = exp - 127 + 15;
    if e >= 31 {
        return sign | 0x7c00;
    }
    if e <= 0 {
        if e < -10 {
            return sign;
        }
        let m = mant | 0x80_0000;
        let shift = (14 - e) as u32;
        let half = 1u32 << (shift - 1);
        let mut r = m >> shift;
        let rem = m & ((1 << shift) - 1);
        if rem > half || (rem == half && (r & 1) == 1) {
            r += 1;
        }
        return sign | r as u16;
    }
    let mut r = ((e as u32) << 10) | (mant >> 13);
    let rem = mant & 0x1fff;
    if rem > 0x1000 || (rem == 0x1000 && (r & 1) == 1) {
        r += 1;
    }
    sign | r as u16
}

pub(crate) fn f16_to_f32(h: u16) -> f32 {
    let sign = if h & 0x8000 != 0 { -1.0f32 } else { 1.0 };
    let exp = i32::from((h >> 10) & 0x1f);
    let mant = f32::from(h & 0x3ff);
    match exp {
        0 => sign * mant * 2f32.powi(-24),
        31 => {
            if mant == 0.0 {
                sign * f32::INFINITY
            } else {
                f32::NAN
            }
        }
        _ => sign * (1.0 + mant / 1024.0) * 2f32.powi(exp - 15),
    }
}

/// A half-float texture holding `rgba` (4 floats per texel).
pub(crate) fn upload_rgba16f(gpu: &Gpu, w: u32, h: u32, rgba: &[f32]) -> GpuTexture {
    let t = gpu.texture(w, h, PixelFormat::Rgba16Float);
    let bytes: Vec<u8> = rgba.iter().flat_map(|v| f32_to_f16(*v).to_le_bytes()).collect();
    gpu.upload_texture(&t, &bytes, w * 8);
    t
}

/// The floats of a half-float texture.
pub(crate) fn read_rgba16f(gpu: &Arc<Gpu>, t: &GpuTexture) -> Vec<f32> {
    let bytes = gpu.read_texture(t).unwrap_or_default();
    bytes.as_chunks::<2>().0.iter().map(|c| f16_to_f32(u16::from_le_bytes(*c))).collect()
}
