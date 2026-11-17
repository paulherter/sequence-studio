// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MediaRobustness.swift (`Conform` and `conform(index:...)`; `check` drives the platform importer, decoder and audio
// source and is the corpus-test and `EngineBench validate` harness: it is rebuilt on the ffmpeg decoder when that tool is)
//! Frame-rate conform walk: how a media of one rate looks on a sequence of another.

use crate::sample_index::SampleIndex;
use sq_core_model::{Clip, TrackKind};
use sq_core_time::{Id, Time, TimeRange};

/// Sequence-frame walk of the media (looped back to back) on a sequence of another rate, through `Clip::source_time` and the
/// render loop's frame pick (`SampleIndex::frame_at`, clamped).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Conform {
    pub sequence_frames: usize,
    /// Largest (sequence time - shown frame's start), in frames of the shown frame. < 1 = never a frame behind.
    pub max_lag_frames: f64,
    /// Lag at the last sequence frame (drift at the end of `length`).
    pub end_drift_frames: f64,
    /// Media frames shown twice in a row (slower media rate) / never shown (faster media rate).
    pub repeated_frames: usize,
    pub skipped_frames: usize,
}

/// a / b as a number (reporting only; time stays rational).
fn ratio(a: Time, b: Time) -> f64 {
    if b.value() == 0 {
        0.0
    } else {
        (a.value() as f64 * b.timescale() as f64) / (a.timescale() as f64 * b.value() as f64)
    }
}

/// The media is placed as back-to-back copies (each `index.duration()` long) from time 0; `length` of a sequence at frame
/// duration `fd` is walked frame by frame.
pub fn conform(index: &SampleIndex, sequence_frame_duration: Time, length: Time) -> Conform {
    let mut c = Conform::default();
    let fd = sequence_frame_duration;
    let d = index.duration();
    if index.count() == 0 || d <= Time::ZERO || fd <= Time::ZERO {
        return c;
    }
    let mut copy: i64 = 0;
    let mut clip = Clip::new(Id::NIL, "conform", Id::NIL, TrackKind::Video, TimeRange::new(Time::ZERO, d), Time::ZERO);
    clip.media_duration = Some(d);
    let mut prev: Option<i64> = None;
    let mut n: i64 = 0;
    while fd * n < length {
        let t = fd * n;
        while t >= clip.start + d {
            copy += 1;
            clip.start = d * copy;
        }
        let s = clip.source_time(t, fd);
        let f = index.frame_at(s).unwrap_or(if s < index.entries()[0].pts { 0 } else { index.count() - 1 });
        let e = index.entries()[f];
        let lag = ratio(s - e.pts, e.duration);
        c.max_lag_frames = c.max_lag_frames.max(lag.abs());
        c.end_drift_frames = lag;
        let g = copy * index.count() as i64 + f as i64;
        if let Some(p) = prev {
            if g == p {
                c.repeated_frames += 1;
            } else if g > p + 1 {
                c.skipped_frames += (g - p - 1) as usize;
            }
        }
        prev = Some(g);
        n += 1;
    }
    c.sequence_frames = n as usize;
    c
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sample_index::Entry;

    fn index(frames: i64, fd: Time) -> SampleIndex {
        SampleIndex::new(
            (0..frames)
                .map(|i| Entry { pts: fd * i, dts: fd * i, duration: fd, is_sync: true, decode_ordinal: i })
                .collect(),
        )
    }

    #[test]
    fn a_slower_media_repeats_frames_and_never_skips() {
        let r = conform(&index(24, Time::new(1, 24)), Time::new(1, 30), Time::new(4, 1));
        assert_eq!(r.sequence_frames, 120);
        assert_eq!(r.skipped_frames, 0);
        assert!(r.repeated_frames > 0 && r.max_lag_frames < 1.0, "{r:?}");
    }

    #[test]
    fn a_faster_media_skips_frames_and_never_repeats() {
        let r = conform(&index(60, Time::new(1, 60)), Time::new(1, 30), Time::new(4, 1));
        assert_eq!(r.sequence_frames, 120);
        assert_eq!(r.repeated_frames, 0);
        assert!(r.skipped_frames > 0 && r.max_lag_frames < 1.0, "{r:?}");
    }

    #[test]
    fn the_same_rate_shows_every_frame_once_and_nothing_without_a_rate() {
        let r = conform(&index(30, Time::new(1, 30)), Time::new(1, 30), Time::new(3, 1));
        assert_eq!((r.sequence_frames, r.repeated_frames, r.skipped_frames), (90, 0, 0));
        assert_eq!(r.max_lag_frames, 0.0);
        assert_eq!(conform(&index(0, Time::new(1, 30)), Time::new(1, 30), Time::new(3, 1)), Conform::default());
    }
}
