// Swift: MediaGrouping.swift (`Calendar` and `DateFormatter` become the `GroupingCalendar` trait; `MediaRef.shootDate`
// is a private copy until `media_filter_tokens` exports it)
//! "Sorted by" view of the Project panel: the same media grouped by shooting day, camera or kind. Display only.

use std::cmp::Ordering;
use std::collections::BTreeMap;

use sq_core_model::{MediaKind, MediaRef};
use sq_core_time::text::standard_compare;
use sq_core_time::{Id, Time, Timestamp};

/// The calendar the day grouping reads: local date parts and the localized title of a day ("Mon, Oct 19").
pub trait GroupingCalendar {
    /// Year, month, day of `t` in the calendar's time zone.
    fn year_month_day(&self, t: Timestamp) -> (i64, i64, i64);
    /// Localized day title (template `EEEMMMd`).
    fn day_title(&self, t: Timestamp) -> String;
    /// The same clock time one calendar day earlier (a daylight-saving change does not move it past midnight).
    fn previous_day(&self, t: Timestamp) -> Timestamp {
        Timestamp::from_unix_seconds(t.unix_seconds() - 86_400.0)
    }
}

/// How the Project panel groups media.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MediaGrouping {
    Folders,
    Day,
    Camera,
    Kind,
}

/// One group of the "sorted by" view.
#[derive(Clone, Debug, PartialEq)]
pub struct MediaGroup {
    pub id: String,
    pub title: String,
    pub items: Vec<Id>,
    pub duration: Time,
}

impl MediaGrouping {
    /// Every grouping in menu order.
    pub const ALL: [MediaGrouping; 4] =
        [MediaGrouping::Folders, MediaGrouping::Day, MediaGrouping::Camera, MediaGrouping::Kind];

    /// Menu title.
    pub fn title(self) -> &'static str {
        match self {
            MediaGrouping::Folders => "Folders",
            MediaGrouping::Day => "Day",
            MediaGrouping::Camera => "Camera",
            MediaGrouping::Kind => "Kind",
        }
    }

    /// Groups in display order, items inside by shooting time (then name). Empty for `Folders`.
    pub fn groups(self, media: &[MediaRef], calendar: &dyn GroupingCalendar) -> Vec<MediaGroup> {
        if self == MediaGrouping::Folders {
            return Vec::new();
        }
        let mut order: Vec<String> = Vec::new();
        let mut titles: BTreeMap<String, String> = BTreeMap::new();
        let mut buckets: BTreeMap<String, Vec<&MediaRef>> = BTreeMap::new();
        for m in media {
            let (key, title) = self.bucket(m, calendar);
            if !buckets.contains_key(&key) {
                order.push(key.clone());
                titles.insert(key.clone(), title);
            }
            buckets.entry(key).or_default().push(m);
        }
        // Keys sort as text (yyyy-MM-dd, camera name, kind rank); the "unknown" bucket (prefix "~") goes last.
        order.sort_by(|a, b| match (a.starts_with('~'), b.starts_with('~')) {
            (false, true) => Ordering::Less,
            (true, false) => Ordering::Greater,
            _ => standard_compare(a, b),
        });
        order
            .into_iter()
            .map(|key| {
                let mut items = buckets.remove(&key).unwrap_or_default();
                items.sort_by(|a, b| match (shoot_date(a), shoot_date(b)) {
                    (Some(x), Some(y)) if x != y => x.partial_cmp(&y).unwrap_or(Ordering::Equal),
                    (Some(_), None) => Ordering::Less,
                    (None, Some(_)) => Ordering::Greater,
                    _ => standard_compare(&a.name, &b.name),
                });
                let mut total = Time::ZERO;
                for m in &items {
                    if let Some(d) = m.duration {
                        total += d;
                    }
                }
                MediaGroup {
                    title: titles.get(&key).cloned().unwrap_or_else(|| key.clone()),
                    id: key,
                    items: items.iter().map(|m| m.id).collect(),
                    duration: total,
                }
            })
            .collect()
    }

    fn bucket(self, m: &MediaRef, cal: &dyn GroupingCalendar) -> (String, String) {
        match self {
            MediaGrouping::Folders => (String::new(), String::new()),
            MediaGrouping::Day => {
                let Some(d) = shoot_date(m) else { return ("~".to_string(), "No Date".to_string()) };
                let (y, mo, da) = cal.year_month_day(d);
                (format!("{y:04}-{mo:02}-{da:02}"), cal.day_title(d))
            }
            MediaGrouping::Camera => {
                let camera = m
                    .info
                    .as_ref()
                    .and_then(|i| i.camera_model.as_deref())
                    .map(trim_whitespaces)
                    .filter(|c| !c.is_empty());
                match camera {
                    Some(c) => (c.to_lowercase(), c.to_string()),
                    None => ("~".to_string(), "Unknown Camera".to_string()),
                }
            }
            MediaGrouping::Kind => match m.kind() {
                MediaKind::Video | MediaKind::VideoAudio => ("1".to_string(), "Video".to_string()),
                MediaKind::Audio => ("2".to_string(), "Audio".to_string()),
                MediaKind::Image => ("3".to_string(), "Photo".to_string()),
                MediaKind::Unknown => ("4".to_string(), "Other".to_string()),
            },
        }
    }
}

/// When the clip was shot: the file's creation date, else its modification date.
fn shoot_date(m: &MediaRef) -> Option<Timestamp> {
    m.info.as_ref().and_then(|i| i.created).or(m.fingerprint.modified)
}

/// `.whitespaces`: spaces and tabs, not line breaks.
fn trim_whitespaces(s: &str) -> &str {
    s.trim_matches(|c: char| {
        c.is_whitespace() && !matches!(c, '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}')
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{MediaFingerprint, MediaInfo};

    /// UTC calendar over unix days.
    struct Utc;

    impl GroupingCalendar for Utc {
        fn year_month_day(&self, t: Timestamp) -> (i64, i64, i64) {
            let z = (t.unix_seconds() / 86400.0).floor() as i64 + 719_468;
            let era = z.div_euclid(146_097);
            let doe = z.rem_euclid(146_097);
            let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
            let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
            let mp = (5 * doy + 2) / 153;
            let d = doy - (153 * mp + 2) / 5 + 1;
            let m = if mp < 10 { mp + 3 } else { mp - 9 };
            (yoe + era * 400 + i64::from(m <= 2), m, d)
        }

        fn day_title(&self, t: Timestamp) -> String {
            let (y, m, d) = self.year_month_day(t);
            format!("{y}-{m}-{d}")
        }
    }

    fn date(y: i64, m: i64, d: i64, h: i64) -> Timestamp {
        // days from civil
        let y2 = if m <= 2 { y - 1 } else { y };
        let era = y2.div_euclid(400);
        let yoe = y2.rem_euclid(400);
        let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        let days = era * 146_097 + doe - 719_468;
        Timestamp::from_unix_seconds((days * 86400 + h * 3600) as f64)
    }

    fn media(n: u128, name: &str, camera: Option<&str>, created: Option<Timestamp>) -> MediaRef {
        let mut m = MediaRef::new(Id::from_u128(n), name, &format!("/x/{name}.mov"), MediaFingerprint::new(1));
        m.duration = Some(Time::new(10, 1));
        let j = serde_json::json!({
            "duration": {"value": 10, "timescale": 1},
            "video": {"width": 1920, "height": 1080, "codec": "h264", "bitDepth": 8, "chroma": "420",
                      "nominalFrameDuration": {"value": 1, "timescale": 30}, "isVariableFrameRate": false}
        });
        let mut info: MediaInfo = serde_json::from_value(j).expect("info");
        info.camera_model = camera.map(str::to_string);
        info.created = created;
        m.info = Some(info);
        m
    }

    #[test]
    fn groups_by_day_in_shooting_order_across_cameras() {
        let a = media(1, "late", Some("FX3"), Some(date(2026, 10, 19, 14)));
        let b = media(2, "early", Some("iPhone"), Some(date(2026, 10, 19, 9)));
        let c = media(3, "sun", Some("FX3"), Some(date(2026, 10, 20, 0)));
        let mut d = media(4, "none", None, None);
        d.fingerprint.modified = None;
        let g = MediaGrouping::Day.groups(&[c, a.clone(), d, b.clone()], &Utc);
        assert_eq!(g.iter().map(|x| x.id.as_str()).collect::<Vec<_>>(), ["2026-10-19", "2026-10-20", "~"]);
        assert_eq!(g[0].items, [b.id, a.id]);
        assert_eq!(g[0].duration, Time::new(20, 1));
        assert_eq!(g[2].title, "No Date");
    }

    #[test]
    fn groups_by_camera_and_kind() {
        let a = media(1, "a", Some("FX3"), None);
        let b = media(2, "b", Some("fx3 "), None);
        let c = media(3, "c", Some("Alpha"), None);
        let d = media(4, "d", None, None);
        let g = MediaGrouping::Camera.groups(&[a.clone(), b, c, d], &Utc);
        assert_eq!(g.iter().map(|x| x.title.as_str()).collect::<Vec<_>>(), ["Alpha", "FX3", "Unknown Camera"]);
        assert_eq!(g[1].items.len(), 2);
        let mut photo = media(5, "p", None, None);
        photo.path = "/x/p.png".to_string();
        if let Some(i) = photo.info.as_mut() {
            i.video = None;
            i.is_still = true;
        }
        let kinds = MediaGrouping::Kind.groups(&[photo, a.clone()], &Utc);
        assert_eq!(kinds.iter().map(|x| x.title.as_str()).collect::<Vec<_>>(), ["Video", "Photo"]);
        assert!(MediaGrouping::Folders.groups(&[a], &Utc).is_empty());
    }
}
