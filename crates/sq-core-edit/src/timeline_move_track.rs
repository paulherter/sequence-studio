// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline+MoveTrack.swift
//
// Reorder tracks. A track only trades places with the next track of its own kind (video stays above audio); "up" is what
// the timeline shows: video lanes stack upward (V2 above V1), audio lanes downward (A1 at the top). Clips, transitions and
// links travel with the track (track ids do not change), so Picture masks keep reading the same track.
//
// Fast Cut: the first video track is the main track every attachment hangs on, so it neither moves nor is swapped.

use crate::timeline_magnetic_ops::MagneticOpsExt;
use sq_core_model::{Timeline, TrackKind};
use sq_core_time::Id;

/// Track order edits.
pub trait TimelineMoveTrackExt {
    /// Index the track `id` would trade places with when moved `up`, `None` when it cannot move that way.
    fn move_track_neighbor(&self, id: Id, up: bool) -> Option<usize>;

    /// Moves the track one place up or down among tracks of its kind. False (nothing changed) when it is at the end.
    fn move_track(&mut self, id: Id, up: bool) -> bool;
}

impl TimelineMoveTrackExt for Timeline {
    fn move_track_neighbor(&self, id: Id, up: bool) -> Option<usize> {
        let i = self.tracks.iter().position(|t| t.id == id)?;
        let forward = (self.tracks[i].kind == TrackKind::Video) == up;
        let mut j = i;
        loop {
            j = if forward { j + 1 } else { j.checked_sub(1)? };
            let t = self.tracks.get(j)?;
            if t.kind == self.tracks[i].kind {
                break;
            }
        }
        if self.is_fast_cut() && self.main_track_index().is_some_and(|m| i == m || j == m) {
            return None;
        }
        Some(j)
    }

    fn move_track(&mut self, id: Id, up: bool) -> bool {
        let Some(i) = self.tracks.iter().position(|t| t.id == id) else { return false };
        let Some(j) = self.move_track_neighbor(id, up) else { return false };
        self.tracks.swap(i, j);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::*;
    use sq_core_model::TimelineEditMode;
    use sq_core_model::TrackKind::{Audio, Video};

    fn tl() -> Timeline {
        timeline(vec![
            track(Video, vec![]),
            track(Video, vec![]),
            track(Video, vec![]),
            track(Audio, vec![]),
            track(Audio, vec![]),
        ])
    }

    #[test]
    fn video_moves_up_by_rising_index() {
        let mut t = tl();
        let (v1, v2) = (t.tracks[0].id, t.tracks[1].id);
        assert!(t.move_track(v1, true));
        assert_eq!((t.tracks[1].id, t.tracks[0].id), (v1, v2));
    }

    #[test]
    fn audio_moves_up_by_falling_index() {
        let mut t = tl();
        let (a2, a1) = (t.tracks[4].id, t.tracks[3].id);
        assert!(t.move_track(a2, true));
        assert_eq!((t.tracks[3].id, t.tracks[4].id), (a2, a1));
    }

    #[test]
    fn ends_and_kind_borders_stay() {
        let mut t = tl();
        let (top, a1, a2) = (t.tracks[2].id, t.tracks[3].id, t.tracks[4].id);
        assert!(!t.move_track(top, true));
        assert!(!t.move_track(a1, true));
        assert!(!t.move_track(a2, false));
        assert_eq!(t.move_track_neighbor(top, false), Some(1));
    }

    #[test]
    fn clips_travel_with_the_track() {
        let mut t = tl();
        let c = clip(0, 2, 0, Video, None, Some(10));
        t.tracks[0].set_clips(vec![c.clone()]);
        let id = t.tracks[0].id;
        t.move_track(id, true);
        assert_eq!(t.tracks[1].clips().iter().map(|x| x.id).collect::<Vec<_>>(), [c.id]);
    }

    #[test]
    fn fast_cut_keeps_the_main_track_in_place() {
        let mut t = tl();
        t.set_edit_mode_stored(TimelineEditMode::Magnetic);
        let (v1, v2, v3) = (t.tracks[0].id, t.tracks[1].id, t.tracks[2].id);
        assert!(!t.move_track(v1, true));
        assert!(!t.move_track(v2, false));
        assert!(t.move_track(v2, true));
        assert_eq!((t.tracks[2].id, t.tracks[1].id), (v2, v3));
    }
}
