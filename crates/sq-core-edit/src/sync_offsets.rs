// Swift: SyncOffsets.swift
//! Frames by which linked clips have drifted apart.

use sq_core_model::{Timeline, TrackKind};
use sq_core_time::{Id, Time};
use std::collections::BTreeMap;

/// `extension Timeline` of SyncOffsets.swift.
pub trait SyncOffsetsExt {
    /// Frames by which linked clips have drifted apart (the red out-of-sync badge). Only video and audio clips of the
    /// same linked group that play the same media count: the video clip is the reference, the audio clip shows `+n`
    /// when it plays n frames later than it should and the video clip shows `-n`. In-sync clips (or less than half a
    /// frame off) are absent.
    fn sync_offsets(&self) -> BTreeMap<Id, i64>;
}

/// Nearest whole number of frames (half away from zero), exact on rational time.
fn rounded_frames(d: Time, frame: Time) -> i64 {
    // d / frame = (d.value * frame.timescale) / (d.timescale * frame.value)
    let n = i128::from(d.value()) * i128::from(frame.timescale());
    let m = i128::from(d.timescale()) * i128::from(frame.value());
    if m == 0 {
        return 0;
    }
    let q = (n.abs() * 2 + m) / (2 * m);
    i64::try_from(if n < 0 { -q } else { q }).unwrap_or(0)
}

impl SyncOffsetsExt for Timeline {
    fn sync_offsets(&self) -> BTreeMap<Id, i64> {
        let fd = self.frame_duration();
        let mut groups: BTreeMap<Id, Vec<&sq_core_model::Clip>> = BTreeMap::new();
        for c in self.tracks.iter().flat_map(|t| t.clips()) {
            if let Some(l) = c.link.filter(|_| !c.is_generator()) {
                groups.entry(l).or_default().push(c);
            }
        }
        let mut out = BTreeMap::new();
        for clips in groups.values() {
            let Some(v) = clips.iter().find(|c| c.kind == TrackKind::Video) else { continue };
            let v_shift = v.start - v.source.start;
            for a in clips.iter().filter(|c| c.kind == TrackKind::Audio && c.media == v.media) {
                let d = (a.start - a.source.start) - v_shift;
                let frames = rounded_frames(d, fd);
                if frames != 0 {
                    out.insert(a.id, frames);
                    out.insert(v.id, -frames);
                }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{Clip, SequenceFormat, Track};
    use sq_core_time::TimeRange;

    fn fd() -> Time {
        Time::new(1001, 30000)
    }
    struct Pair {
        a_start: Time,
        a_src: i64,
        a_media: u128,
        a_link: u128,
    }
    impl Pair {
        fn new(a_start: i64) -> Pair {
            Pair { a_start: fd() * a_start, a_src: 0, a_media: 7, a_link: 90 }
        }
        fn build(&self, v_start: i64) -> (Timeline, Clip, Clip) {
            let mut v = Clip::new(
                Id::from_u128(1),
                "v",
                Id::from_u128(7),
                TrackKind::Video,
                TimeRange::new(Time::ZERO, fd() * 100),
                fd() * v_start,
            );
            let mut a = Clip::new(
                Id::from_u128(2),
                "a",
                Id::from_u128(self.a_media),
                TrackKind::Audio,
                TimeRange::new(fd() * self.a_src, fd() * 100),
                self.a_start,
            );
            v.link = Some(Id::from_u128(90));
            a.link = Some(Id::from_u128(self.a_link));
            let (mut vt, mut at) =
                (Track::new(Id::from_u128(10), TrackKind::Video), Track::new(Id::from_u128(11), TrackKind::Audio));
            vt.set_clips(vec![v.clone()]);
            at.set_clips(vec![a.clone()]);
            (Timeline::new(Id::from_u128(500), "t", SequenceFormat::new(fd()), vec![vt, at]), v, a)
        }
    }

    #[test]
    fn in_sync_pair_has_no_badge() {
        assert!(Pair::new(10).build(10).0.sync_offsets().is_empty());
    }

    #[test]
    fn moved_audio_shows_plus_on_audio_and_minus_on_video() {
        let (t, v, a) = Pair::new(13).build(10);
        let o = t.sync_offsets();
        assert!(o.get(&a.id) == Some(&3) && o.get(&v.id) == Some(&-3));
    }

    #[test]
    fn moved_earlier_is_negative_on_audio() {
        let (t, _, a) = Pair::new(7).build(10);
        assert_eq!(t.sync_offsets().get(&a.id), Some(&-3));
    }

    #[test]
    fn slipped_source_counts_too() {
        // Same timeline start, but the audio shows source 5 frames later than the video: 5 frames out of sync.
        let mut p = Pair::new(10);
        p.a_src = 5;
        let (t, v, a) = p.build(10);
        assert!(t.sync_offsets().get(&a.id) == Some(&-5) && t.sync_offsets().get(&v.id) == Some(&5));
    }

    #[test]
    fn both_moved_together_stays_in_sync() {
        // Trimming the head of both (start and source move together) keeps them in sync.
        let (t, mut v, mut a) = Pair::new(14).build(14);
        v.source.start = fd() * 4;
        a.source.start = fd() * 4;
        let mut t = t;
        t.tracks[0].replace(v);
        t.tracks[1].replace(a);
        assert!(t.sync_offsets().is_empty());
    }

    #[test]
    fn different_media_or_no_link_is_ignored() {
        let mut p = Pair::new(13);
        p.a_media = 8; // e.g. a voice-over linked on purpose
        assert!(p.build(10).0.sync_offsets().is_empty());
        let mut q = Pair::new(13);
        q.a_link = 91; // different link groups
        assert!(q.build(10).0.sync_offsets().is_empty());
    }

    #[test]
    fn sub_frame_difference_rounds_to_zero() {
        let mut p = Pair::new(10);
        p.a_start = fd() * 10 + Time::new(1, 100_000);
        assert!(p.build(10).0.sync_offsets().is_empty());
    }
}
