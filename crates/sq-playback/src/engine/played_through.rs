//! The newest frame drawn of each place of a file while playing: a stand-in never goes back behind it.
//!
//! One file can be on screen twice (the outgoing and the incoming clip of a cut, both cut from the same recording), far
//! apart in the file. One floor per file merged them: the incoming clip's frame 1552 became the floor of the outgoing clip
//! at frame 1199, no cached frame was "newer" than that and "passed" by the playhead, so the stand-in was refused and the
//! frame waited for the exact picture (234 ms gap at a cut under load, real project). A floor belongs to one place only:
//! the frames within `STAND_IN_REACH` of it.

use sq_core_time::Id;
use std::collections::HashMap;

use super::core::STAND_IN_REACH;

#[derive(Default)]
pub(crate) struct PlayedThrough {
    places: HashMap<Id, Vec<i64>>,
}

impl PlayedThrough {
    pub(crate) fn clear(&mut self) {
        self.places.clear();
    }

    /// The floor of the place `index` of `media` belongs to, if a frame near it was drawn.
    pub(crate) fn floor(&self, media: Id, index: i64) -> Option<i64> {
        self.places
            .get(&media)?
            .iter()
            .copied()
            .filter(|f| (f - index).abs() <= STAND_IN_REACH)
            .min_by_key(|f| (f - index).abs())
    }

    /// A frame of `media` was drawn: moves the floor of its place on (forward: up, backward: down), or starts a new place.
    pub(crate) fn note(&mut self, media: Id, drawn: i64, forward: bool) {
        let places = self.places.entry(media).or_default();
        match places.iter_mut().filter(|f| (**f - drawn).abs() <= STAND_IN_REACH).min_by_key(|f| (**f - drawn).abs()) {
            Some(f) => *f = if forward { (*f).max(drawn) } else { (*f).min(drawn) },
            None => places.push(drawn),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn two_clips_of_one_file_keep_their_own_floors() {
        let media = Id::from_u128(1);
        let mut p = PlayedThrough::default();
        p.note(media, 1199, true);
        p.note(media, 1552, true); // the incoming clip is drawn too
        assert_eq!(p.floor(media, 1199), Some(1199), "the outgoing clip's floor is not the incoming clip's frame");
        assert_eq!(p.floor(media, 1555), Some(1552));
        p.note(media, 1200, true);
        assert_eq!(p.floor(media, 1201), Some(1200));
    }

    #[test]
    fn a_floor_only_moves_the_way_the_playhead_goes() {
        let media = Id::from_u128(1);
        let mut p = PlayedThrough::default();
        p.note(media, 50, true);
        p.note(media, 48, true);
        assert_eq!(p.floor(media, 52), Some(50));
        let mut r = PlayedThrough::default();
        r.note(media, 50, false);
        r.note(media, 52, false);
        assert_eq!(r.floor(media, 48), Some(50));
    }

    #[test]
    fn a_far_place_gives_no_floor() {
        let media = Id::from_u128(1);
        let mut p = PlayedThrough::default();
        p.note(media, 1552, true);
        assert_eq!(p.floor(media, 1199), None);
    }
}
