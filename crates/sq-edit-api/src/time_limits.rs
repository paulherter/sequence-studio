// Swift: TimeLimits.swift
//! Bounds for agent-supplied times, checked on the raw integers before a `Time` exists.

use serde::{Deserialize, Deserializer};
use sq_core_time::{Time, TimeRange};

/// Bounds for agent-supplied times. `Time` addition scales both values to the common timescale in `i64`; with the agent's
/// timescale <= 2^20 and |time| <= 2^22 s, the agent value is <= 2^42, so adding it to a project time (timescales up to
/// ~2^17 in practice) stays far below 2^63.
pub struct TimeLimits;

impl TimeLimits {
    /// Largest accepted timescale.
    pub const MAX_TIMESCALE: i64 = 1 << 20;
    /// Largest accepted magnitude in seconds.
    pub const MAX_SECONDS: i64 = 1 << 22;

    /// Whether `value / timescale` is inside the bounds.
    pub fn is_valid(value: i64, timescale: i64) -> bool {
        if timescale <= 0 || timescale > Self::MAX_TIMESCALE || value == i64::MIN {
            return false;
        }
        value.unsigned_abs() <= timescale.unsigned_abs() * Self::MAX_SECONDS.unsigned_abs()
    }

    /// Whether `t` is inside the bounds.
    pub fn is_valid_time(t: Time) -> bool {
        Self::is_valid(t.value(), t.timescale())
    }

    pub(crate) fn message() -> String {
        format!("time out of range: timescale 1...{}, at most {} s either way", Self::MAX_TIMESCALE, Self::MAX_SECONDS)
    }
}

#[derive(Deserialize)]
struct WireTimeFields {
    value: i64,
    timescale: i64,
}

/// A time on the wire: `{"value", "timescale"}`, or a bare number of seconds (39.9 is exactly 399/10 s, to the microsecond).
#[derive(Deserialize)]
#[serde(untagged)]
enum WireTimeForm {
    Fields(WireTimeFields),
    Seconds(f64),
}

fn gcd(a: i64, b: i64) -> i64 {
    if b == 0 { a.abs() } else { gcd(b, a % b) }
}

/// `{"value", "timescale"}` validated against `TimeLimits` before `Time` is built.
pub(crate) struct WireTime {
    pub time: Time,
}

impl<'de> Deserialize<'de> for WireTime {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let f = match WireTimeForm::deserialize(d) {
            Ok(WireTimeForm::Fields(f)) => f,
            Ok(WireTimeForm::Seconds(secs)) => {
                if !secs.is_finite() || secs.abs() > TimeLimits::MAX_SECONDS as f64 {
                    return Err(serde::de::Error::custom(TimeLimits::message()));
                }
                let micros = (secs * 1_000_000.0).round() as i64;
                let g = gcd(micros, 1_000_000).max(1);
                WireTimeFields { value: micros / g, timescale: 1_000_000 / g }
            }
            Err(_) => {
                return Err(serde::de::Error::custom(
                    "a time is {\"value\": n, \"timescale\": n} or a number of seconds",
                ));
            }
        };
        if !TimeLimits::is_valid(f.value, f.timescale) {
            return Err(serde::de::Error::custom(TimeLimits::message()));
        }
        Ok(WireTime { time: Time::new(f.value, f.timescale) })
    }
}

#[derive(Deserialize)]
struct WireRangeFields {
    start: WireTime,
    duration: WireTime,
}

/// `{"start", "duration"}` of two `WireTime`s; a negative duration is refused.
pub(crate) struct WireRange {
    pub range: TimeRange,
}

impl<'de> Deserialize<'de> for WireRange {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let f = WireRangeFields::deserialize(d)?;
        if f.duration.time.is_negative() {
            return Err(serde::de::Error::custom("negative duration"));
        }
        Ok(WireRange { range: TimeRange::new(f.start.time, f.duration.time) })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn time_limits() {
        assert!(TimeLimits::is_valid(1, 25));
        assert!(!TimeLimits::is_valid(1, 0));
        assert!(!TimeLimits::is_valid(1, TimeLimits::MAX_TIMESCALE + 1));
        assert!(!TimeLimits::is_valid(i64::MIN, 1));
        assert!(TimeLimits::is_valid(-TimeLimits::MAX_SECONDS, 1));
        assert!(!TimeLimits::is_valid(TimeLimits::MAX_SECONDS + 1, 1));
    }

    #[test]
    fn wire_time_and_range_validate_before_building() {
        let ok: Result<WireTime, _> = serde_json::from_str(r#"{"value":1,"timescale":25}"#);
        assert_eq!(ok.map(|w| w.time).ok(), Some(Time::new(1, 25)));
        assert!(serde_json::from_str::<WireTime>(r#"{"value":1,"timescale":0}"#).is_err());
        // Bare seconds are the exact decimal fraction.
        let secs = |t: &str| serde_json::from_str::<WireTime>(t).map(|w| w.time).ok();
        assert_eq!(secs("39.9"), Some(Time::new(399, 10)));
        assert_eq!(secs("-0.3"), Some(Time::new(-3, 10)));
        assert_eq!(secs("2"), Some(Time::new(2, 1)));
        assert_eq!(secs("0.04"), Some(Time::new(1, 25)));
        assert!(secs("1e12").is_none() && secs("\"x\"").is_none());
        let neg = r#"{"start":{"value":0,"timescale":1},"duration":{"value":-1,"timescale":1}}"#;
        assert!(serde_json::from_str::<WireRange>(neg).is_err());
    }
}
