// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: DateStamp.swift (the effect keys and catalog spec live in `sq-core-model`)
//
// Date Stamp: camcorder-style date/time burned into the picture. The effect only holds the look values; the text is drawn by
// the one text renderer: `video_layers` adds a second layer next to the clip with a `GeneratorRef::date_stamp` payload (the
// already formatted text, corner, pixel size, color), and the playback and export layer builders turn that into a text layer.
// No second text system, no compositor change: the cost is one extra text layer whose raster changes at most once per second.
//
// Wiring: `LayerHooks::date_stamp` takes `&date_stamp_request` as it is.

use serde::{Deserialize, Serialize};
use sq_core_effects::evaluation::{LayerGroup, LayerRequest};
use sq_core_model::{Clip, ClipEffect, ClipTransform, GeneratorRef, SequenceFormat};
use sq_core_time::{Id, Time};

/// The Date Stamp layer's generator kind.
pub const DATE_STAMP_KIND: &str = "dateStamp";

/// Which corner the stamp sits in. Coded as its integer raw value.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(try_from = "i64", into = "i64")]
pub enum DateStampCorner {
    /// Bottom right (default).
    BottomRight,
    /// Bottom left.
    BottomLeft,
    /// Top right.
    TopRight,
    /// Top left.
    TopLeft,
}

impl From<DateStampCorner> for i64 {
    fn from(c: DateStampCorner) -> i64 {
        match c {
            DateStampCorner::BottomRight => 0,
            DateStampCorner::BottomLeft => 1,
            DateStampCorner::TopRight => 2,
            DateStampCorner::TopLeft => 3,
        }
    }
}

impl TryFrom<i64> for DateStampCorner {
    type Error = String;
    fn try_from(v: i64) -> Result<Self, String> {
        match v {
            0 => Ok(DateStampCorner::BottomRight),
            1 => Ok(DateStampCorner::BottomLeft),
            2 => Ok(DateStampCorner::TopRight),
            3 => Ok(DateStampCorner::TopLeft),
            _ => Err(format!("unknown corner {v}")),
        }
    }
}

/// What the text layer of a Date Stamp shows and where. Pixel values are in canvas pixels of the sequence it is drawn in.
/// Fields are in the key order Swift writes the payload in (sorted).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DateStampSpec {
    /// Blue, 0...1.
    pub blue: f64,
    /// Canvas height.
    pub canvas_height: i64,
    /// Canvas width.
    pub canvas_width: i64,
    /// Corner.
    pub corner: DateStampCorner,
    /// Font size in canvas pixels.
    pub font_size: f64,
    /// Green, 0...1.
    pub green: f64,
    /// Red, 0...1.
    pub red: f64,
    /// The formatted text.
    pub text: String,
}

impl DateStampSpec {
    /// The decoded spec; `None` for another kind or an undecodable payload.
    pub fn decode(r: &GeneratorRef) -> Option<DateStampSpec> {
        if r.kind == DATE_STAMP_KIND { serde_json::from_slice(&r.payload).ok() } else { None }
    }

    /// The Date Stamp layer: payload is the JSON spec.
    pub fn generator(&self) -> GeneratorRef {
        GeneratorRef {
            kind: DATE_STAMP_KIND.to_string(),
            payload: serde_json::to_vec(self).unwrap_or_default(),
            payload_version: 1,
        }
    }
}

/// Format titles and constants of the stamp.
pub struct DateStamp;

impl DateStamp {
    /// Margin from the canvas edge, as a share of the canvas height (the title-safe look of a camcorder).
    pub const MARGIN_SHARE: f64 = 0.06;
    const MONTHS: [&'static str; 12] =
        ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"];

    /// Days since 1970-01-01 of a proleptic Gregorian date.
    fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
        let y = if m <= 2 { y - 1 } else { y };
        let era = y.div_euclid(400);
        let yoe = y.rem_euclid(400);
        let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        era * 146_097 + doe - 719_468
    }

    /// (year, month, day) of a day count since 1970-01-01.
    fn civil_from_days(z: i64) -> (i64, i64, i64) {
        let z = z + 719_468;
        let era = z.div_euclid(146_097);
        let doe = z.rem_euclid(146_097);
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let d = doy - (153 * mp + 2) / 5 + 1;
        let m = if mp < 10 { mp + 3 } else { mp - 9 };
        (yoe + era * 400 + i64::from(m <= 2), m, d)
    }

    /// The stamped moment, in seconds since 1970-01-01 00:00 UTC: the start (clip-local 0) plus whole `elapsed_seconds`. A
    /// date the calendar cannot build (31 Feb) rolls over, as a camcorder clock would.
    pub fn moment(year: i64, month: i64, day: i64, hour: i64, minute: i64, elapsed_seconds: i64) -> i64 {
        let m0 = month.saturating_sub(1);
        let y = year.saturating_add(m0.div_euclid(12));
        let first = Self::days_from_civil(y, m0.rem_euclid(12) + 1, 1);
        let days = first.saturating_add(day.saturating_sub(1));
        days.saturating_mul(86_400)
            .saturating_add(hour.saturating_mul(3600))
            .saturating_add(minute.saturating_mul(60))
            .saturating_add(elapsed_seconds)
    }

    /// The text of format index `format` (see the catalog's format titles). Fixed English month names and 24 h / 12 h forms,
    /// never locale dependent, so a project renders the same on every machine.
    pub fn text(format: i64, at: i64) -> String {
        let (y, mo, d) = Self::civil_from_days(at.div_euclid(86_400));
        let secs = at.rem_euclid(86_400);
        let (h, mi, s) = (secs / 3600, secs % 3600 / 60, secs % 60);
        let p2 = |v: i64| if v < 10 { format!("0{v}") } else { v.to_string() };
        let h12 = if h % 12 == 0 { 12 } else { h % 12 };
        let ampm = if h < 12 { "AM" } else { "PM" };
        let date_en = format!("{} {d} {y}", Self::MONTHS[((mo - 1) % 12) as usize]);
        let date_de = format!("{}.{}.{y}", p2(d), p2(mo));
        let time12 = format!("{h12}:{} {ampm}", p2(mi));
        let time24 = format!("{}:{}:{}", p2(h), p2(mi), p2(s));
        match format {
            1 => date_de,
            2 => format!("{}/{}/{y}", p2(mo), p2(d)),
            3 => time12,
            4 => time24,
            5 => format!("{date_en}  {time12}"),
            6 => format!("{date_de}  {time24}"),
            _ => date_en,
        }
    }

    /// Blink: on for the first half of every second.
    pub fn blink_visible(local_seconds: f64) -> bool {
        local_seconds - local_seconds.floor() < 0.5
    }
}

/// `Int(x.rounded())` for a parameter value; non-finite counts as 0 (Swift would trap).
fn rounded_int(x: f64) -> i64 {
    if x.is_finite() { x.round() as i64 } else { 0 }
}

/// The Date Stamp layer for `c` at timeline time `t` (the last enabled Date Stamp wins), or `None`. It sits on the clip's
/// transform, so it moves and scales with the picture, and follows the clip's opacity. Has the signature of
/// `LayerHooks::date_stamp`.
pub fn date_stamp_request(
    c: &Clip,
    t: Time,
    canvas: &SequenceFormat,
    transform: &ClipTransform,
    groups: &[LayerGroup],
    track: Id,
    in_transition: bool,
) -> Option<LayerRequest> {
    let e = c.effects.iter().rev().find(|e| e.kind == ClipEffect::DATE_STAMP_KIND && e.enabled)?;
    let local = t - c.start;
    let secs = local.value() as f64 / local.timescale().max(1) as f64;
    let v = |key: &str| e.scalar(key, local);
    if e.flag(ClipEffect::STAMP_BLINK_KEY, local) && !DateStamp::blink_visible(secs) {
        return None;
    }
    let date = DateStamp::moment(
        rounded_int(v(ClipEffect::STAMP_YEAR_KEY)),
        rounded_int(v(ClipEffect::STAMP_MONTH_KEY)),
        rounded_int(v(ClipEffect::STAMP_DAY_KEY)),
        rounded_int(v(ClipEffect::STAMP_HOUR_KEY)),
        rounded_int(v(ClipEffect::STAMP_MINUTE_KEY)),
        (secs.floor() as i64).max(0),
    );
    let col = e.color(ClipEffect::STAMP_COLOR_KEY, local);
    let spec = DateStampSpec {
        blue: col.blue,
        canvas_height: canvas.height,
        canvas_width: canvas.width,
        corner: DateStampCorner::try_from(rounded_int(v(ClipEffect::STAMP_POSITION_KEY)))
            .unwrap_or(DateStampCorner::BottomRight),
        font_size: (v(ClipEffect::STAMP_SIZE_KEY) / 100.0 * canvas.height as f64).max(4.0),
        green: col.green,
        red: col.red,
        text: DateStamp::text(rounded_int(v(ClipEffect::STAMP_FORMAT_KEY)), date),
    };
    // The effect's own id names the layer: stable per effect, never a timeline clip.
    let mut r = LayerRequest::new(e.id, e.id, track, local);
    r.transform = *transform;
    r.groups = groups.to_vec();
    r.generator = Some(spec.generator());
    r.local_time = local;
    r.in_transition = in_transition;
    r.clip_duration = Some(c.duration());
    Some(r)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graphics_create::test_support::s;
    use sq_core_effects::effects_editing::ClipEffectsEditingExt as _;
    use sq_core_effects::evaluation::{LayerHooks, TimelineEvaluation as _};
    use sq_core_model::{EffectCatalog, Timeline, Track, TrackKind};
    use sq_core_time::{SequentialIds, TimeRange};

    fn clip(params: &[(&str, f64)], enabled: bool) -> Clip {
        let mut ids = SequentialIds::default();
        let mut c = Clip::new(
            Id::from_u128(900),
            "v",
            Id::from_u128(901),
            TrackKind::Video,
            TimeRange::new(s(10), s(10)),
            s(2),
        );
        let id = c.add_effect(ClipEffect::DATE_STAMP_KIND, None, &mut ids).unwrap();
        for (k, v) in params {
            c.set_parameter(id, k, *v);
        }
        c.effects[0].enabled = enabled;
        c
    }

    fn layers(c: &Clip, at: Time) -> Vec<LayerRequest> {
        let mut ids = SequentialIds::default();
        let mut tr = Track::new(Id::from_u128(902), TrackKind::Video);
        tr.overwrite(c.clone(), &mut ids).unwrap();
        let tl = Timeline::new(Id::from_u128(903), "t", SequenceFormat::new(Time::new(1, 25)), vec![tr]);
        fn none(_: Id) -> Option<&'static Timeline> {
            None
        }
        let hooks = LayerHooks { date_stamp: &date_stamp_request, ..LayerHooks::plain() };
        tl.video_layers(at, &none, &hooks, None)
    }

    #[test]
    fn formats() {
        let d = DateStamp::moment(1998, 7, 14, 22, 32, 5);
        let texts: Vec<String> = (0..7).map(|f| DateStamp::text(f, d)).collect();
        assert_eq!(
            texts,
            [
                "JUL 14 1998",
                "14.07.1998",
                "07/14/1998",
                "10:32 PM",
                "22:32:05",
                "JUL 14 1998  10:32 PM",
                "14.07.1998  22:32:05"
            ]
        );
        let noon = DateStamp::moment(2001, 1, 1, 0, 5, 0);
        assert_eq!(DateStamp::text(3, noon), "12:05 AM");
    }

    #[test]
    fn clock_advances_and_rolls_over() {
        let d = DateStamp::moment(1999, 12, 31, 23, 59, 75);
        assert_eq!(DateStamp::text(6, d), "01.01.2000  00:00:15");
        // 31 Feb rolls into March; a leap day exists.
        assert_eq!(DateStamp::text(1, DateStamp::moment(2001, 2, 31, 0, 0, 0)), "03.03.2001");
        assert_eq!(DateStamp::text(1, DateStamp::moment(2000, 2, 29, 12, 0, 0)), "29.02.2000");
        assert_eq!(DateStamp::moment(1970, 1, 1, 0, 0, 0), 0);
    }

    #[test]
    fn effect_adds_a_text_layer_on_the_clip_transform() {
        let c = clip(&[(ClipEffect::STAMP_FORMAT_KEY, 4.0), (ClipEffect::STAMP_SIZE_KEY, 5.0)], true);
        let ls = layers(&c, s(2) + Time::new(7, 2)); // 3.5 s into the clip
        assert_eq!(ls.len(), 2);
        assert!(
            ls[0].generator.is_none() && ls[1].generator.as_ref().map(|g| g.kind.as_str()) == Some(DATE_STAMP_KIND)
        );
        let spec = DateStampSpec::decode(ls[1].generator.as_ref().unwrap()).unwrap();
        assert_eq!(spec.text, "22:32:03");
        assert_eq!(spec.corner, DateStampCorner::BottomRight);
        let height = SequenceFormat::new(Time::new(1, 25)).height as f64;
        assert!((spec.font_size - 0.05 * height).abs() < 1e-9);
        assert!(ls[1].clip_duration == Some(c.duration()) && ls[1].transform == ls[0].transform);
    }

    #[test]
    fn the_stamp_sits_on_the_whole_clip_not_only_at_an_edge() {
        // The clip runs 2 s ... 12 s on the timeline. An effect acts over the whole clip (catalog walk in sq-core-effects).
        let c = clip(&[], true);
        for at in [s(2), s(7), s(12) - Time::new(1, 25)] {
            assert_eq!(layers(&c, at).len(), 2, "{at:?}");
        }
    }

    #[test]
    fn blink_hides_the_second_half_second() {
        let c = clip(&[(ClipEffect::STAMP_BLINK_KEY, 1.0)], true);
        assert_eq!(layers(&c, s(2) + Time::new(1, 4)).len(), 2);
        assert_eq!(layers(&c, s(2) + Time::new(3, 4)).len(), 1);
    }

    #[test]
    fn disabled_or_absent_adds_nothing() {
        let c = clip(&[], false);
        assert_eq!(layers(&c, s(3)).len(), 1);
    }

    #[test]
    fn spec_round_trips_through_the_generator_ref() {
        let spec = DateStampSpec {
            blue: 0.1,
            canvas_height: 1080,
            canvas_width: 1920,
            corner: DateStampCorner::TopLeft,
            font_size: 48.0,
            green: 0.55,
            red: 1.0,
            text: "x".to_string(),
        };
        let r = spec.generator();
        assert_eq!(DateStampSpec::decode(&r), Some(spec));
        let json = String::from_utf8(r.payload.clone()).unwrap_or_default();
        assert!(json.contains("\"corner\":3"), "{json}");
        let other = GeneratorRef { kind: "text".to_string(), ..r };
        assert_eq!(DateStampSpec::decode(&other), None);
    }

    #[test]
    fn catalog_defaults_in_range() {
        let spec = EffectCatalog::spec_for(ClipEffect::DATE_STAMP_KIND).unwrap();
        for p in spec.params.iter().filter(|p| p.kind.is_scalar()) {
            assert!(p.range.contains(&p.default_value), "{}", p.key);
        }
    }
}
