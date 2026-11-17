// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TemplateTextStyle.swift
//! The text style a saved title template carries (its first text layer), so a template can be given to an existing text
//! ("select text, click the template, the text takes that style") without placing the template's clip.
//! One system: the template stays a `TitleTemplate`; this only reads its first text layer.

use crate::text_generator::TextGenerator;
use crate::text_style::TextStyle;
use crate::text_template::TextTemplate;
use sq_core_model::GeneratorRef;
use sq_core_model::anchored_animation::AnimationSet;
use sq_core_model::{GraphicsContent, Track};
use sq_core_time::Time;

/// A text style with the in and out animation it was authored with.
#[derive(Clone, Debug, PartialEq)]
pub struct TemplateTextStyle {
    /// The style.
    pub style: TextStyle,
    /// The layer's in and out animation (both sides, as authored).
    pub animations: Option<AnimationSet>,
}

impl TemplateTextStyle {
    /// A style with its animations.
    pub fn new(style: TextStyle, animations: Option<AnimationSet>) -> TemplateTextStyle {
        TemplateTextStyle { style, animations }
    }

    /// The first text layer of a template whose content has `tracks` (`TitleTemplate.content.tracks`): lowest track
    /// first, then earliest start; a text layer of a graphics clip counts like a text clip. Nil when the template has no
    /// readable text layer.
    pub fn from_tracks(tracks: &[Track]) -> Option<TemplateTextStyle> {
        let mut refs: Vec<(usize, Time, usize, &GeneratorRef)> = Vec::new();
        for (ti, track) in tracks.iter().enumerate() {
            for clip in track.clips() {
                if let Some(g) = clip.generator.as_ref().filter(|g| g.kind == TextGenerator::KIND) {
                    refs.push((ti, clip.start, 0, g));
                }
                for (li, layer) in clip.graphics().map(|d| d.layers.as_slice()).unwrap_or_default().iter().enumerate() {
                    if let GraphicsContent::Text { generator } = &layer.content {
                        refs.push((ti, clip.start, li + 1, generator));
                    }
                }
            }
        }
        refs.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)).then(a.2.cmp(&b.2)));
        refs.iter().find_map(|r| TextGenerator::decode(r.3).ok().map(|(t, a)| TemplateTextStyle::new(t.style, a)))
    }

    /// `template` with this style: text and box stay, the Look token is cleared (the text no longer carries a Look).
    /// A side the template does not animate keeps the text's own animation, like a Text Motion.
    pub fn giving(
        &self,
        template: &TextTemplate,
        current: Option<&AnimationSet>,
    ) -> (TextTemplate, Option<AnimationSet>) {
        let mut t = template.clone();
        t.style = self.style.clone();
        t.look_id = None;
        let anims = match &self.animations {
            Some(a) => Some(AnimationSet::new(
                a.animation_in.clone().or_else(|| current.and_then(|c| c.animation_in.clone())),
                a.animation_out.clone().or_else(|| current.and_then(|c| c.animation_out.clone())),
            )),
            None => current.cloned(),
        };
        (t, anims)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::anchored_animation::{AnimationAnchor, AnimationTrack, KeyframeTemplate, SegmentShape};
    use sq_core_model::{Clip, TrackKind};
    use sq_core_time::{Id, SequentialIds, TimeRange};

    fn fade(anchor: AnimationAnchor) -> KeyframeTemplate {
        KeyframeTemplate {
            tracks: vec![AnimationTrack::from_shapes(
                "opacity",
                &[(Time::ZERO, 0.0, SegmentShape::Linear), (Time::new(1, 5), 1.0, SegmentShape::Linear)],
            )],
            duration: Time::new(1, 5),
            anchor,
            ..KeyframeTemplate::none()
        }
    }

    fn style(size: f64) -> TextStyle {
        TextStyle { size, ..TextStyle::default() }
    }

    fn text_clip(n: u128, text: &str, size: f64, start: Time, anims: Option<&AnimationSet>) -> Clip {
        let t = TextTemplate::new("T", text, style(size));
        let r = TextGenerator::make_ref(&t, anims).unwrap();
        let mut c = Clip::new(
            Id::from_u128(n),
            text,
            Id::from_u128(100 + n),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::new(3, 1)),
            start,
        );
        c.generator = Some(r);
        c
    }

    fn track(clips: Vec<Clip>) -> Track {
        let mut t = Track::new(Id::from_u128(900), TrackKind::Video);
        let mut ids = SequentialIds::default();
        for c in clips {
            t.overwrite(c, &mut ids).unwrap();
        }
        t
    }

    #[test]
    fn reads_first_text_layer_style_and_both_animations() {
        let anims = AnimationSet::new(Some(fade(AnimationAnchor::Start)), Some(fade(AnimationAnchor::End)));
        let tracks = [
            track(vec![text_clip(1, "A", 90.0, Time::ZERO, Some(&anims))]),
            track(vec![text_clip(2, "B", 20.0, Time::ZERO, None)]),
        ];
        let s = TemplateTextStyle::from_tracks(&tracks).unwrap();
        assert_eq!(s.style.size, 90.0);
        assert!(s.animations.is_some_and(|a| a.animation_in.is_some() && a.animation_out.is_some()));
    }

    #[test]
    fn earliest_start_wins_within_a_track() {
        let t = track(vec![
            text_clip(1, "late", 30.0, Time::new(5, 1), None),
            text_clip(2, "early", 60.0, Time::ZERO, None),
        ]);
        assert_eq!(TemplateTextStyle::from_tracks(&[t]).unwrap().style.size, 60.0);
    }

    #[test]
    fn template_without_text_has_no_style() {
        let mut c = Clip::new(
            Id::from_u128(1),
            "s",
            Id::from_u128(2),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::new(1, 1)),
            Time::ZERO,
        );
        c.generator = Some(GeneratorRef { kind: "shape".into(), payload: b"{}".to_vec(), payload_version: 1 });
        assert!(TemplateTextStyle::from_tracks(&[track(vec![c])]).is_none());
    }

    #[test]
    fn giving_keeps_text_and_box_and_clears_look() {
        let b = crate::text_style::TextBox::new(800.0, 200.0);
        let mut t = TextTemplate::new("T", "Hello", style(30.0));
        t.box_ = Some(b);
        t.look_id = Some("clean".into());
        let s = TemplateTextStyle::new(style(77.0), Some(AnimationSet::new(Some(fade(AnimationAnchor::Start)), None)));
        let own_out = fade(AnimationAnchor::End);
        let current = AnimationSet::new(None, Some(own_out.clone()));
        let (tpl, anims) = s.giving(&t, Some(&current));
        assert!(tpl.text == "Hello" && tpl.box_ == Some(b) && tpl.style.size == 77.0 && tpl.look_id.is_none());
        let anims = anims.unwrap();
        assert!(anims.animation_in.is_some());
        assert_eq!(anims.animation_out, current.animation_out); // a side the template lacks stays
    }
}
