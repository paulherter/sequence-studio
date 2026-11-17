//! Source Monitor Insert / Overwrite: which part of the source, where on the sequence, onto which tracks.
// Swift: Timeline+SourceEdit.swift

use crate::timeline_drop_targets::TimelineDropTargetsExt as _;
use sq_core_model::{Clip, MediaRef, SequenceFormat, SourceMarks, Timeline, Track, TrackKind};
use sq_core_time::{Id, IdSource, Time, TimeRange};

/// Which streams of a source an edit places (Premiere: the video-only / audio-only drag icons).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SourceStreams {
    Both,
    VideoOnly,
    AudioOnly,
}

impl SourceStreams {
    /// The edit places the picture.
    pub fn includes_video(self) -> bool {
        self != SourceStreams::AudioOnly
    }

    /// The edit places the sound.
    pub fn includes_audio(self) -> bool {
        self != SourceStreams::VideoOnly
    }
}

/// Swift `Timeline.sourceEditRange`, `sourceEditPosition` and `sourceTimeline`.
pub trait TimelineSourceEditExt {
    /// Source range of an edit: In defaults to the media start, Out to its end. None when the range is empty.
    fn source_edit_range(marks: &SourceMarks, total: Time) -> Option<TimeRange>;

    /// Where the edit lands: the sequence In point when one is set, else the playhead (Premiere three-point rule;
    /// the sequence Out does not shorten the source here because our In/Out always carries both ends).
    fn source_edit_position(&self, playhead: Time) -> Time;

    /// Destination tracks. The edit uses the targeted tracks (first targeted video, first targeted audio); a kind without a
    /// targeted track is dropped (Premiere). With no targeted track at all the default drop rule applies (V1 and its
    /// mirrored audio track, created when missing). `None` when nothing is left to place.
    fn source_edit_targets(
        &mut self,
        has_video: bool,
        has_audio: bool,
        streams: SourceStreams,
        ids: &mut dyn IdSource,
    ) -> Option<Vec<Id>>;

    /// One-clip sequence that the Source Monitor plays: V1 (+ A1) holding the whole media, in the media's own format.
    fn source_timeline(
        media: &MediaRef,
        format: SequenceFormat,
        has_video: bool,
        has_audio: bool,
        duration: Time,
        is_still: bool,
        ids: &mut dyn IdSource,
    ) -> Timeline;
}

impl TimelineSourceEditExt for Timeline {
    fn source_edit_range(marks: &SourceMarks, total: Time) -> Option<TimeRange> {
        let start = marks.mark_in.unwrap_or(Time::ZERO).max(Time::ZERO);
        let end = marks.mark_out.unwrap_or(total).min(total);
        (end > start).then(|| TimeRange::from_end(start, end))
    }

    fn source_edit_position(&self, playhead: Time) -> Time {
        self.in_out.map_or(playhead, |io| io.start)
    }

    fn source_edit_targets(
        &mut self,
        has_video: bool,
        has_audio: bool,
        streams: SourceStreams,
        ids: &mut dyn IdSource,
    ) -> Option<Vec<Id>> {
        let (want_v, want_a) = (has_video && streams.includes_video(), has_audio && streams.includes_audio());
        if !want_v && !want_a {
            return None;
        }
        let mut out: Vec<Id> = Vec::new();
        if self.tracks.iter().any(|t| t.is_targeted) {
            let first = |tl: &Timeline, kind| tl.tracks.iter().find(|t| t.kind == kind && t.is_targeted).map(|t| t.id);
            out.extend(first(self, TrackKind::Video).filter(|_| want_v));
            out.extend(first(self, TrackKind::Audio).filter(|_| want_a));
        } else {
            let d = self.drop_targets(None, want_v, want_a);
            out.extend(d.video);
            match (d.audio, d.new_audio_ordinal) {
                (Some(a), _) => out.push(a),
                (None, Some(n)) => out.push(self.ensure_audio_track(n, ids)),
                (None, None) => {}
            }
        }
        (!out.is_empty()).then_some(out)
    }

    fn source_timeline(
        media: &MediaRef,
        format: SequenceFormat,
        has_video: bool,
        has_audio: bool,
        duration: Time,
        is_still: bool,
        ids: &mut dyn IdSource,
    ) -> Timeline {
        let mut v = Track::new(ids.next_id(), TrackKind::Video);
        let mut a = Track::new(ids.next_id(), TrackKind::Audio);
        let link = (has_video && has_audio).then(|| ids.next_id());
        let clip = |k: TrackKind, ids: &mut dyn IdSource| {
            let mut c =
                Clip::new(ids.next_id(), &media.name, media.id, k, TimeRange::new(Time::ZERO, duration), Time::ZERO);
            c.link = link;
            c.media_duration = if is_still { None } else { Some(duration) };
            c.is_still = is_still;
            c
        };
        let mut tracks = Vec::new();
        // Swift's `try?` ignores the overwrite error; into an empty track it cannot fail.
        if has_video {
            let c = clip(TrackKind::Video, ids);
            let _ = v.overwrite(c, ids);
        }
        if has_audio {
            let c = clip(TrackKind::Audio, ids);
            let _ = a.overwrite(c, ids);
        }
        if has_video || !has_audio {
            tracks.push(v);
        }
        if has_audio {
            tracks.push(a);
        }
        Timeline::new(ids.next_id(), &media.name, format, tracks)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::SequentialIds;

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }
    fn marks(i: Option<i64>, o: Option<i64>) -> SourceMarks {
        SourceMarks { mark_in: i.map(s), mark_out: o.map(s), ..SourceMarks::default() }
    }

    #[test]
    fn range_defaults_and_clamps() {
        let r = |m: &SourceMarks| Timeline::source_edit_range(m, s(10));
        assert_eq!(r(&marks(None, None)), Some(TimeRange::from_end(s(0), s(10))));
        assert_eq!(r(&marks(Some(2), None)), Some(TimeRange::from_end(s(2), s(10))));
        assert_eq!(r(&marks(None, Some(4))), Some(TimeRange::from_end(s(0), s(4))));
        assert_eq!(r(&marks(Some(2), Some(30))).map(|x| x.end()), Some(s(10)));
        assert_eq!(r(&marks(Some(10), None)), None);
    }

    #[test]
    fn position_prefers_sequence_in() {
        let mut t = Timeline::new(sq_core_time::Id::NIL, "t", SequenceFormat::new(Time::new(1, 30)), vec![]);
        assert_eq!(t.source_edit_position(s(7)), s(7));
        t.in_out = Some(TimeRange::from_end(s(3), s(9)));
        assert_eq!(t.source_edit_position(s(7)), s(3));
    }

    #[test]
    fn source_timeline_holds_whole_media() {
        let mut ids = SequentialIds::default();
        let m = MediaRef::new(sq_core_time::Id::from_u128(5), "m", "/x", sq_core_model::MediaFingerprint::new(1));
        let f = SequenceFormat::new(Time::new(1, 30));
        let tl = Timeline::source_timeline(&m, f.clone(), true, true, s(5), false, &mut ids);
        assert_eq!(tl.duration(), s(5));
        assert_eq!(tl.tracks.len(), 2);
        let audio_only = Timeline::source_timeline(&m, f, false, true, s(5), false, &mut ids);
        assert_eq!(audio_only.tracks.iter().map(|t| t.kind).collect::<Vec<_>>(), [TrackKind::Audio]);
    }
}
