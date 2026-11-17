// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Time.swift

use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::ops::{Add, AddAssign, Mul, Neg, Sub, SubAssign};

/// Rational time: `value / timescale` seconds. Never a float.
/// Always reduced, so field equality is value equality (1/2 == 2/4); ordering is by value.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "TimeFields")]
pub struct Time {
    value: i64,
    timescale: i64,
}

/// The coded shape of `Time`; decoding goes through the reducing constructor.
#[derive(Deserialize)]
struct TimeFields {
    value: i64,
    timescale: i64,
}

impl TryFrom<TimeFields> for Time {
    type Error = String;
    fn try_from(f: TimeFields) -> Result<Self, String> {
        if f.timescale <= 0 {
            return Err(format!("timescale must be positive, got {}", f.timescale));
        }
        Ok(Time::new(f.value, f.timescale))
    }
}

impl Time {
    /// 0/1.
    pub const ZERO: Time = Time { value: 0, timescale: 1 };

    /// `value / timescale`, reduced by the gcd. Panics when `timescale <= 0` (a Swift precondition).
    pub const fn new(value: i64, timescale: i64) -> Time {
        assert!(timescale > 0, "timescale must be positive");
        let g = gcd(value.unsigned_abs(), timescale as u64);
        if g > 1 {
            Time { value: value / g as i64, timescale: timescale / g as i64 }
        } else {
            Time { value, timescale }
        }
    }

    /// Whole seconds.
    pub const fn seconds(seconds: i64) -> Time {
        Time::new(seconds, 1)
    }

    /// `n` frames of `frame_duration`.
    pub fn frames(n: i64, frame_duration: Time) -> Time {
        frame_duration * n
    }

    /// Numerator (reduced).
    pub const fn value(self) -> i64 {
        self.value
    }

    /// Denominator (reduced, always positive).
    pub const fn timescale(self) -> i64 {
        self.timescale
    }

    /// Below zero.
    pub const fn is_negative(self) -> bool {
        self.value < 0
    }

    /// Cross products `(self.value * fd.timescale, self.timescale * fd.value)`: `self / fd` as a fraction.
    fn over(self, fd: Time) -> (i128, i128) {
        (self.value as i128 * fd.timescale as i128, self.timescale as i128 * fd.value as i128)
    }

    /// Floor of `self / frame_duration`; 0 for a zero frame duration.
    pub fn frame_index(self, frame_duration: Time) -> i64 {
        let (num, den) = self.over(frame_duration);
        if den == 0 {
            return 0;
        }
        clamp_i64(floor_div(num, den))
    }

    /// Nearest whole multiple of `frame_duration` (ties round up); `self` when the duration is not positive.
    pub fn snapped(self, frame_duration: Time) -> Time {
        // floor(x + 1/2) as floor(x) plus one when the remainder is at least half the divisor: no 2^127 intermediates.
        let (num, den) = self.over(frame_duration);
        if den <= 0 {
            return self;
        }
        let q = floor_div(num, den);
        let r = num - q * den;
        frame_duration * clamp_i64(if r >= den - r { q + 1 } else { q })
    }

    /// Smallest whole multiple of `frame_duration` at or after `self`; `self` for a zero duration.
    pub fn ceiled(self, frame_duration: Time) -> Time {
        let (num, den) = self.over(frame_duration);
        if den == 0 {
            return self;
        }
        frame_duration * clamp_i64(-floor_div(-num, den))
    }

    /// `t * num / den` for times, exact when the reduced result fits in i64.
    /// Three i64 factors can exceed i128: then it rounds twice instead of overflowing.
    pub fn scaled(t: Time, num: Time, den: Time) -> Time {
        let (n, o1) = (t.value as i128 * num.value as i128).overflowing_mul(den.timescale as i128);
        let (d, o2) = (t.timescale as i128 * num.timescale as i128).overflowing_mul(den.value as i128);
        if !o1 && !o2 {
            return Time::reducing(n, d);
        }
        let tn = Time::reducing(t.value as i128 * num.value as i128, t.timescale as i128 * num.timescale as i128);
        Time::reducing(tn.value as i128 * den.timescale as i128, tn.timescale as i128 * den.value as i128)
    }

    /// `t * n / d` for integers, exact when the reduced result fits in i64. Panics when `d == 0`.
    pub fn scaled_int(t: Time, n: i64, d: i64) -> Time {
        assert!(d != 0, "denominator must not be zero");
        Time::reducing(t.value as i128 * n as i128, t.timescale as i128 * d as i128)
    }

    /// Half of `self`, never overflows.
    pub fn halved(self) -> Time {
        Time::scaled_int(self, 1, 2)
    }

    /// `n / d` from a wide intermediate. Reduced by the gcd; when that still does not fit in i64, the closest fraction
    /// with i64 numerator and denominator (continued fraction); beyond the i64 seconds range clamped to
    /// ±`i64::MAX` seconds. A negative `d` flips the sign. Panics when `d == 0`.
    pub fn reducing(n: i128, d: i128) -> Time {
        assert!(d != 0, "timescale must not be zero");
        let negative = (n < 0) != (d < 0);
        let (mut a, mut b) = (n.unsigned_abs(), d.unsigned_abs());
        let g = gcd128(a, b);
        if g > 1 {
            a /= g;
            b /= g;
        }
        let limit = i64::MAX as u128;
        // Callers pass v <= limit, so the conversion is exact.
        let signed = |v: u128| {
            let v = i64::try_from(v).unwrap_or(i64::MAX);
            if negative { -v } else { v }
        };
        let fit = |v: u128| i64::try_from(v).unwrap_or(i64::MAX);
        if a <= limit && b <= limit {
            return Time::new(signed(a), fit(b));
        }
        // Whole seconds beyond i64: clamp.
        if a / b >= limit {
            return Time::new(signed(limit), 1);
        }
        // Best approximation p/q of a/b with p, q <= i64::MAX: walk the convergents, finish with the best semiconvergent.
        let (mut p0, mut q0, mut p1, mut q1): (u128, u128, u128, u128) = (0, 1, 1, 0);
        let (mut x, mut y) = (a, b);
        while y != 0 {
            let t = x / y;
            let tp = (limit - p0).checked_div(p1).unwrap_or(t);
            let tq = (limit - q0).checked_div(q1).unwrap_or(t);
            let t_max = tp.min(tq);
            if t > t_max {
                // Semiconvergent with t_max, if it is closer than the last convergent.
                if t_max > 0 {
                    let ps = t_max * p1 + p0;
                    let qs = t_max * q1 + q0;
                    let target = a as f64 / b as f64;
                    if (ps as f64 / qs as f64 - target).abs() < (p1 as f64 / q1 as f64 - target).abs() {
                        (p1, q1) = (ps, qs);
                    }
                }
                break;
            }
            (p0, q0, p1, q1) = (p1, q1, t * p1 + p0, t * q1 + q0);
            (x, y) = (y, x - t * y);
        }
        if q1 == 0 {
            return Time::new(signed(limit), 1);
        }
        Time::new(signed(p1), fit(q1))
    }
}

/// Overflow-safe: the exact sum when it fits in i64 (after reducing), otherwise the nearest representable time.
impl Add for Time {
    type Output = Time;
    fn add(self, b: Time) -> Time {
        let a = self;
        if a.timescale == b.timescale
            && let Some(s) = a.value.checked_add(b.value)
        {
            return Time::new(s, a.timescale);
        }
        let g = gcd(a.timescale as u64, b.timescale as u64) as i128;
        let (sa, sb) = (a.timescale as i128, b.timescale as i128);
        let scale = sa / g * sb;
        Time::reducing(a.value as i128 * (sb / g) + b.value as i128 * (sa / g), scale)
    }
}

/// `-i64::MIN` maps to `i64::MAX`.
impl Neg for Time {
    type Output = Time;
    fn neg(self) -> Time {
        if self.value == i64::MIN {
            Time::new(i64::MAX, self.timescale)
        } else {
            Time::new(-self.value, self.timescale)
        }
    }
}

impl Sub for Time {
    type Output = Time;
    fn sub(self, b: Time) -> Time {
        self + (-b)
    }
}

impl Mul<i64> for Time {
    type Output = Time;
    fn mul(self, n: i64) -> Time {
        match self.value.checked_mul(n) {
            Some(p) => Time::new(p, self.timescale),
            None => Time::reducing(self.value as i128 * n as i128, self.timescale as i128),
        }
    }
}

impl AddAssign for Time {
    fn add_assign(&mut self, b: Time) {
        *self = *self + b;
    }
}

impl SubAssign for Time {
    fn sub_assign(&mut self, b: Time) {
        *self = *self - b;
    }
}

impl Ord for Time {
    fn cmp(&self, b: &Time) -> Ordering {
        (self.value as i128 * b.timescale as i128).cmp(&(b.value as i128 * self.timescale as i128))
    }
}

impl PartialOrd for Time {
    fn partial_cmp(&self, b: &Time) -> Option<Ordering> {
        Some(self.cmp(b))
    }
}

/// Half-open span `start ..< start + duration`; the duration is never negative.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "TimeRangeFields")]
pub struct TimeRange {
    /// First instant inside the range.
    pub start: Time,
    /// Length, at least zero.
    pub duration: Time,
}

/// The coded shape of `TimeRange`; a negative duration is a corrupt file.
#[derive(Deserialize)]
struct TimeRangeFields {
    start: Time,
    duration: Time,
}

impl TryFrom<TimeRangeFields> for TimeRange {
    type Error = &'static str;
    fn try_from(f: TimeRangeFields) -> Result<Self, &'static str> {
        if f.duration.is_negative() {
            return Err("negative duration");
        }
        Ok(TimeRange { start: f.start, duration: f.duration })
    }
}

impl TimeRange {
    /// Panics on a negative duration (a Swift precondition).
    pub fn new(start: Time, duration: Time) -> TimeRange {
        assert!(!duration.is_negative(), "negative duration");
        TimeRange { start, duration }
    }

    /// From `start` to `end`; panics when `end < start`.
    pub fn from_end(start: Time, end: Time) -> TimeRange {
        TimeRange::new(start, end - start)
    }

    /// `start + duration`.
    pub fn end(&self) -> Time {
        self.start + self.duration
    }

    /// No length.
    pub fn is_empty(&self) -> bool {
        self.duration <= Time::ZERO
    }

    /// `start` is inside, `end` is not.
    pub fn contains(&self, t: Time) -> bool {
        t >= self.start && t < self.end()
    }

    /// Shares at least one instant with `o`.
    pub fn overlaps(&self, o: &TimeRange) -> bool {
        self.start < o.end() && o.start < self.end()
    }

    /// The shared part, `None` when it is empty.
    pub fn intersection(&self, o: &TimeRange) -> Option<TimeRange> {
        let s = self.start.max(o.start);
        let e = self.end().min(o.end());
        if s < e { Some(TimeRange::from_end(s, e)) } else { None }
    }
}

const fn gcd(mut a: u64, mut b: u64) -> u64 {
    while b != 0 {
        (a, b) = (b, a % b);
    }
    a
}

fn gcd128(mut a: u128, mut b: u128) -> u128 {
    while b != 0 {
        (a, b) = (b, a % b);
    }
    a
}

fn floor_div(n: i128, d: i128) -> i128 {
    let q = n / d;
    if n % d != 0 && (n < 0) != (d < 0) { q - 1 } else { q }
}

fn clamp_i64(v: i128) -> i64 {
    v.clamp(i64::MIN as i128, i64::MAX as i128) as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(v: i64, s: i64) -> Time {
        Time::new(v, s)
    }

    #[test]
    fn new_reduces_and_keeps_sign() {
        assert_eq!((t(2, 4).value(), t(2, 4).timescale()), (1, 2));
        assert_eq!((t(0, 7).value(), t(0, 7).timescale()), (0, 1));
        assert_eq!((t(-6, 9).value(), t(-6, 9).timescale()), (-2, 3));
        let m = t(i64::MIN, 2);
        assert_eq!((m.value(), m.timescale()), (i64::MIN / 2, 1));
        assert_eq!(t(1, 2), t(2, 4));
        assert!(t(1, 3) < t(1, 2));
    }

    #[test]
    #[should_panic(expected = "timescale must be positive")]
    fn new_rejects_zero_timescale() {
        let _ = t(1, 0);
    }

    #[test]
    fn neg_of_min_is_max() {
        assert_eq!(-t(i64::MIN, 1), t(i64::MAX, 1));
        assert_eq!(-t(3, 4), t(-3, 4));
        assert_eq!(t(1, 1) - t(i64::MIN, 1), t(i64::MAX, 1) + t(1, 1));
    }

    #[test]
    fn add_overflow_uses_wide_sum_and_clamps() {
        assert_eq!(t(i64::MAX, 1) + t(1, 1), t(i64::MAX, 1));
        assert_eq!(t(i64::MIN + 1, 1) + t(-5, 1), t(-i64::MAX, 1));
        assert_eq!(t(1, 3) + t(1, 6), t(1, 2));
        // Coprime large timescales: the exact sum does not fit, the result is the closest fraction.
        let s = t(1, i64::MAX) + t(1, i64::MAX - 1);
        assert!(s >= t(2, i64::MAX) && s <= t(2, i64::MAX - 1));
    }

    #[test]
    fn mul_overflow_goes_through_reducing() {
        assert_eq!(t(3, 2) * 4, t(6, 1));
        assert_eq!(t(i64::MAX, 7) * 2, Time::reducing(2 * i64::MAX as i128, 7));
        assert_eq!(t(i64::MAX, 1) * i64::MAX, t(i64::MAX, 1));
        assert_eq!(t(-1, 1) * i64::MIN, t(i64::MAX, 1));
    }

    #[test]
    fn reducing_fits_clamps_and_approximates() {
        assert_eq!(Time::reducing(6, -4), t(-3, 2));
        assert_eq!(Time::reducing(i128::MAX, 1), t(i64::MAX, 1));
        assert_eq!(Time::reducing(-(1i128 << 100), 3), t(-i64::MAX, 1));
        // 10^30 / (10^30 + 1) does not fit: the closest fraction with i64 parts.
        let r = Time::reducing(10i128.pow(30), 10i128.pow(30) + 1);
        assert!(r <= t(1, 1) && (r.value() as f64 / r.timescale() as f64 - 1.0).abs() < 1e-18);
    }

    #[test]
    fn frame_math_floors_snaps_and_ceils() {
        let fd = t(1001, 30000);
        assert_eq!(t(1, 1).frame_index(fd), 29);
        assert_eq!(t(-1, 1000).frame_index(t(1, 30)), -1);
        assert_eq!(t(5, 1).frame_index(Time::ZERO), 0);
        assert_eq!(t(1, 60).snapped(t(1, 30)), t(1, 30));
        assert_eq!(t(1, 61).snapped(t(1, 30)), Time::ZERO);
        assert_eq!(t(1, 61).ceiled(t(1, 30)), t(1, 30));
        assert_eq!(t(-1, 61).ceiled(t(1, 30)), Time::ZERO);
        // The frame count clamps to i64 before the multiply.
        assert_eq!(t(i64::MAX, 1).ceiled(t(1, i64::MAX)), t(1, 1));
    }

    #[test]
    fn scaled_rounds_twice_only_on_overflow() {
        assert_eq!(Time::scaled(t(3, 1), t(2, 1), t(3, 1)), t(2, 1));
        // Exact while the three-factor products fit in i128.
        assert_eq!(
            Time::scaled(t(i64::MAX, 3), t(i64::MAX, 5), t(i64::MAX, 7)),
            Time::reducing(i64::MAX as i128 * 7, 15)
        );
        // MAX^3 overflows i128: two rounding steps, here both clamp.
        assert_eq!(Time::scaled(t(i64::MAX, 3), t(i64::MAX, 5), t(1, i64::MAX)), t(i64::MAX, 1));
        assert_eq!(Time::scaled_int(t(1, 1), 1, 3), t(1, 3));
        assert_eq!(t(i64::MAX, 1).halved(), Time::reducing(i64::MAX as i128, 2));
    }

    #[test]
    fn ranges_are_half_open() {
        let a = TimeRange::new(t(1, 1), t(2, 1));
        assert!(a.contains(t(1, 1)) && !a.contains(t(3, 1)));
        assert!(!a.overlaps(&TimeRange::new(t(3, 1), t(1, 1))));
        assert_eq!(a.intersection(&TimeRange::from_end(t(2, 1), t(9, 1))), Some(TimeRange::from_end(t(2, 1), t(3, 1))));
        assert!(TimeRange::new(t(1, 1), Time::ZERO).is_empty());
    }
}
