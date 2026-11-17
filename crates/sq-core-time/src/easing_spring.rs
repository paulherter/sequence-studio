// SPDX-License-Identifier: GPL-3.0-or-later
//! Damped spring easing and curve previews, ported from `EasingSpring`. The spring is runtime-only (not stored in
//! project files): applying it bakes plain linear keys, so the file format is unchanged.

use crate::keyframes_model::keyframe_math;
use crate::{EasingCurve, EasingLibrary, IdSource, Interpolation, Keyframe, KeyframeValue, Time};

/// Upper bound on baked segments (keeps keys sane for very long spans).
const MAX_BAKED_SEGMENTS: i64 = 600;

/// Spring easing: `progress` goes 0 to 1, may overshoot 1, and ends exactly on 1.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SpringEasing {
    bounce: f64,
}

impl SpringEasing {
    /// `bounce` 0 = critically damped (no overshoot), 1 = very bouncy; clamped to 0...1.
    pub fn new(bounce: f64) -> Self {
        SpringEasing { bounce: bounce.clamp(0.0, 1.0) }
    }

    /// The clamped bounce.
    pub fn bounce(&self) -> f64 {
        self.bounce
    }

    /// Eased progress for normalized time `t` (0 below 0, exactly 1 from 1 on).
    pub fn progress(&self, t: f64) -> f64 {
        if t <= 0.0 {
            return 0.0;
        }
        if t >= 1.0 {
            return 1.0;
        }
        // Damping ratio (1 = critical). The envelope e^(-z*w) = 0.001 at t = 1, so the spring has settled by the
        // end of the segment.
        let z = 1.0 - 0.9 * self.bounce;
        let w = 1000.0_f64.ln() / z;
        let raw = |x: f64| {
            if z >= 0.9999 {
                1.0 - (-w * x).exp() * (1.0 + w * x)
            } else {
                let wd = w * (1.0 - z * z).sqrt();
                1.0 - (-z * w * x).exp() * ((wd * x).cos() + z * w / wd * (wd * x).sin())
            }
        };
        // Distribute the tiny residual linearly so the end value is exact.
        raw(t) + (1.0 - raw(1.0)) * t
    }

    /// Progress sampled at `count` evenly spaced points, for the library preview.
    pub fn preview_samples(&self, count: i64) -> Vec<f64> {
        samples(count, |t| self.progress(t))
    }

    /// Linear keys sampling the spring from `a` to `b`. First key is `a` at `start`, last is exactly `b` at `end`.
    /// Key ids come from `ids`.
    pub fn baked_keys<V: KeyframeValue>(
        &self,
        ids: &mut dyn IdSource,
        a: &V,
        b: &V,
        start: Time,
        end: Time,
        samples_per_second: i64,
    ) -> Vec<Keyframe<V>> {
        if end < start {
            return Vec::new();
        }
        if end == start {
            return vec![Keyframe::new(ids.next_id(), start, b.clone())];
        }
        let secs = keyframe_math::seconds(end - start);
        // Saturating `as` stands in for Swift's trap on absurd spans.
        let n = ((secs * samples_per_second.max(1) as f64).round() as i64).clamp(2, MAX_BAKED_SEGMENTS);
        (0..=n)
            .map(|i| {
                let (time, value) = if i == 0 {
                    (start, a.clone())
                } else if i == n {
                    (end, b.clone())
                } else {
                    (interpolated_time(start, end, i, n), V::lerp(a, b, self.progress(i as f64 / n as f64)))
                };
                Keyframe::new(ids.next_id(), time, value)
            })
            .collect()
    }
}

/// `start + (end - start) * i / n`, computed in i128 so large values or timescales cannot overflow. Falls back to
/// a 1/90000 s grid if the exact rational does not fit i64.
// shortcut: wrapping i128 math; Swift traps for |value| and timescale near 2^63 (v * ts * n), real callers pass spans
// of seconds. Upgrade when such spans must bake.
pub fn interpolated_time(start: Time, end: Time, i: i64, n: i64) -> Time {
    let (ts, te) = (i128::from(start.timescale()), i128::from(end.timescale()));
    let (i, n) = (i128::from(i), i128::from(n));
    let den = ts.wrapping_mul(te).wrapping_mul(n);
    let num = i128::from(start.value()).wrapping_mul(te).wrapping_mul(n).wrapping_add(
        i128::from(end.value())
            .wrapping_mul(ts)
            .wrapping_sub(i128::from(start.value()).wrapping_mul(te))
            .wrapping_mul(i),
    );
    let g = gcd(num.unsigned_abs(), den.unsigned_abs()).max(1) as i128;
    let (v, d) = (num / g, den / g);
    if let (Ok(v64), Ok(d64)) = (i64::try_from(v), i64::try_from(d))
        && d64 > 0
    {
        return Time::new(v64, d64);
    }
    for grid in [90_000_i64, 1000, 1] {
        if let Ok(q) = i64::try_from(num.wrapping_mul(i128::from(grid)) / den) {
            return Time::new(q, grid);
        }
    }
    Time::new((num / den).clamp(i128::from(i64::MIN), i128::from(i64::MAX)) as i64, 1)
}

fn gcd(mut a: u128, mut b: u128) -> u128 {
    while b != 0 {
        (a, b) = (b, a % b);
    }
    a
}

/// `f` at `count` evenly spaced points of 0...1; `[1]` for fewer than two points.
fn samples(count: i64, f: impl Fn(f64) -> f64) -> Vec<f64> {
    if count <= 1 {
        return vec![1.0];
    }
    (0..count).map(|i| f(i as f64 / (count - 1) as f64)).collect()
}

impl EasingCurve {
    /// Eased progress at `count` evenly spaced points (0...1 in time), for library preview thumbnails.
    pub fn preview_samples(&self, count: i64) -> Vec<f64> {
        samples(count, |t| match self.interpolation() {
            Interpolation::Linear => t,
            Interpolation::Hold => f64::from(u8::from(t >= 1.0)),
            Interpolation::HoldAhead => f64::from(u8::from(t > 0.0)),
            Interpolation::Bezier => keyframe_math::bezier_progress(t, self.out_handle, self.in_handle),
        })
    }
}

/// A named spring for the library list.
#[derive(Clone, Debug, PartialEq)]
pub struct SpringPreset {
    /// Shown name, also its identity.
    pub name: &'static str,
    /// The spring.
    pub spring: SpringEasing,
}

impl EasingLibrary {
    /// The springs of the library list.
    pub fn spring_presets() -> [SpringPreset; 3] {
        [
            SpringPreset { name: "Spring smooth", spring: SpringEasing::new(0.0) },
            SpringPreset { name: "Spring soft", spring: SpringEasing::new(0.4) },
            SpringPreset { name: "Spring bounce", spring: SpringEasing::new(0.7) },
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SequentialIds;

    #[test]
    fn progress_is_clamped_and_ends_on_one() {
        for b in [0.0, 0.4, 0.7, 1.0] {
            let s = SpringEasing::new(b);
            assert_eq!((s.progress(-1.0), s.progress(0.0), s.progress(1.0), s.progress(2.0)), (0.0, 0.0, 1.0, 1.0));
        }
        assert_eq!(SpringEasing::new(-0.5).bounce(), 0.0);
        assert_eq!(SpringEasing::new(2.0).bounce(), 1.0);
    }

    #[test]
    fn bounce_overshoots_and_critical_does_not() {
        let peak = |b| (1..100).map(|i| SpringEasing::new(b).progress(f64::from(i) / 100.0)).fold(0.0, f64::max);
        assert!(peak(0.7) > 1.0);
        assert!(peak(0.0) <= 1.0);
    }

    #[test]
    fn baked_keys_start_and_end_exactly() {
        let mut ids = SequentialIds::default();
        let s = SpringEasing::new(0.4);
        let keys = s.baked_keys(&mut ids, &10.0, &20.0, Time::new(0, 1), Time::new(1, 1), 30);
        assert_eq!(keys.len(), 31);
        assert_eq!((keys[0].time, keys[0].value), (Time::ZERO, 10.0));
        assert_eq!((keys[30].time, keys[30].value), (Time::new(1, 1), 20.0));
        assert!(keys.iter().all(|k| k.interpolation == Interpolation::Linear));
        assert!(s.baked_keys(&mut ids, &0.0, &1.0, Time::new(2, 1), Time::new(1, 1), 30).is_empty());
        let one = s.baked_keys(&mut ids, &0.0, &1.0, Time::new(1, 1), Time::new(1, 1), 30);
        assert_eq!((one.len(), one[0].value), (1, 1.0));
        let long = s.baked_keys(&mut ids, &0.0, &1.0, Time::ZERO, Time::new(3600, 1), 30);
        assert_eq!(long.len(), 601);
    }

    #[test]
    fn interpolated_time_is_exact() {
        assert_eq!(interpolated_time(Time::new(1, 3), Time::new(2, 3), 1, 2), Time::new(1, 2));
        assert_eq!(interpolated_time(Time::ZERO, Time::new(1, 1), 7, 7), Time::new(1, 1));
    }

    #[test]
    fn previews_have_the_asked_count() {
        assert_eq!(SpringEasing::new(0.0).preview_samples(1), [1.0]);
        assert_eq!(EasingCurve::linear().preview_samples(3), [0.0, 0.5, 1.0]);
        assert_eq!(EasingCurve::hold().preview_samples(3), [0.0, 0.0, 1.0]);
        let ahead = EasingCurve::new(
            crate::Id::NIL,
            String::new(),
            Interpolation::HoldAhead,
            crate::EaseHandle::LINEAR,
            crate::EaseHandle::LINEAR,
        );
        // A Hold Ahead shape is stored as Hold in a curve.
        assert_eq!(ahead.preview_samples(3), [0.0, 0.0, 1.0]);
        assert_eq!(EasingLibrary::spring_presets().map(|p| p.spring.bounce()), [0.0, 0.4, 0.7]);
    }
}
