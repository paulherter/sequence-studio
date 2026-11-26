//! Preview scale: a `LayerRequest` rewritten for a canvas `f` times the sequence size (0 < f <= 1), so the compositor can
//! draw a preview at the monitor's pixel size and show the same picture, only smaller. Every parameter in canvas pixels
//! is multiplied by `f`; parameters that are fractions, degrees, counts or colors stay. A request that holds something
//! this module cannot scale exactly (motion blur of a pair, shapes, transitions, a film look, a filter whose pixel
//! unit is unclear) returns `None`: the caller then composes that frame at the full size.
//! shortcut: filters not listed in `scale_filter` are refused, not scaled; list more when a preview needs them.

use crate::effects_evaluation::{ClipEffects, DropShadow, EffectMasks, EffectSegment, ImageFilter};
use crate::effect_transform_stage::MotionBlurSamples;
use crate::evaluation::{LayerGroup, LayerRequest};
use sq_core_masks::MaskShape;
use sq_core_model::ClipTransform;
use sq_core_time::Vec2;

fn v(p: Vec2, f: f64) -> Vec2 {
    Vec2::new(p.x * f, p.y * f)
}

/// The transform on a canvas `f` times as large: position and anchor are canvas pixels. `source_pixels`: the layer is drawn
/// at its own (source) size times Scale, so Scale follows the canvas; a generator or raster is drawn at the canvas size
/// already and keeps its Scale.
pub fn scale_transform(t: &ClipTransform, f: f64, source_pixels: bool) -> ClipTransform {
    let mut o = *t;
    o.position = v(t.position, f);
    o.anchor = v(t.anchor, f);
    if source_pixels {
        o.scale = v(t.scale, f);
    }
    o
}

/// The sequence format of a canvas `f` times the size (rounded, at least 2 px, even so 4:2:0 outputs stay valid). The
/// compositor draws into a target of exactly this size; at f = 1 it is the format itself.
pub fn scale_format(format: &sq_core_model::SequenceFormat, f: f64) -> sq_core_model::SequenceFormat {
    let even = |n: i64| (((n as f64 * f) / 2.0).round() as i64 * 2).max(2);
    let mut o = format.clone();
    if (f - 1.0).abs() >= f64::EPSILON {
        o.width = even(format.width);
        o.height = even(format.height);
    }
    o
}

fn scale_masks(m: &EffectMasks, f: f64) -> EffectMasks {
    EffectMasks { corner_radius: m.corner_radius * f, feather: m.feather * f, ..*m }
}

fn scale_mask_shape(m: &MaskShape, f: f64) -> MaskShape {
    MaskShape { feather: m.feather * f, expansion: m.expansion * f, ..m.clone() }
}

fn scale_shadow(s: &DropShadow, px: f64) -> DropShadow {
    DropShadow { dx: s.dx * px, dy: s.dy * px, sigma: s.sigma * px, ..*s }
}

/// `None` = a filter this module does not scale exactly.
fn scale_filter(filter: &ImageFilter, f: f64) -> Option<ImageFilter> {
    use ImageFilter as I;
    Some(match filter.clone() {
        I::UnsharpMask { sigma, amount, threshold } => I::UnsharpMask { sigma: sigma * f, amount, threshold },
        I::DirectionalBlur { dx, dy } => I::DirectionalBlur { dx: dx * f, dy: dy * f },
        I::Glow { threshold, sigma, intensity, color } => I::Glow { threshold, sigma: sigma * f, intensity, color },
        I::RgbSplit { dx, dy, radial, mix } => I::RgbSplit { dx: dx * f, dy: dy * f, radial, mix },
        I::Halftone { size, angle, softness, color, blend } => {
            I::Halftone { size: size * f, angle, softness, color, blend }
        }
        other @ (I::Flip { .. }
        | I::Invert { .. }
        | I::Posterize { .. }
        | I::Tint { .. }
        | I::BrightnessContrast { .. }) => other,
        _ => return None,
    })
}

fn scale_segment(s: &EffectSegment, f: f64, px: f64) -> Option<EffectSegment> {
    let filter = match &s.filter {
        Some(x) => Some(scale_filter(x, px)?),
        None => None,
    };
    Some(EffectSegment {
        masks: scale_masks(&s.masks, f),
        blur_after: s.blur_after * px,
        shadow: s.shadow.as_ref().map(|d| scale_shadow(d, px)),
        filter,
        scope: s.scope.iter().map(|m| scale_mask_shape(m, f)).collect(),
        ..s.clone()
    })
}

impl ClipEffects {
    /// These effects for a canvas `f` times the size; `None` when something cannot be scaled exactly (see the module).
    /// `px` scales the effect pixel values (blur, shadow, filter): the pixels of the layer the effect chain runs on. A
    /// generator or raster is canvas-sized, so `px = f`; a media layer's chain runs at its own native size whatever the canvas
    /// is (its Scale follows f instead), so `px = 1`. Masks, feather and corners are canvas pixels and always follow `f`.
    pub fn scaled(&self, f: f64, px: f64) -> Option<ClipEffects> {
        if self.temporal.is_some() || self.look != sq_core_color::FilmLook::default() || self.anti_flicker > 0.0 {
            return None;
        }
        let segments = self.segments.iter().map(|s| scale_segment(s, f, px)).collect::<Option<Vec<_>>>()?;
        let masks = self.masks.iter().map(|m| scale_mask_shape(m, f)).collect();
        Some(ClipEffects { segments, masks, ..self.clone() })
    }
}

fn scale_group(g: &LayerGroup, f: f64) -> Option<LayerGroup> {
    Some(LayerGroup {
        format: scale_format(&g.format, f),
        transform: scale_transform(&g.transform, f, false),
        corner_radius: g.corner_radius * f,
        effects: g.effects.scaled(f, f)?,
        motion_blur: g.motion_blur.as_ref().map(|mb| MotionBlurSamples {
            format: scale_format(&mb.format, f),
            transforms: mb.transforms.iter().map(|t| scale_transform(t, f, false)).collect(),
            local_times: mb.local_times.clone(),
        }),
        ..g.clone()
    })
}

impl LayerRequest {
    /// This request for a canvas `f` times the sequence size, 0 < f <= 1 (f = 1 returns it unchanged). `None`: compose it
    /// at the full size.
    pub fn scaled(&self, f: f64) -> Option<LayerRequest> {
        if (f - 1.0).abs() < f64::EPSILON {
            return Some(self.clone());
        }
        if !(f > 0.0 && f < 1.0)
            || self.shape.is_some()
            || self.pair.is_some()
            || !self.stack_transitions.is_empty()
        {
            return None;
        }
        let mut o = self.clone();
        o.transform = scale_transform(&self.transform, f, self.generator.is_none());
        o.corner_radius = self.corner_radius * f;
        // The sub-frame transforms follow the canvas like the layer's own (same Scale rule); the samples' canvas is the
        // scaled one so the Pair node and the text samples are drawn at the preview size.
        if let Some(mb) = &self.motion_blur {
            let source_pixels = self.generator.is_none();
            o.motion_blur = Some(crate::effect_transform_stage::MotionBlurSamples {
                format: scale_format(&mb.format, f),
                transforms: mb.transforms.iter().map(|t| scale_transform(t, f, source_pixels)).collect(),
                local_times: mb.local_times.clone(),
            });
        }
        let px = if self.generator.is_none() { 1.0 } else { f };
        o.effects = self.effects.scaled(f, px)?;
        // A nested clip is an offscreen image of the inner format, drawn into the parent: the image is `f` times as large
        // (its own pixels are canvas pixels, like a generator's), so its Scale stays and its position, radius and effects follow.
        o.groups = self.groups.iter().map(|g| scale_group(g, f)).collect::<Option<Vec<_>>>()?;
        Some(o)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::{Id, Time};

    fn req() -> LayerRequest {
        LayerRequest::new(Id::from_u128(1), Id::from_u128(2), Id::from_u128(3), Time::ZERO)
    }

    fn seg(f: impl FnOnce(&mut EffectSegment)) -> ClipEffects {
        let mut s = EffectSegment::default();
        f(&mut s);
        ClipEffects { segments: vec![s], ..ClipEffects::default() }
    }

    #[test]
    fn transform_position_and_anchor_follow_the_canvas_and_media_scale_follows_too() {
        let mut r = req();
        r.transform.position = Vec2::new(100.0, -40.0);
        r.transform.anchor = Vec2::new(8.0, 4.0);
        r.transform.scale = Vec2::new(1.0, 2.0);
        let m = r.scaled(0.5).unwrap().transform;
        assert_eq!((m.position, m.anchor, m.scale), (Vec2::new(50.0, -20.0), Vec2::new(4.0, 2.0), Vec2::new(0.5, 1.0)));
        r.generator = Some(sq_core_model::GeneratorRef { kind: "solid".into(), payload: vec![], payload_version: 1 });
        assert_eq!(r.scaled(0.5).unwrap().transform.scale, Vec2::new(1.0, 2.0));
    }

    #[test]
    fn corner_radius_border_feather_and_mask_edges_scale() {
        let mut r = req();
        r.corner_radius = 20.0;
        r.effects = seg(|s| {
            s.masks.corner_radius = 20.0;
            s.masks.feather = 6.0;
            let mut m = MaskShape::new(vec![Vec2::new(0.1, 0.1)]);
            m.feather = 10.0;
            m.expansion = -4.0;
            s.scope = vec![m];
        });
        let o = r.scaled(0.25).unwrap();
        let s = &o.effects.segments[0];
        assert_eq!((o.corner_radius, s.masks.corner_radius, s.masks.feather), (5.0, 5.0, 1.5));
        assert_eq!((s.scope[0].feather, s.scope[0].expansion, s.scope[0].polygon[0]), (2.5, -1.0, Vec2::new(0.1, 0.1)));
    }

    #[test]
    fn motion_blur_samples_follow_the_canvas_with_their_format() {
        use crate::effect_transform_stage::MotionBlurSamples;
        let mut t = ClipTransform::IDENTITY;
        t.position = Vec2::new(80.0, 40.0);
        let mut r = req();
        r.motion_blur = Some(MotionBlurSamples {
            format: sq_core_model::SequenceFormat::new(Time::new(1, 30)),
            transforms: vec![t, t],
            local_times: vec![Time::ZERO, Time::new(1, 30)],
        });
        let m = r.scaled(0.5).unwrap().motion_blur.unwrap();
        assert_eq!((m.format.width, m.format.height), (960, 540));
        assert_eq!(m.transforms[1].position, Vec2::new(40.0, 20.0));
        assert_eq!(m.local_times.len(), 2);
    }

    #[test]
    fn a_gyro_layer_scales_like_any_media_layer_and_keeps_its_gyro_options() {
        // The warp acts on the source picture (normalized map), so it does not depend on the canvas size.
        let mut r = req();
        r.gyro = Some(sq_core_masks::stabilize_effect::GyroflowOptions::default());
        r.transform.scale = Vec2::new(1.0, 1.0);
        let s = r.scaled(0.5).expect("a gyro layer scales");
        assert_eq!(s.gyro, r.gyro);
        assert_eq!(s.transform.scale, Vec2::new(0.5, 0.5));
    }

    #[test]
    fn blur_and_shadow_scale_in_pixels_on_a_canvas_sized_layer_and_stay_on_a_media_layer() {
        let mut r = req();
        let shadow = DropShadow {
            color: [0.0; 3],
            opacity: 0.5,
            dx: 10.0,
            dy: 20.0,
            sigma: 8.0,
            spread: 0.3,
            shadow_only: false,
        };
        r.effects = ClipEffects {
            segments: vec![
                EffectSegment { blur_after: 12.0, ..EffectSegment::default() },
                EffectSegment { shadow: Some(shadow), ..EffectSegment::default() },
            ],
            ..ClipEffects::default()
        };
        // A media layer's chain runs at its native size: pixel values stay (its Scale follows the canvas instead).
        let o = r.scaled(0.5).unwrap().effects;
        let d = o.segments[1].shadow.as_ref().unwrap();
        assert_eq!(
            (o.segments[0].blur_after, d.dx, d.dy, d.sigma, d.spread, d.opacity),
            (12.0, 10.0, 20.0, 8.0, 0.3, 0.5)
        );
        r.generator = Some(sq_core_model::GeneratorRef { kind: "solid".into(), payload: vec![], payload_version: 1 });
        let o = r.scaled(0.5).unwrap().effects;
        let d = o.segments[1].shadow.as_ref().unwrap();
        assert_eq!(
            (o.segments[0].blur_after, d.dx, d.dy, d.sigma, d.spread, d.opacity),
            (6.0, 5.0, 10.0, 4.0, 0.3, 0.5)
        );
    }

    #[test]
    fn pixel_filters_scale_and_unknown_ones_refuse() {
        let mut r = req();
        r.effects = seg(|s| s.filter = Some(ImageFilter::DirectionalBlur { dx: 30.0, dy: 10.0 }));
        assert_eq!(
            r.scaled(0.5).unwrap().effects.segments[0].filter,
            Some(ImageFilter::DirectionalBlur { dx: 30.0, dy: 10.0 })
        );
        r.generator = Some(sq_core_model::GeneratorRef { kind: "solid".into(), payload: vec![], payload_version: 1 });
        let o = r.scaled(0.5).unwrap();
        assert_eq!(o.effects.segments[0].filter, Some(ImageFilter::DirectionalBlur { dx: 15.0, dy: 5.0 }));
        r.effects =
            seg(|s| s.filter = Some(ImageFilter::Twirl { center: Vec2::new(0.0, 0.0), angle: 1.0, radius: 9.0 }));
        assert!(r.scaled(0.5).is_none());
    }

    #[test]
    fn the_scaled_format_is_even_and_scale_one_keeps_it() {
        let f = sq_core_model::SequenceFormat {
            width: 3840,
            height: 2160,
            frame_duration: Time::new(1, 25),
            audio_sample_rate: 48_000,
            pixel_aspect_store: None,
            unknown: sq_core_model::UnknownKeys::default(),
        };
        assert_eq!((scale_format(&f, 0.5).width, scale_format(&f, 0.5).height), (1920, 1080));
        assert_eq!((scale_format(&f, 0.3333).width, scale_format(&f, 0.3333).height), (1280, 720));
        assert_eq!(scale_format(&f, 1.0), f);
    }

    #[test]
    fn scale_one_is_the_identity_and_unscalable_requests_refuse() {
        let mut r = req();
        r.transform.position = Vec2::new(3.0, 4.0);
        assert_eq!(r.scaled(1.0), Some(r.clone()));
        let format = sq_core_model::SequenceFormat {
            width: 8,
            height: 8,
            frame_duration: Time::new(1, 25),
            audio_sample_rate: 48_000,
            pixel_aspect_store: None,
            unknown: sq_core_model::UnknownKeys::default(),
        };
        let mut g = crate::evaluation::LayerGroup::new(Id::from_u128(9), Id::from_u128(9), Id::from_u128(9), format);
        g.transform.position = Vec2::new(40.0, 20.0);
        g.transform.scale = Vec2::new(0.8, 0.8);
        g.corner_radius = 4.0;
        g.effects = seg(|s| s.blur_after = 6.0);
        r.groups.push(g);
        let o = r.scaled(0.5).expect("a nested clip scales");
        let g = &o.groups[0];
        assert_eq!((g.format.width, g.format.height), (4, 4));
        assert_eq!((g.transform.position, g.transform.scale, g.corner_radius), (Vec2::new(20.0, 10.0), Vec2::new(0.8, 0.8), 2.0));
        assert_eq!(g.effects.segments[0].blur_after, 3.0);
        // A group effect the module cannot scale still refuses the whole frame.
        r.groups[0].effects = ClipEffects { anti_flicker: 1.0, ..ClipEffects::default() };
        assert!(r.scaled(0.5).is_none());
    }
}
