// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: StyleEffects.swift (specs and key constants live in sq-core-model `effects_catalog`; `containsGradientEffects`
//        is a file-version gate in sq-core-file)
//! FB-T2 style effects: Premiere's names, defaults and ranges where Premiere has the effect (Radial Blur, Horizontal /
//! Vertical Flip, Invert, Posterize, Tint, Black & White, Brightness & Contrast, Twirl, Wave Warp, Spherize, Strobe Light,
//! Alpha Adjust), and visible start values for the short-form looks Premiere only has inside Lumetri or not at all
//! (Vignette, Film Grain, RGB Split). Each evaluates into one `ImageFilter`; every parameter is keyframable.

use crate::effects_evaluation::{ImageFilter, OutlinePosition};
use crate::motion_effects::MotionEffects;
use sq_core_model::ClipEffect;
use sq_core_time::keyframes_model::keyframe_math::seconds as time_seconds;
use sq_core_time::{Time, Vec2};
use std::f64::consts::PI;

/// Helpers of the style effects.
pub enum StyleEffects {}

impl StyleEffects {
    /// Hash of a strobe period index to 0..<1 (deterministic, so the same periods flash on every render).
    pub fn period_hash(i: i64) -> f64 {
        let mut z = (i as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15);
        z ^= z >> 30;
        z = z.wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z ^= z >> 27;
        z = z.wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^= z >> 31;
        (z >> 11) as f64 / (1u64 << 53) as f64
    }
}

/// Swift `ClipEffect.styleFilter(atLocal:)`.
pub trait ClipEffectStyleExt {
    /// The FB-T2 filter this effect makes at clip-local `t`, or `None` when it is not such an effect or does nothing.
    fn style_filter(&self, t: Time) -> Option<ImageFilter>;
}

impl ClipEffectStyleExt for ClipEffect {
    fn style_filter(&self, t: Time) -> Option<ImageFilter> {
        let v = |key: &str| self.scalar(key, t);
        let seconds = time_seconds(t);
        let rgb = |key: &str| self.color(key, t).rgb();
        match self.kind.as_str() {
            ClipEffect::VIGNETTE_KIND => {
                let a = v(ClipEffect::VIGNETTE_AMOUNT_KEY);
                if a == 0.0 {
                    return None;
                }
                Some(ImageFilter::Vignette {
                    amount: a,
                    midpoint: v(ClipEffect::VIGNETTE_MIDPOINT_KEY) / 100.0,
                    roundness: v(ClipEffect::VIGNETTE_ROUNDNESS_KEY) / 100.0,
                    feather: v(ClipEffect::VIGNETTE_FEATHER_KEY) / 100.0,
                })
            }
            ClipEffect::RGB_SPLIT_KIND => {
                let len = v(ClipEffect::RGB_SPLIT_AMOUNT_KEY);
                let mix = v(ClipEffect::RGB_SPLIT_BLEND_KEY) / 100.0;
                if len <= 0.0 || mix >= 1.0 {
                    return None;
                }
                let a = v(ClipEffect::RGB_SPLIT_ANGLE_KEY) * PI / 180.0;
                // Premiere's angle convention: 0 = up, clockwise; the default 90 puts red to the right, blue to the left.
                Some(ImageFilter::RgbSplit {
                    dx: len * a.sin(),
                    dy: -len * a.cos(),
                    radial: self.choice(ClipEffect::RGB_SPLIT_MODE_KEY, t) == 1,
                    mix,
                })
            }
            ClipEffect::RADIAL_BLUR_KIND => {
                let a = v(ClipEffect::RADIAL_AMOUNT_KEY);
                if a <= 0.0 {
                    return None;
                }
                Some(ImageFilter::RadialBlur {
                    center: self.point(ClipEffect::RADIAL_CENTER_KEY, t),
                    amount: a,
                    zoom: self.choice(ClipEffect::RADIAL_TYPE_KEY, t) == 1,
                    high: self.choice(ClipEffect::RADIAL_QUALITY_KEY, t) == 1,
                })
            }
            ClipEffect::HORIZONTAL_FLIP_KIND => Some(ImageFilter::Flip { horizontal: true, vertical: false }),
            ClipEffect::VERTICAL_FLIP_KIND => Some(ImageFilter::Flip { horizontal: false, vertical: true }),
            ClipEffect::INVERT_KIND => {
                let blend = v(ClipEffect::INVERT_BLEND_KEY) / 100.0;
                if blend >= 1.0 {
                    return None;
                }
                Some(ImageFilter::Invert { channel: self.choice(ClipEffect::INVERT_CHANNEL_KEY, t), blend })
            }
            ClipEffect::POSTERIZE_KIND => {
                Some(ImageFilter::Posterize { levels: v(ClipEffect::POSTERIZE_LEVEL_KEY).round() as i64 })
            }
            ClipEffect::TINT_KIND => {
                let a = v(ClipEffect::TINT_AMOUNT_KEY) / 100.0;
                if a <= 0.0 {
                    return None;
                }
                Some(ImageFilter::Tint {
                    black: rgb(ClipEffect::TINT_BLACK_KEY),
                    white: rgb(ClipEffect::TINT_WHITE_KEY),
                    amount: a,
                })
            }
            ClipEffect::BLACK_AND_WHITE_KIND => {
                Some(ImageFilter::Tint { black: [0.0; 3], white: [1.0, 1.0, 1.0], amount: 1.0 })
            }
            ClipEffect::BRIGHTNESS_CONTRAST_KIND => {
                let (b, c) = (v(ClipEffect::BRIGHTNESS_KEY), v(ClipEffect::CONTRAST_KEY));
                if b == 0.0 && c == 0.0 {
                    return None;
                }
                Some(ImageFilter::BrightnessContrast { brightness: b / 100.0, contrast: c / 100.0 })
            }
            ClipEffect::TWIRL_KIND => {
                let (a, r) = (v(ClipEffect::TWIRL_ANGLE_KEY), v(ClipEffect::TWIRL_RADIUS_KEY) / 100.0);
                if a == 0.0 || r <= 0.0 {
                    return None;
                }
                Some(ImageFilter::Twirl { center: self.point(ClipEffect::TWIRL_CENTER_KEY, t), angle: a, radius: r })
            }
            ClipEffect::CORNER_PIN_KIND => {
                let tl = self.point(ClipEffect::CORNER_PIN_TOP_LEFT_KEY, t);
                let tr = self.point(ClipEffect::CORNER_PIN_TOP_RIGHT_KEY, t);
                let br = self.point(ClipEffect::CORNER_PIN_BOTTOM_RIGHT_KEY, t);
                let bl = self.point(ClipEffect::CORNER_PIN_BOTTOM_LEFT_KEY, t);
                if tl == Vec2::ZERO && tr == Vec2::ZERO && br == Vec2::ZERO && bl == Vec2::ZERO {
                    return None;
                }
                Some(ImageFilter::CornerPin { top_left: tl, top_right: tr, bottom_right: br, bottom_left: bl })
            }
            ClipEffect::WAVE_WARP_KIND => {
                let h = v(ClipEffect::WAVE_HEIGHT_KEY);
                if h == 0.0 {
                    return None;
                }
                let mut phase = (v(ClipEffect::WAVE_PHASE_KEY) / 360.0 + v(ClipEffect::WAVE_SPEED_KEY) * seconds) % 1.0;
                if phase < 0.0 {
                    phase += 1.0;
                }
                Some(ImageFilter::WaveWarp {
                    wave_type: self.choice(ClipEffect::WAVE_TYPE_KEY, t),
                    height: h,
                    width: v(ClipEffect::WAVE_WIDTH_KEY),
                    direction: v(ClipEffect::WAVE_DIRECTION_KEY),
                    phase,
                    pinning: self.choice(ClipEffect::WAVE_PINNING_KEY, t),
                })
            }
            ClipEffect::SPHERIZE_KIND => {
                let (r, s) = (v(ClipEffect::SPHERIZE_RADIUS_KEY), v(ClipEffect::SPHERIZE_STRENGTH_KEY) / 100.0);
                if r <= 0.0 || s == 0.0 {
                    return None;
                }
                Some(ImageFilter::Spherize {
                    center: self.point(ClipEffect::SPHERIZE_CENTER_KEY, t),
                    radius: r,
                    strength: s,
                })
            }
            ClipEffect::STROBE_KIND => {
                let period = v(ClipEffect::STROBE_PERIOD_KEY);
                let duration = v(ClipEffect::STROBE_DURATION_KEY);
                let blend = v(ClipEffect::STROBE_BLEND_KEY) / 100.0;
                if duration <= 0.0 || blend >= 1.0 {
                    return None;
                }
                let index = (seconds / period).floor();
                if seconds - index * period >= duration {
                    return None;
                }
                let p = v(ClipEffect::STROBE_RANDOM_KEY) / 100.0;
                if p > 0.0 && StyleEffects::period_hash(index as i64) >= p {
                    return None;
                }
                Some(ImageFilter::Strobe {
                    color: rgb(ClipEffect::STROBE_COLOR_KEY),
                    blend,
                    op: self.choice(ClipEffect::STROBE_OPERATOR_KEY, t),
                    transparent: self.choice(ClipEffect::STROBE_MODE_KEY, t) == 1,
                })
            }
            ClipEffect::LENS_DISTORTION_KIND => {
                let c = v(ClipEffect::LENS_CURVATURE_KEY);
                if c == 0.0 {
                    return None;
                }
                let auto_scale = self.flag(ClipEffect::LENS_AUTO_SCALE_KEY, t);
                Some(ImageFilter::LensDistortion {
                    curvature: c / 100.0,
                    decenter: Vec2::new(
                        v(ClipEffect::LENS_H_DECENTER_KEY) / 100.0,
                        v(ClipEffect::LENS_V_DECENTER_KEY) / 100.0,
                    ),
                    fill_alpha: self.flag(ClipEffect::LENS_FILL_ALPHA_KEY, t),
                    fill: rgb(ClipEffect::LENS_FILL_COLOR_KEY),
                    auto_scale,
                    exact_model: self.flag(ClipEffect::LENS_MODEL_KEY, t) || auto_scale,
                })
            }
            ClipEffect::LIGHT_LEAK_KIND => {
                let i = v(ClipEffect::LEAK_INTENSITY_KEY) / 100.0;
                if i <= 0.0 {
                    return None;
                }
                // The leak's center sits outside the frame towards From and wanders on a smooth seeded path (share of half
                // the frame).
                let a = v(ClipEffect::LEAK_ANGLE_KEY) * PI / 180.0;
                let seed = v(ClipEffect::LEAK_SEED_KEY).max(0.0).round() as u64;
                let x = v(ClipEffect::LEAK_SPEED_KEY) * seconds * 0.35;
                let noise = |dx: f64, add: u64| MotionEffects::noise(dx, seed.wrapping_mul(2).wrapping_add(add));
                let wander = Vec2::new(noise(x, 1), noise(x, 2)) * 0.45;
                let center = Vec2::new(a.sin(), -a.cos()) * 0.9 + wander;
                let swirl = noise(x * 0.7, 7) * 0.6;
                Some(ImageFilter::LightLeak {
                    color1: rgb(ClipEffect::LEAK_COLOR1_KEY),
                    color2: rgb(ClipEffect::LEAK_COLOR2_KEY),
                    intensity: i,
                    center,
                    size: v(ClipEffect::LEAK_SIZE_KEY) / 100.0,
                    angle: a + swirl,
                })
            }
            ClipEffect::GRADIENT_KIND => {
                let b = v(ClipEffect::GRADIENT_BLEND_KEY) / 100.0;
                if b <= 0.0 {
                    return None;
                }
                Some(ImageFilter::Gradient {
                    color1: rgb(ClipEffect::GRADIENT_COLOR1_KEY),
                    color2: rgb(ClipEffect::GRADIENT_COLOR2_KEY),
                    start: self.point(ClipEffect::GRADIENT_START_KEY, t),
                    end: self.point(ClipEffect::GRADIENT_END_KEY, t),
                    radial: self.choice(ClipEffect::GRADIENT_TYPE_KEY, t) == 1,
                    blend: b,
                })
            }
            ClipEffect::HALFTONE_KIND => {
                let (b, size) = (v(ClipEffect::HALFTONE_BLEND_KEY) / 100.0, v(ClipEffect::HALFTONE_SIZE_KEY));
                if b <= 0.0 || size <= 0.0 {
                    return None;
                }
                Some(ImageFilter::Halftone {
                    size,
                    angle: v(ClipEffect::HALFTONE_ANGLE_KEY),
                    softness: v(ClipEffect::HALFTONE_SOFTNESS_KEY) / 100.0,
                    color: self.choice(ClipEffect::HALFTONE_MODE_KEY, t) == 1,
                    blend: b,
                })
            }
            ClipEffect::TILE_KIND => {
                let c = v(ClipEffect::TILE_COLUMNS_KEY).max(0.01);
                let r = v(ClipEffect::TILE_ROWS_KEY).max(0.01);
                let off = Vec2::new(v(ClipEffect::TILE_OFFSET_X_KEY) / 100.0, v(ClipEffect::TILE_OFFSET_Y_KEY) / 100.0);
                if c == 1.0 && r == 1.0 && off == Vec2::ZERO {
                    return None;
                }
                Some(ImageFilter::Tile {
                    columns: c,
                    rows: r,
                    offset: off,
                    mirror: self.flag(ClipEffect::TILE_MIRROR_KEY, t),
                })
            }
            ClipEffect::KALEIDOSCOPE_KIND => Some(ImageFilter::Kaleidoscope {
                center: self.point(ClipEffect::KALEIDO_CENTER_KEY, t),
                segments: (v(ClipEffect::KALEIDO_SEGMENTS_KEY).round() as i64).max(2),
                angle: v(ClipEffect::KALEIDO_ANGLE_KEY),
                zoom: v(ClipEffect::KALEIDO_ZOOM_KEY).max(1.0) / 100.0,
            }),
            ClipEffect::EDGE_FEATHER_KIND => {
                let a = v(ClipEffect::EDGE_FEATHER_AMOUNT_KEY);
                if a <= 0.0 {
                    return None;
                }
                Some(ImageFilter::EdgeFeather { amount: a })
            }
            ClipEffect::GLITCH_KIND => {
                let (amount, split) = (v(ClipEffect::GLITCH_AMOUNT_KEY), v(ClipEffect::GLITCH_SPLIT_KEY));
                let density = v(ClipEffect::GLITCH_DENSITY_KEY) / 100.0;
                if !((amount > 0.0 && density > 0.0) || split > 0.0) {
                    return None;
                }
                let step = (seconds * v(ClipEffect::GLITCH_RATE_KEY).max(0.0)).floor() as i64;
                Some(ImageFilter::Glitch {
                    amount,
                    block: v(ClipEffect::GLITCH_BLOCK_KEY).max(1.0),
                    split,
                    density: density.min(1.0),
                    seed: v(ClipEffect::GLITCH_SEED_KEY).max(0.0).round() as i64 + step,
                })
            }
            ClipEffect::OUTLINE_KIND => {
                let w = v(ClipEffect::OUTLINE_WIDTH_KEY);
                if w <= 0.0 {
                    return None;
                }
                Some(ImageFilter::Outline {
                    width: w,
                    color: rgb(ClipEffect::OUTLINE_COLOR_KEY),
                    softness: v(ClipEffect::OUTLINE_SOFTNESS_KEY),
                    position: OutlinePosition::from_raw(self.choice(ClipEffect::OUTLINE_POSITION_KEY, t))
                        .unwrap_or(OutlinePosition::Outside),
                })
            }
            ClipEffect::LONG_SHADOW_KIND => {
                let (len, o) = (v(ClipEffect::LONG_SHADOW_LENGTH_KEY), v(ClipEffect::LONG_SHADOW_OPACITY_KEY) / 100.0);
                if len <= 0.0 || o <= 0.0 {
                    return None;
                }
                Some(ImageFilter::LongShadow {
                    angle: v(ClipEffect::LONG_SHADOW_ANGLE_KEY),
                    length: len,
                    color: rgb(ClipEffect::LONG_SHADOW_COLOR_KEY),
                    fade: v(ClipEffect::LONG_SHADOW_FADE_KEY) / 100.0,
                    opacity: o,
                })
            }
            ClipEffect::ALPHA_ADJUST_KIND => {
                let o = v(ClipEffect::ALPHA_OPACITY_KEY) / 100.0;
                let ignore = self.flag(ClipEffect::ALPHA_IGNORE_KEY, t);
                let invert = self.flag(ClipEffect::ALPHA_INVERT_KEY, t);
                let mask_only = self.flag(ClipEffect::ALPHA_MASK_ONLY_KEY, t);
                if o >= 1.0 && !ignore && !invert && !mask_only {
                    return None;
                }
                Some(ImageFilter::AlphaAdjust { opacity: o, ignore, invert, mask_only })
            }
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::AnimatedProperty;
    use sq_core_time::{Id, Keyframe, KeyframeTrack};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn effect(kind: &str, values: &[(&str, f64)]) -> ClipEffect {
        let mut e = ClipEffect::make(Id::from_u128(1), kind).unwrap();
        for (k, v) in values {
            e.parameters.insert((*k).into(), AnimatedProperty::new(*v));
        }
        e
    }

    fn filter(e: &ClipEffect, t: Time) -> Option<ImageFilter> {
        e.style_filter(t)
    }

    fn at1(e: &ClipEffect) -> Option<ImageFilter> {
        filter(e, s(1))
    }

    #[test]
    fn identity_defaults_draw_the_picture_as_is() {
        for k in [ClipEffect::BRIGHTNESS_CONTRAST_KIND, ClipEffect::TWIRL_KIND, ClipEffect::SPHERIZE_KIND] {
            assert_eq!(at1(&effect(k, &[])), None, "{k}");
        }
        assert_eq!(at1(&effect(ClipEffect::RADIAL_BLUR_KIND, &[(ClipEffect::RADIAL_AMOUNT_KEY, 0.0)])), None);
        assert_eq!(at1(&effect(ClipEffect::VIGNETTE_KIND, &[(ClipEffect::VIGNETTE_AMOUNT_KEY, 0.0)])), None);
        assert_eq!(at1(&effect(ClipEffect::INVERT_KIND, &[(ClipEffect::INVERT_BLEND_KEY, 100.0)])), None);
        assert_eq!(at1(&effect(ClipEffect::TINT_KIND, &[(ClipEffect::TINT_AMOUNT_KEY, 0.0)])), None);
        assert_eq!(at1(&effect(ClipEffect::ALPHA_ADJUST_KIND, &[])), None);
        assert_eq!(at1(&effect(ClipEffect::LENS_DISTORTION_KIND, &[])), None);
        assert_eq!(at1(&effect(ClipEffect::LENS_DISTORTION_KIND, &[(ClipEffect::LENS_AUTO_SCALE_KEY, 1.0)])), None);
        assert_eq!(at1(&effect(ClipEffect::LIGHT_LEAK_KIND, &[(ClipEffect::LEAK_INTENSITY_KEY, 0.0)])), None);
        assert_eq!(at1(&effect(ClipEffect::GRADIENT_KIND, &[(ClipEffect::GRADIENT_BLEND_KEY, 0.0)])), None);
        assert_eq!(at1(&effect(ClipEffect::HALFTONE_KIND, &[(ClipEffect::HALFTONE_BLEND_KEY, 0.0)])), None);
        assert_eq!(
            at1(&effect(
                ClipEffect::TILE_KIND,
                &[(ClipEffect::TILE_COLUMNS_KEY, 1.0), (ClipEffect::TILE_ROWS_KEY, 1.0)]
            )),
            None
        );
        assert_eq!(at1(&effect(ClipEffect::EDGE_FEATHER_KIND, &[(ClipEffect::EDGE_FEATHER_AMOUNT_KEY, 0.0)])), None);
        let still = [(ClipEffect::GLITCH_AMOUNT_KEY, 0.0), (ClipEffect::GLITCH_SPLIT_KEY, 0.0)];
        assert_eq!(at1(&effect(ClipEffect::GLITCH_KIND, &still)), None);
    }

    #[test]
    fn effects_premiere_has_no_standalone_for_show_something_when_dropped() {
        assert!(at1(&effect(ClipEffect::VIGNETTE_KIND, &[])).is_some());
        assert!(at1(&effect(ClipEffect::RGB_SPLIT_KIND, &[])).is_some());
        // Film Grain runs in the film look pass, not as a filter.
        assert_eq!(at1(&effect(ClipEffect::GRAIN_KIND, &[])), None);
    }

    #[test]
    fn flips_and_black_and_white() {
        assert_eq!(
            at1(&effect(ClipEffect::HORIZONTAL_FLIP_KIND, &[])),
            Some(ImageFilter::Flip { horizontal: true, vertical: false })
        );
        assert_eq!(
            at1(&effect(ClipEffect::VERTICAL_FLIP_KIND, &[])),
            Some(ImageFilter::Flip { horizontal: false, vertical: true })
        );
        assert_eq!(
            at1(&effect(ClipEffect::BLACK_AND_WHITE_KIND, &[])),
            Some(ImageFilter::Tint { black: [0.0; 3], white: [1.0; 3], amount: 1.0 })
        );
    }

    #[test]
    fn radial_blur_maps_type_and_center() {
        let mut e = effect(
            ClipEffect::RADIAL_BLUR_KIND,
            &[
                (ClipEffect::RADIAL_AMOUNT_KEY, 20.0),
                (ClipEffect::RADIAL_TYPE_KEY, 1.0),
                (ClipEffect::RADIAL_QUALITY_KEY, 1.0),
            ],
        );
        e.points.insert(ClipEffect::RADIAL_CENTER_KEY.into(), AnimatedProperty::new(Vec2::new(10.0, -5.0)));
        assert_eq!(
            at1(&e),
            Some(ImageFilter::RadialBlur { center: Vec2::new(10.0, -5.0), amount: 20.0, zoom: true, high: true })
        );
    }

    #[test]
    fn rgb_split_is_a_direction_and_a_length() {
        let e = effect(
            ClipEffect::RGB_SPLIT_KIND,
            &[(ClipEffect::RGB_SPLIT_AMOUNT_KEY, 10.0), (ClipEffect::RGB_SPLIT_ANGLE_KEY, 90.0)],
        );
        let Some(ImageFilter::RgbSplit { dx, dy, radial, mix }) = at1(&e) else { panic!("no split") };
        assert!((dx - 10.0).abs() + dy.abs() < 1e-9);
        assert!(!radial && mix == 0.0);
    }

    #[test]
    fn wave_warp_phase_advances_with_wave_speed_and_wraps() {
        let e =
            effect(ClipEffect::WAVE_WARP_KIND, &[(ClipEffect::WAVE_SPEED_KEY, 1.0), (ClipEffect::WAVE_PHASE_KEY, 0.0)]);
        let Some(ImageFilter::WaveWarp { height, width, direction, phase, .. }) = filter(&e, Time::new(1, 4)) else {
            panic!("no wave")
        };
        assert_eq!((height, width, direction), (10.0, 40.0, 90.0));
        assert!((phase - 0.25).abs() < 1e-9);
        let Some(ImageFilter::WaveWarp { phase: p2, .. }) = filter(&e, Time::new(5, 4)) else { panic!("no wave") };
        assert!((p2 - 0.25).abs() < 1e-9);
        let still = effect(
            ClipEffect::WAVE_WARP_KIND,
            &[(ClipEffect::WAVE_SPEED_KEY, 0.0), (ClipEffect::WAVE_PHASE_KEY, 90.0)],
        );
        let Some(ImageFilter::WaveWarp { phase: p3, .. }) = filter(&still, s(3)) else { panic!("no wave") };
        assert!((p3 - 0.25).abs() < 1e-9);
    }

    #[test]
    fn strobe_is_on_for_its_duration_every_period_and_random_periods_repeat() {
        let e = effect(ClipEffect::STROBE_KIND, &[]); // 0.05 s every 0.1 s
        assert!(filter(&e, Time::new(1, 100)).is_some());
        assert!(filter(&e, Time::new(7, 100)).is_none());
        assert!(filter(&e, Time::new(102, 100)).is_some());
        let r = effect(ClipEffect::STROBE_KIND, &[(ClipEffect::STROBE_RANDOM_KEY, 50.0)]);
        let flashes = || -> Vec<bool> { (0..200).map(|i| filter(&r, Time::new(i * 10 + 1, 100)).is_some()).collect() };
        let (on, again) = (flashes(), flashes());
        let count = on.iter().filter(|x| **x).count();
        assert!(count > 60 && count < 140, "{count}");
        assert_eq!(on, again);
        assert!((0.0..1.0).contains(&StyleEffects::period_hash(-7)));
    }

    #[test]
    fn alpha_adjust_twirl_and_posterize_map_their_parameters() {
        let e = effect(
            ClipEffect::ALPHA_ADJUST_KIND,
            &[(ClipEffect::ALPHA_OPACITY_KEY, 40.0), (ClipEffect::ALPHA_INVERT_KEY, 1.0)],
        );
        assert_eq!(
            at1(&e),
            Some(ImageFilter::AlphaAdjust { opacity: 0.4, ignore: false, invert: true, mask_only: false })
        );
        let e = effect(ClipEffect::TWIRL_KIND, &[(ClipEffect::TWIRL_ANGLE_KEY, 180.0)]);
        assert_eq!(at1(&e), Some(ImageFilter::Twirl { center: Vec2::ZERO, angle: 180.0, radius: 0.5 }));
        let mut p = effect(ClipEffect::POSTERIZE_KIND, &[]);
        let mut prop = AnimatedProperty::new(2.0);
        prop.track = KeyframeTrack::with_keys(vec![
            Keyframe::new(Id::from_u128(2), s(0), 2.0),
            Keyframe::new(Id::from_u128(3), s(2), 10.0),
        ]);
        p.parameters.insert(ClipEffect::POSTERIZE_LEVEL_KEY.into(), prop);
        assert_eq!(filter(&p, s(1)), Some(ImageFilter::Posterize { levels: 6 }));
    }

    #[test]
    fn lens_distortion_maps_premiere_parameters_and_the_model_flag() {
        let e = effect(
            ClipEffect::LENS_DISTORTION_KIND,
            &[(ClipEffect::LENS_CURVATURE_KEY, -40.0), (ClipEffect::LENS_V_DECENTER_KEY, 10.0)],
        );
        let want = |auto_scale: bool, exact_model: bool| ImageFilter::LensDistortion {
            curvature: -0.4,
            decenter: Vec2::new(0.0, 0.1),
            fill_alpha: true,
            fill: [1.0, 1.0, 1.0],
            auto_scale,
            exact_model,
        };
        assert_eq!(e.parameters.get(ClipEffect::LENS_MODEL_KEY).map(|p| p.value), Some(1.0));
        assert_eq!(at1(&e), Some(want(false, true)));
        // Saved before F7.15: no model key, the old look; Auto Scale moves it to the exact model.
        let mut saved = e.clone();
        saved.parameters.remove(ClipEffect::LENS_MODEL_KEY);
        assert_eq!(at1(&saved), Some(want(false, false)));
        saved.parameters.insert(ClipEffect::LENS_AUTO_SCALE_KEY.into(), AnimatedProperty::new(1.0));
        assert_eq!(at1(&saved), Some(want(true, true)));
    }

    #[test]
    fn light_leak_drifts_over_time() {
        let e = effect(ClipEffect::LIGHT_LEAK_KIND, &[]);
        let (
            Some(ImageFilter::LightLeak { intensity, center: c0, .. }),
            Some(ImageFilter::LightLeak { center: c1, .. }),
        ) = (filter(&e, s(0)), filter(&e, s(1)))
        else {
            panic!("no leak")
        };
        assert!(intensity > 0.0 && c0 != c1);
        let still = effect(ClipEffect::LIGHT_LEAK_KIND, &[(ClipEffect::LEAK_SPEED_KEY, 0.0)]);
        assert_eq!(filter(&still, s(0)), filter(&still, s(3)));
    }

    #[test]
    fn gradient_mapping_and_keyed_points() {
        let e = effect(ClipEffect::GRADIENT_KIND, &[]);
        assert_eq!(
            at1(&e),
            Some(ImageFilter::Gradient {
                color1: [0.0; 3],
                color2: [1.0; 3],
                start: Vec2::new(0.0, -400.0),
                end: Vec2::new(0.0, 400.0),
                radial: false,
                blend: 1.0
            })
        );
        let r = effect(
            ClipEffect::GRADIENT_KIND,
            &[(ClipEffect::GRADIENT_TYPE_KEY, 1.0), (ClipEffect::GRADIENT_BLEND_KEY, 40.0)],
        );
        let Some(ImageFilter::Gradient { radial, blend, .. }) = at1(&r) else { panic!("no gradient") };
        assert!(radial && (blend - 0.4).abs() < 1e-9);
        let mut k = effect(ClipEffect::GRADIENT_KIND, &[]);
        let mut end = AnimatedProperty::new(Vec2::new(0.0, 400.0));
        end.track = KeyframeTrack::with_keys(vec![
            Keyframe::new(Id::from_u128(2), s(0), Vec2::new(0.0, 400.0)),
            Keyframe::new(Id::from_u128(3), s(2), Vec2::new(200.0, 400.0)),
        ]);
        k.points.insert(ClipEffect::GRADIENT_END_KEY.into(), end);
        let Some(ImageFilter::Gradient { end, .. }) = at1(&k) else { panic!("no gradient") };
        assert!((end.x - 100.0).abs() < 1e-6);
    }

    #[test]
    fn halftone_tile_kaleidoscope_edge_feather_and_glitch_map_their_defaults() {
        assert_eq!(
            at1(&effect(ClipEffect::HALFTONE_KIND, &[])),
            Some(ImageFilter::Halftone { size: 12.0, angle: 45.0, softness: 0.2, color: false, blend: 1.0 })
        );
        assert_eq!(
            at1(&effect(ClipEffect::TILE_KIND, &[])),
            Some(ImageFilter::Tile { columns: 2.0, rows: 2.0, offset: Vec2::ZERO, mirror: false })
        );
        assert_eq!(
            at1(&effect(ClipEffect::KALEIDOSCOPE_KIND, &[])),
            Some(ImageFilter::Kaleidoscope { center: Vec2::ZERO, segments: 6, angle: 0.0, zoom: 1.0 })
        );
        let k = effect(
            ClipEffect::KALEIDOSCOPE_KIND,
            &[(ClipEffect::KALEIDO_SEGMENTS_KEY, 3.6), (ClipEffect::KALEIDO_ZOOM_KEY, 200.0)],
        );
        assert_eq!(at1(&k), Some(ImageFilter::Kaleidoscope { center: Vec2::ZERO, segments: 4, angle: 0.0, zoom: 2.0 }));
        assert_eq!(at1(&effect(ClipEffect::EDGE_FEATHER_KIND, &[])), Some(ImageFilter::EdgeFeather { amount: 40.0 }));
        // Seed 1 + 8 steps per second * 1 s.
        assert_eq!(
            at1(&effect(ClipEffect::GLITCH_KIND, &[])),
            Some(ImageFilter::Glitch { amount: 30.0, block: 24.0, split: 6.0, density: 0.4, seed: 9 })
        );
        // Rate 4 steps per second: the pattern changes every 0.25 s and holds in between. Rate 0 freezes it.
        let a = effect(ClipEffect::GLITCH_KIND, &[(ClipEffect::GLITCH_RATE_KEY, 4.0)]);
        assert_eq!(filter(&a, Time::new(1, 10)), filter(&a, Time::new(2, 10)));
        assert_ne!(filter(&a, Time::new(1, 10)), filter(&a, Time::new(3, 10)));
        let f = effect(ClipEffect::GLITCH_KIND, &[(ClipEffect::GLITCH_RATE_KEY, 0.0)]);
        assert_eq!(filter(&f, Time::new(1, 10)), filter(&f, s(5)));
    }

    #[test]
    fn keyed_tile_columns_animate() {
        let mut e = effect(ClipEffect::TILE_KIND, &[]);
        let mut cols = AnimatedProperty::new(2.0);
        cols.track = KeyframeTrack::with_keys(vec![
            Keyframe::new(Id::from_u128(2), s(0), 2.0),
            Keyframe::new(Id::from_u128(3), s(2), 6.0),
        ]);
        e.parameters.insert(ClipEffect::TILE_COLUMNS_KEY.into(), cols);
        let Some(ImageFilter::Tile { columns, .. }) = at1(&e) else { panic!("no tile") };
        assert!((columns - 4.0).abs() < 1e-9);
    }
}
