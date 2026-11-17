// SPDX-License-Identifier: GPL-3.0-or-later
//! Facts typed into the Project panel's search field (`cam:FX3`, `fps:24`, `day:today`, `unused`).
// Swift: MediaFilterTokens.swift (the saved `MediaFilterToken` lives in `sq-core-model`)
//
// `day:` needs a calendar: Swift passes `Calendar.current`; here a `Calendar` trait is injected and
// `FixedOffsetCalendar` is the one implementation.
// `LocalCalendar` is the machine's zone with daylight saving; `FixedOffsetCalendar` stays for tests and fixed zones.

use crate::recovery::days_from_civil;
use sq_core_model::{LabelColor, MediaFilterKey, MediaFilterToken, MediaKind, MediaRef};
use sq_core_time::Timestamp;
use sq_core_time::text::{ci_contains, standard_compare};
use std::collections::BTreeSet;

/// The calendar days `day:` filters by.
pub trait Calendar {
    /// `date` moved by `days` calendar days.
    fn add_days(&self, date: Timestamp, days: i64) -> Option<Timestamp>;
    /// Start of the given day; `None` for an impossible month.
    fn date_from(&self, year: i64, month: i64, day: i64) -> Option<Timestamp>;
    /// Both instants fall on the same calendar day.
    fn is_same_day(&self, a: Timestamp, b: Timestamp) -> bool;
}

/// The machine's time zone, daylight saving included (Swift `Calendar.current`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LocalCalendar;

impl Calendar for LocalCalendar {
    fn add_days(&self, date: Timestamp, days: i64) -> Option<Timestamp> {
        sq_core_time::local_time::add_local_days(date, days)
    }

    fn date_from(&self, year: i64, month: i64, day: i64) -> Option<Timestamp> {
        sq_core_time::local_time::local_midnight(year, month, day)
    }

    fn is_same_day(&self, a: Timestamp, b: Timestamp) -> bool {
        let (x, y) = (sq_core_time::local_time::local_civil(a), sq_core_time::local_time::local_civil(b));
        (x.year, x.month, x.day) == (y.year, y.month, y.day)
    }
}

/// A calendar at a fixed offset from UTC.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct FixedOffsetCalendar {
    /// Seconds east of UTC.
    pub offset_seconds: i64,
}

impl FixedOffsetCalendar {
    fn day_number(&self, t: Timestamp) -> i64 {
        ((t.unix_seconds() + self.offset_seconds as f64) / 86_400.0).floor() as i64
    }
}

impl Calendar for FixedOffsetCalendar {
    fn add_days(&self, date: Timestamp, days: i64) -> Option<Timestamp> {
        Some(Timestamp::from_unix_seconds(date.unix_seconds() + days as f64 * 86_400.0))
    }

    fn date_from(&self, year: i64, month: i64, day: i64) -> Option<Timestamp> {
        if !(1..=12).contains(&month) {
            return None;
        }
        let seconds = days_from_civil(year, month, day) * 86_400 - self.offset_seconds;
        Some(Timestamp::from_unix_seconds(seconds as f64))
    }

    fn is_same_day(&self, a: Timestamp, b: Timestamp) -> bool {
        self.day_number(a) == self.day_number(b)
    }
}

fn key_raw(key: MediaFilterKey) -> &'static str {
    match key {
        MediaFilterKey::Camera => "cam",
        MediaFilterKey::Fps => "fps",
        MediaFilterKey::Day => "day",
        MediaFilterKey::Label => "label",
        MediaFilterKey::Kind => "kind",
        MediaFilterKey::Usage => "usage",
    }
}

fn key_from_raw(raw: &str) -> Option<MediaFilterKey> {
    [
        MediaFilterKey::Camera,
        MediaFilterKey::Fps,
        MediaFilterKey::Day,
        MediaFilterKey::Label,
        MediaFilterKey::Kind,
        MediaFilterKey::Usage,
    ]
    .into_iter()
    .find(|k| key_raw(*k) == raw)
}

/// Foundation's `capitalized`: the first letter of each word upper case, the rest lower case.
fn capitalized(s: &str) -> String {
    let mut out = String::new();
    let mut word_start = true;
    for c in s.chars() {
        if word_start {
            out.extend(c.to_uppercase());
        } else {
            out.extend(c.to_lowercase());
        }
        word_start = !c.is_alphanumeric();
    }
    out
}

/// Swift `trimmingCharacters(in: .whitespaces)`: spaces and tabs, not line breaks.
pub(crate) fn trim_blanks(s: &str) -> &str {
    s.trim_matches(|c: char| {
        c == '\t' || (c.is_whitespace() && !c.is_control() && !matches!(c, '\u{2028}' | '\u{2029}'))
    })
}

fn label_named(name: &str) -> Option<LabelColor> {
    let n = name.to_lowercase();
    LabelColor::ALL.into_iter().find(|l| label_raw(*l) == n || l.display_name().to_lowercase() == n)
}

/// The stored identifier of a label color (its serde name).
fn label_raw(label: LabelColor) -> String {
    serde_json::to_value(label).ok().and_then(|v| v.as_str().map(str::to_string)).unwrap_or_default()
}

/// 0 = today, -1 = yesterday.
fn day_offset(v: &str) -> Option<i64> {
    match v.to_lowercase().as_str() {
        "today" => Some(0),
        "yesterday" => Some(-1),
        _ => None,
    }
}

fn day_components(v: &str) -> Option<(i64, i64, i64)> {
    let parts: Vec<&str> = v.split('-').filter(|p| !p.is_empty()).collect();
    let p: Vec<i64> = parts.iter().filter_map(|s| s.parse().ok()).collect();
    if parts.len() == 3 && p.len() == 3 { Some((p[0], p[1], p[2])) } else { None }
}

/// Splits `text` into words (a quoted value stays whole). `complete` is false for a trailing word the user may still
/// be typing (no space after it).
fn words(text: &str) -> Vec<(String, bool)> {
    let mut out = Vec::new();
    let (mut cur, mut quoted) = (String::new(), false);
    for ch in text.chars() {
        if ch == '"' {
            quoted = !quoted;
            cur.push(ch);
        } else if ch.is_whitespace() && !quoted {
            if !cur.is_empty() {
                out.push((std::mem::take(&mut cur), true));
            }
        } else {
            cur.push(ch);
        }
    }
    if !cur.is_empty() {
        out.push((cur, false));
    }
    out
}

fn fps_of(media: &MediaRef) -> Option<f64> {
    let d = media.info.as_ref()?.video.as_ref()?.nominal_frame_duration;
    (d.value() > 0).then(|| d.timescale() as f64 / d.value() as f64)
}

/// `extension MediaFilterToken` of MediaFilterTokens.swift.
pub trait MediaFilterTokenExt: Sized {
    /// Typed form; parses back to the same token.
    fn text(&self) -> String;
    /// Chip title.
    fn title(&self) -> String;
    /// Token for one word `key:value` or `unused` / `used`; `None` when it is plain text or the value is empty or invalid.
    fn parse(word: &str) -> Option<Self>;
    /// Pulls the finished tokens out of a typed string. Returns the remaining free text and the tokens found.
    /// A last word without a trailing space becomes a token only when `is_final` (Return, field loses focus).
    fn extract(text: &str, is_final: bool) -> (String, Vec<Self>);
    /// Whether `media` passes. `is_used` comes from the caller; `now` and `calendar` decide `day:`.
    fn matches(&self, media: &MediaRef, is_used: bool, now: Timestamp, calendar: &dyn Calendar) -> bool;
}

impl MediaFilterTokenExt for MediaFilterToken {
    fn text(&self) -> String {
        if self.key == MediaFilterKey::Usage {
            return self.value.clone();
        }
        let v = if self.value.chars().any(char::is_whitespace) {
            format!("\"{}\"", self.value)
        } else {
            self.value.clone()
        };
        format!("{}:{v}", key_raw(self.key))
    }

    fn title(&self) -> String {
        match self.key {
            MediaFilterKey::Camera => format!("Camera: {}", self.value),
            MediaFilterKey::Fps => format!("{} fps", self.value),
            MediaFilterKey::Day => format!("Day: {}", capitalized(&self.value)),
            MediaFilterKey::Label => {
                let shown =
                    label_named(&self.value).map_or_else(|| self.value.clone(), |l| l.display_name().to_string());
                format!("Label: {shown}")
            }
            MediaFilterKey::Kind | MediaFilterKey::Usage => capitalized(&self.value),
        }
    }

    fn parse(word: &str) -> Option<MediaFilterToken> {
        let lower = word.to_lowercase();
        if lower == "unused" || lower == "used" {
            return Some(MediaFilterToken { key: MediaFilterKey::Usage, value: lower });
        }
        let colon = word.find(':')?;
        let key = key_from_raw(&word[..colon].to_lowercase()).filter(|k| *k != MediaFilterKey::Usage)?;
        let mut value = word[colon + 1..].to_string();
        if value.starts_with('"') {
            value.remove(0);
            if value.ends_with('"') {
                value.pop();
            }
        }
        let value = trim_blanks(&value).to_string();
        if value.is_empty() {
            return None;
        }
        let valid = match key {
            MediaFilterKey::Fps => value.parse::<f64>().is_ok(),
            MediaFilterKey::Label => label_named(&value).is_some(),
            MediaFilterKey::Kind => ["video", "audio", "image"].contains(&value.to_lowercase().as_str()),
            MediaFilterKey::Day => day_offset(&value).is_some() || day_components(&value).is_some(),
            _ => true,
        };
        if !valid {
            return None;
        }
        let value = if key == MediaFilterKey::Camera { value } else { value.to_lowercase() };
        Some(MediaFilterToken { key, value })
    }

    fn extract(text: &str, is_final: bool) -> (String, Vec<MediaFilterToken>) {
        let (mut rest, mut tokens): (Vec<String>, Vec<MediaFilterToken>) = (Vec::new(), Vec::new());
        for (word, complete) in words(text) {
            match (complete || is_final).then(|| Self::parse(&word)).flatten() {
                Some(t) => tokens.push(t),
                None => rest.push(word),
            }
        }
        let tail = if text.chars().last().is_some_and(char::is_whitespace) && !rest.is_empty() { " " } else { "" };
        (rest.join(" ") + tail, tokens)
    }

    fn matches(&self, media: &MediaRef, is_used: bool, now: Timestamp, calendar: &dyn Calendar) -> bool {
        let value = &self.value;
        match self.key {
            MediaFilterKey::Usage => {
                if value == "used" {
                    is_used
                } else {
                    !is_used
                }
            }
            MediaFilterKey::Camera => {
                media.info.as_ref().and_then(|i| i.camera_model.as_deref()).is_some_and(|c| ci_contains(c, value))
            }
            MediaFilterKey::Fps => {
                let (Some(fps), Ok(want)) = (fps_of(media), value.parse::<f64>()) else { return false };
                if value.contains('.') { (fps - want).abs() < 0.01 } else { fps.round() == want.round() }
            }
            MediaFilterKey::Label => label_named(value).is_some_and(|l| media.label == Some(l)),
            MediaFilterKey::Kind => matches!(
                (value.as_str(), media.kind()),
                ("video", MediaKind::Video | MediaKind::VideoAudio)
                    | ("audio", MediaKind::Audio)
                    | ("image", MediaKind::Image)
            ),
            MediaFilterKey::Day => {
                let Some(shot) = media.shoot_date() else { return false };
                if let Some(off) = day_offset(value) {
                    return calendar.add_days(now, off).is_some_and(|d| calendar.is_same_day(shot, d));
                }
                day_components(value)
                    .and_then(|(y, m, d)| calendar.date_from(y, m, d))
                    .is_some_and(|d| calendar.is_same_day(shot, d))
            }
        }
    }
}

/// `extension MediaRef` of MediaFilterTokens.swift.
pub trait MediaRefShootDateExt {
    /// When the clip was shot: the file's creation date, else its modification date (`None` when neither is known).
    fn shoot_date(&self) -> Option<Timestamp>;
}

impl MediaRefShootDateExt for MediaRef {
    fn shoot_date(&self) -> Option<Timestamp> {
        self.info.as_ref().and_then(|i| i.created).or(self.fingerprint.modified)
    }
}

/// Free text plus tokens: what the search field and chips say together.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MediaFilterQuery {
    /// Free text, matched against the media name.
    pub text: String,
    /// The finished tokens.
    pub tokens: Vec<MediaFilterToken>,
}

impl MediaFilterQuery {
    /// Nothing typed and no token.
    pub fn is_empty(&self) -> bool {
        trim_blanks(&self.text).is_empty() && self.tokens.is_empty()
    }

    /// Parses a whole string (all words count as complete).
    pub fn parse(s: &str) -> MediaFilterQuery {
        let (rest, tokens) = MediaFilterToken::extract(s, true);
        MediaFilterQuery { text: trim_blanks(&rest).to_string(), tokens }
    }

    /// Tokens of different kinds all apply; two tokens of one kind (two cameras, two days) are alternatives.
    pub fn matches(&self, media: &MediaRef, is_used: bool, now: Timestamp, calendar: &dyn Calendar) -> bool {
        let q = trim_blanks(&self.text);
        if !q.is_empty() && !ci_contains(&media.name, q) {
            return false;
        }
        self.tokens.iter().map(|t| t.key).all(|key| {
            let mut same = self.tokens.iter().filter(|t| t.key == key);
            if key == MediaFilterKey::Usage {
                same.all(|t| t.matches(media, is_used, now, calendar))
            } else {
                same.any(|t| t.matches(media, is_used, now, calendar))
            }
        })
    }

    /// Values that exist in `media` for a key (quick chips): cameras, frame rates, labels.
    pub fn values(key: MediaFilterKey, media: &[MediaRef]) -> Vec<String> {
        let mut seen: BTreeSet<String> = BTreeSet::new();
        let mut out: Vec<String> = Vec::new();
        for m in media {
            let v: Option<String> = match key {
                MediaFilterKey::Camera => m.info.as_ref().and_then(|i| i.camera_model.clone()),
                MediaFilterKey::Fps => fps_of(m).map(|f| {
                    if (f - f.round()).abs() < 0.01 { format!("{}", f.round() as i64) } else { format!("{f:.3}") }
                }),
                MediaFilterKey::Label => m.label.map(label_raw),
                _ => None,
            };
            if let Some(v) = v
                && seen.insert(v.clone())
            {
                out.push(v);
            }
        }
        out.sort_by(|a, b| standard_compare(a, b));
        out
    }
}

#[cfg(test)]
mod tests;
