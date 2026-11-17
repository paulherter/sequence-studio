// Swift: Timeline+Targeting.swift
//! Track target buttons.

use sq_core_model::Timeline;
use sq_core_time::Id;

/// `extension Timeline` of Timeline+Targeting.swift.
pub trait TimelineTargetingExt {
    /// Click on a track's target button. Plain click flips that track. Shift-click sets every track of the same kind to
    /// the state the clicked one is switching to. Option-click targets only that track of its kind (the others of the
    /// kind go off). Locked tracks may still be (un)targeted.
    fn toggle_target(&mut self, id: Id, shift: bool, option: bool);
}

impl TimelineTargetingExt for Timeline {
    fn toggle_target(&mut self, id: Id, shift: bool, option: bool) {
        let Some(i) = self.tracks.iter().position(|t| t.id == id) else { return };
        let kind = self.tracks[i].kind;
        if option {
            for (j, t) in self.tracks.iter_mut().enumerate().filter(|(_, t)| t.kind == kind) {
                t.is_targeted = j == i;
            }
        } else if shift {
            let on = !self.tracks[i].is_targeted;
            for t in self.tracks.iter_mut().filter(|t| t.kind == kind) {
                t.is_targeted = on;
            }
        } else {
            self.tracks[i].is_targeted = !self.tracks[i].is_targeted;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{SequenceFormat, TrackKind};
    use sq_core_time::{SequentialIds, Time};

    fn timeline() -> Timeline {
        let tracks = Timeline::default_tracks(2, 2, &mut SequentialIds::default());
        Timeline::new(Id::from_u128(500), "t", SequenceFormat::new(Time::new(1, 30)), tracks)
    }
    fn flags(t: &Timeline, kind: TrackKind) -> Vec<bool> {
        t.tracks.iter().filter(|x| x.kind == kind).map(|x| x.is_targeted).collect()
    }

    #[test]
    fn plain_click_flips_one_track() {
        let mut t = timeline();
        let second = t.tracks[1].id;
        t.toggle_target(second, false, false);
        assert_eq!(flags(&t, TrackKind::Video), vec![true, true]);
        t.toggle_target(second, false, false);
        assert_eq!(flags(&t, TrackKind::Video), vec![true, false]);
        assert_eq!(flags(&t, TrackKind::Audio), vec![true, false]);
    }

    #[test]
    fn shift_click_sets_every_track_of_the_kind_to_the_new_state() {
        let mut t = timeline();
        let second = t.tracks[1].id;
        t.toggle_target(second, true, false);
        assert_eq!(flags(&t, TrackKind::Video), vec![true, true]);
        t.toggle_target(second, true, false);
        assert_eq!(flags(&t, TrackKind::Video), vec![false, false]);
    }

    #[test]
    fn option_click_targets_only_that_track_of_its_kind() {
        let mut t = timeline();
        let second = t.tracks[1].id;
        t.toggle_target(second, false, true);
        assert_eq!(flags(&t, TrackKind::Video), vec![false, true]);
        assert_eq!(flags(&t, TrackKind::Audio), vec![true, false]);
        t.toggle_target(Id::from_u128(999), false, true); // unknown track: nothing happens
        assert_eq!(flags(&t, TrackKind::Video), vec![false, true]);
    }
}
