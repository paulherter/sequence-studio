// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: LayerOcclusion.swift
//! Layers nobody can see: everything composited under an opaque picture that fills the canvas. Export leaves such layers
//! out (no decode, no grade); the output is the same picture, so the rule is deliberately narrow and only says "hidden"
//! when that is certain.

use super::{LayerGroup, LayerRequest};
use crate::effects_evaluation::ClipEffects;
use sq_core_model::{BlendMode, ClipTransform, SequenceFormat, TimeInterpolation};
use std::collections::BTreeSet;

/// Upright size in pixels of a source known to carry no transparency (the size its layer is drawn at for Scale 1).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Picture {
    /// Width in px.
    pub width: i64,
    /// Height in px.
    pub height: i64,
}

/// What `LayerOcclusion::evaluate` found.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct OcclusionResult {
    /// Indices into the evaluated layers that cannot show.
    pub hidden: BTreeSet<usize>,
    /// Index of the layer that hides them; `None` = nothing is hidden. The caller checks that this layer really is drawn
    /// as assumed (frame decoded, size as given) and draws everything otherwise.
    pub cover: Option<usize>,
}

/// The hidden-layer rule.
pub enum LayerOcclusion {}

fn plain_effects() -> ClipEffects {
    ClipEffects::with_corner_radius(0.0)
}

fn is_plain_transform(t: &ClipTransform) -> bool {
    t.opacity >= 1.0 && t.rotation == 0.0 && !t.is_tilted() && t.scale.x > 0.0 && t.scale.y > 0.0
}

fn is_plain(l: &LayerRequest) -> bool {
    is_plain_transform(&l.transform)
        && l.blend_mode == BlendMode::Normal
        && l.corner_radius == 0.0
        && l.effects == plain_effects()
        && l.pair.is_none()
        && !l.in_transition
        && l.stack_transitions.is_empty()
        && l.motion_blur.is_none()
        && l.gyro.is_none()
        && l.shape.is_none()
        // C6: a matte layer is not drawn into the picture, so it covers nothing.
        && l.matte_for.is_none()
        // Frame Blending / Optical Flow need a second frame; without it the layer is a placeholder that covers nothing.
        && l.interpolation == TimeInterpolation::FrameSampling
}

fn is_plain_group(g: &LayerGroup) -> bool {
    is_plain_transform(&g.transform)
        && g.blend_mode == BlendMode::Normal
        && g.corner_radius == 0.0
        && g.effects == plain_effects()
}

/// The layer may be left out when covered.
fn can_drop(l: &LayerRequest) -> bool {
    l.generator.is_none()
        && l.pair.is_none()
        && !l.in_transition
        && l.stack_transitions.is_empty()
        && l.matte_for.is_none()
        && l.effects.temporal.is_none()
        && !l.effects.needs_subject_matte()
        && l.effects.magic_mattes().is_empty()
}

/// The rectangle of a `width` x `height` picture under `t` (no rotation) reaches all four edges of `canvas`. Same geometry
/// as the compositor: center = canvas center + position, corners = (+-size / 2 - anchor) * scale.
fn fills(t: &ClipTransform, width: i64, height: i64, canvas: &SequenceFormat) -> bool {
    let (cw, ch, w, h) = (canvas.display_width() as f64, canvas.height as f64, width as f64, height as f64);
    if !(w > 0.0 && h > 0.0 && cw > 0.0 && ch > 0.0) {
        return false;
    }
    let x0 = cw / 2.0 + t.position.x + (-w / 2.0 - t.anchor.x) * t.scale.x;
    let x1 = cw / 2.0 + t.position.x + (w / 2.0 - t.anchor.x) * t.scale.x;
    let y0 = ch / 2.0 + t.position.y + (-h / 2.0 - t.anchor.y) * t.scale.y;
    let y1 = ch / 2.0 + t.position.y + (h / 2.0 - t.anchor.y) * t.scale.y;
    // Pixel centers lie half a pixel inside the canvas; the tolerance only absorbs rounding of an exact fit.
    let e = 0.01;
    x0 <= e && y0 <= e && x1 >= cw - e && y1 >= ch - e
}

impl LayerOcclusion {
    /// `layers`: `TimelineEvaluation::video_layers`, bottom first. `picture`: the upright size of a media layer's source
    /// when the source is opaque video, `None` when unknown or when it may be transparent.
    ///
    /// A cover is a media layer drawn plainly: Opacity 1, Normal blend, no rotation, no effect of its own (crop, corners,
    /// masks, keys, blur, shadow, stabilizer, motion blur), outside every transition, whose rectangle reaches all four
    /// canvas edges. Inside nested sequences it must fill the nest's canvas and every enclosing nest must be drawn just as
    /// plainly and fill its parent; a nest that does not still hides what lies below the cover inside it. Hidden are the
    /// media layers below the topmost cover that are plain enough to drop: not part of a transition (a transition
    /// composites its sides apart) and without state carried from frame to frame (denoise, subject mask, tracked masks).
    /// Generators stay: they cost no decode.
    pub fn evaluate(
        layers: &[LayerRequest],
        canvas: &SequenceFormat,
        picture: impl Fn(&LayerRequest) -> Option<Picture>,
    ) -> OcclusionResult {
        if layers.len() <= 1 {
            return OcclusionResult::default();
        }
        for i in (1..layers.len()).rev() {
            let l = &layers[i];
            if l.generator.is_some() || !is_plain(l) {
                continue;
            }
            let Some(p) = picture(l) else { continue };
            let own = l.groups.last().map_or(canvas, |g| &g.format);
            if !fills(&l.transform, p.width, p.height, own) {
                continue;
            }
            // `level`: how many of the enclosing nests (outermost first) do NOT pass the cover on: every nest from there
            // inwards fills its parent, so the cover hides everything below it in the sequence at that level.
            let mut level = l.groups.len();
            while level > 0 {
                let g = &l.groups[level - 1];
                let parent = if level > 1 { &l.groups[level - 2].format } else { canvas };
                if !(is_plain_group(g) && fills(&g.transform, g.format.display_width(), g.format.height, parent)) {
                    break;
                }
                level -= 1;
            }
            let scope: Vec<_> = l.groups.iter().take(level).map(|g| g.clip).collect();
            let mut hidden = BTreeSet::new();
            for (j, other) in layers.iter().enumerate().take(i) {
                if can_drop(other) && other.groups.iter().take(level).map(|g| g.clip).eq(scope.iter().copied()) {
                    hidden.insert(j);
                }
            }
            if !hidden.is_empty() {
                return OcclusionResult { hidden, cover: Some(i) };
            }
            if level == 0 {
                return OcclusionResult::default(); // a full cover with nothing to drop: no cover below it hides more
            }
        }
        OcclusionResult::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::effects_evaluation::{CropInsets, EffectMasks};
    use crate::temporal_effects::{TemporalDenoise, TemporalFilter};
    use sq_core_model::{GeneratorRef, TimeInterpolation};
    use sq_core_time::{Id, Time, Vec2};

    fn canvas() -> SequenceFormat {
        SequenceFormat { width: 1080, height: 1920, ..SequenceFormat::new(Time::new(1, 30)) }
    }

    const UPRIGHT_4K: Picture = Picture { width: 2160, height: 3840 };

    fn id(n: u128) -> Id {
        Id::from_u128(n)
    }

    fn layer(scale: f64, position: Vec2, opacity: f64, rotation: f64, groups: Vec<LayerGroup>) -> LayerRequest {
        let mut l = LayerRequest::new(id(1), id(2), id(3), Time::ZERO);
        l.transform =
            ClipTransform { position, scale: Vec2::new(scale, scale), rotation, opacity, ..ClipTransform::IDENTITY };
        l.groups = groups;
        l
    }

    fn l(scale: f64) -> LayerRequest {
        layer(scale, Vec2::ZERO, 1.0, 0.0, Vec::new())
    }

    fn text() -> LayerRequest {
        let mut t = LayerRequest::new(id(1), id(2), id(3), Time::ZERO);
        t.generator = Some(GeneratorRef { kind: "text".to_string(), payload: Vec::new(), payload_version: 1 });
        t
    }

    fn hidden(layers: &[LayerRequest], picture: Option<Picture>) -> OcclusionResult {
        LayerOcclusion::evaluate(layers, &canvas(), |_| picture)
    }

    fn set(v: &[usize]) -> BTreeSet<usize> {
        v.iter().copied().collect()
    }

    #[test]
    fn a_full_opaque_picture_hides_everything_below_it() {
        let r = hidden(&[l(0.5), l(0.6), l(0.5), text()], Some(UPRIGHT_4K));
        assert_eq!(r.hidden, set(&[0, 1]));
        assert_eq!(r.cover, Some(2));
    }

    #[test]
    fn nothing_is_hidden_under_the_bottom_layer_or_without_a_cover() {
        assert!(hidden(&[l(0.5), text()], Some(UPRIGHT_4K)).hidden.is_empty());
        assert_eq!(hidden(&[l(0.5), text()], Some(UPRIGHT_4K)).cover, None);
        assert!(hidden(&[], Some(UPRIGHT_4K)).hidden.is_empty());
    }

    #[test]
    fn a_picture_that_leaves_canvas_free_hides_nothing() {
        let p = Some(UPRIGHT_4K);
        assert!(hidden(&[l(0.5), l(0.49)], p).hidden.is_empty()); // too small
        assert!(hidden(&[l(0.5), layer(0.5, Vec2::new(1.0, 0.0), 1.0, 0.0, Vec::new())], p).hidden.is_empty());
        // bigger, moved inside its margin
        assert_eq!(hidden(&[l(0.5), layer(0.55, Vec2::new(0.0, -56.0), 1.0, 0.0, Vec::new())], p).hidden, set(&[0]));
        assert!(hidden(&[l(0.5), layer(0.55, Vec2::new(0.0, -120.0), 1.0, 0.0, Vec::new())], p).hidden.is_empty());
    }

    #[test]
    fn anchor_moves_the_picture() {
        let mut a = l(0.5);
        a.transform.anchor = Vec2::new(10.0, 0.0);
        let p = Some(UPRIGHT_4K);
        assert!(hidden(&[l(0.5), a.clone()], p).hidden.is_empty());
        a.transform.scale = Vec2::new(0.6, 0.6);
        assert_eq!(hidden(&[l(0.5), a], p).hidden, set(&[0]));
    }

    #[test]
    fn a_cover_must_be_plain_opaque_and_upright() {
        let p = Some(UPRIGHT_4K);
        let none = |x: LayerRequest| hidden(&[l(0.5), x], p).hidden.is_empty();
        assert!(none(layer(0.5, Vec2::ZERO, 0.99, 0.0, Vec::new())));
        assert!(none(layer(2.0, Vec2::ZERO, 1.0, 3.0, Vec::new())));
        let mut x = l(0.5);
        x.blend_mode = BlendMode::Multiply;
        assert!(none(x));
        let mut x = l(0.5);
        x.effects = ClipEffects::with_corner_radius(20.0);
        x.corner_radius = 20.0;
        assert!(none(x));
        let mut x = l(0.5);
        x.effects = ClipEffects::simple(
            EffectMasks { crop: CropInsets { left: 0.1, ..CropInsets::NONE }, ..EffectMasks::NONE },
            0.0,
            EffectMasks::NONE,
            Vec::new(),
        );
        assert!(none(x));
        let mut x = l(0.5);
        x.in_transition = true;
        assert!(none(x));
        let mut x = l(0.5);
        x.motion_blur = Some(crate::effect_transform_stage::MotionBlurSamples {
            format: canvas(),
            transforms: vec![ClipTransform::IDENTITY],
            local_times: vec![Time::ZERO],
        });
        assert!(none(x));
        // Frame Blending / Optical Flow need a second frame; without it the layer is a placeholder.
        let mut x = l(0.5);
        x.interpolation = TimeInterpolation::FrameBlend;
        assert!(none(x));
        let mut x = l(0.5);
        x.interpolation = TimeInterpolation::OpticalFlow;
        assert!(none(x));
        // A source that is not known to be opaque (alpha video, a still, not decoded yet).
        assert!(hidden(&[l(0.5), l(0.5)], None).hidden.is_empty());
        // A generator never covers.
        assert!(hidden(&[l(0.5), text()], p).hidden.is_empty());
    }

    #[test]
    fn layers_that_belong_to_a_transition_or_keep_state_stay_even_when_covered() {
        let mut in_transition = l(0.5);
        in_transition.in_transition = true;
        let mut temporal = l(0.5);
        temporal.effects.temporal =
            Some(TemporalFilter { denoise: Some(TemporalDenoise::new(2)), ..TemporalFilter::default() });
        let r = hidden(&[in_transition, temporal, text(), l(0.5), l(0.5)], Some(UPRIGHT_4K));
        assert_eq!(r.hidden, set(&[3])); // only the plain media layer goes: generators cost no decode and stay
        assert_eq!(r.cover, Some(4));
    }

    #[test]
    fn the_topmost_cover_counts() {
        let r =
            hidden(&[l(0.5), l(0.5), text(), l(0.5), layer(0.5, Vec2::ZERO, 0.5, 0.0, Vec::new())], Some(UPRIGHT_4K));
        assert_eq!(r.cover, Some(3));
        assert_eq!(r.hidden, set(&[0, 1]));
    }

    #[test]
    fn a_cover_inside_a_nest_needs_the_nest_to_fill_the_canvas_too() {
        let inner = SequenceFormat { width: 2160, height: 3840, ..SequenceFormat::new(Time::new(1, 30)) };
        let group = |n: u128, scale: f64, opacity: f64| {
            let mut g = LayerGroup::new(id(100 + n), id(200), id(300), inner.clone());
            g.transform = ClipTransform { scale: Vec2::new(scale, scale), opacity, ..ClipTransform::IDENTITY };
            g
        };
        let p = Some(UPRIGHT_4K);
        // The inner picture fills the inner canvas (2160x3840 at scale 1), the nest fills the outer one at 0.5.
        let full = group(1, 0.5, 1.0);
        let in_full = |scale: f64| layer(scale, Vec2::ZERO, 1.0, 0.0, vec![full.clone()]);
        assert_eq!(hidden(&[l(0.5), in_full(1.0)], p).hidden, set(&[0]));
        // A lower layer of the same nest is hidden as well.
        assert_eq!(hidden(&[l(0.5), in_full(1.0), in_full(1.0)], p).hidden, set(&[0, 1]));
        // The nest is smaller than the canvas, or faded: only what lies under the picture inside the nest is hidden.
        let small = layer(1.0, Vec2::ZERO, 1.0, 0.0, vec![group(1, 0.4, 1.0)]);
        assert_eq!(hidden(&[l(0.5), small.clone(), small], p).hidden, set(&[1]));
        let faded = layer(1.0, Vec2::ZERO, 1.0, 0.0, vec![group(1, 0.5, 0.5)]);
        assert!(hidden(&[l(0.5), faded], p).hidden.is_empty());
        // The inner picture does not fill the nest.
        assert!(hidden(&[l(0.5), in_full(0.5)], p).hidden.is_empty());
    }
}
