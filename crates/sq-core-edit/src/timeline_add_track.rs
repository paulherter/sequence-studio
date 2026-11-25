//! Port of `Timeline+AddTrack.swift`.

use sq_core_model::{Timeline, Track, TrackKind};
use sq_core_time::{Id, IdSource};

/// `extension Timeline` of `Timeline+AddTrack.swift`.
pub trait AddTrackExt {
    /// Appends a track of `kind`: a new top video track (V n+1) or a new bottom audio track (A n+1). The first track of
    /// its kind becomes the edit target. This is what dropping onto a ghost track does.
    fn add_track(&mut self, kind: TrackKind, ids: &mut dyn IdSource) -> Id;

    /// Sequence > Add Track: a new empty track right after the last one of its kind (a new top video track, a new bottom
    /// audio track); the first video track goes to the bottom, the first audio track to the end. The UI command and the
    /// edit API both call this.
    fn insert_track_after_last(&mut self, kind: TrackKind, ids: &mut dyn IdSource) -> Id;
}

impl AddTrackExt for Timeline {
    fn add_track(&mut self, kind: TrackKind, ids: &mut dyn IdSource) -> Id {
        let mut t = Track::new(ids.next_id(), kind);
        t.is_targeted = !self.tracks.iter().any(|x| x.kind == kind);
        let id = t.id;
        self.tracks.push(t);
        id
    }

    fn insert_track_after_last(&mut self, kind: TrackKind, ids: &mut dyn IdSource) -> Id {
        let track = Track::new(ids.next_id(), kind);
        let id = track.id;
        let at = match self.tracks.iter().rposition(|x| x.kind == kind) {
            Some(i) => i + 1,
            None if kind == TrackKind::Video => 0,
            None => self.tracks.len(),
        };
        self.tracks.insert(at, track);
        id
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::SequentialIds;

    #[test]
    fn insert_goes_after_the_last_track_of_its_kind() {
        let mut ids = SequentialIds::default();
        let tracks = Timeline::default_tracks(1, 1, &mut ids);
        let mut tl = Timeline::new(
            ids.next_id(),
            "T",
            sq_core_model::SequenceFormat::new(sq_core_time::Time::new(1, 25)),
            tracks,
        );
        let kinds = |t: &Timeline| t.tracks.iter().map(|x| x.kind).collect::<Vec<_>>();
        let before = kinds(&tl);
        let v = tl.insert_track_after_last(TrackKind::Video, &mut ids);
        let a = tl.insert_track_after_last(TrackKind::Audio, &mut ids);
        assert_eq!(tl.tracks.len(), before.len() + 2);
        let (vi, ai) = (tl.tracks.iter().position(|t| t.id == v), tl.tracks.iter().position(|t| t.id == a));
        assert!(vi < ai, "video tracks sit above audio tracks");
        assert_eq!(tl.tracks.iter().filter(|t| t.kind == TrackKind::Video).count(), 2);
        assert_eq!(tl.tracks.last().map(|t| t.id), Some(a));
    }

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
