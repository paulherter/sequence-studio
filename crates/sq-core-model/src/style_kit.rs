// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: StyleKit.swift (saved types, moved down; token lookup and merging: later tasks)

use crate::EffectColor;
use crate::media_info::{lenient, lenient_or_default};
use serde::de::DeserializeOwned;
use serde::ser::SerializeMap;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use sq_core_time::Time;
use std::collections::BTreeMap;

/// A literal value or the name of a token of the style kit. Coded as `{"literal": v}` or `{"token": "name"}`; a
/// `token` key wins when both are present.
#[derive(Clone, Debug, PartialEq)]
pub enum StyleValue<V> {
    /// A fixed value.
    Literal(V),
    /// The name of a kit token.
    Token(String),
}

impl<V: Serialize> Serialize for StyleValue<V> {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        let mut m = s.serialize_map(Some(1))?;
        match self {
            StyleValue::Literal(v) => m.serialize_entry("literal", v)?,
            StyleValue::Token(n) => m.serialize_entry("token", n)?,
        }
        m.end()
    }
}

impl<'de, V: DeserializeOwned> Deserialize<'de> for StyleValue<V> {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        struct Fields {
            token: Option<String>,
            literal: Option<serde_json::Value>,
        }
        let f = Fields::deserialize(d)?;
        if let Some(name) = f.token {
            return Ok(StyleValue::Token(name));
        }
        let v = f.literal.ok_or_else(|| serde::de::Error::custom("StyleValue needs literal or token"))?;
        V::deserialize(v).map(StyleValue::Literal).map_err(serde::de::Error::custom)
    }
}

/// Largest pill padding in em.
const MAX_EM: f64 = 10.0;
/// Largest pill corner radius.
const MAX_CORNER_RADIUS: f64 = 10_000.0;
/// Largest caption text size.
const MAX_SIZE: f64 = 1000.0;
/// Largest caption offset from its anchor, fraction of the frame.
const MAX_OFFSET: f64 = 0.5;

fn em<'de, D: Deserializer<'de>>(d: D) -> Result<f64, D::Error> {
    let v = f64::deserialize(d)?;
    Ok(if v.is_finite() { v.clamp(0.0, MAX_EM) } else { 0.0 })
}

fn corner_radius<'de, D: Deserializer<'de>>(d: D) -> Result<Option<f64>, D::Error> {
    Ok(Option::<f64>::deserialize(d)?.map(|v| if v.is_finite() { v.clamp(0.0, MAX_CORNER_RADIUS) } else { 0.0 }))
}

fn pill_horizontal() -> f64 {
    0.40
}

fn pill_vertical() -> f64 {
    0.16
}

/// The caption pill (background box behind the text).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StylePill {
    /// Fill color.
    pub color: StyleValue<EffectColor>,
    /// Horizontal padding in em, 0...10.
    #[serde(default = "pill_horizontal", deserialize_with = "em")]
    pub horizontal_em: f64,
    /// Vertical padding in em, 0...10.
    #[serde(default = "pill_vertical", deserialize_with = "em")]
    pub vertical_em: f64,
    /// Corner radius; `None` = fully rounded.
    #[serde(default, skip_serializing_if = "Option::is_none", deserialize_with = "corner_radius")]
    pub corner_radius: Option<f64>,
}

/// A text shadow.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptionShadow {
    /// Shadow color.
    pub color: EffectColor,
    /// Horizontal offset.
    pub offset_x: f64,
    /// Vertical offset.
    pub offset_y: f64,
    /// Blur radius.
    pub blur: f64,
    /// Resting angle for animated shadows.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resting_angle: Option<f64>,
}

/// Overrides of the base caption style; every part is optional.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptionStyleTweaks {
    /// Font weight.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub weight: Option<i64>,
    /// Italic.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub italic: Option<bool>,
    /// Text alignment name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub alignment: Option<String>,
    /// Letter spacing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tracking: Option<f64>,
    /// Line spacing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line_spacing: Option<f64>,
    /// Stroke width.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stroke_width: Option<f64>,
    /// Stroke position name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stroke_position: Option<String>,
    /// Shadow.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shadow: Option<CaptionShadow>,
    /// The base style's shadow is switched off.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hides_shadow: Option<bool>,
}

fn caption_size<'de, D: Deserializer<'de>>(d: D) -> Result<Option<f64>, D::Error> {
    Ok(Option::<f64>::deserialize(d)?.map(|v| if v.is_finite() { v.clamp(1.0, MAX_SIZE) } else { MAX_SIZE }))
}

/// Tweaks that change nothing are dropped.
fn non_empty_tweaks<'de, D: Deserializer<'de>>(d: D) -> Result<Option<CaptionStyleTweaks>, D::Error> {
    Ok(Option::<CaptionStyleTweaks>::deserialize(d)?.filter(|t| *t != CaptionStyleTweaks::default()))
}

/// The caption style of the kit: a base style plus brand overrides.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptionStyleSpec {
    /// Name of the base style.
    pub base_style: String,
    /// Animation preset name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub animation: Option<String>,
    /// Font.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub font: Option<StyleValue<String>>,
    /// Text size, 1...1000.
    #[serde(default, skip_serializing_if = "Option::is_none", deserialize_with = "caption_size")]
    pub size: Option<f64>,
    /// Text color.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text_color: Option<StyleValue<EffectColor>>,
    /// Stroke color.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stroke_color: Option<StyleValue<EffectColor>>,
    /// Draws the kit pill behind the text.
    #[serde(default)]
    pub uses_pill: bool,
    /// All capitals.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub all_caps: Option<bool>,
    /// Hides the base style's background.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hides_background: Option<bool>,
    /// Further overrides; `None` when they change nothing.
    #[serde(default, skip_serializing_if = "Option::is_none", deserialize_with = "non_empty_tweaks")]
    pub tweaks: Option<CaptionStyleTweaks>,
}

/// Vertical anchor of a caption.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CaptionVertical {
    /// Top.
    Top,
    /// Middle.
    Middle,
    /// Bottom.
    #[default]
    Bottom,
}

/// Horizontal anchor of a caption.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CaptionHorizontal {
    /// Left.
    Left,
    /// Center.
    #[default]
    Center,
    /// Right.
    Right,
}

fn offset<'de, D: Deserializer<'de>>(d: D) -> Result<f64, D::Error> {
    let v = lenient::<D, f64>(d)?.unwrap_or(0.0);
    Ok(if v.is_finite() { v.clamp(-MAX_OFFSET, MAX_OFFSET) } else { 0.0 })
}

/// Where captions sit in the frame. Every key reads leniently: a bad value falls back to the default.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptionPosition {
    /// Vertical anchor.
    #[serde(default, deserialize_with = "lenient_or_default")]
    pub vertical: CaptionVertical,
    /// Horizontal anchor.
    #[serde(default, deserialize_with = "lenient_or_default")]
    pub horizontal: CaptionHorizontal,
    /// Horizontal offset, -0.5...0.5 of the frame.
    #[serde(default, deserialize_with = "offset")]
    pub offset_x: f64,
    /// Vertical offset, -0.5...0.5 of the frame.
    #[serde(default, deserialize_with = "offset")]
    pub offset_y: f64,
}

/// Default motion duration and curve of the kit.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MotionDefaults {
    /// Duration.
    pub duration: Time,
    /// Motion curve number.
    pub curve: i64,
}

/// A saved look: an opaque payload owned by the text crate.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StyleKitLook {
    /// Shown name.
    pub name: String,
    /// Versioned content (base64 in JSON).
    #[serde(with = "sq_core_time::base64")]
    pub payload: Vec<u8>,
    /// Version of the payload's own format.
    pub payload_version: i64,
}

/// Project-level brand tokens: fonts, colors, the caption pill, the caption style and motion defaults.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StyleKit {
    /// Font tokens by name.
    #[serde(default)]
    pub fonts: BTreeMap<String, String>,
    /// Color tokens by name.
    #[serde(default)]
    pub colors: BTreeMap<String, EffectColor>,
    /// The caption pill.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pill: Option<StylePill>,
    /// The caption style.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub caption: Option<CaptionStyleSpec>,
    /// Motion defaults.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub motion: Option<MotionDefaults>,
    /// Saved looks by id.
    #[serde(default)]
    pub looks: BTreeMap<String, StyleKitLook>,
    /// Default caption position.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub caption_position: Option<CaptionPosition>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_info::assert_round_trip;
    use serde_json::json;

    fn color() -> serde_json::Value {
        json!({"red": 1.0, "green": 0.5, "blue": 0.0, "alpha": 1.0})
    }

    #[test]
    fn style_value_uses_literal_or_token_keys() {
        assert_round_trip::<StyleValue<EffectColor>>(json!({"literal": color()}));
        assert_round_trip::<StyleValue<String>>(json!({"token": "brand"}));
        let both: StyleValue<String> = serde_json::from_value(json!({"literal": "x", "token": "t"})).unwrap();
        assert_eq!(both, StyleValue::Token("t".into()));
        assert!(serde_json::from_value::<StyleValue<String>>(json!({})).is_err());
    }

    #[test]
    fn empty_kit_writes_its_dictionaries() {
        assert_round_trip::<StyleKit>(json!({"fonts": {}, "colors": {}, "looks": {}}));
        let kit: StyleKit = serde_json::from_value(json!({})).unwrap();
        assert_eq!(kit, StyleKit::default());
    }

    #[test]
    fn kit_with_looks_and_position_round_trips() {
        assert_round_trip::<StyleKit>(json!({"fonts": {"h": "Inter"}, "colors": {"c": color()},
            "looks": {"a": {"name": "A", "payload": "eyJ9", "payloadVersion": 1}},
            "captionPosition": {"vertical": "top", "horizontal": "left", "offsetX": 0.25, "offsetY": 0.0},
            "motion": {"duration": {"value": 1, "timescale": 2}, "curve": 3}}));
    }

    #[test]
    fn pill_defaults_and_clamps() {
        let p: StylePill = serde_json::from_value(json!({"color": {"token": "c"}})).unwrap();
        assert_eq!((p.horizontal_em, p.vertical_em, p.corner_radius), (0.40, 0.16, None));
        let q: StylePill = serde_json::from_value(json!({"color": {"token": "c"}, "horizontalEm": 99.0,
            "verticalEm": -1.0, "cornerRadius": 1.0e9}))
        .unwrap();
        assert_eq!((q.horizontal_em, q.vertical_em, q.corner_radius), (10.0, 0.0, Some(10_000.0)));
    }

    #[test]
    fn caption_spec_clamps_size_and_drops_empty_tweaks() {
        let s: CaptionStyleSpec =
            serde_json::from_value(json!({"baseStyle": "b", "size": 5000.0, "tweaks": {}})).unwrap();
        assert_eq!((s.size, s.tweaks, s.uses_pill), (Some(1000.0), None, false));
        let small: CaptionStyleSpec = serde_json::from_value(json!({"baseStyle": "b", "size": 0.0})).unwrap();
        assert_eq!(small.size, Some(1.0));
        assert_round_trip::<CaptionStyleSpec>(json!({"baseStyle": "b", "usesPill": true, "allCaps": true,
            "tweaks": {"weight": 700, "shadow": {"color": color(), "offsetX": 1.0, "offsetY": 2.0, "blur": 3.0}}}));
    }

    #[test]
    fn caption_position_reads_each_key_leniently() {
        let p: CaptionPosition = serde_json::from_value(json!({"vertical": "sideways", "horizontal": 4,
            "offsetX": "far", "offsetY": 3.0}))
        .unwrap();
        assert_eq!(
            (p.vertical, p.horizontal, p.offset_x, p.offset_y),
            (CaptionVertical::Bottom, CaptionHorizontal::Center, 0.0, 0.5)
        );
        let d: CaptionPosition = serde_json::from_value(json!({})).unwrap();
        assert_eq!((d.vertical, d.offset_x), (CaptionVertical::Bottom, 0.0));
    }
}
