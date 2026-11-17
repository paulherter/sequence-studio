// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ColorGradeEffect.swift (saved types, moved down; the Color effect logic lives in sq-core-color)

use crate::clip_color::{is_default, is_true};
use crate::{
    AnimatedProperty, BasicToneModel, ClipColor, ColorEffect, ColorSpaceID, HSLSecondary, HueCurves, LUTRef, RGBCurves,
};
use serde::{Deserialize, Deserializer, Serialize};
use sq_core_time::{Id, Time};
use std::collections::BTreeMap;

/// How a log source reaches the display signal (the first Color effect's conversion, v93).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LogMode {
    /// The effect's Input LUT decides. The default.
    #[default]
    CameraLUT,
    /// The built-in transform of the source color space; the Input LUT is ignored.
    BuiltIn,
    /// No log conversion: a log source is taken as display-referred Rec.709.
    Off,
}

/// The space the clip's conversion delivers (v93).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TargetSpace {
    /// Rec.709 (default).
    #[default]
    Rec709,
    /// Rec.2020.
    Rec2020,
    /// Rec.2020 PQ.
    Rec2020PQ,
    /// Rec.2020 HLG.
    Rec2020HLG,
}

/// One Zone Board zone: puck position in its square, saturation and exposure; 0.5 = unchanged. (ZoneBoard.swift)
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ZoneSetting {
    /// 0...1, x right.
    pub puck_x: f32,
    /// 0...1, y up.
    pub puck_y: f32,
    /// 0...1.
    pub saturation: f32,
    /// 0...1.
    pub exposure: f32,
}

impl Default for ZoneSetting {
    fn default() -> Self {
        ZoneSetting { puck_x: 0.5, puck_y: 0.5, saturation: 0.5, exposure: 0.5 }
    }
}

impl ZoneSetting {
    /// The zone does nothing.
    pub fn is_neutral(&self) -> bool {
        *self == ZoneSetting::default()
    }
}

/// The Zone Board (v94): four zones, each written only when not neutral. (ZoneBoard.swift)
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ZoneBoard {
    /// Whole picture.
    #[serde(skip_serializing_if = "ZoneSetting::is_neutral")]
    pub global: ZoneSetting,
    /// Shadows.
    #[serde(skip_serializing_if = "ZoneSetting::is_neutral")]
    pub shadows: ZoneSetting,
    /// Midtones.
    #[serde(skip_serializing_if = "ZoneSetting::is_neutral")]
    pub midtones: ZoneSetting,
    /// Highlights.
    #[serde(skip_serializing_if = "ZoneSetting::is_neutral")]
    pub highlights: ZoneSetting,
}

impl ZoneBoard {
    /// The board does nothing to the picture.
    pub fn is_neutral(&self) -> bool {
        self.global.is_neutral()
            && self.shadows.is_neutral()
            && self.midtones.is_neutral()
            && self.highlights.is_neutral()
    }
}

/// Color statistics of one frame on the display-encoded signal; each `[f32; 3]` is an RGB vector (Swift `SIMD3<Float>`
/// codes as a 3-element array). (ColorMatch.swift)
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct ColorMatchStats {
    /// Mean color of the shadows band.
    pub shadows: [f32; 3],
    /// Mean color of the midtones band.
    pub midtones: [f32; 3],
    /// Mean color of the highlights band.
    pub highlights: [f32; 3],
    /// Share of the picture in each band.
    pub weights: [f32; 3],
    /// Mean distance of a pixel from its gray.
    pub chroma: f32,
}

/// The reference a Color effect matches to (v43). (ColorMatch.swift)
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ColorMatchReference {
    /// The clip the reference frame showed, `None` when none could be named.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub clip: Option<Id>,
    /// Sequence time of the reference frame.
    pub time: Time,
    /// Name shown in Effect Controls.
    pub label: String,
    /// What the frame looked like.
    pub stats: ColorMatchStats,
}

/// Swift `try?` on one key: a value that does not decode is dropped.
fn lenient<'de, D: Deserializer<'de>, T: serde::de::DeserializeOwned>(d: D) -> Result<Option<T>, D::Error> {
    Ok(Option::<serde_json::Value>::deserialize(d)?.and_then(|v| serde_json::from_value(v).ok()))
}

/// The non-scalar part of a Color effect: LUT references and curves (not keyframable).
///
/// Every key is optional on decode; an absent `inputLUT` is `Automatic`, an explicit `null` is none.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ColorGradeData {
    /// Input LUT inside Basic Correction. `None` = none (written as `null`); `Automatic` = the media's camera LUT.
    #[serde(rename = "inputLUT")]
    pub input_lut: Option<LUTRef>,
    /// Creative look LUT; `None` = none.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub look: Option<LUTRef>,
    /// RGB curves; written only when not neutral.
    #[serde(skip_serializing_if = "RGBCurves::is_neutral")]
    pub curves: RGBCurves,
    /// Hue curves; written only when not the default.
    #[serde(skip_serializing_if = "is_default")]
    pub hue_curves: HueCurves,
    /// The Color Range section's toggle.
    #[serde(skip_serializing_if = "is_default")]
    pub hsl_secondary_off: bool,
    /// Color Range qualifier and correction (v48); `None` = none.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hsl_secondary: Option<HSLSecondary>,
    /// The Zone Board's toggle (v94).
    #[serde(skip_serializing_if = "is_default")]
    pub zone_board_off: bool,
    /// Zone Board (v94); `None` = none.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub zone_board: Option<ZoneBoard>,
    /// Color Match reference (v43); a malformed reference is dropped on decode.
    #[serde(rename = "match", deserialize_with = "lenient", skip_serializing_if = "Option::is_none")]
    pub match_reference: Option<ColorMatchReference>,
}

impl Default for ColorGradeData {
    fn default() -> Self {
        ColorGradeData {
            input_lut: Some(LUTRef::Automatic),
            look: None,
            curves: RGBCurves::default(),
            hue_curves: HueCurves::default(),
            hsl_secondary_off: false,
            hsl_secondary: None,
            zone_board_off: false,
            zone_board: None,
            match_reference: None,
        }
    }
}

/// The footage interpretation of a clip (Interpret Footage): stored under the clip's `color` key since v27.
///
/// Every key is optional on decode; `logMode`, `targetSpace` and `hdrConform` are written only when not default.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(from = "ClipColor", rename_all = "camelCase")]
pub struct ClipFootageColor {
    /// `None` = from media (`MediaInfo.colorSpace`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<ColorSpaceID>,
    /// Per-clip toggle for the embedded camera LUT.
    #[serde(rename = "useEmbeddedLUT")]
    pub use_embedded_lut: bool,
    /// How a log source is converted (v93).
    #[serde(skip_serializing_if = "is_default")]
    pub log_mode: LogMode,
    /// The space the conversion delivers (v93).
    #[serde(skip_serializing_if = "is_default")]
    pub target_space: TargetSpace,
    /// Automatic HDR/SDR conform before the grade (v93, default on).
    #[serde(skip_serializing_if = "is_true")]
    pub hdr_conform: bool,
    /// The non-neutral Color effects a v12...v26 file kept in `color` (read, never written); the v26 -> v27 step turns them
    /// into Color effects of the clip and clears this (Swift `Clip.adoptLegacyGrade`).
    #[serde(skip)]
    pub legacy_effects: Option<Vec<ColorEffect>>,
}

impl Default for ClipFootageColor {
    fn default() -> Self {
        ClipFootageColor {
            source: None,
            use_embedded_lut: true,
            log_mode: LogMode::CameraLUT,
            target_space: TargetSpace::Rec709,
            hdr_conform: true,
            legacy_effects: None,
        }
    }
}

impl From<ClipColor> for ClipFootageColor {
    /// A stored `color` object: the footage keys, plus the grade an old file kept there.
    fn from(c: ClipColor) -> ClipFootageColor {
        let mut f = ClipFootageColor::from(&c);
        if c.effects() != ClipColor::default_effects().as_slice() {
            f.legacy_effects = Some(c.effects().to_vec());
        }
        f
    }
}

impl From<&ClipColor> for ClipFootageColor {
    /// The footage part of an edited grade.
    fn from(c: &ClipColor) -> ClipFootageColor {
        ClipFootageColor {
            source: c.source,
            use_embedded_lut: c.use_embedded_lut,
            log_mode: c.log_mode,
            target_space: c.target_space,
            hdr_conform: c.hdr_conform,
            legacy_effects: None,
        }
    }
}

/// Kind of a Color effect (stored string: never rename).
pub const COLOR_KIND: &str = "color";

/// Hidden parameter (not in the spec, never keyed): the Basic Correction maths, `BasicToneModel` raw value. Absent =
/// the effect predates the Lumetri maths (`Legacy`), unless its Basic Correction sliders were never moved.
pub const COLOR_BASIC_MODEL_KEY: &str = "basicModel";

/// Basic Correction slider keys with their default values (`ColorGradeFields.basic`).
const BASIC_SLIDER_DEFAULTS: [(&str, f32); 11] = [
    ("temperature", 0.0),
    ("tint", 0.0),
    ("saturation", 100.0),
    ("exposure", 0.0),
    ("contrast", 0.0),
    ("highlights", 0.0),
    ("shadows", 0.0),
    ("whites", 0.0),
    ("blacks", 0.0),
    ("vibrance", 0.0),
    ("inputLUTIntensity", 100.0),
];

/// The Basic Correction maths of a Color effect with these parameters (`ClipEffect.basicToneModel`).
pub fn basic_tone_model(parameters: &BTreeMap<String, AnimatedProperty<f64>>) -> BasicToneModel {
    if let Some(p) = parameters.get(COLOR_BASIC_MODEL_KEY) {
        let r = p.value.round();
        let raw = if r.is_finite() { r as i64 } else { i64::MAX };
        return BasicToneModel::from_raw(raw).unwrap_or(BasicToneModel::CURRENT);
    }
    // Stored before the model existed: legacy, unless every Basic slider is static at its default.
    let untouched = BASIC_SLIDER_DEFAULTS
        .iter()
        .all(|(key, def)| parameters.get(*key).is_none_or(|p| !p.is_animated() && p.value as f32 == *def));
    if untouched { BasicToneModel::CURRENT } else { BasicToneModel::Legacy }
}

/// The decode step of `ClipEffect`: a Color effect stored before the maths flag gets the model it is read with
/// pinned, so a later slider move cannot flip an untouched effect back to the legacy maths.
pub fn pin_basic_model(kind: &str, parameters: &mut BTreeMap<String, AnimatedProperty<f64>>) {
    if kind == COLOR_KIND && !parameters.contains_key(COLOR_BASIC_MODEL_KEY) {
        let model = basic_tone_model(parameters);
        parameters.insert(COLOR_BASIC_MODEL_KEY.to_string(), AnimatedProperty::new(f64::from(model as i32)));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clip_color::test_util::{decode, encode, parse, round_trip};

    #[test]
    fn grade_data_absent_input_lut_is_automatic_and_null_is_none() {
        assert_eq!(decode::<ColorGradeData>("{}"), ColorGradeData::default());
        assert_eq!(decode::<ColorGradeData>("{}").input_lut, Some(LUTRef::Automatic));
        let none = decode::<ColorGradeData>(r#"{"inputLUT":null}"#);
        assert_eq!(none.input_lut, None);
        assert_eq!(encode(&none), parse(r#"{"inputLUT":null}"#));
    }

    #[test]
    fn grade_data_default_writes_only_the_input_lut() {
        round_trip::<ColorGradeData>(r#"{"inputLUT":{"kind":"automatic"}}"#);
    }

    #[test]
    fn grade_data_full_form_round_trips() {
        let j = r#"{"inputLUT":{"kind":"file","path":"in.cube"},"look":{"kind":"file","path":"look.cube"},
            "curves":{"master":[{"x":0,"y":0},{"x":0.5,"y":0.6},{"x":1,"y":1}],"red":[{"x":0,"y":0},{"x":1,"y":1}],
            "green":[{"x":0,"y":0},{"x":1,"y":1}],"blue":[{"x":0,"y":0},{"x":1,"y":1}]},
            "hueCurves":{"hueVsSat":[{"x":0,"y":0.8},{"x":1,"y":0.5}],"hueVsHue":[{"x":0,"y":0.5},{"x":1,"y":0.5}],
            "hueVsLuma":[{"x":0,"y":0.5},{"x":1,"y":0.5}],"lumaVsSat":[{"x":0,"y":0.5},{"x":1,"y":0.5}],
            "satVsSat":[{"x":0,"y":0.5},{"x":1,"y":0.5}]},
            "hslSecondaryOff":true,"hslSecondary":{"hueCenter":30,"hueWidth":40,"satMin":10,"satMax":100,"lumMin":0,
            "lumMax":100,"softness":20,"invert":false,"hueShift":0,"saturation":100,"exposure":0,"temperature":0,"tint":0},
            "zoneBoardOff":true,"zoneBoard":{"shadows":{"puckX":0.3,"puckY":0.5,"saturation":0.5,"exposure":0.4}},
            "match":{"clip":"6F9619FF-8B86-D011-B42D-00C04FC964FF","time":{"value":121,"timescale":30},"label":"A012",
            "stats":{"shadows":[0.1,0.1,0.1],"midtones":[0.4,0.4,0.4],"highlights":[0.8,0.8,0.8],"weights":[0.3,0.4,0.3],
            "chroma":0.2}}}"#;
        let g = round_trip::<ColorGradeData>(j);
        assert!(g.match_reference.is_some());
        assert!(g.zone_board.is_some_and(|z| !z.global.is_neutral() || !z.shadows.is_neutral()));
    }

    #[test]
    fn grade_data_drops_a_malformed_match_reference() {
        let g = decode::<ColorGradeData>(r#"{"match":{"label":3}}"#);
        assert_eq!(g.match_reference, None);
    }

    #[test]
    fn footage_color_defaults_and_conditional_keys() {
        assert_eq!(decode::<ClipFootageColor>("{}"), ClipFootageColor::default());
        round_trip::<ClipFootageColor>(r#"{"useEmbeddedLUT":true}"#);
        let c = round_trip::<ClipFootageColor>(
            r#"{"source":"appleLog","useEmbeddedLUT":false,"logMode":"off","targetSpace":"rec2020HLG","hdrConform":false}"#,
        );
        assert_eq!((c.log_mode, c.target_space), (LogMode::Off, TargetSpace::Rec2020HLG));
    }

    #[test]
    fn footage_color_takes_the_footage_part_of_a_grade() {
        let mut c = ClipColor::default();
        c.source = Some(ColorSpaceID::AppleLog);
        c.log_mode = LogMode::BuiltIn;
        let f = ClipFootageColor::from(&c);
        assert_eq!((f.source, f.log_mode, f.hdr_conform), (Some(ColorSpaceID::AppleLog), LogMode::BuiltIn, true));
    }

    fn params(items: &[(&str, f64)]) -> BTreeMap<String, AnimatedProperty<f64>> {
        items.iter().map(|(k, v)| (k.to_string(), AnimatedProperty::new(*v))).collect()
    }

    #[test]
    fn basic_model_is_legacy_when_a_slider_moved_and_current_when_untouched() {
        assert_eq!(basic_tone_model(&params(&[("temperature", 5.0)])), BasicToneModel::Legacy);
        assert_eq!(basic_tone_model(&params(&[("temperature", 0.0), ("saturation", 100.0)])), BasicToneModel::Lumetri);
        assert_eq!(basic_tone_model(&params(&[("basicModel", 0.0), ("temperature", 5.0)])), BasicToneModel::Legacy);
        assert_eq!(basic_tone_model(&params(&[("basicModel", 7.0)])), BasicToneModel::Lumetri);
    }

    #[test]
    fn pin_basic_model_writes_the_flag_only_on_color_effects_without_it() {
        let mut p = params(&[("temperature", 5.0)]);
        pin_basic_model("color", &mut p);
        assert_eq!(p["basicModel"].value, 0.0);
        let mut other = params(&[]);
        pin_basic_model("gaussianBlur", &mut other);
        assert!(other.is_empty());
        let mut set = params(&[("basicModel", 1.0), ("temperature", 5.0)]);
        pin_basic_model("color", &mut set);
        assert_eq!(set["basicModel"].value, 1.0);
    }
}
