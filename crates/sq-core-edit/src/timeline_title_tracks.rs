// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline+TitleTracks.swift

use crate::timeline_add_track::AddTrackExt;
use sq_core_model::{Timeline, Track, TrackKind};
use sq_core_time::{Id, IdSource, TimeRange};

/// Tracks for titles.
pub trait TimelineTitleTracksExt {
    /// `count` video tracks for a title (lines and emoji, one clip each), bottom to top: the unlocked tracks above the
    /// highest video track that has a clip over `range`, free over it; new video tracks go on top for the rest. Never
    /// overwrites anything.
    fn stacked_title_tracks(&mut self, count: usize, range: TimeRange, ids: &mut dyn IdSource) -> Vec<Id>;
}

impl TimelineTitleTracksExt for Timeline {
    fn stacked_title_tracks(&mut self, count: usize, range: TimeRange, ids: &mut dyn IdSource) -> Vec<Id> {
        if count == 0 {
            return Vec::new();
        }
        let over = |t: &Track| t.clips().iter().any(|c| c.timeline().overlaps(&range));
        let mut out: Vec<Id> = {
            let video: Vec<&Track> = self.tracks.iter().filter(|t| t.kind == TrackKind::Video).collect();
            let busy = video.iter().rposition(|t| over(t));
            let above = &video[busy.map_or(0, |b| b + 1)..];
            above.iter().filter(|t| !t.is_locked && !over(t)).take(count).map(|t| t.id).collect()
        };
        while out.len() < count {
            out.push(self.add_track(TrackKind::Video, ids));
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::*;
    use sq_core_model::TrackKind::Video;
    use sq_core_time::{SequentialIds, Time};

    fn range() -> TimeRange {
        TimeRange::new(Time::ZERO, s(3))
    }

    fn video_ids(t: &Timeline) -> Vec<Id> {
        t.tracks.iter().filter(|x| x.kind == Video).map(|x| x.id).collect()
    }

    fn with_video(n: usize) -> Timeline {
        timeline((0..n).map(|_| track(Video, vec![])).collect())
    }

    #[test]
    fn free_tracks_above_the_talking_head() {
        let mut t = with_video(4);
        t.tracks[0].set_clips(vec![v(0, 10)]);
        let ids = t.stacked_title_tracks(3, range(), &mut SequentialIds::default());
        assert_eq!(ids, video_ids(&t)[1..=3]);
        assert_eq!(t.tracks.len(), 4);
    }

    #[test]
    fn missing_tracks_are_added_on_top() {
        let mut t = with_video(2);
        t.tracks[0].set_clips(vec![v(0, 10)]);
        let ids = t.stacked_title_tracks(3, range(), &mut SequentialIds::default());
        let all = video_ids(&t);
        assert_eq!(all.len(), 4);
        assert_eq!(ids, [all[1], all[2], all[3]]);
    }

    #[test]
    fn busy_and_locked_tracks_are_skipped() {
        let mut t = with_video(5);
        t.tracks[0].set_clips(vec![v(0, 10)]);
        t.tracks[2].set_clips(vec![v(1, 1)]); // b-roll on V3 over the range
        t.tracks[3].is_locked = true;
        let ids = t.stacked_title_tracks(2, range(), &mut SequentialIds::default());
        let all = video_ids(&t);
        // Above V3 (the highest busy track): V4 is locked, V5 is free, one new track on top.
        assert_eq!(ids, [all[4], all[5]]);
    }

    #[test]
    fn clips_outside_the_range_do_not_count() {
        let mut t = with_video(3);
        t.tracks[2].set_clips(vec![v(20, 1)]);
        let ids = t.stacked_title_tracks(2, range(), &mut SequentialIds::default());
        assert_eq!(ids, video_ids(&t)[0..=1]);
    }

    #[test]
    fn zero_count_changes_nothing() {
        let mut t = with_video(1);
        assert!(t.stacked_title_tracks(0, range(), &mut SequentialIds::default()).is_empty());
        assert_eq!(t.tracks.len(), 1);
    }
}
