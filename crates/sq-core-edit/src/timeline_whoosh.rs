// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline+Whoosh.swift

use sq_core_model::{Clip, ClipEdge, EditError, Timeline, TrackKind};
use sq_core_time::{Id, IdSource, Time};
use std::collections::BTreeSet;

use crate::timeline_add_track::AddTrackExt;

/// Cuts and the "Whoosh at selected cuts" placement.
pub trait TimelineWhooshExt {
    /// Cut times (a clip ends where another starts on the same track) touching any of `ids`, sorted, without duplicates.
    fn cuts_of_clips(&self, ids: &BTreeSet<Id>) -> Vec<Time>;

    /// The time of `edge` of clip `id` when a neighbor touches it there (a cut); `None` otherwise.
    fn cut_time_of_clip(&self, id: Id, edge: ClipEdge) -> Option<Time>;

    /// "Whoosh at selected cuts": one copy of the audio clip `proto` per cut, centered on it (clamped to the sequence
    /// start, snapped to the frame grid), each on the first unlocked audio track that is free over its range; a new audio
    /// track when none is. Copies get fresh ids and no link. Atomic, so one undo step. Returns the new clip ids in cut
    /// order.
    fn place_centred(&mut self, proto: &Clip, cuts: &[Time], ids: &mut dyn IdSource) -> Result<Vec<Id>, EditError>;
}

impl TimelineWhooshExt for Timeline {
    fn cuts_of_clips(&self, ids: &BTreeSet<Id>) -> Vec<Time> {
        let mut out: BTreeSet<Time> = BTreeSet::new();
        for tr in &self.tracks {
            for c in tr.clips().iter().filter(|c| ids.contains(&c.id)) {
                if tr.clips().iter().any(|o| o.start == c.timeline().end()) {
                    out.insert(c.timeline().end());
                }
                if tr.clips().iter().any(|o| o.timeline().end() == c.start) {
                    out.insert(c.start);
                }
            }
        }
        out.into_iter().collect()
    }

    fn cut_time_of_clip(&self, id: Id, edge: ClipEdge) -> Option<Time> {
        let c = self.find(id)?.clip;
        let at = if edge == ClipEdge::Head { c.start } else { c.timeline().end() };
        self.cuts_of_clips(&BTreeSet::from([id])).contains(&at).then_some(at)
    }

    fn place_centred(&mut self, proto: &Clip, cuts: &[Time], ids: &mut dyn IdSource) -> Result<Vec<Id>, EditError> {
        if proto.kind != TrackKind::Audio {
            return Err(EditError::WrongTrackKind);
        }
        let sorted: BTreeSet<Time> = cuts.iter().copied().collect();
        if sorted.is_empty() || proto.duration() <= Time::ZERO {
            return Err(EditError::ClipNotFound);
        }
        let mut work = self.clone();
        let mut placed: Vec<Id> = Vec::new();
        let half = proto.duration().halved();
        for cut in sorted {
            let mut c = proto.clone();
            c.id = ids.next_id();
            c.link = None;
            c.bundle = None;
            c.attachment = None;
            let at = cut - half;
            c.start = (if at < Time::ZERO { Time::ZERO } else { at }).snapped(self.frame_duration());
            let range = c.timeline();
            let free = |t: &sq_core_model::Track| {
                t.kind == TrackKind::Audio && !t.is_locked && !t.clips().iter().any(|o| o.timeline().overlaps(&range))
            };
            let target = match work.tracks.iter().position(free) {
                Some(i) => i,
                None => {
                    work.add_track(TrackKind::Audio, ids);
                    work.tracks.len() - 1
                }
            };
            let new_id = c.id;
            work.tracks[target].overwrite(c, ids)?;
            placed.push(new_id);
        }
        *self = work;
        Ok(placed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::*;
    use sq_core_model::Track;
    use sq_core_model::TrackKind::{Audio, Video};
    use sq_core_time::SequentialIds;

    fn sfx(dur: i64) -> Clip {
        a(0, dur)
    }

    #[test]
    fn centres_on_each_cut_on_a_free_track() {
        let mut tl = timeline(vec![track(Video, vec![v(0, 10), v(10, 10)]), track(Audio, vec![a(0, 20)])]);
        let ids = tl.place_centred(&sfx(2), &[s(10)], &mut SequentialIds::default());
        assert_eq!(ids.as_ref().map(Vec::len), Ok(1));
        assert_eq!(tl.tracks.len(), 3); // A1 is busy: a new audio track
        let c = &tl.tracks[2].clips()[0];
        assert_eq!((c.start, c.duration()), (s(9), s(2)));
        assert_eq!(c.link, None);
    }

    #[test]
    fn reuses_a_free_track_and_packs_several_cuts() {
        let mut tl = timeline(vec![track(Audio, vec![a(0, 30)]), track(Audio, vec![])]);
        let ids = tl.place_centred(&sfx(2), &[s(10), s(20)], &mut SequentialIds::default());
        assert_eq!(ids.as_ref().map(Vec::len), Ok(2));
        assert_eq!(tl.tracks.len(), 2);
        assert_eq!(tl.tracks[1].clips().iter().map(|c| c.start).collect::<Vec<_>>(), [s(9), s(19)]);
    }

    #[test]
    fn close_cuts_spill_to_a_second_track() {
        let mut tl = timeline(vec![track(Audio, vec![])]);
        assert!(tl.place_centred(&sfx(4), &[s(10), s(11)], &mut SequentialIds::default()).is_ok());
        assert_eq!(tl.tracks.len(), 2);
        assert!(tl.tracks.iter().all(Track::is_consistent));
    }

    #[test]
    fn clamps_to_the_sequence_start() {
        let mut tl = timeline(vec![track(Audio, vec![])]);
        assert!(tl.place_centred(&sfx(4), &[s(1)], &mut SequentialIds::default()).is_ok());
        assert_eq!(tl.tracks[0].clips()[0].start, Time::ZERO);
    }

    #[test]
    fn skips_locked_tracks_and_never_touches_video() {
        let mut tl = timeline(vec![track(Video, vec![]), locked(track(Audio, vec![]))]);
        assert!(tl.place_centred(&sfx(2), &[s(5)], &mut SequentialIds::default()).is_ok());
        assert!(tl.tracks[0].clips().is_empty() && tl.tracks[1].clips().is_empty());
        assert_eq!(tl.tracks[2].clips().len(), 1);
    }

    #[test]
    fn a_video_clip_or_no_cuts_is_refused() {
        let mut tl = timeline(vec![track(Audio, vec![])]);
        let mut ids = SequentialIds::default();
        assert!(tl.place_centred(&v(0, 2), &[s(5)], &mut ids).is_err());
        assert!(tl.place_centred(&sfx(2), &[], &mut ids).is_err());
    }

    #[test]
    fn cuts_of_selected_clips_find_touching_pairs() {
        let (x, b, c) = (v(0, 10), v(10, 10), v(25, 5));
        let tl = timeline(vec![track(Video, vec![x.clone(), b.clone(), c.clone()])]);
        assert_eq!(tl.cuts_of_clips(&BTreeSet::from([x.id])), [s(10)]);
        assert_eq!(tl.cuts_of_clips(&BTreeSet::from([x.id, b.id])), [s(10)]);
        assert!(tl.cuts_of_clips(&BTreeSet::from([c.id])).is_empty());
        assert_eq!(tl.cut_time_of_clip(b.id, ClipEdge::Head), Some(s(10)));
        assert_eq!(tl.cut_time_of_clip(b.id, ClipEdge::Tail), None);
    }
}
