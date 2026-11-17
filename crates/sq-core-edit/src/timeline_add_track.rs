//! Port of `Timeline+AddTrack.swift`.

use sq_core_model::{Timeline, Track, TrackKind};
use sq_core_time::{Id, IdSource};

/// `extension Timeline` of `Timeline+AddTrack.swift`.
pub trait AddTrackExt {
    /// Appends a track of `kind`: a new top video track (V n+1) or a new bottom audio track (A n+1). The first track of
    /// its kind becomes the edit target. This is what dropping onto a ghost track does.
    fn add_track(&mut self, kind: TrackKind, ids: &mut dyn IdSource) -> Id;
}

impl AddTrackExt for Timeline {
    fn add_track(&mut self, kind: TrackKind, ids: &mut dyn IdSource) -> Id {
        let mut t = Track::new(ids.next_id(), kind);
        t.is_targeted = !self.tracks.iter().any(|x| x.kind == kind);
        let id = t.id;
        self.tracks.push(t);
        id
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::SequentialIds;

    #[test]
    fn first_track_of_a_kind_is_targeted() {
        let mut ids = SequentialIds::default();
        let tracks = Timeline::default_tracks(1, 0, &mut ids);
        let mut tl = Timeline::new(
            ids.next_id(),
            "T",
            sq_core_model::SequenceFormat::new(sq_core_time::Time::new(1, 25)),
            tracks,
        );
        let a = tl.add_track(TrackKind::Audio, &mut ids);
        let v = tl.add_track(TrackKind::Video, &mut ids);
        assert!(tl.track(a).is_some_and(|t| t.is_targeted));
        assert!(tl.track(v).is_some_and(|t| !t.is_targeted));
        assert_eq!(tl.tracks.len(), 3);
    }
}
