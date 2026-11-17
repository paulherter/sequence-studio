// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SpeedKeysPoints.swift

use crate::{ClipSpeed, EaseShape, SpeedKeys};
use sq_core_time::{EaseSide, EasingCurve, Interpolation, Time};

// Speed points the way a retime curve has them: a point is a key that plays the same source frame wherever it sits, so
// moving it sideways makes the span before it faster or slower and the clip length follows; easing a point opens a short
// speed transition at it and curves that, like the keyframe easing of any other row.

impl SpeedKeys {
    /// Moves the point at `boundary` by `delta` on the timeline while it keeps its source frame: the constant span before
    /// it grows or shrinks to `delta` frames more or less (whole frames, at least one) and takes the speed that still
    /// covers the same source, within 1 % ... 10000 %. The spans after it keep their speed and shift; the clip length
    /// changes by the same amount. `None` when the point is a half of a transition (move that instead) or nothing changes.
    pub fn retiming_key(&self, b: usize, delta: Time, fd: Time) -> Option<SpeedKeys> {
        if b < 1 || b >= self.segments.len() || self.segments[b - 1].is_ramp() || self.segments[b].is_ramp() {
            return None;
        }
        let l = &self.segments[b - 1];
        let n = (l.duration + delta.snapped(fd)).max(fd);
        if n == l.duration {
            return None;
        }
        let edited = self.setting_speed(b - 1, ClipSpeed::from_source_over(l.span(), n), fd);
        if edited == *self { None } else { Some(edited) }
    }

    /// Easing on a speed point (Easy Ease / Ease In / Ease Out): the speed transition at clip-local `local` gets the curve
    /// on the asked side (`In` the arrival, `Out` the start). `local` inside a transition or on one of its ends eases that
    /// transition; on a plain point between two different speeds a transition a quarter of the shorter neighbor wide (at
    /// least one frame) opens centered on it first. `None` when there is nothing to ease (no change of speed at that
    /// point, a Hold curve, or nothing changes).
    pub fn easing_point(&self, local: Time, curve: &EasingCurve, side: EaseSide, fd: Time) -> Option<SpeedKeys> {
        if curve.interpolation().is_hold() {
            return None;
        }
        let bs = self.boundaries();
        let ramp =
            (0..self.segments.len()).find(|j| self.segments[*j].is_ramp() && bs[*j] <= local && local <= bs[*j + 1]);
        let (k, i) = match ramp {
            Some(r) => (self.clone(), r),
            None => {
                let snapped = local.snapped(fd);
                let b = (1..self.segments.len()).find(|j| bs[*j] == snapped)?;
                let (l, r) = (&self.segments[b - 1], &self.segments[b]);
                if l.is_ramp() || r.is_ramp() || l.from == r.from {
                    return None;
                }
                let m = l.duration.min(r.duration);
                let half = Time::new(m.value(), m.timescale() * 4).snapped(fd).max(fd);
                (self.splitting_key(b, half, fd)?, b)
            }
        };
        let old = k.segments[i].ease_shape();
        let shape = EaseShape::new(
            Interpolation::Bezier,
            if side == EaseSide::In { old.out } else { curve.out_handle },
            if side == EaseSide::Out { old.r#in } else { curve.in_handle },
        );
        let eased = k.setting_ease(&shape, i)?;
        if eased == *self { None } else { Some(eased) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SpeedSegment;

    const FD: Time = Time::new(1, 30);

    fn f(n: i64) -> Time {
        Time::new(n, 30)
    }

    fn two() -> SpeedKeys {
        let seg = |frames, pct| SpeedSegment::constant(f(frames), ClipSpeed::from_percent(pct), false);
        SpeedKeys::new(vec![seg(30, 100.0), seg(30, 200.0)], Time::ZERO)
    }

    #[test]
    fn retiming_a_point_keeps_its_source_frame() {
        let k = two();
        let moved = k.retiming_key(1, f(15), FD).unwrap();
        assert_eq!(moved.segments[0].duration, f(45));
        assert_eq!(moved.position(f(45)), k.position(f(30)));
        assert_eq!(moved.duration(), f(75));
        assert!(k.retiming_key(1, Time::ZERO, FD).is_none());
        assert!(k.retiming_key(0, f(5), FD).is_none());
    }

    #[test]
    fn easing_a_plain_point_opens_a_transition_and_curves_it() {
        let k = two();
        let eased = k.easing_point(f(30), &EasingCurve::ease_in_out(), EaseSide::Both, FD).unwrap();
        assert_eq!(eased.segments.len(), 3);
        assert!(eased.segments[1].ease().is_some());
        assert_eq!(eased.duration(), f(60));
    }

    #[test]
    fn a_hold_curve_and_a_point_without_a_speed_change_ease_nothing() {
        assert!(two().easing_point(f(30), &EasingCurve::hold(), EaseSide::Both, FD).is_none());
        let same = SpeedKeys::new(
            vec![
                SpeedSegment::constant(f(30), ClipSpeed::NORMAL, false),
                SpeedSegment::constant(f(30), ClipSpeed::NORMAL, false),
            ],
            Time::ZERO,
        );
        assert!(same.easing_point(f(30), &EasingCurve::ease_in_out(), EaseSide::Both, FD).is_none());
        assert!(two().easing_point(f(10), &EasingCurve::ease_in_out(), EaseSide::Both, FD).is_none());
    }
}
