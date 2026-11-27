// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: EffectsCatalog.swift (types, their helpers, the W3.1 specs and the lookups); the entries of the single effect files sit
// in the child modules

mod audio_keys;
mod audio_specs;
mod eval;
mod keys;
mod motion_specs;
mod stage_specs;
mod style_specs;
mod util;
mod video_specs;

use crate::{ClipEffect, EffectColor, hidden_catalog};
use sq_core_time::Vec2;
use std::ops::RangeInclusive;
use std::sync::OnceLock;

/// Control type of an effect parameter.
#[derive(Clone, Debug, PartialEq)]
pub enum EffectParamKind {
    /// Number slider.
    Slider,
    /// On/off (stored as 0 or 1).
    Checkbox,
    /// Pop-up menu with these titles (stored as the index).
    Choice(Vec<String>),
    /// Color well with its default.
    Color(EffectColor),
    /// Point with its default.
    Point(Vec2),
}

/// Which picture side a parameter scales with.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PictureAxis {
    /// The width.
    Width,
    /// The height.
    Height,
}

/// Two parameters shown as one linked pair (X and Y).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct EffectParamPair {
    /// Row title.
    pub title: String,
    /// Key of the X member.
    pub x: String,
    /// Key of the Y member.
    pub y: String,
    /// Y is stored only while the pair is unlinked.
    pub linkable: bool,
}

/// One parameter of a catalog effect.
#[derive(Clone, Debug, PartialEq)]
pub struct EffectParamSpec {
    /// Parameter key in `ClipEffect::parameters`.
    pub key: String,
    /// Row title.
    pub title: String,
    /// Unit shown after the value.
    pub unit: String,
    /// Value a new effect starts with.
    pub default_value: f64,
    /// Allowed values.
    pub range: RangeInclusive<f64>,
    /// Slider step.
    pub step: f64,
    /// Shown decimals.
    pub decimals: i64,
    /// Control type.
    pub kind: EffectParamKind,
    /// Factor between stored and shown value.
    pub display_scale: f64,
    /// Picture side the value scales with.
    pub picture_axis: Option<PictureAxis>,
    /// The value is a hue angle.
    pub is_hue: bool,
}

/// A catalog effect: kind, title and parameters.
#[derive(Clone, Debug, PartialEq)]
pub struct EffectSpec {
    /// Kind stored in `ClipEffect::kind`.
    pub kind: String,
    /// Shown name.
    pub title: String,
    /// Parameters in panel order.
    pub params: Vec<EffectParamSpec>,
    /// Linked pairs among the parameters.
    pub pairs: Vec<EffectParamPair>,
}

impl EffectParamKind {
    /// Stored as a number in `ClipEffect::parameters`.
    pub fn is_scalar(&self) -> bool {
        matches!(self, EffectParamKind::Slider | EffectParamKind::Checkbox | EffectParamKind::Choice(_))
    }

    /// Switches from key to key instead of blending (checkbox, choice): new keys get hold interpolation.
    pub fn is_stepped(&self) -> bool {
        matches!(self, EffectParamKind::Checkbox | EffectParamKind::Choice(_))
    }

    /// Checkbox state of a stored value (on from 0.5).
    pub fn is_on(&self, v: f64) -> bool {
        v >= 0.5
    }

    /// Choice index of a stored value: rounded and kept inside the list.
    pub fn choice_index(&self, v: f64) -> i64 {
        let EffectParamKind::Choice(titles) = self else { return 0 };
        if titles.is_empty() {
            return 0;
        }
        let last = titles.len() as i64 - 1;
        if !v.is_finite() {
            return if v > 0.0 { last } else { 0 };
        }
        v.round().clamp(0.0, last as f64) as i64
    }
}

impl EffectParamSpec {
    /// A slider with the default display (no scale, no picture axis, not a hue).
    pub fn new(
        key: &str,
        title: &str,
        unit: &str,
        default_value: f64,
        range: RangeInclusive<f64>,
        step: f64,
        decimals: i64,
    ) -> Self {
        EffectParamSpec {
            key: key.to_string(),
            title: title.to_string(),
            unit: unit.to_string(),
            default_value,
            range,
            step,
            decimals,
            kind: EffectParamKind::Slider,
            display_scale: 1.0,
            picture_axis: None,
            is_hue: false,
        }
    }

    /// An on/off row.
    pub fn checkbox(key: &str, title: &str, on: bool) -> Self {
        EffectParamSpec {
            kind: EffectParamKind::Checkbox,
            ..Self::new(key, title, "", if on { 1.0 } else { 0.0 }, 0.0..=1.0, 1.0, 0)
        }
    }

    /// A pop-up row; `index` is the default entry.
    pub fn choice(key: &str, title: &str, titles: &[impl AsRef<str>], index: usize) -> Self {
        let last = titles.len().saturating_sub(1) as f64;
        EffectParamSpec {
            kind: EffectParamKind::Choice(titles.iter().map(|t| t.as_ref().to_string()).collect()),
            ..Self::new(key, title, "", index as f64, 0.0..=last, 1.0, 0)
        }
    }

    /// A color well with its default.
    pub fn color(key: &str, title: &str, value: EffectColor) -> Self {
        EffectParamSpec { kind: EffectParamKind::Color(value), ..Self::new(key, title, "", 0.0, 0.0..=1.0, 0.0, 0) }
    }

    /// A point in px of the clip's own frame with its default.
    pub fn point(key: &str, title: &str, value: Vec2, unit: &str) -> Self {
        EffectParamSpec {
            kind: EffectParamKind::Point(value),
            ..Self::new(key, title, unit, 0.0, -100_000.0..=100_000.0, 1.0, 1)
        }
    }
}

impl EffectParamSpec {
    /// The value is a hue in degrees round the color circle: keys take the short way round.
    pub fn hue(self) -> Self {
        EffectParamSpec { is_hue: true, ..self }
    }

    /// Shown value = stored value x `scale`.
    pub fn display_scale(self, scale: f64) -> Self {
        EffectParamSpec { display_scale: scale, ..self }
    }

    /// Stored as percent of the clip's own picture along `axis`, shown in px of it (Crop).
    pub fn axis(self, axis: PictureAxis) -> Self {
        EffectParamSpec { picture_axis: Some(axis), ..self }
    }
}

impl EffectParamPair {
    /// Position, Scale and Anchor of an effect transform stage, in row order.
    pub fn stage_pairs() -> Vec<EffectParamPair> {
        vec![
            EffectParamPair::new("Position", ClipEffect::STAGE_POSITION_X_KEY, ClipEffect::STAGE_POSITION_Y_KEY, false),
            EffectParamPair::new("Scale", ClipEffect::STAGE_SCALE_KEY, ClipEffect::STAGE_SCALE_Y_KEY, true),
            EffectParamPair::new("Anchor", ClipEffect::STAGE_ANCHOR_X_KEY, ClipEffect::STAGE_ANCHOR_Y_KEY, false),
        ]
    }

    /// A pair; `linkable` pairs store Y only while unlinked.
    pub fn new(title: &str, x: &str, y: &str, linkable: bool) -> Self {
        EffectParamPair { title: title.to_string(), x: x.to_string(), y: y.to_string(), linkable }
    }
}

impl EffectSpec {
    /// The pair `key` belongs to, if any.
    pub fn pair_containing(&self, key: &str) -> Option<&EffectParamPair> {
        self.pairs.iter().find(|p| p.x == key || p.y == key)
    }
}

// W3.1 kinds and parameter keys (stored strings: never rename).
impl ClipEffect {
    /// `sharpen`.
    pub const SHARPEN_KIND: &'static str = "sharpen";
    /// Sharpen amount.
    pub const SHARPEN_AMOUNT_KEY: &'static str = "sharpenAmount";
    /// `directionalBlur`.
    pub const DIRECTIONAL_BLUR_KIND: &'static str = "directionalBlur";
    /// Directional blur angle.
    pub const BLUR_DIRECTION_KEY: &'static str = "blurDirection";
    /// Directional blur length.
    pub const BLUR_LENGTH_KEY: &'static str = "blurLength";
    /// `mirror`.
    pub const MIRROR_KIND: &'static str = "mirror";
    /// Mirror line center.
    pub const MIRROR_CENTER_KEY: &'static str = "reflectionCenter";
    /// Mirror line angle.
    pub const MIRROR_ANGLE_KEY: &'static str = "reflectionAngle";
    /// `noise`.
    pub const NOISE_KIND: &'static str = "noise";
    /// Noise amount.
    pub const NOISE_AMOUNT_KEY: &'static str = "noiseAmount";
    /// Noise per color channel.
    pub const NOISE_COLOR_KEY: &'static str = "colorNoise";
    /// Noise keeps values inside the picture's range.
    pub const NOISE_CLIP_KEY: &'static str = "clipResult";
    /// `glow`.
    pub const GLOW_KIND: &'static str = "glow";
    /// Glow luma threshold.
    pub const GLOW_THRESHOLD_KEY: &'static str = "glowThreshold";
    /// Glow blur radius.
    pub const GLOW_RADIUS_KEY: &'static str = "glowRadius";
    /// Glow strength.
    pub const GLOW_INTENSITY_KEY: &'static str = "glowIntensity";
    /// Glow color mode (original or tinted).
    pub const GLOW_COLORS_KEY: &'static str = "glowColors";
    /// Glow tint.
    pub const GLOW_COLOR_KEY: &'static str = "glowColor";
    /// `mosaic`.
    pub const MOSAIC_KIND: &'static str = "mosaic";
    /// Mosaic block columns.
    pub const MOSAIC_COLUMNS_KEY: &'static str = "horizontalBlocks";
    /// Mosaic block rows.
    pub const MOSAIC_ROWS_KEY: &'static str = "verticalBlocks";
    /// Mosaic takes the center pixel of a block.
    pub const MOSAIC_SHARP_KEY: &'static str = "sharpColors";
    /// `unsharpMask`.
    pub const UNSHARP_MASK_KIND: &'static str = "unsharpMask";
    /// Unsharp radius.
    pub const UNSHARP_RADIUS_KEY: &'static str = "unsharpRadius";
    /// Unsharp amount.
    pub const UNSHARP_AMOUNT_KEY: &'static str = "unsharpAmount";
    /// Unsharp threshold.
    pub const UNSHARP_THRESHOLD_KEY: &'static str = "unsharpThreshold";
}

/// The effects the Effects panel can apply.
pub struct EffectCatalog;

impl EffectCatalog {
    /// Every video spec, hidden ones included (`spec_for` resolves them); `all` is what the UI offers.
    pub fn every_spec() -> &'static [EffectSpec] {
        static EVERY: OnceLock<Vec<EffectSpec>> = OnceLock::new();
        EVERY.get_or_init(|| {
            let mut all = video_specs::core();
            all.extend(Self::batch1());
            all.extend(video_specs::film_look());
            all.extend(video_specs::temporal());
            all.extend(video_specs::posterize_time());
            all.extend(video_specs::date_stamp());
            all.extend([stage_specs::color(), stage_specs::color_graph(), stage_specs::transform()]);
            all.extend(motion_specs::specs().into_iter().filter(|s| !motion_specs::is_retired(&s.kind)));
            all.extend(style_specs::specs());
            all
        })
    }

    /// The video effects the Effects panel, palette and Add Effect lists offer, for the app-level hidden-catalog switch.
    pub fn all() -> Vec<EffectSpec> {
        Self::offered_video(hidden_catalog::is_active())
    }

    /// The same list for an explicit switch (`HiddenCatalog` ones and the Color Graph left out: the Color panel adds that).
    pub fn offered_video(hiding: bool) -> Vec<EffectSpec> {
        Self::every_spec()
            .iter()
            .filter(|s| {
                !hidden_catalog::is_hidden_effect_kind(&s.kind, hiding) && s.kind != ClipEffect::COLOR_GRAPH_KIND
            })
            .cloned()
            .collect()
    }

    /// The "Audio Effects" folder in panel order (`HiddenCatalog` ones included; Swift `everyAudioSpec`).
    pub fn every_audio_spec() -> &'static [EffectSpec] {
        static EVERY: OnceLock<Vec<EffectSpec>> = OnceLock::new();
        EVERY.get_or_init(audio_specs::every)
    }

    /// The "Audio Effects" folder as offered, for an explicit hidden-catalog switch.
    pub fn offered_audio(hiding: bool) -> Vec<EffectSpec> {
        Self::every_audio_spec()
            .iter()
            .filter(|s| !hidden_catalog::is_hidden_effect_kind(&s.kind, hiding))
            .cloned()
            .collect()
    }

    /// Effects that belong to a generator clip and are created with it, never offered in the Effects panel.
    pub fn generator_specs() -> &'static [EffectSpec] {
        static SPECS: OnceLock<Vec<EffectSpec>> = OnceLock::new();
        SPECS.get_or_init(stage_specs::generators)
    }

    /// The listed spec of a kind without a copy (the video, audio and generator tables); `None` for the retired motion
    /// kinds and the stage kinds that `spec_for` builds on demand. Per-frame callers use this, not `spec_for`.
    pub fn spec_ref(kind: &str) -> Option<&'static EffectSpec> {
        if motion_specs::is_retired(kind) {
            return None;
        }
        Self::every_spec()
            .iter()
            .chain(Self::every_audio_spec())
            .chain(Self::generator_specs())
            .find(|s| s.kind == kind)
    }

    /// Every known kind, including the generator-owned and written-by-tool ones the Effects panel does not offer.
    pub fn spec_for(kind: &str) -> Option<EffectSpec> {
        if motion_specs::is_retired(kind) {
            return motion_specs::specs().into_iter().find(|s| s.kind == kind);
        }
        if let Some(s) = Self::spec_ref(kind) {
            return Some(s.clone());
        }
        match kind {
            ClipEffect::REFRAME_KIND => Some(stage_specs::reframe()),
            ClipEffect::DYNAMIC_ZOOM_KIND => Some(stage_specs::dynamic_zoom()),
            ClipEffect::STABILIZE_KIND => Some(stage_specs::stabilize()),
            ClipEffect::GROUP_TRANSFORM_KIND => Some(stage_specs::group_transform()),
            _ => None,
        }
    }

    /// The shown name of a kind; the kind itself for an unknown one.
    // Swift falls back to the Effect Stack preset name (EffectStackPresets.preset(rowID:)); that table lives in
    // sq-core-effects, which depends on this crate, so a stack row id shows as its id here. Callers pass effect kinds only.
    pub fn title_for(kind: &str) -> String {
        Self::spec_for(kind).map_or_else(|| kind.to_string(), |s| s.title)
    }

    /// One parameter of a kind.
    pub fn param(kind: &str, key: &str) -> Option<EffectParamSpec> {
        if let Some(s) = Self::spec_ref(kind) {
            return s.params.iter().find(|p| p.key == key).cloned();
        }
        Self::spec_for(kind)?.params.into_iter().find(|p| p.key == key)
    }

    /// W3.1. Each evaluates into one image filter; px are px of the clip's own frame.
    pub fn batch1() -> Vec<EffectSpec> {
        let spec = |kind: &str, title: &str, params: Vec<EffectParamSpec>| EffectSpec {
            kind: kind.to_string(),
            title: title.to_string(),
            params,
            pairs: Vec::new(),
        };
        let white = EffectColor { red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0 };
        let degree = "\u{00B0}";
        vec![
            // Premiere's Sharpen: 0 does nothing, 100 adds the full difference to a 3 x 3 neighborhood once.
            spec(
                ClipEffect::SHARPEN_KIND,
                "Sharpen",
                vec![EffectParamSpec::new(ClipEffect::SHARPEN_AMOUNT_KEY, "Amount", "", 0.0, 0.0..=4_000.0, 1.0, 0)],
            ),
            // Unsharp Mask: adds Amount % of the difference to a blur of Radius px, only where that difference is above
            // Threshold. Amount 0 does nothing (the drop-in default). Radius 2 px = a Gaussian of sigma 1 px.
            spec(
                ClipEffect::UNSHARP_MASK_KIND,
                "Unsharp Mask",
                vec![
                    EffectParamSpec::new(ClipEffect::UNSHARP_RADIUS_KEY, "Radius", "px", 2.0, 0.0..=12.0, 0.1, 1),
                    EffectParamSpec::new(ClipEffect::UNSHARP_AMOUNT_KEY, "Amount", "%", 0.0, 0.0..=500.0, 1.0, 0),
                    EffectParamSpec::new(ClipEffect::UNSHARP_THRESHOLD_KEY, "Threshold", "%", 0.0, 0.0..=100.0, 0.5, 1),
                ],
            ),
            // Premiere's Directional Blur: direction 0 smears vertically, clockwise; Blur Length is the whole smear in px.
            spec(
                ClipEffect::DIRECTIONAL_BLUR_KIND,
                "Directional Blur",
                vec![
                    EffectParamSpec::new(
                        ClipEffect::BLUR_DIRECTION_KEY,
                        "Direction",
                        degree,
                        0.0,
                        -3_600.0..=3_600.0,
                        1.0,
                        0,
                    ),
                    EffectParamSpec::new(ClipEffect::BLUR_LENGTH_KEY, "Length", "px", 0.0, 0.0..=1_000.0, 0.5, 1),
                ],
            ),
            // Premiere's Mirror: a line through Reflection Center; at 0 degrees the left side is reflected onto the right, at 90
            // the top onto the bottom. The center is an offset from the frame center (like Position / Anchor Point), y down.
            spec(
                ClipEffect::MIRROR_KIND,
                "Mirror",
                vec![
                    EffectParamSpec::point(ClipEffect::MIRROR_CENTER_KEY, "Reflection Center", Vec2::ZERO, "px"),
                    EffectParamSpec::new(
                        ClipEffect::MIRROR_ANGLE_KEY,
                        "Angle",
                        degree,
                        0.0,
                        -3_600.0..=3_600.0,
                        1.0,
                        0,
                    ),
                ],
            ),
            // Premiere's Noise: a new grain pattern every frame. Color noise varies each channel on its own; Clip Result keeps
            // values inside the picture's range.
            spec(
                ClipEffect::NOISE_KIND,
                "Noise",
                vec![
                    EffectParamSpec::new(ClipEffect::NOISE_AMOUNT_KEY, "Amount", "%", 0.0, 0.0..=100.0, 0.5, 1),
                    EffectParamSpec::checkbox(ClipEffect::NOISE_COLOR_KEY, "Use Color Noise", true),
                    EffectParamSpec::checkbox(ClipEffect::NOISE_CLIP_KEY, "Clip Result Values", true),
                ],
            ),
            // Glow: what is brighter than Threshold (luma) is blurred (Radius = 2 sigma) and added on top, Intensity times.
            spec(
                ClipEffect::GLOW_KIND,
                "Glow",
                vec![
                    EffectParamSpec::new(ClipEffect::GLOW_THRESHOLD_KEY, "Threshold", "%", 60.0, 0.0..=100.0, 1.0, 0),
                    EffectParamSpec::new(ClipEffect::GLOW_RADIUS_KEY, "Radius", "px", 20.0, 0.0..=1_000.0, 1.0, 0),
                    EffectParamSpec::new(ClipEffect::GLOW_INTENSITY_KEY, "Intensity", "", 1.0, 0.0..=10.0, 0.05, 2),
                    EffectParamSpec::choice(
                        ClipEffect::GLOW_COLORS_KEY,
                        "Glow Colors",
                        &["Original Colors", "Glow Color"],
                        0,
                    ),
                    EffectParamSpec::color(ClipEffect::GLOW_COLOR_KEY, "Glow Color", white),
                ],
            ),
            // Premiere's Mosaic: the frame cut into blocks, each filled with its average color (Sharp Colors: its center pixel).
            spec(
                ClipEffect::MOSAIC_KIND,
                "Mosaic",
                vec![
                    EffectParamSpec::new(ClipEffect::MOSAIC_COLUMNS_KEY, "Columns", "", 10.0, 1.0..=4_000.0, 1.0, 0),
                    EffectParamSpec::new(ClipEffect::MOSAIC_ROWS_KEY, "Rows", "", 10.0, 1.0..=4_000.0, 1.0, 0),
                    EffectParamSpec::checkbox(ClipEffect::MOSAIC_SHARP_KEY, "Sharp Colors", false),
                ],
            ),
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn param_kinds_classify_their_storage() {
        let choice = EffectParamKind::Choice(vec!["a".into(), "b".into(), "c".into()]);
        assert!(EffectParamKind::Slider.is_scalar() && EffectParamKind::Checkbox.is_scalar() && choice.is_scalar());
        assert!(!EffectParamKind::Point(Vec2::ZERO).is_scalar());
        assert!(EffectParamKind::Checkbox.is_stepped() && choice.is_stepped() && !EffectParamKind::Slider.is_stepped());
        assert!(EffectParamKind::Checkbox.is_on(0.5) && !EffectParamKind::Checkbox.is_on(0.49));
    }

    #[test]
    fn choice_index_is_rounded_and_kept_inside_the_list() {
        let choice = EffectParamKind::Choice(vec!["a".into(), "b".into(), "c".into()]);
        let idx = |v| choice.choice_index(v);
        assert_eq!((idx(0.4), idx(1.5), idx(-3.0), idx(9.0)), (0, 2, 0, 2));
        assert_eq!((idx(f64::INFINITY), idx(f64::NEG_INFINITY), idx(f64::NAN)), (2, 0, 0));
        assert_eq!(EffectParamKind::Slider.choice_index(1.0), 0);
        assert_eq!(EffectParamKind::Choice(vec![]).choice_index(1.0), 0);
    }

    #[test]
    fn constructors_match_the_swift_defaults() {
        let c = EffectParamSpec::checkbox("k", "K", true);
        assert_eq!(
            (c.default_value, c.range, c.step, c.decimals, c.kind),
            (1.0, 0.0..=1.0, 1.0, 0, EffectParamKind::Checkbox)
        );
        let ch = EffectParamSpec::choice("k", "K", &["x", "y"], 1);
        assert_eq!((ch.default_value, ch.range), (1.0, 0.0..=1.0));
        let p = EffectParamSpec::point("k", "K", Vec2::ZERO, "px");
        assert_eq!((p.range, p.step, p.decimals, p.unit.as_str()), (-100_000.0..=100_000.0, 1.0, 1, "px"));
        assert_eq!(EffectParamSpec::new("k", "K", "", 0.0, 0.0..=1.0, 1.0, 0).display_scale, 1.0);
    }

    #[test]
    fn pair_lookup_finds_either_member() {
        let spec = EffectSpec {
            kind: "x".into(),
            title: "X".into(),
            params: vec![],
            pairs: vec![EffectParamPair::new("Position", "px", "py", false)],
        };
        assert_eq!(spec.pair_containing("py").map(|p| p.title.as_str()), Some("Position"));
        assert_eq!(spec.pair_containing("px").map(|p| p.x.as_str()), Some("px"));
        assert!(spec.pair_containing("zz").is_none());
    }

    #[test]
    fn batch1_lists_the_seven_w31_effects_with_unique_keys() {
        let specs = EffectCatalog::batch1();
        let kinds: Vec<_> = specs.iter().map(|s| s.kind.as_str()).collect();
        assert_eq!(kinds, ["sharpen", "unsharpMask", "directionalBlur", "mirror", "noise", "glow", "mosaic"]);
        for s in &specs {
            let mut keys: Vec<_> = s.params.iter().map(|p| p.key.as_str()).collect();
            keys.sort_unstable();
            keys.dedup();
            assert_eq!(keys.len(), s.params.len(), "{}", s.kind);
        }
        let glow = &specs[5];
        assert_eq!(glow.params.len(), 5);
        assert!(
            matches!(glow.params[3].kind, EffectParamKind::Choice(_))
                && matches!(glow.params[4].kind, EffectParamKind::Color(_))
        );
        assert_eq!(specs[4].params[1].default_value, 1.0, "color noise starts on");
    }

    fn kinds(specs: &[EffectSpec]) -> Vec<&str> {
        specs.iter().map(|s| s.kind.as_str()).collect()
    }

    #[test]
    fn every_kind_is_listed_once_and_every_spec_has_unique_keys() {
        let video = EffectCatalog::every_spec();
        let audio = EffectCatalog::every_audio_spec();
        let generators = EffectCatalog::generator_specs();
        let mut all: Vec<&str> = kinds(video);
        all.extend(kinds(audio));
        all.extend(kinds(generators));
        let count = all.len();
        all.sort_unstable();
        all.dedup();
        assert_eq!(all.len(), count, "a kind appears in two lists");
        for s in video.iter().chain(audio).chain(generators) {
            let mut keys: Vec<_> = s.params.iter().map(|p| p.key.as_str()).collect();
            keys.sort_unstable();
            keys.dedup();
            assert_eq!(keys.len(), s.params.len(), "{}", s.kind);
        }
    }

    #[test]
    fn spec_ref_is_the_listed_spec_without_a_copy_and_param_agrees_with_spec_for() {
        for s in EffectCatalog::every_spec().iter().chain(EffectCatalog::every_audio_spec()) {
            assert_eq!(EffectCatalog::spec_ref(&s.kind), Some(s));
            for p in &s.params {
                assert_eq!(EffectCatalog::param(&s.kind, &p.key).map(|x| x.key), Some(p.key.clone()));
            }
        }
        assert!(EffectCatalog::spec_ref("noSuchEffect").is_none());
        assert!(EffectCatalog::spec_ref(ClipEffect::REFRAME_KIND).is_none());
        assert!(EffectCatalog::param(ClipEffect::REFRAME_KIND, "noSuchKey").is_none());
    }

    #[test]
    fn spec_for_knows_every_listed_kind_the_retired_motion_ones_and_the_tool_written_ones() {
        for s in EffectCatalog::every_spec().iter().chain(EffectCatalog::every_audio_spec()) {
            assert_eq!(EffectCatalog::spec_for(&s.kind).map(|x| x.kind), Some(s.kind.clone()));
        }
        for kind in [
            ClipEffect::MOVE_KIND,
            ClipEffect::ZOOM_KIND,
            ClipEffect::POP_KIND,
            ClipEffect::FADE_KIND,
            ClipEffect::REFRAME_KIND,
            ClipEffect::DYNAMIC_ZOOM_KIND,
            ClipEffect::STABILIZE_KIND,
            ClipEffect::GROUP_TRANSFORM_KIND,
            ClipEffect::SHAPE_EFFECT_KIND,
        ] {
            assert!(EffectCatalog::spec_for(kind).is_some(), "{kind}");
        }
        assert!(EffectCatalog::spec_for("noSuchEffect").is_none());
        assert_eq!(EffectCatalog::title_for(ClipEffect::GAUSSIAN_BLUR_KIND), "Blur");
        assert_eq!(EffectCatalog::title_for("noSuchEffect"), "noSuchEffect");
        assert!(EffectCatalog::param(ClipEffect::CROP_KIND, "noSuchKey").is_none());
    }

    #[test]
    fn the_offered_lists_leave_out_the_color_graph_the_retired_motions_and_the_hidden_kinds() {
        let offered = EffectCatalog::offered_video(false);
        let names = kinds(&offered);
        assert!(!names.contains(&ClipEffect::COLOR_GRAPH_KIND));
        assert!(names.contains(&ClipEffect::COLOR_KIND) && names.contains(&ClipEffect::TRANSFORM_KIND));
        for retired in [ClipEffect::MOVE_KIND, ClipEffect::ZOOM_KIND, ClipEffect::POP_KIND, ClipEffect::FADE_KIND] {
            assert!(!names.contains(&retired));
        }
        assert!(names.contains(&ClipEffect::SHAKE_KIND) && names.contains(&ClipEffect::BOUNCE_KIND));
        assert!(!EffectCatalog::offered_video(true).iter().any(|s| s.kind == ClipEffect::NOISE_KIND));
        assert!(EffectCatalog::offered_audio(false).iter().any(|s| s.kind == ClipEffect::AUDIO_GAIN_KIND));
        assert!(!EffectCatalog::offered_audio(true).iter().any(|s| s.kind == ClipEffect::AUDIO_GAIN_KIND));
    }

    #[test]
    fn crop_rows_scale_with_the_picture_and_the_key_is_a_hue() {
        let crop = EffectCatalog::spec_for(ClipEffect::CROP_KIND).unwrap_or_else(|| panic!("crop"));
        let axes: Vec<_> = crop.params.iter().map(|p| p.picture_axis).collect();
        assert_eq!(
            axes,
            [
                Some(PictureAxis::Width),
                Some(PictureAxis::Height),
                Some(PictureAxis::Width),
                Some(PictureAxis::Height),
                None
            ]
        );
        assert_eq!(
            EffectCatalog::param(ClipEffect::ULTRA_KEY_KIND, ClipEffect::KEY_HUE_KEY).map(|p| p.is_hue),
            Some(true)
        );
        let group = EffectCatalog::param(ClipEffect::GROUP_TRANSFORM_KIND, ClipEffect::GROUP_SCALE_KEY);
        assert_eq!(
            group.map(|p| (p.display_scale, p.kind)),
            Some((100.0, EffectParamKind::Point(Vec2::new(1.0, 1.0))))
        );
    }

    #[test]
    fn the_stage_effects_pair_their_position_scale_and_anchor() {
        for kind in [ClipEffect::TRANSFORM_KIND, ClipEffect::REFRAME_KIND, ClipEffect::DYNAMIC_ZOOM_KIND] {
            let spec = EffectCatalog::spec_for(kind).unwrap_or_else(|| panic!("{kind}"));
            let titles: Vec<_> = spec.pairs.iter().map(|p| (p.title.as_str(), p.linkable)).collect();
            assert_eq!(titles, [("Position", false), ("Scale", true), ("Anchor", false)]);
            assert_eq!(
                spec.params.len(),
                if kind == ClipEffect::TRANSFORM_KIND { 9 } else { 8 },
                "{kind}: shutter only on Transform"
            );
        }
        let transform = EffectCatalog::spec_for(ClipEffect::TRANSFORM_KIND).unwrap_or_else(|| panic!("transform"));
        assert_eq!(transform.pair_containing(ClipEffect::STAGE_SCALE_Y_KEY).map(|p| p.x.as_str()), Some("scale"));
    }

    #[test]
    fn the_color_effect_lists_a_switch_before_each_section_and_takes_defaults_from_the_color_effect() {
        let spec = EffectCatalog::spec_for(ClipEffect::COLOR_KIND).unwrap_or_else(|| panic!("color"));
        let toggles: Vec<_> =
            spec.params.iter().filter(|p| p.kind == EffectParamKind::Checkbox).map(|p| p.key.as_str()).collect();
        assert_eq!(
            toggles,
            [
                ClipEffect::COLOR_BASIC_ON_KEY,
                ClipEffect::COLOR_CREATIVE_ON_KEY,
                ClipEffect::COLOR_CURVES_ON_KEY,
                ClipEffect::COLOR_WHEELS_ON_KEY,
                ClipEffect::COLOR_VIGNETTE_ON_KEY
            ]
        );
        assert_eq!(spec.params[0].key, ClipEffect::COLOR_BASIC_ON_KEY);
        assert_eq!(spec.params.len(), 5 + 11 + 9 + 10 + 4);
        let by_key = |k: &str| spec.params.iter().find(|p| p.key == k).cloned().unwrap_or_else(|| panic!("{k}"));
        assert_eq!(by_key(ClipEffect::COLOR_SATURATION_KEY).default_value, 100.0);
        assert_eq!(by_key(ClipEffect::COLOR_VIGNETTE_MIDPOINT_KEY).default_value, 50.0);
        assert!(by_key(ClipEffect::COLOR_WHEEL_SHADOWS_HUE_KEY).is_hue && !by_key(ClipEffect::COLOR_TINT_KEY).is_hue);
        assert_eq!(by_key(ClipEffect::COLOR_EXPOSURE_KEY).step, 0.01);
    }

    #[test]
    fn audio_specs_carry_their_chain_parameters() {
        let eq = EffectCatalog::spec_for(ClipEffect::AUDIO_PARAMETRIC_EQ_KIND).unwrap_or_else(|| panic!("eq"));
        assert_eq!(
            eq.params.len(),
            2 * 9 + 2 * 7,
            "on + freq for nine filters, gain + Q for the seven that are not cuts"
        );
        assert_eq!(
            EffectCatalog::param(ClipEffect::AUDIO_PARAMETRIC_EQ_KIND, "lsQ").map(|p| p.default_value),
            Some(0.71)
        );
        let mb = EffectCatalog::spec_for(ClipEffect::AUDIO_MULTIBAND_KIND).unwrap_or_else(|| panic!("mb"));
        assert_eq!(mb.params.len(), 1 + 3 + 4 * 5 + 5 + 4 * 2 + 1);
        let geq = EffectCatalog::spec_for(ClipEffect::AUDIO_GRAPHIC_EQ_KIND).unwrap_or_else(|| panic!("geq"));
        assert_eq!(geq.params.len(), 11);
        assert_eq!(geq.params[5].title, "1 kHz");
        assert_eq!(
            EffectCatalog::param(ClipEffect::AUDIO_DE_HUM_KIND, ClipEffect::DE_HUM_Q_KEY).map(|p| p.display_scale),
            Some(0.01)
        );
        assert!(ClipEffect::is_audio_kind("audio.reverb") && !ClipEffect::is_audio_kind("reverb"));
    }
    /// Swift: EffectsCatalog.swift (Unsharp Mask, Directional Blur, Glow, Mosaic, Noise, Sharpen), StyleEffects.swift,
    /// MotionEffects.swift (decimals default 1), PosterizeTime.swift: (effect, parameter, default, min, max, step, decimals).
    #[test]
    fn parameter_ranges_match_the_swift_catalog() {
        let all = EffectCatalog::every_spec();
        let rows: [(&str, &str, f64, f64, f64, f64, i64); 12] = [
            ("Rounded Corners", "Radius", 24.0, 0.0, 10_000.0, 1.0, 0),
            ("Unsharp Mask", "Radius", 2.0, 0.0, 12.0, 0.1, 1),
            ("Unsharp Mask", "Amount", 0.0, 0.0, 500.0, 1.0, 0),
            ("Directional Blur", "Length", 0.0, 0.0, 1_000.0, 0.5, 1),
            ("Glow", "Intensity", 1.0, 0.0, 10.0, 0.05, 2),
            ("Glow", "Radius", 20.0, 0.0, 1_000.0, 1.0, 0),
            ("Mosaic", "Columns", 10.0, 1.0, 4_000.0, 1.0, 0),
            ("Noise", "Amount", 0.0, 0.0, 100.0, 0.5, 1),
            ("Posterize Time", "Frame Rate", 8.0, 1.0, 60.0, 1.0, 0),
            ("Drop Shadow", "Direction", 135.0, -3_600.0, 3_600.0, 1.0, 0),
            ("Crop", "Left", 0.0, 0.0, 100.0, 0.5, 1),
            ("Blur", "Amount", 0.0, 0.0, 3_000.0, 0.5, 1),
        ];
        for (effect, param, d, lo, hi, step, decimals) in rows {
            let spec = all.iter().find(|e| e.title == effect).unwrap_or_else(|| panic!("no effect {effect}"));
            let p = spec.params.iter().find(|p| p.title == param).unwrap_or_else(|| panic!("no {effect} / {param}"));
            let got = (p.default_value, *p.range.start(), *p.range.end(), p.step, p.decimals);
            assert_eq!(got, (d, lo, hi, step, decimals), "{effect} / {param}");
        }
    }
}
