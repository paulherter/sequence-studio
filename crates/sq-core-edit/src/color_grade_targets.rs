// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ColorGradeTargets.swift

//! Color target bar (variant E step 1). Source-linked grades: a picture clip is "Linked" by default, i.e. its grade is the
//! grade of every clip of the same source file. The link itself is `Clip::grade_link` (denormalised copies, propagated
//! after each edit); the link forms on its own when a linked clip is edited (`prepare_source_grade_edit`, run in the same
//! undo step as the edit) and "Linked" can be switched off per clip (`Clip::grade_independent`).
//!
//! Who joins on an edit of clip X (not independent):
//! - X has no link but other clips of its source share one: X adopts that shared grade first when it has no grade of its
//!   own (or the same one); when X carries a different grade of its own it counts as independent (it is marked so) and the
//!   edit changes only X. An old project's separately graded clips are never overwritten this way.
//! - Every other unlinked, not independent clip of the source joins when it has no grade or the same grade as the shared
//!   one; one graded differently keeps its grade and is marked independent.
//! - Independent clips and clips in another link are never touched.
//!
//! The Timeline grade: one Adjustment Layer per sequence, marked by its generator payload (`SEQUENCE_GRADE_PAYLOAD`), on its
//! own new top video track over the whole sequence. Created on the first Timeline edit, reused (and stretched to the
//! sequence end) after.

use crate::timeline_add_track::AddTrackExt as _;
use sq_core_color::{ClipGradeExt as _, ClipGradeLinksExt as _, ProjectGradeLinksExt as _, comparable_grade};
use sq_core_effects::adjustment_clip::{ADJUSTMENT_KIND, ClipAdjustmentExt as _};
use sq_core_model::project_media_ops::GeneratorPlacement;
use sq_core_model::{Clip, ClipEffect, EditError, GeneratorRef, Project, Timeline, TrackKind};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use std::collections::BTreeSet;

/// Payload that marks an Adjustment Layer as the sequence's Timeline grade (the renderer ignores adjustment payloads).
pub const SEQUENCE_GRADE_PAYLOAD: &[u8] = b"sq.sequenceGrade";

/// `GeneratorRef.sequenceGrade`.
pub fn sequence_grade_generator() -> GeneratorRef {
    GeneratorRef { kind: ADJUSTMENT_KIND.to_string(), payload: SEQUENCE_GRADE_PAYLOAD.to_vec(), payload_version: 1 }
}

/// `extension Clip` of ColorGradeTargets.swift.
pub trait ClipGradeTargetsExt {
    /// The sequence's Timeline grade layer (see `ensure_sequence_grade`).
    fn is_sequence_grade(&self) -> bool;
}

impl ClipGradeTargetsExt for Clip {
    fn is_sequence_grade(&self) -> bool {
        self.is_adjustment() && self.generator.as_ref().is_some_and(|g| g.payload == SEQUENCE_GRADE_PAYLOAD)
    }
}

/// `extension Timeline` of ColorGradeTargets.swift.
pub trait TimelineGradeTargetsExt {
    /// The Timeline grade layer of this sequence, `None` before the first Timeline edit.
    fn sequence_grade_clip(&self) -> Option<&Clip>;
}

impl TimelineGradeTargetsExt for Timeline {
    fn sequence_grade_clip(&self) -> Option<&Clip> {
        self.tracks
            .iter()
            .filter(|t| t.kind == TrackKind::Video)
            .find_map(|t| t.clips().iter().find(|c| c.is_sequence_grade()))
    }
}

/// What an edit of a linked clip does to its source's other clips (see the file comment).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SourceGradePlan {
    /// A member of the source's shared grade that the clip adopts first (`None` = it is the source itself or linked).
    pub adopt_from: Option<Id>,
    /// The link the edit belongs to after the plan (`None` = a new one is made if anything joins).
    pub link: Option<Id>,
    /// Clips that join the link.
    pub joiners: Vec<Id>,
    /// Clips that keep their own grade and become independent.
    pub keep_own: Vec<Id>,
    /// The clip carries its own grade next to a different shared one: it is independent, nothing joins.
    pub self_independent: bool,
}

/// `extension Project` of ColorGradeTargets.swift.
pub trait ProjectGradeTargetsExt {
    /// What an edit of `id` does to its source's other clips.
    fn source_grade_plan(&self, id: Id) -> Option<SourceGradePlan>;
    /// The target bar's "Linked" state: true when edits of `id` go to its source's shared grade. False for clips that have
    /// no source (adjustment layers, generators, nested sequences, audio) and for independent ones.
    fn is_grade_linked_to_source(&self, id: Id) -> bool;
    /// How many clips an edit of `id` grades (itself included): 1 when it is not linked.
    fn source_grade_share_count(&self, id: Id) -> usize;
    /// Runs before a color edit of `id` (same undo step): forms the source link the edit goes to. True when something
    /// changed.
    fn prepare_source_grade_edit(&mut self, id: Id, ids: &mut dyn IdSource) -> bool;
    /// The target bar's "Linked" switch. Off: `id` leaves its link and keeps its grade; later edits change only it. On: it
    /// adopts the shared grade of its source again when one exists (else it is plain linked: the next edit links its
    /// source). False when nothing changed or `id` has no source.
    fn set_grade_linked_to_source(&mut self, id: Id, on: bool, ids: &mut dyn IdSource) -> bool;
    /// Any clip with "Linked" switched off: the file needs v47.
    fn contains_independent_grades(&self) -> bool;
    /// The Timeline grade layer of `timeline`: created on a new top video track over the whole sequence when it does not
    /// exist, else returned. An existing layer is kept on top (its track moves above video tracks added later, when it
    /// holds nothing else) and its end follows the sequence end when the sequence grew and its track is free there. Its
    /// start never moves, so clip-local keys and ranges stay where they are; nothing changes while coverage and order are
    /// already right. `TimelineNotFound`, or `EmptyClip` for a sequence without clips.
    fn ensure_sequence_grade(&mut self, timeline: Id, ids: &mut dyn IdSource) -> Result<Id, EditError>;
}

impl ProjectGradeTargetsExt for Project {
    fn source_grade_plan(&self, id: Id) -> Option<SourceGradePlan> {
        let x = self.any_clip(id).filter(|x| x.is_source_gradeable() && !x.grade_independent())?;
        let siblings: Vec<&Clip> = self
            .all_clips()
            .into_iter()
            .filter(|c| c.id != id && c.media == x.media && c.is_source_gradeable() && !c.grade_independent())
            .collect();
        let same = |a: &[ClipEffect], b: &[ClipEffect]| comparable_grade(a) == comparable_grade(b);
        let mut plan = SourceGradePlan { link: x.grade_link, ..SourceGradePlan::default() };
        let mut reference = x.base_grade_effects();
        if x.grade_link.is_none()
            && let Some(g) = siblings.iter().find(|c| c.grade_link.is_some())
        {
            if !(x.base_grade_effects().is_empty() || same(&x.base_grade_effects(), &g.base_grade_effects())) {
                plan.self_independent = true;
                return Some(plan);
            }
            plan.adopt_from = Some(g.id);
            plan.link = g.grade_link;
            reference = g.base_grade_effects();
        }
        for s in siblings.iter().filter(|s| s.grade_link.is_none()) {
            if s.base_grade_effects().is_empty() || same(&s.base_grade_effects(), &reference) {
                plan.joiners.push(s.id);
            } else {
                plan.keep_own.push(s.id);
            }
        }
        Some(plan)
    }

    fn is_grade_linked_to_source(&self, id: Id) -> bool {
        self.source_grade_plan(id).is_some_and(|p| !p.self_independent)
    }

    fn source_grade_share_count(&self, id: Id) -> usize {
        let Some(plan) = self.source_grade_plan(id).filter(|p| !p.self_independent) else { return 1 };
        let mut members: BTreeSet<Id> = plan.joiners.iter().copied().collect();
        members.insert(id);
        if let Some(l) = plan.link {
            members.extend(self.all_clips().into_iter().filter(|c| c.grade_link == Some(l)).map(|c| c.id));
        }
        members.len()
    }

    fn prepare_source_grade_edit(&mut self, id: Id, ids: &mut dyn IdSource) -> bool {
        let Some(plan) = self.source_grade_plan(id) else { return false };
        let mut changed = false;
        fn mark(p: &mut Project, set: &BTreeSet<Id>) -> bool {
            if set.is_empty() {
                return false;
            }
            p.for_each_clip_in_place(|c| {
                if set.contains(&c.id) {
                    c.set_grade_independent(true);
                    c.grade_link = None;
                }
            });
            true
        }
        if plan.self_independent {
            mark(self, &BTreeSet::from([id]));
            return true;
        }
        if let Some(g) = plan.adopt_from
            && self.link_grades(&BTreeSet::from([id]), g, ids).is_some()
        {
            changed = true;
        }
        changed |= mark(self, &plan.keep_own.iter().copied().collect());
        if !plan.joiners.is_empty() && self.link_grades(&plan.joiners.iter().copied().collect(), id, ids).is_some() {
            changed = true;
        }
        changed
    }

    fn set_grade_linked_to_source(&mut self, id: Id, on: bool, ids: &mut dyn IdSource) -> bool {
        let Some(x) = self.any_clip(id).filter(|x| x.is_source_gradeable()).cloned() else { return false };
        if !on {
            if x.grade_independent() && x.grade_link.is_none() {
                return false;
            }
            self.for_each_clip_in_place(|c| {
                if c.id == id {
                    c.set_grade_independent(true);
                    c.grade_link = None;
                }
            });
            self.dissolve_lonely_grade_links(); // a link left with one member is no link
            return true;
        }
        if !x.grade_independent() {
            return false;
        }
        self.for_each_clip_in_place(|c| {
            if c.id == id {
                c.set_grade_independent(false);
            }
        });
        // Adopt the source's shared grade: a linked sibling's, else (its link dissolved when this clip left) a graded one's.
        let siblings: Vec<Clip> = self
            .all_clips()
            .into_iter()
            .filter(|c| c.id != id && c.media == x.media && c.is_source_gradeable() && !c.grade_independent())
            .cloned()
            .collect();
        let source = siblings
            .iter()
            .find(|c| c.grade_link.is_some())
            .or_else(|| siblings.iter().find(|c| !c.base_grade_effects().is_empty()))
            .map(|c| c.id);
        if let Some(g) = source {
            self.link_grades(&BTreeSet::from([id]), g, ids);
        }
        true
    }

    fn contains_independent_grades(&self) -> bool {
        self.all_clips().into_iter().any(|c| c.grade_independent())
    }

    fn ensure_sequence_grade(&mut self, timeline: Id, ids: &mut dyn IdSource) -> Result<Id, EditError> {
        let ti = self.timelines.iter().position(|t| t.id == timeline).ok_or(EditError::TimelineNotFound)?;
        let t = &self.timelines[ti];
        let end = t
            .tracks
            .iter()
            .flat_map(|tr| tr.clips().iter())
            .filter(|c| !c.is_sequence_grade())
            .map(|c| c.timeline().end())
            .max()
            .unwrap_or(Time::ZERO);
        if let Some(g) = t.sequence_grade_clip().cloned()
            && let Some(mut tr) = t.tracks.iter().position(|tr| tr.clip(g.id).is_some())
        {
            let tracks = &mut self.timelines[ti].tracks;
            // Keep it the topmost video track.
            if let Some(last_video) = tracks.iter().rposition(|x| x.kind == TrackKind::Video)
                && last_video > tr
                && tracks[tr].clips().len() == 1
                && !tracks[tr].is_locked
            {
                let track = tracks.remove(tr);
                tracks.insert(last_video, track);
                tr = last_video;
            }
            let track = &tracks[tr];
            if !(g.timeline().end() < end)
                || track.is_locked
                || track
                    .clips()
                    .iter()
                    .any(|c| c.id != g.id && c.timeline().start < end && c.timeline().end() > g.timeline().end())
            {
                return Ok(g.id);
            }
            let mut c = g.clone();
            c.source = TimeRange::new(g.source.start, end - g.start);
            tracks[tr].replace(c);
            return Ok(g.id);
        }
        if end <= Time::ZERO {
            return Err(EditError::EmptyClip);
        }
        let track = self.timelines[ti].add_track(TrackKind::Video, ids);
        self.add_generator_clip(
            sequence_grade_generator(),
            Some("Timeline Grade"),
            GeneratorPlacement { timeline, track, start: Time::ZERO, duration: end },
            ids,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_color::*;
    use sq_core_model::{ColorEffect, SequenceFormat, Track};
    use sq_core_time::SequentialIds;

    fn clip(ids: &mut SequentialIds, start: i64, media: Id) -> Clip {
        let source = TimeRange::new(Time::ZERO, Time::new(4, 1));
        let mut c = Clip::new(ids.next_id(), "c", media, TrackKind::Video, source, Time::new(start, 1));
        c.media_duration = Some(Time::new(20, 1));
        c
    }

    fn graded(ids: &mut SequentialIds, start: i64, media: Id, temperature: f32) -> Clip {
        let mut c = clip(ids, start, media);
        let mut e = ColorEffect::new(1, None);
        e.basic.temperature = temperature;
        c.effects = vec![ClipEffect::color_grade(ids.next_id(), &e, ids)];
        c
    }

    fn project(clips: Vec<Clip>, ids: &mut SequentialIds) -> Project {
        let mut track = Track::new(ids.next_id(), TrackKind::Video);
        track.set_clips(clips);
        let tl = Timeline::new(ids.next_id(), "T", SequenceFormat::new(Time::new(1, 25)), vec![track]);
        Project::new(ids.next_id(), "P", Vec::new(), vec![tl])
    }

    fn find(p: &Project, id: Id) -> Clip {
        p.any_clip(id).cloned().unwrap_or_else(|| panic!("clip"))
    }

    fn temperature(c: &Clip) -> f32 {
        c.color().effects().first().map_or(0.0, |e| e.basic.temperature)
    }

    /// One panel edit on `id`, then the session's propagation step.
    fn edit(p: &mut Project, id: Id, t: f32, ids: &mut SequentialIds) {
        let old = p.clone();
        p.for_each_clip_in_place(|c| {
            if c.id != id {
                return;
            }
            if c.effects.is_empty() {
                let mut fresh = SequentialIds::default();
                c.effects = vec![ClipEffect::color_grade(Id::from_u128(9_000), &ColorEffect::new(1, None), &mut fresh)];
            }
            let mut e = c.effects[0].color_effect(None, 1);
            e.basic.temperature = t;
            c.effects[0].set_color_effect(&e, None, &mut SequentialIds::default());
        });
        p.propagate_grade_links(&old, ids);
    }

    #[test]
    fn an_ungraded_clip_is_linked_to_its_source_by_default() {
        let mut ids = SequentialIds::default();
        let m = ids.next_id();
        let (a, b) = (clip(&mut ids, 0, m), clip(&mut ids, 4, m));
        let (aid, p) = (a.id, project(vec![a, b], &mut ids));
        assert!(p.is_grade_linked_to_source(aid));
        assert_eq!(p.source_grade_share_count(aid), 2);
    }

    #[test]
    fn a_clip_with_its_own_different_grade_next_to_a_link_group_shows_unlinked() {
        let mut ids = SequentialIds::default();
        let m = ids.next_id();
        let (a, b, c) = (graded(&mut ids, 0, m, 10.0), clip(&mut ids, 4, m), graded(&mut ids, 8, m, 40.0));
        let (aid, bid, cid) = (a.id, b.id, c.id);
        let mut p = project(vec![a, b, c], &mut ids);
        assert!(p.link_grades(&[aid, bid].into(), aid, &mut ids).is_some());
        assert!(p.is_grade_linked_to_source(aid) && p.is_grade_linked_to_source(bid));
        assert!(!p.is_grade_linked_to_source(cid));
        assert_eq!(p.source_grade_share_count(aid), 2);
    }

    #[test]
    fn editing_a_linked_clip_grades_every_ungraded_clip_of_the_source() {
        let mut ids = SequentialIds::default();
        let m = ids.next_id();
        let (a, b, other) = (clip(&mut ids, 0, m), clip(&mut ids, 4, m), clip(&mut ids, 8, Id::from_u128(777)));
        let (aid, bid, oid) = (a.id, b.id, other.id);
        let mut p = project(vec![a, b, other], &mut ids);
        assert!(p.prepare_source_grade_edit(aid, &mut ids));
        edit(&mut p, aid, 25.0, &mut ids);
        assert_eq!(temperature(&find(&p, bid)), 25.0);
        assert!(find(&p, aid).grade_link.is_some() && find(&p, aid).grade_link == find(&p, bid).grade_link);
        assert_eq!(temperature(&find(&p, oid)), 0.0);
    }

    #[test]
    fn siblings_graded_on_their_own_keep_their_grade_and_become_independent() {
        let mut ids = SequentialIds::default();
        let m = ids.next_id();
        let (a, b) = (clip(&mut ids, 0, m), graded(&mut ids, 4, m, 40.0));
        let (aid, bid) = (a.id, b.id);
        let mut p = project(vec![a, b], &mut ids);
        assert!(p.prepare_source_grade_edit(aid, &mut ids));
        edit(&mut p, aid, 10.0, &mut ids);
        assert_eq!(temperature(&find(&p, bid)), 40.0);
        assert!(find(&p, bid).grade_independent() && find(&p, bid).grade_link.is_none());
    }

    #[test]
    fn a_graded_lone_clip_next_to_a_different_group_edits_only_itself() {
        let mut ids = SequentialIds::default();
        let m = ids.next_id();
        let (a, b, c) = (graded(&mut ids, 0, m, 10.0), clip(&mut ids, 4, m), graded(&mut ids, 8, m, 40.0));
        let (aid, bid, cid) = (a.id, b.id, c.id);
        let mut p = project(vec![a, b, c], &mut ids);
        p.link_grades(&[aid, bid].into(), aid, &mut ids);
        assert!(p.prepare_source_grade_edit(cid, &mut ids));
        assert!(find(&p, cid).grade_independent());
        edit(&mut p, cid, 45.0, &mut ids);
        assert!(temperature(&find(&p, aid)) == 10.0 && temperature(&find(&p, bid)) == 10.0);
    }

    #[test]
    fn prepare_is_a_no_op_when_everything_is_already_linked() {
        let mut ids = SequentialIds::default();
        let m = ids.next_id();
        let (a, b) = (clip(&mut ids, 0, m), clip(&mut ids, 4, m));
        let (aid, bid) = (a.id, b.id);
        let mut p = project(vec![a, b], &mut ids);
        p.link_grades(&[aid, bid].into(), aid, &mut ids);
        assert!(!p.prepare_source_grade_edit(aid, &mut ids));
    }

    #[test]
    fn switching_linked_off_changes_only_that_clip_from_then_on() {
        let mut ids = SequentialIds::default();
        let m = ids.next_id();
        let (a, b) = (graded(&mut ids, 0, m, 20.0), clip(&mut ids, 4, m));
        let (aid, bid) = (a.id, b.id);
        let mut p = project(vec![a, b], &mut ids);
        p.link_grades(&[aid, bid].into(), aid, &mut ids);
        assert!(p.set_grade_linked_to_source(bid, false, &mut ids));
        assert!(!p.set_grade_linked_to_source(bid, false, &mut ids)); // already off
        assert!(!p.is_grade_linked_to_source(bid));
        assert_eq!(temperature(&find(&p, bid)), 20.0);
        assert!(!p.prepare_source_grade_edit(bid, &mut ids));
        edit(&mut p, bid, 50.0, &mut ids);
        assert_eq!(temperature(&find(&p, aid)), 20.0);
        assert!(!p.prepare_source_grade_edit(aid, &mut ids));
        edit(&mut p, aid, 5.0, &mut ids);
        assert_eq!(temperature(&find(&p, bid)), 50.0);
    }

    #[test]
    fn switching_linked_on_again_adopts_the_group_grade() {
        let mut ids = SequentialIds::default();
        let m = ids.next_id();
        let (a, b, c) = (graded(&mut ids, 0, m, 20.0), clip(&mut ids, 4, m), clip(&mut ids, 8, m));
        let (aid, bid, cid) = (a.id, b.id, c.id);
        let mut p = project(vec![a, b, c], &mut ids);
        p.link_grades(&[aid, bid, cid].into(), aid, &mut ids);
        assert!(p.set_grade_linked_to_source(cid, false, &mut ids));
        edit(&mut p, cid, 70.0, &mut ids);
        assert!(p.set_grade_linked_to_source(cid, true, &mut ids));
        assert!(!p.set_grade_linked_to_source(cid, true, &mut ids));
        assert_eq!(temperature(&find(&p, cid)), 20.0);
        assert_eq!(find(&p, cid).grade_link, find(&p, aid).grade_link);
        assert!(!find(&p, cid).grade_independent());
    }

    #[test]
    fn ensure_sequence_grade_creates_one_top_layer_and_reuses_it() {
        let mut ids = SequentialIds::default();
        let m = ids.next_id();
        let a = clip(&mut ids, 0, m);
        let mut p = project(vec![a], &mut ids);
        let tl = p.timelines[0].id;
        let g = p.ensure_sequence_grade(tl, &mut ids).unwrap();
        let t = &p.timelines[0];
        assert_eq!(t.tracks.len(), 2);
        assert_eq!(t.sequence_grade_clip().map(|c| c.id), Some(g));
        assert_eq!(t.sequence_grade_clip().map(|c| c.timeline()), Some(TimeRange::new(Time::ZERO, Time::new(4, 1))));
        assert_eq!(p.ensure_sequence_grade(tl, &mut ids), Ok(g));
        assert_eq!(p.timelines[0].tracks.len(), 2);
    }

    #[test]
    fn ensure_sequence_grade_refuses_an_empty_sequence() {
        let mut ids = SequentialIds::default();
        let mut p = project(vec![], &mut ids);
        let tl = p.timelines[0].id;
        assert_eq!(p.ensure_sequence_grade(tl, &mut ids), Err(EditError::EmptyClip));
        assert_eq!(p.ensure_sequence_grade(Id::from_u128(9), &mut ids), Err(EditError::TimelineNotFound));
    }
}
