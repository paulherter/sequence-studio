// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: StyleKit+Text.swift

//! W8.3: the text side of the project style kit (`sq_core_model::StyleKit`). Captions resolve the kit through the caption
//! library (`CaptionPresetLibrary::applying`, live per frame via `CaptionLookRegistry`); text clips carry
//! `TextStyle.tokens` and are re-resolved into their payloads when the kit changes (`ProjectTextExt::resolve_text_tokens`).

use crate::caption_pill::CaptionPill;
use crate::caption_presets::{
    CaptionLook, CaptionLookError, CaptionPresetLibrary, KeyframeTemplateCaptionExt, default_caption_position,
};
use crate::look::StyleKitLookExt;
use crate::text_generator::TextGenerator;
use crate::text_style::BoxPadding;
use crate::text_style::{
    FontWeight, RGBAColor, StrokePosition, TextAlignment, TextBackground, TextShadow, TextStroke, TextStyle,
};
use serde::{Deserialize, Serialize};
use sq_core_effects::style_kit::{CAPTION_ANIMATION_REF, CAPTION_STYLE_REF, ProjectStyleKitExt, StyleKitExt};
use sq_core_model::anchored_animation::KeyframeTemplate;
use sq_core_model::motion_easing::MotionCurve;
use sq_core_model::{
    CaptionStyleSpec, EffectColor, GeneratorRef, MotionDefaults, Project, StyleKit, StyleKitLook, StylePill, StyleValue,
};
use sq_core_time::Time;
use std::collections::BTreeMap;

/// Kit token names the starter kit uses.
pub const BRAND_FONT_TOKEN: &str = "brand";
/// See `BRAND_FONT_TOKEN`.
pub const TEXT_COLOR_TOKEN: &str = "text";
/// See `BRAND_FONT_TOKEN`.
pub const PILL_COLOR_TOKEN: &str = "pill";

/// Names of the kit tokens a text style's fields follow; `None` = that field is a literal.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TextStyleTokens {
    /// Font token.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub font: Option<String>,
    /// Fill color token.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    /// Stroke color token.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stroke_color: Option<String>,
    /// Background color token.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub background_color: Option<String>,
}

impl TextStyleTokens {
    /// No field is bound.
    pub fn is_empty(&self) -> bool {
        self.font.is_none() && self.color.is_none() && self.stroke_color.is_none() && self.background_color.is_none()
    }
}

/// A field of `TextStyleTokens` (Swift key path).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TokenField {
    /// `font`.
    Font,
    /// `color`.
    Color,
    /// `strokeColor`.
    StrokeColor,
    /// `backgroundColor`.
    BackgroundColor,
}

impl TextStyleTokens {
    fn field_mut(&mut self, f: TokenField) -> &mut Option<String> {
        match f {
            TokenField::Font => &mut self.font,
            TokenField::Color => &mut self.color,
            TokenField::StrokeColor => &mut self.stroke_color,
            TokenField::BackgroundColor => &mut self.background_color,
        }
    }
}

impl From<EffectColor> for RGBAColor {
    fn from(c: EffectColor) -> Self {
        RGBAColor::new(c.red, c.green, c.blue, c.alpha)
    }
}

/// The literal, or the token's value from `lookup`; `None` for a token the kit does not define (Swift `StyleValue.resolve`).
fn resolve<V: Clone>(v: &StyleValue<V>, lookup: impl Fn(&str) -> Option<V>) -> Option<V> {
    match v {
        StyleValue::Literal(l) => Some(l.clone()),
        StyleValue::Token(n) => lookup(n),
    }
}

fn token_name<V>(v: &StyleValue<V>) -> Option<String> {
    match v {
        StyleValue::Token(n) => Some(n.clone()),
        StyleValue::Literal(_) => None,
    }
}

fn from_raw_string<T: serde::de::DeserializeOwned>(s: &str) -> Option<T> {
    serde_json::from_value(serde_json::Value::String(s.to_string())).ok()
}

impl TextStyle {
    /// A manual choice for a field ends its token binding (a later kit change must not overwrite it).
    pub fn unbind(&mut self, field: TokenField) {
        let Some(mut t) = self.tokens.clone() else { return };
        if t.field_mut(field).is_none() {
            return;
        }
        *t.field_mut(field) = None;
        self.tokens = if t.is_empty() { None } else { Some(t) };
    }

    /// The style with every token-bound field set from `kit`. A token the kit does not define keeps the stored literal;
    /// stroke/background colors only change when the style has a stroke/background.
    pub fn resolved(&self, kit: Option<&StyleKit>) -> TextStyle {
        let (Some(kit), Some(t)) = (kit, self.tokens.as_ref()) else { return self.clone() };
        let mut s = self.clone();
        if let Some(f) = t.font.as_deref().and_then(|n| kit.font(n)) {
            s.font_name = f.to_string();
        }
        if let Some(c) = t.color.as_deref().and_then(|n| kit.color(n)) {
            s.color = RGBAColor::from(c);
        }
        if let (Some(c), Some(st)) = (t.stroke_color.as_deref().and_then(|n| kit.color(n)), s.stroke) {
            s.stroke = Some(TextStroke::new(RGBAColor::from(c), st.width, st.position));
        }
        if let (Some(c), Some(b)) = (t.background_color.as_deref().and_then(|n| kit.color(n)), s.background.as_mut()) {
            b.color = RGBAColor::from(c);
        }
        s
    }
}

/// Text side of `extension StyleKit`.
pub trait StyleKitTextExt {
    /// The kit a project without one exports (and a starting point to edit): the short-video pill caption with its font,
    /// text color and pill color as tokens, motion effects at their built-in 0.5 s / Premiere Default.
    fn starter() -> StyleKit;
    /// `legacy_font`: the starter kit of a project that predates the Inter built-ins (Helvetica as its brand font).
    fn starter_with(legacy_font: bool) -> StyleKit;
    /// Kit-owned looks are registered under this id (`CaptionLook::style_id` adds the "look-" prefix).
    fn look_id(id: &str) -> String;
    /// The kit caption style built on `library`'s base style; `None` without a caption spec.
    fn caption_style(&self, library: &CaptionPresetLibrary) -> Option<TextStyle>;
    /// Adds (or replaces) a caption look carried by the kit.
    fn add_look(&mut self, look: &CaptionLook, id: &str, name: &str) -> Result<(), CaptionLookError>;
    /// The kit's Looks that this build can read, as captions render them, by id (one reader: `StyleKit.look`).
    fn caption_looks(&self) -> Vec<(String, String, CaptionLook)>;
}

impl StyleKitTextExt for StyleKit {
    fn starter() -> StyleKit {
        Self::starter_with(false)
    }

    fn starter_with(legacy_font: bool) -> StyleKit {
        StyleKit {
            fonts: BTreeMap::from([(
                BRAND_FONT_TOKEN.to_string(),
                if legacy_font {
                    CaptionPresetLibrary::LEGACY_FONT_NAME.to_string()
                } else {
                    TextStyle::default_font_name().to_string()
                },
            )]),
            colors: BTreeMap::from([
                (TEXT_COLOR_TOKEN.to_string(), EffectColor::WHITE),
                (
                    PILL_COLOR_TOKEN.to_string(),
                    EffectColor { red: 0.0, green: 0.0, blue: 0.0, alpha: CaptionPill::COLOR.alpha },
                ),
            ]),
            pill: Some(StylePill {
                color: StyleValue::Token(PILL_COLOR_TOKEN.to_string()),
                horizontal_em: CaptionPill::HORIZONTAL_EM,
                vertical_em: CaptionPill::VERTICAL_EM,
                corner_radius: None,
            }),
            caption: Some(CaptionStyleSpec {
                base_style: CaptionPill::STYLE_ID.to_string(),
                animation: None,
                font: Some(StyleValue::Token(BRAND_FONT_TOKEN.to_string())),
                size: None,
                text_color: Some(StyleValue::Token(TEXT_COLOR_TOKEN.to_string())),
                stroke_color: None,
                uses_pill: true,
                all_caps: None,
                hides_background: None,
                tweaks: None,
            }),
            motion: Some(MotionDefaults { duration: Time::new(1, 2), curve: MotionCurve::PremiereDefault.raw_value() }),
            ..StyleKit::default()
        }
    }

    fn look_id(id: &str) -> String {
        format!("kit-{id}")
    }

    fn caption_style(&self, library: &CaptionPresetLibrary) -> Option<TextStyle> {
        let spec = self.caption.as_ref()?;
        let mut s = library.style(Some(&spec.base_style));
        let mut t = s.tokens.clone().unwrap_or_default();
        if let Some(f) = &spec.font {
            if let Some(v) = resolve(f, |n| self.font(n).map(str::to_string)) {
                s.font_name = v;
            }
            t.font = token_name(f);
        }
        if let Some(size) = spec.size {
            s.size = size.max(1.0);
        }
        if let Some(caps) = spec.all_caps {
            s.all_caps = caps;
        }
        if let Some(c) = &spec.text_color {
            if let Some(v) = resolve(c, |n| self.color(n)) {
                s.color = RGBAColor::from(v);
            }
            t.color = token_name(c);
        }
        if let Some(c) = &spec.stroke_color {
            if let Some(v) = resolve(c, |n| self.color(n)) {
                s.stroke = Some(TextStroke::new(
                    RGBAColor::from(v),
                    s.stroke.map(|st| st.width).unwrap_or_else(|| 2.0_f64.max((s.size * 0.1).round())),
                    s.stroke.map(|st| st.position).unwrap_or(StrokePosition::Outside),
                ));
            }
            t.stroke_color = token_name(c);
        }
        if let Some(w) = &spec.tweaks {
            if let Some(v) = w.weight.and_then(FontWeight::from_raw) {
                s.weight = v;
            }
            if let Some(v) = w.italic {
                s.italic = v;
            }
            if let Some(v) = w.alignment.as_deref().and_then(from_raw_string::<TextAlignment>) {
                s.alignment = v;
            }
            if let Some(v) = w.tracking.filter(|v| v.is_finite()) {
                s.tracking = v;
            }
            if let Some(v) = w.line_spacing.filter(|v| v.is_finite()) {
                s.line_spacing = v;
            }
            if let Some(st) = s.stroke.as_mut() {
                if let Some(v) = w.stroke_width.filter(|v| v.is_finite()) {
                    st.width = v.max(0.0);
                }
                if let Some(v) = w.stroke_position.as_deref().and_then(from_raw_string::<StrokePosition>) {
                    st.position = v;
                }
            }
            if w.hides_shadow == Some(true) {
                s.shadow = None;
            } else if let Some(sh) = &w.shadow {
                let mut v = TextShadow::new(RGBAColor::from(sh.color), sh.offset_x, sh.offset_y, sh.blur);
                v.resting_angle = sh.resting_angle;
                s.shadow = Some(v);
            }
        }
        if spec.uses_pill {
            let p = self.pill.clone().unwrap_or(StylePill {
                color: StyleValue::Literal(EffectColor {
                    red: 0.0,
                    green: 0.0,
                    blue: 0.0,
                    alpha: CaptionPill::COLOR.alpha,
                }),
                horizontal_em: CaptionPill::HORIZONTAL_EM,
                vertical_em: CaptionPill::VERTICAL_EM,
                corner_radius: None,
            });
            let c = resolve(&p.color, |n| self.color(n)).map(RGBAColor::from).unwrap_or(CaptionPill::COLOR);
            s.background = Some(TextBackground::new(
                c,
                BoxPadding::new((s.size * p.horizontal_em).round(), (s.size * p.vertical_em).round()),
                p.corner_radius.unwrap_or(10_000.0),
            ));
            t.background_color = token_name(&p.color);
        } else if spec.hides_background == Some(true) {
            s.background = None; // FB-Y: Pill off on a look with a box of its own keeps the look, drops the box
            t.background_color = None;
        }
        s.tokens = if t.is_empty() { None } else { Some(t) };
        Some(s)
    }

    fn add_look(&mut self, look: &CaptionLook, id: &str, name: &str) -> Result<(), CaptionLookError> {
        self.looks.insert(
            id.to_string(),
            StyleKitLook {
                name: name.to_string(),
                payload: look.payload()?,
                payload_version: CaptionLook::PAYLOAD_VERSION,
            },
        );
        Ok(())
    }

    fn caption_looks(&self) -> Vec<(String, String, CaptionLook)> {
        self.looks
            .keys()
            .filter_map(|id| self.look(id).map(|l| (id.clone(), l.name.clone(), l.caption_look())))
            .collect()
    }
}

impl CaptionPresetLibrary {
    /// A copy with `kit` applied: every token-bound style resolved, the kit caption style under `CAPTION_STYLE_REF`
    /// (animation `CAPTION_ANIMATION_REF`: the spec's animation, else the caption pop) and the kit's looks under
    /// `StyleKitTextExt::look_id`. `None` = unchanged.
    pub fn applying(&self, kit: Option<&StyleKit>) -> CaptionPresetLibrary {
        let Some(kit) = kit else { return self.clone() };
        let styles = self.styles.iter().map(|(k, v)| (k.clone(), v.resolved(Some(kit)))).collect();
        let mut lib = CaptionPresetLibrary::new(
            styles,
            self.animations.clone(),
            &self.default_style_id,
            &self.default_animation_id,
        );
        for (id, _, look) in kit.caption_looks() {
            let mut l = look;
            l.style = l.style.resolved(Some(kit));
            lib = lib.adding(&l, &StyleKit::look_id(&id));
        }
        if let Some(style) = kit.caption_style(self) {
            let mut s = lib.styles.clone();
            let mut a = lib.animations.clone();
            s.insert(CAPTION_STYLE_REF.to_string(), style);
            let animation: KeyframeTemplate = kit
                .caption
                .as_ref()
                .and_then(|c| c.animation.as_ref())
                .and_then(|n| self.animations.get(n))
                .cloned()
                .unwrap_or_else(KeyframeTemplate::caption_pop);
            a.insert(CAPTION_ANIMATION_REF.to_string(), animation);
            lib = CaptionPresetLibrary::new(s, a, &self.default_style_id, &self.default_animation_id);
        }
        lib.position = kit.caption_position.unwrap_or_else(default_caption_position);
        lib
    }
}

/// Text side of `extension Project`.
pub trait ProjectTextExt {
    /// True for a project written before the built-in caption and text styles moved to Inter: its `styleRef`s keep
    /// resolving to the Helvetica built-ins.
    fn uses_legacy_built_in_font(&self) -> bool;
    /// Writes the current kit values into every text clip whose style follows a token (one pass over all sequences).
    /// Returns how many clips changed. Clips whose payload this build cannot read stay as they are.
    fn resolve_text_tokens(&mut self) -> usize;
}

impl ProjectTextExt for Project {
    fn uses_legacy_built_in_font(&self) -> bool {
        self.built_in_styles.unwrap_or(0) < Project::CURRENT_BUILT_IN_STYLES
    }

    fn resolve_text_tokens(&mut self) -> usize {
        let kit = self.style_kit.clone();
        if kit.is_none() {
            return 0;
        }
        let marker = br#""tokens""#; // cheap pre-check: only payloads with bound fields are decoded
        self.rewrite_generators(&|g: &GeneratorRef| {
            if g.kind != TextGenerator::KIND || !g.payload.windows(marker.len()).any(|w| w == marker) {
                return None;
            }
            let (template, anim) = TextGenerator::decode(g).ok()?;
            template.style.tokens.as_ref()?;
            let style = template.style.resolved(kit.as_ref());
            if style == template.style {
                return None;
            }
            let mut tp = template;
            tp.style = style;
            TextGenerator::make_ref(&tp, anim.as_ref()).ok()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::caption_presets::{CaptionLookRegistry, KeyframeTemplateCaptionExt, registry_test_lock as serial};
    use crate::text_template::TextTemplate;
    use sq_core_model::{Clip, Timeline, Track, TrackKind};
    use sq_core_time::{Id, TimeRange};

    const RED: EffectColor = EffectColor { red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0 };
    const BLUE: EffectColor = EffectColor { red: 0.0, green: 0.0, blue: 1.0, alpha: 1.0 };

    fn brand() -> StyleKit {
        let mut k = StyleKit::default();
        k.fonts.insert("brand".into(), "Avenir-Black".into());
        k.colors.insert("text".into(), EffectColor::WHITE);
        k.colors.insert("accent".into(), RED);
        k.pill = Some(StylePill {
            color: StyleValue::Token("accent".into()),
            horizontal_em: 0.40,
            vertical_em: 0.16,
            corner_radius: None,
        });
        k.caption = Some(CaptionStyleSpec {
            base_style: "pill".into(),
            animation: None,
            font: Some(StyleValue::Token("brand".into())),
            size: Some(70.0),
            text_color: Some(StyleValue::Token("text".into())),
            stroke_color: None,
            uses_pill: true,
            all_caps: None,
            hides_background: None,
            tweaks: None,
        });
        k
    }

    fn base() -> &'static CaptionPresetLibrary {
        CaptionPresetLibrary::base()
    }

    // Caption style follows the tokens

    #[test]
    fn kit_caption_style_resolves_tokens() {
        let lib = base().applying(Some(&brand()));
        let s = lib.style(Some(CAPTION_STYLE_REF));
        assert_eq!(s.font_name, "Avenir-Black");
        assert_eq!(s.size, 70.0);
        assert_eq!(s.color, RGBAColor::WHITE);
        assert_eq!(s.background.map(|b| b.color), Some(RGBAColor::rgb(1.0, 0.0, 0.0)));
        assert_eq!(s.background.map(|b| b.corner_radius), Some(10_000.0));
        assert_eq!(lib.animation(Some(CAPTION_ANIMATION_REF)), KeyframeTemplate::caption_pop());
    }

    #[test]
    fn changing_a_token_changes_every_kit_caption() {
        let mut kit = brand();
        let before = base().applying(Some(&kit));
        assert_eq!(
            before.style(Some(CAPTION_STYLE_REF)).background.map(|b| b.color),
            Some(RGBAColor::rgb(1.0, 0.0, 0.0))
        );
        kit.colors.insert("accent".into(), BLUE);
        kit.fonts.insert("brand".into(), "Futura-Bold".into());
        let after = base().applying(Some(&kit));
        let s = after.style(Some(CAPTION_STYLE_REF));
        assert_eq!(s.background.map(|b| b.color), Some(RGBAColor::rgb(0.0, 0.0, 1.0)));
        assert_eq!(s.font_name, "Futura-Bold");
        // Captions in another style are not touched.
        assert_eq!(after.style(Some("outline")), base().style(Some("outline")));
    }

    #[test]
    fn no_kit_adds_nothing() {
        let lib = base().applying(None);
        assert!(!lib.has_style(CAPTION_STYLE_REF));
        assert_eq!(lib.styles, base().styles);
    }

    #[test]
    fn registry_follows_the_project_kit() {
        let _g = serial();
        let reg = CaptionLookRegistry::shared();
        assert!(reg.set_style_kit(Some(brand()), false));
        assert!(!reg.set_style_kit(Some(brand()), false)); // unchanged
        assert_eq!(CaptionPresetLibrary::built_in().style(Some(CAPTION_STYLE_REF)).font_name, "Avenir-Black");
        let mut k = brand();
        k.fonts.insert("brand".into(), "Futura-Bold".into());
        reg.set_style_kit(Some(k), false);
        assert_eq!(CaptionPresetLibrary::built_in().style(Some(CAPTION_STYLE_REF)).font_name, "Futura-Bold");
        reg.set_style_kit(None, false);
        assert!(!CaptionPresetLibrary::built_in().has_style(CAPTION_STYLE_REF));
    }

    #[test]
    fn explicit_kit_libraries_do_not_clash() {
        let _g = serial();
        let reg = CaptionLookRegistry::shared();
        let mut other = brand();
        other.fonts.insert("brand".into(), "Futura-Bold".into());
        reg.set_style_kit(Some(other.clone()), false); // the "focused" project
        let a = reg.library(Some(&brand()), false);
        let b = reg.library(Some(&other), false);
        assert_eq!(a.style(Some(CAPTION_STYLE_REF)).font_name, "Avenir-Black");
        assert_eq!(b.style(Some(CAPTION_STYLE_REF)).font_name, "Futura-Bold");
        assert!(!reg.library(None, false).has_style(CAPTION_STYLE_REF));
        let v = reg.version();
        reg.register(CaptionLook::default_look(), "ver-test");
        assert_eq!(reg.version(), v + 1);
        assert!(reg.library(None, false).has_style(&CaptionLook::style_id("ver-test")));
        reg.unregister("ver-test");
        reg.set_style_kit(None, false);
    }

    // Token-bound text styles

    #[test]
    fn text_style_tokens_round_trip_and_old_styles_have_none() {
        let mut s = TextStyle { font_name: "Helvetica".into(), ..TextStyle::default() };
        s.tokens = Some(TextStyleTokens {
            font: Some("brand".into()),
            color: Some("accent".into()),
            ..TextStyleTokens::default()
        });
        let back: Result<TextStyle, _> = serde_json::from_str(&serde_json::to_string(&s).unwrap_or_default());
        assert_eq!(back.ok(), Some(s));
        let plain = serde_json::to_value(TextStyle::default()).unwrap_or_default();
        assert!(plain.get("tokens").is_none());
        let back: Result<TextStyle, _> = serde_json::from_value(plain);
        assert_eq!(back.ok().map(|b| b.tokens), Some(None));
    }

    #[test]
    fn resolved_replaces_only_token_bound_fields() {
        let mut s = TextStyle {
            font_name: "Helvetica".into(),
            size: 40.0,
            color: RGBAColor::BLACK,
            stroke: Some(TextStroke::new(RGBAColor::BLACK, 4.0, StrokePosition::Outside)),
            background: Some(TextBackground::new(RGBAColor::BLACK, BoxPadding::new(1.0, 1.0), 2.0)),
            ..TextStyle::default()
        };
        s.tokens = Some(TextStyleTokens {
            font: Some("brand".into()),
            color: Some("accent".into()),
            background_color: Some("missing".into()),
            ..TextStyleTokens::default()
        });
        let r = s.resolved(Some(&brand()));
        assert_eq!(r.font_name, "Avenir-Black");
        assert_eq!(r.color, RGBAColor::rgb(1.0, 0.0, 0.0));
        assert_eq!(r.stroke, s.stroke);
        assert_eq!(r.background, s.background); // unknown token: the literal stays
        assert!(r.size == 40.0 && r.tokens == s.tokens);
        assert_eq!(s.resolved(None), s);
    }

    #[test]
    fn unbind_ends_one_binding_and_clears_empty_tokens() {
        let tokens =
            TextStyleTokens { font: Some("brand".into()), color: Some("accent".into()), ..TextStyleTokens::default() };
        let mut s = TextStyle { tokens: Some(tokens), ..TextStyle::default() };
        s.unbind(TokenField::Font);
        assert_eq!(s.tokens.as_ref().map(|t| t.font.is_none()), Some(true));
        s.unbind(TokenField::Color);
        assert!(s.tokens.is_none());
    }

    #[test]
    fn text_clips_follow_the_kit() {
        let mut style = TextStyle { font_name: "Helvetica".into(), ..TextStyle::default() };
        style.tokens = Some(TextStyleTokens { font: Some("brand".into()), ..TextStyleTokens::default() });
        let bound = TextGenerator::make_ref(&TextTemplate::new("T", "Hi", style), None);
        let literal = TextGenerator::make_ref(
            &TextTemplate::new("L", "Hi", TextStyle { font_name: "Menlo".into(), ..TextStyle::default() }),
            None,
        );
        let (Ok(bound), Ok(literal)) = (bound, literal) else { panic!("refs") };
        let clip = |g: GeneratorRef| {
            let mut c = Clip::new(
                Id::NIL,
                "t",
                Id::NIL,
                TrackKind::Video,
                TimeRange::new(Time::ZERO, Time::new(2, 1)),
                Time::ZERO,
            );
            c.generator = Some(g);
            c
        };
        let mut track = Track::new(Id::NIL, TrackKind::Video);
        track.set_clips(vec![clip(bound), clip(literal)]);
        let tl = Timeline::new(Id::NIL, "s", sq_core_model::SequenceFormat::new(Time::new(1, 30)), vec![track]);
        let mut p = Project::new(Id::NIL, "P", Vec::new(), vec![tl]);
        p.style_kit = Some(brand());
        let font = |p: &Project, i: usize| {
            let g = p.timelines[0].tracks[0].clips()[i]
                .generator
                .clone()
                .unwrap_or_else(|| GeneratorRef::shape(sq_core_model::ShapeKind::Line));
            TextGenerator::decode(&g).map(|(t, _)| t.style.font_name).unwrap_or_default()
        };
        assert_eq!(p.resolve_text_tokens(), 1);
        assert_eq!(font(&p, 0), "Avenir-Black");
        assert_eq!(font(&p, 1), "Menlo");
        if let Some(k) = p.style_kit.as_mut() {
            k.fonts.insert("brand".into(), "Futura-Bold".into());
        }
        assert_eq!(p.resolve_text_tokens(), 1);
        assert_eq!(font(&p, 0), "Futura-Bold");
        assert_eq!(p.resolve_text_tokens(), 0); // already current
    }

    // Looks in a kit

    #[test]
    fn imported_look_follows_the_importers_brand() {
        let mut theirs = brand();
        let mut look_style = TextStyle::new("Helvetica", 60.0, FontWeight::Regular, RGBAColor::WHITE);
        look_style.tokens = Some(TextStyleTokens {
            font: Some("brand".into()),
            color: Some("accent".into()),
            ..TextStyleTokens::default()
        });
        assert!(
            theirs.add_look(&CaptionLook::new(look_style, KeyframeTemplate::caption_pop()), "bold", "Bold").is_ok()
        );

        let mut mine = StyleKit::default();
        mine.fonts.insert("brand".into(), "Futura-Bold".into());
        mine.colors.insert("accent".into(), BLUE);
        let (merged, report) = mine.merging(&theirs);
        assert_eq!(report.added_looks, vec!["bold".to_string()]);
        let lib = base().applying(Some(&merged));
        let s = lib.style(Some(&CaptionLook::style_id(&StyleKit::look_id("bold"))));
        assert_eq!(s.font_name, "Futura-Bold");
        assert_eq!(s.color, RGBAColor::rgb(0.0, 0.0, 1.0));
        assert_eq!(
            lib.animation(Some(&CaptionLook::animation_id(&StyleKit::look_id("bold")))),
            KeyframeTemplate::caption_pop()
        );
        assert_eq!(merged.caption_looks().into_iter().map(|l| l.0).collect::<Vec<_>>(), vec!["bold".to_string()]);
    }

    #[test]
    fn starter_kit_has_the_pill_caption_with_tokens() {
        let k = StyleKit::starter();
        assert_eq!(k.fonts.get(BRAND_FONT_TOKEN).map(String::as_str), Some("Inter"));
        assert_eq!(StyleKit::starter_with(true).fonts.get(BRAND_FONT_TOKEN).map(String::as_str), Some("Helvetica"));
        let s = base().applying(Some(&k)).style(Some(CAPTION_STYLE_REF));
        assert!(s.background.is_some() && s.tokens.is_some());
    }
}
