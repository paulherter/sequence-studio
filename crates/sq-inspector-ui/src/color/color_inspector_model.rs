// Swift: Color/ColorInspectorModel.swift
//! State of the Color inspector for one clip: the clip's `ClipColor` plus UI-only state (which sections are open).
//! All edits go through here and are reported as [`ColorInspectorEvent`]s (Swift `onChange` and friends); gestures
//! (`GestureBegan`/`GestureEnded`) make one undo step. The host drains `events` after every call.

use sq_core_color::{ClipColorExt, ClipGradeExt, ColorSectionKindExt, MediaInfoColorExt, auto_tone_solver};
use sq_core_model::lut_space_hint;
use sq_core_model::{
    BasicCorrection, BasicToneModel, Clip, ClipColor, ClipEffect, ColorEffect, ColorGraph, ColorSectionKind,
    ColorSpaceID, CurvePoint, HueCurves, LUTRef, LogMode, MediaInfo, RGBCurves, TargetSpace, WheelValue,
};
use sq_core_time::{Id, IdSource, Time};
use sq_library::lutlibrary::LUTEntry;
use sq_uikit::keyframe_control_state::KeyframeControlState;
use std::collections::{BTreeMap, BTreeSet, HashMap};

/// One slider of the color panel: title, range, neutral value and where it lives in a Color effect.
/// Ranges and neutrals follow Lumetri (the design notes 2026-10-01).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum ColorParam {
    // Basic Correction
    Temperature,
    Tint,
    Exposure,
    Contrast,
    Highlights,
    Shadows,
    Whites,
    Blacks,
    Saturation,
    Vibrance,
    InputLUTIntensity,
    // Creative
    LookIntensity,
    FadedFilm,
    CreativeVibrance,
    CreativeSaturation,
    TintBalance,
    // Color Wheels (master saturation)
    WheelsSaturation,
    // Vignette
    VignetteAmount,
    VignetteMidpoint,
    VignetteRoundness,
    VignetteFeather,
}

/// The two-color track behind a slider (Temperature blue -> orange, Tint green -> magenta).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ColorTrack {
    Plain,
    Temperature,
    Tint,
    Saturation,
}

impl ColorParam {
    /// Swift `allCases`.
    pub const ALL: [ColorParam; 21] = [
        ColorParam::Temperature,
        ColorParam::Tint,
        ColorParam::Exposure,
        ColorParam::Contrast,
        ColorParam::Highlights,
        ColorParam::Shadows,
        ColorParam::Whites,
        ColorParam::Blacks,
        ColorParam::Saturation,
        ColorParam::Vibrance,
        ColorParam::InputLUTIntensity,
        ColorParam::LookIntensity,
        ColorParam::FadedFilm,
        ColorParam::CreativeVibrance,
        ColorParam::CreativeSaturation,
        ColorParam::TintBalance,
        ColorParam::WheelsSaturation,
        ColorParam::VignetteAmount,
        ColorParam::VignetteMidpoint,
        ColorParam::VignetteRoundness,
        ColorParam::VignetteFeather,
    ];

    pub fn title(self) -> &'static str {
        use ColorParam::*;
        match self {
            Temperature => "Temperature",
            Tint => "Tint",
            Exposure => "Exposure",
            Contrast => "Contrast",
            Highlights => "Highlights",
            Shadows => "Shadows",
            Whites => "Whites",
            Blacks => "Blacks",
            Saturation | CreativeSaturation | WheelsSaturation => "Saturation",
            Vibrance | CreativeVibrance => "Vibrance",
            LookIntensity | InputLUTIntensity => "Intensity",
            FadedFilm => "Fade",
            TintBalance => "Tint Mix",
            VignetteAmount => "Amount",
            VignetteMidpoint => "Midpoint",
            VignetteRoundness => "Roundness",
            VignetteFeather => "Feather",
        }
    }

    pub fn section(self) -> ColorSectionKind {
        use ColorParam::*;
        match self {
            Temperature | Tint | Exposure | Contrast | Highlights | Shadows | Whites | Blacks | Saturation
            | Vibrance | InputLUTIntensity => ColorSectionKind::BasicCorrection,
            LookIntensity | FadedFilm | CreativeVibrance | CreativeSaturation | TintBalance => {
                ColorSectionKind::Creative
            }
            WheelsSaturation => ColorSectionKind::Wheels,
            VignetteAmount | VignetteMidpoint | VignetteRoundness | VignetteFeather => ColorSectionKind::Vignette,
        }
    }

    /// Lower and upper bound of the slider.
    pub fn range(self) -> (f32, f32) {
        use ColorParam::*;
        match self {
            Exposure | VignetteAmount => (-5.0, 5.0),
            Saturation | CreativeSaturation | WheelsSaturation => (0.0, 200.0),
            LookIntensity | InputLUTIntensity | FadedFilm | VignetteMidpoint | VignetteFeather => (0.0, 100.0),
            _ => (-100.0, 100.0),
        }
    }

    pub fn neutral(self) -> f32 {
        use ColorParam::*;
        match self {
            Saturation | CreativeSaturation | WheelsSaturation | LookIntensity | InputLUTIntensity => 100.0,
            VignetteMidpoint | VignetteFeather => 50.0,
            _ => 0.0,
        }
    }

    /// Decimals shown (Premiere shows one).
    pub fn decimals(self) -> i64 {
        if self == ColorParam::Exposure || self == ColorParam::VignetteAmount { 2 } else { 1 }
    }

    pub fn track(self) -> ColorTrack {
        use ColorParam::*;
        match self {
            Temperature => ColorTrack::Temperature,
            Tint => ColorTrack::Tint,
            Saturation | Vibrance | CreativeVibrance => ColorTrack::Saturation,
            _ => ColorTrack::Plain,
        }
    }

    /// Rows of each section in display order (version 9: Basic is Temperature, Tint, Exposure, Contrast, Highlights,
    /// Shadows; Creative is Vibrance, Saturation, Fade). The rows version 9 does not have follow at the end of their
    /// section. The LUT pills, intensities, the White Balance picker and the wheels are added by the view around these.
    pub fn layout(kind: ColorSectionKind) -> Vec<(Option<&'static str>, Vec<ColorParam>)> {
        use ColorParam::*;
        match kind {
            ColorSectionKind::BasicCorrection => vec![
                (Some("Color"), vec![Temperature, Tint]),
                (Some("Light"), vec![Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Saturation, Vibrance]),
            ],
            ColorSectionKind::Creative => {
                vec![(Some("Adjustments"), vec![CreativeVibrance, CreativeSaturation, FadedFilm, TintBalance])]
            }
            ColorSectionKind::Wheels => vec![(None, vec![WheelsSaturation])],
            ColorSectionKind::Vignette => {
                vec![(None, vec![VignetteAmount, VignetteMidpoint, VignetteRoundness, VignetteFeather])]
            }
            ColorSectionKind::Curves | ColorSectionKind::HslSecondary | ColorSectionKind::ZoneBoard => Vec::new(),
        }
    }

    pub fn read(self, e: &ColorEffect) -> f32 {
        use ColorParam::*;
        match self {
            Temperature => e.basic.temperature,
            Tint => e.basic.tint,
            Exposure => e.basic.exposure,
            Contrast => e.basic.contrast,
            Highlights => e.basic.highlights,
            Shadows => e.basic.shadows,
            Whites => e.basic.whites,
            Blacks => e.basic.blacks,
            Saturation => e.basic.saturation,
            Vibrance => e.basic.vibrance,
            InputLUTIntensity => e.input_lut_intensity,
            LookIntensity => e.creative.intensity,
            FadedFilm => e.creative.faded_film,
            CreativeVibrance => e.creative.vibrance,
            CreativeSaturation => e.creative.saturation,
            TintBalance => e.creative.tint_balance,
            WheelsSaturation => e.wheels.saturation,
            VignetteAmount => e.vignette.amount,
            VignetteMidpoint => e.vignette.midpoint,
            VignetteRoundness => e.vignette.roundness,
            VignetteFeather => e.vignette.feather,
        }
    }

    /// Clamps to `range` and writes.
    pub fn write(self, value: f32, e: &mut ColorEffect) {
        use ColorParam::*;
        let (lo, hi) = self.range();
        let v = value.max(lo).min(hi);
        match self {
            Temperature => e.basic.temperature = v,
            Tint => e.basic.tint = v,
            Exposure => e.basic.exposure = v,
            Contrast => e.basic.contrast = v,
            Highlights => e.basic.highlights = v,
            Shadows => e.basic.shadows = v,
            Whites => e.basic.whites = v,
            Blacks => e.basic.blacks = v,
            Saturation => e.basic.saturation = v,
            Vibrance => e.basic.vibrance = v,
            InputLUTIntensity => e.input_lut_intensity = v,
            LookIntensity => e.creative.intensity = v,
            FadedFilm => e.creative.faded_film = v,
            CreativeVibrance => e.creative.vibrance = v,
            CreativeSaturation => e.creative.saturation = v,
            TintBalance => e.creative.tint_balance = v,
            WheelsSaturation => e.wheels.saturation = v,
            VignetteAmount => e.vignette.amount = v,
            VignetteMidpoint => e.vignette.midpoint = v,
            VignetteRoundness => e.vignette.roundness = v,
            VignetteFeather => e.vignette.feather = v,
        }
    }

    /// The Color effect parameter this slider writes (`ClipEffect.color…Key`).
    pub fn parameter_key(self) -> &'static str {
        use ColorParam::*;
        match self {
            Temperature => ClipEffect::COLOR_TEMPERATURE_KEY,
            Tint => ClipEffect::COLOR_TINT_KEY,
            Exposure => ClipEffect::COLOR_EXPOSURE_KEY,
            Contrast => ClipEffect::COLOR_CONTRAST_KEY,
            Highlights => ClipEffect::COLOR_HIGHLIGHTS_KEY,
            Shadows => ClipEffect::COLOR_SHADOWS_KEY,
            Whites => ClipEffect::COLOR_WHITES_KEY,
            Blacks => ClipEffect::COLOR_BLACKS_KEY,
            Saturation => ClipEffect::COLOR_SATURATION_KEY,
            Vibrance => ClipEffect::COLOR_VIBRANCE_KEY,
            InputLUTIntensity => ClipEffect::COLOR_INPUT_LUT_INTENSITY_KEY,
            LookIntensity => ClipEffect::COLOR_LOOK_INTENSITY_KEY,
            FadedFilm => ClipEffect::COLOR_FADED_FILM_KEY,
            CreativeVibrance => ClipEffect::COLOR_CREATIVE_VIBRANCE_KEY,
            CreativeSaturation => ClipEffect::COLOR_CREATIVE_SATURATION_KEY,
            TintBalance => ClipEffect::COLOR_TINT_BALANCE_KEY,
            WheelsSaturation => ClipEffect::COLOR_WHEEL_SATURATION_KEY,
            VignetteAmount => ClipEffect::COLOR_VIGNETTE_AMOUNT_KEY,
            VignetteMidpoint => ClipEffect::COLOR_VIGNETTE_MIDPOINT_KEY,
            VignetteRoundness => ClipEffect::COLOR_VIGNETTE_ROUNDNESS_KEY,
            VignetteFeather => ClipEffect::COLOR_VIGNETTE_FEATHER_KEY,
        }
    }

    /// Unambiguous name for tooltips and undo ("Animate Look Intensity"): the row titles repeat across sections.
    pub fn keyframe_name(self) -> String {
        use ColorParam::*;
        match self {
            InputLUTIntensity => "Source LUT Intensity".to_string(),
            LookIntensity => "Look Intensity".to_string(),
            CreativeVibrance => "Creative Vibrance".to_string(),
            CreativeSaturation => "Creative Saturation".to_string(),
            WheelsSaturation => "Wheels Saturation".to_string(),
            VignetteAmount | VignetteMidpoint | VignetteRoundness | VignetteFeather => {
                format!("Vignette {}", self.title())
            }
            _ => self.title().to_string(),
        }
    }
}

/// The five Hue Saturation Curves of the Curves section (Premiere's tabs).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum HueCurveKind {
    HueVsSat,
    HueVsHue,
    HueVsLuma,
    LumaVsSat,
    SatVsSat,
}

impl HueCurveKind {
    /// Swift `allCases`.
    pub const ALL: [HueCurveKind; 5] = [
        HueCurveKind::HueVsSat,
        HueCurveKind::HueVsHue,
        HueCurveKind::HueVsLuma,
        HueCurveKind::LumaVsSat,
        HueCurveKind::SatVsSat,
    ];

    /// Swift `rawValue`.
    pub fn raw_value(self) -> i64 {
        self as i64
    }

    pub fn title(self) -> &'static str {
        match self {
            HueCurveKind::HueVsSat => "Hue vs Sat",
            HueCurveKind::HueVsHue => "Hue vs Hue",
            HueCurveKind::HueVsLuma => "Hue vs Luma",
            HueCurveKind::LumaVsSat => "Luma vs Sat",
            HueCurveKind::SatVsSat => "Sat vs Sat",
        }
    }

    /// One line on what the curve reads and changes (shown as the tooltip of the curve plot and its popup).
    pub fn explanation(self) -> &'static str {
        match self {
            HueCurveKind::HueVsSat => {
                "Hue vs Sat: raise or lower the saturation of one hue. The x axis is the hue, the middle line is no change."
            }
            HueCurveKind::HueVsHue => {
                "Hue vs Hue: shift one hue towards its neighbors. The x axis is the hue, the middle line is no change."
            }
            HueCurveKind::HueVsLuma => {
                "Hue vs Luma: brighten or darken one hue. The x axis is the hue, the middle line is no change."
            }
            HueCurveKind::LumaVsSat => {
                "Luma vs Sat: change the saturation of shadows, midtones or highlights. The x axis is brightness."
            }
            HueCurveKind::SatVsSat => {
                "Sat vs Sat: change colors by how saturated they already are. The x axis is saturation."
            }
        }
    }

    /// The hue-keyed curves wrap around and show a hue strip under the plot.
    pub fn is_hue_keyed(self) -> bool {
        self.raw_value() <= HueCurveKind::HueVsLuma.raw_value()
    }

    pub fn points(self, h: &HueCurves) -> Vec<CurvePoint> {
        match self {
            HueCurveKind::HueVsSat => h.hue_vs_sat.clone(),
            HueCurveKind::HueVsHue => h.hue_vs_hue.clone(),
            HueCurveKind::HueVsLuma => h.hue_vs_luma.clone(),
            HueCurveKind::LumaVsSat => h.luma_vs_sat.clone(),
            HueCurveKind::SatVsSat => h.sat_vs_sat.clone(),
        }
    }

    /// Hue-keyed curves wrap around the color wheel, so their first and last point are the same place: when one of
    /// them moved vertically the other follows (an edit of the last point wins when both changed).
    pub fn wrapped(self, pts: &[CurvePoint], previous: &[CurvePoint]) -> Vec<CurvePoint> {
        let mut new = pts.to_vec();
        if !self.is_hue_keyed() || new.len() < 2 {
            return new;
        }
        let last = new.len() - 1;
        if let (Some(lo), Some(hi), true) = (previous.first(), previous.last(), previous.len() >= 2) {
            if new[last].y != hi.y {
                new[0].y = new[last].y;
            } else if new[0].y != lo.y {
                new[last].y = new[0].y;
            }
        } else {
            new[last].y = new[0].y;
        }
        new
    }

    pub fn set(self, pts: Vec<CurvePoint>, h: &mut HueCurves) {
        match self {
            HueCurveKind::HueVsSat => h.hue_vs_sat = pts,
            HueCurveKind::HueVsHue => h.hue_vs_hue = pts,
            HueCurveKind::HueVsLuma => h.hue_vs_luma = pts,
            HueCurveKind::LumaVsSat => h.luma_vs_sat = pts,
            HueCurveKind::SatVsSat => h.sat_vs_sat = pts,
        }
    }
}

/// A color wheel in the panel: the three wheels of Color Wheels, or the tints of Creative.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ColorWheelSlot {
    // Color Wheels
    Shadows,
    Midtones,
    Highlights,
    // Creative
    ShadowTint,
    HighlightTint,
}

impl ColorWheelSlot {
    /// Swift `allCases`.
    pub const ALL: [ColorWheelSlot; 5] = [
        ColorWheelSlot::Shadows,
        ColorWheelSlot::Midtones,
        ColorWheelSlot::Highlights,
        ColorWheelSlot::ShadowTint,
        ColorWheelSlot::HighlightTint,
    ];

    pub fn title(self) -> &'static str {
        match self {
            ColorWheelSlot::Shadows => "Shadows",
            ColorWheelSlot::Midtones => "Midtones",
            ColorWheelSlot::Highlights => "Highlights",
            ColorWheelSlot::ShadowTint => "Shadow Tint",
            ColorWheelSlot::HighlightTint => "Highlight Tint",
        }
    }

    /// Only the three-way wheels carry a luminance slider.
    pub fn has_luma(self) -> bool {
        (self as i64) <= ColorWheelSlot::Highlights as i64
    }

    /// The parameters the wheel's keyframe control animates together: hue, amount and (three-way wheels) luma.
    pub fn parameter_keys(self) -> Vec<&'static str> {
        match self {
            ColorWheelSlot::Shadows => vec![
                ClipEffect::COLOR_WHEEL_SHADOWS_HUE_KEY,
                ClipEffect::COLOR_WHEEL_SHADOWS_AMOUNT_KEY,
                ClipEffect::COLOR_WHEEL_SHADOWS_LUMA_KEY,
            ],
            ColorWheelSlot::Midtones => vec![
                ClipEffect::COLOR_WHEEL_MIDTONES_HUE_KEY,
                ClipEffect::COLOR_WHEEL_MIDTONES_AMOUNT_KEY,
                ClipEffect::COLOR_WHEEL_MIDTONES_LUMA_KEY,
            ],
            ColorWheelSlot::Highlights => vec![
                ClipEffect::COLOR_WHEEL_HIGHLIGHTS_HUE_KEY,
                ClipEffect::COLOR_WHEEL_HIGHLIGHTS_AMOUNT_KEY,
                ClipEffect::COLOR_WHEEL_HIGHLIGHTS_LUMA_KEY,
            ],
            ColorWheelSlot::ShadowTint => {
                vec![ClipEffect::COLOR_SHADOW_TINT_HUE_KEY, ClipEffect::COLOR_SHADOW_TINT_AMOUNT_KEY]
            }
            ColorWheelSlot::HighlightTint => {
                vec![ClipEffect::COLOR_HIGHLIGHT_TINT_HUE_KEY, ClipEffect::COLOR_HIGHLIGHT_TINT_AMOUNT_KEY]
            }
        }
    }
}

/// What one keyframe control of the Color panel animates (INTERACTION-AUDIT §2): a slider, or a wheel whose
/// parameters key together.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ColorKeyTarget {
    Param(ColorParam),
    Wheel(ColorWheelSlot),
}

impl ColorKeyTarget {
    pub fn parameter_keys(self) -> Vec<&'static str> {
        match self {
            ColorKeyTarget::Param(p) => vec![p.parameter_key()],
            ColorKeyTarget::Wheel(w) => w.parameter_keys(),
        }
    }

    pub fn name(self) -> String {
        match self {
            ColorKeyTarget::Param(p) => p.keyframe_name(),
            ColorKeyTarget::Wheel(w) => {
                if w.has_luma() {
                    format!("{} Wheel", w.title())
                } else {
                    w.title().to_string()
                }
            }
        }
    }

    /// Every control, sliders first.
    pub fn all() -> Vec<ColorKeyTarget> {
        let mut v: Vec<ColorKeyTarget> = ColorParam::ALL.iter().map(|p| ColorKeyTarget::Param(*p)).collect();
        v.extend(ColorWheelSlot::ALL.iter().map(|w| ColorKeyTarget::Wheel(*w)));
        v
    }

    /// States of every animated control of `clip` (the rest are `.off`). `local` = the clip-local playhead time.
    /// `local` is the playhead minus the clip start (not clamped onto the clip).
    pub fn states(
        clip: Option<&Clip>,
        local: Time,
        playhead_in_range: bool,
    ) -> HashMap<ColorKeyID, KeyframeControlState> {
        let mut out = HashMap::new();
        let Some(clip) = clip else { return out };
        let count = clip.color_grade_effects().len().max(1);
        for n in 1..=count {
            for t in ColorKeyTarget::all() {
                let keys = t.parameter_keys();
                if !clip.is_color_animated(n, &keys) {
                    continue;
                }
                let times = Self::navigable_times(clip, n, t);
                out.insert(
                    ColorKeyID { effect: n as i64, target: t },
                    KeyframeControlState::resolve(
                        true,
                        times.contains(&local),
                        times.iter().any(|x| *x < local),
                        times.iter().any(|x| *x > local),
                        playhead_in_range,
                    ),
                );
            }
        }
        out
    }

    /// The key times Previous/Next can go to: those on the clip's frames (keys past a trim are skipped).
    pub fn navigable_times(clip: &Clip, effect: usize, target: ColorKeyTarget) -> Vec<Time> {
        let duration = clip.duration();
        clip.color_key_times(effect, &target.parameter_keys())
            .into_iter()
            .filter(|t| *t >= Time::ZERO && *t < duration)
            .collect()
    }
}

/// One keyframe control: Color effect `effect` (inspector id, 1-based) and what it animates.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ColorKeyID {
    pub effect: i64,
    pub target: ColorKeyTarget,
}

/// A click on a keyframe control: the ring, the diamond, or previous / next key.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ColorKeyAction {
    ToggleAnimation,
    ToggleKey,
    Previous,
    Next,
}

/// Which LUT of an effect a popup edits: the Input LUT (in Basic Correction) or the Creative look.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ColorLUTSlot {
    Input,
    Look,
}

/// UI identity of a collapsible part of the panel: a section of an effect, or one of its sub-groups.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct ColorPanelKey {
    pub effect: i64,
    pub kind: ColorSectionKind,
    pub group: Option<String>,
}

impl ColorPanelKey {
    pub fn new(effect: i64, kind: ColorSectionKind, group: Option<&str>) -> ColorPanelKey {
        ColorPanelKey { effect, kind, group: group.map(str::to_string) }
    }
}

/// Grade link and range actions of the Color panel menu (COLOR-GRADE-LINKS).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ColorGradeAction {
    /// Link the selected clips to this clip's grade.
    LinkSelected,
    /// Link every clip of this clip's media to its grade.
    LinkSource,
    Unlink,
    /// Add a range grade over In/Out (or playhead to clip end).
    AddRange,
    /// Move effect `id`'s range to In/Out (or playhead to clip end).
    SetRangeToInOut(i64),
    /// Effect `id` grades the whole clip again.
    WholeClip(i64),
}

/// A LUT the popups offer: its id is its identity.
#[derive(Clone, Debug)]
pub struct LUTChoice {
    pub id: String,
    pub name: String,
}

impl PartialEq for LUTChoice {
    /// A choice is its id: the embedded entry's name follows the media info, which may be absent for a moment while the
    /// panel refreshes, and must not make the same LUT look like a different one (the popup flipped to "Automatic").
    fn eq(&self, other: &LUTChoice) -> bool {
        self.id == other.id
    }
}

impl Eq for LUTChoice {}

impl std::hash::Hash for LUTChoice {
    fn hash<H: std::hash::Hasher>(&self, h: &mut H) {
        self.id.hash(h);
    }
}

impl LUTChoice {
    /// Input LUT: the camera's embedded look when the clip is S-Log3 and has one, else the built-in conversion.
    pub fn automatic() -> LUTChoice {
        LUTChoice { id: "automatic".to_string(), name: "Automatic".to_string() }
    }

    /// The LUT embedded in the clip's media.
    pub fn embedded(name: &str) -> LUTChoice {
        LUTChoice { id: "embedded".to_string(), name: format!("Embedded: {name}") }
    }

    pub fn file(path: &str) -> LUTChoice {
        let last = path.rsplit('/').next().unwrap_or(path);
        let name = last.rsplit_once('.').map_or(last, |(stem, _)| stem);
        LUTChoice { id: format!("file:{path}"), name: name.to_string() }
    }

    pub fn file_path(&self) -> Option<&str> {
        self.id.strip_prefix("file:")
    }
}

/// The LUT files this user picked last (most recent first). The host persists `paths` (Swift kept them in
/// `UserDefaults` key `colorRecentLUTs`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RecentLUTs {
    pub paths: Vec<String>,
}

impl RecentLUTs {
    pub const KEY: &'static str = "colorRecentLUTs";
    pub const LIMIT: usize = 8;

    pub fn add(&mut self, path: &str) {
        self.paths.retain(|p| p != path);
        self.paths.insert(0, path.to_string());
        self.paths.truncate(Self::LIMIT);
    }

    pub fn clear(&mut self) {
        self.paths.clear();
    }
}

/// What the Swift model reported through its `on…` hooks. The host drains `ColorInspectorModel::events` after a call and
/// handles them in order.
#[derive(Clone, Debug, PartialEq)]
pub enum ColorInspectorEvent {
    /// `onChange`: the clip color after an edit.
    Change(ClipColor),
    /// `onGestureBegan`.
    GestureBegan,
    /// `onGestureEnded`.
    GestureEnded,
    /// `onGraphChange`.
    GraphChange(ColorGraph),
    /// `onSharpenSet`.
    SharpenSet(f32),
    /// `onGradeViewChange`.
    GradeViewChange,
    /// `onViewerAidChange`.
    ViewerAidChange,
    /// `onCopyColor`.
    CopyColor,
    /// `onPasteColor`.
    PasteColor,
    /// `onGradeWholeSequence`.
    GradeWholeSequence,
    /// `onGradeAction`.
    GradeAction(ColorGradeAction),
    /// `onAutoTone`: the effect id.
    AutoTone(i64),
    /// `onPickWhiteBalance`: the effect id.
    PickWhiteBalance(i64),
    /// `onResetAll` (only while `reset_all_hooked` is set).
    ResetAll,
    /// `onProjectInputChange`.
    ProjectInputChange(Option<ColorSpaceID>),
    /// `onKeyframe`.
    Keyframe(ColorKeyAction, ColorKeyID),
    /// A LUT file was picked: the host remembers it (`RecentLUTs` is persisted by the host).
    RecentLut(String),
    /// A library LUT was starred or unstarred (the `LUTLibraryStore` call of Swift): the file name.
    ToggleFavouriteLut(String),
    /// Files to copy into the LUT library (the `LUTLibraryStore.importLUTs` call of Swift).
    ImportLuts(Vec<String>),
}

/// State of the Color inspector for one clip: the clip's `ClipColor` plus UI-only state (which sections are open).
pub struct ColorInspectorModel {
    /// Bumped by every change a view shows (Swift `@Observable`).
    pub version: u64,
    /// Events for the host, oldest first.
    pub events: Vec<ColorInspectorEvent>,
    pub(crate) ids: Box<dyn IdSource>,

    detected_source: ColorSpaceID,
    embedded_lut_name: Option<String>,
    media_id: Option<Id>,
    media_info: Option<MediaInfo>,
    /// Why the eyedropper and Auto are unavailable (they would measure more than this clip); nil = available.
    pub sampling_block: Option<String>,

    pub(crate) color: ClipColor,
    /// Sections and sub-groups that are collapsed (UI state, not stored in the clip).
    collapsed: BTreeSet<ColorPanelKey>,
    known_effects: BTreeSet<i64>,

    /// LUT files the host offers in the popups (Library).
    pub available_luts: Vec<LUTChoice>,
    /// The user's LUT library entries (copies in App Support, favorites first); empty = none (tests, no host). The host
    /// refreshes them after `ToggleFavouriteLut` / `ImportLuts`.
    pub lut_entries: Vec<LUTEntry>,
    pub recents: RecentLUTs,
    pub recent_luts: Vec<String>,

    /// Color Pro mode: the target's Color Graph (nil: none yet).
    pub(crate) graph: Option<ColorGraph>,
    selected_step: Option<Id>,
    /// Every Step selected on the Steps canvas (Shift or Command click, rectangle); `selected_step` is the one the
    /// inspector shows.
    pub selected_steps: BTreeSet<Id>,
    /// View state: the Step whose name is being edited in the Steps graph (set by the Step menu's Rename).
    pub renaming_step: Option<Id>,
    /// The mixer box selected on the Steps canvas (named by the head of its stack); nil = none.
    pub selected_mixer: Option<Id>,
    shows_empty_pro: bool,
    shows_matte: bool,

    loading: bool,
    gesture_depth: i64,

    /// The Sharpen row of Basic (the target's Sharpen effect, 0 = none). Not part of `ClipColor`: the host reads and
    /// writes the clip's Sharpen effect (`Clip::sharpen_amount`).
    sharpen: f32,

    /// Keyframe control states at the playhead, set by the host (missing = not animated).
    pub keyframe_states: HashMap<ColorKeyID, KeyframeControlState>,

    /// COLOR-GRADE-LINKS, set by the host: clip-local range text per range grade (effect id), and how many clips share
    /// this clip's grade (0 = not linked).
    pub effect_range_labels: BTreeMap<i64, String>,
    pub linked_clip_count: i64,
    /// The host's Reset (removes the clip's Color effects with their keys). When set, `reset_all` sends `ResetAll`
    /// instead of editing the shown values.
    pub reset_all_hooked: bool,
    /// W9.3: the project's camera input color space (`Project.inputColorSpace`), set by the host; nil = none.
    pub project_input: Option<ColorSpaceID>,
}

impl ColorInspectorModel {
    /// A model over `ColorClip::default`; `ids` mints the ids of new Steps.
    pub fn new(ids: Box<dyn IdSource>) -> ColorInspectorModel {
        let mut m = ColorInspectorModel {
            version: 0,
            events: Vec::new(),
            ids,
            detected_source: ColorSpaceID::Rec709,
            embedded_lut_name: None,
            media_id: None,
            media_info: None,
            sampling_block: None,
            color: ClipColor::default(),
            collapsed: BTreeSet::new(),
            known_effects: BTreeSet::new(),
            available_luts: Vec::new(),
            lut_entries: Vec::new(),
            recents: RecentLUTs::default(),
            recent_luts: Vec::new(),
            graph: None,
            selected_step: None,
            selected_steps: BTreeSet::new(),
            renaming_step: None,
            selected_mixer: None,
            shows_empty_pro: false,
            shows_matte: false,
            loading: false,
            gesture_depth: 0,
            sharpen: 0.0,
            keyframe_states: HashMap::new(),
            effect_range_labels: BTreeMap::new(),
            linked_clip_count: 0,
            reset_all_hooked: false,
            project_input: None,
        };
        m.sync_known_effects();
        m
    }

    pub(crate) fn touch(&mut self) {
        self.version += 1;
    }

    pub(crate) fn emit(&mut self, e: ColorInspectorEvent) {
        self.events.push(e);
    }

    /// A drag of the host (the monitor's window handles) starts one undo step.
    pub fn emit_gesture_began(&mut self) {
        self.emit(ColorInspectorEvent::GestureBegan);
    }

    /// The drag of the host ends its undo step.
    pub fn emit_gesture_ended(&mut self) {
        self.emit(ColorInspectorEvent::GestureEnded);
    }

    /// The panel's Auto button / menu row (Swift `onAutoTone?(effect)`).
    pub fn emit_auto_tone(&mut self, effect: i64) {
        self.emit(ColorInspectorEvent::AutoTone(effect));
    }

    /// The white-balance eyedropper button (Swift `onPickWhiteBalance?(effect)`).
    pub fn emit_pick_white_balance(&mut self, effect: i64) {
        self.emit(ColorInspectorEvent::PickWhiteBalance(effect));
    }

    /// Takes the pending events.
    pub fn take_events(&mut self) -> Vec<ColorInspectorEvent> {
        std::mem::take(&mut self.events)
    }

    /// Explicit "Interpret footage as" override; nil = Automatic (what the media says).
    pub fn source_override(&self) -> Option<ColorSpaceID> {
        self.color.source
    }

    pub fn detected_source(&self) -> ColorSpaceID {
        self.detected_source
    }

    /// The clip's source space: the override, else the detected one.
    pub fn source(&self) -> ColorSpaceID {
        self.color.source.unwrap_or(self.detected_source)
    }

    /// Name of the camera look LUT embedded in the clip's media, if any.
    pub fn embedded_lut_name(&self) -> Option<&str> {
        self.embedded_lut_name.as_deref()
    }

    pub fn media_id(&self) -> Option<Id> {
        self.media_id
    }

    /// The clip's media info as loaded (for the effective source under the project input default).
    pub fn media_info(&self) -> Option<&MediaInfo> {
        self.media_info.as_ref()
    }

    pub fn color(&self) -> &ClipColor {
        &self.color
    }

    pub fn is_loading(&self) -> bool {
        self.loading
    }

    pub fn clip_color(&self) -> ClipColor {
        self.color.clone()
    }

    pub fn sharpen(&self) -> f32 {
        self.sharpen
    }

    pub fn load_sharpen(&mut self, v: f32) {
        if self.sharpen != v {
            self.sharpen = v;
            self.touch();
        }
    }

    pub fn set_sharpen(&mut self, v: f32) {
        let c = v.max(super::color_sharpen::SHARPEN_ROW_RANGE.0).min(super::color_sharpen::SHARPEN_ROW_RANGE.1);
        if c == self.sharpen {
            return;
        }
        self.sharpen = c;
        self.touch();
        if !self.loading {
            self.emit(ColorInspectorEvent::SharpenSet(c));
        }
    }

    fn notify(&mut self) {
        if !self.loading {
            let c = self.color.clone();
            self.emit(ColorInspectorEvent::Change(c));
        }
    }

    /// Applies an edit to the clip color and reports it when something changed.
    fn edit(&mut self, body: impl FnOnce(&mut ClipColor)) {
        let mut c = self.color.clone();
        body(&mut c);
        if c == self.color {
            return;
        }
        self.color = c;
        self.sync_known_effects();
        self.touch();
        self.notify();
    }

    pub(crate) fn edit_effect(&mut self, id: i64, body: impl FnOnce(&mut ColorEffect)) {
        self.edit(|c| {
            c.edit_effects(|fx| {
                if let Some(e) = fx.iter_mut().find(|e| e.id == id) {
                    body(e);
                }
            });
        });
    }

    /// Wraps a discrete edit (reset, popup choice, add/remove) as one undo step; nested calls collapse.
    pub fn gesture(&mut self, body: impl FnOnce(&mut ColorInspectorModel)) {
        if self.gesture_depth == 0 {
            self.emit(ColorInspectorEvent::GestureBegan);
        }
        self.gesture_depth += 1;
        body(self);
        self.gesture_depth -= 1;
        if self.gesture_depth == 0 {
            self.emit(ColorInspectorEvent::GestureEnded);
        }
    }

    // MARK: Keyframes

    pub fn keyframe_state(&self, effect: i64, target: ColorKeyTarget) -> KeyframeControlState {
        self.keyframe_states.get(&ColorKeyID { effect, target }).copied().unwrap_or(KeyframeControlState::OFF)
    }

    pub fn keyframe(&mut self, action: ColorKeyAction, effect: i64, target: ColorKeyTarget) {
        self.emit(ColorInspectorEvent::Keyframe(action, ColorKeyID { effect, target }));
    }

    // MARK: Clip.color bridge

    /// Shows `color` (no callbacks fire). `info` = the clip's media, for the detected source and the embedded LUT.
    pub fn load(&mut self, color: &ClipColor, media_id: Option<Id>, info: Option<&MediaInfo>) {
        self.loading = true;
        if self.color != *color {
            self.color = color.clone();
        }
        self.media_id = media_id;
        self.detected_source = info.map_or(ColorSpaceID::Rec709, |i| i.color_space());
        if self.media_info.as_ref() != info {
            self.media_info = info.cloned();
        }
        self.embedded_lut_name = info.and_then(|i| i.embedded_lut_name.clone());
        self.sync_known_effects();
        self.loading = false;
        self.touch();
    }

    /// Forgets UI state of effects that are gone; the first time an effect is shown Basic, Look and Curves are open
    /// and the rest closed (design board Color).
    fn sync_known_effects(&mut self) {
        let ids: BTreeSet<i64> = self.color.effects().iter().map(|e| e.id).collect();
        if !self.collapsed.is_empty() {
            self.collapsed.retain(|k| ids.contains(&k.effect));
        }
        self.known_effects.retain(|i| ids.contains(i));
        let fresh: Vec<i64> = ids.difference(&self.known_effects).copied().collect();
        for id in fresh {
            for k in <ColorSectionKind as ColorSectionKindExt>::ALL {
                if k != ColorSectionKind::BasicCorrection && k != ColorSectionKind::Creative {
                    self.collapsed.insert(ColorPanelKey::new(id, k, None));
                }
            }
            self.known_effects.insert(id);
        }
    }

    // MARK: Source

    pub fn set_source_override(&mut self, id: Option<ColorSpaceID>) {
        self.edit(|c| c.source = id);
    }

    pub fn log_mode(&self) -> LogMode {
        self.color.log_mode
    }

    pub fn target_space(&self) -> TargetSpace {
        self.color.target_space
    }

    pub fn hdr_conform(&self) -> bool {
        self.color.hdr_conform
    }

    pub fn set_log_mode(&mut self, m: LogMode) {
        self.gesture(|s| s.edit(|c| c.log_mode = m));
    }

    pub fn set_target_space(&mut self, t: TargetSpace) {
        self.gesture(|s| s.edit(|c| c.target_space = t));
    }

    pub fn set_hdr_conform(&mut self, on: bool) {
        self.gesture(|s| s.edit(|c| c.hdr_conform = on));
    }

    // MARK: Effects and sections

    pub fn effects(&self) -> &[ColorEffect] {
        self.color.effects()
    }

    /// Swift `color.effect(id)`.
    pub fn effect_by_id(&self, id: i64) -> Option<&ColorEffect> {
        self.color.effect(id)
    }

    /// Adds another Color effect (Premiere: add another Lumetri Color). One undo step.
    pub fn add_effect(&mut self) {
        self.gesture(|s| {
            s.edit(|c| {
                c.add_effect();
            })
        });
    }

    pub fn remove_effect(&mut self, id: i64) {
        self.gesture(|s| s.edit(|c| c.remove_effect(id)));
    }

    pub fn set_enabled(&mut self, effect: i64, kind: ColorSectionKind, on: bool) {
        self.gesture(|s| s.edit_effect(effect, |e| e.set_enabled(kind, on)));
    }

    pub fn is_enabled(&self, effect: i64, kind: ColorSectionKind) -> bool {
        self.color.effect(effect).is_some_and(|e| e.is_enabled(kind))
    }

    pub fn reset_section(&mut self, effect: i64, kind: ColorSectionKind) {
        self.gesture(|s| s.edit(|c| c.reset_section(kind, effect)));
    }

    /// Whether "Reset <section>" is offered enabled: always for the slider sections (as before); Color Range only when
    /// the effect holds a range (its reset removes it).
    pub fn can_reset_section(&self, effect: i64, kind: ColorSectionKind) -> bool {
        if kind == ColorSectionKind::HslSecondary {
            return self.color_range(effect).is_some();
        }
        true
    }

    /// The section resets of the effect's more-actions menu, in panel order (Basic … Vignette, Color Range included).
    pub fn section_resets(&self, effect: i64) -> Vec<(ColorSectionKind, String, bool)> {
        <ColorSectionKind as ColorSectionKindExt>::ALL
            .iter()
            .map(|k| (*k, format!("Reset {}", k.title()), self.can_reset_section(effect, *k)))
            .collect()
    }

    /// Premiere's per-effect Reset: every section of one Color effect back to its defaults (toggles stay). One undo step.
    pub fn reset_effect(&mut self, effect: i64) {
        self.gesture(|s| {
            for k in <ColorSectionKind as ColorSectionKindExt>::ALL {
                s.edit(|c| c.reset_section(k, effect));
            }
        });
    }

    /// Sets Temperature and Tint together (white-balance eyedropper). One undo step.
    pub fn set_white_balance(&mut self, effect: i64, temperature: f32, tint: f32) {
        self.gesture(|s| {
            s.set(effect, ColorParam::Temperature, temperature);
            s.set(effect, ColorParam::Tint, tint);
        });
    }

    /// Premiere's Tone Reset: Exposure, Contrast, Highlights, Shadows, Whites and Blacks of one effect back to neutral
    /// (Temperature, Tint and Saturation stay). One undo step. Like the section reset it moves a legacy effect to the
    /// current tone maths (the tone sliders are neutral, so nothing visible changes).
    pub fn reset_tone(&mut self, effect: i64) {
        self.gesture(|s| {
            for p in [
                ColorParam::Exposure,
                ColorParam::Contrast,
                ColorParam::Highlights,
                ColorParam::Shadows,
                ColorParam::Whites,
                ColorParam::Blacks,
            ] {
                s.set(effect, p, p.neutral());
            }
            s.edit_effect(effect, |e| e.basic.model = BasicToneModel::Lumetri);
        });
    }

    /// Writes the result of Auto Tone (Exposure, Contrast, Whites, Blacks, Temperature, Tint; Highlights, Shadows and
    /// Saturation stay). One undo step.
    pub fn set_auto_tone(&mut self, effect: i64, b: &BasicCorrection) {
        self.gesture(|s| {
            s.set(effect, ColorParam::Exposure, b.exposure);
            s.set(effect, ColorParam::Contrast, b.contrast);
            s.set(effect, ColorParam::Whites, b.whites);
            s.set(effect, ColorParam::Blacks, b.blacks);
            s.set(effect, ColorParam::Temperature, b.temperature);
            s.set(effect, ColorParam::Tint, b.tint);
        });
    }

    /// The title of an effect's header row: "Color", "Color 2", plus its range or the link.
    pub fn effect_title(&self, effect: i64, number: i64) -> String {
        let mut t = if number == 1 { "Color".to_string() } else { format!("Color {number}") };
        if let Some(r) = self.effect_range_labels.get(&effect) {
            t.push_str(&format!("  \u{00B7}  {r}"));
        }
        if number == 1 && self.linked_clip_count > 1 {
            t.push_str(&format!("  \u{00B7}  Linked ({})", self.linked_clip_count));
        }
        t
    }

    /// W9.3: the host sets the project input (one undo step); the new value comes back through `project_input`.
    pub fn set_project_input(&mut self, space: Option<ColorSpaceID>) {
        self.emit(ColorInspectorEvent::ProjectInputChange(space));
    }

    /// The source color space the clip renders with: the clip's override, else the media's detection under the project
    /// input default, else Rec.709.
    pub fn effective_source(&self) -> ColorSpaceID {
        self.color
            .source
            .or_else(|| self.media_info.as_ref().map(|i| i.applying_project_input(self.project_input).color_space()))
            .unwrap_or(ColorSpaceID::Rec709)
    }

    /// Why Auto Tone is unavailable for this Color effect (nil = available): the measurement block, then what the tone
    /// model cannot invert (non-Rec.709 source, Input LUT, Basic Correction off, active later sections).
    pub fn auto_tone_block(&self, effect: i64) -> Option<String> {
        if let Some(b) = &self.sampling_block {
            return Some(b.clone());
        }
        let Some(e) = self.color.effect(effect) else {
            return Some("No Color effect.".to_string());
        };
        auto_tone_solver::block_reason(e, self.effective_source())
    }

    /// Back to one default effect (keeps "interpret as").
    pub fn reset_all(&mut self) {
        if self.reset_all_hooked {
            self.emit(ColorInspectorEvent::ResetAll);
            return;
        }
        self.gesture(|s| {
            s.edit(|c| {
                let (source, log_mode, target_space, hdr_conform) =
                    (c.source, c.log_mode, c.target_space, c.hdr_conform);
                *c = ClipColor::default();
                c.source = source;
                c.log_mode = log_mode;
                c.target_space = target_space;
                c.hdr_conform = hdr_conform;
            })
        });
    }

    pub fn is_collapsed(&self, key: &ColorPanelKey) -> bool {
        self.collapsed.contains(key)
    }

    pub fn set_collapsed(&mut self, key: ColorPanelKey, on: bool) {
        if on {
            self.collapsed.insert(key);
        } else {
            self.collapsed.remove(&key);
        }
        self.touch();
    }

    /// Sections and sub-groups that are collapsed.
    pub fn collapsed(&self) -> &BTreeSet<ColorPanelKey> {
        &self.collapsed
    }

    // MARK: Sliders

    pub fn value(&self, effect: i64, p: ColorParam) -> f32 {
        self.color.effect(effect).map_or(p.neutral(), |e| p.read(e))
    }

    pub fn set(&mut self, effect: i64, p: ColorParam, v: f32) {
        self.edit_effect(effect, |e| p.write(v, e));
    }

    pub fn reset_parameter(&mut self, effect: i64, p: ColorParam) {
        self.gesture(|s| s.set(effect, p, p.neutral()));
    }

    // MARK: Wheels

    pub fn wheel(&self, effect: i64, slot: ColorWheelSlot) -> (WheelValue, f32) {
        let Some(e) = self.color.effect(effect) else { return (WheelValue::default(), 0.0) };
        match slot {
            ColorWheelSlot::Shadows => (e.wheels.shadows, e.wheels.shadows_luma),
            ColorWheelSlot::Midtones => (e.wheels.midtones, e.wheels.midtones_luma),
            ColorWheelSlot::Highlights => (e.wheels.highlights, e.wheels.highlights_luma),
            ColorWheelSlot::ShadowTint => (e.creative.shadow_tint, 0.0),
            ColorWheelSlot::HighlightTint => (e.creative.highlight_tint, 0.0),
        }
    }

    pub fn set_wheel(&mut self, effect: i64, slot: ColorWheelSlot, hue: f32, amount: f32) {
        let v = WheelValue { hue, amount: amount.clamp(0.0, 1.0) };
        self.edit_effect(effect, |e| match slot {
            ColorWheelSlot::Shadows => e.wheels.shadows = v,
            ColorWheelSlot::Midtones => e.wheels.midtones = v,
            ColorWheelSlot::Highlights => e.wheels.highlights = v,
            ColorWheelSlot::ShadowTint => e.creative.shadow_tint = v,
            ColorWheelSlot::HighlightTint => e.creative.highlight_tint = v,
        });
    }

    /// Luminance slider of a three-way wheel, -100…100.
    pub fn set_wheel_luma(&mut self, effect: i64, slot: ColorWheelSlot, luma: f32) {
        let l = luma.clamp(-100.0, 100.0);
        self.edit_effect(effect, |e| match slot {
            ColorWheelSlot::Shadows => e.wheels.shadows_luma = l,
            ColorWheelSlot::Midtones => e.wheels.midtones_luma = l,
            ColorWheelSlot::Highlights => e.wheels.highlights_luma = l,
            _ => {}
        });
    }

    pub fn reset_wheel(&mut self, effect: i64, slot: ColorWheelSlot) {
        self.gesture(|s| {
            s.set_wheel(effect, slot, 0.0, 0.0);
            if slot.has_luma() {
                s.set_wheel_luma(effect, slot, 0.0);
            }
        });
    }

    // MARK: Curves

    pub fn curves(&self, effect: i64) -> RGBCurves {
        self.color.effect(effect).map(|e| e.curves.clone()).unwrap_or_default()
    }

    pub fn set_curves(&mut self, effect: i64, curves: RGBCurves) {
        self.edit_effect(effect, |e| e.curves = curves);
    }

    // MARK: Hue Saturation Curves

    pub fn hue_curve(&self, effect: i64, kind: HueCurveKind) -> Vec<CurvePoint> {
        kind.points(&self.color.effect(effect).map(|e| e.hue_curves.clone()).unwrap_or_default())
    }

    /// Writes one hue curve. Hue-keyed curves wrap around the color wheel, so their first and last point are the same
    /// place: when one of them moved vertically the other follows (an edit of the last point wins when both changed).
    pub fn set_hue_curve(&mut self, effect: i64, kind: HueCurveKind, pts: &[CurvePoint]) {
        self.edit_effect(effect, |e| {
            let wrapped = kind.wrapped(pts, &kind.points(&e.hue_curves));
            kind.set(wrapped, &mut e.hue_curves);
        });
    }

    /// Writes the "Hold Saturation Legal" Sat vs Sat curve. One undo step.
    pub fn hold_saturation_legal(&mut self, effect: i64) {
        self.gesture(|s| s.set_hue_curve(effect, HueCurveKind::SatVsSat, &saturation_hold_legal()));
    }

    // MARK: LUTs (Input LUT and Creative look)

    /// Amber-chip text when the picked LUT file's name says it expects another color space than the clip's (nil = fits).
    pub fn lut_mismatch(&self, effect: i64, slot: ColorLUTSlot) -> Option<String> {
        let choice = self.lut_choice(effect, slot)?;
        let path = choice.file_path()?;
        let name = path.rsplit('/').next().unwrap_or(path);
        // The Look slot runs after conversion to Rec.709; only an Input LUT sees the clip's own space.
        let source = if slot == ColorLUTSlot::Input { self.effective_source() } else { ColorSpaceID::Rec709 };
        lut_space_hint::mismatch(name, source).map(|m| m.1)
    }

    pub fn lut_choice(&self, effect: i64, slot: ColorLUTSlot) -> Option<LUTChoice> {
        let e = self.color.effect(effect)?;
        let r: Option<&LUTRef> =
            if slot == ColorLUTSlot::Input { e.input_lut.as_ref() } else { e.creative.look.as_ref() };
        r.map(|r| self.known_choice(self.choice(r)))
    }

    /// The known LUT files: the library first, then the host's. Each with its standardized path and file name.
    fn known_luts(&self) -> KnownLUTs {
        let known: Vec<LUTChoice> = self
            .lut_entries
            .iter()
            .map(|e| LUTChoice::file(&e.path))
            .chain(self.available_luts.iter().cloned())
            .collect();
        KnownLUTs {
            items: known
                .into_iter()
                .filter_map(|k| {
                    let path = k.file_path()?.to_string();
                    let name = path.rsplit('/').next().unwrap_or(&path).to_string();
                    Some((k, standardized_path(&path), name))
                })
                .collect(),
            sizes: HashMap::new(),
        }
    }

    /// A stored file path that is the project's collected copy of a known LUT is that LUT's choice, so the popup marks it
    /// and the look arrows find their place. Order: same standardized path, then same name and size (a file stat only
    /// for candidates with the same name; `sizes` caches them for one pass).
    fn known_choice_in(&self, c: LUTChoice, known: &mut KnownLUTs) -> LUTChoice {
        let Some(path) = c.file_path().map(str::to_string) else { return c };
        let std = standardized_path(&path);
        if let Some(k) = known.items.iter().find(|k| k.1 == std) {
            return k.0.clone();
        }
        let name = path.rsplit('/').next().unwrap_or(&path).to_string();
        let same: Vec<LUTChoice> = known.items.iter().filter(|k| k.2 == name).map(|k| k.0.clone()).collect();
        if same.is_empty() {
            return c;
        }
        let mut size = |p: &str| -> Option<u64> {
            if let Some(hit) = known.sizes.get(p) {
                return *hit;
            }
            let v = std::fs::metadata(p).ok().map(|m| m.len());
            known.sizes.insert(p.to_string(), v);
            v
        };
        let Some(want) = size(&path) else { return c };
        same.into_iter().find(|k| k.file_path().and_then(&mut size) == Some(want)).unwrap_or(c)
    }

    fn known_choice(&self, c: LUTChoice) -> LUTChoice {
        let mut k = self.known_luts();
        self.known_choice_in(c, &mut k)
    }

    /// Sets the Input LUT (nil = none: built-in conversion in the first effect) or the Creative look (nil = none).
    /// The path is stored as picked; copying into the project happens when the project is saved.
    pub fn set_lut(&mut self, effect: i64, slot: ColorLUTSlot, c: Option<&LUTChoice>) {
        let r = c.and_then(|c| self.lut_ref(c));
        if let Some(path) = c.and_then(|c| c.file_path()) {
            self.recents.add(path);
            self.recent_luts = self.recents.paths.clone();
            self.emit(ColorInspectorEvent::RecentLut(path.to_string()));
        }
        self.gesture(|s| {
            s.edit_effect(effect, |e| match slot {
                ColorLUTSlot::Input => e.input_lut = r,
                ColorLUTSlot::Look => e.creative.look = if r == Some(LUTRef::Automatic) { None } else { r },
            });
        });
    }

    /// The looks the Creative popup and its arrows cycle through (after "None"): the host's LUT files, then recents.
    pub fn look_choices(&self) -> Vec<LUTChoice> {
        let mut seen: BTreeSet<String> = BTreeSet::new();
        let mut out: Vec<LUTChoice> = Vec::new();
        let library: Vec<LUTChoice> = self.lut_entries.iter().map(|e| LUTChoice::file(&e.path)).collect();
        let mut known = self.known_luts();
        let recent: Vec<LUTChoice> =
            self.recent_luts.iter().map(|p| self.known_choice_in(LUTChoice::file(p), &mut known)).collect();
        for c in library.into_iter().chain(self.available_luts.iter().cloned()).chain(recent) {
            if c.file_path().is_some() && seen.insert(c.id.clone()) {
                out.push(c);
            }
        }
        out
    }

    /// Library LUTs in display order (favorites first).
    pub fn library_luts(&self) -> &[LUTEntry] {
        &self.lut_entries
    }

    pub fn is_favourite_lut(&self, choice: &LUTChoice) -> bool {
        let Some(path) = choice.file_path() else { return false };
        self.lut_entries.iter().any(|e| e.path == path && e.is_favourite)
    }

    /// Stars or unstars a library LUT (no-op for files outside the library); the host toggles it in the store.
    pub fn toggle_favourite_lut(&mut self, choice: &LUTChoice) {
        let Some(path) = choice.file_path() else { return };
        let Some(e) = self.lut_entries.iter().find(|e| e.path == path) else { return };
        let name = e.file_name.clone();
        self.emit(ColorInspectorEvent::ToggleFavouriteLut(name));
    }

    /// Asks the host to copy the given .cube files into the library; the added LUTs come back through `lut_entries`.
    pub fn import_luts(&mut self, paths: &[String]) {
        self.emit(ColorInspectorEvent::ImportLuts(paths.to_vec()));
    }

    pub(crate) fn choice(&self, r: &LUTRef) -> LUTChoice {
        match r {
            LUTRef::Automatic => LUTChoice::automatic(),
            LUTRef::Embedded { .. } => LUTChoice::embedded(self.embedded_lut_name.as_deref().unwrap_or("Camera LUT")),
            LUTRef::File { path } => LUTChoice::file(path),
        }
    }

    pub(crate) fn lut_ref(&self, c: &LUTChoice) -> Option<LUTRef> {
        if c.id == LUTChoice::automatic().id {
            return Some(LUTRef::Automatic);
        }
        if c.id == "embedded" {
            return self.media_id.map(|media| LUTRef::Embedded { media });
        }
        c.file_path().map(|p| LUTRef::File { path: p.to_string() })
    }

    // MARK: Graph state shared with ColorInspectorModel+Graph

    pub fn graph(&self) -> Option<&ColorGraph> {
        self.graph.as_ref()
    }

    pub fn selected_step(&self) -> Option<Id> {
        self.selected_step
    }

    /// Swift `selectedStep` with its `didSet`.
    pub fn set_selected_step(&mut self, s: Option<Id>) {
        let old = self.selected_step;
        self.selected_step = s;
        if let Some(id) = s {
            if !self.selected_steps.contains(&id) {
                self.selected_steps = BTreeSet::from([id]);
            }
        } else {
            self.selected_steps.clear();
        }
        self.touch();
        if old != self.selected_step {
            self.emit(ColorInspectorEvent::ViewerAidChange);
        }
    }

    pub fn shows_empty_pro(&self) -> bool {
        self.shows_empty_pro
    }

    /// View state, never saved: the Pro page shows though the clip has no Color Graph yet.
    pub fn set_shows_empty_pro(&mut self, on: bool) {
        let old = self.shows_empty_pro;
        self.shows_empty_pro = on;
        self.touch();
        if old != on {
            self.emit(ColorInspectorEvent::GradeViewChange);
        }
    }

    pub fn shows_matte(&self) -> bool {
        self.shows_matte
    }

    /// Viewing aid, never saved: the monitor shows where the selected Step works (its qualifier and window) as a white
    /// overlay instead of the graded picture.
    pub fn set_shows_matte(&mut self, on: bool) {
        let old = self.shows_matte;
        self.shows_matte = on;
        self.touch();
        if old != on {
            self.emit(ColorInspectorEvent::ViewerAidChange);
        }
    }
}

/// `HueCurves.saturationHoldLegal` (the Swift static is not in `sq-core-model`).
fn saturation_hold_legal() -> Vec<CurvePoint> {
    vec![
        CurvePoint { x: 0.0, y: 0.5 },
        CurvePoint { x: 0.7, y: 0.5 },
        CurvePoint { x: 0.85, y: 0.42 },
        CurvePoint { x: 1.0, y: 0.3 },
    ]
}

pub(crate) struct KnownLUTs {
    /// The choice, its standardized path and its file name.
    items: Vec<(LUTChoice, String, String)>,
    sizes: HashMap<String, Option<u64>>,
}

/// Lexical `standardizedFileURL.path`: `.` and `..` components and doubled slashes removed.
/// shortcut: no symlink or /private resolution, upgrade when LUT folders are symlinked.
fn standardized_path(path: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    for c in path.split('/') {
        match c {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            c => parts.push(c),
        }
    }
    let joined = parts.join("/");
    if path.starts_with('/') { format!("/{joined}") } else { joined }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::SequentialIds;

    fn model() -> ColorInspectorModel {
        ColorInspectorModel::new(Box::new(SequentialIds::default()))
    }

    #[test]
    fn slider_edits_clamp_and_report_one_change() {
        let mut m = model();
        m.set(1, ColorParam::Exposure, 9.0);
        assert_eq!(m.value(1, ColorParam::Exposure), 5.0);
        let ev = m.take_events();
        assert!(matches!(ev.as_slice(), [ColorInspectorEvent::Change(_)]));
        m.set(1, ColorParam::Exposure, 5.0);
        assert!(m.take_events().is_empty());
    }

    #[test]
    fn gestures_nest_into_one_begin_and_end() {
        let mut m = model();
        m.reset_parameter(1, ColorParam::Contrast);
        m.set(1, ColorParam::Contrast, 10.0);
        m.reset_parameter(1, ColorParam::Contrast);
        let ev = m.take_events();
        let begins = ev.iter().filter(|e| matches!(e, ColorInspectorEvent::GestureBegan)).count();
        let ends = ev.iter().filter(|e| matches!(e, ColorInspectorEvent::GestureEnded)).count();
        assert_eq!((begins, ends), (2, 2));
        assert_eq!(m.value(1, ColorParam::Contrast), 0.0);
    }

    #[test]
    fn load_does_not_report() {
        let mut m = model();
        let mut c = ClipColor::default();
        c.edit_effects(|fx| fx[0].basic.temperature = 12.0);
        m.load(&c, None, None);
        assert_eq!(m.value(1, ColorParam::Temperature), 12.0);
        assert!(m.take_events().is_empty());
    }

    #[test]
    fn a_new_effect_opens_basic_and_look_and_closes_the_rest() {
        let m = model();
        let id = m.effects()[0].id;
        assert!(!m.is_collapsed(&ColorPanelKey::new(id, ColorSectionKind::BasicCorrection, None)));
        assert!(!m.is_collapsed(&ColorPanelKey::new(id, ColorSectionKind::Creative, None)));
        assert!(m.is_collapsed(&ColorPanelKey::new(id, ColorSectionKind::Vignette, None)));
    }

    #[test]
    fn hue_curves_wrap_first_and_last_point() {
        let old = vec![CurvePoint { x: 0.0, y: 0.5 }, CurvePoint { x: 1.0, y: 0.5 }];
        let moved = vec![CurvePoint { x: 0.0, y: 0.5 }, CurvePoint { x: 1.0, y: 0.8 }];
        let w = HueCurveKind::HueVsSat.wrapped(&moved, &old);
        assert_eq!((w[0].y, w[1].y), (0.8, 0.8));
        let w = HueCurveKind::LumaVsSat.wrapped(&moved, &old);
        assert_eq!((w[0].y, w[1].y), (0.5, 0.8));
    }

    #[test]
    fn lut_choices_are_their_id() {
        let a = LUTChoice::embedded("A");
        let b = LUTChoice::embedded("B");
        assert_eq!(a, b);
        assert_eq!(LUTChoice::file("/luts/Warm Look.cube").name, "Warm Look");
        assert_eq!(LUTChoice::file("/x/a.cube").file_path(), Some("/x/a.cube"));
    }

    #[test]
    fn recents_keep_the_newest_first_and_cap_at_eight() {
        let mut r = RecentLUTs::default();
        for i in 0..10 {
            r.add(&format!("/p{i}"));
        }
        r.add("/p5");
        assert_eq!(r.paths.len(), RecentLUTs::LIMIT);
        assert_eq!(r.paths[0], "/p5");
    }

    #[test]
    fn effect_titles_carry_range_and_link() {
        let mut m = model();
        m.effect_range_labels.insert(1, "0:01\u{2013}0:02".to_string());
        m.linked_clip_count = 3;
        assert_eq!(m.effect_title(1, 1), "Color  \u{00B7}  0:01\u{2013}0:02  \u{00B7}  Linked (3)");
        assert_eq!(m.effect_title(2, 2), "Color 2");
    }

    #[test]
    fn standardized_paths_drop_dots() {
        assert_eq!(standardized_path("/a/./b/../c//d.cube"), "/a/c/d.cube");
    }

    #[test]
    fn wheel_slots_key_hue_amount_and_luma_together() {
        assert_eq!(ColorWheelSlot::Shadows.parameter_keys().len(), 3);
        assert_eq!(ColorWheelSlot::ShadowTint.parameter_keys().len(), 2);
        assert_eq!(ColorKeyTarget::Wheel(ColorWheelSlot::Midtones).name(), "Midtones Wheel");
        assert_eq!(ColorKeyTarget::Param(ColorParam::LookIntensity).name(), "Look Intensity");
    }
}

/// The Swift `HueCurveExplanationTests` and `ZoneBoardPanelTests`, same names.
#[cfg(test)]
mod ported_tests {
    use super::*;
    use crate::color::color_range_model::ColorRangeParam;
    use sq_core_color::{BoardZone, ZoneBoardExt};
    use sq_core_model::HSLMaskMode;
    use sq_core_time::SequentialIds;

    fn model() -> ColorInspectorModel {
        ColorInspectorModel::new(Box::new(SequentialIds::default()))
    }

    #[test]
    fn curve_menu_titles_match_the_swift_names_in_order() {
        let titles: Vec<_> = HueCurveKind::ALL.iter().map(|k| k.title()).collect();
        assert_eq!(titles, ["Hue vs Sat", "Hue vs Hue", "Hue vs Luma", "Luma vs Sat", "Sat vs Sat"]);
    }

    #[test]
    fn every_curve_explains_itself() {
        for k in HueCurveKind::ALL {
            assert!(k.explanation().starts_with(k.title()));
        }
    }

    #[test]
    fn first_edit_creates_the_board_and_only_that_zone_changes() {
        let mut m = model();
        assert!(m.effect_by_id(1).is_some_and(|e| e.zone_board.is_none()) && m.zone_board(1).is_neutral());
        m.set_zone_saturation(1, BoardZone::Shadows, 50.0);
        let changes = m.take_events().iter().filter(|e| matches!(e, ColorInspectorEvent::Change(_))).count();
        assert_eq!(changes, 1);
        let b = m.zone_board(1);
        assert_eq!(b.shadows.saturation, 0.25);
        assert!(b.global.is_neutral() && b.midtones.is_neutral() && b.highlights.is_neutral());
        assert_eq!(m.zone_saturation_percent(1, BoardZone::Shadows), 50.0);
    }

    #[test]
    fn puck_and_exposure_round_trip() {
        let mut m = model();
        m.set_zone_puck(1, BoardZone::Highlights, 90.0, 0.5);
        let w = m.zone_puck_wheel(1, BoardZone::Highlights);
        assert!((w.hue - 90.0).abs() < 0.01 && (w.amount - 0.5).abs() < 0.001);
        m.set_zone_exposure(1, BoardZone::Highlights, 1.0);
        assert_eq!(m.zone_board(1).zone(BoardZone::Highlights).exposure, 1.0);
        m.set_zone_exposure(1, BoardZone::Highlights, -9.0);
        assert_eq!(m.zone_board(1).zone(BoardZone::Highlights).exposure, 0.0, "clamped");
    }

    #[test]
    fn reset_zone_without_a_board_creates_nothing() {
        let mut m = model();
        m.reset_zone(1, BoardZone::Global);
        let changes = m.take_events().iter().filter(|e| matches!(e, ColorInspectorEvent::Change(_))).count();
        assert!(changes == 0 && m.effect_by_id(1).is_some_and(|e| e.zone_board.is_none()));
        m.set_zone_saturation(1, BoardZone::Global, 150.0);
        m.reset_zone(1, BoardZone::Global);
        assert!(m.zone_board(1).is_neutral());
    }

    #[test]
    fn color_volume_mode_shows_its_own_rows() {
        assert!(
            ColorRangeParam::VolumeRadius.is_shown(HSLMaskMode::Volume)
                && !ColorRangeParam::VolumeRadius.is_shown(HSLMaskMode::Ranges)
        );
        assert!(
            ColorRangeParam::SatMin.is_shown(HSLMaskMode::Ranges)
                && !ColorRangeParam::SatMin.is_shown(HSLMaskMode::Volume)
        );
        assert!(
            ColorRangeParam::HueCenter.is_shown(HSLMaskMode::Volume)
                && ColorRangeParam::Softness.is_shown(HSLMaskMode::Volume)
        );
        assert!(
            ColorRangeParam::Saturation.is_correction() && ColorRangeParam::Saturation.is_shown(HSLMaskMode::Volume)
        );
        let mut m = model();
        m.set_range_mask_mode(1, HSLMaskMode::Volume);
        m.set_range(1, ColorRangeParam::VolumeRadius, 60.0);
        assert!(m.range_mask_mode(1) == HSLMaskMode::Volume && m.range_value(1, ColorRangeParam::VolumeRadius) == 60.0);
    }
}
