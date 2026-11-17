//! How loud a clip is heard, per window of timeline time.
// Swift: ClipLevels.swift

use sq_core_model::{Clip, TrackPan};
use sq_core_time::{Time, TimeRange};

/// How loud a clip is HEARD, per window of timeline time: the source level (peak, supplied by the caller) mapped through
/// the clip's own time mapping (reverse, constant speed, speed ramps), times Audio Gain, the volume line and the track fader.
/// Silence and dialogue detection read this, so a pause is a pause as played, not as stored in the file.
pub struct ClipLevels;

impl ClipLevels {
    /// About 10 ms windows, an exact fraction of the clip duration (no Double time): `(window, count)`.
    pub fn window(duration: Time) -> (Time, i64) {
        // Capped at 1e9 windows (~116 days) so an absurd (corrupt) duration cannot overflow the integer conversion.
        let n = ((duration.value() as f64 / duration.timescale() as f64 * 100.0).ceil().min(1e9) as i64).max(1);
        (Time::scaled_int(duration, 1, n), n)
    }

    /// Audible level (linear) of every window of `clip`, in clip-local order, and the window length.
    /// `source_peak` returns the linear peak of the media in a source time range (any channel).
    pub fn audible(
        clip: &Clip,
        track_volume_db: f64,
        mut source_peak: impl FnMut(TimeRange) -> f32,
    ) -> (Vec<f32>, Time) {
        let dur = clip.timeline().duration;
        if dur <= Time::ZERO {
            return (Vec::new(), dur);
        }
        let (w, n) = Self::window(dur);
        let track = TrackPan::linear(track_volume_db) as f32;
        let min_span = Time::new(1, 1000);
        let mut levels = Vec::with_capacity(n as usize);
        for i in 0..n {
            let (a, b) = (w * i, w * (i + 1));
            let mut src = clip.source_range(a, b);
            if src.duration < min_span {
                src = TimeRange::new(src.start, min_span);
            }
            let heard = clip.volume(clip.start + Time::scaled_int(w, 2 * i + 1, 2)) as f32;
            levels.push(source_peak(src) * heard * track);
        }
        (levels, w)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::TrackKind;
    use sq_core_time::Id;
    use std::cell::RefCell;

    fn clip(dur: i64) -> Clip {
        Clip::new(
            Id::from_u128(1),
            "c",
            Id::from_u128(2),
            TrackKind::Audio,
            TimeRange::new(Time::ZERO, Time::new(dur, 1)),
            Time::ZERO,
        )
    }

    #[test]
    fn windows_are_ten_milliseconds_and_cover_the_clip_exactly() {
        let (w, n) = ClipLevels::window(Time::new(2, 1));
        assert_eq!((w, n), (Time::new(1, 100), 200));
        assert_eq!(ClipLevels::window(Time::new(1, 1000)).1, 1);
    }

    #[test]
    fn levels_multiply_source_peak_gain_and_track_fader() {
        let mut c = clip(1);
        c.audio_gain_db = 6.0;
        let seen = RefCell::new(Vec::new());
        let (levels, w) = ClipLevels::audible(&c, -6.0, |r| {
            seen.borrow_mut().push(r);
            0.5
        });
        assert_eq!(levels.len(), 100);
        assert_eq!(w, Time::new(1, 100));
        let expect = 0.5 * 10.0_f64.powf(6.0 / 20.0) as f32 * TrackPan::linear(-6.0) as f32;
        assert!(levels.iter().all(|l| (l - expect).abs() < 1e-6));
        assert_eq!(seen.borrow()[0], TimeRange::new(Time::ZERO, Time::new(1, 100)));
    }

    #[test]
    fn a_reversed_clip_asks_the_media_backwards_and_an_empty_clip_has_no_windows() {
        let mut c = clip(1);
        c.reversed = true;
        let first = RefCell::new(None);
        ClipLevels::audible(&c, 0.0, |r| {
            first.borrow_mut().get_or_insert(r);
            1.0
        });
        assert_eq!(*first.borrow(), Some(TimeRange::from_end(Time::new(99, 100), Time::new(1, 1))));
        let empty = Clip::new(
            Id::from_u128(1),
            "e",
            Id::from_u128(2),
            TrackKind::Audio,
            TimeRange::new(Time::ZERO, Time::ZERO),
            Time::ZERO,
        );
        assert!(ClipLevels::audible(&empty, 0.0, |_| 1.0).0.is_empty());
    }
}
