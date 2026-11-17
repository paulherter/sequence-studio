//! The calendars of the Project panel's day filters and grouping: the machine's zone for the app, UTC for tests.

use sq_core_project::media_filter_tokens::Calendar;
use sq_core_project::media_grouping::GroupingCalendar;
use sq_core_time::Timestamp;

/// UTC; the app supplies a calendar with the user's time zone instead.
#[derive(Clone, Copy, Debug, Default)]
pub struct UtcCalendar;

const DAY: f64 = 86_400.0;
const MONTHS: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const WEEKDAYS: [&str; 7] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

/// Days since 1970-01-01 of a civil date.
pub(crate) fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y2 = if m <= 2 { y - 1 } else { y };
    let era = y2.div_euclid(400);
    let yoe = y2.rem_euclid(400);
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468
}

/// Civil date of a day count since 1970-01-01.
pub(crate) fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

/// 0 = Monday ... 6 = Sunday (1970-01-01 was a Thursday).
pub(crate) fn weekday_name(days: i64) -> &'static str {
    WEEKDAYS[(days + 3).rem_euclid(7) as usize]
}

impl GroupingCalendar for UtcCalendar {
    fn year_month_day(&self, t: Timestamp) -> (i64, i64, i64) {
        civil_from_days((t.unix_seconds() / DAY).floor() as i64)
    }

    fn day_title(&self, t: Timestamp) -> String {
        let days = (t.unix_seconds() / DAY).floor() as i64;
        let (_, m, d) = civil_from_days(days);
        format!("{}, {} {d}", weekday_name(days), MONTHS[(m - 1).clamp(0, 11) as usize])
    }
}

impl Calendar for UtcCalendar {
    fn add_days(&self, date: Timestamp, days: i64) -> Option<Timestamp> {
        Some(Timestamp::from_unix_seconds(date.unix_seconds() + days as f64 * DAY))
    }

    fn date_from(&self, year: i64, month: i64, day: i64) -> Option<Timestamp> {
        if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
            return None;
        }
        let days = days_from_civil(year, month, day);
        (civil_from_days(days) == (year, month, day)).then(|| Timestamp::from_unix_seconds(days as f64 * DAY))
    }

    fn is_same_day(&self, a: Timestamp, b: Timestamp) -> bool {
        self.year_month_day(a) == self.year_month_day(b)
    }
}

/// The machine's time zone with daylight saving (Swift `Calendar.current`), the calendar the app passes.
#[derive(Clone, Copy, Debug, Default)]
pub struct LocalCalendar;

impl GroupingCalendar for LocalCalendar {
    fn year_month_day(&self, t: Timestamp) -> (i64, i64, i64) {
        let c = sq_core_time::local_time::local_civil(t);
        (c.year, c.month, c.day)
    }

    fn day_title(&self, t: Timestamp) -> String {
        let c = sq_core_time::local_time::local_civil(t);
        sq_uikit::local_format::day_title_of(&c, &sq_uikit::localization::SQL10n::current_language())
    }

    fn previous_day(&self, t: Timestamp) -> Timestamp {
        sq_core_time::local_time::add_local_days(t, -1)
            .unwrap_or_else(|| Timestamp::from_unix_seconds(t.unix_seconds() - DAY))
    }
}

impl Calendar for LocalCalendar {
    fn add_days(&self, date: Timestamp, days: i64) -> Option<Timestamp> {
        sq_core_project::media_filter_tokens::LocalCalendar.add_days(date, days)
    }

    fn date_from(&self, year: i64, month: i64, day: i64) -> Option<Timestamp> {
        sq_core_project::media_filter_tokens::LocalCalendar.date_from(year, month, day)
    }

    fn is_same_day(&self, a: Timestamp, b: Timestamp) -> bool {
        self.year_month_day(a) == self.year_month_day(b)
    }
}
