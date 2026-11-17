// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ToneGenerator.swift (`Timeline.bleep`)

use crate::timeline_range_edits::TimelineRangeEditsExt as _;
use sq_core_audio::tone_generator::{ToneClipExt as _, ToneSpec};
use sq_core_model::{Clip, EditError, Timeline, Track, TrackKind};
use sq_core_time::{Id, IdSource, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

/// Name of the track a bleep tone lands on.
pub const BLEEP_TRACK_NAME: &str = "Bleep";

/// Bleep.
pub trait TimelineBleepExt {
    /// Silences `range` on the targeted audio tracks and lays a tone over it. The sound under the range is kept, only
    /// switched off (the pieces are disabled, so enabling them again undoes the bleep for that part); the tone goes on a
    /// track named "Bleep" (an existing one if it is free over the range, else a new audio track). Pieces keep their link,
    /// so picture and sound keep their sync. One mutation. Returns the tone clip.
    /// Fails with `EmptyClip` for an empty range or when nothing sounds in it, `WrongTrackKind` for a video track,
    /// `TrackLocked` for a locked target, `ClipNotFound` (no target).
    fn bleep(
        &mut self,
        range: TimeRange,
        tracks: &[Id],
        tone: &ToneSpec,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError>;
}

impl TimelineBleepExt for Timeline {
    fn bleep(
        &mut self,
        range: TimeRange,
        tracks: &[Id],
        tone: &ToneSpec,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError> {
        if range.is_empty() {
            return Err(EditError::EmptyClip);
        }
        if tracks.is_empty() {
            return Err(EditError::ClipNotFound);
        }
        let targets: Vec<usize> =
            self.target_indices(tracks)?.into_iter().filter(|&i| self.tracks[i].name != BLEEP_TRACK_NAME).collect();
        if targets.is_empty() {
            return Err(EditError::ClipNotFound);
        }
        if !targets.iter().all(|&i| self.tracks[i].kind == TrackKind::Audio) {
            return Err(EditError::WrongTrackKind);
        }
        let mut work = self.clone();
        let mut relinks: BTreeMap<Id, Id> = BTreeMap::new();
        let mut muted = false;
        // Linked partners (the picture) are cut at both edges too, with the shared relink map, exactly like an add-edit:
        // the pieces of one cut keep one link each, so linked trim and Enable Clip keep working. The picture plays through.
        let links: BTreeSet<Id> = targets
            .iter()
            .flat_map(|&i| {
                work.tracks[i].clips().iter().filter(|c| c.timeline().overlaps(&range)).filter_map(|c| c.link)
            })
            .collect();
        let partners: Vec<usize> = (0..work.tracks.len())
            .filter(|i| {
                !targets.contains(i)
                    && !work.tracks[*i].is_locked
                    && work.tracks[*i].clips().iter().any(|c| c.link.is_some_and(|l| links.contains(&l)))
            })
            .collect();
        for &i in targets.iter().chain(partners.iter()) {
            work.tracks[i].split_relinking(range.start, &mut relinks, ids)?;
            work.tracks[i].split_relinking(range.end(), &mut relinks, ids)?;
        }
        for &i in &targets {
            let pieces: Vec<Clip> =
                work.tracks[i].clips().iter().filter(|c| c.is_enabled && c.tone().is_none()).cloned().collect();
            for mut c in pieces {
                if range.start <= c.start && c.timeline().end() <= range.end() {
                    c.is_enabled = false;
                    muted = true;
                    work.tracks[i].replace(c);
                }
            }
        }
        if !muted {
            return Err(EditError::EmptyClip);
        }
        let clip = Clip::make_tone(ids.next_id(), tone, range.start, range.duration, "Bleep");
        let clip_id = clip.id;
        let free = work.tracks.iter().enumerate().position(|(i, t)| {
            t.kind == TrackKind::Audio
                && t.name == BLEEP_TRACK_NAME
                && !t.is_locked
                && !targets.contains(&i)
                && !t.clips().iter().any(|c| c.timeline().overlaps(&range))
        });
        if let Some(free) = free {
            work.tracks[free].overwrite(clip, ids)?;
        } else {
            let mut t = Track::new(ids.next_id(), TrackKind::Audio);
            t.name = BLEEP_TRACK_NAME.to_string();
            t.is_targeted = false;
            t.overwrite(clip, ids)?;
            work.tracks.push(t);
        }
        if !work.tracks.iter().all(Track::is_consistent) {
            return Err(EditError::Collision);
        }
        *self = work;
        Ok(clip_id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::*;

    fn dialog() -> (Timeline, Id, Id) {
        let l = link();
        let au = track(TrackKind::Audio, vec![clip(0, 10, 0, TrackKind::Audio, Some(l), Some(20))]);
        let vi = track(TrackKind::Video, vec![clip(0, 10, 0, TrackKind::Video, Some(l), Some(20))]);
        let (a, v) = (au.id, vi.id);
        (timeline(vec![vi, au]), a, v)
    }

    fn bleep(t: &mut Timeline, r: TimeRange, tracks: &[Id]) -> Result<Id, EditError> {
        t.bleep(r, tracks, &ToneSpec::DEFAULT, &mut FreshIds)
    }

    #[test]
    fn bleep_mutes_the_range_and_lays_the_tone() {
        let (mut t, a, _) = dialog();
        let tone_id = bleep(&mut t, r(4, 6), &[a]).unwrap();
        let audio = t.tracks[1].clips();
        assert_eq!(audio.iter().map(|c| c.start).collect::<Vec<_>>(), [s(0), s(4), s(6)]);
        assert_eq!(audio.iter().map(|c| c.is_enabled).collect::<Vec<_>>(), [true, false, true]);
        let tone = &t.tracks[2];
        assert!(tone.name == BLEEP_TRACK_NAME && tone.kind == TrackKind::Audio && !tone.is_targeted);
        assert!(tone.clips().len() == 1 && tone.clips()[0].id == tone_id && tone.clips()[0].timeline() == r(4, 6));
        assert_eq!(tone.clips()[0].tone(), Some(ToneSpec::DEFAULT));
        assert!(audio[0].media == audio[1].media && audio[1].source.end() == audio[2].source.start);
    }

    #[test]
    fn bleep_cuts_picture_and_sound_alike_an_add_edit() {
        let (mut t, a, _) = dialog();
        bleep(&mut t, r(4, 6), &[a]).unwrap();
        let (v, au) = (t.tracks[0].clips(), t.tracks[1].clips());
        assert_eq!(v.iter().map(|c| c.start).collect::<Vec<_>>(), [s(0), s(4), s(6)]);
        assert!(v.iter().all(|c| c.is_enabled));
        assert_eq!(v.iter().map(|c| c.link).collect::<Vec<_>>(), au.iter().map(|c| c.link).collect::<Vec<_>>());
        assert_eq!(v.iter().filter_map(|c| c.link).collect::<BTreeSet<_>>().len(), 3);
    }

    #[test]
    fn repeated_bleep_on_the_same_range_adds_no_second_tone() {
        let (mut t, a, _) = dialog();
        bleep(&mut t, r(4, 6), &[a]).unwrap();
        let once = t.clone();
        assert_eq!(bleep(&mut t, r(4, 6), &[a]), Err(EditError::EmptyClip));
        assert!(t == once);
        assert!(t.tracks.len() == 3 && t.tracks[2].clips().len() == 1);
    }

    #[test]
    fn the_bleep_track_is_never_a_target() {
        let (mut t, a, _) = dialog();
        bleep(&mut t, r(4, 6), &[a]).unwrap();
        let bleep_id = t.tracks[2].id;
        bleep(&mut t, r(1, 2), &[a, bleep_id]).unwrap();
        assert!(
            t.tracks.len() == 3 && t.tracks[2].clips().len() == 2 && t.tracks[2].clips().iter().all(|c| c.is_enabled)
        );
        assert_eq!(bleep(&mut t, r(1, 2), &[bleep_id]), Err(EditError::ClipNotFound));
    }

    #[test]
    fn second_bleep_reuses_the_bleep_track() {
        let (mut t, a, _) = dialog();
        bleep(&mut t, r(1, 2), &[a]).unwrap();
        bleep(&mut t, r(7, 8), &[a]).unwrap();
        assert!(t.tracks.len() == 3 && t.tracks[2].clips().len() == 2);
        bleep(&mut t, r(7, 9), &[a]).unwrap();
        assert_eq!(t.tracks.len(), 4);
    }

    #[test]
    fn bleep_refuses_bad_input() {
        let (mut t, a, v) = dialog();
        assert_eq!(bleep(&mut t, r(2, 2), &[a]), Err(EditError::EmptyClip));
        assert_eq!(bleep(&mut t, r(2, 3), &[v]), Err(EditError::WrongTrackKind));
        assert_eq!(bleep(&mut t, r(2, 3), &[]), Err(EditError::ClipNotFound));
        assert_eq!(bleep(&mut t, r(20, 21), &[a]), Err(EditError::EmptyClip));
        t.tracks[1].is_locked = true;
        assert_eq!(bleep(&mut t, r(2, 3), &[a]), Err(EditError::TrackLocked));
        assert_eq!(t.tracks.len(), 2);
    }
}
