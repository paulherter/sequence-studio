// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MotionRecipes.swift
//! The maintainer's top-10 animation recipes as parameters of the motion effects. Each returns the effects to stack on a
//! clip (they compose on the transform stage and leave Motion alone). Times are from the clip's start (In) or end (Out);
//! positions are a % of the frame along the axis. Recipe 10's Mirror keys are not covered (only the 50 % pop).

use crate::motion_effects::MoveSide;
use sq_core_model::motion_easing::MotionCurve;
use sq_core_model::{AnimatedProperty, ClipEffect};
use sq_core_time::{EasingCurve, IdSource, Keyframe, KeyframeTrack, SequentialIds, Time};

/// Which edge a Move recipe uses.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecipeSide {
    Left,
    Right,
    Bottom,
}

/// Swift `MotionRecipes`.
pub struct MotionRecipes;

/// The effect of `kind` with these values as static parameters (built-in ids are placeholders, see `EffectStackPreset`).
pub(crate) fn make_effect(ids: &mut dyn IdSource, kind: &str, values: &[(&str, f64)]) -> ClipEffect {
    let id = ids.next_id();
    let made = ClipEffect::make(id, kind);
    debug_assert!(made.is_some(), "unknown effect kind in a motion recipe: {kind}");
    // Swift traps on an unknown kind; a bare effect keeps release builds running.
    let mut e = made.unwrap_or_else(|| ClipEffect::new(id, kind));
    for (k, v) in values {
        e.parameters.insert((*k).to_string(), AnimatedProperty::new(*v));
    }
    e
}

/// A time of `seconds`, in milliseconds.
pub(crate) fn ms(seconds: f64) -> Time {
    Time::new((seconds * 1000.0).round() as i64, 1000)
}

/// A bezier key with Premiere's default handles.
pub(crate) fn bezier_key(ids: &mut dyn IdSource, time: Time, value: f64) -> Keyframe<f64> {
    let c = EasingCurve::premiere_default();
    let mut k = Keyframe::new(ids.next_id(), time, value);
    k.interpolation = sq_core_time::Interpolation::Bezier;
    k.in_handle = c.in_handle;
    k.out_handle = c.out_handle;
    k
}

fn curve(c: MotionCurve) -> f64 {
    c.raw_value() as f64
}

impl MotionRecipes {
    const MODE: &'static str = ClipEffect::MOTION_MODE_KEY;
    const CURVE: &'static str = ClipEffect::MOTION_CURVE_KEY;
    const DUR: &'static str = ClipEffect::MOTION_DURATION_KEY;

    /// Gaussian Blur with two bezier keys (clip-local times).
    fn blur(a: (Time, f64), b: (Time, f64)) -> ClipEffect {
        let mut ids = SequentialIds::default();
        let mut e = make_effect(&mut ids, ClipEffect::GAUSSIAN_BLUR_KIND, &[]);
        let keys = vec![bezier_key(&mut ids, a.0, a.1), bezier_key(&mut ids, b.0, b.1)];
        e.parameters.insert(
            ClipEffect::BLURRINESS_KEY.to_string(),
            AnimatedProperty { value: a.1, track: KeyframeTrack::with_keys(keys) },
        );
        e
    }

    fn make(kind: &str, values: &[(&str, f64)]) -> ClipEffect {
        make_effect(&mut SequentialIds::default(), kind, values)
    }

    /// 1. Caption pop: scale 90 -> 105 @0.10 s -> 100 @0.13 s, linear, clip start.
    pub fn caption_pop() -> Vec<ClipEffect> {
        vec![Self::make(
            ClipEffect::POP_KIND,
            &[
                (Self::MODE, 0.0),
                (Self::CURVE, curve(MotionCurve::Linear)),
                (Self::DUR, 0.13),
                (ClipEffect::POP_FROM_KEY, 90.0),
                (ClipEffect::POP_PEAK_KEY, 105.0),
                (ClipEffect::POP_SETTLE_KEY, 100.0),
                (ClipEffect::POP_PEAK_AT_KEY, 0.10 / 0.13 * 100.0),
            ],
        )]
    }

    /// 2. Zoom In & Out (BOT; `top` adds the 0.1 s opacity ends): 100 -> 110 in 0.97 s, hold, 110 -> 100 over the last 1.1 s.
    pub fn zoom_in_out(top: bool) -> Vec<ClipEffect> {
        Self::zoom_pair(100.0, 110.0, top)
    }

    /// 3. Zoom Out & In: the inverse (110 -> 100 -> hold -> 110).
    pub fn zoom_out_in(top: bool) -> Vec<ClipEffect> {
        Self::zoom_pair(110.0, 100.0, top)
    }

    fn zoom_pair(from: f64, to: f64, top: bool) -> Vec<ClipEffect> {
        let mut out = vec![Self::make(
            ClipEffect::ZOOM_KIND,
            &[
                (Self::MODE, 2.0),
                (Self::CURVE, curve(MotionCurve::PremiereDefault)),
                (Self::DUR, 0.97),
                (ClipEffect::MOTION_OUT_DURATION_KEY, 1.1),
                (ClipEffect::ZOOM_FROM_KEY, from),
                (ClipEffect::ZOOM_TO_KEY, to),
            ],
        )];
        if top {
            out.push(Self::fade(2.0, 0.1));
        }
        out
    }

    /// 4. VideoStart IN: scale 100 -> 110 over 1.8 s ease-out, Gaussian Blur 40 -> 0 over the first 0.5 s.
    pub fn video_start_in() -> Vec<ClipEffect> {
        vec![
            Self::make(
                ClipEffect::ZOOM_KIND,
                &[
                    (Self::MODE, 0.0),
                    (Self::CURVE, curve(MotionCurve::EaseOut100)),
                    (Self::DUR, 1.8),
                    (ClipEffect::ZOOM_FROM_KEY, 100.0),
                    (ClipEffect::ZOOM_TO_KEY, 110.0),
                ],
            ),
            Self::blur((Time::ZERO, 40.0), (ms(0.5), 0.0)),
        ]
    }

    /// 5. VideoEnd: scale 100 -> 110 over the last 0.65 s, Gaussian Blur 0 -> 40 over the last 0.17 s. Needs the clip length.
    pub fn video_end(clip_duration: Time) -> Vec<ClipEffect> {
        vec![
            Self::make(
                ClipEffect::ZOOM_KIND,
                &[
                    (Self::MODE, 1.0),
                    (Self::CURVE, curve(MotionCurve::PremiereDefault)),
                    (Self::DUR, 0.65),
                    (ClipEffect::ZOOM_FROM_KEY, 100.0),
                    (ClipEffect::ZOOM_TO_KEY, 110.0),
                ],
            ),
            Self::blur((clip_duration - Time::new(17, 100), 0.0), (clip_duration, 40.0)),
        ]
    }

    /// Recipe 6, Move From Left / Right / Bottom: a 102 % frame width over 0.83 s, ease-out; bottom starts 0.085 of the height
    /// below center, takes 1.0 s and fades in over 0.14 s. The right side mirrors the left.
    pub fn move_from(side: RecipeSide) -> Vec<ClipEffect> {
        vec![match side {
            RecipeSide::Left => Self::move_effect(270.0, 102.0, 0.83, 0.0, None),
            RecipeSide::Right => Self::move_effect(90.0, 102.0, 0.83, 0.0, None),
            RecipeSide::Bottom => Self::move_effect(180.0, 8.5, 1.0, 0.0, Some(0.14)),
        }]
    }

    /// 7. Move To Right / Left / Bottom: over 0.83 s (bottom 1.1 s), at the end.
    pub fn move_to(side: RecipeSide) -> Vec<ClipEffect> {
        vec![match side {
            RecipeSide::Right => Self::move_effect(90.0, 101.0, 0.83, 1.0, None),
            RecipeSide::Left => Self::move_effect(270.0, 100.5, 0.83, 1.0, None),
            RecipeSide::Bottom => Self::move_effect(180.0, 44.0, 1.1, 1.0, None),
        }]
    }

    /// 8. Slide-in + overshoot: position 0.964 -> 0.5 over 0.38 s, scale 200 -> 104.6 -> 100.3 (hold) over 0.35 s.
    pub fn slide_in_overshoot() -> Vec<ClipEffect> {
        // Scale first, move second: the stages compose in list order, so the slide is not scaled with the pop.
        vec![
            Self::make(
                ClipEffect::POP_KIND,
                &[
                    (Self::MODE, 0.0),
                    (Self::CURVE, curve(MotionCurve::Linear)),
                    (Self::DUR, 0.35),
                    (ClipEffect::POP_FROM_KEY, 200.0),
                    (ClipEffect::POP_PEAK_KEY, 104.6),
                    (ClipEffect::POP_SETTLE_KEY, 100.3),
                    (ClipEffect::POP_PEAK_AT_KEY, 60.0),
                ],
            ),
            Self::move_effect(90.0, 46.4, 0.38, 0.0, None),
        ]
    }

    /// 9. Opacity fade over 3 frames (0.1 s), In at the start.
    pub fn fade_in() -> Vec<ClipEffect> {
        vec![Self::fade(0.0, 0.1)]
    }

    /// 9. Opacity fade over 3 frames (0.1 s), Out at the end.
    pub fn fade_out() -> Vec<ClipEffect> {
        vec![Self::fade(1.0, 0.1)]
    }

    /// 10. The "50 %" pop: scale 50 -> 95.6 @0.23 s -> 99.7 @0.33 s (hold).
    pub fn pop50() -> Vec<ClipEffect> {
        vec![Self::make(
            ClipEffect::POP_KIND,
            &[
                (Self::MODE, 0.0),
                (Self::CURVE, curve(MotionCurve::Linear)),
                (Self::DUR, 0.33),
                (ClipEffect::POP_FROM_KEY, 50.0),
                (ClipEffect::POP_PEAK_KEY, 95.6),
                (ClipEffect::POP_SETTLE_KEY, 99.7),
                (ClipEffect::POP_PEAK_AT_KEY, 0.23 / 0.33 * 100.0),
            ],
        )]
    }

    fn fade(mode: f64, d: f64) -> ClipEffect {
        Self::make(
            ClipEffect::FADE_KIND,
            &[(Self::MODE, mode), (Self::CURVE, curve(MotionCurve::Linear)), (Self::DUR, d)],
        )
    }

    fn move_effect(direction: f64, distance: f64, d: f64, mode: f64, fade: Option<f64>) -> ClipEffect {
        let side = [MoveSide::Left, MoveSide::Right, MoveSide::Top, MoveSide::Bottom]
            .into_iter()
            .find(|s| s.degrees() == Some(direction))
            .unwrap_or(MoveSide::Angle);
        let mut v = vec![
            (Self::MODE, mode),
            (Self::CURVE, curve(MotionCurve::EaseOut100)),
            (Self::DUR, d),
            (ClipEffect::MOVE_DIRECTION_KEY, direction),
            (ClipEffect::MOVE_DISTANCE_KEY, distance),
            (ClipEffect::MOVE_SIDE_KEY, side as i64 as f64),
        ];
        if let Some(f) = fade {
            v.push((ClipEffect::MOVE_FADE_KEY, 1.0));
            v.push((ClipEffect::MOVE_FADE_LENGTH_KEY, f));
        }
        Self::make(ClipEffect::MOVE_KIND, &v)
    }

    /// The effect of `kind` with these static values (shared with `MotionPresets`).
    pub(crate) fn effect(kind: &str, values: &[(&str, f64)]) -> ClipEffect {
        Self::make(kind, values)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::effect_transform_stage::ClipStageEval;
    use sq_core_model::{Clip, ClipTransform, TrackKind};
    use sq_core_time::{Id, TimeRange, Vec2};

    const W: f64 = 1920.0;
    const H: f64 = 1080.0;

    fn clip_with(effects: Vec<ClipEffect>, d: Time) -> Clip {
        let mut c = Clip::new(
            Id::from_u128(1),
            "v",
            Id::from_u128(2),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, d),
            Time::ZERO,
        );
        c.effects = effects;
        c
    }

    fn at(c: &Clip, t: Time) -> ClipTransform {
        c.render_transform(t, Vec2::new(W, H))
    }

    fn near(a: f64, b: f64, tol: f64) -> bool {
        (a - b).abs() <= tol
    }

    fn scale_px(t: &ClipTransform) -> f64 {
        t.scale.x * W
    }

    fn blur(c: &Clip) -> &AnimatedProperty<f64> {
        &c.effects[1].parameters[ClipEffect::BLURRINESS_KEY]
    }

    #[test]
    fn r1_caption_pop() {
        let c = clip_with(MotionRecipes::caption_pop(), Time::new(3, 1));
        assert!(near(scale_px(&at(&c, Time::ZERO)), 0.90 * W, 1.0));
        assert!(near(scale_px(&at(&c, ms(0.1))), 1.05 * W, 1.0));
        assert!(near(scale_px(&at(&c, ms(0.13))), 1.00 * W, 1.0));
        assert!(near(scale_px(&at(&c, Time::new(2, 1))), 1.00 * W, 1.0));
        // Linear between the keys: halfway to the peak is 97.5 %.
        assert!(near(scale_px(&at(&c, ms(0.05))), 0.975 * W, 1.5));
    }

    #[test]
    fn r2_and_r3_zoom_in_out_and_out_in() {
        let d = ms(3.67);
        for top in [false, true] {
            let c = clip_with(MotionRecipes::zoom_in_out(top), d);
            for t in [0.97, 1.8, 2.57] {
                assert!(near(scale_px(&at(&c, ms(t))), 1.10 * W, 1.0));
            }
            assert!(near(scale_px(&at(&c, ms(3.67))), W, 1.0));
            assert!(near(scale_px(&at(&c, Time::ZERO)), W, 1.0));
            assert!(near(at(&c, ms(1.8)).opacity, 1.0, 1e-9));
            if top {
                assert!(near(at(&c, Time::ZERO).opacity, 0.0, 1e-9) && near(at(&c, ms(0.1)).opacity, 1.0, 1e-9));
                assert!(near(at(&c, ms(3.57)).opacity, 1.0, 1e-9) && near(at(&c, ms(3.67)).opacity, 0.0, 1e-9));
            }
        }
        let inv = clip_with(MotionRecipes::zoom_out_in(false), d);
        assert!(near(scale_px(&at(&inv, Time::ZERO)), 1.10 * W, 1.0));
        assert!(near(scale_px(&at(&inv, ms(0.97))), W, 1.0));
        assert!(near(scale_px(&at(&inv, ms(2.57))), W, 1.0));
        assert!(near(scale_px(&at(&inv, ms(3.67))), 1.10 * W, 1.0));
    }

    #[test]
    fn r4_video_start_in() {
        let c = clip_with(MotionRecipes::video_start_in(), Time::new(5, 1));
        assert!(near(scale_px(&at(&c, Time::ZERO)), W, 1.0) && near(scale_px(&at(&c, ms(1.8))), 1.10 * W, 1.0));
        assert!(near(scale_px(&at(&c, Time::new(4, 1))), 1.10 * W, 1.0));
        let b = blur(&c);
        assert!(near(b.value_at_local(Time::ZERO), 40.0, 1e-9) && near(b.value_at_local(ms(0.5)), 0.0, 1e-9));
    }

    #[test]
    fn r5_video_end() {
        let d = Time::new(5, 1);
        let c = clip_with(MotionRecipes::video_end(d), d);
        assert!(near(scale_px(&at(&c, ms(4.35))), W, 1.0) && near(scale_px(&at(&c, d)), 1.10 * W, 1.0));
        assert!(near(scale_px(&at(&c, ms(2.0))), W, 1.0));
        let b = blur(&c);
        assert!(near(b.value_at_local(ms(4.83)), 0.0, 1e-9) && near(b.value_at_local(d), 40.0, 1e-9));
    }

    #[test]
    fn r6_move_from() {
        let d = Time::new(4, 1);
        let l = clip_with(MotionRecipes::move_from(RecipeSide::Left), d);
        assert!(near(at(&l, Time::ZERO).position.x, -1.02 * W, 1.0) && near(at(&l, ms(0.83)).position.x, 0.0, 1.0));
        let r = clip_with(MotionRecipes::move_from(RecipeSide::Right), d);
        assert!(near(at(&r, Time::ZERO).position.x, 1.02 * W, 1.0) && near(at(&r, ms(0.83)).position.x, 0.0, 1.0));
        let b = clip_with(MotionRecipes::move_from(RecipeSide::Bottom), d);
        assert!(near(at(&b, Time::ZERO).position.y, 0.085 * H, 1.0) && near(at(&b, ms(1.0)).position.y, 0.0, 1.0));
        assert!(near(at(&b, Time::ZERO).opacity, 0.0, 1e-9) && near(at(&b, ms(0.14)).opacity, 1.0, 1e-9));
        assert!(near(at(&b, ms(0.5)).opacity, 1.0, 1e-9));
    }

    #[test]
    fn r7_move_to() {
        let d = Time::new(4, 1);
        let r = clip_with(MotionRecipes::move_to(RecipeSide::Right), d);
        assert!(near(at(&r, ms(3.17)).position.x, 0.0, 1.0) && near(at(&r, d).position.x, 1.01 * W, 1.0));
        let l = clip_with(MotionRecipes::move_to(RecipeSide::Left), d);
        assert!(near(at(&l, d).position.x, -1.005 * W, 1.0));
        let b = clip_with(MotionRecipes::move_to(RecipeSide::Bottom), d);
        assert!(near(at(&b, d).position.y, 0.44 * H, 1.0) && near(at(&b, ms(2.9)).position.y, 0.0, 1.0));
    }

    #[test]
    fn r8_slide_in_overshoot() {
        let c = clip_with(MotionRecipes::slide_in_overshoot(), Time::new(4, 1));
        assert!(near(at(&c, Time::ZERO).position.x, 0.464 * W, 1.0) && near(at(&c, ms(0.38)).position.x, 0.0, 1.0));
        assert!(near(scale_px(&at(&c, Time::ZERO)), 2.0 * W, 1.0));
        assert!(near(scale_px(&at(&c, ms(0.35))), 1.003 * W, 1.0));
        assert!(near(scale_px(&at(&c, Time::new(3, 1))), 1.003 * W, 1.0));
        // The overshoot: the scale dips to 104.6 on the way down.
        assert!(near(scale_px(&at(&c, ms(0.21))), 1.046 * W, 1.0));
    }

    #[test]
    fn r9_fade() {
        let d = Time::new(4, 1);
        let i = clip_with(MotionRecipes::fade_in(), d);
        assert!(near(at(&i, Time::ZERO).opacity, 0.0, 1e-9) && near(at(&i, ms(0.1)).opacity, 1.0, 1e-9));
        assert!(near(at(&i, Time::new(2, 1)).opacity, 1.0, 1e-9));
        let o = clip_with(MotionRecipes::fade_out(), d);
        assert!(near(at(&o, ms(3.9)).opacity, 1.0, 1e-9) && near(at(&o, d).opacity, 0.0, 1e-9));
        assert!(near(at(&o, ms(1.0)).opacity, 1.0, 1e-9));
    }

    #[test]
    fn r10_pop50() {
        let c = clip_with(MotionRecipes::pop50(), Time::new(3, 1));
        assert!(near(scale_px(&at(&c, Time::ZERO)), 0.50 * W, 1.0));
        assert!(near(scale_px(&at(&c, ms(0.23))), 0.956 * W, 1.0));
        assert!(near(scale_px(&at(&c, ms(0.33))), 0.997 * W, 1.0));
        assert!(near(scale_px(&at(&c, Time::new(2, 1))), 0.997 * W, 1.0));
    }
}
