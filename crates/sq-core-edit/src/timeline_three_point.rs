// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline+ThreePoint.swift (lift by id, add edit, mark clip, Q/W, extend edit)
//
// `overwrite` and `three_point_edit` of that file live in sq-core-model (`timeline/three_point.rs`); they take a
// `SourcePlacement` and leave the Fast Cut branch (`fastCutSourceEdit`) to the caller.

use sq_core_model::{ClipEdge, EditError, Timeline};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use std::collections::BTreeMap;

use crate::timeline_edits::{RollCut, TimelineEditsExt};

/// Edit helpers for cutting: lift by id, add edit, Q/W, extend edit.
pub trait TimelineThreePointExt {
    /// Deletes clips and their linked partners and leaves gaps (nothing shifts). Unknown ids fail with `ClipNotFound`;
    /// any member on a locked track refuses the whole edit.
    fn lift_clips(&mut self, ids: &[Id]) -> Result<(), EditError>;

    /// Add edit (Cmd+K): cuts every clip under `t` on the given tracks (`None` = all unlocked tracks; an explicitly named
    /// locked track fails). Edges and gaps are untouched. The left half keeps the id; the right halves of one linked group
    /// share a fresh link, so each side stays linked. Returns the ids of the new right halves.
    fn add_edit(&mut self, t: Time, tracks: Option<&[Id]>, ids: &mut dyn IdSource) -> Result<Vec<Id>, EditError>;

    /// Range to mark for "Mark Clip": the union of the clips under `t` on the given tracks (`None` = all tracks). `None`
    /// when no clip is under `t`.
    fn mark_clip_range(&self, t: Time, tracks: Option<&[Id]>) -> Option<TimeRange>;

    /// Q (`Head`) / W (`Tail`): ripple-trims the clip under `t` on each given track (`None` = all unlocked tracks) so that
    /// edge lands on `t`; later clips on ripple tracks shift. Head: the clip keeps its start, the part before `t` is cut.
    /// Tracks without a clip under `t` are skipped; none at all is `ClipNotFound`. A locked named track is `TrackLocked`
    /// (a tail trim needs `t` after the clip start). All picks are ONE ripple, so shifts never add up. Returns the edge
    /// movement of the first trimmed clip (negative = shortened earlier part).
    fn ripple_trim_to_playhead(&mut self, edge: ClipEdge, t: Time, tracks: Option<&[Id]>) -> Result<Time, EditError>;

    /// `ripple_trim_to_playhead`, also naming the track whose clips limited the trim (`None` = not limited by a clip) and
    /// how much shorter the trim ran because of it.
    fn ripple_trim_to_playhead_detailed(
        &mut self,
        edge: ClipEdge,
        t: Time,
        tracks: Option<&[Id]>,
    ) -> Result<(Time, Option<Id>, Time), EditError>;

    /// E: moves the selected clip edge to `t`. If the edge touches a neighbor on the same track (an edit point) it rolls:
    /// both sides move, either direction, limited by media and by not emptying a clip. Otherwise the clip only grows (no-op
    /// when `t` lies inside the clip), limited by the neighbor, the media and time 0; nothing ripples. Linked partners
    /// follow. Returns how far the edge actually moved.
    fn extend_edit(&mut self, id: Id, edge: ClipEdge, t: Time) -> Result<Time, EditError>;
}

fn selected_indices(tl: &Timeline, ids: Option<&[Id]>) -> Result<Vec<usize>, EditError> {
    let Some(ids) = ids else { return Ok((0..tl.tracks.len()).filter(|i| !tl.tracks[*i].is_locked).collect()) };
    let mut out: Vec<usize> = Vec::new();
    for id in ids {
        let i = tl.tracks.iter().position(|t| t.id == *id).ok_or(EditError::ClipNotFound)?;
        if tl.tracks[i].is_locked {
            return Err(EditError::TrackLocked);
        }
        if !out.contains(&i) {
            out.push(i);
        }
    }
    Ok(out)
}

impl TimelineThreePointExt for Timeline {
    fn lift_clips(&mut self, ids: &[Id]) -> Result<(), EditError> {
        let mut remove: Vec<(usize, Id)> = Vec::new();
        for id in ids {
            let group = self.linked_group(*id)?;
            if group.iter().any(|m| self.tracks[m.track].is_locked) {
                return Err(EditError::TrackLocked);
            }
            remove.extend(group.iter().map(|m| (m.track, m.clip.id)));
        }
        for (track, id) in remove {
            self.tracks[track].remove(id);
        }
        Ok(())
    }

    fn add_edit(&mut self, t: Time, tracks: Option<&[Id]>, ids: &mut dyn IdSource) -> Result<Vec<Id>, EditError> {
        let targets = selected_indices(self, tracks)?;
        let mut work = self.tracks.clone();
        let mut new_links: BTreeMap<Id, Id> = BTreeMap::new();
        let mut created: Vec<Id> = Vec::new();
        for i in targets {
            let Some(c) = work[i].clips().iter().find(|c| c.start < t && c.timeline().contains(t)).cloned() else {
                continue;
            };
            work[i].split(t, ids)?;
            let Some(mut right) =
                work[i].clips().iter().find(|x| x.start == t && x.id != c.id && x.media == c.media).cloned()
            else {
                continue;
            };
            if let Some(l) = c.link {
                let n = match new_links.get(&l) {
                    Some(n) => *n,
                    None => ids.next_id(),
                };
                new_links.insert(l, n);
                right.link = Some(n);
                work[i].replace(right.clone());
            }
            created.push(right.id);
        }
        self.tracks = work;
        Ok(created)
    }

    fn mark_clip_range(&self, t: Time, tracks: Option<&[Id]>) -> Option<TimeRange> {
        let mut result: Option<TimeRange> = None;
        for tr in self.tracks.iter().filter(|tr| tracks.is_none_or(|ids| ids.contains(&tr.id))) {
            let Some(c) = tr.clips().iter().find(|c| c.timeline().contains(t)) else { continue };
            let r = c.timeline();
            result = Some(match result {
                Some(x) => TimeRange::from_end(x.start.min(r.start), x.end().max(r.end())),
                None => r,
            });
        }
        result
    }

    fn ripple_trim_to_playhead(&mut self, edge: ClipEdge, t: Time, tracks: Option<&[Id]>) -> Result<Time, EditError> {
        Ok(self.ripple_trim_to_playhead_detailed(edge, t, tracks)?.0)
    }

    fn ripple_trim_to_playhead_detailed(
        &mut self,
        edge: ClipEdge,
        t: Time,
        tracks: Option<&[Id]>,
    ) -> Result<(Time, Option<Id>, Time), EditError> {
        let targets = selected_indices(self, tracks)?;
        let mut picks: Vec<(Id, Time)> = Vec::new();
        for i in targets {
            let hit = self.tracks[i].clips().iter().find(|c| {
                if edge == ClipEdge::Head { c.timeline().contains(t) } else { c.start < t && t <= c.timeline().end() }
            });
            if let Some(hit) = hit {
                picks.push((hit.id, if edge == ClipEdge::Head { t - hit.start } else { t - hit.timeline().end() }));
            }
        }
        if picks.is_empty() {
            return Err(EditError::ClipNotFound);
        }
        let mut work = self.clone();
        let (moved, limited_by, shortfall) = work.ripple_trim_many(&picks, edge)?;
        *self = work;
        Ok((moved, limited_by.map(|i| self.tracks[i].id), shortfall))
    }

    fn extend_edit(&mut self, id: Id, edge: ClipEdge, t: Time) -> Result<Time, EditError> {
        let m = self.find(id).ok_or(EditError::ClipNotFound)?;
        let c = m.clip;
        let others = self.tracks[m.track].clips().to_vec();
        match edge {
            ClipEdge::Tail => {
                if let Some(right) = others.iter().find(|o| o.start == c.timeline().end()) {
                    let cut = RollCut {
                        left: id,
                        left_partners_of: id,
                        right_partners_of: Some(right.id),
                        extend: true,
                        partners_follow: false,
                    };
                    return self.roll_cut(&cut, t - c.timeline().end());
                }
                let d = t - c.timeline().end();
                if d > Time::ZERO { self.trim(id, ClipEdge::Tail, d) } else { Ok(Time::ZERO) }
            }
            ClipEdge::Head => {
                if let Some(left) = others.iter().find(|o| o.timeline().end() == c.start) {
                    // The selected clip's partners roll their own cut too (not only the left neighbor's).
                    let cut = RollCut {
                        left: left.id,
                        left_partners_of: left.id,
                        right_partners_of: Some(id),
                        extend: true,
                        partners_follow: false,
                    };
                    return self.roll_cut(&cut, t - c.start);
                }
                let d = t - c.start;
                if d < Time::ZERO { self.trim(id, ClipEdge::Head, d) } else { Ok(Time::ZERO) }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::*;
    use sq_core_model::TrackKind::{Audio, Video};
    use sq_core_time::SequentialIds;

    #[test]
    fn lift_by_id_removes_partners_and_leaves_gaps() {
        let l = link();
        let (vc, au) = (clip(2, 2, 0, Video, Some(l), None), clip(2, 2, 0, Audio, Some(l), None));
        let mut tl = timeline(vec![track(Video, vec![v(0, 2), vc.clone(), v(4, 2)]), track(Audio, vec![au])]);
        assert_eq!(tl.lift_clips(&[vc.id]), Ok(()));
        assert_eq!(spans(&tl.tracks[0]), [[0, 2], [4, 6]]);
        assert!(tl.tracks[1].clips().is_empty());
        assert_eq!(tl.lift_clips(&[Id::from_u128(3)]), Err(EditError::ClipNotFound));
    }

    #[test]
    fn add_edit_cuts_under_the_time_and_shares_one_new_link_per_group() {
        let l = link();
        let (vc, au) = (clip(0, 10, 0, Video, Some(l), Some(20)), clip(0, 10, 0, Audio, Some(l), Some(20)));
        let mut tl = timeline(vec![track(Video, vec![vc.clone()]), track(Audio, vec![au])]);
        let created = tl.add_edit(s(4), None, &mut SequentialIds::default()).unwrap_or_default();
        assert_eq!(created.len(), 2);
        assert_eq!(spans(&tl.tracks[0]), [[0, 4], [4, 10]]);
        let (r0, r1) = (tl.tracks[0].clips()[1].link, tl.tracks[1].clips()[1].link);
        assert!(r0.is_some() && r0 == r1 && r0 != Some(l));
        assert_eq!(tl.tracks[0].clips()[0].link, Some(l));
        // edges and gaps are untouched
        assert_eq!(tl.add_edit(s(4), None, &mut SequentialIds::default()), Ok(vec![]));
        let t0 = tl.tracks[0].id;
        tl.tracks[0].is_locked = true;
        assert_eq!(tl.add_edit(s(6), Some(&[t0]), &mut SequentialIds::default()), Err(EditError::TrackLocked));
    }

    #[test]
    fn mark_clip_range_is_the_union_of_the_clips_under_the_time() {
        let tl = timeline(vec![track(Video, vec![v(0, 4)]), track(Video, vec![v(2, 6)])]);
        assert_eq!(tl.mark_clip_range(s(3), None), Some(r(0, 8)));
        assert_eq!(tl.mark_clip_range(s(3), Some(&[tl.tracks[1].id])), Some(r(2, 8)));
        assert_eq!(tl.mark_clip_range(s(9), None), None);
    }

    #[test]
    fn q_and_w_ripple_trim_to_the_time() {
        let mut tl = timeline(vec![track(Video, vec![clip(0, 10, 0, Video, None, Some(30)), v(10, 5)])]);
        assert_eq!(tl.ripple_trim_to_playhead(ClipEdge::Tail, s(6), None), Ok(s(-4)));
        assert_eq!(spans(&tl.tracks[0]), [[0, 6], [6, 11]]);
        assert_eq!(tl.ripple_trim_to_playhead_detailed(ClipEdge::Head, s(2), None), Ok((s(2), None, Time::ZERO)));
        assert_eq!(tl.ripple_trim_to_playhead(ClipEdge::Tail, s(50), None), Err(EditError::ClipNotFound));
    }

    #[test]
    fn extend_edit_rolls_at_a_cut_and_only_grows_elsewhere() {
        let (x, y) = (clip(0, 4, 0, Video, None, Some(30)), clip(4, 4, 6, Video, None, None));
        let mut tl = timeline(vec![track(Video, vec![x.clone(), y.clone()])]);
        assert_eq!(tl.extend_edit(x.id, ClipEdge::Tail, s(6)), Ok(s(2))); // rolls the cut
        assert_eq!(spans(&tl.tracks[0]), [[0, 6], [6, 8]]);
        assert_eq!(tl.extend_edit(y.id, ClipEdge::Head, s(3)), Ok(s(-3)));
        // a free edge only grows
        let z = clip(10, 2, 5, Video, None, Some(30));
        let mut t2 = timeline(vec![track(Video, vec![z.clone()])]);
        assert_eq!(t2.extend_edit(z.id, ClipEdge::Tail, s(11)), Ok(Time::ZERO));
        assert_eq!(t2.extend_edit(z.id, ClipEdge::Tail, s(15)), Ok(s(3)));
        assert_eq!(t2.extend_edit(z.id, ClipEdge::Head, s(7)), Ok(s(-3)));
    }

    // Swift H6ReviewFixTests: extendHeadGrowsPartnerAfterGap / extendHeadIsLimitedByThePartnersGap (frames are seconds).
    #[test]
    fn extend_head_grows_partner_after_gap() {
        let l = link();
        let mut tl = timeline(vec![
            track(Video, vec![clip(0, 10, 0, Video, None, Some(3000)), clip(10, 10, 50, Video, Some(l), Some(3000))]),
            track(Audio, vec![clip(10, 10, 50, Audio, Some(l), Some(3000))]),
        ]);
        let b = tl.tracks[0].clips()[1].id;
        assert_eq!(tl.extend_edit(b, ClipEdge::Head, s(7)), Ok(s(-3)));
        let (vc, au) = (&tl.tracks[0].clips()[1], &tl.tracks[1].clips()[0]);
        assert!(vc.start == s(7) && au.start == s(7) && au.source.start == s(47) && au.timeline().end() == s(20));
    }

    #[test]
    fn extend_head_is_limited_by_the_partners_gap() {
        let l = link();
        let mut tl = timeline(vec![
            track(Video, vec![clip(0, 10, 0, Video, None, Some(3000)), clip(10, 10, 50, Video, Some(l), Some(3000))]),
            track(Audio, vec![clip(0, 8, 0, Audio, None, Some(3000)), clip(10, 10, 50, Audio, Some(l), Some(3000))]),
        ]);
        let b = tl.tracks[0].clips()[1].id;
        assert_eq!(tl.extend_edit(b, ClipEdge::Head, s(5)), Ok(s(-2)));
        assert!(tl.tracks[0].clips()[1].start == s(8) && tl.tracks[1].clips()[1].start == s(8));
    }
}
