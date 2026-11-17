// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ClipColor.swift (saved types, moved down; color logic lives in sq-core-color)

use crate::{ColorGraph, LogMode, TargetSpace, ZoneBoard};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use sq_core_time::Id;

/// `skip_serializing_if` for fields Swift writes only when they differ from their default.
pub(crate) fn is_default<T: Default + PartialEq>(v: &T) -> bool {
    *v == T::default()
}

/// `skip_serializing_if` for flags Swift writes only when false.
pub(crate) fn is_true(v: &bool) -> bool {
    *v
}

/// `100.0`, the default of the percent sliders.
pub(crate) fn hundred() -> f32 {
    100.0
}

/// Present-or-absent for a nullable key: absent gives `None`, an explicit `null` gives `Some(None)` (Swift's
/// `container.contains(key)` before `decodeIfPresent`).
fn present<'de, D: Deserializer<'de>, T: Deserialize<'de>>(d: D) -> Result<Option<Option<T>>, D::Error> {
    Option::<T>::deserialize(d).map(Some)
}

/// Source color space: transfer + gamut. Stored on `MediaInfo` (detected at import) and as a per-clip override.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ColorSpaceID {
    Rec709,
    SLog3SGamut3Cine,
    HlgBT2020,
    /// SMPTE ST 2084 (HDR10), BT.2020 primaries (v34).
    PqBT2020,
    /// Panasonic V-Log / V-Gamut (v34).
    VLogVGamut,
    /// Apple Log, BT.2020 primaries (v34).
    AppleLog,
    /// DJI D-Log / D-Gamut (v34).
    DLogDGamut,
    /// Canon Log, Cinema Gamut (v68).
    CanonLogCinemaGamut,
    /// Canon Log, BT.2020 (v68).
    CanonLogBT2020,
    /// Canon Log, BT.709 (v68).
    CanonLogBT709,
    /// Canon Log 2, Cinema Gamut (v68).
    CanonLog2CinemaGamut,
    /// Canon Log 2, BT.2020 (v68).
    CanonLog2BT2020,
    /// Canon Log 2, BT.709 (v68).
    CanonLog2BT709,
    /// Canon Log 3, Cinema Gamut (v68).
    CanonLog3CinemaGamut,
    /// Canon Log 3, BT.2020 (v68).
    CanonLog3BT2020,
    /// Canon Log 3, BT.709 (v68).
    CanonLog3BT709,
    /// ARRI LogC3 (EI 800) / ARRI Wide Gamut 3.
    LogC3WideGamut3,
    /// ARRI LogC4 / ARRI Wide Gamut 4.
    LogC4WideGamut4,
    /// RED Log3G10 / REDWideGamutRGB.
    Log3G10RedWideGamut,
    /// Blackmagic Film Gen 5 / Blackmagic Wide Gamut.
    BmdFilmGen5WideGamut,
    /// Nikon N-Log / Rec. 2020.
    NLogBT2020,
    /// Fujifilm F-Log2 / F-Gamut C.
    FLog2FGamutC,
    /// ACEScct / AP1.
    AcesCCTAP1,
}

/// Reference to a LUT.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum LUTRef {
    /// Conversion slot only: the camera LUT embedded in the clip's media (if `use_embedded_lut`), else none.
    Automatic,
    /// A `.cube` file on disk.
    File {
        /// File path.
        path: String,
    },
    /// The LUT embedded in the given media item.
    Embedded {
        /// Media item id.
        media: Id,
    },
}

impl<'de> Deserialize<'de> for LUTRef {
    /// An unknown `kind` reads as `Automatic`, like Swift.
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<LUTRef, D::Error> {
        #[derive(Deserialize)]
        struct Raw {
            kind: String,
            path: Option<String>,
            media: Option<Id>,
        }
        let r = Raw::deserialize(d)?;
        match r.kind.as_str() {
            "file" => r.path.map(|path| LUTRef::File { path }).ok_or_else(|| serde::de::Error::missing_field("path")),
            "embedded" => {
                r.media.map(|media| LUTRef::Embedded { media }).ok_or_else(|| serde::de::Error::missing_field("media"))
            }
            _ => Ok(LUTRef::Automatic),
        }
    }
}

/// Puck position of a color wheel: hue in degrees (0 = red) and amount 0...1.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct WheelValue {
    /// Degrees.
    pub hue: f32,
    /// 0...1.
    pub amount: f32,
}

/// Which maths renders a Basic Correction. Stored as its raw integer.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum BasicToneModel {
    /// Up to 2026-10-02: linear contrast about 0.45, levels-style Whites/Blacks, luma-masked Shadows/Highlights.
    Legacy = 0,
    /// Matches Premiere's Lumetri: end-point-fixed tone curves on the Rec.709 signal.
    Lumetri = 1,
}

impl BasicToneModel {
    /// What new Color effects use.
    pub const CURRENT: BasicToneModel = BasicToneModel::Lumetri;

    /// `BasicToneModel(rawValue:)`.
    pub fn from_raw(raw: i64) -> Option<BasicToneModel> {
        match raw {
            0 => Some(BasicToneModel::Legacy),
            1 => Some(BasicToneModel::Lumetri),
            _ => None,
        }
    }
}

impl Serialize for BasicToneModel {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_i64(*self as i64)
    }
}

/// Lumetri "Basic Correction". Neutral: all 0, saturation 100.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BasicCorrection {
    /// -100...100.
    pub temperature: f32,
    /// -100...100.
    pub tint: f32,
    /// -5...5 stops.
    pub exposure: f32,
    /// -100...100.
    pub contrast: f32,
    /// -100...100.
    pub highlights: f32,
    /// -100...100.
    pub shadows: f32,
    /// -100...100.
    pub whites: f32,
    /// -100...100.
    pub blacks: f32,
    /// 0...200.
    pub saturation: f32,
    /// -100...100.
    pub vibrance: f32,
    /// The maths these values are meant for (not a slider).
    pub model: BasicToneModel,
}

impl Default for BasicCorrection {
    fn default() -> Self {
        BasicCorrection {
            temperature: 0.0,
            tint: 0.0,
            exposure: 0.0,
            contrast: 0.0,
            highlights: 0.0,
            shadows: 0.0,
            whites: 0.0,
            blacks: 0.0,
            saturation: 100.0,
            vibrance: 0.0,
            model: BasicToneModel::CURRENT,
        }
    }
}

impl BasicCorrection {
    /// No slider moved (the model does not count).
    pub fn is_neutral(&self) -> bool {
        *self == BasicCorrection { model: self.model, ..BasicCorrection::default() }
    }
}

impl<'de> Deserialize<'de> for BasicCorrection {
    /// A missing `model` means the values were stored before the Lumetri maths existed: `Legacy`, unless no slider
    /// was moved. An unknown raw value falls back to `CURRENT`.
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<BasicCorrection, D::Error> {
        #[derive(Deserialize)]
        #[serde(default, rename_all = "camelCase")]
        struct Raw {
            temperature: f32,
            tint: f32,
            exposure: f32,
            contrast: f32,
            highlights: f32,
            shadows: f32,
            whites: f32,
            blacks: f32,
            saturation: f32,
            vibrance: f32,
            model: Option<serde_json::Value>,
        }
        impl Default for Raw {
            fn default() -> Raw {
                let b = BasicCorrection::default();
                Raw {
                    temperature: b.temperature,
                    tint: b.tint,
                    exposure: b.exposure,
                    contrast: b.contrast,
                    highlights: b.highlights,
                    shadows: b.shadows,
                    whites: b.whites,
                    blacks: b.blacks,
                    saturation: b.saturation,
                    vibrance: b.vibrance,
                    model: None,
                }
            }
        }
        let r = Raw::deserialize(d)?;
        let mut b = BasicCorrection {
            temperature: r.temperature,
            tint: r.tint,
            exposure: r.exposure,
            contrast: r.contrast,
            highlights: r.highlights,
            shadows: r.shadows,
            whites: r.whites,
            blacks: r.blacks,
            saturation: r.saturation,
            vibrance: r.vibrance,
            model: BasicToneModel::CURRENT,
        };
        // Swift: `if let raw = try? decodeIfPresent(Int, .model)`; anything else is the stored-before-the-model case.
        match r.model.as_ref().and_then(serde_json::Value::as_i64) {
            Some(raw) => b.model = BasicToneModel::from_raw(raw).unwrap_or(BasicToneModel::CURRENT),
            None if !b.is_neutral() => b.model = BasicToneModel::Legacy,
            None => {}
        }
        Ok(b)
    }
}

/// Lumetri "Creative": look LUT with intensity, faded film, vibrance/saturation, shadow/highlight tint.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreativeLook {
    /// `None` = none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub look: Option<LUTRef>,
    /// 0...100.
    pub intensity: f32,
    /// 0...100.
    pub faded_film: f32,
    /// -100...100.
    pub vibrance: f32,
    /// 0...200.
    pub saturation: f32,
    /// Shadow tint puck.
    pub shadow_tint: WheelValue,
    /// Highlight tint puck.
    pub highlight_tint: WheelValue,
    /// -100...100.
    pub tint_balance: f32,
}

impl Default for CreativeLook {
    fn default() -> Self {
        CreativeLook {
            look: None,
            intensity: 100.0,
            faded_film: 0.0,
            vibrance: 0.0,
            saturation: 100.0,
            shadow_tint: WheelValue::default(),
            highlight_tint: WheelValue::default(),
            tint_balance: 0.0,
        }
    }
}

/// One control point of a curve (x ascending, 0...1).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct CurvePoint {
    /// Input.
    pub x: f32,
    /// Output.
    pub y: f32,
}

fn curve(points: [(f32, f32); 2]) -> Vec<CurvePoint> {
    points.iter().map(|&(x, y)| CurvePoint { x, y }).collect()
}

/// RGB curves: master + per-channel control points. Default = the diagonal.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RGBCurves {
    /// Master curve.
    pub master: Vec<CurvePoint>,
    /// Red curve.
    pub red: Vec<CurvePoint>,
    /// Green curve.
    pub green: Vec<CurvePoint>,
    /// Blue curve.
    pub blue: Vec<CurvePoint>,
}

impl Default for RGBCurves {
    fn default() -> Self {
        let diagonal = curve([(0.0, 0.0), (1.0, 1.0)]);
        RGBCurves { master: diagonal.clone(), red: diagonal.clone(), green: diagonal.clone(), blue: diagonal }
    }
}

impl RGBCurves {
    /// Every curve is the diagonal.
    pub fn is_neutral(&self) -> bool {
        *self == RGBCurves::default()
    }
}

/// Lumetri "Color Wheels": shadows / midtones / highlights wheel + luminance slider each, and a master saturation.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ColorWheels {
    /// Shadows puck.
    pub shadows: WheelValue,
    /// Midtones puck.
    pub midtones: WheelValue,
    /// Highlights puck.
    pub highlights: WheelValue,
    /// -100...100.
    pub shadows_luma: f32,
    /// -100...100.
    pub midtones_luma: f32,
    /// -100...100.
    pub highlights_luma: f32,
    /// 0...200.
    pub saturation: f32,
}

impl Default for ColorWheels {
    fn default() -> Self {
        ColorWheels {
            shadows: WheelValue::default(),
            midtones: WheelValue::default(),
            highlights: WheelValue::default(),
            shadows_luma: 0.0,
            midtones_luma: 0.0,
            highlights_luma: 0.0,
            saturation: 100.0,
        }
    }
}

/// Lumetri "Hue Saturation Curves": five curves keyed by hue, luma or saturation; y 0.5 = no change.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HueCurves {
    /// Hue vs saturation.
    pub hue_vs_sat: Vec<CurvePoint>,
    /// Hue vs hue.
    pub hue_vs_hue: Vec<CurvePoint>,
    /// Hue vs luma.
    pub hue_vs_luma: Vec<CurvePoint>,
    /// Luma vs saturation.
    pub luma_vs_sat: Vec<CurvePoint>,
    /// Saturation vs saturation.
    pub sat_vs_sat: Vec<CurvePoint>,
}

impl Default for HueCurves {
    fn default() -> Self {
        let flat = curve([(0.0, 0.5), (1.0, 0.5)]);
        HueCurves {
            hue_vs_sat: flat.clone(),
            hue_vs_hue: flat.clone(),
            hue_vs_luma: flat.clone(),
            luma_vs_sat: flat.clone(),
            sat_vs_sat: flat,
        }
    }
}

impl HueCurves {
    /// True when every point of every curve sits on the middle line.
    pub fn is_neutral(&self) -> bool {
        [&self.hue_vs_sat, &self.hue_vs_hue, &self.hue_vs_luma, &self.luma_vs_sat, &self.sat_vs_sat]
            .iter()
            .all(|c| c.iter().all(|p| p.y == 0.5))
    }
}

/// Lumetri vignette.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Vignette {
    /// -5...5.
    pub amount: f32,
    /// 0...100.
    pub midpoint: f32,
    /// -100...100.
    pub roundness: f32,
    /// 0...100.
    pub feather: f32,
}

impl Default for Vignette {
    fn default() -> Self {
        Vignette { amount: 0.0, midpoint: 50.0, roundness: 0.0, feather: 50.0 }
    }
}

/// How the Color Range mask is picked (v94): three separate ranges, or one soft ball in the 3D color volume.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HSLMaskMode {
    /// Hue, saturation and luma ranges.
    #[default]
    Ranges,
    /// One ball in the color volume.
    Volume,
}

/// Color Range (HSL secondary, v48): picks the pixels whose hue, saturation and luma fall in a range and corrects
/// only those. Every key is optional on decode.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct HSLSecondary {
    /// How the mask is picked (v94).
    pub mask_mode: HSLMaskMode,
    /// Color volume (v94): saturation offset of the ball's center, 0...100.
    pub volume_sat: f32,
    /// Color volume (v94): luma offset of the ball's center, 0...100.
    pub volume_lum: f32,
    /// Color volume (v94): radius, 0...100.
    pub volume_radius: f32,
    /// 0..<360.
    pub hue_center: f32,
    /// 0...360; 360 = every hue.
    pub hue_width: f32,
    /// 0...100.
    pub sat_min: f32,
    /// 0...100.
    pub sat_max: f32,
    /// 0...100.
    pub lum_min: f32,
    /// 0...100.
    pub lum_max: f32,
    /// 0...100: width of the soft edge of all three ranges.
    pub softness: f32,
    /// Correct everything outside the range.
    pub invert: bool,
    /// -180...180 degrees.
    pub hue_shift: f32,
    /// 0...200, 100 = unchanged.
    pub saturation: f32,
    /// Stops.
    pub exposure: f32,
    /// -100...100.
    pub temperature: f32,
    /// -100...100.
    pub tint: f32,
}

impl Default for HSLSecondary {
    /// A new range: skin tones (orange hues, not grays), nothing corrected yet.
    fn default() -> Self {
        HSLSecondary {
            mask_mode: HSLMaskMode::Ranges,
            volume_sat: 50.0,
            volume_lum: 50.0,
            volume_radius: 25.0,
            hue_center: 25.0,
            hue_width: 50.0,
            sat_min: 10.0,
            sat_max: 100.0,
            lum_min: 0.0,
            lum_max: 100.0,
            softness: 20.0,
            invert: false,
            hue_shift: 0.0,
            saturation: 100.0,
            exposure: 0.0,
            temperature: 0.0,
            tint: 0.0,
        }
    }
}

impl HSLSecondary {
    /// The correction does nothing (the qualifier alone never changes the picture).
    pub fn is_correction_neutral(&self) -> bool {
        self.hue_shift == 0.0
            && self.saturation == 100.0
            && self.exposure == 0.0
            && self.temperature == 0.0
            && self.tint == 0.0
    }
}

impl Serialize for HSLSecondary {
    /// The color-volume keys are written only when the color volume is on, so a range-mode file stays unchanged.
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeStruct;
        let volume = self.mask_mode != HSLMaskMode::Ranges;
        let mut st = s.serialize_struct("HSLSecondary", if volume { 17 } else { 13 })?;
        st.serialize_field("hueCenter", &self.hue_center)?;
        st.serialize_field("hueWidth", &self.hue_width)?;
        st.serialize_field("satMin", &self.sat_min)?;
        st.serialize_field("satMax", &self.sat_max)?;
        st.serialize_field("lumMin", &self.lum_min)?;
        st.serialize_field("lumMax", &self.lum_max)?;
        st.serialize_field("softness", &self.softness)?;
        st.serialize_field("invert", &self.invert)?;
        st.serialize_field("hueShift", &self.hue_shift)?;
        st.serialize_field("saturation", &self.saturation)?;
        st.serialize_field("exposure", &self.exposure)?;
        st.serialize_field("temperature", &self.temperature)?;
        st.serialize_field("tint", &self.tint)?;
        if volume {
            st.serialize_field("maskMode", &self.mask_mode)?;
            st.serialize_field("volumeSat", &self.volume_sat)?;
            st.serialize_field("volumeLum", &self.volume_lum)?;
            st.serialize_field("volumeRadius", &self.volume_radius)?;
        }
        st.end()
    }
}

/// The fixed sections of one Color effect, in panel and processing order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ColorSectionKind {
    /// Basic Correction (includes the Input LUT).
    BasicCorrection,
    /// Creative.
    Creative,
    /// Curves.
    Curves,
    /// Wheels & Match.
    Wheels,
    /// Zone Board.
    ZoneBoard,
    /// Color Range.
    HslSecondary,
    /// Vignette.
    Vignette,
}

/// One "Color" effect (Premiere: one Lumetri Color). Fixed sections, each with its own enable toggle.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ColorEffect {
    /// Position in `ClipColor::effects` (1, 2, ...).
    pub id: i64,
    /// Basic Correction.
    pub basic: BasicCorrection,
    /// Input LUT inside Basic Correction. `None` = none (written as `null`).
    #[serde(rename = "inputLUT")]
    pub input_lut: Option<LUTRef>,
    /// 0...100; only used by the Input LUT of a later effect.
    #[serde(rename = "inputLUTIntensity")]
    pub input_lut_intensity: f32,
    /// Creative.
    pub creative: CreativeLook,
    /// RGB curves.
    pub curves: RGBCurves,
    /// Hue Saturation Curves; written only when not neutral.
    #[serde(skip_serializing_if = "HueCurves::is_neutral")]
    pub hue_curves: HueCurves,
    /// Color wheels.
    pub wheels: ColorWheels,
    /// Vignette.
    pub vignette: Vignette,
    /// Color Range; `None` = none.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hsl_secondary: Option<HSLSecondary>,
    /// Zone Board (v94); `None` = none.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub zone_board: Option<ZoneBoard>,
    /// Sections whose toggle is off (canonical order, so the JSON is stable); read with `disabled()`.
    #[serde(skip_serializing_if = "Vec::is_empty", deserialize_with = "canonical_sections")]
    disabled: Vec<ColorSectionKind>,
}

/// `ColorSectionKind.allCases.filter(set.contains)`: declaration order, no duplicates.
fn canonical_sections<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<ColorSectionKind>, D::Error> {
    let mut v = Vec::<ColorSectionKind>::deserialize(d)?;
    v.sort();
    v.dedup();
    Ok(v)
}

impl ColorEffect {
    /// A default effect with the given id and Input LUT.
    pub fn new(id: i64, input_lut: Option<LUTRef>) -> ColorEffect {
        ColorEffect {
            id,
            basic: BasicCorrection::default(),
            input_lut,
            input_lut_intensity: 100.0,
            creative: CreativeLook::default(),
            curves: RGBCurves::default(),
            hue_curves: HueCurves::default(),
            wheels: ColorWheels::default(),
            vignette: Vignette::default(),
            hsl_secondary: None,
            zone_board: None,
            disabled: Vec::new(),
        }
    }

    /// Sections whose toggle is off, in canonical order.
    pub fn disabled(&self) -> &[ColorSectionKind] {
        &self.disabled
    }

    /// Whether the section's toggle is on.
    pub fn is_enabled(&self, k: ColorSectionKind) -> bool {
        !self.disabled.contains(&k)
    }

    /// Switches a section on or off, keeping `disabled` canonical.
    pub fn set_enabled(&mut self, k: ColorSectionKind, on: bool) {
        if self.is_enabled(k) == on {
            return;
        }
        if on {
            self.disabled.retain(|d| *d != k);
        } else {
            self.disabled.push(k);
            self.disabled.sort();
        }
    }
}

impl Default for ColorEffect {
    /// What an empty object decodes to (`id` 1, no Input LUT).
    fn default() -> Self {
        ColorEffect::new(1, None)
    }
}

/// Static (keyframe-free) per-clip color settings: the source interpretation plus one or more Color effects applied
/// in order (always at least one).
///
/// Decoding migrates the v11 `sections` list and the v10 `correction` / LUT keys into `effects`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(from = "RawClipColor", rename_all = "camelCase")]
pub struct ClipColor {
    /// `None` = from media (`MediaInfo.colorSpace`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<ColorSpaceID>,
    /// Per-clip toggle for the embedded camera LUT (used by an `Automatic` Input LUT).
    #[serde(rename = "useEmbeddedLUT")]
    pub use_embedded_lut: bool,
    effects: Vec<ColorEffect>,
    /// How a log source is converted (v93).
    #[serde(skip_serializing_if = "is_default")]
    pub log_mode: LogMode,
    /// The space the conversion delivers (v93).
    #[serde(skip_serializing_if = "is_default")]
    pub target_space: TargetSpace,
    /// Automatic HDR/SDR conform before the grade (v93, default on).
    #[serde(skip_serializing_if = "is_true")]
    pub hdr_conform: bool,
    /// The Pro grade to render instead of `effects` (set while Pro is active; never stored).
    #[serde(skip)]
    pub graph: Option<ColorGraph>,
}

impl ClipColor {
    /// `ClipColor.defaultEffects`: one effect with an `Automatic` Input LUT.
    pub fn default_effects() -> Vec<ColorEffect> {
        vec![ColorEffect::new(1, Some(LUTRef::Automatic))]
    }

    /// A grade with the given effects (the default effects when `effects` is empty).
    pub fn new(source: Option<ColorSpaceID>, use_embedded_lut: bool, effects: Vec<ColorEffect>) -> ClipColor {
        ClipColor {
            source,
            use_embedded_lut,
            effects: if effects.is_empty() { ClipColor::default_effects() } else { effects },
            log_mode: LogMode::default(),
            target_space: TargetSpace::default(),
            hdr_conform: true,
            graph: None,
        }
    }

    /// The Color effects, never empty.
    pub fn effects(&self) -> &[ColorEffect] {
        &self.effects
    }

    /// Replaces the effects; an empty list becomes the default effects.
    pub fn set_effects(&mut self, effects: Vec<ColorEffect>) {
        self.effects = if effects.is_empty() { ClipColor::default_effects() } else { effects };
    }

    /// Edits the effects in place; an emptied list becomes the default effects (Swift `didSet`).
    pub fn edit_effects(&mut self, f: impl FnOnce(&mut Vec<ColorEffect>)) {
        f(&mut self.effects);
        if self.effects.is_empty() {
            self.effects = ClipColor::default_effects();
        }
    }
}

impl Default for ClipColor {
    fn default() -> Self {
        ClipColor::new(None, true, Vec::new())
    }
}

/// The stored keys of a `ClipColor`, current and legacy (v11 `sections`, v10 fields).
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawClipColor {
    source: Option<ColorSpaceID>,
    #[serde(rename = "useEmbeddedLUT")]
    use_embedded_lut: Option<bool>,
    effects: Option<Vec<ColorEffect>>,
    sections: Option<Vec<V11Section>>,
    log_mode: Option<LogMode>,
    target_space: Option<TargetSpace>,
    hdr_conform: Option<bool>,
    correction: Option<LegacyCorrection>,
    #[serde(default, rename = "conversionLUT", deserialize_with = "present")]
    conversion_lut: Option<Option<LUTRef>>,
    #[serde(rename = "creativeLUT")]
    creative_lut: Option<LUTRef>,
    creative_intensity: Option<f64>,
    bypass_correction: Option<bool>,
    #[serde(rename = "bypassConversionLUT")]
    bypass_conversion_lut: Option<bool>,
    #[serde(rename = "bypassCreativeLUT")]
    bypass_creative_lut: Option<bool>,
}

impl From<RawClipColor> for ClipColor {
    fn from(r: RawClipColor) -> ClipColor {
        let effects = match (r.effects, r.sections) {
            (Some(effects), _) => effects,
            (None, Some(sections)) => migrate_v11(sections),
            (None, None) => {
                let legacy = LegacyFields {
                    correction: r.correction,
                    conversion_lut: r.conversion_lut,
                    creative_lut: r.creative_lut,
                    creative_intensity: r.creative_intensity,
                    bypass_correction: r.bypass_correction,
                    bypass_conversion_lut: r.bypass_conversion_lut,
                    bypass_creative_lut: r.bypass_creative_lut,
                };
                migrate_v11(legacy.sections())
            }
        };
        let mut c = ClipColor::new(r.source, r.use_embedded_lut.unwrap_or(true), effects);
        c.log_mode = r.log_mode.unwrap_or_default();
        c.target_space = r.target_space.unwrap_or_default();
        c.hdr_conform = r.hdr_conform.unwrap_or(true);
        c
    }
}

/// v11 -> v12: the ordered block list maps into the fixed sections. The first block of each kind fills the first Color
/// effect; further blocks of a kind fill a second effect, then a third, and so on. The block order is lost.
fn migrate_v11(sections: Vec<V11Section>) -> Vec<ColorEffect> {
    let mut pool = sections;
    let mut effects: Vec<ColorEffect> = Vec::new();
    while !pool.is_empty() {
        let first = effects.is_empty();
        let mut e = ColorEffect::new(effects.len() as i64 + 1, if first { Some(LUTRef::Automatic) } else { None });
        let mut taken: Vec<&'static str> = Vec::new();
        let mut rest: Vec<V11Section> = Vec::new();
        for s in pool {
            let slot = s.params.slot();
            if taken.contains(&slot) {
                rest.push(s);
                continue;
            }
            taken.push(slot);
            match s.params {
                V11Params::InputLUT(r) => e.input_lut = if s.enabled { r.v } else { None },
                V11Params::Basic(b) => {
                    e.basic = b.v;
                    e.set_enabled(ColorSectionKind::BasicCorrection, s.enabled);
                }
                V11Params::Creative(k) => {
                    e.creative = k.v;
                    e.set_enabled(ColorSectionKind::Creative, s.enabled);
                }
                V11Params::Curves(k) => {
                    e.curves = k.v;
                    e.set_enabled(ColorSectionKind::Curves, s.enabled);
                }
                V11Params::Wheels(w) => {
                    e.wheels = w.v;
                    e.set_enabled(ColorSectionKind::Wheels, s.enabled);
                }
                V11Params::Vignette(v) => {
                    e.vignette = v.v;
                    e.set_enabled(ColorSectionKind::Vignette, s.enabled);
                }
            }
        }
        // The Basic toggle now gates the Input LUT too: a bypassed Basic with a live LUT keeps the LUT (the bypassed
        // slider values are dropped) so the picture does not change.
        if !e.is_enabled(ColorSectionKind::BasicCorrection) && e.input_lut.is_some() {
            e.basic = BasicCorrection::default();
            e.set_enabled(ColorSectionKind::BasicCorrection, true);
        }
        effects.push(e);
        pool = rest;
    }
    effects
}

/// The v10 single correction + conversion LUT + creative LUT keys.
struct LegacyFields {
    correction: Option<LegacyCorrection>,
    conversion_lut: Option<Option<LUTRef>>,
    creative_lut: Option<LUTRef>,
    creative_intensity: Option<f64>,
    bypass_correction: Option<bool>,
    bypass_conversion_lut: Option<bool>,
    bypass_creative_lut: Option<bool>,
}

impl LegacyFields {
    /// The v10 fields as v11-style blocks in the old order (Basic Correction, Input LUT, Creative). A bypassed
    /// legacy slot becomes a disabled block.
    fn sections(self) -> Vec<V11Section> {
        let mut b = BasicCorrection { model: BasicToneModel::Legacy, ..BasicCorrection::default() };
        if let Some(old) = self.correction {
            b.temperature = old.temperature;
            b.tint = old.tint;
            b.exposure = old.exposure.clamp(-5.0, 5.0);
            b.contrast = old.contrast;
            b.highlights = old.highlights;
            b.shadows = old.shadows;
            b.saturation = old.saturation;
        }
        if b.is_neutral() {
            b.model = BasicToneModel::CURRENT;
        }
        // An absent key = default (`Automatic`); an explicit "none" is stored as JSON null.
        let conv = self.conversion_lut.unwrap_or(Some(LUTRef::Automatic));
        let mut out = vec![
            V11Section { enabled: !self.bypass_correction.unwrap_or(false), params: V11Params::Basic(Wrap { v: b }) },
            V11Section {
                enabled: !self.bypass_conversion_lut.unwrap_or(false),
                params: V11Params::InputLUT(Wrap { v: conv }),
            },
        ];
        if let Some(look) = self.creative_lut.filter(|l| *l != LUTRef::Automatic) {
            let cl = CreativeLook {
                look: Some(look),
                intensity: (self.creative_intensity.unwrap_or(1.0).clamp(0.0, 1.0) as f32) * 100.0,
                ..CreativeLook::default()
            };
            out.push(V11Section {
                enabled: !self.bypass_creative_lut.unwrap_or(false),
                params: V11Params::Creative(Wrap { v: cl }),
            });
        }
        out
    }
}

/// A v11 block (decode only). Shape matches the v11 encoding (its params were a synthesized enum). `id` is not read.
#[derive(Deserialize)]
struct V11Section {
    enabled: bool,
    params: V11Params,
}

/// The associated value of a synthesized enum case: `{"_0": value}`.
#[derive(Deserialize)]
struct Wrap<T: Default> {
    #[serde(rename = "_0", default)]
    v: T,
}

#[derive(Deserialize)]
enum V11Params {
    #[serde(rename = "inputLUT")]
    InputLUT(Wrap<Option<LUTRef>>),
    #[serde(rename = "basic")]
    Basic(Wrap<BasicCorrection>),
    #[serde(rename = "creative")]
    Creative(Wrap<CreativeLook>),
    #[serde(rename = "curves")]
    Curves(Wrap<RGBCurves>),
    #[serde(rename = "wheels")]
    Wheels(Wrap<ColorWheels>),
    #[serde(rename = "vignette")]
    Vignette(Wrap<Vignette>),
}

impl V11Params {
    fn slot(&self) -> &'static str {
        match self {
            V11Params::InputLUT(_) => "lut",
            V11Params::Basic(_) => "basic",
            V11Params::Creative(_) => "creative",
            V11Params::Curves(_) => "curves",
            V11Params::Wheels(_) => "wheels",
            V11Params::Vignette(_) => "vignette",
        }
    }
}

/// The v10 correction object (decode only).
#[derive(Deserialize)]
#[serde(default)]
struct LegacyCorrection {
    temperature: f32,
    tint: f32,
    exposure: f32,
    contrast: f32,
    highlights: f32,
    shadows: f32,
    saturation: f32,
}

impl Default for LegacyCorrection {
    fn default() -> Self {
        LegacyCorrection {
            temperature: 0.0,
            tint: 0.0,
            exposure: 0.0,
            contrast: 0.0,
            highlights: 0.0,
            shadows: 0.0,
            saturation: 100.0,
        }
    }
}

/// Test helpers shared by the saved-type tests of this crate.
#[cfg(test)]
pub(crate) mod test_util {
    use serde::{Serialize, de::DeserializeOwned};
    use serde_json::Value;

    /// Numbers compare by value at `f32` precision (`1` and `1.0` are the same JSON number to Swift's decoder, and
    /// the grade fields are `Float`).
    fn norm(v: Value) -> Value {
        match v {
            Value::Number(n) => serde_json::json!(n.as_f64().map(|x| f64::from(x as f32))),
            Value::Array(a) => Value::Array(a.into_iter().map(norm).collect()),
            Value::Object(o) => Value::Object(o.into_iter().map(|(k, v)| (k, norm(v))).collect()),
            other => other,
        }
    }

    /// Parses `json`.
    pub(crate) fn parse(json: &str) -> Value {
        norm(serde_json::from_str(json).expect("test sample is valid JSON"))
    }

    /// Encodes `v` and normalizes the numbers.
    pub(crate) fn encode<T: Serialize>(v: &T) -> Value {
        norm(serde_json::to_value(v).expect("encodes"))
    }

    /// Decodes `json`, encodes it again and checks the result equals the input as a parsed JSON value.
    pub(crate) fn round_trip<T: Serialize + DeserializeOwned>(json: &str) -> T {
        let v: T = serde_json::from_str(json).expect("decodes");
        assert_eq!(encode(&v), parse(json));
        v
    }

    /// Decodes `json` (no round trip: for inputs the encoder would write differently).
    pub(crate) fn decode<T: DeserializeOwned>(json: &str) -> T {
        serde_json::from_str(json).expect("decodes")
    }
}

#[cfg(test)]
mod tests {
    use super::test_util::{decode, encode, parse, round_trip};
    use super::*;

    const DIAG: &str = r#"[{"x":0,"y":0},{"x":1,"y":1}]"#;

    /// A `ColorEffect` as Swift's encoder writes it for `ColorEffect(id: 1, inputLUT: .automatic)`.
    fn effect_json(id: i64, input_lut: &str) -> String {
        format!(
            r#"{{"id":{id},"basic":{{"temperature":0,"tint":0,"exposure":0,"contrast":0,"highlights":0,"shadows":0,
            "whites":0,"blacks":0,"saturation":100,"vibrance":0,"model":1}},"inputLUT":{input_lut},"inputLUTIntensity":100,
            "creative":{{"intensity":100,"fadedFilm":0,"vibrance":0,"saturation":100,"shadowTint":{{"hue":0,"amount":0}},
            "highlightTint":{{"hue":0,"amount":0}},"tintBalance":0}},
            "curves":{{"master":{DIAG},"red":{DIAG},"green":{DIAG},"blue":{DIAG}}},
            "wheels":{{"shadows":{{"hue":0,"amount":0}},"midtones":{{"hue":0,"amount":0}},"highlights":{{"hue":0,"amount":0}},
            "shadowsLuma":0,"midtonesLuma":0,"highlightsLuma":0,"saturation":100}},
            "vignette":{{"amount":0,"midpoint":50,"roundness":0,"feather":50}}}}"#
        )
    }

    #[test]
    fn lut_refs_round_trip() {
        assert_eq!(round_trip::<LUTRef>(r#"{"kind":"automatic"}"#), LUTRef::Automatic);
        assert_eq!(
            round_trip::<LUTRef>(r#"{"kind":"file","path":"/a/b.cube"}"#),
            LUTRef::File { path: "/a/b.cube".into() }
        );
        let id = "6F9619FF-8B86-D011-B42D-00C04FC964FF";
        let e = round_trip::<LUTRef>(&format!(r#"{{"kind":"embedded","media":"{id}"}}"#));
        assert_eq!(e, LUTRef::Embedded { media: Id::parse(id).unwrap() });
    }

    #[test]
    fn unknown_lut_kind_reads_as_automatic() {
        assert_eq!(decode::<LUTRef>(r#"{"kind":"hdr10"}"#), LUTRef::Automatic);
    }

    #[test]
    fn color_space_names_are_the_swift_raw_values() {
        for name in [
            "rec709",
            "sLog3SGamut3Cine",
            "hlgBT2020",
            "pqBT2020",
            "vLogVGamut",
            "appleLog",
            "dLogDGamut",
            "canonLogCinemaGamut",
            "canonLogBT2020",
            "canonLogBT709",
            "canonLog2CinemaGamut",
            "canonLog2BT2020",
            "canonLog2BT709",
            "canonLog3CinemaGamut",
            "canonLog3BT2020",
            "canonLog3BT709",
            "logC3WideGamut3",
            "logC4WideGamut4",
            "log3G10RedWideGamut",
            "bmdFilmGen5WideGamut",
            "nLogBT2020",
            "fLog2FGamutC",
            "acesCCTAP1",
        ] {
            round_trip::<ColorSpaceID>(&format!("\"{name}\""));
        }
    }

    #[test]
    fn basic_without_model_is_legacy_when_a_slider_moved() {
        let b = decode::<BasicCorrection>(r#"{"temperature":10,"saturation":120}"#);
        assert_eq!(b.model, BasicToneModel::Legacy);
        assert_eq!((b.temperature, b.saturation, b.vibrance), (10.0, 120.0, 0.0));
    }

    #[test]
    fn basic_without_model_is_current_when_neutral() {
        assert_eq!(decode::<BasicCorrection>("{}").model, BasicToneModel::Lumetri);
    }

    #[test]
    fn basic_unknown_model_falls_back_to_current() {
        assert_eq!(decode::<BasicCorrection>(r#"{"exposure":1,"model":9}"#).model, BasicToneModel::Lumetri);
    }

    #[test]
    fn basic_round_trips_with_model() {
        let b = round_trip::<BasicCorrection>(
            r#"{"temperature":5,"tint":-3,"exposure":0.5,"contrast":1,"highlights":2,"shadows":3,"whites":4,"blacks":5,
            "saturation":90,"vibrance":7,"model":0}"#,
        );
        assert_eq!(b.model, BasicToneModel::Legacy);
        assert!(!b.is_neutral());
    }

    #[test]
    fn creative_look_keeps_look_optional_and_rest_required() {
        let j = r#"{"look":{"kind":"file","path":"x.cube"},"intensity":50,"fadedFilm":1,"vibrance":2,"saturation":99,
            "shadowTint":{"hue":10,"amount":0.5},"highlightTint":{"hue":0,"amount":0},"tintBalance":3}"#;
        assert!(round_trip::<CreativeLook>(j).look.is_some());
        assert!(serde_json::from_str::<CreativeLook>(r#"{"look":null,"intensity":1}"#).is_err());
    }

    #[test]
    fn hsl_secondary_range_mode_writes_no_volume_keys() {
        let j = r#"{"hueCenter":25,"hueWidth":50,"satMin":10,"satMax":100,"lumMin":0,"lumMax":100,"softness":20,
            "invert":false,"hueShift":0,"saturation":100,"exposure":0,"temperature":0,"tint":0}"#;
        assert_eq!(round_trip::<HSLSecondary>(j), HSLSecondary::default());
    }

    #[test]
    fn hsl_secondary_volume_mode_round_trips_and_missing_keys_default() {
        let j = r#"{"hueCenter":30,"hueWidth":40,"satMin":10,"satMax":100,"lumMin":0,"lumMax":100,"softness":20,
            "invert":true,"hueShift":5,"saturation":100,"exposure":0.5,"temperature":0,"tint":0,
            "maskMode":"volume","volumeSat":60,"volumeLum":40,"volumeRadius":30}"#;
        let h = round_trip::<HSLSecondary>(j);
        assert_eq!(h.mask_mode, HSLMaskMode::Volume);
        assert_eq!(decode::<HSLSecondary>(r#"{"hueShift":12}"#).softness, 20.0);
    }

    #[test]
    fn color_effect_round_trips() {
        let j = effect_json(1, r#"{"kind":"automatic"}"#);
        let e = round_trip::<ColorEffect>(&j);
        assert_eq!(e, ColorEffect::new(1, Some(LUTRef::Automatic)));
    }

    #[test]
    fn color_effect_absent_input_lut_is_none_and_null_is_written() {
        let e = decode::<ColorEffect>("{}");
        assert_eq!((e.id, e.input_lut.clone()), (1, None));
        assert_eq!(encode(&e)["inputLUT"], serde_json::Value::Null);
        round_trip::<ColorEffect>(&effect_json(2, "null"));
    }

    #[test]
    fn color_effect_disabled_is_canonical() {
        let e = decode::<ColorEffect>(r#"{"disabled":["vignette","creative","vignette"]}"#);
        assert_eq!(e.disabled(), [ColorSectionKind::Creative, ColorSectionKind::Vignette]);
        assert!(!e.is_enabled(ColorSectionKind::Creative));
        assert_eq!(encode(&e)["disabled"], parse(r#"["creative","vignette"]"#));
    }

    #[test]
    fn set_enabled_keeps_section_order() {
        let mut e = ColorEffect::new(1, None);
        e.set_enabled(ColorSectionKind::Vignette, false);
        e.set_enabled(ColorSectionKind::BasicCorrection, false);
        assert_eq!(e.disabled(), [ColorSectionKind::BasicCorrection, ColorSectionKind::Vignette]);
        e.set_enabled(ColorSectionKind::Vignette, true);
        assert_eq!(e.disabled(), [ColorSectionKind::BasicCorrection]);
    }

    #[test]
    fn color_effect_writes_hue_curves_only_when_not_neutral() {
        let mut e = ColorEffect::new(1, None);
        assert!(encode(&e).get("hueCurves").is_none());
        e.hue_curves.hue_vs_sat[0].y = 0.7;
        assert!(encode(&e).get("hueCurves").is_some());
    }

    #[test]
    fn clip_color_current_form_round_trips() {
        let j = format!(
            r#"{{"source":"hlgBT2020","useEmbeddedLUT":false,"effects":[{}],"logMode":"builtIn","targetSpace":"rec2020PQ",
            "hdrConform":false}}"#,
            effect_json(1, r#"{"kind":"automatic"}"#)
        );
        let c = round_trip::<ClipColor>(&j);
        assert_eq!(
            (c.source, c.log_mode, c.target_space, c.hdr_conform),
            (Some(ColorSpaceID::HlgBT2020), LogMode::BuiltIn, TargetSpace::Rec2020PQ, false)
        );
    }

    #[test]
    fn clip_color_omits_default_v93_keys_and_the_graph() {
        let j = format!(r#"{{"useEmbeddedLUT":true,"effects":[{}]}}"#, effect_json(1, r#"{"kind":"automatic"}"#));
        let mut c = round_trip::<ClipColor>(&j);
        assert_eq!(c, ClipColor::default());
        c.graph = Some(ColorGraph::new(Vec::new(), None, None, Id::NIL));
        assert_eq!(encode(&c), parse(&j));
    }

    #[test]
    fn clip_color_empty_object_is_the_default_grade() {
        assert_eq!(decode::<ClipColor>("{}"), ClipColor::default());
    }

    #[test]
    fn clip_color_empty_effects_become_the_default_effects() {
        let c = decode::<ClipColor>(r#"{"effects":[]}"#);
        assert_eq!(c.effects(), ClipColor::default_effects());
    }

    #[test]
    fn clip_color_v11_sections_migrate_into_effects() {
        let c = decode::<ClipColor>(
            r#"{"source":"rec709","sections":[
              {"id":1,"enabled":true,"params":{"basic":{"_0":{"temperature":10,"model":1}}}},
              {"id":2,"enabled":true,"params":{"inputLUT":{"_0":{"kind":"file","path":"a.cube"}}}},
              {"id":3,"enabled":false,"params":{"vignette":{"_0":{"amount":1,"midpoint":50,"roundness":0,"feather":50}}}},
              {"id":4,"enabled":true,"params":{"basic":{"_0":{"tint":4,"model":1}}}}]}"#,
        );
        assert_eq!(c.effects().len(), 2);
        let first = &c.effects()[0];
        assert_eq!(first.basic.temperature, 10.0);
        assert_eq!(first.input_lut, Some(LUTRef::File { path: "a.cube".into() }));
        assert_eq!(first.disabled(), [ColorSectionKind::Vignette]);
        // The second Basic block fills a second effect, whose Input LUT is none.
        assert_eq!((c.effects()[1].id, c.effects()[1].basic.tint, c.effects()[1].input_lut.clone()), (2, 4.0, None));
    }

    #[test]
    fn clip_color_v11_bypassed_basic_with_live_lut_is_reset_and_enabled() {
        let c = decode::<ClipColor>(
            r#"{"sections":[{"id":1,"enabled":false,"params":{"basic":{"_0":{"temperature":10,"model":1}}}},
              {"id":2,"enabled":true,"params":{"inputLUT":{}}}]}"#,
        );
        // `inputLUT` without `_0` is none, so the bypassed Basic stays off.
        assert!(!c.effects()[0].is_enabled(ColorSectionKind::BasicCorrection));
        let c = decode::<ClipColor>(
            r#"{"sections":[{"id":1,"enabled":false,"params":{"basic":{"_0":{"temperature":10,"model":1}}}},
              {"id":2,"enabled":true,"params":{"inputLUT":{"_0":{"kind":"automatic"}}}}]}"#,
        );
        assert!(c.effects()[0].is_enabled(ColorSectionKind::BasicCorrection));
        assert_eq!(c.effects()[0].basic.temperature, 0.0);
    }

    #[test]
    fn clip_color_v10_fields_migrate_into_one_effect() {
        let c = decode::<ClipColor>(
            r#"{"correction":{"temperature":20,"exposure":9},"bypassConversionLUT":true,
            "creativeLUT":{"kind":"file","path":"look.cube"},"creativeIntensity":0.5}"#,
        );
        let e = &c.effects()[0];
        assert_eq!((e.basic.temperature, e.basic.exposure, e.basic.model), (20.0, 5.0, BasicToneModel::Legacy));
        assert_eq!(e.creative.look, Some(LUTRef::File { path: "look.cube".into() }));
        assert_eq!(e.creative.intensity, 50.0);
        // The bypassed conversion LUT slot is a disabled block: no Input LUT.
        assert_eq!(e.input_lut, None);
    }

    #[test]
    fn clip_color_v10_explicit_null_conversion_lut_means_none() {
        let c = decode::<ClipColor>(r#"{"conversionLUT":null}"#);
        assert_eq!(c.effects()[0].input_lut, None);
        let c = decode::<ClipColor>(r#"{"correction":{}}"#);
        assert_eq!(c.effects()[0].input_lut, Some(LUTRef::Automatic));
    }
}
