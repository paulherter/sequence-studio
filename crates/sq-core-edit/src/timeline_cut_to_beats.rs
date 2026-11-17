//! Port of `Timeline+CutToBeats.swift`: Cut to Beats / Snap to Beats, edits that use the beat markers as the grid.

use crate::timeline_beat_markers::BEAT_MARKER_NAME;
use crate::timeline_magnetic_verbs::MagneticVerbsExt as _;
use crate::timeline_three_point::TimelineThreePointExt as _;
use sq_core_model::{ClipEdge, EditError, Timeline};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use std::collections::BTreeSet;

/// `extension Timeline` of `Timeline+CutToBeats.swift`.
pub trait TimelineCutToBeatsExt {
    /// Beat marker times, sorted and unique.
    fn beat_times(&self) -> Vec<Time>;

    /// Cuts the given clips (and their linked partners' tracks) at every beat marker inside their span. Only the tracks the
    /// clips and their partners sit on are cut; other clips on those tracks outside the span stay whole. Beats on a clip
    /// edge or outside cut nothing. Returns the number of beats that produced a cut (0 leaves the timeline unchanged).
    fn cut_to_beats(&mut self, clips: &BTreeSet<Id>, ids: &mut dyn IdSource) -> Result<usize, EditError>;

    /// Moves the tail of each given clip to the nearest beat marker after its head, ripple-trimming (everything after
    /// shifts). Clips are processed left to right, each against the timeline as the earlier ripples left it. The beat grid
    /// keeps its absolute times: the markers do not ride the ripple. A tail the media or a neighbor does not let reach the
    /// beat moves as far as it can. Returns the number of clips whose tail moved.
    fn snap_to_beats(&mut self, clips: &[Id], ids: &mut dyn IdSource) -> Result<usize, EditError>;
}

impl TimelineCutToBeatsExt for Timeline {
    fn beat_times(&self) -> Vec<Time> {
        let set: BTreeSet<Time> = self.markers.iter().filter(|m| m.name == BEAT_MARKER_NAME).map(|m| m.time).collect();
        set.into_iter().collect()
    }

    fn cut_to_beats(&mut self, clips: &BTreeSet<Id>, ids: &mut dyn IdSource) -> Result<usize, EditError> {
        let mut span: Option<TimeRange> = None;
        let mut track_ids: Vec<Id> = Vec::new();
        for id in clips {
            for m in self.linked_group(*id)? {
                if self.tracks[m.track].is_locked {
                    return Err(EditError::TrackLocked);
                }
                let tid = self.tracks[m.track].id;
                if !track_ids.contains(&tid) {
                    track_ids.push(tid);
                }
                if clips.contains(&m.clip.id) {
                    let c = m.clip.timeline();
                    span = Some(match span {
                        Some(s) => TimeRange::from_end(s.start.min(c.start), s.end().max(c.end())),
                        None => c,
                    });
                }
            }
        }
        let Some(span) = span else { return Ok(0) };
        let mut work = self.clone();
        let mut cuts = 0;
        for b in self.beat_times().into_iter().filter(|b| *b > span.start && *b < span.end()) {
            // Only clips inside the selected span are cut: restrict to tracks, the span check above bounds the beats.
            if !work.add_edit(b, Some(&track_ids), ids)?.is_empty() {
                cuts += 1;
            }
        }
        if cuts > 0 {
            *self = work;
        }
        Ok(cuts)
    }

    fn snap_to_beats(&mut self, clips: &[Id], ids: &mut dyn IdSource) -> Result<usize, EditError> {
        let grid: Vec<_> = self.markers.iter().filter(|m| m.name == BEAT_MARKER_NAME).cloned().collect();
        let beats = self.beat_times();
        if beats.is_empty() {
            return Ok(0);
        }
        let mut order: Vec<_> = clips.iter().filter_map(|c| self.find(*c)).map(|m| m.clip).collect();
        order.sort_by_key(|c| c.start);
        let mut work = self.clone();
        let mut moved = 0;
        let fd = self.frame_duration();
        for id in order.iter().map(|c| c.id) {
            let Some(c) = work.find(id).map(|m| m.clip) else { continue };
            let end = c.timeline().end();
            let target = beats
                .iter()
                .copied()
                .filter(|b| *b >= c.start + fd)
                .min_by_key(|b| if *b > end { *b - end } else { end - *b });
            let Some(target) = target.filter(|t| *t != end) else { continue };
            // Fast Cut: V1 stays gapless.
            if work.magnetic_ripple_trim(id, ClipEdge::Tail, target - end, ids)? != Time::ZERO {
                moved += 1;
            }
        }
        if moved == 0 {
            return Ok(0);
        }
        work.markers.retain(|m| m.name != BEAT_MARKER_NAME);
        work.markers.extend(grid);
        *self = work;
        Ok(moved)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_beat_markers::TimelineBeatMarkersExt as _;
    use crate::timeline_edits::fixtures::*;
    use sq_core_model::TrackKind::{Audio, Video};
    use sq_core_time::SequentialIds;

    fn f(n: i64) -> Time {
        Time::new(n, 30)
    }

    fn video(start: i64, frames: i64) -> sq_core_model::Clip {
        let mut c = clip(0, 1, 0, Video, None, Some(6000));
        c.source = TimeRange::new(Time::ZERO, f(frames));
        c.start = f(start);
        c
    }

    fn with_beats(clips: Vec<sq_core_model::Clip>, beats: &[i64]) -> Timeline {
        let mut tl = timeline(vec![track(Video, clips)]);
        let times: Vec<Time> = beats.iter().map(|b| s(*b)).collect();
        tl.replace_beat_markers(TimeRange::new(Time::ZERO, s(100)), &times, &mut SequentialIds::default());
        tl
    }

    #[test]
    fn cuts_the_selected_clip_at_every_beat_inside_it() {
        let c = video(0, 300); // 0..10 s
        let mut tl = with_beats(vec![c.clone()], &[2, 4, 6, 10, 12]);
        assert_eq!(tl.cut_to_beats(&[c.id].into(), &mut SequentialIds::default()), Ok(3)); // 10 s is the end, 12 s outside
        let starts: Vec<Time> = tl.tracks[0].clips().iter().map(|c| c.start).collect();
        assert_eq!(starts, [Time::ZERO, s(2), s(4), s(6)]);
        assert!(tl.tracks[0].is_consistent());
        assert_eq!(tl.tracks[0].clips().last().map(|c| c.timeline().end()), Some(s(10)));
    }

    #[test]
    fn leaves_unselected_clips_alone() {
        let (a, b) = (video(0, 300), video(300, 300));
        let mut tl = with_beats(vec![a.clone(), b.clone()], &[5, 15]);
        assert_eq!(tl.cut_to_beats(&[a.id].into(), &mut SequentialIds::default()), Ok(1));
        assert_eq!(tl.tracks[0].clips().len(), 3);
        assert!(tl.tracks[0].clips().iter().any(|c| c.id == b.id && c.start == s(10)));
    }

    #[test]
    fn linked_audio_is_cut_with_the_video_and_no_beats_change_nothing() {
        let l = link();
        let mut v = video(0, 300);
        v.link = Some(l);
        let mut a = clip(0, 10, 0, Audio, Some(l), Some(6000));
        a.source = TimeRange::new(Time::ZERO, f(300));
        let mut tl = timeline(vec![track(Video, vec![v.clone()]), track(Audio, vec![a])]);
        tl.replace_beat_markers(TimeRange::new(Time::ZERO, s(100)), &[s(5)], &mut SequentialIds::default());
        tl.cut_to_beats(&[v.id].into(), &mut SequentialIds::default()).unwrap();
        assert_eq!((tl.tracks[0].clips().len(), tl.tracks[1].clips().len()), (2, 2));

        let c = video(0, 300);
        let mut plain = with_beats(vec![c.clone()], &[]);
        let before = plain.clone();
        assert_eq!(plain.cut_to_beats(&[c.id].into(), &mut SequentialIds::default()), Ok(0));
        assert_eq!(plain, before);
    }

    #[test]
    fn snap_moves_each_tail_to_the_nearest_beat_and_ripples() {
        let (a, b, c) = (video(0, 100), video(100, 100), video(200, 100));
        let mut tl = with_beats(vec![a.clone(), b.clone(), c], &[3, 7, 10]);
        assert_eq!(tl.snap_to_beats(&[a.id, b.id], &mut SequentialIds::default()), Ok(2));
        let cl = tl.tracks[0].clips();
        assert_eq!(cl[0].timeline().end(), s(3));
        assert_eq!((cl[1].start, cl[1].timeline().end()), (s(3), s(7)));
        assert_eq!(cl[2].start, s(7));
        assert!(tl.tracks[0].is_consistent());
        // The beat grid keeps its times: a ripple must not drag it off the music.
        assert_eq!(tl.beat_times(), [s(3), s(7), s(10)]);
    }

    #[test]
    fn snap_never_empties_a_clip() {
        let (a, b) = (video(0, 60), video(60, 60));
        let mut tl = timeline(vec![track(Video, vec![a.clone(), b])]);
        tl.replace_beat_markers(TimeRange::new(Time::ZERO, s(100)), &[f(0), f(1)], &mut SequentialIds::default());
        let _ = tl.snap_to_beats(&[a.id], &mut SequentialIds::default());
        assert!(tl.tracks[0].clips()[0].duration() >= Time::new(1, 30));
    }
}
