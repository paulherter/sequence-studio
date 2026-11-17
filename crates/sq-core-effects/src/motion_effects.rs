// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MotionEffects.swift
//! W7.4 parametric motion effects. Eight built-in effects (Move, Zoom, Pop, Fade, Shake and the loop animators Bounce,
//! Pulse, Wiggle) each evaluate live on the effect transform stage (`ClipEffect::is_transform_stage`): no keyframes are
//! written, the stage reads its parameters at the clip-local time. Catalog rows and keys live in `sq-core-model`.
//!
//! Progress: with edge length d, `u_in` is the eased 0...1 progress of the first d seconds of the clip and `u_out` that of
//! the last d seconds (0 before, 1 at the clip's end); Loop uses the eased triangle wave of period d. Each type maps these
//! onto its own transform:
//! - Move: displacement (share of the full distance): In 1 - uIn, Out uOut, In & Out both, Loop triangle. Direction =
//!   where the picture comes from / goes to (0 = top, 90 = right, 180 = bottom, 270 = left, clockwise). Distance is a % of
//!   the frame along that direction; Rotation (deg) is reached at full displacement; optional fade.
//! - Zoom: scale From % -> To %: In from -> to at the start (then holds `to`), Out from (held) -> to at the end, In & Out
//!   from -> to -> hold -> from, Loop from -> to -> from.
//! - Pop: scale From % -> Peak % (at Peak at % of the duration) -> Settle %, one pass through the three values.
//! - Fade: opacity Edge % -> 100 % (In), 100 -> Edge (Out), both, Loop pulse.
//! - Shake: smooth noise offset (% of the frame) and rotation at a constant strength over the whole clip (no mode, no
//!   edge window: an effect acts for the clip's full length, the edge version is the Shake transition).

use sq_core_model::motion_easing::{CubicBezierEase, MotionCurve};
use sq_core_model::{ClipEffect, EffectCatalog, StageTransform};
use sq_core_time::keyframes_model::keyframe_math;
use sq_core_time::{Time, Vec2};
use std::f64::consts::PI;

/// Stored key of an element transition's exact span in seconds (ElementTransitions.swift); it replaces the Duration.
const ELEMENT_SPAN_KEY: &str = "elementSpan";

/// When a motion effect acts on the clip.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MotionMode {
    /// At the clip's start.
    In = 0,
    /// At the clip's end.
    Out = 1,
    /// At both ends.
    InOut = 2,
    /// Repeating with the Duration as period.
    Loop = 3,
}

impl MotionMode {
    /// Titles in raw order.
    pub const TITLES: [&'static str; 4] = ["In", "Out", "In & Out", "Loop"];

    /// The case with raw value `raw`.
    pub fn from_raw(raw: i64) -> Option<MotionMode> {
        match raw {
            0 => Some(MotionMode::In),
            1 => Some(MotionMode::Out),
            2 => Some(MotionMode::InOut),
            3 => Some(MotionMode::Loop),
            _ => None,
        }
    }
}

/// Where a Move comes from / goes to. `Angle` uses the Angle slider.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MoveSide {
    /// From the left.
    Left = 0,
    /// From the right.
    Right = 1,
    /// From the top.
    Top = 2,
    /// From the bottom.
    Bottom = 3,
    /// The Angle slider.
    Angle = 4,
}

impl MoveSide {
    /// Titles in raw order.
    pub const TITLES: [&'static str; 5] = ["Left", "Right", "Top", "Bottom", "Angle"];

    /// The case with raw value `raw`.
    pub fn from_raw(raw: i64) -> Option<MoveSide> {
        match raw {
            0 => Some(MoveSide::Left),
            1 => Some(MoveSide::Right),
            2 => Some(MoveSide::Top),
            3 => Some(MoveSide::Bottom),
            4 => Some(MoveSide::Angle),
            _ => None,
        }
    }

    /// Direction in degrees (0 = top, clockwise); `None` for `Angle`.
    pub fn degrees(self) -> Option<f64> {
        match self {
            MoveSide::Left => Some(270.0),
            MoveSide::Right => Some(90.0),
            MoveSide::Top => Some(0.0),
            MoveSide::Bottom => Some(180.0),
            MoveSide::Angle => None,
        }
    }
}

/// Which way a Move turns while it travels; Rotation Strength is the angle at full displacement.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MoveSpin {
    /// No turn.
    None = 0,
    /// Clockwise.
    Clockwise = 1,
    /// Counter-clockwise.
    CounterClockwise = 2,
}

impl MoveSpin {
    /// Titles in raw order.
    pub const TITLES: [&'static str; 3] = ["None", "Clockwise", "Counter-clockwise"];

    /// The case with raw value `raw`.
    pub fn from_raw(raw: i64) -> Option<MoveSpin> {
        match raw {
            0 => Some(MoveSpin::None),
            1 => Some(MoveSpin::Clockwise),
            2 => Some(MoveSpin::CounterClockwise),
            _ => None,
        }
    }
}

/// Evaluation of the parametric motion effects.
pub enum MotionEffects {}

impl MotionEffects {
    /// Smooth deterministic noise in -1...1 (cubic-interpolated hashed lattice).
    pub(crate) fn noise(x: f64, seed: u64) -> f64 {
        fn h(i: i64, seed: u64) -> f64 {
            let mut z = (i as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ seed.wrapping_mul(0xC2B2_AE3D_27D4_EB4F);
            z ^= z >> 30;
            z = z.wrapping_mul(0xBF58_476D_1CE4_E5B9);
            z ^= z >> 27;
            z = z.wrapping_mul(0x94D0_49BB_1331_11EB);
            z ^= z >> 31;
            (z >> 11) as f64 / (1u64 << 53) as f64 * 2.0 - 1.0
        }
        let f = x.floor();
        let u = x - f;
        let s = u * u * (3.0 - 2.0 * u);
        let i = f as i64;
        h(i, seed) * (1.0 - s) + h(i.wrapping_add(1), seed) * s
    }

    /// The stage of motion effect `e` at clip-local `t` in a clip of timeline length `clip_duration` on a `frame` (px).
    pub(crate) fn stage(e: &ClipEffect, t: Time, clip_duration: Option<Time>, frame: Vec2) -> StageTransform {
        if !e.is_motion_preset() {
            return StageTransform::IDENTITY;
        }
        let Some(spec) = EffectCatalog::spec_for(&e.kind) else { return StageTransform::IDENTITY };
        let v = |k: &str| -> f64 {
            let param = spec.params.iter().find(|p| p.key == k);
            let x = e.parameters.get(k).map(|p| p.value_at_local(t)).or(param.map(|p| p.default_value)).unwrap_or(0.0);
            match param {
                Some(p) => x.clamp(*p.range.start(), *p.range.end()),
                None => x,
            }
        };
        if let Some(loop_stage) = Self::loop_stage(&e.kind, keyframe_math::seconds(t), frame, &v) {
            return loop_stage;
        }
        let mode = MotionMode::from_raw(v(ClipEffect::MOTION_MODE_KEY).round() as i64).unwrap_or(MotionMode::In);
        let curve_kind = MotionCurve::from_raw(v(ClipEffect::MOTION_CURVE_KEY).round() as i64)
            .unwrap_or(MotionCurve::PremiereDefault);
        let custom: Option<CubicBezierEase> = if curve_kind == MotionCurve::Custom { e.custom_curve() } else { None };
        let ease = |x: f64| curve_kind.ease(x, custom);
        // An element transition's span is its exact length (not limited to the Duration's 60 s).
        let span = e.parameters.get(ELEMENT_SPAN_KEY).map(|p| p.value_at_local(t).max(1e-6));
        let d_in = span.unwrap_or_else(|| v(ClipEffect::MOTION_DURATION_KEY));
        let d_out_raw = if span.is_none() { v(ClipEffect::MOTION_OUT_DURATION_KEY) } else { 0.0 };
        let d_out = if d_out_raw > 0.0 { d_out_raw } else { d_in };
        let local = keyframe_math::seconds(t);
        // None clip length = no end edge: Out windows never start, end fades never run.
        let total: Option<f64> =
            clip_duration.and_then(|d| if d.value() > 0 { Some(keyframe_math::seconds(d)) } else { None });

        // Edge progress: eased, 0 before the edge window, 1 after it.
        let u_in = ease(local / d_in);
        let u_out = total.map_or(0.0, |tot| ease((local - (tot - d_out)) / d_out));
        let mut phase = (local / d_in) % 1.0;
        if phase < 0.0 {
            phase += 1.0;
        }
        let tri = ease(1.0 - (2.0 * phase - 1.0).abs());

        match e.kind.as_str() {
            ClipEffect::MOVE_KIND => {
                let share = match mode {
                    MotionMode::In => 1.0 - u_in,
                    MotionMode::Out => u_out,
                    MotionMode::InOut => f64::min((1.0 - u_in) + u_out, 1.0),
                    MotionMode::Loop => tri,
                };
                // Older effects without the Direction pop-up use the angle; without the Rotation pop-up the signed strength.
                let side = if !e.parameters.contains_key(ClipEffect::MOVE_SIDE_KEY) {
                    MoveSide::Angle
                } else {
                    MoveSide::from_raw(v(ClipEffect::MOVE_SIDE_KEY).round() as i64).unwrap_or(MoveSide::Left)
                };
                let a = side.degrees().unwrap_or_else(|| v(ClipEffect::MOVE_DIRECTION_KEY)) * PI / 180.0;
                let dist =
                    v(ClipEffect::MOVE_DISTANCE_KEY) / 100.0 * (a.sin().abs() * frame.x + a.cos().abs() * frame.y);
                let strength = v(ClipEffect::MOVE_ROTATION_KEY);
                let rotation = if !e.parameters.contains_key(ClipEffect::MOVE_SPIN_KEY) {
                    strength
                } else {
                    match MoveSpin::from_raw(v(ClipEffect::MOVE_SPIN_KEY).round() as i64).unwrap_or(MoveSpin::None) {
                        MoveSpin::None => 0.0,
                        MoveSpin::Clockwise => strength.abs(),
                        MoveSpin::CounterClockwise => -strength.abs(),
                    }
                };
                let edge_scale = v(ClipEffect::MOVE_SCALE_KEY) / 100.0;
                let mut opacity = 1.0;
                if v(ClipEffect::MOVE_FADE_KEY) >= 0.5 && mode != MotionMode::Loop {
                    let len = v(ClipEffect::MOVE_FADE_LENGTH_KEY).max(1e-6);
                    let fin = if mode == MotionMode::Out { 1.0 } else { (local / len).clamp(0.0, 1.0) };
                    let fout = if mode == MotionMode::In {
                        1.0
                    } else {
                        total.map_or(1.0, |tot| ((tot - local) / len).clamp(0.0, 1.0))
                    };
                    opacity = fin * fout;
                }
                StageTransform {
                    position: Vec2::new(a.sin() * dist * share, -a.cos() * dist * share),
                    scale: (1.0 + (edge_scale - 1.0) * share).max(0.0),
                    rotation: rotation * share,
                    opacity,
                    ..StageTransform::IDENTITY
                }
            }
            ClipEffect::ZOOM_KIND => {
                let from = v(ClipEffect::ZOOM_FROM_KEY);
                let to = v(ClipEffect::ZOOM_TO_KEY);
                let pct = match mode {
                    MotionMode::In => from + (to - from) * u_in,
                    MotionMode::Out => from + (to - from) * u_out,
                    MotionMode::InOut => from + (to - from) * u_in * (1.0 - u_out),
                    MotionMode::Loop => from + (to - from) * tri,
                };
                StageTransform { scale: pct / 100.0, ..StageTransform::IDENTITY }
            }
            ClipEffect::POP_KIND => {
                let from = v(ClipEffect::POP_FROM_KEY);
                let peak = v(ClipEffect::POP_PEAK_KEY);
                let settle = v(ClipEffect::POP_SETTLE_KEY).max(1e-6);
                let at = v(ClipEffect::POP_PEAK_AT_KEY) / 100.0;
                let s = |tau: f64, d: f64| -> f64 {
                    let x = (tau / d).clamp(0.0, 1.0);
                    if x < at {
                        from + (peak - from) * ease(x / at)
                    } else {
                        peak + (settle - peak) * ease((x - at) / (1.0 - at))
                    }
                };
                let s_out = total.map_or(settle, |tot| s(tot - local, d_out));
                let pct = match mode {
                    MotionMode::In => s(local, d_in),
                    MotionMode::Out => s_out / settle * 100.0,
                    MotionMode::InOut => s(local, d_in) * s_out / settle,
                    MotionMode::Loop => {
                        let mut tau = local % d_in;
                        if tau < 0.0 {
                            tau += d_in;
                        }
                        s(tau, d_in) / settle * 100.0
                    }
                };
                StageTransform { scale: pct / 100.0, ..StageTransform::IDENTITY }
            }
            ClipEffect::FADE_KIND => {
                let lo = v(ClipEffect::FADE_START_KEY) / 100.0;
                let o = match mode {
                    MotionMode::In => lo + (1.0 - lo) * u_in,
                    MotionMode::Out => lo + (1.0 - lo) * (1.0 - u_out),
                    MotionMode::InOut => (lo + (1.0 - lo) * u_in) * (lo + (1.0 - lo) * (1.0 - u_out)),
                    MotionMode::Loop => lo + (1.0 - lo) * tri,
                };
                StageTransform { opacity: o, ..StageTransform::IDENTITY }
            }
            ClipEffect::SHAKE_KIND => {
                // A whole-clip effect: projects saved while Shake still had a Mode (In, Out, In & Out) shake all the way too.
                let seed = v(ClipEffect::SHAKE_SEED_KEY).max(0.0).round() as u64;
                let x = local * v(ClipEffect::SHAKE_SPEED_KEY);
                let amp = v(ClipEffect::SHAKE_STRENGTH_KEY) / 100.0;
                StageTransform {
                    position: Vec2::new(
                        Self::noise(x, seed.wrapping_mul(3).wrapping_add(1)) * amp * frame.x,
                        Self::noise(x, seed.wrapping_mul(3).wrapping_add(2)) * amp * frame.y,
                    ),
                    rotation: Self::noise(x, seed.wrapping_mul(3).wrapping_add(3)) * v(ClipEffect::SHAKE_ROTATION_KEY),
                    ..StageTransform::IDENTITY
                }
            }
            _ => StageTransform::IDENTITY,
        }
    }

    /// Loop phase 0...1 at `local` seconds (Phase shifts it); periodic with the Period, pure in `local`.
    pub(crate) fn loop_phase(local: f64, period: f64, offset: f64) -> f64 {
        let p = period.max(1e-6);
        let mut x = (local / p + offset) % 1.0;
        if x < 0.0 {
            x += 1.0;
        }
        x
    }

    /// The N3 loop animators (`None` for every other kind).
    pub(crate) fn loop_stage(kind: &str, local: f64, frame: Vec2, v: &dyn Fn(&str) -> f64) -> Option<StageTransform> {
        if kind != ClipEffect::BOUNCE_KIND && kind != ClipEffect::PULSE_KIND && kind != ClipEffect::WIGGLE_KIND {
            return None;
        }
        let ph = Self::loop_phase(local, v(ClipEffect::LOOP_PERIOD_KEY), v(ClipEffect::LOOP_PHASE_KEY) / 100.0);
        Some(match kind {
            ClipEffect::BOUNCE_KIND => {
                // Hop arc: 0 at the ground, 1 at the top (parabola), so each Period is one bounce.
                let arc = 1.0 - (2.0 * ph - 1.0).powi(2);
                let a = v(ClipEffect::BOUNCE_DIRECTION_KEY) * PI / 180.0;
                let dist = v(ClipEffect::BOUNCE_HEIGHT_KEY) / 100.0
                    * (a.sin().abs() * frame.x + a.cos().abs() * frame.y)
                    * arc;
                // Squash: stretched at the top, flattened at the ground contact (uniform scale stays in the stage model).
                let sq = v(ClipEffect::BOUNCE_SQUASH_KEY) / 100.0;
                StageTransform {
                    position: Vec2::new(a.sin() * dist, -a.cos() * dist),
                    scale: 1.0 + sq * (arc - 0.5) * 0.5,
                    ..StageTransform::IDENTITY
                }
            }
            ClipEffect::PULSE_KIND => {
                let s = (1.0 - (2.0 * PI * ph).cos()) / 2.0; // 0 -> 1 -> 0, smooth
                let from = v(ClipEffect::PULSE_FROM_KEY);
                let to = v(ClipEffect::PULSE_TO_KEY);
                StageTransform {
                    scale: (from + (to - from) * s) / 100.0,
                    opacity: 1.0 - v(ClipEffect::PULSE_FADE_KEY) / 100.0 * (1.0 - s),
                    ..StageTransform::IDENTITY
                }
            }
            _ => {
                let w = (2.0 * PI * ph).sin();
                StageTransform {
                    position: Vec2::new(w * v(ClipEffect::WIGGLE_SHIFT_KEY) / 100.0 * frame.x, 0.0),
                    rotation: w * v(ClipEffect::WIGGLE_ANGLE_KEY),
                    ..StageTransform::IDENTITY
                }
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::effect_transform_stage::{ClipEffectStage, ClipStageEval};
    use sq_core_model::{AnimatedProperty, Clip, ClipTransform, TrackKind};
    use sq_core_time::{Id, TimeRange};

    const W: f64 = 1920.0;
    const H: f64 = 1080.0;

    fn ms(n: i64) -> Time {
        Time::new(n, 1000)
    }

    fn effect(kind: &str) -> ClipEffect {
        ClipEffect::make(Id::from_u128(7), kind).expect("catalog kind")
    }

    fn clip(effects: Vec<ClipEffect>) -> Clip {
        let source = TimeRange::new(Time::ZERO, Time::new(4, 1));
        let mut c = Clip::new(Id::from_u128(1), "v", Id::from_u128(2), TrackKind::Video, source, Time::ZERO);
        c.effects = effects;
        c
    }

    fn at(c: &Clip, t: Time) -> ClipTransform {
        c.render_transform(t, Vec2::new(W, H))
    }

    fn near(a: f64, b: f64, tol: f64) -> bool {
        (a - b).abs() <= tol
    }

    fn set(e: &mut ClipEffect, key: &str, v: f64) {
        e.parameters.insert(key.to_string(), AnimatedProperty::new(v));
    }

    #[test]
    fn motion_kinds_are_stages() {
        for k in ["motionMove", "motionZoom", "motionPop", "motionFade", "motionShake"] {
            // FB-G: Move, Zoom, Pop and Fade are transitions now; they still evaluate in old projects.
            assert_eq!(EffectCatalog::all().iter().any(|s| s.kind == k), k == "motionShake");
            assert!(effect(k).is_transform_stage());
        }
    }

    #[test]
    fn fresh_effects_at_rest_are_harmless_mid_clip() {
        // Default modes are In: after the edge the picture is untouched (Zoom holds its To value, so skip it).
        for k in [ClipEffect::MOVE_KIND, ClipEffect::POP_KIND, ClipEffect::FADE_KIND] {
            let t = at(&clip(vec![effect(k)]), Time::new(2, 1));
            assert!(t.position == Vec2::ZERO && near(t.scale.x, 1.0, 1e-9) && t.opacity == 1.0 && t.rotation == 0.0);
        }
    }

    #[test]
    fn no_keyframes_are_written() {
        for kind in ClipEffect::MOTION_KINDS {
            assert!(effect(kind).key_times().is_empty());
        }
    }

    #[test]
    fn stacked_with_motion_multiplies() {
        let mut c = clip(vec![effect(ClipEffect::ZOOM_KIND)]);
        c.animation.scale = AnimatedProperty::new(Vec2::new(1.2, 1.2));
        // Zoom In default 100 -> 110 over 0.5 s: after it, 120 % * 110 %.
        assert!(near(at(&c, Time::new(2, 1)).scale.x, 1.32, 1e-9));
        assert!(!c.animation.scale.is_animated());
    }

    #[test]
    fn move_direction_rotation_and_strength() {
        let mut e = effect(ClipEffect::MOVE_KIND);
        set(&mut e, ClipEffect::MOVE_SIDE_KEY, MoveSide::Angle as i64 as f64); // FB-T3: the Angle slider
        set(&mut e, ClipEffect::MOVE_DIRECTION_KEY, 90.0); // from the right
        set(&mut e, ClipEffect::MOVE_DISTANCE_KEY, 50.0);
        set(&mut e, ClipEffect::MOVE_ROTATION_KEY, 10.0); // Rotation defaults to Clockwise
        let c = clip(vec![e.clone()]);
        let start = at(&c, Time::ZERO);
        assert!(
            near(start.position.x, 0.5 * W, 1e-6)
                && near(start.position.y, 0.0, 1e-6)
                && near(start.rotation, 10.0, 1e-9)
        );
        // Diagonal: share of the frame along the direction.
        set(&mut e, ClipEffect::MOVE_DIRECTION_KEY, 0.0); // from the top
        assert!(near(at(&clip(vec![e]), Time::ZERO).position.y, -0.5 * H, 1e-6));
        let end = at(&c, Time::new(1, 1));
        assert!(end.position == Vec2::ZERO && end.rotation == 0.0);
    }

    #[test]
    fn out_mode_is_the_time_reverse_of_in() {
        let mut e = effect(ClipEffect::MOVE_KIND);
        set(&mut e, ClipEffect::MOVE_DIRECTION_KEY, 90.0);
        set(&mut e, ClipEffect::MOTION_DURATION_KEY, 1.0);
        let mut o = e.clone();
        set(&mut o, ClipEffect::MOTION_MODE_KEY, 1.0);
        let (cin, cout) = (clip(vec![e]), clip(vec![o]));
        for ts in [0, 100, 300, 500, 900] {
            assert!(near(at(&cin, ms(ts)).position.x, at(&cout, ms(4000 - ts)).position.x, 1e-6));
        }
    }

    #[test]
    fn loop_repeats_per_duration() {
        let mut e = effect(ClipEffect::ZOOM_KIND);
        set(&mut e, ClipEffect::MOTION_MODE_KEY, 3.0);
        set(&mut e, ClipEffect::MOTION_DURATION_KEY, 1.0);
        let c = clip(vec![e]);
        assert!(near(at(&c, ms(250)).scale.x, at(&c, ms(1250)).scale.x, 1e-9));
        assert!(near(at(&c, Time::ZERO).scale.x, 1.0, 1e-9));
        assert!(near(at(&c, ms(500)).scale.x, 1.1, 1e-9));
    }

    #[test]
    fn shake_is_deterministic_smooth_and_shakes_the_whole_clip() {
        let c = clip(vec![effect(ClipEffect::SHAKE_KIND)]);
        let (a, b) = (at(&c, ms(200)), at(&c, ms(200)));
        assert_eq!(a, b);
        // Start, middle and end of the 4 s clip all shake (Bug 37: it used to settle after its 0.5 s Duration).
        for t in [ms(200), ms(2000), ms(3800)] {
            assert_ne!(at(&c, t).position, Vec2::ZERO, "{t:?}");
        }
        assert!((at(&c, ms(200)).position.x - at(&c, ms(204)).position.x).abs() < 6.0); // continuous
    }

    #[test]
    fn shake_has_no_mode_curve_or_duration_and_ignores_stored_ones() {
        let spec = EffectCatalog::spec_for(ClipEffect::SHAKE_KIND).expect("shake");
        let keys: Vec<&str> = spec.params.iter().map(|p| p.key.as_str()).collect();
        assert_eq!(keys, ["strength", "rotation", "speed", "seed"]);
        // A project saved with the old In mode and a 1 s Duration still shakes the whole clip.
        let mut e = effect(ClipEffect::SHAKE_KIND);
        set(&mut e, ClipEffect::MOTION_MODE_KEY, 0.0);
        set(&mut e, ClipEffect::MOTION_DURATION_KEY, 1.0);
        assert_ne!(at(&clip(vec![e]), ms(2500)).position, Vec2::ZERO);
    }

    #[test]
    fn curve_changes_the_middle_not_the_ends() {
        let mut lin = effect(ClipEffect::ZOOM_KIND);
        set(&mut lin, ClipEffect::MOTION_CURVE_KEY, MotionCurve::Linear.raw_value() as f64);
        set(&mut lin, ClipEffect::MOTION_DURATION_KEY, 1.0);
        let mut eo = lin.clone();
        set(&mut eo, ClipEffect::MOTION_CURVE_KEY, MotionCurve::EaseOut100.raw_value() as f64);
        let (eo, lin) = (clip(vec![eo]), clip(vec![lin]));
        assert!(at(&eo, ms(300)).scale.x > at(&lin, ms(300)).scale.x);
        assert!(near(at(&eo, Time::ZERO).scale.x, 1.0, 1e-12) && near(at(&eo, ms(1000)).scale.x, 1.1, 1e-12));
    }

    #[test]
    fn position_is_a_share_of_the_canvas() {
        let mut e = effect(ClipEffect::MOVE_KIND);
        set(&mut e, ClipEffect::MOVE_DIRECTION_KEY, 270.0);
        let c = clip(vec![e]);
        assert!(near(c.render_transform(Time::ZERO, Vec2::new(1080.0, 1920.0)).position.x, -1080.0, 1e-6));
    }

    fn move_left() -> ClipEffect {
        let mut e = effect(ClipEffect::MOVE_KIND);
        set(&mut e, ClipEffect::MOVE_DIRECTION_KEY, 270.0);
        set(&mut e, ClipEffect::MOVE_DISTANCE_KEY, 100.0);
        e
    }

    fn canvas_centre(c: &Clip, t: Time) -> Vec2 {
        c.render_transform(t, Vec2::new(W, H)).map(Vec2::ZERO)
    }

    #[test]
    fn move_is_on_canvas_whatever_the_motion_scale_or_rotation() {
        for (scale, rot) in [(0.5, 0.0), (2.0, 0.0), (1.0, 90.0), (0.5, 33.0)] {
            let mut c = clip(vec![move_left()]);
            c.animation.scale = AnimatedProperty::new(Vec2::new(scale, scale));
            c.animation.rotation = AnimatedProperty::new(rot);
            let p = canvas_centre(&c, Time::ZERO);
            assert!(near(p.x, -W, 1e-6) && near(p.y, 0.0, 1e-6), "scale {scale} rot {rot}: {p:?}");
            assert!(near(canvas_centre(&c, Time::new(2, 1)).x, 0.0, 1e-6));
        }
    }

    #[test]
    fn later_stages_do_not_change_the_canvas_shift() {
        let mut zoom = effect(ClipEffect::ZOOM_KIND);
        set(&mut zoom, ClipEffect::ZOOM_FROM_KEY, 200.0);
        set(&mut zoom, ClipEffect::ZOOM_TO_KEY, 200.0);
        let mut c = clip(vec![move_left(), zoom]);
        c.animation.scale = AnimatedProperty::new(Vec2::new(0.5, 0.5));
        assert!(near(canvas_centre(&c, Time::ZERO).x, -W, 1e-6));
    }

    #[test]
    fn shake_amplitude_is_canvas_sized_at_any_scale() {
        let mut e = effect(ClipEffect::SHAKE_KIND);
        set(&mut e, ClipEffect::SHAKE_ROTATION_KEY, 0.0);
        let a = clip(vec![e.clone()]);
        let mut b = clip(vec![e]);
        b.animation.scale = AnimatedProperty::new(Vec2::new(0.5, 0.5));
        for ts in [100, 370, 900] {
            let (pa, pb) = (canvas_centre(&a, ms(ts)), canvas_centre(&b, ms(ts)));
            assert!(near(pa.x, pb.x, 1e-6) && near(pa.y, pb.y, 1e-6));
        }
    }

    #[test]
    fn pop_in_out_normalises_by_settle() {
        let mut e = effect(ClipEffect::POP_KIND);
        set(&mut e, ClipEffect::MOTION_MODE_KEY, 2.0);
        set(&mut e, ClipEffect::POP_SETTLE_KEY, 120.0);
        assert!(near(at(&clip(vec![e.clone()]), Time::new(2, 1)).scale.x, 1.2, 1e-9));
        set(&mut e, ClipEffect::MOTION_MODE_KEY, 1.0);
        assert!(near(at(&clip(vec![e]), Time::new(2, 1)).scale.x, 1.0, 1e-9));
    }

    #[test]
    fn nil_clip_length_means_no_end_edge() {
        let frame = Vec2::new(W, H);
        let mut pop = effect(ClipEffect::POP_KIND);
        set(&mut pop, ClipEffect::POP_SETTLE_KEY, 120.0);
        set(&mut pop, ClipEffect::MOTION_MODE_KEY, 1.0);
        assert!(near(pop.stage_transform(Time::new(2, 1), None, frame).scale, 1.0, 1e-9));
        set(&mut pop, ClipEffect::MOTION_MODE_KEY, 2.0);
        assert!(near(pop.stage_transform(Time::new(2, 1), None, frame).scale, 1.2, 1e-9));
        let mut mv = move_left();
        set(&mut mv, ClipEffect::MOTION_MODE_KEY, 1.0);
        set(&mut mv, ClipEffect::MOVE_FADE_KEY, 1.0);
        let s = mv.stage_transform(Time::new(2, 1), None, frame);
        assert!(s.opacity == 1.0 && s.position == Vec2::ZERO);
    }

    fn loop_clip(kind: &str, values: &[(&str, f64)]) -> Clip {
        let mut e = effect(kind);
        for (k, x) in values {
            set(&mut e, k, *x);
        }
        let mut c = clip(vec![e]);
        c.source = TimeRange::new(Time::ZERO, Time::new(10, 1));
        c
    }

    #[test]
    fn loop_animators_are_stages_without_keys() {
        for k in [ClipEffect::BOUNCE_KIND, ClipEffect::PULSE_KIND, ClipEffect::WIGGLE_KIND] {
            assert!(EffectCatalog::all().iter().any(|s| s.kind == k));
            let e = effect(k);
            assert!(e.is_transform_stage() && e.is_motion_preset() && e.key_times().is_empty());
        }
    }

    #[test]
    fn period_is_exact_and_deterministic() {
        for k in [ClipEffect::BOUNCE_KIND, ClipEffect::PULSE_KIND, ClipEffect::WIGGLE_KIND] {
            let c = loop_clip(
                k,
                &[
                    (ClipEffect::LOOP_PERIOD_KEY, 0.8),
                    (ClipEffect::WIGGLE_SHIFT_KEY, 3.0),
                    (ClipEffect::BOUNCE_SQUASH_KEY, 20.0),
                    (ClipEffect::PULSE_FADE_KEY, 30.0),
                ],
            );
            for t in [130, 400, 710, 1900] {
                let (a, b) = (at(&c, ms(t)), at(&c, ms(t + 800 * 3)));
                assert!(near(a.position.x, b.position.x, 1e-6) && near(a.position.y, b.position.y, 1e-6));
                assert!(near(a.scale.x, b.scale.x, 1e-9) && near(a.rotation, b.rotation, 1e-6));
                assert!(near(a.opacity, b.opacity, 1e-9));
                assert_eq!(at(&c, ms(t)), a);
            }
        }
    }

    #[test]
    fn bounce_hops_up_and_lands_every_period() {
        let c = loop_clip(
            ClipEffect::BOUNCE_KIND,
            &[(ClipEffect::LOOP_PERIOD_KEY, 1.0), (ClipEffect::BOUNCE_HEIGHT_KEY, 10.0)],
        );
        let y = |t| at(&c, ms(t)).map(Vec2::ZERO);
        assert!(near(y(0).y, 0.0, 1e-6) && near(y(1000).y, 0.0, 1e-6));
        assert!(near(y(500).y, -0.1 * H, 1e-6) && near(y(500).x, 0.0, 1e-6));
        let side = loop_clip(
            ClipEffect::BOUNCE_KIND,
            &[
                (ClipEffect::LOOP_PERIOD_KEY, 1.0),
                (ClipEffect::BOUNCE_HEIGHT_KEY, 10.0),
                (ClipEffect::BOUNCE_DIRECTION_KEY, 90.0),
            ],
        );
        assert!(near(at(&side, ms(500)).map(Vec2::ZERO).x, 0.1 * W, 1e-6));
    }

    #[test]
    fn pulse_breathes_between_from_and_to() {
        let c = loop_clip(
            ClipEffect::PULSE_KIND,
            &[
                (ClipEffect::LOOP_PERIOD_KEY, 2.0),
                (ClipEffect::PULSE_FROM_KEY, 100.0),
                (ClipEffect::PULSE_TO_KEY, 120.0),
            ],
        );
        assert!(near(at(&c, ms(0)).scale.x, 1.0, 1e-9));
        assert!(near(at(&c, ms(1000)).scale.x, 1.2, 1e-9));
        assert!(near(at(&c, ms(500)).scale.x, 1.1, 1e-9));
        assert!(near(at(&c, ms(2000)).scale.x, 1.0, 1e-9));
    }

    #[test]
    fn wiggle_swings_both_ways_and_phase_shifts_the_loop() {
        let c = loop_clip(
            ClipEffect::WIGGLE_KIND,
            &[(ClipEffect::LOOP_PERIOD_KEY, 1.0), (ClipEffect::WIGGLE_ANGLE_KEY, 10.0)],
        );
        assert!(near(at(&c, ms(250)).rotation, 10.0, 1e-6));
        assert!(near(at(&c, ms(750)).rotation, -10.0, 1e-6));
        assert!(near(at(&c, ms(0)).rotation, 0.0, 1e-6));
        let p = loop_clip(
            ClipEffect::WIGGLE_KIND,
            &[
                (ClipEffect::LOOP_PERIOD_KEY, 1.0),
                (ClipEffect::WIGGLE_ANGLE_KEY, 10.0),
                (ClipEffect::LOOP_PHASE_KEY, 25.0),
            ],
        );
        assert!(near(at(&p, ms(0)).rotation, 10.0, 1e-6));
    }
}
