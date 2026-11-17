// SPDX-License-Identifier: GPL-3.0-or-later
//! Swift `Date` in model data. Logic never reads the clock: it takes `now: Timestamp`.

use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// Seconds between 1970-01-01 and Swift's reference date 2001-01-01 (UTC).
const REFERENCE_FROM_UNIX: f64 = 978_307_200.0;

/// An instant, stored like Swift `Date`: seconds since 2001-01-01 00:00 UTC as `f64`.
/// Plain serde uses Swift's default `Date` coding (that number); files with `.iso8601` use `#[serde(with = "iso8601")]`.
#[derive(Clone, Copy, Debug, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Timestamp {
    since_reference: f64,
}

impl Timestamp {
    /// Swift `Date(timeIntervalSinceReferenceDate:)`.
    pub const fn from_reference_seconds(s: f64) -> Timestamp {
        Timestamp { since_reference: s }
    }

    /// Swift `Date(timeIntervalSince1970:)`.
    pub fn from_unix_seconds(s: f64) -> Timestamp {
        Timestamp { since_reference: s - REFERENCE_FROM_UNIX }
    }

    /// Swift `timeIntervalSinceReferenceDate`.
    pub const fn reference_seconds(self) -> f64 {
        self.since_reference
    }

    /// Swift `timeIntervalSince1970`.
    pub fn unix_seconds(self) -> f64 {
        self.since_reference + REFERENCE_FROM_UNIX
    }
}

/// `JSONEncoder.dateEncodingStrategy = .iso8601`: `"2026-11-05T12:00:00Z"`, whole seconds, UTC.
/// Use as `#[serde(with = "sq_core_time::timestamp::iso8601")]`; `iso8601::option` for `Option<Timestamp>`.
pub mod iso8601 {
    use super::*;

    /// Writes the UTC string; fractions of a second are cut off.
    // shortcut: floor of the fraction is not yet checked against Foundation's formatter, check with the file oracle.
    pub fn serialize<S: Serializer>(t: &Timestamp, s: S) -> Result<S::Ok, S::Error> {
        s.collect_str(&format(*t))
    }

    /// Reads `YYYY-MM-DDTHH:MM:SS` with `Z` or a `+HH:MM`/`-HH:MM` offset.
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Timestamp, D::Error> {
        let s = <std::borrow::Cow<'de, str>>::deserialize(d)?;
        parse(&s).ok_or_else(|| serde::de::Error::custom(format!("expected ISO 8601 date, got {s}")))
    }

    /// The same for optional dates (omitted when `None`, pair with `skip_serializing_if`).
    pub mod option {
        use super::*;

        /// See `iso8601::serialize`.
        pub fn serialize<S: Serializer>(t: &Option<Timestamp>, s: S) -> Result<S::Ok, S::Error> {
            match t {
                Some(t) => s.collect_str(&format(*t)),
                None => s.serialize_none(),
            }
        }

        /// See `iso8601::deserialize`.
        pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Timestamp>, D::Error> {
            let s = <Option<std::borrow::Cow<'de, str>>>::deserialize(d)?;
            s.map(|s| parse(&s).ok_or_else(|| serde::de::Error::custom(format!("expected ISO 8601 date, got {s}"))))
                .transpose()
        }
    }

    fn format(t: Timestamp) -> String {
        let secs = t.unix_seconds().floor() as i64;
        let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
        let (y, m, d) = civil_from_days(days);
        format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, rem / 60 % 60, rem % 60)
    }

    fn parse(s: &str) -> Option<Timestamp> {
        let b = s.as_bytes();
        let num = |r: std::ops::Range<usize>| -> Option<i64> {
            let part = s.get(r)?;
            if part.bytes().all(|c| c.is_ascii_digit()) { part.parse().ok() } else { None }
        };
        if b.len() < 20 || b[4] != b'-' || b[7] != b'-' || b[10] != b'T' || b[13] != b':' || b[16] != b':' {
            return None;
        }
        let (y, mo, d, h, mi, se) = (num(0..4)?, num(5..7)?, num(8..10)?, num(11..13)?, num(14..16)?, num(17..19)?);
        if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || se > 60 {
            return None;
        }
        let offset = match &s[19..] {
            "Z" => 0,
            o if o.len() == 6 && (o.starts_with('+') || o.starts_with('-')) && o.get(3..4) == Some(":") => {
                let v = num(20..22)? * 3600 + num(23..25)? * 60;
                if o.starts_with('-') { -v } else { v }
            }
            _ => return None,
        };
        let secs = days_from_civil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + se - offset;
        Some(Timestamp::from_unix_seconds(secs as f64))
    }

    // Howard Hinnant's civil calendar algorithms (public domain), proleptic Gregorian.
    fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
        let y = if m <= 2 { y - 1 } else { y };
        let era = y.div_euclid(400);
        let yoe = y - era * 400;
        let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        era * 146_097 + doe - 719_468
    }

    fn civil_from_days(z: i64) -> (i64, i64, i64) {
        let z = z + 719_468;
        let era = z.div_euclid(146_097);
        let doe = z - era * 146_097;
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let d = doy - (153 * mp + 2) / 5 + 1;
        let m = if mp < 10 { mp + 3 } else { mp - 9 };
        (yoe + era * 400 + i64::from(m <= 2), m, d)
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn round_trips_utc_and_offsets() {
            let t = parse("2026-11-05T12:00:00Z").unwrap();
            assert_eq!(t.unix_seconds(), 1_793_880_000.0);
            assert_eq!(format(t), "2026-11-05T12:00:00Z");
            assert_eq!(parse("2026-11-05T13:00:00+01:00"), Some(t));
            assert_eq!(format(Timestamp::from_unix_seconds(-0.5)), "1969-12-31T23:59:59Z");
            assert_eq!(format(Timestamp::from_reference_seconds(0.0)), "2001-01-01T00:00:00Z");
            assert_eq!(parse("2026-11-05T12:00:00.5Z"), None);
        }
    }
}
