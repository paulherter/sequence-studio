// Swift: FrameSampler.swift
//! Readback of the Program composite for the eyedropper, Auto and the look thumbnail: the pure parts (the magnifier
//! grid, display encodings, 8-bit conversion). The capture itself is the host's: `ProgramFrameSampling` answers with
//! working-linear Rec. 709 samples, and the Mac-only Metal readback is not ported.
//!
//! The BT.709 curve is written out here (the render crate is not a dependency of the session); it matches
//! `sq_render::color::transfer::bt709_oetf`.

/// The pixels around the pointer during a color pick, linear RGB, row-major. At the picture edge the patch is cut, so
/// `center_x/center_y` name the cell under the pointer.
// Swift: FrameSampler.swift:11
#[derive(Clone, Debug, PartialEq)]
pub struct MagnifierGrid {
    // Swift: FrameSampler.swift:12
    pub width: usize,
    // Swift: FrameSampler.swift:12
    pub height: usize,
    // Swift: FrameSampler.swift:13
    pub linear: Vec<[f32; 3]>,
    // Swift: FrameSampler.swift:14
    pub center_x: usize,
    // Swift: FrameSampler.swift:14
    pub center_y: usize,
}

impl MagnifierGrid {
    // Swift: FrameSampler.swift:15
    pub fn new(width: usize, height: usize, linear: Vec<[f32; 3]>, center_x: usize, center_y: usize) -> MagnifierGrid {
        MagnifierGrid { width, height, linear, center_x, center_y }
    }

    /// The cell under the pointer.
    // Swift: FrameSampler.swift:20
    pub fn center(&self) -> [f32; 3] {
        self.linear.get(self.center_y * self.width + self.center_x).copied().unwrap_or([0.0; 3])
    }

    /// "R 12  G 200  B 7": the 8-bit display values of the center cell.
    // Swift: FrameSampler.swift:26
    pub fn readout(&self) -> String {
        let b = FrameSampler::display8(self.center());
        format!("R {}  G {}  B {}", b[0], b[1], b[2])
    }
}

use crate::ProgramFrameSampling;

/// An 8-bit RGBA picture (alpha opaque), rows top down.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RgbaImage {
    pub width: usize,
    pub height: usize,
    pub rgba: Vec<u8>,
}

/// Namespace of the frame-sampler helpers.
pub enum FrameSampler {}

fn bt709_oetf(v: f32) -> f32 {
    let (alpha, beta) = (1.099_296_8_f32, 0.018_053_97_f32);
    let l = v.clamp(0.0, 1.0);
    if l < beta { 4.5 * l } else { alpha * l.powf(0.45) - (alpha - 1.0) }
}

impl FrameSampler {
    /// Mean linear RGB of a (2 * radius + 1) squared patch around `position` (0...1, y down); 5 x 5 like Premiere's
    /// eyedropper.
    // Swift: FrameSampler.swift:43
    pub fn sample_color(sampler: &mut dyn ProgramFrameSampling, position: [f64; 2], radius: i64) {
        sampler.sample_patch(position, radius, "color.pick");
    }

    /// The composite scaled to about `width` px as linear RGB samples (Auto) or an sRGB image (look thumbnail). The
    /// answer arrives later through the host's inbox under `key`.
    // Swift: FrameSampler.swift:56
    pub fn sample_scaled(sampler: &mut dyn ProgramFrameSampling, width: i64, key: &str) {
        sampler.sample_linear(width, key);
    }

    /// Display luma (BT.709-encoded, 0...1, unclamped above 1 up to 4) of linear samples: the statistics for Auto.
    // Swift: FrameSampler.swift:69
    pub fn display_luma(linear: &[[f32; 3]]) -> Vec<f32> {
        linear
            .iter()
            .map(|c| {
                let luma = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
                // The curve is evaluated above 1 here (Auto looks at highlights), so no clamp to 1 inside.
                let l = luma.clamp(0.0, 4.0);
                let (alpha, beta) = (1.099_296_8_f32, 0.018_053_97_f32);
                if l < beta { 4.5 * l } else { alpha * l.powf(0.45) - (alpha - 1.0) }
            })
            .collect()
    }

    /// Display RGB (BT.709-encoded per channel, 0...1) of linear samples: what Color Match measures.
    // Swift: FrameSampler.swift:75
    pub fn display_rgb(linear: &[[f32; 3]]) -> Vec<[f32; 3]> {
        linear.iter().map(|c| [bt709_oetf(c[0]), bt709_oetf(c[1]), bt709_oetf(c[2])]).collect()
    }

    /// 0...1 to 0...255, rounded; NaN (a broken pixel or LUT output) becomes 0.
    fn byte(v: f32) -> u8 {
        if v.is_nan() { 0 } else { (v.clamp(0.0, 1.0) * 255.0 + 0.5) as u8 }
    }

    /// Working-linear Rec.709 to 8-bit display values (clamped, BT.709 encoded like the monitor path).
    // Swift: FrameSampler.swift:166
    pub fn display8(linear: [f32; 3]) -> [u8; 3] {
        let e = |v: f32| Self::byte(bt709_oetf(v));
        [e(linear[0]), e(linear[1]), e(linear[2])]
    }

    /// sRGB image of linear samples (the look thumbnail); `None` when the sample count does not fit the size.
    // Swift: FrameSampler.swift:149
    pub fn image(width: usize, height: usize, linear: &[[f32; 3]]) -> Option<RgbaImage> {
        if linear.len() != width * height || width == 0 || height == 0 {
            return None;
        }
        let mut rgba = vec![255u8; width * height * 4];
        for (i, px) in linear.iter().enumerate() {
            let p = Self::display8(*px);
            rgba[i * 4..i * 4 + 3].copy_from_slice(&p);
        }
        Some(RgbaImage { width, height, rgba })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display8_encodes_with_the_709_curve_and_survives_nan() {
        assert_eq!(FrameSampler::display8([0.0, 1.0, 5.0]), [0, 255, 255]);
        assert_eq!(FrameSampler::display8([0.18, f32::NAN, -1.0]), [104, 0, 0]);
    }

    #[test]
    fn readout_names_the_center_cell() {
        let g = MagnifierGrid::new(2, 1, vec![[0.0; 3], [1.0, 0.0, 0.18]], 1, 0);
        assert_eq!(g.readout(), "R 255  G 0  B 104");
        assert_eq!(MagnifierGrid::new(1, 1, vec![], 5, 5).center(), [0.0; 3]);
    }

    #[test]
    fn luma_goes_above_one_for_highlights_and_rgb_stays_in_range() {
        let l = FrameSampler::display_luma(&[[1.0; 3], [3.0; 3], [9.0; 3]]);
        assert!((l[0] - 1.0).abs() < 1e-5 && l[1] > 1.0);
        assert!((l[2] - 1.099_296_8 * 4f32.powf(0.45) + 0.099_296_8).abs() < 1e-4); // 9.0 clamps to 4.0 before the curve
        let rgb = FrameSampler::display_rgb(&[[2.0, -1.0, 0.0]]);
        assert_eq!(rgb[0], [1.0, 0.0, 0.0]);
    }

    #[test]
    fn image_needs_matching_dimensions() {
        let px = vec![[1.0, 1.0, 1.0]; 4];
        let img = FrameSampler::image(2, 2, &px).expect("fits");
        assert_eq!(img.rgba.len(), 16);
        assert_eq!(&img.rgba[..4], &[255, 255, 255, 255]);
        assert!(FrameSampler::image(3, 2, &px).is_none());
        assert!(FrameSampler::image(0, 0, &[]).is_none());
    }
}
