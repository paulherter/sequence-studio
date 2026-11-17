// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Angles.swift (`extension Timeline`: angle names, switching and Audio Follows Video)

use crate::angles_proxy::AnglesClipExt as _;
use sq_core_model::{Clip, EditError, Member, Timeline, TrackKind};
use sq_core_time::{Id, IdSource, Time};
use std::collections::{BTreeMap, BTreeSet};

/// The angle edits of a timeline, and the reads of an Angles sequence.
pub trait AnglesEditsExt {
    /// Number of angles of an Angles sequence (its video tracks; at least its audio tracks).
    fn angle_count(&self) -> usize;
    /// Display names of the angles: the angle's video track name, else its audio track name, else "Angle n".
    fn angle_names(&self) -> Vec<String>;
    /// Angles whose sound track is missing or empty: a sound piece is not switched to one of these (it keeps its previous
    /// sound), so a camera without a microphone never mutes the cut.
    fn silent_angles(&self) -> BTreeSet<i64>;
    /// The Angles clip piece under `t`: on the topmost video track that has one, else on the first audio track.
    fn angles_clip_at(&self, t: Time) -> Option<Clip>;
    /// Gives the piece `id` another angle. On a video piece: the picture switches, and so does the sound of every linked
    /// audio piece that follows the video. On an audio piece: only the sound (of it and its linked audio pieces)
    /// switches. Returns false when nothing changed. `ClipNotFound` if `id` is no Angles clip, `TrackLocked` if a piece
    /// that would change is on a locked track.
    fn set_angle(&mut self, index: i64, id: Id, silent: &BTreeSet<i64>) -> Result<bool, EditError>;
    /// Audio Follows Video for the piece `id` and its linked pieces: on, the sound takes the picture's angle now and on
    /// every later switch; off, it stays where it is. Returns false when nothing changed.
    fn set_audio_follows_video(&mut self, on: bool, id: Id) -> Result<bool, EditError>;
    /// Cuts the piece `id` (and its linked pieces under `t` that switch with it) at `t` and gives the part from `t` on
    /// another angle: the live switch of the number keys. At or before the piece's start the whole piece switches without
    /// a cut. Returns the piece that now plays from `t`, or `None` when the piece already shows that angle (nothing
    /// changes) or `t` is at or past its end.
    fn switch_angle(
        &mut self,
        index: i64,
        t: Time,
        id: Id,
        silent: &BTreeSet<i64>,
        ids: &mut dyn IdSource,
    ) -> Result<Option<Id>, EditError>;
    /// The clips of each angle Create Angles Clip would build from `ids`, in angle order (for the dialog and the sync).
    fn angle_candidates(&self, ids: &[Id]) -> Result<Vec<Vec<Clip>>, EditError>;
}

/// The angles `make_angles_clip` builds from `ids`: every clip with its linked partners is one angle, ordered by video
/// track from the bottom (sound-only angles last), then by start.
pub(crate) fn angle_groups(tl: &Timeline, ids: &[Id]) -> Result<Vec<Vec<Member>>, EditError> {
    let mut groups: Vec<Vec<Member>> = Vec::new();
    let mut seen = BTreeSet::new();
    for &id in ids {
        if seen.contains(&id) {
            continue;
        }
        let g = tl.linked_group(id)?;
        for m in &g {
            seen.insert(m.clip.id);
        }
        groups.push(g);
    }
    let order = |g: &[Member]| {
        let v = g.iter().filter(|m| m.clip.kind == TrackKind::Video).map(|m| m.track).min();
        (
            i64::from(v.is_none()),
            v.or_else(|| g.iter().map(|m| m.track).min()).unwrap_or(0),
            g.iter().map(|m| m.clip.start).min().unwrap_or(Time::ZERO),
        )
    };
    groups.sort_by_key(|g| order(g));
    Ok(groups)
}

/// The pieces of `group` whose angle changes when its first piece takes angle `index`, with the new angle set: the one rule
/// both the whole-piece switch and the live switch use (a sound that keeps its angle is not in the list).
fn angle_changes(index: i64, group: &[Member], silent: &BTreeSet<i64>) -> Vec<(usize, Clip)> {
    let Some(target) = group.first() else { return Vec::new() };
    let mut changed = Vec::new();
    for m in group {
        let Some(mut a) = m.clip.angle.clone() else { continue };
        if m.clip.sequence != target.clip.sequence {
            continue;
        }
        let follows = if target.clip.kind == TrackKind::Video {
            m.clip.kind == TrackKind::Video || a.follows_video
        } else {
            m.clip.kind == TrackKind::Audio
        };
        if !follows || a.index == index || (m.clip.kind == TrackKind::Audio && silent.contains(&index)) {
            continue;
        }
        a.index = index;
        let mut c = m.clip.clone();
        c.angle = Some(a);
        changed.push((m.track, c));
    }
    changed
}

impl AnglesEditsExt for Timeline {
    fn angle_count(&self) -> usize {
        let video = self.tracks.iter().filter(|t| t.kind == TrackKind::Video).count();
        let audio = self.tracks.iter().filter(|t| t.kind == TrackKind::Audio).count();
        video.max(audio)
    }

    fn angle_names(&self) -> Vec<String> {
        let video: Vec<_> = self.tracks.iter().filter(|t| t.kind == TrackKind::Video).collect();
        let audio: Vec<_> = self.tracks.iter().filter(|t| t.kind == TrackKind::Audio).collect();
        (0..self.angle_count())
            .map(|i| {
                let name = video
                    .get(i)
                    .map(|t| t.name.clone())
                    .or_else(|| audio.get(i).map(|t| t.name.clone()))
                    .unwrap_or_default();
                if name.is_empty() { format!("Angle {}", i + 1) } else { name }
            })
            .collect()
    }

    fn silent_angles(&self) -> BTreeSet<i64> {
        let audio: Vec<_> = self.tracks.iter().filter(|t| t.kind == TrackKind::Audio).collect();
        (0..self.angle_count()).filter(|&i| i >= audio.len() || audio[i].clips().is_empty()).map(|i| i as i64).collect()
    }

    fn angles_clip_at(&self, t: Time) -> Option<Clip> {
        let hit = |track: &sq_core_model::Track| {
            track
                .clips()
                .iter()
                .find(|c| c.is_angles_clip() && c.is_enabled && c.start <= t && t < c.timeline().end())
                .cloned()
        };
        self.tracks
            .iter()
            .rev()
            .filter(|tr| tr.kind == TrackKind::Video)
            .find_map(hit)
            .or_else(|| self.tracks.iter().filter(|tr| tr.kind == TrackKind::Audio).find_map(hit))
    }

    fn set_angle(&mut self, index: i64, id: Id, silent: &BTreeSet<i64>) -> Result<bool, EditError> {
        let group = self.linked_group(id)?;
        let target = group.first().filter(|m| m.clip.is_angles_clip() && index >= 0).ok_or(EditError::ClipNotFound)?;
        let _ = target;
        let changed = angle_changes(index, &group, silent);
        if changed.iter().any(|(track, _)| self.tracks[*track].is_locked) {
            return Err(EditError::TrackLocked);
        }
        let any = !changed.is_empty();
        for (track, clip) in changed {
            self.tracks[track].replace(clip);
        }
        Ok(any)
    }

    fn set_audio_follows_video(&mut self, on: bool, id: Id) -> Result<bool, EditError> {
        let group = self.linked_group(id)?;
        let target = group.first().filter(|m| m.clip.is_angles_clip()).ok_or(EditError::ClipNotFound)?;
        let picture = group
            .iter()
            .find(|m| m.clip.kind == TrackKind::Video && m.clip.is_angles_clip())
            .and_then(|m| m.clip.angle.as_ref().map(|a| a.index));
        let mut changed: Vec<(usize, Clip)> = Vec::new();
        for m in group.iter().filter(|m| m.clip.kind == TrackKind::Audio) {
            let Some(mut a) = m.clip.angle.clone() else { continue };
            if m.clip.sequence != target.clip.sequence {
                continue;
            }
            a.follows_video = on;
            if let (true, Some(p)) = (on, picture) {
                a.index = p;
            }
            if Some(&a) == m.clip.angle.as_ref() {
                continue;
            }
            let mut c = m.clip.clone();
            c.angle = Some(a);
            changed.push((m.track, c));
        }
        if changed.iter().any(|(track, _)| self.tracks[*track].is_locked) {
            return Err(EditError::TrackLocked);
        }
        let any = !changed.is_empty();
        for (track, clip) in changed {
            self.tracks[track].replace(clip);
        }
        Ok(any)
    }

    fn switch_angle(
        &mut self,
        index: i64,
        t: Time,
        id: Id,
        silent: &BTreeSet<i64>,
        ids: &mut dyn IdSource,
    ) -> Result<Option<Id>, EditError> {
        let group = self.linked_group(id)?;
        let target = group.first().filter(|m| m.clip.is_angles_clip() && index >= 0).ok_or(EditError::ClipNotFound)?;
        if target.clip.angle.as_ref().map(|a| a.index) == Some(index) || t >= target.clip.timeline().end() {
            return Ok(None);
        }
        if t <= target.clip.start {
            return Ok(self.set_angle(index, id, silent)?.then_some(id));
        }
        // Every linked piece under `t` is cut with the picture (a normal blade), so each part keeps its own linked sound
        // part and later ripple edits stay in sync. Only a piece that changes its angle needs an unlocked track: a sound
        // that keeps its angle on a locked track stays whole and does not stop the switch.
        let changing: BTreeSet<Id> = angle_changes(index, &group, silent).into_iter().map(|(_, c)| c.id).collect();
        let under: Vec<&Member> = group.iter().filter(|m| m.clip.start < t && t < m.clip.timeline().end()).collect();
        if under.iter().any(|m| changing.contains(&m.clip.id) && self.tracks[m.track].is_locked) {
            return Err(EditError::TrackLocked);
        }
        let cut: BTreeSet<usize> = under.iter().filter(|m| !self.tracks[m.track].is_locked).map(|m| m.track).collect();
        let target_track = target.track;
        let mut work = self.clone();
        let mut relinks: BTreeMap<Id, Id> = BTreeMap::new();
        for i in cut {
            work.tracks[i].split_relinking(t, &mut relinks, ids)?;
        }
        let right = work.tracks[target_track]
            .clips()
            .iter()
            .find(|c| c.start == t)
            .map(|c| c.id)
            .ok_or(EditError::Collision)?;
        work.set_angle(index, right, silent)?;
        *self = work;
        Ok(Some(right))
    }

    fn angle_candidates(&self, ids: &[Id]) -> Result<Vec<Vec<Clip>>, EditError> {
        Ok(angle_groups(self, ids)?.into_iter().map(|g| g.into_iter().map(|m| m.clip).collect()).collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::*;
    use sq_core_model::AngleChoice;
    use sq_core_time::TimeRange;

    fn piece(kind: TrackKind, start: i64, dur: i64, seq: Id, link: Option<Id>, index: i64, follows: bool) -> Clip {
        let mut c = clip(start, dur, 0, kind, link, None);
        c.sequence = Some(seq);
        c.angle = Some(AngleChoice { index, follows_video: follows });
        c
    }

    /// Picture on V1 and sound on A1, linked, both showing angle 0 of the Angles sequence `seq`.
    fn rig(follows: bool) -> (Timeline, Id, Id, Id) {
        let (seq, l) = (link(), link());
        let (v, a) = (
            piece(TrackKind::Video, 0, 10, seq, Some(l), 0, false),
            piece(TrackKind::Audio, 0, 10, seq, Some(l), 0, follows),
        );
        let ids = (v.id, a.id, seq);
        (timeline(vec![track(TrackKind::Video, vec![v]), track(TrackKind::Audio, vec![a])]), ids.0, ids.1, ids.2)
    }

    fn index(t: &Timeline, track: usize, n: usize) -> i64 {
        t.tracks[track].clips()[n].angle.as_ref().map_or(-1, |a| a.index)
    }

    #[test]
    fn set_angle_on_the_picture_moves_the_sound_only_when_it_follows() {
        let (mut t, v, _, _) = rig(false);
        assert_eq!(t.set_angle(2, v, &BTreeSet::new()), Ok(true));
        assert_eq!((index(&t, 0, 0), index(&t, 1, 0)), (2, 0));
        let (mut t, v, _, _) = rig(true);
        assert_eq!(t.set_angle(2, v, &BTreeSet::new()), Ok(true));
        assert_eq!((index(&t, 0, 0), index(&t, 1, 0)), (2, 2));
        assert_eq!(t.set_angle(2, v, &BTreeSet::new()), Ok(false));
    }

    #[test]
    fn set_angle_on_the_sound_switches_only_the_sound_and_skips_silent_angles() {
        let (mut t, _, a, _) = rig(false);
        assert_eq!(t.set_angle(1, a, &BTreeSet::from([1])), Ok(false)); // angle 1 has no sound: the sound keeps its angle
        assert_eq!(t.set_angle(1, a, &BTreeSet::new()), Ok(true));
        assert_eq!((index(&t, 0, 0), index(&t, 1, 0)), (0, 1));
        assert_eq!(t.set_angle(-1, a, &BTreeSet::new()), Err(EditError::ClipNotFound));
    }

    #[test]
    fn a_locked_track_refuses_the_switch() {
        let (mut t, v, _, _) = rig(true);
        t.tracks[1].is_locked = true;
        assert_eq!(t.set_angle(1, v, &BTreeSet::new()), Err(EditError::TrackLocked));
        assert_eq!((index(&t, 0, 0), index(&t, 1, 0)), (0, 0));
    }

    #[test]
    fn audio_follows_video_takes_the_picture_angle_now() {
        let (mut t, v, a, _) = rig(false);
        t.set_angle(2, v, &BTreeSet::new()).unwrap();
        assert_eq!(t.set_audio_follows_video(true, a), Ok(true));
        assert_eq!(index(&t, 1, 0), 2);
        assert!(t.tracks[1].clips()[0].angle.as_ref().is_some_and(|x| x.follows_video));
        assert_eq!(t.set_audio_follows_video(true, a), Ok(false));
    }

    #[test]
    fn switch_angle_cuts_the_picture_and_its_sound_at_the_time() {
        let (mut t, v, _, _) = rig(true);
        let right = t.switch_angle(1, s(4), v, &BTreeSet::new(), &mut FreshIds).unwrap();
        assert!(right.is_some());
        assert_eq!(t.tracks[0].clips().len(), 2);
        assert_eq!(t.tracks[1].clips().len(), 2);
        assert_eq!((index(&t, 0, 0), index(&t, 0, 1)), (0, 1));
        assert_eq!((index(&t, 1, 0), index(&t, 1, 1)), (0, 1));
        assert_eq!(t.tracks[0].clips()[1].timeline(), TimeRange::from_end(s(4), s(10)));
        // The same angle again, or a time past the end, changes nothing.
        let again = right.unwrap();
        assert_eq!(t.switch_angle(1, s(6), again, &BTreeSet::new(), &mut FreshIds), Ok(None));
        let first = t.tracks[0].clips()[0].id;
        assert_eq!(t.switch_angle(2, s(40), first, &BTreeSet::new(), &mut FreshIds), Ok(None));
    }

    #[test]
    fn angle_names_and_silent_angles_come_from_the_tracks() {
        let mut v1 = track(TrackKind::Video, vec![]);
        v1.name = "Wide".into();
        let (v2, a1) = (track(TrackKind::Video, vec![]), track(TrackKind::Audio, vec![a(0, 2)]));
        let t = timeline(vec![v1, v2, a1]);
        assert_eq!(t.angle_count(), 2);
        assert_eq!(t.angle_names(), ["Wide", "Angle 2"]);
        assert_eq!(t.silent_angles(), BTreeSet::from([1]));
    }
}
