// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ClipEffect.swift

use crate::{
    AnimatedProperty, BasicToneModel, Clip, ColorGradeData, ColorGraph, EffectCatalog, EffectParamKind, UnknownKeys,
    pin_basic_model,
};
use serde::{Deserialize, Serialize};
use sq_core_time::{Id, KeyframeValue, Time, TimeRange, Vec2};
use std::collections::BTreeMap;

/// An applied effect with its animatable parameters.
///
/// Reading pins the Basic Correction maths on a Color effect stored without it (`pin_basic_model`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", from = "ClipEffectWire")]
pub struct ClipEffect {
    /// Identity.
    pub id: Id,
    /// Catalog kind, e.g. "gaussianBlur".
    pub kind: String,
    /// fx toggle.
    pub enabled: bool,
    /// Slider, checkbox and choice values by parameter key.
    pub parameters: BTreeMap<String, AnimatedProperty<f64>>,
    /// Color parameters (v24); written only when not empty.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub colors: BTreeMap<String, AnimatedProperty<EffectColor>>,
    /// Point parameters (v24); written only when not empty.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub points: BTreeMap<String, AnimatedProperty<Vec2>>,
    /// Grade of a Color effect (v27).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grade: Option<ColorGradeData>,
    /// Clip-local range a color effect is limited to.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color_range: Option<TimeRange>,
    /// Fade in of a limited color effect.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color_fade_in: Option<Time>,
    /// Fade out of a limited color effect.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color_fade_out: Option<Time>,
    /// Masks (clip mask ids) the effect is limited to.
    #[serde(rename = "masks", default, skip_serializing_if = "Vec::is_empty")]
    pub mask_input: Vec<Id>,
    /// Node graph of a Color effect.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color_graph: Option<ColorGraph>,
    /// Track whose picture is the matte.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mask_track: Option<Id>,
    /// Keys of a newer file that this build does not know; kept and written back.
    #[serde(flatten, default, skip_serializing_if = "UnknownKeys::is_empty")]
    pub unknown: UnknownKeys,
}

/// The coded shape of `ClipEffect`; `From` runs the decode step that needs several fields at once.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClipEffectWire {
    id: Id,
    kind: String,
    enabled: bool,
    parameters: BTreeMap<String, AnimatedProperty<f64>>,
    #[serde(default)]
    colors: BTreeMap<String, AnimatedProperty<EffectColor>>,
    #[serde(default)]
    points: BTreeMap<String, AnimatedProperty<Vec2>>,
    #[serde(default)]
    grade: Option<ColorGradeData>,
    #[serde(default)]
    color_range: Option<TimeRange>,
    #[serde(default)]
    color_fade_in: Option<Time>,
    #[serde(default)]
    color_fade_out: Option<Time>,
    #[serde(rename = "masks", default)]
    mask_input: Vec<Id>,
    #[serde(default)]
    color_graph: Option<ColorGraph>,
    #[serde(default)]
    mask_track: Option<Id>,
    #[serde(flatten)]
    unknown: UnknownKeys,
}

impl From<ClipEffectWire> for ClipEffect {
    fn from(w: ClipEffectWire) -> ClipEffect {
        let mut e = ClipEffect {
            id: w.id,
            kind: w.kind,
            enabled: w.enabled,
            parameters: w.parameters,
            colors: w.colors,
            points: w.points,
            grade: w.grade,
            color_range: w.color_range,
            color_fade_in: w.color_fade_in,
            color_fade_out: w.color_fade_out,
            mask_input: w.mask_input,
            color_graph: w.color_graph,
            mask_track: w.mask_track,
            unknown: w.unknown,
        };
        // A Color effect stored before the Basic Correction maths flag: pin the model it is read with now, so a later
        // slider move (from any panel) cannot flip an untouched effect back to the legacy maths.
        pin_basic_model(&e.kind, &mut e.parameters);
        e
    }
}

impl ClipEffect {
    /// Kind of the Rounded Corners effect.
    pub const ROUNDED_CORNERS_KIND: &'static str = "roundedCorners";
    /// Rounded Corners radius.
    pub const RADIUS_KEY: &'static str = "radius";
    /// Kind of the Crop effect.
    pub const CROP_KIND: &'static str = "crop";
    /// Crop edges.
    pub const CROP_LEFT_KEY: &'static str = "left";
    /// Crop edges.
    pub const CROP_TOP_KEY: &'static str = "top";
    /// Crop edges.
    pub const CROP_RIGHT_KEY: &'static str = "right";
    /// Crop edges.
    pub const CROP_BOTTOM_KEY: &'static str = "bottom";
    /// Soft edge of the crop, px of the clip's own frame (0 = hard edge). Not stored by Crops saved before it: reads 0.
    pub const CROP_SOFTNESS_KEY: &'static str = "softness";
    /// Kind of the Gaussian Blur effect.
    pub const GAUSSIAN_BLUR_KIND: &'static str = "gaussianBlur";
    /// Blurriness in Premiere's units (Premiere value = SQ value); the effect turns it into a Gaussian sigma in px with
    /// `gaussian_sigma`.
    pub const BLURRINESS_KEY: &'static str = "blurriness";
    /// Gaussian sigma (px) per Premiere Blurriness unit. Measured with Tools/PrprojFidelity on iOS 27 Features #1
    /// (Blurriness 200, Repeat Edge Pixels on): 0.25...0.42 within 0.1 dB of Premiere's export, 1.0 is 1.3 dB worse and
    /// 4x the bad pixels; 0.35 is the middle of the flat optimum.
    pub const GAUSSIAN_SIGMA_PER_BLURRINESS: f64 = 0.35;
    /// Drop Shadow Softness is in Premiere units too: Premiere's shadow is a Gaussian of sigma ~0.2 x Softness
    /// (fidelity sweep on the maintainer's Drop Shadow nest, softness 177: luma bias -1.9 at Softness / 2, ~0 at 0.2).
    pub const SHADOW_SIGMA_PER_SOFTNESS: f64 = 0.2;
    /// Gaussian Blur checkbox: samples outside the frame repeat the edge pixels and the result is cut to the frame, so
    /// the edge stays opaque (Premiere's Repeat Edge Pixels). Off: the blur fades into transparency past the frame.
    pub const REPEAT_EDGE_PIXELS_KEY: &'static str = "repeatEdgePixels";
    /// Kind of the Ultra Key effect.
    pub const ULTRA_KEY_KIND: &'static str = "ultraKey";
    /// Kind of the Drop Shadow effect.
    pub const DROP_SHADOW_KIND: &'static str = "dropShadow";
    /// Shadow color (v24).
    pub const SHADOW_COLOR_KEY: &'static str = "shadowColor";
    /// v23 and older: the shadow color as three 0...255 channel parameters (the v24 migration folds them into
    /// `SHADOW_COLOR_KEY`).
    pub const SHADOW_RED_KEY: &'static str = "shadowRed";
    /// See `SHADOW_RED_KEY`.
    pub const SHADOW_GREEN_KEY: &'static str = "shadowGreen";
    /// See `SHADOW_RED_KEY`.
    pub const SHADOW_BLUE_KEY: &'static str = "shadowBlue";
    /// Drop Shadow parameter.
    pub const SHADOW_OPACITY_KEY: &'static str = "shadowOpacity";
    /// Drop Shadow parameter.
    pub const SHADOW_DIRECTION_KEY: &'static str = "shadowDirection";
    /// Drop Shadow parameter.
    pub const SHADOW_DISTANCE_KEY: &'static str = "shadowDistance";
    /// Drop Shadow parameter.
    pub const SHADOW_SOFTNESS_KEY: &'static str = "shadowSoftness";
    /// Drop Shadow parameter.
    pub const SHADOW_SPREAD_KEY: &'static str = "shadowSpread";
    /// Drop Shadow parameter.
    pub const SHADOW_ONLY_KEY: &'static str = "shadowOnly";
    /// Ultra Key parameter.
    pub const KEY_HUE_KEY: &'static str = "keyHue";
    /// Ultra Key parameter.
    pub const TOLERANCE_KEY: &'static str = "tolerance";
    /// Ultra Key parameter.
    pub const SOFTEN_KEY: &'static str = "soften";
    /// Ultra Key parameter.
    pub const SPILL_KEY: &'static str = "spill";
    /// Ultra Key parameter.
    pub const CHOKE_KEY: &'static str = "choke";
    /// Ultra Key parameter.
    pub const PEDESTAL_KEY: &'static str = "pedestal";
    /// Ultra Key parameter.
    pub const KEY_OUTPUT_KEY: &'static str = "keyOutput";
    /// Ultra Key matte clean-up.
    pub const KEY_CONTRAST_KEY: &'static str = "keyContrast";
    /// Ultra Key matte clean-up.
    pub const KEY_MIDPOINT_KEY: &'static str = "keyMidpoint";
    /// Ultra Key matte clean-up.
    pub const KEY_HIGHLIGHT_KEY: &'static str = "keyHighlight";
    /// Ultra Key matte clean-up.
    pub const KEY_SHADOW_KEY: &'static str = "keyShadow";
    /// Ultra Key spill range.
    pub const SPILL_RANGE_KEY: &'static str = "spillRange";
    /// Ultra Key color correction.
    pub const KEY_SATURATION_KEY: &'static str = "keySaturation";
    /// Ultra Key color correction.
    pub const KEY_HUE_SHIFT_KEY: &'static str = "keyHueShift";
    /// Ultra Key color correction.
    pub const KEY_LUMA_KEY: &'static str = "keyLuma";
    /// Kind of the Luma Key effect.
    pub const LUMA_KEY_KIND: &'static str = "lumaKey";
    /// Luma Key parameter.
    pub const LUMA_THRESHOLD_KEY: &'static str = "lumaThreshold";
    /// Luma Key parameter.
    pub const LUMA_SOFTNESS_KEY: &'static str = "lumaSoftness";
    /// Luma Key parameter.
    pub const LUMA_KEY_OUT_KEY: &'static str = "lumaKeyOut";
    /// Film / tape look: Gate Weave.
    pub const GATE_WEAVE_KIND: &'static str = "gateWeave";
    /// Film / tape look: Scanlines.
    pub const SCANLINES_KIND: &'static str = "scanlines";
    /// Film / tape look: Chroma Bleed.
    pub const CHROMA_BLEED_KIND: &'static str = "chromaBleed";
    /// Film / tape look: Tracking Noise.
    pub const TRACKING_NOISE_KIND: &'static str = "trackingNoise";
    /// Aged Film: dust specks, vertical scratches and exposure flicker of worn film (one effect, one pass).
    pub const AGED_FILM_KIND: &'static str = "agedFilm";
    /// Aged Film parameter.
    pub const DUST_KEY: &'static str = "dust";
    /// Aged Film parameter.
    pub const SCRATCHES_KEY: &'static str = "scratches";
    /// Aged Film parameter.
    pub const FLICKER_KEY: &'static str = "flicker";
    /// Film / tape look parameter.
    pub const AMOUNT_KEY: &'static str = "amount";
    /// Film / tape look parameter.
    pub const INTENSITY_KEY: &'static str = "intensity";
    /// Film / tape look parameter.
    pub const SPEED_KEY: &'static str = "speed";
    /// Film / tape look parameter.
    pub const ROTATION_KEY: &'static str = "rotation";
    /// Film / tape look parameter.
    pub const SPACING_KEY: &'static str = "spacing";
    /// Film / tape look parameter.
    pub const THICKNESS_KEY: &'static str = "thickness";
    /// Film / tape look parameter.
    pub const BLEED_KEY: &'static str = "bleed";
    /// Film / tape look parameter.
    pub const SHIFT_KEY: &'static str = "shift";
    /// Film / tape look parameter.
    pub const BAND_HEIGHT_KEY: &'static str = "bandHeight";

    /// An enabled effect of `kind` without parameters.
    pub fn new(id: Id, kind: &str) -> ClipEffect {
        ClipEffect {
            id,
            kind: kind.to_string(),
            enabled: true,
            parameters: BTreeMap::new(),
            colors: BTreeMap::new(),
            points: BTreeMap::new(),
            grade: None,
            color_range: None,
            color_fade_in: None,
            color_fade_out: None,
            mask_input: Vec::new(),
            color_graph: None,
            mask_track: None,
            unknown: UnknownKeys::default(),
        }
    }

    /// Gaussian sigma in px for a Blurriness value.
    pub fn gaussian_sigma(blurriness: f64) -> f64 {
        blurriness.max(0.0) * Self::GAUSSIAN_SIGMA_PER_BLURRINESS
    }

    /// Radius in sequence pixels of the clip's own frame; 0 = square.
    pub fn rounded_corners(id: Id, radius: f64) -> ClipEffect {
        let mut e = ClipEffect::new(id, Self::ROUNDED_CORNERS_KIND);
        e.parameters.insert(Self::RADIUS_KEY.to_string(), AnimatedProperty::new(radius));
        e
    }

    /// Slider, checkbox and choice values an effect starts with (what "Reset" restores).
    pub fn default_parameters(kind: &str) -> BTreeMap<String, AnimatedProperty<f64>> {
        let mut out = BTreeMap::new();
        if let Some(spec) = EffectCatalog::spec_for(kind) {
            // The linked Y member of a pair is stored only while unlinked.
            let linked_y: Vec<&str> = spec.pairs.iter().filter(|p| p.linkable).map(|p| p.y.as_str()).collect();
            for p in spec.params.iter().filter(|p| p.kind.is_scalar() && !linked_y.contains(&p.key.as_str())) {
                out.insert(p.key.clone(), AnimatedProperty::new(p.default_value));
            }
        }
        if kind == Self::COLOR_KIND {
            out.insert(
                Self::COLOR_BASIC_MODEL_KEY.to_string(),
                AnimatedProperty::new(BasicToneModel::CURRENT as i64 as f64),
            );
        }
        if kind == Self::LENS_DISTORTION_KIND {
            out.insert(Self::LENS_MODEL_KEY.to_string(), AnimatedProperty::new(1.0));
        }
        out
    }

    /// Color values an effect starts with.
    pub fn default_colors(kind: &str) -> BTreeMap<String, AnimatedProperty<EffectColor>> {
        let params = EffectCatalog::spec_for(kind).map(|s| s.params).unwrap_or_default();
        params
            .into_iter()
            .filter_map(|p| match p.kind {
                EffectParamKind::Color(c) => Some((p.key, AnimatedProperty::new(c))),
                _ => None,
            })
            .collect()
    }

    /// Point values an effect starts with.
    pub fn default_points(kind: &str) -> BTreeMap<String, AnimatedProperty<Vec2>> {
        let params = EffectCatalog::spec_for(kind).map(|s| s.params).unwrap_or_default();
        params
            .into_iter()
            .filter_map(|p| match p.kind {
                EffectParamKind::Point(v) => Some((p.key, AnimatedProperty::new(v))),
                _ => None,
            })
            .collect()
    }

    /// The value a kind's parameter gets when the user applies it to a clip (`Clip.addEffect`), where it differs from the
    /// stored default: Blur, Sharpen and Spherize would show nothing at 0, Stereo Width at 150 % changes the sound on drop
    /// (AUDIT A10, G13). Only NEW instances use them: `default_parameters` (Reset, stored files, internal effects) is
    /// unchanged, so existing projects render identically.
    pub fn applied_start_value(kind: &str, key: &str) -> Option<f64> {
        match (kind, key) {
            (Self::GAUSSIAN_BLUR_KIND, Self::BLURRINESS_KEY) => Some(20.0),
            (Self::SHARPEN_KIND, Self::SHARPEN_AMOUNT_KEY) => Some(50.0),
            (Self::SPHERIZE_KIND, Self::SPHERIZE_RADIUS_KEY) => Some(400.0),
            (Self::AUDIO_STEREO_WIDTH_KIND, Self::STEREO_WIDTH_KEY) => Some(100.0),
            _ => None,
        }
    }

    /// A new instance of `kind` with its default values; `None` for an unknown kind.
    pub fn make(id: Id, kind: &str) -> Option<ClipEffect> {
        EffectCatalog::spec_for(kind)?;
        let mut e = ClipEffect::new(id, kind);
        e.parameters = Self::default_parameters(kind);
        e.colors = Self::default_colors(kind);
        e.points = Self::default_points(kind);
        Some(e)
    }

    /// Clip-local times of every key of every parameter.
    pub fn key_times(&self) -> Vec<Time> {
        let params = self.parameters.values().flat_map(|p| p.track.keys.iter().map(|k| k.time));
        let colors = self.colors.values().flat_map(|p| p.track.keys.iter().map(|k| k.time));
        let points = self.points.values().flat_map(|p| p.track.keys.iter().map(|k| k.time));
        params.chain(colors).chain(points).collect()
    }

    /// Every parameter frozen at clip-local `t` (no keys): what a frame hold keeps.
    #[doc(hidden)]
    pub fn frozen_at_local(&self, t: Time) -> ClipEffect {
        let mut e = self.clone();
        e.parameters =
            self.parameters.iter().map(|(k, p)| (k.clone(), AnimatedProperty::new(p.value_at_local(t)))).collect();
        e.colors = self.colors.iter().map(|(k, p)| (k.clone(), AnimatedProperty::new(p.value_at_local(t)))).collect();
        e.points = self.points.iter().map(|(k, p)| (k.clone(), AnimatedProperty::new(p.value_at_local(t)))).collect();
        e
    }

    /// Key times and the color range through `f` (a retime); fades keep the length between their mapped ends.
    #[doc(hidden)]
    pub fn remapped(&self, f: impl Fn(Time) -> Time) -> ClipEffect {
        let mut e = self.clone();
        e.parameters = self.parameters.iter().map(|(k, p)| (k.clone(), p.remapped(&f))).collect();
        e.colors = self.colors.iter().map(|(k, p)| (k.clone(), p.remapped(&f))).collect();
        e.points = self.points.iter().map(|(k, p)| (k.clone(), p.remapped(&f))).collect();
        e.color_range = self.color_range.map(|r| {
            let (a, b) = (f(r.start), f(r.end()));
            TimeRange::from_end(a.min(b), a.max(b))
        });
        if let Some(r) = self.color_range {
            let dist = |a: Time, b: Time| if a < b { b - a } else { a - b };
            e.color_fade_in = self.color_fade_in.map(|d| dist(f(r.start + d), f(r.start)));
            e.color_fade_out = self.color_fade_out.map(|d| dist(f(r.end()), f(r.end() - d)));
        }
        e
    }

    /// Key times and the color range moved by `delta`.
    pub fn shifted(&self, delta: Time) -> ClipEffect {
        let mut e = self.clone();
        e.parameters = self.parameters.iter().map(|(k, p)| (k.clone(), p.shifted(delta))).collect();
        e.colors = self.colors.iter().map(|(k, p)| (k.clone(), p.shifted(delta))).collect();
        e.points = self.points.iter().map(|(k, p)| (k.clone(), p.shifted(delta))).collect();
        e.color_range = self.color_range.map(|r| TimeRange::new(r.start + delta, r.duration));
        e
    }
}

/// An RGBA color parameter, channels nominally 0...1.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct EffectColor {
    /// Red.
    pub red: f64,
    /// Green.
    pub green: f64,
    /// Blue.
    pub blue: f64,
    /// Alpha.
    pub alpha: f64,
}

impl EffectColor {
    /// Opaque black.
    pub const BLACK: EffectColor = EffectColor { red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0 };
    /// Opaque white.
    pub const WHITE: EffectColor = EffectColor { red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0 };

    /// Every channel inside 0...1.
    pub fn clamped(&self) -> EffectColor {
        EffectColor {
            red: self.red.clamp(0.0, 1.0),
            green: self.green.clamp(0.0, 1.0),
            blue: self.blue.clamp(0.0, 1.0),
            alpha: self.alpha.clamp(0.0, 1.0),
        }
    }

    /// The three color channels.
    pub fn rgb(&self) -> [f64; 3] {
        [self.red, self.green, self.blue]
    }

    fn zip(a: &EffectColor, b: &EffectColor, op: impl Fn(f64, f64) -> f64) -> EffectColor {
        EffectColor {
            red: op(a.red, b.red),
            green: op(a.green, b.green),
            blue: op(a.blue, b.blue),
            alpha: op(a.alpha, b.alpha),
        }
    }
}

impl KeyframeValue for EffectColor {
    fn lerp(a: &EffectColor, b: &EffectColor, t: f64) -> EffectColor {
        Self::zip(a, b, |x, y| x + (y - x) * t)
    }
    fn plus(a: &EffectColor, b: &EffectColor) -> EffectColor {
        Self::zip(a, b, |x, y| x + y)
    }
    fn minus(a: &EffectColor, b: &EffectColor) -> EffectColor {
        Self::zip(a, b, |x, y| x - y)
    }
    fn speed_magnitude(&self) -> f64 {
        (self.red * self.red + self.green * self.green + self.blue * self.blue + self.alpha * self.alpha).sqrt()
    }
}

impl Clip {
    /// The first effect of `kind`.
    pub fn effect_of_kind(&self, kind: &str) -> Option<&ClipEffect> {
        self.effects.iter().find(|e| e.kind == kind)
    }

    /// The Rounded Corners effect when applied.
    pub fn rounded_corners_effect(&self) -> Option<&ClipEffect> {
        self.effect_of_kind(ClipEffect::ROUNDED_CORNERS_KIND)
    }

    /// Sets the Rounded Corners effect: `None` removes it, a value replaces or appends it.
    pub fn set_rounded_corners_effect(&mut self, new: Option<ClipEffect>) {
        let i = self.effects.iter().position(|e| e.kind == ClipEffect::ROUNDED_CORNERS_KIND);
        match (i, new) {
            (Some(i), Some(n)) => self.effects[i] = n,
            (Some(i), None) => {
                self.effects.remove(i);
            }
            (None, Some(n)) => self.effects.push(n),
            (None, None) => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clip_animation::test_util::clip;
    use crate::{BasicToneModel, COLOR_BASIC_MODEL_KEY, COLOR_KIND, TrackKind};
    use serde_json::json;
    use sq_core_time::Keyframe;

    const ID: &str = "00000000-0000-0000-0000-000000000001";

    fn read(v: serde_json::Value) -> ClipEffect {
        serde_json::from_value(v).unwrap_or_else(|e| panic!("effect: {e}"))
    }

    #[test]
    fn optional_keys_are_absent_before_v24_and_not_written_when_empty() {
        let e = read(json!({"id": ID, "kind": "gaussianBlur", "enabled": true,
            "parameters": {"blurriness": {"value": 20.0, "track": {"keys": []}}}}));
        assert!(e.colors.is_empty() && e.points.is_empty() && e.grade.is_none() && e.mask_input.is_empty());
        let out = serde_json::to_value(&e).unwrap_or_default();
        for key in ["colors", "points", "grade", "masks", "colorRange", "colorGraph", "maskTrack"] {
            assert!(out.get(key).is_none(), "{key}");
        }
        assert_eq!(read(out), e);
    }

    #[test]
    fn a_color_effect_without_the_maths_flag_gets_the_model_pinned() {
        let untouched = read(json!({"id": ID, "kind": COLOR_KIND, "enabled": true, "parameters": {}}));
        assert_eq!(untouched.parameters[COLOR_BASIC_MODEL_KEY].value, f64::from(BasicToneModel::CURRENT as i32));
        let moved = read(json!({"id": ID, "kind": COLOR_KIND, "enabled": true,
            "parameters": {"exposure": {"value": 1.0}}}));
        assert_eq!(moved.parameters[COLOR_BASIC_MODEL_KEY].value, f64::from(BasicToneModel::Legacy as i32));
        let other = read(json!({"id": ID, "kind": "gaussianBlur", "enabled": true, "parameters": {}}));
        assert!(other.parameters.is_empty());
    }

    #[test]
    fn masks_key_and_color_range_round_trip() {
        let j = json!({"id": ID, "kind": "dropShadow", "enabled": false, "parameters": {},
            "masks": [ID], "maskTrack": ID,
            "colorRange": {"start": {"value": 1, "timescale": 1}, "duration": {"value": 2, "timescale": 1}},
            "colorFadeIn": {"value": 1, "timescale": 2}});
        let e = read(j.clone());
        assert_eq!(e.mask_input.len(), 1);
        assert_eq!(e.color_fade_in, Some(Time::new(1, 2)));
        assert_eq!(serde_json::to_value(&e).unwrap_or_default()["masks"], j["masks"]);
    }

    #[test]
    fn sigma_helpers_and_rounded_corners() {
        assert_eq!(ClipEffect::gaussian_sigma(-5.0), 0.0);
        assert!((ClipEffect::gaussian_sigma(200.0) - 70.0).abs() < 1e-9);
        let e = ClipEffect::rounded_corners(Id::from_u128(1), 24.0);
        assert_eq!(e.kind, "roundedCorners");
        assert_eq!(e.parameters["radius"].value, 24.0);
    }

    #[test]
    fn key_times_cover_every_parameter_kind_and_frozen_drops_the_keys() {
        let mut e = ClipEffect::new(Id::from_u128(1), "x");
        let mut p = AnimatedProperty::new(0.0);
        p.track = sq_core_time::KeyframeTrack::with_keys(vec![
            Keyframe::new(Id::from_u128(2), Time::new(1, 1), 0.0),
            Keyframe::new(Id::from_u128(3), Time::new(3, 1), 10.0),
        ]);
        e.parameters.insert("a".into(), p);
        let mut c = AnimatedProperty::new(EffectColor::BLACK);
        c.track = sq_core_time::KeyframeTrack::with_keys(vec![Keyframe::new(
            Id::from_u128(4),
            Time::new(2, 1),
            EffectColor::WHITE,
        )]);
        e.colors.insert("c".into(), c);
        let mut times = e.key_times();
        times.sort();
        assert_eq!(times, vec![Time::new(1, 1), Time::new(2, 1), Time::new(3, 1)]);
        let f = e.frozen_at_local(Time::new(2, 1));
        assert!(f.key_times().is_empty());
        assert_eq!(f.parameters["a"].value, 5.0);
        assert_eq!(f.colors["c"].value, EffectColor::WHITE);
    }

    #[test]
    fn rounded_corners_accessor_replaces_appends_and_removes() {
        let mut c = clip(TrackKind::Video, 0, 4);
        assert!(c.rounded_corners_effect().is_none());
        c.set_rounded_corners_effect(Some(ClipEffect::rounded_corners(Id::from_u128(1), 10.0)));
        c.set_rounded_corners_effect(Some(ClipEffect::rounded_corners(Id::from_u128(2), 30.0)));
        assert_eq!(c.effects.len(), 1);
        assert_eq!(c.rounded_corners_effect().map(|e| e.parameters["radius"].value), Some(30.0));
        c.set_rounded_corners_effect(None);
        assert!(c.effects.is_empty());
    }

    #[test]
    fn color_helpers() {
        let c = EffectColor { red: 2.0, green: -1.0, blue: 0.5, alpha: 3.0 }.clamped();
        assert_eq!((c.red, c.green, c.blue, c.alpha), (1.0, 0.0, 0.5, 1.0));
        assert_eq!(EffectColor::WHITE.rgb(), [1.0, 1.0, 1.0]);
    }

    #[test]
    fn make_gives_the_catalog_defaults_and_nothing_for_an_unknown_kind() {
        let id = Id::from_u128(5);
        let blur = ClipEffect::make(id, ClipEffect::GAUSSIAN_BLUR_KIND).unwrap_or_else(|| panic!("blur"));
        assert_eq!(blur.id, id);
        assert_eq!(blur.parameters[ClipEffect::BLURRINESS_KEY].value, 0.0);
        assert_eq!(blur.parameters[ClipEffect::REPEAT_EDGE_PIXELS_KEY].value, 0.0);
        assert!(ClipEffect::make(id, "noSuchEffect").is_none());
        let shadow = ClipEffect::make(id, ClipEffect::DROP_SHADOW_KIND).unwrap_or_else(|| panic!("shadow"));
        assert_eq!(shadow.colors[ClipEffect::SHADOW_COLOR_KEY].value, EffectColor::BLACK);
        assert_eq!(shadow.parameters[ClipEffect::SHADOW_DIRECTION_KEY].value, 135.0);
        let mirror = ClipEffect::make(id, ClipEffect::MIRROR_KIND).unwrap_or_else(|| panic!("mirror"));
        assert_eq!(mirror.points[ClipEffect::MIRROR_CENTER_KEY].value, Vec2::ZERO);
        assert!(mirror.colors.is_empty() && !mirror.parameters.contains_key(ClipEffect::MIRROR_CENTER_KEY));
        let gradient = ClipEffect::make(id, ClipEffect::GRADIENT_KIND).unwrap_or_else(|| panic!("gradient"));
        assert_eq!(gradient.points[ClipEffect::GRADIENT_END_KEY].value, Vec2::new(0.0, 400.0));
    }

    #[test]
    fn the_unlinked_scale_height_is_not_created_by_default() {
        let transform = ClipEffect::default_parameters(ClipEffect::TRANSFORM_KIND);
        assert!(
            transform.contains_key(ClipEffect::STAGE_SCALE_KEY)
                && !transform.contains_key(ClipEffect::STAGE_SCALE_Y_KEY)
        );
        assert_eq!(transform[ClipEffect::STAGE_SCALE_KEY].value, 100.0);
    }

    #[test]
    fn hidden_model_keys_are_written_by_the_defaults_of_their_kinds() {
        let lens = ClipEffect::default_parameters(ClipEffect::LENS_DISTORTION_KIND);
        assert_eq!(lens[ClipEffect::LENS_MODEL_KEY].value, 1.0);
        let color = ClipEffect::default_parameters(ClipEffect::COLOR_KIND);
        assert_eq!(color[ClipEffect::COLOR_BASIC_MODEL_KEY].value, BasicToneModel::CURRENT as i64 as f64);
        assert_eq!(color[ClipEffect::COLOR_BASIC_ON_KEY].value, 1.0);
        assert!(ClipEffect::default_parameters("noSuchEffect").is_empty());
    }

    #[test]
    fn applied_start_values_differ_from_the_catalog_defaults_only_for_four_kinds() {
        // AUDIT G13: a freshly applied Blur / Sharpen / Spherize shows a visible value, Stereo Width starts neutral.
        let start = ClipEffect::applied_start_value;
        assert_eq!(start(ClipEffect::GAUSSIAN_BLUR_KIND, ClipEffect::BLURRINESS_KEY), Some(20.0));
        assert_eq!(start(ClipEffect::SHARPEN_KIND, ClipEffect::SHARPEN_AMOUNT_KEY), Some(50.0));
        assert_eq!(start(ClipEffect::SPHERIZE_KIND, ClipEffect::SPHERIZE_RADIUS_KEY), Some(400.0));
        assert_eq!(start(ClipEffect::AUDIO_STEREO_WIDTH_KIND, ClipEffect::STEREO_WIDTH_KEY), Some(100.0));
        assert_eq!(start(ClipEffect::GAUSSIAN_BLUR_KIND, ClipEffect::REPEAT_EDGE_PIXELS_KEY), None);
        // The catalog defaults (Reset, stored files, internal effects) stay.
        let default = |kind: &str, key: &str| ClipEffect::default_parameters(kind)[key].value;
        assert_eq!(default(ClipEffect::GAUSSIAN_BLUR_KIND, ClipEffect::BLURRINESS_KEY), 0.0);
        assert_eq!(default(ClipEffect::SHARPEN_KIND, ClipEffect::SHARPEN_AMOUNT_KEY), 0.0);
        assert_eq!(default(ClipEffect::AUDIO_STEREO_WIDTH_KIND, ClipEffect::STEREO_WIDTH_KEY), 150.0);
    }

    #[test]
    fn parameter_readers_clamp_to_the_catalog_and_fall_back_to_its_defaults() {
        let mut e = ClipEffect::new(Id::from_u128(1), ClipEffect::DROP_SHADOW_KIND);
        let t = Time::ZERO;
        assert_eq!(e.scalar(ClipEffect::SHADOW_DISTANCE_KEY, t), 5.0, "missing: the catalog default");
        e.parameters.insert(ClipEffect::SHADOW_OPACITY_KEY.into(), AnimatedProperty::new(250.0));
        assert_eq!(e.scalar(ClipEffect::SHADOW_OPACITY_KEY, t), 100.0, "clamped to the range");
        e.parameters.insert(ClipEffect::SHADOW_OPACITY_KEY.into(), AnimatedProperty::new(f64::NAN));
        assert_eq!(e.scalar(ClipEffect::SHADOW_OPACITY_KEY, t), 50.0, "NaN becomes the default");
        assert_eq!(e.scalar("unknown", t), 0.0);
        assert_eq!(ClipEffect::sanitized(f64::INFINITY, "unknown", "k"), 0.0);
        assert_eq!(ClipEffect::sanitized(f64::INFINITY, ClipEffect::SHADOW_OPACITY_KEY, "x"), 0.0);
        e.colors.insert(
            ClipEffect::SHADOW_COLOR_KEY.into(),
            AnimatedProperty::new(EffectColor { red: 1.4, green: -0.2, blue: 0.5, alpha: 1.0 }),
        );
        assert_eq!(
            e.color(ClipEffect::SHADOW_COLOR_KEY, t),
            EffectColor { red: 1.0, green: 0.0, blue: 0.5, alpha: 1.0 }
        );
        assert!(!e.flag(ClipEffect::SHADOW_ONLY_KEY, t));
        let mirror = ClipEffect::new(Id::from_u128(2), ClipEffect::MIRROR_KIND);
        assert_eq!(mirror.point(ClipEffect::MIRROR_CENTER_KEY, t), Vec2::ZERO);
        let glow = ClipEffect::new(Id::from_u128(3), ClipEffect::GLOW_KIND);
        assert_eq!(
            (glow.choice(ClipEffect::GLOW_COLORS_KEY, t), glow.color(ClipEffect::GLOW_COLOR_KEY, t)),
            (0, EffectColor::WHITE)
        );
    }

    #[test]
    fn hue_parameters_read_the_short_way_round_and_wrap() {
        let mut e = ClipEffect::new(Id::from_u128(1), ClipEffect::ULTRA_KEY_KIND);
        let mut p = AnimatedProperty::new(350.0);
        p.track.insert(Keyframe::new(Id::from_u128(1), Time::ZERO, 350.0));
        p.track.insert(Keyframe::new(Id::from_u128(2), Time::new(2, 1), 10.0));
        e.parameters.insert(ClipEffect::KEY_HUE_KEY.into(), p);
        assert!((e.scalar(ClipEffect::KEY_HUE_KEY, Time::new(3, 2)) - 5.0).abs() < 1e-9);
        e.parameters.insert(ClipEffect::KEY_HUE_KEY.into(), AnimatedProperty::new(370.0));
        assert_eq!(
            e.scalar(ClipEffect::KEY_HUE_KEY, Time::ZERO),
            10.0,
            "an imported 370 is hue 10, not the clamped 360"
        );
    }
}
