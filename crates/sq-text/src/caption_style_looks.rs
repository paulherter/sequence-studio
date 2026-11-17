// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: CaptionStyleLooks.swift
//! The ready caption/title looks of the gallery: a style, an animation and (for captions) a word highlight.

use crate::caption_presets::CaptionPresetLibrary;
use crate::generated_caption_looks::GeneratedCaptionLooks;
use crate::text_presets::{BuiltInTextLooks, TextPresetCategory};
use sq_core_graphics::text_animator_model::KeyframeTemplateTextExt;
use sq_core_model::KaraokeStyle;
use sq_core_model::anchored_animation::{
    AnimationAnchor, AnimationSet, AnimationTrack, KeyframeTemplate, SegmentShape, TextAnimator, TextAnimatorEffect,
    TextAnimatorUnit,
};
use sq_core_time::Time;
use std::collections::BTreeMap;
use std::sync::LazyLock;

/// Gallery group of a look (the order of the gallery sections).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum LookGroup {
    /// Word light.
    WordLight,
    /// Entrance.
    Entrance,
    /// Loop.
    Motion,
    /// Exit.
    Exit,
    /// Collection.
    Collection,
}

impl LookGroup {
    /// Every group, in gallery order.
    pub const ALL: [LookGroup; 5] = [Self::WordLight, Self::Entrance, Self::Motion, Self::Exit, Self::Collection];

    /// The shown name.
    pub fn title(self) -> &'static str {
        match self {
            Self::WordLight => "Word light",
            Self::Entrance => "Entrance",
            Self::Motion => "Loop",
            Self::Exit => "Exit",
            Self::Collection => "Collection",
        }
    }
}

/// A ready caption/title look: a style, an animation and (for captions) a word highlight, all by the refs of
/// `CaptionPresetLibrary`, so applying one only sets the same values the panels edit by hand and everything stays
/// editable afterwards.
#[derive(Clone, Debug, PartialEq)]
pub struct CaptionStyleLook {
    /// Identity.
    pub id: String,
    /// Shown name.
    pub title: String,
    /// Gallery group.
    pub group: LookGroup,
    /// Style ref in the preset library.
    pub style_ref: String,
    /// Animation ref in the preset library.
    pub animation_ref: String,
    /// Word highlight of caption tracks; titles have no spoken words and ignore it.
    pub karaoke: Option<KaraokeStyle>,
    /// Family of a generated look (`GeneratedCaptionLooks`); nil for the hand-made ones.
    pub category: Option<TextPresetCategory>,
}

impl CaptionStyleLook {
    /// A look without a family.
    pub fn new(
        id: &str,
        title: &str,
        group: LookGroup,
        style_ref: &str,
        animation_ref: &str,
        karaoke: Option<KaraokeStyle>,
    ) -> CaptionStyleLook {
        CaptionStyleLook {
            id: id.to_string(),
            title: title.to_string(),
            group,
            style_ref: style_ref.to_string(),
            animation_ref: animation_ref.to_string(),
            karaoke,
            category: None,
        }
    }

    /// `current` with this look's animation in the slot of its anchor (in-animation or out-animation); the other slot
    /// is kept, so an entrance look does not remove an exit look.
    pub fn animation_set(&self, library: &CaptionPresetLibrary, current: &AnimationSet) -> AnimationSet {
        let t = library.animation(Some(&self.animation_ref));
        if t == KeyframeTemplate::none() {
            return current.clone();
        }
        if t.anchor == AnimationAnchor::Start {
            AnimationSet::new(Some(t), current.animation_out.clone())
        } else {
            AnimationSet::new(current.animation_in.clone(), Some(t))
        }
    }
}

/// Where a look's text sits at one moment of its preview (the maths behind the gallery swatches).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LookPose {
    /// Scale.
    pub scale: f64,
    /// Opacity.
    pub opacity: f64,
    /// Horizontal offset.
    pub offset_x: f64,
    /// Vertical offset.
    pub offset_y: f64,
}

/// Namespace of the caption look gallery.
pub enum CaptionStyleLooks {}

fn karaoke(red: f64, green: f64, blue: f64, keep_spoken: bool) -> Option<KaraokeStyle> {
    Some(KaraokeStyle { red, green, blue, keep_spoken })
}

impl CaptionStyleLooks {
    /// Length of the preview window; exit animations play at its end, a lit word advances evenly across it.
    pub const PREVIEW_DURATION: Time = Time::new(2, 1);

    /// The clean presets (fade, rise, scale; no bounce), listed first among the Intro / Outro choices.
    pub const NEUTRAL_INTRO_IDS: [&'static str; 3] = ["fade", "rise", "scale-in"];
    /// The clean exit presets.
    pub const NEUTRAL_OUTRO_IDS: [&'static str; 3] = ["fade-out", "slide-out", "scale-out"];

    /// The hand-made looks first, then the generated collection.
    /// Generated ones only while `BuiltInTextLooks.isEnabled` (off: removed from the gallery, styles still resolve by id).
    pub fn all() -> &'static [CaptionStyleLook] {
        static ALL: LazyLock<Vec<CaptionStyleLook>> = LazyLock::new(|| {
            let mut all = CaptionStyleLooks::handmade();
            if BuiltInTextLooks::IS_ENABLED {
                all.extend(GeneratedCaptionLooks::all().iter().cloned());
            }
            all
        });
        &ALL
    }

    /// The hand-made looks.
    pub fn handmade() -> Vec<CaptionStyleLook> {
        use LookGroup::{Entrance, Exit, Motion, WordLight};
        let l = CaptionStyleLook::new;
        vec![
            l("spark", "Spark", WordLight, "tiktok", "pop", karaoke(1.0, 0.86, 0.1, false)),
            l("fill-up", "Fill-up", WordLight, "youtube", "fade", karaoke(0.3, 0.85, 1.0, true)),
            l("ember", "Ember", WordLight, "outline", "pop-in", karaoke(1.0, 0.5, 0.1, true)),
            l("mint-card", "Mint card", WordLight, "bold-box", "fade", karaoke(0.35, 1.0, 0.65, false)),
            l("type-on", "Type-on", WordLight, "ghost", "none", karaoke(1.0, 1.0, 1.0, true)),
            l("pop", "Pop", Entrance, "title", "pop", None),
            l("rise", "Rise", Entrance, "sticker", "rise", None),
            l("slide-in", "Slide in", Entrance, "neon", "slide-side", None),
            l("drop-in", "Drop in", Entrance, "tiktok", "bounce-in", None),
            l("word-bounce", "Word bounce", Entrance, "tiktok", "word-bounce", None),
            l("ripple", "Ripple", Entrance, "title", "ripple-in", None),
            l("wave", "Wave", Motion, "title", "wave", None),
            l("hop", "Hop", Motion, "tiktok", "hop", None),
            l("pulse", "Pulse", Motion, "neon", "pulse", None),
            l("sway", "Sway", Motion, "youtube", "sway", None),
            l("shake", "Shake", Motion, "outline", "shake", None),
            l("fade-away", "Fade away", Exit, "classic", "fade-out", None),
            l("shrink-out", "Shrink out", Exit, "bold-box", "shrink-out", None),
            l("slide-away", "Slide away", Exit, "title", "slide-out", None),
            l("ripple-out", "Ripple out", Exit, "title", "ripple-out", None),
            l("word-pop-out", "Word pop out", Exit, "tiktok", "word-pop-out", None),
        ]
    }

    /// The look under `id`.
    pub fn look(id: &str) -> Option<&'static CaptionStyleLook> {
        Self::all().iter().find(|l| l.id == id)
    }

    /// The looks of one gallery group.
    pub fn looks_in(group: LookGroup) -> Vec<&'static CaptionStyleLook> {
        Self::all().iter().filter(|l| l.group == group).collect()
    }

    /// The look whose style, animation and highlight all match (nil once any of them was edited).
    pub fn matching(
        style_ref: &str,
        animation_ref: &str,
        karaoke: Option<&KaraokeStyle>,
    ) -> Option<&'static CaptionStyleLook> {
        Self::all()
            .iter()
            .find(|l| l.style_ref == style_ref && l.animation_ref == animation_ref && l.karaoke.as_ref() == karaoke)
    }

    /// Pose of the look at preview time `t` (0 ..< `PREVIEW_DURATION`), from the same template maths playback uses.
    pub fn pose(look: &CaptionStyleLook, library: &CaptionPresetLibrary, t: Time) -> LookPose {
        let a = library.animation(Some(&look.animation_ref));
        let v = |p: &str, d: f64| a.value_of_clip_time(p, t, Self::PREVIEW_DURATION).unwrap_or(d);
        LookPose {
            scale: v("scale", 1.0),
            opacity: v("opacity", 1.0).clamp(0.0, 1.0),
            offset_x: v("positionX", 0.0),
            offset_y: v("positionY", 0.0),
        }
    }

    /// Index of the word lit at preview time `t` when the words share the window evenly; nil without words.
    pub fn lit_word(count: usize, t: Time) -> Option<usize> {
        if count == 0 {
            return None;
        }
        let p = Self::PREVIEW_DURATION;
        let n = i128::from(t.value()) * count as i128 * i128::from(p.timescale());
        let d = i128::from(t.timescale()) * i128::from(p.value());
        let i = if n < 0 { 0 } else { usize::try_from(n / d).unwrap_or(usize::MAX) };
        Some(i.min(count - 1))
    }

    /// The animations the looks need (merged into `CaptionPresetLibrary.builtIn`).
    pub fn extra_animations() -> BTreeMap<String, KeyframeTemplate> {
        static EXTRA: LazyLock<BTreeMap<String, KeyframeTemplate>> = LazyLock::new(extra_animations);
        EXTRA.clone()
    }
}

type Key = (Time, f64, SegmentShape);

fn template(tracks: Vec<(&str, Vec<Key>)>, duration: Time, anchor: AnimationAnchor, loops: bool) -> KeyframeTemplate {
    KeyframeTemplate {
        tracks: tracks.iter().map(|(p, k)| AnimationTrack::from_shapes(p, k)).collect(),
        duration,
        anchor,
        loops,
        ..KeyframeTemplate::none()
    }
}

fn extra_animations() -> BTreeMap<String, KeyframeTemplate> {
    use AnimationAnchor::{End, Start};
    use SegmentShape::{EaseIn, EaseInOut, EaseOut, Linear, Overshoot};
    let z = Time::ZERO;
    let t = Time::new;
    let f = t(1, 30);
    let fade_in = |end: Time| ("opacity", vec![(z, 0.0, Linear), (end, 1.0, Linear)]);
    // Scale 0 / 120 / 100 at frames 0 / 4 / 10 (the pop caption of USAGE-PREMIERE).
    let pop = template(
        vec![("scale", vec![(z, 0.0, EaseOut), (f * 4, 1.2, EaseInOut), (f * 10, 1.0, Linear)])],
        f * 10,
        Start,
        false,
    );
    let rise = template(
        vec![("positionY", vec![(z, 48.0, EaseOut), (t(1, 4), 0.0, Linear)]), fade_in(t(1, 6))],
        t(1, 4),
        Start,
        false,
    );
    let slide_side = template(
        vec![("positionX", vec![(z, -90.0, EaseOut), (t(1, 4), 0.0, Linear)]), fade_in(t(1, 6))],
        t(1, 4),
        Start,
        false,
    );
    let bounce_in = template(
        vec![("positionY", vec![(z, 70.0, Overshoot), (t(1, 3), 0.0, Linear)]), fade_in(t(1, 10))],
        t(1, 3),
        Start,
        false,
    );
    // Loops: the last key equals the first, so the cycle repeats without a jump.
    let wave = template(
        vec![(
            "positionY",
            vec![(z, 0.0, EaseInOut), (t(1, 4), -14.0, EaseInOut), (t(3, 4), 14.0, EaseInOut), (t(1, 1), 0.0, Linear)],
        )],
        t(1, 1),
        Start,
        true,
    );
    let hop = template(
        vec![(
            "positionY",
            vec![(z, 0.0, EaseOut), (t(1, 6), -24.0, EaseIn), (t(1, 3), 0.0, Linear), (t(2, 3), 0.0, Linear)],
        )],
        t(2, 3),
        Start,
        true,
    );
    let pulse = template(
        vec![("scale", vec![(z, 1.0, EaseInOut), (t(1, 2), 1.08, EaseInOut), (t(1, 1), 1.0, Linear)])],
        t(1, 1),
        Start,
        true,
    );
    let sway = template(
        vec![(
            "positionX",
            vec![(z, 0.0, EaseInOut), (t(3, 8), -10.0, EaseInOut), (t(9, 8), 10.0, EaseInOut), (t(3, 2), 0.0, Linear)],
        )],
        t(3, 2),
        Start,
        true,
    );
    let shrink_out = template(vec![("scale", vec![(z, 1.0, EaseIn), (t(1, 5), 0.0, Linear)])], t(1, 5), End, false);
    let slide_out = template(
        vec![
            ("positionY", vec![(z, 0.0, EaseIn), (t(1, 4), 48.0, Linear)]),
            ("opacity", vec![(z, 1.0, Linear), (t(1, 4), 0.0, Linear)]),
        ],
        t(1, 4),
        End,
        false,
    );
    // Neutral pair for graphic items and captions: a small scale with a fade, no overshoot.
    let scale_in = template(
        vec![("scale", vec![(z, 0.9, EaseOut), (t(1, 5), 1.0, Linear)]), fade_in(t(1, 5))],
        t(1, 5),
        Start,
        false,
    );
    let scale_out = template(
        vec![
            ("scale", vec![(z, 1.0, EaseIn), (t(1, 5), 0.9, Linear)]),
            ("opacity", vec![(z, 1.0, Linear), (t(1, 5), 0.0, Linear)]),
        ],
        t(1, 5),
        End,
        false,
    );
    // Shake: a short side-to-side jitter that returns to its start, so the cycle repeats without a jump.
    let shake = template(
        vec![(
            "positionX",
            vec![
                (z, 0.0, EaseInOut),
                (f * 2, -7.0, EaseInOut),
                (f * 5, 7.0, EaseInOut),
                (f * 8, -4.0, EaseInOut),
                (f * 10, 0.0, Linear),
            ],
        )],
        f * 10,
        Start,
        true,
    );
    // Per-unit entrances and exits ride on the text animator (no keyframe tracks): words pop with overshoot, characters
    // rise one after another. The exits mirror them against the caption end.
    let animator = |effect, unit, easing, duration, stagger| {
        let mut a = TextAnimator::new(effect, unit, duration, stagger);
        a.easing = easing;
        a
    };
    let rippler = |easing| {
        let mut a = animator(TextAnimatorEffect::Slide, TextAnimatorUnit::Character, easing, t(1, 5), t(1, 30));
        a.distance = 28.0;
        a
    };
    let word_bounce = KeyframeTemplate::with_text_animator(
        animator(TextAnimatorEffect::Pop, TextAnimatorUnit::Word, Overshoot, t(1, 5), t(1, 10)),
        Start,
    );
    let ripple_in = KeyframeTemplate::with_text_animator(rippler(EaseOut), Start);
    let ripple_out = KeyframeTemplate::with_text_animator(rippler(EaseIn), End);
    let word_pop_out = KeyframeTemplate::with_text_animator(
        animator(TextAnimatorEffect::Pop, TextAnimatorUnit::Word, EaseIn, t(1, 6), t(1, 12)),
        End,
    );
    [
        ("word-bounce", word_bounce),
        ("ripple-in", ripple_in),
        ("ripple-out", ripple_out),
        ("word-pop-out", word_pop_out),
        ("shake", shake),
        ("pop", pop),
        ("rise", rise),
        ("slide-side", slide_side),
        ("bounce-in", bounce_in),
        ("wave", wave),
        ("hop", hop),
        ("pulse", pulse),
        ("sway", sway),
        ("shrink-out", shrink_out),
        ("slide-out", slide_out),
        ("scale-in", scale_in),
        ("scale-out", scale_out),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v))
    .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lib() -> CaptionPresetLibrary {
        CaptionPresetLibrary::built_in()
    }

    fn anim(id: &str) -> KeyframeTemplate {
        lib().animation(Some(id))
    }

    #[test]
    fn looping_template_repeats_its_cycle() {
        let t = anim("wave");
        assert!(t.loops && t.anchor == AnimationAnchor::Start && t.duration > Time::ZERO);
        let probe = Time::new(1, 7);
        let a = t.value_of("positionY", probe).unwrap();
        for n in [1i64, 2, 5] {
            assert!((t.value_of("positionY", probe + t.duration * n).unwrap() - a).abs() < 1e-9);
        }
    }

    #[test]
    fn non_looping_template_still_clamps() {
        let t = anim("rise");
        assert!(!t.loops);
        assert_eq!(t.value_of("positionY", t.duration * 10), Some(0.0));
    }

    #[test]
    fn animation_set_plays_loops_past_the_cycle() {
        let set = AnimationSet::new(Some(anim("pulse")), None);
        let d = anim("pulse").duration;
        let early = set.value_of("scale", Time::new(1, 8), Time::new(10, 1)).unwrap();
        let late = set.value_of("scale", Time::new(1, 8) + d * 3, Time::new(10, 1)).unwrap();
        assert!((early - late).abs() < 1e-9);
    }

    #[test]
    fn pop_scales_zero_to_120_to_100_at_frames_0_4_10() {
        let t = anim("pop");
        let f = Time::new(1, 30);
        assert_eq!(t.value_of("scale", Time::ZERO), Some(0.0));
        assert!((t.value_of("scale", f * 4).unwrap() - 1.2).abs() < 1e-9);
        assert!((t.value_of("scale", f * 10).unwrap() - 1.0).abs() < 1e-9);
        assert_eq!(t.duration, f * 10);
    }

    #[test]
    fn exit_animations_are_end_anchored_and_end_invisible_or_gone() {
        for id in ["fade-out", "shrink-out", "slide-out"] {
            let t = anim(id);
            assert_eq!(t.anchor, AnimationAnchor::End, "{id}");
            let clip = Time::new(3, 1);
            let end = clip - Time::new(1, 1000);
            let o = t.value_of_clip_time("opacity", end, clip).unwrap_or(1.0);
            let s = t.value_of_clip_time("scale", end, clip).unwrap_or(1.0);
            assert!(o < 0.05 || s < 0.05, "{id}");
        }
    }

    #[test]
    fn gallery_has_looks_with_unique_ids_and_known_refs() {
        let all = CaptionStyleLooks::all();
        assert!((12..=24).contains(&CaptionStyleLooks::handmade().len()));
        let unique: std::collections::BTreeSet<&str> = all.iter().map(|l| l.id.as_str()).collect();
        assert_eq!(unique.len(), all.len());
        let lib = lib();
        for l in all {
            assert!(lib.has_style(&l.style_ref), "{} style", l.id);
            assert!(lib.has_animation(&l.animation_ref), "{} animation", l.id);
            assert!(!l.title.is_empty());
        }
        for g in LookGroup::ALL {
            if g != LookGroup::Collection || BuiltInTextLooks::IS_ENABLED {
                assert!(all.iter().any(|l| l.group == g), "group {g:?}");
            }
        }
    }

    #[test]
    fn each_motion_category_is_covered() {
        let ids: std::collections::BTreeSet<&str> =
            CaptionStyleLooks::all().iter().map(|l| l.animation_ref.as_str()).collect();
        for need in ["pop", "wave", "hop", "pulse", "slide-out", "rise"] {
            assert!(ids.contains(need), "{need}");
        }
        assert!(CaptionStyleLooks::all().iter().any(|l| l.karaoke.as_ref().is_some_and(|k| k.keep_spoken)));
        assert!(CaptionStyleLooks::all().iter().any(|l| l.karaoke.as_ref().is_some_and(|k| !k.keep_spoken)));
    }

    #[test]
    fn animation_set_puts_the_look_in_the_slot_of_its_anchor() {
        let lib = lib();
        let pop = CaptionStyleLooks::look("pop").unwrap();
        let set = pop.animation_set(&lib, &AnimationSet::new(None, Some(anim("fade-out"))));
        assert_eq!(set.animation_in, Some(anim("pop")));
        assert_eq!(set.animation_out, Some(anim("fade-out")));
        let out = CaptionStyleLooks::look("shrink-out").unwrap();
        let s2 = out.animation_set(&lib, &AnimationSet::new(Some(anim("pop")), None));
        assert_eq!(s2.animation_in, Some(anim("pop")));
        assert_eq!(s2.animation_out.map(|t| t.anchor), Some(AnimationAnchor::End));
    }

    #[test]
    fn unit_animator_looks_carry_text_animators_on_the_right_side() {
        let expect = [
            ("word-bounce", TextAnimatorEffect::Pop, TextAnimatorUnit::Word, AnimationAnchor::Start),
            ("ripple-in", TextAnimatorEffect::Slide, TextAnimatorUnit::Character, AnimationAnchor::Start),
            ("ripple-out", TextAnimatorEffect::Slide, TextAnimatorUnit::Character, AnimationAnchor::End),
            ("word-pop-out", TextAnimatorEffect::Pop, TextAnimatorUnit::Word, AnimationAnchor::End),
        ];
        for (id, effect, unit, anchor) in expect {
            let t = anim(id);
            let a = t.text_animator.clone().unwrap();
            assert!(a.effect == effect && a.unit == unit, "{id}");
            assert_eq!(t.anchor, anchor, "{id}");
            assert!(CaptionStyleLooks::all().iter().any(|l| l.animation_ref == id), "{id} has a gallery look");
        }
        assert_eq!(anim("word-bounce").text_animator.map(|a| a.easing), Some(SegmentShape::Overshoot));
    }

    #[test]
    fn shake_loops_without_a_jump() {
        let t = anim("shake");
        assert!(t.loops && t.anchor == AnimationAnchor::Start);
        assert_eq!(t.value_of("positionX", Time::ZERO), t.value_of("positionX", t.duration));
    }

    #[test]
    fn preview_pose_is_pure_and_rational_in_time() {
        let lib = lib();
        let look = CaptionStyleLooks::look("pop").unwrap();
        let a = CaptionStyleLooks::pose(look, &lib, Time::new(1, 15));
        assert_eq!(a, CaptionStyleLooks::pose(look, &lib, Time::new(1, 15)));
        assert!((a.scale - anim("pop").value_of("scale", Time::new(1, 15)).unwrap()).abs() < 1e-12);
        let rest = CaptionStyleLooks::pose(look, &lib, Time::new(1, 1));
        assert!(rest.scale == 1.0 && rest.opacity == 1.0 && rest.offset_y == 0.0);
    }

    #[test]
    fn the_lit_word_advances_evenly_across_the_preview() {
        assert_eq!(CaptionStyleLooks::lit_word(0, Time::ZERO), None);
        assert_eq!(CaptionStyleLooks::lit_word(4, Time::ZERO), Some(0));
        assert_eq!(CaptionStyleLooks::lit_word(4, Time::new(1, 1)), Some(2));
        assert_eq!(CaptionStyleLooks::lit_word(4, Time::new(5, 1)), Some(3));
        assert_eq!(CaptionStyleLooks::lit_word(4, Time::new(-1, 1)), Some(0));
    }
}
