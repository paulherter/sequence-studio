// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MotionEasing.swift
//! FB-T3 easing library of the motion effects (the Curve pop-up of Move, Zoom, Pop, Fade, Shake and the element
//! transitions). Stored as the case's raw value in the effect's "curve" parameter; the order is the menu order:
//! Premiere's interpolations first (what a Premiere user looks for), then the short-form families (easings.net names:
//! In = accelerates, Out = decelerates), then Custom (a cubic bezier kept in the effect, edited with the curve editor).
//!
//! Premiere mapping for one edge animation (a two-key segment):
//! - Bezier: Premiere's default bezier (16.7 % influence, flat tangents).
//! - Continuous Bezier: 33 % influence on both keys (Premiere's handles when the segment is smoothed through).
//! - Auto Bezier: straight speed: with only two keys Premiere's auto tangents point at each other.
//! - Linear, Hold: as in Premiere (Hold jumps at the end of the segment).
//! - Ease In / Ease Out: Premiere's keyframe assistants: Ease In slows into the key (fast start, soft landing), Ease
//!   Out slows out of the key (soft start). 100 % variants = full influence.

use crate::{AnimatedProperty, ClipEffect, EaseShape};
use sq_core_time::ease_names::ease_name;
use sq_core_time::keyframes_model::keyframe_math;
use sq_core_time::{EaseHandle, EasingCurve, Interpolation, SpringEasing};

/// A CSS-style cubic bezier `cubic-bezier(x1, y1, x2, y2)` from (0,0) to (1,1). X is clamped to 0...1, Y is free
/// (outside 0...1 the curve overshoots).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CubicBezierEase {
    /// First control point x.
    pub x1: f64,
    /// First control point y.
    pub y1: f64,
    /// Second control point x.
    pub x2: f64,
    /// Second control point y.
    pub y2: f64,
}

impl CubicBezierEase {
    /// Default of a fresh Custom curve: Premiere's Continuous Bezier.
    pub const DEFAULT: CubicBezierEase = CubicBezierEase { x1: 1.0 / 3.0, y1: 0.0, x2: 2.0 / 3.0, y2: 1.0 };

    /// The curve editor's shape (handles relative to their key: out from the start, in back from the end).
    pub fn from_shape(shape: &EaseShape) -> CubicBezierEase {
        if shape.interpolation() == Interpolation::Linear {
            CubicBezierEase { x1: 1.0 / 3.0, y1: 1.0 / 3.0, x2: 2.0 / 3.0, y2: 2.0 / 3.0 }
        } else {
            CubicBezierEase { x1: shape.out.dx, y1: shape.out.dy, x2: 1.0 - shape.r#in.dx, y2: 1.0 - shape.r#in.dy }
        }
    }

    /// The curve editor's shape of this curve.
    pub fn shape(&self) -> EaseShape {
        EaseShape::new(
            Interpolation::Bezier,
            EaseHandle { dx: self.x1, dy: self.y1 },
            EaseHandle { dx: 1.0 - self.x2, dy: 1.0 - self.y2 },
        )
    }

    /// Eased progress for `x` (0 below 0, 1 from 1 on).
    pub fn progress(&self, x: f64) -> f64 {
        if x <= 0.0 {
            return 0.0;
        }
        if x >= 1.0 {
            return 1.0;
        }
        keyframe_math::bezier_progress(
            x,
            EaseHandle { dx: self.x1, dy: self.y1 },
            EaseHandle { dx: 1.0 - self.x2, dy: 1.0 - self.y2 },
        )
    }
}

/// The curve of a motion effect (the Curve pop-up). The discriminant is the stored value.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MotionCurve {
    /// Premiere: the default bezier.
    PremiereDefault,
    /// Premiere: 33 % influence on both keys (older name: Ease In Out).
    ContinuousBezier,
    /// Premiere: straight speed.
    AutoBezier,
    /// Premiere: linear.
    Linear,
    /// Premiere: hold.
    Hold,
    /// Slow arrival (Premiere's Ease In).
    EaseIn,
    /// Slow start (Premiere's Ease Out).
    EaseOut,
    /// Slow start, 100 % influence.
    EaseOut100,
    /// Slow arrival, 100 % influence.
    EaseIn100,
    /// Fast start, soft landing.
    FastStart,
    /// Live spring.
    Spring,
    /// Sine, accelerating.
    SineIn,
    /// Sine, decelerating.
    SineOut,
    /// Sine, both.
    SineInOut,
    /// Quadratic, accelerating.
    QuadIn,
    /// Quadratic, decelerating.
    QuadOut,
    /// Quadratic, both.
    QuadInOut,
    /// Cubic, accelerating.
    CubicIn,
    /// Cubic, decelerating.
    CubicOut,
    /// Cubic, both.
    CubicInOut,
    /// Quartic, accelerating.
    QuartIn,
    /// Quartic, decelerating.
    QuartOut,
    /// Quartic, both.
    QuartInOut,
    /// Quintic, accelerating.
    QuintIn,
    /// Quintic, decelerating.
    QuintOut,
    /// Quintic, both.
    QuintInOut,
    /// Exponential, accelerating.
    ExpoIn,
    /// Exponential, decelerating.
    ExpoOut,
    /// Exponential, both.
    ExpoInOut,
    /// Circular, accelerating.
    CircIn,
    /// Circular, decelerating.
    CircOut,
    /// Circular, both.
    CircInOut,
    /// Back, accelerating (Wind-Up).
    BackIn,
    /// Back, decelerating (Overshoot).
    BackOut,
    /// Back, both.
    BackInOut,
    /// Elastic, accelerating.
    ElasticIn,
    /// Elastic, decelerating.
    ElasticOut,
    /// Elastic, both.
    ElasticInOut,
    /// Bounce, accelerating.
    BounceIn,
    /// Bounce, decelerating.
    BounceOut,
    /// Bounce, both.
    BounceInOut,
    /// The effect's own cubic bezier.
    Custom,
}

impl MotionCurve {
    /// Every curve in menu order (Swift `allCases`).
    pub const ALL: [MotionCurve; 42] = {
        use MotionCurve::*;
        [
            PremiereDefault,
            ContinuousBezier,
            AutoBezier,
            Linear,
            Hold,
            EaseIn,
            EaseOut,
            EaseOut100,
            EaseIn100,
            FastStart,
            Spring,
            SineIn,
            SineOut,
            SineInOut,
            QuadIn,
            QuadOut,
            QuadInOut,
            CubicIn,
            CubicOut,
            CubicInOut,
            QuartIn,
            QuartOut,
            QuartInOut,
            QuintIn,
            QuintOut,
            QuintInOut,
            ExpoIn,
            ExpoOut,
            ExpoInOut,
            CircIn,
            CircOut,
            CircInOut,
            BackIn,
            BackOut,
            BackInOut,
            ElasticIn,
            ElasticOut,
            ElasticInOut,
            BounceIn,
            BounceOut,
            BounceInOut,
            Custom,
        ]
    };

    /// Older name of Continuous Bezier (33 % in and out).
    pub const EASE_IN_OUT: MotionCurve = MotionCurve::ContinuousBezier;

    /// The stored value.
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    /// The curve a stored value stands for.
    pub fn from_raw(raw: i64) -> Option<MotionCurve> {
        usize::try_from(raw).ok().and_then(|i| Self::ALL.get(i).copied())
    }

    /// Menu title.
    pub fn title(self) -> String {
        match self {
            MotionCurve::PremiereDefault => ease_name::GENTLE.to_string(),
            MotionCurve::ContinuousBezier => ease_name::SMOOTH.to_string(),
            MotionCurve::AutoBezier => "Auto".to_string(),
            MotionCurve::Linear => ease_name::STEADY.to_string(),
            MotionCurve::Hold => ease_name::HOLD.to_string(),
            MotionCurve::EaseIn => ease_name::SMOOTH_IN.to_string(),
            MotionCurve::EaseOut => ease_name::SMOOTH_OUT.to_string(),
            MotionCurve::EaseIn100 => ease_name::SMOOTH_OUT_100.to_string(),
            MotionCurve::EaseOut100 => ease_name::SMOOTH_IN_100.to_string(),
            MotionCurve::FastStart => ease_name::FAST_START.to_string(),
            MotionCurve::Spring => "Spring".to_string(),
            MotionCurve::BackIn => "Wind-Up".to_string(),
            MotionCurve::BackOut => "Overshoot".to_string(),
            MotionCurve::BackInOut => "Wind-Up Overshoot".to_string(),
            MotionCurve::ElasticInOut => "Spring In Out".to_string(),
            MotionCurve::Custom => ease_name::CUSTOM.to_string(),
            _ => self.family_title(),
        }
    }

    /// Own words for the strength families (DECISIONS 2026-10-06), in the order of `family`'s shape index.
    const FAMILY_WORDS: [&'static str; 10] =
        ["Soft", "Light", "Firm", "Strong", "Heavy", "Sharp", "Round", "", "Spring", "Bounce"];

    /// "<Word> Out" is the family's accelerating form (slow leaving the start), "<Word> In" the decelerating one (slow
    /// arriving), the bare word both: the sense of `SMOOTH_IN` / `SMOOTH_OUT`, swapped against the CSS names. Spring and
    /// Bounce follow the same rule: "Out" wobbles or bounces at the start, "In" at the end. Back (Wind-Up, Overshoot)
    /// and the two-sided spring ("Spring In Out", bare "Spring" is the live spring) are named in `title`.
    fn family_title(self) -> String {
        let Some((shape, kind)) = self.family() else { return ease_name::CUSTOM.to_string() };
        let word = Self::FAMILY_WORDS[shape];
        match kind {
            0 => format!("{word} Out"),
            1 => format!("{word} In"),
            _ => word.to_string(),
        }
    }

    /// The titles of every curve, in menu order.
    pub fn titles() -> Vec<String> {
        Self::ALL.iter().map(|c| c.title()).collect()
    }

    /// Eased progress for `x` (clamped to 0...1; exactly 0 at 0 and 1 at 1; back, elastic, spring and a custom curve
    /// with Y outside 0...1 overshoot in between). `custom` is the effect's own curve (Custom only; default when
    /// `None`).
    pub fn ease(self, x: f64, custom: Option<CubicBezierEase>) -> f64 {
        if x <= 0.0 {
            return 0.0;
        }
        if x >= 1.0 {
            return 1.0;
        }
        let bez = |c: EasingCurve| keyframe_math::bezier_progress(x, c.out_handle, c.in_handle);
        match self {
            MotionCurve::PremiereDefault => return bez(EasingCurve::premiere_default()),
            MotionCurve::ContinuousBezier => return bez(EasingCurve::ease_in_out()),
            MotionCurve::AutoBezier | MotionCurve::Linear => return x,
            MotionCurve::Hold => return 0.0,
            // EasingCurve's names are CSS-style (its ease_in = slow arrival = Premiere's Ease In).
            MotionCurve::EaseIn => return bez(EasingCurve::ease_in()),
            MotionCurve::EaseOut => return bez(EasingCurve::ease_out()),
            MotionCurve::EaseIn100 => return bez(EasingCurve::ease_in_100()),
            MotionCurve::EaseOut100 => return bez(EasingCurve::ease_out_100()),
            MotionCurve::FastStart => return bez(EasingCurve::fast_start()),
            MotionCurve::Spring => return SpringEasing::new(0.4).progress(x),
            MotionCurve::Custom => return custom.unwrap_or(CubicBezierEase::DEFAULT).progress(x),
            _ => {}
        }
        let Some((shape, kind)) = self.family() else { return x };
        let f = |u: f64| Self::ease_in_shape(shape, u);
        match kind {
            0 => f(x),
            1 => 1.0 - f(1.0 - x),
            _ => {
                if x < 0.5 {
                    f(2.0 * x) / 2.0
                } else {
                    1.0 - f(2.0 - 2.0 * x) / 2.0
                }
            }
        }
    }

    /// The accelerating ("In") shape of a family and which variant this case is (0 In, 1 Out, 2 In-Out).
    fn family(self) -> Option<(usize, usize)> {
        let first = MotionCurve::SineIn as usize;
        let last = MotionCurve::BounceInOut as usize;
        let raw = self as usize;
        if raw < first || raw > last {
            return None;
        }
        let i = raw - first;
        Some((i / 3, i % 3))
    }

    /// The In form of family `shape` (0 sine, 1 quad, 2 cubic, 3 quart, 4 quint, 5 expo, 6 circ, 7 back, 8 elastic,
    /// 9 bounce): f(0) = 0, f(1) = 1 exactly (expo and elastic are normalized so nothing jumps at the ends).
    fn ease_in_shape(shape: usize, x: f64) -> f64 {
        use std::f64::consts::PI;
        match shape {
            0 => 1.0 - (x * PI / 2.0).cos(),
            1..=4 => x.powf((shape + 1) as f64),
            5 => (2.0_f64.powf(10.0 * x) - 1.0) / (2.0_f64.powf(10.0) - 1.0),
            6 => 1.0 - (1.0 - x * x).max(0.0).sqrt(),
            7 => {
                let c1 = 1.70158;
                let c3 = c1 + 1.0;
                c3 * x * x * x - c1 * x * x
            }
            8 => {
                // Elastic Out of easings.net mirrored; divided by its value at 1 so it lands exactly.
                let out = |u: f64| 2.0_f64.powf(-10.0 * u) * ((10.0 * u - 0.75) * 2.0 * PI / 3.0).sin() + 1.0;
                1.0 - out(1.0 - x) / out(1.0)
            }
            _ => 1.0 - Self::bounce_out(1.0 - x),
        }
    }

    /// Robert Penner's bounce (4 floor contacts, the first at 1/2.75).
    fn bounce_out(x: f64) -> f64 {
        let n1 = 7.5625;
        let d1 = 2.75;
        if x < 1.0 / d1 {
            return n1 * x * x;
        }
        if x < 2.0 / d1 {
            let u = x - 1.5 / d1;
            return n1 * u * u + 0.75;
        }
        if x < 2.5 / d1 {
            let u = x - 2.25 / d1;
            return n1 * u * u + 0.9375;
        }
        let u = x - 2.625 / d1;
        n1 * u * u + 0.984375
    }
}

impl ClipEffect {
    /// The Custom curve of a motion effect: `cubic-bezier(x1, y1, x2, y2)`. Not in the specs (no rows of their own,
    /// never keyed); edited with the curve editor from the Curve row.
    pub const CURVE_X1_KEY: &'static str = "curveX1";
    /// See `CURVE_X1_KEY`.
    pub const CURVE_Y1_KEY: &'static str = "curveY1";
    /// See `CURVE_X1_KEY`.
    pub const CURVE_X2_KEY: &'static str = "curveX2";
    /// See `CURVE_X1_KEY`.
    pub const CURVE_Y2_KEY: &'static str = "curveY2";
    const CUSTOM_CURVE_KEYS: [&'static str; 4] =
        [Self::CURVE_X1_KEY, Self::CURVE_Y1_KEY, Self::CURVE_X2_KEY, Self::CURVE_Y2_KEY];

    /// The stored Custom curve; `None` when none was edited (the Custom choice then uses `CubicBezierEase::DEFAULT`).
    pub fn custom_curve(&self) -> Option<CubicBezierEase> {
        let v = |key: &str| self.parameters.get(key).map(|p| p.value);
        let (x1, y1, x2, y2) =
            (v(Self::CURVE_X1_KEY)?, v(Self::CURVE_Y1_KEY)?, v(Self::CURVE_X2_KEY)?, v(Self::CURVE_Y2_KEY)?);
        if ![x1, y1, x2, y2].iter().all(|n| n.is_finite()) {
            return None;
        }
        Some(CubicBezierEase { x1: x1.clamp(0.0, 1.0), y1, x2: x2.clamp(0.0, 1.0), y2 })
    }

    /// Stores `c` as the Custom curve (static values, X clamped to 0...1, Y to -2...3).
    pub fn set_custom_curve(&mut self, c: CubicBezierEase) {
        let v = [c.x1.clamp(0.0, 1.0), c.y1.clamp(-2.0, 3.0), c.x2.clamp(0.0, 1.0), c.y2.clamp(-2.0, 3.0)];
        for (k, x) in Self::CUSTOM_CURVE_KEYS.iter().zip(v) {
            self.parameters.insert((*k).to_string(), AnimatedProperty::new(x));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Id;

    fn near(a: f64, b: f64, tol: f64) -> bool {
        (a - b).abs() <= tol
    }

    #[test]
    fn every_curve_starts_at_zero_and_ends_at_one() {
        for c in MotionCurve::ALL {
            assert!(c.ease(0.0, None) == 0.0 && c.ease(1.0, None) == 1.0, "{c:?}");
            assert!(c.ease(-0.5, None) == 0.0 && c.ease(1.5, None) == 1.0, "{c:?} clamps");
        }
    }

    #[test]
    fn titles_match_cases_and_premiere_comes_first() {
        let titles = MotionCurve::titles();
        assert_eq!(titles.len(), MotionCurve::ALL.len());
        assert_eq!(titles[..5], ["Gentle", "Ease In & Out", "Auto", "Linear", "Hold"]);
        assert_eq!(titles.last().map(String::as_str), Some("Custom"));
        for c in MotionCurve::ALL {
            assert_eq!(titles[c.raw_value() as usize], c.title());
            assert_eq!(MotionCurve::from_raw(c.raw_value()), Some(c));
        }
        let unique: std::collections::BTreeSet<_> = titles.iter().collect();
        assert_eq!(unique.len(), titles.len(), "no duplicate names");
        assert_eq!(MotionCurve::from_raw(-1), None);
        assert_eq!(MotionCurve::from_raw(42), None);
    }

    #[test]
    fn curves_stay_continuous_near_the_ends() {
        // Circ has a vertical tangent at one end (sqrt), so a millionth in time is ~0.0014 in value.
        for c in MotionCurve::ALL.into_iter().filter(|c| *c != MotionCurve::Hold) {
            assert!(c.ease(1e-6, None).abs() < 2e-3, "{c:?} start");
            assert!((c.ease(1.0 - 1e-6, None) - 1.0).abs() < 2e-3, "{c:?} end");
        }
    }

    #[test]
    fn premiere_interpolations() {
        assert_eq!(MotionCurve::Linear.ease(0.3, None), 0.3);
        assert_eq!(MotionCurve::AutoBezier.ease(0.3, None), 0.3);
        assert!(MotionCurve::Hold.ease(0.999, None) == 0.0 && MotionCurve::Hold.ease(1.0, None) == 1.0);
        assert!(near(MotionCurve::ContinuousBezier.ease(0.5, None), 0.5, 1e-9));
        assert!(
            MotionCurve::ContinuousBezier.ease(0.2, None) < 0.2 && MotionCurve::ContinuousBezier.ease(0.8, None) > 0.8
        );
        // Premiere's Ease In slows into the key (fast start), Ease Out slows out of it (slow start).
        assert!(MotionCurve::EaseIn.ease(0.25, None) > 0.25 && MotionCurve::EaseOut.ease(0.25, None) < 0.25);
    }

    #[test]
    fn families_have_their_shape() {
        use MotionCurve::*;
        let families = [
            (SineIn, SineOut, SineInOut),
            (QuadIn, QuadOut, QuadInOut),
            (CubicIn, CubicOut, CubicInOut),
            (QuartIn, QuartOut, QuartInOut),
            (QuintIn, QuintOut, QuintInOut),
            (ExpoIn, ExpoOut, ExpoInOut),
            (CircIn, CircOut, CircInOut),
        ];
        for (i, o, io) in families {
            assert!(i.ease(0.3, None) < 0.3 && o.ease(0.3, None) > 0.3, "{i:?} / {o:?}");
            assert!(near(io.ease(0.5, None), 0.5, 1e-9), "{io:?} middle");
            assert!(near(io.ease(0.2, None) + io.ease(0.8, None), 1.0, 1e-9), "{io:?} symmetric");
            for n in 0..=20 {
                let x = f64::from(n) * 0.05;
                assert!(near(o.ease(x, None), 1.0 - i.ease(1.0 - x, None), 1e-9), "{o:?} mirrors {i:?}");
            }
        }
        assert!(near(CubicIn.ease(0.5, None), 0.125, 1e-9));
        assert!(near(QuadOut.ease(0.5, None), 0.75, 1e-9));
    }

    #[test]
    fn back_overshoots_elastic_rings_bounce_stays_inside() {
        let sweep =
            |c: MotionCurve, n: i32| (1..n).map(|i| c.ease(f64::from(i) / f64::from(n), None)).collect::<Vec<_>>();
        let max = |v: &[f64]| v.iter().copied().fold(f64::MIN, f64::max);
        let min = |v: &[f64]| v.iter().copied().fold(f64::MAX, f64::min);
        assert!(max(&sweep(MotionCurve::BackOut, 100)) > 1.05, "Back Out overshoots past the end");
        assert!(min(&sweep(MotionCurve::BackIn, 100)) < -0.05, "Back In pulls back first");
        let el = sweep(MotionCurve::ElasticOut, 200);
        assert!(max(&el) > 1.1 && el.iter().any(|v| *v < 1.0), "Spring Out rings around the end");
        let bo: Vec<f64> = (0..=200).map(|i| MotionCurve::BounceOut.ease(f64::from(i) / 200.0, None)).collect();
        assert!(bo.iter().all(|v| (-1e-12..=1.0 + 1e-12).contains(v)), "Bounce never leaves 0...1");
        assert!(near(MotionCurve::BounceOut.ease(1.0 / 2.75, None), 1.0, 1e-9), "first floor contact");
        assert!(MotionCurve::Spring.ease(0.5, None) > 0.9);
    }

    #[test]
    fn custom_cubic_bezier_is_css_cubic_bezier() {
        // cubic-bezier(0.25, 0.1, 0.25, 1) = CSS "ease": 0.5 -> ~0.8024.
        let css = CubicBezierEase { x1: 0.25, y1: 0.1, x2: 0.25, y2: 1.0 };
        assert!(near(MotionCurve::Custom.ease(0.5, Some(css)), 0.8024, 2e-3));
        // The straight line is linear.
        let line = CubicBezierEase { x1: 1.0 / 3.0, y1: 1.0 / 3.0, x2: 2.0 / 3.0, y2: 2.0 / 3.0 };
        assert!(near(MotionCurve::Custom.ease(0.37, Some(line)), 0.37, 1e-6));
        // Y outside 0...1 overshoots (a hand-made back curve).
        let over = CubicBezierEase { x1: 0.3, y1: 1.6, x2: 0.6, y2: 1.0 };
        assert!((1..100).any(|i| MotionCurve::Custom.ease(f64::from(i) / 100.0, Some(over)) > 1.0));
        // Round trip with the curve editor's shape.
        assert_eq!(CubicBezierEase::from_shape(&css.shape()), css);
    }

    #[test]
    fn custom_curve_is_read_from_the_effect() {
        let mut e = ClipEffect::new(Id::from_u128(1), "zoom");
        assert_eq!(e.custom_curve(), None);
        let c = CubicBezierEase { x1: 0.0, y1: 1.0, x2: 0.0, y2: 1.0 };
        e.set_custom_curve(c);
        assert_eq!(e.custom_curve(), Some(c));
        e.set_custom_curve(CubicBezierEase { x1: 2.0, y1: 9.0, x2: -1.0, y2: -9.0 });
        assert_eq!(e.custom_curve(), Some(CubicBezierEase { x1: 1.0, y1: 3.0, x2: 0.0, y2: -2.0 }));
        e.parameters.insert("curveX1".into(), AnimatedProperty::new(f64::NAN));
        assert_eq!(e.custom_curve(), None);
    }
}
