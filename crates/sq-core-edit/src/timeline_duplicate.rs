// Swift: Timeline+Duplicate.swift
//! Lane moves of the duplicate/move family.

use crate::timeline_clipboard::TimelineClipboardExt as _;
use crate::timeline_edits::CopySpec;
use crate::timeline_three_point::TimelineThreePointExt as _;
use sq_core_model::{EditError, Member, Timeline, TrackKind, clear_main_track_attachments};
use sq_core_time::{Id, IdSource, Time};
use std::collections::{BTreeMap, BTreeSet, HashMap};

/// `extension Timeline` of Timeline+Duplicate.swift.
pub trait TimelineDuplicateExt {
    /// Moves the clips one track up or down (Opt+Up / Opt+Down). Video: up = the next higher video track. Audio alone:
    /// up = toward the video side (a lower audio number). With video and audio both in the selection, audio mirrors the
    /// video (up = a higher number), like dragging. Destination clips under a moved clip are cut or removed (overwrite).
    /// Returns false, and changes nothing, when any clip would leave the outermost lane. A locked source or destination
    /// track fails.
    fn move_to_lane(&mut self, ids: &BTreeSet<Id>, up: bool, new_ids: &mut dyn IdSource) -> Result<bool, EditError>;

    /// Cmd+Opt drag: an insert edit with a copy of the clip (and its linked partners) at `start`, on `target` for the
    /// dragged clip when given. The copies take the ids and link of `copy`; the originals stay.
    fn insert_copy(
        &mut self,
        id: Id,
        start: Time,
        target: Option<Id>,
        copy: &CopySpec,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError>;

    /// Cmd-drag: an insert edit with the clip itself. The clip (and linked partners) is lifted from its old place, which
    /// stays as a gap, and inserted at `start`: later clips on the destination and every sync-locked track move right by
    /// its length, a clip under the drop point is split. `start` is a time of the timeline before the edit. Locked tracks
    /// refuse.
    fn insert_move(&mut self, id: Id, start: Time, target: Option<Id>, ids: &mut dyn IdSource)
    -> Result<(), EditError>;

    /// Copies the clips right after the end of the selection, on the tracks they are on (overwrite). A link survives only
    /// between copies. Returns the new clip ids (the new selection).
    fn duplicate(&mut self, clips: &BTreeSet<Id>, ids: &mut dyn IdSource) -> Result<Vec<Id>, EditError>;
}

/// The destination track of each member of a group; the dragged clip (first) goes to `target` when given.
fn destinations(tl: &Timeline, group: &[Member], target: Option<Id>) -> Result<Vec<Id>, EditError> {
    let mut out: Vec<Id> = group.iter().map(|m| tl.tracks[m.track].id).collect();
    if let Some(target) = target {
        let t = tl.track(target).ok_or(EditError::ClipNotFound)?;
        if t.kind != group[0].clip.kind {
            return Err(EditError::WrongTrackKind);
        }
        out[0] = target;
    }
    Ok(out)
}

impl TimelineDuplicateExt for Timeline {
    fn insert_copy(
        &mut self,
        id: Id,
        start: Time,
        target: Option<Id>,
        copy: &CopySpec,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError> {
        let group = self.linked_group(id)?;
        let dests = destinations(self, &group, target)?;
        let placements: Vec<(sq_core_model::Clip, Id)> = group
            .iter()
            .zip(dests)
            .map(|(m, dest)| {
                let mut c = m.clip.clone();
                c.id = copy.ids.get(&m.clip.id).copied().unwrap_or_else(|| ids.next_id());
                if c.link.is_some() {
                    c.link = Some(copy.link);
                }
                c.bundle = None; // a copy never joins the original's bundle
                (c, dest)
            })
            .collect();
        let mut work = self.clone();
        work.insert(&placements, start.max(Time::ZERO), ids)?;
        *self = work;
        Ok(())
    }

    fn insert_move(
        &mut self,
        id: Id,
        start: Time,
        target: Option<Id>,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError> {
        let group = self.linked_group(id)?;
        if group.iter().any(|m| self.tracks[m.track].is_locked) {
            return Err(EditError::TrackLocked);
        }
        let dests = destinations(self, &group, target)?;
        let mut work = self.clone();
        work.lift_clips(&group.iter().map(|m| m.clip.id).collect::<Vec<_>>())?;
        let placements: Vec<(sq_core_model::Clip, Id)> =
            group.into_iter().zip(dests).map(|(m, d)| (m.clip, d)).collect();
        work.insert(&placements, start.max(Time::ZERO), ids)?;
        *self = work;
        Ok(())
    }

    fn duplicate(&mut self, clips: &BTreeSet<Id>, ids: &mut dyn IdSource) -> Result<Vec<Id>, EditError> {
        let cb = self.clipboard(clips).ok_or(EditError::ClipNotFound)?;
        let end = self
            .tracks
            .iter()
            .flat_map(|t| t.clips())
            .filter(|c| clips.contains(&c.id))
            .map(|c| c.timeline().end())
            .max();
        let lanes: HashMap<TrackKind, usize> = [TrackKind::Video, TrackKind::Audio]
            .into_iter()
            .filter_map(|k| cb.lowest_lane(k).map(|l| (k, l)))
            .collect();
        let mut work = self.clone();
        let made = work.paste(&cb, end.unwrap_or(Time::ZERO), Some(&lanes), false, ids)?;
        *self = work;
        Ok(made)
    }

    fn move_to_lane(&mut self, ids: &BTreeSet<Id>, up: bool, new_ids: &mut dyn IdSource) -> Result<bool, EditError> {
        let members: Vec<Member> = ids.iter().filter_map(|id| self.find(*id)).collect();
        if members.is_empty() {
            return Err(EditError::ClipNotFound);
        }
        if members.iter().any(|m| self.tracks[m.track].is_locked) {
            return Err(EditError::TrackLocked);
        }
        let mixed = members.iter().any(|m| m.clip.kind == TrackKind::Video)
            && members.iter().any(|m| m.clip.kind == TrackKind::Audio);
        let mut plan: Vec<(Member, usize)> = Vec::new();
        for m in members {
            let lane: Vec<usize> = (0..self.tracks.len()).filter(|&i| self.tracks[i].kind == m.clip.kind).collect();
            let Some(at) = lane.iter().position(|&i| i == m.track) else { continue };
            let step: isize = match m.clip.kind {
                TrackKind::Video => {
                    if up {
                        1
                    } else {
                        -1
                    }
                }
                TrackKind::Audio => {
                    if mixed == up {
                        1
                    } else {
                        -1
                    }
                }
            };
            let Some(dest) = at.checked_add_signed(step).and_then(|to| lane.get(to)).copied() else { return Ok(false) };
            plan.push((m, dest));
        }
        if plan.iter().any(|(_, d)| self.tracks[*d].is_locked) {
            return Err(EditError::TrackLocked);
        }
        let mut work = self.tracks.clone();
        for (m, _) in &plan {
            work[m.track].remove(m.clip.id);
        }
        let mut relinks: BTreeMap<Id, Id> = BTreeMap::new();
        plan.sort_by_key(|(m, _)| m.clip.start);
        for (m, dest) in &plan {
            work[*dest].overwrite_relinking(m.clip.clone(), &mut relinks, new_ids)?;
        }
        if !work.iter().all(|t| t.is_consistent()) {
            return Err(EditError::Collision);
        }
        clear_main_track_attachments(&mut work);
        self.tracks = work;
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{Clip, SequenceFormat, Track};
    use sq_core_time::{SequentialIds, Time, TimeRange};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }
    fn clip(n: u128, start: i64, kind: TrackKind) -> Clip {
        Clip::new(Id::from_u128(n), "c", Id::from_u128(n + 5000), kind, TimeRange::new(Time::ZERO, s(4)), s(start))
    }
    fn track(n: u128, kind: TrackKind, clips: Vec<Clip>) -> Track {
        let mut t = Track::new(Id::from_u128(n), kind);
        t.set_clips(clips);
        t
    }
    fn tl(tracks: Vec<Track>) -> Timeline {
        Timeline::new(Id::from_u128(500), "t", SequenceFormat::new(Time::new(1, 30)), tracks)
    }
    fn one(id: u128) -> BTreeSet<Id> {
        [Id::from_u128(id)].into_iter().collect()
    }

    #[test]
    fn video_up_moves_to_the_next_higher_video_track_and_cuts_what_is_there() {
        let mut t = tl(vec![
            track(10, TrackKind::Video, vec![clip(1, 0, TrackKind::Video)]),
            track(11, TrackKind::Video, vec![clip(2, 2, TrackKind::Video)]),
        ]);
        assert_eq!(t.move_to_lane(&one(1), true, &mut SequentialIds::default()), Ok(true));
        assert!(t.tracks[0].clips().is_empty());
        assert_eq!(t.tracks[1].clips().iter().map(|c| c.start).collect::<Vec<_>>(), vec![s(0), s(4)]);
        assert_eq!(t.tracks[1].clips()[0].id, Id::from_u128(1));
    }

    #[test]
    fn the_outermost_lane_returns_false_and_changes_nothing() {
        let mut t = tl(vec![track(10, TrackKind::Video, vec![clip(1, 0, TrackKind::Video)])]);
        let before = t.clone();
        assert_eq!(t.move_to_lane(&one(1), true, &mut SequentialIds::default()), Ok(false));
        assert_eq!(t, before);
    }

    #[test]
    fn audio_alone_goes_up_toward_the_video_side() {
        let mut t = tl(vec![
            track(10, TrackKind::Audio, vec![]),
            track(11, TrackKind::Audio, vec![clip(1, 0, TrackKind::Audio)]),
        ]);
        assert_eq!(t.move_to_lane(&one(1), true, &mut SequentialIds::default()), Ok(true));
        assert_eq!(t.tracks[0].clips().len(), 1);
    }

    #[test]
    fn locked_and_unknown_fail() {
        let mut t = tl(vec![
            track(10, TrackKind::Video, vec![clip(1, 0, TrackKind::Video)]),
            track(11, TrackKind::Video, vec![]),
        ]);
        let mut ids = SequentialIds::default();
        assert_eq!(t.move_to_lane(&one(9), true, &mut ids), Err(EditError::ClipNotFound));
        t.tracks[1].is_locked = true;
        assert_eq!(t.move_to_lane(&one(1), true, &mut ids), Err(EditError::TrackLocked));
    }
}
