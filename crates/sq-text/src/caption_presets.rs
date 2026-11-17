// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: CaptionPresets.swift

use crate::caption_pill::CaptionPill;
use crate::caption_style_looks::CaptionStyleLooks;
use crate::generated_caption_looks::GeneratedCaptionLooks;
use crate::text_style::{
    BoxPadding, FontWeight, RGBAColor, StrokePosition, TextAlignment, TextBackground, TextShadow, TextStroke, TextStyle,
};
use serde::{Deserialize, Serialize};
use sq_core_model::anchored_animation::{AnimationAnchor, AnimationTrack, KeyframeTemplate, SegmentShape};
use sq_core_model::{CaptionHorizontal, CaptionPosition, CaptionVertical, Project, StyleKit};
use sq_core_time::Time;
use std::collections::BTreeMap;
use std::sync::{Mutex, MutexGuard, OnceLock, PoisonError};

/// Where captions sit without a kit position: bottom center (Swift `CaptionPosition.default`).
pub(crate) fn default_caption_position() -> CaptionPosition {
    CaptionPosition {
        vertical: CaptionVertical::Bottom,
        horizontal: CaptionHorizontal::Center,
        offset_x: 0.0,
        offset_y: 0.0,
    }
}

/// Resolves the opaque `styleRef` / `animationRef` strings (see SQTranscribe `CaptionPreset`).
/// Unknown or nil refs fall back to the library default.
#[derive(Clone, Debug, PartialEq)]
pub struct CaptionPresetLibrary {
    /// Styles by id.
    pub styles: BTreeMap<String, TextStyle>,
    /// Animations by id.
    pub animations: BTreeMap<String, KeyframeTemplate>,
    /// Style used for an unknown ref.
    pub default_style_id: String,
    /// Animation used for an unknown ref.
    pub default_animation_id: String,
    /// FB-Y: where the captions of this library's project sit (the kit's `captionPosition`; bottom center without one).
    pub position: CaptionPosition,
}

impl CaptionPresetLibrary {
    /// Both defaults must exist (`precondition` in Swift).
    pub fn new(
        styles: BTreeMap<String, TextStyle>,
        animations: BTreeMap<String, KeyframeTemplate>,
        default_style_id: &str,
        default_animation_id: &str,
    ) -> Self {
        assert!(
            styles.contains_key(default_style_id) && animations.contains_key(default_animation_id),
            "defaults must exist"
        );
        CaptionPresetLibrary {
            styles,
            animations,
            default_style_id: default_style_id.to_string(),
            default_animation_id: default_animation_id.to_string(),
            position: default_caption_position(),
        }
    }

    /// Style ids, sorted.
    pub fn style_ids(&self) -> Vec<String> {
        self.styles.keys().cloned().collect()
    }

    /// Animation ids, sorted.
    pub fn animation_ids(&self) -> Vec<String> {
        self.animations.keys().cloned().collect()
    }

    /// Whether the style exists.
    pub fn has_style(&self, id: &str) -> bool {
        self.styles.contains_key(id)
    }

    /// Whether the animation exists.
    pub fn has_animation(&self, id: &str) -> bool {
        self.animations.contains_key(id)
    }

    /// The style for `reference`, else the default.
    pub fn style(&self, reference: Option<&str>) -> TextStyle {
        reference.and_then(|r| self.styles.get(r)).unwrap_or_else(|| &self.styles[&self.default_style_id]).clone()
    }

    /// The animation for `reference`, else the default.
    pub fn animation(&self, reference: Option<&str>) -> KeyframeTemplate {
        reference
            .and_then(|r| self.animations.get(r))
            .unwrap_or_else(|| &self.animations[&self.default_animation_id])
            .clone()
    }

    /// The built-in looks plus every user Caption Look registered in `CaptionLookRegistry` (so saved looks render in the
    /// monitor and the burn-in through the same call sites).
    pub fn built_in() -> CaptionPresetLibrary {
        CaptionLookRegistry::shared().library_now()
    }

    /// A copy with `look` added under `id`-derived style and animation ids (see `CaptionLook::style_id`).
    pub fn adding(&self, look: &CaptionLook, id: &str) -> CaptionPresetLibrary {
        let mut s = self.styles.clone();
        let mut a = self.animations.clone();
        s.insert(CaptionLook::style_id(id), look.style.clone());
        a.insert(CaptionLook::animation_id(id), look.animation.clone());
        let mut lib = CaptionPresetLibrary::new(s, a, &self.default_style_id, &self.default_animation_id);
        lib.position = self.position;
        lib
    }

    /// Font of the built-in styles before they moved to Inter (projects without `Project.builtInStyles`).
    pub const LEGACY_FONT_NAME: &'static str = "Helvetica";

    /// The built-in styles: Inter, or the Helvetica set an old project was made with.
    pub fn base_for(legacy_font: bool) -> CaptionPresetLibrary {
        if legacy_font { Self::legacy_base().clone() } else { Self::base().clone() }
    }

    fn legacy_base() -> &'static CaptionPresetLibrary {
        static LEGACY: OnceLock<CaptionPresetLibrary> = OnceLock::new();
        LEGACY.get_or_init(|| {
            let b = Self::base();
            let styles = b
                .styles
                .iter()
                .map(|(k, v)| {
                    let mut s = v.clone();
                    s.font_name = Self::LEGACY_FONT_NAME.to_string();
                    (k.clone(), s)
                })
                .collect();
            CaptionPresetLibrary::new(styles, b.animations.clone(), &b.default_style_id, &b.default_animation_id)
        })
    }

    /// The built-in styles and animations.
    pub fn base() -> &'static CaptionPresetLibrary {
        static BASE: OnceLock<CaptionPresetLibrary> = OnceLock::new();
        BASE.get_or_init(Self::build_base)
    }

    fn build_base() -> CaptionPresetLibrary {
        let font = TextStyle::default_font_name();
        let line = |size: f64, weight: FontWeight, color: RGBAColor, line_spacing: f64| TextStyle {
            font_name: font.to_string(),
            size,
            weight,
            color,
            alignment: TextAlignment::Center,
            line_spacing,
            ..TextStyle::default()
        };
        let black = |a: f64| RGBAColor::new(0.0, 0.0, 0.0, a);
        let classic = TextStyle {
            shadow: Some(TextShadow::new(black(0.6), 0.0, 2.0, 6.0)),
            ..line(56.0, FontWeight::Semibold, RGBAColor::WHITE, 4.0)
        };
        let boxed = TextStyle {
            background: Some(TextBackground::new(black(0.75), BoxPadding::new(20.0, 10.0), 12.0)),
            ..line(52.0, FontWeight::Bold, RGBAColor::WHITE, 4.0)
        };
        let outline = TextStyle {
            stroke: Some(TextStroke::new(RGBAColor::BLACK, 6.0, StrokePosition::Outside)),
            ..line(60.0, FontWeight::Heavy, RGBAColor::WHITE, 2.0)
        };
        let soft_shadow = TextShadow::from_angle(black(0.55), 135.0, 3.0, 8.0);
        // Type tool default and the two short-video looks: bold sans, white fill.
        let title = TextStyle { shadow: Some(soft_shadow), ..line(72.0, FontWeight::Bold, RGBAColor::WHITE, 2.0) };
        let tiktok = TextStyle {
            stroke: Some(TextStroke::new(RGBAColor::BLACK, 8.0, StrokePosition::Outside)),
            shadow: Some(soft_shadow),
            ..line(64.0, FontWeight::Black, RGBAColor::WHITE, 2.0)
        };
        let youtube = TextStyle {
            background: Some(TextBackground::new(black(0.7), BoxPadding::new(14.0, 6.0), 6.0)),
            ..line(56.0, FontWeight::Bold, RGBAColor::WHITE, 2.0)
        };
        // Short-video pill: bold white word on a rounded black pill (no outline, the pill carries the contrast).
        let pill = CaptionPill::apply(&line(64.0, FontWeight::Black, RGBAColor::WHITE, 2.0), None);
        let t = Time::new;
        let pop_in = KeyframeTemplate {
            tracks: vec![
                AnimationTrack::from_shapes(
                    "scale",
                    &[(Time::ZERO, 0.8, SegmentShape::Overshoot), (t(1, 4), 1.0, SegmentShape::Linear)],
                ),
                AnimationTrack::from_shapes(
                    "opacity",
                    &[
                        (Time::ZERO, 0.0, SegmentShape::EaseOut),
                        (t(1, 8), 1.0, SegmentShape::Linear),
                        (t(1, 4), 1.0, SegmentShape::Linear),
                    ],
                ),
            ],
            duration: t(1, 4),
            ..KeyframeTemplate::none()
        };
        let fade = KeyframeTemplate {
            tracks: vec![AnimationTrack::from_shapes(
                "opacity",
                &[(Time::ZERO, 0.0, SegmentShape::Linear), (t(1, 5), 1.0, SegmentShape::Linear)],
            )],
            duration: t(1, 5),
            ..KeyframeTemplate::none()
        };
        let fade_out = KeyframeTemplate {
            tracks: vec![AnimationTrack::from_shapes(
                "opacity",
                &[(Time::ZERO, 1.0, SegmentShape::Linear), (t(1, 5), 0.0, SegmentShape::Linear)],
            )],
            duration: t(1, 5),
            anchor: AnimationAnchor::End,
            ..KeyframeTemplate::none()
        };
        // Styles of the look gallery (CaptionStyleLooks): a dim base whose lit words fill in, a sticker, a neon outline.
        let ghost = line(64.0, FontWeight::Heavy, RGBAColor::new(1.0, 1.0, 1.0, 0.3), 2.0);
        let sticker = TextStyle {
            background: Some(TextBackground::new(
                RGBAColor::new(1.0, 1.0, 1.0, 0.96),
                BoxPadding::new(18.0, 8.0),
                10.0,
            )),
            ..line(56.0, FontWeight::Black, RGBAColor::new(0.08, 0.08, 0.1, 1.0), 2.0)
        };
        let neon = TextStyle {
            stroke: Some(TextStroke::new(RGBAColor::new(0.0, 0.55, 0.6, 1.0), 5.0, StrokePosition::Outside)),
            shadow: Some(TextShadow::from_angle(RGBAColor::new(0.0, 0.9, 0.9, 0.8), 90.0, 0.0, 16.0)),
            ..line(60.0, FontWeight::Heavy, RGBAColor::new(0.85, 1.0, 0.95, 1.0), 2.0)
        };
        let mut animations: BTreeMap<String, KeyframeTemplate> = BTreeMap::from([
            ("none".to_string(), KeyframeTemplate::none()),
            ("fade".to_string(), fade),
            ("fade-out".to_string(), fade_out),
            ("pop-in".to_string(), pop_in),
            (
                CaptionLook::POP_ANIMATION_ID.to_string(),
                <KeyframeTemplate as KeyframeTemplateCaptionExt>::caption_pop(),
            ),
        ]);
        for (k, v) in CaptionStyleLooks::extra_animations() {
            animations.entry(k).or_insert(v);
        }
        let mut styles: BTreeMap<String, TextStyle> = [
            ("default", classic.clone()),
            ("classic", classic),
            ("bold-box", boxed),
            ("outline", outline),
            ("title", title),
            ("tiktok", tiktok),
            ("youtube", youtube),
            (CaptionPill::STYLE_ID, pill),
            ("ghost", ghost),
            ("sticker", sticker),
            ("neon", neon),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect();
        for (k, v) in GeneratedCaptionLooks::styles() {
            styles.entry(k).or_insert(v);
        }
        CaptionPresetLibrary::new(styles, animations, "default", "none")
    }
}

/// `extension KeyframeTemplate` of CaptionPresets.swift.
pub trait KeyframeTemplateCaptionExt {
    /// The maintainer's caption pop, softened after FB-Y ("far too strong, ease softer toward the end"): scale 96 % at the start,
    /// 102 % at 0.08 s (ease out), then easing out back to 100 % at 0.28 s. Anchored at the caption start; the pivot is
    /// the center of the text (`CaptionLayout.pivot`).
    fn caption_pop() -> KeyframeTemplate;
}

impl KeyframeTemplateCaptionExt for KeyframeTemplate {
    fn caption_pop() -> KeyframeTemplate {
        KeyframeTemplate {
            tracks: vec![AnimationTrack::from_shapes(
                "scale",
                &[
                    (Time::ZERO, 0.96, SegmentShape::EaseOut),
                    (Time::new(2, 25), 1.02, SegmentShape::EaseOut),
                    (Time::new(7, 25), 1.0, SegmentShape::Linear),
                ],
            )],
            duration: Time::new(7, 25),
            anchor: AnimationAnchor::Start,
            ..KeyframeTemplate::none()
        }
    }
}

/// A Caption Look: text style + keyframe animation, played once per caption by its anchor; its `text_animator` (if any)
/// animates per character / word / line in the monitor and the burn-in alike (W7.3). Saved as a PresetStore `.caption` preset
/// (the host pairs it with the segmentation, `CaptionPreset`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CaptionLook {
    /// The text style.
    pub style: TextStyle,
    /// The animation.
    pub animation: KeyframeTemplate,
}

/// Errors reading a Caption Look payload.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CaptionLookError {
    /// The payload was written by a newer version.
    NewerVersion,
    /// The payload is not valid JSON of a look.
    Malformed,
}

impl CaptionLook {
    /// Payload format version.
    pub const PAYLOAD_VERSION: i64 = 1;
    /// Animation id of the caption pop.
    pub const POP_ANIMATION_ID: &'static str = "caption-pop";

    /// A look.
    pub fn new(style: TextStyle, animation: KeyframeTemplate) -> Self {
        CaptionLook { style, animation }
    }

    /// Bold white text with drop shadow and the caption pop: what Create Captions applies unless the user picked another look.
    pub fn default_look() -> CaptionLook {
        CaptionLook::new(
            CaptionPresetLibrary::base().style(Some("default")),
            <KeyframeTemplate as KeyframeTemplateCaptionExt>::caption_pop(),
        )
    }

    /// Style id of the look `id`.
    pub fn style_id(id: &str) -> String {
        format!("look-{id}")
    }

    /// Animation id of the look `id`.
    pub fn animation_id(id: &str) -> String {
        format!("look-{id}")
    }

    /// The JSON payload.
    pub fn payload(&self) -> Result<Vec<u8>, CaptionLookError> {
        serde_json::to_vec(self).map_err(|_| CaptionLookError::Malformed)
    }

    /// Reads a payload of `version`.
    pub fn from_payload(payload: &[u8], version: i64) -> Result<CaptionLook, CaptionLookError> {
        if version > Self::PAYLOAD_VERSION {
            return Err(CaptionLookError::NewerVersion);
        }
        serde_json::from_slice(payload).map_err(|_| CaptionLookError::Malformed)
    }
}

struct RegistryState {
    looks: BTreeMap<String, CaptionLook>,
    kit: Option<StyleKit>,
    legacy_font: bool,
    cached: CaptionPresetLibrary,
    version: i64,
}

/// Process-wide set of user looks (loaded from the preset store at start, updated on save), merged into
/// `CaptionPresetLibrary::built_in`.
pub struct CaptionLookRegistry {
    state: Mutex<RegistryState>,
}

impl CaptionLookRegistry {
    /// The shared registry.
    pub fn shared() -> &'static CaptionLookRegistry {
        static SHARED: OnceLock<CaptionLookRegistry> = OnceLock::new();
        SHARED.get_or_init(|| CaptionLookRegistry {
            state: Mutex::new(RegistryState {
                looks: BTreeMap::new(),
                kit: None,
                legacy_font: false,
                cached: CaptionPresetLibrary::base().clone(),
                version: 0,
            }),
        })
    }

    fn lock(&self) -> MutexGuard<'_, RegistryState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn library_now(&self) -> CaptionPresetLibrary {
        self.lock().cached.clone()
    }

    /// Bumped by every `register`/`unregister` (a cache key for per-project libraries).
    pub fn version(&self) -> i64 {
        self.lock().version
    }

    /// The library for one project: built-in + the registered looks, resolved through `kit` (not the process-wide kit).
    /// Two open projects with different kits each pass their own, so neither clashes with the other.
    /// `legacy_font`: the project predates the Inter built-ins (`usesLegacyBuiltInFont`).
    pub fn library(&self, kit: Option<&StyleKit>, legacy_font: bool) -> CaptionPresetLibrary {
        let st = self.lock();
        Self::build(&st.looks, kit, legacy_font)
    }

    /// The library `project`'s captions render with: its kit and its generation of built-in styles.
    pub fn library_for_project(&self, project: &Project) -> CaptionPresetLibrary {
        use crate::style_kit_text::ProjectTextExt;
        self.library(project.style_kit.as_ref(), project.uses_legacy_built_in_font())
    }

    /// Registers (or replaces) the look under `id`; returns the (style, animation) refs captions should carry.
    pub fn register(&self, look: CaptionLook, id: &str) -> (String, String) {
        let mut st = self.lock();
        st.looks.insert(id.to_string(), look);
        st.version += 1;
        Self::rebuild(&mut st);
        (CaptionLook::style_id(id), CaptionLook::animation_id(id))
    }

    /// Removes the look under `id`.
    pub fn unregister(&self, id: &str) {
        let mut st = self.lock();
        st.looks.remove(id);
        st.version += 1;
        Self::rebuild(&mut st);
    }

    /// W8.3: the style kit of the project being edited (the session sets it on open and on every kit change). Captions
    /// and saved looks resolve their tokens through it. Returns whether the kit changed.
    pub fn set_style_kit(&self, kit: Option<StyleKit>, legacy_font: bool) -> bool {
        let mut st = self.lock();
        if kit == st.kit && legacy_font == st.legacy_font {
            return false;
        }
        st.kit = kit;
        st.legacy_font = legacy_font;
        Self::rebuild(&mut st);
        true
    }

    fn build(looks: &BTreeMap<String, CaptionLook>, kit: Option<&StyleKit>, legacy_font: bool) -> CaptionPresetLibrary {
        let mut lib = CaptionPresetLibrary::base_for(legacy_font);
        for (id, look) in looks {
            lib = lib.adding(look, id);
        }
        lib.applying(kit)
    }

    fn rebuild(st: &mut RegistryState) {
        st.cached = Self::build(&st.looks, st.kit.as_ref(), st.legacy_font);
    }
}

/// The registry is process-wide: tests that touch it run one at a time (Swift `.serialized`).
#[cfg(test)]
pub(crate) fn registry_test_lock() -> MutexGuard<'static, ()> {
    static LOCK: Mutex<()> = Mutex::new(());
    LOCK.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pop() -> KeyframeTemplate {
        <KeyframeTemplate as KeyframeTemplateCaptionExt>::caption_pop()
    }

    #[test]
    fn pop_matches_the_preset() {
        let _g = registry_test_lock();
        let a = CaptionPresetLibrary::built_in().animation(Some("caption-pop"));
        assert_eq!(a.anchor, AnimationAnchor::Start);
        // FB-Y: softer than the maintainer's Premiere preset (90 % -> 105 % -> 100 % in 0.13 s, linear): 96 % -> 102 % -> 100 %, eased.
        assert_eq!(a.value_of("scale", Time::ZERO), Some(0.96));
        assert!((a.value_of("scale", Time::new(2, 25)).unwrap_or(0.0) - 1.02).abs() < 1e-9);
        assert!((a.value_of("scale", Time::new(7, 25)).unwrap_or(0.0) - 1.0).abs() < 1e-9);
        assert_eq!(a.value_of("scale", Time::new(2, 1)), Some(1.0));
    }

    #[test]
    fn default_look_has_shadow_and_pop() {
        let l = CaptionLook::default_look();
        assert!(l.style.shadow.is_some());
        assert_eq!(l.animation, pop());
    }

    #[test]
    fn payload_round_trip() {
        let l = CaptionLook::default_look();
        let data = l.payload().unwrap_or_default();
        assert_eq!(CaptionLook::from_payload(&data, 1), Ok(l));
        assert_eq!(CaptionLook::from_payload(&data, 2), Err(CaptionLookError::NewerVersion));
    }

    #[test]
    fn registry_makes_looks_resolvable() {
        let _g = registry_test_lock();
        let mut l = CaptionLook::default_look();
        l.style.size = 99.0;
        let reg = CaptionLookRegistry::shared();
        let (style_ref, animation_ref) = reg.register(l, "test-look");
        let lib = CaptionPresetLibrary::built_in();
        assert_eq!(lib.style(Some(&style_ref)).size, 99.0);
        assert_eq!(lib.animation(Some(&animation_ref)), pop());
        assert!(CaptionPresetLibrary::built_in().has_style(&style_ref));
        reg.unregister("test-look");
    }

    #[test]
    fn base_library_resolves_unknown_refs_to_the_defaults() {
        let lib = CaptionPresetLibrary::base();
        assert_eq!(lib.style(Some("nope")), lib.style(None));
        assert_eq!(lib.style(None), lib.style(Some("default")));
        assert_eq!(lib.animation(Some("nope")), KeyframeTemplate::none());
        assert!(lib.has_style("pill") && lib.has_animation("fade-out"));
        assert_eq!(CaptionPresetLibrary::base_for(true).style(Some("classic")).font_name, "Helvetica");
        assert_eq!(lib.style(Some("classic")).font_name, "Inter");
    }
}
