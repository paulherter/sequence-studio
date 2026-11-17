// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SQPlayback/CaptionLayerPlan.swift
//! The caption layers of the visible caption tracks at one time, bottom first: per slot the caption before it while it hands
//! over (plain, then its lit words), the plain caption, then its lit word.
//! The plan, position and hand-over animation come in through [`CaptionPlanner`] (the app's is `CaptionPreview`).

use sq_core_audio::caption_handover::CaptionSlot;
use sq_core_model::{CaptionItem, GeneratorRef, KaraokeStyle, SequenceFormat, Timeline};
use sq_core_time::{Time, Vec2};

/// One caption layer of a Program frame: the text ref to draw, where its box sits, the clip time to animate it at and an
/// extra opacity (a caption handing over fades out under the next one).
#[derive(Clone, Debug, PartialEq)]
pub struct CaptionLayerRequest {
    pub reference: GeneratorRef,
    /// Box center relative to the canvas center (sequence px, y down).
    pub position: Vec2,
    pub local_time: Time,
    pub duration: Time,
    pub opacity: f64,
}

/// The plain caption and, with karaoke, the lit word.
#[derive(Clone, Debug, PartialEq)]
pub struct CaptionRefs {
    pub plain: GeneratorRef,
    pub lit: Option<GeneratorRef>,
}

/// What `CaptionPreview` / `CaptionHandover.draw` answer.
pub trait CaptionPlanner: Send + Sync {
    /// The planner that draws every caption as a Look hover `preview` says; `None` = this planner has no preview.
    fn previewed(&self, _preview: &super::look_preview::LookPreview) -> Option<std::sync::Arc<dyn CaptionPlanner>> {
        None
    }

    /// The text refs of `item` at `t`; `None` = nothing to draw.
    fn plan(
        &self,
        item: &CaptionItem,
        karaoke: Option<&KaraokeStyle>,
        canvas: &SequenceFormat,
        t: Time,
        held: bool,
        forward: bool,
    ) -> Option<CaptionRefs>;
    /// Box center of `item` relative to the canvas center.
    fn position(&self, item: &CaptionItem, canvas: &SequenceFormat) -> Vec2;
    /// The hand-over of `tail` under `item` at the item's natural clip time: the clip time to draw `item` at and the
    /// tail's opacity. `plain` is the entering caption's plain text ref (its animator units). `None`: nothing to hand over.
    fn hand_over(
        &self,
        tail: &CaptionItem,
        item: &CaptionItem,
        natural_clip_time: Time,
        frame_duration: Time,
        plain: &GeneratorRef,
    ) -> Option<(Time, f64)>;
}

pub fn layers(
    timeline: &Timeline,
    slots: &[CaptionSlot],
    at: Time,
    planner: &dyn CaptionPlanner,
    forward: bool,
) -> Vec<CaptionLayerRequest> {
    let canvas = timeline.format.layout_format();
    let mut out = Vec::new();
    for s in slots {
        let karaoke = timeline.caption_tracks.iter().find(|t| t.id == s.track).and_then(|t| t.karaoke.as_ref());
        let Some(plan) = planner.plan(&s.item, karaoke, &canvas, at, s.held, forward) else { continue };
        let mut local = at - s.item.range.start;
        if let Some(tail) = &s.tail
            && let Some((clip_time, tail_opacity)) =
                planner.hand_over(tail, &s.item, local, timeline.format.frame_duration, &plan.plain)
        {
            local = clip_time;
            if tail_opacity > 0.0
                && let Some(tp) = planner.plan(tail, karaoke, &canvas, at, true, forward)
            {
                let pos = planner.position(tail, &canvas);
                for r in std::iter::once(tp.plain).chain(tp.lit) {
                    out.push(CaptionLayerRequest {
                        reference: r,
                        position: pos,
                        local_time: s.tail_duration,
                        duration: s.tail_duration,
                        opacity: tail_opacity,
                    });
                }
            }
        }
        let pos = planner.position(&s.item, &canvas);
        for r in std::iter::once(plan.plain).chain(plan.lit) {
            out.push(CaptionLayerRequest {
                reference: r,
                position: pos,
                local_time: local,
                duration: s.duration,
                opacity: 1.0,
            });
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_audio::caption_handover::TimelineCaptionsExt;
    use sq_core_model::CaptionTrack;
    use sq_core_time::{Id, TimeRange};

    struct Fake;
    impl CaptionPlanner for Fake {
        fn plan(
            &self,
            item: &CaptionItem,
            karaoke: Option<&KaraokeStyle>,
            _: &SequenceFormat,
            _: Time,
            _: bool,
            _: bool,
        ) -> Option<CaptionRefs> {
            let r = |k: &str| GeneratorRef {
                kind: k.into(),
                payload: item.lines.join(" ").into_bytes(),
                payload_version: 1,
            };
            Some(CaptionRefs { plain: r("caption"), lit: karaoke.map(|_| r("caption-lit")) })
        }
        fn position(&self, _: &CaptionItem, _: &SequenceFormat) -> Vec2 {
            Vec2::new(0.0, 100.0)
        }
        fn hand_over(
            &self,
            _: &CaptionItem,
            _: &CaptionItem,
            t: Time,
            _: Time,
            _: &GeneratorRef,
        ) -> Option<(Time, f64)> {
            Some((t, 0.5))
        }
    }

    fn timeline(items: Vec<CaptionItem>, karaoke: Option<KaraokeStyle>) -> Timeline {
        let mut format = SequenceFormat::new(Time::new(1, 30));
        format.width = 1080;
        format.height = 1920;
        let mut tl = Timeline::new(Id::from_u128(1), "c", format, Vec::new());
        let track: CaptionTrack = serde_json::from_value(serde_json::json!({
            "id": Id::from_u128(2),
            "items": items,
            "karaoke": karaoke,
        }))
        .expect("caption track");
        tl.caption_tracks = vec![track];
        tl
    }

    fn item(start: i64) -> CaptionItem {
        CaptionItem {
            id: Id::from_u128(3),
            lines: vec!["so this works".into()],
            range: TimeRange::new(Time::new(start, 1), Time::new(2, 1)),
            style_ref: String::new(),
            animation_ref: String::new(),
            style_overridden: false,
            words: Vec::new(),
            position: None,
        }
    }

    #[test]
    fn plain_and_lit_word_at_the_captions_place() {
        let tl = timeline(vec![item(1)], Some(KaraokeStyle { red: 1.0, green: 1.0, blue: 0.0, keep_spoken: true }));
        let t = Time::new(3, 2);
        let l = layers(&tl, &tl.caption_slots_at(t), t, &Fake, true);
        assert_eq!(l.iter().map(|x| x.reference.kind.as_str()).collect::<Vec<_>>(), ["caption", "caption-lit"]);
        assert!(l.iter().all(|x| x.local_time == Time::new(1, 2) && x.opacity == 1.0));
        assert!(l.iter().all(|x| x.duration == Time::new(2, 1) && x.position == Vec2::new(0.0, 100.0)));
    }

    #[test]
    fn nothing_outside_captions_and_no_lit_layer_without_karaoke() {
        let tl = timeline(vec![item(1)], None);
        assert!(layers(&tl, &tl.caption_slots_at(Time::new(5, 1)), Time::new(5, 1), &Fake, true).is_empty());
        let one = layers(&tl, &tl.caption_slots_at(Time::new(3, 2)), Time::new(3, 2), &Fake, true);
        assert_eq!(one.len(), 1);
    }
}
