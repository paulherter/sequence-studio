// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MagicMatteNeeds.swift
//! Which tracked Magic mattes a render reads: per exported frame (the export warning counts frames without one, nested
//! sequences included) and per project (the matte cache keeps what the project refers to and drops orphans).

use crate::anonymize::MagicSelectionAnonymizeExt;
use crate::mask_inputs::MaskInputsExt;
use crate::masks::ClipMasksExt;
use sq_core_model::{Clip, MaskSource, Project, Timeline, TrackKind};
use sq_core_time::{Id, Time};
use std::collections::{BTreeMap, BTreeSet};

/// Nesting deeper than this is not followed (guards against a cycle).
pub const MAGIC_NEEDS_MAX_DEPTH: usize = 8;

/// One Magic matte a frame needs: the mask's matte cache key and the source time (s) of the frame it is drawn on.
#[derive(Clone, Debug, PartialEq)]
pub struct MagicMatteNeed {
    /// Matte cache key.
    pub key: String,
    /// Source seconds of the frame.
    pub pts: f64,
}

/// The view of a nested sequence a clip shows (Swift `Clip.angleView(of:)`, which lives in the edit crate).
pub type AngleView<'a> = &'a dyn Fn(&Clip, &Timeline) -> Timeline;

/// Logic Swift keeps on `Clip` in `MagicMatteNeeds.swift`.
pub trait MagicMatteClipExt {
    /// Cache keys of the Magic masks a render draws: enabled, picked, and cutting the picture or feeding an effect.
    fn rendered_magic_keys(&self) -> Vec<String>;
}

impl MagicMatteClipExt for Clip {
    fn rendered_magic_keys(&self) -> Vec<String> {
        let inputs: BTreeSet<Id> = self
            .effects
            .iter()
            .filter(|e| self.takes_mask_input(e))
            .flat_map(|e| e.mask_input.iter().copied())
            .collect();
        self.masks()
            .iter()
            .filter(|m| {
                m.enabled
                    && m.source() == MaskSource::Magic
                    && !m.magic.as_ref().is_none_or(|s| s.points.is_empty())
                    && (m.used_by_opacity() || inputs.contains(&m.id))
            })
            .filter_map(|m| m.magic.as_ref().map(|s| s.matte_key(self.media)))
            .collect()
    }
}

fn seconds(t: Time) -> f64 {
    t.value() as f64 / t.timescale().max(1) as f64
}

/// Logic Swift keeps on `Timeline` in `MagicMatteNeeds.swift`.
pub trait MagicMatteTimelineExt {
    /// One entry per frame a render draws with a Magic mask: every frame of a clip that has one, and every frame of a
    /// nested clip whose inner sequence shows one at that frame (recursively). Each entry lists the mattes that frame
    /// reads. `sequences`: the nested sequences by id.
    fn magic_matte_needs(&self, sequences: &BTreeMap<Id, Timeline>, angle_view: AngleView) -> Vec<Vec<MagicMatteNeed>>;
    /// The mattes needed at this timeline's time `t`: every video clip covering `t`, nested clips followed.
    #[doc(hidden)]
    fn magic_matte_needs_at(
        &self,
        t: Time,
        sequences: &BTreeMap<Id, Timeline>,
        depth: usize,
        angle_view: AngleView,
    ) -> Vec<MagicMatteNeed>;
    /// Some clip here (or in a sequence nested here) draws a Magic mask.
    #[doc(hidden)]
    fn shows_magic(&self, sequences: &BTreeMap<Id, Timeline>, depth: usize, angle_view: AngleView) -> bool;
}

fn needs_at_depth(
    tl: &Timeline,
    sequences: &BTreeMap<Id, Timeline>,
    depth: usize,
    angle_view: AngleView,
) -> Vec<Vec<MagicMatteNeed>> {
    let frame_duration = tl.format.frame_duration;
    let mut out: Vec<Vec<MagicMatteNeed>> = Vec::new();
    for track in tl.tracks.iter().filter(|t| t.kind == TrackKind::Video) {
        for c in track.clips() {
            if let Some(id) = c.sequence {
                let inner =
                    if depth < MAGIC_NEEDS_MAX_DEPTH { sequences.get(&id).map(|s| angle_view(c, s)) } else { None };
                let Some(inner) = inner else { continue };
                if !inner.shows_magic(sequences, depth + 1, angle_view) {
                    continue;
                }
                let mut t = Time::ZERO;
                while t < c.duration() {
                    let it = c.inner_time(t, inner.format.frame_duration);
                    let n = inner.magic_matte_needs_at(it, sequences, depth + 1, angle_view);
                    if !n.is_empty() {
                        out.push(n);
                    }
                    t += frame_duration;
                }
                continue;
            }
            let keys = c.rendered_magic_keys();
            if keys.is_empty() {
                continue;
            }
            let mut t = Time::ZERO;
            while t < c.duration() {
                let pts = seconds(c.shown_source_time(t, frame_duration));
                out.push(keys.iter().map(|k| MagicMatteNeed { key: k.clone(), pts }).collect());
                t += frame_duration;
            }
        }
    }
    out
}

impl MagicMatteTimelineExt for Timeline {
    fn magic_matte_needs(&self, sequences: &BTreeMap<Id, Timeline>, angle_view: AngleView) -> Vec<Vec<MagicMatteNeed>> {
        needs_at_depth(self, sequences, 0, angle_view)
    }

    fn magic_matte_needs_at(
        &self,
        t: Time,
        sequences: &BTreeMap<Id, Timeline>,
        depth: usize,
        angle_view: AngleView,
    ) -> Vec<MagicMatteNeed> {
        let frame_duration = self.format.frame_duration;
        let mut out = Vec::new();
        for track in self.tracks.iter().filter(|t| t.kind == TrackKind::Video) {
            for c in track.clips().iter().filter(|c| c.start <= t && t < c.start + c.duration()) {
                let local = t - c.start;
                if let Some(id) = c.sequence {
                    let inner =
                        if depth < MAGIC_NEEDS_MAX_DEPTH { sequences.get(&id).map(|s| angle_view(c, s)) } else { None };
                    let Some(inner) = inner else { continue };
                    out.extend(inner.magic_matte_needs_at(
                        c.inner_time(local, inner.format.frame_duration),
                        sequences,
                        depth + 1,
                        angle_view,
                    ));
                    continue;
                }
                let keys = c.rendered_magic_keys();
                if keys.is_empty() {
                    continue;
                }
                let pts = seconds(c.shown_source_time(local, frame_duration));
                out.extend(keys.iter().map(|k| MagicMatteNeed { key: k.clone(), pts }));
            }
        }
        out
    }

    fn shows_magic(&self, sequences: &BTreeMap<Id, Timeline>, depth: usize, angle_view: AngleView) -> bool {
        self.tracks.iter().any(|track| {
            track.kind == TrackKind::Video
                && track.clips().iter().any(|c| {
                    if let Some(id) = c.sequence {
                        return depth < MAGIC_NEEDS_MAX_DEPTH
                            && sequences
                                .get(&id)
                                .map(|s| angle_view(c, s))
                                .is_some_and(|inner| inner.shows_magic(sequences, depth + 1, angle_view));
                    }
                    !c.rendered_magic_keys().is_empty()
                })
        })
    }
}

/// Logic Swift keeps on `Project` in `MagicMatteNeeds.swift`.
pub trait MagicMatteProjectExt {
    /// Matte cache keys of every picked Magic mask in the project (enabled or not: the matte is kept while the pick
    /// exists). A Face / Skin mask made by Anonymize needs two: the followed person and the narrowed matte. What is not
    /// listed is removed when the project closes saved, which is also how the mattes of a deleted mask go.
    fn magic_matte_cache_keys(&self) -> BTreeSet<String>;
}

impl MagicMatteProjectExt for Project {
    fn magic_matte_cache_keys(&self) -> BTreeSet<String> {
        let mut out = BTreeSet::new();
        for tl in &self.timelines {
            for track in &tl.tracks {
                for c in track.clips() {
                    for m in c.masks().iter().filter(|m| m.source() == MaskSource::Magic) {
                        if let Some(sel) = &m.magic
                            && !sel.points.is_empty()
                        {
                            out.extend(sel.matte_keys(c.media));
                        }
                    }
                }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::magic_mask::MagicSelectionExt;
    use sq_core_time::IdSource;

    use sq_core_model::{ClipMask, MagicPoint, SequenceFormat};
    use sq_core_time::{SequentialIds, TimeRange, Vec2};

    fn fd() -> Time {
        Time::new(1, 25)
    }

    fn magic_clip(n: u128, start: Time, source_start: Time, seconds: i64) -> Clip {
        let mut ids = SequentialIds::default();
        let mut c = Clip::new(
            Id::from_u128(0x1000 + n),
            "c",
            Id::from_u128(0x2000 + n),
            TrackKind::Video,
            TimeRange::new(source_start, Time::new(seconds, 1)),
            start,
        );
        let p = MagicPoint { position: Vec2::new(0.5, 0.5), subtract: false, source_time: source_start };
        c.set_masks(vec![ClipMask::make_magic(ids.next_id(), "Mask (1)", vec![p])]);
        c
    }

    fn timeline(id: u128, clips: Vec<Clip>) -> Timeline {
        let mut ids = SequentialIds::default();
        let mut track = sq_core_model::Track::new(Id::from_u128(0x3000 + id), TrackKind::Video);
        for c in clips {
            assert!(track.overwrite(c, &mut ids).is_ok());
        }
        Timeline::new(Id::from_u128(id), "t", SequenceFormat::new(fd()), vec![track])
    }

    fn plain_view(_: &Clip, inner: &Timeline) -> Timeline {
        inner.clone()
    }

    #[test]
    fn direct_clip_needs_one_matte_per_frame() {
        let c = magic_clip(1, Time::ZERO, Time::new(2, 1), 1);
        let needs = timeline(1, vec![c.clone()]).magic_matte_needs(&BTreeMap::new(), &plain_view);
        assert_eq!(needs.len(), 25);
        let key = c.masks()[0].magic.as_ref().map(|s| s.matte_key(c.media)).unwrap_or_default();
        assert_eq!(needs[0], vec![MagicMatteNeed { key, pts: 2.0 }]);
        assert!((needs[24][0].pts - (2.0 + 24.0 / 25.0)).abs() < 1e-9);
    }

    #[test]
    fn unused_or_disabled_magic_masks_are_not_needed() {
        let mut c = magic_clip(1, Time::ZERO, Time::new(2, 1), 1);
        let mut masks = c.masks().to_vec();
        masks[0].set_used_by_opacity(false);
        c.set_masks(masks.clone());
        assert!(timeline(1, vec![c.clone()]).magic_matte_needs(&BTreeMap::new(), &plain_view).is_empty());
        masks[0].set_used_by_opacity(true);
        masks[0].enabled = false;
        c.set_masks(masks);
        assert!(timeline(1, vec![c]).magic_matte_needs(&BTreeMap::new(), &plain_view).is_empty());
    }

    #[test]
    fn nested_sequence_frames_count_their_inner_magic_mattes() {
        let inner = magic_clip(1, Time::new(1, 1), Time::new(2, 1), 1); // inner 1 s ... 2 s
        let inner_tl = timeline(9, vec![inner.clone()]);
        // The outer clip plays inner 0.5 s ... 2.5 s: only its frames over inner 1 s ... 2 s need a matte.
        let mut nest = Clip::new(
            Id::from_u128(0x77),
            "n",
            inner_tl.id,
            TrackKind::Video,
            TimeRange::new(Time::new(1, 2), Time::new(2, 1)),
            Time::ZERO,
        );
        nest.sequence = Some(inner_tl.id);
        let outer = timeline(10, vec![nest]);
        let mut seqs = BTreeMap::new();
        seqs.insert(inner_tl.id, inner_tl);
        let needs = outer.magic_matte_needs(&seqs, &plain_view);
        assert_eq!(needs.len(), 25);
        let key = inner.masks()[0].magic.as_ref().map(|s| s.matte_key(inner.media)).unwrap_or_default();
        assert!(needs.iter().all(|n| n.len() == 1 && n[0].key == key));
        assert!((needs[0][0].pts - 2.02).abs() < 1e-9); // outer frame 13 = inner 1.02 s
        assert!(outer.magic_matte_needs(&BTreeMap::new(), &plain_view).is_empty());
    }

    #[test]
    fn project_lists_every_picked_matte_key() {
        let a = magic_clip(1, Time::ZERO, Time::new(2, 1), 1);
        let mut b = magic_clip(2, Time::new(5, 1), Time::new(2, 1), 1);
        let mut ids = SequentialIds::default();
        let mut masks = b.masks().to_vec();
        masks.push(ClipMask::make_magic(ids.next_id(), "Mask (2)", vec![])); // not picked yet: no key
        b.set_masks(masks);
        let p = Project::new(Id::from_u128(1), "P", vec![], vec![timeline(1, vec![a.clone(), b.clone()])]);
        let key = |c: &Clip| c.masks()[0].magic.as_ref().map(|s| s.cache_key(c.media)).unwrap_or_default();
        assert_eq!(p.magic_matte_cache_keys(), BTreeSet::from([key(&a), key(&b)]));
    }
}
