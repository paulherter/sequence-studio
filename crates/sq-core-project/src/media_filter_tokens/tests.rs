// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MediaFilterGroupingTests.swift (the filter tests; grouping and SmartBin tests belong to other modules)

use super::*;
use sq_core_model::MediaFingerprint;
use sq_core_time::Id;

const UTC: FixedOffsetCalendar = FixedOffsetCalendar { offset_seconds: 0 };

fn date(y: i64, m: i64, d: i64, h: i64) -> Timestamp {
    Timestamp::from_unix_seconds((days_from_civil(y, m, d) * 86_400 + h * 3600) as f64)
}

fn token(key: MediaFilterKey, value: &str) -> MediaFilterToken {
    MediaFilterToken { key, value: value.into() }
}

fn media(
    name: &str,
    camera: Option<&str>,
    created: Option<Timestamp>,
    fps: i64,
    label: Option<LabelColor>,
) -> MediaRef {
    let info = serde_json::json!({
        "duration": {"value": 10, "timescale": 1},
        "video": {"width": 1920, "height": 1080, "codec": "avc1", "bitDepth": 8, "chroma": "4:2:0",
                  "nominalFrameDuration": {"value": 1, "timescale": fps}, "isVariableFrameRate": false},
        "cameraModel": camera,
    });
    let mut m = MediaRef::new(Id::from_u128(1), name, &format!("/x/{name}.mov"), MediaFingerprint::new(1));
    let mut info: sq_core_model::MediaInfo = serde_json::from_value(info).unwrap();
    info.created = created;
    m.info = Some(info);
    m.label = label;
    m
}

#[test]
fn parses_tokens_and_keeps_free_text() {
    let q = MediaFilterQuery::parse("window cam:FX3 unused fps:24 label:rose day:today kind:video");
    assert_eq!(q.text, "window");
    let texts: Vec<String> = q.tokens.iter().map(MediaFilterTokenExt::text).collect();
    assert_eq!(texts, ["cam:FX3", "unused", "fps:24", "label:rose", "day:today", "kind:video"]);
    assert_eq!(MediaFilterQuery::parse("cam:\"Sony FX3\"").tokens, [token(MediaFilterKey::Camera, "Sony FX3")]);
    let sony = token(MediaFilterKey::Camera, "Sony FX3");
    assert_eq!(MediaFilterToken::parse(&sony.text()), Some(sony));
}

#[test]
fn invalid_tokens_stay_text() {
    let q = MediaFilterQuery::parse("cam: fps:abc label:nope day:soon kind:x foo:bar");
    assert!(q.tokens.is_empty());
    assert_eq!(q.text, "cam: fps:abc label:nope day:soon kind:x foo:bar");
}

#[test]
fn extract_waits_for_the_space() {
    let typing = MediaFilterToken::extract("cam:FX3", false);
    assert!(typing.1.is_empty() && typing.0 == "cam:FX3");
    let done = MediaFilterToken::extract("win cam:FX3 ", false);
    assert_eq!(done.1, [token(MediaFilterKey::Camera, "FX3")]);
    assert_eq!(done.0, "win ");
    assert_eq!(MediaFilterToken::extract("cam:FX3", true).1.len(), 1);
}

#[test]
fn filters_by_each_token() {
    let a = media("A", Some("ILME-FX3"), Some(date(2026, 10, 19, 9)), 24, Some(LabelColor::Rose));
    let b = media("B", Some("iPhone 15 Pro"), Some(date(2026, 10, 20, 9)), 30, None);
    let now = date(2026, 10, 20, 15);
    let ok = |s: &str, m: &MediaRef, used: bool| MediaFilterQuery::parse(s).matches(m, used, now, &UTC);
    assert!(ok("cam:fx3", &a, false) && !ok("cam:fx3", &b, false));
    assert!(ok("fps:24", &a, false) && !ok("fps:24", &b, false) && ok("fps:30", &b, false));
    assert!(ok("day:yesterday", &a, false) && !ok("day:yesterday", &b, false) && ok("day:today", &b, false));
    assert!(ok("day:2026-10-19", &a, false) && !ok("day:2026-10-19", &b, false));
    assert!(ok("label:rose", &a, false) && ok("label:pink", &a, false) && !ok("label:rose", &b, false));
    assert!(ok("unused", &a, false) && !ok("unused", &a, true) && ok("used", &a, true));
    assert!(ok("cam:fx3 fps:24 A", &a, false) && !ok("cam:fx3 fps:30", &a, false));
    assert!(ok("cam:fx3 cam:iphone", &a, false) && ok("cam:fx3 cam:iphone", &b, false)); // same kind = alternatives
    assert!(!ok("zzz", &a, false));
}

#[test]
fn fractional_frame_rate() {
    let mut m = media("N", None, None, 25, None);
    if let Some(v) = m.info.as_mut().and_then(|i| i.video.as_mut()) {
        v.nominal_frame_duration = sq_core_time::Time::new(1001, 24000);
    }
    let any = |t: &MediaFilterToken| t.matches(&m, false, date(2026, 1, 1, 0), &UTC);
    assert!(any(&token(MediaFilterKey::Fps, "23.976")));
    assert!(any(&token(MediaFilterKey::Fps, "24")));
    assert_eq!(MediaFilterQuery::values(MediaFilterKey::Fps, &[m]), ["23.976"]);
}

#[test]
fn titles_and_values() {
    assert_eq!(token(MediaFilterKey::Day, "yesterday").title(), "Day: Yesterday");
    assert_eq!(token(MediaFilterKey::Label, "rose").title(), "Label: Pink");
    assert_eq!(token(MediaFilterKey::Fps, "24").title(), "24 fps");
    assert_eq!(token(MediaFilterKey::Usage, "unused").title(), "Unused");
    let a = media("a", Some("FX3"), None, 25, Some(LabelColor::Rose));
    assert_eq!(MediaFilterQuery::values(MediaFilterKey::Fps, std::slice::from_ref(&a)), ["25"]);
    assert_eq!(MediaFilterQuery::values(MediaFilterKey::Label, &[a]), ["rose"]);
}

#[test]
fn local_calendar_matches_the_machines_zone() {
    let cal = LocalCalendar;
    let now = Timestamp::from_unix_seconds(1_800_000_000.0);
    let start = cal
        .date_from(
            sq_core_time::local_time::local_civil(now).year,
            sq_core_time::local_time::local_civil(now).month,
            sq_core_time::local_time::local_civil(now).day,
        )
        .unwrap();
    assert!(cal.is_same_day(start, now));
    let next = cal.add_days(start, 1).unwrap();
    assert!(!cal.is_same_day(next, now));
    assert!(cal.is_same_day(cal.add_days(next, -1).unwrap(), now));
    assert!(cal.date_from(2027, 13, 1).is_none());
}
