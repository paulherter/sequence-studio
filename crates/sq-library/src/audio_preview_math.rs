// Swift: AudioPreviewMath.swift
//! Pure mapping between a 0...1 scrub fraction and rational time, and the in/out range of a library item.

use sq_core_time::{Time, TimeRange};

/// Fraction is quantized to 1/1_000_000 so the result stays rational.
const RESOLUTION: i64 = 1_000_000;

/// Pure mapping between a 0...1 scrub fraction and rational time.
pub struct PreviewTimeMap;

impl PreviewTimeMap {
    /// The time at `fraction` of `duration` (zero for a NaN fraction or an empty duration).
    pub fn time(fraction: f64, duration: Time) -> Time {
        if !fraction.is_finite() || duration <= Time::ZERO {
            return Time::ZERO;
        }
        let f = fraction.clamp(0.0, 1.0);
        let step = (f * RESOLUTION as f64).round() as i64;
        let t = Time::new(duration.value() * step, duration.timescale() * RESOLUTION);
        t.min(duration)
    }

    /// The 0...1 position of `time` in `duration`.
    pub fn fraction(time: Time, duration: Time) -> f64 {
        if duration <= Time::ZERO || time <= Time::ZERO {
            return 0.0;
        }
        if time >= duration {
            return 1.0;
        }
        let num = time.value() as f64 * duration.timescale() as f64;
        let den = time.timescale() as f64 * duration.value() as f64;
        (num / den).clamp(0.0, 1.0)
    }
}

/// In/out selection on a library item; the part that gets dragged to the timeline.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct PreviewRange {
    duration: Time,
    in_point: Time,
    out_point: Time,
}

impl PreviewRange {
    /// The whole of `duration`.
    pub fn new(duration: Time) -> PreviewRange {
        let duration = duration.max(Time::ZERO);
        PreviewRange { duration, in_point: Time::ZERO, out_point: duration }
    }

    /// A selection given by two fractions (dragged right-to-left gives in > out: they are ordered).
    pub fn from_fractions(duration: Time, in_fraction: f64, out_fraction: f64) -> PreviewRange {
        let mut r = PreviewRange::new(duration);
        let a = PreviewTimeMap::time(in_fraction, duration);
        let b = PreviewTimeMap::time(out_fraction, duration);
        r.set_in(a.min(b));
        r.set_out(a.max(b));
        r
    }

    /// Length of the item.
    pub fn duration(&self) -> Time {
        self.duration
    }

    /// Start of the selection.
    pub fn in_point(&self) -> Time {
        self.in_point
    }

    /// End of the selection.
    pub fn out_point(&self) -> Time {
        self.out_point
    }

    /// Swift `duration` setter with `didSet`: both points are clamped to the new length.
    pub fn set_duration(&mut self, duration: Time) {
        self.duration = duration.max(Time::ZERO);
        self.in_point = self.in_point.max(Time::ZERO).min(self.duration);
        self.out_point = self.out_point.min(self.duration).max(self.in_point);
    }

    /// The selection is the whole item.
    pub fn is_whole(&self) -> bool {
        self.in_point == Time::ZERO && self.out_point == self.duration
    }

    /// Range dragged with the item, `None` when empty (in == out).
    pub fn time_range(&self) -> Option<TimeRange> {
        (self.out_point > self.in_point).then(|| TimeRange::from_end(self.in_point, self.out_point))
    }

    /// Moves the start, within 0...duration.
    pub fn set_in(&mut self, t: Time) {
        self.in_point = t.max(Time::ZERO).min(self.duration);
    }

    /// Moves the end, within in...duration.
    pub fn set_out(&mut self, t: Time) {
        self.out_point = t.min(self.duration).max(self.in_point);
    }

    /// Back to the whole item.
    pub fn reset(&mut self) {
        self.in_point = Time::ZERO;
        self.out_point = self.duration;
    }

    /// `t` held inside the selection.
    pub fn clamp(&self, t: Time) -> Time {
        t.max(self.in_point).min(self.out_point)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DUR: Time = Time::new(10, 1);

    #[test]
    fn fraction_to_time() {
        assert_eq!(PreviewTimeMap::time(0.5, DUR), Time::new(5, 1));
        assert_eq!(PreviewTimeMap::time(0.0, DUR), Time::ZERO);
        assert_eq!(PreviewTimeMap::time(1.0, DUR), DUR);
    }

    #[test]
    fn fraction_clamps() {
        assert_eq!(PreviewTimeMap::time(-1.0, DUR), Time::ZERO);
        assert_eq!(PreviewTimeMap::time(7.0, DUR), DUR);
        assert_eq!(PreviewTimeMap::time(f64::NAN, DUR), Time::ZERO);
    }

    #[test]
    fn time_to_fraction() {
        assert_eq!(PreviewTimeMap::fraction(Time::new(5, 2), DUR), 0.25);
        assert_eq!(PreviewTimeMap::fraction(Time::new(20, 1), DUR), 1.0);
        assert_eq!(PreviewTimeMap::fraction(Time::new(-1, 1), DUR), 0.0);
        assert_eq!(PreviewTimeMap::fraction(Time::new(1, 1), Time::ZERO), 0.0);
    }

    #[test]
    fn round_trip_is_rational() {
        let t = PreviewTimeMap::time(1.0 / 3.0, Time::new(3, 1));
        assert!((PreviewTimeMap::fraction(t, Time::new(3, 1)) - 1.0 / 3.0).abs() < 1e-6);
    }

    #[test]
    fn range_defaults_to_whole() {
        let r = PreviewRange::new(DUR);
        assert_eq!(r.time_range(), Some(TimeRange::new(Time::ZERO, DUR)));
        assert!(r.is_whole());
    }

    #[test]
    fn range_clamps_and_orders() {
        let mut r = PreviewRange::new(DUR);
        r.set_in(Time::new(4, 1));
        r.set_out(Time::new(99, 1));
        assert_eq!(r.time_range(), Some(TimeRange::from_end(Time::new(4, 1), DUR)));
        r.set_out(Time::new(2, 1));
        assert!(r.out_point() >= r.in_point());
        assert_eq!(r.time_range(), None);
        r.set_in(Time::new(-5, 1));
        assert_eq!(r.in_point(), Time::ZERO);
    }

    #[test]
    fn range_from_fractions() {
        let r = PreviewRange::from_fractions(DUR, 0.8, 0.2);
        assert_eq!(r.time_range(), Some(TimeRange::from_end(Time::new(2, 1), Time::new(8, 1))));
        assert!(!r.is_whole());
    }

    #[test]
    fn range_clamped_to_new_duration() {
        let mut r = PreviewRange::new(DUR);
        r.set_in(Time::new(6, 1));
        r.set_duration(Time::new(5, 1));
        assert_eq!(r.in_point(), Time::new(5, 1));
        assert_eq!(r.out_point(), Time::new(5, 1));
    }

    #[test]
    fn playback_clamps_to_range() {
        let mut r = PreviewRange::new(DUR);
        r.set_in(Time::new(2, 1));
        r.set_out(Time::new(6, 1));
        assert_eq!(r.clamp(Time::new(1, 1)), Time::new(2, 1));
        assert_eq!(r.clamp(Time::new(9, 1)), Time::new(6, 1));
        assert_eq!(r.clamp(Time::new(3, 1)), Time::new(3, 1));
    }
}
