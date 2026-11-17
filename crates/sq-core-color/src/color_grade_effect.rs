// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ColorGradeEffect.swift (the Color effect on ClipEffect), ColorKeyframing.swift (the ClipEffect part),
//        ColorGradeFade.swift (strength of a range grade and `ColorEffect.scaled`)
//! v27: the color grade lives in `Clip.effects` as effects of kind `color` (Premiere: Lumetri Color). Every number of
//! a `ColorEffect` is a keyframable scalar parameter (sliders and section checkboxes), so Effect Controls shows and
//! keys them like any other effect. What is not a number (LUT references, curve points, the Color Range and its on /
//! off toggle) sits in `ClipEffect::grade`. The saved types live in `sq-core-model`.
//!
//! Keyframes created here take their ids from an `IdSource` (Swift draws a random UUID).

use crate::zone_board::{BoardZone, ZoneBoardExt};
use sq_core_model::keyframes_hue::hue_wrap;
use sq_core_model::{
    AnimatedProperty, BasicToneModel, ClipEffect, ColorEffect, ColorGradeData, ColorSectionKind, CurvePoint,
    EffectParamSpec, EffectSpec, LUTRef, WheelValue, basic_tone_model,
};
use sq_core_time::keyframes_model::keyframe_math;
use sq_core_time::{Id, IdSource, Interpolation, Keyframe, KeyframeTrack, KeyframeValue, Time};
use std::collections::BTreeMap;
use std::sync::LazyLock;

/// Kind of a Color effect (stored string: never rename).
pub use sq_core_model::COLOR_KIND;

/// Parameter keys of the Color effect (stored strings: never rename). Swift: `ClipEffect.color...Key`.
pub mod color_keys {
    /// Parameter key `basicCorrectionOn`.
    pub const BASIC_ON: &str = "basicCorrectionOn";
    /// Parameter key `creativeOn`.
    pub const CREATIVE_ON: &str = "creativeOn";
    /// Parameter key `curvesOn`.
    pub const CURVES_ON: &str = "curvesOn";
    /// Parameter key `wheelsOn`.
    pub const WHEELS_ON: &str = "wheelsOn";
    /// Parameter key `vignetteOn`.
    pub const VIGNETTE_ON: &str = "vignetteOn";
    /// Parameter key `temperature`.
    pub const TEMPERATURE: &str = "temperature";
    /// Parameter key `tint`.
    pub const TINT: &str = "tint";
    /// Parameter key `exposure`.
    pub const EXPOSURE: &str = "exposure";
    /// Parameter key `contrast`.
    pub const CONTRAST: &str = "contrast";
    /// Parameter key `highlights`.
    pub const HIGHLIGHTS: &str = "highlights";
    /// Parameter key `shadows`.
    pub const SHADOWS: &str = "shadows";
    /// Parameter key `whites`.
    pub const WHITES: &str = "whites";
    /// Parameter key `blacks`.
    pub const BLACKS: &str = "blacks";
    /// Parameter key `saturation`.
    pub const SATURATION: &str = "saturation";
    /// Parameter key `vibrance`.
    pub const VIBRANCE: &str = "vibrance";
    /// Parameter key `inputLUTIntensity`.
    pub const INPUT_LUT_INTENSITY: &str = "inputLUTIntensity";
    /// Parameter key `lookIntensity`.
    pub const LOOK_INTENSITY: &str = "lookIntensity";
    /// Parameter key `fadedFilm`.
    pub const FADED_FILM: &str = "fadedFilm";
    /// Parameter key `creativeVibrance`.
    pub const CREATIVE_VIBRANCE: &str = "creativeVibrance";
    /// Parameter key `creativeSaturation`.
    pub const CREATIVE_SATURATION: &str = "creativeSaturation";
    /// Parameter key `shadowTintHue`.
    pub const SHADOW_TINT_HUE: &str = "shadowTintHue";
    /// Parameter key `shadowTintAmount`.
    pub const SHADOW_TINT_AMOUNT: &str = "shadowTintAmount";
    /// Parameter key `highlightTintHue`.
    pub const HIGHLIGHT_TINT_HUE: &str = "highlightTintHue";
    /// Parameter key `highlightTintAmount`.
    pub const HIGHLIGHT_TINT_AMOUNT: &str = "highlightTintAmount";
    /// Parameter key `tintBalance`.
    pub const TINT_BALANCE: &str = "tintBalance";
    /// Parameter key `wheelShadowsHue`.
    pub const WHEEL_SHADOWS_HUE: &str = "wheelShadowsHue";
    /// Parameter key `wheelShadowsAmount`.
    pub const WHEEL_SHADOWS_AMOUNT: &str = "wheelShadowsAmount";
    /// Parameter key `wheelShadowsLuma`.
    pub const WHEEL_SHADOWS_LUMA: &str = "wheelShadowsLuma";
    /// Parameter key `wheelMidtonesHue`.
    pub const WHEEL_MIDTONES_HUE: &str = "wheelMidtonesHue";
    /// Parameter key `wheelMidtonesAmount`.
    pub const WHEEL_MIDTONES_AMOUNT: &str = "wheelMidtonesAmount";
    /// Parameter key `wheelMidtonesLuma`.
    pub const WHEEL_MIDTONES_LUMA: &str = "wheelMidtonesLuma";
    /// Parameter key `wheelHighlightsHue`.
    pub const WHEEL_HIGHLIGHTS_HUE: &str = "wheelHighlightsHue";
    /// Parameter key `wheelHighlightsAmount`.
    pub const WHEEL_HIGHLIGHTS_AMOUNT: &str = "wheelHighlightsAmount";
    /// Parameter key `wheelHighlightsLuma`.
    pub const WHEEL_HIGHLIGHTS_LUMA: &str = "wheelHighlightsLuma";
    /// Parameter key `wheelSaturation`.
    pub const WHEEL_SATURATION: &str = "wheelSaturation";
    /// Parameter key `vignetteAmount`.
    pub const VIGNETTE_AMOUNT: &str = "vignetteAmount";
    /// Parameter key `vignetteMidpoint`.
    pub const VIGNETTE_MIDPOINT: &str = "vignetteMidpoint";
    /// Parameter key `vignetteRoundness`.
    pub const VIGNETTE_ROUNDNESS: &str = "vignetteRoundness";
    /// Parameter key `vignetteFeather`.
    pub const VIGNETTE_FEATHER: &str = "vignetteFeather";
    /// Hidden parameter (not in the spec, never keyed): the Basic Correction maths, the `BasicToneModel` raw value.
    pub use sq_core_model::COLOR_BASIC_MODEL_KEY as BASIC_MODEL;
}

/// Degrees round the color circle (the only degree values of the Color effect).
const DEGREE: &str = "\u{00B0}";

/// One number of a `ColorEffect` as an effect parameter.
pub struct ColorScalarField {
    /// Parameter key.
    pub key: &'static str,
    /// Row title.
    pub title: &'static str,
    /// Unit shown after the value.
    pub unit: &'static str,
    /// Allowed values.
    pub range: (f64, f64),
    /// Shown decimals.
    pub decimals: i64,
    /// Reads the number out of an effect (Swift key path).
    pub get: fn(&ColorEffect) -> f32,
    /// Writes the number into an effect.
    pub set: fn(&mut ColorEffect, f32),
}

impl ColorScalarField {
    /// Degrees round the color circle.
    pub fn is_hue(&self) -> bool {
        self.unit == DEGREE
    }

    /// The Effect Controls row of this number.
    pub fn spec(&self) -> EffectParamSpec {
        let def = f64::from((self.get)(&ColorEffect::new(1, None)));
        let mut p = EffectParamSpec::new(
            self.key,
            self.title,
            self.unit,
            def,
            self.range.0..=self.range.1,
            if self.decimals >= 2 { 0.01 } else { 0.1 },
            self.decimals,
        );
        p.is_hue = self.is_hue();
        p
    }
}

/// A color wheel of the Color effect (Look tints, Color Wheels): its hue and amount are one puck on the disc.
pub struct ColorPuckField {
    /// Hue parameter key.
    pub hue_key: &'static str,
    /// Amount parameter key.
    pub amount_key: &'static str,
    /// Reads the puck out of an effect.
    pub get: fn(&ColorEffect) -> WheelValue,
}

/// A section toggle of a `ColorEffect` as a checkbox parameter.
pub struct ColorToggleField {
    /// Parameter key.
    pub key: &'static str,
    /// The section it switches.
    pub section: ColorSectionKind,
}

macro_rules! field {
    ($key:expr, $title:expr, $range:expr, $dec:expr, $unit:expr, |$e:ident| $path:expr) => {
        ColorScalarField {
            key: $key,
            title: $title,
            unit: $unit,
            range: $range,
            decimals: $dec,
            get: |$e| $path,
            set: |$e, v| $path = v,
        }
    };
}

const HUNDRED: (f64, f64) = (-100.0, 100.0);

/// The tables of the Color effect's numbers, pucks and section switches.
pub struct ColorGradeFields;

static SCALARS: LazyLock<Vec<ColorScalarField>> = LazyLock::new(|| {
    use color_keys as k;
    vec![
        // Basic
        field!(k::TEMPERATURE, "Temperature", HUNDRED, 1, "", |e| e.basic.temperature),
        field!(k::TINT, "Tint", HUNDRED, 1, "", |e| e.basic.tint),
        field!(k::SATURATION, "Saturation", (0.0, 200.0), 1, "", |e| e.basic.saturation),
        field!(k::EXPOSURE, "Exposure", (-5.0, 5.0), 2, "", |e| e.basic.exposure),
        field!(k::CONTRAST, "Contrast", HUNDRED, 1, "", |e| e.basic.contrast),
        field!(k::HIGHLIGHTS, "Highlights", HUNDRED, 1, "", |e| e.basic.highlights),
        field!(k::SHADOWS, "Shadows", HUNDRED, 1, "", |e| e.basic.shadows),
        field!(k::WHITES, "Whites", HUNDRED, 1, "", |e| e.basic.whites),
        field!(k::BLACKS, "Blacks", HUNDRED, 1, "", |e| e.basic.blacks),
        field!(k::VIBRANCE, "Vibrance", HUNDRED, 1, "", |e| e.basic.vibrance),
        field!(k::INPUT_LUT_INTENSITY, "Source LUT Intensity", (0.0, 100.0), 1, "", |e| e.input_lut_intensity),
        // Creative
        field!(k::LOOK_INTENSITY, "Look Intensity", (0.0, 100.0), 1, "", |e| e.creative.intensity),
        field!(k::FADED_FILM, "Fade", (0.0, 100.0), 1, "", |e| e.creative.faded_film),
        field!(k::CREATIVE_VIBRANCE, "Look Vibrance", HUNDRED, 1, "", |e| e.creative.vibrance),
        field!(k::CREATIVE_SATURATION, "Look Saturation", (0.0, 200.0), 1, "", |e| e.creative.saturation),
        field!(k::SHADOW_TINT_HUE, "Shadow Tint Hue", (0.0, 360.0), 1, DEGREE, |e| e.creative.shadow_tint.hue),
        field!(k::SHADOW_TINT_AMOUNT, "Shadow Tint Amount", (0.0, 1.0), 2, "", |e| e.creative.shadow_tint.amount),
        field!(k::HIGHLIGHT_TINT_HUE, "Highlight Tint Hue", (0.0, 360.0), 1, DEGREE, |e| e.creative.highlight_tint.hue),
        field!(k::HIGHLIGHT_TINT_AMOUNT, "Highlight Tint Amount", (0.0, 1.0), 2, "", |e| e
            .creative
            .highlight_tint
            .amount),
        field!(k::TINT_BALANCE, "Tint Balance", HUNDRED, 1, "", |e| e.creative.tint_balance),
        // Wheels
        field!(k::WHEEL_SHADOWS_HUE, "Shadows Hue", (0.0, 360.0), 1, DEGREE, |e| e.wheels.shadows.hue),
        field!(k::WHEEL_SHADOWS_AMOUNT, "Shadows Amount", (0.0, 1.0), 2, "", |e| e.wheels.shadows.amount),
        field!(k::WHEEL_SHADOWS_LUMA, "Shadows Luma", HUNDRED, 1, "", |e| e.wheels.shadows_luma),
        field!(k::WHEEL_MIDTONES_HUE, "Midtones Hue", (0.0, 360.0), 1, DEGREE, |e| e.wheels.midtones.hue),
        field!(k::WHEEL_MIDTONES_AMOUNT, "Midtones Amount", (0.0, 1.0), 2, "", |e| e.wheels.midtones.amount),
        field!(k::WHEEL_MIDTONES_LUMA, "Midtones Luma", HUNDRED, 1, "", |e| e.wheels.midtones_luma),
        field!(k::WHEEL_HIGHLIGHTS_HUE, "Highlights Hue", (0.0, 360.0), 1, DEGREE, |e| e.wheels.highlights.hue),
        field!(k::WHEEL_HIGHLIGHTS_AMOUNT, "Highlights Amount", (0.0, 1.0), 2, "", |e| e.wheels.highlights.amount),
        field!(k::WHEEL_HIGHLIGHTS_LUMA, "Highlights Luma", HUNDRED, 1, "", |e| e.wheels.highlights_luma),
        field!(k::WHEEL_SATURATION, "Wheels Saturation", (0.0, 200.0), 1, "", |e| e.wheels.saturation),
        // Vignette
        field!(k::VIGNETTE_AMOUNT, "Vignette Amount", (-5.0, 5.0), 2, "", |e| e.vignette.amount),
        field!(k::VIGNETTE_MIDPOINT, "Vignette Midpoint", (0.0, 100.0), 1, "", |e| e.vignette.midpoint),
        field!(k::VIGNETTE_ROUNDNESS, "Vignette Roundness", HUNDRED, 1, "", |e| e.vignette.roundness),
        field!(k::VIGNETTE_FEATHER, "Vignette Feather", (0.0, 100.0), 1, "", |e| e.vignette.feather),
    ]
});

/// Number of Basic Correction fields at the start of [`SCALARS`].
const BASIC_COUNT: usize = 11;
/// Creative fields follow Basic.
const CREATIVE_COUNT: usize = 9;
/// Wheels fields follow Creative.
const WHEELS_COUNT: usize = 10;

static PUCKS: [ColorPuckField; 5] = [
    ColorPuckField {
        hue_key: color_keys::SHADOW_TINT_HUE,
        amount_key: color_keys::SHADOW_TINT_AMOUNT,
        get: |e| e.creative.shadow_tint,
    },
    ColorPuckField {
        hue_key: color_keys::HIGHLIGHT_TINT_HUE,
        amount_key: color_keys::HIGHLIGHT_TINT_AMOUNT,
        get: |e| e.creative.highlight_tint,
    },
    ColorPuckField {
        hue_key: color_keys::WHEEL_SHADOWS_HUE,
        amount_key: color_keys::WHEEL_SHADOWS_AMOUNT,
        get: |e| e.wheels.shadows,
    },
    ColorPuckField {
        hue_key: color_keys::WHEEL_MIDTONES_HUE,
        amount_key: color_keys::WHEEL_MIDTONES_AMOUNT,
        get: |e| e.wheels.midtones,
    },
    ColorPuckField {
        hue_key: color_keys::WHEEL_HIGHLIGHTS_HUE,
        amount_key: color_keys::WHEEL_HIGHLIGHTS_AMOUNT,
        get: |e| e.wheels.highlights,
    },
];

static TOGGLES: [ColorToggleField; 5] = [
    ColorToggleField { key: color_keys::BASIC_ON, section: ColorSectionKind::BasicCorrection },
    ColorToggleField { key: color_keys::CREATIVE_ON, section: ColorSectionKind::Creative },
    ColorToggleField { key: color_keys::CURVES_ON, section: ColorSectionKind::Curves },
    ColorToggleField { key: color_keys::WHEELS_ON, section: ColorSectionKind::Wheels },
    ColorToggleField { key: color_keys::VIGNETTE_ON, section: ColorSectionKind::Vignette },
];

impl ColorGradeFields {
    /// Every number of the effect, Basic then Creative then Wheels then Vignette.
    pub fn scalars() -> &'static [ColorScalarField] {
        &SCALARS
    }

    /// The Basic Correction numbers.
    pub fn basic() -> &'static [ColorScalarField] {
        &SCALARS[..BASIC_COUNT]
    }

    /// The color wheels (two Creative tints, three Color Wheels).
    pub fn pucks() -> &'static [ColorPuckField] {
        &PUCKS
    }

    /// The section switches.
    pub fn toggles() -> &'static [ColorToggleField] {
        &TOGGLES
    }

    /// Effect Controls rows: each section's toggle, then its numbers (Lumetri order).
    pub fn params() -> Vec<EffectParamSpec> {
        use color_keys as k;
        let s = Self::scalars();
        let (creative, rest) = s[BASIC_COUNT..].split_at(CREATIVE_COUNT);
        let (wheels, vignette) = rest.split_at(WHEELS_COUNT);
        let toggle = |key: &str, title: &str| EffectParamSpec::checkbox(key, title, true);
        let mut out = vec![toggle(k::BASIC_ON, "Basic")];
        out.extend(Self::basic().iter().map(ColorScalarField::spec));
        out.push(toggle(k::CREATIVE_ON, "Creative"));
        out.extend(creative.iter().map(ColorScalarField::spec));
        out.push(toggle(k::CURVES_ON, "Curves"));
        out.push(toggle(k::WHEELS_ON, "Wheels & Match"));
        out.extend(wheels.iter().map(ColorScalarField::spec));
        out.push(toggle(k::VIGNETTE_ON, "Vignette"));
        out.extend(vignette.iter().map(ColorScalarField::spec));
        out
    }

    /// The catalog entry of the Color effect (the catalog registers this).
    pub fn spec() -> EffectSpec {
        EffectSpec {
            kind: COLOR_KIND.to_string(),
            title: "Color".to_string(),
            params: Self::params(),
            pairs: Vec::new(),
        }
    }

    /// `ClipEffect.defaultParameters(for: colorKind)`: every slider and switch at its default plus the hidden maths flag.
    pub fn default_parameters() -> BTreeMap<String, AnimatedProperty<f64>> {
        let mut out: BTreeMap<String, AnimatedProperty<f64>> = Self::params()
            .into_iter()
            .filter(|p| p.kind.is_scalar())
            .map(|p| (p.key, AnimatedProperty::new(p.default_value)))
            .collect();
        out.insert(
            color_keys::BASIC_MODEL.to_string(),
            AnimatedProperty::new(f64::from(BasicToneModel::CURRENT as i32)),
        );
        out
    }
}

/// How Effect Controls groups the parameters of a Color effect like the Color page: one group per switch (Basic
/// Correction, Creative, Curves, Color Wheels, Vignette), the switch first, then its numbers.
pub struct ColorEffectGroups;

impl ColorEffectGroups {
    /// Switch keys in display order; each starts a group.
    pub fn toggle_keys() -> Vec<&'static str> {
        ColorGradeFields::toggles().iter().map(|t| t.key).collect()
    }

    /// The key is a group's switch.
    pub fn is_group_toggle(key: &str) -> bool {
        ColorGradeFields::toggles().iter().any(|t| t.key == key)
    }

    /// The switch key of the group `key` belongs to (a switch is its own group's key).
    pub fn group_key(key: &str) -> Option<String> {
        let mut current: Option<String> = None;
        for p in ColorGradeFields::params() {
            if Self::is_group_toggle(&p.key) {
                current = Some(p.key.clone());
            }
            if p.key == key {
                return current;
            }
        }
        None
    }

    /// Groups that open on a freshly shown Color effect.
    pub fn open_by_default() -> [&'static str; 1] {
        [color_keys::BASIC_ON]
    }
}

/// The Color effect logic on [`ClipEffect`].
pub trait ClipEffectColorExt: Sized {
    /// The effect is a Color effect.
    fn is_color(&self) -> bool;
    /// The effect is a Color effect with a range (it grades only that part of the clip).
    fn is_range_grade(&self) -> bool;
    /// The grade data of a Color effect (defaults when not stored).
    fn color_data(&self) -> ColorGradeData;
    /// This Color effect moved onto a clip of `media` (paste, preset). A LUT embedded in other media does not exist
    /// there: the conversion slot of the first (`primary`) effect falls back to automatic, anything else to none.
    /// `Automatic` means something only in the first effect, so a later one gets none. File LUTs travel unchanged.
    fn adapting_luts(&self, media: Id, primary: bool) -> ClipEffect;
    /// A static Color effect holding `e` with the given effect id and keyframe ids from `ids`.
    fn color_grade(id: Id, e: &ColorEffect, ids: &mut dyn IdSource) -> ClipEffect;
    /// The Color effect's values at clip-local `t` (`None` = the static values), as the stored numbers (not clamped,
    /// so a migrated grade renders exactly as before). `id` is the inspector's index (1-based) of this effect.
    fn color_effect(&self, t: Option<Time>, id: i64) -> ColorEffect;
    /// Writes `e` into this Color effect. Only values that differ from what is shown at `t` change: a keyframed
    /// parameter gets a key at `t` (an existing key there keeps its interpolation), an unkeyed one its static value.
    /// Without `t` keyed parameters change their static value only. LUTs and curves are not keyframable.
    fn set_color_effect(&mut self, e: &ColorEffect, t: Option<Time>, ids: &mut dyn IdSource);
    /// Writes only what an edit changed (`base` = the values the editor showed, `e` = after the edit). A keyframed
    /// parameter gets a key at `t`; without `t` such an edit is refused (false, nothing changes).
    fn apply_color_edit(
        &mut self,
        base: &ColorEffect,
        e: &ColorEffect,
        t: Option<Time>,
        ids: &mut dyn IdSource,
    ) -> bool;
    /// The value the panel shows for parameter `key` at clip-local `t` (a wheel's two parts move together).
    fn color_shown_value(&self, key: &str, t: Time) -> Option<f64>;
    /// 0...1 strength of a range grade at clip-local `t`: 1 for effects without a range or fades, 0 outside the range.
    fn range_strength(&self, t: Time) -> f64;
}

/// `Double(t.value) / Double(t.timescale)`.
fn seconds(x: Time) -> f64 {
    x.value() as f64 / x.timescale() as f64
}

/// The position of a wheel puck between two keys that move hue and amount together: the puck goes in a straight line
/// from one key's position to the next (crossing near the center for opposite hues) instead of swinging round the hue
/// circle. A hold on either track holds the puck. Allocation-free: it runs per frame.
fn puck_value(fx: &ClipEffect, pk: &ColorPuckField, t: Time) -> Option<(f64, f64)> {
    let h = fx.parameters.get(pk.hue_key)?;
    let a = fx.parameters.get(pk.amount_key)?;
    let i = h.track.segment_index(t)?;
    let j = a.track.segment_index(t)?;
    let (h0, h1, a0, a1) = (&h.track.keys[i], &h.track.keys[i + 1], &a.track.keys[j], &a.track.keys[j + 1]);
    if h0.time != a0.time || h1.time != a1.time || t == h0.time {
        return None;
    }
    if h0.interpolation.is_hold() || a0.interpolation.is_hold() {
        // A Hold Ahead shows the next key already.
        let ahead = h0.interpolation == Interpolation::HoldAhead || a0.interpolation == Interpolation::HoldAhead;
        return Some(if ahead { (h1.value, a1.value) } else { (h0.value, a0.value) });
    }
    if h0.out_handle != a0.out_handle || h1.in_handle != a1.in_handle {
        return None;
    }
    let (mut k0, mut k1) = (h0.clone(), h1.clone());
    k0.value = 0.0;
    k1.value = 1.0;
    let f = KeyframeTrack::segment_value(&k0, &k1, keyframe_math::ratio(t - h0.time, h1.time - h0.time));
    let r0 = h0.value * std::f64::consts::PI / 180.0;
    let r1 = h1.value * std::f64::consts::PI / 180.0;
    let x = f64::lerp(&(r0.cos() * a0.value), &(r1.cos() * a1.value), f);
    let y = f64::lerp(&(r0.sin() * a0.value), &(r1.sin() * a1.value), f);
    let amount = (x * x + y * y).sqrt();
    if amount <= 1e-9 || amount.is_nan() {
        return Some((h.hue_value_at_local(t), 0.0));
    }
    Some((hue_wrap(y.atan2(x) * 180.0 / std::f64::consts::PI), amount))
}

/// Writes one parameter value: a keyframed parameter gets a key at `t` (an existing key there keeps its
/// interpolation), an unkeyed one its static value. Without `t` a keyed parameter changes its static value, or with
/// `strict` the write is refused (false).
fn write_parameter(
    parameters: &mut BTreeMap<String, AnimatedProperty<f64>>,
    key: &str,
    v: f64,
    stepped: bool,
    t: Option<Time>,
    strict: bool,
    ids: &mut dyn IdSource,
) -> bool {
    let p = parameters.entry(key.to_string()).or_insert_with(|| AnimatedProperty::new(v));
    if p.is_animated() && (t.is_some() || strict) {
        let Some(t) = t else { return false };
        if let Some(k) = p.track.keys.iter().find(|k| k.time == t) {
            let id = k.id;
            p.track.set(id, v);
        } else {
            let mut k = Keyframe::new(ids.next_id(), t, v);
            k.interpolation = if stepped { Interpolation::Hold } else { Interpolation::Linear };
            p.track.insert(k);
        }
    } else {
        p.value = v;
    }
    true
}

impl ClipEffectColorExt for ClipEffect {
    fn is_color(&self) -> bool {
        self.kind == COLOR_KIND
    }

    fn is_range_grade(&self) -> bool {
        self.is_color() && self.color_range.is_some()
    }

    fn color_data(&self) -> ColorGradeData {
        self.grade.clone().unwrap_or_default()
    }

    fn adapting_luts(&self, media: Id, primary: bool) -> ClipEffect {
        if !self.is_color() {
            return self.clone();
        }
        let mut d = self.color_data();
        if let Some(LUTRef::Embedded { media: m }) = &d.input_lut
            && *m != media
        {
            d.input_lut = if primary { Some(LUTRef::Automatic) } else { None };
        }
        if d.input_lut == Some(LUTRef::Automatic) && !primary {
            d.input_lut = None;
        }
        if let Some(LUTRef::Embedded { media: m }) = &d.look
            && *m != media
        {
            d.look = None;
        }
        let mut e = self.clone();
        e.grade = Some(d);
        e
    }

    fn color_grade(id: Id, e: &ColorEffect, ids: &mut dyn IdSource) -> ClipEffect {
        let mut fx = ClipEffect::new(id, COLOR_KIND);
        fx.parameters = ColorGradeFields::default_parameters();
        fx.grade = Some(ColorGradeData::default());
        fx.set_color_effect(e, None, ids);
        fx
    }

    fn color_effect(&self, t: Option<Time>, id: i64) -> ColorEffect {
        let d = self.color_data();
        let mut e = ColorEffect::new(id, d.input_lut.clone());
        let raw = |key: &str| -> Option<f64> {
            let p = self.parameters.get(key)?;
            Some(t.map_or(p.value, |t| p.value_at_local(t)))
        };
        for f in ColorGradeFields::scalars() {
            if let Some(t) = t
                && f.is_hue()
                && let Some(p) = self.parameters.get(f.key)
            {
                (f.set)(&mut e, p.hue_value_at_local(t) as f32);
            } else if let Some(v) = raw(f.key) {
                (f.set)(&mut e, v as f32);
            }
        }
        if let Some(t) = t {
            for pk in ColorGradeFields::pucks() {
                if let Some((h, a)) = puck_value(self, pk, t) {
                    set_puck(&mut e, pk, WheelValue { hue: h as f32, amount: a as f32 });
                }
            }
        }
        for tg in ColorGradeFields::toggles() {
            if let Some(v) = raw(tg.key) {
                e.set_enabled(tg.section, v >= 0.5);
            }
        }
        e.basic.model = basic_tone_model(&self.parameters);
        e.set_enabled(ColorSectionKind::HslSecondary, !d.hsl_secondary_off);
        e.creative.look = d.look;
        e.curves = d.curves;
        e.hue_curves = d.hue_curves;
        e.hsl_secondary = d.hsl_secondary;
        e.set_enabled(ColorSectionKind::ZoneBoard, !d.zone_board_off);
        e.zone_board = d.zone_board;
        e
    }

    fn set_color_effect(&mut self, e: &ColorEffect, t: Option<Time>, ids: &mut dyn IdSource) {
        let before = self.clone();
        let mut write = |parameters: &mut BTreeMap<String, AnimatedProperty<f64>>, key: &str, v: f64, stepped: bool| {
            let shown = t
                .and_then(|t| before.color_shown_value(key, t))
                .unwrap_or_else(|| parameters.get(key).map_or(v, |p| t.map_or(p.value, |t| p.value_at_local(t))));
            if parameters.contains_key(key) && shown as f32 == v as f32 {
                return;
            }
            write_parameter(parameters, key, v, stepped, t, false, ids);
        };
        for f in ColorGradeFields::scalars() {
            write(&mut self.parameters, f.key, f64::from((f.get)(e)), false);
        }
        for tg in ColorGradeFields::toggles() {
            write(&mut self.parameters, tg.key, if e.is_enabled(tg.section) { 1.0 } else { 0.0 }, true);
        }
        if let Some(t) = t {
            key_wheel_partners(self, t, &before, ids);
        }
        if !self.parameters.contains_key(color_keys::BASIC_MODEL) || basic_tone_model(&self.parameters) != e.basic.model
        {
            self.parameters
                .insert(color_keys::BASIC_MODEL.to_string(), AnimatedProperty::new(f64::from(e.basic.model as i32)));
        }
        let mut d = self.color_data();
        d.input_lut = e.input_lut.clone();
        d.look = e.creative.look.clone();
        d.curves = e.curves.clone();
        d.hue_curves = e.hue_curves.clone();
        d.hsl_secondary_off = !e.is_enabled(ColorSectionKind::HslSecondary);
        d.hsl_secondary = e.hsl_secondary.clone();
        d.zone_board_off = !e.is_enabled(ColorSectionKind::ZoneBoard);
        d.zone_board = e.zone_board;
        self.grade = Some(d);
    }

    fn apply_color_edit(
        &mut self,
        base: &ColorEffect,
        e: &ColorEffect,
        t: Option<Time>,
        ids: &mut dyn IdSource,
    ) -> bool {
        let mut out = self.clone();
        for f in ColorGradeFields::scalars() {
            if (f.get)(base) != (f.get)(e)
                && !write_parameter(&mut out.parameters, f.key, f64::from((f.get)(e)), false, t, true, ids)
            {
                return false;
            }
        }
        for tg in ColorGradeFields::toggles() {
            if base.is_enabled(tg.section) != e.is_enabled(tg.section) {
                let v = if e.is_enabled(tg.section) { 1.0 } else { 0.0 };
                if !write_parameter(&mut out.parameters, tg.key, v, true, t, true, ids) {
                    return false;
                }
            }
        }
        if let Some(t) = t {
            key_wheel_partners(&mut out, t, self, ids);
        }
        // The maths flag follows the edit (e.g. a Reset) and pins down an implicit model before the sliders move away
        // from the defaults it was inferred from.
        if base.basic.model != e.basic.model || !out.parameters.contains_key(color_keys::BASIC_MODEL) {
            out.parameters
                .insert(color_keys::BASIC_MODEL.to_string(), AnimatedProperty::new(f64::from(e.basic.model as i32)));
        }
        let mut d = out.color_data();
        if base.input_lut != e.input_lut {
            d.input_lut = e.input_lut.clone();
        }
        if base.creative.look != e.creative.look {
            d.look = e.creative.look.clone();
        }
        if base.curves != e.curves {
            d.curves = e.curves.clone();
        }
        if base.hue_curves != e.hue_curves {
            d.hue_curves = e.hue_curves.clone();
        }
        if base.is_enabled(ColorSectionKind::HslSecondary) != e.is_enabled(ColorSectionKind::HslSecondary) {
            d.hsl_secondary_off = !e.is_enabled(ColorSectionKind::HslSecondary);
        }
        if base.hsl_secondary != e.hsl_secondary {
            d.hsl_secondary = e.hsl_secondary.clone();
        }
        if base.is_enabled(ColorSectionKind::ZoneBoard) != e.is_enabled(ColorSectionKind::ZoneBoard) {
            d.zone_board_off = !e.is_enabled(ColorSectionKind::ZoneBoard);
        }
        if base.zone_board != e.zone_board {
            d.zone_board = e.zone_board;
        }
        if d != out.color_data() {
            out.grade = Some(d);
        }
        *self = out;
        true
    }

    fn color_shown_value(&self, key: &str, t: Time) -> Option<f64> {
        if let Some(pk) = ColorGradeFields::pucks().iter().find(|pk| pk.hue_key == key || pk.amount_key == key)
            && let Some((hue, amount)) = puck_value(self, pk, t)
        {
            return Some(if key == pk.hue_key { hue } else { amount });
        }
        let p = self.parameters.get(key)?;
        let is_hue = ColorGradeFields::scalars().iter().find(|f| f.key == key).is_some_and(ColorScalarField::is_hue);
        Some(if is_hue { p.hue_value_at_local(t) } else { p.value_at_local(t) })
    }

    fn range_strength(&self, t: Time) -> f64 {
        let Some(r) = &self.color_range else { return 1.0 };
        if !r.contains(t) {
            return 0.0;
        }
        let dur = seconds(r.duration);
        let mut w = 1.0_f64;
        if let Some(fi) = self.color_fade_in
            && fi > Time::ZERO
        {
            let f = seconds(fi).min(dur);
            if f > 0.0 {
                w = w.min(seconds(t - r.start) / f);
            }
        }
        if let Some(fo) = self.color_fade_out
            && fo > Time::ZERO
        {
            let f = seconds(fo).min(dur);
            if f > 0.0 {
                w = w.min(seconds(r.end() - t) / f);
            }
        }
        w.clamp(0.0, 1.0)
    }
}

/// Writes a wheel puck into an effect (the Swift writable key path of `ColorPuckField`).
fn set_puck(e: &mut ColorEffect, pk: &ColorPuckField, v: WheelValue) {
    let target = if pk.hue_key == color_keys::SHADOW_TINT_HUE {
        &mut e.creative.shadow_tint
    } else if pk.hue_key == color_keys::HIGHLIGHT_TINT_HUE {
        &mut e.creative.highlight_tint
    } else if pk.hue_key == color_keys::WHEEL_SHADOWS_HUE {
        &mut e.wheels.shadows
    } else if pk.hue_key == color_keys::WHEEL_MIDTONES_HUE {
        &mut e.wheels.midtones
    } else {
        &mut e.wheels.highlights
    };
    *target = v;
}

/// A wheel with only one of its two parts keyed gets the other part keyed too at `t`, holding the value the panel
/// showed before the edit, so the puck does not jump.
fn key_wheel_partners(fx: &mut ClipEffect, t: Time, before: &ClipEffect, ids: &mut dyn IdSource) {
    for pk in ColorGradeFields::pucks() {
        let animated = |fx: &ClipEffect, key: &str| fx.parameters.get(key).is_some_and(|p| p.is_animated());
        if !(animated(fx, pk.hue_key) && animated(fx, pk.amount_key)) {
            continue;
        }
        for (edited, partner) in [(pk.hue_key, pk.amount_key), (pk.amount_key, pk.hue_key)] {
            let now =
                fx.parameters.get(edited).and_then(|p| p.track.keys.iter().find(|k| k.time == t)).map(|k| k.value);
            let was =
                before.parameters.get(edited).and_then(|p| p.track.keys.iter().find(|k| k.time == t)).map(|k| k.value);
            let Some(now) = now else { continue };
            if was == Some(now) {
                continue;
            }
            let partner_keyed = fx.parameters.get(partner).map(|p| p.track.keys.iter().any(|k| k.time == t));
            if partner_keyed != Some(false) {
                continue;
            }
            let Some(v) = before.color_shown_value(partner, t) else { continue };
            if let Some(p) = fx.parameters.get_mut(partner) {
                p.track.insert(Keyframe::new(ids.next_id(), t, v));
            }
        }
    }
}

/// Strength scaling of a Color effect (soft edges of a range grade).
pub trait ColorEffectScaleExt {
    /// The effect at strength `w` (0 = neutral, 1 = unchanged): numeric values move toward their neutral value, curves
    /// toward the identity, the Color Range correction toward no correction. LUTs fade through their intensity.
    fn scaled(&self, w: f32) -> ColorEffect;
}

impl ColorEffectScaleExt for ColorEffect {
    fn scaled(&self, w: f32) -> ColorEffect {
        let w = w.clamp(0.0, 1.0);
        let mut e = self.clone();
        let neutral = ColorEffect::new(self.id, None);
        let lut_keys = [color_keys::INPUT_LUT_INTENSITY, color_keys::LOOK_INTENSITY];
        let mix = |v: f32, n: f32| -> f32 { n + (v - n) * w };
        for f in ColorGradeFields::scalars().iter().filter(|f| !f.is_hue()) {
            let n = if lut_keys.contains(&f.key) { 0.0 } else { (f.get)(&neutral) };
            (f.set)(&mut e, mix((f.get)(self), n));
        }
        let pts = |p: &[CurvePoint], flat: bool| -> Vec<CurvePoint> {
            p.iter().map(|q| CurvePoint { x: q.x, y: mix(q.y, if flat { 0.5 } else { q.x }) }).collect()
        };
        e.curves.master = pts(&self.curves.master, false);
        e.curves.red = pts(&self.curves.red, false);
        e.curves.green = pts(&self.curves.green, false);
        e.curves.blue = pts(&self.curves.blue, false);
        e.hue_curves.hue_vs_sat = pts(&self.hue_curves.hue_vs_sat, true);
        e.hue_curves.hue_vs_hue = pts(&self.hue_curves.hue_vs_hue, true);
        e.hue_curves.hue_vs_luma = pts(&self.hue_curves.hue_vs_luma, true);
        e.hue_curves.luma_vs_sat = pts(&self.hue_curves.luma_vs_sat, true);
        e.hue_curves.sat_vs_sat = pts(&self.hue_curves.sat_vs_sat, true);
        if let Some(mut h) = self.hsl_secondary.clone() {
            h.hue_shift = mix(h.hue_shift, 0.0);
            h.saturation = mix(h.saturation, 100.0);
            h.exposure = mix(h.exposure, 0.0);
            h.temperature = mix(h.temperature, 0.0);
            h.tint = mix(h.tint, 0.0);
            e.hsl_secondary = Some(h);
        }
        if let Some(mut z) = self.zone_board {
            for zone in BoardZone::ALL {
                let mut v = z.zone(zone);
                v.puck_x = mix(v.puck_x, 0.5);
                v.puck_y = mix(v.puck_y, 0.5);
                v.saturation = mix(v.saturation, 0.5);
                v.exposure = mix(v.exposure, 0.5);
                z.set_zone(zone, v);
            }
            e.zone_board = Some(z);
        }
        e
    }
}
