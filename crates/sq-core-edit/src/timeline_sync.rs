// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline+Sync.swift
//
// Premiere's "Move into Sync" / "Slip into Sync" (right-click on the out-of-sync badge). Both act on the one clip that
// carries the badge and bring its offset (see `sync_offsets`, passed in) to 0; the linked partner stays where it is.

use crate::sync_offsets::SyncOffsetsExt as _;
use crate::timeline_magnetic::{MagneticExt, MagneticOrphans, MagneticScope, MagneticStay};
use crate::timeline_magnetic_ops::MagneticOpsExt;
use sq_core_model::{EditError, Timeline, Track};
use sq_core_time::{Id, IdSource};
use std::collections::BTreeMap;

/// Move / Slip into Sync.
pub trait TimelineSyncExt {
    /// Moves the clip on its own track so it is in sync with its partner. Covered clips are overwritten like in a move;
    /// refused when the clip would start before 0 or its track is locked. No-op when the clip is in sync. `offsets` is
    /// `sync_offsets()` of this timeline.
    fn move_into_sync(&mut self, id: Id, offsets: &BTreeMap<Id, i64>, ids: &mut dyn IdSource) -> Result<(), EditError>;

    /// Slips the clip's source so it is in sync with its partner; position and duration stay. Refused when the media does
    /// not reach that far (`InsufficientMedia`) or the track is locked. No-op when the clip is in sync.
    fn slip_into_sync(&mut self, id: Id, offsets: &BTreeMap<Id, i64>) -> Result<(), EditError>;
}

impl TimelineSyncExt for Timeline {
    fn move_into_sync(&mut self, id: Id, offsets: &BTreeMap<Id, i64>, ids: &mut dyn IdSource) -> Result<(), EditError> {
        let m = self.find(id).ok_or(EditError::ClipNotFound)?;
        if self.tracks[m.track].is_locked {
            return Err(EditError::TrackLocked);
        }
        let Some(&frames) = offsets.get(&id) else { return Ok(()) };
        // Fast Cut: a main-track clip cannot move (V1 stays gapless); its partners off V1 move the other way instead.
        if self.is_fast_cut() && self.is_on_main_track(id) {
            // Partners on locked tracks stay put (they are not candidates); none left means `Collision`.
            let link = m.clip.link;
            let partners: Vec<Id> = self
                .tracks
                .iter()
                .filter(|t| !t.is_locked)
                .flat_map(|t| t.clips())
                .filter(|c| {
                    c.id != id
                        && link.is_some()
                        && c.link == link
                        && offsets.contains_key(&c.id)
                        && !self.is_on_main_track(c.id)
                })
                .map(|c| c.id)
                .collect();
            if partners.is_empty() {
                return Err(EditError::Collision);
            }
            let scope = MagneticScope {
                involving: partners.iter().copied().collect(),
                local: true,
                stay: MagneticStay::All,
                orphans: MagneticOrphans::Follow,
            };
            let mut work = self.clone();
            work.magnetic_edit(scope, ids, |w, ids| {
                for p in &partners {
                    let now = w.sync_offsets();
                    w.move_into_sync(*p, &now, ids)?;
                }
                Ok(())
            })?;
            *self = work;
            return Ok(());
        }
        let mut c = m.clip;
        c.start -= self.frame_duration() * frames;
        if c.start < sq_core_time::Time::ZERO {
            return Err(EditError::Collision);
        }
        let mut work = self.tracks.clone();
        work[m.track].remove(id);
        work[m.track].overwrite_relinking(c, &mut BTreeMap::new(), ids)?;
        if !work.iter().all(Track::is_consistent) {
            return Err(EditError::Collision);
        }
        self.tracks = work;
        Ok(())
    }

    fn slip_into_sync(&mut self, id: Id, offsets: &BTreeMap<Id, i64>) -> Result<(), EditError> {
        let m = self.find(id).ok_or(EditError::ClipNotFound)?;
        if self.tracks[m.track].is_locked {
            return Err(EditError::TrackLocked);
        }
        let Some(&frames) = offsets.get(&id) else { return Ok(()) };
        let mut c = m.clip;
        if c.speed_keys.is_some() {
            return Err(EditError::SpeedUnsupported);
        }
        c.source.start += self.frame_duration() * frames;
        if c.source.start < sq_core_time::Time::ZERO {
            return Err(EditError::InsufficientMedia);
        }
        if c.media_duration.is_some_and(|total| c.source.end() > total) {
            return Err(EditError::InsufficientMedia);
        }
        self.tracks[m.track].replace(c);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::*;
    use sq_core_model::TrackKind::{Audio, Video};
    use sq_core_time::{SequentialIds, Time};

    fn pair(audio_start: i64, audio_src: i64) -> (Timeline, Id) {
        let l = link();
        let au = clip(audio_start, 5, audio_src, Audio, Some(l), Some(30));
        let id = au.id;
        (timeline(vec![track(Video, vec![clip(10, 5, 0, Video, Some(l), None)]), track(Audio, vec![au])]), id)
    }

    #[test]
    fn move_into_sync_shifts_the_clip_back_by_its_offset() {
        let (mut tl, id) = pair(20, 0);
        let offsets = BTreeMap::from([(id, 30_i64)]); // one second of frames
        assert_eq!(tl.move_into_sync(id, &offsets, &mut SequentialIds::default()), Ok(()));
        assert_eq!(tl.tracks[1].clips()[0].start, s(19));
    }

    #[test]
    fn move_into_sync_refuses_to_start_before_zero_and_ignores_clips_in_sync() {
        let (mut tl, id) = pair(1, 0);
        let before = tl.clone();
        let mut ids = SequentialIds::default();
        assert_eq!(tl.move_into_sync(id, &BTreeMap::from([(id, 60)]), &mut ids), Err(EditError::Collision));
        assert_eq!(tl.move_into_sync(id, &BTreeMap::new(), &mut ids), Ok(()));
        assert_eq!(tl, before);
    }

    #[test]
    fn slip_into_sync_moves_the_source_and_checks_the_media() {
        let (mut tl, id) = pair(10, 4);
        assert_eq!(tl.slip_into_sync(id, &BTreeMap::from([(id, 30)])), Ok(()));
        assert_eq!(tl.tracks[1].clips()[0].source.start, s(5));
        assert_eq!(tl.slip_into_sync(id, &BTreeMap::from([(id, -300)])), Err(EditError::InsufficientMedia));
        assert_eq!(tl.slip_into_sync(id, &BTreeMap::from([(id, 30 * 40)])), Err(EditError::InsufficientMedia));
        assert_eq!(tl.tracks[1].clips()[0].source.start, s(5));
        let _ = Time::ZERO;
    }

    #[test]
    fn a_main_track_clip_in_fast_cut_moves_its_partners_instead() {
        use crate::sync_offsets::SyncOffsetsExt as _;
        use crate::timeline_magnetic_ops::fixture::{F, d};
        let mut f = F::new();
        // The camera audio drifts one second late; the main-track picture cannot move.
        let mut audio = f.tl.find(f.c1a).map(|m| m.clip).unwrap();
        audio.start = Time::new(1, 1);
        let ti = f.tl.find(f.c1a).map(|m| m.track).unwrap();
        f.tl.tracks[ti].set_clips(vec![audio]);
        let offsets = f.tl.sync_offsets();
        assert_eq!(offsets.get(&f.c1), Some(&-30));
        assert_eq!(f.tl.move_into_sync(f.c1, &offsets, &mut f.ids), Ok(()));
        assert_eq!(f.tl.find(f.c1a).map(|m| d(m.clip.start)), Some(0.0));
        assert_eq!(f.tl.find(f.c1).map(|m| d(m.clip.start)), Some(0.0));
    }
}
