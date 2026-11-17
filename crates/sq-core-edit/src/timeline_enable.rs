// Swift: Timeline+Enable.swift
//! Enable / Disable Clip.

use sq_core_model::{EditError, Member, Timeline};
use sq_core_time::Id;
use std::collections::BTreeSet;

/// `extension Timeline` of Timeline+Enable.swift.
pub trait TimelineEnableExt {
    /// Enable / Disable Clip (Shift+Cmd+E) on the clips and their linked partners as one group. When any of them is
    /// disabled, all are enabled; otherwise all are disabled. Locked tracks refuse. Returns the new state.
    fn toggle_enabled(&mut self, ids: &BTreeSet<Id>) -> Result<bool, EditError>;
}

impl TimelineEnableExt for Timeline {
    fn toggle_enabled(&mut self, ids: &BTreeSet<Id>) -> Result<bool, EditError> {
        let mut group: Vec<Member> = Vec::new();
        let mut seen = BTreeSet::new();
        for id in ids {
            for m in self.linked_group(*id)? {
                if seen.insert(m.clip.id) {
                    group.push(m);
                }
            }
        }
        if group.is_empty() {
            return Err(EditError::ClipNotFound);
        }
        if group.iter().any(|m| self.tracks[m.track].is_locked) {
            return Err(EditError::TrackLocked);
        }
        let enable = group.iter().any(|m| !m.clip.is_enabled);
        for m in group {
            let mut c = m.clip;
            c.is_enabled = enable;
            self.tracks[m.track].replace(c);
        }
        Ok(enable)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{Clip, SequenceFormat, Track, TrackKind};
    use sq_core_time::{Time, TimeRange};

    fn clip(n: u128, kind: TrackKind, link: Option<u128>) -> Clip {
        let mut c = Clip::new(
            Id::from_u128(n),
            "c",
            Id::from_u128(n + 5000),
            kind,
            TimeRange::new(Time::ZERO, Time::new(4, 1)),
            Time::ZERO,
        );
        c.link = link.map(Id::from_u128);
        c
    }
    fn timeline() -> Timeline {
        let (mut v, mut a) =
            (Track::new(Id::from_u128(10), TrackKind::Video), Track::new(Id::from_u128(11), TrackKind::Audio));
        v.set_clips(vec![clip(1, TrackKind::Video, Some(90))]);
        a.set_clips(vec![clip(2, TrackKind::Audio, Some(90))]);
        Timeline::new(Id::from_u128(500), "t", SequenceFormat::new(Time::new(1, 30)), vec![v, a])
    }
    fn ids(n: &[u128]) -> BTreeSet<Id> {
        n.iter().map(|n| Id::from_u128(*n)).collect()
    }
    fn states(t: &Timeline) -> Vec<bool> {
        t.tracks.iter().flat_map(|tr| tr.clips().iter().map(|c| c.is_enabled)).collect()
    }

    #[test]
    fn toggles_the_clip_and_its_linked_partner_together() {
        let mut t = timeline();
        assert_eq!(t.toggle_enabled(&ids(&[1])), Ok(false));
        assert_eq!(states(&t), vec![false, false]);
        assert_eq!(t.toggle_enabled(&ids(&[2])), Ok(true));
        assert_eq!(states(&t), vec![true, true]);
    }

    #[test]
    fn any_disabled_member_enables_all() {
        let mut t = timeline();
        let mut c = t.tracks[0].clips()[0].clone();
        c.is_enabled = false;
        t.tracks[0].replace(c);
        assert_eq!(t.toggle_enabled(&ids(&[1])), Ok(true));
        assert_eq!(states(&t), vec![true, true]);
    }

    #[test]
    fn locked_track_and_unknown_clip_refuse() {
        let mut t = timeline();
        assert_eq!(t.toggle_enabled(&ids(&[9])), Err(EditError::ClipNotFound));
        assert_eq!(t.toggle_enabled(&ids(&[])), Err(EditError::ClipNotFound));
        t.tracks[1].is_locked = true;
        assert_eq!(t.toggle_enabled(&ids(&[1])), Err(EditError::TrackLocked));
        assert_eq!(states(&t), vec![true, true]);
    }
}
