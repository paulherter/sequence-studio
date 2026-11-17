// Swift: AutosaveVersionLabel.swift
//! The menu title of one autosave version (File > Autosave Versions): the time it was written, how long ago that was, and
//! "Latest" on the newest one, so the user can tell the versions apart without reading clock times.

use crate::localization::SQL10n;
use sq_core_time::Timestamp;

/// Title of an autosave version. `absolute` is the write time formatted by the shell in the user's locale and time zone
/// (Swift `Date.FormatStyle(date: .abbreviated, time: .standard)`).
pub fn title(absolute: &str, date: Timestamp, now: Timestamp, is_newest: bool) -> String {
    let s = (now.unix_seconds() - date.unix_seconds()).trunc().max(0.0) as i64;
    let ago = crate::local_format::ago(s, &SQL10n::current_language());
    let base = format!("{absolute} · {ago}");
    if is_newest { format!("{base} · {}", SQL10n::string("Latest")) } else { base }
}

/// A named checkpoint: its name and the time it was saved (`absolute`, formatted like `title`'s with `time: .shortened`).
pub fn checkpoint_title(name: &str, absolute: &str) -> String {
    format!("{name} · {absolute}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn now() -> Timestamp {
        Timestamp::from_unix_seconds(1_800_000_000.0)
    }

    fn before(seconds: f64) -> Timestamp {
        Timestamp::from_unix_seconds(1_800_000_000.0 - seconds)
    }

    #[test]
    fn shows_how_long_ago_and_marks_the_newest() {
        let old = title("Jan 15, 2027", before(720.0), now(), false);
        assert!(old.contains("12 min. ago"));
        assert!(!old.contains("Latest"));
        let newest = title("Jan 15, 2027", before(30.0), now(), true);
        assert!(newest.ends_with("Latest"));
        assert!(newest.contains("30 sec. ago"));
    }

    #[test]
    fn different_versions_get_different_titles() {
        let a = title("t", before(300.0), now(), false);
        let b = title("t", before(900.0), now(), false);
        assert_ne!(a, b);
        assert_eq!(title("t", before(-5.0), now(), false), "t · 0 sec. ago");
        assert_eq!(checkpoint_title("Rough cut", "10:00"), "Rough cut · 10:00");
    }
}
