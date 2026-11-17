// Swift: KeyTickMath.swift
//! The geometry of the layer list's key strip: positions of keys across the clip, the clip-local time under x, the item's
//! range bar.

use sq_core_time::{Time, TimeRange};

/// Fraction 0...1 of `t` in `duration` (exact integer ratio first, one division at the end).
pub fn fraction(t: Time, duration: Time) -> f64 {
    if duration.value() <= 0 {
        return 0.0;
    }
    let num = (i128::from(t.value()) * i128::from(duration.timescale())) as f64;
    let den = (i128::from(duration.value()) * i128::from(t.timescale())) as f64;
    (num / den).clamp(0.0, 1.0)
}

/// x of each tick (center) inside `width`; keys past the clip are clamped to its ends.
pub fn positions(times: &[Time], duration: Time, width: f64) -> Vec<f64> {
    if width <= 0.0 {
        return Vec::new();
    }
    times.iter().map(|t| fraction(*t, duration) * width).collect()
}

/// The clip-local time at x (clamped to the clip), on the clip's own timescale.
pub fn time_at_x(x: f64, width: f64, duration: Time) -> Time {
    if width <= 0.0 || duration.value() <= 0 {
        return Time::ZERO;
    }
    let f = (x / width).clamp(0.0, 1.0);
    Time::new((duration.value() as f64 * f).round() as i64, duration.timescale())
}

/// The range bar inside `width` (never thinner than 2 pt, so an item cut down to nothing still shows where it is).
pub fn range_span(r: TimeRange, duration: Time, width: f64) -> (f64, f64) {
    let a = fraction(r.start, duration) * width;
    let b = fraction(r.end(), duration) * width;
    let w = (b - a).max(2.0).min(width.max(0.0));
    (a.min((width - w).max(0.0)), w)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fractions_are_exact_and_clamped() {
        let d = Time::new(10, 1);
        assert_eq!(fraction(Time::new(5, 1), d), 0.5);
        assert_eq!(fraction(Time::new(99, 1), d), 1.0);
        assert_eq!(fraction(Time::new(-3, 1), d), 0.0);
        assert_eq!(fraction(Time::new(1, 1), Time::ZERO), 0.0);
    }

    #[test]
    fn ticks_time_and_range_bar() {
        let d = Time::new(10, 1);
        assert_eq!(positions(&[Time::ZERO, Time::new(5, 1), Time::new(20, 1)], d, 200.0), [0.0, 100.0, 200.0]);
        assert!(positions(&[Time::ZERO], d, 0.0).is_empty());
        assert_eq!(time_at_x(50.0, 200.0, d), Time::new(3, 1));
        assert_eq!(time_at_x(500.0, 200.0, d), Time::new(10, 1));
        assert_eq!(time_at_x(1.0, 0.0, d), Time::ZERO);
        // A range cut down to nothing keeps a 2 pt bar inside the strip.
        let (x, w) = range_span(TimeRange::new(Time::new(10, 1), Time::ZERO), d, 200.0);
        assert_eq!((x, w), (198.0, 2.0));
        let (x, w) = range_span(TimeRange::from_end(Time::new(2, 1), Time::new(6, 1)), d, 100.0);
        assert_eq!((x, w), (20.0, 40.0));
    }
}
