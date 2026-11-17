// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline+RangeEdits.swift (lift / extract, slide, insert-move)

use sq_core_model::{Clip, EditError, RippleClamp, Timeline, Track, floored_to_frame};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

/// Range edits (lift / extract), slide and insert-move.
pub trait TimelineRangeEditsExt {
    /// Indices of the tracks `ids`, in order, without duplicates. An unknown id is `ClipNotFound`, a locked track
    /// `TrackLocked`.
    #[doc(hidden)]
    fn target_indices(&self, ids: &[Id]) -> Result<Vec<usize>, EditError>;

    /// Lift: removes `range` (the In/Out span) from the targeted tracks and leaves a gap. Straddling clips are cut, clips
    /// inside are removed. Nothing shifts. The unlocked, untargeted linked partners of a clip cut in two are cut with it
    /// (`clear_range`, the rule `extract` uses); other untargeted clips are untouched. A transition between two clips the
    /// cut pulled apart is dropped. A locked targeted track refuses the whole edit.
    fn lift(&mut self, range: TimeRange, tracks: &[Id], ids: &mut dyn IdSource) -> Result<(), EditError>;

    /// `lift` with the partner rule kept off the tracks in `sparing` (see `clear_range`). `pruning: false` keeps the
    /// transitions for a caller that closes the range afterwards and prunes then.
    #[doc(hidden)]
    fn lift_sparing(
        &mut self,
        range: TimeRange,
        tracks: &[Id],
        sparing: &BTreeSet<Id>,
        pruning: bool,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError>;

    /// Extract: like `lift`, then closes the gap on the targeted tracks and every unlocked sync-locked track (locked tracks
    /// never move). The gap closes only as far as no track collides. Returns the time actually closed.
    fn extract(&mut self, range: TimeRange, tracks: &[Id], ids: &mut dyn IdSource) -> Result<Time, EditError>;

    /// `extract`, also naming the clamp: the track with the least room and how much of the range stayed open.
    #[doc(hidden)]
    fn extract_detailed(
        &mut self,
        range: TimeRange,
        tracks: &[Id],
        ids: &mut dyn IdSource,
    ) -> Result<(Time, Option<RippleClamp>), EditError>;

    /// Slides a clip along its track by `delta`. Source range and duration stay; an adjacent previous clip gets its tail
    /// moved, an adjacent next clip its head (a neighbor across a gap is not edited, the gap just shrinks or grows). Linked
    /// partners slide too. Clamped by neighbor handles (a neighbor never gets shorter than one frame), media ends, gaps and
    /// timeline start 0; the most restrictive member of the group wins. Returns the applied delta.
    fn slide(&mut self, id: Id, delta: Time) -> Result<Time, EditError>;

    /// Insert-move (Cmd-drag): takes the clip (and linked partners) out, closing the source gap like a ripple delete, and
    /// inserts it at `start`, pushing later clips on the destination and all sync-locked tracks right (a clip under the drop
    /// point is split). `start` is in the timeline as it was before the edit; it is translated for the closed gap. Linked
    /// partners keep their start/end offset (J/L cuts). The clip (as dragged) may change track (same kind). Locked tracks
    /// refuse.
    fn move_insert(&mut self, id: Id, start: Time, target: Option<Id>, ids: &mut dyn IdSource)
    -> Result<(), EditError>;
}

/// The cut `lift` and `extract` share: clears `range` on the tracks at `targets`, then keeps linked groups whole.
/// A clip cut in two gave its right piece a new link. Its untargeted partners (unlocked tracks) belong to that piece as
/// well: those overlapping the range are cut with it, so no half stays behind; later ones (on any unlocked track) just take
/// the new link. Everything else on an untargeted track stays uncut; locked tracks are never touched. Returns `targets`
/// plus the tracks holding a partner that belongs to a right piece (they move with it when the range closes). Tracks in
/// `sparing` are left out of the partner rule (Fast Cut: an untargeted main track never gets a hole; its clip stays whole
/// and keeps the link of the left piece).
#[doc(hidden)]
pub fn clear_range(
    range: TimeRange,
    work: &mut [Track],
    targets: &[usize],
    sparing: &BTreeSet<usize>,
    ids: &mut dyn IdSource,
) -> BTreeSet<usize> {
    let mut relinks: BTreeMap<Id, Id> = BTreeMap::new();
    for &i in targets {
        work[i].clear_relinking(range, &mut relinks, ids);
    }
    let mut involved: BTreeSet<usize> = targets.iter().copied().collect();
    if relinks.is_empty() {
        return involved;
    }
    for (j, track) in work.iter_mut().enumerate() {
        if targets.contains(&j) || track.is_locked || sparing.contains(&j) {
            continue;
        }
        let partners: Vec<Clip> =
            track.clips().iter().filter(|c| c.link.is_some_and(|l| relinks.contains_key(&l))).cloned().collect();
        if partners.is_empty() {
            continue;
        }
        let partner_ids: BTreeSet<Id> = partners.iter().map(|c| c.id).collect();
        let mut only = track.clone();
        only.set_clips(partners);
        only.clear_relinking(range, &mut relinks, ids);
        // `clear` moved tail transitions to the right pieces on the copy: keep them.
        track.transitions = only.transitions.clone();
        let mut merged: Vec<Clip> = track.clips().iter().filter(|c| !partner_ids.contains(&c.id)).cloned().collect();
        merged.extend(only.clips().iter().cloned());
        track.set_clips(merged);
        if only.clips().iter().any(|c| c.start >= range.end()) {
            involved.insert(j);
        }
    }
    // Later partners (also on targeted and spared tracks: relinking cuts no hole) take the new link of the right piece they
    // belong to.
    for (j, track) in work.iter_mut().enumerate() {
        if track.is_locked {
            continue;
        }
        let mut hit = false;
        let relinked: Vec<Clip> = track
            .clips()
            .iter()
            .map(|c| {
                let mut c = c.clone();
                if c.start >= range.end()
                    && let Some(n) = c.link.and_then(|l| relinks.get(&l))
                {
                    c.link = Some(*n);
                    hit = true;
                }
                c
            })
            .collect();
        if !hit {
            continue;
        }
        track.set_clips(relinked);
        involved.insert(j);
    }
    involved
}

impl TimelineRangeEditsExt for Timeline {
    fn target_indices(&self, ids: &[Id]) -> Result<Vec<usize>, EditError> {
        let mut out: Vec<usize> = Vec::new();
        for id in ids {
            let i = self.tracks.iter().position(|t| t.id == *id).ok_or(EditError::ClipNotFound)?;
            if self.tracks[i].is_locked {
                return Err(EditError::TrackLocked);
            }
            if !out.contains(&i) {
                out.push(i);
            }
        }
        Ok(out)
    }

    fn lift(&mut self, range: TimeRange, tracks: &[Id], ids: &mut dyn IdSource) -> Result<(), EditError> {
        self.lift_sparing(range, tracks, &BTreeSet::new(), true, ids)
    }

    fn lift_sparing(
        &mut self,
        range: TimeRange,
        tracks: &[Id],
        sparing: &BTreeSet<Id>,
        pruning: bool,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError> {
        if range.is_empty() {
            return Ok(());
        }
        let targets = self.target_indices(tracks)?;
        let mut work = self.tracks.clone();
        let spared: BTreeSet<usize> =
            (0..work.len()).filter(|i| sparing.contains(&work[*i].id) && !targets.contains(i)).collect();
        clear_range(range, &mut work, &targets, &spared, ids);
        if pruning {
            let fd = self.format.frame_duration;
            for (w, old) in work.iter_mut().zip(&self.tracks) {
                if w != old {
                    w.prune_transitions(fd);
                }
            }
        }
        // Cut times off every frame grid can round (see `Time::reducing`): pieces that no longer fit are refused.
        if !work.iter().all(Track::is_consistent) {
            return Err(EditError::Collision);
        }
        self.tracks = work;
        Ok(())
    }

    fn extract(&mut self, range: TimeRange, tracks: &[Id], ids: &mut dyn IdSource) -> Result<Time, EditError> {
        Ok(self.extract_detailed(range, tracks, ids)?.0)
    }

    fn extract_detailed(
        &mut self,
        range: TimeRange,
        tracks: &[Id],
        ids: &mut dyn IdSource,
    ) -> Result<(Time, Option<RippleClamp>), EditError> {
        if range.is_empty() {
            return Ok((Time::ZERO, None));
        }
        let targets = self.target_indices(tracks)?;
        let mut work = self.tracks.clone();
        let mut involved = clear_range(range, &mut work, &targets, &BTreeSet::new(), ids);
        involved.extend((0..work.len()).filter(|i| work[*i].follows_ripple()));
        // Untargeted tracks are not cut: a split-edit partner straddling the edit point there moves with its pair.
        let start: BTreeMap<usize, Time> = involved.iter().map(|i| (*i, range.end())).collect();
        let pivot = Timeline::following_straddlers(&work, &start, &BTreeSet::new());
        let pivot_of = |i: usize| pivot.get(&i).copied().unwrap_or(range.end());
        let none = BTreeSet::new();
        let mut d = range.duration;
        let mut limiting: Option<usize> = None;
        for &i in &involved {
            if let Some(room) = work[i].left_room(pivot_of(i), &none)
                && room < d
            {
                d = room;
                limiting = Some(i);
            }
        }
        for &i in &involved {
            work[i].shift(pivot_of(i), Time::ZERO - d, &none);
        }
        if !work.iter().all(Track::is_consistent) {
            return Err(EditError::Collision);
        }
        self.tracks = work;
        // Deliberate delete of the range: captions inside the closed span go with the content they describe.
        self.close_caption_span(TimeRange::new(range.end() - d, d));
        Ok((d, limiting.map(|track| RippleClamp { track, shortfall: range.duration - d })))
    }

    fn slide(&mut self, id: Id, delta: Time) -> Result<Time, EditError> {
        let group = self.linked_group(id)?;
        if group.iter().any(|m| self.tracks[m.track].is_locked) {
            return Err(EditError::TrackLocked);
        }
        let ids: BTreeSet<Id> = group.iter().map(|m| m.clip.id).collect();
        let frame = self.frame_duration();
        let mut d = delta;
        for m in &group {
            let c = &m.clip;
            let others: Vec<&Clip> = self.tracks[m.track].clips().iter().filter(|o| !ids.contains(&o.id)).collect();
            let prev = others.iter().rev().find(|o| o.timeline().end() <= c.start);
            let next = others.iter().find(|o| o.start >= c.timeline().end());
            if d < Time::ZERO {
                if let Some(p) = prev.filter(|p| p.timeline().end() == c.start) {
                    d = d.max(Time::ZERO - (p.duration() - frame).max(Time::ZERO));
                } else {
                    d = d.max(Time::ZERO - (c.start - prev.map_or(Time::ZERO, |p| p.timeline().end())));
                }
                if let Some(n) = next.filter(|n| n.start == c.timeline().end())
                    && let Some(h) = n.head_handle()
                {
                    d = d.max(Time::ZERO - floored_to_frame(h, frame));
                }
            } else if d > Time::ZERO {
                if let Some(n) = next {
                    if n.start == c.timeline().end() {
                        d = d.min((n.duration() - frame).max(Time::ZERO));
                    } else {
                        d = d.min(n.start - c.timeline().end());
                    }
                }
                if let Some(p) = prev.filter(|p| p.timeline().end() == c.start)
                    && let Some(room) = p.tail_room()
                {
                    d = d.min(floored_to_frame(room, frame));
                }
            }
        }
        if d == Time::ZERO {
            return Ok(Time::ZERO);
        }
        let mut work = self.tracks.clone();
        for m in &group {
            let c = &m.clip;
            let others: Vec<&Clip> = self.tracks[m.track].clips().iter().filter(|o| !ids.contains(&o.id)).collect();
            if let Some(p) = others.iter().rev().find(|o| o.timeline().end() <= c.start)
                && p.timeline().end() == c.start
            {
                let mut p = (*p).clone();
                p.extend_tail(d);
                work[m.track].replace(p);
            }
            if let Some(n) = others.iter().find(|o| o.start >= c.timeline().end())
                && n.start == c.timeline().end()
            {
                let mut n = (*n).clone();
                n.start += d;
                n.extend_head(Time::ZERO - d);
                work[m.track].replace(n);
            }
            let mut moved = c.clone();
            moved.start += d;
            work[m.track].replace(moved);
        }
        if !work.iter().all(Track::is_consistent) {
            return Err(EditError::Collision);
        }
        self.tracks = work;
        Ok(d)
    }

    fn move_insert(
        &mut self,
        id: Id,
        start: Time,
        target: Option<Id>,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError> {
        let group = self.linked_group(id)?;
        if group.iter().any(|m| self.tracks[m.track].is_locked) {
            return Err(EditError::TrackLocked);
        }
        let primary = &group[0].clip;
        let mut destinations: Vec<Id> = group.iter().map(|m| self.tracks[m.track].id).collect();
        if let Some(target) = target {
            let ti = self.tracks.iter().position(|t| t.id == target).ok_or(EditError::ClipNotFound)?;
            if self.tracks[ti].kind != primary.kind {
                return Err(EditError::WrongTrackKind);
            }
            if self.tracks[ti].is_locked {
                return Err(EditError::TrackLocked);
            }
            destinations[0] = target;
        }
        let mut work = self.clone();
        let closed = work.ripple_delete_one(id)?.0;
        let mut t = start.max(Time::ZERO);
        let first = group.iter().map(|m| m.clip.start).min().ok_or(EditError::ClipNotFound)?;
        let last = group.iter().map(|m| m.clip.timeline().end()).max().ok_or(EditError::ClipNotFound)?;
        let range = TimeRange::from_end(first, last);
        if t >= range.end() {
            t = (t - closed).max(Time::ZERO);
        } else if t > range.start {
            t = range.start;
        }
        let placements: Vec<(Clip, Id)> = group.iter().zip(destinations).map(|(m, d)| (m.clip.clone(), d)).collect();
        work.insert(&placements, t, ids)?;
        *self = work;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::*;
    use sq_core_model::TrackKind::{Audio, Video};
    use sq_core_time::SequentialIds;

    fn sync_track(clips: Vec<Clip>, sync: bool) -> Track {
        let mut t = track(Video, clips);
        t.sync_lock = sync;
        t
    }

    #[test]
    fn lift_cuts_straddlers_removes_inside_leaves_gap() {
        let (x, b, c) = (v(0, 4), v(4, 2), clip(6, 4, 10, Video, None, None));
        let mut tl = timeline(vec![track(Video, vec![x.clone(), b, c])]);
        let t0 = tl.tracks[0].id;
        assert_eq!(tl.lift(r(2, 8), &[t0], &mut SequentialIds::default()), Ok(()));
        assert_eq!(spans(&tl.tracks[0]), [[0, 2], [8, 10]]);
        assert_eq!(tl.tracks[0].clips()[1].source.start, s(12));
        assert_eq!(tl.tracks[0].clips()[0].id, x.id);
    }

    #[test]
    fn lift_touches_only_targeted_tracks_and_refuses_locked_ones() {
        let mut tl = timeline(vec![track(Video, vec![v(0, 6)]), locked(track(Video, vec![v(0, 6)]))]);
        let (t0, t1) = (tl.tracks[0].id, tl.tracks[1].id);
        let mut ids = SequentialIds::default();
        assert_eq!(tl.lift(r(1, 3), &[t0], &mut ids), Ok(()));
        assert_eq!(spans(&tl.tracks[0]), [[0, 1], [3, 6]]);
        assert_eq!(spans(&tl.tracks[1]), [[0, 6]]);
        let before = tl.clone();
        assert_eq!(tl.lift(r(1, 3), &[t0, t1], &mut ids), Err(EditError::TrackLocked));
        assert_eq!(tl, before);
    }

    #[test]
    fn lift_linked_partners_on_targeted_tracks_share_the_new_link() {
        let l = link();
        let mut tl = timeline(vec![
            track(Video, vec![clip(0, 6, 0, Video, Some(l), None)]),
            track(Audio, vec![clip(0, 6, 0, Audio, Some(l), None)]),
        ]);
        let all: Vec<Id> = tl.tracks.iter().map(|t| t.id).collect();
        assert_eq!(tl.lift(r(2, 4), &all, &mut SequentialIds::default()), Ok(()));
        for t in &tl.tracks {
            assert_eq!(spans(t), [[0, 2], [4, 6]]);
        }
        assert!(tl.tracks.iter().all(|t| t.clips()[0].link == Some(l))); // left halves keep the link
        let right: Vec<Option<Id>> = tl.tracks.iter().map(|t| t.clips()[1].link).collect();
        assert!(right[0].is_some() && right[0] == right[1] && right[0] != Some(l)); // right halves share a new one
    }

    #[test]
    fn extract_closes_the_gap() {
        let mut tl = timeline(vec![track(Video, vec![v(0, 4), v(4, 4), v(8, 2)])]);
        let t0 = tl.tracks[0].id;
        assert_eq!(tl.extract(r(2, 6), &[t0], &mut SequentialIds::default()), Ok(s(4)));
        assert_eq!(spans(&tl.tracks[0]), [[0, 2], [2, 4], [4, 6]]);
    }

    #[test]
    fn extract_shifts_sync_locked_tracks_only() {
        let mut tl = timeline(vec![
            track(Video, vec![v(0, 10)]),
            sync_track(vec![v(0, 1), v(8, 2)], true),
            sync_track(vec![v(8, 2)], false),
            locked(track(Video, vec![v(8, 2)])),
        ]);
        let t0 = tl.tracks[0].id;
        assert!(tl.extract(r(2, 6), &[t0], &mut SequentialIds::default()).is_ok());
        assert_eq!(spans(&tl.tracks[0]), [[0, 2], [2, 6]]);
        assert_eq!(spans(&tl.tracks[1]), [[0, 1], [4, 6]]);
        assert_eq!(spans(&tl.tracks[2]), [[8, 10]]);
        assert_eq!(spans(&tl.tracks[3]), [[8, 10]]);
    }

    #[test]
    fn extract_blocked_by_another_track_closes_partially() {
        let mut tl = timeline(vec![track(Video, vec![v(0, 10)]), track(Video, vec![v(0, 4), v(8, 2)])]);
        let t0 = tl.tracks[0].id;
        // track 1 has only 4 s of room before its clip at 8; the range is 5 s
        assert_eq!(tl.extract(r(1, 6), &[t0], &mut SequentialIds::default()), Ok(s(4)));
        assert_eq!(spans(&tl.tracks[0]), [[0, 1], [2, 6]]);
        assert!(tl.tracks.iter().all(Track::is_consistent));
    }

    #[test]
    fn extract_refuses_a_locked_target() {
        let mut tl = timeline(vec![locked(track(Video, vec![v(0, 10)]))]);
        let t0 = tl.tracks[0].id;
        assert_eq!(tl.extract(r(2, 4), &[t0], &mut SequentialIds::default()), Err(EditError::TrackLocked));
    }

    #[test]
    fn slide_right_adjusts_the_neighbours() {
        let (p, m, n) =
            (clip(0, 4, 0, Video, None, Some(20)), clip(4, 2, 7, Video, None, None), clip(6, 4, 3, Video, None, None));
        let mut tl = timeline(vec![track(Video, vec![p, m.clone(), n])]);
        assert_eq!(tl.slide(m.id, s(2)), Ok(s(2)));
        let cs = tl.tracks[0].clips();
        assert_eq!(cs[0].timeline(), r(0, 6));
        assert_eq!((cs[1].start, cs[1].source), (s(6), m.source));
        assert_eq!((cs[2].start, cs[2].source), (s(8), TimeRange::new(s(5), s(2))));
    }

    #[test]
    fn slide_left() {
        let (p, m, n) = (v(0, 4), v(4, 2), clip(6, 4, 3, Video, None, None));
        let mut tl = timeline(vec![track(Video, vec![p, m.clone(), n])]);
        assert_eq!(tl.slide(m.id, s(-1)), Ok(s(-1)));
        let cs = tl.tracks[0].clips();
        assert_eq!((cs[0].timeline(), cs[1].start), (r(0, 3), s(3)));
        assert_eq!((cs[2].start, cs[2].source.start, cs[2].timeline().end()), (s(5), s(2), s(10)));
    }

    #[test]
    fn move_insert_closes_the_source_gap_and_opens_one_at_the_target() {
        let (x, y, z) = (v(0, 2), v(2, 2), v(4, 2));
        let mut tl = timeline(vec![track(Video, vec![x.clone(), y.clone(), z.clone()])]);
        assert_eq!(tl.move_insert(x.id, s(4), None, &mut SequentialIds::default()), Ok(()));
        let order: Vec<Id> = tl.tracks[0].clips().iter().map(|c| c.id).collect();
        assert_eq!(order, [y.id, x.id, z.id]);
        assert_eq!(spans(&tl.tracks[0]), [[0, 2], [2, 4], [4, 6]]);
    }
}
