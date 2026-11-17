// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MotionBlurNode.swift
//! W7.1 motion blur of one leaf layer: one copy per sub-frame transform, each at 1/n of the layer's opacity. This is the
//! transform part of `RenderNode.motionBlurred`; building the render node waits for `RenderLayer` (NOTES-effects.md).

use sq_core_model::ClipTransform;
use sq_core_time::Vec2;

fn ratio(a: f64, b: f64) -> f64 {
    if b != 0.0 { a / b } else { 1.0 }
}

/// The transform of one motion blur sample. `sample` is the sub-frame transform, `base` the transform the sample set was
/// made for (the request's) and `actual` the layer's own: the caller's adjustments of the request's transform (a text box
/// offset, say) are carried onto every sample. `count` samples share the layer's opacity (clamped to 0...1) equally.
pub fn sample_transform(
    sample: &ClipTransform,
    base: &ClipTransform,
    actual: &ClipTransform,
    count: usize,
) -> ClipTransform {
    let mut t = *sample;
    if actual != base {
        t.position = sample.position + (actual.position - base.position);
        t.scale = Vec2::new(
            sample.scale.x * ratio(actual.scale.x, base.scale.x),
            sample.scale.y * ratio(actual.scale.y, base.scale.y),
        );
        t.rotation = sample.rotation + (actual.rotation - base.rotation);
        t.anchor = sample.anchor + (actual.anchor - base.anchor);
        t.tilt_x = sample.tilt_x + (actual.tilt_x - base.tilt_x);
        t.tilt_y = sample.tilt_y + (actual.tilt_y - base.tilt_y);
    }
    t.opacity = actual.opacity.clamp(0.0, 1.0) / count as f64;
    t
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unchanged_layer_only_splits_the_opacity() {
        let base = ClipTransform::IDENTITY;
        let mut s = base;
        s.position = Vec2::new(4.0, 0.0);
        let t = sample_transform(&s, &base, &base, 4);
        assert_eq!((t.position, t.opacity), (Vec2::new(4.0, 0.0), 0.25));
    }

    #[test]
    fn the_callers_adjustment_is_carried_onto_the_sample() {
        let base = ClipTransform::IDENTITY;
        let mut actual = base;
        actual.position = Vec2::new(10.0, 5.0);
        actual.scale = Vec2::new(2.0, 2.0);
        actual.rotation = 30.0;
        actual.opacity = 1.5;
        let mut s = base;
        s.position = Vec2::new(1.0, 1.0);
        s.scale = Vec2::new(0.5, 0.5);
        let t = sample_transform(&s, &base, &actual, 2);
        assert_eq!(t.position, Vec2::new(11.0, 6.0));
        assert_eq!(t.scale, Vec2::new(1.0, 1.0));
        assert_eq!((t.rotation, t.opacity), (30.0, 0.5));
        // A zero base scale leaves the sample's scale alone.
        let mut zero = base;
        zero.scale = Vec2::ZERO;
        assert_eq!(sample_transform(&s, &zero, &actual, 1).scale, Vec2::new(0.5, 0.5));
    }
}
