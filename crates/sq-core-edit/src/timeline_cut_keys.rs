// Swift: Timeline+CutKeys.swift
//! Fast manual cutting: Cut Out, piece between two edits, J / L cut by direction.

use crate::timeline_clipboard::TimelineClipboardExt as _;
use crate::timeline_range_edits::TimelineRangeEditsExt as _;
use crate::timeline_split_edit::{SplitEditSide, TimelineSplitEditExt};
use sq_core_model::{EditError, Timeline, TrackKind};
use sq_core_time::{Id, IdSource, Time, TimeRange};

/// J cut: the next clip's audio starts before its picture. L cut: the previous clip's audio runs on over the next picture.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum JLCut {
    /// Next clip's audio starts early.
    JCut,
    /// Previous clip's audio runs on.
    LCut,
}

/// What one press of Cut Out does: the first press marks the start, the next one extracts start..playhead.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CutOutStep {
    /// Remember this time as the start of the span.
    MarkStart(Time),
    /// Extract this span.
    Extract(TimeRange),
}

/// Cut Out: `pending` is the start marked by the previous press (`None` = none). A press at or before the start begins
/// a new span instead.
pub fn cut_out_step(pending: Option<Time>, playhead: Time) -> CutOutStep {
    match pending {
        Some(p) if playhead > p => CutOutStep::Extract(TimeRange::from_end(p, playhead)),
        _ => CutOutStep::MarkStart(playhead),
    }
}

/// `extension Timeline` of Timeline+CutKeys.swift.
pub trait TimelineCutKeysExt {
    /// The clips that start and end exactly at the two edit points (either order): the "piece" between two cuts.
    fn clips_between(&self, a: Time, b: Time) -> Vec<Id>;

    /// One key to close the gap under `t`: every unlocked track that has a gap there closes the part they all share, in
    /// one ripple (later clips on those tracks and sync-locked tracks move left). Returns the time closed; zero (nothing
    /// changed) when no track has a gap at `t`.
    fn close_gaps_at_playhead(&mut self, t: Time, ids: &mut dyn IdSource) -> Result<Time, EditError>;
    /// J / L cut by direction (plain-key command): the audio edit of the nearest cut AHEAD of `t` (J) or BEHIND it (L)
    /// moves to `t`, as a roll (`split_edit`). `ClipNotFound` when there is no such cut.
    fn split_edit_jl(&mut self, kind: JLCut, t: Time) -> Result<Time, EditError>;
}

impl TimelineCutKeysExt for Timeline {
    fn close_gaps_at_playhead(&mut self, t: Time, ids: &mut dyn IdSource) -> Result<Time, EditError> {
        let mut targets: Vec<Id> = Vec::new();
        let mut shared: Option<TimeRange> = None;
        for tr in self.tracks.iter().filter(|t| !t.is_locked) {
            let Some(g) = self.gap(tr.id, t) else { continue };
            targets.push(tr.id);
            shared = Some(match shared {
                Some(s) => TimeRange::from_end(s.start.max(g.start), s.end().min(g.end())),
                None => g,
            });
        }
        match shared {
            Some(r) if !r.is_empty() && !targets.is_empty() => self.extract(r, &targets, ids),
            _ => Ok(Time::ZERO),
        }
    }

    fn clips_between(&self, a: Time, b: Time) -> Vec<Id> {
        let (lo, hi) = (a.min(b), a.max(b));
        self.tracks
            .iter()
            .flat_map(|t| t.clips())
            .filter(|c| c.start == lo && c.timeline().end() == hi)
            .map(|c| c.id)
            .collect()
    }

    fn split_edit_jl(&mut self, kind: JLCut, t: Time) -> Result<Time, EditError> {
        let mut best: Option<Time> = None;
        for tr in self.tracks.iter().filter(|tr| tr.kind == TrackKind::Audio && !tr.is_locked) {
            for c in tr.clips().iter().filter(|c| tr.clips().iter().any(|o| o.start == c.timeline().end())) {
                let cut = c.timeline().end();
                if !(if kind == JLCut::JCut { cut > t } else { cut < t }) {
                    continue;
                }
                if best.is_none_or(|b| if kind == JLCut::JCut { cut < b } else { cut > b }) {
                    best = Some(cut);
                }
            }
        }
        let cut = best.ok_or(EditError::ClipNotFound)?;
        self.split_edit(cut, SplitEditSide::Audio, t, None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{Clip, SequenceFormat, Track};
    use sq_core_time::SequentialIds;

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    /// V1 + A1 with the given (start, length) pairs, same on both.
    fn make(spans: &[(i64, i64)]) -> Timeline {
        let mut v = Track::new(Id::from_u128(10), TrackKind::Video);
        let mut a = Track::new(Id::from_u128(11), TrackKind::Audio);
        let (mut vc, mut ac) = (Vec::new(), Vec::new());
        for (i, (st, len)) in spans.iter().enumerate() {
            let n = 100 + i as u128 * 2;
            for (kind, list, id) in [(TrackKind::Video, &mut vc, n), (TrackKind::Audio, &mut ac, n + 1)] {
                let mut c = Clip::new(
                    Id::from_u128(id),
                    "c",
                    Id::from_u128(id + 5000),
                    kind,
                    TimeRange::new(s(5), s(*len)),
                    s(*st),
                );
                c.link = Some(Id::from_u128(900 + i as u128));
                c.media_duration = Some(s(60));
                list.push(c);
            }
        }
        v.set_clips(vc);
        a.set_clips(ac);
        Timeline::new(Id::from_u128(500), "T", SequenceFormat::new(Time::new(1, 30)), vec![v, a])
    }
    fn starts(t: &Timeline, i: usize) -> Vec<Time> {
        t.tracks[i].clips().iter().map(|c| c.start).collect()
    }

    #[test]
    fn cut_out_first_press_marks_start() {
        assert_eq!(cut_out_step(None, s(3)), CutOutStep::MarkStart(s(3)));
    }

    #[test]
    fn cut_out_second_press_extracts_span() {
        assert_eq!(cut_out_step(Some(s(3)), s(5)), CutOutStep::Extract(TimeRange::from_end(s(3), s(5))));
    }

    #[test]
    fn cut_out_second_press_at_or_before_start_restarts() {
        assert_eq!(cut_out_step(Some(s(3)), s(3)), CutOutStep::MarkStart(s(3)));
        assert_eq!(cut_out_step(Some(s(3)), s(2)), CutOutStep::MarkStart(s(2)));
    }

    #[test]
    fn j_cut_pulls_the_next_audio_edit_back_to_the_playhead() {
        let mut t = make(&[(0, 10), (10, 10)]);
        assert_eq!(t.split_edit_jl(JLCut::JCut, s(8)), Ok(s(-2)));
        assert_eq!(starts(&t, 0), vec![s(0), s(10)]); // video stays
        assert_eq!(starts(&t, 1), vec![s(0), s(8)]);
    }

    #[test]
    fn l_cut_lets_the_previous_audio_run_on_to_the_playhead() {
        let mut t = make(&[(0, 10), (10, 10)]);
        assert_eq!(t.split_edit_jl(JLCut::LCut, s(12)), Ok(s(2)));
        assert_eq!(starts(&t, 1), vec![s(0), s(12)]);
        assert_eq!(starts(&t, 0), vec![s(0), s(10)]);
    }

    #[test]
    fn j_cut_picks_the_nearest_cut_ahead_not_behind() {
        let mut t = make(&[(0, 10), (10, 10), (20, 10)]);
        assert!(t.split_edit_jl(JLCut::JCut, s(18)).is_ok());
        assert_eq!(starts(&t, 1), vec![s(0), s(10), s(18)]);
    }

    #[test]
    fn j_cut_with_no_cut_ahead_fails() {
        let mut t = make(&[(0, 10), (10, 10)]);
        assert_eq!(t.split_edit_jl(JLCut::JCut, s(12)), Err(EditError::ClipNotFound));
        assert_eq!(t.split_edit_jl(JLCut::LCut, s(5)), Err(EditError::ClipNotFound));
    }

    #[test]
    fn clips_between_two_edits_match_start_and_end_in_either_order() {
        let t = make(&[(3, 4)]);
        assert_eq!(t.clips_between(s(3), s(7)).len(), 2);
        assert_eq!(t.clips_between(s(7), s(3)).len(), 2);
        assert!(t.clips_between(s(3), s(8)).is_empty());
    }

    #[test]
    fn closes_the_gap_on_all_tracks_at_once() {
        let mut t = make(&[(0, 4), (6, 4)]);
        assert_eq!(t.close_gaps_at_playhead(s(5), &mut SequentialIds::default()), Ok(s(2)));
        assert_eq!(starts(&t, 0), [s(0), s(4)]);
        assert_eq!(starts(&t, 1), [s(0), s(4)]);
    }

    #[test]
    fn no_gap_under_the_playhead_does_nothing() {
        let mut t = make(&[(0, 4), (6, 4)]);
        let before = t.clone();
        assert_eq!(t.close_gaps_at_playhead(s(2), &mut SequentialIds::default()), Ok(Time::ZERO));
        assert_eq!(t, before);
    }

    #[test]
    fn a_locked_track_keeps_its_gap() {
        let mut t = make(&[(0, 4), (6, 4)]);
        t.tracks[1].is_locked = true;
        t.close_gaps_at_playhead(s(5), &mut SequentialIds::default()).unwrap();
        assert_eq!(starts(&t, 0), [s(0), s(4)]);
        assert_eq!(starts(&t, 1), [s(0), s(6)]);
    }

    #[test]
    fn pieces_between_two_edits_are_the_middle_clips() {
        use crate::timeline_three_point::TimelineThreePointExt as _;
        let mut t = make(&[(0, 10)]);
        let mut ids = SequentialIds::default();
        t.add_edit(s(3), None, &mut ids).unwrap();
        t.add_edit(s(7), None, &mut ids).unwrap();
        let found = t.clips_between(s(3), s(7));
        assert_eq!(found.len(), 2);
        for id in found {
            let c = t.find(id).map(|m| m.clip).unwrap();
            assert_eq!((c.start, c.timeline().end()), (s(3), s(7)));
        }
        assert!(t.clips_between(s(3), s(8)).is_empty());
        assert_eq!(t.clips_between(s(7), s(3)).len(), 2); // order of the two points does not matter
    }
}
