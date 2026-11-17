// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline+JoinCuts.swift
//
// Join Cuts (our name; Premiere calls it Join Through Edits): a through edit is the leftover of a blade. Two clips that sit
// edge to edge, play contiguous parts of the same source and are identical in every other property, so the cut changes
// nothing in picture or sound. Joining puts them back into one clip.
//
// The test for "identical" is exact and cheap: build the joined clip, crop it back to both halves with `cropped` (the very
// function a blade uses) and compare with the originals. Speed, effects, keyframes, levels, labels, markers, anything
// stored: if one differs, the cut is a real edit and stays.

use crate::timeline_solo::SoloExt;
use sq_core_model::{Clip, EditError, Timeline, Track};
use sq_core_time::{Id, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

/// A through edit: the clip before the cut and the clip after it, on one track.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ThroughEdit {
    /// The clip before the cut.
    pub left: Id,
    /// The clip after the cut.
    pub right: Id,
}

/// The clip `clip` would become when it absorbs `next`, `None` when the cut between them is a real edit.
pub fn joined(clip: &Clip, next: &Clip) -> Option<Clip> {
    if clip.kind != next.kind
        || clip.media != next.media
        || clip.sequence != next.sequence
        || clip.is_generator()
        || next.is_generator()
        || clip.is_still
        || next.is_still
        || clip.hold_frame.is_some()
        || next.hold_frame.is_some()
        || clip.speed_keys.is_some()
        || next.speed_keys.is_some()
        || clip.reversed != next.reversed
        || clip.start + clip.duration() != next.start
    {
        return None;
    }
    let range = if clip.reversed {
        if next.source.end() != clip.source.start {
            return None;
        }
        TimeRange::from_end(next.source.start, clip.source.end())
    } else {
        if clip.source.end() != next.source.start {
            return None;
        }
        TimeRange::from_end(clip.source.start, next.source.end())
    };
    let mut merged = clip.clone();
    merged.source = range;
    let l = merged.cropped(clip.timeline())?;
    let r = merged.cropped(next.timeline())?;
    let same = |a: &Clip, b: &Clip| {
        let mut x = a.clone();
        let mut y = b.clone();
        x.id = b.id;
        x.link = b.link;
        x.attachment = b.attachment.clone(); // Fast Cut: re-derived per half, rejoined clip keeps the left one
        y.id = b.id;
        x == y
    };
    if same(&l, clip) && same(&r, next) { Some(merged) } else { None }
}

/// Join Cuts.
pub trait TimelineJoinCutsExt {
    /// Every through edit on unlocked tracks (all of them, or only those at a cut where `selection` holds the clip before or
    /// after it, or a linked partner of one), left to right per track. A linked pair counts as one cut per track: a video
    /// cut whose audio partner cut is a real edit is not listed.
    fn through_edits(&self, selection: Option<&BTreeSet<Id>>) -> Vec<ThroughEdit>;

    /// Joins the through edits (see `through_edits`) until none is left in scope and returns how many cuts went. The joined
    /// clip keeps the left clip's id, link and place; the right clip's id disappears and a transition that started at its
    /// tail now starts at the joined clip's tail. Transitions on the cut itself keep the cut. 0 = nothing changed.
    fn join_through_edits(&mut self, selection: Option<&BTreeSet<Id>>) -> Result<usize, EditError>;
}

/// True when a transition touches the cut between `a` and `b`: on the cut, at the tail of `a` or at the head of `b`.
/// Joining through it would change what it is attached to, so those cuts stay.
fn has_transition(t: &Track, a: &Clip, b: &Clip) -> bool {
    t.transitions.iter().any(|tr| tr.outgoing == Some(a.id) || tr.incoming == Some(b.id))
}

impl TimelineJoinCutsExt for Timeline {
    fn through_edits(&self, selection: Option<&BTreeSet<Id>>) -> Vec<ThroughEdit> {
        let all: Vec<&Clip> = self.tracks.iter().flat_map(|t| t.clips()).collect();
        let scope: Option<BTreeSet<Id>> = selection.map(|sel| {
            let mut s = sel.clone();
            s.extend(self.held_back_partners(sel));
            s
        });
        let mut candidates: Vec<ThroughEdit> = Vec::new();
        for t in self.tracks.iter().filter(|t| !t.is_locked) {
            for w in t.clips().windows(2) {
                let (a, b) = (&w[0], &w[1]);
                if let Some(scope) = &scope
                    && !scope.contains(&a.id)
                    && !scope.contains(&b.id)
                {
                    continue;
                }
                if joined(a, b).is_none() || has_transition(t, a, b) {
                    continue;
                }
                candidates.push(ThroughEdit { left: a.id, right: b.id });
            }
        }
        let right_of: BTreeMap<Id, Id> = candidates.iter().map(|c| (c.left, c.right)).collect();
        let mut by_id: BTreeMap<Id, &Clip> = BTreeMap::new();
        for c in &all {
            by_id.entry(c.id).or_insert(c);
        }
        candidates
            .into_iter()
            .filter(|e| {
                let (Some(a), Some(b)) = (by_id.get(&e.left), by_id.get(&e.right)) else { return false };
                let partners = |c: &Clip| -> Vec<Id> {
                    c.link.map_or_else(Vec::new, |l| {
                        all.iter().filter(|o| o.link == Some(l) && o.id != c.id).map(|o| o.id).collect()
                    })
                };
                let (pa, pb) = (partners(a), partners(b));
                if pa.is_empty() && pb.is_empty() {
                    return true;
                }
                if a.link == b.link {
                    return false;
                }
                // Every partner of the left clip must join the matching partner of the right clip.
                let mapped: BTreeSet<Id> = pa.iter().filter_map(|p| right_of.get(p).copied()).collect();
                let wanted: BTreeSet<Id> = pb.iter().copied().collect();
                mapped == wanted && pa.iter().all(|p| right_of.contains_key(p))
            })
            .collect()
    }

    fn join_through_edits(&mut self, selection: Option<&BTreeSet<Id>>) -> Result<usize, EditError> {
        let mut count = 0;
        loop {
            let pass = self.through_edits(selection);
            let mut used: BTreeSet<Id> = BTreeSet::new();
            let mut progressed = false;
            for e in &pass {
                if used.contains(&e.left) || used.contains(&e.right) {
                    continue;
                }
                let (Some(l), Some(r)) = (self.find(e.left), self.find(e.right)) else { continue };
                if l.track != r.track {
                    continue;
                }
                let Some(merged) = joined(&l.clip, &r.clip) else { continue };
                let track = &mut self.tracks[l.track];
                track.remove(r.clip.id);
                track.replace(merged.clone());
                for tr in &mut track.transitions {
                    if tr.outgoing == Some(r.clip.id) {
                        tr.outgoing = Some(merged.id);
                    }
                }
                used.insert(e.left);
                used.insert(e.right);
                count += 1;
                progressed = true;
            }
            if !progressed {
                return Ok(count);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::*;
    use crate::timeline_three_point::TimelineThreePointExt as _;
    use sq_core_model::TrackKind::Video;
    use sq_core_time::{IdSource as _, SequentialIds};

    fn blade(tl: &mut Timeline, t: i64) {
        // ids far from the fixtures' and from each other's, so every blade mints new ones
        thread_local!(static NEXT: std::cell::Cell<u128> = const { std::cell::Cell::new(100) });
        let mut ids = SequentialIds::default();
        for _ in 0..NEXT.with(|c| c.replace(c.get() + 10)) {
            ids.next_id();
        }
        assert!(tl.add_edit(s(t), None, &mut ids).is_ok());
    }

    #[test]
    fn a_blade_leaves_a_through_edit_and_joining_restores_the_clip() {
        let x = clip(0, 10, 0, Video, None, Some(20));
        let mut tl = timeline(vec![track(Video, vec![x.clone()])]);
        blade(&mut tl, 4);
        assert_eq!(tl.tracks[0].clips().len(), 2);
        assert_eq!(tl.through_edits(None).len(), 1);
        assert_eq!(tl.join_through_edits(None), Ok(1));
        let c = &tl.tracks[0].clips()[0];
        assert_eq!((tl.tracks[0].clips().len(), c.id, c.timeline()), (1, x.id, x.timeline()));
        assert_eq!(c.source, x.source);
        assert!(tl.through_edits(None).is_empty());
    }

    #[test]
    fn a_real_edit_stays() {
        let (p, q) = (clip(0, 4, 0, Video, None, Some(20)), clip(4, 4, 9, Video, None, Some(20)));
        let tl = timeline(vec![track(Video, vec![p, q])]);
        assert!(tl.through_edits(None).is_empty());
    }

    #[test]
    fn three_blades_join_in_passes_and_the_selection_limits_the_scope() {
        let x = clip(0, 12, 0, Video, None, Some(20));
        let mut tl = timeline(vec![track(Video, vec![x.clone()])]);
        for t in [3, 6, 9] {
            blade(&mut tl, t);
        }
        let second = tl.tracks[0].clips()[1].id;
        let scope = BTreeSet::from([second]);
        assert_eq!(tl.through_edits(Some(&scope)).len(), 2); // the cuts on both sides of the second clip
        assert_eq!(tl.join_through_edits(None), Ok(3));
        assert_eq!(tl.tracks[0].clips().len(), 1);
    }

    #[test]
    fn a_linked_pair_joins_only_when_both_cuts_are_through_edits() {
        let l = link();
        let vc = clip(0, 10, 0, Video, Some(l), Some(20));
        let au = clip(0, 10, 0, sq_core_model::TrackKind::Audio, Some(l), Some(20));
        let mut tl = timeline(vec![track(Video, vec![vc]), track(sq_core_model::TrackKind::Audio, vec![au])]);
        blade(&mut tl, 5);
        assert_eq!(tl.through_edits(None).len(), 2);
        // make the audio cut a real edit: the video cut alone must stay too
        let right_audio = tl.tracks[1].clips()[1].clone();
        let mut changed = right_audio;
        changed.audio_gain_db = 3.0;
        tl.tracks[1].replace(changed);
        assert!(tl.through_edits(None).is_empty());
    }
}
