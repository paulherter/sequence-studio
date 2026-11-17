// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ClipSpeed.swift

use serde::{Deserialize, Serialize};
use sq_core_time::Time;
use std::cmp::Ordering;

/// Constant clip speed as an exact ratio `num / den` (never a float): 1/1 = 100 %, 2/1 = 200 %, 3333/10000 = 33.33 %.
/// Clamped to the range 1 % ... 10000 % (`MINIMUM` ... `MAXIMUM`). Direction is not part of the speed:
/// `Clip::reversed` flips it (shown as "-100 %").
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "ClipSpeedWire")]
pub struct ClipSpeed {
    num: i64,
    den: i64,
}

/// `ClipSpeed` as stored; reading rejects a non-positive part.
#[derive(Deserialize)]
struct ClipSpeedWire {
    num: i64,
    den: i64,
}

impl TryFrom<ClipSpeedWire> for ClipSpeed {
    type Error = String;

    fn try_from(w: ClipSpeedWire) -> Result<Self, Self::Error> {
        if w.num > 0 && w.den > 0 {
            Ok(ClipSpeed::new(w.num, w.den))
        } else {
            Err(format!("speed must be positive, got {}/{}", w.num, w.den))
        }
    }
}

fn gcd(mut a: i128, mut b: i128) -> i128 {
    while b != 0 {
        (a, b) = (b, a % b);
    }
    a
}

impl ClipSpeed {
    /// 100 %.
    pub const NORMAL: ClipSpeed = ClipSpeed { num: 1, den: 1 };
    /// 1 %.
    pub const MINIMUM: ClipSpeed = ClipSpeed { num: 1, den: 100 };
    /// 10000 %.
    pub const MAXIMUM: ClipSpeed = ClipSpeed { num: 100, den: 1 };

    /// Numerator.
    pub fn num(self) -> i64 {
        self.num
    }

    /// Denominator.
    pub fn den(self) -> i64 {
        self.den
    }

    /// Reduces the ratio and clamps it to `MINIMUM ..= MAXIMUM`. Non-positive input gives `NORMAL`.
    pub fn new(num: i64, den: i64) -> ClipSpeed {
        if num <= 0 || den <= 0 {
            return ClipSpeed::NORMAL;
        }
        let a = gcd(num as i128, den as i128) as i64;
        let (n, d) = (num / a, den / a);
        // n/d < 1/100  <=>  100 n < d ;  n/d > 100  <=>  n > 100 d
        if (n as i128) * 100 < d as i128 {
            ClipSpeed::MINIMUM
        } else if n as i128 > (d as i128) * 100 {
            ClipSpeed::MAXIMUM
        } else {
            ClipSpeed { num: n, den: d }
        }
    }

    /// From a typed percentage; rounded to 1/100 of a percent (33.33 -> 3333/10000).
    pub fn from_percent(percent: f64) -> ClipSpeed {
        if percent.is_nan() || percent <= 0.0 {
            return ClipSpeed::NORMAL;
        }
        // Out of range (and +infinity) clamps before the integer conversion; a tiny positive value is the slowest speed.
        if percent >= 10_000.0 {
            return ClipSpeed::MAXIMUM;
        }
        if percent < 1.0 {
            return ClipSpeed::MINIMUM;
        }
        ClipSpeed::new((percent * 100.0).round() as i64, 10_000)
    }

    /// The speed that plays source span `source` in timeline time `timeline` (`source / timeline`), overflow-safe: the
    /// ratio is formed in `i128` and reduced; a ratio that still does not fit is rounded (then clamped as usual).
    pub fn from_source_over(source: Time, timeline: Time) -> ClipSpeed {
        let mut n = source.value() as i128 * timeline.timescale() as i128;
        let mut d = source.timescale() as i128 * timeline.value() as i128;
        if n <= 0 || d <= 0 {
            return ClipSpeed::NORMAL;
        }
        let a = gcd(n, d);
        n /= a;
        d /= a;
        if i64::try_from(n).is_err() || i64::try_from(d).is_err() {
            let bits = 128 - n.max(d).leading_zeros() as i32;
            let k = bits - 62;
            let half = 1i128 << (k - 1);
            n = ((n + half) >> k).max(1);
            d = ((d + half) >> k).max(1);
        }
        // Both fit in 62 bits after the shift, or already fit in 63.
        ClipSpeed::new(n as i64, d as i64)
    }

    /// For display only.
    pub fn percent(self) -> f64 {
        self.num as f64 / self.den as f64 * 100.0
    }

    /// 100 %.
    pub fn is_normal(self) -> bool {
        self.num == self.den
    }

    /// `t * speed`: source time spanned by timeline time `t`.
    pub fn scale(self, t: Time) -> Time {
        Time::reducing(t.value() as i128 * self.num as i128, t.timescale() as i128 * self.den as i128)
    }

    /// `t / speed`: timeline time needed to play source time `t`.
    pub fn unscale(self, t: Time) -> Time {
        Time::reducing(t.value() as i128 * self.den as i128, t.timescale() as i128 * self.num as i128)
    }
}

impl PartialOrd for ClipSpeed {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for ClipSpeed {
    fn cmp(&self, other: &Self) -> Ordering {
        (self.num as i128 * other.den as i128).cmp(&(other.num as i128 * self.den as i128))
    }
}

#[cfg(test)]
impl ClipSpeed {
    /// An already reduced, in-range speed.
    pub(crate) fn from_parts_for_tests(num: i64, den: i64) -> ClipSpeed {
        ClipSpeed { num, den }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_reduces_and_clamps() {
        assert_eq!((ClipSpeed::new(4, 2).num(), ClipSpeed::new(4, 2).den()), (2, 1));
        assert_eq!(ClipSpeed::new(1, 1000), ClipSpeed::MINIMUM);
        assert_eq!(ClipSpeed::new(1000, 1), ClipSpeed::MAXIMUM);
        assert_eq!(ClipSpeed::new(0, 5), ClipSpeed::NORMAL);
        assert_eq!(ClipSpeed::new(-3, 5), ClipSpeed::NORMAL);
        assert_eq!(ClipSpeed::new(i64::MAX, 1), ClipSpeed::MAXIMUM);
    }

    #[test]
    fn percent_rounds_to_hundredths_and_clamps() {
        let s = ClipSpeed::from_percent(33.33);
        assert_eq!((s.num(), s.den()), (3333, 10_000));
        assert_eq!(ClipSpeed::from_percent(f64::NAN), ClipSpeed::NORMAL);
        assert_eq!(ClipSpeed::from_percent(-5.0), ClipSpeed::NORMAL);
        assert_eq!(ClipSpeed::from_percent(0.0001), ClipSpeed::MINIMUM);
        assert_eq!(ClipSpeed::from_percent(f64::INFINITY), ClipSpeed::MAXIMUM);
        assert_eq!(ClipSpeed::from_percent(10_000.0), ClipSpeed::MAXIMUM);
        assert_eq!(ClipSpeed::from_percent(100.0), ClipSpeed::NORMAL);
    }

    #[test]
    fn scale_and_unscale_are_inverse_and_exact() {
        let s = ClipSpeed::from_percent(200.0);
        assert_eq!(s.scale(Time::new(1, 1)), Time::new(2, 1));
        assert_eq!(s.unscale(Time::new(2, 1)), Time::new(1, 1));
        let third = ClipSpeed::new(1, 3);
        assert_eq!(third.unscale(Time::new(1, 30)), Time::new(1, 10));
    }

    #[test]
    fn ordering_compares_the_ratios() {
        assert!(ClipSpeed::new(1, 2) < ClipSpeed::NORMAL);
        assert!(ClipSpeed::new(3, 2) > ClipSpeed::NORMAL);
        assert_eq!(ClipSpeed::new(2, 4).cmp(&ClipSpeed::new(1, 2)), Ordering::Equal);
    }

    #[test]
    fn source_over_timeline_is_the_ratio() {
        let s = ClipSpeed::from_source_over(Time::new(2, 1), Time::new(1, 1));
        assert_eq!(s, ClipSpeed::new(2, 1));
        assert_eq!(ClipSpeed::from_source_over(Time::ZERO, Time::new(1, 1)), ClipSpeed::NORMAL);
        assert_eq!(ClipSpeed::from_source_over(Time::new(1, 1), Time::ZERO), ClipSpeed::NORMAL);
        // A ratio that does not fit in 64 bits is rounded, then clamped.
        let huge = ClipSpeed::from_source_over(Time::new(i64::MAX, 7), Time::new(1, i64::MAX));
        assert_eq!(huge, ClipSpeed::MAXIMUM);
    }

    #[test]
    fn decoding_rejects_non_positive_parts_and_normalizes() {
        assert!(serde_json::from_str::<ClipSpeed>(r#"{"num":0,"den":1}"#).is_err());
        assert!(serde_json::from_str::<ClipSpeed>(r#"{"num":1,"den":-1}"#).is_err());
        let s: ClipSpeed = serde_json::from_str(r#"{"num":4,"den":2}"#).unwrap();
        assert_eq!(serde_json::to_string(&s).unwrap(), r#"{"num":2,"den":1}"#);
    }
}
