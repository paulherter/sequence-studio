// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: KeyframesSpeedHill.swift (ported by task M-3)

use crate::keyframes_ease_selection::{EaseSelection, EaseShape};
use crate::keyframes_editing::{KeyframeSummary, PropertyTrack};
use sq_core_time::{EaseHandle, EaseSide, Id, Interpolation, KeyframeTrack, KeyframeValue, Time};
use std::ops::RangeInclusive;

/// The speed graph of one eased segment (Controls > opened keyframe row). Everything is normalized to the segment:
/// time runs 0...1 from the left key to the right key, speed is a multiple of the segment's steady speed
/// (1.0 = a straight segment, 0 = standing still). The hill is dy/dx of the value bezier
/// (0,0) (out.dx, out.dy) (1 - in.dx, 1 - in.dy) (1,1), i.e. exactly what `KeyframeTrack::segment_value` plays.
/// Reach is a handle's `dx` (share of the segment's time), the speed at a key is the handle's slope `dy / dx`.
pub struct SpeedHill;

/// One point of a speed hill.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SpeedHillSample {
    /// Share of the segment's time, 0...1.
    pub x: f64,
    /// Multiple of the steady speed.
    pub speed: f64,
}

impl SpeedHill {
    /// Shortest reach an edit can give a handle: 0.1 %, the lower end of Premiere's influence range (0.1...100 %,
    /// docs/research/SPEED-GRAPH-INFLUENCE.md). A reach of 0 would collapse the handle onto its key.
    pub const MIN_REACH: f64 = 0.001;

    /// `count` points (min 2) from the left key to the right key, evenly spread along the bezier parameter.
    pub fn samples(shape: &EaseShape, count: usize) -> Vec<SpeedHillSample> {
        let n = count.max(2);
        let s = shape.effective();
        if s.interpolation().is_hold() {
            return (0..n).map(|i| SpeedHillSample { x: i as f64 / (n - 1) as f64, speed: 0.0 }).collect();
        }
        let (x1, y1, x2, y2) = (s.out.dx, s.out.dy, 1.0 - s.r#in.dx, 1.0 - s.r#in.dy);
        (0..n)
            .map(|i| {
                let t = i as f64 / (n - 1) as f64;
                let u = 1.0 - t;
                let x = 3.0 * u * u * t * x1 + 3.0 * u * t * t * x2 + t * t * t;
                let dx = 3.0 * u * u * x1 + 6.0 * u * t * (x2 - x1) + 3.0 * t * t * (1.0 - x2);
                let dy = 3.0 * u * u * y1 + 6.0 * u * t * (y2 - y1) + 3.0 * t * t * (1.0 - y2);
                // A handle of reach 0 has no slope of its own at the key: use the key's speed there.
                let speed = if dx.abs() > 1e-9 {
                    dy / dx
                } else if i == 0 {
                    s.speed_out()
                } else if i == n - 1 {
                    s.speed_in()
                } else {
                    0.0
                };
                SpeedHillSample {
                    x: if i == 0 {
                        0.0
                    } else if i == n - 1 {
                        1.0
                    } else {
                        x
                    },
                    speed,
                }
            })
            .collect()
    }

    /// Samples at the default count of 49.
    pub fn default_samples(shape: &EaseShape) -> Vec<SpeedHillSample> {
        Self::samples(shape, 49)
    }

    /// Highest speed on the segment.
    pub fn peak(shape: &EaseShape) -> f64 {
        Self::samples(shape, 97).iter().map(|s| s.speed).reduce(f64::max).unwrap_or(0.0)
    }

    /// Area under the samples (trapezoids): the share of the value delta covered, 1 for any shape that is not Hold.
    pub fn area(samples: &[SpeedHillSample]) -> f64 {
        samples.windows(2).fold(0.0, |acc, w| acc + (w[1].x - w[0].x) * (w[0].speed + w[1].speed) / 2.0)
    }
}

fn slope(h: EaseHandle) -> f64 {
    if h.dx > 1e-9 { h.dy / h.dx } else { 0.0 }
}

impl EaseShape {
    /// Speed leaving the left key, as a multiple of the steady speed (Smooth = 0, Steady = 1, Hold = 0).
    pub fn speed_out(&self) -> f64 {
        let s = self.effective();
        if s.interpolation().is_hold() { 0.0 } else { slope(s.out) }
    }

    /// Speed arriving at the right key.
    pub fn speed_in(&self) -> f64 {
        let s = self.effective();
        if s.interpolation().is_hold() { 0.0 } else { slope(s.r#in) }
    }

    /// Length of the left key's handle as a share of the segment (0...1).
    pub fn reach_out(&self) -> f64 {
        self.effective().out.dx
    }

    /// Length of the right key's handle.
    pub fn reach_in(&self) -> f64 {
        self.effective().r#in.dx
    }

    /// The shape with the handle(s) of `side` made `reach` long. The key's speed stays what it was, so only the
    /// handle's length changes. Each side is clamped to `MIN_REACH...1` on its own (Premiere: influence 0...100 %
    /// per handle, independent of the other one; a cubic with both x controls in 0...1 stays a function of time).
    /// Hold has no handles and comes back unchanged.
    pub fn setting_reach(&self, reach: f64, side: EaseSide) -> EaseShape {
        let s = self.effective();
        if s.interpolation().is_hold() {
            return *self;
        }
        let (mut out, mut in_h) = (s.out, s.r#in);
        let make = |r: f64, speed: f64| {
            let dx = if r.is_finite() {
                r.clamp(SpeedHill::MIN_REACH, 1.0)
            } else if r > 0.0 {
                1.0
            } else {
                SpeedHill::MIN_REACH
            };
            EaseHandle { dx, dy: speed * dx }
        };
        match side {
            EaseSide::Out => out = make(reach, s.speed_out()),
            EaseSide::In => in_h = make(reach, s.speed_in()),
            EaseSide::Both => {
                out = make(reach, s.speed_out());
                in_h = make(reach, s.speed_in());
            }
        }
        EaseShape::new(Interpolation::Bezier, out, in_h)
    }

    /// The shape with the key speed of `side` set (multiple of the steady speed); the reach stays what it was.
    /// A negative speed makes the value run backwards at that key: at the left key a wind-up, at the right key an
    /// overshoot that settles. `value_range` keeps the handle's value part (`dy`) inside what the edited thing can
    /// store.
    pub fn setting_speed(&self, speed: f64, side: EaseSide, value_range: Option<&RangeInclusive<f64>>) -> EaseShape {
        let s = self.effective();
        if s.interpolation().is_hold() {
            return *self;
        }
        let (mut out, mut in_h) = (s.out, s.r#in);
        let make = |h: EaseHandle| {
            let mut dy = if speed.is_finite() { speed * h.dx } else { 0.0 };
            if let Some(r) = value_range {
                dy = dy.max(*r.start()).min(*r.end());
            }
            EaseHandle { dx: h.dx, dy }
        };
        if side != EaseSide::In {
            out = make(out);
        }
        if side != EaseSide::Out {
            in_h = make(in_h);
        }
        EaseShape::new(Interpolation::Bezier, out, in_h)
    }

    /// How far the value leaves the span between its two keys, as shares of the value change: `below` the start
    /// value (wind-up), `above` the end value (overshoot). Both 0 for a curve that stays between its keys.
    pub fn value_excursion(&self) -> (f64, f64) {
        let s = self.effective();
        if s.interpolation().is_hold() {
            return (0.0, 0.0);
        }
        let (y1, y2) = (s.out.dy, 1.0 - s.r#in.dy);
        let (mut lo, mut hi) = (0.0_f64, 1.0_f64);
        for i in 1..128 {
            let t = i as f64 / 128.0;
            let u = 1.0 - t;
            let y = 3.0 * u * u * t * y1 + 3.0 * u * t * t * y2 + t * t * t;
            lo = lo.min(y);
            hi = hi.max(y);
        }
        ((-lo).max(0.0), (hi - 1.0).max(0.0))
    }
}

/// One segment of a track with its times and effective shape (what the speed graph draws).
#[derive(Clone, Debug, PartialEq)]
pub struct EaseTrackSegment {
    /// Left key.
    pub from: Id,
    /// Right key.
    pub to: Id,
    /// Left key time.
    pub start: Time,
    /// Right key time.
    pub end: Time,
    /// The effective shape.
    pub shape: EaseShape,
    /// Size of the value change between the two keys (a length for vectors); `None` when unknown (the curve editor
    /// of a transition, masks paths): such a segment is drawn on its own normalized scale.
    pub change: Option<f64>,
    /// Vertical scale of this segment's curve on the row's one shared scale: its steady speed (value change per
    /// second) over the largest steady speed of the row. 0 = the value does not move (a flat line at speed zero),
    /// 1 = the fastest segment of the row. Normalized segments (no `change`) stay 1.
    pub scale: f64,
}

impl EaseTrackSegment {
    /// A segment with scale 1.
    pub fn new(from: Id, to: Id, start: Time, end: Time, shape: EaseShape, change: Option<f64>) -> EaseTrackSegment {
        EaseTrackSegment { from, to, start, end, shape, change, scale: 1.0 }
    }

    /// Steady speed: value change per second (`None` when the change is unknown).
    pub fn steady_speed(&self) -> Option<f64> {
        let span = self.end - self.start;
        let d = span.value() as f64 / span.timescale().max(1) as f64;
        let change = self.change?;
        if d > 0.0 { Some(change.abs() / d) } else { None }
    }

    /// Sets `scale` on every segment of one row so they share one vertical scale (speed = value change per second).
    pub fn applying_shared_scale(segs: Vec<EaseTrackSegment>) -> Vec<EaseTrackSegment> {
        let top = segs.iter().filter_map(EaseTrackSegment::steady_speed).reduce(f64::max).unwrap_or(0.0);
        segs.into_iter()
            .map(|mut s| {
                if let Some(v) = s.steady_speed() {
                    s.scale = if top > 0.0 { v / top } else { 0.0 };
                }
                s
            })
            .collect()
    }
}

/// Size of the value change between two keys of a track.
#[doc(hidden)]
pub trait KeyframeTrackValueChange {
    /// `|right - left|` as a speed magnitude; `None` if a key is missing.
    fn value_change(&self, a: Id, b: Id) -> Option<f64>;
}

impl<V: KeyframeValue> KeyframeTrackValueChange for KeyframeTrack<V> {
    fn value_change(&self, a: Id, b: Id) -> Option<f64> {
        let (l, r) = (self.key(a)?, self.key(b)?);
        Some(V::minus(&r.value, &l.value).speed_magnitude().abs())
    }
}

impl PropertyTrack {
    /// Every segment of the track in time order.
    pub fn ease_segments(&self) -> Vec<EaseTrackSegment> {
        let times = self.times();
        let raw = times
            .windows(2)
            .filter_map(|w| {
                let ((a, ta), (b, tb)) = (w[0], w[1]);
                let s = self.ease_shape(a, b)?;
                Some(EaseTrackSegment::new(a, b, ta, tb, s.effective(), self.value_change(a, b)))
            })
            .collect();
        EaseTrackSegment::applying_shared_scale(raw)
    }

    /// Size of the value change between two keys; `None` for path tracks (no single number).
    #[doc(hidden)]
    pub fn value_change(&self, a: Id, b: Id) -> Option<f64> {
        match self {
            PropertyTrack::Scalar(t) => t.value_change(a, b),
            PropertyTrack::Vector(t) => t.value_change(a, b),
            PropertyTrack::Color(t) => t.value_change(a, b),
            PropertyTrack::Path(_) => None,
        }
    }
}

impl EaseSelection {
    /// The effective shape of every selected segment, in segment order.
    pub fn shapes(&self, summary: &KeyframeSummary) -> Vec<(crate::EaseSegment, EaseShape)> {
        self.segments()
            .iter()
            .filter_map(|seg| {
                let s = summary.tracks.get(&seg.property)?.ease_shape(seg.from, seg.to)?;
                Some((seg.clone(), s.effective()))
            })
            .collect()
    }

    /// Rewrites every selected segment from its own shape (several rows eased together keep their own speeds while
    /// one handle drag changes the reach of all). Only the selected side of a segment is written. Returns segments
    /// written.
    pub fn transform(
        &self,
        summary: &mut KeyframeSummary,
        mut change: impl FnMut(&crate::EaseSegment, EaseShape) -> EaseShape,
    ) -> usize {
        let mut n = 0;
        for seg in self.segments() {
            let Some(t) = summary.tracks.get_mut(&seg.property) else { continue };
            let Some(s) = t.ease_shape(seg.from, seg.to).map(|s| s.effective()) else { continue };
            if t.set_ease_shape(&change(seg, s), seg.from, seg.to, seg.side) {
                n += 1;
            }
        }
        n
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::EasingCurveShape;
    use crate::keyframes_editing::test_support::{id, key, scalar, t};
    use crate::keyframes_editing::{PropertyID, SummaryMember};
    use sq_core_time::EasingCurve;
    use sq_core_time::{Keyframe, Vec2};
    use std::collections::{BTreeMap, BTreeSet};

    fn smooth(r: f64) -> EaseShape {
        EaseShape::new(Interpolation::Bezier, EaseHandle { dx: r, dy: 0.0 }, EaseHandle { dx: r, dy: 0.0 })
    }

    fn shape(od: f64, oy: f64, id_: f64, iy: f64) -> EaseShape {
        EaseShape::new(Interpolation::Bezier, EaseHandle { dx: od, dy: oy }, EaseHandle { dx: id_, dy: iy })
    }

    fn near(a: f64, b: f64, tol: f64) -> bool {
        (a - b).abs() < tol
    }

    #[test]
    fn smooth_key_has_speed_zero() {
        let s = smooth(0.33);
        assert_eq!((s.speed_out(), s.speed_in()), (0.0, 0.0));
        let pts = SpeedHill::default_samples(&s);
        assert!(pts[0].speed.abs() < 1e-9 && pts[pts.len() - 1].speed.abs() < 1e-9);
        assert_eq!((pts[0].x, pts[pts.len() - 1].x), (0.0, 1.0));
    }

    #[test]
    fn steady_is_flat_at_one_and_hold_has_no_speed() {
        assert_eq!((EaseShape::LINEAR.speed_out(), EaseShape::LINEAR.speed_in()), (1.0, 1.0));
        assert!(SpeedHill::default_samples(&EaseShape::LINEAR).iter().all(|p| near(p.speed, 1.0, 1e-9)));
        assert_eq!((EaseShape::HOLD.speed_out(), EaseShape::HOLD.speed_in()), (0.0, 0.0));
        assert!(SpeedHill::default_samples(&EaseShape::HOLD).iter().all(|p| p.speed == 0.0));
    }

    #[test]
    fn key_speed_is_the_handle_slope() {
        let s = shape(0.2, 0.5, 0.4, 0.1);
        assert!(near(s.speed_out(), 2.5, 1e-9) && near(s.speed_in(), 0.25, 1e-9));
        let pts = SpeedHill::default_samples(&s);
        assert!(near(pts[0].speed, 2.5, 1e-6) && near(pts[pts.len() - 1].speed, 0.25, 1e-6));
    }

    #[test]
    fn peak_for_reach_33_is_149_times_the_average_and_sits_in_the_middle() {
        assert!(near(SpeedHill::peak(&smooth(0.33)), 1.0 / 0.67, 1e-3));
        assert!(near(SpeedHill::peak(&smooth(0.33)), 1.49, 0.005));
        let top =
            SpeedHill::samples(&smooth(0.33), 49).into_iter().reduce(|a, b| if b.speed > a.speed { b } else { a });
        assert!(near(top.map_or(0.0, |p| p.x), 0.5, 1e-9));
        assert!(SpeedHill::peak(&smooth(0.15)) < SpeedHill::peak(&smooth(0.33)));
        assert!(near(SpeedHill::peak(&smooth(0.15)), 1.0 / 0.85, 1e-3));
    }

    #[test]
    fn area_is_the_value_delta() {
        let shapes = [
            smooth(0.33),
            smooth(0.15),
            EaseShape::LINEAR,
            shape(0.2, 0.5, 0.4, 0.1),
            EasingCurve::ease_in().shape(),
            EasingCurve::ease_out().shape(),
        ];
        for s in shapes {
            assert!(near(SpeedHill::area(&SpeedHill::samples(&s, 400)), 1.0, 2e-3));
        }
        assert_eq!(SpeedHill::area(&SpeedHill::default_samples(&EaseShape::HOLD)), 0.0);
    }

    #[test]
    fn the_hill_is_the_derivative_of_the_evaluated_curve() {
        let mut a = Keyframe::new(id(1), t(0), 0.0);
        a.interpolation = Interpolation::Bezier;
        a.out_handle = EaseHandle { dx: 0.33, dy: 0.0 };
        let mut b = Keyframe::new(id(2), t(2), 10.0);
        b.in_handle = EaseHandle { dx: 0.33, dy: 0.0 };
        for p in SpeedHill::samples(&smooth(0.33), 21).iter().filter(|p| p.x > 0.05 && p.x < 0.95) {
            let h = 1e-5;
            let numeric = (KeyframeTrack::segment_value(&a, &b, p.x + h)
                - KeyframeTrack::segment_value(&a, &b, p.x - h))
                / (2.0 * h)
                / 10.0;
            assert!(near(numeric, p.speed, 1e-3));
        }
    }

    #[test]
    fn setting_reach_keeps_the_key_speed() {
        let s = shape(0.2, 0.5, 0.4, 0.1);
        let longer = s.setting_reach(0.4, EaseSide::Out);
        assert!(near(longer.reach_out(), 0.4, 1e-9) && near(longer.speed_out(), 2.5, 1e-9));
        assert_eq!(longer.r#in, s.r#in);
        let in_side = s.setting_reach(0.1, EaseSide::In);
        assert!(near(in_side.reach_in(), 0.1, 1e-9) && near(in_side.speed_in(), 0.25, 1e-9));
        assert_eq!(in_side.out, s.out);
    }

    /// Each handle's influence runs 0...100 % on its own, whatever the other handle has (Premiere semantics).
    #[test]
    fn reach_is_independent_per_side_up_to_full_influence() {
        let s = smooth(0.33);
        assert_eq!(s.setting_reach(0.9, EaseSide::Out).reach_out(), 0.9);
        assert_eq!(s.setting_reach(1.0, EaseSide::Out).reach_out(), 1.0);
        assert_eq!(s.setting_reach(5.0, EaseSide::In).reach_in(), 1.0);
        assert!(near(s.setting_reach(-1.0, EaseSide::Out).reach_out(), SpeedHill::MIN_REACH, 1e-9));
        let both = s.setting_reach(2.0, EaseSide::Both);
        assert!(both.reach_out() == 1.0 && both.reach_in() == 1.0);
        let samples = SpeedHill::samples(&both, 201);
        assert!(samples[0].speed.abs() < 1e-9 && samples[200].speed.abs() < 1e-9);
        assert!(near(SpeedHill::area(&samples), 1.0, 0.01));
        assert!(samples.windows(2).all(|w| w[0].x <= w[1].x));
    }

    #[test]
    fn setting_reach_on_steady_keeps_the_motion() {
        let s = EaseShape::LINEAR.setting_reach(0.5, EaseSide::Out);
        assert_eq!(s.interpolation(), Interpolation::Bezier);
        assert!(near(s.speed_out(), 1.0, 1e-9));
        assert!(SpeedHill::default_samples(&s).iter().all(|p| near(p.speed, 1.0, 1e-6)));
    }

    #[test]
    fn setting_speed_keeps_the_reach() {
        let s = smooth(0.33).setting_speed(2.0, EaseSide::Out, None);
        assert!(near(s.reach_out(), 0.33, 1e-9) && near(s.speed_out(), 2.0, 1e-9));
        assert_eq!(s.speed_in(), 0.0);
        assert_eq!(EaseShape::HOLD.setting_speed(2.0, EaseSide::Out, None), EaseShape::HOLD);
        assert_eq!(EaseShape::HOLD.setting_reach(0.2, EaseSide::Out), EaseShape::HOLD);
    }

    #[test]
    fn transform_writes_every_selected_segment_with_its_own_shape() {
        let pos = vec![Keyframe::new(id(11), t(0), Vec2::ZERO), Keyframe::new(id(12), t(2), Vec2::new(50.0, 50.0))];
        let mut sum = KeyframeSummary::new(BTreeMap::from([
            ("position".into(), PropertyTrack::Vector(KeyframeTrack::with_keys(pos))),
            ("scale".into(), scalar(vec![key(1, 0, 100.0), key(2, 2, 120.0)])),
        ]));
        let members: BTreeSet<_> = [("position", 11), ("position", 12), ("scale", 1), ("scale", 2)]
            .iter()
            .map(|(p, n)| SummaryMember::new((*p).into(), id(*n)))
            .collect();
        let sel = EaseSelection::new(&sum, &members, &BTreeSet::new());
        sel.apply(&smooth(0.33), &mut sum);
        // Only Scale's out reach changes; Position keeps its own shape.
        let n = sel.transform(&mut sum, |seg, s| {
            if seg.property == PropertyID::new("scale") { s.setting_reach(0.15, EaseSide::Out) } else { s }
        });
        assert_eq!(n, 2);
        let shapes = sel.shapes(&sum);
        assert_eq!(shapes.len(), 2);
        let reach = |p: &str| shapes.iter().find(|(s, _)| s.property == PropertyID::new(p)).map(|(_, s)| s.reach_out());
        assert!(near(reach("scale").unwrap_or(0.0), 0.15, 1e-9));
        assert!(near(reach("position").unwrap_or(0.0), 0.33, 1e-9));
    }

    #[test]
    fn track_segments_list_every_segment_in_order() {
        let keys = vec![key(1, 0, 0.0), key(2, 2, 10.0), key(3, 4, 0.0)];
        let mut tr = scalar(keys);
        tr.apply(&EasingCurve::ease_in_out(), &BTreeSet::from([id(1), id(2)]), EaseSide::Both);
        let segs = tr.ease_segments();
        assert_eq!(segs.len(), 2);
        assert!(segs[0].from == id(1) && segs[0].to == id(2));
        assert!(segs[0].start == t(0) && segs[0].end == t(2));
        assert_eq!(segs[0].shape.speed_out(), 0.0);
        assert!(segs[1].start == t(2) && segs[1].end == t(4));
    }

    fn scaled_segments(keys: Vec<Keyframe<f64>>) -> Vec<EaseTrackSegment> {
        let ids: BTreeSet<Id> = keys.iter().map(|k| k.id).collect();
        let mut tr = scalar(keys);
        tr.apply(&EasingCurve::ease_in_out(), &ids, EaseSide::Both);
        tr.ease_segments()
    }

    #[test]
    fn shared_scale_equal_keys_draw_flat_at_zero() {
        let segs = scaled_segments(vec![key(1, 0, 55.0), key(2, 2, 50.0), key(3, 6, 50.0), key(4, 8, 55.0)]);
        assert_eq!(segs[1].scale, 0.0);
        assert!(segs[0].scale > 0.0 && segs[2].scale > 0.0);
    }

    #[test]
    fn shared_scale_doubling_the_change_doubles_the_peak() {
        let segs = scaled_segments(vec![key(1, 0, 0.0), key(2, 2, 10.0), key(3, 4, 30.0)]);
        assert!(near(segs[1].scale, 1.0, 1e-12) && near(segs[0].scale, 0.5, 1e-12));
        let peak0 = SpeedHill::peak(&segs[0].shape) * segs[0].scale;
        let peak1 = SpeedHill::peak(&segs[1].shape) * segs[1].scale;
        assert!(near(peak1, 2.0 * peak0, 1e-9));
    }

    #[test]
    fn shared_scale_is_value_change_per_second() {
        let segs = scaled_segments(vec![key(1, 0, 0.0), key(2, 2, 10.0), key(3, 6, 20.0)]);
        assert!(near(segs[1].scale, 0.5, 1e-12));
    }

    #[test]
    fn value_between_equal_keys_is_constant() {
        let mut a = key(1, 0, 50.0);
        a.interpolation = Interpolation::Bezier;
        a.out_handle = EaseHandle { dx: 0.9, dy: 3.0 };
        let mut b = key(2, 4, 50.0);
        b.in_handle = EaseHandle { dx: 0.9, dy: -3.0 };
        let tr = KeyframeTrack::with_keys(vec![a, b]);
        for s in 0..=4 {
            assert_eq!(tr.value(Time::new(s * 100, 100)), Some(50.0));
        }
    }

    #[test]
    fn excursion_is_zero_for_curves_between_their_keys_and_follows_the_true_extreme() {
        for s in
            [EaseShape::LINEAR, EasingCurve::ease_in_out().shape(), EasingCurve::fast_start().shape(), EaseShape::HOLD]
        {
            assert_eq!(s.value_excursion(), (0.0, 0.0));
        }
        let ease = EasingCurve::ease_in_out().shape();
        let over = ease.setting_speed(-1.2, EaseSide::In, None);
        assert!(over.speed_in() == -1.2 && near(over.reach_in(), 1.0 / 3.0, 1e-12));
        assert!(over.value_excursion().1 > 0.02 && over.value_excursion().0 == 0.0);
        let wind = ease.setting_speed(-1.2, EaseSide::Out, None);
        assert!(wind.value_excursion().0 > 0.02 && wind.value_excursion().1 == 0.0);
        let s = shape(0.2, 0.9, 0.3, -0.4);
        let top = (0..=1000)
            .map(|i| sq_core_time::keyframes_model::keyframe_math::bezier_progress(i as f64 / 1000.0, s.out, s.r#in))
            .fold(f64::MIN, f64::max);
        assert!(near(s.value_excursion().1, top - 1.0, 2e-3));
    }

    #[test]
    fn setting_speed_keeps_the_handle_value_inside_the_given_range() {
        let s = EasingCurve::ease_in_out().shape();
        assert_eq!(s.setting_speed(100.0, EaseSide::Out, Some(&(-2.0..=3.0))).out.dy, 3.0);
        assert_eq!(s.setting_speed(-100.0, EaseSide::In, Some(&(-2.0..=3.0))).r#in.dy, -2.0);
        assert_eq!(s.setting_speed(-1.0, EaseSide::In, Some(&(0.0..=1.0))).r#in.dy, 0.0);
        assert_eq!(s.setting_speed(f64::NAN, EaseSide::Out, Some(&(-2.0..=3.0))).out.dy, 0.0);
        assert_eq!(EaseShape::HOLD.setting_speed(2.0, EaseSide::Out, Some(&(-2.0..=3.0))), EaseShape::HOLD);
    }
}
