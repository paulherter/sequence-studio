// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: PictureMask.swift (`removeTrack`, `removeEmptyTracks`), ProjectFile+V91.swift (`deleteTargetedTracks`)

use crate::timeline_clipboard::TimelineClipboardExt as _;
use crate::timeline_source_patch::TimelineSourcePatchExt as _;
use sq_core_masks::PictureMaskTimelineExt as _;
use sq_core_model::{EditError, Timeline, TrackKind};
use sq_core_time::Id;
use std::collections::BTreeSet;

/// Delete Track, Remove Empty Tracks and Delete Targeted Tracks.
pub trait TimelineRemoveTracksExt {
    /// Delete Track: removes the track with its clips (a locked track is refused), drops broken links and clears every
    /// Picture mask that read it, in one mutation (one undo step). An unknown id is a no-op.
    fn remove_track(&mut self, id: Id) -> Result<(), EditError>;

    /// Remove Empty Tracks: deletes every unlocked track without clips, except the lowest track of each kind (a sequence
    /// always keeps one video and one audio track) and the main track of a Fast Cut sequence. Returns the removed IDs.
    fn remove_empty_tracks(&mut self) -> Vec<Id>;

    /// Delete Track (Sequence menu, key): removes the targeted tracks with their clips in one mutation (one undo step).
    /// Locked tracks are refused; the lowest track of each kind and a Fast Cut main track stay. `TrackLocked` when a
    /// targeted track is locked, `NoTrackToDelete` when nothing is left to remove. Returns the removed IDs.
    fn delete_targeted_tracks(&mut self) -> Result<Vec<Id>, EditError>;
}

/// The tracks a delete never takes: the lowest of each kind and the Fast Cut main track.
fn kept_tracks(t: &Timeline) -> BTreeSet<Id> {
    let mut keep = BTreeSet::new();
    for kind in [TrackKind::Video, TrackKind::Audio] {
        if let Some(tr) = t.tracks.iter().find(|tr| tr.kind == kind) {
            keep.insert(tr.id);
        }
    }
    keep.extend(t.main_track_id());
    keep
}

impl TimelineRemoveTracksExt for Timeline {
    fn remove_track(&mut self, id: Id) -> Result<(), EditError> {
        let Some(i) = self.tracks.iter().position(|t| t.id == id) else { return Ok(()) };
        if self.tracks[i].is_locked {
            return Err(EditError::TrackLocked);
        }
        self.tracks.remove(i);
        self.drop_orphan_links();
        self.clear_picture_masks_reading_track(id);
        // A patch that pointed at the deleted track falls back (v88 gate).
        let patch = self.source_patch();
        self.set_source_patch(patch);
        Ok(())
    }

    fn remove_empty_tracks(&mut self) -> Vec<Id> {
        let keep = kept_tracks(self);
        let doomed: Vec<Id> = self
            .tracks
            .iter()
            .filter(|t| t.clips().is_empty() && !t.is_locked && !keep.contains(&t.id))
            .map(|t| t.id)
            .collect();
        for id in &doomed {
            let _ = self.remove_track(*id);
        }
        doomed
    }

    fn delete_targeted_tracks(&mut self) -> Result<Vec<Id>, EditError> {
        let keep = kept_tracks(self);
        let targeted: Vec<(Id, bool)> = self
            .tracks
            .iter()
            .filter(|t| t.is_targeted && !keep.contains(&t.id))
            .map(|t| (t.id, t.is_locked))
            .collect();
        if targeted.is_empty() {
            return Err(EditError::NoTrackToDelete);
        }
        if targeted.iter().any(|(_, locked)| *locked) {
            return Err(EditError::TrackLocked);
        }
        for (id, _) in &targeted {
            self.remove_track(*id)?;
        }
        Ok(targeted.into_iter().map(|(id, _)| id).collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::*;
    use sq_core_masks::ClipMasksExt as _;
    use sq_core_model::{ClipMask, Track};

    fn kinds(kinds: &[TrackKind]) -> Timeline {
        timeline(kinds.iter().map(|k| track(*k, vec![])).collect())
    }

    #[test]
    fn remove_empty_tracks_keeps_one_of_each_kind_and_locked() {
        use TrackKind::{Audio, Video};
        let mut tl = kinds(&[Video, Video, Video, Audio, Audio]);
        tl.tracks[2].is_locked = true;
        let gone = tl.remove_empty_tracks();
        assert_eq!(gone.len(), 2);
        assert_eq!(tl.tracks.len(), 3);
        assert!(tl.tracks[0].kind == Video && tl.tracks[1].is_locked && tl.tracks[2].kind == Audio);
        assert!(tl.remove_empty_tracks().is_empty());
    }

    #[test]
    fn remove_track_clears_every_link_to_it_and_refuses_a_locked_track() {
        use TrackKind::Video;
        let mut c = v(0, 5);
        let v2 = track(Video, vec![]).id;
        c.set_masks(vec![ClipMask::make_picture(Id::from_u128(fresh()), "Picture", Some(v2))]);
        let mut tl = timeline(vec![track(Video, vec![c]), Track::new(v2, Video)]);
        tl.tracks[1].is_locked = true;
        assert_eq!(tl.remove_track(v2), Err(EditError::TrackLocked));
        assert_eq!(tl.tracks[0].clips()[0].masks()[0].picture_track, Some(v2));
        tl.tracks[1].is_locked = false;
        tl.remove_track(v2).unwrap();
        assert!(tl.track(v2).is_none());
        assert!(tl.tracks[0].clips()[0].masks().iter().all(|m| m.picture_track.is_none()));
    }

    #[test]
    fn delete_targeted_tracks_removes_them_keeps_the_lowest_and_refuses_locked() {
        use TrackKind::{Audio, Video};
        let mut tl = kinds(&[Video, Video, Video, Audio, Audio]);
        tl.tracks[1].is_targeted = true;
        tl.tracks[2].is_targeted = true;
        assert_eq!(tl.delete_targeted_tracks().map(|g| g.len()), Ok(2));
        assert_eq!(tl.tracks.len(), 3);

        let mut tl = kinds(&[Video, Video, Video, Audio, Audio]);
        tl.tracks[0].is_targeted = true;
        tl.tracks[3].is_targeted = true;
        assert_eq!(tl.delete_targeted_tracks(), Err(EditError::NoTrackToDelete));
        assert_eq!(tl.tracks.len(), 5);

        tl.tracks[1].is_targeted = true;
        tl.tracks[2].is_targeted = true;
        tl.tracks[2].is_locked = true;
        assert_eq!(tl.delete_targeted_tracks(), Err(EditError::TrackLocked));
        assert_eq!(tl.tracks.len(), 5);
    }
}
