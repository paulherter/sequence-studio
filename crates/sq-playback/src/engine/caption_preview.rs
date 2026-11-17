// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SQPlayback/CaptionPreview.swift
//! Captions in the Program monitor: each visible caption is a text layer in the caption box, with the same style, wrap width
//! and margin as the export burn-in, so the picture you cut on is the picture you export.
//! A caption handing over to the next one stays under it while the next one's in-animation shows nothing or fades in
//! (`CaptionHandover::draw`, the same call as the Swift Program monitor and burn-in).

use super::caption_plan::{CaptionPlanner, CaptionRefs};
use super::look_preview::LookPreview;
use sq_core_audio::CaptionHandover;
use sq_core_graphics::text_animator_model::CaptionHandoverAnimationExt;
use sq_core_model::anchored_animation::AnimationSet;
use sq_core_model::{CaptionItem, GeneratorRef, KaraokeStyle, SequenceFormat};
use sq_core_time::{Time, Vec2};
use sq_text::caption_karaoke::{CaptionKaraoke, TextHighlight};
use sq_text::caption_layout::CaptionLayout;
use sq_text::caption_presets::CaptionPresetLibrary;
use sq_text::text_generator::TextGenerator;
use std::sync::Arc;

/// The planner of the app: the built-in and registered caption looks.
pub struct CaptionPreview;

fn named(reference: &str) -> Option<&str> {
    (!reference.is_empty()).then_some(reference)
}

impl CaptionPreview {
    fn text_ref(
        item: &CaptionItem,
        canvas: &SequenceFormat,
        library: &CaptionPresetLibrary,
        highlight: Option<TextHighlight>,
    ) -> Option<GeneratorRef> {
        let layout = canvas.layout_format();
        let template = CaptionLayout::template(
            &item.lines.join("\n"),
            &library.style(named(&item.style_ref)),
            layout.width as f64,
            layout.height as f64,
            CaptionLayout::WIDTH_FRACTION,
            highlight,
            &item.position.unwrap_or(library.position),
        );
        let animation = library.animation(named(&item.animation_ref));
        TextGenerator::make_ref(&template, AnimationSet::single(Some(&animation)).as_ref()).ok()
    }
}

fn plan_with(
    library: &CaptionPresetLibrary,
    item: &CaptionItem,
    karaoke: Option<&KaraokeStyle>,
    canvas: &SequenceFormat,
    t: Time,
    held: bool,
) -> Option<CaptionRefs> {
    let style = library.style(named(&item.style_ref));
    // A karaoke caption with a pill draws one pill per word.
    let plain = CaptionPreview::text_ref(
        item,
        canvas,
        library,
        CaptionKaraoke::plain_highlight(&style, karaoke, item.tokens().len()),
    )?;
    let lit = karaoke.and_then(|k| {
        let highlight = if held {
            CaptionKaraoke::held_highlight(item, Some(k))
        } else {
            CaptionKaraoke::highlight(item, Some(k), t)
        };
        CaptionPreview::text_ref(item, canvas, library, Some(highlight?))
    });
    Some(CaptionRefs { plain, lit })
}

fn position_with(library: &CaptionPresetLibrary, item: &CaptionItem, canvas: &SequenceFormat) -> Vec2 {
    let layout = canvas.layout_format();
    let (x, y) = CaptionLayout::box_centre(
        layout.width as f64,
        layout.height as f64,
        &item.position.unwrap_or(library.position),
        CaptionLayout::BOTTOM_MARGIN,
    );
    Vec2::new(x, y)
}

impl CaptionPlanner for CaptionPreview {
    fn previewed(&self, preview: &LookPreview) -> Option<Arc<dyn CaptionPlanner>> {
        let library = preview.caption_library(&CaptionPresetLibrary::built_in())?;
        let karaoke = match preview {
            LookPreview::Captions { karaoke, .. } => karaoke.as_deref().cloned(),
            LookPreview::Text { .. } => None,
        };
        Some(Arc::new(PreviewedCaptions { library, karaoke }))
    }

    fn plan(
        &self,
        item: &CaptionItem,
        karaoke: Option<&KaraokeStyle>,
        canvas: &SequenceFormat,
        t: Time,
        held: bool,
        _forward: bool,
    ) -> Option<CaptionRefs> {
        plan_with(&CaptionPresetLibrary::built_in(), item, karaoke, canvas, t, held)
    }

    fn position(&self, item: &CaptionItem, canvas: &SequenceFormat) -> Vec2 {
        position_with(&CaptionPresetLibrary::built_in(), item, canvas)
    }

    fn hand_over(
        &self,
        tail: &CaptionItem,
        item: &CaptionItem,
        natural_clip_time: Time,
        frame_duration: Time,
        plain: &GeneratorRef,
    ) -> Option<(Time, f64)> {
        hand_over_with(&CaptionPresetLibrary::built_in(), tail, item, natural_clip_time, frame_duration, plain)
    }
}

/// The captions of a Look hover preview: every style (and animation) id resolves to the previewed Look's.
struct PreviewedCaptions {
    library: CaptionPresetLibrary,
    /// The previewed Look's highlight; the track's own when the Look has none.
    karaoke: Option<KaraokeStyle>,
}

impl CaptionPlanner for PreviewedCaptions {
    fn plan(
        &self,
        item: &CaptionItem,
        karaoke: Option<&KaraokeStyle>,
        canvas: &SequenceFormat,
        t: Time,
        held: bool,
        _forward: bool,
    ) -> Option<CaptionRefs> {
        plan_with(&self.library, item, self.karaoke.as_ref().or(karaoke), canvas, t, held)
    }

    fn position(&self, item: &CaptionItem, canvas: &SequenceFormat) -> Vec2 {
        position_with(&self.library, item, canvas)
    }

    fn hand_over(
        &self,
        tail: &CaptionItem,
        item: &CaptionItem,
        natural_clip_time: Time,
        frame_duration: Time,
        plain: &GeneratorRef,
    ) -> Option<(Time, f64)> {
        hand_over_with(&self.library, tail, item, natural_clip_time, frame_duration, plain)
    }
}

/// The hand-over of `tail` under `item`, with the animations resolved through `library`.
fn hand_over_with(
    library: &CaptionPresetLibrary,
    tail: &CaptionItem,
    item: &CaptionItem,
    natural_clip_time: Time,
    frame_duration: Time,
    plain: &GeneratorRef,
) -> Option<(Time, f64)> {
    let animations = |c: &CaptionItem| AnimationSet::single(Some(&library.animation(named(&c.animation_ref))));
    let entering = animations(item)?;
    let previous = animations(tail);
    let units = || TextGenerator::portable_units(plain);
    let d = CaptionHandover::draw(previous.as_ref(), Some(&entering), natural_clip_time, frame_duration, &units);
    Some((d.clip_time, d.tail_opacity))
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::{Id, TimeRange};

    fn caption(start: i64, animation: &str) -> CaptionItem {
        CaptionItem {
            id: Id::from_u128(1),
            lines: vec!["so this works".into()],
            range: TimeRange::new(Time::new(start, 1), Time::new(1, 1)),
            style_ref: String::new(),
            animation_ref: animation.into(),
            style_overridden: false,
            words: Vec::new(),
            position: None,
        }
    }

    #[test]
    fn a_fading_in_caption_keeps_the_one_before_under_it() {
        sq_text::portable_font_match::set_fonts_root(
            &std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../Packages/SQText/Sources/SQText/Resources/Fonts"),
        );
        let library = CaptionPresetLibrary::built_in();
        let fade = library
            .animations
            .iter()
            .find(|(_, t)| !t.loops && t.text_animator.is_none() && t.value_of("opacity", Time::ZERO) == Some(0.0))
            .map(|(id, _)| id.clone());
        let fade = fade.expect("a built-in fade-in look");
        let canvas = SequenceFormat::new(Time::new(1, 30));
        let (tail, item) = (caption(0, ""), caption(1, &fade));
        let plain = CaptionPreview.plan(&item, None, &canvas, Time::new(1, 1), false, true).map(|p| p.plain);
        let plain = plain.expect("plain ref");
        // The first frame of a fade-in shows nothing, so the caption before is drawn at full opacity under it.
        let first = CaptionPreview.hand_over(&tail, &item, Time::ZERO, Time::new(1, 30), &plain);
        assert!(first.is_some_and(|(_, o)| o > 0.0), "{first:?}");
        // Long after the in-animation the tail is gone.
        let late = CaptionPreview.hand_over(&tail, &item, Time::new(5, 1), Time::new(1, 30), &plain);
        assert_eq!(late.map(|(_, o)| o), Some(0.0));
    }
}
