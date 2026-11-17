// Swift: Timeline+SplitEdit.swift
//! Split edit (J / L cut): moves only the audio or only the video edit point of a cut.

use sq_core_model::{EditError, Timeline, TrackKind, floored_to_frame};
use sq_core_time::{Id, Time};

/// Which half of a linked A/V cut a split edit (J / L cut) moves.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SplitEditSide {
    /// The sound edit point.
    Audio,
    /// The picture edit point.
    Video,
}

impl SplitEditSide {
    fn track_kind(self) -> TrackKind {
        if self == SplitEditSide::Audio { TrackKind::Audio } else { TrackKind::Video }
    }
}

/// `extension Timeline` of Timeline+SplitEdit.swift.
pub trait TimelineSplitEditExt {
    /// The cut (a clip ending where another starts on the same track) on the side's tracks nearest to `t`; `tracks`
    /// limits the search (`None` = every unlocked track of that kind). `None` when there is none.
    fn nearest_cut(&self, t: Time, side: SplitEditSide, tracks: Option<&[Id]>) -> Option<Time>;
    /// Split edit (J / L cut): moves only the audio or only the video edit point of the cut at `cut` to `t`, as a roll on
    /// every unlocked track of that kind that has a cut there (or on `tracks` only), so the sequence length and everything
    /// later stay put (ripple-safe). The partner side keeps its edit: video at 10 s and audio at 8 s is a J-cut, audio at
    /// 12 s an L-cut. Clamped by media handles and to one frame left on each side; returns the applied move of the cut
    /// (negative = earlier). `ClipNotFound` when no track has a cut at `cut`, `TrackLocked` when all candidates are locked.
    fn split_edit(
        &mut self,
        cut: Time,
        side: SplitEditSide,
        to: Time,
        tracks: Option<&[Id]>,
    ) -> Result<Time, EditError>;
}

impl TimelineSplitEditExt for Timeline {
    fn nearest_cut(&self, t: Time, side: SplitEditSide, tracks: Option<&[Id]>) -> Option<Time> {
        let dist = |a: Time| if a > t { a - t } else { t - a };
        let mut best: Option<Time> = None;
        for tr in self
            .tracks
            .iter()
            .filter(|tr| tr.kind == side.track_kind() && !tr.is_locked && tracks.is_none_or(|ids| ids.contains(&tr.id)))
        {
            for c in tr.clips().iter().filter(|c| tr.clips().iter().any(|o| o.start == c.timeline().end())) {
                let cut = c.timeline().end();
                if best.is_none_or(|b| dist(cut) < dist(b)) {
                    best = Some(cut);
                }
            }
        }
        best
    }

    fn split_edit(
        &mut self,
        cut: Time,
        side: SplitEditSide,
        to: Time,
        tracks: Option<&[Id]>,
    ) -> Result<Time, EditError> {
        let mut rows = Vec::new();
        let mut locked_hit = false;
        for (i, tr) in self.tracks.iter().enumerate() {
            if tr.kind != side.track_kind() || !tracks.is_none_or(|ids| ids.contains(&tr.id)) {
                continue;
            }
            let (Some(l), Some(r)) =
                (tr.clips().iter().find(|c| c.timeline().end() == cut), tr.clips().iter().find(|c| c.start == cut))
            else {
                continue;
            };
            if tr.is_locked {
                locked_hit = true;
                continue;
            }
            rows.push((i, l.clone(), r.clone()));
        }
        if rows.is_empty() {
            return Err(if locked_hit { EditError::TrackLocked } else { EditError::ClipNotFound });
        }
        let mut d = to - cut;
        let fd = self.frame_duration();
        for (_, left, right) in &rows {
            if d > Time::ZERO {
                if let Some(room) = left.tail_room().map(|r| floored_to_frame(r, fd)) {
                    d = d.min(room);
                }
                d = d.min((right.duration() - right.minimum_duration(fd)).max(Time::ZERO));
            } else if d < Time::ZERO {
                if let Some(h) = right.head_handle().map(|h| floored_to_frame(h, fd)) {
                    d = d.max(Time::ZERO - h);
                }
                d = d.max((left.minimum_duration(fd) - left.duration()).min(Time::ZERO));
            }
        }
        if d == Time::ZERO {
            return Ok(Time::ZERO);
        }
        let mut work = self.tracks.clone();
        for (i, left, right) in rows {
            let (mut l, mut rt) = (left, right);
            l.extend_tail(d);
            rt.start += d;
            rt.extend_head(Time::ZERO - d);
            work[i].replace(l);
            work[i].replace(rt);
        }
        if !work.iter().all(|t| t.is_consistent()) {
            return Err(EditError::Collision);
        }
        self.tracks = work;
        Ok(d)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{Clip, SequenceFormat, Track};
    use sq_core_time::TimeRange;

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }
    fn clip(n: u128, start: i64, dur: i64, kind: TrackKind, link: u128) -> Clip {
        let mut c =
            Clip::new(Id::from_u128(n), "c", Id::from_u128(n + 5000), kind, TimeRange::new(s(5), s(dur)), s(start));
        c.link = Some(Id::from_u128(link));
        c
    }
    fn track(n: u128, kind: TrackKind, clips: Vec<Clip>) -> Track {
        let mut t = Track::new(Id::from_u128(n), kind);
        t.set_clips(clips);
        t
    }
    /// V1 and A1 both cut at 10 s (video 0-10 | 10-20, audio the same), linked per side.
    fn fixture() -> Timeline {
        Timeline::new(
            Id::from_u128(500),
            "t",
            SequenceFormat::new(Time::new(1, 30)),
            vec![
                track(
                    10,
                    TrackKind::Video,
                    vec![clip(1, 0, 10, TrackKind::Video, 91), clip(2, 10, 10, TrackKind::Video, 92)],
                ),
                track(
                    11,
                    TrackKind::Audio,
                    vec![clip(3, 0, 10, TrackKind::Audio, 91), clip(4, 10, 10, TrackKind::Audio, 92)],
                ),
            ],
        )
    }
    fn starts(t: &Timeline, i: usize) -> Vec<Time> {
        t.tracks[i].clips().iter().map(|c| c.start).collect()
    }

    #[test]
    fn audio_leads_the_cut_and_video_stays_put() {
        let mut t = fixture();
        assert_eq!(t.split_edit(s(10), SplitEditSide::Audio, s(8), None), Ok(s(-2)));
        assert_eq!(starts(&t, 0), vec![s(0), s(10)]);
        assert_eq!(t.tracks[0].clips().iter().map(|c| c.duration()).collect::<Vec<_>>(), vec![s(10), s(10)]);
        assert_eq!(starts(&t, 1), vec![s(0), s(8)]);
        assert_eq!(t.tracks[1].clips().iter().map(|c| c.duration()).collect::<Vec<_>>(), vec![s(8), s(12)]);
        // Source follows the head: the later clip starts 2 s earlier in the media.
        assert_eq!(t.tracks[1].clips()[1].source.start, s(3));
        assert!(t.tracks[1].clips().iter().all(|c| c.link.is_some()));
    }

    #[test]
    fn audio_trails_the_cut() {
        let mut t = fixture();
        assert!(t.split_edit(s(10), SplitEditSide::Audio, s(12), None).is_ok());
        assert_eq!(starts(&t, 1), vec![s(0), s(12)]);
        assert_eq!(t.tracks[1].clips()[0].duration(), s(12));
        assert_eq!(starts(&t, 0), vec![s(0), s(10)]);
    }

    #[test]
    fn video_side_moves_only_video() {
        let mut t = fixture();
        assert!(t.split_edit(s(10), SplitEditSide::Video, s(11), None).is_ok());
        assert_eq!(starts(&t, 0), vec![s(0), s(11)]);
        assert_eq!(starts(&t, 1), vec![s(0), s(10)]);
    }

    #[test]
    fn sequence_length_and_consistency_hold() {
        let mut t = fixture();
        let ends = |t: &Timeline| t.tracks.iter().map(|tr| tr.end()).collect::<Vec<_>>();
        let before = ends(&t);
        assert!(t.split_edit(s(10), SplitEditSide::Audio, s(7), None).is_ok());
        assert_eq!(ends(&t), before);
        assert!(t.tracks.iter().all(|tr| tr.is_consistent()));
    }

    #[test]
    fn clamped_by_the_media_handle() {
        let mut t = fixture(); // later clip has 5 s of head media
        assert_eq!(t.split_edit(s(10), SplitEditSide::Audio, s(2), None), Ok(s(-5)));
        assert_eq!(t.tracks[1].clips()[1].start, s(5));
    }

    #[test]
    fn clamped_keeps_a_frame_on_the_other_side() {
        let mut t = fixture();
        let fd = t.frame_duration();
        let moved = t.split_edit(s(10), SplitEditSide::Audio, s(30), None);
        assert!(moved.is_ok_and(|m| m < s(10)));
        assert!(t.tracks[1].clips()[1].duration() >= fd);
    }

    #[test]
    fn no_cut_on_that_side_fails_and_changes_nothing() {
        let mut t = fixture();
        let before = t.clone();
        assert!(t.split_edit(s(5), SplitEditSide::Audio, s(6), None).is_err());
        assert_eq!(t, before);
    }

    #[test]
    fn locked_track_refuses() {
        let mut t = fixture();
        t.tracks[1].is_locked = true;
        assert_eq!(t.split_edit(s(10), SplitEditSide::Audio, s(8), None), Err(EditError::TrackLocked));
    }

    #[test]
    fn nearest_cut_picks_the_closest_on_the_side() {
        let t = fixture();
        assert_eq!(t.nearest_cut(s(9), SplitEditSide::Audio, None), Some(s(10)));
        assert_eq!(t.nearest_cut(s(3), SplitEditSide::Video, None), Some(s(10)));
        assert_eq!(t.nearest_cut(s(3), SplitEditSide::Audio, Some(&[t.tracks[0].id])), None);
    }
}
