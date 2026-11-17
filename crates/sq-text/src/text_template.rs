// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TextTemplate.swift
//! A saved text: its words, style, box, highlight and animation, in a versioned JSON file.

use crate::caption_karaoke::TextHighlight;
use crate::text_style::{TextBox, TextStyle};
use serde::{Deserialize, Serialize};
use sq_core_model::anchored_animation::KeyframeTemplate;
use std::fmt;

/// Why a text template could not be read.
#[derive(Clone, Debug, PartialEq)]
pub enum TextTemplateError {
    /// File was written by a newer app version.
    UnsupportedVersion {
        /// Version in the file.
        found: i64,
        /// Newest version this build reads.
        supported: i64,
    },
    /// The data is not a text template.
    InvalidData(String),
}

impl fmt::Display for TextTemplateError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TextTemplateError::UnsupportedVersion { found, supported } => {
                write!(f, "Text template format version {found} is newer than the supported version {supported}.")
            }
            TextTemplateError::InvalidData(why) => write!(f, "Invalid text template: {why}"),
        }
    }
}

impl std::error::Error for TextTemplateError {}

/// A text with its look.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TextTemplate {
    /// Shown name.
    pub name: String,
    /// The words.
    pub text: String,
    /// How it looks.
    pub style: TextStyle,
    /// The animation.
    #[serde(default)]
    pub animation: Option<KeyframeTemplate>,
    /// Area text: the wrap width and height of the box. Nil = point text (one line per paragraph, grows with the text).
    #[serde(default, rename = "box")]
    pub box_: Option<TextBox>,
    /// Words drawn in another color (karaoke captions); nil for plain text.
    #[serde(default)]
    pub highlight: Option<TextHighlight>,
    /// Id of the Look that was applied last (`LookLibrary`); nil = none. Only a note for the "edited" state: the style
    /// above is what is drawn. An optional key, so older builds read the template as before.
    #[serde(default, rename = "lookID")]
    pub look_id: Option<String>,
}

/// The coded shape: `formatVersion` first among the keys Swift writes.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Wire<'a> {
    format_version: i64,
    name: &'a str,
    text: &'a str,
    style: &'a TextStyle,
    #[serde(skip_serializing_if = "Option::is_none")]
    animation: &'a Option<KeyframeTemplate>,
    #[serde(rename = "box", skip_serializing_if = "Option::is_none")]
    box_: &'a Option<TextBox>,
    #[serde(skip_serializing_if = "Option::is_none")]
    highlight: &'a Option<TextHighlight>,
    #[serde(rename = "lookID", skip_serializing_if = "Option::is_none")]
    look_id: &'a Option<String>,
}

impl Serialize for TextTemplate {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        Wire {
            format_version: Self::FORMAT_VERSION,
            name: &self.name,
            text: &self.text,
            style: &self.style,
            animation: &self.animation,
            box_: &self.box_,
            highlight: &self.highlight,
            look_id: &self.look_id,
        }
        .serialize(s)
    }
}

impl TextTemplate {
    /// 4: the style may carry `secondLine` (N4 two-style text; older versions read as one style).
    /// 3: animations carry an `anchor` (start/end; older files read as start).
    /// 2: animation tracks use SQCore keyframes with template-local `Time`s (v1: normalized fractions + easing enum, still readable).
    pub const FORMAT_VERSION: i64 = 4;

    /// A template with no animation, box, highlight or Look.
    pub fn new(name: &str, text: &str, style: TextStyle) -> TextTemplate {
        TextTemplate {
            name: name.to_string(),
            text: text.to_string(),
            style,
            animation: None,
            box_: None,
            highlight: None,
            look_id: None,
        }
    }

    /// Pretty-printed JSON with sorted keys (stable for diffs).
    pub fn encoded(&self) -> Result<Vec<u8>, serde_json::Error> {
        // Keys are sorted here, not left to `Value`: another crate in the workspace turns on serde_json's
        // `preserve_order`, which makes `Value` keep insertion order.
        serde_json::to_vec_pretty(&sq_core_time::json_sorted::to_value(self)?)
    }

    /// Reads the version first, so newer files fail with `UnsupportedVersion` even if their structure differs.
    pub fn decode_from(data: &[u8]) -> Result<TextTemplate, TextTemplateError> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Peek {
            format_version: i64,
        }
        let version = serde_json::from_slice::<Peek>(data)
            .map_err(|_| TextTemplateError::InvalidData("missing or unreadable formatVersion".to_string()))?
            .format_version;
        if version < 1 {
            return Err(TextTemplateError::InvalidData(format!("formatVersion {version}")));
        }
        if version > Self::FORMAT_VERSION {
            return Err(TextTemplateError::UnsupportedVersion { found: version, supported: Self::FORMAT_VERSION });
        }
        serde_json::from_slice(data).map_err(|e| TextTemplateError::InvalidData(e.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::text_style::{FontWeight, RGBAColor};
    use serde_json::{Value, json};
    use sq_core_model::anchored_animation::{AnimationTrack, SegmentShape};
    use sq_core_time::Time;

    fn sample(animated: bool) -> TextTemplate {
        let style = TextStyle::new("Helvetica", 40.0, FontWeight::Bold, RGBAColor::WHITE);
        let mut t = TextTemplate::new("Lower third", "Hello\nWorld", style);
        if animated {
            t.animation = Some(KeyframeTemplate {
                tracks: vec![AnimationTrack::from_shapes(
                    "scale",
                    &[(Time::ZERO, 0.8, SegmentShape::Overshoot), (Time::new(1, 4), 1.0, SegmentShape::Linear)],
                )],
                duration: Time::new(1, 4),
                ..KeyframeTemplate::none()
            });
        }
        t
    }

    #[test]
    fn round_trip_with_and_without_animation() {
        for animated in [true, false] {
            let t = sample(animated);
            assert_eq!(TextTemplate::decode_from(&t.encoded().unwrap()).unwrap(), t);
        }
    }

    #[test]
    fn writes_current_format_version() {
        let json: Value = serde_json::from_slice(&sample(true).encoded().unwrap()).unwrap();
        assert_eq!(json["formatVersion"], 4);
        assert_eq!(TextTemplate::FORMAT_VERSION, 4);
    }

    const V1_JSON: &str = r#"{"formatVersion":1,"name":"Old","text":"Hi",
     "style":{"fontName":"Helvetica","size":40,"weight":400,"color":{"red":1,"green":1,"blue":1,"alpha":1},
              "alignment":"center","lineSpacing":0},
     "animation":{"duration":{"value":1,"timescale":4},"tracks":[
       {"property":"scale","keyframes":[
         {"time":{"numerator":0,"denominator":1},"value":0.8,"easing":"overshoot"},
         {"time":{"numerator":1,"denominator":1},"value":1,"easing":"linear"}]},
       {"property":"opacity","keyframes":[
         {"time":{"numerator":0,"denominator":1},"value":0,"easing":"hold"},
         {"time":{"numerator":1,"denominator":2},"value":1,"easing":"linear"},
         {"time":{"numerator":1,"denominator":1},"value":1,"easing":"linear"}]}]}}"#;

    #[test]
    fn reads_version_one_files_and_migrates_animation() {
        let t = TextTemplate::decode_from(V1_JSON.as_bytes()).unwrap();
        assert!(t.name == "Old" && t.text == "Hi" && t.style.size == 40.0);
        let anim = t.animation.clone().unwrap();
        assert_eq!(anim.duration, Time::new(1, 4));
        // Fractions became duration * fraction.
        let times: Vec<Time> = anim.track_for("opacity").unwrap().track().keys.iter().map(|k| k.time).collect();
        assert_eq!(times, [Time::ZERO, Time::new(1, 8), Time::new(1, 4)]);
        assert_eq!(anim.value_of("opacity", Time::new(1, 16)), Some(0.0)); // hold
        assert_eq!(anim.value_of("opacity", Time::new(1, 8)), Some(1.0));
        assert!(anim.value_of("scale", Time::new(7, 40)).unwrap() > 1.0); // overshoot survived
        // Re-saving writes the current version and round-trips.
        let resaved = t.encoded().unwrap();
        let json: Value = serde_json::from_slice(&resaved).unwrap();
        assert_eq!(json["formatVersion"], 4);
        assert_eq!(TextTemplate::decode_from(&resaved).unwrap(), t);
    }

    #[test]
    fn output_is_stable_and_sorted() {
        let a = sample(true).encoded().unwrap();
        assert_eq!(a, sample(true).encoded().unwrap());
        let s = String::from_utf8(a).unwrap();
        let keys = ["\"animation\"", "\"formatVersion\"", "\"name\"", "\"style\"", "\"text\""];
        let positions: Vec<usize> = keys.iter().map(|k| s.find(k).unwrap()).collect();
        let mut sorted = positions.clone();
        sorted.sort_unstable();
        assert_eq!(positions, sorted);
    }

    #[test]
    fn newer_version_gives_a_typed_error() {
        // Future file with a structure this version cannot parse: must still report the version.
        let json = r#"{"formatVersion": 5, "name": 5, "layers": []}"#;
        assert_eq!(
            TextTemplate::decode_from(json.as_bytes()),
            Err(TextTemplateError::UnsupportedVersion { found: 5, supported: 4 })
        );
    }

    #[test]
    fn missing_or_broken_data_is_invalid() {
        for json in [r#"{"name":"x"}"#, "not json", r#"{"formatVersion":1,"name":"x"}"#, r#"{"formatVersion":0}"#] {
            assert!(
                matches!(TextTemplate::decode_from(json.as_bytes()), Err(TextTemplateError::InvalidData(_))),
                "{json}"
            );
        }
    }

    #[test]
    fn unknown_extra_keys_in_current_version_are_ignored() {
        let mut obj: Value = serde_json::from_slice(&sample(true).encoded().unwrap()).unwrap();
        obj["futureHint"] = json!("x");
        assert_eq!(TextTemplate::decode_from(&serde_json::to_vec(&obj).unwrap()).unwrap(), sample(true));
    }

    #[test]
    fn error_has_readable_description() {
        let d = TextTemplateError::UnsupportedVersion { found: 5, supported: 4 }.to_string();
        assert!(d.contains('5') && d.contains('4'));
    }

    #[test]
    fn remembers_its_look() {
        let mut t = sample(false);
        assert!(!String::from_utf8(t.encoded().unwrap()).unwrap().contains("lookID"));
        t.look_id = Some("title".into());
        let back = TextTemplate::decode_from(&t.encoded().unwrap()).unwrap();
        assert!(back == t && back.look_id.as_deref() == Some("title"));
    }
}
