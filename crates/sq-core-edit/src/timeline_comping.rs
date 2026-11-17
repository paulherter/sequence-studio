// Swift: Timeline+Comping.swift
//! Take comping: several takes of one performance sit on stacked tracks of the same kind; picking a take for a range
//! lets that take play there and silences / hides the others, without touching track mute, solo or visibility.

use sq_core_model::{EditError, Timeline};
use sq_core_time::{Id, IdSource, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

/// `extension Timeline` of Timeline+Comping.swift.
pub trait TimelineCompingExt {
    /// The tracks that hold the other takes for `clip_id` over `range`: unlocked tracks of the same kind (other than the
    /// clip's own) with a clip overlapping `range`. Indices into `tracks`, top to bottom.
    fn take_stack_tracks(&self, clip_id: Id, range: TimeRange) -> Vec<usize>;
    /// Whether `comp_take` has other takes to silence for this clip over `range`.
    fn can_comp_take(&self, clip_id: Id, range: TimeRange) -> bool;
    /// Uses the take `clip_id` is on for the part of `range` it covers: every track of the same kind that holds an
    /// overlapping clip is cut at the range edges, the clips of the other takes inside the range are disabled and the
    /// clips of the chosen track inside it are enabled. Linked partners (the audio of a picture take) follow their
    /// clip. Returns the chosen track's clips inside the range. Fails with `ClipNotFound` when the clip is unknown or
    /// nothing is left of the range, `TrackLocked` for a locked chosen track, `NotACut` when there is no other take.
    fn comp_take(&mut self, clip_id: Id, range: TimeRange, ids: &mut dyn IdSource) -> Result<Vec<Id>, EditError>;
}

impl TimelineCompingExt for Timeline {
    fn take_stack_tracks(&self, clip_id: Id, range: TimeRange) -> Vec<usize> {
        let Some(own) = self.tracks.iter().position(|t| t.clips().iter().any(|c| c.id == clip_id)) else {
            return Vec::new();
        };
        let kind = self.tracks[own].kind;
        (0..self.tracks.len())
            .filter(|&i| {
                i != own
                    && self.tracks[i].kind == kind
                    && !self.tracks[i].is_locked
                    && self.tracks[i].clips().iter().any(|c| c.timeline().overlaps(&range))
            })
            .collect()
    }

    fn can_comp_take(&self, clip_id: Id, range: TimeRange) -> bool {
        let Some(own) = self.tracks.iter().find(|t| t.clips().iter().any(|c| c.id == clip_id)).filter(|t| !t.is_locked)
        else {
            return false;
        };
        let Some(c) = own.clips().iter().find(|c| c.id == clip_id) else { return false };
        let Some(r) = range.intersection(&c.timeline()).filter(|r| !r.is_empty()) else { return false };
        !self.take_stack_tracks(clip_id, r).is_empty()
    }

    fn comp_take(&mut self, clip_id: Id, range: TimeRange, ids: &mut dyn IdSource) -> Result<Vec<Id>, EditError> {
        let own = self
            .tracks
            .iter()
            .position(|t| t.clips().iter().any(|c| c.id == clip_id))
            .ok_or(EditError::ClipNotFound)?;
        let clip = self.tracks[own].clips().iter().find(|c| c.id == clip_id).ok_or(EditError::ClipNotFound)?;
        let r = range.intersection(&clip.timeline()).filter(|r| !r.is_empty()).ok_or(EditError::ClipNotFound)?;
        if self.tracks[own].is_locked {
            return Err(EditError::TrackLocked);
        }
        let others = self.take_stack_tracks(clip_id, r);
        if others.is_empty() {
            return Err(EditError::NotACut);
        }
        let stack: Vec<usize> = std::iter::once(own).chain(others).collect();
        // Cut the take tracks and the tracks of linked partners, so a split pair stays a pair.
        let links: BTreeSet<Id> = stack
            .iter()
            .flat_map(|&i| self.tracks[i].clips().iter().filter(|c| c.timeline().overlaps(&r)).filter_map(|c| c.link))
            .collect();
        let mut cut_tracks: BTreeSet<usize> = stack.iter().copied().collect();
        for i in 0..self.tracks.len() {
            if self.tracks[i]
                .clips()
                .iter()
                .any(|c| c.timeline().overlaps(&r) && c.link.is_some_and(|l| links.contains(&l)))
            {
                // A locked partner track refuses the whole edit before anything is cut.
                if self.tracks[i].is_locked {
                    return Err(EditError::TrackLocked);
                }
                cut_tracks.insert(i);
            }
        }
        let mut relinks: BTreeMap<Id, Id> = BTreeMap::new();
        for &i in &cut_tracks {
            self.tracks[i].split_relinking(r.start, &mut relinks, ids)?;
            self.tracks[i].split_relinking(r.end(), &mut relinks, ids)?;
        }
        // Inside the range: the chosen track plays, the others are off; partners take their clip's state.
        let mut chosen = Vec::new();
        let mut state: BTreeMap<Id, bool> = BTreeMap::new();
        for &i in &stack {
            for c in self.tracks[i].clips().iter().filter(|c| c.start >= r.start && c.timeline().end() <= r.end()) {
                if let Some(l) = c.link {
                    state.insert(l, i == own);
                }
            }
        }
        // Halves of a split pair got fresh links: state of the right halves follows through the relink map.
        for (old, new) in &relinks {
            if let Some(on) = state.get(old).copied() {
                state.insert(*new, on);
            }
        }
        for &i in &cut_tracks {
            for mut c in self.tracks[i].clips().to_vec() {
                if c.start < r.start || c.timeline().end() > r.end() {
                    continue;
                }
                if stack.contains(&i) {
                    c.is_enabled = i == own;
                    let id = c.id;
                    self.tracks[i].replace(c);
                    if i == own {
                        chosen.push(id);
                    }
                } else if let Some(on) = c.link.and_then(|l| state.get(&l).copied()) {
                    c.is_enabled = on;
                    self.tracks[i].replace(c);
                }
            }
        }
        Ok(chosen)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{Clip, SequenceFormat, Track, TrackKind};
    use sq_core_time::{SequentialIds, Time};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }
    fn clip(n: u128, start: i64, dur: i64, kind: TrackKind, link: Option<u128>) -> Clip {
        let mut c = Clip::new(
            Id::from_u128(n),
            "c",
            Id::from_u128(n + 5000),
            kind,
            TimeRange::new(Time::ZERO, s(dur)),
            s(start),
        );
        c.link = link.map(Id::from_u128);
        c
    }
    fn track(n: u128, kind: TrackKind, clips: Vec<Clip>) -> Track {
        let mut t = Track::new(Id::from_u128(n), kind);
        t.set_clips(clips);
        t
    }
    fn tl(tracks: Vec<Track>) -> Timeline {
        Timeline::new(Id::from_u128(500), "t", SequenceFormat::new(Time::new(1, 30)), tracks)
    }
    fn stack(takes: u128) -> (Timeline, Vec<Clip>) {
        let cs: Vec<Clip> = (0..takes).map(|i| clip(100 + i, 0, 20, TrackKind::Audio, None)).collect();
        let tracks =
            cs.iter().enumerate().map(|(i, c)| track(10 + i as u128, TrackKind::Audio, vec![c.clone()])).collect();
        (tl(tracks), cs)
    }
    fn range(a: i64, d: i64) -> TimeRange {
        TimeRange::new(s(a), s(d))
    }

    #[test]
    fn picks_take_in_range_only() {
        let (mut t, cs) = stack(2);
        let chosen = t.comp_take(cs[1].id, range(5, 5), &mut SequentialIds::default());
        assert_eq!(chosen.as_ref().map(Vec::len), Ok(1));
        let t0: Vec<(Time, bool)> = t.tracks[0].clips().iter().map(|c| (c.start, c.is_enabled)).collect();
        assert_eq!(t0, vec![(s(0), true), (s(5), false), (s(10), true)]);
        let mid = t.tracks[1].clips().iter().find(|c| c.start == s(5));
        assert!(mid.is_some_and(|m| m.is_enabled));
        assert_eq!(mid.map(|m| m.id), chosen.ok().and_then(|c| c.first().copied()));
    }

    #[test]
    fn does_not_touch_track_switches() {
        let (mut t, cs) = stack(2);
        t.tracks[0].is_muted = true;
        assert!(t.comp_take(cs[1].id, range(0, 20), &mut SequentialIds::default()).is_ok());
        assert!(t.tracks[0].is_muted && !t.tracks[0].is_solo && !t.tracks[1].is_muted);
        assert!(t.tracks[0].clips().iter().all(|c| !c.is_enabled));
    }

    #[test]
    fn range_clamped_to_clip() {
        let (mut t, cs) = stack(2);
        assert!(t.comp_take(cs[0].id, range(15, 50), &mut SequentialIds::default()).is_ok());
        let off: Vec<Time> = t.tracks[1].clips().iter().filter(|c| !c.is_enabled).map(|c| c.start).collect();
        assert_eq!(off, vec![s(15)]);
    }

    #[test]
    fn refusals() {
        let mut ids = SequentialIds::default();
        let (mut one, c1) = stack(1);
        assert_eq!(one.comp_take(c1[0].id, range(0, 5), &mut ids), Err(EditError::NotACut));
        assert!(!one.can_comp_take(c1[0].id, range(0, 5)));
        let (mut two, c2) = stack(2);
        assert!(two.can_comp_take(c2[0].id, range(0, 5)));
        assert_eq!(two.comp_take(c2[0].id, range(30, 5), &mut ids), Err(EditError::ClipNotFound));
        two.tracks[0].is_locked = true;
        assert_eq!(two.comp_take(c2[0].id, range(0, 5), &mut ids), Err(EditError::TrackLocked));
    }

    #[test]
    fn locked_other_take_is_ignored() {
        let (mut t, cs) = stack(3);
        t.tracks[0].is_locked = true;
        assert!(t.comp_take(cs[2].id, range(2, 4), &mut SequentialIds::default()).is_ok());
        assert_eq!(t.tracks[0].clips().len(), 1);
        assert_eq!(t.tracks[1].clips().len(), 3);
    }

    fn pair_timeline(lock_last_audio: bool) -> (Timeline, Clip) {
        let c0 = clip(100, 0, 20, TrackKind::Video, Some(900));
        let c1 = clip(101, 0, 20, TrackKind::Video, Some(901));
        let mut a1 = track(13, TrackKind::Audio, vec![clip(103, 0, 20, TrackKind::Audio, Some(901))]);
        a1.is_locked = lock_last_audio;
        let t = tl(vec![
            track(10, TrackKind::Video, vec![c0]),
            track(11, TrackKind::Video, vec![c1.clone()]),
            track(12, TrackKind::Audio, vec![clip(102, 0, 20, TrackKind::Audio, Some(900))]),
            a1,
        ]);
        (t, c1)
    }

    #[test]
    fn linked_partner_follows_its_take() {
        let (mut t, c1) = pair_timeline(false);
        assert!(t.comp_take(c1.id, range(4, 4), &mut SequentialIds::default()).is_ok());
        let off = t.tracks[2].clips().iter().find(|c| c.start == s(4));
        let on = t.tracks[3].clips().iter().find(|c| c.start == s(4));
        assert_eq!(off.map(|c| c.is_enabled), Some(false));
        assert_eq!(on.map(|c| c.is_enabled), Some(true));
        let v_off = t.tracks[0].clips().iter().find(|c| c.start == s(4));
        assert_eq!(v_off.map(|c| c.link), off.map(|c| c.link));
        assert!(t.tracks[2].clips().len() == 3 && t.tracks[0].clips().len() == 3);
    }

    #[test]
    fn locked_partner_track_refuses_and_changes_nothing() {
        let (mut t, c1) = pair_timeline(true);
        let before = t.clone();
        assert_eq!(t.comp_take(c1.id, range(4, 4), &mut SequentialIds::default()), Err(EditError::TrackLocked));
        assert_eq!(t, before);
    }

    #[test]
    fn locked_own_track_cannot_comp() {
        let (mut t, cs) = stack(2);
        t.tracks[1].is_locked = true;
        assert!(!t.can_comp_take(cs[1].id, range(0, 5)));
    }
}
