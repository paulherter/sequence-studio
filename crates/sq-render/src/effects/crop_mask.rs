// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Effects/CropMask.swift
//! Crop and Rounded Corners as one coverage mask on the layer rectangle: the CPU reference of the mask in the compositor
//! fragment shader (signed distance to a rounded rectangle, one pixel anti-aliasing ramp, widened inwards by `feather`).

use super::simd::{Float2, Float4};
use sq_core_effects::effects_evaluation::CropInsets;

/// The kept rectangle in layer-local coordinates (origin at the layer center, y down): `(lo, hi)`.
pub fn kept_rect(size: Float2, crop: &CropInsets) -> (Float2, Float2) {
    let lo = size * -0.5 + Float2::new(crop.left as f32, crop.top as f32) * size;
    let hi = size * 0.5 - Float2::new(crop.right as f32, crop.bottom as f32) * size;
    (lo, hi)
}

/// Signed distance (layer px, negative inside) of `p` to the kept rectangle with rounded corners.
pub fn signed_distance(p: Float2, size: Float2, crop: &CropInsets, corner_radius: f32, round_first: bool) -> f32 {
    let (lo, hi) = kept_rect(size, crop);
    let c = (lo + hi) * 0.5;
    let h = (hi - lo) * 0.5;
    if round_first {
        // Rounded Corners, then Crop: the rounded full frame intersected with the straight crop rectangle.
        let d0 = signed_distance(p, size, &CropInsets::NONE, corner_radius, false);
        let q1 = (p - c).abs() - h;
        let d1 = q1.max(Float2::ZERO).length() + q1.x.max(q1.y).min(0.0);
        return d0.max(d1);
    }
    let r = corner_radius.min(h.x.min(h.y));
    let q = (p - c).abs() - h + Float2::splat(r);
    let outside = q.max(Float2::ZERO).length();
    outside + q.x.max(q.y).min(0.0) - r
}

/// Coverage 0...1 at `p` for an axis-aligned layer drawn at scale 1 (one layer px per screen px). `feather` (layer px)
/// widens the ramp inwards: 0 outside, full `feather` + 0.5 px inside the edge (0 = the one pixel edge).
pub fn coverage(
    p: Float2,
    size: Float2,
    crop: &CropInsets,
    corner_radius: f32,
    round_first: bool,
    feather: f32,
) -> f32 {
    let d = signed_distance(p, size, crop, corner_radius, round_first);
    ((0.5 - d) / (1.0 + feather.max(0.0))).clamp(0.0, 1.0)
}

/// The mask settings of `apply`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CropSettings {
    /// Crop insets.
    pub crop: CropInsets,
    /// Corner radius in layer px.
    pub corner_radius: f32,
    /// Rounded Corners applied before the crop.
    pub round_first: bool,
    /// Crop Softness in layer px.
    pub feather: f32,
}

/// Applies the mask to premultiplied pixels (row-major, `width` x `height`), pixel centers sampled. Identity crop and radius
/// 0 touch nothing.
pub fn apply(px: &mut [Float4], width: usize, height: usize, s: &CropSettings) {
    if s.crop.is_identity() && s.corner_radius <= 0.0 && s.feather <= 0.0 {
        return;
    }
    let size = Float2::new(width as f32, height as f32);
    for y in 0..height {
        for x in 0..width {
            let p = Float2::new(x as f32 + 0.5, y as f32 + 0.5) - size * 0.5;
            let k = coverage(p, size, &s.crop, s.corner_radius, s.round_first, s.feather);
            px[y * width + x] *= k;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SIZE: Float2 = Float2::new(100.0, 60.0);

    #[test]
    fn identity_touches_nothing() {
        let mut px = vec![Float4::new(0.2, 0.4, 0.6, 1.0); 12];
        let s = CropSettings { crop: CropInsets::NONE, corner_radius: 0.0, round_first: false, feather: 0.0 };
        apply(&mut px, 4, 3, &s);
        assert!(px.iter().all(|p| *p == Float4::new(0.2, 0.4, 0.6, 1.0)));
    }

    #[test]
    fn crop_edge_has_a_one_pixel_ramp() {
        let crop = CropInsets { left: 0.1, top: 0.0, right: 0.0, bottom: 0.0 };
        // Kept rect starts at x = -50 + 10 = -40.
        assert_eq!(coverage(Float2::new(-39.5, 0.0), SIZE, &crop, 0.0, false, 0.0), 1.0);
        assert_eq!(coverage(Float2::new(-40.5, 0.0), SIZE, &crop, 0.0, false, 0.0), 0.0);
        assert!((coverage(Float2::new(-40.0, 0.0), SIZE, &crop, 0.0, false, 0.0) - 0.5).abs() < 1e-6);
        // Feather widens the ramp inwards.
        let k = coverage(Float2::new(-39.0, 0.0), SIZE, &crop, 0.0, false, 4.0);
        assert!(k > 0.0 && k < 1.0);
    }

    #[test]
    fn rounded_corner_cuts_the_corner_only() {
        let corner = Float2::new(49.5, 29.5);
        assert!(coverage(corner, SIZE, &CropInsets::NONE, 20.0, false, 0.0) < 0.01);
        assert_eq!(coverage(Float2::ZERO, SIZE, &CropInsets::NONE, 20.0, false, 0.0), 1.0);
        assert_eq!(coverage(corner, SIZE, &CropInsets::NONE, 0.0, false, 0.0), 1.0);
    }

    #[test]
    fn round_first_keeps_the_straight_crop_edges() {
        let crop = CropInsets { left: 0.2, top: 0.0, right: 0.0, bottom: 0.0 };
        let p = Float2::new(-29.5, 0.0);
        // Rounded frame first: the crop edge at x = -30 stays straight, so a point just inside it is covered.
        assert_eq!(coverage(p, SIZE, &crop, 10.0, true, 0.0), 1.0);
        // Crop first rounds the cropped rectangle's own corners.
        let corner = Float2::new(-29.5, 29.5);
        assert!(coverage(corner, SIZE, &crop, 10.0, false, 0.0) < 0.2);
    }
}
