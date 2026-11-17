// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline+PlaceOnTop.swift

use crate::timeline_magnetic_ops::MagneticOpsExt;
use sq_core_model::{Timeline, Track, TrackKind};
use sq_core_time::{Id, Time, TimeRange};

/// Where "Place on Top" puts the media.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PlaceOnTopTarget {
    /// This track.
    Existing(Id),
    /// No free video track above the occupied ones: the caller adds one (same undo step).
    NewTrack,
}

/// Place on Top.
pub trait TimelinePlaceOnTopExt {
    /// Resolve-style Place on Top: the lowest unlocked video track above the topmost video track that has a clip
    /// overlapping `range` and is itself empty there; `NewTrack` when there is none. With nothing in the range, the first
    /// unlocked empty video track. Pure; independent of track targeting.
    fn place_on_top_target(&self, range: TimeRange) -> PlaceOnTopTarget;
}

impl TimelinePlaceOnTopExt for Timeline {
    fn place_on_top_target(&self, range: TimeRange) -> PlaceOnTopTarget {
        let video: Vec<&Track> = self.tracks.iter().filter(|t| t.kind == TrackKind::Video).collect();
        let busy = |t: &Track| t.clips().iter().any(|c| c.timeline().overlaps(&range));
        // Fast Cut: V1 is the main track; Place on Top attaches above it and never lands on it.
        // With an empty main track nothing can be attached: the clip goes on the main track then.
        let main_end = self.main_track_index().map_or(Time::ZERO, |i| self.tracks[i].end());
        let floor = usize::from(self.is_fast_cut() && main_end > Time::ZERO);
        let from = video.iter().rposition(|t| busy(t)).map_or(0, |i| i + 1).max(floor);
        if from < video.len()
            && let Some(t) = video[from..].iter().find(|t| !t.is_locked && !busy(t))
        {
            return PlaceOnTopTarget::Existing(t.id);
        }
        PlaceOnTopTarget::NewTrack
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::*;
    use sq_core_model::TrackKind::{Audio, Video};

    #[test]
    fn lowest_free_track_above_the_topmost_busy_one() {
        let tl = timeline(vec![
            track(Video, vec![v(0, 10)]),
            track(Video, vec![]),
            track(Video, vec![]),
            track(Audio, vec![]),
        ]);
        assert_eq!(tl.place_on_top_target(r(2, 4)), PlaceOnTopTarget::Existing(tl.tracks[1].id));
    }

    #[test]
    fn a_new_track_when_everything_above_is_busy_or_locked() {
        let tl = timeline(vec![track(Video, vec![v(0, 10)]), locked(track(Video, vec![]))]);
        assert_eq!(tl.place_on_top_target(r(2, 4)), PlaceOnTopTarget::NewTrack);
        let full = timeline(vec![track(Video, vec![v(0, 10)])]);
        assert_eq!(full.place_on_top_target(r(2, 4)), PlaceOnTopTarget::NewTrack);
    }

    #[test]
    fn nothing_in_the_range_takes_the_first_free_unlocked_track() {
        let tl = timeline(vec![locked(track(Video, vec![])), track(Video, vec![v(20, 5)]), track(Video, vec![])]);
        assert_eq!(tl.place_on_top_target(r(0, 5)), PlaceOnTopTarget::Existing(tl.tracks[1].id));
    }

    #[test]
    fn fast_cut_never_lands_on_a_filled_main_track() {
        let mut tl = timeline(vec![track(Video, vec![v(30, 5)]), track(Video, vec![])]);
        tl.set_edit_mode_stored(sq_core_model::TimelineEditMode::Magnetic);
        assert_eq!(tl.place_on_top_target(r(0, 5)), PlaceOnTopTarget::Existing(tl.tracks[1].id));
    }
}
