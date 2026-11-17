// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: KeyColorPick.swift
//! Color Key eyedropper: the Key Hue (degrees) of a picked color. The keyer measures hue on the un-premultiplied
//! working-linear color, so the picked linear RGB is converted the same way.

/// Below this saturation the hue is noise (gray): nothing is picked.
pub const MIN_SATURATION: f32 = 0.08;
/// Below this brightness the hue is noise (near black): nothing is picked.
pub const MIN_VALUE: f32 = 0.005;

/// Hue 0..<360 of a linear RGB color, or `None` for a gray / black / non-finite pick.
pub fn hue_from_linear(c: [f32; 3]) -> Option<f64> {
    let [x, y, z] = c;
    if !(x.is_finite() && y.is_finite() && z.is_finite()) {
        return None;
    }
    let mx = x.max(y).max(z);
    let mn = x.min(y).min(z);
    let d = mx - mn;
    if !(mx >= MIN_VALUE && d / mx >= MIN_SATURATION) {
        return None;
    }
    let mut h = if mx == x {
        ((y - z) / d) % 6.0
    } else if mx == y {
        (z - x) / d + 2.0
    } else {
        (x - y) / d + 4.0
    };
    h *= 60.0;
    if h < 0.0 {
        h += 360.0;
    }
    Some(f64::from(h.round()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn primaries_and_grays() {
        assert_eq!(hue_from_linear([1.0, 0.0, 0.0]), Some(0.0));
        assert_eq!(hue_from_linear([0.0, 1.0, 0.0]), Some(120.0));
        assert_eq!(hue_from_linear([0.0, 0.0, 1.0]), Some(240.0));
        assert_eq!(hue_from_linear([1.0, 0.0, 1.0]), Some(300.0));
        assert_eq!(hue_from_linear([0.5, 0.5, 0.5]), None);
        assert_eq!(hue_from_linear([0.001, 0.0, 0.0]), None);
        assert_eq!(hue_from_linear([f32::NAN, 0.0, 0.0]), None);
    }
}
