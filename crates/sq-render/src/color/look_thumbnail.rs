// Swift: LookThumbnail.swift
//! Look thumbnails rendered on one fixed procedural test picture, so every look is comparable at a glance and the
//! thumbnail never needs user footage. The picture (display-encoded Rec.709): a vertical sky gradient on top, a skin patch
//! and six saturated chips in the middle, an 11-step gray ramp at the bottom. Rendering runs the CPU reference pipeline.

use std::sync::Arc;

use super::cube_lut::CubeLut;
use super::pipeline::{ColorOp, ColorPipeline};
use super::source_space::SourceColorSpace;
use super::tone_mapping::ToneMapping;
use super::transfer::bt709_oetf;
use super::vec::Vec3;

/// Thumbnail width.
pub const WIDTH: usize = 256;
/// Thumbnail height.
pub const HEIGHT: usize = 144;

const SKIN: Vec3 = Vec3::new(0.85, 0.63, 0.50);
const CHIPS: [Vec3; 6] = [
    Vec3::new(0.85, 0.10, 0.10),
    Vec3::new(0.90, 0.85, 0.10),
    Vec3::new(0.08, 0.72, 0.12),
    Vec3::new(0.10, 0.75, 0.85),
    Vec3::new(0.12, 0.15, 0.85),
    Vec3::new(0.80, 0.12, 0.75),
];
const SKY_TOP: Vec3 = Vec3::new(0.10, 0.25, 0.62);
const SKY_HORIZON: Vec3 = Vec3::new(0.72, 0.84, 0.95);

/// The test picture as display-encoded Rec.709 colors, row by row from the top.
pub fn test_picture(width: usize, height: usize) -> Vec<Vec3> {
    let mut out = vec![Vec3::ZERO; width.max(1) * height.max(1)];
    for y in 0..height {
        let v = if height > 1 { y as f32 / (height - 1) as f32 } else { 0.0 };
        for x in 0..width {
            let c = if v < 0.45 {
                // simd_mix(a, b, t) = a + (b - a) * t
                SKY_TOP + (SKY_HORIZON - SKY_TOP) * Vec3::splat(v / 0.45)
            } else if v < 0.8 {
                let cell = (x * 7 / width).min(6);
                if cell == 0 { SKIN } else { CHIPS[cell - 1] }
            } else {
                Vec3::splat((x * 11 / width).min(10) as f32 / 10.0)
            };
            out[y * width + x] = c;
        }
    }
    out
}

/// A channel as a byte (NaN is 0).
pub fn byte(v: f32) -> u8 {
    if v.is_nan() { 0 } else { (v.clamp(0.0, 1.0) * 255.0 + 0.5) as u8 }
}

/// RGBA8 (alpha 255) of the test picture through `lut` at `intensity` (`None` = the picture unchanged).
pub fn render(lut: Option<&Arc<CubeLut>>, intensity: f32, width: usize, height: usize) -> Vec<u8> {
    let pic = test_picture(width, height);
    let pipe = lut.map(|l| {
        ColorPipeline::new(
            SourceColorSpace::Rec709,
            vec![ColorOp::Conversion(None), ColorOp::Look(Arc::clone(l), intensity)],
            ToneMapping::default(),
        )
    });
    let mut bytes = vec![255u8; pic.len() * 4];
    for (i, p) in pic.iter().enumerate() {
        let mut rgb = *p;
        if let Some(pipe) = &pipe {
            rgb = pipe.process(*p).clamp(Vec3::ZERO, Vec3::ONE).map(bt709_oetf);
        }
        bytes[i * 4] = byte(rgb.x);
        bytes[i * 4 + 1] = byte(rgb.y);
        bytes[i * 4 + 2] = byte(rgb.z);
    }
    bytes
}
