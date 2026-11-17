// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AudioDriftFit.swift (`Timeline.syncAudio`)

use sq_core_audio::audio_drift_fit::{AudioDriftFit, AudioSyncMethod};
use sq_core_model::{ClipSpeed, EditError, Timeline};
use sq_core_time::{Id, Time, TimeRange};
use std::collections::BTreeSet;

/// Sync Audio to a reference clip.
pub trait TimelineSyncAudioExt {
    /// Lines the clip `id` (and its linked partners) up with `reference` by a sync fit: the group moves so the shared
    /// event lands at the same time, and with `retime` the drift is corrected by a constant speed. One edit; nothing
    /// changes when it fails. `fit` relates the two clips' files (`AudioDriftFit::fit`).
    // The reference clip must play at 100 % and the position is snapped to whole frames (up to half a frame off), as in Swift.
    fn sync_audio(&mut self, id: Id, reference: Id, fit: &AudioDriftFit, retime: bool) -> Result<(), EditError>;
}

impl TimelineSyncAudioExt for Timeline {
    fn sync_audio(&mut self, id: Id, reference: Id, fit: &AudioDriftFit, retime: bool) -> Result<(), EditError> {
        let reference_clip = self.find(reference).ok_or(EditError::ClipNotFound)?.clip;
        if reference_clip.speed != ClipSpeed::NORMAL || reference_clip.speed_keys.is_some() || reference_clip.reversed {
            return Err(EditError::SpeedUnsupported);
        }
        let target = match self.find(id) {
            Some(m) if id != reference => m.clip,
            _ => return Err(EditError::ClipNotFound),
        };
        // A reversed or remapped clip has no single source-start-to-position relation (and no constant drift speed).
        if target.speed_keys.is_some() || target.reversed {
            return Err(EditError::SpeedUnsupported);
        }
        let group = self.linked_group(id)?;
        // The reference never moves with the clip: syncing a clip to its own linked partner is meaningless.
        if group.iter().any(|m| m.clip.id == reference) {
            return Err(EditError::Collision);
        }
        if group.iter().any(|m| self.tracks[m.track].is_locked) {
            return Err(EditError::TrackLocked);
        }
        let frame_duration = self.frame_duration();
        let speed = if retime && fit.method == AudioSyncMethod::Sound { fit.correcting_speed() } else { None };
        let drift = if speed.is_none() { 0.0 } else { fit.drift_ratio };
        // Source frame p of the other file lands on reference media time p * (1 + drift) + offset. A retime keeps the
        // source start, so the position is known before the clip is touched.
        let p = target.source.start;
        let extra_value = (p.value() as f64 / p.timescale() as f64 * drift * 1_000_000.0).round();
        let extra = Time::new(extra_value as i64, 1_000_000);
        let at = reference_clip.start + (p + extra + fit.offset - reference_clip.source.start);
        let delta = at.snapped(frame_duration) - target.start;

        // Move first, then retime: the retime must see the clip where it ends up. Nothing at the destination may be
        // cut or deleted: the range is checked at the old and at the retimed length.
        let mut work = self.clone();
        let group_ids: BTreeSet<Id> = group.iter().map(|m| m.clip.id).collect();
        let blocked = |track: usize, range: &TimeRange| {
            self.tracks[track].clips().iter().any(|c| !group_ids.contains(&c.id) && c.timeline().overlaps(range))
        };
        if delta != Time::ZERO {
            for m in &group {
                let mut length = m.clip.duration();
                if let Some(speed) = speed {
                    length = length.max(speed.unscale(m.clip.retime_span()).ceiled(frame_duration));
                }
                let range = TimeRange::new(m.clip.start + delta, length);
                if range.start < Time::ZERO || blocked(m.track, &range) {
                    return Err(EditError::Collision);
                }
            }
            for m in &group {
                let mut moved = m.clip.clone();
                moved.start += delta;
                work.tracks[m.track].replace(moved);
            }
            if !work.tracks.iter().all(|t| t.is_consistent()) {
                return Err(EditError::Collision);
            }
        } else if let Some(speed) = speed {
            for m in &group {
                let range = TimeRange::new(m.clip.start, speed.unscale(m.clip.retime_span()).ceiled(frame_duration));
                if blocked(m.track, &range) {
                    return Err(EditError::Collision);
                }
            }
        }
        if let Some(speed) = speed {
            work.set_speed(id, speed, None, None, false, false)?;
        }
        *self = work;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::*;
    use sq_core_model::{Clip, Track, TrackKind};
    use sq_core_time::Id;

    fn fd() -> Time {
        Time::new(1, 30)
    }

    fn audio_clip(kind: TrackKind, start: i64, frames: i64, media: Id, media_frames: i64, link: Option<Id>) -> Clip {
        let mut c = Clip::new(
            Id::from_u128(fresh()),
            "c",
            media,
            kind,
            TimeRange::new(Time::ZERO, fd() * frames),
            fd() * start,
        );
        c.media_duration = Some(fd() * media_frames);
        c.link = link;
        c
    }

    fn fit(offset: i64, drift: f64) -> AudioDriftFit {
        AudioDriftFit {
            offset: Time::new(offset, 1),
            drift_ratio: drift,
            confidence: 1.0,
            chunks_used: 8,
            chunk_count: 8,
            method: AudioSyncMethod::Sound,
        }
    }

    fn track_with(kind: TrackKind, clip: Clip) -> Track {
        track(kind, vec![clip])
    }

    fn timeline_fd(tracks: Vec<Track>) -> Timeline {
        let mut t = timeline(tracks);
        t.format.frame_duration = fd();
        t
    }

    /// The Swift `rig()`: a reference at frame 30, the clip to sync at 600 (linked), a neighbor at 100.
    fn rig() -> (Timeline, Clip, Clip) {
        let l = link();
        let reference = audio_clip(TrackKind::Audio, 30, 3000, Id::from_u128(fresh()), 3000, None);
        let a = audio_clip(TrackKind::Audio, 600, 100, Id::from_u128(fresh()), 1000, Some(l));
        let n = audio_clip(TrackKind::Audio, 100, 100, Id::from_u128(fresh()), 100, None);
        let at = track(TrackKind::Audio, vec![a.clone(), n]);
        (timeline_fd(vec![track_with(TrackKind::Audio, reference.clone()), at]), reference, a)
    }

    #[test]
    fn sync_audio_moves_and_retimes_the_linked_group_in_one_edit() {
        let l = link();
        let other = Id::from_u128(fresh());
        let reference = audio_clip(TrackKind::Audio, 30, 3000, Id::from_u128(fresh()), 3000, None);
        let a = audio_clip(TrackKind::Audio, 600, 1000, other, 1000, Some(l));
        let v = audio_clip(TrackKind::Video, 600, 1000, other, 1000, Some(l));
        let mut t = timeline_fd(vec![
            track_with(TrackKind::Video, v.clone()),
            track_with(TrackKind::Audio, reference.clone()),
            track_with(TrackKind::Audio, a.clone()),
        ]);
        t.sync_audio(a.id, reference.id, &fit(2, 0.01), true).unwrap();
        let (na, nv) = (t.find(a.id).unwrap().clip, t.find(v.id).unwrap().clip);
        assert_eq!(na.start, fd() * 30 + Time::new(2, 1));
        assert_eq!(nv.start, na.start);
        assert!((na.speed.num() as f64 / na.speed.den() as f64 - 100.0 / 101.0).abs() < 1e-6);
        assert_eq!(nv.speed, na.speed);
    }

    #[test]
    fn sync_audio_without_retime_keeps_speed_and_refuses_a_retimed_reference() {
        let reference = audio_clip(TrackKind::Audio, 0, 300, Id::from_u128(fresh()), 300, None);
        let a = audio_clip(TrackKind::Audio, 5, 300, Id::from_u128(fresh()), 300, None);
        let mut t =
            timeline_fd(vec![track_with(TrackKind::Audio, reference.clone()), track_with(TrackKind::Audio, a.clone())]);
        t.sync_audio(a.id, reference.id, &fit(1, 0.01), false).unwrap();
        assert_eq!(t.find(a.id).unwrap().clip.speed, ClipSpeed::NORMAL);
        assert_eq!(t.find(a.id).unwrap().clip.start, fd() * 30);
        t.set_speed(reference.id, ClipSpeed::new(1, 2), None, None, false, false).unwrap();
        assert!(t.sync_audio(a.id, reference.id, &fit(1, 0.01), true).is_err());
    }

    #[test]
    fn destination_occupied_is_refused_and_nothing_changes() {
        let (mut t, reference, a) = rig();
        // Lands at frame 30 + 90 = 120: inside the neighbor at 100...200.
        let before = t.clone();
        assert!(t.sync_audio(a.id, reference.id, &fit(3, 0.0), true).is_err());
        assert!(t == before);
    }

    #[test]
    fn retime_growing_into_a_neighbor_is_refused() {
        let (mut t, reference, a) = rig();
        let b = audio_clip(TrackKind::Audio, 705, 10, Id::from_u128(fresh()), 10, None);
        t.tracks[1].overwrite(b, &mut FreshIds).unwrap();
        // Offset keeps the clip at frame 600; speed 1/1.11 makes it 111 frames long: runs into b at 705.
        let before = t.clone();
        assert!(t.sync_audio(a.id, reference.id, &fit(19, 0.11), true).is_err());
        assert!(t == before);
    }

    #[test]
    fn refuses_linked_reference_and_reversed_target() {
        let (l, media) = (link(), Id::from_u128(fresh()));
        let v = audio_clip(TrackKind::Video, 10, 100, media, 200, Some(l));
        let a = audio_clip(TrackKind::Audio, 10, 100, media, 200, Some(l));
        let mut t = timeline_fd(vec![track_with(TrackKind::Video, v.clone()), track_with(TrackKind::Audio, a.clone())]);
        assert!(t.sync_audio(a.id, v.id, &fit(1, 0.01), true).is_err());

        let (mut t2, reference, c) = rig();
        let mut rev = t2.find(c.id).unwrap().clip;
        rev.reversed = true;
        t2.tracks[1].replace(rev);
        assert!(t2.sync_audio(c.id, reference.id, &fit(1, 0.01), true).is_err());
    }
}
