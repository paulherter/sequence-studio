// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MotionPresets.swift
//! FB-T3 built-in motion presets (Effects panel > Presets). Each is a stack of live motion effects on the clip's own
//! transform stage: it starts at its own 100 %, leaves the clip's Motion alone, and every value stays editable. They are
//! `EffectStackPreset`s of the `Motion` bin (one type with the keying presets, film looks and Voice).

use crate::effect_preset::Anchor;
use crate::effect_stack_preset::{EffectStackPreset, StackBin};
use crate::motion_effects::{MotionMode, MoveSide, MoveSpin};
use crate::motion_recipes::{MotionRecipes as R, bezier_key, make_effect, ms};
use sq_core_model::motion_easing::MotionCurve;
use sq_core_model::{AnimatedProperty, ClipEffect, hidden_catalog};
use sq_core_time::{Keyframe, KeyframeTrack, SequentialIds};

/// Swift `MotionPresets`.
pub struct MotionPresets;

type Values<'a> = &'a [(&'a str, f64)];

/// One motion effect: mode, curve and duration plus `values`.
fn e(kind: &str, curve: MotionCurve, duration: f64, mode: MotionMode, values: Values) -> ClipEffect {
    let mut v: Vec<(&str, f64)> = values.to_vec();
    v.push((ClipEffect::MOTION_MODE_KEY, mode as i64 as f64));
    v.push((ClipEffect::MOTION_CURVE_KEY, curve.raw_value() as f64));
    v.push((ClipEffect::MOTION_DURATION_KEY, duration));
    R::effect(kind, &v)
}

/// A Move preset effect; without a rotation key it spins not at all.
fn mv(side: MoveSide, distance: f64, curve: MotionCurve, duration: f64, mode: MotionMode, extra: Values) -> ClipEffect {
    let mut v: Vec<(&str, f64)> = extra.to_vec();
    v.push((ClipEffect::MOVE_SIDE_KEY, side as i64 as f64));
    v.push((ClipEffect::MOVE_DISTANCE_KEY, distance));
    if !extra.iter().any(|(k, _)| *k == ClipEffect::MOVE_ROTATION_KEY) {
        v.push((ClipEffect::MOVE_SPIN_KEY, MoveSpin::None as i64 as f64));
    }
    e(ClipEffect::MOVE_KIND, curve, duration, mode, &v)
}

/// A keyframed effect for the emphasis presets: static `values` plus `keys` per parameter as (seconds, value) pairs
/// (clip-local; end-anchored presets write them against a 1 s clip). Keys ease with Premiere's default bezier unless `linear`.
fn keyed(kind: &str, values: Values, keys: &[(&str, &[(f64, f64)])], linear: bool) -> ClipEffect {
    let mut ids = SequentialIds::default();
    let mut fx = make_effect(&mut ids, kind, values);
    for (param, pts) in keys {
        let ks = pts
            .iter()
            .map(|&(t, v)| {
                if linear {
                    use sq_core_time::IdSource;
                    Keyframe::new(ids.next_id(), ms(t), v)
                } else {
                    bezier_key(&mut ids, ms(t), v)
                }
            })
            .collect();
        fx.parameters
            .insert((*param).to_string(), AnimatedProperty { value: pts[0].1, track: KeyframeTrack::with_keys(ks) });
    }
    fx
}

fn fade_in(d: f64) -> ClipEffect {
    e(ClipEffect::FADE_KIND, MotionCurve::Linear, d, MotionMode::In, &[])
}

fn p(id: &str, name: &str, fx: Vec<ClipEffect>) -> EffectStackPreset {
    EffectStackPreset::new(id, name, StackBin::Motion, fx)
}

fn end(id: &str, name: &str, fx: Vec<ClipEffect>) -> EffectStackPreset {
    EffectStackPreset { anchor: Anchor::End, ..p(id, name, fx) }
}

impl MotionPresets {
    /// All built-in motion presets, in panel order.
    pub fn built_ins() -> Vec<EffectStackPreset> {
        use MotionCurve as C;
        use MotionMode::{In, Out};
        use MoveSide::{Angle, Bottom, Left, Right, Top};
        let repeat_edge: Values = &[(ClipEffect::REPEAT_EDGE_PIXELS_KEY, 1.0)];
        let fade_bottom: Values = &[(ClipEffect::MOVE_FADE_KEY, 1.0), (ClipEffect::MOVE_FADE_LENGTH_KEY, 0.14)];
        let zoom = ClipEffect::ZOOM_KIND;
        let (zf, zt) = (ClipEffect::ZOOM_FROM_KEY, ClipEffect::ZOOM_TO_KEY);
        let (pf, pk, ps, pa) = (
            ClipEffect::POP_FROM_KEY,
            ClipEffect::POP_PEAK_KEY,
            ClipEffect::POP_SETTLE_KEY,
            ClipEffect::POP_PEAK_AT_KEY,
        );
        vec![
            // The maintainer's Move From / To (0.83 s, Premiere Ease In 100 %; top / bottom move a short way and fade).
            p("moveFromLeft", "Move From Left", vec![mv(Left, 102.0, C::EaseOut100, 0.83, In, &[])]),
            p("moveFromRight", "Move From Right", vec![mv(Right, 102.0, C::EaseOut100, 0.83, In, &[])]),
            p("moveFromTop", "Move From Top", vec![mv(Top, 8.5, C::EaseOut100, 1.0, In, fade_bottom)]),
            p("moveFromBottom", "Move From Bottom", vec![mv(Bottom, 8.5, C::EaseOut100, 1.0, In, fade_bottom)]),
            p("moveToLeft", "Move To Left", vec![mv(Left, 100.5, C::EaseOut100, 0.83, Out, &[])]),
            p("moveToRight", "Move To Right", vec![mv(Right, 101.0, C::EaseOut100, 0.83, Out, &[])]),
            p("moveToTop", "Move To Top", vec![mv(Top, 44.0, C::EaseOut100, 1.1, Out, &[])]),
            p("moveToBottom", "Move To Bottom", vec![mv(Bottom, 44.0, C::EaseOut100, 1.1, Out, &[])]),
            // Short-form.
            p("popIn", "Pop In", vec![e(zoom, C::BackOut, 0.35, In, &[(zf, 60.0), (zt, 100.0)]), fade_in(0.12)]),
            p(
                "slideIn",
                "Slide In",
                vec![mv(
                    Right,
                    35.0,
                    C::QuintOut,
                    0.45,
                    In,
                    &[(ClipEffect::MOVE_FADE_KEY, 1.0), (ClipEffect::MOVE_FADE_LENGTH_KEY, 0.15)],
                )],
            ),
            p(
                "whipIn",
                "Whip In",
                vec![mv(Left, 102.0, C::ExpoOut, 0.3, In, &[(ClipEffect::STAGE_SHUTTER_ANGLE_KEY, 360.0)])],
            ),
            p("bounceIn", "Bounce In", vec![mv(Bottom, 60.0, C::BounceOut, 0.7, In, &[])]),
            p(
                "spinIn",
                "Spin In",
                vec![
                    e(zoom, C::BackOut, 0.5, In, &[(zf, 0.0), (zt, 100.0)]),
                    mv(
                        Left,
                        0.0,
                        C::CubicOut,
                        0.5,
                        In,
                        &[
                            (ClipEffect::MOVE_SPIN_KEY, MoveSpin::CounterClockwise as i64 as f64),
                            (ClipEffect::MOVE_ROTATION_KEY, 180.0),
                        ],
                    ),
                ],
            ),
            p("elasticIn", "Elastic Pop", vec![e(zoom, C::ElasticOut, 0.8, In, &[(zf, 70.0), (zt, 100.0)])]),
            // Drift: a slow push and sideways float over the first 4 s (longer clips hold the end).
            p(
                "drift",
                "Drift",
                vec![
                    e(zoom, C::SineInOut, 4.0, In, &[(zf, 100.0), (zt, 108.0)]),
                    mv(Angle, 3.0, C::SineInOut, 4.0, In, &[(ClipEffect::MOVE_DIRECTION_KEY, 250.0)]),
                ],
            ),
            // The maintainer's recipes (docs/RESEARCH-PAUL-CURVES.md section 3).
            p("captionPop", "Caption Pop", R::caption_pop()),
            p("pop50", "Pop 50%", R::pop50()),
            p("slideInOvershoot", "Slide In Overshoot", R::slide_in_overshoot()),
            p("zoomInOut", "Zoom In & Out", R::zoom_in_out(false)),
            p("zoomOutIn", "Zoom Out & In", R::zoom_out_in(false)),
            // Emphasis: live effects and keys on the clip, all editable afterwards. Punch-In: 100 -> 118 % in 6 frames.
            p("punchIn", "Punch-In", vec![e(zoom, C::EaseOut100, 0.2, In, &[(zf, 100.0), (zt, 118.0)])]),
            // Camera Shake: Transform at 115 % (hides the moving edges) with Shutter Angle 360, plus a Shake over the whole clip.
            p(
                "cameraShake",
                "Camera Shake",
                vec![
                    R::effect(
                        ClipEffect::TRANSFORM_KIND,
                        &[(ClipEffect::STAGE_SCALE_KEY, 115.0), (ClipEffect::STAGE_SHUTTER_ANGLE_KEY, 360.0)],
                    ),
                    R::effect(
                        ClipEffect::SHAKE_KIND,
                        &[
                            (ClipEffect::SHAKE_STRENGTH_KEY, 2.5),
                            (ClipEffect::SHAKE_ROTATION_KEY, 1.2),
                            (ClipEffect::SHAKE_SPEED_KEY, 10.0),
                        ],
                    ),
                ],
            ),
            // RGB Split Hit: color fringes of 30 px that settle in 8 frames.
            p(
                "rgbSplitHit",
                "RGB Split Hit",
                vec![keyed(
                    ClipEffect::RGB_SPLIT_KIND,
                    &[(ClipEffect::RGB_SPLIT_ANGLE_KEY, 0.0)],
                    &[(ClipEffect::RGB_SPLIT_AMOUNT_KEY, &[(0.0, 30.0), (0.27, 0.0)])],
                    false,
                )],
            ),
            // Pop 0-120-100: scale 0 / 120 / 100 % at frames 0 / 4 / 10 (30 fps).
            p(
                "pop0120100",
                "Pop 0-120-100",
                vec![e(
                    ClipEffect::POP_KIND,
                    C::Linear,
                    10.0 / 30.0,
                    In,
                    &[(pf, 0.0), (pk, 120.0), (ps, 100.0), (pa, 40.0)],
                )],
            ),
            // Whip Blur In / Out: Gaussian Blur 1000 -> 0 over 5 frames with Repeat Edge Pixels and a horizontal smear.
            // Put In on the incoming clip and Out on the outgoing one; together they are 0 / 1000 / 0 around the cut.
            p(
                "whipBlurIn",
                "Whip Blur In",
                vec![
                    keyed(
                        ClipEffect::GAUSSIAN_BLUR_KIND,
                        repeat_edge,
                        &[(ClipEffect::BLURRINESS_KEY, &[(0.0, 1000.0), (0.17, 0.0)])],
                        false,
                    ),
                    keyed(
                        ClipEffect::DIRECTIONAL_BLUR_KIND,
                        &[(ClipEffect::BLUR_DIRECTION_KEY, 90.0)],
                        &[(ClipEffect::BLUR_LENGTH_KEY, &[(0.0, 250.0), (0.17, 0.0)])],
                        false,
                    ),
                ],
            ),
            end(
                "whipBlurOut",
                "Whip Blur Out",
                vec![
                    keyed(
                        ClipEffect::GAUSSIAN_BLUR_KIND,
                        repeat_edge,
                        &[(ClipEffect::BLURRINESS_KEY, &[(0.83, 0.0), (1.0, 1000.0)])],
                        false,
                    ),
                    keyed(
                        ClipEffect::DIRECTIONAL_BLUR_KIND,
                        &[(ClipEffect::BLUR_DIRECTION_KEY, 90.0)],
                        &[(ClipEffect::BLUR_LENGTH_KEY, &[(0.83, 0.0), (1.0, 250.0)])],
                        false,
                    ),
                ],
            ),
            // RGB Glitch: RGB Split jumps (hard keys) while a Mosaic goes 500 -> 20 x 10 blocks over 9 frames and clears again.
            p(
                "rgbGlitch",
                "RGB Glitch",
                vec![
                    keyed(
                        ClipEffect::RGB_SPLIT_KIND,
                        &[(ClipEffect::RGB_SPLIT_ANGLE_KEY, 0.0)],
                        &[(
                            ClipEffect::RGB_SPLIT_AMOUNT_KEY,
                            &[(0.0, 0.0), (0.07, 30.0), (0.13, 12.0), (0.2, 36.0), (0.27, 0.0)],
                        )],
                        true,
                    ),
                    keyed(
                        ClipEffect::MOSAIC_KIND,
                        &[],
                        &[
                            (ClipEffect::MOSAIC_COLUMNS_KEY, &[(0.0, 500.0), (0.15, 20.0), (0.3, 4000.0)]),
                            (ClipEffect::MOSAIC_ROWS_KEY, &[(0.0, 500.0), (0.15, 10.0), (0.3, 4000.0)]),
                        ],
                        true,
                    ),
                ],
            ),
            // Ghost Frame: a doubled, glowing image (RGB Split blended 50 % with the original) on a stepped 8 fps time.
            p(
                "ghostFrame",
                "Ghost Frame",
                vec![
                    R::effect(ClipEffect::POSTERIZE_TIME_KIND, &[(ClipEffect::POSTERIZE_RATE_KEY, 8.0)]),
                    R::effect(
                        ClipEffect::RGB_SPLIT_KIND,
                        &[
                            (ClipEffect::RGB_SPLIT_AMOUNT_KEY, 24.0),
                            (ClipEffect::RGB_SPLIT_ANGLE_KEY, 0.0),
                            (ClipEffect::RGB_SPLIT_BLEND_KEY, 50.0),
                        ],
                    ),
                    R::effect(ClipEffect::GLOW_KIND, &[]),
                ],
            ),
        ]
    }

    /// The motion bin without the hidden ones; `EffectStackPresets::preset` still finds every one.
    pub fn offered() -> Vec<EffectStackPreset> {
        Self::built_ins().into_iter().filter(|p| !hidden_catalog::is_hidden_motion_preset(&p.id)).collect()
    }

    /// The built-in preset with this display name.
    pub fn built_in_named(name: &str) -> Option<EffectStackPreset> {
        Self::built_ins().into_iter().find(|p| p.name == name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::effect_preset::{ApplyMode, ClipEffectPresetExt};
    use crate::effect_stack_preset::EffectStackPresets;
    use crate::effect_transform_stage::{ClipEffectStage, ClipStageEval};
    use sq_core_model::{Clip, EffectCatalog, TrackKind};
    use sq_core_time::{Id, Time, TimeRange, Vec2};
    use std::collections::BTreeSet;

    const EMPHASIS: [&str; 8] = [
        "Punch-In",
        "Camera Shake",
        "RGB Split Hit",
        "Pop 0-120-100",
        "Whip Blur In",
        "Whip Blur Out",
        "RGB Glitch",
        "Ghost Frame",
    ];

    fn frame() -> Vec2 {
        Vec2::new(1920.0, 1080.0)
    }

    fn clip(seconds: i64) -> Clip {
        let source = TimeRange::new(Time::ZERO, Time::new(seconds, 1));
        Clip::new(Id::from_u128(1), "v", Id::from_u128(2), TrackKind::Video, source, Time::ZERO)
    }

    fn preset(name: &str) -> EffectStackPreset {
        MotionPresets::built_in_named(name).expect("listed preset")
    }

    fn apply(c: &mut Clip, name: &str) {
        c.apply_preset(&preset(name).preset(), ApplyMode::Absolute, None, &mut SequentialIds::default());
    }

    fn scale(c: &Clip, t: Time) -> f64 {
        c.render_transform(t, frame()).scale.x
    }

    #[test]
    fn built_ins_are_unique_and_only_effects() {
        let all = MotionPresets::built_ins();
        let ids: BTreeSet<_> = all.iter().map(|p| p.id.clone()).collect();
        let names: BTreeSet<_> = all.iter().map(|p| p.name.clone()).collect();
        assert!(ids.len() == all.len() && names.len() == all.len());
        for n in ["Move From Left", "Move To Bottom", "Pop In", "Slide In", "Whip In", "Bounce In", "Drift"] {
            assert!(all.iter().any(|p| p.name == n), "{n}");
        }
        for p in &all {
            assert!(!p.effects.is_empty() && p.preset().motion_properties().is_empty(), "{}", p.name);
            if !EMPHASIS.contains(&p.name.as_str()) {
                assert!(p.effects.iter().all(|e| e.is_transform_stage()), "{}: its own transform stage", p.name);
            }
            assert!(p.effects.iter().all(|e| EffectCatalog::spec_for(&e.kind).is_some()), "{}: known kinds", p.name);
        }
        assert!(EMPHASIS.iter().all(|n| MotionPresets::built_in_named(n).is_some()));
    }

    #[test]
    fn move_from_left_and_right_are_one_unkeyed_effect_each() {
        let l = preset("Move From Left").effects;
        let r = preset("Move From Right").effects;
        assert!(
            l.len() == 1 && r.len() == 1 && l[0].kind == ClipEffect::MOVE_KIND && r[0].kind == ClipEffect::MOVE_KIND
        );
        assert_eq!(l[0].parameters[ClipEffect::MOVE_SIDE_KEY].value, 0.0);
        assert_eq!(r[0].parameters[ClipEffect::MOVE_SIDE_KEY].value, 1.0);
        assert!(l[0].key_times().is_empty(), "start values, not locks");
    }

    #[test]
    fn applying_keeps_the_clip_motion() {
        let mut c = clip(3);
        c.animation.scale = AnimatedProperty::new(Vec2::new(1.5, 1.5));
        apply(&mut c, "Slide In");
        assert_eq!(c.animation.scale.value, Vec2::new(1.5, 1.5));
        assert!(c.effects.len() == 1 && c.effects[0].kind == ClipEffect::MOVE_KIND);
        let rest = c.render_transform(Time::new(2, 1), frame());
        assert!((rest.scale.x - 1.5).abs() < 1e-9 && rest.position == Vec2::ZERO);
    }

    #[test]
    fn every_entrance_moves_and_comes_to_rest() {
        let entrances = [
            "Move From Left",
            "Move From Right",
            "Move From Top",
            "Move From Bottom",
            "Pop In",
            "Slide In",
            "Whip In",
            "Bounce In",
            "Spin In",
            "Elastic Pop",
        ];
        for p in MotionPresets::built_ins().iter().filter(|p| entrances.contains(&p.name.as_str())) {
            let mut c = clip(6);
            apply(&mut c, &p.name);
            let start = c.render_transform(Time::ZERO, frame());
            let rest = c.render_transform(Time::new(5, 1), frame());
            assert!(start != rest, "{} animates", p.name);
            assert!(
                rest.position == Vec2::ZERO
                    && (rest.scale.x - 1.0).abs() < 1e-9
                    && (rest.opacity - 1.0).abs() < 1e-9
                    && rest.rotation.abs() < 1e-9,
                "{} rests at 100 %",
                p.name
            );
        }
    }

    #[test]
    fn punch_in_scales_to_about_118_with_ease() {
        let mut c = clip(4);
        apply(&mut c, "Punch-In");
        assert!((scale(&c, Time::ZERO) - 1.0).abs() < 1e-9);
        assert!((scale(&c, Time::new(3, 1)) - 1.18).abs() < 1e-6, "holds the punched-in size");
        let mid = scale(&c, Time::new(1, 10));
        assert!(mid > 1.09 && mid < 1.18, "ease-out: past the halfway point at half the time");
    }

    #[test]
    fn pop_goes_zero_to_120_to_100_in_ten_frames() {
        let mut c = clip(4);
        apply(&mut c, "Pop 0-120-100");
        assert!(scale(&c, Time::ZERO) < 0.01);
        assert!((scale(&c, Time::new(4, 30)) - 1.2).abs() < 0.01, "peak at frame 4");
        assert!((scale(&c, Time::new(10, 30)) - 1.0).abs() < 1e-6, "settled at frame 10");
        assert!((scale(&c, Time::new(3, 1)) - 1.0).abs() < 1e-9);
    }

    #[test]
    fn camera_shake_holds_scale_115_with_shutter_360_and_keeps_shaking() {
        let mut c = clip(4);
        apply(&mut c, "Camera Shake");
        assert!((scale(&c, Time::new(2, 1)) - 1.15).abs() < 1e-6);
        let a = c.render_transform(Time::new(11, 10), frame());
        let b = c.render_transform(Time::new(23, 10), frame());
        assert!(a.position != b.position, "shakes for the whole clip");
        assert!(c.effects.iter().any(|e| e.stage_shutter_angle(Time::new(1, 1)) == 360.0));
    }

    #[test]
    fn whip_blur_in_peaks_at_the_start_and_ends_clear() {
        let mut c = clip(4);
        apply(&mut c, "Whip Blur In");
        let blur = c.effects.iter().find(|e| e.kind == ClipEffect::GAUSSIAN_BLUR_KIND).expect("blur");
        let b = &blur.parameters[ClipEffect::BLURRINESS_KEY];
        assert_eq!(b.value_at_local(Time::ZERO), 1000.0);
        assert_eq!(b.value_at_local(Time::new(3, 1)), 0.0);
        assert_eq!(blur.parameters[ClipEffect::REPEAT_EDGE_PIXELS_KEY].value, 1.0, "edge pixels repeated, no gaps");
    }

    #[test]
    fn ghost_frame_stacks_posterize_time_rgb_split_and_glow() {
        let kinds: Vec<_> = preset("Ghost Frame").effects.into_iter().map(|e| e.kind).collect();
        for k in [ClipEffect::POSTERIZE_TIME_KIND, ClipEffect::RGB_SPLIT_KIND, ClipEffect::GLOW_KIND] {
            assert!(kinds.iter().any(|x| x == k));
        }
    }

    #[test]
    fn hidden_motion_presets_are_not_offered_but_still_apply() {
        let all: BTreeSet<_> = MotionPresets::built_ins().into_iter().map(|p| p.id).collect();
        let hidden: BTreeSet<String> = hidden_catalog::MOTION_PRESET_IDS.iter().map(|s| s.to_string()).collect();
        assert!(hidden.is_subset(&all), "a hidden id that does not exist");
        let offered: BTreeSet<_> = MotionPresets::offered().into_iter().map(|p| p.id).collect();
        if hidden_catalog::is_hidden_motion_preset("moveFromLeft") {
            assert!(offered.is_disjoint(&hidden));
            assert_eq!(offered.len() + hidden.len(), all.len());
        }
        for id in ["whipIn", "elasticIn", "bounceIn", "spinIn", "slideInOvershoot", "captionPop", "ghostFrame"] {
            assert!(offered.contains(id), "{id} is kept");
        }
        for id in &hidden {
            let p = EffectStackPresets::preset(id).expect("still resolves");
            let mut c = clip(3);
            c.apply_preset(&p.preset(), ApplyMode::Absolute, None, &mut SequentialIds::default());
            assert_eq!(
                c.effects.iter().map(|e| &e.kind).collect::<Vec<_>>(),
                p.effects.iter().map(|e| &e.kind).collect::<Vec<_>>()
            );
        }
    }
}
