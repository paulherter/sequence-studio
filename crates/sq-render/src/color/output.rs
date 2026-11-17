// Swift: OutputTarget.swift, Rec709Output.swift
//! SDR output encoding: Rec.709 1-1-1, and the P3-D65 / Rec.2020 targets with soft gamut compression.

use serde::{Deserialize, Serialize};

use super::gamut::Gamut;
use super::transfer::bt709_oetf;
use super::vec::Vec3;

/// SDR output gamut: Rec.709 (default), P3-D65 or Rec.2020. Working-linear is converted to the target primaries, colors
/// outside the target are compressed softly instead of being clipped, then encoded.
/// shortcut: CPU reference only (as in Swift); the GPU export and monitor path still use [`rec709_encode`]. Wire this in
/// with the output-space picker.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OutputTarget {
    /// Rec.709.
    #[default]
    Rec709,
    /// Display P3 with the D65 white.
    DisplayP3,
    /// Rec.2020 (SDR curve).
    Rec2020,
}

impl OutputTarget {
    /// The target primaries.
    pub fn gamut(self) -> &'static Gamut {
        match self {
            OutputTarget::Rec709 => Gamut::rec709(),
            OutputTarget::DisplayP3 => Gamut::display_p3(),
            OutputTarget::Rec2020 => Gamut::bt2020(),
        }
    }

    /// `working_linear` in `working` primaries to encoded 0...1 in this target (BT.709 OETF; the Rec.2020 SDR curve is
    /// the same).
    pub fn encode(self, working_linear: Vec3, working: &Gamut) -> Vec3 {
        let in_target = working.matrix(self.gamut()).mul_vec(working_linear);
        let compressed = SoftGamutCompression::compress(in_target);
        compressed.clamp(Vec3::ZERO, Vec3::ONE).map(bt709_oetf)
    }
}

/// H.273 / CICP color primaries code of the Rec.709 output tags.
pub const REC709_COLOR_PRIMARIES: u8 = 1;
/// H.273 transfer characteristics code of the Rec.709 output tags.
pub const REC709_TRANSFER_FUNCTION: u8 = 1;
/// H.273 matrix coefficients code of the Rec.709 output tags.
pub const REC709_YCBCR_MATRIX: u8 = 1;

/// Rec.709 1-1-1 output: working-linear, clamp 0...1, BT.709 OETF.
pub fn rec709_encode(working_linear: Vec3) -> Vec3 {
    working_linear.clamp(Vec3::ZERO, Vec3::ONE).map(bt709_oetf)
}

/// Pulls negative (out-of-gamut) channels back toward the gamut along the distance from the brightest channel, which
/// keeps that channel and so the brightness and, to first order, the hue. Distances below `THRESHOLD` pass unchanged;
/// beyond it an extended-Reinhard shoulder maps distance `LIMIT` onto the gamut edge (distance 1) and stays monotonic.
pub struct SoftGamutCompression;

impl SoftGamutCompression {
    /// Distances below this pass unchanged.
    pub const THRESHOLD: f32 = 0.9;
    /// Distance that lands on the gamut edge.
    pub const LIMIT: f32 = 1.5;

    /// Compresses one RGB triple.
    pub fn compress(rgb: Vec3) -> Vec3 {
        let m = rgb.x.max(rgb.y).max(rgb.z);
        if m <= 0.0 {
            return rgb;
        }
        let mut out = rgb;
        for i in 0..3 {
            if rgb[i] < m {
                let d = (m - rgb[i]) / m;
                out[i] = m - Self::compress_distance(d) * m;
            }
        }
        out
    }

    /// The distance curve.
    pub fn compress_distance(d: f32) -> f32 {
        if d <= Self::THRESHOLD {
            return d;
        }
        let room = 1.0 - Self::THRESHOLD;
        let x = (d - Self::THRESHOLD) / room;
        let l = (Self::LIMIT - Self::THRESHOLD) / room;
        let y = x * (1.0 + x / (l * l)) / (1.0 + x);
        Self::THRESHOLD + room * y
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rec709_target_equals_rec709_output_inside_the_gamut() {
        let v = Vec3::new(0.2, 0.5, 0.8);
        let a = OutputTarget::Rec709.encode(v, Gamut::rec709());
        let b = rec709_encode(v);
        for i in 0..3 {
            assert!((a[i] - b[i]).abs() < 1e-5);
        }
    }

    #[test]
    fn compression_keeps_the_brightest_channel_and_is_monotonic() {
        let c = SoftGamutCompression::compress(Vec3::new(1.0, 0.5, -0.4));
        assert_eq!(c.x, 1.0);
        assert!(c.z >= -0.001 && c.z < 0.5);
        let mut last = 0.0;
        for i in 0..200 {
            let y = SoftGamutCompression::compress_distance(i as f32 / 100.0);
            assert!(y >= last);
            last = y;
        }
        assert!((SoftGamutCompression::compress_distance(1.5) - 1.0).abs() < 1e-6);
    }
}
