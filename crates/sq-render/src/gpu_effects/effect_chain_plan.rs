// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Effects/EffectChainPlan.swift (the parts that need no compositor uniforms)
//! The plan of a layer's effect chain: working sizes and pass budgets. Pure.

use crate::effects::gaussian_blur::MAX_SHAPE_CANVAS_PIXELS;
use sq_core_effects::effects_evaluation::{EffectSegment, ImageFilter};

/// The blur (layer px) from which a chain works at half size at any scale. 3, not 2: at 2 px a 1 px pattern still differs
/// visibly between the two sizes, and a blur keyframed through the threshold would step there.
pub const STRONG_BLUR_PIXELS: f64 = 3.0;

pub use crate::compositor::uniforms::lin;

/// Working-texture pixel cap of a pass: Long Shadow and Outline can ask for a huge margin (length / width up to thousands of
/// px), so their margin is held to `MAX_SHAPE_CANVAS_PIXELS` (the picture keeps its size); others are not capped.
pub fn pixel_budget(seg: &EffectSegment) -> i64 {
    match seg.filter {
        Some(ImageFilter::LongShadow { .. } | ImageFilter::Outline { .. }) => MAX_SHAPE_CANVAS_PIXELS,
        _ => i64::MAX,
    }
}

/// A pass whose look does not depend on the working resolution: a blur, a shadow, or a filter that smears or moves the picture.
/// Sharpen, Noise, Grain, Mosaic and the per-pixel looks stay at full size.
pub fn works_at_reduced_size(seg: &EffectSegment) -> bool {
    if seg.shadow.is_some() {
        return true;
    }
    match &seg.filter {
        None => seg.blur_after > 0.0,
        Some(f) => matches!(
            f,
            ImageFilter::DirectionalBlur { .. }
                | ImageFilter::Glow { .. }
                | ImageFilter::RadialBlur { .. }
                | ImageFilter::Mirror { .. }
                | ImageFilter::Flip { .. }
                | ImageFilter::Outline { .. }
                | ImageFilter::LongShadow { .. }
        ),
    }
}

/// The working size of a multi-pass chain (`segs`, the last one is the draw into the canvas), as 1/factor of the layer.
/// `display`: `effectWorkFactor` of the layer. A plain blur of `STRONG_BLUR_PIXELS` layer px or more keeps nothing a half-size
/// picture cannot hold, so it works at half size at any scale; the other softening passes follow the display size; any other
/// pass keeps the whole chain at full size. `strong_blur_halves`: false keeps the blur rule to the display size too.
pub fn effect_chain_factor(segs: &[EffectSegment], display: i64, strong_blur_halves: bool) -> i64 {
    let mut f = 2;
    for seg in segs.iter().take(segs.len().saturating_sub(1)) {
        let plain_blur = seg.shadow.is_none() && seg.filter.is_none() && seg.blur_after > 0.0;
        let allowed = if plain_blur && strong_blur_halves && seg.blur_after >= STRONG_BLUR_PIXELS {
            2
        } else if works_at_reduced_size(seg) {
            display
        } else {
            1
        };
        f = f.min(allowed);
    }
    f
}

/// Texture px the Repeat Edge Pixels blur clamps its reads to: the fully covered px of a `frame`-sized picture centered in a
/// `texture`-sized image (a partly covered rim px is not repeated; the next draw cuts the frame edge antialiased). Returns
/// `(lo, hi)`.
pub fn repeat_edge_rect(frame: [f32; 2], texture: [i32; 2]) -> ([i32; 2], [i32; 2]) {
    let mut lo = [0; 2];
    let mut hi = [0; 2];
    for axis in 0..2 {
        let t = texture[axis] as f32;
        let (a, b) = ((t - frame[axis]) / 2.0, (t + frame[axis]) / 2.0);
        let l = (a - 1e-3).ceil() as i32;
        let h = (b + 1e-3).floor() as i32 - 1;
        let max = texture[axis] - 1;
        lo[axis] = l.clamp(0, max);
        hi[axis] = h.max(l).clamp(0, max);
    }
    (lo, hi)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn blur(sigma: f64) -> EffectSegment {
        EffectSegment { blur_after: sigma, ..EffectSegment::default() }
    }

    #[test]
    fn lin_inverts_the_709_encoding() {
        assert_eq!(lin(0.0), 0.0);
        assert!((lin(1.0) - 1.0).abs() < 1e-6);
        assert!((lin(0.45) - 0.2140).abs() < 1e-3);
    }

    #[test]
    fn strong_blurs_halve_the_chain_and_a_sharpen_keeps_it_full_size() {
        let last = EffectSegment::default();
        assert_eq!(effect_chain_factor(&[blur(3.0), last.clone()], 1, true), 2);
        assert_eq!(effect_chain_factor(&[blur(2.0), last.clone()], 1, true), 1);
        assert_eq!(effect_chain_factor(&[blur(3.0), last.clone()], 1, false), 1);
        let sharpen = EffectSegment { filter: Some(ImageFilter::Sharpen { amount: 1.0 }), ..EffectSegment::default() };
        assert_eq!(effect_chain_factor(&[blur(9.0), sharpen, last], 2, true), 1);
    }

    #[test]
    fn budget_caps_only_shape_passes() {
        let long = EffectSegment {
            filter: Some(ImageFilter::LongShadow {
                angle: 0.0,
                length: 10.0,
                color: [0.0; 3],
                fade: 0.0,
                opacity: 1.0,
            }),
            ..EffectSegment::default()
        };
        assert_eq!(pixel_budget(&long), MAX_SHAPE_CANVAS_PIXELS);
        assert_eq!(pixel_budget(&blur(4.0)), i64::MAX);
    }

    #[test]
    fn repeat_edge_rect_keeps_the_fully_covered_pixels() {
        // A 10 x 6 picture centered in 16 x 12: covered columns 3...12, rows 3...8.
        assert_eq!(repeat_edge_rect([10.0, 6.0], [16, 12]), ([3, 3], [12, 8]));
    }
}
