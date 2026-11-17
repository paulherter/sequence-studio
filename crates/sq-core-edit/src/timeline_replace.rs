// Swift: Timeline+Replace.swift
//! Property edits of one clip.

use sq_core_model::{Clip, EditError, Timeline};

/// `extension Timeline` of Timeline+Replace.swift.
pub trait TimelineReplaceExt {
    /// Replaces a clip by ID with `clip` for property edits (animation, name, volume...). The timeline position and
    /// source range must stay the same, so the track stays consistent: a timing change is `Collision` (use the trim
    /// and move edits for those). Fails with `ClipNotFound`, or `TrackLocked` for a locked track.
    fn replace_clip(&mut self, clip: Clip) -> Result<(), EditError>;

    /// Housekeeping after every edit (Swift `normalizeAudioKeyMarks`, Fades.swift): prunes key marks and lets an audio
    /// transition replace the fade on its edge. A clip on a locked track is left as it is.
    fn normalize_audio_key_marks(&mut self);
}

impl TimelineReplaceExt for Timeline {
    fn replace_clip(&mut self, clip: Clip) -> Result<(), EditError> {
        let ti = self.tracks.iter().position(|t| t.clip(clip.id).is_some()).ok_or(EditError::ClipNotFound)?;
        let old = self.tracks[ti].clip(clip.id).ok_or(EditError::ClipNotFound)?;
        if self.tracks[ti].is_locked {
            return Err(EditError::TrackLocked);
        }
        if old.start != clip.start
            || old.source != clip.source
            || old.speed != clip.speed
            || old.reversed != clip.reversed
        {
            return Err(EditError::Collision);
        }
        self.tracks[ti].replace(clip);
        Ok(())
    }

    fn normalize_audio_key_marks(&mut self) {
        for c in self.audio_key_mark_fixes() {
            let _ = self.replace_clip(c);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{SequenceFormat, Track, TrackKind};
    use sq_core_time::{Id, Time, TimeRange};

    fn timeline() -> (Timeline, Clip) {
        let c = Clip::new(
            Id::from_u128(1),
            "c",
            Id::from_u128(2),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::new(4, 1)),
            Time::new(1, 1),
        );
        let mut track = Track::new(Id::from_u128(3), TrackKind::Video);
        track.set_clips(vec![c.clone()]);
        (Timeline::new(Id::from_u128(4), "T", SequenceFormat::new(Time::new(1, 30)), vec![track]), c)
    }

    #[test]
    fn normalize_audio_key_marks_prunes_marks_of_gone_keys() {
        let mut c = Clip::new(
            Id::from_u128(2),
            "a",
            Id::from_u128(9),
            TrackKind::Audio,
            TimeRange::new(Time::ZERO, Time::new(4, 1)),
            Time::ZERO,
        );
        c.duck_key_ids = vec![Id::from_u128(77)];
        let mut track = Track::new(Id::from_u128(3), TrackKind::Audio);
        track.set_clips(vec![c]);
        let mut tl = Timeline::new(Id::from_u128(4), "T", SequenceFormat::new(Time::new(1, 30)), vec![track]);
        tl.normalize_audio_key_marks();
        assert!(tl.tracks[0].clips()[0].duck_key_ids.is_empty());
    }

    #[test]
    fn replaces_properties_of_the_same_clip() {
        let (mut t, mut c) = timeline();
        c.name = "renamed".into();
        assert_eq!(t.replace_clip(c), Ok(()));
        assert_eq!(t.tracks[0].clips()[0].name, "renamed");
    }

    #[test]
    fn unknown_clip_fails() {
        let (mut t, mut c) = timeline();
        c.id = Id::from_u128(99);
        assert_eq!(t.replace_clip(c), Err(EditError::ClipNotFound));
    }

    #[test]
    fn refuses_timing_change() {
        let (mut t, mut c) = timeline();
        c.start = Time::new(9, 1);
        assert_eq!(t.replace_clip(c), Err(EditError::Collision));
    }

    #[test]
    fn locked_track_fails() {
        let (mut t, mut c) = timeline();
        t.tracks[0].is_locked = true;
        c.name = "x".into();
        assert_eq!(t.replace_clip(c), Err(EditError::TrackLocked));
    }
}
