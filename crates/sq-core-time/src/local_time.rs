// SPDX-License-Identifier: GPL-3.0-or-later
//! The machine's local time zone for the places where Swift used `Calendar.current` / `DateFormatter`: civil date and
//! clock time of an instant, local midnight, calendar day steps (daylight saving included, the zone database is chrono's).

use crate::Timestamp;
use chrono::{Datelike, Duration, Local, LocalResult, NaiveDate, TimeZone, Timelike};

/// Date and clock time of an instant in one zone.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Civil {
    pub year: i64,
    pub month: i64,
    pub day: i64,
    pub hour: i64,
    pub minute: i64,
    pub second: i64,
}

fn civil_of<Z: TimeZone>(zone: &Z, t: Timestamp) -> Civil {
    let secs = t.unix_seconds().floor() as i64;
    let d = zone.timestamp_opt(secs, 0).single().map(|d| d.naive_local()).unwrap_or_default();
    Civil {
        year: i64::from(d.year()),
        month: i64::from(d.month()),
        day: i64::from(d.day()),
        hour: i64::from(d.hour()),
        minute: i64::from(d.minute()),
        second: i64::from(d.second()),
    }
}

fn midnight_in<Z: TimeZone>(zone: &Z, year: i64, month: i64, day: i64) -> Option<Timestamp> {
    let date =
        NaiveDate::from_ymd_opt(i32::try_from(year).ok()?, u32::try_from(month).ok()?, u32::try_from(day).ok()?)?;
    let naive = date.and_hms_opt(0, 0, 0)?;
    let dt = match zone.from_local_datetime(&naive) {
        LocalResult::Single(d) => d,
        LocalResult::Ambiguous(first, _) => first,
        // Midnight skipped by a spring-forward gap: the first valid instant of that day.
        LocalResult::None => zone.from_local_datetime(&(naive + Duration::hours(1))).earliest()?,
    };
    Some(Timestamp::from_unix_seconds(dt.timestamp() as f64))
}

fn add_days_in<Z: TimeZone>(zone: &Z, t: Timestamp, days: i64) -> Option<Timestamp> {
    let secs = t.unix_seconds().floor() as i64;
    let local = zone.timestamp_opt(secs, 0).single()?.naive_local();
    let moved = local.checked_add_signed(Duration::days(days))?;
    let dt = zone
        .from_local_datetime(&moved)
        .earliest()
        .or_else(|| zone.from_local_datetime(&(moved + Duration::hours(1))).earliest())?;
    Some(Timestamp::from_unix_seconds(dt.timestamp() as f64 + t.unix_seconds().fract()))
}

/// Civil date and time of `t` in the machine's zone.
pub fn local_civil(t: Timestamp) -> Civil {
    civil_of(&Local, t)
}

/// Start of the local day `year-month-day`; `None` for an impossible date.
pub fn local_midnight(year: i64, month: i64, day: i64) -> Option<Timestamp> {
    midnight_in(&Local, year, month, day)
}

/// `t` moved by whole local calendar days (the clock time stays, a daylight-saving change does not shift it).
pub fn add_local_days(t: Timestamp, days: i64) -> Option<Timestamp> {
    add_days_in(&Local, t, days)
}

/// `local_civil` for a fixed-offset zone (seconds east of UTC); for tests and fixed-zone callers.
pub fn civil_at_offset(t: Timestamp, offset_seconds: i32) -> Civil {
    chrono::FixedOffset::east_opt(offset_seconds).map_or_else(|| civil_of(&chrono::Utc, t), |z| civil_of(&z, t))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::FixedOffset;

    /// A zone with daylight saving needs a database; chrono-tz is not a dependency, so the shift is checked on `Local`
    /// only for consistency and on a fixed zone for the arithmetic.
    #[test]
    fn fixed_zone_civil_and_midnight() {
        let z = FixedOffset::east_opt(2 * 3600).unwrap();
        let t = Timestamp::from_unix_seconds(1_800_000_000.0); // 2027-01-15 08:00:00 UTC
        let c = civil_of(&z, t);
        assert_eq!((c.year, c.month, c.day, c.hour), (2027, 1, 15, 10));
        let m = midnight_in(&z, 2027, 1, 15).unwrap();
        assert_eq!(m.unix_seconds(), 1_799_971_200.0 - 2.0 * 3600.0);
        assert!(midnight_in(&z, 2027, 13, 1).is_none());
        assert_eq!(add_days_in(&z, t, 1).unwrap().unix_seconds(), t.unix_seconds() + 86_400.0);
    }

    #[test]
    fn local_midnight_round_trips() {
        let t = Timestamp::from_unix_seconds(1_800_000_000.0);
        let c = local_civil(t);
        let m = local_midnight(c.year, c.month, c.day).unwrap();
        assert!(m <= t && t.unix_seconds() - m.unix_seconds() < 25.0 * 3600.0);
        let next = add_local_days(m, 1).unwrap();
        let n = local_civil(next);
        assert_eq!((n.hour, n.minute), (0, 0));
    }
}
