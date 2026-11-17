// Swift: SilenceRemoval.swift (the Timeline edits `removeCuts`, `removeSilences` and `softenJoins` wait for the edit crate)
//! Pause shortening ("Remove Silences"): turns detected pauses into frame-aligned ripple cuts that leave a fixed pad of
//! the pause on each side. A timeline edit; the media is never changed. Always run by an explicit command.

use sq_core_model::Clip;
use sq_core_time::{Time, TimeRange};

/// Namespace of the cut maths.
pub enum SilenceRemoval {}

// Largest whole number of frames not above `t` (the model keeps the same helper private in `FadeKeys`).
fn snap_down(t: Time, frame: Time) -> Time {
    if t <= Time::ZERO || frame <= Time::ZERO {
        return Time::ZERO;
    }
    frame * t.frame_index(frame)
}

fn ceil_frame(t: Time, frame: Time) -> Time {
    let n = t.frame_index(frame);
    let f = frame * n;
    if f == t { f } else { frame * (n + 1) }
}

impl SilenceRemoval {
    /// Cuts for `silences` (timeline time). Each pause loses everything except `padding` at both ends; the cut is shrunk
    /// to whole frames (start rounded up, end rounded down) so no cut lands between frames. Pauses that leave less than
    /// one frame to cut are dropped. Sorted, non-overlapping.
    pub fn cuts(silences: &[TimeRange], padding: Time, frame_duration: Time) -> Vec<TimeRange> {
        let mut out: Vec<TimeRange> = Vec::new();
        let mut sorted = silences.to_vec();
        sorted.sort_by_key(|s| s.start);
        for s in sorted {
            let a = ceil_frame(s.start + padding, frame_duration);
            let b = snap_down(s.end() - padding, frame_duration);
            if b - a < frame_duration {
                continue;
            }
            if out.last().is_some_and(|last| a < last.end()) {
                continue;
            }
            out.push(TimeRange::new(a, b - a));
        }
        out
    }

    /// Cuts sorted, overlapping or touching ones joined, clamped to start at 0, empty ones dropped.
    pub fn normalized(cuts: &[TimeRange]) -> Vec<TimeRange> {
        let mut out: Vec<TimeRange> = Vec::new();
        let mut sorted = cuts.to_vec();
        sorted.sort_by_key(|c| c.start);
        for c in sorted {
            let (a, b) = (c.start.max(Time::ZERO), c.end());
            if b <= a {
                continue;
            }
            match out.last_mut() {
                Some(last) if a <= last.end() => *last = TimeRange::new(last.start, last.end().max(b) - last.start),
                _ => out.push(TimeRange::new(a, b - a)),
            }
        }
        out
    }
}

/// `extension Clip` of SilenceRemoval.swift.
pub trait SilenceClipExt {
    /// Timeline range that plays the source range `r` (through speed and direction), clamped to the clip.
    fn timeline_range_for_source(&self, r: &TimeRange) -> Option<TimeRange>;
}

impl SilenceClipExt for Clip {
    fn timeline_range_for_source(&self, r: &TimeRange) -> Option<TimeRange> {
        let a = self.timeline_time_for_source(r.start, Time::ZERO);
        let b = self.timeline_time_for_source(r.end(), Time::ZERO);
        let (lo, hi) = (a.min(b).max(self.start), a.max(b).min(self.timeline().end()));
        (hi > lo).then(|| TimeRange::new(lo, hi - lo))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio_role::tests::clip;

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }
    fn r(a: i64, d: i64) -> TimeRange {
        TimeRange::new(s(a), s(d))
    }
    const FRAME: Time = Time::new(1, 30);

    #[test]
    fn cuts_leave_a_pad_and_land_on_frames() {
        // 30 fps; pause 2.0-4.0 s, pad 0.1 s -> cut 2.1-3.9 s
        let c = SilenceRemoval::cuts(&[r(2, 2)], Time::new(1, 10), FRAME);
        assert_eq!(c, vec![TimeRange::new(Time::new(21, 10), Time::new(18, 10))]);
        // not on the grid: start rounds up, end rounds down
        let d = SilenceRemoval::cuts(&[TimeRange::new(Time::new(1, 100), s(1))], Time::ZERO, FRAME);
        assert_eq!(d.len(), 1);
        assert!(d[0].start.frame_index(FRAME) == 1 && d[0].start == FRAME);
        assert!(d[0].end() <= Time::new(101, 100) && d[0].end().frame_index(FRAME) == 30);
    }

    #[test]
    fn too_short_after_padding_is_dropped() {
        let short = TimeRange::new(s(2), Time::new(1, 2));
        assert!(SilenceRemoval::cuts(&[short], Time::new(6, 25), FRAME).is_empty());
    }

    #[test]
    fn cuts_are_sorted_merged_and_clamped_to_zero() {
        let n = SilenceRemoval::normalized(&[r(6, 2), TimeRange::new(s(-1), s(2)), r(7, 2), r(3, 0)]);
        assert_eq!(n, vec![r(0, 1), r(6, 3)]);
    }

    #[test]
    fn clip_source_range_maps_through_speed() {
        let mut c = clip(10, 10, None);
        assert_eq!(c.timeline_range_for_source(&r(2, 3)), Some(r(12, 3)));
        assert_eq!(c.timeline_range_for_source(&r(20, 3)), None);
        c.reversed = true;
        assert_eq!(c.timeline_range_for_source(&r(2, 3)), Some(r(15, 3)));
    }
}
