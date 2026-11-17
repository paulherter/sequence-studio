// Swift: JumpCut.swift
//! Jump cut to the alternate track (the checkerboard: the take alternates between V1/A1 and V2/A2 with a median 0.3 s
//! overlap). One command cuts the take at the playhead and moves the rest onto the alternate track of its pair
//! (V1<->V2, V3<->V4, A1<->A2, ...), its head pulled back N frames into the handle so the two halves overlap; on audio
//! the overlap is an equal crossfade. No file format change.

use crate::timeline_add_track::AddTrackExt as _;
use crate::timeline_edit_targets::{EditTargetsSource, TimelineEditTargetsExt as _};
use sq_core_model::{Clip, EditError, FadeKeys, Member, Timeline, Track, TrackKind, Transition};
use sq_core_time::{Id, IdSource, Time};
use std::collections::{BTreeMap, BTreeSet};

/// `enum JumpCut`.
pub enum JumpCut {}

impl JumpCut {
    /// Default overlap: 0.3 s (the median track-switch overlap) in whole frames of the sequence.
    pub fn default_overlap_frames(frame_duration: Time) -> i64 {
        Time::new(3, 10).frame_index(frame_duration)
    }

    /// Where one linked group's clips of one kind go, by index among the tracks of that kind. Normally each goes to the
    /// other track of its pair (0<->1, 2<->3). When the group fills both tracks of a pair (dual-mono audio on A1 + A2),
    /// the whole block moves together by its width rounded up to even (A1+A2 <-> A3+A4), keeping the channel order.
    pub fn destinations(k: &[usize]) -> Vec<usize> {
        let set: BTreeSet<usize> = k.iter().copied().collect();
        let flip = || k.iter().map(|i| i ^ 1).collect();
        if !k.iter().any(|i| set.contains(&(i ^ 1))) {
            return flip();
        }
        let (Some(lo), Some(hi)) = (k.iter().copied().min(), k.iter().copied().max()) else { return flip() };
        let w = hi - lo + 1;
        let b = w + (w & 1);
        // Even blocks move up, odd ones down (the odd ones start at `b` or later, so they never leave the list).
        let shift: isize = if (lo / b) % 2 == 0 { b as isize } else { -(b as isize) };
        k.iter().map(|i| i.saturating_add_signed(shift)).collect()
    }
}

/// Index of the track at `i` among the tracks of its kind.
fn kind_index(tl: &Timeline, i: usize) -> usize {
    tl.tracks[..i].iter().filter(|t| t.kind == tl.tracks[i].kind).count()
}

/// Absolute index of the `k`-th track of `kind`, `None` when it does not exist.
fn track_index(tl: &Timeline, kind: TrackKind, k: usize) -> Option<usize> {
    (0..tl.tracks.len()).filter(|i| tl.tracks[*i].kind == kind).nth(k)
}

/// The clip strictly spanning `t` on track `i`.
fn spanning(tl: &Timeline, i: usize, t: Time) -> Option<&Clip> {
    tl.tracks[i].clips().iter().find(|c| c.start < t && t < c.timeline().end())
}

/// `c` (on track `i`) was already jump cut at `t`: a clip of the same media ends exactly at `t` on another track of the
/// same kind. Pressing again at the same playhead is then a no-op instead of leaving a sliver.
fn already_jump_cut(tl: &Timeline, c: &Clip, i: usize, t: Time) -> bool {
    (0..tl.tracks.len()).any(|j| {
        j != i
            && tl.tracks[j].kind == tl.tracks[i].kind
            && tl.tracks[j].clips().iter().any(|o| o.media == c.media && o.timeline().end() == t)
    })
}

/// Seeds of a jump cut at `t`: the clips, whether a locked track hid one, whether one was already cut there.
struct Seeds {
    seeds: Vec<Id>,
    locked: bool,
    already_cut: bool,
}

/// Seeds of a jump cut at `t`. Tracks: the edit target rule (selection > targeted > all); for the targeted tier a targeted
/// track with no clip under `t` is replaced by the other track of its pair, so the take keeps being found after it moved
/// to V2/A2 and nothing is selected.
fn jump_cut_seeds(tl: &Timeline, t: Time, selection: &BTreeSet<Id>) -> Seeds {
    let rule = tl.edit_targets(selection);
    let mut scope: Vec<usize> = Vec::new();
    for id in &rule.tracks {
        let Some(mut i) = tl.tracks.iter().position(|x| x.id == *id) else { continue };
        if rule.source == EditTargetsSource::Targeted
            && spanning(tl, i, t).is_none()
            && let Some(p) = track_index(tl, tl.tracks[i].kind, kind_index(tl, i) ^ 1)
        {
            i = p;
        }
        if !scope.contains(&i) {
            scope.push(i);
        }
    }
    let mut out = Seeds { seeds: Vec::new(), locked: false, already_cut: false };
    for i in scope {
        let Some(c) = spanning(tl, i, t) else { continue };
        if tl.tracks[i].is_locked {
            out.locked = true;
        } else if already_jump_cut(tl, c, i, t) {
            out.already_cut = true;
        } else {
            out.seeds.push(c.id);
        }
    }
    out
}

/// `extension Timeline` of `JumpCut.swift`.
pub trait TimelineJumpCutExt {
    /// Clips the jump cut would cut at `t`; empty when there is nothing (left) to cut.
    fn jump_cut_candidates(&self, t: Time, selection: &BTreeSet<Id>) -> Vec<Id>;

    /// True when the clip under `t` was already jump cut exactly at `t` (a second press would do nothing).
    fn is_jump_cut(&self, t: Time, selection: &BTreeSet<Id>) -> bool;

    /// Cuts the clips under `t` (linked partners included) and moves each right half onto its alternate track
    /// (`JumpCut::destinations`), head extended by `overlap_frames` frames. The overlap is limited by the media handle, by
    /// the left half's length, by time 0 and by the last clip ending before `t` on the alternate track; the whole cut uses
    /// the smallest, so linked A/V stays in sync. Audio halves get matching fade-out / fade-in over the overlap. Missing
    /// alternate tracks are created. A tail fade transition moves with the right half; a transition into the next clip on
    /// the old track is dropped. `ClipNotFound` (nothing under `t`, or already jump cut there), `TrackLocked` (a source,
    /// partner or alternate track is locked) and `Collision` (an alternate track is occupied after `t`, or is another
    /// clip's source track); nothing changes then. Returns the moved halves' ids.
    fn jump_cut_alternate(
        &mut self,
        t: Time,
        selection: &BTreeSet<Id>,
        overlap_frames: i64,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError>;
}

impl TimelineJumpCutExt for Timeline {
    fn jump_cut_candidates(&self, t: Time, selection: &BTreeSet<Id>) -> Vec<Id> {
        jump_cut_seeds(self, t, selection).seeds
    }

    fn is_jump_cut(&self, t: Time, selection: &BTreeSet<Id>) -> bool {
        jump_cut_seeds(self, t, selection).already_cut
    }

    fn jump_cut_alternate(
        &mut self,
        t: Time,
        selection: &BTreeSet<Id>,
        overlap_frames: i64,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError> {
        let fd = self.frame_duration();
        let found = jump_cut_seeds(self, t, selection);
        if found.seeds.is_empty() {
            return Err(if found.locked { EditError::TrackLocked } else { EditError::ClipNotFound });
        }

        // Seeds plus their linked partners that also span `t` (a partner offset past the cut is not cut), per group.
        let mut groups: Vec<Vec<Member>> = Vec::new();
        let mut seen: BTreeSet<Id> = BTreeSet::new();
        for id in &found.seeds {
            if seen.contains(id) {
                continue;
            }
            let mut g: Vec<Member> = Vec::new();
            for m in self.linked_group(*id)? {
                if seen.insert(m.clip.id) && m.clip.start < t && t < m.clip.timeline().end() {
                    g.push(m);
                }
            }
            if !g.is_empty() {
                groups.push(g);
            }
        }
        let members: Vec<Member> = groups.iter().flatten().cloned().collect();
        if members.iter().any(|m| self.tracks[m.track].is_locked) {
            return Err(EditError::TrackLocked);
        }

        let mut work = self.clone();
        // Alternate tracks per group and kind, created when missing (appending keeps the indices of existing tracks).
        let mut dest_of: BTreeMap<Id, usize> = BTreeMap::new();
        for g in &groups {
            for kind in [TrackKind::Video, TrackKind::Audio] {
                let ms: Vec<&Member> = g.iter().filter(|m| work.tracks[m.track].kind == kind).collect();
                if ms.is_empty() {
                    continue;
                }
                let targets = JumpCut::destinations(&ms.iter().map(|m| kind_index(&work, m.track)).collect::<Vec<_>>());
                for (m, k) in ms.iter().zip(targets) {
                    while track_index(&work, kind, k).is_none() {
                        work.add_track(kind, ids);
                    }
                    dest_of.insert(m.clip.id, track_index(&work, kind, k).ok_or(EditError::Collision)?);
                }
            }
        }
        let dest: Vec<usize> = members
            .iter()
            .map(|m| dest_of.get(&m.clip.id).copied().ok_or(EditError::Collision))
            .collect::<Result<_, _>>()?;
        let sources: BTreeSet<usize> = members.iter().map(|m| m.track).collect();
        for d in &dest {
            if work.tracks[*d].is_locked {
                return Err(EditError::TrackLocked);
            }
            if sources.contains(d) {
                return Err(EditError::Collision); // another cut clip sits on the alternate track
            }
        }
        if dest.iter().collect::<BTreeSet<_>>().len() != dest.len() {
            return Err(EditError::Collision);
        }

        // Split; right halves of one group share one new link.
        let mut relinks: BTreeMap<Id, Id> = BTreeMap::new();
        let mut rights: Vec<Clip> = Vec::new();
        for m in &members {
            work.tracks[m.track].split_relinking(t, &mut relinks, ids)?;
            let r =
                work.tracks[m.track].clips().iter().find(|c| c.start == t).cloned().ok_or(EditError::ClipNotFound)?;
            rights.push(r);
        }

        // One overlap for everyone.
        let mut ov = (fd * overlap_frames.max(0)).min(t);
        for (i, (r, d)) in rights.iter().zip(&dest).enumerate() {
            if let Some(h) = r.head_handle() {
                ov = ov.min(h);
            }
            ov = ov.min(t - members[i].clip.start); // never into material cut out before the left half
            let others = work.tracks[*d].clips();
            if others.iter().any(|c| c.timeline().end() > t && c.start < r.timeline().end()) {
                return Err(EditError::Collision);
            }
            let prev_end = others.iter().filter(|c| c.timeline().end() <= t).map(|c| c.timeline().end()).max();
            ov = ov.min(t - prev_end.unwrap_or(Time::ZERO));
        }
        ov = FadeKeys::snap_down(ov, fd);

        for (i, m) in members.iter().enumerate() {
            let mut r = rights[i].clone();
            let d = dest[i];
            let old_id = r.id;
            work.tracks[m.track].remove(old_id);
            // Transitions from the right half's tail: a fade out goes along, a cut into the next clip cannot.
            let mut carried: Vec<Transition> = Vec::new();
            work.tracks[m.track].transitions.retain(|tr| {
                if tr.outgoing != Some(old_id) {
                    return true;
                }
                if tr.incoming.is_none() {
                    carried.push(tr.clone());
                }
                false
            });
            if ov > Time::ZERO {
                r.start -= ov;
                r.extend_head(ov);
                if r.kind == TrackKind::Audio {
                    r.set_audio_fade_in(ov, fd, ids);
                    if let Some(mut l) = work.tracks[m.track].clip(m.clip.id).cloned() {
                        l.set_audio_fade_out(ov, fd, ids);
                        work.tracks[m.track].replace(l);
                    }
                }
            }
            work.tracks[d].overwrite(r, ids)?;
            work.tracks[d].transitions.extend(carried);
        }
        if !work.tracks.iter().all(Track::is_consistent) {
            return Err(EditError::Collision);
        }
        *self = work;
        Ok(rights.iter().map(|c| c.id).collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_magnetic::test_support::dissolve;
    use sq_core_model::{Clip, Track, TrackKind};

    #[test]
    fn default_overlap_is_about_point_three_seconds() {
        assert_eq!(JumpCut::default_overlap_frames(Time::new(1, 30)), 9);
        assert_eq!(JumpCut::default_overlap_frames(Time::new(1, 25)), 7);
        assert_eq!(JumpCut::default_overlap_frames(Time::new(1001, 60000)), 17);
    }

    #[test]
    fn single_tracks_go_to_the_other_track_of_their_pair() {
        assert_eq!(JumpCut::destinations(&[0]), vec![1]);
        assert_eq!(JumpCut::destinations(&[1]), vec![0]);
        assert_eq!(JumpCut::destinations(&[2, 5]), vec![3, 4]);
    }

    #[test]
    fn a_block_filling_both_tracks_of_a_pair_moves_by_its_width() {
        assert_eq!(JumpCut::destinations(&[0, 1]), vec![2, 3]);
        assert_eq!(JumpCut::destinations(&[2, 3]), vec![0, 1]);
        assert_eq!(JumpCut::destinations(&[4, 5]), vec![6, 7]);
    }

    // MARK: Timeline.jump_cut_alternate

    use crate::timeline_edits::fixtures::{clip as fx_clip, link as fx_link, timeline as fx_timeline};
    use sq_core_model::TrackKind::{Audio, Video};
    use sq_core_time::TimeRange;

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }
    fn f(n: i64) -> Time {
        Time::new(1, 30) * n
    }
    /// Ids that never repeat across calls (the fixtures' counter).
    struct Fresh;
    impl IdSource for Fresh {
        fn next_id(&mut self) -> Id {
            Id::from_u128(crate::timeline_edits::fixtures::fresh())
        }
    }
    fn ids() -> Fresh {
        Fresh
    }

    /// Linked A/V take on V1/A1, 0...10 s, source `src`...`src`+10 s of a 60 s file. `with_upper`: V2/A2 exist.
    fn make(with_upper: bool, src: i64, start: i64) -> (Timeline, Clip, Clip) {
        let l = fx_link();
        let mut v = fx_clip(start, 10, src, Video, Some(l), Some(60));
        let mut a = fx_clip(start, 10, src, Audio, Some(l), Some(60));
        a.media = v.media;
        v.name = "take".into();
        a.name = "take".into();
        let mut v1 = Track::new(Id::from_u128(7001), Video);
        let mut a1 = Track::new(Id::from_u128(7002), Audio);
        (v1.is_targeted, a1.is_targeted) = (true, true);
        v1.set_clips(vec![v.clone()]);
        a1.set_clips(vec![a.clone()]);
        let mut tracks = vec![v1];
        if with_upper {
            tracks.push(Track::new(Id::from_u128(7003), Video));
        }
        tracks.push(a1);
        if with_upper {
            tracks.push(Track::new(Id::from_u128(7004), Audio));
        }
        (fx_timeline(tracks), v, a)
    }

    fn track_of(t: &Timeline, kind: TrackKind, n: usize) -> &Track {
        t.tracks.iter().filter(|x| x.kind == kind).nth(n).unwrap()
    }

    fn cut(t: &mut Timeline, at: Time, selection: &[Id]) -> Result<Vec<Id>, EditError> {
        t.jump_cut_alternate(at, &selection.iter().copied().collect(), 9, &mut ids())
    }

    #[test]
    fn moves_the_rest_to_the_alternate_track_with_overlap_and_crossfade() {
        let (mut t, v, a) = make(true, 5, 0);
        let moved = cut(&mut t, s(4), &[]).unwrap();
        assert_eq!(moved.len(), 2);
        let (v1, v2) = (track_of(&t, Video, 0), track_of(&t, Video, 1));
        let (a1, a2) = (track_of(&t, Audio, 0), track_of(&t, Audio, 1));
        assert_eq!(v1.clips().len(), 1);
        assert_eq!(v1.clips()[0].id, v.id);
        assert_eq!(v1.clips()[0].timeline().end(), s(4));
        let (rv, ra) = (&v2.clips()[0], &a2.clips()[0]);
        assert_eq!(rv.start, s(4) - f(9));
        assert_eq!(rv.timeline().end(), s(10));
        assert_eq!(ra.start, rv.start);
        assert_eq!(rv.source.start, s(9) - f(9));
        // Sync: both halves share a new link, different from the left's.
        assert!(rv.link.is_some() && rv.link == ra.link && rv.link != v.link);
        // Audio crossfade over the overlap.
        assert_eq!(a1.clips()[0].audio_fade_out(), f(9));
        assert_eq!(ra.audio_fade_in(), f(9));
        assert_eq!(rv.audio_fade_in(), Time::ZERO);
        let _ = a;
    }

    #[test]
    fn a_second_jump_cut_on_the_moved_clip_goes_back_down() {
        let (mut t, v, _) = make(true, 5, 0);
        let moved = cut(&mut t, s(4), &[]).unwrap();
        let back = cut(&mut t, s(7), &moved).unwrap();
        assert_eq!(back.len(), 2);
        let (v1, v2) = (track_of(&t, Video, 0), track_of(&t, Video, 1));
        let (a1, a2) = (track_of(&t, Audio, 0), track_of(&t, Audio, 1));
        assert_eq!((v1.clips().len(), a1.clips().len()), (2, 2));
        assert_eq!(v1.clips()[0].id, v.id);
        assert_eq!((v1.clips()[1].start, v1.clips()[1].timeline().end()), (s(7) - f(9), s(10)));
        assert_eq!(a1.clips()[1].start, v1.clips()[1].start);
        assert_eq!((v2.clips().len(), v2.clips()[0].timeline().end()), (1, s(7)));
        assert_eq!((a2.clips()[0].audio_fade_out(), a1.clips()[1].audio_fade_in()), (f(9), f(9)));
        assert_eq!(v1.clips()[1].link, a1.clips()[1].link);
    }

    #[test]
    fn overlap_is_limited_by_the_head_handle_and_the_left_half() {
        let (mut t, _, _) = make(true, 0, 0);
        // Source starts at 0: the right half has only 4 frames before the cut at 4 frames.
        cut(&mut t, f(4), &[]).unwrap();
        let rv = &track_of(&t, Video, 1).clips()[0];
        assert_eq!((rv.start, rv.source.start), (Time::ZERO, Time::ZERO));
        assert_eq!(track_of(&t, Audio, 1).clips()[0].audio_fade_in(), f(4));

        // The take starts at 1 s (cut-out material before it in the file): cutting 5 frames in allows 5 frames of overlap.
        let (mut u, _, _) = make(true, 5, 1);
        cut(&mut u, s(1) + f(5), &[]).unwrap();
        let (rv, ra) = (&track_of(&u, Video, 1).clips()[0], &track_of(&u, Audio, 1).clips()[0]);
        assert_eq!((rv.start, rv.source.start, ra.start), (s(1), s(5), s(1)));
        assert_eq!((track_of(&u, Audio, 0).clips()[0].audio_fade_out(), ra.audio_fade_in()), (f(5), f(5)));
    }

    #[test]
    fn a_clip_on_the_alternate_track_limits_or_refuses_the_cut() {
        let (mut t, _, _) = make(true, 5, 0);
        let mut broll = fx_clip(0, 1, 0, Video, None, None);
        broll.source = TimeRange::new(Time::ZERO, s(3) + f(27));
        let vi = t.tracks.iter().position(|x| x.kind == Video && x.clips().is_empty()).unwrap();
        t.tracks[vi].set_clips(vec![broll]); // ends 3 frames before the cut
        cut(&mut t, s(4), &[]).unwrap();
        let v2 = track_of(&t, Video, 1);
        assert_eq!((v2.clips().len(), v2.clips()[1].start), (2, s(4) - f(3)));
        // The whole group uses the same overlap: audio stays in sync.
        assert_eq!(track_of(&t, Audio, 1).clips()[0].start, s(4) - f(3));
        assert_eq!(track_of(&t, Audio, 0).clips()[0].audio_fade_out(), f(3));

        let (mut u, _, _) = make(true, 5, 0);
        let mut under = fx_clip(5, 2, 0, Video, None, None);
        under.source = TimeRange::new(Time::ZERO, s(2));
        let vi = u.tracks.iter().position(|x| x.kind == Video && x.clips().is_empty()).unwrap();
        u.tracks[vi].set_clips(vec![under]);
        let before = u.clone();
        assert_eq!(cut(&mut u, s(4), &[]), Err(EditError::Collision));
        assert_eq!(u, before);
    }

    #[test]
    fn locked_tracks_are_refused() {
        let (mut t, _, _) = make(true, 5, 0);
        let up = t.tracks.iter().position(|x| x.kind == Audio && x.clips().is_empty()).unwrap();
        t.tracks[up].is_locked = true;
        let before = t.clone();
        assert_eq!(cut(&mut t, s(4), &[]), Err(EditError::TrackLocked));
        assert_eq!(t, before);

        let (mut u, _, _) = make(true, 5, 0);
        for x in u.tracks.iter_mut().filter(|x| !x.clips().is_empty()) {
            x.is_locked = true;
        }
        assert_eq!(cut(&mut u, s(4), &[]), Err(EditError::TrackLocked));

        // A linked partner on a locked track refuses the whole cut.
        let (mut w, _, _) = make(true, 5, 0);
        let ai = w.tracks.iter().position(|x| x.kind == Audio && !x.clips().is_empty()).unwrap();
        (w.tracks[ai].is_locked, w.tracks[ai].is_targeted) = (true, false);
        assert_eq!(cut(&mut w, s(4), &[]), Err(EditError::TrackLocked));
    }

    #[test]
    fn missing_alternate_tracks_are_created_and_zero_overlap_is_a_hard_cut() {
        let (mut t, _, _) = make(false, 5, 0);
        cut(&mut t, s(4), &[]).unwrap();
        assert_eq!(t.tracks.iter().filter(|x| x.kind == Video).count(), 2);
        assert_eq!(t.tracks.iter().filter(|x| x.kind == Audio).count(), 2);
        assert_eq!((track_of(&t, Video, 1).clips().len(), track_of(&t, Audio, 1).clips().len()), (1, 1));

        let (mut u, _, _) = make(true, 5, 0);
        u.jump_cut_alternate(s(4), &BTreeSet::new(), 0, &mut ids()).unwrap();
        assert_eq!(track_of(&u, Video, 1).clips()[0].start, s(4));
        assert_eq!(track_of(&u, Audio, 0).clips()[0].audio_fade_out(), Time::ZERO);
        assert_eq!(track_of(&u, Audio, 1).clips()[0].audio_fade_in(), Time::ZERO);
    }

    #[test]
    fn nothing_under_the_playhead_and_a_second_press_are_refused() {
        let (mut t, _, _) = make(true, 5, 0);
        assert_eq!(cut(&mut t, s(20), &[]), Err(EditError::ClipNotFound));
        assert_eq!(cut(&mut t, Time::ZERO, &[]), Err(EditError::ClipNotFound));
        let moved = cut(&mut t, s(4), &[]).unwrap();
        let after = t.clone();
        let moved_set: BTreeSet<Id> = moved.iter().copied().collect();
        assert!(t.jump_cut_candidates(s(4), &moved_set).is_empty());
        assert!(t.jump_cut_candidates(s(4), &BTreeSet::new()).is_empty());
        assert!(t.is_jump_cut(s(4), &moved_set));
        assert_eq!(cut(&mut t, s(4), &moved), Err(EditError::ClipNotFound));
        assert_eq!(cut(&mut t, s(4), &[]), Err(EditError::ClipNotFound));
        assert_eq!(t, after);
        // A little later it cuts again.
        assert!(!t.jump_cut_candidates(s(4) + f(1), &BTreeSet::new()).is_empty());
    }

    #[test]
    fn without_a_selection_the_take_on_the_alternate_track_is_found() {
        let (mut t, v, _) = make(true, 5, 0);
        cut(&mut t, s(4), &[]).unwrap();
        // Nothing selected, V1/A1 targeted but empty at 7 s: their pair partners V2/A2 hold the take.
        let back = cut(&mut t, s(7), &[]).unwrap();
        assert_eq!(back.len(), 2);
        let v1 = track_of(&t, Video, 0);
        assert_eq!((v1.clips().len(), v1.clips()[0].id, v1.clips()[1].start), (2, v.id, s(7) - f(9)));
        assert_eq!(track_of(&t, Audio, 0).clips().len(), 2);
    }

    #[test]
    fn the_tail_fade_transition_moves_with_the_rest() {
        let (mut t, v, _) = make(true, 5, 0);
        let vi = t.tracks.iter().position(|x| x.clip(v.id).is_some()).unwrap();
        t.tracks[vi].transitions = vec![dissolve(Id::from_u128(9001), Some(v.id), None)];
        let moved = cut(&mut t, s(4), &[]).unwrap();
        assert!(t.tracks[vi].transitions.is_empty());
        let v2 = track_of(&t, Video, 1);
        assert_eq!(v2.transitions.len(), 1);
        assert!(v2.transitions[0].outgoing.is_some_and(|o| moved.contains(&o)));
    }

    #[test]
    fn dual_mono_moves_both_channels_to_the_next_audio_pair_and_back() {
        let l = fx_link();
        let m = Id::from_u128(7100);
        let mk = |kind, name: &str| {
            let mut c = fx_clip(0, 10, 5, kind, Some(l), Some(60));
            c.media = m;
            c.name = name.into();
            c
        };
        let (mut v1, mut a1, a2) = (
            Track::new(Id::from_u128(7201), Video),
            Track::new(Id::from_u128(7202), Audio),
            Track::new(Id::from_u128(7203), Audio),
        );
        (v1.is_targeted, a1.is_targeted) = (true, true);
        v1.set_clips(vec![mk(Video, "take")]);
        a1.set_clips(vec![mk(Audio, "L")]);
        let mut a2 = a2;
        a2.set_clips(vec![mk(Audio, "R")]);
        let mut t = fx_timeline(vec![v1, Track::new(Id::from_u128(7204), Video), a1, a2]);
        let moved = cut(&mut t, s(4), &[]).unwrap();
        assert_eq!(moved.len(), 3);
        assert_eq!(t.tracks.iter().filter(|x| x.kind == Audio).count(), 4); // A3 + A4 created
        let names = |tr: &Track| tr.clips().iter().map(|c| c.name.clone()).collect::<Vec<_>>();
        let (a3, a4) = (track_of(&t, Audio, 2), track_of(&t, Audio, 3));
        assert_eq!((names(a3), names(a4)), (vec!["L".to_string()], vec!["R".to_string()])); // channel order kept
        assert_eq!(a3.clips()[0].start, s(4) - f(9));
        assert_eq!(a4.clips()[0].start, a3.clips()[0].start);
        assert_eq!(track_of(&t, Video, 1).clips()[0].start, a3.clips()[0].start);
        assert_eq!(a3.clips()[0].link, track_of(&t, Video, 1).clips()[0].link);
        assert_eq!(track_of(&t, Audio, 0).clips()[0].audio_fade_out(), f(9));
        assert_eq!(track_of(&t, Audio, 1).clips()[0].audio_fade_out(), f(9));

        let back = cut(&mut t, s(7), &moved).unwrap();
        assert_eq!(back.len(), 3);
        assert_eq!(names(track_of(&t, Audio, 0)), ["L", "L"]);
        assert_eq!(names(track_of(&t, Audio, 1)), ["R", "R"]);
        assert_eq!(track_of(&t, Video, 0).clips().len(), 2);
    }
}
