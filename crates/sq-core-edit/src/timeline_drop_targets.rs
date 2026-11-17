// Swift: Timeline+DropTargets.swift
//! Where a dropped media item lands (Premiere): video on the track under the pointer, its linked audio on the
//! mirrored audio track A(n) for V(n). One rule for Finder drops, Project-panel drops and the drop ghost.

use sq_core_model::{Timeline, Track, TrackKind};
use sq_core_time::{Id, IdSource};

/// The tracks one dropped item goes to.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct DropTargets {
    /// Track for the picture.
    pub video: Option<Id>,
    /// Existing audio track the audio lands on; `None` when `new_audio_ordinal` says it must be created first.
    pub audio: Option<Id>,
    /// Zero-based audio track ordinal (A1 = 0) that does not exist yet and is created for the drop.
    pub new_audio_ordinal: Option<usize>,
}

/// `extension Timeline` of Timeline+DropTargets.swift.
pub trait TimelineDropTargetsExt {
    /// Zero-based position of a track among the tracks of its kind (V1 / A1 = 0).
    fn ordinal(&self, id: Id) -> Option<usize>;
    /// The audio track with that ordinal.
    fn audio_track_at(&self, n: usize) -> Option<Id>;
    /// Targets for one dropped item. `pointer` is the track under the pointer (any kind) or `None`.
    /// - Video goes to the pointer's video track, else the targeted, else the first video track.
    /// - Audio goes to the audio track with the same ordinal as that video track (V2 -> A2); a missing one is reported
    ///   in `new_audio_ordinal`. Audio-only items dropped on an audio track stay on that track.
    /// - Without any video track the audio falls back to the targeted or first audio track.
    fn drop_targets(&self, pointer: Option<Id>, has_video: bool, has_audio: bool) -> DropTargets;
    /// Appends audio tracks until one with `ordinal` exists; returns its id.
    fn ensure_audio_track(&mut self, ordinal: usize, ids: &mut dyn IdSource) -> Id;
}

impl TimelineDropTargetsExt for Timeline {
    fn ordinal(&self, id: Id) -> Option<usize> {
        let t = self.track(id)?;
        self.tracks.iter().filter(|x| x.kind == t.kind).position(|x| x.id == id)
    }

    fn audio_track_at(&self, n: usize) -> Option<Id> {
        self.tracks.iter().filter(|t| t.kind == TrackKind::Audio).nth(n).map(|t| t.id)
    }

    fn drop_targets(&self, pointer: Option<Id>, has_video: bool, has_audio: bool) -> DropTargets {
        let pointed = pointer.and_then(|p| self.track(p));
        let mut out = DropTargets::default();
        if let Some(p) = pointed.filter(|p| !has_video && has_audio && p.kind == TrackKind::Audio) {
            out.audio = Some(p.id);
            return out;
        }
        let video = |t: &&Track| t.kind == TrackKind::Video;
        let v = pointed
            .filter(|p| p.kind == TrackKind::Video)
            .map(|p| p.id)
            .or_else(|| self.tracks.iter().filter(video).find(|t| t.is_targeted).map(|t| t.id))
            .or_else(|| self.tracks.iter().find(|t| t.kind == TrackKind::Video).map(|t| t.id));
        if has_video {
            out.video = v;
        }
        if has_audio {
            if let Some((v, n)) = v.and_then(|v| self.ordinal(v).map(|n| (v, n))) {
                let _ = v;
                match self.audio_track_at(n) {
                    Some(a) => out.audio = Some(a),
                    None => out.new_audio_ordinal = Some(n),
                }
            } else {
                out.audio = self
                    .tracks
                    .iter()
                    .find(|t| t.kind == TrackKind::Audio && t.is_targeted)
                    .or_else(|| self.tracks.iter().find(|t| t.kind == TrackKind::Audio))
                    .map(|t| t.id);
                if out.audio.is_none() {
                    out.new_audio_ordinal = Some(0);
                }
            }
        }
        out
    }

    fn ensure_audio_track(&mut self, ordinal: usize, ids: &mut dyn IdSource) -> Id {
        loop {
            if let Some(id) = self.audio_track_at(ordinal) {
                return id;
            }
            let is_first = !self.tracks.iter().any(|t| t.kind == TrackKind::Audio);
            let mut t = Track::new(ids.next_id(), TrackKind::Audio);
            t.is_targeted = is_first;
            self.tracks.push(t);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{Clip, SequenceFormat, SourcePlacement, ThreePointMode};
    use sq_core_time::{SequentialIds, Time, TimeRange};

    fn timeline(video: usize, audio: usize) -> Timeline {
        let mut ids = TestIds(100);
        let tracks = Timeline::default_tracks(video, audio, &mut ids);
        Timeline::new(Id::from_u128(500), "t", SequenceFormat::new(Time::new(1, 30)), tracks)
    }
    struct TestIds(u128);
    impl IdSource for TestIds {
        fn next_id(&mut self) -> Id {
            self.0 += 1;
            Id::from_u128(self.0)
        }
    }
    fn nth(t: &Timeline, kind: TrackKind, n: usize) -> Id {
        t.tracks.iter().filter(|x| x.kind == kind).nth(n).map(|x| x.id).unwrap_or(Id::NIL)
    }
    fn v(t: &Timeline, n: usize) -> Id {
        nth(t, TrackKind::Video, n)
    }
    fn a(t: &Timeline, n: usize) -> Id {
        nth(t, TrackKind::Audio, n)
    }

    #[test]
    fn audio_mirrors_the_video_track() {
        let t = timeline(3, 2);
        let r = t.drop_targets(Some(v(&t, 1)), true, true);
        assert_eq!((r.video, r.audio, r.new_audio_ordinal), (Some(v(&t, 1)), Some(a(&t, 1)), None));
    }

    #[test]
    fn missing_mirrored_audio_track_is_reported_and_created() {
        let mut t = timeline(3, 2);
        let r = t.drop_targets(Some(v(&t, 2)), true, true);
        assert_eq!((r.audio, r.new_audio_ordinal), (None, Some(2)));
        let id = t.ensure_audio_track(2, &mut SequentialIds::default());
        assert_eq!(t.tracks.iter().filter(|x| x.kind == TrackKind::Audio).count(), 3);
        assert_eq!(t.ordinal(id), Some(2));
        assert_eq!(t.drop_targets(Some(v(&t, 2)), true, true).audio, Some(id));
    }

    #[test]
    fn no_pointer_uses_targeted_video_and_its_mirror() {
        let t = timeline(3, 2);
        let r = t.drop_targets(None, true, true);
        assert_eq!((r.video, r.audio), (Some(v(&t, 0)), Some(a(&t, 0))));
    }

    #[test]
    fn audio_only_on_audio_track_stays_there() {
        let t = timeline(3, 2);
        assert_eq!(t.drop_targets(Some(a(&t, 1)), false, true).audio, Some(a(&t, 1)));
        assert_eq!(t.drop_targets(Some(v(&t, 1)), false, true).audio, Some(a(&t, 1)));
    }

    #[test]
    fn video_only_has_no_audio_target() {
        let t = timeline(3, 2);
        let r = t.drop_targets(Some(v(&t, 1)), true, false);
        assert_eq!((r.video, r.audio, r.new_audio_ordinal), (Some(v(&t, 1)), None, None));
    }

    #[test]
    fn audio_overwrite_is_per_target_track() {
        let mut t = timeline(3, 2);
        let other = Clip::new(
            Id::from_u128(1),
            "x",
            Id::from_u128(2),
            TrackKind::Audio,
            TimeRange::new(Time::ZERO, Time::new(10, 1)),
            Time::ZERO,
        );
        let a0 = a(&t, 0);
        assert!(t.overwrite(&[(other.clone(), a0)], Time::ZERO, &mut TestIds(900)).is_ok());
        // Drop on V2: audio lands on A2, A1 is untouched.
        let r = t.drop_targets(Some(v(&t, 1)), true, true);
        let src = SourcePlacement::new(TimeRange::new(Time::ZERO, Time::new(4, 1)), Id::from_u128(3), "m");
        let targets = [r.video.unwrap_or(Id::NIL), r.audio.unwrap_or(Id::NIL)];
        assert!(
            t.three_point_edit(&src, &targets, Time::new(2, 1), ThreePointMode::Overwrite, &mut TestIds(800)).is_ok()
        );
        assert_eq!(t.track(a0).map(|x| x.clips().to_vec()), Some(vec![other]));
        assert_eq!(t.track(a(&t, 1)).map(|x| x.clips().len()), Some(1));
    }
}
