// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TextPresets.swift
//! The built-in text Looks and text Motions of the Library, and the pure logic that applies them.

use crate::text_generator::{TextGenerator, TextGeneratorError};
use crate::text_look_generator::TextLookGenerator;
use crate::text_style::{
    BoxPadding, FontWeight, RGBAColor, StrokePosition, TextAlignment, TextBackground, TextShadow, TextStroke, TextStyle,
};
use crate::text_template::TextTemplate;
use sq_core_graphics::text_animator_model::KeyframeTemplateTextExt;
use sq_core_model::GeneratorRef;
use sq_core_model::anchored_animation::{
    AnimationAnchor, AnimationSet, AnimationTrack, KeyframeTemplate, SegmentShape, TextAnimator, TextAnimatorEffect,
    TextAnimatorUnit,
};
use sq_core_time::Time;
use std::sync::LazyLock;

/// Library families of the built-in text presets (Library folder names).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TextPresetCategory {
    /// TikTok.
    Tiktok,
    /// YouTube.
    Youtube,
    /// Professional.
    Professional,
    /// Titles.
    Titles,
}

impl TextPresetCategory {
    /// Every category, in declaration order.
    pub const ALL: [TextPresetCategory; 4] = [Self::Tiktok, Self::Youtube, Self::Professional, Self::Titles];

    /// The raw string of the category.
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Tiktok => "tiktok",
            Self::Youtube => "youtube",
            Self::Professional => "professional",
            Self::Titles => "titles",
        }
    }

    /// The shown name.
    pub fn title(self) -> &'static str {
        match self {
            Self::Tiktok => "TikTok",
            Self::Youtube => "YouTube",
            Self::Professional => "Professional",
            Self::Titles => "Titles",
        }
    }
}

/// How a text looks: font, color, stroke, shadow, background. Applying it changes the style only.
#[derive(Clone, Debug, PartialEq)]
pub struct TextLook {
    /// Identity.
    pub id: String,
    /// Shown name.
    pub name: String,
    /// Library family.
    pub category: TextPresetCategory,
    /// The style.
    pub style: TextStyle,
    /// A motion (`TextMotion.id`) that suits the look: the hover preview plays it. Applying the look never applies it.
    pub suggested_motion_id: Option<String>,
}

/// How a text moves: an in-animation, an out-animation or both. Applying it changes the keyframes only.
#[derive(Clone, Debug, PartialEq)]
pub struct TextMotion {
    /// Identity.
    pub id: String,
    /// Shown name.
    pub name: String,
    /// Library family.
    pub category: TextPresetCategory,
    /// The in-animation.
    pub animation_in: Option<KeyframeTemplate>,
    /// The out-animation.
    pub animation_out: Option<KeyframeTemplate>,
}

/// Pure apply logic: a look and a motion are independent and stack in any order.
pub enum TextPresetApply {}

impl TextPresetApply {
    /// The template with the look's style; text, box, highlight and animation stay.
    pub fn apply_look(look: &TextLook, template: &TextTemplate) -> TextTemplate {
        let mut t = template.clone();
        t.style = look.style.clone();
        t
    }

    /// The animation set with the motion's in and/or out side replaced; a side the motion does not carry stays.
    pub fn apply_motion(motion: &TextMotion, set: Option<&AnimationSet>) -> AnimationSet {
        AnimationSet::new(
            motion.animation_in.clone().or_else(|| set.and_then(|s| s.animation_in.clone())),
            motion.animation_out.clone().or_else(|| set.and_then(|s| s.animation_out.clone())),
        )
    }

    /// A text layer's generator payload with the look applied (text, box and animation stay).
    pub fn apply_look_to_ref(look: &TextLook, r: &GeneratorRef) -> Result<GeneratorRef, TextGeneratorError> {
        let (template, animations) = TextGenerator::decode(r)?;
        TextGenerator::make_ref(&Self::apply_look(look, &template), animations.as_ref())
            .map_err(|e| TextGeneratorError::InvalidPayload(e.to_string()))
    }

    /// A text layer's generator payload with the motion applied (style and text stay).
    pub fn apply_motion_to_ref(motion: &TextMotion, r: &GeneratorRef) -> Result<GeneratorRef, TextGeneratorError> {
        let (template, animations) = TextGenerator::decode(r)?;
        TextGenerator::make_ref(&template, Some(&Self::apply_motion(motion, animations.as_ref())))
            .map_err(|e| TextGeneratorError::InvalidPayload(e.to_string()))
    }
}

/// Built-in set. Looks use only bundled (OFL) fonts. Styled after common creator content, not after any template pack.
pub enum TextPresetCatalog {}

impl TextPresetCatalog {
    /// Prefix of a look id on the pasteboard.
    pub const LOOK_PREFIX: &'static str = "textlook.";
    /// Prefix of a motion id on the pasteboard.
    pub const MOTION_PREFIX: &'static str = "textanim.";

    /// The prefixed id of a look.
    pub fn look_id(l: &TextLook) -> String {
        format!("{}{}", Self::LOOK_PREFIX, l.id)
    }

    /// The prefixed id of a motion.
    pub fn motion_id(m: &TextMotion) -> String {
        format!("{}{}", Self::MOTION_PREFIX, m.id)
    }

    /// Whether `id` names a text look or motion.
    pub fn is_text_preset_id(id: &str) -> bool {
        id.starts_with(Self::LOOK_PREFIX) || id.starts_with(Self::MOTION_PREFIX)
    }

    /// Accepts the prefixed (pasteboard) id.
    pub fn look(id: &str) -> Option<TextLook> {
        let raw = id.strip_prefix(Self::LOOK_PREFIX)?;
        Self::looks().iter().find(|l| l.id == raw).cloned()
    }

    /// Accepts the prefixed (pasteboard) id.
    pub fn motion(id: &str) -> Option<TextMotion> {
        let raw = id.strip_prefix(Self::MOTION_PREFIX)?;
        Self::motions().iter().find(|m| m.id == raw).cloned()
    }

    /// The looks of one family.
    pub fn looks_in(c: TextPresetCategory) -> Vec<TextLook> {
        Self::looks().iter().filter(|l| l.category == c).cloned().collect()
    }

    /// The motions of one family.
    pub fn motions_in(c: TextPresetCategory) -> Vec<TextMotion> {
        Self::motions().iter().filter(|m| m.category == c).cloned().collect()
    }

    /// The hand-made looks first, then the generated collection (`TextLookGenerator`).
    pub fn looks() -> &'static [TextLook] {
        static LOOKS: LazyLock<Vec<TextLook>> = LazyLock::new(|| {
            TextPresetCatalog::handmade().iter().chain(TextLookGenerator::looks().iter()).cloned().collect()
        });
        &LOOKS
    }

    /// The hand-made looks.
    pub fn handmade() -> &'static [TextLook] {
        static HANDMADE: LazyLock<Vec<TextLook>> = LazyLock::new(handmade_looks);
        &HANDMADE
    }

    /// The built-in motions.
    pub fn motions() -> &'static [TextMotion] {
        static MOTIONS: LazyLock<Vec<TextMotion>> = LazyLock::new(built_in_motions);
        &MOTIONS
    }
}

fn rgb(r: f64, g: f64, b: f64, a: f64) -> RGBAColor {
    RGBAColor::new(r, g, b, a)
}

fn shadow(a: f64, dist: f64, blur: f64) -> TextShadow {
    TextShadow::from_angle(rgb(0.0, 0.0, 0.0, a), 135.0, dist, blur)
}

fn stroke(color: RGBAColor, width: f64) -> TextStroke {
    TextStroke::new(color, width, StrokePosition::Outside)
}

fn look(id: &str, name: &str, category: TextPresetCategory, style: TextStyle) -> TextLook {
    TextLook { id: id.to_string(), name: name.to_string(), category, style, suggested_motion_id: None }
}

fn handmade_looks() -> Vec<TextLook> {
    use TextPresetCategory::{Professional, Tiktok, Titles, Youtube};
    let ink = RGBAColor::BLACK;
    let white = RGBAColor::WHITE;
    let st = |font: &str, size: f64, weight: FontWeight, color: RGBAColor| TextStyle::new(font, size, weight, color);
    let boxed =
        |color: RGBAColor, h: f64, v: f64, radius: f64| Some(TextBackground::new(color, BoxPadding::new(h, v), radius));
    vec![
        // TikTok
        look(
            "tiktok-classic",
            "Classic Outline",
            Tiktok,
            TextStyle {
                stroke: Some(stroke(ink, 9.0)),
                shadow: Some(shadow(0.55, 3.0, 8.0)),
                line_spacing: 2.0,
                ..st("Montserrat", 72.0, FontWeight::Black, white)
            },
        ),
        look(
            "tiktok-yellow",
            "Yellow Caps",
            Tiktok,
            TextStyle {
                stroke: Some(stroke(ink, 10.0)),
                shadow: Some(shadow(0.6, 4.0, 0.0)),
                tracking: 1.0,
                all_caps: true,
                ..st("Anton", 84.0, FontWeight::Regular, rgb(1.0, 0.85, 0.0, 1.0))
            },
        ),
        look(
            "tiktok-word-box",
            "Highlight Box",
            Tiktok,
            TextStyle {
                background: boxed(rgb(1.0, 0.88, 0.1, 1.0), 22.0, 10.0, 12.0),
                all_caps: true,
                ..st("Archivo Black", 64.0, FontWeight::Regular, ink)
            },
        ),
        look(
            "tiktok-comic",
            "Comic Pop",
            Tiktok,
            TextStyle {
                stroke: Some(TextStroke::new(ink, 8.0, StrokePosition::Centre)),
                shadow: Some(TextShadow::from_angle(rgb(0.9, 0.1, 0.25, 1.0), 135.0, 7.0, 0.0)),
                tracking: 2.0,
                ..st("Bangers", 88.0, FontWeight::Regular, white)
            },
        ),
        // YouTube
        look(
            "yt-reaction",
            "Reaction Bold",
            Youtube,
            TextStyle {
                stroke: Some(stroke(ink, 9.0)),
                shadow: Some(TextShadow::from_angle(rgb(0.0, 0.0, 0.0, 0.8), 135.0, 6.0, 0.0)),
                ..st("Lilita One", 86.0, FontWeight::Regular, white)
            },
        ),
        look(
            "yt-caption-bar",
            "Caption Bar",
            Youtube,
            TextStyle {
                background: boxed(rgb(0.0, 0.0, 0.0, 0.72), 18.0, 8.0, 6.0),
                line_spacing: 2.0,
                ..st("Poppins", 54.0, FontWeight::Bold, white)
            },
        ),
        look(
            "yt-red-flag",
            "Red Flag",
            Youtube,
            TextStyle {
                background: boxed(rgb(0.86, 0.08, 0.1, 1.0), 24.0, 8.0, 4.0),
                tracking: 2.0,
                all_caps: true,
                ..st("Anton", 76.0, FontWeight::Regular, white)
            },
        ),
        look(
            "yt-clean",
            "Clean Shadow",
            Youtube,
            TextStyle { shadow: Some(shadow(0.7, 4.0, 10.0)), ..st("Outfit", 64.0, FontWeight::Bold, white) },
        ),
        // Professional
        look(
            "pro-lower-third",
            "Lower Third",
            Professional,
            TextStyle {
                shadow: Some(shadow(0.5, 2.0, 6.0)),
                alignment: TextAlignment::Left,
                ..st("Montserrat", 46.0, FontWeight::Semibold, white)
            },
        ),
        look(
            "pro-minimal",
            "Minimal Caps",
            Professional,
            TextStyle {
                shadow: Some(shadow(0.4, 2.0, 6.0)),
                tracking: 8.0,
                all_caps: true,
                ..st("Outfit", 42.0, FontWeight::Light, white)
            },
        ),
        look(
            "pro-dark-box",
            "Dark Box",
            Professional,
            TextStyle {
                background: boxed(rgb(0.05, 0.06, 0.08, 0.78), 26.0, 12.0, 3.0),
                ..st("Inter", 44.0, FontWeight::Medium, white)
            },
        ),
        look(
            "pro-serif",
            "Editorial Serif",
            Professional,
            TextStyle {
                shadow: Some(shadow(0.5, 2.0, 8.0)),
                ..st("Playfair Display", 62.0, FontWeight::Regular, white)
            },
        ),
        // Titles
        look(
            "title-bebas",
            "Tall Title",
            Titles,
            TextStyle {
                shadow: Some(shadow(0.55, 4.0, 12.0)),
                tracking: 6.0,
                all_caps: true,
                ..st("Bebas Neue", 132.0, FontWeight::Regular, white)
            },
        ),
        look(
            "title-oswald",
            "Poster Bold",
            Titles,
            TextStyle {
                shadow: Some(shadow(0.6, 5.0, 12.0)),
                tracking: 3.0,
                all_caps: true,
                ..st("Oswald", 110.0, FontWeight::Bold, white)
            },
        ),
        look(
            "title-serif",
            "Display Serif",
            Titles,
            TextStyle {
                shadow: Some(shadow(0.55, 4.0, 12.0)),
                ..st("DM Serif Display", 108.0, FontWeight::Regular, white)
            },
        ),
        look(
            "title-spartan",
            "Heavy Geometric",
            Titles,
            TextStyle {
                stroke: Some(stroke(rgb(0.1, 0.35, 1.0, 1.0), 8.0)),
                shadow: Some(shadow(0.5, 4.0, 10.0)),
                all_caps: true,
                ..st("League Spartan", 112.0, FontWeight::Black, white)
            },
        ),
    ]
}

type Key = (Time, f64, SegmentShape);
type Tracks = Vec<(&'static str, Vec<Key>)>;

fn t(n: i64, d: i64) -> Time {
    Time::new(n, d)
}

fn animation(dur: Time, tracks: Tracks, anchor: AnimationAnchor) -> KeyframeTemplate {
    KeyframeTemplate {
        tracks: tracks.iter().map(|(p, k)| AnimationTrack::from_shapes(p, k)).collect(),
        duration: dur,
        anchor,
        ..KeyframeTemplate::none()
    }
}

fn in_anim(dur: Time, tracks: Tracks) -> KeyframeTemplate {
    animation(dur, tracks, AnimationAnchor::Start)
}

fn out_anim(dur: Time, tracks: Tracks) -> KeyframeTemplate {
    animation(dur, tracks, AnimationAnchor::End)
}

fn fade_in(d: Time) -> (&'static str, Vec<Key>) {
    ("opacity", vec![(Time::ZERO, 0.0, SegmentShape::EaseOut), (d, 1.0, SegmentShape::Linear)])
}

fn fade_out(d: Time) -> (&'static str, Vec<Key>) {
    ("opacity", vec![(Time::ZERO, 1.0, SegmentShape::EaseIn), (d, 0.0, SegmentShape::Linear)])
}

fn motion(
    id: &str,
    name: &str,
    category: TextPresetCategory,
    animation_in: Option<KeyframeTemplate>,
    animation_out: Option<KeyframeTemplate>,
) -> TextMotion {
    TextMotion { id: id.to_string(), name: name.to_string(), category, animation_in, animation_out }
}

fn built_in_motions() -> Vec<TextMotion> {
    use SegmentShape::{EaseIn, EaseInOut, EaseOut, Hold, Linear, Overshoot};
    use TextPresetCategory::{Professional, Tiktok, Titles, Youtube};
    let z = Time::ZERO;
    let fade_out_quick = out_anim(t(1, 5), vec![fade_out(t(1, 5))]);
    vec![
        // TikTok
        motion(
            "tiktok-pop",
            "Pop",
            Tiktok,
            Some(in_anim(
                t(1, 4),
                vec![
                    ("scale", vec![(z, 0.6, Overshoot), (t(1, 4), 1.0, Linear)]),
                    ("opacity", vec![(z, 0.0, EaseOut), (t(1, 8), 1.0, Linear), (t(1, 4), 1.0, Linear)]),
                ],
            )),
            Some(out_anim(t(1, 6), vec![("scale", vec![(z, 1.0, EaseIn), (t(1, 6), 0.8, Linear)]), fade_out(t(1, 6))])),
        ),
        motion(
            "tiktok-bounce",
            "Bounce",
            Tiktok,
            Some(in_anim(
                t(1, 2),
                vec![
                    (
                        "scale",
                        vec![
                            (z, 0.5, EaseOut),
                            (t(3, 20), 1.18, EaseInOut),
                            (t(6, 20), 0.94, EaseInOut),
                            (t(1, 2), 1.0, Linear),
                        ],
                    ),
                    ("opacity", vec![(z, 0.0, Linear), (t(1, 10), 1.0, Linear), (t(1, 2), 1.0, Linear)]),
                ],
            )),
            None,
        ),
        motion(
            "tiktok-jolt",
            "Jolt",
            Tiktok,
            Some(in_anim(
                t(1, 3),
                vec![
                    (
                        "rotation",
                        vec![
                            (z, -8.0, EaseOut),
                            (t(1, 12), 6.0, EaseInOut),
                            (t(1, 6), -3.0, EaseInOut),
                            (t(1, 3), 0.0, Linear),
                        ],
                    ),
                    ("scale", vec![(z, 1.25, EaseOut), (t(1, 6), 1.0, Linear), (t(1, 3), 1.0, Linear)]),
                    ("opacity", vec![(z, 0.0, Linear), (t(1, 20), 1.0, Linear), (t(1, 3), 1.0, Linear)]),
                ],
            )),
            None,
        ),
        motion(
            "tiktok-pop-out",
            "Pop Out",
            Tiktok,
            None,
            Some(out_anim(t(1, 5), vec![("scale", vec![(z, 1.0, EaseIn), (t(1, 5), 0.5, Linear)]), fade_out(t(1, 5))])),
        ),
        // YouTube
        motion(
            "yt-slide-up",
            "Slide Up",
            Youtube,
            Some(in_anim(
                t(1, 3),
                vec![("positionY", vec![(z, 70.0, EaseOut), (t(1, 3), 0.0, Linear)]), fade_in(t(1, 4))],
            )),
            Some(out_anim(
                t(1, 4),
                vec![("positionY", vec![(z, 0.0, EaseIn), (t(1, 4), 50.0, Linear)]), fade_out(t(1, 4))],
            )),
        ),
        motion(
            "yt-slide-left",
            "Slide From Left",
            Youtube,
            Some(in_anim(
                t(2, 5),
                vec![("positionX", vec![(z, -160.0, EaseOut), (t(2, 5), 0.0, Linear)]), fade_in(t(1, 5))],
            )),
            Some(out_anim(
                t(1, 4),
                vec![("positionX", vec![(z, 0.0, EaseIn), (t(1, 4), -120.0, Linear)]), fade_out(t(1, 4))],
            )),
        ),
        motion(
            "yt-drop",
            "Drop In",
            Youtube,
            Some(in_anim(
                t(2, 5),
                vec![("positionY", vec![(z, -140.0, Overshoot), (t(2, 5), 0.0, Linear)]), fade_in(t(1, 8))],
            )),
            None,
        ),
        motion(
            "yt-slide-out",
            "Slide Out Down",
            Youtube,
            None,
            Some(out_anim(
                t(1, 3),
                vec![("positionY", vec![(z, 0.0, EaseIn), (t(1, 3), 90.0, Linear)]), fade_out(t(1, 3))],
            )),
        ),
        // Professional
        motion(
            "pro-fade",
            "Fade",
            Professional,
            Some(in_anim(t(1, 2), vec![fade_in(t(1, 2))])),
            Some(out_anim(t(1, 2), vec![fade_out(t(1, 2))])),
        ),
        motion(
            "pro-rise",
            "Soft Rise",
            Professional,
            Some(in_anim(
                t(3, 5),
                vec![("positionY", vec![(z, 24.0, EaseOut), (t(3, 5), 0.0, Linear)]), fade_in(t(3, 5))],
            )),
            Some(out_anim(t(2, 5), vec![fade_out(t(2, 5))])),
        ),
        motion(
            "pro-soft-zoom",
            "Soft Zoom",
            Professional,
            Some(in_anim(t(3, 5), vec![("scale", vec![(z, 0.94, EaseOut), (t(3, 5), 1.0, Linear)]), fade_in(t(3, 5))])),
            None,
        ),
        motion("pro-fade-out", "Fade Out", Professional, None, Some(fade_out_quick)),
        // Titles
        motion(
            "title-punch",
            "Zoom Punch",
            Titles,
            Some(in_anim(t(1, 3), vec![("scale", vec![(z, 1.5, EaseOut), (t(1, 3), 1.0, Linear)]), fade_in(t(1, 6))])),
            None,
        ),
        motion(
            "title-spin",
            "Spin In",
            Titles,
            Some(in_anim(
                t(1, 2),
                vec![
                    ("rotation", vec![(z, -90.0, Overshoot), (t(1, 2), 0.0, Linear)]),
                    ("scale", vec![(z, 0.3, EaseOut), (t(1, 2), 1.0, Linear)]),
                    fade_in(t(1, 6)),
                ],
            )),
            None,
        ),
        motion(
            "title-flicker",
            "Flicker",
            Titles,
            Some(in_anim(
                t(1, 3),
                vec![(
                    "opacity",
                    vec![
                        (z, 0.0, Hold),
                        (t(1, 15), 1.0, Hold),
                        (t(2, 15), 0.2, Hold),
                        (t(1, 5), 1.0, Hold),
                        (t(1, 3), 1.0, Linear),
                    ],
                )],
            )),
            Some(out_anim(
                t(1, 4),
                vec![(
                    "opacity",
                    vec![(z, 1.0, Hold), (t(1, 12), 0.3, Hold), (t(1, 6), 1.0, Hold), (t(1, 4), 0.0, Linear)],
                )],
            )),
        ),
        // Characters appear one by one (no fade); ends with the text fully shown, so no out side.
        motion(
            "title-typewriter",
            "Typewriter",
            Titles,
            Some(KeyframeTemplate::with_text_animator(
                TextAnimator::new(TextAnimatorEffect::Typewriter, TextAnimatorUnit::Character, Time::ZERO, t(1, 20)),
                AnimationAnchor::Start,
            )),
            None,
        ),
        motion(
            "title-rise-out",
            "Rise Out",
            Titles,
            None,
            Some(out_anim(
                t(2, 5),
                vec![("positionY", vec![(z, 0.0, EaseIn), (t(2, 5), -80.0, Linear)]), fade_out(t(2, 5))],
            )),
        ),
    ]
}

/// One internal switch for the built-in text Looks / Animations and the generated caption looks and presets: removed from
/// every panel until a designed system exists (feedback 2026-10-06, the design notes). Catalogs and tests stay; styles still
/// resolve by id, so a project that uses one opens and renders unchanged. No user setting.
pub enum BuiltInTextLooks {}

impl BuiltInTextLooks {
    /// Whether the built-in text Looks show in the panels.
    pub const IS_ENABLED: bool = false;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bundled_fonts;

    #[test]
    fn catalog_is_well_formed() {
        assert!(TextPresetCatalog::looks().len() >= 8);
        assert!(TextPresetCatalog::motions().len() >= 8);
        let mut ids: Vec<&str> = TextPresetCatalog::looks().iter().map(|l| l.id.as_str()).collect();
        ids.extend(TextPresetCatalog::motions().iter().map(|m| m.id.as_str()));
        let unique: std::collections::BTreeSet<&str> = ids.iter().copied().collect();
        assert_eq!(unique.len(), ids.len());
        for c in TextPresetCategory::ALL {
            assert!(!TextPresetCatalog::looks_in(c).is_empty(), "looks in {c:?}");
            assert!(!TextPresetCatalog::motions_in(c).is_empty(), "motions in {c:?}");
        }
    }

    #[test]
    fn looks_use_bundled_fonts_only() {
        for l in TextPresetCatalog::looks() {
            assert!(bundled_fonts::is_bundled(&l.style.font_name), "{}: {}", l.id, l.style.font_name);
        }
    }

    #[test]
    fn motions_are_anchored_and_fit_properties() {
        let known = ["scale", "opacity", "positionX", "positionY", "rotation"];
        for m in TextPresetCatalog::motions() {
            assert!(m.animation_in.is_some() || m.animation_out.is_some(), "{}", m.id);
            if let Some(i) = &m.animation_in {
                assert!(
                    i.anchor == AnimationAnchor::Start && (i.duration > Time::ZERO || i.text_animator.is_some()),
                    "{}",
                    m.id
                );
                assert!(i.tracks.iter().all(|t| known.contains(&t.property.as_str())), "{}", m.id);
            }
            if let Some(o) = &m.animation_out {
                assert!(o.anchor == AnimationAnchor::End && o.duration > Time::ZERO, "{}", m.id);
                assert!(o.tracks.iter().all(|t| known.contains(&t.property.as_str())), "{}", m.id);
            }
        }
    }

    #[test]
    fn typewriter_is_a_built_in_text_animation() {
        let m = TextPresetCatalog::motion("textanim.title-typewriter").unwrap();
        assert!(m.name == "Typewriter" && m.category == TextPresetCategory::Titles && m.animation_out.is_none());
        let a = m.animation_in.as_ref().and_then(|t| t.text_animator.clone()).unwrap();
        assert!(
            a.effect == TextAnimatorEffect::Typewriter
                && a.unit == TextAnimatorUnit::Character
                && a.stagger > Time::ZERO
        );
        assert!(TextPresetCatalog::motions_in(TextPresetCategory::Titles).contains(&m));
        // Applying it sets the in side and keeps the out side.
        let out = KeyframeTemplate {
            tracks: vec![AnimationTrack::from_shapes(
                "opacity",
                &[(Time::ZERO, 1.0, SegmentShape::Linear), (Time::new(1, 5), 0.0, SegmentShape::Linear)],
            )],
            duration: Time::new(1, 5),
            anchor: AnimationAnchor::End,
            ..KeyframeTemplate::none()
        };
        let set = TextPresetApply::apply_motion(&m, Some(&AnimationSet::new(None, Some(out.clone()))));
        assert!(
            set.animation_in.and_then(|t| t.text_animator).is_some_and(|a| a.effect == TextAnimatorEffect::Typewriter)
        );
        assert_eq!(set.animation_out, Some(out));
    }

    #[test]
    fn look_replaces_style_only() {
        let mut t =
            TextTemplate::new("T", "Hello", TextStyle::new("Inter", 30.0, FontWeight::Regular, RGBAColor::WHITE));
        t.box_ = Some(crate::text_style::TextBox::new(800.0, 200.0));
        let look = &TextPresetCatalog::looks()[0];
        let r = TextPresetApply::apply_look(look, &t);
        assert_eq!(r.style, look.style);
        assert!(r.text == "Hello" && r.box_ == t.box_);
    }

    #[test]
    fn motion_keeps_the_other_side() {
        let motions = TextPresetCatalog::motions();
        let in_only = motions.iter().find(|m| m.animation_in.is_some() && m.animation_out.is_none()).unwrap();
        let out_only = motions.iter().find(|m| m.animation_out.is_some() && m.animation_in.is_none()).unwrap();
        let mut set = TextPresetApply::apply_motion(in_only, None);
        assert!(set.animation_in == in_only.animation_in && set.animation_out.is_none());
        set = TextPresetApply::apply_motion(out_only, Some(&set));
        assert!(set.animation_in == in_only.animation_in && set.animation_out == out_only.animation_out);
        // A second in-animation replaces the first one and keeps the out.
        let other = motions
            .iter()
            .find(|m| m.animation_in.is_some() && m.animation_out.is_none() && m.id != in_only.id)
            .unwrap();
        set = TextPresetApply::apply_motion(other, Some(&set));
        assert!(set.animation_in == other.animation_in && set.animation_out == out_only.animation_out);
    }

    #[test]
    fn look_and_motion_stack_on_a_generator_ref() {
        let t = TextTemplate::new("T", "Hi", TextStyle::default());
        let mut r = TextGenerator::make_ref(&t, None).unwrap();
        let looks = TextPresetCatalog::looks();
        let motions = TextPresetCatalog::motions();
        r = TextPresetApply::apply_look_to_ref(&looks[1], &r).unwrap();
        r = TextPresetApply::apply_motion_to_ref(&motions[0], &r).unwrap();
        let (tt, anim) = TextGenerator::decode(&r).unwrap();
        assert!(tt.style == looks[1].style && tt.text == "Hi");
        assert_eq!(anim.as_ref().and_then(|a| a.animation_in.clone()), motions[0].animation_in);
        // Another look afterwards keeps the animation.
        r = TextPresetApply::apply_look_to_ref(&looks[2], &r).unwrap();
        assert_eq!(TextGenerator::decode(&r).unwrap().1, anim);
    }

    #[test]
    fn wrong_kind_fails() {
        let r = GeneratorRef { kind: "solid".into(), payload: Vec::new(), payload_version: 1 };
        assert!(TextPresetApply::apply_look_to_ref(&TextPresetCatalog::looks()[0], &r).is_err());
    }

    #[test]
    fn id_prefixes() {
        let l = &TextPresetCatalog::looks()[0];
        let m = &TextPresetCatalog::motions()[0];
        assert_eq!(TextPresetCatalog::look(&TextPresetCatalog::look_id(l)).map(|x| x.id), Some(l.id.clone()));
        assert_eq!(TextPresetCatalog::motion(&TextPresetCatalog::motion_id(m)).map(|x| x.id), Some(m.id.clone()));
        assert!(TextPresetCatalog::look("nope").is_none());
        assert!(TextPresetCatalog::is_text_preset_id(&TextPresetCatalog::look_id(l)));
        assert!(!TextPresetCatalog::is_text_preset_id("film.grain"));
    }
}
