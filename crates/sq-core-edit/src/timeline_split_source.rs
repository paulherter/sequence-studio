// Swift: Timeline+SplitSource.swift
//! Split source edit (Mark Audio In / Mark Video In).

use crate::timeline_magnetic_ops::MagneticOpsExt;
use sq_core_model::{AnimatedProperty, Clip, EditError, ThreePointMode, Timeline, TrackKind};
use sq_core_time::{Id, IdSource, Time, TimeRange, Vec2};

/// Everything a split source edit needs besides the timeline.
#[derive(Clone, Debug, PartialEq)]
pub struct SplitSourceEdit {
    /// The source media.
    pub media: Id,
    /// Name of the new clips.
    pub name: String,
    /// Where the picture starts in the media.
    pub video_in: Time,
    /// Where the sound starts in the media.
    pub audio_in: Time,
    /// Where both end in the media.
    pub out: Time,
    /// Length of the media, when known.
    pub media_duration: Option<Time>,
    /// Scale of the new picture clips (1 = untouched).
    pub initial_scale: f64,
    /// Tracks for the picture.
    pub video_tracks: Vec<Id>,
    /// Tracks for the sound.
    pub audio_tracks: Vec<Id>,
    /// Where the picture lands.
    pub at: Time,
    /// Insert or overwrite.
    pub mode: ThreePointMode,
}

/// `extension Timeline` of Timeline+SplitSource.swift.
pub trait TimelineSplitSourceExt {
    /// Split source edit: picture and sound of one source start at different source points and end together at `out`.
    /// The picture lands at `at`, the sound `video_in - audio_in` earlier (a J cut; later for a negative lead, an L
    /// start), and the clips share one link. Insert ripples with the picture; the sound is laid over its tracks. A sound
    /// start before sequence time 0 moves its source start up by the overshoot. One atomic edit: any failure leaves the
    /// timeline unchanged. Not for Fast Cut sequences (`Collision`, callers use the plain source edit there).
    fn split_source_edit(&mut self, e: &SplitSourceEdit, ids: &mut dyn IdSource) -> Result<(), EditError>;
}

impl TimelineSplitSourceExt for Timeline {
    fn split_source_edit(&mut self, e: &SplitSourceEdit, ids: &mut dyn IdSource) -> Result<(), EditError> {
        if self.is_fast_cut() {
            return Err(EditError::Collision);
        }
        if !(e.out > e.video_in && e.out > e.audio_in && e.video_in >= Time::ZERO && e.audio_in >= Time::ZERO) {
            return Err(EditError::EmptyClip);
        }
        if e.media_duration.is_some_and(|md| e.out > md) {
            return Err(EditError::EmptyClip);
        }
        if e.video_tracks.is_empty() || e.audio_tracks.is_empty() {
            return Err(EditError::ClipNotFound);
        }
        let mut work = self.clone();
        let link = ids.next_id();
        let mut audio_start = e.at - (e.video_in - e.audio_in);
        let mut audio_source = e.audio_in;
        if audio_start < Time::ZERO {
            audio_source = e.audio_in - audio_start;
            audio_start = Time::ZERO;
            if e.out <= audio_source {
                return Err(EditError::EmptyClip);
            }
        }
        let mut placements = |track_ids: &[Id], source: TimeRange| -> Result<Vec<(Clip, Id)>, EditError> {
            track_ids
                .iter()
                .map(|id| {
                    let kind = work.track(*id).ok_or(EditError::ClipNotFound)?.kind;
                    let mut c = Clip::new(ids.next_id(), &e.name, e.media, kind, source, Time::ZERO);
                    c.link = Some(link);
                    c.media_duration = e.media_duration;
                    if kind == TrackKind::Video && (e.initial_scale - 1.0).abs() > 1e-12 {
                        c.animation.scale = AnimatedProperty::new(Vec2 { x: e.initial_scale, y: e.initial_scale });
                    }
                    Ok((c, *id))
                })
                .collect()
        };
        let v = placements(&e.video_tracks, TimeRange::from_end(e.video_in, e.out))?;
        let a = placements(&e.audio_tracks, TimeRange::from_end(audio_source, e.out))?;
        match e.mode {
            ThreePointMode::Insert => work.insert(&v, e.at, ids)?,
            ThreePointMode::Overwrite => work.overwrite(&v, e.at, ids)?,
        }
        work.overwrite(&a, audio_start, ids)?;
        *self = work;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{SequenceFormat, Track};
    use sq_core_time::SequentialIds;

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }
    fn clip(n: u128, dur: i64, kind: TrackKind) -> Clip {
        Clip::new(Id::from_u128(n), "c", Id::from_u128(n + 5000), kind, TimeRange::new(Time::ZERO, s(dur)), Time::ZERO)
    }
    fn timeline(v: Vec<Clip>, a: Vec<Clip>) -> Timeline {
        let mut vt = Track::new(Id::from_u128(10), TrackKind::Video);
        let mut at = Track::new(Id::from_u128(11), TrackKind::Audio);
        vt.set_clips(v);
        at.set_clips(a);
        Timeline::new(Id::from_u128(500), "t", SequenceFormat::new(Time::new(1, 30)), vec![vt, at])
    }
    fn edit(video_in: i64, audio_in: i64, out: i64, at: i64, mode: ThreePointMode) -> SplitSourceEdit {
        SplitSourceEdit {
            media: Id::from_u128(77),
            name: String::new(),
            video_in: s(video_in),
            audio_in: s(audio_in),
            out: s(out),
            media_duration: None,
            initial_scale: 1.0,
            video_tracks: vec![Id::from_u128(10)],
            audio_tracks: vec![Id::from_u128(11)],
            at: s(at),
            mode,
        }
    }
    fn new_clip(t: &Timeline, track: usize) -> Clip {
        t.tracks[track]
            .clips()
            .iter()
            .find(|c| c.media == Id::from_u128(77))
            .cloned()
            .unwrap_or_else(|| unreachable!("placed clip"))
    }

    #[test]
    fn audio_starts_earlier_and_both_end_together_linked() {
        let mut t = timeline(vec![clip(1, 20, TrackKind::Video)], vec![clip(2, 20, TrackKind::Audio)]);
        let mut e = edit(12, 10, 16, 5, ThreePointMode::Overwrite);
        e.media_duration = Some(s(60));
        assert_eq!(t.split_source_edit(&e, &mut SequentialIds::default()), Ok(()));
        let (nv, na) = (new_clip(&t, 0), new_clip(&t, 1));
        assert!(nv.start == s(5) && nv.timeline().end() == s(9));
        assert!(na.start == s(3) && na.timeline().end() == s(9));
        assert!(nv.source.start == s(12) && na.source.start == s(10));
        assert!(nv.link.is_some() && nv.link == na.link);
    }

    #[test]
    fn sound_before_sequence_start_is_trimmed() {
        let mut t = timeline(vec![], vec![]);
        assert_eq!(
            t.split_source_edit(&edit(10, 5, 14, 2, ThreePointMode::Insert), &mut SequentialIds::default()),
            Ok(())
        );
        let na = new_clip(&t, 1);
        assert!(na.start == Time::ZERO && na.source.start == s(8) && na.timeline().end() == s(6));
    }

    #[test]
    fn refusals_change_nothing() {
        let mut t = timeline(vec![], vec![]);
        let before = t.clone();
        let mut ids = SequentialIds::default();
        assert_eq!(
            t.split_source_edit(&edit(10, 5, 8, 2, ThreePointMode::Insert), &mut ids),
            Err(EditError::EmptyClip)
        );
        let mut none = edit(1, 0, 4, 0, ThreePointMode::Insert);
        none.audio_tracks.clear();
        assert_eq!(t.split_source_edit(&none, &mut ids), Err(EditError::ClipNotFound));
        let mut short = edit(1, 0, 4, 0, ThreePointMode::Insert);
        short.media_duration = Some(s(3));
        assert_eq!(t.split_source_edit(&short, &mut ids), Err(EditError::EmptyClip));
        assert_eq!(t, before);
    }
}
