// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ColorRangeKey.swift
//! v87 Color range mask: the pixels of the clip's own picture near a picked color. The color is display-encoded
//! Rec.709 (what the eyedropper and the swatch show), 0...1; the distance is the Euclidean RGB distance of
//! display-encoded straight colors divided by sqrt(3) (so 0...1). Coverage is 1 up to `tolerance`, then falls with a
//! smoothstep over `softness` (0 = hard edge). CPU reference of the compositor's `colorRangeValue` (same steps).

use sq_core_model::ColorRangeKey;

/// The coverage maths of [`ColorRangeKey`].
pub trait ColorRangeKeyExt {
    /// Coverage 0...1 of a display-encoded straight color (before invert and opacity).
    fn value(&self, red: f64, green: f64, blue: f64) -> f64;
}

impl ColorRangeKeyExt for ColorRangeKey {
    fn value(&self, r: f64, g: f64, b: f64) -> f64 {
        let (dr, dg, db) = (r - self.red, g - self.green, b - self.blue);
        let d = (dr * dr + dg * dg + db * db).sqrt() / 3.0_f64.sqrt();
        if self.softness <= 1e-6 {
            return if d <= self.tolerance { 1.0 } else { 0.0 };
        }
        let x = ((d - self.tolerance) / self.softness).clamp(0.0, 1.0);
        1.0 - x * x * (3.0 - 2.0 * x)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn value_is_full_inside_tolerance_and_falls_over_softness() {
        let k = ColorRangeKey::new(0.5, 0.5, 0.5, 0.2, 0.2);
        assert_eq!(k.value(0.5, 0.5, 0.5), 1.0);
        // All three channels off by 0.2 -> distance 0.2 = tolerance exactly: still fully covered.
        let e = 0.2 * 3.0_f64.sqrt() / 3.0_f64.sqrt();
        assert_eq!(k.value(0.5 + e, 0.5 + e, 0.5 + e), 1.0);
        // Distance 0.3 = tolerance + softness / 2 -> smoothstep(0.5) = 0.5.
        assert!((k.value(0.8, 0.8, 0.8) - 0.5).abs() < 1e-9);
        assert_eq!(k.value(0.95, 0.95, 0.95), 0.0);
    }

    #[test]
    fn zero_softness_is_a_hard_edge() {
        let k = ColorRangeKey::new(0.0, 1.0, 0.0, 0.1, 0.0);
        assert_eq!(k.value(0.0, 1.0, 0.0), 1.0);
        assert_eq!(k.value(0.0, 0.0, 0.0), 0.0);
    }
}
